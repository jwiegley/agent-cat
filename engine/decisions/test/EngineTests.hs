{-# LANGUAGE OverloadedStrings #-}

-- | Checks of the engine against an in-process HTTP stub on the loopback
-- interface. Law L13, which reads an accepted answer at the decision's
-- schema, needs the DSL, so @decision-probe@ checks it.
module EngineTests (engineTests) where

import Agentic.Decisions
import Agentic.Engine
import Agentic.Engine.Decision
import Control.Concurrent (threadDelay)
import Control.Exception (try)
import Data.Aeson (Value (..))
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import qualified Data.CaseInsensitive as CI
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import GHC.Clock (getMonotonicTimeNSec)
import Network.HTTP.Types (Status, mkStatus, status200, status302)
import Network.Wai (Application, Request, pathInfo, requestHeaders, responseLBS, strictRequestBody)
import Network.Wai.Handler.Warp (testWithApplication)
import WireTests (choiceDecision, fixture, yesNoDecision)

-- | One request as the stub received it: its path, headers and body.
data Seen = Seen ![Text] ![(Text, Text)] !BL.ByteString

engineTests :: IO [String]
engineTests = do
  seen <- newIORef []
  (failures, closedPort) <- testWithApplication (pure (stub seen)) $ \port -> do
    results <- traverse (\scenario -> scenario port seen) scenarios
    pure (concat results, port)
  refused <- connectionRefused closedPort
  pure (failures <> refused)

-- ---------------------------------------------------------------------------
-- The stub
-- ---------------------------------------------------------------------------

-- | Answers by path: @ok/<fixture>@ returns a fixture, @slow@ waits three
-- seconds, @status/<n>@ returns status @n@, @big@ returns 64 KiB, @redirect@
-- redirects to a fixture, and @malformed@ returns text that is not JSON.
-- @status/echo@ answers HTTP 400 with an error message that repeats the
-- credential it received, and @ok-echo@ answers a fixture whose model and id
-- repeat it, as a vendor that echoes its input would.
stub :: IORef [Seen] -> Application
stub seen request respond = do
  body <- strictRequestBody request
  atomicModifyIORef' seen (\previous -> (previous <> [Seen (pathInfo request) (headersOf request) body], ()))
  case pathInfo request of
    ["ok", name] -> fixture (T.unpack name) >>= respond . json status200 . BL.fromStrict
    ["slow"] -> threadDelay 3000000 >> fixture "jev-choice.json" >>= respond . json status200 . BL.fromStrict
    ["status", "402-in-flight"] -> fixture "error-402-in-flight.json" >>= respond . json (code 402) . BL.fromStrict
    ["status", "402-credits"] -> fixture "error-402-credits.json" >>= respond . json (code 402) . BL.fromStrict
    ["status", "echo"] ->
      respond (json (code 400) (Aeson.encode (Aeson.object ["error" Aeson..= Aeson.object ["code" Aeson..= (400 :: Int), "message" Aeson..= ("the key " <> credential <> " is not valid")]])))
    ["ok-echo"] -> do
      bytes <- fixture "jev-choice.json"
      respond . json status200 . Aeson.encode $ case Aeson.decodeStrict bytes of
        Just (Object fields) -> Object (KeyMap.insert "model" (String credential) (KeyMap.insert "id" (String ("gen-" <> credential)) fields))
        _ -> Null
    ["status", n] -> respond (json (code (read (T.unpack n))) "{\"error\":{\"code\":0,\"message\":\"stub\"}}")
    ["big"] -> respond (json status200 (BL.fromStrict (BS.replicate 65536 32)))
    ["redirect"] -> respond (responseLBS status302 [("Location", "/ok/jev-choice.json")] "")
    ["malformed"] -> respond (json status200 "{\"answers\":")
    _ -> respond (json (code 404) "{}")
  where
    credential = maybe "" (\value -> fromMaybe value (T.stripPrefix "Bearer " value)) (lookup "authorization" (headersOf request))
    json status = responseLBS status [("Content-Type", "application/json")]
    code :: Int -> Status
    code n = mkStatus n "stub"

headersOf :: Request -> [(Text, Text)]
headersOf request = [(TE.decodeUtf8 (CI.foldedCase name), TE.decodeUtf8 value) | (name, value) <- requestHeaders request]

-- ---------------------------------------------------------------------------
-- Scenarios
-- ---------------------------------------------------------------------------

type Scenario = Int -> IORef [Seen] -> IO [String]

scenarios :: [Scenario]
scenarios =
  [ answered,
    answeredOpenAI,
    timedOut,
    statuses,
    overBound,
    misrouted,
    refusedBeforeSending,
    redirectRefused,
    malformed,
    echoedSecret
  ]

endpointAt :: Int -> Dialect -> Text -> DecisionsEndpoint
endpointAt port dialect path =
  DecisionsEndpoint
    { endpointDialect = dialect,
      endpointUrl = "http://127.0.0.1:" <> T.pack (show port) <> "/" <> path,
      endpointHeaders = [("Authorization", "Bearer test-secret")],
      endpointSecrets = ["test-secret"],
      endpointTimeoutMs = 2000,
      endpointMaxBytes = 1048576,
      endpointLimits = defaultLimits
    }

jev :: Maybe Text -> Either Text DecisionsModel
jev (Just "triage") = Right (DecisionsModel "typesafe/jev-1.14" (Map.fromList [("provider", Aeson.object ["order" Aeson..= ["TypeSafe" :: Text]])]))
jev axis = Left ("no model for the axis " <> T.pack (show axis))

requestFor :: Maybe EngineDecision -> EngineRequest
requestFor decision =
  EngineRequest
    { engineTarget = "model triage",
      engineModelAxis = Just "triage",
      engineModeAxis = Nothing,
      engineDraw = 0,
      engineIntent = Consult,
      engineAnswerKind = StructuredAnswer,
      enginePrompt = "the prompt in words",
      engineRequiresCompletedTurn = True,
      engineDecision = decision
    }

-- | One turn through a fresh engine, with the number of requests that the
-- stub received during it.
turn :: IORef [Seen] -> DecisionsEndpoint -> (Maybe Text -> Either Text DecisionsModel) -> EngineRequest -> IO (Either EngineError EngineResult, [Seen])
turn seen endpoint select request = do
  before <- length <$> readIORef seen
  engine <- newDecisionsEngine endpoint select
  conversation <- startEngine engine context request
  outcome <- try (runEngineTurn conversation "re-ask text that this engine ignores")
  after <- readIORef seen
  pure (outcome, drop before after)
  where
    context = EngineContext {runEngineAttempt = \_ _ action -> action (\_ -> pure ())}

answered :: Scenario
answered port seen = do
  let endpoint = endpointAt port SystemOne "ok/jev-choice.json"
  engine <- newDecisionsEngine endpoint jev
  (outcome, requests) <- turn seen endpoint jev (requestFor (Just choiceDecision))
  let expectedBody =
        Aeson.object
          [ "model" Aeson..= ("typesafe/jev-1.14" :: Text),
            "state" Aeson..= engineDecisionEvidence choiceDecision,
            "provider" Aeson..= Aeson.object ["order" Aeson..= ["TypeSafe" :: Text]],
            "questions"
              Aeson..= Aeson.object
                [ "decision"
                    Aeson..= Aeson.object
                      [ "type" Aeson..= ("choice" :: Text),
                        "instructions" Aeson..= engineDecisionInstructions choiceDecision,
                        "criteria" Aeson..= Aeson.object ["Billing" Aeson..= ("Payments, charges, and refunds" :: Text), "Technical" Aeson..= ("Bugs and outages" :: Text), "Other" Aeson..= Null]
                      ]
                ]
          ]
  pure $ case (outcome, requests) of
    (Right result, [Seen path headers body]) ->
      concat
        [ ["the answer was " <> show (engineAnswer result) | engineAnswer result /= "{\"Billing\":0.88,\"Technical\":0.11,\"Other\":0.01}"],
          ["the turn was not completed" | engineCompletion result /= Completed],
          ["the narration was " <> show (engineNarration result) | not ("decisions system-one: model typesafe/jev-1.14-20261014" `T.isPrefixOf` engineNarration result)],
          ["the path was " <> show path | path /= ["ok", "jev-choice.json"]],
          ["the credential header was not sent: " <> show headers | lookup "authorization" headers /= Just "Bearer test-secret"],
          ["the content type was not JSON: " <> show headers | lookup "content-type" headers /= Just "application/json"],
          ["the body was " <> show body | Aeson.decode body /= Just expectedBody],
          ["the redaction values were " <> show (enginePublicRedactionValues engine) | enginePublicRedactionValues engine /= ["test-secret"]]
        ]
    (Left failure, _) -> ["a Jev choice was refused: " <> show failure]
    (_, other) -> ["a Jev choice sent " <> show (length other) <> " requests"]

answeredOpenAI :: Scenario
answeredOpenAI port seen = do
  (outcome, requests) <- turn seen (endpointAt port OpenAIDecisions "ok/openai-predicate.json") jev (requestFor (Just yesNoDecision))
  pure $ case (outcome, requests) of
    (Right result, [Seen _ _ body]) ->
      ["the predicate answer was " <> show (engineAnswer result) | engineAnswer result /= "{\"False\":0.75,\"True\":0.25}"]
        <> ["the OpenAI body did not carry the evidence as input: " <> show body | inputOf body /= Just (String (engineDecisionEvidence yesNoDecision))]
    (Left failure, _) -> ["an OpenAI predicate was refused: " <> show failure]
    (_, other) -> ["an OpenAI predicate sent " <> show (length other) <> " requests"]
  where
    inputOf body = case Aeson.decode body of
      Just (Object fields) -> KeyMap.lookup "input" fields
      _ -> Nothing

timedOut :: Scenario
timedOut port seen = do
  start <- getMonotonicTimeNSec
  (outcome, _) <- turn seen ((endpointAt port SystemOne "slow") {endpointTimeoutMs = 300}) jev (requestFor (Just choiceDecision))
  end <- getMonotonicTimeNSec
  let elapsedMs = fromIntegral (end - start) `div` (1000000 :: Integer)
  pure $
    failureOf "a timed-out request" TransportFailure "did not answer within 300 ms" outcome
      <> ["the timeout took " <> show elapsedMs <> " ms" | elapsedMs > 2500]

statuses :: Scenario
statuses port seen = concat <$> traverse check cases
  where
    cases =
      [ ("status/429", TransportFailure, "HTTP 429"),
        ("status/529", TransportFailure, "HTTP 529"),
        ("status/503", TransportFailure, "HTTP 503"),
        ("status/402-in-flight", TransportFailure, "HTTP 402: Too many requests are in flight for this budget"),
        ("status/402-credits", ProtocolFailure, "HTTP 402: Insufficient credits"),
        ("status/400", ProtocolFailure, "HTTP 400: stub"),
        ("status/401", ProtocolFailure, "HTTP 401")
      ]
    check (path, kind, evidence) = do
      (outcome, _) <- turn seen (endpointAt port SystemOne path) jev (requestFor (Just choiceDecision))
      pure (failureOf (T.unpack path) kind evidence outcome)

overBound :: Scenario
overBound port seen = do
  (outcome, _) <- turn seen ((endpointAt port SystemOne "big") {endpointMaxBytes = 1024}) jev (requestFor (Just choiceDecision))
  pure (failureOf "a body over the bound" ProtocolFailure "the response exceeds 1024 bytes" outcome)

-- | A request that a decisions engine cannot answer is refused, and the stub
-- receives nothing.
misrouted :: Scenario
misrouted port seen = do
  let endpoint = endpointAt port SystemOne "ok/jev-choice.json"
  (plain, sentPlain) <- turn seen endpoint jev (requestFor Nothing)
  (text, sentText) <- turn seen endpoint jev ((requestFor (Just choiceDecision)) {engineAnswerKind = TextAnswer})
  pure $
    failureOf "a request without a decision" ProtocolFailure "a decisions engine answers decision questions only" plain
      <> failureOf "a decision asked as text" ProtocolFailure "a decisions engine answers decision questions only" text
      <> ["a misrouted request reached the endpoint" | not (null sentPlain && null sentText)]

-- | The model selection, the limits and the reserved option keys are checked
-- before anything is sent.
refusedBeforeSending :: Scenario
refusedBeforeSending port seen = do
  let endpoint = endpointAt port SystemOne "ok/jev-choice.json"
  (noModel, sent1) <- turn seen endpoint jev ((requestFor (Just choiceDecision)) {engineModelAxis = Just "unknown"})
  (overLimit, sent2) <- turn seen (endpoint {endpointLimits = Limits 2 10}) jev (requestFor (Just choiceDecision))
  (reserved, sent3) <- turn seen endpoint (const (Right (DecisionsModel "m" (Map.fromList [("state", String "replaced")])))) (requestFor (Just choiceDecision))
  pure $
    failureOf "an unselectable model" ProtocolFailure "a decisions engine cannot select a model" noModel
      <> failureOf "a choice over the limit" ProtocolFailure "exceeds this endpoint's limit of 2" overLimit
      <> failureOf "a reserved model option" ProtocolFailure "the model option 'state' is written by the engine itself" reserved
      <> ["a request refused before sending reached the endpoint" | not (null sent1 && null sent2 && null sent3)]

redirectRefused :: Scenario
redirectRefused port seen = do
  (outcome, requests) <- turn seen (endpointAt port SystemOne "redirect") jev (requestFor (Just choiceDecision))
  pure $
    failureOf "a redirect" ProtocolFailure "HTTP 302" outcome
      <> ["the redirect was followed" | length requests /= 1]

malformed :: Scenario
malformed port seen = do
  (outcome, _) <- turn seen (endpointAt port SystemOne "malformed") jev (requestFor (Just choiceDecision))
  pure (failureOf "a malformed body" ProtocolFailure "the response is not one JSON value" outcome)

-- | A vendor that repeats the credential in its error message or in its
-- narration fields shows it nowhere: the failure text and the narration carry
-- the redaction in its place.
echoedSecret :: Scenario
echoedSecret port seen = do
  (failed, _) <- turn seen (endpointAt port SystemOne "status/echo") jev (requestFor (Just choiceDecision))
  (answered', _) <- turn seen (endpointAt port SystemOne "ok-echo") jev (requestFor (Just choiceDecision))
  pure $
    failureOf "an error that echoes the credential" ProtocolFailure "HTTP 400: the key <redacted> is not valid" failed
      <> case answered' of
        Right result ->
          ["a narration that echoes the credential showed the secret: " <> T.unpack (engineNarration result) | "test-secret" `T.isInfixOf` engineNarration result]
            <> ["a narration that echoes the credential was " <> T.unpack (engineNarration result) | not ("model <redacted>" `T.isInfixOf` engineNarration result)]
        Left failure -> ["an answer whose narration echoes the credential was refused: " <> show failure]

-- | A port on which nothing listens any more refuses the connection, which is
-- a transport failure.
connectionRefused :: Int -> IO [String]
connectionRefused port = do
  seen <- newIORef []
  (outcome, _) <- turn seen (endpointAt port SystemOne "ok/jev-choice.json") jev (requestFor (Just choiceDecision))
  pure (failureOf "a refused connection" TransportFailure "the connection failed" outcome)

-- | The outcome is a failure of the given kind whose evidence contains the
-- given text, and neither its evidence nor its message shows the secret.
failureOf :: String -> EngineFailureKind -> Text -> Either EngineError EngineResult -> [String]
failureOf what kind evidence outcome = case outcome of
  Left failure ->
    concat
      [ [what <> " was a " <> show (engineFailureKind failure) <> ": " <> T.unpack (engineFailureEvidence failure) | engineFailureKind failure /= kind],
        [ what <> " was refused as '" <> T.unpack (engineFailureEvidence failure) <> "', expected '" <> T.unpack evidence <> "'"
          | not (evidence `T.isInfixOf` engineFailureEvidence failure)
        ],
        [ what <> " showed the secret"
          | any ("test-secret" `T.isInfixOf`) [engineFailureEvidence failure, engineFailureMessage failure]
        ]
      ]
  Right result -> [what <> " was answered: " <> show result]
