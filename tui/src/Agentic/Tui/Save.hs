{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Exclusive publication of exact bytes to one absolute path.
--
-- The bytes go to a new private file in the destination directory first.
-- A hard link then publishes that file at the destination, so the file
-- system of the destination directory must support hard links. A link never
-- replaces an existing entry, so an existing file, directory, symbolic link
-- or dangling symbolic link stays as it is. The new file has mode 0600. A
-- failure before the link removes the private file, so it leaves no new
-- file. After the link, the destination holds the exact bytes and the save
-- succeeds. When the private file cannot then be removed, the success names
-- that leftover file.
module Agentic.Tui.Save (SaveRefusal (..), Saved (..), saveExact, saveExactUsing, saveRefusalText) where

import Control.Exception (IOException, onException, try)
import Crypto.Random (getRandomBytes)
import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as T
import Numeric (showHex)
import System.FilePath (hasTrailingPathSeparator, isAbsolute, takeDirectory, takeFileName, (</>))
import System.IO (hClose)
import System.Posix.Files (createLink, removeLink, setFdMode)
import System.Posix.IO (OpenFileFlags (..), OpenMode (WriteOnly), closeFd, defaultFileFlags, fdToHandle, openFd)

-- | Why a save wrote nothing: the path is not one absolute single-line file
-- path, or an input or output operation failed. An existing entry at the
-- destination, a symbolic link included, is an input or output failure of
-- the already-exists type.
data SaveRefusal = InvalidDestination | SaveIOFailure !IOException
  deriving (Eq, Show)

-- | The text of a refusal: the fixed refusal of an invalid path, or the
-- description of the input or output failure.
saveRefusalText :: SaveRefusal -> Text
saveRefusalText refusal = case refusal of
  InvalidDestination -> "the destination must be one absolute single-line file path"
  SaveIOFailure failure -> T.pack (show failure)

-- | A save that published the exact bytes at the destination: the private
-- file was removed, or it remains at this path because its removal failed.
data Saved = Saved | SavedLeftover !FilePath
  deriving (Eq, Show)

-- | Write exactly these bytes to a new file at this absolute path.
saveExact :: FilePath -> BS.ByteString -> IO (Either SaveRefusal Saved)
saveExact = saveExactUsing removeLink

-- | 'saveExact' with this removal of the private file. A removal that fails
-- after the link leaves the private file, and the save still succeeds.
saveExactUsing :: (FilePath -> IO ()) -> FilePath -> BS.ByteString -> IO (Either SaveRefusal Saved)
saveExactUsing remove path bytes
  | not (isAbsolute path) || hasTrailingPathSeparator path || null (takeFileName path)
      || any (`elem` ['\NUL', '\n', '\r']) path =
      pure (Left InvalidDestination)
  | otherwise = do
      suffix <- getRandomBytes 12 :: IO BS.ByteString
      let private = takeDirectory path </> ("." <> takeFileName path <> "." <> concatMap hex (BS.unpack suffix) <> ".partial")
      outcome <- try $ do
        descriptor <- openFd private WriteOnly defaultFileFlags {creat = Just 0o600, exclusive = True, nofollow = True, cloexec = True}
        let publish = do
              setFdMode descriptor 0o600 `onException` closeFd descriptor
              handle <- fdToHandle descriptor `onException` closeFd descriptor
              (BS.hPut handle bytes `onException` hClose handle) >> hClose handle
              createLink private path
        publish `onException` remove private
      case outcome of
        Left (failure :: IOException) -> pure (Left (SaveIOFailure failure))
        Right () -> do
          removed <- try (remove private)
          pure . Right $ case removed of
            Left (_ :: IOException) -> SavedLeftover private
            Right () -> Saved
  where
    hex byte = let digits = showHex byte "" in if length digits == 1 then '0' : digits else digits
