{-# LANGUAGE OverloadedStrings #-}

-- | Complete sequence-zero envelope prefixes whose JSON fits 'maxArtifactBytes'.
-- Restoration preserves Envelope equality, not original JSON spelling. This
-- representation does not cover arbitrary edited snapshots or every long run.
module Agentic.Runtime.Snapshot.Checkpoint
  ( SnapshotCheckpoint,
    checkpointSnapshot,
    checkpointEnvelopes,
    captureSnapshotCheckpoint,
    appendSnapshotCheckpoint,
    encodeSnapshotCheckpoint,
    decodeSnapshotCheckpoint,
    snapshotCheckpointValue,
  )
where

import Agentic.Runtime.Protocol
import Agentic.Runtime.Snapshot
import Control.Monad (foldM, unless, when)
import Data.Aeson (Value (..), eitherDecodeStrict', encode, object, toJSON, withObject, (.:), (.=))
import qualified Data.Aeson.KeyMap as KeyMap
import Data.Aeson.Types (Pair, parseEither)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.Foldable (toList)
import Data.List (sort)
import Data.Sequence (Seq, (|>))
import qualified Data.Sequence as Seq
import Data.Text (Text)
import qualified Data.Text as T

-- | A validated prefix, its shared fold, and encoded array contents byte count.
-- The snapshot is derived only. Public accessors are not record update labels.
data SnapshotCheckpoint = SnapshotCheckpoint !RunSnapshot !(Seq Envelope) !Int
  deriving (Eq, Show)

checkpointSnapshot :: SnapshotCheckpoint -> RunSnapshot
checkpointSnapshot (SnapshotCheckpoint snapshot _ _) = snapshot

checkpointEnvelopes :: SnapshotCheckpoint -> [Envelope]
checkpointEnvelopes (SnapshotCheckpoint _ envelopes _) = toList envelopes

captureSnapshotCheckpoint :: RunId -> [Envelope] -> Either Text SnapshotCheckpoint
captureSnapshotCheckpoint run envelopes = do
  _ <- mkRunId (runIdText run)
  appendSnapshotCheckpoint (SnapshotCheckpoint (initialRunSnapshot run) Seq.empty 0) envelopes

-- | Replay a contiguous suffix through the same validator and lifecycle fold.
-- No prefix is dropped. Overflow returns no checkpoint and does not force the
-- remaining source list.
appendSnapshotCheckpoint :: SnapshotCheckpoint -> [Envelope] -> Either Text SnapshotCheckpoint
appendSnapshotCheckpoint = foldM appendEnvelope

appendEnvelope :: SnapshotCheckpoint -> Envelope -> Either Text SnapshotCheckpoint
appendEnvelope (SnapshotCheckpoint snapshot envelopes payloadBytes) envelope = do
  -- The native encoder makes a strict ByteString before checking its limit.
  when (BL.length (BL.take (fromIntegral maxFrameBytes + 1) (encode envelope)) > fromIntegral maxFrameBytes) $
    Left "snapshot checkpoint envelope exceeds 1048576 bytes"
  bytes <- encodeEnvelopeFor (envelopeVersion envelope) envelope
  decoded <- decodeEnvelopeFor [protocolVersion, latestProtocolVersion] bytes
  unless (decoded == envelope) $ Left "checkpoint envelope changed during protocol validation"
  let nextPayloadBytes = payloadBytes + BS.length bytes + if Seq.null envelopes then 0 else 1
      boundary = snapshot {snapshotLastEnvelope = Just envelope}
  checkSize (toInteger nextPayloadBytes + metadataBytes boundary)
  next <- either (Left . snapshotErrorMessage) Right (stepRunSnapshot snapshot envelope)
  pure (SnapshotCheckpoint next (envelopes |> envelope) nextPayloadBytes)

encodeSnapshotCheckpoint :: SnapshotCheckpoint -> Either Text ByteString
encodeSnapshotCheckpoint checkpoint@(SnapshotCheckpoint snapshot _ payloadBytes) = do
  checkSize (toInteger payloadBytes + metadataBytes snapshot)
  let bytes = encode (snapshotCheckpointValue checkpoint)
  checkSize (toInteger (BL.length (BL.take (fromInteger maxArtifactBytes + 1) bytes)))
  pure (BL.toStrict bytes)

-- | A helper reply may embed this complete representation, not a compact view.
snapshotCheckpointValue :: SnapshotCheckpoint -> Value
snapshotCheckpointValue checkpoint =
  object (metadata (checkpointSnapshot checkpoint) <> ["envelopes" .= checkpointEnvelopes checkpoint])

decodeSnapshotCheckpoint :: ByteString -> Either Text SnapshotCheckpoint
decodeSnapshotCheckpoint bytes = do
  checkSize (toInteger (BS.length bytes))
  value <- either (Left . T.pack) Right (eitherDecodeStrict' bytes)
  (run, version, boundary, envelopes) <- either (Left . T.pack) Right $
    parseEither (withObject "snapshot checkpoint" $ \o -> do
      unless (sort (KeyMap.keys o) == sort ["checkpointVersion", "representation", "runId", "protocolVersion", "lastSequence", "envelopes"]) $
        fail "snapshot checkpoint fields are missing or unknown"
      checkpointVersion <- o .: "checkpointVersion"
      unless (checkpointVersion == Number 1) $ fail "unsupported snapshot checkpoint version"
      representation <- o .: "representation"
      unless (representation == String "runtime-envelope-prefix") $ fail "unsupported snapshot checkpoint representation"
      runText <- o .: "runId"
      run <- either (fail . T.unpack) pure (mkRunId runText)
      (,,,) run <$> o .: "protocolVersion" <*> o .: "lastSequence" <*> o .: "envelopes") value
  empty <- captureSnapshotCheckpoint run []
  checkpoint <- foldM appendValue empty (envelopes :: [Value])
  let lastEnvelope = snapshotLastEnvelope (checkpointSnapshot checkpoint)
  unless (version == toJSON (envelopeVersion <$> lastEnvelope)) $
    Left "snapshot checkpoint protocol version does not match its prefix"
  unless (boundary == toJSON (sequenceText <$> lastEnvelope)) $
    Left "snapshot checkpoint last sequence does not match its prefix"
  pure checkpoint
  where
    appendValue checkpoint value = do
      let encoded = encode value
          bounded = BL.take (fromIntegral maxFrameBytes + 1) encoded
      when (BL.length bounded > fromIntegral maxFrameBytes) $
        Left "snapshot checkpoint envelope exceeds 1048576 bytes"
      envelope <- decodeEnvelopeFor [protocolVersion, latestProtocolVersion] (BL.toStrict bounded)
      appendEnvelope checkpoint envelope

metadata :: RunSnapshot -> [Pair]
metadata snapshot =
  [ "checkpointVersion" .= (1 :: Int),
    "representation" .= ("runtime-envelope-prefix" :: Text),
    "runId" .= runIdText (snapshotRunId snapshot),
    "protocolVersion" .= fmap envelopeVersion lastEnvelope,
    "lastSequence" .= fmap sequenceText lastEnvelope
  ]
  where
    lastEnvelope = snapshotLastEnvelope snapshot

-- The empty array includes both brackets. Payload bytes include every comma.
metadataBytes :: RunSnapshot -> Integer
metadataBytes snapshot =
  toInteger (BL.length (encode (object (metadata snapshot <> ["envelopes" .= ([] :: [Value])]))))

sequenceText :: Envelope -> Text
sequenceText = T.pack . show . sequenceNumber . envelopeSequence

checkSize :: Integer -> Either Text ()
checkSize bytes =
  when (bytes > maxArtifactBytes) $ Left "snapshot checkpoint exceeds 67108864 bytes"
