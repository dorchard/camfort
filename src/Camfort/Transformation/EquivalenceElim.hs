{-
   Copyright 2016, Dominic Orchard, Andrew Rice, Mistral Contrastin, Matthew Danish

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleContexts #-}

module Camfort.Transformation.EquivalenceElim
  ( refactorEquivalences
  ) where

import Data.List
import qualified Data.Map as M
import Data.Generics.Uniplate.Operations
import Control.Monad.State.Lazy

import qualified Language.Fortran.AST as F
import qualified Language.Fortran.Analysis.Types as FAT (analyseTypes, TypeEnv)
import qualified Language.Fortran.Util.Position as FU
import qualified Language.Fortran.Analysis.Renaming as FAR
import qualified Language.Fortran.Analysis as FA

import Camfort.Analysis
  (SimpleAnalysis, analysisInput, analysisResult, branchAnalysis, writeDebug)
import Camfort.Helpers.Syntax
import Camfort.Analysis.Annotations
import Camfort.Transformation.DeadCode


type A1 = FA.Analysis Annotation
type RmEqState = ([[F.Expression A1]], Int, String)

refactorEquivalences :: SimpleAnalysis (F.ProgramFile A) (F.ProgramFile A)
refactorEquivalences = do
  pf <- analysisInput
  let
    -- initialise analysis
    pf'             = FAR.analyseRenames . FA.initAnalysis $ pf
    -- calculate types
    (pf'', typeEnv) = FAT.analyseTypes pf'
    -- Remove equivalences and add appropriate copy statements
    (report, pf''') = refactoring typeEnv pf''
  -- Lastly deadcode eliminate any redundant copy statements
  -- generated by the refactoring (but don't dead code elim
  -- existing code)
  writeDebug report
  analysisResult <$> branchAnalysis (deadCode True) (fmap FA.prevAnnotation pf''')
  where
    refactoring :: FAT.TypeEnv -> F.ProgramFile A1 -> (Report, F.ProgramFile A1)
    refactoring tenv pf = (mkReport report, pf')
      where
         (pf', (_, _, report)) = runState equiv ([], 0, "")

         equiv = do pf' <- transformBiM perBlockRmEquiv pf
                    descendBiM (addCopysPerBlockGroup tenv) pf'

addCopysPerBlockGroup :: FAT.TypeEnv -> [F.Block A1] -> State RmEqState [F.Block A1]
addCopysPerBlockGroup tenv blocks = do
    blockss <- mapM (addCopysPerBlock tenv) blocks
    return $ concat blockss

addCopysPerBlock :: FAT.TypeEnv -> F.Block A1 -> State RmEqState [F.Block A1]
addCopysPerBlock tenv x@(F.BlStatement _ _ _
                 (F.StExpressionAssign a sp@(FU.SrcSpan s1 _) dstE _))
  | not (pRefactored $ FA.prevAnnotation a) = do
    -- Find all variables/cells that are equivalent to the target
    -- of this assignment
    eqs <- equivalentsToExpr dstE
    -- If there is only one, then it must refer to itself, so do nothing
    if length eqs <= 1
      then return [x]
    -- If there are more than one, copy statements must be generated
      else do
        (equivs, n, r) <- get

        -- Remove the destination from the equivalents
        let eqs' = deleteBy (\x y -> af x == af y) dstE eqs

        -- Make copy statements
        let pos = afterAligned sp
        let copies = map (mkCopy tenv pos dstE) eqs'

        -- Reporting
        let (FU.Position _ c l) = s1
        let reportF i = show (l + i) ++ ":" ++ show c
                    ++ ": added copy due to refactored equivalence\n"
        let report n = concatMap reportF [n..(n + length copies - 1)]

        -- Update refactoring state
        put (equivs, n + length eqs', r ++ report n)
        -- Sequence original assignment with new assignments
        return $ x : copies

addCopysPerBlock tenv x = do
   x' <- descendBiM (addCopysPerBlockGroup tenv) x
   return [x']

-- see if two expressions have the same type
equalTypes tenv e e' = do
    v1 <- extractVariable e
    v2 <- extractVariable e'
    t1 <- M.lookup v1 tenv
    t2 <- M.lookup v2 tenv
    if t1 == t2 then Just t1 else Nothing

-- Create copy statements. Parameters:
--    * A type environment to find out if a type cast is needed
--    * A SrcPos where the copy statements are going to inserted at
--    * The source expression
--    * The number of copies to increment the line by
--           paired with the destination expression
mkCopy :: FAT.TypeEnv
       -> FU.Position
       -> F.Expression A1 -> F.Expression A1 -> F.Block A1
mkCopy tenv pos srcE dstE = FA.initAnalysis $
   F.BlStatement a sp Nothing $
     case equalTypes tenv srcE dstE of
       -- Types not equal, so create a transfer
       Nothing -> F.StExpressionAssign a sp dstE' call
                    where
                     call = F.ExpFunctionCall a sp transf argst
                     transf = F.ExpValue a sp (F.ValVariable "transfer")
                     argst  = Just (F.AList a sp args)
                     args   = map (F.Argument a sp Nothing) [srcE', dstE']
       -- Types are equal, simple a assignment
       Just _ -> F.StExpressionAssign a sp dstE' srcE'
  where
     -- Set position to be at col = 0
     sp   = FU.SrcSpan (toCol0 pos) (toCol0 pos)
     -- But store the aligned position in refactored so
     -- that the reprint algorithm can add the appropriate indentation
     a = unitAnnotation { refactored = Just pos, newNode = True }
     dstE' = FA.stripAnalysis dstE
     srcE' = FA.stripAnalysis srcE

perBlockRmEquiv :: F.Block A1 -> State RmEqState (F.Block A1)
perBlockRmEquiv = transformBiM perStatementRmEquiv

perStatementRmEquiv :: F.Statement A1 -> State RmEqState (F.Statement A1)
perStatementRmEquiv (F.StEquivalence a sp@(FU.SrcSpan spL _) equivs) = do
    (ess, n, r) <- get
    let report = r ++ show spL ++ ": removed equivalence \n"
    put (((map F.aStrip) . F.aStrip $ equivs) ++ ess, n - 1, r ++ report)
    let a' = onPrev (\ap -> ap {refactored = Just spL, deleteNode = True}) a
    return (F.StEquivalence a' (deleteLine sp) equivs)
perStatementRmEquiv f = return f

-- 'equivalents e' returns a list of variables/memory cells
-- that have been equivalenced with "e".
equivalentsToExpr :: F.Expression A1 -> State RmEqState [F.Expression A1]
equivalentsToExpr x = do
    (equivs, _, _) <- get
    return (inGroup x equivs)
  where
    inGroup _ [] = []
    inGroup x (xs:xss) =
        if AnnotationFree x `elem` map AnnotationFree xs
        then xs
        else inGroup x xss
