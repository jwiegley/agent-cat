{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

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
    createRunStoreVersioned,
    createRunStoreSeededVersioned,
    closeRunStore,
    withRunStore,
    withRunStoreSeeded,
    withRunStoreVersioned,
    withRunStoreSeededVersioned,
    storeEventHandle,
    appendStoredEvent,
    readEventLog,
    readRunStore,
    readRunStoreAt,
    readManifest,
    writeSnapshot,
    lookupStoredAnswer,
    storeReusableAnswer,
    appendEffectRecord,
    writeCheckpoint,
    readAnswerRecords,
    readEffectRecords,
    readCheckpoint,
    writeResultArtifact,
    readResultArtifact,
    readResultArtifactAt,
    writeQuestionArtifact,
    readQuestionArtifact,
    readQuestionArtifactByCodeName,
    readQuestionArtifactByCodeNameAt,
  )
where

import Agentic.Runtime.Protocol
  ( Envelope (..),
    PersonAnswering,
    QuestionRef (..),
    ResultRef (..),
    RunId (..),
    OccurrenceId (..),
    SequenceDecision (SequenceNext),
    checkSequence,
    decodeEnvelopeFor,
    encodeEnvelopeFor,
    latestProtocolVersion,
    latestStoreVersion,
    maxArtifactBytes,
    protocolVersion,
    storeVersion,
  )
import Agentic.Runtime.PrivateFile (readConfinedFileAt, withConfinedDirectory)
import qualified Agentic.Runtime.PrivateRoot as Private
import Control.Concurrent.MVar (MVar, modifyMVar, modifyMVar_, newMVar)
import Control.Exception (Exception, IOException, bracket, bracketOnError, displayException, finally, throwIO, try)
import Crypto.Hash (Context, Digest, SHA256, hash, hashFinalize, hashInit, hashUpdate)
import Control.Monad (foldM, unless, when)
import Data.List (find, sort)
import Data.Maybe (fromMaybe)
import Data.Aeson
  ( FromJSON (parseJSON),
    Object,
    ToJSON (toJSON),
    Value (..),
    eitherDecodeStrict',
    encode,
    object,
    withObject,
    (.:),
    (.:?),
    (.=),
  )
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import Data.Aeson.Types (Parser)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Read as TR
import Data.Word (Word64)
import System.Directory (createDirectoryIfMissing, doesFileExist, makeAbsolute)
import System.FilePath ((</>), splitDirectories, takeDirectory)
import System.IO (Handle, hClose, hFlush)
import System.IO.Error (isAlreadyExistsError, isDoesNotExistError)
import qualified System.Posix.Directory as PosixDirectory
import System.Posix.Types (Fd)

semanticStoreVersion :: Int
semanticStoreVersion = 1


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
    manifestOwner :: !(Maybe Text),
    manifestPersonAnswering :: !(Maybe PersonAnswering)
  }
  deriving (Eq, Show)

data RunStore = RunStore
  { runStoreDirectory :: !FilePath,
    runStoreRoot :: !Private.PrivateRoot,
    runStoreFormatVersion :: !Int,
    runStoreProtocolVersion :: !Int,
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
createRunStore = createRunStoreVersioned storeVersion protocolVersion

createRunStoreSeeded :: FilePath -> RunManifest -> [AnswerRecord] -> IO RunStore
createRunStoreSeeded = createRunStoreSeededVersioned storeVersion protocolVersion

createRunStoreVersioned :: Int -> Int -> FilePath -> RunManifest -> IO RunStore
createRunStoreVersioned storeFormat protocol directory manifest =
  createRunStoreSeededVersioned storeFormat protocol directory manifest []

createRunStoreSeededVersioned :: Int -> Int -> FilePath -> RunManifest -> [AnswerRecord] -> IO RunStore
createRunStoreSeededVersioned storeFormat protocol directory manifest inheritedAnswers = do
  validateVersionPair (directory </> "manifest.json") storeFormat protocol
  bracketOnError (createStoreRoot directory) Private.closePrivateRoot $ \root -> do
    writeExclusiveJson root ["program.json"] (manifestProgram manifest)
    writeExclusiveJson root ["manifest.json"]
      (StoredManifest storeFormat protocol (manifest {manifestProgram = privateProgramReference}))
    writeExclusiveJson root ["answers.json"] (StoredAnswers semanticStoreVersion inheritedAnswers)
    bracketOnError (Private.openPrivateFileAt root ["effects.ndjson"]) hClose $ \effects ->
      bracketOnError (Private.openPrivateFileAt root ["events.ndjson"]) hClose $ \events -> do
        effectState <- newMVar effects
        answerState <- newMVar inheritedAnswers
        checkpointState <- newMVar Nothing
        previous <- newMVar Nothing
        pure (RunStore directory root storeFormat protocol events effectState answerState checkpointState previous)

createStoreRoot :: FilePath -> IO Private.PrivateRoot
createStoreRoot directory = Private.withStateAnchor $ \anchor -> case anchor of
  Just root -> do
    components <- Private.privatePathComponents root directory
    Private.createPrivateDirectoryAt root components
    Private.openPrivateSubroot root components
  Nothing -> do
    createDirectoryIfMissing True (takeDirectory directory)
    exists <- doesFileExist (directory </> "manifest.json")
    when exists (throwIO (StoreAlreadyExists directory))
    PosixDirectory.createDirectory directory 0o700
    makeAbsolute directory >>= Private.openPrivateRoot "run store"

closeRunStore :: RunStore -> IO ()
closeRunStore store =
  hClose (runStoreEvents store)
    `finally` modifyMVar_ (runStoreEffects store) (\handle -> hClose handle >> pure handle)
    `finally` Private.closePrivateRoot (runStoreRoot store)

withRunStore :: FilePath -> RunManifest -> (RunStore -> IO a) -> IO a
withRunStore = withRunStoreVersioned storeVersion protocolVersion

withRunStoreSeeded :: FilePath -> RunManifest -> [AnswerRecord] -> (RunStore -> IO a) -> IO a
withRunStoreSeeded = withRunStoreSeededVersioned storeVersion protocolVersion

withRunStoreVersioned :: Int -> Int -> FilePath -> RunManifest -> (RunStore -> IO a) -> IO a
withRunStoreVersioned storeFormat protocol directory manifest =
  withRunStoreSeededVersioned storeFormat protocol directory manifest []

withRunStoreSeededVersioned :: Int -> Int -> FilePath -> RunManifest -> [AnswerRecord] -> (RunStore -> IO a) -> IO a
withRunStoreSeededVersioned storeFormat protocol directory manifest inheritedAnswers =
  bracket
    (createRunStoreSeededVersioned storeFormat protocol directory manifest inheritedAnswers)
    closeRunStore

storeEventHandle :: RunStore -> Handle
storeEventHandle = runStoreEvents

appendStoredEvent :: RunStore -> Envelope -> IO SequenceDecision
appendStoredEvent store envelope =
  modifyMVar (runStorePrevious store) $ \previous -> do
    decision <- either (throwIO . StoreCorrupt (eventPath store)) pure (checkSequence previous envelope)
    case decision of
      SequenceNext -> do
        bytes <-
          either (throwIO . StoreIncompatible (eventPath store)) pure $
            encodeEnvelopeFor (runStoreProtocolVersion store) envelope
        BS.hPut (runStoreEvents store) bytes
        BS.hPut (runStoreEvents store) "\n"
        hFlush (runStoreEvents store)
        pure (Just envelope, decision)
  where
    eventPath s = runStoreDirectory s </> "events.ndjson"

withStoreDirectory :: FilePath -> (Fd -> IO a) -> IO a
withStoreDirectory directory action = Private.withStateAnchor $ \anchor -> case anchor of
  Nothing -> withConfinedDirectory directory [] action
  Just root -> do
    components <- Private.privatePathComponents root directory
    Private.withPrivateDirectoryAt root components action

readStoreFile :: FilePath -> [FilePath] -> Integer -> IO BS.ByteString
readStoreFile directory components limit =
  withStoreDirectory directory (\descriptor -> fst <$> readConfinedFileAt descriptor components limit)

readManifest :: FilePath -> IO RunManifest
readManifest directory =
  withStoreDirectory directory $ \descriptor -> do
    stored <- readStoredManifestAt directory descriptor
    readManifestAt directory descriptor stored

readEventLog :: FilePath -> IO ([Envelope], StoreHealth)
readEventLog directory =
  withStoreDirectory directory $ \descriptor -> do
    stored <- readStoredManifestAt directory descriptor
    readEventLogAt directory descriptor stored

readRunStore :: FilePath -> IO (RunManifest, [Envelope], StoreHealth)
readRunStore directory =
  withStoreDirectory directory (readRunStoreAt directory)

readRunStoreAt :: FilePath -> Fd -> IO (RunManifest, [Envelope], StoreHealth)
readRunStoreAt directory descriptor = do
  stored <- readStoredManifestAt directory descriptor
  manifest <- readManifestAt directory descriptor stored
  (events, health) <- readEventLogAt directory descriptor stored
  pure (manifest, events, health)

readStoredManifestAt :: FilePath -> Fd -> IO StoredManifest
readStoredManifestAt directory descriptor = do
  let path = directory </> "manifest.json"
  (bytes, _) <- readConfinedFileAt descriptor ["manifest.json"] (4 * 1024 * 1024)
  stored <- case eitherDecodeStrict' bytes of
    Left why -> throwIO (StoreCorrupt path (T.pack why))
    Right value -> pure value
  validateVersionPair path (manifestStoreVersion stored) (manifestProtocolVersion stored)
  pure stored

readManifestAt :: FilePath -> Fd -> StoredManifest -> IO RunManifest
readManifestAt directory descriptor stored = do
  let manifest = manifestPayload stored
  if manifestProgram manifest /= privateProgramReference
    then pure manifest
    else do
      let path = directory </> "program.json"
      (bytes, _) <- readConfinedFileAt descriptor ["program.json"] maxArtifactBytes
      program <- case eitherDecodeStrict' bytes of
        Left why -> throwIO (StoreCorrupt path (T.pack why))
        Right value -> pure value
      pure manifest {manifestProgram = program}

readEventLogAt :: FilePath -> Fd -> StoredManifest -> IO ([Envelope], StoreHealth)
readEventLogAt directory descriptor stored = do
  let path = directory </> "events.ndjson"
  (bytes, _) <- readConfinedFileAt descriptor ["events.ndjson"] maxEventLogBytes
  let ended = BS.null bytes || BS.last bytes == 10
  unless ended (throwIO (StoreCorrupt path "runtime event log has a torn final record"))
  let complete = filter (not . BS.null) (BS.split 10 bytes)
  envelopes <- traverse (decodeAt path (manifestProtocolVersion stored)) complete
  accepted <- foldM (accept path) [] envelopes
  pure (reverse accepted, StoreHealthy)
  where
    decodeAt path protocol bytes = either (throwIO . StoreCorrupt path) pure (decodeEnvelopeFor [protocol] bytes)
    accept path accepted envelope = do
      let previous = case accepted of [] -> Nothing; x : _ -> Just x
      case checkSequence previous envelope of
        Left why -> throwIO (StoreCorrupt path why)
        Right SequenceNext -> pure (envelope : accepted)

maxEventLogBytes :: Integer
maxEventLogBytes = 512 * 1024 * 1024

validateVersionPair :: FilePath -> Int -> Int -> IO ()
validateVersionPair path storeFormat protocol =
  unless
    ( (storeFormat, protocol)
        `elem` [ (storeVersion, protocolVersion),
                 (latestStoreVersion, latestProtocolVersion)
               ]
    )
    (throwIO (StoreIncompatible path "unsupported store/protocol version pair"))

privateProgramReference :: Value
privateProgramReference = object ["privateProgram" .= ("program.json" :: Text)]

writeSnapshot :: RunStore -> Value -> IO ()
writeSnapshot store = writeAtomicJson store "snapshot.json"

lookupStoredAnswer :: RunStore -> Value -> IO (Maybe AnswerRecord)
lookupStoredAnswer store question =
  modifyMVar (runStoreAnswers store) $ \answers ->
    pure (answers, find (\answer -> answerReplayable answer && answerQuestion answer == question) answers)

storeReusableAnswer :: RunStore -> AnswerRecord -> IO ()
storeReusableAnswer store answer =
  modifyMVar_ (runStoreAnswers store) $ \answers -> do
    let next = answer : filter ((/= answerQuestion answer) . answerQuestion) answers
    writeAtomicJson store "answers.json" (StoredAnswers semanticStoreVersion next)
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
    writeAtomicJson store "checkpoint.json" (StoredCheckpoint semanticStoreVersion merged)
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
  bytes <- readStoreFile directory ["answers.json"] maxArtifactBytes
  case eitherDecodeStrict' bytes of
    Left why -> throwIO (StoreCorrupt path (T.pack why))
    Right stored
      | storedAnswersVersion stored /= semanticStoreVersion ->
          throwIO (StoreIncompatible path "unsupported answer store version")
      | otherwise -> pure (storedAnswersRecords stored)

readEffectRecords :: FilePath -> IO [EffectRecord]
readEffectRecords directory = do
  let path = directory </> "effects.ndjson"
  bytes <- readStoreFile directory ["effects.ndjson"] maxArtifactBytes
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
  outcome <- try @IOException (readStoreFile directory ["checkpoint.json"] maxArtifactBytes)
  case outcome of
    Left failure | isDoesNotExistError failure -> pure Nothing
    Left failure -> throwIO failure
    Right bytes -> case eitherDecodeStrict' bytes of
      Left why -> throwIO (StoreCorrupt path (T.pack why))
      Right stored
        | storedCheckpointVersion stored /= semanticStoreVersion ->
            throwIO (StoreIncompatible path "unsupported checkpoint version")
        | otherwise -> pure (Just (storedCheckpointPayload stored))

writeResultArtifact :: RunStore -> RunId -> Value -> Value -> Text -> IO ResultRef
writeResultArtifact store runId code value preview = do
  requireStore2 store
  let artifact = StoredResultArtifact 1 runId code value
  (bytes, digest) <- writeArtifact store "result.json" artifact
  pure
    ResultRef
      { resultArtifactVersion = 1,
        resultArtifactPath = "result.json",
        resultArtifactSha256 = digest,
        resultArtifactBytes = bytes,
        resultArtifactCode = code,
        resultArtifactPreview = T.take 500 (oneLine preview)
      }

readResultArtifact :: FilePath -> RunId -> ResultRef -> IO Value
readResultArtifact directory expectedRun reference =
  withStoreDirectory directory $ \descriptor -> readResultArtifactAt directory descriptor expectedRun reference

readResultArtifactAt :: FilePath -> Fd -> RunId -> ResultRef -> IO Value
readResultArtifactAt directory descriptor expectedRun reference = do
  let path = directory </> "result.json"
  unless (resultArtifactVersion reference == 1 && resultArtifactPath reference == "result.json") $
    throwIO (StoreCorrupt path "invalid result artifact reference")
  bytes <- readArtifactBytes descriptor ["result.json"] path (resultArtifactBytes reference) (resultArtifactSha256 reference)
  artifact <- decodeArtifact path bytes
  unless (canonicalArtifactBytes artifact == bytes) $
    throwIO (StoreCorrupt path "result artifact is not canonical compact JSON followed by one newline")
  unless (storedResultVersion artifact == 1) $
    throwIO (StoreIncompatible path "unsupported result artifact version")
  unless (storedResultRunId artifact == expectedRun) $
    throwIO (StoreCorrupt path "result artifact run id does not match its event")
  unless (storedResultCode artifact == resultArtifactCode reference) $
    throwIO (StoreCorrupt path "result artifact code does not match its event")
  pure (storedResultValue artifact)

writeQuestionArtifact :: RunStore -> RunId -> OccurrenceId -> Text -> Value -> IO QuestionRef
writeQuestionArtifact store runId occurrence intent question = do
  requireStore2 store
  ensureQuestionDirectory store
  let relative = questionRelativePath occurrence
      artifact = StoredQuestionArtifact 1 runId occurrence intent question
  (bytes, digest) <- writeArtifact store relative artifact
  pure
    QuestionRef
      { questionArtifactVersion = 1,
        questionArtifactPath = T.pack relative,
        questionArtifactSha256 = digest,
        questionArtifactBytes = bytes
      }

readQuestionArtifact :: FilePath -> RunId -> OccurrenceId -> Value -> QuestionRef -> IO (Text, Value)
readQuestionArtifact directory expectedRun expectedOccurrence expectedCode reference = do
  (path, artifact) <- readQuestionArtifactPayload directory expectedRun expectedOccurrence reference
  validateStoredQuestion path expectedCode (storedQuestionValue artifact)
  pure (storedQuestionIntent artifact, storedQuestionValue artifact)

-- | Read a private person question for a frontend that knows the public code name.
--
-- The machine retains the typed schema validator for the eventual answer.  This
-- reader verifies the reference, artifact identity, canonical bytes, question
-- shape, and that a structured or primitive code agrees with the public event.
readQuestionArtifactByCodeName :: FilePath -> RunId -> OccurrenceId -> Text -> QuestionRef -> IO (Text, Value)
readQuestionArtifactByCodeName directory expectedRun expectedOccurrence expectedCodeName reference =
  withStoreDirectory directory $ \descriptor ->
    readQuestionArtifactByCodeNameAt directory descriptor expectedRun expectedOccurrence expectedCodeName reference

readQuestionArtifactByCodeNameAt :: FilePath -> Fd -> RunId -> OccurrenceId -> Text -> QuestionRef -> IO (Text, Value)
readQuestionArtifactByCodeNameAt directory descriptor expectedRun expectedOccurrence expectedCodeName reference = do
  (path, artifact) <- readQuestionArtifactPayloadAt directory descriptor expectedRun expectedOccurrence reference
  fields <- validateStoredQuestionShape path (storedQuestionValue artifact)
  let actualCodeName = case KeyMap.lookup "code" fields of
        Just (String name) -> Just name
        Just (Object _) -> Just "structured"
        _ -> Nothing
  unless (actualCodeName == Just expectedCodeName) $
    throwIO (StoreCorrupt path "question artifact code/schema does not match its event")
  pure (storedQuestionIntent artifact, storedQuestionValue artifact)

readQuestionArtifactPayload :: FilePath -> RunId -> OccurrenceId -> QuestionRef -> IO (FilePath, StoredQuestionArtifact)
readQuestionArtifactPayload directory expectedRun expectedOccurrence reference =
  withStoreDirectory directory $ \descriptor ->
    readQuestionArtifactPayloadAt directory descriptor expectedRun expectedOccurrence reference

readQuestionArtifactPayloadAt :: FilePath -> Fd -> RunId -> OccurrenceId -> QuestionRef -> IO (FilePath, StoredQuestionArtifact)
readQuestionArtifactPayloadAt directory descriptor expectedRun expectedOccurrence reference = do
  let expectedRelative = questionRelativePath expectedOccurrence
      path = directory </> expectedRelative
  unless
    ( questionArtifactVersion reference == 1
        && questionArtifactPath reference == T.pack expectedRelative
    ) $
    throwIO (StoreCorrupt path "invalid question artifact reference")
  bytes <-
    readArtifactBytes
      descriptor
      ["person", "questions", T.unpack (occurrenceText expectedOccurrence) <> ".json"]
      path
      (questionArtifactBytes reference)
      (questionArtifactSha256 reference)
  artifact <- decodeArtifact path bytes
  unless (canonicalArtifactBytes artifact == bytes) $
    throwIO (StoreCorrupt path "question artifact is not canonical compact JSON followed by one newline")
  unless (storedQuestionVersion artifact == 1) $
    throwIO (StoreIncompatible path "unsupported question artifact version")
  unless (storedQuestionRunId artifact == expectedRun && storedQuestionOccurrence artifact == expectedOccurrence) $
    throwIO (StoreCorrupt path "question artifact identity does not match its event")
  pure (path, artifact)

requireStore2 :: RunStore -> IO ()
requireStore2 store =
  unless
    ( runStoreFormatVersion store == latestStoreVersion
        && runStoreProtocolVersion store == latestProtocolVersion
    )
    (throwIO (StoreIncompatible (runStoreDirectory store) "artifacts require store format 2 and protocol version 2"))

ensureQuestionDirectory :: RunStore -> IO ()
ensureQuestionDirectory store = Private.ensurePrivateDirectoryAt (runStoreRoot store) ["person", "questions"]

questionRelativePath :: OccurrenceId -> FilePath
questionRelativePath occurrence = "person" </> "questions" </> T.unpack (occurrenceText occurrence) <> ".json"

writeArtifact :: (ToJSON a) => RunStore -> FilePath -> a -> IO (Integer, Text)
writeArtifact store relative artifact = do
  let final = runStoreDirectory store </> relative
  outcome <- try @IOException $
    Private.publishPrivateFileAt (runStoreRoot store) (splitDirectories relative) $ \handle ->
      writeBoundedArtifact final handle (encode artifact <> "\n")
  case outcome of
    Left failure | isAlreadyExistsError failure -> throwIO (StoreAlreadyExists final)
    Left failure -> throwIO failure
    Right result -> pure result

writeBoundedArtifact :: FilePath -> Handle -> BL.ByteString -> IO (Integer, Text)
writeBoundedArtifact path handle bytes = do
  (count, context) <- foldM writeChunk (0, hashInit :: Context SHA256) (BL.toChunks bytes)
  pure (count, T.pack (show (hashFinalize context :: Digest SHA256)))
  where
    writeChunk (count, context) chunk = do
      let next = count + toInteger (BS.length chunk)
      when (next > maxArtifactBytes) $
        throwIO (StoreIncompatible path "artifact exceeds 67108864 bytes")
      BS.hPut handle chunk
      pure (next, hashUpdate context chunk)

readArtifactBytes :: Fd -> [FilePath] -> FilePath -> Integer -> Text -> IO BS.ByteString
readArtifactBytes descriptor components path expectedBytes expectedDigest = do
  when (expectedBytes <= 0 || expectedBytes > maxArtifactBytes) $
    throwIO (StoreCorrupt path "artifact byte count is outside the supported bound")
  opened <- try @IOException (readConfinedFileAt descriptor components maxArtifactBytes)
  (bytes, _) <-
    either
      (throwIO . StoreCorrupt path . T.pack . displayException)
      pure
      opened
  unless (toInteger (BS.length bytes) == expectedBytes) $
    throwIO (StoreCorrupt path "artifact byte count does not match its reference")
  unless (digestText bytes == expectedDigest) $
    throwIO (StoreCorrupt path "artifact SHA-256 does not match its reference")
  pure bytes

validateStoredQuestion :: FilePath -> Value -> Value -> IO ()
validateStoredQuestion path expectedCode question = do
  fields <- validateStoredQuestionShape path question
  unless (KeyMap.lookup "code" fields == Just expectedCode) $
    throwIO (StoreCorrupt path "question artifact code/schema does not match its event")

validateStoredQuestionShape :: FilePath -> Value -> IO Object
validateStoredQuestionShape path question = case question of
  Object fields -> do
    let names = sort (map Key.toText (KeyMap.keys fields))
    unless (names == ["addressee", "code", "draw", "prompt", "scope"]) $
      throwIO (StoreCorrupt path "question artifact does not have the questionJson shape")
    case KeyMap.lookup "prompt" fields of
      Just (String _) -> pure fields
      _ -> throwIO (StoreCorrupt path "question artifact prompt is not text")
  _ -> throwIO (StoreCorrupt path "question artifact question is not an object")

decodeArtifact :: (FromJSON a) => FilePath -> BS.ByteString -> IO a
decodeArtifact path bytes = case eitherDecodeStrict' bytes of
  Left why -> throwIO (StoreCorrupt path (T.pack why))
  Right value -> pure value

canonicalArtifactBytes :: (ToJSON a) => a -> BS.ByteString
canonicalArtifactBytes artifact = BL.toStrict (encode artifact <> "\n")

digestText :: BS.ByteString -> Text
digestText bytes = T.pack (show (hash bytes :: Digest SHA256))

oneLine :: Text -> Text
oneLine = T.unwords . T.words

writeAtomicJson :: ToJSON a => RunStore -> FilePath -> a -> IO ()
writeAtomicJson store file = Private.writePrivateAtomicAt (runStoreRoot store) [file] . BL.toStrict . encode

writeExclusiveJson :: ToJSON a => Private.PrivateRoot -> [FilePath] -> a -> IO ()
writeExclusiveJson root components = Private.writePrivateExclusiveAt root components . BL.toStrict . encode

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

data StoredResultArtifact = StoredResultArtifact
  { storedResultVersion :: !Int,
    storedResultRunId :: !RunId,
    storedResultCode :: !Value,
    storedResultValue :: !Value
  }

data StoredQuestionArtifact = StoredQuestionArtifact
  { storedQuestionVersion :: !Int,
    storedQuestionRunId :: !RunId,
    storedQuestionOccurrence :: !OccurrenceId,
    storedQuestionIntent :: !Text,
    storedQuestionValue :: !Value
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

instance ToJSON StoredResultArtifact where
  toJSON artifact =
    object
      [ "artifactVersion" .= storedResultVersion artifact,
        "runId" .= runIdText (storedResultRunId artifact),
        "result" .=
          object
            [ "code" .= storedResultCode artifact,
              "value" .= storedResultValue artifact
            ]
      ]

instance FromJSON StoredResultArtifact where
  parseJSON = withObject "result artifact" $ \o -> do
    version <- o .: "artifactVersion"
    runId <- RunId <$> o .: "runId"
    (code, value) <-
      o .: "result" >>= withObject "stored result" (\result -> (,) <$> result .: "code" <*> result .: "value")
    pure (StoredResultArtifact version runId code value)

instance ToJSON StoredQuestionArtifact where
  toJSON artifact =
    object
      [ "artifactVersion" .= storedQuestionVersion artifact,
        "runId" .= runIdText (storedQuestionRunId artifact),
        "occurrenceId" .= occurrenceText (storedQuestionOccurrence artifact),
        "intent" .= storedQuestionIntent artifact,
        "question" .= storedQuestionValue artifact
      ]

instance FromJSON StoredQuestionArtifact where
  parseJSON = withObject "question artifact" $ \o ->
    StoredQuestionArtifact
      <$> o .: "artifactVersion"
      <*> (RunId <$> o .: "runId")
      <*> (o .: "occurrenceId" >>= parseOccurrence)
      <*> o .: "intent"
      <*> o .: "question"

instance ToJSON LineageOperation where
  toJSON = toJSON . lineageText

instance FromJSON LineageOperation where
  parseJSON value = do
    text <- parseJSON value
    maybe (fail ("unknown lineage operation " <> T.unpack text)) pure (lineageOfText text)

instance ToJSON RunManifest where
  toJSON manifest =
    object $
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
        <> maybe [] (\answering -> ["personAnswering" .= answering]) (manifestPersonAnswering manifest)

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
      <*> o .:? "personAnswering"

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
