{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | Authorized observations and exclusive exports of retained Runtime artifacts.
module Agentic.Manager.Artifacts
  ( withArtifactDownload, withRunOutputs, withRunExports, submitExport, readExport, reconcileExport
  ) where

import Agentic.Manager.Authorization
import qualified Agentic.Manager.Commands as Commands
import Agentic.Manager.Profile (publicId, publicRevision)
import qualified Agentic.Manager.Protocol.Command as Command
import Agentic.Manager.Protocol.Json (decodeStrictValue)
import Agentic.Manager.Protocol.Artifact (validExportDocument, validExportName)
import Agentic.Manager.State (RunAssociation (..), authorizeObservation, withProfileProjection)
import Agentic.Manager.Store
import Agentic.Runtime
import Control.Exception (IOException, SomeException, bracket, fromException, throwIO, try)
import Control.DeepSeq (NFData (rnf))
import Control.Monad (unless, when, void, foldM)
import Crypto.Hash (Digest, SHA256, hash)
import Crypto.Random (getRandomBytes)
import Data.Aeson (FromJSON, Value (..), fromJSON, Result (..), object, (.=))
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Database.SQLite3 as SQL
import System.IO.Error (isAlreadyExistsError, isDoesNotExistError)

-- | A server-held association, never a caller-selected path or executable.
data ArtifactBinding = ArtifactBinding !RunAssociation !Text !Value !Value

-- | A recorded destination and its byte identity. A witness is a successful
-- shared-publisher receipt, not a conclusion drawn from matching foreign bytes.
data ExportRecord = ExportRecord !RunAssociation !Text !Text !Text !Text !Text !Text !Integer !Value !(Maybe Value) !Text

instance NFData ArtifactBinding where
  rnf (ArtifactBinding a i c r) = rnf (associationFields a,i,c,r)
instance NFData ExportRecord where
  rnf (ExportRecord a i c h r n d s v w state) = rnf (associationFields a,(i,c,h,r,n,d),(s,v,w,state))
associationFields :: RunAssociation -> (Text,Text,Text,Text)
associationFields a = (associationRun a,associationProfile a,associationRoot a,runIdText (associationNative a))

encoded :: Value -> BS.ByteString
encoded = Command.encoded
text :: Text -> SQL.SQLData
text = SQL.SQLText
json :: FromJSON a => Value -> IO a
json value = case fromJSON value of Success result -> pure result; Error _ -> throwIO StoreIntegrity
valueOf :: BS.ByteString -> Transaction Value
valueOf = either (const (refuseTransaction StoreIntegrity)) pure . decodeStrictValue

withProfile :: CoordinationStore -> Text -> IO a -> IO a
withProfile store profile action = do
  result <- withStoreConfiguration store $ \_ profiles -> do
    unless (profile `elem` map publicId profiles) (throwIO Command.Forbidden)
    action
  either (const (throwIO Command.StorageUnavailable)) pure result

binding :: CoordinationStore -> CredentialProof -> Text -> IO ArtifactBinding
binding store proof ident = runRead store $ do
  _ <- currentClient proof >>= either refuseTransaction pure
  unless (Command.validId ident) (refuseTransaction Command.InvalidRequest)
  rows <- query "SELECT r.id,r.profile_id,r.root_identity,r.native_run_id,a.code,a.private_reference FROM artifacts a JOIN runs r ON r.id=a.run_id WHERE a.id=?" [text ident]
  case rows of
    [[SQL.SQLText run,SQL.SQLText profile,SQL.SQLText root,SQL.SQLText native,SQL.SQLBlob code,SQL.SQLBlob reference]] -> do
      nativeId <- either (const (refuseTransaction StoreIntegrity)) pure (mkRunId native)
      let association = RunAssociation run profile root nativeId
      authorizeObservation proof association
      ArtifactBinding association ident <$> valueOf code <*> valueOf reference
    _ -> refuseTransaction Command.ResourceUnavailable

withRunRoot :: PrivateRoot -> RunAssociation -> (PrivateRoot -> IO a) -> IO a
withRunRoot root association action = bracket (openPrivateSubroot root ["runs"]) closePrivateRoot $ \runs -> do
  unless (T.pack (privateRootIdentity runs) == associationRoot association) (throwIO StoreIntegrity)
  result <- action runs
  assertPrivateRoot runs
  assertPrivateRoot root
  pure result

sourceBytes :: PrivateRoot -> RunAssociation -> ResultRef -> IO BS.ByteString
sourceBytes runs association = captureObservedResult runs (associationNative association)

-- | Shared verification for a retained observation address. The caller owns the
-- Store file loan, current authorization and response lifetime, not this address.
captureObservedResult :: PrivateRoot -> RunId -> ResultRef -> IO BS.ByteString
captureObservedResult runs native reference =
  bracket (openPrivateSubroot runs ["runs",T.unpack (runIdText native),"runtime"]) closePrivateRoot $ \runtime -> do
    (bytes,value) <- withPrivateDirectoryAt runtime [] $ \descriptor ->
      readResultArtifactBytesAt (privateRootPath runtime) descriptor native reference
    validateDocument (object ["code" .= resultArtifactCode reference,"value" .= value])
    assertPrivateRoot runtime
    assertPrivateRoot runs
    pure bytes

metadata :: Text -> Text -> Text -> Value -> BS.ByteString -> Value
metadata ident run kind code bytes = object
  ["id" .= ident,"runId" .= run,"kind" .= kind,"code" .= code,
   "bytes" .= T.pack (show (BS.length bytes)),"sha256" .= T.pack (show (hash bytes :: Digest SHA256)),
   "download" .= ("/v1/artifacts/" <> ident)]

-- | The callback must finish sending before returning and must not retain bytes.
-- Store's single file loan covers capture, verification, authorization and response.
-- At most one <=64MiB artifact is served per Store, with no unaccounted response queue.
withArtifactDownload :: CoordinationStore -> CredentialProof -> Text -> (Value -> BS.ByteString -> IO ()) -> IO ()
withArtifactDownload store proof ident respond = do
  legacy <- runRead store $ do
    _ <- currentClient proof >>= either refuseTransaction pure
    unless (Command.validId ident) (refuseTransaction Command.InvalidRequest)
    rows <- query "SELECT e.id,e.profile_id,e.root_identity,e.component,h.path,r.reference FROM history_entries e JOIN history_roots h ON h.identity=e.root_identity AND h.profile_id=e.profile_id JOIN history_results r ON r.entry_id=e.id WHERE 'artifact_'||e.id=? AND h.legacy=1" [text ident]
    case rows of
      [[SQL.SQLText run,SQL.SQLText profile,SQL.SQLText root,SQL.SQLText native,SQL.SQLText path,SQL.SQLBlob reference]] -> do
        _ <- authorizeProfile proof profile [Command.Observe] >>= either refuseTransaction pure
        pure (Just(run,profile,root,native,path,reference))
      [] -> pure Nothing
      _ -> refuseTransaction StoreIntegrity
  case legacy of
    Nothing -> withManagedArtifactDownload store proof ident respond
    Just (run,profile,identity,native,path,reference) -> do
      -- A persisted local binding is only an observation address. Configuration
      -- must still allow this exact root and profile before any file is opened.
      result <- withStoreRetentionRoot store (T.unpack path) profile $ \root -> contentRead $ do
        unless (T.pack(privateRootIdentity root) == identity) (throwIO StoreIntegrity)
        nativeId <- either (const (throwIO StoreIntegrity)) pure (mkRunId native)
        ref <- either (const (throwIO StoreIntegrity)) pure (decodeStrictValue reference) >>= json
        bytes <- captureObservedResult root nativeId ref
        revalidateStoreRetentionRoot store root profile >>= either (const (throwIO Command.ResourceUnavailable)) pure
        runRead store $ void (authorizeProfile proof profile [Command.Observe] >>= either refuseTransaction pure)
        revalidateStoreRetentionRoot store root profile >>= either (const (throwIO Command.ResourceUnavailable)) pure
        respond (metadata ident run "source-result" (resultArtifactCode ref) bytes) bytes
      either (const (throwIO Command.ResourceUnavailable)) pure result

withManagedArtifactDownload :: CoordinationStore -> CredentialProof -> Text -> (Value -> BS.ByteString -> IO ()) -> IO ()
withManagedArtifactDownload store proof ident respond = withStoreFiles store $ \root -> do
  ArtifactBinding association _ code reference <- binding store proof ident
  withProfile store (associationProfile association) $ do
    (kind,bytes) <- contentRead $ withRunRoot root association $ \runs -> case reference of
      Object fields | Just (String exportId) <- KM.lookup "exportId" fields -> do
        record@(ExportRecord _ _ _ artifact _ _ _ _ _ _ state) <- loadExport store proof exportId
        unless (artifact == ident && state == "published") (throwIO Command.ResourceUnavailable)
        captured <- captureExport runs record
        pure ("export",captured)
      _ -> do
        ref <- json reference
        unless (resultArtifactCode ref == code) (throwIO StoreIntegrity)
        captured <- sourceBytes runs association ref
        pure ("source-result",captured)
    when (kind == "source-result") (recordVerification store proof association ident "verified" Nothing)
    runRead store (authorizeObservation proof association)
    contentRead (assertPrivateRoot root)
    respond (metadata ident (associationRun association) kind code bytes) bytes

-- | Bounded output items, not a page-set service. Oversized views refuse rather
-- than pretending that a truncated set is a complete page.
withRunOutputs :: CoordinationStore -> CredentialProof -> RunAssociation -> ([Value] -> IO ()) -> IO ()
withRunOutputs store proof association respond = withStoreFiles store $ \root ->
  withProfileProjection store proof association $ \snapshot -> do
    artifact <- runRead store $ do
      authorizeObservation proof association
      rows <- query "SELECT result_artifact_id FROM runs WHERE id=?" [text (associationRun association)]
      case rows of [[SQL.SQLNull]] -> pure Nothing; [[SQL.SQLText ident]] -> pure (Just ident); _ -> refuseTransaction StoreIntegrity
    result <- case artifact of
      Nothing -> pure (object ["state" .= ("absent"::Text)],Null)
      Just ident -> do
        ArtifactBinding bound _ code reference <- binding store proof ident
        unless (bound == association) (throwIO StoreIntegrity)
        ref <- json reference
        unless (resultArtifactCode ref == code) (throwIO StoreIntegrity)
        captured <- try @SomeException (withRunRoot root association (\runs -> sourceBytes runs association ref))
        case captured of
          Right bytes -> do
            recordVerification store proof association ident "verified" Nothing
            pure (object ["state" .= ("verified"::Text),"artifactId" .= ident],metadata ident (associationRun association) "source-result" code bytes)
          Left failure -> do
            reason <- verificationFailure failure
            recordVerification store proof association ident "unavailable" (Just reason)
            pure (object ["state" .= ("unavailable"::Text),"artifactId" .= ident,"reason" .= reason],Null)
    let attempts = [(occurrence,attempt) | occurrence <- Map.elems (snapshotOccurrences snapshot), attempt <- Map.elems (snapshotOccurrenceAttempts occurrence)]
        outputs = [object ["kind" .= ("attempt"::Text),"address" .= object
          ["occurrenceId" .= T.pack (show (occurrenceNumber (snapshotOccurrenceId occurrence))),
           "attemptId" .= T.pack (show (attemptNumber (snapshotAttemptId attempt)))],
          "transportText" .= T.takeEnd 65536 (snapshotAttemptOutput attempt)] | (occurrence,attempt) <- attempts]
        messages = [message | Just message <- snapshotRunFailure snapshot : map (snapshotAttemptFailure . snd) attempts]
          <> concatMap (snapshotAttemptMessages . snd) attempts
        diagnostics = [object ["kind" .= ("diagnostic"::Text),"message" .= T.take 8192 message] | message <- messages]
        items = outputs <> diagnostics <> [object ["kind" .= ("result"::Text),"verification" .= fst result,"artifact" .= snd result]]
    when (length items > 256 || BS.length (Command.encoded items) > 1048576) (throwIO Command.ViewTooLarge)
    runRead store (authorizeObservation proof association)
    respond items

contentRead :: IO a -> IO a
contentRead action = try @SomeException action >>= either (\failure -> verificationFailure failure >> throwIO Command.ResourceUnavailable) pure

verificationFailure :: SomeException -> IO Text
verificationFailure failure
  | Just (StoreIncompatible _ _) <- fromException failure = pure "unsupported-version"
  | Just (StoreCorrupt _ _) <- fromException failure = pure "corrupt"
  | Just io <- fromException failure = pure (if isDoesNotExistError io then "missing" else "ownership-unavailable")
  | Just StoreIntegrity <- fromException failure = pure "ownership-unavailable"
  | otherwise = throwIO failure

recordVerification :: CoordinationStore -> CredentialProof -> RunAssociation -> Text -> Text -> Maybe Text -> IO ()
recordVerification store proof association ident state reason = do
  revision <- freshArtifactRevision
  runTransaction store $ do
    authorizeObservation proof association
    previous <- query "SELECT verification,verification_failure FROM artifacts WHERE id=? AND run_id=?" [text ident,text (associationRun association)]
    if previous == [[text state,maybe SQL.SQLNull text reason]] then pure ((),[]) else do
      execute "UPDATE artifacts SET verification=?,verification_failure=?,revision=? WHERE id=? AND run_id=?"
        [text state,maybe SQL.SQLNull text reason,text revision,text ident,text (associationRun association)]
      execute "UPDATE runs SET result_state=?,revision=? WHERE id=? AND result_artifact_id=?" [text state,text revision,text (associationRun association),text ident]
      pure ((),[Invalidation "artifact.changed" ("/v1/artifacts/"<>ident) revision,
        Invalidation "run.changed" ("/v1/runs/"<>associationRun association<>"/outputs") revision])

freshArtifactRevision :: IO Text
freshArtifactRevision = do
  nonce <- getRandomBytes 24 :: IO BS.ByteString
  pure ("artifact_revision_" <> T.pack (show (hash nonce :: Digest SHA256)))

exportName :: BS.ByteString -> Either Command.CommandFailure Text
exportName bytes = do
  when (BS.length bytes > 2097152) (Left Command.SizeLimit)
  value <- either (const (Left Command.InvalidRequest)) Right (decodeStrictValue bytes)
  case value of
    Object fields | KM.size fields == 1, Just (String name) <- KM.lookup "name" fields,
      validExportName name -> Right name
    _ -> Left Command.InvalidRequest

exportVersion :: RunAssociation -> Transaction (Maybe (Text,Text,Text))
exportVersion association = do
  rows <- query "SELECT revision FROM runs WHERE id=?" [text (associationRun association)]
  case rows of
    [[SQL.SQLText revision]] -> pure (Just ("/v1/runs/"<>associationRun association<>"/exports",associationProfile association,revision))
    _ -> pure Nothing

-- | Explicit acceptance and one original publication. Replays never publish.
submitExport :: CoordinationStore -> CredentialProof -> RunAssociation -> Commands.CommandRequest -> IO (Either Command.CommandFailure Commands.Submission)
submitExport store proof association request
  | Commands.commandOperation request /= Command.Export || Commands.commandProfile request /= associationProfile association
    || Commands.commandResource request /= "/v1/runs/"<>associationRun association<>"/exports" = pure (Left Command.InvalidRequest)
  | otherwise = case exportName (Commands.commandBody request) of
      Left failure -> pure (Left failure)
      Right name -> do
        preflight <- Commands.commandPreflightVersion store proof request (exportVersion association)
        case preflight of
          Left failure -> pure (Left failure)
          Right True -> Commands.submitConfiguredCommand store proof request (\_ _ _ -> Left Command.StateConflict)
          Right False -> withStoreFiles store $ \root -> do
            configured <- withStoreConfiguration store $ \_ profiles -> do
              profileRevision <- case [publicRevision p | p <- profiles, publicId p == associationProfile association] of
                [found] -> pure found
                _ -> throwIO Command.Forbidden
              ident <- runRead store $ do
                authorizeObservation proof association
                _ <- authorizeProfile proof (associationProfile association) [Command.ExportScope] >>= either refuseTransaction pure
                rows <- query "SELECT result_artifact_id FROM runs WHERE id=?" [text (associationRun association)]
                case rows of [[SQL.SQLText artifact]] -> pure artifact; _ -> refuseTransaction Command.ResourceUnavailable
              pure (profileRevision,ident)
            (profileRevision,ident) <- either (const (throwIO Command.StorageUnavailable)) pure configured
            ArtifactBinding bound _ code reference <- binding store proof ident
            unless (bound == association) (throwIO StoreIntegrity)
            ref <- json reference
            unless (resultArtifactCode ref == code) (throwIO StoreIntegrity)
            contentRead $ withRunRoot root association $ \runs -> withPreparedResultExport runs (associationNative association) ref name $ \prepared -> do
              validateDocument (preparedExportDocument prepared)
              accepted <- Commands.submitConfiguredCommand store proof request $ \command _ _ -> Right $ Commands.Mutation profileRevision (exportVersion association) $ do
                authorizeObservation proof association
                conflicts <- query "SELECT id FROM exports WHERE destination_root_identity=? AND name=?" [text (T.pack (preparedExportRootIdentity prepared)),text name]
                if not (null conflicts) then pure (Left Command.StateConflict) else pure $ Right $ Commands.Intent
                  (Commands.noReferences {Commands.referenceRun=Just (associationRun association)}) True $ do
                    let exportId = "export_" <> command
                        artifactId = "artifact_" <> command
                        private = object ["exportId" .= exportId,"bytes" .= T.pack (show (preparedExportBytes prepared)),
                          "acceptedName" .= name,"acceptedBodySha256" .= T.pack (show (hash (Commands.commandBody request) :: Digest SHA256)),
                          "acceptedBodyBytes" .= T.pack (show (BS.length (Commands.commandBody request)))]
                    execute "INSERT INTO artifacts(id,revision,run_id,private_reference,code,verification) VALUES (?,?,?,?,?,'referenced')"
                      [text artifactId,text command,text (associationRun association),SQL.SQLBlob (encoded private),SQL.SQLBlob (encoded code)]
                    execute "INSERT INTO exports(id,revision,run_id,artifact_id,command_id,destination_root_identity,name,expected_sha256,state) VALUES (?,?,?,?,?,?,?,?,'unresolved')"
                      [text exportId,text command,text (associationRun association),text artifactId,text command,text (T.pack (preparedExportRootIdentity prepared)),text name,text (preparedExportSha256 prepared)]
                    execute "UPDATE runs SET revision=? WHERE id=?" [text command,text (associationRun association)]
                    pure ([Invalidation "artifact.changed" ("/v1/artifacts/"<>artifactId) command,Invalidation "run.changed" (Commands.commandResource request) command],Nothing)
              case accepted of
                Right submission | Just ticket <- Commands.submissionTicket submission -> do
                  reserved <- Commands.reserveDispatch ticket
                  case reserved of
                    Left _ -> pure ()
                    Right () -> void $ Commands.attemptDispatch ticket $ withProfile store (associationProfile association) $ do
                      runRead store $ authorizeObservation proof association >> (authorizeProfile proof (associationProfile association) [Command.ExportScope] >>= either refuseTransaction (const (pure ())))
                      let exportId = "export_" <> Commands.dispatchCommandId ticket
                      publication <- try @IOException (publishPreparedResultExport prepared)
                      case publication of
                        Left failure | isAlreadyExistsError failure -> void (Commands.recordRefusal ticket "export-conflict")
                        Left _ -> void (Commands.recordUnresolved ticket)
                        Right () -> do
                          record <- loadExport store proof exportId
                          let receipt = exportReceipt record True
                          runTransaction store $ do
                            authorizeObservation proof association
                            execute "UPDATE exports SET receipt=? WHERE id=? AND receipt IS NULL AND state='unresolved'" [SQL.SQLBlob (encoded receipt),text exportId]
                            pure ((),[Invalidation "run.changed" ("/v1/runs/"<>associationRun association<>"/exports") (exportId<>"_witnessed")])
                          completeExport store proof runs record (Just ticket)
                  pure accepted
                _ -> pure accepted

loadExport :: CoordinationStore -> CredentialProof -> Text -> IO ExportRecord
loadExport store proof ident = runRead store $ do
  _ <- currentClient proof >>= either refuseTransaction pure
  unless (Command.validId ident) (refuseTransaction Command.InvalidRequest)
  rows <- query "SELECT r.id,r.profile_id,r.root_identity,r.native_run_id,e.command_id,e.artifact_id,e.destination_root_identity,e.name,e.expected_sha256,a.private_reference,a.code,e.receipt,e.state FROM exports e JOIN runs r ON r.id=e.run_id JOIN artifacts a ON a.id=e.artifact_id AND a.run_id=r.id WHERE e.id=?" [text ident]
  case rows of
    [[SQL.SQLText run,SQL.SQLText profile,SQL.SQLText root,SQL.SQLText native,SQL.SQLText command,SQL.SQLText artifact,SQL.SQLText destination,SQL.SQLText name,SQL.SQLText digest,SQL.SQLBlob private,SQL.SQLBlob code,witness,SQL.SQLText state]] -> do
      nativeId <- either (const (refuseTransaction StoreIntegrity)) pure (mkRunId native)
      let association = RunAssociation run profile root nativeId
      authorizeObservation proof association
      reference <- valueOf private
      size <- case reference of
        Object fields | KM.lookup "exportId" fields == Just (String ident), Just (String count) <- KM.lookup "bytes" fields ->
          case reads (T.unpack count) of [(n,"")] | n >= 0 && n <= maxArtifactBytes -> pure n; _ -> refuseTransaction StoreIntegrity
        _ -> refuseTransaction StoreIntegrity
      receipt <- case witness of SQL.SQLNull -> pure Nothing; SQL.SQLBlob bytes -> Just <$> valueOf bytes; _ -> refuseTransaction StoreIntegrity
      publicCode <- valueOf code
      let record = ExportRecord association ident command artifact destination name digest size publicCode receipt state
      when (state == "published" && receipt /= Just (exportReceipt record True)) (refuseTransaction StoreIntegrity)
      pure record
    _ -> refuseTransaction Command.ResourceUnavailable

exportReceipt :: ExportRecord -> Bool -> Value
exportReceipt (ExportRecord association ident command artifact _ name digest size code _ _) published = object
  ["version" .= (1::Int),"id" .= ident,"runId" .= associationRun association,"commandId" .= command,
   "name" .= name,"code" .= code,"state" .= (if published then "published" else "unresolved"::Text),
   "sha256" .= digest,"bytes" .= T.pack (show size),
   "download" .= (if published then Just ("/v1/artifacts/"<>artifact) else Nothing)]

captureExport :: PrivateRoot -> ExportRecord -> IO BS.ByteString
captureExport runs (ExportRecord _ _ _ _ root name digest size code _ _) = do
  (bytes,document) <- readPublishedResultExportBytes runs (T.unpack root) name size digest code
  validateDocument document
  pure bytes

validateDocument :: Value -> IO ()
validateDocument document = unless (validExportDocument document) (throwIO (StoreCorrupt "" "result does not fit the public export document"))

-- | Bounded receipt items under one current profile loan, not a page-set service.
withRunExports :: CoordinationStore -> CredentialProof -> RunAssociation -> ([Value] -> IO ()) -> IO ()
withRunExports store proof association respond = withProfile store (associationProfile association) $ do
  (revision,idents) <- runRead store $ do
    authorizeObservation proof association
    revision <- exportVersion association
    rows <- query "SELECT id FROM exports WHERE run_id=? ORDER BY id LIMIT 257" [text (associationRun association)]
    idents <- mapM (\row -> case row of [SQL.SQLText ident] -> pure ident; _ -> refuseTransaction StoreIntegrity) rows
    when (length idents > 256) (refuseTransaction Command.ViewTooLarge)
    pure (revision,idents)
  (_,reversed) <- foldM (\(size,items) ident -> do
    record@(ExportRecord _ _ _ _ _ _ _ _ _ _ state) <- loadExport store proof ident
    let item = exportReceipt record (state == "published")
        next = size + BS.length (encoded item) + if null items then 0 else 1
    when (next > 1048576) (throwIO Command.ViewTooLarge)
    pure (next,item:items)) (2,[]) idents
  let items = reverse reversed
  runRead store $ do
    authorizeObservation proof association
    current <- exportVersion association
    unless (revision == current) (refuseTransaction StoreBusy)
  respond items

readExport :: CoordinationStore -> CredentialProof -> Text -> IO Value
readExport store proof ident = do
  record@(ExportRecord association _ _ _ _ _ _ _ _ _ state) <- loadExport store proof ident
  withProfile store (associationProfile association) $ do
    runRead store (authorizeObservation proof association)
    pure (exportReceipt record (state == "published"))

-- | Only a durable successful publisher witness can close a lost receipt.
-- Matching bytes without that witness remain unresolved, including after reopen.
reconcileExport :: CoordinationStore -> CredentialProof -> Text -> IO Value
reconcileExport store proof ident = withStoreFiles store $ \root -> do
  record@(ExportRecord association _ _ _ _ _ _ _ _ witness _) <- loadExport store proof ident
  withProfile store (associationProfile association) $ do
    runRead store $ do
      authorizeObservation proof association
      _ <- authorizeProfile proof (associationProfile association) [Command.ExportScope] >>= either refuseTransaction pure
      pure ()
    case witness of
      Nothing -> pure (exportReceipt record False)
      Just receipt -> do
        unless (receipt == exportReceipt record True) (throwIO StoreIntegrity)
        contentRead $ withRunRoot root association $ \runs -> completeExport store proof runs record Nothing
        pure (exportReceipt record True)

completeExport :: CoordinationStore -> CredentialProof -> PrivateRoot -> ExportRecord -> Maybe Commands.DispatchTicket -> IO ()
completeExport store proof runs record@(ExportRecord association ident command artifact root name digest _ _ _ _) ticket = do
  void (contentRead (captureExport runs record))
  effect <- json (object ["kind" .= ("exported"::Text),"resource" .= ("/v1/exports/"<>ident),"runtimeSequence" .= Null,"address" .= Null])
  revision <- freshArtifactRevision
  let finish = do
        authorizeObservation proof association
        _ <- authorizeProfile proof (associationProfile association) [Command.ExportScope] >>= either refuseTransaction pure
        rows <- query "SELECT receipt,state FROM exports WHERE id=? AND command_id=? AND run_id=? AND artifact_id=? AND destination_root_identity=? AND name=? AND expected_sha256=?"
          [text ident,text command,text (associationRun association),text artifact,text root,text name,text digest]
        state <- case rows of
          [[SQL.SQLBlob witness,SQL.SQLText state]] | witness == encoded (exportReceipt record True), state `elem` ["published","unresolved"] -> pure state
          _ -> refuseTransaction StoreIntegrity
        if state == "published" then pure [] else do
          execute "UPDATE exports SET state='published',revision=? WHERE id=?" [text revision,text ident]
          execute "UPDATE artifacts SET verification='verified',revision=? WHERE id=?" [text revision,text artifact]
          execute "UPDATE runs SET revision=? WHERE id=?" [text revision,text (associationRun association)]
          pure [Invalidation "run.changed" ("/v1/runs/"<>associationRun association<>"/exports") revision,
            Invalidation "artifact.changed" ("/v1/artifacts/"<>artifact) revision]
  case ticket of
    Just original -> Commands.recordEffectWith original effect finish >>= either throwIO (const (pure ()))
    Nothing -> runTransaction store $ do
      changes <- finish
      events <- Commands.recordExportObservation command ident revision effect
      pure ((),changes <> events)
