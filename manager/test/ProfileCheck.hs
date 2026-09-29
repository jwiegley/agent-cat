{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
module Main (main) where

import Agentic.Manager
import Agentic.Runtime
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (AsyncCancelled (..), async, asyncThreadId, cancel, wait, waitCatch, withAsync)
import Control.Exception (IOException, fromException, try)
import Control.Monad (forM_, unless, void, when)
import Data.Aeson (Value (Object, String), eitherDecodeStrict', encode, object, toJSON, (.=))
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.Char (toUpper)
import Data.Either (isLeft, isRight)
import Data.List (isPrefixOf, sort, sortOn)
import Data.Text (Text)
import qualified Data.Text as T
import Numeric (showHex)
import GHC.Conc (BlockReason (BlockedOnMVar), ThreadStatus (ThreadBlocked), threadStatus)
import System.Directory (createDirectory, doesFileExist, getCurrentDirectory, listDirectory, removePathForcibly)
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

await :: String -> IO Bool -> IO ()
await label ready = do
  reached <- timeout 5000000 loop
  check label (reached == Just ())
  where
    loop = do
      done <- ready
      unless done (threadDelay 1000 >> loop)

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
  appendFile (observations <> ".pids") (show pid <> "\n")
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
    "help-malformed" -> case command of ["help",_] -> BS.hPut stdout (BS.singleton 255); _ -> reply command
    "help-overflow" -> case command of ["help",_] -> BS.hPut stdout (BS.replicate 70000 120); _ -> reply command
    -- Each of the first four help queries waits until four have started and
    -- then holds, so a fifth concurrent query would observe five live queries.
    -- Later help queries reply at once.
    "help-barrier" -> case command of
      ["help",name] -> helpMarked name $ \started -> unless (started > 4) $ do
        await "four help queries started" (((>= 4) . length . filter ("start." `isPrefixOf`)) <$> listDirectory markers)
        threadDelay 300000
      _ -> reply command
    "help-slow" -> case command of
      ["help",name] -> helpMarked name (const (threadDelay 3000000))
      _ -> reply command
    -- The first help query holds until the sixth has started, and every other
    -- help query replies at once. Only a pool whose free slots take later rows
    -- while the first query is live lets the sixth start.
    "help-pool" -> case command of
      ["help",name] -> helpMarked name $ \_ -> when (name == "concurrent_1") $
        await "sixth help query started while the first is live" (doesFileExist (markers </> "start.concurrent_6"))
      _ -> reply command
    -- The first help query holds while the second replies with text that
    -- discovery rejects and the third and fourth hold briefly, so the rejected
    -- reply arrives while the first row is still live. Later help queries
    -- reply at once.
    "help-halt-invalid" -> helpHalt (BS.singleton 255)
    "help-halt-long" -> helpHalt (BS.replicate 262145 120)
    -- The first help query holds while every later one replies with 200000
    -- characters of valid help, so the replies that wait behind the first row
    -- cross a ceiling of 1048576 bytes after six rows.
    "help-halt-bytes" -> case command of
      ["help",name]
        | name == "concurrent_1" -> helpMarked name (const (threadDelay 1500000))
        | otherwise -> helpMarked name (const (BS.hPut stdout (BS.replicate 200000 120)))
      _ -> reply command
    -- The first help query replies at once with text that discovery rejects,
    -- and the next three hold far beyond the group deadline.
    "help-failure-hang" -> case command of
      ["help",name]
        | name == "concurrent_1" -> helpMarked name (const (BS.hPut stdout (BS.singleton 255)))
        | name `elem` ["concurrent_2", "concurrent_3", "concurrent_4"] -> helpMarked name (const (threadDelay 20000000))
        | otherwise -> helpMarked name (const (pure ()))
      _ -> reply command
    "gated" -> do
      let phase = case command of
            ["frontend", "--capabilities"] -> "capabilities"
            ["list", "--json", "--descriptor-version", "3"] -> "catalogue"
            ["help",_] -> "help"
            _ -> error "unexpected gated query"
          gate = observations <> "." <> phase
      BS.writeFile (gate <> ".ready") BS.empty
      await "private fixture release deadline" (doesFileExist (gate <> ".go"))
      reply command
    _ -> error "unknown private fixture mode"
  where
    markers = observations <> ".help.d"
    helpHalt rejected = case command of
      ["help",name]
        | name == "concurrent_1" -> helpMarked name (const (threadDelay 1500000))
        | name == "concurrent_2" -> helpMarked name (const (BS.hPut stdout rejected))
        | name `elem` ["concurrent_3", "concurrent_4"] -> helpMarked name (const (threadDelay 500000))
        | otherwise -> helpMarked name (const (pure ()))
      _ -> reply command
    -- Record this help query's start, the number of help queries live at that
    -- moment, and its end, which precedes its reply and its exit.
    helpMarked :: String -> (Int -> IO ()) -> IO ()
    helpMarked name body = do
      BS.writeFile (markers </> ("start." <> name)) BS.empty
      entries <- listDirectory markers
      let count marker = length (filter (marker `isPrefixOf`) entries)
      appendFile (observations <> ".help.live") (show (count "start." - count "end.") <> "\n")
      body (count "start.")
      BS.writeFile (markers </> ("end." <> name)) BS.empty
      reply command
    reply ["frontend", "--capabilities"] = BS.readFile (replies </> "capabilities.json") >>= BS.hPut stdout
    reply ["list", "--json", "--descriptor-version", "3"] = BS.readFile (replies </> "catalogue.json") >>= BS.hPut stdout
    reply ["help",_] = BS.hPut stdout "Declared workflow help.\n"
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
        PersonAnswerLocalControl ["workspace"] (ConfigurationLimits 100 100 67108864 2 16 4 67108864 30 1) (exactPreparedTarget ["--scripted"])
      limits = QueryLimits 65536 2000000
      writeCaps caps = BL.writeFile (replies </> "capabilities.json") (encode caps)
      writeRows rows = BL.writeFile (replies </> "catalogue.json") (encode rows)
      readObservations = BS.readFile observations
      expected mode command = object ["args" .= (prefix mode <> command), "cwd" .= workspace, "env" .= sort environment]
      concurrentForm observed form rows =
        take 2 observed == [form ["frontend", "--capabilities"], form ["list", "--json", "--descriptor-version", "3"]]
          && sortOn encode (drop 2 observed) == sortOn encode [form ["help", T.unpack (workflowName row)] | row <- rows]
      decodeObservations = mapM (right . (eitherDecodeStrict' :: BS.ByteString -> Either String Value)) . filter (not . BS.null) . BS.split 10
      helpRows template count = [template {workflowName = "concurrent_" <> T.pack (show index)} | index <- [1 .. count :: Int]]
      helpMarkers = observations <> ".help.d"
      resetHelp = do
        removePathForcibly helpMarkers
        createDirectory helpMarkers
        BS.writeFile (observations <> ".help.live") BS.empty
        BS.writeFile (observations <> ".pids") BS.empty
      helpMarked marker = length . filter (marker `isPrefixOf`) <$> listDirectory helpMarkers
      assertAllReaped label = do
        pids <- map read . lines <$> readFile (observations <> ".pids")
        check (label <> ": launches recorded") (not (null pids))
        forM_ pids $ \pid -> try @IOException (signalProcess nullSignal pid) >>= check label . isLeft
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
  case discoveryPublicWorkflows discovery of
    [(ident,Object fields)] -> do
      check "public workflow identity and actual help retained"
        (ident == workflowIdentity "profile_main" (workflowName descriptor) && KM.lookup "help" fields == Just (String "Declared workflow help.\n"))
      check "public catalogue uses exact decimal size" (KM.lookup "size" fields == Just (String (T.pack (show (workflowSize descriptor)))))
      case KM.lookup "capabilities" fields of
        Just (Object capabilities) -> check "private control descriptor is not public" (not (KM.member "controlFd" capabilities))
        _ -> error "missing public capabilities"
    _ -> error "missing public workflow"
  selected <- select registry row >>= right
  let context = selectionContext selected
  check "invocation separate from server" (selectionInvocation selected == FrontendInvocation 1 "configured-wrapper" (T.pack executable) (map T.pack (prefix "normal")))
  check "private target preserved without parsing" (operatorTargetArguments context == ["--scripted"])
  observed <- readObservations >>= decodeObservations
  -- The capability and catalogue queries run in order. The operator decision of
  -- 2026-09-27 runs the help queries four at a time, so their launch order is
  -- not defined, and each row must have exactly one help query.
  check "exact ordered prefix/cwd/explicit env on all discovery subprocesses"
    (concurrentForm observed (expected "normal") [descriptor])
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
  serialized <- newRegistry (QueryLimits 65536 30000000) >>= right
  gated <- rowOf serialized (definition "gated")
  withAsync (probe serialized gated) $ \probing -> do
    await "capability query reached gate" (doesFileExist (observations <> ".capabilities.ready"))
    withAsync (rowOf serialized (definition "normal")) $ \reloading -> do
      await "reload blocks behind discovery" ((== ThreadBlocked BlockedOnMVar) <$> threadStatus (asyncThreadId reloading))
      BS.writeFile (observations <> ".capabilities.go") BS.empty
      await "catalogue query reached gate" (doesFileExist (observations <> ".catalogue.ready"))
      status <- threadStatus (asyncThreadId reloading)
      check "reload remains blocked through second query" (status == ThreadBlocked BlockedOnMVar)
      BS.writeFile (observations <> ".catalogue.go") BS.empty
      await "help query reached gate" (doesFileExist (observations <> ".help.ready"))
      threadStatus (asyncThreadId reloading) >>= check "reload remains blocked through help query" . (== ThreadBlocked BlockedOnMVar)
      BS.writeFile (observations <> ".help.go") BS.empty
      void (wait probing >>= right)
      replaced <- wait reloading
      check "serialized reload changes revision" (publicRevision replaced /= publicRevision gated)
      assertNoLaunch "old revision cannot launch after concurrent reload" $ do
        probe serialized gated >>= expect "old concurrent revision" StaleRevision
        select serialized gated >>= expect "old concurrent selection" StaleRevision
      select serialized replaced >>= expect "reload does not inherit previous discovery readiness" SupervisionUnavailable
  putStrLn "PASS registry: unknown, stale, removed, failed reload, fresh revisions, immutable contexts, explicit ownership, exact frozen public JSON, concurrent reload/probe serialization"

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
         ("failure", ProcessFailure), ("malformed", InvalidReply),
         ("help-malformed", InvalidReply), ("help-overflow", OutputOverflow)] $ \(mode, failure) -> do
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
  writeRows (helpRows descriptor 9)
  resetHelp
  beforeHelp <- readObservations
  -- The group deadline is the configured maximum here, so the barrier alone
  -- decides whether the first four help queries overlap.
  barrier <- newRegistry (QueryLimits 65536 30000000) >>= right
  concurrent <- rowOf barrier (definition "help-barrier")
  -- Discovery that starts fewer than four help queries at once leaves the
  -- first query waiting at the barrier until its fixture fails the probe.
  barrierResult <- probe barrier concurrent
  check "the first four help queries run at the same time" (isRight barrierResult)
  helped <- right barrierResult
  check "every row of a catalogue longer than the pool has public help" (length (discoveryPublicWorkflows helped) == 9)
  live <- map read . lines <$> readFile (observations <> ".help.live")
  check "help queries run four at a time and never more" (length live == 9 && maximum live == (4 :: Int))
  helpObserved <- readObservations >>= decodeObservations . BS.drop (BS.length beforeHelp)
  check "concurrent form: ordered capability and catalogue queries, then one help query per row"
    (concurrentForm helpObserved (expected "help-barrier") (helpRows descriptor 9))
  assertAllReaped "every concurrent help query reaped by Runtime"
  resetHelp
  pooled <- newRegistry (QueryLimits 65536 30000000) >>= right
  held <- rowOf pooled (definition "help-pool")
  pool <- probe pooled held
  check "a live help query does not hold back later rows: free slots take the next rows"
    (either (const False) ((== 9) . length . discoveryPublicWorkflows) pool)
  poolLive <- map read . lines <$> readFile (observations <> ".help.live")
  check "the pool runs help queries four at a time and never more" (length poolLive == 9 && maximum poolLive <= (4 :: Int))
  assertAllReaped "every pooled help query reaped by Runtime"
  writeRows (helpRows descriptor 12)
  resetHelp
  -- Each help query takes three seconds against a five-second budget, so the
  -- first four complete and the next four are in flight at the deadline.
  deadlined <- newRegistry (QueryLimits 65536 5000000) >>= right
  lagging <- rowOf deadlined (definition "help-slow")
  probe deadlined lagging >>= expect "help group deadline reported as timeout" QueryTimeout
  started <- helpMarked "start."
  ended <- helpMarked "end."
  check "help group deadline, not one query budget, ended discovery" (started > 4)
  check "help queries were in flight at the group deadline" (ended < started)
  assertAllReaped "every help query in flight at the group deadline reaped by Runtime"
  assertPublic deadlined "unavailable" "supervision-unavailable"
  -- A reply that fails its own checks stops later rows from starting at once,
  -- although an earlier row is still live, and the earlier row still decides
  -- which failure is reported.
  forM_ [("help-halt-invalid", InvalidReply), ("help-halt-long", OutputOverflow)] $ \(mode, failure) -> do
    resetHelp
    halting <- newRegistry (QueryLimits 4194304 30000000) >>= right
    halted <- rowOf halting (definition mode)
    probe halting halted >>= expect ("help reply rejected behind a live row: " <> mode) failure
    haltStarted <- helpMarked "start."
    check ("no help query starts after a reply fails its own checks: " <> mode) (haltStarted == 4)
    assertAllReaped ("every help query reaped after a rejected reply: " <> mode)
  -- Replies that wait behind a live row count against the byte ceiling, so the
  -- pool stops starting rows once they cross it.
  writeRows (helpRows descriptor 30)
  resetHelp
  buffering <- newRegistry (QueryLimits 1048576 30000000) >>= right
  buffered <- rowOf buffering (definition "help-halt-bytes")
  probe buffering buffered >>= expect "waiting help replies cross the byte ceiling" OutputOverflow
  bufferStarted <- helpMarked "start."
  check "no help query starts once waiting replies cross the byte ceiling" (bufferStarted <= 10)
  assertAllReaped "every help query reaped after the byte ceiling"
  -- A failure that decides the result ends the group at once. Queries still in
  -- flight are cancelled and cleaned up, and the failure is not replaced by
  -- 'QueryTimeout' at the group deadline.
  writeRows (helpRows descriptor 12)
  resetHelp
  failing <- newRegistry (QueryLimits 65536 5000000) >>= right
  hanging <- rowOf failing (definition "help-failure-hang")
  probe failing hanging >>= expect "a decided help failure is reported, not the group deadline" InvalidReply
  hangStarted <- helpMarked "start."
  hangEnded <- helpMarked "end."
  -- A cancelled query can end before its fixture records its start, so at
  -- most the four first rows are recorded.
  check "no help query starts after the first row fails" (hangStarted <= 4)
  check "help queries in flight after a decided failure were cancelled" (hangEnded == 1)
  assertAllReaped "every help query cancelled after a decided failure reaped by Runtime"
  writeRows [descriptor]
  putStrLn "PASS help: four concurrent queries at most in one pool, concurrent argv form, group deadline cleanup and report"
  putStrLn "PASS help: a rejected reply or waiting replies over the byte ceiling stop later rows, and a decided failure cancels queries in flight"
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
