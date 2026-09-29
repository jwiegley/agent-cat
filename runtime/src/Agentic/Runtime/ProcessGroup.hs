{-# LANGUAGE CPP #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE TypeApplications #-}

-- | POSIX groups whose leader remains waitable through group signalling.
module Agentic.Runtime.ProcessGroup
  ( ProcessGroup,
    groupPid,
    groupInput,
    groupOutput,
    groupErrors,
    groupOutcome,
    createProcessGroup,
    waitProcessGroup,
    processGroupLive,
    terminateProcessGroup,
    closeGroupPipes,
  )
where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.Async (asyncWithUnmask, waitCatch)
import Control.Concurrent.MVar (MVar, newEmptyMVar, newMVar, putMVar, readMVar, tryReadMVar, tryTakeMVar, withMVar)
import Control.Exception (IOException, SomeException, fromException, mask, mask_, finally, throwIO, try, uninterruptibleMask_)
import Control.Monad (void)
import Foreign.C.Error (throwErrnoIfMinus1Retry)
import Foreign.C.Types (CInt (..))
import System.Exit (ExitCode)
import System.IO (Handle, hClose)
import System.Posix.Signals (Signal, sigKILL, sigTERM)
import System.Posix.Types (ProcessID)
import System.Process (CreateProcess, ProcessHandle, getPid, waitForProcess)
import System.Timeout (timeout)
#if defined(darwin_HOST_OS)
import Control.Monad (when)
import Foreign.C.Error (throwErrno)
import Foreign.C.String (CString, peekCString, withCString)
import Foreign.Marshal (alloca, allocaArray, maybeWith, withArray, withArray0, withMany)
import Foreign.Ptr (Ptr, nullPtr)
import Foreign.Storable (peek, peekElemOff)
import GHC.IO.Device (IODeviceType (Stream))
import GHC.IO.Encoding (getLocaleEncoding)
import qualified GHC.IO.FD as FD
import GHC.IO.Handle.FD (mkHandleFromFD)
import System.IO (IOMode (ReadMode, WriteMode))
import System.IO.Error (illegalOperationErrorType, ioeSetErrorString, mkIOError)
import System.Posix.Internals (withFilePath)
import System.Process (CmdSpec (RawCommand, ShellCommand), StdStream (CreatePipe, Inherit, NoStream, UseHandle))
import qualified System.Process as Process
import System.Process.Internals (mkProcessHandle, runInteractiveProcess_lock, withCEnvironment, withFilePathException)
#else
import System.Process (CreateProcess (close_fds, new_session), createProcess)
#endif

-- | Sole authority to signal a process group and reap its original leader.
data ProcessGroup = ProcessGroup
  { groupPid :: !ProcessID,
    groupInput :: !(Maybe Handle),
    groupOutput :: !(Maybe Handle),
    groupErrors :: !(Maybe Handle),
    groupOutcome :: !(MVar (Either IOException ExitCode)),
    groupLock :: !(MVar ())
  }

-- | Start a command as the leader of a new session and process group. The
-- child receives only the standard descriptors that its stream modes name,
-- whatever other descriptors the parent holds. An exec failure raises an
-- 'IOException' from this call, and no child is left for the caller to own
-- or reap.
createProcessGroup :: CreateProcess -> IO ProcessGroup
createProcessGroup command = mask_ $ do
  outcome <- newEmptyMVar
  lock <- newMVar ()
  (input, output, errors, process) <- spawnSession command
  pid <- getPid process >>= maybe (ioError (userError "created process has no PID")) pure
  let group = ProcessGroup pid input output errors outcome lock
  _ <- forkIO (monitorGroup group process)
  pure group

-- | The spawn itself. On macOS the process library honours @close_fds@ only
-- through a fork whose child closes every descriptor up to the soft
-- @RLIMIT_NOFILE@, so each spawn costs time in proportion to that limit. The
-- Apple path therefore spawns through @agentic_spawn_session@ in
-- @runtime/cbits/process_spawn.c@, which uses @posix_spawn@ with
-- @POSIX_SPAWN_CLOEXEC_DEFAULT@ and @POSIX_SPAWN_SETSID@. It keeps the argv,
-- working directory, environment, executable resolution, standard stream
-- modes and pipe handles of the process-library fork path, with one
-- difference. When the parent holds descriptors 0 and 1 closed and the command
-- has no standard input, an inherited standard output and a piped standard
-- error, process-1.6.26.1 raises @close(parent_end)@ with @EBADF@. The helper
-- spawns the child and leaves its descriptor 1 closed. An exec failure
-- raises an 'IOException' with that path's error type, errno, file name and
-- description. Its location text names the failed step of this helper, such
-- as @createProcess: posix_spawn@, and not @execve@, @execvp@ or @chdir@,
-- because @posix_spawn@ does not tell a failed working directory from a failed
-- exec. It refuses 'UseHandle' streams, @create_group@, @delegate_ctlc@,
-- @child_group@ and @child_user@, which no caller uses. Other platforms keep
-- the process-library spawn.
spawnSession :: CreateProcess -> IO (Maybe Handle, Maybe Handle, Maybe Handle, ProcessHandle)
#if defined(darwin_HOST_OS)
spawnSession command = do
  refuse "create_group" (Process.create_group command)
  refuse "delegate_ctlc" (Process.delegate_ctlc command)
  refuse "child_group" (Process.child_group command /= Nothing)
  refuse "child_user" (Process.child_user command /= Nothing)
  modes <- sequence [streamMode (Process.std_in command) 0, streamMode (Process.std_out command) 1, streamMode (Process.std_err command) 2]
  let (executable, arguments) = case Process.cmdspec command of
        ShellCommand text -> ("/bin/sh", ["-c", text])
        RawCommand name values -> (name, values)
  withFilePathException executable $
    maybeWith withCEnvironment (Process.env command) $ \environment ->
      maybeWith withFilePath (Process.cwd command) $ \directory ->
        withFilePath executable $ \program ->
          withMany withCString arguments $ \values ->
            withArray0 nullPtr (program : values) $ \argv ->
              withArray modes $ \streams ->
                allocaArray 3 $ \ends ->
                  alloca $ \failure -> do
                    -- The lock excludes a process-library spawn while the new
                    -- pipes lack FD_CLOEXEC.
                    pid <- withMVar runInteractiveProcess_lock $ \_ ->
                      spawnSessionNative argv directory environment streams ends failure
                    when (pid == -1) $ do
                      step <- peek failure >>= peekCString
                      throwErrno ("createProcess: " <> step)
                    input <- pipeHandle (Process.std_in command) ends 0 WriteMode
                    output <- pipeHandle (Process.std_out command) ends 1 ReadMode
                    errors <- pipeHandle (Process.std_err command) ends 2 ReadMode
                    process <- mkProcessHandle (fromIntegral pid) False
                    pure (input, output, errors, process)
  where
    refuse field present = when present $
      ioError (ioeSetErrorString (mkIOError illegalOperationErrorType "createProcessGroup" Nothing Nothing)
        (field <> " is not supported by the session spawn"))
    streamMode stream standard = case stream of
      CreatePipe -> pure (-1)
      NoStream -> pure (-2)
      Inherit -> pure standard
      UseHandle _ -> refuse "UseHandle" True >> pure (-2)
    -- The same Handle that the process library makes for a created pipe. The
    -- helper has already made the parent end nonblocking, so building the
    -- Handle makes no system call and raises no I/O error once the child exists.
    pipeHandle CreatePipe ends index mode = do
      descriptor <- peekElemOff ends index
      (device, kind) <- FD.mkFD descriptor mode (Just (Stream, 0, 0)) False True
      encoding <- getLocaleEncoding
      Just <$> mkHandleFromFD device kind ("fd:" <> show descriptor) mode False (Just encoding)
    pipeHandle _ _ _ _ = pure Nothing
#else
spawnSession command = createProcess command {close_fds = True, new_session = True}
#endif

monitorGroup :: ProcessGroup -> ProcessHandle -> IO ()
monitorGroup group process = do
  observed <- try @IOException (awaitExit (groupPid group))
  withMVar (groupLock group) $ \_ -> do
    result <- case observed of
      Left failure -> pure (Left failure)
      Right () -> do
        signalled <- try @IOException (signalGroup sigKILL (groupPid group))
        reaped <- try @IOException (waitForProcess process)
        pure (signalled >> reaped)
    putMVar (groupOutcome group) result

awaitExit :: ProcessID -> IO ()
awaitExit pid = do
  ready <- throwErrnoIfMinus1Retry "waitid(WNOWAIT)" (childExited (fromIntegral pid))
  if ready /= 0 then pure () else threadDelay 10000 >> awaitExit pid

waitProcessGroup :: ProcessGroup -> IO ExitCode
waitProcessGroup group = readMVar (groupOutcome group) >>= either throwIO pure

-- | A nonblocking liveness observation through the original unreaped leader token.
-- Later process death is not excluded, and no ownership is created by this result.
processGroupLive :: ProcessGroup -> IO Bool
processGroupLive group = mask_ $ do
  lock <- tryTakeMVar(groupLock group)
  case lock of
    Nothing -> pure False
    Just () -> (do
      outcome <- tryReadMVar(groupOutcome group)
      case outcome of
        Just _ -> pure False
        Nothing -> (==0) <$> throwErrnoIfMinus1Retry "observe owned process" (childExited(fromIntegral(groupPid group))))
      `finally` putMVar(groupLock group)()

terminateProcessGroup :: Int -> ProcessGroup -> IO ()
terminateProcessGroup grace group = mask $ \restore -> do
  -- Caller cancellation must not kill a proxy before its owned children get their grace.
  shutdown <- asyncWithUnmask (\unmask -> unmask terminate)
  caller <- try @SomeException (restore (waitCatch shutdown))
  joined <- uninterruptibleMask_ (waitCatch shutdown)
  case caller of
    Left failure -> throwIO failure
    Right _ -> either throwIO pure joined

  where
    terminate = mask $ \restore -> do
      earlier <- try @SomeException $ restore $ do
        signalled <- try @IOException (signalOwned sigTERM)
        -- Refused TERM does not exclude completion during the existing grace.
        void (timeout grace (readMVar (groupOutcome group)))
        either throwIO pure signalled
      final <- try @SomeException $ uninterruptibleMask_ $ do
        signalled <- try @IOException (signalOwned sigKILL)
        case signalled of
          Left failure -> do
            joinable <- try @IOException $ withMVar (groupLock group) $ \_ -> do
              published <- tryReadMVar (groupOutcome group)
              case published of
                Just _ -> pure True
                Nothing -> (/= 0) <$> throwErrnoIfMinus1Retry "observe refused process group" (childExited (fromIntegral (groupPid group)))
            -- A refused signal is still a failure. Join only a published outcome
            -- or the original monitor of a positively observed dead leader.
            case joinable of
              Right True -> void (readMVar (groupOutcome group))
              _ -> pure ()
            throwIO failure
          Right () -> readMVar (groupOutcome group) >>= either throwIO (const (pure ()))
      case earlier of
        Left failure | Nothing <- (fromException failure :: Maybe IOException) -> throwIO failure
        _ -> either throwIO pure final
    signalOwned signal = withMVar (groupLock group) $ \_ -> do
      outcome <- tryReadMVar (groupOutcome group)
      case outcome of
        Nothing -> signalGroup signal (groupPid group)
        Just _ -> pure ()

signalGroup :: Signal -> ProcessID -> IO ()
signalGroup signal pid = void $
  throwErrnoIfMinus1Retry "signal owned process group" (signalGroupNative (fromIntegral pid) (fromIntegral signal))

closeGroupPipes :: ProcessGroup -> IO ()
closeGroupPipes group = mapM_ (mapM_ close) [groupInput group, groupOutput group, groupErrors group]
  where
    close handle = void (try @IOException (hClose handle))

#if defined(darwin_HOST_OS)
-- A safe call, so a spawn never holds a capability.
foreign import ccall safe "agentic_spawn_session"
  spawnSessionNative :: Ptr CString -> CString -> Ptr CString -> Ptr CInt -> Ptr CInt -> Ptr CString -> IO CInt
#endif

foreign import ccall unsafe "agentic_child_exited"
  childExited :: CInt -> IO CInt

foreign import ccall unsafe "agentic_signal_group"
  signalGroupNative :: CInt -> CInt -> IO CInt
