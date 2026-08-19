-- | @agentic-run@ — plan an example, price it, or run it.
--
-- Three verbs over the programs of "Example.Harden", which are the walked
-- examples of @agent-cat\/example@ rebuilt in "Agentic.Workflow" — the
-- authoring surface, whose 'Agentic.Builder.Program' this module reads:
--
-- > agentic-run plan harden [--raw] [--require-pinned]
-- > agentic-run cost harden
-- > agentic-run run  harden --scripted
-- > agentic-run run  harden --session <id> [--binary PATH] [--poll MS]
-- >                                        [--timeout MS] [--verbose]
-- > agentic-run run  harden --engine acp [--adapter stub|claude|codex|PATH]
-- >                                      [--adapter-arg ARG]... [--scratch DIR]
-- >                                      [--timeout MS] [--verbose]
--
-- @plan@ and @cost@ read the elaborated 'Agentic.Plan.Plan' and say nothing a
-- run could contradict: they are the /static/ folds, decided before anybody is
-- asked anything. @run@ executes, through "Agentic.Exec"'s memoizing
-- interpreter, against one of three answering services — a table of canned
-- replies, a live @agent-deck@ session by way of "Agentic.AgentDeck", or an ACP
-- adapter this process starts and speaks the protocol to ("Agentic.Acp").
--
-- The two live engines differ in who owns the process on the other end, which
-- is the whole of what @--engine@ says: @acp@ starts an adapter of its own and
-- owns the pipe; @deck@ sends into a session somebody else started and is
-- watching. Both end at "Agentic.Exec"'s decode loop, so a run means the same
-- thing either way and fails in the same words.
--
-- __The program is the same value tier1 pins.__ Nothing here rebuilds, adapts
-- or trims a program for execution; @agentic-run run harden@ runs the exact
-- 'Agentic.Builder.Program' that @tier1@ has already held against the frozen
-- corpus entry, print and reply alike. That is what makes a run evidence about
-- the language rather than about this executable.
--
-- == Exit codes
--
-- @0@ a completed run (or a printed plan or price); @1@ a usage error, which
-- includes a program refused by @--require-pinned@ — nothing was started, so
-- nothing is a run failure; @2@ a
-- transport failure — the session is stopped, the binary or the adapter is
-- missing, the turn outran its budget; @3@ a run abandoned over what arrived:
-- an answer "Agentic.Exec" could not read after its re-asks, or (over ACP) a
-- turn that did not complete where an act needed one to. The last two are kept
-- apart because they ask different things of the operator: @2@ is something to
-- fix about the transport, @3@ is something that was said, or not finished
-- being said.
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main (main) where

import Control.Exception (Handler (..), catches)
import Control.Monad (unless)
import Data.Aeson (Value (..))
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.List (sort, sortOn)
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import qualified Data.Vector as V
import GHC.Clock (getMonotonicTimeNSec)
import System.Directory (createDirectoryIfMissing, getTemporaryDirectory)
import System.Environment (getArgs)
import System.Exit (ExitCode (..), exitSuccess, exitWith)
import System.FilePath ((</>))
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

import Agentic.Acp
  ( AcpConfig (..),
    AcpError,
    adapterArgv,
    defaultAcpConfig,
    renderAcpError,
    withAcp,
    worldOfAcp,
  )
import Agentic.AgentDeck
  ( DeckConfig (..),
    DeckError,
    defaultDeckConfig,
    renderDeckError,
    worldOfDeck,
  )
import Agentic.Builder (Program, progPlan, progRawOut)
import Agentic.Exec (WorldIO, announcingWorld, runPlanIO, scriptedWorld)
import Agentic.Guards (guardUnpinnedAsk)
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
import Example.Isaac (isaacScript)

-- ---------------------------------------------------------------------------
-- What was asked for
-- ---------------------------------------------------------------------------

-- | The command line, once it has been understood.
--
-- The trailing 'Bool' on 'Plan' and 'Run' is @--require-pinned@, which is a
-- fact about the /program/ rather than about the verb or the transport, and so
-- is checked in 'withExample' where the program is first in hand — before a
-- plan is printed and before an adapter is started.
data Command
  = -- | The static folds, the printed program when the first 'Bool', and
    -- @--require-pinned@ in the second.
    Plan !Text !Bool !Bool
  | -- | The cost summary and the fold it summarizes.
    Cost !Text
  | -- | Execute, against one of the three answering services, under
    -- @--require-pinned@ when the 'Bool'.
    Run !Text !Target !Bool

-- | Who answers.
data Target
  = -- | The canned table of 'scriptFor'.
    Scripted
  | -- | A live @agent-deck@ session.
    Live !DeckConfig
  | -- | An ACP adapter this process starts.
    Adapter !AcpTarget

-- | What @--engine acp@ was told, before the run has a directory.
--
-- The working directory is settled in 'runCmd' and not in the parser, because a
-- run without @--scratch@ makes one — an act may write, and
-- 'Agentic.Acp.permissionByCode' authorizes a tool call in the session's
-- working directory, so a run that had not been given one of its own would be
-- authorizing writes into whatever directory it was started from.
data AcpTarget = AcpTarget
  { atConfig :: !AcpConfig,
    -- | @--scratch DIR@, or 'Nothing' for a fresh one.
    atScratch :: !(Maybe FilePath),
    -- | The word @--adapter@ took, for the header and for a diagnosis: an
    -- operator must be able to act on a message by retyping the name it
    -- contains (@Acp.Adapter.ofName_name@).
    atName :: !Text,
    -- | Whether @--adapter@ was /given/, as against left at its default. The
    -- name alone cannot say — @stub@ is both a thing to type and what a silent
    -- command line means — and the run announces the default rather than
    -- taking it silently.
    atGiven :: !Bool
  }

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
                    Handler $ \(e :: AcpError) -> die 2 ("transport: " <> renderAcpError e),
                    Handler $ \(e :: IOError) ->
                      die 3 $
                        if isUserError e
                          then T.pack (ioeGetErrorString e)
                          else T.pack (show e)
                  ]

execute :: Command -> IO ()
execute = \case
  Plan name raw pinned -> withExample pinned name (planCmd name raw)
  Cost name -> withExample False name (costCmd name)
  Run name target pinned -> withExample pinned name (runCmd name target)

-- | Look the example up, or fail naming the ones there are — and, under
-- @--require-pinned@, refuse a program that leaves a model ask without a
-- @served by@.
--
-- __The check runs before the verb does__, so a refused program prints no plan,
-- starts no adapter and spends nothing. That is the whole value of an opt-in
-- guard over a program: it is a statement about the text, and the text is
-- available before anybody is asked anything.
--
-- Exit @1@, with the guard's own words. It is a usage exit and not a run exit
-- because nothing ran: the operator asked for a guarantee this program does not
-- carry, and the two ways out are to pin the ask or to drop the flag.
withExample :: Bool -> Text -> (Program -> IO ()) -> IO ()
withExample pinned name k = case lookupExample name of
  Just prog
    | pinned, Just why <- guardUnpinnedAsk (progRawOut prog) -> die 1 ("refused: " <> why)
    | otherwise -> k prog >> exitSuccess
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
runCmd name target prog = case target of
  Scripted -> do
    say $
      "running "
        <> name
        <> " against the scripted table ("
        <> tshow (length (scriptFor name))
        <> " canned replies)"
    walk (scriptedWorld (scriptFor name))
  Live cfg -> do
    say $ "running " <> name <> " against agent-deck session " <> deckSession cfg
    say $
      "  polling every "
        <> tshow (deckPollMs cfg)
        <> "ms, "
        <> tshow (deckTimeoutMs cfg)
        <> "ms to a turn; every addressee — model, tool and person — is this one session"
    walk (worldOfDeck cfg)
  Adapter at -> do
    dir <- maybe freshScratch pure (atScratch at)
    createDirectoryIfMissing True dir
    let cfg = (atConfig at) {acpCwd = dir}
    say $
      "running "
        <> name
        <> " against the "
        <> atName at
        <> " adapter: "
        <> T.unwords (map T.pack (acpCommand cfg))
    -- A default that was not typed is announced rather than assumed: `stub` is
    -- both a word an operator can write and what a silent command line means,
    -- and the difference is the difference between a run that answers itself
    -- and one that reaches a real agent.
    unless (atGiven at) $
      say "  no --adapter given, so the stub answers — the same default agent-cat's own CLI takes"
    say $
      "  cwd "
        <> T.pack dir
        <> ", "
        <> tshow (acpTurnTimeoutMs cfg)
        <> "ms to a turn, "
        <> (if acpFreshPerQuestion cfg then "a new session per question" else "one session for the run")
        <> "; every addressee — model, tool and person — is this one adapter"
    withAcp cfg (walk . worldOfAcp cfg)
  where
    walk :: WorldIO -> IO ()
    walk world = do
      say ""
      (_, tr) <- runPlanIO (announcingWorld (say . ("  " <>)) world) (progPlan prog)
      say ""
      report tr

    report :: Trace -> IO ()
    report tr = do
      say "  the run is over."
      say "    answer      () — a workflow's value is the unit; what it did is the trace"
      say $ "    billFresh   " <> tshow (billFresh tr) <> " (consultations the run reached)"
      say $ "    billMemo    " <> tshow (billMemo tr) <> " (distinct questions, which is what was put)"

-- | A directory of this run's own, under the system temporary directory, for a
-- @--engine acp@ run that named none.
--
-- Every run acts somewhere: a workflow may end in an act that writes, and
-- 'Agentic.Acp.permissionByCode' authorizes a tool call /in the session's
-- working directory/. Making one per run is what keeps the answer to "where may
-- this agent write?" from being "wherever you happened to be standing".
freshScratch :: IO FilePath
freshScratch = do
  tmp <- getTemporaryDirectory
  stamp <- getMonotonicTimeNSec
  pure (tmp </> ("agentic-run-" <> show stamp))

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
-- "Example.Isaac"'s five carry their own table, in their own module, because
-- its keys /are/ the prompt defines those programs are written from: a key
-- there is a prefix by construction rather than by proofreading, which is what
-- a table living beside a program in another file cannot promise.
scriptFor name = isaacScript name

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
  ("plan" : name : rest) -> planOpts name False False rest
  ("cost" : name : rest)
    | null rest -> Right (Cost name)
    | otherwise -> Left ("cost takes an example and nothing else\n\n" <> usage)
  ("run" : name : rest) -> (\(t, p) -> Run name t p) <$> parseTarget rest
  (verb : _) -> Left ("no verb '" <> verb <> "'\n\n" <> usage)
  where
    verbs = ["plan", "cost", "run"]

    -- Two independent flags, so they are folded rather than enumerated: the
    -- pair spelled in the other order is the same request.
    planOpts :: Text -> Bool -> Bool -> [Text] -> Either Text Command
    planOpts name raw pinned = \case
      [] -> Right (Plan name raw pinned)
      ("--raw" : more) -> planOpts name True pinned more
      ("--require-pinned" : more) -> planOpts name raw True more
      (flag : _) ->
        Left
          ( "no option '"
              <> flag
              <> "' for plan, which takes an example and, at most, --raw and "
              <> "--require-pinned\n\n"
              <> usage
          )

-- | What the @run@ options say, before it has been decided whether they say
-- anything coherent.
--
-- One record rather than a fold of positional accumulators, because the flags
-- now belong to three answerers and the refusals below are about which
-- /combinations/ name one answerer: a flag's engine is a fact about the flag,
-- and reading it off an argument position is how a flag comes to be silently
-- accepted by the transport it means nothing to.
data RunOpts = RunOpts
  { roScripted :: !Bool,
    roEngine :: !(Maybe Text),
    roSession :: !(Maybe Text),
    roBinary :: !(Maybe Text),
    roPollMs :: !(Maybe Int),
    roTimeoutMs :: !(Maybe Int),
    roVerbose :: !Bool,
    roAdapter :: !(Maybe Text),
    -- | In the order given, which is the order they reach the child's @argv@.
    roAdapterArgs :: ![Text],
    roScratch :: !(Maybe Text),
    -- | @--require-pinned@. Belongs to no engine — it is a question about the
    -- program's text, which is the same text whoever answers it — so it is the
    -- one flag 'chooseTarget' neither forbids nor consumes.
    roRequirePinned :: !Bool
  }

noRunOpts :: RunOpts
noRunOpts = RunOpts False Nothing Nothing Nothing Nothing Nothing False Nothing [] Nothing False

-- | The @run@ options: three mutually exclusive answerers, the knobs that
-- belong to one of them alone, and @--require-pinned@, which belongs to none.
parseTarget :: [Text] -> Either Text (Target, Bool)
parseTarget args = do
  o <- go noRunOpts args
  t <- chooseTarget o
  pure (t, roRequirePinned o)
  where
    go :: RunOpts -> [Text] -> Either Text RunOpts
    go o = \case
      [] -> Right o
      ("--scripted" : rest) -> go o {roScripted = True} rest
      ("--verbose" : rest) -> go o {roVerbose = True} rest
      ("--require-pinned" : rest) -> go o {roRequirePinned = True} rest
      ("--engine" : v : rest)
        | v `elem` ["acp", "deck"] -> go o {roEngine = Just v} rest
        | otherwise ->
            Left $
              "unknown engine '"
                <> v
                <> "': --engine takes acp (start an adapter and speak the protocol to it) "
                <> "or deck (send to a live agent-deck session)"
      ("--session" : v : rest) -> go o {roSession = Just v} rest
      ("--binary" : v : rest) -> go o {roBinary = Just v} rest
      ("--adapter" : v : rest) -> go o {roAdapter = Just v} rest
      ("--adapter-arg" : v : rest) -> go o {roAdapterArgs = roAdapterArgs o <> [v]} rest
      ("--scratch" : v : rest) -> go o {roScratch = Just v} rest
      ("--poll" : v : rest) -> withMs "--poll" v (\n -> go o {roPollMs = Just n} rest)
      ("--timeout" : v : rest) -> withMs "--timeout" v (\n -> go o {roTimeoutMs = Just n} rest)
      (flag : _) -> Left ("no option '" <> flag <> "' for run\n\n" <> usage)

    withMs :: Text -> Text -> (Int -> Either Text a) -> Either Text a
    withMs flag v k = case readMaybe (T.unpack v) of
      Just n | n >= 0 -> k n
      _ -> Left (flag <> " takes a number of milliseconds, not '" <> v <> "'")

-- | Which answerer the options name — or a refusal saying which two of them
-- were named at once.
--
-- Every combination refused here is one where a flag would otherwise mean
-- nothing to the transport that was chosen, which is how a run comes to be
-- configured by a line nobody read.
chooseTarget :: RunOpts -> Either Text Target
chooseTarget o = case (roScripted o, roEngine o, roSession o) of
  (True, Just e, _) -> Left ("--scripted answers from a table and --engine " <> e <> " reaches an agent; pick one")
  (True, _, Just _) -> Left "--scripted and --session name two different answerers; pick one"
  (True, _, _) -> onlyScripted
  (_, Just "acp", Just _) ->
    Left
      "--engine acp starts an adapter of its own, and --session sends to an agent-deck \
      \session somebody else started; pick one"
  (_, Just "acp", _) -> adapter
  (_, Just "deck", Nothing) -> Left "--engine deck needs the session to send to: give --session <id> as well"
  (_, _, Just s) -> deck s
  _ -> Left ("run needs --scripted, --engine acp, or --session <id>\n\n" <> usage)
  where
    -- The flags of the two engines this run is not, refused by name.
    forbid :: Text -> [(Text, Bool)] -> Either Text ()
    forbid engine = \case
      ((flag, True) : _) -> Left (flag <> " is not " <> engine <> "'s to take")
      (_ : rest) -> forbid engine rest
      [] -> Right ()

    acpFlags = [("--adapter", isJust (roAdapter o)), ("--adapter-arg", not (null (roAdapterArgs o))), ("--scratch", isJust (roScratch o))]
    deckFlags = [("--binary", isJust (roBinary o)), ("--poll", isJust (roPollMs o))]
    liveFlags = acpFlags <> deckFlags <> [("--timeout", isJust (roTimeoutMs o)), ("--verbose", roVerbose o)]

    onlyScripted = Scripted <$ forbid "--scripted" liveFlags

    deck s = do
      -- `--adapter` names a child this run starts, and the deck engine starts
      -- none: there the answering agent is the one already in the session.
      forbid "the deck engine" acpFlags
      let base = defaultDeckConfig s
      pure . Live $
        base
          { deckBinary = maybe (deckBinary base) T.unpack (roBinary o),
            deckPollMs = fromMaybe (deckPollMs base) (roPollMs o),
            deckTimeoutMs = fromMaybe (deckTimeoutMs base) (roTimeoutMs o),
            deckVerbose = roVerbose o
          }

    adapter = do
      forbid "the acp engine" deckFlags
      -- The default is `stub`, the deterministic double: a command line that
      -- named no adapter must not spawn a real agent, spend a token or touch
      -- an account. (The retired Lean CLI kept the same default, for the same
      -- reason.)
      let name = fromMaybe "stub" (roAdapter o)
          base = defaultAcpConfig (adapterArgv name <> map T.unpack (roAdapterArgs o))
      pure . Adapter $
        AcpTarget
          { atConfig =
              base
                { acpTurnTimeoutMs = fromMaybe (acpTurnTimeoutMs base) (roTimeoutMs o),
                  acpVerbose = roVerbose o
                },
            atScratch = T.unpack <$> roScratch o,
            atName = name,
            atGiven = isJust (roAdapter o)
          }

usage :: Text
usage =
  T.intercalate
    "\n"
    [ "agentic-run — plan, price and run the worked examples",
      "",
      "  agentic-run plan <example> [--raw] [--require-pinned]",
      "  agentic-run cost <example>",
      "  agentic-run run  <example> --scripted",
      "  agentic-run run  <example> --session <id> [--binary PATH] [--poll MS]",
      "                                            [--timeout MS] [--verbose]",
      "  agentic-run run  <example> --engine acp [--adapter stub|claude|codex|PATH]",
      "                                          [--adapter-arg ARG]... [--scratch DIR]",
      "                                          [--timeout MS] [--verbose]",
      "",
      "  <example> is " <> T.intercalate " or " exampleNames,
      "",
      "  --scripted     answer from a table of canned replies, and ask nobody",
      "  --engine       acp starts an ACP adapter of its own and speaks the protocol",
      "                 to it over a pipe it owns; deck sends to a live agent-deck",
      "                 session somebody else started (which --session alone selects)",
      "  --session      put every question — model, tool and person alike — to this",
      "                 agent-deck session",
      "  --binary       the agent-deck executable (default: agent-deck, found on PATH)",
      "  --poll         milliseconds between two checks of the session's status",
      "  --adapter      the answering program (default: stub, the deterministic double",
      "                 at ../test/stub_adapter.py); claude and codex are looked for on",
      "                 PATH and then at their machine-local pins; anything else is a",
      "                 path. --engine acp only",
      "  --adapter-arg  one argument for the adapter's argv; repeatable.",
      "                 `--adapter-arg --refuse` is how the stub is told to answer *no*",
      "                 to a person's yes/no question. --engine acp only",
      "  --scratch      run in DIR instead of a fresh temporary directory: where the",
      "                 adapter is started, and the only place an act may write.",
      "                 --engine acp only",
      "  --timeout      milliseconds one turn may take before it is abandoned",
      "  --verbose      narrate the transport on stderr",
      "  --require-pinned",
      "                 refuse the program unless every model ask names the model",
      "                 that serves it (`servedBy`). Checked before anything is",
      "                 printed, started or spent; plan and run, any engine"
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
