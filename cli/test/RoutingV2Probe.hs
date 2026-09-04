{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Agentic.Acp (AcpConfig (..), defaultAcpConfig, withAcp)
import Agentic.Route (Backend (..), Routes (..), routes)
import Agentic.RoutingConfig
import Agentic.RoutingConfig.V2
import Agentic.RoutingDiscovery
import Agentic.RoutingSecrets
import Control.Exception (finally)
import qualified Data.ByteString.Char8 as BS
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Time.Clock (UTCTime)
import System.Directory (Permissions (..), getCurrentDirectory, getPermissions, getTemporaryDirectory, removeFile, setPermissions)
import System.Environment (getEnvironment)
import System.Exit (exitFailure)
import System.FilePath ((</>))
import System.IO (hClose, hPutStr, openBinaryTempFile)

userYaml :: BS.ByteString
userYaml =
  BS.unlines
    [ "version: 2",
      "default-persona: personal",
      "secrets:",
      "  personal-key:",
      "    env: PERSONAL_API_KEY",
      "  work-key:",
      "    env: WORK_API_KEY",
      "engines:",
      "  personal-claude:",
      "    backend: acp:claude",
      "    provider: anthropic",
      "    environment:",
      "      ANTHROPIC_API_KEY:",
      "        secret: personal-key",
      "    catalogue:",
      "      dialect: anthropic",
      "      url: https://api.anthropic.com/v1/models",
      "      auth:",
      "        header: x-api-key",
      "        secret: personal-key",
      "      headers:",
      "        anthropic-version: '2023-06-01'",
      "      timeout-ms: 5000",
      "      max-bytes: 4194304",
      "      cache:",
      "        fresh-for: 24h",
      "        stale-if-error: 7d",
      "  work-codex:",
      "    backend: acp:codex",
      "    provider: openai",
      "    environment:",
      "      OPENAI_API_KEY:",
      "        secret: work-key",
      "models:",
      "  opus:",
      "    engine: personal-claude",
      "    select:",
      "      - exact: claude-opus-5",
      "  opus-old:",
      "    engine: personal-claude",
      "    select:",
      "      - exact: claude-opus-4",
      "  sol:",
      "    engine: work-codex",
      "    select:",
      "      - exact: gpt-5.6-sol",
      "      - prefix: gpt-5.6-sol-",
      "        order: newest",
      "personas:",
      "  personal:",
      "    engines: [personal-claude]",
      "    models: [opus, opus-old]",
      "    profiles:",
      "      deep-thinker:",
      "        chain:",
      "          - model: opus",
      "            thinking: max",
      "            max-output: unconstrained",
      "          - model: opus",
      "            thinking: high",
      "            max-output: 32768",
      "  work:",
      "    engines: [work-codex]",
      "    models: [sol]",
      "    profiles:",
      "      deep-thinker:",
      "        chain:",
      "          - model: sol",
      "            thinking: xhigh",
      "            max-output: 65536"
    ]

projectYaml :: BS.ByteString
projectYaml =
  BS.unlines
    [ "version: 2",
      "persona: personal",
      "profiles:",
      "  deep-thinker:",
      "    chain:",
      "      - model: opus",
      "        thinking: high",
      "        max-output: unconstrained"
    ]

check :: IORef Int -> Text -> Bool -> IO ()
check failures label holds =
  if holds
    then TIO.putStrLn ("ok   " <> label)
    else TIO.putStrLn ("FAIL " <> label) >> modifyIORef' failures (+ 1)

isLeftContaining :: Text -> Either Text a -> Bool
isLeftContaining needle = either (T.isInfixOf needle) (const False)

main :: IO ()
main = do
  failures <- newIORef 0
  check failures "version detector reads v1 and v2" $
    routingDocumentVersion "version: 1\n" == Right 1
      && routingDocumentVersion userYaml == Right 2

  case decodeRoutingUserV2 userYaml of
    Left problem -> check failures ("valid v2 user document decodes: " <> problem) False
    Right user -> do
      check failures "v2 maps retain engines, concrete models, and personas" $
        Map.keys (routingV2Engines user) == ["personal-claude", "work-codex"]
          && Map.keys (routingV2Models user) == ["opus", "opus-old", "sol"]
          && Map.keys (routingV2Personas user) == ["personal", "work"]
      check failures "catalogue bounds and secret references are typed" $
        case Map.lookup "personal-claude" (routingV2Engines user) of
          Just engine ->
            Map.lookup "ANTHROPIC_API_KEY" (engineEnvironment engine) == Just (EnvironmentSecret "personal-key")
              && fmap catalogueTimeoutMs (engineCatalogue engine) == Just 5000
              && fmap (cacheFreshSeconds . catalogueCache) (engineCatalogue engine) == Just 86400
          Nothing -> False
      case decodeRoutingProjectV2 projectYaml of
        Left problem -> check failures ("valid project selector decodes: " <> problem) False
        Right project -> do
          let cli = selectRoutingPersona user (Just "work") (Just "personal") (Just project)
              env = selectRoutingPersona user Nothing (Just "work") (Just project)
              projectSelected = selectRoutingPersona user Nothing Nothing (Just project)
              fallback = selectRoutingPersona user Nothing Nothing Nothing
          check failures "persona precedence is CLI, environment, project, default" $
            fmap selectedPersonaName cli == Right "work"
              && fmap selectedPersonaName env == Right "work"
              && fmap selectedPersonaName projectSelected == Right "personal"
              && fmap selectedPersonaName fallback == Right "personal"
          check failures "project profile replacement stays within persona model allowlist" $
            case projectSelected of
              Right selected ->
                fmap (map realizationV2Model . profileV2Chain) (Map.lookup "deep-thinker" (personaProfiles (selectedPersona selected))) == Just ["opus"]
              Left _ -> False

      let older = read "2026-01-01 00:00:00 UTC" :: UTCTime
          newer = read "2026-02-01 00:00:00 UTC" :: UTCTime
          fetched = read "2026-02-02 00:00:00 UTC" :: UTCTime
          newestModel = ConcreteModel "work-codex" [ModelPrefix "gpt-sol-" (Just ModelNewest)]
          newestEntries =
            [ ModelInventoryEntry "gpt-sol-z" (Just newer),
              ModelInventoryEntry "gpt-sol-old" (Just older),
              ModelInventoryEntry "gpt-sol-a" (Just newer)
            ]
          inventory entries = FrozenInventory InventoryFresh "sha256:fixture" fetched 0 entries
          available entries = InventoryResult (Just "sha256:fixture") (Just (inventory entries)) Nothing
          newestResolved = resolveConcreteModel "rolling" newestModel (available newestEntries)
          reversedResolved = resolveConcreteModel "rolling" newestModel (available (reverse newestEntries))
      check failures "newest selection ignores inventory order and breaks equal timestamps by ascending id" $
        fmap selectedModelId newestResolved == Right "gpt-sol-a" && newestResolved == reversedResolved
      check failures "ambiguous prefixes require explicit ordering" $
        isLeftContaining "ambiguous prefix" (resolveConcreteModel "rolling" (ConcreteModel "work-codex" [ModelPrefix "gpt-sol-" Nothing]) (available newestEntries))
      check failures "newest refuses any ambiguous candidate without normalized creation time" $
        isLeftContaining
          "lacks a creation timestamp"
          (resolveConcreteModel "rolling" newestModel (available [ModelInventoryEntry "gpt-sol-a" (Just newer), ModelInventoryEntry "gpt-sol-z" Nothing]))
      let staticResult =
            resolveConcreteModel
              "static"
              (ConcreteModel "work-codex" [ModelExact "gpt-static"])
              (InventoryResult (Just "sha256:unavailable") Nothing (Just "network-timeout"))
      check failures "exact selectors remain static-unverified without usable inventory" $
        case staticResult of
          Right resolution ->
            selectedModelId resolution == "gpt-static"
              && selectedModelSource resolution == ModelStaticUnverified
              && selectedModelFingerprint resolution == Just "sha256:unavailable"
              && selectedModelWarning resolution == Just "network-timeout"
          Left _ -> False
      check failures "ordered selectors continue after an absent exact id" $
        fmap (\resolution -> (selectedModelSelectorIndex resolution, selectedModelId resolution))
          (resolveConcreteModel "ordered" (ConcreteModel "work-codex" [ModelExact "absent", ModelPrefix "gpt-sol-a" Nothing]) (available newestEntries))
          == Right (2, "gpt-sol-a")

      case selectRoutingPersona user Nothing Nothing Nothing of
        Left problem -> check failures ("default persona resolves: " <> problem) False
        Right selected -> do
          let personalInventory =
                available
                  [ ModelInventoryEntry "claude-opus-5" (Just newer),
                    ModelInventoryEntry "claude-opus-4" (Just older)
                  ]
              inventories = Map.singleton "personal-claude" personalInventory
              authored = Map.singleton "deep-thinker" []
              commandRoutes = routes (BackendAcp "stub") []
              exact = resolveRoutingConfigV2 selected inventories (Map.singleton "deep-thinker#2" "opus-old") commandRoutes authored
          check failures "v2 resolution expands chain axes and freezes complete non-secret provenance" $
            case exact of
              Right resolved ->
                resolvedRoutingPersona resolved == Just "personal"
                  && resolvedRoutingPersonaSource resolved == Just PersonaFromUserDefault
                  && Map.keys (resolvedRealizations resolved) == ["deep-thinker", "deep-thinker#2"]
                  && case (Map.lookup "deep-thinker" (resolvedRealizations resolved), Map.lookup "deep-thinker#2" (resolvedRealizations resolved)) of
                    (Just primary, Just fallback) ->
                      resolvedProfile primary == "deep-thinker"
                        && resolvedRung primary == 1
                        && routerName (resolvedRouter primary) == "personal-claude"
                        && routerProvider (resolvedRouter primary) == "anthropic"
                        && maybe False (T.isPrefixOf "sha256:") (resolvedEngineFingerprint primary)
                        && realizationModel (resolvedSpec primary) == "claude-opus-5"
                        && realizationThinking (resolvedSpec primary) == ThinkMax
                        && case resolvedModelSelection primary of
                          Just provenance ->
                            selectedModelAlias provenance == "opus"
                              && selectedModelEngine provenance == "personal-claude"
                              && selectedModelId provenance == "claude-opus-5"
                              && selectedModelSelectorIndex provenance == 1
                              && selectedModelSource provenance == ModelFromInventory InventoryFresh
                              && selectedModelFingerprint provenance == Just "sha256:fixture"
                              && selectedModelFetchedAt provenance == Just fetched
                              && selectedModelCacheAgeSeconds provenance == Just 0
                          Nothing -> False
                        && realizationModel (resolvedSpec fallback) == "claude-opus-4"
                        && fmap selectedModelAlias (resolvedModelSelection fallback) == Just "opus-old"
                    _ -> False
              Left _ -> False
          check failures "raw route substitution is refused only for a managed v2 axis" $
            isLeftContaining
              "raw --route cannot replace version-2 managed axis"
              (resolveRoutingConfigV2 selected inventories Map.empty (routes (BackendAcp "stub") [("deep-thinker", BackendAcp "other")]) authored)
          check failures "raw routes for unconfigured symbolic names retain legacy behavior" $
            case resolveRoutingConfigV2 selected inventories Map.empty (routes (BackendAcp "stub") [("free", BackendAcp "other")]) (Map.singleton "free" []) of
              Right resolved -> routeNamed (resolvedRoutes resolved) == [("free", BackendAcp "other")]
              Left _ -> False
          check failures "model-alias overrides may not escape the selected persona" $
            isLeftContaining
              "outside persona"
              (resolveRoutingConfigV2 selected inventories (Map.singleton "deep-thinker" "sol") commandRoutes authored)

          actualEnvironment <- Map.fromList <$> getEnvironment
          temporaryDirectory <- getTemporaryDirectory
          (wrapperPath, wrapperHandle) <- openBinaryTempFile temporaryDirectory "agent-cat-environment-adapter.py"
          let capturePath = wrapperPath <> ".capture"
              sentinel = "routing-secret-sentinel-7f3d"
              ambient =
                Map.fromList
                  [ ("PERSONAL_API_KEY", sentinel),
                    ("WORK_API_KEY", "unselected-secret-sentinel"),
                    ("ANTHROPIC_API_KEY", "stale-selected-destination"),
                    ("OPENAI_API_KEY", "stale-unselected-destination"),
                    ("KEEP_ME", "kept"),
                    ("CAPTURE_PATH", capturePath)
                  ]
                  `Map.union` actualEnvironment
              contexts = resolveEngineContexts selected ["personal-claude"] ambient
              missing = resolveEngineContexts selected ["personal-claude"] (Map.delete "PERSONAL_API_KEY" ambient)
          check failures "only engines required by the expanded policy resolve secrets" $
            either (const False) Map.null (resolveEngineContexts selected [] Map.empty)
          check failures "missing selected secrets fail by alias and source name without their value" $
            case missing of
              Left problem -> "personal-key" `T.isInfixOf` problem && "PERSONAL_API_KEY" `T.isInfixOf` problem && not (T.pack sentinel `T.isInfixOf` problem)
              Right _ -> False
          case Map.lookup "personal-claude" =<< either (const Nothing) Just contexts of
            Nothing -> check failures "selected engine environment resolves" False
            Just context -> do
              let child = resolvedEngineChildEnvironment context
                  config =
                    (defaultAcpConfig [wrapperPath])
                      { acpCwd = ".",
                        acpTurnTimeoutMs = 5000,
                        acpChildEnvironment = child
                      }
              check failures "resolved child environments and AcpConfig render without values" $
                not (T.pack sentinel `T.isInfixOf` T.pack (show child))
                  && not (T.pack sentinel `T.isInfixOf` T.pack (show config))
                  && resolvedEngineCredentialReady context
              root <- getCurrentDirectory
              hPutStr
                wrapperHandle
                ( unlines
                    [ "#!/usr/bin/env python3",
                      "import os, sys",
                      "with open(os.environ['CAPTURE_PATH'], 'w') as handle:",
                      "    handle.write(os.environ.get('ANTHROPIC_API_KEY', '') + '\\n')",
                      "    handle.write(('present' if 'PERSONAL_API_KEY' in os.environ else 'absent') + '\\n')",
                      "    handle.write(('present' if 'WORK_API_KEY' in os.environ else 'absent') + '\\n')",
                      "    handle.write(('present' if 'OPENAI_API_KEY' in os.environ else 'absent') + '\\n')",
                      "    handle.write(os.environ.get('KEEP_ME', '') + '\\n')",
                      "os.execv(sys.executable, [sys.executable, " <> show (root </> "engine/acp/test/stub_adapter.py") <> "])"
                    ]
                )
              hClose wrapperHandle
              permissions <- getPermissions wrapperPath
              setPermissions wrapperPath permissions {executable = True}
              captured <-
                (withAcp config (const (pure ())) >> BS.readFile capturePath)
                  `finally` removeFile wrapperPath
              check failures "spawned ACP child receives selected binding and no declared unselected/source variables" $
                captured == BS.pack (sentinel <> "\nabsent\nabsent\nabsent\nkept\n")
              removeFile capturePath

  let privilegedProject = BS.unlines ["version: 2", "persona: personal", "engines: {}"]
      duplicateNested = BS.unlines ["version: 2", "persona: personal", "profiles:", "  deep:", "    chain: []", "    chain: []"]
      duplicateFlow = "version: 2\npersona: personal\nprofiles: {deep: {chain: [], chain: []}}\n"
      mixedUnknown = BS.unlines ["version: 2", "default-persona: personal", "surprise: true", "secrets: {}", "engines: {}", "models: {}", "personas: {}"]
      sensitiveLiteral = BS.unlines ["version: 2", "default-persona: p", "secrets: {}", "engines:", "  e:", "    backend: acp:stub", "    provider: p", "    environment:", "      OPENAI_API_KEY:", "        value: literal", "models:", "  m:", "    engine: e", "    select:", "      - exact: m", "personas:", "  p:", "    engines: [e]", "    models: [m]", "    profiles:", "      deep:", "        chain:", "          - model: m", "            thinking: low", "            max-output: 1"]
      unauthorizedModel = BS.unlines ["version: 2", "default-persona: p", "secrets: {}", "engines:", "  e:", "    backend: acp:stub", "    provider: p", "models:", "  allowed:", "    engine: e", "    select:", "      - exact: allowed", "  denied:", "    engine: e", "    select:", "      - exact: denied", "personas:", "  p:", "    engines: [e]", "    models: [allowed]", "    profiles:", "      deep:", "        chain:", "          - model: denied", "            thinking: low", "            max-output: 1"]
      authenticatedHttp = BS.pack . T.unpack $ T.replace "https://api.anthropic.com/v1/models" "http://127.0.0.1:8080/v1/models" (T.pack (BS.unpack userYaml))
      credentialQuery = BS.pack . T.unpack $ T.replace "https://api.anthropic.com/v1/models" "https://api.anthropic.com/v1/models?api_key=literal" userText
      encodedCredentialQuery = BS.pack . T.unpack $ T.replace "https://api.anthropic.com/v1/models" "https://api.anthropic.com/v1/models?to%6ben=literal" userText
      malformedQuery = BS.pack . T.unpack $ T.replace "https://api.anthropic.com/v1/models" "https://api.anthropic.com/v1/models?name%=literal" userText
      authBlock = "      auth:\n        header: x-api-key\n        secret: personal-key\n"
      unauthenticatedText = T.replace authBlock "" userText
      malformedLoopback = BS.pack . T.unpack $ T.replace "https://api.anthropic.com/v1/models" "http://127.999.1.1:8080/v1/models" unauthenticatedText
      tooLongUrl = BS.pack . T.unpack $ T.replace "https://api.anthropic.com/v1/models" ("https://" <> T.replicate 8200 "a") userText
      tooLongQuery = BS.pack . T.unpack $ T.replace "https://api.anthropic.com/v1/models" ("https://api.anthropic.com/v1/models?q=" <> T.replicate 4097 "x") userText
      tooManyQueryItems = BS.pack . T.unpack $ T.replace "https://api.anthropic.com/v1/models" ("https://api.anthropic.com/v1/models?" <> T.intercalate "&" ["p" <> T.pack (show index) <> "=x" | index <- [1 :: Int .. 65]]) userText
      userText = T.pack (BS.unpack userYaml)
      headerNeedle = "      headers:\n        anthropic-version: '2023-06-01'"
      withHeaders rows = BS.pack . T.unpack $ T.replace headerNeedle ("      headers:\n" <> T.unlines (map ("        " <>) rows)) userText
      tooManyHeaders = withHeaders ["x-fixture-" <> T.pack (show index) <> ": value" | index <- [1 :: Int .. 65]]
      tooLongHeader = withHeaders ["x-fixture: '" <> T.replicate 8193 "x" <> "'"]
      tooManyHeaderBytes = withHeaders ["x-fixture-" <> T.pack (show index) <> ": '" <> T.replicate 8000 "x" <> "'" | index <- [1 :: Int .. 8]]
      badTimeout = BS.pack . T.unpack $ T.replace "timeout-ms: 5000" "timeout-ms: 60001" userText
      badCacheWindow = BS.pack . T.unpack $ T.replace "stale-if-error: 7d" "stale-if-error: 1h" userText
      sharedBackend = BS.unlines ["version: 2", "default-persona: p", "secrets: {}", "engines:", "  e1:", "    backend: acp:stub", "    provider: fixture", "  e2:", "    backend: acp:stub", "    provider: fixture", "models:", "  m:", "    engine: e1", "    select: [{exact: model}]", "personas:", "  p:", "    engines: [e1, e2]", "    models: [m]", "    profiles:", "      deep:", "        chain: [{model: m, thinking: low, max-output: 1}]"]
      providerVariantBackend = BS.pack . T.unpack $ T.replace "  e2:\n    backend: acp:stub\n    provider: fixture" "  e2:\n    backend: acp:stub\n    provider: other" (T.pack (BS.unpack sharedBackend))
      conflictingBackend = BS.pack . T.unpack $ T.replace "  e2:\n    backend: acp:stub\n    provider: fixture" "  e2:\n    backend: acp:stub\n    provider: fixture\n    environment:\n      PROFILE_HOME:\n        value: /tmp/other" (T.pack (BS.unpack sharedBackend))
      conflictingCatalogueBackend = BS.pack . T.unpack $ T.replace "  e2:\n    backend: acp:stub\n    provider: fixture" "  e2:\n    backend: acp:stub\n    provider: fixture\n    catalogue:\n      dialect: openai\n      url: http://127.0.0.1:12345/models\n      timeout-ms: 1000\n      max-bytes: 1024\n      cache:\n        fresh-for: 1h\n        stale-if-error: 1h" (T.pack (BS.unpack sharedBackend))
  check failures "project layer cannot declare engines" $
    isLeftContaining "project routing has unknown field" (decodeRoutingProjectV2 privilegedProject)
  check failures "nested duplicate YAML keys are refused before decode" $
    isLeftContaining "profiles.deep.chain: duplicate YAML key" (decodeRoutingProjectV2 duplicateNested)
  check failures "flow-style duplicate YAML keys are refused before decode" $
    isLeftContaining "duplicate YAML key" (decodeRoutingProjectV2 duplicateFlow)
  check failures "unknown v2 fields are refused" $
    isLeftContaining "unknown field" (decodeRoutingUserV2 mixedUnknown)
  check failures "sensitive environment variables require secret references" $
    isLeftContaining "must use a secret reference" (decodeRoutingUserV2 sensitiveLiteral)
  check failures "authenticated catalogues require HTTPS even on loopback" $
    isLeftContaining "authenticated catalogue URL uses plain HTTP" (decodeRoutingUserV2 authenticatedHttp)
  check failures "catalogue URLs reject credential-shaped query keys" $
    isLeftContaining "credential-shaped query key" (decodeRoutingUserV2 credentialQuery)
      && isLeftContaining "credential-shaped query key" (decodeRoutingUserV2 encodedCredentialQuery)
      && isLeftContaining "malformed percent encoding" (decodeRoutingUserV2 malformedQuery)
  check failures "plain HTTP requires a syntactically valid literal loopback address" $
    isLeftContaining "not a literal loopback address" (decodeRoutingUserV2 malformedLoopback)
  check failures "catalogue URL bytes, query bytes, and query item count are bounded" $
    isLeftContaining "URL exceeds 8192" (decodeRoutingUserV2 tooLongUrl)
      && isLeftContaining "query exceeds 4096" (decodeRoutingUserV2 tooLongQuery)
      && isLeftContaining "more than 64 items" (decodeRoutingUserV2 tooManyQueryItems)
  check failures "catalogue header count, value, and aggregate bytes are bounded" $
    isLeftContaining "more than 64 headers" (decodeRoutingUserV2 tooManyHeaders)
      && isLeftContaining "exceeds 8192 bytes" (decodeRoutingUserV2 tooLongHeader)
      && isLeftContaining "exceed 61440 bytes" (decodeRoutingUserV2 tooManyHeaderBytes)
  check failures "catalogue timeout and cache windows are bounded at decode" $
    isLeftContaining "timeout-ms is outside" (decodeRoutingUserV2 badTimeout)
      && isLeftContaining "shorter than fresh-for" (decodeRoutingUserV2 badCacheWindow)
  check failures "persona model allowlist is independent of engine eligibility" $
    isLeftContaining "outside persona" (decodeRoutingUserV2 unauthorizedModel)
  check failures "shared backends allow provenance variants but require one process definition" $
    either (const False) (const True) (decodeRoutingUserV2 sharedBackend)
      && either (const False) (const True) (decodeRoutingUserV2 providerVariantBackend)
      && isLeftContaining "different process definitions" (decodeRoutingUserV2 conflictingBackend)
      && isLeftContaining "different process definitions" (decodeRoutingUserV2 conflictingCatalogueBackend)

  check failures "legacy v1 decoder is unchanged" $
    case decodeRoutingConfig "version: 1\nrouters: []\nprofiles: []\n" of
      Right config -> Map.null (routingRouters config) && Map.null (routingProfiles config)
      Left _ -> False

  documentedExample <- BS.readFile "cli/model-definitions.example.yaml"
  check failures "documented v2 example decodes and covers every bundled symbolic profile" $
    case decodeRoutingUserV2 documentedExample of
      Left _ -> False
      Right config ->
        let names = concatMap (Map.keys . personaProfiles) (Map.elems (routingV2Personas config))
         in all (`elem` names) ["deep", "balanced", "review", "reasoning", "coding"]

  temporary <- getTemporaryDirectory
  (userPath, userHandle) <- openBinaryTempFile temporary "agent-cat-routing-user.yaml"
  BS.hPut userHandle userYaml
  hClose userHandle
  (projectPath, projectHandle) <- openBinaryTempFile temporary "agent-cat-routing-project.yaml"
  BS.hPut projectHandle projectYaml
  hClose projectHandle
  untaggedV2 <- loadRoutingFiles [userPath, projectPath]
  check failures "untagged v2 files cannot infer privileged authority from document shape" $
    isLeftContaining "requires path-derived user/project authority" untaggedV2
  BS.writeFile userPath "version: 1\nrouters: []\nprofiles: []\n"
  mixed <- loadRoutingFiles [userPath, projectPath]
  check failures "v1 and v2 routing layers cannot be mixed" $
    isLeftContaining "cannot mix version 1 and version 2" mixed
  removeFile userPath
  removeFile projectPath

  count <- readIORef failures
  if count == 0
    then TIO.putStrLn "routing v2 schema probe: all checks passed"
    else TIO.putStrLn ("routing v2 schema probe: " <> T.pack (show count) <> " failed") >> exitFailure
