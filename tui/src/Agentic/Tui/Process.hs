{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | POSIX machine-child ownership for the terminal frontend.
module Agentic.Tui.Process
  ( RunningMachine (..),
    MachineExit (..),
    startMachine,
    sendMachineControl,
    terminateMachine,
  )
where

import Agentic.Runtime
  ( Control,
    Envelope,
    FrontendManifest (..),
    LineageOperation (..),
    PersonAnswering (PersonAnswerLocalControl),
    RunId (runIdText),
    RunRecord (..),
    WorkflowDescriptor (..),
    WorkflowInputDescriptor (..),
    decodeEnvelopeFor,
    encodeControlFor,
    frontendManifestVersion,
    maxFrameBytes,
    mkRunId,
    revalidateLineageParentAt,
  )
import Agentic.Tui.ProcessGroup
import Agentic.Tui.Root
import Agentic.Tui.Types
import Control.Concurrent (ThreadId, forkIO, threadDelay)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, readMVar, takeMVar, tryPutMVar, tryReadMVar)
import Control.Concurrent.STM (TBQueue, atomically, writeTBQueue)
import Control.Exception (IOException, SomeAsyncException, SomeException, displayException, finally, fromException, mask_, throwIO, try)
import Control.Monad (unless, when)
import Crypto.Hash (Digest, SHA256, hash)
import Data.Aeson (encode, object, (.=))
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Text.Encoding.Error (lenientDecode)
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import GHC.Clock (getMonotonicTimeNSec)
import System.Environment (getEnvironment)
import System.Exit (ExitCode)
import System.FilePath (takeFileName, (</>))
import System.IO (Handle, hClose, hFlush)
import System.Posix.Process (getProcessID)
import System.Posix.Types (ProcessID)
import System.Process
  ( CreateProcess (cwd, env, std_err, std_in, std_out),
    StdStream (CreatePipe),
    proc
  )

-- | Terminal disposition of one owned child.
data MachineExit
  = MachineExited !ExitCode !Text
  | MachineProtocolFailed !Text
  deriving (Eq, Show)

-- | Handles and ownership facts retained while the child is live.
data RunningMachine = RunningMachine
  { runningRunId :: !RunId,
    runningDirectory :: !FilePath,
    runningPid :: !ProcessID,
    runningGroup :: !ProcessGroup,
    runningControl :: !Handle,
    runningStdout :: !Handle,
    runningStderr :: !Handle,
    runningReaderThread :: !ThreadId,
    runningErrorThread :: !ThreadId,
    runningWaiterThread :: !ThreadId,
    runningHeartbeatThread :: !ThreadId,
    runningExit :: !(MVar (Either IOException ExitCode)),
    runningFailure :: !(MVar MachineExit)
  }

startMachine ::
  TuiConfig ->
  PrivateRoot ->
  LaunchPreview ->
  TBQueue Envelope ->
  IO () ->
  (MachineExit -> IO ()) ->
  IO (Either Text RunningMachine)
startMachine config root preview events notifyFrame notifyExit = do
  partialDirectory <- newIORef Nothing
  partialProcess <- newIORef Nothing
  result <- try @SomeException (prepareAndStart partialDirectory partialProcess config root preview events notifyFrame notifyExit)
  case result of
    Left failure -> do
      readIORef partialProcess >>= mapM_ terminatePartialProcess
      readIORef partialDirectory >>= mapM_ (removePartialDirectory root)
      case fromException failure :: Maybe SomeAsyncException of
        Just _ -> throwIO failure
        Nothing -> pure (Left (T.pack (displayException failure)))
    Right running -> pure (Right running)

prepareAndStart :: IORef (Maybe FilePath) -> IORef (Maybe ProcessGroup) -> TuiConfig -> PrivateRoot -> LaunchPreview -> TBQueue Envelope -> IO () -> (MachineExit -> IO ()) -> IO RunningMachine
prepareAndStart partialDirectory partialProcess config root preview events notifyFrame notifyExit = do
  when (maybe False ((== RootRun) . fst) (previewLineage preview)) $
    ioError (userError "root lineage cannot use a parent run")
  let revalidateParent = case previewLineage preview of
        Nothing -> pure ()
        Just (_, record) -> do
          components <- privatePathComponents root (recordDirectory record)
          withPrivateDirectoryAt root components (revalidateLineageParentAt record)
  revalidateParent
  targetArgs <- case previewLineage preview of
    Nothing -> either (ioError . userError . T.unpack) pure (targetArguments (previewTarget preview))
    Just (_, parentRecord) -> pure (map T.unpack (frontendTargetArgs (recordManifest parentRecord)))
  stamp <- getMonotonicTimeNSec
  pid <- getProcessID
  runId <- either (ioError . userError . T.unpack) pure (mkRunId ("tui-" <> T.pack (show pid) <> "-" <> T.pack (show stamp)))
  now <- T.pack . formatTime defaultTimeLocale "%FT%T%QZ" <$> getCurrentTime
  let runDirectory = tuiStateDir config </> "runs" </> T.unpack (runIdText runId)
      inputDirectory = runDirectory </> "inputs"
      runtimeDirectory = runDirectory </> "runtime"
      ownerId = "tui:" <> T.pack (show pid) <> ":" <> runIdText runId
  ensurePrivateDirectoryAt root ["runs"]
  createPrivateDirectoryAt root ["runs", T.unpack (runIdText runId)]
  writeIORef partialDirectory (Just runDirectory)
  createPrivateDirectoryAt root ["runs", T.unpack (runIdText runId), "inputs"]
  inputFiles <- writeInputs root runId inputDirectory (previewDescriptor preview) (previewInputs preview)
  let inputHashes = Map.fromList [(name, sha256 (TE.encodeUtf8 value)) | (name, value) <- Map.toList (previewInputs preview)]
      parentManifest = recordManifest . snd <$> previewLineage preview
      persona = case parentManifest of
        Just parent -> frontendPersona parent
        Nothing -> case previewTarget preview of
          TargetScripted -> Nothing
          TargetRestored _ _ -> frontendPersona =<< parentManifest
          TargetRouting selected _ _ -> Just selected
      targetKind = case parentManifest of
        Just parent -> frontendTargetKind parent
        Nothing -> case previewTarget preview of
          TargetScripted -> "scripted"
          TargetRestored kind _ -> kind
          TargetRouting {} -> "routing"
      parentRunId = frontendRunId <$> parentManifest
      lineage = lineageOperationText . fst <$> previewLineage preview
      launchCwd = maybe (tuiWorkingDir config) frontendCwd parentManifest
      invocation = case previewLineage preview of
        Nothing -> ["machine", T.unpack (runIdText runId), T.unpack (workflowName (previewDescriptor preview))]
        Just (operation, parentRecord) ->
          [ lineageCommand operation,
            T.unpack (runIdText runId),
            recordDirectory parentRecord </> frontendRuntimeStore (recordManifest parentRecord),
            T.unpack (workflowName (previewDescriptor preview))
          ]
      manifest =
        FrontendManifest
          { frontendVersion = frontendManifestVersion,
            frontendRunId = runId,
            frontendRunnerId = tuiRunnerId config,
            frontendRunnerExecutable = Just (tuiRunner config),
            frontendRunnerVersion = Just (workflowRunnerVersion (previewDescriptor preview)),
            frontendWorkflow = workflowName (previewDescriptor preview),
            frontendCwd = launchCwd,
            frontendTargetKind = targetKind,
            frontendTargetArgs = map T.pack targetArgs,
            frontendInputHashes = inputHashes,
            frontendProgramHash = previewProgramHash preview,
            frontendCreatedAt = now,
            frontendParentRunId = parentRunId,
            frontendLineage = lineage,
            frontendLineageEdits = [],
            frontendPersona = persona,
            frontendPolicyDigest = parentManifest >>= frontendPolicyDigest,
            frontendPersonAnswering = Just PersonAnswerLocalControl,
            frontendOwnerId = Just ownerId,
            frontendRuntimeStore = "runtime"
          }
  writePrivateAtomicAt root ["runs", T.unpack (runIdText runId), "supervisor-manifest.json"] (BL.toStrict (encode manifest <> "\n"))
  writePrivateAtomicAt root ["runs", T.unpack (runIdText runId), "owner.json"] (ownerLeaseBytes ownerId pid now)
  environment <- childEnvironment root runtimeDirectory ownerId
  let arguments =
        invocation
          <> targetArgs
          <> ["--protocol-version", "2", "--person-answering", "local-control"]
          <> concatMap (\(name, path) -> ["--input-file", T.unpack name <> "=" <> path]) inputFiles
  assertPrivateRoot root
  let command =
        (proc (tuiRunner config) (tuiRunnerArgs config <> arguments))
          { cwd = Just launchCwd,
            env = Just environment,
            std_in = CreatePipe,
            std_out = CreatePipe,
            std_err = CreatePipe
          }
  childGroup <- mask_ $ do
    revalidateParent
    group <- createProcessGroup command
    writeIORef partialProcess (Just group)
    pure group
  control <- maybe (ioError (userError "machine child has no control pipe")) pure (groupInput childGroup)
  output <- maybe (ioError (userError "machine child has no stdout pipe")) pure (groupOutput childGroup)
  errors <- maybe (ioError (userError "machine child has no stderr pipe")) pure (groupErrors childGroup)
  let exitState = groupOutcome childGroup
  failureState <- newEmptyMVar
  diagnosticState <- newEmptyMVar
  readerDone <- newEmptyMVar
  diagnosticHandle <- openPrivateFileAt root ["runs", T.unpack (runIdText runId), "stderr.log"]
  heartbeat <- forkIO (heartbeatOwner root runId ownerId pid exitState (reportFailure failureState notifyExit))
  reader <- forkIO (readEvents output events notifyFrame (reportFailure failureState notifyExit) `finally` (closeQuietly output >> putMVar readerDone ()))
  errorReader <- forkIO $ do
    outcome <- try @SomeException (spoolErrors diagnosticHandle errors `finally` closeQuietly errors)
    putMVar diagnosticState (either (const False) id outcome)
  waiter <- forkIO $ do
    status <- readMVar exitState
    closeQuietly control
    takeMVar readerDone
    hadDiagnostics <- takeMVar diagnosticState
    let diagnostic = if hadDiagnostics then "runner diagnostics were redacted into private stderr.log" else ""
    case status of
      Left failure -> reportFailure failureState notifyExit (MachineProtocolFailed (T.pack (displayException failure)))
      Right code -> notifyExit (MachineExited code diagnostic)
  pure
    RunningMachine
      { runningRunId = runId,
        runningDirectory = runDirectory,
        runningPid = groupPid childGroup,
        runningGroup = childGroup,
        runningControl = control,
        runningStdout = output,
        runningStderr = errors,
        runningReaderThread = reader,
        runningErrorThread = errorReader,
        runningWaiterThread = waiter,
        runningHeartbeatThread = heartbeat,
        runningExit = exitState,
        runningFailure = failureState
      }


readEvents :: Handle -> TBQueue Envelope -> IO () -> (MachineExit -> IO ()) -> IO ()
readEvents handle queue notify finishWith = loop BS.empty
  where
    loop buffered = do
      chunkResult <- try @SomeException (BS.hGetSome handle 32768)
      case chunkResult of
        Left failure -> finishWith (MachineProtocolFailed (T.pack (displayException failure)))
        Right chunk
          | BS.null chunk -> when (not (BS.null buffered)) (finishWith (MachineProtocolFailed "machine stream ended without a terminating newline"))
          | otherwise -> feed (buffered <> chunk)
    feed bytes = case BS.break (== 10) bytes of
      (line, rest)
        | BS.null rest ->
            if BS.length line > maxFrameBytes
              then finishWith frameTooLarge
              else loop line
        | BS.length line > maxFrameBytes -> finishWith frameTooLarge
        | otherwise -> do
            valid <- consume line
            when valid (feed (BS.drop 1 rest))
    consume line
      | BS.null line = finishWith (MachineProtocolFailed "machine emitted an empty protocol frame") >> pure False
      | otherwise = case decodeEnvelopeFor [2] line of
          Left failure -> finishWith (MachineProtocolFailed ("machine protocol decode failed: " <> failure)) >> pure False
          Right envelope -> atomically (writeTBQueue queue envelope) >> notify >> pure True
    frameTooLarge = MachineProtocolFailed "machine frame exceeds 1048576 bytes"

spoolErrors :: Handle -> Handle -> IO Bool
spoolErrors destination source = do
  let persist retained bytes = do
        let room = max 0 (10 * 1024 * 1024 - retained)
            kept = BS.take room bytes
        unless (BS.null kept) (BS.hPut destination kept >> hFlush destination)
        pure (retained + BS.length kept)
      loop retained sawBytes pending dropping = do
        chunk <- BS.hGetSome source 32768
        if BS.null chunk
          then
            if dropping || BS.null pending
              then pure sawBytes
              else persist retained (sanitizeDiagnosticLine pending) >> pure True
          else feed retained True pending dropping chunk
      feed retained sawBytes pending dropping bytes
        | dropping = case BS.break (== 10) bytes of
            (_, rest)
              | BS.null rest -> loop retained sawBytes BS.empty True
              | otherwise -> feed retained sawBytes BS.empty False (BS.drop 1 rest)
        | otherwise =
            let combined = pending <> bytes
             in case BS.break (== 10) combined of
                  (line, rest)
                    | BS.length line > maxDiagnosticLineBytes -> do
                        retained' <- persist retained "<redacted overlong diagnostic>\n"
                        if BS.null rest
                          then loop retained' True BS.empty True
                          else feed retained' True BS.empty False (BS.drop 1 rest)
                    | BS.null rest -> loop retained sawBytes line False
                    | otherwise -> do
                        retained' <- persist retained (sanitizeDiagnosticLine line <> "\n")
                        feed retained' sawBytes BS.empty False (BS.drop 1 rest)
  loop 0 False BS.empty False `finally` hClose destination

maxDiagnosticLineBytes :: Int
maxDiagnosticLineBytes = 64 * 1024

sanitizeDiagnosticLine :: BS.ByteString -> BS.ByteString
sanitizeDiagnosticLine bytes =
  let line = TE.decodeUtf8With lenientDecode bytes
      lower = T.toLower line
   in if any (`T.isInfixOf` lower) ["authorization", "bearer ", "api_key", "api-key", "token=", "password="]
        then "<redacted diagnostic>"
        else TE.encodeUtf8 line

sendMachineControl :: RunningMachine -> Control -> IO (Either Text ())
sendMachineControl running control = case encodeControlFor 2 control of
  Left failure -> pure (Left failure)
  Right bytes -> do
    result <- try @SomeException $ do
      BS.hPut (runningControl running) bytes
      BS.hPut (runningControl running) "\n"
      hFlush (runningControl running)
    case result of
      Left failure | Just _ <- fromException @SomeAsyncException failure -> throwIO failure
      _ -> pure (either (Left . T.pack . displayException) (const (Right ())) result)

terminateMachine :: RunningMachine -> IO ()
terminateMachine = terminateProcessGroup 5000000 . runningGroup

terminatePartialProcess :: ProcessGroup -> IO ()
terminatePartialProcess group = terminateProcessGroup 2000000 group `finally` closeGroupPipes group

reportFailure :: MVar MachineExit -> (MachineExit -> IO ()) -> MachineExit -> IO ()
reportFailure state notify value = do
  inserted <- tryPutMVar state value
  when inserted (notify value)

heartbeatOwner :: PrivateRoot -> RunId -> Text -> ProcessID -> MVar (Either IOException ExitCode) -> (MachineExit -> IO ()) -> IO ()
heartbeatOwner root runId owner pid state failOwner = do
  threadDelay 2000000
  exited <- tryReadMVar state
  case exited of
    Just _ -> pure ()
    Nothing -> do
      outcome <- try @SomeException $ do
        now <- timestamp
        writePrivateAtomicAt root ["runs", T.unpack (runIdText runId), "owner.json"] (ownerLeaseBytes owner pid now)
      case outcome of
        Left failure -> failOwner (MachineProtocolFailed ("owner heartbeat failed: " <> T.pack (displayException failure)))
        Right () -> heartbeatOwner root runId owner pid state failOwner

ownerLeaseBytes :: Text -> ProcessID -> Text -> BS.ByteString
ownerLeaseBytes owner pid heartbeat =
  BL.toStrict
    ( encode
        ( object
            [ "version" .= (1 :: Int),
              "ownerId" .= owner,
              "pid" .= (fromIntegral pid :: Integer),
              "heartbeat" .= heartbeat
            ]
        )
        <> "\n"
    )

timestamp :: IO Text
timestamp = T.pack . formatTime defaultTimeLocale "%FT%T%QZ" <$> getCurrentTime

lineageCommand :: LineageOperation -> String
lineageCommand RootRun = "machine"
lineageCommand RestartRun = "machine-restart"
lineageCommand ResumeRun = "machine-resume"
lineageCommand ForkRun = "machine-fork"

lineageOperationText :: LineageOperation -> Text
lineageOperationText RootRun = "root"
lineageOperationText RestartRun = "restart"
lineageOperationText ResumeRun = "resume"
lineageOperationText ForkRun = "fork"

writeInputs :: PrivateRoot -> RunId -> FilePath -> WorkflowDescriptor -> Map Text Text -> IO [(Text, FilePath)]
writeInputs root runId directory descriptor values =
  traverse writeOne (zip [0 :: Int ..] (workflowInputs descriptor))
  where
    writeOne (index, input) = do
      value <- maybe (ioError (userError ("missing input " <> T.unpack (workflowInputName input)))) pure (Map.lookup (workflowInputName input) values)
      let file = show index <> ".txt"
          path = directory </> file
      writePrivateExclusiveAt root ["runs", T.unpack (runIdText runId), "inputs", file] (TE.encodeUtf8 value)
      pure (workflowInputName input, path)

childEnvironment :: PrivateRoot -> FilePath -> Text -> IO [(String, String)]
childEnvironment root runtime owner = do
  ambient <- getEnvironment
  let updates =
        [ ("AGENT_CAT_RUN_STORE", runtime),
          ("AGENT_CAT_STATE_ANCHOR", privateRootIdentity root),
          ("AGENT_CAT_RUN_OWNER", T.unpack owner),
          ("AGENT_CAT_CONTROL_FD", "3"),
          ("AGENT_CAT_TUI_BOOTSTRAP_FD3", "1")
        ]
      reserved name = name `elem` map fst updates || name == "AGENT_CAT_CONTROL_STDIN"
  pure (updates <> filter (not . reserved . fst) ambient)

removePartialDirectory :: PrivateRoot -> FilePath -> IO ()
removePartialDirectory root path = do
  let name = takeFileName path
  _ <- try @SomeException (movePrivateAt root ["runs", name] [".failed-" <> name])
  pure ()

closeQuietly :: Handle -> IO ()
closeQuietly handle = do
  _ <- try @SomeException (hClose handle)
  pure ()

sha256 :: BS.ByteString -> Text
sha256 bytes = T.pack (show (hash bytes :: Digest SHA256))


