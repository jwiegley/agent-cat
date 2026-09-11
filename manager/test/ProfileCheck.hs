{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
module Main (main) where

import Agentic.Manager
import Agentic.Runtime
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (AsyncCancelled (..), async, cancel, waitCatch)
import Control.Exception (IOException, fromException, try)
import Control.Monad (forM_, unless, void)
import Data.Aeson (Value (Object), eitherDecodeStrict', encode, object, toJSON, (.=))
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.Char (toUpper)
import Data.Either (isLeft)
import Data.List (sort)
import Data.Text (Text)
import qualified Data.Text as T
import Numeric (showHex)
import System.Directory (createDirectory, getCurrentDirectory)
import System.Environment (getArgs, getEnvironment, getExecutablePath)
import System.Exit (exitFailure)
import System.FilePath ((</>))
import System.IO (hClose, stderr, stdout)
import System.Posix.Process (getProcessID)
import System.Posix.Signals (nullSignal, signalProcess)
import System.Posix.User (getEffectiveUserID)
import System.Timeout (timeout)

check :: String -> Bool -> IO ()
check label condition = unless condition (error ("FAILED: " <> label))

right :: Show e => Either e a -> IO a
right = either (error . show) pure

expect :: String -> Diagnostic -> Either Diagnostic a -> IO ()
expect label expected result = check label (case result of Left actual -> actual == expected; Right _ -> False)

main :: IO ()
main = do
  args <- getArgs
  case args of
    "fixture" : mode : observations : replies : "prefix one" : "--marker" : command -> fixture mode observations replies command
    [root, source] -> checks root source
    _ -> error "usage: profile-check PRIVATE_TEST_DIRECTORY REPOSITORY"

fixture :: String -> FilePath -> FilePath -> [String] -> IO ()
fixture mode observations replies command = do
  args <- getArgs
  working <- getCurrentDirectory
  environment <- getEnvironment
  pid <- getProcessID
  writeFile (observations <> ".pid") (show pid)
  BL.appendFile observations (encode (object ["args" .= args, "cwd" .= working, "env" .= sort environment]) <> "\n")
  case mode of
    "timeout" -> threadDelay 5000000
    "wait-timeout" -> hClose stdout >> hClose stderr >> threadDelay 5000000
    "overflow-out" -> BS.hPut stdout (BS.replicate 70000 120)
    "overflow-err" -> BS.hPut stderr (BS.replicate 70000 120)
    "failure" -> BS.hPut stderr "SYNTHETIC_PRIVATE_DIAGNOSTIC" >> exitFailure
    "malformed" -> BS.hPut stdout "SYNTHETIC_PRIVATE_DECODER_DATA"
    "dual" -> BS.hPut stderr (BS.replicate 70000 120) >> reply command
    "normal" -> reply command
    _ -> error "unknown private fixture mode"
  where
    reply ["frontend", "--capabilities"] = BS.readFile (replies </> "capabilities.json") >>= BS.hPut stdout
    reply ["list", "--json", "--descriptor-version", "3"] = BS.readFile (replies </> "catalogue.json") >>= BS.hPut stdout
    reply _ = error "unexpected query argv"

checks :: FilePath -> FilePath -> IO ()
checks root source = do
  executable <- getExecutablePath
  uid <- getEffectiveUserID
  ambient <- getEnvironment
  check "synthetic manager credential present only in harness" (lookup "PROFILE_CHECK_MANAGER_ONLY" ambient == Just "SYNTHETIC_MANAGER_ONLY")
  working <- getCurrentDirectory
  let replies = root </> "replies"
      workspace = root </> "workspace"
      observations = root </> "observed.ndjson"
      server = FrontendServer "actual-native-server" "/actual/native/runner" "0.1.0.0"
      native = frontendCapabilities server
      prefix mode = ["fixture", mode, observations, replies, "prefix one", "--marker"]
      -- macOS startup synthesizes this binding if absent. Supply it explicitly
      -- so the fixture can compare the complete environment without filtering.
      environment = [("PROFILE_TEST_SECRET", "SYNTHETIC_SECRET_OLD"), ("EXPLICIT_ONLY", "yes"), ("__CF_USER_TEXT_ENCODING", "0x" <> map toUpper (showHex uid "") <> ":0:0")]
      definition mode = OperatorProfile "profile_main" "Review workspace" "Deterministic worker"
        "configured-wrapper" executable (prefix mode) workspace ["--scripted"] environment ServiceOwned False
      limits = QueryLimits 65536 2000000
      writeCaps caps = BL.writeFile (replies </> "capabilities.json") (encode caps)
      writeRows rows = BL.writeFile (replies </> "catalogue.json") (encode rows)
      readObservations = BS.readFile observations
      rowOf registry p = reloadProfiles registry [p] >>= right >>= \rows -> case rows of
        [row] -> pure row
        _ -> error "expected one profile"
      probe registry row = probeProfile registry (publicId row) (publicRevision row)
      select registry row = selectProfile registry (publicId row) (publicRevision row)
      assertNoLaunch label action = do
        before <- readObservations
        void action
        after <- readObservations
        check label (before == after)
      assertReaped = do
        pid <- read <$> readFile (observations <> ".pid")
        result <- try @IOException (signalProcess nullSignal pid)
        check "query process reaped by Runtime" (isLeft result)
  createDirectory replies
  createDirectory workspace
  BS.writeFile observations BS.empty
  descriptor <- BS.readFile (source </> "test/fixtures/runtime/descriptor-v3/valid.json") >>= right . decodeWorkflowDescriptor
  writeCaps native
  writeRows [descriptor]
  forM_ [QueryLimits 0 1, QueryLimits 4194305 1, QueryLimits 1 0, QueryLimits 1 30000001] $ \invalid ->
    newRegistry invalid >>= expect "invalid limits" InvalidConfiguration
  registry <- newRegistry limits >>= right
  publicProfiles registry >>= check "empty registry" . null
  assertNoLaunch "unknown selection refuses without launch" $ do
    probeProfile registry "manifest-executable-is-not-authority" "anything" >>= expect "unknown probe" UnknownProfile
    selectProfile registry "missing" "anything" >>= expect "unknown selection" UnknownProfile
  row <- rowOf registry (definition "normal")
  select registry row >>= expect "unprobed unavailable" SupervisionUnavailable
  assertNoLaunch "stale probe never launches" $ probeProfile registry (publicId row) "stale" >>= expect "stale" StaleRevision
  discovery <- probe registry row >>= right
  check "actual identity distinct from configured wrapper" (discoveryServer discovery == server)
  check "real Runtime descriptor roundtrip" (discoveryWorkflows discovery == [descriptor])
  selected <- select registry row >>= right
  let context = selectionContext selected
  check "invocation separate from server" (selectionInvocation selected == FrontendInvocation 1 "configured-wrapper" (T.pack executable) (map T.pack (prefix "normal")))
  check "private target preserved without parsing" (operatorTargetArguments context == ["--scripted"])
  observed <- readObservations >>= mapM (right . (eitherDecodeStrict' :: BS.ByteString -> Either String Value)) . filter (not . BS.null) . BS.split 10
  let expected command = object ["args" .= (prefix "normal" <> command), "cwd" .= workspace, "env" .= sort environment]
  check "exact ordered prefix/cwd/explicit env on both subprocesses"
    (observed == [expected ["frontend", "--capabilities"], expected ["list", "--json", "--descriptor-version", "3"]])
  views <- publicProfiles registry
  golden <- BS.readFile (source </> "test/fixtures/manager/v1/valid/profiles.json") >>= right . (eitherDecodeStrict' :: BS.ByteString -> Either String Value)
  let frozenProfile = case golden of
        Object fields -> KM.lookup "items" fields
        _ -> Nothing
      expectedPublic = case views of
        [view] -> case toJSON view of
          Object fields -> Just (toJSON [Object (KM.insert "revision" (toJSON ("profile_rev_4" :: Text)) fields)])
          _ -> Nothing
        _ -> Nothing
  check "public JSON exactly matches frozen Profile object" (frozenProfile == expectedPublic)
  check "public JSON contains no private fields or synthetic secrets" (not ("SYNTHETIC" `BS.isInfixOf` BL.toStrict (encode views)))
  forM_ [ (definition "normal") {operatorId = ""}, (definition "normal") {operatorId = "é"},
          (definition "normal") {operatorId = T.replicate 129 "a"},
          (definition "normal") {operatorId = "bad.id"},
          (definition "normal") {operatorRunnerAlias = ""},
          (definition "normal") {operatorRunnerAlias = T.replicate 257 "a"},
          (definition "normal") {operatorPrefix = replicate 4097 ""},
          (definition "normal") {operatorPrefix = [replicate 65537 'x']},
          (definition "normal") {operatorExecutable = '/' : replicate 4096 'x'},
          (definition "normal") {operatorExecutable = "/nul\0"},
          (definition "normal") {operatorCwd = "/nul\0"},
          (definition "normal") {operatorWorkspaceLabel = T.replicate 4097 "😀"},
          (definition "normal") {operatorTargetLabel = T.replicate 4097 "x"},
          (definition "normal") {operatorExecutable = "relative"},
          (definition "normal") {operatorCwd = "relative"},
          (definition "normal") {operatorPrefix = ["nul\0"]},
          (definition "normal") {operatorTargetArguments = ["nul\0"]},
          (definition "normal") {operatorEnvironment = [("", "value")]},
          (definition "normal") {operatorEnvironment = [("bad=key", "value")]},
          (definition "normal") {operatorEnvironment = [("bad\0key", "value")]},
          (definition "normal") {operatorEnvironment = [("KEY", "nul\0")]},
          (definition "normal") {operatorEnvironment = [("KEY", "one"), ("KEY", "two")]} ] $ \invalid -> do
    reloadProfiles registry [invalid] >>= expect "invalid reload" InvalidConfiguration
    publicProfiles registry >>= check "failed reload preserves ready snapshot/revision" . (== views)
  reloadProfiles registry [definition "normal", definition "normal"] >>= expect "duplicate ids" InvalidConfiguration
  publicProfiles registry >>= check "duplicate batch preserves snapshot" . (== views)
  edge <- rowOf registry ((definition "normal") {operatorId = T.replicate 128 "a", operatorWorkspaceLabel = T.replicate 4096 "😀", operatorTargetLabel = "", operatorRunnerAlias = "native:wrapper"})
  check "token/Unicode-label boundary accepted" (T.length (publicId edge) == 128)
  fresh <- rowOf registry ((definition "normal") {operatorEnvironment = [("PROFILE_TEST_SECRET", "SYNTHETIC_SECRET_NEW")]})
  assertNoLaunch "old revision revoked before launch" $ do
    probe registry row >>= expect "stale after rotation" StaleRevision
    select registry row >>= expect "stale selection after rotation" StaleRevision
  check "fresh revision on rotation" (publicRevision fresh /= publicRevision row)
  check "previously selected context immutable" (operatorEnvironment (selectionContext selected) == environment)
  void (probe registry fresh >>= right)
  freshSelected <- select registry fresh >>= right
  check "new selection uses rotated environment" (operatorEnvironment (selectionContext freshSelected) == [("PROFILE_TEST_SECRET", "SYNTHETIC_SECRET_NEW")])
  unchanged <- rowOf registry ((definition "normal") {operatorEnvironment = [("PROFILE_TEST_SECRET", "SYNTHETIC_SECRET_NEW")]})
  check "identical reload also rotates revision" (publicRevision unchanged /= publicRevision fresh)
  void (reloadProfiles registry [] >>= right)
  assertNoLaunch "removed profile refuses without launch" $ do
    probe registry unchanged >>= expect "removed probe" UnknownProfile
    select registry unchanged >>= expect "removed selection" UnknownProfile
  forM_ [(ClientBound, False, UnsupportedOperation, "unavailable", "unsupported-operation"),
         (ServiceOwned, True, Quarantined, "quarantined", "quarantined")] $ \(ownership, quarantined, failure, readiness, refusal) -> do
    blocked <- rowOf registry ((definition "normal") {operatorOwnership = ownership, operatorQuarantined = quarantined})
    assertNoLaunch "explicit policy blocks even native-looking executable" $ do
      probe registry blocked >>= expect "policy probe refusal" failure
      select registry blocked >>= expect "policy selection refusal" failure
    assertPublic registry readiness refusal
  putStrLn "PASS registry: unknown, stale, removed, failed reload, fresh revisions, immutable contexts, explicit ownership, exact frozen public JSON"

  let missing =
        [ native {capabilitySessionVersions = []}, native {capabilityInvocationVersions = []},
          native {capabilityInputSources = []}, native {capabilityMaxRequestBytes = 1},
          native {capabilityIoVersions = [1]}, native {capabilityExportVersions = []},
          native {capabilityExportOperations = []}, native {capabilityExportFormat = "wrong"},
          native {capabilityExportDestination = "wrong"}, native {capabilityManifestVersions = [2]},
          native {capabilityLegacyManifests = False} ]
        <> [native {capabilitySessionOperations = filter (/= operation) (capabilitySessionOperations native)} | operation <- capabilitySessionOperations native]
        <> [native {capabilityIoOperations = filter (/= operation) (capabilityIoOperations native)} | operation <- capabilityIoOperations native]
  forM_ missing $ \caps -> do
    writeCaps caps
    missingRow <- rowOf registry (definition "normal")
    before <- readObservations
    probe registry missingRow >>= expect "missing native capability unavailable" UnsupportedOperation
    after <- readObservations
    check "missing capability prevents catalogue launch" (length (BS.split 10 after) == length (BS.split 10 before) + 1)
    select registry missingRow >>= expect "missing capability prevents mutation selection" UnsupportedOperation
    assertPublic registry "unavailable" "unsupported-operation"
  writeCaps native
  writeRows [descriptor {workflowRunnerVersion = "different"}]
  mismatch <- rowOf registry (definition "normal")
  probe registry mismatch >>= expect "runner version agreement required" RunnerVersionMismatch
  assertPublic registry "unavailable" "supervision-unavailable"
  let c = workflowCapabilities descriptor
      badRows = [(descriptor {workflowDescriptorVersion = 2}, UnsupportedOperation),
        (descriptor {workflowProtocolVersions = [1]}, InvalidReply),
        (descriptor {workflowStoreVersions = [1]}, InvalidReply),
        (descriptor {workflowPersonAnsweringModes = ["local-stdin"]}, InvalidReply)]
        <> [(descriptor {workflowCapabilities = bad}, UnsupportedOperation) | bad <-
          [c {descriptorStructuredRun = False}, c {descriptorWholeRunCancel = False},
           c {descriptorControlFd = Nothing}, c {descriptorRequestControls = False},
           c {descriptorSemanticResume = False}, c {descriptorImmutableFork = False}, c {descriptorRestartFromScratch = False}]]
  forM_ badRows $ \(bad, expectedFailure) -> do
    writeRows [bad]
    badRow <- rowOf registry (definition "normal")
    probe registry badRow >>= expect "missing workflow protocol/capability" expectedFailure
  BS.writeFile (replies </> "catalogue.json") "SYNTHETIC_CATALOGUE_SECRET"
  badCatalogue <- rowOf registry (definition "normal")
  probe registry badCatalogue >>= expect "safe descriptor decoder failure" InvalidReply
  writeRows [descriptor]
  putStrLn "PASS capabilities: 22 native advertisement omissions, 11 descriptor deficiencies, version mismatch, native codec failures"

  forM_ [("overflow-out", OutputOverflow), ("overflow-err", OutputOverflow),
         ("failure", ProcessFailure), ("malformed", InvalidReply)] $ \(mode, failure) -> do
    bad <- rowOf registry (definition mode)
    probe registry bad >>= expect ("bounded/safe " <> mode) failure
    assertReaped
    assertPublic registry "unavailable" "supervision-unavailable"
  forM_ ["timeout", "wait-timeout"] $ \mode -> do
    quick <- newRegistry (QueryLimits 65536 200000) >>= right
    slow <- rowOf quick (definition mode)
    probe quick slow >>= expect "query time bounded, including wait" QueryTimeout
    assertReaped
  larger <- newRegistry (QueryLimits 131072 2000000) >>= right
  dual <- rowOf larger (definition "dual")
  void (probe larger dual >>= right)
  assertReaped
  missingExecutable <- rowOf registry ((definition "normal") {operatorExecutable = root </> "does-not-exist-SYNTHETIC_SECRET"})
  probe registry missingExecutable >>= expect "safe launch exception" ProcessFailure
  assertPublic registry "unavailable" "supervision-unavailable"
  slow <- rowOf registry (definition "timeout")
  beforeCancel <- readObservations
  task <- async (probe registry slow)
  let awaitLaunch = do
        current <- readObservations
        if current /= beforeCancel then pure () else threadDelay 1000 >> awaitLaunch
  launched <- timeout 2000000 awaitLaunch
  cancel task
  check "cancellation fixture launched within budget" (launched == Just ())
  cancelled <- waitCatch task
  check "async cancellation propagates unchanged" $ case cancelled of
    Left failure -> case fromException failure of
      Just AsyncCancelled -> True
      Nothing -> False
    Right _ -> False
  assertReaped
  void (rowOf registry (definition "normal"))
  secondRegistry <- newRegistry limits >>= right
  second <- rowOf secondRegistry (definition "normal")
  check "registries use distinct revision namespaces" (publicRevision second /= publicRevision row)
  getEnvironment >>= check "parent environment unchanged" . (== ambient)
  getCurrentDirectory >>= check "parent cwd unchanged" . (== working)
  putStrLn "PASS process: exact argv/cwd/env, concurrent drains, stdout/stderr overflow, timeout/wait timeout, exit/exec errors, cancellation, sole-reaper cleanup"
  putStrLn "PASS scope: snapshot values only, no approval/root-role integration or SQLite experiment"

assertPublic :: Registry -> Text -> Text -> IO ()
assertPublic registry readiness refusal = do
  rows <- publicProfiles registry
  case rows of
    [row] -> case toJSON row of
      Object fields -> do
        check "fixed public readiness" (KM.lookup "readiness" fields == Just (toJSON readiness))
        check "fixed public refusal" (KM.lookup "refusal" fields == Just (toJSON refusal))
        check "exact public fields" (sort (KM.keys fields) == sort ["version", "id", "revision", "workspaceLabel", "targetLabel", "readiness", "refusal"])
      _ -> error "public profile is not an object"
    _ -> error "expected one public profile"
