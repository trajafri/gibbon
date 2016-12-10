-- | Interpreter for the target language (L3)

{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE BangPatterns #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Packed.FirstOrder.TargetInterp
    ( Val(..)
    , execProg
    ) where

--------------------------------------------------------------------------------

import Control.Monad
import Control.Exception
import qualified Data.Map.Strict as M
import Data.Maybe (listToMaybe)
import Data.Int
import Data.Sequence (Seq, ViewL ((:<)), (|>))
import qualified Data.Sequence as Seq
import Packed.FirstOrder.Target
import Packed.FirstOrder.Common ((#))
import System.IO.Unsafe
import GHC.Generics
import Control.DeepSeq
import Text.PrettyPrint.GenericPretty
import Text.PrettyPrint.HughesPJ

-- import Data.Time.Clock
import System.Clock
--------------------------------------------------------------------------------

data Val
  = FunVal FunDecl
  | IntVal Int  -- ^ These also serve as Bools
  | TagVal Tag
  | BufVal (Seq Int)
      -- ^ Tags are also written as integers.
  deriving (Eq, Show, Generic, NFData)

instance NFData TimeSpec where
  rnf (TimeSpec !a !b) = ()

{-           
instance Out UTCTime where
    doc s = text (show s)
    docPrec n s = text (show s)
-}
instance Out TimeSpec where
    doc s = text (show s)
    docPrec n s = text (show s)
instance (Out a, Show a) => Out (Seq a) where
    doc s = text (show s)
    docPrec n s = text (show s)
instance Out Val
           
execProg :: Prog -> [Val]
execProg (Prog _ Nothing) = error "Can't evaluate program: No expression given"
execProg (Prog funs (Just (PrintExp expr))) = exec env expr
  where
    env = M.fromList (map (\f -> (funName f, FunVal f)) funs)

type Env = M.Map String Val


clk :: Clock
clk = Monotonic
-- Linux specific:
-- clk = MonotonicRaw

    
eval :: Env -> Triv -> Val
eval env (VarTriv v) = M.findWithDefault (error ("Unbound var: " ++ v)) v env
eval _   (IntTriv i) = IntVal (fromIntegral i) -- TODO: Change L1 to Int64 too.
eval _   (TagTriv t) = TagVal t


exec :: Env -> Tail -> [Val]

exec env (RetValsT ts) = map (eval env) ts

exec env (LetTrivT (v,t,rhs) body) = 
    exec env' body
  where
    env' = extendEnv env [(v,rhs')]
    rhs' = eval env rhs
                         
exec env (LetCallT binds op args body) =
    exec env' body
  where
    rets = apply env (eval env (VarTriv op)) (map (eval env) args)
    env' = extendEnv env (zip (map fst binds) rets)

exec env (LetPrimCallT binds op args body) =
    exec env' body
  where
    rets = applyOp op (map (eval env) args)
    env' = extendEnv env (zip (map fst binds) rets)

exec env (LetIfT bnds (tst,thn,els) bod) =
  do let scrut = eval env tst
         vals = if scrut == IntVal 1
                then exec env thn
                else exec env els
         env' = extendEnv env (zip (map fst bnds) vals)
     exec env' bod

exec env (IfT v1 then_ else_) =
    if v1' == IntVal 1 then exec env then_ else exec env else_    
  where
    v1' = eval env v1

exec _ (ErrT s) =
    error $ "ErrT: " ++ s

exec env (LetTimedT flg bnds rhs bod) = unsafePerformIO $ do
    let iters = if flg then 1
                else (error "Implement timed iteration inside the interpreter...")
    !_ <- return $! force env
    st <- getTime clk          
    vals <- foldM (\ _ i -> execWrapper i env rhs)
                  (error "Internal error: this should be unused.")
               [1..iters]
    en <- getTime clk
    let env' = extendEnv env (zip (map fst bnds) vals)          
    let tm = fromIntegral (toNanoSecs $ diffTimeSpec en st)
              / 10e9 :: Double                        
    if flg
     then do putStrLn $ "ITERS: "++show iters
             putStrLn $ "SIZE: " ++show (error "FINISHME: get size param" :: Int)
             putStrLn $ "BATCHTIME: "++show tm
     else putStrLn $ "SELFTIMED: "++show tm
    return $! exec env' bod
         
exec env (Switch tr alts def) =
    case final_alt of
      Nothing -> error "Switch: No branch to choose."
      Just br -> exec env br
  where
    tr' = eval env tr

    intAlts
      | IntAlts alts' <- alts
      = alts'
      | otherwise
      = error "intAlts: Found TagAlts"

    tagAlts
      | TagAlts alts' <- alts
      = alts'
      | otherwise
      = error "tagAlts: Found IntAlts"

    chooseIntAlt i = snd <$> listToMaybe (filter ((i ==) . fst) intAlts)
    chooseTagAlt t = snd <$> listToMaybe (filter ((t ==) . fst) tagAlts)

    final_alt =
      maybe def return $
        case tr' of
          IntVal i -> chooseIntAlt (fromIntegral i)
          TagVal t -> chooseTagAlt t
          _        -> error ("Switch: invalid value in scrutinee position: " ++ show tr')

exec env (TailCall fn args) =
    apply env fn' args'
  where
    fn' = eval env (VarTriv fn)
    args' = map (eval env) args

exec _ e = error$ "Interpreter/exec, unhandled expression:\n  "++show (doc e)

{-# NOINLINE execWrapper #-}
execWrapper :: Int -> Env -> Tail -> IO [Val]
execWrapper _i env ex =
    evaluate $ force $ exec env ex
           
extendEnv :: Env -> [(String, Val)] -> Env
extendEnv = foldr (uncurry M.insert)

apply :: Env -> Val -> [Val] -> [Val]

apply env (FunVal (FunDecl _ as _ body)) args =
    exec (extendEnv env (zip (map fst as) args)) body

apply _ notFun _ =
    error ("apply to a non-function: " ++ show notFun)

--------------------------------------------------------------------------------

applyOp :: Prim -> [Val] -> [Val]

applyOp AddP [IntVal i1, IntVal i2] = [IntVal (i1 + i2)]
applyOp SubP [IntVal i1, IntVal i2] = [IntVal (i1 - i2)]
applyOp MulP [IntVal i1, IntVal i2] = [IntVal (i1 * i2)]

applyOp EqP  [IntVal i1, IntVal i2] = [IntVal (if i1 == i2 then 1 else 0)]

applyOp NewBuf [] = [BufVal Seq.empty]

applyOp WriteTag [TagVal tag, BufVal is] = [BufVal (is |> fromIntegral tag)]
applyOp WriteInt [IntVal i,   BufVal is] = [BufVal (is |> i)]

applyOp ReadTag [BufVal is] = case Seq.viewl is of
                                Seq.EmptyL -> error "ReadTag: Empty buffer"
                                t :< is'   -> [TagVal (fromIntegral t), BufVal is']

applyOp ReadInt [BufVal is] = case Seq.viewl is of
                                Seq.EmptyL -> error "ReadInt: Empty buffer"
                                i :< is'   -> [IntVal i, BufVal is']

applyOp op args = error ("applyOp: Unsupported form: " ++ show op ++ " " ++ show args)
