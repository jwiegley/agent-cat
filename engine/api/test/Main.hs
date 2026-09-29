{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Agentic.Engine
import Control.Exception (throwIO)
import Control.Monad (unless)
import Data.Aeson (Value (..))
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import Data.Either (isLeft)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import qualified Data.Text as T

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
  progressSeparation
  codecChecks

progressSeparation :: IO ()
progressSeparation = do
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

-- | Round trips through the JSON bytes, and refusals of values that each
-- version-1 codec does not define.
codecChecks :: IO ()
codecChecks = do
  let request = encodeEngineRequest (EngineRequest "model reviewer" (Just "deep") Nothing 0 Consult TextAnswer "question" True)
      result = encodeEngineResult (EngineResult "answer" "" Completed)
      steering = encodeEngineSteering NextBoundary "focus"
      permission = encodeEnginePermissionReport (EnginePermissionReport "question" "tool" EnginePermissionRefused)
      failures =
        concat
          [ roundTrips "request" encodeEngineRequest decodeEngineRequest requests,
            roundTrips "result" encodeEngineResult decodeEngineResult results,
            roundTrips "steering" (uncurry encodeEngineSteering) decodeEngineSteering steerings,
            roundTrips "permission" encodeEnginePermissionReport decodeEnginePermissionReport permissions,
            refusals "request" decodeEngineRequest request "target",
            refusals "result" decodeEngineResult result "answer",
            refusals "steering" decodeEngineSteering steering "text",
            refusals "permission" decodeEnginePermissionReport permission "tool",
            refused "request draw as a JSON number" decodeEngineRequest (withField "draw" (Number 7) request),
            concat
              [ refused ("request draw " <> show draw) decodeEngineRequest (withField "draw" (String draw) request)
                | draw <- ["01", "-0", "+1", " 1", "1 ", "", "1e3", "0x10"]
              ],
            refused "request with an unknown intent" decodeEngineRequest (withField "intent" (String "Effect") request),
            refused "request with a numeric axis" decodeEngineRequest (withField "modelAxis" (Number 1) request),
            refused "result with an unknown completion field" decodeEngineResult (withField "completion" (object' [("state", String "completed"), ("reason", String "")]) result),
            refused "result incomplete without a reason" decodeEngineResult (withField "completion" (object' [("state", String "incomplete")]) result),
            refused "steering with an unknown timing" decodeEngineSteering (withField "steering" (String "later") steering),
            refused "a refusal that names an option" decodeEnginePermissionReport (withField "answer" (object' [("outcome", String "refused"), ("option", String "allow")]) permission),
            refused "a grant without an option" decodeEnginePermissionReport (withField "answer" (object' [("outcome", String "granted")]) permission),
            refused "an array" decodeEngineResult (Array mempty)
          ]
  unless (null failures) $
    throwIO (userError ("engine API codec checks failed:\n" <> unlines failures))

roundTrips :: (Eq a, Show a) => String -> (a -> Value) -> (Value -> Either Text a) -> [a] -> [String]
roundTrips name encode decode values =
  [ name <> " did not round-trip: " <> show value <> " gave " <> show decoded
    | value <- values,
      let decoded = either (Left . T.pack) decode (Aeson.eitherDecode (Aeson.encode (encode value))),
      decoded /= Right value
  ]
    <> [name <> " round trips covered no value" | null values]

-- | The three negative controls that every codec must refuse.
refusals :: Show a => String -> (Value -> Either Text a) -> Value -> Key.Key -> [String]
refusals name decode encoded required =
  refused (name <> " with an unknown field") decode (withField "extra" Null encoded)
    <> refused (name <> " without field " <> show required) decode (withoutField required encoded)
    <> refused (name <> " at version 2") decode (withField "version" (Number 2) encoded)
    <> refused (name <> " without a version") decode (withoutField "version" encoded)
    <> [name <> " control value did not decode" | isLeft (decode encoded)]

refused :: Show a => String -> (Value -> Either Text a) -> Value -> [String]
refused name decode value = case decode value of
  Left _ -> []
  Right decoded -> [name <> " was accepted as " <> show decoded]

withField :: Key.Key -> Value -> Value -> Value
withField key new (Object fields) = Object (KeyMap.insert key new fields)
withField _ _ value = value

withoutField :: Key.Key -> Value -> Value
withoutField key (Object fields) = Object (KeyMap.delete key fields)
withoutField _ value = value

object' :: [(Key.Key, Value)] -> Value
object' = Object . KeyMap.fromList

unicode :: Text
unicode = "caf\233 \8212 \19990\30028 \128640 \\\"quoted\"\n\0"

requests :: [EngineRequest]
requests =
  [ EngineRequest
      { engineTarget = target,
        engineModelAxis = model,
        engineModeAxis = mode,
        engineDraw = draw,
        engineIntent = intent,
        engineAnswerKind = kind,
        enginePrompt = prompt,
        engineRequiresCompletedTurn = completed
      }
    | (index, intent, kind) <- zip3 [0 :: Int ..] (cycle [minBound .. maxBound]) [minBound .. maxBound],
      let target = if even index then "model reviewer" else "",
      let model = if index == 1 then Nothing else Just unicode,
      let mode = if index == 2 then Just "" else Nothing,
      let draw = [0, 2 ^ (64 :: Int) + 1, negate (2 ^ (70 :: Int)), 7, 18446744073709551616] !! index,
      let prompt = if index == 3 then "" else unicode,
      let completed = even index
  ]
    <> [ EngineRequest "tool say" Nothing Nothing 1 intent TextAnswer unicode False
         | intent <- [minBound .. maxBound]
       ]

results :: [EngineResult]
results =
  [ EngineResult unicode "" Completed,
    EngineResult "" unicode Unverified,
    EngineResult unicode unicode (Incomplete unicode),
    EngineResult "" "" (Incomplete "")
  ]

steerings :: [(EngineSteering, Text)]
steerings = [(InterruptNow, unicode), (NextBoundary, ""), (NextBoundary, unicode)]

permissions :: [EnginePermissionReport]
permissions =
  [ EnginePermissionReport "the ack question put to tool apply" "apply the patch" (EnginePermissionGranted "allow"),
    EnginePermissionReport unicode unicode EnginePermissionRefused,
    EnginePermissionReport "" "" (EnginePermissionGranted "")
  ]
