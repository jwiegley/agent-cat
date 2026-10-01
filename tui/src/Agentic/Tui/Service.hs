{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Public manager observations used by the existing terminal presentation.
-- These records carry no local launch, process, filesystem or control authority.
module Agentic.Tui.Service
  ( Endpoint (..), decodeEndpoint, clientIdentity, connectEndpoint, missingScope,
    Profile (..), Workflow (..), loadProfiles, loadWorkflows, loadProfileWorkflows,
    decodeProfile, decodeWorkflow, createBody,
    Mutation (..), mutationOperation, mutationURI, mutationProfile, prepareMutation,
    observeDraft, observePreparation, observeReceipt, requestMatches, reviewMatches, reviewLive,
    requestReady, literalInputs, suppliedName, receiptMatches, receiptEffectKind, captureMatches, capturedReceipt, captureLimit, readCaptureFile,
    approvalBody, approvalSelectors,
    RunObservation (..), ResultReference (..), Verification (..), Artifact (..),
    ControlView (..), ControlOffer (..), DecisionView (..), DecisionContent (..), EditorSchema (..), editorCheck, editorSchemaText,
    observeSnapshot, observeControl, observeDecision, observeResult, decodeSnapshot, decodeControl, decodeDecision,
    RunItem (..), RunContent (..), KnownRun (..), OverviewMember (..), decodeRequestItem, decodeRunItem, decodeOverviewMember,
    decodeOverviewItem, OverviewRow (..), overviewRows, overviewStatus, overviewRowKey, OverviewOpen (..), overviewOpen,
    loadDecisions, decodeDecisionHeads, decisionRows, decisionsStatus, decisionsOpen, decisionAddressee,
    loadHistory, decodeHistory, historyLegacy, historyRows, historyStatus, HistoryDetail (..), historyDetailRun,
    observeHistoryDetail, historyRetrievable, historyDetailLines,
    decisionPrompt, answerValue, answerOffered, retryOffer, headMatches,
    DecisionHead (..), decisionHead, answerMutation, answerKey, answerBody,
    retryMutation, retryBody, retryEffect,
    cancelOffered, cancelMutation, steerOffer, steerMutation, steerBody, recoveryOffer, chooseRecoveryMutation, chooseRecoveryBody,
    redirectOffer, redirectMutation, redirectBody, redirectLines,
    controlMutation, controlMutationRun, controlOutcome, controlLines,
    runTerminal, resultWanted, resultReferenced, decodeOutputs, VerifiedResult (..), retrieveResult, resultLines,
    observedBinding, RunRead (..), RequestRead (..), Selection (..), selectedRun, compositeResources, ReadVerdict (..), readVerdict, runReadValid,
    readRequestId, readRequestRun, runtimeStatus, observationLines,
    approvalStatus, receiptSettlement,
    ExportReceipt (..), ExportCollection (..), ExportProgress (..), ExportOutcome (..), exportsURI, exportNameValid,
    exportSource, exportMutation, observeExports, decodeExportCollection, decodeExportReceipt, observeExport, exportLines,
    LineageChoice (..), lineageChoiceName, LineageCollection (..), LineageProgress (..), LineageOutcome (..), ForkTarget (..),
    LineageMenu (..), LineageMode (..), lineageURI, lineageBody, decodeLineageCollection, observeLineageCollection, forkTargets,
    forkReplacement, lineageMenu, lineageMutation, lineageForkChoice, forkToggleDrop, forkKeep, forkSetReplacement,
    forkFocused, lineageMenuLines, observeLineageCommand, lineageLines
  ) where

import qualified Agentic.Manager.Client as C
import Agentic.Runtime
  ( DescriptorCapabilities (..), WorkflowDescriptor (..),
    WorkflowInputDescriptor (..), WorkflowInputSource (..), frontendLiteralBytes,
    RunSnapshot (..), RunStatus (..), OccurrenceSnapshot (..), OccurrenceState (..),
    AttemptSnapshot (..), AttemptState (..), AttemptId (..), OccurrenceId (..),
    DispatchSnapshot (..), RecoverySnapshot (..), RecoveryChosen (..), RecoveryOption (..),
    SteerSnapshot (..), ControlAckSnapshot (..), PublicToolUpdate (..), PublicTodoItem (..),
    PublicUsage (..), FailureClass (..), PersonAnswering (..), RunId (runIdText), mkRunId, FrontendEdit (..) )
import Agentic.Tui.Person (PersonPrompt (..), personAnswerValue)
import Agentic.Tui.RunModel (runStatusLabel)
import Control.Exception (IOException, finally, onException, try)
import Control.Monad (unless, when, (>=>))
import Data.Scientific (toBoundedInteger)
import System.FilePath (isAbsolute)
import System.IO (hClose)
import System.Posix.Files (getFdStatus, isRegularFile)
import System.Posix.IO (OpenFileFlags (cloexec, nonBlock), OpenMode (ReadOnly), closeFd, defaultFileFlags, fdToHandle, openFd)
import Crypto.Hash (Digest, SHA256, hash)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import qualified Data.Map.Strict as Map
import Data.Time.Clock (UTCTime)
import Data.Time.Format.ISO8601 (iso8601ParseM)
import Data.Aeson (Object, Value (..), encode, object, parseJSON, toJSON, withArray, withObject, withText, (.:), (.=))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson.Types (Parser, parseEither)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Vector as V
import Data.Word (Word32, Word64)
import Data.List (sortOn)
import Data.Maybe (fromMaybe, isJust, isNothing, listToMaybe)
import qualified Data.Text.Encoding as TE
import Data.Text.Encoding.Error (lenientDecode)

-- | The identity of the manager endpoint of one session, for display: the
-- host and port of the client profile endpoint, and the stream identifier,
-- the authority epoch and the credential scopes of the verified capabilities.
data Endpoint = Endpoint
  { endpointHost :: !Text, endpointPort :: !Int, endpointStream :: !Text,
    endpointAuthority :: !Text, endpointScopes :: ![Text]
  } deriving (Eq, Show)

-- | The endpoint identity of a host, a port and a capabilities document. A
-- document without a string @streamId@, a string @authorityEpoch@ and a list
-- of string @scopes@ refuses with 'C.InvalidResponse'.
decodeEndpoint :: (Text, Int) -> Value -> Either C.ClientFailure Endpoint
decodeEndpoint (host, port) = decode $ withObject "capabilities" $ \fields ->
  Endpoint host port <$> fields .: "streamId" <*> fields .: "authorityEpoch" <*> fields .: "scopes"

-- | The endpoint identity of a connected session.
clientIdentity :: C.Client -> Either C.ClientFailure Endpoint
clientIdentity client = decodeEndpoint (C.clientEndpoint client) (C.clientCapabilities client)

-- | Connect one explicitly supplied client profile and take the endpoint
-- identity of the new session. A session whose capabilities give no
-- identity is closed before the failure returns.
connectEndpoint :: FilePath -> IO (Either C.ClientFailure (C.Client, Endpoint))
connectEndpoint profile = C.connectClientProfile profile >>= \connected -> case connected of
  Left failure -> pure (Left failure)
  Right client -> case clientIdentity client of
    Left failure -> Left failure <$ C.closeClient client
    Right identity -> pure (Right (client, identity))

-- | The first scope that the manager requires for the named operation and
-- that the given credential scopes do not list. The manager rule
-- 'C.requiredScopes' decides the required scopes. A name that is not a
-- manager operation requires no scope here, because no key sends it.
missingScope :: [Text] -> Text -> Maybe Text
missingScope granted operation = do
  known <- C.parseOperation operation
  listToMaybe [scope | scope <- map C.scopeName (C.requiredScopes known), scope `notElem` granted]

-- | One configured execution profile's public identity and readiness.
data Profile = Profile
  { profileId :: !Text, profileRevision :: !Text,
    profileWorkspace :: !Text, profileTarget :: !Text,
    profileReadiness :: !Text, profileRefusal :: !(Maybe Text)
  } deriving (Eq, Show)

-- | A catalogue row and its display-only descriptor projection.
-- Omitted native protocol lists and descriptors are not negotiated capabilities.
data Workflow = Workflow
  { workflowId :: !Text, workflowRevision :: !Text,
    workflowProfile :: !Text, workflowProfileRevision :: !Text,
    workflowDisplay :: !WorkflowDescriptor, workflowHelp :: !Text
  } deriving (Eq, Show)

loadProfiles :: C.Client -> IO (Either C.ClientFailure [Profile])
loadProfiles client = collection client "/v1/profiles" $ \values ->
  traverse parseProfile values >>= uniqueBy profileId

loadWorkflows :: C.Client -> Profile -> IO (Either C.ClientFailure [Workflow])
loadWorkflows client profile
  | profileReadiness profile /= "ready" || profileRefusal profile /= Nothing =
      pure (Left (C.Refused 409 "state-conflict"))
  | otherwise = collection client ("/v1/workflows?profileId=" <> profileId profile) $ \values -> do
      rows <- traverse parseWorkflow values >>= uniqueBy workflowId
      unless (all (\row -> workflowProfile row == profileId profile &&
        workflowProfileRevision row == profileRevision profile) rows) (fail "profile binding")
      pure rows

-- | The current profile with this identifier and its workflow catalogue.
-- The profiles are read first, so the catalogue binds to the profile
-- revision that the manager publishes now, also after a manager restart
-- published new profile revisions. A profile that the manager no longer
-- lists gives 'C.InvalidResponse'.
loadProfileWorkflows :: C.Client -> Text -> IO (Either C.ClientFailure (Profile, [Workflow]))
loadProfileWorkflows client ident = do
  listed <- loadProfiles client
  case listed of
    Left failure -> pure (Left failure)
    Right profiles -> case filter ((== ident) . profileId) profiles of
      [profile] -> fmap ((,) profile) <$> loadWorkflows client profile
      _ -> pure (Left C.InvalidResponse)

collection :: C.Client -> Text -> ([Value] -> Parser a) -> IO (Either C.ClientFailure a)
collection client uri parser = case C.reference client uri of
  Left failure -> pure (Left failure)
  Right location -> do
    received <- C.getPageSet client location
    pure $ received >>= \pages -> decode (withObject "collection metadata" (\fields -> do
      closed ["version"] fields
      versionOne fields
      parser (C.pageSetItems pages))) (C.pageSetMetadata pages)

-- | The pending decision heads of the authorized runs: the complete page set
-- of @/v1/decisions@ without @runId@, in manager observation order
-- ('decodeDecisionHeads').
loadDecisions :: C.Client -> IO (Either C.ClientFailure [DecisionView])
loadDecisions client = collection client "/v1/decisions" parseDecisionHeads

-- | The decision heads of the items of one complete @/v1/decisions@ page
-- set, in the order of the items. Each item is a decision representation,
-- and one decision and one run appear at most once, because the collection
-- lists one head for each run.
decodeDecisionHeads :: [Value] -> Either C.ClientFailure [DecisionView]
decodeDecisionHeads = either (const (Left C.InvalidResponse)) Right . parseEither parseDecisionHeads

parseDecisionHeads :: [Value] -> Parser [DecisionView]
parseDecisionHeads values = traverse parseDecision values >>= uniqueBy decisionId >>= uniqueBy decisionRun

-- | The closed request-creation body, bound to the selected catalogue identity.
createBody :: Workflow -> Value
createBody row = object
  [ "workflowId" .= workflowId row, "descriptorRevision" .= workflowRevision row,
    "profileId" .= workflowProfile row, "profileRevision" .= workflowProfileRevision row ]

-- | One explicit user intent. It is data, not a dispatch ticket.
data Mutation
  = Create !Workflow
  | SaveLiteral !C.DraftView !Text !Text !Int
    -- | The capture of these exact raw UTF-8 bytes for the named input of
    -- the request, at this input index. The bytes come from the input
    -- editor or from a local file that the operator named, and the manager
    -- receives only the bytes.
  | Capture !C.DraftView !Text !BS.ByteString !Int
    -- | The set-input of the named input with source capture and the
    -- identifier of this capture receipt, at this input index.
  | SaveCapture !C.DraftView !Text !C.CaptureReceipt !Int
    -- | The remove-input of the named supplied input of the request, at this
    -- input index.
  | RemoveInput !C.DraftView !Text !Int
  | Enqueue !C.DraftView
    -- | The withdrawal of a request in the draft or queued phase.
  | Withdraw !C.DraftView
  | Approve !C.DraftView !C.Preparation
    -- | The discard of the live review of the request. The request returns
    -- to the draft phase when the manager has discarded the prepared worker.
  | Discard !C.DraftView !C.Preparation
    -- | The typed answer to the question that this decision observation
    -- names. The command stays bound to this decision when the head changes.
  | Answer !DecisionView !Value
    -- | The retry that this control offer names for the recovery decision at
    -- the head. The control observation is the precondition. The attempt is
    -- the latest attempt that the snapshot publishes for the occurrence, and
    -- the manager names it in the effect address.
  | Retry !ControlView !DecisionView !ControlOffer !(Maybe Word32)
    -- | The cancel of the run that this control observation names, for the
    -- request profile. The control observation is the precondition, and it
    -- allows the cancel.
  | Cancel !Text !ControlView
    -- | The steer of the attempt that this steer offer names, for the request
    -- profile, with the timing (@interrupt-now@ or @next-boundary@) and the
    -- text. The control observation that offered it is the precondition.
  | Steer !Text !ControlView !ControlOffer !Text !Text
    -- | The recovery choice (@failover@ or @abandon@) that this
    -- choose-recovery offer of the control observation carries for the
    -- recovery decision at the head. The decision observation is the
    -- precondition. The attempt is the latest attempt that the snapshot
    -- publishes for the occurrence, and the manager names it in the effect
    -- address.
  | ChooseRecovery !ControlView !DecisionView !ControlOffer !Text !(Maybe Word32)
    -- | The redirect of the occurrence of this redirect offer to one of its
    -- targets, for the request profile. The control observation that offered
    -- it is the precondition. The attempt is the attempt in flight that a
    -- live redirect stops, as the snapshot publishes it. It is absent for a
    -- redirect inside the dispatch window. The redirect body names no
    -- attempt, so the attempt is shown only.
  | Redirect !Text !ControlView !ControlOffer !Text !(Maybe Word32)
    -- | The export of the verified result of the run under the name, for
    -- the run profile: profile, run identifier and name. Its precondition is
    -- the first page of the export collection of the run, which the
    -- preparation observes ('prepareMutation').
  | Export !Text !Text !Text
    -- | A lineage request of the parent run for the run profile: profile,
    -- parent run identifier, the strong entity tag of the first page of the
    -- lineage collection of the run, and the operation with its fork edits.
    -- The entity tag is the precondition of the request.
  | Lineage !Text !Text !Text !LineageChoice
  deriving (Eq, Show)

mutationOperation :: Mutation -> Text
mutationOperation mutation = case mutation of
  Create _ -> "create"
  SaveLiteral {} -> "set-input"
  Capture {} -> "capture"
  SaveCapture {} -> "set-input"
  RemoveInput {} -> "remove-input"
  Enqueue _ -> "enqueue"
  Withdraw _ -> "withdraw"
  Approve {} -> "approve"
  Discard {} -> "discard"
  Answer {} -> "answer"
  Retry _ _ offer _ -> offerOperation offer
  Cancel {} -> "cancel"
  Steer {} -> "steer"
  ChooseRecovery {} -> "choose-recovery"
  Redirect {} -> "redirect"
  Export {} -> "export"
  Lineage _ _ _ choice -> lineageChoiceName choice

mutationURI :: Mutation -> Text
mutationURI mutation = case mutation of
  Create _ -> "/v1/requests"
  SaveLiteral request _ _ _ -> requestURI request
  Capture request _ _ _ -> "/v1/captures?requestId=" <> C.draftId request
  SaveCapture request _ _ _ -> requestURI request
  RemoveInput request _ _ -> requestURI request
  Enqueue request -> requestURI request
  Withdraw request -> requestURI request
  Approve _ preparation -> "/v1/preparations/" <> C.preparationId preparation
  Discard _ preparation -> "/v1/preparations/" <> C.preparationId preparation
  Answer decision _ -> "/v1/decisions/" <> decisionId decision
  Retry control _ _ _ -> "/v1/runs/" <> controlRun control <> "/control"
  Cancel _ control -> "/v1/runs/" <> controlRun control <> "/control"
  Steer _ control _ _ _ -> "/v1/runs/" <> controlRun control <> "/control"
  ChooseRecovery _ decision _ _ _ -> "/v1/decisions/" <> decisionId decision
  Redirect _ control _ _ _ -> "/v1/runs/" <> controlRun control <> "/control"
  Export _ run _ -> exportsURI run
  Lineage _ run _ _ -> lineageURI run

mutationProfile :: Mutation -> Text
mutationProfile mutation = case mutation of
  Create row -> workflowProfile row
  SaveLiteral request _ _ _ -> C.draftProfile request
  Capture request _ _ _ -> C.draftProfile request
  SaveCapture request _ _ _ -> C.draftProfile request
  RemoveInput request _ _ -> C.draftProfile request
  Enqueue request -> C.draftProfile request
  Withdraw request -> C.draftProfile request
  Approve _ preparation -> C.preparationProfile preparation
  Discard _ preparation -> C.preparationProfile preparation
  Answer decision _ -> decisionProfile decision
  Retry _ decision _ _ -> decisionProfile decision
  Cancel profile _ -> profile
  Steer profile _ _ _ _ -> profile
  ChooseRecovery _ decision _ _ _ -> decisionProfile decision
  Redirect profile _ _ _ _ -> profile
  Export profile _ _ -> profile
  Lineage profile _ _ _ -> profile

requestURI :: C.DraftView -> Text
requestURI request = "/v1/requests/" <> C.draftId request

-- | Produce the original pending command before any HTTP mutation is attempted.
prepareMutation :: C.Client -> UTCTime -> Mutation -> Maybe C.Observed -> IO (Either C.ClientFailure C.PendingCommand)
prepareMutation client now mutation observed
  | not permitted = pure (Left (C.Refused 403 "insufficient-scope"))
  | otherwise = case mutation of
      Create row -> case C.reference client "/v1/requests" of
        Left failure -> pure (Left failure)
        Right location -> C.prepareCommand client location Nothing (createBody row)
      SaveLiteral request name value _ -> fromDraft request $ do
        editableInput request name
        Right (object ["operation" .= ("set-input" :: Text), "input" .= object
          ["name" .= name, "source" .= ("literal" :: Text), "value" .= value]])
      -- A capture has no existing-resource validator, so it carries no
      -- If-Match. The installed request observation still names an editable
      -- input of the request.
      Capture request name bytes _ -> case (observed, editableInput request name) of
        (Just current, Right ()) | owned current (requestURI request) (C.draftRevision request),
          C.decodeObservation (C.observedValue current) == Right request -> C.prepareCapture client (C.draftId request) bytes
        _ -> pure (Left C.InvalidResponse)
      SaveCapture request name receipt _ -> fromDraft request $ do
        editableInput request name
        unless (C.captureRequest receipt == C.draftId request && C.captureProfile receipt == C.draftProfile request) (Left C.InvalidResponse)
        Right (object ["operation" .= ("set-input" :: Text), "input" .= object
          ["name" .= name, "source" .= ("capture" :: Text), "captureId" .= C.captureId receipt]])
      -- A removal names an input that the request supplies.
      RemoveInput request name _ -> fromDraft request $ do
        editableInput request name
        let C.Readiness _ supplied _ _ = C.draftReadiness request
        unless (name `elem` map suppliedName supplied) (Left C.InvalidResponse)
        Right (object ["operation" .= ("remove-input" :: Text), "name" .= name])
      Enqueue request -> fromDraft request $
        if C.draftPhase request == "draft" && requestReady request
        then Right (object ["operation" .= ("enqueue" :: Text)]) else Left C.InvalidResponse
      Withdraw request -> fromDraft request $
        if C.draftPhase request `elem` ["draft","queued"]
        then Right (object ["operation" .= ("withdraw" :: Text)]) else Left C.InvalidResponse
      Approve request preparation -> case observed of
        Just current | owned current (mutationURI mutation) (C.preparationRevision preparation),
          C.decodeObservation (C.observedValue current) == Right preparation,
          C.preparationRequest preparation == C.draftId request,
          C.preparationRequestRevision preparation == C.draftRevision request,
          C.draftPreparation request == Just (C.preparationId preparation),
          reviewLive now preparation -> C.prepareObserved client current (approvalBody preparation)
        _ -> pure (Left C.InvalidResponse)
      -- The discard precondition is the exact observation of the live
      -- preparation of the request, with its entity tag as If-Match.
      Discard request preparation -> case observed of
        Just current | owned current (mutationURI mutation) (C.preparationRevision preparation),
          C.decodeObservation (C.observedValue current) == Right preparation,
          C.preparationRequest preparation == C.draftId request,
          C.draftPhase request == "review",
          C.draftPreparation request == Just (C.preparationId preparation),
          C.preparationState preparation == "live" -> C.prepareObserved client current (object ["operation" .= ("discard" :: Text)])
        _ -> pure (Left C.InvalidResponse)
      -- The answer precondition is the exact decision observation that the
      -- answer was built from, with its entity tag as If-Match.
      Answer decision value -> case observed of
        Just current | owned current (mutationURI mutation) (decisionRevision decision),
          decodeDecision (C.observedValue current) == Right decision -> C.prepareObserved client current (answerBody decision value)
        _ -> pure (Left C.InvalidResponse)
      -- The retry precondition is the exact control observation that
      -- offered the retry, with its entity tag as If-Match.
      Retry control decision offer _ -> case observed of
        Just current | owned current (mutationURI mutation) (controlRevision control),
          decodeControl (C.observedValue current) == Right control,
          retryOffer control decision == Just offer -> C.prepareObserved client current (retryBody decision offer)
        _ -> pure (Left C.InvalidResponse)
      -- The cancel precondition is the exact control observation that
      -- allowed the cancel, with its entity tag as If-Match.
      Cancel _ control -> case observed of
        Just current | owned current (mutationURI mutation) (controlRevision control),
          decodeControl (C.observedValue current) == Right control,
          cancelOffered control -> C.prepareObserved client current (object ["operation" .= ("cancel" :: Text)])
        _ -> pure (Left C.InvalidResponse)
      -- The steer precondition is the exact control observation that
      -- offered the steer with this timing.
      Steer _ control offer timing message -> case observed of
        Just current | owned current (mutationURI mutation) (controlRevision control),
          decodeControl (C.observedValue current) == Right control,
          steerOffer control (Just (offerOccurrence offer)) timing == Just offer,
          not (T.null (T.strip message)) -> C.prepareObserved client current (steerBody offer timing message)
        _ -> pure (Left C.InvalidResponse)
      -- The recovery-choice precondition is the exact decision observation
      -- at the head, with its entity tag as If-Match. The control
      -- observation offers the choice.
      ChooseRecovery control decision offer choice _ -> case observed of
        Just current | owned current (mutationURI mutation) (decisionRevision decision),
          decodeDecision (C.observedValue current) == Right decision,
          recoveryOffer control decision choice == Just offer -> C.prepareObserved client current (chooseRecoveryBody decision choice)
        _ -> pure (Left C.InvalidResponse)
      -- The redirect precondition is the exact control observation that
      -- offered the redirect of the occurrence to this target.
      Redirect _ control offer target _ -> case observed of
        Just current | owned current (mutationURI mutation) (controlRevision control),
          decodeControl (C.observedValue current) == Right control,
          redirectOffer control (Just (offerOccurrence offer)) == Just offer,
          target `elem` offerTargets offer -> C.prepareObserved client current (redirectBody offer target)
        _ -> pure (Left C.InvalidResponse)
      -- The export precondition is the strong entity tag of the first page
      -- of the export collection of the run. No displayed view holds that
      -- page, so the preparation observes it at once ('observeExports') and
      -- sends its entity tag as If-Match. A collection that changes before
      -- the send refuses the export with 412 stale-revision.
      Export _ run name
        | not (exportNameValid name) -> pure (Left C.InvalidResponse)
        | otherwise -> do
            exports <- observeExports client run
            case exports of
              Left failure -> pure (Left failure)
              Right (current, _) -> C.prepareObserved client current (object ["name" .= name])
      -- The lineage precondition is the observation of the first page of the
      -- lineage collection that the menu showed. Its strong entity tag is the
      -- one that the mutation carries, and the page lists the operation as
      -- eligible.
      Lineage _ run tag choice -> case observed of
        Just current | observedBinding current == (lineageURI run, tag),
          Right page <- decodeLineageCollection (C.observedValue current),
          lineageRun page == run, lineageChoiceName choice `elem` lineageEligible page ->
            C.prepareObserved client current (lineageBody choice)
        _ -> pure (Left C.InvalidResponse)
  where
    needed = case mutation of
      Approve {} -> ["observe","submit","control"]
      Discard {} -> ["observe","submit","control"]
      Answer {} -> ["observe","control"]
      Retry {} -> ["observe","control"]
      Cancel {} -> ["observe","control"]
      Steer {} -> ["observe","control"]
      ChooseRecovery {} -> ["observe","control"]
      Redirect {} -> ["observe","control"]
      Export {} -> ["observe","export"]
      _ -> ["observe","submit"]
    permitted = case C.clientCapabilities client of
      Object fields -> case (KM.lookup "scopes" fields, KM.lookup "profileIds" fields) of
        (Just (Array scopes),Just (Array profiles)) -> all ((`V.elem` scopes) . String) needed
          && String (mutationProfile mutation) `V.elem` profiles
        _ -> False
      _ -> False
    editableInput request name = do
      let C.Readiness declarations _ _ _ = C.draftReadiness request
      unless (C.draftPhase request == "draft" && name `elem` [n | C.InputDeclaration n _ <- declarations]) (Left C.InvalidResponse)
    fromDraft request body = case (observed,body) of
      (Just current,Right value) | owned current (requestURI request) (C.draftRevision request),
        C.decodeObservation (C.observedValue current) == Right request -> C.prepareObserved client current value
      _ -> pure (Left C.InvalidResponse)

owned :: C.Observed -> Text -> Text -> Bool
owned = bound observedBinding

-- | The URI and entity tag of one observation. They are display and
-- precondition data, not an owner.
observedBinding :: C.Observed -> (Text, Text)
observedBinding observed = (C.referenceURI (C.observedReference observed), C.observedETag observed)

-- | Whether an observation is the resource at this URI with the strong entity
-- tag of this revision.
bound :: (observed -> (Text, Text)) -> observed -> Text -> Text -> Bool
bound binding observed uri revision = binding observed == (uri, "\"" <> revision <> "\"")

observeDraft :: C.Client -> Workflow -> Text -> IO (Either C.ClientFailure (C.Observed,C.DraftView))
observeDraft client row ident = case C.reference client ("/v1/requests/" <> ident) of
  Left failure -> pure (Left failure)
  Right location -> do
    result <- C.observeResource client location
    pure $ do
      observed <- result
      request <- C.decodeObservation (C.observedValue observed)
      unless (C.draftId request == ident && requestMatches row request && owned observed (requestURI request) (C.draftRevision request))
        (Left C.InvalidResponse)
      Right (observed,request)

observePreparation :: C.Client -> C.DraftView -> IO (Either C.ClientFailure (C.Observed,C.Preparation))
observePreparation client request = case C.draftPreparation request >>= either (const Nothing) Just . C.reference client . ("/v1/preparations/" <>) of
  Nothing -> pure (Left C.InvalidResponse)
  Just location -> do
    result <- C.observeResource client location
    pure $ do
      observed <- result
      preparation <- C.decodeObservation (C.observedValue observed)
      unless (C.draftPreparation request == Just (C.preparationId preparation)
        && owned observed ("/v1/preparations/" <> C.preparationId preparation) (C.preparationRevision preparation)) (Left C.InvalidResponse)
      Right (observed,preparation)

observeReceipt :: C.Client -> Mutation -> C.Reference -> IO (Either C.ClientFailure C.CommandReceipt)
observeReceipt client mutation location = do
  result <- C.getResource client location
  pure $ do
    response <- result
    unless (C.responseStatus response == 200) (Left C.InvalidResponse)
    receipt <- C.decodeObservation (C.responseValue response)
    unless (receiptMatches mutation receipt && C.referenceURI location == "/v1/commands/" <> C.receiptId receipt) (Left C.InvalidResponse)
    Right receipt

-- | Whether a request belongs to this catalogue row: its workflow, its
-- descriptor and profile revisions, and the input declarations of the row. A
-- lineage request ('lineageRequest') declares no input, because its inputs
-- come from its parent run.
requestMatches :: Workflow -> C.DraftView -> Bool
requestMatches row request = C.draftWorkflow request == workflowId row
  && C.draftDescriptorRevision request == workflowRevision row
  && C.draftProfile request == workflowProfile row && C.draftProfileRevision request == workflowProfileRevision row
  && if lineageRequest request then null declarations
     else declarations == [C.InputDeclaration (workflowInputName input) (sourceName (workflowInputSource input))
                         | input <- workflowInputs (workflowDisplay row)]
  where C.Readiness declarations _ _ _ = C.draftReadiness request

-- | Whether a request is a lineage request: it names a parent run and a
-- lineage operation.
lineageRequest :: C.DraftView -> Bool
lineageRequest request = isJust (C.draftParent request) && isJust (C.draftLineage request)

sourceName :: WorkflowInputSource -> Text
sourceName source = case source of DescriptorPrompt -> "prompt"; DescriptorCommandTail -> "command-tail"; DescriptorStdin -> "stdin"

requestReady :: C.DraftView -> Bool
requestReady request = case C.draftReadiness request of C.Readiness _ _ missing errors -> null missing && null errors

literalInputs :: C.DraftView -> Map.Map Text Text
literalInputs request = case C.draftReadiness request of
  C.Readiness _ supplied _ _ -> Map.fromList [(name,value) | C.LiteralValue name value <- supplied]

-- | Agreement of the exact review with the selected request's native input bytes.
-- Logical literals are unchanged. Prompt transport's declared LF is included by Runtime.
-- A captured input agrees only with a capture receipt of this session, given
-- by capture identifier, whose size and SHA-256 the review repeats.
-- The review of a lineage request has the lineage of its request, the
-- parent run and the operation, and one captured input of the parent run
-- for each input declaration of the row, in declaration order. The frontend
-- holds no bytes of the parent inputs, so it shows their size and SHA-256 as
-- the review states them. The review of a root request has no lineage.
reviewMatches :: Map.Map Text C.CaptureReceipt -> Workflow -> C.DraftView -> C.Preparation -> Bool
reviewMatches captures row request preparation = requestMatches row request && requestReady request
  && C.draftPreparation request == Just (C.preparationId preparation)
  && C.preparationRequest preparation == C.draftId request
  && C.preparationRequestRevision preparation == C.draftRevision request
  && C.preparationProfile preparation == C.draftProfile request
  && C.preparationProfileRevision preparation == C.draftProfileRevision request
  && C.preparationDescriptorRevision preparation == C.draftDescriptorRevision request
  && C.reviewWorkflow review == workflowId row && C.reviewProfile review == workflowProfile row
  && case (C.draftParent request, C.draftLineage request, C.reviewLineage review) of
       (Just parent, Just operation, Just lineage) -> null supplied
         && C.reviewLineageParent lineage == parent && C.reviewLineageOperation lineage == operation
         && [(C.reviewInputName input, C.reviewInputSource input) | input <- C.reviewInputs review]
              == [(workflowInputName input, "capture") | input <- inputs]
       (Nothing, Nothing, Nothing) -> length supplied == length inputs && traverse binding inputs == Just (C.reviewInputs review)
       _ -> False
  where
    review = C.preparationReview preparation
    C.Readiness _ supplied _ _ = C.draftReadiness request
    inputs = workflowInputs (workflowDisplay row)
    binding input = case [value | value <- supplied, suppliedName value == workflowInputName input] of
      [C.LiteralValue name logical] ->
        let bytes = frontendLiteralBytes (workflowInputSource input) logical
         in Just (C.ReviewInput name "literal" (T.pack (show (BS.length bytes))) (T.pack (show (hash bytes :: Digest SHA256))))
      [C.CapturedValue name ident] -> do
        receipt <- Map.lookup ident captures
        unless (C.captureId receipt == ident && C.captureRequest receipt == C.draftId request
          && C.captureProfile receipt == C.draftProfile request) Nothing
        Just (C.ReviewInput name "capture" (T.pack (show (C.captureBytes receipt))) (C.captureDigest receipt))
      _ -> Nothing

-- | The name of one supplied input of a request.
suppliedName :: C.SuppliedInput -> Text
suppliedName value = case value of C.LiteralValue name _ -> name; C.CapturedValue name _ -> name

reviewLive :: UTCTime -> C.Preparation -> Bool
reviewLive now preparation = C.preparationState preparation == "live" && C.preparationReason preparation == Nothing
  && T.length expiry <= 40 && maybe False (now <) (iso8601ParseM (T.unpack (T.toUpper expiry)))
  where expiry = C.preparationExpiresAt preparation

approvalBody :: C.Preparation -> Value
approvalBody preparation = object
  [ "operation" .= ("approve" :: Text), "reviewDigest" .= C.preparationDigest preparation,
    "requestRevision" .= C.preparationRequestRevision preparation,
    "profileRevision" .= C.preparationProfileRevision preparation,
    "descriptorRevision" .= C.preparationDescriptorRevision preparation,
    "processGeneration" .= C.preparationGeneration preparation ]

approvalSelectors :: C.Preparation -> [Text]
approvalSelectors preparation =
  [ "reviewDigest       " <> C.preparationDigest preparation,
    "requestRevision    " <> C.preparationRequestRevision preparation,
    "profileRevision    " <> C.preparationProfileRevision preparation,
    "descriptorRevision " <> C.preparationDescriptorRevision preparation,
    "processGeneration  " <> C.preparationGeneration preparation ]

-- | Whether a receipt is the receipt of this mutation. An effect of an input
-- change, an enqueue, a withdrawal or a discard names the request. An effect of an answer names the
-- run controls and the occurrence of the answered decision. An effect of a
-- retry or of a recovery choice names the run controls, the recovering
-- occurrence and the attempt that it follows. An effect of a steer names the
-- run controls and the steered attempt, an effect of a redirect names the
-- run controls and the redirected occurrence, and an effect of a cancel
-- names the run controls. An effect of an export names the export receipt of
-- the command, @/v1/exports/export_{commandId}@.
receiptMatches :: Mutation -> C.CommandReceipt -> Bool
receiptMatches mutation receipt = C.operationName (C.receiptOperation receipt) == mutationOperation mutation
  && C.receiptProfile receipt == mutationProfile mutation && C.receiptResource receipt == mutationURI mutation
  && case (mutation, C.effectValue <$> C.receiptEffect receipt) of
       (_, Nothing) -> True
       (Answer decision _, Just (Object fields)) ->
         KM.lookup "resource" fields == Just (String ("/v1/runs/" <> decisionRun decision <> "/control"))
           && KM.lookup "address" fields == Just (object ["occurrenceId" .= occurrenceText (decisionOccurrence decision)])
       (Retry _ decision _ attempt, Just (Object fields)) ->
         KM.lookup "resource" fields == Just (String (mutationURI mutation))
           && KM.lookup "address" fields == Just (object (["occurrenceId" .= occurrenceText (decisionOccurrence decision)]
                <> ["attemptId" .= T.pack (show number) | Just number <- [attempt]]))
       (Retry {}, Just _) -> False
       (Cancel {}, Just (Object fields)) -> KM.lookup "resource" fields == Just (String (mutationURI mutation))
       (Steer _ _ offer _ _, Just (Object fields)) ->
         KM.lookup "resource" fields == Just (String (mutationURI mutation))
           && KM.lookup "address" fields == Just (object (["occurrenceId" .= occurrenceText (offerOccurrence offer)]
                <> ["attemptId" .= T.pack (show number) | Just number <- [offerAttempt offer]]))
       (ChooseRecovery control decision _ _ attempt, Just (Object fields)) ->
         KM.lookup "resource" fields == Just (String ("/v1/runs/" <> controlRun control <> "/control"))
           && KM.lookup "address" fields == Just (object (["occurrenceId" .= occurrenceText (decisionOccurrence decision)]
                <> ["attemptId" .= T.pack (show number) | Just number <- [attempt]]))
       (Redirect _ _ offer _ _, Just (Object fields)) ->
         KM.lookup "resource" fields == Just (String (mutationURI mutation))
           && KM.lookup "address" fields == Just (object ["occurrenceId" .= occurrenceText (offerOccurrence offer)])
       (Export {}, Just (Object fields)) ->
         KM.lookup "resource" fields == Just (String ("/v1/exports/export_" <> C.receiptId receipt))
       (Export {}, Just _) -> False
       -- An effect of a lineage request names the child request that it
       -- created.
       (Lineage {}, Just (Object fields)) -> case KM.lookup "resource" fields of
         Just (String resource) -> maybe False validIdentifier (T.stripPrefix "/v1/requests/" resource)
         _ -> False
       (Lineage {}, Just _) -> False
       (_, Just _) | controlMutation mutation -> False
       (Discard request _, Just (Object fields)) -> KM.lookup "resource" fields == Just (String (requestURI request))
       (_, Just (Object fields)) | mutationOperation mutation `elem` requestEffects ->
         KM.lookup "resource" fields == Just (String (mutationURI mutation))
       (_, Just _) -> mutationOperation mutation `notElem` ("answer" : "discard" : requestEffects)
  where requestEffects = ["set-input","remove-input","enqueue","withdraw"]

-- | Whether a capture receipt names the exact bytes of this capture: its
-- request, its profile, their size and their SHA-256. No other mutation has
-- a capture receipt.
captureMatches :: Mutation -> C.CaptureReceipt -> Bool
captureMatches mutation receipt = case mutation of
  Capture request _ bytes _ -> C.captureRequest receipt == C.draftId request
    && C.captureProfile receipt == C.draftProfile request
    && C.captureBytes receipt == fromIntegral (BS.length bytes)
    && C.captureDigest receipt == T.pack (show (hash bytes :: Digest SHA256))
  _ -> False

-- | A capture receipt of this session that 'captureMatches' this capture.
-- Every such receipt names the same request, profile, size and digest.
capturedReceipt :: Mutation -> Map.Map Text C.CaptureReceipt -> Maybe C.CaptureReceipt
capturedReceipt mutation = listToMaybe . filter (captureMatches mutation) . Map.elems

-- | The @captureBytes@ limit of the capabilities of the session. The client
-- accepts only capabilities that state it, so 0 never occurs.
captureLimit :: C.Client -> Int
captureLimit client = case C.clientCapabilities client of
  Object fields | Just (Object limits) <- KM.lookup "limits" fields, Just (Number limit) <- KM.lookup "captureBytes" limits,
    Just count <- toBoundedInteger limit -> count
  _ -> 0

-- | The exact bytes of the local file at this absolute path, for a capture:
-- a regular file of at most the given number of bytes whose bytes are UTF-8.
-- The refusal text names the reason. Only the bytes leave this function, so
-- the manager never receives the path.
readCaptureFile :: Int -> FilePath -> IO (Either Text BS.ByteString)
readCaptureFile limit path
  | not (isAbsolute path) || any (`elem` ['\NUL', '\n', '\r']) path = pure (Left "the file path must be one absolute single-line path")
  | otherwise = do
      -- A nonblocking open never waits on a FIFO or a device, and only a
      -- regular file is read.
      outcome <- try $ do
        descriptor <- openFd path ReadOnly defaultFileFlags {nonBlock = True, cloexec = True}
        status <- getFdStatus descriptor `onException` closeFd descriptor
        if not (isRegularFile status) then Nothing <$ closeFd descriptor else do
          handle <- fdToHandle descriptor `onException` closeFd descriptor
          Just <$> BS.hGet handle (limit + 1) `finally` hClose handle
      pure $ case outcome of
        Left (failure :: IOException) -> Left ("the file cannot be read: " <> T.pack (show failure))
        Right Nothing -> Left "the path does not name a regular file"
        Right (Just bytes)
          | BS.length bytes > limit -> Left ("the file exceeds the capture limit of " <> T.pack (show limit) <> " bytes")
          | Left _ <- TE.decodeUtf8' bytes -> Left "the file is not UTF-8 text"
          | otherwise -> Right bytes

receiptEffectKind :: C.CommandReceipt -> Maybe Text
receiptEffectKind receipt = case C.effectValue <$> C.receiptEffect receipt of
  Just (Object fields) | Just (String kind) <- KM.lookup "kind" fields -> Just kind
  _ -> Nothing

decodeProfile :: Value -> Either C.ClientFailure Profile
decodeProfile = decode parseProfile

decodeWorkflow :: Value -> Either C.ClientFailure Workflow
decodeWorkflow = decode parseWorkflow

decode :: (Value -> Parser a) -> Value -> Either C.ClientFailure a
decode parser = either (const (Left C.InvalidResponse)) Right . parseEither parser

parseProfile :: Value -> Parser Profile
parseProfile = withObject "profile" $ \fields -> do
  closed ["version","id","revision","workspaceLabel","targetLabel","readiness","refusal"] fields
  versionOne fields
  Profile <$> at identifier fields "id" <*> at identifier fields "revision"
    <*> at (text 0 4096) fields "workspaceLabel" <*> at (text 0 4096) fields "targetLabel"
    <*> at (oneOf ["ready","unavailable","quarantined"]) fields "readiness"
    <*> at (nullable (oneOf ["supervision-unavailable","quarantined","unsupported-operation"])) fields "refusal"

parseWorkflow :: Value -> Parser Workflow
parseWorkflow = withObject "workflow" $ \fields -> do
  closed ["version","id","revision","profileId","profileRevision","descriptorVersion",
    "runnerVersion","name","blurb","resultCode","level","size","askNodes","minFold",
    "maxFold","paths","inputs","runFacts","pins","capabilities","help"] fields
  versionOne fields
  ident <- at identifier fields "id"
  revision <- at identifier fields "revision"
  profile <- at identifier fields "profileId"
  profileVersion <- at identifier fields "profileRevision"
  descriptorVersion <- fields .: "descriptorVersion" :: Parser Int
  unless (descriptorVersion `elem` [2,3]) (fail "descriptor version")
  (capabilities,modes) <- at parseCapabilities fields "capabilities"
  inputs <- at (list 256 parseInput) fields "inputs" >>= uniqueBy workflowInputName
  descriptor <- WorkflowDescriptor descriptorVersion
    <$> at (text 0 128) fields "runnerVersion" <*> pure [] <*> pure [] <*> pure capabilities
    <*> at (text 1 1024) fields "name" <*> at (text 0 4096) fields "blurb"
    <*> at observationCode fields "resultCode" <*> at (text 0 128) fields "level"
    <*> at natural fields "size" <*> at natural fields "askNodes"
    <*> at (nullable natural) fields "minFold" <*> at (nullable natural) fields "maxFold"
    <*> at natural fields "paths" <*> pure inputs
    <*> at (list 256 (text 0 4096)) fields "runFacts"
    <*> at (list 256 (text 0 4096)) fields "pins" <*> pure modes
  help <- at (text 0 262144) fields "help"
  pure (Workflow ident revision profile profileVersion descriptor help)

parseCapabilities :: Value -> Parser (DescriptorCapabilities, [Text])
parseCapabilities = withObject "workflow capabilities" $ \fields -> do
  closed ["structuredRun","wholeRunCancel","requestControls","steering","interactiveRetry",
    "schedulerRedirect","semanticResume","immutableFork","restartFromScratch",
    "protocolNegotiation","routingInspection","personaRouting","modelAliasRouting",
    "effectful","toolExecution","consults","observes","effects","personAnsweringModes"] fields
  capabilities <- DescriptorCapabilities
    <$> fields .: "structuredRun" <*> fields .: "wholeRunCancel" <*> pure Nothing
    <*> fields .: "requestControls" <*> fields .: "steering" <*> fields .: "interactiveRetry"
    <*> fields .: "schedulerRedirect" <*> fields .: "semanticResume" <*> fields .: "immutableFork"
    <*> fields .: "restartFromScratch" <*> fields .: "protocolNegotiation"
    <*> fields .: "routingInspection" <*> pure Nothing
    <*> fields .: "personaRouting" <*> fields .: "modelAliasRouting"
    <*> at natural fields "consults" <*> at natural fields "observes" <*> at natural fields "effects"
    <*> fields .: "effectful" <*> fields .: "toolExecution"
  modes <- at (list 2 (oneOf ["engine","local-control"])) fields "personAnsweringModes" >>= uniqueBy id
  pure (capabilities,modes)

parseInput :: Value -> Parser WorkflowInputDescriptor
parseInput = withObject "input declaration" $ \fields -> do
  closed ["name","source","description","required","schema"] fields
  name <- at (text 1 1024) fields "name"
  source <- at (oneOf ["prompt","command-tail","stdin"]) fields "source"
  description <- fields .: "description" :: Parser Value
  required <- fields .: "required" :: Parser Bool
  schema <- fields .: "schema" :: Parser Value
  unless (description == Null && required && schema == object ["type" .= ("string" :: Text)])
    (fail "input declaration")
  pure (WorkflowInputDescriptor name (case source of
    "prompt" -> DescriptorPrompt
    "command-tail" -> DescriptorCommandTail
    _ -> DescriptorStdin))

observationCode :: Value -> Parser Value
observationCode value@(String _) = oneOf ["text","verdict","flag","receipt"] value >> pure value
observationCode value = withObject "observation code" (\fields -> do
  closed ["json"] fields
  at (withObject "structured code" $ \json -> do
    closed ["schema"] json
    at (semanticSchema 0) json "schema") fields "json"
  pure value) value

-- This validates schema-as-data for display, not an executable runtime schema.
semanticSchema :: Int -> Value -> Parser ()
semanticSchema depth value
  | depth >= 64 = fail "schema depth"
  | String _ <- value = oneOf ["null","boolean","integer","number","string","object"] value >> pure ()
  | Object fields <- value, KM.member "array" fields = do
      closed ["array"] fields
      at (withObject "array schema" $ \array -> do
        closed ["items"] array
        at (semanticSchema (depth + 1)) array "items") fields "array"
  | otherwise = semanticObject depth Set.empty value

semanticObject :: Int -> Set.Set Text -> Value -> Parser ()
semanticObject depth seen value
  | depth >= 64 = fail "schema depth"
  | value == String "object" = pure ()
  | otherwise = withObject "property schema" (\fields -> do
      closed ["property"] fields
      at (withObject "property" $ \property -> do
        closed ["name","schema","rest"] property
        name <- at (text 0 1024) property "name"
        unless (Set.notMember name seen) (fail "duplicate property")
        at (semanticSchema (depth + 1)) property "schema"
        at (semanticObject (depth + 1) (Set.insert name seen)) property "rest") fields "property") value

closed :: [Key.Key] -> Object -> Parser ()
closed keys fields = unless (KM.size fields == length keys && all (`KM.member` fields) keys)
  (fail "public object fields")

at :: (Value -> Parser a) -> Object -> Key.Key -> Parser a
at parser fields key = fields .: key >>= parser

versionOne :: Object -> Parser ()
versionOne fields = do
  version <- fields .: "version" :: Parser Int
  unless (version == 1) (fail "public version")

text :: Int -> Int -> Value -> Parser Text
text lo hi = withText "bounded text" $ \value -> do
  unless (T.length value >= lo && T.length value <= hi) (fail "text bound")
  pure value

identifier :: Value -> Parser Text
identifier value = do
  ident <- text 1 128 value
  unless (validIdentifier ident) (fail "identifier")
  pure ident

-- | Whether a text is a public identifier: 1 to 128 ASCII letters, digits,
-- underscores and hyphens.
validIdentifier :: Text -> Bool
validIdentifier ident = T.length ident >= 1 && T.length ident <= 128
  && T.all (`elem` (['A'..'Z'] <> ['a'..'z'] <> ['0'..'9'] <> "_-")) ident

oneOf :: [Text] -> Value -> Parser Text
oneOf choices value = do
  name <- parseJSON value
  unless (name `elem` choices) (fail "public enum")
  pure name

nullable :: (Value -> Parser a) -> Value -> Parser (Maybe a)
nullable _ Null = pure Nothing
nullable parser value = Just <$> parser value

list :: Int -> (Value -> Parser a) -> Value -> Parser [a]
list limit parser = withArray "bounded array" $ \values -> do
  unless (V.length values <= limit) (fail "array bound")
  traverse parser (V.toList values)

natural :: Value -> Parser Integer
natural value = do
  digits <- text 1 4096 value
  unless (T.all (\c -> c >= '0' && c <= '9') digits && (digits == "0" || not ("0" `T.isPrefixOf` digits)))
    (fail "natural decimal")
  pure (T.foldl' (\number c -> number * 10 + toInteger (fromEnum c - fromEnum '0')) 0 digits)

uniqueBy :: Ord key => (a -> key) -> [a] -> Parser [a]
uniqueBy key values = do
  unless (Set.size (Set.fromList (map key values)) == length values) (fail "duplicate identity")
  pure values

-- | One complete public snapshot and its display-only Runtime projection.
-- Private references and a last native envelope are not reconstructed. The
-- run identity is the validated public run id, and the published workflow and
-- target label are kept, also when the runtime is absent.
data RunObservation = RunObservation
  { runIdentity :: !RunId, runWorkflow :: !(Maybe Text), runTarget :: !(Maybe Text),
    runSequence :: !(Maybe Word64), runProtocol :: !(Maybe Int),
    runSnapshot :: !(Maybe RunSnapshot), runResult :: !(Maybe ResultReference),
    runVerification :: !Verification, runSupervision :: !Text, runIntegrity :: !Text,
    runDecisionIds :: !(Map.Map OccurrenceId (Maybe Text)),
    runMetadata :: !Value, runItems :: ![Value]
  } deriving (Eq, Show)

data ResultReference = ResultReference
  { resultArtifact :: !Text, resultBytes :: !Word64, resultDigest :: !Text,
    resultCode :: !Value, resultPreview :: !Text } deriving (Eq, Show)

data Verification = Absent | Referenced !Text | Verified !Text | Unavailable !(Maybe Text) !Text
  deriving (Eq, Show)

-- | Metadata for exact captured bytes. It is not a download or execution capability.
data Artifact = Artifact
  { artifactId :: !Text, artifactRun :: !Text, artifactKind :: !Text, artifactCode :: !Value,
    artifactBytes :: !Int, artifactDigest :: !Text, artifactDownload :: !Text } deriving (Eq, Show)

data ControlOffer = ControlOffer
  { offerOperation :: !Text, offerOccurrence :: !OccurrenceId, offerAttempt :: !(Maybe Word32),
    offerGeneration :: !(Maybe Text), offerTimings :: ![Text], offerChoices :: ![RecoveryOption], offerTargets :: ![Text]
  } deriving (Eq, Show)

-- | The currently published control offers, not original manager ownership.
data ControlView = ControlView
  { controlRun :: !Text, controlRevision :: !Text, controlSupervision :: !Text,
    controlCancel :: !Bool, controlHead :: !(Maybe Text), controlOffers :: ![ControlOffer], controlValue :: !Value
  } deriving (Eq, Show)

-- | The content of a decision. A question carries its observation code, the
-- editor schema of the decision when the manager gives one, and its prompt.
data DecisionContent = QuestionContent !Value !(Maybe EditorSchema) !Text | RecoveryContent !Text !Text ![RecoveryOption]
  deriving (Eq, Show)

-- | The editor schema of a question, in the frozen editor vocabulary: a
-- primitive type, an array of one item schema, or a closed object whose
-- properties are all required.
data EditorSchema
  = EditorNull
  | EditorBoolean
  | EditorInteger
  | EditorNumber
  | EditorString
  | EditorArray !EditorSchema
  | EditorObject !(Map.Map Text EditorSchema)
  deriving (Eq, Show)

data DecisionView = DecisionView
  { decisionId :: !Text, decisionRevision :: !Text, decisionRun :: !Text, decisionProfile :: !Text,
    decisionGeneration :: !Text, decisionOccurrence :: !OccurrenceId, decisionState :: !Text,
    decisionPosition :: !Int, decisionSequence :: !Word64, decisionContent :: !DecisionContent, decisionValue :: !Value
  } deriving (Eq, Show)

observeSnapshot :: C.Client -> Text -> IO (Either C.ClientFailure RunObservation)
observeSnapshot client ident = case C.reference client ("/v1/runs/" <> ident <> "/snapshot") of
  Left failure -> pure (Left failure)
  Right location -> do
    received <- C.getPageSet client location
    pure $ do
      pages <- received
      result <- decodeSnapshot (C.pageSetMetadata pages) (C.pageSetItems pages)
      unless (runIdText (runIdentity result) == ident) (Left C.InvalidResponse)
      Right result

observeControl :: C.Client -> Text -> IO (Either C.ClientFailure (C.Observed,ControlView))
observeControl client ident = case C.reference client ("/v1/runs/" <> ident <> "/control") of
  Left failure -> pure (Left failure)
  Right location -> do
    received <- C.observeResource client location
    pure $ do
      observed <- received
      value <- decodeControl (C.observedValue observed)
      unless (controlRun value == ident && owned observed (C.referenceURI location) (controlRevision value)) (Left C.InvalidResponse)
      Right (observed,value)

observeDecision :: C.Client -> Text -> Text -> Text -> IO (Either C.ClientFailure (C.Observed,DecisionView))
observeDecision client profile run ident = case C.reference client ("/v1/decisions/" <> ident) of
  Left failure -> pure (Left failure)
  Right location -> do
    received <- C.observeResource client location
    pure $ do
      observed <- received
      value <- decodeDecision (C.observedValue observed)
      unless (decisionId value == ident && decisionProfile value == profile && decisionRun value == run
        && owned observed (C.referenceURI location) (decisionRevision value)) (Left C.InvalidResponse)
      Right (observed,value)

observeResult :: C.Client -> RunObservation -> IO (Either C.ClientFailure (Maybe Artifact))
observeResult client snapshot = case C.reference client ("/v1/runs/" <> runIdText (runIdentity snapshot) <> "/outputs") of
  Left failure -> pure (Left failure)
  Right location -> do
    received <- C.getPageSet client location
    pure (received >>= \pages -> decodeOutputs snapshot (C.pageSetMetadata pages) (C.pageSetItems pages))

-- | The source-result artifact of one complete output page set, bound to the
-- run snapshot. A listed artifact is one that the output page set reports as
-- verified. The snapshot must reference or verify the same artifact, and the
-- run, kind, id, size, digest and code of the listed artifact must agree with
-- the snapshot result reference. Any other listed artifact refuses the page
-- set.
decodeOutputs :: RunObservation -> Value -> [Value] -> Either C.ClientFailure (Maybe Artifact)
decodeOutputs snapshot metadata items = decode (withObject "output metadata" (\fields -> do
  closed ["version","runId"] fields
  versionOne fields
  ident <- at identifier fields "runId"
  unless (ident == runIdText (runIdentity snapshot)) (fail "output run")
  entries <- traverse parseOutput items
  let artifacts = [artifact | Just artifact <- entries]
  unless (length artifacts <= 1) (fail "ambiguous result")
  case (artifacts,runResult snapshot,runVerification snapshot) of
    ([artifact],Just reference,verification) | Just expected <- boundArtifact verification -> do
      unless (artifactRun artifact == ident && artifactKind artifact == "source-result"
        && artifactId artifact == expected && resultArtifact reference == expected
        && fromIntegral (artifactBytes artifact) == resultBytes reference
        && artifactDigest artifact == resultDigest reference && artifactCode artifact == resultCode reference) (fail "result binding")
      pure (Just artifact)
    ([],_,_) -> pure Nothing
    _ -> fail "result verification")) metadata
  where
    boundArtifact verification = case verification of
      Verified expected -> Just expected
      Referenced expected -> Just expected
      _ -> Nothing

-- | The terminal runtime status that the validated snapshot publishes. A
-- null runtime and a running, starting or cancelling runtime are not
-- terminal.
runTerminal :: RunObservation -> Maybe RunStatus
runTerminal run = case runtimeStatus run of
  Just status | terminal status -> Just status
  _ -> Nothing
  where
    terminal status = case status of
      RunSucceeded -> True
      RunFailedStatus -> True
      RunCancelledStatus -> True
      RunOrphaned -> True
      RunStarting -> False
      RunRunning -> False
      RunCancelling -> False

-- | Whether the result bytes of this run are retrieved: the runtime status
-- is succeeded, the verification is verified, and the result reference names
-- the verified artifact. No other state causes a download.
resultWanted :: RunObservation -> Bool
resultWanted run = case (runtimeStatus run, runVerification run, runResult run) of
  (Just RunSucceeded, Verified ident, Just reference) -> resultArtifact reference == ident
  _ -> False

-- | Whether the snapshot of a succeeded run references a result whose
-- verification the manager has not yet recorded. The manager checks the
-- referenced bytes and records their verification when the run outputs are
-- read.
resultReferenced :: RunObservation -> Bool
resultReferenced run = case (runtimeStatus run, runVerification run, runResult run) of
  (Just RunSucceeded, Referenced ident, Just reference) -> resultArtifact reference == ident
  _ -> False

-- | The exact bytes of a verified source result and the artifact metadata
-- that they were verified against. The bytes are retained unchanged.
data VerifiedResult = VerifiedResult { verifiedArtifact :: !Artifact, verifiedBytes :: !BS.ByteString }
  deriving (Eq, Show)

-- | Retrieve the verified source result of a run through the same client.
-- Only a snapshot that 'resultWanted' selects causes a download. The
-- artifact metadata comes from 'observeResult', and 'C.downloadVerified'
-- checks the size (at most 64 MiB) and the digest of that metadata. A
-- selected run whose outputs list no verified artifact is refused.
--
-- For a snapshot that 'resultReferenced' selects, the outputs read makes the
-- manager check the referenced bytes and record their verification. The
-- snapshot is then read again, and the download takes place only when that
-- snapshot publishes the verified state for the same result reference. Any
-- other run downloads nothing.
retrieveResult :: C.Client -> RunObservation -> IO (Either C.ClientFailure (Maybe VerifiedResult))
retrieveResult client run
  | resultWanted run = do
      listed <- observeResult client run
      case listed of
        Left failure -> pure (Left failure)
        Right Nothing -> pure (Left C.InvalidResponse)
        Right (Just artifact) -> download artifact
  | resultReferenced run = do
      listed <- observeResult client run
      case listed of
        Left failure -> pure (Left failure)
        Right Nothing -> pure (Right Nothing)
        Right (Just artifact) -> do
          current <- observeSnapshot client (runIdText (runIdentity run))
          case current of
            Left failure -> pure (Left failure)
            Right fresh | resultWanted fresh && runResult fresh == runResult run -> download artifact
                        | otherwise -> pure (Right Nothing)
  | otherwise = pure (Right Nothing)
  where
    download artifact = case C.reference client (artifactDownload artifact) of
      Left failure -> pure (Left failure)
      Right location -> fmap (Just . VerifiedResult artifact)
        <$> C.downloadVerified client location (artifactBytes artifact) (artifactDigest artifact)

-- | Display lines for a terminal run, given the retrieval of its result: no
-- retrieval yet, the failure code of a retrieval that the next refresh
-- retries, or the verified bytes. A run that is not
-- terminal has no lines. The preview is bounded and is decoded leniently for
-- display only.
resultLines :: RunObservation -> Maybe (Either Text VerifiedResult) -> [Text]
resultLines run retrieval = case runTerminal run of
  Nothing -> []
  Just status -> ("Terminal: " <> statusName status) : case (status, retrieval) of
    (RunSucceeded, Just (Right result)) -> verifiedLines result
    (RunSucceeded, _) | not (resultWanted run || resultReferenced run) ->
      ["Result: no download; verification is " <> verificationName (runVerification run)]
    (RunSucceeded, Nothing) -> ["Result: retrieving the verified bytes"]
    (RunSucceeded, Just (Left code)) -> ["Result: not retrieved (" <> code <> "); the next refresh retries"]
    _ -> ["Result: no download for a run that did not succeed"]
  where
    statusName status = case status of
      RunSucceeded -> "succeeded"
      RunFailedStatus -> "failed"
      RunCancelledStatus -> "cancelled"
      RunOrphaned -> "orphaned"
      RunStarting -> "starting"
      RunRunning -> "running"
      RunCancelling -> "cancelling"

-- | The display lines of retained verified bytes: their size, the SHA-256
-- digest of their artifact and a bounded preview, which is decoded
-- leniently for display only.
verifiedLines :: VerifiedResult -> [Text]
verifiedLines result =
  [ "Result: verified " <> T.pack (show (BS.length (verifiedBytes result))) <> " bytes",
    "Result SHA-256: " <> artifactDigest (verifiedArtifact result),
    "Result preview: " <> preview (verifiedBytes result) ]
  where
    preview bytes = T.map (\character -> if character == '\n' then ' ' else character)
      (T.take 120 (TE.decodeUtf8With lenientDecode (BS.take 480 bytes)))

-- | The display name of a verification state.
verificationName :: Verification -> Text
verificationName verification = case verification of
  Absent -> "absent"
  Referenced _ -> "referenced"
  Verified _ -> "verified"
  Unavailable _ reason -> "unavailable (" <> reason <> ")"

-- | One export receipt, as @/v1/exports/{id}@ and the export collection of
-- its run represent it. A published receipt states the size, the SHA-256
-- digest and the download link of the exported bytes: the compact code and
-- value document of the verified result followed by one LF. It is metadata,
-- not a download capability.
data ExportReceipt = ExportReceipt
  { exportId :: !Text, exportRun :: !Text, exportCommand :: !Text, exportName :: !Text,
    exportCode :: !Value, exportState :: !Text, exportDigest :: !(Maybe Text),
    exportBytes :: !(Maybe Int), exportDownload :: !(Maybe Text)
  } deriving (Eq, Show)

-- | The first page of the export collection of one run: its run, the
-- collection revision that its strong entity tag carries, and its receipts.
data ExportCollection = ExportCollection
  { exportsRun :: !Text, exportsRevision :: !Text, exportsItems :: ![ExportReceipt]
  } deriving (Eq, Show)

-- | The progress of an accepted export: its command receipt before the
-- effect @exported@, or the command receipt, the published export receipt
-- and the exported bytes that 'C.downloadVerified' checked against that
-- receipt.
data ExportProgress
  = ExportPending !C.CommandReceipt
  | ExportPublished !C.CommandReceipt !ExportReceipt !BS.ByteString
  deriving (Eq, Show)

-- | The outcome of the latest export of a run, for display: a definite 412
-- refusal of its send with the export name and the refusal code, or the
-- published export receipt with its verified bytes.
data ExportOutcome
  = ExportRefused !Text !Text
  | ExportVerified !ExportReceipt !BS.ByteString
  deriving (Eq, Show)

-- | The export collection of a run.
exportsURI :: Text -> Text
exportsURI run = "/v1/runs/" <> run <> "/exports"

-- | Whether a name is a valid export name: one ASCII component of 1 to 128
-- letters, digits, dots, underscores and hyphens that starts with a letter
-- or a digit. The manager checks the name again.
exportNameValid :: Text -> Bool
exportNameValid name = case T.uncons name of
  Just (first, rest) -> T.length name <= 128 && alphanumeric first && T.all (\c -> alphanumeric c || c `elem` ("._-" :: String)) rest
  Nothing -> False
  where alphanumeric c = c `elem` (['A'..'Z'] <> ['a'..'z'] <> ['0'..'9'])

-- | Whether @e@ exports the result of this run, or the reason why it exports
-- nothing. Only a succeeded run whose snapshot publishes a verified result
-- is a source of an export, because the manager exports only a verified
-- result.
exportSource :: RunObservation -> Either Text ()
exportSource run
  | resultWanted run = Right ()
  | isNothing (runTerminal run) = Left "the run is not terminal"
  | runTerminal run /= Just RunSucceeded = Left "the run did not succeed"
  | otherwise = Left ("the run has no verified result; verification is " <> verificationName (runVerification run))

-- | The export of the verified result of this run under this name, for this
-- profile, or the reason why it starts nothing.
exportMutation :: Text -> RunObservation -> Text -> Either Text Mutation
exportMutation profile run name = do
  exportSource run
  unless (exportNameValid name) (Left "the export name must be 1 to 128 ASCII letters, digits, dots, underscores or hyphens that start with a letter or a digit")
  Right (Export profile (runIdText (runIdentity run)) name)

-- | Observe the first page of the export collection of a run through
-- 'C.observeResource'. Its strong entity tag must carry the collection
-- revision, and every receipt must belong to the run.
observeExports :: C.Client -> Text -> IO (Either C.ClientFailure (C.Observed, ExportCollection))
observeExports client run = case C.reference client (exportsURI run) of
  Left failure -> pure (Left failure)
  Right location -> do
    received <- C.observeResource client location
    pure $ do
      observed <- received
      page <- decodeExportCollection (C.observedValue observed)
      unless (exportsRun page == run && all ((== run) . exportRun) (exportsItems page)
        && owned observed (exportsURI run) (exportsRevision page)) (Left C.InvalidResponse)
      Right (observed, page)

decodeExportCollection :: Value -> Either C.ClientFailure ExportCollection
decodeExportCollection = decode $ withObject "export page" $ \fields -> do
  closed ["version","page","items","runId"] fields
  versionOne fields
  revision <- at (withObject "page" (\page -> at (text 1 256) page "revision")) fields "page"
  ExportCollection <$> at identifier fields "runId" <*> pure revision
    <*> at (list 256 parseExportReceipt >=> uniqueBy exportId) fields "items"

decodeExportReceipt :: Value -> Either C.ClientFailure ExportReceipt
decodeExportReceipt = decode parseExportReceipt

parseExportReceipt :: Value -> Parser ExportReceipt
parseExportReceipt = withObject "export receipt" $ \fields -> do
  closed ["version","id","runId","commandId","name","code","state","sha256","bytes","download"] fields
  versionOne fields
  size <- at (nullable uint64) fields "bytes"
  unless (maybe True (<= 67108864) size) (fail "export bound")
  name <- at (text 1 128) fields "name"
  unless (exportNameValid name) (fail "export name")
  ExportReceipt <$> at identifier fields "id" <*> at identifier fields "runId" <*> at identifier fields "commandId"
    <*> pure name <*> at observationCode fields "code" <*> at (oneOf ["published","unresolved"]) fields "state"
    <*> at (nullable digest) fields "sha256" <*> pure (fromIntegral <$> size) <*> at (nullable resourceLink) fields "download"

-- | Read the progress of an accepted export from its own command receipt.
-- Before the effect @exported@, the receipt is the progress. After it, the
-- export receipt that the effect names is read. It must be the published
-- receipt of this command, run and name, and 'C.downloadVerified' downloads
-- its bytes and checks them against its size and SHA-256 digest. Any other
-- receipt refuses the read.
observeExport :: C.Client -> Mutation -> C.Reference -> IO (Either C.ClientFailure ExportProgress)
observeExport client mutation location = do
  received <- observeReceipt client mutation location
  case (received, mutation) of
    (Left failure, _) -> pure (Left failure)
    (Right receipt, Export _ run name)
      | C.stateName (C.receiptState receipt) == "effect-observed", receiptEffectKind receipt == Just "exported" ->
          case C.reference client ("/v1/exports/export_" <> C.receiptId receipt) of
            Left failure -> pure (Left failure)
            Right detail -> do
              response <- C.getResource client detail
              case response >>= published receipt run name of
                Left failure -> pure (Left failure)
                Right (export, size, checksum, download) -> case C.reference client download of
                  Left failure -> pure (Left failure)
                  Right link -> fmap (ExportPublished receipt export) <$> C.downloadVerified client link size checksum
    (Right receipt, _) -> pure (Right (ExportPending receipt))
  where
    published receipt run name response = do
      unless (C.responseStatus response == 200) (Left C.InvalidResponse)
      export <- decodeExportReceipt (C.responseValue response)
      case (exportBytes export, exportDigest export, exportDownload export) of
        (Just size, Just checksum, Just download)
          | exportId export == "export_" <> C.receiptId receipt, exportCommand export == C.receiptId receipt,
            exportRun export == run, exportName export == name, exportState export == "published" ->
              Right (export, size, checksum, download)
        _ -> Left C.InvalidResponse

-- | The display lines of the latest export of a run. The preview of the
-- exported bytes is bounded and is decoded leniently for display only.
exportLines :: ExportOutcome -> [Text]
exportLines outcome = case outcome of
  ExportRefused name code ->
    ["Export " <> name <> ": refused (" <> code <> "); the export collection changed and nothing was sent again; e exports again"]
  ExportVerified export bytes ->
    [ "Export " <> exportName export <> ": " <> exportId export <> " state " <> exportState export,
      "Export download: verified " <> T.pack (show (BS.length bytes)) <> " bytes, SHA-256 " <> fromMaybe "none" (exportDigest export),
      "Export preview: " <> T.map (\character -> if character == '\n' then ' ' else character)
        (T.take 120 (TE.decodeUtf8With lenientDecode (BS.take 480 bytes))) ]

-- | The operation of a lineage request of a parent run: a restart, a resume,
-- or a fork with its edits. Each fork edit drops or replaces the persisted
-- answer of one occurrence of the parent run.
data LineageChoice = RestartChoice | ResumeChoice | ForkChoice ![FrontendEdit]
  deriving (Eq, Show)

-- | The operation name of a lineage choice, which is also the operation of
-- its command.
lineageChoiceName :: LineageChoice -> Text
lineageChoiceName choice = case choice of
  RestartChoice -> "restart"
  ResumeChoice -> "resume"
  ForkChoice _ -> "fork"

-- | The closed body of a lineage request. A fork carries its edits in the
-- canonical encoding of 'FrontendEdit'.
lineageBody :: LineageChoice -> Value
lineageBody choice = object (["operation" .= lineageChoiceName choice] <> case choice of
  ForkChoice edits -> ["edits" .= edits]
  _ -> [])

-- | The lineage collection of a run.
lineageURI :: Text -> Text
lineageURI run = "/v1/runs/" <> run <> "/lineage-requests"

-- | The first page of the lineage collection of one parent run: the run, the
-- revision that its strong entity tag carries, the operations that a new
-- lineage request may name now, the refusal code when it names none, and the
-- child requests of the run.
data LineageCollection = LineageCollection
  { lineageRun :: !Text, lineageRevision :: !Text, lineageEligible :: ![Text],
    lineageRefusal :: !(Maybe Text), lineageChildren :: ![C.DraftView]
  } deriving (Eq, Show)

-- | Decode the first page of a lineage collection. The page lists a refusal
-- exactly when it lists no eligible operation, and every child request names
-- the run as its parent.
decodeLineageCollection :: Value -> Either C.ClientFailure LineageCollection
decodeLineageCollection value = do
  (run, revision, eligible, refusal, items) <- decode (withObject "lineage page" $ \fields -> do
    closed ["version","page","items","runId","eligible","refusal"] fields
    versionOne fields
    revision <- at (withObject "page" (\page -> at (text 1 256) page "revision")) fields "page"
    eligible <- at (list 3 (oneOf ["restart","resume","fork"])) fields "eligible" >>= uniqueBy id
    refusal <- at (nullable (oneOf ["incompatible-parent","ownership-unavailable","quarantined","unsupported-operation"])) fields "refusal"
    unless (null eligible == isJust refusal) (fail "lineage eligibility")
    items <- at (list 256 pure) fields "items"
    run <- at identifier fields "runId"
    pure (run, revision, eligible, refusal, items)) value
  children <- traverse decodeRequestItem items
  unless (all ((== Just run) . C.draftParent) children && Set.size (Set.fromList (map C.draftId children)) == length children)
    (Left C.InvalidResponse)
  Right (LineageCollection run revision eligible refusal children)

-- | Observe the first page of the lineage collection of a run through
-- 'C.observeResource'. Its strong entity tag must carry the collection
-- revision.
observeLineageCollection :: C.Client -> Text -> IO (Either C.ClientFailure (C.Observed, LineageCollection))
observeLineageCollection client run = case C.reference client (lineageURI run) of
  Left failure -> pure (Left failure)
  Right location -> do
    received <- C.observeResource client location
    pure $ do
      observed <- received
      page <- decodeLineageCollection (C.observedValue observed)
      unless (lineageRun page == run && owned observed (lineageURI run) (lineageRevision page)) (Left C.InvalidResponse)
      Right (observed, page)

-- | An occurrence of a parent run that a fork edit may name: a completed or
-- reused occurrence, whose answer the runtime persisted, with its
-- observation code, its intent and its published answer text.
data ForkTarget = ForkTarget
  { forkOccurrence :: !OccurrenceId, forkCode :: !Text, forkIntent :: !Text, forkAnswer :: !(Maybe Text)
  } deriving (Eq, Show)

-- | The fork targets of a run snapshot, in occurrence order.
forkTargets :: RunObservation -> [ForkTarget]
forkTargets run =
  [ ForkTarget (snapshotOccurrenceId occurrence) (snapshotOccurrenceCode occurrence) (snapshotOccurrenceIntent occurrence)
      (snapshotOccurrenceAnswer occurrence)
  | occurrence <- maybe [] (Map.elems . snapshotOccurrences) (runSnapshot run),
    snapshotOccurrenceState occurrence `elem` [OccurrenceCompletedState, OccurrenceReusedState] ]

-- | The replacement answer of a fork target, converted from the editor text
-- by the observation code of the occurrence with 'personAnswerValue', as an
-- answer to a question: text as given, a flag from yes, no, true or false,
-- an acknowledgement from empty text, and a verdict or a structured answer
-- from JSON text. The native preparation checks the value against the
-- persisted code and schema of the occurrence.
forkReplacement :: ForkTarget -> Text -> Either Text Value
forkReplacement target = personAnswerValue (if forkCode target == "ack" then "receipt" else forkCode target)

-- | Which part of the lineage menu has the keys: the choice of the
-- operation, the fork edits of each occurrence, or the replacement answer
-- editor of the selected occurrence.
data LineageMode = LineageChoosing | LineageForking | LineageReplacing
  deriving (Eq, Show)

-- | The lineage menu of one parent run: the run profile, the observation of
-- the first page of the lineage collection and its decoded page, the fork
-- targets of the run, the part of the menu that has the keys, the selected
-- fork target, the fork edits by occurrence and the refusal of the latest
-- key.
data LineageMenu observed = LineageMenu
  { menuProfile :: !Text, menuObserved :: !observed, menuCollection :: !LineageCollection,
    menuTargets :: ![ForkTarget], menuMode :: !LineageMode, menuFocus :: !Int,
    menuEdits :: !(Map.Map OccurrenceId FrontendEdit), menuError :: !(Maybe Text)
  } deriving (Eq, Show)

-- | The lineage menu of this run for this profile, opened on the choice of
-- the operation without fork edits.
lineageMenu :: Text -> observed -> LineageCollection -> RunObservation -> LineageMenu observed
lineageMenu profile observed page run = LineageMenu profile observed page (forkTargets run) LineageChoosing 0 Map.empty Nothing

-- | The lineage mutation of the menu for this operation, with the
-- observation that becomes its precondition, or the reason why it starts
-- nothing. The first argument reads the URI and entity tag of an
-- observation. An operation that the page does not list as eligible is
-- refused here, before any send, and the refusal names the eligible
-- operations or the refusal code of the page.
lineageMutation :: (observed -> (Text, Text)) -> LineageMenu observed -> LineageChoice -> Either Text (Mutation, observed)
lineageMutation binding menu choice
  | name `notElem` lineageEligible page = Left $ case lineageEligible page of
      [] -> name <> " is not eligible: the manager lists no lineage operation for run " <> run
        <> "; refusal " <> fromMaybe "none" (lineageRefusal page)
      eligible -> name <> " is not eligible: the manager lists only " <> T.intercalate ", " eligible <> " for run " <> run
  | binding (menuObserved menu) /= (lineageURI run, tag) = Left ("the lineage observation is not the first page of run " <> run)
  | otherwise = Right (Lineage (menuProfile menu) run tag choice, menuObserved menu)
  where
    page = menuCollection menu
    run = lineageRun page
    name = lineageChoiceName choice
    tag = "\"" <> lineageRevision page <> "\""

-- | The fork of the menu with its edits in occurrence order.
lineageForkChoice :: LineageMenu observed -> LineageChoice
lineageForkChoice = ForkChoice . Map.elems . menuEdits

-- | The selected fork target.
forkFocused :: LineageMenu observed -> Maybe ForkTarget
forkFocused menu = listToMaybe (drop (menuFocus menu) (menuTargets menu))

-- | Drop the answer of the selected occurrence, or keep it when the menu
-- already drops it.
forkToggleDrop :: LineageMenu observed -> LineageMenu observed
forkToggleDrop menu = case forkFocused menu of
  Nothing -> menu {menuError = Just "no occurrence is selected"}
  Just target -> let ident = forkOccurrence target in menu {menuError = Nothing, menuEdits = case Map.lookup ident (menuEdits menu) of
    Just (DropAnswer _) -> Map.delete ident (menuEdits menu)
    _ -> Map.insert ident (DropAnswer ident) (menuEdits menu)}

-- | Keep the answer of the selected occurrence without an edit.
forkKeep :: LineageMenu observed -> LineageMenu observed
forkKeep menu = case forkFocused menu of
  Nothing -> menu {menuError = Just "no occurrence is selected"}
  Just target -> menu {menuError = Nothing, menuEdits = Map.delete (forkOccurrence target) (menuEdits menu)}

-- | Replace the answer of the selected occurrence with the answer that
-- 'forkReplacement' converts from the editor text, and return to the fork
-- edits. A text that does not convert keeps the editor open with the reason.
forkSetReplacement :: Text -> LineageMenu observed -> LineageMenu observed
forkSetReplacement input menu = case forkFocused menu of
  Nothing -> menu {menuError = Just "no occurrence is selected"}
  Just target -> case forkReplacement target input of
    Left reason -> menu {menuError = Just reason}
    Right value -> let ident = forkOccurrence target in
      menu {menuMode = LineageForking, menuError = Nothing, menuEdits = Map.insert ident (ReplaceAnswer ident value) (menuEdits menu)}

-- | The display lines of the lineage menu.
lineageMenuLines :: LineageMenu observed -> [Text]
lineageMenuLines menu = case menuMode menu of
  LineageChoosing ->
    [ "Parent run: " <> run, "Child requests: " <> T.pack (show (length (lineageChildren page))) ]
      <> [ "Refusal: " <> code <> "; no lineage operation is eligible" | Just code <- [lineageRefusal page] ]
      <> [ key <> " " <> name <> ": " <> (if name `elem` lineageEligible page then "eligible" else "not eligible")
         | (key, name) <- [("r","restart"),("s","resume"),("f","fork")] ]
      <> [ "A lineage request creates a new draft request. Its review needs a new exact approval." ]
  LineageForking ->
    ("Fork of run " <> run <> ": Up/Down select, d drops, Enter replaces, k keeps the answer") :
      if null (menuTargets menu)
        then ["The run publishes no completed occurrence. Ctrl-D forks without edits."]
        else zipWith row [0 ..] (menuTargets menu)
  LineageReplacing -> case forkFocused menu of
    Just target ->
      [ "Replacement answer for occurrence " <> occurrenceText (forkOccurrence target) <> " (" <> forkCode target <> "): " <> hint (forkCode target),
        "Recorded answer: " <> maybe "not published" bounded (forkAnswer target) ]
    Nothing -> ["No occurrence is selected."]
  where
    page = menuCollection menu
    run = lineageRun page
    row :: Int -> ForkTarget -> Text
    row index target = (if index == menuFocus menu then "> " else "  ") <> "occurrence " <> occurrenceText (forkOccurrence target)
      <> " (" <> forkCode target <> "): " <> case Map.lookup (forkOccurrence target) (menuEdits menu) of
        Nothing -> "keep; answer " <> maybe "not published" bounded (forkAnswer target)
        Just (DropAnswer _) -> "drop"
        Just (ReplaceAnswer _ value) -> "replace with " <> bounded (jsonText value)
    hint code = case code of
      "text" -> "the editor text is the answer"
      "flag" -> "yes, no, true or false"
      "ack" -> "empty text"
      _ -> "a JSON value"
    bounded value = let single = T.map (\character -> if character == '\n' then ' ' else character) value in
      if T.length single > 80 then T.take 80 single <> "..." else single
    jsonText = TE.decodeUtf8With lenientDecode . BL.toStrict . encode

-- | The progress of an accepted lineage request: its command receipt before
-- the effect @lineage-created@, or the command receipt and the child request
-- that the effect names.
data LineageProgress
  = LineagePending !C.CommandReceipt
  | LineageChild !C.CommandReceipt !C.DraftView
  deriving (Eq, Show)

-- | Read the progress of an accepted lineage request from its own command
-- receipt. After the effect @lineage-created@, the child request that the
-- effect names is read. It must name the parent run and the operation of the
-- mutation and belong to its profile.
observeLineageCommand :: C.Client -> Mutation -> C.Reference -> IO (Either C.ClientFailure LineageProgress)
observeLineageCommand client mutation location = do
  received <- observeReceipt client mutation location
  case (received, mutation) of
    (Left failure, _) -> pure (Left failure)
    (Right receipt, Lineage profile run _ choice)
      | C.stateName (C.receiptState receipt) == "effect-observed", receiptEffectKind receipt == Just "lineage-created",
        Just (Object fields) <- C.effectValue <$> C.receiptEffect receipt, Just (String resource) <- KM.lookup "resource" fields ->
          case C.reference client resource of
            Left failure -> pure (Left failure)
            Right detail -> do
              response <- C.getResource client detail
              pure $ do
                answered <- response
                unless (C.responseStatus answered == 200) (Left C.InvalidResponse)
                child <- decodeRequestItem (C.responseValue answered)
                unless (requestURI child == resource && C.draftParent child == Just run
                  && C.draftLineage child == Just (lineageChoiceName choice) && C.draftProfile child == profile) (Left C.InvalidResponse)
                Right (LineageChild receipt child)
    (Right receipt, _) -> pure (Right (LineagePending receipt))

-- | The outcome of the latest lineage request of a run, for display: a
-- definite refusal of its send with the operation and the refusal code, or
-- the operation and the child request that it created.
data LineageOutcome
  = LineageRefused !Text !Text
  | LineageCreated !Text !Text
  deriving (Eq, Show)

-- | The display line of the latest lineage request of a run.
lineageLines :: LineageOutcome -> [Text]
lineageLines outcome = case outcome of
  LineageRefused operation code ->
    ["Lineage " <> operation <> ": refused (" <> code <> "); nothing was sent again; l opens the lineage menu again"]
  LineageCreated operation child ->
    ["Lineage " <> operation <> ": created request " <> child <> "; it opens for setup and review"]

decodeControl :: Value -> Either C.ClientFailure ControlView
decodeControl = decode parseControl

decodeDecision :: Value -> Either C.ClientFailure DecisionView
decodeDecision = decode parseDecision

-- | One item of the request collection, which is the representation of its
-- request resource and decodes with the shared protocol codec.
decodeRequestItem :: Value -> Either C.ClientFailure C.DraftView
decodeRequestItem = C.decodeObservation

-- | One item of the run collection, or the run of one overview member. It is
-- display data. It grants no supervision, control or signalling authority.
data RunItem = RunItem
  { runItemId :: !Text, runItemRevision :: !Text, runItemProfile :: !Text, runItemContent :: !RunContent
  } deriving (Eq, Show)

-- | A run whose manifest the manager read, or a retained catalogue entry
-- whose manifest it could not read, with only its public category.
data RunContent = KnownContent !KnownRun | UnreadableContent !Text
  deriving (Eq, Show)

-- | The public summary of a known run. A null manifest version is a legacy
-- manifest. The runtime is the status, the last sequence and the protocol
-- version, and it is absent without validated native evidence.
data KnownRun = KnownRun
  { knownWorkflow :: !Text, knownRequest :: !(Maybe Text), knownParent :: !(Maybe Text),
    knownLineage :: !(Maybe Text), knownManifest :: !(Maybe Int),
    knownRuntime :: !(Maybe (RunStatus,Word64,Int)), knownSupervision :: !Text, knownIntegrity :: !Text,
    knownVerification :: !Verification, knownLimitations :: ![Text]
  } deriving (Eq, Show)

-- | One member of the overview page set, tagged by its kind. A request and a
-- preparation decode with the shared protocol codec.
data OverviewMember
  = RequestMember !C.DraftView
  | PreparationMember !C.Preparation
  | RunMember !RunItem
  | DecisionMember !DecisionView
  deriving (Eq, Show)

decodeRunItem :: Value -> Either C.ClientFailure RunItem
decodeRunItem = decode parseRunItem

decodeOverviewMember :: Value -> Either C.ClientFailure OverviewMember
decodeOverviewMember value = do
  (kind,member) <- decode (withObject "overview member" $ \fields -> do
    name <- at (oneOf (map fst overviewKinds)) fields "kind"
    closed ["kind",Key.fromText name] fields
    kind <- maybe (fail "overview kind") pure (lookup name overviewKinds)
    (,) kind <$> fields .: Key.fromText name) value
  decodeMember kind member
  where overviewKinds = [("request",C.OverviewRequest),("preparation",C.OverviewPreparation),("run",C.OverviewRun),("decision",C.OverviewDecision)]

-- | The member of one item of the page set that 'C.loadOverview' assembled,
-- decoded by its kind as 'decodeOverviewMember' decodes it.
decodeOverviewItem :: C.OverviewItem -> Either C.ClientFailure OverviewMember
decodeOverviewItem item = decodeMember (C.overviewKind item) (C.overviewValue item)

decodeMember :: C.OverviewKind -> Value -> Either C.ClientFailure OverviewMember
decodeMember kind member = case kind of
  C.OverviewRequest -> RequestMember <$> decodeRequestItem member
  C.OverviewPreparation -> PreparationMember <$> C.decodeObservation member
  C.OverviewRun -> RunMember <$> decodeRunItem member
  C.OverviewDecision -> DecisionMember <$> decodeDecision member

-- | The display projection of one overview member: its kind, its identity,
-- a one-line list label and its detail lines. A request keeps its phase,
-- admission and blocking reasons. A queued request also shows its position
-- among the queued requests of its profile ('queuePositions'). A run keeps its runtime status, its
-- supervision and its verification on distinct lines, and a runtime that the
-- manager does not publish is shown as not published. The projection reads
-- only the decoded member. No runtime reducer takes part.
data OverviewRow = OverviewRow
  { overviewRowKind :: !C.OverviewKind, overviewRowId :: !Text, overviewRowLabel :: !Text, overviewRowDetails :: ![Text]
  } deriving (Eq, Show)

-- | The rows of the overview members: the requests first, then the
-- preparations, the runs and the decisions, each kind in manager order.
overviewRows :: [OverviewMember] -> [OverviewRow]
overviewRows members = sortOn overviewRowKind (map (overviewRow (queuePositions members)) members)

-- | The position of each queued request among the queued requests of its
-- profile, in overview order, with the number of those requests. The
-- manager position of a request counts the queued requests of every
-- profile, so it differs from this position when another profile also has
-- queued requests.
queuePositions :: [OverviewMember] -> Map.Map Text (Int, Int)
queuePositions members = Map.fromList
  [ (C.draftId request, (position, length queued))
  | profile <- profiles,
    let queued = filter ((== profile) . C.draftProfile) queuedRequests,
    (position, request) <- zip [1 ..] queued ]
  where
    queuedRequests = [request | RequestMember request <- members, C.draftPhase request == "queued"]
    profiles = Set.toList (Set.fromList (map C.draftProfile queuedRequests))

overviewRow :: Map.Map Text (Int, Int) -> OverviewMember -> OverviewRow
overviewRow positions member = case member of
  RequestMember request -> OverviewRow C.OverviewRequest (C.draftId request)
    ("request " <> C.draftPhase request <> maybe "" (\place -> " " <> placeText place) queuePlace <> "  " <> C.draftId request)
    ([ "Request: " <> C.draftId request, "Workflow: " <> C.draftWorkflow request, "Profile: " <> C.draftProfile request,
      "Phase: " <> C.draftPhase request, "Admission: " <> C.draftAdmission request,
      "Position: " <> maybe "none" (T.pack . show) (C.draftPosition request) ]
      <> maybe [] (\place -> ["Profile queue position: " <> placeText place]) queuePlace
      <> [ "Blocking reasons: " <> listed (C.draftReasons request),
      "Preparation: " <> fromMaybe "none" (C.draftPreparation request), "Run: " <> fromMaybe "none" (C.draftRun request) ])
    where
      queuePlace = Map.lookup (C.draftId request) positions
      placeText (position, count) = T.pack (show position) <> " of " <> T.pack (show count)
  PreparationMember preparation -> OverviewRow C.OverviewPreparation (C.preparationId preparation)
    ("preparation  " <> C.preparationId preparation)
    [ "Preparation: " <> C.preparationId preparation, "Request: " <> C.preparationRequest preparation,
      "Profile: " <> C.preparationProfile preparation, "Expires: " <> C.preparationExpiresAt preparation ]
  RunMember item -> case runItemContent item of
    UnreadableContent category -> OverviewRow C.OverviewRun (runItemId item) ("run unreadable  " <> runItemId item)
      [ "Run: " <> runItemId item, "Profile: " <> runItemProfile item, "Manifest: unreadable (" <> category <> ")" ]
    KnownContent known -> OverviewRow C.OverviewRun (runItemId item)
      ("run " <> maybe "unpublished" (\(status,_,_) -> runStatusLabel status) (knownRuntime known) <> "  " <> runItemId item)
      ([ "Run: " <> runItemId item, "Workflow: " <> knownWorkflow known, "Profile: " <> runItemProfile item,
        "Request: " <> fromMaybe "none" (knownRequest known),
        "Runtime status: " <> maybe "not published" (\(status,sequenceNumber,protocol) -> runStatusLabel status
          <> " (sequence " <> T.pack (show sequenceNumber) <> ", protocol " <> T.pack (show protocol) <> ")") (knownRuntime known),
        "Supervision: " <> knownSupervision known, "Verification: " <> verificationName (knownVerification known),
        "Integrity: " <> knownIntegrity known, "Limitations: " <> listed (knownLimitations known) ]
        <> maybe [] (\parent -> ["Lineage: " <> fromMaybe "unknown" (knownLineage known) <> " of run " <> parent]) (knownParent known))
  DecisionMember view -> OverviewRow C.OverviewDecision (decisionId view)
    ("decision " <> decisionKindName view <> "  run " <> decisionRun view)
    ([ "Decision: " <> decisionId view, "Run: " <> decisionRun view, "Kind: " <> decisionKindName view,
       "State: " <> decisionState view, "Occurrence: " <> occurrenceText (decisionOccurrence view) ]
      <> case decisionContent view of
        QuestionContent code schema prompt -> [ "Answer type: " <> (case code of String name -> name; _ -> "structured") ]
          <> [ "Answer schema: " <> editorSchemaText editor | Object _ <- [code], Just editor <- [schema] ]
          <> [ "Addressee: " <> fromMaybe "none" (decisionAddressee view), "Prompt: " <> prompt ]
        RecoveryContent _ message _ -> ["Recovery: " <> message])
  where
    listed values = if null values then "none" else T.intercalate ", " values

-- | The kind of a decision: question or recovery.
decisionKindName :: DecisionView -> Text
decisionKindName view = case decisionContent view of
  QuestionContent {} -> "question"
  RecoveryContent {} -> "recovery"

-- | The kind and identity of an overview row. The overview view keeps its
-- focus by this key, not by the index of the row.
overviewRowKey :: OverviewRow -> (C.OverviewKind, Text)
overviewRowKey row = (overviewRowKind row, overviewRowId row)

-- | What Enter on an overview row opens.
data OverviewOpen
  = -- | A request, which opens by its phase.
    OpenRequest !C.DraftView
  | -- | A run by its identifier, with the profile that the row names.
    OpenRun !Text !Text
  | -- | Nothing, for the reason given.
    OpenNothing !Text
  deriving (Eq, Show)

-- | What Enter on the overview row with this key opens, given the overview
-- members. A request row opens its request and a run row its run. A
-- decision row opens the run of the decision. A preparation row opens its
-- request when the overview lists that request.
overviewOpen :: [OverviewMember] -> (C.OverviewKind, Text) -> OverviewOpen
overviewOpen members key = case [member | member <- members, overviewRowKey (overviewRow Map.empty member) == key] of
  RequestMember request : _ -> OpenRequest request
  RunMember item : _ -> OpenRun (runItemId item) (runItemProfile item)
  DecisionMember view : _ -> OpenRun (decisionRun view) (decisionProfile view)
  PreparationMember preparation : _ ->
    case [request | RequestMember request <- members, C.draftId request == C.preparationRequest preparation] of
      request : _ -> OpenRequest request
      [] -> OpenNothing "the overview does not list the request of this preparation"
  [] -> OpenNothing "no overview row is selected"

-- | The addressee that a question decision names, such as @person
-- model:fixed-point@ for an ask that the policy field @personAnswers@ routes
-- to the person. A recovery decision names none.
decisionAddressee :: DecisionView -> Maybe Text
decisionAddressee view = case (decisionContent view, decisionValue view) of
  (QuestionContent {}, Object fields) | Just (Object question) <- KM.lookup "question" fields,
    Just (String addressee) <- KM.lookup "addressee" question -> Just addressee
  _ -> Nothing

-- | The rows of the manager decisions: one row for each pending decision
-- head, in manager observation order. The rows keep the order of the
-- decision collection and are not sorted. Each row has the details of the
-- decision row of the overview, and its list label names only the kind and
-- the run, because every row is a decision.
decisionRows :: [DecisionView] -> [OverviewRow]
decisionRows = map $ \view -> (overviewRow Map.empty (DecisionMember view))
  {overviewRowLabel = decisionKindName view <> "  run " <> decisionRun view}

-- | What Enter on the decision row with this key opens: the run of the
-- decision at that head, with the profile of the decision.
decisionsOpen :: [DecisionView] -> (C.OverviewKind, Text) -> OverviewOpen
decisionsOpen = overviewOpen . map DecisionMember

-- | The status line of the installed manager decisions, given the refusal
-- code of the latest read when that read was refused and the installed
-- rows. A refusal keeps the last complete decision heads and marks them
-- stale.
decisionsStatus :: Maybe Text -> Maybe [OverviewRow] -> Text
decisionsStatus stale rows = case (stale, rows) of
  (Nothing, Nothing) -> "Decisions: not read"
  (Nothing, Just current) -> "Decisions: current; pending heads: " <> count current
  (Just code, Just retained) -> "Decisions: stale (" <> code <> "); the last complete heads are retained; pending heads: " <> count retained
  (Just code, Nothing) -> "Decisions: refused (" <> code <> "); no complete decision heads are installed"
  where count = T.pack . show . length

-- | The status line of the installed overview, given the refusal code of the
-- latest read when that read was refused and the installed rows. A refusal
-- keeps the last complete overview and marks it stale.
overviewStatus :: Maybe Text -> Maybe [OverviewRow] -> Text
overviewStatus stale rows = case (stale, rows) of
  (Nothing, Nothing) -> "Overview: not read"
  (Nothing, Just current) -> "Overview: current; " <> counts current
  (Just code, Just retained) -> "Overview: stale (" <> code <> "); the last complete overview is retained; " <> counts retained
  (Just code, Nothing) -> "Overview: refused (" <> code <> "); no complete overview is installed"
  where
    counts current = T.intercalate ", " [name <> ": " <> T.pack (show (length (filter ((== kind) . overviewRowKind) current)))
      | (name,kind) <- [("requests",C.OverviewRequest),("preparations",C.OverviewPreparation),("runs",C.OverviewRun),("decisions",C.OverviewDecision)]]

-- | The runs of the History view: the complete page set of @/v1/runs@,
-- every window of it, in the identifier order of the collection
-- ('decodeHistory'). The page set holds the managed runs of the authorized
-- profiles and the legacy entries of their bound retention roots.
loadHistory :: C.Client -> IO (Either C.ClientFailure [RunItem])
loadHistory client = collection client "/v1/runs" parseHistory

-- | The runs of the items of one complete @/v1/runs@ page set, in the order
-- of the items. Each item is a run representation, and one run appears at
-- most once.
decodeHistory :: [Value] -> Either C.ClientFailure [RunItem]
decodeHistory = either (const (Left C.InvalidResponse)) Right . parseEither parseHistory

parseHistory :: [Value] -> Parser [RunItem]
parseHistory values = traverse parseRunItem values >>= uniqueBy runItemId

-- | Whether a run of the History view is a legacy entry of a bound local
-- retention root: an entry with an unreadable manifest, or a known run with
-- observer supervision and no request. The manager serves the detail
-- representation of a legacy entry and refuses its other run resources.
historyLegacy :: RunItem -> Bool
historyLegacy item = case runItemContent item of
  UnreadableContent _ -> True
  KnownContent known -> knownSupervision known == "observer" && isNothing (knownRequest known)

-- | The rows of the History view: one row for each run, in the identifier
-- order of the collection. Each row has the details of the run row of the
-- overview: the runtime status, the supervision and the verification.
historyRows :: [RunItem] -> [OverviewRow]
historyRows = map (overviewRow Map.empty . RunMember)

-- | The status line of the installed History view, given the refusal code
-- of the latest read when that read was refused and the installed runs. A
-- refusal keeps the last complete run list and marks it stale.
historyStatus :: Maybe Text -> Maybe [RunItem] -> Text
historyStatus stale runs = case (stale, runs) of
  (Nothing, Nothing) -> "History: not read"
  (Nothing, Just current) -> "History: current; " <> counts current
  (Just code, Just retained) -> "History: stale (" <> code <> "); the last complete run list is retained; " <> counts retained
  (Just code, Nothing) -> "History: refused (" <> code <> "); no complete run list is installed"
  where
    counts items = let legacy = length (filter historyLegacy items) in
      "runs: " <> shown (length items) <> " (managed " <> shown (length items - legacy) <> ", legacy " <> shown legacy <> ")"
    shown = T.pack . show

-- | The read-only detail of one run of the History view: the snapshot of a
-- managed run, or the detail representation of a legacy entry.
data HistoryDetail = ManagedDetail !RunObservation | LegacyDetail !RunItem
  deriving (Eq, Show)

-- | The run identifier of a run detail.
historyDetailRun :: HistoryDetail -> Text
historyDetailRun detail = case detail of
  ManagedDetail run -> runIdText (runIdentity run)
  LegacyDetail item -> runItemId item

-- | Read the detail of one run of the History view: the snapshot page set of
-- a managed run, or @/v1/runs/{id}@ of a legacy entry ('historyLegacy'),
-- whose snapshot the manager refuses. The detail must name the same run.
observeHistoryDetail :: C.Client -> RunItem -> IO (Either C.ClientFailure HistoryDetail)
observeHistoryDetail client item
  | historyLegacy item = case C.reference client ("/v1/runs/" <> runItemId item) of
      Left failure -> pure (Left failure)
      Right location -> do
        received <- C.observeResource client location
        pure $ do
          observed <- received
          value <- decodeRunItem (C.observedValue observed)
          unless (runItemId value == runItemId item && runItemProfile value == runItemProfile item) (Left C.InvalidResponse)
          Right (LegacyDetail value)
  | otherwise = fmap ManagedDetail <$> observeSnapshot client (runItemId item)

-- | The run whose verified result @r@ retrieves from a run detail, or the
-- reason why @r@ retrieves nothing. Only a succeeded managed run with a
-- verified or referenced result is retrieved, through 'retrieveResult'. A
-- legacy entry publishes no size and digest for its result, so the frontend
-- cannot verify a download of it.
historyRetrievable :: HistoryDetail -> Either Text RunObservation
historyRetrievable detail = case detail of
  LegacyDetail _ -> Left "a legacy entry publishes no size and digest for its result"
  ManagedDetail run
    | resultWanted run || resultReferenced run -> Right run
    | isNothing (runTerminal run) -> Left "the run is not terminal"
    | runTerminal run /= Just RunSucceeded -> Left "the run did not succeed"
    | otherwise -> Left ("the run has no verified result; verification is " <> verificationName (runVerification run))

-- | The display lines of a run detail, given the retrieval of its verified
-- result: none yet, the failure code of the latest retrieval, or the
-- verified bytes. A managed run shows its snapshot summary, and a legacy
-- entry shows its representation.
historyDetailLines :: HistoryDetail -> Maybe (Either Text VerifiedResult) -> [Text]
historyDetailLines detail retrieval = case detail of
  LegacyDetail item -> overviewRowDetails (overviewRow Map.empty (RunMember item))
    <> ["Result: not retrieved; a legacy entry publishes no size and digest for its result"]
  ManagedDetail run ->
    [ "Run: " <> runIdText (runIdentity run),
      "Workflow: " <> fromMaybe "not published" (runWorkflow run),
      "Target: " <> fromMaybe "not published" (runTarget run),
      "Runtime status: " <> maybe "not published" runStatusLabel (runtimeStatus run)
        <> maybe "" (\number -> " (sequence " <> T.pack (show number) <> ")") (runSequence run),
      "Supervision: " <> runSupervision run, "Integrity: " <> runIntegrity run,
      "Verification: " <> verificationName (runVerification run),
      "Result reference: " <> maybe "none" (\reference -> resultArtifact reference <> ", " <> T.pack (show (resultBytes reference))
        <> " bytes, SHA-256 " <> resultDigest reference) (runResult run),
      "Occurrences: " <> maybe "none" (T.pack . show . Map.size . snapshotOccurrences) (runSnapshot run) ]
    <> case (historyRetrievable detail, retrieval) of
      (Right _, Just (Right result)) -> verifiedLines result
      (Right _, Just (Left code)) -> ["Result: not retrieved (" <> code <> "); r retries"]
      (Right _, Nothing) -> ["Result: r retrieves the verified bytes"]
      (Left reason, _) -> ["Result: no retrieval; " <> reason]

parseRunItem :: Value -> Parser RunItem
parseRunItem = withObject "run" $ \fields -> do
  versionOne fields
  ident <- at identifier fields "id"
  let self = "/v1/runs/" <> ident
  content <- if KM.member "kind" fields
    then do
      closed ["version","kind","id","revision","profileId","category","links"] fields
      _ <- at (oneOf ["unreadable-manifest"]) fields "kind"
      links fields [("self",self)]
      UnreadableContent <$> at (oneOf ["manifest-unavailable","malformed-manifest","unsupported-manifest"]) fields "category"
    else do
      closed ["version","id","revision","profileId","workflowId","requestId","parentRunId","lineage","manifest",
        "runtime","supervision","integrity","verification","limitations","links"] fields
      links fields [("self",self),("snapshot",self <> "/snapshot"),("control",self <> "/control"),
        ("outputs",self <> "/outputs"),("exports",self <> "/exports"),("lineageRequests",self <> "/lineage-requests")]
      fmap KnownContent $ KnownRun <$> at identifier fields "workflowId" <*> at (nullable identifier) fields "requestId"
        <*> at (nullable identifier) fields "parentRunId" <*> at (nullable (oneOf ["restart","resume","fork"])) fields "lineage"
        <*> at manifest fields "manifest" <*> at (nullable parseRuntime) fields "runtime" <*> at supervisionState fields "supervision"
        <*> at (oneOf ["valid","corrupt","incomplete","unknown"]) fields "integrity" <*> at parseVerification fields "verification"
        <*> (at (list 6 (oneOf ["legacy","foreign-owner","corrupt-journal","incompatible-invocation","quarantined","lost-supervision"])) fields "limitations"
          >>= uniqueBy id)
  RunItem ident <$> at identifier fields "revision" <*> at identifier fields "profileId" <*> pure content
  where
    links fields expected = at (withObject "run links" $ \present -> do
      closed (map fst expected) present
      mapM_ (\(key,uri) -> do
        actual <- at resourceLink present key
        unless (actual == uri) (fail "run link")) expected) fields "links"
    manifest = withObject "manifest compatibility" $ \fields -> do
      kind <- at (oneOf ["legacy","versioned"]) fields "kind"
      if kind == "legacy" then closed ["kind"] fields >> pure Nothing
        else do
          closed ["kind","frontendManifestVersion"] fields
          version <- fields .: "frontendManifestVersion"
          unless (version `elem` [2,3 :: Int]) (fail "frontend manifest version")
          pure (Just version)

decodeSnapshot :: Value -> [Value] -> Either C.ClientFailure RunObservation
decodeSnapshot metadata items = decode (withObject "run snapshot" $ \fields -> do
  closed ["version","snapshotVersion","runId","runtime","workflow","targetLabel","personAnswering",
    "authoredOrder","traceRecorded","controlAcks","billFresh","billMemo","result","verification",
    "failure","failureClass","supervision","integrity"] fields
  versionOne fields
  snapshotVersion <- fields .: "snapshotVersion" :: Parser Int
  unless (snapshotVersion == 1 && length items <= 2048) (fail "snapshot version or count")
  ident <- at identifier fields "runId"
  run <- either (const (fail "run identity")) pure (mkRunId ident)
  runtime <- at (nullable parseRuntime) fields "runtime"
  parsed <- traverse parseOccurrence items >>= uniqueBy (snapshotOccurrenceId . fst)
  let occurrences = map fst parsed
  unless (sum (map (Map.size . snapshotOccurrenceAttempts) occurrences) <= 512) (fail "attempt count")
  order <- at (list 2048 occurrenceId) fields "authoredOrder" >>= uniqueBy id
  acknowledgements <- at (list 2048 parseAcknowledgement) fields "controlAcks" >>= uniqueBy snapshotControlId
  workflow <- at (nullable (text 0 1024)) fields "workflow"
  target <- at (nullable (text 0 1024)) fields "targetLabel"
  answering <- at (nullable (enum [("engine",PersonAnswerEngine),("local-control",PersonAnswerLocalControl)])) fields "personAnswering"
  recorded <- fields .: "traceRecorded"
  fresh <- at (nullable natural) fields "billFresh"
  memo <- at (nullable natural) fields "billMemo"
  result <- at (nullable parseResultReference) fields "result"
  verification <- at parseVerification fields "verification"
  failure <- at (nullable (text 0 4096)) fields "failure"
  failureClass <- at (nullable parseFailure) fields "failureClass"
  supervision <- at supervisionState fields "supervision"
  integrity <- at (oneOf ["valid","corrupt","incomplete","unknown"]) fields "integrity"
  let projection (status,_,_) = RunSnapshot run status Nothing workflow target answering
        (Map.fromList [(snapshotOccurrenceId item,item) | item <- occurrences]) order recorded
        (Map.fromList [(snapshotControlId item,item) | item <- acknowledgements]) fresh memo Nothing failure failureClass
  pure (RunObservation run workflow target ((\(_,sequenceNumber,_) -> sequenceNumber) <$> runtime)
    ((\(_,_,protocol) -> protocol) <$> runtime) (projection <$> runtime) result verification supervision integrity
    (Map.fromList [(snapshotOccurrenceId item,decision) | (item,decision) <- parsed]) metadata items)) metadata

parseRuntime :: Value -> Parser (RunStatus,Word64,Int)
parseRuntime = withObject "runtime summary" $ \fields -> do
  closed ["status","lastSequence","protocolVersion"] fields
  status <- at (enum [("starting",RunStarting),("running",RunRunning),("cancelling",RunCancelling),
    ("succeeded",RunSucceeded),("failed",RunFailedStatus),("cancelled",RunCancelledStatus),("orphaned",RunOrphaned)]) fields "status"
  number <- at uint64 fields "lastSequence"
  protocol <- fields .: "protocolVersion"
  unless (protocol `elem` [1,2,3 :: Int]) (fail "runtime protocol")
  pure (status,number,protocol)

parseOccurrence :: Value -> Parser (OccurrenceSnapshot,Maybe Text)
parseOccurrence = withObject "occurrence" $ \fields -> do
  closed ["occurrenceId","state","code","intent","addressee","prompt","answer","dispatch","recovery",
    "reuseKind","source","failureClass","replayable","decisionId","personPending","attempts"] fields
  ident <- at occurrenceId fields "occurrenceId"
  attempts <- at (list 512 (parseAttempt ident)) fields "attempts" >>= uniqueBy snapshotAttemptId
  decision <- at (nullable identifier) fields "decisionId"
  value <- OccurrenceSnapshot ident
    <$> at (enum [("running",OccurrenceRunningState),("recovering",OccurrenceRecoveringState),
      ("reused",OccurrenceReusedState),("completed",OccurrenceCompletedState),("failed",OccurrenceFailedState),
      ("cancelled",OccurrenceCancelledState)]) fields "state"
    <*> at (oneOf ["text","verdict","flag","ack","structured"]) fields "code"
    <*> at (text 0 1024) fields "intent" <*> at (text 0 4096) fields "addressee"
    <*> at (text 0 524288) fields "prompt" <*> at (nullable (text 0 524288)) fields "answer"
    <*> at (nullable parseDispatch) fields "dispatch" <*> at (nullable parseRecovery) fields "recovery"
    <*> at (nullable (text 0 1024)) fields "reuseKind" <*> at (nullable (text 0 4096)) fields "source"
    <*> at (nullable parseFailure) fields "failureClass" <*> fields .: "replayable" <*> pure Nothing
    <*> fields .: "personPending" <*> pure (Map.fromList [(snapshotAttemptId attempt,attempt) | attempt <- attempts])
  pure (value,decision)

parseAttempt :: OccurrenceId -> Value -> Parser AttemptSnapshot
parseAttempt occurrence = withObject "attempt" $ \fields -> do
  closed ["address","targetLabel","state","output","steers","messages","tools","todos","usage",
    "reasoningSummaries","failure","failureClass"] fields
  ident <- at attemptAddress fields "address"
  unless (attemptOccurrence ident == occurrence) (fail "attempt address")
  tools <- at (list 128 parseTool) fields "tools" >>= uniqueBy publicToolId
  AttemptSnapshot ident <$> at (text 0 1024) fields "targetLabel"
    <*> at (enum [("running",AttemptRunning),("completed",AttemptCompletedState),("failed",AttemptFailedState)]) fields "state"
    <*> pure Nothing <*> at (text 0 65536) fields "output" <*> at (list 256 parseSteer) fields "steers"
    <*> at (list 128 (text 0 4096)) fields "messages" <*> pure (Map.fromList [(publicToolId tool,tool) | tool <- tools])
    <*> at (list 128 parseTodo) fields "todos" <*> at (nullable parseUsage) fields "usage"
    <*> at (list 128 (text 0 4096)) fields "reasoningSummaries"
    <*> at (nullable (text 0 4096)) fields "failure" <*> at (nullable parseFailure) fields "failureClass"

parseDispatch :: Value -> Parser DispatchSnapshot
parseDispatch = withObject "dispatch" $ \fields -> do
  closed ["targets","open","redirect"] fields
  DispatchSnapshot <$> at (list 256 (text 0 1024)) fields "targets" <*> fields .: "open"
    <*> at (nullable (withObject "redirect" $ \redirect -> do
      closed ["commandId","target"] redirect
      (,) <$> at identifier redirect "commandId" <*> at (text 0 1024) redirect "target")) fields "redirect"

parseRecovery :: Value -> Parser RecoverySnapshot
parseRecovery = withObject "recovery" $ \fields -> do
  closed ["gap","message","retries","choices","chosen"] fields
  RecoverySnapshot <$> at (text 0 4096) fields "gap" <*> at (text 0 4096) fields "message"
    <*> at (list 256 identifier) fields "retries" <*> at (list 16 parseRecoveryOption) fields "choices"
    <*> at (nullable (withObject "chosen recovery" $ \chosen -> do
      closed ["commandId","choice","target"] chosen
      option <- parseRecoveryOption (Object (KM.delete "commandId" chosen))
      RecoveryChosen <$> at identifier chosen "commandId" <*> pure (recoveryChoice option) <*> pure (recoveryTarget option))) fields "chosen"

parseRecoveryOption :: Value -> Parser RecoveryOption
parseRecoveryOption = withObject "recovery choice" $ \fields -> do
  closed ["choice","target"] fields
  choice <- at (oneOf ["retry","failover","abandon"]) fields "choice"
  target <- at (nullable (text 0 1024)) fields "target"
  unless (choice == "failover" || target == Nothing) (fail "recovery target")
  pure (RecoveryOption choice target)

parseSteer :: Value -> Parser SteerSnapshot
parseSteer = withObject "steer" $ \fields -> do
  closed ["commandId","timing","text"] fields
  SteerSnapshot <$> at identifier fields "commandId" <*> at (oneOf ["interrupt-now","next-boundary"]) fields "timing"
    <*> at (text 0 65536) fields "text"

parseTool :: Value -> Parser PublicToolUpdate
parseTool = withObject "tool" $ \fields -> do
  unless (KM.member "id" fields && all (`elem` ["id","title","toolKind","status","summary"]) (KM.keys fields)) (fail "tool fields")
  PublicToolUpdate <$> at (text 1 256) fields "id" <*> optional (text 0 1024) fields "title"
    <*> optional (text 0 128) fields "toolKind"
    <*> optional (oneOf ["pending","in_progress","completed","failed","cancelled"]) fields "status"
    <*> optional (text 0 4096) fields "summary"

parseTodo :: Value -> Parser PublicTodoItem
parseTodo = withObject "todo" $ \fields -> do
  closed ["content","priority","status"] fields
  PublicTodoItem <$> at (text 0 2048) fields "content" <*> at (oneOf ["high","medium","low"]) fields "priority"
    <*> at (oneOf ["pending","in_progress","completed"]) fields "status"

parseUsage :: Value -> Parser PublicUsage
parseUsage = withObject "usage" $ \fields -> do
  closed ["used","size"] fields
  used <- at natural fields "used"
  size <- at natural fields "size"
  unless (size > 0 && used <= size) (fail "usage bounds")
  pure (PublicUsage used size)

parseAcknowledgement :: Value -> Parser ControlAckSnapshot
parseAcknowledgement = withObject "acknowledgement" $ \fields -> do
  closed ["commandId","state","message","command","occurrenceId","attemptId"] fields
  command <- at (nullable (oneOf ["cancel","steer","retry","choose-recovery","redirect","answer"])) fields "command"
  occurrence <- at (nullable occurrenceId) fields "occurrenceId"
  attempt <- at (nullable uint32) fields "attemptId"
  unless (attempt == Nothing || occurrence /= Nothing) (fail "acknowledgement attempt")
  unless (command /= Just "answer" || (occurrence /= Nothing && attempt == Nothing)) (fail "answer address")
  ControlAckSnapshot <$> at identifier fields "commandId"
    <*> at (oneOf ["accepted","queued","delivered","rejected-stale","unsupported","failed"]) fields "state"
    <*> at (text 0 4096) fields "message" <*> pure command <*> pure occurrence <*> pure (AttemptId <$> occurrence <*> attempt)

parseResultReference :: Value -> Parser ResultReference
parseResultReference = withObject "result reference" $ \fields -> do
  closed ["artifactId","artifactVersion","sha256","bytes","code","preview"] fields
  version <- fields .: "artifactVersion" :: Parser Int
  unless (version == 1) (fail "artifact version")
  ResultReference <$> at identifier fields "artifactId" <*> at uint64 fields "bytes" <*> at digest fields "sha256"
    <*> at observationCode fields "code" <*> at (text 0 524288) fields "preview"

parseVerification :: Value -> Parser Verification
parseVerification = withObject "verification" $ \fields -> do
  state <- at (oneOf ["absent","referenced","verified","unavailable"]) fields "state"
  case state of
    "absent" -> closed ["state"] fields >> pure Absent
    "referenced" -> closed ["state","artifactId"] fields >> Referenced <$> at identifier fields "artifactId"
    "verified" -> closed ["state","artifactId"] fields >> Verified <$> at identifier fields "artifactId"
    _ -> do
      closed ["state","artifactId","reason"] fields
      Unavailable <$> at (nullable identifier) fields "artifactId"
        <*> at (oneOf ["missing","corrupt","unsupported-version","size-limit","ownership-unavailable"]) fields "reason"

parseControl :: Value -> Parser ControlView
parseControl raw = withObject "run controls" (\fields -> do
  closed ["version","runId","revision","supervision","cancelAllowed","offers","decisionHeadId"] fields
  versionOne fields
  ControlView <$> at identifier fields "runId" <*> at identifier fields "revision" <*> at supervisionState fields "supervision"
    <*> fields .: "cancelAllowed" <*> at (nullable identifier) fields "decisionHeadId"
    <*> at (list 512 parseOffer) fields "offers" <*> pure raw) raw

parseOffer :: Value -> Parser ControlOffer
parseOffer = withObject "control offer" $ \fields -> do
  closed ["operation","address","generation","timings","choices","targets"] fields
  operation <- at (oneOf ["steer","retry","choose-recovery","redirect","answer"]) fields "operation"
  (occurrence,attempt) <- if operation == "steer"
    then at (\value -> do AttemptId occurrence attempt <- attemptAddress value; pure (occurrence,Just attempt)) fields "address"
    else at (\value -> do occurrence <- occurrenceAddress value; pure (occurrence,Nothing)) fields "address"
  timings <- at (list 2 (oneOf ["interrupt-now","next-boundary"])) fields "timings" >>= uniqueBy id
  ControlOffer operation occurrence attempt <$> at (nullable identifier) fields "generation" <*> pure timings
    <*> at (list 16 parseRecoveryOption) fields "choices" <*> at (list 256 (text 0 1024)) fields "targets"

parseDecision :: Value -> Parser DecisionView
parseDecision raw = withObject "decision" (\fields -> do
  kind <- at (oneOf ["question","recovery"]) fields "kind"
  closed (["version","id","revision","runId","profileId","generation","address","state","position","observedSequence","queue","kind"]
    <> if kind == "question" then ["question"] else ["gap","message","choices"]) fields
  versionOne fields
  run <- at identifier fields "runId"
  queue <- at resourceLink fields "queue"
  unless (queue == "/v1/decisions?runId=" <> run) (fail "decision queue binding")
  position <- fields .: "position" :: Parser Int
  unless (position >= 0 && position <= 2047) (fail "decision position")
  content <- if kind == "question" then at parseQuestion fields "question"
    else RecoveryContent <$> at (text 0 4096) fields "gap" <*> at (text 0 4096) fields "message"
      <*> at (list 16 parseRecoveryOption) fields "choices"
  DecisionView <$> at identifier fields "id" <*> at identifier fields "revision" <*> pure run
    <*> at identifier fields "profileId" <*> at identifier fields "generation" <*> at occurrenceAddress fields "address"
    <*> at (oneOf ["pending","submitting","resolved","invalidated"]) fields "state" <*> pure position
    <*> at uint64 fields "observedSequence" <*> pure content <*> pure raw) raw

parseQuestion :: Value -> Parser DecisionContent
parseQuestion = withObject "question" $ \fields -> do
  closed ["code","semanticSchema","editorSchema","addressee","scope","draw","prompt"] fields
  code <- at observationCode fields "code"
  schema <- fields .: "semanticSchema"
  case schema of Null -> pure (); _ -> semanticSchema 0 schema
  case code of
    Object tagged | Just (Object structured) <- KM.lookup "json" tagged ->
      unless (KM.lookup "schema" structured == Just schema) (fail "question schema agreement")
    _ -> pure ()
  editor <- at (nullable (editorSchema 0)) fields "editorSchema"
  _ <- at (text 0 1024) fields "addressee"
  _ <- at (withObject "scope" $ \scope -> do
    closed ["model","mode"] scope
    (,) <$> at (nullable (text 0 1024)) scope "model" <*> at (nullable (text 0 1024)) scope "mode") fields "scope"
  _ <- at natural fields "draw"
  QuestionContent code editor <$> at (text 0 524288) fields "prompt"

-- | The editor schema of a question in the frozen editor vocabulary. An
-- object schema must be closed and must require each of its properties.
editorSchema :: Int -> Value -> Parser EditorSchema
editorSchema depth = withObject "editor schema" $ \fields -> do
  unless (depth < 64) (fail "editor schema depth")
  kind <- at (oneOf ["null","boolean","integer","number","string","array","object"]) fields "type"
  case kind of
    "array" -> closed ["type","items"] fields >> EditorArray <$> at (editorSchema (depth + 1)) fields "items"
    "object" -> do
      closed ["type","properties","required","additionalProperties"] fields
      properties <- fields .: "properties" :: Parser Object
      unless (KM.size properties <= 256 && all ((<=1024) . T.length . Key.toText) (KM.keys properties)) (fail "editor properties")
      schemas <- traverse (editorSchema (depth + 1)) (KM.toMapText properties)
      required <- at (list 256 (text 0 1024)) fields "required" >>= uniqueBy id
      additional <- fields .: "additionalProperties" :: Parser Bool
      unless (not additional && Set.fromList required == Map.keysSet schemas) (fail "editor required fields")
      pure (EditorObject schemas)
    _ -> closed ["type"] fields >> pure (case kind of
      "null" -> EditorNull
      "boolean" -> EditorBoolean
      "integer" -> EditorInteger
      "number" -> EditorNumber
      _ -> EditorString)

-- | Check a JSON answer against the editor schema of its question. The
-- refusal names the first field that does not agree, for example
-- @answer field ok must be a boolean@.
editorCheck :: EditorSchema -> Value -> Either Text ()
editorCheck = go "answer"
  where
    go place schema value = case (schema, value) of
      (EditorNull, Null) -> Right ()
      (EditorBoolean, Bool _) -> Right ()
      (EditorInteger, Number number) | number == fromInteger (truncate number) -> Right ()
      (EditorNumber, Number _) -> Right ()
      (EditorString, String _) -> Right ()
      (EditorArray item, Array values) ->
        mapM_ (\(index, element) -> go (place <> " item " <> T.pack (show index)) item element) (zip [0 :: Int ..] (V.toList values))
      (EditorObject properties, Object fields) -> do
        let given = KM.toMapText fields
        case Map.keys (Map.difference properties given) of
          name : _ -> Left (place <> " lacks the field " <> name)
          [] -> pure ()
        case Map.keys (Map.difference given properties) of
          name : _ -> Left (place <> " has the unknown field " <> name)
          [] -> pure ()
        mapM_ (\(name, (field, element)) -> go (place <> " field " <> name) field element)
          (Map.toList (Map.intersectionWith (,) properties given))
      _ -> Left (place <> " must be " <> editorSchemaNoun schema)

-- | The noun of an editor schema in a refusal.
editorSchemaNoun :: EditorSchema -> Text
editorSchemaNoun schema = case schema of
  EditorNull -> "null"
  EditorBoolean -> "a boolean"
  EditorInteger -> "an integer"
  EditorNumber -> "a number"
  EditorString -> "a string"
  EditorArray _ -> "an array"
  EditorObject _ -> "an object"

-- | One line that shows an editor schema to the operator, for example
-- @{"notes": [string], "ok": boolean}@.
editorSchemaText :: EditorSchema -> Text
editorSchemaText schema = case schema of
  EditorNull -> "null"
  EditorBoolean -> "boolean"
  EditorInteger -> "integer"
  EditorNumber -> "number"
  EditorString -> "string"
  EditorArray item -> "[" <> editorSchemaText item <> "]"
  EditorObject properties -> "{" <> T.intercalate ", " [quoted name <> ": " <> editorSchemaText field | (name, field) <- Map.toList properties] <> "}"
  where quoted name = "\"" <> name <> "\""

headMatches :: ControlView -> DecisionView -> Bool
headMatches control decision = controlRun control == decisionRun decision && controlSupervision control == "owned"
  && controlHead control == Just (decisionId decision) && decisionState decision == "pending" && decisionPosition decision == 0

matchingOffers :: ControlView -> DecisionView -> [ControlOffer]
matchingOffers control decision
  | headMatches control decision = [offer | offer <- controlOffers control, offerOccurrence offer == decisionOccurrence decision,
      offerAttempt offer == Nothing, offerGeneration offer == Just (decisionGeneration decision)]
  | otherwise = []

answerOffered :: ControlView -> DecisionView -> Bool
answerOffered control decision = case decisionContent decision of
  QuestionContent (String code) _ _ | code `elem` ["text","verdict","flag","receipt"] -> offered
  QuestionContent (Object _) _ _ -> offered
  _ -> False
  where offered = any ((== "answer") . offerOperation) (matchingOffers control decision)

retryOffer :: ControlView -> DecisionView -> Maybe ControlOffer
retryOffer control decision = case decisionContent decision of
  RecoveryContent _ _ choices | any ((== "retry") . recoveryChoice) choices ->
    listToMaybe [offer | offer <- matchingOffers control decision, offerOperation offer == "retry"]
      `orMaybe` listToMaybe [offer | offer <- matchingOffers control decision, offerOperation offer == "choose-recovery",
        any ((== "retry") . recoveryChoice) (offerChoices offer)]
  _ -> Nothing
  where orMaybe (Just value) _ = Just value; orMaybe Nothing value = value

-- | The head of the installed decision queue as the manager presents it.
-- A question carries its prompt. A recovery carries the snapshot occurrence
-- and its published recovery. The head is display data, not an owner.
data DecisionHead
  = QuestionHead !DecisionView !PersonPrompt
  | RecoveryHead !DecisionView !OccurrenceSnapshot !RecoverySnapshot
  deriving (Eq, Show)

-- | The decision head of one composite read of the run components, derived
-- only from that read. The controls must be owned and name the decision as
-- the pending head at position 0 of the same run. A recovery head also needs
-- the recovery that the snapshot publishes for the decision occurrence. No
-- other case has a head.
decisionHead :: RunRead observed -> Maybe DecisionHead
decisionHead (RunRead snapshot (_, control) decision) = do
  (_, view) <- decision
  unless (headMatches control view && decisionRun view == runIdText (runIdentity snapshot)) Nothing
  case decisionContent view of
    QuestionContent {} -> QuestionHead view <$> decisionPrompt view
    RecoveryContent {} -> do
      runtime <- runSnapshot snapshot
      occurrence <- Map.lookup (decisionOccurrence view) (snapshotOccurrences runtime)
      RecoveryHead view occurrence <$> snapshotOccurrenceRecovery occurrence

-- | The answer mutation for the editor input, given the request profile and
-- one composite read of the run components, with the decision observation
-- that becomes its precondition. The manager must offer an answer for the
-- owned pending head, the decision and the controls must belong to the run
-- of the snapshot and to the profile, and the snapshot occurrence must wait
-- for a person answer. The input is converted by the question code, so a
-- flag input "false" becomes JSON false and an unparsable input is refused
-- before any send.
answerMutation :: Text -> RunRead observed -> Text -> Either Text (Mutation, observed)
answerMutation profile (RunRead snapshot (_, control) decision) input = do
  (observed, view) <- maybe (Left "no decision is at the head of the queue") Right decision
  unless (answerOffered control view) (Left "the manager offers no answer for this decision")
  unless (decisionRun view == runIdText (runIdentity snapshot) && controlRun control == decisionRun view)
    (Left "the decision belongs to another run")
  unless (decisionProfile view == profile) (Left "the decision belongs to another profile")
  unless (maybe False snapshotOccurrencePersonPending (runSnapshot snapshot >>= Map.lookup (decisionOccurrence view) . snapshotOccurrences))
    (Left "the occurrence is not waiting for an answer")
  value <- answerValue view input
  Right (Answer view value, observed)

-- | The outcome of Ctrl-D on the displayed question head, given whether the
-- command lane already holds an answer to this decision, whether the
-- installed observation is stale, the request profile, the run components
-- and the editor input: the answer mutation with its precondition, or the
-- reason why nothing starts. An answer in flight decides first, so a second
-- Ctrl-D never starts a second answer.
answerKey :: Bool -> Bool -> Text -> RunRead observed -> Text -> Either Text (Mutation, observed)
answerKey pending stale profile components input
  | pending = Left "an answer to this decision is in flight."
  | stale = Left "the decision observation is stale."
  | otherwise = answerMutation profile components input

-- | The retry mutation for the recovery at the head, given the request
-- profile and one composite read of the run components, with the control
-- observation that becomes its precondition. Only 'retryOffer' selects the
-- offer, so the controls must be owned and name the decision as the pending
-- head at position 0, and the offer must match its occurrence and
-- generation. The decision and the controls must belong to the run of the
-- snapshot and to the profile, and the snapshot must publish the recovery of
-- the occurrence.
retryMutation :: Text -> RunRead observed -> Either Text (Mutation, observed)
retryMutation profile (RunRead snapshot (observed, control) decision) = do
  (_, view) <- maybe (Left "no decision is at the head of the queue") Right decision
  offer <- maybe (Left "the manager offers no retry for this decision") Right (retryOffer control view)
  unless (decisionRun view == runIdText (runIdentity snapshot) && controlRun control == decisionRun view)
    (Left "the decision belongs to another run")
  unless (decisionProfile view == profile) (Left "the decision belongs to another profile")
  occurrence <- maybe (Left "the snapshot publishes no recovery for this decision") Right
    (runSnapshot snapshot >>= Map.lookup (decisionOccurrence view) . snapshotOccurrences)
  unless (isJust (snapshotOccurrenceRecovery occurrence)) (Left "the snapshot publishes no recovery for this decision")
  let attempt = attemptNumber . fst <$> Map.lookupMax (snapshotOccurrenceAttempts occurrence)
  Right (Retry control view offer attempt, observed)

-- | The closed retry body for the offer kind: a retry offer sends the retry
-- operation, and a choose-recovery offer sends the retry choice.
retryBody :: DecisionView -> ControlOffer -> Value
retryBody decision offer = object $
  [ "operation" .= offerOperation offer, "occurrenceId" .= occurrenceText (decisionOccurrence decision),
    "generation" .= decisionGeneration decision ]
  <> ["choice" .= ("retry" :: Text) | offerOperation offer == "choose-recovery"]

-- | The effect kind that completes a retry of this offer kind.
retryEffect :: ControlOffer -> Text
retryEffect offer = if offerOperation offer == "retry" then "retried" else "recovery-chosen"

-- | Whether the control observation allows a cancel of its run: the manager
-- owns the live run and reports @cancelAllowed@.
cancelOffered :: ControlView -> Bool
cancelOffered control = controlSupervision control == "owned" && controlCancel control

-- | The cancel mutation for the request profile and one composite read of
-- the run components, with the control observation that becomes its
-- precondition. The control observation must allow the cancel and belong to
-- the run of the snapshot.
cancelMutation :: Text -> RunRead observed -> Either Text (Mutation, observed)
cancelMutation profile (RunRead snapshot (observed, control) _) = do
  unless (controlRun control == runIdText (runIdentity snapshot)) (Left "the controls belong to another run")
  unless (cancelOffered control) (Left "the manager offers no cancel for this run")
  Right (Cancel profile control, observed)

-- | The steer offer of an owned control observation with this timing. An
-- offer for the given occurrence comes first, and the first steer offer
-- otherwise. Every steer offer names one attempt.
steerOffer :: ControlView -> Maybe OccurrenceId -> Text -> Maybe ControlOffer
steerOffer control selected timing
  | controlSupervision control /= "owned" = Nothing
  | otherwise = listToMaybe ([offer | offer <- offers, Just (offerOccurrence offer) == selected] <> offers)
  where offers = [offer | offer <- controlOffers control, offerOperation offer == "steer", isJust (offerAttempt offer), timing `elem` offerTimings offer]

-- | The steer mutation for the request profile, one composite read of the
-- run components, the selected occurrence, the timing and the text, with
-- the control observation that becomes its precondition. Only 'steerOffer'
-- selects the offer, and an empty text is refused before any send.
steerMutation :: Text -> RunRead observed -> Maybe OccurrenceId -> Text -> Text -> Either Text (Mutation, observed)
steerMutation profile (RunRead snapshot (observed, control) _) selected timing message = do
  unless (controlRun control == runIdText (runIdentity snapshot)) (Left "the controls belong to another run")
  offer <- maybe (Left ("the manager offers no " <> timing <> " steer for this run")) Right (steerOffer control selected timing)
  when (T.null (T.strip message)) (Left "the steering text is empty")
  Right (Steer profile control offer timing message, observed)

-- | The closed steer body for the attempt of the offer.
steerBody :: ControlOffer -> Text -> Text -> Value
steerBody offer timing message = object
  [ "operation" .= ("steer" :: Text), "occurrenceId" .= occurrenceText (offerOccurrence offer),
    "attemptId" .= maybe "" (T.pack . show) (offerAttempt offer), "timing" .= timing, "text" .= message ]

-- | The choose-recovery offer of the control observation that carries this
-- choice for the recovery decision at the head, when the decision publishes
-- the choice. Only 'matchingOffers' supplies the candidates, so the controls
-- must be owned and name the decision as the pending head at position 0.
recoveryOffer :: ControlView -> DecisionView -> Text -> Maybe ControlOffer
recoveryOffer control decision choice = case decisionContent decision of
  RecoveryContent _ _ choices | any ((== choice) . recoveryChoice) choices ->
    listToMaybe [offer | offer <- matchingOffers control decision, offerOperation offer == "choose-recovery",
      any ((== choice) . recoveryChoice) (offerChoices offer)]
  _ -> Nothing

-- | The recovery-choice mutation for the request profile, one composite read
-- of the run components and the choice (@failover@ or @abandon@), with the
-- decision observation that becomes its precondition. Only 'recoveryOffer'
-- selects the offer. The decision and the controls must belong to the run of
-- the snapshot and to the profile, and the snapshot must publish the
-- recovery of the occurrence.
chooseRecoveryMutation :: Text -> RunRead observed -> Text -> Either Text (Mutation, observed)
chooseRecoveryMutation profile (RunRead snapshot (_, control) decision) choice = do
  (observed, view) <- maybe (Left "no decision is at the head of the queue") Right decision
  offer <- maybe (Left ("the manager offers no " <> choice <> " for this decision")) Right (recoveryOffer control view choice)
  unless (decisionRun view == runIdText (runIdentity snapshot) && controlRun control == decisionRun view)
    (Left "the decision belongs to another run")
  unless (decisionProfile view == profile) (Left "the decision belongs to another profile")
  occurrence <- maybe (Left "the snapshot publishes no recovery for this decision") Right
    (runSnapshot snapshot >>= Map.lookup (decisionOccurrence view) . snapshotOccurrences)
  unless (isJust (snapshotOccurrenceRecovery occurrence)) (Left "the snapshot publishes no recovery for this decision")
  let attempt = attemptNumber . fst <$> Map.lookupMax (snapshotOccurrenceAttempts occurrence)
  Right (ChooseRecovery control view offer choice attempt, observed)

-- | The closed choose-recovery body for one decision and choice.
chooseRecoveryBody :: DecisionView -> Text -> Value
chooseRecoveryBody decision choice = object
  [ "operation" .= ("choose-recovery" :: Text), "occurrenceId" .= occurrenceText (decisionOccurrence decision),
    "generation" .= decisionGeneration decision, "choice" .= choice ]

-- | The redirect offer of an owned control observation. An offer for the
-- given occurrence comes first, and the first redirect offer otherwise. The
-- run monitor lists the targets of this offer, and the digit keys choose
-- among them, so both use this one selection. An offer exists inside the
-- dispatch window of an occurrence and, after the window, for the attempt in
-- flight of an occurrence that is not an effect.
redirectOffer :: ControlView -> Maybe OccurrenceId -> Maybe ControlOffer
redirectOffer control selected
  | controlSupervision control /= "owned" = Nothing
  | otherwise = listToMaybe ([offer | offer <- offers, Just (offerOccurrence offer) == selected] <> offers)
  where offers = [offer | offer <- controlOffers control, offerOperation offer == "redirect", not (null (offerTargets offer))]

-- | Whether the snapshot publishes an open dispatch window for the
-- occurrence of the offer, and the attempt in flight of that occurrence when
-- exactly one attempt runs.
redirectPlace :: RunObservation -> ControlOffer -> (Bool, Maybe Word32)
redirectPlace snapshot offer = case runSnapshot snapshot >>= Map.lookup (offerOccurrence offer) . snapshotOccurrences of
  Nothing -> (False, Nothing)
  Just occurrence
    | maybe False dispatchOpen (snapshotOccurrenceDispatch occurrence) -> (True, Nothing)
    | otherwise -> (False, case [attemptNumber ident | (ident, attempt) <- Map.toList (snapshotOccurrenceAttempts occurrence),
        snapshotAttemptState attempt == AttemptRunning] of
          [number] -> Just number
          _ -> Nothing)

-- | The redirect mutation for the request profile, one composite read of the
-- run components, the selected occurrence and the zero-based index of a
-- digit key, with the control observation that becomes its precondition.
-- Only 'redirectOffer' selects the offer, and a target that the offer does
-- not hold is refused before any send. The attempt of a live redirect is the
-- attempt in flight that the snapshot publishes.
redirectMutation :: Text -> RunRead observed -> Maybe OccurrenceId -> Int -> Either Text (Mutation, observed)
redirectMutation profile (RunRead snapshot (observed, control) _) selected index = do
  unless (controlRun control == runIdText (runIdentity snapshot)) (Left "the controls belong to another run")
  offer <- maybe (Left "the manager offers no redirect for this run") Right (redirectOffer control selected)
  target <- maybe (Left ("the manager offers no target " <> T.pack (show (index + 1)) <> " for occurrence " <> occurrenceText (offerOccurrence offer)))
    Right (if index < 0 then Nothing else listToMaybe (drop index (offerTargets offer)))
  Right (Redirect profile control offer target (snd (redirectPlace snapshot offer)), observed)

-- | The closed redirect body for the occurrence of the offer and one target.
redirectBody :: ControlOffer -> Text -> Value
redirectBody offer target = object
  [ "operation" .= ("redirect" :: Text), "occurrenceId" .= occurrenceText (offerOccurrence offer), "target" .= target ]

-- | The redirect line of the live monitor: the occurrence that the digit
-- keys redirect, whether its dispatch window is open or which attempt is in
-- flight, and each offered target with its digit. It is empty when the
-- installed control observation offers no redirect.
redirectLines :: ControlView -> RunObservation -> Maybe OccurrenceId -> [Text]
redirectLines control snapshot selected = case redirectOffer control selected of
  Nothing -> []
  Just offer ->
    let place = case redirectPlace snapshot offer of
          (True, _) -> " in its dispatch window"
          (False, Just number) -> ", attempt " <> T.pack (show number) <> " in flight"
          (False, Nothing) -> ""
     in ["Redirect occurrence " <> occurrenceText (offerOccurrence offer) <> place <> ": "
          <> T.intercalate "   " [T.pack (show digit) <> " " <> target | (digit, target) <- zip [1 :: Int .. 9] (offerTargets offer)]]

-- | Whether a mutation is a cancel, a steer, a recovery choice or a redirect
-- of a run.
controlMutation :: Mutation -> Bool
controlMutation = isJust . controlMutationRun

-- | The run of a cancel, a steer, a recovery choice or a redirect. No other
-- mutation has one.
controlMutationRun :: Mutation -> Maybe Text
controlMutationRun mutation = case mutation of
  Cancel _ control -> Just (controlRun control)
  Steer _ control _ _ _ -> Just (controlRun control)
  ChooseRecovery control _ _ _ _ -> Just (controlRun control)
  Redirect _ control _ _ _ -> Just (controlRun control)
  _ -> Nothing

-- | The displayed outcome of a cancel, a steer, a recovery choice or a
-- redirect that its own receipt shows. A runtime acknowledgement that
-- rejects the control (@rejected-stale@, @unsupported@ or @failed@) is the
-- outcome of every control: the control ends without an effect, and nothing
-- is sent again. A cancel is accepted when the runtime acknowledgement
-- accepts, queues or delivers it. The runtime cancellation names no control,
-- so the receipt records no cancel effect, and only the snapshot shows the
-- cancelled run. A steer completes on the effect steered, a recovery choice
-- on the effect recovery-chosen, and a redirect on the effect redirected. No
-- other receipt has an outcome.
controlOutcome :: Mutation -> C.CommandReceipt -> Maybe Text
controlOutcome mutation receipt
  | not (receiptMatches mutation receipt) || not (controlMutation mutation) = Nothing
  | Just rejected <- acknowledgementState receipt, rejected `elem` ["rejected-stale","unsupported","failed"] =
      Just (label <> ": runtime acknowledgement " <> rejected)
  | otherwise = case (mutation, C.stateName (C.receiptState receipt), receiptEffectKind receipt) of
      (Cancel {}, state, _) | state `elem` ["acknowledged","effect-observed"],
        Just accepted <- acknowledgementState receipt, accepted `elem` ["accepted","queued","delivered"] -> Just "cancel accepted"
      (Steer {}, "effect-observed", Just "steered") -> Just "steered"
      (ChooseRecovery _ _ _ "failover" _, "effect-observed", Just "recovery-chosen") -> Just "failed over"
      (ChooseRecovery _ _ _ "abandon" _, "effect-observed", Just "recovery-chosen") -> Just "abandoned"
      (Redirect _ _ offer target attempt, "effect-observed", Just "redirected") ->
        Just ("redirected occurrence " <> occurrenceText (offerOccurrence offer)
          <> maybe "" (\number -> " from attempt " <> T.pack (show number)) attempt <> " to " <> target)
      _ -> Nothing
  where
    label = case mutation of
      Redirect _ _ _ target _ -> "redirect to " <> target
      _ -> mutationOperation mutation

-- | The state of the runtime acknowledgement that a receipt records.
acknowledgementState :: C.CommandReceipt -> Maybe Text
acknowledgementState receipt = case toJSON <$> C.receiptAcknowledgement receipt of
  Just (Object fields) | Just (String state) <- KM.lookup "state" fields -> Just state
  _ -> Nothing

-- | The control line of the live monitor, given the run and the outcome of
-- its latest completed control and the installed run observation. An
-- accepted cancel shows @cancel accepted@ and waits for the runtime status
-- cancelled until the snapshot publishes it. It never shows a finished or
-- succeeded state. Every other outcome shows as its receipt shows it.
controlLines :: Maybe (Text, Text) -> Maybe RunObservation -> [Text]
controlLines outcome run = case (outcome, run) of
  (Just (ident, label), Just observed) | ident == runIdText (runIdentity observed) -> case (label, runtimeStatus observed) of
    ("cancel accepted", Just RunCancelledStatus) -> ["Control: cancel accepted; the runtime status is Cancelled"]
    ("cancel accepted", _) -> ["Control: cancel accepted; waiting for the runtime status Cancelled"]
    _ -> ["Control: " <> label]
  _ -> []

-- | The closed answer body for one decision.
answerBody :: DecisionView -> Value -> Value
answerBody decision value = object
  [ "operation" .= ("answer" :: Text), "occurrenceId" .= occurrenceText (decisionOccurrence decision),
    "generation" .= decisionGeneration decision, "value" .= value ]

occurrenceText :: OccurrenceId -> Text
occurrenceText = T.pack . show . occurrenceNumber

decisionPrompt :: DecisionView -> Maybe PersonPrompt
decisionPrompt decision = case decisionContent decision of
  QuestionContent code schema prompt -> Just (PersonPrompt (decisionOccurrence decision)
    (case (code, schema) of
      (String name, _) -> name
      (_, Just editor) -> "structured JSON " <> editorSchemaText editor
      _ -> "structured") "question" prompt)
  _ -> Nothing

-- | The JSON answer of the editor input. A question with a code name
-- converts the input with 'personAnswerValue'. A structured question takes
-- JSON text, which must agree with the editor schema of the decision before
-- any send.
answerValue :: DecisionView -> Text -> Either Text Value
answerValue decision input = case decisionContent decision of
  QuestionContent (String code) _ _ -> personAnswerValue code input
  QuestionContent (Object _) (Just schema) _ -> do
    value <- personAnswerValue "structured" input
    editorCheck schema value
    Right value
  QuestionContent _ _ _ -> Left "the decision gives no editor schema for its structured answer"
  RecoveryContent {} -> Left "a recovery decision takes no answer"

-- | The run components of one composite read: the complete snapshot page
-- set, the run controls with their observation, and the observation of the
-- decision at the head of the control queue when the controls name one. The
-- observations are display and precondition data only.
data RunRead observed = RunRead
  { runReadSnapshot :: !RunObservation,
    runReadControl :: !(observed, ControlView),
    runReadDecision :: !(Maybe (observed, DecisionView))
  } deriving (Eq, Show)

-- | One composite read of the selection: the request of a request
-- selection, its preparation in the review phase, the result of the receipt
-- read for a retained command together with that command's mutation, and the
-- run components when the selection names a run. A run selection reads no
-- request and no preparation. A declared receipt failure stays in its slot.
data RequestRead observed = RequestRead
  { readRequest :: !(Maybe (observed, C.DraftView)),
    readPreparation :: !(Maybe (observed, C.Preparation)),
    readReceipt :: !(Maybe (Mutation, Either C.ClientFailure C.CommandReceipt)),
    readRun :: !(Maybe (RunRead observed))
  } deriving (Eq, Show)

-- | The selected identity. A request selection names the request and the
-- run that its installed observation names. A read of the run components
-- takes place only when the run is known. A run selection names a run by its
-- identifier and the profile that its overview item names, so a run without
-- a request of this session can be read.
data Selection
  = RequestSelection !Text !(Maybe Text)
  | RunSelection !Text !Text
  deriving (Eq, Show)

-- | The run that the selection names, when it names one.
selectedRun :: Selection -> Maybe Text
selectedRun selection = case selection of
  RequestSelection _ run -> run
  RunSelection run _ -> Just run

-- | The resources that the composite read of the selection reads, given
-- the installed composite read and the receipt URI of a retained command:
-- the request, the preparation that the installed request names, the run of
-- the selection, the decision at the head of the installed run controls and
-- the receipt. An invalidation of one of these resources, or of a resource
-- below or above one of them, invalidates the composite read.
compositeResources :: Selection -> Maybe (RequestRead observed) -> Maybe Text -> [Text]
compositeResources selection installed receipt =
  ["/v1/requests/" <> request | RequestSelection request _ <- [selection]]
    <> ["/v1/preparations/" <> preparation | Just preparation <- [installed >>= readRequest >>= C.draftPreparation . snd]]
    <> ["/v1/runs/" <> ident | Just ident <- [selectedRun selection]]
    <> ["/v1/decisions/" <> decision | Just decision <- [installed >>= readRun >>= controlHead . snd . runReadControl]]
    <> [uri | Just uri <- [receipt]]

-- | How a delivered composite read relates to the current selection.
data ReadVerdict
  = -- | Every component is valid for the selection. The read may be installed.
    ReadCurrent
  | -- | The read concerns another request. It is not installed.
    ReadForeign
  | -- | A component is invalid or missing. The read is not installed.
    ReadInvalid
  deriving (Eq, Show)

readRequestId :: RequestRead observed -> Maybe Text
readRequestId = fmap (C.draftId . snd) . readRequest

readRequestRun :: RequestRead observed -> Maybe Text
readRequestRun composite = readRequest composite >>= C.draftRun . snd

-- | Decide a delivered composite read against the current selection. The
-- first argument reads the URI and entity tag of an observation.
--
-- A read for another request is foreign. A read whose request names another
-- run than the selected one, or no run, is invalid, so a changed association
-- marks the installed observation stale and is never discarded silently. A
-- read is current only when the request and any preparation are
-- bound to their own URIs and revisions, and when the run components are
-- present exactly when the selection names a run and are valid for that run
-- and the request profile. A read before association that observes the first
-- association carries no run components. The next read reads them.
--
-- For a run selection, a read with a request, or with run components of
-- another run, is foreign. A read is current only when it carries no
-- request and no preparation, and its run components are valid for the
-- selected run and profile.
readVerdict :: (observed -> (Text, Text)) -> Selection -> RequestRead observed -> ReadVerdict
readVerdict binding selection composite = case (selection, readRequest composite) of
  (RequestSelection selected run, Just (requestObserved, request))
    | C.draftId request /= selected -> ReadForeign
    | Just ident <- run, C.draftRun request /= Just ident -> ReadInvalid
    | not (bound binding requestObserved ("/v1/requests/" <> C.draftId request) (C.draftRevision request)) -> ReadInvalid
    | not (all (preparationBound request) (readPreparation composite)) -> ReadInvalid
    | otherwise -> case (run, readRun composite) of
        (Nothing, Nothing) -> ReadCurrent
        (Just ident, Just components) | runReadValid binding (C.draftProfile request) ident components -> ReadCurrent
        _ -> ReadInvalid
  (RunSelection run profile, Nothing) -> case readRun composite of
    Just components
      | runIdText (runIdentity (runReadSnapshot components)) /= run -> ReadForeign
      | null (readPreparation composite), runReadValid binding profile run components -> ReadCurrent
    _ -> ReadInvalid
  _ -> ReadForeign
  where
    preparationBound request (observed, preparation) = C.draftPreparation request == Just (C.preparationId preparation)
      && bound binding observed ("/v1/preparations/" <> C.preparationId preparation) (C.preparationRevision preparation)

-- | Whether the run components are valid for this profile and run. The
-- snapshot and the controls name the run, the controls observation carries
-- the entity tag of their revision, and a decision is present exactly when
-- the controls name a head. That decision is the head, belongs to the run and
-- the profile, and its observation carries the entity tag of its revision.
runReadValid :: (observed -> (Text, Text)) -> Text -> Text -> RunRead observed -> Bool
runReadValid binding profile run (RunRead snapshot (controlObserved, control) decision) =
  runIdText (runIdentity snapshot) == run && controlRun control == run
    && bound binding controlObserved ("/v1/runs/" <> run <> "/control") (controlRevision control)
    && case (controlHead control, decision) of
      (Nothing, Nothing) -> True
      (Just headId, Just (decisionObserved, view)) -> decisionId view == headId && decisionRun view == run
        && decisionProfile view == profile && bound binding decisionObserved ("/v1/decisions/" <> headId) (decisionRevision view)
      _ -> False

-- | The runtime status that the snapshot publishes. A null runtime publishes
-- none, and none is invented.
runtimeStatus :: RunObservation -> Maybe RunStatus
runtimeStatus = fmap snapshotRunStatus . runSnapshot

-- | Display lines for the installed observation, given whether automatic
-- refresh is paused after a deferred key, the refusal code of the latest read
-- when that read was refused, whether a complete read is installed, and the
-- installed run snapshot. A paused refresh replaces the current-observation
-- line. A null runtime is shown as not yet observed, without a status. A
-- supervision other than @owned@ follows the runtime status as the manager
-- reports it, for example @Runtime: Running; supervision lost@ for a run
-- whose manager lifetime ended, so such a run is never shown as completed.
observationLines :: Bool -> Maybe Text -> Bool -> Maybe RunObservation -> [Text]
observationLines paused stale installed run = case (stale, installed) of
  (Nothing, False) -> []
  (Nothing, True)
    | paused -> "Observation: automatic refresh paused after a deferred key" : runtime
    | otherwise -> "Observation: current" : runtime
  (Just code, True) -> ("Observation: stale (" <> code <> "); the last complete observation is retained") : runtime
  (Just code, False) -> ["Observation: refused (" <> code <> "); no complete observation is installed"]
  where
    runtime = maybe [] (\observed -> ["Runtime: " <> maybe "not yet observed" runStatusLabel (runtimeStatus observed)
      <> supervised (runSupervision observed)]) run
    supervised supervision = if supervision == "owned" then "" else "; supervision " <> supervision

-- | The displayed approval receipt status after one request read, given the
-- retained approval, the receipt read of this read with the mutation whose
-- receipt it read, and the status before it. An approval always has a
-- status, and "outcome unresolved" stands in for a status that no readable
-- receipt has set. Only a readable receipt of the approval sets a receipt
-- state. An unreadable receipt of the approval keeps the earlier state and
-- states that the read was unavailable. A receipt read of another command,
-- or no receipt read, changes nothing. No case supplies a resolved state.
approvalStatus :: Mutation -> Maybe (Mutation, Either C.ClientFailure C.CommandReceipt) -> Maybe Text -> Text
approvalStatus approval result before = case result of
  Just (_, Right received) | receiptMatches approval received -> C.stateName (C.receiptState received)
  Just (owner, Left _) | owner == approval -> maybe unresolved (\status -> maybe status id (T.stripSuffix unavailable status)) before <> unavailable
  _ -> maybe unresolved id before
  where
    unresolved = "outcome unresolved"
    unavailable = " (receipt read unavailable)"

-- | The declared reason to leave a pending attempt unresolved, taken from the
-- receipt read of this read. Only a readable receipt of that attempt that the
-- manager reports as refused or unresolved settles it. A runtime
-- acknowledgement that rejects a run control is an outcome of the control,
-- as 'controlOutcome' shows it, and not a settlement. An unreadable receipt
-- settles nothing, so it never offers an exact resend.
receiptSettlement :: Mutation -> Maybe (Mutation, Either C.ClientFailure C.CommandReceipt) -> Maybe Text
receiptSettlement mutation result = case result of
  Just (_, Right received) | receiptMatches mutation received, C.stateName (C.receiptState received) `elem` ["refused","unresolved"] ->
    Just (C.stateName (C.receiptState received))
  _ -> Nothing

parseOutput :: Value -> Parser (Maybe Artifact)
parseOutput = withObject "output" $ \fields -> do
  kind <- at (oneOf ["attempt","diagnostic","result"]) fields "kind"
  case kind of
    "attempt" -> do
      closed ["kind","address","transportText"] fields
      _ <- at attemptAddress fields "address"
      _ <- at (text 0 65536) fields "transportText"
      pure Nothing
    "diagnostic" -> closed ["kind","message"] fields >> at (text 0 8192) fields "message" >> pure Nothing
    _ -> do
      closed ["kind","verification","artifact"] fields
      verification <- at parseVerification fields "verification"
      artifact <- at (nullable parseArtifact) fields "artifact"
      case (verification,artifact) of
        (Verified ident,Just value) | artifactId value == ident -> pure (Just value)
        (Verified _,_) -> fail "verified artifact absent"
        _ -> pure Nothing

parseArtifact :: Value -> Parser Artifact
parseArtifact = withObject "artifact" $ \fields -> do
  closed ["id","runId","kind","code","bytes","sha256","download"] fields
  size <- at uint64 fields "bytes"
  unless (size <= 67108864) (fail "artifact bound")
  Artifact <$> at identifier fields "id" <*> at identifier fields "runId"
    <*> at (oneOf ["source-result","export"]) fields "kind" <*> at observationCode fields "code"
    <*> pure (fromIntegral size) <*> at digest fields "sha256" <*> at resourceLink fields "download"

parseFailure :: Value -> Parser FailureClass
parseFailure = enum [("setup",FailureSetup),("transport",FailureTransport),("decode",FailureDecode),
  ("protocol",FailureProtocol),("cancelled",FailureCancelled),("runtime",FailureRuntime)]

supervisionState :: Value -> Parser Text
supervisionState = oneOf ["owned","cleanup-pending","lost","observer"]

optional :: (Value -> Parser a) -> Object -> Key.Key -> Parser (Maybe a)
optional parser fields key = maybe (pure Nothing) (fmap Just . parser) (KM.lookup key fields)

enum :: [(Text,a)] -> Value -> Parser a
enum entries = withText "enum" $ \value -> maybe (fail "unknown enum") pure (lookup value entries)

uint64 :: Value -> Parser Word64
uint64 value = do
  _ <- text 1 20 value
  number <- natural value
  unless (number <= toInteger (maxBound :: Word64)) (fail "UInt64")
  pure (fromInteger number)

uint32 :: Value -> Parser Word32
uint32 value = do
  _ <- text 1 10 value
  number <- natural value
  unless (number <= toInteger (maxBound :: Word32)) (fail "UInt32")
  pure (fromInteger number)

occurrenceId :: Value -> Parser OccurrenceId
occurrenceId value = OccurrenceId <$> uint64 value

occurrenceAddress :: Value -> Parser OccurrenceId
occurrenceAddress = withObject "occurrence address" $ \fields -> closed ["occurrenceId"] fields >> at occurrenceId fields "occurrenceId"

attemptAddress :: Value -> Parser AttemptId
attemptAddress = withObject "attempt address" $ \fields -> do
  closed ["occurrenceId","attemptId"] fields
  AttemptId <$> at occurrenceId fields "occurrenceId" <*> at uint32 fields "attemptId"

digest :: Value -> Parser Text
digest value = do
  checksum <- text 64 64 value
  unless (T.all (`elem` ("0123456789abcdef" :: String)) checksum) (fail "SHA256")
  pure checksum

resourceLink :: Value -> Parser Text
resourceLink value = do
  uri <- text 4 8192 value
  unless ("/v1/" `T.isPrefixOf` uri && T.all (`elem` (['A'..'Z'] <> ['a'..'z'] <> ['0'..'9'] <> "_/?=&.%-")) uri) (fail "resource URI")
  pure uri
