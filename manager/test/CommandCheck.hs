{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE PackageImports #-}
{-# LANGUAGE TypeApplications #-}
module Main (main) where

import qualified "agentic" Agentic.Manager as Public
import Agentic.Manager.Credentials (administerCredentials)
import Agentic.Manager.LocalAdmin (withLocalAdministration)
import qualified Agentic.Manager.Protocol.LocalAdmin as Admin
import Agentic.Manager.Authorization
import Agentic.Manager.Commands
import Agentic.Manager.Configuration
import Agentic.Manager.Profile (Diagnostic, publicRevision)
import Agentic.Manager.Protocol.Command
import Agentic.Manager.Protocol.Json (representableEditorSchema)
import Agentic.Manager.Schema (schemaVersion, schemaStatements)
import Agentic.Manager.Store
import qualified Agentic.Manager.Test.AcceptanceAudit as Audit
import qualified Agentic.Runtime as Runtime
import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (atomically)
import Control.Concurrent.Async (AsyncCancelled (..), async, cancel, concurrently, poll, wait, waitCatch)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar, tryPutMVar)
import System.Timeout (timeout)
import Control.DeepSeq (NFData)
import Control.Exception (AsyncException (UserInterrupt), bracket, fromException, throwIO, try)
import Control.Monad (forM_, unless, void)
import Crypto.Hash (Digest, SHA256, hash)
import Data.Aeson (FromJSON (parseJSON), Value (..), eitherDecodeStrict', object, toJSON, withObject, (.:), (.=))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import Data.Foldable (toList)
import Data.Bits ((.&.))
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import Data.ByteArray (convert)
import qualified Data.ByteString as BS
import Data.IORef (writeIORef, modifyIORef', newIORef, readIORef)
import Data.Int (Int64)
import Data.Maybe (isNothing)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Database.SQLite3 as SQL
import qualified Database.SQLite3.Direct as Direct
import Foreign.Ptr (Ptr)
import Foreign.C.Types (CInt (..))
import System.Directory (createDirectory, doesFileExist)
import System.Environment (getArgs)
import System.FilePath ((</>), takeDirectory)
import System.IO (BufferMode (LineBuffering), hSetBuffering, stdout)
import System.Posix.Files (setFileMode, fileMode, getSymbolicLinkStatus)

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  args <- getArgs
  case args of
    ["quota-pressure",work] -> preflightRetentionChecks work >> capacityChecks work >> rateChecks work
    ["deadline-crossing",work] -> commandDeadlineChecks work
    ["authorization-commit-gap",work] -> credentialCommitGapChecks work
    ["hold-credentials",path] -> withInstalled path $ \installed -> withCoordinationStore installed $ \_ ->
      putStrLn "ready" >> threadDelay 60000000
    ["serve-credentials",path] -> serveCredentialChecks path
    [work, source] -> do
      credentialParserChecks source
      credentialAdministrationChecks work
      credentialRepresentationChecks work
      credentialFailureChecks work
      credentialMigrationChecks work
      credentialBoundsChecks work
      publicComposition work
      replayChecks work
      retainedAttemptChecks work
      controlBindingChecks work
      commandDeadlineChecks work
      localEffectChecks work
      bindingBounds work
      dispatchChecks work
      restartDispatchChecks work
      preflightRetentionChecks work
      capacityChecks work
      rateChecks work
      rollbackChecks work
      migrationChecks work
      largestLegacyChecks work
      legacyCaptureChecks work
      codecChecks work source
      putStrLn "PASS manager command receipts and idempotency"
    _ -> error "usage: manager-command-check PRIVATE_DIRECTORY PACKAGE_DIRECTORY"

-- The Python CLI owner drives these barriers through the original private pipe.
-- Only this fixture reads its disposable bearer file, never argv or diagnostics.
serveCredentialChecks :: FilePath -> IO ()
serveCredentialChecks path = do
  configuration <- loadConfiguration
    (\args -> if args == ["--scripted"] then Right () else error "unexpected live fixture target")
    exactPreparedTarget (const False) path >>= right
  bracket (installConfiguration configuration >>= right) closeConfiguration $ \installed ->
    withCoordinationStore installed $ \store -> withLocalAdministration store $ do
      conflict <- try @Diagnostic (withLocalAdministration store (pure ()))
      requireCheck "second live endpoint refuses without replacing the original"
        (case conflict of Left _ -> True; Right _ -> False)
      putStrLn "ready"
      command <- getLine
      unless (command == "stop") $ do
        requireCheck "live fixture watch barrier" (command == "watch")
        bearer <- BS.readFile (takeDirectory path </> "cli-live.credential")
        proof <- authenticateCredential store bearer >>= right
        withStoreWorker store $ \_ _ active -> withStoreFiles store $ \_ ->
          withAuthorizedResponse store proof "profile_1" [Observe] $ \view -> do
            putStrLn "watching"
            getLine >>= requireCheck "unrelated revocation barrier" . (== "unrelated")
            unchanged <- timeout 7000000 (awaitAuthorizedView view)
            requireCheck "unrelated client revocation preserves retained response" (unchanged == Just (Right ()))
            atomically active >>= requireCheck "unrelated revocation preserves original worker registration"
            putStrLn "unchanged"
            getLine >>= requireCheck "own revocation barrier" . (== "revoked")
            revoked <- timeout 7000000 (awaitAuthorizedView view)
            requireCheck "live CLI revocation invalidates retained response" (revoked == Just (Left Unauthenticated))
            atomically active >>= requireCheck "own revocation preserves original worker registration"
            putStrLn "revoked"
        getLine >>= requireCheck "live fixture stop barrier" . (== "stop")
  putStrLn "closed"
  where
    requireCheck label condition = unless condition (error ("FAIL " <> label))

check :: String -> Bool -> IO ()
check label condition = unless condition (error ("FAIL " <> label)) >> putStrLn ("PASS " <> label)
right :: Show e => Either e a -> IO a
right = either (error . show) pure
expect :: String -> CommandFailure -> IO (Either CommandFailure a) -> IO ()
expect label expected action = action >>= \outcome -> check label (case outcome of Left actual -> actual == expected; Right _ -> False)

bearerA, bearerRotated, bearerB :: BS.ByteString
bearerA = BS.replicate 32 97
bearerRotated = BS.replicate 32 98
bearerB = BS.replicate 32 99
verifier :: BS.ByteString -> BS.ByteString
verifier bytes = convert (hash bytes :: Digest SHA256)

fixture :: FilePath -> String -> Int64 -> Int -> IO (FilePath, FilePath)
fixture work name capacity safety = do
  let root = work </> name
      path = work </> (name <> ".json")
  createDirectory root
  setFileMode root 0o700
  BS.writeFile path $ encoded $ object
    ["version" .= (1 :: Int), "managerRoot" .= root, "localRetentionRoots" .= ([] :: [String]),
     "runners" .= [object ["alias" .= ("runner" :: Text), "executable" .= ("/bin/false" :: Text), "prefix" .= ([] :: [String])]],
     "profiles" .= [object ["id" .= ("profile_1" :: Text), "runner" .= ("runner" :: Text), "workspace" .= work,
       "workspaceLabel" .= ("fixture" :: Text), "targetLabel" .= ("no execution" :: Text),
       "targetArguments" .= ([] :: [String]), "environment" .= ([] :: [String]),
       "ownership" .= ("service-owned" :: Text), "quarantined" .= False,
       "personAnswering" .= ("engine" :: Text), "resourceKeys" .= ([] :: [String])]],
     "limits" .= object ["drafts" .= (100 :: Int), "globalDrafts" .= (100 :: Int),
       "globalCaptureBytes" .= (67108864 :: Int), "globalPageSets" .= (2 :: Int),
       "globalConnections" .= (8 :: Int), "globalDatabaseReaders" .= (2 :: Int),
       "globalMutationLedgerBytes" .= capacity, "safetyControlsPerMinute" .= safety,
       "executionReservations" .= (1 :: Int)]]
  setFileMode path 0o600
  pure (path, root)

load :: FilePath -> IO Configuration
load path = loadConfiguration (\args -> if null args then Right () else error "unexpected fixture target")  exactPreparedTarget (const False) path >>= right
withInstalled :: FilePath -> (InstalledConfiguration -> IO a) -> IO a
withInstalled path action = load path >>= \configuration -> bracket (installConfiguration configuration >>= right) closeConfiguration action
withFixture :: FilePath -> String -> Int64 -> Int -> (FilePath -> FilePath -> InstalledConfiguration -> CoordinationStore -> Text -> CredentialProof -> IO a) -> IO a
withFixture work name capacity safety action = do
  (path, root) <- fixture work name capacity safety
  withInstalled path $ \installed -> withCoordinationStore installed $ \store -> do
    revision <- profileRevision installed
    mutate store seed
    proof <- authenticateCredential store bearerA >>= right
    action path root installed store revision proof
profileRevision :: InstalledConfiguration -> IO Text
profileRevision installed = do
  (_, profiles) <- configurationSnapshot installed >>= right
  case profiles of [profile] -> pure (publicRevision profile); _ -> error "fixture profile missing"

seed :: Transaction ()
seed = do
  execute "INSERT INTO clients VALUES ('client_1','client_revision','authorization_revision',0),('client_2','client_revision','authorization_revision',0)" []
  forM_ [("credential_a", "client_1", bearerA), ("credential_rotated", "client_1", bearerRotated), ("credential_b", "client_2", bearerB)] $ \(credential, client, bearer) -> do
    execute "INSERT INTO credentials VALUES (?,?,?,'2999-01-01T00:00:00Z',0)" [SQL.SQLText credential, SQL.SQLText client, SQL.SQLBlob (verifier bearer)]
    forM_ ["observe", "submit", "control", "export"] $ \scope ->
      execute "INSERT INTO credential_scopes VALUES (?,'profile_1',?)" [SQL.SQLText credential, SQL.SQLText scope]
  execute "INSERT INTO requests (id,revision,client_id,workflow_id,descriptor_revision,profile_id,profile_revision,phase,admission,blocking_reasons,validation_errors) VALUES ('request_1','r0','client_1','workflow_1','descriptor_1','profile_1','profile_revision','draft','not-queued',X'5b5d',X'5b5d')" []
  execute "INSERT INTO runs (id,revision,control_revision,request_id,profile_id,root_identity,native_run_id,supervision,result_state) VALUES ('run_1','run_revision','control_revision','request_1','profile_1','root_1','native_1','owned','absent')" []

mutate :: NFData a => CoordinationStore -> Transaction a -> IO a
mutate store action = runTransaction store $ do
  value <- action
  pure (value, [Invalidation "service.changed" "/v1/capabilities" "fixture_revision"])
scalarText :: CoordinationStore -> Text -> IO Text
scalarText store statement = runRead store $ do
  rows <- query statement []
  case rows of [[SQL.SQLText value]] -> pure value; _ -> refuseTransaction StoreIntegrity
scalarInt :: CoordinationStore -> Text -> IO Int64
scalarInt store statement = runRead store $ do
  rows <- query statement []
  case rows of [[SQL.SQLInteger value]] -> pure value; _ -> refuseTransaction StoreIntegrity
rowsEqual :: CoordinationStore -> Text -> [[SQL.SQLData]] -> IO Bool
rowsEqual store statement expected = runRead store ((== expected) <$> query statement [])

request :: CoordinationStore -> Operation -> Text -> IO CommandRequest
request store operation nonce = do
  epoch <- scalarText store "SELECT authority_epoch FROM service_metadata"
  pure $ CommandRequest operation "profile_1" "POST" (if operation == Cancel then "/v1/runs/run_1/control" else "/v1/requests/request_1")
    (epoch <> "." <> T.replicate 22 "n" <> nonce) "application/json"
    (Just (if operation == Cancel then "\"control_revision\"" else "\"r0\""))
    (if operation == Cancel then "{\"operation\":\"cancel\"}" else "{\"operation\":\"set-input\",\"input\":{\"name\":\"input_1\",\"source\":\"literal\",\"value\":\"hello\"}}")

edit :: Text -> Text -> Text -> Mutation
edit profile uri next = Mutation profile version validate
  where
    version = do
      rows <- query "SELECT profile_id,revision FROM requests WHERE id='request_1'" []
      pure $ case rows of [[SQL.SQLText p, SQL.SQLText r]] -> Just (uri, p, r); _ -> Nothing
    validate = do
      rows <- query "SELECT phase FROM requests WHERE id='request_1'" []
      pure $ if rows == [[SQL.SQLText "draft"]]
        then Right (Intent (noReferences {referenceRequest = Just "request_1"}) False $ do
          execute "UPDATE requests SET revision=? WHERE id='request_1'" [SQL.SQLText next]
          pure ([Invalidation "request.changed" uri next], Nothing))
        else Left StateConflict

control :: Text -> Mutation
control profile = Mutation profile version validate
  where
    version = do
      rows <- query "SELECT profile_id,control_revision FROM runs WHERE id='run_1'" []
      pure $ case rows of [[SQL.SQLText p, SQL.SQLText r]] -> Just ("/v1/runs/run_1/control", p, r); _ -> Nothing
    validate = do
      rows <- query "SELECT supervision FROM runs WHERE id='run_1'" []
      pure $ if rows == [[SQL.SQLText "owned"]]
        then Right (Intent (noReferences {referenceRun = Just "run_1"}) True (pure ([], Nothing)))
        else Left OwnershipUnavailable

ticketOf :: Submission -> IO DispatchTicket
ticketOf submission = maybe (error "missing new dispatch ticket") pure (submissionTicket submission)

-- Ledger/ownership checks supplement the genuine Worker delivery gate.
controlBindingChecks :: FilePath -> IO ()
controlBindingChecks work = do
  (path,req,receipt) <- withFixture work "control-binding" (64*commandCapacity) 20 $ \path _ _ store profile proof -> do
    initial<-request store Cancel "control-binding"
    let base=commandResource initial<>"?"
        uri=base<>T.replicate(8192-T.length base)"x"
        revision=T.replicate 128 "r"
        original=commandBody initial
        req=initial {commandResource=uri,commandKey=commandKey initial<>T.replicate(128-T.length(commandKey initial))"n",
          commandPrecondition=Just("\""<>revision<>"\""),commandBody=original<>BS.replicate(2097152-BS.length original)32}
        encoder ident=either(const(Left InvalidRequest))Right(Runtime.encodeControlFor 2(Runtime.Control(Runtime.ControlId ident)Nothing Nothing Runtime.CancelRun))
        builder candidate _ _=Right (control profile)
          {mutationVersion=pure(Just(uri,"profile_1",revision)),mutationValidate=pure(Right(Intent(noReferences {referenceRun=Just "run_1"})True $ do
            bytes<-either refuseTransaction pure(encoder candidate)
            execute "INSERT INTO control_intents(command_id,run_id,native_command,native_sha256,native_bytes) VALUES (?,'run_1','cancelRun',?,?)"
              [SQL.SQLText candidate,SQL.SQLText(T.pack(show(hash bytes::Digest SHA256))),SQL.SQLInteger(fromIntegral(BS.length bytes))]
            pure([],Nothing)))}
    mutate store(execute "UPDATE runs SET control_revision=? WHERE id='run_1'" [SQL.SQLText revision])
    attempt<-newControlCommandAttempt store proof req encoder
    accepted<-submitCommandAttempt attempt builder >>=right
    ticket<-ticketOf accepted
    expected<-right(encoder(dispatchCommandId ticket))
    reserveDispatch ticket >>=right
    entered<-newEmptyMVar
    release<-newEmptyMVar
    bracket(async(attemptControlDispatch ticket(\bytes->putMVar entered()>>takeMVar release>>pure(bytes==expected))))
      (\worker->void(tryPutMVar release())>>void(waitCatch worker)) $ \worker->do
        takeMVar entered
        discarded<-attemptControlDispatch ticket(\_->error "losing claimant received bytes")
        check "competing control claimant has no original payload" (case discarded of Left OwnershipUnavailable->True;_->False)
        discardControlPayload ticket
        putMVar release()
        result<-wait worker >>=right
        check "discard cannot disrupt consumed winner's original payload" result
    scalarInt store "SELECT count(*) FROM pragma_table_info('control_intents') WHERE type='BLOB'" >>=check "durable control binding contains no payload BLOB" . (==0)
    scalarInt store "SELECT bytes FROM command_ledger_usage" >>=check "maximal binding fields retain unchanged command reserve" . (==commandCapacity)
    replay<-submitCommand store proof req ((control profile){mutationVersion=pure Nothing}) >>=right
    check "maximal exact body replay has no control payload ticket" (submissionReceipt replay==submissionReceipt accepted && isNothing(submissionTicket replay))
    pure(path,req,submissionReceipt accepted)
  withInstalled path $ \installed->withCoordinationStore installed $ \store->do
    proof<-authenticateCredential store bearerA >>=right
    profile<-profileRevision installed
    replay<-submitCommand store proof req(control profile) >>=right
    check "reopened metadata cannot reconstruct original control payload" (submissionReceipt replay==receipt && isNothing(submissionTicket replay))
    mutate store(execute "UPDATE runs SET supervision='observer' WHERE id='run_1'" [])
    let inactive uri=do
          rows<-query "SELECT supervision FROM runs WHERE id='run_1'" []
          pure(if uri==commandResource req && rows==[[SQL.SQLText "observer"]] then Just "2000-01-01T00:00:00Z" else Nothing)
    retireReceipt store(receiptId receipt)inactive >>=right
    expect "retired control cannot acquire another dispatch" ReceiptExpired(submitCommand store proof req(control profile))
    scalarInt store "SELECT bytes FROM command_ledger_usage" >>=check "retired control metadata fits unchanged tombstone reserve" . (==tombstoneCapacity)

publicComposition :: FilePath -> IO ()
publicComposition work = do
  (path, _) <- fixture work "public" (64 * commandCapacity) 10
  configuration <- Public.loadConfiguration (\args -> if null args then Right () else error "fixture target") Public.exactPreparedTarget (const False) path >>= right
  bracket (Public.installConfiguration configuration >>= right) Public.closeConfiguration $ \installed ->
    Public.withCoordinationStore installed $ \store -> do
      identity <- Public.storeIdentity store
      check "installed public composition uses migrated store" (Public.storeSchemaVersion identity == schemaVersion)

preflightRetentionChecks :: FilePath -> IO ()
preflightRetentionChecks work = withFixture work "preflight-retention" 8388608 10 $ \_ _ _ store profile proof -> do
  req <- request store SetInput "preflight"
  original <- submitCommand store proof req (edit profile (commandResource req) "next") >>= right
  replay <- commandPreflight store proof req (\_ _ _ exists -> pure(exists,[])) >>= right
  check "unretired replay preserves preflight callback path" replay
  mutate store(execute "UPDATE requests SET phase='withdrawn' WHERE id='request_1'" [])
  let inactive _ = do
        rows <- query "SELECT phase FROM requests WHERE id='request_1'" []
        pure(if rows==[[SQL.SQLText "withdrawn"]] then Just "2000-01-01T00:00:00Z" else Nothing)
      forbiddenCallback _ _ _ _ = refuseTransaction StoreIntegrity :: Transaction ((),[Invalidation])
      preflight value=commandPreflight store proof value forbiddenCallback
  retireReceipt store (receiptId(submissionReceipt original)) inactive >>= right
  expect "matching tombstone refuses before preflight callback" ReceiptExpired (preflight req)
  expect "operation conflict precedes tombstone expiry" IdempotencyConflict (preflight (req {commandOperation=RemoveInput}))
  expect "wrong epoch precedes tombstone lookup" AuthorityChanged (preflight (req {commandKey="old_authority."<>T.replicate 22 "n"}))
  mutate store(execute "UPDATE credentials SET revoked=1 WHERE id='credential_a'" [])
  expect "current authorization precedes tombstone lookup" Unauthenticated (preflight req)
  mutate store(execute "INSERT INTO clients VALUES ('retired_client','revision','authorization',1)" [])
  forM_ ["DELETE FROM clients WHERE id='retired_client'",
         "UPDATE clients SET retired=0 WHERE id='retired_client'",
         "UPDATE clients SET id='replacement_client' WHERE id='retired_client'",
         "DELETE FROM credentials WHERE id='credential_a'",
         "UPDATE credentials SET verifier=X'04' WHERE id='credential_a'"] $ \statement -> do
    refused <- try @StoreFailure(mutate store(execute statement []))
    check "retention cannot recycle registered client or credential identities" (refused==Left StoreUnavailable)

replayChecks :: FilePath -> IO ()
replayChecks work = do
  (path, root) <- fixture work "replay" (64 * commandCapacity) 20
  (original, originalRequest, oldProof) <- withInstalled path $ \installed -> withCoordinationStore installed $ \store -> do
    mutate store seed
    profile <- profileRevision installed
    proof <- authenticateCredential store bearerA >>= right
    req <- request store SetInput "first"
    accepted <- submitCommand store proof req (edit profile (commandResource req) "r1") >>= right
    let receipt = submissionReceipt accepted
    check "fresh command accepted without fabricating delivery" (receiptState receipt == Accepted && not (submissionReplayed accepted) && isNothing (receiptAttemptedAt receipt))
    count <- scalarInt store "SELECT count(*) FROM invalidations"
    retry <- submitCommand store proof req (edit profile (commandResource req) "never") >>= right
    check "exact retry returns original receipt after revision advance" (submissionReplayed retry && submissionReceipt retry == receipt && isNothing (submissionTicket retry))
    scalarInt store "SELECT count(*) FROM invalidations" >>= check "retry appends no invalidation" . (== count)
    scalarText store "SELECT revision FROM requests" >>= check "retry applies no second mutation" . (== "r1")
    forM_ [("different exact bytes", req {commandBody = commandBody req <> " "}),
           ("different media type", req {commandMediaType = "application/json; charset=utf-8"}),
           ("different strong precondition", req {commandPrecondition = Just "\"r1\""})] $ \(label, changed) ->
      expect label IdempotencyConflict (submitCommand store proof changed (edit profile (commandResource req) "never"))
    expect "fresh stale revision refuses" StaleRevision (submitCommand store proof (req {commandKey = commandKey req <> "stale"}) (edit profile (commandResource req) "never"))
    expect "missing precondition refuses" PreconditionRequired (submitCommand store proof (req {commandKey = commandKey req <> "missing", commandPrecondition = Nothing}) (edit profile (commandResource req) "never"))
    forM_ ["W/\"r1\"", "*", "\"r1\",\"r2\""] $ \bad -> expect "invalid precondition grammar refuses" InvalidPrecondition $
      submitCommand store proof (req {commandPrecondition = Just bad}) (edit profile (commandResource req) "never")
    expect "wrong same-resource URI validator refuses" InvalidPrecondition $
      submitCommand store proof (req {commandKey = commandKey req <> "uri", commandPrecondition = Just "\"r1\""}) (edit profile "/v1/requests/other" "never")
    let queryReq = req {commandResource = commandResource req <> "?view=exact", commandPrecondition = Just "\"r1\""}
    separate <- submitCommand store proof queryReq (edit profile (commandResource queryReq) "r2") >>= right
    check "canonical URI and query are separate ledger scope" (receiptId (submissionReceipt separate) /= receiptId receipt)
    mutate store (execute "UPDATE requests SET phase='withdrawn'" [])
    void (submitCommand store proof req (edit profile (commandResource req) "never") >>= right)
    expect "fresh lifecycle refusal records no intent" StateConflict $
      submitCommand store proof (req {commandKey = commandKey req <> "phase", commandPrecondition = Just "\"r2\""}) (edit profile (commandResource req) "never")
    rotated <- authenticateCredential store bearerRotated >>= right
    mutate store (execute "UPDATE credentials SET revoked=1 WHERE id='credential_a'" [])
    expect "revocation checked before receipt retry" Unauthenticated (submitCommand store proof req (edit profile (commandResource req) "never"))
    expect "revocation checked before receipt GET" Unauthenticated (readCommand store proof (receiptId receipt))
    replacement <- submitCommand store rotated req (edit profile (commandResource req) "never") >>= right
    check "credential rotation keeps registered-client deduplication" (submissionReceipt replacement == receipt)
    mutate store (execute "DELETE FROM credential_scopes WHERE credential_id='credential_rotated' AND scope='submit'" [])
    expect "current original-operation scopes required for GET" Forbidden (readCommand store rotated (receiptId receipt))
    expect "current scopes required before retry lookup" Forbidden (submitCommand store rotated req (edit profile (commandResource req) "never"))
    mutate store (execute "INSERT INTO credential_scopes VALUES ('credential_rotated','profile_1','submit')" [])
    configuration <- load path
    void (reloadConfiguration installed configuration >>= right)
    void (submitCommand store rotated req (edit profile (commandResource req) "never") >>= right)
    check "profile revision advance does not destroy exact replay" True
    expect "new intent cannot use stale profile revision" StaleRevision $
      submitCommand store rotated (req {commandKey = commandKey req <> "profile", commandPrecondition = Just "\"r2\""}) (edit profile (commandResource req) "never")
    expect "wrong epoch precedes matching ledger lookup" AuthorityChanged $
      submitCommand store rotated (req {commandKey = "old_authority." <> T.replicate 22 "n"}) (edit profile (commandResource req) "never")
    authenticateCredential store (BS.replicate 32 120) >>= check "unknown bearer never mints proof" . either (== Unauthenticated) (const False)
    authenticateCredential store (BS.replicate 513 120) >>= check "oversized bearer bounded before hashing" . either (== Unauthenticated) (const False)
    pure (receipt, req, rotated)
  withInstalled path $ \installed -> withCoordinationStore installed $ \store -> do
    profile <- profileRevision installed
    direct <- runRead store (currentClient oldProof)
    check "authorization primitive itself rejects a different transaction lifetime" (direct == Left Unauthenticated)
    expect "proof cannot cross store lifetime" Unauthenticated (readCommand store oldProof (receiptId original))
    proof <- authenticateCredential store bearerRotated >>= right
    replay <- submitCommand store proof originalRequest (edit profile (commandResource originalRequest) "never") >>= right
    check "restart preserves receipt but cannot reconstruct dispatch" (submissionReceipt replay == original && isNothing (submissionTicket replay))
    expect "active receipt cannot retire" StateConflict (retireReceipt store (receiptId original) (const (pure Nothing)))
    expect "recent inactivity cannot retire" StateConflict (retireReceipt store (receiptId original) (const (pure (Just "2999-01-01T00:00:00Z"))))
    let inactive uri = do
          rows <- query "SELECT phase FROM requests WHERE id='request_1'" []
          pure $ if uri == "/v1/requests/request_1" && rows == [[SQL.SQLText "withdrawn"]] then Just "2000-01-01T00:00:00Z" else Nothing
    retireReceipt store (receiptId original) inactive >>= right
    expect "retired key returns 410 rather than re-executing" ReceiptExpired (submitCommand store proof originalRequest (edit profile (commandResource originalRequest) "never"))
    expect "retired receipt GET returns 410" ReceiptExpired (readCommand store proof (receiptId original))
    rowsEqual store "SELECT body,body_sha256,body_bytes,receipt,media_type,precondition FROM commands WHERE retired=1"
      [[SQL.SQLNull,SQL.SQLNull,SQL.SQLNull,SQL.SQLNull,SQL.SQLNull,SQL.SQLNull]] >>= check "retirement removes content-bearing bindings"
    scalarInt store "SELECT bytes FROM command_ledger_usage" >>= check "tombstone remains charged" . (== commandCapacity + tombstoneCapacity)
    mutate store (execute "UPDATE service_metadata SET authority_epoch='restored_authority'" [])
    expect "current authority fences retired pre-restore keys first" AuthorityChanged (submitCommand store proof originalRequest (edit profile (commandResource originalRequest) "never"))
  check "replay fixture uses ordinary local database" (not (null root))

dispatchChecks :: FilePath -> IO ()
dispatchChecks work = withFixture work "dispatch" (64 * commandCapacity) 20 $ \_ root _ store profile proof -> do
  req <- request store Cancel "dispatch"
  let submit = submitCommand store proof req (control profile)
  (left, rightResult) <- concurrently submit submit
  results <- mapM (\value -> case value of Left StorageUnavailable -> submit >>= right; _ -> right value) [left, rightResult]
  check "matching concurrent callers converge after explicit same-key retry" (case results of
    first : rest -> all ((== receiptId (submissionReceipt first)) . receiptId . submissionReceipt) rest
    [] -> False)
  let tickets = [ticket | result <- results, Just ticket <- [submissionTicket result]]
  check "only new acceptance returns one live ticket" (length tickets == 1)
  ticket <- case tickets of [one] -> pure one; _ -> error "ticket count"
  calls <- newIORef (0 :: Int)
  expect "attempt cannot bypass reservation" OwnershipUnavailable (attemptDispatch ticket (modifyIORef' calls (+1)))
  reserveDispatch ticket >>= right
  expect "reservation is one-shot" OwnershipUnavailable (reserveDispatch ticket)
  (first, second) <- concurrently (attemptDispatch ticket (modifyIORef' calls (+1))) (attemptDispatch ticket (modifyIORef' calls (+1)))
  check "one attempt claimant succeeds" (length [() | Right () <- [first,second]] == 1)
  readIORef calls >>= check "actual callback invoked once" . (== 1)
  current <- readCommand store proof (dispatchCommandId ticket) >>= right
  check "callback success is not acknowledgement or effect" (receiptState current == DispatchAttempted && isNothing (receiptAcknowledgement current) && isNothing (receiptEffect current))
  BS.writeFile (work </> "actual-dispatched.json") (encoded current)
  original <- submit >>= right
  check "retry retains original accepted receipt after dispatch" (receiptState (submissionReceipt original) == Accepted && isNothing (submissionTicket original))
  ack <- decodeValue (object ["commandId" .= dispatchCommandId ticket, "state" .= ("delivered" :: Text), "message" .= ("delivered" :: Text), "command" .= ("cancel" :: Text), "occurrenceId" .= (Nothing :: Maybe Text), "attemptId" .= (Nothing :: Maybe Text)])
  acknowledged <- recordAcknowledgement ticket ack >>= right
  check "explicit correlated acknowledgement is distinct" (receiptState acknowledged == Acknowledged)
  BS.writeFile (work </> "actual-acknowledged.json") (encoded acknowledged)
  bad <- decodeValue (object ["commandId" .= ("another_command" :: Text), "state" .= ("delivered" :: Text), "message" .= ("delivered" :: Text), "command" .= ("cancel" :: Text), "occurrenceId" .= (Nothing :: Maybe Text), "attemptId" .= (Nothing :: Maybe Text)])
  expect "wrong native correlation rejected" StateConflict (recordAcknowledgement ticket bad)
  effect <- decodeValue (object ["kind" .= ("cancelled" :: Text), "resource" .= ("/v1/runs/run_1/snapshot" :: Text), "runtimeSequence" .= ("9" :: Text), "address" .= (Nothing :: Maybe Value)])
  observed <- recordEffect ticket effect >>= right
  check "explicit bound effect observation" (receiptState observed == EffectObserved)
  BS.writeFile (work </> "actual-effect.json") (encoded observed)
  expect "known effect cannot become unresolved" StateConflict (recordUnresolved ticket)
  wrongEffect <- decodeValue (object ["kind" .= ("cancelled" :: Text), "runtimeSequence" .= ("10" :: Text),
    "address" .= (Nothing :: Maybe Value), "resource" .= ("/v1/runs/other/snapshot" :: Text)])
  expect "effect cannot address another run" StateConflict (recordEffect ticket wrongEffect)
  count <- scalarInt store "SELECT count(*) FROM invalidations"
  void (recordEffect ticket effect >>= right)
  scalarInt store "SELECT count(*) FROM invalidations" >>= check "duplicate observation appends no event" . (== count)
  failedRequest <- request store Cancel "failed"
  failedTicket <- submitCommand store proof failedRequest (control profile) >>= right >>= ticketOf
  reserveDispatch failedTicket >>= right
  failure <- try @AsyncException (attemptDispatch failedTicket (throwIO UserInterrupt :: IO ()))
  check "callback asynchronous exception identity preserved" (case failure of Left UserInterrupt -> True; _ -> False)
  unresolved <- readCommand store proof (dispatchCommandId failedTicket) >>= right
  check "callback failure remains unresolved" (receiptState unresolved == Unresolved)
  BS.writeFile (work </> "actual-unresolved.json") (encoded unresolved)
  expect "uncertain callback cannot repeat" OwnershipUnavailable (attemptDispatch failedTicket (modifyIORef' calls (+1)))
  refusedRequest <- request store Cancel "refused"
  refusedTicket <- submitCommand store proof refusedRequest (control profile) >>= right >>= ticketOf
  refused <- recordRefusal refusedTicket "unsupported-operation" >>= right
  check "known refusal remains distinct from unresolved delivery" (receiptState refused == Refused && isNothing (receiptAttemptedAt refused))
  BS.writeFile (work </> "actual-refused.json") (encoded refused)
  expect "known refusal invokes no callback" StateConflict (reserveDispatch refusedTicket)
  markerRequest <- request store Cancel "marker-failure"
  markerTicket <- submitCommand store proof markerRequest (control profile) >>= right >>= ticketOf
  reserveDispatch markerTicket >>= right
  withRaw root $ \db -> SQL.exec db "CREATE TRIGGER fail_attempt BEFORE UPDATE OF attempted_at ON commands BEGIN SELECT RAISE(ABORT,'fixture attempted marker failure'); END"
  expect "attempt marker failure invokes no callback" StorageUnavailable (attemptDispatch markerTicket (modifyIORef' calls (+1)))
  readIORef calls >>= check "callback count unchanged after failed attempted marker" . (== 1)
  withRaw root $ \db -> SQL.exec db "DROP TRIGGER fail_attempt"
  expect "failed attempted marker never restores dispatch permission" OwnershipUnavailable (attemptDispatch markerTicket (modifyIORef' calls (+1)))
  mutate store (execute "UPDATE credentials SET revoked=1 WHERE id='credential_a'" [])
  expect "revoked credential cannot read accepted work" Unauthenticated (readCommand store proof (dispatchCommandId failedTicket))
  void (recordEffect failedTicket effect >>= right)
  check "revocation does not reinterpret already accepted ownership" True

restartDispatchChecks :: FilePath -> IO ()
restartDispatchChecks work = do
  (path, _) <- fixture work "restart-dispatch" (64 * commandCapacity) 20
  (req, receipt, oldTicket) <- withInstalled path $ \installed -> withCoordinationStore installed $ \store -> do
    mutate store seed
    profile <- profileRevision installed
    proof <- authenticateCredential store bearerA >>= right
    req <- request store Cancel "lost-reply"
    accepted <- submitCommand store proof req (control profile) >>= right
    ticket <- ticketOf accepted
    reserveDispatch ticket >>= right
    pure (req, submissionReceipt accepted, ticket)
  withInstalled path $ \installed -> withCoordinationStore installed $ \store -> do
    profile <- profileRevision installed
    proof <- authenticateCredential store bearerA >>= right
    replay <- submitCommand store proof req (control profile) >>= right
    check "lost dispatch receipt after restart grants no replacement ticket"
      (submissionReplayed replay && submissionReceipt replay == receipt && isNothing (submissionTicket replay))
    calls <- newIORef (0 :: Int)
    expect "old live ticket cannot cross closed store lifetime" StorageUnavailable (attemptDispatch oldTicket (modifyIORef' calls (+1)))
    readIORef calls >>= check "restart never reissues uncertain dispatch" . (== 0)

capacityChecks :: FilePath -> IO ()
capacityChecks work = withFixture work "capacity" (17 * commandCapacity) 100 $ \_ _ _ store profile proof -> do
  ordinary <- request store SetInput "ordinary"
  void (submitCommand store proof ordinary (edit profile (commandResource ordinary) "r1") >>= right)
  expect "ordinary saturation cannot consume cancellation reserve" StorageQuota $
    submitCommand store proof (ordinary {commandKey = commandKey ordinary <> "other",commandPrecondition=Just "\"r1\""}) (edit profile (commandResource ordinary) "r2")
  void (submitCommand store proof ordinary (edit profile (commandResource ordinary) "never") >>= right)
  forM_ [1..16 :: Int] $ \n -> do
    req <- request store Cancel (T.pack (show n))
    void (submitCommand store proof req (control profile) >>= right)
  req <- request store Cancel "exhausted"
  expect "finite cancellation reserve also refuses exhaustion" StorageQuota (submitCommand store proof req (control profile))
  scalarInt store "SELECT bytes FROM command_ledger_usage" >>= check "logical reservation accounting reaches configured limit exactly" . (== 17 * commandCapacity)
  scalarInt store "SELECT count(*) FROM commands" >>= check "saturation never evicts replay protection" . (== 17)

rateChecks :: FilePath -> IO ()
rateChecks work = withFixture work "rates" (100 * commandCapacity) 2 $ \_ _ _ store profile proof -> do
  other <- authenticateCredential store bearerB >>= right
  mutate store (execute "INSERT INTO command_ordinary_rate VALUES ('credential_a',CAST(unixepoch('now')/60 AS INTEGER)+2,0)" [])
  forM_ [1..30 :: Int] $ \n -> do
    req <- request store SetInput (T.pack (show n))
    let revision = "r" <> T.pack (show (n-1))
    void (submitCommand store proof (req {commandPrecondition=Just ("\""<>revision<>"\"")}) (edit profile (commandResource req) ("r"<>T.pack(show n))) >>= right)
  saturated <- request store SetInput "31"
  expect "ordinary per-credential rate is bounded" RateLimit $
    submitCommand store proof (saturated {commandPrecondition=Just "\"r30\""}) (edit profile (commandResource saturated) "r31")
  void (submitCommand store other (saturated {commandPrecondition=Just "\"r30\""}) (edit profile (commandResource saturated) "r31") >>= right)
  check "ordinary rate counters are independent per credential" True
  forM_ [(proof,"safety_a"),(other,"safety_b")] $ \(credential,nonce) -> request store Cancel nonce >>= \req -> void (submitCommand store credential req (control profile) >>= right)
  req <- request store Cancel "safety_c"
  expect "two credentials share one global safety rate" RateLimit (submitCommand store other req (control profile))
  retry <- request store Cancel "safety_a"
  void (submitCommand store proof retry (control profile) >>= right)
  mutate store (execute "UPDATE command_ordinary_rate SET minute=CAST(unixepoch('now')/60 AS INTEGER)+100,count=30 WHERE credential_id='credential_b'" [])
  later <- request store SetInput "clock_backwards"
  expect "clock rollback cannot replenish ordinary permits" RateLimit $
    submitCommand store other (later {commandPrecondition=Just "\"r31\""}) (edit profile (commandResource later) "never")

rollbackChecks :: FilePath -> IO ()
rollbackChecks work = withFixture work "rollback" (64 * commandCapacity) 20 $ \path root installed store profile proof -> do
  withRaw root $ \db -> SQL.exec db "CREATE TRIGGER fail_command_event BEFORE INSERT ON invalidations WHEN NEW.kind='command.changed' BEGIN SELECT RAISE(ABORT,'fixture event failure'); END"
  req <- request store SetInput "rollback"
  expect "genuine SQL event failure returns no receipt" StorageUnavailable (submitCommand store proof req (edit profile (commandResource req) "r1"))
  scalarInt store "SELECT bytes FROM command_ledger_usage" >>= check "failed acceptance rolls back ledger charge" . (== 0)
  scalarInt store "SELECT count(*) FROM command_ordinary_rate" >>= check "failed acceptance rolls back rate charge" . (== 0)
  scalarText store "SELECT revision FROM requests" >>= check "failed acceptance rolls back resource revision" . (== "r0")
  scalarInt store "SELECT count(*) FROM commands" >>= check "failed acceptance leaves no intent" . (== 0)
  withRaw root $ \db -> SQL.exec db "DROP TRIGGER fail_command_event"
  let expiryAfterWrite = (edit profile (commandResource req) "r1") {mutationValidate = do
        validated <- mutationValidate (edit profile (commandResource req) "r1")
        pure $ fmap (\intent -> intent {intentApply = do
          result <- intentApply intent
          execute "UPDATE credentials SET expires_at='2000-01-01T00:00:00Z' WHERE id='credential_a'" []
          pure result}) validated}
  expect "post-write expiry recheck returns precise authentication refusal" Unauthenticated (submitCommand store proof req expiryAfterWrite)
  scalarText store "SELECT revision FROM requests" >>= check "post-write refusal rolls back resource state" . (== "r0")
  scalarInt store "SELECT count(*) FROM commands" >>= check "post-write refusal rolls back command state" . (== 0)
  scalarInt store "SELECT bytes FROM command_ledger_usage" >>= check "post-write refusal rolls back ledger state" . (== 0)
  scalarInt store "SELECT count(*) FROM command_ordinary_rate" >>= check "post-write refusal rolls back rate state" . (== 0)
  void (authenticateCredential store bearerA >>= right)
  let expensive = (edit profile (commandResource req) "r1") {mutationValidate = do
        _ <- query "WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<1000000000000) SELECT sum(x) FROM n" []
        mutationValidate (edit profile (commandResource req) "r1")}
  pending <- async (submitCommand store proof req expensive)
  threadDelay 100000
  configuration <- load path
  reload <- async (reloadConfiguration installed configuration)
  threadDelay 100000
  poll reload >>= check "configuration reload cannot interleave with acceptance" . isNothing
  expect "concurrent admission refuses without a waiting queue" StorageUnavailable (submitCommand store proof req (edit profile (commandResource req) "r1"))
  cancel pending
  outcome <- waitCatch pending
  check "command cancellation preserves AsyncCancelled" (case outcome of
    Left failure -> case fromException failure of Just AsyncCancelled -> True; Nothing -> False
    Right _ -> False)
  void (wait reload >>= right)
  scalarInt store "SELECT count(*) FROM commands" >>= check "cancelled validator records no receipt" . (== 0)

migrationChecks :: FilePath -> IO ()
migrationChecks work = do
  (path, root) <- fixture work "migration" commandCapacity 20
  withInstalled path (const (pure ()))
  let receipt = CommandReceipt "legacy_command" "profile_1" SetInput "/v1/requests/request_1" Accepted "2000-01-01T00:00:00Z" Nothing Nothing Nothing Nothing
      key = "authority_legacy." <> T.replicate 22 "n" <> "legacy"
      body = "{\"operation\":\"set-input\"}"
  withRaw root $ \db -> do
    mapM_ (SQL.exec db) schemaStatements
    SQL.exec db "PRAGMA user_version=1; INSERT INTO service_metadata VALUES (1,'authority_legacy','stream_legacy','0','0','service_1'); INSERT INTO clients VALUES ('client_1','r','a',0)"
    rawInsert db "INSERT INTO credentials VALUES ('credential_a','client_1',?,'2999-01-01T00:00:00Z',0)" [SQL.SQLBlob (verifier bearerA)]
    SQL.exec db "INSERT INTO credential_scopes VALUES ('credential_a','profile_1','submit'),('credential_a','profile_1','observe')"
    rawInsert db "INSERT INTO commands (id,revision,profile_id,operation,client_id,authority_epoch,method,resource_uri,idempotency_key,body,media_type,precondition,receipt,retired,accepted_at,state) VALUES ('legacy_command','r','profile_1','set-input','client_1','authority_legacy','POST','/v1/requests/request_1',?,?,'application/json','\"r0\"',?,0,'2000-01-01T00:00:00Z','accepted')"
      [SQL.SQLText key,SQL.SQLBlob body,SQL.SQLBlob(encoded receipt)]
    SQL.exec db "INSERT INTO requests (id,revision,client_id,workflow_id,descriptor_revision,profile_id,profile_revision,phase,admission,blocking_reasons,validation_errors) VALUES ('request_1','r0','client_1','workflow_1','descriptor_1','profile_1','profile_revision','draft','not-queued',X'5b5d',X'5b5d')"
    SQL.exec db "CREATE TABLE command_ledger_usage (sentinel TEXT)"
  withInstalled path $ \installed -> do
    failed <- try @StoreFailure (withCoordinationStore installed (const (pure ())))
    check "v1 to v2 partial migration refuses atomically" (case failed of Left StoreUnavailable -> True; _ -> False)
  withRaw root $ \db -> do
    values <- rawRows db "PRAGMA user_version"
    check "failed migration preserves version one" (values == [[SQL.SQLInteger 1]])
    columns <- rawRows db "SELECT name FROM pragma_table_info('commands') WHERE name='body_sha256'"
    check "failed migration rolls back added columns" (null columns)
    SQL.exec db "DROP TABLE command_ledger_usage"
  withInstalled path $ \installed -> withCoordinationStore installed $ \store -> do
    proof <- authenticateCredential store bearerA >>= right
    profile <- profileRevision installed
    let req = CommandRequest SetInput "profile_1" "POST" "/v1/requests/request_1" key "application/json" (Just "\"r0\"") body
    retried <- submitCommand store proof req (edit profile (commandResource req) "never") >>= right
    check "migration preserves legacy exact body and original receipt" (submissionReceipt retried == receipt && submissionReplayed retried)
    scalarInt store "SELECT bytes FROM command_ledger_usage" >>= check "migration charges legacy raw-body bytes in addition to reserved capacity" . (== commandCapacity + fromIntegral (BS.length body))
    rowsEqual store "SELECT body FROM commands" [[SQL.SQLBlob body]] >>= check "migration does not rewrite legacy private body"
    expect "over-budget migrated records are preserved while new admission refuses" StorageQuota $
      submitCommand store proof (req {commandKey=commandKey req<>"new"}) (edit profile (commandResource req) "never")

legacyCaptureChecks :: FilePath -> IO ()
legacyCaptureChecks work = withFixture work "legacy-capture" (64 * commandCapacity) 20 $ \_ _ _ store profile proof -> do
  epoch <- storeAuthorityEpoch <$> storeIdentity store
  base <- request store Capture "legacy-capture"
  let req = base {commandResource = "/v1/captures?requestId=request_1", commandMediaType = "application/octet-stream",
        commandPrecondition = Nothing, commandBody = "captured\r\n"}
      receipt = CommandReceipt "legacy_capture" "profile_1" Capture (commandResource req) Accepted "2000-01-01T00:00:00Z" Nothing Nothing Nothing Nothing
      mutation = edit profile (commandResource req) "never"
  mutate store $ execute
    "INSERT INTO commands (id,revision,profile_id,operation,client_id,authority_epoch,method,resource_uri,idempotency_key,body,media_type,receipt,retired,accepted_at,state) VALUES ('legacy_capture','r','profile_1','capture','client_1',?,'POST',?,?,?,'application/octet-stream',?,0,'2000-01-01T00:00:00Z','accepted')"
    [SQL.SQLText epoch, SQL.SQLText (commandResource req), SQL.SQLText (commandKey req), SQL.SQLBlob (commandBody req), SQL.SQLBlob (encoded receipt)]
  replay <- submitCommand store proof req mutation >>= right
  check "legacy capture exact body returns original receipt without a ticket"
    (submissionReplayed replay && submissionReceipt replay == receipt && isNothing (submissionTicket replay))
  sequenceBefore <- scalarText store "SELECT sequence FROM service_metadata"
  expect "oversized differing legacy capture is a binding conflict, not storage failure" IdempotencyConflict $
    submitCommand store proof (req {commandBody = BS.replicate 2097153 97}) mutation
  scalarText store "SELECT sequence FROM service_metadata" >>= check "legacy capture conflict changes no sequence" . (== sequenceBefore)
  rowsEqual store "SELECT body,receipt FROM commands WHERE id='legacy_capture'"
    [[SQL.SQLBlob (commandBody req), SQL.SQLBlob (encoded receipt)]] >>= check "legacy capture conflict preserves original bytes"

-- Exercise the accepted native row ceiling, not merely a large individual parameter.
largestLegacyChecks :: FilePath -> IO ()
largestLegacyChecks work = do
  (path, root) <- fixture work "largest-legacy" (64 * commandCapacity) 20
  withInstalled path (const (pure ()))
  let receipt = CommandReceipt "legacy_largest" "profile_1" Withdraw "/v1/requests/request_1" Accepted "2000-01-01T00:00:00Z" Nothing Nothing Nothing Nothing
      key = "authority_legacy." <> T.replicate 22 "n" <> "largest"
      prefix = "{\"operation\":\"withdraw\"}"
      bodyAt size = prefix <> BS.replicate (size - BS.length prefix) 32
      insert db body = rawInsert db
        "INSERT INTO commands (id,revision,profile_id,operation,client_id,authority_epoch,method,resource_uri,idempotency_key,body,media_type,precondition,receipt,retired,request_id,accepted_at,state) VALUES ('legacy_largest','r','profile_1','withdraw','client_1','authority_legacy','POST','/v1/requests/request_1',?,?,'application/json','\"r0\"',?,0,'request_1','2000-01-01T00:00:00Z','accepted')"
        [SQL.SQLText key, SQL.SQLBlob body, SQL.SQLBlob (encoded receipt)]
  maximumBytes <- withRaw root $ \db@(Direct.Database native) -> do
    existingSqliteLimits native
    mapM_ (SQL.exec db) schemaStatements
    SQL.exec db "PRAGMA foreign_keys=ON; PRAGMA user_version=1; INSERT INTO service_metadata VALUES (1,'authority_legacy','stream_legacy','0','0','service_1'); INSERT INTO clients VALUES ('client_1','r','a',0)"
    rawInsert db "INSERT INTO credentials VALUES ('credential_a','client_1',?,'2999-01-01T00:00:00Z',0)" [SQL.SQLBlob (verifier bearerA)]
    SQL.exec db "INSERT INTO credential_scopes VALUES ('credential_a','profile_1','submit'),('credential_a','profile_1','observe')"
    SQL.exec db "INSERT INTO requests (id,revision,client_id,workflow_id,descriptor_revision,profile_id,profile_revision,phase,admission,blocking_reasons,validation_errors) VALUES ('request_1','r1','client_1','workflow_1','descriptor_1','profile_1','profile_revision','withdrawn','released',X'5b5d',X'5b5d')"
    let fits size = do
          SQL.exec db "SAVEPOINT row_boundary"
          result <- try @SQL.SQLError (insert db (bodyAt size))
          SQL.exec db "ROLLBACK TO row_boundary; RELEASE row_boundary"
          case result of
            Right () -> pure True
            Left failure | SQL.sqlError failure == SQL.ErrorTooBig -> pure False
            Left failure -> throwIO failure
        search low high
          | high - low <= 1 = pure low
          | otherwise = do
              let middle = low + (high - low) `div` 2
              accepted <- fits middle
              if accepted then search middle high else search low middle
    fits (BS.length prefix) >>= check "native legacy boundary has a valid lower control"
    fits 2097152 >>= check "native row overhead excludes a full-limit legacy body" . not
    maximumSize <- search (BS.length prefix) 2097152
    fits maximumSize >>= check "largest version-one row fits native LIMIT_LENGTH"
    fits (maximumSize + 1) >>= check "one additional legacy body byte gets SQLITE_TOOBIG" . not
    check "largest legacy body exceeds the manager result budget" (maximumSize > 1048576)
    insert db (bodyAt maximumSize)
    SQL.exec db "CREATE TABLE command_ledger_usage (sentinel TEXT)"
    pure maximumSize
  putStrLn ("Largest version-one legacy body bytes: " <> show maximumBytes)
  let body = bodyAt maximumBytes
      req = CommandRequest Withdraw "profile_1" "POST" "/v1/requests/request_1" key "application/json" (Just "\"r0\"") body
  withInstalled path $ \installed -> do
    failed <- try @StoreFailure (withCoordinationStore installed (const (pure ())))
    check "largest legacy partial migration refuses atomically" (case failed of Left StoreUnavailable -> True; _ -> False)
  withRaw root $ \db@(Direct.Database native) -> do
    existingSqliteLimits native
    rawRows db "PRAGMA user_version" >>= check "largest legacy migration failure preserves version one" . (== [[SQL.SQLInteger 1]])
    rawRows db "SELECT name FROM pragma_table_info('commands') WHERE name='body_sha256'" >>= check "largest legacy migration failure rolls back added columns" . null
    bracket (SQL.prepare db "SELECT body=?,receipt=? FROM commands WHERE id='legacy_largest'") SQL.finalize $ \statement -> do
      SQL.bind statement [SQL.SQLBlob body, SQL.SQLBlob (encoded receipt)]
      _ <- SQL.step statement
      SQL.columns statement >>= check "failed migration preserves exact largest body and original receipt" . (== [SQL.SQLInteger 1,SQL.SQLInteger 1])
    SQL.exec db "DROP TABLE command_ledger_usage"
  withInstalled path $ \installed -> withCoordinationStore installed $ \store -> do
    profile <- profileRevision installed
    proof <- authenticateCredential store bearerA >>= right
    storeIdentity store >>= check "largest legacy row completes current migration" . ((== schemaVersion) . storeSchemaVersion)
    largeRead <- try @StoreFailure (runRead store (query "SELECT body FROM commands WHERE id='legacy_largest'" [] >> pure ()))
    check "largest body cannot be copied through the one-MiB result budget" (case largeRead of Left StoreLimit -> True; _ -> False)
    replay <- submitCommand store proof req (edit profile (commandResource req) "never") >>= right
    check "largest legacy exact retry compares in SQL and returns original receipt"
      (submissionReplayed replay && submissionReceipt replay == receipt)
    check "legacy replay refuses to mint dispatch or observation authority" (isNothing (submissionTicket replay))
    let changedBody = BS.take (maximumBytes - 1) body <> "\t"
    expect "largest legacy whitespace change remains a binding conflict" IdempotencyConflict $
      submitCommand store proof (req {commandBody=changedBody}) (edit profile (commandResource req) "never")
    readCommand store proof "legacy_largest" >>= right >>= check "largest legacy original facts remain readable without observation updates" . (== receipt)
    rowsEqual store "SELECT receipt,acknowledgement,effect_evidence,attempted_at,dispatch_generation FROM commands WHERE id='legacy_largest'"
      [[SQL.SQLBlob (encoded receipt),SQL.SQLNull,SQL.SQLNull,SQL.SQLNull,SQL.SQLNull]] >>=
        check "replay preserves original receipt bytes and adds no progress facts"
    scalarInt store "SELECT bytes FROM command_ledger_usage" >>= check "largest legacy raw bytes remain fully charged" . (== commandCapacity + fromIntegral maximumBytes)
    scalarText store "SELECT sequence FROM service_metadata" >>= check "largest legacy retries emit no invalidation" . (== "0")
    let inactive uri = do
          rows <- query "SELECT phase FROM requests WHERE id='request_1'" []
          pure $ if uri == commandResource req && rows == [[SQL.SQLText "withdrawn"]] then Just "2000-01-01T00:00:00Z" else Nothing
    retireReceipt store "legacy_largest" inactive >>= right
    expect "largest legacy retirement retains permanent replay refusal" ReceiptExpired $
      submitCommand store proof req (edit profile (commandResource req) "never")
    rowsEqual store "SELECT body,body_sha256,body_bytes,receipt,retired FROM commands WHERE id='legacy_largest'"
      [[SQL.SQLNull,SQL.SQLNull,SQL.SQLNull,SQL.SQLNull,SQL.SQLInteger 1]] >>= check "permitted retirement shrinks the maximum native row without losing replay protection"
    scalarInt store "SELECT bytes FROM command_ledger_usage" >>= check "largest legacy retirement accounts for removed raw body and retained tombstone" . (== tombstoneCapacity)

foreign import ccall unsafe "agentic_manager_sqlite_limits"
  existingSqliteLimits :: Ptr a -> IO ()

codecChecks :: FilePath -> FilePath -> IO ()
codecChecks work source = do
  let primitive=object["type" .= ("integer"::Text)]
      constrained=object["type" .= ("integer"::Text),"minimum" .= (1::Int)]
      record field=object["type" .= ("object"::Text),"properties" .= object["value" .= field],"required" .= ["value"::Text],"additionalProperties" .= False]
  check "frozen editor subset preserves nested supported schema" (representableEditorSchema(record(object["type" .= ("array"::Text),"items" .= primitive])))
  check "frozen editor subset refuses whole nested unsupported constraint" (not(representableEditorSchema(record constrained)))
  check "frozen editor subset refuses unsupported alternatives" (not(representableEditorSchema(object["oneOf" .= [primitive,constrained]])))
  check "frozen editor subset enforces required-property agreement" (not(representableEditorSchema(object["type" .= ("object"::Text),"properties" .= object["value" .= primitive],"required" .= ([]::[Text]),"additionalProperties" .= False])))
  Manifest cases <- BS.readFile (source </> "test/fixtures/manager/v1/manifest.json") >>= right . eitherDecodeStrict'
  forM_ [entry | entry@(CorpusCase _ schema _) <- cases, schema == "CommandReceipt"] $ \(CorpusCase file _ valid) -> do
    bytes <- BS.readFile (source </> "test/fixtures/manager/v1" </> file)
    let result = eitherDecodeStrict' bytes :: Either String CommandReceipt
    check ("frozen receipt corpus " <> file) (either (const False) (const True) result == valid)
    case result of
      Right receipt -> check "valid corpus receipt round-trip" (decodeReceipt (encoded receipt) == Right receipt)
      Left _ -> pure ()
  let ident = T.replicate 128 "x"
      uri = "/v1/" <> T.replicate 8188 "x"
  ack <- decodeValue (object ["commandId" .= ident, "state" .= ("failed" :: Text), "message" .= T.replicate 4096 "\0", "command" .= ("choose-recovery" :: Text), "occurrenceId" .= ("18446744073709551615" :: Text), "attemptId" .= ("4294967295" :: Text)])
  effect <- decodeValue (object ["kind" .= ("recovery-chosen" :: Text), "resource" .= uri, "runtimeSequence" .= ("18446744073709551615" :: Text), "address" .= object ["occurrenceId" .= ("18446744073709551615" :: Text), "attemptId" .= ("4294967295" :: Text)]])
  let receipt = CommandReceipt ident ident Cancel uri EffectObserved "2000-01-01T00:00:00Z" (Just "2000-01-01T00:00:00Z") (Just ack) (Just effect) Nothing
  check "maximum escaped acknowledgement fits 32 KiB reservation" (BS.length(encoded ack) <= 32768)
  check "maximum bounded effect fits 16 KiB reservation" (BS.length(encoded effect) <= 16384)
  check "maximum escaped receipt fits 64 KiB reservation" (BS.length(encoded receipt) <= 65536 && decodeReceipt(encoded receipt)==Right receipt)
  BS.writeFile (work </> "worst-case-receipt.json") (encoded receipt)
  forM_ ["not-a-date", "2026-13-01T00:00:00Z", "2026-02-30T00:00:00Z", "2026-01-01T25:00:00Z", "2026-01-01T00:00:00", "2026-01-01T00:00:00+25:00", "2026-01-01T00:00:00.Z", "-001-01-01T00:00:00Z"] $ \bad ->
    check "invalid receipt date-time refuses" (either (const True) (const False) (decodeReceipt (encoded receipt {receiptAcceptedAt=bad})))
  check "RFC3339 offset and lowercase timestamp remain valid" (validTimestamp "2026-09-03t00:00:00+01:00" && validTimestamp "2026-09-03t00:00:00z")
  let duplicate = "{\"version\":1," <> BS.drop 1 (encoded receipt)
  check "receipt decoding rejects duplicate keys before object construction" (either (const True) (const False) (decodeReceipt duplicate))
  check "frozen error code and status spellings" (failureCode Forbidden == "insufficient-scope" && failureCode ResourceUnavailable == "unavailable-resource" && failureStatus SizeLimit == 413)

data CorpusCase = CorpusCase FilePath Text Bool
instance FromJSON CorpusCase where
  parseJSON = withObject "corpus case" $ \o -> CorpusCase <$> o .: "file" <*> o .: "schema" <*> o .: "valid"
newtype Manifest = Manifest [CorpusCase]
instance FromJSON Manifest where
  parseJSON = withObject "corpus manifest" $ \o -> Manifest <$> o .: "cases"

localEffectChecks :: FilePath -> IO ()
localEffectChecks work = withFixture work "local-effect" (64 * commandCapacity) 20 $ \_ _ _ store profile proof -> do
  req <- request store SetInput "local"
  effect <- decodeValue (object ["kind" .= ("input-changed" :: Text), "runtimeSequence" .= (Nothing :: Maybe Text),
    "address" .= (Nothing :: Maybe Value), "resource" .= commandResource req])
  let withEffect value = (edit profile (commandResource req) "r1") {mutationValidate = do
        checkedIntent <- mutationValidate (edit profile (commandResource req) "r1")
        pure $ fmap (\intent -> intent {intentApply = do
          (events, _) <- intentApply intent
          pure (events, Just value)}) checkedIntent}
  wrong <- decodeValue (object ["kind" .= ("input-changed" :: Text), "runtimeSequence" .= (Nothing :: Maybe Text),
    "address" .= (Nothing :: Maybe Value), "resource" .= ("/v1/requests/another" :: Text)])
  expect "mismatched local effect rolls back with precise refusal" StateConflict (submitCommand store proof req (withEffect wrong))
  scalarText store "SELECT revision FROM requests" >>= check "invalid local effect rolls back owning mutation" . (== "r0")
  first <- submitCommand store proof req (withEffect effect) >>= right
  check "committed local effect invents no dispatch authority or runtime acknowledgement"
    (receiptState (submissionReceipt first) == EffectObserved && isNothing (submissionTicket first)
      && isNothing (receiptAttemptedAt (submissionReceipt first)) && isNothing (receiptAcknowledgement (submissionReceipt first)))
  BS.writeFile (work </> "actual-local-effect.json") (encoded (submissionReceipt first))
  sequenceBefore <- scalarText store "SELECT sequence FROM service_metadata"
  replay <- submitCommand store proof req (withEffect effect) >>= right
  check "local effect retry preserves original first-commit facts" (submissionReplayed replay && submissionReceipt replay == submissionReceipt first)
  scalarText store "SELECT sequence FROM service_metadata" >>= check "local effect retry does not advance stream" . (== sequenceBefore)

bindingBounds :: FilePath -> IO ()
bindingBounds work = withFixture work "binding-bounds" (64 * commandCapacity) 20 $ \_ _ _ store profile proof -> do
  req <- request store SetInput "large"
  let prefix = "{\"operation\":\"set-input\",\"input\":{\"name\":\"input_1\",\"source\":\"literal\",\"value\":\""
      suffix = "\"}}"
      maximumBody = prefix <> BS.replicate (2097152 - BS.length prefix - BS.length suffix) 120 <> suffix
  accepted <- submitCommand store proof (req {commandBody=maximumBody}) (edit profile (commandResource req) "r1") >>= right
  check "full JSON byte ceiling binds without exceeding SQLite row ceiling" (receiptState (submissionReceipt accepted) == Accepted)
  rowsEqual store "SELECT body,length(body_sha256),body_bytes FROM commands"
    [[SQL.SQLNull, SQL.SQLInteger 32, SQL.SQLInteger 2097152]] >>= check "new binding stores digest and exact byte length, not reserialized body"
  expect "oversized JSON input refuses before hashing" SizeLimit $
    submitCommand store proof (req {commandBody=BS.replicate 2097153 32}) (edit profile (commandResource req) "never")
  let capture = req {commandOperation=Capture, commandResource="/v1/captures?requestId=request_1", commandKey=commandKey req <> "capture",
        commandMediaType="application/octet-stream", commandPrecondition=Nothing, commandBody=BS.empty}
      captureMutation = Mutation profile (pure Nothing) $ do
        rows <- query "SELECT phase FROM requests WHERE id='request_1'" []
        pure $ if rows == [[SQL.SQLText "draft"]] then Right (Intent (noReferences {referenceRequest=Just "request_1"}) False (pure ([],Nothing))) else Left StateConflict
  empty <- submitCommand store proof capture captureMutation >>= right
  check "empty capture bytes are a present exact binding" (receiptOperation (submissionReceipt empty) == Capture)
  large <- submitCommand store proof (capture {commandKey=commandKey capture <> "large",commandBody=BS.replicate 67108864 120}) captureMutation >>= right
  check "full capture ceiling uses bounded cryptographic binding" (receiptOperation (submissionReceipt large) == Capture)
  expect "capture creation requires the frozen requestId target" InvalidRequest $
    submitCommand store proof (capture {commandResource="/v1/captures"}) captureMutation
  mutate store (execute "UPDATE credentials SET expires_at='2000-01-01T00:00:00Z' WHERE id='credential_a'" [])
  expect "expiry fences an otherwise matching receipt" Unauthenticated $
    submitCommand store proof capture captureMutation

decodeValue :: FromJSON a => Value -> IO a
decodeValue = right . eitherDecodeStrict' . encoded
withRaw :: FilePath -> (SQL.Database -> IO a) -> IO a
withRaw root action = do
  let path = root </> "coordination.sqlite3"
  bracket (SQL.open2 (T.pack path) [SQL.SQLOpenReadWrite, SQL.SQLOpenCreate, SQL.SQLOpenFullMutex, SQL.SQLOpenNoFollow] SQL.SQLVFSDefault)
    SQL.close $ \db -> setFileMode path 0o600 >> action db
rawInsert :: SQL.Database -> Text -> [SQL.SQLData] -> IO ()
rawInsert db statement values = bracket (SQL.prepare db statement) SQL.finalize $ \prepared -> SQL.bind prepared values >> void (SQL.step prepared)
rawRows :: SQL.Database -> Text -> IO [[SQL.SQLData]]
rawRows db statement = bracket (SQL.prepare db statement) SQL.finalize $ \prepared ->
  let loop n = SQL.step prepared >>= \result -> case result of
        SQL.Done -> pure []
        SQL.Row -> if n <= (0::Int) then error "fixture row bound" else (:) <$> SQL.columns prepared <*> loop (n-1)
  in loop 1000

retainedAttemptChecks :: FilePath -> IO ()
retainedAttemptChecks work=withFixture work "retained-attempt" (64*commandCapacity) 10 $ \_ _ _ store profile proof->do
  req<-request store SetInput "retained"
  attempt<-newCommandAttempt store proof req
  expect "unsubmitted context cannot reconcile rows or assert absence" OwnershipUnavailable (reconcileCommandAttempt attempt)
  accepted<-submitCommandAttempt attempt (\_ _ _->Right(edit profile(commandResource req)"retained_revision"))>>=right
  expect "retained invocation cannot be submitted twice" OwnershipUnavailable (submitCommandAttempt attempt (\_ _ _->Left StateConflict))
  before<-scalarText store "SELECT sequence FROM service_metadata"
  recovered<-reconcileCommandAttempt attempt>>=right>>=maybe(error "missing retained receipt")pure
  check "same completed invocation recovers original receipt without replacement ticket" (submissionReceipt recovered==submissionReceipt accepted && case submissionTicket recovered of Nothing->True;_->False)
  after<-scalarText store "SELECT sequence FROM service_metadata"
  check "known invocation reconciliation appends no event" (before==after)
  failedRequest<-request store SetInput "not-accepted"
  failed<-newCommandAttempt store proof failedRequest
  expect "failed retained candidate preserves exact stale revision refusal" StaleRevision (submitCommandAttempt failed(\_ _ _->Right(edit profile(commandResource failedRequest)"never")))
  absent<-reconcileCommandAttempt failed>>=right
  check "completed failed candidate proves absence without constructing authority" (case absent of Nothing->True;_->False)

commandDeadlineChecks :: FilePath -> IO ()
commandDeadlineChecks work=withFixture work "command-deadline" (64*commandCapacity) 10 $ \_ root _ store profile proof->do
  clock<-newIORef 0
  calls<-newIORef (0::Int)
  entered<-newEmptyMVar
  release<-newEmptyMVar
  let rendezvous action=timeout 2000000 action >>= maybe(error "final deadline rendezvous timed out")pure
      finalClock=do
        modifyIORef' calls (+1)
        putMVar entered()
        rendezvous(takeMVar release)
        readIORef clock
      atFinalRead action crossing = bracket (async action) cancel $ \pending->do
        rendezvous(takeMVar entered)
        active<-try @StoreFailure(storeIdentity store)
        check "deadline rendezvous occurs while actual acceptance transaction owns Store" (case active of Left StoreBusy->True;_->False)
        void crossing
        putMVar release()
        wait pending
  req<-request store SetInput "deadline"
  withCommitDeadline store finalClock 10 $ \guard->do
    attempt<-newCommandAttempt store proof req
    accepted<-atFinalRead (submitCommandAttemptWithDeadline guard attempt (\_ _ _->Right(edit profile(commandResource req)"deadline_revision"))) (pure()) >>=right
    writeIORef clock 10
    repeated<-newCommandAttempt store proof req
    replay<-submitCommandAttemptWithDeadline guard repeated (\_ _ _->Left StateConflict)>>=right
    check "exact command replay bypasses fresh acceptance deadline" (submissionReceipt replay==submissionReceipt accepted && submissionReplayed replay)
    readIORef calls >>=check "exact replay makes no final clock read" . (==1)
    -- A new guard begins unexpired. The coordinator advances only at its in-transaction read.
  writeIORef clock 11
  withCommitDeadline store finalClock 20 $ \guard->do
    newRequest<-request store SetInput "deadline_expired"
    let freshRequest=newRequest{commandPrecondition=Just "\"deadline_revision\""}
    freshAttempt<-newCommandAttempt store proof freshRequest
    beforeEvents<-scalarInt store "SELECT count(*) FROM invalidations"
    refused<-atFinalRead (submitCommandAttemptWithDeadline guard freshAttempt(\_ _ _->Right(edit profile(commandResource req)"must_rollback"))) $ do
      bracket (SQL.open(T.pack(root </> "coordination.sqlite3"))) SQL.close $ \database->do
        rawRows database "SELECT revision FROM requests WHERE id='request_1'" >>=check "active final check has not published source mutation" . (==[[SQL.SQLText "deadline_revision"]])
        rawRows database "SELECT count(*) FROM commands" >>=check "active final check has not published fresh receipt" . (==[[SQL.SQLInteger 1]])
      writeIORef clock 20
    check "deadline crossing inside fresh acceptance refuses commit" (case refused of Left StorageUnavailable->True;_->False)
    scalarText store "SELECT revision FROM requests WHERE id='request_1'" >>=check "expired fresh intent rolls back owning mutation" . (=="deadline_revision")
    scalarInt store "SELECT count(*) FROM commands" >>=check "expired fresh intent publishes no receipt" . (==1)
    scalarInt store "SELECT count(*) FROM invalidations" >>=check "expired fresh intent rolls back invalidations" . (==beforeEvents)
  escaped<-withCommitDeadline store (readIORef clock) 30 pure
  expiredScope<-try @StoreFailure $ mutate store $ do
    execute "UPDATE clients SET revision='escaped_deadline' WHERE id='client_1'" []
    enforceCommitDeadline escaped
  check "escaped deadline guard cannot authorize a later transaction" (case expiredScope of Left StoreDeadline->True;_->False)

adminField :: Text -> Value -> Value
adminField key (Object fields) = maybe Null id (KM.lookup (Key.fromText key) fields)
adminField _ _ = Null

adminText :: Value -> IO Text
adminText (String value) = pure value
adminText _ = error "admin metadata field missing"

adminValue :: BS.ByteString -> IO Value
adminValue = either (const (error "admin response is not JSON")) pure . eitherDecodeStrict'

adminOK :: CoordinationStore -> Admin.LocalAdminRequest -> IO Value
adminOK store requestValue = do
  value <- administerCredentials store requestValue >>= adminValue
  check "local credential operation confirmed" (adminField "ok" value == Bool True)
  pure (adminField "result" value)

adminRefused :: String -> Admin.AdminFailure -> CoordinationStore -> Admin.LocalAdminRequest -> IO ()
adminRefused label failure store requestValue = do
  value <- administerCredentials store requestValue >>= adminValue
  check label (adminField "ok" value == Bool False && adminField "code" (adminField "error" value) == String (Admin.adminFailureCode failure))

credentialParserChecks :: FilePath -> IO ()
credentialParserChecks source = do
  let frozen directory name = BS.readFile (source </> "test/fixtures/manager/v1" </> directory </> (name <> ".json"))
  forM_ ["status","reload-profiles","list-credentials","issue-credential","rotate-credential","revoke-credential","drain","shutdown","check-store","backup","restore","check-quarantine","release-quarantine"] $ \operation -> do
    bytes <- frozen "valid" ("admin-" <> operation)
    check "frozen local request accepted exactly" (case Admin.decodeLocalAdminRequest bytes of Right value -> Admin.adminOperation value == T.pack operation; _ -> False)
  forM_ [("admin-duplicate",Admin.DuplicateField),("admin-unknown-field",Admin.UnknownField),
         ("admin-unknown-operation",Admin.UnknownOperation),("admin-unsupported-version",Admin.UnsupportedVersion),
         ("admin-malformed-request",Admin.MalformedRequest),("admin-missing-operation",Admin.MalformedRequest),
         ("admin-issue-client-override",Admin.UnknownField),("admin-rotate-client-override",Admin.UnknownField),
         ("admin-relative-output",Admin.MalformedRequest)] $ \(name,expected) -> do
    bytes <- frozen "invalid" name
    check "frozen invalid local request refused before dispatch" (case Admin.decodeLocalAdminRequest bytes of Left actual -> actual == expected; _ -> False)
    output <- adminValue (Admin.adminError Nothing expected)
    check "pre-dispatch error neither guesses operation nor echoes input" (adminField "operation" output == Null && adminField "message" (adminField "error" output) == String "")
  forM_ ["{\"version\":1,\"operation\":\"list-credentials\"} {}",
         "{\"version\":1,\"operation\":\"list-credentials\",\"secret\":\"private\"}",
         "{\"version\":1,\"operation\":\"list-credentials\",\"operation\":\"private\"}"] $ \bytes ->
    check "strict local EOF and duplicate/unknown-field refusal" (case Admin.decodeLocalAdminRequest bytes of Left _ -> True; _ -> False)
  check "local input bound enforced before parsing" (case Admin.decodeLocalAdminRequest (BS.replicate 2097153 32) of Left Admin.SizeLimit -> True; _ -> False)
  oversized <- adminValue (Admin.adminSuccess "list-credentials" (String (T.replicate 1048576 "x")))
  check "whole oversized response refuses within newline-inclusive byte ceiling" (adminField "code" (adminField "error" oversized) == String "size-limit")

credentialAdministrationChecks :: FilePath -> IO ()
credentialAdministrationChecks work = withFixture work "credentials" (64*commandCapacity) 20 $ \_ _ _ store profile proof -> do
  let expiry = "2999-01-01T00:00:00Z"
      issue = Admin.IssueCredential "Terminal" [Observe,Submit,Control,ExportScope] ["profile_1"] expiry
      destination = work </> "one-time.credential"
  issued <- adminOK store (issue destination)
  let metadata = adminField "credential" issued
  ident <- adminText (adminField "credentialId" metadata)
  client <- adminText (adminField "clientId" metadata)
  bearer <- BS.readFile destination
  check "one-time bearer is exactly 64 lowercase hexadecimal bytes without newline"
    (BS.length bearer == 64 && BS.all (`elem` BS.unpack "0123456789abcdef") bearer)
  status <- getSymbolicLinkStatus destination
  check "one-time file remains private" (fileMode status .&. 0o777 == 0o600)
  bytes <- administerCredentials store Admin.ListCredentials
  check "metadata does not disclose bearer, verifier or destination"
    (all (not . (`BS.isInfixOf` bytes)) [bearer,convertToBase Base16 (verifier bearer),TE.encodeUtf8 (T.pack destination)])
  stored <- runRead store $ do
    rows <- query "SELECT verifier FROM credentials WHERE id=?" [SQL.SQLText ident]
    pure (rows == [[SQL.SQLBlob (verifier bearer)]])
  check "only exact encoded-bearer verifier persisted" stored
  issuedProof <- authenticateCredential store bearer >>= right
  runRead store (currentClient issuedProof) >>= check "issue creates registered client" . (== Right client)
  adminRefused "exclusive publication collision" Admin.OutputConflict store (issue destination)
  BS.readFile destination >>= check "collision never replaces one-time bytes" . (== bearer)
  scalarInt store "SELECT count(*) FROM credentials" >>= check "collision never activates another credential" . (==4)
  adminRefused "other admin owner not falsely implemented" Admin.StateConflict store (Admin.OtherAdmin "status")
  req <- request store SetInput "credential-rotation"
  original <- withAuthorizedView store proof "profile_1" [Observe] (\view -> do
    submission <- submitCommand store proof req (edit profile (commandResource req) "rotated_revision") >>= right
    revalidateAuthorizedView view >>= check "ordinary request mutation preserves current authorization view" . (==Right ())
    pure submission) >>= right
  first <- adminOK store (Admin.RotateCredential "credential_a" expiry (work </> "rotation-1.credential"))
  firstId <- adminText (adminField "credentialId" (adminField "credential" first))
  firstBearer <- BS.readFile (work </> "rotation-1.credential")
  firstProof <- authenticateCredential store firstBearer >>= right
  runRead store (currentClient firstProof) >>= check "rotation retains registered client" . (==Right "client_1")
  replay <- submitCommand store firstProof req (edit profile (commandResource req) "never") >>= right
  check "rotation preserves client-keyed idempotency receipt" (submissionReceipt replay == submissionReceipt original && isNothing (submissionTicket replay))
  void (authenticateCredential store bearerA >>= right)
  scalarInt store "SELECT CAST((julianday(rotation_cutoff)-julianday('now'))*86400 AS INTEGER) FROM credential_administration WHERE credential_id='credential_a'"
    >>= check "rotation overlap is positive and at most sixty seconds" . (\seconds -> seconds > 0 && seconds <= 60)
  cutoff <- scalarText store "SELECT rotation_cutoff FROM credential_administration WHERE credential_id='credential_a'"
  adminRefused "superseded target cannot rotate again" Admin.StateConflict store (Admin.RotateCredential "credential_a" expiry (work </> "rotation-refused.credential"))
  doesFileExist (work </> "rotation-refused.credential") >>= check "invalid target refused before publication" . not
  second <- adminOK store (Admin.RotateCredential firstId expiry (work </> "rotation-2.credential"))
  secondId <- adminText (adminField "credentialId" (adminField "credential" second))
  scalarText store "SELECT rotation_cutoff FROM credential_administration WHERE credential_id='credential_a'" >>= check "repeated rotation never extends old cutoff" . (==cutoff)
  expect "older predecessor revoked atomically" Unauthenticated (authenticateCredential store bearerA)
  scalarInt store "SELECT count(*) FROM credentials WHERE client_id='client_1' AND revoked=0" >>= check "at most current and immediate predecessor remain active" . (==2)
  void $ withAuthorizedView store firstProof "profile_1" [Observe] (\view -> do
    void (adminOK store (Admin.RevokeCredential firstId))
    timeout 1000000 (awaitAuthorizedView view) >>= check "confirmed revocation wakes bound view" . (==Just (Left Unauthenticated))) >>= right
  secondBearer <- BS.readFile (work </> "rotation-2.credential")
  secondProof <- authenticateCredential store secondBearer >>= right
  withStoreWorker store $ \_ _ running -> do
    void (adminOK store (Admin.RevokeCredential secondId))
    atomically running >>= check "credential revocation does not cancel original worker ownership"
  expect "current authorization precedes retained receipt" Unauthenticated (readCommand store secondProof (receiptId (submissionReceipt original)))
  scalarText store "SELECT supervision FROM runs WHERE id='run_1'" >>= check "revocation leaves already-owned run facts intact" . (=="owned")
  expired <- scalarText store "SELECT strftime('%Y-%m-%dT%H:%M:%fZ','now','+3 seconds')"
  void (adminOK store (Admin.IssueCredential "short" [Observe] ["profile_1"] expired (work </> "short.credential")))
  shortBearer <- BS.readFile (work </> "short.credential")
  shortProof <- authenticateCredential store shortBearer >>= right
  void $ withAuthorizedView store shortProof "profile_1" [Observe] (\view -> do
    threadDelay 3100000
    timeout 2000000 (awaitAuthorizedView view) >>= check "expiry timer revalidates trusted SQLite time" . (==Just (Left Unauthenticated))) >>= right
  escaped <- withAuthorizedView store issuedProof "profile_1" [Observe] pure >>= right
  revalidateAuthorizedView escaped >>= check "view cannot escape reader scope" . (==Left Unauthenticated)
  withStoreAuthorizationWatch store $ \watch -> do
    pending <- async (adminOK store (Admin.RevokeCredential ident))
    void (wait pending)
    authorizationWatchCurrent watch >>= check "registration before concurrent invalidation cannot lose it" . not

foreign import ccall unsafe "draft_arm_sync_failure" armCredentialSyncFailure :: CInt -> IO ()
foreign import ccall unsafe "draft_sync_failure_fired" credentialSyncFailureFired :: IO CInt

credentialRepresentationChecks :: FilePath -> IO ()
credentialRepresentationChecks work = withFixture work "credential-representations" (64*commandCapacity) 20 $ \_ _ _ store _ _ -> do
  forM_ [("nul-label", "\0", "2999-01-01T00:00:00Z"),
         ("lower-expiry", "a\0b", "2999-01-01t00:00:00z"),
         ("unicode-label", "\0" <> T.replicate 255 "𐐀", "2999-01-01t00:00:00+00:00")] $ \(name,label,expiry) -> do
    let destination = work </> (name <> ".credential")
        requestValue = Admin.IssueCredential label [Observe] ["profile_1"] expiry destination
    check "frozen label and expiry grammar accepts representation" (Admin.validAdminRequest requestValue)
    issued <- adminOK store requestValue
    let metadata = adminField "credential" issued
    check "label preserves every Unicode scalar including NUL" (adminField "label" metadata == String label)
    check "issued expiry uses equivalent SQL-compatible spelling" (adminField "expiresAt" metadata == String (T.toUpper expiry))
    ident <- adminText (adminField "credentialId" metadata)
    client <- adminText (adminField "clientId" metadata)
    proof <- BS.readFile destination >>= authenticateCredential store >>= right
    runRead store (currentClient proof) >>= check "normalized issue remains authenticatable" . (==Right client)
    let rotatedDestination = work </> (name <> "-rotated.credential")
        rotatedExpiry = "2999-02-01t12:34:56.125z"
    rotated <- adminOK store (Admin.RotateCredential ident rotatedExpiry rotatedDestination)
    check "rotated expiry uses equivalent SQL-compatible spelling"
      (adminField "expiresAt" (adminField "credential" rotated) == String (T.toUpper rotatedExpiry))
    rotatedProof <- BS.readFile rotatedDestination >>= authenticateCredential store >>= right
    runRead store (currentClient rotatedProof) >>= check "normalized rotation remains authenticatable" . (==Right client)
    runRead store (currentClient proof) >>= check "normalized rotation preserves positive predecessor overlap" . (==Right client)
  let oversized = work </> "oversized-label.credential"
  adminRefused "NUL does not hide an overlong label" Admin.MalformedRequest store
    (Admin.IssueCredential (T.replicate 257 "\0") [Observe] ["profile_1"] "2999-01-01T00:00:00Z" oversized)
  doesFileExist oversized >>= check "invalid label refuses before private publication" . not

-- The existing source auditor pauses the original writer after real COMMIT and
-- before its notification, while the observation retains facts read before it.
credentialCommitGapChecks :: FilePath -> IO ()
credentialCommitGapChecks work = withFixture work "credential-commit-gap" (64*commandCapacity) 20 $ \_ _ _ store _ proof ->
  withStoreAuthorizationWatch store $ \watch ->
    Audit.withReviewAudit "authorization-commit" $ \audit -> do
      entered <- newEmptyMVar
      calls <- newIORef (0 :: Int)
      bracket (async (takeMVar entered >> adminOK store (Admin.RevokeCredential "credential_a")))
        (\writer -> Audit.releaseReviewed audit >> cancel writer >> void (waitCatch writer)) $ \writer -> do
          observed <- try @StoreFailure $ withAuthorizationObservation watch $ do
            modifyIORef' calls (+1)
            facts <- runRead store (currentClient proof)
            check "observation reads authority before concurrent revocation" (facts == Right "client_1")
            putMVar entered ()
            void (Audit.waitReviewed audit)
            pure facts
          Audit.releaseReviewed audit
          void (wait writer)
          check "authorization acknowledgement refuses committed but unnotified state"
            (case observed of Left StoreBusy -> True; _ -> False)
          readIORef calls >>= check "commit-gap observation is never replayed" . (==1)
          authorizationWatchCurrent watch >>= check "committed revocation notification is not consumed" . not
          runRead store (currentClient proof) >>= check "original revocation completed before owner join" . (==Left Unauthenticated)

credentialFailureChecks :: FilePath -> IO ()
credentialFailureChecks work = do
  withFixture work "credential-observation" (64*commandCapacity) 20 $ \_ _ _ store _ _ ->
    withStoreAuthorizationWatch store $ \watch -> do
      mutate store (execute "UPDATE clients SET revision='unrelated_view_change' WHERE id='client_1'" [])
      authorizationWatchCurrent watch >>= check "committed change wakes the original watch" . not
      withAuthorizationObservation watch (pure ()) >>= check "stable observation acknowledges coalesced notification" . (==Just ())
      authorizationWatchCurrent watch >>= check "acknowledged watch is current again"
      entered <- newEmptyMVar
      calls <- newIORef (0 :: Int)
      bracket (async (takeMVar entered >> mutate store (execute "UPDATE clients SET revision='racing_view_change' WHERE id='client_1'" [])))
        (\writer -> cancel writer >> void (waitCatch writer)) $ \writer -> do
          outcome <- try @StoreFailure $ withAuthorizationObservation watch $ do
            modifyIORef' calls (+1)
            putMVar entered ()
            wait writer
          check "concurrent commit refuses the observation" (outcome == Left StoreBusy)
          readIORef calls >>= check "authorization observation is never replayed" . (==1)
          authorizationWatchCurrent watch >>= check "failed observation does not consume invalidation" . not
  withFixture work "credential-cutoff" (64*commandCapacity) 20 $ \_ _ _ store _ proof -> do
    void (adminOK store (Admin.RotateCredential "credential_a" "2999-01-01T00:00:00Z" (work </> "cutoff.credential")))
    mutate store (execute "UPDATE credential_administration SET rotation_cutoff='2000-01-01T00:00:00Z' WHERE credential_id='credential_a'" [])
    expect "effective rotation cutoff rejects fresh possession" Unauthenticated (authenticateCredential store bearerA)
    runRead store (currentClient proof) >>= check "effective cutoff rejects retained proof" . (==Left Unauthenticated)
    scalarText store "SELECT expires_at FROM credentials WHERE id='credential_a'" >>= check "rotation never rewrites declared expiry" . (=="2999-01-01T00:00:00Z")
    listing <- adminOK store Admin.ListCredentials
    check "metadata reflects effective revocation" (case adminField "credentials" listing of
      Array values -> any (\value -> adminField "credentialId" value == String "credential_a" && adminField "state" value == String "revoked") values
      _ -> False)
  forM_ [1,2] $ \nth -> withFixture work ("credential-sync-"<>show nth) (64*commandCapacity) 20 $ \_ _ _ store _ _ -> do
    let destination = work </> ("sync-"<>show nth<>".credential")
    armCredentialSyncFailure nth
    adminRefused (if nth == 1 then "file sync failure refuses activation" else "unconfirmed parent sync refuses activation") Admin.StorageUnavailable store
      (Admin.IssueCredential "sync" [Observe] ["profile_1"] "2999-01-01T00:00:00Z" destination)
    credentialSyncFailureFired >>= check "selected file or parent synchronization failed" . (== if nth == 1 then -1 else 1)
    doesFileExist destination >>= check "only post-publication uncertainty retains the fresh private file" . (== (nth == 2))
    scalarInt store "SELECT count(*) FROM credentials" >>= check "failed synchronization made no activation attempt" . (==3)
  withFixture work "credential-sql-refusal" (64*commandCapacity) 20 $ \_ root _ store _ proof -> do
    withRaw root $ \db -> SQL.exec db "CREATE TRIGGER refuse_credential BEFORE INSERT ON credentials BEGIN SELECT RAISE(ABORT,'fixture refusal'); END"
    withStoreAuthorizationWatch store $ \watch -> do
      adminRefused "definite SQL rollback leaves inert file" Admin.StorageUnavailable store
        (Admin.IssueCredential "rollback" [Observe] ["profile_1"] "2999-01-01T00:00:00Z" (work </> "inert.credential"))
      authorizationWatchCurrent watch >>= check "constraint rollback does not invalidate readers"
    inert <- BS.readFile (work </> "inert.credential")
    expect "confirmed file with SQL refusal is inert" Unauthenticated (authenticateCredential store inert)
    void (runRead store (currentClient proof) >>= right)
  withFixture work "credential-commit-uncertain" (64*commandCapacity) 20 $ \_ root _ store _ _ -> do
    withRaw root $ \db -> SQL.exec db "CREATE TABLE credential_commit_fault(client_id TEXT REFERENCES clients(id) DEFERRABLE INITIALLY DEFERRED); CREATE TRIGGER fail_credential_commit AFTER INSERT ON credentials BEGIN INSERT INTO credential_commit_fault VALUES ('missing_client'); END"
    withStoreAuthorizationWatch store $ \watch -> do
      adminRefused "COMMIT failure stays uncertain" Admin.StorageUnavailable store
        (Admin.IssueCredential "commit" [Observe] ["profile_1"] "2999-01-01T00:00:00Z" (work </> "uncertain.credential"))
      authorizationWatchCurrent watch >>= check "Store poison invalidates authorization observers" . not
      failed <- try @StoreFailure (storeIdentity store)
      check "uncertain COMMIT poisons original Store" (case failed of Left StorePoisoned -> True; _ -> False)
    doesFileExist (work </> "uncertain.credential") >>= check "COMMIT uncertainty preserves published secret"
  (path,_) <- fixture work "credential-close" (64*commandCapacity) 20
  registered <- newEmptyMVar
  released <- newEmptyMVar
  observer <- withInstalled path $ \installed -> withCoordinationStore installed $ \store -> do
    pending <- async $ withStoreAuthorizationWatch store $ \watch -> do
      putMVar registered ()
      takeMVar released
      authorizationWatchCurrent watch
    takeMVar registered
    pure pending
  putMVar released ()
  timeout 1000000 (wait observer) >>= check "Store close invalidates still-registered observer without joining it" . (==Just False)

credentialMigrationChecks :: FilePath -> IO ()
credentialMigrationChecks work = do
  (path,root) <- fixture work "credential-migration" (64*commandCapacity) 20
  withInstalled path $ \installed -> withCoordinationStore installed $ \store -> mutate store seed
  withRaw root $ \db -> SQL.exec db "DROP TABLE credential_profiles; DROP TABLE credential_administration; PRAGMA user_version=11"
  withInstalled path $ \installed -> withCoordinationStore installed $ \store -> do
    proof <- authenticateCredential store bearerA >>= right
    runRead store (currentClient proof) >>= check "legacy verifier and client survive migration" . (==Right "client_1")
    scalarText store "SELECT label FROM credential_administration WHERE credential_id='credential_a'" >>= check "legacy label is retained credential identity" . (=="credential_a")
    scalarText store "SELECT expires_at FROM credentials WHERE id='credential_a'" >>= check "migration keeps declared expiry" . (=="2999-01-01T00:00:00Z")
    scalarInt store "SELECT count(*) FROM credential_scopes" >>= check "migration preserves old scopes" . (==12)
  withRaw root $ \db -> SQL.exec db "PRAGMA user_version=999"
  withInstalled path $ \installed -> do
    failure <- try @StoreFailure (withCoordinationStore installed (const (pure ())))
    check "unknown credential schema refused" (failure == Left StoreVersion)
  withRaw root $ \db -> do
    rawRows db "PRAGMA user_version" >>= check "invalid-version refusal does not mutate database version" . (==[[SQL.SQLInteger 999]])
    rawRows db "SELECT count(*) FROM credentials" >>= check "invalid-version refusal keeps legacy records" . (==[[SQL.SQLInteger 3]])

credentialBoundsChecks :: FilePath -> IO ()
credentialBoundsChecks work = do
  (path,_) <- fixture work "credential-bounds" (64*commandCapacity) 20
  document <- BS.readFile path >>= right . eitherDecodeStrict'
  let names = ["profile_" <> T.justifyRight 3 '0' (T.pack (show index)) | index <- [1..256 :: Int]]
  case document of
    Object fields -> case KM.lookup "profiles" fields of
      Just (Array profiles) | [Object profile] <- toList profiles ->
        BS.writeFile path (encoded (Object (KM.insert "profiles" (toJSON [Object (KM.insert "id" (String name) profile) | name <- names]) fields)))
      _ -> error "profile fixture shape"
    _ -> error "configuration fixture shape"
  withInstalled path $ \installed -> withCoordinationStore installed $ \store -> do
    let destination = work </> "maximum.credential"
    result <- adminOK store (Admin.IssueCredential "maximum" [Observe,Submit,Control,ExportScope] names "2999-01-01T00:00:00Z" destination)
    scalarInt store "SELECT count(*) FROM credential_scopes" >>= check "all 256 profiles and four scopes fit original budgets" . (==1024)
    check "bounded metadata retains all profiles" (adminField "profileIds" (adminField "credential" result) == toJSON names)
    mutate store $ do
      execute "INSERT INTO clients WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<255) SELECT 'bound_client_'||x,'revision','authorization',0 FROM n" []
      execute "INSERT INTO credentials SELECT 'bound_credential_'||id,id,CAST(id AS BLOB),'2999-01-01T00:00:00Z',0 FROM clients WHERE id LIKE 'bound_client_%'" []
    values <- adminOK store Admin.ListCredentials
    check "list returns all 256 retained records" (case adminField "credentials" values of Array items -> length items == 256; _ -> False)
    case names of
      first:_ -> void (adminOK store (Admin.IssueCredential "beyond list" [] [first] "2999-01-01T00:00:00Z" (work </> "beyond-list.credential")))
      [] -> error "missing credential-bound profile"
    adminRefused "257 retained records refuse whole list without lifetime issuance cap" Admin.SizeLimit store Admin.ListCredentials
