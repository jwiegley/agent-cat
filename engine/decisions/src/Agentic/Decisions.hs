{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- |
-- Module      : Agentic.Decisions
-- Description : An engine that answers decision questions through a decisions HTTP endpoint.
--
-- A decisions endpoint answers a decision question with a point of the
-- simplex Δ(O) over its options O. This module carries one such question per
-- request over HTTP and returns the answer as the number record of the answer
-- contract in "Agentic.Engine.Decision". It owns the connection, the timeout,
-- the bound on the response, and the classification of failures. The vendor
-- bodies belong to "Agentic.Decisions.Wire", and this module names no vendor
-- field.
--
-- A request that carries no decision, or that does not ask for a structured
-- answer, is refused before anything is sent, because a decisions endpoint
-- cannot answer it.
module Agentic.Decisions
  ( DecisionsEndpoint (..),
    DecisionsModel (..),
    DecisionsEngine,
    newDecisionsEngine,
    newDecisionsManager,

    -- * Re-exported wire vocabulary
    Dialect (..),
    dialectWord,
    dialectOfWord,
    Limits (..),
    defaultLimits,
    reservedBodyKeys,
  )
where

import Agentic.Decisions.Wire
  ( Dialect (..),
    Limits (..),
    WireAnswer (..),
    WireFailure (..),
    checkLimits,
    classifyStatus,
    decodeBody,
    decodeResponse,
    defaultLimits,
    dialectOfWord,
    dialectWord,
    encodeRequest,
    reservedBodyKeys,
  )
import Agentic.Engine
  ( Engine (..),
    EngineAnswerKind (StructuredAnswer),
    EngineCompletion (Completed),
    EngineContext (..),
    EngineConversation (..),
    EngineError (..),
    EngineFailureKind (..),
    EngineRequest (..),
    EngineResult (..),
  )
import Control.Exception (IOException, displayException, throwIO, try)
import qualified Data.Aeson as Aeson
import Data.Aeson.Encoding (encodingToLazyByteString)
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import qualified Data.CaseInsensitive as CI
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import Network.HTTP.Client
  ( BodyReader,
    HttpException (..),
    HttpExceptionContent (..),
    Manager,
    RequestBody (RequestBodyLBS),
    brRead,
    checkResponse,
    defaultManagerSettings,
    method,
    newManager,
    parseRequest,
    redirectCount,
    requestBody,
    requestHeaders,
    responseBody,
    responseStatus,
    responseTimeout,
    responseTimeoutMicro,
    withResponse,
  )
import Network.HTTP.Client.TLS (newTlsManager)
import Network.HTTP.Types.Status (statusCode)
import System.Timeout (timeout)

-- | One decisions endpoint. Denotes a function from a model identifier, its
-- realization options and a decision to either a failure or a point of the
-- cone C(O), reached at 'endpointUrl' in 'endpointDialect'. The other fields
-- bound how long a request may take and how large a response may be, and
-- which option sets the endpoint accepts.
--
-- No 'Show' instance exists, because 'endpointHeaders' holds the resolved
-- credential.
data DecisionsEndpoint = DecisionsEndpoint
  { endpointDialect :: !Dialect,
    endpointUrl :: !Text,
    -- | Every header sent with a request, the resolved authentication header
    -- included.
    endpointHeaders :: ![(Text, Text)],
    -- | The exact secret values in 'endpointHeaders', which no public update
    -- may show.
    endpointSecrets :: ![Text],
    endpointTimeoutMs :: !Int,
    endpointMaxBytes :: !Int,
    endpointLimits :: !Limits
  }

-- | The model that a request names. Denotes a point of the endpoint's model
-- set: the identifier sent as the model, and the realization options merged
-- into the body.
data DecisionsModel = DecisionsModel
  { decisionsModelId :: !Text,
    decisionsModelOptions :: !(Map Text Aeson.Value)
  }
  deriving (Eq, Show)

-- | An endpoint, its model selection, and the connection manager that serves
-- it. Denotes the endpoint's function on decisions, with the model chosen
-- from a request's model axis.
data DecisionsEngine = DecisionsEngine
  { engineEndpoint :: !DecisionsEndpoint,
    engineSelectModel :: Maybe Text -> Either Text DecisionsModel,
    engineManager :: !Manager
  }

-- | An engine for one endpoint. The selector maps a request's model axis to
-- the model to name, or to the reason that none applies.
newDecisionsEngine :: DecisionsEndpoint -> (Maybe Text -> Either Text DecisionsModel) -> IO DecisionsEngine
newDecisionsEngine endpoint select = DecisionsEngine endpoint select <$> newDecisionsManager (endpointUrl endpoint)

-- | The connection manager for a URL. This is the one place where TLS trust
-- is chosen: an @https@ URL gets the TLS manager of @http-client-tls@, which
-- trusts the certificate store that the library selects, and every other URL
-- gets a manager with no TLS.
newDecisionsManager :: Text -> IO Manager
newDecisionsManager url
  | "https://" `T.isPrefixOf` T.toLower url = newTlsManager
  | otherwise = newManager defaultManagerSettings

instance Engine DecisionsEngine where
  -- A re-ask appends text to a prompt that this engine does not send, so the
  -- re-ask text is ignored and the same decision is asked again.
  startEngine engine context request =
    pure . EngineConversation $ \_extra ->
      runEngineAttempt context Nothing (engineTarget request) $ \_ -> decisionsTurn engine request
  engineTurnLane _ = Nothing
  enginePublicRedactionValues = endpointSecrets . engineEndpoint

-- | One turn: one decision question, one HTTP request, one answer.
--
-- 1. A request without a decision, or for an answer that is not structured,
--    is refused.
-- 2. The model is selected from the model axis.
-- 3. The decision is checked against the endpoint's limits, and the model's
--    options against the reserved body keys.
-- 4. The body is sent with redirects off, under the timeout, and the response
--    is read up to the byte bound.
-- 5. A connection failure or a timeout is a transport failure.
-- 6. The status is classified.
-- 7. The body is decoded, and every secret of the endpoint is removed from
--    each string and each key of the decoded body, so that no vendor text
--    that reaches a failure or the narration shows a credential.
-- 8. The record is returned as a completed answer.
--
-- Steps 1 to 3 send nothing.
decisionsTurn :: DecisionsEngine -> EngineRequest -> IO EngineResult
decisionsTurn engine request = do
  decision <- case (engineDecision request, engineAnswerKind request) of
    (Just decision, StructuredAnswer) -> pure decision
    _ -> refuse ProtocolFailure "a decisions engine answers decision questions only"
  model <- either (refuse ProtocolFailure . ("a decisions engine cannot select a model: " <>)) pure (engineSelectModel engine (engineModelAxis request))
  either (refuse ProtocolFailure) pure (checkLimits (endpointLimits endpoint) decision)
  case filter (`Map.member` decisionsModelOptions model) (reservedBodyKeys dialect) of
    reserved : _ -> refuse ProtocolFailure ("the model option '" <> reserved <> "' is written by the engine itself")
    [] -> pure ()
  let body = encodingToLazyByteString (encodeRequest dialect (decisionsModelId model) (decisionsModelOptions model) decision)
  outcome <- exchange body
  (status, bytes) <- either (uncurry refuse) pure outcome
  let decoded = fmap (redactSecrets (endpointSecrets endpoint)) . decodeBody <$> bytes
  case classifyStatus status (either (const Nothing) Just =<< decoded) of
    Just failure -> wire failure
    Nothing -> do
      value <- maybe (refuse ProtocolFailure ("the response exceeds " <> showText (endpointMaxBytes endpoint) <> " bytes")) pure decoded
      answer <- either wire pure (value >>= decodeResponse dialect decision)
      pure (EngineResult (wireAnswerJson answer) (wireNarration answer) Completed)
  where
    endpoint = engineEndpoint engine
    dialect = endpointDialect endpoint
    target = engineTarget request
    refuse :: EngineFailureKind -> Text -> IO a
    refuse kind reason =
      throwIO
        EngineError
          { engineFailureKind = kind,
            engineFailureEvidence = "decisions " <> dialectWord dialect <> ": " <> reason,
            engineFailureMessage = "the decisions engine could not answer " <> target <> ": " <> reason
          }
    wire = \case
      WireTransport reason -> refuse TransportFailure reason
      WireProtocol reason -> refuse ProtocolFailure reason
    micro = endpointTimeoutMs endpoint * 1000
    timedOut = "the endpoint did not answer within " <> showText (endpointTimeoutMs endpoint) <> " ms"
    -- The status and the body, with Nothing in place of a body over the
    -- bound, or the failure that prevented an exchange.
    exchange :: BL.ByteString -> IO (Either (EngineFailureKind, Text) (Int, Maybe BS.ByteString))
    exchange body = do
      parsed <- try (parseRequest (T.unpack (endpointUrl endpoint)))
      case parsed of
        Left (_ :: HttpException) -> pure (Left (ProtocolFailure, "the endpoint URL does not parse"))
        Right base -> do
          let headers = [(CI.mk (encodeUtf8 name), encodeUtf8 value) | (name, value) <- endpointHeaders endpoint]
              contentType = [("Content-Type", "application/json") | all ((/= "content-type") . CI.foldedCase . fst) headers]
              http =
                base
                  { method = "POST",
                    requestHeaders = contentType <> headers,
                    requestBody = RequestBodyLBS body,
                    redirectCount = 0,
                    responseTimeout = responseTimeoutMicro micro,
                    checkResponse = \_ _ -> pure ()
                  }
              receive response =
                (,) (statusCode (responseStatus response))
                  <$> readBounded (endpointMaxBytes endpoint) (responseBody response)
          result <- timeout micro (try (try (withResponse http (engineManager engine) receive)))
          pure $ case result of
            Nothing -> Left (TransportFailure, timedOut)
            Just (Left (failure :: HttpException)) -> Left (httpFailure failure)
            Just (Right (Left (failure :: IOException))) -> Left (TransportFailure, "the connection failed: " <> T.pack (displayException failure))
            Just (Right (Right exchanged)) -> Right exchanged
    -- The text of a failure names its cause and never shows the request,
    -- whose headers hold the credential.
    httpFailure = \case
      InvalidUrlException _ _ -> (ProtocolFailure, "the endpoint URL does not parse")
      HttpExceptionRequest _ content -> case content of
        ResponseTimeout -> (TransportFailure, timedOut)
        ConnectionTimeout -> (TransportFailure, "the connection timed out")
        ConnectionFailure cause -> (TransportFailure, "the connection failed: " <> T.pack (displayException cause))
        ConnectionClosed -> (TransportFailure, "the connection closed")
        NoResponseDataReceived -> (TransportFailure, "the endpoint closed the connection without a response")
        IncompleteHeaders -> (TransportFailure, "the endpoint closed the connection inside the headers")
        ResponseBodyTooShort _ _ -> (TransportFailure, "the endpoint closed the connection inside the body")
        InternalException cause -> (TransportFailure, "the connection failed: " <> T.pack (displayException cause))
        ProxyConnectException _ _ _ -> (TransportFailure, "the proxy connection failed")
        other -> (ProtocolFailure, "the HTTP exchange failed: " <> T.pack (takeWhile (/= ' ') (show other)))

-- | @redactSecrets secrets v@ is @v@ with every occurrence of every non-empty
-- secret replaced by @<redacted>@ in each string and in each object key, at
-- every depth. Numbers, booleans and nulls are unchanged, so the
-- probabilities that a body carries are read as the vendor sent them.
redactSecrets :: [Text] -> Aeson.Value -> Aeson.Value
redactSecrets secrets
  | null present = id
  | otherwise = go
  where
    present = filter (not . T.null) secrets
    go = \case
      Aeson.String text -> Aeson.String (redact text)
      Aeson.Array items -> Aeson.Array (fmap go items)
      Aeson.Object fields -> Aeson.Object (KeyMap.fromList [(Key.fromText (redact (Key.toText key)), go value) | (key, value) <- KeyMap.toList fields])
      other -> other
    redact text = foldl' (\acc secret -> T.replace secret "<redacted>" acc) text present

-- | Reads a body up to a bound. 'Nothing' means the body exceeds the bound,
-- and reading stops at the first chunk that crosses it.
readBounded :: Int -> BodyReader -> IO (Maybe BS.ByteString)
readBounded limit reader = go 0 []
  where
    go total chunks = do
      chunk <- brRead reader
      if BS.null chunk
        then pure (Just (BS.concat (reverse chunks)))
        else
          let total' = total + BS.length chunk
           in if total' > limit then pure Nothing else go total' (chunk : chunks)

showText :: Show a => a -> Text
showText = T.pack . show
