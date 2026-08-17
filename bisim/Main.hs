-- | The live bisimulation: generated programs, held against a running Lean.
--
-- Where @tier0@ replays a frozen corpus and @tier1@ rebuilds sixteen of its
-- entries, this runner asks questions nobody wrote down. It draws programs,
-- worlds and string-layer inputs from "Agentic.Gen", puts each one to a live
-- @conformance-oracle@ subprocess ("Agentic.Oracle"), and compares the reply
-- against what this implementation says — the whole reply, as a
-- 'Data.Aeson.Value', field for field (@connection.md@ §3.4, §3.5).
--
-- == The four properties
--
-- [P0 — the generators terminate] "Agentic.Gen"'s @selfTest@, run before the
--   oracle is even spawned. A backwards-from-the-rules generator over a
--   language with functions, calls and bounded revisions can blow up, and
--   @connection.md@ §3.4 asks for that as a red test rather than as a hung
--   CI job. A 'False' here aborts the run: every other property draws from
--   these generators, and a suite that hangs reports nothing at all.
--
-- [P1 — the builder bisimulation] For each 'GenCase': send the program /as
--   this implementation prints it/ and compare the oracle's whole checked
--   reply against @observeValue@. A __refusal is a failure here__, not a
--   skip. The builder's types are supposed to make a refusable term
--   unrepresentable (@PORTING2-elab.md@), so a refusal is either a hole in
--   that claim or a bug in the printer, and both are findings. Positions
--   never appear in a checked reply, so nothing is zeroed on this path: the
--   comparison is of two replies, not of two programs.
--
-- [P2 — string parity] Every trap text against every string-layer operation,
--   compared with 'Agentic.Text.stringOp'. This is the highest-ranked
--   divergence risk on the page (@connection.md@ D12) and the only surface
--   that reaches @Decode@ at all, because a program-in\/world-out boundary
--   never calls it.
--
-- [P3 — refusal parity] For each generated 'RawProgram': if the oracle
--   refuses with one of the five term-level guards, 'guardCheck' must name
--   the same guard and the same @n@; if it accepts, 'guardCheck' must be
--   'Nothing' and 'askCounts' must match the reply's counts. A refusal
--   classified @other@ is __not a comparand__ (@connection.md@ §3.6): those
--   are the typing judgment's diagnostics, which this implementation does not
--   port. They are counted and skipped, and if nearly everything is one, the
--   generator is saying it cannot reach the surface under test — which is
--   reported rather than swallowed.
--
-- == What is a failure and what is not
--
-- A __divergence__ is a reply that arrived and disagreed. It is printed in
-- full — request, oracle reply, this implementation's answer — and the run
-- continues, so that one bad constructor does not hide the other nineteen.
-- All divergences are counted and the process exits nonzero.
--
-- A __transport failure__ — the oracle wedged, died, or answered a question
-- that was not asked — is not a divergence and does not accumulate. It stops
-- the run then and there, because after it the stream no longer means
-- anything ("Agentic.Oracle").
--
-- An __in-band timeout__ (@{"timeout": {"ms": n}}@) is neither: it is an
-- observation that the two implementations differ in asymptotics
-- (@connection.md@ D13), and it is counted as a skip and named in the summary.
--
-- == Usage
--
-- > bisim [--oracle PATH] [--n N] [--seed SEED]
--
-- defaulting to the built oracle under @agent-cat\/.lake@, 200 iterations, and
-- a seed drawn from the system. The seed used is always printed first, so any
-- run can be replayed exactly with @--seed@.
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
    handle,
    throwIO,
    try,
  )
import Control.Monad (forM_, unless)
import Data.Aeson (Value (..), object, toJSON, (.=))
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.Bits (shiftR, (.&.))
import qualified Data.ByteString as BS
import Data.Char (ord)
import Data.List (sort, sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Maybe (catMaybes, fromMaybe)
import Data.Scientific (floatingOrInteger)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import qualified Data.Vector as V
import Numeric (showHex)
import System.CPUTime (getCPUTime)
import System.Environment (getArgs, getProgName)
import System.Exit (exitFailure, exitSuccess, exitWith, ExitCode (..))
import System.IO
  ( BufferMode (..),
    IOMode (..),
    hSetBuffering,
    stdout,
    withBinaryFile,
  )
import Test.QuickCheck (Gen, resize)
import Test.QuickCheck.Gen (unGen)
import Test.QuickCheck.Random (mkQCGen)

import Agentic.Builder (progPlan)
import Agentic.Gen
  ( GenCase (..),
    genCase,
    genRawProgram,
    genTrapText,
    selfTest,
  )
import Agentic.Guards (Guard (..), askCounts, guardCheck)
import Agentic.Observe (observeValue, printedValue)
import Agentic.Oracle
  ( Oracle,
    OracleError,
    oracleErrorText,
    oraclePing,
    oracleProgram,
    oracleString,
    withOracle,
  )
import Agentic.Plan (Level (..), level)
import Agentic.Raw (RawProgram)
import Agentic.Text (stringOp)

-- ---------------------------------------------------------------------------
-- Options
-- ---------------------------------------------------------------------------

data Opts = Opts
  { optOracle :: FilePath,
    optN :: Int,
    optSeed :: Maybe Int
  }

defaultOracle :: FilePath
defaultOracle = "/Users/johnw/src/agent-cat/.lake/build/bin/conformance-oracle"

defaultOpts :: Opts
defaultOpts = Opts {optOracle = defaultOracle, optN = 200, optSeed = Nothing}

-- | @bisim [--oracle PATH] [--n N] [--seed SEED]@, and @--help@. Long options
-- only, in both spellings (@--n 50@ and @--n=50@), because there is no third
-- form anyone will reach for.
parseOpts :: [String] -> Either Text Opts
parseOpts = go defaultOpts
  where
    go acc [] = Right acc
    go acc (arg : rest) = case break (== '=') arg of
      (flag, '=' : val) -> withValue acc flag val rest
      _ -> case rest of
        (val : rest') | isFlag arg -> withValue acc arg val rest'
        _
          | isFlag arg -> Left (T.pack arg <> " needs a value")
          | otherwise -> Left ("unrecognized argument: " <> T.pack arg)

    isFlag a = a `elem` ["--oracle", "--n", "--seed"]

    withValue acc flag val rest = case flag of
      "--oracle" -> go acc {optOracle = val} rest
      "--n" -> num val >>= \k -> go acc {optN = k} rest
      "--seed" -> num val >>= \k -> go acc {optSeed = Just k} rest
      _ -> Left ("unrecognized flag: " <> T.pack flag)

    num val = case reads val of
      [(k, "")] | k > 0 -> Right k
      [(k, "")] -> Left ("not a positive number: " <> tshow (k :: Int))
      _ -> Left ("not a number: " <> T.pack val)

usage :: String -> Text
usage prog =
  T.unlines
    [ "usage: " <> T.pack prog <> " [--oracle PATH] [--n N] [--seed SEED]",
      "",
      "  --oracle PATH  the conformance-oracle binary",
      "                 (default " <> T.pack defaultOracle <> ")",
      "  --n N          iterations per property (default 200)",
      "  --seed SEED    the generator seed (default: drawn from the system,",
      "                 and always printed, so a run can be replayed)"
    ]

-- ---------------------------------------------------------------------------
-- Driver
-- ---------------------------------------------------------------------------

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  args <- getArgs
  prog <- getProgName
  if any (`elem` ["-h", "--help"]) args
    then TIO.putStr (usage prog) >> exitSuccess
    else case parseOpts args of
      Left err -> do
        TIO.putStrLn ("bisim: " <> err)
        TIO.putStr (usage prog)
        exitWith (ExitFailure 2)
      Right opts -> run opts

run :: Opts -> IO ()
run opts = do
  seed <- maybe freshSeed pure (optSeed opts)
  TIO.putStrLn $
    "bisim: seed " <> tshow seed <> ", n = " <> tshow (optN opts)

  -- P0 first, and without an oracle: it is a statement about this side alone,
  -- and every other property draws from the generators it exercises.
  green <- selfTest
  unless green $ do
    TIO.putStrLn
      "FAIL P0: the generator self-test failed \
      \(see Agentic.Gen's diagnostics above); \
      \aborting before any oracle traffic"
    exitFailure
  TIO.putStrLn "bisim: P0 generator self-test ok"

  -- A transport failure is not a conformance finding and does not accumulate:
  -- it stops the run and says why.
  handle onTransportFailure $
    withOracle (optOracle opts) $ \oracle -> do
      alive <- oraclePing oracle
      unless alive $ do
        TIO.putStrLn "bisim: the oracle did not answer a ping; aborting"
        exitFailure

      t1 <- propBuilder oracle (seedFor seed 1) (optN opts)
      t2 <- propString oracle (seedFor seed 2) (optN opts)
      t3 <- propRefusal oracle (seedFor seed 3) (optN opts)
      summarize [t1, t2, t3]

onTransportFailure :: OracleError -> IO a
onTransportFailure e = do
  TIO.putStrLn ("bisim: " <> oracleErrorText e)
  TIO.putStrLn "bisim: the run stopped here; no summary is meaningful past a transport failure"
  exitFailure

-- | One seed per property, so that shortening one property's @--n@ does not
-- shift the programs another property draws.
seedFor :: Int -> Int -> Int
seedFor base k = base + 7919 * k

-- | A seed from the system, so an unseeded run is a genuinely new sample —
-- and printed, so it is still a reproducible one.
--
-- @\/dev\/urandom@ is read with an explicit fixed-size 'BS.hGet' rather than
-- with 'BS.readFile', which would try to read a character device to EOF and
-- never return. The CPU clock is the fallback for a platform without it; it
-- is poor entropy and the printed seed is what makes that survivable.
freshSeed :: IO Int
freshSeed = do
  got <- try (withBinaryFile "/dev/urandom" ReadMode (\h -> BS.hGet h 8))
  case got :: Either SomeException BS.ByteString of
    Right bs | BS.length bs == 8 -> pure (clamp (BS.foldl' byte 0 bs))
    _ -> clamp . fromIntegral <$> getCPUTime
  where
    byte acc w = acc * 256 + fromIntegral w :: Integer
    clamp n = fromInteger (n `mod` 1000000000)

-- ---------------------------------------------------------------------------
-- Drawing from the generators
-- ---------------------------------------------------------------------------

-- | @draw seed n maxSize g@ — @n@ values, sizes ramping from 0 to @maxSize@.
--
-- The whole list comes from a single 'unGen', so the seed splits inside the
-- 'Gen' monad and this module never needs a random number generator of its
-- own. The ramp is deliberate: the small end catches the base cases a
-- size-100 program would bury, and the large end is where a fold's asymptotics
-- and an oracle's budget start to matter.
draw :: Int -> Int -> Int -> Gen a -> [a]
draw seed n maxSize g =
  unGen (traverse (\i -> resize (sizeAt i) g) [0 .. n - 1]) (mkQCGen seed) maxSize
  where
    sizeAt i = (i * maxSize) `div` max 1 (n - 1)

-- | Programs and raw terms grow fast in this language — a size of 20 already
-- reaches nested branches with functions and calls.
maxTermSize :: Int
maxTermSize = 20

-- | Trap texts are cheap and their interesting cases are all small: escapes,
-- dotted capitals, whitespace runs.
maxTextSize :: Int
maxTextSize = 12

-- ---------------------------------------------------------------------------
-- P1 — the builder bisimulation
-- ---------------------------------------------------------------------------

propBuilder :: Oracle -> Int -> Int -> IO Tally
propBuilder oracle seed n =
  runProperty "P1" (draw seed n maxTermSize genCase) $ \gc -> do
    let prog = gcProgram gc
        ws = gcWorlds gc
        req = printedValue prog
    reply <- oracleProgram oracle req ws
    -- The Haskell side is forced inside `try`: a partial function in a fold or
    -- a trace is this implementation's bug, and it should be reported as this
    -- case's failure rather than kill the run.
    ours <- forced (observeValue prog ws)
    pure $ case (classify reply, ours) of
      (_, Left err) ->
        Diverged
          ("this implementation raised while assembling the reply: " <> err)
          [("request", req)]
      (Timeout ms, _) ->
        Skipped ("the oracle ran out of budget at " <> ms <> "ms")
      (Refused r, _) ->
        Diverged
          "the oracle REFUSED a program the builder built; \
          \a refusable term is supposed to be unrepresentable here"
          [("request", req), ("refusal", r)]
      (Errored msg, _) ->
        Diverged
          ("the oracle could not read the printed program: " <> msg)
          [("request", req)]
      (Unknown, _) ->
        Diverged
          "the oracle's reply is neither checked, refused, timed out nor an error"
          [("request", req), ("oracle", reply)]
      (Checked, Right ourReply)
        -- `costSummary` is defined only below the dynamic rung, so a plan that
        -- reached it would be compared against a meaningless summary.
        | level (progPlan prog) > Branch ->
            Diverged
              "the generated program elaborates to the dynamic rung, \
              \which no reply describes"
              [("request", req)]
        | Just d <- firstDiff reply ourReply ->
            Diverged
              ("reply differs at " <> d)
              [("request", req), ("oracle", reply), ("haskell", ourReply)]
        | otherwise -> Agreed

-- ---------------------------------------------------------------------------
-- P2 — string parity
-- ---------------------------------------------------------------------------

-- | Every operation the string request kind offers, with every code the two
-- coded operations take: eleven questions per text.
stringOps :: [(Text, Maybe Text)]
stringOps =
  [("norm", Nothing), ("words", Nothing), ("decodeVerdict", Nothing)]
    ++ [ (op, Just code)
       | op <- ["decode", "say"],
         code <- ["text", "verdict", "flag", "receipt"]
       ]

propString :: Oracle -> Int -> Int -> IO Tally
propString oracle seed n =
  runProperty "P2" pairs $ \(text, (op, mcode)) -> do
    reply <- oracleString oracle op mcode text
    ours <- forced (stringOp op mcode text)
    pure $ case ours of
      Left err ->
        Diverged ("this implementation raised: " <> err) [("request", ask op mcode text)]
      Right ourReply
        | Just d <- firstDiff reply ourReply ->
            Diverged
              (label op mcode <> " differs at " <> d)
              [("request", ask op mcode text), ("oracle", reply), ("haskell", ourReply)]
        | otherwise -> Agreed
  where
    pairs = [(t, o) | t <- draw seed n maxTextSize genTrapText, o <- stringOps]
    label op mcode = op <> maybe "" ("/" <>) mcode
    ask op mcode text =
      object
        ["string" .= object (["op" .= op] ++ maybe [] (\c -> ["code" .= c]) mcode ++ ["text" .= text])]

-- ---------------------------------------------------------------------------
-- P3 — refusal parity
-- ---------------------------------------------------------------------------

-- | The oracle's spelling of the five term-level guards
-- (@Conformance.lean@'s @classify@). Its sixth tag, @other@, is handled
-- before this table is consulted.
guardNames :: [(Text, Guard)]
guardNames =
  [ ("panelEmpty", PanelEmpty),
    ("revisionBound", RevisionBound),
    ("questionBudget", QuestionBudget),
    ("servedBy", ServedBy),
    ("dupFunction", DupFunction)
  ]

propRefusal :: Oracle -> Int -> Int -> IO Tally
propRefusal oracle seed n =
  runProperty "P3" (draw seed n maxTermSize genRawProgram) $ \raw -> do
    let req = toJSON (raw :: RawProgram)
    -- No worlds: a refusal has none, and a checked reply's comparands here are
    -- the two ask counts, which need no world. The key is written explicitly
    -- because an absent `worlds` means the echo world, not none.
    reply <- oracleProgram oracle req []
    pure $ case classify reply of
      Timeout ms -> Skipped ("the oracle ran out of budget at " <> ms <> "ms")
      Errored msg ->
        Diverged
          ("the oracle could not read a program this implementation printed: " <> msg)
          [("request", req)]
      Unknown ->
        Diverged
          "the oracle's reply is neither checked, refused, timed out nor an error"
          [("request", req), ("oracle", reply)]
      Refused r -> refusalCase req r raw
      Checked -> checkedCase req reply raw

-- | The oracle refused. Either it named one of the five guards — in which
-- case 'guardCheck' owes the same guard and the same @n@ — or it named
-- @other@, which is a diagnostic of the typing judgment and not a comparand.
refusalCase :: Value -> Value -> RawProgram -> Verdict
refusalCase req r raw = case textOf =<< field "guard" r of
  Nothing ->
    Diverged "the refusal carries no guard" [("request", req), ("refusal", r)]
  Just "other" -> Skipped "other"
  Just name -> case lookup name guardNames of
    Nothing ->
      Diverged
        ("the oracle refused with a guard this implementation does not know: " <> name)
        [("request", req), ("refusal", r)]
    Just g ->
      let expected = Just (g, intOf =<< field "n" r)
          actual = guardCheck raw
       in if actual == expected
            then Agreed
            else
              Diverged
                ( "guardCheck says "
                    <> renderGuard actual
                    <> ", the oracle says "
                    <> renderGuard expected
                )
                [("request", req), ("refusal", r)]

-- | The oracle accepted. Then no guard of ours may fire, and the two Raw-level
-- ask counts must agree — the week-one comparands, which need no 'Plan' on
-- either side (@connection.md@ §3.5 row 3).
checkedCase :: Value -> Value -> RawProgram -> Verdict
checkedCase req reply raw
  | Just fired <- guardCheck raw =
      Diverged
        ( "the oracle accepted a program guardCheck refuses with "
            <> renderGuard (Just fired)
        )
        [("request", req), ("oracle", reply)]
  | Just d <- firstDiff theirs ours =
      Diverged
        ("ask counts differ at " <> d)
        [("request", req), ("oracle", theirs), ("haskell", ours)]
  | otherwise = Agreed
  where
    (blockAsks, fnAsks) = askCounts raw
    ours = object ["blockAsks" .= blockAsks, "fnAsks" .= fnAsks]
    theirs =
      object
        [ "blockAsks" .= fromMaybe Null (field "blockAsks" reply),
          "fnAsks" .= fromMaybe Null (field "fnAsks" reply)
        ]

renderGuard :: Maybe (Guard, Maybe Integer) -> Text
renderGuard Nothing = "no guard"
renderGuard (Just (g, mn)) = tshow g <> maybe "" (\k -> " (n = " <> tshow k <> ")") mn

-- ---------------------------------------------------------------------------
-- Reply shapes
-- ---------------------------------------------------------------------------

-- | Which of the schema's reply shapes arrived. The refusal carries its own
-- object, because the failure report wants to show it whole.
data Shape = Checked | Refused Value | Timeout Text | Errored Text | Unknown

classify :: Value -> Shape
classify reply
  | Just r <- field "refused" reply = Refused r
  | Just t <- field "timeout" reply =
      -- The schema's timeout carries `{"ms": n}`; anything else is shown whole
      -- rather than reported as an unnamed budget.
      Timeout (maybe (render t) tshow (intOf =<< field "ms" t))
  | Just e <- field "error" reply = Errored (fromMaybe (render e) (textOf e))
  | Just _ <- field "level" reply = Checked
  | otherwise = Unknown

-- ---------------------------------------------------------------------------
-- Running a property
-- ---------------------------------------------------------------------------

-- | What one case came to.
data Verdict
  = Agreed
  | -- | A reason, counted and named in the summary. Never a failure.
    Skipped Text
  | -- | A headline, and the values to print under it.
    Diverged Text [(Text, Value)]

data Tally = Tally
  { tallyName :: !Text,
    tallyAttempted :: !Int,
    tallyAgreed :: !Int,
    tallyFailed :: !Int,
    tallySkips :: !(Map Text Int)
  }

-- | Run one property over its cases, printing each divergence in full as it
-- happens and carrying on. A failure that scrolls past is still a failure the
-- summary counts, and a run that stopped at the first one would hide the
-- second constructor that is also broken.
runProperty :: Text -> [a] -> (a -> IO Verdict) -> IO Tally
runProperty name xs step = go (zip [1 :: Int ..] xs) (Tally name 0 0 0 M.empty)
  where
    go [] t = pure t
    go ((i, x) : rest) t = do
      v <- step x
      t' <- case v of
        Agreed -> pure t {tallyAgreed = tallyAgreed t + 1}
        Skipped reason ->
          pure t {tallySkips = M.insertWith (+) reason 1 (tallySkips t)}
        Diverged headline shown -> do
          TIO.putStrLn ("FAIL " <> name <> " #" <> tshow i <> ": " <> headline)
          forM_ shown $ \(what, v') ->
            TIO.putStrLn ("  " <> what <> ": " <> render v')
          pure t {tallyFailed = tallyFailed t + 1}
      go rest t' {tallyAttempted = tallyAttempted t' + 1}

-- | Force a pure value through its rendering, inside 'try'.
--
-- Rendering is the cheapest total traversal to hand: it visits every field of
-- the 'Value', so an @error@ hiding in a lazily built trace is raised here,
-- where it becomes this case's failure, rather than later inside the printer.
-- An asynchronous exception is the user talking and is re-thrown.
forced :: Value -> IO (Either Text Value)
forced v = do
  caught <- try (evaluate (let t = render v in T.length t `seq` v))
  case caught :: Either SomeException Value of
    Right v' -> pure (Right v')
    Left e
      | Just (_ :: SomeAsyncException) <- fromException e -> throwIO e
      | otherwise -> pure (Left (squash (tshow e)))

-- ---------------------------------------------------------------------------
-- The summary
-- ---------------------------------------------------------------------------

summarize :: [Tally] -> IO ()
summarize ts = do
  TIO.putStrLn ("bisim: " <> T.intercalate ", " (map one ts) <> ", " <> failures)
  forM_ ts $ \t ->
    forM_ (M.toList (tallySkips t)) $ \(reason, k) ->
      TIO.putStrLn ("bisim: " <> tallyName t <> " skipped " <> tshow k <> ": " <> reason)
  -- §3.4's complaint, made out loud: a refusal-path generator whose output is
  -- almost entirely `other` is not reaching the five guards it exists to test,
  -- and the coverage it reports is not the coverage anyone wanted. This is a
  -- statement about the generator, not a conformance failure, so it warns
  -- rather than failing.
  forM_ ts $ \t -> do
    let others = M.findWithDefault 0 "other" (tallySkips t)
        n = tallyAttempted t
    unless (n == 0 || others * 10 <= n * 9) $
      TIO.putStrLn $
        "bisim: WARNING "
          <> tallyName t
          <> ": "
          <> tshow others
          <> " of "
          <> tshow n
          <> " draws were refused `other`, over 90% — the generator is too \
             \wild to reach the five guards, and this property is not \
             \testing what it claims"
  if total == 0 then exitSuccess else exitFailure
  where
    total = sum (map tallyFailed ts)
    failures = tshow total <> (if total == 1 then " failure" else " failures")
    one t =
      tallyName t
        <> " "
        <> tshow (tallyAgreed t)
        <> "/"
        <> tshow (tallyAttempted t)
        <> skipNote t
    skipNote t =
      let others = M.findWithDefault 0 "other" (tallySkips t)
       in if others == 0 then "" else " (" <> tshow others <> "-other skipped)"

-- ---------------------------------------------------------------------------
-- Value inspection
-- ---------------------------------------------------------------------------

-- | A missing key and an explicit null read alike, as everywhere else in this
-- port.
field :: Text -> Value -> Maybe Value
field k (Object o) = case KM.lookup (K.fromText k) o of
  Just Null -> Nothing
  other -> other
field _ _ = Nothing

textOf :: Value -> Maybe Text
textOf (String s) = Just s
textOf _ = Nothing

intOf :: Value -> Maybe Integer
intOf (Number s) = case floatingOrInteger s :: Either Double Integer of
  Right i -> Just i
  Left _ -> Nothing
intOf _ = Nothing

-- ---------------------------------------------------------------------------
-- Structural diffing: the first place two values part company
-- ---------------------------------------------------------------------------

-- | @firstDiff expected actual@ names the first divergence as a JSON path plus
-- the two offending fragments, so a mismatch points at its own field —
-- @$.worlds[1].trace[3].prompt@ — rather than leaving a reader to compare two
-- pages of JSON by eye.
--
-- The same function lives in @tier1\/Main.hs@; the two runners are owned by
-- different implementers this phase, and it belongs in the library the moment
-- one person owns both. Until then the duplication is deliberate and noted
-- rather than papered over by a hasty shared module.
firstDiff :: Value -> Value -> Maybe Text
firstDiff = go "$"
  where
    go path expected actual = case (expected, actual) of
      (Object a, Object b)
        | not (null missing) -> Just (path <> ": missing key(s) " <> keyList missing)
        | not (null extra) -> Just (path <> ": unexpected key(s) " <> keyList extra)
        | otherwise ->
            firstJust
              [ go (path <> "." <> K.toText k) va vb
                | k <- sort (KM.keys a),
                  Just va <- [KM.lookup k a],
                  Just vb <- [KM.lookup k b]
              ]
        where
          missing = sort [k | k <- KM.keys a, not (KM.member k b)]
          extra = sort [k | k <- KM.keys b, not (KM.member k a)]
      (Array a, Array b)
        | V.length a /= V.length b ->
            Just $
              path
                <> ": array length: oracle "
                <> tshow (V.length a)
                <> ", haskell "
                <> tshow (V.length b)
        | otherwise ->
            firstJust
              [ go (path <> "[" <> tshow i <> "]") x y
                | (i, (x, y)) <- zip [(0 :: Int) ..] (zip (V.toList a) (V.toList b))
              ]
      _
        | expected == actual -> Nothing
        | otherwise ->
            Just $
              path
                <> ": oracle "
                <> clip (render expected)
                <> ", haskell "
                <> clip (render actual)

    keyList ks = T.intercalate ", " (map (render . String . K.toText) ks)

firstJust :: [Maybe a] -> Maybe a
firstJust xs = case catMaybes xs of
  (x : _) -> Just x
  [] -> Nothing

-- ---------------------------------------------------------------------------
-- Rendering: canonical, one line, and ASCII-safe
-- ---------------------------------------------------------------------------

-- | Keys sorted so two renderings are comparable by eye, and every
-- non-printable or non-ASCII character escaped — a prompt that differs by an
-- invisible character must not read as identical. The whole point of this
-- runner is that the trap texts contain exactly such characters.
render :: Value -> Text
render = \case
  Null -> "null"
  Bool True -> "true"
  Bool False -> "false"
  Number n -> case floatingOrInteger n :: Either Double Integer of
    Right i -> tshow i
    Left d -> tshow d
  String s -> renderString s
  Array xs -> "[" <> T.intercalate "," (map render (V.toList xs)) <> "]"
  Object o ->
    "{"
      <> T.intercalate
        ","
        [ renderString (K.toText k) <> ":" <> render v
          | (k, v) <- sortOn fst (KM.toList o)
        ]
      <> "}"

renderString :: Text -> Text
renderString t = "\"" <> T.concatMap esc t <> "\""
  where
    esc c = case c of
      '"' -> "\\\""
      '\\' -> "\\\\"
      '\n' -> "\\n"
      '\r' -> "\\r"
      '\t' -> "\\t"
      _
        | ord c < 0x20 || ord c > 0x7e -> uni (ord c)
        | otherwise -> T.singleton c
    uni n
      | n <= 0xffff = hex4 n
      | otherwise =
          let n' = n - 0x10000
           in hex4 (0xd800 + (n' `shiftR` 10)) <> hex4 (0xdc00 + (n' .&. 0x3ff))
    hex4 n = "\\u" <> T.justifyRight 4 '0' (T.pack (showHex n ""))

-- | Keep a diff headline to one line, however large the offending value. The
-- values themselves are printed whole, underneath it.
clip :: Text -> Text
clip t
  | T.length t > 400 = T.take 400 t <> "..."
  | otherwise = t

squash :: Text -> Text
squash = T.unwords . T.words

tshow :: (Show a) => a -> Text
tshow = T.pack . show
