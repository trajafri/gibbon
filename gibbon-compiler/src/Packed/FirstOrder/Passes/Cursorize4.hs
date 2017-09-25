{-# LANGUAGE OverloadedStrings #-}

module Packed.FirstOrder.Passes.Cursorize4
  (cursorize) where

import Data.Loc
import Data.List as L
import Data.Map as M

import Packed.FirstOrder.Common    hiding (FunDefs, FunDef(..))
import Packed.FirstOrder.L1.Syntax hiding (Prog(..), FunDef(..), FunDefs)
import Packed.FirstOrder.L2.Syntax as L2
import qualified Packed.FirstOrder.L3.Syntax as L3

import Debug.Trace
--------------------------------------------------------------------------------

-- keeps a track of all the `Packed Ty loc` variables in L2 IR. Since all packed types go
-- to the dilated (start,end) form, we refer to this environment when processing var references
type TEnv = M.Map Var Ty2

-- |
cursorize :: Prog -> SyM L3.Prog
cursorize Prog{ddefs,fundefs,mainExp} = do
  fns' <- mapM (fd . snd) (M.toList fundefs)
  let fundefs' = M.fromList $ L.map (\f -> (L3.funname f, f)) fns'
      ddefs'   = M.map L3.eraseLocMarkers ddefs

  mainExp' <- case mainExp of
                Nothing -> return Nothing
                Just (e,ty) -> do
                  e' <- case ty of
                          _ | isPackedTy ty  -> cursorizePackedExp ddefs M.empty e
                          _ | hasPacked ty   -> error $ "TODO: hasPacked mainExp"
                          _ -> cursorizeExp ddefs M.empty e
                  return $ Just (e', L3.stripTyLocs ty)

  return $ L3.Prog ddefs' fundefs' mainExp'

  where

    fd :: FunDef -> SyM L3.FunDef
    fd FunDef{funname,funty,funarg,funbod} = do
      newarg <- gensym (varAppend "tup_arg_" funname)

      let lvars   = locVars funty
          mInloc  = L.find (\(LRM _ _ m) -> m == Input) lvars
          mOutLoc = L.find (\(LRM _ _ m) -> m == Output) lvars

          inT  = arrIn funty
          outT = arrOut funty

          -- FIXME: temporary, need to create a proper type for each case
          funty' = L3.cursorizeTy funty

      L3.FunDef funname funty' newarg <$>

        case (mInloc,mOutLoc) of
          -- Eg. add1, copyTree
          (Just inLoc, Just outLoc) -> do

            l<$> (LetE (lrmLoc outLoc,[], CursorTy, l$ ProjE 0 (l$ VarE newarg)) <$>
                  (l<$> (LetE (lrmLoc inLoc,[], CursorTy, l$ ProjE 1 (l$ VarE newarg)) <$>
                         (l<$> (LetE (funarg,[],CursorTy, l$ VarE (lrmLoc inLoc)) <$>
                                cursorizePackedExp ddefs M.empty funbod)))))

          -- Eg. leftmost
          (Just inLoc, Nothing) ->

            l<$> (LetE (lrmLoc inLoc,[], CursorTy, l$ ProjE 0 (l$ VarE newarg)) <$>
                   (l<$> (LetE (funarg,[],CursorTy, l$ VarE (lrmLoc inLoc)) <$>
                          cursorizeExp ddefs M.empty funbod)))

          -- Eg. buildLeaf
          (Nothing, Just outLoc) ->

            l<$> (LetE (lrmLoc outLoc,[], CursorTy, l$ ProjE 0 (l$ VarE newarg)) <$>
                   (l<$> (LetE (funarg,[],CursorTy, l$ VarE (lrmLoc outLoc)) <$>
                          cursorizePackedExp ddefs M.empty funbod)))

          -- Eg. intAdd
          (Nothing, Nothing) ->
            if (hasPacked inT || hasPacked outT)
            then error $ "Non-packed types expected, but got: " ++ sdoc inT ++ "\n" ++ sdoc outT
            else cursorizeExp ddefs M.empty funbod


-- | Cursorize expressions NOT producing `Packed` values
cursorizeExp :: DDefs Ty2 -> TEnv -> L Exp2 -> SyM (L L3.Exp3)
cursorizeExp ddfs tenv (L p ex) = L p <$>
  case ex of
    VarE v    -> return $ VarE v
    LitE n    -> return $ LitE n
    LitSymE n -> return $ LitSymE n

    AppE f locs arg ->
      if locs /= []
      then error $ "cursorizeExp: AppE expected empty locs for scalar values. Got: " ++ sdoc locs
      else AppE f [] <$> go arg

    PrimAppE pr args -> PrimAppE pr <$> mapM go args

    LetE (v,locs,ty,rhs) bod
      | isPackedTy ty -> error $ "cursorizeExp: TOOD isPacked LetE"
      | hasPacked ty  -> error $ "cursorizeExp: TOOD hasPacked LetE"
      | otherwise ->
          if locs /= []
          then error $ "cursorizeExp: LetE expected empty locs for scalar values. Got " ++ sdoc locs
          else do
            rhs' <- go rhs
            LetE (v,[],L3.stripTyLocs ty,rhs') <$>
              cursorizeExp ddfs (M.insert v ty tenv) bod

    IfE a b c  -> IfE <$> go a <*> go b <*> go c

    MkProdE ls -> MkProdE <$> mapM go ls

    ProjE i e  -> ProjE i <$> go e

    -- Eg. leftmost
    CaseE _scrtE _ls -> error $ "TODO: cursorizeExp " ++ sdoc ex

    DataConE _ _ _ -> error $ "cursorizeExp: Should not have encountered DataConE if type is not packed: "++ndoc ex

    TimeIt e ty b -> TimeIt <$> go e <*> pure (L3.stripTyLocs ty) <*> pure b

    -- Eg. leftmost
    Ext ext ->
      case ext of
        -- Since we're returning a scalar value, locs should be empty here...
        -- Also, we don't have to dilate this return value
        RetE locs v ->
          if locs /= []
          then error $ "cursorizeExp: RetE expected empty locs for scalar values. Got" ++ sdoc locs
          else return $ VarE v

        _ -> error $ "TODO: cursorizeExp " ++ sdoc ext

    oth -> error $ "TODO: cursorizeExp" ++ sdoc oth

  where
    go = cursorizeExp ddfs tenv


-- Cursorize expressions producing `Packed` values
cursorizePackedExp :: DDefs Ty2 -> TEnv -> L Exp2 -> SyM (L L3.Exp3)
cursorizePackedExp _ddfs _tenv (L p ex) = L p <$>
  case ex of
    oth -> error $ "TODO: cursorizeExp" ++ sdoc oth


{-
cursorizeExp :: DDefs Ty2 -> TEnv -> L Exp2 -> SyM (L L3.Exp3)
cursorizeExp ddfs tenv (L p exp) = L p <$>
  case exp of
    -- If the variable had a `Packed _ T`, it's going to be transformed to
    -- (start,end) cursors
    VarE v    -> case M.lookup v tenv of
                   Nothing -> return $ VarE v
                   -- (isPackedTy ty) is always going to be true here. tenv only stores
                   -- variables who had packed types
                   Just ty | isPackedTy ty -> return $ MkProdE [l$ VarE v, l$ VarE (toEndV v)]
                   oth -> error $ "unexpected variable type: " ++ sdoc oth

    LitE n    -> return $ LitE n
    LitSymE v -> return $ LitSymE v

    -- A case expression is eventually transformed into a ReadTag + switch statement.
    -- We first retrieve the cursor referred to by the scrutinee, and unpack
    -- the first bound variable 1 byte after that cursor. Thats all we need to do here,
    -- because we've already computed other locations in InferLocations and RouteEnds
    CaseE (L _ (VarE v)) brs ->
          {- generate a ReadTag here, instead of doing it in Lower ...

          cursorAfterTag <- gensym (toVar "cursor_after_tag")
          traceShow lrm (return __)
          maintain all the same properties as the cursor for v
          let cursorAfterTagLrm = cursorizeLRM "_" lrm
          (LetE (cursorAfterTag,[],
                 CursorTy cursorAfterTagLrm,
                 l$ Ext $ L3.ReadTag loc)) <$>
            (l<$> CaseE (l$ VarE cursorAfterTag)) <$>
                    mapM (unpackDataCon cursorAfterTagLrm) brs

          -}
      CaseE (l$ VarE $ v) <$>
        mapM (unpackDataCon v) brs

    -- Trivial case
    PrimAppE pr args -> PrimAppE pr <$> mapM go args

    -- Here we switch to a convention where functions accept (output,input) cursors
    -- and return end-witnesses. Since we already know the abstract locations to which
    -- these values flow to, the actual fn arguments are unused!
    -- TODO: AUTIT ME
    AppE f locs _args ->
      case locs of
        (iploc:oploc:[]) -> do
          return $ AppE f [] (l$ MkProdE [l$ VarE oploc, l$ VarE iploc])
        _ -> error $ "cursorizing AppE: unexpected number of locations: " ++ show locs

    -- TODO: AUTIT ME
    -- Right now, we return a (Cursor,Cursor) pair i.e (start, end)
    DataConE sloc dcon args -> do
      let
          -- Return (start,end) cursors
          -- The final return value lives at the position of the out cursors:
          go2 d [] = return $ MkProdE [l$ VarE sloc, l$ VarE d]

          go2 _d ((rnd, ty):rst) | isPackedTy ty = do
            d' <- gensym $ toVar "writepackedcur"
            let (L _ (VarE v)) = rnd
            LetE (d',[], CursorTy, l$ VarE (toEndV v)) <$>
              l <$> (go2 d' rst)

          -- (_ty == IntTy) : Int fields are currently our only "scalar" fields
          go2 d ((rnd,_ty):rst) = do
            d' <- gensym $ toVar "writeintcur"
            rnd' <- go rnd
            LetE (d',[], CursorTy, l$ Ext $ L3.WriteInt d rnd') <$>
              l <$> (go2 d' rst)

      writetag <- gensym "writetag"
      (LetE (writetag,[], CursorTy,
             l$ Ext $ L3.WriteTag dcon sloc)
        <$> l <$> (go2 writetag (zip args (lookupDataCon ddfs dcon))))


    -- This is a simple case where the RHS is not packed
    LetE (v,_locs,ty,rhs) bod | not (isPackedTy ty) -> do
      rhs' <- go rhs
      LetE (v,[], L3.stripTyLocs ty,rhs') <$> go bod


    -- Here, we assume a convention that all packed values are changed to be (start,end) cursors.
    LetE (v,locs,ty,rhs) bod | isPackedTy ty -> do
      -- would return a (start,end) cursor tuple
      -- we bind v to the end cursor, and start cursor to the location in locs
      rhs' <- go rhs
      fresh <- gensym "packed_tpl"
      let tenv' = M.insert v ty tenv

      let (PackedTy _ tyLoc) = ty

      -- bind the end-of witness that rhs would return
      prefix <- case locs of
                  [] -> return $ LetE (fresh,[],ProdTy [CursorTy, CursorTy], rhs')

                  _  -> return $ LetE (fresh,[],ProdTy [CursorTy, CursorTy], rhs') <$>
                                   l <$> LetE (head locs,[],CursorTy, l$ ProjE 0 (l$ VarE fresh))

      prefix <$>
        (l <$> LetE (toEndV v,[],CursorTy, l$ ProjE 1 (l$ VarE fresh)) <$>
          (l <$> LetE (v,[],CursorTy, l$ VarE tyLoc) <$>
            cursorizeExp ddfs tenv' bod))


    -- TODO
    -- IfE EXP EXP EXP
    -- MkProdE [EXP]
    -- ProjE Int EXP
    -- TimeIt EXP dec Bool

    -- All locations are transformed into cursors here. All the location expressions
    -- are expressed in terms of corresponding cursor operations. See `cursorizeLocExp`
    Ext (LetLocE loc rhs bod) -> do
      let rhs' = cursorizeLocExp rhs
      LetE (loc,[],CursorTy,rhs') <$>
        go bod

    -- Just convert the implicit location return into a ProdE
    Ext (RetE locs v) ->
      case locs of
        [] -> unLoc <$> go (l$ VarE v)
        -- ASSUMPTION: RetE forms have locs when we're using them to return end-witnesses
        -- So return the end-witness of v' if v was packed
        [loc] -> do
          v' <- case M.lookup v tenv of
                  Nothing -> return $ VarE v
                  Just ty | isPackedTy ty ->  return $ VarE (toEndV v)
                  oth -> error $ "unexpected variable type: " ++ sdoc oth

          return $ MkProdE [l$ VarE loc, l$ v']
        _ -> error $ "cursorize: RetE with more than 1 locs not allowed! " ++ show locs

    Ext (LetRegionE r bod) -> do
      v <- regionToVar r
      LetE (v,[],CursorTy, l$ Ext L3.NewBuffer) <$>
        go bod

    -- Some expressions are not handled yet ...
    oth -> error $ "TODO:\n" ++ sdoc oth

  where
    go = cursorizeExp ddfs tenv

    toEndV = varAppend "end_"

    regionToVar :: Region -> SyM Var
    regionToVar r = case r of
                      GlobR  -> gensym "glob_region"
                      VarR v -> return v
                      DynR v -> return v


    -- | Take a cursor pointing to the start of the tag, and advance it by 1 byte
    -- If the first bound varaible is a scalar (IntTy), read it using the newly returned cursor.
    -- Otherwise, just process the body. it'll have the correct instructions to process
    -- other bound locations
    unpackDataCon :: Var -> (DataCon, [(Var,LocVar)], L Exp2) ->
                     SyM (DataCon, [(Var,())], L L3.Exp3)
    unpackDataCon scrtCur (dcon,vlocs,rhs) =
      let (vars,locs) = unzip vlocs
          tys  = lookupDataCon ddfs dcon
      in
      case tys of
        [] -> (dcon, [],) <$> go rhs
        (ty:_) -> do
          let floc    = head locs            -- location of the first field

          -- TODO: check if we can conditionally add things to the fmap computation
          bod <-
            if ty == IntTy
            then do
              -- the first field is an int, create a let binding for "v" by performing a
              -- readint
              let v = head vars -- name of the first bound variable
              tmp <- gensym (toVar "readint_tpl")
              LetE (floc,[],CursorTy, l$ Ext$ L3.AddCursor scrtCur 1) <$>
                -- the tmp cursor doesn't have a correct type. flrm should be modified
                -- with the location of the next field, if it has any
                l<$> (LetE (tmp,[],ProdTy [IntTy, CursorTy],
                            l$ Ext $ L3.ReadInt scrtCur) <$>
                       (l<$> LetE (v,[],IntTy, l$ ProjE 0 (l$ VarE tmp)) <$>
                         go rhs))
            else do
              LetE (floc,[],CursorTy, l$ Ext$ L3.AddCursor scrtCur 1) <$>
                go rhs

          return (dcon,[],l$ bod)

    -- would this always have a valid LRM ? should this be a Maybe ?
    cursorizeLocExp :: LocExp -> L L3.Exp3
    cursorizeLocExp locExp =
      case locExp of
        AfterConstantLE i loc -> l$ Ext $ L3.AddCursor loc i
        AfterVariableLE v loc -> l$ VarE (toVar $ "AfterVariableLE" ++ fromVar v ++ fromVar loc)
        FromEndLE loc -> l$ VarE loc
        StartOfLE r   -> case r of
                           GlobR  -> error $ "cursorizeLocExp: TODO: GlobR should have a var param"
                           VarR v -> l$ VarE v
                           DynR v -> l$ VarE v
        oth -> error $ "cursorizeLocExp: todo " ++ sdoc oth

-- | Change the location to _
cursorizeLRM :: LRM -> LRM
cursorizeLRM lrm = lrm {lrmLoc = "_"}

-}