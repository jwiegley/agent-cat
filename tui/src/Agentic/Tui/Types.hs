{-# LANGUAGE OverloadedStrings #-}

-- | Frontend-local launch and routing values.
module Agentic.Tui.Types
  ( TuiConfig (..),
    EngineChoice (..),
    RoutingProfileChoice (..),
    RoutingRungChoice (..),
    RoutingInventoryChoice (..),
    RoutingSummary (..),
    TargetSelection (..),
    LaunchPreview (..),
    decodeRoutingSummary,
    targetArguments,
  )
where

import Agentic.Runtime (LineageOperation, RunRecord, WorkflowDescriptor)
import Control.Monad (unless)
import Data.Aeson (FromJSON (parseJSON), Value (..), eitherDecodeStrict', withObject, (.:), (.:?))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import Data.Aeson.Types (Parser)
import qualified Data.ByteString as BS
import Data.Char (isAlphaNum)
import Data.List (nub)
import Data.Map.Strict (Map)
import qualified Data.Set as Set
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T

-- | Everything needed to run a TUI against one executable registry.
data TuiConfig = TuiConfig
  { tuiRunnerId :: !Text,
    tuiRunner :: !FilePath,
    tuiRunnerArgs :: ![String],
    tuiWorkingDir :: !FilePath,
    tuiStateDir :: !FilePath
  }
  deriving (Eq, Show)

-- | One sanitized physical engine offered by routing inspection.
data EngineChoice = EngineChoice
  { engineChoiceAlias :: !Text,
    engineChoiceBackend :: !Text,
    engineChoiceProvider :: !Text
  }
  deriving (Eq, Show)

-- | Sanitized model-inventory provenance shown by the frontend.
data RoutingInventoryChoice = RoutingInventoryChoice
  { routingInventorySource :: !Text,
    routingInventoryFingerprint :: !(Maybe Text),
    routingInventoryFetchedAt :: !(Maybe Text)
  }
  deriving (Eq, Show)

-- | One concrete rung of a symbolic profile.
data RoutingRungChoice = RoutingRungChoice
  { routingRungAxis :: !Text,
    routingRungNumber :: !Int,
    routingRungModelAlias :: !(Maybe Text),
    routingRungModel :: !Text,
    routingRungRouter :: !Text,
    routingRungBackend :: !Text,
    routingRungProvider :: !Text,
    routingRungThinking :: !Text,
    routingRungInventory :: !RoutingInventoryChoice
  }
  deriving (Eq, Show)

-- | One symbolic profile and its ordered concrete realizations.
data RoutingProfileChoice = RoutingProfileChoice
  { routingProfileName :: !Text,
    routingProfileRungs :: ![RoutingRungChoice]
   }
  deriving (Eq, Show)

-- | Sanitized routing facts needed by the browser and launch confirmation.
data RoutingSummary = RoutingSummary
  { routingSummaryVersion :: !Int,
    routingSummaryPersona :: !(Maybe Text),
    routingSummaryPersonaSource :: !(Maybe Text),
    routingSummaryPersonas :: ![Text],
    routingSummaryArguments :: ![Text],
    routingSummaryFingerprint :: !Text,
    routingSummaryEngines :: ![EngineChoice],
    routingSummaryProfiles :: ![RoutingProfileChoice],
    routingSummaryWarnings :: ![Text],
    routingSummaryRaw :: !Value
  }
  deriving (Eq, Show)

-- | Execution target selected explicitly before preview.
data TargetSelection
  = TargetScripted
  | TargetRouting !Text ![Text] !Text
  | TargetRestored !Text ![Text]
  deriving (Eq, Show)

-- | Exact-input preview retained for the confirmation screen.
data LaunchPreview = LaunchPreview
  { previewDescriptor :: !WorkflowDescriptor,
    previewInputs :: !(Map Text Text),
    previewTarget :: !TargetSelection,
    previewLineage :: !(Maybe (LineageOperation, RunRecord)),
    previewRouting :: !(Maybe RoutingSummary),
    previewPlan :: !Value,
    previewProgramHash :: !Text
  }
  deriving (Eq, Show)

decodeRoutingSummary :: BS.ByteString -> Either Text RoutingSummary
decodeRoutingSummary bytes = case eitherDecodeStrict' bytes of
  Left why -> Left (T.pack why)
  Right value -> Right value

instance FromJSON RoutingSummary where
  parseJSON value = withObject "routing inspection" (parseSummary value) value
    where
      parseSummary raw object = do
        rejectSensitiveRouting raw
        version <- object .: "version"
        unless (version == 2) (fail "routing inspection version is not 2")
        persona <- object .:? "persona" >>= traverse parsePersona
        (arguments, fingerprint) <- object .: "launch" >>= parseRoutingLaunch
        engines <- fromMaybe [] <$> object .:? "engines"
        profiles <- fromMaybe [] <$> object .:? "profiles"
        warnings <- fromMaybe [] <$> object .:? "warnings"
        available <- fromMaybe [] <$> object .:? "availablePersonas"
        unless (length engines <= 128 && length profiles <= 256 && sum (map (length . routingProfileRungs) profiles) <= 2048) (fail "routing inspection exceeds engine/profile bounds")
        unless (length available <= 128 && length available == length (nub available) && all ((<= 256) . T.length) available) (fail "routing persona choices are invalid or oversized")
        unless (length warnings <= 128 && all ((<= 4096) . T.length) warnings) (fail "routing warnings are oversized")
        case persona of
          Just (selected, _) -> unless (selected `elem` available) (fail "selected routing persona is absent from availablePersonas")
          Nothing -> pure ()
        pure
          RoutingSummary
            { routingSummaryVersion = version,
              routingSummaryPersona = fst <$> persona,
              routingSummaryPersonaSource = snd <$> persona,
              routingSummaryPersonas = available,
              routingSummaryArguments = arguments,
              routingSummaryFingerprint = fingerprint,
              routingSummaryEngines = engines,
              routingSummaryProfiles = profiles,
              routingSummaryWarnings = warnings,
              routingSummaryRaw = raw
            }
      parsePersona = withObject "routing persona" $ \persona ->
        (,) <$> persona .: "name" <*> persona .: "source"
      parseRoutingLaunch = withObject "routing-only launch" $ \launch -> do
        targetKind <- launch .: "targetKind"
        arguments <- launch .: "arguments"
        fingerprint <- launch .: "fingerprint"
        unless (targetKind == ("routing" :: Text)) (fail "routing-only launch target kind is invalid")
        unless (not (null arguments) && length arguments <= 16 && all validLaunchArgument arguments) (fail "routing-only launch arguments are invalid")
        unless (validLaunchFingerprint fingerprint) (fail "routing-only launch fingerprint is invalid")
        pure (arguments, fingerprint)

instance FromJSON RoutingInventoryChoice where
  parseJSON = withObject "routing inventory" $ \inventory ->
    RoutingInventoryChoice <$> inventory .: "source" <*> inventory .:? "fingerprint" <*> inventory .:? "fetchedAt"

instance FromJSON RoutingRungChoice where
  parseJSON = withObject "routing rung" $ \rung ->
    RoutingRungChoice
      <$> rung .: "axis"
      <*> rung .: "rung"
      <*> rung .:? "modelAlias"
      <*> rung .: "model"
      <*> rung .: "router"
      <*> rung .: "backend"
      <*> rung .: "provider"
      <*> rung .: "thinking"
      <*> rung .: "inventory"

instance FromJSON RoutingProfileChoice where
  parseJSON = withObject "routing profile" $ \profile ->
    RoutingProfileChoice <$> profile .: "name" <*> profile .: "rungs"

rejectSensitiveRouting :: Value -> Parser ()
rejectSensitiveRouting = go
  where
    forbidden =
      Set.fromList
        [ "secret", "secrets", "secretref", "secretreference", "secretvalue",
          "environment", "environments", "environmentname", "environmentvalue",
          "header", "headers", "auth", "authorization", "credential", "credentials", "credentialvalue",
          "token", "accesstoken", "authtoken", "bearertoken", "refreshtoken", "sessiontoken",
          "apikey", "password", "passwordvalue", "cookie", "cookievalue",
          "url", "endpoint", "endpointurl", "baseurl", "catalogurl", "catalogueurl"
        ]
    go (Object object) = mapM_ inspect (KeyMap.toList object)
    go (Array values) = mapM_ go values
    go _ = pure ()
    inspect (key, value) = do
      let normalized = T.filter isAlphaNum (T.toLower (Key.toText key))
      unless (normalized `Set.notMember` forbidden) (fail ("routing inspection contains forbidden field " <> T.unpack (Key.toText key)))
      go value

instance FromJSON EngineChoice where
  parseJSON = withObject "routing engine" $ \engine -> do
    name <- engine .: "name"
    backend <- engine .: "backend"
    provider <- engine .: "provider"
    unless (not (T.null name) && not (T.null backend)) (fail "routing engine name or backend is empty")
    pure (EngineChoice name backend provider)

validLaunchArgument :: Text -> Bool
validLaunchArgument value = not (T.null value) && T.length value <= 4096 && not (T.any (`elem` ['\NUL', '\n', '\r']) value)

validLaunchFingerprint :: Text -> Bool
validLaunchFingerprint value = T.length value == 64 && T.all (`elem` ("0123456789abcdef" :: String)) value

targetArguments :: TargetSelection -> Either Text [String]
targetArguments TargetScripted = Right ["--scripted"]
targetArguments (TargetRestored _ arguments) = Right (map T.unpack arguments)
targetArguments (TargetRouting persona arguments fingerprint) =
  Right
    ( map T.unpack arguments
        <> [ "--persona",
             T.unpack persona,
             "--offline",
             "--expect-routing-fingerprint",
             T.unpack fingerprint
           ]
    )
