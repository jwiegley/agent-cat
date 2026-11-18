{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QualifiedDo #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RebindableSyntax #-}
{-# LANGUAGE TypeApplications #-}

module AmendmentProbe (check) where

import Agentic.Builder (progPlan)
import Agentic.DSL (Addressee (..))
import Agentic.Plan (ExecEvent (..), Q (..), Request (..))
import Agentic.Runtime (ExecSettings (..), defaultExecSettings, runPlanIO, scriptedWorldWith)
import Agentic.Workflow
import qualified Agentic.Workflow.Do as W
import qualified Control.Monad as M
import Data.String (fromString)
import qualified Data.Text as T
import Prelude

repair :: Fn '[ 'CodeText, 'CodeVerdict] 'CodeText
repair = function "amendment.repair"
  (takes @"candidate" Text . takes @"review" Verdict $ noParams)
  \candidate review -> W.do
    first <- ask (model "edit-one") [wf|step one {candidate}: {review}|]
    second <- ask (model "edit-two") [wf|step two {first}|]
    answer second

program :: Integer -> ProgramOf 'CodeText
program bound = defining [SomeFn repair] W.do
  seed <- ask (model "seed") [wf|seed|]
  result <- revising seed (atMost bound) \candidate -> W.do
    verdict <- ask (model "review") [wf|check {candidate}|]
    amendWith (call repair (arg candidate :> arg verdict :> noArgs))
  case result of
    Settled final -> W.do
      answer final
    Unsettled final -> W.do
      failure <- ask (model "unsettled") [wf|exhausted {final}|]
      answer failure

check :: IO ()
check = do
  let settings = defaultExecSettings {esLog = const (pure ())}
      replies verdict =
        [ ("seed", "initial"),
          ("check initial", "OBJECTION: fix"),
          ("check revised", verdict),
          ("step one", "first edit"),
          ("step two", "revised"),
          ("exhausted revised", "exhausted revised"),
          ("exhausted initial", "exhausted initial")
        ]
      run bound verdict = runPlanIO (scriptedWorldWith settings (replies verdict)) (progPlan (program bound))
      seen target events = [qPrompt q | ExecEvent _ request _ _ <- events, let q = reqQuestion request, qAddressee q == AddrModel target]
      expect message value = M.unless value (fail ("amendWith: " ++ message))
  (settled, trace) <- run 1 "APPROVE"
  expect "function result did not become the candidate" (settled == "revised")
  expect "function calls must execute in body order" (seen "edit-two" trace == ["step two first edit"])
  expect "candidate and verdict must reach the callee" $
    case seen "edit-one" trace of
      [prompt] -> "initial" `T.isInfixOf` prompt && "fix" `T.isInfixOf` prompt
      _ -> False
  expect "the amended candidate must be reviewed" (seen "review" trace == ["check initial", "check revised"])
  (exhausted, exhaustedTrace) <- run 1 "OBJECTION: remains"
  expect "exhaustion lost the last function result" (exhausted == "exhausted revised")
  expect "exhaustion exceeded the amendment bound" (length (seen "edit-one" exhaustedTrace) == 1)
  (zero, zeroTrace) <- run 0 "APPROVE"
  expect "zero bound must retain the original candidate" (zero == "exhausted initial")
  expect "zero bound must not call the amendment" (null (seen "edit-one" zeroTrace))
  putStrLn "amendWith: function data flow, settlement, exhaustion and zero bound verified"
