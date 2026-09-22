{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
module Main (main) where

import qualified Agentic.Cli as Cli
import Agentic.Manager.Admission
import qualified Agentic.Manager.Artifacts as Artifacts
import VerticalCheck (EventOrder (..), compareNativeRuns)
import Agentic.Manager.Approval
import Agentic.Manager.Authorization
import Agentic.Manager.Commands
import Agentic.Manager.Configuration
import Agentic.Manager.Drafts
import Agentic.Manager.History
import Agentic.Manager.Lineage
import qualified Agentic.Manager.Worker as Worker
import Agentic.Manager.Profile hiding (StaleRevision)
import Agentic.Manager.Protocol.Command
import Agentic.Manager.Protocol.Draft
import qualified Agentic.Manager.Protocol.Preparation as P
import Agentic.Manager.Store
import Agentic.Manager.State
import IngestionCheck (ingestionChecks, concurrentIngestionChecks)
import qualified Agentic.Manager.Test.AcceptanceAudit as Audit
import Agentic.Manager.Worker (WorkerObservation (..),WorkerPhase (..), WorkerFailure (..), workerEventBytes, workerEventEnvelope)
import qualified Agentic.Runtime as Runtime
import Agentic.Runtime (workflowName, FrontendPrepared (..), RunId (..), FrontendPreparedInput (..))
import Control.Concurrent (threadDelay,throwTo,getNumCapabilities)
import Control.Concurrent.Async (asyncThreadId,async,wait,waitCatch,cancel,poll)
import Control.Concurrent.MVar (newEmptyMVar,putMVar,takeMVar,readMVar,tryPutMVar)
import Control.Concurrent.STM hiding (check)
import qualified Control.Concurrent.STM as STM
import Control.DeepSeq (NFData)
import Control.Exception (IOException,mask_,bracket,try,fromException,throwIO,finally,AsyncException (UserInterrupt))
import Control.Monad (unless,forM_,forM,void,when,foldM)
import Crypto.Hash (Digest,SHA256,hash)
import Data.Aeson (Value (..),toJSON,object,(.=),eitherDecodeStrict')
import qualified Data.Aeson.KeyMap as KM
import Data.ByteArray (convert)
import qualified Data.ByteString as BS
import Data.Int (Int64)
import Data.IORef (newIORef, readIORef, modifyIORef', writeIORef)
import Data.Time.Clock (getCurrentTime)
import Data.List (sortOn)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Database.SQLite3 as SQL
import System.Directory (createDirectory,createDirectoryIfMissing,doesFileExist,listDirectory)
import System.Process (readProcessWithExitCode)
import System.Exit (ExitCode (..))
import System.Info (os)
import System.Environment (getArgs)
import System.FilePath ((</>),takeExtension,dropExtension)
import System.IO (BufferMode (LineBuffering),hSetBuffering,stdout,hPutStrLn,stderr)
import System.Posix.Files (setFileMode)
import System.Timeout (timeout)
import GHC.Conc (threadStatus, ThreadStatus (ThreadBlocked), BlockReason (BlockedOnException, BlockedOnMVar))
import GHC.Clock (getMonotonicTimeNSec)

main :: IO ()
main=do
  hSetBuffering stdout LineBuffering
  args<-getArgs
  case args of
    ["vertical",work,native,source,python]->verticalChecks work native source python
    ["shutdown-drain",work,native]->shutdownDrainChecks work native >> shutdownRunningChecks work native
    ["shutdown-races",work,native]->shutdownReuseRaceChecks work native >> shutdownRaceChecks work native
    ["history-lineage",work,native]->awaitHistory(nativeLineageChecks False work native)
    ["history-corrections",work,native]->awaitHistory(nativeLineageChecks True work native)
    ["history-policy",work,native,source,python]->awaitHistory(nativeRoutedLineageChecks work native source python)
    ["controls",work,native]->nativeControlChecks work native
    ["controls-receipt-observation",work,native]->receiptObservationChecks work native
    ["controls-live",work,native,source,python]->nativeMixedControlChecks work native source python
    ["controls-steering",work,native,source,python]->nativeSteeringChecks False 1 work native source python
    ["controls-stale-steer",work,native,source,python]->nativeSteeringChecks True 1 work native source python
    ["controls-saturation",work,native,source,python]->nativeSteeringChecks False 256 work native source python
    ["controls-write",work,native]->nativeControlWriteChecks work native
    ["controls-interruption",work,native]->nativeControlInterruptionChecks work native
    ["controls-reload",work,native]->nativeControlReloadChecks False work native
    ["controls-reload-race",work,native]->nativeControlReloadChecks True work native
    ["controls-preparation",work,native,source,python]->nativeConcurrentChecks True work native source python
    ["store-cancel-gap",work,native]->storeCancellationChecks work native
    ["ingestion-framing",work,native,source,python]->framedIngestionChecks work native source python
    ["ingestion-association",work,native]->nativeIngestionChecks work native
    ["ingestion-observer",native]->observerChecks native
    ["ingestion-observer",_,native]->observerChecks native
    ["ingestion-race",work,native,source,_]->withReady work native "ingestion-race" ["--scripted"] [] $ \(Fixture _ _ store _ _ _)->concurrentIngestionChecks source store
    ["ingestion-cleanup",work,native]->associationCleanupChecks work native
    ["ingestion",work,native,source,python]->do
      observerChecks native
      framedIngestionChecks work native source python
      nativeIngestionChecks work native
      associationCleanupChecks work native
      nativeDecisionIngestionChecks work native
      nativeConcurrentIngestionChecks work native source python
      failedNativeIngestionChecks work native source python
      withReady work native "ingestion-fixtures" ["--scripted"] [] $ \(Fixture _ _ store _ _ _)->ingestionChecks source store
    ["retention-native",work,native]->nativeIngestionChecks work native >> cancellationRetentionChecks work native
    ["ingestion-native",work,native]->nativeIngestionChecks work native
    ["ingestion-concurrent",work,native,source,python]->nativeConcurrentIngestionChecks work native source python
    ["targets-live",work,native,source,python]->targetChecks work native source python
    ["corrections",work,native,source,python]->do
      nativePrivacyChecks work native
      supervisionChecks work native
      supervisionFaultChecks work native source python
      captureApprovalChecks work native
      targetChecks work native source python
    ["privacy-native",work,native]->nativePrivacyChecks work native
    ["privacy-header",work,native]->nativeHeaderChecks work native
    ["supervision",work,native]->supervisionChecks work native
    ["reservation-integrity",work,native]->reservationChecks work native
    ["review-gap",work,native]->reviewGapChecks work native
    ["interrupted-approval",work,native]->interruptionChecks work native
    ["worker-loss",work,native,source,python]->workerLossChecks work native source python
    [work,native]->positive work native
    [work,native,source,python]->do
      nativePrivacyChecks work native
      supervisionChecks work native
      supervisionFaultChecks work native source python
      captureApprovalChecks work native
      positive work native
      selectorChecks work native
      privacyChecks work native
      lifecycleChecks work native
      deadlineChecks work native
      reservationChecks work native
      profileChecks work native
      reopenChecks work native
      workerLossChecks work native source python
      postStartLossChecks work native source python
      backpressureChecks work native source python
      targetChecks work native source python
    _->error "usage: manager-approval-check PRIVATE_DIRECTORY NATIVE"

verticalChecks :: FilePath -> FilePath -> FilePath -> FilePath -> IO ()
verticalChecks work native source python = do
  identities <- newIORef []
  let compareRuns order fixture@(Fixture root _ _ _ _ _) run context directRoot direct = do
        compareNativeRuns order identities (root </> "runs") (preparedRunId (reviewNative context)) (directRoot </> "runs") direct
        verticalOutputs fixture run context
      section name action = do
        let directory = work </> name
        createDirectory directory
        putStrLn ("SECTION " <> name)
        action directory
  section "captures" $ \directory -> do
    forM_ [("unicode",TE.encodeUtf8 "Captured café λ.\r\nSecond line.\n",False),
           ("expanded",BS.replicate 1100000 10,True),("large",BS.replicate 2100000 120,True)] $ \(name,bytes,file) ->
      verticalCaptureCheck (compareRuns SerialEvents) directory native name ["--scripted"] [] bytes file
  section "lineage" $ \directory -> nativeLineageChecksCompared (compareRuns IndependentModelPerson) False False [1,2,3] directory native ["--scripted"] []
  section "routed" $ \directory -> nativeRoutedLineageChecksWith (compareRuns SerialEvents) directory native source python
  section "deck" $ \directory -> verticalCaptureCheck (compareRuns SerialEvents) directory native "deck"
    ["--session","stub","--binary",T.pack(source </> "engine/agent-deck/test/stub-deck.sh"),"--poll","20","--timeout","30000"]
    [("DECK_STUB_STATE",T.pack(directory </> "transport")),("DECK_STUB_MODE","happy")]
    (TE.encodeUtf8 "Deck capture café.\r\nExact input.\n") False
  section "approval" $ \directory -> do
    selectorChecks directory native
    lifecycleChecks directory native
    deadlineChecks directory native
    captureApprovalChecks directory native
    workerLossChecks directory native source python
    postStartLossChecks directory native source python
    reopenChecks directory native
  section "ingestion" $ \directory -> do
    withReady directory native "refusals" ["--scripted"] [] $ \(Fixture _ _ store _ _ _) -> ingestionChecks source store
    nativeIngestionChecks directory native
    nativeConcurrentIngestionChecks directory native source python
  section "controls" $ \directory -> do
    nativeControlChecks directory native
    nativeMixedControlChecks directory native source python
    nativeSteeringChecks False 1 directory native source python
  section "shutdown" $ \directory -> shutdownDrainChecks directory native >> shutdownRunningChecks directory native
  putStrLn "PASS WM022 non-network vertical lifecycle"

verticalCaptureCheck :: NativeComparison -> FilePath -> FilePath -> String -> [Text] -> [(Text,Text)] -> BS.ByteString -> Bool -> IO ()
verticalCaptureCheck compareRuns work native name arguments environment bytes file =
  withReadyRunner work native [] "captured-input" (name<>"-managed") arguments environment $ \(Fixture root installed store proof key ready) ->
    withReadyRunner work native [] "captured-input" (name<>"-direct") arguments environment $ \(Fixture directRoot _ directStore directProof directKey directReady) -> do
      let bindInput current auth makeKey draft = do
            _ <- changeDraftInput current auth (draftId draft) (makeKey "remove") (Just("\""<>draftRevision draft<>"\""))
              (encoded(object["operation" .= ("remove-input"::Text),"name" .= ("input"::Text)])) >>= right
            missing <- readDraft current auth (draftId draft) >>= right
            check "selection reports exact missing input without engine work" (case draftReadiness missing of Readiness _ [] ["input"] [] -> True; _ -> False)
            denied <- assembleDraftSnapshot current auth (draftId missing)
            check "missing input cannot prepare a worker" (case denied of Left InvalidInput -> True; _ -> False)
            let original=work </> (name<>"-"<>T.unpack(draftId draft)<>".input")
            BS.writeFile original bytes
            capturedBytes <- BS.readFile original
            chunks <- newIORef (splitChunks capturedBytes)
            let readChunk = do
                  remaining <- readIORef chunks
                  case remaining of [] -> pure BS.empty; x:xs -> writeIORef chunks xs >> pure x
            captured <- uploadCapture current auth (draftId missing) (makeKey "capture") (fromIntegral(BS.length capturedBytes)) readChunk >>= right
            BS.writeFile original "mutated after capture"
            check "capture digest and byte count survive original mutation"
              (captureBytes captured==fromIntegral(BS.length bytes) && captureDigest captured==T.pack(show(hash bytes::Digest SHA256)))
            _ <- changeDraftInput current auth (draftId missing) (makeKey "bind") (Just("\""<>draftRevision missing<>"\""))
              (encoded(object["operation" .= ("set-input"::Text),"input" .= CapturedValue "input" (captureId captured)])) >>= right
            linked <- readDraft current auth (draftId missing) >>= right
            assembly <- assembleDraftSnapshot current auth (draftId linked) >>= right
            check "capture uses expected inline or server-owned file transport" (case assemblySetup assembly of
              Runtime.RootSetup setup -> case Runtime.setupInputs setup of
                [("input",Runtime.File _)] -> file
                [("input",Runtime.Transport value)] -> not file && value==TE.decodeUtf8 bytes
                _ -> False
              _ -> False)
            pure (linked,assembly)
      (linked,_) <- bindInput store proof key ready
      (directLinked,directAssembly) <- bindInput directStore directProof directKey directReady
      direct <- directLineageRun directStore directLinked (assemblySetup directAssembly)
      withAdmissionClock fixedClock store $ \controller -> do
        (run,context) <- managedLineageRun store proof (shortLineageKey key) controller linked Nothing True
        check "real worker preserves captured digest and exact semantic input"
          (preparedInputs(reviewNative context)==[FrontendPreparedInput "input" (fromIntegral(BS.length bytes)) (T.pack(show(hash bytes::Digest SHA256)))])
        let nativeDirectory=root </> "runs/runs" </> T.unpack(runIdText(preparedRunId(reviewNative context)))
        answers <- Runtime.readAnswerRecords (nativeDirectory </> "runtime")
        check "actual native program consumes complete unmodified semantic input"
          (case answers of
            [answer] -> case Runtime.answerQuestion answer of
              Object fields -> KM.lookup "prompt" fields==Just(String("fixed-point source: "<>T.pack(show(hash bytes::Digest SHA256))))
              _ -> False
            _ -> False)
        compareRuns (Fixture root installed store proof key linked) run context directRoot direct
  where
    splitChunks content | BS.null content = [BS.empty]
                        | otherwise = let (chunk,rest)=BS.splitAt 65536 content in chunk:splitChunks rest

verticalOutputs :: Fixture -> Text -> ReviewContext -> IO ()
verticalOutputs (Fixture root _ store proof originalKey _) run context = do
  let key=shortLineageKey originalKey
      association=RunAssociation run "profile" (preparedRootIdentity(reviewNative context)) (preparedRunId(reviewNative context))
      scalar sql=runRead store $ do
        rows<-query sql [SQL.SQLText run]
        case rows of [[SQL.SQLText value]]->pure value;_->refuseTransaction StoreIntegrity
  withHistory store proof [] Nothing $ \rows -> check "completed actual run remains in history"
    (any (\value -> case value of Object fields -> KM.lookup "id" fields==Just(String run); _ -> False) rows)
  Artifacts.withRunOutputs store proof association $ \_ rows -> check "actual authored result is verified"
    (any (\value -> case value of
      Object fields -> case KM.lookup "verification" fields of
        Just(Object verification)->KM.lookup "state" verification==Just(String "verified")
        _ -> False
      _ -> False) rows)
  artifact <- scalar "SELECT result_artifact_id FROM runs WHERE id=?"
  let nativeFile=root </> "runs/runs" </> T.unpack(runIdText(preparedRunId(reviewNative context))) </> "runtime/result.json"
  sourceBytes <- BS.readFile nativeFile
  Artifacts.withArtifactDownload store proof artifact $ \_ _ bytes -> check "verified manager download is exact native result envelope" (bytes==sourceBytes)
  mutate store (execute "INSERT OR IGNORE INTO credential_scopes VALUES ('credential','profile','export')" [])
  revision <- scalar "SELECT revision FROM runs WHERE id=?"
  let name="vertical-"<>run<>".json"
      request=CommandRequest Export "profile" "POST" ("/v1/runs/"<>run<>"/exports") (key("export-"<>run)) "application/json" (Just("\""<>revision<>"\"")) (encoded(object["name" .= name]))
  first <- Artifacts.submitExport store proof association request >>= right
  let receipt=submissionReceipt first
      path=root </> "runs/exports" </> T.unpack name
  completed <- readCommand store proof (receiptId receipt) >>= right
  check "real result export completes under original publication owner" (receiptState completed==EffectObserved)
  published <- BS.readFile path
  replay <- Artifacts.submitExport store proof association request >>= right
  check "lost export reply returns original receipt without publication replay" (submissionReceipt replay==receipt && submissionReplayed replay)
  currentRevision <- scalar "SELECT revision FROM runs WHERE id=?"
  conflict <- Artifacts.submitExport store proof association request{commandKey=key("collision-"<>run),commandPrecondition=Just("\""<>currentRevision<>"\"")}
  check "exclusive export refuses distinct command for existing name" (case conflict of Left StateConflict -> True; _ -> False)
  BS.readFile path >>= check "exclusive refusal leaves published bytes unchanged" . (==published)

right :: Show e => Either e a -> IO a
right=either(error.show)pure
check :: String -> Bool -> IO ()
check name valid=unless valid(error("FAIL "<>name))>>putStrLn("PASS "<>name)
await :: IO a -> IO a
await action=timeout 15000000 action >>=maybe(error "approval rendezvous timeout")pure
mutate :: NFData a => CoordinationStore -> Transaction a -> IO a
mutate store action=runTransaction store $ do value<-action;pure(value,[Invalidation "service.changed" "/v1/capabilities" "fixture"])
number :: CoordinationStore -> Text -> IO Int64
number store sql=runRead store $ do rows<-query sql [];case rows of [[SQL.SQLInteger n]]->pure n;_->refuseTransaction StoreIntegrity

data Fixture = Fixture FilePath InstalledConfiguration CoordinationStore CredentialProof (Text -> Text) DraftView
withReady :: FilePath -> FilePath -> String -> [Text] -> [(Text,Text)] -> (Fixture -> IO a) -> IO a
withReady work native = withReadyRunner work native [] "person-controlled"

withReadyRunner :: FilePath -> FilePath -> [Text] -> Text -> String -> [Text] -> [(Text,Text)] -> (Fixture -> IO a) -> IO a
withReadyRunner = withReadyRunnerLedger 8388608

withReadyRunnerLedger :: Int64 -> FilePath -> FilePath -> [Text] -> Text -> String -> [Text] -> [(Text,Text)] -> (Fixture -> IO a) -> IO a
withReadyRunnerLedger = withReadyRunnerProfiles [("profile",["shared"])]

withReadyRunnerProfiles :: [(Text,[Text])] -> Int64 -> FilePath -> FilePath -> [Text] -> Text -> String -> [Text] -> [(Text,Text)] -> (Fixture -> IO a) -> IO a
withReadyRunnerProfiles configuredProfiles ledger work native prefix selectedWorkflow name arguments environment action=do
  capabilities <- getNumCapabilities
  let root=work </> name;path=work </> (name<>".json")
  createDirectory root;setFileMode root 0o700
  BS.writeFile path(encoded(object["version" .= (1::Int),"managerRoot" .= root,"localRetentionRoots" .= ([]::[String]),
    "runners" .= [object["alias" .= ("native"::Text),"executable" .= native,"prefix" .= prefix]],
    "profiles" .= [object["id" .= profileId,"runner" .= ("native"::Text),"workspace" .= work,"workspaceLabel" .= ("Review workspace"::Text),"targetLabel" .= ("Deterministic worker"::Text),
      "targetArguments" .= arguments,"environment" .= [object["name" .= envName,"value" .= value]|(envName,value)<-[("TMPDIR",T.pack work),("XDG_CONFIG_HOME",T.pack(work </> "config")),("GHCRTS",T.pack ("-N"<>show capabilities))]<>environment],
      "ownership" .= ("service-owned"::Text),"quarantined" .= False,"personAnswering" .= ("local-control"::Text),"resourceKeys" .= resources]|(profileId,resources)<-configuredProfiles],
    "limits" .= object["drafts" .= (10::Int),"globalDrafts" .= (20::Int),"globalCaptureBytes" .= (67108864::Int),"globalPageSets" .= (2::Int),"globalConnections" .= (8::Int),"globalDatabaseReaders" .= (2::Int),"globalMutationLedgerBytes" .= ledger,"safetyControlsPerMinute" .= (20::Int),"executionReservations" .= length configuredProfiles]]))
  setFileMode path 0o600
  let registry=Cli.Registry "approval-check" "workflow" "approval fixture" []
      validate requested=either(const(Left InvalidConfiguration))Right(Cli.validateManagerTarget registry requested)
      validatePrepared requested nativePrepared=either(const(Left InvalidReply))Right(Cli.validateManagerPreparedTarget registry requested nativePrepared)
  config<-loadConfiguration validate validatePrepared (const False) path >>=right
  bracket (installConfiguration config >>=right) closeConfiguration $ \installed->withCoordinationStore installed $ \store->do
    (_,profiles)<-configurationSnapshot installed >>=right
    policy<-case filter ((=="profile") . publicId) profiles of [profile]->pure(publicRevision profile);_->error "profile count"
    catalogue<-probeConfiguredProfile installed "profile" policy>>=right
    let secret=BS.replicate 32 97
    mutate store $ do
      execute "INSERT INTO clients VALUES ('client','revision','authority',0)" []
      execute "INSERT INTO credentials VALUES ('credential','client',?,'2999-01-01T00:00:00Z',0)" [SQL.SQLBlob(convert(hash secret::Digest SHA256))]
      forM_ configuredProfiles $ \(profileId,_) -> forM_ ["observe","submit","control"::Text] $ \scope->execute "INSERT INTO credential_scopes VALUES ('credential',?,?)" [SQL.SQLText profileId,SQL.SQLText scope]
    proof<-authenticateCredential store secret>>=right
    identity<-storeIdentity store
    let key suffix=storeAuthorityEpoch identity<>"."<>T.replicate 22 "n"<>suffix
        etag view=Just("\""<>draftRevision view<>"\"")
    workflow<-case [ident|(ident,descriptor)<-discoveryEntries catalogue,workflowName descriptor==selectedWorkflow]of [ident]->pure ident;_->error "native workflow"
    draft<-createDraft store proof (key "create") (encoded(object["workflowId" .= workflow,"descriptorRevision" .= discoveryRevision catalogue,"profileId" .= ("profile"::Text),"profileRevision" .= policy]))>>=right
    _<-changeDraftInput store proof (draftId draft) (key "input") (etag draft) (encoded(object["operation" .= ("set-input"::Text),"input" .= LiteralValue "input" "Consent for this exact worker."]))>>=right
    ready<-readDraft store proof(draftId draft)>>=right
    action(Fixture root installed store proof key ready)

awaitHistory :: IO a -> IO a
awaitHistory action=timeout 120000000 action >>= maybe(error "history native deadline expired; original cleanup not certified")pure

lineageAnswers :: Map.Map Runtime.OccurrenceId Value
lineageAnswers=Map.fromList [(Runtime.OccurrenceId 1,Bool False),(Runtime.OccurrenceId 2,Null),(Runtime.OccurrenceId 3,object["ok" .= False,"notes" .= ([]::[Text])])]

nativeLineageChecks :: Bool -> FilePath -> FilePath -> IO ()
nativeLineageChecks barriers base native = nativeLineageChecksWith barriers False [1,2,3] base native ["--scripted"] []

nativeRoutedLineageChecks :: FilePath -> FilePath -> FilePath -> FilePath -> IO ()
nativeRoutedLineageChecks = nativeRoutedLineageChecksWith (\_ _ _ _ _ -> pure ())

nativeRoutedLineageChecksWith :: NativeComparison -> FilePath -> FilePath -> FilePath -> FilePath -> IO ()
nativeRoutedLineageChecksWith compareRuns base native source python=do
  routedPolicyProjectionChecks
  let work=base </> "manifest-v3"
      adapters=work </> "adapter-bin"
      adapter=adapters </> "history-adapter"
      script=source </> "engine/acp/test/stub_adapter.py"
      routing=work </> "config/agent-cat/routing.yaml"
      scratch=work </> "scratch"
  createDirectoryIfMissing True adapters
  createDirectoryIfMissing True(work </> "config/agent-cat")
  createDirectory scratch
  writeFile adapter("#!"<>python<>"\nimport os,sys\nos.execv("<>show python<>",["<>show python<>","<>show script<>",*sys.argv[1:]])\n")
  setFileMode adapter 0o700
  BS.writeFile routing(encoded(object["version" .= (2::Int),"default-persona" .= ("fixture"::Text),"secrets" .= object[],
    "engines" .= object["local" .= object["backend" .= ("acp:history-adapter"::Text),"provider" .= ("fixture"::Text)]],
    "models" .= object["selected" .= object["engine" .= ("local"::Text),"select" .= [object["exact" .= ("stub-default"::Text)]]]],
    "personas" .= object["fixture" .= object["engines" .= ["local"::Text],"models" .= ["selected"::Text],
      "profiles" .= object["primary" .= object["chain" .= [object["model" .= ("selected"::Text),"thinking" .= ("low"::Text),"max-output" .= ("unconstrained"::Text)]]]]]]]))
  setFileMode routing 0o600
  nativeLineageChecksCompared compareRuns False True [3] base native ["--scratch",T.pack scratch] [("PATH",T.pack adapters)]
  putStrLn "PASS actual WM018 non-null routed policy provenance"

routedPolicyProjectionChecks :: IO ()
routedPolicyProjectionChecks=do
  let digest=T.replicate 64 "a"
      bare=String digest
      native=String("sha256:"<>digest)
      policy policyDigest executionFingerprint=object["kind" .= ("routed"::Text),"coverage" .= ("full"::Text),"routes" .= ([]::[Value]),
        "pollMs" .= Null,"timeoutMs" .= Null,"verbose" .= False,"routingVersion" .= (2::Int),"persona" .= ("fixture"::Text),"personaSource" .= ("user-default"::Text),"policyDigest" .= policyDigest,
        "realizations" .= [object["profile" .= ("primary"::Text),"axis" .= ("controlled"::Text),"rung" .= (0::Int),"backend" .= ("acp:history-adapter"::Text),"router" .= ("local"::Text),"provider" .= ("fixture"::Text),"model" .= ("stub-default"::Text),"thinking" .= ("low"::Text),"maxOutput" .= Null,"executionFingerprint" .= executionFingerprint]]]
      projected value=P.policyValue <$> P.projectPolicy value
      refused value=case P.projectPolicy value of Left InvalidInput->True;_->False
      publicAccepts value=case eitherDecodeStrict' @P.PublicPolicy(encoded value) of Right _->True;_->False
  check "native policy projection preserves both SHA256 meanings" (projected(policy native native)==Right(policy bare bare))
  check "policy projection preserves accepted bare hex" (projected(policy bare bare)==Right(policy bare bare))
  check "strict public parser accepts bare hex" (publicAccepts(policy bare bare))
  forM_ [policy native native,policy native bare,policy bare native] $ \value ->
    check "strict public parser still refuses native fingerprint spelling" (not(publicAccepts value))
  forM_ [String("sha512:"<>digest),String("sha256:"<>T.take 63 digest),String("sha256:"<>digest<>"a"),String("sha256:"<>T.toUpper digest),String("sha256:sha256:"<>digest),Null,Number 1,Bool False,object[]] $ \bad -> do
    check "projection refuses malformed native policy digest" (refused(policy bad native))
    check "projection refuses malformed native execution fingerprint" (refused(policy native bad))

nativeLineageChecksWith :: Bool -> Bool -> [Int] -> FilePath -> FilePath -> [Text] -> [(Text,Text)] -> IO ()
nativeLineageChecksWith = nativeLineageChecksCompared (\_ _ _ _ _ -> pure ())

type NativeComparison = Fixture -> Text -> ReviewContext -> FilePath -> RunId -> IO ()

nativeLineageChecksCompared :: NativeComparison -> Bool -> Bool -> [Int] -> FilePath -> FilePath -> [Text] -> [(Text,Text)] -> IO ()
nativeLineageChecksCompared compareRuns barriers routed versions base native arguments environment = forM_ versions $ \branchVersion -> do
  let work=base </> ("manifest-v"<>show branchVersion)
      workflow=if routed then "controlled-single" else "lineage-typed"
      expectedCount=if routed then 1 else 4
      forkEdits=if routed then [Runtime.ReplaceAnswer(Runtime.OccurrenceId 0)(Bool False)] else
        [Runtime.DropAnswer(Runtime.OccurrenceId 0),Runtime.ReplaceAnswer(Runtime.OccurrenceId 1)(Bool False),Runtime.ReplaceAnswer(Runtime.OccurrenceId 2)Null,Runtime.ReplaceAnswer(Runtime.OccurrenceId 3)(object["ok" .= False,"notes" .= (["replacement"]::[Text])])]
  createDirectoryIfMissing True work
  withReadyRunner work native [] workflow "history-managed" arguments environment $ \fixture@(Fixture root _ store proof originalKey ready) ->
    withReadyRunner work native [] workflow "history-direct" arguments environment $ \(Fixture directRoot _ directStore directProof _ directReady) -> do
      let key = shortLineageKey originalKey
      directAssembly<-assembleDraftSnapshot directStore directProof(draftId directReady)>>=right
      directParent<-directLineageRun directStore directReady (assemblySetup directAssembly)
      withAdmissionClock fixedClock store $ \controller -> do
        (parent,context)<-managedLineageRun store proof key controller ready (if routed then Nothing else Just (fixture,controller)) routed
        let parentNative=preparedRunId(reviewNative context)
            parentPath=root </> "runs/runs" </> T.unpack(runIdText parentNative) </> "supervisor-manifest.json"
            directPath=directRoot </> "runs/runs" </> T.unpack(runIdText directParent) </> "supervisor-manifest.json"
        compareRuns fixture parent context directRoot directParent
        source<-BS.readFile parentPath >>= right . Runtime.decodeFrontendManifest
        directSource<-BS.readFile directPath >>= right . Runtime.decodeFrontendManifest
        check "native lineage parent has nonempty captured inputs" (not(Map.null(Runtime.frontendInputHashes source)))
        parentPolicy<-if routed then do
          managedFacts<-lineageFacts expectedCount(root </> "runs") parentNative
          directFacts<-lineageFacts expectedCount(directRoot </> "runs") directParent
          managedPolicy<-requireRoutedPolicy parentNative managedFacts
          directPolicy<-requireRoutedPolicy directParent directFacts
          check "routed native parents preserve exact direct facts and policy" (managedFacts==directFacts && managedPolicy==directPolicy)
          check "routed parent review binds executed policy" (preparedPolicy(reviewNative context)==fst managedPolicy)
          pure(Just managedPolicy)
          else pure Nothing
        forM_ [branchVersion] $ \version -> do
          let branch manifest=manifest {Runtime.frontendVersion=version,
                Runtime.frontendInvocation=if version==3 then Runtime.frontendInvocation manifest else Nothing,
                Runtime.frontendRunnerExecutable=if version==1 then Nothing else Runtime.frontendRunnerExecutable manifest,
                Runtime.frontendRunnerVersion=if version==1 then Nothing else Runtime.frontendRunnerVersion manifest,
                Runtime.frontendPersonAnswering=if version==1 then Nothing else Runtime.frontendPersonAnswering manifest,
                Runtime.frontendOwnerId=if version==1 then Nothing else Runtime.frontendOwnerId manifest}
          parentBytes<-if routed then BS.readFile parentPath else pure(Runtime.encodeFrontendManifest(branch source))
          unless routed $ do
            BS.writeFile parentPath parentBytes
            BS.writeFile directPath(Runtime.encodeFrontendManifest(branch directSource))
          _<-right(Runtime.decodeFrontendManifest parentBytes)
          forM_ (zip [0::Int ..] [RestartParent,ResumeParent,ForkParent forkEdits]) $ \(index,mutation) -> do
            let suffix=T.pack(show version<>"-"<>show index)
            draft<-lineageDraft store proof key parent suffix mutation
            (child,childContext)<-managedLineageRun store proof key controller draft Nothing routed
            direct<-directLineageRun directStore directReady (Runtime.DerivedSetup(directRoot </> "runs") directParent (lineageOperation mutation) (lineageEdits mutation) Runtime.PersonAnswerLocalControl (Just(assemblySelectionInvocation directAssembly)))
            compareRuns fixture child childContext directRoot direct
            let childNative=preparedRunId(reviewNative childContext)
            check "distinct accepted request, manager run and native run" (draftId draft/=draftId ready && child/=parent && childNative/=parentNative)
            links<-runRead store $ do rows<-query "SELECT parent_run_id FROM runs WHERE id=?" [SQL.SQLText child];pure[link|[SQL.SQLText link]<-rows]
            check "approved native child retains manager parent link" (links==[parent])
            managedFacts<-lineageFacts expectedCount(root </> "runs") childNative
            directFacts<-lineageFacts expectedCount(directRoot </> "runs") direct
            check ("native legacy/v"<>show version<>" "<>show mutation<>" preserves direct answers trace reuse bills policy result") (managedFacts==directFacts)
            forM_ parentPolicy $ \expectedPolicy -> do
              managedPolicy<-requireRoutedPolicy childNative managedFacts
              directPolicy<-requireRoutedPolicy direct directFacts
              check "routed child preserves immutable parent policy document and fingerprint" (managedPolicy==expectedPolicy && directPolicy==expectedPolicy)
              check "routed child review binds executed policy" (preparedPolicy(reviewNative childContext)==fst managedPolicy)
              currentParent<-lineageFacts expectedCount(root </> "runs") parentNative >>= requireRoutedPolicy parentNative
              currentDirectParent<-lineageFacts expectedCount(directRoot </> "runs") directParent >>= requireRoutedPolicy directParent
              directUnchanged<-BS.readFile directPath >>= right . Runtime.decodeFrontendManifest
              check "both routed parents retain original provenance and immutable manifests" (currentParent==expectedPolicy && currentDirectParent==expectedPolicy && directUnchanged==directSource)
            unchanged<-BS.readFile parentPath
            check "native lineage leaves accepted parent manifest unchanged" (unchanged==parentBytes)
        when barriers (lineageParentBarriers store proof key controller parent parentPath)
        putStrLn "PASS actual WM018 native lineage preservation and original ownership"
  where assemblySelectionInvocation=selectionInvocation . assemblySelection

requireRoutedPolicy :: RunId -> Value -> IO (Value,Text)
requireRoutedPolicy native (Object facts)=case (KM.lookup "policy" facts,KM.lookup "fingerprint" facts) of
  (Just policy@(Object fields),Just(String fingerprint))->do
    let expected="sha256:"<>T.pack(show(hash(encoded(Object(KM.delete "policyDigest" fields)))::Digest SHA256))
    check "required routed policy fingerprint is non-null, well-formed and matches actual policy" (KM.lookup "kind" fields==Just(String "routed") && KM.lookup "routingVersion" fields==Just(Number 2) && KM.lookup "policyDigest" fields==Just(String fingerprint) && fingerprint==expected)
    putStrLn("POLICY "<>T.unpack(runIdText native)<>" "<>T.unpack fingerprint)
    pure(policy,fingerprint)
  _->error "required routed policy document or fingerprint absent"
requireRoutedPolicy _ _=error "native lineage facts object absent"

shortLineageKey :: (Text -> Text) -> Text -> Text
shortLineageKey key suffix=key(T.take 24(T.pack(show(hash(encoded suffix)::Digest SHA256))))

lineageDraft :: CoordinationStore -> CredentialProof -> (Text->Text) -> Text -> Text -> LineageMutation -> IO DraftView
lineageDraft store proof key parent suffix mutation=do
  revision<-runRead store $ do rows<-query "SELECT revision FROM runs WHERE id=?" [SQL.SQLText parent];case rows of [[SQL.SQLText r]]->pure r;_->refuseTransaction StoreIntegrity
  receipt<-createLineageDraft store proof parent(key("lineage-"<>suffix))(Just("\""<>revision<>"\""))(encoded mutation)>>=right
  ident<-runRead store $ do rows<-query "SELECT request_id FROM commands WHERE id=?" [SQL.SQLText(receiptId receipt)];case rows of [[SQL.SQLText r]]->pure r;_->refuseTransaction StoreIntegrity
  readDraft store proof ident >>=right

managedLineageRun :: CoordinationStore -> CredentialProof -> (Text->Text) -> Admission -> DraftView -> Maybe (Fixture,Admission) -> Bool -> IO (Text,ReviewContext)
managedLineageRun store proof key controller draft ownershipCheck modelOnly=do
  _<-enqueueRequest controller proof(draftId draft)(key("enqueue-"<>draftId draft))(Just("\""<>draftRevision draft<>"\""))(encoded(object["operation" .= ("enqueue"::Text)]))>>=right
  live<-admitOldest controller>>=right>>=maybe(error "lineage admission")pure
  context<-await(awaitReview live)>>=right
  reviewed<-publishReview store live>>=right
  ident<-runRead store $ do rows<-query "SELECT id FROM preparations WHERE request_id=?" [SQL.SQLText(draftId draft)];case rows of [[SQL.SQLText i]]->pure i;_->refuseTransaction StoreIntegrity
  public<-readPreparation store proof ident>>=right
  (_,start)<-acceptApproval reviewed proof(key("approve-"<>draftId draft))(condition public)(approvalBody public)>>=right
  owned<-maybe(error "lineage original start")pure start
  deliverAcceptedStart owned>>=right
  firstQuestion<-newIORef True
  let loop=do
        more<-ingestAcceptedStart owned
        when more $ do
          pending<-runRead store $ do
            rows<-query "SELECT id,occurrence_id,generation,revision FROM decisions WHERE run_id=? AND state='pending'" [SQL.SQLText(acceptedStartRun owned)]
            pure[(i,o,g,r)|[SQL.SQLText i,SQL.SQLText o,SQL.SQLText g,SQL.SQLText r]<-rows]
          forM_ pending $ \(decision,occurrence,generation,revision)->do
            firstQuestionNow<-readIORef firstQuestion
            when firstQuestionNow $ do
              writeIORef firstQuestion False
              forM_ ownershipCheck $ \(fixture,owner)->nativeHistoryOwnership fixture owner context owned
            numberValue<-case reads(T.unpack occurrence) of [(n,"")]->pure(Runtime.OccurrenceId n);_->error "occurrence"
            value<-maybe(error "unexpected native question")pure(Map.lookup numberValue lineageAnswers)
            submitted<-submitDecisionControl owned proof decision(key("answer-"<>decision))(Just("\""<>revision<>"\""))(encoded(object["operation" .= ("answer"::Text),"occurrenceId" .= occurrence,"generation" .= generation,"value" .= value]))>>=right
            deliverAcceptedControl owned(receiptId(submissionReceipt submitted))>>=right
            when(occurrence=="3")(await(awaitAdmissionCleanup live)>>=right)
          loop
  -- Model-only and reused/edited answers have no interactive lane to hold completion.
  when(modelOnly || draftLineage draft `elem` [Just "resume",Just "fork"])(await(awaitAdmissionCleanup live)>>=right)
  await loop
  await(awaitAdmissionCleanup live)>>=right
  pure(acceptedStartRun owned,context)

directLineageRun :: CoordinationStore -> DraftView -> Runtime.FrontendSetupRequest -> IO RunId
directLineageRun store draft setup=Worker.withFrontendWorker store(draftProfile draft)(draftProfileRevision draft)setup $ \worker -> do
  prepared<-Worker.workerPrepared worker
  Worker.startWorker worker
  let loop=Worker.consumeWorkerEvent worker (\event -> case Runtime.envelopeEvent(workerEventEnvelope event) of
        Runtime.OccurrencePersonAnswerPending occurrence _ -> do
          value<-maybe(error "direct native question")pure(Map.lookup occurrence lineageAnswers)
          Worker.writeWorkerControl worker(Runtime.Control(Runtime.ControlId("direct_"<>T.pack(show(Runtime.occurrenceNumber occurrence))))(Just occurrence)Nothing(Runtime.AnswerPerson value))
        _->pure()) >>= \more -> when more loop
  await loop
  pure(preparedRunId prepared)

lineageFacts :: Int -> FilePath -> RunId -> IO Value
lineageFacts expectedCount root native=Runtime.withPrivateRoot "native comparison" root $ \owned -> do
  now<-getCurrentTime
  (record,_)<-Runtime.withPrivateDirectoryAt owned ["runs",T.unpack(runIdText native)] $ \fd -> Runtime.readRunRecordWithEnvelopesAt(root </> "runs" </> T.unpack(runIdText native)) fd Nothing now
  snapshot<-maybe(error "native snapshot")pure(Runtime.recordSnapshot record)
  result<-BS.readFile(root </> "runs" </> T.unpack(runIdText native) </> "runtime/result.json") >>= right . (eitherDecodeStrict' :: BS.ByteString -> Either String Value)
  answers<-BS.readFile(root </> "runs" </> T.unpack(runIdText native) </> "runtime/answers.json") >>= right . (eitherDecodeStrict' :: BS.ByteString -> Either String Value)
  let get name(Object fields)=KM.lookup name fields;get _ _=Nothing
  resultBody<-maybe(error "native result document")pure(get "result" result)
  nativeAnswers<-case get "answers" answers of Just(Array values)->pure(sortOn(get "occurrenceId")(foldr (:) [] values));_->error "native answers"
  check "actual native terminal result succeeded" (Runtime.snapshotRunStatus snapshot==Runtime.RunSucceeded)
  check "comparison includes populated typed answers trace bills and native result" (length nativeAnswers==expectedCount && length(Runtime.snapshotAuthoredOrder snapshot)==expectedCount && Runtime.snapshotTraceRecorded snapshot && Runtime.snapshotBillFresh snapshot/=Nothing && Runtime.snapshotBillMemo snapshot/=Nothing && get "code" resultBody/=Nothing && get "value" resultBody/=Nothing)
  pure(object["nativeAnswers" .= nativeAnswers,"trace" .= map (\(Runtime.OccurrenceId n)->n) (Runtime.snapshotAuthoredOrder snapshot),"answers" .= [(Runtime.snapshotOccurrenceCode o,Runtime.snapshotOccurrenceAnswer o,Runtime.snapshotOccurrenceReuseKind o)|o<-Map.elems(Runtime.snapshotOccurrences snapshot)],
    "fresh" .= Runtime.snapshotBillFresh snapshot,"memo" .= Runtime.snapshotBillMemo snapshot,"policy" .= Runtime.recordPolicy record,
    "fingerprint" .= Runtime.frontendPolicyDigest(Runtime.recordManifest record),"code" .= get "code" resultBody,"value" .= get "value" resultBody])

nativeHistoryOwnership :: Fixture -> Admission -> ReviewContext -> AcceptedStart -> IO ()
nativeHistoryOwnership (Fixture _ _ store proof originalKey draft) controller context owned =
  Worker.withFrontendWorker store(draftProfile draft)(draftProfileRevision draft)(reviewSetup context) $ \foreignWorker -> do
    let key = shortLineageKey originalKey
    prepared<-Worker.workerPrepared foreignWorker
    mutate store $ execute "INSERT INTO runs(id,revision,control_revision,profile_id,root_identity,native_run_id,supervision,result_state) VALUES ('run_foreign','foreign','foreign','profile',?,?,'observer','absent')" [SQL.SQLText(preparedRootIdentity prepared),SQL.SQLText(runIdText(preparedRunId prepared))]
    Worker.startWorker foreignWorker
    let pending=do reached<-newIORef False;_<-Worker.consumeWorkerEvent foreignWorker(\event->case Runtime.envelopeEvent(workerEventEnvelope event) of Runtime.OccurrencePersonAnswerPending {}->writeIORef reached True;_->pure());readIORef reached >>= \yes->unless yes pending
    await pending
    before<-number store "SELECT count(*) FROM commands"
    forM_ [acceptedStartRun owned,"run_foreign"] $ \parent -> do
      revision<-runRead store $ do rows<-query "SELECT revision FROM runs WHERE id=?" [SQL.SQLText parent];case rows of [[SQL.SQLText r]]->pure r;_->refuseTransaction StoreIntegrity
      denied<-createLineageDraft store proof parent(key("live-parent-"<>parent))(Just("\""<>revision<>"\""))(encoded RestartParent)
      check "actual live original or foreign parent refuses mutation" (denied==Left OwnershipUnavailable)
    number store "SELECT count(*) FROM commands" >>=check "live-parent refusals have no command effect" . (==before)
    values<-newIORef []
    withHistory store proof [] (Just controller)(writeIORef values)
    observed<-readIORef values
    let limitations ident=[v|v@(Object fields)<-observed,KM.lookup "id" fields==Just(String ident)]
        has name(Object fields)=case KM.lookup "limitations" fields of Just(Array xs)->String name `elem` xs;_->False
        has _ _=False
    check "actual original live manager worker is not foreign" (case limitations(acceptedStartRun owned) of [v]->not(has "foreign-owner" v);_->False)
    check "actual foreign worker stays foreign observation" (case limitations "run_foreign" of [v]->has "foreign-owner" v;_->False)
    withHistory store proof [] Nothing(writeIORef values)
    absent<-readIORef values
    check "without original controller stored ownership is not adopted" (or [has "foreign-owner" v | v@(Object fields)<-absent,KM.lookup "id" fields==Just(String(acceptedStartRun owned))])

lineageParentBarriers :: CoordinationStore -> CredentialProof -> (Text->Text) -> Admission -> Text -> FilePath -> IO ()
lineageParentBarriers store proof key controller parent path=do
  original<-BS.readFile path
  manifest<-right(Runtime.decodeFrontendManifest original)
  let substitute=BS.writeFile path(Runtime.encodeFrontendManifest(manifest {Runtime.frontendCreatedAt="2026-09-19T00:00:01Z"}))
  invalid<-lineageDraft store proof key parent "invalid-native-edit" (ForkParent [Runtime.ReplaceAnswer(Runtime.OccurrenceId 1)(String "not-a-flag")])
  _<-enqueueRequest controller proof(draftId invalid)(key "invalid-edit-enqueue")(Just("\""<>draftRevision invalid<>"\""))(encoded(object["operation" .= ("enqueue"::Text)]))>>=right
  invalidLive<-admitOldest controller>>=right>>=maybe(error "invalid edit admission")pure
  invalidReview<-await(awaitReview invalidLive)
  check "actual native typed replacement validation refuses invalid edit" (case invalidReview of Left _->True;_->False)
  await(awaitAdmissionCleanup invalidLive)>>=right
  draft<-lineageDraft store proof key parent "assembly-race" RestartParent
  Audit.withReviewAudit "lineage-assembly" $ \barrier -> do
    _<-enqueueRequest controller proof(draftId draft)(key "assembly-enqueue")(Just("\""<>draftRevision draft<>"\""))(encoded(object["operation" .= ("enqueue"::Text)]))>>=right
    live<-admitOldest controller>>=right>>=maybe(error "assembly barrier admission")pure
    _<-Audit.waitReviewed barrier
    substitute
    Audit.releaseReviewed barrier
    refused<-await(awaitReview live)
    check "parent substitution after assembly cannot publish native review" (case refused of Left _->True;_->False)
    await(awaitAdmissionCleanup live)>>=right
    BS.writeFile path original
  draft2<-lineageDraft store proof key parent "approval-race" RestartParent
  _<-enqueueRequest controller proof(draftId draft2)(key "approval-race-enqueue")(Just("\""<>draftRevision draft2<>"\""))(encoded(object["operation" .= ("enqueue"::Text)]))>>=right
  live<-admitOldest controller>>=right>>=maybe(error "approval parent admission")pure
  _<-await(awaitReview live)>>=right
  reviewed<-publishReview store live>>=right
  ident<-runRead store $ do rows<-query "SELECT id FROM preparations WHERE request_id=?" [SQL.SQLText(draftId draft2)];case rows of [[SQL.SQLText i]]->pure i;_->refuseTransaction StoreIntegrity
  public<-readPreparation store proof ident>>=right
  substitute
  rejected<-acceptApproval reviewed proof(key "changed-parent-approval")(condition public)(approvalBody public)
  check "parent substitution before approval cannot consume consent" (case rejected of Left _->True;_->False)
  BS.writeFile path original
  (_,start)<-acceptApproval reviewed proof(key "original-parent-approval")(condition public)(approvalBody public)>>=right
  owned<-maybe(error "original parent approved start")pure start
  substitute
  _<-deliverAcceptedStart owned
  cleanup<-await(awaitAdmissionCleanup live)
  observation<-observeAcceptedStart owned
  putStrLn("Post-approval negative original cleanup: "<>show cleanup)
  check "native post-approval revalidation refuses substituted parent" (observedQueuedFrames observation==0 && case observedWorkerExit observation of Just(Left _)->True;_->False)
  check "post-approval negative retains proven original cleanup" (cleanup==Right() && not(observedCleanupUnproven observation))
  BS.writeFile path original

positive :: FilePath -> FilePath -> IO ()
positive work native=withReady work native "positive" ["--scripted"] [] $ \(Fixture _ _ store proof key ready)->do
    let etag view=Just("\""<>draftRevision view<>"\"")
    other<-createDraft store proof(key "other_create")(encoded(object["workflowId" .= draftWorkflow ready,"descriptorRevision" .= draftDescriptorRevision ready,"profileId" .= draftProfile ready,"profileRevision" .= draftProfileRevision ready]))>>=right
    _<-changeDraftInput store proof(draftId other)(key "other_input")(etag other)(encoded(object["operation" .= ("set-input"::Text),"input" .= LiteralValue "input" "Independent consent required."]))>>=right
    otherReady<-readDraft store proof(draftId other)>>=right
    time<-newTVarIO 0
    let clock=MonotonicClock(atomically(readTVar time))(\end->atomically(readTVar time>>=checkSTM.(>=end)))
        checkSTM=STM.check
    withAdmissionClock clock store $ \controller->do
      _<-enqueueRequest controller proof(draftId ready)(key "enqueue")(etag ready)(encoded(object["operation" .= ("enqueue"::Text)]))>>=right
      _<-enqueueRequest controller proof(draftId otherReady)(key "other_enqueue")(etag otherReady)(encoded(object["operation" .= ("enqueue"::Text)]))>>=right
      live<-admitOldest controller>>=right>>=maybe(error "no admission")pure
      context<-await(awaitReview live)>>=right
      reviewed<-publishReview store live>>=right
      ident<-runRead store $ do
        ids<-query "SELECT id FROM preparations WHERE state='live'" []
        case ids of [[SQL.SQLText value]]->pure value;_->refuseTransaction StoreIntegrity
      storedReview<-runRead store $ do
        rows<-query "SELECT review FROM preparations WHERE id=?" [SQL.SQLText ident]
        case rows of [[SQL.SQLBlob bytes]]->pure bytes;_->refuseTransaction StoreIntegrity
      _<-right(eitherDecodeStrict' storedReview::Either String P.Review)
      preparation<-readPreparation store proof ident>>=right
      BS.writeFile(work </> "preparation.json")(encoded preparation)
      _<-publishReview store live>>=right
      same<-readPreparation store proof ident>>=right
      check "publication preserves exact digest and expiry" (same==preparation)
      let approval=encoded(object["operation" .= ("approve"::Text),"reviewDigest" .= P.preparationDigest preparation,"requestRevision" .= P.preparationRequestRevision preparation,
            "profileRevision" .= P.preparationProfileRevision preparation,"descriptorRevision" .= P.preparationDescriptorRevision preparation,"processGeneration" .= P.preparationGeneration preparation])
          approvalCondition=Just("\""<>P.preparationRevision preparation<>"\"")
      (submission,start)<-acceptApproval reviewed proof(key "approve")approvalCondition approval>>=right
      owned<-maybe(error "missing original accepted start")pure start
      BS.writeFile(work </> "approved-receipt.json")(encoded(submissionReceipt submission))
      check "accepted intent is not delivery or native running" (receiptState(submissionReceipt submission)==Accepted)
      number store "SELECT count(*) FROM start_intents" >>=check "real original start intent committed" . (==1)
      number store "SELECT count(*) FROM runs WHERE runtime_snapshot IS NULL AND result_state='absent'" >>=check "start intent does not fabricate Runtime evidence" . (==1)
      atomically(writeTVar time(reviewDeadlineNanos context+1))
      let retired=acceptedTimerRetired owned >>= \done->unless done(threadDelay 1000>>retired)
      await retired
      check "original timer checks committed start before delayed delivery" True
      deliverAcceptedStart owned>>=right
      let running=observeAcceptedStart owned >>= \observed->if observedWorkerPhase observed==WorkerRunning then pure() else threadDelay 1000>>running
      await running
      number store "SELECT count(*) FROM reservations WHERE state='held'" >>=check "real running retains original reservation" . (==1)
      blocked<-admitOldest controller>>=right
      check "actual accepted-running occupancy blocks queued conflicting work" (case blocked of Nothing->True;_->False)
      (replay,_)<-acceptApproval reviewed proof(key "approve")approvalCondition approval>>=right
      check "exact approval replay returns immutable original receipt" (submissionReceipt replay==submissionReceipt submission && submissionReplayed replay)
      repeated<-deliverAcceptedStart owned
      check "original start cannot dispatch twice" (repeated==Left OwnershipUnavailable)
      stopAcceptedStart owned>>=right
      await(awaitAdmissionCleanup live)>>=right
      number store "SELECT count(*) FROM reservations WHERE state!='released'" >>=check "explicit original-owner stop joins before release" . (==0)
      (lastReply,_)<-acceptApproval reviewed proof(key "approve")approvalCondition approval>>=right
      check "cleanup does not rewrite accepted consent or receipt" (submissionReceipt lastReply==submissionReceipt submission)
      next<-admitOldest controller>>=right>>=maybe(error "released slot did not admit oldest waiting work")pure
      nextReview<-await(awaitReview next)>>=right
      check "queued work advances only after actual started-worker cleanup" (reviewRequest nextReview==draftId otherReady)

withPrepared :: Fixture -> MonotonicClock -> (Admission -> LivePreparation -> ReviewContext -> ReviewedPreparation -> P.Preparation -> IO a) -> IO a
withPrepared (Fixture _ _ store proof key ready) clock action=withAdmissionClock clock store $ \controller->do
  _<-enqueueRequest controller proof(draftId ready)(key "enqueue_ready")(Just("\""<>draftRevision ready<>"\""))(encoded(object["operation" .= ("enqueue"::Text)]))>>=right
  live<-admitOldest controller>>=right>>=maybe(error "no live admission")pure
  outcome<-await(awaitReview live)
  case outcome of Left _->observeLivePreparation live >>= print;_->pure ()
  context<-right outcome
  reviewed<-publishReview store live>>=right
  ident<-runRead store $ do
    rows<-query "SELECT id FROM preparations WHERE state='live'" []
    case rows of [[SQL.SQLText value]]->pure value;_->refuseTransaction StoreIntegrity
  public<-readPreparation store proof ident>>=right
  action controller live context reviewed public

shutdownDrainChecks :: FilePath -> FilePath -> IO ()
shutdownDrainChecks work native = withReadyRunnerProfiles [("profile",["shared"]),("pending",["pending"])] 8388608 work native [] "person-controlled" "shutdown-drain" ["--scripted"] [] $ \fixture@(Fixture _ installed store proof key _) -> do
  pendingId <- withPrepared fixture fixedClock $ \controller live context reviewed public -> do
    (_,start) <- acceptApproval reviewed proof(key "drain-approve")(condition public)(approvalBody public) >>= right
    owned <- maybe(error "missing retained drain start")pure start
    (_,profiles) <- configurationSnapshot installed >>= right
    revision <- case [publicRevision p|p<-profiles,publicId p=="pending"] of [value]->pure value;_->error "pending profile"
    catalogue <- probeConfiguredProfile installed "pending" revision >>= right
    workflow <- case [ident|(ident,descriptor)<-discoveryEntries catalogue,workflowName descriptor=="person-controlled"] of [ident]->pure ident;_->error "pending workflow"
    pending <- createDraft store proof(key "pending-create")(encoded(object["workflowId" .= workflow,"descriptorRevision" .= discoveryRevision catalogue,"profileId" .= ("pending"::Text),"profileRevision" .= revision])) >>= right
    _ <- changeDraftInput store proof(draftId pending)(key "pending-input")(Just("\""<>draftRevision pending<>"\""))(encoded(object["operation" .= ("set-input"::Text),"input" .= LiteralValue "input" "unapproved preparation"])) >>= right
    queued <- readDraft store proof(draftId pending) >>= right
    _ <- enqueueRequest controller proof(draftId queued)(key "pending-enqueue")(Just("\""<>draftRevision queued<>"\""))(encoded(object["operation" .= ("enqueue"::Text)])) >>= right
    unapproved <- admitOldest controller >>= right >>= maybe(error "pending admission")pure
    void(await(awaitReview unapproved) >>= right)
    void(publishReview store unapproved >>= right)
    ending <- async(closeAdmission controller 100)
    await(awaitAdmissionCleanup unapproved) >>= right
    number store "SELECT count(*) FROM preparations WHERE state='invalidated'" >>= check "drain invalidates only genuinely unapproved preparation" . (==1)
    number store "SELECT count(*) FROM start_intents" >>= check "committed original start survives unapproved cleanup" . (==1)
    refusal <- admitOldest controller
    check "healthy drain refuses new admission" (case refusal of Left StorageUnavailable->True;_->False)
    refusedApproval <- acceptApproval reviewed proof(key "after-drain")(condition public)(approvalBody public)
    check "healthy drain refuses new approval acceptance" (case refusedApproval of Left StorageUnavailable->True;_->False)
    deliverAcceptedStart owned >>= right
    finishShutdownPerson store proof key controller context owned
    await(awaitAdmissionCleanup live) >>= right
    result <- await(wait ending)
    check "genuine terminal drain completes without expiry" (result==ShutdownResult False(Right()))
    number store "SELECT count(*) FROM reservations WHERE state!='released'" >>= check "native drain releases only after original joined cleanup" . (==0)
    pure(draftId pending)
  withAdmission store $ \controller -> do
    pending <- readDraft store proof pendingId >>= right
    _ <- enqueueRequest controller proof pendingId(key "reuse-enqueue")(Just("\""<>draftRevision pending<>"\""))(encoded(object["operation" .= ("enqueue"::Text)])) >>= right
    live <- admitOldest controller >>= right >>= maybe(error "reused admission")pure
    void(await(awaitReview live) >>= right)
    check "same still-open Store prepares native work after healthy drain" True

shutdownRunningChecks :: FilePath -> FilePath -> IO ()
shutdownRunningChecks work native = forM_ [False,True] $ \expiry ->
  withReady work native ("shutdown-running-"<>show expiry) ["--scripted"] [] $ \fixture@(Fixture _ _ store proof key _) -> do
    time <- newTVarIO 0
    watching <- newEmptyMVar
    let timer=MonotonicClock(atomically(readTVar time))(\deadline -> do
          when(deadline==100)(void(tryPutMVar watching ()))
          atomically(readTVar time >>= STM.check . (>=deadline)))
    withPrepared fixture timer $ \controller live context reviewed public -> do
      (_,start) <- acceptApproval reviewed proof(key "running-approve")(condition public)(approvalBody public) >>= right
      owned <- maybe(error "missing running original start")pure start
      deliverAcceptedStart owned >>= right
      let pending = do
            count <- observeControl(number store "SELECT count(*) FROM decisions WHERE state='pending'")
            when(count==0)(observeControl(ingestAcceptedStart owned) >>= \more -> if more then pending else error "running stream ended early")
      await pending
      ending <- async(shutdownAdmission controller(if expiry then DrainUntil 100 else CancelNow))
      when expiry (await(takeMVar watching) >> atomically(writeTVar time 100))
      result <- await(wait ending)
      check "approved person-waiting shutdown retains actual deadline outcome" (result==ShutdownResult expiry(Right()))
      await(awaitAdmissionCleanup live) >>= right
      observed <- observeAcceptedStart owned
      check "approved native cancellation joins original physical owner without success fabrication"
        (case observedWorkerExit observed of Just(Left _) -> not(observedCleanupUnproven observed);_->False)
      let association=RunAssociation(acceptedStartRun owned) "profile" (preparedRootIdentity(reviewNative context))(preparedRunId(reviewNative context))
      projection <- restoreRunProjection store association >>= maybe(error "missing original running prefix")pure
      check "physical cancellation leaves Runtime terminal evidence separate"
        (Runtime.snapshotRunStatus(Runtime.checkpointSnapshot projection)==Runtime.RunRunning)
      number store "SELECT count(*) FROM commands WHERE operation='cancel'" >>= check "local cancellation does not invent committed public consent" . (==0)
      number store "SELECT count(*) FROM reservations WHERE state!='released'" >>= check "approved cancellation releases after original cleanup" . (==0)

finishShutdownPerson :: CoordinationStore -> CredentialProof -> (Text -> Text) -> Admission -> ReviewContext -> AcceptedStart -> IO ()
finishShutdownPerson store proof key controller context owned = do
  let association=RunAssociation(acceptedStartRun owned) "profile" (preparedRootIdentity(reviewNative context))(preparedRunId(reviewNative context))
      pending=runRead store $ do
        rows <- query "SELECT id,occurrence_id,generation,revision FROM decisions WHERE run_id=? AND state='pending'" [SQL.SQLText(acceptedStartRun owned)]
        forM rows $ \row -> case row of [SQL.SQLText i,SQL.SQLText o,SQL.SQLText g,SQL.SQLText r]->pure(i,o,g,r);_->refuseTransaction StoreIntegrity
      untilPending = do
        rows <- observeControl pending
        if null rows then observeControl(ingestAcceptedStart owned) >>= \more -> if more then untilPending else error "native person stream ended early" else pure rows
  forM_ [1,2::Int] $ \index -> do
    (ident,occurrence,generation,revision) <- await untilPending >>= \rows -> case rows of [row]->pure row;_->error "person decision count"
    observed <- newIORef []
    withHistory store proof [] (Just controller)(writeIORef observed)
    history <- readIORef observed
    check "healthy drain retains original owned live history" (or[KM.lookup "supervision" fields==Just(String "owned")|Object fields<-history,KM.lookup "id" fields==Just(String(acceptedStartRun owned))])
    let answer=encoded(object["operation" .= ("answer"::Text),"occurrenceId" .= occurrence,"generation" .= generation,"value" .= Bool True])
    accepted <- submitDecisionControl owned proof ident(key("drain-answer-"<>T.pack(show index)))(Just("\""<>revision<>"\""))answer >>= right
    check "answer acceptance during drain is not yet a native effect" (receiptState(submissionReceipt accepted)==Accepted)
    deliverAcceptedControl owned(receiptId(submissionReceipt accepted)) >>= right
    -- Consume the current decision before looking for the next generation.
    let consumed = do
          rows <- observeControl pending
          when(any(\(current,_,_,_)->current==ident)rows)(observeControl(ingestAcceptedStart owned) >>= \more -> if more then consumed else error "answer stream ended early")
    await consumed
  let drain = observeControl(ingestAcceptedStart owned) >>= \more -> when more drain
  await drain
  snapshot <- observeControl(restoreRunProjection store association) >>= maybe(error "missing terminal Runtime evidence")pure
  check "drain ingests genuine successful Runtime terminal evidence" (Runtime.snapshotRunStatus(Runtime.checkpointSnapshot snapshot)==Runtime.RunSucceeded)

shutdownReuseRaceChecks :: FilePath -> FilePath -> IO ()
shutdownReuseRaceChecks work native = withReady work native "shutdown-reuse-race" ["--scripted"] [] $ \fixture@(Fixture _ _ store _ _ _) ->
  Audit.withReviewAudit "shutdown-request" $ \audit -> do
    caller <- withAdmission store $ \controller -> do
      delayed <- async(shutdownAdmission controller CancelNow)
      _ <- Audit.waitReviewed audit
      pure delayed
    poll caller >>= check "old shutdown caller remains paused after original scope release" . maybe True (const False)
    withPrepared fixture fixedClock $ \_ live _ _ _ -> do
      observeLivePreparation live >>= check "new scope owns actual prepared native worker before old caller resumes" . maybe False ((==WorkerPrepared) . observedWorkerPhase)
      Audit.releaseReviewed audit
      result <- await(wait caller)
      check "delayed old caller returns original completed shutdown result" (result==ShutdownResult False(Right()))
      construction <- try @StoreFailure(withStoreWorker store(\_ _ _ -> pure()))
      check "delayed old caller cannot re-fence new scope construction" (construction==Right())
      observeLivePreparation live >>= check "delayed old caller cannot stop new scope native worker" . maybe False ((==WorkerPrepared) . observedWorkerPhase)

shutdownRaceChecks :: FilePath -> FilePath -> IO ()
shutdownRaceChecks work native = forM_ [False,True] $ \committed -> withReady work native ("shutdown-race-"<>show committed) ["--scripted"] [] $ \fixture@(Fixture _ _ store proof key _) -> do
  watching <- newEmptyMVar
  let timer=MonotonicClock(pure 0)(\deadline -> when(deadline==100)(void(tryPutMVar watching ())) >> atomically retry)
  withPrepared fixture timer $ \controller live context reviewed public -> do
    if committed then do
      (caller,ending) <- Audit.withAcceptanceAudit $ \audit -> do
        caller <- async(acceptApproval reviewed proof(key "race-approve")(condition public)(approvalBody public))
        _ <- Audit.waitAccepted audit
        number store "SELECT count(*) FROM start_intents" >>= check "shutdown race begins after actual committed approval" . (==1)
        ending <- async(closeAdmission controller 100)
        await(takeMVar watching)
        pure(caller,ending)
      (accepted,start) <- await(wait caller) >>= right
      owned <- maybe(error "committed approval lost original association")pure start
      check "post-commit drain retains original receipt without replay" (not(submissionReplayed accepted))
      acceptedTimerRetired owned >>= check "committed approval retires original preparation timer"
      deliverAcceptedStart owned >>= right
      second <- deliverAcceptedStart owned
      check "drain cannot deliver original start twice" (case second of Left _->True;_->False)
      finishShutdownPerson store proof key controller context owned
      result <- await(wait ending)
      check "committed acceptance race drains through original worker" (result==ShutdownResult False(Right()))
      number store "SELECT count(*) FROM commands WHERE operation='approve' AND attempted_at IS NOT NULL" >>= check "one committed approval has one original attempted delivery" . (==1)
    else Audit.withReviewAudit "acceptance" $ \audit -> do
      caller <- async(acceptApproval reviewed proof(key "race-approve")(condition public)(approvalBody public))
      _ <- Audit.waitReviewed audit
      ending <- async(closeAdmission controller 100)
      await(takeMVar watching)
      Audit.releaseReviewed audit
      refused <- await(wait caller)
      check "pre-validation shutdown refuses uncommitted approval" (case refused of Left _->True;_->False)
      await(awaitAdmissionCleanup live) >>= right
      result <- await(wait ending)
      check "uncommitted acceptance race invalidates only original preparation" (result==ShutdownResult False(Right()))
      number store "SELECT count(*) FROM start_intents" >>= check "fenced approval creates no committed start" . (==0)
      number store "SELECT count(*) FROM commands WHERE operation='approve'" >>= check "fenced approval creates no receipt" . (==0)

fixedClock :: MonotonicClock
fixedClock=MonotonicClock (pure 0) (\_->atomically retry)

approvalBody :: P.Preparation -> BS.ByteString
approvalBody value=encoded(object["operation" .= ("approve"::Text),"reviewDigest" .= P.preparationDigest value,"requestRevision" .= P.preparationRequestRevision value,
  "profileRevision" .= P.preparationProfileRevision value,"descriptorRevision" .= P.preparationDescriptorRevision value,"processGeneration" .= P.preparationGeneration value])
condition :: P.Preparation -> Maybe Text
condition value=Just("\""<>P.preparationRevision value<>"\"")

selectorChecks :: FilePath -> FilePath -> IO ()
selectorChecks work native=withReady work native "selectors" ["--scripted"] [] $ \fixture@(Fixture _ _ store proof key _)->withPrepared fixture fixedClock $ \_ _ _ reviewed public->do
  before<-number store "SELECT count(*) FROM invalidations"
  let alter name value=case toJSONBody of Object fields->encoded(Object(KM.insert name(String value)fields));_->error "approval object"
      toJSONBody=case eitherDecodeStrict'(approvalBody public)of Right value->value;Left failure->error failure
  forM_ [("reviewDigest",T.replicate 64 "b"),("requestRevision","wrong_request"),("profileRevision","wrong_profile"),("descriptorRevision","wrong_descriptor"),("processGeneration","wrong_generation")] $ \(name,value)->do
    result<-acceptApproval reviewed proof(key("bad_"<>T.take 16 value))(condition public)(alter name value)
    check "stale exact approval selector creates no start" (case result of Left StateConflict->True;_->False)
  stale<-acceptApproval reviewed proof(key "bad_etag")(Just "\"wrong_etag\"")(approvalBody public)
  check "stale preparation validator refuses" (case stale of Left StaleRevision->True;_->False)
  number store "SELECT count(*) FROM invalidations" >>=check "rejected approval consumes no invalidation" . (==before)
  number store "SELECT count(*) FROM commands WHERE operation='approve'" >>=check "rejected approval creates no receipt or dispatch reservation" . (==0)
  number store "SELECT count(*) FROM start_intents" >>=check "rejected approval leaves no start intent" . (==0)

privacyChecks :: FilePath -> FilePath -> IO ()
privacyChecks work native=withReady work native "privacy" ["--scripted"] [("DISPLAY_VALUE","9"),("VIEW_EXTRA","private-operator-value-X"),("PRIVATE_LABEL","Review workspace")] $ \fixture@(Fixture root _ store proof _ ready)->withPrepared fixture fixedClock $ \_ _ context _ public->do
  let render=renderValue . String
      renderValue payload=case preparedPlan(reviewNative context) of
        Object outer->case KM.lookup "program" outer of
          Just(Object program)->projectReview(draftWorkflow ready)context{reviewNative=(reviewNative context){preparedPlan=Object(KM.insert "program" (Object(KM.insert "privacyProbe" payload program))outer)}}
          _->error "native program"
        _->error "native plan"
  forM_ [T.pack root,T.pack work,"9","private-operator-value-X","Authorization: Bearer private-material","--api-key=private-material","https://user:password@private.invalid"] $ \private->
    check "known private values, paths and credential syntax refuse without echo" (case render private of Left InvalidInput->True;_->False)
  nested<-right(eitherDecodeStrict' "{\"outer\":[{\"authored\":\"\\u0039\"}]}"::Either String Value)
  check "decoded escaped content is screened inside nested native values" (case renderValue nested of Left InvalidInput->True;_->False)
  check "oversized required exact plan refuses instead of truncating" (case render(T.replicate 524289 "Z") of Left ViewTooLarge->True;_->False)
  ordinary<-right(render "Discussion of token and password handling remains authored text.")
  check "ordinary authored discussion stays exact" ("Discussion of token and password" `T.isInfixOf` P.reviewPlan ordinary)
  check "explicit public operator label retains its public meaning" (P.reviewWorkspaceLabel(P.preparationReview public)=="Review workspace")
  let encodedPublic=encoded public
  check "nonce and private binding hashes are absent from public preparation" (not(any (`BS.isInfixOf` encodedPublic)["nonce","contextSha256","nativeSha256","binding_"]))
  mutate store(execute "DELETE FROM credential_scopes WHERE credential_id='credential' AND scope='observe'" [])
  hidden<-readPreparation store proof(P.preparationId public)
  check "submit/control authority does not expose Observe-only review" (hidden==Left Forbidden)

lifecycleChecks :: FilePath -> FilePath -> IO ()
lifecycleChecks work native=do
  withReady work native "changed-input" ["--scripted"] [] $ \fixture@(Fixture _ _ store proof key ready)->withPrepared fixture fixedClock $ \controller live _ reviewed public->do
    current<-readDraft store proof(draftId ready)>>=right
    _<-editRequestInput controller proof(draftId ready)(key "edit_live")(Just("\""<>draftRevision current<>"\""))(encoded(object["operation" .= ("set-input"::Text),"input" .= LiteralValue "input" "Changed after consent."]))>>=right
    await(awaitAdmissionCleanup live)>>=right
    refused<-acceptApproval reviewed proof(key "stale_input")(condition public)(approvalBody public)
    check "changed input cannot start old prepared worker" (case refused of Left _->True;_->False)
    view<-readPreparation store proof(P.preparationId public)>>=right
    check "input mutation invalidates actual public preparation" (P.preparationState view=="invalidated" && P.preparationReason view==Just "input-changed")
  withReady work native "changed-descriptor" ["--scripted"] [] $ \fixture@(Fixture _ installed store proof key _)->withPrepared fixture fixedClock $ \_ live context reviewed public->do
    void(probeConfiguredProfile installed "profile" (reviewProfileRevision context)>>=right)
    refused<-acceptApproval reviewed proof(key "stale_catalogue")(condition public)(approvalBody public)
    check "changed descriptor invalidates old approval eligibility" (case refused of Left StaleRevision->True;_->False)
    await(awaitAdmissionCleanup live)>>=right
    view<-readPreparation store proof(P.preparationId public)>>=right
    check "descriptor change discards original worker and records invalidation" (P.preparationState view=="invalidated" && P.preparationReason view==Just "profile-changed")

workerLossChecks :: FilePath -> FilePath -> FilePath -> FilePath -> IO ()
workerLossChecks work native source python=do
  let evidence=work </> "worker-loss"
  withReadyRunner work python [T.pack(source </> "manager/test/approval_fixture.py"),T.pack native,"exit-on-trigger",T.pack evidence] "person-controlled" "worker-loss-root" ["--scripted"] [] $ \fixture@(Fixture _ _ store proof key _)->do
    armed<-newTVarIO False
    entered<-newEmptyMVar
    release<-newEmptyMVar
    let now=do
          pause<-atomically $ do flag<-readTVar armed;writeTVar armed False;pure flag
          when pause(putMVar entered()>>takeMVar release)
          pure 0
        clock=MonotonicClock now (\_->atomically retry)
    withPrepared fixture clock $ \_ live _ reviewed public->do
      atomically(writeTVar armed True)
      result<-bracket(async(acceptApproval reviewed proof(key "lost_worker")(condition public)(approvalBody public)))cancel $ \pending->do
        await(takeMVar entered)
        -- The first read is preliminary. Arm again so the next read is the final transaction guard.
        atomically(writeTVar armed True)
        putMVar release()
        await(takeMVar entered)
        active<-try @StoreFailure(storeIdentity store)
        check "worker loss rendezvous is inside active acceptance" (case active of Left StoreBusy->True;_->False)
        BS.writeFile (evidence<>".exit") BS.empty
        let lost=observeLivePreparation live >>= \status->case status of
              Just observation | observedWorkerPhase observation `elem` [WorkerExited,WorkerReleased] ->pure()
              _->threadDelay 1000>>lost
        await lost
        doesFileExist(evidence<>".joined") >>=check "controlled wrapper joined its original native child"
        putMVar release()
        wait pending
      check "detected original worker loss rejects final acceptance" (case result of Left StorageUnavailable->True;_->False)
      await(awaitAdmissionCleanup live)>>=right
      number store "SELECT count(*) FROM start_intents" >>=check "worker loss rolls back real start intent" . (==0)
      number store "SELECT count(*) FROM commands WHERE operation='approve'" >>=check "worker loss rolls back approving receipt" . (==0)

backpressureChecks :: FilePath -> FilePath -> FilePath -> FilePath -> IO ()
backpressureChecks work native source python=do
  let evidence=work </> "backpressure"
  withReadyRunner work python [T.pack(source </> "manager/test/approval_fixture.py"),T.pack native,"backpressure",T.pack evidence] "person-controlled" "backpressure-root" ["--scripted"] [] $ \fixture@(Fixture _ _ store proof key _)->withPrepared fixture fixedClock $ \_ live context reviewed public->do
    (_,accepted)<-acceptApproval reviewed proof(key "pressure_approve")(condition public)(approvalBody public)>>=right
    owned<-maybe(error "no accepted start")pure accepted
    deliverAcceptedStart owned>>=right
    let full=observeAcceptedStart owned >>= \status->if observedQueuedFrames status==32 then pure() else threadDelay 1000>>full
    await full
    number store "SELECT count(*) FROM reservation_resources" >>=check "actual full native queue retains running resource claim" . (==1)
    nativePresent native context >>=check "actual native inner worker is present before stop"
    stopAcceptedStart owned>>=right
    await(awaitAdmissionCleanup live)>>=right
    nativePresent native context >>=check "joined owner stop leaves no live native inner worker" . not
    number store "SELECT count(*) FROM reservations WHERE state!='released'" >>=check "full native queue cannot prevent confirmed release" . (==0)

storeRows :: CoordinationStore -> Text -> IO String
storeRows store sql = runRead store (show <$> query sql [])

observerChecks :: FilePath -> IO ()
observerChecks native = do
  let rejects label result = do
        outcome <- try @IOError (processObservation (pure result))
        check label (case outcome of Left _ -> True; _ -> False)
  processObservation (pure (ExitSuccess,"123 backend", "")) >>= check "observer accepts populated successful observation" . (==Just "123 backend")
  processObservation (pure (ExitFailure 1,"", "")) >>= check "observer accepts clean absent observation" . (==Nothing)
  rejects "observer rejects diagnostic exit-one rather than claiming absence" (ExitFailure 1,"", "observer denied")
  rejects "observer rejects diagnostic success" (ExitSuccess,"123 backend", "observer denied")
  rejects "observer rejects empty success" (ExitSuccess,"", "")
  rejects "observer rejects unexpected exit" (ExitFailure 2,"", "")
  rejects "observer rejects populated absent status" (ExitFailure 1,"123 backend", "")
  outcome <- try @IOError (processObservation (ioError (userError "fixture observer launch failed")))
  check "observer launch failure remains explicit" (case outcome of Left _ -> True; _ -> False)
  -- Genuine presence/absence are checked against the original joined workers in A06.
  check "observer native executable supplied" (not (null native))

processObservation :: IO (ExitCode,String,String) -> IO (Maybe String)
processObservation observe = do
  result@(code,output,diagnostic) <- observe
  if not (null diagnostic) then failed result else case code of
    ExitSuccess | not (null (words output)) -> pure (Just output)
    ExitFailure 1 | null (words output) -> pure Nothing
    _ -> failed result
  where failed result = ioError (userError ("process observation failed: "<>show result))

observeProcess :: String -> IO (Maybe String)
observeProcess pid = processObservation (readProcessWithExitCode observer ["-p",pid,"-o","pid=,command="] "")
  where observer = if os=="darwin" then "/bin/ps" else "ps"

framedIngestionChecks :: FilePath -> FilePath -> FilePath -> FilePath -> IO ()
framedIngestionChecks work native source python = forM_ ["frame-max","frame-overflow"] $ \mode -> do
  let evidence = work </> mode
  withReadyRunner work python [T.pack(source </> "manager/test/approval_fixture.py"),T.pack native,T.pack mode,T.pack evidence] "prompt-source" (mode<>"-root") ["--scripted"] [] $ \fixture@(Fixture _ _ store proof key _) ->
    withPrepared fixture fixedClock $ \_ live context reviewed public -> do
      (_,start) <- acceptApproval reviewed proof (key "framed-approve") (condition public) (approvalBody public) >>= right
      owned <- maybe (error "missing original framed approval") pure start
      let association = RunAssociation (acceptedStartRun owned) "profile" (preparedRootIdentity (reviewNative context)) (preparedRunId (reviewNative context))
      deliverAcceptedStart owned >>= right
      await (awaitAdmissionCleanup live) >>= right
      wire <- BS.readFile (evidence<>".wire")
      if mode=="frame-overflow" then do
        observed <- observeAcceptedStart owned
        check "genuine Worker rejects payload overflow before ingestion" (observedQueuedFrames observed==0 && case observedWorkerExit observed of Just (Left _) -> True; _ -> False)
        refused <- try @WorkerFailure (ingestAcceptedStart owned)
        check "overflow preserves original Worker framing failure" (refused==Left WorkerRuntimeFraming)
        restoreRunProjection store association >>= check "overflow leaves projection absent" . (==Nothing)
      else do
        check "genuine Worker maximum payload plus exact LF fixture" (BS.length wire==Runtime.maxFrameBytes+1 && BS.last wire==10)
        ingestAcceptedStart owned >>= check "genuine Worker exact maximum framed payload commits"
        restored <- restoreRunProjection store association >>= maybe (error "missing framed restoration") pure
        envelope <- right (Runtime.decodeEnvelopeFor Runtime.supportedProtocolVersions (BS.init wire))
        check "framed restoration uses unchanged Runtime decoder and fold" (Runtime.checkpointEnvelopes restored==[envelope])
        digestRows <- storeRows store "SELECT envelope_digest,length(envelope) FROM ingestions"
        check "complete original framed digest and length retained" (digestRows==show [[SQL.SQLText(T.pack(show(hash wire::Digest SHA256))),SQL.SQLInteger(fromIntegral(BS.length wire))]])
        count <- number store "SELECT count(*) FROM invalidations"
        ingestRuntimeEnvelope store association wire >>= check "exact framed duplicate no-op" . not
        number store "SELECT count(*) FROM invalidations" >>= check "framed duplicate emits no invalidation" . (==count)
        conflict <- try @StoreFailure (ingestRuntimeEnvelope store association (BS.init wire))
        check "same maximum Envelope without original LF conflicts" (conflict==Left StoreIntegrity)
        let drain = ingestAcceptedStart owned >>= \more -> when more drain
        await drain
        checkpoint <- restoreRunProjection store association >>= maybe (error "missing framed completed projection") pure
        check "remaining genuine framed history completes" (Runtime.snapshotRunStatus(Runtime.checkpointSnapshot checkpoint)==Runtime.RunSucceeded)

nativePresent :: FilePath -> ReviewContext -> IO Bool
nativePresent native context=nativeIdentityPresent native(runIdText(preparedRunId(reviewNative context)))
nativeIdentityPresent :: FilePath -> Text -> IO Bool
nativeIdentityPresent native identity=do
  pid<-case T.splitOn "-" identity of ["native",value,_] | T.all(\c->c>='0' && c<='9')value->pure(T.unpack value);_->error "native fixture identity"
  output <- observeProcess pid
  pure (maybe False (T.isInfixOf (T.pack native) . T.pack) output)

targetChecks :: FilePath -> FilePath -> FilePath -> FilePath -> IO ()
targetChecks work native source python=do
  let adapters=work </> "adapter-bin"
      adapter=adapters </> "review-adapter"
      script=source </> "engine/acp/test/stub_adapter.py"
      arguments=["--engine","acp","--adapter","review-adapter"]
      registry=Cli.Registry "approval-check" "workflow" "approval fixture" []
  createDirectory adapters
  writeFile adapter("#!"<>python<>"\nimport os,sys\nos.execv("<>show python<>",["<>show python<>","<>show script<>",*sys.argv[1:]])\n")
  setFileMode adapter 0o700
  let env=[("PATH",T.pack adapters)]
      verify name target workflow=withReadyRunner work native [] workflow name target env $ \fixture@(Fixture _ _ _ _ _ ready)->withPrepared fixture fixedClock $ \_ _ context _ public->do
        BS.writeFile(work </> ("public-preparation-"<>name<>".json"))(encoded public)
        let original=reviewNative context
            effective=preparedTargetArguments original
            result=Cli.validateManagerPreparedTarget registry target original
        check "actual native target association validates through retained CLI owner" (case result of Right()->True;_->False)
        forM_ [original{preparedTargetArguments="--verbose":effective},original{preparedTargetArguments=effective<>["--timeout","7"]},original{preparedTargetKind="deck"},
          original{preparedPolicy=case preparedPolicy original of Object value->Object(KM.insert "scratch" (String "/wrong/private/scratch")value);_->error "native policy"}] $ \forged->
          check "forged target prefix, suffix, kind or scratch policy refuses" (case Cli.validateManagerPreparedTarget registry target forged of Left _->True;_->False)
        check "derived and explicit scratch paths remain private in public policy" (not("scratch" `BS.isInfixOf` encoded(P.reviewPolicy(P.preparationReview public))))
        _<-right(projectReview(draftWorkflow ready)context)
        pure effective
  derived<-verify "acp-derived" arguments "person-controlled"
  check "actual native ACP derivation has exact original prefix" (take(length arguments)derived==arguments && length derived==length arguments+2)
  let explicit=arguments<>["--scratch",T.pack(work </> "explicit-scratch")]
  fixed<-verify "acp-explicit" explicit "person-controlled"
  check "explicit configured scratch is not overridden" (fixed==explicit)
  forM_ ["bad-prefix","bad-suffix","bad-target","bad-scratch"] $ \mode->do
    let evidence=work </> mode
    withReadyRunner work python [T.pack(source </> "manager/test/approval_fixture.py"),T.pack native,T.pack mode,T.pack evidence] "person-controlled" ("live-"<>mode) arguments env $ \(Fixture _ _ store proof key ready)->withAdmissionClock fixedClock store $ \controller->do
      _<-enqueueRequest controller proof(draftId ready)(key "forge")(Just("\""<>draftRevision ready<>"\""))(encoded(object["operation" .= ("enqueue"::Text)]))>>=right
      live<-admitOldest controller>>=right>>=maybe(error "missing forged-frame owner")pure
      result<-await(awaitReview live)
      check ("live Worker rejects real prepared field corruption: "<>mode) (case result of Left _->True;_->False)
      published<-publishReview store live
      check "rejected native target cannot publish review" (case published of Left _->True;_->False)
      await(awaitAdmissionCleanup live)>>=right
      joined<-doesFileExist(evidence<>".joined")
      check "forged-frame fixture joins its actual native child" joined
      ident<-TE.decodeUtf8 <$> BS.readFile(evidence<>".identity")
      nativeIdentityPresent native ident >>=check "rejected target leaves no original inner survivor" . not
      started<-doesFileExist(evidence<>".started")
      check "rejected target never forwards native start" (not started)
      number store "SELECT count(*) FROM commands WHERE operation='approve'" >>=check "rejected target creates no approving receipt" . (==0)
      forM_ ["preparations","start_intents","runs"] $ \table->number store("SELECT count(*) FROM "<>table)>>=check "rejected live target creates no approval association" . (==0)
      number store "SELECT count(*) FROM reservations WHERE state!='released'" >>=check "rejected target releases only after original cleanup" . (==0)

  let routing=work </> ".agent-cat" </> "routing.yaml"
  createDirectoryIfMissing True(work </> ".agent-cat")
  BS.writeFile routing(encoded(object["version" .= (1::Int),"routers" .= [object["name" .= ("fixture"::Text),"backend" .= ("acp:review-adapter"::Text),"provider" .= ("fixture"::Text)]],
    "profiles" .= [object["name" .= ("primary"::Text),"chain" .= [object["router" .= ("fixture"::Text),"model" .= ("fixture-model"::Text),"thinking" .= ("off"::Text),"max-output" .= ("unconstrained"::Text)]]]]]))
  setFileMode routing 0o600
  unloaded<-verify "routing-unloaded" [] "controlled-single"
  check "actual unloaded routing is resolved by original native worker and may derive scratch" (case unloaded of ["--scratch",path]->not(T.null path);_->False)

deadlineChecks :: FilePath -> FilePath -> IO ()
deadlineChecks work native=withReady work native "deadline" ["--scripted"] [] $ \fixture@(Fixture _ _ store proof key _)->do
  time<-newTVarIO 0
  armed<-newTVarIO False
  entered<-newEmptyMVar
  release<-newEmptyMVar
  let now=do
        pause<-atomically $ do value<-readTVar armed;writeTVar armed False;pure value
        when pause(putMVar entered()>>takeMVar release)
        atomically(readTVar time)
      clock=MonotonicClock now(\end->atomically(readTVar time>>=STM.check.(>=end)))
  withPrepared fixture clock $ \_ live context reviewed public->do
    atomically(writeTVar armed True)
    result<-bracket(async(acceptApproval reviewed proof(key "deadline_approval")(condition public)(approvalBody public)))cancel $ \pending->do
      await(takeMVar entered)
      atomically(writeTVar armed True)
      putMVar release()
      await(takeMVar entered)
      busy<-try @StoreFailure(storeIdentity store)
      check "real Approve deadline crosses inside active transaction" (case busy of Left StoreBusy->True;_->False)
      atomically(writeTVar time(reviewDeadlineNanos context))
      putMVar release()
      wait pending
    check "expired final approval guard refuses publication" (case result of Left StorageUnavailable->True;_->False)
    await(awaitAdmissionCleanup live)>>=right
    number store "SELECT count(*) FROM start_intents" >>=check "expired approval leaves no start intent" . (==0)
    number store "SELECT count(*) FROM runs" >>=check "expired approval rolls back run association" . (==0)
    number store "SELECT count(*) FROM commands WHERE operation='approve'" >>=check "expired approval rolls back receipt" . (==0)
    number store "SELECT count(*) FROM invalidations WHERE kind='run.changed'" >>=check "expired approval rolls back start invalidation" . (==0)
    expired<-readPreparation store proof(P.preparationId public)>>=right
    check "expired native preparation retains original digest without enqueue" (P.preparationDigest expired==P.preparationDigest public && P.preparationReason expired==Just "expired")

profileChecks :: FilePath -> FilePath -> IO ()
profileChecks work native=do
  withReady work native "profile-change" ["--scripted"] [] $ \fixture@(Fixture _ installed store proof key _)->withPrepared fixture fixedClock $ \_ live _ reviewed public->do
    let registry=Cli.Registry "approval-check" "workflow" "approval fixture" []
        validate args=either(const(Left InvalidConfiguration))Right(Cli.validateManagerTarget registry args)
        prepared args value=either(const(Left InvalidReply))Right(Cli.validateManagerPreparedTarget registry args value)
    config<-loadConfiguration validate prepared(const False)(work </> "profile-change.json")>>=right
    void(reloadConfiguration installed config>>=right)
    rejected<-acceptApproval reviewed proof(key "profile_changed")(condition public)(approvalBody public)
    check "actual profile reload rejects old review" (case rejected of Left StaleRevision->True;_->False)
    await(awaitAdmissionCleanup live)>>=right
    number store "SELECT count(*) FROM start_intents" >>=check "profile reload creates no replacement start" . (==0)
  withReady work native "revoked" ["--scripted"] [] $ \fixture@(Fixture _ _ store proof key _)->withPrepared fixture fixedClock $ \_ _ _ reviewed public->do
    mutate store(execute "UPDATE credentials SET revoked=1 WHERE id='credential'" [])
    rejected<-acceptApproval reviewed proof(key "revoked_approval")(condition public)(approvalBody public)
    check "fresh approval rechecks actual credential revocation" (case rejected of Left Unauthenticated->True;_->False)
    number store "SELECT count(*) FROM start_intents" >>=check "revoked approval commits no intent" . (==0)

reopenChecks :: FilePath -> FilePath -> IO ()
reopenChecks work native=withReady work native "reopen" ["--scripted"] [] $ \fixture@(Fixture root installed store _ key ready)->do
  (old,public)<-withPrepared fixture fixedClock $ \_ _ _ reviewed view->pure(reviewed,view)
  retryStoreCleanup store
  withCoordinationStore installed $ \freshStore->do
    proof<-authenticateCredential freshStore(BS.replicate 32 97)>>=right
    oldRead<-readPreparation freshStore proof(P.preparationId public)
    check "reopen does not expose historical preparation as live authority" (oldRead==Left ResourceUnavailable)
    oldStart<-acceptApproval old proof(key "reopened_approval")(condition public)(approvalBody public)
    check "old opaque review cannot start across Store lifetime" (case oldStart of Left _->True;_->False)
    new<-createDraft freshStore proof(key "replacement_create")(encoded(object["workflowId" .= draftWorkflow ready,"descriptorRevision" .= draftDescriptorRevision ready,"profileId" .= draftProfile ready,"profileRevision" .= draftProfileRevision ready]))>>=right
    _<-changeDraftInput freshStore proof(draftId new)(key "replacement_input")(Just("\""<>draftRevision new<>"\""))(encoded(object["operation" .= ("set-input"::Text),"input" .= LiteralValue "input" "Consent for this exact worker."]))>>=right
    newReady<-readDraft freshStore proof(draftId new)>>=right
    let replacement=Fixture root installed freshStore proof key newReady
    withPrepared replacement fixedClock $ \_ _ _ reviewed view->do
      check "replacement native worker requires a distinct bound digest" (P.preparationDigest view/=P.preparationDigest public)
      wrong<-acceptApproval reviewed proof(key "old_digest")(condition view)(approvalBody public)
      check "old digest cannot approve replacement worker" (case wrong of Left StateConflict->True;_->False)
      number freshStore "SELECT count(*) FROM start_intents" >>=check "reopen or old review never mints start intent" . (==0)

interruptionChecks :: FilePath -> FilePath -> IO ()
interruptionChecks work native=do
  withReady work native "interrupted-acceptance" ["--scripted"] [] $ \fixture@(Fixture _ _ store proof key _)->withPrepared fixture fixedClock $ \_ live _ reviewed public->Audit.withAcceptanceAudit $ \audit->do
    caller<-async(acceptApproval reviewed proof(key "interrupted_accept")(condition public)(approvalBody public))
    (originalThread,command)<-Audit.waitAccepted audit
    original<-receiptBytes store command
    number store "SELECT count(*) FROM start_intents" >>=check "interruption follows actual original start-intent commit" . (==1)
    number store "SELECT count(*) FROM commands WHERE operation='approve' AND attempted_at IS NOT NULL" >>=check "accepted return gap has not attempted native start" . (==0)
    number store "SELECT count(*) FROM reservation_resources" >>=check "interrupted acceptance retains original resource claim" . (==1)
    throwTo originalThread UserInterrupt
    interrupted caller
    (replay,retained)<-acceptApproval reviewed proof(key "interrupted_accept")(condition public)(approvalBody public)>>=right
    check "lost approval reply returns original committed receipt" (encoded(submissionReceipt replay)==original && submissionReplayed replay)
    owned<-maybe(error "interrupted approval lost original accepted association")pure retained
    deliverAcceptedStart owned>>=right
    running owned
    (reconciled,delivered,sameTicket,sameAttempt)<-Audit.auditSummary audit
    check "interrupted Approve retains original attempt and original one-shot ticket" (reconciled==1 && delivered==1 && sameTicket && sameAttempt)
    stopAcceptedStart owned>>=right
    await(awaitAdmissionCleanup live)>>=right
  withReady work native "interrupted-delivery" ["--scripted"] [] $ \fixture@(Fixture root _ store proof key _)->withPrepared fixture fixedClock $ \_ live context reviewed public->Audit.withDeliveryAudit $ \audit->do
    (accepted,start)<-acceptApproval reviewed proof(key "interrupted_delivery")(condition public)(approvalBody public)>>=right
    owned<-maybe(error "no accepted delivery")pure start
    caller<-async(deliverAcceptedStart owned)
    (originalThread,command)<-Audit.waitReturned audit
    check "native return boundary belongs to original committed command" (command==receiptId(submissionReceipt accepted))
    running owned
    throwTo originalThread UserInterrupt
    interrupted caller
    observation<-readCommand store proof command>>=right
    check "interrupted pipe delivery remains explicitly unresolved" (receiptState observation==Unresolved)
    (replay,_)<-acceptApproval reviewed proof(key "interrupted_delivery")(condition public)(approvalBody public)>>=right
    check "lost delivery reply does not rewrite original accepted receipt" (submissionReceipt replay==submissionReceipt accepted)
    rejected<-deliverAcceptedStart owned
    check "uncertain original delivery cannot be attempted again" (rejected==Left OwnershipUnavailable)
    stopAcceptedStart owned>>=right
    await(awaitAdmissionCleanup live)>>=right
    let events=root </> "runs" </> "runs" </> T.unpack(runIdText(preparedRunId(reviewNative context))) </> "runtime" </> "events.ndjson"
    bytes<-BS.readFile events
    let starts=length(filter (BS.isInfixOf "\"type\":\"run.started\"") (BS.split 10 bytes))
    (_,delivered,sameTicket,sameAttempt)<-Audit.auditSummary audit
    check "interrupted original start retains one native start and immutable receipt" (starts==1 && delivered==1 && sameTicket && sameAttempt)
  where
    receiptBytes store command=runRead store $ do
      rows<-query "SELECT receipt FROM commands WHERE id=?" [SQL.SQLText command]
      case rows of [[SQL.SQLBlob bytes]]->pure bytes;_->refuseTransaction StoreIntegrity
    interrupted caller=do
      outcome<-await(waitCatch caller)
      check "original UserInterrupt survives original acceptance/delivery cleanup" (case outcome of
        Left failure->case fromException failure of Just UserInterrupt->True;_->False
        Right _->False)
    running owned=await loop
      where loop=observeAcceptedStart owned >>= \state->unless(observedWorkerPhase state==WorkerRunning)(threadDelay 1000>>loop)

postStartLossChecks :: FilePath -> FilePath -> FilePath -> FilePath -> IO ()
postStartLossChecks work native source python=do
  let evidence=work </> "post-start-loss"
  withReadyRunner work python [T.pack(source </> "manager/test/approval_fixture.py"),T.pack native,"exit-on-trigger",T.pack evidence] "person-controlled" "post-start-loss-root" ["--scripted"] [] $ \fixture@(Fixture _ _ store proof key _)->withPrepared fixture fixedClock $ \_ live context reviewed public->do
    (original,accepted)<-acceptApproval reviewed proof(key "lost_after_start")(condition public)(approvalBody public)>>=right
    owned<-maybe(error "missing accepted owner")pure accepted
    deliverAcceptedStart owned>>=right
    let running=observeAcceptedStart owned >>= \status->unless(observedWorkerPhase status==WorkerRunning)(threadDelay 1000>>running)
    await running
    BS.writeFile(evidence<>".exit")BS.empty
    await(awaitAdmissionCleanup live)>>=right
    nativePresent native context >>=check "unexpected original worker exit leaves no surviving inner" . not
    number store "SELECT count(*) FROM reservations WHERE state!='released'" >>=check "unexpected started-worker exit releases only confirmed ownership" . (==0)
    number store "SELECT count(*) FROM runs WHERE supervision='lost' AND runtime_snapshot IS NULL" >>=check "worker exit records lost supervision without inventing Runtime result" . (==1)
    (replay,_)<-acceptApproval reviewed proof(key "lost_after_start")(condition public)(approvalBody public)>>=right
    check "unexpected worker loss does not erase accepted consent" (submissionReceipt replay==submissionReceipt original)
    checkRunEvents store

reservationChecks :: FilePath -> FilePath -> IO ()
reservationChecks work native=withReady work native "reservation-integrity" ["--scripted"] [] $ \fixture@(Fixture _ _ store proof key _)->withPrepared fixture fixedClock $ \_ _ _ reviewed public->do
  mutate store(execute "DELETE FROM reservation_resources" [])
  refused<-acceptApproval reviewed proof(key "incomplete_reservation")(condition public)(approvalBody public)
  check "approval requires complete original reservation footprint" (case refused of Left StateConflict->True;_->False)
  number store "SELECT count(*) FROM start_intents" >>=check "missing original resource claim creates no start" . (==0)
  number store "SELECT count(*) FROM commands WHERE operation='approve'" >>=check "missing original resource claim creates no receipt" . (==0)

reviewGapChecks :: FilePath -> FilePath -> IO ()
reviewGapChecks work native=forM_ [True,False] $ \changed->do
  withReady work native ("publication-gap-"<>show changed) ["--scripted"] [] $ \(Fixture _ configuration store proof key ready)->withAdmissionClock fixedClock store $ \controller->do
    _<-enqueueRequest controller proof(draftId ready)(key "publication_enqueue")(Just("\""<>draftRevision ready<>"\""))(encoded(object["operation" .= ("enqueue"::Text)]))>>=right
    original<-admitOldest controller>>=right>>=maybe(error "no publication owner")pure
    _<-await(awaitReview original)>>=right
    Audit.withReviewAudit "publication" $ \audit->do
      caller<-async(publishReview store original)
      executing<-Audit.waitReviewed audit
      putStrLn("REACHED original publication currentReview: "<>show executing)
      number store "SELECT count(*) FROM reservation_resources" >>=check "publication gap retains complete original claim" . (==1)
      when changed $ void(probeConfiguredProfile configuration "profile" (draftProfileRevision ready)>>=right)
      Audit.releaseReviewed audit
      result<-await(wait caller)
      check "publication final catalogue agrees with original currentReview" (case result of Left StaleRevision->changed;Right _->not changed;_->False)
      number store "SELECT count(*) FROM preparations" >>=check "stale publication creates no consent row" . (==if changed then 0 else 1)
      number store "SELECT count(*) FROM reservation_resources" >>=check "refused publication retains claim until original cleanup" . (==1)
    invalidateLivePreparation original "discarded">>=right
    await(awaitAdmissionCleanup original)>>=right
  withReady work native ("acceptance-gap-"<>show changed) ["--scripted"] [] $ \fixture@(Fixture _ configuration store proof key ready)->withPrepared fixture fixedClock $ \_ original _ reviewed public->Audit.withReviewAudit "acceptance" $ \audit->do
    caller<-async(acceptApproval reviewed proof(key "approval_gap")(condition public)(approvalBody public))
    executing<-Audit.waitReviewed audit
    putStrLn("REACHED original acceptance currentReview: "<>show executing)
    number store "SELECT count(*) FROM reservation_resources" >>=check "approval gap retains complete original claim" . (==1)
    when changed $ void(probeConfiguredProfile configuration "profile" (draftProfileRevision ready)>>=right)
    Audit.releaseReviewed audit
    result<-await(wait caller)
    check "fresh approval final catalogue agrees with original currentReview" (case result of Left StaleRevision->changed;Right _->not changed;_->False)
    number store "SELECT count(*) FROM start_intents" >>=check "stale fresh approval creates no start intent" . (==if changed then 0 else 1)
    number store "SELECT count(*) FROM commands WHERE operation='approve'" >>=check "stale fresh approval creates no approving receipt" . (==if changed then 0 else 1)
    number store "SELECT count(*) FROM commands WHERE operation='approve' AND attempted_at IS NOT NULL" >>=check "catalogue gap does not fabricate native start" . (==0)
    case result of
      Left _->await(awaitAdmissionCleanup original)>>=right
      Right(submission,retained)->do
        owned<-maybe(error "unchanged catalogue lost original accepted start")pure retained
        _<-probeConfiguredProfile configuration "profile" (draftProfileRevision ready)>>=right
        (replay,_)<-acceptApproval reviewed proof(key "approval_gap")(condition public)(approvalBody public)>>=right
        check "catalogue change cannot retroactively reinterpret accepted consent" (submissionReceipt replay==submissionReceipt submission && submissionReplayed replay)
        deliverAcceptedStart owned>>=right
        let running=observeAcceptedStart owned >>= \state->unless(observedWorkerPhase state==WorkerRunning)(threadDelay 1000>>running)
        await running
        stopAcceptedStart owned>>=right
        await(awaitAdmissionCleanup original)>>=right

nativePrivacyChecks :: FilePath -> FilePath -> IO ()
nativePrivacyChecks work native=do
  nativePrivacyCases work native "original" "quoted or punctuated native credentials refuse exact review"
    [("curl -H \"Authorization: Bearer synthetic-secret\"",True),
   ("curl -H 'Authorization: Bearer synthetic-secret'",True),
   ("(Authorization: Bearer synthetic-secret)",True),
   ("Authorization: Bearer synthetic-secret",True),
   ("{\"Authorization\": \"Bearer synthetic-secret\"}",True),
   ("`Authorization: Bearer synthetic-secret`",True),
   ("“Authorization: Bearer synthetic-secret”",True),
   ("curl --api-key=\"synthetic-secret\"",True),
   ("Discussion of token and password handling remains authored text.",False)]
  nativeHeaderChecks work native

nativeHeaderChecks :: FilePath -> FilePath -> IO ()
nativeHeaderChecks work native=do
  let names=["authorization","api_key","api-key","access_token","access-token","token","password","passwd","secret","client-secret"]
      layouts=[("none","",""),("before"," ",""),("after",""," "),("both"," "," ")]
      matrix=[(T.unpack name<>"/"<>T.unpack delimiter<>"/"<>layout,"curl -H \""<>name<>before<>delimiter<>after<>"synthetic-secret\"")
             |name<-names,delimiter<-[":","="],(layout,before,after)<-layouts]
      controls=[("case/"<>T.unpack name,"curl -H \""<>T.toUpper name<>" : synthetic-secret\"")|name<-names]
            <>[("flag/"<>T.unpack name,"command --"<>name<>" synthetic-secret")|name<-names]
      cases=("reported-api-key-header","curl -H \"api-key: synthetic-secret\""):matrix<>controls
  check "native matrix contains all ten names and eight delimiter layouts" (length names==10 && length matrix==80)
  forM_ (zip [0::Int ..] cases) $ \(index,(label,content))->do
    putStrLn("MATRIX "<>label)
    nativePrivacyCases work native ("header-"<>show index) "uniform credential delimiter matrix refuses native review" [(content,True)]
  nativePrivacyCases work native "header-benign" "uniform credential delimiter matrix refuses native review"
    [("Discussion of token and password handling remains authored text.",False),
     ("API documentation discusses authorization, api-key, access-token and client-secret.",False),
     ("Options: token and password are discussed here. Count=two.",False)]

nativePrivacyCases :: FilePath -> FilePath -> String -> String -> [(Text,Bool)] -> IO ()
nativePrivacyCases work native label refusal cases=forM_ (zip [0::Int ..] cases) $ \(index,(content,unsafe))->
  withReady work native ("native-privacy-"<>label<>"-"<>show index) ["--scripted"] [] $ \(Fixture _ _ store proof key ready)->do
    _<-changeDraftInput store proof(draftId ready)(key "privacy_input")(Just("\""<>draftRevision ready<>"\""))(encoded(object["operation" .= ("set-input"::Text),"input" .= LiteralValue "input" content]))>>=right
    updated<-readDraft store proof(draftId ready)>>=right
    withAdmissionClock fixedClock store $ \controller->do
      _<-enqueueRequest controller proof(draftId updated)(key "privacy_enqueue")(Just("\""<>draftRevision updated<>"\""))(encoded(object["operation" .= ("enqueue"::Text)]))>>=right
      live<-admitOldest controller>>=right>>=maybe(error "no privacy worker")pure
      context<-await(awaitReview live)>>=right
      check "genuine native plan contains exact authored input" (containsText content(preparedPlan(reviewNative context)))
      let planBytes=encoded(preparedPlan(reviewNative context))
      result<-publishReview store live
      if unsafe then do
        case result of
          Right _->do
            ids<-texts store "SELECT id FROM preparations"
            ident<-case ids of [value]->pure value;_->error "missing published preparation"
            exposed<-readPreparation store proof ident>>=right
            check "red witness reaches public encoding through native publication" ("synthetic-secret" `BS.isInfixOf` encoded exposed)
          Left _->pure()
        check refusal (case result of Left InvalidInput->True;_->False)
        retained<-await(awaitReview live)>>=right
        check "unsafe review refusal leaves exact native plan bytes unchanged" (encoded(preparedPlan(reviewNative retained))==planBytes)
        number store "SELECT count(*) FROM preparations" >>=check "unsafe native review creates no public preparation" . (==0)
        number store "SELECT count(*) FROM commands WHERE operation='approve'" >>=check "unsafe native review creates no approving receipt" . (==0)
      else do
        _<-right result
        ids<-texts store "SELECT id FROM preparations"
        ident<-case ids of [value]->pure value;_->error "missing safe preparation"
        public<-readPreparation store proof ident>>=right
        check "ordinary native authored discussion remains unchanged" (content `T.isInfixOf` P.reviewPlan(P.preparationReview public))
        check "safe public review preserves exact native plan codec bytes" (TE.encodeUtf8(P.reviewPlan(P.preparationReview public))==planBytes)
      invalidateLivePreparation live "discarded">>=right
      await(awaitAdmissionCleanup live)>>=right
      nativePresent native context >>=check "native privacy fixture joins original worker" . not
      number store "SELECT count(*) FROM invalidations WHERE kind='run.changed'" >>=check "pre-start cleanup emits no false run invalidation" . (==0)

supervisionChecks :: FilePath -> FilePath -> IO ()
supervisionChecks work native=withReady work native "supervision-stop" ["--scripted"] [] $ \fixture@(Fixture _ _ store proof key _)->withPrepared fixture fixedClock $ \_ live context reviewed public->do
  (receipt,accepted)<-acceptApproval reviewed proof(key "supervision_start")(condition public)(approvalBody public)>>=right
  owned<-maybe(error "missing original supervision owner")pure accepted
  before<-texts store "SELECT revision FROM runs"
  deliverAcceptedStart owned>>=right
  let running=observeAcceptedStart owned >>= \state->unless(observedWorkerPhase state==WorkerRunning)(threadDelay 1000>>running)
  await running
  stopAcceptedStart owned>>=right
  await(awaitAdmissionCleanup live)>>=right
  after<-texts store "SELECT revision FROM runs"
  check "original stop changes run revision with supervision" (before/=after)
  number store "SELECT count(*) FROM invalidations WHERE kind='run.changed' AND resource_uri NOT LIKE '%/control'" >>=check "original stop publishes both run supervision invalidations" . (==3)
  number store "SELECT count(*) FROM invalidations WHERE kind='run.changed' AND resource_uri LIKE '%/control'" >>=check "original stop separately invalidates live control availability" . (==2)
  (replay,_)<-acceptApproval reviewed proof(key "supervision_start")(condition public)(approvalBody public)>>=right
  check "versioned supervision preserves immutable original receipt" (submissionReceipt receipt==submissionReceipt replay)
  checkRunEvents store
  nativePresent native context >>=check "versioned supervision release follows original cleanup" . not

texts :: CoordinationStore -> Text -> IO [Text]
texts store sql=runRead store $ do
  rows<-query sql []
  mapM (\row->case row of [SQL.SQLText value]->pure value;_->refuseTransaction StoreIntegrity)rows

captureApprovalChecks :: FilePath -> FilePath -> IO ()
captureApprovalChecks work native=withReady work native "capture-approval" ["--scripted"] [] $ \(Fixture root configuration store proof key ready)->do
  let bytes=TE.encodeUtf8 "Captured consent: café λ.\nSecond line.\n"
  chunks<-newTVarIO [BS.take 19 bytes,BS.drop 19 bytes,BS.empty]
  let readChunk=atomically $ do values<-readTVar chunks;case values of []->pure BS.empty;x:xs->writeTVar chunks xs>>pure x
  captured<-uploadCapture store proof(draftId ready)(key "capture")(fromIntegral(BS.length bytes))readChunk>>=right
  _<-changeDraftInput store proof(draftId ready)(key "linkcap")(Just("\""<>draftRevision ready<>"\""))(encoded(object["operation" .= ("set-input"::Text),"input" .= CapturedValue "input" (captureId captured)]))>>=right
  linked<-readDraft store proof(draftId ready)>>=right
  withPrepared (Fixture root configuration store proof key linked) fixedClock $ \_ live context reviewed public->do
    let checksum=T.pack(show(hash bytes::Digest SHA256))
        expected=P.ReviewInput "input" "capture" (T.pack(show(BS.length bytes)))checksum
    check "capture receipt describes exact UTF-8 and newline bytes" (captureBytes captured==fromIntegral(BS.length bytes) && captureDigest captured==checksum)
    check "capture-backed public and retained summaries agree" (P.reviewInputs(P.preparationReview public)==[expected] && reviewInputSummaries context==[expected])
    check "actual native preparation hashes the same captured bytes" (preparedInputs(reviewNative context)==[FrontendPreparedInput "input" (fromIntegral(BS.length bytes))checksum])
    check "captured material keeps original trusted invocation" (preparedInvocation(reviewNative context)==Just(selectionInvocation(reviewSelection context)))
    binding<-runRead store $ do rows<-query "SELECT private_binding FROM preparations" [];case rows of [[SQL.SQLBlob value]]->pure value;_->refuseTransaction StoreIntegrity
    bound<-right(eitherDecodeStrict' binding::Either String Value)
    check "private binding retains that original native invocation" (case bound of Object fields->KM.lookup "invocation" fields==Just(toJSON(preparedInvocation(reviewNative context)));_->False)
    number store "SELECT count(*) FROM preparation_captures JOIN captures ON captures.id=preparation_captures.capture_id" >>=check "public capture summary retains actual immutable capture association" . (==1)
    check "public captured review omits private capture paths" (not(TE.encodeUtf8(T.pack(root </> "captures")) `BS.isInfixOf` encoded public))
    BS.writeFile(work </> "public-preparation-capture.json")(encoded public)
    (receipt,start)<-acceptApproval reviewed proof(key "capstart")(condition public)(approvalBody public)>>=right
    owned<-maybe(error "missing captured original start")pure start
    deliverAcceptedStart owned>>=right
    let running=observeAcceptedStart owned >>= \state->unless(observedWorkerPhase state==WorkerRunning)(threadDelay 1000>>running)
    await running
    (replay,_)<-acceptApproval reviewed proof(key "capstart")(condition public)(approvalBody public)>>=right
    check "captured approval replay returns original receipt without new start" (submissionReceipt replay==submissionReceipt receipt && submissionReplayed replay)
    deliverAcceptedStart owned >>=check "captured original ticket is one-shot" . (==Left OwnershipUnavailable)
    stopAcceptedStart owned>>=right
    await(awaitAdmissionCleanup live)>>=right
    nativePresent native context >>=check "captured original worker cleanup is joined" . not
    (afterStop,_)<-acceptApproval reviewed proof(key "capstart")(condition public)(approvalBody public)>>=right
    check "captured receipt remains immutable after joined cleanup" (submissionReceipt afterStop==submissionReceipt receipt)

checkRunEvents :: CoordinationStore -> IO ()
checkRunEvents store=do
  current<-texts store "SELECT revision FROM runs"
  revisions<-texts store "SELECT revision FROM invalidations WHERE kind='run.changed' AND resource_uri NOT LIKE '%/control' ORDER BY length(sequence),sequence"
  resources<-texts store "SELECT resource_uri FROM invalidations WHERE kind='run.changed' AND resource_uri NOT LIKE '%/control' ORDER BY length(sequence),sequence"
  ids<-texts store "SELECT '/v1/runs/'||id FROM runs"
  check "both supervision transitions have fresh revisions and exact run invalidations" (case revisions of
    [first,middle,lastRevision]->first/=middle && middle/=lastRevision && first/=lastRevision && current==[lastRevision] && resources==concat(replicate 3 ids)
    _->False)

supervisionFaultChecks :: FilePath -> FilePath -> FilePath -> FilePath -> IO ()
supervisionFaultChecks work native source python=forM_ [False,True] $ \loss->do
  let name=if loss then "supervision-loss-fault" else "supervision-stop-fault"
      evidence=work </> name
  withReadyRunner work python [T.pack(source </> "manager/test/approval_fixture.py"),T.pack native,"exit-on-trigger",T.pack evidence] "person-controlled" (name<>"-root") ["--scripted"] [] $ \fixture@(Fixture root _ store proof key _)->withPrepared fixture fixedClock $ \_ live context reviewed public->do
    (original,accepted)<-acceptApproval reviewed proof(key "faultstart")(condition public)(approvalBody public)>>=right
    owned<-maybe(error "missing fault owner")pure accepted
    deliverAcceptedStart owned>>=right
    let running=observeAcceptedStart owned >>= \state->unless(observedWorkerPhase state==WorkerRunning)(threadDelay 1000>>running)
    await running
    let ddl statement=bracket(SQL.open(T.pack(root </> "coordination.sqlite3")))SQL.close(\db->SQL.exec db statement)
        trigger phase="CREATE TRIGGER supervision_failure BEFORE INSERT ON invalidations WHEN NEW.kind='run.changed' AND EXISTS(SELECT 1 FROM runs WHERE supervision='"<>phase<>"') BEGIN SELECT RAISE(ABORT,'supervision publication refused'); END"
        snapshot=mapM (texts store)
          ["SELECT revision||':'||supervision||':'||result_state FROM runs",
           "SELECT revision||':'||phase||':'||admission FROM requests",
           "SELECT revision||':'||state||':'||request_revision||':'||review_digest FROM preparations",
           "SELECT id||':'||hex(receipt) FROM commands WHERE operation='approve'",
           "SELECT request_revision||':'||state||':'||coalesce(CAST(slot AS TEXT),'none') FROM reservations",
           "SELECT kind||':'||resource_key FROM reservation_resources",
           "SELECT sequence||':'||kind||':'||resource_uri||':'||revision FROM invalidations ORDER BY length(sequence),sequence"]
        refusal label result=check label(case result of Left StorageUnavailable->True;_->False)
    before<-snapshot
    ddl(trigger "cleanup-pending")
    failed<-if loss then BS.writeFile(evidence<>".exit")BS.empty>>await(awaitAdmissionCleanup live) else stopAcceptedStart owned
    refusal "original cleanup-pending publication failure remains explicit" failed
    firstResult<-await(awaitAdmissionCleanup live)
    refusal "original cleanup result retains publication error" firstResult
    after<-snapshot
    check "failed cleanup-pending run publication atomically rolls back revisions events and claims" (before==after)
    nativePresent native context >>=check "physical cleanup proof stays separate from failed SQL publication" . not
    joined<-doesFileExist(evidence<>".joined")
    check "failed publication fixture joined its original child" joined
    number store "SELECT count(*) FROM reservation_resources" >>=check "failed supervision publication retains original claims" . (==1)
    ddl "DROP TRIGGER supervision_failure"
    ddl(trigger "lost")
    pendingFailure<-retryAdmissionCleanup live
    refusal "original lost publication failure remains explicit" pendingFailure
    middle<-snapshot
    phase<-texts store "SELECT supervision FROM runs"
    check "actual intermediate supervision committed despite final publication refusal" (phase==["cleanup-pending"] && middle/=before)
    revisions<-texts store "SELECT revision FROM invalidations WHERE kind='run.changed' AND resource_uri NOT LIKE '%/control' ORDER BY length(sequence),sequence"
    current<-texts store "SELECT revision FROM runs"
    check "committed intermediate run revision matches its atomic invalidation" (case revisions of [old,new]->old/=new && current==[new];_->False)
    number store "SELECT count(*) FROM reservations WHERE state='cleanup-pending' AND slot IS NOT NULL" >>=check "failed lost publication rolls back reservation release" . (==1)
    again<-retryAdmissionCleanup live
    refusal "repeated failed lost publication preserves original refusal" again
    unchanged<-snapshot
    check "failed lost publication atomically preserves run request claim and event state" (unchanged==middle)
    ddl "DROP TRIGGER supervision_failure"
    retryAdmissionCleanup live>>=right
    await(awaitAdmissionCleanup live)>>=right
    checkRunEvents store
    number store "SELECT count(*) FROM reservation_resources" >>=check "original successful cleanup publication releases retained claims" . (==0)
    phaseAfter<-texts store "SELECT supervision FROM runs WHERE runtime_snapshot IS NULL AND result_state='absent'"
    check "lost supervision never fabricates Runtime result" (phaseAfter==["lost"])
    complete<-snapshot
    _<-retryAdmissionCleanup live
    repeated<-snapshot
    check "repeated original cleanup cannot duplicate a run transition" (complete==repeated)
    (replay,_)<-acceptApproval reviewed proof(key "faultstart")(condition public)(approvalBody public)>>=right
    check "publication failures never rewrite original accepted consent" (submissionReceipt replay==submissionReceipt original)

containsText :: Text -> Value -> Bool
containsText content (String value)=content `T.isInfixOf` value
containsText content (Object value)=any(containsText content)value
containsText content (Array value)=any(containsText content)value
containsText _ _=False

storeCancellationChecks :: FilePath -> FilePath -> IO ()
storeCancellationChecks work native = forM_ [False,True] $ \masked -> forM_ [False,True] $ \expiry ->
  withReady work native ("store-gap-"<>show masked<>show expiry) ["--scripted"] [] $ \(Fixture _ _ store _ _ _) ->
    Audit.withReviewAudit "store-step" $ \audit -> do
      before <- storeRows store "SELECT * FROM invalidations"
      let transaction = runTransaction store $ do
            execute "INSERT INTO clients VALUES ('cancel-gap','revision','authority',0)" []
            _ <- query "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<1000000000000) SELECT sum(x) FROM n" []
            pure ((),[Invalidation "service.changed" "/v1/capabilities" "cancel-gap"])
          action = if masked then mask_ transaction else transaction
          rescue original = do
            Audit.releaseReviewed audit
            let loop = poll original >>= \status -> case status of
                  Just _ -> pure ()
                  Nothing -> Audit.rescueSql >> threadDelay 1000 >> loop
            await loop
      bracket (async action) rescue $ \original -> do
        _ <- Audit.waitReviewed audit
        bracket (async (unless expiry (throwTo (asyncThreadId original) UserInterrupt))) cancel $ \sender -> do
          -- The original caller is now joining cancellation after its interrupt.
          await $ let blocked = threadStatus (asyncThreadId original) >>= \status ->
                        unless (status==ThreadBlocked BlockedOnException) (threadDelay 1000 >> blocked)
                  in blocked
          Audit.releaseReviewed audit
          completed <- timeout 1000000 (waitCatch original)
          rescue original
          void (wait sender)
          check ("missed SQL interrupt joins original action "<>show (masked,expiry)) (case completed of
            Just (Left failure) -> if expiry then fromException failure==Just StoreDeadline else fromException failure==Just UserInterrupt
            _ -> False)
      number store "SELECT count(*) FROM clients WHERE id='cancel-gap'" >>= check "cancelled transaction rolls back prior mutation" . (==0)
      storeRows store "SELECT * FROM invalidations" >>= check "cancelled transaction publishes no invalidations" . (==before)
      forM_ [1::Int ..100] $ \_ -> do
        _ <- storeIdentity store
        number store "SELECT count(*) FROM clients" >>= check "joined interrupter cannot contaminate same-connection reuse" . (==1)
      runTransaction store $ do
        execute "INSERT INTO clients VALUES ('after-cancel','revision','authority',0)" []
        pure ((),[Invalidation "service.changed" "/v1/capabilities" "after-cancel"])
      number store "SELECT count(*) FROM clients WHERE id='after-cancel'" >>= check "rollback restores autocommit for subsequent real commit" . (==1)

associationCleanupChecks :: FilePath -> FilePath -> IO ()
associationCleanupChecks work native = withReadyRunner work native [] "prompt-source" "association-cleanup" ["--scripted"] [] $ \fixture@(Fixture root _ store proof key _) ->
  withPrepared fixture fixedClock $ \_ live context reviewed public -> do
    (_,start) <- acceptApproval reviewed proof (key "cleanup-associate") (condition public) (approvalBody public) >>= right
    owned <- maybe (error "missing cleanup association owner") pure start
    let ddl sql = bracket (SQL.open (T.pack (root </> "coordination.sqlite3"))) SQL.close (\db -> SQL.exec db sql)
        facts = mapM (storeRows store) ["SELECT * FROM requests", "SELECT * FROM reservations", "SELECT * FROM runs", "SELECT * FROM ingestions", "SELECT * FROM invalidations"]
    immutable <- mapM (storeRows store) ["SELECT * FROM start_intents", "SELECT * FROM preparations", "SELECT id,receipt FROM commands"]
    ddl "CREATE TRIGGER association_cleanup_fault BEFORE INSERT ON invalidations WHEN NEW.kind='run.changed' AND EXISTS(SELECT 1 FROM runs WHERE supervision='lost') BEGIN SELECT RAISE(ABORT,'fixture final cleanup publication fault'); END"
    deliverAcceptedStart owned >>= right
    failed <- await (awaitAdmissionCleanup live)
    check "original final cleanup publication failure remains explicit" (failed==Left StorageUnavailable)
    nativePresent native context >>= check "original physical cleanup completes despite final SQL failure" . not
    texts store "SELECT state FROM reservations" >>= check "failed final publication retains cleanup-pending reservation" . (==["cleanup-pending"])
    texts store "SELECT phase FROM requests" >>= check "cleanup-pending request still awaits first Runtime evidence" . (==["start-pending"])
    before <- facts
    ddl "CREATE TRIGGER association_ingestion_fault BEFORE INSERT ON invalidations WHEN NEW.kind='request.changed' BEGIN SELECT RAISE(ABORT,'fixture association publication fault'); END"
    refused <- try @StoreFailure (ingestAcceptedStart owned)
    check "first evidence association publication refusal explicit during pending cleanup" (case refused of Left _ -> True; _ -> False)
    facts >>= check "pending cleanup association failure rolls back entire publication" . (==before)
    ddl "DROP TRIGGER association_ingestion_fault"
    ingestAcceptedStart owned >>= check "first retained evidence associates despite pending final cleanup publication"
    texts store "SELECT phase FROM requests" >>= check "cleanup-pending does not block associated phase" . (==["associated"])
    number store "SELECT count(*) FROM requests r JOIN reservations v ON v.request_id=r.id WHERE r.revision=v.request_revision" >>= check "pending cleanup reservation follows association revision atomically" . (==1)
    ddl "DROP TRIGGER association_cleanup_fault"
    retryAdmissionCleanup live >>= right
    texts store "SELECT state FROM reservations" >>= check "original finalization retry accepts exact association successor" . (==["released"])
    texts store "SELECT phase FROM requests" >>= check "original finalization retains associated phase" . (==["associated"])
    number store "SELECT count(*) FROM reservation_resources" >>= check "original finalization releases claims" . (==0)
    after <- facts
    duplicate <- retryAdmissionCleanup live
    check "completed cleanup cannot be finalized twice" (duplicate==Left StateConflict)
    facts >>= check "duplicate original cleanup retry publishes no changes" . (==after)
    mapM (storeRows store) ["SELECT * FROM start_intents", "SELECT * FROM preparations", "SELECT id,receipt FROM commands"] >>= check "association cleanup retry preserves receipt intent and preparation facts" . (==immutable)
    let drain = ingestAcceptedStart owned >>= \more -> when more drain
    await drain

-- Real approval/start/cleanup precedes ingestion. Buffered evidence is not live authority.
nativeIngestionChecks :: FilePath -> FilePath -> IO ()
nativeIngestionChecks work native = checkReopenedIngestion work $ withReadyRunner work native [] "prompt-source" "native-ingestion" ["--scripted"] [] $ \fixture@(Fixture root _ store proof key _) ->
  withPrepared fixture fixedClock $ \_ live context reviewed public -> do
    (approved,start) <- acceptApproval reviewed proof (key "approve") (condition public) (approvalBody public) >>= right
    owned <- maybe (error "missing original accepted start") pure start
    let association = RunAssociation (acceptedStartRun owned) "profile" (preparedRootIdentity (reviewNative context)) (preparedRunId (reviewNative context))
    restoreRunProjection store association >>= check "accepted intent has no fabricated Runtime snapshot" . (==Nothing)
    observeRetainedTerminal store association >>= check "missing native prefix provides no terminal retention proof" . not
    texts store "SELECT phase FROM requests" >>= check "genuine approval remains start-pending before Runtime evidence" . (==["start-pending"])
    immutable <- storeRows store "SELECT * FROM start_intents"
    deliverAcceptedStart owned >>= right
    await (awaitAdmissionCleanup live) >>= right
    stopped <- observeAcceptedStart owned
    check "genuine fast native run physically cleaned before ingestion starts" (observedWorkerPhase stopped==WorkerReleased && observedQueuedFrames stopped>0 && not (observedCleanupUnproven stopped))
    void(retainReceipts store "" >>= right)
    number store "SELECT terminal_observed FROM runs" >>= check "physical cleanup cannot supply retention terminal evidence" . (==0)
    number store "SELECT count(*) FROM commands WHERE inactive_since IS NOT NULL" >>= check "unobserved terminal result leaves original receipts protected" . (==0)
    forbidden <- deliverAcceptedStart owned
    check "closed original accepted start cannot acquire execution again" (case forbidden of Left _ -> True; _ -> False)
    let associationFacts = mapM (storeRows store)
          ["SELECT * FROM requests", "SELECT * FROM reservations", "SELECT * FROM runs", "SELECT * FROM invalidations", "SELECT * FROM start_intents", "SELECT * FROM preparations", "SELECT * FROM commands"]
    beforeFailure <- associationFacts
    let expectUncommitted label action = do
          result <- try @StoreFailure action
          after <- observeAcceptedStart owned
          number store "SELECT count(*) FROM ingestions" >>= check (label<>" rollback has no dedup identity") . (==0)
          texts store "SELECT phase FROM requests" >>= check (label<>" rolls back request association") . (==["start-pending"])
          associationFacts >>= check (label<>" atomically preserves revisions reservations consent and invalidations") . (==beforeFailure)
          check (label<>" retains exact queued input") (case result of Left _ -> observedQueuedFrames after==observedQueuedFrames stopped; _ -> False)
    bracket (SQL.open (T.pack (root </> "coordination.sqlite3"))) SQL.close $ \db -> do
      SQL.exec db "CREATE TRIGGER ingestion_fault BEFORE INSERT ON invalidations WHEN NEW.kind='run.changed' BEGIN SELECT RAISE(ABORT,'fixture ingestion commit fault'); END"
      expectUncommitted "durable invalidation failure" (ingestAcceptedStart owned)
      SQL.exec db "DROP TRIGGER ingestion_fault"
      SQL.exec db "BEGIN IMMEDIATE"
      expectUncommitted "busy durable writer" (ingestAcceptedStart owned)
      SQL.exec db "ROLLBACK"
    let occupy = do
          result <- try @StoreFailure $ runRead store $ do
            _ <- query "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<1000000000000) SELECT sum(x) FROM n" []
            pure ()
          case result of
            Left StoreBusy -> threadDelay 1000 >> occupy
            _ -> either throwIO pure result
    bracket (async occupy) cancel $ \writer -> do
      let waitBusy = try @StoreFailure (storeIdentity store) >>= \result -> case result of
            Left StoreBusy -> pure ()
            _ -> do
              ended <- poll writer
              case ended of
                Just outcome -> either throwIO (const (error "fixture writer completed before busy rendezvous")) outcome
                Nothing -> threadDelay 1000 >> waitBusy
      await waitBusy
      busy <- try @StoreFailure (ingestAcceptedStart owned)
      check "overlapping Store transaction refuses ingestion as StoreBusy" (busy==Left StoreBusy)
    number store "SELECT count(*) FROM ingestions" >>= check "busy Store admission cannot acknowledge queued input" . (==0)
    entered <- newEmptyMVar
    hold <- newEmptyMVar @()
    retained <- newIORef Nothing
    reader <- async $ consumeAcceptedStart owned $ \_ _ _ event -> do
      modifyIORef' retained (const (Just (workerEventBytes event)))
      putMVar entered ()
      takeMVar hold
    await (takeMVar entered)
    observer <- async $ forM_ [1::Int ..1000] $ \_ -> do
      observed <- observeAcceptedStart owned
      unless (observedQueuedFrames observed==observedQueuedFrames stopped) (error "observer consumed ingestion input")
    await (wait observer)
    competing <- try @WorkerFailure (ingestAcceptedStart owned)
    check "callback holds sole consumer across slow durable boundary" (competing==Left WorkerConsumerBusy)
    cancel reader
    void (waitCatch reader)
    afterCancel <- observeAcceptedStart owned
    check "cancelled callback after cleanup retains queue head and byte charge" (observedQueuedFrames afterCancel==observedQueuedFrames stopped && observedQueuedBytes afterCancel==observedQueuedBytes stopped)
    committed <- try @AsyncException $ consumeAcceptedStart owned $ \_ _ _ event -> do
      first <- readIORef retained
      check "callback retry receives identical original wire" (first==Just (workerEventBytes event))
      void (ingestRuntimeEnvelope store association (workerEventBytes event))
      throwIO UserInterrupt
    check "commit then callback failure remains explicit" (committed==Left UserInterrupt)
    number store "SELECT count(*) FROM ingestions" >>= check "commit-return window contains exactly one durable envelope" . (==1)
    texts store "SELECT phase FROM requests" >>= check "first committed Runtime evidence associates managed request" . (==["associated"])
    observeRetainedTerminal store association >>= check "nonterminal validated prefix cannot supply terminal retention proof" . not
    number store "SELECT count(*) FROM requests r JOIN reservations v ON v.request_id=r.id WHERE r.revision=v.request_revision" >>= check "association keeps reservation revision consistent after cleanup" . (==1)
    number store "SELECT count(*) FROM requests r JOIN invalidations i ON i.resource_uri='/v1/requests/'||r.id AND i.revision=r.revision WHERE i.kind='request.changed'" >>= check "association publishes matching request invalidation" . (==1)
    storeRows store "SELECT * FROM start_intents" >>= check "association preserves immutable original consent" . (==immutable)
    requestBeforeReplay <- storeRows store "SELECT * FROM requests"
    beforeReplay <- number store "SELECT count(*) FROM invalidations"
    ingestAcceptedStart owned >>= check "original queue retry acknowledges matching committed duplicate"
    number store "SELECT count(*) FROM invalidations" >>= check "commit-return duplicate window creates no invalidation" . (==beforeReplay)
    storeRows store "SELECT * FROM requests" >>= check "duplicate does not transition or repair request" . (==requestBeforeReplay)
    first <- readIORef retained >>= maybe (error "missing first wire") pure
    firstEnvelope <- right (Runtime.decodeEnvelopeFor Runtime.supportedProtocolVersions first)
    envelopes <- newIORef [firstEnvelope]
    let drain = consumeAcceptedStart owned (\_ _ _ event -> do
          void (ingestRuntimeEnvelope store association (workerEventBytes event))
          modifyIORef' envelopes (<>[workerEventEnvelope event])) >>= \more -> when more drain
    await drain
    actual <- readIORef envelopes
    direct <- right (foldM Runtime.stepRunSnapshot (Runtime.initialRunSnapshot (associationNative association)) actual)
    restored <- restoreRunProjection store association >>= maybe (error "missing native projection") pure
    check "genuine approved native completion equals unchanged direct fold" (Runtime.checkpointSnapshot restored==direct && Runtime.checkpointEnvelopes restored==actual && Runtime.snapshotRunStatus direct==Runtime.RunSucceeded && Runtime.snapshotTraceRecorded direct && Runtime.snapshotResult direct/=Nothing)
    number store "SELECT terminal_observed FROM runs" >>= check "shared Runtime terminal fold publishes retention evidence atomically" . (==1)
    boundary <- runRead store $ do
      rows <- query "SELECT runtime_snapshot FROM runs" []
      case rows of [[SQL.SQLBlob bytes]] -> pure bytes; _ -> refuseTransaction StoreIntegrity
    let replaceBoundary bytes = runTransaction store $ do
          execute "UPDATE runs SET runtime_snapshot=?,terminal_observed=0" [SQL.SQLBlob bytes]
          pure((),[Invalidation "service.changed" "/v1/capabilities" "retention_fixture"])
    forM_ [("corrupt", "not-a-boundary"),("changed",boundary<>" ")] $ \(label,bytes) -> do
      replaceBoundary bytes
      refusal <- try @StoreFailure(observeRetainedTerminal store association)
      check (label<>" stored boundary cannot mint historical terminal proof") (refusal==Left StoreIntegrity)
      number store "SELECT terminal_observed FROM runs" >>= check "failed historical proof preserves absence of authority" . (==0)
    replaceBoundary boundary
    observeRetainedTerminal store association >>= check "explicit historical observation validates original complete Runtime prefix"
    beforeProofDuplicate <- number store "SELECT count(*) FROM invalidations"
    observeRetainedTerminal store association >>= check "repeated terminal proof is a no-op" . not
    number store "SELECT count(*) FROM invalidations" >>= check "repeated proof appends no event" . (==beforeProofDuplicate)
    number store "SELECT count(*) FROM commands WHERE inactive_since IS NOT NULL" >>= check "historical proof requires a new inactivity interval" . (==0)
    void(retainReceipts store "" >>= right)
    storeRows store "SELECT id,state FROM commands WHERE operation='approve'" >>= check "original approval remains dispatch-attempted despite terminal run" . (==show [[SQL.SQLText(receiptId(submissionReceipt approved)),SQL.SQLText "dispatch-attempted"]])
    number store "SELECT count(*) FROM commands WHERE inactive_since IS NOT NULL OR retired=1" >>= check "pending original approval protects every linked receipt despite terminal evidence" . (==0)
    number store "SELECT count(*) FROM artifacts WHERE verification='referenced'" >>= check "native result observed as reference, never verified content" . (>0)
    number store "SELECT count(*) FROM runs WHERE result_state='referenced' AND runtime_snapshot IS NOT NULL" >>= check "native result and projection commit together" . (==1)
    remaining <- observeAcceptedStart owned
    check "finished producer drains every retained envelope exactly once" (observedQueuedFrames remaining==0 && observedQueuedBytes remaining==0 && length actual==observedQueuedFrames stopped)
    pure (association,restored,first)

checkReopenedIngestion :: FilePath -> IO (RunAssociation,Runtime.SnapshotCheckpoint,BS.ByteString) -> IO ()
checkReopenedIngestion work action = do
  (association,expected,wire) <- action
  let registry=Cli.Registry "approval-check" "workflow" "approval fixture" []
      validate requested=either (const (Left InvalidConfiguration)) Right (Cli.validateManagerTarget registry requested)
      validatePrepared requested prepared=either (const (Left InvalidReply)) Right (Cli.validateManagerPreparedTarget registry requested prepared)
  configuration <- loadConfiguration validate validatePrepared (const False) (work </> "native-ingestion.json") >>= right
  bracket (installConfiguration configuration >>= right) closeConfiguration $ \installed -> withCoordinationStore installed $ \store -> do
    restored <- restoreRunProjection store association
    check "fresh Store lifetime restores exact complete native checkpoint" (restored==Just expected)
    before <- number store "SELECT count(*) FROM invalidations"
    ingestRuntimeEnvelope store association wire >>= check "matching original native wire remains duplicate after reopen" . not
    number store "SELECT count(*) FROM invalidations" >>= check "reopened duplicate does not advance manager commit sequence" . (==before)
    number store "SELECT count(*) FROM start_intents" >>= check "projection restoration reconstructs no start authority or new intent" . (==1)

-- Explicit observation retry retains the same original head. It never resends a control.
observeControl :: IO a -> IO a
observeControl action = await (loop True)
  where
    loop first = do
      result <- try @StoreFailure action
      case result of
        Left failure -> do
          when (first || failure/=StoreBusy) (noteControlFailure ("control observation: "<>show failure))
          case failure of
            StoreBusy -> threadDelay 1000 >> loop False
            _ -> throwIO failure
        Right value -> pure value

noteControlFailure :: String -> IO ()
noteControlFailure message = void (try @IOException (hPutStrLn stderr message))

readControlReceipt :: CoordinationStore -> CredentialProof -> Text -> IO (Either CommandFailure CommandReceipt)
readControlReceipt store proof ident =
  readCommand store proof ident >>= noteControlResult "control receipt"

noteControlResult :: String -> Either CommandFailure a -> IO (Either CommandFailure a)
noteControlResult source result = do
  case result of
    Left failure -> noteControlFailure (source<>" public refusal (cause opaque): "<>show failure)
    Right _ -> pure ()
  pure result

controlNumber :: CoordinationStore -> Text -> IO Int64
controlNumber store = observeControl . number store

controlEffectRecorded :: Text -> Transaction Bool
controlEffectRecorded command = do
  rows <- query "SELECT effect_evidence FROM commands WHERE id=?" [SQL.SQLText command]
  case rows of
    [[SQL.SQLNull]] -> pure False
    [[SQL.SQLBlob _]] -> pure True
    _ -> refuseTransaction StoreIntegrity

checkAnsweredControlReceipt :: CoordinationStore -> CredentialProof -> CommandReceipt -> Text -> Text -> IO ()
checkAnsweredControlReceipt store proof original occurrence run = do
  receipt <- readControlReceipt store proof(receiptId original) >>= right
  check "post-cleanup answer receipt retains original acceptance binding"
    (binding receipt==binding original && receiptOperation receipt==Answer && receiptState receipt==EffectObserved && receiptAttemptedAt receipt/=Nothing && receiptRefusal receipt==Nothing)
  check "post-cleanup answer acknowledgement correlates original delivered command"
    (maybe False (\ack -> let value=acknowledgementValue ack in
      field "commandId" value==Just(String(receiptId original)) && field "command" value==Just(String "answer") &&
      field "state" value==Just(String "delivered") && field "occurrenceId" value==Just(String occurrence)) (receiptAcknowledgement receipt))
  check "post-cleanup answer effect retains original occurrence and run resource"
    (maybe False (\effect -> let value=effectValue effect in
      field "kind" value==Just(String "answer-accepted") && field "resource" value==Just(String("/v1/runs/"<>run<>"/control")) &&
      (field "address" value >>= field "occurrenceId")==Just(String occurrence)) (receiptEffect receipt))
  where
    binding receipt=(receiptId receipt,receiptProfile receipt,receiptOperation receipt,receiptResource receipt,receiptAcceptedAt receipt)
    field name (Object fields)=KM.lookup name fields
    field _ _=Nothing

receiptObservationChecks :: FilePath -> FilePath -> IO ()
receiptObservationChecks work native = withReady work native "receipt-observation" ["--scripted"] [] $ \(Fixture _ _ store proof key _) -> do
  command <- runRead store $ do
    rows <- query "SELECT id FROM commands WHERE idempotency_key=?" [SQL.SQLText(key "input")]
    case rows of [[SQL.SQLText ident]] -> pure ident; _ -> refuseTransaction StoreIntegrity
  publicCalls <- newIORef (0::Int)
  typedCalls <- newIORef (0::Int)
  completedReads <- newIORef (0::Int)
  held <- newEmptyMVar
  resume <- newEmptyMVar
  let clock = putMVar held () >> readMVar resume >> pure 0
      release = void(tryPutMVar resume ())
  -- Same held-Store rendezvous as StoreCheck.terminalAdmissionChecks.
  withCommitDeadline store clock 1 $ \guard ->
    bracket (async(runTransaction store (enforceCommitDeadline guard >> pure((),[]))))
      (\holder -> release >> cancel holder) $ \holder -> do
        timeout 1000000(takeMVar held) >>= maybe(error "Store holder not admitted")pure
        modifyIORef' publicCalls (+1)
        refused <- readControlReceipt store proof command
        calls <- readIORef publicCalls
        check "public receipt under held Store returns opaque refusal once" (refused==Left StorageUnavailable && calls==1)
        let typedRead = do
              modifyIORef' typedCalls (+1)
              result <- try @StoreFailure (runRead store (controlEffectRecorded command))
              case result of
                Left StoreBusy -> do
                  completed <- readIORef completedReads
                  check "typed receipt observation refuses before query completion" (completed==0)
                  release
                  wait holder
                  throwIO StoreBusy
                Left failure -> throwIO failure
                Right value -> modifyIORef' completedReads (+1) >> pure value
        recorded <- observeControl typedRead
        attempts <- readIORef typedCalls
        completed <- readIORef completedReads
        check "released typed observation executes one admitted read without replay" (recorded && attempts==2 && completed==1)
  receipt <- readControlReceipt store proof command >>= right
  check "released public receipt retains original command" (receiptId receipt==command && receiptEffect receipt/=Nothing)
  absent <- try @StoreFailure (runRead store (controlEffectRecorded "missing_receipt"))
  check "typed receipt predicate requires exactly one matching row" (absent==Left StoreIntegrity)
  forM_ [StoreClosed,StorePoisoned,StoreLimit,StoreDeadline,StoreVersion,StoreIntegrity,StoreUnavailable,StoreCleanupUnproven] $ \failure -> do
    calls <- newIORef (0::Int)
    outcome <- try @StoreFailure (observeControl (modifyIORef' calls (+1) >> throwIO failure :: IO ()))
    attempts <- readIORef calls
    check ("non-busy observation failure propagates once: "<>show failure) (outcome==Left failure && attempts==1)
  sqlCalls <- newIORef (0::Int)
  sqlFailure <- try @StoreFailure $ observeControl $ do
    modifyIORef' sqlCalls (+1)
    runRead store (void (query "SELECT missing_receipt_observation_column FROM commands" []))
  sqlAttempts <- readIORef sqlCalls
  check "SQL StoreUnavailable propagates once without replay" (sqlFailure==Left StoreUnavailable && sqlAttempts==1)
  opaqueCalls <- newIORef (0::Int)
  opaque <- observeControl (modifyIORef' opaqueCalls (+1) >> pure(Left StorageUnavailable :: Either CommandFailure ()))
  opaqueAttempts <- readIORef opaqueCalls
  check "returned opaque observation refusal propagates once" (opaque==Left StorageUnavailable && opaqueAttempts==1)

nativeControlReloadChecks :: Bool -> FilePath -> FilePath -> IO ()
nativeControlReloadChecks racing work native = withReady work native "reload-control" ["--scripted"] [] $ \fixture@(Fixture _ installed store proof key _) ->
  withPrepared fixture fixedClock $ \_ live context reviewed public -> do
    (_,start)<-acceptApproval reviewed proof(key "approve-reload")(condition public)(approvalBody public) >>=right
    owned<-maybe(error "missing reload owner")pure start
    deliverAcceptedStart owned >>=right
    let pending=observeControl $ runRead store $ do
          rows<-query "SELECT id,occurrence_id,generation,revision FROM decisions WHERE state='pending'" []
          pure[(i,o,g,r)|[SQL.SQLText i,SQL.SQLText o,SQL.SQLText g,SQL.SQLText r]<-rows]
        ingestUntil predicate=await loop
          where loop=do done<-predicate;unless done(observeControl (ingestAcceptedStart owned)>>loop)
        registry=Cli.Registry "approval-check" "workflow" "approval fixture" []
        validate args=either(const(Left InvalidConfiguration))Right(Cli.validateManagerTarget registry args)
        prepared args value=either(const(Left InvalidReply))Right(Cli.validateManagerPreparedTarget registry args value)
        load path=loadConfiguration validate prepared(const False)path >>=right
    original<-load(work </> "reload-control.json")
    ingestUntil(not . null <$> pending)
    (decision,occurrence,generation,revision)<-pending >>= \rows->case rows of [row]->pure row;_->error "missing reload decision"
    let body=encoded(object["operation" .= ("answer"::Text),"occurrenceId" .= occurrence,"generation" .= generation,"value" .= False])
        etag=Just("\""<>revision<>"\"")
    when racing $ Audit.withReviewAudit "control-authorization" $ \audit ->
      bracket(async(submitDecisionControl owned proof decision(key "racing-reload")etag body)) (\job->cancel job>>void(waitCatch job)) $ \job -> do
        _<-Audit.waitReviewed audit
        _<-reloadConfiguration installed original >>=right
        Audit.releaseReviewed audit
        outcome<-await(wait job)
        check "profile reload racing control acceptance cannot authorize write" (case outcome of Left StaleRevision->True;_->False)
        controlNumber store "SELECT count(*) FROM control_intents" >>=check "racing reload creates no control or native write" . (==0)
    _<-reloadConfiguration installed original >>=right
    observed<-observeAcceptedStart owned
    check "actual reload retains original approved worker and captured person mode" (observedWorkerPhase observed==WorkerRunning && preparedPersonAnswering(reviewNative context)==Runtime.PersonAnswerLocalControl)
    mutate store(execute "DELETE FROM credential_scopes WHERE credential_id='credential' AND scope='control'" [])
    forbidden<-submitDecisionControl owned proof decision(key "revoked-control")etag body
    check "fresh control rechecks actual revoked scope" (case forbidden of Left Forbidden->True;_->False)
    mutate store(execute "INSERT INTO credential_scopes VALUES ('credential','profile','control')" [])
    configurationValue<-BS.readFile(work </> "reload-control.json") >>=right . (eitherDecodeStrict' :: BS.ByteString -> Either String Value)
    removedValue<-case configurationValue of
      Object fields -> case KM.lookup "profiles" fields of
        Just(Array profiles) -> pure(Object(KM.insert "profiles" (Array(fmap (\value->case value of Object profile->Object(KM.insert "id" (String "replacement")profile);_->error "profile object")profiles))fields))
        _->error "missing profiles"
      _->error "configuration object"
    let removedPath=work </> "removed-control-profile.json"
    BS.writeFile removedPath(encoded removedValue)
    setFileMode removedPath 0o600
    removed<-load removedPath
    _<-reloadConfiguration installed removed >>=right
    missing<-submitDecisionControl owned proof decision(key "removed-profile")etag body
    check "removed current profile cannot control original worker" (case missing of Left Forbidden->True;_->False)
    _<-reloadConfiguration installed original >>=right
    let revokedSecret=BS.replicate 32 122
    mutate store $ do
      execute "INSERT INTO clients VALUES ('revoked-client','revision','authority',0)" []
      execute "INSERT INTO credentials VALUES ('revoked-credential','revoked-client',?,'2999-01-01T00:00:00Z',0)" [SQL.SQLBlob(convert(hash revokedSecret::Digest SHA256))]
      execute "INSERT INTO credential_scopes VALUES ('revoked-credential','profile','control')" []
    revoked<-authenticateCredential store revokedSecret >>=right
    mutate store(execute "UPDATE credentials SET revoked=1 WHERE id='revoked-credential'" [])
    denied<-submitDecisionControl owned revoked decision(key "revoked-credential")etag body
    check "revoked credential cannot submit a fresh original-worker answer" (case denied of Left Unauthenticated->True;_->False)
    accepted<-submitDecisionControl owned proof decision(key "after-reload")etag body >>=right
    _<-reloadConfiguration installed original >>=right
    replay<-submitDecisionControl owned proof decision(key "after-reload")etag body >>=right
    check "accepted control replay survives reload without changing original consent" (submissionReceipt replay==submissionReceipt accepted && submissionReplayed replay && case submissionTicket replay of Nothing->True;_->False)
    deliverAcceptedControl owned(receiptId(submissionReceipt accepted)) >>=right
    ingestUntil (observeControl (runRead store (controlEffectRecorded(receiptId(submissionReceipt accepted)))))
    preparation<-readPreparation store proof(P.preparationId public) >>=right
    check "reload and fresh answer never rewrite captured approval digest" (P.preparationDigest preparation==P.preparationDigest public)
    _<-reloadConfiguration installed original >>=right
    cancelView<-observeControl (readControlSurface owned proof)
    let revisionOf(Object fields)=case KM.lookup "revision" fields of Just(String value)->value;_->error "missing control revision"
        revisionOf _=error "missing control view"
    cancellation<-submitRunControl owned proof(key "cancel-after-reload")(Just("\""<>revisionOf cancelView<>"\""))(encoded(object["operation" .= ("cancel"::Text)])) >>=right
    deliverAcceptedControl owned(receiptId(submissionReceipt cancellation)) >>=right
    joinControlCleanup live owned
    checkAnsweredControlReceipt store proof(submissionReceipt accepted)occurrence(acceptedStartRun owned)
    nativePresent native context >>=check "reloaded control fixture joins only original native owner" . not

nativeControlWriteChecks :: FilePath -> FilePath -> IO ()
nativeControlWriteChecks work native = forM_ [False,True] $ \paused -> do
  let name=if paused then "blocked-control" else "full-control"
      barrier=work </> (name<>"-reader")
      release=BS.writeFile(barrier<>".release")BS.empty
      environment=[("AGENT_CAT_TEST_CONTROL_READ_BARRIER",T.pack barrier)|paused]
  withReadyRunner work native [] "parallel-person" name ["--scripted"] environment $ \fixture@(Fixture _ _ store proof key _) ->
    withPrepared fixture fixedClock $ \_ live context reviewed public -> flip finally release $ do
      (approval,start)<-acceptApproval reviewed proof(key "approve-write")(condition public)(approvalBody public) >>=right
      owned<-maybe(error "missing write owner")pure start
      deliverAcceptedStart owned >>=right
      let pending=observeControl $ runRead store $ do
            rows<-query "SELECT id,occurrence_id,generation,revision FROM decisions WHERE state='pending'" []
            pure[(i,o,g,r)|[SQL.SQLText i,SQL.SQLText o,SQL.SQLText g,SQL.SQLText r]<-rows]
          ingestUntil predicate=await loop
            where loop=do done<-predicate;unless done(observeControl (ingestAcceptedStart owned)>>loop)
      ingestUntil(not . null <$> pending)
      (decision,occurrence,generation,revision)<-pending >>= \rows->case rows of [row]->pure row;_->error "missing original large-answer decision"
      when paused $ do
        await $ let ready=doesFileExist(barrier<>".ready") >>= \done->unless done(threadDelay 1000>>ready) in ready
        buffered<-readFile(barrier<>".ready")
        check "original native reader paused with unchanged empty initial buffer" (buffered=="0")
      occurrenceId<-case reads(T.unpack occurrence) of [(value,"")]->pure(Runtime.OccurrenceId value);_->error "native occurrence number"
      let template ident value=Runtime.Control(Runtime.ControlId ident)(Just occurrenceId)Nothing(Runtime.AnswerPerson value)
          placeholder=T.replicate(T.length(receiptId(submissionReceipt approval)))"x"
      emptyFrame<-right(Runtime.encodeControlFor 2(template placeholder(String "")))
      let value=String(T.replicate(Runtime.maxFrameBytes-BS.length emptyFrame)"w")
          body=encoded(object["operation" .= ("answer"::Text),"occurrenceId" .= occurrence,"generation" .= generation,"value" .= value])
          etag=Just("\""<>revision<>"\"")
      submission<-submitDecisionControl owned proof decision(key "large-answer")etag body >>=right
      let command=receiptId(submissionReceipt submission)
      nativeFrame<-right(Runtime.encodeControlFor 2(template command value))
      check "original native control frame reaches unchanged maximum" (BS.length nativeFrame==Runtime.maxFrameBytes)
      Audit.withFrameAudit $ \audit -> do
        result<-bracket(async(try @WorkerFailure(deliverAcceptedControl owned command))) (\job->cancel job>>void(waitCatch job)) $ \job -> do
          Audit.waitFramePrefix audit
          when paused $ do
            ongoing<-poll job
            check "real remainder write remains incomplete after flushed prefix" (case ongoing of Nothing->True;_->False)
            controlNumber store "SELECT count(*) FROM decisions WHERE state='submitting'" >>=check "blocked original write retains reservation" . (==1)
            competing<-submitDecisionControl owned proof decision(key "blocked-second")etag body
            check "blocked write cannot authorize another answer" (case competing of Left StaleRevision->True;_->False)
          await(wait job)
        (size,prefix,stage,digest,sameHandle)<-Audit.frameSummary audit
        check "split uses exact original frame plus one LF and original Handle" (size==BS.length nativeFrame+1 && prefix>0 && prefix<size && sameHandle && digest==T.pack(show(hash(nativeFrame<>"\n")::Digest SHA256)))
        if paused then do
          check "original five-second deadline fails in real remainder write" (stage==3 && case result of Left WorkerWriteTimeout->True;_->False)
          controlNumber store "SELECT count(*) FROM decisions WHERE state='submitting'" >>=check "write timeout alone never releases decision" . (==1)
        else check "unpaused identical maximum frame completes original write" (stage==4 && case result of Right(Right())->True;_->False)
      release
      if paused then do
        joinControlCleanup live owned
        ticket<-maybe(error "missing original timed-out ticket")pure(submissionTicket submission)
        _<-recordUnresolved ticket >>=right
        receipt<-readControlReceipt store proof command >>=right
        check "actual partial-write outcome remains unresolved without a native acknowledgement" (receiptState receipt==Unresolved && receiptAcknowledgement receipt==Nothing && receiptEffect receipt==Nothing)
      else do
        ingestUntil (observeControl (runRead store (controlEffectRecorded command)))
        joinControlCleanup live owned
        checkAnsweredControlReceipt store proof(submissionReceipt submission)occurrence(acceptedStartRun owned)
      replay<-submitDecisionControl owned proof decision(key "large-answer")etag body >>=right
      check "lost ownership exact replay returns no payload or ticket" (submissionReplayed replay && submissionReceipt replay==submissionReceipt submission && case submissionTicket replay of Nothing->True;_->False)
      repeated<-deliverAcceptedControl owned command
      check "maximum-frame control cannot be replayed after original owner loss" (case repeated of Left OwnershipUnavailable->True;_->False)
      nativePresent native context >>=check "maximum-frame fixtures join original native owners" . not

nativeControlInterruptionChecks :: FilePath -> FilePath -> IO ()
nativeControlInterruptionChecks work native = forM_ [False,True] $ \afterWrite ->
  withReady work native (if afterWrite then "control-return" else "control-commit") ["--scripted"] [] $ \fixture@(Fixture _ _ store proof key _) ->
    withPrepared fixture fixedClock $ \_ live context reviewed public -> do
      (_,start)<-acceptApproval reviewed proof(key "approve-control")(condition public)(approvalBody public) >>=right
      owned<-maybe(error "missing interrupted control owner")pure start
      deliverAcceptedStart owned >>=right
      let pending=observeControl $ runRead store $ do
            rows<-query "SELECT id,occurrence_id,generation,revision FROM decisions WHERE state='pending'" []
            pure[(i,o,g,r)|[SQL.SQLText i,SQL.SQLText o,SQL.SQLText g,SQL.SQLText r]<-rows]
          ingestUntil predicate=await loop
            where loop=do done<-predicate;unless done(observeControl (ingestAcceptedStart owned)>>loop)
      ingestUntil(not . null <$> pending)
      (decision,occurrence,generation,revision)<-pending >>= \rows->case rows of [row]->pure row;_->error "missing interrupted decision"
      let body=encoded(object["operation" .= ("answer"::Text),"occurrenceId" .= occurrence,"generation" .= generation,"value" .= False])
          etag=Just("\""<>revision<>"\"")
          submit=submitDecisionControl owned proof decision(key "interrupted-answer")etag body
          auditScope=if afterWrite then Audit.withDeliveryAudit else Audit.withAcceptanceAudit
      original<-auditScope $ \audit -> do
        (command,acceptance)<-if afterWrite then do
          accepted<-submit >>=right
          let command=receiptId(submissionReceipt accepted)
          bracket(async(try @AsyncException(deliverAcceptedControl owned command))) (\job->cancel job>>void(waitCatch job)) $ \job -> do
            (thread,actual)<-Audit.waitReturned audit
            check "write-return audit names original control" (actual==command)
            throwTo thread UserInterrupt
            outcome<-await(wait job)
            check "original control write-return exception survives" (case outcome of Left UserInterrupt->True;_->False)
          pure(command,Just(submissionReceipt accepted))
          else do
            bracket(async(try @AsyncException submit)) (\job->cancel job>>void(waitCatch job)) $ \job -> do
              (thread,command)<-Audit.waitAccepted audit
              throwTo thread UserInterrupt
              outcome<-await(wait job)
              check "original control commit-return exception survives" (case outcome of Left UserInterrupt->True;_->False)
              (reconciled,_,sameTicket,sameAttempt)<-Audit.auditSummary audit
              check "control acceptance reconciles original ticket and payload" (reconciled>=1 && sameTicket && sameAttempt)
              pure(command,Nothing)
        replay<-submit >>=right
        check "interrupted control retry is immutable and does not mint a ticket" (submissionReplayed replay && receiptId(submissionReceipt replay)==command && maybe True (==submissionReceipt replay) acceptance && case submissionTicket replay of Nothing->True;_->False)
        unless afterWrite $ do
          delivery<-deliverAcceptedControl owned command
          check "control acceptance reconciles original ticket and payload" (case delivery of Right()->True;_->False)
        ingestUntil (observeControl (runRead store (controlEffectRecorded command)))
        (_,delivered,sameTicket,sameAttempt)<-Audit.auditSummary audit
        check "interrupted controls retain one original native write" (delivered==1 && sameTicket && sameAttempt)
        repeated<-deliverAcceptedControl owned command
        check "lost control return never authorizes another write" (case repeated of Left OwnershipUnavailable->True;_->False)
        pure(submissionReceipt replay)
      joinControlCleanup live owned
      checkAnsweredControlReceipt store proof original occurrence(acceptedStartRun owned)
      nativePresent native context >>=check "interrupted control fixture joins original native owner" . not

nativeSteeringChecks :: Bool -> Int -> FilePath -> FilePath -> FilePath -> FilePath -> IO ()
nativeSteeringChecks stale count work native source python = forM_ (if count==256 then ["next-boundary"] else ["interrupt-now","next-boundary"]) $ \timing -> do
  let base=work </> T.unpack timing
      adapters=base </> "adapters"
      launcher=adapters </> "steer-adapter"
      completion=base </> "engine-finish"
      controlBarrier=base </> "control"
      release=BS.writeFile completion BS.empty >> BS.writeFile(controlBarrier<>".release")BS.empty
  createDirectory base
  createDirectory adapters
  writeFile launcher ("#!"<>python<>"\nimport os\nos.execv("<>show python<>",["<>show python<>","<>show(source </> "engine/acp/test/steer_adapter.py")<>","<>show("--completion-barrier="<>completion)<>"])\n")
  setFileMode launcher 0o700
  let environment=[("PATH",T.pack adapters)]<>[("AGENT_CAT_TEST_CONTROL_BARRIER",T.pack controlBarrier)|stale]
  let ledger=max (64*commandCapacity) (fromIntegral(count+21)*commandCapacity)
      arguments=["--engine","acp","--adapter","steer-adapter"]<>[value|count>1,value<-["--timeout","600000"]]
  withReadyRunnerLedger ledger work native [] "parallel-person" ("steering-"<>T.unpack timing) arguments environment $ \fixture@(Fixture _ _ store proof key ready) ->
    withPrepared fixture fixedClock $ \_ live context reviewed public -> flip finally release $ do
      (_,start)<-acceptApproval reviewed proof(key "approve-steering")(condition public)(approvalBody public) >>=right
      owned<-maybe(error "missing steering original owner")pure start
      let association=RunAssociation(acceptedStartRun owned)"profile"(preparedRootIdentity(reviewNative context))(preparedRunId(reviewNative context))
          snapshot=observeControl $ restoreRunProjection store association >>=maybe(error "no steering projection")(pure . Runtime.checkpointSnapshot)
          textField fieldName (Object fields)=case KM.lookup fieldName fields of Just(String value)->value;_->error "missing steering text"
          textField _ _=error "missing steering object"
      outputSeen<-newIORef False
      let ingestOne=observeControl $ consumeAcceptedStart owned $ \current _ _ event -> do
            let output=case Runtime.envelopeEvent(workerEventEnvelope event) of Runtime.AttemptOutput {}->True;_->False
            before<-if output then Just . textField "revision" <$> observeControl (readControlSurface owned proof) else pure Nothing
            _<-ingestRuntimeEnvelope current association(workerEventBytes event)
            forM_ before $ \revision -> do
              after<-observeControl (readControlSurface owned proof)
              check "real output does not revise Runtime control availability" (textField "revision" after==revision)
              modifyIORef' outputSeen(const True)
          ingestUntil predicate=await loop
            where loop=do
                    done<-predicate
                    unless done $ do more<-ingestOne;unless more(error "steering native evidence ended early");loop
          acknowledgement command expected=do
            receipt<-readControlReceipt store proof command >>=right
            pure(maybe False ((==expected) . textField "state" . acknowledgementValue)(receiptAcknowledgement receipt))
      deliverAcceptedStart owned >>=right
      first<-ingestOne;check "steering original runtime started" first
      ingestUntil $ do
        current<-snapshot
        output<-readIORef outputSeen
        pure(output && any Runtime.snapshotOccurrencePersonPending(Map.elems(Runtime.snapshotOccurrences current)) &&
          any (any ((==Runtime.AttemptRunning) . Runtime.snapshotAttemptState) . Map.elems . Runtime.snapshotOccurrenceAttempts)(Map.elems(Runtime.snapshotOccurrences current)))
      current<-snapshot
      activeAttempt<-case [a|occurrence<-Map.elems(Runtime.snapshotOccurrences current),a<-Map.elems(Runtime.snapshotOccurrenceAttempts occurrence),Runtime.snapshotAttemptState a==Runtime.AttemptRunning] of
        [value]->pure value;_->error "missing genuine active attempt"
      check "genuine registered steerability observed" (Runtime.snapshotAttemptSteerable activeAttempt==Just True)
      let attempt=Runtime.snapshotAttemptId activeAttempt
      view<-observeControl (readControlSurface owned proof)
      BS.writeFile(work </> ("control-view-"<>T.unpack timing<>".json"))(encoded view)
      let body=encoded(object["operation" .= ("steer"::Text),"occurrenceId" .= T.pack(show(Runtime.occurrenceNumber(Runtime.attemptOccurrence attempt))),
            "attemptId" .= T.pack(show(Runtime.attemptNumber attempt)),"timing" .= timing,"text" .= ("Keep exact steering evidence."::Text)])
      submission<-submitRunControl owned proof(key "steer")(Just("\""<>textField "revision" view<>"\""))body >>=right
      let command=receiptId(submissionReceipt submission)
      deliverAcceptedControl owned command >>=right
      if stale then do
        ingestUntil(acknowledgement command "accepted")
        acceptedReceipt<-readControlReceipt store proof command >>=right
        check "genuine native Accepted is not delivery or effect" (receiptEffect acceptedReceipt==Nothing)
        BS.writeFile completion BS.empty
        ingestUntil $ do currentState<-snapshot;pure(any (any ((/=Runtime.AttemptRunning) . Runtime.snapshotAttemptState) . Map.elems . Runtime.snapshotOccurrenceAttempts)(Map.elems(Runtime.snapshotOccurrences currentState)))
        currentState<-snapshot
        check "normal original attempt finish removes authoritative steering support"
          (all (all ((/=Just True) . Runtime.snapshotAttemptSteerable) . Map.elems . Runtime.snapshotOccurrenceAttempts)(Map.elems(Runtime.snapshotOccurrences currentState)))
        await $ let retired=doesFileExist(controlBarrier<>".retired") >>= \done->unless done(threadDelay 1000>>retired) in retired
        retiredAttempt<-TE.decodeUtf8 <$> BS.readFile(controlBarrier<>".retired")
        check "original unregister returned for exact steering attempt" (retiredAttempt==T.pack(show attempt))
        BS.writeFile(controlBarrier<>".release")BS.empty
        ingestUntil $ do latest<-snapshot;pure(maybe False ((=="unsupported") . Runtime.snapshotControlState)(Map.lookup command(Runtime.snapshotControlAcks latest)))
        refused<-readControlReceipt store proof command >>=right
        check "genuine Accepted to Unsupported remains distinct with no effect" (receiptEffect refused==Nothing && receiptState refused==Acknowledged &&
          maybe False ((=="unsupported") . textField "state" . acknowledgementValue)(receiptAcknowledgement refused))
      else do
        ingestUntil(acknowledgement command "delivered")
        delivered<-readControlReceipt store proof command >>=right
        check "unchanged live native steering preserves timing address and effect" (maybe False ((=="steered") . textField "kind" . effectValue)(receiptEffect delivered))
      when(count>1) $ do
        actors <- forM [0::Int ..8] $ \index -> do
          let client="stress_client_"<>T.pack(show index)
              credential="stress_credential_"<>T.pack(show index)
              secret=BS.replicate 32(fromIntegral(120+index))
          mutate store $ do
            execute "INSERT INTO clients VALUES (?,'revision','authority',0)" [SQL.SQLText client]
            execute "INSERT INTO credentials VALUES (?,?,?,'2999-01-01T00:00:00Z',0)" [SQL.SQLText credential,SQL.SQLText client,SQL.SQLBlob(convert(hash secret::Digest SHA256))]
            forM_ ["observe","control"::Text] $ \scope->execute "INSERT INTO credential_scopes VALUES (?,'profile',?)" [SQL.SQLText credential,SQL.SQLText scope]
          authenticateCredential store secret >>=right
        forM_ [2..count] $ \index -> do
          actor <- case drop ((index-2) `mod` length actors) actors of value:_->pure value;_->error "missing stress actor"
          controlView<-observeControl (readControlSurface owned actor)
          accepted<-submitRunControl owned actor(key("stress-"<>T.pack(show index)))(Just("\""<>textField "revision" controlView<>"\""))body >>=right
          let ident=receiptId(submissionReceipt accepted)
          deliverAcceptedControl owned ident >>=right
          ingestUntil(acknowledgement ident "delivered")
        full<-snapshot
        check "all 256 ordinary controls retain original native acknowledgements" (Map.size(Runtime.snapshotControlAcks full)==256)
        fullView<-observeControl (readControlSurface owned proof)
        overflow<-submitRunControl owned proof(key "ordinary-overflow")(Just("\""<>textField "revision" fullView<>"\""))body
        check "257th ordinary Manager control refuses before write" (case overflow of Left SizeLimit->True;_->False)
        _<-createDraft store proof(key "fill-ledger")(encoded(object["workflowId" .= draftWorkflow ready,"descriptorRevision" .= draftDescriptorRevision ready,
          "profileId" .= draftProfile ready,"profileRevision" .= draftProfileRevision ready])) >>=right
        controlNumber store "SELECT bytes FROM command_ledger_usage" >>=check "ordinary ledger is saturated without changing C or R" . (==ledger-16*commandCapacity)
        cancelView<-observeControl (readControlSurface owned proof)
        let cancelBody=encoded(object["operation" .= ("cancel"::Text)])
            cancelEtag=Just("\""<>textField "revision" cancelView<>"\"")
            retrySame action=await loop
              where loop=do
                      result<-try @StoreFailure action
                      case result of Left StoreBusy->threadDelay 1000>>loop;Left failure->throwIO failure
                                     Right value->noteControlResult "cancellation submission (no opaque retry)" value
        opaqueSubmissionCalls<-newIORef (0::Int)
        opaqueSubmissionOutcome<-retrySame $ do
          callNumber<-readIORef opaqueSubmissionCalls
          modifyIORef' opaqueSubmissionCalls (+1)
          pure(if callNumber==0 then Left StorageUnavailable else Right ())
        opaqueSubmissionAttempts<-readIORef opaqueSubmissionCalls
        check "opaque cancellation submission refusal is returned without replay"
          (opaqueSubmissionOutcome==Left StorageUnavailable && opaqueSubmissionAttempts==1)
        rendezvous<-newEmptyTMVarIO
        raceStarted<-getMonotonicTimeNSec
        a<-async(atomically(readTMVar rendezvous)>>retrySame(submitRunControl owned proof(key "extra-cancel-a")cancelEtag cancelBody))
        secondActor<-case actors of actor:_->pure actor;_->error "missing cancel racer"
        b<-async(atomically(readTMVar rendezvous)>>retrySame(submitRunControl owned secondActor(key "extra-cancel-b")cancelEtag cancelBody))
        atomically(putTMVar rendezvous())
        outcomes<-mapM wait [a,b]
        raceEnded<-getMonotonicTimeNSec
        putStrLn("extra-cancel preparation race microseconds="<>show((raceEnded-raceStarted)`div`1000)<>" outcomes="<>show[either failureCode (const "accepted") value|value<-outcomes])
        extra<-case [accepted|Right accepted<-outcomes] of [accepted]->pure accepted;_->error "extra cancel race did not select one original ticket"
        check "one extra cancellation wins across distinct clients at saturation" (length[()|Left _<-outcomes]==1)
        occupiedView<-observeControl (readControlSurface owned proof)
        another<-submitRunControl owned proof(key "second-extra-cancel")(Just("\""<>textField "revision" occupiedView<>"\""))cancelBody
        check "second extra cancellation cannot acquire original live slot" (case another of Left SizeLimit->True;_->False)
        let extraId=receiptId(submissionReceipt extra)
        deliverAcceptedControl owned extraId >>=right
        ticket<-maybe(error "missing original extra cancellation ticket")pure(submissionTicket extra)
        _<-recordUnresolved ticket >>=right
        again<-retrySame(submitRunControl owned proof(key "uncertain-extra-cancel")(Just("\""<>textField "revision" occupiedView<>"\""))cancelBody)
        check "uncertainty never reopens extra cancellation slot" (case again of Left SizeLimit->True;Left OwnershipUnavailable->True;Left StaleRevision->True;_->False)
        let drain=ingestOne >>= \more->when more drain
        _<-try @WorkerFailure(await drain)
        joinControlCleanup live owned
        final<-snapshot
        check "v3 records 256 ordinary controls and genuine correlated cancellation" (Map.size(Runtime.snapshotControlAcks final)==257 && Runtime.snapshotRunStatus final==Runtime.RunCancelledStatus &&
          maybe False ((==Just "cancelRun") . Runtime.snapshotControlCommand)(Map.lookup extraId(Runtime.snapshotControlAcks final)))
      release
      joinControlCleanup live owned
      BS.writeFile(work </> (T.unpack timing<>"-steering-receipt.json")) . encoded =<< (readControlReceipt store proof command >>=right)
      nativePresent native context >>=check "steering fixture joins original native process" . not

joinControlCleanup :: LivePreparation -> AcceptedStart -> IO ()
joinControlCleanup live owned = do
  stopped <- stopAcceptedStart owned >>= noteControlResult "control cleanup (no retry)"
  right stopped
  await(awaitAdmissionCleanup live) >>=right

nativeMixedControlChecks :: FilePath -> FilePath -> FilePath -> FilePath -> IO ()
nativeMixedControlChecks work native source python = do
  let adapters=work </> "mixed-adapters"
      launcher=adapters </> "mixed-adapter"
      script=source </> "engine/acp/test/retry_adapter.py"
  createDirectory adapters
  writeFile launcher ("#!"<>python<>"\nimport os\nos.execv("<>show python<>",["<>show python<>","<>show script<>"])\n")
  setFileMode launcher 0o700
  forM_ ["retry","choose-retry","failover","abandon"] $ \choice -> withReadyRunner work native [] "mixed-controls" ("mixed-"<>choice)
    ["--engine","acp","--adapter","mixed-adapter"] [("PATH",T.pack adapters)] $ \fixture@(Fixture _ _ store proof key _) ->
      withPrepared fixture fixedClock $ \_ live context reviewed public -> do
        (_,start)<-acceptApproval reviewed proof(key "approve-mixed")(condition public)(approvalBody public) >>=right
        owned<-maybe(error "missing mixed original owner")pure start
        let association=RunAssociation(acceptedStartRun owned)"profile"(preparedRootIdentity(reviewNative context))(preparedRunId(reviewNative context))
            snapshot=observeControl $ restoreRunProjection store association >>=maybe(error "no mixed projection")(pure . Runtime.checkpointSnapshot)
            pending=observeControl $ runRead store $ do
              rows<-query "SELECT id,occurrence_id,generation,revision,kind FROM decisions WHERE run_id=? AND state IN ('pending','submitting') ORDER BY length(observed_sequence),observed_sequence" [SQL.SQLText(acceptedStartRun owned)]
              forM rows $ \row->case row of [SQL.SQLText i,SQL.SQLText o,SQL.SQLText g,SQL.SQLText r,SQL.SQLText k]->pure(i,o,g,r,k);_->refuseTransaction StoreIntegrity
            conditionOf revision=Just("\""<>revision<>"\"")
            controlCondition=observeControl (readControlSurface owned proof) >>= \value->pure(conditionOf(textField "revision" value))
            bodyFor (_,occurrence,generation,_,kind) selected=encoded(object
              (["operation" .= (if kind=="question" then "answer" else if selected=="retry" then "retry" else "choose-recovery"::Text),"occurrenceId" .= occurrence,"generation" .= generation] <>
               if kind=="question" then ["value" .= False] else if selected=="retry" then [] else ["choice" .= (if selected=="choose-retry" then "retry" else selected)]))
            ingestUntil predicate=await loop
              where loop=do
                      done<-predicate
                      unless done $ do more<-observeControl (ingestAcceptedStart owned);unless more(error "mixed native stream ended early");loop
            deliver suffix body=do
              etag<-controlCondition
              submission<-submitRunControl owned proof(key suffix)etag body >>=right
              let command=receiptId(submissionReceipt submission)
              deliverAcceptedControl owned command >>=right
              pure(submissionReceipt submission)
            effectRecorded command=observeControl (runRead store (controlEffectRecorded command))
        deliverAcceptedStart owned >>=right
        first<-observeControl (ingestAcceptedStart owned);check "mixed original runtime started" first
        ingestUntil $ do current<-snapshot;pure(any (maybe False Runtime.dispatchOpen . Runtime.snapshotOccurrenceDispatch)(Map.elems(Runtime.snapshotOccurrences current)))
        current<-snapshot
        (occurrence,target)<-case [(Runtime.occurrenceNumber(Runtime.snapshotOccurrenceId item),selected)|item<-Map.elems(Runtime.snapshotOccurrences current),Just dispatch<-[Runtime.snapshotOccurrenceDispatch item],selected<-take 1(Runtime.dispatchTargets dispatch)] of
          pair:_->pure pair;_->error "native reserved redirect absent"
        redirected<-deliver "redirect" (encoded(object["operation" .= ("redirect"::Text),"occurrenceId" .= T.pack(show occurrence),"target" .= target]))
        retained<-newIORef [(redirected,T.pack(show occurrence),"redirected")]
        ingestUntil(effectRecorded(receiptId redirected))
        ingestUntil ((==2) . length <$> pending)
        rows<-pending
        nonHead@(ident,_,_,revision,_)<-case drop 1 rows of [row]->pure row;_->error "missing genuine person/recovery non-head"
        etag<-controlCondition
        let refusedBody=bodyFor nonHead ("choose-retry"::Text)
        refusedRun<-submitRunControl owned proof(key "nonhead-run")etag refusedBody
        refusedDecision<-submitDecisionControl owned proof ident(key "nonhead-decision")(conditionOf revision)refusedBody
        check "genuine mixed non-head refuses through both internal entrypoints" (case(refusedRun,refusedDecision)of(Left DecisionNotHead,Left DecisionNotHead)->True;_->False)
        chosen<-newIORef False
        let processHead count=do
              available<-pending
              case available of
                []->do
                  currentState<-snapshot
                  unless(Runtime.snapshotRunStatus currentState `elem` [Runtime.RunSucceeded,Runtime.RunFailedStatus,Runtime.RunCancelledStatus]) $ do
                    more<-observeControl (ingestAcceptedStart owned)
                    unless more(error "mixed control ended without terminal evidence")
                    processHead count
                row@(decision,decisionOccurrence,_,decisionRevision,kind):_->do
                  used<-readIORef chosen
                  let selection=if used then "retry" else T.pack choice
                      body=bodyFor row selection
                      expectedKind=if kind=="question" then "answer-accepted" else if selection=="retry" then "retried" else "recovery-chosen"
                  acceptedReceipt<-if kind=="recovery" && selection=="retry" then deliver("recovery-"<>T.pack(show count))body else do
                    accepted<-submitDecisionControl owned proof decision(key("decision-"<>T.pack(show count)))(conditionOf decisionRevision)body >>=right
                    let command=receiptId(submissionReceipt accepted)
                    deliverAcceptedControl owned command >>=right
                    pure(submissionReceipt accepted)
                  modifyIORef' retained (<>[(acceptedReceipt,decisionOccurrence,expectedKind)])
                  when(kind=="recovery")(modifyIORef' chosen(const True))
                  ingestUntil(effectRecorded(receiptId acceptedReceipt))
                  processHead(count+1::Int)
        await(processHead 0)
        let drain=observeControl (ingestAcceptedStart owned) >>= \more->when more drain
        _<-try @WorkerFailure(await drain)
        joinControlCleanup live owned
        final<-snapshot
        check "recovery terminal outcome remains native evidence" (Runtime.snapshotRunStatus final==if choice=="abandon" then Runtime.RunFailedStatus else Runtime.RunSucceeded)
        -- Public reads are one-shot, after the original owner has successfully joined.
        expected<-readIORef retained
        forM_ expected $ \(original,expectedOccurrence,expectedKind)->do
          receipt<-readControlReceipt store proof(receiptId original) >>=right
          check "post-cleanup public receipt retains original acceptance binding"
            (receiptBinding receipt==receiptBinding original && receiptState receipt==EffectObserved && receiptAttemptedAt receipt/=Nothing && receiptRefusal receipt==Nothing)
          check "post-cleanup public acknowledgement correlates original command and occurrence"
            (maybe False (\ack->let value=acknowledgementValue ack in textField "commandId" value==receiptId original && textField "command" value==operationName(receiptOperation original) && textField "occurrenceId" value==expectedOccurrence) (receiptAcknowledgement receipt))
          effect<-maybe(error "missing mixed native effect")pure(receiptEffect receipt)
          let value=effectValue effect
          check (if expectedKind=="redirected" then "native redirect correlates exact original control" else "mixed native effect keeps exact occurrence and control receipt")
            (textField "kind" value==expectedKind && textField "occurrenceId" (valueField "address" value)==expectedOccurrence && textField "resource" value=="/v1/runs/"<>acceptedStartRun owned<>"/control")
        BS.writeFile(work </> ("mixed-"<>choice<>"-snapshot.json"))(encoded(Runtime.runSnapshotValue final))
        nativePresent native context >>=check "mixed control fixture joins original native process" . not
  where
    receiptBinding receipt=(receiptId receipt,receiptProfile receipt,receiptOperation receipt,receiptResource receipt,receiptAcceptedAt receipt)
    valueField key (Object fields)=maybe(error "missing control field")id(KM.lookup key fields)
    valueField _ _=error "missing control object"
    textField key value=case valueField key value of String text->text;_->error "missing control text"

nativeControlChecks :: FilePath -> FilePath -> IO ()
nativeControlChecks work native = do
  receiptObservationChecks work native
  precise <- right(eitherDecodeStrict' "123456789012345678901234567890" :: Either String Value)
  let expectedAnswers=Map.fromList [(0,Bool False),(1,Null),(2,object["ok" .= False,"notes" .= ([]::[Text])]),
        (3,toJSON [precise,Number (-7)]),(4,object["numerator" .= (1::Integer),"denominator" .= (8::Integer)]),
        (5,object["tag" .= ("approve"::Text)]),(6,object["ratio" .= object["numerator" .= (1::Integer),"denominator" .= (8::Integer)]]),
        (7,Bool True)]
  withReadyRunner work native [] "typed-person" "typed-controls" ["--scripted"] [] $ \fixture@(Fixture root _ store proof key _) ->
    withPrepared fixture fixedClock $ \_ live context reviewed public -> do
      let otherSecret=BS.replicate 32 98
      mutate store $ do
        execute "INSERT INTO clients VALUES ('other-client','revision','authority',0)" []
        execute "INSERT INTO credentials VALUES ('other-credential','other-client',?,'2999-01-01T00:00:00Z',0)" [SQL.SQLBlob(convert(hash otherSecret::Digest SHA256))]
        forM_ ["observe","submit","control"::Text] $ \scope->execute "INSERT INTO credential_scopes VALUES ('other-credential','profile',?)" [SQL.SQLText scope]
      other <- authenticateCredential store otherSecret >>= right
      (_,start) <- acceptApproval reviewed proof(key "control-approve")(condition public)(approvalBody public) >>= right
      owned <- maybe(error "missing native control owner")pure start
      let association=RunAssociation (acceptedStartRun owned) "profile" (preparedRootIdentity(reviewNative context)) (preparedRunId(reviewNative context))
          pending=observeControl $ runRead store $ do
            rows<-query "SELECT id,occurrence_id,generation,revision FROM decisions WHERE run_id=? AND state IN ('pending','submitting') ORDER BY length(observed_sequence),observed_sequence" [SQL.SQLText(acceptedStartRun owned)]
            forM rows $ \row->case row of [SQL.SQLText i,SQL.SQLText o,SQL.SQLText g,SQL.SQLText r]->pure(i,o,g,r);_->refuseTransaction StoreIntegrity
          controlEtag=observeControl (readControlSurface owned proof) >>= \value->pure(Just("\""<>valueText "revision" value<>"\""))
          bodyFor (_,occurrence,generation,_) value=encoded(object["operation" .= ("answer"::Text),"occurrenceId" .= occurrence,"generation" .= generation,"value" .= value])
          decisionEtag (_,_,_,revision)=Just("\""<>revision<>"\"")
          ingestUntil predicate=await loop
            where
              loop=do
                done<-predicate
                unless done $ do more<-observeControl (ingestAcceptedStart owned);unless more(error "native control evidence ended early");loop
          submitSame action=await loop
            where
              loop=do
                result<-try @StoreFailure action
                case result of
                  Left StoreBusy->threadDelay 1000>>loop
                  Left failure->throwIO failure
                  Right value->noteControlResult "typed-answer submission (no opaque retry)" value
      opaqueSubmissionCalls<-newIORef (0::Int)
      opaqueSubmissionOutcome<-submitSame $ do
        callNumber<-readIORef opaqueSubmissionCalls
        modifyIORef' opaqueSubmissionCalls (+1)
        pure(if callNumber==0 then Left StorageUnavailable else Right ())
      opaqueSubmissionAttempts<-readIORef opaqueSubmissionCalls
      check "opaque typed-answer submission refusal is returned without replay"
        (opaqueSubmissionOutcome==Left StorageUnavailable && opaqueSubmissionAttempts==1)
      deliverAcceptedStart owned >>= right
      ingestUntil (not . null <$> pending)
      initial<-pending
      check "genuine typed person lane opens one decision" (length initial==1)
      firstRow@(firstId,_,_,_) <- case initial of row:_->pure row;_->error "missing first typed decision"
      question<-readDecision store proof association firstId
      check "verified Runtime editor schema present" (case question of
        Object fields -> case KM.lookup "question" fields of Just(Object q)->KM.member "editorSchema" q;_->False
        _ -> False)
      invalid<-submitDecisionControl owned proof firstId(key "invalid-typed")(decisionEtag firstRow)(bodyFor firstRow (String "invalid typed answer")) >>= right
      deliverAcceptedControl owned(receiptId(submissionReceipt invalid)) >>= right
      ingestUntil $ do receipt<-readControlReceipt store proof(receiptId(submissionReceipt invalid)) >>= right;pure(case receiptAcknowledgement receipt of Just ack->valueText "state" (acknowledgementValue ack)=="failed";_->False)
      released<-pending
      check "native typed failure releases exact reservation and revises editor" (case released of (_,_,_,revision):_->revision/=fourth firstRow;_->False)
      stale<-submitDecisionControl owned proof firstId(key "stale-editor")(decisionEtag firstRow)(bodyFor firstRow(Bool False))
      check "pre-failure editor stale after proven release" (case stale of Left StaleRevision->True;_->False)
      typedCommands<-forM [0::Int ..6] $ \index->do
        ingestUntil (not . null <$> pending)
        row@(ident,occurrence,generation,_)<-pending >>= \rows->case rows of x:_->pure x;_->error "missing next typed decision"
        decisionView<-readDecision store proof association ident
        controlView<-observeControl (readControlSurface owned proof)
        let editor=case decisionView of
              Object fields -> case KM.lookup "question" fields of Just(Object questionFields)->KM.lookup "editorSchema" questionFields;_->Nothing
              _ -> Nothing
        check "unsupported full Runtime editor is null without weakening nested constraints"
          (if occurrence `elem` ["4","5","6"] then editor==Just Null else editor/=Nothing && editor/=Just Null)
        BS.writeFile(work </> ("decision-view-"<>show index<>".json"))(encoded decisionView)
        BS.writeFile(work </> ("control-view-"<>show index<>".json"))(encoded controlView)
        value <- case lookup occurrence [(T.pack(show occurrenceNumber),answer)|(occurrenceNumber,answer)<-Map.toList expectedAnswers] of
          Just answer->pure answer;_->error "unexpected typed occurrence"
        etag<-controlEtag
        let body=bodyFor row value; decisionKey=key("answer-decision-"<>T.pack(show index));runKey=key("answer-run-"<>T.pack(show index))
        rendezvous<-newEmptyTMVarIO
        a<-async(atomically(readTMVar rendezvous)>>submitSame(submitDecisionControl owned proof ident decisionKey(decisionEtag row)body))
        b<-async(atomically(readTMVar rendezvous)>>submitSame(submitRunControl owned other runKey etag body))
        atomically(putTMVar rendezvous())
        answers<-mapM wait [a,b]
        winner<-case [accepted|Right accepted<-answers] of [accepted]->pure accepted;_->error "two clients did not arbitrate one generation"
        check "distinct clients race across both entrypoints with one reservation" (length[()|Left _<-answers]==1)
        let receipt=submissionReceipt winner;command=receiptId receipt
        check "manager acceptance distinct from attempted write" (receiptState receipt==Accepted && receiptAttemptedAt receipt==Nothing)
        latestEtag<-controlEtag
        blocked<-submitRunControl owned proof(key("second-answer-"<>T.pack(show index)))latestEtag body
        check "reserved generation cannot accept another answer before write" (case blocked of Left StaleRevision->True;_->False)
        deliverAcceptedControl owned command >>= right
        ticket<-maybe(error "missing original live control ticket")pure(submissionTicket winner)
        _<-recordUnresolved ticket >>= right
        afterTimeout<-submitRunControl owned proof(key("timeout-answer-"<>T.pack(show index)))latestEtag body
        check "unresolved acknowledgement does not release reservation" (case afterTimeout of Left StaleRevision->True;Left OwnershipUnavailable->True;_->False)
        controlNumber store "SELECT count(*) FROM decisions WHERE state='submitting'" >>= check "uncertain delivery retains durable decision reservation" . (==1)
        reserved<-observeControl $ runRead store $ do
          currentReservation<-query "SELECT command_id,generation,state FROM decisions WHERE id=? AND run_id=?" [SQL.SQLText ident,SQL.SQLText(acceptedStartRun owned)]
          competing<-query "SELECT id FROM commands WHERE idempotency_key IN (?,?)"
            [SQL.SQLText(key("second-answer-"<>T.pack(show index))),SQL.SQLText(key("timeout-answer-"<>T.pack(show index)))]
          pure(currentReservation==[[SQL.SQLText command,SQL.SQLText generation,SQL.SQLText "submitting"]] && null competing)
        check "unresolved original command and generation stay reserved without another acceptance" reserved
        duplicate<-deliverAcceptedControl owned command
        check "consumed original dispatch never writes twice" (case duplicate of Left OwnershipUnavailable->True;_->False)
        when(index==0) $ do
          ingestUntil $ do current<-readControlReceipt store proof command >>=right;pure(maybe False ((=="accepted") . valueText "state" . acknowledgementValue)(receiptAcknowledgement current))
          acceptedEtag<-controlEtag
          afterAcceptance<-submitRunControl owned proof(key "after-native-accepted")acceptedEtag body
          check "native Accepted cannot release submitting decision" (case afterAcceptance of Left StaleRevision->True;_->False)
        ingestUntil $ do current<-readControlReceipt store proof command >>= right;pure(receiptEffect current/=Nothing)
        current<-readControlReceipt store proof command >>= right
        check "native Delivered correlates typed acceptance, separate from command receipt" (receiptState current==EffectObserved && maybe False ((=="delivered") . valueText "state" . acknowledgementValue)(receiptAcknowledgement current))
        replay<-case answers of
          [Right _,_] -> submitDecisionControl owned proof ident decisionKey(decisionEtag row)body >>= right
          _ -> submitRunControl owned other runKey etag body >>= right
        check "exact replay returns immutable acceptance without a ticket" (submissionReplayed replay && submissionReceipt replay==receipt && case submissionTicket replay of Nothing->True;_->False)
        conflict<-case answers of
          [Right _,_] -> submitSame(submitDecisionControl owned proof ident decisionKey(decisionEtag row)(body<>" "))
          _ -> submitSame(submitRunControl owned other runKey etag(body<>" "))
        check "exact original body bytes bind replay" (case conflict of Left IdempotencyConflict->True;_->False)
        controlNumber store "SELECT count(*) FROM decisions WHERE state='submitting'" >>= check "matching typed delivery resolves reservation" . (==0)
        pure command
      -- Observe the real final person gate only after every intermediate assertion.
      ingestUntil (not . null <$> pending)
      holdRow@(holdId,_,_,_)<-pending >>= \rows->case rows of
        [row@(_,"7",_,_)]->pure row
        _->error "missing exact final-control-confirmation decision"
      held<-observeControl (restoreRunProjection store association) >>=maybe(error "no final hold checkpoint")pure
      liveWorker<-observeAcceptedStart owned
      let heldSnapshot=Runtime.checkpointSnapshot held
      check "unanswered final person confirmation prevents native terminal completion"
        (Runtime.snapshotRunStatus heldSnapshot==Runtime.RunRunning &&
         any (\occurrence->Runtime.occurrenceNumber(Runtime.snapshotOccurrenceId occurrence)==7 && Runtime.snapshotOccurrencePersonPending occurrence) (Map.elems(Runtime.snapshotOccurrences heldSnapshot)) &&
         observedWorkerPhase liveWorker==WorkerRunning && maybe True (const False) (observedWorkerExit liveWorker))
      holdAnswer<-submitDecisionControl owned proof holdId(key "answer-final-hold")(decisionEtag holdRow)(bodyFor holdRow(Bool True)) >>=right
      let holdCommand=receiptId(submissionReceipt holdAnswer)
      check "final hold answer uses fresh ordinary acceptance"
        (not(submissionReplayed holdAnswer) && receiptState(submissionReceipt holdAnswer)==Accepted && case submissionTicket holdAnswer of Just _->True;Nothing->False)
      deliverAcceptedControl owned holdCommand >>=right
      let drain=observeControl (ingestAcceptedStart owned) >>= \more->when more drain
      await drain
      joinControlCleanup live owned
      checkpoint<-restoreRunProjection store association >>=maybe(error "no typed terminal checkpoint")pure
      let finalSnapshot=Runtime.checkpointSnapshot checkpoint
      check "all typed native answers and final confirmation complete original run" (Runtime.snapshotRunStatus finalSnapshot==Runtime.RunSucceeded)
      holdReceipt<-readControlReceipt store proof holdCommand >>=right
      check "final confirmation has correlated native delivery and effect after cleanup"
        (receiptId holdReceipt==holdCommand && receiptState holdReceipt==EffectObserved &&
         maybe False (\ack->valueText "commandId" (acknowledgementValue ack)==holdCommand && valueText "state" (acknowledgementValue ack)=="delivered" && valueText "occurrenceId" (acknowledgementValue ack)=="7") (receiptAcknowledgement holdReceipt) &&
         maybe False ((=="answer-accepted") . valueText "kind" . effectValue) (receiptEffect holdReceipt))
      let expectedControls=receiptId(submissionReceipt invalid):typedCommands<>[holdCommand]
      check "native control acknowledgements contain only the original dispatched commands"
        (Map.keys(Runtime.snapshotControlAcks finalSnapshot)==Map.keys(Map.fromList[(ident,())|ident<-expectedControls]))
      answers <- Runtime.readAnswerRecords (root </> "runs" </> "runs" </> T.unpack(runIdText(preparedRunId(reviewNative context))) </> "runtime")
      check "false null arrays objects and numbers reach original Runtime typed answer store unchanged"
        (length answers==Map.size expectedAnswers &&
         Map.fromList [(Runtime.occurrenceNumber(Runtime.answerOccurrence answer),Runtime.answerValue answer)|answer<-answers]
          == expectedAnswers)
      BS.writeFile(work </> "typed-controls-checkpoint.json")(encoded(Runtime.snapshotCheckpointValue checkpoint))
      nativePresent native context >>=check "typed controls join original native workers" . not
  cancellationRetentionChecks work native
  where
    fourth (_,_,_,value)=value
    valueText key (Object fields)=case KM.lookup key fields of Just(String value)->value;_->error "missing text field"
    valueText _ _=error "missing object"

cancellationRetentionChecks :: FilePath -> FilePath -> IO ()
cancellationRetentionChecks work native =
  withReady work native "cancel-controls" ["--scripted"] [] $ \fixture@(Fixture _ _ store proof key _) ->
    withPrepared fixture fixedClock $ \_ live context reviewed public -> do
      (_,start)<-acceptApproval reviewed proof(key "approve-cancel")(condition public)(approvalBody public) >>=right
      owned<-maybe(error "no cancellation owner")pure start
      deliverAcceptedStart owned >>=right
      more<-observeControl (ingestAcceptedStart owned);check "native cancellation run observed" more
      let association=RunAssociation(acceptedStartRun owned)"profile"(preparedRootIdentity(reviewNative context))(preparedRunId(reviewNative context))
      view<-observeControl (readControlSurface owned proof)
      submitted<-submitRunControl owned proof(key "cancel")(Just("\""<>valueText "revision" view<>"\""))(encoded(object["operation" .= ("cancel"::Text)])) >>=right
      let command=receiptId(submissionReceipt submitted)
      check "accepted cancellation is not terminal" (receiptState(submissionReceipt submitted)==Accepted)
      deliverAcceptedControl owned command >>=right
      let drain=observeControl (ingestAcceptedStart owned) >>= \next->when next drain
      _<-try @WorkerFailure(await drain)
      joinControlCleanup live owned
      current<-readControlReceipt store proof command >>=right
      check "uncorrelated terminal cancellation never manufactures command effect" (receiptEffect current==Nothing)
      checkpoint<-restoreRunProjection store association >>=maybe(error "no cancellation checkpoint")pure
      check "native terminal remains independent of cancellation receipt" (Runtime.snapshotRunStatus(Runtime.checkpointSnapshot checkpoint)==Runtime.RunCancelledStatus)
      number store "SELECT terminal_observed FROM runs" >>= check "cancelled Runtime terminal evidence is genuine but not command completion" . (==1)
      runTransaction store $ do
        execute "UPDATE commands SET inactive_since='2000-01-01T00:00:00Z'" []
        pure((),[Invalidation "service.changed" "/v1/capabilities" "retention_fixture"])
      void(retainReceipts store "" >>= right)
      number store "SELECT count(*) FROM commands WHERE retired=1 OR inactive_since IS NOT NULL" >>= check "real unresolved cancellation protects receipts despite terminal run and aged eligibility" . (==0)
  where
    valueText key (Object fields)=case KM.lookup key fields of Just(String value)->value;_->error "missing text field"
    valueText _ _=error "missing object"

nativeDecisionIngestionChecks :: FilePath -> FilePath -> IO ()
nativeDecisionIngestionChecks work native = withReady work native "native-decision-ingestion" ["--scripted"] [] $ \fixture@(Fixture root _ store proof key _) ->
  withPrepared fixture fixedClock $ \_ live context reviewed public -> do
    (_,start) <- acceptApproval reviewed proof (key "approve") (condition public) (approvalBody public) >>= right
    owned <- maybe (error "missing original decision start") pure start
    deliverAcceptedStart owned >>= right
    let association = RunAssociation (acceptedStartRun owned) "profile" (preparedRootIdentity (reviewNative context)) (preparedRunId (reviewNative context))
    forM_ [1::Int,2] $ \_ -> await (ingestAcceptedStart owned) >>= check "native person run and occurrence committed"
    before <- restoreRunProjection store association
    eventsBefore <- number store "SELECT count(*) FROM invalidations"
    bracket (SQL.open (T.pack (root </> "coordination.sqlite3"))) SQL.close $ \db -> do
      SQL.exec db "CREATE TRIGGER decision_ingestion_fault BEFORE INSERT ON invalidations WHEN NEW.kind='run.changed' BEGIN SELECT RAISE(ABORT,'fixture decision observation fault'); END"
      result <- try @StoreFailure (await (ingestAcceptedStart owned))
      check "native question invalidation failure is explicit storage refusal" (result==Left StoreUnavailable)
      number store "SELECT count(*) FROM decisions" >>= check "failed commit rolls back derived native decision" . (==0)
      number store "SELECT count(*) FROM artifacts" >>= check "failed commit rolls back native question reference" . (==0)
      number store "SELECT count(*) FROM invalidations" >>= check "failed decision commit rolls back all invalidations" . (==eventsBefore)
      restoreRunProjection store association >>= check "failed question commit retains valid Runtime prefix" . (==before)
      SQL.exec db "DROP TRIGGER decision_ingestion_fault"
    await (ingestAcceptedStart owned) >>= check "retained native question commits on explicit retry"
    number store "SELECT count(*) FROM decisions WHERE state='pending' AND question_artifact_id IS NOT NULL" >>= check "native mandatory decision and reference observed together" . (==1)
    number store "SELECT count(*) FROM artifacts WHERE verification='referenced'" >>= check "native question remains reference-only" . (==1)
    number store "SELECT count(*) FROM invalidations WHERE kind='decision.changed'" >>= check "native question has one durable decision invalidation" . (==1)
    stopAcceptedStart owned >>= right
    await (awaitAdmissionCleanup live) >>= right

failedNativeIngestionChecks :: FilePath -> FilePath -> FilePath -> FilePath -> IO ()
failedNativeIngestionChecks work native source python =
  withReadyRunner work python [T.pack (source </> "manager/test/worker_fixture.py"),T.pack native,"prefix-malformed",T.pack (work </> "prefix-malformed.ndjson")] "prompt-source" "failed-native-ingestion" ["--scripted"] [] $ \fixture@(Fixture _ _ store proof key _) ->
    withPrepared fixture fixedClock $ \_ live context reviewed public -> do
      (_,start) <- acceptApproval reviewed proof (key "approve") (condition public) (approvalBody public) >>= right
      owned <- maybe (error "missing failed original accepted start") pure start
      deliverAcceptedStart owned >>= right
      void (await (awaitAdmissionCleanup live))
      observation <- observeAcceptedStart owned
      check "native transport failure retains validated prefix after physical cleanup" (observedQueuedFrames observation>=1 && observedWorkerExit observation==Just (Left WorkerRuntimeDecode) && not (observedCleanupUnproven observation))
      let drain = ingestAcceptedStart owned >>= \more -> when more drain
          association = RunAssociation (acceptedStartRun owned) "profile" (preparedRootIdentity (reviewNative context)) (preparedRunId (reviewNative context))
      failure <- try @WorkerFailure (await drain)
      check "drain reports original transport failure, not false EOF or generic closure" (failure==Left WorkerRuntimeDecode)
      checkpoint <- restoreRunProjection store association >>= maybe (error "lost valid failed-worker prefix") pure
      let snapshot=Runtime.checkpointSnapshot checkpoint
      check "valid native prefix survives without invented terminal success" (Runtime.snapshotRunStatus snapshot==Runtime.RunRunning && not (Runtime.snapshotTraceRecorded snapshot) && Runtime.snapshotResult snapshot==Nothing)
      number store "SELECT count(*) FROM ingestions" >>= check "failed worker valid prefix committed exactly once" . (==1)

-- A06 observation: two original workers, each with independent engine/person branches.
nativeConcurrentIngestionChecks :: FilePath -> FilePath -> FilePath -> FilePath -> IO ()
nativeConcurrentIngestionChecks = nativeConcurrentChecks False

nativeConcurrentChecks :: Bool -> FilePath -> FilePath -> FilePath -> FilePath -> IO ()
nativeConcurrentChecks gateCheck work native source python = forM_ [False,True] $ \interrupt -> do
  let name=if interrupt then "native-pair-interrupted" else "native-pair"
      base=work </> name
      root=base </> "manager"
      barrier=base </> "barrier"
      adapters=base </> "bin"
      adapter=adapters </> "pair-adapter"
      configPath=base </> "configuration.json"
      stub=source </> "engine/acp/test/stub_adapter.py"
      profileIds=["pair-a","pair-b"::Text]
      release=BS.writeFile (barrier </> "release") BS.empty
      readyFiles=filter ((==".ready") . takeExtension) <$> listDirectory barrier
  forM_ [base,root,barrier,adapters,base </> "pair-a",base </> "pair-b"] $ \path -> createDirectory path >> setFileMode path 0o700
  writeFile adapter ("#!"<>python<>"\nimport os,sys\nos.execv("<>show python<>",["<>show python<>","<>show stub<>","<>show ("--prompt-barrier="<>barrier)<>",*sys.argv[1:]])\n")
  setFileMode adapter 0o700
  capabilities <- getNumCapabilities
  let profile ident=object ["id" .= ident,"runner" .= ("native"::Text),"workspace" .= (base </> T.unpack ident),
        "workspaceLabel" .= ("Independent fixture workspace"::Text),"targetLabel" .= ("Offline ACP"::Text),
        "targetArguments" .= (["--engine","acp","--adapter","pair-adapter"]::[Text]),
        "environment" .= [object ["name" .= (key::Text),"value" .= value] | (key,value)<-[("PATH",T.pack adapters),("TMPDIR",T.pack base),("XDG_CONFIG_HOME",T.pack (base </> "config")),("GHCRTS",T.pack ("-N"<>show capabilities))]],
        "ownership" .= ("service-owned"::Text),"quarantined" .= False,"personAnswering" .= ("local-control"::Text),"resourceKeys" .= [ident]]
  BS.writeFile configPath (encoded (object ["version" .= (1::Int),"managerRoot" .= root,"localRetentionRoots" .= ([]::[Text]),
    "runners" .= [object ["alias" .= ("native"::Text),"executable" .= native,"prefix" .= ([]::[Text])]],
    "profiles" .= map profile profileIds,
    "limits" .= object ["drafts" .= (10::Int),"globalDrafts" .= (20::Int),"globalCaptureBytes" .= (67108864::Int),"globalPageSets" .= (2::Int),"globalConnections" .= (8::Int),"globalDatabaseReaders" .= (2::Int),"globalMutationLedgerBytes" .= (8388608::Int),"safetyControlsPerMinute" .= (20::Int),"executionReservations" .= (2::Int)]]))
  setFileMode configPath 0o600
  let registry=Cli.Registry "approval-check" "workflow" "approval fixture" []
      validate requested=either (const (Left InvalidConfiguration)) Right (Cli.validateManagerTarget registry requested)
      validatePrepared requested prepared=either (const (Left InvalidReply)) Right (Cli.validateManagerPreparedTarget registry requested prepared)
  configuration <- loadConfiguration validate validatePrepared (const False) configPath >>= right
  bracket (installConfiguration configuration >>= right) closeConfiguration $ \installed -> withCoordinationStore installed $ \store -> do
    (_,profiles) <- configurationSnapshot installed >>= right
    catalogues <- forM profiles $ \policy -> do
      catalogue <- probeConfiguredProfile installed (publicId policy) (publicRevision policy) >>= right
      pure (publicId policy,publicRevision policy,catalogue)
    let secret=BS.replicate 32 112
    mutate store $ do
      execute "INSERT INTO clients VALUES ('pair-client','revision','authority',0)" []
      execute "INSERT INTO credentials VALUES ('pair-credential','pair-client',?,'2999-01-01T00:00:00Z',0)" [SQL.SQLBlob (convert (hash secret::Digest SHA256))]
      forM_ profileIds $ \ident -> forM_ ["observe","submit","control"::Text] $ \scope ->
        execute "INSERT INTO credential_scopes VALUES ('pair-credential',?,?)" [SQL.SQLText ident,SQL.SQLText scope]
    proof <- authenticateCredential store secret >>= right
    identity <- storeIdentity store
    let key suffix=storeAuthorityEpoch identity<>"."<>T.replicate 22 "p"<>suffix
    retained <- newIORef []
    outcome <- try @AsyncException $ withAdmissionClock fixedClock store $ \controller -> flip finally release $ do
      forM_ catalogues $ \(profileId,revision,catalogue) -> do
        workflow <- case [ident | (ident,descriptor)<-discoveryEntries catalogue,workflowName descriptor=="parallel-person"] of
          [ident] -> pure ident
          _ -> error "missing real parallel-person workflow"
        draft <- createDraft store proof (key (profileId<>"-create")) (encoded (object ["workflowId" .= workflow,"descriptorRevision" .= discoveryRevision catalogue,"profileId" .= profileId,"profileRevision" .= revision])) >>= right
        _ <- changeDraftInput store proof (draftId draft) (key (profileId<>"-input")) (Just ("\""<>draftRevision draft<>"\"")) (encoded (object ["operation" .= ("set-input"::Text),"input" .= LiteralValue "input" profileId])) >>= right
        ready <- readDraft store proof (draftId draft) >>= right
        _ <- enqueueRequest controller proof (draftId ready) (key (profileId<>"-enqueue")) (Just ("\""<>draftRevision ready<>"\"")) (encoded (object ["operation" .= ("enqueue"::Text)])) >>= right
        pure ()
      forM_ profileIds $ \_ -> do
        live <- admitOldest controller >>= right >>= maybe (error "legitimate pair reservation not admitted") pure
        context <- await (awaitReview live) >>= right
        reviewed <- publishReview store live >>= right
        ident <- runRead store $ do
          rows <- query "SELECT id FROM preparations WHERE request_id=? AND state='live'" [SQL.SQLText (reviewRequest context)]
          case rows of [[SQL.SQLText value]] -> pure value; _ -> refuseTransaction StoreIntegrity
        preparation <- readPreparation store proof ident >>= right
        (_,start) <- acceptApproval reviewed proof (key (P.preparationProfile preparation<>"-approve")) (condition preparation) (approvalBody preparation) >>= right
        owned <- maybe (error "missing original pair approval") pure start
        let association=RunAssociation (acceptedStartRun owned) (P.preparationProfile preparation) (preparedRootIdentity (reviewNative context)) (preparedRunId (reviewNative context))
        modifyIORef' retained (<>[(live,owned,association)])
      entries <- readIORef retained
      number store "SELECT count(*) FROM reservations WHERE state='held'" >>= check "native pair uses two legitimate occupied reservations" . (==2)
      forM_ entries $ \(_,owned,_) -> deliverAcceptedStart owned >>= right
      await $ let rendezvous=readyFiles >>= \names -> if length names==2 then pure () else threadDelay 1000 >> rendezvous in rendezvous
      activeBackends <- readyFiles
      forM_ activeBackends $ \backendName -> do
        observed <- observeProcess (dropExtension backendName)
        check "strict observer sees original live backend" (maybe False (not . null) observed)
      forM_ entries $ \(_,owned,association) -> do
        let ingest=do
              more <- ingestAcceptedStart owned
              unless more (error "native pair ended before both dimensions")
              snapshot <- restoreRunProjection store association
              unless (maybe False (bothDimensions . Runtime.checkpointSnapshot) snapshot) ingest
        await ingest
      forM_ (entries<>reverse entries<>entries) $ \(_,owned,association) -> do
        checkpoint <- restoreRunProjection store association >>= maybe (error "missing native pair projection") pure
        observation <- observeAcceptedStart owned
        check "alternating native run views preserve active attempts and mandatory decisions together" (bothDimensions (Runtime.checkpointSnapshot checkpoint) && Runtime.snapshotRunId (Runtime.checkpointSnapshot checkpoint)==associationNative association && observedWorkerPhase observation==WorkerRunning && observedWorkerExit observation==Nothing)
        BS.writeFile (base </> T.unpack (associationProfile association)<>"-snapshot.json") (encoded (Runtime.runSnapshotValue (Runtime.checkpointSnapshot checkpoint)))
      number store "SELECT count(*) FROM decisions WHERE state='pending' AND question_artifact_id IS NOT NULL" >>= check "both live native runs have independent durable mandatory decisions" . (==2)
      number store "SELECT count(*) FROM requests r JOIN reservations v ON v.request_id=r.id WHERE r.phase='associated' AND v.state='held' AND r.revision=v.request_revision" >>= check "live native pair associates before cleanup with matching held reservations" . (==2)
      let nativeIds=map (associationNative . third) entries
      check "native pair retains distinct original identities" (case nativeIds of [a,b] -> a/=b; _ -> False)
      when gateCheck $ do
        (firstOwner,firstAssociation,secondOwner,secondAssociation)<-case entries of
          [(_,a,aa),(_,b,bb)]->pure(a,aa,b,bb);_->error "missing preparation pair"
        let prepareBody association=runRead store $ do
              rows<-query "SELECT id,occurrence_id,generation,revision FROM decisions WHERE run_id=? AND state='pending'" [SQL.SQLText(associationRun association)]
              case rows of
                [[SQL.SQLText ident,SQL.SQLText occurrence,SQL.SQLText generation,SQL.SQLText revision]] -> pure(ident,Just("\""<>revision<>"\""),encoded(object["operation" .= ("answer"::Text),"occurrenceId" .= occurrence,"generation" .= generation,"value" .= ("Original prepared answer"::Text)]))
                _->refuseTransaction StoreIntegrity
            finishAnswer owned accepted=do
              let command=receiptId(submissionReceipt accepted)
              deliverAcceptedControl owned command >>=right
              await $ let ingest=do
                            receipt<-readCommand store proof command >>=right
                            unless(receiptEffect receipt/=Nothing)(ingestAcceptedStart owned>>ingest)
                      in ingest
        (firstDecision,firstEtag,firstBody)<-prepareBody firstAssociation
        (secondDecision,secondEtag,secondBody)<-prepareBody secondAssociation
        Audit.withReviewAudit ("control-preparation:"<>associationRun firstAssociation) $ \audit ->
          bracket(async(try @AsyncException(submitDecisionControl firstOwner proof firstDecision(key "held-preparation")firstEtag firstBody))) (\job->cancel job>>void(waitCatch job)) $ \held -> do
            originalThread<-Audit.waitReviewed audit
            bracket(async(submitDecisionControl firstOwner proof firstDecision(key "queued-preparation")firstEtag firstBody)) (\job->cancel job>>void(waitCatch job)) $ \queued -> do
              queuedThread<-Audit.waitControlWaiter audit
              await $ let blocked=do
                            status<-threadStatus queuedThread
                            case status of
                              ThreadBlocked BlockedOnMVar -> pure ()
                              _ -> do finishedQueued<-poll queued;case finishedQueued of Just _->error "FAIL same-run preparation holds original queued caller";_->threadDelay 1000>>blocked
                      in blocked
              independent<-submitDecisionControl secondOwner proof secondDecision(key "independent-preparation")secondEtag secondBody >>=right
              finishAnswer secondOwner independent
              check "independent run progresses during held original preparation" True
              if interrupt then do
                throwTo originalThread UserInterrupt
                stopped<-await(wait held)
                check "interrupted preparation preserves original exception" (case stopped of Left UserInterrupt->True;_->False)
                accepted<-await(wait queued) >>=right
                finishAnswer firstOwner accepted
              else do
                Audit.releaseReviewed audit
                accepted<-await(wait held) >>=right >>=right
                queuedResult<-await(wait queued)
                check "original preparation returns fresh acceptance with original ticket before delivery"
                  (not(submissionReplayed accepted) && receiptState(submissionReceipt accepted)==Accepted && receiptAttemptedAt(submissionReceipt accepted)==Nothing && maybe False ((==receiptId(submissionReceipt accepted)) . dispatchCommandId) (submissionTicket accepted))
                check "queued preparation returns exact stale revision before original delivery" (case queuedResult of Left StaleRevision->True;_->False)
                finishAnswer firstOwner accepted
              Audit.releaseReviewed audit
              check "same-run preparation holds original queued caller" True
      unless (interrupt || gateCheck) $ do
        heads <- readDecisionHeads store proof
        let fieldText fieldName (Object fields)=case KM.lookup fieldName fields of Just(String value)->value;_->error "missing head field"
            fieldText _ _=error "missing head object"
        check "global inbox follows manager observation order, independent of selected run"
          (map(fieldText "runId")heads==map(associationRun . third)entries)
        (_,second,association) <- case reverse entries of entry:_->pure entry;_->error "missing independent native run"
        decision <- case [value|value<-heads,fieldText "runId" value==associationRun association] of [value]->pure value;_->error "missing second run head"
        let occurrence=case decision of
              Object fields -> case KM.lookup "address" fields of Just address->fieldText "occurrenceId" address;_->error "missing address"
              _ -> error "missing decision"
            body=encoded(object["operation" .= ("answer"::Text),"occurrenceId" .= occurrence,"generation" .= fieldText "generation" decision,"value" .= ("Independent original run answer"::Text)])
        accepted <- submitDecisionControl second proof(fieldText "id" decision)(key "independent-answer")(Just("\""<>fieldText "revision" decision<>"\""))body >>= right
        deliverAcceptedControl second(receiptId(submissionReceipt accepted)) >>= right
        let ingest=do
              current<-readCommand store proof(receiptId(submissionReceipt accepted)) >>=right
              unless(receiptEffect current/=Nothing)(ingestAcceptedStart second>>ingest)
        await ingest
        remainingHeads <- readDecisionHeads store proof
        check "second run answers while first run remains pending and engines remain active"
          (map(fieldText "runId")remainingHeads==take 1(map(associationRun . third)entries))
      when interrupt (throwIO UserInterrupt)
      release
      forM_ entries $ \(live,owned,_) -> joinControlCleanup live owned
    check "native pair preserves injected caller failure after joined cleanup" (if interrupt then outcome==Left UserInterrupt else outcome==Right ())
    entries <- readIORef retained
    forM_ entries $ \(_,owned,_) -> do
      observation <- observeAcceptedStart owned
      check "original pair workers physically joined on success and failure" (observedWorkerPhase observation==WorkerReleased && not (observedCleanupUnproven observation))
      let drain=ingestAcceptedStart owned >>= \more -> when more drain
      drained <- try @WorkerFailure (await drain)
      remaining <- observeAcceptedStart owned
      check "native pair drains retained evidence after cleanup without replacing its transport outcome" (observedQueuedFrames remaining==0 && case observedWorkerExit observation of Just (Left failure) -> drained==Left failure; Just (Right _) -> drained==Right (); Nothing -> False)
    number store "SELECT count(*) FROM reservations WHERE state!='released'" >>= check "native pair releases reservations only after original cleanup" . (==0)
    names <- readyFiles
    forM_ names $ \name' -> do
      let pid=dropExtension name'
      done <- doesFileExist (barrier </> pid<>".done")
      observed <- observeProcess pid
      check "rendezvoused fixture backend exited through original native cleanup" (done && observed==Nothing)
  where
    third (_,_,value)=value
    bothDimensions snapshot=any Runtime.snapshotOccurrencePersonPending occurrences && any (any ((==Runtime.AttemptRunning) . Runtime.snapshotAttemptState) . Map.elems . Runtime.snapshotOccurrenceAttempts) occurrences
      where occurrences=Map.elems (Runtime.snapshotOccurrences snapshot)
