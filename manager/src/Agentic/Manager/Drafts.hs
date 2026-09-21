{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | Durable input representations and verified captures, never workflow execution.
module Agentic.Manager.Drafts
  ( reconcileDrafts, createDraft, createLineageDraft, withLineageRequests, checkLineageParent, changeDraftInput, changeDraftInputGuarded, InputTransition (..), RequestState, requestView, requestOwner, requestState, currentVersion, editable, checkDraftCapacity, uploadCapture, collectCaptures, readDraft, assembleDraft, DraftAssembly, assemblyRequest, assemblyRevision, assemblyProfile, assemblyProfileRevision, assemblySetup, assemblyFrame, assemblyInputSummaries, assemblySelection, assemblyParentBinding, validateAssemblyParent, assembleDraftSnapshot, assembleAcceptedDraft, structuralReadiness, verifyFrontendFiles ) where

import Agentic.Manager.Authorization
import Agentic.Manager.Commands
import Agentic.Manager.Profile
  (ConfigurationLimits (..), Discovery, discoveryEntries, discoveryRevision, discoveryProfileRevision,
   discoverySelection, restartBinding, Selection, selectionContext, selectionInvocation, OperatorProfile (..))
import Agentic.Manager.Protocol.Command
import Agentic.Manager.Protocol.Draft
import Agentic.Manager.Lineage
import Agentic.Manager.Protocol.Preparation (ReviewInput (..))
import Agentic.Manager.Store
import Agentic.Runtime
  (PrivateRoot, privateRootPath, privatePathComponents, withPrivateDirectoryAt, ensurePrivateDirectoryAt,
   removePrivateFileDurablyAt, publishPrivateCaptureAt, CapturePublication (..), PrivateCapture, privateCaptureBytes, privateCaptureSha256,
   WorkflowDescriptor (..), WorkflowInputDescriptor (..), frontendLiteralBytes,
   FrontendSetup (..), FrontendSetupRequest (..), FrontendInputSource (..), encodeFrontendSetupRequest,
   maxFrontendQueryBytes, FrontendManifest (..), RunRecord (..), RunOwnership (..),
   RunId (..), mkRunId, openPrivateSubroot, closePrivateRoot, privateRootIdentity,
   readRunRecordWithEnvelopesAt, revalidateLineageParentAt, readFrontendInputBytesBoundedAt,
   retainLineageInvocation, encodeFrontendManifest, FrontendPrepared (..))
import Control.DeepSeq (NFData)
import Control.Exception (IOException, SomeException, bracket, evaluate, throwIO, try)
import Control.Monad (forM, forM_, unless, when, void)
import Crypto.Hash (Context, Digest, SHA256, hash, hashInit, hashUpdate, hashFinalize)
import Crypto.Random (getRandomBytes)
import Data.Aeson (FromJSON, eitherDecodeStrict', fromJSON, Result (..), object, toJSON, (.=))
import Data.ByteArray (convert, constEq)
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import qualified Data.ByteString as BS
import Data.Int (Int64)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (find)
import Data.Maybe (catMaybes)
import qualified Data.Set as Set
import qualified Data.Map.Strict as Map
import Data.Time.Clock (getCurrentTime)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Text.Encoding.Error (strictDecode, UnicodeException)
import qualified Database.SQLite3 as SQL
import GHC.Generics (Generic)
import System.FilePath ((</>))
import System.IO (Handle, hClose)
import System.Posix.Files (getFdStatus, isRegularFile, fileOwner, fileMode, linkCount)
import System.Posix.IO (OpenMode (ReadOnly), OpenFileFlags (cloexec, nofollow, nonBlock), defaultFileFlags, openFdAt, closeFd, fdToHandle)
import System.Posix.User (getEffectiveUserID)
import Data.Bits ((.&.))
import System.Timeout (timeout)

-- | Reconcile only declared-equal draft/queue intent against current discovery.
-- Missing historical bindings remain inert. This creates no live approval or ticket.
reconcileDrafts :: CoordinationStore -> IO [AcceptedEnqueue]
reconcileDrafts store = page ""
  where
    page after = do
      identifiers <- runRead store $ do
        rows <- query "SELECT r.id FROM requests r JOIN request_restart_bindings b ON b.request_id=r.id WHERE r.id>? AND r.phase IN ('draft','queued') AND NOT EXISTS(SELECT 1 FROM reservations v WHERE v.request_id=r.id AND v.state!='released') ORDER BY r.id LIMIT 100" [text after]
        pure [ident | [SQL.SQLText ident] <- rows]
      eligible <- forM identifiers $ \ident -> do
        outcome <- draftIO(withStoreFiles store(\root -> timed 5000000(reconcile root ident)))
        case outcome of
          Right permits -> pure permits
          Left failure | failure `elem` [StaleRevision,InvalidInput,ResourceUnavailable,StateConflict] -> pure[]
          Left failure -> throwIO failure
      remaining <- case reverse identifiers of
        ident:_ -> page ident
        [] -> pure[]
      let permits=concat eligible<>remaining
      unless(length permits<=100)(throwIO SizeLimit)
      pure permits
    reconcile root ident = do
      let access=RestartAccess ident
      snapshot@(RequestState original client errors) <- runRead store(requestStateWith access ident [])
      binding <- runRead store $ do
        rows <- query "SELECT digest FROM request_restart_bindings WHERE request_id=?" [text ident]
        case rows of [[SQL.SQLText digest]] -> pure digest; _ -> refuseTransaction InvalidInput
      catalogues <- withStoreCatalogues store(\_ _ current -> pure current) >>= either(const(throwIO StorageUnavailable))pure
      catalogue <- maybe(throwIO ResourceUnavailable)pure(lookup(draftProfile original)catalogues)
      descriptor <- maybe(throwIO ResourceUnavailable)pure(lookup(draftWorkflow original)(discoveryEntries catalogue))
      unless(restartBinding catalogue descriptor==binding)(throwIO StaleRevision)
      let revised=original {draftProfileRevision=discoveryProfileRevision catalogue,draftDescriptorRevision=discoveryRevision catalogue}
          checked=RequestState revised client errors
      if draftPhase original=="queued" || draftParent original/=Nothing
        then void(assembleSnapshot store access root checked catalogue descriptor)
        else do
          inputs <- runRead store(inputStates ident)
          declarations <- mapM (requireEither . nativeDeclaration) inputs
          unless(declarations==workflowInputs descriptor)(throwIO InvalidInput)
          forM_ inputs $ \input@(InputState _ _ source _ _ _ _ capture) -> case source of
            Nothing -> pure()
            Just "literal" -> void(readLiteralWith store access snapshot [] input)
            Just "capture" -> do
              captureId' <- maybe(throwIO InvalidInput)pure capture
              captured <- runRead store(captureState ident captureId')
              void(verifyCapture root captured False)
            _ -> throwIO InvalidInput
      revision <- fresh "request_revision_"
      result <- withStoreCatalogues store $ \_ _ current -> do
        _ <- maybe(throwIO ResourceUnavailable)pure(lookup(draftProfile revised)current)
        _ <- either throwIO pure(selectCatalogue current (draftProfile revised) (draftProfileRevision revised) (draftWorkflow revised) (draftDescriptorRevision revised))
        runTransaction store $ do
          checkRevisionWith access snapshot []
          let changed=draftProfileRevision original/=draftProfileRevision revised || draftDescriptorRevision original/=draftDescriptorRevision revised
          when changed $ execute "UPDATE requests SET profile_revision=?,descriptor_revision=?,revision=? WHERE id=?" [text(draftProfileRevision revised),text(draftDescriptorRevision revised),text revision,text ident]
          (permits,associated) <- restoreAcceptedEnqueues ident
          when (associated && not changed) $ execute "UPDATE requests SET revision=? WHERE id=?" [text revision,text ident]
          pure(permits,[requestEvent ident revision | changed || associated])
      either(const(throwIO StorageUnavailable))pure result

holdingLimit :: Int64
holdingLimit = 67108864

-- | One bounded transactional observation, revalidated before materialization completes.
data RequestState = RequestState !DraftView !Text !BS.ByteString deriving (Generic, NFData)
requestView :: RequestState -> DraftView
requestView (RequestState view _ _) = view
requestOwner :: RequestState -> Text
requestOwner (RequestState _ owner _) = owner

data InputState = InputState !Text !BS.ByteString !(Maybe Text) !(Maybe Int64) !(Maybe Int64) !(Maybe Int64) !(Maybe BS.ByteString) !(Maybe Text)
  deriving (Generic, NFData)
data CaptureState = CaptureState !CaptureReceipt !Text !BS.ByteString deriving (Generic, NFData)

createDraft :: CoordinationStore -> CredentialProof -> Text -> BS.ByteString -> IO (Either CommandFailure DraftView)
createDraft store proof key body = draftIO $ do
  requestBody <- requireEither (decodeDraftBody body :: Either CommandFailure CreateDraft)
  ident <- fresh "request_"
  let request = CommandRequest Create (createProfile requestBody) "POST" "/v1/requests" key "application/json" Nothing body
      builder commandId limits catalogues = do
        (catalogue, descriptor) <- selectCatalogue catalogues (createProfile requestBody) (createProfileRevision requestBody)
          (createWorkflow requestBody) (createDescriptorRevision requestBody)
        declarations <- traverse publicDeclaration (workflowInputs descriptor)
        let names = map workflowInputName (workflowInputs descriptor)
            initial = DraftView ident ident (createWorkflow requestBody) (createDescriptorRevision requestBody)
              (createProfile requestBody) (createProfileRevision requestBody) "draft"
              (Readiness declarations [] names []) "not-queued" Nothing (if null names then [] else ["missing-inputs"]) Nothing Nothing Nothing Nothing
            initialBytes = encoded initial
        unless (length names<=256 && Set.size(Set.fromList names)==length names) (Left InvalidInput)
        unless (BS.length initialBytes<=1048576) (Left ViewTooLarge)
        pure $ Mutation (createProfileRevision requestBody) (pure Nothing) $ do
          client <- currentClient proof >>= requireTransaction
          checkDraftCapacity limits client
          pure $ Right $ Intent (noReferences {referenceRequest=Just ident}) False $ do
            execute "INSERT INTO requests (id,revision,client_id,workflow_id,descriptor_revision,profile_id,profile_revision,input_revision,phase,admission,blocking_reasons,validation_errors) VALUES (?,?,?,?,?,?,?,?,'draft','not-queued',?,?)"
              [text ident,text ident,text client,text(createWorkflow requestBody),text(createDescriptorRevision requestBody),text(createProfile requestBody),text(createProfileRevision requestBody),text ident,
               SQL.SQLBlob(encoded(draftReasons initial)),SQL.SQLBlob(encoded([]::[InputError]))]
            forM_ (groupsOf 32 (zip [0..] (workflowInputs descriptor))) $ \inputs ->
              execute ("INSERT INTO request_inputs (request_id,name,declaration_ordinal,declaration) VALUES " <> T.intercalate "," (replicate(length inputs) "(?,?,?,?)"))
                (concat [[text ident,text(workflowInputName input),SQL.SQLInteger ordinal,SQL.SQLBlob(encoded input)] | (ordinal,input)<-inputs])
            execute "INSERT INTO request_restart_bindings VALUES (?,?)" [text ident,text(restartBinding catalogue descriptor)]
            execute "INSERT INTO request_origins VALUES (?,?,?)" [text ident,text commandId,SQL.SQLBlob initialBytes]
            pure ([requestEvent ident ident], Nothing)
  submission <- submitConfiguredCommand store proof request builder >>= requireEither
  runRead store $ do
    client <- authorizeProfile proof (createProfile requestBody) [Submit] >>= requireTransaction
    rows <- query "SELECT o.view FROM request_origins o JOIN commands c ON c.id=o.command_id WHERE o.command_id=? AND c.client_id=? AND c.retired=0"
      [text(receiptId(submissionReceipt submission)),text client]
    case rows of [[SQL.SQLBlob value]] -> decodeTransaction value; _ -> refuseTransaction ResourceUnavailable

-- | Lineage creates an ordinary draft. Only the existing admission owner can enqueue it.
createLineageDraft :: CoordinationStore -> CredentialProof -> Text -> Text -> Maybe Text -> BS.ByteString -> IO (Either CommandFailure CommandReceipt)
createLineageDraft store proof parent key precondition body = draftIO $ do
  mutation <- requireEither (decodeDraftBody body :: Either CommandFailure LineageMutation)
  when (BS.length (encoded mutation) > 524288) (throwIO ViewTooLarge)
  (profile,_,_) <- runRead store $ do
    address@(profile,_,_) <- parentAddress parent
    _ <- authorizeProfile proof profile [Observe,Submit] >>= requireTransaction
    pure address
  let operation = case mutation of RestartParent -> Restart; ResumeParent -> Resume; ForkParent _ -> Fork
      uri = "/v1/runs/" <> parent <> "/lineage-requests"
      request = CommandRequest operation profile "POST" uri key "application/json" precondition body
      version = do
        rows <- query "SELECT revision FROM runs WHERE id=?" [text parent]
        pure $ case rows of [[SQL.SQLText revision]] -> Just (uri,profile,revision); _ -> Nothing
  replay <- commandPreflightVersion store proof request version >>= requireEither
  if replay then submissionReceipt <$> (submitConfiguredCommand store proof request (\_ _ _ -> Left StateConflict) >>= requireEither)
  else withStoreFiles store $ \root -> timed 5000000 $ do
    configured <- withStoreCatalogues store $ \_ _ catalogues -> case lookup profile catalogues of
      Just catalogue -> pure catalogue
      Nothing -> throwIO StaleRevision
    catalogue <- either (const (throwIO StorageUnavailable)) pure configured
    let selection = discoverySelection catalogue
        policy = selectionContext selection
    record <- readParent store root parent selection
    let manifest = recordManifest record
    (workflow,descriptor) <- case [(ident,descriptor) | (ident,descriptor) <- discoveryEntries catalogue, workflowName descriptor == frontendWorkflow manifest] of
      [entry] -> pure entry
      _ -> throwIO StaleRevision
    _ <- parentInputs root record descriptor
    ident <- fresh "request_"
    parentRevision <- fresh "run_revision_"
    let profileRevision = discoveryProfileRevision catalogue
        descriptorRevision = discoveryRevision catalogue
        initial = DraftView ident ident workflow descriptorRevision profile profileRevision "draft" (Readiness [] [] [] []) "not-queued" Nothing [] Nothing Nothing (Just parent) (Just (operationName operation))
        builder commandId limits catalogues = do
          _ <- selectCatalogue catalogues profile profileRevision workflow descriptorRevision
          pure $ Mutation profileRevision version $ do
            _ <- authorizeProfile proof profile [Observe,Submit] >>= requireTransaction
            checkLineageParent parent
            client <- currentClient proof >>= requireTransaction
            checkDraftCapacity limits client
            pure $ Right $ Intent (noReferences {referenceRequest=Just ident,referenceRun=Just parent}) False $ do
              execute "INSERT INTO requests (id,revision,client_id,workflow_id,descriptor_revision,profile_id,profile_revision,input_revision,phase,admission,blocking_reasons,validation_errors,parent_run_id,lineage_operation,lineage_edits) VALUES (?,?,?,?,?,?,?,?,'draft','not-queued',?,?,?,?,?)"
                [text ident,text ident,text client,text workflow,text descriptorRevision,text profile,text profileRevision,text ident,
                 SQL.SQLBlob(encoded ([]::[Text])),SQL.SQLBlob(encoded ([]::[InputError])),text parent,text(operationName operation),SQL.SQLBlob(encoded mutation)]
              execute "INSERT INTO request_restart_bindings VALUES (?,?)" [text ident,text(restartBinding catalogue descriptor)]
              execute "INSERT INTO request_lineage VALUES (?,?)" [text ident,SQL.SQLBlob(encodeFrontendManifest manifest)]
              execute "INSERT INTO request_origins VALUES (?,?,?)" [text ident,text commandId,SQL.SQLBlob(encoded initial)]
              effect <- requireTransaction $ case fromJSON (object ["kind" .= ("lineage-created"::Text),"resource" .= requestURI ident,"runtimeSequence" .= (Nothing::Maybe Text),"address" .= (Nothing::Maybe Text)]) of
                Success value -> Right value
                Error _ -> Left InvalidRequest
              execute "UPDATE runs SET revision=? WHERE id=?" [text parentRevision,text parent]
              pure ([requestEvent ident ident,Invalidation "run.changed" uri parentRevision],Just effect)
    when (BS.length (encodeFrontendManifest manifest) > 1048576) (throwIO ViewTooLarge)
    unless (operatorId policy == profile) (throwIO StaleRevision)
    submissionReceipt <$> (submitConfiguredCommand store proof request builder >>= requireEither)

-- | Complete bounded child-request collection, not an HTTP page-set implementation.
withLineageRequests :: CoordinationStore -> CredentialProof -> Text -> ([DraftView] -> IO ()) -> IO ()
withLineageRequests store proof parent respond = do
  (profile,revision,idents) <- runRead store $ do
    (profile,_,_) <- parentAddress parent
    _ <- authorizeProfile proof profile [Observe] >>= requireTransaction
    versions <- query "SELECT revision FROM runs WHERE id=?" [text parent]
    revision <- case versions of [[SQL.SQLText value]] -> pure value; _ -> refuseTransaction ResourceUnavailable
    rows <- query "SELECT id FROM requests WHERE parent_run_id=? ORDER BY id LIMIT 257" [text parent]
    when (length rows > 256) (refuseTransaction ViewTooLarge)
    idents <- mapM (\row -> case row of [SQL.SQLText ident] -> pure ident; _ -> refuseTransaction StorageUnavailable) rows
    pure (profile,revision,idents)
  views <- mapM (\ident -> readDraft store proof ident >>= requireEither) idents
  when (BS.length(encoded views) > 1048576) (throwIO ViewTooLarge)
  runRead store $ do
    _ <- authorizeProfile proof profile [Observe] >>= requireTransaction
    versions <- query "SELECT revision FROM runs WHERE id=?" [text parent]
    unless (versions == [[text revision]]) (refuseTransaction StaleRevision)
  respond views

parentAddress :: Text -> Transaction (Text,Text,Text)
parentAddress parent = do
  rows <- query "SELECT profile_id,root_identity,native_run_id FROM runs WHERE id=?" [text parent]
  case rows of
    [[SQL.SQLText profile,SQL.SQLText root,SQL.SQLText native]] -> pure (profile,root,native)
    _ -> refuseTransaction ResourceUnavailable

-- | Durable conflicts are refusals, never a reconstructed ownership capability.
checkLineageParent :: Text -> Transaction ()
checkLineageParent parent = do
  rows <- query "SELECT u.supervision,v.state FROM runs u LEFT JOIN start_intents i ON i.run_id=u.id LEFT JOIN reservations v ON v.id=i.reservation_id WHERE u.id=?" [text parent]
  case rows of
    [[SQL.SQLText supervision,state]] -> unless (supervision /= "cleanup-pending" && (state == text "released" || (supervision `elem` ["observer","lost"] && state == SQL.SQLNull))) (refuseTransaction OwnershipUnavailable)
    _ -> refuseTransaction ResourceUnavailable

readParent :: CoordinationStore -> PrivateRoot -> Text -> Selection -> IO RunRecord
readParent store root parent selection = do
  (profile,identity,native) <- runRead store (checkLineageParent parent >> parentAddress parent)
  unless (operatorId (selectionContext selection) == profile && not (operatorQuarantined (selectionContext selection))) (throwIO OwnershipUnavailable)
  nativeId <- either (const (throwIO ResourceUnavailable)) pure (mkRunId native)
  bracket (openPrivateSubroot root ["runs"]) closePrivateRoot $ \runs -> do
    unless (T.pack (privateRootIdentity runs) == identity) (throwIO OwnershipUnavailable)
    now <- getCurrentTime
    record <- withPrivateDirectoryAt runs ["runs",T.unpack native] $ \fd ->
      fst <$> readRunRecordWithEnvelopesAt (privateRootPath runs </> "runs" </> T.unpack native) fd Nothing now
    unless (frontendRunId (recordManifest record) == nativeId && recordOwnership record /= RunOwnedElsewhere) (throwIO OwnershipUnavailable)
    _ <- either (const (throwIO StateConflict)) pure (retainLineageInvocation (recordManifest record) (Just(selectionInvocation selection)))
    withPrivateDirectoryAt runs ["runs",T.unpack native] (revalidateLineageParentAt record)
    pure record

parentInputs :: PrivateRoot -> RunRecord -> WorkflowDescriptor -> IO [ReviewInput]
parentInputs root record descriptor = do
  let names = map workflowInputName (workflowInputs descriptor)
      native = T.unpack (runIdText (frontendRunId (recordManifest record)))
  captured <- withPrivateDirectoryAt root ["runs","runs",native] $ \fd -> readFrontendInputBytesBoundedAt 67108864 record fd names
  pure [ReviewInput name "capture" (T.pack(show(BS.length bytes))) (T.pack(show(hash bytes::Digest SHA256))) | name <- names, let bytes = captured Map.! name]

changeDraftInput :: CoordinationStore -> CredentialProof -> Text -> Text -> Maybe Text -> BS.ByteString -> IO (Either CommandFailure CommandReceipt)
changeDraftInput store proof ident key precondition body = fmap (fmap submissionReceipt) $
  changeDraftInputGuarded store proof ident key precondition body (\_ limits current _ -> do
    editable current
    let RequestState view owner _ = current
    when(draftPhase view=="queued")(checkDraftCapacity limits owner)
    pure(InputTransition "draft" "not-queued" False [])) (submitConfiguredCommand store proof)

-- | A source-owned admission transition checked in the same command transaction.
data InputTransition = InputTransition !Text !Text !Bool ![Invalidation]

changeDraftInputGuarded :: CoordinationStore -> CredentialProof -> Text -> Text -> Maybe Text -> BS.ByteString
  -> (Text -> ConfigurationLimits -> RequestState -> Text -> Transaction InputTransition)
  -> (CommandRequest -> (Text -> ConfigurationLimits -> [(Text, Discovery)] -> Either CommandFailure Mutation) -> IO (Either CommandFailure Submission))
  -> IO (Either CommandFailure Submission)
changeDraftInputGuarded store proof ident key precondition body transition submit = draftIO $ withStoreFiles store $ \root -> timed 5000000 $ do
  change <- requireEither (decodeDraftBody body :: Either CommandFailure InputChange)
  original@(RequestState view _ _) <- runRead store (requestState proof ident [Submit])
  unless (draftParent view == Nothing) (throwIO InvalidInput)
  let operation = case change of SetBinding _ -> SetInput; RemoveBinding _ -> RemoveInput
      request = CommandRequest operation (draftProfile view) "POST" (requestURI ident) key "application/json" precondition body
  replay <- commandPreflight store proof request (\_ _ _ exists -> pure (exists,[])) >>= requireEither
  if replay then submit request (\_ _ _ -> Left StateConflict) >>= requireEither
    else changeFresh root store proof original request change transition submit

changeFresh :: PrivateRoot -> CoordinationStore -> CredentialProof -> RequestState -> CommandRequest -> InputChange -> (Text -> ConfigurationLimits -> RequestState -> Text -> Transaction InputTransition) -> (CommandRequest -> (Text -> ConfigurationLimits -> [(Text, Discovery)] -> Either CommandFailure Mutation) -> IO (Either CommandFailure Submission)) -> IO Submission
changeFresh root store proof original@(RequestState view _ _) request change transition submit = do
  let ident=draftId view
  revision <- fresh "request_revision_"
  let name = case change of SetBinding value -> suppliedName value; RemoveBinding value -> value
  inputs <- runRead store (inputStates ident)
  input <- maybe (throwIO InvalidInput) pure (find ((==name).inputStateName) inputs)
  literal <- case change of
    SetBinding (LiteralValue _ value) -> do
      declaration <- requireEither (nativeDeclaration input)
      pure (Just (TE.encodeUtf8 value, fromIntegral (BS.length (frontendLiteralBytes (workflowInputSource declaration) value))))
    _ -> pure Nothing
  verified <- case change of
    SetBinding (CapturedValue _ cap) -> do
      capture <- runRead store (captureState ident cap)
      _ <- verifyCapture root capture False
      pure (Just capture)
    _ -> pure Nothing
  let builder commandId limits catalogues = do
        _ <- selectCatalogue catalogues (draftProfile view) (draftProfileRevision view) (draftWorkflow view) (draftDescriptorRevision view)
        pure $ Mutation (draftProfileRevision view) (currentVersion proof ident) $ do
          current <- requestState proof ident [Submit]
          InputTransition nextPhase nextAdmission dispatch extraEvents <- transition commandId limits current revision
          allInputs <- inputStates ident
          unless (any ((==name).inputStateName) allInputs) (refuseTransaction InvalidInput)
          client <- currentClient proof >>= requireTransaction
          case verified of
            Just (CaptureState capture uploader _) -> do
              unless (client==uploader) (refuseTransaction Forbidden)
              actual <- captureState ident (captureId capture)
              unless (sameCapture actual (CaptureState capture uploader (TE.encodeUtf8(captureId capture)))) (refuseTransaction InvalidInput)
            Nothing -> pure ()
          let replacement = fmap (\(bytes,native) -> (fromIntegral(BS.length bytes),native)) literal
          checkInputReplacement ident name replacement verified
          pure $ Right $ Intent (noReferences {referenceRequest=Just ident}) dispatch $ do
            execute "DELETE FROM request_literal_chunks WHERE request_id=? AND name=?" [text ident,text name]
            case change of
              RemoveBinding _ -> execute "UPDATE request_inputs SET source=NULL,literal_bytes=NULL,literal_transport_bytes=NULL,literal_chunks=NULL,literal_digest=NULL,capture_id=NULL WHERE request_id=? AND name=?" [text ident,text name]
              SetBinding (CapturedValue _ cap) -> execute "UPDATE request_inputs SET source='capture',literal_bytes=NULL,literal_transport_bytes=NULL,literal_chunks=NULL,literal_digest=NULL,capture_id=? WHERE request_id=? AND name=?" [text cap,text ident,text name]
              SetBinding (LiteralValue _ _) -> do
                (bytes,native)<-maybe (refuseTransaction InvalidInput) pure literal
                let parts=byteChunks bytes
                    digest=convert(hash bytes::Digest SHA256)::BS.ByteString
                execute "UPDATE request_inputs SET source='literal',literal_bytes=?,literal_transport_bytes=?,literal_chunks=?,literal_digest=?,capture_id=NULL WHERE request_id=? AND name=?"
                  [integer(BS.length bytes),SQL.SQLInteger native,integer(length parts),SQL.SQLBlob digest,text ident,text name]
                forM_ (zip [0..] parts) $ \(ordinal,bytes') -> execute "INSERT INTO request_literal_chunks VALUES (?,?,?,?)" [text ident,text name,SQL.SQLInteger ordinal,SQL.SQLBlob bytes']
            execute "UPDATE requests SET revision=?,input_revision=?,phase=?,admission=?,queue_ordinal=NULL,queue_origin_revision=NULL,queue_generation=NULL,blocking_reasons=?,validation_errors=? WHERE id=?"
              [text revision,text revision,text nextPhase,text nextAdmission,SQL.SQLBlob(encoded([]::[Text])),SQL.SQLBlob(encoded([]::[InputError])),text ident]
            effect <- decodeTransaction (encoded(object ["kind" .= ("input-changed"::Text),"runtimeSequence" .= (Nothing::Maybe Text),"address" .= (Nothing::Maybe Text),"resource" .= requestURI ident]))
            pure (requestEvent ident revision : extraEvents,if dispatch then Nothing else Just effect)
  ensureRevision store proof original [Submit]
  submit request builder >>= requireEither

uploadCapture :: CoordinationStore -> CredentialProof -> Text -> Text -> Int64 -> IO BS.ByteString -> IO (Either CommandFailure CaptureReceipt)
uploadCapture store proof ident key ceilingBytes source = draftIO $ withStoreFiles store $ \root -> do
  unless (ceilingBytes>=0 && ceilingBytes<=holdingLimit) (throwIO SizeLimit)
  RequestState view _ _ <- runRead store (requestState proof ident [Submit])
  unless (draftParent view == Nothing) (throwIO InvalidInput)
  capId <- fresh "capture_"
  generation <- storeProcessGeneration <$> storeIdentity store
  let request = CommandRequest Capture (draftProfile view) "POST" ("/v1/captures?requestId="<>ident) key "application/octet-stream" Nothing BS.empty
  existing <- commandPreflight store proof request (\limits catalogues client replay -> do
    if replay then pure (True,[]) else do
      _ <- requireTransaction (selectCatalogue catalogues (draftProfile view) (draftProfileRevision view) (draftWorkflow view) (draftDescriptorRevision view))
      current <- requestState proof ident [Submit]
      editable current
      checkUploadCapacity limits ident ceilingBytes
      execute "INSERT INTO capture_uploads(id,request_id,client_id,profile_id,profile_revision,process_generation,reserved_bytes,created_at,state) VALUES (?,?,?,?,?,?,?,strftime('%Y-%m-%dT%H:%M:%fZ','now'),'pending')"
        [text capId,text ident,text client,text(draftProfile view),text(draftProfileRevision view),text generation,SQL.SQLInteger ceilingBytes]
      pure (False,[Invalidation "service.changed" "/v1/capabilities" capId])) >>= requireEither
  checkedSource <- utf8Source ceilingBytes source
  let collect input = do bytes <- input; unless (BS.null bytes) (collect input)
  if existing then do
    (_, binding) <- timed 30000000 (measureCommandBody Capture checkedSource collect)
    verifiedBody <- maybe (throwIO InvalidInput) pure binding
    finishCapture store proof request view capId Nothing verifiedBody
  else do
    ensurePrivateDirectoryAt root ["captures"]
    outcome <- try @SomeException $ timed 30000000 $ measureCommandBody Capture checkedSource $ \input ->
      publishPrivateCaptureAt root ["captures",T.unpack capId] (fromIntegral ceilingBytes) input
    case outcome of
      Left failure -> do
        void (try @SomeException (markOrphan store capId))
        throwIO failure
      Right (CaptureNotPublished _, _) -> do
        releaseUpload store capId
        throwIO StorageUnavailable
      Right (CaptureUnconfirmed _ _, _) -> markOrphan store capId >> throwIO StorageUnavailable
      Right (CapturePublished publication, binding) -> do
        verifiedBody <- maybe (throwIO StorageUnavailable) pure binding
        unless (privateCaptureBytes publication==fromIntegral(bodyBindingBytes verifiedBody)
          && privateCaptureSha256 publication==bodyBindingSha256 verifiedBody) (markOrphan store capId >> throwIO StorageUnavailable)
        result <- try @SomeException $ do
          runTransaction store $ do
            execute "UPDATE capture_uploads SET published_bytes=?,published_sha256=? WHERE id=? AND state='pending'"
              [integer(bodyBindingBytes verifiedBody),text(bodyBindingSha256 verifiedBody),text capId]
            pure((),[Invalidation "service.changed" "/v1/capabilities" capId])
          finishCapture store proof request view capId (Just publication) verifiedBody
        case result of
          Left failure -> void(try @SomeException(markOrphan store capId)) >> throwIO failure
          Right receipt -> pure receipt

finishCapture :: CoordinationStore -> CredentialProof -> CommandRequest -> DraftView -> Text -> Maybe PrivateCapture -> BodyBinding -> IO CaptureReceipt
finishCapture store proof request view capId publication binding = do
  let ident=draftId view
      builder commandId limits catalogues = do
        _ <- selectCatalogue catalogues (draftProfile view) (draftProfileRevision view) (draftWorkflow view) (draftDescriptorRevision view)
        unless (publication/=Nothing) (Left StateConflict)
        pure $ Mutation (draftProfileRevision view) (pure Nothing) $ do
          current <- requestState proof ident [Submit]
          editable current
          client <- currentClient proof >>= requireTransaction
          reservations <- query "SELECT client_id,profile_id,profile_revision,reserved_bytes FROM capture_uploads WHERE id=? AND request_id=?"
            [text capId,text ident]
          case reservations of
            [[SQL.SQLText owner,SQL.SQLText profile,SQL.SQLText revision,SQL.SQLInteger reserved]] ->
              unless(owner==client && profile==draftProfile view && revision==draftProfileRevision view && fromIntegral(bodyBindingBytes binding)<=reserved) (refuseTransaction StateConflict)
            _ -> refuseTransaction StateConflict
          capacity <- query "SELECT coalesce((SELECT sum(bytes) FROM captures),0)+coalesce((SELECT sum(reserved_bytes) FROM capture_uploads WHERE id!=?),0)+?" [text capId,integer(bodyBindingBytes binding)]
          unless (case capacity of [[SQL.SQLInteger used]] -> used<=fromIntegral(limitGlobalCaptureBytes limits); _ -> False) (refuseTransaction StorageQuota)
          pure $ Right $ Intent (noReferences {referenceRequest=Just ident}) False $ do
            execute "INSERT INTO captures(id,revision,request_id,client_id,profile_id,private_reference,bytes,sha256) VALUES (?,?,?,?,?,?,?,?)"
              [text capId,text capId,text ident,text client,text(draftProfile view),SQL.SQLBlob(TE.encodeUtf8 capId),integer(bodyBindingBytes binding),text(bodyBindingSha256 binding)]
            execute "INSERT INTO command_captures VALUES (?,?)" [text commandId,text capId]
            execute "DELETE FROM capture_uploads WHERE id=?" [text capId]
            pure ([Invalidation "service.changed" "/v1/capabilities" capId],Nothing)
  submission <- submitStreamedCommand store proof request binding builder >>= requireEither
  runRead store $ do
    _ <- authorizeProfile proof (draftProfile view) [Submit] >>= requireTransaction
    rows <- query "SELECT c.id FROM command_captures l JOIN captures c ON c.id=l.capture_id WHERE l.command_id=? AND c.request_id=?"
      [text(receiptId(submissionReceipt submission)),text ident]
    case rows of
      [[SQL.SQLText actual]] -> do CaptureState receipt _ _ <- captureState ident actual; pure receipt
      _ -> refuseTransaction ResourceUnavailable

-- | Examine at most sixteen recorded identities under the original file owner.
-- Unknown files and unconfirmed publications are never candidates. A durable
-- upload row retains quota and provenance across an interrupted unlink.
collectCaptures :: CoordinationStore -> Text -> IO (Either CommandFailure (Maybe Text))
collectCaptures store after = draftIO $ withStoreFiles store $ \root -> timed 5000000 $ do
  candidates <- runRead store $ do
    rows <- query "SELECT id,request_id,profile_id,bytes,sha256,0 FROM captures WHERE id>? AND private_reference=CAST(id AS BLOB) UNION ALL SELECT id,request_id,profile_id,published_bytes,published_sha256,1 FROM capture_uploads WHERE id>? AND state='orphan' AND published_bytes IS NOT NULL AND published_sha256 IS NOT NULL ORDER BY id LIMIT 16" [text after,text after]
    forM rows $ \row -> case row of
      [SQL.SQLText ident,SQL.SQLText request,SQL.SQLText profile,SQL.SQLInteger bytes,SQL.SQLText digest,SQL.SQLInteger orphan] -> pure(ident,request,profile,bytes,digest,orphan==1)
      _ -> refuseTransaction StorageUnavailable
  forM_ candidates $ \(ident,request,profile,bytes,digest,orphan) -> do
    let table=if orphan then "capture_uploads" else "captures"
        eligible = do
          inactive <- if orphan then pure True else requestInactive request
          rows <- query "SELECT NOT EXISTS(SELECT 1 FROM request_inputs WHERE capture_id=?) AND NOT EXISTS(SELECT 1 FROM preparation_captures WHERE capture_id=?) AND NOT EXISTS(SELECT 1 FROM command_captures cc JOIN commands c ON c.id=cc.command_id WHERE cc.capture_id=? AND c.retired=0) AND NOT EXISTS(SELECT 1 FROM retention_pending_commands WHERE request_id=?) AND NOT EXISTS(SELECT 1 FROM requests child JOIN runs parent ON child.parent_run_id=parent.id WHERE parent.request_id=?) AND NOT EXISTS(SELECT 1 FROM restoration_quarantine) AND (?=0 OR NOT EXISTS(SELECT 1 FROM captures WHERE id=?))" [text ident,text ident,text ident,text request,text request,SQL.SQLInteger(if orphan then 1 else 0),text ident]
          pure(inactive && rows==[[SQL.SQLInteger 1]])
        event=Invalidation "service.changed" "/v1/capabilities" ident
    ready <- runTransaction store $ do
      allowed <- eligible
      rows <- query ("SELECT collection_since,collection_since<=unixepoch()-86400 FROM "<>table<>" WHERE id=?") [text ident]
      case rows of
        [[since,aged]]
          | not allowed -> case since of
              SQL.SQLNull -> pure(False,[])
              _ -> execute ("UPDATE "<>table<>" SET collection_since=NULL WHERE id=?") [text ident] >> pure(False,[event])
          | since==SQL.SQLNull -> execute ("UPDATE "<>table<>" SET collection_since=unixepoch() WHERE id=?") [text ident] >> pure(False,[event])
          | otherwise -> pure(aged==SQL.SQLInteger 1,[])
        _ -> refuseTransaction StateConflict
    when ready $ do
      _ <- verifyCapture root (CaptureState (CaptureReceipt ident request profile bytes digest) "" (TE.encodeUtf8 ident)) False
      runTransaction store $ do
        allowed <- eligible
        age <- query ("SELECT collection_since<=unixepoch()-86400 FROM "<>table<>" WHERE id=?") [text ident]
        current <- if orphan
          then query "SELECT request_id,profile_id,published_bytes,published_sha256 FROM capture_uploads WHERE id=? AND state='orphan'" [text ident]
          else query "SELECT request_id,profile_id,bytes,sha256 FROM captures WHERE id=? AND private_reference=CAST(id AS BLOB)" [text ident]
        unless (allowed && age==[[SQL.SQLInteger 1]] && current==[[text request,text profile,SQL.SQLInteger bytes,text digest]]) (refuseTransaction StateConflict)
        unless orphan $ do
          generation <- transactionGeneration
          execute "INSERT INTO capture_uploads(id,request_id,client_id,profile_id,profile_revision,process_generation,reserved_bytes,created_at,state,collection_since,published_bytes,published_sha256) SELECT c.id,c.request_id,c.client_id,c.profile_id,r.profile_revision,?,c.bytes,strftime('%Y-%m-%dT%H:%M:%fZ','now'),'orphan',c.collection_since,c.bytes,c.sha256 FROM captures c JOIN requests r ON r.id=c.request_id WHERE c.id=?" [text generation,text ident]
          execute "DELETE FROM command_captures WHERE capture_id=? AND command_id IN (SELECT id FROM commands WHERE retired=1)" [text ident]
          execute "DELETE FROM captures WHERE id=?" [text ident]
        pure((),if orphan then [] else [event])
      removePrivateFileDurablyAt root ["captures",T.unpack ident]
      releaseUpload store ident
  pure(case reverse candidates of (ident,_,_,_,_,_):_ -> Just ident; _ -> Nothing)

readDraft :: CoordinationStore -> CredentialProof -> Text -> IO (Either CommandFailure DraftView)
readDraft store proof ident = draftIO $ withStoreFiles store $ \root -> timed 5000000 $ do
  snapshot@(RequestState view _ _) <- runRead store (requestState proof ident [Observe])
  inputs <- runRead store (inputStates ident)
  lower <- pure (sum [n | InputState _ _ (Just "literal") (Just n) _ _ _ _ <- inputs])
  when(lower>1048576) (throwIO ViewTooLarge)
  let declarationResults=[(inputStateName input,nativeDeclaration input >>= publicDeclaration)|input<-inputs]
      invalidDeclarations=[InputError name "invalid-input"|(name,Left _)<-declarationResults]
  unless(null invalidDeclarations) $ do
    _<-persistErrors store proof snapshot invalidDeclarations view
    throwIO InvalidInput
  declarations <- mapM (requireEither . snd) declarationResults
  originalDeclarations <- runRead store $ do
    rows <- query "SELECT view FROM request_origins WHERE request_id=?" [text ident]
    case rows of
      [[SQL.SQLBlob bytes]] -> do
        origin <- decodeTransaction bytes
        let Readiness declared _ _ _ = draftReadiness origin
        pure (Just declared)
      [] -> pure Nothing
      _ -> refuseTransaction InvalidInput
  case originalDeclarations of
    Just declared -> unless (declared==declarations) (throwIO InvalidInput)
    Nothing -> throwIO InvalidInput
  pairs <- forM inputs $ \input@(InputState name _ representation _ _ _ _ capture) -> case representation of
    Nothing -> pure (Nothing,Nothing)
    Just "literal" -> do
      decoded <- try @CommandFailure (readLiteral store proof snapshot [Observe] input)
      case decoded of
        Right value -> pure (Just(LiteralValue name value),Nothing)
        Left InvalidInput -> pure (Nothing,Just(InputError name "invalid-input"))
        Left failure -> throwIO failure
    Just "capture" -> do
      cap <- maybe (throwIO InvalidInput) pure capture
      verified <- try @CommandFailure $ do value <- runRead store(captureState ident cap); void(verifyCapture root value False)
      pure (Just(CapturedValue name cap),case verified of Left _ -> Just(InputError name "capture-unavailable"); Right () -> Nothing)
    _ -> throwIO InvalidInput
  let supplied=catMaybes(map fst pairs)
      errors=catMaybes(map snd pairs)
      missing=[name | InputDeclaration name _ <- declarations,name `notElem` map suppliedName supplied]
      readiness=Readiness declarations supplied missing errors
      result=view {draftReadiness=readiness,draftReasons=filter (/="missing-inputs") (draftReasons view) <> if null missing then [] else ["missing-inputs"]}
  unless(BS.length(encoded result)<=1048576) (throwIO ViewTooLarge)
  ensureRevision store proof snapshot [Observe]
  updated <- persistErrors store proof snapshot errors result
  when (any (\(InputError _ code)->code=="invalid-input") errors) (throwIO InvalidInput)
  pure updated

-- | A bounded materialization snapshot, not permission to start a worker.
data DraftAssembly = DraftAssembly
  { assemblyRequest :: !Text, assemblyRevision :: !Text, assemblyProfile :: !Text,
    assemblyProfileRevision :: !Text, assemblySetup :: !FrontendSetupRequest,
    assemblyFrame :: !BS.ByteString, assemblyInputSummaries :: ![ReviewInput],
    assemblySelection :: !Selection, assemblyDescriptor :: !WorkflowDescriptor,
    assemblyParent :: !(Maybe (Text,FrontendManifest)) }

assemblyParentBinding :: DraftAssembly -> Maybe BS.ByteString
assemblyParentBinding = fmap (encodeFrontendManifest . snd) . assemblyParent

-- | Recheck the accepted parent, not a new parent selected by the native reply.
validateAssemblyParent :: CoordinationStore -> DraftAssembly -> FrontendPrepared -> IO ()
validateAssemblyParent store assembly prepared = case assemblyParent assembly of
  Nothing -> pure ()
  Just (parent,expected) -> withStoreFiles store $ \root -> do
    record <- readParent store root parent (assemblySelection assembly)
    unless (recordManifest record == expected && preparedDescriptor prepared == assemblyDescriptor assembly
      && workflowName (preparedDescriptor prepared) == frontendWorkflow expected) (throwIO StateConflict)
    summaries <- parentInputs root record (assemblyDescriptor assembly)
    unless (summaries == assemblyInputSummaries assembly) (throwIO StateConflict)

data DraftAccess = ClientAccess !CredentialProof | AcceptedAccess !AcceptedEnqueue | RestartAccess !Text

assembleDraft :: CoordinationStore -> CredentialProof -> Text -> IO (Either CommandFailure (FrontendSetupRequest, BS.ByteString))
assembleDraft store proof ident = fmap (fmap (\snapshot -> (assemblySetup snapshot,assemblyFrame snapshot))) (assembleDraftSnapshot store proof ident)

assembleDraftSnapshot :: CoordinationStore -> CredentialProof -> Text -> IO (Either CommandFailure DraftAssembly)
assembleDraftSnapshot store proof = assembleWith store (ClientAccess proof)

assembleAcceptedDraft :: CoordinationStore -> AcceptedEnqueue -> IO (Either CommandFailure DraftAssembly)
assembleAcceptedDraft store permit = assembleWith store (AcceptedAccess permit) (acceptedRequest permit)

assembleWith :: CoordinationStore -> DraftAccess -> Text -> IO (Either CommandFailure DraftAssembly)
assembleWith store access ident = draftIO $ withStoreFiles store $ \root -> timed 5000000 $ do
  snapshot@(RequestState view _ _) <- runRead store(requestStateWith access ident [Submit])
  (catalogue,descriptor) <- currentCatalogue store access view
  assembleSnapshot store access root snapshot catalogue descriptor

assembleSnapshot :: CoordinationStore -> DraftAccess -> PrivateRoot -> RequestState -> Discovery -> WorkflowDescriptor -> IO DraftAssembly
assembleSnapshot store access root snapshot@(RequestState view _ _) catalogue descriptor = do
  let ident=draftId view
  case draftParent view of
    Nothing -> assembleRoot store access root snapshot catalogue descriptor
    Just parent -> do
      let selection = discoverySelection catalogue
          policy = selectionContext selection
      expected <- runRead store $ do
        rows <- query "SELECT parent_manifest FROM request_lineage WHERE request_id=?" [text ident]
        case rows of [[SQL.SQLBlob manifest]] -> pure manifest; _ -> refuseTransaction InvalidInput
      mutation <- runRead store $ do
        rows <- query "SELECT lineage_edits FROM requests WHERE id=?" [text ident]
        case rows of [[SQL.SQLBlob edits]] -> pure edits; _ -> refuseTransaction InvalidInput
      record <- readParent store root parent selection
      unless (encodeFrontendManifest (recordManifest record) == expected) (throwIO StateConflict)
      edits <- requireEither (decodeDraftBody mutation :: Either CommandFailure LineageMutation)
      summaries <- parentInputs root record descriptor
      let setup = DerivedSetup (privateRootPath root </> "runs") (frontendRunId(recordManifest record))
            (lineageOperation edits) (lineageEdits edits) (operatorPersonAnswering policy) (Just(selectionInvocation selection))
      frame <- either (const (throwIO SizeLimit)) pure (encodeFrontendSetupRequest setup)
      runRead store (checkRevisionWith access snapshot [Submit])
      _ <- currentCatalogue store access view
      pure (DraftAssembly ident (draftRevision view) (draftProfile view) (draftProfileRevision view) setup frame summaries selection descriptor (Just(parent,recordManifest record)))

assembleRoot :: CoordinationStore -> DraftAccess -> PrivateRoot -> RequestState -> Discovery -> WorkflowDescriptor -> IO DraftAssembly
assembleRoot store access root snapshot@(RequestState view _ _) catalogue descriptor = do
  let ident = draftId view
  inputs <- runRead store(inputStates ident)
  let selection=discoverySelection catalogue
      policy=selectionContext selection
  declarations <- mapM (requireEither . nativeDeclaration) inputs
  unless(declarations==workflowInputs descriptor) (throwIO InvalidInput)
  ensureReadyTotal store ident
  let literalTotal=sum[n | InputState _ _ (Just "literal") (Just n) _ _ _ _ <- inputs]
  when(literalTotal>fromIntegral maxFrontendQueryBytes) (throwIO SizeLimit)
  resolved <- forM inputs $ \input@(InputState name _ representation _ _ _ _ capId) -> case representation of
    Just "literal" -> do
      value<-readLiteralWith store access snapshot [Submit] input
      declaration<-requireEither(nativeDeclaration input)
      let bytes=frontendLiteralBytes(workflowInputSource declaration)value
          summary=ReviewInput name "literal" (T.pack(show(BS.length bytes))) (T.pack(show(hash bytes::Digest SHA256)))
      pure ((name,Literal value),Nothing,summary)
    Just "capture" -> do
      cap<-maybe(throwIO InvalidInput)pure capId
      capture@(CaptureState receipt _ _)<-runRead store(captureState ident cap)
      content<-verifyCapture root capture (captureBytes receipt<=fromIntegral maxFrontendQueryBytes)
      let path=privateRootPath root </> "captures" </> T.unpack cap
      pure ((name,maybe(File path)Transport content),Just path,ReviewInput name "capture" (T.pack(show(captureBytes receipt))) (captureDigest receipt))
    _ -> throwIO InvalidInput
  ensurePrivateDirectoryAt root ["runs"]
  let setup values=RootSetup(FrontendSetup (workflowName descriptor) (privateRootPath root </> "runs")
        (operatorTargetArguments policy) Nothing (operatorPersonAnswering policy) values (Just(selectionInvocation selection)))
      inline=setup[values | (values,_,_)<-resolved]
      files=setup[(name,maybe source File path) | ((name,source),path,_)<-resolved]
      result=case encodeFrontendSetupRequest inline of Right bytes -> Right(inline,bytes); Left _ -> case encodeFrontendSetupRequest files of Right bytes -> Right(files,bytes); Left _ -> Left SizeLimit
  value<-requireEither result
  runRead store (checkRevisionWith access snapshot [Submit])
  _<-currentCatalogue store access view
  pure (DraftAssembly ident (draftRevision view) (draftProfile view) (draftProfileRevision view) (fst value) (snd value) [summary|(_,_,summary)<-resolved] selection descriptor Nothing)

-- | Worker-side revalidation of File sources against actual retained capture records.
-- Literal/Transport sources carry values, not paths. This grants no approval authority.
verifyFrontendFiles :: CoordinationStore -> Text -> FrontendSetupRequest -> IO ()
verifyFrontendFiles store profile setup = withStoreFiles store $ \root -> timed 5000000 $ do
  let (directory, sources) = case setup of
        RootSetup request -> (setupDirectory request, map snd (setupInputs request))
        DerivedSetup path _ _ _ _ _ -> (path, [])
  unless (directory == privateRootPath root </> "runs") (throwIO InvalidInput)
  forM_ sources $ \source -> case source of
    File path -> do
      components <- privatePathComponents root path
      ident <- case components of
        ["captures", name] | validId (T.pack name) -> pure (T.pack name)
        _ -> throwIO InvalidInput
      capture <- runRead store $ do
        rows <- query "SELECT request_id FROM captures WHERE id=? AND profile_id=?" [text ident,text profile]
        case rows of [[SQL.SQLText request]] -> captureState request ident; _ -> refuseTransaction InvalidInput
      void (verifyCapture root capture False)
    _ -> pure ()

requestState :: CredentialProof -> Text -> [Scope] -> Transaction RequestState
requestState proof = requestStateWith (ClientAccess proof)

requestStateWith :: DraftAccess -> Text -> [Scope] -> Transaction RequestState
requestStateWith access ident scopes = do
  unless(validId ident) (refuseTransaction InvalidRequest)
  (predicates, credentials) <- case access of
    ClientAccess proof -> do
      _<-currentClient proof >>= requireTransaction
      pure (T.concat[" AND EXISTS(SELECT 1 FROM credential_scopes s WHERE s.credential_id=? AND s.profile_id=r.profile_id AND s.scope=?)" | _<-scopes],
        concat[[text(credentialRateKey proof),text(scopeName scope)]|scope<-scopes])
    RestartAccess expected -> do
      unless(expected==ident)(refuseTransaction OwnershipUnavailable)
      eligible <- query "SELECT count(*) FROM requests r JOIN request_restart_bindings b ON b.request_id=r.id WHERE r.id=? AND r.phase IN ('draft','queued') AND NOT EXISTS(SELECT 1 FROM reservations v WHERE v.request_id=r.id AND v.state!='released')" [text ident]
      unless(eligible==[[SQL.SQLInteger 1]])(refuseTransaction OwnershipUnavailable)
      pure ("",[])
    AcceptedAccess permit -> do
      request <- checkAcceptedEnqueue permit
      unless(request==ident)(refuseTransaction OwnershipUnavailable)
      pure ("",[])
  rows<-query ("SELECT r.revision,r.workflow_id,r.descriptor_revision,r.profile_id,r.profile_revision,r.phase,r.admission,(CASE WHEN r.phase='queued' THEN (SELECT count(*) FROM requests q WHERE q.phase='queued' AND (length(q.queue_ordinal)<length(r.queue_ordinal) OR (length(q.queue_ordinal)=length(r.queue_ordinal) AND q.queue_ordinal<=r.queue_ordinal))) END),r.blocking_reasons,r.validation_errors,r.client_id,r.parent_run_id,r.lineage_operation,(SELECT id FROM preparations WHERE request_id=r.id AND state='live'),(SELECT id FROM runs WHERE request_id=r.id) FROM requests r WHERE r.id=?"<>predicates)
    (text ident:credentials)
  case rows of
    [[SQL.SQLText revision,SQL.SQLText workflow,SQL.SQLText descriptor,SQL.SQLText profile,SQL.SQLText policy,SQL.SQLText phase,SQL.SQLText admission,position,SQL.SQLBlob reasons,SQL.SQLBlob errors,SQL.SQLText client,parent,lineage,preparation,run]] -> do
      blocked<-decodeTransaction reasons
      place<-fmap fromIntegral <$> optionalInteger position
      p<-optionalText parent;l<-optionalText lineage;prep<-optionalText preparation;u<-optionalText run
      pure(RequestState(DraftView ident revision workflow descriptor profile policy phase (Readiness[][][][]) admission place blocked prep u p l) client errors)
    _->refuseTransaction Forbidden

inputStates :: Text -> Transaction [InputState]
inputStates ident = do
  rows<-query "SELECT name,declaration,source,literal_bytes,literal_transport_bytes,literal_chunks,literal_digest,capture_id FROM request_inputs WHERE request_id=? ORDER BY declaration_ordinal" [text ident]
  unless(length rows<=256)(refuseTransaction InvalidInput)
  forM rows $ \row -> case row of
    [SQL.SQLText name,SQL.SQLBlob declaration,source,bytes,native,chunks,digest,cap] ->
      InputState name declaration <$> optionalText source <*> optionalInteger bytes <*> optionalInteger native <*> optionalInteger chunks <*> optionalBlob digest <*> optionalText cap
    _->refuseTransaction InvalidInput
inputStateName :: InputState -> Text
inputStateName (InputState name _ _ _ _ _ _ _)=name
nativeDeclaration :: InputState -> Either CommandFailure WorkflowInputDescriptor
nativeDeclaration (InputState name bytes _ _ _ _ _ _) = case eitherDecodeStrict' bytes of
  Right input | workflowInputName input==name -> Right input
  _->Left InvalidInput
publicDeclaration :: WorkflowInputDescriptor -> Either CommandFailure InputDeclaration
publicDeclaration input = case fromJSON(toJSON(workflowInputSource input)) of
  Success source | inputNameValid(workflowInputName input) -> Right(InputDeclaration(workflowInputName input)source)
  _->Left InvalidInput

captureState :: Text -> Text -> Transaction CaptureState
captureState request ident = do
  rows<-query "SELECT profile_id,client_id,private_reference,bytes,sha256 FROM captures WHERE id=? AND request_id=?" [text ident,text request]
  case rows of
    [[SQL.SQLText profile,SQL.SQLText client,SQL.SQLBlob reference,SQL.SQLInteger bytes,SQL.SQLText digest]] ->
      pure(CaptureState(CaptureReceipt ident request profile bytes digest)client reference)
    _->refuseTransaction ResourceUnavailable
sameCapture :: CaptureState -> CaptureState -> Bool
sameCapture (CaptureState a x r) (CaptureState b y s)=a==b && x==y && r==s

readLiteral :: CoordinationStore -> CredentialProof -> RequestState -> [Scope] -> InputState -> IO Text
readLiteral store proof = readLiteralWith store (ClientAccess proof)

readLiteralWith :: CoordinationStore -> DraftAccess -> RequestState -> [Scope] -> InputState -> IO Text
readLiteralWith store access snapshot@(RequestState view _ _) scopes input@(InputState name _ _ raw native count expected _) = do
  bytes<-maybe(throwIO InvalidInput)pure raw
  nativeBytes<-maybe(throwIO InvalidInput)pure native
  chunks<-maybe(throwIO InvalidInput)pure count
  digest<-maybe(throwIO InvalidInput)pure expected
  unless(bytes<=2097152 && chunks==(bytes+65535)`div`65536) (throwIO InvalidInput)
  runRead store $ do
    checkRevisionWith access snapshot scopes
    rows <- query "SELECT count(*),coalesce(sum(length(bytes)),0) FROM request_literal_chunks WHERE request_id=? AND name=?" [text(draftId view),text name]
    unless(rows==[[SQL.SQLInteger chunks,SQL.SQLInteger bytes]])(refuseTransaction InvalidInput)
  parts<-forM [0..chunks-1] $ \index -> runRead store $ do
    checkRevisionWith access snapshot scopes
    rows<-query "SELECT bytes FROM request_literal_chunks WHERE request_id=? AND name=? AND ordinal=?" [text(draftId view),text name,SQL.SQLInteger index]
    case rows of [[SQL.SQLBlob value]] | fromIntegral(BS.length value)==min 65536 (bytes-index*65536) -> pure value; _->refuseTransaction InvalidInput
  let result=BS.concat parts
  unless(fromIntegral(BS.length result)==bytes && constEq (convert(hash result::Digest SHA256)::BS.ByteString) digest) (throwIO InvalidInput)
  value <- either (const(throwIO InvalidInput)) pure (TE.decodeUtf8' result)
  declaration <- requireEither (nativeDeclaration input)
  unless(fromIntegral(BS.length(frontendLiteralBytes(workflowInputSource declaration)value))==nativeBytes)(throwIO InvalidInput)
  pure value

editable :: RequestState -> Transaction ()
editable (RequestState view _ _) = do
  unless(draftPhase view `elem` ["draft","queued"]) (refuseTransaction StateConflict)
  rows<-query "SELECT (SELECT count(*) FROM reservations WHERE request_id=? AND state!='released')+(SELECT count(*) FROM preparations WHERE request_id=? AND state='live')" [text(draftId view),text(draftId view)]
  unless(rows==[[SQL.SQLInteger 0]]) (refuseTransaction StateConflict)
currentVersion :: CredentialProof -> Text -> Transaction (Maybe (Text,Text,Text))
currentVersion proof ident = do RequestState view _ _<-requestState proof ident [Submit];pure(Just(requestURI ident,draftProfile view,draftRevision view))
checkRevision :: CredentialProof -> RequestState -> [Scope] -> Transaction ()
checkRevision proof = checkRevisionWith (ClientAccess proof)
checkRevisionWith :: DraftAccess -> RequestState -> [Scope] -> Transaction ()
checkRevisionWith access (RequestState expected _ _) scopes = do
  RequestState actual _ _<-requestStateWith access (draftId expected) scopes
  unless(draftRevision actual==draftRevision expected)(refuseTransaction StaleRevision)
ensureRevision :: CoordinationStore -> CredentialProof -> RequestState -> [Scope] -> IO ()
ensureRevision store proof snapshot scopes=runRead store(checkRevision proof snapshot scopes)

checkDraftCapacity :: ConfigurationLimits -> Text -> Transaction ()
checkDraftCapacity limits client = do
  rows<-query "SELECT count(*),coalesce(sum(client_id=?),0) FROM requests WHERE phase='draft'" [text client]
  case rows of
    [[SQL.SQLInteger total,SQL.SQLInteger owned]] -> unless(total<fromIntegral(limitGlobalDrafts limits) && owned<fromIntegral(limitDrafts limits))(refuseTransaction StorageQuota)
    _->refuseTransaction StorageUnavailable
holding :: Text -> Transaction (Int64,Int64,Int64)
holding ident = do
  rows<-query "SELECT coalesce((SELECT sum(literal_bytes) FROM request_inputs WHERE request_id=?),0),coalesce((SELECT sum(bytes) FROM captures WHERE request_id=?),0)+coalesce((SELECT sum(reserved_bytes) FROM capture_uploads WHERE request_id=?),0),(SELECT count(*) FROM captures WHERE request_id=?)+(SELECT count(*) FROM capture_uploads WHERE request_id=?)" (replicate 5(text ident))
  case rows of [[SQL.SQLInteger literals,SQL.SQLInteger captures,SQL.SQLInteger count]] ->pure(literals,captures,count);_->refuseTransaction StorageUnavailable
checkUploadCapacity :: ConfigurationLimits -> Text -> Int64 -> Transaction ()
checkUploadCapacity limits ident bytes = do
  (literals,captures,count)<-holding ident
  global<-query "SELECT coalesce((SELECT sum(bytes) FROM captures),0)+coalesce((SELECT sum(reserved_bytes) FROM capture_uploads),0)" []
  case global of
    [[SQL.SQLInteger used]] -> unless(count<256 && literals+captures+bytes<=holdingLimit && used+bytes<=fromIntegral(limitGlobalCaptureBytes limits))(refuseTransaction StorageQuota)
    _->refuseTransaction StorageUnavailable
checkInputReplacement :: Text -> Text -> Maybe (Int64,Int64) -> Maybe CaptureState -> Transaction ()
checkInputReplacement ident name replacement capture = do
  (literals,captures,_)<-holding ident
  rows<-query "SELECT coalesce(literal_bytes,0) FROM request_inputs WHERE request_id=? AND name=?" [text ident,text name]
  old<-case rows of [[SQL.SQLInteger value]]->pure value;_->refuseTransaction InvalidInput
  let added=maybe 0 fst replacement
      native=case replacement of Just(_,n)->n;Nothing->maybe 0 (\(CaptureState c _ _)->captureBytes c) capture
  unless(literals-old+added+captures<=holdingLimit)(refuseTransaction StorageQuota)
  totals<-query "SELECT coalesce(sum(CASE WHEN i.source='literal' THEN i.literal_transport_bytes WHEN i.source='capture' THEN c.bytes ELSE 0 END),0),coalesce(sum(i.source='literal' AND i.literal_transport_bytes IS NULL),0) FROM request_inputs i LEFT JOIN captures c ON c.id=i.capture_id WHERE i.request_id=? AND i.name!=?" [text ident,text name]
  case totals of [[SQL.SQLInteger total,SQL.SQLInteger 0]]->unless(total+native<=holdingLimit)(refuseTransaction SizeLimit);_->refuseTransaction InvalidInput
-- | Structural stored readiness. File integrity is still checked by materialization.
structuralReadiness :: [Text] -> Transaction [(Text, Bool)]
structuralReadiness identifiers = do
  unless(length identifiers<=100)(refuseTransaction SizeLimit)
  if null identifiers then pure [] else do
    rows <- query ("SELECT r.id,CASE WHEN json_valid(r.validation_errors) AND json_type(r.validation_errors)='array' AND json_array_length(r.validation_errors)=0 AND NOT EXISTS(SELECT 1 FROM request_inputs i LEFT JOIN captures c ON c.id=i.capture_id WHERE i.request_id=r.id AND (i.source IS NULL OR (i.source='literal' AND i.literal_transport_bytes IS NULL) OR (i.source='capture' AND c.id IS NULL))) AND coalesce((SELECT sum(CASE WHEN i.source='literal' THEN i.literal_transport_bytes ELSE c.bytes END) FROM request_inputs i LEFT JOIN captures c ON c.id=i.capture_id WHERE i.request_id=r.id),0)<=67108864 THEN 1 ELSE 0 END FROM requests r WHERE r.id IN (" <> T.intercalate "," (replicate(length identifiers) "?") <> ")") (map text identifiers)
    forM rows $ \row -> case row of
      [SQL.SQLText ident,SQL.SQLInteger ready] -> pure(ident,ready==1)
      _ -> refuseTransaction InvalidInput

ensureReadyTotal :: CoordinationStore -> Text -> IO ()
ensureReadyTotal store ident = runRead store $ do
  rows<-query "SELECT coalesce(sum(CASE WHEN i.source='literal' THEN i.literal_transport_bytes ELSE c.bytes END),0),coalesce(sum(i.source IS NULL OR (i.source='literal' AND i.literal_transport_bytes IS NULL)),0) FROM request_inputs i LEFT JOIN captures c ON c.id=i.capture_id WHERE i.request_id=?" [text ident]
  case rows of [[SQL.SQLInteger total,SQL.SQLInteger 0]]->unless(total<=holdingLimit)(refuseTransaction SizeLimit);_->refuseTransaction InvalidInput

selectCatalogue :: [(Text,Discovery)] -> Text -> Text -> Text -> Text -> Either CommandFailure (Discovery,WorkflowDescriptor)
selectCatalogue catalogues profile policy workflow revision = do
  catalogue<-maybe(Left StorageUnavailable)Right(lookup profile catalogues)
  unless(discoveryProfileRevision catalogue==policy && discoveryRevision catalogue==revision)(Left StaleRevision)
  descriptor<-maybe(Left ResourceUnavailable)Right(lookup workflow (discoveryEntries catalogue))
  pure(catalogue,descriptor)
currentCatalogue :: CoordinationStore -> DraftAccess -> DraftView -> IO (Discovery,WorkflowDescriptor)
currentCatalogue store access view = do
  result<-withStoreCatalogues store $ \_ _ catalogues -> pure $ do
    case access of
      RestartAccess _ -> maybe(Left ResourceUnavailable)(const(Right()))(lookup(draftProfile view)catalogues)
      _ -> Right()
    selectCatalogue catalogues (draftProfile view) (draftProfileRevision view) (draftWorkflow view) (draftDescriptorRevision view)
  either(const(throwIO StorageUnavailable)) requireEither result

persistErrors :: CoordinationStore -> CredentialProof -> RequestState -> [InputError] -> DraftView -> IO DraftView
persistErrors store proof snapshot@(RequestState view _ previous) errors result
  | previous==encoded errors=pure result
  | otherwise=do
      revision<-fresh "request_revision_"
      runTransaction store $ do
        checkRevision proof snapshot [Observe]
        execute "UPDATE requests SET validation_errors=?,revision=? WHERE id=?" [SQL.SQLBlob(encoded errors),text revision,text(draftId view)]
        pure(result {draftRevision=revision},[requestEvent(draftId view)revision])
markOrphan :: CoordinationStore -> Text -> IO ()
markOrphan store ident=runTransaction store $ do
  execute "UPDATE capture_uploads SET state='orphan' WHERE id=?" [text ident]
  pure((),[Invalidation "service.changed" "/v1/capabilities" ident])
releaseUpload :: CoordinationStore -> Text -> IO ()
releaseUpload store ident=runTransaction store $ do
  execute "DELETE FROM capture_uploads WHERE id=?" [text ident]
  pure((),[Invalidation "service.changed" "/v1/capabilities" ident])

verifyCapture :: PrivateRoot -> CaptureState -> Bool -> IO (Maybe Text)
verifyCapture root (CaptureState receipt _ reference) keep = do
  unless(reference==TE.encodeUtf8(captureId receipt) && validId(captureId receipt))(throwIO InvalidInput)
  result<-try @IOException $ withCaptureFile root (captureId receipt) $ \handle -> do
    input<-utf8Source (captureBytes receipt) (BS.hGetSome handle 65536)
    let loop !count !context parts=do
          bytes<-input
          if BS.null bytes then do
            unless(count==captureBytes receipt && T.pack(show(hashFinalize context::Digest SHA256))==captureDigest receipt)(throwIO InvalidInput)
            if keep then Just <$> either(const(throwIO InvalidInput))pure(TE.decodeUtf8'(BS.concat(reverse parts))) else pure Nothing
          else loop (count+fromIntegral(BS.length bytes)) (hashUpdate context bytes) (if keep then bytes:parts else [])
    loop 0 (hashInit::Context SHA256) []
  either(const(throwIO InvalidInput))pure result
withCaptureFile :: PrivateRoot -> Text -> (Handle -> IO a) -> IO a
withCaptureFile root ident action=withPrivateDirectoryAt root ["captures"] $ \parent ->
  bracket (do
    fd<-openFdAt (Just parent) (T.unpack ident) ReadOnly defaultFileFlags {cloexec=True,nofollow=True,nonBlock=True}
    result<-try @SomeException $ do
      status<-getFdStatus fd
      owner<-getEffectiveUserID
      unless(isRegularFile status && fileOwner status==owner && fileMode status .&. 0o777==0o600 && linkCount status==1)(throwIO InvalidInput)
      fdToHandle fd
    either(\failure->closeFd fd>>throwIO failure)pure result) hClose action
utf8Source :: Int64 -> IO BS.ByteString -> IO (IO BS.ByteString)
utf8Source limit source = do
  decoder<-newIORef (TE.streamDecodeUtf8With strictDecode)
  pending<-newIORef BS.empty
  count<-newIORef 0
  pure $ do
    bytes<-source
    previous<-readIORef count
    unless(BS.length bytes<=65536 && previous+fromIntegral(BS.length bytes)<=limit)(throwIO SizeLimit)
    if BS.null bytes then do
      suffix<-readIORef pending
      unless(BS.null suffix)(throwIO InvalidInput)
    else do
      continue<-readIORef decoder
      result<-try @UnicodeException $ do
        let TE.Some textValue suffix next=continue bytes
        _<-evaluate(T.length textValue)
        pure(suffix,next)
      case result of
        Left _ -> throwIO InvalidInput
        Right(suffix,next)->writeIORef pending suffix>>writeIORef decoder next
      writeIORef count (previous+fromIntegral(BS.length bytes))
    pure bytes

timed :: Int -> IO a -> IO a
timed micros action=timeout micros action >>= maybe(throwIO StorageUnavailable)pure
draftIO :: IO a -> IO (Either CommandFailure a)
draftIO action=do
  result<-try @CommandFailure (try @StoreFailure (try @IOException action))
  pure $ case result of Left failure->Left failure;Right(Left _)->Left StorageUnavailable;Right(Right(Left _))->Left StorageUnavailable;Right(Right(Right value))->Right value
requireEither :: Either CommandFailure a -> IO a
requireEither=either throwIO pure
requireTransaction :: Either CommandFailure a -> Transaction a
requireTransaction=either refuseTransaction pure
decodeTransaction :: FromJSON a => BS.ByteString -> Transaction a
decodeTransaction=either (const(refuseTransaction InvalidInput)) pure . eitherDecodeStrict'
optionalText :: SQL.SQLData -> Transaction (Maybe Text)
optionalText SQL.SQLNull=pure Nothing
optionalText (SQL.SQLText value)=pure(Just value)
optionalText _=refuseTransaction InvalidInput
optionalInteger :: SQL.SQLData -> Transaction (Maybe Int64)
optionalInteger SQL.SQLNull=pure Nothing
optionalInteger (SQL.SQLInteger value)=pure(Just value)
optionalInteger _=refuseTransaction InvalidInput
optionalBlob :: SQL.SQLData -> Transaction (Maybe BS.ByteString)
optionalBlob SQL.SQLNull=pure Nothing
optionalBlob (SQL.SQLBlob value)=pure(Just value)
optionalBlob _=refuseTransaction InvalidInput
text :: Text -> SQL.SQLData
text=SQL.SQLText
integer :: Integral a => a -> SQL.SQLData
integer=SQL.SQLInteger . fromIntegral
requestURI :: Text -> Text
requestURI ident="/v1/requests/"<>ident
requestEvent :: Text -> Text -> Invalidation
requestEvent ident revision=Invalidation "request.changed" (requestURI ident) revision
fresh :: Text -> IO Text
fresh prefix=do bytes<-getRandomBytes 24::IO BS.ByteString;pure(prefix<>TE.decodeUtf8(convertToBase Base16 bytes))
groupsOf :: Int -> [a] -> [[a]]
groupsOf _ []=[]
groupsOf n values=let (prefix,rest)=splitAt n values in prefix:groupsOf n rest
byteChunks :: BS.ByteString -> [BS.ByteString]
byteChunks bytes | BS.null bytes=[] | otherwise=let (prefix,rest)=BS.splitAt 65536 bytes in prefix:byteChunks rest
