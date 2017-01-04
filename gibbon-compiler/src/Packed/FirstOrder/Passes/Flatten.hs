-- | Put the program in A-normal form where only varrefs and literals are
-- allowed in operand position.

module Packed.FirstOrder.Passes.Flatten
  ( flatten
  , flattenExp
  , typeExp, TEnv
  ) where

-------------------------------------------------------------------------------

import Control.Monad.State
import Packed.FirstOrder.Common
import Packed.FirstOrder.L1_Source as L1
import qualified Packed.FirstOrder.L2_Traverse as L2

-- import Packed.FirstOrder.L2_Traverse (isCursorTy)

import qualified Data.Map as M

import Prelude hiding (exp)

-------------------------------------------------------------------------------

flatten :: L1.Prog -> SyM L1.Prog
flatten prg@(L1.Prog defs funs main) = do
    main' <- mapM (flattenExp defs env20) main
    funs' <- flattenFuns funs
    return $ L1.Prog defs funs' main'
  where
    flattenFuns = mapM flattenFun
    flattenFun (FunDef nam (narg,targ) ty bod) = do
      let env2 = Env2 (M.singleton narg targ) (fEnv env20)
      bod' <- flattenExp defs env2 bod
      return $ FunDef nam (narg,targ) ty bod'

    env20 = L1.progToEnv prg

-- NOTE: / FIXME
-- If we would just include arrow types in the grammar from the start,
-- the the typeenv could contain function types too.  Data constructors could
-- go in there too.  Everything would be simpler.  We would simply have to use other means
-- to remember that L1 programs are first order.


type Binds = (Var,L1.Ty,Exp)

flattenExp :: DDefs L1.Ty -> Env2 L1.Ty -> L1.Exp -> SyM L1.Exp
flattenExp ddefs env2 ex0 = do (b,e') <- exp (vEnv env2) ex0
                               return $ flatLets b e'
 where
   typeIt = typeExp (ddefs,env2)
   
   exp :: TEnv -> Exp -> SyM ([Binds],Exp)
   exp tenv e0 =
     let triv m e = -- Force something to be trivial
           if isTriv e
           then return ([],e)
           else do tmp <- gensym $ "flt"++m
                   let ty = typeIt tenv e
                   (bnds,e') <- exp tenv e
                   return (bnds++[(tmp,ty,e')], VarE tmp)
         go = exp tenv
         gols f ls m = do (bndss,ls') <- unzip <$> mapM (triv m) ls
                          return (concat bndss, f ls')
     in
     case e0 of
       (VarE _)         -> return ([],e0)
       (LitE _)         -> return ([],e0)

       -- This pass is run at multiple points in the compiler pipeline.
       -- We COULD just let these patterns be treated as arbitrary AppE forms,
       -- but it is safer to handle them explicitly.
       L2.AddCursor _ _ -> return ([],e0) -- Already flat.
                           
       L2.NewBuffer     -> return ([],e0) -- Already flat.
       L2.ScopedBuffer  -> return ([],e0) -- Already flat.
       L2.ReadInt _     -> return ([],e0) -- Already flat.
       -- Mimics the AppE case:
       L2.WriteInt v e  -> do (b1,e') <- triv "WI" e; return (b1, L2.WriteInt v e')
       -- A fail-safe:
       _ | L2.isExtendedPattern e0 -> error$ "Unhandled extended L2 pattern: "++ndoc e0
                                         
       (AppE f arg)     -> do (b1,arg') <- triv "Ap" arg
                              return (b1, AppE f arg')
       (PrimAppE p ls)  -> gols (PrimAppE p)  ls "Prm"
       (MkProdE ls)     -> gols  MkProdE      ls "Prd"
       (MkPackedE k ls) -> gols (MkPackedE k) ls "Pkd"

       (LetE (v1,t1, LetE (v2,t2,rhs2) rhs1) bod) ->
         go $ LetE (v2,t2,rhs2) $ LetE (v1,t1,rhs1) bod
                           
       (LetE (v,t,rhs) bod) -> do (bnd1,rhs') <- go rhs
                                  (bnd2,bod') <- exp (M.insert v t tenv) bod
                                  return (bnd1++[(v,t,rhs')]++bnd2, bod')
       (IfE a b c) -> do (b1,a') <- triv "If" a 
                         (b2,b') <- go b
                         (b3,c') <- go c
                         return (b1, IfE a' (flatLets b2 b') (flatLets b3 c'))
       -- This can happen anywhere, but doing it here prevents
       -- unneccessary bloat where we can ill afford it:
       (ProjE ix (MkProdE ls)) ->
           dbgTrace 5 (" [flatten] Reducing project-of-tuple, index "++show ix++" expr:  "++take 80 (show (MkProdE ls))++"...") $
           go (ls !! ix)
       (ProjE ix e) -> do (b,e') <- triv "Prj" e
                          return (b, ProjE ix e')
       (CaseE e ls) -> do (b,e') <- triv "Cse" e
                          ls' <- forM ls $ \ (k,vrs,rhs) -> do
                                   let tys = lookupDataCon ddefs k
                                       tenv' = M.union (M.fromList (zip vrs tys)) tenv
                                   (b2,rhs') <- exp tenv' rhs
                                   return (k,vrs, flatLets b2 rhs')
                          return (b, CaseE e' ls')
       -- TimeIt is treated like a conditional.  Don't lift out of it:
       (TimeIt e _t b) -> do (bnd,e') <- go e
                             return ([],TimeIt (flatLets bnd e') (typeIt tenv e) b)
       -- (MapE x1 x2) -> __
       -- (FoldE _ _ _) -> __

flattenExpOld :: DDefs L1.Ty -> Env2 L1.Ty -> L1.Exp -> SyM L1.Exp
flattenExpOld defs env2 = fExp (vEnv env2)
  where
    fExp :: M.Map Var L1.Ty -> L1.Exp -> SyM L1.Exp
    fExp _env (L1.VarE v) = return $ L1.VarE v
    fExp _env (L1.LitE i) = return $ L1.LitE i
    fExp _env (L1.AppE v (L1.VarE v')) = return $ L1.AppE v (L1.VarE v')
    fExp _env (L1.AppE v (L1.MkProdE [])) = return $ L1.AppE v (L1.MkProdE [])
    fExp env (L1.AppE v e) =
        do e' <- fExp env e
           v' <- gensym "flatAp"
           let ty = typeExp (defs,env2) env e
           return $ mkLetE (v',ty,e') (L1.AppE v (L1.VarE v'))
    fExp env (L1.PrimAppE p es) =
        do es' <- mapM (fExp env) es
           nams <- mapM gensym $ replicate (length es) "flatPA"
           let bind [] e = e
               bind ((v,e'):xs) e = mkLetE (v,(typeExp (defs,env2) env e'),e') $ bind xs e
           let exp = bind (zip nams es') $ L1.PrimAppE p $ map L1.VarE nams
           return exp
    fExp env (L1.LetE (v,t,L1.VarE i) e) =
        do e' <- fExp (M.insert v t env) e
           return $ L1.LetE (v,t,L1.VarE i) e'
    fExp env (L1.LetE (v,t,L1.LitE i) e) =
        do e' <- fExp (M.insert v t env) e
           return $ L1.LetE (v,t,L1.LitE i) e'                  
    fExp env (L1.LetE (v,t,e') e) =
        do fe' <- fExp env e'
           fe  <- fExp (M.insert v t env) e
           let exp = mkLetE (v,t,fe') fe
           return exp
    fExp env (L1.IfE e1 e2 e3) =
        do fe1 <- fExp env e1
           fe2 <- fExp env e2
           fe3 <- fExp env e3
           v1 <- gensym "flatIf"
           return $ mkLetE (v1,L1.BoolTy,fe1) $ L1.IfE (L1.VarE v1) fe2 fe3
    fExp env (L1.ProjE i e) =
        do fe <- fExp env e
           let ty = typeExp (defs,env2) env e
           v1 <- gensym "flatPj"
           return $ mkLetE (v1,ty,fe) $ L1.ProjE i (L1.VarE v1)
    fExp env (L1.MkProdE es) =
        do fes <- mapM (fExp env) es
           nams <- mapM gensym $ replicate (length fes) "flatPr"
           let tys = map (typeExp (defs,env2) env) fes
               bind [] e            = e
               bind ((v,t,e'):xs) e = mkLetE (v,t,e') $ bind xs e
           return $ bind (zip3 nams tys fes) $ L1.MkProdE $ map L1.VarE nams
    fExp env (L1.CaseE e mp) =
        do fe <- fExp env e
           v <- gensym "flatCs"
           let ty  = typeExp (defs,env2) env fe
           fals <- forM mp $ \(c,args,ae) -> do
                     let tys = lookupDataCon defs c
                     fae <- fExp (M.fromList (zip args tys) `M.union` env) ae
                     return (c,args,fae)
           return $ mkLetE (v,ty,fe) $ L1.CaseE (L1.VarE v) fals
    fExp env (L1.MkPackedE c es) =
        do fes <- mapM (fExp env) es
           nams <- mapM gensym $ replicate (length fes) "flatPk"
           let tys = map (typeExp (defs,env2) env) fes
               bind [] e            = e
               bind ((v,t,e'):xs) e = mkLetE (v,t,e') $ bind xs e
           return $ bind (zip3 nams tys fes) $ L1.MkPackedE c $ map L1.VarE nams
    -- very important to NOT "flatten" the time form:
    fExp env (L1.TimeIt e _ b) =
        do fe <- fExp env e
           let ty = typeExp (defs,env2) env e
           return $ L1.TimeIt fe ty b
    fExp env (L1.MapE (v,t,e') e) =
        do fe' <- fExp env e'
           fe <- fExp env e
           return $ L1.MapE (v,t,fe') fe
    fExp env (L1.FoldE (v1,t1,e1) (v2,t2,e2) e3) =
        do fe1 <- fExp env e1
           fe2 <- fExp env e2
           fe3 <- fExp env e3
           return $ L1.FoldE (v1,t1,fe1) (v2,t2,fe2) fe3

-- | Helper function that lifts out Lets on the RHS of other Lets.
--   Absolutely requires unique names.
mkLetE (vr,ty, L1.LetE bnd e) bod = mkLetE bnd $ mkLetE (vr,ty,e) bod
mkLetE bnd bod = L1.LetE bnd bod

-- | Alternative version of L1.mkLets that also flattens                 
flatLets :: [(Var,Ty,Exp)] -> Exp -> Exp
flatLets [] bod = bod
flatLets (b:bs) bod = mkLetE b (flatLets bs bod)

                     
                     
type TEnv = M.Map Var L1.Ty
                     
typeExp :: (DDefs L1.Ty,Env2 L1.Ty) -> TEnv -> L1.Exp -> L1.Ty
typeExp (dd,env2) env (L1.VarE v) =
    M.findWithDefault (L1.Packed "CURSOR_TY") v env
--  M.findWithDefault (error ("Cannot find type of variable " ++ show v)) v env

typeExp (dd,env2) _env (L1.LitE _i) = L1.IntTy
typeExp (dd,env2) _env (L1.AppE v _e) = snd $ fEnv env2 # v

typeExp (dd,env2) _env (L1.PrimAppE p _es) =
    case p of
      L1.AddP -> L1.IntTy
      L1.SubP -> L1.IntTy
      L1.MulP -> L1.IntTy
      L1.EqIntP -> L1.BoolTy
      L1.EqSymP -> L1.BoolTy
      L1.MkTrue -> L1.BoolTy
      L1.MkFalse -> L1.BoolTy
      L1.DictInsertP ty -> L1.SymDictTy ty
      L1.DictLookupP ty -> ty
      L1.DictEmptyP ty -> L1.SymDictTy ty
      L1.SizeParam -> L1.IntTy
      _ -> error $ "case " ++ (show p) ++ " not handled in typeExp yet"
typeExp (dd,env2) env (L1.LetE (v,t,_) e) = typeExp (dd,env2) (M.insert v t env) e
typeExp (dd,env2) env (L1.IfE _ e _) = typeExp (dd,env2) env e
typeExp (dd,env2) env e0@(L1.ProjE i e) =
    case typeExp (dd,env2) env e of 
     (L1.ProdTy tys) -> tys !! i 
     oth -> error $ "typeExp: Cannot project fields from this type: "++show oth
                  ++"\nExpression:\n  "++sdoc e0
                  ++"\nEnvironment:\n  "++sdoc env
typeExp (dd,env2) env (L1.MkProdE es) =
    L1.ProdTy $ map (typeExp (dd,env2) env) es
typeExp (dd,env2) env (L1.CaseE _e mp) =
    let (c,args,e) = head mp
    in typeExp (dd,env2) (M.fromList (zip args (lookupDataCon dd c)) `M.union` env) e

typeExp (dd,env2) _env (L1.MkPackedE c _es) = L1.Packed (getTyOfDataCon dd c)

typeExp (dd,env2) env (L1.TimeIt e _ _) = typeExp (dd,env2) env e
typeExp (dd,env2) env (L1.MapE _ e)     = typeExp (dd,env2) env e
typeExp (dd,env2) env (L1.FoldE _ _ e)  = typeExp (dd,env2) env e