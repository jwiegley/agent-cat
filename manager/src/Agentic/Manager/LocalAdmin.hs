{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | A same-user local channel to an existing coordinator, not a second writer.
module Agentic.Manager.LocalAdmin
  ( withLocalAdministration, callLocalAdministration, administerLocally,
    AdministrationHooks (..), offlineAdministration, ProfileReload, backupStopped, restoreStopped
  ) where

import Agentic.Manager.Administration (localAdministrator, recordAdministration, recordAdministrationReceipt)
import Agentic.Manager.Configuration (Configuration, InstalledConfiguration, configurationAdministrationRoot)
import Agentic.Manager.Credentials (administerCredentials)
import Agentic.Manager.Flow (AdministrationBody (DrainAdministration, ReloadAdministration, ShutdownAdministration))
import Agentic.Manager.Profile (Diagnostic (UnreadableConfiguration), PublicProfile, publicId, publicRevision)
import Agentic.Manager.Protocol.Json (decodeStrictValue)
import Agentic.Manager.Protocol.LocalAdmin
import Agentic.Manager.Quarantine (StoreState (..), checkQuarantine, releaseQuarantine, reportStatus, reportStoreCheck)
import Agentic.Manager.Store (CoordinationStore, RestoreFence (..), StoreBackup (..),
  StoreFailure (StoreFenceMismatch, StoreLimit, StoreOutputConflict), StoreRestoration (..),
  advanceAuthorizationRevision, backupCoordinationStore, restoreCoordinationStore, runTransaction,
  withStoreAdministration, withStoreRequest)
import Agentic.Runtime (PrivateRoot, assertPrivateRoot, closePrivateRoot, openPrivateRoot, privateRootPath, readPrivateFileAt)
import Control.Concurrent.Async (link, withAsync)
import Control.Exception (IOException, bracket, finally, throwIO, try)
import Control.Monad (forever, unless, void, when)
import Data.Aeson (Value (..), object, (.=))
import qualified Data.Aeson.KeyMap as KM
import Data.Bits ((.&.))
import qualified Data.ByteString as BS
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Network.Socket (Family (AF_UNIX), Socket, SocketType (Stream), SockAddr (SockAddrUnix),
  ShutdownCmd (ShutdownSend), accept, bind, close, connect, defaultProtocol, getPeerCredential,
  listen, shutdown, socket)
import qualified Network.Socket.ByteString as Net
import System.FilePath (takeDirectory, takeFileName, (</>))
import System.IO.Error (isDoesNotExistError)
import System.Posix.Files (FileStatus, deviceID, fileID, fileMode, fileOwner, getSymbolicLinkStatus,
  isSocket, linkCount, removeLink, setFileMode)
import System.Posix.User (getEffectiveUserID)
import System.Timeout (timeout)

-- | The profile reload of a serving manager: load its configuration file
-- again and install the profiles, or refuse and keep the installed profiles.
type ProfileReload = IO (Either Diagnostic [PublicProfile])

-- | The lifetime facts and actions that one dispatch of a request uses.
-- 'hookState' is the state that @status@ reports. 'hookWake' tells the
-- running admission controller that a committed quarantine release freed its
-- execution slot and resource keys, or that a profile reload installed new
-- profiles. 'hookReload' performs @reload-profiles@ and 'hookDrain' performs
-- @drain@ on a serving manager. 'hookShutdown' is the stop request of a
-- serving manager, which @shutdown@ calls after its reply. Without them, the
-- dispatch refuses those operations with 'StateConflict'.
data AdministrationHooks = AdministrationHooks
  { hookState :: IO StoreState, hookWake :: IO (), hookReload :: Maybe ProfileReload, hookDrain :: Maybe (IO ()),
    hookShutdown :: Maybe (IO ()) }

-- | The hooks of offline administration: the Store is stopped, no admission
-- controller runs, and nothing can be reloaded, drained or stopped.
offlineAdministration :: AdministrationHooks
offlineAdministration = AdministrationHooks (pure StoreStopped) (pure ()) Nothing Nothing Nothing

-- | Serve the frozen requests while retaining the original Store configuration
-- and endpoint lease. The configuration guard is released before any request.
-- The hooks are those of the serving manager. Each reply is written and the
-- sending half of its connection is closed, so that the client reads the end
-- of the reply. The action that the dispatch gives then runs, whether or not
-- the reply reached the client.
withLocalAdministration :: CoordinationStore -> AdministrationHooks -> IO a -> IO a
withLocalAdministration store hooks action = do
  result <- withStoreAdministration store $ \root -> do
    -- Exclusive directory ownership, not process absence, permits stale-name removal.
    previous <- try @IOException (checkedSocket root)
    case previous of
      Left failure | isDoesNotExistError failure -> pure ()
      Left failure -> throwIO failure
      Right _ -> removeLink (socketPath root)
    bracket newSocket close $ \listener -> do
      bind listener (SockAddrUnix (socketPath root))
      setFileMode (socketPath root) 0o600
      owned <- checkedSocket root
      (do
        listen listener 4
        withAsync (serve root listener) $ \server -> link server >> action)
        `finally` removeOwned root owned
  either throwIO pure result
  where
    serve root listener = forever $ bracket (accept listener) (close . fst) $ \(connection, _) -> do
      accepted <- try @IOException (assertPrivateRoot root >> requirePeer connection)
      case accepted of
        Left _ -> pure ()
        Right () -> do
          input <- try @IOException (boundedIO 5000000 (receiveBounded 2097152 connection))
          (response, after) <- case input of
            Left _ -> pure (adminError Nothing MalformedRequest, pure ())
            Right bytes -> case decodeLocalAdminRequest bytes of
              Left failure -> pure (adminError Nothing failure, pure ())
              Right request -> administerLocally hooks store request
          -- Only connection IO has an outer deadline. An admitted mutation is
          -- neither interrupted by this timer nor retried after a lost reply.
          void (try @IOException (boundedIO 5000000 (Net.sendAll connection response >> shutdown connection ShutdownSend)))
          after

-- | Dispatch one decoded request to its owner on the original Store, and give
-- the response and the action that follows its reply. Only @shutdown@ gives
-- an action other than @pure ()@. The live channel passes the hooks of the
-- serving manager. Offline administration passes 'offlineAdministration'.
-- Offline @reload-profiles@ only validates a file and offline @shutdown@
-- changes nothing, both before any Store opens, and offline @drain@ has no
-- lifetime to drain, so without their hooks this dispatch refuses them with
-- 'StateConflict'. A @backup@ needs the stopped Store, which offline
-- administration copies through 'backupStopped' before any other Store
-- lifetime opens, so this dispatch, and with it the serving manager, refuses
-- it with 'StateConflict'. A @restore@ replaces the stopped Store through
-- 'restoreStopped' in offline administration, so this dispatch refuses it
-- with 'StateConflict' too.
administerLocally :: AdministrationHooks -> CoordinationStore -> LocalAdminRequest -> IO (BS.ByteString, IO ())
administerLocally hooks store request = case request of
  Status -> answered (hookState hooks >>= \state -> reportStatus state store)
  CheckStore -> answered (reportStoreCheck store)
  CheckQuarantine ident -> answered (checkQuarantine store ident)
  ReleaseQuarantine ident evidence digest -> answered (releaseQuarantine store (hookWake hooks) ident evidence digest)
  IssueCredential {} -> answered (administerCredentials store request)
  RotateCredential {} -> answered (administerCredentials store request)
  RevokeCredential {} -> answered (administerCredentials store request)
  ListCredentials -> answered (administerCredentials store request)
  ReloadProfiles -> maybe refused (answered . reloadServing store (hookWake hooks)) (hookReload hooks)
  Drain -> maybe refused (answered . drainServing store) (hookDrain hooks)
  Shutdown -> maybe refused (shutdownServing store) (hookShutdown hooks)
  Backup _ -> refused
  Restore _ _ -> refused
  where
    answered = fmap (\response -> (response, pure ()))
    refused = pure (adminError (Just (adminOperation request)) StateConflict, pure ())

-- | @reload-profiles@ on a serving manager. A transaction appends the command
-- record of the reload to the manager log and commits. The reload then loads
-- the configuration file and installs its profiles. A successful reload
-- advances the authorization revision, so that the next revalidation of every
-- retained view reads the authorization facts again, and wakes the admission
-- controller. The receipt with the response follows. A file that cannot be
-- read is refused with 'StorageUnavailable', and every other refusal of the
-- reload, such as an invalid file or a changed manager root, administration
-- root or @https@ section, with 'StateConflict'. A refused reload keeps the
-- installed profiles. A command record that cannot be appended refuses the
-- reload with 'StorageUnavailable' before it runs.
reloadServing :: CoordinationStore -> IO () -> ProfileReload -> IO BS.ByteString
reloadServing store wake reload = recordedServing store operation ReloadAdministration $ do
  result <- reload
  case result of
    Left UnreadableConfiguration -> pure (failure StorageUnavailable, pure ())
    Left _ -> pure (failure StateConflict, pure ())
    Right profiles -> do
      advanceAuthorizationRevision store
      pure (adminSuccess operation (reloadedProfiles [(publicId profile, publicRevision profile) | profile <- profiles]), wake)
  where
    operation = "reload-profiles"
    failure = adminError (Just operation)

-- | @drain@ on a serving manager. A transaction appends the command record of
-- the drain to the manager log and commits. The drain is then published, and
-- the answer @{state: draining}@ and its receipt follow. The drain has no
-- deadline and lasts for the rest of the lifetime. A repeated drain answers
-- the same. A command record that cannot be appended refuses the drain with
-- 'StorageUnavailable' before it is published.
drainServing :: CoordinationStore -> IO () -> IO BS.ByteString
drainServing store drain = recordedServing store "drain" DrainAdministration $ do
  drain
  pure (adminSuccess "drain" (object ["state" .= ("draining" :: Text)]), pure ())

-- | @shutdown@ on a serving manager. A transaction appends the command record
-- of the shutdown to the manager log and commits. The answer
-- @{state: stopped}@ and its receipt follow, and the stop request runs after
-- the reply. The termination path of the manager then cancels the owned runs
-- with their original cleanup, ends the open streams, appends the shutdown
-- notice and closes the listener. A command record that cannot be appended
-- refuses the shutdown with 'StorageUnavailable', and the manager keeps
-- serving.
shutdownServing :: CoordinationStore -> IO () -> IO (BS.ByteString, IO ())
shutdownServing store stop = do
  admitted <- newIORef False
  response <- recordedServing store "shutdown" ShutdownAdministration $ do
    writeIORef admitted True
    pure (stoppedManager, pure ())
  stopping <- readIORef admitted
  pure (response, when stopping stop)

-- | One mutating operation of a serving manager that changes no Store row. A
-- transaction appends its command record to the manager log and commits. The
-- operation then runs and gives its response and an action that follows the
-- receipt. The receipt of the response is appended, and the action runs. A
-- size limit of the log refuses with 'SizeLimit', a refused append with its
-- refusal, and every other failure with 'StorageUnavailable', each before the
-- operation runs.
recordedServing :: CoordinationStore -> Text -> AdministrationBody -> IO (BS.ByteString, IO ()) -> IO BS.ByteString
recordedServing store operation body perform = do
  principal <- localAdministrator
  recorded <- try @IOException (try @AdminFailure (try @StoreFailure (withStoreRequest store $ \scoped ->
    runTransaction scoped ((\logged -> (logged, [])) <$> recordAdministration scoped principal body))))
  case recorded of
    Right (Right (Right logged)) -> do
      (response, after) <- perform
      answered <- recordAdministrationReceipt store principal logged response
      after
      pure answered
    Right (Right (Left StoreLimit)) -> pure (failure SizeLimit)
    Right (Left refusal) -> pure (failure refusal)
    _ -> pure (failure StorageUnavailable)
  where
    failure = adminError (Just operation)

-- | Offline @backup@ into the given destination under the configuration
-- lease of the installed configuration. It copies the Store through
-- 'backupCoordinationStore', with no restart reconciliation and no manager
-- log, and answers the frozen result that 'backedUp' defines. An existing
-- destination refuses with 'OutputConflict'. Every other failure propagates
-- to the caller.
backupStopped :: InstalledConfiguration -> FilePath -> IO BS.ByteString
backupStopped installed destination = do
  result <- try @StoreFailure (backupCoordinationStore installed destination)
  case result of
    Right copied -> pure (adminSuccess "backup" (backedUp (backupBinding copied) (backupSha256 copied) (backupBytes copied)))
    Left StoreOutputConflict -> pure (adminError (Just "backup") OutputConflict)
    Left failure -> throwIO failure

-- | Offline @restore@ from the backup directory under the configuration lease
-- of the installed configuration. The fencing evidence file is a private
-- file that holds the offline @status@ answer which the operator saved after
-- the last lifetime stopped. Its @state@ must be @stopped@, and its
-- @authorityEpoch@ and @streamId@ must name the identities of the stopped
-- Store. Its @processGeneration@ is not compared, because each Store open
-- creates a new one. 'restoreCoordinationStore' compares the two identities
-- under its configuration lease, at the open of its restoring lifetime and
-- before it writes the restoration marker. On a root that an interrupted
-- restoration fenced, it compares them with the identities before the
-- restoration that the marker records, and it completes that restoration
-- only from the backup that the marker records. Evidence that is not such an
-- answer, evidence that names other identities, and another backup on a
-- fenced root refuse with 'StateConflict' and change nothing, the marker
-- included. A completed restoration answers the frozen result that
-- 'restored' defines. Every other failure propagates to the caller.
restoreStopped :: InstalledConfiguration -> FilePath -> FilePath -> IO BS.ByteString
restoreStopped installed source evidenceFile = do
  evidence <- bracket (openPrivateRoot "restore fencing evidence" (takeDirectory evidenceFile)) closePrivateRoot $ \parent ->
    readPrivateFileAt parent [takeFileName evidenceFile] 1048576
  case fencingEvidence evidence of
    Nothing -> pure conflict
    Just fence -> do
      result <- try @StoreFailure (restoreCoordinationStore installed source fence)
      case result of
        Right installedIdentity -> pure (adminSuccess "restore"
          (restored (restoredAuthorityEpoch installedIdentity) (restoredStreamId installedIdentity)))
        Left StoreFenceMismatch -> pure conflict
        Left failure -> throwIO failure
  where
    conflict = adminError (Just "restore") StateConflict

-- | The authority epoch and the stream identity of an offline @status@
-- answer that reports the state @stopped@.
fencingEvidence :: BS.ByteString -> Maybe RestoreFence
fencingEvidence bytes = case decodeStrictValue bytes of
  Right (Object fields)
    | KM.lookup "version" fields == Just (Number 1)
    , KM.lookup "operation" fields == Just (String "status")
    , KM.lookup "ok" fields == Just (Bool True)
    , Just (Object result) <- KM.lookup "result" fields
    , KM.lookup "state" result == Just (String "stopped")
    , Just (String epoch) <- KM.lookup "authorityEpoch" result
    , Just (String stream) <- KM.lookup "streamId" result -> Just (RestoreFence epoch stream)
  _ -> Nothing

-- | Nothing selects the existing offline path. A configured channel failure
-- never reopens the Store or retries the request through another path.
callLocalAdministration :: Configuration -> BS.ByteString -> IO (Maybe BS.ByteString)
callLocalAdministration configuration bytes = case configurationAdministrationRoot configuration of
  Nothing -> pure Nothing
  Just path -> case decodeLocalAdminRequest bytes of
    Left failure -> pure (Just (adminError Nothing failure))
    Right request -> bracket (openPrivateRoot "local administration client" path) closePrivateRoot $ \root ->
      bracket newSocket close $ \connection -> boundedIO 15000000 $ do
        _ <- checkedSocket root
        connect connection (SockAddrUnix (socketPath root))
        requirePeer connection
        Net.sendAll connection bytes
        shutdown connection ShutdownSend
        response <- receiveBounded 1048575 connection
        unless (completeReply (adminOperation request) response) transportFailure
        pure (Just response)

newSocket :: IO Socket
newSocket = socket AF_UNIX Stream defaultProtocol

socketPath :: PrivateRoot -> FilePath
socketPath root = privateRootPath root </> "admin.sock"

requirePeer :: Socket -> IO ()
requirePeer connection = do
  (_, uid, _) <- getPeerCredential connection
  owner <- getEffectiveUserID
  unless (uid == Just (fromIntegral owner)) transportFailure

checkedSocket :: PrivateRoot -> IO FileStatus
checkedSocket root = do
  assertPrivateRoot root
  status <- getSymbolicLinkStatus (socketPath root)
  owner <- getEffectiveUserID
  unless (isSocket status && fileOwner status == owner && linkCount status == 1
    && fileMode status .&. 0o077 == 0) transportFailure
  pure status

removeOwned :: PrivateRoot -> FileStatus -> IO ()
removeOwned root original = do
  current <- checkedSocket root
  unless ((deviceID current, fileID current) == (deviceID original, fileID original)) transportFailure
  removeLink (socketPath root)

-- The extra byte distinguishes a full bounded frame from an oversized one.
-- EOF is required for a frame at or below the bound.
receiveBounded :: Int -> Socket -> IO BS.ByteString
receiveBounded limit connection = go (limit + 1) []
  where
    go remaining chunks
      | remaining == 0 = pure (BS.concat (reverse chunks))
      | otherwise = do
          bytes <- Net.recv connection (min 32768 remaining)
          if BS.null bytes then pure (BS.concat (reverse chunks))
            else go (remaining - BS.length bytes) (bytes : chunks)

-- The peer is the trusted local operator. Reject truncation, concatenated JSON,
-- duplicate fields, unexpected envelopes and mismatched operation replies.
completeReply :: Text -> BS.ByteString -> Bool
completeReply operation bytes = BS.length bytes < 1048576 && case decodeStrictValue bytes of
  Right (Object fields)
    | KM.lookup "version" fields == Just (Number 1)
    , KM.lookup "operation" fields == Just (String operation)
    , KM.size fields == 4 -> case KM.lookup "ok" fields of
        Just (Bool True) -> case KM.lookup "result" fields of Just (Object _) -> True; _ -> False
        Just (Bool False) -> case KM.lookup "error" fields of
          Just (Object failure) -> KM.size failure == 2
            && KM.lookup "message" failure == Just (String "")
            && case KM.lookup "code" failure of Just (String _) -> True; _ -> False
          _ -> False
        _ -> False
  _ -> False

boundedIO :: Int -> IO a -> IO a
boundedIO microseconds action = timeout microseconds action >>= maybe transportFailure pure

transportFailure :: IO a
transportFailure = ioError (userError "local administration transport unavailable")
