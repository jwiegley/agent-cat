{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- | A single leased SQLite writer with strict, bounded transaction results.
module Agentic.Manager.Store
  ( CoordinationStore, StoreIdentity (..), StoreFailure (..), Checkpoint (..),
    withCoordinationStore, storeIdentity, checkpointStore, withStoreConfiguration,
    Transaction, execute, query, refuseTransaction, runTransaction, runRead, transactionGeneration,
    Invalidation (..)
  ) where

import Agentic.Manager.Configuration
  (InstalledConfiguration, acquireConfigurationStorage, releaseConfigurationStorage, withConfigurationSnapshot)
import Agentic.Manager.Profile (ConfigurationLimits, PublicProfile, Diagnostic)
import Agentic.Manager.Schema (schemaVersion, schemaStatements, commandMigration)
import Agentic.Runtime
  (PrivateRoot, assertPrivateRoot, closePrivateRoot, privateRootPath,
   withPrivateDirectoryAt, writePrivateExclusiveAt)
import Control.Concurrent (rtsSupportsBoundThreads)
import Control.Concurrent.MVar (MVar, newMVar, takeMVar, putMVar, tryTakeMVar)
import Control.Exception
  (Exception, SomeException, bracket, bracketOnError, finally, mask,
   evaluate, uninterruptibleMask_, throwIO, try)
import Control.Monad (unless, when, void)
import Control.DeepSeq (NFData, force)
import Crypto.Random (getRandomBytes)
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import qualified Data.ByteString as BS
import Data.Int (Int64)
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
  | StoreDeadline | StoreVersion | StoreIntegrity | StoreUnavailable
  deriving (Eq, Show)
instance Exception StoreFailure

-- | Observed passive checkpoint progress, not a promise of truncation or power-loss safety.
data Checkpoint = Checkpoint
  { checkpointBusy :: !Bool, checkpointLogPages :: !Int64, checkpointedPages :: !Int64
  } deriving (Eq, Show)

-- | One connection and a fail-fast admission cell. There is no waiting operation queue.
data CoordinationStore = CoordinationStore !InstalledConfiguration !PrivateRoot !SQL.Database !StoreIdentity
  !(MVar ()) !(IORef Bool) !(IORef Bool)

-- | A manager-only transaction program. No IO lift, connection or cursor is exported.
newtype Transaction a = Transaction (Context -> IO a)
data Context = Context !SQL.Database !Text !Bool !(IORef Budget) !(IORef Bool)
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
withCoordinationStore installed action = do
  unless rtsSupportsBoundThreads (throwIO StoreUnavailable)
  bracket (acquireConfigurationStorage installed) release $ \(root, _) ->
    bracket (openStore installed root) closeStore action
  where
    release (root, lease) =
      (closePrivateRoot root `finally` closeFd lease) `finally` releaseConfigurationStorage installed

openStore :: InstalledConfiguration -> PrivateRoot -> IO CoordinationStore
openStore installed root = storageErrors $ do
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
      unless (version `elem` map SQL.SQLInteger [0, 1, fromIntegral schemaVersion]) $
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
      <$> newMVar () <*> newIORef False <*> newIORef False
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
      SQL.SQLInteger current | current == fromIntegral schemaVersion -> pure ()
      _ -> throwIO StoreVersion
    when (version /= SQL.SQLInteger (fromIntegral schemaVersion)) $ do
      mapM_ (SQL.exec db) commandMigration
      SQL.exec db "PRAGMA user_version=2"
    SQL.exec db "COMMIT"
  case result of
    Right () -> pure ()
    Left failure -> do
      -- Startup never publishes a reusable connection after any migration failure.
      void (try @SomeException (rollback db))
      throwIO failure

closeStore :: CoordinationStore -> IO ()
closeStore (CoordinationStore _ _ db _ gate closed poisoned) = uninterruptibleMask_ $ do
  writeIORef closed True
  -- Only the scoped owner waits for the single in-flight operation to finish cleanup.
  -- No lease may be released while a joined SQLite operation still uses this DB.
  takeMVar gate
  result <- try @SomeException (SQL.close db)
  case result of
    Right () -> pure ()
    Left failure -> writeIORef poisoned True >> throwIO failure

-- | Configuration authority associated with this store, never a caller-selected registry.
withStoreConfiguration :: CoordinationStore -> (ConfigurationLimits -> [PublicProfile] -> IO a) -> IO (Either Diagnostic a)
withStoreConfiguration (CoordinationStore installed _ _ _ _ _ _) = withConfigurationSnapshot installed

storeIdentity :: CoordinationStore -> IO StoreIdentity
storeIdentity store@(CoordinationStore _ _ _ identity _ _ _) = admitted store (pure identity)

checkpointStore :: CoordinationStore -> IO Checkpoint
checkpointStore store@(CoordinationStore _ _ db _ _ _ _) = admitted store $ bounded db 5000000 $ do
  verifyPragmas db
  values <- rawRows db "PRAGMA wal_checkpoint(PASSIVE)" []
  case values of
    [[SQL.SQLInteger busy, SQL.SQLInteger pages, SQL.SQLInteger done]] -> pure (Checkpoint (busy /= 0) pages done)
    _ -> throwIO StoreIntegrity

admitted :: CoordinationStore -> IO a -> IO a
admitted (CoordinationStore _ root _ _ gate closed poisoned) action = mask $ \restore -> do
  readIORef closed >>= \value -> when value (throwIO StoreClosed)
  token <- tryTakeMVar gate
  case token of
    Nothing -> throwIO StoreBusy
    Just () -> (do
      readIORef closed >>= \value -> when value (throwIO StoreClosed)
      readIORef poisoned >>= \value -> when value (throwIO StorePoisoned)
      storageErrors (assertPrivateRoot root >> restore action)) `finally` putMVar gate ()

-- | Internal callers supply source-owned SQL, never SQL obtained from a client.
-- Statement count, binding bytes and strict result bytes share one transaction budget.
execute :: Text -> [SQL.SQLData] -> Transaction ()
execute sql parameters = Transaction $ \context@(Context db _ writable _ changed) -> do
  unless writable (throwIO StoreIntegrity)
  unless (T.toUpper (T.takeWhile (not . isSpace) (T.stripStart sql)) `elem` ["INSERT", "UPDATE", "DELETE"]) $
    throwIO StoreIntegrity
  chargeInput context sql parameters
  rawExecute db sql parameters
  writeIORef changed True

query :: Text -> [SQL.SQLData] -> Transaction [[SQL.SQLData]]
query sql parameters = Transaction $ \context@(Context db _ _ budget _) -> do
  unless (T.toUpper (T.takeWhile (not . isSpace) (T.stripStart sql)) `elem` ["SELECT", "WITH"]) $
    throwIO StoreIntegrity
  chargeInput context sql parameters
  withStatement db sql $ \statement -> do
    let Direct.Statement raw = statement
    readonly <- statementReadonly raw
    unless (readonly /= 0) (throwIO StoreIntegrity)
    SQL.bind statement parameters
    collectRows budget statement

-- | The current in-memory lifetime, never reconstructed from a database row.
transactionGeneration :: Transaction Text
transactionGeneration = Transaction $ \(Context _ generation _ _ _) -> pure generation

refuseTransaction :: Exception e => e -> Transaction a
refuseTransaction failure = Transaction (const (throwIO failure))

runRead :: NFData a => CoordinationStore -> Transaction a -> IO a
runRead store transaction = run store False ((\value -> (value, [])) <$> transaction)

runTransaction :: NFData a => CoordinationStore -> Transaction (a, [Invalidation]) -> IO a
runTransaction store transaction = run store True transaction

run :: NFData a => CoordinationStore -> Bool -> Transaction (a, [Invalidation]) -> IO a
run store@(CoordinationStore _ _ db identity _ _ poisoned) writable (Transaction action) = admitted store $ do
  committing <- newIORef False
  changed <- newIORef False
  budget <- newIORef (Budget 256 8388608 1000 1048576)
  mask $ \restore -> do
    result <- try @SomeException $ restore $ bounded db 5000000 $ do
      SQL.exec db (if writable then "BEGIN IMMEDIATE" else "BEGIN")
      (resultValue, events) <- action (Context db (storeProcessGeneration identity) writable budget changed)
      validateEvents events
      value <- evaluate (force resultValue)
      didChange <- readIORef changed
      when (didChange && null events) (throwIO StoreIntegrity)
      mapM_ (appendInvalidation db) events
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
chargeInput (Context _ _ _ budget _) sql parameters = do
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
bounded db micros action = do
  result <- timeout micros (SQL.interruptibly db action)
  maybe (throwIO StoreDeadline) pure result

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
