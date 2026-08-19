{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
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
    Q (qAddressee, qPrompt, qScope),
    QScope (scopeModelAxis),
    SCode (SAck, SFlag, SText, SVerdict),
    fromSCode,
    verdictApprove,
  )
import Agentic.Shell (ShellConfig (shellCwd), defaultShellConfig, executingWorld)
import Agentic.World (Event (Event), Trace, billFresh, billMemo)
import Control.Exception (ErrorCall, SomeException, evaluate, try)
import Data.IORef
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Example.Harden (hardenProgram)
import Agentic.Builder
  ( Code (CodeFlag),
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
  )
import qualified Data.Map.Strict as Map
import Agentic.Observe (printedValue)
import System.Exit (exitFailure)

import SurfaceRefusals
  ( callsAnUnlistedFunction,
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

  n <- readIORef failures
  if n == 0
    then TIO.putStrLn "policy probe: all checks passed"
    else do
      TIO.putStrLn ("policy probe: " <> T.pack (show n) <> " failed")
      exitFailure
