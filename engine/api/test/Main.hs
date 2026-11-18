{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Agentic.Engine
import Agentic.Engine.Decision
import Control.Exception (throwIO)
import Control.Monad (unless)
import Data.Aeson (Value (..))
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString.Lazy.Char8 as BL
import Data.Either (isLeft)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (zip4)
import Data.List.NonEmpty (NonEmpty ((:|)))
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
            engineRequiresCompletedTurn = True,
            engineDecision = Nothing
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
-- codec does not define. A request without a decision is version 1, byte for
-- byte as before the decision field existed, and a request with a decision is
-- version 2. Every other codec stays at version 1.
codecChecks :: IO ()
codecChecks = do
  let request = encodeEngineRequest (EngineRequest "model reviewer" (Just "deep") Nothing 0 Consult TextAnswer "question" True Nothing)
      decided = encodeEngineRequest (EngineRequest "model triage" Nothing Nothing 0 Consult StructuredAnswer "question" True (Just choice))
      decision = encodeEngineDecision choice
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
            refused "an array" decodeEngineResult (Array mempty),
            [ "request without a decision is not the version 1 bytes: " <> BL.unpack (Aeson.encode request)
              | Aeson.encode request /= BL.pack version1Request
            ],
            [ "request with a decision is not version 2: " <> BL.unpack (Aeson.encode decided)
              | versionField decided /= Just (Number 2)
            ],
            roundTrips "decision request" encodeEngineRequest decodeEngineRequest decisionRequests,
            roundTrips "decision" encodeEngineDecision decodeEngineDecision decisions,
            [ "decision request control value did not decode" | isLeft (decodeEngineRequest decided)],
            refused "version 2 request with a null decision" decodeEngineRequest (withField "decision" Null decided),
            refused "version 2 request without a decision" decodeEngineRequest (withoutField "decision" decided),
            refused "version 2 request with an unknown field" decodeEngineRequest (withField "extra" Null decided),
            refused "version 1 request with a decision" decodeEngineRequest (withField "version" (Number 1) decided),
            refused "request at version 3 with a decision" decodeEngineRequest (withField "version" (Number 3) decided),
            refused "version 2 request with an invalid decision" decodeEngineRequest (withField "decision" (String "choice") decided),
            refused "result at version 2 with a decision" decodeEngineResult (withField "decision" decision (withField "version" (Number 2) result)),
            refused "steering at version 2 with a decision" decodeEngineSteering (withField "decision" decision (withField "version" (Number 2) steering)),
            refused "permission at version 2 with a decision" decodeEnginePermissionReport (withField "decision" decision (withField "version" (Number 2) permission)),
            [ "decision control value did not decode" | isLeft (decodeEngineDecision decision)],
            refused "decision with an unknown field" decodeEngineDecision (withField "extra" Null decision),
            refused "decision without evidence" decodeEngineDecision (withoutField "evidence" decision),
            refused "decision with an unknown form" decodeEngineDecision (withField "form" (String "yesNo") decision),
            refused "decision with no options" decodeEngineDecision (withOptions [] decision),
            refused "decision with two options of one name" decodeEngineDecision (withOptions [optionValue "Billing" Null, optionValue "Billing" Null] decision),
            refused "decision with an empty option name" decodeEngineDecision (withOptions [optionValue "" Null, optionValue "Billing" Null] decision),
            refused "decision option with an unknown field" decodeEngineDecision (withOptions [withField "rank" Null (optionValue "Billing" Null), optionValue "Other" Null] decision),
            refused "decision option with a numeric description" decodeEngineDecision (withOptions [optionValue "Billing" (Number 1), optionValue "Other" Null] decision),
            refused "decision option without a description" decodeEngineDecision (withOptions [withoutField "description" (optionValue "Billing" Null), optionValue "Other" Null] decision),
            concat
              [ refused ("yes-no decision with options " <> show names) decodeEngineDecision (withField "form" (String "yes-no") (withOptions [optionValue name Null | name <- names] decision))
                | names <- [["True", "False"], ["False"], ["False", "True", "True"], ["False", "True", "Unsure"], ["No", "Yes"], ["false", "true"]]
              ],
            [ "yes-no control value did not decode"
              | isLeft (decodeEngineDecision (withField "form" (String "yes-no") (withOptions [optionValue name Null | name <- ["False", "True"]] decision)))
            ]
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

withOptions :: [Value] -> Value -> Value
withOptions = withField "options" . Array . foldMap pure

optionValue :: Text -> Value -> Value
optionValue name description = object' [("name", String name), ("description", description)]

versionField :: Value -> Maybe Value
versionField (Object fields) = KeyMap.lookup "version" fields
versionField _ = Nothing

-- | The bytes that the request codec wrote for this request before
-- 'engineDecision' existed.
version1Request :: String
version1Request =
  "{\"answerKind\":\"text\",\"draw\":\"0\",\"intent\":\"consult\",\"modeAxis\":null,\"modelAxis\":\"deep\",\"prompt\":\"question\",\"requiresCompletedTurn\":true,\"target\":\"model reviewer\",\"version\":1}"

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
        engineRequiresCompletedTurn = completed,
        engineDecision = Nothing
      }
    | (index, intent, kind) <- zip3 [0 :: Int ..] (cycle [minBound .. maxBound]) [minBound .. maxBound],
      let target = if even index then "model reviewer" else "",
      let model = if index == 1 then Nothing else Just unicode,
      let mode = if index == 2 then Just "" else Nothing,
      let draw = [0, 2 ^ (64 :: Int) + 1, negate (2 ^ (70 :: Int)), 7, 18446744073709551616] !! index,
      let prompt = if index == 3 then "" else unicode,
      let completed = even index
  ]
    <> [ EngineRequest "tool say" Nothing Nothing 1 intent TextAnswer unicode False Nothing
         | intent <- [minBound .. maxBound]
       ]

decisionRequests :: [EngineRequest]
decisionRequests =
  [ EngineRequest "model triage" model Nothing draw Consult StructuredAnswer unicode completed (Just decision)
    | (decision, model, draw, completed) <- zip4 decisions [Nothing, Just unicode, Just ""] [0, 2 ^ (64 :: Int) + 1, -3] [True, False, True]
  ]

choice :: EngineDecision
choice =
  EngineDecision
    EngineChoice
    "Which team owns this ticket?"
    (EngineOption "Billing" (Just "Charges, refunds and invoices.") :| [EngineOption "Shipping" Nothing, EngineOption "Other" (Just "")])
    "The parcel arrived broken."

decisions :: [EngineDecision]
decisions =
  [ choice,
    EngineDecision EngineYesNo unicode (EngineOption "False" Nothing :| [EngineOption "True" (Just unicode)]) "",
    EngineDecision EngineScale "" (EngineOption "Low" (Just "Can wait.") :| [EngineOption "Medium" Nothing, EngineOption unicode (Just "Now.")]) unicode
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
