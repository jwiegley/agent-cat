{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeApplications #-}

-- | Store status, quarantine discovery, cleanup evidence and quarantine
-- release for local administration. Only the release changes Store rows and
-- appends to the manager log. No operation reads or signals a stored process
-- identity, or adopts a worker.
module Agentic.Manager.Quarantine
  ( StoreState (..), reportStatus, reportStoreCheck, unavailableStoreCheck,
    QuarantineState (..), CleanupEvidence (..), inspectQuarantine, checkQuarantine, cleanupEvidenceLifetime,
    releaseQuarantine
  ) where

import Agentic.Manager.Administration (localAdministrator, recordAdministration, recordAdministrationReceipt)
import Agentic.Manager.Flow (AdministrationBody (ReleaseAdministration))
import Agentic.Manager.Protocol.Command (encoded, validId)
import Agentic.Manager.Protocol.LocalAdmin (AdminFailure (..), adminError, adminSuccess)
import Agentic.Manager.Store
import Agentic.Runtime
  ( FlowLiveness (FlowLive), FlowReport (..), Position (..), PrivateRoot, RunId, closePrivateRoot, mkRunId,
    openPrivateSubroot, privateRootPath, probePrivateLockAt, readFlow, readFlowLine, runIdText, runLogName )
import Control.DeepSeq (NFData (rnf))
import Control.Exception (IOException, bracket, throwIO, try)
import Control.Monad (forM, unless)
import Crypto.Hash (Digest, SHA256, hash)
import Crypto.Random (getRandomBytes)
import Data.Aeson (Value (Null), object, (.=))
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Key as Key
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import qualified Data.ByteString as BS
import qualified Data.Text.Encoding as TE
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (NominalDiffTime, addUTCTime, getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import qualified Database.SQLite3 as SQL

-- | The lifetime that answers @status@: the live channel of a serving
-- manager, or offline administration while no manager serves.
data StoreState = StoreServing | StoreStopped

stateName :: StoreState -> Text
stateName state = case state of
  StoreServing -> "serving"
  StoreStopped -> "stopped"

-- | The durable identities of the Store, the process generation of the
-- answering lifetime, and the count of reservations that are not released.
-- Quarantined reservations count, since they keep their slots and resource
-- keys until cleanup evidence releases them.
reportStatus :: StoreState -> CoordinationStore -> IO BS.ByteString
reportStatus state store = answered "status" $ do
  identity <- storeIdentity store
  active <- runRead store $ do
    rows <- query "SELECT count(*) FROM reservations WHERE state!='released'" []
    case rows of
      [[SQL.SQLInteger count]] | count >= 0 && count <= 16 -> pure (fromIntegral count :: Int)
      _ -> refuseTransaction StoreIntegrity
  pure $ object
    ["state" .= stateName state, "authorityEpoch" .= storeAuthorityEpoch identity,
     "streamId" .= storeStreamId identity, "processGeneration" .= storeProcessGeneration identity,
     "activeReservations" .= active]

-- | A SQLite quick check of the open Store, and the identities of its
-- quarantined claims in identity order: each reservation in state
-- @quarantined@ and each claim that a restoration carried forward. More than
-- 256 claims refuse with @size-limit@.
reportStoreCheck :: CoordinationStore -> IO BS.ByteString
reportStoreCheck store = answered "check-store" $ do
  (integrity, identities) <- runRead store $ do
    checked <- query "SELECT quick_check FROM pragma_quick_check" []
    rows <- query "SELECT id FROM reservations WHERE state='quarantined' UNION SELECT id FROM restoration_quarantine ORDER BY id LIMIT 257" []
    unless (length rows <= 256) (refuseTransaction StoreLimit)
    identities <- forM rows $ \row -> case row of
      [SQL.SQLText ident] | validId ident -> pure ident
      _ -> refuseTransaction StoreIntegrity
    pure (if checked == [[SQL.SQLText "ok"]] then "valid" else "corrupt" :: Text, identities)
  pure (storeCheck integrity identities)

-- | The @check-store@ answer when the Store cannot be opened.
unavailableStoreCheck :: BS.ByteString
unavailableStoreCheck = adminSuccess "check-store" (storeCheck "unavailable" [])

storeCheck :: Text -> [Text] -> Value
storeCheck integrity identities = object ["integrity" .= integrity, "quarantineIds" .= identities]

-- | The answer of @check-quarantine@ for one quarantined claim.
data QuarantineState
  = -- | Cleanup evidence holds: the reservation never launched a run, the
    -- run store of its run holds the terminal record of the runtime, or the
    -- owner lock of its run is free.
    QuarantineClean
  | -- | The reservation launched a run, its run store holds no terminal
    -- record, and the owner lock of its run is held, absent or not a
    -- private regular file.
    QuarantineCleanupRequired
  | -- | The run store cannot be read, or the claim is one that a restoration
    -- carried forward, whose run the Store does not record.
    QuarantineUnverifiable
  deriving (Eq, Show)

quarantineStateName :: QuarantineState -> Text
quarantineStateName state = case state of
  QuarantineClean -> "clean"
  QuarantineCleanupRequired -> "cleanup-required"
  QuarantineUnverifiable -> "unverifiable"

-- | The cleanup evidence of a clean claim: the canonical JSON bytes of its
-- facts, their lowercase SHA-256 digest, and the identity
-- @cleanup_@ followed by the first 32 hexadecimal digits of the digest.
-- Every fact is durable or names the answering lifetime, so two checks in one
-- lifetime give the same evidence, and a new lifetime gives new evidence.
data CleanupEvidence = CleanupEvidence
  { evidenceFacts :: !BS.ByteString,
    evidenceDigest :: !Text,
    evidenceId :: !Text
  } deriving (Eq, Show)

-- | The time, in seconds after the check, at which the evidence that
-- @check-quarantine@ returns expires.
cleanupEvidenceLifetime :: NominalDiffTime
cleanupEvidenceLifetime = 600

-- What the Store records about one quarantine identity.
data Claim
  = ClaimAbsent
  | ClaimNotQuarantined
  | ClaimRestored
  | ClaimUnlaunched !Text ![(Text, Value)]
  | ClaimLaunched !Text !Text !Text !RunId
  deriving (Eq)

instance NFData Claim where
  rnf claim = case claim of
    ClaimUnlaunched request facts -> rnf (request, facts)
    ClaimLaunched request run recorded native -> rnf (request, run, recorded, runIdText native)
    _ -> ()

-- | Inspect one quarantine identity with the current process generation. An
-- unknown identity and a reservation that is not quarantined refuse with
-- 'StateConflict'. The Store file slot and one read transaction are taken in
-- the lock order file slot, configuration, database. A launched reservation
-- reads the run log of its run with the runtime readers: the first event
-- record whose event ends the run is the terminal record. Without a terminal
-- record, the free owner lock of the run shows that its inner frontend worker
-- has ended.
inspectQuarantine :: CoordinationStore -> Text -> IO (QuarantineState, Maybe CleanupEvidence)
inspectQuarantine store ident = withStoreFiles store $ \root -> do
  generation <- storeProcessGeneration <$> storeIdentity store
  claim <- runRead store (readClaim ident)
  classify root generation ident claim

-- | The state and cleanup evidence of a claim that the Store records, under
-- the held file slot, with the given process generation.
classify :: PrivateRoot -> Text -> Text -> Claim -> IO (QuarantineState, Maybe CleanupEvidence)
classify root generation ident claim =
  case claim of
    ClaimAbsent -> throwIO StateConflict
    ClaimNotQuarantined -> throwIO StateConflict
    ClaimRestored -> pure (QuarantineUnverifiable, Nothing)
    ClaimUnlaunched _ facts ->
      pure (QuarantineClean, Just (evidence (("evidence", "no-launch") : ("processGeneration", toValue generation) : facts)))
    ClaimLaunched _ run recorded native -> do
      found <- try @IOException (try @StoreFailure (terminalRecord root recorded native))
      case found of
        Right (Right (Just (Position position, bytes))) ->
          pure (QuarantineClean, Just (evidence
            [("evidence", "terminal-record"), ("reservationId", toValue ident), ("runId", toValue run),
             ("position", toValue position), ("recordSha256", toValue (sha256 bytes)),
             ("processGeneration", toValue generation)]))
        Right (Right Nothing) -> do
          released <- ownerReleased root recorded native
          pure $ if released
            then (QuarantineClean, Just (evidence
              [("evidence", "owner-released"), ("reservationId", toValue ident), ("runId", toValue run),
               ("processGeneration", toValue generation)]))
            else (QuarantineCleanupRequired, Nothing)
        _ -> pure (QuarantineUnverifiable, Nothing)
  where
    toValue :: Aeson.ToJSON a => a -> Value
    toValue = Aeson.toJSON

-- | The frozen @check-quarantine@ result. A clean claim carries its evidence
-- and expires 'cleanupEvidenceLifetime' after the check. Every other state
-- carries no evidence and no expiry.
checkQuarantine :: CoordinationStore -> Text -> IO BS.ByteString
checkQuarantine store ident = answered "check-quarantine" $ do
  generation <- storeProcessGeneration <$> storeIdentity store
  (state, found) <- inspectQuarantine store ident
  expiry <- case found of
    Nothing -> pure Null
    Just _ -> Aeson.toJSON . T.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" . addUTCTime cleanupEvidenceLifetime <$> getCurrentTime
  pure $ object
    ["quarantineId" .= ident, "state" .= quarantineStateName state,
     "cleanupEvidenceId" .= fmap evidenceId found, "cleanupEvidenceDigest" .= fmap evidenceDigest found,
     "processGeneration" .= generation, "expiresAt" .= expiry]

-- | Release one quarantined reservation for reuse. The wake action runs after
-- the COMMIT and after the receipt: the live channel passes the wake of its
-- admission controller, and offline administration passes nothing.
--
-- The Store file slot, the configuration guard and the database are taken in
-- that lock order, each within its five-second allowance. Under the held file
-- slot and configuration guard the release reads the claim, computes its
-- cleanup evidence again with the current process generation, as
-- @check-quarantine@ does, and then commits one transaction. An unknown
-- identity and a reservation that is not quarantined, a released one
-- included, refuse with 'StateConflict'. Evidence that is not clean, or whose
-- identity or digest differs from the supplied values, refuses with
-- 'CleanupUnverified'. So does a claim whose Store facts changed between the
-- read and the transaction. A refusal changes nothing.
--
-- The transaction deletes the resource keys of the reservation, sets it
-- @released@ with no slot, advances the revision of its request, sets a
-- @reserved@ request admission to @released@, appends the @request.changed@
-- invalidation of the request, and appends the command record of the release
-- to the manager log as its last step. After the COMMIT the receipt follows.
-- The run of the reservation keeps its supervision, and no run store changes.
releaseQuarantine :: CoordinationStore -> IO () -> Text -> Text -> Text -> IO BS.ByteString
releaseQuarantine store wake ident suppliedId suppliedDigest = do
  principal <- localAdministrator
  attempted <- attempt operation $ withStoreFiles store $ \root -> do
    revision <- ("request_revision_" <>) . TE.decodeUtf8 . convertToBase Base16 <$> (getRandomBytes 24 :: IO BS.ByteString)
    configured <- withStoreConfiguration store $ \_ _ -> do
      generation <- storeProcessGeneration <$> storeIdentity store
      claim <- runRead store (readClaim ident)
      found <- classify root generation ident claim
      request <- case (found, claim) of
        ((QuarantineClean, Just current), ClaimUnlaunched request _)
          | matches current -> pure request
        ((QuarantineClean, Just current), ClaimLaunched request _ _ _)
          | matches current -> pure request
        _ -> throwIO CleanupUnverified
      runTransaction store $ do
        unchanged <- (== claim) <$> readClaim ident
        unless unchanged (refuseTransaction CleanupUnverified)
        execute "DELETE FROM reservation_resources WHERE reservation_id=?" [SQL.SQLText ident]
        execute "UPDATE reservations SET state='released',slot=NULL,request_revision=? WHERE id=? AND state='quarantined'" [SQL.SQLText revision, SQL.SQLText ident]
        execute "UPDATE requests SET admission=CASE WHEN admission='reserved' THEN 'released' ELSE admission END,revision=? WHERE id=?" [SQL.SQLText revision, SQL.SQLText request]
        logged <- recordAdministration store principal (ReleaseAdministration ident request suppliedId suppliedDigest)
        pure (logged, [Invalidation "request.changed" ("/v1/requests/" <> request) revision])
    either (const (throwIO StorageUnavailable)) pure configured
  case attempted of
    Left refusal -> pure refusal
    Right logged -> do
      response <- recordAdministrationReceipt store principal logged
        (adminSuccess operation (object ["quarantineId" .= ident, "state" .= ("released" :: Text)]))
      wake
      pure response
  where
    operation = "release-quarantine"
    matches current = evidenceId current == suppliedId && evidenceDigest current == suppliedDigest

-- The claim that the identity names. A reservation launched a run when a
-- start intent or a run row names it, directly or through one of its
-- preparations. The facts of an unlaunched reservation are its identity, its
-- request with the current phase, the states of its preparations and of its
-- admission observation, and its resource keys.
readClaim :: Text -> Transaction Claim
readClaim ident = do
  reservations <- query "SELECT request_id,state FROM reservations WHERE id=?" [SQL.SQLText ident]
  case reservations of
    [] -> do
      restored <- query "SELECT 1 FROM restoration_quarantine WHERE id=?" [SQL.SQLText ident]
      pure (if null restored then ClaimAbsent else ClaimRestored)
    [[SQL.SQLText request, SQL.SQLText "quarantined"]] -> do
      runs <- query "SELECT id,root_identity,native_run_id FROM runs WHERE id IN (SELECT run_id FROM start_intents WHERE reservation_id=?) OR preparation_id IN (SELECT id FROM preparations WHERE reservation_id=?) ORDER BY id" [SQL.SQLText ident, SQL.SQLText ident]
      intents <- query "SELECT count(*) FROM start_intents WHERE reservation_id=?" [SQL.SQLText ident]
      case (runs, intents) of
        ([[SQL.SQLText run, SQL.SQLText recorded, SQL.SQLText native]], _) ->
          either (const (refuseTransaction StoreIntegrity)) (pure . ClaimLaunched request run recorded) (mkRunId native)
        ([], [[SQL.SQLInteger 0]]) -> do
          phases <- query "SELECT phase FROM requests WHERE id=?" [SQL.SQLText request]
          phase <- case phases of
            [[SQL.SQLText value]] -> pure value
            _ -> refuseTransaction StoreIntegrity
          preparations <- query "SELECT state FROM preparations WHERE reservation_id=? ORDER BY id LIMIT 257" [SQL.SQLText ident]
          unless (length preparations <= 256) (refuseTransaction StoreLimit)
          prepared <- forM preparations $ \row -> case row of
            [SQL.SQLText value] -> pure value
            _ -> refuseTransaction StoreIntegrity
          observations <- query "SELECT state FROM admission_observations WHERE reservation_id=?" [SQL.SQLText ident]
          observed <- case observations of
            [] -> pure Nothing
            [[SQL.SQLText value]] -> pure (Just value)
            _ -> refuseTransaction StoreIntegrity
          keys <- query "SELECT kind,resource_key FROM reservation_resources WHERE reservation_id=? ORDER BY kind,resource_key LIMIT 257" [SQL.SQLText ident]
          unless (length keys <= 256) (refuseTransaction StoreLimit)
          resources <- forM keys $ \row -> case row of
            [SQL.SQLText kind, SQL.SQLText key] -> pure [kind, key]
            _ -> refuseTransaction StoreIntegrity
          pure (ClaimUnlaunched request
            [("reservationId", Aeson.toJSON ident), ("requestId", Aeson.toJSON request), ("requestPhase", Aeson.toJSON phase),
             ("preparationStates", Aeson.toJSON prepared), ("admissionObservationState", Aeson.toJSON observed),
             ("resourceKeys", Aeson.toJSON resources)])
        _ -> refuseTransaction StoreIntegrity
    [[SQL.SQLText _, SQL.SQLText _]] -> pure ClaimNotQuarantined
    _ -> refuseTransaction StoreIntegrity

-- The terminal record of the run log of the run store of a run: its position
-- and its exact line bytes. A log without one gives nothing. A run store
-- whose events or effects cannot be read raises an I/O error, because without
-- them no terminal record can be found.
terminalRecord :: PrivateRoot -> Text -> RunId -> IO (Maybe (Position, BS.ByteString))
terminalRecord root recorded native = withRecordedRunRoot root recorded $ \runs ->
  bracket (openPrivateSubroot runs ["runs", T.unpack (runIdText native), "runtime"]) closePrivateRoot $ \runtime -> do
    report <- readFlow FlowLive (privateRootPath runtime)
    case reportStop report of
      Just position -> readFlowLine runtime [runLogName] position >>= \case
        Just bytes -> pure (Just (position, bytes))
        Nothing -> ioError (userError "the terminal record is not a complete line")
      Nothing
        | null (reportProblems report) -> pure Nothing
        | otherwise -> ioError (userError "the run store cannot be read")

-- Whether the inner frontend worker of a run has ended: the exclusive lock of
-- runs/<run>/owner.lock in the recorded run root is free. The probe takes the
-- lock and releases it at once. A lock that another open description holds, an absent
-- lock file, and a lock file that cannot be opened as a private regular file
-- give 'False'. An absent file is no proof, because a worker from before the
-- owner lock never created one.
ownerReleased :: PrivateRoot -> Text -> RunId -> IO Bool
ownerReleased root recorded native = do
  probed <- try @IOException (try @StoreFailure (withRecordedRunRoot root recorded $ \runs ->
    probePrivateLockAt runs ["runs", T.unpack (runIdText native), "owner.lock"]))
  pure $ case probed of
    Right (Right free) -> free
    _ -> False

evidence :: [(Text, Value)] -> CleanupEvidence
evidence facts =
  let bytes = encoded (object [(Key.fromText key, value) | (key, value) <- facts])
      digest = sha256 bytes
  in CleanupEvidence bytes digest ("cleanup_" <> T.take 32 digest)

sha256 :: BS.ByteString -> Text
sha256 bytes = T.pack (show (hash bytes :: Digest SHA256))

-- The answer of a read. A read records nothing, so no receipt follows.
answered :: Text -> IO Value -> IO BS.ByteString
answered operation action = either id (adminSuccess operation) <$> attempt operation action

-- The refusals of 'Agentic.Manager.Credentials.administerCredentials', or the
-- result of the action. 'StateConflict' names an identity that is not a
-- quarantined claim.
attempt :: Text -> IO a -> IO (Either BS.ByteString a)
attempt operation action = do
  result <- try @IOException (try @AdminFailure (try @StoreFailure action))
  pure $ case result of
    Left _ -> Left (adminError (Just operation) StorageUnavailable)
    Right (Left failure) -> Left (adminError (Just operation) failure)
    Right (Right (Left StoreLimit)) -> Left (adminError (Just operation) SizeLimit)
    Right (Right (Left _)) -> Left (adminError (Just operation) StorageUnavailable)
    Right (Right (Right value)) -> Right value
