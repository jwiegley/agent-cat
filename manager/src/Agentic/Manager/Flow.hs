{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | The manager log: one append-only log of flow records for each Store
-- stream identity.
--
-- A 'ManagerFlow' denotes the writer of the log of one stream for one Store
-- lifetime. The log is the file @flow/<stream>.ndjson@ in the manager's
-- private root, and its claim-check files live in @flow/claims/<stream>/@. The writer
-- lock is a leaf lock: no other lock is taken while it is held. It orders the
-- gap entries of the lifetime and the appends of the runtime writer, which
-- this module reaches only through "Agentic.Runtime".
--
-- Every manager body codec satisfies @decode (encode x) = Right x@ and refuses
-- a value that is not the exact encoding of its decoding. No bearer token,
-- credential verifier, idempotency key, page token or local path enters a
-- body.
module Agentic.Manager.Flow
  ( -- * Writer
    ManagerFlow,
    ManagerFlowFault (..),
    FlowRecordClass (..),
    ManagerFlowFailure (..),
    managerFlowPath,
    managerFlowClaims,
    openManagerFlow,
    closeManagerFlow,
    managerFlowBytes,
    managerFlowAllowance,
    gapEntryLimit,
    appendManagerAsk,
    appendManagerTell,
    appendManagerReply,
    appendLifetime,
    appendShutdown,

    -- * Command bodies
    CommandBody (..),
    CaptureReference (..),
    commandFlowBody,
    commandFromFlowBody,

    -- * Receipt bodies
    receiptFlowBody,
    receiptFromFlowBody,

    -- * Review bodies
    ReviewBody (..),
    reviewFlowBody,
    reviewFromFlowBody,

    -- * Relay bodies
    RelayKind (..),
    RelayBody (..),
    relayFlowBody,
    relayFromFlowBody,

    -- * Notice bodies
    Notice (..),
    RequestCause (..),
    Reconciliation (..),
    noReconciliation,
    CredentialEntry (..),
    Lifetime (..),
    MissingRecord (..),
    noticeFlowBody,
    noticeFromFlowBody,
  )
where

import Agentic.Manager.Protocol.Command (CommandReceipt, CommandState, Operation, mutationLedgerReserve, operationName, parseOperation, parseState, stateName)
import Agentic.Manager.Protocol.Preparation (ApprovalRequest (..))
import Agentic.Runtime
  ( About,
    Actor (Manager),
    Address (To),
    Content (ContentValue),
    FlowAppend (..),
    FlowCodec,
    FlowError (..),
    FlowLimitReached (..),
    FlowLog (RunLog),
    FlowWriter,
    Position,
    PrivateRoot,
    Record,
    RunId (..),
    Schema (..),
    aboutFromValue,
    aboutValue,
    appendAskWith,
    appendReplyWith,
    appendTellWith,
    closeFlowWriter,
    ensurePrivateDirectoryAt,
    flowExactKeys,
    flowField,
    flowInteger,
    flowObject,
    flowOptionalText,
    flowSha256,
    flowTextField,
    flowWriterBytes,
    isFlowSha256,
    maxFrameBytes,
    noAbout,
    openFlowLog,
    schemaFromName,
    schemaLog,
    schemaName,
  )
import Control.Concurrent.MVar (MVar, modifyMVar, newMVar, withMVar)
import Control.Exception (SomeAsyncException, SomeException, displayException, fromException, throwIO, try)
import Control.Monad (unless, when)
import Data.Aeson (Value (..), object, toJSON, (.=))
import qualified Data.Aeson as Aeson
import Data.Aeson.Types (parseEither)
import qualified Data.ByteString as BS
import Data.Char (isAscii, isAlphaNum)
import Data.Foldable (toList)
import Data.Int (Int64)
import Data.List (nub)
import Data.Sequence (Seq, (|>))
import qualified Data.Sequence as Seq
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE

-- ---------------------------------------------------------------------------
-- Writer
-- ---------------------------------------------------------------------------

-- | The writer of the manager log of one stream for one lifetime.
data ManagerFlow = ManagerFlow
  { managerLock :: !(MVar Gaps),
    -- | The runtime writer, or the reason why the log could not be opened.
    managerWriter :: !(Either Text FlowWriter),
    managerFault :: !(Maybe ManagerFlowFault)
  }

-- | The missing records that no gap notice names yet: at most
-- 'gapEntryLimit' named records and the count of the others.
data Gaps = Gaps !(Seq MissingRecord) !Integer

-- | A test fault. The appends that it selects fail before the writer takes
-- any other step. Test modes pass one. Production never does.
newtype ManagerFlowFault = ManagerFlowFault (Schema -> About -> IO Bool)

-- | The class of a manager record, which fixes the part of the ceiling that it
-- may use and what a failed append leaves behind.
data FlowRecordClass
  = -- | A record of an ordinary command that its operation needs before it
    -- commits or dispatches. It stays within the ceiling minus the reserve.
    -- A failed append refuses the operation and leaves no gap entry.
    Refusing
  | -- | A record of an ordinary command that follows a commit. It stays within
    -- the ceiling minus the reserve. A failed append leaves a gap entry.
    Following
  | -- | A record of a cancel or of the manager itself. It may use the whole
    -- ceiling. A failed append leaves a gap entry.
    Reserved
  deriving (Eq, Show)

-- | Why an append failed. A quota failure leaves the writer usable.
data ManagerFlowFailure
  = ManagerFlowQuota
  | ManagerFlowUnavailable !Text
  deriving (Eq, Show)

-- | A missing record, named by its schema and identifiers.
data MissingRecord = MissingRecord
  { missingSchema :: !Schema,
    missingAbout :: !About
  }
  deriving (Eq, Show)

-- | The most missing records that one gap notice names.
gapEntryLimit :: Int
gapEntryLimit = 256

-- | The path of the log of a stream in the manager's private root.
managerFlowPath :: Text -> [FilePath]
managerFlowPath stream = ["flow", T.unpack stream <> ".ndjson"]

-- | The directory of the claim-check files of the log of a stream. Each
-- stream has its own directory, so the claim checks of a log count toward the
-- ceiling of that log only.
managerFlowClaims :: Text -> [FilePath]
managerFlowClaims stream = ["flow", "claims", T.unpack stream]

-- | Open the log of the stream for one lifetime. The configured ledger ceiling
-- bounds the bytes that the writer reads. A log that cannot be opened gives a
-- writer whose every append fails.
openManagerFlow :: FlowCodec -> Maybe ManagerFlowFault -> PrivateRoot -> Text -> Int64 -> IO ManagerFlow
openManagerFlow codec fault root stream total = do
  opened <- synchronous $ do
    unless (validStream stream) (throwIO (FlowError "the stream identity is not a file name"))
    ensurePrivateDirectoryAt root ["flow"]
    fst <$> openFlowLog codec root (managerFlowPath stream) (managerFlowClaims stream) (toInteger total)
  lock <- newMVar (Gaps Seq.empty 0)
  pure (ManagerFlow lock (either (Left . T.pack . displayException) Right opened) fault)
  where
    validStream text = not (T.null text) && T.length text <= 128 && T.all (\c -> isAscii c && (isAlphaNum c || c == '_' || c == '-')) text

closeManagerFlow :: ManagerFlow -> IO ()
closeManagerFlow flow = withMVar (managerLock flow) $ \_ -> either (const (pure ())) closeFlowWriter (managerWriter flow)

-- | The bytes of the log and of its claim-check files, or 'Nothing' when the
-- log could not be opened.
managerFlowBytes :: ManagerFlow -> IO (Maybe Integer)
managerFlowBytes flow = withMVar (managerLock flow) $ \_ -> either (const (pure Nothing)) (fmap Just . flowWriterBytes) (managerWriter flow)

-- | The bytes that the log and its claim checks may reach with a record of the
-- class, under the configured @globalMutationLedgerBytes@: the whole ceiling
-- for a reserved record, and the ceiling minus the reserve of
-- 'mutationLedgerReserve' for every other record.
managerFlowAllowance :: Int64 -> FlowRecordClass -> Integer
managerFlowAllowance total = \case
  Reserved -> toInteger total
  _ -> toInteger (total - mutationLedgerReserve total)

appendManagerAsk :: ManagerFlow -> Int64 -> FlowRecordClass -> Schema -> Actor -> Address -> About -> Value -> IO (Either ManagerFlowFailure (Position, Record))
appendManagerAsk flow total recordClass schema from to about body =
  appendManager flow total recordClass schema (\writer mode -> appendAskWith writer mode schema from to about (ContentValue body)) about

appendManagerTell :: ManagerFlow -> Int64 -> FlowRecordClass -> Schema -> Actor -> Address -> About -> Value -> IO (Either ManagerFlowFailure (Position, Record))
appendManagerTell flow total recordClass schema from to about body =
  appendManager flow total recordClass schema (\writer mode -> appendTellWith writer mode schema from to about (ContentValue body)) about

appendManagerReply :: ManagerFlow -> Int64 -> FlowRecordClass -> Schema -> Position -> Actor -> Address -> About -> Value -> IO (Either ManagerFlowFailure (Position, Record))
appendManagerReply flow total recordClass schema position from to about body =
  appendManager flow total recordClass schema (\writer mode -> appendReplyWith writer mode schema position from to about (ContentValue body)) about

-- | Append one record under the writer lock. A gap notice that names the
-- missing records of the lifetime comes first. When the gap notice cannot be
-- appended, the record is not attempted and fails in the same way. A failed
-- record of a class other than 'Refusing' becomes a gap entry.
appendManager :: ManagerFlow -> Int64 -> FlowRecordClass -> Schema -> (FlowWriter -> FlowAppend -> IO (Position, Record)) -> About -> IO (Either ManagerFlowFailure (Position, Record))
appendManager flow total recordClass schema appendRecord about = modifyMVar (managerLock flow) $ \gaps@(Gaps entries uncounted) -> do
  pending <-
    if Seq.null entries
      then pure (Right gaps)
      else do
        let notice = GapNotice (toList entries) uncounted
        noticed <- attempt Reserved FlowNotice noAbout (\writer mode -> appendTellWith writer mode FlowNotice Manager (To Manager) noAbout (ContentValue (noticeFlowBody notice)))
        pure (either Left (const (Right (Gaps Seq.empty 0))) noticed)
  outcome <- case pending of
    Left failure -> pure (Left failure)
    Right _ -> attempt recordClass schema about appendRecord
  let remaining = either (const gaps) id pending
  pure $ case outcome of
    Right appended -> (remaining, Right appended)
    Left failure
      | recordClass == Refusing -> (remaining, Left failure)
      | otherwise -> (addGap (MissingRecord schema about) remaining, Left failure)
  where
    attempt :: FlowRecordClass -> Schema -> About -> (FlowWriter -> FlowAppend -> IO (Position, Record)) -> IO (Either ManagerFlowFailure (Position, Record))
    attempt current target identifiers action
      | schemaLog target == RunLog = pure (Left (ManagerFlowUnavailable ("the " <> schemaName target <> " schema belongs to the run log")))
      | otherwise = case managerWriter flow of
          Left why -> pure (Left (ManagerFlowUnavailable why))
          Right writer -> do
            injected <- maybe (pure False) (\(ManagerFlowFault selects) -> selects target identifiers) (managerFault flow)
            if injected
              then pure (Left (ManagerFlowUnavailable "the test fault failed this append"))
              else do
                let mode = FlowAppend (target `elem` [FlowCommand, FlowReview, FlowRelay]) (Just (managerFlowAllowance total current))
                result <- synchronous (action writer mode)
                pure $ case result of
                  Right appended -> Right appended
                  Left failure
                    | Just FlowLimitReached <- fromException failure -> Left ManagerFlowQuota
                    | otherwise -> Left (ManagerFlowUnavailable (T.pack (displayException failure)))

addGap :: MissingRecord -> Gaps -> Gaps
addGap missing (Gaps entries uncounted)
  | Seq.length entries < gapEntryLimit = Gaps (entries |> missing) uncounted
  | otherwise = Gaps entries (uncounted + 1)

-- | Run an action and return its synchronous exception. An asynchronous
-- exception propagates.
synchronous :: IO a -> IO (Either SomeException a)
synchronous action =
  try action >>= \case
    Left failure | Just (_ :: SomeAsyncException) <- fromException failure -> throwIO failure
    other -> pure other

-- | Append the lifetime notice of a Store lifetime, as a reserved record.
appendLifetime :: ManagerFlow -> Int64 -> Lifetime -> IO (Either ManagerFlowFailure (Position, Record))
appendLifetime flow total lifetime = appendManagerTell flow total Reserved FlowNotice Manager (To Manager) noAbout (noticeFlowBody (LifetimeNotice lifetime))

-- | Append the shutdown notice of the lifetime of the process generation, as a
-- reserved record.
appendShutdown :: ManagerFlow -> Int64 -> Text -> IO (Either ManagerFlowFailure (Position, Record))
appendShutdown flow total generation = appendManagerTell flow total Reserved FlowNotice Manager (To Manager) noAbout (noticeFlowBody (ShutdownNotice generation))

-- ---------------------------------------------------------------------------
-- Command bodies
-- ---------------------------------------------------------------------------

-- | An admitted command without its idempotency key. A JSON request body is
-- its strictly decoded value. A capture is named by identifier, digest and
-- size, and its bytes are not copied.
data CommandBody = CommandBody
  { commandBodyOperation :: !Operation,
    commandBodyProfile :: !Text,
    commandBodyMethod :: !Text,
    commandBodyResource :: !Text,
    commandBodyMediaType :: !Text,
    commandBodyPrecondition :: !(Maybe Text),
    commandBodyValue :: !(Maybe Value),
    commandBodyCapture :: !(Maybe CaptureReference)
  }
  deriving (Eq, Show)

data CaptureReference = CaptureReference
  { captureReferenceId :: !Text,
    captureReferenceSha256 :: !Text,
    captureReferenceBytes :: !Integer
  }
  deriving (Eq, Show)

commandFlowBody :: CommandBody -> Value
commandFlowBody command =
  object
    [ "operation" .= operationName (commandBodyOperation command),
      "profile" .= commandBodyProfile command,
      "method" .= commandBodyMethod command,
      "resource" .= commandBodyResource command,
      "mediaType" .= commandBodyMediaType command,
      "precondition" .= commandBodyPrecondition command,
      "body" .= fmap (\value -> object ["json" .= value]) (commandBodyValue command),
      "capture" .= fmap captureValue (commandBodyCapture command)
    ]
  where
    captureValue capture =
      object
        [ "id" .= captureReferenceId capture,
          "sha256" .= captureReferenceSha256 capture,
          "bytes" .= captureReferenceBytes capture
        ]

commandFromFlowBody :: Value -> Either Text CommandBody
commandFromFlowBody value = do
  fields <- flowObject "command body" value
  flowExactKeys "command body" ["operation", "profile", "method", "resource", "mediaType", "precondition", "body", "capture"] fields
  operationText <- flowTextField "command body" fields "operation"
  operation <- maybe (Left ("command body has unknown operation '" <> operationText <> "'")) Right (parseOperation operationText)
  precondition <- flowField "command body" fields "precondition" >>= flowOptionalText "command precondition"
  payload <- flowField "command body" fields "body" >>= \case
    Null -> Right Nothing
    wrapped -> do
      inner <- flowObject "command request body" wrapped
      flowExactKeys "command request body" ["json"] inner
      Just <$> flowField "command request body" inner "json"
  capture <- flowField "command body" fields "capture" >>= \case
    Null -> Right Nothing
    reference -> do
      inner <- flowObject "command capture" reference
      flowExactKeys "command capture" ["id", "sha256", "bytes"] inner
      digest <- flowTextField "command capture" inner "sha256"
      unless (isFlowSha256 digest) (Left "command capture sha256 is not a lowercase SHA-256")
      bytes <- flowField "command capture" inner "bytes" >>= flowInteger "command capture bytes"
      unless (bytes >= 0) (Left "command capture bytes is negative")
      Just <$> (CaptureReference <$> flowTextField "command capture" inner "id" <*> pure digest <*> pure bytes)
  command <-
    CommandBody operation
      <$> flowTextField "command body" fields "profile"
      <*> flowTextField "command body" fields "method"
      <*> flowTextField "command body" fields "resource"
      <*> flowTextField "command body" fields "mediaType"
      <*> pure precondition
      <*> pure payload
      <*> pure capture
  exact "command body" commandFlowBody command value

-- ---------------------------------------------------------------------------
-- Receipt bodies
-- ---------------------------------------------------------------------------

-- | The frozen @/v1@ receipt JSON.
receiptFlowBody :: CommandReceipt -> Value
receiptFlowBody = toJSON

receiptFromFlowBody :: Value -> Either Text CommandReceipt
receiptFromFlowBody value = do
  receipt <- either (\why -> Left ("receipt body: " <> T.pack why)) Right (parseEither Aeson.parseJSON value)
  exact "receipt body" receiptFlowBody receipt value

-- ---------------------------------------------------------------------------
-- Review bodies
-- ---------------------------------------------------------------------------

-- | A published review: the public review bytes and their SHA-256, the private
-- binding bytes and their digest, the expiry, the preparation identifier and
-- the five selectors that an approval of this review must present.
data ReviewBody = ReviewBody
  { reviewBodyPreparation :: !Text,
    reviewBodyBytes :: !BS.ByteString,
    reviewBodySha256 :: !Text,
    reviewBodyBinding :: !BS.ByteString,
    reviewBodyBindingDigest :: !Text,
    reviewBodyExpires :: !Text,
    reviewBodySelectors :: !ApprovalRequest
  }
  deriving (Eq, Show)

-- | The review body, or a refusal when a byte field is not UTF-8.
reviewFlowBody :: ReviewBody -> Either Text Value
reviewFlowBody review = do
  bytes <- utf8 "review bytes" (reviewBodyBytes review)
  binding <- utf8 "review binding" (reviewBodyBinding review)
  let ApprovalRequest digest request profile descriptor generation = reviewBodySelectors review
  pure $
    object
      [ "preparation" .= reviewBodyPreparation review,
        "review" .= bytes,
        "reviewSha256" .= reviewBodySha256 review,
        "binding" .= binding,
        "bindingSha256" .= reviewBodyBindingDigest review,
        "expiresAt" .= reviewBodyExpires review,
        "selectors"
          .= object
            [ "reviewDigest" .= digest,
              "requestRevision" .= request,
              "profileRevision" .= profile,
              "descriptorRevision" .= descriptor,
              "processGeneration" .= generation
            ]
      ]

-- | Decode a review body and verify both digests against their bytes.
reviewFromFlowBody :: Value -> Either Text ReviewBody
reviewFromFlowBody value = do
  fields <- flowObject "review body" value
  flowExactKeys "review body" ["preparation", "review", "reviewSha256", "binding", "bindingSha256", "expiresAt", "selectors"] fields
  bytes <- TE.encodeUtf8 <$> flowTextField "review body" fields "review"
  binding <- TE.encodeUtf8 <$> flowTextField "review body" fields "binding"
  reviewDigest <- flowTextField "review body" fields "reviewSha256"
  bindingDigest <- flowTextField "review body" fields "bindingSha256"
  unless (flowSha256 bytes == reviewDigest) (Left "review body reviewSha256 does not match its review bytes")
  unless (flowSha256 binding == bindingDigest) (Left "review body bindingSha256 does not match its binding bytes")
  selectorFields <- flowField "review body" fields "selectors" >>= flowObject "review selectors"
  let selectorKeys = ["reviewDigest", "requestRevision", "profileRevision", "descriptorRevision", "processGeneration"]
  flowExactKeys "review selectors" selectorKeys selectorFields
  selectors <- traverse (flowTextField "review selectors" selectorFields) selectorKeys
  selectorValue <- case selectors of
    [digest, request, profile, descriptor, generation] -> Right (ApprovalRequest digest request profile descriptor generation)
    _ -> Left "review selectors are incomplete"
  review <-
    ReviewBody
      <$> flowTextField "review body" fields "preparation"
      <*> pure bytes
      <*> pure reviewDigest
      <*> pure binding
      <*> pure bindingDigest
      <*> flowTextField "review body" fields "expiresAt"
      <*> pure selectorValue
  exactEither "review body" reviewFlowBody review value

-- ---------------------------------------------------------------------------
-- Relay bodies
-- ---------------------------------------------------------------------------

data RelayKind = RelayStart | RelayControl
  deriving (Eq, Show, Enum, Bounded)

-- | One native start or control frame for one worker, with its exact bytes.
data RelayBody = RelayBody
  { relayBodyKind :: !RelayKind,
    relayBodyManagerRun :: !Text,
    relayBodyNativeRun :: !RunId,
    relayBodyCommand :: !Text,
    relayBodyFrame :: !BS.ByteString
  }
  deriving (Eq, Show)

relayKindName :: RelayKind -> Text
relayKindName = \case
  RelayStart -> "start"
  RelayControl -> "control"

-- | The relay body, or a refusal when the frame is above 'maxFrameBytes' or
-- is not UTF-8.
relayFlowBody :: RelayBody -> Either Text Value
relayFlowBody relay = do
  when (BS.length (relayBodyFrame relay) > maxFrameBytes) (Left "relay frame exceeds the frame bound")
  frame <- utf8 "relay frame" (relayBodyFrame relay)
  pure $
    object
      [ "kind" .= relayKindName (relayBodyKind relay),
        "managerRun" .= relayBodyManagerRun relay,
        "nativeRun" .= runIdText (relayBodyNativeRun relay),
        "command" .= relayBodyCommand relay,
        "frame" .= frame
      ]

relayFromFlowBody :: Value -> Either Text RelayBody
relayFromFlowBody value = do
  fields <- flowObject "relay body" value
  flowExactKeys "relay body" ["kind", "managerRun", "nativeRun", "command", "frame"] fields
  kind <- flowTextField "relay body" fields "kind" >>= named "relay kind" relayKindName
  relay <-
    RelayBody kind
      <$> flowTextField "relay body" fields "managerRun"
      <*> (RunId <$> flowTextField "relay body" fields "nativeRun")
      <*> flowTextField "relay body" fields "command"
      <*> (TE.encodeUtf8 <$> flowTextField "relay body" fields "frame")
  exactEither "relay body" relayFlowBody relay value

-- ---------------------------------------------------------------------------
-- Notice bodies
-- ---------------------------------------------------------------------------

-- | Why a request ended without a run.
data RequestCause = RequestWithdrawn | RequestDiscarded | RequestRefused | RequestInvalidated | RequestReviewExpired | RequestPreparationFailed
  deriving (Eq, Show, Enum, Bounded)

requestCauseName :: RequestCause -> Text
requestCauseName = \case
  RequestWithdrawn -> "withdrawn"
  RequestDiscarded -> "discarded"
  RequestRefused -> "refused"
  RequestInvalidated -> "invalidated"
  RequestReviewExpired -> "review-expired"
  RequestPreparationFailed -> "preparation-failed"

-- | The rows that the restart reconciliation of one lifetime changed.
data Reconciliation = Reconciliation
  { reconciledPreparations :: !Integer,
    reconciledRequests :: !Integer,
    reconciledRuns :: !Integer,
    reconciledCommands :: !Integer,
    reconciledReservations :: !Integer,
    reconciledObservations :: !Integer,
    reconciledUploads :: !Integer
  }
  deriving (Eq, Show)

noReconciliation :: Reconciliation
noReconciliation = Reconciliation 0 0 0 0 0 0 0

-- | One credential of the Store: its client, its identifier, its status and
-- the scopes and profiles that it holds. The verifier never appears.
data CredentialEntry = CredentialEntry
  { credentialEntryClient :: !Text,
    credentialEntryId :: !Text,
    credentialEntryStatus :: !Text,
    credentialEntryScopes :: ![Text],
    credentialEntryProfiles :: ![Text]
  }
  deriving (Eq, Show)

-- | The start of one Store lifetime: its process generation, the restart
-- reconciliation, the credentials of the Store and the number of credentials
-- that the list omits.
data Lifetime = Lifetime
  { lifetimeGeneration :: !Text,
    lifetimeReconciliation :: !Reconciliation,
    lifetimeCredentials :: ![CredentialEntry],
    lifetimeOmittedCredentials :: !Integer
  }
  deriving (Eq, Show)

data Notice
  = -- | A later commit of the state of the command that the record names.
    CommandChanged !CommandState !(Maybe Text)
  | -- | The end of a review: the preparation and the reason.
    ReviewEnded !Text !Text
  | -- | The end of a request without a run.
    RequestEnded !Text !RequestCause
  | LifetimeNotice !Lifetime
  | -- | The orderly end of the lifetime of the process generation.
    ShutdownNotice !Text
  | -- | The missing records of the lifetime: at most 'gapEntryLimit' named
    -- records and the count of the others.
    GapNotice ![MissingRecord] !Integer
  deriving (Eq, Show)

noticeFlowBody :: Notice -> Value
noticeFlowBody = \case
  CommandChanged state refusal -> object ["notice" .= ("command-changed" :: Text), "state" .= stateName state, "refusal" .= refusal]
  ReviewEnded preparation reason -> object ["notice" .= ("review-ended" :: Text), "preparation" .= preparation, "reason" .= reason]
  RequestEnded request cause -> object ["notice" .= ("request-ended" :: Text), "request" .= request, "cause" .= requestCauseName cause]
  LifetimeNotice lifetime ->
    object
      [ "notice" .= ("lifetime" :: Text),
        "processGeneration" .= lifetimeGeneration lifetime,
        "reconciliation" .= reconciliationValue (lifetimeReconciliation lifetime),
        "credentials" .= map credentialValue (lifetimeCredentials lifetime),
        "omittedCredentials" .= lifetimeOmittedCredentials lifetime
      ]
  ShutdownNotice generation -> object ["notice" .= ("shutdown" :: Text), "processGeneration" .= generation]
  GapNotice missing more ->
    object
      [ "notice" .= ("gap" :: Text),
        "missing" .= map (\entry -> object ["schema" .= schemaName (missingSchema entry), "about" .= aboutValue (missingAbout entry)]) missing,
        "more" .= more
      ]
  where
    reconciliationValue counts =
      object
        [ "preparations" .= reconciledPreparations counts,
          "requests" .= reconciledRequests counts,
          "runs" .= reconciledRuns counts,
          "commands" .= reconciledCommands counts,
          "reservations" .= reconciledReservations counts,
          "observations" .= reconciledObservations counts,
          "uploads" .= reconciledUploads counts
        ]
    credentialValue entry =
      object
        [ "client" .= credentialEntryClient entry,
          "credential" .= credentialEntryId entry,
          "status" .= credentialEntryStatus entry,
          "scopes" .= credentialEntryScopes entry,
          "profiles" .= credentialEntryProfiles entry
        ]

noticeFromFlowBody :: Value -> Either Text Notice
noticeFromFlowBody value = do
  fields <- flowObject "notice body" value
  kind <- flowTextField "notice body" fields "notice"
  let keys names = flowExactKeys ("notice body " <> kind) ("notice" : names) fields
      text = flowTextField ("notice body " <> kind) fields
  notice <- case kind of
    "command-changed" -> do
      keys ["state", "refusal"]
      stateText <- text "state"
      state <- maybe (Left ("notice body has unknown command state '" <> stateText <> "'")) Right (parseState stateText)
      CommandChanged state <$> (flowField "notice body" fields "refusal" >>= flowOptionalText "notice refusal")
    "review-ended" -> keys ["preparation", "reason"] >> (ReviewEnded <$> text "preparation" <*> text "reason")
    "request-ended" -> do
      keys ["request", "cause"]
      RequestEnded <$> text "request" <*> (text "cause" >>= named "request cause" requestCauseName)
    "lifetime" -> do
      keys ["processGeneration", "reconciliation", "credentials", "omittedCredentials"]
      counts <- flowField "notice body" fields "reconciliation" >>= reconciliation
      credentials <- flowField "notice body" fields "credentials" >>= array "notice credentials" >>= traverse credential
      omitted <- flowField "notice body" fields "omittedCredentials" >>= count "notice omittedCredentials"
      generation <- text "processGeneration"
      pure (LifetimeNotice (Lifetime generation counts credentials omitted))
    "shutdown" -> keys ["processGeneration"] >> (ShutdownNotice <$> text "processGeneration")
    "gap" -> do
      keys ["missing", "more"]
      missing <- flowField "notice body" fields "missing" >>= array "gap missing" >>= traverse missingRecord
      more <- flowField "notice body" fields "more" >>= count "gap more"
      when (length missing > gapEntryLimit) (Left "gap notice names more than 256 missing records")
      when (null missing) (Left "gap notice names no missing record")
      when (more > 0 && length missing < gapEntryLimit) (Left "gap notice counts records that it could name")
      pure (GapNotice missing more)
    _ -> Left ("notice body has unknown notice '" <> kind <> "'")
  exact "notice body" noticeFlowBody notice value
  where
    reconciliation raw = do
      counts <- flowObject "reconciliation" raw
      let names = ["preparations", "requests", "runs", "commands", "reservations", "observations", "uploads"]
      flowExactKeys "reconciliation" names counts
      values <- traverse (\name -> flowField "reconciliation" counts name >>= count "reconciliation count") names
      case values of
        [a, b, c, d, e, f, g] -> Right (Reconciliation a b c d e f g)
        _ -> Left "reconciliation is incomplete"
    credential raw = do
      entry <- flowObject "credential entry" raw
      flowExactKeys "credential entry" ["client", "credential", "status", "scopes", "profiles"] entry
      status <- flowTextField "credential entry" entry "status"
      unless (status `elem` ["active", "expired", "revoked"]) (Left ("credential entry has unknown status '" <> status <> "'"))
      scopes <- flowField "credential entry" entry "scopes" >>= array "credential scopes" >>= traverse (textValue "credential scope")
      unless (all (`elem` ["observe", "submit", "control", "export"]) scopes && nub scopes == scopes) (Left "credential entry has an invalid scope list")
      profiles <- flowField "credential entry" entry "profiles" >>= array "credential profiles" >>= traverse (textValue "credential profile")
      CredentialEntry
        <$> flowTextField "credential entry" entry "client"
        <*> flowTextField "credential entry" entry "credential"
        <*> pure status
        <*> pure scopes
        <*> pure profiles
    missingRecord raw = do
      entry <- flowObject "missing record" raw
      flowExactKeys "missing record" ["schema", "about"] entry
      name <- flowTextField "missing record" entry "schema"
      schema <- maybe (Left ("missing record has unknown schema '" <> name <> "'")) Right (schemaFromName name)
      MissingRecord schema <$> (flowField "missing record" entry "about" >>= aboutFromValue)
    count what raw = do
      number <- flowInteger what raw
      unless (number >= 0) (Left (what <> " is negative"))
      pure number

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- | Refuse a value that is not the exact encoding of its decoding.
exact :: Text -> (a -> Value) -> a -> Value -> Either Text a
exact what encode decoded value
  | encode decoded == value = Right decoded
  | otherwise = Left (what <> " is not the exact encoding of its value")

exactEither :: Text -> (a -> Either Text Value) -> a -> Value -> Either Text a
exactEither what encode decoded value = do
  encoded <- encode decoded
  unless (encoded == value) (Left (what <> " is not the exact encoding of its value"))
  pure decoded

utf8 :: Text -> BS.ByteString -> Either Text Text
utf8 what bytes = either (const (Left (what <> " are not UTF-8"))) Right (TE.decodeUtf8' bytes)

named :: (Enum a, Bounded a) => Text -> (a -> Text) -> Text -> Either Text a
named what name text = case [value | value <- [minBound .. maxBound], name value == text] of
  [value] -> Right value
  _ -> Left ("unknown " <> what <> " '" <> text <> "'")

array :: Text -> Value -> Either Text [Value]
array what = \case
  Array items -> Right (toList items)
  _ -> Left (what <> " is not an array")

textValue :: Text -> Value -> Either Text Text
textValue what = \case
  String content -> Right content
  _ -> Left (what <> " is not a string")
