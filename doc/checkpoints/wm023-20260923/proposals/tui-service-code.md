# First manager-backed TUI path: code proposal

**Proposal only. No source edits, commands, tests, processes, Git operations, credential reads, or PTY interaction performed.** This report is the only written artifact.

The supervisor confirmed that `doc/api/openapi.yaml` is the frozen contract, including Workflow and OverviewSnapshot, despite its historical “proposed” wording. `/workflows` and complete `/snapshot` implementation remain parent-owned prerequisites. A missing route must fail, never select a local fallback.

## 1. Smallest owner-aligned change

Keep one Brick application. Keep `TuiConfig`, `runTui`, the local subprocess client, and local behavior intact.

Proposed source locations:

| Owner | Change |
|---|---|
| `manager/src/Agentic/Manager/Client.hs` | Operator client-profile loading, validated TLS, bound GET observations, complete page assembly, Last-Event-ID polling, transport hardening below. |
| `tui/src/Agentic/Tui/Service.hs` (new) | Public DTO parsers and observation adapters. Imports only `Agentic.Manager.Client` from manager. No execution or store APIs. |
| `tui/src/Agentic/Tui.hs` | Add `runServiceTui`. Keep `runTui` unchanged. |
| `tui/src/Agentic/Tui/App.hs` | Backend sum, existing worker slots extended for service reads/preparation/send/download, guarded results, backend-specific actions. |
| `tui/src/Agentic/Tui/Model.hs` | Three navigation states: profile selection, request waiting, service review. Reuse workflow filtering/input collection and live snapshot selection. |
| `tui/src/Agentic/Tui/Presentation.hs` | Service profile list and exact review inside existing shell. Reuse person, recovery, occurrence/output panes. Add verified-byte result metadata. |
| `cli/src/Agentic/Cli.hs` | Parse and dispatch `--tui --service ABS_CLIENT_PROFILE` and `--tui --local`. No frontend execution logic. |
| `agentic.cabal`, existing test owners | Register Service, expose already-installed TLS dependencies to library, add focused checks. |

Do not put service execution in `Agentic.Tui.Client`: its present owner is bounded subprocess discovery (`loadInitialData`, `buildLaunchPreview`, `invokeRunner`). Do not construct `LaunchPreview`, `RunRecord`, `FrontendManifest`, `Control`, `QuestionRef`, or `ResultRef` for remote work.

The first path deliberately omits service history browsing, lineage, export creation, raw capture upload, steering, and redirect UI. Hide those shortcuts in service mode and refuse their actions. Existing local functions remain available in local mode. Source-result download is required and is not export creation.

## 2. Client-profile entry and TLS

### New client-side file contract

Supervisor-approved definition, not an existing implemented file format:

```json
{"version":1,"endpoint":"https://manager.example/v1","credentialFile":"/absolute/client/credential","caFile":"/absolute/client/ca.pem"}
```

`CLIENT_PROFILE` is this explicit absolute JSON pathname, not a name registry, manager profile ID, manager configuration file, or manager store. Credential file contains exact bearer bytes without LF. Execution profile is selected later from `/v1/profiles`.

Add `connectClientProfile` to the public Client export list. Add fixed failures `ClientFileUnavailable` and `InvalidClientProfile`. No `Show` instance for Client or credentials. The public Client is also the owner of file/TLS setup, as requested by the supervisor.

Proposed additions to `Client.hs` follow. Additional imports are `Data.Bits ((.&.))`, `Data.Aeson.Types (Parser, parseEither)`, qualified `Data.Aeson.Key`, `Data.X509 (SignedCertificate)`, `Data.X509.Memory (readSignedObject)`, `Data.X509.CertificateStore (makeCertificateStore)`, `Network.Connection (TLSSettings (TLSSettings))`, `Network.HTTP.Client.TLS (mkManagerSettings)`, qualified `Network.TLS`, `System.FilePath (isAbsolute)`, `System.IO (hClose)`, `System.Posix.Files`, `System.Posix.IO`, `System.Posix.User (getEffectiveUserID)`, and exception `bracket`, `finally`, `onException`, `mask`.

```haskell
-- No file contents or parser diagnostics appear in errors.
readClientFile :: Bool -> Int -> FilePath -> IO BS.ByteString
readClientFile private limit path = do
  unless (isAbsolute path && BS.length (TE.encodeUtf8 (T.pack path)) <= 4096
    && not (any (`elem` ['\NUL', '\n', '\r']) path))
    (throwIO InvalidClientProfile)
  result <- try @IOException $
    bracket
      (openFd path ReadOnly defaultFileFlags
        { nofollow = True, cloexec = True, nonBlock = True })
      closeFd $ \fd -> do
        status <- getFdStatus fd
        uid <- getEffectiveUserID
        unless (isRegularFile status && fileSize status <= fromIntegral limit
          && fileMode status .&. 0o022 == 0
          && (not private || (fileOwner status == uid
                && fileMode status .&. 0o077 == 0)))
          (throwIO ClientFileUnavailable)
        -- dup transfers only the duplicate to Handle ownership.
        copy <- dup fd
        handle <- fdToHandle copy `onException` closeFd copy
        bytes <- BS.hGet handle (limit + 1) `finally` hClose handle
        when (BS.length bytes > limit) (throwIO ClientFileUnavailable)
        pure bytes
  either (const (throwIO ClientFileUnavailable)) pure result

parseClientProfile :: Value -> Parser (Text, FilePath, FilePath)
parseClientProfile = withObject "client profile" $ \o -> do
  unless (KM.size o == 4 && all (`KM.member` o)
    ["version", "endpoint", "credentialFile", "caFile"])
    (fail "client profile fields")
  version <- o .: "version" :: Parser Int
  unless (version == 1) (fail "client profile version")
  endpoint <- o .: "endpoint"
  credential <- o .: "credentialFile"
  ca <- o .: "caFile"
  unless (all validFile [credential, ca]) (fail "client profile paths")
  pure (endpoint, credential, ca)
  where
    validFile path = isAbsolute path
      && BS.length (TE.encodeUtf8 (T.pack path)) <= 4096
      && not (any (`elem` ['\NUL', '\n', '\r']) path)

-- Extract this validation from connectClient, and call it there too.
checkedEndpoint :: Text -> IO HTTP.Request
checkedEndpoint endpoint = do
  unless (T.length endpoint <= 8192 && "https://" `T.isPrefixOf` endpoint
    && not (T.any (\c -> c <= ' ' || c `elem` ("@?#\\" :: String)) endpoint))
    (throwIO InvalidEndpoint)
  parsed <- HTTP.parseRequest (T.unpack endpoint)
  unless (HTTP.secure parsed && HTTP.path parsed `elem` ["/v1", "/v1/"]
    && BS.null (HTTP.queryString parsed) && null (HTTP.requestHeaders parsed))
    (throwIO InvalidEndpoint)
  pure parsed

connectClientProfile :: FilePath -> IO (Either ClientFailure Client)
connectClientProfile file = clientIO $ do
  bytes <- readClientFile True 16384 file
  document <- either (const (throwIO InvalidClientProfile)) pure
    (decodeStrictValue bytes)
  (endpoint, credentialFile, caFile) <-
    either (const (throwIO InvalidClientProfile)) pure
      (parseEither parseClientProfile document)
  endpointRequest <- checkedEndpoint endpoint
  caBytes <- readClientFile False 1048576 caFile
  let certificates = readSignedObject caBytes :: [SignedCertificate]
  when (null certificates) (throwIO InvalidClientProfile)
  let defaults = TLS.defaultParamsClient (BC.unpack (HTTP.host endpointRequest)) ""
      parameters = defaults
        { TLS.clientShared = (TLS.clientShared defaults)
            { TLS.sharedCAStore = makeCertificateStore certificates },
          TLS.clientSupported = (TLS.clientSupported defaults)
            { TLS.supportedVersions = [TLS.TLS13] }
        }
      settings = mkManagerSettings (TLSSettings parameters) Nothing
  connectClient settings endpoint (readClientFile True 512 credentialFile)
    >>= either throwIO pure
```

Do not install certificate-validation hooks, `TLSSettingsSimple True`, hostname bypasses, proxy/environment discovery, or fallback CAs. `defaultParamsClient` retains normal chain, validity, and hostname validation. The explicit CA store replaces ambient trust for this client session. The TLS construction follows the installed API already used by `manager/test/DependencyProbe.hs:134–137`, not an invented transport.

Cabal library dependencies need `crypton-connection`, `crypton-x509`, `crypton-x509-store` in addition to existing `tls` and `http-client-tls`. These packages are already in the dependency graph. `Data.X509.Memory` belongs to `crypton-x509-store`. Parent must compile against the pinned versions rather than guess package exports.

**Connection acquisition:** change `connectClient` to `clientIO $ mask $ \restore -> ...`. Create its `active` flag before acquisition completes, then run capability discovery under `restore ... \`onException\` (writeIORef active False >> HTTP.closeManager manager)`. This closes the capability-discovery failure/cancellation window. Preserve existing no-proxy/no-cookie/no-redirect/no-retry/no-pool settings.

Replace `closeClient` with:

```haskell
closeClient :: Client -> IO ()
closeClient (Client _ _ manager _ _ _ _ active) = do
  writeIORef active False
  HTTP.closeManager manager
```

This does not cancel/join request tasks. App must do that explicitly, below.

### Entry functions

Add public export `runServiceTui` to `Agentic.Tui`:

```haskell
runServiceTui :: FilePath -> IO ()
runServiceTui profile = withTerminationHandlers $ do
  inputTerminal <- hIsTerminalDevice stdin
  outputTerminal <- hIsTerminalDevice stdout
  unless (inputTerminal && outputTerminal) $
    ioError (userError "--tui requires terminal input and output")
  bracket
    (Manager.connectClientProfile profile >>= either throwIO pure)
    Manager.closeClient
    runServiceApp
```

Here `Manager` imports only `Agentic.Manager.Client`. No `withPrivateRoot`, executable lookup, state-directory lookup, machine capability subprocess, or local configuration is entered.

In `cli/src/Agentic/Cli.hs`, keep `Tui` and add `TuiService FilePath` to `Command`. Add these arms beside existing `parseCommand` line 3421:

```haskell
  ["--tui"] -> Right Tui
  ["--tui", "--local"] -> Right Tui
  ["--tui", "--service", profile]
    | isAbsolute (T.unpack profile)
    , BS.length (encodeUtf8 profile) <= 4096
    , not (T.any (`elem` ['\NUL', '\n', '\r']) profile) ->
        Right (TuiService (T.unpack profile))
  ("--tui" : _) -> Left
    "--tui takes --local or --service ABSOLUTE_CLIENT_PROFILE"
```

Dispatch `TuiService profile -> runServiceTui profile` beside `Tui -> tuiCmd reg`. Local `tuiCmd` remains unchanged. Add corresponding usage text.

## 3. Client APIs actually missing

### Bound GET observations

The current `prepareCommand :: Client -> Reference -> Maybe Text -> Value -> ...` permits accidental borrowing of another URI's ETag. Keep that low-level API for compatibility, but make the TUI use an opaque GET observation instead:

```haskell
-- Export the type abstractly, plus these functions.
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

prepareObserved :: Client -> Observed -> Value
  -> IO (Either ClientFailure PendingCommand)
prepareObserved client (Observed location etag _) =
  prepareCommand client location (Just etag)

prepareCreateRequest :: Client -> Value
  -> IO (Either ClientFailure PendingCommand)
prepareCreateRequest client value = case reference client "/v1/requests" of
  Left failure -> pure (Left failure)
  Right location -> prepareCommand client location Nothing value
```

Do not construct Observed from Overview items, DTO `revision`, a 201/202 body, page ETags, or another resource's GET. The type intentionally has no exposed constructor.

**Idempotency correction:** current `prepareCommand` uses 32 hexadecimal nonce characters. A valid 105-character epoch then makes a 138-byte key, exceeding 128. Import `Base64URLUnpadded` and replace only key construction:

```haskell
  let key = TE.encodeUtf8 epoch <> "." <> convertToBase Base64URLUnpadded nonce
```

Keep `nonce <- getRandomBytes 16`. This produces 22 nonce characters and fits the maximum epoch. PendingCommand remains the exact URI, bytes, key, and original If-Match. Never prepare again to retry it.

### Polling is headers, not a query invention

`GET /events` requires `Last-Event-ID`, including JSON polling. `getResource` cannot supply it. Add:

```haskell
pollEvents :: Client -> Text -> IO (Either ClientFailure ClientResponse)
pollEvents client cursor = clientIO $ do
  unless (validCursor cursor) (throwIO InvalidResponse)
  location <- either throwIO pure (reference client "/v1/events")
  exchangeJSON client location "GET"
    [("Last-Event-ID", TE.encodeUtf8 cursor)] (HTTP.RequestBodyBS BS.empty)

validCursor :: Text -> Bool
validCursor value = case T.splitOn "." value of
  [stream, number] -> validId stream && canonical64 number
  _ -> False
  where
    canonical64 t = not (T.null t) && T.length t <= 20
      && T.all (\c -> c >= '0' && c <= '9') t
      && (t == "0" || T.head t /= '0')
      && T.foldl' (\n c -> 10 * n + toInteger (fromEnum c - fromEnum '0')) 0 t
           <= 18446744073709551615
```

Do not subtract from `oldestCursor`, derive cursors from runtime sequence numbers, or introduce SSE in this first frontend path. Server polling is already supported.

### Complete page sets

Add `responseBodyBytes :: !Int` to ClientResponse and populate it with `BS.length bytes` in `exchangeJSON`, before discarding raw response bytes. Counting re-encoded JSON is not a valid wire/set bound.

Add abstract `PageSet` with these read-only accessors. Its metadata is the exact repeated top-level object with `page` and `items` removed. Thus Overview metadata retains `version`, `snapshotVersion`, `cursor`, and `oldestCursor`, and RunSnapshot retains all repeated snapshot fields.

```haskell
data PageSet = PageSet
  { pageSetMetadata :: !Value,
    pageSetItems :: ![Value]
  }

data PageInfo = PageInfo
  { pageSetId :: !Text,
    pageRevision :: !Text,
    pageExpiryText :: !Text,
    pageExpiry :: !UTCTime,
    pageIndex :: !Int,
    pageTotal :: !Int,
    pageNext :: !(Maybe Reference)
  }

parseClientValue :: (Value -> Parser a) -> Value -> IO a
parseClientValue parser = either (const (throwIO InvalidResponse)) pure
  . parseEither parser

parsePageInfo :: Client -> Value -> Parser PageInfo
parsePageInfo client = withObject "page" $ \o -> do
  unless (KM.size o == 6 && all (`KM.member` o)
    ["setId", "revision", "expiresAt", "index", "totalItems", "next"])
    (fail "page fields")
  ident <- o .: "setId"
  revision <- o .: "revision"
  expiryText <- o .: "expiresAt"
  unless (validId ident && validId revision && T.length expiryText <= 40)
    (fail "page identity")
  expiry <- maybe (fail "page expiry") pure
    (iso8601ParseM (T.unpack expiryText) :: Maybe UTCTime)
  index <- o .: "index"
  total <- o .: "totalItems"
  unless (index >= 0 && index <= 65535 && total >= 0 && total <= 1048576)
    (fail "page bounds")
  nextText <- o .: "next" :: Parser (Maybe Text)
  next <- traverse (either (const (fail "page link")) pure . reference client) nextText
  pure (PageInfo ident revision expiryText expiry index total next)

pageScope :: Reference -> Maybe (BS.ByteString, [(BS.ByteString, Maybe BS.ByteString)])
pageScope location = do
  let (path, query) = BS.break (== 63) (TE.encodeUtf8 (referenceURI location))
      pairs = HTTP.parseQuery query
      names = map fst pairs
  guard (length names == length (nub names))
  pure (path, sort (filter ((/= "pageToken") . fst) pairs))

getPageSet :: Client -> Reference -> IO (Either ClientFailure PageSet)
getPageSet client first = clientIO (go Nothing Nothing 0 0 0 [] first)
  where
    go stamp metadata index count charged chunks location = do
      unless (pageScope first /= Nothing && pageScope first == pageScope location)
        (throwIO InvalidResponse)
      response <- getJSON client location
      unless (responseStatus response == 200) (throwIO InvalidResponse)
      fields <- parseClientValue (withObject "paged resource" pure)
        (responseValue response)
      page <- parseClientValue
        (\value -> withObject "paged resource"
          (\o -> o .: "page" >>= parsePageInfo client) value)
        (responseValue response)
      items <- parseClientValue
        (withObject "paged resource" (\o -> o .: "items" :: Parser [Value]))
        (responseValue response)
      now <- getCurrentTime
      let nextStamp = (pageSetId page, pageRevision page,
                       pageExpiryText page, pageTotal page)
          nextMetadata = Object (KM.delete "page" (KM.delete "items" fields))
          nextCount = count + length items
          nextCharged = charged + responseBodyBytes response
      unless (pageIndex page == index && now < pageExpiry page
        && length items <= 256 && nextCount <= pageTotal page
        && nextCharged <= 67108864
        && maybe True (== nextStamp) stamp
        && maybe True (== nextMetadata) metadata)
        (throwIO InvalidResponse)
      case pageNext page of
        Nothing -> do
          unless (nextCount == pageTotal page) (throwIO InvalidResponse)
          pure (PageSet nextMetadata (concat (reverse (items : chunks))))
        Just next -> do
          unless (not (null items) && nextCount < pageTotal page && index < 65535)
            (throwIO InvalidResponse)
          go (Just nextStamp) (Just nextMetadata) (index + 1)
            nextCount nextCharged (items : chunks) next
```

Additional imports: `guard`, `nub`, `sort`, `UTCTime`, `getCurrentTime`, and `iso8601ParseM`. `HTTP.parseQuery` comes from the existing HTTP-types alias. This is one serial page assembler, not a pagination framework. Do not install partial sets. Follow `page.next` unchanged. The first path finishes each set before opening another. Current `Pages.withPage` retires a set on its terminal page, so completed profile/workflow/snapshot requests do not consume three simultaneous page-set slots.

### Response safety adjustments

At `exchangeJSON`, require `Cache-Control: no-store`; successful responses must use `application/json`, errors `application/problem+json`. Preserve strict duplicate-key/depth/Unicode decoding. Keep the existing 1 MiB JSON response limit.

At the end of `exchange`, after reading the body and before returning, re-read the credential and compare its fingerprint with `expected`, then `checkActive`. That prevents a response collected during a local credential-file replacement from being installed in the old session:

```haskell
    currentBearer <- readCredential credentials
    unless (BA.constEq (fingerprint currentBearer) expected)
      (throwIO CredentialChanged)
    checkActive client
```

Keep the pre-send fingerprint check as well.

In `downloadVerified`, handle a non-200 response as a bounded public problem before checking artifact headers, so authentication failures do not become anonymous artifact failures. Also require the documented binary media type:

```haskell
  unless (status == 200) $ do
    problem <- either (const (throwIO InvalidResponse)) pure (decodeStrictValue bytes)
    throwIO (publicRefusal status problem)
  unless (BS.length bytes == size
    && fmap (BC.takeWhile (/= ';')) (lookup "Content-Type" headers)
         == Just "application/octet-stream"
    && lookup "Cache-Control" headers == Just "no-store"
    && lookup "X-Content-Type-Options" headers == Just "nosniff"
    && maybe False ("attachment" `BS.isPrefixOf`) (lookup "Content-Disposition" headers))
    (throwIO InvalidResponse)
```

The existing hash check stays. For non-200 downloads, refuse problems above 1 MiB before parsing. Successful bytes remain bounded at 64 MiB. Add `Accept: application/octet-stream` to the download request.

### Version domains

Replace the current three-field capabilities-only test with validation of the exact `Versions` object. Do not equate native versions with API version:

```haskell
checkVersions :: Value -> Parser ()
checkVersions = withObject "versions" $ \o -> do
  let numeric =
        [ ("api", [1]), ("snapshot", [1]), ("event", [1]),
          ("descriptor", [2,3]), ("frontendSession", [1,2]),
          ("control", [1,2]), ("runtimeProtocol", [1,2,3]),
          ("runtimeStore", [1,2]), ("managerStore", [1..12]),
          ("invocation", [1]) ] :: [(Key.Key, [Int])]
  unless (KM.size o == 11 && all (`KM.member` o)
    ("frontendManifest" : map fst numeric)) (fail "version domains")
  forM_ numeric $ \(name, supported) -> do
    values <- o .: name :: Parser [Int]
    unless (not (null values) && length values == length (nub values)
      && all (`elem` supported) values) (fail "unsupported version")
  manifests <- o .: "frontendManifest" :: Parser [Text]
  unless (not (null manifests) && length manifests == length (nub manifests)
    && all (`elem` ["legacy","2","3"]) manifests)
    (fail "unsupported manifest version")
```

Call this inside `requireCapabilities`, mapping failure to `UnsupportedVersion`. Also validate current scopes, unique bounded profile IDs, both advertised transports, and the frozen positive limits before enabling service actions. New native versions fail closed, not downgrade. Manager schema 12 is accepted. A fresh capabilities read whose authority epoch or stream differs from this Client's handshake suspends this session. It does not re-key old mutations.

## 4. DTO parsing and existing view-model adapters

Place these in new `tui/src/Agentic/Tui/Service.hs`. It may import public Runtime observation constructors and the existing pure `personAnswerValue`; it must not import manager implementation modules. Use qualified public Client as `C`.

Use small explicit parsers, not native `decodeWorkflowDescriptors`, native envelope replay, a schema generator, or an HTTP success-shape guess. Recommended parser helpers:

```haskell
closed :: [Key.Key] -> Object -> Parser ()
closed names o = unless (KM.size o == length names && all (`KM.member` o) names)
  (fail "public object fields")

at :: (Value -> Parser a) -> Object -> Key.Key -> Parser a
at parser o key = o .: key >>= parser

text :: Int -> Int -> Value -> Parser Text
text lo hi = withText "bounded text" $ \value -> do
  unless (T.length value >= lo && T.length value <= hi) (fail "text bound")
  pure value

identifier :: Value -> Parser Text
identifier value = do
  name <- text 1 128 value
  unless (T.all (\c -> c `elem` (['A'..'Z'] <> ['a'..'z'] <> ['0'..'9'] <> "_-")) name)
    (fail "identifier")
  pure name

oneOf :: [Text] -> Value -> Parser Text
oneOf choices value = do
  name <- parseJSON value
  unless (name `elem` choices) (fail "public enum")
  pure name

nullable :: (Value -> Parser a) -> Value -> Parser (Maybe a)
nullable _ Null = pure Nothing
nullable parser value = Just <$> parser value

list :: Int -> (Value -> Parser a) -> Value -> Parser [a]
list limit parser = withArray "bounded array" $ \values -> do
  unless (V.length values <= limit) (fail "array bound")
  traverse parser (V.toList values)

natural :: Value -> Parser Integer
natural value = do
  digits <- text 1 4096 value
  unless (T.all (\c -> c >= '0' && c <= '9') digits
    && (digits == "0" || T.head digits /= '0')) (fail "natural decimal")
  pure (T.foldl' (\n c -> n * 10 + toInteger (fromEnum c - fromEnum '0')) 0 digits)

uint64 :: Value -> Parser Word64
uint64 value = do
  number <- natural value
  unless (number <= toInteger (maxBound :: Word64)) (fail "UInt64")
  pure (fromInteger number)

uint32 :: Value -> Parser Word32
uint32 value = do
  number <- natural value
  unless (number <= toInteger (maxBound :: Word32)) (fail "UInt32")
  pure (fromInteger number)

sha256Text :: Value -> Parser Text
sha256Text value = do
  checksum <- text 64 64 value
  unless (T.all (`elem` ("0123456789abcdef" :: String)) checksum) (fail "SHA256")
  pure checksum

versionOne :: Object -> Parser ()
versionOne o = do
  version <- o .: "version" :: Parser Int
  unless (version == 1) (fail "public version")

uniqueBy :: Ord k => (a -> k) -> [a] -> Parser [a]
uniqueBy key values = do
  unless (Set.size (Set.fromList (map key values)) == length values)
    (fail "duplicate identity")
  pure values

publicDecode :: (Value -> Parser a) -> Value -> Either Text a
publicDecode parser = either (const (Left "invalid public manager response")) Right
  . parseEither parser
```

Use `.:` plus `nullable`, not `.:?`, for required nullable fields. Required `false`, `null`, and empty strings remain distinct from absent fields. Parser diagnostics are fixed and never include response bodies.

### Profile/workflow selection

Profile parser reads exactly `version,id,revision,workspaceLabel,targetLabel,readiness,refusal`, with enum/bounds from OpenAPI. Display unavailable/quarantined rows but do not create a request from them. Keep profile ID/revision and workflow ID/revision separate from names and display labels.

The concrete workflow adapter is:

```haskell
data WorkflowRow = WorkflowRow
  { remoteWorkflowId :: !Text,
    remoteWorkflowRevision :: !Text,
    remoteProfileId :: !Text,
    remoteProfileRevision :: !Text,
    remoteDescriptor :: !WorkflowDescriptor,
    remoteHelp :: !Text
  } deriving (Eq, Show)

parseInput :: Value -> Parser WorkflowInputDescriptor
parseInput = withObject "input declaration" $ \o -> do
  closed ["name","source","description","required","schema"] o
  name <- at (text 1 1024) o "name"
  source <- at (oneOf ["prompt","command-tail","stdin"]) o "source"
  description <- o .: "description" :: Parser Value
  required <- o .: "required" :: Parser Bool
  schema <- o .: "schema" :: Parser Value
  unless (description == Null && required && schema == object ["type" .= ("string" :: Text)])
    (fail "input declaration")
  pure (WorkflowInputDescriptor name (case source of
    "prompt" -> DescriptorPrompt
    "command-tail" -> DescriptorCommandTail
    _ -> DescriptorStdin))

parseWorkflow :: Value -> Parser WorkflowRow
parseWorkflow = withObject "workflow" $ \o -> do
  closed ["version","id","revision","profileId","profileRevision",
    "descriptorVersion","runnerVersion","name","blurb","resultCode","level",
    "size","askNodes","minFold","maxFold","paths","inputs","runFacts","pins",
    "capabilities","help"] o
  versionOne o
  ident <- at identifier o "id"
  revision <- at identifier o "revision"
  profile <- at identifier o "profileId"
  profileRevision <- at identifier o "profileRevision"
  descriptorVersion <- o .: "descriptorVersion"
  unless (descriptorVersion `elem` [2,3 :: Int]) (fail "descriptor version")
  c <- o .: "capabilities" >>= withObject "workflow capabilities" pure
  closed ["structuredRun","wholeRunCancel","requestControls","steering",
    "interactiveRetry","schedulerRedirect","semanticResume","immutableFork",
    "restartFromScratch","protocolNegotiation","routingInspection","personaRouting",
    "modelAliasRouting","effectful","toolExecution","consults","observes","effects",
    "personAnsweringModes"] c
  capabilities <- DescriptorCapabilities
    <$> c .: "structuredRun" <*> c .: "wholeRunCancel" <*> pure Nothing
    <*> c .: "requestControls" <*> c .: "steering" <*> c .: "interactiveRetry"
    <*> c .: "schedulerRedirect" <*> c .: "semanticResume" <*> c .: "immutableFork"
    <*> c .: "restartFromScratch" <*> c .: "protocolNegotiation"
    <*> c .: "routingInspection" <*> pure Nothing
    <*> c .: "personaRouting" <*> c .: "modelAliasRouting"
    <*> at natural c "consults" <*> at natural c "observes" <*> at natural c "effects"
    <*> c .: "effectful" <*> c .: "toolExecution"
  modes <- at (list 2 (oneOf ["engine","local-control"])) c "personAnsweringModes"
    >>= uniqueBy id
  inputs <- at (list 256 parseInput) o "inputs" >>= uniqueBy workflowInputName
  descriptor <- WorkflowDescriptor descriptorVersion
    <$> at (text 0 128) o "runnerVersion"
    <*> pure [] <*> pure [] <*> pure capabilities
    <*> at (text 1 1024) o "name" <*> at (text 0 4096) o "blurb"
    <*> at observationCode o "resultCode" <*> at (text 0 128) o "level"
    <*> at natural o "size" <*> at natural o "askNodes"
    <*> at (nullable natural) o "minFold" <*> at (nullable natural) o "maxFold"
    <*> at natural o "paths" <*> pure inputs
    <*> at (list 256 (text 0 4096)) o "runFacts"
    <*> at (list 256 (text 0 4096)) o "pins" <*> pure modes
  help <- at (text 0 262144) o "help"
  pure (WorkflowRow ident revision profile profileRevision descriptor help)
```

`observationCode` validates frozen `ObservationCode`, retaining its original Value: primitives `text/verdict/flag/receipt`, or the closed `{"json":{"schema":SemanticSchema}}` variant. For semantic schemas recursively admit primitive names, closed `array.items`, or closed `property.{name,schema,rest}` and reject duplicate property names along `rest`. This is validation of observation data, not an executable workflow schema. The client strict decoder already limits the entire document to depth 64. Do not map native `ack` to a public result `receipt` by guessing. Snapshot codes and ObservationCode are distinct.

The empty protocol/store lists in the **display adapter** mean “not supplied by Workflow”, not “unsupported”. Do not display them as negotiated native versions. Neither absent control descriptor nor routing JSON version is fabricated. `remoteDescriptor` is used only by browser/input presentation. Service actions retain WorkflowRow identity and never pass it to the local launcher.

`GET /v1/workflows?profileId=<validated ID>` is mandatory. There is no unfiltered `/workflows` fallback. After assembly, every workflow must match the selected profile ID/revision and every ID must be unique. The browser can then use `initialModel (map remoteDescriptor rows) [] (Left "service profile selected")` and the existing `visibleWorkflows`, `beginWorkflow`, `submitInput`, `inputValue`, and selection functions.

### Request and preparation

Use the exact Request shape at OpenAPI lines 2922–2993. Keep full readiness, admission, nullable preparation/run/parent IDs, nullable lineage, and `links.self`. A Request's `runId = null` is not a starting RunSnapshot.

For the first path, retain these pure types:

```haskell
data ApprovalBinding = ApprovalBinding
  { bindingDigest :: !Text,
    bindingRequestRevision :: !Text,
    bindingProfileRevision :: !Text,
    bindingDescriptorRevision :: !Text,
    bindingProcessGeneration :: !Text
  } deriving (Eq, Show)

data Preparation = Preparation
  { preparationId :: !Text,
    preparationRevision :: !Text,
    preparationRequestId :: !Text,
    preparationProfileId :: !Text,
    preparationState :: !Text,
    preparationExpiry :: !UTCTime,
    preparationBinding :: !ApprovalBinding,
    preparationReview :: !Value,
    preparationReason :: !(Maybe Text)
  } deriving (Eq, Show)

parsePreparation :: Value -> Parser Preparation
parsePreparation = withObject "preparation" $ \o -> do
  closed ["version","id","revision","requestId","requestRevision","profileId",
    "profileRevision","descriptorRevision","state","expiresAt","reviewDigest",
    "processGeneration","review","reason"] o
  versionOne o
  binding <- ApprovalBinding <$> at sha256Text o "reviewDigest"
    <*> at identifier o "requestRevision" <*> at identifier o "profileRevision"
    <*> at identifier o "descriptorRevision" <*> at identifier o "processGeneration"
  expiryText <- at (text 1 40) o "expiresAt"
  expiry <- maybe (fail "preparation expiry") pure
    (iso8601ParseM (T.unpack expiryText) :: Maybe UTCTime)
  Preparation <$> at identifier o "id" <*> at identifier o "revision"
    <*> at identifier o "requestId" <*> at identifier o "profileId"
    <*> at (oneOf ["live","consumed","invalidated"]) o "state" <*> pure expiry
    <*> pure binding <*> at parseReview o "review"
    <*> at (nullable (oneOf ["expired","input-changed","profile-changed",
      "worker-lost","discarded","authority-changed","consumed"])) o "reason"

approveBody :: Preparation -> Value
approveBody preparation = let b = preparationBinding preparation in object
  [ "operation" .= ("approve" :: Text),
    "reviewDigest" .= bindingDigest b,
    "requestRevision" .= bindingRequestRevision b,
    "profileRevision" .= bindingProfileRevision b,
    "descriptorRevision" .= bindingDescriptorRevision b,
    "processGeneration" .= bindingProcessGeneration b
  ]
```

`parseReview` must validate and retain precisely the 13 frozen fields: `programHash`, `personAnswering`, `policy`, `workflowId`, `profileId`, `workspaceLabel`, `targetLabel`, `inputs`, `plan`, `runFacts`, `pins`, `warnings`, `resultCode`. Validate each review input's closed `name/source/bytes/sha256` object. Policy is the frozen scripted/routed union at lines 3132–3237. Routed policy admits either `default` or `coverage:"full"`, never both, requires routes/timing/verbose/realizations, and admits the four persona-v2 fields only together. Its realization entries use the allowlist in `PublicRealizationPolicy`. Preserve every admitted public field for display. Never substitute current catalogue routing or use existing `LaunchPreview` to recompute this review.

Before displaying an approvable preparation, compare its request/profile/descriptor revisions, review workflow/profile IDs, and input names, source, UTF-8 byte counts and SHA256 against the submitted request's supplied literals. Compare against the retained server request revisions, not a revision guessed from an ETag. Empty literal remains present. Unicode text is not trimmed, normalized, or suffixed with LF.

### Decision parsing and typed false

The Decision union contains exact required nullable and variant fields. Do not synthesize its generation, queue position, observed sequence, or head identity from a native occurrence. A useful common projection is:

```haskell
data DecisionView = DecisionView
  { decisionId :: !Text,
    decisionRevision :: !Text,
    decisionRun :: !Text,
    decisionProfile :: !Text,
    decisionGeneration :: !Text,
    decisionOccurrence :: !OccurrenceId,
    decisionState :: !Text,
    decisionPosition :: !Int,
    decisionSequence :: !Word64,
    decisionQueue :: !Text,
    decisionContent :: !DecisionContent
  } deriving (Eq, Show)

data DecisionContent
  = QuestionContent !Value !Text !Value
  | RecoveryContent !Text !Text ![RecoveryOption]
  deriving (Eq, Show)

parseDecision :: Value -> Parser DecisionView
parseDecision = withObject "decision" $ \o -> do
  kind <- at (oneOf ["question","recovery"]) o "kind"
  closed (["version","id","revision","runId","profileId","generation","address",
    "state","position","observedSequence","queue","kind"]
    <> if kind == "question" then ["question"] else ["gap","message","choices"]) o
  versionOne o
  occurrence <- at (withObject "occurrence address" $ \address -> do
    closed ["occurrenceId"] address
    OccurrenceId <$> at uint64 address "occurrenceId") o "address"
  position <- o .: "position"
  unless (position >= 0 && position <= 2047) (fail "decision position")
  content <- if kind == "question"
    then at (withObject "question" $ \q -> do
      closed ["code","semanticSchema","editorSchema","addressee","scope","draw","prompt"] q
      code <- at observationCode q "code"
      prompt <- at (text 0 524288) q "prompt"
      -- validateQuestionMetadata performs the frozen schema agreement checks.
      validateQuestionMetadata code q
      pure (QuestionContent code prompt (Object q))) o "question"
    else RecoveryContent <$> at (text 0 4096) o "gap"
      <*> at (text 0 4096) o "message"
      <*> at (list 16 parseRecoveryOption) o "choices"
  DecisionView <$> at identifier o "id" <*> at identifier o "revision"
    <*> at identifier o "runId" <*> at identifier o "profileId"
    <*> at identifier o "generation" <*> pure occurrence
    <*> at (oneOf ["pending","submitting","resolved","invalidated"]) o "state"
    <*> pure position <*> at uint64 o "observedSequence"
    <*> at resourceLink o "queue" <*> pure content

parseRecoveryOption :: Value -> Parser RecoveryOption
parseRecoveryOption = withObject "recovery option" $ \o -> do
  closed ["choice","target"] o
  choice <- at (oneOf ["retry","failover","abandon"]) o "choice"
  target <- at (nullable (text 0 1024)) o "target"
  unless (choice == "failover" || target == Nothing) (fail "recovery target")
  pure (RecoveryOption choice target)

decisionPrompt :: DecisionView -> Maybe PersonPrompt
decisionPrompt decision = case decisionContent decision of
  QuestionContent code prompt _ -> Just PersonPrompt
    { personPromptOccurrence = decisionOccurrence decision,
      personPromptCode = case code of String name -> name; _ -> "structured",
      personPromptIntent = "question",
      personPromptText = prompt
    }
  _ -> Nothing

answerBody :: DecisionView -> Text -> Either Text Value
answerBody decision input = case decisionContent decision of
  QuestionContent (String code) _ _ -> do
    answer <- personAnswerValue code input
    pure (body answer)
  QuestionContent _ _ _ -> Left "structured answer editor is not enabled in this service path"
  _ -> Left "selected decision is not a question"
  where
    body value = object
      [ "operation" .= ("answer" :: Text),
        "generation" .= decisionGeneration decision,
        "occurrenceId" .= T.pack (show (occurrenceNumber (decisionOccurrence decision))),
        "value" .= value
      ]
```

`validateQuestionMetadata` validates required nullable semantic/editor schemas, bounded addressee, closed scope with both nullable axes, and NaturalDecimal draw. For structured codes, repeated semanticSchema must equal `json.schema`. Preserve those fields for the question details viewport, but do not infer an absent semantic schema for primitive verdict. `personPromptIntent` above is only a display label, not a claim about native question intent, which this DTO does not expose.

The first path intentionally rejects structured submission rather than using `eitherDecodeStrict'` as a replacement for strict manager JSON validation. Primitive `flag` uses existing `personAnswerValue` (`Person.hs:63–72`), which returns `Right (Bool False)` for `false` or `no`. No Maybe test, truthiness test, or text coercion intervenes. The sent JSON includes `"value":false`.

The current `PersonPrompt` type is a display record. Service code must never call `loadPersonPrompt`, which reads private manager/runtime files in local mode.

### Full RunSnapshot observation adapter

The public snapshot is not native snapshot JSON and cannot be fed to `stepRunSnapshot`. Parse the complete paged public DTO into shared observation constructors. The important full adapter body is:

```haskell
data RunObservation = RunObservation
  { remoteRunId :: !Text,
    remoteRuntimeSequence :: !(Maybe Word64),
    remoteRuntimeProtocol :: !(Maybe Int),
    remoteSnapshot :: !(Maybe RunSnapshot),
    remoteResult :: !(Maybe Value),
    remoteVerification :: !Value,
    remoteSupervision :: !Text,
    remoteIntegrity :: !Text,
    remoteOccurrenceDecisions :: !(Map.Map OccurrenceId (Maybe Text))
  } deriving (Eq, Show)

parseRunObservation :: C.PageSet -> Either Text RunObservation
parseRunObservation pages = publicDecode parser (C.pageSetMetadata pages)
  where
    parser = withObject "run snapshot metadata" $ \o -> do
      closed ["version","snapshotVersion","runId","runtime","workflow","targetLabel",
        "personAnswering","authoredOrder","traceRecorded","controlAcks","billFresh",
        "billMemo","result","verification","failure","failureClass","supervision","integrity"] o
      versionOne o
      snapshotVersion <- o .: "snapshotVersion" :: Parser Int
      unless (snapshotVersion == 1) (fail "snapshot version")
      ident <- at identifier o "runId"
      runtime <- at (nullable parseRuntimeSummary) o "runtime"
      runId <- either (const (fail "run id")) pure (mkRunId ident)
      occurrences <- traverse parseOccurrence (C.pageSetItems pages)
        >>= uniqueBy snapshotOccurrenceId
      decisionIds <- traverse
        (withObject "occurrence decision" (\item ->
          (,) <$> (OccurrenceId <$> at uint64 item "occurrenceId")
              <*> at (nullable identifier) item "decisionId"))
        (C.pageSetItems pages)
      unless (length occurrences <= 2048
        && sum (map (Map.size . snapshotOccurrenceAttempts) occurrences) <= 512)
        (fail "snapshot cardinality")
      order <- at (list 2048 (fmap OccurrenceId . uint64)) o "authoredOrder"
        >>= uniqueBy id
      acks <- at (list 2048 parseAcknowledgement) o "controlAcks"
        >>= uniqueBy snapshotControlId
      workflow <- at (nullable (text 0 1024)) o "workflow"
      target <- at (nullable (text 0 1024)) o "targetLabel"
      answering <- at (nullable parseJSON) o "personAnswering"
      recorded <- o .: "traceRecorded"
      fresh <- at (nullable natural) o "billFresh"
      memo <- at (nullable natural) o "billMemo"
      failure <- at (nullable (text 0 4096)) o "failure"
      failureClass <- at (nullable parseFailureClass) o "failureClass"
      result <- at (nullable parseResultReference) o "result"
      verification <- at parseVerification o "verification"
      supervision <- at (oneOf ["owned","cleanup-pending","lost","observer"]) o "supervision"
      integrity <- at (oneOf ["valid","corrupt","incomplete","unknown"]) o "integrity"
      let snapshot (status, _, _) = RunSnapshot
            { snapshotRunId = runId,
              snapshotRunStatus = status,
              snapshotLastEnvelope = Nothing,
              snapshotWorkflow = workflow,
              snapshotTarget = target,
              snapshotPersonAnswering = answering,
              snapshotOccurrences = Map.fromList [(snapshotOccurrenceId x, x) | x <- occurrences],
              snapshotAuthoredOrder = order,
              snapshotTraceRecorded = recorded,
              snapshotControlAcks = Map.fromList [(snapshotControlId x, x) | x <- acks],
              snapshotBillFresh = fresh,
              snapshotBillMemo = memo,
              snapshotResult = Nothing,
              snapshotRunFailure = failure,
              snapshotRunFailureClass = failureClass
            }
      pure (RunObservation ident ((\(_,n,_) -> n) <$> runtime)
        ((\(_,_,v) -> v) <$> runtime) (snapshot <$> runtime)
        result verification supervision integrity (Map.fromList decisionIds))
```

The null native result/question reference fields and null last envelope are deliberate. Their public replacements are retained separately. They never become fabricated paths or replay checkpoints. A null `runtime` yields no RunSnapshot, not `RunStarting` or `RunSucceeded`.

Nested adapter field map, with no dropped retained fields:

| Public field | Shared observation |
|---|---|
| Occurrence `occurrenceId` (UInt64) | `OccurrenceId` |
| Occurrence `state` | exact six-way OccurrenceState case |
| `code,intent,addressee,prompt,answer` | corresponding snapshot fields; `answer` remains rendered text |
| `dispatch` | `DispatchSnapshot targets open (commandId,target)` |
| `recovery` | `RecoverySnapshot gap message retries choices chosen` |
| `reuseKind,source,failureClass,replayable,personPending` | corresponding snapshot fields |
| `decisionId` | retained in service-side occurrence-to-decision map, not QuestionRef |
| Attempt `address` | `AttemptId (OccurrenceId occurrenceId) attemptId`; check containing occurrence agrees |
| Attempt `targetLabel,state,output,steers,messages,tools,todos,usage,reasoningSummaries,failure,failureClass` | all corresponding AttemptSnapshot fields |
| Attempt `snapshotAttemptSteerable` | `Nothing`; authorization comes from RunControl, not guessed here |
| Acknowledgement `commandId,state,message,command,occurrenceId,attemptId` | ControlAckSnapshot; construct attempt only when occurrence is present |

Use explicit nested DTO parsers, not native `FromJSON` wholesale. For example, native `PublicTodoItem` currently requires nonempty content and limits it to 1024, while public Todo permits empty content through 2048. Native RecoveryOption allows missing target, while public target is required nullable. These dialect differences make a direct `parseJSON` shortcut incorrect.

The constructors for the two larger nested records can be written directly:

```haskell
-- Call closed with the complete Occurrence key list before this body.
-- Parse and retain decisionId separately in the enclosing service view.
occurrenceFields :: Object -> Parser OccurrenceSnapshot
occurrenceFields o = do
  ident <- OccurrenceId <$> at uint64 o "occurrenceId"
  attempts <- at (list 512 (parseAttempt ident)) o "attempts"
    >>= uniqueBy snapshotAttemptId
  OccurrenceSnapshot ident
    <$> at parseOccurrenceState o "state"
    <*> at (oneOf ["text","verdict","flag","ack","structured"]) o "code"
    <*> at (text 0 1024) o "intent" <*> at (text 0 4096) o "addressee"
    <*> at (text 0 524288) o "prompt" <*> at (nullable (text 0 524288)) o "answer"
    <*> at (nullable parseDispatch) o "dispatch"
    <*> at (nullable parseRecovery) o "recovery"
    <*> at (nullable (text 0 1024)) o "reuseKind"
    <*> at (nullable (text 0 4096)) o "source"
    <*> at (nullable parseFailureClass) o "failureClass"
    <*> o .: "replayable" <*> pure Nothing <*> o .: "personPending"
    <*> pure (Map.fromList [(snapshotAttemptId x,x) | x <- attempts])

parseAttempt :: OccurrenceId -> Value -> Parser AttemptSnapshot
parseAttempt occurrence = withObject "attempt" $ \o -> do
  closed ["address","targetLabel","state","output","steers","messages","tools",
    "todos","usage","reasoningSummaries","failure","failureClass"] o
  address <- at parseAttemptAddress o "address"
  unless (attemptOccurrence address == occurrence) (fail "attempt occurrence")
  tools <- at (list 128 parseTool) o "tools" >>= uniqueBy publicToolId
  AttemptSnapshot address
    <$> at (text 0 1024) o "targetLabel" <*> at parseAttemptState o "state"
    <*> pure Nothing <*> at (text 0 65536) o "output"
    <*> at (list 256 parseSteer) o "steers"
    <*> at (list 128 (text 0 4096)) o "messages"
    <*> pure (Map.fromList [(publicToolId x,x) | x <- tools])
    <*> at (list 128 parseTodo) o "todos"
    <*> at (nullable parseUsage) o "usage"
    <*> at (list 128 (text 0 4096)) o "reasoningSummaries"
    <*> at (nullable (text 0 4096)) o "failure"
    <*> at (nullable parseFailureClass) o "failureClass"
```

All named leaf parsers above are mechanical closed-schema cases from OpenAPI `RuntimeSummary`, `Dispatch`, `Recovery`, `ControlAcknowledgement`, `ResultReference`, `Verification`, `Tool`, `Todo`, `Usage`, and `Steer`. Preserve the exact schema bounds. The field map is intentionally explicit so no server parser is imported to fill this work in.

### Overview, receipts, and outputs

A complete Overview parser first checks metadata keys exactly `version,snapshotVersion,cursor,oldestCursor` after Client page assembly. Both versions equal 1. Validate both cursor syntaxes without deriving their values. Decode each item as exactly one closed pair:

```haskell
parseOverviewItem :: Value -> Parser OverviewItem
parseOverviewItem = withObject "overview item" $ \o -> do
  kind <- at (oneOf ["request","run","decision","preparation"]) o "kind"
  let key = Key.fromText kind
  closed ["kind", key] o
  case kind of
    "request" -> OverviewRequest <$> at parseRequest o key
    "run" -> OverviewRun <$> at parseRun o key
    "decision" -> OverviewDecision <$> at parseDecision o key
    _ -> OverviewPreparation <$> at parsePreparation o key
```

`parseRun` must retain the `KnownRun` versus `UnreadableRun` union. Do not fabricate workflow/runtime/manifest fields for unreadable rows. Check duplicate identities within each kind. Preserve all authorized items rather than taking 256. Install graph and cursors together only after every page and item validates.

Use the graph to locate the selected request's preparation/run and that run's decision. Do not treat removal from the active Overview as cancellation or completion. Continue GETs on already selected request/run references, including terminal runs.

Mutation response rules are not interchangeable:

* Create draft: **201 Request**, with Location equal to Request `links.self` and its validated `/v1/requests/{id}` URI. No runtime starts here.
* Set input, enqueue, approve, answer, recovery, cancel: **202 CommandReceipt**, with Location equal to `links.self` and `/v1/commands/{id}`. Check receipt operation/profile/resource match the submitted intent. Preserve the exact PendingCommand until reconciliation finishes.
* A receipt's `accepted`, `dispatch-attempted`, `acknowledged`, `effect-observed`, `refused`, and `unresolved` are different states. None is a replacement RunSnapshot. Its acknowledgement/effect/refusal nullability must match its state as specified at OpenAPI lines 4743–4819.

OutputPage metadata is exactly `version,runId` after removing pages/items. Output items are the frozen attempt/diagnostic/result union. For a result, require `verification.state == "verified"`, non-null artifact, matching artifact ID, run ID, source-result kind, bounded decimal byte size, and SHA256. Bind its `download` with `C.reference`. Do not interpret `preview` or verification metadata as downloaded-byte evidence.

## 5. Exact asynchronous ownership in App

Current `App.hs` already owns Async handles in `stateWorkers :: MVar (Map Work (Async ()))` and request serials. Extend that mechanism instead of spawning untracked workers.

Replace `stateConfig/stateRoot` with:

```haskell
data Backend = LocalBackend !TuiConfig !PrivateRoot | ServiceBackend !C.Client
```

Add `stateBackend :: Backend` and `stateService :: Maybe ServiceSession`. ServiceSession holds observations, public DTOs, cursor, refresh state, mutation state, and downloaded bytes, but no manager paths or process handles. Keep existing local RunningMachine fields empty in service mode.

Turn existing `runApp config root` into the wrapper `runAppWith (LocalBackend config root)`. Add `runServiceApp client = runAppWith (ServiceBackend client)`. Reuse current Vty, channel, ticker, editors, model, and worker initialization. There must be no dummy local configuration or fake PrivateRoot. `presentationConfig` becomes `Maybe TuiConfig`; local confirmation branches require Just, service branches use their own reviewed DTO. Keep `staticPresentation config` as a wrapper setting Just so existing rendering tests need little change.

### Slots and events

```haskell
-- Add constructors to existing Work.
-- ServiceReadWork | ServicePrepareWork | ServiceSendWork | ServiceDownloadWork

data Ticket = Ticket !Integer !Integer deriving (Eq, Ord)
-- Client-session generation, monotonically increasing job serial.
-- View changes invalidate read tickets, not a still-owned mutation ticket.

data RefreshState = RefreshIdle | RefreshBusy !Ticket !Bool
-- Bool is dirty, not permission to start another HTTP request.

data MutationState
  = MutationIdle
  | MutationPreparing !Ticket !Purpose
  | MutationSending !Ticket !Purpose !C.PendingCommand
  | MutationAwaiting !Purpose !C.PendingCommand !C.Reference
  | MutationUncertain !Purpose !C.PendingCommand !(Maybe C.Reference) !Text

-- Add to AppEvent, carrying typed result packages, not closures.
-- ServiceReadReady Ticket (Either C.ClientFailure ServiceReadResult)
-- ServicePrepared Ticket (Either C.ClientFailure C.PendingCommand)
-- ServiceSent Ticket (Either C.ClientFailure C.ClientResponse)
-- ServiceDownloaded Ticket Reference ArtifactIdentity
--   (Either C.ClientFailure ByteString)
```

Purpose is the small first-path sum: `CreateDraft WorkflowRow`, `SetLiteral RequestId InputName Text InputIndex`, `Enqueue RequestId`, `Approve Preparation`, `Answer DecisionView`, `Recovery DecisionView`, `Cancel RunId`. It is retained only in memory and never logged with input content.

Use the existing `startWorker` for starting a slot **only after the pure phase guard succeeds**. Do not call it on each timer tick: it cancels the previous task. Mutations are never replaced by a fresh click.

Explicit worker join implementation, also usable for existing local slots:

```haskell
stopWorker :: Async () -> IO ()
stopWorker worker = cancel worker >> void (waitCatch worker)

cancelWorker :: AppState -> Work -> IO ()
cancelWorker state work =
  modifyMVarMasked_ (stateWorkers state) $ \workers -> do
    mapM_ stopWorker (Map.lookup work workers)
    pure (Map.delete work workers)

startWorker :: AppState -> Work -> IO () -> IO ()
startWorker state work action =
  modifyMVarMasked_ (stateWorkers state) $ \workers -> do
    mapM_ stopWorker (Map.lookup work workers)
    worker <- asyncWithUnmask (\unmask -> unmask action)
    pure (Map.insert work worker workers)
```

The Async above is the task executing `C.observeResource`, `C.getPageSet`, `C.pollEvents`, `C.sendCommand`, or `C.downloadVerified`, not a wrapper that launches a detached HTTP child. Exceptions used for cancellation must pass through:

```haskell
safeClientWork :: IO (Either C.ClientFailure a) -> IO (Either C.ClientFailure a)
safeClientWork action = do
  outcome <- try @SomeException action
  case outcome of
    Left failure | Just _ <- fromException @SomeAsyncException failure -> throwIO failure
    Left _ -> pure (Left C.TransportUnavailable)
    Right result -> pure result
```

Parsing can run in that same worker. Force/validate the result before sending the Brick event. Never put raw exception messages, request headers, or credentials into AppEvent. Preserve lossless completion events with `writeBChan`; cancellation of a worker blocked on that channel remains possible.

### Single-flight refresh rules

These pure reducers are sufficient for one bounded read lane:

```haskell
markRefreshDirty :: RefreshState -> RefreshState
markRefreshDirty RefreshIdle = RefreshIdle
markRefreshDirty (RefreshBusy ticket _) = RefreshBusy ticket True

beginRefresh :: Ticket -> RefreshState -> (RefreshState, Bool)
beginRefresh ticket RefreshIdle = (RefreshBusy ticket False, True)
beginRefresh _ busy = (markRefreshDirty busy, False)

finishRefresh :: Ticket -> RefreshState -> Maybe Bool
finishRefresh ticket (RefreshBusy expected dirty)
  | ticket == expected = Just dirty
finishRefresh _ _ = Nothing
```

Call-site behavior must be exact:

1. A timer/manual invalidation in RefreshIdle allocates a new ticket, installs RefreshBusy, then starts ServiceReadWork. While busy it only sets dirty.
2. ServiceReadReady is accepted only when its ticket equals the busy ticket **and** its Client-session generation is current. The busy job also records the selected profile/run identities. Apply the entire validated result atomically. Set idle. If dirty, schedule one next refresh.
3. Selecting another profile/run, starting a mutation, or resnapshotting after cursor loss clears the busy read ticket and advances the job serial **before** cancel/join of ServiceReadWork. Late events cannot clear a newer busy flag or reinstall an old view. These read invalidations do not invalidate a still-owned mutation ticket. Increment Client-session generation only on session teardown/replacement or authorization suspension. On suspension, convert any Sending phase to Uncertain before dropping its stale completion event.
4. Use `-- ponytail: one serial read lane; split by resource if refresh latency becomes material.` No per-resource worker pool is needed.
5. ServiceSendWork is separate and single-flight. A repaint, tick, navigation, or refresh must never cancel/replace an in-flight mutation. After preparing returns, store the PendingCommand in MutationSending before starting its one HTTP send.
6. Download completions additionally match the retained download ticket, session generation, selected run, bound download Reference, artifact ID, size, and digest. Selecting another run invalidates that ticket before cancelling/joining the original download task. Its late event cannot install bytes for the newly selected run.

Polling algorithm, using only reads:

* Bootstrap: complete `/profiles`, then complete `/snapshot`; install both. Select a profile, then complete its `/workflows?profileId=...`. Each set is assembled serially.
* Attach JSON event polling only after complete Overview installation, passing its exact cursor. Validate the entire EventBatch and each invalidation before advancing its cursor.
* Process invalidations as dirtiness, not as runtime envelopes. A nonempty batch triggers one complete Overview refresh and the exact selected request/preparation/run snapshot/control/decision/receipt GETs. A `hasMore` batch schedules another bounded poll, not an unbounded in-memory accumulation.
* When a new Overview supplies a later boundary, install its own cursor and oldestCursor together. Never install an old EventBatch cursor over a resnapshot.
* Even an unchanged batch proves only that poll request's authorization. Gate mutations on current observed resources, scopes, preparation expiry, and absence of stale/uncertain state.
* Terminal selected run remains selected even if absent from active Overview. Fetch its RunSnapshot and OutputPage until genuine terminal runtime evidence and verified output are obtained.

### Mutation state rules

The following table is the reducer, not an invitation to infer success:

| Current state / event | Action |
|---|---|
| Idle + explicit user action | Capture immutable displayed DTO and exact Observed; prepare once under ServicePrepareWork. |
| Preparing + matching prepared success | Store PendingCommand, enter Sending, start exactly one ServiceSendWork. |
| Preparing + failure | Return to Idle with fixed error; no HTTP mutation has started. |
| Sending + matching 201 valid Request | Install created identity, then GET its exact URI for an ETag. Open first input editor. |
| Sending + matching 202 valid receipt | Retain PendingCommand and receipt reference in Awaiting. Poll receipt/resource. No next mutation yet. |
| Sending + transport/parse/redirect/size/unknown failure | Enter Uncertain with original PendingCommand. Never create a replacement key or retry automatically. |
| Sending + authenticated refusal | Display exact fixed status/code and refresh read-only. For stale/conflict, invalidate the displayed authorization. Do not resubmit with a fresh ETag. Retain original attempt until explicit reconciliation. |
| Awaiting + accepted/dispatch-attempted/acknowledged | Keep waiting. “Acknowledged” is not effect or completion. |
| Awaiting + effect-observed | Read the affected resource. Advance input/editor stage only after matching effect and requested literal are visible. Approval still waits for actual RunSnapshot runtime evidence. |
| Awaiting + refused | Display refusal, refresh resource, require a new explicit action. |
| Awaiting + unresolved | Enter Uncertain, retaining receipt reference and PendingCommand. |
| Uncertain + refresh | GET only. Never infer absence means unexecuted. |
| Uncertain + explicit “resend exact attempt” confirmation | Send the retained PendingCommand unchanged, only in the same live Client session. No reprepare, fallback, new body, new ETag, or new key. |

For simplicity, all send failures can retain a pending uncertain attempt while separately labeling a known refusal. A valid 503 does not establish absence of an effect. An authorization error while reconciling a previous uncertain attempt does not erase that uncertainty.

### Exit cleanup

Replace the service branch of current cleanup (`App.hs:243–249`) with a joined, masked teardown. Do not use uninterruptibleMask around network cancellation/join and do not halt a manager worker on frontend exit:

```haskell
cleanupService :: C.Client -> Async () -> MVar (Map.Map Work (Async ()))
  -> Vty.Vty -> IO ()
cleanupService client ticker workers vty = mask_ $ do
  owned <- modifyMVar workers (\current -> pure (Map.empty, Map.elems current))
  (C.closeClient client `finally` stopAll (ticker : owned))
    `finally` Vty.shutdown vty
  where
    stopAll [] = pure ()
    stopAll (worker : remaining) = stopWorker worker `finally` stopAll remaining
```

Change ticker acquisition from `forkIO` to an owned `Async ()` too. Acquire Vty/ticker/workers under nested brackets or onException cleanup so a failure before `customMain` cannot leave a ticker alive. If preserving current ThreadId ticker in local mode, keep its current local cleanup separately.

On `q`, EOF, SIGINT, or SIGTERM, stop new service jobs, mark the Client closed, cancel/join the original HTTP tasks, and restore terminal. If a mutation was sending, exit text must say its outcome may be uncertain and the manager run is not cancelled. Never resolve uncertainty by killing a local child, reading manager files, or resending on restart.

## 6. Exact TUI action adaptations

Add `ServiceProfilesScreen`, `ServiceWaitingScreen Text`, and `ServiceReviewScreen Preparation` to Screen. Keep BrowserScreen for service workflows, InputScreen for literal editing, and LiveScreen only when a public RunSnapshot has non-null runtime. Service mode's browser exposes workflows and a profile-back action, not the existing local Runs/Routing tabs.

The IO boundary should be exhaustive:

```haskell
withBackend :: (TuiConfig -> PrivateRoot -> EventM Name AppState ())
  -> (C.Client -> EventM Name AppState ()) -> EventM Name AppState ()
withBackend local service = do
  state <- get
  case stateBackend state of
    LocalBackend config root -> local config root
    ServiceBackend client -> service client
```

Move current local action bodies behind the local arm. Backend dispatch belongs in actions, not just rendering. This prevents an overlooked key from invoking a subprocess or filesystem path.

| Existing App function | Service arm |
|---|---|
| `startInitialLoad` | Load public profiles and complete Overview. |
| `handleEnter` | Profile screen selects configured profile; workflow browser explicitly creates draft. |
| `submitEditor` | Prepare/send one `set-input` for current editor, preserving exact Unicode/empty bytes. Advance only after receipt effect and request GET. |
| `chooseScripted`, `chooseLive`, `beginPreview` | Service target page offers only explicit enqueue into selected configured profile. No local target construction. |
| `confirmLaunch` | Approve the held exact preparation, below. |
| `showSelectedHelp` | Use WorkflowRow.help. No runner invocation. |
| `refreshRuns` | Public refresh only; do not call `loadRunCatalogue`. |
| `ensureAuxiliaryLoads` | Public decision, output metadata, and verified download only. |
| `submitPersonAnswer` | Public decision answer using held exact decision observation. |
| `sendRecoveryFor` | Matching public RunControl offer only. |
| `requestCancellation`, `confirmCancellation` | Explicit manager cancel if public `cancelAllowed`; no terminateMachine fallback/timer. |
| `openSteer`, `redirectSelected`, `beginLineage`, `openSelectedRun` | Fixed “not available in this service path”; hidden shortcuts. |
| `saveFinalResult` | Save retained verified bytes unchanged, never existing JSON re-encoder. |
| `handleEscape`/quit | Navigation or detach only. Do not withdraw, discard, approve, or cancel implicitly. |

Use complete command bodies:

```haskell
createBody :: WorkflowRow -> Value
createBody row = object
  [ "workflowId" .= remoteWorkflowId row,
    "descriptorRevision" .= remoteWorkflowRevision row,
    "profileId" .= remoteProfileId row,
    "profileRevision" .= remoteProfileRevision row
  ]

setInputBody :: Text -> Text -> Value
setInputBody name value = object
  [ "operation" .= ("set-input" :: Text),
    "input" .= object
      [ "name" .= name, "source" .= ("literal" :: Text), "value" .= value ]
  ]

enqueueBody :: Value
enqueueBody = object ["operation" .= ("enqueue" :: Text)]
```

Enqueue has a separate visible Enter action after every supplied input is acknowledged and readiness has neither missing inputs nor errors. It requires GET/ETag from the same request URI, not `/requests` or `/snapshot`.

Approval handler requirements:

```haskell
prepareApproval :: C.Client -> UTCTime -> Preparation -> C.Observed
  -> IO (Either C.ClientFailure C.PendingCommand)
prepareApproval client now displayed observed =
  case publicDecode parsePreparation (C.observedValue observed) of
    Right current
      | current == displayed
      , preparationState current == "live"
      , now < preparationExpiry current
      , C.referenceURI (C.observedReference observed)
          == "/v1/preparations/" <> preparationId current ->
          C.prepareObserved client observed (approveBody displayed)
    _ -> pure (Left C.InvalidResponse)
```

The App additionally requires current submit+control scopes, no dirty/stale authorization, no pending mutation, a full visible selector summary, and an explicit `y` on that summary. A refreshed or expired preparation replaces the screen and disables approval until its newly displayed exact review is approved. Do not refetch a different review inside this function and approve it invisibly. Do not let Enter carried over from the previous screen consent to execution.

Decision answers require all of: RunControl supervision `owned`; Decision pending; position zero; RunControl `decisionHeadId == decisionId`; matching selected run/profile; an answer offer with matching occurrence and generation; current control scope; exact `GET /decisions/{id}` observation. Encode only the DecisionMutation fields above. No attempt ID.

Recovery retry is selected from current public offers, not from reconstructed runtime capability booleans:

```haskell
-- ControlOffer is the direct parsed public DTO. No Runtime Control is built.
retryBody :: DecisionView -> ControlOffer -> Either Text Value
retryBody decision offer
  | offerOccurrence offer /= decisionOccurrence decision
      || offerGeneration offer /= Just (decisionGeneration decision) =
      Left "recovery offer is stale"
  | offerOperation offer == "retry" = Right (body [])
  | offerOperation offer == "choose-recovery"
      && any ((== "retry") . recoveryChoice) (offerChoices offer) =
      Right (body ["choice" .= ("retry" :: Text)])
  | otherwise = Left "retry is not offered"
  where
    body more = object
      ([ "operation" .= offerOperation offer,
         "occurrenceId" .= T.pack (show (occurrenceNumber (decisionOccurrence decision))),
         "generation" .= decisionGeneration decision ] <> more)
```

Check the same head/pending/supervision conditions as answers, and require a RecoveryContent decision. Send via `prepareObserved` on the **control resource GET**, not its run snapshot or decision ETag. A chooser-only offer emits `operation:"choose-recovery",choice:"retry"`; a retry offer emits `operation:"retry"`. This makes the existing `r` key real without inventing unsupported control authority.

Service mandatory-modal selection uses `RunControl.decisionHeadId` and the matching parsed Decision, not `updateMandatoryDecisions [] [] snapshot`, which cannot discover a new FIFO head without native envelopes. Reuse PersonLayer and RecoveryLayer drawing; do not create fake Envelope values to drive the local reducer. When the head changes, reset the editor and increment its load generation. A delayed answer response never clears the next decision's editor.

## 7. Review and progress rendering

Existing Presentation owns the responsive shell, `dialog`, `pane`, `displayText`, `displayTextWrap`, independent viewports, `wrapDisplayLines`, and 140x36 layout. Reuse them. All server text passes through those safe widgets, never stdout or raw Vty escape sequences.

The service review uses the same confirmation layer but not `LaunchPreview`. Display request/profile/workflow identity, expiry, the five complete selectors, exact-URI ETag, program hash, selected workspace/target, and an explicit details affordance. The full retained Review is available in ConfirmDetailsViewport: policy including every realization, input source/byte/hash rows, exact plan, run facts, pins, warnings, result code, and person-answering mode. It comes from one Preparation object, not a catalogue merge.

```haskell
approvalSelectorLines :: Preparation -> [Text]
approvalSelectorLines preparation =
  let b = preparationBinding preparation in
  [ "reviewDigest       " <> bindingDigest b,
    "requestRevision    " <> bindingRequestRevision b,
    "profileRevision    " <> bindingProfileRevision b,
    "descriptorRevision " <> bindingDescriptorRevision b,
    "processGeneration  " <> bindingProcessGeneration b
  ]

serviceReviewRows :: Text -> Preparation -> [Text]
serviceReviewRows etag preparation =
  [ "Explicit approval starts execution through the manager.",
    "Request  " <> preparationRequestId preparation,
    "Profile  " <> preparationProfileId preparation,
    "Preparation  " <> preparationId preparation,
    "If-Match  " <> etag,
    "Expires  " <> T.pack (show (preparationExpiry preparation))
  ] <> approvalSelectorLines preparation
    <> ["d EXACT REVIEW DETAILS", "y APPROVE EXACT REVIEW   n BACK"]

serviceReviewFits :: Int -> Int -> [Text] -> Bool
serviceReviewFits width height rows =
  let innerWidth = max 1 (min 132 (width - 4))
      available = max 0 (height - 9)
  in width >= 40
      && sum (map (length . wrapDisplayLines innerWidth) rows) <= available
```

Use the **same** inner width and body-height calculation for drawing and gating. No truncation, ellipsis, or fixed five-fixture-values table. `y` is disabled in the details layer and when summary does not fit. At 140x36 the five selectors are shown wrapped in full. Details scrolling does not create per-leaf consent ceremonies. One explicit approval binds the complete server review and all five selectors.

Adjust `personView`'s current “Answer accepted locally” wording in service mode to the actual stage: “Sending answer”, “Manager accepted intent; waiting for effect”, or “Outcome uncertain”. Never call an HTTP receipt native delivery. Add `presentationSubmissionStatus :: Maybe Text` rather than overloading `presentationPersonSubmitted` to imply success.

Progress uses the complete remote RunSnapshot adapter with existing `reconcileRunView`, `occurrenceRowsWithSelection`, `selectedOutputLines`, and `liveView`. Put runtime sequence/protocol, supervision, integrity, and verification into run details from RunObservation. Do not invent elapsed time from local launch or a fake last Envelope. Show unknown elapsed unless public evidence supplies it.

Success means **public validated runtime status `succeeded`**, not accepted approval, missing Overview row, idle transport, decision disappearance, or a timer. Independently show result verification state. Runtime success and downloadable result verification are separate facts.

## 8. Verified result bytes

After real terminal evidence, load complete OutputPage. Use only a verified source-result ArtifactMetadata for the selected public run and matching result artifact. Preserve exact download Reference and metadata with the download ticket.

```haskell
data VerifiedDownload = VerifiedDownload
  { downloadedBytes :: !BS.ByteString,
    downloadedSize :: !Int,
    downloadedSHA256 :: !Text
  }

fetchVerified :: C.Client -> C.Reference -> Int -> Text
  -> IO (Either C.ClientFailure VerifiedDownload)
fetchVerified client location size checksum = do
  result <- C.downloadVerified client location size checksum
  pure $ do
    bytes <- result
    let actualSize = BS.length bytes
        actualSHA256 = T.pack (show (hash bytes :: Digest SHA256))
    unless (actualSize == size && actualSHA256 == checksum) (Left C.InvalidResponse)
    pure (VerifiedDownload bytes actualSize actualSHA256)

verifiedDownloadLines :: VerifiedDownload -> [Text]
verifiedDownloadLines downloaded =
  [ "Verified source-result download",
    "Bytes  " <> T.pack (show (downloadedSize downloaded)),
    "SHA256 " <> downloadedSHA256 downloaded
  ]

saveDownloadedResult :: FilePath -> VerifiedDownload -> IO ()
saveDownloadedResult path downloaded = do
  when (not (isAbsolute path) || any (`elem` ['\NUL', '\n', '\r']) path) $
    ioError (userError "result destination must be one absolute single-line path")
  descriptor <- openFd path WriteOnly privateOutputFlags
  handle <- fdToHandle descriptor `onException` closeFd descriptor
  BS.hPut handle (downloadedBytes downloaded) `finally` hClose handle
```

Reuse existing exclusive/nofollow/privateOutputFlags. Do **not** use current `saveResultFile`, which `encode`s a Value and appends LF (`App.hs:889–896`). Source-result download is the native stored-result envelope. An exported code/value document is a distinct artifact. Neither can be silently substituted.

The duplicate size/hash computation above is intentional, tiny, and provides actual displayed measurements while `downloadVerified` owns transport verification. Keep bytes bounded at 64 MiB; do not decode a 64 MiB artifact into an unbounded terminal widget. Render its measured metadata plus the separately labeled bounded runtime preview. On authorization failure discard sensitive cached review/question/result data and disable actions.

## 9. Stale, expired, and uncertain authorization

Centralize service failure handling in App rather than adding a fallback at every button:

* `CredentialChanged`, `CredentialUnavailable`, `ClientClosed`, 401, and 403 suspend the session. Invalidate response generations, stop polling/downloads, clear displayed sensitive DTOs and cached ETags, and preserve any uncertain mutation separately in memory without exposing its body. No automatic reconnect under a new credential.
* `authority-changed` suspends the session and forbids resending retained old-epoch attempts. Explicit reconnect creates a new Client identity. References and PendingCommand values never migrate.
* `cursor-expired` or `view-expired` stops that poll generation and obtains a new complete Overview. No mutation is replayed. If scope/view changed, refresh capabilities/profiles before redisplaying authorized data.
* 412/stale-revision, expired/invalidated preparation, decision-not-head, ownership/supervision unavailable, and state-conflict invalidate that action's observed authority. Show current resource after refresh. Require a new explicit action against the newly displayed review/decision.
* 404 on an advertised required route is a visible service failure. It is not an empty workflow list, successful cancellation, or a reason to invoke the runner.
* 413/view-too-large is a visible bounded-view failure, not permission to truncate items.
* 429 backs off reads and retains mutation intent without resending. 503/transport failure after send remains uncertain. No retry timer touches ServiceSendWork.

Service backend handling must cover every path that currently accesses `stateConfig`, `stateRoot`, `stateRunning`, `startMachine`, `sendMachineControl`, or `readResultArtifactAt`. Rendering alone is not a security boundary.

## 10. Parent validation plan, not executed evidence

Add checks to existing owners, not a new framework or recorder:

1. `tui/test/Main.hs`: strict workflow/public-to-display parsing, missing nullable fields, NaturalDecimal strings, profile/workflow identity binding, five approval selectors, typed `Bool False`, recovery offer choice, real terminal-only status, and raw-byte preservation. Use existing `check` helper.
2. Same test owner: generation/single-flight reducers reject old response tickets and coalesce ticks without replacing original work. One accepted receipt does not produce RunSucceeded. An unreadable run or null runtime does not produce a fabricated snapshot.
3. Manager Client test owner: exact-URI observation preconditions, maximum-length epoch nonce, failed/wrong-host/untrusted TLS, changed credential before response installation, no redirect/retry, page set identity/expiry/meta/size mismatch, Last-Event-ID polling, authentication failures on download, and actual cancel/join of blocked request tasks.
4. Existing 140x36 rendering tests: every selector visible in full, approval hidden/disabled if clipped, service action labels, Unicode editor contents, public question false, offered retry, genuine success plus actual downloaded size/hash. Smaller size must refuse clipped approval.

Minimal runnable assertions to add once the proposed helpers exist:

```haskell
check "service false is typed JSON" $
  case answerBody flagDecision "False" of
    Right (Object fields) -> KM.lookup "value" fields == Just (Bool False)
    _ -> False

check "only matching refresh can finish" $
  finishRefresh (Ticket 4 8) (RefreshBusy (Ticket 4 9) True) == Nothing

check "ticks coalesce without replacing original request" $
  case beginRefresh (Ticket 4 10) (RefreshBusy (Ticket 4 9) False) of
    (RefreshBusy ticket dirty, started) -> ticket == Ticket 4 9 && dirty && not started
    _ -> False

check "raw result is not re-encoded" $
  let bytes = "{\"value\":false}\n" in
  downloadedBytes (VerifiedDownload bytes (BS.length bytes)
    (T.pack (show (hash bytes :: Digest SHA256)))) == bytes
```

`flagDecision` should be a directly constructed pure DecisionView in this test, not a credential-bearing fixture. The raw-byte assertion must also be backed by the parent HTTP/PTY journey, since a pure assertion cannot prove transport behavior.

Parent-owned commands, **not run here**:

```text
nix develop path:. -c cabal build all
nix develop path:. -c cabal test tui-model-test
```

Parent also owns relevant manager transport/client gates, boundary checks, and actual PTY acceptance. No paid backend gate is required for the deterministic local ACP adapter.

The real PTY journey must discover actual configured profile/workflow IDs, enter Unicode text, explicitly enqueue, display actual review and all five selectors, explicitly approve once, observe genuine public progress, submit typed false, choose only offered retry, observe runtime success, download through `Client.downloadVerified`, and compare/display the returned bytes' actual size/SHA256. Capture evidence from that journey, not from mocked completion or this proposal.

### Implementation boundaries still requiring parent work

This report gives complete critical Client functions, workflow/approval/decision/snapshot adapters, mutation bodies, lifecycle reducers, and rendering/download bodies. It is not a claimed compiling patch. Parent must finish the mechanical closed-schema leaf parsers and the App event/action wiring named above, implement/verify the promised workflow and Overview HTTP routes, compile against pinned TLS APIs, and execute mutation/PTY tests. None of those steps is represented as already done.

```acceptance-report
{
  "criteriaSatisfied": [
    {
      "id": "criterion-1",
      "status": "not-satisfied",
      "evidence": "Read-only source-grounded code proposal completed. Requested implementation acceptance cannot be claimed because no source changes or tests were authorized or executed by this agent."
    }
  ],
  "changedFiles": [],
  "testsAddedOrUpdated": [],
  "commandsRun": [],
  "validationOutput": [
    "Inspected bounded source reads in public Client, TUI owners, runtime observation types, selected test sources, and frozen OpenAPI schemas.",
    "Supervisor confirmed frozen Workflow/Overview DTOs and approved explicit version-1 client-profile JSON file surface.",
    "No compile, HTTP mutation, cancellation test, TLS test, or PTY journey executed."
  ],
  "residualRisks": [
    "Proposed code is uncompiled. Mechanical leaf DTO parsers and App event/action wiring remain parent implementation work.",
    "Parent must deliver and exercise /workflows and complete atomic /snapshot without fallback.",
    "Real HTTP mutations, exact review consent, typed false, offered retry, genuine terminal completion, and verified result download remain unexecuted here.",
    "Pinned TLS package API and dependency declarations require parent build validation."
  ],
  "noStagedFiles": true,
  "diffSummary": "No source diff. Only requested proposal report artifact written.",
  "reviewFindings": [
    "Client lacks Last-Event-ID polling and an opaque same-URI GET/ETag observation helper.",
    "Current hex nonce exceeds the 128-byte key bound for the longest admitted authority epoch.",
    "Current TUI local result saver re-encodes JSON and must not save remote verified artifact bytes.",
    "Public Workflow, Todo, RecoveryOption, RunSnapshot, and Decision dialects cannot be replaced with native JSON decoding or synthetic runtime envelopes."
  ],
  "manualNotes": "No Git operation or staging performed. Pre-existing index state was not inspected. This is a proposal, not implementation or executed acceptance evidence."
}
```
