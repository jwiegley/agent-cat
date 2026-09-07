{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Agentic.RoutingConfig
import Control.Concurrent (threadDelay)
import Control.Exception (bracket, finally)
import Data.Bits ((.&.))
import qualified Data.ByteString as BS
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import qualified Data.Text.IO as TIO
import Data.Time.Clock (UTCTime, addUTCTime)
import System.Directory
  ( createDirectory,
    doesFileExist,
    getCurrentDirectory,
    getTemporaryDirectory,
    listDirectory,
    removeFile,
    removePathForcibly,
  )
import System.Exit (exitFailure)
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
      cacheHome = marker </> "cache"
      serverScript = root </> "cli/test/model_catalogue_server.py"
  writeFile controlFile ""
  bracket
    (startServer serverScript portFile countFile controlFile)
    stopServer
    (\_ -> runChecks failures marker cacheHome portFile countFile controlFile)
    `finally` removePathForcibly marker
  count <- readIORef failures
  if count == 0
    then TIO.putStrLn "routing discovery probe: all checks passed"
    else TIO.putStrLn ("routing discovery probe: " <> T.pack (show count) <> " failed") >> exitFailure

startServer :: FilePath -> FilePath -> FilePath -> FilePath -> IO ProcessHandle
startServer script portFile countFile controlFile = do
  (_, _, _, process) <-
    createProcess
      (proc "python3" [script, portFile, countFile, controlFile])
        { std_in = NoStream,
          std_out = NoStream,
          std_err = Inherit
        }
  waitForFile 1000 portFile
  pure process

stopServer :: ProcessHandle -> IO ()
stopServer process = terminateProcess process >> waitForProcess process >> pure ()

waitForFile :: Int -> FilePath -> IO ()
waitForFile 0 path = ioError (userError ("fixture did not create " <> path))
waitForFile attempts path = do
  present <- doesFileExist path
  if present then pure () else threadDelay 10000 >> waitForFile (attempts - 1) path

runChecks :: IORef Int -> FilePath -> FilePath -> FilePath -> FilePath -> FilePath -> IO ()
runChecks failures temporary cacheHome portFile countFile controlFile = do
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
      let fingerprint = engineCatalogueFingerprint "engine" engine
          path = cacheFileFor cacheHome "p" fingerprint
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
      setFileMode path 0o644
      privateAgain <- discoverRoutingInventories DiscoveryNormal cacheHome (addUTCTime 3600 twoDays) selected contexts ["engine"]
      countAfterPrivate <- readCount countFile
      repairedMode <- fileMode <$> getFileStatus path
      leftovers <- filter (T.isPrefixOf ".inventory.tmp" . T.pack . takeFileName) <$> listDirectory (takeDirectory path)
      check failures "insecure cache permissions force refresh; atomic rewrite restores 0600" $
        countAfterPrivate == countAfterRepair + 1
          && warningOf privateAgain == Just "cache-permissions-are-not-private"
          && repairedMode .&. 0o077 == 0
          && null leftovers

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
              && cacheFileFor cacheHome "p" fingerprint /= cacheFileFor cacheHome "other" fingerprint

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
  checkFailure failures port temporary countFile "duplicate model ids are refused" "duplicate" CatalogueOpenAI 5000 4194304 "duplicate-model-id"
  checkFailure failures port temporary countFile "model count is bounded" "too-many" CatalogueOpenAI 5000 4194304 "openai-response-malformed"
  checkFailure failures port temporary countFile "model ids are bounded to 512 UTF-8 bytes" "large-id" CatalogueOpenAI 5000 4194304 "model inventory id exceeds 512"
  checkFailure failures port temporary countFile "fractional OpenAI creation times are refused" "bad-created" CatalogueOpenAI 5000 4194304 "openai-response-malformed"
  checkFailure failures port temporary countFile "response timeout is enforced" "slow" CatalogueOpenAI 50 4194304 "network-error"
  checkFailure failures port temporary countFile "pagination must advance" "anthropic-loop" CatalogueAnthropic 5000 4194304 "pagination-did-not-advance"
  checkFailure failures port temporary countFile "duplicate ids across pages are refused" "anthropic-duplicate" CatalogueAnthropic 5000 4194304 "duplicate-model-id"

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

  let baseEngine = either (const Nothing) (Just . third) (fixture port "openai" CatalogueOpenAI 5000 4194304 "p")
      changedEngine = either (const Nothing) (Just . third) (fixture port "status" CatalogueOpenAI 5000 4194304 "p")
  check failures "endpoint fingerprint is stable and changes with catalogue definition" $
    case (baseEngine, changedEngine) of
      (Just firstEngine, Just secondEngine) ->
        engineCatalogueFingerprint "engine" firstEngine == engineCatalogueFingerprint "engine" firstEngine
          && engineCatalogueFingerprint "engine" firstEngine /= engineCatalogueFingerprint "engine" secondEngine
      _ -> False

checkFailure :: IORef Int -> Int -> FilePath -> FilePath -> Text -> Text -> CatalogueDialect -> Int -> Int -> Text -> IO ()
checkFailure failures port temporary _ label endpoint dialect timeoutMs maximumBytes expected =
  case fixture port endpoint dialect timeoutMs maximumBytes "p" of
    Left problem -> check failures (label <> " (fixture: " <> problem <> ")") False
    Right (selected, contexts, _) -> do
      result <- discoverRoutingInventories DiscoveryNormal (temporary </> "failure-" <> T.unpack endpoint) (read "2026-03-01 00:00:00 UTC") selected contexts ["engine"]
      check failures label $ maybe False (T.isInfixOf expected) (warningOf result)

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

third :: (a, b, c) -> c
third (_, _, value) = value
