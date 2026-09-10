{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module Main (main) where

import Agentic.Runtime (assertPrivateRoot, closePrivateRoot, openPrivateRoot)
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (cancel, withAsync)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar, tryReadMVar)
import Control.Exception (IOException, bracket, finally, try)
import Control.Monad (forever, unless)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Builder as Builder
import Data.IORef (atomicModifyIORef', newIORef)
import Data.Text (Text)
import qualified Data.Text as T
import Data.X509.CertificateStore (readCertificateStore)
import qualified Database.SQLite3 as SQL
import Network.Connection (TLSSettings (TLSSettings))
import qualified Network.HTTP.Client as HTTP
import Network.HTTP.Client.TLS (mkManagerSettings, tlsManagerSettings)
import qualified Network.Socket as Socket
import Network.TLS (ClientParams (clientShared), Shared (sharedCAStore), Version (TLS13), defaultParamsClient)
import Network.HTTP.Types (status200, status413)
import qualified Network.Wai as Wai
import qualified Network.Wai.Handler.Warp as Warp
import qualified Network.Wai.Handler.WarpTLS as WarpTLS
import System.Directory (createDirectory, listDirectory, renameDirectory)
import System.Environment (getArgs)
import System.Exit (ExitCode (ExitSuccess), die)
import System.FilePath ((</>))
import System.Posix.Files (createSymbolicLink, setFileMode)
import System.Process (readProcessWithExitCode)
import System.Timeout (timeout)
import Text.Read (readMaybe)

main :: IO ()
main = getArgs >>= \case
  [root] -> sqliteChecks root >> httpChecks >> tlsChecks root
  _ -> die "usage: manager-dependency-probe PRIVATE_FIXTURE_DIRECTORY"

check :: String -> Bool -> IO ()
check label holds = unless holds (die ("FAIL: " <> label)) >> putStrLn ("ok: " <> label)

openDatabase :: FilePath -> IO SQL.Database
openDatabase path = SQL.open2 (T.pack path)
  [SQL.SQLOpenReadWrite, SQL.SQLOpenCreate, SQL.SQLOpenFullMutex, SQL.SQLOpenNoFollow]
  SQL.SQLVFSDefault

rows :: SQL.Database -> Text -> IO [[SQL.SQLData]]
rows database query = bracket (SQL.prepare database query) SQL.finalize $ \statement ->
  let collect = SQL.step statement >>= \case
        SQL.Done -> pure []
        SQL.Row -> (:) <$> SQL.columns statement <*> collect
   in collect

sqliteChecks :: FilePath -> IO ()
sqliteChecks root = do
  let path = root </> "state.sqlite"
  bracket (openDatabase path) SQL.close $ \writer -> do
    version <- rows writer "SELECT sqlite_version()"
    let fixed = case version of
          [[SQL.SQLText value]] -> case map (readMaybe . T.unpack) (T.splitOn "." value) of
            [Just major, Just minor, Just patch] -> (major, minor, patch) >= ((3, 51, 3) :: (Int, Int, Int))
            _ -> False
          _ -> False
    check ("linked SQLite has the WAL-reset fix: " <> show version) fixed
    wal <- rows writer "PRAGMA journal_mode=WAL"
    check "WAL activation is verified rather than assumed" (wal == [[SQL.SQLText "wal"]])
    SQL.exec writer "PRAGMA synchronous=FULL"
    synchronous <- rows writer "PRAGMA synchronous"
    check "FULL synchronization is active" (synchronous == [[SQL.SQLInteger 2]])
    SQL.exec writer "CREATE TABLE items (id INTEGER PRIMARY KEY, value TEXT NOT NULL)"
    bracket (SQL.prepare writer "INSERT INTO items VALUES (?, ?)") SQL.finalize $ \statement -> do
      SQL.bind statement [SQL.SQLInteger 1, SQL.SQLText "α雪\r\n"]
      result <- SQL.step statement
      check "bound values execute without SQL interpolation" (result == SQL.Done)
    initial <- rows writer "SELECT id, value FROM items ORDER BY id"
    check "Unicode and CRLF values survive binding" (initial == [[SQL.SQLInteger 1, SQL.SQLText "α雪\r\n"]])
    SQL.exec writer "BEGIN IMMEDIATE"
    SQL.exec writer "INSERT INTO items VALUES (2, 'uncommitted')"
    refused <- try @SQL.SQLError (SQL.exec writer "INSERT INTO items VALUES (1, 'duplicate')")
    check "constraint failure is observable" (case refused of Left _ -> True; Right _ -> False)
    SQL.exec writer "ROLLBACK"
    rolledBack <- rows writer "SELECT id, value FROM items ORDER BY id"
    check "rollback removes the entire failed transaction" (rolledBack == initial)
    bracket (openDatabase path) SQL.close $ \reader -> do
      SQL.exec reader "BEGIN"
      snapshot <- rows reader "SELECT id, value FROM items ORDER BY id"
      SQL.exec writer "BEGIN IMMEDIATE; INSERT INTO items VALUES (2, 'committed'); COMMIT"
      unchanged <- rows reader "SELECT id, value FROM items ORDER BY id"
      check "reader snapshot remains stable across writer commits" (snapshot == initial && unchanged == initial)
      SQL.exec reader "COMMIT"
      current <- rows reader "SELECT id, value FROM items ORDER BY id"
      check "a new reader transaction sees committed rows" (length current == 2)
    createSymbolicLink path (root </> "alias.sqlite")
    alias <- try @SQL.SQLError (bracket (openDatabase (root </> "alias.sqlite")) SQL.close (const (pure ())))
    check "NOFOLLOW refuses a database symlink" (case alias of Left _ -> True; Right _ -> False)
  let original = root </> "moving"
      retained = root </> "retained"
  createDirectory original
  setFileMode original 0o700
  bracket (openPrivateRoot "dependency probe database" original) closePrivateRoot $ \anchor ->
    bracket (openDatabase (original </> "state.sqlite")) SQL.close $ \database -> do
      _ <- rows database "PRAGMA journal_mode=WAL"
      SQL.exec database "CREATE TABLE values_ (id INTEGER); INSERT INTO values_ VALUES (1)"
      renameDirectory original retained
      createDirectory original
      setFileMode original 0o700
      BS.writeFile (original </> "sentinel") "unchanged"
      result <- try @IOException (assertPrivateRoot anchor >> SQL.exec database "INSERT INTO values_ VALUES (2)")
      entries <- listDirectory original
      sentinel <- BS.readFile (original </> "sentinel")
      retainedRows <- rows database "SELECT id FROM values_"
      check "retained-root validation refuses replacement before SQLite writes" $
        case result of
          Left _ -> entries == ["sentinel"] && sentinel == "unchanged" && retainedRows == [[SQL.SQLInteger 1]]
          Right _ -> False

tlsChecks :: FilePath -> IO ()
tlsChecks root = do
  let certificate = root </> "certificate.pem"
      key = root </> "key.pem"
  (status, _, diagnostic) <- readProcessWithExitCode "openssl"
    [ "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256",
      "-keyout", key, "-out", certificate, "-days", "1",
      "-subj", "/CN=127.0.0.1", "-addext", "subjectAltName=IP:127.0.0.1",
      "-addext", "basicConstraints=critical,CA:TRUE",
      "-addext", "keyUsage=critical,digitalSignature,keyEncipherment,keyCertSign",
      "-addext", "extendedKeyUsage=serverAuth"
    ] ""
  unless (status == ExitSuccess) (die ("TLS certificate fixture failed: " <> diagnostic))
  store <- readCertificateStore certificate >>= maybe (die "cannot read fixture CA") pure
  let defaults = defaultParamsClient "127.0.0.1" ""
      parameters = defaults {clientShared = (clientShared defaults) {sharedCAStore = store}}
  trusted <- HTTP.newManager (mkManagerSettings (TLSSettings parameters) Nothing)
  untrusted <- HTTP.newManager tlsManagerSettings
  ready <- newEmptyMVar
  bracket (Socket.socket Socket.AF_INET Socket.Stream Socket.defaultProtocol) Socket.close $ \socket -> do
    Socket.bind socket (Socket.SockAddrInet 0 (Socket.tupleToHostAddress (127, 0, 0, 1)))
    Socket.listen socket 8
    port <- Socket.getSocketName socket >>= \case
      Socket.SockAddrInet value _ -> pure value
      _ -> die "TLS fixture did not bind IPv4 loopback"
    let settings = Warp.setBeforeMainLoop (putMVar ready ()) $ Warp.setTimeout 2 $
          Warp.setGracefulShutdownTimeout (Just 1) Warp.defaultSettings
        transport = (WarpTLS.tlsSettings certificate key)
          { WarpTLS.onInsecure = WarpTLS.DenyInsecure "HTTPS required",
            WarpTLS.tlsAllowedVersions = [TLS13]
          }
        application _ respond = respond (Wai.responseLBS status200 [] "tls fixture")
    withAsync (WarpTLS.runTLSSocket transport settings socket application) $ \_ -> do
      listening <- timeout 5000000 (takeMVar ready)
      check "TLS server startup is bounded" (listening == Just ())
      request <- HTTP.parseRequest ("https://127.0.0.1:" <> show port <> "/")
      rejected <- try @HTTP.HttpException (HTTP.httpLbs request untrusted)
      check "the standard client rejects the untrusted fixture certificate" (case rejected of Left _ -> True; Right _ -> False)
      response <- HTTP.httpLbs request trusted
      check "Warp TLS 1.3 serves a certificate-validated client" (HTTP.responseStatus response == status200 && HTTP.responseBody response == "tls fixture")
      plain <- HTTP.parseRequest ("http://127.0.0.1:" <> show port <> "/")
      refused <- try @HTTP.HttpException (HTTP.httpLbs plain trusted)
      check "the TLS listener refuses plaintext HTTP" (case refused of Left _ -> True; Right reply -> HTTP.responseStatus reply /= status200)

httpChecks :: IO ()
httpChecks = do
  started <- newEmptyMVar
  stopped <- newEmptyMVar
  received <- newEmptyMVar
  consumed <- newEmptyMVar
  let expected = "data: ready\n\n"
      application request respond
        | Wai.rawPathInfo request == "/stream" =
            respond (Wai.responseStream status200 [("Content-Type", "text/event-stream")] $ \write flush ->
              (do
                  mapM_ (\byte -> write (Builder.word8 byte) >> flush >> takeMVar consumed) (BS.unpack expected)
                  putMVar started ()
                  forever (threadDelay 10000 >> write (Builder.byteString ": heartbeat\n\n") >> flush)
              ) `finally` putMVar stopped ())
        | otherwise = do
            accepted <- boundedBody 1024 request
            respond (Wai.responseLBS (if accepted then status200 else status413) [] "fixture")
      settings = Warp.setHost "127.0.0.1" $ Warp.setTimeout 2 $
        Warp.setGracefulShutdownTimeout (Just 1) Warp.defaultSettings
  Warp.withApplicationSettings settings (pure application) $ \port -> do
    manager <- HTTP.newManager HTTP.defaultManagerSettings
    base <- HTTP.parseRequest ("http://127.0.0.1:" <> show port <> "/body")
    small <- HTTP.httpLbs (base {HTTP.method = "POST", HTTP.requestBody = HTTP.RequestBodyBS "small"}) manager
    check "WAI receives bounded request bytes" (HTTP.responseStatus small == status200)
    let chunked = HTTP.RequestBodyStreamChunked $ \consume -> do
          chunks <- newIORef (replicate 6 (BS.replicate 256 120))
          consume (atomicModifyIORef' chunks (\case [] -> ([], BS.empty); chunk : rest -> (rest, chunk)))
    large <- HTTP.httpLbs (base {HTTP.method = "POST", HTTP.requestBody = chunked}) manager
    check "incremental body accounting rejects an oversized chunked request" (HTTP.responseStatus large == status413)
    stream <- HTTP.parseRequest ("http://127.0.0.1:" <> show port <> "/stream")
    withAsync (HTTP.withResponse stream manager $ \response -> do
        let readPrefix remaining
              | remaining == 0 = pure BS.empty
              | otherwise = do
                  chunk <- HTTP.brRead (HTTP.responseBody response)
                  unless (not (BS.null chunk)) (die "stream ended before its bounded prefix")
                  let part = BS.take remaining chunk
                  putMVar consumed ()
                  (part <>) <$> readPrefix (remaining - BS.length part)
        prefix <- readPrefix (BS.length expected)
        check "fragmented stream prefix is visible before the response completes" (prefix == expected)
        putMVar received ()
        forever (threadDelay 1000000)) $ \client -> do
      ready <- timeout 5000000 (takeMVar started >> takeMVar received)
      check "stream is active before cancellation" (ready == Just ())
      early <- tryReadMVar stopped
      check "stream has not completed before its client disconnects" (early == Nothing)
      cancel client
      finished <- timeout 5000000 (takeMVar stopped)
      check "client cancellation releases the streaming handler" (finished == Just ())
  where
    boundedBody remaining request = do
      chunk <- Wai.getRequestBodyChunk request
      if BS.null chunk
        then pure True
        else if BS.length chunk > remaining
          then pure False
          else boundedBody (remaining - BS.length chunk) request
