{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NamedFieldPuns #-}

module L3.Typecheck where

import Packed.FirstOrder.Passes.InferEffects2
import Packed.FirstOrder.Passes.RouteEnds2
import Packed.FirstOrder.Passes.Cursorize4
import Packed.FirstOrder.Passes.Unariser
import Packed.FirstOrder.Passes.ShakeTree
import Packed.FirstOrder.Passes.HoistNewBuf
import Packed.FirstOrder.Passes.FindWitnesses
import Packed.FirstOrder.Common
import Packed.FirstOrder.L1.Syntax hiding (FunDef, Prog, add1Prog)
import Packed.FirstOrder.L2.Syntax
import Packed.FirstOrder.L2.Examples
import qualified Packed.FirstOrder.L2.Typecheck as L2
import qualified Packed.FirstOrder.L3.Typecheck as L3
import qualified Packed.FirstOrder.L3.Syntax as L3

import Test.Tasty.HUnit
import Test.Tasty.TH
import Test.Tasty

runT :: Prog -> L3.Prog
runT prg = fst $ runSyM 0 $ do
  l2 <- inferEffects prg
  l2 <- L2.tcProg l2
  l2 <- routeEnds l2
  l3 <- cursorize l2
  l3 <- findWitnesses l3
  l3 <- L3.tcProg l3
  l3 <- shakeTree l3
  l3 <- hoistNewBuf l3
  l3 <- unariser l3
  L3.tcProg l3

l3TypecheckerTests :: TestTree
l3TypecheckerTests = $(testGroupGenerator)

-- | just a dummy assertion, but we check that runT doesn't raise an exception
case_run_add1 :: Assertion
case_run_add1 = res @=? res
  where res = runT add1Prog

case_run_intAdd :: Assertion
case_run_intAdd = res @=? res
  where res = runT intAddProg