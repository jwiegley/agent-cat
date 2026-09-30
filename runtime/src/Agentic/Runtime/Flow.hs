{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- | The actor flow: one append-only log of records for each run or manager
-- stream.
--
-- A 'Record' denotes one message: a schema from a closed list of seventeen, a
-- sender, an address, the identifiers that the message concerns, the position
-- of the ask that it answers when it is a reply, a body and the time at which
-- the writer appended it. A log denotes the finite sequence of its records, and
-- the 'Position' of a record is its 0-based index in that sequence.
--
-- The strict line codec satisfies @decodeFlowLine (encodeFlowLine r) = Right r@
-- for every record whose bodies satisfy their own codecs, and it refuses every
-- line that is not the exact encoding of a record: a line above
-- 'maxFrameBytes', which it refuses before it decodes anything, a duplicate key
-- at any depth, an unknown or a missing field, and any bytes other than the
-- encoder's rendering of the decoded record, such as whitespace, an escape where
-- the encoder writes a character, or an exponent where it writes digits. A
-- number keeps its decimal representation, so @1.0@ and @1@ are distinct lines.
-- Each body codec satisfies @decode (encode x) = Right x@.
module Agentic.Runtime.Flow
  ( -- * Records
    Record (..),
    Actor (..),
    Authority (..),
    ToolKind (..),
    Address (..),
    About (..),
    noAbout,
    Position (..),
    Body (..),
    Content (..),
    inlineBodyLimit,

    -- * Schemas
    Schema (..),
    SchemaRole (..),
    RouteClass (..),
    FlowLog (..),
    schemaName,
    schemaFromName,
    schemaRole,
    schemaRouteClass,
    schemaLog,
    schemaAnswers,

    -- * Line codecs
    FlowCodec (..),
    strictFlowCodec,
    encodeFlowLine,
    decodeFlowLine,

    -- * Run-log body codecs
    Start (..),
    StartInput (..),
    startBody,
    startFromBody,
    controlBody,
    controlFromBody,
    questionBody,
    questionFromBody,
    answerBody,
    answerFromBody,
    engineStartBody,
    engineStartFromBody,
    turnBody,
    turnFromBody,
    engineResultBody,
    engineResultFromBody,
    steerBody,
    steerFromBody,
    doneBody,
    doneFromBody,
    FailureKind (..),
    failureBody,
    failureFromBody,
    eventContent,
    eventFromContent,
    permissionBody,
    permissionFromBody,

    -- * Writer
    FlowWriter,
    FlowError (..),
    flowClaimDirectory,
    openFlowWriter,
    closeFlowWriter,
    withFlowWriter,
    appendAsk,
    appendTell,
    appendReply,
    readFlowContent,

    -- * Run log
    runLogName,
    runAbout,
    withRunLog,
    appendEventRecord,

    -- * Reader
    FlowLiveness (..),
    FlowEntry (..),
    PendingEffect (..),
    FlowStates (..),
    FlowReport (..),
    readFlow,
    flowVerified,
    flowUncertain,
    flowReportProblems,
    flowEntryValue,
    flowSummaryValue,
    FlowRoute,
    parseFlowRoute,
    flowRouteMatches,
    actorName,
    addressName,

    -- * Carriage
    RunFlow (..),
    FlowScope (..),
    newFlowScope,
    scopeRunFlow,
    flowBroker,
    flowScopedBroker,
  )
where

import Agentic.Engine
  ( EnginePermissionReport,
    EngineRequest,
    EngineResult,
    EngineSteering,
    EngineUpdate (EnginePermission),
    decodeEnginePermissionReport,
    decodeEngineRequest,
    decodeEngineResult,
    decodeEngineSteering,
    encodeEnginePermissionReport,
    encodeEngineRequest,
    encodeEngineResult,
    encodeEngineSteering,
  )
import Agentic.Planning (El, Request, SCode, SomeCode (..), answerFromJsonExact, answerJson, requestCodeFromJson, requestFromJson, requestJson)
import Agentic.Runtime.Broker (DataBroker (..))
import Agentic.Runtime.Control (Control (controlId), ControlId (controlIdText), controlVersionFor, decodeControlFor, encodeControlFor)
import Agentic.Runtime.PrivateRoot (PrivateRoot, closePrivateRoot, ensurePrivateDirectoryAt, openPrivateFileAt, openPrivateRoot, readPrivateFileAt, readPrivatePrefixAt, writePrivateExclusiveAt)
import Agentic.Runtime.Protocol
  ( Envelope (..),
    FailureClass,
    OccurrenceId (..),
    RuntimeEvent (..),
    PersonAnswering,
    RunId (..),
    SeqNo (..),
    failureOfText,
    failureText,
    maxArtifactBytes,
    maxFrameBytes,
    supportedProtocolVersions,
  )
import Agentic.Runtime.Store (EffectPhase (..), EffectRecord (..), LineageOperation, RunStore, StoreError, readEffectRecords, readEventLog, storePrivateRoot)
import Control.Concurrent.MVar (MVar, modifyMVar, modifyMVar_, newMVar)
import Control.Exception (Exception, IOException, SomeAsyncException, SomeException, bracket, displayException, finally, fromException, onException, throwIO, try)
import Control.Monad (unless, when)
import Crypto.Hash (Digest, SHA256, hash)
import Data.Aeson (FromJSON, Key, ToJSON (toJSON), Value (..), encode, object, (.=))
import qualified Data.Aeson as Aeson
import Data.Aeson.Decoding.ByteString (bsToTokens)
import Data.Aeson.Decoding.Tokens (Lit (..), Number (..), TkArray (..), TkRecord (..), Tokens (..))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import Data.Aeson.Types (parseEither)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.Char (isDigit, isHexDigit, isLower)
import Data.Foldable (toList)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List (nub)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust, isNothing, listToMaybe)
import Data.Scientific (Scientific, toBoundedInteger)
import Data.Sequence (Seq, (|>))
import qualified Data.Sequence as Seq
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (UTCTime, getCurrentTime)
import Data.Int (Int64)
import Data.Word (Word32, Word64)
import System.IO (Handle, hClose, hFlush)
import System.IO.Error (isAlreadyExistsError)

-- ---------------------------------------------------------------------------
-- Records
-- ---------------------------------------------------------------------------

-- | One message of a log.
data Record = Record
  { -- | The schema, which fixes the codec of the body, the role and the route class.
    recSchema :: !Schema,
    -- | The sender, stamped by the writer from its binding and never taken from the body.
    recFrom :: !Actor,
    recTo :: !Address,
    recAbout :: !About,
    -- | Present exactly on a reply: the position of its ask in the same log.
    recReplyTo :: !(Maybe Position),
    recBody :: !Body,
    -- | Taken under the writer lock. It is never used for order.
    recAt :: !UTCTime
  }
  deriving (Eq, Show)

-- | A participant that sends or receives messages.
data Actor
  = -- | The principal that the receiving edge authenticated.
    Principal !Authority
  | -- | The engine candidate that the runtime routed to, by target label.
    Model !Text
  | -- | A registry tool, a program command or a test fixture, by name. The
    -- constructor is not named @Tool@ because "Agentic.Runtime" already exports
    -- the in-process tool constructor of that name.
    ToolActor !Text !ToolKind
  | -- | An engine adapter that answers its agent's requests itself.
    Adapter !Text
  | -- | The runtime of one run, by native run identifier.
    Workflow !RunId
  | Manager
  deriving (Eq, Show)

-- | How the receiving edge authenticated a principal.
data Authority
  = -- | A manager credential: the client identifier and the credential identifier.
    Credential !Text !Text
  | -- | A local account: the user identifier and the owner string that the
    -- launching interface declared, if it declared one.
    LocalAccount !Word32 !(Maybe Text)
  deriving (Eq, Show)

data ToolKind = RegistryTool | ProgramCommand | FixtureTool
  deriving (Eq, Ord, Show, Enum, Bounded)

data Address
  = To !Actor
  | -- | The approvers of a manager profile, by profile identifier.
    Approvers !Text
  | Public
  deriving (Eq, Show)

-- | The identifiers that a record concerns. Each is optional, and an attempt
-- number requires its occurrence.
data About = About
  { aboutRequest :: !(Maybe Text),
    aboutManagerRun :: !(Maybe Text),
    aboutNativeRun :: !(Maybe RunId),
    aboutOccurrence :: !(Maybe OccurrenceId),
    aboutEpoch :: !(Maybe Word64),
    aboutAttempt :: !(Maybe Word32),
    aboutCommand :: !(Maybe Text)
  }
  deriving (Eq, Show)

noAbout :: About
noAbout = About Nothing Nothing Nothing Nothing Nothing Nothing Nothing

-- | The 0-based index of a record in its log.
newtype Position = Position {positionIndex :: Word64}
  deriving (Eq, Ord, Show)

-- | The body of a record as the log holds it.
data Body
  = -- | The body value, whose compact encoding is at most 'inlineBodyLimit' bytes.
    Inline !Value
  | -- | A body value above 'inlineBodyLimit' bytes, held in the private file
    -- @flow-claims/<sha256>@ beside the log: its lowercase hexadecimal SHA-256
    -- and its size in bytes.
    ClaimCheck !Text !Integer
  | -- | The sequence number of one line of @events.ndjson@.
    EventNumber !SeqNo
  deriving (Eq, Show)

-- | The body that a caller hands to the writer, and that a reader obtains
-- after it resolves a claim check.
data Content = ContentValue !Value | ContentEvent !SeqNo
  deriving (Eq, Show)

inlineBodyLimit :: Int
inlineBodyLimit = 64 * 1024

-- ---------------------------------------------------------------------------
-- Schemas
-- ---------------------------------------------------------------------------

-- | The closed list of record schemas.
data Schema
  = FlowStart
  | FlowControl
  | FlowQuestion
  | FlowAnswer
  | FlowEngineStart
  | FlowTurn
  | FlowEngineResult
  | FlowSteer
  | FlowDone
  | FlowFailure
  | FlowEvent
  | FlowPermission
  | FlowCommand
  | FlowReceipt
  | FlowReview
  | FlowRelay
  | FlowNotice
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | An ask expects a reply, a reply names its ask, and a tell expects nothing.
data SchemaRole = AskSchema | ReplySchema | TellSchema
  deriving (Eq, Ord, Show)

data RouteClass = ActorRoute | RestrictedRoute | PublicRoute
  deriving (Eq, Ord, Show)

-- | The logs in which a schema may appear.
data FlowLog = RunLog | ManagerLog | BothLogs
  deriving (Eq, Ord, Show)

schemaName :: Schema -> Text
schemaName = \case
  FlowStart -> "start"
  FlowControl -> "control"
  FlowQuestion -> "question"
  FlowAnswer -> "answer"
  FlowEngineStart -> "engine-start"
  FlowTurn -> "turn"
  FlowEngineResult -> "engine-result"
  FlowSteer -> "steer"
  FlowDone -> "done"
  FlowFailure -> "failure"
  FlowEvent -> "event"
  FlowPermission -> "permission"
  FlowCommand -> "command"
  FlowReceipt -> "receipt"
  FlowReview -> "review"
  FlowRelay -> "relay"
  FlowNotice -> "notice"

schemaFromName :: Text -> Maybe Schema
schemaFromName name = case [schema | schema <- [minBound .. maxBound], schemaName schema == name] of
  [schema] -> Just schema
  _ -> Nothing

-- | The asks that a reply schema may answer. It is empty for every other schema.
schemaAnswers :: Schema -> [Schema]
schemaAnswers = \case
  FlowAnswer -> [FlowQuestion]
  FlowEngineResult -> [FlowTurn]
  FlowDone -> [FlowEngineStart, FlowSteer]
  FlowFailure -> [schema | schema <- [minBound .. maxBound], schemaRole schema == AskSchema]
  FlowReceipt -> [FlowCommand]
  _ -> []

schemaRole :: Schema -> SchemaRole
schemaRole = \case
  FlowQuestion -> AskSchema
  FlowEngineStart -> AskSchema
  FlowTurn -> AskSchema
  FlowSteer -> AskSchema
  FlowCommand -> AskSchema
  FlowAnswer -> ReplySchema
  FlowEngineResult -> ReplySchema
  FlowDone -> ReplySchema
  FlowFailure -> ReplySchema
  FlowReceipt -> ReplySchema
  FlowStart -> TellSchema
  FlowControl -> TellSchema
  FlowEvent -> TellSchema
  FlowPermission -> TellSchema
  FlowReview -> TellSchema
  FlowRelay -> TellSchema
  FlowNotice -> TellSchema

schemaRouteClass :: Schema -> RouteClass
schemaRouteClass = \case
  FlowEngineResult -> RestrictedRoute
  FlowFailure -> RestrictedRoute
  FlowEvent -> PublicRoute
  _ -> ActorRoute

schemaLog :: Schema -> FlowLog
schemaLog = \case
  FlowFailure -> BothLogs
  FlowCommand -> ManagerLog
  FlowReceipt -> ManagerLog
  FlowReview -> ManagerLog
  FlowRelay -> ManagerLog
  FlowNotice -> ManagerLog
  _ -> RunLog

-- ---------------------------------------------------------------------------
-- Line codecs
-- ---------------------------------------------------------------------------

-- | The codec through which a writer carries its records. The writer encodes
-- each record with 'flowEncodeLine', decodes the bytes with 'flowDecodeLine',
-- appends the bytes and hands the decoded record to its caller.
data FlowCodec = FlowCodec
  { flowEncodeLine :: Record -> BS.ByteString,
    flowDecodeLine :: BS.ByteString -> Either Text Record
  }

strictFlowCodec :: FlowCodec
strictFlowCodec = FlowCodec encodeFlowLine decodeFlowLine

-- | One line without its newline.
encodeFlowLine :: Record -> BS.ByteString
encodeFlowLine = BL.toStrict . encode . recordValue

-- | Decode one line without its newline. The length check comes before any
-- decoding, so a line above 'maxFrameBytes' allocates nothing.
decodeFlowLine :: BS.ByteString -> Either Text Record
decodeFlowLine line
  | BS.length line > maxFrameBytes = Left ("flow line exceeds " <> T.pack (show maxFrameBytes) <> " bytes")
  | otherwise = do
      value <- strictValue "flow line" line
      record <- recordFromValue value
      unless (encodeFlowLine record == line) $
        Left "flow line is not the exact encoding of its record"
      pure record

recordValue :: Record -> Value
recordValue record =
  object $
    [ "schema" .= schemaName (recSchema record),
      "from" .= actorValue (recFrom record),
      "to" .= addressValue (recTo record),
      "about" .= aboutValue (recAbout record),
      "body" .= bodyValue (recBody record),
      "at" .= recAt record
    ]
      <> maybe [] (\position -> ["replyTo" .= positionIndex position]) (recReplyTo record)

recordFromValue :: Value -> Either Text Record
recordFromValue value = do
  fields <- objectOf "flow record" value
  schema <- textField "flow record" fields "schema" >>= \name ->
    maybe (Left ("flow record has unknown schema '" <> name <> "'")) Right (schemaFromName name)
  let reply = schemaRole schema == ReplySchema
      keys = ["schema", "from", "to", "about", "body", "at"] <> ["replyTo" | reply]
  exactKeys "flow record" keys fields
  from <- field "flow record" fields "from" >>= actorFromValue
  to <- field "flow record" fields "to" >>= addressFromValue
  about <- field "flow record" fields "about" >>= aboutFromValue
  replyTo <- if reply then Just . Position <$> (field "flow record" fields "replyTo" >>= boundedNumber "flow record replyTo") else Right Nothing
  body <- field "flow record" fields "body" >>= bodyFromValue
  checkBodyForm schema body
  at <- field "flow record" fields "at" >>= parsed "flow record at"
  pure (Record schema from to about replyTo body at)

checkBodyForm :: Schema -> Body -> Either Text ()
checkBodyForm schema body = case (schema, body) of
  (FlowEvent, EventNumber _) -> Right ()
  (FlowEvent, _) -> Left "an event record must name an event sequence number"
  (_, EventNumber _) -> Left ("a " <> schemaName schema <> " record cannot name an event sequence number")
  _ -> Right ()

actorValue :: Actor -> Value
actorValue = \case
  Principal (Credential client credential) -> object ["principal" .= ("credential" :: Text), "client" .= client, "credentialId" .= credential]
  Principal (LocalAccount uid owner) -> object ["principal" .= ("local" :: Text), "uid" .= uid, "owner" .= owner]
  Model target -> object ["model" .= target]
  ToolActor name kind -> object ["tool" .= name, "kind" .= toolKindName kind]
  Adapter name -> object ["adapter" .= name]
  Workflow run -> object ["workflow" .= runIdText run]
  Manager -> String "manager"

actorFromValue :: Value -> Either Text Actor
actorFromValue = \case
  String "manager" -> Right Manager
  value@(Object fields)
    | KeyMap.member "principal" fields -> textField "actor" fields "principal" >>= \case
        "credential" -> exactKeys "credential actor" ["principal", "client", "credentialId"] fields >> (Principal <$> (Credential <$> textField "actor" fields "client" <*> textField "actor" fields "credentialId"))
        "local" -> do
          exactKeys "local actor" ["principal", "uid", "owner"] fields
          uid <- field "actor" fields "uid" >>= boundedNumber "actor uid"
          owner <- field "actor" fields "owner" >>= optionalText "actor owner"
          pure (Principal (LocalAccount uid owner))
        other -> Left ("actor has unknown principal kind '" <> other <> "'")
    | KeyMap.member "tool" fields -> do
        exactKeys "tool actor" ["tool", "kind"] fields
        kind <- textField "actor" fields "kind" >>= named "tool kind" toolKindName
        ToolActor <$> textField "actor" fields "tool" <*> pure kind
    | otherwise -> single value
  _ -> Left "actor is neither an object nor \"manager\""
  where
    single value = do
      fields <- objectOf "actor" value
      case KeyMap.toList fields of
        [("model", String target)] -> Right (Model target)
        [("adapter", String name)] -> Right (Adapter name)
        [("workflow", String run)] -> Right (Workflow (RunId run))
        _ -> Left "actor has an unknown form"

toolKindName :: ToolKind -> Text
toolKindName = \case
  RegistryTool -> "registry"
  ProgramCommand -> "command"
  FixtureTool -> "fixture"

addressValue :: Address -> Value
addressValue = \case
  To actor -> object ["to" .= actorValue actor]
  Approvers profile -> object ["approvers" .= profile]
  Public -> String "public"

addressFromValue :: Value -> Either Text Address
addressFromValue = \case
  String "public" -> Right Public
  Object fields -> case KeyMap.toList fields of
    [("to", actor)] -> To <$> actorFromValue actor
    [("approvers", String profile)] -> Right (Approvers profile)
    _ -> Left "address has an unknown form"
  _ -> Left "address is neither an object nor \"public\""

aboutValue :: About -> Value
aboutValue about =
  object $
    concat
      [ present "request" (aboutRequest about),
        present "managerRun" (aboutManagerRun about),
        present "nativeRun" (runIdText <$> aboutNativeRun about),
        present "occurrence" (occurrenceNumber <$> aboutOccurrence about),
        present "epoch" (aboutEpoch about),
        present "attempt" (aboutAttempt about),
        present "command" (aboutCommand about)
      ]
  where
    present :: ToJSON a => Key -> Maybe a -> [(Key, Value)]
    present key = maybe [] (\value -> [key .= value])

aboutFromValue :: Value -> Either Text About
aboutFromValue value = do
  fields <- objectOf "about" value
  let known = ["request", "managerRun", "nativeRun", "occurrence", "epoch", "attempt", "command"]
  case filter (`notElem` known) (KeyMap.keys fields) of
    unknown : _ -> Left ("about has unknown field '" <> Key.toText unknown <> "'")
    [] -> pure ()
  let optional :: Key -> (Value -> Either Text a) -> Either Text (Maybe a)
      optional key decode = traverse decode (KeyMap.lookup key fields)
      text what = \case
        String content -> Right content
        _ -> Left ("about " <> what <> " is not a string")
  about <-
    About
      <$> optional "request" (text "request")
      <*> optional "managerRun" (text "managerRun")
      <*> optional "nativeRun" (fmap RunId . text "nativeRun")
      <*> optional "occurrence" (fmap OccurrenceId . boundedNumber "about occurrence")
      <*> optional "epoch" (boundedNumber "about epoch")
      <*> optional "attempt" (boundedNumber "about attempt")
      <*> optional "command" (text "command")
  when (aboutAttempt about /= Nothing && aboutOccurrence about == Nothing) $
    Left "about names an attempt without its occurrence"
  pure about

bodyValue :: Body -> Value
bodyValue = \case
  Inline value -> object ["inline" .= value]
  ClaimCheck digest size -> object ["claim" .= object ["sha256" .= digest, "bytes" .= size]]
  EventNumber (SeqNo number) -> object ["event" .= number]

bodyFromValue :: Value -> Either Text Body
bodyFromValue value = do
  fields <- objectOf "body" value
  case KeyMap.toList fields of
    [("inline", inline)] -> Right (Inline inline)
    [("claim", claim)] -> do
      claimFields <- objectOf "claim check" claim
      exactKeys "claim check" ["sha256", "bytes"] claimFields
      digest <- textField "claim check" claimFields "sha256"
      unless (isSha256 digest) (Left "claim check digest is not a lowercase SHA-256")
      size <- field "claim check" claimFields "bytes" >>= integral "claim check bytes"
      unless (size > toInteger inlineBodyLimit && size <= maxArtifactBytes) $
        Left "claim check size is outside the claim-check range"
      pure (ClaimCheck digest size)
    [("event", number)] -> EventNumber . SeqNo <$> boundedNumber "body event" number
    _ -> Left "body has an unknown form"

-- ---------------------------------------------------------------------------
-- Run-log body codecs
-- ---------------------------------------------------------------------------

-- | The first record of a run log.
data Start = Start
  { startRun :: !RunId,
    -- | The lowercase hexadecimal SHA-256 of the program.
    startProgramSha256 :: !Text,
    startPolicyDigest :: !Text,
    startPersonAnswering :: !(Maybe PersonAnswering),
    startTarget :: !Text,
    startLineage :: !LineageOperation,
    startParent :: !(Maybe RunId),
    -- | The inputs by name, each at most once.
    startInputs :: ![StartInput]
  }
  deriving (Eq, Show)

data StartInput = StartInput
  { startInputName :: !Text,
    startInputBytes :: !Integer,
    startInputSha256 :: !Text
  }
  deriving (Eq, Show)

startBody :: Start -> Value
startBody start =
  object
    [ "run" .= runIdText (startRun start),
      "programSha256" .= startProgramSha256 start,
      "policyDigest" .= startPolicyDigest start,
      "personAnswering" .= startPersonAnswering start,
      "target" .= startTarget start,
      "lineage" .= startLineage start,
      "parent" .= fmap runIdText (startParent start),
      "inputs" .= map inputValue (startInputs start)
    ]
  where
    inputValue input = object ["name" .= startInputName input, "bytes" .= startInputBytes input, "sha256" .= startInputSha256 input]

startFromBody :: Value -> Either Text Start
startFromBody value = do
  fields <- objectOf "start" value
  exactKeys "start" ["run", "programSha256", "policyDigest", "personAnswering", "target", "lineage", "parent", "inputs"] fields
  program <- textField "start" fields "programSha256"
  unless (isSha256 program) (Left "start programSha256 is not a lowercase SHA-256")
  answering <- field "start" fields "personAnswering" >>= \case
    Null -> Right Nothing
    mode@(String _) -> Just <$> parsed "start personAnswering" mode
    _ -> Left "start personAnswering is neither a string nor null"
  lineage <- field "start" fields "lineage" >>= \case
    name@(String _) -> parsed "start lineage" name
    _ -> Left "start lineage is not a string"
  parent <- field "start" fields "parent" >>= optionalText "start parent"
  inputs <- field "start" fields "inputs" >>= \case
    Array items -> traverse input (toList items)
    _ -> Left "start inputs is not an array"
  unless (length (nub (map startInputName inputs)) == length inputs) $
    Left "start names an input more than once"
  Start
    <$> (RunId <$> textField "start" fields "run")
    <*> pure program
    <*> textField "start" fields "policyDigest"
    <*> pure answering
    <*> textField "start" fields "target"
    <*> pure lineage
    <*> pure (RunId <$> parent)
    <*> pure inputs
  where
    input item = do
      fields <- objectOf "start input" item
      exactKeys "start input" ["name", "bytes", "sha256"] fields
      bytes <- field "start input" fields "bytes" >>= integral "start input bytes"
      unless (bytes >= 0) (Left "start input bytes is negative")
      digest <- textField "start input" fields "sha256"
      unless (isSha256 digest) (Left "start input sha256 is not a lowercase SHA-256")
      StartInput <$> textField "start input" fields "name" <*> pure bytes <*> pure digest

-- | A control at the protocol that the record names, 1 to 3. Protocol 3
-- carries its controls in control protocol 2, as the machine reads them.
controlBody :: Int -> Control -> Either Text Value
controlBody protocol control = do
  checkProtocol protocol
  frame <- encodeControlFor (controlVersionFor protocol) control >>= strictValue "control frame"
  pure (object ["protocol" .= protocol, "control" .= frame])

controlFromBody :: Value -> Either Text (Int, Control)
controlFromBody value = do
  fields <- objectOf "control body" value
  exactKeys "control body" ["protocol", "control"] fields
  protocol <- field "control body" fields "protocol" >>= boundedNumber "control protocol"
  checkProtocol protocol
  frame <- field "control body" fields "control"
  control <- decodeControlFor (controlVersionFor protocol) (BL.toStrict (encode frame))
  exact <- controlBody protocol control
  unless (exact == value) (Left "control body is not the exact form of its control")
  pure (protocol, control)

checkProtocol :: Int -> Either Text ()
checkProtocol protocol =
  unless (protocol `elem` supportedProtocolVersions) $
    Left ("unsupported runtime protocol version " <> T.pack (show protocol))

questionBody :: SCode c -> Request c -> Value
questionBody = requestJson

questionFromBody :: SCode c -> Value -> Either Text (Request c)
questionFromBody = requestFromJson

answerBody :: SCode c -> El c -> Value
answerBody = answerJson

answerFromBody :: SCode c -> Value -> Either Text (El c)
answerFromBody = answerFromJsonExact

engineStartBody :: EngineRequest -> Value
engineStartBody = encodeEngineRequest

engineStartFromBody :: Value -> Either Text EngineRequest
engineStartFromBody = decodeEngineRequest

turnBody :: Text -> Value
turnBody = String

turnFromBody :: Value -> Either Text Text
turnFromBody = \case
  String text -> Right text
  _ -> Left "turn body is not a string"

engineResultBody :: EngineResult -> Value
engineResultBody = encodeEngineResult

engineResultFromBody :: Value -> Either Text EngineResult
engineResultFromBody = decodeEngineResult

-- | The steering and its text. The record names the occurrence in its 'About'.
steerBody :: EngineSteering -> Text -> Value
steerBody = encodeEngineSteering

steerFromBody :: Value -> Either Text (EngineSteering, Text)
steerFromBody = decodeEngineSteering

doneBody :: Value
doneBody = Null

doneFromBody :: Value -> Either Text ()
doneFromBody = \case
  Null -> Right ()
  _ -> Left "done body is not null"

-- | The class of a @failure@ record: the runtime failure class of an operation
-- that raised an exception, or a refusal that the receiver returned as its
-- value, such as a steering that the engine refused.
data FailureKind = FailedWith !FailureClass | Refused
  deriving (Eq, Show)

failureBody :: FailureKind -> Text -> Value
failureBody failure message = object ["class" .= kindText failure, "message" .= message]
  where
    kindText (FailedWith class') = failureText class'
    kindText Refused = "refused"

failureFromBody :: Value -> Either Text (FailureKind, Text)
failureFromBody value = do
  fields <- objectOf "failure body" value
  exactKeys "failure body" ["class", "message"] fields
  name <- textField "failure body" fields "class"
  failure <- case name of
    "refused" -> Right Refused
    _ -> maybe (Left ("failure body has unknown class '" <> name <> "'")) (Right . FailedWith) (failureOfText name)
  (,) failure <$> textField "failure body" fields "message"

eventContent :: SeqNo -> Content
eventContent = ContentEvent

eventFromContent :: Content -> Either Text SeqNo
eventFromContent = \case
  ContentEvent number -> Right number
  ContentValue _ -> Left "event content is not an event sequence number"

permissionBody :: EnginePermissionReport -> Value
permissionBody = encodeEnginePermissionReport

permissionFromBody :: Value -> Either Text EnginePermissionReport
permissionFromBody = decodeEnginePermissionReport

-- ---------------------------------------------------------------------------
-- Writer
-- ---------------------------------------------------------------------------

-- | The writer of one log. One lock orders its appends.
data FlowWriter = FlowWriter
  { writerCodec :: !FlowCodec,
    writerRoot :: !PrivateRoot,
    writerState :: !(MVar WriterState),
    writerBroken :: !(IORef Bool)
  }

data WriterState = WriterState
  { stateHandle :: !Handle,
    -- | The schema of each appended position, and nothing else.
    stateSchemas :: !(Seq Schema),
    stateClaims :: !(Set Text),
    stateOpen :: !Bool
  }

newtype FlowError = FlowError Text
  deriving (Eq, Show)

instance Exception FlowError

-- | The directory, beside the log, that holds its claim-check files.
flowClaimDirectory :: FilePath
flowClaimDirectory = "flow-claims"

-- | Create the log as the exclusive private file of this name in the root.
openFlowWriter :: FlowCodec -> PrivateRoot -> FilePath -> IO FlowWriter
openFlowWriter codec root name = do
  handle <- openPrivateFileAt root [name]
  FlowWriter codec root <$> newMVar (WriterState handle Seq.empty Set.empty True) <*> newIORef False

closeFlowWriter :: FlowWriter -> IO ()
closeFlowWriter writer = modifyMVar_ (writerState writer) $ \current -> do
  when (stateOpen current) (hClose (stateHandle current))
  pure current {stateOpen = False}

withFlowWriter :: FlowCodec -> PrivateRoot -> FilePath -> (FlowWriter -> IO a) -> IO a
withFlowWriter codec root name = bracket (openFlowWriter codec root name) closeFlowWriter

-- | Append an ask and return its position with the record decoded from the
-- appended bytes.
appendAsk :: FlowWriter -> Schema -> Actor -> Address -> About -> Content -> IO (Position, Record)
appendAsk writer schema = append writer schema AskSchema Nothing

appendTell :: FlowWriter -> Schema -> Actor -> Address -> About -> Content -> IO (Position, Record)
appendTell writer schema = append writer schema TellSchema Nothing

-- | Append a reply to the ask at the given position. The writer refuses a
-- position that does not name an earlier ask of a schema that this reply may
-- answer.
appendReply :: FlowWriter -> Schema -> Position -> Actor -> Address -> About -> Content -> IO (Position, Record)
appendReply writer schema position = append writer schema ReplySchema (Just position)

append :: FlowWriter -> Schema -> SchemaRole -> Maybe Position -> Actor -> Address -> About -> Content -> IO (Position, Record)
append writer = appendVia (writerCodec writer) writer

-- | Append one record through the given codec, under the writer lock.
appendVia :: FlowCodec -> FlowWriter -> Schema -> SchemaRole -> Maybe Position -> Actor -> Address -> About -> Content -> IO (Position, Record)
appendVia codec writer schema role replyTo from to about content = do
  unless (schemaRole schema == role) $
    refuse ("the " <> schemaName schema <> " schema is not a " <> roleName role)
  modifyMVar (writerState writer) $ \current -> do
    broken <- readIORef (writerBroken writer)
    when broken (refuse "an earlier append to this log failed")
    unless (stateOpen current) (refuse "the log is closed")
    let schemas = stateSchemas current
        position = Position (fromIntegral (Seq.length schemas))
    mapM_ (checkReply schemas) replyTo
    (body, claim) <- either refuse pure (bodyFor schema content)
    at <- getCurrentTime
    let record = Record schema from to about replyTo body at
        line = flowEncodeLine codec record
    when (BS.length line > maxFrameBytes) $
      refuse ("the " <> schemaName schema <> " record exceeds " <> T.pack (show maxFrameBytes) <> " bytes")
    carried <- either (refuse . ("the codec does not decode its own line: " <>)) pure (flowDecodeLine codec line)
    claims <- case claim of
      Just (digest, bytes) | Set.notMember digest (stateClaims current) -> do
        writeClaim (writerRoot writer) digest bytes
        pure (Set.insert digest (stateClaims current))
      _ -> pure (stateClaims current)
    (BS.hPut (stateHandle current) (line <> "\n") >> hFlush (stateHandle current))
      `onException` writeIORef (writerBroken writer) True
    pure (current {stateSchemas = schemas |> schema, stateClaims = claims}, (position, carried))
  where
    checkReply schemas (Position index) =
      case Seq.lookup (fromIntegral index) schemas of
        Nothing -> refuse ("reply names position " <> T.pack (show index) <> ", which is not earlier in this log")
        Just asked
          | asked `elem` schemaAnswers schema -> pure ()
          | otherwise -> refuse ("a " <> schemaName schema <> " record cannot answer the " <> schemaName asked <> " record at position " <> T.pack (show index))
    roleName = \case
      AskSchema -> "ask"
      ReplySchema -> "reply"
      TellSchema -> "tell"

refuse :: Text -> IO a
refuse = throwIO . FlowError

bodyFor :: Schema -> Content -> Either Text (Body, Maybe (Text, BS.ByteString))
bodyFor schema content = case content of
  ContentEvent number
    | schema == FlowEvent -> Right (EventNumber number, Nothing)
    | otherwise -> Left ("a " <> schemaName schema <> " record cannot carry an event sequence number")
  ContentValue value
    | schema == FlowEvent -> Left "an event record carries an event sequence number"
    | BS.length bytes <= inlineBodyLimit -> Right (Inline value, Nothing)
    | toInteger (BS.length bytes) > maxArtifactBytes -> Left ("the " <> schemaName schema <> " body exceeds " <> T.pack (show maxArtifactBytes) <> " bytes")
    | otherwise -> Right (ClaimCheck digest (toInteger (BS.length bytes)), Just (digest, bytes))
    where
      bytes = BL.toStrict (encode value)
      digest = sha256Text bytes

-- | Write a claim check as its exclusive private file. A file of this name that
-- an earlier writer left is accepted only when its bytes have this digest.
writeClaim :: PrivateRoot -> Text -> BS.ByteString -> IO ()
writeClaim root digest bytes = do
  ensurePrivateDirectoryAt root [flowClaimDirectory]
  written <- try @IOException (writePrivateExclusiveAt root (claimPath digest) bytes)
  case written of
    Right () -> pure ()
    Left failure
      | isAlreadyExistsError failure -> do
          existing <- readPrivateFileAt root (claimPath digest) (toInteger (BS.length bytes))
          unless (existing == bytes) (refuse ("claim check " <> digest <> " exists with other bytes"))
      | otherwise -> throwIO failure

claimPath :: Text -> [FilePath]
claimPath digest = [flowClaimDirectory, T.unpack digest]

-- | The content of a body. A claim check is read from its private file beside
-- the log, and its size, digest and exact encoding are verified before use.
readFlowContent :: PrivateRoot -> Body -> IO (Either Text Content)
readFlowContent root = \case
  Inline value -> pure (Right (ContentValue value))
  EventNumber number -> pure (Right (ContentEvent number))
  ClaimCheck digest size
    | not (isSha256 digest) -> pure (Left "claim check digest is not a lowercase SHA-256")
    | otherwise -> do
        read' <- try @IOException (readPrivateFileAt root (claimPath digest) size)
        pure $ case read' of
          Left failure -> Left ("claim check " <> digest <> " cannot be read: " <> T.pack (show failure))
          Right bytes
            | toInteger (BS.length bytes) /= size -> Left ("claim check " <> digest <> " does not have its recorded size")
            | sha256Text bytes /= digest -> Left ("claim check " <> digest <> " does not have its recorded digest")
            | otherwise -> do
                value <- strictValue "claim check" bytes
                unless (BL.toStrict (encode value) == bytes) $
                  Left ("claim check " <> digest <> " is not the exact encoding of its value")
                pure (ContentValue value)

-- ---------------------------------------------------------------------------
-- Run log
-- ---------------------------------------------------------------------------

-- | The file of the run log in a run store.
runLogName :: FilePath
runLogName = "flow.ndjson"

-- | The identifiers of a record that concerns only its native run.
runAbout :: RunId -> About
runAbout run = noAbout {aboutNativeRun = Just run}

-- | Create the run log of a run store with its strict codec, append the
-- @start@ record from the intake to the workflow of the run, and run the
-- action with the writer. The log is closed when the action ends.
withRunLog :: RunStore -> Actor -> Start -> (FlowWriter -> IO a) -> IO a
withRunLog store intake start action =
  withFlowWriter strictFlowCodec (storePrivateRoot store) runLogName $ \writer -> do
    let run = startRun start
    _ <- appendTell writer FlowStart intake (To (Workflow run)) (runAbout run) (ContentValue (startBody start))
    action writer

-- | Append the @event@ record that names line @n@ of @events.ndjson@, from the
-- workflow of the run to the public audience.
appendEventRecord :: FlowWriter -> RunId -> SeqNo -> IO ()
appendEventRecord writer run number =
  () <$ appendTell writer FlowEvent (Workflow run) Public (runAbout run) (eventContent number)

-- ---------------------------------------------------------------------------
-- Carriage
-- ---------------------------------------------------------------------------

-- | What 'flowBroker' needs to record the messages of one run.
data RunFlow = RunFlow
  { runFlowWriter :: !FlowWriter,
    -- | The runtime protocol of the run, which fixes the codec of its controls.
    runFlowProtocol :: !Int,
    runFlowRun :: !RunId,
    -- | The actor that sends the run its controls: the local principal, or
    -- 'Manager' in service mode.
    runFlowIntake :: !Actor,
    -- | The actor that answers a dispatched request. The runtime resolves it
    -- from the candidate that it dispatched and the target in the @start@
    -- record, and never from an engine report.
    runFlowAnswerer :: forall c. Request c -> Actor,
    -- | The runtime failure class of an exception that a receiver raised.
    runFlowFailureClass :: SomeException -> FailureClass,
    -- | The occurrence whose operations this broker carries, if any.
    runFlowScope :: !(Maybe FlowScope)
  }

-- | The scope of one occurrence, which the runtime creates for each occurrence
-- before its first dispatch. The records that a scoped broker appends name the
-- occurrence, its epoch and the attempt of the scope. The runtime creates each
-- scope without an attempt at present.
data FlowScope = FlowScope
  { flowScopeOccurrence :: !OccurrenceId,
    flowScopeEpoch :: !Word64,
    flowScopeAttempt :: !(Maybe Word32),
    -- | The control that supplied the answer of the question in flight, when a
    -- control supplied it. 'flowBroker' empties the cell before it delivers a
    -- request, and a local person answer fills it with the control that
    -- supplied the answer before the receiver returns.
    flowScopeAnswerSource :: !(IORef (Maybe ControlId)),
    -- | The answerer of the question in flight, which receives the engine
    -- start, the turns and the steering of that question. Only 'flowBroker'
    -- writes it, for the duration of one @brokerRequest@.
    flowScopeCandidate :: !(IORef (Maybe Actor))
  }

newFlowScope :: OccurrenceId -> Word64 -> IO FlowScope
newFlowScope occurrence epoch = FlowScope occurrence epoch Nothing <$> newIORef Nothing <*> newIORef Nothing

scopeRunFlow :: FlowScope -> RunFlow -> RunFlow
scopeRunFlow scope flow = flow {runFlowScope = Just scope}

-- | The broker of one occurrence: 'flowBroker' over the scoped flow.
flowScopedBroker :: FlowCodec -> RunFlow -> DataBroker -> FlowScope -> DataBroker
flowScopedBroker codec flow inner scope = flowBroker codec (scopeRunFlow scope flow) inner

-- | Carry the operations of a broker through the run log.
--
-- Each operation appends its ask or tell through the codec before delivery,
-- hands its receiver the value decoded from the appended bytes, and appends the
-- reply or failure. The runtime receives the value decoded from the reply
-- record. A record whose bytes do not decode fails the operation before
-- delivery. Otherwise the receiver acts on the decoding, even when the codec
-- changed the value. A reply append that fails after the receiver returned
-- makes the operation refuse that reply. A receiver that raises a synchronous
-- exception has its failure appended, and the original exception propagates.
-- An asynchronous exception appends nothing. When a control supplied the
-- answer of a request, the @answer@ record comes from the intake and names that
-- control as its command.
--
-- @brokerEvent@ is carried by the event sink of the run, which appends each
-- event record, and @brokerLog@ and @brokerPersistence@ append nothing.
flowBroker :: FlowCodec -> RunFlow -> DataBroker -> DataBroker
flowBroker codec flow inner =
  inner
    { brokerRequest = \receive code request -> do
        let answerer = runFlowAnswerer flow request
        (asked, request') <- carryAsk FlowQuestion answerer (questionBody code request) (questionFromBody code)
        mapM_ (\current -> writeIORef (flowScopeAnswerSource current) Nothing) scope
        answer <- failing asked answerer (withCandidate answerer (brokerRequest inner receive code request'))
        -- A control that supplied the answer makes the intake its sender.
        source <- maybe (pure Nothing) (readIORef . flowScopeAnswerSource) scope
        let (sender, answered) = case source of
              Nothing -> (answerer, about)
              Just control -> (runFlowIntake flow, about {aboutCommand = Just (controlIdText control)})
        carryReplyAbout FlowAnswer asked sender answered (answerBody code answer) (answerFromBody code),
      brokerStart = \engine context request -> do
        model <- candidate FlowEngineStart
        (asked, request') <- carryAsk FlowEngineStart model (engineStartBody request) engineStartFromBody
        conversation <- failing asked model (brokerStart inner engine context request')
        carryReply FlowDone asked model doneBody doneFromBody
        pure conversation,
      brokerTurn = \conversation text -> do
        model <- candidate FlowTurn
        (asked, text') <- carryAsk FlowTurn model (turnBody text) turnFromBody
        result <- failing asked model (brokerTurn inner conversation text')
        carryReply FlowEngineResult asked model (engineResultBody result) engineResultFromBody,
      brokerSteer = \steerer timing text -> do
        model <- candidate FlowSteer
        (asked, (timing', text')) <- carryAsk FlowSteer model (steerBody timing text) steerFromBody
        outcome <- failing asked model (brokerSteer inner steerer timing' text')
        case outcome of
          Right () -> Right <$> carryReply FlowDone asked model doneBody doneFromBody
          Left why -> Left . snd <$> carryReply FlowFailure asked model (failureBody Refused why) failureFromBody,
      brokerControl = \receive control -> do
        body <- either refuse pure (controlBody (runFlowProtocol flow) control)
        let command = (runAbout (runFlowRun flow)) {aboutCommand = Just (controlIdText (controlId control))}
        (_, record) <- appendVia codec writer FlowControl TellSchema Nothing (runFlowIntake flow) (To workflow) command (ContentValue body)
        (_, control') <- carried FlowControl controlFromBody record
        brokerControl inner receive control',
      brokerUpdate = \sink update -> case update of
        EnginePermission report -> do
          adapter <- candidate FlowPermission >>= \case
            Model name -> pure (Adapter name)
            other -> refuse ("a permission report arrived while " <> T.pack (show other) <> " answers, not a model")
          (_, record) <- appendVia codec writer FlowPermission TellSchema Nothing adapter (To workflow) about (ContentValue (permissionBody report))
          report' <- carried FlowPermission permissionFromBody record
          brokerUpdate inner sink (EnginePermission report')
        _ -> brokerUpdate inner sink update
    }
  where
    writer = runFlowWriter flow
    workflow = Workflow (runFlowRun flow)
    scope = runFlowScope flow
    about = case scope of
      Nothing -> runAbout (runFlowRun flow)
      Just current ->
        (runAbout (runFlowRun flow))
          { aboutOccurrence = Just (flowScopeOccurrence current),
            aboutEpoch = Just (flowScopeEpoch current),
            aboutAttempt = flowScopeAttempt current
          }

    carryAsk :: Schema -> Actor -> Value -> (Value -> Either Text a) -> IO (Position, a)
    carryAsk schema to body decode = do
      (position, record) <- appendVia codec writer schema AskSchema Nothing workflow (To to) about (ContentValue body)
      (,) position <$> carried schema decode record

    carryReply :: Schema -> Position -> Actor -> Value -> (Value -> Either Text a) -> IO a
    carryReply schema asked from = carryReplyAbout schema asked from about

    carryReplyAbout :: Schema -> Position -> Actor -> About -> Value -> (Value -> Either Text a) -> IO a
    carryReplyAbout schema asked from identifiers body decode = do
      (_, record) <- appendVia codec writer schema ReplySchema (Just asked) from (To workflow) identifiers (ContentValue body)
      carried schema decode record

    -- A synchronous failure of the receiver is the reply to its ask.
    failing :: Position -> Actor -> IO a -> IO a
    failing asked from action = do
      outcome <- try @SomeException action
      case outcome of
        Right value -> pure value
        Left failure
          | Just (_ :: SomeAsyncException) <- fromException failure -> throwIO failure
          | otherwise -> do
              let body = failureBody (FailedWith (runFlowFailureClass flow failure)) (T.pack (displayException failure))
              _ <- carryReply FlowFailure asked from body failureFromBody
              throwIO failure

    carried :: Schema -> (Value -> Either Text a) -> Record -> IO a
    carried schema decode record = do
      content <- case recBody record of
        Inline value -> pure value
        body@(ClaimCheck _ _) -> readFlowContent (writerRoot writer) body >>= \case
          Right (ContentValue value) -> pure value
          Right (ContentEvent _) -> refuse ("the " <> schemaName schema <> " claim check names an event")
          Left why -> refuse why
        EventNumber _ -> refuse ("the " <> schemaName schema <> " record names an event")
      either (\why -> refuse ("the " <> schemaName schema <> " record does not decode: " <> why)) pure (decode content)

    candidate :: Schema -> IO Actor
    candidate schema = case scope of
      Nothing -> refuse ("a " <> schemaName schema <> " record needs the scope of an occurrence")
      Just current ->
        readIORef (flowScopeCandidate current)
          >>= maybe (refuse ("a " <> schemaName schema <> " record needs a question in flight")) pure

    withCandidate :: Actor -> IO a -> IO a
    withCandidate answerer action = case scope of
      Nothing -> action
      Just current -> do
        previous <- readIORef (flowScopeCandidate current)
        writeIORef (flowScopeCandidate current) (Just answerer)
        action `finally` writeIORef (flowScopeCandidate current) previous

-- ---------------------------------------------------------------------------
-- Reader
-- ---------------------------------------------------------------------------

-- | Whether a reader treats a log as one that its writer may still extend, or
-- as one that has ended. An ask without a reply is in flight in a live log and
-- uncertain in an ended log, and only an ended log can lose its supervision.
data FlowLiveness = FlowLive | FlowEnded
  deriving (Eq, Show)

-- | One complete line of a run log as the reader verified it.
data FlowEntry = FlowEntry
  { entryPosition :: !Position,
    -- | The record, when the line decodes.
    entryRecord :: !(Maybe Record),
    -- | The body value: the inline value, or the value of a claim check whose
    -- size, digest and exact encoding verify. An event record has none.
    entryContent :: !(Maybe Value),
    -- | The line of @events.ndjson@ that an event record names.
    entryEvent :: !(Maybe Envelope),
    -- | Each verification that this line fails.
    entryProblems :: ![Text]
  }
  deriving (Eq, Show)

-- | An effect start in @effects.ndjson@ without a later completion for the
-- same occurrence and question: its 0-based line and its occurrence.
data PendingEffect = PendingEffect
  { pendingEffectLine :: !Int,
    pendingEffectOccurrence :: !OccurrenceId
  }
  deriving (Eq, Show)

-- | The states of section 3.6 of the run log, each computed from the records
-- alone. Every list holds positions in log order.
data FlowStates = FlowStates
  { -- | Asks without a reply in a live log.
    statesInFlight :: ![Position],
    -- | Asks without a reply in an ended log without its stop.
    statesUncertain :: ![Position],
    -- | Asks without a reply in an ended log with its stop, as a run that
    -- races a cancel can leave one.
    statesUnansweredAtStop :: ![Position],
    -- | Controls without a later acknowledgement event for their identifier.
    statesUnacknowledged :: ![Position],
    -- | @OccurrenceRecoveryPending@ event records without a later
    -- @OccurrenceRecoveryChosen@ event record for the occurrence.
    statesPendingRecovery :: ![Position],
    -- | @OccurrencePersonAnswerPending@ event records without a later @answer@
    -- record for the occurrence.
    statesPendingPersonAnswer :: ![Position],
    statesPotentiallyExecuted :: ![PendingEffect],
    -- | The log has ended without its stop.
    statesLostSupervision :: !Bool,
    -- | Asks after the stop.
    statesAskAfterStop :: ![Position]
  }
  deriving (Eq, Show)

-- | What a reader found in one run log.
data FlowReport = FlowReport
  { reportLiveness :: !FlowLiveness,
    reportEntries :: ![FlowEntry],
    -- | The size in bytes of a final line without its newline. The reader
    -- does not decode it.
    reportTornBytes :: !(Maybe Int),
    -- | The position of the stop: the first event record whose event ends the
    -- run.
    reportStop :: !(Maybe Position),
    reportStates :: !FlowStates,
    -- | Each verification of the whole log that fails.
    reportProblems :: ![Text]
  }
  deriving (Eq, Show)

-- | The largest run log that a reader reads.
maxRunLogBytes :: Integer
maxRunLogBytes = 512 * 1024 * 1024

-- | Read the run log of a run store directory, as the account that owns the
-- directory.
--
-- The reader reads the prefix of @flow.ndjson@ that the file holds when it is
-- opened, so a live writer never tears a complete line. It decodes each
-- complete line with 'decodeFlowLine', which refuses a line above
-- 'maxFrameBytes' before it decodes it, and it reports a final line without
-- its newline by its size and does not decode it. It verifies the size, digest
-- and exact encoding of each claim check before it uses the body, decodes each
-- body with the codec of its schema, and verifies that each reply names an
-- earlier ask of a schema that the reply may answer and that no other reply
-- names. It joins each event record to the line of @events.ndjson@ with its
-- sequence number, and it reads @effects.ndjson@ for effect starts without a
-- completion.
readFlow :: FlowLiveness -> FilePath -> IO FlowReport
readFlow liveness directory =
  bracket (openPrivateRoot "run store" directory) closePrivateRoot $ \root -> do
    bytes <- readPrivatePrefixAt root [runLogName] maxRunLogBytes
    let (complete, torn) = splitFlowLines bytes
    entries <- traverse (readEntry root) (zip [0 ..] complete)
    events <- readable "events.ndjson" (fst <$> readEventLog directory)
    effects <- readable "effects.ndjson" (readEffectRecords directory)
    pure (analyseFlow liveness entries torn events effects)
  where
    readable :: Text -> IO a -> IO (Either Text a)
    readable name action = do
      outcome <- try @IOException (try @StoreError action)
      pure $ case outcome of
        Left failure -> Left (name <> " cannot be read: " <> T.pack (displayException failure))
        Right (Left failure) -> Left (name <> " cannot be read: " <> T.pack (show failure))
        Right (Right value) -> Right value

-- | The complete lines of a log, without their newlines, and the size of a
-- final line without its newline.
splitFlowLines :: BS.ByteString -> ([BS.ByteString], Maybe Int)
splitFlowLines = go []
  where
    go lines' rest
      | BS.null rest = (reverse lines', Nothing)
      | otherwise = case BS.elemIndex 10 rest of
          Nothing -> (reverse lines', Just (BS.length rest))
          Just index -> go (BS.take index rest : lines') (BS.drop (index + 1) rest)

readEntry :: PrivateRoot -> (Word64, BS.ByteString) -> IO FlowEntry
readEntry root (index, line) = case decodeFlowLine line of
  Left why -> pure (FlowEntry position Nothing Nothing Nothing ["the line does not decode: " <> why])
  Right record -> do
    content <- case recBody record of
      Inline value -> pure (Right (Just value))
      EventNumber _ -> pure (Right Nothing)
      body@(ClaimCheck _ _) ->
        readFlowContent root body >>= \case
          Right (ContentValue value) -> pure (Right (Just value))
          Right (ContentEvent _) -> pure (Left "the claim check names an event")
          Left why -> pure (Left why)
    pure $ case content of
      Right value -> FlowEntry position (Just record) value Nothing []
      Left why -> FlowEntry position (Just record) Nothing Nothing [why]
  where
    position = Position index

-- | The verification and the states of a log from its entries, the events of
-- its store and the effects of its store.
analyseFlow :: FlowLiveness -> [FlowEntry] -> Maybe Int -> Either Text [Envelope] -> Either Text [EffectRecord] -> FlowReport
analyseFlow liveness entries0 torn events effects =
  FlowReport liveness entries torn stop states problems
  where
    eventLines = either (const Map.empty) (Map.fromList . map (\envelope -> (sequenceOf envelope, envelope))) events
    sequenceOf envelope = let SeqNo number = envelopeSequence envelope in number
    entries = scanEntries eventLines (either (const False) (const True) events) entries0

    records = [(entryPosition entry, record) | entry <- entries, Just record <- [entryRecord entry]]
    asks = [position | (position, record) <- records, schemaRole (recSchema record) == AskSchema]
    answered = Set.fromList [index | (_, record) <- records, Just (Position index) <- [recReplyTo record]]
    open = [position | position@(Position index) <- asks, Set.notMember index answered]
    joined = [(entryPosition entry, envelopeEvent envelope) | entry <- entries, Just envelope <- [entryEvent entry]]
    stop = listToMaybe [position | (position, event) <- joined, terminal event]
    later position = filter ((> position) . fst)
    controls = [(position, controlKey entry record) | entry <- entries, Just record <- [entryRecord entry], recSchema record == FlowControl, let position = entryPosition entry]
    acknowledged key position = or [acknowledges key event | (_, event) <- later position joined]
    states =
      FlowStates
        { statesInFlight = if liveness == FlowLive then open else [],
          statesUncertain = if liveness == FlowEnded && isNothing stop then open else [],
          statesUnansweredAtStop = if liveness == FlowEnded && isJust stop then open else [],
          statesUnacknowledged = [position | (position, key) <- controls, maybe True (\name -> not (acknowledged name position)) key],
          statesPendingRecovery =
            [ position
              | (position, OccurrenceRecoveryPending occurrence _ _ _) <- joined,
                null [() | (_, OccurrenceRecoveryChosen chosen _ _ _) <- later position joined, chosen == occurrence]
            ],
          statesPendingPersonAnswer =
            [ position
              | (position, OccurrencePersonAnswerPending occurrence _) <- joined,
                null [() | (_, record) <- later position records, recSchema record == FlowAnswer, aboutOccurrence (recAbout record) == Just occurrence]
            ],
          statesPotentiallyExecuted = either (const []) pendingEffects effects,
          statesLostSupervision = liveness == FlowEnded && isNothing stop,
          statesAskAfterStop = maybe [] (\at -> filter (> at) asks) stop
        }
    problems =
      either pure (const []) events
        <> either pure (const []) effects
        <> [ "the run log ends with a line of " <> T.pack (show size) <> " bytes without its newline, which the reader did not decode"
             | Just size <- [torn],
               liveness == FlowEnded
           ]
        <> [ "the run log does not begin with a start record"
             | case entries of
                 first : _ -> fmap recSchema (entryRecord first) /= Just FlowStart
                 [] -> liveness == FlowEnded
           ]

-- | Verify each entry in log order: its schema, its body, its reply position
-- and its event.
scanEntries :: Map Word64 Envelope -> Bool -> [FlowEntry] -> [FlowEntry]
scanEntries eventLines eventsRead = go Map.empty Map.empty Set.empty Set.empty
  where
    go _ _ _ _ [] = []
    go schemas codes answered seen (entry : rest) = case entryRecord entry of
      Nothing -> entry : go schemas codes answered seen rest
      Just record ->
        let Position index = entryPosition entry
            schema = recSchema record
            logProblems =
              [ "the " <> schemaName schema <> " schema belongs to the manager log" | schemaLog schema == ManagerLog ]
                <> [ "a start record follows position 0" | schema == FlowStart, index /= 0 ]
            (code, bodyProblems) = case entryContent entry of
              Just value | schemaLog schema /= ManagerLog -> decodeEntryBody codes record value
              _ -> (Nothing, [])
            (replyProblems, answered') = case recReplyTo record of
              Nothing -> ([], answered)
              Just (Position asked)
                | asked >= index -> (["the reply names position " <> T.pack (show asked) <> ", which is not earlier in this log"], answered)
                | otherwise -> case Map.lookup asked schemas of
                    Nothing -> (["the reply names position " <> T.pack (show asked) <> ", which holds no record"], answered)
                    Just askedSchema
                      | askedSchema `notElem` schemaAnswers schema ->
                          (["a " <> schemaName schema <> " record cannot answer the " <> schemaName askedSchema <> " record at position " <> T.pack (show asked)], answered)
                      | Set.member asked answered -> (["the ask at position " <> T.pack (show asked) <> " already has a reply"], answered)
                      | otherwise -> ([], Set.insert asked answered)
            (event, eventProblems, seen') = case recBody record of
              EventNumber (SeqNo number)
                | Set.member number seen -> (Nothing, ["event " <> T.pack (show number) <> " has an earlier event record"], seen)
                | otherwise -> case Map.lookup number eventLines of
                    Just envelope -> (Just envelope, [], Set.insert number seen)
                    Nothing -> (Nothing, ["events.ndjson has no line for event " <> T.pack (show number) | eventsRead], Set.insert number seen)
              _ -> (Nothing, [], seen)
            entry' =
              entry
                { entryEvent = event,
                  entryProblems = entryProblems entry <> logProblems <> bodyProblems <> replyProblems <> eventProblems
                }
            codes' = maybe codes (\found -> Map.insert index found codes) code
         in entry' : go (Map.insert index schema schemas) codes' answered' seen' rest

-- | Decode a body with the codec of its schema. A question yields its code,
-- which decodes the answer that names it.
decodeEntryBody :: Map Word64 SomeCode -> Record -> Value -> (Maybe SomeCode, [Text])
decodeEntryBody codes record value = case recSchema record of
  FlowStart -> plain (startFromBody value)
  FlowControl -> plain (controlFromBody value)
  FlowQuestion -> case requestCodeFromJson value of
    Left why -> (Nothing, ["the question body does not decode: " <> why])
    Right found@(SomeCode code) -> (Just found, problem (questionFromBody code value))
  FlowAnswer -> case recReplyTo record >>= \(Position asked) -> Map.lookup asked codes of
    Just (SomeCode code) -> plain (answerFromBody code value)
    Nothing -> (Nothing, ["the answer names no question whose code decoded"])
  FlowEngineStart -> plain (engineStartFromBody value)
  FlowTurn -> plain (turnFromBody value)
  FlowEngineResult -> plain (engineResultFromBody value)
  FlowSteer -> plain (steerFromBody value)
  FlowDone -> plain (doneFromBody value)
  FlowFailure -> plain (failureFromBody value)
  FlowPermission -> plain (permissionFromBody value)
  _ -> (Nothing, [])
  where
    plain :: Either Text a -> (Maybe SomeCode, [Text])
    plain result = (Nothing, problem result)
    problem :: Either Text a -> [Text]
    problem = either (\why -> ["the " <> schemaName (recSchema record) <> " body does not decode: " <> why]) (const [])

-- | The identifier that a control record names: its decoded control's, or the
-- command of its identifiers.
controlKey :: FlowEntry -> Record -> Maybe Text
controlKey entry record = case entryContent entry >>= either (const Nothing) Just . controlFromBody of
  Just (_, control) -> Just (controlIdText (controlId control))
  Nothing -> aboutCommand (recAbout record)

acknowledges :: Text -> RuntimeEvent -> Bool
acknowledges key = \case
  ControlAcknowledged control _ _ -> control == key
  ControlAcknowledgedV2 control _ _ _ _ _ -> control == key
  _ -> False

terminal :: RuntimeEvent -> Bool
terminal = \case
  RunCompleted {} -> True
  RunCompletedV2 {} -> True
  RunFailed {} -> True
  RunCancelled {} -> True
  _ -> False

-- | Each effect start without a later completion for the same occurrence and
-- question. A completion completes the earliest open start that it matches.
pendingEffects :: [EffectRecord] -> [PendingEffect]
pendingEffects = go [] . zip [0 ..]
  where
    -- The open starts, the earliest first.
    go open [] = [PendingEffect line (effectOccurrence effect) | (line, effect) <- open]
    go open ((line, effect) : rest) = case effectPhase effect of
      EffectStarted -> go (open <> [(line, effect)]) rest
      EffectCompleted ->
        let matches (_, start) = effectOccurrence start == effectOccurrence effect && effectQuestion start == effectQuestion effect
            (before, after) = break matches open
         in go (before <> drop 1 after) rest

-- | Whether every verification of the log passed.
flowVerified :: FlowReport -> Bool
flowVerified = null . flowReportProblems

-- | Whether the log leaves the outcome of the run uncertain: an ended log
-- without its stop has lost its supervision, and each of its asks without a
-- reply is uncertain.
flowUncertain :: FlowReport -> Bool
flowUncertain = statesLostSupervision . reportStates

-- | Every failed verification, each line's under its position.
flowReportProblems :: FlowReport -> [Text]
flowReportProblems report =
  reportProblems report
    <> [ "position " <> T.pack (show (positionIndex (entryPosition entry))) <> ": " <> why
         | entry <- reportEntries report,
           why <- entryProblems entry
       ]

-- | One entry as the JSON object of the reader: its position, the fields of
-- its record, the decoded body or the claim check with its verified value, the
-- joined event and the failed verifications.
flowEntryValue :: FlowEntry -> Value
flowEntryValue entry =
  object $
    ["position" .= positionIndex (entryPosition entry)]
      <> maybe [] fields (entryRecord entry)
      <> ["problems" .= entryProblems entry]
  where
    fields record =
      [ "schema" .= schemaName (recSchema record),
        "from" .= actorValue (recFrom record),
        "to" .= addressValue (recTo record),
        "about" .= aboutValue (recAbout record),
        "replyTo" .= fmap positionIndex (recReplyTo record),
        "at" .= recAt record
      ]
        <> case recBody record of
          Inline value -> ["body" .= value]
          ClaimCheck digest size -> ["claim" .= object ["sha256" .= digest, "bytes" .= size], "body" .= entryContent entry]
          EventNumber (SeqNo number) -> ["event" .= object ["sequence" .= number, "line" .= entryEvent entry]]

-- | The summary object of the reader: the number of records, the verification
-- result and its failures, the torn final line, the stop and the states.
flowSummaryValue :: FlowReport -> Value
flowSummaryValue report =
  object
    [ "summary"
        .= object
          [ "live" .= (reportLiveness report == FlowLive),
            "records" .= length (reportEntries report),
            "verified" .= flowVerified report,
            "problems" .= flowReportProblems report,
            "tornFinalLine" .= fmap (\size -> object ["bytes" .= size]) (reportTornBytes report),
            "stop" .= fmap positionIndex (reportStop report),
            "states"
              .= object
                [ "inFlight" .= positions statesInFlight,
                  "uncertain" .= positions statesUncertain,
                  "unansweredAtStop" .= positions statesUnansweredAtStop,
                  "unacknowledged" .= positions statesUnacknowledged,
                  "pendingRecovery" .= positions statesPendingRecovery,
                  "pendingPersonAnswer" .= positions statesPendingPersonAnswer,
                  "potentiallyExecuted"
                    .= [ object ["line" .= pendingEffectLine effect, "occurrence" .= occurrenceNumber (pendingEffectOccurrence effect)]
                         | effect <- statesPotentiallyExecuted states
                       ],
                  "lostSupervision" .= statesLostSupervision states,
                  "askAfterStop" .= positions statesAskAfterStop
                ]
          ]
    ]
  where
    states = reportStates report
    positions select = map positionIndex (select states)

-- | A route: a conjunction of terms, each of which requires one field of a
-- record to equal a value. The fields are @schema@, @from@, @to@ and the
-- identifiers @request@, @managerRun@, @nativeRun@, @occurrence@, @epoch@,
-- @attempt@ and @command@. A sender or an address is compared by
-- 'actorName' or 'addressName'.
newtype FlowRoute = FlowRoute [(Text, Text)]
  deriving (Eq, Show)

-- | Parse a route: terms @field=value@ separated by commas.
parseFlowRoute :: Text -> Either Text FlowRoute
parseFlowRoute text
  | T.null text = Left "a route needs at least one field=value term"
  | otherwise = FlowRoute <$> traverse term (T.splitOn "," text)
  where
    term item = case T.breakOn "=" item of
      (name, value)
        | T.null value -> Left ("route term '" <> item <> "' is not field=value")
        | name `notElem` routeFields -> Left ("route field '" <> name <> "' is not one of " <> T.intercalate ", " routeFields)
        | otherwise -> Right (name, T.drop 1 value)

routeFields :: [Text]
routeFields = ["schema", "from", "to", "request", "managerRun", "nativeRun", "occurrence", "epoch", "attempt", "command"]

flowRouteMatches :: FlowRoute -> Record -> Bool
flowRouteMatches (FlowRoute terms) record = all matches terms
  where
    about = recAbout record
    matches (name, value) = fieldText name == Just value
    fieldText = \case
      "schema" -> Just (schemaName (recSchema record))
      "from" -> Just (actorName (recFrom record))
      "to" -> Just (addressName (recTo record))
      "request" -> aboutRequest about
      "managerRun" -> aboutManagerRun about
      "nativeRun" -> runIdText <$> aboutNativeRun about
      "occurrence" -> T.pack . show . occurrenceNumber <$> aboutOccurrence about
      "epoch" -> T.pack . show <$> aboutEpoch about
      "attempt" -> T.pack . show <$> aboutAttempt about
      "command" -> aboutCommand about
      _ -> Nothing

-- | The name of an actor in a route: @manager@, @local:UID@,
-- @credential:CLIENT:CREDENTIAL@, @model:TARGET@, @tool:NAME@,
-- @adapter:NAME@ or @workflow:RUN@.
actorName :: Actor -> Text
actorName = \case
  Principal (Credential client credential) -> "credential:" <> client <> ":" <> credential
  Principal (LocalAccount uid _) -> "local:" <> T.pack (show uid)
  Model target -> "model:" <> target
  ToolActor name _ -> "tool:" <> name
  Adapter name -> "adapter:" <> name
  Workflow run -> "workflow:" <> runIdText run
  Manager -> "manager"

-- | The name of an address in a route: the name of its actor, @approvers:PROFILE@
-- or @public@.
addressName :: Address -> Text
addressName = \case
  To actor -> actorName actor
  Approvers profile -> "approvers:" <> profile
  Public -> "public"

-- ---------------------------------------------------------------------------
-- Strict JSON values
-- ---------------------------------------------------------------------------

maxDepth :: Int
maxDepth = 128

-- | One JSON value from the Aeson token stream, refusing a duplicate key at any
-- depth, nesting deeper than 'maxDepth' and any trailing byte. The callers
-- bound the input length first.
strictValue :: Text -> BS.ByteString -> Either Text Value
strictValue what bytes = do
  (value, rest) <- either (\why -> Left (what <> ": " <> why)) Right (tokenValue 0 (bsToTokens bytes))
  unless (BS.null rest) (Left (what <> " has trailing bytes"))
  pure value

tokenValue :: Int -> Tokens k String -> Either Text (Value, k)
tokenValue depth = \case
  TkLit LitNull rest -> Right (Null, rest)
  TkLit LitTrue rest -> Right (Bool True, rest)
  TkLit LitFalse rest -> Right (Bool False, rest)
  TkText text rest -> Right (String text, rest)
  TkNumber number rest -> Right (Number (numberValue number), rest)
  TkArrayOpen items
    | depth >= maxDepth -> Left "nesting is too deep"
    | otherwise -> tokenArray (depth + 1) [] items
  TkRecordOpen fields
    | depth >= maxDepth -> Left "nesting is too deep"
    | otherwise -> tokenRecord (depth + 1) KeyMap.empty fields
  TkErr why -> Left ("invalid JSON: " <> T.pack why)

tokenArray :: Int -> [Value] -> TkArray k String -> Either Text (Value, k)
tokenArray depth items = \case
  TkItem tokens -> do
    (item, next) <- tokenValue depth tokens
    tokenArray depth (item : items) next
  TkArrayEnd rest -> Right (toJSON (reverse items), rest)
  TkArrayErr why -> Left ("invalid JSON: " <> T.pack why)

tokenRecord :: Int -> KeyMap.KeyMap Value -> TkRecord k String -> Either Text (Value, k)
tokenRecord depth fields = \case
  TkPair key tokens
    | KeyMap.member key fields -> Left ("duplicate key '" <> Key.toText key <> "'")
    | otherwise -> do
        (value, next) <- tokenValue depth tokens
        tokenRecord depth (KeyMap.insert key value fields) next
  TkRecordEnd rest -> Right (Object fields, rest)
  TkRecordErr why -> Left ("invalid JSON: " <> T.pack why)

numberValue :: Number -> Scientific
numberValue = \case
  NumInteger integer -> fromInteger integer
  NumDecimal decimal -> decimal
  NumScientific scientific -> scientific

-- ---------------------------------------------------------------------------
-- Field helpers
-- ---------------------------------------------------------------------------

type Fields = KeyMap.KeyMap Value

objectOf :: Text -> Value -> Either Text Fields
objectOf what = \case
  Object fields -> Right fields
  _ -> Left (what <> " is not an object")

exactKeys :: Text -> [Key] -> Fields -> Either Text ()
exactKeys what keys fields =
  case (filter (`notElem` keys) (KeyMap.keys fields), filter (not . (`KeyMap.member` fields)) keys) of
    (unknown : _, _) -> Left (what <> " has unknown field '" <> Key.toText unknown <> "'")
    (_, missing : _) -> Left (what <> " lacks field '" <> Key.toText missing <> "'")
    ([], []) -> Right ()

field :: Text -> Fields -> Key -> Either Text Value
field what fields key = maybe (Left (what <> " lacks field '" <> Key.toText key <> "'")) Right (KeyMap.lookup key fields)

textField :: Text -> Fields -> Key -> Either Text Text
textField what fields key =
  field what fields key >>= \case
    String text -> Right text
    _ -> Left (what <> " field '" <> Key.toText key <> "' is not a string")

optionalText :: Text -> Value -> Either Text (Maybe Text)
optionalText what = \case
  Null -> Right Nothing
  String text -> Right (Just text)
  _ -> Left (what <> " is neither a string nor null")

boundedNumber :: (Integral a, Bounded a) => Text -> Value -> Either Text a
boundedNumber what = \case
  Number number | Just bounded <- toBoundedInteger number -> Right bounded
  _ -> Left (what <> " is not an integer in range")

integral :: Text -> Value -> Either Text Integer
integral what value = toInteger <$> boundedNumber @Int64 what value

parsed :: FromJSON a => Text -> Value -> Either Text a
parsed what value = either (\why -> Left (what <> ": " <> T.pack why)) Right (parseEither Aeson.parseJSON value)

named :: (Enum a, Bounded a) => Text -> (a -> Text) -> Text -> Either Text a
named what name text = case [value | value <- [minBound .. maxBound], name value == text] of
  [value] -> Right value
  _ -> Left ("unknown " <> what <> " '" <> text <> "'")

isSha256 :: Text -> Bool
isSha256 digest = T.length digest == 64 && T.all (\c -> isDigit c || (isHexDigit c && isLower c)) digest

sha256Text :: BS.ByteString -> Text
sha256Text bytes = T.pack (show (hash bytes :: Digest SHA256))
