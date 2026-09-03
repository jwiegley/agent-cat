{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- | The D6/D7 policy gate (`lake`-free, corpus-free): the six policies the
-- wave-one audit probed by hand, pinned as a program so the tree rather than a
-- transcript holds them (fess wave-1, finding F6).
--
-- Each probe runs 'Example.Harden.hardenProgram' against a scripted world
-- whose one deviation is that the owner's flag question answers @maybe@ —
-- unreadable at 'decodeEl' — and asserts what each policy does about it:
--
--   * defaults: one nudge, then abandonment, wording pinned to Exec's own;
--   * @esLoudArm = Just True@: the configured arm is taken, the act runs
--     (billFresh 7), the warning says the safety is the operator's;
--   * @esLoudArm = Just False@: the other arm, the act skipped (billFresh 6);
--   * @esStandingAnswer = Just "no"@: the person is answered from settings
--     (billFresh 6) with the standing-answer warning;
--   * @esRecover = const FailOver@: no re-ask at all (the policy did not answer
--     'Agentic.Exec.RetryHere'), and then, with no spare declared, exactly the
--     abandonment the run would have raised with no chain at all — which is why
--     it says \"after 1 attempts\" where the default policy's says two;
--   * @esRetryUndecodable = 3@: four attempts before the abandonment.
--
-- A third section pins __fail-over itself__ (D6), which is the one policy that
-- needs a chain and a world that refuses: a question pinned @deep or broad@, a
-- world that raises a gap at @deep@ and answers at @broad@, and three
-- assertions — the run settles, the trace names __the model that actually
-- answered__, and the narration says what it was about to do. Its fourth
-- assertion is the acceptance criterion the design states: __with no alternates
-- declared, the same world and the same program abandon in exactly the words
-- they always did.
--
-- A fourth pins D5's __executing world__: a @toolExec@ act whose command exits
-- 0 answers yes and pays for the act, one that exits nonzero answers no and
-- does not, two commands at one tool id are two questions, and a command that
-- cannot be run is a named gap rather than an answer. @true@ and @false@ and
-- nothing else.__
--
-- The probes assert on bills, on thrown wording, and on logged wording — the
-- three places a policy can lie.
--
-- A fifth pins __routing__ ("Agentic.Route"): the backend grammar an operator
-- types — both schemes, the first-colon split, the @NAME=BACKEND@ split, the
-- refusal wordings, which are the only part of a usage error anybody reads, and
-- that whitespace is part of neither half, a blank value being the refusal
-- @acp:@ gets rather than an adapter with no name — and the resolution rule
-- itself, which is that __a question is routed by its model axis and 'Nothing'
-- takes the default__. Then the two facts about the table a run's header rests
-- on — that 'Agentic.Route.routeBackends' is the /distinct/ backends with the
-- default first, so the header counts processes rather than route lines, and
-- that connecting the table with @fmap@ moves no question, so nothing can be
-- answered by a backend the header did not name — and the three claims routing
-- itself rests on:
--
--   * __it is invisible to the fold__ — the flagship run twice, once at an
--     empty route table and once at four /distinct/ backends that answer alike,
--     giving byte-identical traces and identical bills. That is the whole
--     compatibility argument made executable, and it is why this case is not
--     optional. Each backend notes that it was consulted, so the same rows also
--     say where the questions went: equal traces from one shared world would be
--     equal however they had been dispatched;
--   * __it never intercepts a @toolExec@__ — two program-authored commands
--     around a pinned ask, put to a table whose default raises and whose one
--     route answers, so a command that reached routing and an ask that reached
--     the default each fail, and only a run that intercepted both commands and
--     read the table settles;
--   * __a fail-over crosses backends__ — two /distinct/ worlds are two backends
--     as far as 'Agentic.Route.routedWorld' is concerned, and the acceptance
--     criterion is that with no spare declared the same two abandon in exactly
--     the words they always did.
--
-- Pure throughout: routing reads one field the interpreter has already
-- computed, so a probe of it needs no process, no network and no transport.
--
-- A sixth pins the __two prompt quoters__ ("Agentic.WF"): that @[wft|…|]@ and
-- @wfText [wf|…|]@ are the same bytes, hole for hole. That equality is what
-- made the sweep of @Example.Isaac@ safe, and it is a claim about two
-- expressions rather than about a program, so it is checked as two
-- expressions — the same block written both ways, with a hole naming a 'Text'
-- and a hole naming a fence. The rows that assert the /layout/ are there so
-- that two identically broken values cannot pass: a fence's text is dedented,
-- opens at its first word, and ends without a newline.
--
-- A seventh section pins the __concurrent interpreter__: independent prompt
-- overlap at one model with plan-ordered traces, exact blocking on shared input,
-- one owner for a memo key under a race, plan-ordered write effects and stateful
-- transport turns, and failure propagation that cancels and cleans up an
-- independent blocked worker. Every row synchronizes on events rather than
-- comparing elapsed runtimes.
--
-- A second section pins the __surface's own refusals__ (fess wave-2, gap V3):
-- the three mistakes 'Agentic.Workflow' answers with an @error@ rather than
-- with a type error, forced out of the four bottoms in "SurfaceRefusals". They
-- are here rather than in @tier1@ because a refusal has no corpus entry to be
-- pinned against — there is no program, so there is nothing to freeze — and
-- because what is worth pinning about them is the /wording/, which is the only
-- thing the author ever sees.
module Main (main) where

-- The runner, for one function: `run.routes` is derived there and read in
-- `Agentic.Workflow`, and the pair is one contract. And for the parse, whose
-- arm order IS the collision policy — read below over a registry that collides
-- with every verb, which neither real table does.
import Agentic.Acp (AcpConfig (..), adapterArgv, defaultAcpConfig, newSession, resolveArgv, sayAcp, withAcp)
import Agentic.Cli
  ( Command (..),
    Registry (..),
    Row (..),
    parseCommand,
    routesFact,
  )
import Agentic.Exec
import Agentic.Plan
  ( AnswerSource (AnswerAsked, AnswerReused),
    Cont (..),
    El,
    ExecEvent (ExecEvent),
    ExecTrace,
    Plan,
    Q (..),
    QScope (..),
    Request (..),
    RequestShape (..),
    SCode (SAck, SFlag, SStructured, SText, SVerdict),
    Shape (..),
    consultRequest,
    intentName,
    consultShape,
    effectRequest,
    observeRequest,
    effectShape,
    ask1,
    askC1,
    defaultEl,
    fromSCode,
    graft,
    pairP,
    scopeUnit,
    verdictApprove,
  )
import Agentic.Raw (Addressee (AddrModel, AddrPerson, AddrTool))
import Agentic.Route
  ( Backend (BackendAcp, BackendDeck),
    Routes,
    backendFor,
    backendSpelling,
    parseBackend,
    parseRoute,
    routeBackends,
    routeDefault,
    routeNamed,
    routedWorld,
    routes,
  )
import Agentic.Runtime.Control
import Agentic.Runtime.Machine (handleEventSink)
import Agentic.Runtime.Store
import Agentic.Runtime.Protocol
import Data.Aeson (Value, encode, object, toJSON, (.=))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Agentic.Shell (ShellConfig (shellCwd), defaultShellConfig, executingWorld)
import Agentic.Workflow
  ( Example (Fixed),
    InputSource (..),
    InputSpec (..),
    Parameterized,
    Words,
    argsInput,
    argsInputAs,
    input,
    inputSpecs,
    noInputs,
    routeDefaultLabel,
    routedBackend,
    sessionPolicy,
    sharesOneSession,
    stdinInput,
    stdinInputAs,
    taking,
    pattern (:>),
    wf,
    wft,
  )
import Agentic.World
  ( World (World), billExecFresh, billMemo, billMemoLegacy, eventJson,
    forgetExecEvent, trace
  )
import Control.Concurrent (forkFinally, forkIO, killThread, threadDelay)
import Control.Concurrent.STM
  ( TMVar,
    atomically,
    check,
    modifyTVar',
    newEmptyTMVarIO,
    newTVarIO,
    putTMVar,
    readTVar,
    retry,
    takeTMVar,
    tryPutTMVar,
  )
import Control.Exception (ErrorCall, SomeException, evaluate, finally, try)
import Data.Bits ((.&.))
import Control.Monad (void)
import Data.IORef
import Data.List (nub, sort)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Example.Harden (hardenProgram)
import Agentic.Builder
  ( Code (CodeAck, CodeFlag, CodeText),
    Program,
    act,
    askModelFallingBack,
    askTool,
    askToolRunning,
    bindAs,
    ifFlag,
    lit,
    one,
    program,
    progPlan,
    stop,
    wordsClosed,
  )
import qualified Data.Map.Strict as Map
import Agentic.Observe (printedValue)
import GHC.Clock (getMonotonicTimeNSec)
import System.Directory (createDirectoryIfMissing, doesFileExist, getTemporaryDirectory, removePathForcibly)
import System.FilePath ((</>))
import System.Posix.Files (fileMode, getFileStatus)
import System.Exit (exitFailure)
import System.IO (IOMode (WriteMode), withBinaryFile)
import System.Timeout (timeout)

import SurfaceRefusals
  ( callsAnUnlistedFunction,
    inputIsMisspelledRunFact,
    namedIsReserved,
    takesIsReserved,
    twoOfOneName,
  )

-- The flagship's scripted answers with the flag made unreadable.
maybeScript :: [(Text, Text)]
maybeScript = [("Apply this patch?", "maybe")]

probe ::
  IORef Int ->
  String ->
  ExecSettings ->
  Either Text (Integer, Integer) ->
  IO ()
probe failures name st expect = do
  logged <- newIORef []
  let st' = st {esLog = \t -> modifyIORef' logged (t :)}
  out <- try (runPlanIO (scriptedWorldWith st' maybeScript) (progPlan hardenProgram))
  msgs <- readIORef logged
  let failWith why = do
        TIO.putStrLn ("FAIL " <> T.pack name <> ": " <> why)
        mapM_ (TIO.putStrLn . ("  log: " <>)) (reverse msgs)
        modifyIORef' failures (+ 1)
  case (out, expect) of
    (Left (e :: SomeException), Left needle)
      | needle `T.isInfixOf` T.pack (show e) ->
          TIO.putStrLn ("ok   " <> T.pack name)
      | otherwise -> failWith ("threw, but not with: " <> needle)
    (Left (e :: SomeException), Right _) ->
      failWith ("threw unexpectedly: " <> T.pack (show e))
    (Right _, Left needle) ->
      failWith ("completed, but should have thrown: " <> needle)
    (Right (_, tr), Right (wantFresh, wantMemo))
      | billExecFresh tr == wantFresh && billMemo tr == wantMemo ->
          TIO.putStrLn ("ok   " <> T.pack name)
      | otherwise ->
          failWith
            ( "bills ("
                <> T.pack (show (billExecFresh tr))
                <> ","
                <> T.pack (show (billMemo tr))
                <> ") wanted ("
                <> T.pack (show wantFresh)
                <> ","
                <> T.pack (show wantMemo)
                <> ")"
            )

probeLogged :: IORef Int -> String -> ExecSettings -> Text -> IO ()
probeLogged failures name st needle = do
  logged <- newIORef []
  let st' = st {esLog = \t -> modifyIORef' logged (t :)}
  _ <- try @SomeException (runPlanIO (scriptedWorldWith st' maybeScript) (progPlan hardenProgram))
  msgs <- readIORef logged
  if any (needle `T.isInfixOf`) msgs
    then TIO.putStrLn ("ok   " <> T.pack name)
    else do
      TIO.putStrLn ("FAIL " <> T.pack name <> ": nothing logged containing: " <> needle)
      mapM_ (TIO.putStrLn . ("  log: " <>)) (reverse msgs)
      modifyIORef' failures (+ 1)

-- | One surface refusal: force the program's /printed/ value — which is what
-- every caller of a 'Program' does first, and what runs the surface's checks —
-- and assert that it raised an 'ErrorCall' containing this fragment.
--
-- 'ErrorCall' rather than 'SomeException' on purpose: these are @error@ calls,
-- and a program that failed some other way (a pattern match, an arithmetic
-- fault) must not read as the refusal under test. @show@ of the printed value
-- is what forces it past weak head normal form, so a refusal buried in one
-- function of a table is reached as surely as one at the top.
refusal :: IORef Int -> String -> Program -> Text -> IO ()
refusal failures name prog needle = do
  out <- try (evaluate (length (show (printedValue prog))))
  case out :: Either ErrorCall Int of
    Left e
      | needle `T.isInfixOf` T.pack (show e) ->
          TIO.putStrLn ("ok   " <> T.pack name)
      | otherwise -> do
          TIO.putStrLn
            ( "FAIL "
                <> T.pack name
                <> ": refused, but not with: "
                <> needle
            )
          TIO.putStrLn ("  said: " <> T.pack (show e))
          modifyIORef' failures (+ 1)
    Right _ -> do
      TIO.putStrLn
        ( "FAIL "
            <> T.pack name
            <> ": the program printed, and should have been refused with: "
            <> needle
        )
      modifyIORef' failures (+ 1)

-- ---------------------------------------------------------------------------
-- Fail-over (D6)
-- ---------------------------------------------------------------------------

-- | One flag question, pinned to @deep@ with @broad@ behind it, and an act on
-- the yes arm. The smallest program in which a fail-over is observable at all:
-- the chain is on the question, the answer decides a branch, and the act is
-- what makes the bills say whether the run got an answer.
failOverProgram :: Program
failOverProgram =
  program [] $
    bindAs @"ok" @'CodeFlag
      (one (askModelFallingBack "r" "deep" ["broad"] [lit "ready?"]))
      $ \ok -> ifFlag ok (act (askTool "log" [lit "yes"]) stop) stop

-- | A world that will not answer for one model and will for anyone else.
--
-- It raises a __gap__ rather than an ordinary error, which is the whole
-- distinction the fail-over walk turns on: a gap is \"nothing usable came
-- back\" and may be put to another model; anything else is a defect and is
-- rethrown untouched, because re-running broken work on a second, pricier model
-- bills twice for hiding it.
refusingWorld :: Text -> WorldIO
refusingWorld bad = concurrentWorld $ \c q ->
  if scopeModelAxis (scopeOf q) == Just bad
    then
      raiseGap
        GapTransportRefusal
        (bad <> " is not answering")
        (userError ("no readable flag from model r after 1 attempts"))
    else pure (answerAt c q)
  where
    answerAt :: SCode c -> Request c -> El c
    answerAt SFlag _ = True
    answerAt SAck _ = ()
    answerAt SText q = promptOf q
    answerAt SVerdict _ = verdictApprove
    answerAt code@(SStructured _) _ = defaultEl code

-- | The model each event's scope names, in trace order.
answerers :: ExecTrace -> [Maybe Text]
answerers = map answerer
  where
    answerer (ExecEvent _ _ (AnswerAsked q) _) = scopeModelAxis (qScope q)
    answerer (ExecEvent _ _ AnswerReused _) = Nothing

authoredModels :: ExecTrace -> [Maybe Text]
authoredModels = map (\(ExecEvent _ r _ _) -> scopeModelAxis (qScope (reqQuestion r)))

-- ---------------------------------------------------------------------------
-- The executing world (D5)
-- ---------------------------------------------------------------------------

-- | A world that answers nothing, so that a @toolExec@ question answered by
-- anything but the executing layer is a loud failure rather than a quiet pass.
noWorld :: WorldIO
noWorld = concurrentWorld $ \c q ->
  ioError
    ( userError
        ( "the executing layer did not take a "
            <> T.unpack (codeWord (fromSCode c))
            <> " question put to "
            <> T.unpack (addresseeWord (addresseeOf q))
        )
    )

-- | One @toolExec@ act at a chosen code, running a chosen command.
runningProgram :: Text -> [Text] -> Program
runningProgram cmd args =
  program [] $
    bindAs @"g" @'CodeFlag (one (askToolRunning "green" cmd args [lit "check"])) $
      -- The yes arm is a `toolExec` too, so that __every__ question in this
      -- program is the executing layer's and `noWorld` can stay strict: a
      -- question that reached the world beneath would be a routing bug, and
      -- here it is a raised error rather than a quiet pass.
      \g -> ifFlag g (act (askToolRunning "log" "true" ["green"] [lit "note"]) stop) stop

-- | Two commands at one tool id, same words: __two questions__, which is why
-- the argv rides in the addressee.
twoCommandsProgram :: Program
twoCommandsProgram =
  program [] $
    act (askToolRunning "green" "true" ["one"] [lit "gate"]) $
      act (askToolRunning "green" "true" ["two"] [lit "gate"]) stop

-- ---------------------------------------------------------------------------
-- The two prompt quoters (Agentic.WF)
-- ---------------------------------------------------------------------------

-- | The conversion every define in this tree used to be written through.
--
-- Spelled out here rather than imported: @Example.Isaac@ carried a copy of it
-- and applied it forty-six times, and the sweep to 'wft' deleted both the copy
-- and every application. This is the /old/ side of the comparison, so it has to
-- go on being spelled the old way — and nothing else in the tree may.
--
-- It lives in this module and not in "SurfaceRefusals" because it needs no
-- @RebindableSyntax@, which is the one reason that module exists.
wfText :: Words '[] -> Text
wfText = fromMaybe "" . wordsClosed

-- | A define written as a fence and left as one, so that a hole below names a
-- 'Words' rather than a 'Text': the second of the two @define@ shapes 'Says'
-- knows, and the one whose splice is a list of chunks rather than one chunk.
verdictFence :: Words '[]
verdictFence = [wf|Reply with exactly APPROVE if you find nothing, or OBJECTION: <one line> for each finding.|]

-- | A hole-free define, both ways.
lensOldWay, lensNewWay :: Text
lensOldWay = wfText [wf|
  Correctness lens. Read the change below and report only defects that are
  wrong on inputs this code will actually see.

  For each: the location, the input that reaches it, and what it produces
  instead of the right answer.|]
lensNewWay = [wft|
  Correctness lens. Read the change below and report only defects that are
  wrong on inputs this code will actually see.

  For each: the location, the input that reaches it, and what it produces
  instead of the right answer.|]

-- | A define that holes a computed count and a fence, both ways — @qaFence@'s
-- shape, which is the shape that would break first if the two quoters splice a
-- hole differently.
holedOldWay, holedNewWay :: Text
holedOldWay = wfText [wf|
  You are one of {reviewers} independent reviewers and there is no synthesis
  step behind you, so anything you repeat ships twice. The other {siblings}
  own the rest.

  {verdictFence}|]
holedNewWay = [wft|
  You are one of {reviewers} independent reviewers and there is no synthesis
  step behind you, so anything you repeat ships twice. The other {siblings}
  own the rest.

  {verdictFence}|]

-- | The two counts the holes above name, derived as @qaFence@ derives its own.
reviewers, siblings :: Text
reviewers = "6"
siblings = "5"

-- ---------------------------------------------------------------------------
-- Routing (Agentic.Route)
-- ---------------------------------------------------------------------------

-- | One row of the routing section: every case must hold, and a row that fails
-- names the cases that did rather than only the row.
--
-- Rows rather than one assertion each because "Agentic.Route"'s grammar is a
-- handful of spellings of one rule, and a gate that printed a line per spelling
-- would report six facts where there is one.
-- | A registry every one of whose rows is named after a verb.
--
-- Both shell gates check today's two tables against the reserved set, and a
-- green run of either is a fact about /those tables/ — it would stay green if
-- the parse changed. This is the policy instead: 'Agentic.Cli.parseCommand'
-- decides a verb in head position before a row name is ever looked up, so these
-- rows are unreachable __by name__ rather than ambiguous, which is exactly what
-- makes unreachable-but-registered a thing a gate can shout about.
--
-- No program here is ever run. The parse is a pure function of the arguments
-- and the registry's /names/, so the flagship stands in for six programs and
-- the rows differ in nothing but what they are called.
collidingRegistry :: Registry
collidingRegistry =
  Registry
    { regBinary = "wf",
      regNoun = "workflow",
      regBanner = "a table that collides with its own verbs",
      regRows = [(n, row) | n <- ["run", "machine", "plan", "cost", "list", "help", "ordinary"]]
    }
  where
    row = Row (Fixed hardenProgram) "one line" "a page" []

-- | What a parse came back as, in one word plus the name it settled on.
--
-- The policy is about which /arm/ answered, so it is stated as an equality on
-- that rather than as a pattern match written once per case. The two refusals
-- that matter are told apart by their wording, which is the same wording an
-- operator reads.
parsedAs :: [Text] -> String
parsedAs args = case parseCommand collidingRegistry args of
  Right Usage -> "usage"
  Right (Help n) -> "help " <> T.unpack n
  Right (List _) -> "list"
  Right (Plan n _ _ _ _) -> "plan " <> T.unpack n
  Right (Cost n _) -> "cost " <> T.unpack n
  Right (Run n _ _ _) -> "run " <> T.unpack n
  Right (Machine _ n _ _ _) -> "machine " <> T.unpack n
  Right (LineageCheck _ _ _ n _ _ _) -> "lineage-check " <> T.unpack n
  Right (MachineLineage _ _ _ _ n _ _ _) -> "machine-lineage " <> T.unpack n
  Left t
    | "and not a verb" `T.isInfixOf` t -> "bare-row"
    | "no verb '" `T.isInfixOf` t -> "no-verb"
    | otherwise -> "refused"

pureProbe :: IORef Int -> String -> [(String, Bool)] -> IO ()
pureProbe failures name cases = case [c | (c, ok) <- cases, not ok] of
  [] -> TIO.putStrLn ("ok   " <> T.pack name)
  bad -> do
    TIO.putStrLn ("FAIL " <> T.pack name <> ": " <> T.pack (unwords bad))
    modifyIORef' failures (+ 1)

inputSourceProbe :: IORef Int -> IO ()
inputSourceProbe failures = do
  let defaults :: Parameterized
      defaults = taking (argsInput :> stdinInput :> input "tone" :> noInputs) $ \_ _ _ -> hardenProgram
      custom :: Parameterized
      custom = taking (argsInputAs "scope" :> stdinInputAs "document" :> noInputs) $ \_ _ -> hardenProgram
      duplicate :: Parameterized
      duplicate = taking (input "same" :> stdinInputAs "same" :> noInputs) $ \_ _ -> hardenProgram
      twoArgs :: Parameterized
      twoArgs = taking (argsInput :> argsInputAs "scope" :> noInputs) $ \_ _ -> hardenProgram
      twoStdin :: Parameterized
      twoStdin = taking (stdinInput :> stdinInputAs "document" :> noInputs) $ \_ _ -> hardenProgram
      sourcedRunFact :: Parameterized
      sourcedRunFact = taking (stdinInputAs "run.engine" :> noInputs) $ \_ -> hardenProgram
  pureProbe failures "input sources retain ordered defaults and custom names"
    [ ("default source descriptors", inputSpecs defaults == [InputSpec "args" CommandTailInput, InputSpec "input" StandardInput, InputSpec "tone" PromptInput]),
      ("custom source descriptors", inputSpecs custom == [InputSpec "scope" CommandTailInput, InputSpec "document" StandardInput])
    ]
  inputSourceRefusal failures "duplicate input names are refused" duplicate "input 'same' was declared twice"
  inputSourceRefusal failures "multiple command-tail inputs are refused" twoArgs "more than one command-tail input was declared: args, scope"
  inputSourceRefusal failures "multiple standard-input inputs are refused" twoStdin "more than one standard-input input was declared: input, document"
  inputSourceRefusal failures "run facts cannot be sourced from stdin" sourcedRunFact "is under the `run.` prefix"

inputSourceRefusal :: IORef Int -> String -> Parameterized -> Text -> IO ()
inputSourceRefusal failures name parameterized needle = do
  out <- try (evaluate (length (inputSpecs parameterized)))
  case out :: Either ErrorCall Int of
    Left e | needle `T.isInfixOf` T.pack (show e) -> TIO.putStrLn ("ok   " <> T.pack name)
    Left e -> do
      TIO.putStrLn ("FAIL " <> T.pack name <> ": said " <> T.pack (show e))
      modifyIORef' failures (+ 1)
    Right _ -> do
      TIO.putStrLn ("FAIL " <> T.pack name <> ": declaration was accepted")
      modifyIORef' failures (+ 1)
-- | A question at a chosen addressee, pinned to a chosen model or to none.
--
-- The code is 'CodeText' and could be any of the four: 'backendFor' reads
-- @scopeModelAxis@ and nothing else, and the type index on 'Q' is phantom.
asked :: Maybe Text -> Addressee -> Q 'CodeText
asked pin addr = Q addr (scopeUnit {scopeModelAxis = pin}) "does not matter" 0

-- | A route table over names rather than transports, which is all
-- 'backendFor' needs: it is parametric in the backend, so a 'Text' stands in
-- for a connection and the probe stays pure.
namedRoutes :: Routes Text
namedRoutes = namedTable "default" [("gemini", "gemini-backend"), ("opus", "opus-backend")]

-- | 'routes' at the naming type, so a table written inline in a row is one
-- expression rather than one expression and an annotation.
namedTable :: Text -> [(Text, Text)] -> Routes Text
namedTable = routes

-- | __The owner's two-pane split__ — @--session CODEX --route
-- partner=deck:CLAUDE@ — as the tables @run.routes@ is written from.
--
-- At 'Backend' and not at the naming type, unlike 'namedRoutes': what the
-- @run.routes@ group checks is the /spelling/, and the spelling is
-- @Agentic.Route.backendSpelling@'s, which only a real backend has.
ownersSplit, inverted, sharedPane, pathBackend :: Routes Backend
ownersSplit = routes (BackendDeck "CODEX") [("partner", BackendDeck "CLAUDE")]
-- The same two panes, the other flag routed: it looks like the split, and it
-- leaves everything the program did not pin itself in the pane that is about to
-- judge it.
inverted = routes (BackendDeck "CLAUDE") [("worker", BackendDeck "CODEX")]
-- Two pins on one pane, which is what a table that deduplicated would hide.
sharedPane = routes (BackendDeck "PANE") [("partner", BackendDeck "PANE"), ("deep", BackendAcp "codex")]
-- A backend containing the very character the fact's lines are split on.
pathBackend = routes (BackendAcp "stub") [("deep", BackendAcp "/opt/a=b/adapter")]

-- | The five shapes of question a table must place: a pin it names, a pin it
-- does not, an unpinned model ask, and the two addressees that are not models.
--
-- The last three are one case and not three — 'backendFor' reads
-- @scopeModelAxis@ and nothing else, so a tool and a person cannot be told
-- apart by it — and they are listed anyway because what is quantified over here
-- is /every question a run puts/, which is the claim worth making.
routeSamples :: [Q 'CodeText]
routeSamples =
  [ asked (Just "gemini") (AddrModel "lateral"),
    asked (Just "fable") (AddrModel "author"),
    asked Nothing (AddrModel "reviewer-correct"),
    asked Nothing (AddrTool "cat"),
    asked Nothing (AddrPerson "owner")
  ]

-- | The connect step, at the type the probe can compare: 'Agentic.Cli' maps a
-- 'Agentic.Route.Backend' table to a 'WorldIO' one and neither type has an 'Eq',
-- so the property is stated over 'Text' — which is exactly the generality
-- 'Routes' is parametric for.
connected :: Text -> Text
connected = ("live:" <>)

-- | A world that answers precisely as 'plainWorld' does and says it was the one
-- consulted.
--
-- Two backends that answer /alike/ are what routing's invisibility to the fold
-- has to be observed at, and the note is what keeps that observation sharp: one
-- shared world would make a dispatcher that ignored the table indistinguishable
-- from one that read it, and worlds that answered differently would make the
-- traces differ for a reason that is not routing. This is both at once —
-- identical answers, and a record of who gave them.
tellingWorld :: IORef [Text] -> Text -> WorldIO
tellingWorld seen name = concurrentWorld $ \c q -> do
  modifyIORef' seen (name :)
  worldAskIO (pureWorldIO plainWorld) c q

-- | A world that answers every question from the question itself.
--
-- Used twice: as the /same/ world behind every entry of a route table, which is
-- what makes routing's invisibility to the fold observable; and as the backend
-- that answers where another refuses, which is what makes a cross-backend
-- fail-over observable without a process.
plainWorld :: World
plainWorld = World answerAt
  where
    answerAt :: SCode c -> Q c -> El c
    answerAt SFlag _ = True
    answerAt SAck _ = ()
    answerAt SText q = qPrompt q
    answerAt SVerdict _ = verdictApprove
    answerAt code@(SStructured _) _ = defaultEl code

-- | A backend that will not answer anything, raising a __gap__ — "nothing
-- usable came back" — rather than an ordinary error, so that the question may
-- be put to the next rung of its ladder.
deadBackend :: WorldIO
deadBackend = concurrentWorld $ \_ _ ->
  raiseGap
    GapTransportRefusal
    "the backend deep was routed to is not answering"
    (userError "no readable flag from model r after 1 attempts")

-- | Two program-authored commands around one __pinned__ model ask.
--
-- The smallest program in which both halves of the @toolExec@ claim are
-- observable at once. Put to a table whose default raises and whose one route
-- answers, it settles only if both hold: a command answered anywhere but in the
-- executing layer would have been routed, found the default, and raised; and
-- the ask between them, sent to the default rather than to the route its pin
-- names, would have raised too. A program of commands alone can say the first
-- but not the second, because a dispatcher nothing reaches cannot be caught
-- being wrong.
routedGateProgram :: Program
routedGateProgram =
  program [] $
    bindAs @"g" @'CodeFlag (one (askToolRunning "green" "true" ["gate"] [lit "check"])) $
      \g ->
        ifFlag
          g
          ( bindAs @"ok" @'CodeFlag
              (one (askModelFallingBack "r" "deep" [] [lit "ready?"]))
              (\ok -> ifFlag ok (act (askToolRunning "log" "true" ["yes"] [lit "note"]) stop) stop)
          )
          stop

execProbe :: IORef Int -> String -> Program -> (ExecTrace -> Bool) -> IO ()
execProbe failures name prog want = do
  let cfg = defaultShellConfig {shellCwd = "."}
  out <- try (runPlanIO (executingWorld cfg noWorld) (progPlan prog))
  case out :: Either SomeException ((), ExecTrace) of
    Left e -> do
      TIO.putStrLn ("FAIL " <> T.pack name <> ": threw " <> T.pack (show e))
      modifyIORef' failures (+ 1)
    Right (_, tr)
      | want tr -> TIO.putStrLn ("ok   " <> T.pack name)
      | otherwise -> do
          TIO.putStrLn
            ( "FAIL "
                <> T.pack name
                <> ": bills ("
                <> T.pack (show (billExecFresh tr))
                <> ","
                <> T.pack (show (billMemo tr))
                <> ")"
            )
          modifyIORef' failures (+ 1)

-- The executor's concurrency contract, synchronized rather than timed: a
-- blocked first ask can complete only if its independent sibling starts; an
-- independent sentinel proves the scheduler has passed two dependent workers
-- while their shared source remains blocked; and a later failure must cancel
-- an earlier worker that is blocked forever.
textQuestion :: Text -> Request 'CodeText
textQuestion prompt = consultRequest (Q (AddrModel prompt) scopeUnit prompt 0)

ackQuestion :: Text -> Request 'CodeAck
ackQuestion prompt = effectRequest (Q (AddrModel prompt) scopeUnit prompt 0)

statefulQuestion :: Text -> Request 'CodeText
statefulQuestion prompt = consultRequest (Q (AddrModel "stateful") scopeUnit prompt 0)

servedQuestion :: Text -> Text -> Request 'CodeText
servedQuestion model prompt =
  consultRequest (Q (AddrModel prompt) (QScope (Just model) Nothing) prompt 0)

textShape :: Text -> RequestShape 'CodeText
textShape party = consultShape (Shape (AddrModel party) scopeUnit 0)

ackShape :: Text -> RequestShape 'CodeAck
ackShape party = effectShape (Shape (AddrModel party) scopeUnit 0)

promptOf :: Request c -> Text
promptOf = qPrompt . reqQuestion

scopeOf :: Request c -> QScope
scopeOf = qScope . reqQuestion

addresseeOf :: Request c -> Addressee
addresseeOf = qAddressee . reqQuestion

tracePrompts :: ExecTrace -> [Text]
tracePrompts = map (\(ExecEvent _ r _ _) -> promptOf r)

newSignal :: IO (TMVar ())
newSignal = newEmptyTMVarIO

overlapProbe :: IORef Int -> IO ()
overlapProbe failures = do
  firstStarted <- newSignal
  secondStarted <- newSignal
  let plan = pairP (askC1 SText (servedQuestion "shared" "first")) (askC1 SText (servedQuestion "shared" "second"))
      world = concurrentWorld $ \c q -> case c of
        SText -> case promptOf q of
          "first" -> do
            atomically (putTMVar firstStarted ())
            atomically (takeTMVar secondStarted)
            pure "first-answer"
          "second" -> do
            atomically (putTMVar secondStarted ())
            atomically (takeTMVar firstStarted)
            pure "second-answer"
          _ -> pure "unexpected"
        _ -> pure (defaultEl c)
  out <- timeout 2000000 (try @SomeException (runPlanIO world plan))
  pureProbe failures "independent prompts overlap at one model and retain trace order" $ case out of
    Just (Right (answer, tr)) ->
      [ ("both asks rendezvoused before either completed", answer == ("first-answer", "second-answer")),
        ("trace order is plan order, not completion order", tracePrompts tr == ["first", "second"])
      ]
    Just (Left e) -> [("the run threw: " <> show e, False)]
    Nothing -> [("the independent pair deadlocked", False)]

effectOrderProbe :: IORef Int -> IO ()
effectOrderProbe failures = do
  sourceStarted <- newSignal
  releaseSource <- newSignal
  sentinelStarted <- newSignal
  firstEffectStarted <- newSignal
  releaseFirstEffect <- newSignal
  effects <- newTVarIO ([] :: [Text])
  done <- newEmptyTMVarIO
  let plan :: Plan '[] (((), ()), Text)
      plan =
        graft
          (askC1 SText (textQuestion "effect-source"))
          ( Cont $ \_ source ->
              pairP
                ( pairP
                    (ask1 SAck (ackShape "writer") (("write-one:" <>) <$> source))
                    (askC1 SAck (ackQuestion "write-two"))
                )
                (askC1 SText (textQuestion "effect-sentinel"))
          )
      world = concurrentWorld $ \c q -> case c of
        SText -> case promptOf q of
          "effect-source" -> do
            atomically (putTMVar sourceStarted ())
            atomically (takeTMVar releaseSource)
            pure "seed"
          "effect-sentinel" -> atomically (putTMVar sentinelStarted ()) >> pure "sentinel-answer"
          _ -> pure "unexpected"
        SAck -> do
          atomically (modifyTVar' effects (<> [promptOf q]))
          if promptOf q == "write-one:seed"
            then do
              atomically (putTMVar firstEffectStarted ())
              atomically (takeTMVar releaseFirstEffect)
            else pure ()
        _ -> pure (defaultEl c)
  tid <- forkFinally (runPlanIO world plan) (atomically . putTMVar done)
  ready <-
    timeout 2000000 . atomically $ do
      takeTMVar sourceStarted
      takeTMVar sentinelStarted
  beforeSource <- atomically (readTVar effects)
  case ready of
    Nothing -> killThread tid
    Just () -> atomically (putTMVar releaseSource ())
  firstReady <- case ready of
    Nothing -> pure Nothing
    Just () -> timeout 2000000 (atomically (takeTMVar firstEffectStarted))
  duringFirst <- atomically (readTVar effects)
  case firstReady of
    Nothing -> killThread tid
    Just () -> atomically (putTMVar releaseFirstEffect ())
  finished <- case firstReady of
    Nothing -> pure Nothing
    Just () -> timeout 2000000 (atomically (takeTMVar done))
  after <- atomically (readTVar effects)
  pureProbe failures "write effects keep plan order across dependency waits" $
    [ ("the later ready write did not overtake the blocked first write", null beforeSource),
      ("the second write did not overlap the first", duringFirst == ["write-one:seed"]),
      ("actual effect order is plan order", after == ["write-one:seed", "write-two"])
    ]
      ++ case finished of
        Just (Right (_, tr)) -> [("the trace has the same order", tracePrompts tr == ["effect-source", "write-one:seed", "write-two", "effect-sentinel"])]
        Just (Left e) -> [("the run threw: " <> show e, False)]
        Nothing -> [("the ordered effects did not finish", False)]

statefulTurnOrderProbe :: IORef Int -> IO ()
statefulTurnOrderProbe failures = do
  lane <- newTurnLaneIO
  sourceStarted <- newSignal
  releaseSource <- newSignal
  sentinelStarted <- newSignal
  firstTurnStarted <- newSignal
  releaseFirstTurn <- newSignal
  turns <- newTVarIO ([] :: [Text])
  done <- newEmptyTMVarIO
  let plan :: Plan '[] ((Text, Text), Text)
      plan =
        graft
          (askC1 SText (textQuestion "turn-source"))
          ( Cont $ \_ source ->
              pairP
                ( pairP
                    (ask1 SText (textShape "stateful") (("turn-one:" <>) <$> source))
                    (askC1 SText (statefulQuestion "turn-two"))
                )
                (askC1 SText (textQuestion "turn-sentinel"))
          )
      world =
        WorldIO
          { worldAskIO = \c q -> case c of
              SText -> case promptOf q of
                "turn-source" -> do
                  atomically (putTMVar sourceStarted ())
                  atomically (takeTMVar releaseSource)
                  pure "seed"
                "turn-sentinel" -> atomically (putTMVar sentinelStarted ()) >> pure "sentinel-answer"
                prompt
                  | "turn-" `T.isPrefixOf` prompt -> do
                      atomically (modifyTVar' turns (<> [prompt]))
                      if prompt == "turn-one:seed"
                        then do
                          atomically (putTMVar firstTurnStarted ())
                          atomically (takeTMVar releaseFirstTurn)
                        else pure ()
                      pure prompt
                  | otherwise -> pure "unexpected"
              _ -> pure (defaultEl c),
            worldAskAttemptIO = \context c q ->
              withPhysicalAttempt context "stateful" (\_ -> worldAskIO world c q),
            worldTurnLane = \_ shape -> case shAddressee (rsQuestion shape) of
              AddrModel party | party == "stateful" -> Just lane
              _ -> Nothing
          }
  tid <- forkFinally (runPlanIO world plan) (atomically . putTMVar done)
  ready <-
    timeout 2000000 . atomically $ do
      takeTMVar sourceStarted
      takeTMVar sentinelStarted
  beforeSource <- atomically (readTVar turns)
  case ready of
    Nothing -> killThread tid
    Just () -> atomically (putTMVar releaseSource ())
  firstReady <- case ready of
    Nothing -> pure Nothing
    Just () -> timeout 2000000 (atomically (takeTMVar firstTurnStarted))
  duringFirst <- atomically (readTVar turns)
  case firstReady of
    Nothing -> killThread tid
    Just () -> atomically (putTMVar releaseFirstTurn ())
  finished <- case firstReady of
    Nothing -> pure Nothing
    Just () -> timeout 2000000 (atomically (takeTMVar done))
  after <- atomically (readTVar turns)
  pureProbe failures "stateful turns keep plan order across dependency waits" $
    [ ("the later ready turn did not overtake the blocked first turn", null beforeSource),
      ("the second turn did not overlap the first", duringFirst == ["turn-one:seed"]),
      ("actual session order is plan order", after == ["turn-one:seed", "turn-two"])
    ]
      ++ case finished of
        Just (Right (_, tr)) -> [("the trace has the same order", tracePrompts tr == ["turn-source", "turn-one:seed", "turn-two", "turn-sentinel"])]
        Just (Left e) -> [("the run threw: " <> show e, False)]
        Nothing -> [("the ordered turns did not finish", False)]

dependencyProbe :: IORef Int -> IO ()
dependencyProbe failures = do
  sourceStarted <- newSignal
  releaseSource <- newSignal
  sentinelStarted <- newSignal
  dependents <- newTVarIO ([] :: [Text])
  done <- newEmptyTMVarIO
  let plan :: Plan '[] ((Text, Text), Text)
      plan =
        graft
          (askC1 SText (textQuestion "source"))
          ( Cont $ \_ source ->
              pairP
                ( pairP
                    (ask1 SText (textShape "left") (("left:" <>) <$> source))
                    (ask1 SText (textShape "right") (("right:" <>) <$> source))
                )
                (askC1 SText (textQuestion "sentinel"))
          )
      world = concurrentWorld $ \c q -> case c of
        SText -> case promptOf q of
          "source" -> do
            atomically (putTMVar sourceStarted ())
            atomically (takeTMVar releaseSource)
            pure "seed"
          "sentinel" -> atomically (putTMVar sentinelStarted ()) >> pure "sentinel-answer"
          prompt
            | "left:" `T.isPrefixOf` prompt || "right:" `T.isPrefixOf` prompt -> do
                atomically (modifyTVar' dependents (prompt :))
                atomically $ do
                  seen <- readTVar dependents
                  check (all (`elem` seen) ["left:seed", "right:seed"])
                pure prompt
            | otherwise -> pure "unexpected"
        _ -> pure (defaultEl c)
  tid <- forkFinally (runPlanIO world plan) (atomically . putTMVar done)
  ready <-
    timeout 2000000 . atomically $ do
      takeTMVar sourceStarted
      takeTMVar sentinelStarted
  (beforeRelease, finished) <- case ready of
    Nothing -> do
      killThread tid
      pure (["scheduler did not reach the sentinel"], Nothing)
    Just () -> do
      blocked <- atomically (readTVar dependents)
      atomically (putTMVar releaseSource ())
      result <- timeout 2000000 (atomically (takeTMVar done))
      case result of
        Nothing -> killThread tid
        Just _ -> pure ()
      pure (blocked, result)
  pureProbe failures "prompt dependencies block only their consumers" $
    [ ("the independent sentinel ran while the source was blocked", ready == Just ()),
      ("both source consumers stayed blocked", null beforeRelease)
    ]
      ++ case finished of
        Just (Right (answer, tr)) ->
          [ ("the consumers overlapped after the source arrived", answer == (("left:seed", "right:seed"), "sentinel-answer")),
            ("the trace retains plan order", tracePrompts tr == ["source", "left:seed", "right:seed", "sentinel"])
          ]
        Just (Left e) -> [("the run threw: " <> show e, False)]
        Nothing -> [("the run did not finish after unblocking the source", False)]

memoConcurrencyProbe :: IORef Int -> IO ()
memoConcurrencyProbe failures = do
  entered <- newSignal
  release <- newSignal
  sentinelStarted <- newSignal
  calls <- newTVarIO (0 :: Int)
  done <- newEmptyTMVarIO
  let repeated = askC1 SText (textQuestion "same")
      plan = pairP (pairP repeated repeated) (askC1 SText (textQuestion "memo-sentinel"))
      world = concurrentWorld $ \c q -> case c of
        SText -> case promptOf q of
          "same" -> do
            atomically $ do
              modifyTVar' calls (+ 1)
              void (tryPutTMVar entered ())
            atomically (takeTMVar release)
            pure "one-answer"
          "memo-sentinel" -> atomically (putTMVar sentinelStarted ()) >> pure "sentinel-answer"
          _ -> pure "unexpected"
        _ -> pure (defaultEl c)
  tid <- forkFinally (runPlanIO world plan) (atomically . putTMVar done)
  ready <-
    timeout 2000000 . atomically $ do
      takeTMVar entered
      takeTMVar sentinelStarted
  beforeRelease <- atomically (readTVar calls)
  case ready of
    Nothing -> killThread tid
    Just () -> atomically (putTMVar release ())
  finished <- case ready of
    Nothing -> pure Nothing
    Just () -> do
      result <- timeout 2000000 (atomically (takeTMVar done))
      case result of
        Nothing -> killThread tid
        Just _ -> pure ()
      pure result
  afterRelease <- atomically (readTVar calls)
  pureProbe failures "concurrent memo reservations ask an equal question once" $
    [ ("one consultation owned the in-flight key", beforeRelease == 1),
      ("no waiter re-asked after publication", afterRelease == 1)
    ]
      ++ case finished of
        Just (Right (answer, tr)) ->
          [ ("both nodes received the one answer", answer == (("one-answer", "one-answer"), "sentinel-answer")),
            ("both nodes remain in the trace", tracePrompts tr == ["same", "same", "memo-sentinel"]),
            ("the bills distinguish nodes from questions",
              (billExecFresh tr, billMemo tr) == (3, 2))
          ]
        Just (Left e) -> [("the run threw: " <> show e, False)]
        Nothing -> [("the memoized run did not finish", False)]

intentMemoProbe :: IORef Int -> IO ()
intentMemoProbe failures = do
  calls <- newIORef (0 :: Int)
  let q = Q (AddrModel "same-ack") scopeUnit "same operation" 0
      effect = effectRequest q
      consult = consultRequest q
      observe = observeRequest q
      plan = pairP (pairP (askC1 SAck effect) (askC1 SAck effect))
        (pairP (askC1 SAck consult)
          (pairP (askC1 SAck observe) (askC1 SAck observe)))
      world = concurrentWorld $ \c _ -> case c of
        SAck -> atomicModifyIORef' calls (\n -> (n + 1, ()))
        _ -> pure (defaultEl c)
      semantic = trace (World (\c _ -> defaultEl c)) plan
  out <- try @SomeException (runPlanIO world plan)
  invocations <- readIORef calls
  pureProbe failures "intent separates reusable answers from effect occurrences" $
    case out of
      Right (_, tr) ->
        [ ("effects run twice; consult and observations share bare Q", invocations == 3),
          ("operational bill retains effects and one reusable answer",
            (billExecFresh tr, billMemo tr) == (5, 3)),
          ("each occurrence retains its authored annotation",
            [intentName (reqIntent r) | ExecEvent _ r _ _ <- tr] ==
              ["effect", "effect", "consult", "observe", "observe"]),
          ("runtime annotated trace erases to semantic trace",
            map (eventJson . forgetExecEvent) tr == map eventJson semantic),
          ("v2 erases intent before deduplication",
            billMemoLegacy (map forgetExecEvent tr) == 1)
        ]
      Left e -> [("the run threw: " <> show e, False)]

failoverMemoIdentityProbe :: IORef Int -> IO ()
failoverMemoIdentityProbe failures = do
  dispatchedCalls <- newIORef ([] :: [Maybe Text])
  let request model =
        consultRequest (Q (AddrModel "r") (QScope (Just model) Nothing) "same" 0)
      deep = request "deep"
      broad = request "broad"
      plan = pairP (askC1 SFlag deep)
        (pairP (askC1 SFlag broad) (askC1 SFlag deep))
      chains = chainsOf (const (pure ())) (Map.fromList [("deep", ["broad"])])
      world = concurrentWorld $ \c r -> case c of
        SFlag -> do
          let model = scopeModelAxis (scopeOf r)
          atomicModifyIORef' dispatchedCalls (\models -> (model : models, ()))
          case model of
            Just "deep" -> raiseGap GapTransportRefusal "deep refused"
              (userError "deep refused")
            _ -> pure True
        _ -> pure (defaultEl c)
  out <- try @SomeException (runPlanWith chains world plan)
  calls <- reverse <$> readIORef dispatchedCalls
  pureProbe failures "failover memo identity is authored bare Q" $ case out of
    Right (answer, tr) ->
      [ ("all three Plan occurrences receive answers", answer == (True, (True, True))),
        ("concurrent equal deep asks share one whole fallback walk",
          sort calls == sort [Just "deep", Just "broad", Just "broad"]),
        ("authored questions survive",
          authoredModels tr == [Just "deep", Just "broad", Just "deep"]),
        ("one deep occurrence owns the fallback and the other reuses it",
          sort (answerers tr) == sort [Just "broad", Just "broad", Nothing]),
        ("fresh/memo bills are 3/2", (billExecFresh tr, billMemo tr) == (3, 2))
      ]
    Left e -> [("the run threw: " <> show e, False)]

sourceIntentProbe :: IORef Int -> IO ()
sourceIntentProbe failures = do
  out <- try @SomeException $ runPlanIO world (progPlan (runningProgram "true" []))
  pureProbe failures "Builder lowers command value and act positions to intent" $
    case out of
      Right (_, [ExecEvent SFlag observed _ _, ExecEvent SAck effected _ _]) ->
        [ ("value-position running is observe", intentName (reqIntent observed) == "observe"),
          ("statement-position act is effect", intentName (reqIntent effected) == "effect")
        ]
      Right (_, tr) -> [("unexpected source fixture trace length: " <> show (length tr), False)]
      Left e -> [("the source fixture threw: " <> show e, False)]
  where
    world = concurrentWorld $ \c _ -> case c of
      SFlag -> pure True
      SAck -> pure ()
      _ -> pure (defaultEl c)

failureConcurrencyProbe :: IORef Int -> IO ()
failureConcurrencyProbe failures = do
  blockedStarted <- newSignal
  cleaned <- newSignal
  let plan = pairP (askC1 SText (textQuestion "blocked")) (askC1 SText (textQuestion "boom"))
      world = concurrentWorld $ \c q -> case c of
        SText -> case promptOf q of
          "blocked" -> do
            atomically (putTMVar blockedStarted ())
            atomically retry `finally` atomically (void (tryPutTMVar cleaned ()))
          "boom" -> do
            atomically (takeTMVar blockedStarted)
            ioError (userError "concurrent boom")
          _ -> pure "unexpected"
        _ -> pure (defaultEl c)
  out <- timeout 2000000 (try @SomeException (runPlanIO world plan))
  cleanup <- timeout 2000000 (atomically (takeTMVar cleaned))
  pureProbe failures "a prompt failure cancels independent workers"
    [ ( "the failure propagated instead of waiting on the earlier trace node",
        case out of
          Just (Left e) -> "concurrent boom" `T.isInfixOf` T.pack (show e)
          _ -> False
      ),
      ("the blocked sibling ran its cleanup", cleanup == Just ())
    ]

storeProbe :: IORef Int -> IO ()
storeProbe failures = do
  temp <- getTemporaryDirectory
  stamp <- getMonotonicTimeNSec
  let directory = temp </> ("agentic-store-probe-" <> show stamp)
      run = RunId "run-store-probe"
      sensitiveProgram = object ["prompt" .= ("sensitive body text" :: Text)]
      manifest = RunManifest run "fixture" "0.1.0.0" sensitiveProgram "scripted" (object ["kind" .= ("scripted" :: Text)]) Nothing RootRun Nothing
      envelope n event = Envelope protocolVersion run (SeqNo n) "2026-08-28T00:00:00Z" event
      first = envelope 0 (RunStarted "fixture" "scripted")
      second = envelope 1 (RunCompleted 1 1)
      gap = envelope 3 (RunFailed FailureRuntime "gap")
      question = object ["prompt" .= ("persist me" :: Text)]
      answer = object ["value" .= ("answer" :: Text)]
      answerRecord = AnswerRecord question answer (OccurrenceId 0) True False
      effectRecord = EffectRecord question (Just answer) (OccurrenceId 1) EffectCompleted
      checkpoint = Checkpoint (object ["program" .= ("fixture" :: Text)]) (Just (OccurrenceId 2)) 1 1
      olderCheckpoint = Checkpoint (object ["program" .= ("fixture" :: Text)]) (Just (OccurrenceId 1)) 2 1
      mergedCheckpoint = Checkpoint (object ["program" .= ("fixture" :: Text)]) (Just (OccurrenceId 2)) 2 1
  checks <-
    ( do
        appended <- withRunStore directory manifest $ \store -> do
          firstDecision <- appendStoredEvent store first
          secondDecision <- appendStoredEvent store second
          duplicateResult <- try @StoreError (appendStoredEvent store second)
          gapResult <- try @StoreError (appendStoredEvent store gap)
          writeSnapshot store (object ["state" .= ("done" :: Text)])
          storeReusableAnswer store answerRecord
          lookedUp <- lookupStoredAnswer store question
          appendEffectRecord store effectRecord
          writeCheckpoint store checkpoint
          writeCheckpoint store olderCheckpoint
          pure (firstDecision, secondDecision, duplicateResult, gapResult, lookedUp)
        restoredManifest <- readManifest directory
        (events, health) <- readEventLog directory
        answers <- readAnswerRecords directory
        effects <- readEffectRecords directory
        restoredCheckpoint <- readCheckpoint directory
        directoryMode <- fileMode <$> getFileStatus directory
        manifestMode <- fileMode <$> getFileStatus (directory </> "manifest.json")
        programMode <- fileMode <$> getFileStatus (directory </> "program.json")
        manifestBytes <- BS.readFile (directory </> "manifest.json")
        programBytes <- BS.readFile (directory </> "program.json")
        answerMode <- fileMode <$> getFileStatus (directory </> "answers.json")
        effectMode <- fileMode <$> getFileStatus (directory </> "effects.ndjson")
        checkpointMode <- fileMode <$> getFileStatus (directory </> "checkpoint.json")
        snapshotExists <- doesFileExist (directory </> "snapshot.json")
        BS.appendFile (directory </> "events.ndjson") "{torn"
        tornEvents <- try @StoreError (readEventLog directory)
        duplicateCreate <- try @StoreError (createRunStore directory manifest)
        BS.appendFile (directory </> "effects.ndjson") "{torn"
        tornEffect <- try @StoreError (readEffectRecords directory)
        BL.writeFile (directory </> "answers.json") (encode (object ["semanticStoreVersion" .= (99 :: Int), "answers" .= ([] :: [Value])]))
        incompatibleAnswers <- try @StoreError (readAnswerRecords directory)
        pure
          [ ("manifest round-trips through its private program reference", restoredManifest == manifest),
            ("manifest omits sensitive program text", not ("sensitive body text" `BS.isInfixOf` manifestBytes) && "program.json" `BS.isInfixOf` manifestBytes && "sensitive body text" `BS.isInfixOf` programBytes),
            ("ordered events append and duplicate both fail closed", case appended of
              (SequenceNext, SequenceNext, Left (StoreCorrupt _ _), Left (StoreCorrupt _ _), Just persisted) -> events == [first, second] && answerValue persisted == answer
              _ -> False),
            ("typed answer, effect journal, and monotone checkpoint round-trip", answers == [answerRecord] && effects == [effectRecord] && restoredCheckpoint == Just mergedCheckpoint),
            ("healthy log is reported", health == StoreHealthy),
            ("directory and files are private", directoryMode .&. 0o777 == 0o700 && all (\mode -> mode .&. 0o777 == 0o600) [manifestMode, programMode, answerMode, effectMode, checkpointMode]),
            ("snapshot is atomically visible", snapshotExists),
            ("a torn event journal fails closed", case tornEvents of Left (StoreCorrupt _ _) -> True; _ -> False),
            ("an existing run is immutable", case duplicateCreate of Left (StoreAlreadyExists _) -> True; _ -> False),
            ("a torn effect journal fails closed", case tornEffect of Left (StoreCorrupt _ _) -> True; _ -> False),
            ("an unknown semantic migration fails explicitly", case incompatibleAnswers of Left (StoreIncompatible _ _) -> True; _ -> False)
          ]
    )
      `finally` removePathForcibly directory
  pureProbe failures "runtime store is private, ordered, atomic, and recoverable" checks

machineFrameProbe :: IORef Int -> IO ()
machineFrameProbe failures = do
  temp <- getTemporaryDirectory
  stamp <- getMonotonicTimeNSec
  let path = temp </> ("agentic-machine-frame-" <> show stamp <> ".ndjson")
      run = RunId "run-machine-frame"
      attempt = AttemptId (OccurrenceId 0) 0
      chunk = T.replicate 150000 "\NUL" <> T.replicate 150000 "x"
  checks <-
    ( do
        withBinaryFile path WriteMode $ \handle -> do
          sink <- handleEventSink handle run
          sink (RunStarted "fixture" "scripted")
          sink (AttemptOutput attempt chunk)
          sink (RunCompleted 1 1)
        bytes <- BS.readFile path
        let lines' = filter (not . BS.null) (BS.split 10 bytes)
            decoded = traverse decodeEnvelope lines'
            chunks = case decoded of
              Right envelopes -> [text | Envelope _ _ _ _ (AttemptOutput _ text) <- envelopes]
              Left _ -> []
        oversized <- withBinaryFile path WriteMode $ \handle -> do
          sink <- handleEventSink handle run
          try @SomeException (sink (RunCancelled (T.replicate 200000 "x")))
        pure
          [ ("large attempt output is split into valid bounded envelopes", length lines' > 3 && all ((<= maxFrameBytes) . BS.length) lines' && T.concat chunks == chunk),
            ("oversized non-output events are refused before writing", either (const True) (const False) oversized)
          ]
    )
      `finally` removePathForcibly path
  pureProbe failures "machine event emission enforces the frame bound" checks

controlProbe :: IORef Int -> IO ()
controlProbe failures = do
  let occurrence = OccurrenceId 4
      attempt = AttemptId occurrence 2
      cancel = Control (ControlId "cancel") Nothing Nothing CancelRun
      steer = Control (ControlId "steer") (Just occurrence) (Just attempt) (Steer NextBoundary "focus")
      retryControl = Control (ControlId "retry") (Just occurrence) Nothing RetryOccurrence
      failoverControl = Control (ControlId "failover") (Just occurrence) Nothing (ChooseRecovery RecoveryFailOver)
      abandonControl = Control (ControlId "abandon") (Just occurrence) Nothing (ChooseRecovery RecoveryAbandon)
      redirect = Control (ControlId "redirect") (Just occurrence) Nothing (RedirectOccurrence "deck:other")
      controls = [cancel, steer, retryControl, failoverControl, abandonControl, redirect]
      base = emptyControlSnapshot {activeAttempts = [attempt]}
      none = ControlCapabilities False False False
      allCapabilities = ControlCapabilities True True True
      (cancelling, cancelAck, cancelAction) = decideControl none base cancel
      (_, secondCancelAck, secondCancelAction) = decideControl none cancelling (Control (ControlId "cancel-2") Nothing Nothing CancelRun)
      (_, staleAck, _) = decideControl allCapabilities base (Control (ControlId "stale") (Just occurrence) (Just (AttemptId occurrence 9)) (Steer InterruptNow "x"))
      (_, unsupportedAck, _) = decideControl none base steer
      redirectable = emptyControlSnapshot {reservedRedirects = Map.singleton occurrence ["deck:other"]}
      (_, redirectAck, redirectAction) = decideControl allCapabilities redirectable redirect
      (_, activeRedirectAck, _) = decideControl allCapabilities base {reservedRedirects = Map.singleton occurrence ["deck:other"]} redirect
      recoverable = emptyControlSnapshot {recoverableOccurrences = [occurrence], recoveryOptions = Map.singleton occurrence [RecoveryRetry]}
      (_, retryAck, retryAction) = decideControl allCapabilities recoverable retryControl
      (_, unofferedAck, unofferedAction) = decideControl allCapabilities recoverable failoverControl
  deliveredRef <- newIORef ([] :: [(SteeringTiming, Text)])
  runtime <- newControlRuntime
  registerControlAttempt runtime attempt (Just (\timing text -> atomicModifyIORef' deliveredRef (\xs -> ((timing, text) : xs, Right ()))))
  (acceptedAck, acceptedAction) <- decideRuntimeControl runtime steer
  deliveredAck <- case acceptedAction of
    Just action -> deliverRuntimeAction runtime steer action
    Nothing -> pure acceptedAck
  (duplicateAck, duplicateAction) <- decideRuntimeControl runtime steer
  delivered <- readIORef deliveredRef
  retryResult <- newEmptyTMVarIO
  _ <- forkIO (waitForRuntimeRecovery runtime occurrence [RecoveryRetry] (pure ()) >>= atomically . putTMVar retryResult)
  let awaitRegistered = do
        current <- controlRuntimeSnapshot runtime
        if occurrence `elem` recoverableOccurrences current
          then pure ()
          else threadDelay 1000 >> awaitRegistered
  awaitRegistered
  (runtimeRetryAck, runtimeRetryAction) <- decideRuntimeControl runtime retryControl
  runtimeRetryDelivered <- case runtimeRetryAction of
    Just action -> deliverRuntimeAction runtime retryControl action
    Nothing -> pure runtimeRetryAck
  receivedRetry <- atomically (takeTMVar retryResult)
  unregisterControlAttempt runtime attempt
  registerRuntimeRedirects runtime occurrence ["deck:default", "deck:other"]
  redirectResult <- newEmptyTMVarIO
  _ <- forkIO (awaitRuntimeRedirect runtime occurrence >>= atomically . putTMVar redirectResult)
  (runtimeRedirectAck, runtimeRedirectAction) <- decideRuntimeControl runtime redirect
  runtimeRedirectDelivered <- case runtimeRedirectAction of
    Just action -> deliverRuntimeAction runtime redirect action
    Nothing -> pure runtimeRedirectAck
  receivedRedirect <- atomically (takeTMVar redirectResult)
  (staleRuntimeAck, _) <- decideRuntimeControl runtime (Control (ControlId "after") (Just occurrence) (Just attempt) (Steer InterruptNow "late"))
  snapshot <- controlRuntimeSnapshot runtime
  pureProbe failures "runtime control codec, stale/capability policy, and live delivery are strict"
    [ ("every control round-trips", all (\c -> decodeControl (encodeControl c) == Right c) controls),
      ("first cancel is accepted and marks cancelling", acknowledgementState cancelAck == Accepted && cancelAction == Just ActCancel && controlCancelling cancelling),
      ("cancel is idempotent", acknowledgementState secondCancelAck == Accepted && secondCancelAction == Nothing),
      ("a stale attempt is rejected", acknowledgementState staleAck == RejectedStale),
      ("unsupported steering is explicit", acknowledgementState unsupportedAck == Unsupported),
      ("a reserved undispatched redirect is accepted", acknowledgementState redirectAck == Accepted && redirectAction == Just (ActRedirect occurrence "deck:other")),
      ("an active attempt cannot be redirected", acknowledgementState activeRedirectAck == RejectedStale),
      ("retry requires a recoverable occurrence", acknowledgementState retryAck == Accepted && retryAction == Just (ActRecover occurrence RecoveryRetry)),
      ("an unoffered recovery choice is rejected", acknowledgementState unofferedAck == RejectedStale && unofferedAction == Nothing),
      ("live steering is accepted, delivered once, and remembered idempotently", acknowledgementState acceptedAck == Accepted && acknowledgementState deliveredAck == Delivered && acknowledgementState duplicateAck == Delivered && duplicateAction == Nothing && delivered == [(NextBoundary, "focus")]),
      ("interactive recovery registers, accepts, and delivers one retry", acknowledgementState runtimeRetryAck == Accepted && acknowledgementState runtimeRetryDelivered == Delivered && receivedRetry == (ControlId "retry", RecoveryRetry)),
      ("scheduler redirect selects one reserved target before dispatch", acknowledgementState runtimeRedirectAck == Accepted && acknowledgementState runtimeRedirectDelivered == Delivered && receivedRedirect == Just "deck:other"),
      ("finished attempts become stale", acknowledgementState staleRuntimeAck == RejectedStale && null (activeAttempts snapshot))
    ]

protocolProbe :: IORef Int -> IO ()
protocolProbe failures = do
  let run = RunId "run-protocol-probe"
      occurrence = OccurrenceId 7
      attempt = AttemptId occurrence 2
      events =
        [ RunStarted "fixture" "scripted",
          OccurrenceStarted occurrence "text" "consult" "model reviewer" "review this",
          AttemptStarted attempt "scripted",
          AttemptOutput attempt "partial",
          AttemptSteered attempt "steer-1" "next-boundary" "focus",
          AttemptCompleted attempt "model reviewer",
          AttemptFailed attempt FailureTransport "refused",
          OccurrenceReused occurrence "answer-1",
          OccurrenceCompleted occurrence "asked:model reviewer" "approved",
          OccurrenceFailed occurrence FailureDecode "unreadable",
          ControlAcknowledged "steer-1" "delivered" "steer delivered",
          OccurrenceRecoveryPending occurrence "decode" "unreadable" [RecoveryOption "retry" Nothing, RecoveryOption "failover" Nothing, RecoveryOption "abandon" Nothing],
          OccurrenceRetried occurrence "retry-1",
          OccurrenceRecoveryChosen occurrence "failover-1" "failover" Nothing,
          OccurrenceDispatchPending occurrence ["deck:default", "deck:other"],
          OccurrenceRedirected occurrence "redirect-1" "deck:other",
          TraceOrdered [occurrence],
          RunCompleted 3 2,
          RunFailed FailureRuntime "boom",
          RunCancelled "operator"
        ]
      envelope n event = Envelope protocolVersion run (SeqNo n) "2026-08-28T00:00:00Z" event
      envelopes = zipWith (envelope . fromIntegral) [0 :: Int ..] events
      first = envelope 0 (RunStarted "fixture" "scripted")
      second = envelope 1 (OccurrenceStarted occurrence "text" "consult" "model reviewer" "review this")
      third = envelope 2 (AttemptStarted attempt "scripted")
      unknownFields =
        object
          [ "protocolVersion" .= protocolVersion,
            "runId" .= ("run-protocol-probe" :: Text),
            "sequence" .= ("0" :: Text),
            "timestamp" .= ("2026-08-28T00:00:00Z" :: Text),
            "future" .= True,
            "event"
              .= object
                [ "type" .= ("run.started" :: Text),
                  "workflow" .= ("fixture" :: Text),
                  "target" .= ("scripted" :: Text),
                  "future" .= True
                ]
          ]
      wrongVersion =
        object
          [ "protocolVersion" .= (protocolVersion + 1),
            "runId" .= ("run-protocol-probe" :: Text),
            "sequence" .= ("0" :: Text),
            "timestamp" .= ("2026-08-28T00:00:00Z" :: Text),
            "event" .= toJSON (RunStarted "fixture" "scripted")
          ]
      missingEvent =
        object
          [ "protocolVersion" .= protocolVersion,
            "runId" .= ("run-protocol-probe" :: Text),
            "sequence" .= ("0" :: Text),
            "timestamp" .= ("2026-08-28T00:00:00Z" :: Text)
          ]
      decodeValue = decodeEnvelope . BL.toStrict . encode
      conflicting = second {envelopeTimestamp = "later"}
      gap = third {envelopeSequence = SeqNo 3}
      regressed = first {envelopeSequence = SeqNo 0}
      exhausted = second {envelopeSequence = SeqNo maxBound}
  pureProbe failures "runtime protocol codec and sequence are strict"
    [ ("every event round-trips", all (\e -> decodeEnvelope (encodeEnvelope e) == Right e) envelopes),
      ("unknown additive fields are ignored", decodeValue unknownFields == Right first),
      ("unsupported major version is refused", either (T.isInfixOf "unsupported runtime protocol version") (const False) (decodeValue wrongVersion)),
      ("missing required event is refused", either (const True) (const False) (decodeValue missingEvent)),
      ("a torn line is refused", either (const True) (const False) (decodeEnvelope (BS.init (encodeEnvelope first)))),
      ("the first sequence is zero", checkSequence Nothing first == Right SequenceNext),
      ("the next sequence advances by one", checkSequence (Just first) second == Right SequenceNext),
      ("an identical duplicate is refused", either (T.isInfixOf "duplicate") (const False) (checkSequence (Just second) second)),
      ("a conflicting duplicate is corruption", either (T.isInfixOf "conflicting duplicate") (const False) (checkSequence (Just second) conflicting)),
      ("a sequence gap is corruption", either (T.isInfixOf "gap") (const False) (checkSequence (Just second) gap)),
      ("a sequence regression is corruption", either (T.isInfixOf "regressed") (const False) (checkSequence (Just second) regressed)),
      ("a sequence cannot wrap past Word64", either (T.isInfixOf "exhausted") (const False) (checkSequence (Just exhausted) first))
    ]

observedExecutionProbe :: IORef Int -> IO ()
observedExecutionProbe failures = do
  observed <- newIORef ([] :: [RuntimeEvent])
  calls <- newIORef (0 :: Int)
  let occurrenceSink event = atomicModifyIORef' observed (\events -> (event : events, ()))
      repeated = askC1 SText (textQuestion "observed-same")
      effectQ = effectRequest (Q (AddrTool "observed-effect") scopeUnit "observed-effect" 0)
      plan = pairP (pairP repeated repeated) (askC1 SAck effectQ)
      world = concurrentWorld $ \c _ -> do
        atomicModifyIORef' calls (\n -> (n + 1, ()))
        pure (defaultEl c)
  out <- try @SomeException (runPlanObserved occurrenceSink noChains world plan)
  events <- reverse <$> readIORef observed
  invocations <- readIORef calls
  let occurrenceIds = [i | OccurrenceStarted i _ _ _ _ <- events]
      attempts = [i | AttemptStarted i _ <- events]
      reused = [i | OccurrenceReused i _ <- events]
      ordered = [is | TraceOrdered is <- events]
  pureProbe failures "runtime observer preserves scheduler and memo semantics" $
    case out of
      Right (_, trace') ->
        [ ("three reached nodes get three distinct plan-order occurrence ids", sort occurrenceIds == map OccurrenceId [0, 1, 2]),
          ("one memo owner and one effect make two physical attempts", length attempts == 2 && invocations == 2),
          ("the racing equal occurrence is reuse, not a fake attempt", length reused == 1),
          ("authored order comes from tickets", ordered == [map OccurrenceId [0, 1, 2]]),
          ("the existing trace and bills are unchanged", tracePrompts trace' == ["observed-same", "observed-same", "observed-effect"] && (billExecFresh trace', billMemo trace') == (3, 2))
        ]
      Left e -> [("the observed run threw: " <> show e, False)]

observedFailureProbe :: IORef Int -> IO ()
observedFailureProbe failures = do
  failoverEventsRef <- newIORef ([] :: [RuntimeEvent])
  let sink ref event = atomicModifyIORef' ref (\events -> (event : events, ()))
      request model =
        consultRequest (Q (AddrModel "observed-router") (QScope (Just model) Nothing) "observed-route" 0)
      chains = chainsOf (const (pure ())) (Map.fromList [("deep", ["broad"])])
      routedWorld' = concurrentWorld $ \c r -> case c of
        SFlag
          | scopeModelAxis (scopeOf r) == Just "deep" ->
              raiseGap GapTransportRefusal "deep refused" (userError "deep refused")
          | otherwise -> pure True
        _ -> pure (defaultEl c)
  routed <- try @SomeException $
    runPlanObserved (sink failoverEventsRef) chains routedWorld' (askC1 SFlag (request "deep"))
  failoverEvents <- reverse <$> readIORef failoverEventsRef
  let targets = [target | AttemptStarted _ target <- failoverEvents]
      failedAttempts = [failure | AttemptFailed _ failure _ <- failoverEvents]
      completedSources = [source | OccurrenceCompleted _ source _ <- failoverEvents]
  pureProbe failures "runtime observer records failover attempts without changing authored request" $
    case routed of
      Right (_, [ExecEvent _ authored (AnswerAsked dispatched) _]) ->
        [ ("primary and spare are two attempts", targets == ["model observed-router@deep", "model observed-router@broad"]),
          ("the failed primary is classified", failedAttempts == [FailureTransport]),
          ("the occurrence resolves through the spare", completedSources == ["asked:model observed-router@broad"]),
          ("the authored request stays deep", scopeModelAxis (qScope (reqQuestion authored)) == Just "deep"),
          ("dispatch attribution says broad", scopeModelAxis (qScope dispatched) == Just "broad")
        ]
      Right _ -> [("the routed trace had an unexpected shape", False)]
      Left e -> [("the routed observed run threw: " <> show e, False)]

  failureEventsRef <- newIORef ([] :: [RuntimeEvent])
  let boom = askC1 SText (textQuestion "observed-boom")
      broken = concurrentWorld $ \_ _ -> ioError (userError "observed failure")
  failed <- try @SomeException (runPlanObserved (sink failureEventsRef) noChains broken boom)
  failureEvents <- reverse <$> readIORef failureEventsRef
  pureProbe failures "runtime observer records attempt and occurrence failure"
    [ ("the run still raises the original failure", either (T.isInfixOf "observed failure" . T.pack . show) (const False) failed),
      ("the physical attempt failed", length [() | AttemptFailed _ FailureRuntime _ <- failureEvents] == 1),
      ("the reached occurrence failed", length [() | OccurrenceFailed (OccurrenceId 0) FailureRuntime _ <- failureEvents] == 1),
      ("a failed run has no invented authored trace order", null [() | TraceOrdered _ <- failureEvents])
    ]

observedRetryProbe :: IORef Int -> IO ()
observedRetryProbe failures = do
  eventsRef <- newIORef ([] :: [RuntimeEvent])
  let sink event = atomicModifyIORef' eventsRef (\events -> (event : events, ()))
      settings = defaultExecSettings {esLog = const (pure ()), esRetryUndecodable = 2}
      request = consultRequest (Q (AddrModel "retry") scopeUnit "observed-retry" 0)
      world = scriptedWorldWith settings [("observed-retry", "maybe")]
  outcome <- try @SomeException $ runPlanObserved sink noChains world (askC1 SFlag request)
  events <- reverse <$> readIORef eventsRef
  pureProbe failures "runtime observer counts every decode re-ask as a transport attempt"
    [ ("three physical turns were attempted", length [() | AttemptStarted _ _ <- events] == 3),
      ("all three transports completed before decoding refused them", length [() | AttemptCompleted _ _ <- events] == 3),
      ("the occurrence reports terminal decode failure", length [() | OccurrenceFailed _ _ why <- events, "no readable flag" `T.isInfixOf` why] == 1),
      ("the run still abandons without inventing an answer", either (T.isInfixOf "after 3 attempts" . T.pack . show) (const False) outcome)
    ]

controlledRedirectProbe :: IORef Int -> IO ()
controlledRedirectProbe failures = do
  controls <- newControlRuntime
  eventsRef <- newIORef ([] :: [RuntimeEvent])
  statesRef <- newIORef ([] :: [AckState])
  let sink event = do
        atomicModifyIORef' eventsRef (\events -> (event : events, ()))
        case event of
          OccurrenceDispatchPending occurrence targets -> case reverse targets of
            target : _ -> do
              let redirect = Control (ControlId "redirect-live") (Just occurrence) Nothing (RedirectOccurrence target)
              (accepted, action) <- decideRuntimeControl controls redirect
              delivered <- maybe (pure accepted) (deliverRuntimeAction controls redirect) action
              writeIORef statesRef [acknowledgementState accepted, acknowledgementState delivered]
            [] -> pure ()
          _ -> pure ()
      request model =
        consultRequest (Q (AddrModel "observed-router") (QScope (Just model) Nothing) "controlled-redirect" 0)
      chains = chainsOf (const (pure ())) (Map.fromList [("deep", ["broad"])])
      world = concurrentWorld (\c _ -> pure (defaultEl c))
  outcome <- try @SomeException $
    runPlanControlled controls sink chains world (askC1 SFlag (request "deep"))
  events <- reverse <$> readIORef eventsRef
  states <- readIORef statesRef
  pureProbe failures "controlled redirect changes only the pre-dispatch reserved target"
    [ ("redirect is accepted then delivered", states == [Accepted, Delivered]),
      ("only the selected spare is attempted", [target | AttemptStarted _ target <- events] == ["model observed-router@broad"]),
      ("redirected execution preserves the authored answer", either (const False) (const True) outcome)
    ]

steeredMemoProbe :: IORef Int -> IO ()
steeredMemoProbe failures = do
  controls <- newControlRuntime
  eventsRef <- newIORef ([] :: [RuntimeEvent])
  callsRef <- newIORef (0 :: Int)
  steeredRef <- newIORef False
  let sink event = do
        atomicModifyIORef' eventsRef (\events -> (event : events, ()))
        case event of
          AttemptStarted attempt _ -> do
            already <- atomicModifyIORef' steeredRef (\value -> (True, value))
            if already
              then pure ()
              else do
                let steer = Control (ControlId "memo-steer") (Just (attemptOccurrence attempt)) (Just attempt) (Steer NextBoundary "different")
                (_, action) <- decideRuntimeControl controls steer
                maybe (pure ()) (void . deliverRuntimeAction controls steer) action
          _ -> pure ()
      repeated = askC1 SText (textQuestion "steered-memo")
      world =
        WorldIO
          { worldAskIO = \c _ -> pure (defaultEl c),
            worldAskAttemptIO = \context c _ ->
              withPhysicalAttempt
                (withAttemptSteering context (\_ _ -> pure (Right ())))
                "controlled"
                (\_ -> do
                    atomicModifyIORef' callsRef (\count -> (count + 1, ()))
                    threadDelay 20000
                    pure (defaultEl c)
                ),
            worldTurnLane = \_ _ -> Nothing
          }
  outcome <- try @SomeException $ runPlanControlled controls sink noChains world (pairP repeated repeated)
  calls <- readIORef callsRef
  events <- reverse <$> readIORef eventsRef
  pureProbe failures "steered in-flight answers are not replayed to memo waiters"
    [ ("both occurrences dispatch independently", calls == 2),
      ("no occurrence is reported as ordinary reuse", null [() | OccurrenceReused _ _ <- events]),
      ("the authored program still completes", either (const False) (const True) outcome)
    ]

main :: IO ()
main = do
  failures <- newIORef (0 :: Int)
  inputSourceProbe failures
  let d = defaultExecSettings
  machineFrameProbe failures
  storeProbe failures
  controlProbe failures
  protocolProbe failures
  observedExecutionProbe failures
  observedFailureProbe failures
  observedRetryProbe failures
  controlledRedirectProbe failures
  steeredMemoProbe failures

  probe failures "defaults abandon after 2 attempts" d
    (Left "after 2 attempts")
  probe failures "loud-arm yes takes the act (7/7)" d {esLoudArm = Just True}
    (Right (7, 7))
  probe failures "loud-arm no skips the act (6/6)" d {esLoudArm = Just False}
    (Right (6, 6))
  probeLogged failures "…and the warning owns the safety"
    d {esLoudArm = Just False} "that safety is the operator's"
  probe failures "standing answer 'no' never asks the person (6/6)"
    d {esStandingAnswer = Just "no"} (Right (6, 6))
  -- With no spare declared, a policy that asks for fail-over gets the
  -- abandonment the run would have raised with no chain at all: the layer that
  -- knows whether there is anywhere to go is `askOrMemo`, and it degrades a
  -- fail-over with nowhere to go rather than inventing an answer.
  probe failures "FailOver with no spare abandons in the old words"
    d {esRecover = const FailOver} (Left "after 1 attempts")
  probe failures "retry budget 3 means 4 attempts"
    d {esRetryUndecodable = 3} (Left "after 4 attempts")

  overlapProbe failures
  effectOrderProbe failures
  statefulTurnOrderProbe failures
  dependencyProbe failures
  memoConcurrencyProbe failures
  intentMemoProbe failures
  failoverMemoIdentityProbe failures
  sourceIntentProbe failures
  failureConcurrencyProbe failures

  -- The surface's own refusals: what an author is told, in the author's words.
  refusal failures "two functions of one name are refused"
    twoOfOneName "two functions answer to one name"
  refusal failures "a call of a function defining was not given is refused"
    callsAnUnlistedFunction "which defining was not given"
  refusal failures "named refuses a generated name"
    namedIsReserved "`b1` is a name this surface generates for itself"
  refusal failures "takes refuses a generated name"
    takesIsReserved "`b1` is a name this surface generates for itself"
  -- The author's half of the run facts. The operator's half is a command line
  -- and is typed in `ci/policies.sh`, because a refusal `resolveInputs` makes
  -- is only exercised by giving the flag.
  refusal failures "input refuses a misspelled run fact"
    inputIsMisspelledRunFact "is under the `run.` prefix"

  -- The two quoters say the same bytes. `wft` was added so that a define need
  -- not be written as a prompt and then converted, and the only thing anybody
  -- had to be sure of before rewriting every define in `Example.Isaac` was
  -- this: that the conversion moving inside the quoter moves no text. The first
  -- two rows are that equality at the two hole shapes; the last three keep it
  -- from being an agreement between two equally wrong values, by pinning what
  -- the shared layout rule did to the block — the first blank line dropped, the
  -- common indentation gone, and no trailing newline.
  --
  -- The half of `wft` that is NOT here is its refusal: a hole naming a live
  -- binding is `Agentic.WF.Scopeless`, and that is a *type* error, which cannot
  -- be a case in a probe that has to compile. Writing the mistake is the one
  -- thing this file may not do, so the wording is pinned by living at the
  -- definition and nowhere else.
  pureProbe failures "[wft|…|] is wfText [wf|…|], byte for byte"
    [ ("a hole-free define", lensNewWay == lensOldWay),
      ("a define holing a count and a fence", holedNewWay == holedOldWay),
      ("the fence opens at its first word", "Correctness lens. Read" `T.isPrefixOf` lensNewWay),
      ("the holes said what they name", "one of 6 independent reviewers" `T.isInfixOf` holedNewWay),
      ("and no fence ends in a newline", not (any ("\n" `T.isSuffixOf`) [lensNewWay, holedNewWay]))
    ]

  -- The fail-over itself: the run settles, the trace names who answered, the
  -- narration says what it was about to do, and — the acceptance criterion —
  -- with no chain the very same world and program abandon in the old words.
  do
    logged <- newIORef []
    let chains =
          chainsOf
            (\t -> modifyIORef' logged (t :))
            (Map.fromList [("deep", ["broad"])])
    out <- try (runPlanWith chains (refusingWorld "deep") (progPlan failOverProgram))
    msgs <- readIORef logged
    case out :: Either SomeException ((), ExecTrace) of
      Left e -> do
        TIO.putStrLn ("FAIL fail-over settles: threw " <> T.pack (show e))
        modifyIORef' failures (+ 1)
      Right (_, tr)
        | billExecFresh tr == 2 && billMemo tr == 2 ->
            TIO.putStrLn "ok   fail-over settles on the spare (2/2)"
        | otherwise -> do
            TIO.putStrLn
              ( "FAIL fail-over settles: bills ("
                  <> T.pack (show (billExecFresh tr))
                  <> ","
                  <> T.pack (show (billMemo tr))
                  <> ") wanted (2,2)"
              )
            modifyIORef' failures (+ 1)
    case out of
      Right (_, tr)
        | take 1 (answerers tr) == [Just "broad"],
          take 1 (authoredModels tr) == [Just "deep"] ->
            TIO.putStrLn "ok   …and the trace names the model that answered"
        | otherwise -> do
            TIO.putStrLn
              ( "FAIL the trace names the answerer: got "
                  <> T.pack (show (take 1 (answerers tr)))
              )
            modifyIORef' failures (+ 1)
      _ -> pure ()
    if any ("falling back to broad" `T.isInfixOf`) msgs
      then TIO.putStrLn "ok   …and the fall-back is narrated"
      else do
        TIO.putStrLn "FAIL nothing narrated the fall-back"
        mapM_ (TIO.putStrLn . ("  log: " <>)) (reverse msgs)
        modifyIORef' failures (+ 1)

  do
    out <- try (runPlanIO (refusingWorld "deep") (progPlan failOverProgram))
    case out :: Either SomeException ((), ExecTrace) of
      Left e
        | "no readable flag from model r" `T.isInfixOf` T.pack (show e) ->
            TIO.putStrLn "ok   …and with no chain it abandons in the old words"
        | otherwise -> do
            TIO.putStrLn ("FAIL no-chain abandonment: " <> T.pack (show e))
            modifyIORef' failures (+ 1)
      Right _ -> do
        TIO.putStrLn "FAIL no-chain abandonment: the run completed"
        modifyIORef' failures (+ 1)

  -- D5: the exit status is the answer. `true` takes the yes arm and pays for
  -- the act; `false` takes the no arm and does not. Nothing but the executing
  -- layer may answer these, which `noWorld` enforces by raising.
  execProbe failures "a command that exits 0 answers yes (2/2)"
    (runningProgram "true" []) (\tr -> billExecFresh tr == 2 && billMemo tr == 2)
  execProbe failures "…and one that exits nonzero answers no (1/1)"
    (runningProgram "false" []) (\tr -> billExecFresh tr == 1 && billMemo tr == 1)
  -- The most important D5 assertion: two commands at one tool id, saying the
  -- same words, are two questions. Were the argv anywhere outside the
  -- addressee the second would be answered from the memo table without running.
  execProbe failures "two commands at one tool are two questions (2/2)"
    twoCommandsProgram (\tr -> billExecFresh tr == 2 && billMemo tr == 2)
  -- A command that cannot be run is a __gap__, not an answer, and it is named
  -- so an operator can tell "the gate said no" from "the gate could not be run".
  do
    let cfg = defaultShellConfig {shellCwd = "."}
    out <-
      try
        ( runPlanIO
            (executingWorld cfg noWorld)
            (progPlan (runningProgram "no-such-gate-command" []))
        )
    case out :: Either SomeException ((), ExecTrace) of
      Left e
        | "did not run" `T.isInfixOf` T.pack (show e) ->
            TIO.putStrLn "ok   …and a command that cannot be run is named, not answered"
        | otherwise -> do
            TIO.putStrLn ("FAIL the missing command: " <> T.pack (show e))
            modifyIORef' failures (+ 1)
      Right _ -> do
        TIO.putStrLn "FAIL the missing command: the run completed"
        modifyIORef' failures (+ 1)

  -- Permission authority exists only while session/prompt is active. The stub
  -- sends a same-session permission request after a completed effect; newSession
  -- pumps it before its own response, and it must be cancelled despite the prior
  -- effect having carried Grant.
  temp <- getTemporaryDirectory
  stamp <- getMonotonicTimeNSec
  let delayedDir = temp </> ("agentic-delayed-permission-" <> show stamp)
      delayedCfg =
        (defaultAcpConfig (adapterArgv "stub" <> ["--delayed-same-session-permission"]))
          { acpCwd = delayedDir, acpTurnTimeoutMs = 10000 }
      delayedRequest = effectRequest (Q (AddrTool "apply") scopeUnit "Apply:\n+ok" 0)
  createDirectoryIfMissing True delayedDir
  delayed <-
    try
      ( withAcp delayedCfg $ \acp -> do
          _ <- sayAcp delayedCfg acp SAck delayedRequest ""
          _ <- newSession acp
          doesFileExist (delayedDir </> "delayed-permission-cancelled")
      )
      `finally` removePathForcibly delayedDir
  let delayedSafe = case delayed :: Either SomeException Bool of
        Right True -> True
        _ -> False
  pureProbe failures "same-session permissions outside prompt scope are cancelled"
    [("delayed after completed effect", delayedSafe)]

  -- Routing (Agentic.Route): the grammar an operator types, and the one rule
  -- that decides where a question goes. Pure — no process, no network — because
  -- routing is a function of a field the interpreter has already computed.
  resolvedDroid <- resolveArgv (adapterArgv "droid" <> ["./test/PolicyProbe.hs"])
  pureProbe failures "Droid adapter arguments remain byte-for-byte unchanged"
    [("existing relative path", resolvedDroid == ["droid", "exec", "--output-format", "acp", "./test/PolicyProbe.hs"])]
  pureProbe failures "adapterArgv selects Droid's native ACP mode"
    [ ("droid", adapterArgv "droid" == ["droid", "exec", "--output-format", "acp"]),
      ("appended argv", adapterArgv "droid" <> ["--probe"] == ["droid", "exec", "--output-format", "acp", "--probe"])
    ]
  pureProbe failures "parseBackend reads both schemes, splitting on the first colon"
    [ ("acp:stub", parseBackend "acp:stub" == Right (BackendAcp "stub")),
      ("acp:claude", parseBackend "acp:claude" == Right (BackendAcp "claude")),
      ("acp:codex", parseBackend "acp:codex" == Right (BackendAcp "codex")),
      ("acp:droid", parseBackend "acp:droid" == Right (BackendAcp "droid")),
      ("acp:PATH", parseBackend "acp:/opt/bin/my-adapter" == Right (BackendAcp "/opt/bin/my-adapter")),
      ("deck:id", parseBackend "deck:gemini-pane" == Right (BackendDeck "gemini-pane")),
      -- The first colon and no other: a deck session's title may contain one,
      -- and a value split anywhere else would make it unnameable.
      ("deck:a:b", parseBackend "deck:notes: monday" == Right (BackendDeck "notes: monday")),
      ( "unknown scheme names both shapes",
        parseBackend "grpc:x"
          == Left
            [wft|unknown backend 'grpc:x' in --route: a backend is acp:<adapter> (start an adapter of this run's own) or deck:<id> (send to a live agent-deck session)|]
      ),
      ("no colon at all", either ("unknown backend 'codex'" `T.isInfixOf`) (const False) (parseBackend "codex")),
      ("a scheme with no value", either ("unknown backend 'acp:'" `T.isInfixOf`) (const False) (parseBackend "acp:"))
    ]
  -- __Whitespace is not part of a name or of a backend__, which is a refusal
  -- and not a convenience. A blank value is one character rather than none, so
  -- until it was trimmed `--route 'deep=acp: '` passed every check the command
  -- line makes: it printed a header naming an adapter with no name, started one,
  -- and was found out by `posix_spawnp` — after the run had spawned. A usage
  -- error discovered after a spawn is not a usage error, and these are the
  -- spellings that say so.
  pureProbe failures "whitespace is not part of a name or a backend"
    [ ( "a blank value refuses, exactly as an absent one does",
        either ("unknown backend 'acp: '" `T.isInfixOf`) (const False) (parseBackend "acp: ")
      ),
      ( "…and a blank deck id likewise",
        either ("unknown backend" `T.isInfixOf`) (const False) (parseBackend "deck:  ")
      ),
      ("a padded backend is the bare one", parseBackend " acp: codex " == Right (BackendAcp "codex")),
      ("a padded route is the bare one", parseRoute " deep = acp:codex " == Right ("deep", BackendAcp "codex")),
      ( "a blank name takes the shape refusal",
        either ("--route takes NAME=BACKEND" `T.isInfixOf`) (const False) (parseRoute " =acp:codex")
      )
    ]
  -- The law `backendSpelling`'s haddock asserts and nothing checked:
  -- `parseBackend . backendSpelling == Right`. It is the reason a caller may
  -- name a backend in one word without inventing `acp:` for itself — the run's
  -- header, `run.backends` and every refusal that quotes a backend all go
  -- through it — so a spelling the parser could not read back would be a
  -- second grammar wearing the first one's name. Over the shapes the parser can
  -- produce, including the two the round trip could plausibly lose: a path with
  -- slashes and dots, and a deck id containing the very colon the parser splits
  -- on.
  pureProbe failures "backendSpelling round-trips through parseBackend"
    [ (T.unpack (backendSpelling b), parseBackend (backendSpelling b) == Right b)
      | b <-
          [ BackendAcp "stub",
            BackendAcp "claude",
            BackendAcp "codex",
            BackendAcp "droid",
            BackendAcp "/opt/bin/my-adapter",
            BackendAcp "./adapters/local.sh",
            BackendDeck "gemini-pane",
            BackendDeck "notes: monday",
            BackendDeck "3"
          ]
    ]
  -- `run.engine`'s two halves are built from `sessionPolicy`
  -- (`Agentic.Cli.runFactsOf`) so that a program can gate on them
  -- (`sharesOneSession`), and that is a contract between a printed sentence and
  -- a predicate. Asserted here because the two live in different repositories:
  -- `agent-workflows`' `wiggum` refuses to start a loop when this predicate
  -- holds, and a reworded phrase would turn that gate off without failing
  -- anything.
  --
  -- The mixed arm is the one worth stating: a run that is half `acp:` and half
  -- `deck:` shares a conversation with SOME of its answerers, and a gate that
  -- read that as independence would be reading the half that suits it.
  pureProbe failures "run.engine says its session policy in one matchable phrase"
    [ ("a fresh session per question is not one session", not (sharesOneSession ("acp: " <> sessionPolicy True))),
      ("one session for the run is", sharesOneSession ("acp: " <> sessionPolicy False)),
      ("a deck pane is, by construction", sharesOneSession ("deck: " <> sessionPolicy False)),
      ( "and a mixed run is, on the strength of its shared half",
        sharesOneSession ("acp: " <> sessionPolicy True <> "; deck: " <> sessionPolicy False)
      ),
      -- What `plan` and `cost` hole, where no run is being made.
      ("an unbound fact is not a claim of sharing", not (sharesOneSession "")),
      -- The scripted target reaches no session at all, and its own words must
      -- not be read as either policy.
      ( "and neither is a scripted table",
        not (sharesOneSession "scripted: a canned table, no process and no session")
      ),
      ("the two policies are different sentences", sessionPolicy True /= sessionPolicy False)
    ]
  -- `run.routes` is the fourth run fact and it is the same *kind* of contract
  -- the group above pins: a printed table on one side, a predicate on the other,
  -- and the two in different repositories. `Agentic.Cli.routesFact` writes it,
  -- `Agentic.Workflow.routedBackend` reads it, and `agent-workflows`' gate on
  -- "is the judge somewhere the work is not" is decided from what it reads — so
  -- a reworded separator, a dropped default line or a deduplicated table would
  -- switch that gate off without failing anything else.
  --
  -- Two groups and not one, per `pureProbe`'s own rule: the spelling and the
  -- reading are two rules, and a group whose rows were spellings of both would
  -- report one fact where there are two.
  --
  -- The spelling is asserted VERBATIM, which no other fact here is, because this
  -- one is read back by a machine as well as by an operator: it is the run's own
  -- header table restated for the prompts, and the operator is meant to be able
  -- to lay the three side by side — command line, header, fact.
  pureProbe failures "run.routes is the route table in the header's own words"
    [ ( "the owner's split, verbatim",
        routesFact (Just ownersSplit) == "(default) = deck:CODEX\npartner = deck:CLAUDE\n"
      ),
      ( "the default is the first line, and is labelled rather than named",
        take 1 (T.lines (routesFact (Just ownersSplit)))
          == [routeDefaultLabel <> " = " <> backendSpelling (BackendDeck "CODEX")]
      ),
      ( "the routes follow in the order they were typed",
        drop 1 (T.lines (routesFact (Just ownersSplit)))
          == ["partner = " <> backendSpelling (BackendDeck "CLAUDE")]
      ),
      -- An unrouted live run is NOT an empty fact, and that is the whole reason
      -- the default line exists: it is the one line that tells a run whose judge
      -- and workers both fall to the default apart from the split where only the
      -- judge was routed away. Omit it and the two read alike.
      ( "an unrouted live run still has a table, and it is the default's line",
        routesFact (Just (routes (BackendDeck "PANE") [])) == "(default) = deck:PANE\n"
      ),
      -- `routeBackends` deduplicates because a header that counted route lines
      -- would overstate how many agents a run started. This is the mapping, and
      -- two pins on one backend is precisely what a gate over it must see.
      ( "it does not deduplicate: two pins on one pane are two lines",
        length (T.lines (routesFact (Just sharedPane))) == 3
      ),
      -- The table `ci/deck.sh`'s eighth scenario runs one program against, whose
      -- two header lines that gate asserts. The header's two lines and the
      -- fact's two lines are one walk of one table, and they are held together
      -- here because the transport gate can see the header while no
      -- `agentic-run` row holes this fact for it to see.
      ( "the two-stub scenario's table, verbatim",
        routesFact (Just (routes (BackendDeck "pane-a") [("deep", BackendDeck "pane-b")]))
          == "(default) = deck:pane-a\ndeep = deck:pane-b\n"
      ),
      -- What `plan`, `cost` and `--scripted` hole, where there is no table at
      -- all. Empty means NO TABLE, not "no --route".
      ("no table is the empty text", routesFact Nothing == ""),
      ( "and a table is never empty, so the two cannot be confused",
        not (T.null (routesFact (Just (routes (BackendAcp "stub") []))))
      )
    ]
  -- The reader. The round trip is the load-bearing row: every right-hand side is
  -- `backendSpelling`, which is documented as the printed inverse of
  -- `parseBackend`, so a gate that reads this fact is reading the operator's own
  -- word rather than a second rendering of it.
  pureProbe failures "routedBackend reads a run.routes table back"
    ( [ ( "round trip: " <> T.unpack (backendSpelling (routeDefault t)) <> "/" <> T.unpack n,
          routedBackend (routesFact (Just t)) n == backendSpelling b
        )
        | t <- [ownersSplit, sharedPane, pathBackend],
          (n, b) <- routeNamed t
      ]
        <> [ -- The default is reachable under its own label, which is how a gate
             -- asks "and where does everything else go?".
             ( "the label reads as the default",
               routedBackend (routesFact (Just ownersSplit)) routeDefaultLabel == "deck:CODEX"
             ),
             -- Not an error, and the point of having a default at all: this row
             -- is `backendFor`'s "an unrouted pin takes the default", restated
             -- over the fact so that the program reads what the runtime does.
             ( "a pin no route names takes the default",
               routedBackend (routesFact (Just ownersSplit)) "worker" == "deck:CODEX"
             ),
             -- The pair of rows a gate exists for. Under the split the judge's
             -- pin is somewhere the default is not; under the inversion — the
             -- same two panes, the other flag routed — it is the default, so
             -- everything the program did not pin itself lands in the pane that
             -- is about to judge it. The fact distinguishes them; nothing else
             -- the runner binds does.
             ( "the split puts the routed pin somewhere the default is not",
               routedBackend (routesFact (Just ownersSplit)) "partner"
                 /= routedBackend (routesFact (Just ownersSplit)) routeDefaultLabel
             ),
             ( "and its inversion leaves it on the default, which is not the same run",
               routedBackend (routesFact (Just inverted)) "partner"
                 == routedBackend (routesFact (Just inverted)) routeDefaultLabel
             ),
             -- The separator is the first `=`, both halves trimmed, which is
             -- `parseRoute`'s own rule: a backend may contain an `=` (a path)
             -- and a label never does.
             ( "the split is on the first =, so a path-valued backend survives",
               routedBackend (routesFact (Just pathBackend)) "deep" == "acp:/opt/a=b/adapter"
             ),
             -- An unbound fact, which is what `plan` and `cost` hole. The empty
             -- answer is the honest one: a gate over it must decide the shape a
             -- run with an unknown table would take.
             ("an empty table answers nothing, for every pin", routedBackend "" "partner" == ""),
             ("and nothing under the default's label either", routedBackend "" routeDefaultLabel == "")
           ]
    )
  pureProbe failures "parseRoute splits NAME=BACKEND on the first ="
    [ ("deep=acp:codex", parseRoute "deep=acp:codex" == Right ("deep", BackendAcp "codex")),
      ("deep=acp:droid", parseRoute "deep=acp:droid" == Right ("deep", BackendAcp "droid")),
      -- The first `=`, for the reason `--input-file` splits on the first `=`:
      -- no model name contains one and a value may contain as many as it likes.
      ("a value containing =", parseRoute "deep=acp:/opt/a=b/adapter" == Right ("deep", BackendAcp "/opt/a=b/adapter")),
      ("a missing = names the shape", parseRoute "deep" == Left "--route takes NAME=BACKEND, not 'deep'"),
      ("an empty name names the shape", parseRoute "=acp:codex" == Left "--route takes NAME=BACKEND, not '=acp:codex'"),
      -- A well-formed route whose backend is not is the backend's refusal,
      -- unchanged: the operator's mistake is the part they must retype.
      ( "a bad backend keeps the backend's words",
        either Left (const (Right ())) (parseRoute "deep=grpc:x")
          == either Left (const (Right ())) (parseBackend "grpc:x")
      )
    ]
  pureProbe failures "backendFor sends a pinned question to its route"
    [ ("gemini", backendFor namedRoutes (asked (Just "gemini") (AddrModel "lateral")) == "gemini-backend"),
      ("opus", backendFor namedRoutes (asked (Just "opus") (AddrModel "author")) == "opus-backend")
    ]
  pureProbe failures "…and an unrouted pin to the default"
    -- Not an error, and this is the point of having a default at all: an
    -- exhaustive route table would make --route unusable on any program with
    -- more than two pins.
    [("fable", backendFor namedRoutes (asked (Just "fable") (AddrModel "author")) == "default")]
  -- One row and not three: an unpinned ask, a tool and a person differ in their
  -- addressee and in nothing `backendFor` reads, so three rows would report
  -- three facts where there is one.
  pureProbe failures "…and every question with no axis — ask, tool or person — to the default"
    [ ("an unpinned model ask", backendFor namedRoutes (asked Nothing (AddrModel "reviewer-correct")) == "default"),
      ("a tool", backendFor namedRoutes (asked Nothing (AddrTool "cat")) == "default"),
      ("a person", backendFor namedRoutes (asked Nothing (AddrPerson "owner")) == "default")
    ]

  -- __The header counts processes, not route lines.__ `routeBackends` is what a
  -- run starts and what its header announces, and being `nub` over the default
  -- and the typed order is the whole reason it is a function rather than
  -- `map snd`: two pins at one adapter are one provider, so a run that started
  -- two would double nothing and a header that counted lines would claim more
  -- agents than it had. The default is first because every run needs it, so one
  -- whose default will not start fails before spawning anything else.
  pureProbe failures "routeBackends is the distinct backends, the default first"
    [ ( "two pins at one backend are one process",
        routeBackends (namedTable "default" [("deep", "codex"), ("broad", "codex")])
          == ["default", "codex"]
      ),
      ( "a route back to the default adds nothing",
        routeBackends (namedTable "default" [("deep", "default")]) == ["default"]
      ),
      ( "the default leads, then the order they were typed",
        routeBackends (namedTable "d" [("b", "second"), ("a", "first")]) == ["d", "second", "first"]
      ),
      ("and an empty table is the default alone", routeBackends (namedTable "default" []) == ["default"])
    ]

  -- __Connecting a table moves no question.__ The run announces
  -- `routeBackends` of the table the command line spelled and then dispatches
  -- over `fmap connect` of that same table (Cli.hs:813 and :842), so the header
  -- is a true statement about the run only because `fmap` is the connect step
  -- and nothing else: it rewrites the backends and touches neither the
  -- default's place nor the lookup. That is the naturality below, and the
  -- consequence worth having is the second row — no question can reach a
  -- backend the header did not name.
  pureProbe failures "connecting a table moves no question"
    [ ( "backendFor commutes with fmap",
        and
          [ backendFor (fmap connected namedRoutes) q == connected (backendFor namedRoutes q)
            | q <- routeSamples
          ]
      ),
      ( "so every answerer is one the header named",
        and
          [ backendFor (fmap connected namedRoutes) q
              `elem` map connected (routeBackends namedRoutes)
            | q <- routeSamples
          ]
      )
    ]

  -- __Routing is invisible to the fold.__ The same program, once with an empty
  -- route table and once with four backends that answer alike: byte-identical
  -- traces, identical bills. This is the design's central claim made executable
  -- — no field of an `EventKey`, an `Event` or an `eventJson` names a backend,
  -- so there is no field in which two runs differing only in their route table
  -- could differ.
  --
  -- The four are __distinct worlds__ that happen to agree, each noting that it
  -- was consulted, and that is what keeps the claim from being vacuous: behind
  -- one shared world these traces would be equal however the questions were
  -- dispatched — including not dispatched at all — so the last three rows say
  -- where they actually went. The flagship pins one model, `deep`; `fable` and
  -- `gemini` are configured and never reached, which is the distinction
  -- ci/route-live.sh makes between backends configured and backends reached.
  do
    seen <- newIORef []
    (_, bare) <-
      runPlanIO
        (routedWorld (routes (tellingWorld seen "default") []))
        (progPlan hardenProgram)
    bareSeen <- readIORef seen
    writeIORef seen []
    (_, routed) <-
      runPlanIO
        ( routedWorld
            ( routes
                (tellingWorld seen "default")
                [ ("deep", tellingWorld seen "deep"),
                  ("fable", tellingWorld seen "fable"),
                  ("gemini", tellingWorld seen "gemini")
                ]
            )
        )
        (progPlan hardenProgram)
    routedSeen <- readIORef seen
    pureProbe failures "routing is invisible to the fold"
      [ ("the semantic traces are equal after erasure",
          map (eventJson . forgetExecEvent) bare ==
            map (eventJson . forgetExecEvent) routed),
        ("billFresh", billExecFresh bare == billExecFresh routed),
        ("billMemo", billMemo bare == billMemo routed),
        -- And they are the flagship's own numbers, so the row cannot pass by
        -- finding two equally wrong runs.
        ("the flagship's bills", (billExecFresh routed, billMemo routed) == (7, 7)),
        ("the unrouted run reached the default and nothing else", nub bareSeen == ["default"]),
        ("the routed run put the pinned questions to deep", "deep" `elem` routedSeen),
        ("…and every other question to the default", sort (nub routedSeen) == ["deep", "default"]),
        ("with the same number of consultations either way", length routedSeen == length bareSeen)
      ]

  -- __Routing does not intercept `toolExec`.__ `executingWorld` answers an
  -- `AddrToolExec` question before consulting the world beneath it, so a
  -- program-authored command reaches no backend at all. D5's guarantee — a gate
  -- is an exit code and not a model's claim about one — is unaffected by which
  -- providers a run reached.
  --
  -- The table is the discriminating part: the default __raises__ and the one
  -- route __answers__, so the two ways this could be wrong fail in two
  -- different places. A command that reached routing would be unpinned, find
  -- the default and raise; and the pinned ask between the two commands, put to
  -- the default rather than to the route its axis names, would raise too. Only
  -- a run that intercepted both commands /and/ read the table settles.
  do
    let cfg = defaultShellConfig {shellCwd = "."}
        table = routes noWorld [("deep", pureWorldIO plainWorld)]
    out <-
      try
        ( runPlanIO
            (executingWorld cfg (routedWorld table))
            (progPlan routedGateProgram)
        )
    case out :: Either SomeException ((), ExecTrace) of
      Left e -> do
        TIO.putStrLn ("FAIL routing does not intercept toolExec: threw " <> T.pack (show e))
        modifyIORef' failures (+ 1)
      Right (_, tr) ->
        pureProbe failures "routing does not intercept toolExec"
          [ ("bills", billExecFresh tr == 3 && billMemo tr == 3),
            ( "the two commands were the executing layer's and the ask was deep's",
              answerers tr == [Nothing, Just "deep", Nothing]
            )
          ]

  -- __A fail-over across backends__, which is the capability the whole design
  -- exists for, proved without a process: two /distinct/ worlds are two
  -- backends as far as `routedWorld` is concerned. `deep` is routed to one that
  -- will not answer; the ladder relabels the question to `broad`, which no
  -- route claims, so the next rung is put to the default — and that is a
  -- fail-over that crossed a backend with no change to `Agentic.Exec` at all.
  --
  -- The last case is the acceptance criterion: with no alternates declared, the
  -- very same two backends abandon in exactly the words they always did.
  do
    logged <- newIORef []
    let chains = chainsOf (\t -> modifyIORef' logged (t :)) (Map.fromList [("deep", ["broad"])])
        rs = routes (pureWorldIO plainWorld) [("deep", deadBackend)]
    out <- try (runPlanWith chains (routedWorld rs) (progPlan failOverProgram))
    msgs <- readIORef logged
    bare <- try (runPlanIO (routedWorld rs) (progPlan failOverProgram))
    let settled = case out :: Either SomeException ((), ExecTrace) of
          Right (_, tr) -> billExecFresh tr == 2 && billMemo tr == 2
          Left _ -> False
        namesBroad = case out of
          Right (_, tr) -> take 1 (answerers tr) == [Just "broad"]
          Left _ -> False
        authoredDeep = case out of
          Right (_, tr) -> take 1 (authoredModels tr) == [Just "deep"]
          Left _ -> False
        abandons = case bare :: Either SomeException ((), ExecTrace) of
          Left e -> "no readable flag from model r" `T.isInfixOf` T.pack (show e)
          Right _ -> False
    pureProbe failures "a fail-over crosses backends, and with no spare abandons as ever"
      [ ("settles on the spare's backend (2/2)", settled),
        ("the trace names the model that answered", namesBroad),
        ("failover preserves the authored deep question", authoredDeep),
        ("the narration keeps its wording", any ("falling back to broad" `T.isInfixOf`) msgs),
        ("with no chain the same two backends abandon in the old words", abandons)
      ]

  -- __A verb in head position beats a row of the same name.__ Over
  -- 'collidingRegistry', where every verb is also a row: the verb answers every
  -- time, the rows named after it are reachable through `help NAME` and through
  -- nothing else, and the one row that is not a verb keeps both of the answers
  -- an ordinary row has.
  --
  -- `run` is the row the ruling's stop condition is about — it is the verb that
  -- could start spending — so it is asked in all three of its spellings. The
  -- last two rows are the control: strike the collision and the same command
  -- lines mean the row.
  pureProbe failures "a verb in head position beats a row of the same name"
    [ ("run NAME is the verb", parsedAs ["run", "ordinary", "--scripted"] == "run ordinary"),
      ("machine RUN_ID NAME is the structured verb", parsedAs ["machine", "run-1", "ordinary", "--scripted"] == "machine ordinary"),
      ("a bare `run` is the verb wanting a subject", parsedAs ["run"] == "refused"),
      ("`run --help` is the verb too, and refuses", parsedAs ["run", "--help"] == "refused"),
      ("plan NAME is the verb", parsedAs ["plan", "ordinary"] == "plan ordinary"),
      ("cost NAME is the verb", parsedAs ["cost", "ordinary"] == "cost ordinary"),
      ("`list` is the verb", parsedAs ["list"] == "list"),
      ("`help` alone is the usage", parsedAs ["help"] == "usage"),
      -- The one door left open, and it is enough: a row named after a verb can
      -- still be READ about, which is what makes the situation a thing to fix
      -- rather than a thing to discover.
      ("`help run` reaches the row named run", parsedAs ["help", "run"] == "help run"),
      ("`help help` reaches the row named help", parsedAs ["help", "help"] == "help help"),
      ("an ordinary row is refused bare, naming the verbs", parsedAs ["ordinary"] == "bare-row"),
      ("…and answers NAME --help", parsedAs ["ordinary", "--help"] == "help ordinary"),
      ("an unregistered name is still no verb", parsedAs ["ordinarie"] == "no-verb")
    ]

  n <- readIORef failures
  if n == 0
    then TIO.putStrLn "policy probe: all checks passed"
    else do
      TIO.putStrLn ("policy probe: " <> T.pack (show n) <> " failed")
      exitFailure
