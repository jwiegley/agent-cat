{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

-- Executable semantic oracle for the proposed routing-v2 documentation.
-- It reads fenced examples, performs no network access, and is not production routing code.
module Main (main) where

import Control.Monad (foldM, forM_, unless)
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
import Data.Aeson.Types (Parser, parseEither)
import qualified Data.ByteString as BS
import Data.Char (GeneralCategory (Format), generalCategory, isAlphaNum, isControl, isSpace)
import Data.List (nub, sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Maybe (catMaybes, fromMaybe, isJust)
import Data.Ord (Down (..))
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import qualified Data.Text.IO as TIO
import qualified Data.Text.Read as TextRead
import qualified Data.Yaml as Yaml
import System.Exit (exitFailure)

newtype SecretDef = SecretDef {secretEnv :: Text}
  deriving (Eq, Show)

data EnvBinding = EnvSecret !Text | EnvValue !Text
  deriving (Eq, Show)

data Auth = Auth
  { authHeader :: !Text,
    authScheme :: !(Maybe Text),
    authSecret :: !Text
  }
  deriving (Eq, Show)

data CachePolicy = CachePolicy
  { cacheFreshFor :: !Text,
    cacheStaleIfError :: !Text
  }
  deriving (Eq, Show)

data Catalogue = Catalogue
  { catalogueDialect :: !Text,
    catalogueUrl :: !Text,
    catalogueAuth :: !(Maybe Auth),
    catalogueHeaders :: !(Map Text Text),
    catalogueTimeoutMs :: !Int,
    catalogueMaxBytes :: !Int,
    catalogueCache :: !CachePolicy
  }
  deriving (Eq, Show)

data EngineDef = EngineDef
  { engineBackend :: !Text,
    engineProvider :: !Text,
    engineEnvironment :: !(Map Text EnvBinding),
    engineCatalogue :: !(Maybe Catalogue)
  }
  deriving (Eq, Show)

data Selector
  = SelectExact !Text
  | SelectPrefix !Text !(Maybe Text)
  deriving (Eq, Show)

data ModelDef = ModelDef
  { modelEngine :: !Text,
    modelSelectors :: ![Selector]
  }
  deriving (Eq, Show)

data Rung = Rung
  { rungModel :: !Text,
    rungThinking :: !Text,
    rungMaxOutput :: !Value,
    rungOptions :: !(Map Text Value)
  }
  deriving (Eq, Show)

newtype Profile = Profile {profileChain :: [Rung]}
  deriving (Eq, Show)

data Persona = Persona
  { personaEngines :: ![Text],
    personaModels :: ![Text],
    personaProfiles :: !(Map Text Profile)
  }
  deriving (Eq, Show)

data UserDoc = UserDoc
  { userDefaultPersona :: !Text,
    userSecrets :: !(Map Text SecretDef),
    userEngines :: !(Map Text EngineDef),
    userModels :: !(Map Text ModelDef),
    userPersonas :: !(Map Text Persona)
  }
  deriving (Eq, Show)

data ProjectDoc = ProjectDoc
  { projectPersona :: !Text,
    projectProfiles :: !(Map Text Profile)
  }
  deriving (Eq, Show)

data Freshness = Fresh | Stale
  deriving (Eq, Show)

data DiscoveryMode = NormalDiscovery | OfflineDiscovery | RefreshDiscovery
  deriving (Eq, Show)

data CacheDecision = UseFreshCache | UseFetched | UseStaleCache | NoInventory
  deriving (Eq, Show)

data ModelEntry = ModelEntry
  { entryId :: !Text,
    entryCreated :: !(Maybe Integer)
  }
  deriving (Eq, Show)

type Inventory = Map Text (Freshness, [ModelEntry])

type Check a = Either Text a

instance FromJSON SecretDef where
  parseJSON = withObject "secret" $ \o -> do
    onlyKeys "secret" ["env"] o
    SecretDef <$> o .: "env"

instance FromJSON EnvBinding where
  parseJSON = withObject "environment binding" $ \o -> do
    onlyKeys "environment binding" ["secret", "value"] o
    secret <- o .:? "secret"
    value <- o .:? "value"
    case (secret, value) of
      (Just name, Nothing) -> pure (EnvSecret name)
      (Nothing, Just literal) -> pure (EnvValue literal)
      _ -> fail "environment binding requires exactly one of secret or value"

instance FromJSON Auth where
  parseJSON = withObject "catalogue auth" $ \o -> do
    onlyKeys "catalogue auth" ["header", "scheme", "secret"] o
    Auth <$> o .: "header" <*> o .:? "scheme" <*> o .: "secret"

instance FromJSON CachePolicy where
  parseJSON = withObject "cache policy" $ \o -> do
    onlyKeys "cache policy" ["fresh-for", "stale-if-error"] o
    CachePolicy <$> o .: "fresh-for" <*> o .: "stale-if-error"

instance FromJSON Catalogue where
  parseJSON = withObject "catalogue" $ \o -> do
    onlyKeys "catalogue" ["dialect", "url", "auth", "headers", "timeout-ms", "max-bytes", "cache"] o
    Catalogue
      <$> o .: "dialect"
      <*> o .: "url"
      <*> o .:? "auth"
      <*> (fromMaybe Map.empty <$> o .:? "headers")
      <*> o .: "timeout-ms"
      <*> o .: "max-bytes"
      <*> o .: "cache"

instance FromJSON EngineDef where
  parseJSON = withObject "engine" $ \o -> do
    onlyKeys "engine" ["backend", "provider", "environment", "catalogue"] o
    EngineDef
      <$> o .: "backend"
      <*> o .: "provider"
      <*> (fromMaybe Map.empty <$> o .:? "environment")
      <*> o .:? "catalogue"

instance FromJSON Selector where
  parseJSON = withObject "model selector" $ \o -> do
    onlyKeys "model selector" ["exact", "prefix", "order"] o
    exact <- o .:? "exact"
    prefix <- o .:? "prefix"
    order <- o .:? "order"
    case (exact, prefix, order) of
      (Just value, Nothing, Nothing) -> pure (SelectExact value)
      (Nothing, Just value, ordering) -> pure (SelectPrefix value ordering)
      _ -> fail "model selector is exact or prefix; only prefix may carry order"

instance FromJSON ModelDef where
  parseJSON = withObject "model" $ \o -> do
    onlyKeys "model" ["engine", "select"] o
    ModelDef <$> o .: "engine" <*> o .: "select"

instance FromJSON Rung where
  parseJSON = withObject "profile rung" $ \o -> do
    onlyKeys "profile rung" ["model", "thinking", "max-output", "options"] o
    Rung
      <$> o .: "model"
      <*> o .: "thinking"
      <*> o .: "max-output"
      <*> (fromMaybe Map.empty <$> o .:? "options")

instance FromJSON Profile where
  parseJSON = withObject "profile" $ \o -> do
    onlyKeys "profile" ["chain"] o
    Profile <$> o .: "chain"

instance FromJSON Persona where
  parseJSON = withObject "persona" $ \o -> do
    onlyKeys "persona" ["engines", "models", "profiles"] o
    Persona <$> o .: "engines" <*> o .: "models" <*> o .: "profiles"

instance FromJSON UserDoc where
  parseJSON = withObject "version-2 user routing" $ \o -> do
    onlyKeys "version-2 user routing" ["version", "default-persona", "secrets", "engines", "models", "personas"] o
    version <- o .: "version" :: Parser Int
    unless (version == 2) (fail "user routing version is not 2")
    UserDoc
      <$> o .: "default-persona"
      <*> o .: "secrets"
      <*> o .: "engines"
      <*> o .: "models"
      <*> o .: "personas"

instance FromJSON ProjectDoc where
  parseJSON = withObject "version-2 project routing" $ \o -> do
    onlyKeys "version-2 project routing" ["version", "persona", "profiles"] o
    version <- o .: "version" :: Parser Int
    unless (version == 2) (fail "project routing version is not 2")
    ProjectDoc <$> o .: "persona" <*> (fromMaybe Map.empty <$> o .:? "profiles")

onlyKeys :: String -> [Text] -> Object -> Parser ()
onlyKeys label allowed object =
  case filter (`notElem` allowed) (map Key.toText (KeyMap.keys object)) of
    [] -> pure ()
    unknown -> fail (label <> " has unknown field(s): " <> T.unpack (T.intercalate ", " unknown))

ensure :: Bool -> Text -> Check ()
ensure condition message = unless condition (Left message)

nonEmptyDistinct :: Text -> [Text] -> Check ()
nonEmptyDistinct label values = do
  ensure (not (null values)) (label <> " is empty")
  ensure (length values == length (nub values)) (label <> " contains duplicates")

validModelId :: Text -> Bool
validModelId value =
  not (T.null value)
    && T.strip value == value
    && not (T.any (\c -> isSpace c || isControl c || generalCategory c == Format) value)

sensitiveName :: Text -> Bool
sensitiveName name = any (`T.isInfixOf` collapsed) fragments
  where
    collapsed = T.filter isAlphaNum (T.toLower name)
    fragments =
      [ "token",
        "secret",
        "password",
        "credential",
        "auth",
        "oauth",
        "cookie",
        "bearer",
        "key",
        "certificate",
        "private",
        "signing"
      ]

scalarOption :: Value -> Bool
scalarOption (String _) = True
scalarOption (Number _) = True
scalarOption (Bool _) = True
scalarOption _ = False

parseDurationSeconds :: Text -> Check Integer
parseDurationSeconds value = case T.unsnoc value of
  Nothing -> Left "duration is empty"
  Just (digits, suffix) -> do
    multiplier <- case suffix of
      's' -> Right 1
      'm' -> Right 60
      'h' -> Right 3600
      'd' -> Right 86400
      _ -> Left ("duration has unknown suffix: " <> value)
    count <- case TextRead.decimal digits of
      Right (n, rest) | T.null rest && n > (0 :: Integer) -> Right n
      _ -> Left ("duration is not a positive integer plus s/m/h/d: " <> value)
    let seconds = count * multiplier
    ensure (seconds <= 31536000) ("duration exceeds one year: " <> value)
    pure seconds

headerNameValid :: Text -> Bool
headerNameValid name =
  not (T.null name)
    && T.all (\c -> isAlphaNum c || c `elem` ("!#$%&'*+-.^_`|~" :: String)) name

headerValueValid :: Text -> Bool
headerValueValid value =
  BS.length (encodeUtf8 value) <= 8192
    && not (T.any (\c -> c == '\r' || c == '\n' || isControl c) value)

validateHeaders :: Maybe Auth -> Map Text Text -> Check ()
validateHeaders auth headers = do
  forM_ (Map.toList headers) $ \(name, value) -> do
    ensure (headerNameValid name) ("invalid catalogue header name " <> name)
    ensure (not (sensitiveName name)) ("sensitive catalogue header must use auth.secret: " <> name)
    ensure (headerValueValid value) ("invalid or oversized catalogue header " <> name)
  let total = sum [BS.length (encodeUtf8 name) + BS.length (encodeUtf8 value) | (name, value) <- Map.toList headers]
  ensure (total <= 61440) "catalogue literal headers exceed 61440 bytes"
  forM_ auth $ \value -> do
    ensure (headerNameValid (authHeader value)) "invalid catalogue auth header name"
    ensure (all ((/= T.toLower (authHeader value)) . T.toLower) (Map.keys headers)) "catalogue auth header is duplicated in literal headers"

validateCatalogueUrl :: Maybe Auth -> Text -> Check ()
validateCatalogueUrl auth url = do
  ensure (BS.length (encodeUtf8 url) <= 8192) "catalogue URL exceeds 8192 bytes"
  ensure (not (T.any (\c -> isSpace c || isControl c) url)) "catalogue URL contains whitespace or controls"
  ensure (not ("#" `T.isInfixOf` url)) "catalogue URL contains a fragment"
  let (scheme, withSeparator) = T.breakOn "://" url
  ensure (not (T.null withSeparator)) "catalogue URL has no scheme separator"
  let afterScheme = T.drop 3 withSeparator
      authority = T.takeWhile (\c -> c /= '/' && c /= '?' && c /= '#') afterScheme
      host =
        if "[" `T.isPrefixOf` authority
          then T.takeWhile (/= ']') (T.drop 1 authority)
          else T.takeWhile (/= ':') authority
      loopback = host == "::1" || ("127." `T.isPrefixOf` host && T.all (\c -> c == '.' || (c >= '0' && c <= '9')) host)
      query = case T.breakOn "?" url of
        (_, rest) | T.null rest -> ""
        (_, rest) -> T.takeWhile (/= '#') (T.drop 1 rest)
      queryParts = filter (not . T.null) (T.splitOn "&" query)
      queryKeys = map (T.takeWhile (/= '=')) queryParts
  ensure (not (T.null authority)) "catalogue URL has no authority"
  ensure (not ("@" `T.isInfixOf` authority)) "catalogue URL contains user-info"
  ensure (BS.length (encodeUtf8 query) <= 4096) "catalogue URL query exceeds 4096 bytes"
  ensure (length queryParts <= 64) "catalogue URL query has more than 64 items"
  ensure (not (any sensitiveName queryKeys)) "catalogue URL contains a sensitive query key"
  case (T.toLower scheme, auth) of
    ("https", _) -> pure ()
    ("http", Nothing) -> ensure loopback "unauthenticated HTTP catalogue is not a literal loopback address"
    ("http", Just _) -> Left "authenticated catalogue URL uses plain HTTP"
    _ -> Left "catalogue URL scheme is not HTTP or HTTPS"

cacheDecision :: DiscoveryMode -> CachePolicy -> Maybe Integer -> Bool -> Check CacheDecision
cacheDecision mode policy age fetchSucceeded = do
  fresh <- parseDurationSeconds (cacheFreshFor policy)
  stale <- parseDurationSeconds (cacheStaleIfError policy)
  ensure (stale >= fresh) "stale-if-error is shorter than fresh-for"
  forM_ age $ \seconds -> ensure (seconds >= 0) "cache age is negative"
  let cached
        | maybe False (<= fresh) age = Just UseFreshCache
        | maybe False (<= stale) age = Just UseStaleCache
        | otherwise = Nothing
  case mode of
    OfflineDiscovery -> pure (fromMaybe NoInventory cached)
    RefreshDiscovery -> if fetchSucceeded then pure UseFetched else Left "explicit refresh failed"
    NormalDiscovery -> case cached of
      Just UseFreshCache -> pure UseFreshCache
      _ | fetchSucceeded -> pure UseFetched
      Just UseStaleCache -> pure UseStaleCache
      _ -> pure NoInventory

validateUser :: UserDoc -> Check ()
validateUser UserDoc {..} = do
  ensure (Map.member userDefaultPersona userPersonas) "default persona is unknown"
  forM_ (Map.toList userSecrets) $ \(name, SecretDef envName) -> do
    ensure (not (T.null name) && not (T.null envName)) "secret name or source is empty"
  forM_ (Map.toList userEngines) $ \(name, engine) -> validateEngine userSecrets name engine
  forM_ (Map.toList userModels) $ \(name, model) -> validateModel userEngines name model
  forM_ (Map.toList userPersonas) $ \(name, persona) -> validatePersona userEngines userModels name persona

validateEngine :: Map Text SecretDef -> Text -> EngineDef -> Check ()
validateEngine secrets name EngineDef {..} = do
  ensure (not (T.null name) && not (T.null engineBackend) && not (T.null engineProvider)) "engine identity is empty"
  forM_ (Map.toList engineEnvironment) $ \(variable, binding) -> do
    ensure (headerNameValid variable) ("invalid environment variable name " <> variable)
    case binding of
      EnvSecret secret -> ensure (Map.member secret secrets) ("engine references unknown secret " <> secret)
      EnvValue value -> do
        ensure (not (T.null value)) ("engine has empty literal environment value " <> variable)
        ensure (not (sensitiveName variable)) ("sensitive environment variable must use a secret reference: " <> variable)
  forM_ engineCatalogue $ \catalogue -> do
    ensure (catalogueDialect catalogue `elem` ["openai", "anthropic"]) "catalogue dialect is unknown"
    ensure (catalogueTimeoutMs catalogue > 0 && catalogueTimeoutMs catalogue <= 60000) "catalogue timeout is outside 1..60000ms"
    ensure (catalogueMaxBytes catalogue > 0 && catalogueMaxBytes catalogue <= 4194304) "catalogue byte bound is invalid"
    fresh <- parseDurationSeconds (cacheFreshFor (catalogueCache catalogue))
    stale <- parseDurationSeconds (cacheStaleIfError (catalogueCache catalogue))
    ensure (stale >= fresh) "catalogue stale-if-error is shorter than fresh-for"
    ensure (Map.size (catalogueHeaders catalogue) <= 64) "catalogue has more than 64 literal headers"
    validateCatalogueUrl (catalogueAuth catalogue) (catalogueUrl catalogue)
    case catalogueAuth catalogue of
      Nothing -> pure ()
      Just auth -> do
        ensure (Map.member (authSecret auth) secrets) ("catalogue references unknown secret " <> authSecret auth)
        ensure (authScheme auth `elem` [Nothing, Just "bearer"]) "catalogue auth scheme is invalid"
    validateHeaders (catalogueAuth catalogue) (catalogueHeaders catalogue)

validateModel :: Map Text EngineDef -> Text -> ModelDef -> Check ()
validateModel engines name ModelDef {..} = do
  ensure (not (T.null name)) "model alias is empty"
  ensure (Map.member modelEngine engines) ("model " <> name <> " references unknown engine " <> modelEngine)
  ensure (not (null modelSelectors)) ("model " <> name <> " has no selectors")
  forM_ modelSelectors $ \case
    SelectExact value -> ensure (validModelId value) ("model " <> name <> " has invalid exact id")
    SelectPrefix value ordering -> do
      ensure (validModelId value) ("model " <> name <> " has invalid prefix")
      ensure (ordering `elem` [Nothing, Just "newest", Just "id-descending"]) ("model " <> name <> " has invalid selector order")

validatePersona :: Map Text EngineDef -> Map Text ModelDef -> Text -> Persona -> Check ()
validatePersona engines models name Persona {..} = do
  nonEmptyDistinct ("persona " <> name <> " engines") personaEngines
  nonEmptyDistinct ("persona " <> name <> " models") personaModels
  ensure (not (Map.null personaProfiles)) ("persona " <> name <> " has no profiles")
  forM_ personaEngines $ \engine -> ensure (Map.member engine engines) ("persona " <> name <> " references unknown engine " <> engine)
  forM_ personaModels $ \modelName -> do
    model <- maybe (Left ("persona " <> name <> " references unknown model " <> modelName)) Right (Map.lookup modelName models)
    ensure (modelEngine model `elem` personaEngines) ("persona " <> name <> " model " <> modelName <> " belongs to unauthorized engine " <> modelEngine model)
  forM_ (Map.toList personaProfiles) $ \(profileName, profile) -> validateProfile name personaModels profileName profile

validateProfile :: Text -> [Text] -> Text -> Profile -> Check ()
validateProfile persona allowedModels profileName (Profile chain) = do
  ensure (not (null chain)) ("profile " <> profileName <> " has an empty chain")
  forM_ chain $ \rung -> do
    ensure (rungModel rung `elem` allowedModels) ("profile " <> profileName <> " uses model " <> rungModel rung <> " outside persona " <> persona)
    ensure (rungThinking rung `elem` ["off", "minimal", "low", "medium", "high", "xhigh", "max"]) ("profile " <> profileName <> " has invalid thinking")
    forM_ (Map.toList (rungOptions rung)) $ \(option, value) -> do
      ensure (not (sensitiveName option)) ("profile " <> profileName <> " has sensitive option " <> option)
      ensure (scalarOption value) ("profile " <> profileName <> " has non-scalar option " <> option)
    case rungMaxOutput rung of
      String "unconstrained" -> pure ()
      Number n -> ensure (n > 0) ("profile " <> profileName <> " has non-positive max-output")
      _ -> Left ("profile " <> profileName <> " has invalid max-output")

validateProject :: UserDoc -> ProjectDoc -> Check ()
validateProject user ProjectDoc {..} = do
  persona <- maybe (Left ("project selects unknown persona " <> projectPersona)) Right (Map.lookup projectPersona (userPersonas user))
  forM_ (Map.toList projectProfiles) $ \(name, profile) -> validateProfile projectPersona (personaModels persona) name profile

resolveProfile :: UserDoc -> Text -> Map Text Profile -> Text -> Inventory -> Check [(Text, Text, Text)]
resolveProfile user personaName overrides profileName inventories = do
  persona <- maybe (Left ("unknown persona " <> personaName)) Right (Map.lookup personaName (userPersonas user))
  profile <- maybe (Left ("unknown profile " <> profileName)) Right (Map.lookup profileName (overrides `Map.union` personaProfiles persona))
  validateProfile personaName (personaModels persona) profileName profile
  traverse resolveRung (profileChain profile)
  where
    resolveRung rung = do
      model <- maybe (Left ("unknown model " <> rungModel rung)) Right (Map.lookup (rungModel rung) (userModels user))
      (identifier, source) <- resolveModel inventories model
      pure (rungModel rung, identifier, source)

resolveModel :: Inventory -> ModelDef -> Check (Text, Text)
resolveModel inventories ModelDef {..} = go modelSelectors
  where
    inventory = Map.lookup modelEngine inventories
    source Fresh = "fresh"
    source Stale = "stale-cache"
    go [] = Left ("no selector resolved on engine " <> modelEngine)
    go (SelectExact wanted : rest) = case inventory of
      Nothing -> Right (wanted, "static-unverified")
      Just (freshness, entries)
        | wanted `elem` map entryId entries -> Right (wanted, source freshness)
        | otherwise -> go rest
    go (SelectPrefix prefix ordering : rest) = case inventory of
      Nothing -> go rest
      Just (freshness, entries) ->
        let matches = filter (T.isPrefixOf prefix . entryId) entries
         in case matches of
              [] -> go rest
              [entry] -> Right (entryId entry, source freshness)
              _ -> case ordering of
                Nothing -> Left ("ambiguous prefix " <> prefix)
                Just "newest" -> do
                  ensure (all (isJust . entryCreated) matches) ("newest selector lacks timestamp for " <> prefix)
                  case sortOn (\entry -> (Down (fromMaybe 0 (entryCreated entry)), entryId entry)) matches of
                    chosen : _ -> Right (entryId chosen, source freshness)
                    [] -> Left ("newest selector produced no match for " <> prefix)
                Just "id-descending" -> case sortOn (Down . entryId) matches of
                  chosen : _ -> Right (entryId chosen, source freshness)
                  [] -> Left ("id-descending selector produced no match for " <> prefix)
                Just other -> Left ("unknown selector order " <> other)

selectPersona :: UserDoc -> Maybe Text -> Maybe Text -> Maybe Text -> Check Text
selectPersona user cli environment project = do
  let selected = fromMaybe (userDefaultPersona user) (firstJust [cli, environment, project])
  ensure (Map.member selected (userPersonas user)) ("unknown selected persona " <> selected)
  pure selected

firstJust :: [Maybe a] -> Maybe a
firstJust [] = Nothing
firstJust (Just value : _) = Just value
firstJust (Nothing : rest) = firstJust rest

childEnvironment :: UserDoc -> Text -> Map Text Text -> Check (Map Text Text)
childEnvironment UserDoc {..} engineName ambient = do
  engine <- maybe (Left ("unknown engine " <> engineName)) Right (Map.lookup engineName userEngines)
  let destinationNames = concatMap (Map.keys . engineEnvironment) (Map.elems userEngines)
      sourceNames = map secretEnv (Map.elems userSecrets)
      scrubbed = foldr Map.delete ambient (nub (destinationNames <> sourceNames))
  foldM apply scrubbed (Map.toList (engineEnvironment engine))
  where
    apply current (destination, binding) = do
      value <- case binding of
        EnvValue literal -> Right literal
        EnvSecret alias -> do
          SecretDef source <- maybe (Left ("unknown secret " <> alias)) Right (Map.lookup alias userSecrets)
          maybe (Left ("missing environment variable " <> source)) Right (Map.lookup source ambient)
      pure (Map.insert destination value current)

requiredSecretSources :: UserDoc -> Text -> Map Text Profile -> Text -> Check [Text]
requiredSecretSources user personaName overrides profileName = do
  persona <- maybe (Left ("unknown persona " <> personaName)) Right (Map.lookup personaName (userPersonas user))
  profile <- maybe (Left ("unknown profile " <> profileName)) Right (Map.lookup profileName (overrides `Map.union` personaProfiles persona))
  let aliases = map rungModel (profileChain profile)
  engineNames <- traverse (\alias -> maybe (Left ("unknown model " <> alias)) (Right . modelEngine) (Map.lookup alias (userModels user))) aliases
  engines <- traverse (\name -> maybe (Left ("unknown engine " <> name)) Right (Map.lookup name (userEngines user))) (nub engineNames)
  let secretNames = nub (concatMap engineSecrets engines)
  traverse (\name -> maybe (Left ("unknown secret " <> name)) (Right . secretEnv) (Map.lookup name (userSecrets user))) secretNames
  where
    engineSecrets EngineDef {..} =
      [secret | EnvSecret secret <- Map.elems engineEnvironment]
        <> catMaybes [authSecret <$> (engineCatalogue >>= catalogueAuth)]

checkSecrets :: UserDoc -> Text -> Map Text Profile -> Text -> Map Text Text -> Check ()
checkSecrets user persona overrides profileName environment = do
  sources <- requiredSecretSources user persona overrides profileName
  forM_ sources $ \source -> ensure (Map.member source environment) ("missing environment variable " <> source)

expectLeft :: Text -> Check a -> IO ()
expectLeft label = \case
  Left _ -> ok label
  Right _ -> die (label <> " unexpectedly succeeded")

allLeft :: [Check a] -> Bool
allLeft = all (either (const True) (const False))

expect :: Text -> Bool -> IO ()
expect label condition = if condition then ok label else die label

ok :: Text -> IO ()
ok label = TIO.putStrLn ("ok   " <> label)

die :: Text -> IO a
die message = TIO.putStrLn ("FAIL " <> message) >> exitFailure

decodeValue :: Text -> IO Value
decodeValue source =
  case Yaml.decodeEither' (encodeUtf8 source) of
    Left problem -> die ("YAML decode: " <> T.pack (Yaml.prettyPrintParseException problem))
    Right value -> pure value

decodeAs :: (FromJSON a) => Text -> Value -> IO a
decodeAs label value =
  case parseEither parseJSON value of
    Left problem -> die (label <> ": " <> T.pack problem)
    Right result -> pure result

duplicateYamlKeys :: Text -> [(Int, Text)]
duplicateYamlKeys source = reverse duplicates
  where
    (_, duplicates) = foldl step ([], []) (zip [1 ..] (T.lines source))
    step (stack, found) (lineNumber, raw)
      | T.null body || "#" `T.isPrefixOf` body = (stack, found)
      | otherwise =
          let item = "- " `T.isPrefixOf` body
              keyDepth = indentation + if item then 2 else 0
              content = if item then T.drop 2 body else body
              trimmed =
                if item
                  then dropWhile ((>= keyDepth) . fst) stack
                  else dropWhile ((> keyDepth) . fst) stack
              scoped = case trimmed of
                (depth, _) : _ | depth == keyDepth -> trimmed
                _ -> (keyDepth, Set.empty) : trimmed
           in case yamlKey content of
                Nothing -> (scoped, found)
                Just key -> case scoped of
                  (depth, seen) : rest
                    | key `Set.member` seen -> ((depth, seen) : rest, (lineNumber, key) : found)
                    | otherwise -> ((depth, Set.insert key seen) : rest, found)
                  [] -> ([(keyDepth, Set.singleton key)], found)
      where
        indentation = T.length (T.takeWhile (== ' ') raw)
        body = T.stripStart raw
    yamlKey content =
      let (key, suffix) = T.breakOn ":" content
          normalized = T.strip key
       in if T.null suffix || T.null normalized then Nothing else Just normalized

yamlBlocks :: Text -> [Text]
yamlBlocks = go . T.lines
  where
    go [] = []
    go (line : rest)
      | T.strip line == "```yaml" =
          let (body, suffix) = break ((== "```") . T.strip) rest
           in T.unlines body : go (drop 1 suffix)
      | otherwise = go rest

main :: IO ()
main = do
  markdown <- TIO.readFile "doc/model-routing-v2.md"
  let sources = yamlBlocks markdown
  expect "documented YAML examples contain no duplicate mapping keys" (all (null . duplicateYamlKeys) sources)
  expect
    "nested duplicate YAML keys are refused before Data.Yaml decoding"
    (not (null (duplicateYamlKeys "version: 2\npersonas:\n  personal:\n    profiles:\n      deep:\n        chain: one\n        chain: two\n")))
  blocks <- traverse decodeValue sources
  (legacyValue, userValue, projectValue, overrideValue) <- case blocks of
    [legacy, user, project, override] -> pure (legacy, user, project, override)
    _ -> die ("expected four YAML examples, found " <> T.pack (show (length blocks)))
  legacyVersion <- decodeAs "version-1 example" legacyValue :: IO (Map Text Value)
  expect "version-1 example remains exactly version 1" (Map.lookup "version" legacyVersion == Just (Number 1))

  user <- decodeAs "version-2 user example" userValue
  project <- decodeAs "version-2 project example" projectValue
  override <- decodeAs "version-2 project override" overrideValue
  either die pure (validateUser user)
  either die pure (validateProject user project)
  either die pure (validateProject user override)
  ok "all version-2 references, engine allowlists, and model allowlists validate"
  expect
    "persona precedence is CLI, environment, project, then user default"
    ( [ selectPersona user (Just "work") (Just "personal") (Just "agent-cat"),
        selectPersona user Nothing (Just "work") (Just "agent-cat"),
        selectPersona user Nothing Nothing (Just (projectPersona project)),
        selectPersona user Nothing Nothing Nothing
      ]
        == [Right "work", Right "work", Right "agent-cat", Right "personal"]
    )
  codexEngine <- maybe (die "codex-work engine is missing") pure (Map.lookup "codex-work" (userEngines user))
  codexCatalogue <- maybe (die "codex-work catalogue is missing") pure (engineCatalogue codexEngine)
  let checkCatalogue catalogue =
        validateEngine
          (userSecrets user)
          "codex-work"
          codexEngine {engineCatalogue = Just catalogue}
  expect
    "catalogue URL, authentication, user-info, fragment, and query restrictions hold"
    ( allLeft
        [ checkCatalogue codexCatalogue {catalogueUrl = "http://api.openai.com/v1/models"},
          checkCatalogue codexCatalogue {catalogueUrl = "https://user:password@api.openai.com/v1/models"},
          checkCatalogue codexCatalogue {catalogueUrl = "https://api.openai.com/v1/models#fragment"},
          checkCatalogue codexCatalogue {catalogueUrl = "https://api.openai.com/v1/models?api_key=literal"}
        ]
    )
  expect
    "sensitive literal environment, header, and profile options are refused"
    ( allLeft
        [ validateEngine
            (userSecrets user)
            "codex-work"
            codexEngine {engineEnvironment = Map.singleton "OPENAI_API_KEY" (EnvValue "literal-secret")},
          checkCatalogue codexCatalogue {catalogueHeaders = Map.singleton "authorization" "Bearer literal-secret"},
          validateProfile
            "agent-cat"
            ["glm-next-personal"]
            "bad-sensitive-option"
            (Profile [Rung "glm-next-personal" "high" (Number 1) (Map.singleton "api-key" (String "literal-secret"))]),
          validateProfile
            "agent-cat"
            ["glm-next-personal"]
            "bad-nonscalar-option"
            (Profile [Rung "glm-next-personal" "high" (Number 1) (Map.singleton "nested" (Object KeyMap.empty))])
        ]
    )
  expect
    "URL, query, header, timeout, body, and duration bounds are enforced"
    ( allLeft
        [ checkCatalogue codexCatalogue {catalogueUrl = "https://" <> T.replicate 8200 "a"},
          checkCatalogue codexCatalogue {catalogueUrl = "https://api.openai.com/v1/models?q=" <> T.replicate 4097 "x"},
          checkCatalogue codexCatalogue {catalogueUrl = "https://api.openai.com/v1/models?" <> T.intercalate "&" ["p" <> T.pack (show i) <> "=x" | i <- [1 .. 65 :: Int]]},
          checkCatalogue codexCatalogue {catalogueTimeoutMs = 60001},
          checkCatalogue codexCatalogue {catalogueMaxBytes = 4194305},
          checkCatalogue codexCatalogue {catalogueHeaders = Map.singleton "x-long" (T.replicate 8193 "x")},
          checkCatalogue codexCatalogue {catalogueHeaders = Map.fromList [("x-" <> T.pack (show i), "v") | i <- [1 .. 65 :: Int]]},
          checkCatalogue codexCatalogue {catalogueHeaders = Map.fromList [("x-" <> T.pack (show i), T.replicate 8000 "x") | i <- [1 .. 8 :: Int]]},
          checkCatalogue codexCatalogue {catalogueHeaders = Map.singleton "bad header" "value"},
          checkCatalogue codexCatalogue {catalogueCache = CachePolicy "forever" "7d"},
          checkCatalogue codexCatalogue {catalogueCache = CachePolicy "0h" "7d"},
          checkCatalogue codexCatalogue {catalogueCache = CachePolicy "366d" "366d"},
          checkCatalogue codexCatalogue {catalogueCache = CachePolicy "24h" "1h"}
        ]
    )
  let cachePolicy = CachePolicy "1h" "24h"
  expect
    "normal, offline, refresh, and cache-age decisions are explicit"
    ( [ cacheDecision NormalDiscovery cachePolicy (Just 60) False,
        cacheDecision NormalDiscovery cachePolicy (Just 7200) False,
        cacheDecision NormalDiscovery cachePolicy (Just 90000) False,
        cacheDecision NormalDiscovery cachePolicy Nothing True,
        cacheDecision OfflineDiscovery cachePolicy Nothing False,
        cacheDecision OfflineDiscovery cachePolicy (Just 7200) False,
        cacheDecision RefreshDiscovery cachePolicy (Just 60) False,
        cacheDecision RefreshDiscovery cachePolicy (Just 60) True
      ]
        == [ Right UseFreshCache,
             Right UseStaleCache,
             Right NoInventory,
             Right UseFetched,
             Right NoInventory,
             Right UseStaleCache,
             Left "explicit refresh failed",
             Right UseFetched
           ]
    )

  let freshInventories =
        Map.fromList
          [ ("claude-personal", (Fresh, [ModelEntry "claude-opus-5" (Just 5)])),
            ("codex-work", (Fresh, [ModelEntry "gpt-5.6-sol" (Just 6)])),
            ("omlx-hera", (Fresh, [ModelEntry "GLM-5.3-Next" (Just 3)]))
          ]
      expectedWork = [("openai-sol-work", "gpt-5.6-sol", "fresh")]
      expectedPersonal =
        [ ("anthropic-opus-personal", "claude-opus-5", "fresh"),
          ("glm-next-personal", "GLM-5.3-Next", "fresh")
        ]
      expectedProject =
        [ ("glm-next-personal", "GLM-5.3-Next", "fresh"),
          ("anthropic-opus-personal", "claude-opus-5", "fresh")
        ]
      work = resolveProfile user "work" Map.empty "deep-thinker" freshInventories
      personal = resolveProfile user "personal" Map.empty "deep-thinker" freshInventories
      projectResult = resolveProfile user (projectPersona override) (projectProfiles override) "deep-thinker" freshInventories
  expect "work deep-thinker resolves to Codex/gpt-5.6-sol" (work == Right expectedWork)
  expect "personal deep-thinker resolves to Claude then personal-only OMLX" (personal == Right expectedPersonal)
  expect "project low-cost override deterministically puts OMLX first" (projectResult == Right expectedProject)
  expect "work persona excludes the personal GLM model alias" $ case Map.lookup "work" (userPersonas user) of
    Just persona -> "glm-next-personal" `notElem` personaModels persona
    Nothing -> False
  case Map.lookup "work" (userPersonas user) of
    Nothing -> die "work persona is missing"
    Just persona ->
      expectLeft
        "project profile cannot widen the work model allowlist"
        (validateProfile "work" (personaModels persona) "deep-thinker" (Profile [Rung "glm-next-personal" "high" (Number 65536) Map.empty]))

  let noInventory = resolveProfile user "personal" Map.empty "deep-thinker" Map.empty
  expect "unavailable catalogues leave exact selectors static-unverified" $ case noInventory of
    Right ((_, "claude-opus-5", "static-unverified") : _) -> True
    _ -> False

  let staleInventory = Map.singleton "codex-work" (Stale, [ModelEntry "gpt-5.6-sol-20260801" (Just 1), ModelEntry "gpt-5.6-sol-20260901" (Just 2)])
      staleResolved = resolveProfile user "work" Map.empty "deep-thinker" staleInventory
  expect "stale cache selects the newest prefix deterministically" (staleResolved == Right [("openai-sol-work", "gpt-5.6-sol-20260901", "stale-cache")])
  expect "inventory order cannot change newest selection" (staleResolved == resolveProfile user "work" Map.empty "deep-thinker" (fmap (\(f, es) -> (f, reverse es)) staleInventory))

  let ambiguous = ModelDef "codex-work" [SelectPrefix "gpt-" Nothing]
      ambiguousInventory = Map.singleton "codex-work" (Fresh, [ModelEntry "gpt-a" (Just 1), ModelEntry "gpt-b" (Just 2)])
  expectLeft "ambiguous prefix without an order is refused" (resolveModel ambiguousInventory ambiguous)

  let completeEnvironment =
        Map.fromList
          [ ("ANTHROPIC_PERSONAL_API_KEY", "selected-anthropic"),
            ("OPENAI_WORK_API_KEY", "selected-openai"),
            ("OMLX_HERA_API_KEY", "selected-omlx")
          ]
  either die pure (checkSecrets user "work" Map.empty "deep-thinker" completeEnvironment)
  expectLeft "missing work credential is refused before discovery" (checkSecrets user "work" Map.empty "deep-thinker" (Map.delete "OPENAI_WORK_API_KEY" completeEnvironment))
  let ambient =
        Map.insert "PATH" "/usr/bin"
          . Map.insert "OPENAI_API_KEY" "ambient-wrong"
          . Map.insert "ANTHROPIC_API_KEY" "ambient-anthropic"
          . Map.insert "OPENAI_BASE_URL" "ambient-omlx"
          $ completeEnvironment
  selectedChild <- either die pure (childEnvironment user "codex-work" ambient)
  expect
    "selected child environment scrubs source and unselected engine secrets"
    ( Map.lookup "PATH" selectedChild == Just "/usr/bin"
        && Map.lookup "OPENAI_API_KEY" selectedChild == Just "selected-openai"
        && all (`Map.notMember` selectedChild) ["ANTHROPIC_PERSONAL_API_KEY", "OPENAI_WORK_API_KEY", "OMLX_HERA_API_KEY", "ANTHROPIC_API_KEY", "OPENAI_BASE_URL"]
        && all (`notElem` Map.elems selectedChild) ["selected-anthropic", "selected-omlx", "ambient-anthropic", "ambient-omlx"]
    )

  badProjectValue <- decodeValue "version: 2\npersona: agent-cat\nengines: {}\n"
  case parseEither parseJSON badProjectValue :: Either String ProjectDoc of
    Left _ -> ok "project engine authority is refused by the project schema"
    Right _ -> die "project engine authority was accepted"

  TIO.putStrLn "model routing v2 design: 4 YAML examples and 20 semantic outcomes verified"
