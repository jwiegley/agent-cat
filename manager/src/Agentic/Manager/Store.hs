{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- | A single leased SQLite writer with strict, bounded transaction results.
module Agentic.Manager.Store
  ( CoordinationStore, StoreIdentity (..), StoreFailure (..), Checkpoint (..),
    withCoordinationStore, storeIdentity, checkpointStore, withStoreConfiguration, withStoreCatalogues, withStoreFiles, withStoreAdmission, withStoreWorker, StoreWorker, createStoreWorkerGroup, storeWorkerCleanupConfirmed, retryStoreCleanup, probeStoreCapabilities,
    CommitDeadline, withCommitDeadline, withPreparedCommitDeadline, enforceCommitDeadline, Transaction, execute, query, refuseTransaction, runTransaction, runRead, StoreAdmission (..), runTransactionWithAdmission, runReadWithAdmission, transactionGeneration,
    Invalidation (..)
  ) where

import Agentic.Manager.Store.Admission (StoreAdmission (..))
import qualified Agentic.Manager.Store.Admission as Admission
import Agentic.Manager.Configuration
  (InstalledConfiguration, acquireConfigurationStorage, releaseConfigurationStorage, withConfigurationSnapshot, withConfigurationCatalogues, probeConfiguredCapabilities)
import Agentic.Manager.Profile (ConfigurationLimits, PublicProfile, Diagnostic, Discovery)
import Agentic.Manager.Worker.State (WorkerLifecycle, acceptingPreparation)
import Agentic.Manager.Lease (duplicateLease)
import Agentic.Manager.Schema (schemaVersion, schemaStatements, commandMigration, draftMigration, admissionMigration, approvalMigration, ingestionMigration, controlMigration, artifactMigration)
import Agentic.Runtime
  (PrivateRoot, assertPrivateRoot, closePrivateRoot, openPrivateSubroot, privateRootPath,
   withPrivateDirectoryAt, writePrivateExclusiveAt, WorkflowInputDescriptor (..), frontendLiteralBytes, FrontendCapabilities, ProcessGroup, createProcessGroup, terminateProcessGroup, groupOutcome, processGroupLive)
import Control.Concurrent (rtsSupportsBoundThreads)
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (race, withAsync, asyncWithUnmask, cancel, wait)
import Control.Concurrent.STM (STM, TMVar, atomically, newEmptyTMVarIO, readTMVar, isEmptyTMVar, tryPutTMVar)
import Control.Concurrent.MVar (MVar, newMVar, newEmptyMVar, readMVar, tryReadMVar, withMVar, modifyMVarMasked, takeMVar, putMVar, tryTakeMVar)
import Control.Exception
  (Exception, SomeException, bracket, bracketOnError, finally, mask,
   evaluate, uninterruptibleMask_, throwIO, try, onException, catch)
import Control.Monad (unless, when, void, foldM, forM_, forever)
import Control.DeepSeq (NFData, force)
import Crypto.Hash (Digest, SHA256, hashInit, hashUpdate, hashFinalize)
import qualified Crypto.Hash as Hash
import Data.ByteArray (convert)
import Data.Aeson (eitherDecodeStrict')
import Crypto.Random (getRandomBytes)
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import qualified Data.ByteString as BS
import Data.Int (Int64)
import Data.Word (Word64)
import Data.Bits ((.&.))
import Data.Char (isAlphaNum, isAscii, isSpace)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Database.SQLite3 as SQL
import qualified Database.SQLite3.Direct as Direct
import Foreign.C.Types (CInt (..))
import Foreign.Ptr (Ptr)
import System.FilePath ((</>))
import System.IO.Error (isDoesNotExistError)
import Control.Exception (IOException)
import System.Posix.IO
  (OpenFileFlags (cloexec, nofollow, nonBlock), OpenMode (ReadOnly),
   closeFd, defaultFileFlags, openFdAt)
import System.Posix.Files (fileMode, fileOwner, getFdStatus, isRegularFile, linkCount)
import System.Process (CreateProcess)
import System.Posix.Types (Fd)
import System.Posix.User (getEffectiveUserID)
import System.Timeout (timeout)

-- | Durable identities and one fresh lifetime identifier, never live worker authority.
data StoreIdentity = StoreIdentity
  { storeSchemaVersion :: !Int,
    storeAuthorityEpoch :: !Text,
    storeStreamId :: !Text,
    storeProcessGeneration :: !Text
  } deriving (Eq, Show)

-- | Fixed storage refusals. SQLite details and bound private data are not public diagnostics.
data StoreFailure = StoreBusy | StoreClosed | StorePoisoned | StoreLimit
  | StoreDeadline | StoreVersion | StoreIntegrity | StoreUnavailable | StoreCleanupUnproven
  deriving (Eq, Show)
instance Exception StoreFailure

-- | Observed passive checkpoint progress, not a promise of truncation or power-loss safety.
data Checkpoint = Checkpoint
  { checkpointBusy :: !Bool, checkpointLogPages :: !Int64, checkpointedPages :: !Int64
  } deriving (Eq, Show)

-- | One connection and admission cell. Ordinary calls fail fast, terminal-owner
-- persistence can spend its existing operation allowance waiting for the cell.
data CoordinationStore = CoordinationStore !InstalledConfiguration !PrivateRoot !SQL.Database !StoreIdentity
  !(MVar ()) !(IORef Bool) !(IORef Bool) !Fd !(MVar ()) !(MVar (Bool, [StoreWorker])) !(MVar ()) !(IORef Bool) !(MVar (Bool, Maybe (TMVar (), MVar ())))

-- | One in-memory lifetime notification and joined release, not PID authority.
data StoreWorker = StoreWorker !(TMVar ()) !(MVar ()) !(MVar [ProcessGroup]) !(MVar (Maybe (PrivateRoot, Fd)))

-- | A manager-only transaction program. No IO lift, connection or cursor is exported.
newtype Transaction a = Transaction (Context -> IO a)
data Context = Context !SQL.Database !Text !Bool !(IORef Budget) !(IORef Bool) !(IORef (Maybe CommitDeadline))
data Budget = Budget !Int !Int !Int !Int

instance Functor Transaction where
  fmap f (Transaction action) = Transaction (fmap f . action)
instance Applicative Transaction where
  pure value = Transaction (const (pure value))
  Transaction f <*> Transaction x = Transaction $ \context -> f context <*> x context
instance Monad Transaction where
  Transaction action >>= next = Transaction $ \context -> do
    value <- action context
    let Transaction continuation = next value
    continuation context

-- | One bounded invalidation, appended in the same commit as the owning mutation.
data Invalidation = Invalidation !Text !Text !Text deriving (Eq, Show)

withCoordinationStore :: InstalledConfiguration -> (CoordinationStore -> IO a) -> IO a
withCoordinationStore installed action = mask $ \restore -> do
  unless rtsSupportsBoundThreads (throwIO StoreUnavailable)
  let acquire = bracketOnError (acquireConfigurationStorage installed) release $ \(root, lease) ->
        openStore installed root lease
      release (root, lease) =
        (closePrivateRoot root `finally` closeFd lease) `finally` releaseConfigurationStorage installed
  store <- acquire
  result <- try @SomeException (restore (action store))
  cleanup <- try @SomeException (closeStore store)
  case result of
    Left failure -> throwIO failure
    Right value -> either throwIO (const (pure value)) cleanup

openStore :: InstalledConfiguration -> PrivateRoot -> Fd -> IO CoordinationStore
openStore installed root lease = storageErrors $ do
  -- Stable operator-controlled paths are required. Runtime still checks private files.
  existing <- try @IOException (checkPrivateFile root databaseName)
  case existing of
    Left failure | isDoesNotExistError failure -> writePrivateExclusiveAt root [databaseName] BS.empty
    Left failure -> throwIO failure
    Right () -> pure ()
  mapM_ checkCompanion [databaseName <> "-wal", databaseName <> "-shm", databaseName <> "-journal"]
  bracketOnError (SQL.open2 (T.pack (privateRootPath root </> databaseName))
      [SQL.SQLOpenReadWrite, SQL.SQLOpenFullMutex, SQL.SQLOpenNoFollow, SQL.SQLOpenPrivateCache]
      SQL.SQLVFSDefault) SQL.close $ \db -> do
    let Direct.Database raw = db
    sqliteLimits raw
    generation <- freshIdentity "generation_"
    (epoch, stream) <- bounded db 30000000 $ do
      SQL.exec db "PRAGMA busy_timeout=100; PRAGMA foreign_keys=ON; PRAGMA temp_store=FILE; PRAGMA cache_size=-2048; PRAGMA temp.cache_size=-2048"
      version <- scalar db "PRAGMA user_version"
      unless (version `elem` map SQL.SQLInteger [0, 1, 2, 3, 4, 5, 6, 7, fromIntegral schemaVersion]) $
        throwIO StoreVersion
      -- Newer versions are refused before changing their journal or schema.
      wal <- scalar db "PRAGMA journal_mode=WAL"
      unless (wal == SQL.SQLText "wal") (throwIO StoreUnavailable)
      SQL.exec db "PRAGMA synchronous=FULL; PRAGMA wal_autocheckpoint=0; PRAGMA journal_size_limit=16777216"
      verifyPragmas db
      migrate db
      values <- rawRows db "SELECT authority_epoch,stream_id FROM service_metadata WHERE singleton=1" []
      case values of
        [[SQL.SQLText epoch, SQL.SQLText stream]] -> pure (epoch, stream)
        _ -> throwIO StoreIntegrity
    CoordinationStore installed root db (StoreIdentity schemaVersion epoch stream generation)
      <$> newMVar () <*> newIORef False <*> newIORef False <*> pure lease <*> newMVar () <*> newMVar (False, []) <*> newMVar () <*> newIORef False <*> newMVar (False, Nothing)
  where
    databaseName = "coordination.sqlite3"
    checkCompanion name = do
      result <- try @IOException (checkPrivateFile root name)
      case result of
        Left failure | isDoesNotExistError failure -> pure ()
        Left failure -> throwIO failure
        Right () -> pure ()

-- Runtime owns directory traversal for the database and its named companions.
-- SQLite also owns native private temporary files outside this root.
checkPrivateFile :: PrivateRoot -> FilePath -> IO ()
checkPrivateFile root name = withPrivateDirectoryAt root [] $ \parent ->
  bracket (openFdAt (Just parent) name ReadOnly
    defaultFileFlags {cloexec = True, nofollow = True, nonBlock = True}) closeFd $ \fd -> do
      status <- getFdStatus fd
      owner <- getEffectiveUserID
      unless (isRegularFile status && fileOwner status == owner && fileMode status .&. 0o777 == 0o600
              && linkCount status == 1) (throwIO StoreUnavailable)

freshIdentity :: Text -> IO Text
freshIdentity prefix = do
  bytes <- getRandomBytes 32 :: IO BS.ByteString
  pure (prefix <> TE.decodeUtf8 (convertToBase Base16 bytes))

verifyPragmas :: SQL.Database -> IO ()
verifyPragmas db = mapM_ verify
  [("PRAGMA journal_mode", SQL.SQLText "wal"), ("PRAGMA synchronous", SQL.SQLInteger 2),
   ("PRAGMA foreign_keys", SQL.SQLInteger 1), ("PRAGMA busy_timeout", SQL.SQLInteger 100),
   ("PRAGMA wal_autocheckpoint", SQL.SQLInteger 0), ("PRAGMA temp_store", SQL.SQLInteger 1),
   ("PRAGMA cache_size", SQL.SQLInteger (-2048)), ("PRAGMA temp.cache_size", SQL.SQLInteger (-2048)),
   ("SELECT sqlite_compileoption_used('TEMP_STORE=3')", SQL.SQLInteger 0)]
  where
    verify (sql, expected) = scalar db sql >>= \actual ->
      unless (actual == expected) (throwIO StoreUnavailable)

migrate :: SQL.Database -> IO ()
migrate db = mask $ \restore -> do
  SQL.exec db "BEGIN IMMEDIATE"
  result <- try @SomeException $ restore $ do
    version <- scalar db "PRAGMA user_version"
    case version of
      SQL.SQLInteger 0 -> do
        mapM_ (SQL.exec db) schemaStatements
        epoch <- freshIdentity "authority_"
        stream <- freshIdentity "stream_"
        rawExecute db "INSERT INTO service_metadata VALUES (1,?,?,'0','0','service_1')"
          [SQL.SQLText epoch, SQL.SQLText stream]
        SQL.exec db "PRAGMA user_version=1"
      SQL.SQLInteger 1 -> pure ()
      SQL.SQLInteger 2 -> pure ()
      SQL.SQLInteger 3 -> pure ()
      SQL.SQLInteger 4 -> pure ()
      SQL.SQLInteger 5 -> pure ()
      SQL.SQLInteger 6 -> pure ()
      SQL.SQLInteger 7 -> pure ()
      SQL.SQLInteger current | current == fromIntegral schemaVersion -> pure ()
      _ -> throwIO StoreVersion
    when (version `elem` [SQL.SQLInteger 0, SQL.SQLInteger 1]) $ do
      mapM_ (SQL.exec db) commandMigration
      SQL.exec db "PRAGMA user_version=2"
    when (version `elem` [SQL.SQLInteger 0, SQL.SQLInteger 1, SQL.SQLInteger 2]) $ do
      mapM_ (SQL.exec db) draftMigration
      migrateLiteralDigests db Nothing
      SQL.exec db "PRAGMA user_version=3"
    when (version `elem` map SQL.SQLInteger [0,1,2,3]) $ do
      invalid <- scalar db "SELECT count(*) FROM requests WHERE queue_ordinal IS NOT NULL AND NOT(length(queue_ordinal) BETWEEN 1 AND 20 AND queue_ordinal NOT GLOB '*[^0-9]*' AND (queue_ordinal='0' OR substr(queue_ordinal,1,1) BETWEEN '1' AND '9') AND (length(queue_ordinal)<20 OR queue_ordinal<='18446744073709551615'))"
      unless (invalid==SQL.SQLInteger 0) (throwIO StoreIntegrity)
      mapM_ (SQL.exec db) admissionMigration
      SQL.exec db "PRAGMA user_version=4"
    when (version `elem` map SQL.SQLInteger [0,1,2,3,4]) $ do
      mapM_ (SQL.exec db) approvalMigration
      SQL.exec db "PRAGMA user_version=5"
    when (version `elem` map SQL.SQLInteger [0,1,2,3,4,5]) $ do
      mapM_ (SQL.exec db) ingestionMigration
      SQL.exec db "PRAGMA user_version=6"
    when (version `elem` map SQL.SQLInteger [0,1,2,3,4,5,6]) $ do
      mapM_ (SQL.exec db) controlMigration
      SQL.exec db "PRAGMA user_version=7"
    when (version /= SQL.SQLInteger (fromIntegral schemaVersion)) $ do
      mapM_ (SQL.exec db) artifactMigration
      SQL.exec db "PRAGMA user_version=8"
    SQL.exec db "COMMIT"
  case result of
    Right () -> pure ()
    Left failure -> do
      -- Startup never publishes a reusable connection after any migration failure.
      void (try @SomeException (rollback db))
      throwIO failure

-- SQL copies the old bytes into bounded chunks. Hashing never reads an oversized row.
migrateLiteralDigests :: SQL.Database -> Maybe Int64 -> IO ()
migrateLiteralDigests db after = do
  let (condition, parameters) = case after of
        Nothing -> ("", [])
        Just row -> (" AND rowid>?", [SQL.SQLInteger row])
  rows <- rawRows db ("SELECT rowid,literal_chunks,length(declaration) FROM request_inputs WHERE source='literal'" <> condition <> " ORDER BY rowid LIMIT 100") parameters
  case rows of
    [] -> pure ()
    _ -> do
      lastRow <- foldM migrateOne after rows
      migrateLiteralDigests db lastRow
  where
    migrateOne _ [SQL.SQLInteger row, SQL.SQLInteger count, SQL.SQLInteger declarationBytes] = do
      unless (count >= 0 && count <= 32) (throwIO StoreIntegrity)
      (digest, pieces) <- collect row count 0 (hashInit :: Hash.Context SHA256) []
      -- Never batch declaration blobs or parse a truncated prefix as a declaration.
      declaration <- if declarationBytes <= 1048576 then do
          values <- rawRows db "SELECT declaration FROM request_inputs WHERE rowid=?" [SQL.SQLInteger row]
          case values of
            [[SQL.SQLBlob bytes]] -> pure (eitherDecodeStrict' bytes :: Either String WorkflowInputDescriptor)
            _ -> throwIO StoreIntegrity
        else pure (Left "declaration exceeds derivation budget")
      let transport = case (declaration, TE.decodeUtf8' (BS.concat (reverse pieces))) of
            (Right input, Right value) -> SQL.SQLInteger (fromIntegral (BS.length (frontendLiteralBytes (workflowInputSource input) value)))
            _ -> SQL.SQLNull
      rawExecute db "UPDATE request_inputs SET literal_digest=?,literal_transport_bytes=? WHERE rowid=?"
        [SQL.SQLBlob (convert (hashFinalize digest :: Digest SHA256)), transport, SQL.SQLInteger row]
      pure (Just row)
    migrateOne _ _ = throwIO StoreIntegrity
    collect row count index !context pieces
      | index == count = pure (context, pieces)
      | otherwise = do
          rows <- rawRows db "SELECT c.bytes FROM request_literal_chunks c JOIN request_inputs i ON i.request_id=c.request_id AND i.name=c.name WHERE i.rowid=? AND c.ordinal=?"
            [SQL.SQLInteger row, SQL.SQLInteger index]
          case rows of
            [[SQL.SQLBlob bytes]] -> collect row count (index + 1) (hashUpdate context bytes) (bytes : pieces)
            _ -> throwIO StoreIntegrity


closeStore :: CoordinationStore -> IO ()
closeStore store@(CoordinationStore installed root db _ gate closed poisoned lease files workers closing retired admission) =
  uninterruptibleMask_ $ withMVar closing $ \_ -> do
    already <- readIORef retired
    unless already $ do
      writeIORef closed True
      controller <- modifyMVarMasked admission (\(_, owner) -> pure ((True, owner), owner))
      forM_ controller $ \(stop, _) -> void (atomically (tryPutTMVar stop ()))
      active <- modifyMVarMasked workers (\(_, entries) -> pure ((True, entries), entries))
      mapM_ (\(StoreWorker stop _ _ _) -> void (atomically (tryPutTMVar stop ()))) active
      mapM_ (\(StoreWorker _ done _ _) -> readMVar done) active
      forM_ controller (readMVar . snd)
      -- Only the original Runtime tokens may resolve previously unproven completion.
      forM_ active $ \entry@(StoreWorker _ _ groups _) -> do
        owned <- readMVar groups
        forM_ owned $ \group -> void (try @SomeException (terminateProcessGroup 5000000 group))
        releaseStoreWorker store entry
      remaining <- snd <$> readMVar workers
      unless (null remaining) (throwIO StoreCleanupUnproven)
      takeMVar files
      takeMVar gate
      result <- try @SomeException (SQL.close db)
      case result of
        Right () -> do
          writeIORef retired True
          (closePrivateRoot root `finally` closeFd lease) `finally` releaseConfigurationStorage installed
        Left failure -> writeIORef poisoned True >> throwIO failure

-- | Bounded recheck of retained original ownership, never PID or command replay.
retryStoreCleanup :: CoordinationStore -> IO ()
retryStoreCleanup = closeStore

-- | Configuration authority associated with this store, never a caller-selected registry.
withStoreConfiguration :: CoordinationStore -> (ConfigurationLimits -> [PublicProfile] -> IO a) -> IO (Either Diagnostic a)
withStoreConfiguration (CoordinationStore installed _ _ _ _ _ _ _ _ _ _ _ _) = withConfigurationSnapshot installed

-- | Current catalogue facts from the same associated configuration and lock.
withStoreCatalogues :: CoordinationStore -> (ConfigurationLimits -> [PublicProfile] -> [(Text, Discovery)] -> IO a) -> IO (Either Diagnostic a)
withStoreCatalogues (CoordinationStore installed _ _ _ _ _ _ _ _ _ _ _ _) = withConfigurationCatalogues installed

-- | One fail-fast file operation, joined by store close. Lock order: file, configuration, database.
-- The retained root and duplicated lease cannot escape this callback's lifetime.
withStoreFiles :: CoordinationStore -> (PrivateRoot -> IO a) -> IO a
withStoreFiles store@(CoordinationStore _ root _ _ _ closed _ lease files _ _ _ _) action = mask $ \restore -> do
  readIORef closed >>= \done -> when done (throwIO StoreClosed)
  acquired <- tryTakeMVar files
  case acquired of
    Nothing -> throwIO StoreBusy
    Just () -> (bracket acquire release (\(retained, _) -> restore (action retained))) `finally` putMVar files ()
  where
    acquire = admitted store $ bracketOnError (openPrivateSubroot root []) closePrivateRoot $ \retained -> do
      copied <- duplicateLease lease
      pure (retained, copied)
    release (retained, copied) = closePrivateRoot retained `finally` closeFd copied

-- | One admission owner, separate from the physical worker registration ceiling.
withStoreAdmission :: CoordinationStore -> (STM Bool -> IO a) -> IO a
withStoreAdmission (CoordinationStore _ _ _ _ _ closed _ _ _ _ _ _ admission) action = mask $ \restore -> do
  stop <- newEmptyTMVarIO
  done <- newEmptyMVar
  modifyMVarMasked admission $ \(fenced, current) -> do
    closing <- readIORef closed
    when (fenced || closing) (throwIO StoreClosed)
    case current of
      Just _ -> throwIO StoreBusy
      Nothing -> pure ((False, Just (stop, done)), ())
  result <- try @SomeException (restore (action (isEmptyTMVar stop)))
  atomically (void (tryPutTMVar stop ()))
  modifyMVarMasked admission (\(fenced, _) -> pure ((fenced, Nothing), ()))
  putMVar done ()
  either throwIO pure result

-- | A separate bounded lifetime for workers. Close signals and joins it without SQL.
withStoreWorker :: CoordinationStore -> (StoreWorker -> PrivateRoot -> STM Bool -> IO a) -> IO a
withStoreWorker store@(CoordinationStore _ root _ _ _ _ _ lease _ workers _ _ _) action = mask $ \restore -> do
  entry@(StoreWorker stop done _ resources) <- StoreWorker <$> newEmptyTMVarIO <*> newEmptyMVar <*> newMVar [] <*> newMVar Nothing
  modifyMVarMasked workers $ \(fenced, entries) -> do
    when fenced (throwIO StoreCleanupUnproven)
    when (length entries >= 16) (throwIO StoreBusy)
    pure ((False, entry : entries), ())
  result <- try @SomeException $ do
    pair <- admitted store $ bracketOnError (openPrivateSubroot root []) closePrivateRoot $ \retained -> do
      copied <- duplicateLease lease
      pure (retained, copied)
    modifyMVarMasked resources (const (pure (Just pair, ())))
    raced <- restore $ race (atomically (readTMVar stop)) (action entry (fst pair) (isEmptyTMVar stop))
    either (const (throwIO StoreClosed)) pure raced
  cleanup <- try @SomeException (releaseStoreWorker store entry)
  putMVar done ()
  case result of
    Left failure -> throwIO failure
    Right value -> do
      either throwIO pure cleanup
      confirmed <- storeWorkerCleanupConfirmed entry
      unless confirmed (throwIO StoreCleanupUnproven)
      pure value

-- | Construct and attach while protected, before a process or its pipes can escape.
createStoreWorkerGroup :: StoreWorker -> CreateProcess -> IO ProcessGroup
createStoreWorkerGroup (StoreWorker stop _ groups _) command = mask $ \_ ->
  modifyMVarMasked groups $ \owned -> do
    live <- atomically (isEmptyTMVar stop)
    unless live (throwIO StoreClosed)
    when (length owned >= 2) (throwIO StoreLimit)
    group <- createProcessGroup command
    pure (group : owned, group)

storeWorkerCleanupConfirmed :: StoreWorker -> IO Bool
storeWorkerCleanupConfirmed (StoreWorker _ _ groups _) = do
  owned <- readMVar groups
  results <- mapM (tryReadMVar . groupOutcome) owned
  pure (all (\value -> case value of Just (Right _) -> True; _ -> False) results)

releaseStoreWorker :: CoordinationStore -> StoreWorker -> IO ()
releaseStoreWorker (CoordinationStore _ _ _ _ _ closed _ _ _ workers _ _ _) entry@(StoreWorker stop done _ resources) = do
  void (atomically (tryPutTMVar stop ()))
  confirmed <- storeWorkerCleanupConfirmed entry
  if confirmed then do
    retained <- modifyMVarMasked resources (\value -> pure (Nothing, value))
    forM_ retained $ \(root, lease) -> closePrivateRoot root `finally` closeFd lease
    modifyMVarMasked workers $ \(fenced, entries) -> pure
      ((fenced, filter (\(StoreWorker _ other _ _) -> other /= done) entries), ())
  else do
    writeIORef closed True
    modifyMVarMasked workers $ \(_, entries) -> pure ((True, entries), ())


probeStoreCapabilities :: CoordinationStore -> StoreWorker -> Text -> Text -> IO (Either Diagnostic FrontendCapabilities)
probeStoreCapabilities (CoordinationStore installed _ _ _ _ _ _ _ _ _ _ _ _) owner = probeConfiguredCapabilities installed (createStoreWorkerGroup owner)

storeIdentity :: CoordinationStore -> IO StoreIdentity
storeIdentity store@(CoordinationStore _ _ _ identity _ _ _ _ _ _ _ _ _) = admitted store (pure identity)

checkpointStore :: CoordinationStore -> IO Checkpoint
checkpointStore store@(CoordinationStore _ _ db _ _ _ _ _ _ _ _ _ _) = admitted store $ bounded db 5000000 $ do
  verifyPragmas db
  values <- rawRows db "PRAGMA wal_checkpoint(PASSIVE)" []
  case values of
    [[SQL.SQLInteger busy, SQL.SQLInteger pages, SQL.SQLInteger done]] -> pure (Checkpoint (busy /= 0) pages done)
    _ -> throwIO StoreIntegrity

admitted :: CoordinationStore -> IO a -> IO a
admitted store action = admittedWith FailFast store (const action)

admittedWith :: StoreAdmission -> CoordinationStore -> (Maybe Admission.Deadline -> IO a) -> IO a
admittedWith policy (CoordinationStore _ root _ _ gate closed poisoned _ _ _ _ _ _) action = do
  readIORef closed >>= \value -> when value (throwIO StoreClosed)
  let ready = do
        readIORef closed >>= \value -> when value (throwIO StoreClosed)
        readIORef poisoned >>= \value -> when value (throwIO StorePoisoned)
        assertPrivateRoot root
  storageErrors (Admission.withGate policy gate ready action) `catch` \failure ->
    throwIO (case failure of Admission.AdmissionBusy -> StoreBusy; Admission.AdmissionExpired -> StoreDeadline)

-- | Internal callers supply source-owned SQL, never SQL obtained from a client.
-- Statement count, binding bytes and strict result bytes share one transaction budget.
execute :: Text -> [SQL.SQLData] -> Transaction ()
execute sql parameters = Transaction $ \context@(Context db _ writable _ changed _) -> do
  unless writable (throwIO StoreIntegrity)
  unless (T.toUpper (T.takeWhile (not . isSpace) (T.stripStart sql)) `elem` ["INSERT", "UPDATE", "DELETE"]) $
    throwIO StoreIntegrity
  chargeInput context sql parameters
  rawExecute db sql parameters
  writeIORef changed True

query :: Text -> [SQL.SQLData] -> Transaction [[SQL.SQLData]]
query sql parameters = Transaction $ \context@(Context db _ _ budget _ _) -> do
  unless (T.toUpper (T.takeWhile (not . isSpace) (T.stripStart sql)) `elem` ["SELECT", "WITH"]) $
    throwIO StoreIntegrity
  chargeInput context sql parameters
  withStatement db sql $ \statement -> do
    let Direct.Statement raw = statement
    readonly <- statementReadonly raw
    unless (readonly /= 0) (throwIO StoreIntegrity)
    SQL.bind statement parameters
    collectRows budget statement

-- | One live owner's monotonic acceptance deadline, scoped to a protected loan.
data CommitDeadline = CommitDeadline !Text !(IO Word64) !Word64 !(IORef Bool) !(Maybe PreparedCommit)
data PreparedCommit = PreparedCommit !(MVar (Bool,[StoreWorker])) !StoreWorker !ProcessGroup !WorkerLifecycle

withCommitDeadline :: CoordinationStore -> IO Word64 -> Word64 -> (CommitDeadline -> IO a) -> IO a
withCommitDeadline (CoordinationStore _ _ _ identity _ closed _ _ _ _ _ _ _) now deadline action = mask $ \restore -> do
  readIORef closed >>= \closing -> when closing(throwIO StoreClosed)
  active <- newIORef True
  restore(action(CommitDeadline(storeProcessGeneration identity)now deadline active Nothing)) `finally` writeIORef active False

-- | The prepared variant binds the original registration, process and adapter cells.
withPreparedCommitDeadline :: CoordinationStore -> StoreWorker -> ProcessGroup -> WorkerLifecycle -> IO Word64 -> Word64 -> (CommitDeadline -> IO a) -> IO a
withPreparedCommitDeadline store@(CoordinationStore _ _ _ _ _ _ _ _ _ registry _ _ _) owner group state now deadline action =
  withCommitDeadline store now deadline $ \(CommitDeadline generation clock end active _) ->
    action(CommitDeadline generation clock end active(Just(PreparedCommit registry owner group state)))

checkPreparedCommit :: PreparedCommit -> IO ()
checkPreparedCommit (PreparedCommit registry (StoreWorker stop done groups _) group state) = do
  registered <- tryReadMVar registry
  owned <- tryReadMVar groups
  let present = case registered of
        Just(False,entries) -> any(\(StoreWorker _ registeredDone _ _)->registeredDone==done)entries
        _ -> False
      attached = case owned of
        Just entries -> any((==groupOutcome group).groupOutcome)entries
        _ -> False
      current = atomically $ do
        open <- isEmptyTMVar stop
        ready <- acceptingPreparation state
        pure(open && ready)
  ready <- current
  unless(present && attached && ready)(throwIO StoreClosed)
  living <- processGroupLive group
  readyAfter <- current
  unless(living && readyAfter)(throwIO StoreClosed)

-- | Arm one fixed final check after transactional work and invalidations, before COMMIT.
-- This adds no general IO lift or caller-supplied acceptance predicate.
enforceCommitDeadline :: CommitDeadline -> Transaction ()
enforceCommitDeadline guard@(CommitDeadline owner _ _ _ _) = Transaction $ \(Context _ generation writable _ _ pending) -> do
  unless(writable && owner==generation)(throwIO StoreIntegrity)
  existing <- readIORef pending
  case existing of
    Nothing -> writeIORef pending(Just guard)
    Just _ -> throwIO StoreIntegrity

checkCommitDeadline :: CommitDeadline -> IO ()
checkCommitDeadline (CommitDeadline _ now deadline active prepared) = do
  current <- readIORef active
  unless current(throwIO StoreDeadline)
  observed <- now
  unless(observed<deadline)(throwIO StoreDeadline)
  mapM_ checkPreparedCommit prepared

-- | The current in-memory lifetime, never reconstructed from a database row.
transactionGeneration :: Transaction Text
transactionGeneration = Transaction $ \(Context _ generation _ _ _ _) -> pure generation

refuseTransaction :: Exception e => e -> Transaction a
refuseTransaction failure = Transaction (const (throwIO failure))

runRead :: NFData a => CoordinationStore -> Transaction a -> IO a
runRead store transaction = run store False ((\value -> (value, [])) <$> transaction)

runTransaction :: NFData a => CoordinationStore -> Transaction (a, [Invalidation]) -> IO a
runTransaction store transaction = run store True transaction

-- | Explicit admission policy for one read. Waiting creates no replay authority.
runReadWithAdmission :: NFData a => StoreAdmission -> CoordinationStore -> Transaction a -> IO a
runReadWithAdmission policy store transaction = runWithAdmission policy store False ((\value -> (value, [])) <$> transaction)

-- | Explicit admission policy for one transaction, preserving the original fences.
runTransactionWithAdmission :: NFData a => StoreAdmission -> CoordinationStore -> Transaction (a, [Invalidation]) -> IO a
runTransactionWithAdmission policy store transaction = runWithAdmission policy store True transaction

run :: NFData a => CoordinationStore -> Bool -> Transaction (a, [Invalidation]) -> IO a
run = runWithAdmission FailFast

runWithAdmission :: NFData a => StoreAdmission -> CoordinationStore -> Bool -> Transaction (a, [Invalidation]) -> IO a
runWithAdmission policy store@(CoordinationStore _ _ db identity _ _ poisoned _ _ _ _ _ _) writable (Transaction action) = admittedWith policy store $ \end -> do
  committing <- newIORef False
  changed <- newIORef False
  budget <- newIORef (Budget 256 8388608 1000 1048576)
  deadline <- newIORef Nothing
  mask $ \restore -> do
    result <- try @SomeException $ restore $ boundedWith db (maybe (pure 5000000) Admission.remainingMicros end) $ do
      mapM_ (void . Admission.remainingMicros) end
      SQL.exec db (if writable then "BEGIN IMMEDIATE" else "BEGIN")
      (resultValue, events) <- action (Context db (storeProcessGeneration identity) writable budget changed deadline)
      validateEvents events
      value <- evaluate (force resultValue)
      didChange <- readIORef changed
      when (didChange && null events) (throwIO StoreIntegrity)
      mapM_ (appendInvalidation db) events
      readIORef deadline >>= mapM_ checkCommitDeadline
      writeIORef committing True
      SQL.exec db "COMMIT"
      pure value
    case result of
      Right value -> pure value
      Left failure -> do
        uncertain <- readIORef committing
        cleanup <- try @SomeException (bounded db 5000000 (rollback db))
        when (uncertain || either (const True) (const False) cleanup) (writeIORef poisoned True)
        throwIO failure

rollback :: SQL.Database -> IO ()
rollback db@(Direct.Database raw) = do
  automatic <- getAutocommit raw
  when (automatic == 0) (SQL.exec db "ROLLBACK")

validateEvents :: [Invalidation] -> IO ()
validateEvents = go (256 :: Int)
  where
    go _ [] = pure ()
    go 0 (_ : _) = throwIO StoreLimit
    go remaining (Invalidation kind uri revision : rest) = do
      unless (kind `elem` ["request.changed", "preparation.changed", "run.changed", "decision.changed",
                          "command.changed", "artifact.changed", "service.changed"]
              && T.length uri > 4 && T.length uri <= 8192 && T.isPrefixOf "/v1/" uri
              && T.all (\c -> identifierChar c || c `elem` ("/?=&.%" :: String)) uri
              && T.length revision > 0 && T.length revision <= 128
              && T.all identifierChar revision) (throwIO StoreLimit)
      go (remaining - 1) rest
    identifierChar c = isAscii c && (isAlphaNum c || c == '_' || c == '-')

appendInvalidation :: SQL.Database -> Invalidation -> IO ()
appendInvalidation db (Invalidation kind uri revision) = do
  old <- scalar db "SELECT sequence FROM service_metadata WHERE singleton=1"
  sequenceNumber <- case old of
    SQL.SQLText text -> case reads (T.unpack text) of
      [(n, "")] | (n :: Integer) >= 0 && n < 18446744073709551615 -> pure (T.pack (show (n + 1)))
      _ -> throwIO StoreLimit
    _ -> throwIO StoreIntegrity
  rawExecute db "UPDATE service_metadata SET sequence=? WHERE singleton=1" [SQL.SQLText sequenceNumber]
  rawExecute db "INSERT INTO invalidations SELECT stream_id,sequence,?,?,? FROM service_metadata WHERE singleton=1"
    [SQL.SQLText kind, SQL.SQLText uri, SQL.SQLText revision]

chargeInput :: Context -> Text -> [SQL.SQLData] -> IO ()
chargeInput (Context _ _ _ budget _ _) sql parameters = do
  when (T.length sql > 65536 || T.any (`elem` ['\0', ';']) sql) (throwIO StoreLimit)
  let sqlBytes = BS.length (TE.encodeUtf8 sql)
  when (sqlBytes > 65536) (throwIO StoreLimit)
  bytes <- countParameters (256 :: Int) 0 parameters
  Budget statements input rows result <- readIORef budget
  when (statements <= 0 || bytes + sqlBytes > input) (throwIO StoreLimit)
  writeIORef budget (Budget (statements - 1) (input - bytes - sqlBytes) rows result)
  where
    countParameters _ !total [] = pure total
    countParameters 0 _ (_ : _) = throwIO StoreLimit
    countParameters remaining !total (value : rest) = do
      size <- dataBytes value
      when (size > 2097152 || total + size > 8388608) (throwIO StoreLimit)
      countParameters (remaining - 1) (total + size) rest
    dataBytes (SQL.SQLBlob value) = pure (BS.length value)
    dataBytes (SQL.SQLText value) = do
      when (T.length value > 2097152) (throwIO StoreLimit)
      pure (BS.length (TE.encodeUtf8 value))
    dataBytes _ = pure 8

collectRows :: IORef Budget -> SQL.Statement -> IO [[SQL.SQLData]]
collectRows budget statement = loop []
  where
    loop !acc = do
      result <- SQL.step statement
      case result of
        SQL.Done -> pure (reverse acc)
        SQL.Row -> do
          Budget statements input rows bytes <- readIORef budget
          let Direct.Statement raw = statement
          size <- rowBytes raw
          when (rows <= 0 || size > fromIntegral bytes) (throwIO StoreLimit)
          -- Account before copying SQLite-owned text/blob values into Haskell.
          writeIORef budget (Budget statements input (rows - 1) (bytes - fromIntegral size))
          row <- SQL.columns statement
          loop (row : acc)

rawRows :: SQL.Database -> Text -> [SQL.SQLData] -> IO [[SQL.SQLData]]
rawRows db sql parameters = withStatement db sql $ \statement -> do
  SQL.bind statement parameters
  budget <- newIORef (Budget 1 0 1000 1048576)
  collectRows budget statement

scalar :: SQL.Database -> Text -> IO SQL.SQLData
scalar db sql = rawRows db sql [] >>= \values -> case values of
  [[value]] -> pure value
  _ -> throwIO StoreIntegrity

rawExecute :: SQL.Database -> Text -> [SQL.SQLData] -> IO ()
rawExecute db sql parameters = withStatement db sql $ \statement -> do
  SQL.bind statement parameters
  result <- SQL.step statement
  unless (result == SQL.Done) (throwIO StoreIntegrity)

withStatement :: SQL.Database -> Text -> (SQL.Statement -> IO a) -> IO a
withStatement db sql action = mask $ \restore -> do
  statement <- SQL.prepare db sql
  result <- try @SomeException (restore (action statement))
  cleanup <- try @SomeException (SQL.finalize statement)
  -- SQLite destroys the statement even when finalize reports its last step error.
  -- Preserve the original exception, particularly asynchronous cancellation.
  case result of
    Left failure -> throwIO failure
    Right value -> either throwIO (const (pure value)) cleanup

bounded :: SQL.Database -> Int -> IO a -> IO a
bounded db micros = boundedWith db (pure micros)

boundedWith :: SQL.Database -> IO Int -> IO a -> IO a
boundedWith db remaining action = mask $ \restore ->
  withAsync (restore action) $ \running -> do
    -- One interrupt can precede sqlite3_step and do nothing. Keep interrupting
    -- the original action until it joins; join the interrupter before reuse.
    let stop = uninterruptibleMask_ $
          bracket (asyncWithUnmask (\unmask -> unmask (forever (SQL.interrupt db >> threadDelay 1000)))) cancel
            (\_ -> cancel running)
    result <- restore (remaining >>= \micros -> timeout micros (wait running)) `onException` stop
    case result of
      Nothing -> stop >> throwIO StoreDeadline
      Just value -> pure value

storageErrors :: IO a -> IO a
storageErrors action = do
  result <- try @SQL.SQLError (try @IOException action)
  case result of
    Left _ -> throwIO StoreUnavailable
    Right (Left _) -> throwIO StoreUnavailable
    Right (Right value) -> pure value

foreign import ccall unsafe "agentic_manager_sqlite_limits"
  sqliteLimits :: Ptr a -> IO ()
foreign import ccall unsafe "agentic_manager_row_bytes"
  rowBytes :: Ptr a -> IO Int64
foreign import ccall unsafe "agentic_manager_readonly"
  statementReadonly :: Ptr a -> IO CInt
foreign import ccall unsafe "sqlite3_get_autocommit"
  getAutocommit :: Ptr a -> IO CInt
