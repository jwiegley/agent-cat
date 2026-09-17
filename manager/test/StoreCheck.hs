{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PackageImports #-}
{-# LANGUAGE TypeApplications #-}
module Main (main) where

import qualified StoreAdmissionCheck
import qualified "agentic" Agentic.Manager as Public
import Agentic.Manager.Configuration
import Agentic.Manager.Profile (Diagnostic)
import Agentic.Manager.Schema (schemaVersion, schemaStatements, commandMigration, draftMigration, admissionMigration, approvalMigration)
import Agentic.Manager.Store
import Control.Concurrent (threadDelay, throwTo)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar, readMVar, tryPutMVar)
import Control.Concurrent.Async (AsyncCancelled (..), async, asyncThreadId, wait, cancel, poll, waitCatch, withAsync)
import Control.Exception
  (AsyncException (UserInterrupt), bracket, finally, fromException, onException, throwIO, try)
import Control.Monad (forM_, replicateM_, unless, void)
import Control.DeepSeq (NFData)
import Crypto.Hash (Digest, SHA256, hash)
import Data.ByteArray (convert)
import Data.Aeson (encode, object, (.=))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.Either (isLeft)
import Data.IORef (newIORef, readIORef, writeIORef, modifyIORef')
import Data.Text (Text)
import qualified Data.Text as T
import qualified Database.SQLite3 as SQL
import GHC.Clock (getMonotonicTimeNSec)
import System.Directory (createDirectory)
import System.Environment (getArgs, getExecutablePath)
import System.Exit (ExitCode (ExitSuccess))
import System.FilePath ((</>))
import System.IO (BufferMode (LineBuffering), hClose, hGetLine, hSetBuffering, stdout)
import System.Posix.Files (fileMode, getSymbolicLinkStatus, setFileMode)
import Data.Bits ((.&.))
import System.Posix.Signals (sigKILL, signalProcess)
import System.Process
  (CreateProcess (std_out, close_fds), StdStream (CreatePipe), ProcessHandle, createProcess, getPid,
   proc, readProcessWithExitCode, terminateProcess, waitForProcess)
import System.Timeout (timeout)

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  args <- getArgs
  case args of
    ["admission-data"] -> StoreAdmissionCheck.dataChecks
    ["terminal-admission",work] -> terminalAdmissionChecks work
    ["hold", path] -> withInstalled path $ \installed -> withCoordinationStore installed $ \_ ->
      putStrLn "ready" >> threadDelay 60000000
    ["refuse", path] -> do
      config <- load path
      result <- installConfiguration config
      check "second-process lease refusal" (isLeft result)
    ["idle"] -> putStrLn "ready" >> threadDelay 60000000
    [work] -> do
      publicChecks work
      ownershipChecks work
      databaseChecks work
      migrationChecks work
      admissionMigrationChecks work
      ingestionMigrationChecks work
      conditionalTransactionChecks work
      putStrLn "PASS manager coordination storage"
    _ -> error "usage: manager-store-check PRIVATE_DIRECTORY"

check :: String -> Bool -> IO ()
check label result = unless result (error ("FAIL " <> label)) >> putStrLn ("PASS " <> label)

right :: Show e => Either e a -> IO a
right = either (error . show) pure

load :: FilePath -> IO Configuration
load path = loadConfiguration (const (Right ()))  exactPreparedTarget (const False) path >>= right

withInstalled :: FilePath -> (InstalledConfiguration -> IO a) -> IO a
withInstalled path action = do
  config <- load path
  bracket (installConfiguration config >>= right) closeConfiguration action

fixture :: FilePath -> String -> IO (FilePath, FilePath)
fixture work name = do
  let root = work </> name
      path = work </> (name <> ".json")
  createDirectory root
  setFileMode root 0o700
  BL.writeFile path $ encode $ object
    ["version" .= (1 :: Int), "managerRoot" .= root, "localRetentionRoots" .= ([] :: [String]),
     "runners" .= ([] :: [String]), "profiles" .= ([] :: [String]),
     "limits" .= object
       ["drafts" .= (10 :: Int), "globalDrafts" .= (20 :: Int),
        "globalCaptureBytes" .= (67108864 :: Int), "globalPageSets" .= (2 :: Int),
        "globalConnections" .= (4 :: Int), "globalDatabaseReaders" .= (2 :: Int),
        "globalMutationLedgerBytes" .= (8388608 :: Int), "safetyControlsPerMinute" .= (10 :: Int),
        "executionReservations" .= (1 :: Int)]]
  setFileMode path 0o600
  pure (path, root)

expect :: String -> StoreFailure -> IO a -> IO ()
expect label expected action = do
  result <- try @StoreFailure action
  check label (case result of Left failure -> failure == expected; Right _ -> False)

publicChecks :: FilePath -> IO ()
publicChecks work = do
  (path, _) <- fixture work "public"
  config <- Public.loadConfiguration (const (Right ())) Public.exactPreparedTarget (const False) path >>= right
  bracket (Public.installConfiguration config >>= right) Public.closeConfiguration $ \installed -> do
    first <- Public.withCoordinationStore installed $ \store -> do
      identity <- Public.storeIdentity store
      checkpoint <- Public.checkpointStore store
      check "public facade real checkpoint" (not (Public.checkpointBusy checkpoint))
      pure identity
    second <- Public.withCoordinationStore installed Public.storeIdentity
    check "public facade durable epoch/stream, fresh live generation"
      (Public.storeAuthorityEpoch first == Public.storeAuthorityEpoch second
       && Public.storeStreamId first == Public.storeStreamId second
       && Public.storeProcessGeneration first /= Public.storeProcessGeneration second)

ownershipChecks :: FilePath -> IO ()
ownershipChecks work = do
  (path, _) <- fixture work "ownership"
  config <- load path
  withInstalled path $ \installed -> do
    installConfiguration config >>= check "distinct same-process opens exclude ownership" . isLeft
    executable <- getExecutablePath
    (status, output, _) <- readProcessWithExitCode executable ["refuse", path] ""
    check "actual second process refused" (status == ExitSuccess && "second-process" `T.isInfixOf` T.pack output)
    withCoordinationStore installed $ \store -> do
      result <- try @Diagnostic (withCoordinationStore installed (const (pure ())))
      check "one store slot per installed configuration" (isLeft result)
      reloadConfiguration installed config >>= right >>= check "reload remains available with live store" . null
      void (storeIdentity store)
    failed <- try @AsyncException (withCoordinationStore installed (const (throwIO UserInterrupt)))
    check "callback exception identity preserved" (case failed of Left UserInterrupt -> True; _ -> False)
    void (withCoordinationStore installed storeIdentity)
    ready <- newIORef False
    withAsync (withCoordinationStore installed $ \_ -> writeIORef ready True >> threadDelay 60000000) $ \child -> do
      await (readIORef ready)
      cancel child
      result <- waitCatch child
      check "callback cancellation identity and slot cleanup" (case result of
        Left failure -> case fromException failure of Just AsyncCancelled -> True; Nothing -> False
        Right _ -> False)
    void (withCoordinationStore installed storeIdentity)
    escaped <- withCoordinationStore installed pure
    expect "escaped handle refuses after scope" StoreClosed (storeIdentity escaped)
    -- This child intentionally does not close inherited descriptors before exec.
    withChild ["idle"] $ \_ -> do
      withCoordinationStore installed $ \store -> do
        closeConfiguration installed
        closeConfiguration installed
        installConfiguration config >>= check "store duplicate retains lease after configuration close" . isLeft
        void (storeIdentity store)
        reloadConfiguration installed config >>= check "closed configuration cannot reload" . isLeft
      bracket (installConfiguration config >>= right) closeConfiguration $ \_ ->
        check "lease released while exec child lives" True
  withChild ["hold", path] $ \process -> do
    installConfiguration config >>= check "child owns real service lease" . isLeft
    pid <- getPid process >>= maybe (error "missing fixture PID") pure
    signalProcess sigKILL pid
    void (waitForProcess process)
    bracket (installConfiguration config >>= right) closeConfiguration $ \_ ->
      check "hard process death releases ownership" True
  -- Exercise both original and duplicated lease across exec, after opening the store.
  bracket (withInstalled path $ \installed -> withCoordinationStore installed $ \_ -> startChild ["idle"])
    stopChild $ \_ -> bracket (installConfiguration config >>= right) closeConfiguration $ \_ ->
      check "original and duplicated leases both close on exec" True

withChild :: [String] -> (ProcessHandle -> IO a) -> IO a
withChild args = bracket (startChild args) stopChild

startChild :: [String] -> IO ProcessHandle
startChild args = do
  executable <- getExecutablePath
  (_, output, _, process) <- createProcess (proc executable args) {std_out = CreatePipe, close_fds = False}
  (do
    handle <- maybe (error "missing fixture stdout") pure output
    ready <- timeout 5000000 (hGetLine handle) `finally` hClose handle
    check "fixture child ready" (ready == Just "ready")
    pure process) `onException` stopChild process

stopChild :: ProcessHandle -> IO ()
stopChild process = terminateProcess process >> void (waitForProcess process)

await :: IO Bool -> IO ()
await condition = do
  result <- timeout 5000000 loop
  check "bounded concurrency synchronization" (result == Just ())
  where
    loop = condition >>= \ready -> unless ready (threadDelay 1000 >> loop)

event :: Invalidation
event = Invalidation "request.changed" "/v1/requests/request_1" "revision_1"

mutate :: NFData a => CoordinationStore -> Transaction a -> [Invalidation] -> IO a
mutate store transaction events = runTransaction store ((\value -> (value, events)) <$> transaction)

client :: Text -> Transaction ()
client ident = execute "INSERT INTO clients VALUES (?, 'revision_1', 'authorization_1', 0)" [SQL.SQLText ident]

rowsEqual :: CoordinationStore -> Text -> [[SQL.SQLData]] -> IO Bool
rowsEqual store sql expected = runRead store ((== expected) <$> query sql [])

count :: CoordinationStore -> Text -> IO Int
count store table = runRead store $ do
  rows <- query ("SELECT count(*) FROM " <> table) []
  case rows of
    [[SQL.SQLInteger n]] -> pure (fromIntegral n)
    _ -> refuseTransaction StoreIntegrity

databaseChecks :: FilePath -> IO ()
databaseChecks work = do
  (path, root) <- fixture work "database"
  first <- withInstalled path $ \installed -> withCoordinationStore installed $ \store -> do
    version <- runRead store $ do
      values <- query "SELECT sqlite_version()" []
      case values of
        [[SQL.SQLText value]] -> pure value
        _ -> refuseTransaction StoreIntegrity
    putStrLn ("Linked SQLite: " <> T.unpack version)
    forM_ [("SELECT journal_mode FROM pragma_journal_mode", SQL.SQLText "wal"), ("SELECT synchronous FROM pragma_synchronous", SQL.SQLInteger 2),
           ("SELECT foreign_keys FROM pragma_foreign_keys", SQL.SQLInteger 1), ("SELECT timeout FROM pragma_busy_timeout", SQL.SQLInteger 100),
           ("SELECT temp_store FROM pragma_temp_store", SQL.SQLInteger 1),
           ("SELECT cache_size FROM pragma_cache_size", SQL.SQLInteger (-2048)),
           ("SELECT cache_size FROM pragma_cache_size('temp')", SQL.SQLInteger (-2048)),
           ("SELECT sqlite_compileoption_used('TEMP_STORE=3')", SQL.SQLInteger 0)] $ \(sql, expected) ->
      rowsEqual store sql [[expected]] >>= check (T.unpack sql)
    forM_ ["coordination.sqlite3", "coordination.sqlite3-wal", "coordination.sqlite3-shm"] $ \name -> do
      status <- getSymbolicLinkStatus (root </> name)
      check (name <> " private mode") (fileMode status .&. 0o777 == 0o600)
    mutate store (client "client_1") [event]
    expect "SQL unique constraint refuses duplicate client" StoreUnavailable $
      mutate store (client "client_1") [event]
    expect "SQL foreign key refuses unknown client" StoreUnavailable $
      mutate store (execute "INSERT INTO credentials VALUES ('credential_1','missing',X'01','2030-01-01',0)" []) [event]
    count store "invalidations" >>= check "constraint failures do not append invalidations" . (== 1)
    expect "explicit rollback removes resource and event changes" StoreIntegrity $
      mutate store (client "rolled_back" >> refuseTransaction StoreIntegrity :: Transaction ()) [event]
    expect "mutation cannot commit without an invalidation" StoreIntegrity $
      mutate store (client "no_event") []
    count store "clients" >>= check "resource rollback is atomic" . (== 1)
    mutate store relationalRows [event]
    relationalConstraints store
    reservationHistory store
    inputAndReadBounds store
    cancellationChecks store
    bracket (rawOpen root) SQL.close $ \other -> do
      SQL.exec other "BEGIN IMMEDIATE"
      start <- getMonotonicTimeNSec
      expect "bounded external writer busy refusal" StoreUnavailable $
        mutate store (client "busy") [event]
      end <- getMonotonicTimeNSec
      check "busy wait below operation budget" (end - start < 2000000000)
      SQL.exec other "ROLLBACK; BEGIN"
      void (rawRows other "SELECT * FROM clients")
      mutate store (client "after_reader") [event]
      progress <- checkpointStore store
      check "passive checkpoint reports pinned-reader progress" (checkpointedPages progress < checkpointLogPages progress)
      SQL.exec other "ROLLBACK"
    completed <- checkpointStore store
    check "ordinary checkpoint completes after reader release"
      (not (checkpointBusy completed) && checkpointLogPages completed == checkpointedPages completed)
    identity <- storeIdentity store
    pure identity
  withInstalled path $ \installed -> withCoordinationStore installed $ \store -> do
    second <- storeIdentity store
    check "reopen preserves durable identities separately from live generation"
      (storeAuthorityEpoch first == storeAuthorityEpoch second && storeStreamId first == storeStreamId second
       && storeProcessGeneration first /= storeProcessGeneration second && storeSchemaVersion second == schemaVersion)
    rowsEqual store "SELECT sequence,retained_floor,revision FROM service_metadata"
      [[SQL.SQLText "4", SQL.SQLText "0", SQL.SQLText "service_1"]] >>= check "stream sequence and resource revisions survive reopen"
  -- Real SQLite trigger failure occurs after resource update and sequence allocation.
  bracket (rawOpen root) SQL.close $ \db -> SQL.exec db
    "CREATE TRIGGER reject_event BEFORE INSERT ON invalidations BEGIN SELECT RAISE(ABORT,'synthetic event failure'); END"
  withInstalled path $ \installed -> withCoordinationStore installed $ \store -> do
    expect "event insertion failure rolls back resource and sequence" StoreUnavailable $
      mutate store (client "event_failed") [event]
    count store "clients" >>= check "failed event leaves no new client" . (== 2)
    rowsEqual store "SELECT sequence FROM service_metadata" [[SQL.SQLText "4"]] >>= check "failed event leaves no sequence gap"

relationalRows :: Transaction ()
relationalRows = do
  execute "INSERT INTO requests (id,revision,client_id,workflow_id,descriptor_revision,profile_id,profile_revision,phase,admission,blocking_reasons,validation_errors) VALUES ('request_1','revision_1','client_1','workflow_1','descriptor_1','profile_1','profile_revision_1','draft','not-queued',X'5b5d',X'5b5d')" []
  execute "INSERT INTO captures VALUES ('capture_1','revision_1','request_1','client_1','profile_1',X'01',0,?)" [SQL.SQLText (T.replicate 64 "0")]
  let literalBytes = BS.pack [0xce,0xb1,13,10]
  execute "INSERT INTO request_inputs (request_id,name,declaration_ordinal,declaration,source,literal_bytes,literal_transport_bytes,literal_chunks,literal_digest) VALUES ('request_1','input_1',0,X'7b7d','literal',4,4,1,?)"
    [SQL.SQLBlob (convert (hash literalBytes :: Digest SHA256))]
  execute "INSERT INTO request_literal_chunks VALUES ('request_1','input_1',0,?)" [SQL.SQLBlob literalBytes]
  execute "INSERT INTO reservations (id,request_id,slot,process_generation,state) VALUES ('reservation_1','request_1',0,'generation_1','held')" []
  execute "INSERT INTO reservation_resources VALUES ('operator','workspace_1','reservation_1')" []
  execute "INSERT INTO preparations VALUES ('preparation_1','revision_1','request_1','revision_1','profile_revision_1','reservation_1','generation_1','worker_1','root_1','native_1','2030-01-01','digest_1',X'7b7d',X'7b7d','live',NULL)" []
  execute "INSERT INTO runs (id,revision,control_revision,request_id,preparation_id,profile_id,root_identity,native_run_id,supervision,result_state) VALUES ('run_1','revision_1','control_1','request_1','preparation_1','profile_1','root_1','native_1','owned','absent')" []
  execute "INSERT INTO ingestions VALUES ('run_1','18446744073709551615',?,X'7b7d')" [SQL.SQLText (T.pack (show (hash ("{}"::BS.ByteString)::Digest SHA256)))]
  execute "INSERT INTO decisions (id,revision,run_id,occurrence_id,generation,observed_sequence,kind,state) VALUES ('decision_1','revision_1','run_1','0','decision_generation_1','2','question','pending')" []
  execute "INSERT INTO artifacts VALUES ('artifact_1','revision_1','run_1',X'02',X'03','referenced',NULL)" []
  execute "INSERT INTO commands (id,revision,profile_id,operation,client_id,authority_epoch,method,resource_uri,idempotency_key,body,media_type,receipt,retired,run_id,accepted_at,state) VALUES ('command_1','revision_1','profile_1','export','client_1','authority_1','POST','/v1/runs/run_1/exports','authority_1.nonce_1',X'7b7d','application/json',X'7b7d',0,'run_1','2030-01-01','accepted')" []
  execute "INSERT INTO exports VALUES ('export_1','revision_1','run_1','artifact_1','command_1','export_root_1','out.json','digest_1',NULL,NULL)" []
  execute "INSERT INTO credentials VALUES ('credential_1','client_1',X'010203','2030-01-01',0)" []
  execute "INSERT INTO credential_scopes VALUES ('credential_1','profile_1','observe')" []

relationalConstraints :: CoordinationStore -> IO ()
relationalConstraints store = do
  forM_
    [("reservation resource exclusivity", "INSERT INTO reservation_resources VALUES ('operator','workspace_1','reservation_1')"),
     ("native run identity uniqueness", "INSERT INTO runs (id,revision,control_revision,profile_id,root_identity,native_run_id,supervision,result_state) VALUES ('duplicate','r','c','profile_1','root_1','native_1','observer','absent')"),
     ("runtime ingestion identity uniqueness", "INSERT INTO ingestions VALUES ('run_1','18446744073709551615','different',X'00')"),
     ("capture profile must match its request", "UPDATE captures SET profile_id='other_profile'"),
     ("canonical runtime sequence required", "INSERT INTO ingestions VALUES ('run_1','01','digest',X'00')"),
     ("runtime sequence overflow refused", "INSERT INTO ingestions VALUES ('run_1','18446744073709551616','digest',X'00')"),
     ("input representation exclusivity", "UPDATE request_inputs SET capture_id='capture_1'"),
     ("missing input cannot retain literal bytes", "UPDATE request_inputs SET source=NULL"),
     ("decision occurrence identity without attempt", "INSERT INTO decisions (id,revision,run_id,occurrence_id,generation,observed_sequence,kind,state) VALUES ('decision_2','revision_1','run_1','0','decision_generation_1','3','question','pending')"),
     ("credential verifier uniqueness", "INSERT INTO credentials VALUES ('credential_2','client_1',X'010203','2030-01-01',0)"),
     ("capture reference prevents removal", "DELETE FROM requests WHERE id='request_1'")]
    $ \(label, sql) -> expect label StoreUnavailable (mutate store (execute sql []) [event])
  let duplicateLedger = "INSERT INTO commands (id,revision,profile_id,operation,client_id,authority_epoch,method,resource_uri,idempotency_key,body,media_type,precondition,receipt,retired,request_id,run_id,preparation_id,decision_id,accepted_at,dispatch_generation,attempted_at,acknowledgement,effect_evidence,state) SELECT 'duplicate',revision,profile_id,operation,client_id,authority_epoch,method,resource_uri,idempotency_key || ?,body,media_type,precondition,receipt,retired,request_id,run_id,preparation_id,decision_id,accepted_at,dispatch_generation,attempted_at,acknowledgement,effect_evidence,state FROM commands"
  expect "ledger duplicate fixture is otherwise valid" StoreIntegrity $
    mutate store (execute duplicateLedger [SQL.SQLText "_distinct"] >> (refuseTransaction StoreIntegrity :: Transaction ())) [event]
  expect "registered-client ledger uniqueness with the otherwise-valid fixture" StoreUnavailable $
    mutate store (execute duplicateLedger [SQL.SQLText ""]) [event]
  rowsEqual store "SELECT runtime_snapshot,snapshot_version,result_state,supervision FROM runs"
    [[SQL.SQLNull, SQL.SQLNull, SQL.SQLText "absent", SQL.SQLText "owned"]] >>= check "reserved run does not fabricate runtime evidence"
  rowsEqual store "SELECT bytes FROM request_literal_chunks" [[SQL.SQLBlob (BS.pack [0xce,0xb1,13,10])]] >>=
    check "input binding preserves exact Unicode/CRLF bytes"

reservationHistory :: CoordinationStore -> IO ()
reservationHistory store = do
  expect "one active reservation per request" StoreUnavailable $
    mutate store (execute "INSERT INTO reservations (id,request_id,slot,process_generation,state) VALUES ('duplicate','request_1',1,'generation_1','held')" []) [event]
  expect "active reservation requires a slot" StoreUnavailable $
    mutate store (execute "UPDATE reservations SET slot=NULL" []) [event]
  expect "reservation release requires removing resource claims" StoreUnavailable $
    mutate store (execute "UPDATE reservations SET slot=NULL,state='released'" []) [event]
  expect "released reservation cannot retain a slot" StoreUnavailable $
    mutate store (do
      execute "DELETE FROM reservation_resources" []
      execute "UPDATE reservations SET state='released'" []) [event]
  mutate store (do
    execute "UPDATE preparations SET state='invalidated',reason='discarded'" []
    execute "DELETE FROM reservation_resources" []
    execute "UPDATE reservations SET slot=NULL,state='released'" []
    execute "INSERT INTO reservations (id,request_id,slot,process_generation,state) VALUES ('reservation_2','request_1',0,'generation_2','held')" []
    execute "INSERT INTO reservation_resources VALUES ('operator','workspace_1','reservation_2')" []) [event]
  rowsEqual store "SELECT reservation_id,state FROM preparations"
    [[SQL.SQLText "reservation_1", SQL.SQLText "invalidated"]] >>=
      check "capacity reuse retains historical preparation association"
  rowsEqual store "SELECT slot,state FROM reservations WHERE id='reservation_1'"
    [[SQL.SQLNull, SQL.SQLText "released"]] >>= check "released reservation history retains no slot"
  rowsEqual store "SELECT slot FROM reservations WHERE id='reservation_2'"
    [[SQL.SQLInteger 0]] >>= check "same request and execution slot reusable after release"
  expect "cannot add a claim to released reservation" StoreUnavailable $
    mutate store (execute "INSERT INTO reservation_resources VALUES ('operator','other','reservation_1')" []) [event]
  expect "cannot move a claim to released reservation" StoreUnavailable $
    mutate store (execute "UPDATE reservation_resources SET reservation_id='reservation_1'" []) [event]

inputAndReadBounds :: CoordinationStore -> IO ()
inputAndReadBounds store = do
  expect "oversized bound parameter refused" StoreLimit $
    runRead store (query "SELECT ?" [SQL.SQLBlob (BS.replicate 2097153 120)] >> pure ())
  expect "aggregate binding bytes bounded across statements" StoreLimit $
    runRead store (replicateM_ 4 (query "SELECT length(?)" [SQL.SQLBlob (BS.replicate 2097152 120)]))
  expect "oversized SQL refused" StoreLimit $
    runRead store (query ("SELECT 1 " <> T.replicate 65536 " ") [] >> pure ())
  expect "parameter list bounded without traversing infinite tail" StoreLimit $
    runRead store (query "SELECT ?" (repeat SQL.SQLNull) >> pure ())
  expect "result row count refused without truncation" StoreLimit $
    runRead store (query "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<1001) SELECT x FROM n" [] >> pure ())
  expect "result bytes checked before copying" StoreLimit $
    runRead store (query "SELECT zeroblob(1048577)" [] >> pure ())
  expect "aggregate result budget shared by queries" StoreLimit $
    runRead store (replicateM_ 2 (query "SELECT zeroblob(600000)" []))
  expect "transaction statement count bounded" StoreLimit $
    runRead store (replicateM_ 257 (query "SELECT 1" []))
  expect "returned invalidation list bounded before append" StoreLimit $
    mutate store (client "too_many_events") (repeat event)
  expect "invalidation URI syntax follows frozen contract" StoreLimit $
    mutate store (client "bad_event") [Invalidation "request.changed" "/v1/requests/雪" "revision_1"]
  expect "read operation cannot execute mutations" StoreIntegrity $
    runRead store (execute "DELETE FROM clients" [])
  expect "read program cannot disable foreign keys" StoreIntegrity $
    runRead store (query "PRAGMA foreign_keys=OFF" [] >> pure ())
  expect "query cannot mutate through an allowed WITH prefix" StoreIntegrity $
    runRead store (query "WITH target(id) AS (SELECT 'client_1') UPDATE clients SET revision='unapproved' WHERE id IN (SELECT id FROM target) RETURNING id" [] >> pure ())
  rowsEqual store "SELECT revision FROM clients" [[SQL.SQLText "revision_1"]] >>=
    check "read-only refusal leaves resource revision unchanged"
  expect "transaction program cannot replace transaction boundary" StoreIntegrity $
    mutate store (execute "COMMIT" []) [event]
  count store "clients" >>= check "bound refusals preserve committed data" . (== 1)

expensive :: Transaction ()
expensive = query "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<1000000000000) SELECT sum(x) FROM n" [] >> pure ()

cancellationChecks :: CoordinationStore -> IO ()
cancellationChecks store = do
  child <- async (mutate store (client "cancelled" >> expensive) [event])
  threadDelay 100000
  await $ do
    finished <- poll child
    case finished of
      Just result -> error ("SQLite fixture ended before synchronization: " <> show result)
      Nothing -> pure ()
    outcome <- try @StoreFailure (storeIdentity store)
    pure (case outcome of Left StoreBusy -> True; _ -> False)
  threadDelay 100000
  poll child >>= check "SQLite operation still in flight before cancellation" . maybe True (const False)
  expect "overlapping caller refused without waiting queue" StoreBusy (runRead store (pure ()))
  cancel child
  outcome <- waitCatch child
  check "SQLite cancellation preserves original AsyncCancelled" (case outcome of
    Left failure -> case fromException failure of Just AsyncCancelled -> True; Nothing -> False
    Right _ -> False)
  count store "clients" >>= check "cancelled transaction rollback and reuse" . (== 1)
  before <- getMonotonicTimeNSec
  expect "cooperative SQLite operation deadline" StoreDeadline (mutate store (client "deadline" >> expensive) [event])
  after <- getMonotonicTimeNSec
  check "real deadline observed within test ceiling" (after - before < 15000000000)
  count store "clients" >>= check "deadline rollback and subsequent consistency" . (== 1)
  expect "read transaction has same cooperative deadline" StoreDeadline (runRead store expensive)
  count store "clients" >>= check "read deadline releases transaction" . (== 1)

rawOpen :: FilePath -> IO SQL.Database
rawOpen root = SQL.open2 (T.pack (root </> "coordination.sqlite3"))
  [SQL.SQLOpenReadWrite, SQL.SQLOpenCreate, SQL.SQLOpenFullMutex, SQL.SQLOpenNoFollow] SQL.SQLVFSDefault

rawRows :: SQL.Database -> Text -> IO [[SQL.SQLData]]
rawRows db sql = bracket (SQL.prepare db sql) SQL.finalize $ \statement ->
  let loop remaining = do
        result <- SQL.step statement
        case result of
          SQL.Done -> pure []
          SQL.Row -> do
            unless (remaining > (0 :: Int)) (error "fixture row ceiling")
            (:) <$> SQL.columns statement <*> loop (remaining - 1)
   in loop 1000

migrationChecks :: FilePath -> IO ()
migrationChecks work = do
  (path, root) <- fixture work "migration"
  withInstalled path (const (pure ()))
  bracket (rawOpen root) SQL.close $ \db ->
    SQL.exec db "CREATE TABLE clients (sentinel TEXT); INSERT INTO clients VALUES ('preserved')"
  setFileMode (root </> "coordination.sqlite3") 0o600
  withInstalled path $ \installed -> expect "partial migration refuses" StoreUnavailable $
    withCoordinationStore installed (const (pure ()))
  bracket (rawOpen root) SQL.close $ \db -> do
    rawRows db "PRAGMA user_version" >>= check "failed migration leaves version zero" . (== [[SQL.SQLInteger 0]])
    rawRows db "SELECT name FROM sqlite_master WHERE type='table'" >>= check "failed migration leaves no partial tables" . (== [[SQL.SQLText "clients"]])
    rawRows db "SELECT sentinel FROM clients" >>= check "failed migration preserves existing data" . (== [[SQL.SQLText "preserved"]])
    SQL.exec db "DROP TABLE clients"
  withInstalled path $ \installed -> void (withCoordinationStore installed storeIdentity)
  bracket (rawOpen root) SQL.close $ \db -> SQL.exec db
    "CREATE TABLE deferred_failure (client_id TEXT REFERENCES clients(id) DEFERRABLE INITIALLY DEFERRED)"
  withInstalled path $ \installed -> withCoordinationStore installed $ \store -> do
    expect "commit failure is explicit" StoreUnavailable $
      mutate store (execute "INSERT INTO deferred_failure VALUES ('missing')" []) [event]
    expect "uncertain commit path cannot return reusable success" StorePoisoned (storeIdentity store)
  withInstalled path $ \installed -> withCoordinationStore installed $ \store -> do
    count store "deferred_failure" >>= check "failed commit rolled back before fresh lifetime" . (== 0)
    count store "invalidations" >>= check "failed commit also rolled back its event" . (== 0)
  bracket (rawOpen root) SQL.close $ \db ->
    SQL.exec db "UPDATE service_metadata SET sequence='18446744073709551615'"
  withInstalled path $ \installed -> withCoordinationStore installed $ \store -> do
    expect "stream exhaustion refuses without wrapping" StoreLimit $
      mutate store (client "overflow") [event]
    count store "clients" >>= check "stream exhaustion rolls back resource change" . (== 0)
    rowsEqual store "SELECT sequence FROM service_metadata" [[SQL.SQLText "18446744073709551615"]] >>=
      check "complete UInt64 stream range survives reopen"
  bracket (rawOpen root) SQL.close $ \db -> SQL.exec db ("PRAGMA user_version="<>T.pack(show(schemaVersion+1)))
  before <- BS.readFile (root </> "coordination.sqlite3")
  withInstalled path $ \installed -> expect "newer schema refused" StoreVersion $
    withCoordinationStore installed (const (pure ()))
  after <- BS.readFile (root </> "coordination.sqlite3")
  check "newer database unchanged by refusal" (before == after)


conditionalTransactionChecks :: FilePath -> IO ()
conditionalTransactionChecks work = do
  (path, _) <- fixture work "conditional"
  withInstalled path $ \installed -> withCoordinationStore installed $ \store -> do
    mutate store (client "conditional_client") [event]
    let advance = do
          values <- query "SELECT revision FROM clients WHERE id='conditional_client'" []
          case values of
            [[SQL.SQLText revision]] | revision == "revision_1" -> do
              let next = revision <> "_next"
              execute "UPDATE clients SET revision=? WHERE id='conditional_client'" [SQL.SQLText next]
              pure (next, [Invalidation "service.changed" "/v1/capabilities" next])
            [[SQL.SQLText revision]] -> pure (revision, [])
            _ -> refuseTransaction StoreIntegrity
    first <- runTransaction store advance
    duplicate <- runTransaction store advance
    check "conditional duplicate returns original transaction result" (first == "revision_1_next" && duplicate == first)
    rowsEqual store "SELECT revision FROM clients WHERE id='conditional_client'" [[SQL.SQLText first]] >>=
      check "conditional duplicate preserves resource revision"
    rowsEqual store "SELECT revision FROM invalidations WHERE sequence='2'" [[SQL.SQLText first]] >>=
      check "invalidation revision derives from same transaction snapshot"
    count store "invalidations" >>= check "conditional duplicate appends no event" . (== 2)
    rowsEqual store "SELECT sequence FROM service_metadata" [[SQL.SQLText "2"]] >>=
      check "conditional duplicate does not advance stream sequence"

admissionMigrationChecks :: FilePath -> IO ()
admissionMigrationChecks work = do
  (path,root)<-fixture work "admission-migration"
  withInstalled path (const(pure()))
  bracket (rawOpen root) SQL.close $ \database -> do
    mapM_ (SQL.exec database) (schemaStatements<>commandMigration<>draftMigration)
    SQL.exec database "INSERT INTO service_metadata VALUES (1,'authority_old','stream_old','0','0','service_old'); INSERT INTO clients VALUES ('client_old','revision','fixture',0)"
    SQL.exec database "INSERT INTO requests(id,revision,client_id,workflow_id,descriptor_revision,profile_id,profile_revision,phase,admission,queue_ordinal,blocking_reasons,validation_errors) VALUES ('request_old','revision_old','client_old','workflow_old','descriptor_old','profile_old','policy_old','queued','waiting','18446744073709551614',X'5b5d',X'5b5d')"
    SQL.exec database "INSERT INTO reservations VALUES ('reservation_old','request_old',7,'generation_old','held'); INSERT INTO reservation_resources VALUES ('unclassified','reservation_old'); PRAGMA user_version=3"
    SQL.exec database "CREATE TABLE admission_observations(sentinel TEXT); INSERT INTO admission_observations VALUES('preserved')"
  setFileMode (root </> "coordination.sqlite3") 0o600
  withInstalled path $ \installed -> expect "version-four partial migration refuses" StoreUnavailable (withCoordinationStore installed(const(pure())))
  bracket (rawOpen root) SQL.close $ \database -> do
    rawRows database "PRAGMA user_version" >>=check "failed version-four migration retains version three" . (==[[SQL.SQLInteger 3]])
    rawRows database "SELECT count(*) FROM pragma_table_info('requests') WHERE name='input_revision'" >>=check "failed version-four migration rolls back added request columns" . (==[[SQL.SQLInteger 0]])
    rawRows database "SELECT resource_key,reservation_id FROM reservation_resources" >>=check "failed version-four migration preserves exact old claims" . (==[[SQL.SQLText "unclassified",SQL.SQLText "reservation_old"]])
    rawRows database "SELECT sentinel FROM admission_observations" >>=check "failed version-four migration preserves pre-existing conflict" . (==[[SQL.SQLText "preserved"]])
    SQL.exec database "DROP TABLE admission_observations"
  withInstalled path $ \installed -> withCoordinationStore installed $ \owner -> do
    storeIdentity owner >>=check "version-four migration completes transactionally" . ((==schemaVersion).storeSchemaVersion)
    rowsEqual owner "SELECT last_ordinal FROM admission_queue_clock" [[SQL.SQLText "18446744073709551614"]] >>=check "migration preserves unsigned queue history beyond signed SQLite integers"
    rowsEqual owner "SELECT kind,resource_key,reservation_id FROM reservation_resources" [[SQL.SQLText "operator",SQL.SQLText "unclassified",SQL.SQLText "reservation_old"]] >>=check "legacy operator string remains outside internal unclassified domain"
    rowsEqual owner "SELECT input_revision,queue_generation,queue_origin_revision,enqueue_command FROM requests" [[SQL.SQLNull,SQL.SQLNull,SQL.SQLNull,SQL.SQLNull]] >>=check "migration mints no input-selection or enqueue authority"
    rowsEqual owner "SELECT slot,process_generation,state FROM reservations" [[SQL.SQLInteger 7,SQL.SQLText "generation_old",SQL.SQLText "held"]] >>=check "migration preserves old held slot without adopting its worker"

ingestionMigrationChecks :: FilePath -> IO ()
ingestionMigrationChecks work = do
  (path,root) <- fixture work "ingestion-migration"
  withInstalled path (const (pure ()))
  bracket (rawOpen root) SQL.close $ \db -> do
    mapM_ (SQL.exec db) (schemaStatements<>commandMigration<>draftMigration<>admissionMigration<>approvalMigration)
    SQL.exec db "INSERT INTO service_metadata VALUES (1,'old_epoch','old_stream','0','0','old_revision'); INSERT INTO clients VALUES ('old_client','old_revision','old_auth',0); INSERT INTO runs(id,revision,control_revision,profile_id,root_identity,native_run_id,supervision,result_state) VALUES ('old_run','old_revision','old_control','old_profile','old_root','old_native','observer','absent'); PRAGMA user_version=5"
    SQL.exec db "CREATE INDEX ingestion_order ON clients(id)"
  setFileMode (root </> "coordination.sqlite3") 0o600
  withInstalled path $ \installed -> expect "partial version-six migration refuses" StoreUnavailable (withCoordinationStore installed (const (pure ())))
  bracket (rawOpen root) SQL.close $ \db -> do
    rawRows db "PRAGMA user_version" >>= check "failed ingestion migration leaves schema five" . (==[[SQL.SQLInteger 5]])
    rawRows db "SELECT count(*) FROM sqlite_master WHERE name='ingestion_immutable'" >>= check "failed ingestion migration rolls back prefix triggers" . (==[[SQL.SQLInteger 0]])
    SQL.exec db "DROP INDEX ingestion_order"
  withInstalled path $ \installed -> withCoordinationStore installed $ \store -> do
    storeIdentity store >>= check "schema five migrates to current version" . ((==schemaVersion) . storeSchemaVersion)
    rowsEqual store "SELECT id,revision,profile_id,root_identity,native_run_id,runtime_snapshot FROM runs" [[SQL.SQLText "old_run",SQL.SQLText "old_revision",SQL.SQLText "old_profile",SQL.SQLText "old_root",SQL.SQLText "old_native",SQL.SQLNull]] >>= check "ingestion migration preserves old associations without inventing evidence"
    rowsEqual store "SELECT authority_epoch,stream_id FROM service_metadata" [[SQL.SQLText "old_epoch",SQL.SQLText "old_stream"]] >>= check "ingestion migration preserves durable authority and stream"
    count store "start_intents" >>= check "ingestion migration reconstructs no accepted start" . (==0)

-- Focused Store checks. Execution requires a separately authorized fresh fixture.
terminalAdmissionChecks :: FilePath -> IO ()
terminalAdmissionChecks work = do
  (path,_) <- fixture work "terminal-admission"
  withInstalled path $ \installed -> withCoordinationStore installed $ \store -> do
    entered <- newIORef (0::Int)
    let markedClock = modifyIORef' entered (+1) >> pure 0
        marked = withCommitDeadline store markedClock 1 $ \guard ->
          runTransactionWithAdmission WaitWithinBudget store (enforceCommitDeadline guard >> pure((),[]))
    withHeld store $ \release -> do
      expect "ordinary Store callers still refuse the held gate" StoreBusy (runRead store (pure ()))
      withAsync marked $ \waiter -> do
        StoreAdmissionCheck.blocked waiter
        readIORef entered >>= check "waiting Store action has not reached its commit check" . (==0)
        release
        wait waiter
    readIORef entered >>= check "released terminal Store action executes once" . (==1)
    writeIORef entered 0
    withHeld store $ \release -> withAsync marked $ \waiter -> do
      StoreAdmissionCheck.blocked waiter
      throwTo (asyncThreadId waiter) UserInterrupt
      result <- waitCatch waiter
      check "Store admission interruption preserves original exception"
        (case result of Left failure -> fromException failure==Just UserInterrupt; _->False)
      release
    readIORef entered >>= check "interrupted Store action never runs after release" . (==0)
    withHeld store $ \release -> do
      let delayed = withCommitDeadline store (modifyIORef' entered (+1) >> threadDelay 3000000 >> pure 0) 1 $ \guard ->
            runTransactionWithAdmission WaitWithinBudget store (enforceCommitDeadline guard >> pure((),[]))
      withAsync (try @StoreFailure delayed) $ \waiter -> do
        StoreAdmissionCheck.blocked waiter
        threadDelay 3000000
        release
        result <- wait waiter
        check "three seconds waiting leaves less than three seconds for execution" (result==Left StoreDeadline)
    readIORef entered >>= check "execution deadline does not replay admitted action" . (==1)
    writeIORef entered 0
    withCommitDeadline store (modifyIORef' entered (+1) >> throwIO(userError "admitted publication failure")) 1 $ \guard ->
      expect "admitted action failure is not retried" StoreUnavailable
        (runTransactionWithAdmission WaitWithinBudget store (enforceCommitDeadline guard >> pure((),[])))
    readIORef entered >>= check "failing admitted body executed once" . (==1)
    runTransaction store $ do
      execute "INSERT INTO clients VALUES ('terminal_client','revision','authority',0)" []
      execute "INSERT INTO requests(id,revision,client_id,workflow_id,descriptor_revision,profile_id,profile_revision,phase,admission,blocking_reasons,validation_errors) VALUES ('terminal_request','revision','terminal_client','workflow','descriptor','profile','policy','draft','not-queued',?,?)" [SQL.SQLBlob "[]",SQL.SQLBlob "[]"]
      pure((),[Invalidation "service.changed" "/v1/capabilities" "terminal_seed"])
    expect "deferred commit failure remains uncertain and is not retried" StoreUnavailable $
      runTransactionWithAdmission WaitWithinBudget store $ do
        execute "UPDATE requests SET enqueue_command='missing_command' WHERE id='terminal_request'" []
        pure((),[Invalidation "service.changed" "/v1/capabilities" "terminal_poison"])
    expect "poisoned Store refuses terminal action before its body" StorePoisoned marked
    readIORef entered >>= check "poisoned Store never enters later body" . (==1)
    retryStoreCleanup store
    expect "closed Store refuses terminal action" StoreClosed marked
    readIORef entered >>= check "closed Store never enters later body" . (==1)
  where
    withHeld store action = do
      held <- newEmptyMVar
      resume <- newEmptyMVar
      let clock = putMVar held () >> readMVar resume >> pure 0
          release = void(tryPutMVar resume ())
      withCommitDeadline store clock 1 $ \guard ->
        bracket (async(runTransaction store (enforceCommitDeadline guard >> pure((),[]))))
          (\holder -> release >> cancel holder) $ \holder -> do
            timeout 1000000(takeMVar held) >>= maybe(error "Store holder not admitted")pure
            value <- action release
            release
            wait holder
            pure value
