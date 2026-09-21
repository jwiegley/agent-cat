{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
module Main (main) where

import Agentic.Manager.Artifacts
import Agentic.Manager.Protocol.Artifact (validExportDocument)
import Agentic.Manager.Authorization
import qualified Agentic.Manager.Commands as Commands
import Agentic.Manager.Configuration
import Agentic.Manager.Profile (Diagnostic (..))
import qualified Agentic.Manager.Protocol.Command as Command
import Agentic.Manager.State
import Agentic.Manager.Schema (schemaVersion, schemaStatements, commandMigration, draftMigration, admissionMigration, approvalMigration, ingestionMigration, controlMigration)
import Agentic.Manager.Store
import Agentic.Runtime hiding (Checkpoint)
import Control.Concurrent.Async (AsyncCancelled (..), async, cancel, concurrently, wait, waitCatch, withAsync)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.DeepSeq (NFData, force)
import Control.Exception (IOException, bracket, evaluate, fromException, throwIO, try)
import Control.Monad (forM_, unless, void)
import Crypto.Hash (Digest, SHA256, hash)
import Data.Aeson (Value (..), object, (.=), eitherDecodeStrict')
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import Data.ByteArray (convert)
import Data.Foldable (toList)
import Data.IORef (newIORef, readIORef, writeIORef)
import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as T
import qualified Database.SQLite3 as SQL
import System.Directory (createDirectory, renameDirectory, renameFile, removeFile)
import System.Environment (getArgs)
import System.FilePath ((</>))
import System.IO (hSetBuffering, stdout, BufferMode (LineBuffering))
import System.IO.Error (isDoesNotExistError, isPermissionError)
import System.Posix.Files (createSymbolicLink, setFileMode)

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  args <- getArgs
  case args of
    ["retention",work] -> retentionChecks work
    ["composition",work] -> compositionChecks work
    [work,source] -> do
      createDirectory(work </> "composition")
      compositionChecks(work </> "composition")
      createDirectory(work </> "retention")
      retentionChecks(work </> "retention")
      artifactChecks work source
    _ -> error "usage: manager-artifact-check [retention|composition] PRIVATE_DIRECTORY [PACKAGE_DIRECTORY]"

compositionChecks :: FilePath -> IO ()
compositionChecks work = do
  (config,_) <- fixture work
  withInstalled config $ \installed -> withCoordinationStore installed $ \store -> do
    seed store
    proof <- authenticateCredential store bearer >>= right
    (association,reference,directory) <- sourceRun store
    ingest store association reference
    entered <- newIORef False
    let outputs = withRunOutputs store proof association
        refused label action = do
          outcome <- try @StoreFailure (void action)
          check label (outcome == Left StoreLimit)
        verified = outputs $ \items -> check "charged profile projection returns verified output"
          (field "state" (field "verification" (last items)) == String "verified")
    withStoreReader store $ do
      verified
      withStoreReader store $ do
        refused "output quota refuses before response" (outputs (\_ -> writeIORef entered True))
        refused "standalone restoration shares reader quota" (restoreRunProjection store association)
        refused "historical terminal observation shares reader quota" (observeRetainedTerminal store association)
        refused "ingestion shares reader quota" (ingest store association reference)
      readIORef entered >>= check "quota refusal never enters output callback" . not
      document <- BS.readFile config >>= right . eitherDecodeStrict'
      case document of
        Object fields | Just(Object limits) <- KM.lookup "limits" fields ->
          BS.writeFile config (Command.encoded (Object(KM.insert "limits" (Object(KM.insert "globalDatabaseReaders" (Number 1) limits)) fields)))
        _ -> error "configuration fixture shape"
      replacement <- loadConfiguration (\args -> if null args then Right () else error "unexpected target") exactPreparedTarget (const False) config >>= right
      void (reloadConfiguration installed replacement >>= right)
      refused "output uses current lowered global quota" (outputs (\_ -> error "stale reader allowance"))
    outputs $ \_ -> do
      locked <- withStoreConfiguration store (\_ _ -> pure ())
      check "profile configuration remains held through response" (locked == Left SupervisionUnavailable)
      files <- try @StoreFailure (withStoreFiles store (\_ -> pure ()))
      check "original file owner remains held through response" (files == Left StoreBusy)
    failed <- try @StoreFailure (outputs (\_ -> throwIO StoreIntegrity))
    check "response failure remains original failure" (failed == Left StoreIntegrity)
    verified
    ready <- newEmptyMVar
    blocked <- newEmptyMVar
    withAsync (outputs (\_ -> putMVar ready () >> takeMVar blocked)) $ \reader -> do
      takeMVar ready
      cancel reader
      outcome <- waitCatch reader
      check "response interruption joins original reader" (case outcome of Left failure -> fromException failure == Just AsyncCancelled; _ -> False)
    verified
    original <- BS.readFile (directory </> "result.json")
    BS.writeFile (directory </> "result.json") "corrupt"
    outputs $ \items -> check "charged profile projection reports unavailable output"
      (field "state" (field "verification" (last items)) == String "unavailable")
    BS.writeFile (directory </> "result.json") original
    verified
    absent <- try @Command.CommandFailure (withRunOutputs store proof (association {associationProfile="profile_missing"}) (\_ -> error "absent profile response"))
    check "current profile membership still required" (absent == Left Command.Forbidden)
    verified
    mutate store (execute "DELETE FROM credential_scopes WHERE credential_id='credential_1'" [])
    denied <- try @Command.CommandFailure (outputs (\_ -> error "unauthorized output response"))
    check "current client authorization still required" (denied == Left Command.Forbidden)
    withStoreReader store (check "authorization failure releases sole reader capacity" True)

retentionChecks :: FilePath -> IO ()
retentionChecks work = do
  (config,_) <- fixture work
  withInstalled config $ \installed -> withCoordinationStore installed $ \store -> do
    (association,reference,_) <- sourceRun store
    seed store
    proof <- authenticateCredential store bearer >>= right
    ingest store association reference
    scalar store "SELECT CAST(terminal_observed AS TEXT) FROM runs" >>= check "independent observer prefix has shared validated Runtime terminal evidence" . (=="1")
    exportRequest <- request store association "retention" "retained.json"
    submitted <- submitExport store proof association exportRequest >>= right
    let ident=Command.receiptId(Commands.submissionReceipt submitted)
        exportId="export_"<>ident
    scalar store "SELECT state FROM commands" >>= check "actual export owner records its independent completed effect" . (=="effect-observed")
    public <- readExport store proof exportId
    let artifact=T.drop(T.length "/v1/artifacts/")(string(field "download" public))
    original <- newIORef Nothing
    withArtifactDownload store proof artifact $ \_ bytes -> do
      digest <- evaluate(force(convert(hash bytes :: Digest SHA256) :: BS.ByteString))
      writeIORef original (Just digest)
    void(Commands.retainReceipts store "" >>= right)
    scalar store "SELECT CAST(count(*) AS TEXT) FROM commands WHERE inactive_since IS NOT NULL AND retired=0" >>= check "terminal linked resource without unresolved work begins real inactivity observation" . (=="1")
    mutate store(execute "UPDATE commands SET inactive_since='2000-01-01T00:00:00Z'" [])
    void(Commands.retainReceipts store "" >>= right)
    receipt <- Commands.readCommand store proof ident
    check "completed linked-run receipt expires only after full observed interval" (case receipt of Left Command.ReceiptExpired -> True; _ -> False)
    withArtifactDownload store proof artifact $ \_ bytes -> do
      digest <- evaluate(force(convert(hash bytes :: Digest SHA256) :: BS.ByteString))
      expected <- readIORef original
      check "receipt retirement preserves independently referenced artifact bytes" (Just digest==expected)
    scalar store "SELECT CAST(count(*) AS TEXT) FROM ingestions" >>= check "receipt retirement retains original Runtime history" . (/="0")

artifactChecks :: FilePath -> FilePath -> IO ()
artifactChecks work source = do
  migrationChecks work
  reviewRegressions (work </> "review")
  documents <- documentFixtures source
  (config,root) <- fixture work
  sourceFixture <- BS.readFile (source </> "test/fixtures/manager/v1/valid/artifact-download.utf8")
  exportFixture <- BS.readFile (source </> "test/fixtures/manager/v1/valid/export-download.utf8")
  withInstalled config $ \installed -> do
    (association,handle,witness,unwitnessed,conflict) <- withCoordinationStore installed $ \store -> do
      (association,reference,directory) <- sourceRun store
      seed store
      proof <- authenticateCredential store bearer >>= right
      ingest store association reference
      handle <- scalar store "SELECT result_artifact_id FROM runs WHERE id='run_21'"
      actual <- BS.readFile (directory </> "result.json")
      check "native writer matches frozen captured source fixture" (actual == sourceFixture)
      withArtifactDownload store proof handle $ \metadata bytes -> do
        check "download is exact source bytes, not export document" (bytes == sourceFixture && bytes /= exportFixture)
        BS.writeFile (work </> "source-metadata.json") (Command.encoded metadata)
        BS.writeFile (work </> "source-download.utf8") bytes
      sequenceBefore <- scalar store "SELECT sequence FROM service_metadata"
      withArtifactDownload store proof handle (\_ bytes -> check "repeat observation still verifies captured bytes" (bytes == sourceFixture))
      sequenceAfter <- scalar store "SELECT sequence FROM service_metadata"
      check "unchanged successful verification creates no duplicate invalidation" (sequenceBefore == sequenceAfter)
      withRunOutputs store proof association $ \items -> do
        check "attempt, diagnostic and verified result remain distinct" (map (field "kind") items == map String ["attempt","diagnostic","result"])
        BS.writeFile (work </> "outputs.json") (Command.encoded items)
      rawChecks store proof association handle reference directory sourceFixture
      typedDocuments store proof documents
      outputBounds store proof work
      exportRequest <- request store association "main" "review-result.json"
      submission <- submitExport store proof association exportRequest >>= right
      let exportId = "export_" <> Command.receiptId (Commands.submissionReceipt submission)
      receipt <- readExport store proof exportId
      check "published receipt omits server path" (field "state" receipt == String "published" && not (has "path" receipt))
      BS.writeFile (work </> "export-receipt.json") (Command.encoded receipt)
      let exportHandle = T.drop (T.length "/v1/artifacts/") (string (field "download" receipt))
      withArtifactDownload store proof exportHandle $ \metadata bytes -> do
        check "download is exact distinct frozen export bytes" (bytes == exportFixture && exportHandle /= handle)
        BS.writeFile (work </> "export-metadata.json") (Command.encoded metadata)
        BS.writeFile (work </> "export-download.utf8") bytes
      replay <- submitExport store proof association exportRequest >>= right
      check "same key replays immutable acceptance without publication authority" (Commands.submissionReplayed replay && noTicket replay)
      authChecks store proof association handle exportHandle exportId
      runtimeRaces store association reference
      withStoreFiles store $ \managerRoot -> bracket (openPrivateSubroot managerRoot ["runs"]) closePrivateRoot $ \runs -> do
        writePrivateExclusiveAt runs ["exports","foreign.json"] exportFixture
        writePrivateExclusiveAt runs ["exports","different.json"] "foreign"
      conflict <- submitNamed store proof association "foreign"
      check "identical pre-existing bytes do not prove our publication" =<< ((== String "unresolved") . field "state" <$> reconcileExport store proof conflict)
      foreignCommand <- scalar store "SELECT state FROM commands WHERE id=(SELECT command_id FROM exports WHERE name='foreign.json')"
      check "known identical existing destination is a refusal" (foreignCommand == "refused")
      different <- submitNamed store proof association "different"
      check "conflicting destination remains unchanged" =<< ((== "foreign") <$> BS.readFile (root </> "runs/exports/different.json"))
      check "known conflicting destination has no false receipt" =<< ((== String "unresolved") . field "state" <$> readExport store proof different)
      badRequests store proof association
      competing <- request store association "second-owner" "review-result.json" >>= submitExport store proof association
      check "second command cannot own existing intended destination" (case competing of Left Command.StateConflict -> True; _ -> False)
      withRaw root $ \db -> SQL.exec db "CREATE TRIGGER fail_export_completion BEFORE UPDATE OF effect_evidence ON commands WHEN NEW.operation='export' AND NEW.effect_evidence IS NOT NULL BEGIN SELECT RAISE(ABORT,'fixture completion failure'); END"
      lost <- request store association "witness" "witness.json"
      failure <- try @Command.CommandFailure (submitExport store proof association lost)
      check "completion fault is preserved after durable publisher witness" (case failure of Left Command.StorageUnavailable -> True; _ -> False)
      witness <- scalar store "SELECT id FROM exports WHERE name='witness.json' AND receipt IS NOT NULL AND state='unresolved'"
      withRaw root $ \db -> SQL.exec db "DROP TRIGGER fail_export_completion"
      withRaw root $ \db -> SQL.exec db "CREATE TRIGGER fail_export_witness BEFORE UPDATE OF receipt ON exports WHEN NEW.receipt IS NOT NULL BEGIN SELECT RAISE(ABORT,'fixture witness failure'); END"
      lostBeforeWitness <- request store association "unwitnessed" "unwitnessed.json"
      noWitness <- try @StoreFailure (submitExport store proof association lostBeforeWitness)
      check "publication without durable witness preserves first storage failure" (case noWitness of Left StoreUnavailable -> True; _ -> False)
      unwitnessed <- scalar store "SELECT id FROM exports WHERE name='unwitnessed.json' AND receipt IS NULL AND state='unresolved'"
      withRaw root $ \db -> SQL.exec db "DROP TRIGGER fail_export_witness"
      check "unwitnessed complete destination really exists" =<< ((== exportFixture) <$> BS.readFile (root </> "runs/exports/unwitnessed.json"))
      exportSubstitution store proof exportHandle root
      pure (association,handle,witness,unwitnessed,conflict)
    withCoordinationStore installed $ \store -> do
      proof <- authenticateCredential store bearer >>= right
      let witnessedPath=root </> "runs/exports/witness.json"
      BS.writeFile witnessedPath "conflicting bytes"
      corrupted <- try @Command.CommandFailure (reconcileExport store proof witness)
      check "durable witness alone cannot bypass current byte verification" (corrupted == Left Command.ResourceUnavailable)
      observed <- readExport store proof witness
      check "failed verification leaves witnessed publication unresolved" (field "state" observed == String "unresolved")
      BS.writeFile witnessedPath exportFixture
      epoch <- storeAuthorityEpoch <$> storeIdentity store
      mutate store $ execute "UPDATE service_metadata SET authority_epoch='authority_changed'" []
      changedAuthority <- try @Command.CommandFailure (reconcileExport store proof witness)
      check "reopen evidence cannot cross authority epoch" (changedAuthority == Left Command.OwnershipUnavailable)
      mutate store $ execute "UPDATE service_metadata SET authority_epoch=?" [SQL.SQLText epoch]
      recovered <- reconcileExport store proof witness
      check "reopen completes only witnessed verified publication" (field "state" recovered == String "published")
      state <- scalar store "SELECT state FROM commands WHERE id=(SELECT command_id FROM exports WHERE name='witness.json')"
      check "export and command effect observed atomically after reopen" (state == "effect-observed")
      missingWitness <- reconcileExport store proof unwitnessed
      check "reopen does not adopt filesystem-only publication" (field "state" missingWitness == String "unresolved" && field "download" missingWitness == Null)
      refused <- reconcileExport store proof conflict
      check "reopen does not adopt identical foreign publication" (field "state" refused == String "unresolved")
      check "reconciliation never changes existing bytes" =<< ((== exportFixture) <$> BS.readFile (root </> "runs/exports/unwitnessed.json"))
      withArtifactDownload store proof handle (\_ bytes -> check "trusted handle survives reopen without journal" (bytes == sourceFixture))
      withRunExports store proof association $ \items -> do
        check "run export collection exposes published and unresolved receipts separately"
          (length items == 5 && length [() | item <- items,field "state" item == String "published"] == 2
            && length [() | item <- items,field "state" item == String "unresolved",field "download" item == Null] == 3)
        BS.writeFile (work </> "export-items.json") (Command.encoded items)
      rootSubstitution store proof association handle root
  putStrLn "PASS deterministic manager artifacts A11/A12/A21 primitives, no native process execution"

-- Durable acceptance integrity and collection revision regressions from WM-017 review.
reviewRegressions :: FilePath -> IO ()
reviewRegressions work = do
  createDirectory work
  (config,root) <- fixture work
  (association,witness) <- withInstalled config $ \installed -> withCoordinationStore installed $ \store -> do
    seed store
    proof <- authenticateCredential store bearer >>= right
    (association,reference,directory) <- sourceRun store
    ingest store association reference
    handle <- scalar store "SELECT result_artifact_id FROM runs WHERE id='run_21'"
    let result=directory </> "result.json"
    original <- BS.readFile result
    withArtifactDownload store proof handle (\_ _ -> pure ())
    staleVerified <- request store association "stale-verified" "stale-verified.json"
    verifiedRevision <- scalar store "SELECT revision FROM artifacts WHERE id=(SELECT result_artifact_id FROM runs WHERE id='run_21')"
    BS.writeFile result "corrupt"
    withRunOutputs store proof association (\_ -> pure ())
    unavailableRevision <- scalar store "SELECT revision FROM artifacts WHERE id=(SELECT result_artifact_id FROM runs WHERE id='run_21')"
    BS.writeFile result original
    withArtifactDownload store proof handle (\_ _ -> pure ())
    restoredRevision <- scalar store "SELECT revision FROM artifacts WHERE id=(SELECT result_artifact_id FROM runs WHERE id='run_21')"
    check "verified unavailable verified transitions have distinct revisions"
      (verifiedRevision /= unavailableRevision && restoredRevision /= verifiedRevision && restoredRevision /= unavailableRevision)
    assertStale store proof association staleVerified "verification ABA cannot revive collection If-Match"
    first <- submitNamed store proof association "revision-a"
    staleFirst <- request store association "stale-a" "stale-a.json"
    _ <- submitNamed store proof association "revision-b"
    before <- observationState store
    receipt <- reconcileExport store proof first
    after <- observationState store
    check "A B reconcile-A leaves all revisions receipts and invalidations unchanged" (before == after && field "state" receipt == String "published")
    assertStale store proof association staleFirst "published reconciliation cannot revive collection If-Match"
    base <- request store association "bound" "bound.json"
    let raw="{ \"name\" : \"bound.json\" }\n"
        req=base {Commands.commandBody=raw}
    withRaw root $ \db -> SQL.exec db "CREATE TRIGGER fail_review_completion BEFORE UPDATE OF effect_evidence ON commands WHEN NEW.operation='export' AND NEW.effect_evidence IS NOT NULL BEGIN SELECT RAISE(ABORT,'injected review completion failure'); END"
    failed <- try @Command.CommandFailure (submitExport store proof association req)
    check "review fixture preserves genuine publisher witness before failed completion" (case failed of Left Command.StorageUnavailable -> True; _ -> False)
    withRaw root $ \db -> SQL.exec db "DROP TRIGGER fail_review_completion"
    command <- scalar store "SELECT command_id FROM exports WHERE name='bound.json'"
    let witness="export_"<>command
    exact <- runRead store $ do
      rows <- query "SELECT body,body_sha256,body_bytes FROM commands WHERE id=?" [SQL.SQLText command]
      pure (rows == [[SQL.SQLNull,SQL.SQLBlob (convert (hash raw::Digest SHA256)),SQL.SQLInteger (fromIntegral (BS.length raw))]])
    check "accepted whitespace body retains exact digest and count without generic body" exact
    replay <- submitExport store proof association req >>= right
    check "identical whitespace body replays acceptance without dispatch authority" (Commands.submissionReplayed replay && noTicket replay)
    different <- submitExport store proof association base
    check "whitespace-distinct equivalent name remains raw-body idempotency conflict" (case different of Left Command.IdempotencyConflict -> True; _ -> False)
    mutate store $ execute "INSERT INTO runs(id,revision,control_revision,profile_id,root_identity,native_run_id,supervision,result_state) VALUES ('run_other','revision','revision','profile_1',?,'native-other','observer','absent')" [SQL.SQLText (associationRoot association)]
    acceptanceTampering store proof root witness command req
    pure (association,witness)
  withInstalled config $ \installed -> withCoordinationStore installed $ \store -> do
    proof <- authenticateCredential store bearer >>= right
    published <- reconcileExport store proof witness
    check "untampered whitespace acceptance reconciles after reopen" (field "state" published == String "published" && field "runId" published == String (associationRun association))
    before <- observationState store
    again <- reconcileExport store proof witness
    after <- observationState store
    check "reopened published reconciliation is observationally idempotent" (before == after && published == again)

assertStale :: CoordinationStore -> CredentialProof -> RunAssociation -> Commands.CommandRequest -> String -> IO ()
assertStale store proof association req label = do
  before <- observationState store
  outcome <- submitExport store proof association req
  after <- observationState store
  check label (case outcome of Left Command.StaleRevision -> before == after; _ -> False)

observationState :: CoordinationStore -> IO [[[String]]]
observationState store = runRead store $ mapM (\statement -> map (map show) <$> query statement [])
  ["SELECT * FROM runs ORDER BY id","SELECT * FROM artifacts ORDER BY id","SELECT * FROM exports ORDER BY id",
   "SELECT * FROM commands ORDER BY id","SELECT * FROM service_metadata",
   "SELECT * FROM invalidations ORDER BY stream_id,sequence"]

acceptanceTampering :: CoordinationStore -> CredentialProof -> FilePath -> Text -> Text -> Commands.CommandRequest -> IO ()
acceptanceTampering store proof root witness command req = do
  (receiptBytes,privateBytes,witnessBytes) <- runRead store $ do
    rows <- query "SELECT c.receipt,a.private_reference,e.receipt FROM exports e JOIN commands c ON c.id=e.command_id JOIN artifacts a ON a.id=e.artifact_id WHERE e.id=?" [SQL.SQLText witness]
    case rows of [[SQL.SQLBlob a,SQL.SQLBlob b,SQL.SQLBlob c]] -> pure (a,b,c); _ -> refuseTransaction StoreIntegrity
  receipt <- right (Command.decodeReceipt receiptBytes)
  private <- right (eitherDecodeStrict' privateBytes)
  published <- right (eitherDecodeStrict' witnessBytes)
  let set key value (Object fields)=Object (KM.insert (Key.fromText key) value fields)
      set _ _ value=value
      privateChange value=execute "UPDATE artifacts SET private_reference=? WHERE id=(SELECT artifact_id FROM exports WHERE id=?)" [SQL.SQLBlob (Command.encoded value),SQL.SQLText witness]
      receiptChange value=execute "UPDATE commands SET receipt=? WHERE id=?" [SQL.SQLBlob (Command.encoded value),SQL.SQLText command]
      commandChange column value=execute ("UPDATE commands SET "<>column<>"=? WHERE id=?") [value,SQL.SQLText command]
      otherProfile=receipt {Command.receiptProfile="profile_other"}
      otherResource=receipt {Command.receiptResource="/v1/runs/run_other/exports"}
      raw=Commands.commandBody req
      canonical=Command.encoded (object ["name" .= ("bound.json"::Text)])
      restore = do
        execute "UPDATE commands SET profile_id='profile_1',resource_uri=?,operation='export',run_id='run_21',receipt=?,body_sha256=?,body_bytes=? WHERE id=?"
          [SQL.SQLText (Commands.commandResource req),SQL.SQLBlob receiptBytes,SQL.SQLBlob (convert (hash raw::Digest SHA256)),SQL.SQLInteger (fromIntegral (BS.length raw)),SQL.SQLText command]
        execute "UPDATE exports SET name='bound.json',receipt=? WHERE id=?" [SQL.SQLBlob witnessBytes,SQL.SQLText witness]
        execute "UPDATE artifacts SET private_reference=? WHERE id=(SELECT artifact_id FROM exports WHERE id=?)" [SQL.SQLBlob privateBytes,SQL.SQLText witness]
  exact <- pure (field "acceptedName" private == String "bound.json"
    && field "acceptedBodySha256" private == String (T.pack (show (hash raw::Digest SHA256)))
    && field "acceptedBodyBytes" private == String (T.pack (show (BS.length raw))))
  check "private provenance binds accepted parsed name and exact incoming bytes" exact
  let destination=root </> "runs/exports/bound.json"
      foreignDestination=root </> "runs/exports/other-bound.json"
  bytes <- BS.readFile destination
  withStoreFiles store $ \retained -> writePrivateExclusiveAt retained ["runs","exports","other-bound.json"] bytes
  forM_
    [("receipt cross-profile",receiptChange otherProfile),
     ("row cross-profile",commandChange "profile_id" (SQL.SQLText "profile_other")),
     ("row and receipt cross-profile",commandChange "profile_id" (SQL.SQLText "profile_other") >> receiptChange otherProfile),
     ("receipt cross-resource with matching link",receiptChange otherResource),
     ("row cross-resource",commandChange "resource_uri" (SQL.SQLText "/v1/runs/run_other/exports")),
     ("row and receipt cross-resource",commandChange "resource_uri" (SQL.SQLText "/v1/runs/run_other/exports") >> receiptChange otherResource),
     ("receipt wrong operation",receiptChange (receipt {Command.receiptOperation=Command.Cancel})),
     ("row wrong operation",commandChange "operation" (SQL.SQLText "cancel")),
     ("row cross-run",commandChange "run_id" (SQL.SQLText "run_other")),
     ("accepted name mismatch",privateChange (set "acceptedName" (String "other-bound.json") private)),
     ("intended name with matching witness and foreign bytes",execute "UPDATE exports SET name='other-bound.json',receipt=? WHERE id=?" [SQL.SQLBlob (Command.encoded (set "name" (String "other-bound.json") published)),SQL.SQLText witness]),
     ("missing older acceptance binding",privateChange (object ["exportId" .= witness,"bytes" .= field "bytes" private])),
     ("unknown private binding field",privateChange (set "extra" Null private)),
     ("noncanonical private byte count",privateChange (set "acceptedBodyBytes" (String ("0"<>T.pack (show (BS.length raw)))) private)),
     ("canonical body substituted in private binding",privateChange (set "acceptedBodySha256" (String (T.pack (show (hash canonical::Digest SHA256)))) (set "acceptedBodyBytes" (String (T.pack (show (BS.length canonical)))) private))),
     ("canonical body substituted in command binding",commandChange "body_sha256" (SQL.SQLBlob (convert (hash canonical::Digest SHA256))) >> commandChange "body_bytes" (SQL.SQLInteger (fromIntegral (BS.length canonical))))] $ \(label,tamper) -> do
       mutate store tamper
       before <- observationState store
       outcome <- try @Command.CommandFailure (reconcileExport store proof witness)
       after <- observationState store
       current <- BS.readFile destination
       foreignBytes <- BS.readFile foreignDestination
       check (label<>" refuses with complete rollback and no publication replay")
         (outcome == Left Command.OwnershipUnavailable && before == after && current == bytes && foreignBytes == bytes)
       mutate store restore

migrationChecks :: FilePath -> IO ()
migrationChecks work = do
  let directory=work </> "migration"
  createDirectory directory
  (config,root) <- fixture directory
  withInstalled config (const (pure ()))
  original <- withRaw root $ \db -> do
    mapM_ (SQL.exec db) (schemaStatements<>commandMigration<>draftMigration<>admissionMigration<>approvalMigration<>ingestionMigration<>controlMigration)
    SQL.exec db "PRAGMA user_version=7; INSERT INTO service_metadata VALUES (1,'authority_legacy','stream_legacy','0','0','r'); INSERT INTO clients VALUES ('client','r','a',0)"
    SQL.exec db "INSERT INTO runs(id,revision,control_revision,profile_id,root_identity,native_run_id,supervision,result_state) VALUES ('run','r','r','profile_1','root','native','observer','absent')"
    SQL.exec db "INSERT INTO artifacts VALUES ('artifact','r','run',X'007f',X'22666c616722','verified',NULL)"
    forM_ ["published","unresolved"] $ \state -> do
      SQL.exec db ("INSERT INTO commands(id,revision,profile_id,operation,client_id,authority_epoch,method,resource_uri,idempotency_key,body,media_type,receipt,retired,run_id,accepted_at,state) VALUES ('command_"<>state<>"','r','profile_1','export','client','authority_legacy','POST','/v1/runs/run/exports','key_"<>state<>"',X'007f','application/json',X'007f',0,'run','2026-09-03T00:00:00Z','accepted')")
      SQL.exec db ("INSERT INTO exports VALUES ('export_"<>state<>"','r','run','artifact','command_"<>state<>"','root','"<>state<>".json','digest',"<>(if state=="published" then "X'007f'" else "NULL")<>",'"<>state<>"')")
    SQL.exec db "CREATE VIEW migration_fault AS SELECT * FROM nonexistent_migration_fixture"
    rawRows db "SELECT * FROM exports ORDER BY id"
  withInstalled config $ \installed -> do
    failed <- try @StoreFailure (withCoordinationStore installed (const (pure ())))
    check "schema7 export migration failure remains explicit" (failed == Left StoreUnavailable)
  withRaw root $ \db -> do
    version <- rawRows db "PRAGMA user_version"
    rows <- rawRows db "SELECT * FROM exports ORDER BY id"
    leftover <- rawRows db "SELECT name FROM sqlite_master WHERE name='exports_v8'"
    check "failed migration rolls back copy, drop and version with all data intact" (version==[[SQL.SQLInteger 7]] && rows==original && null leftover)
    SQL.exec db "DROP VIEW migration_fault"
  withInstalled config $ \installed -> withCoordinationStore installed $ \store -> do
    identity <- storeIdentity store
    current <- runRead store ((==[[SQL.SQLInteger(fromIntegral schemaVersion)]]) <$> query "SELECT user_version FROM pragma_user_version" [])
    check "populated schema7 upgrades to current schema" (storeSchemaVersion identity==schemaVersion && current)
    preserved <- runRead store ((==original) <$> query "SELECT * FROM exports ORDER BY id" [])
    check "published and unresolved export rows retained byte-for-byte" preserved
    before <- scalar store "SELECT sequence FROM service_metadata"
    aborted <- try @StoreFailure $ mutate store $ do
      execute "INSERT INTO exports VALUES ('aborted','r','run','artifact','not-yet-command','root','aborted.json','digest',NULL,'unresolved')" []
      (refuseTransaction StoreIntegrity :: Transaction ())
    after <- scalar store "SELECT sequence FROM service_metadata"
    check "deferred intent still rolls back with owning transaction" (aborted==Left StoreIntegrity && before==after)
    missing <- try @StoreFailure $ mutate store $ execute "INSERT INTO exports VALUES ('missing','r','run','artifact','missing-command','root','missing.json','digest',NULL,'unresolved')" []
    check "missing export command rejected at commit" (missing==Left StoreUnavailable)
    poisoned <- try @StoreFailure (storeIdentity store)
    check "failed commit preserves existing Store poison fence" (case poisoned of Left StorePoisoned -> True; _ -> False)
  withInstalled config $ \installed -> withCoordinationStore installed $ \store -> do
    preserved <- runRead store ((==original) <$> query "SELECT * FROM exports ORDER BY id" [])
    integrity <- runRead store (null <$> query "SELECT * FROM pragma_foreign_key_check" [])
    check "fresh lifetime sees complete rollback and valid export foreign keys" (preserved && integrity)

withRaw :: FilePath -> (SQL.Database -> IO a) -> IO a
withRaw root action = do
  let path=root </> "coordination.sqlite3"
  bracket (SQL.open2 (T.pack path) [SQL.SQLOpenReadWrite,SQL.SQLOpenCreate,SQL.SQLOpenFullMutex,SQL.SQLOpenNoFollow] SQL.SQLVFSDefault) SQL.close $ \db -> do
    setFileMode path 0o600
    SQL.exec db "PRAGMA foreign_keys=ON"
    action db
rawRows :: SQL.Database -> Text -> IO [[SQL.SQLData]]
rawRows db statement = bracket (SQL.prepare db statement) SQL.finalize $ \prepared ->
  let loop n = SQL.step prepared >>= \result -> case result of
        SQL.Done -> pure []
        SQL.Row -> if n <= (0::Int) then error "fixture row bound" else (:) <$> SQL.columns prepared <*> loop (n-1)
  in loop 100

documentFixtures :: FilePath -> IO [Value]
documentFixtures source = do
  let directory=source </> "test/fixtures/manager/v1"
  manifest <- BS.readFile (directory </> "manifest.json") >>= right . eitherDecodeStrict'
  cases <- case field "cases" manifest of Array values -> pure (toList values); _ -> error "fixture manifest"
  documents <- mapM (\entry -> do
    value <- BS.readFile (directory </> T.unpack (string (field "file" entry))) >>= right . eitherDecodeStrict'
    check "frozen ExportDocument fixture agrees with public shape validator" (validExportDocument value == (field "valid" entry == Bool True))
    pure [value | field "valid" entry == Bool True]) [entry | entry <- cases, field "schema" entry == String "ExportDocument"]
  let rational=object ["code" .= object ["json" .= object ["schema" .= ("number"::Text)]],"value" .= object ["numerator" .= (1::Int),"denominator" .= (3::Int)]]
  check "native exact rational shape remains valid without decimal coercion" (validExportDocument rational)
  pure (concat documents <> [rational])

typedDocuments :: CoordinationStore -> CredentialProof -> [Value] -> IO ()
typedDocuments store proof documents = do
  forM_ (zip [0::Int ..] documents) $ \(index,document) -> withStoreFiles store $ \root -> do
    let name="typed-"<>show index
        native=RunId (T.pack name)
    ensurePrivateDirectoryAt root ["runs","runs",name]
    bracket (openPrivateSubroot root ["runs"]) closePrivateRoot $ \runs -> do
      let directory=privateRootPath runs </> "runs" </> name </> "runtime"
          code=field "code" document
          value=field "value" document
          manifest=RunManifest native "fixture" "0.1.0.0" Null "scripted" Null Nothing RootRun Nothing (Just PersonAnswerLocalControl)
      reference <- bracket (createRunStoreVersioned 2 2 directory manifest) closeRunStore $ \runtime -> writeResultArtifact runtime native code value "fixture"
      bracket (openPrivateRoot "typed fixture" directory) closePrivateRoot $ \runtime -> withPrivateDirectoryAt runtime [] $ \descriptor -> do
        (_,captured) <- readResultArtifactBytesAt directory descriptor native reference
        check "shared capture preserves frozen value without coercion" (captured == value)
      withPreparedResultExport runs native reference (T.pack name<>".json") $ \prepared -> do
        check "shared pre-publication identity retains exact document" (preparedExportDocument prepared == document)
        publishPreparedResultExport prepared
        (_,captured) <- readPublishedResultExportBytes runs (preparedExportRootIdentity prepared) (T.pack name<>".json") (preparedExportBytes prepared) (preparedExportSha256 prepared) code
        check "published typed document matches frozen decoded fixture" (captured == document)
  association <- withStoreFiles store $ \root -> do
    ensurePrivateDirectoryAt root ["runs","runs","bad-flag"]
    bracket (openPrivateSubroot root ["runs"]) closePrivateRoot $ \runs -> do
      let native=RunId "bad-flag"
          directory=privateRootPath runs </> "runs/bad-flag/runtime"
          bound=RunAssociation "run_bad_flag" "profile_1" (T.pack (privateRootIdentity runs)) native
          manifest=RunManifest native "fixture" "0.1.0.0" Null "scripted" Null Nothing RootRun Nothing (Just PersonAnswerLocalControl)
      reference <- bracket (createRunStoreVersioned 2 2 directory manifest) closeRunStore $ \runtime -> writeResultArtifact runtime native (String "flag") (String "synthetic-token") "fixture"
      mutate store $ execute "INSERT INTO runs(id,revision,control_revision,profile_id,root_identity,native_run_id,supervision,result_state) VALUES ('run_bad_flag','revision','revision','profile_1',?,'bad-flag','observer','absent')" [SQL.SQLText (associationRoot bound)]
      forM_ (zip [0..] [RunStartedV2 "fixture" "scripted" PersonAnswerLocalControl,TraceOrdered [],RunCompletedV2 0 0 reference]) $ \(number,event) ->
        void (ingestRuntimeEnvelope store bound (encodeEnvelope (Envelope 2 native (SeqNo number) "2026-09-03T00:00:00Z" event)))
      pure bound
  handle <- scalar store "SELECT result_artifact_id FROM runs WHERE id='run_bad_flag'"
  refused <- try @Command.CommandFailure (withArtifactDownload store proof handle (\_ _ -> error "ill-typed response"))
  check "verified envelope with flag/string mismatch never becomes a response" (refused == Left Command.ResourceUnavailable)
  req <- request store association "bad-flag" "bad-flag.json"
  publication <- try @Command.CommandFailure (submitExport store proof association req)
  check "verified envelope with flag/string mismatch never becomes an export" (case publication of Left Command.ResourceUnavailable -> True; _ -> False)
  absent <- runRead store ((== [[SQL.SQLInteger 0]]) <$> query "SELECT count(*) FROM exports WHERE run_id='run_bad_flag'" [])
  check "ill-typed result creates no accepted publication intent" absent

check :: String -> Bool -> IO ()
check label condition = unless condition (error ("FAIL "<>label)) >> putStrLn ("PASS "<>label)
right :: Show e => Either e a -> IO a
right = either (error . show) pure
field :: Text -> Value -> Value
field key (Object fields) = maybe Null id (KM.lookup (fromString key) fields)
  where fromString = Key.fromText
field _ _ = Null
has :: Text -> Value -> Bool
has key (Object fields) = KM.member (Key.fromText key) fields
has _ _ = False
string :: Value -> Text
string (String value) = value
string _ = error "expected string"
noTicket :: Commands.Submission -> Bool
noTicket value = case Commands.submissionTicket value of Nothing -> True; _ -> False
mutate :: NFData a => CoordinationStore -> Transaction a -> IO a
mutate store action = runTransaction store $ do
  value <- action
  pure (value,[Invalidation "service.changed" "/v1/capabilities" "fixture"])
scalar :: CoordinationStore -> Text -> IO Text
scalar store sql = runRead store $ do
  rows <- query sql []
  case rows of [[SQL.SQLText value]] -> pure value; _ -> refuseTransaction StoreIntegrity
bearer :: BS.ByteString
bearer = BS.replicate 32 97

fixture :: FilePath -> IO (FilePath,FilePath)
fixture work = do
  let root=work </> "manager"; path=work </> "config.json"
  createDirectory root
  setFileMode root 0o700
  BS.writeFile path $ Command.encoded $ object
    ["version" .= (1::Int),"managerRoot" .= root,"localRetentionRoots" .= ([]::[String]),
     "runners" .= [object ["alias" .= ("runner"::Text),"executable" .= ("/bin/false"::Text),"prefix" .= ([]::[String])]],
     "profiles" .= [object ["id" .= ("profile_1"::Text),"runner" .= ("runner"::Text),"workspace" .= work,
       "workspaceLabel" .= ("fixture"::Text),"targetLabel" .= ("no execution"::Text),"targetArguments" .= ([]::[String]),
       "environment" .= ([]::[String]),"ownership" .= ("service-owned"::Text),"quarantined" .= False,
       "personAnswering" .= ("engine"::Text),"resourceKeys" .= ([]::[String])]],
     "limits" .= object ["drafts" .= (100::Int),"globalDrafts" .= (100::Int),"globalCaptureBytes" .= (67108864::Int),
       "globalPageSets" .= (2::Int),"globalConnections" .= (8::Int),"globalDatabaseReaders" .= (2::Int),
       "globalMutationLedgerBytes" .= (16777216::Int),"safetyControlsPerMinute" .= (100::Int),"executionReservations" .= (1::Int)]]
  setFileMode path 0o600
  pure (path,root)
withInstalled :: FilePath -> (InstalledConfiguration -> IO a) -> IO a
withInstalled path action = do
  config <- loadConfiguration (\args -> if null args then Right () else error "unexpected target") exactPreparedTarget (const False) path >>= right
  bracket (installConfiguration config >>= right) closeConfiguration action
seed :: CoordinationStore -> IO ()
seed store = mutate store $ do
  execute "INSERT INTO clients VALUES ('client_1','client_revision','authorization_revision',0)" []
  execute "INSERT INTO credentials VALUES ('credential_1','client_1',?,'2999-01-01T00:00:00Z',0)" [SQL.SQLBlob (convert (hash bearer::Digest SHA256))]
  forM_ ["observe","export"] $ \scope -> execute "INSERT INTO credential_scopes VALUES ('credential_1','profile_1',?)" [SQL.SQLText scope]

sourceRun :: CoordinationStore -> IO (RunAssociation,ResultRef,FilePath)
sourceRun store = withStoreFiles store $ \root -> do
  ensurePrivateDirectoryAt root ["runs","runs","native-21"]
  bracket (openPrivateSubroot root ["runs"]) closePrivateRoot $ \runs -> do
    let native=RunId "native-21"
        directory=privateRootPath runs </> "runs/native-21/runtime"
        association=RunAssociation "run_21" "profile_1" (T.pack (privateRootIdentity runs)) native
        manifest=RunManifest native "fixture" "0.1.0.0" Null "scripted" Null Nothing RootRun Nothing (Just PersonAnswerLocalControl)
    reference <- bracket (createRunStoreVersioned 2 2 directory manifest) closeRunStore $ \runtime -> writeResultArtifact runtime native (String "flag") (Bool False) "false"
    mutate store $ execute "INSERT INTO runs(id,revision,control_revision,profile_id,root_identity,native_run_id,supervision,result_state) VALUES ('run_21','revision','revision','profile_1',?,'native-21','observer','absent')" [SQL.SQLText (associationRoot association)]
    pure (association,reference,directory)

ingest :: CoordinationStore -> RunAssociation -> ResultRef -> IO ()
ingest store association reference = do
  let occurrence=OccurrenceId maxBound; attempt=AttemptId occurrence maxBound
      events=[RunStartedV2 "fixture" "scripted" PersonAnswerLocalControl,
        OccurrenceStarted occurrence "flag" "fixture" "engine" "synthetic prompt",
        AttemptStarted attempt "scripted",AttemptOutput attempt "雪😀\n",
        AttemptProgress attempt (ProgressMessage "Public diagnostic."),AttemptCompleted attempt "fresh",
        OccurrenceCompleted occurrence "fresh" "false",TraceOrdered [occurrence],RunCompletedV2 1 0 reference]
  forM_ (zip [0..] events) $ \(number,event) -> do
    let bytes = encodeEnvelope (Envelope 2 (associationNative association) (SeqNo number) "2026-09-03T00:00:00Z" event)
    void (ingestRuntimeEnvelope store association bytes)

outputBounds :: CoordinationStore -> CredentialProof -> FilePath -> IO ()
outputBounds store proof work = do
  rootIdentity <- scalar store "SELECT root_identity FROM runs WHERE id='run_21'"
  let native=RunId "bounded-output"
      association=RunAssociation "run_bounded" "profile_1" rootIdentity native
      occurrence=OccurrenceId 0
      attempt=AttemptId occurrence 0
      secret="synthetic-token <script>\ESC[31m"
      transport=T.replicate 70000 "x"<>secret
      diagnostic=T.replicate 9000 "d"<>secret
      events=[RunStartedV2 "fixture" "scripted" PersonAnswerLocalControl,
        OccurrenceStarted occurrence "text" "fixture" "engine" "private prompt",
        AttemptStarted attempt "scripted",AttemptOutput attempt transport,
        AttemptFailed attempt FailureTransport diagnostic,OccurrenceFailed occurrence FailureTransport diagnostic,
        RunFailed FailureRuntime diagnostic]
  mutate store $ execute "INSERT INTO runs(id,revision,control_revision,profile_id,root_identity,native_run_id,supervision,result_state) VALUES ('run_bounded','revision','revision','profile_1',?,'bounded-output','observer','absent')" [SQL.SQLText rootIdentity]
  forM_ (zip [0..] events) $ \(number,event) -> void $ ingestRuntimeEnvelope store association
    (encodeEnvelope (Envelope 2 native (SeqNo number) "2026-09-03T00:00:00Z" event))
  withRunOutputs store proof association $ \items -> do
    check "attempt transport retains bounded attributed tail" (case items of
      item:_ -> field "transportText" item == String (T.takeEnd 65536 transport)
      [] -> False)
    let diagnostics=[string (field "message" item) | item <- items,field "kind" item==String "diagnostic"]
    check "authorized diagnostics have independent 8192-character ceiling" (length diagnostics==2 && all ((==8192) . T.length) diagnostics)
    check "absent result remains distinct from runtime failure" (field "state" (field "verification" (last items))==String "absent")
    let wire=Command.encoded items
    check "JSON encoding carries control text without literal terminal escapes" (not ("\ESC[31m" `BS.isInfixOf` wire))
    BS.writeFile (work </> "bounded-outputs.json") wire

rawChecks :: CoordinationStore -> CredentialProof -> RunAssociation -> Text -> ResultRef -> FilePath -> BS.ByteString -> IO ()
rawChecks store proof association handle reference directory original = do
  let result=directory </> "result.json"
      download=withArtifactDownload store proof handle (\_ _ -> error "unverified content reached response")
  BS.writeFile result "synthetic-token <script>\ESC[31m provider diagnostic"
  failed <- try @Command.CommandFailure download
  check "corrupt content never reaches response or incidental exception" (failed == Left Command.ResourceUnavailable)
  withRunOutputs store proof association $ \items -> do
    check "corrupt result is unavailable independently" (field "state" (field "verification" (last items)) == String "unavailable")
    check "sensitive bytes absent from unavailable output" (not ("synthetic-token" `BS.isInfixOf` Command.encoded items))
  snapshot <- requireProjection store association
  check "corrupt result does not change runtime success" (snapshotRunStatus snapshot == RunSucceeded)
  BS.writeFile result original
  BS.writeFile (directory </> "events.ndjson") "not a journal"
  withArtifactDownload store proof handle (\_ bytes -> check "good known reference ignores damaged journal" (bytes == original))
  withArtifactDownload store proof handle $ \_ captured -> do
    BS.writeFile result "changed after capture"
    check "response owns captured bytes rather than a reopened file" (captured == original)
  BS.writeFile result original
  renameFile result (result<>".retained")
  withRunOutputs store proof association $ \items ->
    check "missing result has its distinct unavailable reason" (field "reason" (field "verification" (last items)) == String "missing")
  bracket (openPrivateRoot "missing fixture" directory) closePrivateRoot $ \runtime -> withPrivateDirectoryAt runtime [] $ \descriptor -> do
    legacy <- try @StoreError (readResultArtifactAt directory descriptor (associationNative association) reference)
    captured <- try @IOException (readResultArtifactBytesAt directory descriptor (associationNative association) reference)
    check "legacy missing result retains StoreCorrupt exception" (case legacy of Left (StoreCorrupt _ _) -> True; _ -> False)
    check "captured missing result preserves original typed ENOENT" (case captured of Left failure -> isDoesNotExistError failure; _ -> False)
  createSymbolicLink (result<>".retained") result
  symlink <- try @Command.CommandFailure download
  check "source leaf symlink cannot produce content" (symlink == Left Command.ResourceUnavailable)
  removeFile result
  renameFile (result<>".retained") result
  setFileMode result 0o000
  withRunOutputs store proof association $ \items ->
    check "unreadable result has fixed ownership-unavailable status" (field "reason" (field "verification" (last items)) == String "ownership-unavailable")
  bracket (openPrivateRoot "mode fixture" directory) closePrivateRoot $ \runtime -> withPrivateDirectoryAt runtime [] $ \descriptor -> do
    legacy <- try @StoreError (readResultArtifactAt directory descriptor (associationNative association) reference)
    captured <- try @IOException (readResultArtifactBytesAt directory descriptor (associationNative association) reference)
    check "legacy permission failure retains StoreCorrupt exception" (case legacy of Left (StoreCorrupt _ _) -> True; _ -> False)
    check "captured permission failure preserves typed IO refusal" (case captured of Left failure -> isPermissionError failure; _ -> False)
  setFileMode result 0o600
  bracket (openPrivateRoot "fixture runtime" directory) closePrivateRoot $ \runtime ->
    withPrivateDirectoryAt runtime [] $ \descriptor -> do
      forM_ [("wrong run",RunId "other",reference),("wrong code",associationNative association,reference {resultArtifactCode=String "text"}),
        ("wrong hash",associationNative association,reference {resultArtifactSha256=T.replicate 64 "0"}),
        ("wrong size",associationNative association,reference {resultArtifactBytes=resultArtifactBytes reference-1}),
        ("wrong reference version",associationNative association,reference {resultArtifactVersion=2}),
        ("oversized reference",associationNative association,reference {resultArtifactBytes=maxArtifactBytes+1})] $ \(label,native,ref) -> do
          bad <- try @StoreError (readResultArtifactBytesAt directory descriptor native ref)
          check label (case bad of Left (StoreCorrupt _ _) -> True; _ -> False)
      let noncanonical=original<>"\n"
          expected=reference {resultArtifactBytes=toInteger (BS.length noncanonical),resultArtifactSha256=T.pack (show (hash noncanonical::Digest SHA256))}
      BS.writeFile result noncanonical
      legacy <- try @StoreError (readResultArtifactAt directory descriptor (associationNative association) expected)
      captured <- try @StoreError (readResultArtifactBytesAt directory descriptor (associationNative association) expected)
      check "both reader surfaces reject correctly hashed noncanonical bytes" (case (legacy,captured) of
        (Left (StoreCorrupt _ _),Left (StoreCorrupt _ _)) -> True
        _ -> False)
      BS.writeFile result original
  entered <- newEmptyMVar
  release <- newEmptyMVar
  reader <- async (withArtifactDownload store proof handle (\_ _ -> putMVar entered () >> takeMVar release))
  takeMVar entered
  overlapping <- try @StoreFailure (withArtifactDownload store proof handle (\_ _ -> error "second response admitted"))
  check "single aggregate read loan spans response callback" (overlapping == Left StoreBusy)
  putMVar release ()
  wait reader

request :: CoordinationStore -> RunAssociation -> Text -> Text -> IO Commands.CommandRequest
request store association key name = do
  identity <- storeIdentity store
  revision <- runRead store $ do
    rows <- query "SELECT revision FROM runs WHERE id=?" [SQL.SQLText (associationRun association)]
    case rows of [[SQL.SQLText value]] -> pure value; _ -> refuseTransaction StoreIntegrity
  pure $ Commands.CommandRequest Command.Export "profile_1" "POST" ("/v1/runs/"<>associationRun association<>"/exports")
    (storeAuthorityEpoch identity<>"."<>key<>T.replicate 22 "a") "application/json" (Just ("\""<>revision<>"\"")) (Command.encoded (object ["name" .= name]))
submitNamed :: CoordinationStore -> CredentialProof -> RunAssociation -> Text -> IO Text
submitNamed store proof association name = do
  req <- request store association name (name<>".json")
  submission <- submitExport store proof association req >>= right
  pure ("export_"<>Command.receiptId (Commands.submissionReceipt submission))

authChecks :: CoordinationStore -> CredentialProof -> RunAssociation -> Text -> Text -> Text -> IO ()
authChecks store proof association source exported exportId = do
  mutate store $ execute "DELETE FROM credential_scopes WHERE scope='export'" []
  withArtifactDownload store proof exported (\_ _ -> check "observe alone may download published content" True)
  unauthorized <- request store association "unauthorized" "unauthorized.json" >>= submitExport store proof association
  check "publication needs export scope" (case unauthorized of Left Command.Forbidden -> True; _ -> False)
  reconciliation <- try @Command.CommandFailure (reconcileExport store proof exportId)
  check "reconciliation needs export scope" (reconciliation == Left Command.Forbidden)
  mutate store $ execute "DELETE FROM credential_scopes WHERE scope='observe'" []
  denied <- try @Command.CommandFailure (withArtifactDownload store proof source (\_ _ -> error "unauthorized response"))
  check "current observe scope checked before content" (denied == Left Command.Forbidden)
  mutate store $ forM_ ["observe","export"] $ \scope -> execute "INSERT INTO credential_scopes VALUES ('credential_1','profile_1',?)" [SQL.SQLText scope]
  mutate store $ execute "UPDATE credentials SET revoked=1" []
  revoked <- try @Command.CommandFailure (withArtifactDownload store proof source (\_ _ -> error "revoked response"))
  check "credential revoked before download call is refused" (revoked == Left Command.Unauthenticated)
  mutate store $ execute "UPDATE credentials SET revoked=0" []

runtimeRaces :: CoordinationStore -> RunAssociation -> ResultRef -> IO ()
runtimeRaces store association reference = withStoreFiles store $ \root ->
  bracket (openPrivateSubroot root ["runs"]) closePrivateRoot $ \runs -> do
    withPreparedResultExport runs (associationNative association) reference "runtime-race.json" $ \left ->
      withPreparedResultExport runs (associationNative association) reference "runtime-race.json" $ \rightExport -> do
        (a,b) <- concurrently (try @IOException (publishPreparedResultExport left)) (try @IOException (publishPreparedResultExport rightExport))
        check "shared publisher has exactly one complete exclusive winner" (length [() | Right () <- [a,b]] == 1)
        bytes <- readPublishedResultExport runs (preparedExportRootIdentity left) "runtime-race.json" (preparedExportBytes left) (preparedExportSha256 left) (String "flag")
        check "exclusive winner has intended byte count" (toInteger (BS.length bytes) == preparedExportBytes left)
        oversized <- try @IOException (readPublishedResultExport runs (preparedExportRootIdentity left) "runtime-race.json" (maxArtifactBytes+1) (preparedExportSha256 left) (String "flag"))
        check "export read rejects oversized bound before content" (case oversized of Left _ -> True; _ -> False)
    withPreparedResultExport runs (associationNative association) reference "replaced-root.json" $ \prepared -> do
      let exports=privateRootPath runs </> "exports"
      renameDirectory exports (exports<>".retained")
      createDirectory exports
      setFileMode exports 0o700
      refused <- try @IOException (publishPreparedResultExport prepared)
      check "prepared publication refuses substituted export root" (case refused of Left _ -> True; _ -> False)
      renameDirectory exports (exports<>".prepared-replacement")
      renameDirectory (exports<>".retained") exports

badRequests :: CoordinationStore -> CredentialProof -> RunAssociation -> IO ()
badRequests store proof association = do
  req <- request store association "bad-name" "unused"
  huge <- submitExport store proof association req {Commands.commandBody=BS.replicate 2097153 32}
  check "mutation byte cap applies before JSON decoding" (case huge of Left Command.SizeLimit -> True; _ -> False)
  forM_ [object ["name" .= ("../escape"::Text)],object ["name" .= ("ok"::Text),"path" .= ("/tmp/escape"::Text)],object ["name" .= T.replicate 129 "a"],object ["name" .= ("雪"::Text)]] $ \body -> do
    denied <- submitExport store proof association req {Commands.commandBody=Command.encoded body}
    check "frozen export mutation refuses paths, extra keys and out-of-bound names" (case denied of Left Command.InvalidRequest -> True; _ -> False)

exportSubstitution :: CoordinationStore -> CredentialProof -> Text -> FilePath -> IO ()
exportSubstitution store proof handle root = do
  let exports=root </> "runs/exports"
      leaf=exports </> "review-result.json"
  renameFile leaf (leaf<>".retained")
  createSymbolicLink (leaf<>".retained") leaf
  symlink <- try @Command.CommandFailure (withArtifactDownload store proof handle (\_ _ -> error "export symlink response"))
  check "export leaf symlink cannot produce content" (symlink == Left Command.ResourceUnavailable)
  removeFile leaf
  renameFile (leaf<>".retained") leaf
  renameDirectory exports (exports<>".retained")
  createDirectory exports
  setFileMode exports 0o700
  failed <- try @Command.CommandFailure (withArtifactDownload store proof handle (\_ _ -> error "substituted export response"))
  check "export root replacement cannot produce content" (failed == Left Command.ResourceUnavailable)
  renameDirectory exports (exports<>".replacement")
  renameDirectory (exports<>".retained") exports

rootSubstitution :: CoordinationStore -> CredentialProof -> RunAssociation -> Text -> FilePath -> IO ()
rootSubstitution store proof _ handle root = do
  let runs=root </> "runs"
  renameDirectory runs (runs<>".retained")
  createDirectory runs
  setFileMode runs 0o700
  failed <- try @Command.CommandFailure (withArtifactDownload store proof handle (\_ _ -> error "substituted state response"))
  check "state root replacement cannot produce content" (failed == Left Command.ResourceUnavailable)
  renameDirectory runs (runs<>".replacement")
  renameDirectory (runs<>".retained") runs
