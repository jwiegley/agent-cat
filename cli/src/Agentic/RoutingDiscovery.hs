{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Bounded catalogue acquisition, private caching, and deterministic model
-- selector evaluation. This module is owned by CLI composition; engines never
-- parse routing files or call catalogue endpoints.
module Agentic.RoutingDiscovery
  ( ModelInventoryEntry (..),
    InventorySource (..),
    FrozenInventory (..),
    InventoryResult (..),
    DiscoveryMode (..),
    ModelSelectionSource (..),
    ResolvedModelSelection (..),
    discoverRoutingInventories,
    discoverRoutingInventoriesWithManager,
    engineCatalogueFingerprint,
    engineDefinitionFingerprint,
    sha256Fingerprint,
    cacheFileFor,
    resolveConcreteModel,
    validateFrozenInventory,
    inventorySourceName,
    modelSelectionSourceName,
  )
where

import Agentic.Route (backendSpelling)
import Agentic.RoutingConfig.V2
import Agentic.RoutingSecrets
  ( ResolvedEngineContext,
    resolvedEngineCatalogueCredential,
    withSecretValue,
  )
import Control.Exception (IOException, catch, onException, try)
import Control.Monad (unless, when)
import Crypto.Hash (Digest, SHA256, hash)
import Data.Aeson
  ( FromJSON (parseJSON),
    Object,
    ToJSON (toJSON),
    Value (..),
    eitherDecodeStrict',
    encode,
    object,
    withObject,
    (.:),
    (.:?),
    (.=),
  )
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import Data.Aeson.Types (Parser, parseEither)
import Data.Bits ((.&.))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.CaseInsensitive (mk)
import qualified Data.CaseInsensitive as CI
import Data.Char (GeneralCategory (Format), generalCategory, isAlphaNum, isAscii, isControl, isSpace)
import Data.Foldable (forM_)
import Data.List (nub, sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isJust)
import Data.Ord (Down (..))
import Data.Scientific (floatingOrInteger)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import Data.Time.Clock (UTCTime, diffUTCTime)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Network.HTTP.Client
  ( BodyReader,
    HttpException,
    Manager,
    Request (..),
    getUri,
    brRead,
    newManager,
    parseRequest,
    responseBody,
    responseStatus,
    responseTimeoutMicro,
    setQueryString,
    withResponse,
  )
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.HTTP.Types.Header (Header)
import Network.HTTP.Types.Status (statusCode)
import Network.HTTP.Types.URI (Query, parseQuery, renderQuery)
import Numeric (showHex)
import System.Directory
  ( createDirectory,
    createDirectoryIfMissing,
    doesFileExist,
    doesPathExist,
    removeFile,
    renameFile,
  )
import System.FilePath (takeDirectory, (</>))
import System.IO (hClose, hFlush, openBinaryTempFile)
import System.Posix.Files (fileMode, fileSize, getSymbolicLinkStatus, isDirectory, isRegularFile, isSymbolicLink, setFileMode)

data ModelInventoryEntry = ModelInventoryEntry
  { inventoryModelId :: !Text,
    inventoryModelCreatedAt :: !(Maybe UTCTime)
  }
  deriving (Eq, Show)

data InventorySource
  = InventoryFresh
  | InventoryFreshCache
  | InventoryStaleCache
  | InventoryOfflineCache
  deriving (Eq, Ord, Show)

data FrozenInventory = FrozenInventory
  { frozenInventorySource :: !InventorySource,
    frozenInventoryFingerprint :: !Text,
    frozenInventoryFetchedAt :: !UTCTime,
    frozenInventoryAgeSeconds :: !Integer,
    frozenInventoryEntries :: ![ModelInventoryEntry]
  }
  deriving (Eq, Show)

data InventoryResult = InventoryResult
  { inventoryResultFingerprint :: !(Maybe Text),
    inventoryResultInventory :: !(Maybe FrozenInventory),
    inventoryResultWarning :: !(Maybe Text)
  }
  deriving (Eq, Show)

data DiscoveryMode = DiscoveryNormal | DiscoveryOffline | DiscoveryRefresh
  deriving (Eq, Ord, Show)

data ModelSelectionSource
  = ModelStaticUnverified
  | ModelFromInventory !InventorySource
  deriving (Eq, Ord, Show)

data ResolvedModelSelection = ResolvedModelSelection
  { selectedModelAlias :: !Text,
    selectedModelEngine :: !Text,
    selectedModelId :: !Text,
    selectedModelSelectorIndex :: !Int,
    selectedModelSelector :: !ModelSelector,
    selectedModelSource :: !ModelSelectionSource,
    selectedModelFingerprint :: !(Maybe Text),
    selectedModelFetchedAt :: !(Maybe UTCTime),
    selectedModelCacheAgeSeconds :: !(Maybe Integer),
    selectedModelWarning :: !(Maybe Text)
  }
  deriving (Eq, Show)

-- | Fetch/cache each required engine exactly once. No manager is created in
-- offline mode, so that mode has no path to the network implementation.
discoverRoutingInventories :: DiscoveryMode -> FilePath -> UTCTime -> SelectedRoutingV2 -> Map Text ResolvedEngineContext -> [Text] -> IO (Either Text (Map Text InventoryResult))
discoverRoutingInventories mode cacheHome now selected contexts required = do
  manager <- case mode of
    DiscoveryOffline -> pure Nothing
    _ -> Just <$> newManager tlsManagerSettings
  discoverRoutingInventoriesWithManager manager mode cacheHome now selected contexts required

-- | Testable acquisition boundary. Production calls this only with the standard
-- TLS manager above; deterministic TLS fixtures supply a manager with a local CA.
discoverRoutingInventoriesWithManager :: Maybe Manager -> DiscoveryMode -> FilePath -> UTCTime -> SelectedRoutingV2 -> Map Text ResolvedEngineContext -> [Text] -> IO (Either Text (Map Text InventoryResult))
discoverRoutingInventoriesWithManager manager mode cacheHome now selected contexts required =
  go manager Map.empty (nub required)
  where
    config = selectedRoutingV2 selected
    personaName = selectedPersonaName selected

    go _ accumulated [] = pure (Right accumulated)
    go activeManager accumulated (alias : rest) = case Map.lookup alias (routingV2Engines config) of
      Nothing -> pure (Left ("persona '" <> personaName <> "' requires unknown engine '" <> alias <> "'"))
      Just engine -> case Map.lookup alias contexts of
        Nothing -> pure (Left ("persona '" <> personaName <> "', engine '" <> alias <> "' has no resolved environment context"))
        Just context -> do
          result <- acquireEngine config activeManager mode cacheHome now personaName alias engine context
          case result of
            Left problem -> pure (Left problem)
            Right inventory -> go activeManager (Map.insert alias inventory accumulated) rest

acquireEngine :: RoutingConfigV2 -> Maybe Manager -> DiscoveryMode -> FilePath -> UTCTime -> Text -> Text -> EngineDefinition -> ResolvedEngineContext -> IO (Either Text InventoryResult)
acquireEngine _ _ _ _ _ _ _ EngineDefinition {engineCatalogue = Nothing} _ =
  pure (Right (InventoryResult Nothing Nothing Nothing))
acquireEngine config manager mode cacheHome now personaName engineName engine context = do
  let catalogue = fromMaybe (error "catalogue checked above") (engineCatalogue engine)
      endpointFingerprint = engineCatalogueFingerprint engineName engine
      engineFingerprint = engineDefinitionFingerprint config engineName engine
      path = cacheFileFor cacheHome personaName engineFingerprint
  cached <- readCache path now personaName engineName engineFingerprint endpointFingerprint
  case mode of
    DiscoveryOffline ->
      pure . Right $ case usableStale catalogue cached of
        Just (record, age) -> inventoryFromCache InventoryOfflineCache endpointFingerprint record age (cacheWarning cached)
        Nothing -> InventoryResult (Just endpointFingerprint) Nothing (Just (fromMaybe "offline-cache-unavailable" (cacheWarning cached)))
    DiscoveryNormal -> case freshCache catalogue cached of
      Just (record, age) -> pure (Right (inventoryFromCache InventoryFreshCache endpointFingerprint record age (cacheWarning cached)))
      Nothing -> refresh False catalogue engineFingerprint endpointFingerprint path cached
    DiscoveryRefresh -> refresh True catalogue engineFingerprint endpointFingerprint path cached
  where
    refresh explicit catalogue engineFingerprint endpointFingerprint path cached = case manager of
      Nothing -> pure (Left "internal error: refresh has no HTTP manager")
      Just http -> do
        fetched <- fetchCatalogue http endpointFingerprint catalogue context
        case fetched of
          Right entries -> do
            let record = CacheRecord 1 personaName engineName engineFingerprint endpointFingerprint now (sortOn inventoryModelId entries)
            cacheWrite <- writeCache path record
            let warning = joinWarnings [cacheWarning cached, either Just (const Nothing) cacheWrite]
                frozen = FrozenInventory InventoryFresh endpointFingerprint now 0 (cacheModels record)
            pure (Right (InventoryResult (Just endpointFingerprint) (Just frozen) warning))
          Left failure
            | explicit ->
                pure
                  ( Left
                      ( "persona '"
                          <> personaName
                          <> "', engine '"
                          <> engineName
                          <> "', endpoint "
                          <> endpointFingerprint
                          <> " discovery failed: "
                          <> failure
                      )
                  )
            | Just (record, age) <- usableStale catalogue cached ->
                pure (Right (inventoryFromCache InventoryStaleCache endpointFingerprint record age (Just failure)))
            | otherwise ->
                pure (Right (InventoryResult (Just endpointFingerprint) Nothing (Just failure)))

data CacheRecord = CacheRecord
  { cacheVersion :: !Int,
    cachePersona :: !Text,
    cacheEngine :: !Text,
    cacheEngineFingerprint :: !Text,
    cacheEndpointFingerprint :: !Text,
    cacheFetchedAt :: !UTCTime,
    cacheModels :: ![ModelInventoryEntry]
  }

instance ToJSON CacheRecord where
  toJSON CacheRecord {..} =
    object
      [ "version" .= cacheVersion,
        "persona" .= cachePersona,
        "engine" .= cacheEngine,
        "engineFingerprint" .= cacheEngineFingerprint,
        "endpointFingerprint" .= cacheEndpointFingerprint,
        "fetchedAt" .= cacheFetchedAt,
        "models" .= cacheModels
      ]

instance FromJSON CacheRecord where
  parseJSON = withObject "model inventory cache" $ \o -> do
    onlyKeys "model inventory cache" ["version", "persona", "engine", "engineFingerprint", "endpointFingerprint", "fetchedAt", "models"] o
    CacheRecord <$> o .: "version" <*> o .: "persona" <*> o .: "engine" <*> o .: "engineFingerprint" <*> o .: "endpointFingerprint" <*> o .: "fetchedAt" <*> o .: "models"

instance ToJSON ModelInventoryEntry where
  toJSON ModelInventoryEntry {..} = object ["id" .= inventoryModelId, "createdAt" .= inventoryModelCreatedAt]

instance FromJSON ModelInventoryEntry where
  parseJSON = withObject "cached model" $ \o -> do
    onlyKeys "cached model" ["id", "createdAt"] o
    ModelInventoryEntry <$> o .: "id" <*> o .:? "createdAt"

maxCacheRecordBytes :: Integer
maxCacheRecordBytes = 8 * 1024 * 1024

data CacheRead
  = CacheMissing
  | CacheBroken !Text
  | CacheFound !CacheRecord !Integer

readCache :: FilePath -> UTCTime -> Text -> Text -> Text -> Text -> IO CacheRead
readCache path now personaName engineName engineFingerprint endpointFingerprint = do
  parentsSafe <- cacheParentsSafe path
  if not parentsSafe
    then pure (CacheBroken "cache-directory-unsafe")
    else do
      exists <- doesFileExist path
      if not exists
        then pure CacheMissing
        else do
          statusResult <- try (getSymbolicLinkStatus path)
          case statusResult of
            Left (_ :: IOException) -> pure (CacheBroken "cache-read-failed")
            Right status
              | isSymbolicLink status -> pure (CacheBroken "cache-is-symbolic-link")
              | not (isRegularFile status) -> pure (CacheBroken "cache-is-not-a-regular-file")
              | toInteger (fileSize status) > maxCacheRecordBytes -> pure (CacheBroken "cache-too-large")
              | fileMode status .&. 0o077 /= 0 -> pure (CacheBroken "cache-permissions-are-not-private")
              | otherwise -> do
                  bytesResult <- try (BS.readFile path)
                  pure $ case bytesResult of
                    Left (_ :: IOException) -> CacheBroken "cache-read-failed"
                    Right bytes -> case eitherDecodeStrict' bytes of
                      Left _ -> CacheBroken "cache-corrupt"
                      Right record -> validateRecord record
  where
    validateRecord record
      | cacheVersion record /= 1 = CacheBroken "cache-version-unsupported"
      | cachePersona record /= personaName = CacheBroken "cache-persona-mismatch"
      | cacheEngine record /= engineName = CacheBroken "cache-engine-mismatch"
      | cacheEngineFingerprint record /= engineFingerprint = CacheBroken "cache-engine-fingerprint-mismatch"
      | cacheEndpointFingerprint record /= endpointFingerprint = CacheBroken "cache-endpoint-fingerprint-mismatch"
      | age < 0 = CacheBroken "cache-timestamp-is-in-the-future"
      | Left _ <- validateEntries (cacheModels record) = CacheBroken "cache-models-invalid"
      | otherwise = CacheFound record age
      where
        age = floor (diffUTCTime now (cacheFetchedAt record))

cacheParentsSafe :: FilePath -> IO Bool
cacheParentsSafe path = do
  checked <- try (and <$> traverse safe managed) :: IO (Either IOException Bool)
  pure (either (const False) id checked)
  where
    personaDirectory = takeDirectory path
    modelDirectory = takeDirectory personaDirectory
    agentCatDirectory = takeDirectory modelDirectory
    managed = [agentCatDirectory, modelDirectory, personaDirectory]
    safe directory = do
      exists <- doesPathExist directory
      if not exists
        then pure True
        else do
          status <- getSymbolicLinkStatus directory
          pure (not (isSymbolicLink status) && isDirectory status && fileMode status .&. 0o077 == 0)

writeCache :: FilePath -> CacheRecord -> IO (Either Text ())
writeCache path record = do
  result <- try write :: IO (Either IOException ())
  pure (either (const (Left "cache-write-failed")) Right result)
  where
    directory = takeDirectory path
    modelDirectory = takeDirectory directory
    agentCatDirectory = takeDirectory modelDirectory
    cacheHomeDirectory = takeDirectory agentCatDirectory

    write = do
      createDirectoryIfMissing True cacheHomeDirectory
      forM_ [agentCatDirectory, modelDirectory, directory] ensureManagedDirectory
      (temporary, handle) <- openBinaryTempFile directory ".inventory.tmp"
      let cleanup = do
            hClose handle `catch` \(_ :: IOException) -> pure ()
            present <- doesFileExist temporary
            when present (removeFile temporary `catch` \(_ :: IOException) -> pure ())
          install = do
            setFileMode temporary 0o600
            BS.hPut handle (BL.toStrict (encode record))
            hFlush handle
            hClose handle
            renameFile temporary path
            setFileMode path 0o600
      install `onException` cleanup

    ensureManagedDirectory managed = do
      exists <- doesPathExist managed
      if exists
        then do
          status <- getSymbolicLinkStatus managed
          when (isSymbolicLink status || not (isDirectory status)) $
            ioError (userError "unsafe routing cache directory")
        else createDirectory managed
      setFileMode managed 0o700

freshCache :: Catalogue -> CacheRead -> Maybe (CacheRecord, Integer)
freshCache catalogue (CacheFound record age)
  | age < cacheFreshSeconds (catalogueCache catalogue) = Just (record, age)
freshCache _ _ = Nothing

usableStale :: Catalogue -> CacheRead -> Maybe (CacheRecord, Integer)
usableStale catalogue (CacheFound record age)
  | age <= cacheStaleIfErrorSeconds (catalogueCache catalogue) = Just (record, age)
usableStale _ _ = Nothing

cacheWarning :: CacheRead -> Maybe Text
cacheWarning (CacheBroken warning) = Just warning
cacheWarning _ = Nothing

inventoryFromCache :: InventorySource -> Text -> CacheRecord -> Integer -> Maybe Text -> InventoryResult
inventoryFromCache source fingerprint record age warning =
  InventoryResult
    (Just fingerprint)
    (Just (FrozenInventory source fingerprint (cacheFetchedAt record) age (cacheModels record)))
    warning

joinWarnings :: [Maybe Text] -> Maybe Text
joinWarnings warnings = case [warning | Just warning <- warnings] of
  [] -> Nothing
  values -> Just (T.intercalate ";" (nub values))

engineDefinitionFingerprint :: RoutingConfigV2 -> Text -> EngineDefinition -> Text
engineDefinitionFingerprint config engineName engine = sha256Fingerprint (encodeUtf8 payload)
  where
    payload =
      T.intercalate
        "\NUL"
        ( [ engineName,
            backendSpelling (engineBackend engine),
            engineProvider engine
          ]
            <> concatMap environmentPart (Map.toAscList (engineEnvironment engine))
            <> maybe [] cataloguePart (engineCatalogue engine)
        )
    environmentPart (destination, EnvironmentValue value) = [destination, "value", value]
    environmentPart (destination, EnvironmentSecret secretName) =
      [ destination,
        "secret",
        secretName,
        maybe "<unknown>" secretEnvironmentName (Map.lookup secretName (routingV2Secrets config))
      ]
    cataloguePart catalogue =
      [ engineCatalogueFingerprint engineName engine,
        T.pack (show (catalogueTimeoutMs catalogue)),
        T.pack (show (catalogueMaxBytes catalogue)),
        T.pack (show (cacheFreshSeconds (catalogueCache catalogue))),
        T.pack (show (cacheStaleIfErrorSeconds (catalogueCache catalogue)))
      ]

engineCatalogueFingerprint :: Text -> EngineDefinition -> Text
engineCatalogueFingerprint engineName engine = sha256Fingerprint (encodeUtf8 payload)
  where
    payload =
      T.intercalate
        "\NUL"
        ( [ engineName,
            backendSpelling (engineBackend engine),
            engineProvider engine
          ]
            <> maybe [] catalogueParts (engineCatalogue engine)
        )
    catalogueParts catalogue =
      [ dialectName (catalogueDialect catalogue),
        catalogueUrl catalogue,
        maybe "" authText (catalogueAuth catalogue)
      ]
        <> [T.toLower name <> ":" <> value | (name, value) <- Map.toAscList (catalogueHeaders catalogue)]
    authText auth =
      T.intercalate
        ":"
        [ T.toLower (catalogueAuthHeader auth),
          authSchemeName (catalogueAuthScheme auth),
          catalogueAuthSecret auth
        ]

cacheFileFor :: FilePath -> Text -> Text -> FilePath
cacheFileFor cacheHome personaName fingerprint =
  cacheHome
    </> "agent-cat"
    </> "models"
    </> safeComponent personaName
    </> T.unpack (fromMaybe fingerprint (T.stripPrefix "sha256:" fingerprint)) <> ".json"

safeComponent :: Text -> FilePath
safeComponent value
  | rendered == "." || rendered == ".." = '_' : rendered
  | otherwise = rendered
  where
    rendered = concatMap encodeCharacter (T.unpack value)
    encodeCharacter character
      | isAscii character && (isAlphaNum character || character `elem` ("._-" :: String)) = [character]
      | otherwise = '_' : showHex (fromEnum character) ""

sha256Fingerprint :: BS.ByteString -> Text
sha256Fingerprint value =
  "sha256:" <> T.pack (show (hash value :: Digest SHA256))

dialectName :: CatalogueDialect -> Text
dialectName CatalogueOpenAI = "openai"
dialectName CatalogueAnthropic = "anthropic"

authSchemeName :: CatalogueAuthScheme -> Text
authSchemeName CatalogueAuthRaw = "raw"
authSchemeName CatalogueAuthBearer = "bearer"

fetchCatalogue :: Manager -> Text -> Catalogue -> ResolvedEngineContext -> IO (Either Text [ModelInventoryEntry])
fetchCatalogue manager fingerprint catalogue context = case catalogueDialect catalogue of
  CatalogueOpenAI -> do
    body <- fetchPage manager fingerprint catalogue context Nothing 1
    pure (body >>= decodeOpenAI)
  CatalogueAnthropic -> fetchAnthropic manager fingerprint catalogue context

fetchAnthropic :: Manager -> Text -> Catalogue -> ResolvedEngineContext -> IO (Either Text [ModelInventoryEntry])
fetchAnthropic manager fingerprint catalogue context = go 1 Nothing Set.empty []
  where
    go page cursor seen accumulated
      | page > maxCataloguePages = pure (Left "page-limit-exceeded")
      | otherwise = do
          body <- fetchPage manager fingerprint catalogue context cursor page
          case body >>= decodeAnthropicPage of
            Left problem -> pure (Left problem)
            Right response -> do
              let entries = anthropicEntries response
                  identifiers = map inventoryModelId entries
                  combined = accumulated <> entries
                  stalled =
                    anthropicHasMore response
                      && maybe False (\next -> Just next == cursor || next `Set.member` seen) (anthropicLastId response)
              if stalled
                then pure (Left "pagination-did-not-advance")
                else
                  if length combined > maxCatalogueModels
                    then pure (Left "model-limit-exceeded")
                    else case firstDuplicate (Set.toList seen <> identifiers) of
                      Just _ -> pure (Left "duplicate-model-id")
                      Nothing ->
                        if not (anthropicHasMore response)
                          then pure (validateEntries combined >> Right combined)
                          else case anthropicLastId response of
                            Nothing -> pure (Left "pagination-missing-last-id")
                            Just next
                              | null entries -> pure (Left "pagination-empty-page")
                              | otherwise -> go (page + 1) (Just next) (Set.union seen (Set.fromList identifiers)) combined

fetchPage :: Manager -> Text -> Catalogue -> ResolvedEngineContext -> Maybe Text -> Int -> IO (Either Text BS.ByteString)
fetchPage manager fingerprint catalogue context cursor page = do
  attempted <- try requestAndRead :: IO (Either HttpException (Either Text BS.ByteString))
  pure (either (const (Left "network-error")) id attempted)
  where
    requestAndRead = do
      base <- parseRequest (T.unpack (catalogueUrl catalogue))
      let query = parseQuery (queryString base)
          withoutPagination = filter (\(name, _) -> name /= "after_id" && name /= "limit") query
          pagedQuery = case catalogueDialect catalogue of
            CatalogueAnthropic -> withoutPagination <> [("limit", Just "1000")] <> maybe [] (\value -> [("after_id", Just (encodeUtf8 value))]) cursor
            CatalogueOpenAI -> query
          literalHeaders = [(mk (encodeUtf8 name), encodeUtf8 value) | (name, value) <- Map.toAscList (catalogueHeaders catalogue)]
          authHeaders = case (catalogueAuth catalogue, resolvedEngineCatalogueCredential context) of
            (Nothing, _) -> []
            (Just auth, Just credential) ->
              withSecretValue credential $ \secret ->
                let value = case catalogueAuthScheme auth of
                      CatalogueAuthRaw -> secret
                      CatalogueAuthBearer -> "Bearer " <> secret
                 in [(mk (encodeUtf8 (catalogueAuthHeader auth)), encodeUtf8 value)]
            (Just _, Nothing) -> []
          requestIdConfigured =
            any ((== "x-request-id") . T.toLower) (Map.keys (catalogueHeaders catalogue))
              || maybe False ((== "x-request-id") . T.toLower . catalogueAuthHeader) (catalogueAuth catalogue)
          requestIdHeader =
            if requestIdConfigured
              then []
              else [("x-request-id", encodeUtf8 ("agent-cat-" <> T.take 16 fingerprint <> "-" <> T.pack (show page)))]
          request =
            setQueryString pagedQuery
              base
                { method = "GET",
                  requestHeaders = literalHeaders <> authHeaders <> requestIdHeader,
                  redirectCount = 0,
                  responseTimeout = responseTimeoutMicro (catalogueTimeoutMs catalogue * 1000),
                  checkResponse = \_ _ -> pure ()
                }
      case validateOutboundRequest request pagedQuery of
        Left problem -> pure (Left problem)
        Right ()
          | isJust (catalogueAuth catalogue) && null authHeaders -> pure (Left "resolved-credential-unavailable")
          | otherwise ->
              withResponse request manager $ \response -> do
                let code = statusCode (responseStatus response)
                if code >= 300 && code < 400
                  then pure (Left "redirect-refused")
                  else
                    if code /= 200
                      then pure (Left ("http-status-" <> T.pack (show code)))
                      else readBounded (catalogueMaxBytes catalogue) (responseBody response)

validateOutboundRequest :: Request -> Query -> Either Text ()
validateOutboundRequest request query = do
  when (length query > maxCatalogueQueryItems) (Left "request-query-item-limit")
  when (BS.length (renderQuery False query) > maxCatalogueQueryBytes) (Left "request-query-byte-limit")
  when (BS.length (encodeUtf8 (T.pack (show (getUri request)))) > maxCatalogueUrlBytes) (Left "request-url-limit")
  validateOutboundHeaders (requestHeaders request)

validateOutboundHeaders :: [Header] -> Either Text ()
validateOutboundHeaders headers = do
  when (length headers > maxCatalogueHeaders) (Left "request-header-count-limit")
  forM_ headers $ \(_, value) ->
    when (BS.length value > maxCatalogueHeaderValueBytes || BS.any (\byte -> byte < 32 || byte == 127) value) $
      Left "request-header-value-limit"
  let total = sum [BS.length (CI.original name) + BS.length value | (name, value) <- headers]
  when (total > maxCatalogueHeaderBytes) (Left "request-header-byte-limit")

readBounded :: Int -> BodyReader -> IO (Either Text BS.ByteString)
readBounded limit = go 0 []
  where
    go total chunks reader = do
      chunk <- brRead reader
      if BS.null chunk
        then pure (Right (BS.concat (reverse chunks)))
        else
          let total' = total + BS.length chunk
           in if total' > limit
                then pure (Left "response-too-large")
                else go total' (chunk : chunks) reader

decodeOpenAI :: BS.ByteString -> Either Text [ModelInventoryEntry]
decodeOpenAI bytes = do
  entries <- decodeJson "openai-response-malformed" parseOpenAI bytes
  validateEntries entries
  pure entries
  where
    parseOpenAI = withObject "OpenAI model list" $ \o -> do
      objectType <- o .: "object"
      unless ((objectType :: Text) == "list") (fail "object is not list")
      values <- o .: "data"
      when (length values > maxCatalogueModels) (fail "model limit exceeded")
      traverse parseOpenAIEntry values

parseOpenAIEntry :: Value -> Parser ModelInventoryEntry
parseOpenAIEntry = withObject "OpenAI model" $ \o -> do
  identifier <- o .: "id"
  created <- o .:? "created"
  timestamp <- traverse parseEpoch created
  pure (ModelInventoryEntry identifier timestamp)
  where
    parseEpoch scientific = case (floatingOrInteger scientific :: Either Double Integer) of
      Right integer | integer >= (0 :: Integer) -> pure (posixSecondsToUTCTime (fromInteger integer))
      _ -> fail "created is not a non-negative integer"

data AnthropicPage = AnthropicPage
  { anthropicEntries :: ![ModelInventoryEntry],
    anthropicHasMore :: !Bool,
    anthropicLastId :: !(Maybe Text)
  }

decodeAnthropicPage :: BS.ByteString -> Either Text AnthropicPage
decodeAnthropicPage = decodeJson "anthropic-response-malformed" $ withObject "Anthropic model list" $ \o -> do
  values <- o .: "data"
  when (length values > maxCatalogueModels) (fail "model limit exceeded")
  entries <- traverse parseAnthropicEntry values
  hasMore <- o .: "has_more"
  firstId <- o .:? "first_id"
  lastId <- o .:? "last_id"
  case entries of
    [] -> do
      when (firstId /= Nothing || lastId /= Nothing) (fail "empty page carries first_id or last_id")
    firstEntry : rest -> do
      let lastEntry = foldl (\_ entry -> entry) firstEntry rest
      firstIdentifier <- maybe (fail "nonempty page has no first_id") pure firstId
      lastIdentifier <- maybe (fail "nonempty page has no last_id") pure lastId
      unless (firstIdentifier == inventoryModelId firstEntry) (fail "first_id mismatch")
      unless (lastIdentifier == inventoryModelId lastEntry) (fail "last_id mismatch")
  when (hasMore && lastId == Nothing) (fail "paginated response has no last_id")
  pure (AnthropicPage entries hasMore lastId)

parseAnthropicEntry :: Value -> Parser ModelInventoryEntry
parseAnthropicEntry = withObject "Anthropic model" $ \o -> do
  identifier <- o .: "id"
  createdText <- o .:? "created_at"
  created <- traverse (parseJSON . String) createdText
  pure (ModelInventoryEntry identifier created)

decodeJson :: Text -> (Value -> Parser a) -> BS.ByteString -> Either Text a
decodeJson label parser bytes = do
  value <- either (const (Left label)) Right (eitherDecodeStrict' bytes :: Either String Value)
  either (const (Left label)) Right (parseEither parser value)

validateFrozenInventory :: FrozenInventory -> Either Text ()
validateFrozenInventory inventory = do
  when (frozenInventoryAgeSeconds inventory < 0) (Left "model inventory has a negative cache age")
  validateEntries (frozenInventoryEntries inventory)

validateEntries :: [ModelInventoryEntry] -> Either Text ()
validateEntries entries = do
  when (length entries > maxCatalogueModels) (Left "model inventory exceeds 10000 entries")
  identifiers <- traverse validateIdentifier entries
  case firstDuplicate identifiers of
    Just _ -> Left "duplicate-model-id"
    Nothing -> pure ()

validateIdentifier :: ModelInventoryEntry -> Either Text Text
validateIdentifier entry = do
  let identifier = inventoryModelId entry
  when (T.null identifier || identifier /= T.strip identifier) (Left "model inventory contains an empty id or surrounding whitespace")
  when (BS.length (encodeUtf8 identifier) > maxModelIdBytes) (Left "model inventory id exceeds 512 UTF-8 bytes")
  when (T.any (\c -> isSpace c || isControl c || generalCategory c == Format) identifier) (Left "model inventory id contains whitespace or controls")
  pure identifier

resolveConcreteModel :: Text -> ConcreteModel -> InventoryResult -> Either Text ResolvedModelSelection
resolveConcreteModel alias definition result = do
  traverse_ validateFrozenInventory inventory
  go 1 (concreteModelSelectors definition)
  where
    inventory = inventoryResultInventory result
    go _ [] =
      Left
        ( "concrete model alias '"
            <> alias
            <> "' has no selector satisfied by engine '"
            <> concreteModelEngine definition
            <> "'"
        )
    go index (selector : rest) = case selector of
      ModelExact wanted -> case inventory of
        Nothing -> pure (selected index selector wanted ModelStaticUnverified Nothing)
        Just available
          | any ((== wanted) . inventoryModelId) (frozenInventoryEntries available) ->
              pure (selected index selector wanted (ModelFromInventory (frozenInventorySource available)) (Just available))
          | otherwise -> go (index + 1) rest
      ModelPrefix prefix ordering -> case inventory of
        Nothing -> go (index + 1) rest
        Just available ->
          let matches = filter (T.isPrefixOf prefix . inventoryModelId) (frozenInventoryEntries available)
           in case matches of
                [] -> go (index + 1) rest
                [entry] -> pure (selected index selector (inventoryModelId entry) (ModelFromInventory (frozenInventorySource available)) (Just available))
                _ -> do
                  chosen <- choosePrefix alias prefix ordering matches
                  pure (selected index selector (inventoryModelId chosen) (ModelFromInventory (frozenInventorySource available)) (Just available))

    selected index selector modelId source evidence =
      ResolvedModelSelection
        { selectedModelAlias = alias,
          selectedModelEngine = concreteModelEngine definition,
          selectedModelId = modelId,
          selectedModelSelectorIndex = index,
          selectedModelSelector = selector,
          selectedModelSource = source,
          selectedModelFingerprint = case evidence of
            Just value -> Just (frozenInventoryFingerprint value)
            Nothing -> inventoryResultFingerprint result,
          selectedModelFetchedAt = frozenInventoryFetchedAt <$> evidence,
          selectedModelCacheAgeSeconds = frozenInventoryAgeSeconds <$> evidence,
          selectedModelWarning = inventoryResultWarning result
        }

choosePrefix :: Text -> Text -> Maybe ModelOrder -> [ModelInventoryEntry] -> Either Text ModelInventoryEntry
choosePrefix alias prefix ordering matches = case ordering of
  Nothing -> Left ("concrete model alias '" <> alias <> "' has ambiguous prefix '" <> prefix <> "'; add order")
  Just ModelNewest -> do
    unless (all (isJust . inventoryModelCreatedAt) matches) $
      Left ("concrete model alias '" <> alias <> "' newest selector for prefix '" <> prefix <> "' lacks a creation timestamp")
    case sortOn (\entry -> (Down (inventoryModelCreatedAt entry), inventoryModelId entry)) matches of
      chosen : _ -> Right chosen
      [] -> Left "internal error: empty prefix match set"
  Just ModelIdDescending -> case sortOn (Down . inventoryModelId) matches of
    chosen : _ -> Right chosen
    [] -> Left "internal error: empty prefix match set"

firstDuplicate :: (Ord a) => [a] -> Maybe a
firstDuplicate = go Set.empty
  where
    go _ [] = Nothing
    go seen (value : rest)
      | value `Set.member` seen = Just value
      | otherwise = go (Set.insert value seen) rest

inventorySourceName :: InventorySource -> Text
inventorySourceName InventoryFresh = "fresh"
inventorySourceName InventoryFreshCache = "fresh-cache"
inventorySourceName InventoryStaleCache = "stale-cache"
inventorySourceName InventoryOfflineCache = "offline-cache"

modelSelectionSourceName :: ModelSelectionSource -> Text
modelSelectionSourceName ModelStaticUnverified = "static-unverified"
modelSelectionSourceName (ModelFromInventory source) = inventorySourceName source

onlyKeys :: String -> [Text] -> Object -> Parser ()
onlyKeys label allowed value =
  case filter (`notElem` allowed) (map Key.toText (KeyMap.keys value)) of
    [] -> pure ()
    unknown -> fail (label <> " has unknown field(s): " <> T.unpack (T.intercalate ", " unknown))

traverse_ :: (a -> Either Text ()) -> Maybe a -> Either Text ()
traverse_ _ Nothing = Right ()
traverse_ action (Just value) = action value
