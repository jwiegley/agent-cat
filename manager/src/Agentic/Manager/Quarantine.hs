{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeApplications #-}

-- | Read-only Store status, quarantine discovery and cleanup evidence for
-- local administration. No operation changes a Store row, appends to the
-- manager log, reads or signals a stored process identity, or adopts a
-- worker.
module Agentic.Manager.Quarantine
  ( StoreState (..), reportStatus, reportStoreCheck, unavailableStoreCheck,
    QuarantineState (..), CleanupEvidence (..), inspectQuarantine, checkQuarantine, cleanupEvidenceLifetime
  ) where

import Agentic.Manager.Protocol.Command (encoded, validId)
import Agentic.Manager.Protocol.LocalAdmin (AdminFailure (..), adminError, adminSuccess)
import Agentic.Manager.Store
import Agentic.Runtime
  ( FlowLiveness (FlowLive), FlowReport (..), Position (..), PrivateRoot, RunId, closePrivateRoot, mkRunId,
    openPrivateSubroot, privateRootPath, readFlow, readFlowLine, runIdText, runLogName )
import Control.DeepSeq (NFData (rnf))
import Control.Exception (IOException, bracket, throwIO, try)
import Control.Monad (forM, unless)
import Crypto.Hash (Digest, SHA256, hash)
import Data.Aeson (Value (Null), object, (.=))
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Key as Key
import qualified Data.ByteString as BS
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
  = -- | Cleanup evidence holds: the reservation never launched a run, or the
    -- run store of its run holds the terminal record of the runtime.
    QuarantineClean
  | -- | The reservation launched a run, and its run store holds no terminal
    -- record.
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
  | ClaimUnlaunched ![(Text, Value)]
  | ClaimLaunched !Text !Text !RunId

instance NFData Claim where
  rnf claim = case claim of
    ClaimUnlaunched facts -> rnf facts
    ClaimLaunched run recorded native -> rnf (run, recorded, runIdText native)
    _ -> ()

-- | Inspect one quarantine identity with the current process generation. An
-- unknown identity and a reservation that is not quarantined refuse with
-- 'StateConflict'. The Store file slot and one read transaction are taken in
-- the lock order file slot, configuration, database. A launched reservation
-- reads the run log of its run with the runtime readers: the first event
-- record whose event ends the run is the terminal record.
inspectQuarantine :: CoordinationStore -> Text -> IO (QuarantineState, Maybe CleanupEvidence)
inspectQuarantine store ident = withStoreFiles store $ \root -> do
  generation <- storeProcessGeneration <$> storeIdentity store
  claim <- runRead store (readClaim ident)
  case claim of
    ClaimAbsent -> throwIO StateConflict
    ClaimNotQuarantined -> throwIO StateConflict
    ClaimRestored -> pure (QuarantineUnverifiable, Nothing)
    ClaimUnlaunched facts ->
      pure (QuarantineClean, Just (evidence (("evidence", "no-launch") : ("processGeneration", toValue generation) : facts)))
    ClaimLaunched run recorded native -> do
      found <- try @IOException (try @StoreFailure (terminalRecord root recorded native))
      pure $ case found of
        Right (Right (Just (Position position, bytes))) ->
          (QuarantineClean, Just (evidence
            [("evidence", "terminal-record"), ("reservationId", toValue ident), ("runId", toValue run),
             ("position", toValue position), ("recordSha256", toValue (sha256 bytes)),
             ("processGeneration", toValue generation)]))
        Right (Right Nothing) -> (QuarantineCleanupRequired, Nothing)
        _ -> (QuarantineUnverifiable, Nothing)
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
          either (const (refuseTransaction StoreIntegrity)) (pure . ClaimLaunched run recorded) (mkRunId native)
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
          pure (ClaimUnlaunched
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

evidence :: [(Text, Value)] -> CleanupEvidence
evidence facts =
  let bytes = encoded (object [(Key.fromText key, value) | (key, value) <- facts])
      digest = sha256 bytes
  in CleanupEvidence bytes digest ("cleanup_" <> T.take 32 digest)

sha256 :: BS.ByteString -> Text
sha256 bytes = T.pack (show (hash bytes :: Digest SHA256))

-- The refusals of 'Agentic.Manager.Credentials.administerCredentials'. A read
-- records nothing, so no receipt follows. 'StateConflict' names an identity
-- that is not a quarantined claim.
answered :: Text -> IO Value -> IO BS.ByteString
answered operation action = do
  result <- try @IOException (try @AdminFailure (try @StoreFailure action))
  pure $ case result of
    Left _ -> adminError (Just operation) StorageUnavailable
    Right (Left failure) -> adminError (Just operation) failure
    Right (Right (Left StoreLimit)) -> adminError (Just operation) SizeLimit
    Right (Right (Left _)) -> adminError (Just operation) StorageUnavailable
    Right (Right (Right value)) -> adminSuccess operation value
