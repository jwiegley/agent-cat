{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | Bounded subprocess client for descriptor, routing, help, and plan commands.
module Agentic.Tui.Client
  ( InitialData (..),
    loadInitialData,
    loadRoutingSummary,
    loadRunCatalogue,
    loadWorkflowHelp,
    buildLaunchPreview,
    buildLineagePreview,
    decodeFrontendCapabilities,
    invokeRunner,
  )
where

import Agentic.Runtime
  ( CatalogueEntry,
    FrontendManifest (..),
    FrontendServer (..),
    ExactPlanSummary (exactPlanDescriptor),
    LineageOperation,
    RunRecord (..),
    WorkflowDescriptor (..),
    WorkflowInputDescriptor (..),
    capabilityServer,
    capabilityManifestVersions,
    capabilityLegacyManifests,
    closeGroupPipes,
    createProcessGroup,
    decodeExactPlan,
    decodeWorkflowDescriptors,
    groupErrors,
    groupOutput,
    readFrontendInputBytesAt,
    revalidateLineageParentAt,
    listRunCatalogueAt,
    terminateProcessGroup,
    waitProcessGroup,
  )
import qualified Agentic.Runtime as Runtime (decodeFrontendCapabilities)
import Agentic.Tui.Root
import Agentic.Tui.Types
import Control.Concurrent.Async (concurrently)
import Control.Exception (SomeAsyncException, SomeException, bracket, displayException, finally, fromException, throwIO, try)
import Control.Monad (unless)
import Crypto.Hash (Digest, SHA256, hash)
import Data.Aeson (encode)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Text.Encoding.Error (lenientDecode)
import Data.Time.Clock (getCurrentTime)
import GHC.Clock (getMonotonicTimeNSec)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (Handle)
import System.Process
  ( CreateProcess (cwd, env, std_err, std_in, std_out),
    StdStream (NoStream, CreatePipe),
    proc
  )
import System.Timeout (timeout)

maxSubprocessBytes :: Int
maxSubprocessBytes = 4 * 1024 * 1024

subprocessTimeoutMicros :: Int
subprocessTimeoutMicros = 30 * 1000 * 1000

data InitialData = InitialData
  { initialServer :: !FrontendServer,
    initialWorkflows :: ![WorkflowDescriptor],
    initialRuns :: ![CatalogueEntry],
    initialRouting :: !(Either Text RoutingSummary)
  }

decodeFrontendCapabilities :: BS.ByteString -> Either Text FrontendServer
decodeFrontendCapabilities bytes = do
  capabilities <- Runtime.decodeFrontendCapabilities bytes
  unless (capabilityManifestVersions capabilities == [2, 3]) $
    Left "Error in $: frontend manifest capabilities are not versions 2 and 3"
  unless (capabilityLegacyManifests capabilities) $
    Left "Error in $: frontend capability omits legacy manifest support"
  pure (capabilityServer capabilities)

loadRunCatalogue :: TuiConfig -> PrivateRoot -> IO (Either Text [CatalogueEntry])
loadRunCatalogue config root = do
  outcome <- try @SomeException $ do
    assertLocalStateRoot root
    now <- getCurrentTime
    records <- withPrivateDirectoryAt root [] $ \descriptor -> listRunCatalogueAt (tuiStateDir config) descriptor Nothing now
    assertLocalStateRoot root
    pure records
  case outcome of
    Left failure | Just _ <- fromException @SomeAsyncException failure -> throwIO failure
    _ -> pure (either (Left . T.pack . displayException) Right outcome)

loadWorkflowHelp :: TuiConfig -> Text -> IO (Either Text Text)
loadWorkflowHelp config workflow = do
  bytes <- invokeRunner config ["help", T.unpack workflow]
  pure $ do
    output <- bytes
    either (Left . ("workflow help is not UTF-8: " <>) . T.pack . show) Right (TE.decodeUtf8' output)

loadRoutingSummary :: TuiConfig -> Maybe Text -> IO (Either Text RoutingSummary)
loadRoutingSummary config persona = do
  let arguments = ["--routing", "--offline", "--json"] <> maybe [] (\name -> ["--persona", T.unpack name]) persona
  bytes <- invokeRunner config arguments
  pure (bytes >>= decodeRoutingSummary)

loadInitialData :: TuiConfig -> PrivateRoot -> IO (Either Text InitialData)
loadInitialData config root = do
  outcome <- try @SomeException $ do
    assertLocalStateRoot root
    loadInitialDataUnchecked config root
  case outcome of
    Left failure | Just _ <- fromException @SomeAsyncException failure -> throwIO failure
    _ -> pure (either (Left . T.pack . displayException) id outcome)

loadInitialDataUnchecked :: TuiConfig -> PrivateRoot -> IO (Either Text InitialData)
loadInitialDataUnchecked config root = do
  capabilities <- invokeRunner config ["frontend", "--capabilities"]
  case capabilities >>= decodeFrontendCapabilities of
    Left failure -> pure (Left ("capability discovery failed: " <> failure))
    Right server -> do
      descriptors <- invokeRunner config ["list", "--json", "--descriptor-version", "3"]
      case descriptors >>= decodeWorkflowDescriptors of
        Left failure -> pure (Left ("workflow discovery failed: " <> failure))
        Right workflows
          | any ((/= frontendServerRunnerVersion server) . workflowRunnerVersion) workflows ->
              pure (Left "workflow discovery disagrees with capability server version")
          | otherwise -> do
              runsResult <- loadRunCatalogue config root
              case runsResult of
                Left failure -> pure (Left ("run catalogue failed: " <> failure))
                Right runs -> do
                  routing <- loadRoutingSummary config Nothing
                  pure (Right (InitialData server workflows runs routing))

buildLaunchPreview :: TuiConfig -> PrivateRoot -> WorkflowDescriptor -> Map Text Text -> TargetSelection -> IO (Either Text LaunchPreview)
buildLaunchPreview config root descriptor inputs target = do
  outcome <- try @SomeException (buildLaunchPreviewUnchecked config root descriptor inputs target)
  case outcome of
    Left failure | Just _ <- fromException @SomeAsyncException failure -> throwIO failure
    _ -> pure (either (Left . T.pack . displayException) id outcome)

buildLaunchPreviewUnchecked :: TuiConfig -> PrivateRoot -> WorkflowDescriptor -> Map Text Text -> TargetSelection -> IO (Either Text LaunchPreview)
buildLaunchPreviewUnchecked config root descriptor inputs target = do
  assertLocalStateRoot root
  stamp <- getMonotonicTimeNSec
  let components = ["previews", show stamp]
      directory = tuiStateDir config </> "previews" </> show stamp
  ensurePrivateDirectoryAt root ["previews"]
  createPrivateDirectoryAt root components
  (do
      inputFiles <- writeInputs root components directory descriptor inputs
      let arguments =
            ["plan", T.unpack (workflowName descriptor), "--json", "--raw"]
              <> concatMap (\(name, path) -> ["--input-file", T.unpack name <> "=" <> path]) inputFiles
      result <- invokeRunnerWithRoot config (Just root) arguments
      assertLocalStateRoot root
      pure $ do
        bytes <- result
        (plan, program) <- decodeExactPlan bytes
        validateExactPlanIdentity descriptor (exactPlanDescriptor plan)
        pure
          LaunchPreview
            { previewDescriptor = descriptor,
              previewInputs = inputs,
              previewTarget = target,
              previewLineage = Nothing,
              previewRouting = Nothing,
              previewPlan = plan,
              previewProgramHash = sha256 (BL.toStrict (encode program))
            }
    )
    `finally` cleanupPreview root components (length (workflowInputs descriptor))

validateExactPlanIdentity :: WorkflowDescriptor -> WorkflowDescriptor -> Either Text ()
validateExactPlanIdentity catalogue exact
  | workflowRunnerVersion exact /= workflowRunnerVersion catalogue = Left "exact workflow plan runner version changed"
  | workflowName exact /= workflowName catalogue = Left "exact workflow plan names another workflow"
  | workflowBlurb exact /= workflowBlurb catalogue = Left "exact workflow plan description changed"
  | workflowResultCode exact /= workflowResultCode catalogue = Left "exact workflow plan result type changed"
  | workflowInputs exact /= workflowInputs catalogue = Left "exact workflow plan input contract changed"
  | otherwise = Right ()

buildLineagePreview :: TuiConfig -> PrivateRoot -> WorkflowDescriptor -> RunRecord -> LineageOperation -> IO (Either Text LaunchPreview)
buildLineagePreview config root descriptor record operation = case validateStoredInvocation config (recordManifest record) of
  Left failure -> pure (Left failure)
  Right () -> do
    loaded <- try @SomeException $ do
      assertLocalStateRoot root
      components <- privatePathComponents root (recordDirectory record)
      bytes <- withPrivateDirectoryAt root components $ \runDescriptor -> do
        revalidateLineageParentAt record runDescriptor
        readFrontendInputBytesAt record runDescriptor (map workflowInputName (workflowInputs descriptor))
      either (ioError . userError . T.unpack) pure (traverse decodeInput bytes)
    case loaded of
      Left failure | Just _ <- fromException @SomeAsyncException failure -> throwIO failure
      Left failure -> pure (Left ("lineage input validation failed: " <> T.pack (displayException failure)))
      Right inputs
        | workflowName descriptor /= frontendWorkflow (recordManifest record) -> pure (Left "selected run workflow is not present in this runner catalogue")
        | otherwise -> do
            let manifest = recordManifest record
                target = TargetRestored (frontendTargetKind manifest) (frontendTargetArgs manifest)
            preview <- buildLaunchPreview config root descriptor inputs target
            pure $ do
              value <- preview
              if previewProgramHash value /= frontendProgramHash (recordManifest record)
                then Left "current exact-input program does not match the parent program fingerprint"
                else Right value {previewLineage = Just (operation, record)}
  where
    decodeInput bytes = case TE.decodeUtf8' bytes of
      Left failure -> Left ("lineage input is not UTF-8: " <> T.pack (show failure))
      Right value -> Right value

invokeRunner :: TuiConfig -> [String] -> IO (Either Text BS.ByteString)
invokeRunner config = invokeRunnerWithRoot config Nothing

invokeRunnerWithRoot :: TuiConfig -> Maybe PrivateRoot -> [String] -> IO (Either Text BS.ByteString)
invokeRunnerWithRoot config root arguments = do
  environment <- case root of
    Nothing -> pure Nothing
    Just anchor -> do
      assertLocalStateRoot anchor
      ambient <- getEnvironment
      pure (Just (("AGENT_CAT_STATE_ANCHOR", privateRootIdentity anchor) : filter ((/= "AGENT_CAT_STATE_ANCHOR") . fst) ambient))
  let command =
        (proc (tuiRunner config) (tuiRunnerArgs config <> arguments))
          { cwd = Just (tuiWorkingDir config),
            env = environment,
            std_in = NoStream,
            std_out = CreatePipe,
            std_err = CreatePipe
          }
  outcome <- try @SomeException $ timeout subprocessTimeoutMicros $
    bracket (createProcessGroup command) cleanup collect
  case outcome of
    Left failure -> case fromException failure :: Maybe SomeAsyncException of
      Just _ -> throwIO failure
      Nothing -> pure (Left ("runner subprocess failed: " <> T.pack (displayException failure)))
    Right Nothing -> pure (Left "runner subprocess exceeded 30 seconds")
    Right (Just value) -> pure value
  where
    cleanup group = terminateProcessGroup 2000000 group `finally` closeGroupPipes group
    collect group = case (groupOutput group, groupErrors group) of
      (Just output, Just errors) -> do
        (stdoutBytes, stderrBytes) <- concurrently (readBounded output) (readBounded errors)
        exitCode <- waitProcessGroup group
        pure $ case exitCode of
          ExitSuccess -> Right stdoutBytes
          ExitFailure code -> Left ("runner exited " <> T.pack (show code) <> ": " <> redactDiagnostic stderrBytes)
      _ -> pure (Left "runner subprocess did not create output pipes")

readBounded :: Handle -> IO BS.ByteString
readBounded handle = fmap BS.concat (go 0 [])
  where
    go size chunks = do
      chunk <- BS.hGetSome handle 32768
      if BS.null chunk
        then pure (reverse chunks)
        else do
          let next = size + BS.length chunk
          unless (next <= maxSubprocessBytes) (ioError (userError "runner subprocess output exceeds 4194304 bytes"))
          go next (chunk : chunks)

writeInputs :: PrivateRoot -> [FilePath] -> FilePath -> WorkflowDescriptor -> Map Text Text -> IO [(Text, FilePath)]
writeInputs root components directory descriptor inputs =
  traverse writeOne (zip [0 :: Int ..] (workflowInputs descriptor))
  where
    writeOne (index, input) = do
      value <- maybe (ioError (userError ("missing input " <> T.unpack (workflowInputName input)))) pure (Map.lookup (workflowInputName input) inputs)
      let file = show index <> ".txt"
          path = directory </> file
      writePrivateExclusiveAt root (components <> [file]) (TE.encodeUtf8 value)
      pure (workflowInputName input, path)

cleanupPreview :: PrivateRoot -> [FilePath] -> Int -> IO ()
cleanupPreview root components count = do
  assertLocalStateRoot root
  mapM_ (removePrivateFileAt root . (components <>) . pure . (<> ".txt") . show) [0 .. count - 1]
  removePrivateDirectoryAt root components

sha256 :: BS.ByteString -> Text
sha256 bytes = T.pack (show (hash bytes :: Digest SHA256))

redactDiagnostic :: BS.ByteString -> Text
redactDiagnostic =
  T.take 2000
    . T.unlines
    . map redactLine
    . T.lines
    . TE.decodeUtf8With lenientDecode
  where
    redactLine line
      | any (`T.isInfixOf` T.toLower line) ["authorization", "bearer ", "api_key", "api-key", "token=", "password="] = "<redacted diagnostic>"
      | otherwise = line
