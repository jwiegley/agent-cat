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
-- @thinking@ and @max-output@ are required constraints, never hints; the
-- runtime must apply or verify them before putting a question. @options@ is
-- optional and carries additional non-secret backend constraints.
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
    discoverRoutingFiles,
    loadRoutingFiles,
    loadRoutingConfig,
  )
where

import Agentic.Route
  ( Backend,
    Routes,
    parseBackend,
    routeDefault,
    routeNamed,
    routes,
  )
import Control.Exception (IOException, try)
import Control.Monad (unless, when)
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

-- | Provider-neutral effort names.  A transport translates one of these to an
-- advertised native option; no translation means the requested realization is
-- unavailable.
data Thinking
  = ThinkOff
  | ThinkMinimal
  | ThinkLow
  | ThinkMedium
  | ThinkHigh
  | ThinkXHigh
  | ThinkMax
  deriving (Eq, Ord, Show, Enum, Bounded)

thinkingName :: Thinking -> Text
thinkingName = \case
  ThinkOff -> "off"
  ThinkMinimal -> "minimal"
  ThinkLow -> "low"
  ThinkMedium -> "medium"
  ThinkHigh -> "high"
  ThinkXHigh -> "xhigh"
  ThinkMax -> "max"

instance FromJSON Thinking where
  parseJSON value = do
    name <- parseJSON value
    case find ((== name) . thinkingName) [minBound .. maxBound] of
      Just thinking -> pure thinking
      Nothing -> fail ("unknown thinking level '" <> T.unpack name <> "'")

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
    realizationMaxOutput :: !Integer,
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

-- | The merged configuration together with the files that contributed to it,
-- in increasing precedence order.
data LoadedRouting = LoadedRouting
  { loadedRouting :: !RoutingConfig,
    loadedRoutingSources :: ![FilePath]
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
    resolvedSpec :: !Realization
  }
  deriving (Eq, Show)

-- | The execution-only tables produced for one program.
data ResolvedRouting = ResolvedRouting
  { resolvedRoutes :: !(Routes Backend),
    resolvedChains :: !(Map Text [Text]),
    resolvedRealizations :: !(Map Text ResolvedRealization)
  }

emptyRoutingConfig :: RoutingConfig
emptyRoutingConfig = RoutingConfig Map.empty Map.empty

-- The list representation is intentional: unlike an object decoder, it can
-- reject duplicate names instead of silently retaining one value.
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
    maxOutput <- o .: "max-output"
    when (maxOutput <= 0) (fail "max-output must be a positive integer")
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
        resolvedRealizations = realized
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
            resolvedSpec = spec
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

-- | Discover the user layer followed by the nearest project layer.  The first
-- argument is the already-resolved XDG configuration home, which keeps tests
-- independent of process-global environment variables.
discoverRoutingFiles :: FilePath -> FilePath -> IO [FilePath]
discoverRoutingFiles configHome cwd = do
  let user = configHome </> "agent-cat" </> "routing.yaml"
  userThere <- doesFileExist user
  project <- nearestProjectFile cwd
  pure (nub (catMaybes [if userThere then Just user else Nothing, project]))

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

-- | Read, validate and overlay files in increasing precedence order.
loadRoutingFiles :: [FilePath] -> IO (Either Text LoadedRouting)
loadRoutingFiles files = go emptyRoutingConfig [] files
  where
    go config sources [] =
      pure (LoadedRouting <$> validateRoutingConfig config <*> pure sources)
    go config sources (path : rest) = do
      readResult <- try (BS.readFile path)
      case readResult of
        Left problem -> pure (Left (T.pack path <> ": " <> T.pack (show (problem :: IOException))))
        Right bytes -> case decodeRoutingLayer bytes of
          Left problem -> pure (Left (T.pack path <> ": " <> problem))
          Right layer -> go (mergeRoutingConfig config layer) (sources <> [path]) rest

-- | Load the conventional user and project files for this process.
loadRoutingConfig :: IO (Either Text LoadedRouting)
loadRoutingConfig = do
  home <- getHomeDirectory
  configuredHome <- lookupEnv "XDG_CONFIG_HOME"
  let configHome = case configuredHome of
        Just path | not (null path) -> path
        _ -> home </> ".config"
  cwd <- getCurrentDirectory
  discoverRoutingFiles configHome cwd >>= loadRoutingFiles
