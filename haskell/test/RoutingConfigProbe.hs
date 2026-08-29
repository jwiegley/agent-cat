{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

-- This focused probe is linked threaded and is always exercised at -N8.
import Agentic.Route
  ( Backend (BackendAcp, BackendDeck),
    routeByModel,
    routeNamed,
    routes,
  )
import Agentic.RoutingConfig
import Data.Aeson (Value (..))
import qualified Data.ByteString.Char8 as BS
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import qualified Data.List.NonEmpty as NE
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import GHC.Clock (getMonotonicTimeNSec)
import System.Directory
  ( createDirectoryIfMissing,
    getTemporaryDirectory,
    removePathForcibly,
  )
import System.Exit (exitFailure)
import System.FilePath ((</>))
import Control.Exception (finally)

baseYaml :: BS.ByteString
baseYaml =
  BS.unlines
    [ "version: 1",
      "routers:",
      "  - name: claude",
      "    backend: acp:claude",
      "    provider: anthropic",
      "  - name: reviewer-pane",
      "    backend: deck:reviewer",
      "    provider: anthropic",
      "profiles:",
      "  - name: deep-thinker",
      "    chain:",
      "      - router: claude",
      "        model: claude-fable-5",
      "        thinking: max",
      "        max-output: 65536",
      "        options:",
      "          temperature: deterministic",
      "          samples: 3",
      "          streaming: true",
      "      - router: reviewer-pane",
      "        model: claude-opus-5",
      "        thinking: high",
      "        max-output: 32768"
    ]

projectYaml :: BS.ByteString
projectYaml =
  BS.unlines
    [ "version: 1",
      "profiles:",
      "  - name: deep-thinker",
      "    chain:",
      "      - router: claude",
      "        model: project-model",
      "        thinking: low",
      "        max-output: 16384"
    ]

bad :: [BS.ByteString]
bad =
  [ "version: 2",
    BS.unlines ["version: 1", "surprise: true"],
    BS.unlines ["version: 1", "routers:", "  - name: same", "    backend: acp:a", "    provider: p", "  - name: same", "    backend: acp:b", "    provider: p"],
    BS.unlines ["version: 1", "profiles:", "  - name: empty", "    chain: []"],
    BS.unlines ["version: 1", "profiles:", "  - name: missing", "    chain:", "      - router: nowhere", "        model: m", "        thinking: low", "        max-output: 1"],
    BS.unlines ["version: 1", "routers:", "  - name: r", "    backend: acp:a", "    provider: p", "profiles:", "  - name: p", "    chain:", "      - router: r", "        model: m", "        thinking: enormous", "        max-output: 1"],
    BS.unlines ["version: 1", "routers:", "  - name: r", "    backend: acp:a", "    provider: p", "profiles:", "  - name: p", "    chain:", "      - router: r", "        model: m", "        thinking: low", "        max-output: 0"],
    BS.unlines ["version: 1", "routers:", "  - name: r", "    backend: acp:a", "    provider: p", "profiles:", "  - name: p", "    chain:", "      - router: r", "        model: m", "        max-output: 1"],
    BS.unlines ["version: 1", "routers:", "  - name: r", "    backend: acp:a", "    provider: p", "profiles:", "  - name: p", "    chain:", "      - router: r", "        model: m", "        thinking: low"],
    BS.unlines ["version: 1", "routers:", "  - name: r", "    backend: acp:a", "    provider: p", "profiles:", "  - name: p", "    chain:", "      - router: r", "        model: m", "        thinking: low", "        max-output: 1", "        options:", "          nested: [one]"],
    BS.unlines ["version: 1", "profiles:", "  - name: reserved#2", "    chain: []"]
  ]
    <> map secretOption
      [ "api-key",
        "apiKey",
        "apikey",
        "credential",
        "auth",
        "authentication",
        "client-auth",
        "access-key",
        "cookie",
        "signing-key",
        "privateKey",
        "session_key"
      ]

secretOption :: BS.ByteString -> BS.ByteString
secretOption key =
  BS.unlines
    [ "version: 1",
      "routers:",
      "  - name: r",
      "    backend: acp:a",
      "    provider: p",
      "profiles:",
      "  - name: p",
      "    chain:",
      "      - router: r",
      "        model: m",
      "        thinking: low",
      "        max-output: 1",
      "        options:",
      "          " <> key <> ": forbidden"
    ]

check :: IORef Int -> Text -> Bool -> IO ()
check failures name holds =
  if holds
    then TIO.putStrLn ("ok   " <> name)
    else TIO.putStrLn ("FAIL " <> name) >> modifyIORef' failures (+ 1)

main :: IO ()
main = do
  failures <- newIORef 0
  case decodeRoutingConfig baseYaml of
    Left problem -> check failures ("valid routing YAML decodes: " <> problem) False
    Right config -> do
      check failures "ACP and deck routers decode" $
        fmap routerBackend (Map.lookup "claude" (routingRouters config)) == Just (BackendAcp "claude")
          && fmap routerBackend (Map.lookup "reviewer-pane" (routingRouters config)) == Just (BackendDeck "reviewer")
      check failures "profile keeps its ordered realization chain" $
        case Map.lookup "deep-thinker" (routingProfiles config) of
          Just profile ->
            map realizationModel (NE.toList (profileChain profile)) == ["claude-fable-5", "claude-opus-5"]
              && realizationThinking (NE.head (profileChain profile)) == ThinkMax
              && realizationMaxOutput (NE.head (profileChain profile)) == 65536
              && Map.lookup "temperature" (realizationOptions (NE.head (profileChain profile))) == Just (String "deterministic")
              && Map.lookup "samples" (realizationOptions (NE.head (profileChain profile))) == Just (Number 3)
              && Map.lookup "streaming" (realizationOptions (NE.head (profileChain profile))) == Just (Bool True)
          Nothing -> False
      let commandRoutes = routes (BackendAcp "default") [("deep-thinker", BackendDeck "cli-override")]
      case resolveRoutingConfig config commandRoutes (Map.singleton "deep-thinker" []) of
        Left problem -> check failures ("symbolic profile resolves: " <> problem) False
        Right resolved -> do
          check failures "YAML owns the ordered fallback axes" $
            Map.lookup "deep-thinker" (resolvedChains resolved) == Just ["deep-thinker#2"]
          check failures "CLI backend overrides the primary while YAML routes the fallback" $
            Map.lookup "deep-thinker" (routeByModel (resolvedRoutes resolved)) == Just (BackendDeck "cli-override")
              && Map.lookup "deep-thinker#2" (routeByModel (resolvedRoutes resolved)) == Just (BackendDeck "reviewer")
          check failures "resolved provenance retains profile, rung, and concrete model" $
            case (Map.lookup "deep-thinker" (resolvedRealizations resolved), Map.lookup "deep-thinker#2" (resolvedRealizations resolved)) of
              (Just first, Just second) ->
                resolvedProfile first == "deep-thinker"
                  && resolvedRung first == 1
                  && resolvedBackend first == BackendDeck "cli-override"
                  && realizationModel (resolvedSpec second) == "claude-opus-5"
              _ -> False
      check failures "authored and YAML-owned fallback chains are refused as ambiguous" $
        case resolveRoutingConfig config commandRoutes (Map.singleton "deep-thinker" ["legacy-spare"]) of
          Left problem -> "keep the chain in one place" `T.isInfixOf` problem
          Right _ -> False
      let legacyRoutes = routes (BackendAcp "default") [("plain", BackendDeck "pane")]
      check failures "empty YAML preserves authored chains and command routes" $
        case resolveRoutingConfig emptyRoutingConfig legacyRoutes (Map.singleton "plain" ["spare"]) of
          Right resolved ->
            resolvedChains resolved == Map.singleton "plain" ["spare"]
              && routeNamed (resolvedRoutes resolved) == routeNamed legacyRoutes
              && Map.null (resolvedRealizations resolved)
          Left _ -> False
  check failures "invalid schema, names, references, settings, and secret options are refused" $
    all (either (const True) (const False) . decodeRoutingConfig) bad

  temp <- getTemporaryDirectory
  stamp <- getMonotonicTimeNSec
  let root = temp </> ("agentic-routing-probe-" <> show stamp)
      xdg = root </> "xdg"
      project = root </> "work"
      nested = project </> "a" </> "b"
      userFile = xdg </> "agent-cat" </> "routing.yaml"
      projectFile = project </> ".agent-cat" </> "routing.yaml"
  ( do
      createDirectoryIfMissing True (xdg </> "agent-cat")
      createDirectoryIfMissing True (project </> ".git")
      createDirectoryIfMissing True (project </> ".agent-cat")
      createDirectoryIfMissing True nested
      BS.writeFile userFile baseYaml
      BS.writeFile projectFile projectYaml
      files <- discoverRoutingFiles xdg nested
      loaded <- loadRoutingFiles files
      check failures "discovery orders XDG before nearest project config" (files == [userFile, projectFile])
      check failures "project profiles replace user profiles whole while reusing user routers" $
        case loaded of
          Right result ->
            loadedRoutingSources result == files
              && case Map.lookup "deep-thinker" (routingProfiles (loadedRouting result)) of
                Just profile ->
                  map realizationModel (NE.toList (profileChain profile)) == ["project-model"]
                    && realizationThinking (NE.head (profileChain profile)) == ThinkLow
                    && realizationMaxOutput (NE.head (profileChain profile)) == 16384
                Nothing -> False
          Left _ -> False
    )
    `finally` removePathForcibly root

  count <- readIORef failures
  if count == 0
    then TIO.putStrLn "routing config probe: all checks passed"
    else TIO.putStrLn ("routing config probe: " <> T.pack (show count) <> " failed") >> exitFailure
