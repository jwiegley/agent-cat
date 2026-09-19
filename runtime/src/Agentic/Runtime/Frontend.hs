{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | Process interfaces over identity-bound private frontend stores.
module Agentic.Runtime.Frontend
  ( maxFrontendQueryBytes,
    runFrontendQuery,
    runFrontendExport,
    PreparedResultExport, withPreparedResultExport, publishPreparedResultExport,
    preparedExportRootIdentity, preparedExportBytes, preparedExportSha256, preparedExportDocument,
    readPublishedResultExport, readPublishedResultExportBytes,
  )
where

import Agentic.Runtime.Catalogue
import Agentic.Runtime.Frontend.Protocol (maxFrontendQueryBytes, maxFrontendReplyBytes)
import Agentic.Runtime.Snapshot (runSnapshotValue, snapshotResult)
import Agentic.Runtime.Snapshot.Checkpoint (captureSnapshotCheckpoint, encodeSnapshotCheckpoint, snapshotCheckpointValue)
import Agentic.Runtime.PrivateRoot
import Agentic.Runtime.Protocol
import Agentic.Runtime.Store (readQuestionArtifactByCodeNameAt, readQuestionArtifactSchemaAt, readResultArtifactAt)
import Control.Exception (SomeAsyncException, SomeException, bracket, displayException, fromException, throwIO, try)
import Control.Monad (unless, when)
import Crypto.Hash (Digest, SHA256, hash)
import Data.Aeson (FromJSON (parseJSON), Value (..), eitherDecodeStrict', encode, object, withObject, (.:), (.=))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import Data.Aeson.Types (Object, Pair, Parser, parseEither)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.Char (ord)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.Read as TR
import Data.Word (Word64)
import Data.Maybe (isJust)
import Data.Time.Clock (getCurrentTime)
import System.FilePath ((</>))
import System.Posix.Types (Fd)

-- | A private-root observation or an artifact query with its expected reference.
data FrontendQuery
  = OpenRoot !FilePath
  | ReadQuestion !String !RunId !OccurrenceId !Text !QuestionRef
  | ReadResult !String !RunId !ResultRef
  | ListRuns !String
  | ReadRun !String !RunId
  | ReadRunCheckpoint !String !RunId
  | ReadQuestionSchema !String !RunId !OccurrenceId !QuestionRef

-- | One request to publish a verified result beneath the configured state root.
data FrontendExportRequest = FrontendExportRequest
  { exportRootIdentity :: !String,
    exportRunId :: !RunId,
    exportReference :: !ResultRef,
    exportName :: !Text
  }

instance FromJSON FrontendQuery where
  parseJSON = withObject "frontend query" $ \fields -> do
    version <- fields .: "version" :: Parser Int
    unless (version `elem` [1, 2]) (fail "unsupported frontend query version")
    operation <- fields .: "operation" :: Parser Text
    case (version, operation) of
      (1, "open-root") -> do
        onlyKeys fields ["version", "operation", "path"]
        path <- fields .: "path"
        when (BS.length (TE.encodeUtf8 path) > 4096) (fail "frontend root path exceeds 4096 bytes")
        pure (OpenRoot (T.unpack path))
      (1, "read-question") -> do
        onlyKeys fields ["version", "operation", "rootIdentity", "runId", "occurrenceId", "codeName", "reference"]
        identity <- fields .: "rootIdentity"
        run <- fields .: "runId" >>= either (fail . T.unpack) pure . mkRunId
        occurrence <- fields .: "occurrenceId" >>= parseOccurrence
        code <- fields .: "codeName"
        when (T.null code || T.length code > 256) (fail "invalid frontend question code name")
        ReadQuestion identity run occurrence code <$> fields .: "reference"
      (1, "read-result") -> do
        onlyKeys fields ["version", "operation", "rootIdentity", "runId", "reference"]
        identity <- fields .: "rootIdentity"
        run <- fields .: "runId" >>= either (fail . T.unpack) pure . mkRunId
        ReadResult identity run <$> fields .: "reference"
      (1, "list-runs") -> do
        onlyKeys fields ["version", "operation", "rootIdentity"]
        ListRuns <$> fields .: "rootIdentity"
      (1, "read-run") -> do
        onlyKeys fields ["version", "operation", "rootIdentity", "runId"]
        identity <- fields .: "rootIdentity"
        run <- fields .: "runId" >>= either (fail . T.unpack) pure . mkRunId
        pure (ReadRun identity run)
      (2, "read-run-checkpoint") -> do
        onlyKeys fields ["version", "operation", "rootIdentity", "runId"]
        identity <- fields .: "rootIdentity"
        run <- fields .: "runId" >>= either (fail . T.unpack) pure . mkRunId
        pure (ReadRunCheckpoint identity run)
      (2, "read-question-schema") -> do
        onlyKeys fields ["version", "operation", "rootIdentity", "runId", "occurrenceId", "reference"]
        identity <- fields .: "rootIdentity"
        run <- fields .: "runId" >>= either (fail . T.unpack) pure . mkRunId
        occurrence <- fields .: "occurrenceId" >>= parseOccurrence
        ReadQuestionSchema identity run occurrence <$> fields .: "reference"
      _ -> fail "unsupported frontend query operation"

instance FromJSON FrontendExportRequest where
  parseJSON = withObject "frontend export request" $ \fields -> do
    exportOnlyKeys "request" fields ["version", "operation", "rootIdentity", "runId", "reference", "name"]
    version <- fields .: "version" :: Parser Int
    unless (version == 1) (fail "unsupported frontend export version")
    operation <- fields .: "operation" :: Parser Text
    unless (operation == "export-result") (fail "unsupported frontend export operation")
    identity <- fields .: "rootIdentity"
    run <- fields .: "runId" >>= either (fail . T.unpack) pure . mkRunId
    referenceValue <- fields .: "reference"
    reference <- parseStrictResultRef referenceValue
    name <- fields .: "name" >>= parseExportName
    pure (FrontendExportRequest identity run reference name)

onlyKeys :: Object -> [Text] -> Parser ()
onlyKeys fields allowed =
  unless (all ((`elem` allowed) . Key.toText) (KeyMap.keys fields)) (fail "frontend query contains unknown fields")

exportOnlyKeys :: String -> Object -> [Text] -> Parser ()
exportOnlyKeys label fields allowed =
  unless (all ((`elem` allowed) . Key.toText) (KeyMap.keys fields)) $
    fail ("frontend export " <> label <> " contains unknown fields")

parseStrictResultRef :: Value -> Parser ResultRef
parseStrictResultRef value = withObject "frontend export result reference" (\fields -> do
  exportOnlyKeys "result reference" fields ["artifactVersion", "path", "sha256", "bytes", "code", "preview"]
  parseJSON value) value

parseExportName :: Text -> Parser Text
parseExportName name
  | name `elem` ["", ".", ".."] = fail "frontend export name is empty or reserved"
  | bytes > 255 = fail "frontend export name exceeds 255 UTF-8 bytes"
  | T.any invalid name = fail "frontend export name contains a forbidden character"
  | otherwise = pure name
  where
    bytes = BS.length (TE.encodeUtf8 name)
    invalid character = character == '/' || character == '\\' || ord character <= 31 || ord character == 127

parseOccurrence :: Text -> Parser OccurrenceId
parseOccurrence text
  | T.length text > 20 = fail "frontend occurrence id exceeds 20 digits"
  | otherwise = case TR.decimal text :: Either String (Integer, Text) of
      Right (number, rest)
        | T.null rest && number <= toInteger (maxBound :: Word64) -> pure (OccurrenceId (fromInteger number))
      _ -> fail "frontend occurrence id is not a Word64 decimal string"

-- | Execute one bounded query without launching a run or granting its controls.
-- References and code names come from a validated event or restored snapshot.
runFrontendQuery :: BS.ByteString -> IO (Either Text BS.ByteString)
runFrontendQuery bytes
  | BS.length bytes > maxFrontendQueryBytes = pure (Left "frontend query exceeds 2097152 bytes")
  | otherwise = case eitherDecodeStrict' bytes of
      Left failure -> pure (Left (T.take 4096 ("frontend query: " <> T.pack failure)))
      Right query -> do
        outcome <- try @SomeException $ do
          value <- executeQuery query
          let response = encode value <> "\n"
          when (toInteger (BL.length response) > maxFrontendReplyBytes) $
            ioError (userError "frontend response exceeds its artifact byte bound")
          pure (BL.toStrict response)
        boundedOutcome outcome

-- | Verify and atomically publish one result beneath @STATE/exports@.
runFrontendExport :: FilePath -> BS.ByteString -> IO (Either Text BS.ByteString)
runFrontendExport stateRoot bytes
  | BS.length bytes > maxFrontendQueryBytes = pure (Left "frontend export request exceeds 2097152 bytes")
  | otherwise = case eitherDecodeStrict' bytes of
      Left failure -> pure (Left (T.take 4096 ("frontend export request: " <> T.pack failure)))
      Right request -> try @SomeException (executeExport stateRoot request) >>= boundedOutcome

boundedOutcome :: Either SomeException BS.ByteString -> IO (Either Text BS.ByteString)
boundedOutcome = \case
  Left failure | Just _ <- fromException @SomeAsyncException failure -> throwIO failure
  Left failure -> pure (Left (T.take 4096 (T.pack (displayException failure))))
  Right response -> pure (Right response)

executeExport :: FilePath -> FrontendExportRequest -> IO BS.ByteString
executeExport stateRoot request = bracket (openPrivateRoot "frontend export state root" stateRoot) closePrivateRoot $ \root -> do
  unless (exportRootIdentity request == privateRootIdentity root) $
    ioError (userError "frontend export root identity does not match configured state")
  withPreparedResultExport root (exportRunId request) (exportReference request) (exportName request) $ \prepared -> do
    publishPreparedResultExport prepared
    pure $ BL.toStrict (encode (reply "export-result"
      [ "runId" .= runIdText (exportRunId request),
        "name" .= exportName request,
        "path" .= (privateRootPath root </> "exports" </> T.unpack (exportName request)),
        "bytes" .= T.pack (show (preparedExportBytes prepared)),
        "sha256" .= preparedExportSha256 prepared,
        "code" .= resultArtifactCode (exportReference request)
      ]) <> "\n")

-- | Verified compact export bytes under retained state and export roots.
-- The callback owns these roots and bytes until publication or abandonment.
data PreparedResultExport = PreparedResultExport !PrivateRoot !PrivateRoot !Text !BS.ByteString !Value

preparedExportRootIdentity :: PreparedResultExport -> String
preparedExportRootIdentity (PreparedResultExport _ root _ _ _) = privateRootIdentity root
preparedExportBytes :: PreparedResultExport -> Integer
preparedExportBytes (PreparedResultExport _ _ _ bytes _) = toInteger (BS.length bytes)
preparedExportSha256 :: PreparedResultExport -> Text
preparedExportSha256 (PreparedResultExport _ _ _ bytes _) = digestText bytes
preparedExportDocument :: PreparedResultExport -> Value
preparedExportDocument (PreparedResultExport _ _ _ _ document) = document

withPreparedResultExport :: PrivateRoot -> RunId -> ResultRef -> Text -> (PreparedResultExport -> IO a) -> IO a
withPreparedResultExport root run reference name action = do
  _ <- either (ioError . userError) pure (parseEither parseExportName name)
  let components = ["runs", T.unpack (runIdText run), "runtime"]
      directory = privateRootPath root </> "runs" </> T.unpack (runIdText run) </> "runtime"
  value <- withPrivateDirectoryAt root components $ \descriptor -> readResultArtifactAt directory descriptor run reference
  assertPrivateRoot root
  let document = object ["code" .= resultArtifactCode reference, "value" .= value]
      output = BL.toStrict (encode document <> "\n")
  when (toInteger (BS.length output) > maxArtifactBytes) $
    ioError (userError "frontend export result exceeds 67108864 bytes")
  ensurePrivateDirectoryAt root ["exports"]
  bracket (openPrivateSubroot root ["exports"]) closePrivateRoot $ \exportsRoot ->
    action (PreparedResultExport root exportsRoot name output document)

publishPreparedResultExport :: PreparedResultExport -> IO ()
publishPreparedResultExport (PreparedResultExport root exportsRoot name output _) = do
  assertPrivateRoot root
  publishPrivateFileAt exportsRoot [T.unpack name] (\handle -> BS.hPut handle output)
  assertPrivateRoot exportsRoot
  assertPrivateRoot root

-- | Capture a published document by its retained identity, never by a caller path.
readPublishedResultExport :: PrivateRoot -> String -> Text -> Integer -> Text -> Value -> IO BS.ByteString
readPublishedResultExport root identity name size digest code =
  fst <$> readPublishedResultExportBytes root identity name size digest code

-- | The same captured document and decoded value, without reopening the file.
readPublishedResultExportBytes :: PrivateRoot -> String -> Text -> Integer -> Text -> Value -> IO (BS.ByteString, Value)
readPublishedResultExportBytes root identity name size digest code = do
  _ <- either (ioError . userError) pure (parseEither parseExportName name)
  unless (size >= 0 && size <= maxArtifactBytes) (ioError (userError "invalid export byte bound"))
  bracket (openPrivateSubroot root ["exports"]) closePrivateRoot $ \exportsRoot -> do
    unless (privateRootIdentity exportsRoot == identity) (ioError (userError "export root identity changed"))
    bytes <- readPrivateFileAt exportsRoot [T.unpack name] size
    unless (toInteger (BS.length bytes) == size && digestText bytes == digest) (ioError (userError "export byte identity changed"))
    document <- either (const (ioError (userError "invalid export document"))) pure (eitherDecodeStrict' bytes)
    case document of
      Object fields | KeyMap.size fields == 2 && KeyMap.member "value" fields ->
        unless (KeyMap.lookup "code" fields == Just code && BL.toStrict (encode document <> "\n") == bytes)
          (ioError (userError "export document identity changed"))
      _ -> ioError (userError "invalid export document")
    assertPrivateRoot exportsRoot
    assertPrivateRoot root
    pure (bytes,document)

executeQuery :: FrontendQuery -> IO Value
executeQuery = \case
  OpenRoot path -> bracket (openPrivateRoot "frontend state root" path) closePrivateRoot $ \root ->
    pure (reply "open-root" ["rootIdentity" .= privateRootIdentity root])
  ReadQuestion identity run occurrence code reference ->
    withRuntimeDirectory identity run $ \directory descriptor -> do
      (intent, question) <- readQuestionArtifactByCodeNameAt directory descriptor run occurrence code reference
      pure (reply "read-question" ["runId" .= runIdText run, "occurrenceId" .= T.pack (show (occurrenceNumber occurrence)), "intent" .= intent, "question" .= question])
  ReadResult identity run reference ->
    withRuntimeDirectory identity run $ \directory descriptor -> do
      value <- readResultArtifactAt directory descriptor run reference
      pure (reply "read-result" ["runId" .= runIdText run, "code" .= resultArtifactCode reference, "value" .= value])
  ListRuns identity -> withPrivateRootIdentity identity $ \root -> do
    now <- getCurrentTime
    entries <- withPrivateDirectoryAt root [] $ \descriptor ->
      listRunCatalogueAt (privateRootPath root) descriptor Nothing now
    assertPrivateRoot root
    pure (reply "list-runs" ["runs" .= map catalogueSummary entries])
  ReadRun identity run -> withPrivateRootIdentity identity $ \root -> do
    let components = ["runs", T.unpack (runIdText run)]
        directory = privateRootPath root </> "runs" </> T.unpack (runIdText run)
    now <- getCurrentTime
    record <- withPrivateDirectoryAt root components $ \descriptor ->
      readRunRecordAt directory descriptor Nothing now
    assertPrivateRoot root
    pure (reply "read-run" ["run" .= object
      [ "runId" .= runIdText run, "directory" .= directory,
        "manifest" .= recordManifest record, "ownership" .= ownershipText (recordOwnership record),
        "policy" .= recordPolicy record, "snapshot" .= fmap runSnapshotValue (recordSnapshot record)
      ]])

  ReadRunCheckpoint identity run -> withPrivateRootIdentity identity $ \root -> do
    let components = ["runs", T.unpack (runIdText run)]
        directory = privateRootPath root </> "runs" </> T.unpack (runIdText run)
    now <- getCurrentTime
    (record, envelopes) <- withPrivateDirectoryAt root components $ \descriptor ->
      readRunRecordWithEnvelopesAt directory descriptor Nothing now
    checkpoint <- case envelopes of
      [] -> pure Nothing
      _ -> do
        captured <- either (ioError . userError . T.unpack) pure (captureSnapshotCheckpoint run envelopes)
        _ <- either (ioError . userError . T.unpack) pure (encodeSnapshotCheckpoint captured)
        pure (Just (snapshotCheckpointValue captured))
    assertPrivateRoot root
    pure (replyV2 "read-run-checkpoint" ["run" .= object
      [ "runId" .= runIdText run, "directory" .= directory,
        "manifest" .= recordManifest record, "ownership" .= ownershipText (recordOwnership record),
        "policy" .= recordPolicy record, "checkpoint" .= checkpoint
      ]])
  ReadQuestionSchema identity run occurrence reference ->
    withRuntimeDirectory identity run $ \directory descriptor -> do
      (intent, question, code, schema) <- readQuestionArtifactSchemaAt directory descriptor run occurrence reference
      pure (replyV2 "read-question-schema"
        [ "runId" .= runIdText run, "occurrenceId" .= T.pack (show (occurrenceNumber occurrence)),
          "intent" .= intent, "question" .= question, "codeName" .= code, "answerSchema" .= schema
        ])

catalogueSummary :: CatalogueEntry -> Value
catalogueSummary (CatalogueCorrupt directory failure) = object
  ["kind" .= ("corrupt" :: Text), "directory" .= directory, "error" .= failure]
catalogueSummary (CatalogueRun record) =
  let manifest = recordManifest record
   in object
        [ "kind" .= ("run" :: Text), "directory" .= recordDirectory record,
          "runId" .= runIdText (frontendRunId manifest), "runnerId" .= frontendRunnerId manifest,
          "workflow" .= frontendWorkflow manifest, "cwd" .= frontendCwd manifest,
          "targetKind" .= frontendTargetKind manifest, "createdAt" .= frontendCreatedAt manifest,
          "parentRunId" .= fmap runIdText (frontendParentRunId manifest), "lineage" .= frontendLineage manifest,
          "invocation" .= frontendInvocation manifest,
          "persona" .= frontendPersona manifest, "ownership" .= ownershipText (recordOwnership record),
          "snapshot" .= fmap (snapshotSummary . runSnapshotValue) (recordSnapshot record),
          "resultReferenceAvailable" .= isJust (recordSnapshot record >>= snapshotResult)
        ]
  where
    snapshotSummary (Object fields) = Object (KeyMap.filterWithKey (\key _ -> key `elem`
      ["status", "lastSequence", "billFresh", "billMemo", "personAnswering", "failureClass"]) fields)
    snapshotSummary value = value

ownershipText :: RunOwnership -> Text
ownershipText = \case
  RunOwnedHere -> "observed"
  RunOwnedElsewhere -> "owned-elsewhere"
  RunOwnerStale -> "stale"
  RunNotStarted -> "not-started"
  RunTerminal -> "terminal"

withRuntimeDirectory :: String -> RunId -> (FilePath -> Fd -> IO Value) -> IO Value
withRuntimeDirectory identity run action = withPrivateRootIdentity identity $ \root -> do
  let components = ["runs", T.unpack (runIdText run), "runtime"]
      directory = privateRootPath root </> "runs" </> T.unpack (runIdText run) </> "runtime"
  withPrivateDirectoryAt root components $ \descriptor -> do
    value <- action directory descriptor
    assertPrivateRoot root
    pure value

digestText :: BS.ByteString -> Text
digestText bytes = T.pack (show (hash bytes :: Digest SHA256))

reply :: Text -> [Pair] -> Value
reply operation fields = object (["version" .= (1 :: Int), "operation" .= operation] <> fields)

replyV2 :: Text -> [Pair] -> Value
replyV2 operation fields = object (["version" .= (2 :: Int), "operation" .= operation] <> fields)
