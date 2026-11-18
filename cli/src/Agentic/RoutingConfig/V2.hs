{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

-- | Strict persona-aware routing documents. Execution still lowers through the
-- existing 'Agentic.RoutingConfig' resolver; this module owns only v2 policy.
module Agentic.RoutingConfig.V2
  ( SecretReference (..),
    EnvironmentBinding (..),
    CatalogueDialect (..),
    CatalogueAuthScheme (..),
    CatalogueAuth (..),
    CachePolicy (..),
    Catalogue (..),
    Endpoint (..),
    EngineDefinition (..),
    ModelOrder (..),
    ModelSelector (..),
    ConcreteModel (..),
    RealizationV2 (..),
    ProfileV2 (..),
    Persona (..),
    RoutingConfigV2 (..),
    ProjectRoutingV2 (..),
    PersonaSelectionSource (..),
    SelectedRoutingV2 (..),
    routingDocumentVersion,
    decodeRoutingUserV2,
    decodeRoutingProjectV2,
    selectRoutingPersona,
    sensitiveName,
    scalarV2Option,
    validateDecisionsRealization,
    decisionsDialectOf,
    maxCatalogueBytes,
    maxCatalogueUrlBytes,
    maxCatalogueQueryBytes,
    maxCatalogueQueryItems,
    maxCatalogueTimeoutMs,
    maxCatalogueHeaders,
    maxCatalogueHeaderValueBytes,
    maxCatalogueHeaderBytes,
    maxCataloguePages,
    maxCatalogueModels,
    maxModelIdBytes,
    maxEndpointTimeoutMs,
    maxEndpointBytes,
  )
where

import Agentic.Decisions (Dialect, Limits (..), defaultLimits, reservedBodyKeys)
import Agentic.Engine (Thinking (ThinkOff))
import Agentic.Route (Backend (..), parseConfiguredBackend)
import Control.Monad (forM_, unless, when)
import Data.Aeson
  ( FromJSON (parseJSON),
    Object,
    Value (..),
    withObject,
    (.:),
    (.:?),
  )
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import Data.Aeson.Types (Parser, formatError, parseEither)
import qualified Data.ByteString as BS
import Data.Char (GeneralCategory (Format), generalCategory, isAlpha, isAlphaNum, isAscii, isControl, isHexDigit, isSpace)
import Data.List (nub)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isJust, isNothing)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeUtf8', encodeUtf8)
import Network.HTTP.Types.URI (parseQuery)
import qualified Data.Text.Read as TextRead
import qualified Data.Yaml.Internal as YamlInternal
import System.IO.Unsafe (unsafePerformIO)
import qualified Text.Libyaml as LibYaml

newtype SecretReference = SecretEnvironment
  { secretEnvironmentName :: Text
  }
  deriving (Eq, Show)

data EnvironmentBinding
  = EnvironmentSecret !Text
  | EnvironmentValue !Text
  deriving (Eq, Show)

data CatalogueDialect = CatalogueOpenAI | CatalogueAnthropic
  deriving (Eq, Ord, Show)

data CatalogueAuthScheme = CatalogueAuthRaw | CatalogueAuthBearer
  deriving (Eq, Ord, Show)

data CatalogueAuth = CatalogueAuth
  { catalogueAuthHeader :: !Text,
    catalogueAuthScheme :: !CatalogueAuthScheme,
    catalogueAuthSecret :: !Text
  }
  deriving (Eq, Show)

data CachePolicy = CachePolicy
  { cacheFreshSeconds :: !Integer,
    cacheStaleIfErrorSeconds :: !Integer
  }
  deriving (Eq, Show)

data Catalogue = Catalogue
  { catalogueDialect :: !CatalogueDialect,
    catalogueUrl :: !Text,
    catalogueAuth :: !(Maybe CatalogueAuth),
    catalogueHeaders :: !(Map Text Text),
    catalogueTimeoutMs :: !Int,
    catalogueMaxBytes :: !Int,
    catalogueCache :: !CachePolicy
  }
  deriving (Eq, Show)

-- | The HTTP endpoint of a decisions engine. Denotes the place where its
-- decision questions are put: the URL that receives each request, the
-- authentication and literal headers sent with it, the bounds on how long a
-- request may take and how large its response may be, and the option counts
-- that the endpoint accepts.
data Endpoint = Endpoint
  { endpointUrl :: !Text,
    endpointAuth :: !(Maybe CatalogueAuth),
    endpointHeaders :: !(Map Text Text),
    endpointTimeoutMs :: !Int,
    endpointMaxBytes :: !Int,
    endpointLimits :: !Limits
  }
  deriving (Eq, Show)

data EngineDefinition = EngineDefinition
  { engineBackend :: !Backend,
    engineProvider :: !Text,
    engineEnvironment :: !(Map Text EnvironmentBinding),
    engineCatalogue :: !(Maybe Catalogue),
    -- | Present exactly when the backend is a decisions backend.
    engineEndpoint :: !(Maybe Endpoint)
  }
  deriving (Eq, Show)

data ModelOrder = ModelNewest | ModelIdDescending
  deriving (Eq, Ord, Show)

data ModelSelector
  = ModelExact !Text
  | ModelPrefix !Text !(Maybe ModelOrder)
  deriving (Eq, Show)

data ConcreteModel = ConcreteModel
  { concreteModelEngine :: !Text,
    concreteModelSelectors :: ![ModelSelector]
  }
  deriving (Eq, Show)

-- | One rung of a profile chain. The thinking level and the output limit
-- are 'Nothing' when the document does not write them, which only a
-- realization of a decisions model may do. An output limit of
-- @'Just' 'Nothing'@ is the written word @unconstrained@.
data RealizationV2 = RealizationV2
  { realizationV2Model :: !Text,
    realizationV2Thinking :: !(Maybe Thinking),
    realizationV2MaxOutput :: !(Maybe (Maybe Integer)),
    realizationV2Options :: !(Map Text Value)
  }
  deriving (Eq, Show)

newtype ProfileV2 = ProfileV2
  { profileV2Chain :: [RealizationV2]
  }
  deriving (Eq, Show)

data Persona = Persona
  { personaEngines :: ![Text],
    personaModels :: ![Text],
    personaProfiles :: !(Map Text ProfileV2)
  }
  deriving (Eq, Show)

data RoutingConfigV2 = RoutingConfigV2
  { routingV2DefaultPersona :: !Text,
    routingV2Secrets :: !(Map Text SecretReference),
    routingV2Engines :: !(Map Text EngineDefinition),
    routingV2Models :: !(Map Text ConcreteModel),
    routingV2Personas :: !(Map Text Persona)
  }
  deriving (Eq, Show)

data ProjectRoutingV2 = ProjectRoutingV2
  { projectRoutingPersona :: !Text,
    projectRoutingProfiles :: !(Map Text ProfileV2)
  }
  deriving (Eq, Show)

data PersonaSelectionSource
  = PersonaFromCommandLine
  | PersonaFromEnvironment
  | PersonaFromProject
  | PersonaFromUserDefault
  deriving (Eq, Ord, Show)

data SelectedRoutingV2 = SelectedRoutingV2
  { selectedRoutingV2 :: !RoutingConfigV2,
    selectedPersonaName :: !Text,
    selectedPersonaSource :: !PersonaSelectionSource,
    selectedPersona :: !Persona
  }
  deriving (Eq, Show)

maxCatalogueBytes, maxCatalogueUrlBytes, maxCatalogueQueryBytes, maxCatalogueQueryItems, maxCatalogueTimeoutMs, maxCatalogueHeaders, maxCatalogueHeaderValueBytes, maxCatalogueHeaderBytes, maxCataloguePages, maxCatalogueModels, maxModelIdBytes :: Int
maxCatalogueBytes = 4 * 1024 * 1024
maxCatalogueUrlBytes = 8192
maxCatalogueQueryBytes = 4096
maxCatalogueQueryItems = 64
maxCatalogueTimeoutMs = 60000
maxCatalogueHeaders = 64
maxCatalogueHeaderValueBytes = 8192
maxCatalogueHeaderBytes = 61440
maxCataloguePages = 100
maxCatalogueModels = 10000
maxModelIdBytes = 512

-- | The bounds on a decisions endpoint's @timeout-ms@ and @max-bytes@.
maxEndpointTimeoutMs, maxEndpointBytes :: Int
maxEndpointTimeoutMs = 600000
maxEndpointBytes = 4 * 1024 * 1024

instance FromJSON SecretReference where
  parseJSON = withObject "secret" $ \o -> do
    onlyKeys "secret" ["env"] o
    source <- nonBlank "secret environment variable" =<< o .: "env"
    unless (environmentName source) (fail "secret environment variable is invalid")
    pure (SecretEnvironment source)

instance FromJSON EnvironmentBinding where
  parseJSON = withObject "environment binding" $ \o -> do
    onlyKeys "environment binding" ["secret", "value"] o
    secret <- o .:? "secret"
    value <- o .:? "value"
    case (secret, value) of
      (Just name, Nothing) -> EnvironmentSecret <$> nonBlank "environment secret" name
      (Nothing, Just literal) -> EnvironmentValue <$> nonBlank "environment literal" literal
      _ -> fail "environment binding requires exactly one of secret or value"

instance FromJSON CatalogueDialect where
  parseJSON value = do
    name <- parseJSON value
    case (name :: Text) of
      "openai" -> pure CatalogueOpenAI
      "anthropic" -> pure CatalogueAnthropic
      other -> fail ("unknown catalogue dialect '" <> T.unpack other <> "'")

instance FromJSON CatalogueAuthScheme where
  parseJSON value = do
    name <- parseJSON value
    case (name :: Text) of
      "bearer" -> pure CatalogueAuthBearer
      other -> fail ("unknown catalogue auth scheme '" <> T.unpack other <> "'")

instance FromJSON CatalogueAuth where
  parseJSON = withObject "catalogue auth" $ \o -> do
    onlyKeys "catalogue auth" ["header", "scheme", "secret"] o
    header <- nonBlank "catalogue auth header" =<< o .: "header"
    scheme <- fromMaybe CatalogueAuthRaw <$> o .:? "scheme"
    secret <- nonBlank "catalogue auth secret" =<< o .: "secret"
    pure (CatalogueAuth header scheme secret)

instance FromJSON CachePolicy where
  parseJSON = withObject "catalogue cache" $ \o -> do
    onlyKeys "catalogue cache" ["fresh-for", "stale-if-error"] o
    fresh <- parseDuration =<< o .: "fresh-for"
    stale <- parseDuration =<< o .: "stale-if-error"
    when (stale < fresh) (fail "stale-if-error is shorter than fresh-for")
    pure (CachePolicy fresh stale)

instance FromJSON Catalogue where
  parseJSON = withObject "catalogue" $ \o -> do
    onlyKeys "catalogue" ["dialect", "url", "auth", "headers", "timeout-ms", "max-bytes", "cache"] o
    dialect <- o .: "dialect"
    url <- nonBlank "catalogue URL" =<< o .: "url"
    auth <- o .:? "auth"
    headers <- fromMaybe Map.empty <$> o .:? "headers"
    timeoutMs <- o .: "timeout-ms"
    maximumBytes <- o .: "max-bytes"
    cache <- o .: "cache"
    either (fail . T.unpack) pure (validateCatalogue (Catalogue dialect url auth headers timeoutMs maximumBytes cache))

instance FromJSON Endpoint where
  parseJSON = withObject "endpoint" $ \o -> do
    onlyKeys "endpoint" ["url", "auth", "headers", "timeout-ms", "max-bytes", "limits"] o
    url <- nonBlank "endpoint URL" =<< o .: "url"
    auth <- o .:? "auth"
    headers <- fromMaybe Map.empty <$> o .:? "headers"
    timeoutMs <- o .: "timeout-ms"
    maximumBytes <- o .: "max-bytes"
    limits <- maybe (pure defaultLimits) parseLimits =<< o .:? "limits"
    either (fail . T.unpack) pure (validateEndpoint (Endpoint url auth headers timeoutMs maximumBytes limits))
    where
      parseLimits = withObject "endpoint limits" $ \l -> do
        onlyKeys "endpoint limits" ["options", "levels"] l
        options <- fromMaybe (limitOptions defaultLimits) <$> l .:? "options"
        levels <- fromMaybe (limitLevels defaultLimits) <$> l .:? "levels"
        when (options < 2 || levels < 2) (fail "endpoint limits allow fewer than 2 options or levels")
        pure (Limits options levels)

instance FromJSON EngineDefinition where
  parseJSON = withObject "engine" $ \o -> do
    onlyKeys "engine" ["backend", "provider", "environment", "catalogue", "endpoint"] o
    backendText <- nonBlank "engine backend" =<< o .: "backend"
    backend <- either (fail . T.unpack) pure (parseConfiguredBackend backendText)
    provider <- nonBlank "engine provider" =<< o .: "provider"
    environment <- fromMaybe Map.empty <$> o .:? "environment"
    catalogue <- o .:? "catalogue"
    endpoint <- o .:? "endpoint"
    pure (EngineDefinition backend provider environment catalogue endpoint)

instance FromJSON ModelOrder where
  parseJSON value = do
    name <- parseJSON value
    case (name :: Text) of
      "newest" -> pure ModelNewest
      "id-descending" -> pure ModelIdDescending
      other -> fail ("unknown model selector order '" <> T.unpack other <> "'")

instance FromJSON ModelSelector where
  parseJSON = withObject "model selector" $ \o -> do
    onlyKeys "model selector" ["exact", "prefix", "order"] o
    exact <- o .:? "exact"
    prefix <- o .:? "prefix"
    order <- o .:? "order"
    case (exact, prefix, order) of
      (Just value, Nothing, Nothing) -> ModelExact <$> modelId "exact model id" value
      (Nothing, Just value, ordering) -> ModelPrefix <$> modelId "model prefix" value <*> pure ordering
      _ -> fail "model selector is exact or prefix; only prefix may carry order"

instance FromJSON ConcreteModel where
  parseJSON = withObject "concrete model" $ \o -> do
    onlyKeys "concrete model" ["engine", "select"] o
    engine <- nonBlank "concrete model engine" =<< o .: "engine"
    selectors <- o .: "select"
    when (null selectors) (fail "concrete model has an empty select list")
    pure (ConcreteModel engine selectors)

instance FromJSON RealizationV2 where
  parseJSON = withObject "profile realization" $ \o -> do
    onlyKeys "profile realization" ["model", "thinking", "max-output", "options"] o
    model <- nonBlank "profile realization model" =<< o .: "model"
    thinking <- o .:? "thinking"
    maximumValue <- o .:? "max-output"
    maximumOutput <- traverse limitOf maximumValue
    when (maybe False (<= 0) (maximumOutput >>= id)) (fail "max-output must be positive or 'unconstrained'")
    options <- fromMaybe Map.empty <$> o .:? "options"
    forM_ (Map.toList options) $ \(name, value) -> do
      when (sensitiveName name) (fail ("profile option '" <> T.unpack name <> "' may carry a secret"))
      unless (scalarV2Option value) (fail ("profile option '" <> T.unpack name <> "' must be scalar"))
    pure (RealizationV2 model thinking maximumOutput options)
    where
      limitOf (String "unconstrained") = pure Nothing
      limitOf value = Just <$> parseJSON value

instance FromJSON ProfileV2 where
  parseJSON = withObject "profile" $ \o -> do
    onlyKeys "profile" ["chain"] o
    chain <- o .: "chain"
    when (null chain) (fail "profile has an empty chain")
    pure (ProfileV2 chain)

instance FromJSON Persona where
  parseJSON = withObject "persona" $ \o -> do
    onlyKeys "persona" ["engines", "models", "profiles"] o
    Persona <$> o .: "engines" <*> o .: "models" <*> o .: "profiles"

instance FromJSON RoutingConfigV2 where
  parseJSON = withObject "user routing" $ \o -> do
    onlyKeys "user routing" ["version", "default-persona", "secrets", "engines", "models", "personas"] o
    version <- o .: "version"
    unless (version == (2 :: Int)) (fail "user routing version is not 2")
    RoutingConfigV2
      <$> o .: "default-persona"
      <*> (fromMaybe Map.empty <$> o .:? "secrets")
      <*> o .: "engines"
      <*> o .: "models"
      <*> o .: "personas"

instance FromJSON ProjectRoutingV2 where
  parseJSON = withObject "project routing" $ \o -> do
    projectKeys o
    version <- o .: "version"
    unless (version == (2 :: Int)) (fail "project routing version is not 2")
    ProjectRoutingV2 <$> o .: "persona" <*> (fromMaybe Map.empty <$> o .:? "profiles")

routingDocumentVersion :: BS.ByteString -> Either Text Int
routingDocumentVersion bytes = do
  value <- (decodeYaml bytes :: Either Text Value)
  firstText T.pack (parseEither (withObject "routing document" (.: "version")) value)

decodeRoutingUserV2 :: BS.ByteString -> Either Text RoutingConfigV2
decodeRoutingUserV2 bytes = do
  version <- routingDocumentVersion bytes
  unless (version == 2) (Left ("user routing document has version " <> T.pack (show version) <> ", expected 2"))
  config <- decodeYaml bytes
  validateRoutingV2 config

decodeRoutingProjectV2 :: BS.ByteString -> Either Text ProjectRoutingV2
decodeRoutingProjectV2 bytes = do
  version <- routingDocumentVersion bytes
  unless (version == 2) (Left ("project routing document has version " <> T.pack (show version) <> ", expected 2"))
  decodeYaml bytes

selectRoutingPersona :: RoutingConfigV2 -> Maybe Text -> Maybe Text -> Maybe ProjectRoutingV2 -> Either Text SelectedRoutingV2
selectRoutingPersona config commandLine environment project = do
  -- The project layer is checked against the persona that it names whichever
  -- persona is selected, so a file that one selection accepts no other
  -- selection refuses.
  forM_ project $ \layer -> do
    let named = projectRoutingPersona layer
    persona <- maybe (Left ("project selects unknown persona '" <> named <> "'")) Right (Map.lookup named (routingV2Personas config))
    applyProjectProfiles config named persona (projectRoutingProfiles layer)
  let (name, source) = case commandLine of
        Just value -> (value, PersonaFromCommandLine)
        Nothing -> case environment of
          Just value -> (value, PersonaFromEnvironment)
          Nothing -> case project of
            Just layer -> (projectRoutingPersona layer, PersonaFromProject)
            Nothing -> (routingV2DefaultPersona config, PersonaFromUserDefault)
  base <- maybe (Left ("unknown routing persona '" <> name <> "'")) Right (Map.lookup name (routingV2Personas config))
  selected <- case project of
    Just layer | projectRoutingPersona layer == name -> applyProjectProfiles config name base (projectRoutingProfiles layer)
    _ -> pure base
  pure (SelectedRoutingV2 config name source selected)

validateRoutingV2 :: RoutingConfigV2 -> Either Text RoutingConfigV2
validateRoutingV2 config@RoutingConfigV2 {..} = do
  validateNamedMap "secret" routingV2Secrets
  validateNamedMap "engine" routingV2Engines
  validateNamedMap "concrete model" routingV2Models
  validateNamedMap "persona" routingV2Personas
  unless (routingV2DefaultPersona `Map.member` routingV2Personas) $
    Left ("default persona '" <> routingV2DefaultPersona <> "' is not declared")
  forM_ (Map.toList routingV2Engines) $ \(name, engine) -> validateEngine routingV2Secrets name engine
  forM_ (Map.toList routingV2Models) $ \(name, model) -> validateConcreteModel routingV2Engines name model
  forM_ (Map.toList routingV2Personas) $ \(name, persona) -> validatePersona config name persona
  pure config

validateEngine :: Map Text SecretReference -> Text -> EngineDefinition -> Either Text ()
validateEngine secrets name EngineDefinition {..} = do
  case engineBackend of
    BackendDeck _ -> unless (Map.null engineEnvironment) (Left ("deck engine '" <> name <> "' cannot declare child environment bindings"))
    _ -> pure ()
  case engineBackend of
    BackendDecisions _ -> do
      unless (Map.null engineEnvironment) (Left ("decisions engine '" <> name <> "' starts no process and cannot declare environment bindings"))
      when (isJust engineCatalogue) (Left ("decisions engine '" <> name <> "' cannot declare a catalogue: its models are selected by exact id"))
      case engineEndpoint of
        Nothing -> Left ("decisions engine '" <> name <> "' needs an endpoint")
        Just endpoint ->
          forM_ (endpointAuth endpoint) $ \auth ->
            unless (catalogueAuthSecret auth `Map.member` secrets) $
              Left ("engine '" <> name <> "' endpoint names unknown secret '" <> catalogueAuthSecret auth <> "'")
    _ -> when (isJust engineEndpoint) (Left ("engine '" <> name <> "' is not a decisions engine and cannot declare an endpoint"))
  forM_ (Map.toList engineEnvironment) $ \(variable, binding) -> do
    unless (environmentName variable) (Left ("engine '" <> name <> "' has invalid environment variable '" <> variable <> "'"))
    case binding of
      EnvironmentSecret secret ->
        unless (secret `Map.member` secrets) (Left ("engine '" <> name <> "' names unknown secret '" <> secret <> "'"))
      EnvironmentValue _ ->
        when (sensitiveName variable) (Left ("engine '" <> name <> "' environment variable '" <> variable <> "' must use a secret reference"))
  forM_ engineCatalogue $ \catalogue ->
    forM_ (catalogueAuth catalogue) $ \auth ->
      unless (catalogueAuthSecret auth `Map.member` secrets) $
        Left ("engine '" <> name <> "' catalogue names unknown secret '" <> catalogueAuthSecret auth <> "'")


validateConcreteModel :: Map Text EngineDefinition -> Text -> ConcreteModel -> Either Text ()
validateConcreteModel engines name model =
  case Map.lookup (concreteModelEngine model) engines of
    Nothing -> Left ("concrete model '" <> name <> "' names unknown engine '" <> concreteModelEngine model <> "'")
    Just engine -> case engineBackend engine of
      BackendDecisions _ ->
        forM_ (concreteModelSelectors model) $ \case
          ModelExact _ -> Right ()
          ModelPrefix _ _ ->
            Left
              ( "concrete model '"
                  <> name
                  <> "' of decisions engine '"
                  <> concreteModelEngine model
                  <> "' must select by exact id: a prefix selector needs a catalogue"
              )
      _ -> Right ()

-- | Check the generation settings of every realization in a persona's
-- profiles. A realization of a decisions model writes neither @max-output@
-- nor a thinking level other than @off@, and its options pass
-- 'validateDecisionsRealization'. Every other realization writes both
-- @thinking@ and @max-output@.
validateRealizationSettings :: RoutingConfigV2 -> Text -> Map Text ProfileV2 -> Either Text ()
validateRealizationSettings config personaName profiles =
  forM_ (Map.toList profiles) $ \(profileName, ProfileV2 chain) ->
    forM_ chain $ \realization ->
      firstText
        (\problem -> "persona '" <> personaName <> "' profile '" <> profileName <> "': " <> problem)
        (settingsOf realization)
  where
    settingsOf RealizationV2 {..} = case decisionsDialectOf config realizationV2Model of
      Just dialect -> do
        when (isJust realizationV2MaxOutput) $
          Left ("decisions model '" <> realizationV2Model <> "' takes no max-output")
        validateDecisionsRealization
          dialect
          realizationV2Model
          (fromMaybe ThinkOff realizationV2Thinking)
          Nothing
          realizationV2Options
      Nothing ->
        unless (isJust realizationV2Thinking && isJust realizationV2MaxOutput) $
          Left ("realization of model '" <> realizationV2Model <> "' needs both thinking and max-output")

-- | The dialect of the decisions engine that serves a concrete model alias,
-- or 'Nothing' when the alias is unknown or served by another kind of engine.
decisionsDialectOf :: RoutingConfigV2 -> Text -> Maybe Dialect
decisionsDialectOf config alias = do
  model <- Map.lookup alias (routingV2Models config)
  engine <- Map.lookup (concreteModelEngine model) (routingV2Engines config)
  case engineBackend engine of
    BackendDecisions dialect -> Just dialect
    _ -> Nothing

-- | A realization of a decisions model sets no thinking level and no output
-- limit, because a decisions endpoint has neither, and its options never
-- name a body key that the engine writes itself.
validateDecisionsRealization :: Dialect -> Text -> Thinking -> Maybe Integer -> Map Text Value -> Either Text ()
validateDecisionsRealization dialect alias thinking maximumOutput options = do
  unless (thinking == ThinkOff && isNothing maximumOutput) $
    Left ("decisions model '" <> alias <> "' takes no thinking level and no output limit")
  forM_ (Map.keys options) $ \key ->
    when (key `elem` reservedBodyKeys dialect) $
      Left ("decisions model '" <> alias <> "' option '" <> key <> "' names a request field that the engine writes itself")

validatePersona :: RoutingConfigV2 -> Text -> Persona -> Either Text ()
validatePersona config@RoutingConfigV2 {..} name Persona {..} = do
  distinct ("persona '" <> name <> "' engines") personaEngines
  distinct ("persona '" <> name <> "' models") personaModels
  forM_ personaEngines $ \engine ->
    unless (engine `Map.member` routingV2Engines) (Left ("persona '" <> name <> "' names unknown engine '" <> engine <> "'"))
  forM_ personaModels $ \modelName -> do
    model <- maybe (Left ("persona '" <> name <> "' names unknown model '" <> modelName <> "'")) Right (Map.lookup modelName routingV2Models)
    unless (concreteModelEngine model `elem` personaEngines) $
      Left ("persona '" <> name <> "' model '" <> modelName <> "' belongs to engine '" <> concreteModelEngine model <> "' outside persona")
  forM_ (Map.toList personaProfiles) $ \(profileName, profile) -> do
    validateProfileName profileName
    validateProfileModels name personaModels profileName profile
  validateRealizationSettings config name personaProfiles

applyProjectProfiles :: RoutingConfigV2 -> Text -> Persona -> Map Text ProfileV2 -> Either Text Persona
applyProjectProfiles config personaName persona overrides = do
  validateNamedMap "project profile" overrides
  forM_ (Map.toList overrides) $ \(name, profile) -> do
    unless (name `Map.member` personaProfiles persona) $
      Left ("project profile '" <> name <> "' does not replace a profile declared by persona '" <> personaName <> "'")
    validateProfileName name
    validateProfileModels personaName (personaModels persona) name profile
  let selected = persona {personaProfiles = overrides `Map.union` personaProfiles persona}
  validatePersona config personaName selected
  pure selected

validateProfileModels :: Text -> [Text] -> Text -> ProfileV2 -> Either Text ()
validateProfileModels personaName allowed profileName (ProfileV2 chain) =
  forM_ chain $ \realization ->
    unless (realizationV2Model realization `elem` allowed) $
      Left
        ( "profile '"
            <> profileName
            <> "' names model '"
            <> realizationV2Model realization
            <> "' outside persona '"
            <> personaName
            <> "'"
        )

validateCatalogue :: Catalogue -> Either Text Catalogue
validateCatalogue catalogue@Catalogue {..} = do
  unless (catalogueTimeoutMs > 0 && catalogueTimeoutMs <= maxCatalogueTimeoutMs) (Left "catalogue timeout-ms is outside 1..60000")
  unless (catalogueMaxBytes > 0 && catalogueMaxBytes <= maxCatalogueBytes) (Left "catalogue max-bytes is outside 1..4194304")
  unless (Map.size catalogueHeaders <= maxCatalogueHeaders) (Left "catalogue has more than 64 headers")
  validateUrl "catalogue" catalogueAuth catalogueUrl
  validateHeaders "catalogue" catalogueAuth catalogueHeaders
  pure catalogue

validateEndpoint :: Endpoint -> Either Text Endpoint
validateEndpoint endpoint@Endpoint {..} = do
  unless (endpointTimeoutMs > 0 && endpointTimeoutMs <= maxEndpointTimeoutMs) (Left "endpoint timeout-ms is outside 1..600000")
  unless (endpointMaxBytes > 0 && endpointMaxBytes <= maxEndpointBytes) (Left "endpoint max-bytes is outside 1..4194304")
  unless (Map.size endpointHeaders <= maxCatalogueHeaders) (Left "endpoint has more than 64 headers")
  validateUrl "endpoint" endpointAuth endpointUrl
  validateHeaders "endpoint" endpointAuth endpointHeaders
  pure endpoint

-- | The URL rule shared by catalogues and decisions endpoints, whose refusals
-- begin with @label@. An @https@ URL is always allowed. A plain @http@ URL is
-- allowed only without authentication and only for a literal loopback host.
validateUrl :: Text -> Maybe CatalogueAuth -> Text -> Either Text ()
validateUrl label auth url = do
  when (BS.length (encodeUtf8 url) > maxCatalogueUrlBytes) (Left (label <> " URL exceeds 8192 UTF-8 bytes"))
  when (T.any (\c -> isSpace c || isControl c) url) (Left (label <> " URL contains whitespace or controls"))
  when ("#" `T.isInfixOf` url) (Left (label <> " URL contains a fragment"))
  let (scheme, separator) = T.breakOn "://" url
  when (T.null separator) (Left (label <> " URL has no scheme"))
  let afterScheme = T.drop 3 separator
      authority = T.takeWhile (\c -> c /= '/' && c /= '?' && c /= '#') afterScheme
      query = case T.breakOn "?" url of
        (_, rest) | T.null rest -> ""
        (_, rest) -> T.takeWhile (/= '#') (T.drop 1 rest)
  when (T.null authority) (Left (label <> " URL has no authority"))
  when ("@" `T.isInfixOf` authority) (Left (label <> " URL contains user-info"))
  host <- maybe (Left (label <> " URL has an invalid authority")) Right (authorityHost authority)
  when (BS.length (encodeUtf8 query) > maxCatalogueQueryBytes) (Left (label <> " URL query exceeds 4096 UTF-8 bytes"))
  unless (validPercentEncoding query) (Left (label <> " URL contains malformed percent encoding"))
  let queryItems = parseQuery (encodeUtf8 ("?" <> query))
  when (length queryItems > maxCatalogueQueryItems) (Left (label <> " URL query has more than 64 items"))
  queryKeys <-
    traverse
      (firstText (const (label <> " URL query key is not UTF-8")) . decodeUtf8')
      [key | (key, _) <- queryItems]
  when (any sensitiveName queryKeys) (Left (label <> " URL contains a credential-shaped query key"))
  case (T.toLower scheme, auth) of
    ("https", _) -> pure ()
    ("http", Nothing) -> unless (literalLoopback host) (Left ("unauthenticated HTTP " <> label <> " is not a literal loopback address"))
    ("http", Just _) -> Left ("authenticated " <> label <> " URL uses plain HTTP")
    _ -> Left (label <> " URL scheme is not HTTP or HTTPS")

authorityHost :: Text -> Maybe Text
authorityHost authority
  | Just bracketed <- T.stripPrefix "[" authority =
      let (host, closing) = T.breakOn "]" bracketed
       in if T.null host || T.null closing || not (validPortSuffix (T.drop 1 closing)) then Nothing else Just host
  | otherwise = case T.splitOn ":" authority of
      [host] | not (T.null host) -> Just host
      [host, port] | not (T.null host) && validPort port -> Just host
      _ -> Nothing

validPortSuffix :: Text -> Bool
validPortSuffix suffix
  | T.null suffix = True
  | Just port <- T.stripPrefix ":" suffix = validPort port
  | otherwise = False

validPort :: Text -> Bool
validPort value = case TextRead.decimal value of
  Right (port, rest) -> T.null rest && port >= (0 :: Int) && port <= 65535
  Left _ -> False

literalLoopback :: Text -> Bool
literalLoopback "::1" = True
literalLoopback host = case traverse octet (T.splitOn "." host) of
  Just [127, _, _, _] -> True
  _ -> False
  where
    octet value = case TextRead.decimal value of
      Right (number, rest) | T.null rest && number >= (0 :: Int) && number <= 255 -> Just number
      _ -> Nothing

validPercentEncoding :: Text -> Bool
validPercentEncoding value = case T.uncons value of
  Nothing -> True
  Just ('%', rest) -> case T.uncons rest of
    Just (first, rest') | isHexDigit first -> case T.uncons rest' of
      Just (second, more) | isHexDigit second -> validPercentEncoding more
      _ -> False
    _ -> False
  Just (_, rest) -> validPercentEncoding rest

validateHeaders :: Text -> Maybe CatalogueAuth -> Map Text Text -> Either Text ()
validateHeaders label auth headers = do
  forM_ (Map.toList headers) $ \(name, value) -> do
    unless (headerName name) (Left (label <> " header name '" <> name <> "' is invalid"))
    when (sensitiveName name) (Left (label <> " header '" <> name <> "' must use auth.secret"))
    when (BS.length (encodeUtf8 value) > maxCatalogueHeaderValueBytes || T.any isControl value) $
      Left (label <> " header '" <> name <> "' is invalid or exceeds 8192 bytes")
  let total = sum [BS.length (encodeUtf8 name) + BS.length (encodeUtf8 value) | (name, value) <- Map.toList headers]
  when (total > maxCatalogueHeaderBytes) (Left (label <> " headers exceed 61440 bytes"))
  forM_ auth $ \value -> do
    unless (headerName (catalogueAuthHeader value)) (Left (label <> " auth header name is invalid"))
    when (any ((== T.toLower (catalogueAuthHeader value)) . T.toLower) (Map.keys headers)) $
      Left (label <> " auth header is duplicated in literal headers")

parseDuration :: Text -> Parser Integer
parseDuration value = case T.unsnoc value of
  Nothing -> fail "duration is empty"
  Just (digits, suffix) -> do
    multiplier <- case suffix of
      's' -> pure 1
      'm' -> pure 60
      'h' -> pure 3600
      'd' -> pure 86400
      _ -> fail "duration suffix must be s, m, h, or d"
    count <- case TextRead.decimal digits of
      Right (n, rest) | T.null rest && n > (0 :: Integer) -> pure n
      _ -> fail "duration must be a positive integer plus s, m, h, or d"
    let seconds = count * multiplier
    when (seconds > 365 * 86400) (fail "duration exceeds one year")
    pure seconds

modelId :: String -> Text -> Parser Text
modelId label value = do
  normalized <- nonBlank label value
  when (BS.length (encodeUtf8 normalized) > maxModelIdBytes) (fail (label <> " exceeds 512 UTF-8 bytes"))
  when (T.any (\c -> isSpace c || isControl c || generalCategory c == Format) normalized) (fail (label <> " contains whitespace or controls"))
  pure normalized

sensitiveName :: Text -> Bool
sensitiveName name = any (`T.isInfixOf` collapsed) fragments
  where
    collapsed = T.filter isAlphaNum (T.toLower name)
    fragments = ["token", "secret", "password", "credential", "auth", "oauth", "cookie", "bearer", "key", "certificate", "private", "signing"]

scalarV2Option :: Value -> Bool
scalarV2Option (String _) = True
scalarV2Option (Number _) = True
scalarV2Option (Bool _) = True
scalarV2Option _ = False

nonBlank :: String -> Text -> Parser Text
nonBlank label value
  | T.null (T.strip value) = fail (label <> " is empty")
  | value /= T.strip value = fail (label <> " has surrounding whitespace")
  | otherwise = pure value

validateNamedMap :: Text -> Map Text a -> Either Text ()
validateNamedMap label values =
  forM_ (Map.keys values) $ \name ->
    unless (not (T.null name) && name == T.strip name) $
      Left (label <> " name is empty or has surrounding whitespace")

validateProfileName :: Text -> Either Text ()
validateProfileName name = do
  unless (not (T.null name) && name == T.strip name) (Left "profile name is empty or has surrounding whitespace")
  when ("#" `T.isInfixOf` name) (Left ("profile name '" <> name <> "' contains reserved character '#'"))

distinct :: Text -> [Text] -> Either Text ()
distinct label values =
  when (length values /= length (nub values)) (Left (label <> " contains duplicates"))


headerName :: Text -> Bool
headerName name = not (T.null name) && T.all (\c -> isAscii c && (isAlphaNum c || c `elem` ("!#$%&'*+-.^_`|~" :: String))) name

environmentName :: Text -> Bool
environmentName name = case T.uncons name of
  Nothing -> False
  Just (first, rest) ->
    isAscii first
      && (isAlpha first || first == '_')
      && T.all (\c -> isAscii c && (isAlphaNum c || c == '_')) rest

onlyKeys :: String -> [Text] -> Object -> Parser ()
onlyKeys label allowed object =
  case filter (`notElem` allowed) (map Key.toText (KeyMap.keys object)) of
    [] -> pure ()
    unknown -> fail (label <> " has unknown field(s): " <> T.unpack (T.intercalate ", " unknown))

projectKeys :: Object -> Parser ()
projectKeys object =
  case filter (`notElem` ["version", "persona", "profiles"]) (map Key.toText (KeyMap.keys object)) of
    [] -> pure ()
    unknown ->
      fail
        ( "project routing has unknown field(s): "
            <> T.unpack (T.intercalate ", " unknown)
            <> "; privileged routing definitions belong only in the user file"
        )

-- Data.Yaml's pure decoder intentionally drops duplicate-key warnings. Use the
-- same pinned libyaml decoder while retaining those warnings before FromJSON.
decodeYaml :: (FromJSON a) => BS.ByteString -> Either Text a
decodeYaml bytes = unsafePerformIO $ do
  decoded <- YamlInternal.decodeHelper (LibYaml.decode bytes)
  pure $ case decoded of
    Left problem -> Left (T.pack (YamlInternal.prettyPrintParseException problem))
    Right (YamlInternal.DuplicateKey path : _, _) -> Left (T.pack (formatError path "duplicate YAML key"))
    Right ([], parsed) -> firstText T.pack parsed
{-# NOINLINE decodeYaml #-}

firstText :: (e -> Text) -> Either e a -> Either Text a
firstText render = either (Left . render) Right
