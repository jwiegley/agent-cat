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
--   * @esRecover = const FailOver@: refused by name, wave three's sentence;
--   * @esRetryUndecodable = 3@: four attempts before the abandonment.
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
import Agentic.World (billFresh, billMemo)
import Control.Exception (ErrorCall, SomeException, evaluate, try)
import Data.IORef
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Example.Harden (hardenProgram)
import Agentic.Builder (Program, progPlan)
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
  probe failures "FailOver refuses naming wave three"
    d {esRecover = const FailOver} (Left "fail-over")
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

  n <- readIORef failures
  if n == 0
    then TIO.putStrLn "policy probe: all checks passed"
    else do
      TIO.putStrLn ("policy probe: " <> T.pack (show n) <> " failed")
      exitFailure
