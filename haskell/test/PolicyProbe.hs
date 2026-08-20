{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
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
-- A second section pins the __surface's own refusals__ (fess wave-2, gap V3):
-- the three mistakes 'Agentic.Workflow' answers with an @error@ rather than
-- with a type error, forced out of the four bottoms in "SurfaceRefusals". They
-- are here rather than in @tier1@ because a refusal has no corpus entry to be
-- pinned against — there is no program, so there is nothing to freeze — and
-- because what is worth pinning about them is the /wording/, which is the only
-- thing the author ever sees.
module Main (main) where

import Agentic.Exec
import Agentic.Plan
  ( El,
    Q (..),
    QScope (..),
    SCode (SAck, SFlag, SText, SVerdict),
    fromSCode,
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
    routedWorld,
    routes,
  )
import Agentic.Shell (ShellConfig (shellCwd), defaultShellConfig, executingWorld)
import Agentic.Workflow (Words, sessionPolicy, sharesOneSession, wf, wft)
import Agentic.World (Event (Event), Trace, World (World), billFresh, billMemo, eventJson)
import Control.Exception (ErrorCall, SomeException, evaluate, try)
import Data.IORef
import Data.List (nub, sort)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Example.Harden (hardenProgram)
import Agentic.Builder
  ( Code (CodeFlag, CodeText),
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
import System.Exit (exitFailure)

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
      | billFresh tr == wantFresh && billMemo tr == wantMemo ->
          TIO.putStrLn ("ok   " <> T.pack name)
      | otherwise ->
          failWith
            ( "bills ("
                <> T.pack (show (billFresh tr))
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
refusingWorld bad = WorldIO $ \c q ->
  if scopeModelAxis (qScope q) == Just bad
    then
      raiseGap
        GapTransportRefusal
        (bad <> " is not answering")
        (userError ("no readable flag from model r after 1 attempts"))
    else pure (answerAt c q)
  where
    answerAt :: SCode c -> Q c -> El c
    answerAt SFlag _ = True
    answerAt SAck _ = ()
    answerAt SText q = qPrompt q
    answerAt SVerdict _ = verdictApprove

-- | The model each event's scope names, in trace order.
answerers :: [Event] -> [Maybe Text]
answerers tr = [scopeModelAxis (qScope q) | Event _ q _ <- tr]

-- ---------------------------------------------------------------------------
-- The executing world (D5)
-- ---------------------------------------------------------------------------

-- | A world that answers nothing, so that a @toolExec@ question answered by
-- anything but the executing layer is a loud failure rather than a quiet pass.
noWorld :: WorldIO
noWorld = WorldIO $ \c q ->
  ioError
    ( userError
        ( "the executing layer did not take a "
            <> T.unpack (codeWord (fromSCode c))
            <> " question put to "
            <> T.unpack (addresseeWord (qAddressee q))
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
pureProbe :: IORef Int -> String -> [(String, Bool)] -> IO ()
pureProbe failures name cases = case [c | (c, ok) <- cases, not ok] of
  [] -> TIO.putStrLn ("ok   " <> T.pack name)
  bad -> do
    TIO.putStrLn ("FAIL " <> T.pack name <> ": " <> T.pack (unwords bad))
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
tellingWorld seen name = WorldIO $ \c q -> do
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

-- | A backend that will not answer anything, raising a __gap__ — "nothing
-- usable came back" — rather than an ordinary error, so that the question may
-- be put to the next rung of its ladder.
deadBackend :: WorldIO
deadBackend = WorldIO $ \_ _ ->
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

execProbe :: IORef Int -> String -> Program -> (Trace -> Bool) -> IO ()
execProbe failures name prog want = do
  let cfg = defaultShellConfig {shellCwd = "."}
  out <- try (runPlanIO (executingWorld cfg noWorld) (progPlan prog))
  case out :: Either SomeException ((), Trace) of
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
                <> T.pack (show (billFresh tr))
                <> ","
                <> T.pack (show (billMemo tr))
                <> ")"
            )
          modifyIORef' failures (+ 1)

main :: IO ()
main = do
  failures <- newIORef (0 :: Int)
  let d = defaultExecSettings

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
    case out :: Either SomeException ((), [Event]) of
      Left e -> do
        TIO.putStrLn ("FAIL fail-over settles: threw " <> T.pack (show e))
        modifyIORef' failures (+ 1)
      Right (_, tr)
        | billFresh tr == 2 && billMemo tr == 2 ->
            TIO.putStrLn "ok   fail-over settles on the spare (2/2)"
        | otherwise -> do
            TIO.putStrLn
              ( "FAIL fail-over settles: bills ("
                  <> T.pack (show (billFresh tr))
                  <> ","
                  <> T.pack (show (billMemo tr))
                  <> ") wanted (2,2)"
              )
            modifyIORef' failures (+ 1)
    case out of
      Right (_, tr)
        | take 1 (answerers tr) == [Just "broad"] ->
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
    case out :: Either SomeException ((), [Event]) of
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
    (runningProgram "true" []) (\tr -> billFresh tr == 2 && billMemo tr == 2)
  execProbe failures "…and one that exits nonzero answers no (1/1)"
    (runningProgram "false" []) (\tr -> billFresh tr == 1 && billMemo tr == 1)
  -- The most important D5 assertion: two commands at one tool id, saying the
  -- same words, are two questions. Were the argv anywhere outside the
  -- addressee the second would be answered from the memo table without running.
  execProbe failures "two commands at one tool are two questions (2/2)"
    twoCommandsProgram (\tr -> billFresh tr == 2 && billMemo tr == 2)
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
    case out :: Either SomeException ((), Trace) of
      Left e
        | "did not run" `T.isInfixOf` T.pack (show e) ->
            TIO.putStrLn "ok   …and a command that cannot be run is named, not answered"
        | otherwise -> do
            TIO.putStrLn ("FAIL the missing command: " <> T.pack (show e))
            modifyIORef' failures (+ 1)
      Right _ -> do
        TIO.putStrLn "FAIL the missing command: the run completed"
        modifyIORef' failures (+ 1)

  -- Routing (Agentic.Route): the grammar an operator types, and the one rule
  -- that decides where a question goes. Pure — no process, no network — because
  -- routing is a function of a field the interpreter has already computed.
  pureProbe failures "parseBackend reads both schemes, splitting on the first colon"
    [ ("acp:stub", parseBackend "acp:stub" == Right (BackendAcp "stub")),
      ("acp:claude", parseBackend "acp:claude" == Right (BackendAcp "claude")),
      ("acp:codex", parseBackend "acp:codex" == Right (BackendAcp "codex")),
      ("acp:PATH", parseBackend "acp:/opt/bin/my-adapter" == Right (BackendAcp "/opt/bin/my-adapter")),
      ("deck:id", parseBackend "deck:gemini-pane" == Right (BackendDeck "gemini-pane")),
      -- The first colon and no other: a deck session's title may contain one,
      -- and a value split anywhere else would make it unnameable.
      ("deck:a:b", parseBackend "deck:notes: monday" == Right (BackendDeck "notes: monday")),
      ( "unknown scheme names both shapes",
        parseBackend "grpc:x"
          == Left
            "unknown backend 'grpc:x' in --route: a backend is acp:<adapter> \
            \(start an adapter of this run's own) or deck:<id> (send to a live \
            \agent-deck session)"
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
  pureProbe failures "parseRoute splits NAME=BACKEND on the first ="
    [ ("deep=acp:codex", parseRoute "deep=acp:codex" == Right ("deep", BackendAcp "codex")),
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
      [ ("the traces are equal event for event", map eventJson bare == map eventJson routed),
        ("billFresh", billFresh bare == billFresh routed),
        ("billMemo", billMemo bare == billMemo routed),
        -- And they are the flagship's own numbers, so the row cannot pass by
        -- finding two equally wrong runs.
        ("the flagship's bills", (billFresh routed, billMemo routed) == (7, 7)),
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
    case out :: Either SomeException ((), Trace) of
      Left e -> do
        TIO.putStrLn ("FAIL routing does not intercept toolExec: threw " <> T.pack (show e))
        modifyIORef' failures (+ 1)
      Right (_, tr) ->
        pureProbe failures "routing does not intercept toolExec"
          [ ("bills", billFresh tr == 3 && billMemo tr == 3),
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
    let settled = case out :: Either SomeException ((), Trace) of
          Right (_, tr) -> billFresh tr == 2 && billMemo tr == 2
          Left _ -> False
        namesBroad = case out of
          Right (_, tr) -> take 1 (answerers tr) == [Just "broad"]
          Left _ -> False
        abandons = case bare :: Either SomeException ((), Trace) of
          Left e -> "no readable flag from model r" `T.isInfixOf` T.pack (show e)
          Right _ -> False
    pureProbe failures "a fail-over crosses backends, and with no spare abandons as ever"
      [ ("settles on the spare's backend (2/2)", settled),
        ("the trace names the model that answered", namesBroad),
        ("the narration keeps its wording", any ("falling back to broad" `T.isInfixOf`) msgs),
        ("with no chain the same two backends abandon in the old words", abandons)
      ]

  n <- readIORef failures
  if n == 0
    then TIO.putStrLn "policy probe: all checks passed"
    else do
      TIO.putStrLn ("policy probe: " <> T.pack (show n) <> " failed")
      exitFailure
