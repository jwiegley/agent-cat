{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
module Main (main) where

import qualified Agentic.Cli as Cli
import Agentic.Manager.Admission
import Agentic.Manager.Approval
import Agentic.Manager.Authorization
import Agentic.Manager.Commands
import Agentic.Manager.Configuration
import Agentic.Manager.Drafts
import Agentic.Manager.Profile hiding (StaleRevision)
import Agentic.Manager.Protocol.Command
import Agentic.Manager.Protocol.Draft
import qualified Agentic.Manager.Protocol.Preparation as P
import Agentic.Manager.Store
import qualified Agentic.Manager.Test.AcceptanceAudit as Audit
import Agentic.Manager.Worker (WorkerObservation (..),WorkerPhase (..))
import Agentic.Runtime (workflowName, FrontendPrepared (..), RunId (..), FrontendPreparedInput (..))
import Control.Concurrent (threadDelay,throwTo)
import Control.Concurrent.Async (async,wait,waitCatch,cancel)
import Control.Concurrent.MVar (newEmptyMVar,putMVar,takeMVar)
import Control.Concurrent.STM hiding (check)
import qualified Control.Concurrent.STM as STM
import Control.DeepSeq (NFData)
import Control.Exception (bracket,try,fromException,AsyncException (UserInterrupt))
import Control.Monad (unless,forM_,void,when)
import Crypto.Hash (Digest,SHA256,hash)
import Data.Aeson (Value (..),toJSON,object,(.=),eitherDecodeStrict')
import qualified Data.Aeson.KeyMap as KM
import Data.ByteArray (convert)
import qualified Data.ByteString as BS
import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Database.SQLite3 as SQL
import System.Directory (createDirectory,createDirectoryIfMissing,doesFileExist)
import System.Process (readProcessWithExitCode)
import System.Exit (ExitCode (..))
import System.Info (os)
import System.Environment (getArgs)
import System.FilePath ((</>))
import System.IO (BufferMode (LineBuffering),hSetBuffering,stdout)
import System.Posix.Files (setFileMode)
import System.Timeout (timeout)

main :: IO ()
main=do
  hSetBuffering stdout LineBuffering
  args<-getArgs
  case args of
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
withReadyRunner work native prefix selectedWorkflow name arguments environment action=do
  let root=work </> name;path=work </> (name<>".json")
  createDirectory root;setFileMode root 0o700
  BS.writeFile path(encoded(object["version" .= (1::Int),"managerRoot" .= root,"localRetentionRoots" .= ([]::[String]),
    "runners" .= [object["alias" .= ("native"::Text),"executable" .= native,"prefix" .= prefix]],
    "profiles" .= [object["id" .= ("profile"::Text),"runner" .= ("native"::Text),"workspace" .= work,"workspaceLabel" .= ("Review workspace"::Text),"targetLabel" .= ("Deterministic worker"::Text),
      "targetArguments" .= arguments,"environment" .= [object["name" .= envName,"value" .= value]|(envName,value)<-[("TMPDIR",T.pack work),("XDG_CONFIG_HOME",T.pack(work </> "config"))]<>environment],
      "ownership" .= ("service-owned"::Text),"quarantined" .= False,"personAnswering" .= ("local-control"::Text),"resourceKeys" .= ["shared"::Text]]],
    "limits" .= object["drafts" .= (10::Int),"globalDrafts" .= (20::Int),"globalCaptureBytes" .= (67108864::Int),"globalPageSets" .= (2::Int),"globalConnections" .= (8::Int),"globalDatabaseReaders" .= (2::Int),"globalMutationLedgerBytes" .= (8388608::Int),"safetyControlsPerMinute" .= (20::Int),"executionReservations" .= (1::Int)]]))
  setFileMode path 0o600
  let registry=Cli.Registry "approval-check" "workflow" "approval fixture" []
      validate requested=either(const(Left InvalidConfiguration))Right(Cli.validateManagerTarget registry requested)
      validatePrepared requested nativePrepared=either(const(Left InvalidReply))Right(Cli.validateManagerPreparedTarget registry requested nativePrepared)
  config<-loadConfiguration validate validatePrepared (const False) path >>=right
  bracket (installConfiguration config >>=right) closeConfiguration $ \installed->withCoordinationStore installed $ \store->do
    (_,profiles)<-configurationSnapshot installed >>=right
    policy<-case profiles of [profile]->pure(publicRevision profile);_->error "profile count"
    catalogue<-probeConfiguredProfile installed "profile" policy>>=right
    let secret=BS.replicate 32 97
    mutate store $ do
      execute "INSERT INTO clients VALUES ('client','revision','authority',0)" []
      execute "INSERT INTO credentials VALUES ('credential','client',?,'2999-01-01T00:00:00Z',0)" [SQL.SQLBlob(convert(hash secret::Digest SHA256))]
      forM_ ["observe","submit","control"::Text] $ \scope->execute "INSERT INTO credential_scopes VALUES ('credential','profile',?)" [SQL.SQLText scope]
    proof<-authenticateCredential store secret>>=right
    identity<-storeIdentity store
    let key suffix=storeAuthorityEpoch identity<>"."<>T.replicate 22 "n"<>suffix
        etag view=Just("\""<>draftRevision view<>"\"")
    workflow<-case [ident|(ident,descriptor)<-discoveryEntries catalogue,workflowName descriptor==selectedWorkflow]of [ident]->pure ident;_->error "native workflow"
    draft<-createDraft store proof (key "create") (encoded(object["workflowId" .= workflow,"descriptorRevision" .= discoveryRevision catalogue,"profileId" .= ("profile"::Text),"profileRevision" .= policy]))>>=right
    _<-changeDraftInput store proof (draftId draft) (key "input") (etag draft) (encoded(object["operation" .= ("set-input"::Text),"input" .= LiteralValue "input" "Consent for this exact worker."]))>>=right
    ready<-readDraft store proof(draftId draft)>>=right
    action(Fixture root installed store proof key ready)

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
  context<-await(awaitReview live)>>=right
  reviewed<-publishReview store live>>=right
  ident<-runRead store $ do
    rows<-query "SELECT id FROM preparations WHERE state='live'" []
    case rows of [[SQL.SQLText value]]->pure value;_->refuseTransaction StoreIntegrity
  public<-readPreparation store proof ident>>=right
  action controller live context reviewed public

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

nativePresent :: FilePath -> ReviewContext -> IO Bool
nativePresent native context=nativeIdentityPresent native(runIdText(preparedRunId(reviewNative context)))
nativeIdentityPresent :: FilePath -> Text -> IO Bool
nativeIdentityPresent native identity=do
  pid<-case T.splitOn "-" identity of ["native",value,_] | T.all(\c->c>='0' && c<='9')value->pure(T.unpack value);_->error "native fixture identity"
  let observer=if os=="darwin" then "/bin/ps" else "ps"
  result@(code,output,diagnostic)<-readProcessWithExitCode observer ["-p",pid,"-o","pid=,command="] ""
  if not(null diagnostic) then error("process observation failed: "<>show result) else case code of
    ExitSuccess | not(null(words output))->pure(T.pack native `T.isInfixOf` T.pack output)
    ExitFailure 1 | null(words output)->pure False
    _->error("process observation failed: "<>show result)

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
  number store "SELECT count(*) FROM invalidations WHERE kind='run.changed'" >>=check "original stop publishes both run supervision invalidations" . (==3)
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
  revisions<-texts store "SELECT revision FROM invalidations WHERE kind='run.changed' ORDER BY length(sequence),sequence"
  resources<-texts store "SELECT resource_uri FROM invalidations WHERE kind='run.changed' ORDER BY length(sequence),sequence"
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
    revisions<-texts store "SELECT revision FROM invalidations WHERE kind='run.changed' ORDER BY length(sequence),sequence"
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
