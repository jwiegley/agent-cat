{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Exclusive publication of exact bytes to one absolute path.
--
-- The bytes go to a new private file in the destination directory first.
-- A hard link then publishes that file at the destination. A link never
-- replaces an existing entry, so an existing file, directory, symbolic link
-- or dangling symbolic link stays as it is. The new file has mode 0600. A
-- failure removes the private file, so it leaves no new file.
module Agentic.Tui.Save (saveExact) where

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

-- | Write exactly these bytes to a new file at this absolute path. The
-- result is a fixed refusal for a path that is not one absolute single-line
-- file path, or the description of the input or output failure.
saveExact :: FilePath -> BS.ByteString -> IO (Either Text ())
saveExact path bytes
  | not (isAbsolute path) || hasTrailingPathSeparator path || null (takeFileName path)
      || any (`elem` ['\NUL', '\n', '\r']) path =
      pure (Left "the destination must be one absolute single-line file path")
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
        publish `onException` removeLink private
        removeLink private
      pure $ case outcome of
        Left (failure :: IOException) -> Left (T.pack (show failure))
        Right () -> Right ()
  where
    hex byte = let digits = showHex byte "" in if length digits == 1 then '0' : digits else digits
