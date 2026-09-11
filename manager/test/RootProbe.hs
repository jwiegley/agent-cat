{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module Main (main) where

import Agentic.Manager (validateRootSeparation)
import Agentic.Runtime (closePrivateRoot, openPrivateRoot, withPrivateRoot)
import Control.Exception (IOException, bracket, finally, try)
import Control.Monad (forM_, unless)
import qualified Data.ByteString as BS
import GHC.Clock (getMonotonicTimeNSec)
import System.Directory (getTemporaryDirectory, removePathForcibly, renameDirectory)
import System.FilePath ((</>))
import qualified System.Posix.Directory as Directory
import System.Posix.Files (createNamedPipe, createSymbolicLink)

main :: IO ()
main = do
  temporary <- getTemporaryDirectory
  stamp <- getMonotonicTimeNSec
  let bucket = temporary </> ("agentic-manager-roots-" <> show stamp)
      managerPath = bucket </> "manager"
      neighbour = bucket </> "manager-neighbour"
      alias = bucket </> "alias"
      dangling = bucket </> "dangling"
      ordinary = bucket </> "ordinary"
      fifo = bucket </> "fifo"
  Directory.createDirectory bucket 0o700
  (withPrivateRoot "manager root test" managerPath $ \manager -> do
    Directory.createDirectory neighbour 0o700
    createSymbolicLink bucket alias
    createSymbolicLink (managerPath </> "future") dangling
    BS.writeFile ordinary "untouched"
    createNamedPipe fifo 0o600
    forM_ [managerPath, bucket, managerPath </> "new" </> "nested", alias </> "manager", alias </> "manager" </> "new", dangling] $ \local ->
      refuses "overlapping root was accepted" (validateRootSeparation manager [local])
    validateRootSeparation manager [neighbour, bucket </> "new-local", alias </> "new-local"]
    forM_ ["relative", bucket <> "\NULsuffix", ordinary, ordinary </> "child", fifo] $ \local ->
      refuses "invalid root was accepted" (validateRootSeparation manager [local])
    withPrivateRoot "aliased manager test" (alias </> "manager") $ \aliased -> do
      refuses "manager alias bypassed overlap check" (validateRootSeparation aliased [managerPath])
      validateRootSeparation aliased [neighbour]
    bracket (openPrivateRoot "closed manager test" managerPath) closePrivateRoot $ \closed -> do
      closePrivateRoot closed
      refuses "closed root bypassed empty-list validation" (validateRootSeparation closed [])
    let moved = managerPath <> "-moved"
    renameDirectory managerPath moved
    Directory.createDirectory managerPath 0o700
    refuses "replaced root bypassed empty-list validation" (validateRootSeparation manager [])
    removePathForcibly managerPath
    renameDirectory moved managerPath
    bytes <- BS.readFile ordinary
    unless (bytes == "untouched") (ioError (userError "root validation changed fixture bytes")))
    `finally` removePathForcibly bucket
  putStrLn "manager root checks passed: equality, nesting, aliases, missing paths, invalid roots and retained identity"

refuses :: String -> IO () -> IO ()
refuses message action = do
  result <- try @IOException action
  case result of
    Left _ -> pure ()
    Right () -> ioError (userError message)
