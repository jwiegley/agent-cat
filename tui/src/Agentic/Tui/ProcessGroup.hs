{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE TypeApplications #-}

-- | POSIX groups whose leader remains waitable through group signalling.
module Agentic.Tui.ProcessGroup
  ( ProcessGroup,
    groupPid,
    groupInput,
    groupOutput,
    groupErrors,
    groupOutcome,
    createProcessGroup,
    waitProcessGroup,
    terminateProcessGroup,
    closeGroupPipes,
  )
where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (MVar, newEmptyMVar, newMVar, putMVar, readMVar, tryReadMVar, withMVar)
import Control.Exception (IOException, finally, mask_, throwIO, try, uninterruptibleMask_)
import Control.Monad (void)
import Foreign.C.Error (throwErrnoIfMinus1Retry)
import Foreign.C.Types (CInt (..))
import System.Exit (ExitCode)
import System.IO (Handle, hClose)
import System.Posix.Signals (Signal, sigKILL, sigTERM)
import System.Posix.Types (ProcessID)
import System.Process (CreateProcess (close_fds, new_session), ProcessHandle, createProcess, getPid, waitForProcess)
import System.Timeout (timeout)

-- | Sole authority to signal a process group and reap its original leader.
data ProcessGroup = ProcessGroup
  { groupPid :: !ProcessID,
    groupInput :: !(Maybe Handle),
    groupOutput :: !(Maybe Handle),
    groupErrors :: !(Maybe Handle),
    groupOutcome :: !(MVar (Either IOException ExitCode)),
    groupLock :: !(MVar ())
  }

createProcessGroup :: CreateProcess -> IO ProcessGroup
createProcessGroup command = mask_ $ do
  outcome <- newEmptyMVar
  lock <- newMVar ()
  (input, output, errors, process) <- createProcess command {close_fds = True, new_session = True}
  pid <- getPid process >>= maybe (ioError (userError "created process has no PID")) pure
  let group = ProcessGroup pid input output errors outcome lock
  _ <- forkIO (monitorGroup group process)
  pure group

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

terminateProcessGroup :: Int -> ProcessGroup -> IO ()
terminateProcessGroup grace group =
  (signalOwned sigTERM >> void (timeout grace (readMVar (groupOutcome group))))
    `finally` uninterruptibleMask_ (signalOwned sigKILL >> void (readMVar (groupOutcome group)))
  where
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

foreign import ccall unsafe "agentic_child_exited"
  childExited :: CInt -> IO CInt

foreign import ccall unsafe "agentic_signal_group"
  signalGroupNative :: CInt -> CInt -> IO CInt
