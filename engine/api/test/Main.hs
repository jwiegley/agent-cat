{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Agentic.Engine
import Control.Exception (throwIO)

main :: IO ()
main = do
  let request =
        EngineRequest
          { engineTarget = "model reviewer",
            engineModelAxis = Just "deep",
            engineModeAxis = Nothing,
            engineDraw = 0,
            engineIntent = Consult,
            engineAnswerKind = TextAnswer,
            enginePrompt = "question",
            engineRequiresCompletedTurn = True
          }
      context = EngineContext {runEngineAttempt = \_ _ action -> action (const (pure ()))}
      fake = concurrentEngine (\received extra -> pure (EngineResult (enginePrompt received <> extra) "" Completed))
  conversation <- startEngine fake context request
  result <- runEngineTurn conversation "?"
  if engineAnswer result == "question?" && engineCompletion result == Completed
    then pure ()
    else throwIO (userError "engine API fake did not preserve request/response")
