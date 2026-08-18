-- | @agentic-run@ — plan an example, price it, or run it.
--
-- Three verbs over the programs of "Example.Harden", which are the walked
-- examples of @agent-cat\/example@ rebuilt in "Agentic.Workflow" — the
-- authoring surface, whose 'Agentic.Builder.Program' this module reads:
--
-- > agentic-run plan harden [--raw]
-- > agentic-run cost harden
-- > agentic-run run  harden --scripted
-- > agentic-run run  harden --session <id> [--binary PATH] [--poll MS]
-- >                                        [--timeout MS] [--verbose]
--
-- @plan@ and @cost@ read the elaborated 'Agentic.Plan.Plan' and say nothing a
-- run could contradict: they are the /static/ folds, decided before anybody is
-- asked anything. @run@ executes, through "Agentic.Exec"'s memoizing
-- interpreter, against one of two answering services — a table of canned
-- replies, or a live @agent-deck@ session by way of "Agentic.AgentDeck".
--
-- __The program is the same value tier1 pins.__ Nothing here rebuilds, adapts
-- or trims a program for execution; @agentic-run run harden@ runs the exact
-- 'Agentic.Builder.Program' that @tier1@ has already held against the frozen
-- corpus entry, print and reply alike. That is what makes a run evidence about
-- the language rather than about this executable.
--
-- == Exit codes
--
-- @0@ a completed run (or a printed plan or price); @1@ a usage error; @2@ a
-- transport failure — the session is stopped, the binary is missing, the turn
-- outran its budget; @3@ a run abandoned because an answer could not be read
-- after "Agentic.Exec"'s re-asks. The last two are kept apart because they ask
-- different things of the operator: @2@ is something to fix about the session,
-- @3@ is something that was said.
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main (main) where

import Control.Exception (Handler (..), catches)
import Data.Aeson (Value (..))
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.List (sort, sortOn)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import qualified Data.Vector as V
import System.Environment (getArgs)
import System.Exit (ExitCode (..), exitSuccess, exitWith)
import System.IO
  ( BufferMode (LineBuffering),
    hSetBuffering,
    hSetEncoding,
    stderr,
    stdout,
    utf8,
  )
import System.IO.Error (ioeGetErrorString, isUserError)
import Text.Read (readMaybe)

import Agentic.AgentDeck
  ( DeckConfig (..),
    DeckError,
    defaultDeckConfig,
    renderDeckError,
    worldOfDeck,
  )
import Agentic.Builder (Program, progPlan)
import Agentic.Exec (WorldIO, announcingWorld, runPlanIO, scriptedWorld)
import Agentic.Observe (printedValue, render, renderString)
import Agentic.Plan
  ( askNodes,
    codes,
    costM,
    costSummary,
    level,
    levelName,
    size,
  )
import Agentic.Raw (codeName)
import Agentic.World (Trace, billFresh, billMemo)
import Example.Harden (exampleNames, lookupExample)

-- ---------------------------------------------------------------------------
-- What was asked for
-- ---------------------------------------------------------------------------

-- | The command line, once it has been understood.
data Command
  = -- | The static folds, and the printed program when 'True'.
    Plan !Text !Bool
  | -- | The cost summary and the fold it summarizes.
    Cost !Text
  | -- | Execute, against one of the two answering services.
    Run !Text !Target

-- | Who answers.
data Target
  = -- | The canned table of 'scriptFor'.
    Scripted
  | -- | A live @agent-deck@ session.
    Live !DeckConfig

main :: IO ()
main = do
  -- A run's questions and answers are the output, and they arrive over
  -- minutes; line buffering is what makes them appear as they happen rather
  -- than in a block at the end. UTF-8 explicitly, because an answer can carry
  -- anything and a locale of @C@ would otherwise abort the run on an em dash.
  hSetBuffering stdout LineBuffering
  hSetEncoding stdout utf8
  hSetEncoding stderr utf8
  args <- map T.pack <$> getArgs
  case parseCommand args of
    Left problem -> die 1 problem
    Right cmd ->
      execute cmd
        `catches` [ Handler $ \(e :: DeckError) -> die 2 ("transport: " <> renderDeckError e),
                    Handler $ \(e :: IOError) ->
                      die 3 $
                        if isUserError e
                          then T.pack (ioeGetErrorString e)
                          else T.pack (show e)
                  ]

execute :: Command -> IO ()
execute = \case
  Plan name raw -> withExample name (planCmd name raw)
  Cost name -> withExample name (costCmd name)
  Run name target -> withExample name (runCmd name target)

-- | Look the example up, or fail naming the ones there are.
withExample :: Text -> (Program -> IO ()) -> IO ()
withExample name k = case lookupExample name of
  Just prog -> k prog >> exitSuccess
  Nothing ->
    die 1 $
      "no example named '"
        <> name
        <> "'; there is "
        <> T.intercalate " and " exampleNames

-- ---------------------------------------------------------------------------
-- plan
-- ---------------------------------------------------------------------------

-- | The five static folds the oracle reports, and — with @--raw@ — the program
-- as "Agentic.Builder" prints it.
--
-- Every line here is decided by the elaborated term alone. In particular
-- @askNodes@ counts the ask nodes /written/, which is not what any run will
-- put: a branch is not taken and a loop is unrolled, so the number to compare a
-- run's bill against is the cost fold below and not this one.
planCmd :: Text -> Bool -> Program -> IO ()
planCmd name raw prog = do
  say $ name <> ", as elaborated:"
  say ""
  say $ "  level     " <> levelName (level p)
  say $ "  size      " <> tshow (size p)
  say $ "  askNodes  " <> tshow (askNodes p)
  say $ "  codes     " <> renderCodes
  say $ "  cost      " <> renderSummary (costSummary p)
  if raw
    then do
      say ""
      say "  the program, as the builder prints it:"
      say ""
      say (indentBy 2 (prettyJson 0 (printedValue prog)))
    else say "  (--raw prints the program itself)"
  where
    p = progPlan prog

    -- @null@ and @[]@ are different answers: no single sequence of answer kinds
    -- exists (the program branches), against a program that asks nothing.
    renderCodes = case codes p of
      Nothing -> "(none — the program branches, so no one sequence of answer kinds)"
      Just [] -> "[] (nothing is asked)"
      Just cs -> T.intercalate ", " (map codeName cs)

-- ---------------------------------------------------------------------------
-- cost
-- ---------------------------------------------------------------------------

-- | The cost summary, and the fold it is a summary of.
--
-- @costSummary@ is @(minFold, maxFold, paths)@ over @costM@'s bag of bills:
-- one element per path through the program, each the number of consultations
-- that path pays for. The two bounds are what a run can be held against — a run
-- whose @billFresh@ falls outside them is a run of a different program — and
-- when they coincide the program has one price rather than a range.
--
-- The bag is sorted before it is printed, because a multiset has no order of
-- its own to report; @Explain.leafBills@ sorts the same one for the same
-- reason.
costCmd :: Text -> Program -> IO ()
costCmd name prog = do
  say $ name <> ", priced:"
  say ""
  say $ "  costSummary   " <> renderSummary (costSummary p)
  say ""
  case (mn, mx) of
    (Just lo, Just hi)
      | lo == hi ->
          say $
            "  every path consults "
              <> tshow lo
              <> " times, so this program has one price and not a range."
      | otherwise -> do
          say $ "  no path through this program consults fewer than " <> tshow lo <> " addressees,"
          say $ "  and none consults more than " <> tshow hi <> "."
    _ -> say "  the program has no paths, which is a program that cannot be run."
  say ""
  say $ "  the fold, path by path (" <> tshow paths <> " in all):"
  say $ "    " <> T.intercalate ", " (map renderRun (runLengths (sort leaves)))
  where
    p = progPlan prog
    (mn, mx, paths) = costSummary p
    leaves = costM p

    renderRun (n, k)
      | k == (1 :: Int) = tshow n
      | otherwise = tshow n <> " (×" <> tshow k <> ")"

-- | A sorted list as its runs, so nine paths that cost five things do not print
-- as nine fives.
runLengths :: (Eq a) => [a] -> [(a, Int)]
runLengths = foldr step []
  where
    step x ((y, k) : rest) | x == y = (y, k + 1) : rest
    step x acc = (x, 1) : acc

-- | @minFold n, maxFold m, over k paths@ — shared by @plan@ and @cost@ so the
-- two cannot disagree about the same three numbers.
--
-- The bounds are 'Maybe' because a plan can have no paths at all, in which case
-- there is no least and no greatest and saying @0@ would be saying something
-- false about a program that consults nothing.
renderSummary :: (Maybe Integer, Maybe Integer, Integer) -> Text
renderSummary (mn, mx, paths) =
  "minFold "
    <> bound mn
    <> ", maxFold "
    <> bound mx
    <> ", over "
    <> tshow paths
    <> (if paths == 1 then " path" else " paths")
  where
    bound = maybe "—" tshow

-- ---------------------------------------------------------------------------
-- run
-- ---------------------------------------------------------------------------

-- | Execute the program and report what it cost.
--
-- The world is wrapped in 'announcingWorld', so each question that is actually
-- put prints as two lines — the code, the addressee and the prompt on one, the
-- answer on the next. __A memo hit prints nothing__, because nothing was asked:
-- the printed lines are @billMemo@ many, and the trace they summarize is
-- @billFresh@ many. Seeing the two differ is seeing the memo table work.
runCmd :: Text -> Target -> Program -> IO ()
runCmd name target prog = do
  world <- announce
  say ""
  (_, tr) <- runPlanIO (announcingWorld (say . ("  " <>)) world) (progPlan prog)
  say ""
  report tr
  where
    announce :: IO WorldIO
    announce = case target of
      Scripted -> do
        say $ "running " <> name <> " against the scripted table (" <> tshow (length (scriptFor name)) <> " canned replies)"
        pure (scriptedWorld (scriptFor name))
      Live cfg -> do
        say $ "running " <> name <> " against agent-deck session " <> deckSession cfg
        say $
          "  polling every "
            <> tshow (deckPollMs cfg)
            <> "ms, "
            <> tshow (deckTimeoutMs cfg)
            <> "ms to a turn; every addressee — model, tool and person — is this one session"
        pure (worldOfDeck cfg)

    report :: Trace -> IO ()
    report tr = do
      say "  the run is over."
      say "    answer      () — a workflow's value is the unit; what it did is the trace"
      say $ "    billFresh   " <> tshow (billFresh tr) <> " (consultations the run reached)"
      say $ "    billMemo    " <> tshow (billMemo tr) <> " (distinct questions, which is what was put)"

-- ---------------------------------------------------------------------------
-- The canned answers
-- ---------------------------------------------------------------------------

-- | The scripted table for an example: the canned replies of
-- @agent-cat\/test\/stub_adapter.py@, __keyed by prefix__ rather than by
-- substring.
--
-- The stub matches substrings (@\"correct?\"@, @\"secure?\"@), which
-- 'scriptedWorld' deliberately does not: a substring key can match a prompt
-- through an answer that was spliced into it, so a patch that mentioned
-- @correct?@ would answer the reviewers' question. Prefixes cannot do that, and
-- the flagship's prompts are already distinguishable by their first line — two
-- of the three reviews open with the guide, and their second lines differ.
--
-- The answers are the stub's: a fixed guide, a fixed patch, three approvals,
-- consent, and a receipt. Under them the revision settles in its first round,
-- so the amendment prompt is never put and the run bills seven consultations —
-- @Harden.bill_demo@ in @demo\/Main.lean@.
scriptFor :: Text -> [(Text, Text)]
scriptFor "harden" =
  [ ("Write out the house style guide", guideText),
    ("Draft a patch satisfying:", patchText),
    (guideText <> "\nIs this patch correct?", "APPROVE"),
    (guideText <> "\nIs this patch secure?", "APPROVE"),
    ("Could this patch be simpler?", "APPROVE"),
    -- Unreachable while all three reviews approve, and here so that a run with
    -- an objecting table amends with a patch rather than with prose.
    (guideText <> "\nRevise this patch:", patchText),
    ("Apply this patch?", "yes"),
    ("Apply:", "DONE")
  ]
scriptFor "hello" =
  [ ("Name one thing worth greeting.", "the sunrise"),
    ("Write a greeting for this, and nothing else:", "Good morning, sunrise."),
    ("Say it:", "DONE")
  ]
scriptFor _ = []

-- | @stub_adapter.py:100@'s @GUIDE@.
guideText :: Text
guideText =
  "House style: two-space indent, no tabs, every public name documented, \
  \and failures returned rather than raised."

-- | @stub_adapter.py:105@'s @PATCH@ — a real unified diff, because the act's
-- prompt wraps it and a run that applied it would have something to apply.
patchText :: Text
patchText =
  "--- a/src/parse.c\n\
  \+++ b/src/parse.c\n\
  \@@\n\
  \-  char buf[64]; strcpy(buf, input);\n\
  \+  char buf[64]; snprintf(buf, sizeof buf, \"%s\", input);\n"

-- ---------------------------------------------------------------------------
-- The command line
-- ---------------------------------------------------------------------------

-- | Parse the arguments, or say what is wrong together with the usage.
parseCommand :: [Text] -> Either Text Command
parseCommand = \case
  [] -> Left usage
  [verb] | verb `elem` verbs -> Left (verb <> " needs an example: " <> T.intercalate " or " exampleNames)
  ("plan" : name : rest) -> case rest of
    [] -> Right (Plan name False)
    ["--raw"] -> Right (Plan name True)
    _ -> Left ("plan takes an example and, at most, --raw\n\n" <> usage)
  ("cost" : name : rest)
    | null rest -> Right (Cost name)
    | otherwise -> Left ("cost takes an example and nothing else\n\n" <> usage)
  ("run" : name : rest) -> Run name <$> parseTarget rest
  (verb : _) -> Left ("no verb '" <> verb <> "'\n\n" <> usage)
  where
    verbs = ["plan", "cost", "run"]

-- | The @run@ options. Two mutually exclusive worlds, and four knobs that
-- belong to the live one alone.
parseTarget :: [Text] -> Either Text Target
parseTarget = go Nothing (defaultDeckConfig "") False
  where
    go :: Maybe Text -> DeckConfig -> Bool -> [Text] -> Either Text Target
    go sess cfg scripted = \case
      [] -> case (scripted, sess) of
        (True, Nothing) -> Right Scripted
        (False, Just s) -> Right (Live cfg {deckSession = s})
        (True, Just _) -> Left "--scripted and --session name two different answerers; pick one"
        (False, Nothing) -> Left ("run needs --scripted or --session <id>\n\n" <> usage)
      ("--scripted" : rest) -> go sess cfg True rest
      ("--verbose" : rest) -> go sess cfg {deckVerbose = True} scripted rest
      ("--session" : v : rest) -> go (Just v) cfg scripted rest
      ("--binary" : v : rest) -> go sess cfg {deckBinary = T.unpack v} scripted rest
      ("--poll" : v : rest) -> withMs "--poll" v $ \n -> go sess cfg {deckPollMs = n} scripted rest
      ("--timeout" : v : rest) -> withMs "--timeout" v $ \n -> go sess cfg {deckTimeoutMs = n} scripted rest
      (flag : _) -> Left ("no option '" <> flag <> "' for run\n\n" <> usage)

    withMs :: Text -> Text -> (Int -> Either Text Target) -> Either Text Target
    withMs flag v k = case readMaybe (T.unpack v) of
      Just n | n >= 0 -> k n
      _ -> Left (flag <> " takes a number of milliseconds, not '" <> v <> "'")

usage :: Text
usage =
  T.intercalate
    "\n"
    [ "agentic-run — plan, price and run the worked examples",
      "",
      "  agentic-run plan <example> [--raw]",
      "  agentic-run cost <example>",
      "  agentic-run run  <example> --scripted",
      "  agentic-run run  <example> --session <id> [--binary PATH] [--poll MS]",
      "                                            [--timeout MS] [--verbose]",
      "",
      "  <example> is " <> T.intercalate " or " exampleNames,
      "",
      "  --scripted   answer from a table of canned replies, and ask nobody",
      "  --session    put every question — model, tool and person alike — to this",
      "               agent-deck session",
      "  --binary     the agent-deck executable (default: agent-deck, found on PATH)",
      "  --poll       milliseconds between two checks of the session's status",
      "  --timeout    milliseconds one turn may take before it is abandoned",
      "  --verbose    narrate the transport on stderr"
    ]

-- ---------------------------------------------------------------------------
-- Printing
-- ---------------------------------------------------------------------------

say :: Text -> IO ()
say = TIO.putStrLn

-- | Print the message on stderr and stop with this code.
die :: Int -> Text -> IO a
die code msg = do
  TIO.hPutStrLn stderr ("agentic-run: " <> msg)
  exitWith (ExitFailure code)

-- | A 'Value' over several lines, keys sorted, scalars rendered by
-- "Agentic.Observe" so that every escape in this executable is that module's.
prettyJson :: Int -> Value -> Text
prettyJson ind = \case
  Object o
    | KM.null o -> "{}"
    | otherwise ->
        wrap "{" "}" $
          [ pad (ind + 2) <> renderString (K.toText k) <> ": " <> prettyJson (ind + 2) v
          | (k, v) <- sortOn fst (KM.toList o)
          ]
  Array a
    | V.null a -> "[]"
    | otherwise ->
        wrap "[" "]" $
          [pad (ind + 2) <> prettyJson (ind + 2) v | v <- V.toList a]
  v -> render v
  where
    wrap open close items =
      open <> "\n" <> T.intercalate ",\n" items <> "\n" <> pad ind <> close
    pad n = T.replicate n " "

indentBy :: Int -> Text -> Text
indentBy n = T.intercalate "\n" . map (T.replicate n " " <>) . T.splitOn "\n"

tshow :: (Show a) => a -> Text
tshow = T.pack . show
