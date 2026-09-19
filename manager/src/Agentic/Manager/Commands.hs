{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | Durable command acceptance and one-shot live dispatch, not worker interpretation.
module Agentic.Manager.Commands
  ( CommandRequest (..), Mutation (..), Intent (..), CommandReferences (..), noReferences,
    Submission, submissionReceipt, submissionReplayed, submissionTicket, submissionReferences, submissionEnqueue, AcceptedEnqueue, acceptedRequest, checkAcceptedEnqueue, currentAcceptedEnqueues,
    CommandAttempt, newCommandAttempt, newControlCommandAttempt, submitCommandAttempt, submitCommandAttemptWithDeadline, reconcileCommandAttempt, reconcileCommandAttemptWithAdmission, DispatchTicket, dispatchCommandId, submitCommand, submitConfiguredCommand, submitStreamedCommand, commandPreflight, commandPreflightVersion, readCommand,
    BodyBinding, measureCommandBody, bodyBindingBytes, bodyBindingSha256,
    reserveDispatch, reserveDispatchWithAdmission, attemptDispatch, attemptDispatchWithAdmission, attemptControlDispatch, discardControlPayload, discardControlAttempt, recordAcknowledgement, recordEffect, recordEffectWith, recordEffectWithAdmission, recordUnresolved, recordRefusal,
    recordRuntimeObservation, recordExportObservation, retireReceipt, commandCapacity, tombstoneCapacity
  ) where

import Agentic.Manager.Authorization
import Agentic.Manager.Profile (ConfigurationLimits (..), PublicProfile, publicId, publicRevision, Discovery)
import Agentic.Manager.Protocol.Command
import Agentic.Manager.Protocol.Artifact (validExportName)
import Agentic.Manager.Protocol.Json (decodeStrictValue)
import Agentic.Manager.Store
import Agentic.Runtime (maxFrameBytes, maxArtifactBytes)
import Control.DeepSeq (NFData)
import Control.Exception (SomeException, mask, finally, throwIO, try)
import Control.Monad (unless, void, forM, forM_)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT, throwE)
import Crypto.Hash (Context, Digest, SHA256, hash, hashInit, hashUpdate, hashFinalize)
import Crypto.Random (getRandomBytes)
import Data.Aeson (FromJSON, Value (..), eitherDecodeStrict')
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import Data.ByteArray (convert, constEq)
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import qualified Data.ByteString as BS
import Data.Int (Int64)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.List (find)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Database.SQLite3 as SQL
import GHC.Generics (Generic)

-- | Exact transport binding, after the owning route's strict body/target decoding.
-- No body normalization is performed. The profile is independently authorized.
data CommandRequest = CommandRequest
  { commandOperation :: !Operation, commandProfile :: !Text, commandMethod :: !Text,
    commandResource :: !Text, commandKey :: !Text, commandMediaType :: !Text,
    commandPrecondition :: !(Maybe Text), commandBody :: !BS.ByteString
  }

-- | An exact byte-stream binding, minted only after the wrapped source reports EOF.
-- No Generic, Show, JSON or digest constructor exposes a forging route.
data BodyBinding = BodyBinding !BS.ByteString !Int !(Maybe BS.ByteString)
bodyBindingBytes :: BodyBinding -> Int
bodyBindingBytes (BodyBinding _ count _) = count
bodyBindingSha256 :: BodyBinding -> Text
bodyBindingSha256 (BodyBinding digest _ _) = TE.decodeUtf8 (convertToBase Base16 digest)

measureCommandBody :: Operation -> IO BS.ByteString -> (IO BS.ByteString -> IO a) -> IO (a, Maybe BodyBinding)
measureCommandBody operation source action = do
  progress <- newIORef (hashInit :: Context SHA256, 0 :: Int, Just [], False)
  let wrapped = do
        (context, count, retained, ended) <- readIORef progress
        if ended then pure BS.empty else do
          bytes <- source
          if BS.null bytes then writeIORef progress (context, count, retained, True) >> pure bytes else do
            let next = count + BS.length bytes
                limit = if operation == Capture then 67108864 else 2097152
            unless (BS.length bytes <= 65536 && next <= limit) (throwIO SizeLimit)
            let prefix = if next <= 2097152 then (bytes :) <$> retained else Nothing
            let !updated = hashUpdate context bytes
            writeIORef progress (updated, next, prefix, False)
            pure bytes
  value <- action wrapped
  (context, count, retained, ended) <- readIORef progress
  let binding = BodyBinding (convert (hashFinalize context :: Digest SHA256)) count (BS.concat . reverse <$> retained)
  pure (value, if ended then Just binding else Nothing)

-- | A source-owned lifecycle validator and deferred state mutation. There is no default.
-- The version action must read the validator for the exact URI, including its query.
data Mutation = Mutation
  { mutationProfileRevision :: !Text,
    mutationVersion :: Transaction (Maybe (Text, Text, Text)),
    mutationValidate :: Transaction (Either CommandFailure Intent)
  }

-- | Existing relational associations and a deferred owning-module mutation.
data Intent = Intent
  { intentReferences :: !CommandReferences,
    intentDispatch :: !Bool,
    intentApply :: Transaction ([Invalidation], Maybe Effect)
  }

-- | References to coordination records, never reconstructed worker handles.
data CommandReferences = CommandReferences
  { referenceRequest :: !(Maybe Text), referenceRun :: !(Maybe Text),
    referencePreparation :: !(Maybe Text), referenceDecision :: !(Maybe Text)
  } deriving (Eq, Generic, NFData)
noReferences :: CommandReferences
noReferences = CommandReferences Nothing Nothing Nothing Nothing

-- | A committed original receipt and, only for fresh acceptance, live dispatch authority.
data Submission = Submission !CommandReceipt !Bool !(Maybe DispatchTicket) !CommandReferences !(Maybe AcceptedEnqueue)
submissionReceipt :: Submission -> CommandReceipt
submissionReceipt (Submission receipt _ _ _ _) = receipt
submissionReplayed :: Submission -> Bool
submissionReplayed (Submission _ replayed _ _ _) = replayed
submissionTicket :: Submission -> Maybe DispatchTicket
submissionTicket (Submission _ _ ticket _ _) = ticket

submissionReferences :: Submission -> CommandReferences
submissionReferences (Submission _ _ _ refs _) = refs

-- | A current, accepted enqueue's materialization association, not approval or worker authority.
data AcceptedEnqueue = AcceptedEnqueue !Text !Text !Text !QueueAssociation
data QueueAssociation = QueueAssociation !Text !Text !Text !Text !Text !Text !Text !Text
  deriving (Generic, NFData)
submissionEnqueue :: Submission -> Maybe AcceptedEnqueue
submissionEnqueue (Submission _ _ _ _ permit) = permit
acceptedRequest :: AcceptedEnqueue -> Text
acceptedRequest (AcceptedEnqueue _ _ _ (QueueAssociation request _ _ _ _ _ _ _)) = request

checkAcceptedEnqueue :: AcceptedEnqueue -> Transaction Text
checkAcceptedEnqueue permit = do
  current <- currentAcceptedEnqueues [permit]
  unless(Set.member (acceptedRequest permit) current)(refuseTransaction OwnershipUnavailable)
  pure(acceptedRequest permit)

-- | Bounded current associations from retained permits, not capabilities minted from rows.
currentAcceptedEnqueues :: [AcceptedEnqueue] -> Transaction (Set.Set Text)
currentAcceptedEnqueues permits = do
  unless(length permits<=116)(refuseTransaction SizeLimit)
  generation <- transactionGeneration
  let current=[permit | permit@(AcceptedEnqueue owner _ _ _) <- permits, owner==generation]
      chunks []=[]
      chunks values=let(first,rest)=splitAt 16 values in first:chunks rest
      parameters (AcceptedEnqueue owner epoch command (QueueAssociation request profile policy workflow descriptor ordinal origin inputRevision)) =
        map text [owner,epoch,command,request,profile,policy,workflow,descriptor,ordinal,origin,inputRevision]
  selected <- forM (chunks current) $ \batch -> do
    rows <- query ("WITH permits(generation,epoch,command,request,profile,policy,workflow,descriptor,ordinal,origin,input_revision) AS (VALUES "
      <> T.intercalate ","(replicate(length batch)"(?,?,?,?,?,?,?,?,?,?,?)")
      <> ") SELECT p.request FROM permits p JOIN requests r ON r.id=p.request JOIN commands c ON c.id=p.command AND c.request_id=r.id JOIN service_metadata s ON s.singleton=1 WHERE r.enqueue_command=c.id AND c.operation='enqueue' AND c.retired=0 AND c.authority_epoch=p.epoch AND s.authority_epoch=p.epoch AND r.profile_id=p.profile AND r.profile_revision=p.policy AND r.workflow_id=p.workflow AND r.descriptor_revision=p.descriptor AND r.queue_ordinal=p.ordinal AND r.queue_origin_revision=p.origin AND r.input_revision=p.input_revision AND r.queue_generation=p.generation AND r.phase IN ('queued','preparing','review') AND (r.phase='queued' OR EXISTS(SELECT 1 FROM reservations v WHERE v.request_id=r.id AND v.process_generation=p.generation AND v.state='held'))") (concatMap parameters batch)
    pure [request | [SQL.SQLText request] <- rows]
  pure(Set.fromList(concat selected))

-- | One command's live ownership. IDs and durable generation columns cannot mint this.
data DispatchTicket = DispatchTicket !CoordinationStore !Text !Text !CommandReferences !(IORef TicketState)
data TicketPhase = Unreserved | Reserved | Consumed deriving (Eq)
data TicketState = TicketState !TicketPhase !(Maybe BS.ByteString)
dispatchCommandId :: DispatchTicket -> Text
dispatchCommandId (DispatchTicket _ ident _ _ _) = ident

commandCapacity, tombstoneCapacity :: Int64
commandCapacity = 131072
tombstoneCapacity = 16384

type CommandTx = ExceptT CommandFailure Transaction

submitCommand :: CoordinationStore -> CredentialProof -> CommandRequest -> Mutation -> IO (Either CommandFailure Submission)
submitCommand store proof request mutation = submitConfiguredCommand store proof request (\_ _ _ -> Right mutation)

submitConfiguredCommand :: CoordinationStore -> CredentialProof -> CommandRequest -> (Text -> ConfigurationLimits -> [(Text, Discovery)] -> Either CommandFailure Mutation) -> IO (Either CommandFailure Submission)
submitConfiguredCommand store proof request = submitBoundCommand store proof request Nothing Nothing Nothing

submitStreamedCommand :: CoordinationStore -> CredentialProof -> CommandRequest -> BodyBinding -> (Text -> ConfigurationLimits -> [(Text, Discovery)] -> Either CommandFailure Mutation) -> IO (Either CommandFailure Submission)
submitStreamedCommand store proof request binding builder
  | commandOperation request /= Capture || not (BS.null (commandBody request)) = pure (Left InvalidRequest)
  | otherwise = submitBoundCommand store proof request (Just binding) Nothing Nothing builder

submitBoundCommand :: CoordinationStore -> CredentialProof -> CommandRequest -> Maybe BodyBinding -> Maybe CommandAttempt -> Maybe CommitDeadline -> (Text -> ConfigurationLimits -> [(Text, Discovery)] -> Either CommandFailure Mutation) -> IO (Either CommandFailure Submission)
submitBoundCommand store proof request streamed known deadline buildMutation = case validateRequest request of
  Left failure -> pure (Left failure)
  Right () -> mask $ \restore -> do
    CommandAttempt _ _ _ candidate retained generationAtCreation _ <- maybe (newCommandAttempt store proof request) pure known
    let (digest, bodyBytes, legacyBytes) = case streamed of
          Nothing -> (convert (hash (commandBody request) :: Digest SHA256), BS.length (commandBody request), Just (commandBody request))
          Just (BodyBinding checksum count prefix) -> (checksum, count, prefix)
    outcome <- restore $ configuredCatalogues store proof $ \limits profiles catalogues identity -> transaction store $ do
      (client, epoch) <- authorizeRequest profiles proof request
      old <- sql "SELECT id,profile_id,operation,retired,media_type,precondition,body_sha256,body_bytes FROM commands WHERE client_id=? AND method=? AND resource_uri=? AND idempotency_key=?"
        [text client, text (commandMethod request), text (commandResource request), text (commandKey request)]
      case old of
        [] -> do
          mutation <- checked (buildMutation candidate limits catalogues)
          require (commandMediaType request == if commandOperation request == Capture then "application/octet-stream" else "application/json") UnsupportedMediaType
          profile <- knownProfile profiles (commandProfile request)
          require (publicRevision profile == mutationProfileRevision mutation) StaleRevision
          current <- lift (mutationVersion mutation)
          checkPrecondition request current
          intent <- checked =<< lift (mutationValidate mutation)
          require (validReferences (intentReferences intent)) InvalidRequest
          (now, minute) <- trustedTime
          checkCapacity limits (commandOperation request)
          checkRate limits proof (commandOperation request) minute
          (events, immediate) <- lift (intentApply intent)
          let refs = intentReferences intent
          metadata <- sql "SELECT command_id,run_id,decision_id,native_command,occurrence_id,attempt_id,generation,native_sha256,native_bytes,effect_sha256,effect_bytes FROM control_intents WHERE command_id=?" [text candidate]
          correlation <- case metadata of
            [] -> pure []
            [values] -> mapM metadataValue values
            _ -> throwE StorageUnavailable
          let fixed = map String [candidate,candidate,commandProfile request,operationName(commandOperation request),client,epoch,
                commandMethod request,commandResource request,commandKey request,commandMediaType request,now,
                storeProcessGeneration identity,TE.decodeUtf8(convertToBase Base16 digest),T.pack(show bodyBytes)] <>
                map (maybe Null String) [commandPrecondition request,referenceRequest refs,referenceRun refs,referencePreparation refs,referenceDecision refs]
          require (BS.length(encoded(fixed<>correlation))<=fromIntegral tombstoneCapacity) StorageQuota
          case immediate of
            Nothing -> pure ()
            Just effect -> do
              require (not (intentDispatch intent) && commandOperation request `elem` [SetInput, RemoveInput, Enqueue, Withdraw, Restart, Resume, Fork]) StateConflict
              require (nullField "runtimeSequence" (effectValue effect) && nullField "address" (effectValue effect)) StateConflict
              validateEffectBinding (commandOperation request) candidate refs effect
          _ <- checked =<< lift (authorizeProfile proof (commandProfile request) (requiredScopes (commandOperation request)))
          let receipt = CommandReceipt candidate (commandProfile request) (commandOperation request)
                (commandResource request) (maybe Accepted (const EffectObserved) immediate) now Nothing Nothing immediate Nothing
              receiptBytes = encoded receipt
          require (BS.length receiptBytes <= 65536) StorageUnavailable
          lift $ execute
            "INSERT INTO commands (id,revision,profile_id,operation,client_id,authority_epoch,method,resource_uri,idempotency_key,body,media_type,precondition,receipt,retired,request_id,run_id,preparation_id,decision_id,accepted_at,state,effect_evidence,body_sha256,body_bytes,reserved_bytes) VALUES (?,?,?,?,?,?,?,?,?,NULL,?,?,?,0,?,?,?,?,?,?,?,?,?,?)"
            [text candidate, text candidate, text (commandProfile request), text (operationName (commandOperation request)),
             text client, text epoch, text (commandMethod request), text (commandResource request), text (commandKey request),
             text (commandMediaType request), optional (commandPrecondition request), SQL.SQLBlob receiptBytes,
             optional (referenceRequest refs), optional (referenceRun refs), optional (referencePreparation refs),
             optional (referenceDecision refs), text now, text (stateName (receiptState receipt)),
             maybe SQL.SQLNull (SQL.SQLBlob . encoded) immediate, SQL.SQLBlob digest,
             SQL.SQLInteger (fromIntegral bodyBytes), SQL.SQLInteger commandCapacity]
          forM_ (referenceDecision refs) $ \decision -> lift $ execute
            "UPDATE decisions SET command_id=? WHERE id=? AND state='submitting' AND revision=?"
            [text candidate,text decision,text candidate]
          chargeRate proof (commandOperation request) minute
          queue <- case (commandOperation request, referenceRequest refs) of
            (Enqueue, Just requestId) -> do
              values <- sql "SELECT id,profile_id,profile_revision,workflow_id,descriptor_revision,queue_ordinal,queue_origin_revision,input_revision FROM requests WHERE id=? AND phase='queued' AND queue_generation=?"
                [text requestId,text(storeProcessGeneration identity)]
              pure $ case values of
                [[SQL.SQLText r,SQL.SQLText p,SQL.SQLText pr,SQL.SQLText w,SQL.SQLText d,SQL.SQLText q,SQL.SQLText o,SQL.SQLText i]] -> Just(QueueAssociation r p pr w d q o i)
                _ -> Nothing
            _ -> pure Nothing
          forM_ deadline (lift . enforceCommitDeadline)
          pure ((receipt, False, intentDispatch intent, refs, storeProcessGeneration identity, epoch, queue), events <> [commandEvent candidate candidate])
        [[SQL.SQLText ident, SQL.SQLText profile, SQL.SQLText operation, SQL.SQLInteger retired, media, precondition, bodyDigest, bodyLength]] -> do
          require (profile == commandProfile request && operation == operationName (commandOperation request)) IdempotencyConflict
          require (retired == 0) ReceiptExpired
          require (media == text (commandMediaType request) && precondition == optional (commandPrecondition request)) IdempotencyConflict
          match <- case (bodyDigest, bodyLength) of
            (SQL.SQLBlob original, SQL.SQLInteger bytes) -> pure (constEq original digest && bytes == fromIntegral bodyBytes)
            (SQL.SQLNull, SQL.SQLNull) | Just bytes <- legacyBytes, BS.length bytes <= 2097152 -> do
              equality <- sql "SELECT body=? FROM commands WHERE id=?" [SQL.SQLBlob bytes, text ident]
              pure (equality == [[SQL.SQLInteger 1]])
            _ -> pure False
          require match IdempotencyConflict
          receipt <- originalReceipt ident
          require (receiptProfile receipt == profile && receiptOperation receipt == commandOperation request
            && receiptResource receipt == commandResource request) StorageUnavailable
          referenceRows <- sql "SELECT request_id,run_id,preparation_id,decision_id FROM commands WHERE id=?" [text ident]
          refs <- case referenceRows of
            [[r,u,p,d]] -> CommandReferences <$> sqlOptionalText r <*> sqlOptionalText u <*> sqlOptionalText p <*> sqlOptionalText d
            _ -> throwE StorageUnavailable
          pure ((receipt, True, False, refs, storeProcessGeneration identity, epoch, Nothing), [])
        _ -> throwE StorageUnavailable
    case outcome of
      Left failure -> pure (Left failure)
      Right (receipt, replayed, dispatch, refs, generation, epoch, association) -> do
        unless (generation==generationAtCreation) (throwIO OwnershipUnavailable)
        ticket <- if dispatch then pure (Just (DispatchTicket store (receiptId receipt) generation refs retained)) else pure Nothing
        pure (Right (Submission receipt replayed ticket refs (AcceptedEnqueue generation epoch (receiptId receipt) <$> association)))

-- | One retained invocation, allocated before acceptance and never recreated from a receipt.
data CommandAttempt = CommandAttempt !CoordinationStore !CredentialProof !CommandRequest !Text !(IORef TicketState) !Text !(IORef AttemptPhase)
data AttemptPhase = AttemptNew | AttemptRunning | AttemptFinished deriving (Eq)

newCommandAttempt :: CoordinationStore -> CredentialProof -> CommandRequest -> IO CommandAttempt
newCommandAttempt store proof request = do
  candidate <- freshId "command_"
  state <- newIORef (TicketState Unreserved Nothing)
  phase <- newIORef AttemptNew
  pure (CommandAttempt store proof request candidate state (proofGeneration proof) phase)

-- | Capture only for a fresh, authorized original control attempt. The encoder
-- uses the already allocated correlation ID, not mutable lifecycle observations.
newControlCommandAttempt :: CoordinationStore -> CredentialProof -> CommandRequest
  -> (Text -> Either CommandFailure BS.ByteString) -> IO CommandAttempt
newControlCommandAttempt store proof request encoder = do
  either throwIO pure (validateRequest request)
  unless(commandOperation request `elem` [Cancel,Steer,Retry,ChooseRecovery,Redirect,Answer])(throwIO InvalidRequest)
  attempt@(CommandAttempt _ _ _ candidate retained _ _) <- newCommandAttempt store proof request
  bytes <- either throwIO pure (encoder candidate)
  unless(BS.length bytes<=maxFrameBytes)(throwIO SizeLimit)
  writeIORef retained (TicketState Unreserved (Just bytes))
  pure attempt

submitCommandAttempt :: CommandAttempt -> (Text -> ConfigurationLimits -> [(Text, Discovery)] -> Either CommandFailure Mutation) -> IO (Either CommandFailure Submission)
submitCommandAttempt = submitAttempt Nothing

submitCommandAttemptWithDeadline :: CommitDeadline -> CommandAttempt -> (Text -> ConfigurationLimits -> [(Text, Discovery)] -> Either CommandFailure Mutation) -> IO (Either CommandFailure Submission)
submitCommandAttemptWithDeadline deadline = submitAttempt(Just deadline)

submitAttempt :: Maybe CommitDeadline -> CommandAttempt -> (Text -> ConfigurationLimits -> [(Text, Discovery)] -> Either CommandFailure Mutation) -> IO (Either CommandFailure Submission)
submitAttempt deadline attempt@(CommandAttempt store proof request _ retained _ phase) builder = mask $ \restore -> do
  started <- atomicModifyIORef' phase $ \current -> if current==AttemptNew then (AttemptRunning,True) else (current,False)
  if not started then pure(Left OwnershipUnavailable) else
    (do
      result <- restore(submitBoundCommand store proof request Nothing (Just attempt) deadline builder)
      case result of
        Left failure | failure/=StorageUnavailable -> discardTicketState retained
        Right submission | submissionReplayed submission -> discardTicketState retained
        _ -> pure ()
      pure result) `finally` writeIORef phase AttemptFinished

-- Reconcile only this known invocation after a lost return. Current credentials do not
-- revoke its accepted cleanup, while Store lifetime and authority epoch still fence it.
reconcileCommandAttempt :: CommandAttempt -> IO (Either CommandFailure (Maybe Submission))
reconcileCommandAttempt = reconcileCommandAttemptWithAdmission FailFast

reconcileCommandAttemptWithAdmission :: StoreAdmission -> CommandAttempt -> IO (Either CommandFailure (Maybe Submission))
reconcileCommandAttemptWithAdmission admission (CommandAttempt store _ request candidate retained generation phase) = do
  done <- readIORef phase
  if done/=AttemptFinished then pure(Left OwnershipUnavailable) else reconcile
  where
  reconcile = do
   outcome <- transactionWithAdmission admission store $ do
     current <- lift transactionGeneration
     epoch <- currentEpoch
     require (generation==current && epoch==keyEpoch request) OwnershipUnavailable
     rows <- sql "SELECT body_sha256,body_bytes,method,resource_uri,idempotency_key,profile_id,operation,authority_epoch,retired,request_id,run_id,preparation_id,decision_id FROM commands WHERE id=?" [text candidate]
     if null rows then pure(Nothing,[]) else do
       refs <- case rows of
         [[SQL.SQLBlob digest,SQL.SQLInteger count,method,uri,key,profile,operation,authority,SQL.SQLInteger 0,r,u,p,d]] -> do
           require (constEq digest (convert(hash(commandBody request)::Digest SHA256)::BS.ByteString)
             && count==fromIntegral(BS.length(commandBody request)) && method==text(commandMethod request)
             && uri==text(commandResource request) && key==text(commandKey request) && profile==text(commandProfile request)
             && operation==text(operationName(commandOperation request)) && authority==text epoch) OwnershipUnavailable
           CommandReferences <$> sqlOptionalText r <*> sqlOptionalText u <*> sqlOptionalText p <*> sqlOptionalText d
         _ -> throwE OwnershipUnavailable
       receipt <- originalReceipt candidate
       association <- case (commandOperation request,referenceRequest refs) of
         (Enqueue,Just ident) -> do
           queue <- sql "SELECT id,profile_id,profile_revision,workflow_id,descriptor_revision,queue_ordinal,queue_origin_revision,input_revision FROM requests WHERE id=? AND queue_generation=? AND enqueue_command=? AND queue_origin_revision IS NOT NULL AND phase='queued'" [text ident,text generation,text candidate]
           pure $ case queue of
             [[SQL.SQLText r,SQL.SQLText p,SQL.SQLText pr,SQL.SQLText w,SQL.SQLText d,SQL.SQLText q,SQL.SQLText o,SQL.SQLText i]] -> Just(QueueAssociation r p pr w d q o i)
             _ -> Nothing
         _ -> pure Nothing
       pending <- sql "SELECT count(*) FROM reservations WHERE pending_command=? AND process_generation=? AND state='cleanup-pending'" [text candidate,text generation]
       started <- sql "SELECT count(*) FROM start_intents WHERE command_id=? AND process_generation=?" [text candidate,text generation]
       controlled <- sql "SELECT count(*) FROM control_intents WHERE command_id=?" [text candidate]
       pure (Just(receipt,refs,epoch,association,pending==[[SQL.SQLInteger 1]] || started==[[SQL.SQLInteger 1]] || controlled==[[SQL.SQLInteger 1]]),[])
   case outcome of Right Nothing -> discardTicketState retained; _ -> pure ()
   pure $ fmap (fmap (\(receipt,refs,epoch,association,dispatch) -> Submission receipt False
     (if dispatch then Just(DispatchTicket store candidate generation refs retained) else Nothing) refs
     (AcceptedEnqueue generation epoch candidate <$> association))) outcome

-- | Reserve bounded pre-body work without claiming command acceptance or exposing a receipt.
commandPreflight :: NFData a => CoordinationStore -> CredentialProof -> CommandRequest
  -> (ConfigurationLimits -> [(Text, Discovery)] -> Text -> Bool -> Transaction (a, [Invalidation]))
  -> IO (Either CommandFailure a)
commandPreflight store proof request action = case validateRequest request of
  Left failure -> pure (Left failure)
  Right () -> configuredCatalogues store proof $ \limits profiles catalogues _ -> transaction store $ do
    (client, _) <- authorizeRequest profiles proof request
    rows <- sql "SELECT count(*) FROM commands WHERE client_id=? AND method=? AND resource_uri=? AND idempotency_key=?"
      [text client, text (commandMethod request), text (commandResource request), text (commandKey request)]
    exists <- case rows of [[SQL.SQLInteger count]] -> pure (count /= 0); _ -> throwE StorageUnavailable
    lift (action limits catalogues client exists)

-- | Cheap fresh-version refusal, using the same check as final acceptance.
-- Matching keys still defer exact binding comparison to the normal replay path.
commandPreflightVersion :: CoordinationStore -> CredentialProof -> CommandRequest
  -> Transaction (Maybe (Text,Text,Text)) -> IO (Either CommandFailure Bool)
commandPreflightVersion store proof request version = do
  result <- commandPreflight store proof request $ \_ _ _ exists -> do
    checkedVersion <- if exists then pure(Right()) else version >>= runExceptT . checkPrecondition request
    pure(exists <$ checkedVersion,[])
  pure(result >>= id)

authorizeRequest :: [PublicProfile] -> CredentialProof -> CommandRequest -> CommandTx (Text, Text)
authorizeRequest profiles proof request = do
  client <- checked =<< lift (authorizeProfile proof (commandProfile request) (requiredScopes (commandOperation request)))
  _ <- knownProfile profiles (commandProfile request)
  epoch <- currentEpoch
  require (keyEpoch request == epoch) AuthorityChanged
  pure (client, epoch)

-- Credential validity is checked before even the authorization-filtered metadata query.
readCommand :: CoordinationStore -> CredentialProof -> Text -> IO (Either CommandFailure CommandReceipt)
readCommand store proof ident
  | not (validId ident) = pure (Left InvalidRequest)
  | otherwise = configured store proof $ \_ profiles _ -> transaction store $ do
      _ <- checked =<< lift (currentClient proof)
      let allowed = map publicId profiles
      metadata <- sql
        "SELECT c.profile_id,c.operation FROM commands c WHERE c.id=? AND EXISTS(SELECT 1 FROM credential_scopes s WHERE s.credential_id=? AND s.profile_id=c.profile_id AND s.scope='observe')"
        [text ident, text (credentialRateKey proof)]
      case metadata of
        [[SQL.SQLText profile, SQL.SQLText operation]] -> do
          require (profile `elem` allowed) Forbidden
          op <- maybe (throwE StorageUnavailable) pure (parseOperation operation)
          _ <- checked =<< lift (authorizeProfile proof profile (Observe : requiredScopes op))
          receipt <- currentReceipt ident
          require (receiptProfile receipt == profile && receiptOperation receipt == op) StorageUnavailable
          pure (receipt, [])
        _ -> throwE Forbidden

reserveDispatch :: DispatchTicket -> IO (Either CommandFailure ())
reserveDispatch = reserveDispatchWithAdmission FailFast

reserveDispatchWithAdmission :: StoreAdmission -> DispatchTicket -> IO (Either CommandFailure ())
reserveDispatchWithAdmission admission ticket@(DispatchTicket store ident generation _ state) = mask $ \restore -> do
  claimed <- claim state Unreserved Reserved
  if not claimed then pure (Left OwnershipUnavailable) else do
    revision <- freshId "command_revision_"
    restore $ transactionWithAdmission admission store $ do
      current <- liveCommand ticket
      require (receiptState current == Accepted) StateConflict
      rows <- sql "SELECT dispatch_generation FROM commands WHERE id=?" [text ident]
      require (rows == [[SQL.SQLNull]]) OwnershipUnavailable
      lift $ execute "UPDATE commands SET dispatch_generation=?,revision=? WHERE id=?"
        [text generation, text revision, text ident]
      pure ((), [commandEvent ident revision])

-- Consuming the ticket is irreversible even if storage or the callback becomes uncertain.
attemptDispatch :: DispatchTicket -> IO a -> IO (Either CommandFailure a)
attemptDispatch = attemptDispatchWithAdmission FailFast

attemptDispatchWithAdmission :: StoreAdmission -> DispatchTicket -> IO a -> IO (Either CommandFailure a)
attemptDispatchWithAdmission admission ticket action = attemptTicket admission ticket (const action)

attemptControlDispatch :: DispatchTicket -> (BS.ByteString -> IO a) -> IO (Either CommandFailure a)
attemptControlDispatch ticket action = attemptTicket FailFast ticket (maybe (throwIO OwnershipUnavailable) action)

-- The successful claim transfers the original bytes to this invocation and clears
-- the retained cell atomically. A losing invocation cannot touch the winner's bytes.
attemptTicket :: StoreAdmission -> DispatchTicket -> (Maybe BS.ByteString -> IO a) -> IO (Either CommandFailure a)
attemptTicket admission ticket@(DispatchTicket store ident generation _ state) action = mask $ \restore -> do
  (claimed,payload) <- atomicModifyIORef' state $ \old -> case old of
    TicketState Reserved bytes -> (TicketState Consumed Nothing,(True,bytes))
    _ -> (old,(False,Nothing))
  if not claimed then pure (Left OwnershipUnavailable) else do
    result <- try @SomeException $ do
      revision <- freshId "command_revision_"
      marked <- restore $ transactionWithAdmission admission store $ do
        current <- liveCommand ticket
        require (receiptState current == Accepted) StateConflict
        rows <- sql "SELECT dispatch_generation,attempted_at FROM commands WHERE id=?" [text ident]
        require (rows == [[text generation, SQL.SQLNull]]) OwnershipUnavailable
        (now, _) <- trustedTime
        lift $ execute "UPDATE commands SET attempted_at=?,state='dispatch-attempted',revision=? WHERE id=?"
          [text now, text revision, text ident]
        pure ((), [commandEvent ident revision])
      case marked of
        Left failure -> pure (Left failure)
        Right () -> Right <$> restore (action payload)
    case result of
      Right (Right value) -> pure (Right value)
      Right (Left failure) -> unresolved >> pure (Left failure)
      Left failure -> unresolved >> throwIO failure
  where
    unresolved = void (try @SomeException (recordUnresolvedWithAdmission admission ticket))

-- | Revoke only unattempted original permission. A consumed invocation owns its
-- local bytes until return and cannot be disrupted or resurrected by cleanup.
discardControlPayload :: DispatchTicket -> IO ()
discardControlPayload (DispatchTicket _ _ _ _ state) = discardTicketState state

-- The original acceptance operation must have returned or been joined first.
discardControlAttempt :: CommandAttempt -> IO ()
discardControlAttempt (CommandAttempt _ _ _ _ state _ phase) = do
  current <- readIORef phase
  unless(current==AttemptRunning)(discardTicketState state)

discardTicketState :: IORef TicketState -> IO ()
discardTicketState state = atomicModifyIORef' state $ \old -> case old of
  TicketState Consumed _ -> (old,())
  _ -> (TicketState Consumed Nothing,())

recordAcknowledgement :: DispatchTicket -> Acknowledgement -> IO (Either CommandFailure CommandReceipt)
recordAcknowledgement ticket@(DispatchTicket _ ident _ _ _) acknowledgement = observe ticket (acknowledge ident acknowledgement)

acknowledge :: Text -> Acknowledgement -> CommandReceipt -> CommandTx CommandReceipt
acknowledge ident acknowledgement current = do
  require (receiptAttemptedAt current /= Nothing) StateConflict
  require (field "commandId" (acknowledgementValue acknowledgement) == Just ident) StateConflict
  require (maybe True (== operationName (receiptOperation current)) (field "command" (acknowledgementValue acknowledgement))) StateConflict
  case receiptAcknowledgement current of
    Just old | old == acknowledgement -> pure current
    Just old -> require (ackRank acknowledgement > ackRank old && ackRank old < 3) StateConflict >> advance
    Nothing -> advance
  where
    advance = do
      require (receiptState current `elem` [DispatchAttempted, Acknowledged, Unresolved, EffectObserved]) StateConflict
      pure current {receiptAcknowledgement = Just acknowledgement,
        receiptState = if receiptState current == EffectObserved then EffectObserved else Acknowledged}

recordEffect :: DispatchTicket -> Effect -> IO (Either CommandFailure CommandReceipt)
recordEffect ticket effect = recordEffectWith ticket effect (pure [])

-- | Owning resource completion and command effect commit together after physical proof.
recordEffectWith :: DispatchTicket -> Effect -> Transaction [Invalidation] -> IO (Either CommandFailure CommandReceipt)
recordEffectWith = recordEffectWithAdmission FailFast

recordEffectWithAdmission :: StoreAdmission -> DispatchTicket -> Effect -> Transaction [Invalidation] -> IO (Either CommandFailure CommandReceipt)
recordEffectWithAdmission admission ticket@(DispatchTicket _ ident _ refs _) effect finalTransition = observeWithAdmission admission ticket finalTransition $ \current -> do
  require (receiptAttemptedAt current /= Nothing) StateConflict
  validateEffectBinding (receiptOperation current) ident refs effect
  case receiptEffect current of
    Just old -> require (old == effect) StateConflict >> pure current
    Nothing -> do
      require (receiptState current `elem` [DispatchAttempted, Acknowledged, Unresolved]) StateConflict
      pure current {receiptState = EffectObserved, receiptEffect = Just effect}

effectKind :: Operation -> Maybe Text
effectKind operation = case operation of
  SetInput -> Just "input-changed"
  RemoveInput -> Just "input-changed"
  Enqueue -> Just "enqueued"
  Withdraw -> Just "withdrawn"
  Approve -> Just "started"
  Discard -> Just "discarded"
  Cancel -> Just "cancelled"
  Steer -> Just "steered"
  Retry -> Just "retried"
  ChooseRecovery -> Just "recovery-chosen"
  Redirect -> Just "redirected"
  Answer -> Just "answer-accepted"
  Export -> Just "exported"
  Restart -> Just "lineage-created"
  Resume -> Just "lineage-created"
  Fork -> Just "lineage-created"
  _ -> Nothing

validateEffectBinding :: Operation -> Text -> CommandReferences -> Effect -> CommandTx ()
validateEffectBinding operation ident refs effect = do
  require (field "kind" (effectValue effect) == effectKind operation && effectKind operation /= Nothing) StateConflict
  let value = effectValue effect
      references = concat
        [ maybe [] (\key -> ["/v1/requests/" <> key]) (referenceRequest refs),
          maybe [] (\key -> ["/v1/preparations/" <> key]) (referencePreparation refs),
          maybe [] (\key -> ["/v1/decisions/" <> key]) (referenceDecision refs),
          maybe [] (\key -> map (("/v1/runs/" <> key) <>) ["", "/snapshot", "/control", "/exports", "/lineage-requests"]) (referenceRun refs)]
  exports <- sql "SELECT id,artifact_id FROM exports WHERE command_id=?" [text ident]
  let exportReferences = concat [["/v1/exports/" <> exportId, "/v1/artifacts/" <> artifact] | [SQL.SQLText exportId, SQL.SQLText artifact] <- exports]
  require (maybe False (`elem` (references <> exportReferences)) (field "resource" value)) StateConflict

recordUnresolved :: DispatchTicket -> IO (Either CommandFailure CommandReceipt)
recordUnresolved = recordUnresolvedWithAdmission FailFast

recordUnresolvedWithAdmission :: StoreAdmission -> DispatchTicket -> IO (Either CommandFailure CommandReceipt)
recordUnresolvedWithAdmission admission ticket = observeWithAdmission admission ticket (pure []) $ \current -> do
  require (receiptState current `elem` [Accepted, DispatchAttempted, Acknowledged, Unresolved]) StateConflict
  pure current {receiptState = Unresolved}

recordRefusal :: DispatchTicket -> Text -> IO (Either CommandFailure CommandReceipt)
recordRefusal ticket refusal = observe ticket $ \current -> do
  require (refusal `elem` ["state-conflict", "stale-revision", "unsupported-operation", "ownership-unavailable",
    "supervision-unavailable", "invalid-answer", "invalid-lineage-edit", "export-conflict", "storage-unavailable"]) InvalidRequest
  require (receiptEffect current == Nothing && maybe True ((== 3) . ackRank) (receiptAcknowledgement current)) StateConflict
  case receiptRefusal current of
    Just previous -> require (previous == refusal) StateConflict >> pure current
    Nothing -> pure current {receiptState = Refused, receiptRefusal = Just refusal}

observe :: DispatchTicket -> (CommandReceipt -> CommandTx CommandReceipt) -> IO (Either CommandFailure CommandReceipt)
observe ticket = observeWith ticket (pure [])

observeWith :: DispatchTicket -> Transaction [Invalidation] -> (CommandReceipt -> CommandTx CommandReceipt) -> IO (Either CommandFailure CommandReceipt)
observeWith = observeWithAdmission FailFast

observeWithAdmission :: StoreAdmission -> DispatchTicket -> Transaction [Invalidation] -> (CommandReceipt -> CommandTx CommandReceipt) -> IO (Either CommandFailure CommandReceipt)
observeWithAdmission admission ticket@(DispatchTicket store ident _ _ _) finalTransition update = do
  revision <- freshId "command_revision_"
  transactionWithAdmission admission store $ do
    current <- liveCommand ticket
    next <- update current
    if next == current then pure (current, []) else do
      changes <- lift finalTransition
      lift $ execute "UPDATE commands SET state=?,acknowledgement=?,effect_evidence=?,refusal=?,revision=? WHERE id=?"
        [text (stateName (receiptState next)), maybe SQL.SQLNull (SQL.SQLBlob . encoded) (receiptAcknowledgement next),
         maybe SQL.SQLNull (SQL.SQLBlob . encoded) (receiptEffect next), optional (receiptRefusal next), text revision, text ident]
      pure (next, changes <> [commandEvent ident revision])

-- | Atomic native evidence publication. This creates no dispatch capability.
recordRuntimeObservation :: Text -> Text -> Maybe Acknowledgement -> Maybe Effect -> Transaction [Invalidation]
recordRuntimeObservation ident revision acknowledgement effect = do
  binding <- query "SELECT count(*) FROM control_intents WHERE command_id=?" [text ident]
  unless (binding==[[SQL.SQLInteger 1]]) (refuseTransaction OwnershipUnavailable)
  recordObservation ident revision acknowledgement effect

-- | Complete a durably witnessed export, without creating dispatch authority.
-- The artifact owner verifies the exact retained destination before this transaction.
recordExportObservation :: Text -> Text -> Text -> Effect -> Transaction [Invalidation]
recordExportObservation ident exportId revision effect = do
  binding <- query "SELECT r.id,r.profile_id,c.profile_id,c.resource_uri,c.body_sha256,c.body_bytes,a.private_reference,e.name FROM exports e JOIN runs r ON r.id=e.run_id JOIN artifacts a ON a.id=e.artifact_id AND a.run_id=e.run_id JOIN commands c ON c.id=e.command_id JOIN service_metadata s ON s.singleton=1 WHERE e.id=? AND c.id=? AND c.operation='export' AND c.run_id=e.run_id AND c.authority_epoch=s.authority_epoch AND e.receipt IS NOT NULL AND e.state IN ('published','unresolved') AND c.refusal IS NULL AND c.attempted_at IS NOT NULL AND c.method='POST' AND c.media_type='application/json'" [text exportId,text ident]
  case binding of
    [[SQL.SQLText run,SQL.SQLText profile,SQL.SQLText commandProfileId,SQL.SQLText resource,SQL.SQLBlob digest,SQL.SQLInteger count,SQL.SQLBlob private,SQL.SQLText name]] -> do
      let collection = "/v1/runs/" <> run <> "/exports"
      result <- runExceptT $ do
        receipt <- originalReceipt ident
        require (commandProfileId == profile && resource == collection
          && receiptProfile receipt == profile && receiptResource receipt == collection
          && receiptOperation receipt == Export && receiptState receipt == Accepted) OwnershipUnavailable
        require (exportAcceptanceMatches exportId name digest count private) OwnershipUnavailable
      either refuseTransaction pure result
    _ -> refuseTransaction OwnershipUnavailable
  recordObservation ident revision Nothing (Just effect)

-- Only the export owner's immutable private reference carries parsed-name provenance.
-- Its digest/count refer to the accepted raw body, never a re-encoded mutation.
exportAcceptanceMatches :: Text -> Text -> BS.ByteString -> Int64 -> BS.ByteString -> Bool
exportAcceptanceMatches exportId name digest count private = case decodeStrictValue private of
  Right (Object fields) | KM.size fields == 5,
    KM.lookup "exportId" fields == Just (String exportId),
    KM.lookup "acceptedName" fields == Just (String name), validExportName name,
    BS.length digest == 32, count > 0, count <= 2097152,
    KM.lookup "acceptedBodySha256" fields == Just (String (TE.decodeUtf8 (convertToBase Base16 digest))),
    KM.lookup "acceptedBodyBytes" fields == Just (String (T.pack (show count))),
    Just (String bytes) <- KM.lookup "bytes" fields ->
      case reads (T.unpack bytes) of
        [(size,"")] -> size > 0 && size <= maxArtifactBytes && T.pack (show size) == bytes
        _ -> False
  _ -> False

recordObservation :: Text -> Text -> Maybe Acknowledgement -> Maybe Effect -> Transaction [Invalidation]
recordObservation ident revision acknowledgement effect = do
  result <- runExceptT $ do
    current <- currentReceipt ident
    next <- maybe (pure current) (\ack -> acknowledge ident ack current) acknowledgement
    updated <- case effect of
      Nothing -> pure next
      Just value -> do
        rows <- sql "SELECT request_id,run_id,preparation_id,decision_id FROM commands WHERE id=?" [text ident]
        refs <- case rows of
          [[r,u,p,d]] -> CommandReferences <$> sqlOptionalText r <*> sqlOptionalText u <*> sqlOptionalText p <*> sqlOptionalText d
          _ -> throwE StorageUnavailable
        require (receiptAttemptedAt next /= Nothing) StateConflict
        validateEffectBinding (receiptOperation next) ident refs value
        require (maybe True (== value) (receiptEffect next)) StateConflict
        require (receiptRefusal next == Nothing) StateConflict
        pure next {receiptState=EffectObserved,receiptEffect=Just value}
    if updated==current then pure [] else do
      lift $ execute "UPDATE commands SET state=?,acknowledgement=?,effect_evidence=?,revision=? WHERE id=?"
        [text(stateName(receiptState updated)),maybe SQL.SQLNull (SQL.SQLBlob . encoded) (receiptAcknowledgement updated),
         maybe SQL.SQLNull (SQL.SQLBlob . encoded) (receiptEffect updated),text revision,text ident]
      pure [commandEvent ident revision]
  either refuseTransaction pure result

-- The owning retention module supplies a real transactional inactivity check for this URI.
-- There is deliberately no public retire-by-ID operation or default inactivity proof.
retireReceipt :: CoordinationStore -> Text -> (Text -> Transaction (Maybe Text)) -> IO (Either CommandFailure ())
retireReceipt store ident inactiveSince
  | not (validId ident) = pure (Left InvalidRequest)
  | otherwise = do
      revision <- freshId "command_revision_"
      transaction store $ do
        rows <- sql "SELECT resource_uri,retired FROM commands WHERE id=?" [text ident]
        case rows of
          [[_, SQL.SQLInteger 1]] -> pure ((), [])
          [[SQL.SQLText uri, SQL.SQLInteger 0]] -> do
            since <- lift (inactiveSince uri)
            stamp <- maybe (throwE StateConflict) pure since
            require (validTimestamp stamp) InvalidRequest
            oldEnough <- sql "SELECT julianday(?)<=julianday('now')-30" [text stamp]
            require (oldEnough == [[SQL.SQLInteger 1]]) StateConflict
            lift $ execute
              "UPDATE commands SET retired=1,body=NULL,body_sha256=NULL,body_bytes=NULL,media_type=NULL,precondition=NULL,receipt=NULL,acknowledgement=NULL,effect_evidence=NULL,reserved_bytes=?,revision=? WHERE id=?"
              [SQL.SQLInteger tombstoneCapacity, text revision, text ident]
            pure ((), [commandEvent ident revision])
          _ -> throwE ResourceUnavailable

configured :: CoordinationStore -> CredentialProof -> (ConfigurationLimits -> [PublicProfile] -> StoreIdentity -> IO (Either CommandFailure a)) -> IO (Either CommandFailure a)
configured store proof action = configuredCatalogues store proof $ \limits profiles _ identity -> action limits profiles identity

configuredCatalogues :: CoordinationStore -> CredentialProof -> (ConfigurationLimits -> [PublicProfile] -> [(Text, Discovery)] -> StoreIdentity -> IO (Either CommandFailure a)) -> IO (Either CommandFailure a)
configuredCatalogues store proof action = do
  result <- try @StoreFailure $ withStoreCatalogues store $ \limits profiles catalogues -> do
    identity <- storeIdentity store
    if proofGeneration proof /= storeProcessGeneration identity then pure (Left Unauthenticated)
      else action limits profiles catalogues identity
  pure $ case result of
    Left _ -> Left StorageUnavailable
    Right (Left _) -> Left StorageUnavailable
    Right (Right value) -> value

transaction :: NFData a => CoordinationStore -> CommandTx (a, [Invalidation]) -> IO (Either CommandFailure a)
transaction = transactionWithAdmission FailFast

transactionWithAdmission :: NFData a => StoreAdmission -> CoordinationStore -> CommandTx (a, [Invalidation]) -> IO (Either CommandFailure a)
transactionWithAdmission admission store action = do
  result <- try @CommandFailure $ try @StoreFailure $ runTransactionWithAdmission admission store $ do
    outcome <- runExceptT action
    either refuseTransaction pure outcome
  pure $ case result of
    Left failure -> Left failure
    Right (Left _) -> Left StorageUnavailable
    Right (Right value) -> Right value

liveCommand :: DispatchTicket -> CommandTx CommandReceipt
liveCommand (DispatchTicket _ ident generation refs _) = do
  currentGeneration <- lift transactionGeneration
  require (currentGeneration == generation) OwnershipUnavailable
  rows <- sql "SELECT authority_epoch,dispatch_generation,request_id,run_id,preparation_id,decision_id FROM commands WHERE id=?" [text ident]
  epoch <- currentEpoch
  case rows of
    [[SQL.SQLText authority, storedGeneration, request, run, preparation, decision]] -> do
      require (authority == epoch) AuthorityChanged
      require (storedGeneration == SQL.SQLNull || storedGeneration == text generation) OwnershipUnavailable
      require ([request, run, preparation, decision] == map optional
        [referenceRequest refs, referenceRun refs, referencePreparation refs, referenceDecision refs]) OwnershipUnavailable
      currentReceipt ident
    _ -> throwE ResourceUnavailable

originalReceipt :: Text -> CommandTx CommandReceipt
originalReceipt ident = do
  rows <- sql "SELECT receipt,retired FROM commands WHERE id=?" [text ident]
  case rows of
    [[SQL.SQLBlob bytes, SQL.SQLInteger 0]] -> do
      receipt <- checked (decodeReceipt bytes)
      require (receiptId receipt == ident) StorageUnavailable
      pure receipt
    [[_, SQL.SQLInteger 1]] -> throwE ReceiptExpired
    _ -> throwE StorageUnavailable

currentReceipt :: Text -> CommandTx CommandReceipt
currentReceipt ident = do
  original <- originalReceipt ident
  rows <- sql "SELECT state,attempted_at,acknowledgement,effect_evidence,refusal FROM commands WHERE id=?" [text ident]
  case rows of
    [[SQL.SQLText state, attempted, acknowledgement, effect, refusal]] -> do
      currentState <- maybe (throwE StorageUnavailable) pure (parseState state)
      attemptTime <- sqlOptionalText attempted
      ack <- decodeOptional acknowledgement
      observed <- decodeOptional effect
      refused <- sqlOptionalText refusal
      let receipt = original {receiptState = currentState, receiptAttemptedAt = attemptTime,
            receiptAcknowledgement = ack, receiptEffect = observed, receiptRefusal = case refused of Nothing -> receiptRefusal original; Just code -> Just code}
      checked (decodeReceipt (encoded receipt))
    _ -> throwE StorageUnavailable

checkPrecondition :: CommandRequest -> Maybe (Text, Text, Text) -> CommandTx ()
checkPrecondition request current
  | commandOperation request `elem` [Create, Capture] = require (commandPrecondition request == Nothing && current == Nothing) InvalidPrecondition
  | otherwise = do
      supplied <- maybe (throwE PreconditionRequired) pure (commandPrecondition request)
      (uri, profile, revision) <- maybe (throwE ResourceUnavailable) pure current
      require (profile == commandProfile request) Forbidden
      require (uri == commandResource request && validRevision revision) InvalidPrecondition
      require (supplied == "\"" <> revision <> "\"") StaleRevision

checkCapacity :: ConfigurationLimits -> Operation -> CommandTx ()
checkCapacity limits operation = do
  rows <- sql "SELECT bytes FROM command_ledger_usage WHERE singleton=1" []
  used <- case rows of [[SQL.SQLInteger value]] -> pure value; _ -> throwE StorageUnavailable
  let total = fromIntegral (limitGlobalMutationLedgerBytes limits)
      reserve = min total (16 * commandCapacity)
      ceilingBytes = if operation == Cancel then total else total - reserve
  require (used <= ceilingBytes - commandCapacity) StorageQuota

checkRate :: ConfigurationLimits -> CredentialProof -> Operation -> Int64 -> CommandTx ()
checkRate limits proof operation minute = do
  rows <- if operation == Cancel
    then sql "SELECT minute,count FROM command_safety_rate WHERE singleton=1" []
    else sql "SELECT minute,count FROM command_ordinary_rate WHERE credential_id=?" [text (credentialRateKey proof)]
  used <- case rows of
    [] -> pure 0
    [[SQL.SQLInteger previous, SQL.SQLInteger count]] -> pure (if minute > previous then 0 else count)
    _ -> throwE StorageUnavailable
  let allowance = if operation == Cancel then fromIntegral (limitSafetyControlsPerMinute limits) else 30
  require (used < allowance) RateLimit

chargeRate :: CredentialProof -> Operation -> Int64 -> CommandTx ()
chargeRate proof operation minute = lift $
  if operation == Cancel then execute
    "UPDATE command_safety_rate SET count=CASE WHEN ?>minute THEN 1 ELSE count+1 END,minute=max(minute,?) WHERE singleton=1"
    [SQL.SQLInteger minute, SQL.SQLInteger minute]
  else execute
    "INSERT INTO command_ordinary_rate VALUES (?,?,1) ON CONFLICT(credential_id) DO UPDATE SET count=CASE WHEN excluded.minute>minute THEN 1 ELSE count+1 END,minute=max(minute,excluded.minute)"
    [text (credentialRateKey proof), SQL.SQLInteger minute]

trustedTime :: CommandTx (Text, Int64)
trustedTime = do
  rows <- sql "SELECT strftime('%Y-%m-%dT%H:%M:%fZ','now'),CAST(unixepoch('now')/60 AS INTEGER)" []
  case rows of [[SQL.SQLText stamp, SQL.SQLInteger minute]] -> pure (stamp, minute); _ -> throwE StorageUnavailable
currentEpoch :: CommandTx Text
currentEpoch = do
  rows <- sql "SELECT authority_epoch FROM service_metadata WHERE singleton=1" []
  case rows of [[SQL.SQLText epoch]] -> pure epoch; _ -> throwE StorageUnavailable
knownProfile :: [PublicProfile] -> Text -> CommandTx PublicProfile
knownProfile profiles ident = maybe (throwE Forbidden) pure (find ((== ident) . publicId) profiles)

validateRequest :: CommandRequest -> Either CommandFailure ()
validateRequest r = do
  let operation = commandOperation r
      bodyLimit = if operation == Capture then 67108864 else 2097152
      precondition = commandPrecondition r
  unless (validId (commandProfile r) && commandMethod r == "POST" && validResource (commandResource r)
    && operationResource operation (commandResource r)) (Left InvalidRequest)
  unless (BS.length (commandBody r) <= bodyLimit) (Left SizeLimit)
  unless (not (T.null (commandMediaType r)) && T.length (commandMediaType r) <= 256
    && T.all (\c -> c >= ' ' && c <= '~') (commandMediaType r)) (Left InvalidRequest)
  let parts = T.splitOn "." (commandKey r)
  unless (T.length (commandKey r) <= 128 && case parts of
    [epoch, nonce] -> validId epoch && T.length epoch <= 105 && validId nonce && T.length nonce >= 22
    _ -> False) (Left InvalidRequest)
  mapM_ (\etag -> unless (T.length etag >= 3 && T.head etag == '"' && T.last etag == '"'
    && validRevision (T.dropEnd 1 (T.drop 1 etag))) (Left InvalidPrecondition)) precondition

operationResource :: Operation -> Text -> Bool
operationResource operation uri = case T.splitOn "/" (T.takeWhile (/= '?') uri) of
  ["", "v1", "requests"] -> operation == Create
  ["", "v1", "requests", ident] -> validId ident && operation `elem` [SetInput, RemoveInput, Enqueue, Withdraw]
  ["", "v1", "captures"] -> operation == Capture && maybe False validId (T.stripPrefix "/v1/captures?requestId=" uri)
  ["", "v1", "preparations", ident] -> validId ident && operation `elem` [Approve, Discard]
  ["", "v1", "decisions", ident] -> validId ident && operation `elem` [Answer, ChooseRecovery]
  ["", "v1", "runs", ident, "control"] -> validId ident && operation `elem` [Cancel, Steer, Retry, ChooseRecovery, Redirect, Answer]
  ["", "v1", "runs", ident, "exports"] -> validId ident && operation == Export
  ["", "v1", "runs", ident, "lineage-requests"] -> validId ident && operation `elem` [Restart, Resume, Fork]
  _ -> False

keyEpoch :: CommandRequest -> Text
keyEpoch = T.takeWhile (/= '.') . commandKey
validReferences :: CommandReferences -> Bool
validReferences refs = all (maybe True validId) [referenceRequest refs, referenceRun refs, referencePreparation refs, referenceDecision refs]
commandEvent :: Text -> Text -> Invalidation
commandEvent ident revision = Invalidation "command.changed" ("/v1/commands/" <> ident) revision
freshId :: Text -> IO Text
freshId prefix = do
  bytes <- getRandomBytes 24 :: IO BS.ByteString
  pure (prefix <> TE.decodeUtf8 (convertToBase Base16 bytes))
claim :: IORef TicketState -> TicketPhase -> TicketPhase -> IO Bool
claim state expected next = atomicModifyIORef' state $ \old@(TicketState phase payload) ->
  if phase == expected then (TicketState next payload, True) else (old, False)
ackRank :: Acknowledgement -> Int
ackRank ack = case field "state" (acknowledgementValue ack) of
  Just "accepted" -> 0
  Just "queued" -> 1
  Just "delivered" -> 2
  _ -> 3
field :: Text -> Value -> Maybe Text
field key (Object value) = case KM.lookup (Key.fromText key) value of Just (String textValue) -> Just textValue; _ -> Nothing
field _ _ = Nothing
nullField :: Text -> Value -> Bool
nullField key (Object value) = KM.lookup (Key.fromText key) value == Just Null
nullField _ _ = False
-- Count a conservative JSON encoding of all fixed/binding/dispatch metadata
-- inside the unchanged 16KiB component, also retained by non-content tombstones.
metadataValue :: SQL.SQLData -> CommandTx Value
metadataValue SQL.SQLNull=pure Null
metadataValue (SQL.SQLText value)=pure(String value)
metadataValue (SQL.SQLInteger value)=pure(Number(fromIntegral value))
metadataValue _=throwE StorageUnavailable

sql :: Text -> [SQL.SQLData] -> CommandTx [[SQL.SQLData]]
sql statement values = lift (query statement values)
text :: Text -> SQL.SQLData
text = SQL.SQLText
optional :: Maybe Text -> SQL.SQLData
optional = maybe SQL.SQLNull text
sqlOptionalText :: SQL.SQLData -> CommandTx (Maybe Text)
sqlOptionalText SQL.SQLNull = pure Nothing
sqlOptionalText (SQL.SQLText value) = pure (Just value)
sqlOptionalText _ = throwE StorageUnavailable
decodeOptional :: FromJSON a => SQL.SQLData -> CommandTx (Maybe a)
decodeOptional SQL.SQLNull = pure Nothing
decodeOptional (SQL.SQLBlob bytes) = either (const (throwE StorageUnavailable)) (pure . Just) (eitherDecodeStrict' bytes)
decodeOptional _ = throwE StorageUnavailable
checked :: Either CommandFailure a -> CommandTx a
checked = either throwE pure
require :: Bool -> CommandFailure -> CommandTx ()
require condition failure = unless condition (throwE failure)
