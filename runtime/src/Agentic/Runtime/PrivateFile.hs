{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE TypeApplications #-}

-- | Descriptor-relative file reads which never follow a symbolic link.
module Agentic.Runtime.PrivateFile
  ( readPrivateConfigurationFile,
    readConfinedFile,
    readConfinedFileAt,
    withConfinedDirectory,
    withConfinedDirectoryAt,
    withConfinedDirectoryIfPresentAt,
    listConfinedDirectoryAt,
  )
where

import Control.Exception (IOException, bracket, bracketOnError, throwIO, try)
import Control.Monad (unless, when)
import qualified Data.ByteString as BS
import Data.Bits ((.&.))
import Foreign.C.Error (throwErrnoIfMinus1, throwErrnoIfMinus1Retry, throwErrnoIfNull)
import Foreign.C.String (CString)
import Foreign.C.Types (CInt (..))
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (Ptr)
import Foreign.Storable (peek)
import qualified GHC.Foreign as GHC
import GHC.IO.Encoding (getFileSystemEncoding)
import System.FilePath (isAbsolute, isPathSeparator, splitDirectories)
import System.IO.Error (isDoesNotExistError)
import System.IO (hClose)
import System.Posix.Files (FileStatus, fileMode, fileOwner, fileSize, getFdStatus, isRegularFile)
import System.Posix.IO
  ( OpenFileFlags (cloexec, directory, nofollow, nonBlock),
    OpenMode (ReadOnly),
    closeFd,
    defaultFileFlags,
    fdToHandle,
    openFd,
    openFdAt,
  )
import System.Posix.Types (Fd)
import System.Posix.User (getEffectiveUserID)

-- | A bounded snapshot of an absolute, owned private regular configuration file.
-- Every path component is opened without following links. Ownership and mode
-- are checked on the opened file before reading, not on a prior pathname stat.
readPrivateConfigurationFile :: FilePath -> Integer -> IO BS.ByteString
readPrivateConfigurationFile path limit = do
  unless (isAbsolute path && '\0' `notElem` path) $
    ioError (userError "private configuration path must be absolute")
  user <- getEffectiveUserID
  let check status = unless (fileOwner status == user && fileMode status .&. 0o077 == 0) $
        ioError (userError "configuration file is not owned and private")
  withConfinedDirectory "/" [] $ \root ->
    fst <$> readConfinedFileAtChecked check root (drop 1 (splitDirectories path)) limit

readConfinedFile :: FilePath -> [FilePath] -> Integer -> IO (BS.ByteString, FileStatus)
readConfinedFile root components limit =
  withConfinedDirectory root [] $ \rootFd -> readConfinedFileAt rootFd components limit

readConfinedFileAt :: Fd -> [FilePath] -> Integer -> IO (BS.ByteString, FileStatus)
readConfinedFileAt = readConfinedFileAtChecked (const (pure ()))

readConfinedFileAtChecked :: (FileStatus -> IO ()) -> Fd -> [FilePath] -> Integer -> IO (BS.ByteString, FileStatus)
readConfinedFileAtChecked check root components limit = case components of
  [] -> throwIO (userError "confined file path is empty")
  _ -> go root components
  where
    go parent [file] = do
      validateComponent file
      readOpened check limit (openFdAt (Just parent) file ReadOnly fileFlags)
    go parent (component : rest) = do
      validateComponent component
      bracket
        (openFdAt (Just parent) component ReadOnly directoryFlags)
        closeFd
        (\child -> go child rest)
    go _ [] = throwIO (userError "confined file path is empty")

withConfinedDirectory :: FilePath -> [FilePath] -> (Fd -> IO a) -> IO a
withConfinedDirectory root components action =
  bracket (openFd root ReadOnly directoryFlags) closeFd $ \rootFd ->
    withConfinedDirectoryAt rootFd components action

withConfinedDirectoryAt :: Fd -> [FilePath] -> (Fd -> IO a) -> IO a
withConfinedDirectoryAt root components action = descend root components
  where
    descend current [] = action current
    descend current (component : rest) = do
      validateComponent component
      bracket
        (openFdAt (Just current) component ReadOnly directoryFlags)
        closeFd
        (\child -> descend child rest)

-- | An optional child directory; errors inside the action are never absence.
withConfinedDirectoryIfPresentAt :: Fd -> FilePath -> (Fd -> IO a) -> IO (Maybe a)
withConfinedDirectoryIfPresentAt parent component action = do
  validateComponent component
  let acquire = do
        opened <- try @IOException (openFdAt (Just parent) component ReadOnly directoryFlags)
        case opened of
          Left failure | isDoesNotExistError failure -> pure Nothing
          Left failure -> throwIO failure
          Right descriptor -> pure (Just descriptor)
  bracket acquire (mapM_ closeFd) (traverse action)

-- | A bounded directory listing from the captured descriptor, not its pathname.
listConfinedDirectoryAt :: Fd -> Int -> IO [FilePath]
listConfinedDirectoryAt parent limit = do
  encoding <- getFileSystemEncoding
  let acquire = bracketOnError (openFdAt (Just parent) "." ReadOnly directoryFlags) closeFd $ \descriptor ->
        throwErrnoIfNull "fdopendir" (fdOpenDirectory (fromIntegral descriptor))
      close stream = do
        _ <- throwErrnoIfMinus1 "closedir" (closeDirectory stream)
        pure ()
      loop stream count names = alloca $ \namePointer -> do
        available <- throwErrnoIfMinus1Retry "readdir" (readDirectoryName stream namePointer)
        if available == 0
          then pure (reverse names)
          else do
            name <- peek namePointer >>= GHC.peekCString encoding
            if name == "." || name == ".."
              then loop stream count names
              else do
                unless (count < limit) (ioError (userError ("confined directory exceeds " <> show limit <> " entries")))
                loop stream (count + 1) (name : names)
  bracket acquire close (\stream -> loop stream 0 [])

readOpened :: (FileStatus -> IO ()) -> Integer -> IO Fd -> IO (BS.ByteString, FileStatus)
readOpened check limit open =
  bracket acquire (hClose . fst) $ \(handle, status) -> do
    let bytes = toInteger (fileSize status)
    contents <- BS.hGet handle (fromInteger bytes + 1)
    unless (toInteger (BS.length contents) == bytes) $
      throwIO (userError "confined file changed while it was read")
    pure (contents, status)
  where
    acquire = bracketOnError open closeFd $ \descriptor -> do
      status <- getFdStatus descriptor
      unless (isRegularFile status) (throwIO (userError "confined path is not a regular file"))
      check status
      let bytes = toInteger (fileSize status)
      when (bytes < 0 || bytes > limit) (throwIO (userError "confined file exceeds its byte bound"))
      handle <- fdToHandle descriptor
      pure (handle, status)

validateComponent :: FilePath -> IO ()
validateComponent component =
  when
    ( null component
        || component == "."
        || component == ".."
        || any isPathSeparator component
        || '\0' `elem` component
    )
    (throwIO (userError "confined path contains an invalid component"))

fileFlags :: OpenFileFlags
fileFlags = defaultFileFlags {nofollow = True, cloexec = True, nonBlock = True}

directoryFlags :: OpenFileFlags
directoryFlags = fileFlags {directory = True}

foreign import ccall unsafe "fdopendir"
  fdOpenDirectory :: CInt -> IO (Ptr ())

foreign import ccall unsafe "closedir"
  closeDirectory :: Ptr () -> IO CInt

foreign import ccall unsafe "agentic_read_directory_name"
  readDirectoryName :: Ptr () -> Ptr CString -> IO CInt
