# Concrete manager HTTP proposal

This is a source-grounded proposal against the supplied `base678326b` context. This inspection changed no source files, ran no commands or tests, and read no configuration or credential files. The code below is not compilation or execution evidence. Unqualified owner filenames refer to `manager/src/Agentic/Manager/`.

## Findings

- **Blocker — `agentic.cabal:209-248`, `manager/src/Agentic/Manager/Service.hs:213-266`, `cli/src/Agentic/Cli.hs:849-864`.** Service operations exist, but the registered modules contain no HTTP application, and CLI dispatch contains only the manager administration entry. A running service needs the composition below, not a replacement admission controller.
- **Blocker — `doc/api/openapi.yaml:2543-2578`, `manager/src/Agentic/Manager/Store.hs:1065-1141`.** `Capabilities.transports` requires both `sse` and `polling`. Store has an unfiltered retained-event reader, not an authorized event transport. There is no honest contract-compatible successful capabilities response yet. Returning `transports: []`, returning only polling, or advertising SSE would be wrong under this frozen contract.
- **High — `Approval.hs:92-121`, `Commands.hs:409-429`, `Authorization.hs:93-103`, `Store.hs:671-701`.** Wrapping existing `readPreparation` or `readCommand` in `withAuthorizedResponse` reacquires the fail-fast configuration guard. State projection readers also charge a reader through configuration. Scoped variants must be implemented at those owners, as below.
- **High — `Pages.hs:39-86`, `Observation.hs:89-97`, `Artifacts.hs:162-197`.** Reserving a page set after snapshot or output materialization misses the required admission ordering. The page owner already has the correct callback shape. Give it an owner-scoped materializer, not an already-built result or a detached `Response`.
- **Blocker — `Profile.hs:143-151,305-324`, `runtime/src/Agentic/Runtime/Descriptor.hs:84-106`, `doc/api/openapi.yaml:2661-2776`.** Filtered catalogue access is implemented. A complete public `Workflow` projection is not. In particular, discovery does not retain the required `help` text. Do not substitute an empty catalogue, fabricated help, native descriptor JSON, or private invocation fields.

The executable subset below deliberately refuses `/v1/capabilities` and does not register absent overview, event, workflow, or run-list handlers. It therefore does **not** complete the requested TUI acceptance journey. Those remaining owner obligations are named at the end.

## `manager/src/Agentic/Manager/Application.hs`

This module uses the scoped additions in the next section. It allocates one page table per service lifetime, keeps exact POST bytes and headers, and never obtains worker authority from an ID.

```haskell
{-# LANGUAGE OverloadedStrings #-}

-- | HTTP representations and commands of one existing manager service.
module Agentic.Manager.Application (newApplication) where

import qualified Agentic.Manager.Approval as Approval
import qualified Agentic.Manager.Authorization as Auth
import qualified Agentic.Manager.Commands as Commands
import Agentic.Manager.Configuration (HttpsConfiguration)
import qualified Agentic.Manager.Drafts as Drafts
import qualified Agentic.Manager.Observation as Observation
import qualified Agentic.Manager.Pages as Pages
import Agentic.Manager.Profile (ConfigurationLimits (..))
import qualified Agentic.Manager.Protocol.Command as C
import qualified Agentic.Manager.Protocol.Draft as D
import Agentic.Manager.Protocol.Json (decodeStrictValue)
import qualified Agentic.Manager.Protocol.Preparation as P
import qualified Agentic.Manager.Service as Service
import qualified Agentic.Manager.State as State
import qualified Agentic.Manager.Store as Store
import qualified Agentic.Manager.Transport as Transport
import Control.Exception (throwIO)
import Control.Monad (unless, when)
import Crypto.Hash (Digest, SHA256, hash)
import Data.Aeson (Value (..), object, toJSON, (.=))
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson.Types (Pair)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Network.HTTP.Types as HTTP
import qualified Network.Wai as Wai

newApplication :: HttpsConfiguration -> Service.Service -> IO Wai.Application
newApplication https service = do
  pages <- Pages.newPageSets
  pure $ Transport.authenticated https (Service.serviceStore service)
    methods (dispatch service pages)

-- Only implemented methods are exposed to preflight. Resource existence is
-- checked by owners after Transport has authenticated the request.
methods :: [Text] -> [HTTP.Method]
methods path = case path of
  ["v1", "capabilities"] -> ["GET"]
  ["v1", "profiles"] -> ["GET"]
  ["v1", "requests"] -> ["POST"]
  ["v1", kind, ident]
    | C.validId ident && kind `elem` ["requests", "preparations", "decisions"] ->
        ["GET", "POST"]
    | C.validId ident && kind `elem` ["commands", "artifacts"] -> ["GET"]
  ["v1", "runs", ident, "control"] | C.validId ident -> ["GET", "POST"]
  ["v1", "runs", ident, leaf]
    | C.validId ident && leaf `elem` ["snapshot", "outputs"] -> ["GET"]
  _ -> []

dispatch :: Service.Service -> Pages.PageSets -> Transport.AuthenticatedApplication
dispatch service pages proof request respond = do
  when (Wai.requestMethod request == "GET") $ case Wai.requestBodyLength request of
    Wai.KnownLength 0 -> pure ()
    _ -> throwIO C.InvalidRequest
  token <- if paged then pageParameter request
    else noQuery request >> pure Nothing
  case (Wai.requestMethod request, Wai.pathInfo request) of
    ("GET", ["v1", "capabilities"]) ->
      -- The frozen successful DTO requires two real event transports.
      throwIO C.StorageUnavailable

    ("GET", ["v1", "profiles"]) ->
      Auth.withAuthorizedCatalogues store proof [C.Observe] $ \view limits profiles _ ->
        page view limits token $ do
          let items = map (toJSON . fst) profiles
          pure (contentRevision (toJSON items), [], items)

    ("POST", ["v1", "requests"]) -> do
      (key, condition, bytes) <- jsonMutation request
      unless (condition == Nothing) (throwIO C.InvalidPrecondition)
      draft <- Drafts.createDraft store proof key bytes >>= need
      Auth.withAuthorizedResponse store proof (D.draftProfile draft) [C.Submit] $ \view ->
        json view HTTP.status201
          [("Location", TE.encodeUtf8 ("/v1/requests/" <> D.draftId draft))]
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
      result >>= need >>= receipt

    ("GET", ["v1", "preparations", ident]) ->
      Approval.withPreparation store proof ident $ \view preparation -> do
        tag <- strong (P.preparationRevision preparation)
        json view HTTP.status200 [("ETag", tag)] (toJSON preparation) respond

    ("POST", ["v1", "preparations", ident]) -> do
      (key, condition, bytes) <- jsonMutation request
      operation <- bodyOperation bytes
      case operation of
        "approve" -> Service.approve service proof ident key condition bytes >>= need >>= receipt
        "discard" -> do
          value <- either (const (throwIO C.InvalidRequest)) pure (decodeStrictValue bytes)
          unless (value == object ["operation" .= ("discard" :: Text)])
            (throwIO C.InvalidRequest)
          -- Discard needs its own original-admission command path. It is not withdraw.
          throwIO C.UnsupportedOperation
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
                Observation.publicSnapshotFields snapshot,
                Observation.publicSnapshotItems snapshot)

    ("GET", ["v1", "runs", ident, "outputs"]) ->
      Service.withOutputsSource service proof ident $ \view limits materialize ->
        page view limits token $ do
          items <- materialize
          pure (contentRevision (toJSON items), [], items)

    ("GET", ["v1", "artifacts", ident]) ->
      Service.download service proof ident $ \view _ bytes ->
        Transport.respondBytes HTTP.status200
          [("Content-Type", "application/octet-stream"),
           ("Content-Disposition", "attachment"),
           ("Content-Length", BC.pack (show (BS.length bytes))),
           ("ETag", representationTag request bytes)]
          (current view) bytes respond

    _ -> throwIO C.ResourceUnavailable
  where
    store = Service.serviceStore service
    paged = Wai.requestMethod request == "GET" && case Wai.pathInfo request of
      ["v1", "profiles"] -> True
      ["v1", "runs", _, leaf] -> leaf `elem` ["snapshot", "outputs"]
      _ -> False
    page view limits token produce =
      servePage pages store proof request view limits token produce respond
    -- POST responses require the operation's scopes, not an added observe scope.
    -- The owner has already completed or retained acceptance before this loan.
    receipt value = Auth.withAuthorizedResponse store proof (C.receiptProfile value)
      (C.requiredScopes (C.receiptOperation value)) $ \view ->
        json view HTTP.status202
          [("Location", TE.encodeUtf8 ("/v1/commands/" <> C.receiptId value))]
          (toJSON value) respond

servePage :: Pages.PageSets -> Store.CoordinationStore -> Auth.CredentialProof
  -> Wai.Request -> Auth.AuthorizedView -> ConfigurationLimits -> Maybe Text
  -> IO (Text, [Pair], [Value])
  -> (Wai.Response -> IO Wai.ResponseReceived) -> IO Wai.ResponseReceived
servePage pages store proof request view limits token produce respond = do
  client <- Store.runRead store (Auth.currentClient proof) >>= need
  binding <- Auth.authorizedViewRevision view
  let query = TE.decodeUtf8 (Wai.rawPathInfo request)
  Pages.withPage pages client binding query (limitGlobalPageSets limits) token produce $ \_ bytes ->
    Transport.respondBytes HTTP.status200
      [("Content-Type", "application/json"), ("ETag", representationTag request bytes)]
      (current view) bytes respond

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

-- Read-only representations and individual pages have URI-and-byte validators.
-- A first-page tag must not stand in for a continuation's tag.
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
    header name = traverse
      (either (const (throwIO C.InvalidRequest)) pure . TE.decodeUtf8')
      (lookup name (Wai.requestHeaders request))

bodyOperation :: BS.ByteString -> IO Text
bodyOperation bytes = case decodeStrictValue bytes of
  Right (Object fields) -> case KM.lookup "operation" fields of
    Just (String operation) -> pure operation
    _ -> throwIO C.InvalidRequest
  _ -> throwIO C.InvalidRequest

noQuery :: Wai.Request -> IO ()
noQuery request = unless (BS.null (Wai.rawQueryString request)
  && null (Wai.queryString request)) (throwIO C.InvalidRequest)

-- These three collections have no filter query. Accept one canonical token,
-- without ignored parameters, duplicate keys, alternate escaping or reordering.
pageParameter :: Wai.Request -> IO (Maybe Text)
pageParameter request = case Wai.queryString request of
  [] -> noQuery request >> pure Nothing
  [("pageToken", Just bytes)] -> do
    unless (not (BS.null bytes) && BS.length bytes <= 512
      && BS.all (\b -> (b >= 65 && b <= 90) || (b >= 97 && b <= 122)
        || (b >= 48 && b <= 57) || b == 45 || b == 95) bytes
      && Wai.rawQueryString request == "?pageToken=" <> bytes)
      (throwIO C.InvalidRequest)
    pure (Just (TE.decodeUtf8 bytes))
  _ -> throwIO C.InvalidRequest

need :: Either C.CommandFailure a -> IO a
need = either throwIO pure
```

`Commands.checkPrecondition` remains the owner of missing, malformed, stale and exact-URI mutation preconditions. Do not hash the draft, preparation, decision or control ETag in Application while leaving that check expecting `"revision"`. Do not normalize, re-encode, or replace POST bytes before calling an owner. A receipt response uses the returned original receipt, not a subsequent `readCommand` result.

## Exact scoped-owner additions

### `Authorization.hs`

Export `withAuthorizedResponseLimits`. Replace the current implementation of `withAuthorizedResponse` with delegation to this implementation. This preserves one reader charge, one configuration loan and one watch. Its revalidation uses the borrowed profiles.

```haskell
withAuthorizedResponse :: CoordinationStore -> CredentialProof -> Text -> [Scope]
  -> (AuthorizedView -> IO a) -> IO a
withAuthorizedResponse store proof profile scopes action =
  withAuthorizedResponseLimits store proof profile scopes $ \view _ -> action view

withAuthorizedResponseLimits :: CoordinationStore -> CredentialProof -> Text -> [Scope]
  -> (AuthorizedView -> ConfigurationLimits -> IO a) -> IO a
withAuthorizedResponseLimits store proof profile scopes action = do
  unless (validId profile && length (take 5 scopes) <= 4) (throwIO InvalidRequest)
  runRead store (currentClient proof) >>= either throwIO (const (pure ()))
  result <- withStoreConfigurationWatch store $ \watch limits profiles ->
    withView watch (profileViewFacts store proof profile scopes profiles) $ \view ->
      action view limits
  either (const (throwIO StorageUnavailable)) pure result
```

Leave `authorizedViewRevision` unchanged. Its stable acknowledged fingerprint is a page binding, not authority and not a process-generation token.

### `Drafts.hs`

Export this additional scoped read. Its call to `readDraft` does not reacquire configuration. The existing file checks, literal bounds, revision checks and error publication remain in that owner.

```haskell
withDraft :: CoordinationStore -> CredentialProof -> Text
  -> (AuthorizedView -> DraftView -> IO a) -> IO a
withDraft store proof ident respond = do
  original <- runRead store (requestState proof ident [Observe])
  withAuthorizedResponse store proof (draftProfile (requestView original)) [Observe] $ \view -> do
    draft <- readDraft store proof ident >>= requireEither
    revalidateAuthorizedView view >>= requireEither
    respond view draft
```

### `Approval.hs`

Export `withPreparation`. Extract the current transactional body of `readPreparation` into `preparationProjection` below. Keep all digest, generation, DTO and authorization checks. The old unscoped read can remain for existing library callers, calling this same projection under its original configuration scope. Application must call the new scoped function, never nest the old one.

```haskell
withPreparation :: CoordinationStore -> CredentialProof -> Text
  -> (AuthorizedView -> P.Preparation -> IO a) -> IO a
withPreparation store proof ident respond = do
  unless (validId ident) (throwIO InvalidRequest)
  withAuthorizedCatalogues store proof [Observe] $ \view _ visible _ -> do
    preparation <- runRead store (preparationProjection proof (map fst visible) ident)
    revalidateAuthorizedView view >>= need
    respond view preparation

readPreparation :: CoordinationStore -> CredentialProof -> Text
  -> IO (Either CommandFailure P.Preparation)
readPreparation store proof ident = attemptIO $ do
  unless (validId ident) (throwIO InvalidRequest)
  result <- withStoreConfiguration store $ \_ profiles ->
    runRead store (preparationProjection proof profiles ident)
  either (const (throwIO StorageUnavailable)) pure result

preparationProjection :: CredentialProof -> [PublicProfile] -> Text
  -> Transaction P.Preparation
preparationProjection proof profiles ident = do
  _ <- currentClient proof >>= needT
  metadata <- query
    "SELECT r.profile_id FROM preparations p JOIN requests r ON r.id=p.request_id WHERE p.id=? AND EXISTS(SELECT 1 FROM credential_scopes s WHERE s.credential_id=? AND s.profile_id=r.profile_id AND s.scope='observe')"
    [text ident, text (credentialRateKey proof)]
  profile <- case metadata of
    [[SQL.SQLText value]] | value `elem` map publicId profiles -> pure value
    _ -> refuseTransaction Forbidden
  _ <- authorizeProfile proof profile [Observe] >>= needT
  generation <- transactionGeneration
  rows <- query
    "SELECT p.id,p.revision,p.request_id,p.request_revision,r.profile_id,p.profile_revision,r.descriptor_revision,p.state,p.expires_at,p.review_digest,p.process_generation,p.review,p.reason,p.private_binding FROM preparations p JOIN requests r ON r.id=p.request_id WHERE p.id=?"
    [text ident]
  preparation <- case rows of
    [[SQL.SQLText a, SQL.SQLText b, SQL.SQLText c, SQL.SQLText d,
      SQL.SQLText e, SQL.SQLText f, SQL.SQLText g, SQL.SQLText h,
      SQL.SQLText i, SQL.SQLText j, SQL.SQLText k, SQL.SQLBlob body,
      reason, SQL.SQLBlob privateBytes]] -> do
      public <- decodeT body
      binding <- decodeT privateBytes
      unless (digest privateBytes == j
        && field "reviewSha256" binding == Just (String (digest (encoded (public :: P.Review)))))
        (refuseTransaction StorageUnavailable)
      why <- case reason of
        SQL.SQLNull -> pure Nothing
        SQL.SQLText value -> pure (Just value)
        _ -> refuseTransaction StorageUnavailable
      pure (P.Preparation a b c d e f g h i j k public why)
    _ -> refuseTransaction ResourceUnavailable
  _ <- needT (either (const (Left StorageUnavailable)) Right
    (parseEither parseJSON (toJSON preparation)) :: Either CommandFailure P.Preparation)
  unless (P.preparationGeneration preparation == generation)
    (refuseTransaction ResourceUnavailable)
  pure preparation
```

### `Commands.hs`

Export `withCommand`. Factor the existing transactional receipt read, not command submission or replay. Its additional original-operation scopes remain mandatory. `configured`, `submitBoundCommand`, rates, attempts and retained dispatch tickets remain unchanged.

```haskell
readCommand :: CoordinationStore -> CredentialProof -> Text
  -> IO (Either CommandFailure CommandReceipt)
readCommand store proof ident
  | not (validId ident) = pure (Left InvalidRequest)
  | otherwise = configured store proof $ \_ profiles _ -> transaction store $ do
      receipt <- commandProjection proof profiles ident
      pure (receipt, [])

withCommand :: CoordinationStore -> CredentialProof -> Text
  -> (AuthorizedView -> CommandReceipt -> IO a) -> IO a
withCommand store proof ident respond = do
  unless (validId ident) (throwIO InvalidRequest)
  withAuthorizedCatalogues store proof [Observe] $ \view _ visible _ -> do
    receipt <- runRead store (runExceptT (commandProjection proof (map fst visible) ident))
      >>= either throwIO pure
    revalidateAuthorizedView view >>= either throwIO pure
    respond view receipt

commandProjection :: CredentialProof -> [PublicProfile] -> Text -> CommandTx CommandReceipt
commandProjection proof profiles ident = do
  _ <- checked =<< lift (currentClient proof)
  metadata <- sql
    "SELECT c.profile_id,c.operation FROM commands c WHERE c.id=? AND EXISTS(SELECT 1 FROM credential_scopes s WHERE s.credential_id=? AND s.profile_id=c.profile_id AND s.scope='observe')"
    [text ident, text (credentialRateKey proof)]
  case metadata of
    [[SQL.SQLText profile, SQL.SQLText operation]] -> do
      require (profile `elem` map publicId profiles) Forbidden
      op <- maybe (throwE StorageUnavailable) pure (parseOperation operation)
      _ <- checked =<< lift (authorizeProfile proof profile (Observe : requiredScopes op))
      receipt <- currentReceipt ident
      require (receiptProfile receipt == profile && receiptOperation receipt == op) StorageUnavailable
      pure receipt
    _ -> throwE Forbidden
```

### `State.hs`

Add `ConfigurationLimits` to the existing Profile import. Export `withProfileProjectionSource`, `withControlSurface`, `withClosedControlSurface`, and `withDecision`.

Keep the body of `controlSurface`, renaming it `controlSurfaceBorrowed`. Keep the body of `readDecision`, renaming it `decisionBorrowed`. In **those two bodies only**, replace `requireProjection store association` with `borrowedProjection store association`. No control submission path changes. Install these wrappers:

```haskell
-- Private helper. Only callers holding the response owner's reader loan use it.
borrowedProjection :: CoordinationStore -> RunAssociation -> IO RunSnapshot
borrowedProjection store association = restoreProjection store association
  >>= maybe (throwIO Command.ResourceUnavailable) (pure . checkpointSnapshot)

withProfileProjectionSource :: CoordinationStore -> CredentialProof -> RunAssociation
  -> (AuthorizedView -> ConfigurationLimits -> IO RunSnapshot -> IO a) -> IO a
withProfileProjectionSource store proof association action =
  withAuthorizedResponseLimits store proof (associationProfile association) [Command.Observe] $ \view limits ->
    action view limits $ do
      runRead store (authorizeObservation proof association)
      snapshot <- borrowedProjection store association
      revalidateAuthorizedView view >>= either throwIO pure
      pure snapshot

withProfileProjection :: CoordinationStore -> CredentialProof -> RunAssociation
  -> (AuthorizedView -> RunSnapshot -> IO a) -> IO a
withProfileProjection store proof association respond =
  withProfileProjectionSource store proof association $ \view _ materialize ->
    materialize >>= respond view

withControlSurface :: AcceptedStart -> CredentialProof
  -> (AuthorizedView -> Value -> IO a) -> IO a
withControlSurface accepted proof respond = do
  (store, profile, _, prepared) <- acceptedControlContext accepted
  let association = RunAssociation (acceptedStartRun accepted) profile
        (preparedRootIdentity prepared) (preparedRunId prepared)
  withAuthorizedResponse store proof profile [Command.Observe] $ \view -> do
    worker <- observeAcceptedStart accepted
    let live = observedWorkerPhase worker `elem` [WorkerStartSent, WorkerRunning]
          && observedWorkerExit worker == Nothing
    value <- controlSurfaceBorrowed store proof association live
    revalidateAuthorizedView view >>= either throwIO pure
    respond view value

withClosedControlSurface :: CoordinationStore -> CredentialProof -> RunAssociation
  -> (AuthorizedView -> Value -> IO a) -> IO a
withClosedControlSurface store proof association respond =
  withAuthorizedResponse store proof (associationProfile association) [Command.Observe] $ \view -> do
    value <- controlSurfaceBorrowed store proof association False
    revalidateAuthorizedView view >>= either throwIO pure
    respond view value

readControlSurface :: AcceptedStart -> CredentialProof -> IO Value
readControlSurface accepted proof = withControlSurface accepted proof (\_ -> pure)

readClosedControlSurface :: CoordinationStore -> CredentialProof -> RunAssociation -> IO Value
readClosedControlSurface store proof association =
  withClosedControlSurface store proof association (\_ -> pure)

withDecision :: CoordinationStore -> CredentialProof -> RunAssociation -> Text
  -> (AuthorizedView -> Value -> IO a) -> IO a
withDecision store proof association ident respond =
  withAuthorizedResponse store proof (associationProfile association) [Command.Observe] $ \view -> do
    value <- decisionBorrowed store proof association ident
    revalidateAuthorizedView view >>= either throwIO pure
    respond view value

readDecision :: CoordinationStore -> CredentialProof -> RunAssociation -> Text -> IO Value
readDecision store proof association ident =
  withDecision store proof association ident (\_ -> pure)
```

The existing `controlSurfaceBorrowed` consistency checks and `decisionBorrowed` question verification stay intact. In particular, `parseControlBody` still requires the `value` key, retains `Bool False`, and delegates typed decoding to Runtime. Do not replace it with a truthiness test or a text-answer adapter.

### `Observation.hs`

Import `ConfigurationLimits` from Profile and export `withRunSnapshotSource`. Replace `withRunSnapshot` with the delegating wrapper below. A continuation authorizes the resource and view but does not replay its runtime prefix again.

```haskell
withRunSnapshotSource :: CoordinationStore -> CredentialProof -> Text
  -> (AuthorizedView -> ConfigurationLimits -> IO SnapshotProjection -> IO a) -> IO a
withRunSnapshotSource store proof ident action = do
  association <- resolveRun store proof [Command.Observe] ident
  withAuthorizedResponseLimits store proof (associationProfile association) [Command.Observe] $ \view limits ->
    action view limits $ do
      cut <- runRead store (captureSnapshot proof association)
      projected <- restoreSnapshot store cut
      revalidateAuthorizedView view >>= either throwIO pure
      pure projected

withRunSnapshot :: CoordinationStore -> CredentialProof -> Text
  -> (AuthorizedView -> SnapshotProjection -> IO a) -> IO a
withRunSnapshot store proof ident respond =
  withRunSnapshotSource store proof ident $ \view _ materialize ->
    materialize >>= respond view
```

### `Artifacts.hs`

Import `ConfigurationLimits` and `withProfileProjectionSource`. Export `withRunOutputsSource`. Move the existing output materialization into the delayed action below. Its existing 256-item and 1 MiB refusal ceilings remain unchanged. This does not claim a larger output materializer merely because Pages can hold a larger set.

```haskell
withRunOutputs :: CoordinationStore -> CredentialProof -> RunAssociation
  -> (AuthorizedView -> [Value] -> IO ()) -> IO ()
withRunOutputs store proof association respond =
  withRunOutputsSource store proof association $ \view _ materialize ->
    materialize >>= respond view

withRunOutputsSource :: CoordinationStore -> CredentialProof -> RunAssociation
  -> (AuthorizedView -> ConfigurationLimits -> IO [Value] -> IO a) -> IO a
withRunOutputsSource store proof association action = withStoreFiles store $ \root ->
  withProfileProjectionSource store proof association $ \view limits readSnapshot ->
    action view limits $ do
      snapshot <- readSnapshot
      artifact <- runRead store $ do
        authorizeObservation proof association
        rows <- query "SELECT result_artifact_id FROM runs WHERE id=?"
          [text (associationRun association)]
        case rows of
          [[SQL.SQLNull]] -> pure Nothing
          [[SQL.SQLText ident]] -> pure (Just ident)
          _ -> refuseTransaction StoreIntegrity
      result <- case artifact of
        Nothing -> pure (object ["state" .= ("absent" :: Text)], Null)
        Just ident -> do
          ArtifactBinding bound _ code reference <- binding store proof ident
          unless (bound == association) (throwIO StoreIntegrity)
          ref <- json reference
          unless (resultArtifactCode ref == code) (throwIO StoreIntegrity)
          captured <- try @SomeException (withRunRoot root association (\runs -> sourceBytes runs association ref))
          case captured of
            Right bytes -> do
              recordVerification store proof association ident "verified" Nothing
              pure (object ["state" .= ("verified" :: Text), "artifactId" .= ident],
                    metadata ident (associationRun association) "source-result" code bytes)
            Left failure -> do
              reason <- verificationFailure failure
              recordVerification store proof association ident "unavailable" (Just reason)
              pure (object ["state" .= ("unavailable" :: Text), "artifactId" .= ident,
                            "reason" .= reason], Null)
      let attempts = [(occurrence, attempt)
            | occurrence <- Map.elems (snapshotOccurrences snapshot),
              attempt <- Map.elems (snapshotOccurrenceAttempts occurrence)]
          outputs = [object ["kind" .= ("attempt" :: Text), "address" .= object
            ["occurrenceId" .= T.pack (show (occurrenceNumber (snapshotOccurrenceId occurrence))),
             "attemptId" .= T.pack (show (attemptNumber (snapshotAttemptId attempt)))],
            "transportText" .= T.takeEnd 65536 (snapshotAttemptOutput attempt)]
            | (occurrence, attempt) <- attempts]
          messages = [message | Just message <- snapshotRunFailure snapshot
            : map (snapshotAttemptFailure . snd) attempts]
            <> concatMap (snapshotAttemptMessages . snd) attempts
          diagnostics = [object ["kind" .= ("diagnostic" :: Text),
                                  "message" .= T.take 8192 message] | message <- messages]
          items = outputs <> diagnostics <> [object ["kind" .= ("result" :: Text),
            "verification" .= fst result, "artifact" .= snd result]]
      when (length items > 256 || BS.length (Command.encoded items) > 1048576)
        (throwIO Command.ViewTooLarge)
      runRead store (authorizeObservation proof association)
      pure items
```

Generalize **only the callback result type** on `withArtifactDownload` and `withManagedArtifactDownload` from `(AuthorizedView -> Value -> ByteString -> IO ()) -> IO ()` to `(AuthorizedView -> Value -> ByteString -> IO a) -> IO a`. Their implementations already return the callback result. This lets WAI return `ResponseReceived` within the original file loan, without an IORef handoff or detached byte buffer. Existing unit callbacks remain valid.

### `Service.hs`

Add `ConfigurationLimits` to imports and export the new names below. Change the `download` signature to the polymorphic signature shown. Do not introduce another map, Admission instance, worker task, cancellation path, or receipt-to-worker lookup.

```haskell
editInput :: Service -> CredentialProof -> Text -> Text -> Maybe Text -> BS.ByteString
  -> IO (Either CommandFailure CommandReceipt)
editInput service = A.editRequestInput (admission service)

withdraw :: Service -> CredentialProof -> Text -> Text -> Maybe Text -> BS.ByteString
  -> IO (Either CommandFailure CommandReceipt)
withdraw service = A.withdrawRequest (admission service)

withControl :: Service -> CredentialProof -> Text
  -> (AuthorizedView -> Value -> IO a) -> IO a
withControl service proof ident respond = do
  association <- State.resolveRun (serviceStore service) proof [Observe] ident
  original <- startFor service ident
  case original of
    Just start -> State.withControlSurface start proof respond
    Nothing -> State.withClosedControlSurface (serviceStore service) proof association respond

withSnapshotSource :: Service -> CredentialProof -> Text
  -> (AuthorizedView -> ConfigurationLimits -> IO Observation.SnapshotProjection -> IO a) -> IO a
withSnapshotSource service = Observation.withRunSnapshotSource (serviceStore service)

withOutputsSource :: Service -> CredentialProof -> Text
  -> (AuthorizedView -> ConfigurationLimits -> IO [Value] -> IO a) -> IO a
withOutputsSource service proof ident respond = do
  association <- State.resolveRun (serviceStore service) proof [Observe] ident
  Artifacts.withRunOutputsSource (serviceStore service) proof association respond

download :: Service -> CredentialProof -> Text
  -> (AuthorizedView -> Value -> BS.ByteString -> IO a) -> IO a
download service = Artifacts.withArtifactDownload (serviceStore service)
```

`editInput` deliberately uses `Admission.editRequestInput`, not the narrower `Drafts.changeDraftInput`. It must invalidate a retained live preparation and keep its reservation charged through cleanup. `withdraw` uses the same original controller.

### `Transport.hs`

Make `respondBytes` authorize **before** invoking the WAI response callback as well as before each existing bounded chunk write. This covers empty responses and prevents committing success headers before discovering an already-invalid view.

```haskell
respondBytes :: HTTP.Status -> HTTP.ResponseHeaders -> IO () -> BS.ByteString
  -> (Wai.Response -> IO Wai.ResponseReceived) -> IO Wai.ResponseReceived
respondBytes status headers authorize bytes respond = do
  authorize
  respond $ Wai.responseStream status headers $ \write flush -> do
    let send chunk = do
          authorize
          outcome <- timeout 5000000 (write (Builder.byteString chunk) >> flush)
          maybe (throwIO (HttpFailure 503 "storage-unavailable")) pure outcome
        chunks value
          | BS.null value = pure ()
          | otherwise = let (chunk, rest) = BS.splitAt 16384 value
                         in send chunk >> chunks rest
    chunks bytes
```

The supplied `respond` must be called inside the owner scope. Under the proposed Warp composition, it performs the streaming response before returning. Do not return a `Response` from the scope for a different layer to send later. An abort unwinds Pages and its active-send charge. There is no fallback response after a write has begun.

Until `/v1/snapshot` exists, change the fixed problem document's `links` value from the nonexistent snapshot reference to `object []`. The frozen Problem DTO permits empty links. Restore that link with the actual Overview handler.

## Foreground lifetime integration

### `manager/src/Agentic/Manager.hs`

Export `serveManager`. Add qualified imports of Application, Service and Transport, plus `bracket`, `throwIO`, `forM_`, and `void`. Existing Configuration, Profile, Store and LocalAdmin imports provide the other identifiers.

```haskell
-- | One foreground listener within the original configuration and Store lifetimes.
serveManager :: Configuration -> IO ()
serveManager configuration = do
  https <- maybe (throwIO InvalidConfiguration) pure (configurationHttps configuration)
  bracket (installConfiguration configuration >>= either throwIO pure)
    closeConfiguration $ \installed -> do
      (limits, profiles) <- configurationSnapshot installed >>= either throwIO pure
      -- Discovery finishes before admission reconciles retained queue intent.
      -- Fixed unavailable/quarantined outcomes remain public profile facts.
      forM_ profiles $ \profile ->
        void (probeConfiguredProfile installed (publicId profile) (publicRevision profile))
      withCoordinationStore installed $ \store ->
        Service.withService store $ \service -> do
          application <- Application.newApplication https service
          let listen = Transport.runHttps https limits application
          case configurationAdministrationRoot configuration of
            Nothing -> listen
            Just _ -> withLocalAdministration store listen
```

The initial configuration snapshot is released before probing, admission, or serving. HTTPS configuration is immutable under existing reload rules. This proposal adds no reload endpoint or reload signal. It does not hold `withConfigurationSnapshot` around the listener.

Teardown unwinds HTTPS connections, local administration, Service's original scheduler and admission cleanup, Store, then installed configuration. Disconnecting an HTTP client never calls `shutdownAdmission`, `stopAcceptedStart`, or worker pipe cleanup. An uncertain POST response never causes automatic mutation replay.

### `cli/src/Agentic/Cli.hs`

Add the exact serve arm beside the existing administration arm, before ordinary CLI dispatch:

```haskell
["--manager", "serve", "--config", path] -> managerServeCmd reg (T.unpack path)
```

Use the existing loader and fixed public refusals. Add `bracket` and `AsyncException (UserInterrupt)` to Control.Exception imports, `myThreadId` and `throwTo` from Control.Concurrent, and `import qualified System.Posix.Signals as Signals`.

```haskell
managerServeCmd :: Registry -> FilePath -> IO ()
managerServeCmd reg path = do
  unless (isAbsolute path) (die reg 1 "manager --config requires an absolute file")
  withManagerSignals (do
    configuration <- loadManagerConfiguration reg path >>= either throwIO pure
    Manager.serveManager configuration)
    `catches`
      [ Handler $ \(_ :: Manager.Diagnostic) ->
          die reg 1 "manager configuration or HTTPS listener is unavailable",
        Handler $ \(failure :: SomeException) ->
          case fromException failure :: Maybe SomeAsyncException of
            Just asynchronous -> throwIO asynchronous
            Nothing -> die reg 2 "manager service is unavailable"
      ]

-- Signals interrupt the foreground owner, so its existing brackets perform cleanup.
-- They do not signal workers by PID or create a second supervision mechanism.
withManagerSignals :: IO a -> IO a
withManagerSignals action = do
  owner <- myThreadId
  let install signal = Signals.installHandler signal
        (Signals.CatchOnce (throwTo owner UserInterrupt)) Nothing
      restore signal previous = void (Signals.installHandler signal previous Nothing)
  bracket (install Signals.softwareTermination) (restore Signals.softwareTermination) $ \_ ->
    bracket (install Signals.keyboardSignal) (restore Signals.keyboardSignal) $ \_ -> action
```

Add the corresponding usage line. Add only `Agentic.Manager.Application` to the library's `other-modules` in `agentic.cabal`. Existing dependencies already include WAI, Warp, WarpTLS, TLS, network and crypton.

Leave `cliMain = cliMainWithBroker inProcessBroker` and the broker flow into `frontendCmd` unchanged. Manager starts the installed runner's existing frontend protocol through Admission and Worker. It does not interpret workflow terms or serialize a new broker implementation into the child. The configured runner must be the intended broker-enabled executable. This inspection did not verify any installed executable or running broker.

## Remaining non-fabricated interfaces

These are missing production owners, not successful placeholder routes in the code above.

### Event and Overview ownership

The public service still needs these concrete scoped surfaces. Names below are proposed interfaces, **not existing implementations**:

```haskell
-- Events: scoped data, already authorization-filtered and cursor-bound.
withEventBatch :: CoordinationStore -> CredentialProof -> Text
  -> (AuthorizedView -> Value -> IO a) -> IO a

-- Events: each supplied writer finishes within the corresponding batch loan.
-- Neither event values nor authority escape to an uncharged response queue.
type EventPump = (AuthorizedView -> Value -> IO ())
  -> (AuthorizedView -> IO ()) -> IO ()

withEventStream :: CoordinationStore -> CredentialProof -> Text
  -> (EventPump -> IO a) -> IO a

-- Overview: current grants, cursor and oldestCursor belong to the same cut.
-- The materializer runs only after Pages has reserved capacity.
withOverviewSource :: CoordinationStore -> CredentialProof
  -> (AuthorizedView -> ConfigurationLimits -> IO (Text, [Pair], [Value]) -> IO a)
  -> IO a
```

`withEventStream` must reserve the scoped reader and validate the initial cursor before entering its response continuation. The continuation invokes `EventPump` inside the actual WAI streaming callback. The pump calls its batch writer and heartbeat writer under current authorization loans, releases configuration before waiting, and releases the original reader on exit. Each writer must finish synchronously and must not retain a Value, view or byte buffer. Admission and batch reads must share the original reader charge rather than nesting another `withStoreReader`. These are required owner interfaces, not implemented handlers or a claimed functioning SSE transport.

The actual implementation obligations are precise:

1. Factor Store's retained-event read so current authorization, supplied view alias, durable stream, floor, high-water and selected invalidations are checked in one transaction. Calling `readRetainedEvents` and authorizing later in a separate transaction is insufficient. Filter command invalidations using observe **and original-operation authority**, just as `readCommand` does. Advance the batch cursor over the scanned durable prefix even when every scanned event is filtered out. Do not claim `hasMore = False` merely because the visible list is empty.
2. Factor Authorization's existing catalogue fact observation so Event and Overview owners can bind their cut to the same acknowledged authorization observation. Keep stable facts private. Use `authorizedViewRevision` as the acknowledged fingerprint, not a credential. The public cursor prefix must hash the versioned tuple of durable stream, authority epoch and that fingerprint, excluding process generation. Use the same alias for capability stream identity, snapshot cursor, oldestCursor and event IDs.
3. Capture complete Overview request, active-run, preparation and pending-decision cuts. Materialize outside SQL within the retained reader/configuration/watch scope. The current `Observation.captureSnapshot` and `restoreSnapshot` are for **one run**, not an Overview. Sequential current GETs followed by a freshly read high-water are not a snapshot. Preserve the existing 256-statement, 1000-row and 1 MiB transaction budgets. If bounded multi-read materialization is used, a commit between capture and final acknowledgement must refuse the whole cut, not replay its action or splice generations. It must neither truncate at 256 items nor hold a database transaction during network writes.
4. SSE needs two readers per client, the existing positive global connection/reader quotas, at most 1 MiB pending per reader, canonical LF `id/event/data` blocks of at most 16384 bytes, 15-second heartbeats, and authorization/floor checks during an open stream. A slow or invalidated reader closes without altering worker lifetime. No configuration guard is held while waiting for the next event or heartbeat. JSON polling uses the identical durable cursor and `oldestCursor` rules.
5. Map wrong-stream, old/future and stale-view event cursors to the frozen 410/resnapshot failures. Pages retains its settled independent retirement policy. Successful terminal socket delivery retires the set only after active sends finish. Terminal response loss requires a new snapshot. No token is authority and no acknowledgement endpoint is added.

Because the frozen capability DTO requires both transports, successful `/capabilities` remains a release blocker until both real paths are installed. Do not edit `minItems` or claim that periodic individual-resource GETs implement the `/events` polling contract.

### Other exact route gaps

- **Workflow GETs:** Profile needs bounded public Workflow projection and retained real help text from the installed runner. Discovery already owns bounded subprocess queries. Keep that IO there and keep executable paths, argv, environment, `controlFd`, and routing source paths out of HTTP DTOs. The existing descriptor v2/v3 distinction and the branch's accepted frontend-session v1/v2 and runtime-protocol v1/v2/v3 domains remain intact. Unknown versions still refuse.
- **Collection and Run GETs:** `/requests`, `/runs`, `/runs/{id}`, and global/per-run `/decisions` need consistent owner materializers. `State.readDecisionHeads` returns current head values, not a consistent paged inbox. `History.withHistory` is not an authorized Overview or a GET-by-ID replacement and must not be wrapped in a configuration scope that it reacquires internally.
- **Preparation discard:** Add a real Approval/Admission-owned command path using the preparation URI, its own revision, `[Submit, Control]`, and original live preparation cleanup. Calling request withdrawal under a preparation key would change the idempotency resource and operation. The proposed HTTP route returns an explicit refusal instead.
- **Capture upload:** `Drafts.uploadCapture` exists, but the subset does not register `/captures`. A real adapter must validate the sole canonical `requestId` query, require octet-stream, reject If-Match, preserve UTF-8 bytes, reserve the existing ceiling, and supply chunks no larger than 65536 bytes through the owner's exact-body measurement. It also needs a contract-correct Location from the owning command/resource association. No buffering of a 64 MiB request into the JSON path is proposed.
- **Exports and lineage:** Existing Artifacts and Drafts command owners exist, but their GET collections must supply the exact mutation validator for their respective collection URI and query. A page-content hash is not a substitute for `exportVersion` or the lineage mutation revision. They are not registered until that owner-scoped representation is supplied.

## Requested journey and residual risk

Once the missing discovery and event/overview owners are real, the lifecycle portion is concrete: create and edit a draft, GET its exact request ETag, enqueue, GET the preparation and its five exact approval selectors, approve through `Service.approve`, then observe the original run. GET the current decision before submitting `{"operation":"answer","occurrenceId":"…","generation":"…","value":false}`. Recovery uses the current decision's `choose-recovery` with `choice: "retry"`, or the exact run-control retry offer and that URI's ETag. Application never turns `false` into missing input.

Completion requires terminal Runtime observation plus result verification, not a 202 or pipe write. `withRunOutputsSource` produces existing verified metadata. Artifact GET serves the exact bytes verified by Artifacts under its retained file loan. The existing `Client.downloadVerified` can independently check byte count, digest and attachment headers. None of this report demonstrates a TUI submission, a running HTTPS server, native execution, recovery, or downloaded result. Those remain unverified.

```acceptance-report
{
  "criteriaSatisfied": [
    {
      "id": "criterion-1",
      "status": "satisfied",
      "evidence": "Source-cited blocker and high-severity findings accompany concrete Application code, scoped owner edits, foreground Manager/CLI composition, and explicitly absent Event/Overview and catalogue interfaces."
    }
  ],
  "changedFiles": [
    "/Users/johnw/Products/agent-cat-workflow-manager/implementation.9tGzKH/service-tui.purvEwEv/http-application-code.md"
  ],
  "testsAddedOrUpdated": [],
  "commandsRun": [],
  "validationOutput": [
    "Read-only inspection of named source owners, package registration, CLI composition, frozen OpenAPI routes/DTOs, and settled page/cursor contract.",
    "No source edits, commands, Git operations, tests, live configuration reads, credential reads, compilation, or runtime execution."
  ],
  "residualRisks": [
    "Proposal has not been compiled. Parent must integrate the stated owner extractions and exports before Application can build.",
    "Frozen capabilities require real SSE and polling. This subset intentionally refuses capabilities and does not complete TUI acceptance.",
    "Overview, authorized event cuts, SSE scoped-send ownership, Workflow help projection, collection GETs and remaining mutation variants are not fabricated here.",
    "Existing Store fail-fast contention and existing output-materialization ceilings remain unchanged.",
    "Foreground shutdown, configured broker executable identity, exact approval, typed false, recovery retry and verified download remain unexecuted."
  ],
  "noStagedFiles": true,
  "diffSummary": "Proposal artifact only. Parent alone writes or runs implementation changes.",
  "reviewFindings": [
    "Blocker: cli/src/Agentic/Cli.hs:849-864 and agentic.cabal:209-248 have no foreground manager HTTP application composition.",
    "Blocker: doc/api/openapi.yaml:2543-2578 requires both SSE and polling, while Store.readRetainedEvents is not an authorized event transport.",
    "High: Approval.hs:92-121, Commands.hs:409-429 and State projection readers must gain owner-scoped response variants rather than nested configuration acquisition.",
    "High: Observation.hs:89-97 and Artifacts.hs:162-197 currently materialize before a page reservation can be made by a caller.",
    "Blocker: Profile discovery does not yet retain the help required by the frozen public Workflow DTO."
  ],
  "manualNotes": "noStagedFiles means this agent staged nothing. Repository staging state was not inspected. Report code is a proposal, not attested compilation or end-to-end evidence."
}
```
