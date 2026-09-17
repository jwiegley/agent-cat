{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module RootRoleTests (rootRoleTests, rootRoleBucketEvidenceData) where

import Agentic.Runtime
import CaptureTests (withCaptureBucket, bucketEvidenceChecks)
import Control.Exception (IOException, bracket, try)
import Control.Monad (forM_, unless, void)
import qualified Data.ByteString as BS
import Data.Bits ((.&.))
import Foreign.C.Error (throwErrnoIfMinus1Retry)
import Foreign.C.Types (CInt (..))
import System.Directory (getTemporaryDirectory, listDirectory, removePathForcibly, renameDirectory)
import System.FilePath ((</>))
import qualified System.Posix.Directory as Directory
import System.Posix.Files (createNamedPipe, createSymbolicLink, fileID, fileMode, getFileStatus, setFileMode)
import System.Posix.IO (OpenFileFlags (cloexec, directory, nofollow), OpenMode (ReadOnly), closeFd, defaultFileFlags, openFd)
import System.Posix.Types (Fd (..))

rootRoleTests :: IO ()
rootRoleTests = do
  rootRoleBucketEvidenceData
  temporary <- getTemporaryDirectory
  withCaptureBucket "agentic-root-roles-" temporary $ \bucket -> do
    let marker = ".agentic-root-role.json"
        canonical = "{\"version\":1,\"role\":\"manager\"}\n"
        fixture name action = withPrivateRoot "role fixture" (bucket </> name) $ \root -> do
          mapM_ syncDirectory [privateRootPath root, bucket, temporary]
          action root
    withLocalStateRoot "new local state" (bucket </> "new-local" </> "state") $ \root -> do
      assertLocalStateRoot root
      status <- getFileStatus (privateRootPath root)
      check "local creation retains private root mode" (fileMode status .&. 0o777 == 0o700)
    fixture "manager" $ \root -> do
      assertLocalStateRoot root
      withPrivateDirectoryAt root [] readStateRootRoleAt >>= check "unmarked root is not an ownership claim" . (== UnmarkedStateRoot)
      establishManagerRootRole root
      status <- getFileStatus (privateRootPath root </> marker)
      check "manager marker has private mode" (fileMode status .&. 0o777 == 0o600)
      bytes <- readPrivateFileAt root [marker] 256
      check "manager role uses exact canonical bytes" (bytes == canonical)
      withPrivateDirectoryAt root [] readStateRootRoleAt >>= check "manager role is recorded" . (== ManagerStateRoot)
      refuses "manager root passed local guard" (assertLocalStateRoot root)
      before <- listDirectory (privateRootPath root)
      refuses "manager root was opened for local use" (withLocalStateRoot "local" (privateRootPath root) (const (pure ())))
      refuses "local creation entered a manager namespace" (withLocalStateRoot "local" (privateRootPath root </> "missing" </> "state") (const (pure ())))
      after <- listDirectory (privateRootPath root)
      check "refused local creation does not change manager directories" (before == after)
      writePrivateExclusiveAt root ["generic"] "manager access remains possible"
      establishManagerRootRole root
      again <- getFileStatus (privateRootPath root </> marker)
      check "existing role is synchronized without replacement" (fileID status == fileID again)
      createPrivateDirectoryAt root ["nested"]
      bracket (openPrivateSubroot root ["nested"]) closePrivateRoot $ \nested -> do
        withPrivateDirectoryAt nested [] readStateRootRoleAt >>= check "exact marker read does not invent inherited data" . (== UnmarkedStateRoot)
        refuses "nested local root ignored ancestor manager role" (assertLocalStateRoot nested)
        refuses "nested manager root was reassigned" (establishManagerRootRole nested)
      createSymbolicLink (privateRootPath root) (bucket </> "alias")
      withPrivateRoot "aliased descendant" (bucket </> "alias" </> "nested") $ \nested ->
        refuses "alias hid inherited manager role" (assertLocalStateRoot nested)
      withPrivateDirectoryAt root [] $ \descriptor -> do
        let original = privateRootPath root
            moved = original <> "-moved"
        renameDirectory original moved
        Directory.createDirectory original 0o700
        readStateRootRoleAt descriptor >>= check "role reader retains descriptor identity" . (== ManagerStateRoot)
        refuses "changed root bypassed local identity guard" (assertLocalStateRoot root)
        listDirectory original >>= check "replacement root remains untouched" . null
        removePathForcibly original
        renameDirectory moved original
    fixture "local" $ \root -> do
      writePrivateExclusiveAt root ["history"] "preserved"
      refuses "existing local namespace was claimed" (establishManagerRootRole root)
      assertLocalStateRoot root
      readPrivateFileAt root ["history"] 9 >>= check "local history remains unchanged" . (== "preserved")
      listDirectory (privateRootPath root) >>= check "failed claim leaves no marker or temporary" . (== ["history"])
    forM_ (zip [0 :: Int ..] ["", "{}", "{\"version\":2,\"role\":\"manager\"}\n", "{\"version\":1,\"role\":\"local\"}\n", "{\"version\":1,\"role\":\"manager\",\"extra\":0}\n", "{\"version\":1,\"role\":\"manager\",\"role\":\"local\"}\n", "{ \"version\":1,\"role\":\"manager\"}\n", BS.replicate 257 120]) $ \(index, contents) ->
      fixture ("invalid-" <> show index) $ \root -> do
        writePrivateExclusiveAt root [marker] contents
        rejectsMarker root
        actual <- BS.readFile (privateRootPath root </> marker)
        check "invalid marker was not repaired or removed" (actual == contents)
    fixture "permissions" $ \root -> do
      writePrivateExclusiveAt root [marker] canonical
      setFileMode (privateRootPath root </> marker) 0o644
      rejectsMarker root
    fixture "fifo" $ \root -> do
      createNamedPipe (privateRootPath root </> marker) 0o600
      rejectsMarker root
    forM_ [False, True] $ \present -> fixture ("symlink-" <> show present) $ \root -> do
      if present then writePrivateExclusiveAt root ["target"] canonical else pure ()
      createSymbolicLink "target" (privateRootPath root </> marker)
      rejectsMarker root
    fixture "invalid-parent" $ \root -> do
      writePrivateExclusiveAt root [marker] "invalid"
      createPrivateDirectoryAt root ["child"]
      bracket (openPrivateSubroot root ["child"]) closePrivateRoot $ \child -> do
        refuses "invalid ancestor marker became local absence" (assertLocalStateRoot child)
        refuses "invalid ancestor marker allowed manager claim" (establishManagerRootRole child)
  putStrLn "root role checks passed: canonical private markers, durable establishment, inherited refusals, retained identity and legacy access"

rootRoleBucketEvidenceData :: IO ()
rootRoleBucketEvidenceData = do
  bucketEvidenceChecks "agentic-root-roles-"
  putStrLn "PASS root role bucket evidence data-only checks"

rejectsMarker :: PrivateRoot -> IO ()
rejectsMarker root = do
  refuses "invalid marker became unmarked root" (withPrivateDirectoryAt root [] (void . readStateRootRoleAt))
  refuses "invalid marker passed local guard" (assertLocalStateRoot root)
  refuses "invalid marker was replaced by manager claim" (establishManagerRootRole root)

refuses :: String -> IO () -> IO ()
refuses message action = do
  result <- try @IOException action
  case result of
    Left _ -> pure ()
    Right () -> ioError (userError message)

check :: String -> Bool -> IO ()
check message value = unless value (ioError (userError message))

syncDirectory :: FilePath -> IO ()
syncDirectory path = bracket (openFd path ReadOnly defaultFileFlags {directory = True, nofollow = True, cloexec = True}) closeFd $ \(Fd descriptor) ->
  void (throwErrnoIfMinus1Retry "role fixture synchronization" (syncFixture descriptor))

foreign import ccall safe "agentic_sync_private_descriptor" syncFixture :: CInt -> IO CInt
