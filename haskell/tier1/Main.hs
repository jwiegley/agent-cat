-- | Tier 1: the rebuilt-case runner.
--
-- Where tier0 replays the frozen corpus through the codec, the guards and the
-- string layer, tier1 rebuilds nineteen of its /checked/ entries in the
-- production surface ("Agentic.Builder", see "Cases") and holds the rebuilt
-- program against the oracle on two fronts:
--
-- 1. the __printed Raw__ — @toJSON@ of the builder's 'RawProgram' against the
--    entry's @request.program@, with every position zeroed on /both/ sides,
--    because positions are not representable in the builder and are
--    oracle-only throughout this program. The printed program is also
--    decoded back and re-encoded, so a print that no reader accepts fails here
--    rather than silently.
--
--    Two of the twenty-one cases — the walked examples of "Example.Harden",
--    named by @Cases.alphaNamed@ — compare this one field __up to alpha__.
--    They are written in "Agentic.Workflow", which cannot read a Haskell
--    binder's spelling and therefore generates the name each binding prints;
--    'canonProgram' below renames the binders of /both/ sides to @c0, c1, …@
--    in one traversal before they are compared, so what is pinned is that the
--    two programs agree on everything a name is not — including which binding
--    every hole, scrutinee and subject reads. The other nineteen are written
--    in "Agentic.Builder" with explicit names and are compared exactly.
--
-- 2. the __whole reply__ — @level@, @size@, @askNodes@, @codes@ and
--    @costSummary@ folded from the elaborated 'Agentic.Plan.Plan';
--    @blockAsks@ and @fnAsks@ counted by "Agentic.Guards" on the /printed/
--    Raw (week-one code, cross-checking the builder against the corpus's own
--    program); and, per world of @request.worlds@ in order, the world's
--    re-serialization, its trace event by event and its two bills
--    (@Agentic.World.worldObservation@). Everything is compared as
--    'Data.Aeson.Value's, whole: no field is skipped, and a missing or extra
--    key is a failure, so a runner cannot go quietly green when the corpus
--    moves under it.
--
-- A divergence is reported as the JSON path where the two values first part
-- company, with both fragments.
--
-- Both sides of that comparison — the printed program, the position-zeroing
-- rule and the assembled reply — come from "Agentic.Observe", which the live
-- bisimulation uses too. What is left here is the driver and the diff: reading
-- the frozen entries, deciding what counts as a failure, and saying where.
--
-- Usage: @tier1 [corpusDir]@, defaulting to
-- @\/Users\/johnw\/src\/agent-cat\/test\/corpus@. Exit status is 0 iff nothing
-- failed.
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main (main) where

import Control.Exception
  ( SomeAsyncException,
    SomeException,
    evaluate,
    fromException,
    throwIO,
    try,
  )
import Control.Monad (forM, unless)
import Data.Aeson
  ( Result (..),
    Value (..),
    eitherDecodeStrict',
    fromJSON,
    toJSON,
  )
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Directory (doesDirectoryExist, doesFileExist)
import System.Environment (getArgs)
import System.Exit (exitFailure, exitSuccess)
import System.FilePath ((</>))

import Agentic.Builder (Program, progPlan, progRawOut)
import Agentic.Observe
  ( firstDiff,
    observeValue,
    printedValue,
    tshow,
    zeroPosValue,
  )
import Agentic.Plan (Level (..), level)
import Agentic.Raw
  ( Chunk (..),
    Raw (..),
    RawArg (..),
    RawAsk (askPrompt),
    RawBodyStmt (..),
    RawFn (..),
    RawProgram (..),
    RawRhs (..),
    RawSource (..),
  )
import Agentic.World (WorldSpec)

import Cases (alphaNamed, cases)

-- ---------------------------------------------------------------------------
-- Driver
-- ---------------------------------------------------------------------------

defaultCorpus :: FilePath
defaultCorpus = "../test/corpus"

main :: IO ()
main = do
  args <- getArgs
  let dir = case args of
        (d : _) -> d
        [] -> defaultCorpus
  present <- doesDirectoryExist dir
  unless present $ do
    TIO.putStrLn ("tier1: no such corpus directory: " <> T.pack dir)
    exitFailure
  results <- forM cases $ \(name, prog) ->
    (,) name <$> runCase (dir </> name) (nameRule name) prog
  mapM_ report results
  let total = length results
      failed = length [() | (_, fs) <- results, not (null fs)]
      passed = total - failed
  TIO.putStrLn $
    "tier1: "
      <> tshow passed
      <> " passed, "
      <> tshow failed
      <> " failed, of "
      <> tshow total
      <> " cases"
  if failed == 0 then exitSuccess else exitFailure
  where
    report (name, fs) =
      mapM_ (\f -> TIO.putStrLn ("FAIL " <> T.pack name <> ": " <> f)) fs

-- | How a case's __names__ are compared, which is the only thing about a case
-- that is ever compared loosely. See 'Cases.alphaNamed' for which cases are
-- which, and why.
data NameRule
  = -- | the printed program must match name for name
    Exact
  | -- | the printed program must match once the binders of both sides are
    -- canonically renamed
    Alpha

-- | The rule for one case, by the basename of the entry it rebuilds.
nameRule :: FilePath -> NameRule
nameRule name = if name `elem` alphaNamed then Alpha else Exact

-- | Check one rebuilt case against its frozen entry. A bottom anywhere in the
-- builder, the folds or the trace is caught and reported as that case's
-- failure rather than killing the run.
runCase :: FilePath -> NameRule -> Program -> IO [Text]
runCase path rule prog = do
  there <- doesFileExist path
  if not there
    then pure ["no such corpus entry: " <> T.pack path]
    else do
      bytes <- BS.readFile path
      case eitherDecodeStrict' bytes of
        Left err -> pure ["not valid JSON: " <> squash (T.pack err)]
        Right v -> forced (checkCase rule v prog)

-- | Force a failure list to normal form inside 'try', so an @error@ raised by
-- the implementation becomes a reported failure.
forced :: [Text] -> IO [Text]
forced fs = do
  caught <- try (evaluate (sum (map T.length fs) `seq` fs))
  case caught :: Either SomeException [Text] of
    Right fs' -> pure fs'
    Left e
      -- An interrupt is the user talking, not a conformance failure.
      | Just (_ :: SomeAsyncException) <- fromException e -> throwIO e
      | otherwise -> pure ["implementation raised: " <> squash (tshow e)]

-- ---------------------------------------------------------------------------
-- The comparison rules (the two fronts of the module header)
-- ---------------------------------------------------------------------------

checkCase :: NameRule -> Value -> Program -> [Text]
checkCase rule entry prog = case (field "request" entry, field "reply" entry) of
  (Just req, Just reply)
    | Just _ <- field "refused" reply ->
        -- Only checked entries are rebuildable; a refusal here means the
        -- corpus moved and the case list must be revisited, not skipped.
        ["the entry is a refusal, and only checked entries are rebuildable"]
    | Nothing <- field "level" reply ->
        ["the reply is neither a refusal nor a checked result (no `level`)"]
    | otherwise -> case field "program" req of
        Nothing -> ["the request has no program"]
        Just pv -> case worldsOf req of
          Left err -> [err]
          Right ws -> programCheck rule pv prog ++ replyCheck reply ws prog
  _ -> ["the entry lacks a request or a reply"]

-- | The worlds of the request, in order. Absent reads as none.
worldsOf :: Value -> Either Text [WorldSpec]
worldsOf req = case field "worlds" req of
  Nothing -> Right []
  Just wv -> case fromJSON wv :: Result [WorldSpec] of
    Error err -> Left ("request.worlds does not decode: " <> squash (T.pack err))
    Success ws -> Right ws

-- | Front 1: the printed program, positions zeroed on both sides — and a
-- round-trip of the print, since the builder is the only writer of Raw that
-- the codec has not already been proved against.
--
-- Under 'Alpha' the two programs are compared after 'canonProgram' has renamed
-- the binders of each; the round-trip is unaffected and stays exact, because
-- it compares the print with itself.
programCheck :: NameRule -> Value -> Program -> [Text]
programCheck rule expected prog =
  concat
    [ case rule of
        Exact ->
          [ "printed program differs at " <> d
          | Just d <- [firstDiff (zeroPosValue expected) (zeroPosValue printed)]
          ]
        Alpha -> case fromJSON expected :: Result RawProgram of
          Error err ->
            ["the frozen program does not decode: " <> squash (T.pack err)]
          Success frozen ->
            [ "printed program differs, up to alpha, at " <> d
            | Just d <-
                [ firstDiff
                    (zeroPosValue (toJSON (canonProgram frozen)))
                    (zeroPosValue (toJSON (canonProgram (progRawOut prog))))
                ]
            ],
      case fromJSON printed :: Result RawProgram of
        Error err ->
          ["the printed program does not decode back: " <> squash (T.pack err)]
        Success back ->
          [ "the printed program does not round-trip at " <> d
          | Just d <- [firstDiff printed (toJSON back)]
          ]
    ]
  where
    printed = printedValue prog

-- | Front 2: the whole reply, assembled by 'observeValue' from the folds,
-- the guards' ask counts and one observation per world.
replyCheck :: Value -> [WorldSpec] -> Program -> [Text]
replyCheck reply ws prog
  -- `costSummary` is defined only below the dynamic rung; the builder cannot
  -- reach it, so say so plainly rather than reporting a meaningless summary.
  | level (progPlan prog) > Branch =
      ["the elaborated plan reaches the dynamic rung, which no reply describes"]
  | otherwise =
      [ "reply differs at " <> d
      | Just d <- [firstDiff reply (observeValue prog ws)]
      ]

-- ---------------------------------------------------------------------------
-- The alpha canonicalizer
-- ---------------------------------------------------------------------------

-- | Every name a program /binds/, renamed to @c\<level\>@, and every name it
-- /reads/ renamed with it.
--
-- One total structural traversal, used on both sides of the comparison, so
-- @'canonProgram' a == 'canonProgram' b@ says exactly that @a@ and @b@ are the
-- same program up to the spelling of names. It is scope-aware and not a flat
-- substitution: a canonical name is the __level__ of the binder that
-- introduced it — how many bindings enclose it — so two binders in disjoint
-- scopes may share a canonical name (the flagship's carrier and settled binder
-- do), and a name that is free is left exactly as written.
--
-- __The traversal order__, which is the order levels are handed out and is
-- therefore the whole definition:
--
-- 1. the function table, each function alone: its parameters take levels
--    @0…n-1@ in declaration order, then its body statements in order, each
--    @bind@ taking the next level and its right-hand side read /before/ that
--    name is live, and finally @answer@;
-- 2. the main block, from level @0@, statement by statement down the @rest@
--    spine: a @bind@ takes the current level, its source is read in the scope
--    /before/ it, and the rest of the block continues one level deeper;
-- 3. inside a @revising@ source: the subject is read in the enclosing scope,
--    the carrier takes the level after the result's, the review binding the
--    one after that, and the review and the amendment are read in those
--    scopes;
-- 4. a @caseResult@'s settled binder takes the current level and is live in
--    the settled arm only; both arms of an @if@ and of a @case@ are read in
--    the same scope, in the order the constructor writes them;
-- 5. within one question, its prompt left to right, an @interp@ chunk being a
--    read like any other.
canonProgram :: RawProgram -> RawProgram
canonProgram p =
  RawProgram (map canonFn (progFns p)) (canonRaw M.empty 0 (progMain p))

-- | What a name is called after renaming, by the level of its binder.
type Names = Map Text Text

-- | The canonical name of the binding at level @n@.
canonName :: Int -> Text
canonName n = "c" <> tshow n

-- | A read: the canonical name of whatever binding is live under this name,
-- and the name itself if none is — a free name compares by its own spelling.
useName :: Names -> Text -> Text
useName env x = M.findWithDefault x x env

-- | A binding: @x@ names level @n@ from here on.
bindName :: Names -> Int -> Text -> Names
bindName env n x = M.insert x (canonName n) env

canonRaw :: Names -> Int -> Raw -> Raw
canonRaw env n = \case
  RawEmpty pos -> RawEmpty pos
  RawBind x ann src rest pos ->
    RawBind
      (canonName n)
      ann
      (canonSource env n src)
      (canonRaw (bindName env n x) (n + 1) rest)
      pos
  RawAct a rest pos -> RawAct (canonAsk env a) (canonRaw env n rest) pos
  RawIfFlag x yes no pos ->
    RawIfFlag (useName env x) (canonRaw env n yes) (canonRaw env n no) pos
  RawCaseVerdict x approved objected noAnswer pos ->
    RawCaseVerdict
      (useName env x)
      (canonRaw env n approved)
      (canonRaw env n objected)
      (canonRaw env n noAnswer)
      pos
  RawCaseResult x sname settled unsettled pos ->
    RawCaseResult
      (useName env x)
      (canonName n)
      (canonRaw (bindName env n sname) (n + 1) settled)
      (canonRaw env n unsettled)
      pos
  RawKnownHere names rest pos ->
    RawKnownHere (map (useName env) names) (canonRaw env n rest) pos
  RawCallStmt f as rest pos ->
    RawCallStmt f (map (canonArg env) as) (canonRaw env n rest) pos

-- | A source, at the level its binding took: the two clause binders of a
-- bounded revision are the two levels after it.
canonSource :: Names -> Int -> RawSource -> RawSource
canonSource env n = \case
  SrcRhs r -> SrcRhs (canonRhs env r)
  SrcRevising subj carrier bound rname rann review am pos ->
    SrcRevising
      (useName env subj)
      (canonName (n + 1))
      bound
      (canonName (n + 2))
      rann
      (canonRhs envCarrier review)
      (canonRhs envReview am)
      pos
    where
      envCarrier = bindName env (n + 1) carrier
      envReview = bindName envCarrier (n + 2) rname

canonRhs :: Names -> RawRhs -> RawRhs
canonRhs env = \case
  RhsAsk a -> RhsAsk (canonAsk env a)
  RhsPanel ms pos -> RhsPanel (map (canonAsk env) ms) pos
  RhsCall f as pos -> RhsCall f (map (canonArg env) as) pos

-- | A question: only its prompt can name anything.
canonAsk :: Names -> RawAsk -> RawAsk
canonAsk env a = a {askPrompt = map (canonChunk env) (askPrompt a)}

canonChunk :: Names -> Chunk -> Chunk
canonChunk env = \case
  Lit s -> Lit s
  Interp x -> Interp (useName env x)

canonArg :: Names -> RawArg -> RawArg
canonArg env = \case
  ArgName x pos -> ArgName (useName env x) pos
  ArgLit p pos -> ArgLit (map (canonChunk env) p) pos

-- | One function: its parameters are its first bindings, its body a straight
-- line of them, and its @answer@ a read at the end of that line. Function
-- names are not renamed — they are a different namespace, and both sides must
-- agree on them exactly.
canonFn :: RawFn -> RawFn
canonFn f =
  f
    { fnParams = zipWith (\i (_, c) -> (canonName i, c)) [0 ..] (fnParams f),
      fnBody = body,
      fnAnswer = useName envEnd <$> fnAnswer f
    }
  where
    env0 =
      M.fromList (zipWith (\i (p, _) -> (p, canonName i)) [0 ..] (fnParams f))
    (body, envEnd) = canonBody env0 (length (fnParams f)) (fnBody f)

-- | A body, and the scope it leaves behind for @answer@ to read.
canonBody :: Names -> Int -> [RawBodyStmt] -> ([RawBodyStmt], Names)
canonBody env _ [] = ([], env)
canonBody env n (s : ss) = case s of
  BodyBind x ann rhs pos ->
    let (rest, envEnd) = canonBody (bindName env n x) (n + 1) ss
     in (BodyBind (canonName n) ann (canonRhs env rhs) pos : rest, envEnd)
  BodyAct a pos ->
    let (rest, envEnd) = canonBody env n ss
     in (BodyAct (canonAsk env a) pos : rest, envEnd)
  BodyCallS f as pos ->
    let (rest, envEnd) = canonBody env n ss
     in (BodyCallS f (map (canonArg env) as) pos : rest, envEnd)

-- ---------------------------------------------------------------------------
-- Value inspection
-- ---------------------------------------------------------------------------

field :: Text -> Value -> Maybe Value
field k (Object o) = case KM.lookup (K.fromText k) o of
  Just Null -> Nothing -- a missing key and an explicit null read alike.
  other -> other
field _ _ = Nothing

-- | One failure reason on one line, whatever whitespace it arrived with.
squash :: Text -> Text
squash = T.unwords . T.words
