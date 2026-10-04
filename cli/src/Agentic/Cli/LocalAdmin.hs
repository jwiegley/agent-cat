{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | Frozen stdin administration through the selected local authority, and the
-- two commands that build on it: @--manager init@, which creates a manager
-- root with its configuration pair, listener certificate and first client
-- profile, and @--manager add-client@, which issues one more client
-- credential and writes its client profile.
module Agentic.Cli.LocalAdmin (runLocalAdmin, initManager, addClient, configurationNote) where

import Agentic.Manager.Configuration
import Agentic.Manager.LocalAdmin (administerLocally, backupStopped, callLocalAdministration, offlineAdministration, restoreStopped)
import Agentic.Manager.Profile (Diagnostic (UnreadableConfiguration), publicId, publicRevision)
import Agentic.Manager.Protocol.LocalAdmin
import Agentic.Manager.Quarantine (unavailableStoreCheck)
import Agentic.Manager.Store (CoordinationStore, StoreFailure, withCoordinationStore)
import Control.Exception (IOException, bracket, finally, throwIO, try)
import Control.Monad (filterM, forM_, unless)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Aeson (Value (..), eitherDecodeStrict', encode, object, (.=))
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.List (inits)
import Data.Maybe (listToMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Text.IO as TIO
import Paths_agentic (getDataFileName)
import System.Directory (canonicalizePath, createDirectory, doesDirectoryExist, doesPathExist, listDirectory, removeFile)
import System.Exit (ExitCode (..), exitFailure, exitSuccess)
import System.FilePath (dropExtension, isAbsolute, joinPath, splitDirectories, takeBaseName, takeExtension, (</>))
import System.IO (hClose, stderr, stdin, stdout)
import System.Posix.Files (createSymbolicLink, getSymbolicLinkStatus, isSymbolicLink, setFileMode)
import System.Posix.IO (OpenFileFlags (creat, exclusive), OpenMode (WriteOnly), defaultFileFlags, fdToHandle, openFd)
import System.Process (proc, readCreateProcessWithExitCode)

-- | A loader of manager configuration files.
type Load = FilePath -> IO (Either Diagnostic Configuration)

-- A configured channel is authoritative even when unavailable. Only omission
-- selects offline ownership, including the normal restart reconciliation.
-- Offline reload-profiles validates the given file through the loader and answers
-- before the configuration lease and the Store are acquired. Offline drain
-- has no serving lifetime to drain and refuses at the same point. Offline
-- shutdown acquires the configuration lease, which proves that no manager
-- serves the configuration, and answers that the manager is stopped without
-- opening the Store, so it changes nothing. A live manager refuses backup.
-- Offline backup holds the configuration lease and copies the Store through
-- its copying lifetime, so it neither reconciles a restart nor goes through
-- the dispatch of the other operations. Offline restore does the same: it
-- holds the configuration lease, compares the fencing evidence with the
-- identities of the stopped Store and replaces the Store from the backup. A
-- live manager refuses restore. The JSON answer goes to standard output. A
-- refusal whose cause the operator can act on also writes one line that
-- names that cause to standard error.
runLocalAdmin :: Load -> FilePath -> IO ()
runLocalAdmin load path = do
  input <- try @IOException (BS.hGet stdin 2097153)
  (output, note) <- case input of
    Left _ -> pure (adminError Nothing MalformedRequest, Nothing)
    Right bytes -> administer load path bytes
  forM_ note $ \line -> TIO.hPutStrLn stderr ("manager admin: " <> line)
  BS.hPut stdout (output <> "\n")
  if answeredOk output then exitSuccess else exitFailure

-- | One request through the selected local authority: the frozen JSON answer
-- and, for a refusal whose cause the operator can act on, a line that names
-- that cause. The line never changes the answer.
administer :: Load -> FilePath -> BS.ByteString -> IO (BS.ByteString, Maybe Text)
administer load path bytes = case decodeLocalAdminRequest bytes of
  Left failure -> pure (adminError Nothing failure, Nothing)
  Right request -> do
    let refused failure note = pure (adminError (Just (adminOperation request)) failure, note)
    result <- try @IOException $ try @StoreFailure $ try @Diagnostic $ do
      if not (validLocalFile path)
        then refused MalformedRequest (Just "the --config file must be an absolute path")
        else do
          configuration <- load path
          case (request, configuration) of
            (ReloadProfiles, Left UnreadableConfiguration) -> configurationNote path UnreadableConfiguration >>= refused StorageUnavailable . Just
            (ReloadProfiles, Left problem) -> configurationNote path problem >>= refused StateConflict . Just
            (_, Left problem) -> configurationNote path problem >>= refused StorageUnavailable . Just
            (_, Right value) -> do
              live <- try @IOException (callLocalAdministration value bytes)
              case (live, request) of
                (Left _, _) -> refused StorageUnavailable (Just (noManager value))
                (Right (Just response), _) -> pure (response, profileNote value request response)
                (Right Nothing, ReloadProfiles) -> (\response -> (response, Nothing)) <$> validateOffline value
                (Right Nothing, Drain) -> refused StateConflict (Just "drain needs a serving manager; give the serve configuration")
                (Right Nothing, _) -> do
                  installed <- installConfiguration value
                  case (installed, request) of
                    (Left _, _) -> refused StorageUnavailable (Just offlineRefused)
                    (Right owner, Shutdown) -> closeConfiguration owner >> pure (stoppedManager, Nothing)
                    (Right owner, Backup destination) -> bracket (pure owner) closeConfiguration $ \active ->
                      (\response -> (response, Nothing)) <$> backupStopped active destination
                    (Right owner, Restore source evidence) -> bracket (pure owner) closeConfiguration $ \active ->
                      (\response -> (response, Nothing)) <$> restoreStopped active source evidence
                    (Right owner, _) -> bracket (pure owner) closeConfiguration $ \active -> do
                      response <- offline request (withCoordinationStore active)
                      pure (response, profileNote value request response)
    pure $ case result of
      Right (Right (Right answer)) -> answer
      _ -> (adminError (Just (adminOperation request)) StorageUnavailable, Nothing)
  where
    noManager value = "no manager serves on this administrationRoot ("
      <> maybe "" T.pack (configurationAdministrationRoot value)
      <> "); start one with --manager serve, or give the offline configuration when no manager serves"
    offlineRefused = "the offline configuration cannot take the manager root: a serving manager holds it,"
      <> " or a configured directory is missing or not private (mode 0700)"

-- | The line for a refused @issue-credential@ whose profile identifiers name
-- a profile that the configuration does not define.
profileNote :: Configuration -> LocalAdminRequest -> BS.ByteString -> Maybe Text
profileNote value request response = case request of
  IssueCredential _ _ profiles _ _ | not (answeredOk response) ->
    case filter (`notElem` configurationProfileIds value) profiles of
      [] -> Nothing
      unknown -> Just ("issue-credential: no configured profile has the id " <> T.intercalate ", " unknown)
  _ -> Nothing

-- | The cause of a refused configuration file, in one line. A path with a
-- symbolic-link component is named with that component, because the loader
-- follows no symbolic link and macOS reaches @/tmp@ and @/var@ through one.
configurationNote :: FilePath -> Diagnostic -> IO Text
configurationNote path problem = do
  linked <- symbolicLinkComponent path
  pure $ case (linked, problem) of
    (Just component, _) ->
      "the configuration path " <> T.pack path <> " has the symbolic-link component " <> T.pack component
        <> "; give the canonical path, which has none"
    (Nothing, UnreadableConfiguration) ->
      "the configuration file " <> T.pack path <> " cannot be read as a private file of this user:"
        <> " it must exist as a regular file that this user owns, with mode 0600"
    (Nothing, _) -> "the configuration file " <> T.pack path <> " is not a valid manager configuration (see manager/CONFIGURATION.md)"

-- | The first component of an absolute path that is a symbolic link.
symbolicLinkComponent :: FilePath -> IO (Maybe FilePath)
symbolicLinkComponent path = listToMaybe <$> filterM linked prefixes
  where
    prefixes = map joinPath (drop 2 (inits (splitDirectories path)))
    linked prefix = either (const False) isSymbolicLink <$> try @IOException (getSymbolicLinkStatus prefix)

answeredOk :: BS.ByteString -> Bool
answeredOk output = case eitherDecodeStrict' output of
  Right (Object fields) -> KM.lookup "ok" fields == Just (Bool True)
  _ -> False

-- | Offline @reload-profiles@: validate the profiles of the loaded file as an
-- installation would and answer their identifiers and the revision of the
-- validation registry. Nothing is installed.
validateOffline :: Configuration -> IO BS.ByteString
validateOffline value = do
  validated <- validateConfigurationProfiles value
  pure $ case validated of
    Left _ -> adminError (Just "reload-profiles") StateConflict
    Right profiles -> adminSuccess "reload-profiles" (reloadedProfiles [(publicId profile, publicRevision profile) | profile <- profiles])

-- | Offline administration on a Store that this process opens. A Store that
-- cannot be opened answers @check-store@ with integrity @unavailable@. Every
-- other failure keeps its existing mapping.
offline :: LocalAdminRequest -> ((CoordinationStore -> IO BS.ByteString) -> IO BS.ByteString) -> IO BS.ByteString
offline request open = do
  entered <- newIORef False
  result <- try @StoreFailure (open (\store -> writeIORef entered True >> fst <$> administerLocally offlineAdministration store request))
  opened <- readIORef entered
  case (request, result) of
    (_, Right response) -> pure response
    (CheckStore, Left _) | not opened -> pure unavailableStoreCheck
    (_, Left failure) -> throwIO failure

-- ---------------------------------------------------------------------------
-- Manager root creation and client provisioning
-- ---------------------------------------------------------------------------

-- | The placeholder root and port of the reference configuration pair.
placeholderRoot, placeholderPort :: Text
placeholderRoot = "/Users/OPERATOR/agent-cat"
placeholderPort = "8443"

-- | The scopes of a client credential that these commands issue: every scope,
-- because the client is a client of the operator.
clientScopes :: [Text]
clientScopes = ["observe", "submit", "control", "export"]

-- | Create a manager root at an absent or empty directory, for the runner at
-- the given executable path and the given HTTPS port on @127.0.0.1@. It
-- creates the directories @manager@, @admin@, @workspace@, @tls@, @bin@ and
-- @client@ with mode 0700, links @bin/agentic-run@ to the executable, writes
-- @serve.json@ and @offline.json@ from the reference pair with the canonical
-- root and the port, creates a self-signed certificate and its key with the
-- @openssl@ of @PATH@, validates the offline file, issues one credential for
-- every configured profile offline, and writes @client/profile.json@. Every
-- written file has mode 0600. The result is the lines that name the next
-- commands, or the refusal. A failure leaves the root as it is.
initManager :: Load -> FilePath -> FilePath -> Int -> IO (Either Text [Text])
initManager load executable requested port
  | not (isAbsolute requested) = pure (Left "--root must be an absolute directory")
  | port < 1 || port > 65535 = pure (Left "--port must be a port number from 1 to 65535")
  | otherwise = do
      present <- doesPathExist requested
      directory <- doesDirectoryExist requested
      contents <- if directory then listDirectory requested else pure []
      canonical <- canonicalizePath requested
      let socket = canonical </> "admin" </> "admin.sock"
      if present && (not directory || not (null contents))
        then pure (Left ("the root " <> T.pack requested <> " exists and is not an empty directory"))
        else if BS.length (TE.encodeUtf8 (T.pack socket)) > 103
        then pure (Left ("the root " <> T.pack canonical <> " is too long: the administration socket "
          <> T.pack socket <> " must fit in 103 bytes, the Unix socket address limit of macOS"))
        else do
          unless present (createDirectory requested)
          setFileMode requested 0o700
          root <- canonicalizePath requested
          forM_ ["manager", "admin", "workspace", "tls", "bin", "client"] $ \name -> do
            createDirectory (root </> name)
            setFileMode (root </> name) 0o700
          createSymbolicLink executable (root </> "bin" </> "agentic-run")
          let serveFile = root </> "serve.json"
              offlineFile = root </> "offline.json"
          forM_ [("manager-serve.json", serveFile), ("manager-offline.json", offlineFile)] $ \(reference, destination) -> do
            source <- getDataFileName ("doc/examples" </> reference)
            bytes <- BS.readFile source
            writePrivateFile destination (localize root port bytes)
          certified <- selfSignedCertificate (root </> "tls")
          case certified of
            Left problem -> pure (Left problem)
            Right () -> do
              (validated, validateNote) <- administer load offlineFile (requestBody ["operation" .= ("reload-profiles" :: Text)])
              if not (answeredOk validated)
                then pure (Left ("offline validation of " <> T.pack offlineFile <> " refused: " <> answerText validated <> noteText validateNote))
                else do
                  configuration <- load offlineFile
                  case configuration of
                    Left problem -> Left <$> configurationNote offlineFile problem
                    Right value -> do
                      let profileFile = root </> "client" </> "profile.json"
                      provisioned <- provision load offlineFile value "operator" (configurationProfileIds value) profileFile
                      pure $ case provisioned of
                        Left problem -> Left problem
                        Right () -> Right (nextCommands root serveFile offlineFile profileFile)

-- | Issue one credential for the given configured profiles through the
-- selected local authority of the configuration file, a serving manager's
-- channel when the file names an administration root, and write the client
-- profile beside the credential. The credential file is the profile file
-- with the extension @.credential@.
addClient :: Load -> FilePath -> FilePath -> [Text] -> IO (Either Text [Text])
addClient load configFile profileFile requested
  | not (isAbsolute configFile) = pure (Left "--config must be an absolute file")
  | not (isAbsolute profileFile) = pure (Left "--profile-file must be an absolute file")
  | otherwise = do
      exists <- doesPathExist profileFile
      if exists
        then pure (Left ("the client profile " <> T.pack profileFile <> " exists already"))
        else do
          configuration <- load configFile
          case configuration of
            Left problem -> Left <$> configurationNote configFile problem
            Right value -> do
              let configured = configurationProfileIds value
                  profiles = if null requested then configured else requested
              case filter (`notElem` configured) profiles of
                unknown@(_ : _) -> pure (Left ("no configured profile has the id " <> T.intercalate ", " unknown))
                [] -> do
                  provisioned <- provision load configFile value (T.pack (takeBaseName profileFile)) profiles profileFile
                  pure $ case provisioned of
                    Left problem -> Left problem
                    Right () -> Right (clientCommands profileFile)

-- | Issue the credential and write the client profile.
provision :: Load -> FilePath -> Configuration -> Text -> [Text] -> FilePath -> IO (Either Text ())
provision load configFile value label profiles profileFile = case configurationHttps value of
  Nothing -> pure (Left ("the configuration " <> T.pack configFile <> " has no https section"))
  Just https -> do
    let credentialFile = (if takeExtension profileFile == ".json" then dropExtension profileFile else profileFile) <> ".credential"
    (issued, note) <- administer load configFile $ requestBody
      [ "operation" .= ("issue-credential" :: Text), "label" .= label, "scopes" .= clientScopes,
        "profileIds" .= profiles, "expiresAt" .= ("2999-01-01T00:00:00Z" :: Text), "outputFile" .= credentialFile ]
    if not (answeredOk issued)
      then pure (Left ("issue-credential refused: " <> answerText issued <> noteText note))
      else do
        writePrivateFile profileFile $ BL.toStrict (encode (object
          [ "version" .= (1 :: Int), "endpoint" .= endpointOf https,
            "credentialFile" .= credentialFile, "caFile" .= httpsCertificateFile https ])) <> "\n"
        pure (Right ())
  where
    endpointOf https =
      let host = httpsHost https
          bracketed = if T.any (== ':') host then "[" <> host <> "]" else host
       in "https://" <> bracketed <> ":" <> T.pack (show (httpsPort https)) <> "/v1"

-- | A request body of the frozen administration protocol.
requestBody :: [(KM.Key, Value)] -> BS.ByteString
requestBody fields = BL.toStrict (encode (Object (KM.fromList (("version", Number 1) : fields))))

answerText :: BS.ByteString -> Text
answerText = TE.decodeUtf8With (\_ _ -> Just '?')

noteText :: Maybe Text -> Text
noteText = maybe "" (" " <>)

-- | The reference pair with the placeholder root replaced by the root and the
-- placeholder port, in @port@ and in @allowedHosts@, replaced by the port. The
-- root is written as the content of a JSON string.
localize :: FilePath -> Int -> BS.ByteString -> BS.ByteString
localize root port bytes =
  let escaped = T.dropEnd 1 (T.drop 1 (TE.decodeUtf8 (BL.toStrict (encode (T.pack root)))))
      text = TE.decodeUtf8 bytes
      rooted = T.replace placeholderRoot escaped text
      ported = T.replace ("\"port\": " <> placeholderPort) ("\"port\": " <> T.pack (show port))
        (T.replace ("127.0.0.1:" <> placeholderPort) ("127.0.0.1:" <> T.pack (show port)) rooted)
   in TE.encodeUtf8 ported

-- | A self-signed certificate for @127.0.0.1@ and its key, both with mode
-- 0600, made by the @openssl@ of @PATH@. The extensions come from a
-- configuration file, a form that both OpenSSL and LibreSSL accept, and the
-- configuration file is removed afterwards.
selfSignedCertificate :: FilePath -> IO (Either Text ())
selfSignedCertificate directory = do
  let settings = directory </> "openssl.cnf"
      certificate = directory </> "certificate.pem"
      key = directory </> "key.pem"
  writePrivateFile settings $ TE.encodeUtf8 $ T.unlines
    [ "[req]", "distinguished_name = subject", "x509_extensions = listener", "prompt = no",
      "[subject]", "CN = 127.0.0.1",
      "[listener]", "subjectKeyIdentifier = hash", "authorityKeyIdentifier = keyid:always,issuer",
      "basicConstraints = critical,CA:true", "subjectAltName = IP:127.0.0.1" ]
  outcome <- try @IOException $ readCreateProcessWithExitCode
    (proc "openssl" [ "req", "-x509", "-newkey", "rsa:2048", "-sha256", "-nodes", "-days", "3650",
                      "-config", settings, "-keyout", key, "-out", certificate ]) ""
  removeFile settings
  case outcome of
    Left failure -> pure (Left ("openssl could not run from PATH: " <> T.pack (show failure)))
    Right (ExitFailure code, _, errors) ->
      pure (Left ("openssl req exited with status " <> T.pack (show code) <> ": " <> T.strip (T.pack errors)))
    Right (ExitSuccess, _, _) -> do
      made <- and <$> mapM doesPathExist [certificate, key]
      if not made
        then pure (Left "openssl req wrote no certificate or no key")
        else do
          mapM_ (`setFileMode` 0o600) [certificate, key]
          pure (Right ())

-- | Create a new file with mode 0600 and write the bytes. An existing file is
-- refused.
writePrivateFile :: FilePath -> BS.ByteString -> IO ()
writePrivateFile path bytes = do
  descriptor <- openFd path WriteOnly defaultFileFlags {creat = Just 0o600, exclusive = True}
  handle <- fdToHandle descriptor
  BS.hPut handle bytes `finally` hClose handle

nextCommands :: FilePath -> FilePath -> FilePath -> FilePath -> [Text]
nextCommands root serveFile offlineFile profileFile =
  [ "created the manager root " <> T.pack root,
    "  serve configuration    " <> T.pack serveFile,
    "  offline configuration  " <> T.pack offlineFile,
    "  client profile         " <> T.pack profileFile,
    "",
    "Start the manager in the foreground (it prints the URL when it listens):",
    "  " <> runner <> " --manager serve --config " <> T.pack serveFile,
    "Ask for its status from another terminal:",
    "  printf '%s' '{\"version\": 1, \"operation\": \"status\"}' | " <> runner <> " --manager admin --config " <> T.pack serveFile,
    "Stop it:",
    "  printf '%s' '{\"version\": 1, \"operation\": \"shutdown\"}' | " <> runner <> " --manager admin --config " <> T.pack serveFile
  ] <> clientCommands profileFile
  where
    runner = T.pack (root </> "bin" </> "agentic-run")

clientCommands :: FilePath -> [Text]
clientCommands profileFile =
  [ "Connect a client with the client profile " <> T.pack profileFile <> ":",
    "  TUI:   agentic-run --tui --service " <> T.pack profileFile,
    "  Pi:    AGENT_CAT_MANAGER_PROFILE=" <> T.pack profileFile <> " pi -e AGENT_CAT_CHECKOUT/ext-pi/src/index.ts",
    "  Emacs: (setq wf-manager-profiles '(\"" <> T.pack profileFile <> "\")), then M-x wf-service"
  ]
