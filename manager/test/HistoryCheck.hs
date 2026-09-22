{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
module Main (main) where

import Agentic.Manager.Artifacts (withArtifactDownload, withRunOutputs)
import Agentic.Manager.State (RunAssociation (..), ingestRuntimeEnvelope)
import qualified Agentic.Manager.Test.AcceptanceAudit as Audit
import Agentic.Manager.Authorization
import Agentic.Manager.Configuration
import Agentic.Manager.Drafts
import Agentic.Manager.History
import Agentic.Manager.Profile hiding (StaleRevision)
import Agentic.Manager.Protocol.Command
import Agentic.Manager.Protocol.Draft
import Agentic.Manager.Lineage
import Agentic.Manager.Schema
import Agentic.Manager.Store
import Agentic.Runtime
import Control.Exception (SomeException, bracket, try)
import Control.Monad (forM_, unless, void)
import Crypto.Hash (Digest, SHA256, hash)
import Data.Aeson (Value (..), object, (.=), toJSON, eitherDecodeStrict')
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import Data.ByteArray (convert)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import Data.Either (isLeft)
import Data.IORef
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Database.SQLite3 as SQL
import System.Directory (createDirectory, removeFile)
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format (formatTime, defaultTimeLocale)
import System.Environment (getArgs, getExecutablePath)
import System.FilePath ((</>))
import System.IO (hSetBuffering, stdout, BufferMode (LineBuffering))
import System.Posix.Files (setFileMode)
import System.Timeout (timeout)
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (withAsync,wait)
import Control.Concurrent.MVar (newEmptyMVar,putMVar,takeMVar,tryReadMVar)

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  args <- getArgs
  case args of
    ["runner",_,"frontend","--capabilities"] -> BS.putStr(encoded(frontendCapabilities(FrontendServer "fixture" "/fixture/runner" "0.1.0.0")))
    ["runner",reply,"list","--json","--descriptor-version","3"] -> BS.readFile reply >>= BS.putStr
    ["corrections",work,source] -> deadline (observationRace work source)
    ["--blocked-query","frontend","--capabilities"] -> putStrLn "query-ready" >> threadDelay maxBound
    [work,source] -> deadline $ do
      pureChecks
      (config,root,legacy,replies) <- fixture work source
      bracket (installConfiguration config >>= right) closeConfiguration $ \installed -> do
        (_,profiles) <- configurationSnapshot installed >>= right
        revision <- case profiles of [p] -> pure(publicRevision p); _ -> error "profile"
        catalogue <- probeConfiguredProfile installed "profile_1" revision >>= right
        blockedQueryDeadline (selectionContext(discoverySelection catalogue))
        let selection = discoverySelection catalogue
            descriptor = case discoveryEntries catalogue of [(_,value)] -> value; _ -> error "descriptor"
            invocation = selectionInvocation selection
        retained <- withCoordinationStore installed $ \store -> do
          seed store
          proof <- authenticateCredential store bearer >>= right
          missingBinding <- try @CommandFailure(history store proof [])
          check "missing local binding refuses complete history" (missingBinding == Left ResourceUnavailable)
          binding <- bindLegacyHistory store legacy "profile_1"
          values <- history store proof [binding]
          check "empty configured history is complete" (null values)
          forM_ [1,2,3] $ \version -> do
            let native = "native-"<>T.pack(show(version::Int)); parent = "run_"<>T.pack(show version)
            manifest <- writeParent root descriptor invocation native version
            withStoreFiles store $ \manager -> bracket (openPrivateSubroot manager ["runs"]) closePrivateRoot $ \runs -> mutate store $
              execute "INSERT INTO runs(id,revision,control_revision,profile_id,root_identity,native_run_id,supervision,result_state) VALUES (?,?,'control','profile_1',?,?,'observer','absent')"
                [txt parent,txt parent,txt(T.pack(privateRootIdentity runs)),txt native]
            forM_ [RestartParent,ResumeParent,ForkParent [DropAnswer (OccurrenceId 0),ReplaceAnswer (OccurrenceId 1) (Bool True)]] $ \operation -> do
              nonce <- key store (parent<>T.pack(show operation))
              current <- scalar store "SELECT revision FROM runs WHERE id=?" [txt parent]
              receipt <- createLineageDraft store proof parent nonce (Just(etag ("/v1/runs/"<>parent<>"/lineage-requests") "profile_1" current)) (encoded operation) >>= right
              request <- scalar store "SELECT request_id FROM commands WHERE id=?" [txt(receiptId receipt)]
              check "lineage gets distinct request identity" (request /= parent)
              (setup,_) <- assembleDraft store proof request >>= right
              check "lineage carries only parent, operation, typed edits and current invocation" (setup == DerivedSetup (root </> "runs") (frontendRunId manifest) (lineageOperation operation) (lineageEdits operation) PersonAnswerLocalControl (Just invocation))
              let manifestPath = root </> "runs/runs" </> T.unpack native </> "supervisor-manifest.json"
              BS.writeFile manifestPath (encodeFrontendManifest(manifest {frontendProgramHash=T.replicate 64 "b"}))
              changed <- assembleDraft store proof request
              check "immutable parent facts revalidated during assembly" (changed == Left StateConflict)
              BS.writeFile manifestPath (encodeFrontendManifest manifest)
              check "parent manifest remains byte-identical" =<< ((==encodeFrontendManifest manifest) <$> BS.readFile(root </> "runs/runs" </> T.unpack native </> "supervisor-manifest.json"))
              replay <- createLineageDraft store proof parent nonce (Just(etag ("/v1/runs/"<>parent<>"/lineage-requests") "profile_1" current)) (encoded operation) >>= right
              check "lineage replay does not create another request" (replay == receipt)
              bad <- changeDraftInput store proof request nonce Nothing "{\"operation\":\"remove\",\"name\":\"input\"}"
              check "lineage refuses input replacement" (isLeft bad)
              mutate store (execute "UPDATE runs SET supervision='cleanup-pending' WHERE id=?" [txt parent])
              blocked <- assembleDraft store proof request
              check "queued lineage rechecks parent quarantine" (blocked == Left OwnershipUnavailable)
              mutate store (execute "UPDATE runs SET supervision='observer' WHERE id=?" [txt parent])
            check "Emacs missing invocation refused only for v3" (isLeft(retainLineageInvocation manifest Nothing) == (version==3))
            check "v3 exact invocation mismatch refuses" (isLeft(retainLineageInvocation manifest (Just(invocation {frontendInvocationExecutable="/never-run"}))) == (version==3))
            withLineageRequests store proof parent (\children -> check "complete parent child-request links" (length children==3 && all ((==Just parent) . draftParent) children))
          now <- getCurrentTime
          let ownerPath = root </> "runs/runs/native-2/owner.json"
          BS.writeFile ownerPath (encoded(object ["version" .= (1::Int),"ownerId" .= ("foreign"::Text),"pid" .= (99999::Int),"heartbeat" .= formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" now]))
          nonce <- key store "foreign"
          current <- scalar store "SELECT revision FROM runs WHERE id='run_2'" []
          foreignRequest <- createLineageDraft store proof "run_2" nonce (Just(etag "" "" current)) (encoded RestartParent)
          check "foreign live owner cannot become a parent" (foreignRequest == Left OwnershipUnavailable)
          observedForeign <- history store proof [binding]
          check "foreign owner stays observer" (any (\v -> field "limitations" v == toJSON (["foreign-owner"]::[Text]) && field "supervision" v == String "observer") observedForeign)
          removeFile ownerPath
          void (writeLegacy legacy descriptor invocation)
          _ <- writeResult (root </> "runs") descriptor (RunId "native-3")
          rootIdentity <- scalar store "SELECT root_identity FROM runs WHERE id='run_3'" []
          let association = RunAssociation "run_3" "profile_1" rootIdentity (RunId "native-3")
          (_,envelopes) <- withPrivateRoot "managed result" (root </> "runs") $ \runs -> withPrivateDirectoryAt runs ["runs","native-3"] $ \fd -> readRunRecordWithEnvelopesAt (root </> "runs/runs/native-3") fd Nothing now
          forM_ envelopes (void . ingestRuntimeEnvelope store association . encodeEnvelope)
          removeFile (root </> "runs/runs/native-3/runtime/result.json")
          withRunOutputs store proof association (\_ _ -> pure ())
          resultViews <- history store proof [binding]
          check "history preserves shared missing-result reason" (any (\v -> field "id" v==String "run_3" && field "reason" (field "verification" v)==String "missing") resultViews)
          views <- history store proof [binding]
          check "managed and read-only legacy entries complete" (length views == 5)
          check "corrupt legacy entry remains visible" (length(filter ((==String "unreadable-manifest") . field "kind") views)==1)
          let legacyView = case [v | v <- views,field "requestId" v == Null, field "id" v /= String "run_1",field "id" v /= String "run_2",field "id" v /= String "run_3",field "kind" v == Null] of
                [value] -> value
                _ -> error "legacy view"
              ident = string(field "id" legacyView)
          check "historical workflow uses existing profile identity" (field "workflowId" legacyView == String(workflowIdentity "profile_1" (workflowName descriptor)))
          refused <- createHistoryLineage store proof ident "unused" Nothing "{\"operation\":\"restart\"}"
          check "legacy ROOT refuses before mutation" (refused == Left OwnershipUnavailable)
          expected <- BS.readFile(legacy </> "runs/old/runtime/result.json")
          withHistoryResult store proof [binding] ident (\view bytes -> do
            revalidateAuthorizedView view >>= check "legacy response view revalidates under retained scopes" . (==Right ())
            check "legacy result uses verified original bytes" (bytes==expected))
          withArtifactDownload store proof (string(field "artifactId" (field "verification" legacyView))) $ \_ metadata bytes -> do
            check "advertised legacy artifact resolves through existing owner" (bytes==expected && field "runId" metadata==String ident)
            BS.writeFile(work </> "history-artifact.json") (encoded metadata)
          BS.writeFile(legacy </> "runs/old/runtime/journal.ndjson") "corrupt\n"
          withHistoryResult store proof [binding] ident (\_ bytes -> check "retained reference survives corrupt journal" (bytes==expected))
          BS.writeFile(legacy </> "runs/old/runtime/result.json") "tampered"
          badResult <- try @SomeException(withHistoryResult store proof [binding] ident (\_ _ -> error "unverified response"))
          check "tampered legacy result never responds" (isLeft badResult)
          BS.writeFile(legacy </> "runs/old/runtime/result.json") expected
          BS.writeFile(work </> "history.json") (encoded views)
          stable <- history store proof [binding]
          check "opaque handle stable across corruption" (any ((==String ident) . field "id") stable)
          mutate store (execute "DELETE FROM credential_scopes WHERE profile_id='profile_1' AND scope='observe'" [])
          hidden <- history store proof [binding]
          check "out-of-scope profiles disclose no history" (null hidden)
          mutate store (execute "INSERT INTO credential_scopes VALUES ('credential_1','profile_1','observe')" [])
          staleViews <- history store proof [binding]
          let sampled = case [v | v<-staleViews,field "id" v==String "run_1"] of [v]->v;_->error "sampled parent"
          mutate store $ execute "UPDATE runs SET revision='concurrent-transition',supervision='lost' WHERE id='run_1'" []
          stalePublication <- try @StoreFailure(retainView store sampled)
          check "changed run refuses stale history publication" (stalePublication==Left StoreBusy)
          scalar store "SELECT revision FROM runs WHERE id='run_1'" [] >>= check "history preserves concurrent revision" . (=="concurrent-transition")
          let mismatchPath = root </> "runs/runs/native-3/supervisor-manifest.json"
          originalManifest <- BS.readFile mismatchPath >>= right . decodeFrontendManifest
          BS.writeFile mismatchPath (encodeFrontendManifest(originalManifest {frontendInvocation=Just(invocation {frontendInvocationExecutable="/historical/other"})}))
          BS.writeFile replies "[]"
          _ <- probeConfiguredProfile installed "profile_1" revision >>= right
          withoutCatalogue <- history store proof [binding]
          check "history identity survives current descriptor removal" (any (\v -> field "id" v == String ident && field "workflowId" v == field "workflowId" legacyView) withoutCatalogue)
          check "missing descriptor does not erase invocation mismatch" (any (\v -> field "id" v==String "run_3" && (case field "limitations" v of Array xs -> String "incompatible-invocation" `elem` xs; _ -> False)) withoutCatalogue)
          BS.writeFile mismatchPath (encodeFrontendManifest originalManifest)
          staleKey <- key store "stale-catalogue"
          currentParent <- scalar store "SELECT revision FROM runs WHERE id='run_1'" []
          stale <- createLineageDraft store proof "run_1" staleKey (Just(etag "" "" currentParent)) (encoded RestartParent)
          check "removed workflow never becomes execution authority" (stale == Left StaleRevision)
          withStoreFiles store $ \manager -> ensurePrivateDirectoryAt manager ["runs","runs","unassociated"]
          unbound <- try @SomeException(history store proof [binding])
          check "unassociated manager entry refuses whole materialization" (isLeft unbound)
          bracket (openPrivateRoot "bounded catalogue" legacy) closePrivateRoot $ \legacyRoot -> do
            forM_ [1..257::Int] $ \n -> ensurePrivateDirectoryAt legacyRoot ["runs","overflow-"<>show n]
            stamp <- getCurrentTime
            overflow <- try @SomeException(withPrivateDirectoryAt legacyRoot [] (\fd -> listRunCatalogueBoundedAt 256 legacy fd Nothing stamp))
            check "catalogue cap refuses instead of returning prefix" (isLeft overflow)
          -- Remains present deliberately. Reopen tests query only retained legacy content.
          pure (binding,ident,expected)
        let (binding,ident,expected)=retained
        -- Reload discards current discovery, but historical identity must remain readable.
        _ <- reloadConfiguration installed config >>= right
        withCoordinationStore installed $ \store -> do
          proof <- authenticateCredential store bearer >>= right
          withHistoryResult store proof [binding] ident (\_ bytes -> check "retained result survives Store reopen without authority adoption" (bytes==expected))
          nonce <- key store "absent"
          absent <- createLineageDraft store proof "run_1" nonce Nothing "{\"operation\":\"restart\"}"
          check "missing precondition refuses without worker" (isLeft absent)
        BS.writeFile replies "[]"
      migrationChecks work
      putStrLn "PASS WM018 deterministic history and lineage contracts. No native workflow execution."
    _ -> error "usage: manager-history-check PRIVATE_DIRECTORY PACKAGE_DIRECTORY"

observationRace :: FilePath -> FilePath -> IO ()
observationRace work source = do
  (configuration,_,legacy,_) <- fixture work source
  bracket (installConfiguration configuration >>= right) closeConfiguration $ \installed -> do
    (_,profiles) <- configurationSnapshot installed >>= right
    revision <- case profiles of [p]->pure(publicRevision p);_->error "profile"
    discovery <- probeConfiguredProfile installed "profile_1" revision >>= right
    descriptor <- case discoveryEntries discovery of [(_,d)]->pure d;_->error "descriptor"
    withCoordinationStore installed $ \store -> do
      seed store
      proof <- authenticateCredential store bearer >>= right
      binding <- bindLegacyHistory store legacy "profile_1"
      writeLegacy legacy descriptor (selectionInvocation(discoverySelection discovery))
      items <- history store proof [binding]
      ident <- case [string(field "id" value) | value<-items,field "kind" value==Null] of [i]->pure i;_->error "legacy run"
      entered <- newIORef False
      Audit.withReviewAudit "history-artifact-captured" $ \barrier ->
        withAsync (try @CommandFailure(withHistoryResult store proof [binding] ident (\_ _ -> writeIORef entered True))) $ \download -> do
          _ <- Audit.waitReviewed barrier
          original <- BS.readFile(work </> "configuration.json") >>= right . (eitherDecodeStrict' :: BS.ByteString -> Either String Value)
          let removed = case original of Object fields->Object(KM.insert "localRetentionRoots" (toJSON([]::[Text])) fields);_->error "configuration"
          BS.writeFile(work </> "removed.json") (encoded removed)
          setFileMode(work </> "removed.json") 0o600
          replacement <- loadConfiguration (const(Right())) exactPreparedTarget (const False) (work </> "removed.json") >>= right
          _ <- reloadConfiguration installed replacement >>= right
          Audit.releaseReviewed barrier
          result <- wait download
          called <- readIORef entered
          check "removed retention root cannot enter artifact response" (result==Left ResourceUnavailable && not called)

blockedQueryDeadline :: OperatorProfile -> IO ()
blockedQueryDeadline policy = do
  registry <- newRegistry (QueryLimits 1048576 10000000) >>= right
  profiles <- reloadProfiles registry [policy {operatorPrefix=["--blocked-query"]}] >>= right
  revision <- case profiles of [p]->pure(publicRevision p);_->error "blocked profile"
  original <- newIORef Nothing
  ready <- newEmptyMVar
  let create command = do
        group <- createProcessGroup command
        writeIORef original (Just group)
        output <- maybe (error "query stdout") pure (groupOutput group)
        marker <- BSC.hGetLine output
        check "blocked query reached actual original child" (marker=="query-ready")
        putMVar ready ()
        pure group
  expired <- withAsync (probeProfileCapabilitiesWith create registry (operatorId policy) revision) $ \child -> do
    takeMVar ready
    timeout 100000 (wait child)
  check "checker deadline remains a timeout" (case expired of Nothing->True;_->False)
  group <- readIORef original >>= maybe (error "original query handle missing") pure
  outcome <- tryReadMVar (groupOutcome group)
  check "deadline cancellation joins original query owner" (case outcome of Just(Right _)->True;_->False)

deadline :: IO a -> IO a
deadline action = timeout 120000000 action >>= maybe (error "history deadline expired; original cleanup outcome not certified") pure

pureChecks :: IO ()
pureChecks = do
  forM_ ["{\"operation\":\"restart\",\"workflow\":\"x\"}","{\"operation\":\"resume\",\"inputs\":[]}","{\"operation\":\"fork\",\"edits\":[],\"target\":[]}","{\"operation\":\"fork\",\"edits\":[{\"operation\":\"drop\",\"occurrenceId\":\"0\"},{\"operation\":\"drop\",\"occurrenceId\":\"0\"}]}"] $ \bytes ->
    check "closed lineage mutation and unique typed edits" (isLeft(decodeDraftBody bytes::Either CommandFailure LineageMutation))
  check "workflow identity is profile-scoped" (workflowIdentity "p" "w" /= workflowIdentity "q" "w")

writeParent :: FilePath -> WorkflowDescriptor -> FrontendInvocation -> Text -> Int -> IO FrontendManifest
writeParent root descriptor invocation native version = withPrivateRoot "fixture" root $ \manager -> do
  ensurePrivateDirectoryAt manager ["runs","runs",T.unpack native,"inputs"]
  let manifest = parentManifest descriptor invocation native version
  check "actual legacy/v2/v3 manifest decoder branch" (decodeFrontendManifest(encodeFrontendManifest manifest) == Right manifest)
  writePrivateExclusiveAt manager ["runs","runs",T.unpack native,"supervisor-manifest.json"] (encodeFrontendManifest manifest)
  pure manifest

parentManifest :: WorkflowDescriptor -> FrontendInvocation -> Text -> Int -> FrontendManifest
parentManifest descriptor invocation native version = FrontendManifest version (RunId native) "fixture" (if version==1 then Nothing else Just "/never-execute-this")
  (if version==1 then Nothing else Just "0.1.0.0") (if version==3 then Just invocation else Nothing)
  (workflowName descriptor) "/private/historical/workspace" "scripted" [] Map.empty (T.replicate 64 "a") "2026-09-19T00:00:00Z" Nothing Nothing [] Nothing Nothing (if version==1 then Nothing else Just PersonAnswerLocalControl) (if version==1 then Nothing else Just "fixture-owner") "runtime"

writeLegacy :: FilePath -> WorkflowDescriptor -> FrontendInvocation -> IO ()
writeLegacy path descriptor invocation = withPrivateRoot "legacy fixture" path $ \root -> do
  ensurePrivateDirectoryAt root ["runs","old","inputs"]
  ensurePrivateDirectoryAt root ["runs","broken"]
  writePrivateExclusiveAt root ["runs","broken","supervisor-manifest.json"] "broken"
  writePrivateExclusiveAt root ["runs","old","supervisor-manifest.json"] (encodeFrontendManifest(parentManifest descriptor invocation "old" 2))
  void (writeResult path descriptor (RunId "old"))

writeResult :: FilePath -> WorkflowDescriptor -> RunId -> IO ResultRef
writeResult path descriptor native = do
  let manifest = RunManifest native (workflowName descriptor) "0.1.0.0" Null "scripted" Null Nothing RootRun Nothing (Just PersonAnswerLocalControl)
      directory = path </> "runs" </> T.unpack(runIdText native) </> "runtime"
  bracket (createRunStoreVersioned 2 2 directory manifest) closeRunStore $ \runtime -> do
    reference <- writeResultArtifact runtime native (String "flag") (Bool False) "false"
    let events = [RunStartedV2 (workflowName descriptor) "scripted" PersonAnswerLocalControl,TraceOrdered [],RunCompletedV2 0 0 reference]
    forM_ (zip [0..] events) $ \(number,event) -> void (appendStoredEvent runtime (Envelope 2 native (SeqNo number) "2026-09-19T00:00:00Z" event))
    pure reference

fixture :: FilePath -> FilePath -> IO (Configuration,FilePath,FilePath,FilePath)
fixture work source = do
  executable <- getExecutablePath
  let root=work </> "manager"; legacy=work </> "legacy"; path=work </> "configuration.json"; replies=work </> "descriptors.json"
  forM_ [root,legacy] $ \directory -> createDirectory directory >> setFileMode directory 0o700
  descriptor <- BS.readFile(source </> "test/fixtures/runtime/descriptor-v3/valid.json") >>= right . decodeWorkflowDescriptor
  BS.writeFile replies (encoded [descriptor {workflowInputs=[]}])
  BS.writeFile path (encoded(object ["version" .= (1::Int),"managerRoot" .= root,"localRetentionRoots" .= [legacy],
    "runners" .= [object ["alias" .= ("runner"::Text),"executable" .= executable,"prefix" .= ["runner",replies]]],
    "profiles" .= [object ["id" .= ("profile_1"::Text),"runner" .= ("runner"::Text),"workspace" .= work,"workspaceLabel" .= ("fixture"::Text),"targetLabel" .= ("no engine"::Text),"targetArguments" .= ([]::[Text]),"environment" .= ([]::[Text]),"ownership" .= ("service-owned"::Text),"quarantined" .= False,"personAnswering" .= ("local-control"::Text),"resourceKeys" .= ([]::[Text])]],
    "limits" .= object ["drafts" .= (16::Int),"globalDrafts" .= (16::Int),"globalCaptureBytes" .= (67108864::Int),"globalPageSets" .= (2::Int),"globalConnections" .= (8::Int),"globalDatabaseReaders" .= (2::Int),"globalMutationLedgerBytes" .= (134217728::Int),"safetyControlsPerMinute" .= (20::Int),"executionReservations" .= (1::Int)]]))
  setFileMode path 0o600
  config <- loadConfiguration (const(Right())) exactPreparedTarget (const False) path >>= right
  pure(config,root,legacy,replies)

migrationChecks :: FilePath -> IO ()
migrationChecks work = bracket (SQL.open(T.pack(work </> "schema8.sqlite3"))) SQL.close $ \db -> do
  SQL.exec db "PRAGMA foreign_keys=ON"
  mapM_ (SQL.exec db) (schemaStatements<>commandMigration<>draftMigration<>admissionMigration<>approvalMigration<>ingestionMigration<>controlMigration<>artifactMigration)
  SQL.exec db "INSERT INTO clients VALUES ('retained','r','a',0)"
  SQL.exec db "PRAGMA user_version=8"
  SQL.exec db "BEGIN IMMEDIATE"
  mapM_ (SQL.exec db) historyMigration
  SQL.exec db "ROLLBACK"
  check "schema9 rollback preserves populated schema8" =<< ((==[[SQL.SQLText "retained"]]) <$> rawRows db "SELECT id FROM clients")
  mapM_ (SQL.exec db) historyMigration
  check "schema9 upgrade preserves populated schema8" =<< ((==[[SQL.SQLText "retained"]]) <$> rawRows db "SELECT id FROM clients")
  check "schema9 foreign keys intact" =<< (null <$> rawRows db "PRAGMA foreign_key_check")

rawRows :: SQL.Database -> Text -> IO [[SQL.SQLData]]
rawRows db sql = bracket (SQL.prepare db sql) SQL.finalize $ \statement -> let loop = SQL.step statement >>= \result -> case result of SQL.Done -> pure []; SQL.Row -> (:) <$> SQL.columns statement <*> loop in loop
seed :: CoordinationStore -> IO ()
seed store = mutate store $ do
  execute "INSERT INTO clients VALUES ('client_1','r','a',0)" []
  execute "INSERT INTO credentials VALUES ('credential_1','client_1',?,'2999-01-01T00:00:00Z',0)" [SQL.SQLBlob(convert(hash bearer::Digest SHA256))]
  forM_ ["observe","submit","control"] $ \scope -> execute "INSERT INTO credential_scopes VALUES ('credential_1','profile_1',?)" [txt scope]
bearer :: BS.ByteString
bearer = BS.replicate 32 97
mutate :: CoordinationStore -> Transaction () -> IO ()
mutate store action = runTransaction store (action >> pure((),[Invalidation "service.changed" "/v1/capabilities" "fixture"]))
scalar :: CoordinationStore -> Text -> [SQL.SQLData] -> IO Text
scalar store sql params = runRead store $ do rows <- query sql params; case rows of [[SQL.SQLText value]] -> pure value; _ -> error "scalar"
key :: CoordinationStore -> Text -> IO Text
key store label = do epoch <- storeAuthorityEpoch <$> storeIdentity store; pure(epoch<>"."<>T.take 40 (T.pack(show(hash(encoded label)::Digest SHA256))))
history :: CoordinationStore -> CredentialProof -> [LegacyHistory] -> IO [Value]
history store proof bindings = do ref <- newIORef []; withHistory store proof bindings Nothing (writeIORef ref); readIORef ref
field :: Key.Key -> Value -> Value
field name (Object fields) = KM.lookup name fields `orNull` Null where orNull (Just value) _ = value; orNull Nothing other = other
field _ _ = Null
string :: Value -> Text
string (String value) = value
string _ = error "string"
right :: Show e => Either e a -> IO a
right = either (error.show) pure
check :: String -> Bool -> IO ()
check label ok = unless ok (error("FAIL "<>label)) >> putStrLn("PASS "<>label)
etag :: Text -> Text -> Text -> Text
etag _ _ revision = "\""<>revision<>"\""
txt :: Text -> SQL.SQLData
txt = SQL.SQLText
