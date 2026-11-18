{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- | Checks of the engine against an in-process HTTP stub on the loopback
-- interface, and law L13: every answer that the engine accepts decodes at the
-- decision's schema, and its record holds the vendor's probabilities.
module EngineTests (engineTests) where

import Agentic.Decision (Options, Weights, options, weight)
import Agentic.Decisions
import Agentic.Decisions.Wire (WireAnswer (..), decodeResponse)
import Agentic.Engine
import Agentic.Engine.Decision
import Agentic.Schema.Json (decodeAs)
import Control.Concurrent (threadDelay)
import Control.Exception (try)
import Data.Aeson (Value (..))
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import qualified Data.CaseInsensitive as CI
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import qualified Data.Map.Strict as Map
import Data.Ratio ((%))
import Data.Scientific (Scientific, scientific)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Vector as V
import GHC.Clock (getMonotonicTimeNSec)
import GHC.Generics (Generic)
import Network.HTTP.Types (Status, mkStatus, status200, status302)
import Network.Wai (Application, Request, pathInfo, requestHeaders, responseLBS, strictRequestBody)
import Network.Wai.Handler.Warp (testWithApplication)
import Test.QuickCheck
import WireTests (choiceDecision, fixture, scaleDecision, yesNoDecision)

-- | The options of 'choiceDecision', in its order.
data Team = Billing | Technical | Other
  deriving (Eq, Ord, Show, Enum, Bounded, Generic)

-- | The levels of 'scaleDecision', in its order.
data Urgency = Routine | Soon | Urgent
  deriving (Eq, Ord, Show, Enum, Bounded, Generic)

-- | One request as the stub received it: its path, headers and body.
data Seen = Seen ![Text] ![(Text, Text)] !BL.ByteString

engineTests :: IO [String]
engineTests = do
  seen <- newIORef []
  (failures, closedPort) <- testWithApplication (pure (stub seen)) $ \port -> do
    results <- traverse (\scenario -> scenario port seen) scenarios
    pure (concat results, port)
  refused <- connectionRefused closedPort
  law <- answerLaw
  pure (failures <> refused <> law)

-- ---------------------------------------------------------------------------
-- The stub
-- ---------------------------------------------------------------------------

-- | Answers by path: @ok/<fixture>@ returns a fixture, @slow@ waits three
-- seconds, @status/<n>@ returns status @n@, @big@ returns 64 KiB, @redirect@
-- redirects to a fixture, and @malformed@ returns text that is not JSON.
stub :: IORef [Seen] -> Application
stub seen request respond = do
  body <- strictRequestBody request
  atomicModifyIORef' seen (\previous -> (previous <> [Seen (pathInfo request) (headersOf request) body], ()))
  case pathInfo request of
    ["ok", name] -> fixture (T.unpack name) >>= respond . json status200 . BL.fromStrict
    ["slow"] -> threadDelay 3000000 >> fixture "jev-choice.json" >>= respond . json status200 . BL.fromStrict
    ["status", "402-in-flight"] -> fixture "error-402-in-flight.json" >>= respond . json (code 402) . BL.fromStrict
    ["status", "402-credits"] -> fixture "error-402-credits.json" >>= respond . json (code 402) . BL.fromStrict
    ["status", n] -> respond (json (code (read (T.unpack n))) "{\"error\":{\"code\":0,\"message\":\"stub\"}}")
    ["big"] -> respond (json status200 (BL.fromStrict (BS.replicate 65536 32)))
    ["redirect"] -> respond (responseLBS status302 [("Location", "/ok/jev-choice.json")] "")
    ["malformed"] -> respond (json status200 "{\"answers\":")
    _ -> respond (json (code 404) "{}")
  where
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
    malformed
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

-- ---------------------------------------------------------------------------
-- L13
-- ---------------------------------------------------------------------------

-- | The record of an answer at the schema of the option type @t@, as the
-- runtime decodes it, read back as one weight per option.
weightsAt :: forall t. Options t => Text -> Maybe [Rational]
weightsAt json = (\answer -> map (weight answer) (options @t)) <$> decodeAs @(Weights t) json

-- | L13: for every accepted vendor answer A,
-- @decodeAs \@(Weights t) (wireAnswerJson A)@ is @Just w@, and @w@ holds the
-- vendor's probability at each option, 0 at an option the vendor left out,
-- and @(1 - p, p)@ for a yes/no probability @p@.
answerLaw :: IO [String]
answerLaw = do
  fixtures <- concat <$> traverse fixtureLaw lawFixtures
  result <- quickCheckWithResult stdArgs {maxSuccess = 2000, chatty = False} answerDecodes
  pure (fixtures <> ["L13 does not hold: " <> output result | not (isSuccess result)])

lawFixtures :: [(FilePath, Dialect, EngineDecision, Text -> Maybe [Rational], [Rational])]
lawFixtures =
  [ ("jev-choice.json", SystemOne, choiceDecision, weightsAt @Team, [88 % 100, 11 % 100, 1 % 100]),
    ("jev-score.json", SystemOne, scaleDecision, weightsAt @Urgency, [0, 79 % 100, 21 % 100]),
    ("jev-noul.json", SystemOne, yesNoDecision, weightsAt @Bool, [2 % 100, 98 % 100]),
    ("drex-v1.5-score-array-legend.json", SystemOne, scaleDecision, weightsAt @Urgency, [2489 % 10000, 166 % 1000, 5851 % 10000]),
    ("drex-max-score-object-legend.json", SystemOne, scaleDecision, weightsAt @Urgency, [1 % 10, 3 % 10, 6 % 10]),
    ("kev-score-object-legend.json", SystemOne, scaleDecision, weightsAt @Urgency, [0, 56 % 100, 44 % 100]),
    ("openai-choice.json", OpenAIDecisions, choiceDecision, weightsAt @Team, [9 % 10, 6 % 100, 4 % 100]),
    ("openai-score.json", OpenAIDecisions, scaleDecision, weightsAt @Urgency, [1 % 10, 7 % 10, 2 % 10]),
    ("openai-predicate.json", OpenAIDecisions, yesNoDecision, weightsAt @Bool, [3 % 4, 1 % 4])
  ]

fixtureLaw :: (FilePath, Dialect, EngineDecision, Text -> Maybe [Rational], [Rational]) -> IO [String]
fixtureLaw (name, dialect, decision, decode, expected) = do
  bytes <- fixture name
  pure $ case Aeson.decodeStrict bytes of
    Nothing -> [name <> " is not JSON"]
    Just value -> case decodeResponse dialect decision value of
      Left failure -> ["L13: " <> name <> " was refused: " <> show failure]
      Right answer
        | decode (wireAnswerJson answer) == Just expected -> []
        | otherwise -> ["L13: " <> name <> " decodes to " <> show (decode (wireAnswerJson answer)) <> ", expected " <> show expected]

-- | A vendor answer: its dialect, its form, and one probability per option,
-- with 'Nothing' for an option that the vendor leaves out.
data Vendor = Vendor !Dialect !EngineDecisionForm ![Maybe Scientific] ![Int]
  deriving (Show)

-- | A decimal in [0,1] with at most four digits after the point.
decimal :: Gen Scientific
decimal = do
  digits <- choose (0, 4)
  numerator' <- choose (0, 10 ^ digits)
  pure (scientific numerator' (negate digits))

vendor :: Gen Vendor
vendor = do
  dialect <- elements [minBound .. maxBound]
  form <- elements [minBound .. maxBound]
  probabilities <- case form of
    EngineYesNo -> (\p -> [Just p]) <$> decimal
    _ -> vectorOf 3 (frequency [(1, pure Nothing), (4, Just <$> decimal)]) `suchThat` any (maybe False (> 0))
  order <- shuffle [0 .. length probabilities - 1]
  pure (Vendor dialect form probabilities order)

answerDecodes :: Property
answerDecodes = forAll vendor $ \(Vendor dialect form probabilities order) ->
  let (decision, decode, names) = case form of
        EngineChoice -> (choiceDecision, weightsAt @Team, ["Billing", "Technical", "Other"])
        EngineScale -> (scaleDecision, weightsAt @Urgency, ["Routine", "Soon", "Urgent"])
        EngineYesNo -> (yesNoDecision, weightsAt @Bool, ["False", "True"])
      present = [(index, p) | index <- order, Just p <- [probabilities !! index]]
      expected = case (form, probabilities) of
        (EngineYesNo, [Just p]) -> [1 - toRational p, toRational p]
        _ -> map (maybe 0 toRational) probabilities
      response = vendorResponse dialect form names present
   in counterexample (show response) $ case decodeResponse dialect decision response of
        Left failure -> counterexample ("refused: " <> show failure) False
        Right answer -> counterexample (T.unpack (wireAnswerJson answer)) (decode (wireAnswerJson answer) === Just expected)

-- | The response that a vendor of the dialect returns for the given
-- probabilities, each paired with the index of its option.
vendorResponse :: Dialect -> EngineDecisionForm -> [Text] -> [(Int, Scientific)] -> Value
vendorResponse SystemOne form names present =
  Aeson.object ["answers" Aeson..= Aeson.object ["decision" Aeson..= answer]]
  where
    answer = case form of
      EngineYesNo -> Aeson.object ["type" Aeson..= ("noul" :: Text), "noul" Aeson..= Number (firstOf present)]
      EngineChoice -> Aeson.object ["type" Aeson..= ("choice" :: Text), "choice" Aeson..= ("Billing" :: Text), "probabilities" Aeson..= Aeson.object [Key.fromText (names !! index) Aeson..= Number p | (index, p) <- present]]
      EngineScale -> Aeson.object ["type" Aeson..= ("score" :: Text), "score" Aeson..= (1 :: Int), "probabilities" Aeson..= Aeson.object [Key.fromText (T.pack (show index)) Aeson..= Number p | (index, p) <- present]]
vendorResponse OpenAIDecisions form names present =
  Aeson.object ["answers" Aeson..= Array (V.singleton answer)]
  where
    answer = case form of
      EngineYesNo -> Aeson.object ["type" Aeson..= ("predicate" :: Text), "name" Aeson..= ("decision" :: Text), "probability" Aeson..= Number (firstOf present)]
      EngineChoice -> Aeson.object ["type" Aeson..= ("choice" :: Text), "name" Aeson..= ("decision" :: Text), "probabilities" Aeson..= [Aeson.object ["value" Aeson..= (names !! index), "probability" Aeson..= Number p] | (index, p) <- present]]
      EngineScale -> Aeson.object ["type" Aeson..= ("score" :: Text), "name" Aeson..= ("decision" :: Text), "probabilities" Aeson..= [Aeson.object ["value" Aeson..= index, "label" Aeson..= (names !! index), "probability" Aeson..= Number p] | (index, p) <- present]]

-- | The probability of a yes/no answer, which has exactly one.
firstOf :: [(Int, Scientific)] -> Scientific
firstOf ((_, p) : _) = p
firstOf [] = 0
