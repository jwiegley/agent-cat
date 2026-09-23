{-# LANGUAGE OverloadedStrings #-}

-- | Public manager observations used by the existing terminal presentation.
-- These records carry no local launch, process, filesystem or control authority.
module Agentic.Tui.Service
  ( Profile (..), Workflow (..), loadProfiles, loadWorkflows,
    decodeProfile, decodeWorkflow, createBody,
    Mutation (..), mutationOperation, mutationURI, mutationProfile, prepareMutation,
    observeDraft, observePreparation, observeReceipt, requestMatches, reviewMatches, reviewLive,
    requestReady, literalInputs, receiptMatches, receiptEffectKind, approvalBody, approvalSelectors,
    RunObservation (..), ResultReference (..), Verification (..), Artifact (..),
    ControlView (..), ControlOffer (..), DecisionView (..), DecisionContent (..),
    observeSnapshot, observeControl, observeDecision, observeResult, decodeSnapshot, decodeControl, decodeDecision,
    decisionPrompt, answerValue, answerOffered, retryOffer, headMatches
  ) where

import qualified Agentic.Manager.Client as C
import Agentic.Runtime
  ( DescriptorCapabilities (..), WorkflowDescriptor (..),
    WorkflowInputDescriptor (..), WorkflowInputSource (..), frontendLiteralBytes,
    RunSnapshot (..), RunStatus (..), OccurrenceSnapshot (..), OccurrenceState (..),
    AttemptSnapshot (..), AttemptState (..), AttemptId (..), OccurrenceId (..),
    DispatchSnapshot (..), RecoverySnapshot (..), RecoveryChosen (..), RecoveryOption (..),
    SteerSnapshot (..), ControlAckSnapshot (..), PublicToolUpdate (..), PublicTodoItem (..),
    PublicUsage (..), FailureClass (..), PersonAnswering (..), mkRunId )
import Agentic.Tui.Person (PersonPrompt (..), personAnswerValue)
import Control.Monad (unless)
import Crypto.Hash (Digest, SHA256, hash)
import qualified Data.ByteString as BS
import qualified Data.Map.Strict as Map
import Data.Time.Clock (UTCTime)
import Data.Time.Format.ISO8601 (iso8601ParseM)
import Data.Aeson (Object, Value (..), object, parseJSON, withArray, withObject, withText, (.:), (.=))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson.Types (Parser, parseEither)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Vector as V
import Data.Word (Word32, Word64)
import Data.Maybe (listToMaybe)

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

collection :: C.Client -> Text -> ([Value] -> Parser a) -> IO (Either C.ClientFailure a)
collection client uri parser = case C.reference client uri of
  Left failure -> pure (Left failure)
  Right location -> do
    received <- C.getPageSet client location
    pure $ received >>= \pages -> decode (withObject "collection metadata" (\fields -> do
      closed ["version"] fields
      versionOne fields
      parser (C.pageSetItems pages))) (C.pageSetMetadata pages)

-- | The closed request-creation body, bound to the selected catalogue identity.
createBody :: Workflow -> Value
createBody row = object
  [ "workflowId" .= workflowId row, "descriptorRevision" .= workflowRevision row,
    "profileId" .= workflowProfile row, "profileRevision" .= workflowProfileRevision row ]

-- | One explicit user intent. It is data, not a dispatch ticket.
data Mutation
  = Create !Workflow
  | SaveLiteral !C.DraftView !Text !Text !Int
  | Enqueue !C.DraftView
  | Approve !C.DraftView !C.Preparation

mutationOperation :: Mutation -> Text
mutationOperation mutation = case mutation of
  Create _ -> "create"
  SaveLiteral {} -> "set-input"
  Enqueue _ -> "enqueue"
  Approve {} -> "approve"

mutationURI :: Mutation -> Text
mutationURI mutation = case mutation of
  Create _ -> "/v1/requests"
  SaveLiteral request _ _ _ -> requestURI request
  Enqueue request -> requestURI request
  Approve _ preparation -> "/v1/preparations/" <> C.preparationId preparation

mutationProfile :: Mutation -> Text
mutationProfile mutation = case mutation of
  Create row -> workflowProfile row
  SaveLiteral request _ _ _ -> C.draftProfile request
  Enqueue request -> C.draftProfile request
  Approve _ preparation -> C.preparationProfile preparation

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
        let C.Readiness declarations _ _ _ = C.draftReadiness request
        unless (C.draftPhase request == "draft" && name `elem` [n | C.InputDeclaration n _ <- declarations]) (Left C.InvalidResponse)
        Right (object ["operation" .= ("set-input" :: Text), "input" .= object
          ["name" .= name, "source" .= ("literal" :: Text), "value" .= value]])
      Enqueue request -> fromDraft request $
        if C.draftPhase request == "draft" && requestReady request
        then Right (object ["operation" .= ("enqueue" :: Text)]) else Left C.InvalidResponse
      Approve request preparation -> case observed of
        Just current | owned current (mutationURI mutation) (C.preparationRevision preparation),
          C.decodeObservation (C.observedValue current) == Right preparation,
          C.preparationRequest preparation == C.draftId request,
          C.preparationRequestRevision preparation == C.draftRevision request,
          C.draftPreparation request == Just (C.preparationId preparation),
          reviewLive now preparation -> C.prepareObserved client current (approvalBody preparation)
        _ -> pure (Left C.InvalidResponse)
  where
    needed = case mutation of Approve {} -> ["observe","submit","control"]; _ -> ["observe","submit"]
    permitted = case C.clientCapabilities client of
      Object fields -> case (KM.lookup "scopes" fields, KM.lookup "profileIds" fields) of
        (Just (Array scopes),Just (Array profiles)) -> all ((`V.elem` scopes) . String) needed
          && String (mutationProfile mutation) `V.elem` profiles
        _ -> False
      _ -> False
    fromDraft request body = case (observed,body) of
      (Just current,Right value) | owned current (requestURI request) (C.draftRevision request),
        C.decodeObservation (C.observedValue current) == Right request -> C.prepareObserved client current value
      _ -> pure (Left C.InvalidResponse)

owned :: C.Observed -> Text -> Text -> Bool
owned observed uri revision = C.referenceURI (C.observedReference observed) == uri
  && C.observedETag observed == "\"" <> revision <> "\""

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

requestMatches :: Workflow -> C.DraftView -> Bool
requestMatches row request = C.draftWorkflow request == workflowId row
  && C.draftDescriptorRevision request == workflowRevision row
  && C.draftProfile request == workflowProfile row && C.draftProfileRevision request == workflowProfileRevision row
  && declarations == [C.InputDeclaration (workflowInputName input) (sourceName (workflowInputSource input))
                    | input <- workflowInputs (workflowDisplay row)]
  where C.Readiness declarations _ _ _ = C.draftReadiness request

sourceName :: WorkflowInputSource -> Text
sourceName source = case source of DescriptorPrompt -> "prompt"; DescriptorCommandTail -> "command-tail"; DescriptorStdin -> "stdin"

requestReady :: C.DraftView -> Bool
requestReady request = case C.draftReadiness request of C.Readiness _ _ missing errors -> null missing && null errors

literalInputs :: C.DraftView -> Map.Map Text Text
literalInputs request = case C.draftReadiness request of
  C.Readiness _ supplied _ _ -> Map.fromList [(name,value) | C.LiteralValue name value <- supplied]

-- | Agreement of the exact review with the selected request's native input bytes.
-- Logical literals are unchanged. Prompt transport's declared LF is included by Runtime.
reviewMatches :: Workflow -> C.DraftView -> C.Preparation -> Bool
reviewMatches row request preparation = requestMatches row request && requestReady request
  && C.draftPreparation request == Just (C.preparationId preparation)
  && C.preparationRequest preparation == C.draftId request
  && C.preparationRequestRevision preparation == C.draftRevision request
  && C.preparationProfile preparation == C.draftProfile request
  && C.preparationProfileRevision preparation == C.draftProfileRevision request
  && C.preparationDescriptorRevision preparation == C.draftDescriptorRevision request
  && C.reviewWorkflow review == workflowId row && C.reviewProfile review == workflowProfile row
  && Map.size literals == length inputs && traverse binding inputs == Just (C.reviewInputs review)
  where
    review = C.preparationReview preparation
    literals = literalInputs request
    inputs = workflowInputs (workflowDisplay row)
    binding input = do
      logical <- Map.lookup (workflowInputName input) literals
      let bytes = frontendLiteralBytes (workflowInputSource input) logical
      pure (C.ReviewInput (workflowInputName input) "literal" (T.pack (show (BS.length bytes)))
        (T.pack (show (hash bytes :: Digest SHA256))))

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

receiptMatches :: Mutation -> C.CommandReceipt -> Bool
receiptMatches mutation receipt = C.operationName (C.receiptOperation receipt) == mutationOperation mutation
  && C.receiptProfile receipt == mutationProfile mutation && C.receiptResource receipt == mutationURI mutation
  && (mutationOperation mutation `notElem` ["set-input","enqueue"] || case C.effectValue <$> C.receiptEffect receipt of
       Nothing -> True
       Just (Object fields) -> KM.lookup "resource" fields == Just (String (mutationURI mutation))
       _ -> False)

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
  unless (T.all (`elem` (['A'..'Z'] <> ['a'..'z'] <> ['0'..'9'] <> "_-")) ident) (fail "identifier")
  pure ident

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
-- Private references and a last native envelope are not reconstructed.
data RunObservation = RunObservation
  { runIdentity :: !Text, runSequence :: !(Maybe Word64), runProtocol :: !(Maybe Int),
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

data DecisionContent = QuestionContent !Value !Text | RecoveryContent !Text !Text ![RecoveryOption]
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
      unless (runIdentity result == ident) (Left C.InvalidResponse)
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
observeResult client snapshot = case C.reference client ("/v1/runs/" <> runIdentity snapshot <> "/outputs") of
  Left failure -> pure (Left failure)
  Right location -> do
    received <- C.getPageSet client location
    pure $ do
      pages <- received
      decode (withObject "output metadata" (\fields -> do
        closed ["version","runId"] fields
        versionOne fields
        ident <- at identifier fields "runId"
        unless (ident == runIdentity snapshot) (fail "output run")
        entries <- traverse parseOutput (C.pageSetItems pages)
        let artifacts = [artifact | Just artifact <- entries]
        unless (length artifacts <= 1) (fail "ambiguous result")
        case (artifacts,runResult snapshot,runVerification snapshot) of
          ([artifact],Just reference,Verified expected) -> do
            unless (artifactRun artifact == ident && artifactKind artifact == "source-result"
              && artifactId artifact == expected && resultArtifact reference == expected
              && fromIntegral (artifactBytes artifact) == resultBytes reference
              && artifactDigest artifact == resultDigest reference && artifactCode artifact == resultCode reference) (fail "result binding")
            pure (Just artifact)
          ([],_,_) -> pure Nothing
          _ -> fail "result verification")) (C.pageSetMetadata pages)

decodeControl :: Value -> Either C.ClientFailure ControlView
decodeControl = decode parseControl

decodeDecision :: Value -> Either C.ClientFailure DecisionView
decodeDecision = decode parseDecision

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
  pure (RunObservation ident ((\(_,sequenceNumber,_) -> sequenceNumber) <$> runtime)
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
  _ <- at (nullable (editorSchema 0)) fields "editorSchema"
  _ <- at (text 0 1024) fields "addressee"
  _ <- at (withObject "scope" $ \scope -> do
    closed ["model","mode"] scope
    (,) <$> at (nullable (text 0 1024)) scope "model" <*> at (nullable (text 0 1024)) scope "mode") fields "scope"
  _ <- at natural fields "draw"
  QuestionContent code <$> at (text 0 524288) fields "prompt"

editorSchema :: Int -> Value -> Parser ()
editorSchema depth = withObject "editor schema" $ \fields -> do
  unless (depth < 64) (fail "editor schema depth")
  kind <- at (oneOf ["null","boolean","integer","number","string","array","object"]) fields "type"
  case kind of
    "array" -> closed ["type","items"] fields >> at (editorSchema (depth + 1)) fields "items"
    "object" -> do
      closed ["type","properties","required","additionalProperties"] fields
      properties <- fields .: "properties" :: Parser Object
      unless (KM.size properties <= 256 && all ((<=1024) . T.length . Key.toText) (KM.keys properties)) (fail "editor properties")
      mapM_ (editorSchema (depth + 1)) (KM.elems properties)
      required <- at (list 256 (text 0 1024)) fields "required" >>= uniqueBy id
      additional <- fields .: "additionalProperties" :: Parser Bool
      unless (not additional && Set.fromList required == Set.fromList (map Key.toText (KM.keys properties))) (fail "editor required fields")
    _ -> closed ["type"] fields

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
  QuestionContent (String code) _ | code `elem` ["text","verdict","flag","receipt"] ->
    any ((== "answer") . offerOperation) (matchingOffers control decision)
  _ -> False

retryOffer :: ControlView -> DecisionView -> Maybe ControlOffer
retryOffer control decision = case decisionContent decision of
  RecoveryContent _ _ choices | any ((== "retry") . recoveryChoice) choices ->
    listToMaybe [offer | offer <- matchingOffers control decision, offerOperation offer == "retry"]
      `orMaybe` listToMaybe [offer | offer <- matchingOffers control decision, offerOperation offer == "choose-recovery",
        any ((== "retry") . recoveryChoice) (offerChoices offer)]
  _ -> Nothing
  where orMaybe (Just value) _ = Just value; orMaybe Nothing value = value

decisionPrompt :: DecisionView -> Maybe PersonPrompt
decisionPrompt decision = case decisionContent decision of
  QuestionContent code prompt -> Just (PersonPrompt (decisionOccurrence decision)
    (case code of String name -> name; _ -> "structured") "question" prompt)
  _ -> Nothing

answerValue :: DecisionView -> Text -> Either Text Value
answerValue decision input = case decisionContent decision of
  QuestionContent (String code) _ -> personAnswerValue code input
  _ -> Left "structured answer editor is not available"

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
