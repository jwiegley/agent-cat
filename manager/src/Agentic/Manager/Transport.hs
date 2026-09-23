{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeApplications #-}

-- | A bounded authenticated HTTPS boundary around the existing coordinator.
module Agentic.Manager.Transport
  ( AuthenticatedApplication, runHttps, authenticated, readJsonRequest,
    respondJSON, respondBytes, problem, HttpFailure (..)
  ) where

import Agentic.Manager.Authorization (CredentialProof, authenticateCredential)
import Agentic.Manager.Configuration (HttpsConfiguration (..))
import Agentic.Manager.Profile (ConfigurationLimits (..))
import Agentic.Manager.Protocol.Command (CommandFailure (..), failureCode, failureStatus, encoded, validResource)
import Agentic.Manager.Protocol.Json (decodeStrictValue)
import Agentic.Manager.Store (CoordinationStore, StoreFailure)
import Agentic.Runtime (readPrivateConfigurationFile)
import Control.Concurrent (forkIOWithUnmask)
import Control.Concurrent.QSem (newQSem, waitQSem, signalQSem)
import Control.Exception
  (Exception, SomeException, SomeAsyncException, bracket, catch,
   finally, fromException, mask, onException, throwIO)
import Control.Monad (replicateM_, unless, void, when)
import Data.Aeson (Value, object, (.=))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Builder as Builder
import qualified Data.CaseInsensitive as CI
import Data.Char (toLower)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Network.HTTP.Types as HTTP
import qualified Network.Socket as Socket
import Network.TLS (Version (TLS13))
import qualified Network.Wai as Wai
import qualified Network.Wai.Handler.Warp as Warp
import qualified Network.Wai.Handler.WarpTLS as TLS
import System.Timeout (timeout)

-- | A request whose possession proof is current, not authority for any resource.
type AuthenticatedApplication = CredentialProof -> Wai.Application

-- | Fixed transport failures, with no retained request or diagnostic contents.
data HttpFailure = HttpFailure !Int !Text deriving (Show)
instance Exception HttpFailure

-- | Retain the original listener and a finite number of connection workers.
-- TLS is mandatory, including loopback. Peer addresses are numeric and explicit.
runHttps :: HttpsConfiguration -> ConfigurationLimits -> Wai.Application -> IO ()
runHttps configuration limits application = do
  certificate <- readPrivateConfigurationFile (httpsCertificateFile configuration) 1048576
  key <- readPrivateConfigurationFile (httpsKeyFile configuration) 1048576
  addresses <- numeric (httpsHost configuration) (httpsPort configuration)
  peers <- concat <$> mapM (\host -> numeric host 0) (httpsAllowedPeers configuration)
  address <- case addresses of value:_ -> pure value; [] -> throwIO (HttpFailure 503 "storage-unavailable")
  let capacity = limitGlobalConnections limits
  slots <- newQSem capacity
  let receive listener = mask $ \restore -> do
        waitQSem slots
        pair@(connection, remote) <- restore (Socket.accept listener) `onException` signalQSem slots
        if any (samePeer remote . Socket.addrAddress) peers then pure pair
          else Socket.close connection >> signalQSem slots >> restore (receive listener)
      fork :: ((forall a. IO a -> IO a) -> IO ()) -> IO ()
      fork worker = void (forkIOWithUnmask (\restore -> worker restore `finally` signalQSem slots))
        `onException` signalQSem slots
      settings = Warp.setAccept receive $ Warp.setFork fork $
        Warp.setMaxTotalHeaderLength 16384 $ Warp.setMaxBuilderResponseBufferSize 16384 $
        Warp.setMaximumBodyFlush (Just 0) $ Warp.setHTTP2Disabled $ Warp.setProxyProtocolNone $
        Warp.setTimeout 15 $ Warp.setGracefulShutdownTimeout (Just 15) $
        Warp.setOnException (\_ _ -> pure ()) $
        Warp.setOnExceptionResponse (\_ -> problem "/v1/capabilities" 400 "malformed-request") Warp.defaultSettings
      tls = (TLS.tlsSettingsMemory certificate key)
        { TLS.tlsAllowedVersions = [TLS13], TLS.onInsecure = TLS.DenyInsecure "HTTPS required" }
  (bracket (Socket.socket (Socket.addrFamily address) Socket.Stream Socket.defaultProtocol) Socket.close $ \listener -> do
    Socket.setSocketOption listener Socket.ReuseAddr 1
    Socket.bind listener (Socket.addrAddress address)
    Socket.listen listener (min 128 capacity)
    TLS.runTLSSocket tls settings listener application)
    `finally` replicateM_ capacity (waitQSem slots)
  where
    numeric :: Text -> Int -> IO [Socket.AddrInfo]
    numeric host port = Socket.getAddrInfo
      (Just Socket.defaultHints {Socket.addrFlags = [Socket.AI_NUMERICHOST,Socket.AI_NUMERICSERV],
        Socket.addrSocketType = Socket.Stream}) (Just (T.unpack host)) (Just (show port))
    samePeer (Socket.SockAddrInet _ a) (Socket.SockAddrInet _ b) = a == b
    samePeer (Socket.SockAddrInet6 _ _ a scopeA) (Socket.SockAddrInet6 _ _ b scopeB) = a == b && scopeA == scopeB
    samePeer _ _ = False

-- | Authenticate resource requests after bounded framing and exact origin checks.
-- Only policy-conforming preflight is unauthenticated, and it exposes no state.
authenticated :: HttpsConfiguration -> CoordinationStore
  -> ([Text] -> [HTTP.Method]) -> AuthenticatedApplication -> Wai.Application
authenticated configuration store methods application request respond = do
  started <- newIORef False
  let send response = writeIORef started True >> respond (withCors response)
  handle send `catch` \failure -> do
    sent <- readIORef started
    if sent then throwIO failure else case fromException failure :: Maybe SomeAsyncException of
      Just asynchronous -> throwIO asynchronous
      Nothing -> send (failureResponse failure)
  where
    headers = Wai.requestHeaders request
    path = Wai.pathInfo request
    method = Wai.requestMethod request
    origin = lookup "Origin" headers
    allowedOrigin = maybe True (`elem` map TE.encodeUtf8 (httpsAllowedOrigins configuration)) origin
    allowedMethods = methods path
    safeInstance = case TE.decodeUtf8' (Wai.rawPathInfo request) of
      Right value | validResource value -> value
      _ -> "/v1/capabilities"
    protected = [("Cache-Control","no-store"),("X-Content-Type-Options","nosniff"),("Vary","Origin")]
    withCors = Wai.mapResponseHeaders $ \old -> protected <>
      (case origin of
        Just value | allowedOrigin -> [("Access-Control-Allow-Origin",value),
          ("Access-Control-Expose-Headers","ETag, Location, Retry-After")]
        _ -> []) <> filter (\(name,_) -> name `notElem` map fst protected) old
    reject status code = throwIO (HttpFailure status code)
    unique name = length [() | (key,_) <- headers, key == name] <= 1
    handle send = do
      unless (Wai.isSecure request) (reject 400 "malformed-request")
      unless (Wai.rawPathInfo request == TE.encodeUtf8 ("/" <> T.intercalate "/" path))
        (reject 400 "malformed-request")
      when (any (\(name,_) -> BC.map toLower name `elem` ["token","access_token","authorization"])
        (Wai.queryString request)) (reject 400 "malformed-request")
      when (BS.length (Wai.rawPathInfo request) + BS.length (Wai.rawQueryString request) > 8192
        || length headers > 100 || sum [BS.length (CI.original name) + BS.length value + 4 | (name,value) <- headers] > 16384)
        (reject 413 "size-limit")
      unless (all unique ["Host","Authorization","Origin","Content-Type","Content-Length",
        "Transfer-Encoding","Idempotency-Key","If-Match","Access-Control-Request-Method","Access-Control-Request-Headers"])
        (reject 400 "malformed-request")
      let host = fmap (BC.map toLower) (lookup "Host" headers)
      unless (maybe False (`elem` map (BC.map toLower . TE.encodeUtf8) (httpsAllowedHosts configuration)) host)
        (reject 400 "malformed-request")
      when (any (\(name,_) -> name == "Cookie" || name == "Forwarded" ||
        "x-forwarded-" `BS.isPrefixOf` CI.foldedCase name) headers) (reject 400 "malformed-request")
      when (lookup "Content-Encoding" headers /= Nothing) (reject 415 "unsupported-media-type")
      when (lookup "Transfer-Encoding" headers /= Nothing && lookup "Content-Length" headers /= Nothing)
        (reject 400 "malformed-request")
      unless allowedOrigin (reject 403 "insufficient-scope")
      let bodyLimit = if path == ["v1","captures"] then 67108864 else 2097152
      case Wai.requestBodyLength request of
        Wai.KnownLength size | size > bodyLimit -> reject 413 "size-limit"
        _ -> pure ()
      if method == "OPTIONS" then preflight send else do
        bearer <- case lookup "Authorization" headers >>= BS.stripPrefix "Bearer " of
          Just value | BS.length value >= 32 && BS.length value <= 512
            && BS.all (\byte -> byte > 32 && byte < 127 && byte /= 44) value -> pure value
          _ -> reject 401 "unauthenticated"
        proof <- authenticateCredential store bearer >>= either throwIO pure
        if null allowedMethods then send (problem safeInstance 404 "unavailable-resource")
        else if method `elem` allowedMethods
          then application proof request send
          else send (Wai.responseLBS HTTP.status405 [("Allow",BC.intercalate ", " ("OPTIONS":allowedMethods))] "")
    preflight send = do
      requested <- maybe (reject 400 "malformed-request") pure (lookup "Access-Control-Request-Method" headers)
      unless (origin /= Nothing && requested `elem` allowedMethods) (reject 403 "insufficient-scope")
      let permitted = ["authorization","content-type","if-match","idempotency-key","last-event-id"]
          requestedHeaders = maybe [] (map (BC.map toLower . trim) . BC.split ',') (lookup "Access-Control-Request-Headers" headers)
      unless (all (`elem` permitted) requestedHeaders) (reject 403 "insufficient-scope")
      send (Wai.responseLBS HTTP.status204
        [("Access-Control-Allow-Methods",requested),
         ("Access-Control-Allow-Headers",BC.intercalate ", " requestedHeaders)] "")
    failureResponse :: SomeException -> Wai.Response
    failureResponse failure = case fromException failure of
      Just (HttpFailure status code) -> problem safeInstance status code
      Nothing -> case fromException failure of
        Just refusal -> problem safeInstance (failureStatus refusal) (failureCode refusal)
        Nothing -> case fromException failure :: Maybe StoreFailure of
          Just _ -> problem safeInstance 503 "storage-unavailable"
          Nothing -> problem safeInstance 503 "storage-unavailable"
    trim = BC.dropWhile (== ' ') . BC.dropWhileEnd (== ' ')

readJsonRequest :: Wai.Request -> IO BS.ByteString
readJsonRequest request = do
  unless (lookup "Content-Type" (Wai.requestHeaders request) == Just "application/json")
    (throwIO UnsupportedMediaType)
  received <- timeout 15000000 (readBounded 2097152)
  bytes <- maybe (throwIO (HttpFailure 400 "malformed-request")) pure received
  case decodeStrictValue bytes of
    Left "duplicate-field" -> throwIO (HttpFailure 400 "duplicate-field")
    Left _ -> throwIO InvalidRequest
    Right _ -> pure bytes
  where
    readBounded limit = go limit []
    go remaining chunks = do
      chunk <- Wai.getRequestBodyChunk request
      if BS.null chunk then pure (BS.concat (reverse chunks)) else do
        when (BS.length chunk > remaining) (throwIO SizeLimit)
        go (remaining - BS.length chunk) (chunk:chunks)

problem :: Text -> Int -> Text -> Wai.Response
problem instanceURI status code = Wai.responseLBS (HTTP.mkStatus status "Request refused")
  ([("Content-Type","application/problem+json"),("Cache-Control","no-store"),("X-Content-Type-Options","nosniff")]
    <> if status == 401 then [("WWW-Authenticate","Bearer")] else [])
  (Builder.toLazyByteString (Builder.byteString (encoded (object
    ["type" .= ("urn:agent-cat:manager:problem:" <> code), "title" .= ("Request refused" :: Text),
     "status" .= status, "instance" .= instanceURI, "code" .= code,
     "links" .= object ["snapshot" .= ("/v1/snapshot" :: Text)]]))))

respondJSON :: HTTP.Status -> HTTP.ResponseHeaders -> Value
  -> (Wai.Response -> IO Wai.ResponseReceived) -> IO Wai.ResponseReceived
respondJSON status headers value respond = do
  let bytes = encoded value
  when (BS.length bytes > 1048576) (throwIO ViewTooLarge)
  respondBytes status (("Content-Type","application/json"):headers) (pure ()) bytes respond

-- | Complete each bounded socket write while the caller retains response authority.
respondBytes :: HTTP.Status -> HTTP.ResponseHeaders -> IO () -> BS.ByteString
  -> (Wai.Response -> IO Wai.ResponseReceived) -> IO Wai.ResponseReceived
respondBytes status headers authorize bytes respond = respond $ Wai.responseStream status headers $ \write flush -> do
  let send chunk = do
        authorize
        outcome <- timeout 5000000 (write (Builder.byteString chunk) >> flush)
        maybe (throwIO (HttpFailure 503 "storage-unavailable")) pure outcome
      chunks value | BS.null value = pure ()
                   | otherwise = let (chunk,rest) = BS.splitAt 16384 value in send chunk >> chunks rest
  chunks bytes
