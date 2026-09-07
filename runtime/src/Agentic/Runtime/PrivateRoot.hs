{-# LANGUAGE CPP #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | An owned private directory identity retained across descriptor-relative IO.
module Agentic.Runtime.PrivateRoot
  ( PrivateRoot,
    withPrivateRoot,
    openPrivateRoot,
    closePrivateRoot,
    openPrivateSubroot,
    withPrivateDirectoryAt,
    privateRootPath,
    privateRootIdentity,
    withStateAnchor,
    privatePathComponents,
    assertPrivateRoot,
    ensurePrivateDirectoryAt,
    createPrivateDirectoryAt,
    openPrivateFileAt,
    readPrivateFileAt,
    writePrivateExclusiveAt,
    writePrivateAtomicAt,
    publishPrivateFileAt,
    movePrivateAt,
    removePrivateFileAt,
    removePrivateDirectoryAt,
  )
where

import Agentic.Runtime.PrivateFile (readConfinedFileAt)
import Control.Concurrent.MVar (MVar, modifyMVar, newMVar, withMVar)
import Control.Exception (IOException, bracket, bracketOnError, finally, mask, mask_, onException, throwIO, try)
import Control.Monad (unless, when)
import Data.Aeson (eitherDecodeStrict', encode)
import Data.Bits ((.&.))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Foreign.C.Error (eEXIST, eNOENT, getErrno, throwErrno)
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CInt (..))
import System.Directory (createDirectoryIfMissing)
import System.Environment (lookupEnv)
import System.FilePath (dropTrailingPathSeparator, isAbsolute, isPathSeparator, makeRelative, normalise, splitDirectories, takeDirectory, (</>))
import System.IO (Handle, hClose, hFlush)
import System.IO.Error (isDoesNotExistError)
import qualified System.Posix.Directory as PosixDirectory
import System.Posix.Files (FileStatus, deviceID, fileID, fileMode, fileOwner, getFdStatus, getSymbolicLinkStatus, isDirectory, isSymbolicLink, ownerModes)
import System.Posix.IO (OpenFileFlags (cloexec, creat, directory, exclusive, nofollow), OpenMode (ReadOnly, WriteOnly), closeFd, defaultFileFlags, fdToHandle, openFd, openFdAt)
import System.Posix.Types (CMode (..), DeviceID, Fd (..), FileID, UserID)
import System.Posix.User (getEffectiveUserID)

-- | One validated directory and the identity its pathname must still designate.
data PrivateRoot = PrivateRoot
  { privateRootPath :: !FilePath,
    privateRootFd :: !(MVar (Maybe Fd)),
    privateRootDevice :: !DeviceID,
    privateRootFile :: !FileID,
    privateRootOwner :: !UserID,
    privateRootLabel :: !String
  }

withPrivateRoot :: String -> FilePath -> (PrivateRoot -> IO a) -> IO a
withPrivateRoot label original action = do
  let path = dropTrailingPathSeparator (normalise original)
  validateRootPath label path
  inspected <- try @IOException (getSymbolicLinkStatus path)
  case inspected of
    Left failure
      | isDoesNotExistError failure -> do
          createDirectoryIfMissing True (takeDirectory path)
          PosixDirectory.createDirectory path ownerModes
      | otherwise -> throwIO failure
    Right _ -> pure ()
  bracket (openPrivateRoot label path) closePrivateRoot action

validateRootPath :: String -> FilePath -> IO ()
validateRootPath label path =
  unless (isAbsolute path && not ('\NUL' `elem` path)) $
    ioError (userError (label <> " path is not absolute or contains NUL"))

openPrivateRoot :: String -> FilePath -> IO PrivateRoot
openPrivateRoot label original = do
  let path = dropTrailingPathSeparator (normalise original)
  validateRootPath label path
  user <- getEffectiveUserID
  getSymbolicLinkStatus path >>= validateDirectory user label
  bracketOnError (openFd path ReadOnly directoryFlags) closeFd $ \descriptor -> do
    root <- rootFromDescriptor label path descriptor
    assertPrivateRoot root
    pure root

closePrivateRoot :: PrivateRoot -> IO ()
closePrivateRoot root = mask_ $ do
  descriptor <- modifyMVar (privateRootFd root) (\current -> pure (Nothing, current))
  mapM_ closeFd descriptor

openPrivateSubroot :: PrivateRoot -> [FilePath] -> IO PrivateRoot
openPrivateSubroot root components =
  bracketOnError (openDirectoryChain root components) closeFd $ \descriptor ->
    rootFromDescriptor (privateRootLabel root) (foldl (</>) (privateRootPath root) components) descriptor

rootFromDescriptor :: String -> FilePath -> Fd -> IO PrivateRoot
rootFromDescriptor label path descriptor = do
  user <- getEffectiveUserID
  status <- getFdStatus descriptor
  validateDirectory user label status
  state <- newMVar (Just descriptor)
  pure (PrivateRoot path state (deviceID status) (fileID status) user label)

-- | A process-boundary identity, not authority: the receiver reopens and fstats it.
privateRootIdentity :: PrivateRoot -> String
privateRootIdentity root = T.unpack . TE.decodeUtf8 . BL.toStrict . encode $
  (privateRootPath root, toInteger (privateRootDevice root), toInteger (privateRootFile root))

-- | Validate the optional parent's state-root identity before accessing child paths.
withStateAnchor :: (Maybe PrivateRoot -> IO a) -> IO a
withStateAnchor action = do
  configured <- lookupEnv "AGENT_CAT_STATE_ANCHOR"
  case configured of
    Nothing -> action Nothing
    Just encoded -> do
      let bytes = TE.encodeUtf8 (T.pack encoded)
      when (BS.length bytes > 16384) (ioError (userError "state root identity exceeds its byte bound"))
      (path, device, inode) <- either (const (ioError (userError "invalid state root identity"))) pure $
        eitherDecodeStrict' @(FilePath, Integer, Integer) bytes
      bracket (openPrivateRoot "anchored state root" path) closePrivateRoot $ \root -> do
        unless (toInteger (privateRootDevice root) == device && toInteger (privateRootFile root) == inode) $
          ioError (userError "state root identity changed before child access")
        action (Just root)

privatePathComponents :: PrivateRoot -> FilePath -> IO [FilePath]
privatePathComponents root path = do
  let relative = makeRelative (privateRootPath root) path
      components = splitDirectories relative
  unless (isAbsolute path && not (isAbsolute relative)) $
    ioError (userError "path is outside the anchored state root")
  mapM_ validateComponent components
  pure components

assertPrivateRoot :: PrivateRoot -> IO ()
assertPrivateRoot root = withRootDescriptor root (assertRootIdentity root)

withRootDescriptor :: PrivateRoot -> (Fd -> IO a) -> IO a
withRootDescriptor root action = withMVar (privateRootFd root) $ \current ->
  maybe (ioError (userError (privateRootLabel root <> " is closed"))) action current

assertRootIdentity :: PrivateRoot -> Fd -> IO ()
assertRootIdentity root descriptor = do
  descriptorStatus <- getFdStatus descriptor
  pathStatus <- getSymbolicLinkStatus (privateRootPath root)
  validateDirectory (privateRootOwner root) (privateRootLabel root) descriptorStatus
  validateDirectory (privateRootOwner root) (privateRootLabel root) pathStatus
  unless
    ( deviceID descriptorStatus == privateRootDevice root
        && fileID descriptorStatus == privateRootFile root
        && deviceID pathStatus == privateRootDevice root
        && fileID pathStatus == privateRootFile root
    )
    (ioError (userError (privateRootLabel root <> " identity changed while it was open")))

ensurePrivateDirectoryAt :: PrivateRoot -> [FilePath] -> IO ()
ensurePrivateDirectoryAt = descend True

createPrivateDirectoryAt :: PrivateRoot -> [FilePath] -> IO ()
createPrivateDirectoryAt = descend False

openPrivateFileAt :: PrivateRoot -> [FilePath] -> IO Handle
openPrivateFileAt root components = withParent root components $ \parent file ->
  bracketOnError (openFdAt (Just parent) file WriteOnly fileFlags) closeFd fdToHandle

readPrivateFileAt :: PrivateRoot -> [FilePath] -> Integer -> IO BS.ByteString
readPrivateFileAt root components limit =
  withParent root components $ \parent file -> fst <$> readConfinedFileAt parent [file] limit

writePrivateExclusiveAt :: PrivateRoot -> [FilePath] -> BS.ByteString -> IO ()
writePrivateExclusiveAt root components bytes =
  bracket (openPrivateFileAt root components) hClose $ \handle -> BS.hPut handle bytes >> hFlush handle

writePrivateAtomicAt :: PrivateRoot -> [FilePath] -> BS.ByteString -> IO ()
writePrivateAtomicAt root components bytes =
  withTemporaryAt False root components (\handle -> BS.hPut handle bytes)

-- | Publish a completed artifact without replacing any existing directory entry.
publishPrivateFileAt :: PrivateRoot -> [FilePath] -> (Handle -> IO a) -> IO a
publishPrivateFileAt = withTemporaryAt True

withTemporaryAt :: Bool -> PrivateRoot -> [FilePath] -> (Handle -> IO a) -> IO a
withTemporaryAt exclusivePublish root components action = withParent root components $ \parent file -> mask $ \restore -> do
  let temporary = file <> ".tmp"
      cleanup = voidUnlink parent temporary
  descriptor <- openFdAt (Just parent) temporary WriteOnly fileFlags
  handle <- fdToHandle descriptor `onException` (closeFd descriptor `finally` cleanup)
  result <- (restore (action handle <* hFlush handle) `finally` hClose handle) `onException` cleanup
  (if exclusivePublish
      then linkAt parent temporary parent file >> cleanup
      else renameAt parent temporary parent file
    ) `onException` cleanup
  pure result

movePrivateAt :: PrivateRoot -> [FilePath] -> [FilePath] -> IO ()
movePrivateAt root oldComponents newComponents =
  withParent root oldComponents $ \oldParent oldName ->
    withParent root newComponents $ \newParent newName ->
      renameAt oldParent oldName newParent newName

removePrivateFileAt :: PrivateRoot -> [FilePath] -> IO ()
removePrivateFileAt root components = unlinkPrivateAt root components 0

removePrivateDirectoryAt :: PrivateRoot -> [FilePath] -> IO ()
removePrivateDirectoryAt root components = unlinkPrivateAt root components atRemovedir

unlinkPrivateAt :: PrivateRoot -> [FilePath] -> CInt -> IO ()
unlinkPrivateAt root components flags = withParent root components $ \(Fd descriptor) name -> do
  result <- withCString name (\path -> c_unlinkat descriptor path flags)
  when (result == -1) $ do
    errno <- getErrno
    when (errno /= eNOENT) (throwErrno "unlinkat")

atRemovedir :: CInt
#if defined(darwin_HOST_OS)
atRemovedir = 0x80
#else
atRemovedir = 0x200
#endif

withParent :: PrivateRoot -> [FilePath] -> (Fd -> FilePath -> IO a) -> IO a
withParent root components action = do
  mapM_ validateComponent components
  case reverse components of
    [] -> ioError (userError "private file path is empty")
    file : parents -> bracket (openDirectoryChain root (reverse parents)) closeFd (\parent -> action parent file)

withPrivateDirectoryAt :: PrivateRoot -> [FilePath] -> (Fd -> IO a) -> IO a
withPrivateDirectoryAt root components action =
  bracket (openDirectoryChain root components) closeFd action

openDirectoryChain :: PrivateRoot -> [FilePath] -> IO Fd
openDirectoryChain root components = mask_ $ do
  mapM_ validateComponent components
  initial <- withRootDescriptor root $ \descriptor -> do
    assertRootIdentity root descriptor
    openFdAt (Just descriptor) "." ReadOnly directoryFlags
  foldDirectories initial components
  where
    foldDirectories current [] = pure current
    foldDirectories current (component : rest) = do
      next <- bracket (pure current) closeFd $ \parent ->
        openFdAt (Just parent) component ReadOnly directoryFlags
      (getFdStatus next >>= validateDirectory (privateRootOwner root) "private state descendant") `onException` closeFd next
      foldDirectories next rest

-- Parents are ensured; the final component is exclusive for creation.
descend :: Bool -> PrivateRoot -> [FilePath] -> IO ()
descend finalMayExist root components = do
  mapM_ validateComponent components
  bracket (openDirectoryChain root []) closeFd (\descriptor -> go descriptor components)
  where
    go parent [component] = do
      mkdirAt parent component finalMayExist
      checkChild parent component (const (pure ()))
    go parent (component : rest) = do
      mkdirAt parent component True
      checkChild parent component (\child -> go child rest)
    go _ [] = ioError (userError "private directory path is empty")
    checkChild parent component action =
      bracket (openFdAt (Just parent) component ReadOnly directoryFlags) closeFd $ \child -> do
        getFdStatus child >>= validateDirectory (privateRootOwner root) "private state descendant"
        action child

mkdirAt :: Fd -> FilePath -> Bool -> IO ()
mkdirAt (Fd descriptor) component mayExist = do
  result <- withCString component $ \name -> c_mkdirat descriptor name 0o700
  when (result == -1) $ do
    errno <- getErrno
    unless (mayExist && errno == eEXIST) (throwErrno "mkdirat")

renameAt :: Fd -> FilePath -> Fd -> FilePath -> IO ()
renameAt (Fd oldDescriptor) oldName (Fd newDescriptor) newName =
  withCString oldName $ \oldPath -> withCString newName $ \newPath -> do
    result <- c_renameat oldDescriptor oldPath newDescriptor newPath
    when (result == -1) (throwErrno "renameat")

linkAt :: Fd -> FilePath -> Fd -> FilePath -> IO ()
linkAt (Fd oldDescriptor) oldName (Fd newDescriptor) newName =
  withCString oldName $ \oldPath -> withCString newName $ \newPath -> do
    result <- c_linkat oldDescriptor oldPath newDescriptor newPath 0
    when (result == -1) (throwErrno "linkat")

voidUnlink :: Fd -> FilePath -> IO ()
voidUnlink (Fd descriptor) name = do
  _ <- withCString name (\path -> c_unlinkat descriptor path 0)
  pure ()

validateDirectory :: UserID -> String -> FileStatus -> IO ()
validateDirectory user label status = do
  unless (isDirectory status && not (isSymbolicLink status)) $
    ioError (userError (label <> " is not a no-follow directory"))
  unless (fileOwner status == user) $
    ioError (userError (label <> " is not owned by the effective user"))
  unless (fileMode status .&. 0o077 == 0) $
    ioError (userError (label <> " permissions are not private"))

validateComponent :: FilePath -> IO ()
validateComponent component =
  when (null component || component == "." || component == ".." || any isPathSeparator component || '\NUL' `elem` component) $
    ioError (userError "private path contains an invalid component")

directoryFlags :: OpenFileFlags
directoryFlags = defaultFileFlags {directory = True, nofollow = True, cloexec = True}

fileFlags :: OpenFileFlags
fileFlags = defaultFileFlags {creat = Just 0o600, exclusive = True, nofollow = True, cloexec = True}

foreign import ccall unsafe "mkdirat" c_mkdirat :: CInt -> CString -> CMode -> IO CInt
foreign import ccall unsafe "renameat" c_renameat :: CInt -> CString -> CInt -> CString -> IO CInt
foreign import ccall unsafe "linkat" c_linkat :: CInt -> CString -> CInt -> CString -> CInt -> IO CInt
foreign import ccall unsafe "unlinkat" c_unlinkat :: CInt -> CString -> CInt -> IO CInt
