{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | Bounded retained observations. Neither an opaque handle nor a native address owns a worker.
module Agentic.Manager.History
  ( LegacyHistory, bindLegacyHistory, withHistory, withHistoryResult, createHistoryLineage, retainView ) where

import Agentic.Manager.Artifacts (withArtifactDownload)
import Agentic.Manager.Admission (Admission, ownsHistoryRun)
import Agentic.Manager.Authorization
import Agentic.Manager.Drafts (createLineageDraft)
import Agentic.Manager.Profile
import qualified Agentic.Manager.Protocol.Command as C
import Agentic.Manager.Protocol.Json (decodeStrictValue)
import Agentic.Manager.Store
import Agentic.Runtime
import Control.Exception (IOException, SomeException, fromException, bracket, try, throwIO)
import System.IO.Error (isDoesNotExistError)
import Control.Monad (forM, forM_, foldM, unless, when)
import Crypto.Hash (Digest, SHA256, hash)
import Crypto.Random (getRandomBytes)
import Data.Aeson (Value (..), object, (.=), toJSON, fromJSON, Result (..))
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (getCurrentTime)
import qualified Database.SQLite3 as SQL
import System.FilePath ((</>), takeFileName)
import System.Timeout (timeout)

-- | A local binding to one configured retention root and existing profile.
-- The constructor is private. Reload cannot rebind its retained root identity.
data LegacyHistory = LegacyHistory !FilePath !Text !Text

bindLegacyHistory :: CoordinationStore -> FilePath -> Text -> IO LegacyHistory
bindLegacyHistory store path profile = do
  result <- withStoreRetentionRoot store path profile $ \root -> do
    let identity = T.pack (privateRootIdentity root)
    revision <- fresh "history_binding_"
    runTransaction store $ do
      existing <- query "SELECT identity,profile_id,path FROM history_roots WHERE legacy=1 AND (identity=? OR path=?)" [text identity,text(T.pack path)]
      unless (null existing || existing == [[text identity,text profile,text(T.pack path)]]) (refuseTransaction C.StateConflict)
      if null existing then do
        execute "INSERT INTO history_roots VALUES (?,?,?,1)" [text identity,text profile,text(T.pack path)]
        pure ((),[Invalidation "service.changed" "/v1/capabilities" revision])
      else pure ((),[])
    pure (LegacyHistory path profile identity)
  either (const (throwIO C.ResourceUnavailable)) pure result

withLegacy :: CoordinationStore -> LegacyHistory -> (PrivateRoot -> IO a) -> IO a
withLegacy store (LegacyHistory path profile identity) action = do
  result <- withStoreRetentionRoot store path profile $ \root -> do
    unless (T.pack(privateRootIdentity root) == identity) (throwIO C.ResourceUnavailable)
    value <- action root
    assertPrivateRoot root
    pure value
  either (const (throwIO C.ResourceUnavailable)) pure result

-- | Complete materialization: at most 256 entries, 1MiB encoded, 30 seconds.
-- A larger or unbound catalogue refuses. No mutable offset or page token is returned.
-- WM025 owns consistent HTTP page sets over this bounded library observation.
withHistory :: CoordinationStore -> CredentialProof -> [LegacyHistory] -> Maybe Admission -> ([Value] -> IO ()) -> IO ()
withHistory store proof legacy admission respond = bounded $ do
  configured <- validateStoreHistoryBindings store [(path,profile) | LegacyHistory path profile _ <- legacy]
  either (const (throwIO C.ResourceUnavailable)) pure configured
  unless (length legacy <= 256 && Set.size(Set.fromList [identity | LegacyHistory _ _ identity <- legacy]) == length legacy) (throwIO C.InvalidRequest)
  managed <- withStoreFiles store $ \root -> do
    rows <- map (map (maybe SQL.SQLNull text)) <$> runRead store (do
      _ <- currentClient proof >>= either refuseTransaction pure
      values <- query "SELECT u.id,u.profile_id,u.root_identity,u.native_run_id,u.revision,u.supervision,r.workflow_id,u.request_id,u.parent_run_id,r.lineage_operation,u.result_artifact_id,u.result_state,a.verification_failure FROM runs u LEFT JOIN requests r ON r.id=u.request_id LEFT JOIN artifacts a ON a.id=u.result_artifact_id ORDER BY u.id LIMIT 257" []
      mapM (mapM (\value -> case value of SQL.SQLText t -> pure (Just t); SQL.SQLNull -> pure Nothing; _ -> refuseTransaction StoreIntegrity)) values)
    when (length rows > 256) (throwIO C.ViewTooLarge)
    bracket (try @IOException (openPrivateSubroot root ["runs"])) (either (const (pure ())) closePrivateRoot) $ \opened -> case opened of
      Left failure | isDoesNotExistError failure && null rows -> pure []
      Left _ -> throwIO C.ResourceUnavailable
      Right runs -> do
          now <- getCurrentTime
          let identity = T.pack(privateRootIdentity runs)
              addresses = [(native,row) | row@[_ ,_,SQL.SQLText bound,SQL.SQLText native,_,_,_,_,_,_,_,_,_] <- rows, bound == identity]
          unless (length addresses == length rows) (throwIO C.ResourceUnavailable)
          entries <- withPrivateDirectoryAt runs [] $ \fd -> foldRunCatalogueBoundedAt 256 (privateRootPath runs) fd Nothing now (\(size,seen,items) entry -> do
            let native = T.pack(takeFileName(entryDirectory entry))
            row <- maybe (throwIO C.ResourceUnavailable) pure (lookup native addresses)
            item <- renderManaged runs row entry
            (next,values) <- foldM appendItem (size,items) item
            pure (next,Set.insert native seen,values)) (2,Set.empty,[])
          let (size,seen,items) = entries
          (_,complete) <- foldM (\current (native,row) -> do
            rendered <- renderManaged runs row (CatalogueCorrupt (privateRootPath runs </> "runs" </> T.unpack native) "")
            foldM appendItem current rendered) (size,items) [(native,row) | (native,row) <- addresses,Set.notMember native seen]
          pure (reverse complete)
  observed <- foldM (\items binding -> do
    values <- legacyItems store proof (256-length items) binding
    let combined = items <> values
    when (BS.length(C.encoded combined) > 1048576) (throwIO C.ViewTooLarge)
    pure combined) managed legacy
  items <- mapM (retainView store) observed
  when (length items > 256 || BS.length(C.encoded items) > 1048576) (throwIO C.ViewTooLarge)
  forM_ (Set.toList(Set.fromList [profile | Object fields <- items, Just(String profile) <- [KM.lookup "profileId" fields]])) $ \profile -> do
    allowed <- observable store proof profile
    unless allowed (throwIO C.Forbidden)
  respond items
  where
    renderManaged runs row entry = case row of
        [SQL.SQLText ident,SQL.SQLText profile,_,SQL.SQLText native,SQL.SQLText revision,SQL.SQLText supervision,workflow,request,parent,lineage,artifact,state,failure] -> do
          allowed <- observable store proof profile
          if not allowed then pure [] else do
            unless (T.pack(takeFileName(entryDirectory entry)) == native) (throwIO StoreIntegrity)
            owned <- case (admission,entry) of
              (Just controller,CatalogueRun record) -> ownsHistoryRun store controller ident (frontendRunId(recordManifest record)) (T.pack(privateRootIdentity runs))
              _ -> pure False
            let observed = case entry of CatalogueRun record | owned -> CatalogueRun record {recordOwnership=RunOwnedHere}; _ -> entry
                supervisionNow = if supervision == "owned" && not owned then "lost" else supervision
            result <- verification artifact state failure
            item <- renderEntry store runs profile ident revision (case workflow of SQL.SQLText value -> Just value; _ -> Nothing) (sqlValue request) (sqlValue parent) (sqlValue lineage) supervisionNow result observed
            pure [item]
        _ -> throwIO StoreIntegrity

legacyItems :: CoordinationStore -> CredentialProof -> Int -> LegacyHistory -> IO [Value]
legacyItems store proof limit binding@(LegacyHistory _ profile _) = do
  allowed <- observable store proof profile
  if not allowed then pure [] else withLegacy store binding $ \root -> do
    now <- getCurrentTime
    (size,seen,parents,items) <- withPrivateDirectoryAt root [] $ \fd ->
      foldRunCatalogueBoundedAt limit (privateRootPath root) fd Nothing now (\(size,seen,parents,items) entry -> do
        let name = T.pack(takeFileName(entryDirectory entry))
        ident <- retainHandle store root profile name
        manifest <- entryManifest root entry
        parent <- traverse (\p -> do
          handle <- retainHandle store root profile (runIdText p)
          pure (runIdText p,handle)) (manifest >>= frontendParentRunId)
        reference <- retainResult store ident (case entry of CatalogueRun record -> recordSnapshot record >>= snapshotResult; _ -> Nothing)
        item <- renderEntry store root profile ident ident Nothing Null (toJSON(fmap snd parent)) (toJSON(manifest >>= frontendLineage)) "observer"
          (case reference of Nothing -> object ["state" .= ("absent"::Text)]; Just _ -> object ["state" .= ("referenced"::Text),"artifactId" .= resultHandle ident]) entry
        (next,values) <- appendItem (size,items) item
        pure (next,Set.insert name seen,maybe parents (:parents) parent,values)) (2,Set.empty,[],[])
    let missing = Set.toList(Set.fromList parents `Set.difference` Set.fromList [(name,ident) | (name,ident) <- parents,Set.member name seen])
    when (length items + length missing > limit) (throwIO C.ViewTooLarge)
    (_,complete) <- foldM (\current (name,ident) -> do
      item <- renderEntry store root profile ident ident Nothing Null Null Null "observer" (object ["state" .= ("absent"::Text)])
        (CatalogueCorrupt (privateRootPath root </> "runs" </> T.unpack name) "")
      appendItem current item) (size,items) missing
    pure (reverse complete)

appendItem :: (Int,[Value]) -> Value -> IO (Int,[Value])
appendItem (size,items) item = do
  let next = size + BS.length(C.encoded item) + 1
  when (next > 1048576 || length items >= 256) (throwIO C.ViewTooLarge)
  pure (next,item:items)

entryManifest :: PrivateRoot -> CatalogueEntry -> IO (Maybe FrontendManifest)
entryManifest _ (CatalogueRun record) = pure (Just(recordManifest record))
entryManifest root (CatalogueCorrupt directory _) = do
  attempt <- try @IOException $ withPrivateDirectoryAt root ["runs",takeFileName directory] readFrontendManifestAt
  pure $ case attempt of Right value | runIdText(frontendRunId value) == T.pack(takeFileName directory) -> Just value; _ -> Nothing

retainView :: CoordinationStore -> Value -> IO Value
retainView store (Object fields) | Just(String ident) <- KM.lookup "id" fields = do
  revision <- fresh "history_revision_"
  let digest = T.pack(show(hash(C.encoded(Object(KM.delete "revision" fields)))::Digest SHA256))
  actual <- runTransaction store $ do
    current <- query "SELECT revision FROM runs WHERE id=?" [text ident]
    unless (null current || (case KM.lookup "revision" fields of Just(String sampled) -> current == [[text sampled]]; _ -> False)) (refuseTransaction StoreBusy)
    old <- query "SELECT revision,digest FROM history_views WHERE id=?" [text ident]
    case old of
      [[SQL.SQLText retained,SQL.SQLText previous]] | previous == digest -> do
        let revisionNow = case current of [[SQL.SQLText value]] -> value; _ -> retained
        when (revisionNow /= retained) (execute "UPDATE history_views SET revision=? WHERE id=?" [text revisionNow,text ident])
        pure (revisionNow,[Invalidation "run.changed" (uri ident) revisionNow | revisionNow /= retained])
      _ -> do
        execute "INSERT INTO history_views VALUES (?,?,?) ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,digest=excluded.digest" [text ident,text revision,text digest]
        execute "UPDATE runs SET revision=? WHERE id=?" [text revision,text ident]
        pure (revision,[Invalidation "run.changed" (uri ident) revision])
  pure (Object(KM.insert "revision" (String actual) fields))
retainView _ _ = throwIO StoreIntegrity

observable :: CoordinationStore -> CredentialProof -> Text -> IO Bool
observable store proof profile = do
  configured <- withStoreConfiguration store $ \_ profiles -> pure (profile `elem` map publicId profiles)
  current <- either (const (throwIO C.StorageUnavailable)) pure configured
  allowed <- runRead store (authorizeProfile proof profile [C.Observe])
  pure (current && either (const False) (const True) allowed)

entryDirectory :: CatalogueEntry -> FilePath
entryDirectory (CatalogueRun record) = recordDirectory record
entryDirectory (CatalogueCorrupt directory _) = directory

retainHandle :: CoordinationStore -> PrivateRoot -> Text -> Text -> IO Text
retainHandle store root profile component = do
  ident <- fresh "history_"
  runTransaction store $ do
    rows <- query "SELECT id,profile_id FROM history_entries WHERE root_identity=? AND component=?" [text(T.pack(privateRootIdentity root)),text component]
    case rows of
      [[SQL.SQLText current,SQL.SQLText bound]] | bound == profile -> pure (current,[])
      [] -> do
        execute "INSERT INTO history_entries(id,root_identity,profile_id,component) VALUES (?,?,?,?)" [text ident,text(T.pack(privateRootIdentity root)),text profile,text component]
        pure (ident,[Invalidation "run.changed" (uri ident) ident])
      _ -> refuseTransaction StoreIntegrity

renderEntry :: CoordinationStore -> PrivateRoot -> Text -> Text -> Text -> Maybe Text -> Value -> Value -> Value -> Text -> Value -> CatalogueEntry -> IO Value
renderEntry store root profile ident revision workflow request parent lineage supervision result entry = do
  manifest <- entryManifest root entry
  case manifest of
    Nothing -> pure (object ["version" .= (1::Int),"kind" .= ("unreadable-manifest"::Text),"id" .= ident,"revision" .= revision,
      "profileId" .= profile,"category" .= ("manifest-unavailable"::Text),"links" .= object ["self" .= uri ident]])
    Just value -> do
      configured <- storeInvocations store >>= either (const (throwIO C.StorageUnavailable)) pure
      let current = lookup profile configured
      let expectedWorkflow = workflowIdentity profile (frontendWorkflow value)
      unless (maybe True (==expectedWorkflow) workflow) (throwIO C.ResourceUnavailable)
      let workflowId = expectedWorkflow
      let compatibility = if frontendVersion value == 1 then object ["kind" .= ("legacy"::Text)] else object ["kind" .= ("versioned"::Text),"frontendManifestVersion" .= frontendVersion value]
          (snapshot,foreignOwner,corrupt) = case entry of CatalogueRun record -> (recordSnapshot record,recordOwnership record == RunOwnedElsewhere,False); _ -> (Nothing,False,True)
          runtime = do
            s <- snapshot
            envelope <- snapshotLastEnvelope s
            case runSnapshotValue s of
              Object fields -> Just (Object (KM.insert "protocolVersion" (toJSON(envelopeVersion envelope)) (KM.filterWithKey (\k _ -> k `elem` ["status","lastSequence"]) fields)))
              _ -> Nothing
          limitations = ["legacy" | frontendVersion value == 1] <> ["foreign-owner" | foreignOwner] <> ["corrupt-journal" | corrupt]
            <> ["incompatible-invocation" | maybe False (\invocation -> either (const True) (const False) (retainLineageInvocation value (Just invocation))) current]
            <> ["lost-supervision" | supervision == "lost"] <> ["quarantined" | supervision == "cleanup-pending"]
      pure (object ["version" .= (1::Int),"id" .= ident,"revision" .= revision,"profileId" .= profile,"workflowId" .= workflowId,
        "requestId" .= request,"parentRunId" .= parent,"lineage" .= lineage,"manifest" .= compatibility,"runtime" .= runtime,
        "supervision" .= supervision,"integrity" .= (if corrupt then "corrupt" else "valid"::Text),"verification" .= result,"limitations" .= (limitations::[Text]),
        "links" .= object ["self" .= uri ident,"snapshot" .= (uri ident<>"/snapshot"),"control" .= (uri ident<>"/control"),"outputs" .= (uri ident<>"/outputs"),"exports" .= (uri ident<>"/exports"),"lineageRequests" .= (uri ident<>"/lineage-requests")]])

verification :: SQL.SQLData -> SQL.SQLData -> SQL.SQLData -> IO Value
verification (SQL.SQLText artifact) (SQL.SQLText state) _ | state `elem` ["referenced","verified"] = pure (object ["state" .= state,"artifactId" .= artifact])
verification (SQL.SQLText artifact) (SQL.SQLText "unavailable") (SQL.SQLText reason) = pure (object ["state" .= ("unavailable"::Text),"artifactId" .= artifact,"reason" .= reason])
verification SQL.SQLNull (SQL.SQLText "absent") _ = pure (object ["state" .= ("absent"::Text)])
verification _ _ _ = throwIO StoreIntegrity

retainResult :: CoordinationStore -> Text -> Maybe ResultRef -> IO (Maybe ResultRef)
retainResult store ident observed = do
  retained <- runTransaction store $ do
    rows <- query "SELECT reference FROM history_results WHERE entry_id=?" [text ident]
    case rows of
      [[SQL.SQLBlob bytes]] -> pure (Just bytes,[])
      [] -> case observed of
        Nothing -> pure (Nothing,[])
        Just reference -> do
          execute "INSERT INTO history_results VALUES (?,?)" [text ident,SQL.SQLBlob(C.encoded reference)]
          pure (Just(C.encoded reference),[Invalidation "artifact.changed" ("/v1/artifacts/"<>resultHandle ident) (resultHandle ident)])
      _ -> refuseTransaction StoreIntegrity
  forM retained $ \bytes -> do
    unless (maybe True ((==bytes) . C.encoded) observed) (throwIO C.ResourceUnavailable)
    value <- either (const (throwIO StoreIntegrity)) pure (decodeStrictValue bytes)
    case fromJSON value of Success reference -> pure reference; Error _ -> throwIO StoreIntegrity

-- | Verified retained result through the shared Artifacts/Runtime owner. Legacy roots never mutate.
withHistoryResult :: CoordinationStore -> CredentialProof -> [LegacyHistory] -> Text -> (BS.ByteString -> IO ()) -> IO ()
withHistoryResult store proof bindings ident respond = bounded $ do
  (profile,identity) <- runRead store $ do
    rows <- query "SELECT profile_id,root_identity FROM history_entries WHERE id=?" [text ident]
    case rows of
      [[SQL.SQLText profile,SQL.SQLText identity]] -> do
        _ <- authorizeProfile proof profile [C.Observe] >>= either refuseTransaction pure
        pure (profile,identity)
      _ -> refuseTransaction C.ResourceUnavailable
  unless (length [() | LegacyHistory _ p r <- bindings,p==profile,r==identity] == 1) (throwIO C.ResourceUnavailable)
  withArtifactDownload store proof (resultHandle ident) (\_ bytes -> respond bytes)

-- | Observation handles are not admitted as parents. No command or worker effect precedes refusal.
createHistoryLineage :: CoordinationStore -> CredentialProof -> Text -> Text -> Maybe Text -> BS.ByteString -> IO (Either C.CommandFailure C.CommandReceipt)
createHistoryLineage store proof ident key version body = do
  outcome <- try @C.CommandFailure $ runRead store $ do
    _ <- currentClient proof >>= either refuseTransaction pure
    rows <- query "SELECT profile_id FROM history_entries WHERE id=?" [text ident]
    case rows of
      [[SQL.SQLText profile]] -> do
        _ <- authorizeProfile proof profile [C.Observe,C.Submit] >>= either refuseTransaction pure
        pure True
      [] -> pure False
      _ -> refuseTransaction StoreIntegrity
  case outcome of
    Left failure -> pure (Left failure)
    Right True -> pure (Left C.OwnershipUnavailable)
    Right False -> createLineageDraft store proof ident key version body

bounded :: IO a -> IO a
bounded action = do
  outcome <- try @SomeException (timeout 30000000 action >>= maybe (throwIO C.ViewTooLarge) pure)
  case outcome of
    Right value -> pure value
    Left failure
      | Just _ <- fromException @IOException failure -> throwIO C.ResourceUnavailable
      | Just _ <- fromException @StoreError failure -> throwIO C.ResourceUnavailable
      | otherwise -> throwIO failure
fresh :: Text -> IO Text
fresh prefix = do bytes <- getRandomBytes 24 :: IO BS.ByteString; pure (prefix<>T.pack(show(hash bytes::Digest SHA256)))
text :: Text -> SQL.SQLData
text = SQL.SQLText
sqlValue :: SQL.SQLData -> Value
sqlValue (SQL.SQLText value) = String value
sqlValue _ = Null
uri :: Text -> Text
uri ident = "/v1/runs/"<>ident
resultHandle :: Text -> Text
resultHandle ident = "artifact_"<>ident
