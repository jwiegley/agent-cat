{-# LANGUAGE TypeApplications #-}

-- | Observed separation between manager storage and local retention namespaces.
module Agentic.Manager.Root (validateRootSeparation) where

import Agentic.Runtime (PrivateRoot, assertPrivateRoot, privateRootPath)
import Control.Exception (IOException, throwIO, try)
import Control.Monad (forM_, unless, when)
import Data.List (isPrefixOf)
import System.Directory (canonicalizePath)
import System.FilePath (isAbsolute, joinPath, splitDirectories)
import System.IO.Error (isDoesNotExistError)
import System.Posix.Files (deviceID, fileID, getSymbolicLinkStatus, isDirectory, isSymbolicLink)
import System.Posix.Types (DeviceID, FileID)

-- | Refuse configured local roots which equal, contain, or lie within manager
-- storage. Missing suffixes are compared under their existing directory
-- identities. This observation does not authorize later pathname operations.
validateRootSeparation :: PrivateRoot -> [FilePath] -> IO ()
validateRootSeparation manager localRoots = do
  assertPrivateRoot manager
  managerAnchors <- pathAnchors (privateRootPath manager)
  forM_ localRoots $ \local -> do
    localAnchors <- pathAnchors local
    when (any (overlaps localAnchors) managerAnchors) $
      ioError (userError "manager storage overlaps a configured local retention root")
  assertPrivateRoot manager
  where
    overlaps candidates (identity, suffix) = any
      (\(other, remainder) -> identity == other && (suffix `isPrefixOf` remainder || remainder `isPrefixOf` suffix))
      candidates

type PathAnchor = ((DeviceID, FileID), [FilePath])

pathAnchors :: FilePath -> IO [PathAnchor]
pathAnchors path = do
  unless (isAbsolute path && '\NUL' `notElem` path) $
    ioError (userError "configured storage root must be absolute and contain no NUL")
  canonical <- canonicalizePath path
  descend [] (splitDirectories canonical)
  where
    descend _ [] = pure []
    descend prefix (component : remaining) = do
      let next = prefix <> [component]
      inspected <- try @IOException (getSymbolicLinkStatus (joinPath next))
      case inspected of
        Left failure | isDoesNotExistError failure -> pure []
        Left failure -> throwIO failure
        Right status -> do
          unless (isDirectory status && not (isSymbolicLink status)) $
            ioError (userError "configured storage root has an unresolved link or non-directory component")
          rest <- descend next remaining
          pure (((deviceID status, fileID status), remaining) : rest)
