{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Agentic.Runtime.Store
  ( LineageOperation (..),
    RunManifest (..),
    AnswerRecord (..),
    EffectPhase (..),
    EffectRecord (..),
    Checkpoint (..),
    RunStore,
    StoreError (..),
    StoreHealth (..),
    createRunStore,
    createRunStoreSeeded,
    closeRunStore,
    withRunStore,
    withRunStoreSeeded,
    storeEventHandle,
    appendStoredEvent,
    readEventLog,
    readManifest,
    writeSnapshot,
    lookupStoredAnswer,
    storeReusableAnswer,
    appendEffectRecord,
    writeCheckpoint,
    readAnswerRecords,
    readEffectRecords,
    readCheckpoint,
  )
where

import Agentic.Runtime.Protocol
  ( Envelope,
    RunId (..),
    OccurrenceId (..),
    SequenceDecision (SequenceNext),
    checkSequence,
    decodeEnvelope,
    encodeEnvelope,
    protocolVersion,
    storeVersion,
  )
import Control.Concurrent.MVar (MVar, modifyMVar, modifyMVar_, newMVar)
import Control.Exception (Exception, bracket, throwIO)
import Control.Monad (foldM, unless)
import Data.List (find)
import Data.Maybe (fromMaybe)
import Data.Aeson
  ( FromJSON (parseJSON),
    ToJSON (toJSON),
    Value,
    eitherDecodeStrict',
    encode,
    object,
    withObject,
    (.:),
    (.:?),
    (.=),
  )
import Data.Aeson.Types (Parser)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Read as TR
import Data.Word (Word64)
import System.Directory
  ( createDirectory,
    createDirectoryIfMissing,
    doesFileExist,
    renameFile,
  )
import System.FilePath ((</>), takeDirectory)
import System.IO (Handle, IOMode (AppendMode), hClose, hFlush, openBinaryFile)
import System.Posix.Files (ownerModes, setFileMode)
import System.Posix.IO
  ( OpenFileFlags (creat, exclusive),
    OpenMode (WriteOnly),
    defaultFileFlags,
    fdToHandle,
    openFd,
  )
import System.Posix.Types (FileMode)

semanticStoreVersion :: Int
semanticStoreVersion = 1

privateDirectoryMode, privateFileMode :: FileMode
privateDirectoryMode = ownerModes
privateFileMode = 0o600

data LineageOperation = RootRun | RestartRun | ResumeRun | ForkRun
  deriving (Eq, Show)

data RunManifest = RunManifest
  { manifestRunId :: !RunId,
    manifestWorkflow :: !Text,
    manifestRunnerVersion :: !Text,
    manifestProgram :: !Value,
    manifestTarget :: !Text,
    manifestPolicy :: !Value,
    manifestParent :: !(Maybe RunId),
    manifestLineage :: !LineageOperation,
    manifestOwner :: !(Maybe Text)
  }
  deriving (Eq, Show)

data RunStore = RunStore
  { runStoreDirectory :: !FilePath,
    runStoreEvents :: !Handle,
    runStoreEffects :: !(MVar Handle),
    runStoreAnswers :: !(MVar [AnswerRecord]),
    runStoreCheckpoint :: !(MVar (Maybe Checkpoint)),
    runStorePrevious :: !(MVar (Maybe Envelope))
  }

data AnswerRecord = AnswerRecord
  { answerQuestion :: !Value,
    answerValue :: !Value,
    answerOccurrence :: !OccurrenceId,
    answerReplayable :: !Bool,
    answerReplaced :: !Bool
  }
  deriving (Eq, Show)

data EffectPhase = EffectStarted | EffectCompleted
  deriving (Eq, Show)

data EffectRecord = EffectRecord
  { effectQuestion :: !Value,
    effectAnswer :: !(Maybe Value),
    effectOccurrence :: !OccurrenceId,
    effectPhase :: !EffectPhase
  }
  deriving (Eq, Show)

data Checkpoint = Checkpoint
  { checkpointProgram :: !Value,
    checkpointLastOccurrence :: !(Maybe OccurrenceId),
    checkpointAnswers :: !Int,
    checkpointEffects :: !Int
  }
  deriving (Eq, Show)

data StoreHealth = StoreHealthy
  deriving (Eq, Show)

data StoreError
  = StoreAlreadyExists !FilePath
  | StoreCorrupt !FilePath !Text
  | StoreIncompatible !FilePath !Text
  deriving (Eq, Show)

instance Exception StoreError

createRunStore :: FilePath -> RunManifest -> IO RunStore
createRunStore directory manifest = createRunStoreSeeded directory manifest []

createRunStoreSeeded :: FilePath -> RunManifest -> [AnswerRecord] -> IO RunStore
createRunStoreSeeded directory manifest inheritedAnswers = do
  createDirectoryIfMissing True (takeDirectory directory)
  exists <- doesFileExist (directory </> "manifest.json")
  if exists
    then throwIO (StoreAlreadyExists directory)
    else do
      createDirectory directory
      setFileMode directory privateDirectoryMode
      writeExclusiveJson
        (directory </> "manifest.json")
        (StoredManifest storeVersion protocolVersion manifest)
      writeExclusiveJson (directory </> "answers.json") (StoredAnswers semanticStoreVersion inheritedAnswers)
      effects <- openPrivateAppend (directory </> "effects.ndjson")
      events <- openPrivateAppend (directory </> "events.ndjson")
      effectState <- newMVar effects
      answerState <- newMVar inheritedAnswers
      checkpointState <- newMVar Nothing
      previous <- newMVar Nothing
      pure (RunStore directory events effectState answerState checkpointState previous)

closeRunStore :: RunStore -> IO ()
closeRunStore store = do
  hClose (runStoreEvents store)
  modifyMVar_ (runStoreEffects store) (\handle -> hClose handle >> pure handle)

withRunStore :: FilePath -> RunManifest -> (RunStore -> IO a) -> IO a
withRunStore directory manifest = withRunStoreSeeded directory manifest []

withRunStoreSeeded :: FilePath -> RunManifest -> [AnswerRecord] -> (RunStore -> IO a) -> IO a
withRunStoreSeeded directory manifest inheritedAnswers = bracket (createRunStoreSeeded directory manifest inheritedAnswers) closeRunStore

storeEventHandle :: RunStore -> Handle
storeEventHandle = runStoreEvents

appendStoredEvent :: RunStore -> Envelope -> IO SequenceDecision
appendStoredEvent store envelope =
  modifyMVar (runStorePrevious store) $ \previous -> do
    decision <- either (throwIO . StoreCorrupt (eventPath store)) pure (checkSequence previous envelope)
    case decision of
      SequenceNext -> do
        BS.hPut (runStoreEvents store) (encodeEnvelope envelope)
        BS.hPut (runStoreEvents store) "\n"
        hFlush (runStoreEvents store)
        pure (Just envelope, decision)
  where
    eventPath s = runStoreDirectory s </> "events.ndjson"

readManifest :: FilePath -> IO RunManifest
readManifest directory = do
  let path = directory </> "manifest.json"
  bytes <- BS.readFile path
  case eitherDecodeStrict' bytes of
    Left why -> throwIO (StoreCorrupt path (T.pack why))
    Right manifest
      | manifestStoreVersion manifest /= storeVersion ->
          throwIO (StoreIncompatible path "unsupported store version")
      | manifestProtocolVersion manifest /= protocolVersion ->
          throwIO (StoreIncompatible path "unsupported protocol version")
      | otherwise -> pure (manifestPayload manifest)

readEventLog :: FilePath -> IO ([Envelope], StoreHealth)
readEventLog directory = do
  let path = directory </> "events.ndjson"
  bytes <- BS.readFile path
  let ended = BS.null bytes || BS.last bytes == 10
  unless ended (throwIO (StoreCorrupt path "runtime event log has a torn final record"))
  let complete = filter (not . BS.null) (BS.split 10 bytes)
  envelopes <- traverse (decodeAt path) complete
  accepted <- foldM (accept path) [] envelopes
  pure (reverse accepted, StoreHealthy)
  where
    decodeAt path bytes = either (throwIO . StoreCorrupt path) pure (decodeEnvelope bytes)
    accept path accepted envelope = do
      let previous = case accepted of [] -> Nothing; x : _ -> Just x
      case checkSequence previous envelope of
        Left why -> throwIO (StoreCorrupt path why)
        Right SequenceNext -> pure (envelope : accepted)

writeSnapshot :: RunStore -> Value -> IO ()
writeSnapshot store = writeAtomicJson (runStoreDirectory store </> "snapshot.json")

lookupStoredAnswer :: RunStore -> Value -> IO (Maybe AnswerRecord)
lookupStoredAnswer store question =
  modifyMVar (runStoreAnswers store) $ \answers ->
    pure (answers, find (\answer -> answerReplayable answer && answerQuestion answer == question) answers)

storeReusableAnswer :: RunStore -> AnswerRecord -> IO ()
storeReusableAnswer store answer =
  modifyMVar_ (runStoreAnswers store) $ \answers -> do
    let next = answer : filter ((/= answerQuestion answer) . answerQuestion) answers
    writeAtomicJson (runStoreDirectory store </> "answers.json") (StoredAnswers semanticStoreVersion next)
    pure next

appendEffectRecord :: RunStore -> EffectRecord -> IO ()
appendEffectRecord store effect =
  modifyMVar_ (runStoreEffects store) $ \handle -> do
    BL.hPut handle (encode effect <> "\n")
    hFlush handle
    pure handle

instance ToJSON AnswerRecord where
  toJSON answer =
    object
      [ "question" .= answerQuestion answer,
        "answer" .= answerValue answer,
        "occurrenceId" .= occurrenceText (answerOccurrence answer),
        "replayable" .= answerReplayable answer,
        "replaced" .= answerReplaced answer
      ]

instance FromJSON AnswerRecord where
  parseJSON = withObject "stored answer" $ \o ->
    AnswerRecord
      <$> o .: "question"
      <*> o .: "answer"
      <*> (o .: "occurrenceId" >>= parseOccurrence)
      <*> o .: "replayable"
      <*> (fromMaybe False <$> o .:? "replaced")

instance ToJSON EffectRecord where
  toJSON effect =
    object
      [ "question" .= effectQuestion effect,
        "answer" .= effectAnswer effect,
        "occurrenceId" .= occurrenceText (effectOccurrence effect),
        "phase" .= effectPhase effect
      ]

instance FromJSON EffectRecord where
  parseJSON = withObject "effect record" $ \o ->
    EffectRecord <$> o .: "question" <*> o .:? "answer" <*> (o .: "occurrenceId" >>= parseOccurrence) <*> o .: "phase"

instance ToJSON EffectPhase where
  toJSON EffectStarted = toJSON ("started" :: Text)
  toJSON EffectCompleted = toJSON ("completed" :: Text)

instance FromJSON EffectPhase where
  parseJSON value = do
    phase <- parseJSON value
    case phase :: Text of
      "started" -> pure EffectStarted
      "completed" -> pure EffectCompleted
      _ -> fail "unknown effect journal phase"

instance ToJSON Checkpoint where
  toJSON checkpoint =
    object
      [ "program" .= checkpointProgram checkpoint,
        "lastOccurrenceId" .= fmap occurrenceText (checkpointLastOccurrence checkpoint),
        "answerCount" .= checkpointAnswers checkpoint,
        "effectCount" .= checkpointEffects checkpoint
      ]

instance FromJSON Checkpoint where
  parseJSON = withObject "runtime checkpoint" $ \o ->
    Checkpoint
      <$> o .: "program"
      <*> (traverse parseOccurrence =<< o .:? "lastOccurrenceId")
      <*> o .: "answerCount"
      <*> o .: "effectCount"

instance ToJSON StoredAnswers where
  toJSON stored = object ["semanticStoreVersion" .= storedAnswersVersion stored, "answers" .= storedAnswersRecords stored]

instance FromJSON StoredAnswers where
  parseJSON = withObject "stored answers" $ \o -> StoredAnswers <$> o .: "semanticStoreVersion" <*> o .: "answers"

instance ToJSON StoredCheckpoint where
  toJSON stored = object ["semanticStoreVersion" .= storedCheckpointVersion stored, "checkpoint" .= storedCheckpointPayload stored]

instance FromJSON StoredCheckpoint where
  parseJSON = withObject "stored checkpoint" $ \o -> StoredCheckpoint <$> o .: "semanticStoreVersion" <*> o .: "checkpoint"

occurrenceText :: OccurrenceId -> Text
occurrenceText = T.pack . show . occurrenceNumber

parseOccurrence :: Text -> Parser OccurrenceId
parseOccurrence text = case (TR.decimal text :: Either String (Integer, Text)) of
  Right (value, rest)
    | T.null rest, value <= toInteger (maxBound :: Word64) -> pure (OccurrenceId (fromInteger value))
  _ -> fail "occurrenceId is not an unsigned Word64 decimal string"

writeCheckpoint :: RunStore -> Checkpoint -> IO ()
writeCheckpoint store checkpoint =
  modifyMVar_ (runStoreCheckpoint store) $ \previous -> do
    merged <- case previous of
      Nothing -> pure checkpoint
      Just prior
        | checkpointProgram prior /= checkpointProgram checkpoint ->
            throwIO (StoreCorrupt (runStoreDirectory store </> "checkpoint.json") "checkpoint program changed within one run")
        | otherwise ->
            pure
              Checkpoint
                { checkpointProgram = checkpointProgram checkpoint,
                  checkpointLastOccurrence = laterOccurrence (checkpointLastOccurrence prior) (checkpointLastOccurrence checkpoint),
                  checkpointAnswers = max (checkpointAnswers prior) (checkpointAnswers checkpoint),
                  checkpointEffects = max (checkpointEffects prior) (checkpointEffects checkpoint)
                }
    writeAtomicJson (runStoreDirectory store </> "checkpoint.json") (StoredCheckpoint semanticStoreVersion merged)
    pure (Just merged)

laterOccurrence :: Maybe OccurrenceId -> Maybe OccurrenceId -> Maybe OccurrenceId
laterOccurrence Nothing right = right
laterOccurrence left Nothing = left
laterOccurrence left@(Just a) right@(Just b)
  | occurrenceNumber a >= occurrenceNumber b = left
  | otherwise = right

readAnswerRecords :: FilePath -> IO [AnswerRecord]
readAnswerRecords directory = do
  let path = directory </> "answers.json"
  bytes <- BS.readFile path
  case eitherDecodeStrict' bytes of
    Left why -> throwIO (StoreCorrupt path (T.pack why))
    Right stored
      | storedAnswersVersion stored /= semanticStoreVersion ->
          throwIO (StoreIncompatible path "unsupported answer store version")
      | otherwise -> pure (storedAnswersRecords stored)

readEffectRecords :: FilePath -> IO [EffectRecord]
readEffectRecords directory = do
  let path = directory </> "effects.ndjson"
  bytes <- BS.readFile path
  if not (BS.null bytes) && BS.last bytes /= 10
    then throwIO (StoreCorrupt path "effect journal has a torn final record")
    else traverse (decodeEffect path) (filter (not . BS.null) (BS.split 10 bytes))
  where
    decodeEffect path bytes = case eitherDecodeStrict' bytes of
      Left why -> throwIO (StoreCorrupt path (T.pack why))
      Right effect -> pure effect

readCheckpoint :: FilePath -> IO (Maybe Checkpoint)
readCheckpoint directory = do
  let path = directory </> "checkpoint.json"
  exists <- doesFileExist path
  if not exists
    then pure Nothing
    else do
      bytes <- BS.readFile path
      case eitherDecodeStrict' bytes of
        Left why -> throwIO (StoreCorrupt path (T.pack why))
        Right stored
          | storedCheckpointVersion stored /= semanticStoreVersion ->
              throwIO (StoreIncompatible path "unsupported checkpoint version")
          | otherwise -> pure (Just (storedCheckpointPayload stored))

writeAtomicJson :: ToJSON a => FilePath -> a -> IO ()
writeAtomicJson final value = do
  let temp = final <> ".tmp"
  BL.writeFile temp (encode value)
  setFileMode temp privateFileMode
  renameFile temp final

openPrivateAppend :: FilePath -> IO Handle
openPrivateAppend path = do
  handle <- openBinaryFile path AppendMode
  setFileMode path privateFileMode
  pure handle

writeExclusiveJson :: ToJSON a => FilePath -> a -> IO ()
writeExclusiveJson path value = do
  fd <- openFd path WriteOnly defaultFileFlags {exclusive = True, creat = Just privateFileMode}
  handle <- fdToHandle fd
  BL.hPut handle (encode value)
  hFlush handle
  hClose handle

data StoredAnswers = StoredAnswers
  { storedAnswersVersion :: !Int,
    storedAnswersRecords :: ![AnswerRecord]
  }

data StoredCheckpoint = StoredCheckpoint
  { storedCheckpointVersion :: !Int,
    storedCheckpointPayload :: !Checkpoint
  }

-- Private wire wrapper keeps version fields next to the manifest payload.
data StoredManifest = StoredManifest
  { manifestStoreVersion :: !Int,
    manifestProtocolVersion :: !Int,
    manifestPayload :: !RunManifest
  }


instance ToJSON StoredManifest where
  toJSON stored =
    object
      [ "storeVersion" .= manifestStoreVersion stored,
        "protocolVersion" .= manifestProtocolVersion stored,
        "run" .= manifestPayload stored
      ]

instance FromJSON StoredManifest where
  parseJSON = withObject "stored run manifest" $ \o ->
    StoredManifest <$> o .: "storeVersion" <*> o .: "protocolVersion" <*> o .: "run"

instance ToJSON LineageOperation where
  toJSON = toJSON . lineageText

instance FromJSON LineageOperation where
  parseJSON value = do
    text <- parseJSON value
    maybe (fail ("unknown lineage operation " <> T.unpack text)) pure (lineageOfText text)

instance ToJSON RunManifest where
  toJSON manifest =
    object
      [ "runId" .= runIdText (manifestRunId manifest),
        "workflow" .= manifestWorkflow manifest,
        "runnerVersion" .= manifestRunnerVersion manifest,
        "program" .= manifestProgram manifest,
        "target" .= manifestTarget manifest,
        "policy" .= manifestPolicy manifest,
        "parentRunId" .= fmap runIdText (manifestParent manifest),
        "lineage" .= manifestLineage manifest,
        "owner" .= manifestOwner manifest
      ]

instance FromJSON RunManifest where
  parseJSON = withObject "run manifest" $ \o ->
    RunManifest
      <$> (RunId <$> o .: "runId")
      <*> o .: "workflow"
      <*> o .: "runnerVersion"
      <*> o .: "program"
      <*> o .: "target"
      <*> o .: "policy"
      <*> (fmap RunId <$> o .:? "parentRunId")
      <*> o .: "lineage"
      <*> o .:? "owner"

lineageText :: LineageOperation -> Text
lineageText RootRun = "root"
lineageText RestartRun = "restart"
lineageText ResumeRun = "resume"
lineageText ForkRun = "fork"

lineageOfText :: Text -> Maybe LineageOperation
lineageOfText "root" = Just RootRun
lineageOfText "restart" = Just RestartRun
lineageOfText "resume" = Just ResumeRun
lineageOfText "fork" = Just ForkRun
lineageOfText _ = Nothing
