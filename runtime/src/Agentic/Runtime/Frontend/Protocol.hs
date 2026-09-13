{-# LANGUAGE OverloadedStrings #-}

-- | The version-1 frontend transport, without execution or storage authority.
module Agentic.Runtime.Frontend.Protocol
  ( FrontendSetupRequest (..),
    FrontendSetup (..),
    FrontendInputSource (..),
    frontendLiteralBytes,
    FrontendEdit (..),
    FrontendDecision (..),
    FrontendPrepared (..),
    FrontendPreparedInput (..),
    FrontendPreparedLineage (..),
    FrontendEditMetadata (..),
    FrontendCapabilities (..),
    frontendCapabilities,
    maxFrontendQueryBytes,
    maxFrontendReplyBytes,
    parseSetupRequest,
    parseSetup,
    parseInput,
    parseEdit,
    parseDecision,
    encodeFrontendSetupRequest,
    decodeFrontendSetupRequest,
    encodeFrontendDecision,
    decodeFrontendDecision,
    encodeFrontendPrepared,
    decodeFrontendPrepared,
    encodeFrontendCapabilities,
    decodeFrontendCapabilities,
  )
where

import Agentic.Runtime.Catalogue
  ( FrontendInvocation,
    FrontendServer,
    frontendManifestVersion,
    frontendManifestVersionWithInvocation,
  )
import Agentic.Runtime.Descriptor (WorkflowDescriptor, WorkflowInputSource (..))
import Agentic.Runtime.Plan (parseExactPlan)
import Agentic.Runtime.Protocol
  ( OccurrenceId (..),
    PersonAnswering (..),
    RunId (..),
    maxArtifactBytes,
    maxFrameBytes,
    mkRunId,
  )
import Agentic.Runtime.Store (LineageOperation (..))
import Control.Monad (unless, when)
import Data.Aeson (FromJSON (parseJSON), ToJSON (toJSON), Value (..), eitherDecodeStrict', encode, object, withObject, (.:), (.:?), (.=))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import Data.Aeson.Types (Object, Pair, Parser, parseEither)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as Text
import qualified Data.Text.Read as TextRead
import Data.Word (Word64)
import System.FilePath (isAbsolute)

-- | Bound allowing a runtime reference and its separately encoded root identity.
maxFrontendQueryBytes :: Int
maxFrontendQueryBytes = 2 * maxFrameBytes

-- | The complete native reply bound, including its terminating newline.
maxFrontendReplyBytes :: Integer
maxFrontendReplyBytes = maxArtifactBytes + 4096

-- | One requested answer change, retaining the exact JSON replacement value.
data FrontendEdit = DropAnswer !OccurrenceId | ReplaceAnswer !OccurrenceId !Value
  deriving (Eq, Show)

-- | A root preparation or a request to prepare an immutable parent's lineage.
data FrontendSetupRequest
  = RootSetup !FrontendSetup
  | DerivedSetup !FilePath !RunId !LineageOperation ![FrontendEdit] !PersonAnswering !(Maybe FrontendInvocation)
  deriving (Eq, Show)

-- | The transport representation of an input, before workflow-specific capture.
data FrontendInputSource = Literal !Text | File !FilePath | Transport !Text
  deriving (Eq, Show)

-- | Native transport bytes for one logical literal, before workflow interpretation.
frontendLiteralBytes :: WorkflowInputSource -> Text -> BS.ByteString
frontendLiteralBytes source value = Text.encodeUtf8 value <> if source == DescriptorPrompt then "\n" else ""

-- | The parameters supplied to root preparation, without a resolved workflow.
data FrontendSetup = FrontendSetup
  { setupWorkflow :: !Text,
    setupDirectory :: !FilePath,
    setupArguments :: ![Text],
    setupTargetKind :: !(Maybe Text),
    setupPerson :: !PersonAnswering,
    setupInputs :: ![(Text, FrontendInputSource)],
    setupInvocation :: !(Maybe FrontendInvocation)
  }
  deriving (Eq, Show)

-- | A decision naming one live preparation, not a stored run's authority.
data FrontendDecision = FrontendStart !Text | FrontendDiscard !Text
  deriving (Eq, Show)

-- | The public metadata for a captured input, without its bytes or source path.
data FrontendPreparedInput = FrontendPreparedInput
  { preparedInputName :: !Text,
    preparedInputBytes :: !Integer,
    preparedInputSha256 :: !Text
  }
  deriving (Eq, Show)

-- | An answer edit's public metadata, which never substitutes a digest for an answer.
data FrontendEditMetadata
  = DroppedAnswer !OccurrenceId
  | ReplacedAnswer !OccurrenceId !Text
  deriving (Eq, Show)

-- | The optional, jointly present lineage fields of a prepared reply.
data FrontendPreparedLineage = FrontendPreparedLineage
  { preparedParentRunId :: !RunId,
    preparedLineageOperation :: !LineageOperation,
    preparedLineageEdits :: ![FrontendEditMetadata]
  }
  deriving (Eq, Show)

-- | The native preview of one live preparation. Identities remain observations.
-- The plan is validated by the runtime plan codec and retained without rewriting.
-- Public policy is an opaque object, not a second backend policy interpreter.
data FrontendPrepared = FrontendPrepared
  { preparedApprovalId :: !Text,
    preparedRunId :: !RunId,
    preparedRootIdentity :: !Text,
    preparedCwd :: !FilePath,
    preparedDescriptor :: !WorkflowDescriptor,
    preparedPlan :: !Value,
    preparedProgramHash :: !Text,
    preparedTargetKind :: !Text,
    preparedTargetArguments :: ![Text],
    preparedPolicy :: !Value,
    preparedPersonAnswering :: !PersonAnswering,
    preparedServer :: !FrontendServer,
    preparedInvocation :: !(Maybe FrontendInvocation),
    preparedInputs :: ![FrontendPreparedInput],
    preparedLineage :: !(Maybe FrontendPreparedLineage)
  }
  deriving (Eq, Show)

-- | A process's advertised interfaces, separate from a client's requirements.
data FrontendCapabilities = FrontendCapabilityReply
  { capabilityServer :: !FrontendServer,
    capabilitySessionVersions :: ![Int],
    capabilitySessionOperations :: ![Text],
    capabilityInputSources :: ![Text],
    capabilityInvocationVersions :: ![Int],
    capabilityMaxRequestBytes :: !Integer,
    capabilityIoVersions :: ![Int],
    capabilityIoOperations :: ![Text],
    capabilityExportVersions :: ![Int],
    capabilityExportOperations :: ![Text],
    capabilityExportFormat :: !Text,
    capabilityExportDestination :: !Text,
    capabilityManifestVersions :: ![Int],
    capabilityLegacyManifests :: !Bool
  }
  deriving (Eq, Show)

-- | The advertisement emitted by the native frontend, with its actual server.
frontendCapabilities :: FrontendServer -> FrontendCapabilities
frontendCapabilities server = FrontendCapabilityReply
  { capabilityServer = server,
    capabilitySessionVersions = [1],
    capabilitySessionOperations = ["prepare", "prepare-lineage", "start", "discard"],
    capabilityInputSources = ["literal", "file", "transport"],
    capabilityInvocationVersions = [1],
    capabilityMaxRequestBytes = toInteger maxFrontendQueryBytes,
    capabilityIoVersions = [1, 2],
    capabilityIoOperations = ["open-root", "read-question", "read-result", "list-runs", "read-run", "read-run-checkpoint", "read-question-schema"],
    capabilityExportVersions = [1],
    capabilityExportOperations = ["export-result"],
    capabilityExportFormat = "result-json",
    capabilityExportDestination = "state-exports",
    capabilityManifestVersions = [frontendManifestVersion, frontendManifestVersionWithInvocation],
    capabilityLegacyManifests = True
  }

instance FromJSON FrontendSetupRequest where
  parseJSON = parseSetupRequest

instance FromJSON FrontendSetup where
  parseJSON = parseSetup

instance FromJSON FrontendEdit where
  parseJSON = parseEdit

instance ToJSON FrontendSetupRequest where
  toJSON (RootSetup setup) = toJSON setup
  toJSON (DerivedSetup directory parent lineage edits answering invocation) =
    request "prepare-lineage" $
      [ "stateDirectory" .= directory,
        "parentRunId" .= runIdText parent,
        "lineage" .= lineage,
        "edits" .= edits,
        "personAnswering" .= answering
      ] <> invocationFields invocation

instance ToJSON FrontendSetup where
  toJSON setup = request "prepare" $
    [ "workflow" .= setupWorkflow setup,
      "stateDirectory" .= setupDirectory setup,
      "targetArguments" .= setupArguments setup,
      "personAnswering" .= setupPerson setup,
      "inputs" .= map inputValue (setupInputs setup)
    ] <> maybe [] (\kind -> ["targetKind" .= kind]) (setupTargetKind setup)
      <> invocationFields (setupInvocation setup)

instance ToJSON FrontendEdit where
  toJSON (DropAnswer occurrence) = object
    ["occurrenceId" .= occurrenceText occurrence, "operation" .= ("drop" :: Text)]
  toJSON (ReplaceAnswer occurrence answer) = object
    ["occurrenceId" .= occurrenceText occurrence, "operation" .= ("replace" :: Text), "answer" .= answer]

inputValue :: (Text, FrontendInputSource) -> Value
inputValue (name, source) = object (["name" .= name] <> case source of
  Literal value -> ["source" .= ("literal" :: Text), "value" .= value]
  File path -> ["source" .= ("file" :: Text), "path" .= path]
  Transport value -> ["source" .= ("transport" :: Text), "value" .= value])

invocationFields :: Maybe FrontendInvocation -> [Pair]
invocationFields = maybe [] (\invocation -> ["invocation" .= invocation])

instance FromJSON FrontendDecision where
  parseJSON value = withObject "frontend decision" (\o -> do
    approval <- o .: "approvalId"
    start <- parseDecision approval value
    pure (if start then FrontendStart approval else FrontendDiscard approval)) value

instance ToJSON FrontendDecision where
  toJSON (FrontendStart approval) = request "start" ["approvalId" .= approval]
  toJSON (FrontendDiscard approval) = request "discard" ["approvalId" .= approval]

parseSetupRequest :: Value -> Parser FrontendSetupRequest
parseSetupRequest value = withObject "frontend preparation" (\o -> do
  version <- o .: "version"
  unless (version == (1 :: Int)) (fail "unsupported frontend request version")
  operation <- o .: "operation"
  case operation :: Text of
    "prepare" -> RootSetup <$> parseSetup value
    "prepare-lineage" -> do
      onlyKeys ["version", "operation", "stateDirectory", "parentRunId", "lineage", "edits", "personAnswering", "invocation"] o
      directory <- o .: "stateDirectory"
      unless (isAbsolute directory && not ('\0' `elem` directory) && BS.length (Text.encodeUtf8 (T.pack directory)) <= 4096) (fail "frontend state directory must be an absolute bounded path")
      parent <- o .: "parentRunId" >>= either (fail . T.unpack) pure . mkRunId
      lineage <- o .: "lineage" >>= \caseName -> case caseName :: Text of
        "restart" -> pure RestartRun
        "resume" -> pure ResumeRun
        "fork" -> pure ForkRun
        _ -> fail "frontend lineage must be restart, resume, or fork"
      edits <- o .:? "edits" >>= maybe (pure []) (traverse parseEdit)
      unless (null edits || lineage == ForkRun) (fail "answer edits require fork lineage")
      person <- o .:? "personAnswering"
      invocation <- optionalInvocation o
      pure (DerivedSetup directory parent lineage edits (maybe PersonAnswerLocalControl id person) invocation)
    _ -> fail "frontend requires preparation before a decision") value

parseEdit :: Value -> Parser FrontendEdit
parseEdit = withObject "frontend answer edit" $ \o -> do
  occurrence <- o .: "occurrenceId" >>= parseEditOccurrence
  operation <- o .: "operation"
  case operation :: Text of
    "drop" -> onlyKeys ["occurrenceId", "operation"] o >> pure (DropAnswer occurrence)
    "replace" -> onlyKeys ["occurrenceId", "operation", "answer"] o >> ReplaceAnswer occurrence <$> o .: "answer"
    _ -> fail "frontend edit must drop or replace an answer"

parseEditOccurrence :: Text -> Parser OccurrenceId
parseEditOccurrence text = case TextRead.decimal text :: Either String (Integer, Text) of
  Right (number, rest) | T.null rest && T.length text <= 20 && number <= toInteger (maxBound :: Word64) -> pure (OccurrenceId (fromInteger number))
  _ -> fail "frontend edit occurrence must be a Word64 decimal string"

parseSetup :: Value -> Parser FrontendSetup
parseSetup = withObject "frontend preparation" $ \o -> do
  onlyKeys ["version", "operation", "workflow", "stateDirectory", "targetArguments", "targetKind", "personAnswering", "inputs", "invocation"] o
  version <- o .: "version"
  unless (version == (1 :: Int)) (fail "unsupported frontend request version")
  operation <- o .: "operation"
  unless (operation == ("prepare" :: Text)) (fail "frontend requires preparation before a decision")
  workflow <- o .: "workflow"
  directory <- o .: "stateDirectory"
  unless (isAbsolute directory && not ('\0' `elem` directory) && BS.length (Text.encodeUtf8 (T.pack directory)) <= 4096) (fail "frontend state directory must be an absolute bounded path")
  arguments <- o .: "targetArguments"
  when (length arguments > 4096 || sum (map (BS.length . Text.encodeUtf8) arguments) > 65536 || any (T.any (== '\0')) arguments) (fail "frontend target arguments must be bounded and NUL-free")
  kind <- o .:? "targetKind"
  person <- o .:? "personAnswering"
  inputs <- o .: "inputs" >>= traverse parseInput
  invocation <- optionalInvocation o
  pure (FrontendSetup workflow directory arguments kind (maybe PersonAnswerLocalControl id person) inputs invocation)

parseInput :: Value -> Parser (Text, FrontendInputSource)
parseInput = withObject "frontend input" $ \o -> do
  name <- o .: "name"
  source <- o .: "source"
  case source :: Text of
    "literal" -> do
      onlyKeys ["name", "source", "value"] o
      value <- o .: "value"
      pure (name, Literal value)
    "file" -> do
      onlyKeys ["name", "source", "path"] o
      path <- o .: "path"
      unless (isAbsolute path && not ('\0' `elem` path) && BS.length (Text.encodeUtf8 (T.pack path)) <= 4096) (fail "frontend input file must be an absolute bounded path")
      pure (name, File path)
    "transport" -> do
      onlyKeys ["name", "source", "value"] o
      value <- o .: "value"
      pure (name, Transport value)
    _ -> fail "frontend input source must be literal, file, or transport"

parseDecision :: Text -> Value -> Parser Bool
parseDecision expected = withObject "frontend decision" $ \o -> do
  onlyKeys ["version", "operation", "approvalId"] o
  version <- o .: "version"
  unless (version == (1 :: Int)) (fail "unsupported frontend request version")
  approval <- o .: "approvalId"
  unless (approval == expected) (fail "frontend approval does not name this prepared execution")
  operation <- o .: "operation"
  case operation :: Text of
    "start" -> pure True
    "discard" -> pure False
    _ -> fail "frontend decision must be start or discard"

onlyKeys :: [Text] -> Object -> Parser ()
onlyKeys allowed object' =
  unless (all ((`elem` allowed) . Key.toText) (KeyMap.keys object')) (fail "frontend request has unknown fields")

optionalInvocation :: Object -> Parser (Maybe FrontendInvocation)
optionalInvocation object' = traverse parseJSON (KeyMap.lookup "invocation" object')

instance ToJSON FrontendPreparedInput where
  toJSON input = object
    [ "name" .= preparedInputName input,
      "bytes" .= T.pack (show (preparedInputBytes input)),
      "sha256" .= preparedInputSha256 input
    ]

instance FromJSON FrontendPreparedInput where
  parseJSON = withObject "frontend prepared input" $ \o -> do
    replyKeys ["name", "bytes", "sha256"] o
    name <- o .: "name"
    bytes <- o .: "bytes" >>= parseInputBytes
    digest <- o .: "sha256" >>= parseDigest
    pure (FrontendPreparedInput name bytes digest)

parseInputBytes :: Text -> Parser Integer
parseInputBytes text
  | T.length text > T.length (T.pack (show maxArtifactBytes)) = invalid
  | otherwise = case TextRead.decimal text :: Either String (Integer, Text) of
      Right (number, rest)
        | T.null rest && text == T.pack (show number) && number <= maxArtifactBytes -> pure number
      _ -> invalid
  where
    invalid = fail "frontend prepared input bytes must be a bounded natural decimal string"

instance ToJSON FrontendEditMetadata where
  toJSON (DroppedAnswer occurrence) = object
    ["operation" .= ("drop" :: Text), "occurrenceId" .= occurrenceText occurrence]
  toJSON (ReplacedAnswer occurrence digest) = object
    ["operation" .= ("replace" :: Text), "occurrenceId" .= occurrenceText occurrence, "sha256" .= digest]

instance FromJSON FrontendEditMetadata where
  parseJSON = withObject "frontend lineage edit metadata" $ \o -> do
    occurrence <- o .: "occurrenceId" >>= parseEditOccurrence
    operation <- o .: "operation"
    case operation :: Text of
      "drop" -> replyKeys ["operation", "occurrenceId"] o >> pure (DroppedAnswer occurrence)
      "replace" -> do
        replyKeys ["operation", "occurrenceId", "sha256"] o
        ReplacedAnswer occurrence <$> (o .: "sha256" >>= parseDigest)
      _ -> fail "frontend lineage edit metadata must drop or replace an answer"

instance ToJSON FrontendPrepared where
  toJSON prepared = request "prepared" $
    [ "approvalId" .= preparedApprovalId prepared,
      "runId" .= runIdText (preparedRunId prepared),
      "rootIdentity" .= preparedRootIdentity prepared,
      "cwd" .= preparedCwd prepared,
      "descriptor" .= preparedDescriptor prepared,
      "plan" .= preparedPlan prepared,
      "programHash" .= preparedProgramHash prepared,
      "targetKind" .= preparedTargetKind prepared,
      "targetArguments" .= preparedTargetArguments prepared,
      "policy" .= preparedPolicy prepared,
      "personAnswering" .= preparedPersonAnswering prepared,
      "server" .= preparedServer prepared,
      "invocation" .= preparedInvocation prepared,
      "inputs" .= preparedInputs prepared
    ] <> maybe [] lineageFields (preparedLineage prepared)
    where
      lineageFields lineage =
        [ "parentRunId" .= runIdText (preparedParentRunId lineage),
          "lineage" .= preparedLineageOperation lineage,
          "lineageEdits" .= preparedLineageEdits lineage
        ]

instance FromJSON FrontendPrepared where
  parseJSON = withObject "frontend prepared reply" $ \o -> do
    replyKeys
      [ "version", "operation", "approvalId", "runId", "rootIdentity", "cwd",
        "descriptor", "plan", "programHash", "targetKind", "targetArguments",
        "policy", "personAnswering", "server", "invocation", "inputs",
        "parentRunId", "lineage", "lineageEdits"
      ] o
    replyEnvelope "prepared" o
    approval <- o .: "approvalId"
    run <- o .: "runId" >>= either (fail . T.unpack) pure . mkRunId
    identity <- o .: "rootIdentity"
    cwd <- o .: "cwd"
    descriptor <- o .: "descriptor"
    plan <- o .: "plan"
    _ <- parseExactPlan plan
    programHash <- o .: "programHash" >>= parseDigest
    kind <- o .: "targetKind"
    arguments <- o .: "targetArguments"
    policy <- o .: "policy" >>= withObject "frontend public policy" (pure . Object)
    answering <- o .: "personAnswering"
    server <- o .: "server"
    invocation <- o .: "invocation"
    inputs <- o .: "inputs"
    let names = map preparedInputName inputs
    unless (length names == Set.size (Set.fromList names)) (fail "frontend prepared inputs contain duplicate names")
    when (sum (map preparedInputBytes inputs) > maxArtifactBytes) (fail "frontend prepared inputs exceed their byte bound")
    lineage <- if any (`KeyMap.member` o) ["parentRunId", "lineage", "lineageEdits"]
      then do
        parent <- o .: "parentRunId" >>= either (fail . T.unpack) pure . mkRunId
        operation <- o .: "lineage"
        unless (operation `elem` [RestartRun, ResumeRun, ForkRun]) (fail "frontend lineage must be restart, resume, or fork")
        edits <- o .: "lineageEdits"
        unless (null edits || operation == ForkRun) (fail "answer edits require fork lineage")
        pure (Just (FrontendPreparedLineage parent operation edits))
      else pure Nothing
    pure (FrontendPrepared approval run identity cwd descriptor plan programHash kind arguments policy answering server invocation inputs lineage)

instance ToJSON FrontendCapabilities where
  toJSON capabilities = request "capabilities"
    [ "server" .= capabilityServer capabilities,
      "session" .= object
        [ "versions" .= capabilitySessionVersions capabilities,
          "operations" .= capabilitySessionOperations capabilities,
          "inputSources" .= capabilityInputSources capabilities,
          "invocationVersions" .= capabilityInvocationVersions capabilities,
          "maxRequestBytes" .= capabilityMaxRequestBytes capabilities
        ],
      "io" .= object
        [ "versions" .= capabilityIoVersions capabilities,
          "operations" .= capabilityIoOperations capabilities
        ],
      "export" .= object
        [ "versions" .= capabilityExportVersions capabilities,
          "operations" .= capabilityExportOperations capabilities,
          "format" .= capabilityExportFormat capabilities,
          "destination" .= capabilityExportDestination capabilities
        ],
      "frontendManifestVersions" .= capabilityManifestVersions capabilities,
      "legacyFrontendManifests" .= capabilityLegacyManifests capabilities
    ]

instance FromJSON FrontendCapabilities where
  parseJSON = withObject "frontend capabilities" $ \o -> do
    replyKeys ["version", "operation", "server", "session", "io", "export", "frontendManifestVersions", "legacyFrontendManifests"] o
    replyEnvelope "capabilities" o
    server <- o .: "server"
    (versions, operations, sources, invocationVersions, bound) <- o .: "session" >>= withObject "frontend session capabilities" (\fields -> do
      replyKeys ["versions", "operations", "inputSources", "invocationVersions", "maxRequestBytes"] fields
      versions <- fields .: "versions"
      operations <- fields .: "operations"
      sources <- fields .: "inputSources"
      invocationVersions <- fields .: "invocationVersions"
      bound <- fields .: "maxRequestBytes"
      when (bound <= 0) (fail "frontend session request byte bound must be positive")
      pure (versions, operations, sources, invocationVersions, bound))
    (ioVersions, ioOperations) <- o .: "io" >>= withObject "frontend IO capabilities" (\fields -> do
      replyKeys ["versions", "operations"] fields
      (,) <$> fields .: "versions" <*> fields .: "operations")
    (exportVersions, exportOperations, format, destination) <- o .: "export" >>= withObject "frontend export capabilities" (\fields -> do
      replyKeys ["versions", "operations", "format", "destination"] fields
      (,,,) <$> fields .: "versions" <*> fields .: "operations" <*> fields .: "format" <*> fields .: "destination")
    manifests <- o .: "frontendManifestVersions"
    legacy <- o .: "legacyFrontendManifests"
    pure (FrontendCapabilityReply server versions operations sources invocationVersions bound ioVersions ioOperations exportVersions exportOperations format destination manifests legacy)

replyKeys :: [Text] -> Object -> Parser ()
replyKeys allowed fields =
  unless (all ((`elem` allowed) . Key.toText) (KeyMap.keys fields)) (fail "frontend reply has unknown fields")

replyEnvelope :: Text -> Object -> Parser ()
replyEnvelope expected fields = do
  version <- fields .: "version"
  unless (version == (1 :: Int)) (fail "unsupported frontend reply version")
  operation <- fields .: "operation"
  unless (operation == expected) (fail "unexpected frontend reply operation")

parseDigest :: Text -> Parser Text
parseDigest digest
  | T.length digest == 64 && T.all (\c -> c `elem` ['0' .. '9'] || c `elem` ['a' .. 'f']) digest = pure digest
  | otherwise = fail "frontend digest is not a lowercase SHA-256"

occurrenceText :: OccurrenceId -> Text
occurrenceText = T.pack . show . occurrenceNumber

request :: Text -> [Pair] -> Value
request operation fields = object (["version" .= (1 :: Int), "operation" .= operation] <> fields)

-- | Encode a validated JSON payload. The adapter supplies the NDJSON newline.
-- Request decoders consume the payload returned by readNdjsonFrame.
encodeFrontendSetupRequest :: FrontendSetupRequest -> Either Text BS.ByteString
encodeFrontendSetupRequest = encodeBounded (toInteger maxFrontendQueryBytes) "frontend request exceeds its byte bound" parseSetupRequest . toJSON

decodeFrontendSetupRequest :: BS.ByteString -> Either Text FrontendSetupRequest
decodeFrontendSetupRequest = decodeRequest parseSetupRequest

encodeFrontendDecision :: FrontendDecision -> Either Text BS.ByteString
encodeFrontendDecision = encodeBounded (toInteger maxFrontendQueryBytes) "frontend request exceeds its byte bound" (parseJSON :: Value -> Parser FrontendDecision) . toJSON

-- | Decode against the approval held by the live worker, preserving its refusals.
decodeFrontendDecision :: Text -> BS.ByteString -> Either Text Bool
decodeFrontendDecision expected = decodeRequest (parseDecision expected)

encodeFrontendPrepared :: FrontendPrepared -> Either Text BS.ByteString
encodeFrontendPrepared = encodeReply (parseJSON :: Value -> Parser FrontendPrepared) . toJSON

decodeFrontendPrepared :: BS.ByteString -> Either Text FrontendPrepared
decodeFrontendPrepared = decodeReply

encodeFrontendCapabilities :: FrontendCapabilities -> Either Text BS.ByteString
encodeFrontendCapabilities = encodeReply (parseJSON :: Value -> Parser FrontendCapabilities) . toJSON

decodeFrontendCapabilities :: BS.ByteString -> Either Text FrontendCapabilities
decodeFrontendCapabilities = decodeReply

decodeRequest :: (Value -> Parser a) -> BS.ByteString -> Either Text a
decodeRequest parser bytes
  | BS.length bytes > maxFrontendQueryBytes = Left "frontend request exceeds its byte bound"
  | otherwise = do
      value <- either (const (Left "frontend request is not valid JSON")) Right (eitherDecodeStrict' bytes)
      either (Left . T.pack) Right (parseEither parser value)

decodeReply :: FromJSON a => BS.ByteString -> Either Text a
decodeReply bytes
  | toInteger (BS.length bytes) > maxFrontendReplyBytes = Left "frontend preview exceeds its byte bound"
  | otherwise = either (Left . T.pack) Right (eitherDecodeStrict' bytes)

-- Reserve the newline counted by the native reply sender, but leave framing to it.
encodeReply :: (Value -> Parser a) -> Value -> Either Text BS.ByteString
encodeReply = encodeBounded (maxFrontendReplyBytes - 1) "frontend preview exceeds its byte bound"

encodeBounded :: Integer -> Text -> (Value -> Parser a) -> Value -> Either Text BS.ByteString
encodeBounded bound failure parser value = do
  let payload = encode value
  when (toInteger (BL.length payload) > bound) (Left failure)
  _ <- either (Left . T.pack) Right (parseEither parser value)
  pure (BL.toStrict payload)
