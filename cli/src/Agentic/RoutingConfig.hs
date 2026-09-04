{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Agentic.RoutingConfig
-- Description : Layered YAML realization policy for symbolic model profiles.
--
-- A workflow names a capability, such as @deep-thinker@.  This module keeps the
-- concrete realization outside the workflow: a profile is an ordered chain of
-- router, provider, model and generation settings.  Routers are reusable so a
-- file with many profiles does not repeat adapter or session locators.
--
-- The version-1 surface is deliberately small:
--
-- > version: 1
-- > routers:
-- >   - name: anthropic-acp
-- >     backend: acp:claude
-- >     provider: anthropic
-- > profiles:
-- >   - name: deep-thinker
-- >     chain:
-- >       - router: anthropic-acp
-- >         model: claude-fable-5
-- >         thinking: max
-- >         max-output: 65536
--
-- @model@, @thinking@ and @max-output@ are required policy. @max-output@ is
-- either a positive integer constraint or the explicit word @unconstrained@ for
-- backends that expose no output-limit control. Every declared setting must be
-- applied or verified before a question. @options@ carries additional non-secret
-- backend constraints.
module Agentic.RoutingConfig
  ( Thinking (..),
    thinkingName,
    Router (..),
    Realization (..),
    Profile (..),
    RoutingConfig (..),
    LoadedRouting (..),
    ResolvedRealization (..),
    ResolvedRouting (..),
    emptyRoutingConfig,
    decodeRoutingConfig,
    mergeRoutingConfig,
    routesWithProfiles,
    resolveRoutingConfig,
    expandRoutingConfigV2,
    freezeRoutingConfigV2,
    resolveRoutingConfigV2,
    discoverRoutingFiles,
    loadRoutingFiles,
    loadRoutingConfig,
  )
where

import Agentic.Engine (Thinking (..), thinkingName)
import Agentic.RoutingDiscovery
import Agentic.RoutingConfig.V2
import Agentic.Route
  ( Backend,
    Routes,
    parseBackend,
    routeDefault,
    routeNamed,
    routes,
  )
import Control.Exception (IOException, try)
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
import qualified Data.ByteString as BS
import Data.Char (isAlphaNum)
import Data.List (find, nub)
import Data.List.NonEmpty (NonEmpty (..))
import qualified Data.List.NonEmpty as NE
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes, fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Yaml as Yaml
import System.Directory
  ( doesFileExist,
    doesPathExist,
    getCurrentDirectory,
    getHomeDirectory,
  )
import System.Environment (lookupEnv)
import System.FilePath ((</>), takeDirectory)

-- | A reusable physical route.  The provider is declared here because it is a
-- property of the adapter or session, not of every profile that uses it.
data Router = Router
  { routerName :: !Text,
    routerBackend :: !Backend,
    routerProvider :: !Text
  }
  deriving (Eq, Show)

-- | One rung of a symbolic profile's ordered realization chain.
data Realization = Realization
  { realizationRouter :: !Text,
    realizationModel :: !Text,
    realizationThinking :: !Thinking,
    realizationMaxOutput :: !(Maybe Integer),
    realizationOptions :: !(Map Text Value)
  }
  deriving (Eq, Show)

-- | One symbolic capability named by Haskell workflow source.
data Profile = Profile
  { profileName :: !Text,
    profileChain :: !(NonEmpty Realization)
  }
  deriving (Eq, Show)

-- | One validated routing layer.  Maps make replacement and lookup exact;
-- duplicate declarations are rejected before these maps are built.
data RoutingConfig = RoutingConfig
  { routingRouters :: !(Map Text Router),
    routingProfiles :: !(Map Text Profile)
  }
  deriving (Eq, Show)

-- | Trust assigned by path discovery, before document contents are decoded.
-- Version 2 uses this tag to prevent a project document from being interpreted
-- as privileged user configuration.
data RoutingLayerRole = UserRoutingLayer | ProjectRoutingLayer
  deriving (Eq, Show)

-- | The merged configuration together with the files that contributed to it,
-- in increasing precedence order.
data LoadedRouting = LoadedRouting
  { loadedRouting :: !RoutingConfig,
    loadedRoutingSources :: ![FilePath],
    loadedRoutingV2User :: !(Maybe RoutingConfigV2),
    loadedRoutingV2Project :: !(Maybe ProjectRoutingV2)
  }
  deriving (Eq, Show)

-- | One concrete rung after router references and command-line overrides have
-- been resolved.  The axis is the runtime key: the profile name for its first
-- rung and a reserved @#N@ suffix for later rungs.
data ResolvedRealization = ResolvedRealization
  { resolvedProfile :: !Text,
    resolvedAxis :: !Text,
    resolvedRung :: !Int,
    resolvedRouter :: !Router,
    resolvedBackend :: !Backend,
    resolvedSpec :: !Realization,
    resolvedEngineFingerprint :: !(Maybe Text),
    resolvedModelSelection :: !(Maybe ResolvedModelSelection)
  }
  deriving (Eq, Show)

-- | The execution-only tables produced for one program.
data ResolvedRouting = ResolvedRouting
  { resolvedRoutes :: !(Routes Backend),
    resolvedChains :: !(Map Text [Text]),
    resolvedRealizations :: !(Map Text ResolvedRealization),
    resolvedRoutingPersona :: !(Maybe Text),
    resolvedRoutingPersonaSource :: !(Maybe PersonaSelectionSource)
  }

emptyRoutingConfig :: RoutingConfig
emptyRoutingConfig = RoutingConfig Map.empty Map.empty

-- The list representation is intentional: unlike an object decoder, it can
-- reject duplicate names instead of silently retaining one value.
newtype RoutingVersionFile = RoutingVersionFile Int

instance FromJSON RoutingVersionFile where
  parseJSON = withObject "routing document" $ \o -> RoutingVersionFile <$> o .: "version"

data RoutingFile = RoutingFile [Router] [Profile]

instance FromJSON RoutingFile where
  parseJSON = withObject "routing configuration" $ \o -> do
    onlyKeys "routing configuration" ["version", "routers", "profiles"] o
    version <- o .: "version"
    unless (version == (1 :: Int)) (fail ("unsupported routing configuration version " <> show version))
    routers <- fromMaybe [] <$> o .:? "routers"
    profiles <- fromMaybe [] <$> o .:? "profiles"
    rejectDuplicate "router" (map routerName routers)
    rejectDuplicate "profile" (map profileName profiles)
    pure (RoutingFile routers profiles)

instance FromJSON Router where
  parseJSON = withObject "router" $ \o -> do
    onlyKeys "router" ["name", "backend", "provider"] o
    name <- nonBlank "router name" =<< o .: "name"
    backendText <- nonBlank "router backend" =<< o .: "backend"
    backend <- either (fail . T.unpack) pure (parseBackend backendText)
    provider <- nonBlank "router provider" =<< o .: "provider"
    pure (Router name backend provider)

instance FromJSON Profile where
  parseJSON = withObject "profile" $ \o -> do
    onlyKeys "profile" ["name", "chain"] o
    name <- profileNameValue =<< o .: "name"
    chain <- o .: "chain"
    case chain of
      [] -> fail ("profile '" <> T.unpack name <> "' has an empty chain")
      first : rest -> pure (Profile name (first :| rest))

instance FromJSON Realization where
  parseJSON = withObject "profile realization" $ \o -> do
    onlyKeys "profile realization" ["router", "model", "thinking", "max-output", "options"] o
    router <- nonBlank "realization router" =<< o .: "router"
    model <- nonBlank "realization model" =<< o .: "model"
    thinking <- o .: "thinking"
    maxOutputValue <- o .: "max-output"
    maxOutput <- case maxOutputValue of
      String "unconstrained" -> pure Nothing
      value -> Just <$> parseJSON value
    when (maybe False (<= 0) maxOutput) (fail "max-output must be a positive integer or 'unconstrained'")
    options <- fromMaybe Map.empty <$> o .:? "options"
    case find (sensitive . fst) (Map.toList options) of
      Just (key, _) -> fail ("backend option '" <> T.unpack key <> "' may carry a secret and is not allowed")
      Nothing -> pure ()
    case find (not . scalarOption . snd) (Map.toList options) of
      Just (key, _) -> fail ("backend option '" <> T.unpack key <> "' must be a string, number, or boolean")
      Nothing -> pure ()
    pure (Realization router model thinking maxOutput options)

scalarOption :: Value -> Bool
scalarOption = \case
  String _ -> True
  Number _ -> True
  Bool _ -> True
  _ -> False
onlyKeys :: String -> [Text] -> Object -> Yaml.Parser ()
onlyKeys label allowed object =
  case filter (`notElem` allowed) (map Key.toText (KeyMap.keys object)) of
    [] -> pure ()
    unknown -> fail (label <> " has unknown field(s): " <> T.unpack (T.intercalate ", " unknown))

nonBlank :: String -> Text -> Yaml.Parser Text
nonBlank label value
  | T.null (T.strip value) = fail (label <> " is empty")
  | value /= T.strip value = fail (label <> " has surrounding whitespace")
  | otherwise = pure value

profileNameValue :: Text -> Yaml.Parser Text
profileNameValue value = do
  name <- nonBlank "profile name" value
  when ("#" `T.isInfixOf` name) (fail "profile name contains reserved character '#'")
  pure name

rejectDuplicate :: String -> [Text] -> Yaml.Parser ()
rejectDuplicate label names =
  case duplicate names of
    Nothing -> pure ()
    Just name -> fail ("duplicate " <> label <> " name '" <> T.unpack name <> "'")

validateRoutingConfig :: RoutingConfig -> Either Text RoutingConfig
validateRoutingConfig config = config <$ mapM_ validateProfile' (Map.elems (routingProfiles config))
  where
    validateProfile' profile = mapM_ (validateRealization profile) (profileChain profile)
    validateRealization profile realization =
      unless (realizationRouter realization `Map.member` routingRouters config) $
        Left
          ( "profile '"
              <> profileName profile
              <> "' names unknown router '"
              <> realizationRouter realization
              <> "'"
          )

duplicate :: (Ord a) => [a] -> Maybe a
duplicate = go Map.empty
  where
    go _ [] = Nothing
    go seen (x : xs)
      | x `Map.member` seen = Just x
      | otherwise = go (Map.insert x () seen) xs

sensitive :: Text -> Bool
sensitive key =
  let collapsed = T.filter isAlphaNum (T.toLower key)
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
   in any (`T.isInfixOf` collapsed) fragments

-- | Decode and validate one complete version-1 document.
decodeRoutingConfig :: BS.ByteString -> Either Text RoutingConfig
decodeRoutingConfig bytes = decodeRoutingLayer bytes >>= validateRoutingConfig

decodeLayerVersion :: BS.ByteString -> Either Text Int
decodeLayerVersion bytes = case Yaml.decodeEither' bytes of
  Left problem -> Left (T.pack (Yaml.prettyPrintParseException problem))
  Right (RoutingVersionFile version) -> Right version

decodeRoutingLayer :: BS.ByteString -> Either Text RoutingConfig
decodeRoutingLayer bytes = case Yaml.decodeEither' bytes of
  Left problem -> Left (T.pack (Yaml.prettyPrintParseException problem))
  Right (RoutingFile routers profiles) ->
    Right
      RoutingConfig
        { routingRouters = Map.fromList [(routerName router, router) | router <- routers],
          routingProfiles = Map.fromList [(profileName profile, profile) | profile <- profiles]
        }

-- | Overlay whole named routers and profiles.  'Map.union' is left-biased, so
-- every object in the second argument replaces the same-named lower layer.
mergeRoutingConfig :: RoutingConfig -> RoutingConfig -> RoutingConfig
mergeRoutingConfig base overlay =
  RoutingConfig
    { routingRouters = routingRouters overlay `Map.union` routingRouters base,
      routingProfiles = routingProfiles overlay `Map.union` routingProfiles base
    }

-- | Add every profile's primary backend beneath explicit command-line routes.
-- The command line is the higher layer and therefore remains last in the
-- authored order and wins lookup for a repeated name.
routesWithProfiles :: RoutingConfig -> Routes Backend -> Either Text (Routes Backend)
routesWithProfiles config commandRoutes = do
  configured <- traverse primary (Map.toAscList (routingProfiles config))
  pure (overlayRoutes (routeDefault commandRoutes) configured (routeNamed commandRoutes))
  where
    primary (name, profile) = do
      router <- routerFor config name (realizationRouter (NE.head (profileChain profile)))
      pure (name, routerBackend router)

-- | Resolve the profile chains used by one program.  A YAML-owned multi-rung
-- chain and an authored @fallingBackTo@ chain may not both own the same model.
resolveRoutingConfig :: RoutingConfig -> Routes Backend -> Map Text [Text] -> Either Text ResolvedRouting
resolveRoutingConfig config commandRoutes authored = do
  pieces <- traverse resolveChain (Map.toAscList authored)
  realizations <- foldl insertResolved (Right Map.empty) (concatMap pieceRealizations pieces)
  let commandMap = Map.fromList (routeNamed commandRoutes)
      realized = fmap (applyCommandOverride commandMap) realizations
      configured = [(axis, resolvedBackend target) | (axis, target) <- Map.toAscList realized]
      routeTable = overlayRoutes (routeDefault commandRoutes) configured (routeNamed commandRoutes)
  pure
    ResolvedRouting
      { resolvedRoutes = routeTable,
        resolvedChains = Map.fromList [(piecePrimary piece, pieceAlternates piece) | piece <- pieces],
        resolvedRealizations = realized,
        resolvedRoutingPersona = Nothing,
        resolvedRoutingPersonaSource = Nothing
      }
  where
    authoredNames = Map.keys authored <> concat (Map.elems authored)

    resolveChain (primary, alternates)
      | null alternates = case Map.lookup primary (routingProfiles config) of
          Nothing -> pure (Piece primary [] [])
          Just profile -> do
            let specs = NE.toList (profileChain profile)
                axes = primary : [primary <> "#" <> T.pack (show rung) | rung <- [2 .. length specs]]
                generated = drop 1 axes
            case find (`elem` authoredNames) generated of
              Just collision -> Left ("generated routing axis '" <> collision <> "' collides with an authored model name")
              Nothing -> pure ()
            targets <- sequence [resolveTarget primary axis rung spec | (axis, rung, spec) <- zip3 axes [1 ..] specs]
            pure (Piece primary generated targets)
      | otherwise = do
          targets <- catMaybes <$> traverse resolveSingle (primary : alternates)
          pure (Piece primary alternates targets)

    resolveSingle name = case Map.lookup name (routingProfiles config) of
      Nothing -> pure Nothing
      Just profile -> case NE.toList (profileChain profile) of
        [spec] -> Just <$> resolveTarget name name 1 spec
        _ ->
          Left
            ( "model '"
                <> name
                <> "' has both an authored fallback chain and a multi-rung YAML profile; keep the chain in one place"
            )

    resolveTarget profile axis rung spec = do
      router <- routerFor config profile (realizationRouter spec)
      pure
        ResolvedRealization
          { resolvedProfile = profile,
            resolvedAxis = axis,
            resolvedRung = rung,
            resolvedRouter = router,
            resolvedBackend = routerBackend router,
            resolvedSpec = spec,
            resolvedEngineFingerprint = Nothing,
            resolvedModelSelection = Nothing
          }

-- | Expand version-2 symbolic profiles through the established chain resolver.
-- The resulting model names are still concrete aliases; no inventory or secret
-- is consulted, so this phase is safe inside the run-fact fixed point.
expandRoutingConfigV2 :: SelectedRoutingV2 -> Map Text Text -> Routes Backend -> Map Text [Text] -> Either Text ResolvedRouting
expandRoutingConfigV2 selected overrides commandRoutes authored = do
  lowered <- lowerSelectedRouting selected
  expanded <- resolveRoutingConfig lowered commandRoutes authored
  let managed = resolvedRealizations expanded
      rawConflicts = [axis | (axis, _) <- routeNamed commandRoutes, axis `Map.member` managed]
      unknownOverrides = filter (`Map.notMember` managed) (Map.keys overrides)
  case rawConflicts of
    axis : _ ->
      Left
        ( "raw --route cannot replace version-2 managed axis '"
            <> axis
            <> "'; use --realize AXIS=MODEL-ALIAS or a project profile override"
        )
    [] -> pure ()
  case unknownOverrides of
    axis : _ -> Left ("--realize names unknown version-2 axis '" <> axis <> "'")
    [] -> pure ()
  realized <- Map.traverseWithKey applyAlias managed
  let configured = [(axis, resolvedBackend target) | (axis, target) <- Map.toAscList realized]
      unmanagedCommand = filter ((`Map.notMember` managed) . fst) (routeNamed commandRoutes)
  pure
    expanded
      { resolvedRoutes = overlayRoutes (routeDefault commandRoutes) configured unmanagedCommand,
        resolvedRealizations = realized,
        resolvedRoutingPersona = Just (selectedPersonaName selected),
        resolvedRoutingPersonaSource = Just (selectedPersonaSource selected)
      }
  where
    config = selectedRoutingV2 selected
    persona = selectedPersona selected

    applyAlias axis target = do
      let alias = Map.findWithDefault (realizationModel (resolvedSpec target)) axis overrides
      (model, engine) <- modelAndEngine config persona (selectedPersonaName selected) alias
      let router =
            Router
              { routerName = concreteModelEngine model,
                routerBackend = engineBackend engine,
                routerProvider = engineProvider engine
              }
          spec =
            (resolvedSpec target)
              { realizationRouter = concreteModelEngine model,
                realizationModel = alias
              }
      pure
        target
          { resolvedRouter = router,
            resolvedBackend = engineBackend engine,
            resolvedSpec = spec,
            resolvedEngineFingerprint = Just (engineDefinitionFingerprint config (concreteModelEngine model) engine),
            resolvedModelSelection = Nothing
          }

-- | Replace the aliases of an already-expanded policy with exact model ids.
-- This phase is run once after inventories have been frozen.
freezeRoutingConfigV2 :: SelectedRoutingV2 -> Map Text InventoryResult -> ResolvedRouting -> Either Text ResolvedRouting
freezeRoutingConfigV2 selected inventories expanded = do
  unless (resolvedRoutingPersona expanded == Just (selectedPersonaName selected)) $
    Left "version-2 routing was expanded for a different persona"
  realized <- Map.traverseWithKey freezeAxis (resolvedRealizations expanded)
  pure expanded {resolvedRealizations = realized}
  where
    config = selectedRoutingV2 selected
    persona = selectedPersona selected

    freezeAxis _ target = do
      let alias = realizationModel (resolvedSpec target)
      (model, _) <- modelAndEngine config persona (selectedPersonaName selected) alias
      let evidence = Map.findWithDefault (InventoryResult Nothing Nothing Nothing) (concreteModelEngine model) inventories
      selection <- case resolveConcreteModel alias model evidence of
        Right value -> Right value
        Left problem ->
          Left
            ( "persona '"
                <> selectedPersonaName selected
                <> "', engine '"
                <> concreteModelEngine model
                <> "', model alias '"
                <> alias
                <> "', endpoint "
                <> fromMaybe "none" (inventoryResultFingerprint evidence)
                <> maybe "" (", inventory " <>) (inventoryResultWarning evidence)
                <> ": "
                <> problem
            )
      pure
        target
          { resolvedSpec = (resolvedSpec target) {realizationModel = selectedModelId selection},
            resolvedModelSelection = Just selection
          }

-- | Convenience composition for callers which already possess frozen
-- inventories. CLI execution uses the two phases separately around convergence.
resolveRoutingConfigV2 :: SelectedRoutingV2 -> Map Text InventoryResult -> Map Text Text -> Routes Backend -> Map Text [Text] -> Either Text ResolvedRouting
resolveRoutingConfigV2 selected inventories overrides commandRoutes authored =
  expandRoutingConfigV2 selected overrides commandRoutes authored >>= freezeRoutingConfigV2 selected inventories

modelAndEngine :: RoutingConfigV2 -> Persona -> Text -> Text -> Either Text (ConcreteModel, EngineDefinition)
modelAndEngine config persona personaName alias = do
  unless (alias `elem` personaModels persona) $
    Left ("model alias '" <> alias <> "' is outside persona '" <> personaName <> "'")
  model <- maybe (Left ("unknown concrete model alias '" <> alias <> "'")) Right (Map.lookup alias (routingV2Models config))
  unless (concreteModelEngine model `elem` personaEngines persona) $
    Left ("concrete model alias '" <> alias <> "' belongs to engine outside persona '" <> personaName <> "'")
  engine <-
    maybe
      (Left ("concrete model alias '" <> alias <> "' names unknown engine '" <> concreteModelEngine model <> "'"))
      Right
      (Map.lookup (concreteModelEngine model) (routingV2Engines config))
  pure (model, engine)

lowerSelectedRouting :: SelectedRoutingV2 -> Either Text RoutingConfig
lowerSelectedRouting selected = do
  let config = selectedRoutingV2 selected
      persona = selectedPersona selected
  routersByName <- fmap Map.fromList . traverse (lowerEngine config) $ personaEngines persona
  profilesByName <- Map.traverseWithKey (lowerProfile config) (personaProfiles persona)
  pure (RoutingConfig routersByName profilesByName)
  where
    lowerEngine config name = do
      engine <- maybe (Left ("persona names unknown engine '" <> name <> "'")) Right (Map.lookup name (routingV2Engines config))
      pure
        ( name,
          Router
            { routerName = name,
              routerBackend = engineBackend engine,
              routerProvider = engineProvider engine
            }
        )

    lowerProfile config name (ProfileV2 chain) = do
      lowered <- traverse (lowerRealization config) chain
      nonEmpty <- maybe (Left ("profile '" <> name <> "' has an empty chain")) Right (NE.nonEmpty lowered)
      pure (Profile name nonEmpty)

    lowerRealization config realization = do
      model <-
        maybe
          (Left ("profile names unknown concrete model alias '" <> realizationV2Model realization <> "'"))
          Right
          (Map.lookup (realizationV2Model realization) (routingV2Models config))
      pure
        Realization
          { realizationRouter = concreteModelEngine model,
            realizationModel = realizationV2Model realization,
            realizationThinking = realizationV2Thinking realization,
            realizationMaxOutput = realizationV2MaxOutput realization,
            realizationOptions = realizationV2Options realization
          }

data Piece = Piece
  { piecePrimary :: !Text,
    pieceAlternates :: ![Text],
    pieceRealizations :: ![ResolvedRealization]
  }

routerFor :: RoutingConfig -> Text -> Text -> Either Text Router
routerFor config profile name =
  maybe
    (Left ("profile '" <> profile <> "' names unknown router '" <> name <> "'"))
    Right
    (Map.lookup name (routingRouters config))

insertResolved :: Either Text (Map Text ResolvedRealization) -> ResolvedRealization -> Either Text (Map Text ResolvedRealization)
insertResolved acc target = do
  known <- acc
  case Map.lookup (resolvedAxis target) known of
    Nothing -> pure (Map.insert (resolvedAxis target) target known)
    Just existing
      | existing == target -> pure known
      | otherwise -> Left ("routing axis '" <> resolvedAxis target <> "' resolves two different ways")

applyCommandOverride :: Map Text Backend -> ResolvedRealization -> ResolvedRealization
applyCommandOverride command target =
  target {resolvedBackend = Map.findWithDefault (resolvedBackend target) (resolvedAxis target) command}

-- Lower-precedence pairs first, higher-precedence pairs last and authoritative.
overlayRoutes :: Backend -> [(Text, Backend)] -> [(Text, Backend)] -> Routes Backend
overlayRoutes defaultBackend lower higher =
  let claimed = map fst higher
   in routes defaultBackend (filter ((`notElem` claimed) . fst) lower <> higher)

-- | Discover untagged routing paths for version-1 API compatibility. The
-- composition root uses private role-preserving discovery for version 2.
discoverRoutingFiles :: FilePath -> FilePath -> IO [FilePath]
discoverRoutingFiles configHome cwd = map snd <$> discoverRoutingLayers configHome cwd

-- | Discover the trusted user path followed by the nearest untrusted project
-- path. Authority comes from this path-derived role, never from YAML shape.
discoverRoutingLayers :: FilePath -> FilePath -> IO [(RoutingLayerRole, FilePath)]
discoverRoutingLayers configHome cwd = do
  let user = configHome </> "agent-cat" </> "routing.yaml"
  userThere <- doesFileExist user
  project <- nearestProjectFile cwd
  pure
    ( deduplicate
        []
        ( catMaybes
            [ if userThere then Just (UserRoutingLayer, user) else Nothing,
              fmap (\path -> (ProjectRoutingLayer, path)) project
            ]
        )
    )
  where
    deduplicate _ [] = []
    deduplicate seen (layer@(_, path) : rest)
      | path `elem` seen = deduplicate seen rest
      | otherwise = layer : deduplicate (path : seen) rest

nearestProjectFile :: FilePath -> IO (Maybe FilePath)
nearestProjectFile = go
  where
    go directory = do
      let candidate = directory </> ".agent-cat" </> "routing.yaml"
      there <- doesFileExist candidate
      if there
        then pure (Just candidate)
        else do
          gitBoundary <- doesPathExist (directory </> ".git")
          let parent = takeDirectory directory
          if gitBoundary || parent == directory then pure Nothing else go parent

-- | Read and overlay version-1 files in increasing precedence order. Untagged
-- version-2 input is refused because its user/project authority is unknowable.
loadRoutingFiles :: [FilePath] -> IO (Either Text LoadedRouting)
loadRoutingFiles files = loadRoutingDocuments [(Nothing, path) | path <- files]

-- | Read routing files whose authority was assigned before decoding. Version-1
-- retains its historical overlay behavior; version 2 requires one user layer
-- followed by at most one project layer.
loadRoutingLayers :: [(RoutingLayerRole, FilePath)] -> IO (Either Text LoadedRouting)
loadRoutingLayers layers = loadRoutingDocuments [(Just role, path) | (role, path) <- layers]

loadRoutingDocuments :: [(Maybe RoutingLayerRole, FilePath)] -> IO (Either Text LoadedRouting)
loadRoutingDocuments files = do
  readResult <- traverse readLayer files
  pure $ do
    layers <- sequence readResult
    versions <- traverse (\(_, path, bytes) -> firstAt path (decodeLayerVersion bytes)) layers
    let distinctVersions = nub versions
    case distinctVersions of
      [] -> Right (LoadedRouting emptyRoutingConfig [] Nothing Nothing)
      [1] -> loadV1Layers [(path, bytes) | (_, path, bytes) <- layers]
      [2] -> do
        tagged <- traverse requireRole layers
        loadV2Layers tagged
      [version] -> Left ("unsupported routing configuration version " <> T.pack (show version))
      _
        | all (`elem` [1, 2]) distinctVersions -> Left "routing configuration cannot mix version 1 and version 2 documents"
        | otherwise -> Left ("unsupported routing configuration versions " <> T.intercalate ", " (map (T.pack . show) distinctVersions))
  where
    readLayer (role, path) = do
      result <- try (BS.readFile path)
      pure $ case result of
        Left problem -> Left (T.pack path <> ": " <> T.pack (show (problem :: IOException)))
        Right bytes -> Right (role, path, bytes)

    requireRole (Nothing, path, _) =
      Left (T.pack path <> ": version-2 routing requires path-derived user/project authority")
    requireRole (Just role, path, bytes) = Right (role, path, bytes)

    firstAt path = either (Left . ((T.pack path <> ": ") <>)) Right

loadV1Layers :: [(FilePath, BS.ByteString)] -> Either Text LoadedRouting
loadV1Layers layers = do
  config <- foldl apply (Right emptyRoutingConfig) layers >>= validateRoutingConfig
  pure (LoadedRouting config (map fst layers) Nothing Nothing)
  where
    apply accumulated (path, bytes) = do
      base <- accumulated
      layer <- firstAt path (decodeRoutingLayer bytes)
      pure (mergeRoutingConfig base layer)
    firstAt path = either (Left . ((T.pack path <> ": ") <>)) Right

loadV2Layers :: [(RoutingLayerRole, FilePath, BS.ByteString)] -> Either Text LoadedRouting
loadV2Layers layers = do
  users <- traverse (uncurry firstUserAt) [(path, bytes) | (UserRoutingLayer, path, bytes) <- layers]
  projects <- traverse (uncurry firstProjectAt) [(path, bytes) | (ProjectRoutingLayer, path, bytes) <- layers]
  let roles = [role | (role, _, _) <- layers]
  unless (roles == [UserRoutingLayer] || roles == [UserRoutingLayer, ProjectRoutingLayer]) $
    Left "version-2 routing requires one user document followed by at most one project document"
  (privileged, project) <- case (users, projects) of
    ([user], []) -> Right (user, Nothing)
    ([user], [project]) -> Right (user, Just project)
    _ -> Left "version-2 routing requires one user document followed by at most one project document"
  forM_ project $ \selector -> do
    _ <- selectRoutingPersona privileged Nothing Nothing (Just selector)
    pure ()
  pure
    LoadedRouting
      { loadedRouting = emptyRoutingConfig,
        loadedRoutingSources = [path | (_, path, _) <- layers],
        loadedRoutingV2User = Just privileged,
        loadedRoutingV2Project = project
      }
  where
    firstUserAt path bytes = firstAt path (decodeRoutingUserV2 bytes)
    firstProjectAt path bytes = firstAt path (decodeRoutingProjectV2 bytes)
    firstAt path = either (Left . ((T.pack path <> ": ") <>)) Right

-- | Load the conventional user and project files for this process.
loadRoutingConfig :: IO (Either Text LoadedRouting)
loadRoutingConfig = do
  home <- getHomeDirectory
  configuredHome <- lookupEnv "XDG_CONFIG_HOME"
  let configHome = case configuredHome of
        Just path | not (null path) -> path
        _ -> home </> ".config"
  cwd <- getCurrentDirectory
  discoverRoutingLayers configHome cwd >>= loadRoutingLayers
