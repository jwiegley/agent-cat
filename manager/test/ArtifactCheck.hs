{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
module Main (main) where

import Agentic.Manager.Artifacts
import Agentic.Manager.Approval (readPreparation, withPreparation)
import qualified Agentic.Manager.Drafts as Drafts
import Agentic.Manager.Test.PrivateLog (withPrivateStderr, recordCount)
import Agentic.Manager.Fault
import Agentic.Manager.Fault.Record (faultLine)
import qualified Agentic.Manager.Overview as Overview
import Agentic.Manager.Pages (newPageSets, reservePageSet)
import qualified Agentic.Manager.Protocol.Preparation as P
import qualified Agentic.Manager.Transport as Transport
import Agentic.Manager.Worker.State (WorkerFailure (WorkerUnexpectedExit))
import qualified Agentic.Manager.Admission as Admission
import qualified Agentic.Manager.Service as Service
import Agentic.Manager.Protocol.Artifact (validExportDocument)
import Agentic.Manager.Credentials (administerCredentials)
import qualified Agentic.Manager.Protocol.LocalAdmin as Admin
import Agentic.Manager.Authorization
import qualified Agentic.Manager.Commands as Commands
import Agentic.Manager.Configuration
import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (atomically)
import Control.Exception (ErrorCall (..), SomeException, toException)
import qualified Data.ByteString.Builder as Builder
import qualified Data.Text.Encoding as TE
import Data.Time (getCurrentTime)
import qualified Network.HTTP.Types as HTTP
import qualified Network.Wai as Wai
import Network.Wai.Internal (ResponseReceived (..))
import Agentic.Manager.Profile (Diagnostic (..), publicId)
import qualified Agentic.Manager.Protocol.Command as Command
import Agentic.Manager.State
import qualified Agentic.Manager.Observation as Observation
import qualified Agentic.Manager.Events as Events
import Agentic.Manager.Schema (schemaVersion, schemaStatements, commandMigration, draftMigration, admissionMigration, approvalMigration, ingestionMigration, controlMigration)
import Agentic.Manager.Store
import Agentic.Runtime hiding (Checkpoint)
import Control.Concurrent.Async (AsyncCancelled (..), async, cancel, concurrently, wait, waitCatch, withAsync)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.DeepSeq (NFData, force)
import Control.Exception (IOException, bracket, evaluate, fromException, throwIO, try)
import Control.Monad (forM_, unless, void)
import Crypto.Hash (Digest, SHA256, hash)
import Data.Aeson (Value (..), object, (.=), eitherDecodeStrict')
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import Data.ByteArray (convert)
import Data.Foldable (toList)
import Data.IORef (newIORef, readIORef, writeIORef)
import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as T
import qualified Database.SQLite3 as SQL
import System.Directory (createDirectory, renameDirectory, renameFile, removeFile)
import System.Environment (getArgs)
import System.FilePath ((</>))
import System.IO (hSetBuffering, stdout, BufferMode (LineBuffering))
import System.IO.Error (isDoesNotExistError, isPermissionError)
import System.Posix.Files (createSymbolicLink, setFileMode)
import System.Timeout (timeout)

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  args <- getArgs
  case args of
    ["retention",work] -> retentionChecks work
    ["composition",work] -> compositionChecks work
    ["observation",work] -> observationChecks work
    ["events",work] -> eventChecks work
    ["admission-contention",work] -> admissionContentionChecks work
    ["response-order",work] -> responseOrderChecks work
    ["fault-classification",work] -> faultClassificationChecks work
    [work,source] -> do
      createDirectory(work </> "composition")
      compositionChecks(work </> "composition")
      createDirectory(work </> "retention")
      retentionChecks(work </> "retention")
      createDirectory(work </> "observation")
      observationChecks(work </> "observation")
      createDirectory(work </> "events")
      eventChecks(work </> "events")
      createDirectory(work </> "admission-contention")
      admissionContentionChecks(work </> "admission-contention")
      createDirectory(work </> "response-order")
      responseOrderChecks(work </> "response-order")
      createDirectory(work </> "fault-classification")
      faultClassificationChecks(work </> "fault-classification")
      artifactChecks work source
    _ -> error "usage: manager-artifact-check [retention|composition|observation|events|admission-contention|response-order|fault-classification] PRIVATE_DIRECTORY [PACKAGE_DIRECTORY]"

-- Each converted cause site keeps its own class or records its own erased
-- cause, genuine Store failures keep the storage-unavailable problem, and the
-- private record holds no exception text.
faultClassificationChecks :: FilePath -> IO ()
faultClassificationChecks work = do
  let classOf :: SomeException -> FaultClass
      classOf = classifyFault
      marker = "synthetic-token"
      markerBytes = TE.encodeUtf8 (T.pack marker)
      storageUnavailable = Left (CommandRefusal Command.StorageUnavailable)
  check "an unexpected exception keeps its own type" (classOf (toException (ErrorCall marker)) == UnexpectedFault "ErrorCall")
  check "an I/O exception keeps its fixed error type" (classOf (toException (userError marker)) == UnexpectedFault "IOException user error")
  check "Store contention remains a Store refusal" (classOf (toException StoreBusy) == StoreRefusal StoreBusy)
  check "a Store I/O failure remains a Store refusal" (classOf (toException StoreUnavailable) == StoreRefusal StoreUnavailable)
  check "a configuration diagnostic keeps its own class" (classOf (toException InvalidConfiguration) == ConfigurationFault InvalidConfiguration)
  check "a worker failure keeps its own class" (classOf (toException WorkerUnexpectedExit) == WorkerRefusal WorkerUnexpectedExit)
  check "an internal cause keeps its own class" (classOf (toException ConfigurationBusy) == InternalFault ConfigurationBusy)
  check "a declared refusal keeps its own public problem" (faultProblem (classOf (toException Command.Forbidden)) == (403,"insufficient-scope"))
  check "Store contention and Store I/O keep the public storage-unavailable problem"
    (all ((== (503,"storage-unavailable")) . faultProblem) [StoreRefusal StoreBusy, StoreRefusal StoreUnavailable])
  check "every other class uses the declared storage-unavailable problem"
    (all ((== (503,"storage-unavailable")) . faultProblem)
      [UnexpectedFault "ErrorCall", ConfigurationFault InvalidConfiguration, WorkerRefusal WorkerUnexpectedExit, InternalFault ConfigurationBusy])
  let classes = [classOf (toException (ErrorCall marker)), StoreRefusal StoreBusy, StoreRefusal StoreUnavailable,
        ConfigurationFault InvalidConfiguration, WorkerRefusal WorkerUnexpectedExit, InternalFault ConfigurationBusy,
        InternalFault (ConfigurationRefused InvalidConfiguration), InternalFault AuthorizationChanged,
        InternalFault PageSetCollision, InternalFault ResponseWriteTimeout, InternalFault DeadlineElapsed,
        InternalFault AdmissionStopping, InternalFault AdmissionStoreInactive, InternalFault AdmissionCapacity,
        CommandRefusal Command.StorageUnavailable]
  check "each class has a distinct private label" (length (distinctText (map faultLabel classes)) == length classes)
  now <- getCurrentTime
  check "the private record holds no exception text"
    (not (T.pack marker `T.isInfixOf` faultLine now "context" (faultLabel (classOf (toException (ErrorCall marker))))))
  ((busyLoan, refusedLoan, deadline), loanRecord) <- withPrivateStderr (work </> "loan-stderr.log") $ do
    busyLoan <- faultOf (configurationLoan "check loan" (Left SupervisionUnavailable :: Either Diagnostic ()))
    refusedLoan <- faultOf (configurationLoan "check loan" (Left InvalidConfiguration :: Either Diagnostic ()))
    deadline <- faultOf (Drafts.timed 1000 (threadDelay 1000000))
    pure (busyLoan, refusedLoan, deadline)
  check "an unsuccessful configuration loan keeps the declared refusal" (busyLoan == storageUnavailable && refusedLoan == storageUnavailable)
  check "an unacquired configuration guard is recorded as configuration contention"
    (recordCount loanRecord "check loan class=internal ConfigurationBusy erased=command StorageUnavailable" == 1)
  check "another configuration diagnostic is recorded distinctly"
    (recordCount loanRecord "check loan class=internal ConfigurationRefused InvalidConfiguration erased=command StorageUnavailable" == 1)
  check "a draft deadline keeps the declared refusal" (deadline == storageUnavailable)
  check "a draft deadline is recorded as an elapsed deadline"
    (recordCount loanRecord "drafts deadline class=internal DeadlineElapsed erased=command StorageUnavailable" == 1)
  ((), undeclaredRecord) <- withPrivateStderr (work </> "undeclared-stderr.log") $ do
    recordUndeclaredRefusal "check preparation" (toException Command.Forbidden)
    recordUndeclaredRefusal "check preparation" (toException WorkerUnexpectedExit)
  check "an undeclared failure is recorded by its own class"
    (recordCount undeclaredRecord "check preparation class=worker WorkerUnexpectedExit erased=command StorageUnavailable" == 1)
  check "a declared command refusal is not recorded as an erasure"
    (length (T.lines (TE.decodeUtf8 undeclaredRecord)) == 1)
  pages <- newPageSets
  atomically (reservePageSet pages "client_1" "view" "/v1/profiles" 2 0 "set_a")
  collided <- faultOf (atomically (reservePageSet pages "client_2" "view" "/v1/profiles" 2 0 "set_a"))
  check "a reserved page-set identifier is an internal collision" (collided == Left (InternalFault PageSetCollision))
  atomically (reservePageSet pages "client_2" "view" "/v1/profiles" 2 0 "set_b")
  quota <- faultOf (atomically (reservePageSet pages "client_3" "view" "/v1/profiles" 2 0 "set_c"))
  check "page-set capacity keeps the declared quota refusal" (quota == Left (CommandRefusal Command.StorageQuota))
  stalled <- faultOf (Transport.respondBytes HTTP.status200 [] (pure ()) "bytes" $ \response -> do
    let (_, _, withBody) = Wai.responseToStream response
    withBody (\body -> body (\_ -> threadDelay 10000000) (pure ()))
    pure ResponseReceived)
  check "a stalled response write is its own internal cause" (fmap (const ()) stalled == Left (InternalFault ResponseWriteTimeout))
  createDirectory (work </> "sites")
  (config,_) <- fixture (work </> "sites")
  escaped <- withInstalled config $ \installed -> withCoordinationStore installed $ \store -> do
    seed store
    proof <- authenticateCredential store bearer >>= right
    contended <- withHeldGate store (faultOf (authenticateCredential store bearer >>= right))
    check "authentication preserves typed Store contention" (fmap (const ()) contended == Left (StoreRefusal StoreBusy))
    streams <- Events.newStreamReaders
    start <- Events.withBoundary store proof (\_ cursor _ -> pure cursor) (\_ _ cursor -> pure cursor)
    (sites, siteRecord) <- withPrivateStderr (work </> "sites-stderr.log") $ do
      reader <- withStoreConfiguration store $ \_ _ -> faultOf (withStoreReader store (pure ()))
      observed <- withStoreAuthorizationWatch store $ \watch ->
        faultOf (withAuthorizationObservation watch (mutate store (execute "UPDATE clients SET retired=0 WHERE id='client_1'" [])))
      callback <- withStoreConfiguration store (\_ _ -> ioError (userError marker) :: IO ())
      responseLoan <- faultOf (withAuthorizedResponse store proof "profile_1" [Command.Observe] (\_ -> throwIO ProcessFailure :: IO ()))
      catalogue <- faultOf (withAuthorizedCatalogueContext store proof [Command.Observe] (\_ _ _ _ _ -> throwIO ProcessFailure :: IO ()))
      borrowed <- withStoreAuthorizationWatch store $ \watch -> withStoreConfiguration store $ \_ _ ->
        faultOf (withBorrowedAuthorizedCatalogues watch proof [Command.Observe] (\_ _ _ _ -> pure ()))
      available <- withStoreAuthorizationWatch store $ \watch ->
        faultOf (withBorrowedAuthorizedCatalogues watch proof [Command.Observe] (\_ _ _ _ -> pure ()))
      viewFacts <- withAuthorizedView store proof "profile_1" [Command.Observe] $ \view ->
        withStoreConfiguration store (\_ _ -> revalidateAuthorizedView view)
      preparationRead <- withStoreConfiguration store $ \_ _ -> fmap (const ()) <$> readPreparation store proof "preparation_1"
      operation <- Admission.withAdmission store $ \controller ->
        withHeldGate store (fmap (const ()) <$> Admission.pollAdmission controller)
      streamed <- faultOf (Events.withStream streams store proof start $ \pump -> pump (\_ _ -> pure ()) (\_ -> threadDelay 7000000))
      pure (reader, observed, callback, responseLoan, catalogue, borrowed, available, viewFacts, preparationRead, operation, streamed)
    let (reader, observed, callback, responseLoan, catalogue, borrowed, available, viewFacts, preparationRead, operation, streamed) = sites
        erased context cause value = recordCount siteRecord (context <> " class=" <> cause <> " erased=" <> value) == 1
        declared = "command StorageUnavailable"
    check "reader admission keeps configuration contention as Store contention" (reader == Right (Left (StoreRefusal StoreBusy)))
    check "reader admission records configuration contention"
      (erased "store reader-admission" "internal ConfigurationBusy" "store StoreBusy")
    check "a concurrent commit keeps the declared observation refusal" (fmap (const ()) observed == Left (StoreRefusal StoreBusy))
    check "a concurrent commit is recorded as an authorization change"
      (erased "store authorization-observation" "internal AuthorizationChanged" "store StoreBusy")
    -- Characterization of a known gap: configurationIO has no private sink
    -- that the local administration command does not share, so this
    -- replacement is not recorded.
    check "characterization of the unrecorded gap: an I/O failure inside a configuration loan becomes the declared diagnostic" (callback == Left InvalidConfiguration)
    check "a response loan keeps the declared refusal" (responseLoan == storageUnavailable)
    check "a response loan records its own configuration cause"
      (erased "authorization response" "internal ConfigurationRefused ProcessFailure" declared)
    check "a catalogue loan keeps the declared refusal" (catalogue == storageUnavailable)
    check "a catalogue loan records its own configuration cause"
      (erased "authorization catalogue-context" "internal ConfigurationRefused ProcessFailure" declared)
    check "a borrowed catalogue loan keeps the declared refusal" (borrowed == Right storageUnavailable)
    check "a borrowed catalogue loan records configuration contention"
      (erased "authorization borrowed-catalogues" "internal ConfigurationBusy" declared)
    check "the borrowed catalogue loan succeeds when the guard is free" (available == Right ())
    check "view revalidation keeps its declared refusal" (viewFacts == Right (Right (Left Command.StorageUnavailable)))
    check "view revalidation records configuration contention"
      (erased "authorization view-facts" "internal ConfigurationBusy" declared)
    check "a preparation read keeps its declared refusal" (preparationRead == Right (Left Command.StorageUnavailable))
    check "a preparation read records configuration contention"
      (erased "approval preparation-read" "internal ConfigurationBusy" declared)
    check "an admission operation keeps its declared refusal" (operation == Left Command.StorageUnavailable)
    check "an admission operation records its Store cause"
      (erased "admission operation" "store StoreBusy" declared)
    check "a stalled event write keeps the declared refusal" (streamed == storageUnavailable)
    check "a stalled event write is recorded as a write timeout"
      (erased "events write" "internal ResponseWriteTimeout" declared)
    check "no erasure record holds exception text" (not (markerBytes `BS.isInfixOf` siteRecord))
    generation <- storeProcessGeneration <$> storeIdentity store
    policy <- right (P.projectPolicy (object ["kind" .= ("scripted"::Text)]))
    let review = P.Review (T.replicate 64 "a") "local-control" policy "workflow_1" "profile_1" "fixture" "no execution"
          [] "plan" [] [] [] (String "flag")
        reviewBytes = Command.encoded review
        binding = Command.encoded (object ["reviewSha256" .= hexDigest reviewBytes])
        insertPreparation ident requestId reviewStored digestStored expires = mutate store $ do
          execute "INSERT INTO requests(id,revision,client_id,workflow_id,descriptor_revision,profile_id,profile_revision,phase,admission,blocking_reasons,validation_errors) VALUES (?,'revision_1','client_1','workflow_1','descriptor_1','profile_1','profile_revision_1','review','reserved',?,?)"
            [SQL.SQLText requestId,SQL.SQLBlob "[]",SQL.SQLBlob "[]"]
          execute "INSERT INTO reservations(id,request_id,slot,process_generation,state) VALUES (?,?,NULL,?,'released')"
            [SQL.SQLText ("reservation_" <> ident),SQL.SQLText requestId,SQL.SQLText generation]
          execute "INSERT INTO preparations VALUES (?,'preparation_revision_1',?,'request_revision_1','profile_revision_1',?,?,'worker_1','root_1','native_1',?,?,?,?,'live',NULL)"
            [SQL.SQLText ident,SQL.SQLText requestId,SQL.SQLText ("reservation_" <> ident),SQL.SQLText generation,SQL.SQLText expires,
             SQL.SQLText digestStored,SQL.SQLBlob reviewStored,SQL.SQLBlob binding]
        stored ident = faultOf (withPreparation store proof ident (\_ preparation -> pure (P.preparationId preparation)))
        timestamp = "2999-01-01T00:00:00Z"
    insertPreparation "preparation_ok" "request_ok" reviewBytes (hexDigest binding) timestamp
    stored "preparation_ok" >>= check "a consistent stored preparation projects" . (== Right "preparation_ok")
    insertPreparation "preparation_undecodable" "request_undecodable" "not json" (hexDigest binding) timestamp
    stored "preparation_undecodable" >>= check "an undecodable stored review is a Store integrity failure" . (== Left (StoreRefusal StoreIntegrity))
    insertPreparation "preparation_digest" "request_digest" reviewBytes (T.replicate 64 "b") timestamp
    stored "preparation_digest" >>= check "a stored binding digest mismatch is a Store integrity failure" . (== Left (StoreRefusal StoreIntegrity))
    insertPreparation "preparation_public" "request_public" reviewBytes (hexDigest binding) "not-a-timestamp"
    stored "preparation_public" >>= check "a stored preparation outside the public contract is a Store integrity failure" . (== Left (StoreRefusal StoreIntegrity))
    let https = HttpsConfiguration "127.0.0.1" 1 "unused" "unused" ["manager.invalid"] [] ["127.0.0.1"]
        profilesRequest = Wai.defaultRequest
          { Wai.isSecure = True, Wai.requestMethod = "GET", Wai.rawPathInfo = "/v1/profiles", Wai.pathInfo = ["v1","profiles"],
            Wai.requestHeaders = [("Host","manager.invalid"),("Authorization","Bearer " <> bearer)],
            Wai.requestBodyLength = Wai.KnownLength 0 }
        invalidRequest = profilesRequest { Wai.rawPathInfo = "/v1/profiles:x", Wai.pathInfo = ["v1","profiles:x"] }
        serveAt wanted failure = do
          answered <- newIORef Nothing
          _ <- Transport.authenticated https store (const ["GET"]) (\_ _ _ -> throwIO failure) wanted $ \response -> do
            body <- newIORef BS.empty
            let (status, _, withBody) = Wai.responseToStream response
            withBody (\stream -> stream (\chunk -> readIORef body >>= \old -> writeIORef body (old <> BS.toStrict (Builder.toLazyByteString chunk))) (pure ()))
            bytes <- readIORef body
            writeIORef answered (Just (HTTP.statusCode status, either (const Null) (field "code") (eitherDecodeStrict' bytes), bytes))
            pure ResponseReceived
          readIORef answered
        serve = serveAt profilesRequest
        started failure = try @SomeException $ Transport.authenticated https store (const ["GET"]) (\_ _ respond -> do
          _ <- respond (Wai.responseLBS HTTP.status200 [] "")
          throwIO failure) profilesRequest (\_ -> pure ResponseReceived)
    ((busy, unavailable, unexpected, internal, declaredRefusal, late, invalid), recorded) <- withPrivateStderr (work </> "private-stderr.log") $ do
      busy <- serve (toException StoreBusy)
      unavailable <- serve (toException StoreUnavailable)
      unexpected <- serve (toException (ErrorCall marker))
      internal <- serve (toException ConfigurationBusy)
      declaredRefusal <- serve (toException Command.Forbidden)
      late <- started (toException StoreBusy)
      invalid <- serveAt invalidRequest (toException StoreBusy)
      pure (busy, unavailable, unexpected, internal, declaredRefusal, late, invalid)
    let answer = fmap (\(status, code, _) -> (status, code))
        recordLines = T.lines (TE.decodeUtf8 recorded)
        recordFor = recordCount recorded
        publicStorageUnavailable = Just (503, String "storage-unavailable")
    check "transport Store contention keeps the public storage-unavailable problem" (answer busy == publicStorageUnavailable)
    check "transport Store I/O failure keeps the public storage-unavailable problem" (answer unavailable == publicStorageUnavailable)
    check "transport unexpected failure keeps the declared public problem" (answer unexpected == publicStorageUnavailable)
    check "transport internal cause keeps the declared public problem" (answer internal == publicStorageUnavailable)
    check "transport declared refusal keeps its own problem" (answer declaredRefusal == Just (403, String "insufficient-scope"))
    check "transport invalid path keeps the public storage-unavailable problem" (answer invalid == publicStorageUnavailable)
    check "no public problem carries exception text"
      (not (any (maybe False (\(_, _, bytes) -> markerBytes `BS.isInfixOf` bytes)) [busy, unavailable, unexpected, internal, declaredRefusal, invalid]))
    check "transport records Store contention privately" (recordFor "response GET /v1/profiles unstarted public=503 storage-unavailable class=store StoreBusy" == 1)
    check "transport records Store I/O failure privately" (recordFor "response GET /v1/profiles unstarted public=503 storage-unavailable class=store StoreUnavailable" == 1)
    check "transport records an unexpected failure by type" (recordFor "response GET /v1/profiles unstarted public=503 storage-unavailable class=unexpected ErrorCall" == 1)
    check "transport records an internal cause privately" (recordFor "response GET /v1/profiles unstarted public=503 storage-unavailable class=internal ConfigurationBusy" == 1)
    check "transport records a failure after the response started" (recordFor "response GET /v1/profiles started public=503 storage-unavailable class=store StoreBusy" == 1)
    check "transport records an invalid path by a fixed word" (recordFor "response GET invalid-path unstarted public=503 storage-unavailable class=store StoreBusy" == 1)
    check "a failure after the response started is rethrown" (fmap (const ()) (either (Left . classifyFault) Right late) == Left (StoreRefusal StoreBusy))
    check "a declared refusal is not recorded" (not (any ("insufficient-scope" `T.isInfixOf`) recordLines))
    check "the private record holds no exception text" (not (markerBytes `BS.isInfixOf` recorded))
    check "the private record holds only the six fault lines" (all ("manager-fault " `T.isPrefixOf`) recordLines && length recordLines == 6)
    (contendedServe, contendedRecord) <- withPrivateStderr (work </> "transport-contention-stderr.log") $
      withHeldGate store (serve (toException (ErrorCall marker)))
    check "transport refuses real Store contention with the public storage-unavailable problem" (answer contendedServe == publicStorageUnavailable)
    check "transport records real Store contention during authentication"
      (recordCount contendedRecord "response GET /v1/profiles unstarted public=503 storage-unavailable class=store StoreBusy" == 1)
    check "the application does not run under real Store contention during authentication"
      (length (T.lines (TE.decodeUtf8 contendedRecord)) == 1)
    ((viewStore, revalidatedStore, preparationStore, overviewDeadline), storeRecord) <- withPrivateStderr (work </> "store-erasure-stderr.log") $ do
      viewStore <- withHeldGate store (withAuthorizedView store proof "profile_1" [Command.Observe] (\_ -> pure ()))
      revalidatedStore <- withAuthorizedView store proof "profile_1" [Command.Observe] (\view -> withHeldGate store (revalidateAuthorizedView view))
      preparationStore <- withHeldGate store (fmap (const ()) <$> readPreparation store proof "preparation_ok")
      overviewDeadline <- faultOf (Overview.withOverviewSourceWithin 0 store proof Nothing (\_ _ materialize -> fmap (const ()) materialize))
      pure (viewStore, revalidatedStore, preparationStore, overviewDeadline)
    let storeErased context = recordCount storeRecord (context <> " class=store StoreBusy erased=command StorageUnavailable") == 1
    check "an authorized view keeps the declared refusal for a Store failure" (viewStore == Left Command.StorageUnavailable)
    check "an authorized view records its Store cause" (storeErased "authorization view")
    check "view revalidation keeps the declared refusal for a Store failure" (revalidatedStore == Right (Left Command.StorageUnavailable))
    check "view revalidation records its Store cause" (storeErased "authorization revalidation")
    check "a preparation read keeps the declared refusal for a Store failure" (preparationStore == Left Command.StorageUnavailable)
    check "a preparation read records its Store cause" (storeErased "approval preparation-read")
    check "an overview materialization deadline keeps the declared refusal" (overviewDeadline == storageUnavailable)
    check "an overview materialization deadline is recorded as an elapsed deadline"
      (recordCount storeRecord "overview materialization class=internal DeadlineElapsed erased=command StorageUnavailable" == 1)
    check "the Store erasure record holds only the four erasure lines"
      (all ("manager-fault " `T.isPrefixOf`) (T.lines (TE.decodeUtf8 storeRecord)) && length (T.lines (TE.decodeUtf8 storeRecord)) == 4)
    pure store
  closed <- faultOf (authenticateCredential escaped bearer >>= right)
  check "authentication preserves the closed-Store refusal" (fmap (const ()) closed == Left (StoreRefusal StoreClosed))
  createDirectory (work </> "closed-configuration")
  (closedConfig,_) <- fixture (work </> "closed-configuration")
  ((closedReader, closedPoll), closedRecord) <- withInstalled closedConfig $ \installed -> withCoordinationStore installed $ \store ->
    Admission.withAdmission store $ \controller -> withPrivateStderr (work </> "closed-configuration-stderr.log") $ do
      closeConfiguration installed
      closedReader <- faultOf (withStoreReader store (pure ()))
      closedPoll <- fmap (const ()) <$> Admission.pollAdmission controller
      pure (closedReader, closedPoll)
  check "reader admission keeps a refused configuration as the Store I/O refusal" (closedReader == Left (StoreRefusal StoreUnavailable))
  check "reader admission records the refused configuration distinctly"
    (recordCount closedRecord "store reader-admission class=internal ConfigurationRefused InvalidConfiguration erased=store StoreUnavailable" == 1)
  check "an admission poll keeps its declared refusal for a refused configuration" (closedPoll == Left Command.StorageUnavailable)
  check "an admission poll records the refused configuration"
    (recordCount closedRecord "admission poll class=internal ConfigurationRefused InvalidConfiguration erased=command StorageUnavailable" == 1)
  createDirectory (work </> "credential-query")
  (queryConfig,_) <- fixture (work </> "credential-query")
  failedQuery <- withInstalled queryConfig $ \installed -> withCoordinationStore installed $ \store -> do
    seed store
    let hidden statement = withRaw (work </> "credential-query" </> "manager") (\db -> SQL.exec db statement)
    hidden "ALTER TABLE credential_administration RENAME TO credential_administration_hidden"
    outcome <- faultOf (authenticateCredential store bearer >>= right)
    hidden "ALTER TABLE credential_administration_hidden RENAME TO credential_administration"
    pure outcome
  check "authentication preserves a typed credential-query Store failure" (fmap (const ()) failedQuery == Left (StoreRefusal StoreUnavailable))

faultOf :: IO a -> IO (Either FaultClass a)
faultOf action = either (Left . classifyFault) Right <$> try @SomeException action

-- The occupier is itself a fail-fast caller, so it retries only its own
-- refused admission until it owns the gate. The probe then observes the held
-- gate before the action under test runs.
withHeldGate :: CoordinationStore -> IO a -> IO a
withHeldGate store action = withAsync occupy $ \_ -> do
  timeout 4000000 held >>= maybe (error "Store gate fixture was not held") pure
  action
  where
    held = do
      outcome <- try @StoreFailure (runRead store (pure ()))
      case outcome of
        Left StoreBusy -> pure ()
        _ -> threadDelay 1000 >> held
    occupy = do
      outcome <- try @StoreFailure (runRead store (query "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<1000000000000) SELECT sum(x) FROM n" [] >> pure ()))
      case outcome of
        Left StoreBusy -> occupy
        _ -> pure ()

hexDigest :: BS.ByteString -> Text
hexDigest bytes = T.pack (show (hash bytes :: Digest SHA256))

distinctText :: [Text] -> [Text]
distinctText = foldr (\value kept -> if value `elem` kept then kept else value : kept) []

responseOrderChecks :: FilePath -> IO ()
responseOrderChecks work = do
  (config,_) <- fixture work
  withInstalled config $ \installed -> withCoordinationStore installed $ \store -> do
    seed store
    proof <- authenticateCredential store bearer >>= right
    Service.withService store $ \service -> do
      entered <- newIORef False
      let refused label operation = do
            outcome <- try @StoreFailure (void operation)
            check label (outcome == Left StoreBusy)
          association = RunAssociation "run_missing" "profile_1" "root_missing" (RunId "native_missing")
      -- Exhaust readers as well as files. A configuration-first response would
      -- report StoreLimit, rather than refusing at the original file guard.
      withStoreReader store $ withStoreReader store $ withStoreFiles store $ \_ -> do
        refused "overview acquires files before reader/configuration"
          (Service.withOverviewSource service proof (\_ _ _ -> writeIORef entered True))
        refused "run response acquires files before reader/configuration"
          (Service.withRun service proof "run_missing" (\_ _ -> writeIORef entered True))
        refused "decision response acquires files before reader/configuration"
          (withDecision store proof association "decision_missing" (\_ _ -> writeIORef entered True))
        readIORef entered >>= check "refused responses never enter their callbacks" . not
        withStoreConfiguration store (\_ _ -> pure ()) >>= check "refused responses leave configuration available" . (==Right ())
      escaped <- newIORef Nothing
      Service.withOverviewSource service proof $ \view _ materialize -> do
        (_,_,items) <- materialize
        check "complete empty overview uses its original materialization scope" (null items)
        refused "overview file loan spans the response callback" (withStoreFiles store (\_ -> pure ()))
        withStoreConfiguration store (\_ _ -> pure ()) >>= check "overview configuration spans response callback" . (==Left SupervisionUnavailable)
        revalidateAuthorizedView view >>= check "overview view revalidates under its original loans" . (==Right ())
        writeIORef escaped (Just materialize)
      readIORef escaped >>= maybe (error "missing overview materializer") (\materialize -> do
        result <- try @Command.CommandFailure (void materialize)
        check "overview materializer cannot outlive its original loans" (result == Left Command.Unauthenticated))

admissionContentionChecks :: FilePath -> IO ()
admissionContentionChecks work = do
  (config,_) <- fixture work
  withInstalled config $ \installed -> withCoordinationStore installed $ \store ->
    Admission.withAdmission store $ \controller -> do
      before <- scalar store "SELECT sequence FROM service_metadata WHERE singleton=1"
      result <- withStoreConfiguration store $ \_ _ -> do
        deferred <- Admission.pollAdmission controller
        check "configuration contention is proven before admission selection"
          (case deferred of Right Admission.AdmissionDeferred -> True; _ -> False)
        legacy <- Admission.admitOldest controller
        check "existing admission entry retains its refusal contract"
          (case legacy of Left Command.StorageUnavailable -> True; _ -> False)
      right result
      after <- scalar store "SELECT sequence FROM service_metadata WHERE singleton=1"
      check "deferred admission publishes no mutation" (before == after)
      entered <- newIORef False
      classified <- tryWithStoreCatalogues store $ \_ _ _ -> do
        writeIORef entered True
        throwIO SupervisionUnavailable :: IO ()
      readIORef entered >>= check "entered configuration failure is not a deferred callback"
      check "entered failure preserves its distinct classification" (classified == Just (Left SupervisionUnavailable))
      writeIORef entered False
      withStoreFiles store $ \_ -> do
        deferred <- tryWithStoreFiles store (\_ -> writeIORef entered True)
        check "file contention proves the callback did not enter" (deferred == Nothing)
        legacy <- try @StoreFailure (withStoreFiles store (\_ -> writeIORef entered True))
        check "existing file entry remains fail-fast" (legacy == Left StoreBusy)
      readIORef entered >>= check "deferred file operation performs no work" . not
      failed <- try @StoreFailure (tryWithStoreFiles store (\_ -> throwIO StoreBusy :: IO ()))
      check "entered file failure is never classified as deferred" (failed == Left StoreBusy)
      idle <- Admission.pollAdmission controller
      check "released configuration permits a new admission selection" (case idle of Right Admission.AdmissionIdle -> True; _ -> False)

eventChecks :: FilePath -> IO ()
eventChecks work = do
  (config,_) <- fixture work
  let boundary store proof = Events.withBoundary store proof (\_ cursor floorCursor -> pure (cursor,floorCursor)) $ \view _ pair -> do
        revision <- authorizedViewRevision view
        pure (pair,revision)
      batch store proof cursor = Events.withBatch store proof cursor (\_ -> pure)
      alias = fst . T.breakOn "."
  (previous, pageRevision) <- withInstalled config $ \installed -> withCoordinationStore installed $ \store -> do
    seed store
    proof <- authenticateCredential store bearer >>= right
    (association,_,_) <- sourceRun store
    ((start,_),revision) <- boundary store proof
    forM_ [1::Int ..65] $ \number -> runTransaction store (pure ((),
      [Invalidation "request.changed" ("/v1/requests/hidden_" <> T.pack (show number)) "revision"]))
    runTransaction store (pure ((), [Invalidation "run.changed" ("/v1/runs/" <> associationRun association <> "/snapshot") "revision"]))
    first <- batch store proof start
    check "filtered event batch advances over scanned prefix without skipping the tail"
      (field "events" first == Array mempty && field "hasMore" first == Bool True && string (field "cursor" first) /= start)
    second <- batch store proof (string (field "cursor" first))
    check "next event batch retains the authorized tail"
      (case field "events" second of Array values -> length values == 1 && field "hasMore" second == Bool False; _ -> False)
    BS.writeFile (work </> "batch.json") (Command.encoded second)
    escaped <- Events.withBatch store proof (string (field "cursor" second)) (\view _ -> pure view)
    revalidateAuthorizedView escaped >>= check "event view ends with the original response loan" . (==Left Command.Unauthenticated)
    pure (string (field "cursor" second), revision)
  withInstalled config $ \installed -> withCoordinationStore installed $ \store -> do
    proof <- authenticateCredential store bearer >>= right
    ((current,_),revision) <- boundary store proof
    check "ordinary restart preserves the public event stream alias" (alias current == alias previous)
    check "ordinary restart still changes the page and execution profile binding" (revision /= pageRevision)
    resumed <- batch store proof previous
    BS.writeFile (work </> "resumed.json") (Command.encoded resumed)
    let refused label expected cursor = do
          outcome <- try @Command.CommandFailure (void (batch store proof cursor))
          check label (outcome == Left expected)
    refused "future event cursor requires resnapshot" Command.CursorExpired (alias current <> ".18446744073709551615")
    refused "noncanonical event cursor refuses" Command.InvalidRequest (alias current <> ".00")
    mutate store (execute "DELETE FROM credential_scopes WHERE credential_id='credential_1' AND scope='export'" [])
    refused "permission change invalidates the old event cursor" Command.ViewExpired current
    forM_ [1::Int ..25] $ \_ -> runTransaction store (pure ((), replicate 32
      (Invalidation "service.changed" "/v1/capabilities" "aged_fixture")))
    ((beforeAging,_),_) <- boundary store proof
    -- Controlled timestamps test selection, not elapsed aging. The mutation
    -- helper appends one new, unexpired invalidation after the aged prefix.
    mutate store (execute "UPDATE invalidations SET recorded_at=unixepoch()-604801" [])
    ((high,floorCursor),_) <- boundary store proof
    deleted <- scalar store "SELECT retained_floor FROM service_metadata WHERE singleton=1"
    check "expired prefix beyond one trim chunk has an exact resume floor"
      (floorCursor == beforeAging && floorCursor /= alias high <> "." <> deleted)
    retained <- batch store proof floorCursor
    check "exact floor preserves the fresh invalidation after the expired prefix"
      (field "cursor" retained == String high && case field "events" retained of Array values -> length values == 1; _ -> False)

observationChecks :: FilePath -> IO ()
observationChecks work = do
  (config,_) <- fixture work
  withInstalled config $ \installed -> withCoordinationStore installed $ \store -> do
    seed store
    proof <- authenticateCredential store bearer >>= right
    escaped <- newIORef Nothing
    withStoreReader store $ withAuthorizedCatalogues store proof [Command.Observe] $ \view _ profiles catalogues -> do
      check "catalogue observation uses one reader and filters current grants"
        (map (publicId . fst) profiles == ["profile_1"] && all ((=="profile_1") . fst) catalogues)
      revalidateAuthorizedView view >>= check "catalogue view revalidates without reacquiring configuration" . (==Right ())
      held <- withStoreConfiguration store (\_ _ -> pure ())
      check "catalogue response retains original configuration" (held == Left SupervisionUnavailable)
      writeIORef escaped (Just view)
    readIORef escaped >>= maybe (error "missing catalogue view") (\view ->
      revalidateAuthorizedView view >>= check "catalogue view cannot outlive its original loan" . (==Left Command.Unauthenticated))
    withAuthorizedCatalogues store proof [Command.Submit] $ \_ _ profiles catalogues ->
      check "catalogue excludes profiles missing requested scope" (null profiles && null catalogues)
    (association,reference,_) <- sourceRun store
    let occurrence=OccurrenceId 0; attempt=AttemptId occurrence 0
        events=[RunStartedV2 "fixture" "scripted" PersonAnswerLocalControl,
          OccurrenceStarted occurrence "flag" "consult" "model reviewer" "Approve?",
          AttemptStarted attempt "scripted", AttemptOutput attempt "no",
          AttemptProgress attempt (ProgressMessage "Public update"), AttemptCompleted attempt "scripted",
          OccurrenceCompleted occurrence "asked:model reviewer" "no", TraceOrdered [occurrence]]
        append number event = void (ingestRuntimeEnvelope store association
          (encodeEnvelope (Envelope 2 (associationNative association) (SeqNo number) "2026-09-03T00:00:00Z" event)))
        document projection = object (Observation.publicSnapshotFields projection <>
          ["version" .= (1::Int), "items" .= Observation.publicSnapshotItems projection,
           "page" .= object ["setId" .= ("set_projection_fixture"::Text),
             "revision" .= Observation.publicSnapshotRevision projection, "expiresAt" .= ("2999-01-01T00:00:00Z"::Text),
             "index" .= (0::Int), "totalItems" .= length (Observation.publicSnapshotItems projection), "next" .= Null]])
    forM_ (zip [0..] events) (uncurry append)
    withStoreReader store $ do
      cut <- runRead store (Observation.captureSnapshot proof association)
      append 8 (RunCompletedV2 1 1 reference)
      before <- Observation.restoreSnapshot store cut
      let value=document before
      check "snapshot bindings retain the captured nonterminal prefix"
        (field "status" (field "runtime" value)==String "running" && field "result" value==Null && field "billFresh" value==Null)
      BS.writeFile (work </> "snapshot-before.json") (Command.encoded value)
    Observation.withRunSnapshot store proof (associationRun association) $ \view projection -> do
      let value=document projection
      check "public snapshot carries terminal result and exact bills"
        (field "status" (field "runtime" value)==String "succeeded" && field "billFresh" value==String "1" && field "billMemo" value==String "1"
          && field "code" (field "result" value)==String "flag")
      revalidateAuthorizedView view >>= check "public snapshot remains within response authority" . (==Right ())
      BS.writeFile (work </> "snapshot-after.json") (Command.encoded value)
    native3 <- right (stepRunSnapshot (initialRunSnapshot (RunId "protocol3"))
      (Envelope 3 (RunId "protocol3") (SeqNo 0) "2026-09-03T00:00:00Z" (RunStartedV2 "fixture" "scripted" PersonAnswerLocalControl)))
    summary <- right (Observation.runtimeSummary (Just native3))
    check "public runtime summary reports actual protocol3 without downgrade" (field "protocolVersion" summary==Number 3)
    mutate store (execute "DELETE FROM credential_scopes WHERE credential_id='credential_1'" [])
    withAuthorizedCatalogues store proof [Command.Observe] $ \_ _ profiles catalogues ->
      check "catalogue observation uses current scope removal" (null profiles && null catalogues)

compositionChecks :: FilePath -> IO ()
compositionChecks work = do
  (config,_) <- fixture work
  withInstalled config $ \installed -> withCoordinationStore installed $ \store -> do
    seed store
    proof <- authenticateCredential store bearer >>= right
    (association,reference,directory) <- sourceRun store
    ingest store association reference
    entered <- newIORef False
    let outputs = withRunOutputs store proof association
        refused label action = do
          outcome <- try @StoreFailure (void action)
          check label (outcome == Left StoreLimit)
        verified = outputs $ \_ items -> check "charged profile projection returns verified output"
          (field "state" (field "verification" (last items)) == String "verified")
    withStoreReader store $ do
      verified
      withStoreReader store $ do
        refused "output quota refuses before response" (outputs (\_ _ -> writeIORef entered True))
        refused "standalone restoration shares reader quota" (restoreRunProjection store association)
        refused "historical terminal observation shares reader quota" (observeRetainedTerminal store association)
        refused "ingestion shares reader quota" (ingest store association reference)
      readIORef entered >>= check "quota refusal never enters output callback" . not
      document <- BS.readFile config >>= right . eitherDecodeStrict'
      case document of
        Object fields | Just(Object limits) <- KM.lookup "limits" fields ->
          BS.writeFile config (Command.encoded (Object(KM.insert "limits" (Object(KM.insert "globalDatabaseReaders" (Number 1) limits)) fields)))
        _ -> error "configuration fixture shape"
      replacement <- loadConfiguration (\args -> if null args then Right () else error "unexpected target") exactPreparedTarget (const False) config >>= right
      void (reloadConfiguration installed replacement >>= right)
      refused "output uses current lowered global quota" (outputs (\_ _ -> error "stale reader allowance"))
    escaped <- newIORef Nothing
    outputs $ \view _ -> do
      writeIORef escaped (Just view)
      revalidateAuthorizedView view >>= check "output view revalidates with sole reader capacity" . (==Right ())
      locked <- withStoreConfiguration store (\_ _ -> pure ())
      check "profile configuration remains held through response" (locked == Left SupervisionUnavailable)
      withAsync (try @StoreFailure (withStoreReader store (writeIORef entered True))) $ \other -> do
        outcome <- wait other
        check "competing reader admission preserves typed configuration contention" (outcome == Left StoreBusy)
      readIORef entered >>= check "configuration contention refuses before reader work" . not
      files <- try @StoreFailure (withStoreFiles store (\_ -> pure ()))
      check "original file owner remains held through response" (files == Left StoreBusy)
    retained <- readIORef escaped >>= maybe (error "missing response view") pure
    revalidateAuthorizedView retained >>= check "response view cannot escape retained scopes" . (==Left Command.Unauthenticated)
    failed <- try @StoreFailure (outputs (\_ _ -> throwIO StoreIntegrity))
    check "response failure remains original failure" (failed == Left StoreIntegrity)
    verified
    ready <- newEmptyMVar
    blocked <- newEmptyMVar
    withAsync (outputs (\_ _ -> putMVar ready () >> takeMVar blocked)) $ \reader -> do
      takeMVar ready
      cancel reader
      outcome <- waitCatch reader
      check "response interruption joins original reader" (case outcome of Left failure -> fromException failure == Just AsyncCancelled; _ -> False)
    verified
    original <- BS.readFile (directory </> "result.json")
    BS.writeFile (directory </> "result.json") "corrupt"
    outputs $ \_ items -> check "charged profile projection reports unavailable output"
      (field "state" (field "verification" (last items)) == String "unavailable")
    BS.writeFile (directory </> "result.json") original
    verified
    absent <- try @Command.CommandFailure (withRunOutputs store proof (association {associationProfile="profile_missing"}) (\_ _ -> error "absent profile response"))
    check "current profile membership still required" (absent == Left Command.Forbidden)
    verified
    mutate store (execute "DELETE FROM credential_scopes WHERE credential_id='credential_1'" [])
    denied <- try @Command.CommandFailure (outputs (\_ _ -> error "unauthorized output response"))
    check "current client authorization still required" (denied == Left Command.Forbidden)
    withStoreReader store (check "authorization failure releases sole reader capacity" True)

retentionChecks :: FilePath -> IO ()
retentionChecks work = do
  (config,_) <- fixture work
  withInstalled config $ \installed -> withCoordinationStore installed $ \store -> do
    (association,reference,_) <- sourceRun store
    seed store
    proof <- authenticateCredential store bearer >>= right
    ingest store association reference
    scalar store "SELECT CAST(terminal_observed AS TEXT) FROM runs" >>= check "independent observer prefix has shared validated Runtime terminal evidence" . (=="1")
    exportRequest <- request store association "retention" "retained.json"
    submitted <- submitExport store proof association exportRequest >>= right
    let ident=Command.receiptId(Commands.submissionReceipt submitted)
        exportId="export_"<>ident
    scalar store "SELECT state FROM commands" >>= check "actual export owner records its independent completed effect" . (=="effect-observed")
    public <- readExport store proof exportId
    let artifact=T.drop(T.length "/v1/artifacts/")(string(field "download" public))
    original <- newIORef Nothing
    withArtifactDownload store proof artifact $ \_ _ bytes -> do
      digest <- evaluate(force(convert(hash bytes :: Digest SHA256) :: BS.ByteString))
      writeIORef original (Just digest)
    void(Commands.retainReceipts store "" >>= right)
    scalar store "SELECT CAST(count(*) AS TEXT) FROM commands WHERE inactive_since IS NOT NULL AND retired=0" >>= check "terminal linked resource without unresolved work begins real inactivity observation" . (=="1")
    mutate store(execute "UPDATE commands SET inactive_since='2000-01-01T00:00:00Z'" [])
    void(Commands.retainReceipts store "" >>= right)
    receipt <- Commands.readCommand store proof ident
    check "completed linked-run receipt expires only after full observed interval" (case receipt of Left Command.ReceiptExpired -> True; _ -> False)
    withArtifactDownload store proof artifact $ \_ _ bytes -> do
      digest <- evaluate(force(convert(hash bytes :: Digest SHA256) :: BS.ByteString))
      expected <- readIORef original
      check "receipt retirement preserves independently referenced artifact bytes" (Just digest==expected)
    scalar store "SELECT CAST(count(*) AS TEXT) FROM ingestions" >>= check "receipt retirement retains original Runtime history" . (/="0")
    let confirmed requestBody = do
          response <- administerCredentials store requestBody
          value <- either (const (error "invalid admin result")) pure (eitherDecodeStrict' response)
          check "local administration confirmed" (field "ok" value == Bool True)
    confirmed (Admin.IssueCredential "other-response" [Command.Observe] ["profile_1"] "2999-01-01T00:00:00Z" (work </> "other-response.credential"))
    other <- scalar store "SELECT credential_id FROM credential_administration WHERE label='other-response'"
    withArtifactDownload store proof artifact $ \view _ _ -> do
      revalidateAuthorizedView view >>= check "valid authorization revalidates under retained response scopes" . (==Right ())
      confirmed (Admin.RevokeCredential other)
      awaitAuthorizedView view >>= check "unrelated client revocation preserves response authority" . (==Right ())
      -- The response still owns file/configuration scopes. Revocation must be SQL-only.
      confirmed (Admin.RevokeCredential "credential_1")
      awaitAuthorizedView view >>= check "payload-free wakeup needs no response-scope reacquisition" . (==Left Command.Unauthenticated)
    refused <- try @Command.CommandFailure (withArtifactDownload store proof artifact (\_ _ _ -> error "revoked download callback" :: IO ()))
    check "revocation refuses retained artifact download before response" (refused == Left Command.Unauthenticated)
    Commands.readCommand store proof ident >>= check "revocation precedes retained receipt lookup" . (\result -> case result of Left Command.Unauthenticated -> True; _ -> False)
    expiry <- scalar store "SELECT strftime('%Y-%m-%dT%H:%M:%fZ','now','+3 seconds')"
    let shortFile = work </> "short-response.credential"
    confirmed (Admin.IssueCredential "short-response" [Command.Observe] ["profile_1"] expiry shortFile)
    shortProof <- BS.readFile shortFile >>= authenticateCredential store >>= right
    withArtifactDownload store shortProof artifact $ \view _ _ -> do
      revalidateAuthorizedView view >>= check "short-lived response begins authorized" . (==Right ())
      before <- scalar store "SELECT sequence FROM service_metadata"
      let awaitExpiry = awaitAuthorizedView view >>= \result -> case result of
            Right () -> awaitExpiry
            Left failure -> pure failure
      outcome <- timeout 7000000 awaitExpiry
      check "quiet expiry revalidates under retained response scopes" (outcome == Just Command.Unauthenticated)
      after <- scalar store "SELECT sequence FROM service_metadata"
      check "quiet expiry requires no Store mutation notification" (before == after)

artifactChecks :: FilePath -> FilePath -> IO ()
artifactChecks work source = do
  migrationChecks work
  reviewRegressions (work </> "review")
  documents <- documentFixtures source
  (config,root) <- fixture work
  sourceFixture <- BS.readFile (source </> "test/fixtures/manager/v1/valid/artifact-download.utf8")
  exportFixture <- BS.readFile (source </> "test/fixtures/manager/v1/valid/export-download.utf8")
  withInstalled config $ \installed -> do
    (association,handle,witness,unwitnessed,conflict) <- withCoordinationStore installed $ \store -> do
      (association,reference,directory) <- sourceRun store
      seed store
      proof <- authenticateCredential store bearer >>= right
      ingest store association reference
      handle <- scalar store "SELECT result_artifact_id FROM runs WHERE id='run_21'"
      actual <- BS.readFile (directory </> "result.json")
      check "native writer matches frozen captured source fixture" (actual == sourceFixture)
      withArtifactDownload store proof handle $ \_ metadata bytes -> do
        check "download is exact source bytes, not export document" (bytes == sourceFixture && bytes /= exportFixture)
        BS.writeFile (work </> "source-metadata.json") (Command.encoded metadata)
        BS.writeFile (work </> "source-download.utf8") bytes
      sequenceBefore <- scalar store "SELECT sequence FROM service_metadata"
      withArtifactDownload store proof handle (\_ _ bytes -> check "repeat observation still verifies captured bytes" (bytes == sourceFixture))
      sequenceAfter <- scalar store "SELECT sequence FROM service_metadata"
      check "unchanged successful verification creates no duplicate invalidation" (sequenceBefore == sequenceAfter)
      withRunOutputs store proof association $ \_ items -> do
        check "attempt, diagnostic and verified result remain distinct" (map (field "kind") items == map String ["attempt","diagnostic","result"])
        BS.writeFile (work </> "outputs.json") (Command.encoded items)
      rawChecks store proof association handle reference directory sourceFixture
      typedDocuments store proof documents
      outputBounds store proof work
      exportRequest <- request store association "main" "review-result.json"
      submission <- submitExport store proof association exportRequest >>= right
      let exportId = "export_" <> Command.receiptId (Commands.submissionReceipt submission)
      receipt <- readExport store proof exportId
      check "published receipt omits server path" (field "state" receipt == String "published" && not (has "path" receipt))
      BS.writeFile (work </> "export-receipt.json") (Command.encoded receipt)
      let exportHandle = T.drop (T.length "/v1/artifacts/") (string (field "download" receipt))
      withArtifactDownload store proof exportHandle $ \_ metadata bytes -> do
        check "download is exact distinct frozen export bytes" (bytes == exportFixture && exportHandle /= handle)
        BS.writeFile (work </> "export-metadata.json") (Command.encoded metadata)
        BS.writeFile (work </> "export-download.utf8") bytes
      replay <- submitExport store proof association exportRequest >>= right
      check "same key replays immutable acceptance without publication authority" (Commands.submissionReplayed replay && noTicket replay)
      authChecks store proof association handle exportHandle exportId
      runtimeRaces store association reference
      withStoreFiles store $ \managerRoot -> bracket (openPrivateSubroot managerRoot ["runs"]) closePrivateRoot $ \runs -> do
        writePrivateExclusiveAt runs ["exports","foreign.json"] exportFixture
        writePrivateExclusiveAt runs ["exports","different.json"] "foreign"
      conflict <- submitNamed store proof association "foreign"
      check "identical pre-existing bytes do not prove our publication" =<< ((== String "unresolved") . field "state" <$> reconcileExport store proof conflict)
      foreignCommand <- scalar store "SELECT state FROM commands WHERE id=(SELECT command_id FROM exports WHERE name='foreign.json')"
      check "known identical existing destination is a refusal" (foreignCommand == "refused")
      different <- submitNamed store proof association "different"
      check "conflicting destination remains unchanged" =<< ((== "foreign") <$> BS.readFile (root </> "runs/exports/different.json"))
      check "known conflicting destination has no false receipt" =<< ((== String "unresolved") . field "state" <$> readExport store proof different)
      badRequests store proof association
      competing <- request store association "second-owner" "review-result.json" >>= submitExport store proof association
      check "second command cannot own existing intended destination" (case competing of Left Command.StateConflict -> True; _ -> False)
      withRaw root $ \db -> SQL.exec db "CREATE TRIGGER fail_export_completion BEFORE UPDATE OF effect_evidence ON commands WHEN NEW.operation='export' AND NEW.effect_evidence IS NOT NULL BEGIN SELECT RAISE(ABORT,'fixture completion failure'); END"
      lost <- request store association "witness" "witness.json"
      failure <- try @Command.CommandFailure (submitExport store proof association lost)
      check "completion fault is preserved after durable publisher witness" (case failure of Left Command.StorageUnavailable -> True; _ -> False)
      witness <- scalar store "SELECT id FROM exports WHERE name='witness.json' AND receipt IS NOT NULL AND state='unresolved'"
      withRaw root $ \db -> SQL.exec db "DROP TRIGGER fail_export_completion"
      withRaw root $ \db -> SQL.exec db "CREATE TRIGGER fail_export_witness BEFORE UPDATE OF receipt ON exports WHEN NEW.receipt IS NOT NULL BEGIN SELECT RAISE(ABORT,'fixture witness failure'); END"
      lostBeforeWitness <- request store association "unwitnessed" "unwitnessed.json"
      noWitness <- try @StoreFailure (submitExport store proof association lostBeforeWitness)
      check "publication without durable witness preserves first storage failure" (case noWitness of Left StoreUnavailable -> True; _ -> False)
      unwitnessed <- scalar store "SELECT id FROM exports WHERE name='unwitnessed.json' AND receipt IS NULL AND state='unresolved'"
      withRaw root $ \db -> SQL.exec db "DROP TRIGGER fail_export_witness"
      check "unwitnessed complete destination really exists" =<< ((== exportFixture) <$> BS.readFile (root </> "runs/exports/unwitnessed.json"))
      exportSubstitution store proof exportHandle root
      pure (association,handle,witness,unwitnessed,conflict)
    withCoordinationStore installed $ \store -> do
      proof <- authenticateCredential store bearer >>= right
      let witnessedPath=root </> "runs/exports/witness.json"
      BS.writeFile witnessedPath "conflicting bytes"
      corrupted <- try @Command.CommandFailure (reconcileExport store proof witness)
      check "durable witness alone cannot bypass current byte verification" (corrupted == Left Command.ResourceUnavailable)
      observed <- readExport store proof witness
      check "failed verification leaves witnessed publication unresolved" (field "state" observed == String "unresolved")
      BS.writeFile witnessedPath exportFixture
      epoch <- storeAuthorityEpoch <$> storeIdentity store
      mutate store $ execute "UPDATE service_metadata SET authority_epoch='authority_changed'" []
      changedAuthority <- try @Command.CommandFailure (reconcileExport store proof witness)
      check "reopen evidence cannot cross authority epoch" (changedAuthority == Left Command.OwnershipUnavailable)
      mutate store $ execute "UPDATE service_metadata SET authority_epoch=?" [SQL.SQLText epoch]
      recovered <- reconcileExport store proof witness
      check "reopen completes only witnessed verified publication" (field "state" recovered == String "published")
      state <- scalar store "SELECT state FROM commands WHERE id=(SELECT command_id FROM exports WHERE name='witness.json')"
      check "export and command effect observed atomically after reopen" (state == "effect-observed")
      missingWitness <- reconcileExport store proof unwitnessed
      check "reopen does not adopt filesystem-only publication" (field "state" missingWitness == String "unresolved" && field "download" missingWitness == Null)
      refused <- reconcileExport store proof conflict
      check "reopen does not adopt identical foreign publication" (field "state" refused == String "unresolved")
      check "reconciliation never changes existing bytes" =<< ((== exportFixture) <$> BS.readFile (root </> "runs/exports/unwitnessed.json"))
      withArtifactDownload store proof handle (\_ _ bytes -> check "trusted handle survives reopen without journal" (bytes == sourceFixture))
      withRunExports store proof association $ \view items -> do
        revalidateAuthorizedView view >>= check "export collection view revalidates under its configuration guard" . (==Right ())
        check "run export collection exposes published and unresolved receipts separately"
          (length items == 5 && length [() | item <- items,field "state" item == String "published"] == 2
            && length [() | item <- items,field "state" item == String "unresolved",field "download" item == Null] == 3)
        BS.writeFile (work </> "export-items.json") (Command.encoded items)
      rootSubstitution store proof association handle root
  putStrLn "PASS deterministic manager artifacts A11/A12/A21 primitives, no native process execution"

-- Durable acceptance integrity and collection revision regressions from WM-017 review.
reviewRegressions :: FilePath -> IO ()
reviewRegressions work = do
  createDirectory work
  (config,root) <- fixture work
  (association,witness) <- withInstalled config $ \installed -> withCoordinationStore installed $ \store -> do
    seed store
    proof <- authenticateCredential store bearer >>= right
    (association,reference,directory) <- sourceRun store
    ingest store association reference
    handle <- scalar store "SELECT result_artifact_id FROM runs WHERE id='run_21'"
    let result=directory </> "result.json"
    original <- BS.readFile result
    withArtifactDownload store proof handle (\_ _ _ -> pure ())
    staleVerified <- request store association "stale-verified" "stale-verified.json"
    verifiedRevision <- scalar store "SELECT revision FROM artifacts WHERE id=(SELECT result_artifact_id FROM runs WHERE id='run_21')"
    BS.writeFile result "corrupt"
    withRunOutputs store proof association (\_ _ -> pure ())
    unavailableRevision <- scalar store "SELECT revision FROM artifacts WHERE id=(SELECT result_artifact_id FROM runs WHERE id='run_21')"
    BS.writeFile result original
    withArtifactDownload store proof handle (\_ _ _ -> pure ())
    restoredRevision <- scalar store "SELECT revision FROM artifacts WHERE id=(SELECT result_artifact_id FROM runs WHERE id='run_21')"
    check "verified unavailable verified transitions have distinct revisions"
      (verifiedRevision /= unavailableRevision && restoredRevision /= verifiedRevision && restoredRevision /= unavailableRevision)
    assertStale store proof association staleVerified "verification ABA cannot revive collection If-Match"
    first <- submitNamed store proof association "revision-a"
    staleFirst <- request store association "stale-a" "stale-a.json"
    _ <- submitNamed store proof association "revision-b"
    before <- observationState store
    receipt <- reconcileExport store proof first
    after <- observationState store
    check "A B reconcile-A leaves all revisions receipts and invalidations unchanged" (before == after && field "state" receipt == String "published")
    assertStale store proof association staleFirst "published reconciliation cannot revive collection If-Match"
    base <- request store association "bound" "bound.json"
    let raw="{ \"name\" : \"bound.json\" }\n"
        req=base {Commands.commandBody=raw}
    withRaw root $ \db -> SQL.exec db "CREATE TRIGGER fail_review_completion BEFORE UPDATE OF effect_evidence ON commands WHEN NEW.operation='export' AND NEW.effect_evidence IS NOT NULL BEGIN SELECT RAISE(ABORT,'injected review completion failure'); END"
    failed <- try @Command.CommandFailure (submitExport store proof association req)
    check "review fixture preserves genuine publisher witness before failed completion" (case failed of Left Command.StorageUnavailable -> True; _ -> False)
    withRaw root $ \db -> SQL.exec db "DROP TRIGGER fail_review_completion"
    command <- scalar store "SELECT command_id FROM exports WHERE name='bound.json'"
    let witness="export_"<>command
    exact <- runRead store $ do
      rows <- query "SELECT body,body_sha256,body_bytes FROM commands WHERE id=?" [SQL.SQLText command]
      pure (rows == [[SQL.SQLNull,SQL.SQLBlob (convert (hash raw::Digest SHA256)),SQL.SQLInteger (fromIntegral (BS.length raw))]])
    check "accepted whitespace body retains exact digest and count without generic body" exact
    replay <- submitExport store proof association req >>= right
    check "identical whitespace body replays acceptance without dispatch authority" (Commands.submissionReplayed replay && noTicket replay)
    different <- submitExport store proof association base
    check "whitespace-distinct equivalent name remains raw-body idempotency conflict" (case different of Left Command.IdempotencyConflict -> True; _ -> False)
    mutate store $ execute "INSERT INTO runs(id,revision,control_revision,profile_id,root_identity,native_run_id,supervision,result_state) VALUES ('run_other','revision','revision','profile_1',?,'native-other','observer','absent')" [SQL.SQLText (associationRoot association)]
    acceptanceTampering store proof root witness command req
    pure (association,witness)
  withInstalled config $ \installed -> withCoordinationStore installed $ \store -> do
    proof <- authenticateCredential store bearer >>= right
    published <- reconcileExport store proof witness
    check "untampered whitespace acceptance reconciles after reopen" (field "state" published == String "published" && field "runId" published == String (associationRun association))
    before <- observationState store
    again <- reconcileExport store proof witness
    after <- observationState store
    check "reopened published reconciliation is observationally idempotent" (before == after && published == again)

assertStale :: CoordinationStore -> CredentialProof -> RunAssociation -> Commands.CommandRequest -> String -> IO ()
assertStale store proof association req label = do
  before <- observationState store
  outcome <- submitExport store proof association req
  after <- observationState store
  check label (case outcome of Left Command.StaleRevision -> before == after; _ -> False)

observationState :: CoordinationStore -> IO [[[String]]]
observationState store = runRead store $ mapM (\statement -> map (map show) <$> query statement [])
  ["SELECT * FROM runs ORDER BY id","SELECT * FROM artifacts ORDER BY id","SELECT * FROM exports ORDER BY id",
   "SELECT * FROM commands ORDER BY id","SELECT * FROM service_metadata",
   "SELECT * FROM invalidations ORDER BY stream_id,sequence"]

acceptanceTampering :: CoordinationStore -> CredentialProof -> FilePath -> Text -> Text -> Commands.CommandRequest -> IO ()
acceptanceTampering store proof root witness command req = do
  (receiptBytes,privateBytes,witnessBytes) <- runRead store $ do
    rows <- query "SELECT c.receipt,a.private_reference,e.receipt FROM exports e JOIN commands c ON c.id=e.command_id JOIN artifacts a ON a.id=e.artifact_id WHERE e.id=?" [SQL.SQLText witness]
    case rows of [[SQL.SQLBlob a,SQL.SQLBlob b,SQL.SQLBlob c]] -> pure (a,b,c); _ -> refuseTransaction StoreIntegrity
  receipt <- right (Command.decodeReceipt receiptBytes)
  private <- right (eitherDecodeStrict' privateBytes)
  published <- right (eitherDecodeStrict' witnessBytes)
  let set key value (Object fields)=Object (KM.insert (Key.fromText key) value fields)
      set _ _ value=value
      privateChange value=execute "UPDATE artifacts SET private_reference=? WHERE id=(SELECT artifact_id FROM exports WHERE id=?)" [SQL.SQLBlob (Command.encoded value),SQL.SQLText witness]
      receiptChange value=execute "UPDATE commands SET receipt=? WHERE id=?" [SQL.SQLBlob (Command.encoded value),SQL.SQLText command]
      commandChange column value=execute ("UPDATE commands SET "<>column<>"=? WHERE id=?") [value,SQL.SQLText command]
      otherProfile=receipt {Command.receiptProfile="profile_other"}
      otherResource=receipt {Command.receiptResource="/v1/runs/run_other/exports"}
      raw=Commands.commandBody req
      canonical=Command.encoded (object ["name" .= ("bound.json"::Text)])
      restore = do
        execute "UPDATE commands SET profile_id='profile_1',resource_uri=?,operation='export',run_id='run_21',receipt=?,body_sha256=?,body_bytes=? WHERE id=?"
          [SQL.SQLText (Commands.commandResource req),SQL.SQLBlob receiptBytes,SQL.SQLBlob (convert (hash raw::Digest SHA256)),SQL.SQLInteger (fromIntegral (BS.length raw)),SQL.SQLText command]
        execute "UPDATE exports SET name='bound.json',receipt=? WHERE id=?" [SQL.SQLBlob witnessBytes,SQL.SQLText witness]
        execute "UPDATE artifacts SET private_reference=? WHERE id=(SELECT artifact_id FROM exports WHERE id=?)" [SQL.SQLBlob privateBytes,SQL.SQLText witness]
  exact <- pure (field "acceptedName" private == String "bound.json"
    && field "acceptedBodySha256" private == String (T.pack (show (hash raw::Digest SHA256)))
    && field "acceptedBodyBytes" private == String (T.pack (show (BS.length raw))))
  check "private provenance binds accepted parsed name and exact incoming bytes" exact
  let destination=root </> "runs/exports/bound.json"
      foreignDestination=root </> "runs/exports/other-bound.json"
  bytes <- BS.readFile destination
  withStoreFiles store $ \retained -> writePrivateExclusiveAt retained ["runs","exports","other-bound.json"] bytes
  forM_
    [("receipt cross-profile",receiptChange otherProfile),
     ("row cross-profile",commandChange "profile_id" (SQL.SQLText "profile_other")),
     ("row and receipt cross-profile",commandChange "profile_id" (SQL.SQLText "profile_other") >> receiptChange otherProfile),
     ("receipt cross-resource with matching link",receiptChange otherResource),
     ("row cross-resource",commandChange "resource_uri" (SQL.SQLText "/v1/runs/run_other/exports")),
     ("row and receipt cross-resource",commandChange "resource_uri" (SQL.SQLText "/v1/runs/run_other/exports") >> receiptChange otherResource),
     ("receipt wrong operation",receiptChange (receipt {Command.receiptOperation=Command.Cancel})),
     ("row wrong operation",commandChange "operation" (SQL.SQLText "cancel")),
     ("row cross-run",commandChange "run_id" (SQL.SQLText "run_other")),
     ("accepted name mismatch",privateChange (set "acceptedName" (String "other-bound.json") private)),
     ("intended name with matching witness and foreign bytes",execute "UPDATE exports SET name='other-bound.json',receipt=? WHERE id=?" [SQL.SQLBlob (Command.encoded (set "name" (String "other-bound.json") published)),SQL.SQLText witness]),
     ("missing older acceptance binding",privateChange (object ["exportId" .= witness,"bytes" .= field "bytes" private])),
     ("unknown private binding field",privateChange (set "extra" Null private)),
     ("noncanonical private byte count",privateChange (set "acceptedBodyBytes" (String ("0"<>T.pack (show (BS.length raw)))) private)),
     ("canonical body substituted in private binding",privateChange (set "acceptedBodySha256" (String (T.pack (show (hash canonical::Digest SHA256)))) (set "acceptedBodyBytes" (String (T.pack (show (BS.length canonical)))) private))),
     ("canonical body substituted in command binding",commandChange "body_sha256" (SQL.SQLBlob (convert (hash canonical::Digest SHA256))) >> commandChange "body_bytes" (SQL.SQLInteger (fromIntegral (BS.length canonical))))] $ \(label,tamper) -> do
       mutate store tamper
       before <- observationState store
       outcome <- try @Command.CommandFailure (reconcileExport store proof witness)
       after <- observationState store
       current <- BS.readFile destination
       foreignBytes <- BS.readFile foreignDestination
       check (label<>" refuses with complete rollback and no publication replay")
         (outcome == Left Command.OwnershipUnavailable && before == after && current == bytes && foreignBytes == bytes)
       mutate store restore

migrationChecks :: FilePath -> IO ()
migrationChecks work = do
  let directory=work </> "migration"
  createDirectory directory
  (config,root) <- fixture directory
  withInstalled config (const (pure ()))
  original <- withRaw root $ \db -> do
    mapM_ (SQL.exec db) (schemaStatements<>commandMigration<>draftMigration<>admissionMigration<>approvalMigration<>ingestionMigration<>controlMigration)
    SQL.exec db "PRAGMA user_version=7; INSERT INTO service_metadata VALUES (1,'authority_legacy','stream_legacy','0','0','r'); INSERT INTO clients VALUES ('client','r','a',0)"
    SQL.exec db "INSERT INTO runs(id,revision,control_revision,profile_id,root_identity,native_run_id,supervision,result_state) VALUES ('run','r','r','profile_1','root','native','observer','absent')"
    SQL.exec db "INSERT INTO artifacts VALUES ('artifact','r','run',X'007f',X'22666c616722','verified',NULL)"
    forM_ ["published","unresolved"] $ \state -> do
      SQL.exec db ("INSERT INTO commands(id,revision,profile_id,operation,client_id,authority_epoch,method,resource_uri,idempotency_key,body,media_type,receipt,retired,run_id,accepted_at,state) VALUES ('command_"<>state<>"','r','profile_1','export','client','authority_legacy','POST','/v1/runs/run/exports','key_"<>state<>"',X'007f','application/json',X'007f',0,'run','2026-09-03T00:00:00Z','accepted')")
      SQL.exec db ("INSERT INTO exports VALUES ('export_"<>state<>"','r','run','artifact','command_"<>state<>"','root','"<>state<>".json','digest',"<>(if state=="published" then "X'007f'" else "NULL")<>",'"<>state<>"')")
    SQL.exec db "CREATE VIEW migration_fault AS SELECT * FROM nonexistent_migration_fixture"
    rawRows db "SELECT * FROM exports ORDER BY id"
  withInstalled config $ \installed -> do
    failed <- try @StoreFailure (withCoordinationStore installed (const (pure ())))
    check "schema7 export migration failure remains explicit" (failed == Left StoreUnavailable)
  withRaw root $ \db -> do
    version <- rawRows db "PRAGMA user_version"
    rows <- rawRows db "SELECT * FROM exports ORDER BY id"
    leftover <- rawRows db "SELECT name FROM sqlite_master WHERE name='exports_v8'"
    check "failed migration rolls back copy, drop and version with all data intact" (version==[[SQL.SQLInteger 7]] && rows==original && null leftover)
    SQL.exec db "DROP VIEW migration_fault"
  withInstalled config $ \installed -> withCoordinationStore installed $ \store -> do
    identity <- storeIdentity store
    current <- runRead store ((==[[SQL.SQLInteger(fromIntegral schemaVersion)]]) <$> query "SELECT user_version FROM pragma_user_version" [])
    check "populated schema7 upgrades to current schema" (storeSchemaVersion identity==schemaVersion && current)
    preserved <- runRead store ((==original) <$> query "SELECT * FROM exports ORDER BY id" [])
    check "published and unresolved export rows retained byte-for-byte" preserved
    before <- scalar store "SELECT sequence FROM service_metadata"
    aborted <- try @StoreFailure $ mutate store $ do
      execute "INSERT INTO exports VALUES ('aborted','r','run','artifact','not-yet-command','root','aborted.json','digest',NULL,'unresolved')" []
      (refuseTransaction StoreIntegrity :: Transaction ())
    after <- scalar store "SELECT sequence FROM service_metadata"
    check "deferred intent still rolls back with owning transaction" (aborted==Left StoreIntegrity && before==after)
    missing <- try @StoreFailure $ mutate store $ execute "INSERT INTO exports VALUES ('missing','r','run','artifact','missing-command','root','missing.json','digest',NULL,'unresolved')" []
    check "missing export command rejected at commit" (missing==Left StoreUnavailable)
    poisoned <- try @StoreFailure (storeIdentity store)
    check "failed commit preserves existing Store poison fence" (case poisoned of Left StorePoisoned -> True; _ -> False)
  withInstalled config $ \installed -> withCoordinationStore installed $ \store -> do
    preserved <- runRead store ((==original) <$> query "SELECT * FROM exports ORDER BY id" [])
    integrity <- runRead store (null <$> query "SELECT * FROM pragma_foreign_key_check" [])
    check "fresh lifetime sees complete rollback and valid export foreign keys" (preserved && integrity)

withRaw :: FilePath -> (SQL.Database -> IO a) -> IO a
withRaw root action = do
  let path=root </> "coordination.sqlite3"
  bracket (SQL.open2 (T.pack path) [SQL.SQLOpenReadWrite,SQL.SQLOpenCreate,SQL.SQLOpenFullMutex,SQL.SQLOpenNoFollow] SQL.SQLVFSDefault) SQL.close $ \db -> do
    setFileMode path 0o600
    SQL.exec db "PRAGMA foreign_keys=ON"
    action db
rawRows :: SQL.Database -> Text -> IO [[SQL.SQLData]]
rawRows db statement = bracket (SQL.prepare db statement) SQL.finalize $ \prepared ->
  let loop n = SQL.step prepared >>= \result -> case result of
        SQL.Done -> pure []
        SQL.Row -> if n <= (0::Int) then error "fixture row bound" else (:) <$> SQL.columns prepared <*> loop (n-1)
  in loop 100

documentFixtures :: FilePath -> IO [Value]
documentFixtures source = do
  let directory=source </> "test/fixtures/manager/v1"
  manifest <- BS.readFile (directory </> "manifest.json") >>= right . eitherDecodeStrict'
  cases <- case field "cases" manifest of Array values -> pure (toList values); _ -> error "fixture manifest"
  documents <- mapM (\entry -> do
    value <- BS.readFile (directory </> T.unpack (string (field "file" entry))) >>= right . eitherDecodeStrict'
    check "frozen ExportDocument fixture agrees with public shape validator" (validExportDocument value == (field "valid" entry == Bool True))
    pure [value | field "valid" entry == Bool True]) [entry | entry <- cases, field "schema" entry == String "ExportDocument"]
  let rational=object ["code" .= object ["json" .= object ["schema" .= ("number"::Text)]],"value" .= object ["numerator" .= (1::Int),"denominator" .= (3::Int)]]
  check "native exact rational shape remains valid without decimal coercion" (validExportDocument rational)
  pure (concat documents <> [rational])

typedDocuments :: CoordinationStore -> CredentialProof -> [Value] -> IO ()
typedDocuments store proof documents = do
  forM_ (zip [0::Int ..] documents) $ \(index,document) -> withStoreFiles store $ \root -> do
    let name="typed-"<>show index
        native=RunId (T.pack name)
    ensurePrivateDirectoryAt root ["runs","runs",name]
    bracket (openPrivateSubroot root ["runs"]) closePrivateRoot $ \runs -> do
      let directory=privateRootPath runs </> "runs" </> name </> "runtime"
          code=field "code" document
          value=field "value" document
          manifest=RunManifest native "fixture" "0.1.0.0" Null "scripted" Null Nothing RootRun Nothing (Just PersonAnswerLocalControl)
      reference <- bracket (createRunStoreVersioned 2 2 directory manifest) closeRunStore $ \runtime -> writeResultArtifact runtime native code value "fixture"
      bracket (openPrivateRoot "typed fixture" directory) closePrivateRoot $ \runtime -> withPrivateDirectoryAt runtime [] $ \descriptor -> do
        (_,captured) <- readResultArtifactBytesAt directory descriptor native reference
        check "shared capture preserves frozen value without coercion" (captured == value)
      withPreparedResultExport runs native reference (T.pack name<>".json") $ \prepared -> do
        check "shared pre-publication identity retains exact document" (preparedExportDocument prepared == document)
        publishPreparedResultExport prepared
        (_,captured) <- readPublishedResultExportBytes runs (preparedExportRootIdentity prepared) (T.pack name<>".json") (preparedExportBytes prepared) (preparedExportSha256 prepared) code
        check "published typed document matches frozen decoded fixture" (captured == document)
  association <- withStoreFiles store $ \root -> do
    ensurePrivateDirectoryAt root ["runs","runs","bad-flag"]
    bracket (openPrivateSubroot root ["runs"]) closePrivateRoot $ \runs -> do
      let native=RunId "bad-flag"
          directory=privateRootPath runs </> "runs/bad-flag/runtime"
          bound=RunAssociation "run_bad_flag" "profile_1" (T.pack (privateRootIdentity runs)) native
          manifest=RunManifest native "fixture" "0.1.0.0" Null "scripted" Null Nothing RootRun Nothing (Just PersonAnswerLocalControl)
      reference <- bracket (createRunStoreVersioned 2 2 directory manifest) closeRunStore $ \runtime -> writeResultArtifact runtime native (String "flag") (String "synthetic-token") "fixture"
      mutate store $ execute "INSERT INTO runs(id,revision,control_revision,profile_id,root_identity,native_run_id,supervision,result_state) VALUES ('run_bad_flag','revision','revision','profile_1',?,'bad-flag','observer','absent')" [SQL.SQLText (associationRoot bound)]
      forM_ (zip [0..] [RunStartedV2 "fixture" "scripted" PersonAnswerLocalControl,TraceOrdered [],RunCompletedV2 0 0 reference]) $ \(number,event) ->
        void (ingestRuntimeEnvelope store bound (encodeEnvelope (Envelope 2 native (SeqNo number) "2026-09-03T00:00:00Z" event)))
      pure bound
  handle <- scalar store "SELECT result_artifact_id FROM runs WHERE id='run_bad_flag'"
  refused <- try @Command.CommandFailure (withArtifactDownload store proof handle (\_ _ _ -> error "ill-typed response" :: IO ()))
  check "verified envelope with flag/string mismatch never becomes a response" (refused == Left Command.ResourceUnavailable)
  req <- request store association "bad-flag" "bad-flag.json"
  publication <- try @Command.CommandFailure (submitExport store proof association req)
  check "verified envelope with flag/string mismatch never becomes an export" (case publication of Left Command.ResourceUnavailable -> True; _ -> False)
  absent <- runRead store ((== [[SQL.SQLInteger 0]]) <$> query "SELECT count(*) FROM exports WHERE run_id='run_bad_flag'" [])
  check "ill-typed result creates no accepted publication intent" absent

check :: String -> Bool -> IO ()
check label condition = unless condition (error ("FAIL "<>label)) >> putStrLn ("PASS "<>label)
right :: Show e => Either e a -> IO a
right = either (error . show) pure
field :: Text -> Value -> Value
field key (Object fields) = maybe Null id (KM.lookup (fromString key) fields)
  where fromString = Key.fromText
field _ _ = Null
has :: Text -> Value -> Bool
has key (Object fields) = KM.member (Key.fromText key) fields
has _ _ = False
string :: Value -> Text
string (String value) = value
string _ = error "expected string"
noTicket :: Commands.Submission -> Bool
noTicket value = case Commands.submissionTicket value of Nothing -> True; _ -> False
mutate :: NFData a => CoordinationStore -> Transaction a -> IO a
mutate store action = runTransaction store $ do
  value <- action
  pure (value,[Invalidation "service.changed" "/v1/capabilities" "fixture"])
scalar :: CoordinationStore -> Text -> IO Text
scalar store sql = runRead store $ do
  rows <- query sql []
  case rows of [[SQL.SQLText value]] -> pure value; _ -> refuseTransaction StoreIntegrity
bearer :: BS.ByteString
bearer = BS.replicate 32 97

fixture :: FilePath -> IO (FilePath,FilePath)
fixture work = do
  let root=work </> "manager"; path=work </> "config.json"
  createDirectory root
  setFileMode root 0o700
  BS.writeFile path $ Command.encoded $ object
    ["version" .= (1::Int),"managerRoot" .= root,"localRetentionRoots" .= ([]::[String]),
     "runners" .= [object ["alias" .= ("runner"::Text),"executable" .= ("/bin/false"::Text),"prefix" .= ([]::[String])]],
     "profiles" .= [object ["id" .= ("profile_1"::Text),"runner" .= ("runner"::Text),"workspace" .= work,
       "workspaceLabel" .= ("fixture"::Text),"targetLabel" .= ("no execution"::Text),"targetArguments" .= ([]::[String]),
       "environment" .= ([]::[String]),"ownership" .= ("service-owned"::Text),"quarantined" .= False,
       "personAnswering" .= ("engine"::Text),"resourceKeys" .= ([]::[String])]],
     "limits" .= object ["drafts" .= (100::Int),"globalDrafts" .= (100::Int),"globalCaptureBytes" .= (67108864::Int),
       "globalPageSets" .= (2::Int),"globalConnections" .= (8::Int),"globalDatabaseReaders" .= (2::Int),
       "globalMutationLedgerBytes" .= (16777216::Int),"safetyControlsPerMinute" .= (100::Int),"executionReservations" .= (1::Int)]]
  setFileMode path 0o600
  pure (path,root)
withInstalled :: FilePath -> (InstalledConfiguration -> IO a) -> IO a
withInstalled path action = do
  config <- loadConfiguration (\args -> if null args then Right () else error "unexpected target") exactPreparedTarget (const False) path >>= right
  bracket (installConfiguration config >>= right) closeConfiguration action
seed :: CoordinationStore -> IO ()
seed store = mutate store $ do
  execute "INSERT INTO clients VALUES ('client_1','client_revision','authorization_revision',0)" []
  execute "INSERT INTO credentials VALUES ('credential_1','client_1',?,'2999-01-01T00:00:00Z',0)" [SQL.SQLBlob (convert (hash bearer::Digest SHA256))]
  forM_ ["observe","export"] $ \scope -> execute "INSERT INTO credential_scopes VALUES ('credential_1','profile_1',?)" [SQL.SQLText scope]

sourceRun :: CoordinationStore -> IO (RunAssociation,ResultRef,FilePath)
sourceRun store = withStoreFiles store $ \root -> do
  ensurePrivateDirectoryAt root ["runs","runs","native-21"]
  bracket (openPrivateSubroot root ["runs"]) closePrivateRoot $ \runs -> do
    let native=RunId "native-21"
        directory=privateRootPath runs </> "runs/native-21/runtime"
        association=RunAssociation "run_21" "profile_1" (T.pack (privateRootIdentity runs)) native
        manifest=RunManifest native "fixture" "0.1.0.0" Null "scripted" Null Nothing RootRun Nothing (Just PersonAnswerLocalControl)
    reference <- bracket (createRunStoreVersioned 2 2 directory manifest) closeRunStore $ \runtime -> writeResultArtifact runtime native (String "flag") (Bool False) "false"
    mutate store $ execute "INSERT INTO runs(id,revision,control_revision,profile_id,root_identity,native_run_id,supervision,result_state) VALUES ('run_21','revision','revision','profile_1',?,'native-21','observer','absent')" [SQL.SQLText (associationRoot association)]
    pure (association,reference,directory)

ingest :: CoordinationStore -> RunAssociation -> ResultRef -> IO ()
ingest store association reference = do
  let occurrence=OccurrenceId maxBound; attempt=AttemptId occurrence maxBound
      events=[RunStartedV2 "fixture" "scripted" PersonAnswerLocalControl,
        OccurrenceStarted occurrence "flag" "fixture" "engine" "synthetic prompt",
        AttemptStarted attempt "scripted",AttemptOutput attempt "雪😀\n",
        AttemptProgress attempt (ProgressMessage "Public diagnostic."),AttemptCompleted attempt "fresh",
        OccurrenceCompleted occurrence "fresh" "false",TraceOrdered [occurrence],RunCompletedV2 1 0 reference]
  forM_ (zip [0..] events) $ \(number,event) -> do
    let bytes = encodeEnvelope (Envelope 2 (associationNative association) (SeqNo number) "2026-09-03T00:00:00Z" event)
    void (ingestRuntimeEnvelope store association bytes)

outputBounds :: CoordinationStore -> CredentialProof -> FilePath -> IO ()
outputBounds store proof work = do
  rootIdentity <- scalar store "SELECT root_identity FROM runs WHERE id='run_21'"
  let native=RunId "bounded-output"
      association=RunAssociation "run_bounded" "profile_1" rootIdentity native
      occurrence=OccurrenceId 0
      attempt=AttemptId occurrence 0
      secret="synthetic-token <script>\ESC[31m"
      transport=T.replicate 70000 "x"<>secret
      diagnostic=T.replicate 9000 "d"<>secret
      events=[RunStartedV2 "fixture" "scripted" PersonAnswerLocalControl,
        OccurrenceStarted occurrence "text" "fixture" "engine" "private prompt",
        AttemptStarted attempt "scripted",AttemptOutput attempt transport,
        AttemptFailed attempt FailureTransport diagnostic,OccurrenceFailed occurrence FailureTransport diagnostic,
        RunFailed FailureRuntime diagnostic]
  mutate store $ execute "INSERT INTO runs(id,revision,control_revision,profile_id,root_identity,native_run_id,supervision,result_state) VALUES ('run_bounded','revision','revision','profile_1',?,'bounded-output','observer','absent')" [SQL.SQLText rootIdentity]
  forM_ (zip [0..] events) $ \(number,event) -> void $ ingestRuntimeEnvelope store association
    (encodeEnvelope (Envelope 2 native (SeqNo number) "2026-09-03T00:00:00Z" event))
  withRunOutputs store proof association $ \_ items -> do
    check "attempt transport retains bounded attributed tail" (case items of
      item:_ -> field "transportText" item == String (T.takeEnd 65536 transport)
      [] -> False)
    let diagnostics=[string (field "message" item) | item <- items,field "kind" item==String "diagnostic"]
    check "authorized diagnostics have independent 8192-character ceiling" (length diagnostics==2 && all ((==8192) . T.length) diagnostics)
    check "absent result remains distinct from runtime failure" (field "state" (field "verification" (last items))==String "absent")
    let wire=Command.encoded items
    check "JSON encoding carries control text without literal terminal escapes" (not ("\ESC[31m" `BS.isInfixOf` wire))
    BS.writeFile (work </> "bounded-outputs.json") wire

rawChecks :: CoordinationStore -> CredentialProof -> RunAssociation -> Text -> ResultRef -> FilePath -> BS.ByteString -> IO ()
rawChecks store proof association handle reference directory original = do
  let result=directory </> "result.json"
      download=withArtifactDownload store proof handle (\_ _ _ -> error "unverified content reached response" :: IO ())
  BS.writeFile result "synthetic-token <script>\ESC[31m provider diagnostic"
  failed <- try @Command.CommandFailure download
  check "corrupt content never reaches response or incidental exception" (failed == Left Command.ResourceUnavailable)
  withRunOutputs store proof association $ \_ items -> do
    check "corrupt result is unavailable independently" (field "state" (field "verification" (last items)) == String "unavailable")
    check "sensitive bytes absent from unavailable output" (not ("synthetic-token" `BS.isInfixOf` Command.encoded items))
  snapshot <- requireProjection store association
  check "corrupt result does not change runtime success" (snapshotRunStatus snapshot == RunSucceeded)
  BS.writeFile result original
  BS.writeFile (directory </> "events.ndjson") "not a journal"
  withArtifactDownload store proof handle (\_ _ bytes -> check "good known reference ignores damaged journal" (bytes == original))
  withArtifactDownload store proof handle $ \_ _ captured -> do
    BS.writeFile result "changed after capture"
    check "response owns captured bytes rather than a reopened file" (captured == original)
  BS.writeFile result original
  renameFile result (result<>".retained")
  withRunOutputs store proof association $ \_ items ->
    check "missing result has its distinct unavailable reason" (field "reason" (field "verification" (last items)) == String "missing")
  bracket (openPrivateRoot "missing fixture" directory) closePrivateRoot $ \runtime -> withPrivateDirectoryAt runtime [] $ \descriptor -> do
    legacy <- try @StoreError (readResultArtifactAt directory descriptor (associationNative association) reference)
    captured <- try @IOException (readResultArtifactBytesAt directory descriptor (associationNative association) reference)
    check "legacy missing result retains StoreCorrupt exception" (case legacy of Left (StoreCorrupt _ _) -> True; _ -> False)
    check "captured missing result preserves original typed ENOENT" (case captured of Left failure -> isDoesNotExistError failure; _ -> False)
  createSymbolicLink (result<>".retained") result
  symlink <- try @Command.CommandFailure download
  check "source leaf symlink cannot produce content" (symlink == Left Command.ResourceUnavailable)
  removeFile result
  renameFile (result<>".retained") result
  setFileMode result 0o000
  withRunOutputs store proof association $ \_ items ->
    check "unreadable result has fixed ownership-unavailable status" (field "reason" (field "verification" (last items)) == String "ownership-unavailable")
  bracket (openPrivateRoot "mode fixture" directory) closePrivateRoot $ \runtime -> withPrivateDirectoryAt runtime [] $ \descriptor -> do
    legacy <- try @StoreError (readResultArtifactAt directory descriptor (associationNative association) reference)
    captured <- try @IOException (readResultArtifactBytesAt directory descriptor (associationNative association) reference)
    check "legacy permission failure retains StoreCorrupt exception" (case legacy of Left (StoreCorrupt _ _) -> True; _ -> False)
    check "captured permission failure preserves typed IO refusal" (case captured of Left failure -> isPermissionError failure; _ -> False)
  setFileMode result 0o600
  bracket (openPrivateRoot "fixture runtime" directory) closePrivateRoot $ \runtime ->
    withPrivateDirectoryAt runtime [] $ \descriptor -> do
      forM_ [("wrong run",RunId "other",reference),("wrong code",associationNative association,reference {resultArtifactCode=String "text"}),
        ("wrong hash",associationNative association,reference {resultArtifactSha256=T.replicate 64 "0"}),
        ("wrong size",associationNative association,reference {resultArtifactBytes=resultArtifactBytes reference-1}),
        ("wrong reference version",associationNative association,reference {resultArtifactVersion=2}),
        ("oversized reference",associationNative association,reference {resultArtifactBytes=maxArtifactBytes+1})] $ \(label,native,ref) -> do
          bad <- try @StoreError (readResultArtifactBytesAt directory descriptor native ref)
          check label (case bad of Left (StoreCorrupt _ _) -> True; _ -> False)
      let noncanonical=original<>"\n"
          expected=reference {resultArtifactBytes=toInteger (BS.length noncanonical),resultArtifactSha256=T.pack (show (hash noncanonical::Digest SHA256))}
      BS.writeFile result noncanonical
      legacy <- try @StoreError (readResultArtifactAt directory descriptor (associationNative association) expected)
      captured <- try @StoreError (readResultArtifactBytesAt directory descriptor (associationNative association) expected)
      check "both reader surfaces reject correctly hashed noncanonical bytes" (case (legacy,captured) of
        (Left (StoreCorrupt _ _),Left (StoreCorrupt _ _)) -> True
        _ -> False)
      BS.writeFile result original
  entered <- newEmptyMVar
  release <- newEmptyMVar
  reader <- async (withArtifactDownload store proof handle (\_ _ _ -> putMVar entered () >> takeMVar release))
  takeMVar entered
  overlapping <- try @StoreFailure (withArtifactDownload store proof handle (\_ _ _ -> error "second response admitted" :: IO ()))
  check "single aggregate read loan spans response callback" (overlapping == Left StoreBusy)
  putMVar release ()
  wait reader

request :: CoordinationStore -> RunAssociation -> Text -> Text -> IO Commands.CommandRequest
request store association key name = do
  identity <- storeIdentity store
  revision <- runRead store $ do
    rows <- query "SELECT revision FROM runs WHERE id=?" [SQL.SQLText (associationRun association)]
    case rows of [[SQL.SQLText value]] -> pure value; _ -> refuseTransaction StoreIntegrity
  pure $ Commands.CommandRequest Command.Export "profile_1" "POST" ("/v1/runs/"<>associationRun association<>"/exports")
    (storeAuthorityEpoch identity<>"."<>key<>T.replicate 22 "a") "application/json" (Just ("\""<>revision<>"\"")) (Command.encoded (object ["name" .= name]))
submitNamed :: CoordinationStore -> CredentialProof -> RunAssociation -> Text -> IO Text
submitNamed store proof association name = do
  req <- request store association name (name<>".json")
  submission <- submitExport store proof association req >>= right
  pure ("export_"<>Command.receiptId (Commands.submissionReceipt submission))

authChecks :: CoordinationStore -> CredentialProof -> RunAssociation -> Text -> Text -> Text -> IO ()
authChecks store proof association source exported exportId = do
  mutate store $ execute "DELETE FROM credential_scopes WHERE scope='export'" []
  withArtifactDownload store proof exported (\_ _ _ -> check "observe alone may download published content" True)
  unauthorized <- request store association "unauthorized" "unauthorized.json" >>= submitExport store proof association
  check "publication needs export scope" (case unauthorized of Left Command.Forbidden -> True; _ -> False)
  reconciliation <- try @Command.CommandFailure (reconcileExport store proof exportId)
  check "reconciliation needs export scope" (reconciliation == Left Command.Forbidden)
  mutate store $ execute "DELETE FROM credential_scopes WHERE scope='observe'" []
  denied <- try @Command.CommandFailure (withArtifactDownload store proof source (\_ _ _ -> error "unauthorized response" :: IO ()))
  check "current observe scope checked before content" (denied == Left Command.Forbidden)
  mutate store $ forM_ ["observe","export"] $ \scope -> execute "INSERT INTO credential_scopes VALUES ('credential_1','profile_1',?)" [SQL.SQLText scope]
  mutate store $ execute "UPDATE credentials SET revoked=1" []
  revoked <- try @Command.CommandFailure (withArtifactDownload store proof source (\_ _ _ -> error "revoked response" :: IO ()))
  check "credential revoked before download call is refused" (revoked == Left Command.Unauthenticated)
  mutate store $ execute "UPDATE credentials SET revoked=0" []

runtimeRaces :: CoordinationStore -> RunAssociation -> ResultRef -> IO ()
runtimeRaces store association reference = withStoreFiles store $ \root ->
  bracket (openPrivateSubroot root ["runs"]) closePrivateRoot $ \runs -> do
    withPreparedResultExport runs (associationNative association) reference "runtime-race.json" $ \left ->
      withPreparedResultExport runs (associationNative association) reference "runtime-race.json" $ \rightExport -> do
        (a,b) <- concurrently (try @IOException (publishPreparedResultExport left)) (try @IOException (publishPreparedResultExport rightExport))
        check "shared publisher has exactly one complete exclusive winner" (length [() | Right () <- [a,b]] == 1)
        bytes <- readPublishedResultExport runs (preparedExportRootIdentity left) "runtime-race.json" (preparedExportBytes left) (preparedExportSha256 left) (String "flag")
        check "exclusive winner has intended byte count" (toInteger (BS.length bytes) == preparedExportBytes left)
        oversized <- try @IOException (readPublishedResultExport runs (preparedExportRootIdentity left) "runtime-race.json" (maxArtifactBytes+1) (preparedExportSha256 left) (String "flag"))
        check "export read rejects oversized bound before content" (case oversized of Left _ -> True; _ -> False)
    withPreparedResultExport runs (associationNative association) reference "replaced-root.json" $ \prepared -> do
      let exports=privateRootPath runs </> "exports"
      renameDirectory exports (exports<>".retained")
      createDirectory exports
      setFileMode exports 0o700
      refused <- try @IOException (publishPreparedResultExport prepared)
      check "prepared publication refuses substituted export root" (case refused of Left _ -> True; _ -> False)
      renameDirectory exports (exports<>".prepared-replacement")
      renameDirectory (exports<>".retained") exports

badRequests :: CoordinationStore -> CredentialProof -> RunAssociation -> IO ()
badRequests store proof association = do
  req <- request store association "bad-name" "unused"
  huge <- submitExport store proof association req {Commands.commandBody=BS.replicate 2097153 32}
  check "mutation byte cap applies before JSON decoding" (case huge of Left Command.SizeLimit -> True; _ -> False)
  forM_ [object ["name" .= ("../escape"::Text)],object ["name" .= ("ok"::Text),"path" .= ("/tmp/escape"::Text)],object ["name" .= T.replicate 129 "a"],object ["name" .= ("雪"::Text)]] $ \body -> do
    denied <- submitExport store proof association req {Commands.commandBody=Command.encoded body}
    check "frozen export mutation refuses paths, extra keys and out-of-bound names" (case denied of Left Command.InvalidRequest -> True; _ -> False)

exportSubstitution :: CoordinationStore -> CredentialProof -> Text -> FilePath -> IO ()
exportSubstitution store proof handle root = do
  let exports=root </> "runs/exports"
      leaf=exports </> "review-result.json"
  renameFile leaf (leaf<>".retained")
  createSymbolicLink (leaf<>".retained") leaf
  symlink <- try @Command.CommandFailure (withArtifactDownload store proof handle (\_ _ _ -> error "export symlink response" :: IO ()))
  check "export leaf symlink cannot produce content" (symlink == Left Command.ResourceUnavailable)
  removeFile leaf
  renameFile (leaf<>".retained") leaf
  renameDirectory exports (exports<>".retained")
  createDirectory exports
  setFileMode exports 0o700
  failed <- try @Command.CommandFailure (withArtifactDownload store proof handle (\_ _ _ -> error "substituted export response" :: IO ()))
  check "export root replacement cannot produce content" (failed == Left Command.ResourceUnavailable)
  renameDirectory exports (exports<>".replacement")
  renameDirectory (exports<>".retained") exports

rootSubstitution :: CoordinationStore -> CredentialProof -> RunAssociation -> Text -> FilePath -> IO ()
rootSubstitution store proof _ handle root = do
  let runs=root </> "runs"
  renameDirectory runs (runs<>".retained")
  createDirectory runs
  setFileMode runs 0o700
  failed <- try @Command.CommandFailure (withArtifactDownload store proof handle (\_ _ _ -> error "substituted state response" :: IO ()))
  check "state root replacement cannot produce content" (failed == Left Command.ResourceUnavailable)
  renameDirectory runs (runs<>".replacement")
  renameDirectory (runs<>".retained") runs
