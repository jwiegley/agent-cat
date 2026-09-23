{-# LANGUAGE OverloadedStrings #-}

-- | HTTP representations and commands of one existing manager service.
module Agentic.Manager.Application (newApplication) where

import qualified Agentic.Manager.Approval as Approval
import qualified Agentic.Manager.Authorization as Auth
import qualified Agentic.Manager.Commands as Commands
import Agentic.Manager.Configuration (HttpsConfiguration)
import qualified Agentic.Manager.Drafts as Drafts
import qualified Agentic.Manager.Events as Events
import qualified Agentic.Manager.Observation as Observation
import qualified Agentic.Manager.Pages as Pages
import Agentic.Manager.Profile (ConfigurationLimits (..), publicId, discoveryPublicWorkflows)
import Agentic.Manager.Schema (schemaVersion)
import qualified Agentic.Runtime as Runtime
import qualified Agentic.Manager.Protocol.Command as C
import qualified Agentic.Manager.Protocol.Draft as D
import Agentic.Manager.Protocol.Json (decodeStrictValue)
import qualified Agentic.Manager.Protocol.Preparation as P
import qualified Agentic.Manager.Service as Service
import qualified Agentic.Manager.State as State
import qualified Agentic.Manager.Store as Store
import qualified Agentic.Manager.Transport as Transport
import Control.Exception (throwIO)
import Control.Monad (forM_, unless, when)
import Crypto.Hash (Digest, SHA256, hash)
import Data.Aeson (Value (..), object, toJSON, (.=))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson.Types (Pair)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Builder as Builder
import Data.List (nub)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Word (Word8)
import qualified Network.HTTP.Types as HTTP
import qualified Network.Wai as Wai

newApplication :: HttpsConfiguration -> Service.Service -> IO Wai.Application
newApplication https service = do
  pages <- Pages.newPageSets
  streams <- Events.newStreamReaders
  pure $ Transport.authenticated https (Service.serviceStore service)
    methods (dispatch service pages streams)

-- Only implemented methods are exposed to preflight. Owners check resource
-- existence after Transport authenticates the request.
methods :: [Text] -> [HTTP.Method]
methods path = case path of
  ["v1", "capabilities"] -> ["GET"]
  ["v1", "snapshot"] -> ["GET"]
  ["v1", "profiles"] -> ["GET"]
  ["v1", "workflows"] -> ["GET"]
  ["v1", "events"] -> ["GET"]
  ["v1", "requests"] -> ["POST"]
  ["v1", kind, ident]
    | C.validId ident && kind `elem` ["requests", "preparations", "decisions"] -> ["GET", "POST"]
    | C.validId ident && kind `elem` ["commands", "artifacts", "workflows", "runs"] -> ["GET"]
  ["v1", "runs", ident, "control"] | C.validId ident -> ["GET", "POST"]
  ["v1", "runs", ident, leaf]
    | C.validId ident && leaf `elem` ["snapshot", "outputs"] -> ["GET"]
  _ -> []

dispatch :: Service.Service -> Pages.PageSets -> Events.StreamReaders -> Transport.AuthenticatedApplication
dispatch service pages streams proof request respond = do
  when (Wai.requestMethod request == "GET") $ case Wai.requestBodyLength request of
    Wai.KnownLength 0 -> pure ()
    _ -> throwIO C.InvalidRequest
  (selectedProfile, token) <- if workflowList then workflowParameters request else do
    pageToken <- if paged then pageParameter request else
      if eventRequest then pure Nothing else noQuery request >> pure Nothing
    pure (Nothing,pageToken)
  case (Wai.requestMethod request, Wai.pathInfo request) of
    ("GET", ["v1", "capabilities"]) ->
      Auth.withAuthorizedCatalogues store proof [C.Observe] $ \view limits profiles _ -> do
        revision <- Auth.authorizedCursorRevision view
        (epoch, stream) <- Store.runRead store $ do
          binding <- Events.captureBinding proof (map fst profiles) revision
          pure (Events.bindingEpoch binding, Events.publicStreamId binding)
        let scopes = [scope | scope <- [C.Observe,C.Submit,C.Control,C.ExportScope],
                      any (elem scope . snd) profiles]
            value = object ["version" .= (1 :: Int), "authorityEpoch" .= epoch, "streamId" .= stream,
              "versions" .= versions, "scopes" .= map C.scopeName scopes, "profileIds" .= map (publicId . fst) profiles,
              "transports" .= (["sse","polling"] :: [Text]), "limits" .= limitsValue limits]
        json view HTTP.status200 [] value respond
    ("GET", ["v1", "snapshot"]) ->
      Service.withOverviewSource service proof $ \view limits materialize -> page view limits token materialize
    ("GET", ["v1", "runs", ident]) ->
      Service.withRun service proof ident $ \view value ->
        json view HTTP.status200 [("ETag", representationTag request (C.encoded value))] value respond
    ("GET", ["v1", "profiles"]) ->
      Auth.withAuthorizedCatalogues store proof [C.Observe] $ \view limits profiles _ ->
        page view limits token $ do
          let items = map (toJSON . fst) profiles
          pure (contentRevision (toJSON items), [], items)
    ("GET", ["v1", "workflows"]) ->
      Auth.withAuthorizedCatalogues store proof [C.Observe] $ \view limits profiles catalogues -> do
        let allowed = map (publicId . fst) profiles
        forM_ selectedProfile $ \ident -> unless (ident `elem` allowed) (throwIO C.Forbidden)
        let chosen = maybe allowed pure selectedProfile
            available = [catalogue | (ident,catalogue) <- catalogues, ident `elem` chosen]
        unless (length chosen == length available) (throwIO C.StorageUnavailable)
        page view limits token $ do
          let items = [value | catalogue <- available, (_,value) <- discoveryPublicWorkflows catalogue]
          pure (contentRevision (toJSON items), [], items)
    ("GET", ["v1", "workflows", ident]) ->
      Auth.withAuthorizedCatalogues store proof [C.Observe] $ \view _ _ catalogues ->
        case [value | (_,catalogue) <- catalogues, (key,value) <- discoveryPublicWorkflows catalogue, key == ident] of
          [value] -> json view HTTP.status200 [("ETag", representationTag request (C.encoded value))] value respond
          _ -> throwIO C.ResourceUnavailable
    ("GET", ["v1", "events"]) -> do
      after <- eventParameter request
      case lookup "Accept" (Wai.requestHeaders request) of
        Just "application/json" -> Events.withBatch store proof after $ \view value ->
          json view HTTP.status200 [] value respond
        Just "text/event-stream" -> Events.withStream streams store proof after $ \pump ->
          respond $ Wai.responseStream HTTP.status200
            [("Content-Type", "text/event-stream"), ("X-Accel-Buffering", "no")] $ \write flush -> do
              let send view bytes = current view >> write (Builder.byteString bytes) >> flush
                  batch view (Object fields) = case KM.lookup "events" fields of
                    Just (Array events) -> forM_ events $ \event -> eventBlock event >>= send view
                    _ -> throwIO C.StorageUnavailable
                  batch _ _ = throwIO C.StorageUnavailable
              pump batch (\view -> send view ": heartbeat\n\n")
        _ -> throwIO C.UnsupportedOperation
    ("POST", ["v1", "requests"]) -> do
      (key, condition, bytes) <- jsonMutation request
      unless (condition == Nothing) (throwIO C.InvalidPrecondition)
      draft <- Drafts.createDraft store proof key bytes >>= need
      Auth.withAuthorizedResponse store proof (D.draftProfile draft) [C.Submit] $ \view ->
        json view HTTP.status201 [("Location", TE.encodeUtf8 ("/v1/requests/" <> D.draftId draft))]
          (toJSON draft) respond
    ("GET", ["v1", "requests", ident]) ->
      Drafts.withDraft store proof ident $ \view draft -> do
        tag <- strong (D.draftRevision draft)
        json view HTTP.status200 [("ETag", tag)] (toJSON draft) respond
    ("POST", ["v1", "requests", ident]) -> do
      (key, condition, bytes) <- jsonMutation request
      operation <- bodyOperation bytes
      result <- case operation of
        "set-input" -> Service.editInput service proof ident key condition bytes
        "remove-input" -> Service.editInput service proof ident key condition bytes
        "enqueue" -> Service.enqueue service proof ident key condition bytes
        "withdraw" -> Service.withdraw service proof ident key condition bytes
        _ -> throwIO C.InvalidRequest
      need result >>= receipt
    ("GET", ["v1", "preparations", ident]) ->
      Approval.withPreparation store proof ident $ \view preparation -> do
        tag <- strong (P.preparationRevision preparation)
        json view HTTP.status200 [("ETag", tag)] (toJSON preparation) respond
    ("POST", ["v1", "preparations", ident]) -> do
      (key, condition, bytes) <- jsonMutation request
      operation <- bodyOperation bytes
      case operation of
        "approve" -> Service.approve service proof ident key condition bytes >>= need >>= receipt
        "discard" -> throwIO C.UnsupportedOperation
        _ -> throwIO C.InvalidRequest
    ("GET", ["v1", "commands", ident]) ->
      Commands.withCommand store proof ident $ \view value ->
        json view HTTP.status200 [("ETag", representationTag request (C.encoded value))]
          (toJSON value) respond
    ("GET", ["v1", "runs", ident, "control"]) ->
      Service.withControl service proof ident $ \view value -> do
        tag <- valueRevision value >>= strong
        json view HTTP.status200 [("ETag", tag)] value respond
    ("POST", ["v1", "runs", ident, "control"]) -> do
      (key, condition, bytes) <- jsonMutation request
      Service.controlRun service proof ident key condition bytes >>= need >>= receipt
    ("GET", ["v1", "decisions", ident]) -> do
      association <- State.resolveDecision store proof [C.Observe] ident
      State.withDecision store proof association ident $ \view value -> do
        tag <- valueRevision value >>= strong
        json view HTTP.status200 [("ETag", tag)] value respond
    ("POST", ["v1", "decisions", ident]) -> do
      (key, condition, bytes) <- jsonMutation request
      Service.controlDecision service proof ident key condition bytes >>= need >>= receipt
    ("GET", ["v1", "runs", ident, "snapshot"]) ->
      Service.withSnapshotSource service proof ident $ \view limits materialize ->
        page view limits token $ do
          snapshot <- materialize
          pure (Observation.publicSnapshotRevision snapshot,
                Observation.publicSnapshotFields snapshot, Observation.publicSnapshotItems snapshot)
    ("GET", ["v1", "runs", ident, "outputs"]) ->
      Service.withOutputsSource service proof ident $ \view limits materialize ->
        page view limits token $ do
          items <- materialize
          pure (contentRevision (toJSON items), ["runId" .= ident], items)
    ("GET", ["v1", "artifacts", ident]) ->
      Service.download service proof ident $ \view _ bytes ->
        Transport.respondBytes HTTP.status200
          [("Content-Type", "application/octet-stream"), ("Content-Disposition", "attachment"),
           ("Content-Length", BC.pack (show (BS.length bytes))),
           ("ETag", representationTag request bytes)] (current view) bytes respond
    _ -> throwIO C.ResourceUnavailable
  where
    store = Service.serviceStore service
    eventRequest = Wai.pathInfo request == ["v1", "events"]
    workflowList = Wai.pathInfo request == ["v1", "workflows"]
    paged = Wai.requestMethod request == "GET" && case Wai.pathInfo request of
      ["v1", kind] -> kind `elem` ["profiles", "snapshot"]
      ["v1", "runs", _, leaf] -> leaf `elem` ["snapshot", "outputs"]
      _ -> False
    page view limits token produce = servePage pages store proof request view limits token produce respond
    receipt value = Auth.withAuthorizedResponse store proof (C.receiptProfile value)
      (C.requiredScopes (C.receiptOperation value)) $ \view ->
        json view HTTP.status202 [("Location", TE.encodeUtf8 ("/v1/commands/" <> C.receiptId value))]
          (toJSON value) respond

servePage :: Pages.PageSets -> Store.CoordinationStore -> Auth.CredentialProof
  -> Wai.Request -> Auth.AuthorizedView -> ConfigurationLimits -> Maybe Text
  -> IO (Text, [Pair], [Value])
  -> (Wai.Response -> IO Wai.ResponseReceived) -> IO Wai.ResponseReceived
servePage pages store proof request view limits token produce respond = do
  client <- Store.runRead store (Auth.currentClient proof) >>= need
  binding <- Auth.authorizedViewRevision view
  let query = TE.decodeUtf8 (Wai.rawPathInfo request <> HTTP.renderQuery True
        [(key,value) | (key,value) <- Wai.queryString request, key /= "pageToken"])
  Pages.withPage pages client binding query (limitGlobalPageSets limits) token produce $ \_ bytes ->
    Transport.respondBytes HTTP.status200
      [("Content-Type", "application/json"), ("ETag", representationTag request bytes)]
      (current view) bytes respond

workflowParameters :: Wai.Request -> IO (Maybe Text, Maybe Text)
workflowParameters request = do
  let parameters = Wai.queryString request
      keys = map fst parameters
      value name bound = case lookup name parameters of
        Nothing -> pure Nothing
        Just (Just bytes) | not (BS.null bytes) && BS.length bytes <= bound && BS.all urlSafe bytes ->
          pure (Just (TE.decodeUtf8 bytes))
        _ -> throwIO C.InvalidRequest
  unless ("profileId" `elem` keys && all (`elem` ["profileId","pageToken"]) keys && length (nub keys) == length keys
    && Wai.rawQueryString request == HTTP.renderQuery True parameters) (throwIO C.InvalidRequest)
  (,) <$> value "profileId" 128 <*> value "pageToken" 512

versions :: Value
versions = object
  ["api" .= ([1] :: [Int]), "snapshot" .= ([1] :: [Int]), "event" .= ([1] :: [Int]),
   "descriptor" .= ([2,3] :: [Int]), "frontendSession" .= ([1,2] :: [Int]),
   "control" .= ([1,2] :: [Int]), "runtimeProtocol" .= Runtime.supportedProtocolVersions,
   "frontendManifest" .= (["legacy","2","3"] :: [Text]), "runtimeStore" .= ([1,2] :: [Int]),
   "managerStore" .= [1..schemaVersion], "invocation" .= ([1] :: [Int])]

limitsValue :: ConfigurationLimits -> Value
limitsValue configuration = object [key .= value | (key,value) <- fields]
  where
    fields :: [(Key.Key,Int)]
    fields =
      [("requestTargetBytes",8192), ("headerBytes",16384), ("headerFields",100),
       ("jsonBodyBytes",2097152), ("jsonDepth",64), ("nativeControlBytes",1048576),
       ("captureBytes",67108864), ("aggregateInputBytes",67108864), ("artifactBytes",67108864),
       ("sseBlockBytes",16384), ("pageBytes",1048576), ("pageSetBytes",67108864),
       ("pageSetsPerClient",2), ("pageSetLifetimeSeconds",60), ("queuedRequests",100),
       ("maxReservations",16), ("reviewLifetimeSeconds",600), ("sseReadersPerClient",2),
       ("ssePendingBytesPerReader",1048576), ("replaySeconds",604800), ("replayBytes",268435456),
       ("heartbeatSeconds",15), ("reconnectIdleSeconds",45), ("reconnectBackoffMaxSeconds",30),
       ("ordinaryMutationsPerMinute",30), ("drafts",limitDrafts configuration),
       ("globalDrafts",limitGlobalDrafts configuration), ("globalCaptureBytes",limitGlobalCaptureBytes configuration),
       ("globalPageSets",limitGlobalPageSets configuration), ("globalConnections",limitGlobalConnections configuration),
       ("globalDatabaseReaders",limitGlobalDatabaseReaders configuration),
       ("globalMutationLedgerBytes",limitGlobalMutationLedgerBytes configuration),
       ("safetyControlsPerMinute",limitSafetyControlsPerMinute configuration),
       ("executionReservations",limitExecutionReservations configuration)]

eventBlock :: Value -> IO BS.ByteString
eventBlock (Object fields)
  | Just (String ident) <- KM.lookup "id" fields, Just (String kind) <- KM.lookup "event" fields,
    Just value <- KM.lookup "data" fields = do
      let bytes = "id: " <> TE.encodeUtf8 ident <> "\nevent: " <> TE.encodeUtf8 kind
            <> "\ndata: " <> C.encoded value <> "\n\n"
      when (BS.length bytes > 16384) (throwIO C.ViewTooLarge)
      pure bytes
eventBlock _ = throwIO C.StorageUnavailable

json :: Auth.AuthorizedView -> HTTP.Status -> HTTP.ResponseHeaders -> Value
  -> (Wai.Response -> IO Wai.ResponseReceived) -> IO Wai.ResponseReceived
json view status headers value respond = do
  let bytes = C.encoded value
  when (BS.length bytes > 1048576) (throwIO C.ViewTooLarge)
  Transport.respondBytes status (("Content-Type", "application/json") : headers)
    (current view) bytes respond

current :: Auth.AuthorizedView -> IO ()
current view = Auth.revalidateAuthorizedView view >>= need

-- Writable-resource GETs use the owning Mutation's revision unchanged.
strong :: Text -> IO BS.ByteString
strong revision = do
  unless (C.validRevision revision) (throwIO C.StorageUnavailable)
  pure (TE.encodeUtf8 ("\"" <> revision <> "\""))

representationTag :: Wai.Request -> BS.ByteString -> BS.ByteString
representationTag request bytes = TE.encodeUtf8 $ "\"http_" <>
  T.pack (show (hash (Wai.rawPathInfo request <> Wai.rawQueryString request <> "\n" <> bytes)
    :: Digest SHA256)) <> "\""

contentRevision :: Value -> Text
contentRevision value = "content_" <> T.pack (show (hash (C.encoded value) :: Digest SHA256))

valueRevision :: Value -> IO Text
valueRevision (Object fields) = case KM.lookup "revision" fields of
  Just (String revision) | C.validRevision revision -> pure revision
  _ -> throwIO C.StorageUnavailable
valueRevision _ = throwIO C.StorageUnavailable

jsonMutation :: Wai.Request -> IO (Text, Maybe Text, BS.ByteString)
jsonMutation request = do
  key <- header "Idempotency-Key" >>= maybe (throwIO C.InvalidRequest) pure
  condition <- header "If-Match"
  bytes <- Transport.readJsonRequest request
  pure (key, condition, bytes)
  where
    header name = traverse (either (const (throwIO C.InvalidRequest)) pure . TE.decodeUtf8')
      (lookup name (Wai.requestHeaders request))

bodyOperation :: BS.ByteString -> IO Text
bodyOperation bytes = case decodeStrictValue bytes of
  Right (Object fields) -> case KM.lookup "operation" fields of
    Just (String operation) -> pure operation
    _ -> throwIO C.InvalidRequest
  _ -> throwIO C.InvalidRequest

noQuery :: Wai.Request -> IO ()
noQuery request = unless (BS.null (Wai.rawQueryString request) && null (Wai.queryString request))
  (throwIO C.InvalidRequest)

pageParameter :: Wai.Request -> IO (Maybe Text)
pageParameter request = case Wai.queryString request of
  [] -> noQuery request >> pure Nothing
  [("pageToken", Just bytes)] -> do
    unless (not (BS.null bytes) && BS.length bytes <= 512 && BS.all urlSafe bytes
      && Wai.rawQueryString request == "?pageToken=" <> bytes) (throwIO C.InvalidRequest)
    pure (Just (TE.decodeUtf8 bytes))
  _ -> throwIO C.InvalidRequest

-- The two cursor channels cannot be supplied together, even with equal values.
eventParameter :: Wai.Request -> IO Text
eventParameter request = case (Wai.queryString request, lookup "Last-Event-ID" (Wai.requestHeaders request)) of
  ([("after", Just bytes)], Nothing) | Wai.rawQueryString request == "?after=" <> bytes -> decode bytes
  ([], Just bytes) -> noQuery request >> decode bytes
  _ -> throwIO C.InvalidRequest
  where
    decode bytes = do
      unless (BS.length bytes <= 149 && BS.all (\byte -> byte == 46 || urlSafe byte) bytes)
        (throwIO C.InvalidRequest)
      either (const (throwIO C.InvalidRequest)) pure (TE.decodeUtf8' bytes)

urlSafe :: Word8 -> Bool
urlSafe byte = (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
  || (byte >= 48 && byte <= 57) || byte == 45 || byte == 95

need :: Either C.CommandFailure a -> IO a
need = either throwIO pure
