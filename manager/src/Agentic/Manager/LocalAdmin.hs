{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | A same-user local channel to an existing coordinator, not a second writer.
module Agentic.Manager.LocalAdmin (withLocalAdministration, callLocalAdministration) where

import Agentic.Manager.Configuration (Configuration, configurationAdministrationRoot)
import Agentic.Manager.Credentials (administerCredentials)
import Agentic.Manager.Protocol.Json (decodeStrictValue)
import Agentic.Manager.Protocol.LocalAdmin
import Agentic.Manager.Store (CoordinationStore, withStoreAdministration)
import Agentic.Runtime (PrivateRoot, assertPrivateRoot, closePrivateRoot, openPrivateRoot, privateRootPath)
import Control.Concurrent.Async (link, withAsync)
import Control.Exception (IOException, bracket, finally, throwIO, try)
import Control.Monad (forever, unless, void)
import Data.Aeson (Value (..))
import qualified Data.Aeson.KeyMap as KM
import Data.Bits ((.&.))
import qualified Data.ByteString as BS
import Data.Text (Text)
import Network.Socket (Family (AF_UNIX), Socket, SocketType (Stream), SockAddr (SockAddrUnix),
  ShutdownCmd (ShutdownSend), accept, bind, close, connect, defaultProtocol, getPeerCredential,
  listen, shutdown, socket)
import qualified Network.Socket.ByteString as Net
import System.FilePath ((</>))
import System.IO.Error (isDoesNotExistError)
import System.Posix.Files (FileStatus, deviceID, fileID, fileMode, fileOwner, getSymbolicLinkStatus,
  isSocket, linkCount, removeLink, setFileMode)
import System.Posix.User (getEffectiveUserID)
import System.Timeout (timeout)

-- | Serve the frozen requests while retaining the original Store configuration
-- and endpoint lease. The configuration guard is released before any request.
withLocalAdministration :: CoordinationStore -> IO a -> IO a
withLocalAdministration store action = do
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
          response <- case input of
            Left _ -> pure (adminError Nothing MalformedRequest)
            Right bytes -> case decodeLocalAdminRequest bytes of
              Left failure -> pure (adminError Nothing failure)
              Right request -> administerCredentials store request
          -- Only connection IO has an outer deadline. An admitted mutation is
          -- neither interrupted by this timer nor retried after a lost reply.
          void (try @IOException (boundedIO 5000000 (Net.sendAll connection response)))

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
