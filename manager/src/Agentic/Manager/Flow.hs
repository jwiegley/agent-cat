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
-- a value that is not the exact encoding of its decoding. A review body holds
-- the exact binding bytes, which name the frontend invocation path, the
-- run-root identity and the target arguments. No bearer token, credential
-- verifier, idempotency key or page token enters a record.
module Agentic.Manager.Flow
  ( -- * Writer
    ManagerFlow,
    ManagerFlowFault (..),
    FlowRecordClass (..),
    ManagerFlowFailure (..),
    ManagerFlowOpenFailure (..),
    managerFlowOpenFailure,
    managerFlowOpenWord,
    managerFlowPath,
    managerFlowClaims,
    openManagerFlow,
    closeManagerFlow,
    managerFlowBytes,
    managerFlowCeiling,
    managerFlowAllowance,
    managerFlowContent,
    noteManagerGap,
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

    -- * Administration bodies
    AdministrationOperation (..),
    AdministrationBody (..),
    administrationFlowBody,
    administrationFromFlowBody,
    administrationReceiptFromFlowBody,

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

    -- * Reader
    ManagerValue (..),
    ManagerLogReport (..),
    readManagerLog,
    LogPosition (..),
    ReviewJoin (..),
    RelayJoin (..),
    ControlJoin (..),
    CommandJoin (..),
    AnswerJoin (..),
    ConsentCheck (..),
    LifetimeJoin (..),
    FlowJoin (..),
    joinFlows,
    joinUndecided,
    joinUnresolvedDelivery,
    joinPendingReview,
    joinLostLifetimes,
    flowJoinProblems,
    flowJoinVerified,
    flowJoinUncertain,
    flowJoinSummaryValue,
  )
where

import Agentic.Manager.Protocol.Command (CommandReceipt (..), CommandState (Refused), Operation (Answer, Approve, Discard), mutationLedgerReserve, operationName, parseOperation, parseState, stateName)
import Agentic.Manager.Protocol.Preparation (ApprovalRequest (..))
import Agentic.Runtime
  ( About (..),
    Actor (Manager, Principal),
    Authority (Credential),
    FlowEntry (..),
    FlowReport (..),
    Start (..),
    closePrivateRoot,
    flowAcknowledgements,
    flowReportProblems,
    flowReportValue,
    flowUncertain,
    openPrivateRoot,
    readFlowLogAt,
    startFromBody,
    Address (To),
    Content (ContentValue, ContentEvent),
    FlowAppend (..),
    FlowCodec,
    FlowError (..),
    FlowLimitReached (..),
    FlowOpenRefusal (..),
    FlowLog (ManagerLog, RunLog),
    FlowWriter,
    Position (..),
    PrivateRoot,
    Record (..),
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
    readFlowContentAt,
    schemaFromName,
    schemaLog,
    schemaName,
  )
import Control.Concurrent.MVar (MVar, modifyMVar, newMVar, withMVar)
import Control.Exception (SomeAsyncException, SomeException, bracket, displayException, fromException, throwIO, try)
import Control.Monad (unless, when)
import Data.Aeson (Value (..), object, toJSON, (.=))
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.KeyMap as KeyMap
import Data.Aeson.Types (parseEither)
import qualified Data.ByteString as BS
import Data.Char (isAscii, isAlphaNum)
import Data.Foldable (toList)
import Data.Int (Int64)
import Data.List (nub)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isJust, isNothing, listToMaybe)
import Data.Sequence (Seq, (|>))
import qualified Data.Sequence as Seq
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import System.FilePath (dropExtension, takeDirectory, takeFileName)

-- ---------------------------------------------------------------------------
-- Writer
-- ---------------------------------------------------------------------------

-- | The writer of the manager log of one stream for one lifetime.
data ManagerFlow = ManagerFlow
  { managerLock :: !(MVar Gaps),
    -- | The runtime writer, or the reason why the log could not be opened.
    managerWriter :: !(Either ManagerFlowOpenFailure FlowWriter),
    managerFault :: !(Maybe ManagerFlowFault),
    managerRoot :: !PrivateRoot,
    managerStream :: !Text,
    managerCeiling :: !Int64
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

-- | Why the log of a lifetime could not be opened. Each reason has one fixed
-- word, which is the only text of the reason that leaves the writer.
data ManagerFlowOpenFailure
  = -- | The log holds more bytes than the configured ledger ceiling.
    ManagerFlowOversized
  | -- | A complete line of the log fails strict decoding.
    ManagerFlowUndecodable
  | -- | Any other failure of the open, such as an I/O failure.
    ManagerFlowIOFailure
  deriving (Eq, Show)

-- | The fixed word of an open failure.
managerFlowOpenWord :: ManagerFlowOpenFailure -> Text
managerFlowOpenWord = \case
  ManagerFlowOversized -> "oversized"
  ManagerFlowUndecodable -> "undecodable"
  ManagerFlowIOFailure -> "io-failure"

-- | The reason why the log of the lifetime could not be opened, or 'Nothing'
-- when the writer is open.
managerFlowOpenFailure :: ManagerFlow -> Maybe ManagerFlowOpenFailure
managerFlowOpenFailure = either Just (const Nothing) . managerWriter

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
-- writer whose every append fails with the fixed word of the reason, and the
-- text of the exception is dropped.
openManagerFlow :: FlowCodec -> Maybe ManagerFlowFault -> PrivateRoot -> Text -> Int64 -> IO ManagerFlow
openManagerFlow codec fault root stream total = do
  opened <- synchronous $ do
    unless (validStream stream) (throwIO (FlowError "the stream identity is not a file name"))
    ensurePrivateDirectoryAt root ["flow"]
    fst <$> openFlowLog codec root (managerFlowPath stream) (managerFlowClaims stream) (toInteger total)
  lock <- newMVar (Gaps Seq.empty 0)
  pure (ManagerFlow lock (either (Left . openFailure) Right opened) fault root stream total)
  where
    openFailure failure = case fromException failure of
      Just FlowLogOversized -> ManagerFlowOversized
      Just FlowLogUndecodable -> ManagerFlowUndecodable
      Nothing -> ManagerFlowIOFailure
    validStream text = not (T.null text) && T.length text <= 128 && T.all (\c -> isAscii c && (isAlphaNum c || c == '_' || c == '-')) text

closeManagerFlow :: ManagerFlow -> IO ()
closeManagerFlow flow = withMVar (managerLock flow) $ \_ -> either (const (pure ())) closeFlowWriter (managerWriter flow)

-- | The bytes of the log and of its claim-check files, or 'Nothing' when the
-- log could not be opened.
managerFlowBytes :: ManagerFlow -> IO (Maybe Integer)
managerFlowBytes flow = withMVar (managerLock flow) $ \_ -> either (const (pure Nothing)) (fmap Just . flowWriterBytes) (managerWriter flow)

-- | The configured @globalMutationLedgerBytes@ with which the log of the
-- lifetime was opened. A caller that holds no configuration uses it as the
-- ceiling of its appends.
managerFlowCeiling :: ManagerFlow -> Int64
managerFlowCeiling = managerCeiling

-- | The bytes that the log and its claim checks may reach with a record of the
-- class, under the configured @globalMutationLedgerBytes@: the whole ceiling
-- for a reserved record, and the ceiling minus the reserve of
-- 'mutationLedgerReserve' for every other record.
managerFlowAllowance :: Int64 -> FlowRecordClass -> Integer
managerFlowAllowance total = \case
  Reserved -> toInteger total
  _ -> toInteger (total - mutationLedgerReserve total)

-- | The body value of a record that this writer appended, decoded from the
-- appended bytes. A claim check is read from the claim-check directory of the
-- log, and its size, digest and exact encoding are verified.
managerFlowContent :: ManagerFlow -> Record -> IO (Either Text Value)
managerFlowContent flow record = do
  content <- synchronous (readFlowContentAt (managerRoot flow) (managerFlowClaims (managerStream flow)) (recBody record))
  pure $ case content of
    Left failure -> Left (T.pack (displayException failure))
    Right (Left why) -> Left why
    Right (Right (ContentValue value)) -> Right value
    Right (Right (ContentEvent _)) -> Left "a manager record holds an event sequence number"

-- | Keep a gap entry for a record that the manager did not attempt, because
-- the record that it answers is missing. The next appended record is preceded
-- by the gap notice that names it.
noteManagerGap :: ManagerFlow -> MissingRecord -> IO ()
noteManagerGap flow missing = modifyMVar (managerLock flow) (\gaps -> pure (addGap missing gaps, ()))

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
          Left why -> pure (Left (ManagerFlowUnavailable (managerFlowOpenWord why)))
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
-- Administration bodies
-- ---------------------------------------------------------------------------

-- | A credential operation of the local administration channel.
data AdministrationOperation = AdministerIssue | AdministerRotate | AdministerRevoke
  deriving (Eq, Show, Enum, Bounded)

administrationOperationName :: AdministrationOperation -> Text
administrationOperationName = \case
  AdministerIssue -> "issue-credential"
  AdministerRotate -> "rotate-credential"
  AdministerRevoke -> "revoke-credential"

-- | An admitted credential operation of the local administration channel: the
-- client, the credential that the operation issues, rotates to or revokes, the
-- credential that a rotation supersedes, and the label, scopes, profiles and
-- expiry of the credential. The bearer, its verifier and the output file never
-- appear.
data AdministrationBody = AdministrationBody
  { administrationOperation :: !AdministrationOperation,
    administrationClient :: !Text,
    administrationCredential :: !Text,
    administrationPrevious :: !(Maybe Text),
    administrationLabel :: !Text,
    administrationScopes :: ![Text],
    administrationProfiles :: ![Text],
    administrationExpires :: !Text
  }
  deriving (Eq, Show)

administrationFlowBody :: AdministrationBody -> Value
administrationFlowBody command =
  object
    [ "administration" .= administrationOperationName (administrationOperation command),
      "client" .= administrationClient command,
      "credential" .= administrationCredential command,
      "previousCredential" .= administrationPrevious command,
      "label" .= administrationLabel command,
      "scopes" .= administrationScopes command,
      "profiles" .= administrationProfiles command,
      "expiresAt" .= administrationExpires command
    ]

administrationFromFlowBody :: Value -> Either Text AdministrationBody
administrationFromFlowBody value = do
  fields <- flowObject "administration body" value
  flowExactKeys "administration body" ["administration", "client", "credential", "previousCredential", "label", "scopes", "profiles", "expiresAt"] fields
  operation <- flowTextField "administration body" fields "administration" >>= named "administration operation" administrationOperationName
  previous <- flowField "administration body" fields "previousCredential" >>= flowOptionalText "administration previousCredential"
  scopes <- flowField "administration body" fields "scopes" >>= array "administration scopes" >>= traverse (textValue "administration scope")
  unless (all (`elem` ["observe", "submit", "control", "export"]) scopes && nub scopes == scopes) (Left "administration body has an invalid scope list")
  profiles <- flowField "administration body" fields "profiles" >>= array "administration profiles" >>= traverse (textValue "administration profile")
  command <-
    AdministrationBody operation
      <$> flowTextField "administration body" fields "client"
      <*> flowTextField "administration body" fields "credential"
      <*> pure previous
      <*> flowTextField "administration body" fields "label"
      <*> pure scopes
      <*> pure profiles
      <*> flowTextField "administration body" fields "expiresAt"
  exact "administration body" administrationFlowBody command value

-- | The receipt of a credential operation is the frozen local administration
-- response that the operator receives: its version, its operation, and either
-- its metadata-only result or its error.
administrationReceiptFromFlowBody :: Value -> Either Text Value
administrationReceiptFromFlowBody value = do
  fields <- flowObject "administration receipt" value
  succeeded <- flowField "administration receipt" fields "ok" >>= \case
    Bool flag -> Right flag
    _ -> Left "administration receipt ok is not a boolean"
  flowExactKeys "administration receipt" ["version", "operation", "ok", if succeeded then "result" else "error"] fields
  version <- flowField "administration receipt" fields "version" >>= flowInteger "administration receipt version"
  unless (version == 1) (Left "administration receipt has an unknown version")
  _ <- flowTextField "administration receipt" fields "operation" >>= named "administration operation" administrationOperationName
  _ <- flowField "administration receipt" fields (if succeeded then "result" else "error") >>= flowObject "administration receipt outcome"
  pure value

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

-- | The frame that a relay carries: a start or discard decision for a
-- prepared worker, or a native control for a running worker.
data RelayKind = RelayStart | RelayDiscard | RelayControl
  deriving (Eq, Show, Enum, Bounded)

-- | One native start, discard or control frame for one worker, with its exact
-- bytes. A start and a control name the manager run and the command. A discard
-- names no manager run, because no run exists before an approval, and it names
-- the command that caused it, or no command when the manager discards on its
-- own.
data RelayBody = RelayBody
  { relayBodyKind :: !RelayKind,
    relayBodyManagerRun :: !(Maybe Text),
    relayBodyNativeRun :: !RunId,
    relayBodyCommand :: !(Maybe Text),
    relayBodyFrame :: !BS.ByteString
  }
  deriving (Eq, Show)

relayKindName :: RelayKind -> Text
relayKindName = \case
  RelayStart -> "start"
  RelayDiscard -> "discard"
  RelayControl -> "control"

-- | The relay body, or a refusal when the frame is above 'maxFrameBytes', is
-- not UTF-8, or names identifiers that its kind does not permit.
relayFlowBody :: RelayBody -> Either Text Value
relayFlowBody relay = do
  when (BS.length (relayBodyFrame relay) > maxFrameBytes) (Left "relay frame exceeds the frame bound")
  case (relayBodyKind relay, relayBodyManagerRun relay, relayBodyCommand relay) of
    (RelayDiscard, Nothing, _) -> Right ()
    (RelayDiscard, Just _, _) -> Left "a discard relay names no manager run"
    (_, Just _, Just _) -> Right ()
    _ -> Left "a start or control relay names its manager run and its command"
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
  managerRun <- flowField "relay body" fields "managerRun" >>= flowOptionalText "relay managerRun"
  command <- flowField "relay body" fields "command" >>= flowOptionalText "relay command"
  relay <-
    RelayBody kind managerRun
      <$> (RunId <$> flowTextField "relay body" fields "nativeRun")
      <*> pure command
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
-- Reader
-- ---------------------------------------------------------------------------

-- | The body of one manager record, decoded with the codec of its schema. A
-- failure body is decoded by the runtime reader and carries no value here.
data ManagerValue
  = CommandValue !CommandBody
  | AdministrationValue !AdministrationBody
  | ReceiptValue !CommandReceipt
  | AdministrationReceiptValue !Value
  | ReviewValue !ReviewBody
  | RelayValue !RelayBody
  | NoticeValue !Notice
  deriving (Eq, Show)

-- | What a reader found in one manager log: its path, its entries as the
-- runtime reader verified them with the failures of the manager body codecs
-- added, the decoded body of each record whose body decodes, and the size of
-- a final line without its newline.
data ManagerLogReport = ManagerLogReport
  { managerLogPath :: !FilePath,
    managerLogEntries :: ![FlowEntry],
    managerLogValues :: !(Map Position ManagerValue),
    managerLogTorn :: !(Maybe Int)
  }
  deriving (Eq, Show)

-- | Read one manager log file, as the account that owns its flow directory.
--
-- The flow directory of a manager private root holds the log
-- @<stream>.ndjson@ of each stream and its claim-check files in
-- @claims/<stream>/@. The reader verifies each line with 'readFlowLogAt' as a
-- manager log, and then decodes each body with the codec of its schema. A
-- receipt decodes with the receipt codec of the command that it answers.
readManagerLog :: FilePath -> IO ManagerLogReport
readManagerLog path =
  bracket (openPrivateRoot "manager flow" (takeDirectory path)) closePrivateRoot $ \root -> do
    let name = takeFileName path
        stream = T.pack (dropExtension name)
    (entries, torn) <- readFlowLogAt ManagerLog root [name] (drop 1 (managerFlowClaims stream))
    let (decoded, values) = decodeManagerEntries entries
    pure (ManagerLogReport path decoded values torn)

decodeManagerEntries :: [FlowEntry] -> ([FlowEntry], Map Position ManagerValue)
decodeManagerEntries = go Map.empty []
  where
    go values done [] = (reverse done, values)
    go values done (entry : rest) = case (entryRecord entry, entryContent entry) of
      (Just record, Just value) -> case decodeManagerBody values record value of
        Right Nothing -> go values (entry : done) rest
        Right (Just decoded) -> go (Map.insert (entryPosition entry) decoded values) (entry : done) rest
        Left why ->
          let failed = entry {entryProblems = entryProblems entry <> ["the " <> schemaName (recSchema record) <> " body does not decode: " <> why]}
           in go values (failed : done) rest
      _ -> go values (entry : done) rest

decodeManagerBody :: Map Position ManagerValue -> Record -> Value -> Either Text (Maybe ManagerValue)
decodeManagerBody values record value = case recSchema record of
  FlowCommand
    | administration -> Just . AdministrationValue <$> administrationFromFlowBody value
    | otherwise -> Just . CommandValue <$> commandFromFlowBody value
  FlowReceipt -> case recReplyTo record >>= (`Map.lookup` values) of
    Just (AdministrationValue _) -> Just . AdministrationReceiptValue <$> administrationReceiptFromFlowBody value
    Just (CommandValue _) -> do
      receipt <- receiptFromFlowBody value
      unless (Just (receiptId receipt) == aboutCommand (recAbout record)) (Left "the receipt names another command")
      pure (Just (ReceiptValue receipt))
    _ -> Left "the receipt answers no command whose body decoded"
  FlowReview -> Just . ReviewValue <$> reviewFromFlowBody value
  FlowRelay -> Just . RelayValue <$> relayFromFlowBody value
  FlowNotice -> Just . NoticeValue <$> noticeFromFlowBody value
  _ -> Right Nothing
  where
    administration = case value of
      Object fields -> KeyMap.member "administration" fields
      _ -> False

-- | One position in one of the logs that a reader joins.
data LogPosition = LogPosition
  { logPositionLog :: !FilePath,
    logPositionAt :: !Position
  }
  deriving (Eq, Show)

-- | A review and, by its preparation identifier, the later approve and
-- discard commands and review endings of its manager log.
data ReviewJoin = ReviewJoin
  { reviewJoinReview :: !LogPosition,
    reviewJoinPreparation :: !Text,
    reviewJoinCommands :: ![Position],
    reviewJoinEndings :: ![Position]
  }
  deriving (Eq, Show)

-- | A start or control relay and, by its native run and command identifiers,
-- the @start@ or @control@ record of the run log that the worker received.
data RelayJoin = RelayJoin
  { relayJoinRelay :: !LogPosition,
    relayJoinKind :: !RelayKind,
    relayJoinNativeRun :: !RunId,
    relayJoinDelivered :: !(Maybe LogPosition)
  }
  deriving (Eq, Show)

-- | A control of a run log and, by its command identifier, its first later
-- acknowledgement event record.
data ControlJoin = ControlJoin
  { controlJoinControl :: !LogPosition,
    controlJoinAcknowledgement :: !(Maybe Position)
  }
  deriving (Eq, Show)

-- | A command, its reply and, by its command identifier, its later command
-- notices.
data CommandJoin = CommandJoin
  { commandJoinCommand :: !LogPosition,
    commandJoinReply :: !(Maybe Position),
    commandJoinNotices :: ![Position]
  }
  deriving (Eq, Show)

-- | A person answer of a run log that names a command and, by that command
-- identifier, the answer command of the principal in a manager log.
data AnswerJoin = AnswerJoin
  { answerJoinAnswer :: !LogPosition,
    answerJoinCommandId :: !Text,
    answerJoinCommand :: !(Maybe LogPosition)
  }
  deriving (Eq, Show)

-- | The verification of the consent of one start relay (section 2 of the
-- design): the review, the approve command, its accepted receipt or the gap
-- notice that names that receipt, and the @start@ of the run log that names
-- the native run of the relay. The consent is verified when the list of
-- problems is empty.
data ConsentCheck = ConsentCheck
  { consentRelay :: !LogPosition,
    consentNativeRun :: !RunId,
    consentReview :: !(Maybe Position),
    consentCommand :: !(Maybe Position),
    consentReceipt :: !(Maybe Position),
    consentGap :: !(Maybe Position),
    consentRunStart :: !(Maybe LogPosition),
    consentProblems :: ![Text]
  }
  deriving (Eq, Show)

-- | A lifetime notice and the shutdown notice of the same process generation
-- that ends it, when one follows before the next lifetime notice.
data LifetimeJoin = LifetimeJoin
  { lifetimeJoinStart :: !LogPosition,
    lifetimeJoinShutdown :: !(Maybe Position)
  }
  deriving (Eq, Show)

-- | The manager logs and run logs that one reading joins, and every join
-- between them. The Store ledger remains the authority on commands, reviews
-- and requests.
data FlowJoin = FlowJoin
  { joinManagerLogs :: ![ManagerLogReport],
    joinRunLogs :: ![(FilePath, FlowReport)],
    joinReviews :: ![ReviewJoin],
    joinRelays :: ![RelayJoin],
    joinControls :: ![ControlJoin],
    joinCommands :: ![CommandJoin],
    joinAnswers :: ![AnswerJoin],
    joinConsent :: ![ConsentCheck],
    joinLifetimes :: ![LifetimeJoin],
    -- | Each join that fails a verification other than consent.
    joinFailures :: ![Text]
  }
  deriving (Eq, Show)

-- | Join manager logs with run logs. The predicate recognises an argument
-- that carries a credential, as the frontend worker refuses one in its
-- invocation.
joinFlows :: (String -> Bool) -> [ManagerLogReport] -> [(FilePath, FlowReport)] -> FlowJoin
joinFlows credentialArgument managers runs =
  FlowJoin
    { joinManagerLogs = managers,
      joinRunLogs = runs,
      joinReviews = concatMap reviewJoins managers,
      joinRelays = relays,
      joinControls = [ControlJoin (LogPosition path control) acknowledgement | (path, report) <- runs, (control, acknowledgement) <- flowAcknowledgements report],
      joinCommands = concatMap commandJoins managers,
      joinAnswers = answers,
      joinConsent = concatMap (consentChecks credentialArgument runStarts) managers,
      joinLifetimes = concatMap lifetimeJoins managers,
      joinFailures = answerFailures
    }
  where
    runStarts = [(run, path) | (path, report) <- runs, Just run <- [runLogStart report]]
    relays =
      [ RelayJoin (LogPosition (managerLogPath manager) position) (relayBodyKind relay) (relayBodyNativeRun relay) (delivered relay)
        | manager <- managers,
          (position, RelayValue relay) <- Map.toList (managerLogValues manager),
          relayBodyKind relay /= RelayDiscard
      ]
    delivered relay =
      listToMaybe
        [ LogPosition path position
          | (run, path) <- runStarts,
            run == relayBodyNativeRun relay,
            Just report <- [lookup path runs],
            position <- case relayBodyKind relay of
              RelayStart -> [Position 0]
              _ -> [entryPosition entry | entry <- reportEntries report, Just record <- [entryRecord entry], recSchema record == FlowControl, aboutCommand (recAbout record) == relayBodyCommand relay]
        ]
    answers =
      [ AnswerJoin (LogPosition path (entryPosition entry)) command (fst <$> listToMaybe (managerCommands command))
        | (path, report) <- runs,
          entry <- reportEntries report,
          Just record <- [entryRecord entry],
          recSchema record == FlowAnswer,
          Just command <- [aboutCommand (recAbout record)]
      ]
    managerCommands command =
      [ (LogPosition (managerLogPath manager) position, body)
        | manager <- managers,
          (position, CommandValue body) <- Map.toList (managerLogValues manager),
          Just record <- [recordAt manager position],
          aboutCommand (recAbout record) == Just command
      ]
    answerFailures =
      [ T.pack (logPositionLog (answerJoinAnswer answer)) <> " position " <> showPosition (logPositionAt (answerJoinAnswer answer)) <> ": the answer names command " <> answerJoinCommandId answer <> ", which is a " <> operationName (commandBodyOperation body) <> " command"
        | answer <- answers,
          (_, body) <- take 1 (managerCommands (answerJoinCommandId answer)),
          commandBodyOperation body /= Answer
      ]
        <> [ T.pack (logPositionLog (answerJoinAnswer answer)) <> " position " <> showPosition (logPositionAt (answerJoinAnswer answer)) <> ": the answer names command " <> answerJoinCommandId answer <> ", which the manager log records twice"
             | answer <- answers,
               length (managerCommands (answerJoinCommandId answer)) > 1
           ]

-- | The native run that the first record of a run log starts.
runLogStart :: FlowReport -> Maybe RunId
runLogStart report = case reportEntries report of
  first : _
    | Just record <- entryRecord first,
      recSchema record == FlowStart,
      Just value <- entryContent first,
      Right start <- startFromBody value ->
        Just (startRun start)
  _ -> Nothing

recordAt :: ManagerLogReport -> Position -> Maybe Record
recordAt manager (Position index) = case drop (fromIntegral index) (managerLogEntries manager) of
  entry : _ -> entryRecord entry
  [] -> Nothing

managerRecords :: ManagerLogReport -> [(Position, Record, Maybe ManagerValue)]
managerRecords manager =
  [ (entryPosition entry, record, Map.lookup (entryPosition entry) (managerLogValues manager))
    | entry <- managerLogEntries manager,
      Just record <- [entryRecord entry]
  ]

reviewJoins :: ManagerLogReport -> [ReviewJoin]
reviewJoins manager =
  [ ReviewJoin
      (LogPosition (managerLogPath manager) position)
      preparation
      [ later
        | (later, _, Just (CommandValue body)) <- records,
          later > position,
          commandBodyOperation body `elem` [Approve, Discard],
          commandPreparation body == Just preparation
      ]
      [later | (later, _, Just (NoticeValue (ReviewEnded ended _))) <- records, later > position, ended == preparation]
    | (position, _, Just (ReviewValue review)) <- records,
      let preparation = reviewBodyPreparation review
  ]
  where
    records = managerRecords manager

-- | The preparation that an approve or discard command names by its resource.
commandPreparation :: CommandBody -> Maybe Text
commandPreparation = T.stripPrefix "/v1/preparations/" . commandBodyResource

commandJoins :: ManagerLogReport -> [CommandJoin]
commandJoins manager =
  [ CommandJoin
      (LogPosition (managerLogPath manager) position)
      (listToMaybe [later | (later, reply, _) <- records, recReplyTo reply == Just position])
      [ later
        | Just command <- [aboutCommand (recAbout record)],
          (later, notice, Just (NoticeValue (CommandChanged _ _))) <- records,
          later > position,
          aboutCommand (recAbout notice) == Just command
      ]
    | (position, record, _) <- records,
      recSchema record == FlowCommand
  ]
  where
    records = managerRecords manager

lifetimeJoins :: ManagerLogReport -> [LifetimeJoin]
lifetimeJoins manager =
  [ LifetimeJoin (LogPosition (managerLogPath manager) position) $
      case [(later, notice) | (later, _, Just (NoticeValue notice)) <- records, later > position, isLifetimeEnd notice] of
        (later, ShutdownNotice generation) : _ | generation == lifetimeGeneration lifetime -> Just later
        _ -> Nothing
    | (position, _, Just (NoticeValue (LifetimeNotice lifetime))) <- records
  ]
  where
    records = managerRecords manager
    isLifetimeEnd = \case
      LifetimeNotice _ -> True
      ShutdownNotice _ -> True
      _ -> False

consentChecks :: (String -> Bool) -> [(RunId, FilePath)] -> ManagerLogReport -> [ConsentCheck]
consentChecks credentialArgument runStarts manager =
  [consentOf position relay | (position, _, Just (RelayValue relay)) <- records, relayBodyKind relay == RelayStart]
  where
    path = managerLogPath manager
    records = managerRecords manager
    consentOf relayAt relay =
      let run = relayBodyNativeRun relay
          command =
            listToMaybe
              (reverse [(at, record, body) | (at, record, Just (CommandValue body)) <- records, at < relayAt, aboutCommand (recAbout record) == relayBodyCommand relay, isJust (relayBodyCommand relay)])
          commandAt = (\(at, _, _) -> at) <$> command
          preparation = command >>= \(_, _, body) -> commandPreparation body
          review =
            listToMaybe
              (reverse [(at, body) | Just commandPosition <- [commandAt], (at, _, Just (ReviewValue body)) <- records, at < commandPosition, Just (reviewBodyPreparation body) == preparation])
          receipt =
            listToMaybe
              [ at
                | Just commandPosition <- [commandAt],
                  (at, record, Just (ReceiptValue body)) <- records,
                  recReplyTo record == Just commandPosition,
                  at < relayAt,
                  receiptState body /= Refused
              ]
          gap =
            listToMaybe
              [ at
                | Just commandPosition <- [commandAt],
                  (at, _, Just (NoticeValue (GapNotice missing _))) <- records,
                  at > commandPosition,
                  at < relayAt,
                  any (\entry -> missingSchema entry == FlowReceipt && aboutCommand (missingAbout entry) == relayBodyCommand relay) missing
              ]
          runStart = LogPosition <$> lookup run runStarts <*> pure (Position 0)
          problems = case (command, review) of
            (Nothing, _) -> ["no earlier command record names the command " <> fromMaybe "(none)" (relayBodyCommand relay) <> " of the start relay"]
            (Just (_, record, body), found) ->
              [ "the command of the start relay is a " <> operationName (commandBodyOperation body) <> " command" | commandBodyOperation body /= Approve ]
                <> [ "the approve command is not from a credential" | not (fromCredential (recFrom record)) ]
                <> case found of
                  Nothing -> ["no earlier review record names the preparation " <> fromMaybe "(none)" preparation <> " of the approve command"]
                  Just (_, reviewed) -> reviewProblems body reviewed
                <> [ "neither an accepted receipt nor a gap notice that names the receipt lies between the approve command and the start relay" | isNothing receipt && isNothing gap ]
                <> [ "no run log that was read begins with a start for native run " <> runIdText run | isNothing runStart ]
          reviewProblems body reviewed =
            let binding = either (const Nothing) Just (Aeson.eitherDecodeStrict' (reviewBodyBinding reviewed)) :: Maybe Value
                bindingText key = case binding of
                  Just (Object fields) | Just (String text) <- KeyMap.lookup key fields -> Just text
                  _ -> Nothing
                approval = commandBodyValue body >>= either (const Nothing) Just . parseEither Aeson.parseJSON :: Maybe ApprovalRequest
                ApprovalRequest reviewDigest _ _ _ _ = reviewBodySelectors reviewed
             in [ "the approve command names other selectors than the review" | approval /= Just (reviewBodySelectors reviewed) ]
                  <> [ "the binding is not a JSON object" | not (maybe False isObject binding) ]
                  <> [ "the SHA-256 of the review bytes differs from the reviewSha256 of the binding" | bindingText "reviewSha256" /= Just (flowSha256 (reviewBodyBytes reviewed)) ]
                  <> [ "the SHA-256 of the binding bytes differs from the binding digest" | flowSha256 (reviewBodyBinding reviewed) /= reviewBodyBindingDigest reviewed ]
                  <> [ "the approve command names another digest than the binding digest" | reviewDigest /= reviewBodyBindingDigest reviewed ]
                  <> [ "the binding names another native run than the start relay" | bindingText "nativeRunId" /= Just (runIdText (relayBodyNativeRun relay)) ]
                  <> [ "the binding carries a credential in its invocation or target arguments" | any credentialArgument (bindingArguments binding) ]
       in ConsentCheck (LogPosition path relayAt) run (fst <$> review) commandAt receipt gap runStart problems
    fromCredential = \case
      Principal (Credential _ _) -> True
      _ -> False
    isObject = \case
      Object _ -> True
      _ -> False

-- | The invocation prefix arguments and the target arguments of a binding.
bindingArguments :: Maybe Value -> [String]
bindingArguments = \case
  Just (Object fields) ->
    strings (KeyMap.lookup "targetArguments" fields)
      <> case KeyMap.lookup "invocation" fields of
        Just (Object invocation) -> strings (KeyMap.lookup "prefixArgs" invocation)
        _ -> []
  _ -> []
  where
    strings = \case
      Just (Array items) -> [T.unpack text | String text <- toList items]
      _ -> []

-- | The undecided commands: each command without a reply. The ledger is the
-- authority on its state.
joinUndecided :: FlowJoin -> [LogPosition]
joinUndecided join = [commandJoinCommand command | command <- joinCommands join, isNothing (commandJoinReply command)]

-- | The unresolved deliveries: each start or control relay without the
-- record of the run log that the worker received.
joinUnresolvedDelivery :: FlowJoin -> [LogPosition]
joinUnresolvedDelivery join = [relayJoinRelay relay | relay <- joinRelays join, isNothing (relayJoinDelivered relay)]

-- | The pending reviews: each review without a later command and without a
-- review ending with its preparation identifier.
joinPendingReview :: FlowJoin -> [LogPosition]
joinPendingReview join = [reviewJoinReview review | review <- joinReviews join, null (reviewJoinCommands review), null (reviewJoinEndings review)]

-- | The lifetimes that end without their shutdown notice, which lost their
-- supervision.
joinLostLifetimes :: FlowJoin -> [LogPosition]
joinLostLifetimes join = [lifetimeJoinStart lifetime | lifetime <- joinLifetimes join, isNothing (lifetimeJoinShutdown lifetime)]

-- | Every failed verification of the joined logs, each under its log: the
-- failures of each manager log and each run log, each consent that does not
-- verify and each failed join.
flowJoinProblems :: FlowJoin -> [Text]
flowJoinProblems join =
  concatMap managerProblems (joinManagerLogs join)
    <> [T.pack path <> ": " <> problem | (path, report) <- joinRunLogs join, problem <- flowReportProblems report]
    <> [ T.pack (logPositionLog (consentRelay consent)) <> " position " <> showPosition (logPositionAt (consentRelay consent)) <> ": the consent of the start relay does not verify: " <> problem
         | consent <- joinConsent join,
           problem <- consentProblems consent
       ]
    <> joinFailures join
  where
    managerProblems manager =
      [ T.pack (managerLogPath manager) <> ": the manager log ends with a line of " <> T.pack (show size) <> " bytes without its newline, which the reader did not decode"
        | Just size <- [managerLogTorn manager]
      ]
        <> [ T.pack (managerLogPath manager) <> " position " <> showPosition (entryPosition entry) <> ": " <> problem
             | entry <- managerLogEntries manager,
               problem <- entryProblems entry
           ]

flowJoinVerified :: FlowJoin -> Bool
flowJoinVerified = null . flowJoinProblems

-- | Whether the joined logs leave an outcome uncertain: a run log that has
-- lost its supervision, or a lifetime without its shutdown notice.
flowJoinUncertain :: FlowJoin -> Bool
flowJoinUncertain join = any (flowUncertain . snd) (joinRunLogs join) || not (null (joinLostLifetimes join))

-- | The summary object of a joined reading: the summary of each log, the
-- verification result and its failures, the joins, the consent of each start
-- relay and the states. It states that the Store ledger is the authority.
flowJoinSummaryValue :: FlowJoin -> Value
flowJoinSummaryValue join =
  object
    [ "summary"
        .= object
          [ "authority" .= ("The Store ledger is the authority on commands, reviews and requests. The manager log records what the manager decided." :: Text),
            "logs"
              .= ( [ object
                       [ "log" .= managerLogPath manager,
                         "kind" .= ("manager" :: Text),
                         "records" .= length (managerLogEntries manager),
                         "tornFinalLine" .= fmap (\size -> object ["bytes" .= size]) (managerLogTorn manager)
                       ]
                     | manager <- joinManagerLogs join
                   ]
                     <> [object ["log" .= path, "kind" .= ("run" :: Text), "report" .= flowReportValue report] | (path, report) <- joinRunLogs join]
                 ),
            "verified" .= flowJoinVerified join,
            "problems" .= flowJoinProblems join,
            "joins"
              .= object
                [ "reviews" .= [object ["review" .= at (reviewJoinReview review), "preparation" .= reviewJoinPreparation review, "commands" .= map positionIndex (reviewJoinCommands review), "endings" .= map positionIndex (reviewJoinEndings review)] | review <- joinReviews join],
                  "relays" .= [object ["relay" .= at (relayJoinRelay relay), "kind" .= relayKindName (relayJoinKind relay), "nativeRun" .= runIdText (relayJoinNativeRun relay), "delivered" .= fmap at (relayJoinDelivered relay)] | relay <- joinRelays join],
                  "controls" .= [object ["control" .= at (controlJoinControl control), "acknowledgement" .= fmap positionIndex (controlJoinAcknowledgement control)] | control <- joinControls join],
                  "commands" .= [object ["command" .= at (commandJoinCommand command), "reply" .= fmap positionIndex (commandJoinReply command), "notices" .= map positionIndex (commandJoinNotices command)] | command <- joinCommands join],
                  "answers" .= [object ["answer" .= at (answerJoinAnswer answer), "commandId" .= answerJoinCommandId answer, "command" .= fmap at (answerJoinCommand answer)] | answer <- joinAnswers join],
                  "lifetimes" .= [object ["lifetime" .= at (lifetimeJoinStart lifetime), "shutdown" .= fmap positionIndex (lifetimeJoinShutdown lifetime)] | lifetime <- joinLifetimes join]
                ],
            "consent"
              .= [ object
                     [ "relay" .= at (consentRelay consent),
                       "nativeRun" .= runIdText (consentNativeRun consent),
                       "review" .= fmap positionIndex (consentReview consent),
                       "command" .= fmap positionIndex (consentCommand consent),
                       "receipt" .= fmap positionIndex (consentReceipt consent),
                       "gap" .= fmap positionIndex (consentGap consent),
                       "runStart" .= fmap at (consentRunStart consent),
                       "verified" .= null (consentProblems consent),
                       "problems" .= consentProblems consent
                     ]
                   | consent <- joinConsent join
                 ],
            "states"
              .= object
                [ "undecided" .= map at (joinUndecided join),
                  "unresolvedDelivery" .= map at (joinUnresolvedDelivery join),
                  "pendingReview" .= map at (joinPendingReview join),
                  "lifetimeWithoutShutdown" .= map at (joinLostLifetimes join)
                ]
          ]
    ]
  where
    at (LogPosition path position) = object ["log" .= path, "position" .= positionIndex position]

showPosition :: Position -> Text
showPosition = T.pack . show . positionIndex

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
