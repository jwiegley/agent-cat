{-# LANGUAGE CPP #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE TypeApplications #-}

-- | Spawn contracts of 'createProcessGroup': inherited descriptors, closed
-- standard descriptors, nonblocking parent pipe ends, session leadership,
-- executable resolution, exec errors, the inherited owner lock and spawn cost.
module ProcessGroupTests (processGroupTests, spawnCostCheck, spawnCostProbe) where

import Agentic.Runtime (ProcessGroup, closeGroupPipes, createProcessGroup, groupErrors, groupInput, groupOutput, groupPid, terminateProcessGroup, waitProcessGroup)
#if defined(darwin_HOST_OS)
import Agentic.Runtime (lockPrivateDescriptor, processGroupLive, setInheritedOwnerLock)
#endif
import Control.Concurrent (threadDelay)
import Control.Exception (IOException, bracket, finally, try)
import Control.Monad (forM, forM_, unless)
import qualified Data.ByteString.Char8 as BC
import GHC.Clock (getMonotonicTimeNSec)
import GHC.IO.FD (FD (fdFD, fdIsNonBlocking))
import GHC.IO.Handle.FD (handleToFd)
import System.Directory (canonicalizePath, createDirectory, getTemporaryDirectory, removePathForcibly)
import System.Environment (getExecutablePath, lookupEnv, setEnv, unsetEnv)
import System.Exit (ExitCode (..), exitFailure)
import System.FilePath ((</>))
import System.IO (hClose, hFlush, hPutStrLn, stderr, stdout)
import System.Posix.Files (setFileMode)
import System.Posix.IO (FdOption (CloseOnExec, NonBlockingRead), OpenMode (ReadOnly), closeFd, defaultFileFlags, dup, dupTo, openFd, queryFdOption)
import System.Posix.Process (getProcessGroupIDOf, getProcessID)
import System.Posix.Resource (Resource (ResourceOpenFiles), ResourceLimit (ResourceLimit), ResourceLimits (..), getResourceLimit, setResourceLimit)
import System.Posix.Temp (mkdtemp)
import System.Posix.Types (CPid (..), Fd (..), ProcessID)
import System.Process (CreateProcess (..), StdStream (..), proc)
#if defined(darwin_HOST_OS)
import Data.Int (Int32)
import Data.List (sort, (\\))
import Data.Word (Word64)
import Foreign.C.Error (Errno (Errno), eWOULDBLOCK, throwErrno)
import Foreign.C.Types (CInt (..))
import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.Marshal.Array (allocaArray, peekArray)
import Foreign.Ptr (Ptr)
import Foreign.Storable (peekByteOff)
import GHC.IO.Exception (IOErrorType (..), IOException (ioe_errno, ioe_filename, ioe_type))
import System.Posix.IO (OpenFileFlags (cloexec, creat, exclusive), OpenMode (WriteOnly))
#else
import Data.List (sort)
import System.Directory (listDirectory)
#endif

foreign import ccall unsafe "getsid"
  getSessionOf :: CPid -> IO CPid

#if defined(darwin_HOST_OS)
foreign import ccall unsafe "proc_pidinfo"
  procPidInfo :: CInt -> CInt -> Word64 -> Ptr () -> CInt -> IO CInt

-- | The open descriptors of another process, from @PROC_PIDLISTFDS@. Each
-- @struct proc_fdinfo@ record holds a 32-bit descriptor and a 32-bit type.
openDescriptors :: ProcessID -> IO [Int]
openDescriptors pid = allocaBytes bytes $ \buffer -> do
  used <- procPidInfo (fromIntegral pid) 1 0 buffer (fromIntegral bytes)
  unless (used > 0) (throwErrno "proc_pidinfo(PROC_PIDLISTFDS)")
  fmap sort $ forM [0 .. fromIntegral used `div` 8 - 1] $ \index ->
    fromIntegral <$> (peekByteOff buffer (index * 8) :: IO Int32)
  where
    bytes = 8 * 4096

foreign import ccall unsafe "proc_listchildpids"
  procListChildPids :: CInt -> Ptr CPid -> CInt -> IO CInt

-- | The children of this process, zombies included, from @proc_listchildpids@.
childProcesses :: IO [ProcessID]
childProcesses = do
  self <- getProcessID
  allocaArray capacity $ \buffer -> do
    count <- procListChildPids (fromIntegral self) buffer (fromIntegral (capacity * 4))
    unless (count >= 0) (throwErrno "proc_listchildpids")
    sort <$> peekArray (fromIntegral count) buffer
  where
    capacity = 4096 :: Int
#else
-- | The open descriptors of another process, from @/proc@.
openDescriptors :: ProcessID -> IO [Int]
openDescriptors pid = sort . map read <$> listDirectory ("/proc/" <> show pid <> "/fd")
#endif

-- | The soft descriptor limit of the spawn-cost check. It is the soft
-- @RLIMIT_NOFILE@ of the validation host, and the check refuses to run on a
-- host that does not allow it.
highDescriptorLimit :: Integer
highDescriptorLimit = 1048576

-- | The number of spawns that the spawn-cost check times.
timedSpawns :: Int
timedSpawns = 64

-- | The bound on the time that 'timedSpawns' spawns spend inside
-- 'createProcessGroup' at 'highDescriptorLimit'. A spawn that closes every
-- descriptor up to the limit costs about 100 ms at that limit, which is more
-- than six seconds for the whole check. A @posix_spawn@ costs about one
-- millisecond, which is about 0.1 s for the whole check.
spawnBudgetNs :: Integer
spawnBudgetNs = 1000000000

processGroupTests :: IO ()
processGroupTests = do
  descriptorCheck
  nonblockingCheck
  closedStandardChecks
  sessionCheck
  base <- getTemporaryDirectory
  bracket (mkdtemp (base </> "process-group-")) removePathForcibly $ \work -> do
    directory <- canonicalizePath work
    resolutionChecks directory
    execErrorChecks directory
#if defined(darwin_HOST_OS)
    ownerLockCheck directory
#endif
  spawnCostCheck
  putStrLn ("PASS process group: stdio-only descriptors, nonblocking parent pipe ends, closed standard descriptors, session leader, execvp and find_executable resolution, exec error class/errno/file, inherited owner lock, spawn cost below one second for " <> show timedSpawns <> " spawns at soft RLIMIT_NOFILE " <> show highDescriptorLimit)

expect :: String -> Bool -> IO ()
expect label condition = unless condition $ do
  hPutStrLn stderr ("FAIL " <> label)
  exitFailure

-- | Run a command to completion and return its exit status and standard
-- output. The feed action runs first, for a command that reads input.
capture :: CreateProcess -> (ProcessGroup -> IO ()) -> IO (ExitCode, BC.ByteString)
capture command feed =
  bracket (createProcessGroup command) (\group -> terminateProcessGroup 2000000 group `finally` closeGroupPipes group) $ \group -> do
    feed group
    output <- maybe (ioError (userError "process group test: no stdout pipe")) pure (groupOutput group)
    bytes <- BC.hGetContents output
    status <- waitProcessGroup group
    pure (status, bytes)

piped :: CreateProcess -> CreateProcess
piped command = command {std_in = CreatePipe, std_out = CreatePipe, std_err = CreatePipe}

-- | Two descriptors without FD_CLOEXEC, one low and one high, must not reach
-- the child. The parent reads the descriptor table of a sleeping child until
-- it holds only the three standard descriptors, for at most five seconds, so
-- that files which the dynamic loader opens and closes during exec cannot
-- decide the result.
descriptorCheck :: IO ()
descriptorCheck =
  bracket (openFd "/dev/null" ReadOnly defaultFileFlags) closeFd $ \low ->
    bracket (dupTo low (Fd 900)) closeFd $ \high ->
      bracket (createProcessGroup (piped (proc "/bin/sleep" ["30"]))) (\group -> terminateProcessGroup 2000000 group `finally` closeGroupPipes group) $ \group -> do
        let settle :: Int -> IO [Int]
            settle remaining = do
              held <- openDescriptors (groupPid group)
              if held == [0, 1, 2] || remaining <= 0 then pure held else threadDelay 10000 >> settle (remaining - 1)
        held <- settle 500
        unless (held == [0, 1, 2]) $
          hPutStrLn stderr ("     child descriptors: " <> unwords (map show held) <> "; parent held " <> show low <> " and " <> show high)
        expect "spawned child holds only the descriptors its stdio file actions name" (held == [0, 1, 2])

-- | Each parent pipe end is nonblocking in the kernel, as its Handle declares,
-- so that a read or a write waits in the I/O manager and never blocks a
-- capability.
nonblockingCheck :: IO ()
nonblockingCheck =
  bracket (createProcessGroup (piped (proc "/bin/sleep" ["30"]))) (\group -> terminateProcessGroup 2000000 group `finally` closeGroupPipes group) $ \group ->
    forM_ [("input", groupInput group), ("output", groupOutput group), ("error", groupErrors group)] $ \(name, end) -> do
      handle <- maybe (ioError (userError ("process group test: no " <> name <> " pipe"))) pure end
      descriptor <- handleToFd handle
      kernel <- queryFdOption (Fd (fdFD descriptor)) NonBlockingRead
      expect ("parent " <> name <> " pipe end is nonblocking in the kernel") kernel
      expect ("parent " <> name <> " pipe Handle declares a nonblocking descriptor") (fdIsNonBlocking descriptor /= 0)

-- | Read the descriptor table of a child until it equals the expected set, for
-- at most five seconds, and report what it held.
settledDescriptors :: ProcessID -> [Int] -> IO [Int]
settledDescriptors pid wanted = go (500 :: Int)
  where
    go remaining = do
      held <- openDescriptors pid
      if held == wanted || remaining <= 0 then pure held else threadDelay 10000 >> go (remaining - 1)

-- | Close the given standard descriptors of this process for the duration of
-- the action, and restore each one that was open. Nothing may print to a
-- closed descriptor meanwhile, so standard output is flushed first.
withClosedStandard :: [Fd] -> IO a -> IO a
withClosedStandard descriptors action = do
  hFlush stdout
  bracket save (mapM_ restore) (const action)
  where
    -- Every copy is made before any close, so that no copy takes the number
    -- of a descriptor that this action needs closed.
    save = do
      saved <- forM descriptors $ \descriptor -> (,) descriptor <$> try @IOException (dup descriptor)
      mapM_ (\(descriptor, copy) -> either (const (pure ())) (const (closeFd descriptor)) copy) saved
      pure saved
    restore (descriptor, saved) = case saved of
      Right copy -> dupTo copy descriptor >> closeFd copy
      Left _ -> pure ()

-- | A standard descriptor that the parent holds closed is the lowest free
-- descriptor, so a new pipe end takes its number. A pipe end that lands on its
-- own target still reaches the child. A closed descriptor that a stream
-- inherits stays closed in the child, even when a pipe end for another stream
-- has taken its number in the parent. The process-1.6.26.1 fork path refuses
-- that second case with an exec error from @close(parent_end)@, because its
-- 'NoStream' step closes descriptor 0, which holds the parent end of the error
-- pipe, before the error stream is set up.
closedStandardChecks :: IO ()
closedStandardChecks = do
  echoed <- withClosedStandard [Fd 0] $ do
    free <- try @IOException (queryFdOption (Fd 0) CloseOnExec)
    expect "closed standard input: descriptor 0 is free before the spawn" (either (const True) (const False) free)
    capture (proc "/bin/cat" []) {std_in = CreatePipe, std_out = CreatePipe, std_err = NoStream} $ \group ->
      maybe (ioError (userError "process group test: no stdin pipe")) (\input -> BC.hPut input (BC.pack "closed standard input\n") >> hClose input) (groupInput group)
  expect "closed standard input: a pipe end on descriptor 0 reaches the child as its standard input"
    (echoed == (ExitSuccess, BC.pack "closed standard input\n"))
  held <- withClosedStandard [Fd 0, Fd 1] $ do
    free <- forM [Fd 0, Fd 1] (try @IOException . flip queryFdOption CloseOnExec)
    expect "closed standard input and output: descriptors 0 and 1 are free before the spawn" (all (either (const True) (const False)) free)
    let command = (proc "/bin/sleep" ["30"]) {std_in = NoStream, std_out = Inherit, std_err = CreatePipe}
    bracket (createProcessGroup command) (\group -> terminateProcessGroup 2000000 group `finally` closeGroupPipes group) $ \group -> do
      expect "closed standard input and output: the error stream is a pipe" (groupErrors group /= Nothing)
      settledDescriptors (groupPid group) [2]
  unless (held == [2]) $
    hPutStrLn stderr ("     child descriptors: " <> unwords (map show held) <> "; expected 2 only")
  expect "closed standard output inherited by the child stays closed when an error pipe end takes its number" (held == [2])

-- | The child leads a new session and a new process group.
sessionCheck :: IO ()
sessionCheck = do
  parent <- getProcessID >>= getSessionOf
  let command = (proc "/bin/sleep" ["30"]) {std_in = NoStream, std_out = NoStream, std_err = NoStream}
  bracket (createProcessGroup command) (\group -> terminateProcessGroup 2000000 group `finally` closeGroupPipes group) $ \group -> do
    let pid = groupPid group
    session <- getSessionOf pid
    processGroup <- getProcessGroupIDOf pid
    expect "spawned child leads its own session" (session == pid && session /= parent)
    expect "spawned child leads its own process group" (processGroup == pid)

#if defined(darwin_HOST_OS)
-- | A lock descriptor that 'setInheritedOwnerLock' names reaches the session
-- leader as the same open file description. A fresh open of the lock file
-- cannot take the exclusive lock while the leader lives, after the parent has
-- closed its own descriptor, and can take it once the group has ended. The
-- setting is cleared before the parent descriptor closes, so that no later
-- spawn names a closed descriptor.
ownerLockCheck :: FilePath -> IO ()
ownerLockCheck directory = do
  let path = directory </> "owner.lock"
      command = (proc "/bin/sleep" ["30"]) {std_in = NoStream, std_out = NoStream, std_err = NoStream}
  parent <- openFd path WriteOnly defaultFileFlags {creat = Just 0o600, exclusive = True, cloexec = True}
  group <- (do
      lockPrivateDescriptor "owner lock check" parent
      setInheritedOwnerLock (Just parent)
      createProcessGroup command)
    `finally` (setInheritedOwnerLock Nothing >> closeFd parent)
  (do
      live <- processGroupLive group
      expect "owner lock check: the session leader lives" live
      held <- lockedElsewhere path
      expect "spawned session leader holds the inherited owner lock after the parent closes its descriptor" held)
    `finally` (terminateProcessGroup 2000000 group `finally` closeGroupPipes group)
  released <- lockedElsewhere path
  expect "inherited owner lock is free after the process group ends" (not released)
  where
    -- Only EWOULDBLOCK shows another holder. Any other failure is raised.
    lockedElsewhere path = bracket (openFd path ReadOnly defaultFileFlags {cloexec = True}) closeFd $ \fresh -> do
      taken <- try @IOException (lockPrivateDescriptor "owner lock probe" fresh)
      case taken of
        Right () -> pure False
        Left failure
          | fmap Errno (ioe_errno failure) == Just eWOULDBLOCK -> pure True
          | otherwise -> ioError failure
#endif

-- | The executable resolution of the process-library fork path. With an
-- explicit environment, @find_executable@ resolves the name and @execve@ runs
-- it without a shell fallback. Without one, @execvp@ runs it in the child
-- working directory, with the shell fallback for a file that is not an
-- executable image.
resolutionChecks :: FilePath -> IO ()
resolutionChecks directory = do
  createDirectory (directory </> "bin")
  script (directory </> "tool") "#!/bin/sh\necho \"tool ran in $(pwd -P)\"\n"
  script (directory </> "bin" </> "found") "#!/bin/sh\necho \"found ran in $(pwd -P)\"\n"
  script (directory </> "plain") "echo \"plain ran in $(pwd -P)\"\n"
  let explicit = Just [("PATH", "/usr/bin:/bin")]
      run name environment = capture (proc name []) {cwd = Just directory, env = environment, std_in = NoStream, std_out = CreatePipe, std_err = NoStream} (const (pure ()))
      ranIn label = (== (ExitSuccess, BC.pack (label <> " ran in " <> directory <> "\n")))
  run "./tool" explicit >>= expect "explicit environment: relative executable resolves in the child working directory" . ranIn "tool"
  run "./tool" Nothing >>= expect "inherited environment: relative executable resolves in the child working directory" . ranIn "tool"
  withPath "bin" (run "found" Nothing)
    >>= expect "inherited environment: a relative PATH entry resolves in the child working directory" . either (const False) (ranIn "found")
  run "./plain" Nothing >>= expect "inherited environment: a file without an image format runs through /bin/sh" . ranIn "plain"
  where
    script path text = writeFile path text >> setFileMode path 0o700
    withPath value action = bracket (lookupEnv "PATH") (maybe (unsetEnv "PATH") (setEnv "PATH")) $ \_ ->
      setEnv "PATH" value >> try @IOException action

-- | Each exec failure raises an 'IOException' with the error class, errno and
-- file name of the process-library fork path, and leaves no child for this
-- process to own or reap. The expected values are those that process-1.6.26.1
-- reports on macOS, the validated platform. An unresolved name under an
-- explicit environment keeps that library's errno of @-ENOENT@, which is not a
-- known error class. On macOS a failed @posix_spawn@ leaves a process that is
-- still listed as a child of the caller for a short time. The kernel removes
-- it without a wait by the caller, so the check allows five seconds for every
-- new child to disappear without a reap. Other platforms check only that each
-- failure raises an exec error.
execErrorChecks :: FilePath -> IO ()
#if defined(darwin_HOST_OS)
execErrorChecks directory = do
  writeFile (directory </> "noexec") "#!/bin/sh\n"
  setFileMode (directory </> "noexec") 0o600
  let explicit = Just [("PATH", "/usr/bin:/bin")]
      missing = directory </> "missing"
      cases =
        [ ("a missing absolute executable, inherited environment", missing, Nothing, Nothing, NoSuchThing, 2, missing),
          ("a missing absolute executable, explicit environment", missing, Nothing, explicit, NoSuchThing, 2, missing),
          ("an unresolved name, inherited environment", "agentic-missing-tool", Nothing, Nothing, NoSuchThing, 2, "agentic-missing-tool"),
          ("an unresolved name, explicit environment", "agentic-missing-tool", Nothing, explicit, OtherError, -2, "agentic-missing-tool"),
          ("an executable without execute permission, inherited environment", directory </> "noexec", Nothing, Nothing, PermissionDenied, 13, directory </> "noexec"),
          ("an executable without execute permission, explicit environment", directory </> "noexec", Nothing, explicit, PermissionDenied, 13, directory </> "noexec"),
          ("a missing working directory, inherited environment", "/usr/bin/true", Just missing, Nothing, NoSuchThing, 2, "/usr/bin/true"),
          ("a missing working directory, explicit environment", "/usr/bin/true", Just missing, explicit, NoSuchThing, 2, "/usr/bin/true"),
          ("a directory as the executable, inherited environment", directory, Nothing, Nothing, PermissionDenied, 13, directory),
          ("a directory as the executable, explicit environment", directory, Nothing, explicit, PermissionDenied, 13, directory),
          ("a file without an image format, explicit environment", directory </> "plain", Just directory, explicit, InvalidArgument, 8, directory </> "plain")
        ]
  forM_ cases $ \(label, executable, working, environment, kind, errno, file) -> do
    before <- childProcesses
    outcome <- try @IOException (createProcessGroup (proc executable []) {cwd = working, env = environment, std_in = NoStream, std_out = NoStream, std_err = NoStream})
    let settle :: Int -> IO [ProcessID]
        settle remaining = do
          now <- childProcesses
          if null (now \\ before) || remaining <= 0 then pure now else threadDelay 10000 >> settle (remaining - 1)
    after <- settle 500
    case outcome of
      Left failure -> do
        let observed = (ioe_type failure, ioe_errno failure, ioe_filename failure)
        unless (observed == (kind, Just errno, Just file)) $
          hPutStrLn stderr ("     " <> label <> ": observed " <> show observed)
        expect ("exec error class, errno and file name: " <> label) (observed == (kind, Just errno, Just file))
      Right group -> do
        terminateProcessGroup 2000000 group `finally` closeGroupPipes group
        expect ("exec error raised: " <> label) False
    unless (null (after \\ before)) $
      hPutStrLn stderr ("     " <> label <> ": children before " <> show before <> ", after " <> show after)
    expect ("no child remains for this process after the exec error: " <> label) (null (after \\ before))
#else
execErrorChecks directory = do
  let explicit = Just [("PATH", "/usr/bin:/bin")]
      raises executable environment = do
        outcome <- try @IOException (createProcessGroup (proc executable []) {cwd = Just directory, env = environment, std_in = NoStream, std_out = NoStream, std_err = NoStream})
        either (const (pure True)) (\group -> (terminateProcessGroup 2000000 group `finally` closeGroupPipes group) >> pure False) outcome
  raises "./plain" explicit >>= expect "explicit environment: a file without an image format is an exec error"
  raises (directory </> "missing") Nothing >>= expect "a missing absolute executable is an exec error"
  raises "agentic-missing-tool" explicit >>= expect "an unresolved name under an explicit environment is an exec error"
#endif

-- | Spawn cost must not grow with the soft @RLIMIT_NOFILE@. Each measurement
-- runs in a fresh process, which sets its soft limit before its first spawn.
-- The check requires a host whose hard limit allows 'highDescriptorLimit'.
spawnCostCheck :: IO ()
spawnCostCheck = do
  executable <- getExecutablePath
  allowed <- hardLimit <$> getResourceLimit ResourceOpenFiles
  case allowed of
    ResourceLimit hard | hard < highDescriptorLimit ->
      expect ("spawn-cost check requires a hard RLIMIT_NOFILE of at least " <> show highDescriptorLimit <> ", and this host allows " <> show hard) False
    _ -> pure ()
  costs <- forM [highDescriptorLimit, 4096] $ \limit -> do
    (status, output) <- capture (proc executable ["--process-group-spawn-cost", show limit, show timedSpawns]) {std_in = NoStream, std_out = CreatePipe, std_err = Inherit} (const (pure ()))
    expect ("spawn-cost probe at soft RLIMIT_NOFILE " <> show limit <> " completes") (status == ExitSuccess)
    case reads (BC.unpack output) of
      [(nanoseconds, _)] -> do
        putStrLn ("     spawn cost at soft RLIMIT_NOFILE " <> show limit <> ": " <> show timedSpawns <> " spawns, "
          <> show (nanoseconds `div` 1000000 :: Integer) <> " ms inside createProcessGroup")
        pure nanoseconds
      _ -> expect "spawn-cost probe reports nanoseconds" False >> pure 0
  case costs of
    high : _ -> expect ("spawn cost at soft RLIMIT_NOFILE " <> show highDescriptorLimit <> " stays below one second for " <> show timedSpawns <> " spawns")
      (high < spawnBudgetNs)
    [] -> expect "spawn-cost probe ran" False

-- | The child side of 'spawnCostCheck': set the soft descriptor limit, then
-- print the total nanoseconds that the spawns spend inside
-- 'createProcessGroup'.
spawnCostProbe :: String -> String -> IO ()
spawnCostProbe limitText countText = do
  let limit = read limitText :: Integer
      count = read countText :: Int
  current <- getResourceLimit ResourceOpenFiles
  refused <- try @IOException (setResourceLimit ResourceOpenFiles current {softLimit = ResourceLimit limit})
  either (\failure -> expect ("spawn-cost check requires a soft RLIMIT_NOFILE of " <> show limit <> ", and this host refused it: " <> show failure) False) pure refused
  applied <- getResourceLimit ResourceOpenFiles
  expect ("soft RLIMIT_NOFILE set to " <> show limit) (softLimit applied == ResourceLimit limit)
  spent <- forM [1 .. count] $ \_ -> do
    started <- getMonotonicTimeNSec
    group <- createProcessGroup (proc "/usr/bin/true" []) {std_in = NoStream, std_out = NoStream, std_err = NoStream}
    ended <- getMonotonicTimeNSec
    status <- waitProcessGroup group
    expect "spawn-cost child exits successfully" (status == ExitSuccess)
    pure (toInteger (ended - started))
  print (sum spent)
