{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module TuiRootRoleTests (tuiRootRoleTests) where

import Agentic.Runtime (FrontendServer (..), LineageOperation (RestartRun), RunRecord (..), RunOwnership (RunTerminal), WorkflowDescriptor (workflowRunnerVersion))
import qualified Agentic.Runtime as Runtime
import Agentic.Tui.Client (buildLaunchPreview, buildLineagePreview, loadInitialData, loadRunCatalogue)
import Agentic.Tui.Process (startMachine)
import qualified Agentic.Tui.Root as Local
import Agentic.Tui.Types (LaunchPreview, TargetSelection (TargetScripted), TuiConfig (..), validateStoredInvocation)
import Control.Concurrent.STM (newTBQueueIO)
import Control.Exception (IOException, displayException, finally, try)
import Control.Monad (forM_, unless)
import qualified Data.ByteString as BS
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import GHC.Clock (getMonotonicTimeNSec)
import System.Directory (doesFileExist, getTemporaryDirectory, listDirectory, removePathForcibly)
import System.Environment (getExecutablePath)
import System.FilePath ((</>))
import qualified System.Posix.Directory as Directory

-- The test executable records any accidental runner launch before failing.
tuiRootRoleTests :: WorkflowDescriptor -> LaunchPreview -> RunRecord -> IO ()
tuiRootRoleTests descriptor preview parentRecord = do
  temporary <- getTemporaryDirectory
  stamp <- getMonotonicTimeNSec
  runner <- getExecutablePath
  let bucket = temporary </> ("agentic-tui-root-role-" <> show stamp)
      path = bucket </> "manager"
      launched = bucket </> "unexpected-runner"
      config = TuiConfig "role-test" runner ["--root-role-runner", launched] bucket path
      server = FrontendServer "role-test" runner (workflowRunnerVersion descriptor)
  Directory.createDirectory bucket 0o700
  (do
    Runtime.withPrivateRoot "manager role fixture" path $ \root -> do
      Runtime.establishManagerRootRole root
      forM_ ["parent", "child", "partial"] $ \name -> do
        Runtime.ensurePrivateDirectoryAt root ["runs", name]
        Runtime.writePrivateExclusiveAt root ["runs", name, "sentinel"] "preserved"
      let lineage = parentRecord {recordDirectory = path </> "runs" </> "parent"}
          manifestBytes = Runtime.encodeFrontendManifest (recordManifest lineage)
      unless (recordOwnership lineage == RunTerminal && maybe False (const True) (recordSnapshot lineage)) $
        ioError (userError "lineage fixture must have a validated terminal snapshot")
      unless (validateStoredInvocation config (recordManifest lineage) == Right ()) $
        ioError (userError "lineage fixture invocation does not pass trusted configuration check")
      Runtime.writePrivateExclusiveAt root ["runs", "parent", "supervisor-manifest.json"] manifestBytes
      before <- listDirectory path
      startup <- try @IOException (Local.withPrivateRoot path (const (ioError (userError "local startup callback ran"))))
      expectThrownRole "TUI startup" startup
      missing <- try @IOException (Local.withPrivateRoot (path </> "missing" </> "state") (const (ioError (userError "local nested startup callback ran"))))
      expectThrownRole "TUI nested startup" missing
      loadInitialData config root >>= expectRole "TUI discovery"
      loadRunCatalogue config root >>= expectRole "TUI catalogue"
      buildLaunchPreview config root descriptor Map.empty TargetScripted >>= expectRole "TUI preview"
      buildLineagePreview config root descriptor lineage RestartRun >>= expectRole "TUI lineage preview"
      retainedManifest <- BS.readFile (path </> "runs" </> "parent" </> "supervisor-manifest.json")
      unless (retainedManifest == manifestBytes) (ioError (userError "TUI lineage refusal changed parent manifest"))
      queue <- newTBQueueIO 4
      startMachine server config root preview queue (pure ()) (const (pure ())) >>= expectRole "TUI launch"
      didLaunch <- doesFileExist launched
      unless (not didLaunch) (ioError (userError "manager root reached runner launch"))
      after <- listDirectory path
      unless (before == after) (ioError (userError "TUI changed manager root entries"))
      forM_ ["parent", "child", "partial"] $ \name -> do
        actual <- BS.readFile (path </> "runs" </> name </> "sentinel")
        unless (actual == "preserved") (ioError (userError "TUI changed manager fixture bytes"))
    Local.withPrivateRoot (bucket </> "late") $ \root -> do
      Runtime.establishManagerRootRole root
      let changed = config {tuiStateDir = Runtime.privateRootPath root}
      loadRunCatalogue changed root >>= expectRole "TUI refresh after role change")
    `finally` removePathForcibly bucket
  putStrLn "TUI root roles: startup, discovery, refresh, preview and launch refuse manager roots without changing their data"

expectRole :: String -> Either T.Text a -> IO ()
expectRole label outcome = case outcome of
  Left failure | "state root is owned by a manager" `T.isInfixOf` failure -> pure ()
  _ -> ioError (userError (label <> " did not refuse manager ownership"))

expectThrownRole :: String -> Either IOException a -> IO ()
expectThrownRole label outcome = expectRole label (either (Left . T.pack . displayException) Right outcome)
