{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | Endpoint-bound observations and explicit HTTP attempts, never worker ownership.
module Agentic.Manager.Client
  ( Client, Reference, Observed, PendingCommand, PageSet, pageSetMetadata, pageSetItems, getPageSet, ClientResponse (..), ClientFailure (..),
    connectClient, connectClientProfile, closeClient, clientCapabilities, reference, referenceURI,
    getResource, observeResource, observedReference, observedETag, observedValue, prepareObserved,
    pollEvents, prepareCommand, sendCommand, downloadVerified, decodeObservation,
    DraftView (..), Readiness (..), InputDeclaration (..), SuppliedInput (..), InputError (..),
    Preparation (..), Review (..), ReviewInput (..), PublicPolicy, policyValue,
    CommandReceipt (..), CommandState, Operation, stateName, operationName, effectValue
  ) where

import Agentic.Manager.Protocol.Command
  (validId, validResource, encoded, CommandReceipt (..), CommandState, Operation, stateName, operationName, effectValue)
import Agentic.Manager.Protocol.Draft (DraftView (..), Readiness (..), InputDeclaration (..), SuppliedInput (..), InputError (..))
import Agentic.Manager.Protocol.Preparation (Preparation (..), Review (..), ReviewInput (..), PublicPolicy, policyValue)
import Control.DeepSeq (NFData, deepseq)
import Agentic.Manager.Protocol.Json (decodeStrictValue)
import Control.Exception (Exception, IOException, bracket, bracketOnError, throwIO, try)
import Control.Monad ((>=>), forM_, guard, unless, when)
import Crypto.Hash (Digest, SHA256, hash)
import Crypto.Random (getRandomBytes)
import Data.Aeson (FromJSON (parseJSON), Value (..), withObject, (.:))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson.Types (Parser, parseEither)
import Data.Bits ((.&.))
import Data.List (nub, sort)
import qualified Data.ByteArray as BA
import Data.ByteArray.Encoding (Base (Base16, Base64URLUnpadded), convertToBase)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import qualified Data.CaseInsensitive as CI
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Time.Clock (UTCTime, getCurrentTime)
import Data.Time.Format.ISO8601 (iso8601ParseM)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.X509 (SignedCertificate)
import Data.X509.Memory (readSignedObjectFromMemory)
import Data.X509.CertificateStore (makeCertificateStore)
import Network.Connection (TLSSettings (TLSSettings))
import qualified Network.HTTP.Client as HTTP
import Network.HTTP.Client.TLS (mkManagerSettings)
import qualified Network.HTTP.Types as HTTP
import qualified Network.TLS as TLS
import System.FilePath (isAbsolute)
import System.IO (hClose)
import System.Posix.Files (getFdStatus, isRegularFile, fileSize, fileMode, fileOwner, linkCount)
import System.Posix.IO (OpenFileFlags (nofollow, cloexec, nonBlock), OpenMode (ReadOnly), openFd, closeFd, defaultFileFlags, fdToHandle)
import System.Posix.User (getEffectiveUserID)

-- | Decode and force public observation data using the shared protocol codec.
-- Its identities and receipt facts do not create live ownership or approval.
decodeObservation :: (FromJSON a, NFData a) => Value -> Either ClientFailure a
decodeObservation value = case parseEither parseJSON value of
  Left _ -> Left InvalidResponse
  Right observation -> observation `deepseq` Right observation

-- | One locally retained transport session and its private credential source.
-- No Show, Generic or serialization can disclose that source or its bearer.
data Client = Client !Text !HTTP.Request !HTTP.Manager !(IO BS.ByteString)
  !BS.ByteString !Text !Value !(IORef Bool)

-- | A URI paired with the original client session, not a retargetable string.
data Reference = Reference !Text !Text deriving (Eq, Ord)

-- | Exact pending bytes, key and preconditions for an explicitly requested attempt.
-- This object cannot migrate to another session or credential identity.
data PendingCommand = PendingCommand !Reference !BS.ByteString !(Maybe BS.ByteString) !BS.ByteString

-- | One bounded public response. A receipt is not a replacement run snapshot.
data ClientResponse = ClientResponse
  { responseStatus :: !Int, responseValue :: !Value,
    responseETag :: !(Maybe Text), responseLocation :: !(Maybe Reference), responseBodyBytes :: !Int
  }

-- | Fixed local failures. Request headers and exception diagnostics are not retained.
data ClientFailure = ClientClosed | InvalidEndpoint | WrongEndpoint | CredentialUnavailable
  | CredentialChanged | TransportUnavailable | RedirectRefused | InvalidResponse
  | ResponseTooLarge | UnsupportedVersion | Refused !Int !Text | ClientFileUnavailable | InvalidClientProfile
  deriving (Eq, Show)
instance Exception ClientFailure

-- | The composition root supplies verified TLS settings and a private byte reader.
-- Environment proxies, cookies, redirects and implicit transport retries are disabled.
-- | An explicit operator-supplied client profile, with no implicit registry or
-- manager-store access. Normal certificate and hostname validation remain enabled.
connectClientProfile :: FilePath -> IO (Either ClientFailure Client)
connectClientProfile path = clientIO $ do
  bytes <- readClientFile True 16384 path
  value <- either (const (throwIO InvalidClientProfile)) pure (decodeStrictValue bytes)
  (endpoint, credentialPath, caPath) <- either (const (throwIO InvalidClientProfile)) pure
    (parseEither parseClientProfile value)
  base <- checkedEndpoint endpoint
  caBytes <- readClientFile False 1048576 caPath
  let certificates = readSignedObjectFromMemory caBytes :: [SignedCertificate]
  when (null certificates) (throwIO InvalidClientProfile)
  let defaults = TLS.defaultParamsClient (BC.unpack (HTTP.host base)) ""
      parameters = defaults
        { TLS.clientShared = (TLS.clientShared defaults) {TLS.sharedCAStore = makeCertificateStore certificates},
          TLS.clientSupported = (TLS.clientSupported defaults) {TLS.supportedVersions = [TLS.TLS13]} }
  connectClient (mkManagerSettings (TLSSettings parameters) Nothing) endpoint
    (readClientFile True 512 credentialPath) >>= either throwIO pure

parseClientProfile :: Value -> Parser (Text, FilePath, FilePath)
parseClientProfile = withObject "client profile" $ \fields -> do
  unless (KM.size fields == 4 && all (`KM.member` fields) ["version","endpoint","credentialFile","caFile"])
    (fail "client profile fields")
  version <- fields .: "version" :: Parser Int
  unless (version == 1) (fail "client profile version")
  endpoint <- fields .: "endpoint"
  credential <- fields .: "credentialFile"
  ca <- fields .: "caFile"
  unless (all validClientPath [credential,ca]) (fail "client profile paths")
  pure (endpoint,credential,ca)

validClientPath :: FilePath -> Bool
validClientPath path = isAbsolute path && BS.length (TE.encodeUtf8 (T.pack path)) <= 4096
  && not (any (`elem` ['\NUL','\n','\r']) path)

readClientFile :: Bool -> Int -> FilePath -> IO BS.ByteString
readClientFile private limit path = do
  unless (validClientPath path) (throwIO InvalidClientProfile)
  result <- try @IOException $ bracket acquire hClose $ \handle -> do
    bytes <- BS.hGet handle (limit + 1)
    when (BS.length bytes > limit) (throwIO ClientFileUnavailable)
    pure bytes
  either (const (throwIO ClientFileUnavailable)) pure result
  where
    acquire = bracketOnError
      (openFd path ReadOnly defaultFileFlags {nofollow=True,cloexec=True,nonBlock=True}) closeFd $ \descriptor -> do
        status <- getFdStatus descriptor
        uid <- getEffectiveUserID
        unless (isRegularFile status && fileSize status >= 0 && fileSize status <= fromIntegral limit
          && fileMode status .&. 0o022 == 0
          && (not private || (fileOwner status == uid && fileMode status .&. 0o077 == 0 && linkCount status == 1)))
          (throwIO ClientFileUnavailable)
        fdToHandle descriptor

checkedEndpoint :: Text -> IO HTTP.Request
checkedEndpoint endpoint = do
  unless (T.length endpoint <= 8192 && "https://" `T.isPrefixOf` endpoint
    && not (T.any (\c -> c <= ' ' || c `elem` ("@?#\\" :: String)) endpoint)) (throwIO InvalidEndpoint)
  parsed <- HTTP.parseRequest (T.unpack endpoint)
  unless (HTTP.secure parsed && HTTP.path parsed `elem` ["/v1","/v1/"]
    && BS.null (HTTP.queryString parsed) && null (HTTP.requestHeaders parsed)) (throwIO InvalidEndpoint)
  pure parsed

connectClient :: HTTP.ManagerSettings -> Text -> IO BS.ByteString -> IO (Either ClientFailure Client)
connectClient settings endpoint credentials = clientIO $ do
  parsed <- checkedEndpoint endpoint
  bearer <- readCredential credentials
  nonce <- getRandomBytes 16 :: IO BS.ByteString
  let identity = TE.decodeUtf8 (convertToBase Base16 nonce)
      configured = HTTP.managerSetMaxHeaderLength 16384 $ HTTP.managerSetMaxNumberHeaders 100 $
        HTTP.managerSetProxy HTTP.noProxy settings
        {HTTP.managerRetryableException = const False,
         HTTP.managerIdleConnectionCount = 0,
         HTTP.managerResponseTimeout = HTTP.responseTimeoutMicro 15000000}
  -- ponytail: no idle pooling; add a scoped pool if handshake cost dominates.
  manager <- HTTP.newManager configured
  active <- newIORef True
  let pending = Client identity parsed manager credentials (fingerprint bearer) "" Null active
  location <- either throwIO pure (reference pending "/v1/capabilities")
  capabilities <- getJSON pending location >>= requireCapabilities
  pure (Client identity parsed manager credentials (fingerprint bearer)
    (capabilityEpoch capabilities) capabilities active)

-- | Refuse further work and discard late results. The caller joins its request
-- tasks, whose withResponse scopes close their non-pooled connections.
closeClient :: Client -> IO ()
closeClient (Client _ _ _ _ _ _ _ active) = writeIORef active False

clientCapabilities :: Client -> Value
clientCapabilities (Client _ _ _ _ _ _ value _) = value

reference :: Client -> Text -> Either ClientFailure Reference
reference (Client identity _ _ _ _ _ _ _) uri
  | validResource uri = Right (Reference identity uri)
  | otherwise = Left InvalidEndpoint

referenceURI :: Reference -> Text
referenceURI (Reference _ uri) = uri

getResource :: Client -> Reference -> IO (Either ClientFailure ClientResponse)
getResource client location = clientIO (getJSON client location)

-- | One complete immutable public collection, never a partial page installation.
data PageSet = PageSet {pageSetMetadata :: !Value, pageSetItems :: ![Value]}

data PageInfo = PageInfo
  { pageIdentity :: !Text, pageRevision :: !Text, pageExpiryText :: !Text,
    pageExpiry :: !UTCTime, pageIndex :: !Int, pageTotal :: !Int, pageNext :: !(Maybe Reference) }

parseClientValue :: (Value -> Parser a) -> Value -> IO a
parseClientValue parser = either (const (throwIO InvalidResponse)) pure . parseEither parser

parsePage :: Client -> Value -> Parser PageInfo
parsePage client = withObject "page" $ \fields -> do
  unless (KM.size fields == 6 && all (`KM.member` fields) ["setId","revision","expiresAt","index","totalItems","next"])
    (fail "page fields")
  ident <- fields .: "setId"
  revision <- fields .: "revision"
  expiryText <- fields .: "expiresAt"
  unless (validId ident && validId revision && T.length expiryText <= 40) (fail "page identity")
  expiry <- maybe (fail "page expiry") pure (iso8601ParseM (T.unpack (T.toUpper expiryText)) :: Maybe UTCTime)
  index <- fields .: "index"
  total <- fields .: "totalItems"
  unless (index >= 0 && index <= 65535 && total >= 0 && total <= 1048576) (fail "page bounds")
  nextText <- fields .: "next" :: Parser (Maybe Text)
  next <- traverse (either (const (fail "page link")) pure . reference client) nextText
  pure (PageInfo ident revision expiryText expiry index total next)

pageScope :: Reference -> Maybe (BS.ByteString, HTTP.Query)
pageScope location = do
  let (path,query) = BS.break (==63) (TE.encodeUtf8 (referenceURI location))
      pairs = HTTP.parseQuery query
      names = map fst pairs
  guard (length names == length (nub names))
  pure (path,sort (filter ((/= "pageToken") . fst) pairs))

-- | Fetch and validate one set serially, under the original session and credential.
-- Count actual wire bytes. Failure discards the set and never returns partial data.
getPageSet :: Client -> Reference -> IO (Either ClientFailure PageSet)
getPageSet client first = clientIO (collect Nothing Nothing 0 0 0 [] first)
  where
    collect stamp metadata index count charged chunks location = do
      unless (pageScope first /= Nothing && pageScope first == pageScope location) (throwIO InvalidResponse)
      response <- getJSON client location
      unless (responseStatus response == 200) (throwIO InvalidResponse)
      fields <- parseClientValue (withObject "paged resource" pure) (responseValue response)
      page <- parseClientValue (withObject "paged resource" (\value -> value .: "page" >>= parsePage client))
        (responseValue response)
      items <- parseClientValue (withObject "paged resource" (\value -> value .: "items" :: Parser [Value]))
        (responseValue response)
      now <- getCurrentTime
      let identity = (pageIdentity page,pageRevision page,pageExpiryText page,pageTotal page)
          repeated = Object (KM.delete "page" (KM.delete "items" fields))
          total = count + length items
          used = charged + responseBodyBytes response
      unless (pageIndex page == index && now < pageExpiry page && length items <= 256
        && total <= pageTotal page && used <= 67108864
        && maybe True (== identity) stamp && maybe True (== repeated) metadata) (throwIO InvalidResponse)
      case pageNext page of
        Nothing -> do
          unless (total == pageTotal page) (throwIO InvalidResponse)
          pure (PageSet repeated (concat (reverse (items:chunks))))
        Just next -> do
          unless (not (null items) && total < pageTotal page && index < 65535) (throwIO InvalidResponse)
          collect (Just identity) (Just repeated) (index+1) total used (items:chunks) next

-- | One successful GET and its exact-URI validator in the original client session.
-- Overview values and mutation receipts cannot construct this binding.
data Observed = Observed !Reference !Text !Value

observedReference :: Observed -> Reference
observedReference (Observed location _ _) = location

observedETag :: Observed -> Text
observedETag (Observed _ etag _) = etag

observedValue :: Observed -> Value
observedValue (Observed _ _ value) = value

observeResource :: Client -> Reference -> IO (Either ClientFailure Observed)
observeResource client location = clientIO $ do
  response <- getJSON client location
  unless (responseStatus response == 200) (throwIO InvalidResponse)
  etag <- maybe (throwIO InvalidResponse) pure (responseETag response)
  pure (Observed location etag (responseValue response))

prepareObserved :: Client -> Observed -> Value -> IO (Either ClientFailure PendingCommand)
prepareObserved client (Observed location etag _) = prepareCommand client location (Just etag)

pollEvents :: Client -> Text -> IO (Either ClientFailure ClientResponse)
pollEvents client cursor = clientIO $ do
  unless (validCursor cursor) (throwIO InvalidResponse)
  location <- either throwIO pure (reference client "/v1/events")
  exchangeJSON client location "GET" [("Last-Event-ID",TE.encodeUtf8 cursor)] (HTTP.RequestBodyBS BS.empty)

validCursor :: Text -> Bool
validCursor value = case T.splitOn "." value of
  [stream,number] -> validId stream && not (T.null number) && T.length number <= 20
    && T.all (\c -> c >= '0' && c <= '9') number
    && (number == "0" || T.take 1 number /= "0")
    && T.foldl' (\n c -> 10 * n + toInteger (fromEnum c - fromEnum '0')) 0 number <= 18446744073709551615
  _ -> False

prepareCommand :: Client -> Reference -> Maybe Text -> Value -> IO (Either ClientFailure PendingCommand)
prepareCommand client@(Client _ _ _ _ _ epoch _ _) location precondition value = clientIO $ do
  checkReference client location
  checkActive client
  unless (validId epoch && T.length epoch <= 105) (throwIO UnsupportedVersion)
  let bytes = encoded value
  when (BS.length bytes > 2097152) (throwIO ResponseTooLarge)
  either (const (throwIO InvalidResponse)) (const (pure ())) (decodeStrictValue bytes)
  header <- traverse checkedETag precondition
  nonce <- getRandomBytes 16 :: IO BS.ByteString
  let key = TE.encodeUtf8 epoch <> "." <> convertToBase Base64URLUnpadded nonce
  when (BS.length key > 128) (throwIO InvalidResponse)
  pure (PendingCommand location key header bytes)

-- | One HTTP attempt using the retained exact bytes. Failure returns to the caller.
-- Neither redirects nor a dropped response cause another request here.
sendCommand :: Client -> PendingCommand -> IO (Either ClientFailure ClientResponse)
sendCommand client (PendingCommand location key condition bytes) = clientIO $
  exchangeJSON client location "POST"
    ([ ("Content-Type","application/json"),("Idempotency-Key",key)]
      <> maybe [] (\value -> [("If-Match",value)]) condition) (HTTP.RequestBodyBS bytes)

getJSON :: Client -> Reference -> IO ClientResponse
getJSON client location = exchangeJSON client location "GET" [] (HTTP.RequestBodyBS BS.empty)

exchangeJSON :: Client -> Reference -> HTTP.Method -> HTTP.RequestHeaders -> HTTP.RequestBody -> IO ClientResponse
exchangeJSON client location method headers body = do
  (status, returnedHeaders, bytes) <- exchange client location method
    (("Accept","application/json"):headers) body 1048576
  let media = fmap (BC.takeWhile (/= ';')) (lookup "Content-Type" returnedHeaders)
      expectedMedia = if status >= 200 && status < 300 then "application/json" else "application/problem+json"
  unless (media == Just expectedMedia && lookup "Cache-Control" returnedHeaders == Just "no-store") (throwIO InvalidResponse)
  value <- either (const (throwIO InvalidResponse)) pure (decodeStrictValue bytes)
  unless (status >= 200 && status < 300) (throwIO (publicRefusal status value))
  case value of
    Object fields | KM.lookup "version" fields == Just (Number 1) -> pure ()
    _ -> throwIO UnsupportedVersion
  etag <- traverse (decodeText >=> checkedETagText) (lookup "ETag" returnedHeaders)
  target <- traverse (decodeText >=> either throwIO pure . reference client) (lookup "Location" returnedHeaders)
  pure (ClientResponse status value etag target (BS.length bytes))
  where
    checkedETagText value = checkedETag value >> pure value

-- | Verify exact downloaded bytes rather than reserializing a JSON value.
downloadVerified :: Client -> Reference -> Int -> Text -> IO (Either ClientFailure BS.ByteString)
downloadVerified client location size checksum = clientIO $ do
  unless (size >= 0 && size <= 67108864 && T.length checksum == 64
    && T.all (`elem` ("0123456789abcdef" :: String)) checksum) (throwIO InvalidResponse)
  (status, headers, bytes) <- exchange client location "GET" [("Accept","application/octet-stream")] (HTTP.RequestBodyBS BS.empty) 67108864
  unless (status == 200) $ do
    when (BS.length bytes > 1048576) (throwIO ResponseTooLarge)
    problem <- either (const (throwIO InvalidResponse)) pure (decodeStrictValue bytes)
    throwIO (publicRefusal status problem)
  unless (BS.length bytes == size
    && fmap (BC.takeWhile (/= ';')) (lookup "Content-Type" headers) == Just "application/octet-stream"
    && lookup "Cache-Control" headers == Just "no-store"
    && lookup "X-Content-Type-Options" headers == Just "nosniff"
    && maybe False ("attachment" `BS.isPrefixOf`) (lookup "Content-Disposition" headers)) (throwIO InvalidResponse)
  unless (T.pack (show (hash bytes :: Digest SHA256)) == checksum) (throwIO InvalidResponse)
  pure bytes

exchange :: Client -> Reference -> HTTP.Method -> HTTP.RequestHeaders -> HTTP.RequestBody -> Int
  -> IO (Int, HTTP.ResponseHeaders, BS.ByteString)
exchange client@(Client _ base manager credentials expected _ _ _) location method headers body limit = do
  checkReference client location
  checkActive client
  bearer <- readCredential credentials
  unless (BA.constEq (fingerprint bearer) expected) (throwIO CredentialChanged)
  let (path,query) = BS.break (== 63) (TE.encodeUtf8 (referenceURI location))
      request = base {HTTP.method=method, HTTP.path=path, HTTP.queryString=query,
        HTTP.requestHeaders = ("Authorization","Bearer " <> bearer):("Accept-Encoding","identity"):("Connection","close"):headers,
        HTTP.requestBody = body, HTTP.cookieJar = Nothing, HTTP.redirectCount = 0,
        HTTP.proxy = Nothing, HTTP.checkResponse = \_ _ -> pure (), HTTP.decompress = const False,
        HTTP.responseTimeout = HTTP.responseTimeoutMicro 15000000}
  HTTP.withResponse request manager $ \response -> do
    let status = HTTP.statusCode (HTTP.responseStatus response)
        received = HTTP.responseHeaders response
        unique name = length [() | (key,_) <- received, key == name] <= 1
    when (length received > 100 || sum [BS.length (CI.original name) + BS.length value + 4 | (name,value) <- received] > 16384)
      (throwIO ResponseTooLarge)
    unless (all unique ["Content-Type","Content-Length","Transfer-Encoding","Content-Encoding","ETag","Location","Cache-Control","Content-Disposition"])
      (throwIO InvalidResponse)
    when (lookup "Transfer-Encoding" received /= Nothing && lookup "Content-Length" received /= Nothing)
      (throwIO InvalidResponse)
    when (status >= 300 && status < 400) (throwIO RedirectRefused)
    when (lookup "Content-Encoding" received /= Nothing) (throwIO InvalidResponse)
    bytes <- consume limit [] (HTTP.responseBody response)
    currentBearer <- readCredential credentials
    unless (BA.constEq (fingerprint currentBearer) expected) (throwIO CredentialChanged)
    checkActive client
    pure (status,HTTP.responseHeaders response,bytes)
  where
    consume remaining chunks reader = do
      chunk <- HTTP.brRead reader
      if BS.null chunk then pure (BS.concat (reverse chunks)) else do
        when (BS.length chunk > remaining) (throwIO ResponseTooLarge)
        consume (remaining - BS.length chunk) (chunk:chunks) reader

checkReference :: Client -> Reference -> IO ()
checkReference (Client identity _ _ _ _ _ _ _) (Reference owner _) =
  unless (identity == owner) (throwIO WrongEndpoint)

checkActive :: Client -> IO ()
checkActive (Client _ _ _ _ _ _ _ active) = readIORef active >>= \open -> unless open (throwIO ClientClosed)

readCredential :: IO BS.ByteString -> IO BS.ByteString
readCredential readBytes = do
  outcome <- try @IOException readBytes
  bytes <- either (const (throwIO CredentialUnavailable)) pure outcome
  unless (BS.length bytes >= 32 && BS.length bytes <= 512
    && BS.all (\byte -> byte > 32 && byte < 127 && byte /= 44) bytes) (throwIO CredentialUnavailable)
  pure bytes

fingerprint :: BS.ByteString -> BS.ByteString
fingerprint bytes = BA.convert (hash bytes :: Digest SHA256)

checkedETag :: Text -> IO BS.ByteString
checkedETag value = do
  unless (T.length value >= 3 && T.length value <= 130 && T.head value == '"'
    && T.last value == '"' && validId (T.dropEnd 1 (T.drop 1 value))) (throwIO InvalidResponse)
  pure (TE.encodeUtf8 value)

decodeText :: BS.ByteString -> IO Text
decodeText = either (const (throwIO InvalidResponse)) pure . TE.decodeUtf8'

requireCapabilities :: ClientResponse -> IO Value
requireCapabilities response = case responseValue response of
  value@(Object fields) -> do
    unless (responseStatus response == 200 && KM.size fields == 8 && all (`KM.member` fields)
      ["version","authorityEpoch","streamId","versions","scopes","profileIds","transports","limits"])
      (throwIO InvalidResponse)
    versions <- maybe (throwIO UnsupportedVersion) pure (KM.lookup "versions" fields)
    either (const (throwIO UnsupportedVersion)) pure (parseEither checkVersions versions)
    either (const (throwIO InvalidResponse)) pure (parseEither checkCapabilities value)
    pure value
  _ -> throwIO InvalidResponse

checkVersions :: Value -> Parser ()
checkVersions = withObject "versions" $ \fields -> do
  let numeric :: [(Key.Key,[Int])]
      numeric = [("api",[1]),("snapshot",[1]),("event",[1]),("descriptor",[2,3]),
        ("frontendSession",[1,2]),("control",[1,2]),("runtimeProtocol",[1,2,3]),
        ("runtimeStore",[1,2]),("managerStore",[1..12]),("invocation",[1])]
  unless (KM.size fields == 11 && all (`KM.member` fields) ("frontendManifest":map fst numeric))
    (fail "version fields")
  forM_ numeric $ \(name,supported) -> do
    values <- fields .: name :: Parser [Int]
    unless (not (null values) && length values == length (nub values) && all (`elem` supported) values)
      (fail "unsupported version")
  manifests <- fields .: "frontendManifest" :: Parser [Text]
  unless (not (null manifests) && length manifests == length (nub manifests)
    && all (`elem` ["legacy","2","3"]) manifests) (fail "unsupported manifest")

checkCapabilities :: Value -> Parser ()
checkCapabilities = withObject "capabilities" $ \fields -> do
  version <- fields .: "version" :: Parser Int
  epoch <- fields .: "authorityEpoch"
  stream <- fields .: "streamId"
  scopes <- fields .: "scopes" :: Parser [Text]
  profiles <- fields .: "profileIds" :: Parser [Text]
  transports <- fields .: "transports" :: Parser [Text]
  unless (version == 1 && validId epoch && T.length epoch <= 105 && validId stream
    && length scopes <= 4 && length scopes == length (nub scopes)
    && all (`elem` ["observe","submit","control","export"]) scopes
    && length profiles <= 256 && all validId profiles && length profiles == length (nub profiles)
    && length transports == 2 && length (nub transports) == 2 && all (`elem` ["sse","polling"]) transports)
    (fail "capability facts")
  limits <- fields .: "limits"
  checkLimits limits

checkLimits :: Value -> Parser ()
checkLimits = withObject "limits" $ \fields -> do
  let fixed :: [(Key.Key,Integer)]
      fixed = [("requestTargetBytes",8192),("headerBytes",16384),("headerFields",100),
        ("jsonBodyBytes",2097152),("jsonDepth",64),("nativeControlBytes",1048576),
        ("captureBytes",67108864),("aggregateInputBytes",67108864),("artifactBytes",67108864),
        ("sseBlockBytes",16384),("pageBytes",1048576),("pageSetBytes",67108864),
        ("pageSetsPerClient",2),("pageSetLifetimeSeconds",60),("queuedRequests",100),
        ("maxReservations",16),("reviewLifetimeSeconds",600),("sseReadersPerClient",2),
        ("ssePendingBytesPerReader",1048576),("replaySeconds",604800),("replayBytes",268435456),
        ("heartbeatSeconds",15),("reconnectIdleSeconds",45),("reconnectBackoffMaxSeconds",30),
        ("ordinaryMutationsPerMinute",30)]
      configurable = [(name,2147483647) | name <- ["drafts","globalDrafts","globalCaptureBytes",
        "globalPageSets","globalConnections","globalDatabaseReaders","globalMutationLedgerBytes","safetyControlsPerMinute"]]
        <> [("executionReservations",16)]
  unless (KM.size fields == length fixed + length configurable
    && all (`KM.member` fields) (map fst (fixed <> configurable))) (fail "limit fields")
  forM_ fixed $ \(name,expected) -> do
    value <- fields .: name
    unless (value == expected) (fail "fixed limit")
  forM_ configurable $ \(name,maximumValue) -> do
    value <- fields .: name
    unless (value > 0 && value <= maximumValue) (fail "configured limit")

capabilityEpoch :: Value -> Text
capabilityEpoch (Object fields) = case KM.lookup "authorityEpoch" fields of Just (String value) -> value; _ -> ""
capabilityEpoch _ = ""

publicRefusal :: Int -> Value -> ClientFailure
publicRefusal status (Object fields) = case (KM.lookup "status" fields,KM.lookup "code" fields) of
  (Just (Number number),Just (String code)) | number == fromIntegral status
    && validId code && T.length code <= 128 -> Refused status code
  _ -> InvalidResponse
publicRefusal _ _ = InvalidResponse

clientIO :: IO a -> IO (Either ClientFailure a)
clientIO action = do
  outcome <- try @HTTP.HttpException (try @ClientFailure action)
  pure (either (const (Left TransportUnavailable)) id outcome)
