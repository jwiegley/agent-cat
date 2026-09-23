{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | Endpoint-bound observations and explicit HTTP attempts, never worker ownership.
module Agentic.Manager.Client
  ( Client, Reference, PendingCommand, ClientResponse (..), ClientFailure (..),
    connectClient, closeClient, clientCapabilities, reference, referenceURI,
    getResource, prepareCommand, sendCommand, downloadVerified
  ) where

import Agentic.Manager.Protocol.Command (validId, validResource, encoded)
import Agentic.Manager.Protocol.Json (decodeStrictValue)
import Control.Exception (Exception, IOException, throwIO, try)
import Control.Monad ((>=>), unless, when)
import Crypto.Hash (Digest, SHA256, hash)
import Crypto.Random (getRandomBytes)
import Data.Aeson (Value (..))
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteArray as BA
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Vector as V
import qualified Network.HTTP.Client as HTTP
import qualified Network.HTTP.Types as HTTP

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
    responseETag :: !(Maybe Text), responseLocation :: !(Maybe Reference)
  }

-- | Fixed local failures. Request headers and exception diagnostics are not retained.
data ClientFailure = ClientClosed | InvalidEndpoint | WrongEndpoint | CredentialUnavailable
  | CredentialChanged | TransportUnavailable | RedirectRefused | InvalidResponse
  | ResponseTooLarge | UnsupportedVersion | Refused !Int !Text
  deriving (Eq, Show)
instance Exception ClientFailure

-- | The composition root supplies verified TLS settings and a private byte reader.
-- Environment proxies, cookies, redirects and implicit transport retries are disabled.
connectClient :: HTTP.ManagerSettings -> Text -> IO BS.ByteString -> IO (Either ClientFailure Client)
connectClient settings endpoint credentials = clientIO $ do
  unless (T.length endpoint <= 8192 && "https://" `T.isPrefixOf` endpoint
    && not (T.any (\c -> c <= ' ' || c `elem` ("@?#\\" :: String)) endpoint)) (throwIO InvalidEndpoint)
  parsed <- HTTP.parseRequest (T.unpack endpoint)
  unless (HTTP.secure parsed && HTTP.path parsed `elem` ["/v1","/v1/"]
    && BS.null (HTTP.queryString parsed) && null (HTTP.requestHeaders parsed)) (throwIO InvalidEndpoint)
  bearer <- readCredential credentials
  nonce <- getRandomBytes 16 :: IO BS.ByteString
  let identity = TE.decodeUtf8 (convertToBase Base16 nonce)
      configured = HTTP.managerSetProxy HTTP.noProxy settings
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
  let key = TE.encodeUtf8 epoch <> "." <> convertToBase Base16 nonce
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
  unless (media `elem` [Just "application/json",Just "application/problem+json"]) (throwIO InvalidResponse)
  value <- either (const (throwIO InvalidResponse)) pure (decodeStrictValue bytes)
  unless (status >= 200 && status < 300) (throwIO (publicRefusal status value))
  case value of
    Object fields | KM.lookup "version" fields == Just (Number 1) -> pure ()
    _ -> throwIO UnsupportedVersion
  etag <- traverse (decodeText >=> checkedETagText) (lookup "ETag" returnedHeaders)
  target <- traverse (decodeText >=> either throwIO pure . reference client) (lookup "Location" returnedHeaders)
  pure (ClientResponse status value etag target)
  where
    checkedETagText value = checkedETag value >> pure value

-- | Verify exact downloaded bytes rather than reserializing a JSON value.
downloadVerified :: Client -> Reference -> Int -> Text -> IO (Either ClientFailure BS.ByteString)
downloadVerified client location size checksum = clientIO $ do
  unless (size >= 0 && size <= 67108864 && T.length checksum == 64
    && T.all (`elem` ("0123456789abcdef" :: String)) checksum) (throwIO InvalidResponse)
  (status, headers, bytes) <- exchange client location "GET" [] (HTTP.RequestBodyBS BS.empty) 67108864
  unless (status == 200 && BS.length bytes == size
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
    when (status >= 300 && status < 400) (throwIO RedirectRefused)
    when (lookup "Content-Encoding" (HTTP.responseHeaders response) /= Nothing) (throwIO InvalidResponse)
    bytes <- consume limit [] (HTTP.responseBody response)
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
    unless (KM.size fields == 8 && all (`KM.member` fields)
      ["version","authorityEpoch","streamId","versions","scopes","profileIds","transports","limits"])
      (throwIO InvalidResponse)
    case (KM.lookup "authorityEpoch" fields, KM.lookup "streamId" fields, KM.lookup "versions" fields) of
      (Just (String epoch),Just (String stream),Just (Object versions))
        | validId epoch && T.length epoch <= 105 && validId stream
        , all (\name -> KM.lookup name versions == Just (Array (V.singleton (Number 1)))) ["api","snapshot","event"] -> pure ()
      _ -> throwIO UnsupportedVersion
    pure value
  _ -> throwIO InvalidResponse

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
