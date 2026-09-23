{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
module Main (main) where

import qualified Agentic.Cli as Cli
import Agentic.Manager
import Agentic.Runtime
  ( PersonAnswering (..), FrontendServer (..), frontendCapabilities,
    decodeWorkflowDescriptor, workflowName )
import Control.Exception (bracket, fromException)
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (AsyncCancelled (..), withAsync, asyncThreadId, cancel, wait, waitCatch)
import Control.Monad (forM_, unless, void)
import Data.Aeson (Value (..), encode, eitherDecodeStrict', object, toJSON, (.=))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.Char (toUpper)
import Data.List (sort)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Vector as V
import Numeric (showHex)
import GHC.Conc (BlockReason (BlockedOnMVar), ThreadStatus (ThreadBlocked), threadStatus)
import System.Directory (createDirectory, doesDirectoryExist, doesFileExist, listDirectory, renameDirectory, removeFile)
import System.Environment (getArgs, getEnvironment)
import System.FilePath ((</>), takeDirectory)
import System.Posix.Files (createNamedPipe, createSymbolicLink, fileID, fileMode, getSymbolicLinkStatus, modificationTimeHiRes, setFileMode)
import System.Posix.IO (openFd, closeFd, defaultFileFlags, OpenMode (ReadOnly))
import System.Posix.Unistd (fileSynchronise)
import System.Posix.User (getEffectiveUserID)
import System.Timeout (timeout)

check :: String -> Bool -> IO ()
check label condition = unless condition (error ("FAILED: " <> label))

right :: Show e => Either e a -> IO a
right = either (error . show) pure

await :: String -> IO Bool -> IO ()
await label ready = do
  result <- timeout 5000000 loop
  check label (result == Just ())
  where
    loop = do
      done <- ready
      unless done (threadDelay 1000 >> loop)

refused :: String -> Either Diagnostic a -> IO ()
refused label result = check label (case result of Left InvalidConfiguration -> True; _ -> False)

field :: Text -> Value -> Value -> Value
field name value (Object fields) = Object (KM.insert (Key.fromText name) value fields)
field _ _ _ = error "fixture field expects object"

atField :: Text -> (Value -> Value) -> Value -> Value
atField name change original@(Object fields) = case KM.lookup (Key.fromText name) fields of
  Just value -> field name (change value) original
  Nothing -> error "fixture field missing"
atField _ _ _ = error "fixture field expects object"

first :: (Value -> Value) -> Value -> Value
first change (Array values) = Array (values V.// [(0, change (V.head values))])
first _ _ = error "fixture array missing"

main :: IO ()
main = do
  args <- getArgs
  case args of
    [work, source, fixture] -> checks work source fixture
    _ -> error "usage: configuration-check PRIVATE_WORK REPOSITORY PROFILE_FIXTURE_EXECUTABLE"

-- Test provisioning synchronizes each already-existing parent after mkdir.
durableDirectory :: FilePath -> IO ()
durableDirectory path = do
  createDirectory path
  setFileMode path 0o700
  forM_ [path, takeDirectory path] $ \directory ->
    bracket (openFd directory ReadOnly defaultFileFlags) closeFd fileSynchronise

checks :: FilePath -> FilePath -> FilePath -> IO ()
checks work source fixture = do
  uid <- getEffectiveUserID
  ambient <- getEnvironment
  check "harness has synthetic manager-only credential" (lookup "PROFILE_CHECK_MANAGER_ONLY" ambient == Just "SYNTHETIC_MANAGER_ONLY")
  let manager = work </> "manager"
      alternate = work </> "alternate"
      administration = work </> "administration"
      workspace = work </> "workspace"
      retention = work </> "retention"
      replies = work </> "replies"
      observations = work </> "observed.ndjson"
      path = work </> "operator.json"
      marker = manager </> ".agentic-root-role.json"
      registry = Cli.Registry "configuration-check" "workflow" "configuration validation" []
      limits = ConfigurationLimits 100 1000 67108864 10 32 4 67108864 60 1
      limitsJson = object ["drafts" .= (100 :: Int), "globalDrafts" .= (1000 :: Int),
        "globalCaptureBytes" .= (67108864 :: Int), "globalPageSets" .= (10 :: Int),
        "globalConnections" .= (32 :: Int), "globalDatabaseReaders" .= (4 :: Int),
        "globalMutationLedgerBytes" .= (67108864 :: Int), "safetyControlsPerMinute" .= (60 :: Int),
        "executionReservations" .= (1 :: Int)]
      environment = [("PROFILE_TEST_SECRET", "SYNTHETIC_OLD"), ("EXPLICIT_ONLY", "yes"),
        ("__CF_USER_TEXT_ENCODING", "0x" <> map toUpper (showHex uid "") <> ":0:0")]
      bindings values = toJSON [object ["name" .= name, "value" .= value] | (name, value) <- values :: [(String, String)]]
      prefix = ["fixture", "normal", observations, replies, "prefix one", "--marker"]
      profile = object ["id" .= ("main" :: Text), "runner" .= ("native:wrapper" :: Text),
        "workspace" .= workspace, "workspaceLabel" .= ("Review workspace" :: Text),
        "targetLabel" .= ("Deterministic worker" :: Text), "targetArguments" .= ["--scripted" :: Text],
        "environment" .= bindings environment, "ownership" .= ("service-owned" :: Text),
        "quarantined" .= False, "personAnswering" .= PersonAnswerLocalControl,
        "resourceKeys" .= ["workspace_review" :: Text, "engine_owned"]]
      runner = object ["alias" .= ("native:wrapper" :: Text), "executable" .= fixture, "prefix" .= prefix]
      valid = object ["version" .= (1 :: Int), "managerRoot" .= manager,
        "localRetentionRoots" .= [retention], "limits" .= limitsJson,
        "runners" .= [runner],
        "profiles" .= [profile]]
      changeProfile = atField "profiles" . first
      changeRunner = atField "runners" . first
      unusedRunner args = field "runners" (toJSON [runner,
        field "alias" (toJSON ("unused-wrapper" :: Text)) (field "prefix" (toJSON args) runner)]) valid
      credentialPrefixes = [["--api-key", "SYNTHETIC_PREFIX_VALUE"], ["--authorization=SYNTHETIC_PREFIX_VALUE"],
        ["--cookie", "SYNTHETIC_PREFIX_VALUE"], ["--PASSWORD=SYNTHETIC_PREFIX_VALUE"]] :: [[Text]]
      prefixCandidates = concat
        [[changeRunner (field "prefix" (toJSON args)) valid, unusedRunner args,
          field "profiles" (toJSON ([] :: [Value])) (unusedRunner args)] | args <- credentialPrefixes]
      writeValue value = BL.writeFile path (encode value) >> setFileMode path 0o600
      load value = writeValue value >> Cli.loadManagerConfiguration registry path
      install value = writeValue value >> Cli.openManagerConfiguration registry path
      noLaunch action = do
        before <- BS.readFile observations
        void action
        after <- BS.readFile observations
        check "refusal did not launch" (before == after)
      unchangedRoot action = do
        entries <- sort <$> listDirectory manager
        status <- getSymbolicLinkStatus manager
        void action
        afterEntries <- sort <$> listDirectory manager
        afterStatus <- getSymbolicLinkStatus manager
        check "prefix refusal leaves root unchanged" (entries == afterEntries && fileID status == fileID afterStatus
          && fileMode status == fileMode afterStatus && modificationTimeHiRes status == modificationTimeHiRes afterStatus)
      noMarker = doesFileExist marker >>= check "invalid installation did not publish marker" . not
      invalid label value = noLaunch $ do
        install value >>= refused label
        noMarker
      snapshot installed = configurationSnapshot installed >>= right
      one installed = snapshot installed >>= \(_, rows) -> case rows of
        [row] -> pure row
        _ -> error "expected single public profile"
      probe installed row = probeConfiguredProfile installed (publicId row) (publicRevision row)
      select installed row = selectConfiguredProfile installed (publicId row) (publicRevision row)
  forM_ [manager, alternate, administration, workspace, retention, replies] durableDirectory
  BS.writeFile observations BS.empty
  descriptor <- BS.readFile (source </> "test/fixtures/runtime/descriptor-v3/valid.json") >>= right . decodeWorkflowDescriptor
  BL.writeFile (replies </> "capabilities.json") (encode (frontendCapabilities (FrontendServer "native-fixture" "/actual/native" "0.1.0.0")))
  BL.writeFile (replies </> "catalogue.json") (encode [descriptor])
  void (load valid >>= right)
  noMarker
  invalid "missing administration root refuses before marker publication"
    (field "administrationRoot" (toJSON (work </> "missing-administration")) valid)
  invalid "administration cannot share manager storage"
    (field "administrationRoot" (toJSON manager) valid)
  invalid "administration cannot share local retention"
    (field "administrationRoot" (toJSON retention) valid)
  invalid "administration root must be absolute"
    (field "administrationRoot" (String "relative") valid)
  invalid "explicit administration null is not an omitted endpoint"
    (field "administrationRoot" Null valid)
  setFileMode administration 0o755
  invalid "administration root must be private"
    (field "administrationRoot" (toJSON administration) valid)
  setFileMode administration 0o700
  forM_ prefixCandidates $ \candidate -> noLaunch $ unchangedRoot $ do
    load candidate >>= refused "credential prefix loader diagnostic is fixed"
    install candidate >>= refused "credential prefix refuses before installation"
    noMarker
  let wrapperFlags = ["--wrapper-mode", "isolated", "--forward-native"] :: [Text]
  refused "wrapper flags are not native target grammar" (Cli.validateManagerTarget registry wrapperFlags)
  forM_ [changeRunner (field "prefix" (toJSON wrapperFlags)) valid, unusedRunner wrapperFlags] $ \candidate ->
    noLaunch $ unchangedRoot $ do
      void (load candidate >>= right)
      noMarker
  putStrLn "PASS prefix credentials: used, unused and no-profile runners refuse before root mutation or launch; non-native wrapper flags accepted"
  -- Preserve an actual accepted private fixture, including concrete absolute paths.
  BL.writeFile (work </> "valid-operator-v1.json") (encode valid)
  setFileMode (work </> "valid-operator-v1.json") 0o600
  forM_ [field "version" (toJSON (2 :: Int)) valid, field "extra" Null valid,
    changeProfile (field "unexpected" Null) valid,
    changeRunner (field "unexpected" Null) valid,
    atField "limits" (field "unexpected" Null) valid,
    changeProfile (field "runner" (toJSON ("unknown" :: Text))) valid,
    field "runners" (toJSON ([] :: [Value])) valid,
    field "profiles" (toJSON [profile, profile]) valid,
    changeProfile (field "id" (toJSON ("bad.id" :: Text))) valid,
    changeProfile (field "personAnswering" (toJSON ("local-stdin" :: Text))) valid,
    changeProfile (field "resourceKeys" (toJSON ["same" :: Text, "same"])) valid,
    changeProfile (field "resourceKeys" (toJSON ["invalid key" :: Text])) valid,
    changeProfile (field "resourceKeys" (toJSON (replicate 257 ("key" :: Text)))) valid,
    changeProfile (field "environment" (bindings [("KEY", "one"), ("KEY", "two")])) valid,
    changeProfile (field "environment" (bindings [("bad=key", "one")])) valid,
    changeProfile (field "environment" (bindings [("KEY", "nul\0")])) valid,
    changeProfile (field "environment" (bindings [("KEY", replicate 65537 's')])) valid,
    changeProfile (field "workspace" (toJSON ("relative" :: Text))) valid,
    changeProfile (field "workspaceLabel" (toJSON (T.replicate 4097 "😀"))) valid,
    changeProfile (field "targetArguments" (toJSON [T.replicate 65537 "x"])) valid,
    changeRunner (field "alias" (toJSON ("" :: Text))) valid,
    changeRunner (field "prefix" (toJSON (replicate 4097 ("" :: Text)))) valid,
    field "localRetentionRoots" (toJSON [retention, retention]) valid] $ invalid "closed/ bounded schema"
  forM_ ["drafts", "globalDrafts", "globalCaptureBytes", "globalPageSets", "globalConnections",
         "globalDatabaseReaders", "globalMutationLedgerBytes", "safetyControlsPerMinute", "executionReservations"] $ \name -> do
    let maximumValue = if name == "executionReservations" then 16 else 2147483647 :: Integer
    invalid "zero quota" (atField "limits" (field name (toJSON (0 :: Int))) valid)
    invalid "oversized quota" (atField "limits" (field name (toJSON (maximumValue + 1))) valid)
    void (load (atField "limits" (field name (toJSON maximumValue)) valid) >>= right)
  forM_ ["AGENT_CAT_PI_BRIDGE_SOCKET", "AGENT_CAT_PI_BRIDGE_TOKEN_FILE", "AGENT_CAT_PI_REMOTE_SOCKET", "AGENT_CAT_PI_REMOTE_SESSION"] $ \name ->
    invalid "known client dependency refused despite service-owned label" (changeProfile (field "environment" (bindings [(name, "synthetic")])) valid)
  invalid "explicit client ownership refuses service" (changeProfile (field "ownership" (toJSON ("client-bound" :: Text))) valid)
  forM_ [["--engine", "pi"], ["--scripted", "--engine", "acp"], ["--engine", "deck"],
         ["--engine", "acp", "--session", "existing"], ["--adapter", "stub"],
         ["--route", "model=acp:stub"], ["--persona", "one", "--persona", "two"],
         ["--offline", "--refresh-models"], ["--scripted", "--input-arg", "subject=data"],
         ["--engine", "acp", "--adapter-arg", "--token=SYNTHETIC_ARG_SECRET"],
         ["--adapter-arg", "--password=SYNTHETIC_ROUTING_SECRET"],
         ["--engine", "acp", "--route", "model=acp:stub", "--route", "model=acp:stub"],
         ["--unknown-SYNTHETIC_ARGUMENT"]] $ \args -> do
    refused "real CLI target rejection" (Cli.validateManagerTarget registry args)
    invalid "CLI hook invoked by loader" (changeProfile (field "targetArguments" (toJSON args)) valid)
  forM_ [["--scripted"], ["--engine", "acp", "--adapter", "stub", "--adapter-arg", "first", "--adapter-arg", "second"],
         ["--engine", "acp", "--route", "model=acp:stub"], ["--engine", "deck", "--session", "owned-resource"],
         ["--persona", "review", "--offline", "--realize", "axis=model"], ["--require-pinned"]] $ \args -> do
    void (right (Cli.validateManagerTarget registry args))
    void (load (changeProfile (field "targetArguments" (toJSON args)) valid) >>= right)
  let encoded = BL.toStrict (encode valid)
      limitsStart = "\"limits\":{"
      (beforeLimits, limitsSuffix) = BS.breakSubstring limitsStart encoded
  check "canonical fixture contains limits object" (not (BS.null limitsSuffix))
  let nestedDuplicate = beforeLimits <> limitsStart <> "\"drafts\":100," <> BS.drop (BS.length limitsStart) limitsSuffix
      duplicates = ["{\"version\":1," <> BS.drop 1 encoded,
                    "{\"vers\\u0069on\":1," <> BS.drop 1 encoded, nestedDuplicate]
  forM_ duplicates $ \bytes -> noLaunch $ do
    check "duplicate fixture otherwise matches valid configuration"
      ((eitherDecodeStrict' bytes :: Either String Value) == Right valid)
    BS.writeFile path bytes
    Cli.loadManagerConfiguration registry path >>= refused "otherwise-valid duplicate key refused"
    noMarker
  putStrLn "PASS duplicate keys: ordinary, escaped-equivalent and nested duplicates in otherwise valid configuration"
  forM_ ["{", "[]", "null", "{\"version\":1,\"version\":1}",
         "{\"version\":1,\"vers\\u0069on\":1}", "{\"a\":{\"x\":1,\"x\":2}}", "{\"a\":[1,]}",
         "{\"a\":tru}", "[", "\"unterminated", "{\"version\":1e999999999}",
         BS.replicate 65 91 <> BS.replicate 65 93,
         BL.toStrict (encode valid) <> " trailing", BS.pack [255]] $ \bytes -> noLaunch $ do
    BS.writeFile path bytes
    Cli.loadManagerConfiguration registry path >>= refused "bounded JSON token/codec failure"
    noMarker
  BS.writeFile path (encoded <> BS.replicate (2097152 - BS.length encoded) 32)
  void (Cli.loadManagerConfiguration registry path >>= right)
  BS.appendFile path " "
  Cli.loadManagerConfiguration registry path >>= refused "file byte ceiling before decode"
  writeValue valid
  setFileMode path 0o644
  Cli.openManagerConfiguration registry path >>= refused "non-private file refused"
  setFileMode path 0o600
  forM_ ["relative.json", path <> "\0", work, work </> "missing.json"] $ \badPath ->
    Cli.openManagerConfiguration registry badPath >>= refused "path or regular-file refusal"
  createSymbolicLink path (work </> "link.json")
  Cli.openManagerConfiguration registry (work </> "link.json") >>= refused "file symlink refused"
  createSymbolicLink work (work </> "linked-parent")
  Cli.openManagerConfiguration registry (work </> "linked-parent" </> "operator.json") >>= refused "ancestor symlink refused"
  createNamedPipe (work </> "fifo") 0o600
  Cli.openManagerConfiguration registry (work </> "fifo") >>= refused "FIFO refused without blocking"
  noMarker
  forM_ [[manager], [work], [manager </> "missing-child"]] $ \overlap -> noLaunch $ do
    install (field "localRetentionRoots" (toJSON overlap) valid) >>= refused "overlap before marker"
    noMarker
  install (field "managerRoot" (toJSON (work </> "missing" </> "ancestors")) valid) >>= refused "no implicit root provisioning"
  doesDirectoryExist (work </> "missing") >>= check "no ancestor creation" . not
  BS.writeFile (manager </> "legacy-data") "synthetic retained local data"
  install valid >>= refused "nonempty unmarked root cannot be appropriated"
  noMarker
  removeFile (manager </> "legacy-data")
  putStrLn "PASS configuration: private bounded files, strict JSON, native CLI grammar, ownership dependencies, immutable policy limits, overlap before marker"

  installed <- install valid >>= right
  doesFileExist marker >>= check "valid installation establishes real marker"
  (capturedLimits, initial) <- snapshot installed
  check "configuration limits captured once" (capturedLimits == limits && length initial == 1)
  row <- one installed
  select installed row >>= \result -> check "unprobed selection unavailable" (case result of Left SupervisionUnavailable -> True; _ -> False)
  void (probe installed row >>= right)
  selected <- select installed row >>= right
  let context = selectionContext selected
  check "exact captured prefix" (operatorPrefix context == prefix)
  check "exact captured environment" (operatorEnvironment context == environment)
  check "exact captured target/person/resources/limits"
    (operatorTargetArguments context == ["--scripted"] && operatorPersonAnswering context == PersonAnswerLocalControl
      && operatorResourceKeys context == ["workspace_review", "engine_owned"] && operatorConfigurationLimits context == limits)
  records <- BS.readFile observations >>= mapM (right . (eitherDecodeStrict' :: BS.ByteString -> Either String Value)) . filter (not . BS.null) . BS.split 10
  let expected command = object ["args" .= (prefix <> command), "cwd" .= workspace, "env" .= sort environment]
  check "real fixture sees exact prefix/cwd/explicit environment" (records ==
    [expected ["frontend", "--capabilities"], expected ["list", "--json", "--descriptor-version", "3"],
     expected ["help", T.unpack (workflowName descriptor)]])
  before <- snapshot installed
  markerBytes <- BS.readFile marker
  markerStatus <- getSymbolicLinkStatus marker
  forM_ prefixCandidates $ \candidate -> noLaunch $ unchangedRoot $ do
    writeValue candidate
    Cli.reloadManagerConfiguration registry installed path >>= refused "credential prefix reload diagnostic is fixed"
    snapshot installed >>= check "credential prefix reload preserves limits and revisions" . (== before)
    BS.readFile marker >>= check "credential prefix reload preserves marker bytes" . (== markerBytes)
    currentMarker <- getSymbolicLinkStatus marker
    check "credential prefix reload preserves marker identity and mode"
      (fileID markerStatus == fileID currentMarker && fileMode markerStatus == fileMode currentMarker)
  putStrLn "PASS prefix reload: all installed runner prefixes checked, fixed refusals preserve snapshot and existing root marker"
  writeValue (changeProfile (field "targetArguments" (toJSON ["--bogus" :: Text])) valid)
  Cli.reloadManagerConfiguration registry installed path >>= refused "invalid reload"
  after <- snapshot installed
  check "invalid reload preserves revisions and limits" (before == after)
  writeValue (field "managerRoot" (toJSON alternate) valid)
  Cli.reloadManagerConfiguration registry installed path >>= refused "root transfer forbidden"
  doesFileExist (alternate </> ".agentic-root-role.json") >>= check "alternate not marked" . not
  writeValue (field "localRetentionRoots" (toJSON [manager]) valid)
  Cli.reloadManagerConfiguration registry installed path >>= refused "active overlap forbidden"
  snapshot installed >>= check "failed overlap preserves prior snapshot" . (== before)
  let rotated = atField "limits" (field "executionReservations" (toJSON (2 :: Int))) $
        changeProfile (field "environment" (bindings [("PROFILE_TEST_SECRET", "SYNTHETIC_NEW")])
          . field "personAnswering" (toJSON PersonAnswerEngine)
          . field "resourceKeys" (toJSON ["new_resource" :: Text])) valid
  writeValue rotated
  void (Cli.reloadManagerConfiguration registry installed path >>= right)
  next <- one installed
  check "reload invalidates revision" (publicRevision next /= publicRevision row)
  noLaunch $ probe installed row >>= \result -> check "old revision refuses before launch" (case result of Left StaleRevision -> True; _ -> False)
  void (probe installed next >>= right)
  newSelection <- select installed next >>= right
  let newContext = selectionContext newSelection
  check "new context carries new policy/limits" (operatorEnvironment newContext == [("PROFILE_TEST_SECRET", "SYNTHETIC_NEW")]
    && operatorPersonAnswering newContext == PersonAnswerEngine && operatorResourceKeys newContext == ["new_resource"]
    && limitExecutionReservations (operatorConfigurationLimits newContext) == 2)
  check "old selection remains immutable facts" (operatorEnvironment context == environment
    && operatorConfigurationLimits context == limits && operatorPersonAnswering context == PersonAnswerLocalControl)
  snapshot installed >>= check "limits published with profiles" . ((== 2) . limitExecutionReservations . fst)
  let gatedObservations = work </> "gated-observations.ndjson"
      gatedPrefix = ["fixture", "gated", gatedObservations, replies, "prefix one", "--marker"]
  writeValue (changeRunner (field "prefix" (toJSON gatedPrefix)) valid)
  void (Cli.reloadManagerConfiguration registry installed path >>= right)
  gatedRow <- one installed
  candidate <- load rotated >>= right
  withAsync (probe installed gatedRow) $ \query -> do
    await "capability query gate reached" (doesFileExist (gatedObservations <> ".capabilities.ready"))
    withAsync (reloadConfiguration installed candidate) $ \abandoned -> do
      await "cancelled reload reaches configuration lock" ((== ThreadBlocked BlockedOnMVar) <$> threadStatus (asyncThreadId abandoned))
      cancel abandoned
      outcome <- waitCatch abandoned
      check "reload cancellation propagates without publishing" (case outcome of
        Left failure -> case fromException failure of Just AsyncCancelled -> True; Nothing -> False
        Right _ -> False)
    withAsync (reloadConfiguration installed candidate) $ \reload -> do
      await "reload waits for complete configured probe" ((== ThreadBlocked BlockedOnMVar) <$> threadStatus (asyncThreadId reload))
      withAsync (configurationSnapshot installed) $ \viewer -> do
        await "snapshot observer waits for atomic commit" ((== ThreadBlocked BlockedOnMVar) <$> threadStatus (asyncThreadId viewer))
        BS.writeFile (gatedObservations <> ".capabilities.go") BS.empty
        await "catalogue query gate reached" (doesFileExist (gatedObservations <> ".catalogue.ready"))
        threadStatus (asyncThreadId reload) >>= check "reload cannot interleave between discovery queries" . (== ThreadBlocked BlockedOnMVar)
        BS.writeFile (gatedObservations <> ".catalogue.go") BS.empty
        await "help query gate reached" (doesFileExist (gatedObservations <> ".help.ready"))
        threadStatus (asyncThreadId reload) >>= check "reload cannot interleave with help query" . (== ThreadBlocked BlockedOnMVar)
        BS.writeFile (gatedObservations <> ".help.go") BS.empty
        void (wait query >>= right)
        changed <- wait reload >>= right
        (viewLimits, viewProfiles) <- wait viewer >>= right
        check "observer sees coherent limits and revision snapshot" $
          (viewProfiles == changed && limitExecutionReservations viewLimits == 2)
          || (map publicRevision viewProfiles == [publicRevision gatedRow] && viewLimits == limits)
  putStrLn "PASS concurrent configuration reload: probe excludes reload through all discovery queries, observers receive coherent limits/revisions"
  stable <- snapshot installed
  renameDirectory retention (retention <> ".original")
  createSymbolicLink manager retention
  noLaunch $ do
    probe installed next >>= refused "retention alias overlap checked before launch"
    Cli.reloadManagerConfiguration registry installed path >>= refused "retention alias overlap checked on active reload"
  removeFile retention
  renameDirectory (retention <> ".original") retention
  bytes <- BS.readFile marker
  BS.writeFile marker "SYNTHETIC_INVALID_ROLE"
  noLaunch $ do
    Cli.reloadManagerConfiguration registry installed path >>= refused "malformed role refuses reload"
    probe installed next >>= refused "malformed role checked before launch"
  BS.writeFile marker bytes
  setFileMode marker 0o644
  noLaunch $ probe installed next >>= refused "non-private role checked before launch"
  setFileMode marker 0o600
  removeFile marker
  noLaunch $ do
    Cli.reloadManagerConfiguration registry installed path >>= refused "lost role cannot be recreated on reload"
    probe installed next >>= refused "lost role checked before launch"
    select installed next >>= refused "lost role checked before selection"
  doesFileExist marker >>= check "lost role not recreated" . not
  BS.writeFile marker bytes
  setFileMode marker 0o600
  renameDirectory manager (manager <> ".retained")
  durableDirectory manager
  noLaunch $ do
    Cli.reloadManagerConfiguration registry installed path >>= refused "root identity replacement refused"
    probe installed next >>= refused "retained identity checked before launch"
  renameDirectory manager (manager <> ".replacement")
  renameDirectory (manager <> ".retained") manager
  snapshot installed >>= check "all failed root checks preserve snapshot" . (== stable)
  writeValue (field "profiles" (toJSON ([] :: [Value])) valid)
  void (Cli.reloadManagerConfiguration registry installed path >>= right)
  (_, removed) <- snapshot installed
  check "profile removal installed" (null removed)
  doesFileExist marker >>= check "profile removal preserves root ownership"
  closeConfiguration installed
  closeConfiguration installed
  configurationSnapshot installed >>= refused "closed handle refuses"
  probe installed next >>= refused "closed handle cannot launch"
  config <- load valid >>= right
  reloadConfiguration installed config >>= refused "closed handle cannot reload"
  doesFileExist marker >>= check "close preserves root ownership"
  reopened <- installConfiguration config >>= right
  writeValue (changeProfile (field "quarantined" (Bool True)) valid)
  void (Cli.reloadManagerConfiguration registry reopened path >>= right)
  quarantined <- one reopened
  noLaunch $ probe reopened quarantined >>= \result -> check "quarantine captured and refuses service probing" (case result of Left Quarantined -> True; _ -> False)
  closeConfiguration reopened
  let withAdministration = field "administrationRoot" (toJSON administration) valid
  bracket (install withAdministration >>= right) closeConfiguration $ \owner -> do
    prior <- snapshot owner
    forM_ [valid, field "administrationRoot" (toJSON alternate) valid,
      field "localRetentionRoots" (toJSON [administration]) withAdministration] $ \adminCandidate -> do
      writeValue adminCandidate
      Cli.reloadManagerConfiguration registry owner path >>= refused "reload preserves administration binding and separation"
      snapshot owner >>= check "invalid administration reload preserves profile revisions and limits" . (== prior)
    writeValue withAdministration
    void (Cli.reloadManagerConfiguration registry owner path >>= right)
  putStrLn "PASS local administration configuration: private separated root, immutable endpoint and atomic reload refusal"
  getEnvironment >>= check "manager environment unchanged" . (== ambient)
  putStrLn "PASS installation/reload: retained root and role checks, no implicit provisioning, atomic policy revision replacement, old context retention, no role transfer or deletion"
  putStrLn "PASS boundary: actual CLI and Runtime modules, deterministic native fixture only, no service/approval/quota enforcement claim"
