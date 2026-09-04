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
  )
where

import Agentic.Engine (Thinking)
import Agentic.Route (Backend, parseBackend)
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
import Data.Maybe (fromMaybe)
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

data EngineDefinition = EngineDefinition
  { engineBackend :: !Backend,
    engineProvider :: !Text,
    engineEnvironment :: !(Map Text EnvironmentBinding),
    engineCatalogue :: !(Maybe Catalogue)
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

data RealizationV2 = RealizationV2
  { realizationV2Model :: !Text,
    realizationV2Thinking :: !Thinking,
    realizationV2MaxOutput :: !(Maybe Integer),
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

instance FromJSON EngineDefinition where
  parseJSON = withObject "engine" $ \o -> do
    onlyKeys "engine" ["backend", "provider", "environment", "catalogue"] o
    backendText <- nonBlank "engine backend" =<< o .: "backend"
    backend <- either (fail . T.unpack) pure (parseBackend backendText)
    provider <- nonBlank "engine provider" =<< o .: "provider"
    environment <- fromMaybe Map.empty <$> o .:? "environment"
    catalogue <- o .:? "catalogue"
    pure (EngineDefinition backend provider environment catalogue)

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
    thinking <- o .: "thinking"
    maximumValue <- o .: "max-output"
    maximumOutput <- case maximumValue of
      String "unconstrained" -> pure Nothing
      value -> Just <$> parseJSON value
    when (maybe False (<= 0) maximumOutput) (fail "max-output must be positive or 'unconstrained'")
    options <- fromMaybe Map.empty <$> o .:? "options"
    forM_ (Map.toList options) $ \(name, value) -> do
      when (sensitiveName name) (fail ("profile option '" <> T.unpack name <> "' may carry a secret"))
      unless (scalarV2Option value) (fail ("profile option '" <> T.unpack name <> "' must be scalar"))
    pure (RealizationV2 model thinking maximumOutput options)

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
      <*> o .: "secrets"
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
  forM_ project $ \layer ->
    unless (projectRoutingPersona layer `Map.member` routingV2Personas config) $
      Left ("project selects unknown persona '" <> projectRoutingPersona layer <> "'")
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
  validateBackendAliases routingV2Engines
  forM_ (Map.toList routingV2Models) $ \(name, model) -> validateConcreteModel routingV2Engines name model
  forM_ (Map.toList routingV2Personas) $ \(name, persona) -> validatePersona config name persona
  pure config

validateEngine :: Map Text SecretReference -> Text -> EngineDefinition -> Either Text ()
validateEngine secrets name EngineDefinition {..} = do
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

validateBackendAliases :: Map Text EngineDefinition -> Either Text ()
validateBackendAliases engines =
  forM_ (Map.toList grouped) $ \(backend, definitions) -> case definitions of
    [] -> pure ()
    (firstName, firstDefinition) : rest ->
      unless (all (sameProcessDefinition firstDefinition . snd) rest) $
        Left
          ( "engine aliases "
              <> T.intercalate ", " (firstName : map fst rest)
              <> " share backend "
              <> T.pack (show backend)
              <> " but have different process definitions"
          )
  where
    sameProcessDefinition left right =
      engineBackend left == engineBackend right
        && engineEnvironment left == engineEnvironment right
        && engineCatalogue left == engineCatalogue right
    grouped =
      Map.fromListWith (<>)
        [(engineBackend definition, [(name, definition)]) | (name, definition) <- Map.toList engines]

validateConcreteModel :: Map Text EngineDefinition -> Text -> ConcreteModel -> Either Text ()
validateConcreteModel engines name model =
  unless (concreteModelEngine model `Map.member` engines) $
    Left ("concrete model '" <> name <> "' names unknown engine '" <> concreteModelEngine model <> "'")

validatePersona :: RoutingConfigV2 -> Text -> Persona -> Either Text ()
validatePersona RoutingConfigV2 {..} name Persona {..} = do
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
  validateUrl catalogueAuth catalogueUrl
  validateHeaders catalogueAuth catalogueHeaders
  pure catalogue

validateUrl :: Maybe CatalogueAuth -> Text -> Either Text ()
validateUrl auth url = do
  when (BS.length (encodeUtf8 url) > maxCatalogueUrlBytes) (Left "catalogue URL exceeds 8192 UTF-8 bytes")
  when (T.any (\c -> isSpace c || isControl c) url) (Left "catalogue URL contains whitespace or controls")
  when ("#" `T.isInfixOf` url) (Left "catalogue URL contains a fragment")
  let (scheme, separator) = T.breakOn "://" url
  when (T.null separator) (Left "catalogue URL has no scheme")
  let afterScheme = T.drop 3 separator
      authority = T.takeWhile (\c -> c /= '/' && c /= '?' && c /= '#') afterScheme
      query = case T.breakOn "?" url of
        (_, rest) | T.null rest -> ""
        (_, rest) -> T.takeWhile (/= '#') (T.drop 1 rest)
  when (T.null authority) (Left "catalogue URL has no authority")
  when ("@" `T.isInfixOf` authority) (Left "catalogue URL contains user-info")
  host <- maybe (Left "catalogue URL has an invalid authority") Right (authorityHost authority)
  when (BS.length (encodeUtf8 query) > maxCatalogueQueryBytes) (Left "catalogue URL query exceeds 4096 UTF-8 bytes")
  unless (validPercentEncoding query) (Left "catalogue URL contains malformed percent encoding")
  let queryItems = parseQuery (encodeUtf8 ("?" <> query))
  when (length queryItems > maxCatalogueQueryItems) (Left "catalogue URL query has more than 64 items")
  queryKeys <-
    traverse
      (firstText (const "catalogue URL query key is not UTF-8") . decodeUtf8')
      [key | (key, _) <- queryItems]
  when (any sensitiveName queryKeys) (Left "catalogue URL contains a credential-shaped query key")
  case (T.toLower scheme, auth) of
    ("https", _) -> pure ()
    ("http", Nothing) -> unless (literalLoopback host) (Left "unauthenticated HTTP catalogue is not a literal loopback address")
    ("http", Just _) -> Left "authenticated catalogue URL uses plain HTTP"
    _ -> Left "catalogue URL scheme is not HTTP or HTTPS"

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

validateHeaders :: Maybe CatalogueAuth -> Map Text Text -> Either Text ()
validateHeaders auth headers = do
  forM_ (Map.toList headers) $ \(name, value) -> do
    unless (headerName name) (Left ("catalogue header name '" <> name <> "' is invalid"))
    when (sensitiveName name) (Left ("catalogue header '" <> name <> "' must use auth.secret"))
    when (BS.length (encodeUtf8 value) > maxCatalogueHeaderValueBytes || T.any isControl value) $
      Left ("catalogue header '" <> name <> "' is invalid or exceeds 8192 bytes")
  let total = sum [BS.length (encodeUtf8 name) + BS.length (encodeUtf8 value) | (name, value) <- Map.toList headers]
  when (total > maxCatalogueHeaderBytes) (Left "catalogue headers exceed 61440 bytes")
  forM_ auth $ \value -> do
    unless (headerName (catalogueAuthHeader value)) (Left "catalogue auth header name is invalid")
    when (any ((== T.toLower (catalogueAuthHeader value)) . T.toLower) (Map.keys headers)) $
      Left "catalogue auth header is duplicated in literal headers"

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
