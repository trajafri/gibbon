{-# OPTIONS_GHC -fno-warn-name-shadowing #-}
{-# OPTIONS_GHC -Wno-type-defaults #-}
{-# LANGUAGE ParallelListComp #-}
{-# LANGUAGE QuasiQuotes        #-}
{-# LANGUAGE TemplateHaskell    #-}

-- | The final pass of the compiler: generate C code.

module Gibbon.Passes.Codegen
  ( codegenProg, harvestStructTys, makeName, rewriteReturns ) where

import           Control.Monad
import           Data.Bifunctor (first)
import           Data.Int
import           Data.Loc
import qualified Data.Map as M
import           Data.Maybe
import           Data.List as L
import qualified Data.Set as S
import           Language.C.Quote.C (cdecl, cedecl, cexp, cfun, cparam, csdecl, cstm, cty)
import qualified Language.C.Quote.C as C
import qualified Language.C.Syntax as C
import           Prelude hiding (init)
import           System.Directory
import           System.Environment
import           Text.PrettyPrint.Mainland
import           Text.PrettyPrint.Mainland.Class

import           Gibbon.Common
import qualified Gibbon.Language as GL
import           Gibbon.DynFlags
import           Gibbon.L2.Syntax ( Multiplicity(..) )
import           Gibbon.L4.Syntax

--------------------------------------------------------------------------------


-- | Harvest all struct tys.  All product types used anywhere in the program.
harvestStructTys :: Prog -> S.Set [Ty]
harvestStructTys (Prog _ funs mtal) =
    S.delete [] (S.union tys0 tys1)
  where
  tys00 = concatMap allTypes allTails

  tys0 :: S.Set [Ty]
  tys0 = findAllProds tys00

  tys1 :: S.Set [Ty]
  -- All types mentioned in function arguments and returns:
  tys1 = S.fromList [ tys | fn <- funs, ProdTy tys <- funTys fn ]
  -- structs f = makeStructs $ S.toList $ harvestStructTys prg

  funTys :: FunDecl -> [Ty]
  funTys (FunDecl _ args ty _ _) = ty : (map snd args)

  allTails = (case mtal of
                Just (PrintExp t) -> [t]
                Nothing -> []) ++
             map funBody funs

  -- We may have nested products; this finds everything:
  findAllProds :: [Ty] -> S.Set [Ty]
  findAllProds = go
    where
      go []     = S.empty
      go (t:ts) =
       case t of
         ProdTy ls -> S.insert ls $ S.union (go ls) (go ts)
         ListTy ty -> S.insert [ListTy ty] $ S.union (go [ty])(go ts)
         _ -> go ts

  -- This finds all types that maybe grouped together as a ProdTy:
  allTypes :: Tail -> [Ty]
  allTypes = go
   where
    go tl =
     case tl of
       (RetValsT _)  -> []
       (AssnValsT ls bod_maybe) ->
         case bod_maybe of
           Just bod -> ProdTy (map (\(_,x,_) -> x) ls) : go bod
           Nothing  -> [ProdTy (map (\(_,x,_) -> x) ls)]
       -- This creates a demand for a struct return, but it is covered
       -- by the fun signatures already:
       (LetCallT _ binds _ _  bod) -> ProdTy (map snd binds) : go bod
       -- INVARIANT: This does not create a struct:
       -- But just in case it does in the future, we add it:
       (LetPrimCallT binds prm _ bod) ->
         let rst = go bod in
         case prm of
           VEmptyP ty  -> ListTy ty : rst
           VNthP   ty  -> ListTy ty : rst
           VLengthP ty -> ListTy ty : rst
           VUpdateP ty -> ListTy ty : rst
           VSnocP ty   -> ListTy ty : rst
           VSortP ty   -> ListTy ty : rst
           InPlaceVSnocP ty   -> ListTy ty : rst
           InPlaceVSortP ty   -> ListTy ty : rst
           ReadArrayFile _ ty -> ListTy ty : rst
           _ -> ProdTy (map snd binds) : rst
       (LetTrivT (_,ty,_) bod)     -> ty : go bod
       -- This should not create a struct.  Again, we add it just for the heck of it:
       (LetIfT binds (_,a,b) bod)  -> ProdTy (map snd binds) : go a ++ go b ++ go bod
       (LetTimedT _ binds rhs bod) -> ProdTy (map snd binds) : go rhs ++ go bod
       (LetArenaT _ bod)          -> ProdTy [ArenaTy] : go bod

       -- These are precisely for operating on structs:
       (LetUnpackT binds _ bod)    -> ProdTy (map snd binds) : go bod
       (LetAllocT _ vals bod)      -> ProdTy (map fst vals) : go bod
       (LetAvailT _ bod)           -> go bod

       (IfT _ a b) -> go a ++ go b
       ErrT{} -> []
       (Switch _ _ (IntAlts ls) b) -> concatMap (go . snd) ls ++ concatMap go (maybeToList b)
       (Switch _ _ (TagAlts ls) b) -> concatMap (go . snd) ls ++ concatMap go (maybeToList b)
       (TailCall _ _)    -> []
       (Goto _) -> []

sortFns :: Prog -> S.Set Var
sortFns (Prog _ funs mtal) = foldl go S.empty allTails
  where
    allTails = (case mtal of
                Just (PrintExp t) -> [t]
                Nothing -> []) ++
             map funBody funs

    go acc tl =
      case tl of
        RetValsT{} -> acc
        AssnValsT _ mb_bod -> case mb_bod of
                                Just bod -> go acc bod
                                Nothing  -> acc
        LetCallT{bod} -> go acc bod
        LetPrimCallT{prim,bod,rands} ->
          case prim of
            VSortP{} ->
              let [_,VarTriv fp] = rands
              in go (S.insert fp acc) bod
            _ -> go acc bod
        LetTrivT{bod}   -> go acc bod
        LetIfT{ife,bod} ->
          let (_,a,b) = ife
          in go (go (go acc a) b) bod
        LetUnpackT{bod} -> go acc bod
        LetAllocT{bod}  -> go acc bod
        LetAvailT{bod}  -> go acc bod
        IfT{con,els}    -> go (go acc con) els
        ErrT{} -> acc
        LetTimedT{timed,bod} -> go (go acc timed) bod
        Switch _ _ alts mb_tl ->
          let acc1 = case mb_tl of
                       Nothing -> acc
                       Just tl -> go acc tl
          in case alts of
               TagAlts ls -> foldr (\(_,b) ac -> go ac b) acc1 ls
               IntAlts ls -> foldr (\(_,b) ac -> go ac b) acc1 ls
        TailCall{}     -> acc
        Goto{}         -> acc
        LetArenaT{bod} -> go acc bod

--------------------------------------------------------------------------------
-- * C codegen

-- | Compile a program to C code which has the side effect of the
-- "main" expression in that program.
--
--  The boolean flag is true when we are compiling in "Packed" mode.
codegenProg :: Config -> Prog -> IO String
codegenProg cfg prg@(Prog sym_tbl funs mtal) = do
      env <- getEnvironment
      let rtsPath = case lookup "GIBBONDIR" env of
                      Just p -> p ++"/gibbon-compiler/cbits/rts.c"
                      Nothing -> "cbits/rts.c" -- Assume we're running from the compiler dir!
      e <- doesFileExist rtsPath
      unless e $ error$ "codegen: rts.c file not found at path: "++rtsPath
                       ++"\n Consider setting GIBBONDIR to repo root.\n"
      rts <- readFile rtsPath -- TODO (maybe): We can read this in in compile time using TH
      return (rts ++ '\n' : pretty 80 (stack (map ppr defs)))
    where
      init_fun_env = foldr (\fn acc -> M.insert (funName fn) (map snd (funArgs fn), funRetTy fn) acc) M.empty funs

      sort_fns = sortFns prg

      defs = fst $ runPassM cfg 0 $ do
        (prots,funs') <- (unzip . concat) <$> mapM codegenFun funs
        main_expr' <- main_expr
        let struct_tys = uniqueDicts $ S.toList $ harvestStructTys prg
        return ((L.nub $ makeStructs struct_tys) ++ prots ++ funs' ++ [main_expr'])

      main_expr :: PassM C.Definition
      main_expr = do
        e <- case mtal of
               -- [2019.06.13]: CSK, Why is codegenTail always called with IntTy?
               Just (PrintExp t) -> codegenTail M.empty init_fun_env t IntTy []
               _ -> pure []
        let bod = mkSymTable ++ e
        pure $ C.FuncDef [cfun| void __main_expr() { $items:bod } |] noLoc

      codegenFun' :: FunDecl -> PassM C.Func
      codegenFun' (FunDecl nam args ty tal _) =
          do let retTy   = codegenTy ty
                 params  = map (\(v,t) -> [cparam| $ty:(codegenTy t) $id:v |]) args
                 init_venv = M.fromList args
             if S.member nam sort_fns
             then do
               -- See codegenSortFn
               let nam' = varAppend nam (toVar "_original")
               body <- codegenTail init_venv init_fun_env tal ty []
               let fun = [cfun| $ty:retTy $id:nam' ($params:params) {
                                $items:body
                                } |]
               return fun
             else do
               body <- codegenTail init_venv init_fun_env tal ty []
               let fun = [cfun| $ty:retTy $id:nam ($params:params) {
                                $items:body
                                } |]
               return fun

      -- C's qsort expects a sort function to be of type, (void*  a, void* b) : int.
      -- But there's no way for a user to write a function of this type. So we generate
      -- the function that the user wrote with a different_name, and then codegenSortFn
      -- generates the actual sort function; which reads the values from these void*
      -- pointers and calls the user written one after that.
      codegenSortFn :: FunDecl -> PassM C.Func
      codegenSortFn (FunDecl nam args _ty _tal _) = do
        let nam' = varAppend nam (toVar "_original")
            ([v0,v1],[ty0,ty1]) = unzip args
            retTy      = codegenTy IntTy
            params     = map (\v -> [cparam| const void* $id:v |]) [v0,v1]
        tmpa <- gensym "fst"
        tmpb <- gensym "snd"
        let bod = [ C.BlockDecl [cdecl| $ty:(codegenTy ty0) $id:tmpa = *($ty:(codegenTy ty0) *) $id:v0; |]
                  , C.BlockDecl [cdecl| $ty:(codegenTy ty1) $id:tmpb = *($ty:(codegenTy ty1) *) $id:v1; |]
                  , C.BlockStm  [cstm| return $id:nam'($id:tmpa, $id:tmpb);|]
                  ]
            fun = [cfun| $ty:retTy $id:nam ($params:params) {
                          $items:bod
                       } |]
        return fun

      makeProt :: C.Func -> Bool -> PassM C.InitGroup
      makeProt fn ispure = do
        dflags <- getDynFlags
        let prot@(C.InitGroup decl_spec _ inits lc) = C.funcProto fn
            purattr = C.Attr (C.Id "pure" noLoc) [] noLoc
            -- Only add pure annotations if compiling in pointer mode, and if the
            -- --no-pure-annot flag is not passed.
            pureAnnotOk = not (gopt Opt_No_PureAnnot dflags || gopt Opt_Packed dflags)
        if ispure && pureAnnotOk
        then return $ C.InitGroup decl_spec [purattr] inits lc
        else return prot

      codegenFun :: FunDecl -> PassM [(C.Definition, C.Definition)]
      codegenFun fd@FunDecl{funName} =
          do fun <- codegenFun' fd
             prot <- makeProt fun (isPure fd)
             sort_fn <- if S.member funName sort_fns
                        then do
                          fun' <- codegenSortFn fd
                          let prot = C.funcProto fun'
                          pure [(C.DecDef prot noLoc, C.FuncDef fun' noLoc)]
                        else pure []
             return $ [(C.DecDef prot noLoc, C.FuncDef fun noLoc)] ++ sort_fn

      mkSymTable :: [C.BlockItem]
      mkSymTable =
        map
          (\(k,v) -> case v of
                       -- Special symbols that get handled differently
                       "NEWLINE" -> C.BlockStm [cstm| set_newline($k); |]
                       "COMMA" -> C.BlockStm [cstm| set_comma($k); |]
                       "SPACE" -> C.BlockStm [cstm| set_space($k); |]
                       "LEFTPAREN" -> C.BlockStm [cstm| set_leftparen($k); |]
                       "RIGHTPAREN" -> C.BlockStm [cstm| set_rightparen($k); |]
                       -- Normal symbols just get added to the table
                       _ -> C.BlockStm [cstm| add_symbol($k, $v); |]
          )
          (M.toList sym_tbl)


makeStructs :: [[Ty]] -> [C.Definition]
makeStructs [] = []
makeStructs (ts : ts') =
  case ts of
    [ListTy ty] ->
        let ty_name  = case ty of
                         IntTy      -> makeName' ty
                         ProdTy tys -> makeName tys
                         _ -> "makeStructs: Lists of type " ++ sdoc ty ++ " not allowed."
            icd_name = ty_name ++ "_icd"
            icd_ty   = [cty|typename UT_icd|]
            icd      = [cedecl| $ty:icd_ty $id:icd_name = {sizeof($id:ty_name),NULL, NULL, NULL} ;|]
        in icd : makeStructs ([ty]:ts')
    _ ->
      let strName = makeName ts
          decls = zipWith (\t n -> [csdecl| $ty:(codegenTy t) $id:("field"++(show n)); |]) ts [0 :: Int ..]
          d = [cedecl| typedef struct $id:(strName ++ "_struct") { $sdecls:decls } $id:strName; |]
      in d : makeStructs ts'

uniqueDicts :: [[Ty]] -> [[Ty]]
uniqueDicts [] = []
uniqueDicts (ts : ts') = (map f ts) : uniqueDicts ts'
    where f (SymDictTy _ t) = SymDictTy "_" t
          f t = t

-- | Replace returns with assignments to a given set of destinations.
rewriteReturns :: Tail -> [(Var,Ty)] -> Tail
rewriteReturns tl bnds =
 let go x = rewriteReturns x bnds in
 case tl of
   (RetValsT ls) -> AssnValsT [ (v,t,e) | (v,t) <- bnds | e <- ls ] Nothing
   (Goto _) -> tl

   -- Here we've already rewritten the tail to assign values
   -- somewhere.. and now we want to REREWRITE it?
   (AssnValsT _ _) -> error$ "rewriteReturns: Internal invariant broken:\n "++sdoc tl
   (e@LetCallT{bod})     -> e{bod = go bod }
   (e@LetPrimCallT{bod}) -> e{bod = go bod }
   (e@LetTrivT{bod})     -> e{bod = go bod }
   -- We don't recur on the "tails" under the if, because they're not
   -- tail with respect to our redex:
   (LetIfT bnd (a,b,c) bod) -> LetIfT bnd (a,b,c) (go bod)
   (LetTimedT flg bnd rhs bod) -> LetTimedT flg bnd rhs (go bod)
   (LetArenaT v bod) -> LetArenaT v (go bod)
   (LetUnpackT bs scrt body) -> LetUnpackT bs scrt (go body)
   (LetAllocT lhs vals body) -> LetAllocT lhs vals (go body)
   (LetAvailT vs body)       -> LetAvailT vs (go body)
   (IfT a b c) -> IfT a (go b) (go c)
   (ErrT s) -> (ErrT s)
   (Switch lbl tr alts def) -> Switch lbl tr (mapAlts go alts) (fmap go def)
   -- Oops, this is not REALLY a tail call.  Hoist it and go under:
   (TailCall f rnds) -> let (vs,ts) = unzip bnds
                            vs' = map (toVar . (++"hack")) (map fromVar vs) -- FIXME: Gensym
                        in LetCallT False (zip vs' ts) f rnds
                            (rewriteReturns (RetValsT (map VarTriv vs')) bnds)
 where
   mapAlts f (TagAlts ls) = TagAlts $ zip (map fst ls) (map (f . snd) ls)
   mapAlts f (IntAlts ls) = IntAlts $ zip (map fst ls) (map (f . snd) ls)


-- dummyLoc :: SrcLoc
-- dummyLoc = (SrcLoc (Loc (Pos "" 0 0 0) (Pos "" 0 0 0)))

codegenTriv :: VEnv -> Triv -> C.Exp
codegenTriv _ (VarTriv v) = C.Var (C.toIdent v noLoc) noLoc
codegenTriv _ (IntTriv i) = [cexp| $int:i |]
codegenTriv _ (FloatTriv i) = [cexp| $double:i |]
codegenTriv _ (SymTriv i) = [cexp| $i |]
codegenTriv _ (TagTriv i) = [cexp| $i |]
codegenTriv venv (ProdTriv ls) =
  let ty = codegenTy $ typeOfTriv venv (ProdTriv ls)
      args = map (\a -> (Nothing,C.ExpInitializer (codegenTriv venv a) noLoc)) ls
  in [cexp| $(C.CompoundLit ty args noLoc) |]
codegenTriv venv (ProjTriv i trv) =
  let field = "field" ++ show i
  in [cexp| $(codegenTriv venv trv).$id:field |]

-- Type environment
type FEnv = M.Map Var ([Ty], Ty)
type VEnv = M.Map Var Ty
type SyncDeps = [(Var, C.BlockItem)]

-- | The central codegen function.
codegenTail :: VEnv -> FEnv -> Tail -> Ty -> SyncDeps -> PassM [C.BlockItem]

-- Void type:
codegenTail _ _ (RetValsT []) _ty _   = return [ C.BlockStm [cstm| return; |] ]
-- Single return:
codegenTail venv _ (RetValsT [tr]) ty _ =
    case ty of
      ProdTy [_one] -> do
          let arg = [(Nothing,C.ExpInitializer (codegenTriv venv tr) noLoc)]
              ty' = codegenTy ty
          return $ [ C.BlockStm [cstm| return $(C.CompoundLit ty' arg noLoc); |] ]
      _ -> return [ C.BlockStm [cstm| return $(codegenTriv venv tr); |] ]
-- Multiple return:
codegenTail venv _ (RetValsT ts) ty _ =
    return $ [ C.BlockStm [cstm| return $(C.CompoundLit ty' args noLoc); |] ]
    where args = map (\a -> (Nothing,C.ExpInitializer (codegenTriv venv a) noLoc)) ts
          ty' = codegenTy ty

codegenTail venv fenv (AssnValsT ls bod_maybe) ty sync_deps = do
    case bod_maybe of
      Just bod -> do
        let venv' = (M.fromList $ map (\(a,b,_) -> (a,b)) ls)
                    `M.union` venv
        bod' <- codegenTail venv' fenv bod ty sync_deps
        return $ [ mut (codegenTy ty) vr (codegenTriv venv triv) | (vr,ty,triv) <- ls ] ++ bod'
      Nothing  ->
        return $ [ mut (codegenTy ty) vr (codegenTriv venv triv) | (vr,ty,triv) <- ls ]

codegenTail venv fenv (Switch lbl tr alts def) ty sync_deps =
    case def of
      Nothing  -> let (rest,lastone) = splitAlts alts in
                  genSwitch venv fenv lbl tr rest (altTail lastone) ty sync_deps
      Just def -> genSwitch venv fenv lbl tr alts def ty sync_deps

codegenTail venv _ (TailCall v ts) _ty _ =
    return $ [ C.BlockStm [cstm| return $( C.FnCall (cid v) (map (codegenTriv venv) ts) noLoc ); |] ]

codegenTail venv fenv (IfT e0 e1 e2) ty sync_deps = do
    e1' <- codegenTail venv fenv e1 ty sync_deps
    e2' <- codegenTail venv fenv e2 ty sync_deps
    return $ [ C.BlockStm [cstm| if ($(codegenTriv venv e0)) { $items:e1' } else { $items:e2' } |] ]

codegenTail _ _ (ErrT s) _ty _ = return $ [ C.BlockStm [cstm| printf("%s\n", $s); |]
                                          , C.BlockStm [cstm| exit(1); |] ]


-- We could eliminate these earlier
codegenTail venv fenv (LetTrivT (vr,rty,rhs) body) ty sync_deps =
    do let venv' = M.insert vr rty venv
       tal <- codegenTail venv' fenv body ty sync_deps
       return $ [ C.BlockDecl [cdecl| $ty:(codegenTy rty) $id:vr = ($ty:(codegenTy rty)) $(codegenTriv venv rhs); |] ]
                ++ tal

-- TODO: extend rts with arena primitives, and invoke them here
codegenTail venv fenv (LetArenaT vr body) ty sync_deps =
    do tal <- codegenTail venv fenv body ty sync_deps
       return $ [ C.BlockDecl [cdecl| $ty:(codegenTy ArenaTy) $id:vr = alloc_arena();|] ]
              ++ tal

codegenTail venv fenv (LetAllocT lhs vals body) ty sync_deps =
    do let structTy = codegenTy (ProdTy (map fst vals))
           size = [cexp| sizeof($ty:structTy) |]
           venv' = M.insert lhs PtrTy venv
       tal <- codegenTail venv' fenv body ty sync_deps
       return$ assn (codegenTy PtrTy) lhs [cexp| ( $ty:structTy *)ALLOC( $size ) |] :
               [ C.BlockStm [cstm| (($ty:structTy *)  $id:lhs)->$id:fld = $(codegenTriv venv trv); |]
               | (ix,(_ty,trv)) <- zip [0 :: Int ..] vals
               , let fld = "field"++show ix] ++ tal

codegenTail venv fenv (LetAvailT vs body) ty sync_deps =
    do let (avail, sync_deps') = partition (\(v,_) -> elem v vs) sync_deps
       tl <- codegenTail venv fenv body ty sync_deps'
       pure $ (map snd avail) ++ tl

codegenTail venv fenv (LetUnpackT bs scrt body) ty sync_deps =
    do let mkFld :: Int -> C.Id
           mkFld i = C.toIdent ("field" ++ show i) noLoc

           fldTys = map snd bs
           struct_ty = codegenTy (ProdTy fldTys)

           mk_bind i (v, t) = [cdecl|
             $ty:(codegenTy t) $id:v = ( ( $ty:struct_ty * ) $exp:(cid scrt) )->$id:(mkFld i);
           |]

           binds = zipWith mk_bind [0..] bs
           venv' = (M.fromList bs) `M.union` venv

       body' <- codegenTail venv' fenv body ty sync_deps
       return (map C.BlockDecl binds ++ body')

-- Here we unzip the tuple into assignments to local variables.
codegenTail venv fenv (LetIfT bnds (e0,e1,e2) body) ty sync_deps =

    do let decls = [ C.BlockDecl [cdecl| $ty:(codegenTy ty0) $id:vr0; |]
                   | (vr0,ty0) <- bnds ]
       let e1' = rewriteReturns e1 bnds
           e2' = rewriteReturns e2 bnds

           venv' = (M.fromList bnds) `M.union` venv

       e1'' <- codegenTail venv' fenv e1' ty sync_deps
       e2'' <- codegenTail venv' fenv e2' ty sync_deps
       -- Int 1 is Boolean true:
       let ifbod = [ C.BlockStm [cstm| if ($(codegenTriv venv e0)) { $items:e1'' } else { $items:e2'' } |] ]
       tal <- codegenTail venv' fenv body ty sync_deps
       return $ decls ++ ifbod ++ tal

codegenTail venv fenv (LetTimedT flg bnds rhs body) ty sync_deps =

    do let decls = [ C.BlockDecl [cdecl| $ty:(codegenTy ty0) $id:vr0; |]
                   | (vr0,ty0) <- bnds ]
       let rhs' = rewriteReturns rhs bnds
       rhs'' <- codegenTail venv fenv rhs' ty sync_deps
       batchtime <- gensym "batchtime"
       selftimed <- gensym "selftimed"
       let ident = case bnds of
                     ((v,_):_) -> v
                     _ -> (toVar "")
           begn  = "begin_" ++ (fromVar ident)
           end   = "end_" ++ (fromVar ident)
           iters = "iters_"++ (fromVar ident)

           timebod = [ C.BlockDecl [cdecl| struct timespec $id:begn; |]
                     , C.BlockStm [cstm| clock_gettime(CLOCK_MONOTONIC_RAW, & $id:begn );  |]
                     , (if flg
                        -- Save and restore EXCEPT on the last iteration.  This "cancels out" the effect of intermediate allocations.
                        then let body = [ C.BlockStm [cstm| if ( $id:iters != global_iters_param-1) save_alloc_state(); |] ] ++
                                        rhs''++
                                        [ C.BlockStm [cstm| if ( $id:iters != global_iters_param-1) restore_alloc_state(); |] ]
                             in C.BlockStm [cstm| for (long long $id:iters = 0; $id:iters < global_iters_param; $id:iters ++) { $items:body } |]
                        else C.BlockStm [cstm| { $items:rhs'' } |])
                     , C.BlockDecl [cdecl| struct timespec $id:end; |]
                     , C.BlockStm [cstm| clock_gettime(CLOCK_MONOTONIC_RAW, &$(cid (toVar end))); |]
                     , C.BlockDecl [cdecl| double $id:batchtime = difftimespecs(&$(cid (toVar begn)), &$(cid (toVar end))); |]
                     , C.BlockDecl [cdecl| double $id:selftimed = $id:batchtime / global_iters_param; |]
                     ]
           withPrnt = timebod ++
                       if flg
                       then [ C.BlockStm [cstm| printf("ITERS: %lld\n", global_iters_param); |]
                            , C.BlockStm [cstm| printf("SIZE: %lld\n", global_size_param); |]
                            , C.BlockStm [cstm| printf("BATCHTIME: %e\n", $id:batchtime); |]
                            , C.BlockStm [cstm| printf("SELFTIMED: %e\n", $id:selftimed); |]
                            ]
                       else [ C.BlockStm [cstm| printf("SIZE: %lld\n", global_size_param); |]
                            , C.BlockStm [cstm| printf("SELFTIMED: %e\n", difftimespecs(&$(cid (toVar begn)), &$(cid (toVar end)))); |] ]
       let venv' = (M.fromList bnds) `M.union` venv
       tal <- codegenTail venv' fenv body ty sync_deps
       return $ decls ++ withPrnt ++ tal


codegenTail venv fenv (LetCallT False bnds ratr rnds body) ty sync_deps
    | [] <- bnds = do tal <- codegenTail venv fenv body ty sync_deps
                      return $ [toStmt fnexp] ++ tal
    | [bnd] <- bnds  = let fn_ret_ty = snd (fenv M.! ratr)
                           venv' = (M.fromList bnds) `M.union` venv in
                       case fn_ret_ty of
                         -- Copied from the otherwise case below.
                         ProdTy [_one] -> do
                           nam <- gensym $ toVar "tmp_struct"
                           let bind (v,t) f = assn (codegenTy t) v (C.Member (cid nam) (C.toIdent f noLoc) noLoc)
                               fields = map (\i -> "field" ++ show i) [0 :: Int .. length bnds - 1]
                               ty0 = ProdTy $ map snd bnds
                               init = [ C.BlockDecl [cdecl| $ty:(codegenTy ty0) $id:nam = $(fnexp); |] ]
                           tal <- codegenTail venv' fenv body ty sync_deps
                           return $ init ++ zipWith bind bnds fields ++ tal
                         ProdTy _ -> error $ "codegenTail: LetCallT" ++ fromVar ratr
                         _ -> do
                           tal <- codegenTail venv' fenv body ty sync_deps
                           let call = assn (codegenTy (snd bnd)) (fst bnd) (fnexp)
                           return $ [call] ++ tal
    | otherwise = do
       nam <- gensym $ toVar "tmp_struct"
       let bind (v,t) f = assn (codegenTy t) v (C.Member (cid nam) (C.toIdent f noLoc) noLoc)
           fields = map (\i -> "field" ++ show i) [0 :: Int .. length bnds - 1]
           ty0 = ProdTy $ map snd bnds
           init = [ C.BlockDecl [cdecl| $ty:(codegenTy ty0) $id:nam = $(fnexp); |] ]
           venv' = (M.fromList bnds) `M.union` venv
       tal <- codegenTail venv' fenv body ty sync_deps
       return $ init ++ zipWith bind bnds fields ++ tal
  where
    fncall = C.FnCall (cid ratr) (map (codegenTriv venv) rnds) noLoc
    fnexp = C.EscExp (prettyCompact (space <> ppr fncall)) noLoc

codegenTail venv fenv (LetCallT True bnds ratr rnds body) ty sync_deps
    | [] <- bnds = do tal <- codegenTail venv fenv body ty sync_deps
                      return $ [toStmt spawnexp] ++ tal
    | [bnd] <- bnds  = let fn_ret_ty = snd (fenv M.! ratr)
                           venv' = (M.fromList bnds) `M.union` venv in
                       case fn_ret_ty of
                         -- Copied from the otherwise case below.
                         ProdTy [_one] -> do
                           nam <- gensym $ toVar "tmp_struct"
                           let bind (v,t) f = (v, assn (codegenTy t) v (C.Member (cid nam) (C.toIdent f noLoc) noLoc))
                               fields = map (\i -> "field" ++ show i) [0 :: Int .. length bnds - 1]
                               ty0 = ProdTy $ map snd bnds
                               init = [ C.BlockDecl [cdecl| $ty:(codegenTy ty0) $id:nam = $(spawnexp); |] ]
                               bind_after_sync = zipWith bind bnds fields
                           tal <- codegenTail venv' fenv body ty (sync_deps ++ bind_after_sync)
                           return $ init ++ tal
                         ProdTy _ -> error $ "codegenTail: LetCallT" ++ fromVar ratr
                         _ -> do
                           tal <- codegenTail venv' fenv body ty sync_deps
                           let call = assn (codegenTy (snd bnd)) (fst bnd) (spawnexp)
                           return $ [call] ++ tal
    | otherwise = do
       nam <- gensym $ toVar "tmp_struct"
       let bind (v,t) f = (v, assn (codegenTy t) v (C.Member (cid nam) (C.toIdent f noLoc) noLoc))
           fields = map (\i -> "field" ++ show i) [0 :: Int .. length bnds - 1]
           ty0 = ProdTy $ map snd bnds
           init = [ C.BlockDecl [cdecl| $ty:(codegenTy ty0) $id:nam = $(spawnexp); |] ]

       let bind_after_sync = zipWith bind bnds fields
           venv' = (M.fromList bnds) `M.union` venv
       tal <- codegenTail venv' fenv body ty (sync_deps ++ bind_after_sync)
       return $ init ++  tal
  where
    fncall = C.FnCall (cid ratr) (map (codegenTriv venv) rnds) noLoc
    spawnexp = C.EscExp (prettyCompact (text "cilk_spawn" <> space <> ppr fncall)) noLoc
    _seqexp = C.EscExp (prettyCompact (ppr fncall)) noLoc

codegenTail venv fenv (LetPrimCallT bnds prm rnds body) ty sync_deps =
    do let venv' = (M.fromList bnds) `M.union` venv
       bod' <- case prm of
                 ParSync -> codegenTail venv' fenv body ty []
                 _       -> codegenTail venv' fenv body ty sync_deps
       dflags <- getDynFlags
       let isPacked = gopt Opt_Packed dflags
           noGC = gopt Opt_DisableGC dflags

       pre <- case prm of
                 AddP -> let [(outV,outT)] = bnds
                             [pleft,pright] = rnds in pure
                         [ C.BlockDecl [cdecl| $ty:(codegenTy outT) $id:outV = $(codegenTriv venv pleft) + $(codegenTriv venv pright); |] ]
                 SubP -> let (outV,outT) = head bnds
                             [pleft,pright] = rnds in pure
                         [ C.BlockDecl [cdecl| $ty:(codegenTy outT) $id:outV = $(codegenTriv venv pleft) - $(codegenTriv venv pright); |] ]
                 MulP -> let [(outV,outT)] = bnds
                             [pleft,pright] = rnds in pure
                         [ C.BlockDecl [cdecl| $ty:(codegenTy outT) $id:outV = $(codegenTriv venv pleft) * $(codegenTriv venv pright); |]]
                 DivP -> let [(outV,outT)] = bnds
                             [pleft,pright] = rnds in pure
                         [ C.BlockDecl [cdecl| $ty:(codegenTy outT) $id:outV = $(codegenTriv venv pleft) / $(codegenTriv venv pright); |]]
                 ModP -> let [(outV,outT)] = bnds
                             [pleft,pright] = rnds in pure
                         [ C.BlockDecl [cdecl| $ty:(codegenTy outT) $id:outV = $(codegenTriv venv pleft) % $(codegenTriv venv pright); |]]
                 ExpP -> let [(outV,outT)] = bnds
                             [pleft,pright] = rnds in pure
                         [ C.BlockDecl [cdecl| $ty:(codegenTy outT) $id:outV = expll($(codegenTriv venv pleft), $(codegenTriv venv pright)); |]]
                 RandP -> let [(outV,outT)] = bnds in pure
                          [ C.BlockDecl [cdecl| $ty:(codegenTy outT) $id:outV = rand(); |]]
                 FRandP-> let [(outV,outT)] = bnds
                              fty = [cty| typename FloatTy |] in pure
                          [ C.BlockDecl [cdecl| $ty:(codegenTy outT) $id:outV = ($ty:fty) rand() / ($ty:fty) (RAND_MAX); |]]
                 FSqrtP -> let [(outV,outT)] = bnds
                               [arg] = rnds in pure
                           [ C.BlockDecl [cdecl| $ty:(codegenTy outT) $id:outV = sqrt($(codegenTriv venv arg)) ; |]]

                 FloatToIntP -> let [(outV,outT)] = bnds
                                    [arg] = rnds
                                    ity= [cty| typename IntTy |] in pure
                                [ C.BlockDecl [cdecl| $ty:(codegenTy outT) $id:outV = ($ty:ity) ($(codegenTriv venv arg)) ; |]]

                 IntToFloatP -> let [(outV,outT)] = bnds
                                    [arg] = rnds
                                    fty= [cty| typename FloatTy |] in pure
                                [ C.BlockDecl [cdecl| $ty:(codegenTy outT) $id:outV = ($ty:fty) ($(codegenTriv venv arg)) ; |]]

                 EqP -> let [(outV,outT)] = bnds
                            [pleft,pright] = rnds in pure
                        [ C.BlockDecl [cdecl| $ty:(codegenTy outT) $id:outV = ($(codegenTriv venv pleft) == $(codegenTriv venv pright)); |]]
                 LtP -> let [(outV,outT)] = bnds
                            [pleft,pright] = rnds in pure
                        [ C.BlockDecl [cdecl| $ty:(codegenTy outT) $id:outV = ($(codegenTriv venv pleft) < $(codegenTriv venv pright)); |]]
                 GtP -> let [(outV,outT)] = bnds
                            [pleft,pright] = rnds in pure
                        [ C.BlockDecl [cdecl| $ty:(codegenTy outT) $id:outV = ($(codegenTriv venv pleft) > $(codegenTriv venv pright)); |]]
                 LtEqP -> let [(outV,outT)] = bnds
                              [pleft,pright] = rnds in pure
                          [ C.BlockDecl [cdecl| $ty:(codegenTy outT) $id:outV = ($(codegenTriv venv pleft) <= $(codegenTriv venv pright)); |]]
                 GtEqP -> let [(outV,outT)] = bnds
                              [pleft,pright] = rnds in pure
                          [ C.BlockDecl [cdecl| $ty:(codegenTy outT) $id:outV = ($(codegenTriv venv pleft) >= $(codegenTriv venv pright)); |]]
                 OrP -> let [(outV,outT)] = bnds
                            [pleft,pright] = rnds in pure
                        [ C.BlockDecl [cdecl| $ty:(codegenTy outT) $id:outV = ($(codegenTriv venv pleft) || $(codegenTriv venv pright)); |]]
                 AndP -> let [(outV,outT)] = bnds
                             [pleft,pright] = rnds in pure
                        [ C.BlockDecl [cdecl| $ty:(codegenTy outT) $id:outV = ($(codegenTriv venv pleft) && $(codegenTriv venv pright)); |]]
                 DictInsertP _ -> let [(outV,ty)] = bnds
                                      [(VarTriv arena),(VarTriv dict),keyTriv,valTriv] = rnds in pure
                    [ C.BlockDecl [cdecl| $ty:(codegenTy ty) $id:outV = dict_insert_ptr($id:arena, $id:dict, $(codegenTriv venv keyTriv), $(codegenTriv venv valTriv)); |] ]
                 DictLookupP _ -> let [(outV,ty)] = bnds
                                      [(VarTriv dict),keyTriv] = rnds in pure
                    [ C.BlockDecl [cdecl| $ty:(codegenTy ty) $id:outV = dict_lookup_ptr($id:dict, $(codegenTriv venv keyTriv)); |] ]
                 DictEmptyP _ty -> let [(outV,ty)] = bnds
                                   in pure [ C.BlockDecl [cdecl| $ty:(codegenTy ty) $id:outV = 0; |] ]
                 DictHasKeyP PtrTy -> let [(outV,IntTy)] = bnds
                                          [(VarTriv dict)] = rnds in pure
                    [ C.BlockDecl [cdecl| $ty:(codegenTy IntTy) $id:outV = dict_has_key_ptr($id:dict); |] ]
                 DictHasKeyP _ -> error $ "codegen: " ++ show prm ++ "unhandled."

                 NewBuffer mul -> do
                   let [(reg, CursorTy),(outV,CursorTy)] = bnds
                       bufsize = codegenMultiplicity mul
                   pure
                     [ C.BlockDecl [cdecl| $ty:(codegenTy RegionTy)* $id:reg = alloc_region($id:bufsize); |]
                     , C.BlockDecl [cdecl| $ty:(codegenTy CursorTy) $id:outV = $id:reg->start_ptr; |]
                     ]
                 ScopedBuffer mul -> let [(outV,CursorTy)] = bnds
                                         bufsize = codegenMultiplicity mul
                                     in pure
                             [ C.BlockDecl [cdecl| $ty:(codegenTy CursorTy) $id:outV = ( $ty:(codegenTy CursorTy) )ALLOC_SCOPED($id:bufsize); |] ]

                 InitSizeOfBuffer mul -> let [(sizev,IntTy)] = bnds
                                             bufsize = codegenMultiplicity mul
                                         in pure
                                            [ C.BlockDecl [cdecl| $ty:(codegenTy IntTy) $id:sizev = $id:bufsize; |] ]

                 FreeBuffer -> if noGC
                               then pure []
                               else
                                 let [(VarTriv reg),(VarTriv _rcur),(VarTriv endr_cur)] = rnds
                                 in pure
                                 [ C.BlockStm [cstm| if ($id:reg->refcount != REG_FREED) { free_region($id:endr_cur); }  |]
                                 , C.BlockStm [cstm| free($id:reg); |]
                                 ]

                 WriteTag -> let [(outV,CursorTy)] = bnds
                                 [(TagTriv tag),(VarTriv cur)] = rnds in pure
                             [ C.BlockStm [cstm| *($id:cur) = $tag; |]
                             , C.BlockDecl [cdecl| $ty:(codegenTy CursorTy) $id:outV = $id:cur + 1; |] ]
                 ReadTag -> let [(tagV,TagTyPacked),(curV,CursorTy)] = bnds
                                [(VarTriv cur)] = rnds in pure
                            [ C.BlockDecl [cdecl| $ty:(codegenTy TagTyPacked) $id:tagV = *($id:cur); |]
                            , C.BlockDecl [cdecl| $ty:(codegenTy CursorTy) $id:curV = $id:cur + 1; |] ]

                 WriteScalar s -> let [(outV,CursorTy)] = bnds
                                      [val,(VarTriv cur)] = rnds in pure
                                  [ C.BlockStm [cstm| *( $ty:(codegenTy (scalarToTy s))  *)($id:cur) = $(codegenTriv venv val); |]
                                  , C.BlockDecl [cdecl| $ty:(codegenTy CursorTy) $id:outV = ($id:cur) + sizeof( $ty:(codegenTy (scalarToTy s)) ); |] ]

                 ReadScalar s -> let [(valV,valTy),(curV,CursorTy)] = bnds
                                     [(VarTriv cur)] = rnds in pure
                                     [ C.BlockDecl [cdecl| $ty:(codegenTy valTy) $id:valV = *( $ty:(codegenTy valTy) *)($id:cur); |]
                                     , C.BlockDecl [cdecl| $ty:(codegenTy CursorTy) $id:curV = ($id:cur) + sizeof( $ty:(codegenTy (scalarToTy s))); |] ]

                 ReadCursor -> let [(next,CursorTy),(afternext,CursorTy)] = bnds
                                   [(VarTriv cur)] = rnds in pure
                               [ C.BlockDecl [cdecl| $ty:(codegenTy CursorTy) $id:next = *($ty:(codegenTy CursorTy) *) ($id:cur); |]
                               , C.BlockDecl [cdecl| $ty:(codegenTy CursorTy) $id:afternext = ($id:cur) + 8; |]
                               ]

                 WriteCursor -> let [(outV,CursorTy)] = bnds
                                    [val,(VarTriv cur)] = rnds in pure
                                 [ C.BlockStm [cstm| *( $ty:(codegenTy CursorTy)  *)($id:cur) = $(codegenTriv venv val); |]
                                 , C.BlockDecl [cdecl| $ty:(codegenTy CursorTy) $id:outV = ($id:cur) + 8; |] ]

                 BumpRefCount -> let [(VarTriv end_r1), (VarTriv end_r2)] = rnds
                                 in pure [ C.BlockStm [cstm| bump_ref_count($id:end_r1, $id:end_r2); |] ]

                 BoundsCheck -> do
                   new_chunk   <- gensym "new_chunk"
                   chunk_start <- gensym "chunk_start"
                   chunk_end   <- gensym "chunk_end"
                   let [(IntTriv i),(VarTriv bound), (VarTriv cur)] = rnds
                       bck = [ C.BlockDecl [cdecl| $ty:(codegenTy ChunkTy) $id:new_chunk = alloc_chunk($id:bound); |]
                             , C.BlockDecl [cdecl| $ty:(codegenTy CursorTy) $id:chunk_start = $id:new_chunk.start_ptr; |]
                             , C.BlockDecl [cdecl| $ty:(codegenTy CursorTy) $id:chunk_end = $id:new_chunk.end_ptr; |]
                             , C.BlockStm  [cstm|  $id:bound = $id:chunk_end; |]
                             , C.BlockStm  [cstm|  *($ty:(codegenTy TagTyPacked) *) ($id:cur) = ($int:(GL.redirectionAlt)); |]
                             , C.BlockDecl [cdecl| $ty:(codegenTy CursorTy) redir =  $id:cur + 1; |]
                             , C.BlockStm  [cstm|  *($ty:(codegenTy CursorTy) *) redir = $id:chunk_start; |]
                             , C.BlockStm  [cstm|  $id:cur = $id:chunk_start; |]
                             ]
                   return [ C.BlockStm [cstm| if (($id:cur + $int:i) > $id:bound) { $items:bck }  |] ]

                 SizeOfPacked -> let [(sizeV,IntTy)] = bnds
                                     [(VarTriv startV), (VarTriv endV)] = rnds
                                 in pure
                                   [ C.BlockDecl [cdecl| $ty:(codegenTy IntTy) $id:sizeV = $id:endV - $id:startV; |] ]
                 SizeOfScalar -> let [(sizeV,IntTy)] = bnds
                                     [(VarTriv w)]   = rnds
                                 in pure
                                   [ C.BlockDecl [cdecl| $ty:(codegenTy IntTy) $id:sizeV = sizeof($id:w); |] ]


                 GetFirstWord ->
                  let [ptr] = rnds in
                  case bnds of
                    [(outV,outTy)] -> pure
                     [ C.BlockDecl [cdecl|
                            $ty:(codegenTy outTy) $id:outV =
                              * (( $ty:(codegenTy outTy) *) $(codegenTriv venv ptr));
                          |] ]
                    _ -> error $ "wrong number of return bindings from GetFirstWord: "++show bnds

                 SizeParam -> let [(outV,IntTy)] = bnds in pure
                      [ C.BlockDecl [cdecl| $ty:(codegenTy IntTy) $id:outV = global_size_param; |] ]

                 PrintInt ->
                     let [arg] = rnds in
                     case bnds of
                       [(outV,IntTy)] -> pure [ C.BlockDecl [cdecl| $ty:(codegenTy IntTy) $id:outV = printf("%lld", $(codegenTriv venv arg)); |] ]
                       [] -> pure [ C.BlockStm [cstm| printf("%lld", $(codegenTriv venv arg)); |] ]
                       _ -> error $ "wrong number of return bindings from PrintInt: "++show bnds

                 PrintFloat ->
                     let [arg] = rnds in
                     case bnds of
                       [(outV,FloatTy)] -> pure [ C.BlockDecl [cdecl| $ty:(codegenTy FloatTy) $id:outV = printf("%lf", $(codegenTriv venv arg)); |] ]
                       [] -> pure [ C.BlockStm [cstm| printf("%f", $(codegenTriv venv arg)); |] ]
                       _ -> error $ "wrong number of return bindings from PrintInt: "++show bnds

                 PrintSym ->
                     let [arg] = rnds in
                     case bnds of
                       [(outV,ty)] -> pure [ C.BlockDecl [cdecl| $ty:(codegenTy ty) $id:outV = print_symbol($(codegenTriv venv arg)); |] ]
                       [] -> pure [ C.BlockStm [cstm| print_symbol($(codegenTriv venv arg)); |] ]
                       _ -> error $ "wrong number of return bindings from PrintSym: "++show bnds

                 PrintString str
                     | [] <- bnds, [] <- rnds -> pure [ C.BlockStm [cstm| fputs( $string:str, stdout ); |] ]
                     | otherwise -> error$ "wrong number of args/return values expected from PrintString prim: "++show (rnds,bnds)

                 -- FINISHME: Codegen here depends on whether we are in --packed mode or not.
                 ReadPackedFile mfile tyc
                     | [] <- rnds, [(outV,_outT)] <- bnds -> do
                             let filename = case mfile of
                                              Just f  -> [cexp| $string:f |] -- Fixed at compile time.
                                              Nothing -> [cexp| read_benchfile_param() |] -- Will be set by command line arg.
                                 unpackName = GL.mkUnpackerName tyc
                                 unpackcall = LetCallT False [(outV,PtrTy),(toVar "junk",CursorTy)]
                                                    unpackName [VarTriv (toVar "ptr")] (AssnValsT [] Nothing)

                                 mmap_size = varAppend outV "_size"

                                 mmapCode =
                                  [ C.BlockDecl[cdecl| int fd = open( $filename, O_RDONLY); |]
                                  , C.BlockStm[cstm| { if(fd == -1) { fprintf(stderr,"fopen failed\n"); abort(); }} |]
                                  , C.BlockDecl[cdecl| struct stat st; |]
                                  , C.BlockStm  [cstm| fstat(fd, &st); |]
                                  , C.BlockDecl [cdecl| $ty:(codegenTy IntTy) $id:mmap_size = st.st_size;|]
                                  , C.BlockDecl[cdecl| $ty:(codegenTy CursorTy) ptr = ($ty:(codegenTy CursorTy)) mmap(0,st.st_size,PROT_READ,MAP_PRIVATE,fd,0); |]
                                  , C.BlockStm[cstm| { if(ptr==MAP_FAILED) { fprintf(stderr,"mmap failed\n"); abort(); }} |]
                                  ]
                             docall <- if isPacked
                                       -- In packed mode we eagerly FORCE the IO to happen before we start benchmarking:
                                       then pure [ C.BlockStm [cstm| { int sum=0; for(int i=0; i < st.st_size; i++) sum += ptr[i]; } |]
                                                 , C.BlockDecl [cdecl| $ty:(codegenTy CursorTy) $id:outV = ptr; |]]
                                       else codegenTail venv fenv unpackcall voidTy sync_deps
                             return $ mmapCode ++ docall
                     | otherwise -> error $ "ReadPackedFile, wrong arguments "++show rnds++", or expected bindings "++show bnds

                 ReadArrayFile mfile ty
                   | [] <- rnds, [(outV,_outT)] <- bnds -> do
                           let filename = case mfile of
                                            Just f  -> [cexp| $string:f |] -- Fixed at compile time.
                                            Nothing -> [cexp| read_arrayfile_param() |] -- Will be set by command line arg.
                           let ty_name  = case ty of
                                            IntTy      -> makeName' ty
                                            ProdTy tys -> makeName tys
                                            _ -> error $ "ReadArrayFile: Lists of type " ++ sdoc ty ++ " not allowed."
                               icd_name = ty_name ++ "_icd"
                               parse_in_c t = case t of
                                                IntTy   -> "%lld"
                                                FloatTy -> "%f"
                                                _ -> error $ "ReadArrayFile: Lists of type " ++ sdoc ty ++ " not allowed."

                           elem <- gensym "arr_elem"
                           fp <- gensym "fp"
                           line <- gensym "line"
                           len <- gensym "len"
                           read <- gensym "read"

                           (tmps, tmps_parsers, tmps_assns, tmps_decls) <-
                                 case ty of
                                     IntTy -> do
                                       one <- gensym "tmp"
                                       let assn = C.BlockStm [cstm| $id:elem = $id:one ; |]
                                       pure ([one], [parse_in_c ty], [ assn ], [ C.BlockDecl [cdecl| $ty:(codegenTy IntTy) $id:one; |] ])
                                     FloatTy -> do
                                       one <- gensym "tmp"
                                       let assn = C.BlockStm [cstm| $id:elem = $id:one ; |]
                                       pure ([one], [parse_in_c ty], [ assn ], [ C.BlockDecl [cdecl| $ty:(codegenTy FloatTy) $id:one; |] ])
                                     ProdTy tys -> do
                                       vs <- mapM (\_ -> gensym "tmp") tys
                                       let decls = map (\(name, t) -> C.BlockDecl [cdecl| $ty:(codegenTy t) $id:name; |] ) (zip vs tys)
                                           parsers = map parse_in_c tys
                                           assns = map (\(v, i) ->
                                                           let field = "field" ++ (show i)
                                                           in C.BlockStm [cstm| $id:elem.$id:field = $id:v; |])
                                                   (zip vs [0..])
                                       pure (vs, parsers, assns, decls)
                                     _ -> error $ "ReadArrayFile: Lists of type " ++ sdoc ty ++ " not allowed."

                           let scanf_vars   = map (\v -> [cexp| &($id:v) |]) tmps
                               scanf_line = [cexp| $id:line |]
                               scanf_format = [cexp| $string:(intercalate " " tmps_parsers) |]
                               scanf_rator  = C.Var (C.Id "sscanf" noLoc) noLoc
                               scanf = C.FnCall scanf_rator (scanf_line : scanf_format : scanf_vars) noLoc

                           return $
                                  [ C.BlockDecl [cdecl| $ty:(codegenTy (ListTy ty)) ($id:outV); |]
                                  , C.BlockStm  [cstm| utarray_new($id:outV,&($id:icd_name)); |]
                                  , C.BlockDecl [cdecl| $ty:(codegenTy ty) $id:elem; |]
                                  , C.BlockStm  [cstm| FILE *($id:fp); |]
                                  , C.BlockDecl [cdecl| char *($id:line) = NULL; |]
                                  , C.BlockStm [cstm| size_t ($id:len); |]
                                  , C.BlockStm [cstm| $id:len = 0; |]
                                  , C.BlockStm [cstm| ssize_t ($id:read); |]
                                  , C.BlockStm [cstm| $id:fp = fopen( $filename, "r"); |]
                                  , C.BlockStm [cstm| { if($id:fp == NULL) { fprintf(stderr,"fopen failed\n"); abort(); }} |]
                                  ] ++ tmps_decls ++
                                  [ C.BlockStm [cstm| while(($id:read = getline(&($id:line), &($id:len), $id:fp)) != -1) {
                                                      int xxxx = $scanf;
                                                      $items:tmps_assns
                                                      utarray_push_back($id:outV, &($id:elem));
                                                    } |]
                                  ]

                   | otherwise -> error $ "ReadPackedFile, wrong arguments "++show rnds++", or expected bindings "++show bnds

                 MMapFileSize v -> do
                       let [(outV,IntTy)] = bnds
                           -- Must match with mmap_size set by ReadPackedFile
                           mmap_size = varAppend v "_size"
                       return [ C.BlockDecl[cdecl| $ty:(codegenTy IntTy) $id:outV = $id:mmap_size; |] ]

                 ParSync -> do
                    let e = [cexp| cilk_sync |]
                    return $ [ C.BlockStm [cstm| $exp:e; |] ] ++ (map snd sync_deps)

                 GetCilkWorkerNum -> do
                   let [(outV, IntTy)] = bnds
                       e = [cexp| __cilkrts_get_worker_number() |]
                   return $ [ C.BlockDecl [cdecl| $ty:(codegenTy IntTy) $id:outV = $exp:e; |] ]

                 Gensym  -> do
                   let [(outV,SymTy)] = bnds
                   return [ C.BlockDecl [cdecl| $ty:(codegenTy SymTy) $id:outV = gensym(); |] ]

                 FreeSymTable -> return [C.BlockStm [cstm| free_symtable(); |]]

                 VEmptyP ty  -> do
                   let ty_name  = case ty of
                         IntTy      -> makeName' ty
                         ProdTy tys -> makeName tys
                         _ -> "VEmptyP: Lists of type " ++ sdoc ty ++ " not allowed."
                       icd_name = ty_name ++ "_icd"
                       [(outV,_)]  = bnds
                   return [ C.BlockDecl [cdecl| $ty:(codegenTy (ListTy ty)) ($id:outV); |]
                          , C.BlockStm  [cstm| utarray_new($id:outV,&($id:icd_name)); |] ]

                 VNthP ty    -> do
                   let ty1 = codegenTy ty
                       [(outV,_)] = bnds
                       [i, VarTriv ls] = rnds
                   tmp <- gensym "tmp"
                   return [ C.BlockDecl [cdecl| $ty:ty1 *($id:tmp); |]
                          , C.BlockStm  [cstm| $id:tmp = ($ty:ty1 *) utarray_eltptr($id:ls,$(codegenTriv venv i)); |]
                          , C.BlockDecl [cdecl| $ty:ty1 $id:outV = *($id:tmp); |]
                          ]

                 VLengthP{} -> do
                   let [(v,IntTy)] = bnds
                       [VarTriv ls] = rnds
                   return [ C.BlockDecl [cdecl| $ty:(codegenTy IntTy) $id:v = ($ty:(codegenTy IntTy)) utarray_len($id:ls); |] ]

                 VUpdateP{} -> return []

                 -- This is not a side effect. It creates a copy of the old list.
                 VSnocP ty   -> do
                   let [(outV,_)] = bnds
                       [(VarTriv old_ls), val] = rnds
                       trv = codegenTriv venv val
                       ty1 = codegenTy ty
                       ty_name  = case ty of
                         IntTy      -> makeName' ty
                         ProdTy tys -> makeName tys
                         _ -> "codegenTail: Lists of type " ++ sdoc ty ++ " not allowed."
                       icd_name = ty_name ++ "_icd"
                   tmp <- gensym "tmp"
                   return [ C.BlockDecl [cdecl| $ty:(codegenTy (ListTy ty)) ($id:outV); |]
                          , C.BlockStm  [cstm| utarray_new($id:outV,&($id:icd_name)); |]
                          , C.BlockStm  [cstm| utarray_concat($id:outV,$id:old_ls); |]
                          , C.BlockDecl [cdecl| $ty:ty1 ($id:tmp) = $trv; |]
                          , C.BlockStm  [cstm| utarray_push_back($id:outV, &($id:tmp)); |]
                          ]
                 VSortP ty -> do
                   let [(outV,_)] = bnds
                       [VarTriv old_ls, VarTriv sort_fn] = rnds
                       ty_name  = case ty of
                         IntTy      -> makeName' ty
                         ProdTy tys -> makeName tys
                         _ -> "codegenTail: Lists of type " ++ sdoc ty ++ " not allowed."
                       icd_name = ty_name ++ "_icd"
                   return [ C.BlockDecl [cdecl| $ty:(codegenTy (ListTy ty)) ($id:outV); |]
                          , C.BlockStm [cstm| utarray_new($id:outV,&($id:icd_name)); |]
                          , C.BlockStm [cstm| utarray_inserta($id:outV,$id:old_ls,0); |]
                          , C.BlockStm [cstm| utarray_sort($id:outV, $id:sort_fn); |]
                          ]

                 InPlaceVSnocP ty   -> do
                   let [(VarTriv old_ls), val] = rnds
                       trv = codegenTriv venv val
                       ty1 = codegenTy ty
                   tmp <- gensym "tmp"
                   return [ C.BlockDecl [cdecl| $ty:ty1 ($id:tmp) = $trv; |]
                          , C.BlockStm  [cstm| utarray_push_back($id:old_ls, &($id:tmp)); |]
                          ]

                 InPlaceVSortP _ty -> do
                   let [VarTriv old_ls, VarTriv sort_fn] = rnds
                   return [ C.BlockStm [cstm| utarray_sort($id:old_ls, $id:sort_fn); |] ]

                 VSliceP ty -> do
                   let [(outV,_)] = bnds
                       [VarTriv old_ls, from, to] = rnds
                       ty_name  = case ty of
                         IntTy      -> makeName' ty
                         ProdTy tys -> makeName tys
                         _ -> "codegenTail: Lists of type " ++ sdoc ty ++ " not allowed."
                       icd_name = ty_name ++ "_icd"
                   from_v <- gensym "from"
                   to_v <- gensym "to"
                   len <- gensym "len"
                   return [ C.BlockDecl [cdecl| $ty:(codegenTy (ListTy ty)) ($id:outV); |]
                          , C.BlockStm [cstm| utarray_new($id:outV,&($id:icd_name)); |]
                          , C.BlockStm [cstm| utarray_inserta($id:outV,$id:old_ls,0); |]
                          , C.BlockDecl [cdecl| $ty:(codegenTy IntTy) $id:from_v = $(codegenTriv venv from); |]
                          , C.BlockDecl [cdecl| $ty:(codegenTy IntTy) $id:to_v = $(codegenTriv venv to); |]
                          , C.BlockDecl [cdecl| int $id:len = utarray_len($id:outV); |]
                          , C.BlockStm [cstm| utarray_erase($id:outV, 0, $id:from_v); |]
                          , C.BlockStm [cstm| utarray_erase($id:outV, $id:to_v, $id:len - $id:to_v); |]
                          ]

                 BumpArenaRefCount{} -> error "codegen: BumpArenaRefCount not handled."
                 ReadInt{} -> error "codegen: ReadInt not handled."

       return $ pre ++ bod'

codegenTail _ _ (Goto lbl) _ty _ = do
  return [ C.BlockStm [cstm| goto $id:lbl; |] ]

-- | The sizes for all mulitplicities are defined as globals in the RTS.
-- Note: Must be consistent with the names in RTS!
codegenMultiplicity :: Multiplicity -> Var
codegenMultiplicity mul =
  case mul of
    BigInfinite -> toVar "global_init_biginf_buf_size"
    Infinite    -> toVar "global_init_inf_buf_size"
    Bounded     -> error $ "codegenMultiplicity: Bounded buffers not handled yet."


splitAlts :: Alts -> (Alts, Alts)
splitAlts (TagAlts ls) = (TagAlts (init ls), TagAlts [last ls])
splitAlts (IntAlts ls) = (IntAlts (init ls), IntAlts [last ls])

-- | Take a "singleton" Alts and extract the Tail.
altTail :: Alts -> Tail
altTail (TagAlts [(_,t)]) = t
altTail (IntAlts [(_,t)]) = t
altTail oth = error $ "altTail expected a 'singleton' Alts, got: "++ abbrv 80 oth


-- Helper for lhs of a case
mk_tag_lhs :: (Integral a, Show a) => a -> C.Exp
mk_tag_lhs lhs = C.Const (C.IntConst (show lhs) C.Unsigned (fromIntegral lhs) noLoc) noLoc

mk_int_lhs :: (Integral a, Show a) => a -> C.Exp
mk_int_lhs lhs = C.Const (C.IntConst (show lhs) C.Signed   (fromIntegral lhs) noLoc) noLoc

normalizeAlts :: Alts -> [(C.Exp, Tail)]
normalizeAlts alts =
    case alts of
      TagAlts as -> map (first mk_tag_lhs) as
      IntAlts as -> map (first mk_int_lhs) as

-- | Generate a proper switch expression instead.
genSwitch :: VEnv -> FEnv -> Label -> Triv -> Alts -> Tail -> Ty -> SyncDeps -> PassM [C.BlockItem]
genSwitch venv fenv lbl tr alts lastE ty sync_deps =
    do let go :: [(C.Exp,Tail)] -> PassM [C.Stm]
           go [] = do tal <- codegenTail venv fenv lastE ty sync_deps
                      return [[cstm| default: $stm:(mkBlock tal) |]]
           go ((ex,tl):rst) =
               do tal <- codegenTail venv fenv tl ty sync_deps
                  let tal2 = tal ++ [ C.BlockStm [cstm| break; |] ]
                  let this = [cstm| case $exp:ex : $stm:(mkBlock tal2) |]
                  rst' <- go rst
                  return (this:rst')
       alts' <- go (normalizeAlts alts)
       let body = mkBlock [ C.BlockStm a | a <- alts' ]
       return $ [ C.BlockStm [cstm| $id:lbl: ; |]
                , C.BlockStm [cstm| switch ( $exp:(codegenTriv venv tr) ) $stm:body |]]

-- | The identifier after typename refers to typedefs defined in rts.c
--
codegenTy :: Ty -> C.Type
codegenTy IntTy = [cty|typename IntTy|]
codegenTy FloatTy= [cty|typename FloatTy|]
codegenTy BoolTy = [cty|typename BoolTy|]
codegenTy TagTyPacked = [cty|typename TagTyPacked|]
codegenTy TagTyBoxed  = [cty|typename TagTyBoxed|]
codegenTy SymTy = [cty|typename SymTy|]
codegenTy PtrTy = [cty|typename PtrTy|] -- char* - Hack, this could be void* if we have enough casts. [2016.11.06]
codegenTy CursorTy = [cty|typename CursorTy|]
codegenTy RegionTy = [cty|typename RegionTy|]
codegenTy ChunkTy = [cty|typename ChunkTy|]
codegenTy (ProdTy []) = [cty|void*|]
codegenTy (ProdTy ts) = C.Type (C.DeclSpec [] [] (C.Tnamed (C.Id nam noLoc) [] noLoc) noLoc) (C.DeclRoot noLoc) noLoc
    where nam = makeName ts
codegenTy (SymDictTy _ _t) = C.Type (C.DeclSpec [] [] (C.Tnamed (C.Id "dict_item_t*" noLoc) [] noLoc) noLoc) (C.DeclRoot noLoc) noLoc
codegenTy ArenaTy = [cty|typename ArenaTy|]
codegenTy ListTy{} = [cty|typename UT_array* |]

makeName :: [Ty] -> String
makeName tys = concatMap makeName' tys ++ "Prod"

makeName' :: Ty -> String
makeName' IntTy       = "Int64"
makeName' FloatTy     = "Float32"
makeName' SymTy       = "Sym"
makeName' BoolTy      = "Bool"
makeName' CursorTy    = "Cursor"
makeName' TagTyPacked = "Tag"
makeName' TagTyBoxed  = makeName' IntTy
makeName' PtrTy = "Ptr"
makeName' (SymDictTy _ _ty) = "Dict"
makeName' RegionTy = "Region"
makeName' ChunkTy  = "Chunk"
makeName' ArenaTy  = "Arena"
makeName' ListTy{} = "Vector"
makeName' (ProdTy tys) = "Prod" ++ concatMap makeName' tys

mkBlock :: [C.BlockItem] -> C.Stm
mkBlock ss = C.Block ss noLoc

cid :: Var -> C.Exp
cid v = C.Var (C.toIdent v noLoc) noLoc

toStmt :: C.Exp -> C.BlockItem
toStmt x = C.BlockStm [cstm| $exp:x; |]

-- | Create a NEW lexical binding.
assn :: (C.ToIdent v, C.ToExp e) => C.Type -> v -> e -> C.BlockItem
assn t x y = C.BlockDecl [cdecl| $ty:t $id:x = $exp:y; |]

-- | Mutate an existing binding:
mut :: (C.ToIdent v, C.ToExp e) => C.Type -> v -> e -> C.BlockItem
mut _t x y = C.BlockStm [cstm| $id:x = $exp:y; |]
