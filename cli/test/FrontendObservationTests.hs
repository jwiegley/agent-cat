{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module FrontendObservationTests (frontendObservationTests) where

import qualified Agentic.Planning as P
import Agentic.Runtime
import Agentic.Schema
import Agentic.Schema.Json (codeJson)
import Control.Exception (SomeException, bracket, displayException, try)
import Control.Monad (foldM, forM_, unless, void)
import Data.Aeson (Value (..), eitherDecodeStrict', encode, object, toJSON, (.=))
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson.Types (Pair, parseEither)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString.Lazy as BL
import Data.Either (isLeft)
import Data.List (inits, sort)
import Data.Maybe (isJust)
import Data.Ratio ((%))
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import GHC.Clock (getMonotonicTimeNSec)
import System.Directory (createDirectoryIfMissing, getTemporaryDirectory, removeFile, removePathForcibly, renameDirectory)
import System.FilePath ((</>))
import System.IO (IOMode (WriteMode), hSetFileSize, withBinaryFile)
import System.Posix.Files (createSymbolicLink, setFileMode)
import System.Posix.Types (Fd)

frontendObservationTests :: FilePath -> IO ()
frontendObservationTests checkout = do
  temporary <- getTemporaryDirectory
  stamp <- getMonotonicTimeNSec
  let sandbox = temporary </> ("helper-integration-" <> show stamp)
  frontend <- BS.readFile (checkout </> "test/fixtures/runtime/frontend-manifest/v2.json") >>= require "frontend fixture" . decodeFrontendManifest
  bracket (privateDirectory sandbox >> pure sandbox) removePathForcibly $ \base -> do
    checkCapabilities
    forM_ [(1, name) | name <- ["success", "cancelled", "reused", "redirected", "recovery-failed", "failover-retried"]] $ \(version, name) ->
      checkFixture checkout base frontend version name
    forM_ ["person-result", "progress"] $ checkFixture checkout base frontend 2
    checkArtifacts base frontend
    checkCatalogue base frontend
    checkReadLimits base frontend
    checkReplyLimits base frontend
  putStrLn "helper integration tests passed: v1 reply contracts, v2 negotiation, snapshot prefixes, schemas, confinement, catalogue and byte limits"

checkCapabilities :: IO ()
checkCapabilities = do
  let caps = frontendCapabilities (FrontendServer "fixture" "/bin/agentic-run" "0.1.0.0")
  expect "IO version advertisement" (capabilityIoVersions caps == [1, 2])
  expect "IO operations advertisement" (capabilityIoOperations caps == ["open-root", "read-question", "read-result", "list-runs", "read-run", "read-run-checkpoint", "read-question-schema"])
  expect "other capability versions unchanged" (capabilitySessionVersions caps == [1] && capabilityExportVersions caps == [1] && capabilityInvocationVersions caps == [1])
  expect "capability shape unchanged" (keys (toJSON caps) == sort ["version", "operation", "server", "session", "io", "export", "frontendManifestVersions", "legacyFrontendManifests"])
  expect "capability codec" ((encodeFrontendCapabilities caps >>= decodeFrontendCapabilities) == Right caps)
  expect "hard transport bounds unchanged" (maxFrontendQueryBytes == 2 * 1024 * 1024 && maxFrontendReplyBytes == 64 * 1024 * 1024 + 4096)

checkFixture :: FilePath -> FilePath -> FrontendManifest -> Int -> String -> IO ()
checkFixture checkout base frontend version name = do
  (root, directory, identity) <- setup base (show version <> "-" <> name) frontend
  bytes <- BS.readFile (checkout </> "test/fixtures/runtime" </> ("protocol-v" <> show version) </> name <> ".ndjson")
  envelopes <- require name (traverse (decodeEnvelopeFor [version]) (BSC.lines bytes))
  let request = checkpointQuery identity
      legacy = query 1 "read-run" (runFields identity)
      runtime = directory </> "runtime"
      journal = runtime </> "events.ndjson"
  missing <- success request
  expect "absent runtime gives null checkpoint" (field "checkpoint" (field "run" missing) == Null)
  expect "checkpoint run metadata shape" (keys (field "run" missing) == sort ["runId", "directory", "manifest", "ownership", "policy", "checkpoint"])
  assertV1 (query 1 "open-root" ["path" .= root]) (query 1 "open-root" ["rootIdentity" .= identity])
  assertV1 legacy (legacyRun missing Null)
  withRunStoreVersioned version version runtime (manifest version) (const (pure ()))
  forM_ (zip [0 :: Int ..] (inits envelopes)) $ \(n, prefix) -> do
    writePrivate journal (journalBytes prefix)
    response <- success request
    expect "v2 reply envelope" (field "version" response == Number 2 && field "operation" response == String "read-run-checkpoint")
    expected <- require "shared fold" (foldM stepRunSnapshot (initialRunSnapshot run) prefix)
    now <- getCurrentTime
    (record, captured) <- withDirectoryFd directory $ \fd -> readRunRecordWithEnvelopesAt directory fd Nothing now
    expect "single capture retains exact prefix" (captured == prefix)
    let checkpointValue = field "checkpoint" (field "run" response)
    if null prefix then do
      expect "empty runtime gives null checkpoint and no snapshot" (checkpointValue == Null && recordSnapshot record == Nothing)
      expect "empty runtime not running" (field "ownership" (field "run" response) == String "not-started")
    else do
      checkpoint <- require "checkpoint decode" (decodeSnapshotCheckpoint (encoded checkpointValue))
      expect "exact snapshot including lastEnvelope" (checkpointSnapshot checkpoint == expected && recordSnapshot record == Just expected)
      expect "exact original prefix" (checkpointEnvelopes checkpoint == prefix)
      replay <- require "suffix" (appendSnapshotCheckpoint checkpoint (drop n envelopes))
      full <- require "full fold" (foldM stepRunSnapshot (initialRunSnapshot run) envelopes)
      expect "suffix equivalence" (checkpointSnapshot replay == full)
    assertV1 legacy (legacyRun response (if null prefix then Null else runSnapshotValue expected))
  assertCatalogue (query 1 "list-runs" ["rootIdentity" .= identity]) 1
  forM_ [(0, "read-run-checkpoint"), (3, "read-run-checkpoint"), (1, "read-run-checkpoint"), (1, "read-question-schema"), (2, "read-run"), (2, "list-runs"), (2, "read-question"), (2, "read-result"), (2, "open-root"), (2, "future")] $ \(v, op) ->
    refused "version/operation negotiation" (query v op (runFields identity))
  refused "unknown checkpoint field" (set "snapshot" Null request)
  refused "missing run" (delete "runId" request)
  refused "root identity mismatch" (set "rootIdentity" (String "[]") request)
  refused "run traversal" (set "runId" (String "..") request)
  forM_ ["{broken\n", BS.take (max 0 (BS.length bytes - 1)) bytes, journalBytes (drop 1 envelopes), bytes <> bytes] $ \bad -> do
    writePrivate journal bad
    refused "corrupt/torn/gapped/duplicate checkpoint" request
  writePrivate journal bytes
  let start = case envelopes of
        first : _ -> first
        [] -> error "nonempty fixture required"
  writePrivate journal (journalBytes [start {envelopeEvent = if version == 1 then RunStarted "other" "scripted" else RunStartedV2 "other" "scripted" PersonAnswerEngine}])
  refused "journal workflow mismatch" request
  writePrivate journal (journalBytes [start {envelopeRunId = RunId "other"}])
  refused "journal run mismatch" request
  writePrivate journal bytes
  writePrivate (directory </> "supervisor-manifest.json") (encodeFrontendManifest frontend {frontendRunId = run, frontendWorkflow = "other"})
  refused "frontend/runtime workflow mismatch" request
  writePrivate (directory </> "supervisor-manifest.json") (encodeFrontendManifest frontend {frontendRunId = RunId "other"})
  refused "manifest directory identity mismatch" request
  writePrivate (directory </> "supervisor-manifest.json") (encodeFrontendManifest frontend {frontendRunId = run})
  renameDirectory runtime (directory </> "saved-runtime")
  createSymbolicLink (directory </> "saved-runtime") runtime
  refused "runtime symlink" request
  removeFile runtime
  renameDirectory (directory </> "saved-runtime") runtime
  renameDirectory root (root <> "-old")
  privateDirectory root
  refused "captured root replacement" request

checkArtifacts :: FilePath -> FrontendManifest -> IO ()
checkArtifacts base frontend = do
  (_, directory, identity) <- setup base "artifacts" frontend
  let runtime = directory </> "runtime"
      question code = object ["code" .= code, "addressee" .= object ["person" .= object ["id" .= ("owner" :: Text)]], "scope" .= object ["model" .= Null, "mode" .= Null], "prompt" .= ("full\nquestion" :: Text), "draw" .= (0 :: Int)]
      nested = SStructured (schemaProperty @"ratios" (schemaArray schemaNumber) schemaObject)
      nestedCode = codeJson (fromSCode nested)
      samples = [(String "receipt", "receipt"), (String "flag", "flag"), (String "verdict", "verdict"), (nestedCode, "structured"), (object ["json" .= object ["schema" .= ("bogus" :: Text)]], "structured"), (String "ack", "ack")]
  refs <- withRunStoreVersioned 2 2 runtime (manifest 2) $ \store -> do
    references <- sequence [writeQuestionArtifact store run (OccurrenceId n) "consult" (question code) | (n, (code, _)) <- zip [0 ..] samples]
    resultRef <- writeResultArtifact store run (String "receipt") (object ["historical" .= True]) "done"
    pure (references, resultRef)
  now <- getCurrentTime
  let ownerPath = directory </> "owner.json"
      ownerBytes = encoded (object ["version" .= (1 :: Int), "ownerId" .= ("foreign" :: Text), "pid" .= (1 :: Int), "heartbeat" .= formatTime defaultTimeLocale "%FT%T%QZ" now])
  writePrivate ownerPath ownerBytes
  writePrivate (runtime </> "events.ndjson") (journalBytes [Envelope 2 run (SeqNo 0) "2026-09-03T00:00:00Z" (RunStartedV2 "review" "scripted" PersonAnswerLocalControl)])
  observed <- success (checkpointQuery identity)
  expect "checkpoint observes foreign ownership" (field "ownership" (field "run" observed) == String "owned-elsewhere")
  ownerAfter <- BS.readFile ownerPath
  expect "checkpoint does not acquire ownership" (ownerAfter == ownerBytes)
  forM_ ["answerPerson", "cancelRun", "steerOccurrence"] $ \operation ->
    refused "v2 grants no control authority" (query 2 operation (runFields identity))
  -- Both schema and v1 artifact readers remain independent of journal health.
  writePrivate (runtime </> "events.ndjson") "{torn"
  refused "checkpoint refuses unhealthy journal" (checkpointQuery identity)
  forM_ (zip3 [0 :: Int ..] samples (fst refs)) $ \(n, (code, name), reference) -> do
    let fields = runFields identity <> ["occurrenceId" .= T.pack (show n), "reference" .= reference]
        request = query 2 "read-question-schema" fields
        legacy = query 1 "read-question" (fields <> ["codeName" .= (name :: Text)])
    assertV1 legacy (query 1 "read-question"
      ["runId" .= runIdText run, "occurrenceId" .= T.pack (show n), "intent" .= ("consult" :: Text), "question" .= question code])
    if n >= 4 then refused "malformed structured/authoring code refused only by schema query" request
    else do
      response <- success request
      (expectedName, schema) <- require "planning schema" (parseEither P.answerSchemaForObservationCode code)
      expect "schema response exact shape and payload" (response == query 2 "read-question-schema"
        ["runId" .= runIdText run, "occurrenceId" .= T.pack (show n), "intent" .= ("consult" :: Text), "question" .= question code, "codeName" .= expectedName, "answerSchema" .= schema])
      refused "schema codeName is not client authority" (set "codeName" (String name) request)
      refused "schema missing reference" (delete "reference" request)
      refused "schema reference digest mismatch" (set "reference" (toJSON reference {questionArtifactSha256 = T.replicate 64 "0"}) request)
      refused "schema reference length mismatch" (set "reference" (toJSON reference {questionArtifactBytes = questionArtifactBytes reference + 1}) request)
      refused "schema reference path mismatch" (set "reference" (toJSON reference {questionArtifactPath = "person/questions/999.json"}) request)
      refused "schema occurrence mismatch" (set "occurrenceId" (String "999") request)
      refused "schema root mismatch" (set "rootIdentity" (String "[]") request)
  let verdictExtra = object ["tag" .= ("approve" :: Text), "objections" .= Null, "extra" .= True]
      rational = object ["numerator" .= (1 :: Int), "denominator" .= (3 :: Int)]
      nestedAnswer = object ["ratios" .= [rational]]
  expect "verdict extras accepted by final authority" (isJust (P.answerFromJson SVerdict verdictExtra))
  expect "nested 1/3 remains exact" (P.answerFromJson nested nestedAnswer == Just ([1 % 3], ()))
  expect "receipt accepts null" (isJust (P.answerFromJson SAck Null))
  expect "flag accepts false" (P.answerFromJson SFlag (Bool False) == Just False)
  assertV1 (query 1 "read-result" (runFields identity <> ["reference" .= snd refs]))
    (query 1 "read-result" ["runId" .= runIdText run, "code" .= ("receipt" :: Text), "value" .= object ["historical" .= True]])
  let firstRef = case fst refs of x : _ -> x; [] -> error "references missing"
      request = query 2 "read-question-schema" (runFields identity <> ["occurrenceId" .= ("0" :: Text), "reference" .= firstRef])
      questionPath = runtime </> "person/questions/0.json"
  original <- BS.readFile questionPath
  writePrivate questionPath "{}\n"
  refused "schema changed artifact bytes" request
  writePrivate questionPath original
  -- A valid reference must still bind stored run identity, not only path/digest.
  let otherRun = directory </> ".." </> "other"
      other = otherRun </> "runtime/person/questions"
  mapM_ privateDirectory [otherRun, otherRun </> "runtime", otherRun </> "runtime/person", other]
  writePrivate (other </> "0.json") original
  refusedWith "schema stored run mismatch" "question artifact identity does not match its event" (set "runId" (String "other") request)

checkCatalogue :: FilePath -> FrontendManifest -> IO ()
checkCatalogue base frontend = do
  (root, _, identity) <- setup base "catalogue" frontend
  forM_ [1 :: Int .. 999] $ \n -> privateDirectory (root </> "runs" </> ("corrupt-" <> show n))
  let request = query 1 "list-runs" ["rootIdentity" .= identity]
  response <- success request
  let entries = values (field "runs" response)
  expect "exactly 1000 catalogue children" (length entries == 1000)
  expect "corrupt entries retained" (length (filter ((== String "corrupt") . field "kind") entries) == 999)
  assertCatalogue request 1000
  privateDirectory (root </> "runs/overflow")
  refusedWith "1001 catalogue children refuse completely" "exceeds 1000 entries" request

checkReadLimits :: FilePath -> FrontendManifest -> IO ()
checkReadLimits base frontend = do
  (root, directory, identity) <- setup base "read-limits" frontend
  let runtime = directory </> "runtime"
      journal = runtime </> "events.ndjson"
      readBound limit = withDirectoryFd runtime (readRunStoreBoundedAt limit runtime)
      resize size = withBinaryFile journal WriteMode (\h -> hSetFileSize h size)
  withRunStoreVersioned 1 1 runtime (manifest 1) (const (pure ()))
  void (readBound 0)
  expectException "negative limit" "read limit must be" (readBound (-1))
  expectException "cannot relax 512 MiB maximum" "read limit must be" (readBound (512 * 1024 * 1024 + 1))
  let bytes = journalBytes [env 0 (RunStarted "review" "scripted")]
      limit = toInteger (BS.length bytes)
  writePrivate journal bytes
  (_, captured, _) <- readBound limit
  expect "exact tightened bound accepted" (captured == [env 0 (RunStarted "review" "scripted")])
  expectException "one byte over tightened bound refused by confined read" "confined file exceeds its byte bound" (readBound (limit - 1))
  resize (maxArtifactBytes + 1)
  refusedWith "64 MiB journal preallocation bound" "confined file exceeds its byte bound" (checkpointQuery identity)
  expectException "legacy still reads beyond 64 MiB" "torn final record" (withDirectoryFd runtime (readRunStoreAt runtime))
  resize (512 * 1024 * 1024 + 1)
  expectException "legacy maximum remains 512 MiB" "confined file exceeds its byte bound" (withDirectoryFd runtime (readRunStoreAt runtime))
  writePrivate journal ""
  let request = encoded (checkpointQuery identity)
      exactRequest = request <> BS.replicate (maxFrontendQueryBytes - BS.length request) 32
  void (runFrontendQuery exactRequest >>= require "exact request bound")
  runFrontendQuery (exactRequest <> " ") >>= expectLeft "request bound plus one"
  -- Validation precedes opening a missing manifest or journal.
  withDirectoryFd root $ \fd -> expectException "invalid read limit checked first" "read limit must be" (readRunStoreBoundedAt (-1) root fd)

checkReplyLimits :: FilePath -> FrontendManifest -> IO ()
checkReplyLimits base frontend = do
  (_, directory, identity) <- setup base "reply-limits" frontend
  let runtime = directory </> "runtime"
      journal = runtime </> "events.ndjson"
      attempt = AttemptId (OccurrenceId 0) 0
      output n text = env n (AttemptOutput attempt text)
      prefix = [env 0 (RunStarted "review" "scripted"), env 1 (OccurrenceStarted (OccurrenceId 0) "text" "consult" "model reviewer" "prompt"), env 2 (AttemptStarted attempt "scripted")]
        <> [output n (T.replicate 990000 "x") | n <- [3 .. 69]]
  withRunStoreVersioned 1 1 runtime (manifest 1) (const (pure ()))
  initial <- require "large prefix" (captureSnapshotCheckpoint run (prefix <> [output 70 ""]))
  initialBytes <- require "large prefix encoding" (encodeSnapshotCheckpoint initial)
  let room = fromInteger maxArtifactBytes - BS.length initialBytes
      exact = prefix <> [output 70 (T.replicate room "x")]
      over = prefix <> [output 70 (T.replicate (room + 1) "x")]
  expect "exact checkpoint journal fits lower read limit" (toInteger (BS.length (journalBytes exact)) < maxArtifactBytes)
  writePrivate journal (journalBytes exact)
  response <- runFrontendQuery (encoded (checkpointQuery identity)) >>= require "exact 64 MiB checkpoint helper reply"
  expect "whole response fits hard reply limit" (toInteger (BS.length response) <= maxFrontendReplyBytes)
  value <- require "large response JSON" (eitherDecodeStrict' response)
  restored <- require "large response checkpoint decode" (decodeSnapshotCheckpoint (encoded (field "checkpoint" (field "run" value))))
  expected <- require "large shared fold" (foldM stepRunSnapshot (initialRunSnapshot run) exact)
  expect "large helper snapshot exact Eq" (checkpointSnapshot restored == expected)
  writePrivate journal (journalBytes over)
  refusedWith "checkpoint encoding overflow without journal overflow" "snapshot checkpoint exceeds 67108864 bytes" (checkpointQuery identity)
  writePrivate journal (journalBytes exact)
  writePrivate (directory </> "supervisor-manifest.json") (encodeFrontendManifest frontend {frontendRunId = run, frontendTargetArgs = [T.replicate 8192 "x"]})
  refusedWith "complete reply overflow refuses without truncating" "frontend response exceeds its artifact byte bound" (checkpointQuery identity)

setup :: FilePath -> String -> FrontendManifest -> IO (FilePath, FilePath, Text)
setup base name frontend = do
  let root = base </> name
      directory = root </> "runs/run-1"
  mapM_ privateDirectory [root, root </> "runs", directory]
  writePrivate (directory </> "supervisor-manifest.json") (encodeFrontendManifest frontend {frontendRunId = run})
  value <- success (query 1 "open-root" ["path" .= root])
  identity <- case field "rootIdentity" value of String t -> pure t; _ -> fail "missing identity"
  pure (root, directory, identity)

manifest :: Int -> RunManifest
manifest version = RunManifest run "review" "0.1.0.0" (object ["program" .= ("fixture" :: Text)]) "scripted" (object ["kind" .= ("scripted" :: Text)]) Nothing RootRun Nothing (if version == 2 then Just PersonAnswerLocalControl else Nothing)

run :: RunId
run = RunId "run-1"

env :: Word -> RuntimeEvent -> Envelope
env n = Envelope 1 run (SeqNo (fromIntegral n)) "2026-09-03T00:00:00Z"

query :: Int -> Text -> [Pair] -> Value
query version operation fields = object (["version" .= version, "operation" .= operation] <> fields)

runFields :: Text -> [Pair]
runFields identity = ["rootIdentity" .= identity, "runId" .= runIdText run]

checkpointQuery :: Text -> Value
checkpointQuery identity = query 2 "read-run-checkpoint" (runFields identity)

encoded :: Value -> BS.ByteString
encoded = BL.toStrict . encode

journalBytes :: [Envelope] -> BS.ByteString
journalBytes = BS.concat . map (\e -> encodeEnvelope e <> "\n")

privateDirectory :: FilePath -> IO ()
privateDirectory path = createDirectoryIfMissing True path >> setFileMode path 0o700

writePrivate :: FilePath -> BS.ByteString -> IO ()
writePrivate path bytes = BS.writeFile path bytes >> setFileMode path 0o600

success :: Value -> IO Value
success value = runFrontendQuery (encoded value) >>= require "helper reply" >>= require "reply JSON" . eitherDecodeStrict'

assertV1 :: Value -> Value -> IO ()
assertV1 request expected = do
  actual <- runFrontendQuery (encoded request) >>= require "v1 query"
  expect "complete canonical v1 reply" (actual == encoded expected <> "\n")

legacyRun :: Value -> Value -> Value
legacyRun response snapshot = query 1 "read-run"
  ["run" .= set "snapshot" snapshot (delete "checkpoint" (field "run" response))]

assertCatalogue :: Value -> Int -> IO ()
assertCatalogue request count = do
  response <- success request
  expect "catalogue v1 reply fields" (keys response == sort ["version", "operation", "runs"]
    && field "version" response == Number 1 && field "operation" response == String "list-runs")
  expect "catalogue complete entry count" (length (values (field "runs" response)) == count)

withDirectoryFd :: FilePath -> (Fd -> IO a) -> IO a
withDirectoryFd path action = withPrivateRoot "frontend observation test root" path $ \root ->
  withPrivateDirectoryAt root [] action

refused :: String -> Value -> IO ()
refused label value = runFrontendQuery (encoded value) >>= expectLeft label

refusedWith :: String -> Text -> Value -> IO ()
refusedWith label message value = runFrontendQuery (encoded value) >>= \result -> case result of
  Left failure -> expect (label <> ": " <> T.unpack failure) (message `T.isInfixOf` failure)
  Right _ -> fail (label <> " accepted")

expectException :: String -> Text -> IO a -> IO ()
expectException label message action = do
  outcome <- try @SomeException action
  case outcome of
    Left failure -> expect (label <> ": " <> displayException failure) (message `T.isInfixOf` T.pack (displayException failure))
    Right _ -> fail (label <> " accepted")

expect :: String -> Bool -> IO ()
expect label condition = unless condition (fail label)

expectLeft :: String -> Either e a -> IO ()
expectLeft label = expect (label <> " accepted") . isLeft

require :: Show e => String -> Either e a -> IO a
require label = either (fail . ((label <> ": ") <>) . show) pure

field :: KM.Key -> Value -> Value
field key (Object fields) = maybe (error ("missing test field " <> show key)) id (KM.lookup key fields)
field _ _ = error "expected test object"

keys :: Value -> [KM.Key]
keys (Object fields) = sort (KM.keys fields)
keys _ = error "expected test object"

values :: Value -> [Value]
values (Array xs) = foldr (:) [] xs
values _ = error "expected test array"

set :: KM.Key -> Value -> Value -> Value
set key value (Object fields) = Object (KM.insert key value fields)
set _ _ _ = error "expected test object"

delete :: KM.Key -> Value -> Value
delete key (Object fields) = Object (KM.delete key fields)
delete _ _ = error "expected test object"
