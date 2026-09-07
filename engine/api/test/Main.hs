{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Agentic.Engine
import Control.Exception (throwIO)
import Data.IORef (modifyIORef', newIORef, readIORef)

-- | Test engine that emits answer bytes and optional public progress separately.
data UpdatingEngine = UpdatingEngine

instance Engine UpdatingEngine where
  startEngine UpdatingEngine context request =
    pure . EngineConversation $ \extra ->
      runEngineAttempt context Nothing (engineTarget request) $ \updates -> do
        updates (EngineAnswerChunk "answer chunk")
        updates (EnginePublicMessage "public status")
        updates (EngineToolProgress (EngineToolUpdate "tool-1" (Just "Read") (Just "read") (Just "completed") Nothing))
        updates (EngineTodoSnapshot [EngineTodoItem "Check result" "high" "completed"])
        updates (EngineUsageProgress (EngineUsage 10 100))
        updates (EnginePublicReasoningSummary "Public summary")
        pure (EngineResult (enginePrompt request <> extra) "" Completed)
  engineTurnLane _ = Nothing

main :: IO ()
main = do
  seen <- newIORef []
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
      context = EngineContext {runEngineAttempt = \_ _ action -> action (\update -> modifyIORef' seen (<> [update]))}
      quiet = concurrentEngine (\received extra -> pure (EngineResult (enginePrompt received <> extra) "" Completed))
  conversation <- startEngine UpdatingEngine context request
  result <- runEngineTurn conversation "?"
  updates <- readIORef seen
  quietConversation <- startEngine quiet context request
  quietResult <- runEngineTurn quietConversation "!"
  quietUpdates <- readIORef seen
  if engineAnswer result == "question?"
      && engineCompletion result == Completed
      && updates
        == [ EngineAnswerChunk "answer chunk",
             EnginePublicMessage "public status",
             EngineToolProgress (EngineToolUpdate "tool-1" (Just "Read") (Just "read") (Just "completed") Nothing),
             EngineTodoSnapshot [EngineTodoItem "Check result" "high" "completed"],
             EngineUsageProgress (EngineUsage 10 100),
             EnginePublicReasoningSummary "Public summary"
           ]
      && engineAnswer quietResult == "question!"
      && quietUpdates == updates
    then pure ()
    else throwIO (userError "engine API did not preserve answer/progress separation or quiet-engine omission")
