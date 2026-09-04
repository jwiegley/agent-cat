{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Agentic.RoutingConfig.V2
import Agentic.RoutingDiscovery
import Agentic.RoutingSecrets (ResolvedEngineContext, resolveEngineContexts)
import Control.Concurrent (threadDelay)
import Control.Exception (bracket, finally)
import Data.Bits ((.&.))
import qualified Data.ByteString as BS
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import Data.X509.CertificateStore (readCertificateStore)
import qualified Data.Text.IO as TIO
import Data.Time.Clock (UTCTime, addUTCTime)
import Network.Connection (TLSSettings (TLSSettings))
import Network.HTTP.Client (Manager, newManager)
import Network.HTTP.Client.TLS (mkManagerSettings)
import Network.TLS (ClientParams (clientShared), Shared (sharedCAStore), defaultParamsClient)
import System.Directory
  ( createDirectory,
    createDirectoryLink,
    doesFileExist,
    getCurrentDirectory,
    getTemporaryDirectory,
    listDirectory,
    removeFile,
    removePathForcibly,
  )
import System.Exit (ExitCode (..), exitFailure)
import System.FilePath (takeDirectory, takeFileName, (</>))
import System.IO (hClose, openBinaryTempFile)
import System.Posix.Files (fileMode, getFileStatus, setFileMode)
import Text.Read (readMaybe)
import System.Process
  ( CreateProcess (..),
    ProcessHandle,
    StdStream (Inherit, NoStream),
    createProcess,
    proc,
    terminateProcess,
    waitForProcess,
  )

check :: IORef Int -> Text -> Bool -> IO ()
check failures label holds =
  if holds
    then TIO.putStrLn ("ok   " <> label)
    else TIO.putStrLn ("FAIL " <> label) >> modifyIORef' failures (+ 1)

main :: IO ()
main = do
  failures <- newIORef 0
  root <- getCurrentDirectory
  temporary <- getTemporaryDirectory
  (marker, markerHandle) <- openBinaryTempFile temporary "agent-cat-discovery"
  hClose markerHandle
  removeFile marker
  createDirectory marker
  let portFile = marker </> "port"
      countFile = marker </> "count"
      controlFile = marker </> "control"
      tlsPortFile = marker </> "tls-port"
      tlsCountFile = marker </> "tls-count"
      tlsControlFile = marker </> "tls-control"
      certificateFile = marker </> "certificate.pem"
      keyFile = marker </> "key.pem"
      cacheHome = marker </> "cache"
      serverScript = root </> "cli/test/model_catalogue_server.py"
  writeFile controlFile ""
  writeFile tlsControlFile ""
  generateCertificate certificateFile keyFile
  ( bracket
      (startServer serverScript portFile countFile controlFile)
      stopServer
      ( \_ ->
          bracket
            (startTlsServer serverScript tlsPortFile tlsCountFile tlsControlFile certificateFile keyFile)
            stopServer
            ( \_ -> do
                tlsManager <- trustedTlsManager certificateFile
                runChecks failures marker cacheHome portFile countFile controlFile tlsPortFile tlsCountFile tlsManager
            )
      )
    )
    `finally` removePathForcibly marker
  count <- readIORef failures
  if count == 0
    then TIO.putStrLn "routing discovery probe: all checks passed"
    else TIO.putStrLn ("routing discovery probe: " <> T.pack (show count) <> " failed") >> exitFailure

startServer :: FilePath -> FilePath -> FilePath -> FilePath -> IO ProcessHandle
startServer script portFile countFile controlFile =
  startServerWith script portFile countFile controlFile []

startTlsServer :: FilePath -> FilePath -> FilePath -> FilePath -> FilePath -> FilePath -> IO ProcessHandle
startTlsServer script portFile countFile controlFile certificateFile keyFile =
  startServerWith script portFile countFile controlFile [certificateFile, keyFile]

startServerWith :: FilePath -> FilePath -> FilePath -> FilePath -> [FilePath] -> IO ProcessHandle
startServerWith script portFile countFile controlFile extraArguments = do
  (_, _, _, process) <-
    createProcess
      (proc "python3" ([script, portFile, countFile, controlFile] <> extraArguments))
        { std_in = NoStream,
          std_out = NoStream,
          std_err = Inherit
        }
  waitForFile 1000 portFile
  pure process

generateCertificate :: FilePath -> FilePath -> IO ()
generateCertificate certificateFile keyFile = do
  (_, _, _, process) <-
    createProcess
      ( proc
          "openssl"
          [ "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256",
            "-keyout", keyFile, "-out", certificateFile, "-days", "1",
            "-subj", "/CN=127.0.0.1",
            "-addext", "subjectAltName=IP:127.0.0.1",
            "-addext", "basicConstraints=critical,CA:TRUE",
            "-addext", "keyUsage=critical,digitalSignature,keyEncipherment,keyCertSign",
            "-addext", "extendedKeyUsage=serverAuth"
          ]
      )
        { std_in = NoStream, std_out = NoStream, std_err = NoStream }
  exitCode <- waitForProcess process
  case exitCode of
    ExitSuccess -> pure ()
    ExitFailure code -> ioError (userError ("openssl certificate fixture failed with exit " <> show code))

trustedTlsManager :: FilePath -> IO Manager
trustedTlsManager certificateFile = do
  store <- readCertificateStore certificateFile >>= maybe (ioError (userError "cannot read generated TLS certificate")) pure
  let defaults = defaultParamsClient "127.0.0.1" ""
      parameters = defaults {clientShared = (clientShared defaults) {sharedCAStore = store}}
  newManager (mkManagerSettings (TLSSettings parameters) Nothing)

stopServer :: ProcessHandle -> IO ()
stopServer process = terminateProcess process >> waitForProcess process >> pure ()

waitForFile :: Int -> FilePath -> IO ()
waitForFile 0 path = ioError (userError ("fixture did not create " <> path))
waitForFile attempts path = do
  present <- doesFileExist path
  if present then pure () else threadDelay 10000 >> waitForFile (attempts - 1) path

runChecks :: IORef Int -> FilePath -> FilePath -> FilePath -> FilePath -> FilePath -> FilePath -> FilePath -> Manager -> IO ()
runChecks failures temporary cacheHome portFile countFile controlFile tlsPortFile tlsCountFile tlsManager = do
  port <- readIntFile portFile
  let now = read "2026-03-01 00:00:00 UTC" :: UTCTime
      oneHour = addUTCTime 3600 now
      twoDays = addUTCTime (2 * 86400) now
      eightDays = addUTCTime (8 * 86400) now
      openai = fixture port "openai" CatalogueOpenAI 5000 4194304 "p"
  case openai of
    Left problem -> check failures ("OpenAI fixture configuration decodes: " <> problem) False
    Right (selected, contexts, engine) -> do
      first <- discoverRoutingInventories DiscoveryNormal cacheHome now selected contexts ["engine"]
      countAfterFirst <- readCount countFile
      check failures "OpenAI response is bounded, normalized, cached, and selected deterministically" $
        case first >>= lookupInventory of
          Right result ->
            countAfterFirst == 1
              && fmap frozenInventorySource (inventoryResultInventory result) == Just InventoryFresh
              && fmap selectedModelId (resolveAlias selected result) == Right "gpt-sol-a"
          Left _ -> False
      let endpointFingerprint = engineCatalogueFingerprint "engine" engine
          engineFingerprint = engineDefinitionFingerprint (selectedRoutingV2 selected) "engine" engine
          path = cacheFileFor cacheHome "p" engineFingerprint
      check failures "selection provenance keeps endpoint fingerprint separate from cache identity" $
        case first >>= lookupInventory of
          Right result -> inventoryResultFingerprint result == Just endpointFingerprint
          Left _ -> False
      cachePresent <- doesFileExist path
      mode <- if cachePresent then fileMode <$> getFileStatus path else pure 0
      bytes <- if cachePresent then BS.readFile path else pure BS.empty
      check failures "cache path is fingerprinted, mode 0600, and omits raw endpoint/credentials" $
        cachePresent
          && mode .&. 0o077 == 0
          && not ("127.0.0.1" `BS.isInfixOf` bytes)
          && not ("fixture-secret" `BS.isInfixOf` bytes)

      fresh <- discoverRoutingInventories DiscoveryNormal cacheHome oneHour selected contexts ["engine"]
      countAfterFresh <- readCount countFile
      check failures "fresh cache avoids network access" $
        countAfterFresh == countAfterFirst
          && sourceOf fresh == Just InventoryFreshCache

      offline <- discoverRoutingInventories DiscoveryOffline cacheHome twoDays selected contexts ["engine"]
      countAfterOffline <- readCount countFile
      check failures "offline uses a permitted cache without constructing a request" $
        countAfterOffline == countAfterFresh
          && sourceOf offline == Just InventoryOfflineCache

      writeFile controlFile "fail\n"
      stale <- discoverRoutingInventories DiscoveryNormal cacheHome twoDays selected contexts ["engine"]
      countAfterStale <- readCount countFile
      check failures "failed normal refresh degrades only to stale-if-error cache" $
        countAfterStale == countAfterOffline + 1
          && sourceOf stale == Just InventoryStaleCache
          && warningOf stale == Just "http-status-503"

      refreshed <- discoverRoutingInventories DiscoveryRefresh cacheHome twoDays selected contexts ["engine"]
      countAfterRefresh <- readCount countFile
      check failures "explicit refresh failure never degrades to stale cache" $
        countAfterRefresh == countAfterStale + 1
          && either (T.isInfixOf "discovery failed: http-status-503") (const False) refreshed

      tooOld <- discoverRoutingInventories DiscoveryOffline cacheHome eightDays selected contexts ["engine"]
      countAfterTooOld <- readCount countFile
      check failures "offline refuses cache older than stale-if-error" $
        countAfterTooOld == countAfterRefresh
          && sourceOf tooOld == Nothing
          && warningOf tooOld == Just "offline-cache-unavailable"

      writeFile controlFile ""
      BS.writeFile path "not-json"
      repaired <- discoverRoutingInventories DiscoveryNormal cacheHome twoDays selected contexts ["engine"]
      countAfterRepair <- readCount countFile
      check failures "corrupt cache is ignored, refreshed, and reported" $
        countAfterRepair == countAfterRefresh + 1
          && sourceOf repaired == Just InventoryFresh
          && warningOf repaired == Just "cache-corrupt"
      BS.writeFile path (BS.replicate (8 * 1024 * 1024 + 1) 120)
      oversized <- discoverRoutingInventories DiscoveryNormal cacheHome twoDays selected contexts ["engine"]
      countAfterOversized <- readCount countFile
      check failures "oversized cache is rejected before JSON allocation and refreshed" $
        countAfterOversized == countAfterRepair + 1
          && sourceOf oversized == Just InventoryFresh
          && warningOf oversized == Just "cache-too-large"
      setFileMode path 0o644
      privateAgain <- discoverRoutingInventories DiscoveryNormal cacheHome (addUTCTime 3600 twoDays) selected contexts ["engine"]
      countAfterPrivate <- readCount countFile
      repairedMode <- fileMode <$> getFileStatus path
      leftovers <- filter (T.isPrefixOf ".inventory.tmp" . T.pack . takeFileName) <$> listDirectory (takeDirectory path)
      check failures "insecure cache permissions force refresh; atomic rewrite restores 0600" $
        countAfterPrivate == countAfterOversized + 1
          && warningOf privateAgain == Just "cache-permissions-are-not-private"
          && repairedMode .&. 0o077 == 0
          && null leftovers

      let unsafeCache = temporary </> "symlink-cache"
          outsideCache = temporary </> "symlink-target"
      createDirectory unsafeCache
      createDirectory outsideCache
      createDirectoryLink outsideCache (unsafeCache </> "agent-cat")
      symlinked <- discoverRoutingInventories DiscoveryRefresh unsafeCache twoDays selected contexts ["engine"]
      outsideEntries <- listDirectory outsideCache
      check failures "cache reads and writes refuse symlinked managed directories" $
        maybe False (\warning -> "cache-directory-unsafe" `T.isInfixOf` warning && "cache-write-failed" `T.isInfixOf` warning) (warningOf symlinked)
          && null outsideEntries

      let otherPersona = fixture port "openai" CatalogueOpenAI 5000 4194304 "other"
      case otherPersona of
        Left problem -> check failures ("second persona fixture decodes: " <> problem) False
        Right (otherSelected, otherContexts, _) -> do
          before <- readCount countFile
          isolated <- discoverRoutingInventories DiscoveryOffline cacheHome twoDays otherSelected otherContexts ["engine"]
          after <- readCount countFile
          check failures "cache cannot cross persona directories" $
            before == after
              && sourceOf isolated == Nothing
              && cacheFileFor cacheHome "p" engineFingerprint /= cacheFileFor cacheHome "other" engineFingerprint

      let changedEngine = engine {engineEnvironment = Map.singleton "PROFILE_HOME" (EnvironmentValue "/tmp/other-profile")}
          changedConfig = (selectedRoutingV2 selected) {routingV2Engines = Map.insert "engine" changedEngine (routingV2Engines (selectedRoutingV2 selected))}
          changedSelected = selected {selectedRoutingV2 = changedConfig}
          changedFingerprint = engineDefinitionFingerprint changedConfig "engine" changedEngine
      case resolveEngineContexts changedSelected ["engine"] Map.empty of
        Left problem -> check failures ("changed engine context resolves: " <> problem) False
        Right changedContexts -> do
          before <- readCount countFile
          changedOffline <- discoverRoutingInventories DiscoveryOffline cacheHome twoDays changedSelected changedContexts ["engine"]
          after <- readCount countFile
          check failures "cache identity includes the complete non-secret engine definition" $
            before == after
              && sourceOf changedOffline == Nothing
              && engineFingerprint /= changedFingerprint
              && cacheFileFor cacheHome "p" engineFingerprint /= cacheFileFor cacheHome "p" changedFingerprint

  writeFile controlFile ""
  let anthropic = fixture port "anthropic" CatalogueAnthropic 5000 4194304 "p"
  case anthropic of
    Left problem -> check failures ("Anthropic fixture configuration decodes: " <> problem) False
    Right (selected, contexts, _) -> do
      before <- readCount countFile
      result <- discoverRoutingInventories DiscoveryRefresh (temporary </> "anthropic-cache") now selected contexts ["engine"]
      after <- readCount countFile
      check failures "Anthropic pagination adds bounded cursor/limit and normalizes ISO creation times" $
        after == before + 2
          && case result >>= lookupInventory of
            Right inventory -> fmap selectedModelId (resolveAlias selected inventory) == Right "claude-a"
            Left _ -> False

  checkFailure failures port temporary countFile "redirects are disabled" "redirect" CatalogueOpenAI 5000 4194304 "redirect-refused"
  checkFailure failures port temporary countFile "non-200 status is classified without response details" "status" CatalogueOpenAI 5000 4194304 "http-status-503"
  checkFailure failures port temporary countFile "malformed JSON is refused" "malformed" CatalogueOpenAI 5000 4194304 "openai-response-malformed"
  checkFailure failures port temporary countFile "response body bound stops oversized payloads" "large" CatalogueOpenAI 5000 128 "response-too-large"
  checkFailure failures port temporary countFile "chunked response streaming stops at the body bound" "chunked-large" CatalogueOpenAI 5000 128 "response-too-large"
  checkFailure failures port temporary countFile "duplicate model ids are refused" "duplicate" CatalogueOpenAI 5000 4194304 "duplicate-model-id"
  checkFailure failures port temporary countFile "model count is bounded" "too-many" CatalogueOpenAI 5000 4194304 "openai-response-malformed"
  checkFailure failures port temporary countFile "model ids are bounded to 512 UTF-8 bytes" "large-id" CatalogueOpenAI 5000 4194304 "model inventory id exceeds 512"
  checkFailure failures port temporary countFile "fractional OpenAI creation times are refused" "bad-created" CatalogueOpenAI 5000 4194304 "openai-response-malformed"
  checkFailure failures port temporary countFile "response timeout is enforced" "slow" CatalogueOpenAI 50 4194304 "network-error"
  checkFailure failures port temporary countFile "pagination must advance" "anthropic-loop" CatalogueAnthropic 5000 4194304 "pagination-did-not-advance"
  checkFailure failures port temporary countFile "duplicate ids across pages are refused" "anthropic-duplicate" CatalogueAnthropic 5000 4194304 "duplicate-model-id"
  checkFailure failures port temporary countFile "nonempty Anthropic pages require matching first/last ids" "anthropic-missing-bounds" CatalogueAnthropic 5000 4194304 "anthropic-response-malformed"
  let itemBoundEndpoint = "anthropic?" <> T.intercalate "&" ["p" <> T.pack (show index) <> "=x" | index <- [1 :: Int .. 64]]
      byteBoundEndpoint = "anthropic?pad=" <> T.replicate 4082 "x"
      urlPrefix = "http://127.0.0.1:" <> T.pack (show port) <> "/"
      urlBoundEndpoint = T.replicate (maxCatalogueUrlBytes - BS.length (encodeUtf8 urlPrefix)) "a"
  checkSynthesizedRequestBound failures port temporary countFile "Anthropic pagination cannot exceed final query-item bound" itemBoundEndpoint "request-query-item-limit"
  checkSynthesizedRequestBound failures port temporary countFile "Anthropic pagination cannot exceed final query-byte bound" byteBoundEndpoint "request-query-byte-limit"
  checkSynthesizedRequestBound failures port temporary countFile "Anthropic pagination cannot exceed final URL bound" urlBoundEndpoint "request-url-limit"

  let pages = fixture port "anthropic-pages" CatalogueAnthropic 5000 4194304 "p"
  case pages of
    Left problem -> check failures ("page-bound fixture decodes: " <> problem) False
    Right (selected, contexts, _) -> do
      before <- readCount countFile
      result <- discoverRoutingInventories DiscoveryNormal (temporary </> "pages-cache") now selected contexts ["engine"]
      after <- readCount countFile
      check failures "pagination is capped at 100 requests" $
        after == before + maxCataloguePages
          && warningOf result == Just "page-limit-exceeded"

  case fixtureWithScheme "https" port "openai" CatalogueOpenAI 5000 4194304 "p" of
    Left problem -> check failures ("TLS fixture decodes: " <> problem) False
    Right (selected, contexts, _) -> do
      result <- discoverRoutingInventories DiscoveryRefresh (temporary </> "tls-cache") now selected contexts ["engine"]
      check failures "HTTPS uses the verifying TLS manager and never downgrades to loopback HTTP" $
        either (T.isInfixOf "discovery failed: network-error") (const False) result

  tlsPort <- readIntFile tlsPortFile
  tlsBefore <- readCount tlsCountFile
  case authenticatedFixture tlsPort CatalogueOpenAI of
    Left problem -> check failures ("authenticated OpenAI TLS fixture: " <> problem) False
    Right (selected, contexts, engine) -> do
      untrusted <- discoverRoutingInventories DiscoveryRefresh (temporary </> "untrusted-openai-cache") now selected contexts ["engine"]
      check failures "standard TLS manager rejects an untrusted local certificate" $
        either (T.isInfixOf "discovery failed: network-error") (const False) untrusted
      case resolveEngineContexts selected ["engine"] (Map.singleton "FIXTURE_CATALOGUE_SECRET" (replicate 8193 's')) of
        Left problem -> check failures ("oversized auth context resolves: " <> problem) False
        Right oversizedContexts -> do
          before <- readCount tlsCountFile
          oversized <- discoverRoutingInventoriesWithManager (Just tlsManager) DiscoveryRefresh (temporary </> "oversized-auth-cache") now selected oversizedContexts ["engine"]
          after <- readCount tlsCountFile
          check failures "resolved authentication headers are bounded before request" $
            before == after
              && either (T.isInfixOf "discovery failed: request-header-value-limit") (const False) oversized
      case engineCatalogue engine of
        Nothing -> check failures "authenticated catalogue remains available" False
        Just catalogue -> do
          let crowdedEngine = engine {engineCatalogue = Just catalogue {catalogueHeaders = Map.fromList [("x-fixture-" <> T.pack (show index), "v") | index <- [1 :: Int .. 63]]}}
              crowdedConfig = (selectedRoutingV2 selected) {routingV2Engines = Map.insert "engine" crowdedEngine (routingV2Engines (selectedRoutingV2 selected))}
              crowdedSelected = selected {selectedRoutingV2 = crowdedConfig}
          case resolveEngineContexts crowdedSelected ["engine"] (Map.singleton "FIXTURE_CATALOGUE_SECRET" "fixture-secret") of
            Left problem -> check failures ("crowded header context resolves: " <> problem) False
            Right crowdedContexts -> do
              before <- readCount tlsCountFile
              crowded <- discoverRoutingInventoriesWithManager (Just tlsManager) DiscoveryRefresh (temporary </> "crowded-header-cache") now crowdedSelected crowdedContexts ["engine"]
              after <- readCount tlsCountFile
              check failures "literal, auth, and generated headers share the final count bound" $
                before == after
                  && either (T.isInfixOf "discovery failed: request-header-count-limit") (const False) crowded
          let aggregateEngine = engine {engineCatalogue = Just catalogue {catalogueHeaders = Map.fromList [("x-large-" <> T.pack (show index), T.replicate 8000 "x") | index <- [1 :: Int .. 7]]}}
              aggregateConfig = (selectedRoutingV2 selected) {routingV2Engines = Map.insert "engine" aggregateEngine (routingV2Engines (selectedRoutingV2 selected))}
              aggregateSelected = selected {selectedRoutingV2 = aggregateConfig}
          case resolveEngineContexts aggregateSelected ["engine"] (Map.singleton "FIXTURE_CATALOGUE_SECRET" (replicate 6000 's')) of
            Left problem -> check failures ("aggregate header context resolves: " <> problem) False
            Right aggregateContexts -> do
              before <- readCount tlsCountFile
              aggregate <- discoverRoutingInventoriesWithManager (Just tlsManager) DiscoveryRefresh (temporary </> "aggregate-header-cache") now aggregateSelected aggregateContexts ["engine"]
              after <- readCount tlsCountFile
              check failures "literal and resolved authentication headers share the final byte bound" $
                before == after
                  && either (T.isInfixOf "discovery failed: request-header-byte-limit") (const False) aggregate
      result <- discoverRoutingInventoriesWithManager (Just tlsManager) DiscoveryRefresh (temporary </> "authenticated-openai-cache") now selected contexts ["engine"]
      tlsAfterOpenAI <- readCount tlsCountFile
      let engineFingerprint = engineDefinitionFingerprint (selectedRoutingV2 selected) "engine" engine
          cachePath = cacheFileFor (temporary </> "authenticated-openai-cache") "p" engineFingerprint
      cacheBytes <- BS.readFile cachePath
      check failures "trusted local TLS sends bearer auth and selects OpenAI inventory" $
        tlsAfterOpenAI == tlsBefore + 1
          && sourceOf result == Just InventoryFresh
          && case result >>= lookupInventory of
            Right inventory -> fmap selectedModelId (resolveAlias selected inventory) == Right "gpt-sol-a"
            Left _ -> False
      check failures "authenticated cache stores fingerprints but no secret or endpoint" $
        not ("fixture-secret" `BS.isInfixOf` cacheBytes)
          && not ("127.0.0.1" `BS.isInfixOf` cacheBytes)
  case authenticatedFixture tlsPort CatalogueAnthropic of
    Left problem -> check failures ("authenticated Anthropic TLS fixture: " <> problem) False
    Right (selected, contexts, _) -> do
      before <- readCount tlsCountFile
      result <- discoverRoutingInventoriesWithManager (Just tlsManager) DiscoveryRefresh (temporary </> "authenticated-anthropic-cache") now selected contexts ["engine"]
      after <- readCount tlsCountFile
      check failures "trusted local TLS sends raw x-api-key auth across Anthropic pagination" $
        after == before + 2
          && case result >>= lookupInventory of
            Right inventory -> fmap selectedModelId (resolveAlias selected inventory) == Right "claude-a"
            Left _ -> False

  let baseFixture = fixture port "openai" CatalogueOpenAI 5000 4194304 "p"
      changedFixture = fixture port "status" CatalogueOpenAI 5000 4194304 "p"
  check failures "endpoint and complete engine fingerprints are stable and definition-sensitive" $
    case (baseFixture, changedFixture) of
      (Right (firstSelected, _, firstEngine), Right (secondSelected, _, secondEngine)) ->
        engineCatalogueFingerprint "engine" firstEngine == engineCatalogueFingerprint "engine" firstEngine
          && engineCatalogueFingerprint "engine" firstEngine /= engineCatalogueFingerprint "engine" secondEngine
          && engineDefinitionFingerprint (selectedRoutingV2 firstSelected) "engine" firstEngine
            /= engineDefinitionFingerprint (selectedRoutingV2 secondSelected) "engine" secondEngine
      _ -> False

checkFailure :: IORef Int -> Int -> FilePath -> FilePath -> Text -> Text -> CatalogueDialect -> Int -> Int -> Text -> IO ()
checkFailure failures port temporary _ label endpoint dialect timeoutMs maximumBytes expected =
  case fixture port endpoint dialect timeoutMs maximumBytes "p" of
    Left problem -> check failures (label <> " (fixture: " <> problem <> ")") False
    Right (selected, contexts, _) -> do
      result <- discoverRoutingInventories DiscoveryNormal (temporary </> "failure-" <> T.unpack endpoint) (read "2026-03-01 00:00:00 UTC") selected contexts ["engine"]
      check failures label $ maybe False (T.isInfixOf expected) (warningOf result)

checkSynthesizedRequestBound :: IORef Int -> Int -> FilePath -> FilePath -> Text -> Text -> Text -> IO ()
checkSynthesizedRequestBound failures port temporary countFile label endpoint expected =
  case fixture port endpoint CatalogueAnthropic 5000 4194304 "p" of
    Left problem -> check failures (label <> " (fixture: " <> problem <> ")") False
    Right (selected, contexts, _) -> do
      before <- readCount countFile
      result <- discoverRoutingInventories DiscoveryRefresh (temporary </> "synthesized-" <> T.unpack expected) (read "2026-03-01 00:00:00 UTC") selected contexts ["engine"]
      after <- readCount countFile
      check failures label $
        before == after && either (T.isInfixOf ("discovery failed: " <> expected)) (const False) result

authenticatedFixture :: Int -> CatalogueDialect -> Either Text (SelectedRoutingV2, Map.Map Text ResolvedEngineContext, EngineDefinition)
authenticatedFixture port dialect = do
  (selected, _, engine) <- fixtureWithScheme "https" port endpoint dialect 5000 4194304 "p"
  catalogue <- maybe (Left "authenticated fixture catalogue missing") Right (engineCatalogue engine)
  let secretName = "fixture-auth"
      auth = case dialect of
        CatalogueOpenAI -> CatalogueAuth "authorization" CatalogueAuthBearer secretName
        CatalogueAnthropic -> CatalogueAuth "x-api-key" CatalogueAuthRaw secretName
      authenticatedEngine = engine {engineCatalogue = Just catalogue {catalogueAuth = Just auth}}
      config =
        (selectedRoutingV2 selected)
          { routingV2Secrets = Map.singleton secretName (SecretEnvironment "FIXTURE_CATALOGUE_SECRET"),
            routingV2Engines = Map.insert "engine" authenticatedEngine (routingV2Engines (selectedRoutingV2 selected))
          }
      authenticatedSelected = selected {selectedRoutingV2 = config}
  contexts <- resolveEngineContexts authenticatedSelected ["engine"] (Map.singleton "FIXTURE_CATALOGUE_SECRET" "fixture-secret")
  pure (authenticatedSelected, contexts, authenticatedEngine)
  where
    endpoint = case dialect of
      CatalogueOpenAI -> "openai"
      CatalogueAnthropic -> "anthropic"

fixture :: Int -> Text -> CatalogueDialect -> Int -> Int -> Text -> Either Text (SelectedRoutingV2, Map.Map Text ResolvedEngineContext, EngineDefinition)
fixture = fixtureWithScheme "http"

fixtureWithScheme :: Text -> Int -> Text -> CatalogueDialect -> Int -> Int -> Text -> Either Text (SelectedRoutingV2, Map.Map Text ResolvedEngineContext, EngineDefinition)
fixtureWithScheme scheme port endpoint dialect timeoutMs maximumBytes personaName = do
  config <- decodeRoutingUserV2 (encodeUtf8 yaml)
  selected <- selectRoutingPersona config Nothing Nothing Nothing
  contexts <- resolveEngineContexts selected ["engine"] Map.empty
  engine <- maybe (Left "fixture engine missing") Right (Map.lookup "engine" (routingV2Engines config))
  pure (selected, contexts, engine)
  where
    dialectText = case dialect of
      CatalogueOpenAI -> "openai"
      CatalogueAnthropic -> "anthropic"
    prefix = case dialect of
      CatalogueOpenAI -> "gpt-sol-"
      CatalogueAnthropic -> "claude-"
    headers = case dialect of
      CatalogueOpenAI -> []
      CatalogueAnthropic -> ["      headers:", "        anthropic-version: '2023-06-01'"]
    yaml =
      T.unlines $
        [ "version: 2",
          "default-persona: " <> personaName,
          "secrets: {}",
          "engines:",
          "  engine:",
          "    backend: acp:stub",
          "    provider: fixture",
          "    catalogue:",
          "      dialect: " <> dialectText,
          "      url: " <> scheme <> "://127.0.0.1:" <> T.pack (show port) <> "/" <> endpoint
        ]
          <> headers
          <> [ "      timeout-ms: " <> T.pack (show timeoutMs),
               "      max-bytes: " <> T.pack (show maximumBytes),
               "      cache:",
               "        fresh-for: 24h",
               "        stale-if-error: 7d",
               "models:",
               "  rolling:",
               "    engine: engine",
               "    select:",
               "      - prefix: " <> prefix,
               "        order: newest",
               "personas:",
               "  " <> personaName <> ":",
               "    engines: [engine]",
               "    models: [rolling]",
               "    profiles:",
               "      deep:",
               "        chain:",
               "          - model: rolling",
               "            thinking: high",
               "            max-output: 65536"
             ]

resolveAlias :: SelectedRoutingV2 -> InventoryResult -> Either Text ResolvedModelSelection
resolveAlias selected inventory = do
  model <- maybe (Left "fixture model missing") Right (Map.lookup "rolling" (routingV2Models (selectedRoutingV2 selected)))
  resolveConcreteModel "rolling" model inventory

lookupInventory :: Map.Map Text InventoryResult -> Either Text InventoryResult
lookupInventory inventories = maybe (Left "fixture inventory missing") Right (Map.lookup "engine" inventories)

sourceOf :: Either Text (Map.Map Text InventoryResult) -> Maybe InventorySource
sourceOf result = do
  inventories <- either (const Nothing) Just result
  inventory <- Map.lookup "engine" inventories >>= inventoryResultInventory
  pure (frozenInventorySource inventory)

warningOf :: Either Text (Map.Map Text InventoryResult) -> Maybe Text
warningOf result = do
  inventories <- either (const Nothing) Just result
  Map.lookup "engine" inventories >>= inventoryResultWarning

readCount :: FilePath -> IO Int
readCount = readIntFile


readIntFile :: FilePath -> IO Int
readIntFile = go (200 :: Int)
  where
    go 0 path = ioError (userError ("fixture did not write an integer to " <> path))
    go attempts path = do
      contents <- readFile path
      case readMaybe contents of
        Just value -> pure value
        Nothing -> threadDelay 1000 >> go (attempts - 1) path
