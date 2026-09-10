{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | Process interfaces over identity-bound private frontend stores.
module Agentic.Runtime.Frontend
  ( maxFrontendQueryBytes,
    runFrontendQuery,
    runFrontendExport,
  )
where

import Agentic.Runtime.Catalogue
import Agentic.Runtime.Snapshot (runSnapshotValue, snapshotResult)
import Agentic.Runtime.PrivateRoot
import Agentic.Runtime.Protocol
import Agentic.Runtime.Store (readQuestionArtifactByCodeNameAt, readResultArtifactAt)
import Control.Exception (SomeAsyncException, SomeException, bracket, displayException, fromException, throwIO, try)
import Control.Monad (unless, when)
import Crypto.Hash (Digest, SHA256, hash)
import Data.Aeson (FromJSON (parseJSON), Value (..), eitherDecodeStrict', encode, object, withObject, (.:), (.=))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import Data.Aeson.Types (Object, Pair, Parser)
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

-- | Bound allowing a runtime reference and its separately encoded root identity.
maxFrontendQueryBytes :: Int
maxFrontendQueryBytes = 2 * maxFrameBytes

-- | A private-root observation or an artifact query with its expected reference.
data FrontendQuery
  = OpenRoot !FilePath
  | ReadQuestion !String !RunId !OccurrenceId !Text !QuestionRef
  | ReadResult !String !RunId !ResultRef
  | ListRuns !String
  | ReadRun !String !RunId

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
    unless (version == 1) (fail "unsupported frontend query version")
    operation <- fields .: "operation" :: Parser Text
    case operation of
      "open-root" -> do
        onlyKeys fields ["version", "operation", "path"]
        path <- fields .: "path"
        when (BS.length (TE.encodeUtf8 path) > 4096) (fail "frontend root path exceeds 4096 bytes")
        pure (OpenRoot (T.unpack path))
      "read-question" -> do
        onlyKeys fields ["version", "operation", "rootIdentity", "runId", "occurrenceId", "codeName", "reference"]
        identity <- fields .: "rootIdentity"
        run <- fields .: "runId" >>= either (fail . T.unpack) pure . mkRunId
        occurrence <- fields .: "occurrenceId" >>= parseOccurrence
        code <- fields .: "codeName"
        when (T.null code || T.length code > 256) (fail "invalid frontend question code name")
        ReadQuestion identity run occurrence code <$> fields .: "reference"
      "read-result" -> do
        onlyKeys fields ["version", "operation", "rootIdentity", "runId", "reference"]
        identity <- fields .: "rootIdentity"
        run <- fields .: "runId" >>= either (fail . T.unpack) pure . mkRunId
        ReadResult identity run <$> fields .: "reference"
      "list-runs" -> do
        onlyKeys fields ["version", "operation", "rootIdentity"]
        ListRuns <$> fields .: "rootIdentity"
      "read-run" -> do
        onlyKeys fields ["version", "operation", "rootIdentity", "runId"]
        identity <- fields .: "rootIdentity"
        run <- fields .: "runId" >>= either (fail . T.unpack) pure . mkRunId
        pure (ReadRun identity run)
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
          when (toInteger (BL.length response) > maxArtifactBytes + 4096) $
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
  let run = exportRunId request
      reference = exportReference request
      name = T.unpack (exportName request)
      runtimeComponents = ["runs", T.unpack (runIdText run), "runtime"]
      runtimeDirectory = privateRootPath root </> "runs" </> T.unpack (runIdText run) </> "runtime"
      destination = privateRootPath root </> "exports" </> name
  value <- withPrivateDirectoryAt root runtimeComponents $ \descriptor ->
    readResultArtifactAt runtimeDirectory descriptor run reference
  assertPrivateRoot root
  let output = BL.toStrict (encode (object ["code" .= resultArtifactCode reference, "value" .= value]) <> "\n")
  when (toInteger (BS.length output) > maxArtifactBytes) $
    ioError (userError "frontend export result exceeds 67108864 bytes")
  let receipt = BL.toStrict (encode (reply "export-result"
        [ "runId" .= runIdText run,
          "name" .= exportName request,
          "path" .= destination,
          "bytes" .= T.pack (show (BS.length output)),
          "sha256" .= digestText output,
          "code" .= resultArtifactCode reference
        ]) <> "\n")
  ensurePrivateDirectoryAt root ["exports"]
  bracket (openPrivateSubroot root ["exports"]) closePrivateRoot $ \exportsRoot -> do
    publishPrivateFileAt exportsRoot [name] (\handle -> BS.hPut handle output)
    assertPrivateRoot exportsRoot
    assertPrivateRoot root
  pure receipt

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
