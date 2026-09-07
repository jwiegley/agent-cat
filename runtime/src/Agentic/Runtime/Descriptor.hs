{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Versioned workflow descriptors shared by process frontends.
module Agentic.Runtime.Descriptor
  ( WorkflowInputSource (..),
    WorkflowInputDescriptor (..),
    DescriptorCapabilities (..),
    WorkflowDescriptor (..),
    descriptorVersion,
    latestDescriptorVersion,
    workflowDescriptorFields,
    encodeWorkflowDescriptor,
    decodeWorkflowDescriptor,
    decodeWorkflowDescriptors,
  )
where

import Control.Monad (unless, when)
import Data.Aeson
  ( FromJSON (parseJSON),
    ToJSON (toJSON),
    Value,
    eitherDecodeStrict',
    encode,
    object,
    withObject,
    withText,
    (.:),
    (.:?),
    (.!=),
    (.=),
  )
import Data.Aeson.Key (toText)
import Data.Aeson.KeyMap (keys)
import Data.Aeson.Types (Object, Pair, Parser)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.List (nub)
import Data.Text (Text)
import qualified Data.Text as T

-- | The operator channel from which one workflow input is collected.
data WorkflowInputSource
  = DescriptorPrompt
  | DescriptorCommandTail
  | DescriptorStdin
  deriving (Eq, Ord, Show)

-- | One declared workflow input, in the order the frontend must request it.
data WorkflowInputDescriptor = WorkflowInputDescriptor
  { workflowInputName :: !Text,
    workflowInputSource :: !WorkflowInputSource
  }
  deriving (Eq, Show)

-- | Operational capabilities published with one workflow descriptor.
data DescriptorCapabilities = DescriptorCapabilities
  { descriptorStructuredRun :: !Bool,
    descriptorWholeRunCancel :: !Bool,
    descriptorControlFd :: !(Maybe Integer),
    descriptorRequestControls :: !Bool,
    descriptorSteering :: !Bool,
    descriptorInteractiveRetry :: !Bool,
    descriptorSchedulerRedirect :: !Bool,
    descriptorSemanticResume :: !Bool,
    descriptorImmutableFork :: !Bool,
    descriptorRestartFromScratch :: !Bool,
    descriptorProtocolNegotiation :: !Bool,
    descriptorRoutingInspection :: !Bool,
    descriptorRoutingJsonVersion :: !(Maybe Integer),
    descriptorPersonaRouting :: !Bool,
    descriptorModelAliasRouting :: !Bool,
    descriptorConsults :: !Integer,
    descriptorObserves :: !Integer,
    descriptorEffects :: !Integer,
    descriptorEffectful :: !Bool,
    descriptorToolExecution :: !Bool
  }
  deriving (Eq, Show)

-- | One machine-readable workflow catalogue row.
data WorkflowDescriptor = WorkflowDescriptor
  { workflowDescriptorVersion :: !Int,
    workflowRunnerVersion :: !Text,
    workflowProtocolVersions :: ![Int],
    workflowStoreVersions :: ![Int],
    workflowCapabilities :: !DescriptorCapabilities,
    workflowName :: !Text,
    workflowBlurb :: !Text,
    workflowResultCode :: !Value,
    workflowLevel :: !Text,
    workflowSize :: !Integer,
    workflowAskNodes :: !Integer,
    workflowMinFold :: !(Maybe Integer),
    workflowMaxFold :: !(Maybe Integer),
    workflowPaths :: !Integer,
    workflowInputs :: ![WorkflowInputDescriptor],
    workflowRunFacts :: ![Text],
    workflowPins :: ![Text],
    workflowPersonAnsweringModes :: ![Text]
  }
  deriving (Eq, Show)

-- | The descriptor emitted by established unqualified @list --json@ calls.
descriptorVersion :: Int
descriptorVersion = 2

-- | The newest descriptor a frontend may request explicitly.
latestDescriptorVersion :: Int
latestDescriptorVersion = 3

workflowDescriptorFields :: WorkflowDescriptor -> [Pair]
workflowDescriptorFields descriptor =
  [ "descriptorVersion" .= workflowDescriptorVersion descriptor,
    "runnerVersion" .= workflowRunnerVersion descriptor,
    "protocolVersions" .= workflowProtocolVersions descriptor,
    "storeVersions" .= workflowStoreVersions descriptor,
    "capabilities" .= workflowCapabilities descriptor,
    "name" .= workflowName descriptor,
    "blurb" .= workflowBlurb descriptor,
    "result" .= workflowResultCode descriptor,
    "level" .= workflowLevel descriptor,
    "size" .= workflowSize descriptor,
    "askNodes" .= workflowAskNodes descriptor,
    "minFold" .= workflowMinFold descriptor,
    "maxFold" .= workflowMaxFold descriptor,
    "paths" .= workflowPaths descriptor,
    "inputs" .= workflowInputs descriptor,
    "runFacts" .= workflowRunFacts descriptor,
    "pins" .= workflowPins descriptor
  ]
    <> if workflowDescriptorVersion descriptor >= 3
      then ["personAnsweringModes" .= workflowPersonAnsweringModes descriptor]
      else []

encodeWorkflowDescriptor :: WorkflowDescriptor -> BS.ByteString
encodeWorkflowDescriptor = BL.toStrict . encode

decodeWorkflowDescriptor :: BS.ByteString -> Either Text WorkflowDescriptor
decodeWorkflowDescriptor = either (Left . T.pack) Right . eitherDecodeStrict'

decodeWorkflowDescriptors :: BS.ByteString -> Either Text [WorkflowDescriptor]
decodeWorkflowDescriptors = either (Left . T.pack) Right . eitherDecodeStrict'

instance ToJSON WorkflowInputSource where
  toJSON = toJSON . inputSourceText

instance FromJSON WorkflowInputSource where
  parseJSON = withText "workflow input source" $ \case
    "prompt" -> pure DescriptorPrompt
    "command-tail" -> pure DescriptorCommandTail
    "stdin" -> pure DescriptorStdin
    source -> fail ("unknown workflow input source " <> T.unpack source)

instance ToJSON WorkflowInputDescriptor where
  toJSON descriptor =
    object
      [ "name" .= workflowInputName descriptor,
        "source" .= workflowInputSource descriptor
      ]

instance FromJSON WorkflowInputDescriptor where
  parseJSON = withObject "workflow input descriptor" $ \o -> do
    onlyKeys "workflow input descriptor" ["name", "source"] o
    name <- o .: "name" >>= validName "workflow input"
    WorkflowInputDescriptor name <$> o .: "source"

instance ToJSON DescriptorCapabilities where
  toJSON capabilities =
    object
      ( [ "structuredRun" .= descriptorStructuredRun capabilities,
          "wholeRunCancel" .= descriptorWholeRunCancel capabilities,
          "requestControls" .= descriptorRequestControls capabilities,
          "steering" .= descriptorSteering capabilities,
          "interactiveRetry" .= descriptorInteractiveRetry capabilities,
          "schedulerRedirect" .= descriptorSchedulerRedirect capabilities,
          "semanticResume" .= descriptorSemanticResume capabilities,
          "immutableFork" .= descriptorImmutableFork capabilities,
          "restartFromScratch" .= descriptorRestartFromScratch capabilities,
          "consults" .= descriptorConsults capabilities,
          "observes" .= descriptorObserves capabilities,
          "effects" .= descriptorEffects capabilities,
          "effectful" .= descriptorEffectful capabilities,
          "toolExecution" .= descriptorToolExecution capabilities
        ]
          <> maybe [] (\descriptor -> ["controlFd" .= descriptor]) (descriptorControlFd capabilities)
          <> ["protocolNegotiation" .= True | descriptorProtocolNegotiation capabilities]
          <> ["routingInspection" .= True | descriptorRoutingInspection capabilities]
          <> maybe [] (\version -> ["routingJsonVersion" .= version]) (descriptorRoutingJsonVersion capabilities)
          <> ["personaRouting" .= True | descriptorPersonaRouting capabilities]
          <> ["modelAliasRouting" .= True | descriptorModelAliasRouting capabilities]
      )

instance FromJSON DescriptorCapabilities where
  parseJSON = withObject "workflow descriptor capabilities" $ \o -> do
    onlyKeys "workflow descriptor capabilities" capabilityKeys o
    capabilities <-
      DescriptorCapabilities
        <$> (o .:? "structuredRun" .!= False)
        <*> (o .:? "wholeRunCancel" .!= False)
        <*> (traverse (natural "controlFd") =<< o .:? "controlFd")
        <*> (o .:? "requestControls" .!= False)
        <*> (o .:? "steering" .!= False)
        <*> (o .:? "interactiveRetry" .!= False)
        <*> (o .:? "schedulerRedirect" .!= False)
        <*> (o .:? "semanticResume" .!= False)
        <*> (o .:? "immutableFork" .!= False)
        <*> (o .:? "restartFromScratch" .!= False)
        <*> (o .:? "protocolNegotiation" .!= False)
        <*> (o .:? "routingInspection" .!= False)
        <*> (traverse (natural "routingJsonVersion") =<< o .:? "routingJsonVersion")
        <*> (o .:? "personaRouting" .!= False)
        <*> (o .:? "modelAliasRouting" .!= False)
        <*> (o .:? "consults" .!= 0 >>= natural "consults")
        <*> (o .:? "observes" .!= 0 >>= natural "observes")
        <*> (o .:? "effects" .!= 0 >>= natural "effects")
        <*> (o .:? "effectful" .!= False)
        <*> (o .:? "toolExecution" .!= False)
    when (maybe False (< 3) (descriptorControlFd capabilities)) (fail "workflow descriptor controlFd is less than 3")
    when
      (descriptorEffectful capabilities /= (descriptorEffects capabilities > 0))
      (fail "workflow descriptor effectful disagrees with effects")
    pure capabilities

instance ToJSON WorkflowDescriptor where
  toJSON = object . workflowDescriptorFields

instance FromJSON WorkflowDescriptor where
  parseJSON = withObject "workflow descriptor" $ \o -> do
    version <- o .: "descriptorVersion"
    unless (version == descriptorVersion || version == latestDescriptorVersion) $
      fail ("unsupported workflow descriptor version " <> show (version :: Int))
    onlyKeys "workflow descriptor" (descriptorKeys version) o
    descriptor <-
      WorkflowDescriptor version
        <$> o .: "runnerVersion"
        <*> o .: "protocolVersions"
        <*> o .: "storeVersions"
        <*> o .: "capabilities"
        <*> (o .: "name" >>= validName "workflow")
        <*> o .: "blurb"
        <*> o .: "result"
        <*> o .: "level"
        <*> (o .: "size" >>= natural "size")
        <*> (o .: "askNodes" >>= natural "askNodes")
        <*> (o .: "minFold" >>= traverse (natural "minFold"))
        <*> (o .: "maxFold" >>= traverse (natural "maxFold"))
        <*> (o .: "paths" >>= natural "paths")
        <*> o .: "inputs"
        <*> o .: "runFacts"
        <*> o .: "pins"
        <*> if version >= 3 then o .: "personAnsweringModes" else pure []
    validateDescriptor descriptor

inputSourceText :: WorkflowInputSource -> Text
inputSourceText DescriptorPrompt = "prompt"
inputSourceText DescriptorCommandTail = "command-tail"
inputSourceText DescriptorStdin = "stdin"

capabilityKeys :: [Text]
capabilityKeys =
  [ "structuredRun",
    "wholeRunCancel",
    "controlFd",
    "requestControls",
    "steering",
    "interactiveRetry",
    "schedulerRedirect",
    "semanticResume",
    "immutableFork",
    "restartFromScratch",
    "protocolNegotiation",
    "routingInspection",
    "routingJsonVersion",
    "personaRouting",
    "modelAliasRouting",
    "consults",
    "observes",
    "effects",
    "effectful",
    "toolExecution"
  ]

descriptorKeys :: Int -> [Text]
descriptorKeys version =
  [ "descriptorVersion",
    "runnerVersion",
    "protocolVersions",
    "storeVersions",
    "capabilities",
    "name",
    "blurb",
    "result",
    "level",
    "size",
    "askNodes",
    "minFold",
    "maxFold",
    "paths",
    "inputs",
    "runFacts",
    "pins"
  ]
    <> ["personAnsweringModes" | version >= 3]

validateDescriptor :: WorkflowDescriptor -> Parser WorkflowDescriptor
validateDescriptor descriptor = do
  nonEmptyDistinct "protocolVersions" (workflowProtocolVersions descriptor)
  nonEmptyDistinct "storeVersions" (workflowStoreVersions descriptor)
  unless (1 `elem` workflowProtocolVersions descriptor) (fail "workflow descriptor does not support protocol 1")
  unless (1 `elem` workflowStoreVersions descriptor) (fail "workflow descriptor does not support store 1")
  when (workflowDescriptorVersion descriptor == 2 && not (null (workflowPersonAnsweringModes descriptor)) ) $
    fail "descriptor version 2 cannot advertise person answering"
  when (workflowDescriptorVersion descriptor >= 3) $ do
    unless (2 `elem` workflowProtocolVersions descriptor) (fail "descriptor version 3 does not support protocol 2")
    unless (2 `elem` workflowStoreVersions descriptor) (fail "descriptor version 3 does not support store 2")
    unless (workflowPersonAnsweringModes descriptor == ["local-control"]) $
      fail "descriptor version 3 has unsupported person answering modes"
  let names = map workflowInputName (workflowInputs descriptor)
  when (length names /= length (nub names)) (fail "workflow descriptor has duplicate input names")
  atMostOne DescriptorCommandTail descriptor
  atMostOne DescriptorStdin descriptor
  case (workflowMinFold descriptor, workflowMaxFold descriptor) of
    (Just lo, Just hi) | lo > hi -> fail "workflow descriptor minFold exceeds maxFold"
    _ -> pure ()
  pure descriptor

atMostOne :: WorkflowInputSource -> WorkflowDescriptor -> Parser ()
atMostOne source descriptor =
  when (length (filter ((== source) . workflowInputSource) (workflowInputs descriptor)) > 1) $
    fail ("workflow descriptor has multiple " <> T.unpack (inputSourceText source) <> " inputs")

nonEmptyDistinct :: (Eq a) => String -> [a] -> Parser ()
nonEmptyDistinct label values = do
  when (null values) (fail ("workflow descriptor " <> label <> " is empty"))
  when (length values /= length (nub values)) (fail ("workflow descriptor " <> label <> " has duplicates"))

natural :: String -> Integer -> Parser Integer
natural label value
  | value < 0 = fail ("workflow descriptor " <> label <> " is negative")
  | otherwise = pure value

validName :: String -> Text -> Parser Text
validName label value
  | T.null value || T.any (`elem` ['\NUL', '\n', '\r']) value = fail ("invalid " <> label <> " name")
  | otherwise = pure value

onlyKeys :: String -> [Text] -> Object -> Parser ()
onlyKeys label allowed object' =
  case filter (`notElem` allowed) (map toText (keys object')) of
    [] -> pure ()
    unknown -> fail (label <> " has unknown field(s): " <> T.unpack (T.intercalate ", " unknown))
