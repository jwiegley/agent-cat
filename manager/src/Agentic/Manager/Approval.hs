{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | Exact public consent and private binding to one original native preparation.
module Agentic.Manager.Approval
  ( ReviewedPreparation, reviewedView, projectReview, publishReview, readPreparation, acceptApproval, approve, replayApproval,
    AcceptedStart, deliverAcceptedStart, stopAcceptedStart, observeAcceptedStart, acceptedStartRun, acceptedTimerRetired ) where

import Agentic.Manager.Admission
import Agentic.Manager.Drafts (checkLineageParent, assemblyParentBinding)
import Agentic.Manager.Admission.Policy (Resource (..), effectiveResources)
import Agentic.Manager.Authorization
import Agentic.Manager.Commands
import Agentic.Manager.Profile hiding (StaleRevision)
import Agentic.Manager.Protocol.Command
import qualified Agentic.Manager.Protocol.Preparation as P
import Agentic.Manager.Store
import Agentic.Runtime hiding (Control)
import Control.Exception (SomeException, try, throwIO, fromException)
import Control.Monad (unless)
import Crypto.Hash (Digest, SHA256, hash)
import Crypto.Random (getRandomBytes)
import Data.Aeson
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson.Types (parseEither)
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import qualified Data.ByteString as BS
import Data.Char (isSpace,isPunctuation)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Database.SQLite3 as SQL

-- | An original live loan paired with its persisted exact public/private binding.
-- No constructor, Generic or receipt lookup creates this authority.
data ReviewedPreparation = ReviewedPreparation !CoordinationStore !LivePreparation !P.Preparation !BS.ByteString

-- | The already published public review, not another observation or a capability.
reviewedView :: ReviewedPreparation -> P.Preparation
reviewedView (ReviewedPreparation _ _ public _) = public

publishReview :: CoordinationStore -> LivePreparation -> IO (Either CommandFailure ReviewedPreparation)
publishReview store live = attempt $ withReviewAcceptance live $ \context guard -> do
  (workflow,descriptor,expires) <- runRead store $ do
    rows<-query "SELECT r.workflow_id,r.descriptor_revision,o.review_expires_at FROM requests r JOIN admission_observations o ON o.reservation_id=? WHERE r.id=? AND o.state='prepared'"
      [text(reviewReservation context),text(reviewRequest context)]
    case rows of [[SQL.SQLText w,SQL.SQLText d,SQL.SQLText e]]->pure(w,d,e);_->refuseTransaction StateConflict
  public<-need(projectReview workflow context)
  let nativeHash=digest(encoded(reviewNative context))
      contextHash=digest(encoded(contextValue context))
  ident<-fresh "preparation_"
  revision<-fresh "preparation_revision_"
  requestRevision<-fresh "request_revision_"
  nonce<-fresh "binding_"
  published<-withStoreCatalogues store $ \_ _ catalogues->runTransaction store $ do
    unless(currentCatalogue catalogues (P.reviewProfile public) (reviewProfileRevision context) descriptor workflow)(refuseTransaction StaleRevision)
    current<-query "SELECT r.revision,v.request_revision FROM requests r JOIN reservations v ON v.request_id=r.id WHERE r.id=? AND v.id=? AND r.phase='review' AND v.state='held' AND v.process_generation=?"
      [text(reviewRequest context),text(reviewReservation context),text(reviewGeneration context)]
    unless(current==[[text(reviewRequestRevision context),text(reviewRequestRevision context)]])(refuseTransaction StateConflict)
    checkReservation context
    enforceCommitDeadline guard
    rows<-query "SELECT id,revision,request_revision,review_digest,review,private_binding FROM preparations WHERE reservation_id=? AND process_generation=? AND state='live'"
      [text(reviewReservation context),text(reviewGeneration context)]
    case rows of
      [[SQL.SQLText existing,SQL.SQLText oldRevision,SQL.SQLText boundRevision,SQL.SQLText oldDigest,SQL.SQLBlob reviewBytes,SQL.SQLBlob privateBytes]] -> do
        oldPublic<-decodeT reviewBytes
        binding<-decodeT privateBytes
        unless(oldPublic==public && field "nativeSha256" binding==Just(String nativeHash) && field "contextSha256" binding==Just(String contextHash)
          && digest privateBytes==oldDigest && boundRevision==reviewRequestRevision context)(refuseTransaction StateConflict)
        let view=P.Preparation existing oldRevision (reviewRequest context) boundRevision (P.reviewProfile public) (reviewProfileRevision context) descriptor "live" expires oldDigest (reviewGeneration context) oldPublic Nothing
        pure((view,privateBytes),[])
      [] -> do
        let binding=object["domain" .= ("agent-cat/exact-preparation/v1"::Text),"nonce" .= nonce,
              "requestId" .= reviewRequest context,"requestRevision" .= requestRevision,"profileRevision" .= reviewProfileRevision context,
              "descriptorRevision" .= descriptor,"reservationId" .= reviewReservation context,"workerIdentity" .= reviewReservation context,
              "processGeneration" .= reviewGeneration context,"approvalId" .= preparedApprovalId(reviewNative context),
              "nativeRunId" .= runIdText(preparedRunId(reviewNative context)),"rootIdentity" .= preparedRootIdentity(reviewNative context),
              "expiresAt" .= expires,"invocation" .= preparedInvocation(reviewNative context),
              "targetArguments" .= preparedTargetArguments(reviewNative context),"targetKind" .= preparedTargetKind(reviewNative context),
              "nativeSha256" .= nativeHash,"contextSha256" .= contextHash,"reviewSha256" .= digest(encoded public)]
            privateBytes=encoded binding
            checksum=digest privateBytes
            view=P.Preparation ident revision (reviewRequest context) requestRevision (P.reviewProfile public) (reviewProfileRevision context) descriptor "live" expires checksum (reviewGeneration context) public Nothing
        unless(BS.length(encoded view)+BS.length privateBytes+4096<=1048576)(refuseTransaction ViewTooLarge)
        execute "INSERT INTO preparations VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,'live',NULL)"
          [text ident,text revision,text(reviewRequest context),text requestRevision,text(reviewProfileRevision context),text(reviewReservation context),text(reviewGeneration context),
           text(reviewReservation context),text(preparedRootIdentity(reviewNative context)),text(runIdText(preparedRunId(reviewNative context))),text expires,text checksum,SQL.SQLBlob(encoded public),SQL.SQLBlob privateBytes]
        execute "INSERT INTO preparation_captures SELECT ?,capture_id FROM request_inputs WHERE request_id=? AND capture_id IS NOT NULL GROUP BY capture_id" [text ident,text(reviewRequest context)]
        execute "UPDATE requests SET revision=? WHERE id=?" [text requestRevision,text(reviewRequest context)]
        execute "UPDATE reservations SET request_revision=? WHERE id=?" [text requestRevision,text(reviewReservation context)]
        pure((view,privateBytes),[Invalidation "preparation.changed" (preparationURI ident) revision,Invalidation "request.changed" (requestURI(reviewRequest context))requestRevision])
      _->refuseTransaction StateConflict
  (view,binding)<-either(const(throwIO StorageUnavailable))pure published
  pure(ReviewedPreparation store live view binding)

readPreparation :: CoordinationStore -> CredentialProof -> Text -> IO (Either CommandFailure P.Preparation)
readPreparation store proof ident = attemptIO $ do
  unless(validId ident)(throwIO InvalidRequest)
  result<-withStoreConfiguration store $ \_ profiles -> runRead store $ do
    _<-currentClient proof >>= needT
    metadata<-query "SELECT r.profile_id FROM preparations p JOIN requests r ON r.id=p.request_id WHERE p.id=? AND EXISTS(SELECT 1 FROM credential_scopes s WHERE s.credential_id=? AND s.profile_id=r.profile_id AND s.scope='observe')" [text ident,text(credentialRateKey proof)]
    profile<-case metadata of [[SQL.SQLText value]] | value `elem` map publicId profiles ->pure value;_->refuseTransaction Forbidden
    _<-authorizeProfile proof profile [Observe] >>= needT
    generation<-transactionGeneration
    rows<-query "SELECT p.id,p.revision,p.request_id,p.request_revision,r.profile_id,p.profile_revision,r.descriptor_revision,p.state,p.expires_at,p.review_digest,p.process_generation,p.review,p.reason,p.private_binding FROM preparations p JOIN requests r ON r.id=p.request_id WHERE p.id=?" [text ident]
    view<-case rows of
      [[SQL.SQLText a,SQL.SQLText b,SQL.SQLText c,SQL.SQLText d,SQL.SQLText e,SQL.SQLText f,SQL.SQLText g,SQL.SQLText h,SQL.SQLText i,SQL.SQLText j,SQL.SQLText k,SQL.SQLBlob body,reason,SQL.SQLBlob privateBytes]] ->do
        public<-decodeT body
        binding<-decodeT privateBytes
        unless(digest privateBytes==j && field "reviewSha256" binding==Just(String(digest(encoded(public::P.Review)))))(refuseTransaction StorageUnavailable)
        why<-case reason of SQL.SQLNull->pure Nothing;SQL.SQLText value->pure(Just value);_->refuseTransaction StorageUnavailable
        pure(P.Preparation a b c d e f g h i j k public why)
      _->refuseTransaction ResourceUnavailable
    _<-needT(either(const(Left StorageUnavailable))Right(parseEither parseJSON(toJSON view))::Either CommandFailure P.Preparation)
    unless(P.preparationGeneration view==generation)(refuseTransaction ResourceUnavailable)
    pure view
  either(const(throwIO StorageUnavailable))pure result

acceptApproval :: ReviewedPreparation -> CredentialProof -> Text -> Maybe Text -> BS.ByteString -> IO (Either CommandFailure (Submission,Maybe AcceptedStart))
acceptApproval = acceptApprovalWithDelivery False

acceptApprovalWithDelivery :: Bool -> ReviewedPreparation -> CredentialProof -> Text -> Maybe Text -> BS.ByteString
  -> IO (Either CommandFailure (Submission,Maybe AcceptedStart))
acceptApprovalWithDelivery dispatch (ReviewedPreparation store live preparation privateBytes) proof key precondition body = attempt $ do
  selectors<-need(P.decodeApproval body)
  requestRevision<-fresh "request_revision_"
  preparationRevision<-fresh "preparation_revision_"
  run<-fresh "run_"
  let request=CommandRequest Approve (P.preparationProfile preparation) "POST" (preparationURI(P.preparationId preparation)) key "application/json" precondition body
      builder context command _ catalogues = do
        unless(currentCatalogue catalogues (P.preparationProfile preparation) (P.preparationProfileRevision preparation) (P.preparationDescriptorRevision preparation) (P.reviewWorkflow(P.preparationReview preparation)))(Left StaleRevision)
        Right $ Mutation (P.preparationProfileRevision preparation) version $ do
          unless(selectors==P.ApprovalRequest (P.preparationDigest preparation) (P.preparationRequestRevision preparation) (P.preparationProfileRevision preparation) (P.preparationDescriptorRevision preparation) (P.preparationGeneration preparation))(refuseTransaction StateConflict)
          unless(reviewRequestRevision context==P.preparationRequestRevision preparation && reviewProfileRevision context==P.preparationProfileRevision preparation && reviewGeneration context==P.preparationGeneration preparation)(refuseTransaction StateConflict)
          checkReservation context
          parents <- query "SELECT parent_run_id FROM requests WHERE id=?" [text(reviewRequest context)]
          case parents of
            [[SQL.SQLText parent]] -> checkLineageParent parent
            [[SQL.SQLNull]] -> pure ()
            _ -> refuseTransaction StateConflict
          rows<-query "SELECT request_id,request_revision,profile_revision,reservation_id,process_generation,worker_identity,root_identity,native_run_id,review_digest,review,private_binding,state FROM preparations WHERE id=?" [text(P.preparationId preparation)]
          let native=reviewNative context
              expected=[text(reviewRequest context),text(reviewRequestRevision context),text(reviewProfileRevision context),text(reviewReservation context),text(reviewGeneration context),text(reviewReservation context),text(preparedRootIdentity native),text(runIdText(preparedRunId native)),text(P.preparationDigest preparation),SQL.SQLBlob(encoded(P.preparationReview preparation)),SQL.SQLBlob privateBytes,text "live"]
          unless(rows==[expected])(refuseTransaction StateConflict)
          binding<-decodeT privateBytes
          unless(field "nativeSha256" binding==Just(String(digest(encoded native))) && field "contextSha256" binding==Just(String(digest(encoded(contextValue context)))))(refuseTransaction StateConflict)
          client<-currentClient proof >>= needT
          pure $ Right $ Intent (CommandReferences(Just(reviewRequest context))(Just run)(Just(P.preparationId preparation))Nothing) True $ do
            execute "INSERT INTO runs(id,revision,control_revision,request_id,preparation_id,profile_id,root_identity,native_run_id,parent_run_id,supervision,result_state) VALUES (?,?,?,?,?,?,?,?,(SELECT parent_run_id FROM requests WHERE id=?),'owned','absent')"
              (map text [run,run,run,reviewRequest context,P.preparationId preparation,P.preparationProfile preparation,preparedRootIdentity native,runIdText(preparedRunId native),reviewRequest context])
            execute "INSERT INTO start_intents VALUES (?,?,?,?,?,?,?,?)"
              (map text [command,client,reviewRequest context,P.preparationId preparation,run,reviewReservation context,reviewGeneration context,reviewReservation context])
            execute "UPDATE preparations SET state='consumed',reason='consumed',revision=? WHERE id=?" [text preparationRevision,text(P.preparationId preparation)]
            execute "UPDATE requests SET phase='start-pending',revision=? WHERE id=?" [text requestRevision,text(reviewRequest context)]
            execute "UPDATE reservations SET request_revision=? WHERE id=?" [text requestRevision,text(reviewReservation context)]
            execute "UPDATE admission_observations SET state='handed-off' WHERE reservation_id=?" [text(reviewReservation context)]
            pure([Invalidation "preparation.changed" (preparationURI(P.preparationId preparation))preparationRevision,Invalidation "request.changed" (requestURI(reviewRequest context))requestRevision,Invalidation "run.changed" ("/v1/runs/"<>run)run],Nothing)
      version=do
        _<-authorizeProfile proof (P.preparationProfile preparation) [Submit,Control] >>= needT
        rows<-query "SELECT revision FROM preparations WHERE id=?" [text(P.preparationId preparation)]
        case rows of [[SQL.SQLText revision]]->pure(Just(preparationURI(P.preparationId preparation),P.preparationProfile preparation,revision));_->pure Nothing
  result <- (if dispatch then acceptAndDeliverStartCommand else acceptStartCommand) live proof request builder
  case result of
    Left StaleRevision -> do
      current<-withStoreCatalogues store $ \_ _ catalogues->pure $ case lookup(P.preparationProfile preparation)catalogues of
        Just catalogue->discoveryProfileRevision catalogue==P.preparationProfileRevision preparation && discoveryRevision catalogue==P.preparationDescriptorRevision preparation
        Nothing->False
      case current of
        Right False -> do
          _<-invalidateLivePreparation live "profile-changed"
          pure result
        _->pure result
    _->pure result

approve :: ReviewedPreparation -> CredentialProof -> Text -> Maybe Text -> BS.ByteString -> IO (Either CommandFailure CommandReceipt)
approve prepared proof key precondition body =
  fmap (fmap (submissionReceipt . fst)) (acceptApprovalWithDelivery True prepared proof key precondition body)

-- | Resolve an exact cached receipt without recovering any live preparation.
replayApproval :: CoordinationStore -> CredentialProof -> Text -> Text -> Maybe Text -> BS.ByteString
  -> IO (Either CommandFailure CommandReceipt)
replayApproval store proof ident key precondition body = attemptIO $ do
  unless (validId ident) (throwIO InvalidRequest)
  _ <- need (P.decodeApproval body)
  profile <- runRead store $ do
    _ <- currentClient proof >>= needT
    rows <- query "SELECT r.profile_id FROM preparations p JOIN requests r ON r.id=p.request_id WHERE p.id=?" [text ident]
    selected <- case rows of
      [[SQL.SQLText value]] -> pure value
      _ -> refuseTransaction Forbidden
    _ <- authorizeProfile proof selected [Submit,Control] >>= needT
    pure selected
  let request = CommandRequest Approve profile "POST" (preparationURI ident) key "application/json" precondition body
  submissionReceipt <$> (submitConfiguredCommand store proof request (\_ _ _ -> Left OwnershipUnavailable) >>= need)

projectReview :: Text -> ReviewContext -> Either CommandFailure P.Review
projectReview workflow context = do
  let native=reviewNative context
      selected=selectionContext(reviewSelection context)
      descriptor=preparedDescriptor native
  _<-either(const(Left InvalidInput))Right(operatorPreparedTarget selected native)
  (summary,program)<-either(const(Left InvalidInput))Right(parseEither parseExactPlan(preparedPlan native))
  let exact=exactPlanDescriptor summary
  unless(workflowName exact==workflowName descriptor && workflowInputs exact==workflowInputs descriptor && workflowRunnerVersion exact==workflowRunnerVersion descriptor)(Left InvalidInput)
  unless([(preparedInputName input,T.pack(show(preparedInputBytes input)),preparedInputSha256 input)|input<-preparedInputs native]==[(P.reviewInputName input,P.reviewInputBytes input,P.reviewInputSha256 input)|input<-reviewInputSummaries context])(Left InvalidInput)
  policy<-P.projectPolicy(preparedPolicy native)
  _<-either(const(Left InvalidInput))Right(parseEither answerSchemaForObservationCode(workflowResultCode exact))
  let plan=TE.decodeUtf8(encoded(preparedPlan native))
  unless(T.length plan<=524288 && BS.length(TE.encodeUtf8 plan)<=1048576)(Left ViewTooLarge)
  let protected=privateValues context
      content=stringLeaves program <> [workflowName exact,workflowBlurb exact,workflowLevel exact] <> map workflowInputName(workflowInputs exact) <> P.observationCodeNames(workflowResultCode exact) <> workflowRunFacts exact <> workflowPins exact <> policyLabels(P.policyValue policy)
  unless(all (safeText protected) content)(Left InvalidInput)
  let person=case preparedPersonAnswering native of PersonAnswerEngine->"engine";PersonAnswerLocalControl->"local-control"
      public=P.Review (preparedProgramHash native)person policy workflow (operatorId selected) (operatorWorkspaceLabel selected) (operatorTargetLabel selected)
        (reviewInputSummaries context) plan (workflowRunFacts exact) (workflowPins exact) [] (workflowResultCode exact)
  either(const(Left ViewTooLarge))Right(parseEither parseJSON(toJSON public))

privateValues :: ReviewContext -> [Text]
privateValues context = filter (not.T.null) $
  map (T.pack.snd)(operatorEnvironment selected) <> map T.pack[operatorCwd selected,operatorExecutable selected,preparedCwd native]
  <> [directory] <> files <> privateFields(preparedPolicy native)
  <> concatMap argumentPaths(map T.pack(operatorPrefix selected)<>operatorTargetArguments selected<>preparedTargetArguments native)
  where
    selected=selectionContext(reviewSelection context)
    native=reviewNative context
    (directory,inputs)=case reviewSetup context of RootSetup setup->(T.pack(setupDirectory setup),setupInputs setup);DerivedSetup root _ _ _ _ _->(T.pack root,[])
    files=[T.pack path|(_,File path)<-inputs]
    privateFields (Object value)=concat [if Key.toText key `elem` ["scratch","binary","routingSources","source","path","privateReference","token","password","apiKey","api_key","secret","authorization","options","providerOptions","provider-options"] then stringLeaves child else privateFields child|(key,child)<-KM.toList value]
    privateFields (Array values)=concatMap privateFields values
    privateFields _=[]
    pathLike value=T.isPrefixOf "/" value || T.isInfixOf "://" value
    argumentPaths value=filter pathLike [value,T.drop 1(snd(T.breakOn "=" value))]

safeText :: [Text] -> Text -> Bool
safeText protected value=not(any (`T.isInfixOf` value) protected) && not(credentialText value)
credentialText :: Text -> Bool
credentialText value=any argument (zip tokens (drop 1 tokens)) || any separated (zip3 tokens (drop 1 tokens) (drop 2 tokens)) || bearer || uriCredentials
  where
    lower=T.toLower value
    tokens=T.words(T.concatMap token lower)
    token c
      | c `elem` (":="::String) = T.pack [' ',c,' ']
      | c=='`' || (isPunctuation c && c `notElem` ("-_"::String)) = " "
      | otherwise = T.singleton c
    names=["authorization","api_key","api-key","access_token","access-token","token","password","passwd","secret","client-secret"]
    flags=map("--"<>)names
    argument (key,value')=key `elem` flags && value' `notElem` [":","="] && not("--" `T.isPrefixOf` value')
    separated (key,separator,value')=key `elem` (names<>flags) && separator `elem` [":","="] && not(T.null value')
    bearer=case tokens of "bearer":_:_->True;_->False
    uriCredentials=any (\(_,rest)->"@" `T.isInfixOf` T.takeWhile(\c->not(isSpace c) && c `notElem` ("/?#"::String))(T.drop 3 rest)) (T.breakOnAll "://" lower)

policyLabels :: Value -> [Text]
policyLabels (Object values)=concat[if Key.toText key `elem` ["kind","coverage","thinking","personaSource","policyDigest","executionFingerprint"] then [] else policyLabels child|(key,child)<-KM.toList values]
policyLabels (Array values)=concatMap policyLabels values
policyLabels (String value)=[value]
policyLabels _=[]
stringLeaves :: Value -> [Text]
stringLeaves (Object values)=concatMap stringLeaves(KM.elems values)
stringLeaves (Array values)=concatMap stringLeaves values
stringLeaves (String value)=[value]
stringLeaves _=[]

checkReservation :: ReviewContext -> Transaction ()
checkReservation context = do
  let resources=Set.toAscList(effectiveResources(operatorResourceKeys(selectionContext(reviewSelection context))))
      pair UnclassifiedResource=["unclassified",""::Text]
      pair (OperatorResource key)=["operator",key]
      expected=TE.decodeUtf8(encoded(map pair resources))
  rows<-query "SELECT json_group_array(json_array(kind,resource_key))=? FROM (SELECT kind,resource_key FROM reservation_resources WHERE reservation_id=? ORDER BY kind,resource_key)"
    [text expected,text(reviewReservation context)]
  unless(rows==[[SQL.SQLInteger 1]])(refuseTransaction StateConflict)

currentCatalogue :: [(Text,Discovery)] -> Text -> Text -> Text -> Text -> Bool
currentCatalogue catalogues profile revision descriptor workflow=case lookup profile catalogues of
  Just value->discoveryProfileRevision value==revision && discoveryRevision value==descriptor && any((==workflow).fst)(discoveryEntries value)
  Nothing->False

contextValue :: ReviewContext -> Value
contextValue context=object["invocation" .= selectionInvocation(reviewSelection context),"cwd" .= operatorCwd selected,
  "arguments" .= operatorTargetArguments selected,"environment" .= operatorEnvironment selected,
  "resourceKeys" .= operatorResourceKeys selected,"personAnswering" .= operatorPersonAnswering selected,
  "ownership" .= (case operatorOwnership selected of ServiceOwned->("service-owned"::Text);ClientBound->"client-bound"),
  "quarantined" .= operatorQuarantined selected,"limits" .= limits,
  "parentManifestSha256" .= fmap digest (assemblyParentBinding (reviewAssembly context))]
  where
    selected=selectionContext(reviewSelection context)
    config=operatorConfigurationLimits selected
    limits=map ($ config)[limitDrafts,limitGlobalDrafts,limitGlobalCaptureBytes,limitGlobalPageSets,limitGlobalConnections,limitGlobalDatabaseReaders,limitGlobalMutationLedgerBytes,limitSafetyControlsPerMinute,limitExecutionReservations]
digest :: BS.ByteString -> Text
digest bytes=T.pack(show(hash bytes::Digest SHA256))
fresh :: Text -> IO Text
fresh prefix=do bytes<-getRandomBytes 24::IO BS.ByteString;pure(prefix<>TE.decodeUtf8(convertToBase Base16 bytes))
field :: Key.Key -> Value -> Maybe Value
field name (Object object')=KM.lookup name object'
field _ _=Nothing
text :: Text -> SQL.SQLData
text=SQL.SQLText
preparationURI,requestURI :: Text -> Text
preparationURI ident="/v1/preparations/"<>ident
requestURI ident="/v1/requests/"<>ident
need :: Either CommandFailure a -> IO a
need=either throwIO pure
needT :: Either CommandFailure a -> Transaction a
needT=either refuseTransaction pure
decodeT :: FromJSON a => BS.ByteString -> Transaction a
decodeT=either(const(refuseTransaction StorageUnavailable))pure.eitherDecodeStrict'
attempt :: IO (Either CommandFailure a) -> IO (Either CommandFailure a)
attempt action=attemptIO(action >>= need)
attemptIO :: IO a -> IO (Either CommandFailure a)
attemptIO action=do
  result<-try @SomeException action
  case result of
    Right value->pure(Right value)
    Left failure->case fromException failure of
      Just reason->pure(Left reason)
      Nothing->case fromException failure::Maybe StoreFailure of Just _->pure(Left StorageUnavailable);Nothing->throwIO failure
