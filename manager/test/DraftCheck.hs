{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
module Main (main) where

import Agentic.Manager.Authorization
import Agentic.Manager.Commands (measureCommandBody, bodyBindingBytes, bodyBindingSha256)
import Agentic.Manager.Configuration
import Agentic.Manager.Drafts
import Agentic.Manager.Profile hiding (StaleRevision)
import Agentic.Manager.Protocol.Command
import Agentic.Manager.Protocol.Draft
import Agentic.Manager.Schema (schemaVersion, schemaStatements, commandMigration)
import Agentic.Manager.Store
import Agentic.Runtime
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (AsyncCancelled (..), async, cancel, waitCatch, wait, poll)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.DeepSeq (NFData)
import Control.Exception (bracket, fromException, try)
import Control.Monad (forM_, unless, void)
import Crypto.Hash (Digest, SHA256, hash)
import Data.Aeson (FromJSON (parseJSON), eitherDecodeStrict', object, withObject, (.:), (.=))
import Data.Either (isRight)
import Data.ByteArray (convert)
import qualified Data.ByteString as BS
import Data.IORef (atomicModifyIORef', newIORef, modifyIORef', readIORef)
import Data.Int (Int64)
import Data.List (find)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Database.SQLite3 as SQL
import Foreign.C.Types (CInt (..))
import System.Directory (createDirectory, doesFileExist, listDirectory, removeFile)
import System.Environment (getArgs, getExecutablePath)
import System.Exit (exitFailure)
import System.FilePath ((</>))
import System.IO (BufferMode (LineBuffering), IOMode (ReadMode), withBinaryFile, hSetBuffering, stdout)
import System.Posix.Files (setFileMode)
import System.Timeout (timeout)

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  args<-getArgs
  case args of
    ["runner", replies, "frontend", "--capabilities"] -> do
      let server=FrontendServer "fixture" "/fixture/runner" "0.1.0.0"
      BS.putStr(encoded(frontendCapabilities server))
      void(pure replies)
    ["runner", replies, "list", "--json", "--descriptor-version", "3"] -> do
      bytes<-BS.readFile replies
      if bytes=="WAIT" then BS.writeFile (replies<>".ready") BS.empty >> threadDelay 60000000
        else if bytes=="FAIL" then exitFailure else BS.putStr bytes
    ["review-lifetime",work,source] -> reopenChecks work source >> sameConfigurationReopenChecks work source
    ["review-catalogue",work,source] -> cataloguePageChecks work source
    ["review-migration",work] -> declarationMigrationChecks work
    ["review-holding",work,source] -> holdingByteChecks work source
    ["review-utf8-eof",work,source] -> uploadChecks work source
    [work,source] -> do
      literalContract
      bindingContract
      corpusChecks source
      cataloguePageChecks work source
      draftChecks work source
      uploadChecks work source
      quotaChecks work source
      holdingByteChecks work source
      lifecycleChecks work source
      atomicOriginChecks work source
      reopenChecks work source
      sameConfigurationReopenChecks work source
      framingChecks work source
      lifetimeChecks work source
      escapedFileChecks work source
      migrationChecks work
      declarationMigrationChecks work
      putStrLn "PASS manager drafts, captures and readiness"
    _->error "usage: manager-draft-check PRIVATE_DIRECTORY PACKAGE_DIRECTORY"

check :: String -> Bool -> IO ()
check label condition=unless condition(error("FAIL "<>label))>>putStrLn("PASS "<>label)
right :: Show e => Either e a -> IO a
right=either(error.show)pure
expect :: String -> CommandFailure -> IO (Either CommandFailure a) -> IO ()
expect label expected action=action>>= \result->check label(case result of Left actual->actual==expected;Right _->False)
await :: IO a -> IO a
await action=timeout 5000000 action >>= maybe(error "fixture rendezvous timeout")pure

bearer, secondBearer :: BS.ByteString
bearer=BS.replicate 32 97
secondBearer=BS.replicate 32 98

data Fixture = Fixture FilePath FilePath FilePath Configuration InstalledConfiguration CoordinationStore CredentialProof Text Discovery
withFixture :: FilePath -> FilePath -> String -> Int -> Int -> Int64 -> (Fixture -> IO a) -> IO a
withFixture work source name drafts global bytes action=do
  (path,root,replies)<-configurationFile work name drafts global bytes
  descriptor<-BS.readFile(source </> "test/fixtures/runtime/descriptor-v3/valid.json") >>= right.decodeWorkflowDescriptor
  let native=descriptor {workflowInputs=[WorkflowInputDescriptor "first" DescriptorPrompt,WorkflowInputDescriptor "second" DescriptorCommandTail,WorkflowInputDescriptor "third" DescriptorStdin]}
  BS.writeFile replies(encoded[native])
  config<-loadConfiguration (\args->if null args then Right() else Left InvalidConfiguration)  exactPreparedTarget (const False) path >>=right
  bracket (installConfiguration config >>=right) closeConfiguration $ \installed->withCoordinationStore installed $ \store->do
    (_,profiles)<-configurationSnapshot installed >>=right
    profile<-case profiles of [value]->pure(publicRevision value);_->error "fixture profile"
    discovery<-probeConfiguredProfile installed "profile_1" profile >>=right
    mutate store $ do
      execute "INSERT INTO clients VALUES ('client_1','r','a',0),('client_2','r','a',0)" []
      forM_ [("credential_1","client_1",bearer),("credential_2","client_2",secondBearer)] $ \(credential,client,secret)->do
        execute "INSERT INTO credentials VALUES (?,?,?,'2999-01-01T00:00:00Z',0)" [txt credential,txt client,SQL.SQLBlob(convert(hash secret::Digest SHA256))]
        forM_ ["observe","submit","control"] $ \scope->execute "INSERT INTO credential_scopes VALUES (?,'profile_1',?)" [txt credential,txt scope]
    proof<-authenticateCredential store bearer >>=right
    action(Fixture path root replies config installed store proof profile discovery)

configurationFile :: FilePath -> String -> Int -> Int -> Int64 -> IO (FilePath,FilePath,FilePath)
configurationFile work name drafts global bytes=do
  executable<-getExecutablePath
  let root=work </> name;path=work </> (name<>".json");replies=work </> (name<>"-catalogue.json")
  createDirectory root;setFileMode root 0o700
  BS.writeFile path(encoded(object["version" .= (1::Int),"managerRoot" .= root,"localRetentionRoots" .= ([]::[String]),
    "runners" .= [object["alias" .= ("runner"::Text),"executable" .= executable,"prefix" .= ["runner",replies]]],
    "profiles" .= [object["id" .= ("profile_1"::Text),"runner" .= ("runner"::Text),"workspace" .= work,"workspaceLabel" .= ("fixture"::Text),
      "targetLabel" .= ("no engine"::Text),"targetArguments" .= ([]::[String]),"environment" .= ([]::[String]),"ownership" .= ("service-owned"::Text),
      "quarantined" .= False,"personAnswering" .= ("local-control"::Text),"resourceKeys" .= ([]::[String])]],
    "limits" .= object["drafts" .= drafts,"globalDrafts" .= global,"globalCaptureBytes" .= bytes,"globalPageSets" .= (2::Int),
      "globalConnections" .= (8::Int),"globalDatabaseReaders" .= (2::Int),"globalMutationLedgerBytes" .= (134217728::Int),
      "safetyControlsPerMinute" .= (20::Int),"executionReservations" .= (1::Int)]]))
  setFileMode path 0o600
  pure(path,root,replies)

createBody :: Text -> Discovery -> BS.ByteString
createBody profile discovery = case discoveryEntries discovery of
  [(ident,_)]->encoded(object["workflowId" .= ident,"descriptorRevision" .= discoveryRevision discovery,"profileId" .= ("profile_1"::Text),"profileRevision" .= profile])
  _->error "fixture catalogue"
key :: CoordinationStore -> Text -> IO Text
key store suffix=do identity<-storeIdentity store;pure(storeAuthorityEpoch identity<>"."<>T.replicate 22 "n"<>suffix)
newDraft :: Fixture -> Text -> IO DraftView
newDraft (Fixture _ _ _ _ _ store proof profile discovery) suffix=do
  nonce<-key store suffix
  createDraft store proof nonce(createBody profile discovery)>>=right
setLiteral :: CoordinationStore -> CredentialProof -> DraftView -> Text -> Text -> Text -> IO CommandReceipt
setLiteral store proof view nonce name value=do
  actualKey<-key store nonce
  changeDraftInput store proof (draftId view) actualKey (Just("\""<>draftRevision view<>"\""))
    (encoded(object["operation" .= ("set-input"::Text),"input" .= LiteralValue name value]))>>=right
bindCapture :: CoordinationStore -> CredentialProof -> DraftView -> Text -> Text -> CaptureReceipt -> IO (Either CommandFailure CommandReceipt)
bindCapture store proof view nonce name capture=do
  actualKey<-key store nonce
  changeDraftInput store proof (draftId view) actualKey (Just("\""<>draftRevision view<>"\""))
    (encoded(object["operation" .= ("set-input"::Text),"input" .= CapturedValue name(captureId capture)]))
chunks :: [BS.ByteString] -> IO (IO BS.ByteString)
chunks values=do ref<-newIORef values;pure(atomicModifyIORef' ref $ \items->case items of []->([],BS.empty);part:rest->(rest,part))
mutate :: NFData a => CoordinationStore -> Transaction a -> IO a
mutate store action=runTransaction store $ do result<-action;pure(result,[Invalidation "service.changed" "/v1/capabilities" "fixture"])
number :: CoordinationStore -> Text -> IO Int64
number store sql=runRead store $ do rows<-query sql [];case rows of [[SQL.SQLInteger value]]->pure value;_->refuseTransaction StoreIntegrity
rowsEqual :: CoordinationStore -> Text -> [[SQL.SQLData]] -> IO Bool
rowsEqual store sql expected=runRead store((==expected)<$>query sql [])
txt :: Text -> SQL.SQLData
txt=SQL.SQLText

literalContract :: IO ()
literalContract=forM_ ["","x","x\r\n","x\n","雪λ"] $ \value->do
  check "shared native prompt literal bytes" (frontendLiteralBytes DescriptorPrompt value==TE.encodeUtf8 value<>"\n")
  check "shared native command-tail literal bytes" (frontendLiteralBytes DescriptorCommandTail value==TE.encodeUtf8 value)
  check "shared native stdin literal bytes" (frontendLiteralBytes DescriptorStdin value==TE.encodeUtf8 value)

bindingContract :: IO ()
bindingContract=do
  input<-chunks["partial"]
  (_,unfinished)<-measureCommandBody Capture input (\next->void next)
  check "stream binding cannot be finalized before EOF" (case unfinished of Nothing->True;_->False)
  complete<-chunks["exact","\r\n"]
  let drain next=next>>= \bytes->unless(BS.null bytes)(drain next)
  (_,finished)<-measureCommandBody Capture complete drain
  check "stream binding derives actual bytes only at EOF" (case finished of
    Just value->bodyBindingBytes value==7 && bodyBindingSha256 value==T.pack(show(hash ("exact\r\n"::BS.ByteString)::Digest SHA256))
    Nothing->False)

data CorpusCase = CorpusCase FilePath Text Bool
instance FromJSON CorpusCase where
  parseJSON=withObject "case" $ \o->CorpusCase <$> o .: "file" <*> o .: "schema" <*> o .: "valid"
newtype Corpus = Corpus [CorpusCase]
instance FromJSON Corpus where parseJSON=withObject "manifest" $ \o->Corpus <$> o .: "cases"
corpusChecks :: FilePath -> IO ()
corpusChecks source=do
  Corpus cases<-BS.readFile(source </> "test/fixtures/manager/v1/manifest.json")>>=right.eitherDecodeStrict'
  forM_ [entry|entry@(CorpusCase _ schema _)<-cases,schema `elem` ["Request","Readiness","InputDeclaration","SuppliedInput","CaptureReceipt"]] $ \(CorpusCase file schema expected)->do
    bytes<-BS.readFile(source </> "test/fixtures/manager/v1" </> file)
    let valid=case schema of
          "Request"->isRight(eitherDecodeStrict' bytes::Either String DraftView)
          "Readiness"->isRight(eitherDecodeStrict' bytes::Either String Readiness)
          "InputDeclaration"->isRight(eitherDecodeStrict' bytes::Either String InputDeclaration)
          "SuppliedInput"->isRight(eitherDecodeStrict' bytes::Either String SuppliedInput)
          _->isRight(eitherDecodeStrict' bytes::Either String CaptureReceipt)
    check ("frozen draft corpus "<>file) (valid==expected)

draftChecks :: FilePath -> FilePath -> IO ()
draftChecks work source=withFixture work source "drafts" 5 8 134217728 $ \fixture@(Fixture path _ replies config installed store proof profile discovery)->do
  operatorBytes<-BS.readFile path
  view<-newDraft fixture "create"
  BS.writeFile(work </> "actual-request.json")(encoded view)
  let Readiness declarations supplied missing errors=draftReadiness view
  check "trusted native catalogue establishes ordered required inputs" (declarations==[InputDeclaration "first" "prompt",InputDeclaration "second" "command-tail",InputDeclaration "third" "stdin"] && null supplied && missing==["first","second","third"] && null errors)
  _<-setLiteral store proof view "empty" "first" ""
  current<-readDraft store proof(draftId view)>>=right
  check "empty literal is supplied rather than missing" (case draftReadiness current of Readiness _ inputs absent _->LiteralValue "first" "" `elem` inputs && "first" `notElem` absent)
  _<-setLiteral store proof current "unicode" "second" "雪\r\n"
  current2<-readDraft store proof(draftId view)>>=right
  _<-setLiteral store proof current2 "last" "third" "last\n"
  ready<-readDraft store proof(draftId view)>>=right
  BS.writeFile(work </> "actual-ready.json")(encoded ready)
  (setup,frame)<-assembleDraft store proof(draftId view)>>=right
  check "actual shared frontend codec round-trip and declaration order" (decodeFrontendSetupRequest frame==Right setup && case setup of RootSetup request->setupInputs request==[("first",Literal ""),("second",Literal "雪\r\n"),("third",Literal "last\n")];_->False)
  mutate store(execute "DELETE FROM credential_scopes WHERE credential_id='credential_1' AND scope='observe'" [])
  nonce<-key store "create"
  original<-createDraft store proof nonce(createBody profile discovery)>>=right
  check "Submit-only create retry returns immutable original view, not later inputs" (original==view)
  expect "Submit-only cannot read current Observe-only inputs" Forbidden(readDraft store proof(draftId view))
  mutate store(execute "INSERT INTO credential_scopes VALUES ('credential_1','profile_1','observe')" [])
  duplicate<-key store "duplicate"
  expect "duplicate fields reject before object-map loss" InvalidRequest(createDraft store proof duplicate "{\"workflowId\":\"x\",\"workflowId\":\"y\"}")
  forM_ [("unknown",LiteralValue "unknown" "x")] $ \(suffix,input)->do
    k<-key store suffix
    expect "unknown input refuses without mutation" InvalidInput(changeDraftInput store proof(draftId view)k(Just("\""<>draftRevision ready<>"\""))(encoded(object["operation" .= ("set-input"::Text),"input" .= input])))
  k<-key store "null"
  expect "null is not substituted for literal text" InvalidRequest(changeDraftInput store proof(draftId view)k(Just("\""<>draftRevision ready<>"\""))"{\"operation\":\"set-input\",\"input\":{\"name\":\"first\",\"source\":\"literal\",\"value\":null}}")
  originalBytes<-BS.readFile replies
  _<-probeConfiguredProfile installed "profile_1" profile >>=right
  freshKey<-key store "old-catalogue"
  expect "replaced catalogue fences fresh descriptor selection" StaleRevision(createDraft store proof freshKey(createBody profile discovery))
  createDraft store proof nonce(createBody profile discovery)>>=right>>=check "catalogue replacement does not erase completed retry" . (==view)
  BS.writeFile replies "FAIL"
  failed<-probeConfiguredProfile installed "profile_1" profile
  check "failed discovery is observable" (either(const True)(const False)failed)
  expect "failed discovery clears current catalogue authority" StorageUnavailable(createDraft store proof freshKey(createBody profile discovery))
  BS.writeFile replies "WAIT"
  pending<-async(probeConfiguredProfile installed "profile_1" profile)
  let waitReady=doesFileExist(replies<>".ready")>>= \done->unless done(threadDelay 1000>>waitReady)
  await waitReady
  cancel pending
  outcome<-waitCatch pending
  check "interrupted probe preserves exception identity" (case outcome of
    Left failure->case fromException failure of Just AsyncCancelled->True;Nothing->False
    Right _->False)
  expect "interrupted probe leaves no current catalogue" StorageUnavailable(createDraft store proof freshKey(createBody profile discovery))
  BS.writeFile replies originalBytes
  _<-probeConfiguredProfile installed "profile_1" profile >>=right
  void(reloadConfiguration installed config >>=right)
  expect "reload clears cached catalogue" StorageUnavailable(createDraft store proof freshKey(createBody profile discovery))
  readDraft store proof(draftId view)>>=right>>=check "readback preserves original revisions and literal bytes after policy change" . (==ready)
  expect "assembly never silently adopts changed policy" StorageUnavailable(assembleDraft store proof(draftId view))
  BS.readFile path>>=check "draft and discovery operations preserve operator configuration bytes" . (==operatorBytes)

uploadChecks :: FilePath -> FilePath -> IO ()
uploadChecks work source=withFixture work source "uploads" 10 10 134217728 $ \fixture@(Fixture _ root _ _ _ store proof _ _)->do
  view<-newDraft fixture "upload-request"
  nonce<-key store "capture"
  input<-chunks [BS.pack[0xe9],BS.pack[0x9b,0xaa],"\r","\n"]
  capture<-uploadCapture store proof(draftId view)nonce 8 input>>=right
  BS.writeFile(work </> "actual-capture.json")(encoded capture)
  check "UTF8 split across stream chunks preserves exact bytes" (captureBytes capture==5 && captureDigest capture==T.pack(show(hash(TE.encodeUtf8 "雪\r\n")::Digest SHA256)))
  names<-listDirectory(root </> "captures")
  again<-chunks[TE.encodeUtf8 "雪\r\n"]>>=uploadCapture store proof(draftId view)nonce 8>>=right
  check "exact upload retry preserves capture identity and result" (again==capture)
  listDirectory(root </> "captures")>>=check "exact retry publishes no second file" . (==names)
  other<-authenticateCredential store secondBearer>>=right
  expect "capture binding checks registered client association" Forbidden(bindCapture store other view "foreign-bind" "second" capture)
  bindCapture store proof view "bind" "second" capture>>=right>>=const(pure())
  current<-readDraft store proof(draftId view)>>=right
  _<-setLiteral store proof current "literal-one" "first" ""
  next<-readDraft store proof(draftId view)>>=right
  _<-setLiteral store proof next "literal-three" "third" ""
  (frame,_)<-assembleDraft store proof(draftId view)>>=right
  check "capture assembly preserves transport rather than literal interpretation" (case frame of RootSetup request->lookup "second"(setupInputs request)==Just(Transport "雪\r\n");_->False)
  BS.writeFile(root </> "captures" </> T.unpack(captureId capture)) "wrong"
  damaged<-readDraft store proof(draftId view)>>=right
  check "tampered committed bytes create a persisted readiness failure" (case draftReadiness damaged of Readiness _ _ _ errors->InputError "second" "capture-unavailable" `elem` errors)
  rowsEqual store "SELECT validation_errors FROM requests" [[SQL.SQLBlob(encoded[InputError "second" "capture-unavailable"])]]>>=check "readiness failure persisted with request state"
  result<-assembleDraft store proof(draftId view)
  check "tampered capture cannot reach a successful frontend frame" (either(const True)(const False)result)
  removeFile(root </> "captures" </> T.unpack(captureId capture))
  readDraft store proof(draftId view)>>=right>>= \missing->check "missing bytes are not reconstructed" (case draftReadiness missing of Readiness _ _ _ errors->not(null errors))
  linksBefore<-number store "SELECT count(*) FROM command_captures"
  brokenKey<-key store "invalid-utf8"
  invalid<-chunks[BS.pack[0xe9],BS.pack[0xff]]
  expect "invalid fragmented UTF8 upload never commits a receipt" InvalidInput(uploadCapture store proof(draftId view)brokenKey 4 invalid)
  number store "SELECT count(*) FROM captures" >>=check "invalid UTF8 creates no capture metadata" . (==1)
  truncatedKey<-key store "truncated-utf8"
  truncated<-chunks[BS.pack[0xe9],BS.pack[0x9b]]
  expect "incomplete UTF8 at EOF refuses upload" InvalidInput(uploadCapture store proof(draftId view)truncatedKey 2 truncated)
  number store "SELECT count(*) FROM captures" >>=check "truncated UTF8 creates no capture metadata" . (==1)
  number store "SELECT count(*) FROM command_captures" >>=check "truncated UTF8 creates no command capture link" . (==linksBefore)
  faultKey<-key store "uncertain"
  armFailure 2
  dataSource<-chunks["kept"]
  expect "real post-link barrier failure refuses capture success" StorageUnavailable(uploadCapture store proof(draftId view)faultKey 4 dataSource)
  failureFired >>=check "fault fired at the actual directory barrier" . (==1)
  armFailure 0
  number store "SELECT count(*) FROM capture_uploads WHERE state='orphan'" >>=check "uncertain publication remains charged as orphan" . (>=1)
  files<-listDirectory(root </> "captures")
  contents<-mapM (BS.readFile . ((root </> "captures") </>)) files
  check "unconfirmed final bytes remain installed" ("kept" `elem` contents)
  number store "SELECT count(*) FROM captures" >>=check "unconfirmed publication creates no capture metadata" . (==1)
  number store "SELECT count(*) FROM command_captures" >>=check "unconfirmed publication creates no command capture link" . (==linksBefore)
  cancelKey<-key store "cancelled"
  started<-newEmptyMVar;release<-newEmptyMVar
  worker<-async(uploadCapture store proof(draftId view)cancelKey 8 (putMVar started()>>takeMVar release>>pure BS.empty))
  await(takeMVar started)
  cancel worker
  cancelled<-waitCatch worker
  check "upload cancellation preserves original exception" (case cancelled of
    Left failure->case fromException failure of Just AsyncCancelled->True;Nothing->False
    Right _->False)
  number store "SELECT count(*) FROM captures" >>=check "cancelled upload has no successful metadata" . (==1)
  forM_ [(brokenKey,"invalid UTF8"),(truncatedKey,"truncated UTF8"),(faultKey,"unconfirmed publication"),(cancelKey,"cancelled upload")] $ \(nonceKey,label)->do
    absent<-runRead store((==[[SQL.SQLInteger 0]]) <$> query "SELECT count(*) FROM commands WHERE idempotency_key=?" [txt nonceKey])
    check(label<>" creates no command receipt") absent

quotaChecks :: FilePath -> FilePath -> IO ()
quotaChecks work source=do
  withFixture work source "draft-quota" 1 2 64 $ \fixture@(Fixture _ _ _ _ _ store proof profile discovery)->do
    _<-newDraft fixture "one"
    k<-key store "two"
    expect "per-client draft quota applies before insertion" StorageQuota(createDraft store proof k(createBody profile discovery))
    other<-authenticateCredential store secondBearer>>=right
    createDraft store other k(createBody profile discovery)>>=right>>=const(pure())
    k3<-key store "three"
    expect "global draft quota is independent" StorageQuota(createDraft store other k3(createBody profile discovery))
  withFixture work source "holding-count" 2 2 64 $ \fixture@(Fixture _ root _ _ _ store proof _ _)->do
    view<-newDraft fixture "holding"
    forM_ [1..255::Int] $ \n->do
      k<-key store(T.pack(show n))
      armFailure 2
      expect "zero-byte uncertain upload retains one holding slot" StorageUnavailable(uploadCapture store proof(draftId view)k 0 (pure BS.empty))
      failureFired>>=check "one-shot barrier fault fired" . (==1)
    armFailure 0
    k<-key store "last"
    started<-newEmptyMVar;release<-newEmptyMVar
    worker<-async(uploadCapture store proof(draftId view)k 0 (putMVar started()>>takeMVar release>>pure BS.empty))
    await(takeMVar started)
    k2<-key store "concurrent"
    expect "concurrent admission at last slot is fail-fast" StorageUnavailable(uploadCapture store proof(draftId view)k2 0 (pure BS.empty))
    putMVar release()
    result<-wait worker>>=right
    number store "SELECT (SELECT count(*) FROM captures)+(SELECT count(*) FROM capture_uploads)" >>=check "successful conversion counts one slot only" . (==256)
    expect "257th zero-byte holding entry refuses" StorageQuota(uploadCapture store proof(draftId view)k2 0 (pure BS.empty))
    uploadCapture store proof(draftId view)k 0 (pure BS.empty)>>=right>>=check "exact retry succeeds at holding saturation" . (==result)
    listDirectory(root </> "captures")>>=check "retry did not publish a 257th file" . ((==256).length)

holdingByteChecks :: FilePath -> FilePath -> IO ()
holdingByteChecks work source=withFixture work source "holding-bytes" 5 5 134217728 $ \fixture@(Fixture _ _ _ _ _ store proof _ _)->do
  let limit=67108864
      publishedBytes=16777216
      orphanBytes=limit-publishedBytes-4
      totalHolding="SELECT coalesce((SELECT sum(literal_bytes) FROM request_inputs),0)+coalesce((SELECT sum(bytes) FROM captures),0)+coalesce((SELECT sum(reserved_bytes) FROM capture_uploads),0)"
  view<-newDraft fixture "mixed"
  _<-setLiteral store proof view "literal" "first" "abc"
  current<-readDraft store proof(draftId view)>>=right
  uploadKey<-key store "published"
  payload<-chunks(replicate 256 (BS.replicate 65536 120))
  capture<-uploadCapture store proof(draftId view)uploadKey publishedBytes payload>>=right
  bindCapture store proof current "bind-second" "second" capture>>=right>>=const(pure())
  bound<-readDraft store proof(draftId view)>>=right
  bindCapture store proof bound "bind-third" "third" capture>>=right>>=const(pure())
  orphanKey<-key store "orphan"
  orphanSource<-chunks["kept"]
  armFailure 2
  expect "mixed holding uses actual uncertain publication" StorageUnavailable(uploadCapture store proof(draftId view)orphanKey orphanBytes orphanSource)
  failureFired>>=check "mixed holding fault reaches real directory barrier" . (==1)
  armFailure 0
  number store "SELECT sum(reserved_bytes) FROM capture_uploads WHERE state='orphan'" >>=check "uncertain upload retains its entire byte reservation" . (==orphanBytes)
  number store totalHolding>>=check "mixed holdings leave exactly one byte available" . (==limit-1)
  pendingKey<-key store "pending-boundary"
  started<-newEmptyMVar;release<-newEmptyMVar
  bracket (async(uploadCapture store proof(draftId view)pendingKey 1 (putMVar started()>>takeMVar release>>pure BS.empty))) cancel $ \pending->do
    await(takeMVar started)
    number store totalHolding>>=check "literal capture orphan and pending bytes accept exact holding limit" . (==limit)
    rowsEqual store "SELECT reserved_bytes FROM capture_uploads WHERE state='pending'" [[SQL.SQLInteger 1]]>>=check "boundary reservation commits before source proceeds"
    putMVar release()
    wait pending>>=right>>=check "empty publication releases unused reserved byte" . ((==0).captureBytes)
  number store totalHolding>>=check "completed reservation is not double charged" . (==limit-1)
  ready<-readDraft store proof(draftId view)>>=right
  _<-setLiteral store proof ready "literal-boundary" "first" "abcd"
  number store totalHolding>>=check "literal replacement accepts exact mixed holding limit" . (==limit)
  number store "SELECT sum(CASE WHEN i.source='literal' THEN i.literal_transport_bytes ELSE c.bytes END) FROM request_inputs i LEFT JOIN captures c ON c.id=i.capture_id" >>=check "native assembled input use still has independent headroom" . (<limit)
  exact<-readDraft store proof(draftId view)>>=right
  commandsBefore<-number store "SELECT count(*) FROM commands"
  sequenceBefore<-number store "SELECT CAST(sequence AS INTEGER) FROM service_metadata"
  overLiteralKey<-key store "literal-over"
  expect "one extra literal byte refuses per-request holding quota" StorageQuota(changeDraftInput store proof(draftId view)overLiteralKey (Just("\""<>draftRevision exact<>"\""))
    (encoded(object["operation" .= ("set-input"::Text),"input" .= LiteralValue "first" "abcde"])))
  calls<-newIORef(0::Int)
  overUploadKey<-key store "upload-over"
  expect "one extra upload byte refuses per-request holding quota" StorageQuota(uploadCapture store proof(draftId view)overUploadKey 1 (modifyIORef' calls(+1)>>pure BS.empty))
  readIORef calls>>=check "holding quota refuses before consuming upload source" . (==0)
  readDraft store proof(draftId view)>>=right>>=check "holding quota refusals preserve exact request state" . (==exact)
  number store totalHolding>>=check "holding quota refusals preserve charged bytes" . (==limit)
  number store "SELECT count(*) FROM commands" >>=check "holding quota refusals create no command receipt" . (==commandsBefore)
  number store "SELECT CAST(sequence AS INTEGER) FROM service_metadata" >>=check "holding quota refusals emit no invalidation" . (==sequenceBefore)
  rowsEqual store "SELECT (SELECT count(*) FROM captures),(SELECT count(*) FROM capture_uploads),(SELECT count(*) FROM capture_uploads WHERE state='pending')"
    [[SQL.SQLInteger 2,SQL.SQLInteger 1,SQL.SQLInteger 0]]>>=check "holding quota refusals create no capture or reservation"

lifecycleChecks :: FilePath -> FilePath -> IO ()
lifecycleChecks work source=withFixture work source "lifecycle" 5 5 8 $ \fixture@(Fixture _ root _ _ _ store proof _ _)->do
  view<-newDraft fixture "queued"
  mutate store(execute "UPDATE requests SET phase='queued',admission='waiting',queue_ordinal='1' WHERE id=?" [txt(draftId view)])
  queued<-readDraft store proof(draftId view)>>=right
  _<-setLiteral store proof queued "dequeue" "second" ""
  rowsEqual store "SELECT phase,admission,queue_ordinal FROM requests"
    [[txt"draft",txt"not-queued",SQL.SQLNull]]>>=check "queued edit atomically leaves the admission queue"
  current<-readDraft store proof(draftId view)>>=right
  mutate store(execute "INSERT INTO reservations (id,request_id,slot,process_generation,state) VALUES ('reservation',?,0,'generation','held')" [txt(draftId view)])
  k<-key store "reserved"
  expect "reserved request cannot pretend a worker was discarded" StateConflict(changeDraftInput store proof(draftId view)k(Just("\""<>draftRevision current<>"\""))(encoded(object["operation" .= ("set-input"::Text),"input" .= LiteralValue "second" "blocked"])))
  mutate store(execute "UPDATE reservations SET state='released',slot=NULL" [])
  uploadKey<-key store "bounded"
  bytes<-chunks["12345678"]
  capture<-uploadCapture store proof(draftId view)uploadKey 8 bytes>>=right
  check "declared exact upload byte ceiling succeeds" (captureBytes capture==8)
  called<-newIORef(0::Int)
  extraKey<-key store "excess"
  expect "global capture admission precedes source consumption" StorageQuota(uploadCapture store proof(draftId view)extraKey 1 (modifyIORef' called(+1)>>pure BS.empty))
  readIORef called>>=check "unreserved excess upload source was not called" . (==0)
  body<-BS.readFile(root </> "captures" </> T.unpack(captureId capture))
  check "exact uploaded bytes survived real publication" (body=="12345678")

atomicOriginChecks :: FilePath -> FilePath -> IO ()
atomicOriginChecks work source=withFixture work source "atomic-origin" 5 5 1024 $ \(Fixture _ root _ _ _ store proof profile discovery)->do
  let raw action=bracket(SQL.open(T.pack(root </> "coordination.sqlite3")))SQL.close action
  raw $ \db->SQL.exec db "CREATE TRIGGER fail_command_event BEFORE INSERT ON invalidations WHEN NEW.kind='command.changed' BEGIN SELECT RAISE(ABORT,'fixture command event failure'); END"
  k<-key store "rollback"
  expect "failed invalidation cannot create a successful draft origin" StorageUnavailable(createDraft store proof k(createBody profile discovery))
  forM_ ["requests","request_inputs","request_origins","commands"] $ \table->
    number store ("SELECT count(*) FROM "<>table)>>=check ("atomic rollback of "<>T.unpack table) . (==0)
  raw $ \db->SQL.exec db "DROP TRIGGER fail_command_event"
  view<-createDraft store proof k(createBody profile discovery)>>=right
  raw $ \db->SQL.exec db "CREATE TRIGGER fail_capture_event BEFORE INSERT ON invalidations WHEN NEW.kind='command.changed' BEGIN SELECT RAISE(ABORT,'fixture capture event failure'); END"
  uploadKey<-key store "capture-rollback"
  input<-chunks["kept"]
  expect "metadata failure after confirmed publication returns no capture receipt" StorageUnavailable(uploadCapture store proof(draftId view)uploadKey 4 input)
  number store "SELECT count(*) FROM captures" >>=check "failed capture metadata is rolled back" . (==0)
  number store "SELECT count(*) FROM command_captures" >>=check "failed capture link is rolled back" . (==0)
  number store "SELECT count(*) FROM capture_uploads WHERE state='orphan' AND reserved_bytes=4" >>=check "confirmed but unreceipted publication remains charged" . (==1)
  names<-listDirectory(root </> "captures")
  bytes<-mapM (BS.readFile . ((root </> "captures") </>)) names
  check "installed final file is never unlinked as SQL rollback" (bytes==["kept"])

reopenChecks :: FilePath -> FilePath -> IO ()
reopenChecks work source=do
  (path,expected,oldProof)<-withFixture work source "reopen" 5 5 134217728 $ \fixture@(Fixture path _ _ _ _ store proof _ _)->do
    view<-newDraft fixture "root"
    _<-setLiteral store proof view "one" "first" (T.replicate 65535 "a"<>"雪\r\n")
    current<-readDraft store proof(draftId view)>>=right
    k<-key store "source-file"
    let clientPath=work </> "client-source.utf8"
    BS.writeFile clientPath(TE.encodeUtf8 "transport雪\r\n")
    capture<-withBinaryFile clientPath ReadMode $ \handle->uploadCapture store proof(draftId view)k 100 (BS.hGetSome handle 3)>>=right
    BS.writeFile clientPath "client changed after upload"
    bindCapture store proof current "two" "second" capture>>=right>>=const(pure())
    next<-readDraft store proof(draftId view)>>=right
    _<-setLiteral store proof next "three" "third" ""
    ready<-readDraft store proof(draftId view)>>=right
    (setup,_)<-assembleDraft store proof(draftId view)>>=right
    check "changed client source has no effect on retained transport" (case setup of RootSetup request->lookup "second"(setupInputs request)==Just(Transport "transport雪\r\n");_->False)
    pure(path,ready,proof)
  config<-loadConfiguration(const(Right())) exactPreparedTarget (const False)path>>=right
  bracket(installConfiguration config>>=right)closeConfiguration $ \installed->withCoordinationStore installed $ \store->do
    expect "earlier store proof cannot read reopened draft" Unauthenticated(readDraft store oldProof(draftId expected))
    expect "earlier store proof cannot assemble reopened draft" Unauthenticated(assembleDraft store oldProof(draftId expected))
    direct<-runRead store(currentClient oldProof)
    check "owning authority primitive rejects earlier transaction lifetime" (direct==Left Unauthenticated)
    proof<-authenticateCredential store bearer>>=right
    actual<-readDraft store proof(draftId expected)>>=right
    check "full reopen preserves exact literal/capture representations and original revisions" (actual==expected)
    expect "reopen never recreates catalogue execution authority" StorageUnavailable(assembleDraft store proof(draftId expected))

sameConfigurationReopenChecks :: FilePath -> FilePath -> IO ()
sameConfigurationReopenChecks work source=do
  (path,_,replies)<-configurationFile work "same-configuration-reopen" 5 5 1024
  native<-BS.readFile(source </> "test/fixtures/runtime/descriptor-v3/valid.json")>>=right.decodeWorkflowDescriptor
  BS.writeFile replies(encoded[native])
  config<-loadConfiguration(const(Right())) exactPreparedTarget (const False)path>>=right
  bracket(installConfiguration config>>=right)closeConfiguration $ \installed->do
    (_,profiles)<-configurationSnapshot installed>>=right
    revision<-case profiles of [profile]->pure(publicRevision profile);_->error "fixture profile missing"
    discovery<-probeConfiguredProfile installed "profile_1" revision>>=right
    (original,oldProof)<-withCoordinationStore installed $ \store->do
      mutate store $ do
        execute "INSERT INTO clients VALUES ('client_1','r','a',0)" []
        execute "INSERT INTO credentials VALUES ('credential_1','client_1',?,'2999-01-01T00:00:00Z',0)" [SQL.SQLBlob(convert(hash bearer::Digest SHA256))]
        execute "INSERT INTO credential_scopes VALUES ('credential_1','profile_1','observe'),('credential_1','profile_1','submit')" []
      proof<-authenticateCredential store bearer>>=right
      nonce<-key store "create"
      view<-createDraft store proof nonce(createBody revision discovery)>>=right
      _<-setLiteral store proof view "subject" "subject" "retained"
      next<-readDraft store proof(draftId view)>>=right
      _<-setLiteral store proof next "notes" "notes" ""
      ready<-readDraft store proof(draftId view)>>=right
      void(assembleDraft store proof(draftId view)>>=right)
      pure(ready,proof)
    withCoordinationStore installed $ \store->do
      expect "old proof refuses draft read despite retained current catalogue" Unauthenticated(readDraft store oldProof(draftId original))
      expect "old proof refuses assembly despite retained current catalogue" Unauthenticated(assembleDraft store oldProof(draftId original))
      freshProof<-authenticateCredential store bearer>>=right
      readDraft store freshProof(draftId original)>>=right>>=check "fresh proof reads unchanged stored revisions in new lifetime" . (==original)
      (setup,bytes)<-assembleDraft store freshProof(draftId original)>>=right
      check "fresh proof assembles through unchanged live catalogue authority" (decodeFrontendSetupRequest bytes==Right setup)

framingChecks :: FilePath -> FilePath -> IO ()
framingChecks work source=withFixture work source "framing" 10 10 134217728 $ \fixture@(Fixture _ root _ _ _ store proof _ _)->do
  view<-newDraft fixture "transport"
  _<-setLiteral store proof view "first" "first" ""
  current<-readDraft store proof(draftId view)>>=right
  _<-setLiteral store proof current "third" "third" ""
  ready<-readDraft store proof(draftId view)>>=right
  k<-key store "escaped-transport"
  sourceBytes<-chunks[BS.replicate 50000 0 | _<-[1..8::Int]]
  capture<-uploadCapture store proof(draftId view)k 400000 sourceBytes>>=right
  bindCapture store proof ready "bind-escaped" "second" capture>>=right>>=const(pure())
  (setup,bytes)<-assembleDraft store proof(draftId view)>>=right
  check "actual escaped transport frame falls back only to server-owned file" (BS.length bytes<=maxFrontendQueryBytes && case setup of
    RootSetup request->lookup "second"(setupInputs request)==Just(File(root </> "captures" </> T.unpack(captureId capture))) && lookup "first"(setupInputs request)==Just(Literal "")
    _->False)
  literalDraft<-newDraft fixture "literal-frame"
  _<-setLiteral store proof literalDraft "lf-first" "first" ""
  literalNext<-readDraft store proof(draftId literalDraft)>>=right
  _<-setLiteral store proof literalNext "lf-third" "third" ""
  literalReady<-readDraft store proof(draftId literalDraft)>>=right
  let body inputValue=encoded(object["operation" .= ("set-input"::Text),"input" .= LiteralValue "second" inputValue])
      value=T.replicate ((2097152-BS.length(body "")) `div` 2) "\""
  check "large escaped literal still meets HTTP body ceiling" (BS.length(body value)<=2097152)
  _<-setLiteral store proof literalReady "lf-large" "second" value
  expect "oversized literal frame refuses without transport reinterpretation" SizeLimit(assembleDraft store proof(draftId literalDraft))
  expect "oversized public view refuses without truncation" ViewTooLarge(readDraft store proof(draftId literalDraft))
  corrupt<-newDraft fixture "chunk-integrity"
  _<-setLiteral store proof corrupt "chunk" "first" "abc"
  mutate store(execute "DELETE FROM request_literal_chunks WHERE request_id=?" [txt(draftId corrupt)])
  expect "missing literal chunk does not become empty supplied text" InvalidInput(readDraft store proof(draftId corrupt))
  other<-newDraft fixture "logical-total"
  _<-setLiteral store proof other "logical-first" "first" ""
  otherReady<-readDraft store proof(draftId other)>>=right
  largeKey<-key store "shared-large"
  largeInput<-chunks(replicate 528 (BS.replicate 65536 120))
  large<-uploadCapture store proof(draftId other)largeKey (33*1048576) largeInput>>=right
  bindCapture store proof otherReady "large-one" "second" large>>=right>>=const(pure())
  lastView<-readDraft store proof(draftId other)>>=right
  expect "one capture reused by two inputs cannot evade logical byte limit" SizeLimit(bindCapture store proof lastView "large-two" "third" large)

lifetimeChecks :: FilePath -> FilePath -> IO ()
lifetimeChecks work source=do
  (path,_)<-withFixture work source "file-lifetime" 5 5 64 $ \fixture@(Fixture path _ _ config installed store proof _ _)->do
    view<-newDraft fixture "root"
    k<-key store "in-flight"
    started<-newEmptyMVar;release<-newEmptyMVar
    worker<-async(uploadCapture store proof(draftId view)k 0 (putMVar started()>>takeMVar release>>pure BS.empty))
    await(takeMVar started)
    closeConfiguration installed
    denied<-installConfiguration config
    check "active file work retains exclusive lease after configuration close" (either(const True)(const False)denied)
    putMVar release()
    outcome<-wait worker
    check "closed configuration cannot acknowledge new upload metadata" (either(const True)(const False)outcome)
    pure(path,())
  config<-loadConfiguration(const(Right())) exactPreparedTarget (const False)path>>=right
  bracket(installConfiguration config>>=right)closeConfiguration(const(check "file cleanup releases final ownership" True))

escapedFileChecks :: FilePath -> FilePath -> IO ()
escapedFileChecks work source=do
  started<-newEmptyMVar;release<-newEmptyMVar;published<-newEmptyMVar
  owner<-async $ withFixture work source "escaped-file" 5 5 64 $ \fixture@(Fixture _ _ _ config installed store proof _ _)->do
    view<-newDraft fixture "root"
    k<-key store "escaped"
    upload<-async(uploadCapture store proof(draftId view)k 0 (putMVar started()>>takeMVar release>>pure BS.empty))
    await(takeMVar started)
    putMVar published(config,installed,upload)
  (config,installed,upload)<-await(takeMVar published)
  threadDelay 100000
  progress<-poll owner
  check "store close joins escaped file work rather than abandoning its root" (case progress of Nothing->True;_->False)
  closeConfiguration installed
  denied<-installConfiguration config
  check "no competing owner enters before escaped file cleanup" (either(const True)(const False)denied)
  putMVar release()
  result<-wait upload
  check "store closing refuses escaped upload success" (either(const True)(const False)result)
  await(wait owner)
  bracket(installConfiguration config>>=right)closeConfiguration(const(check "escaped file completion releases ownership" True))

cataloguePageChecks :: FilePath -> FilePath -> IO ()
cataloguePageChecks work source=withFixture work source "catalogue-pages" 5 5 1024 $ \(Fixture _ _ replies _ installed store proof profile initial)->do
  native<-case discoveryWorkflows initial of
    [descriptor]->pure descriptor
    _->error "initial catalogue fixture"
  let descriptors=[native {workflowName="page_workflow_"<>T.pack(show index)}|index<-[0..256::Int]]
  check "multi-page catalogue remains within existing query byte ceiling" (BS.length(encoded descriptors)<4194304)
  BS.writeFile replies(encoded descriptors)
  current<-probeConfiguredProfile installed "profile_1" profile>>=right
  check "actual discovery retains workflows beyond one public page" (length(discoveryEntries current)==257)
  (ident,_)<-maybe(error "workflow beyond first page missing")pure(find((=="page_workflow_256").workflowName.snd)(discoveryEntries current))
  nonce<-key store "beyond-first-page"
  let body=encoded(object["workflowId" .= ident,"descriptorRevision" .= discoveryRevision current,"profileId" .= ("profile_1"::Text),"profileRevision" .= profile])
  created<-createDraft store proof nonce body>>=right
  check "fresh draft selects actual workflow beyond first page" (draftWorkflow created==ident && draftDescriptorRevision created==discoveryRevision current)

declarationMigrationChecks :: FilePath -> IO ()
declarationMigrationChecks work=do
  (path,root,_)<-configurationFile work "declaration-migration" 5 5 1024
  config<-loadConfiguration(const(Right())) exactPreparedTarget (const False)path>>=right
  bracket(installConfiguration config>>=right)closeConfiguration(const(pure()))
  let ordinary=[("native_"<>T.pack(show index),index)|index<-[0..19::Int]]
      declaration name=let prefix=encoded(WorkflowInputDescriptor name DescriptorPrompt)
        in prefix<>BS.replicate(65536-BS.length prefix)32
      validPrefix=encoded(WorkflowInputDescriptor "oversized_unknown" DescriptorPrompt)
      unknown=validPrefix<>BS.replicate(1048576-BS.length validPrefix)32<>BS.replicate(1500000-1048576)120
      literal=TE.encodeUtf8 "雪\r\n"
      raw action=bracket(SQL.open(T.pack(root </> "coordination.sqlite3")))SQL.close action
  check "ordinary declaration batch exceeds aggregate result ceiling" (sum[BS.length(declaration name)|(name,_)<-ordinary]>1048576)
  check "truncating the unknown declaration would misleadingly parse as valid" (isRight(eitherDecodeStrict' (BS.take 1048576 unknown)::Either String WorkflowInputDescriptor))
  check "large unknown declaration exceeds individual result ceiling" (BS.length unknown>1048576 && BS.length unknown+BS.length literal+1024<2097152)
  raw $ \db->do
    setFileMode(root </> "coordination.sqlite3")0o600
    mapM_ (SQL.exec db) (schemaStatements<>commandMigration)
    SQL.exec db "PRAGMA user_version=2; INSERT INTO service_metadata VALUES (1,'epoch','stream','0','0','r'); INSERT INTO clients VALUES ('client','r','a',0); INSERT INTO requests (id,revision,client_id,workflow_id,descriptor_revision,profile_id,profile_revision,phase,admission,blocking_reasons,validation_errors) VALUES ('req','r','client','wf','d','profile_1','p','draft','not-queued',X'5b5d',X'5b5d')"
    let insert name ordinal metadata=bracket(SQL.prepare db "INSERT INTO request_inputs VALUES ('req',?,?,?,'literal',?,NULL)")SQL.finalize $ \statement->do
          SQL.bind statement[txt name,SQL.SQLInteger(fromIntegral ordinal),SQL.SQLBlob metadata,SQL.SQLBlob literal]
          void(SQL.step statement)
    forM_ ordinary $ \(name,index)->insert name index(declaration name)
    insert "oversized_unknown" (20::Int) unknown
  bracket(installConfiguration config>>=right)closeConfiguration $ \installed->withCoordinationStore installed $ \store->do
    storeIdentity store>>=check "large declaration migration completes without raising result limit" . ((==schemaVersion).storeSchemaVersion)
    number store "SELECT count(*) FROM request_inputs WHERE literal_transport_bytes=6" >>=check "ordinary large declarations derive exact native lengths individually" . (==20)
    rowsEqual store "SELECT literal_bytes,literal_transport_bytes,literal_chunks,literal_digest FROM request_inputs WHERE name='oversized_unknown'"
      [[SQL.SQLInteger 5,SQL.SQLNull,SQL.SQLInteger 1,SQL.SQLBlob(convert(hash literal::Digest SHA256))]]>>=check "oversized unknown derivation stays explicit with complete literal integrity"
    number store "SELECT count(*) FROM request_literal_chunks WHERE bytes=x'e99baa0d0a'" >>=check "all original literal byte sequences survive declaration migration" . (==21)
    blocked<-try @StoreFailure(runRead store(query "SELECT declaration FROM request_inputs WHERE name='oversized_unknown'" []>>pure()))
    check "native migration did not weaken the public result budget" (case blocked of Left StoreLimit->True;_->False)
  raw $ \db->do
    bracket(SQL.prepare db "SELECT declaration=? FROM request_inputs WHERE name='oversized_unknown'")SQL.finalize $ \statement->do
      SQL.bind statement[SQL.SQLBlob unknown]
      _<-SQL.step statement
      SQL.columns statement>>=check "unknown declaration bytes were preserved rather than truncated" . (==[SQL.SQLInteger 1])
    forM_ ordinary $ \(name,_)->bracket(SQL.prepare db "SELECT declaration=? FROM request_inputs WHERE name=?")SQL.finalize $ \statement->do
      SQL.bind statement[SQL.SQLBlob(declaration name),txt name]
      _<-SQL.step statement
      SQL.columns statement>>=check "ordinary declaration bytes remain exact" . (==[SQL.SQLInteger 1])

migrationChecks :: FilePath -> IO ()
migrationChecks work=do
  (path,root,_)<-configurationFile work "migration" 5 5 1024
  config<-loadConfiguration (const(Right()))  exactPreparedTarget (const False) path>>=right
  bracket (installConfiguration config>>=right) closeConfiguration (const(pure()))
  bracket (SQL.open(T.pack(root </> "coordination.sqlite3"))) SQL.close $ \db->do
    setFileMode(root </> "coordination.sqlite3")0o600
    mapM_ (SQL.exec db) (schemaStatements<>commandMigration)
    SQL.exec db "PRAGMA user_version=2; INSERT INTO service_metadata VALUES (1,'epoch','stream','0','0','r'); INSERT INTO clients VALUES ('client','r','a',0); INSERT INTO requests (id,revision,client_id,workflow_id,descriptor_revision,profile_id,profile_revision,phase,admission,blocking_reasons,validation_errors) VALUES ('req','r','client','wf','d','profile_1','p','draft','not-queued',X'5b5d',X'5b5d')"
    forM_ [("native",encoded(WorkflowInputDescriptor "native" DescriptorPrompt),TE.encodeUtf8 "雪\r\n"),
           ("unknown","{}",BS.pack[0xff]),("empty","{}",BS.empty),
           ("public",encoded(InputDeclaration "public" "prompt"),"text")] $ \(name,declaration,value)->
      bracket (SQL.prepare db "INSERT INTO request_inputs VALUES ('req',?,?,?,'literal',?,NULL)") SQL.finalize $ \statement->do
        let ordinal=case name of "native"->0;"unknown"->1;"empty"->2;_->3
        SQL.bind statement[txt name,SQL.SQLInteger ordinal,SQL.SQLBlob declaration,SQL.SQLBlob value]
        void(SQL.step statement)
    SQL.exec db "CREATE TABLE capture_uploads (sentinel TEXT)"
  bracket (installConfiguration config>>=right) closeConfiguration $ \installed->do
    failed<-try @StoreFailure(withCoordinationStore installed (const(pure())))
    check "schema3 partial migration failure is explicit" (case failed of Left StoreUnavailable->True;_->False)
  bracket (SQL.open(T.pack(root </> "coordination.sqlite3"))) SQL.close $ \db->do
    bracket (SQL.prepare db "SELECT literal FROM request_inputs WHERE name='unknown'") SQL.finalize $ \statement->do
      _<-SQL.step statement
      SQL.columns statement>>=check "failed schema3 migration preserves original literal bytes" . (==[SQL.SQLBlob(BS.pack[0xff])])
    bracket (SQL.prepare db "PRAGMA user_version") SQL.finalize $ \statement->do
      _<-SQL.step statement
      SQL.columns statement>>=check "failed schema3 migration preserves version two" . (==[SQL.SQLInteger 2])
    SQL.exec db "DROP TABLE capture_uploads"
  bracket (installConfiguration config>>=right) closeConfiguration $ \installed->withCoordinationStore installed $ \store->do
    rowsEqual store "SELECT name,literal_bytes,literal_transport_bytes,literal_chunks FROM request_inputs ORDER BY declaration_ordinal"
      [[txt"native",SQL.SQLInteger 5,SQL.SQLInteger 6,SQL.SQLInteger 1],[txt"unknown",SQL.SQLInteger 1,SQL.SQLNull,SQL.SQLInteger 1],
       [txt"empty",SQL.SQLInteger 0,SQL.SQLNull,SQL.SQLInteger 0],[txt"public",SQL.SQLInteger 4,SQL.SQLNull,SQL.SQLInteger 1]]>>=check "v2 migration preserves unknown native counts explicitly"
    rowsEqual store "SELECT bytes FROM request_literal_chunks WHERE name='unknown'" [[SQL.SQLBlob(BS.pack[0xff])]]>>=check "migration preserves invalid legacy UTF8 without replacement"
    rowsEqual store "SELECT literal_digest FROM request_inputs WHERE name='empty'" [[SQL.SQLBlob(convert(hash BS.empty::Digest SHA256))]]>>=check "empty literal retains its explicit integrity metadata"

foreign import ccall unsafe "draft_arm_sync_failure"
  armFailure :: CInt -> IO ()
foreign import ccall unsafe "draft_sync_failure_fired"
  failureFired :: IO CInt
