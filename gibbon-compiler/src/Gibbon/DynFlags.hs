{-# LANGUAGE CPP #-}

-- | Flags à la GHC
module Gibbon.DynFlags
  ( DynFlags(..), GeneralFlag(..), DebugFlag(..)
  , defaultDynFlags, dynflagsParser
  , gopt, gopt_set, dopt, dopt_set
  ) where

#if !MIN_VERSION_base(4,11,0)
import Data.Monoid
#endif
import Data.Set as S
import Options.Applicative

data GeneralFlag
  = Opt_Gibbon1            -- ^ Set Opt_No_RemoveCopies & Opt_BigInfiniteRegions
  | Opt_Gibbon2            -- ^ Set Opt_RemoveCopies & Opt_InfiniteRegions
  | Opt_RemoveCopies       -- ^ Calls to copy functions are converted to indirections
  | Opt_No_RemoveCopies    -- ^ Unset Opt_RemoveCopies
  | Opt_InfiniteRegions    -- ^ Use infinite regions
  | Opt_BigInfiniteRegions -- ^ Use big infinite regions
  | Opt_BenchPrint         -- ^ Should the benchamrked function have its output printed?
  | Opt_Packed             -- ^ Use packed representation
  | Opt_Pointer            -- ^ Use pointer representation
  | Opt_BumpAlloc          -- ^ Use bump-pointer allocation if using the non-packed backend
  | Opt_Warnc              -- ^ Show warnings from the C compiler
  | Opt_DisableGC          -- ^ Don't run the the garbage collector (used by Codegen).
  | Opt_No_PureAnnot       -- ^ Don't use 'pure' annotations (a GCC optimization)
  | Opt_Fusion             -- ^ Enable fusion.
  | Opt_Parallel           -- ^ Fork/join parallelism.
  deriving (Show,Read,Eq,Ord)

-- | Exactly like GHC's ddump flags.
data DebugFlag
  = Opt_D_Dump_Repair
  | Opt_D_DumpToFile
  | Opt_D_Dump_Hs
  deriving (Show, Read, Eq, Ord)

-- Coming soon ...
-- data WarningFlag

data DynFlags = DynFlags { generalFlags :: Set GeneralFlag
                         , debugFlags :: Set DebugFlag }
  deriving (Show,Read,Eq,Ord)

defaultDynFlags :: DynFlags
defaultDynFlags = DynFlags { generalFlags = S.empty
                           , debugFlags = S.empty }

-- | Test whether a 'GeneralFlag' is set
gopt :: GeneralFlag -> DynFlags -> Bool
gopt f dflags  = f `S.member` generalFlags dflags

gopt_set :: GeneralFlag -> DynFlags -> DynFlags
gopt_set f dflags = dflags { generalFlags = S.insert f (generalFlags dflags) }

dopt :: DebugFlag -> DynFlags -> Bool
dopt f dflags = f `S.member` debugFlags dflags

dopt_set :: DebugFlag -> DynFlags -> DynFlags
dopt_set f dflags = dflags { debugFlags = S.insert f (debugFlags dflags) }

dynflagsParser :: Parser DynFlags
dynflagsParser = DynFlags <$> (S.fromList <$> many gflagsParser) <*> (S.fromList <$> many dflagsParser)
  where
    gflagsParser :: Parser GeneralFlag
    gflagsParser = -- Default Opt_Gibbon2
                   flag' Opt_Gibbon1 (long "gibbon1" <>
                                      help "Gibbon1 mode") <|>
                   -- Default Opt_RemoveCopies
                   flag' Opt_No_RemoveCopies (long "no-rcopies" <>
                                              help "Calls to copy functions are *not* converted to indirections") <|>
                   -- Default Opt_InfiniteRegions
                   flag' Opt_BigInfiniteRegions (long "biginf" <>
                                                 help "Use big infinite regions") <|>
                   flag' Opt_BenchPrint (long "bench-print" <>
                                         help "Print the output of the benchmarked function, rather than #t") <|>
                   flag' Opt_Packed (short 'p' <>
                                     long "packed" <>
                                     help "Enable packed tree representation in C backend") <|>
                   flag' Opt_Pointer (long "pointer" <>
                                      help "Enable pointer-based trees in C backend (default)") <|>
                   flag' Opt_BumpAlloc (long "bumpalloc" <>
                                        help "Use BUMPALLOC mode in generated C code.  Only affects --pointer") <|>
                   flag' Opt_Warnc (short 'w' <>
                                    long "warnc" <>
                                    help "Show warnings from C compiler, normally suppressed") <|>
                   flag' Opt_DisableGC (long "no-gc" <>
                                        help "Disable the garbage collector (don't use -g when using this flag).") <|>
                   flag' Opt_No_PureAnnot (long "no-pure-annot" <>
                                           help "Don't use 'pure' annotations (a GCC optimization).") <|>
                   flag' Opt_Fusion (long "fusion" <>
                                     help "Enable fusion.") <|>
                   flag' Opt_Parallel (long "parallel" <> help "Enable parallelism")

    dflagsParser :: Parser DebugFlag
    dflagsParser = flag' Opt_D_Dump_Repair (long "ddump-repair" <>
                                            help "Dump some information while running RepairProgram") <|>
                   flag' Opt_D_DumpToFile (long "ddump-to-file" <>
                                           help "Dump output to files instead of stdout.") <|>
                   flag' Opt_D_Dump_Hs (long "ddump-hs" <>
                                        help "Dump GHC compliant source code after all the L1 passes are done.")
