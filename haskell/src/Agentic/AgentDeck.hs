-- | An @agent-deck@ session, as an answering service.
--
-- "Agentic.Exec" runs a plan against a 'WorldIO'; this module builds one out of
-- a live @agent-deck@ session, so that a program written in "Agentic.Builder"
-- can be executed by a real agent instead of by a table. It is the Haskell
-- counterpart of the @Oracle IO@ Lean once stood over its own transports. Both
-- are retired there — @Agentic\/Core\/Exec.lean:62@, \"Where the transport
-- went\", records that the Lean ACP and @agent-deck@ transports, the
-- @Oracle IO@ over them and the entry points @exec@\/@execIO@ are gone and that
-- @agentic-run@ on the Haskell side is the runner. What Lean still states, and
-- what this module is held to, is the trusted base and the retry discipline
-- around it: @Decode@, @renderQ@, @nudge@, @askDecoding@.
--
-- == Everything goes to the one session
--
-- A question carries an 'Agentic.Raw.Addressee' — @model \"reviewer-secure\"@,
-- @tool \"apply\"@, @person \"owner\"@ — and all three kinds are sent to the
-- same @--session@. The addressee is not lost: it is the first thing the
-- rendered question says (@[question for person owner@ …), so the agent knows
-- whose part it is being asked to play. But there is one session, one
-- conversation and one agent, and the /language/ says three addressees. That
-- gap is this adapter's, not the semantics': a world in
-- @Agentic\/Core\/World.lean@ is a function of the question, and this one is a
-- function of the question that happens to route every question to the same
-- place.
--
-- == The transport, in three commands
--
-- One question is one turn, and a turn is:
--
-- 1. @agent-deck session output \<id\> --json@ — /before/ sending, to learn the
--    timestamp of the reply that is already there. This is the staleness guard:
--    without it, a session that has not started working yet reads as idle and
--    the /previous/ turn's text is read as this question's answer.
-- 2. @agent-deck session send \<id\> \<message\>@ — the question, rendered by
--    'renderQ'.
-- 3. @agent-deck session show \<id\> --json@, repeatedly, @deckPollMs@ apart,
--    until the session is not working any more (see 'Liveness'), and then
--    @agent-deck session output \<id\> --json@ for the reply — accepted only
--    once its @timestamp@ differs from the one recorded in step 1.
--
-- The whole turn is bounded by @deckTimeoutMs@: every subprocess call gets what
-- is left of that budget and the poll loop checks it before each poll, so a
-- session that never finishes produces 'DeckTimedOut' — a named error naming
-- the last status seen — and never a hang.
--
-- == How idleness is detected
--
-- From @session show \<id\> --json@, whose object carries @status@ and
-- @substate@ (measured against @agent-deck 1.11.0@; the same two fields appear
-- per session in @status --verbose --json@, while plain @status --json@ is a
-- fleet-wide count — @{\"waiting\":4,\"running\":5,…}@ — and cannot answer a
-- question about one session at all).
--
-- @status@ is one of @running@, @waiting@, @idle@, @stopped@, @error@;
-- 'livenessOfStatus' reads @running@ as 'Busy', @waiting@ and @idle@ as 'Idle'
-- — a Claude session that has finished its turn sits at
-- @\"status\":\"waiting\", \"substate\":\"idle-at-empty-prompt\"@ — and
-- @stopped@ and @error@ as 'Gone', which is 'DeckNotAlive' rather than a wait
-- for something that will not happen. An /unrecognized/ status is read as
-- 'Busy': a future @agent-deck@ that adds one should make this adapter wait and
-- then say what it was waiting for, rather than declare a turn finished on a
-- word it does not know.
--
-- == What is sent, and the format line
--
-- 'renderQ' is @Exec.renderQ@ (@Exec.lean:534@) verbatim, with @Selected@ empty:
-- a header naming the addressee, the scope axes, the draw when it is not the
-- first, and the answer format, then a blank line, then the prompt. Both scope
-- axes are said /in words/ because this transport has no call for either — that
-- is the fallback @Exec.lean@ documents, not an invention here.
--
-- The format line is @Exec.answerSpec@ (imported, never re-worded): a @flag@
-- question carries @Reply with exactly yes or no.@ and a @verdict@ carries
-- @Reply with exactly APPROVE if acceptable, or OBJECTION: \<one line\> if
-- not.@ __This is adapter behaviour and not language semantics.__ Nothing in
-- @Agentic\/Core\/Question.lean@ says a question carries its own answer format;
-- what the language says is that a @flag@'s answer set is @Bool@, and this
-- header is one runtime's way of making a live model likely to say something
-- "Agentic.Text" can read. A different transport may say it differently and the
-- program means the same thing.
--
-- Decoding, re-asking and abandonment are __not__ here: 'worldOfDeck' hands the
-- transport to "Agentic.Exec"'s 'askDecoding', which is @Exec.attemptWith@
-- (@Exec.lean:594@) and @Exec.askDecoding@'s error (@Exec.lean:648@), so the
-- retry wording and the exhaustion message exist once in this package.
--
-- == One rule this transport cannot apply
--
-- 'Agentic.Exec.requiresCompletedTurn' says a receipt, or any answer from a
-- person, may not be recorded from a turn the agent did not finish — the rule
-- is Haskell's own, because the Lean transport that once carried it is retired
-- (@Exec.lean:62@). The @agent-deck@ CLI reports no stop reason —
-- @session output@ returns text and
-- @session show@ returns a status, and neither says whether the agent ended its
-- turn or was cut off — so this adapter __cannot__ enforce that rule, and does
-- not pretend to. An @ack@ read here is evidence that something replied; a run
-- that needs more than that needs the ACP transport, or a check on the
-- workspace itself.
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Agentic.AgentDeck
  ( -- * The configuration
    DeckConfig (..),
    defaultDeckConfig,

    -- * The answering service
    worldOfDeck,
    worldOfDeckWith,
    verifyDeckRealizations,
    sayDeck,

    -- * What goes on the wire
    renderQ,

    -- * Liveness
    Liveness (..),
    livenessOfStatus,
    SessionState (..),
    parseSessionState,
    stateWords,

    -- * The reply
    Reply (..),
    parseReply,

    -- * Failure
    DeckError (..),
    renderDeckError,
    deckGap,
  )
where

import Control.Applicative ((<|>))
import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception
  ( Exception,
    IOException,
    SomeException,
    fromException,
    throwIO,
    try,
  )
import Control.Monad (void, when)
import Data.Aeson (Value (..))
import qualified Data.Aeson as A
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString as BS
import Data.Maybe (isNothing, mapMaybe)
import Data.Scientific (floatingOrInteger)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeUtf8With, encodeUtf8)
import Data.Text.Encoding.Error (lenientDecode)
import qualified Data.Vector as V
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import System.Exit (ExitCode (..))
import Text.Read (readMaybe)
import System.IO (Handle, hPutStrLn, stderr)
import System.Process
  ( CreateProcess (..),
    StdStream (..),
    proc,
    waitForProcess,
    withCreateProcess,
  )
import System.Timeout (timeout)

import Agentic.Exec
  ( ExecSettings (esLog, esRetryUndecodable),
    TurnGap (GapTransportRefusal),
    WorldIO (..),
    newTurnLaneIO,
    addresseeWord,
    answerSpec,
    askDecodingWith,
    attemptExecSettings,
    codeWord,
    defaultExecSettings,
    defaultRetries,
    oneLine,
    stderrLog,
    trimAscii,
    withPhysicalAttempt,
    withTransportGaps,
  )
import Agentic.Plan
  ( Q (..),
    Request (..),
    intentName,
    QScope (..),
    SCode,
    fromSCode,
  )
import Agentic.Raw (Code)
import Agentic.RoutingConfig
  ( Realization (..),
    ResolvedRealization (..),
    Router (routerProvider),
    thinkingName,
  )

-- ---------------------------------------------------------------------------
-- The configuration
-- ---------------------------------------------------------------------------

-- | Where the session is, how to reach it, and how patiently to wait.
--
-- @deckPollMs@ is the gap between two @session show@ calls and @deckTimeoutMs@
-- is the budget for a whole turn — send, poll and read. There is deliberately
-- no retry knob: how many times an unreadable answer is re-asked is
-- 'Agentic.Exec.defaultRetries', which is @Settings.retries@ (@Exec.lean:568@),
-- and it is a fact about the language's trusted base rather than about this
-- transport.
data DeckConfig = DeckConfig
  { -- | @\<id\>@ or the session's title; @agent-deck@ accepts either.
    deckSession :: !Text,
    -- | The executable, resolved on @PATH@ when it has no directory part.
    deckBinary :: !FilePath,
    -- | Milliseconds between two polls of @session show@.
    deckPollMs :: !Int,
    -- | Milliseconds for one whole turn, after which 'DeckTimedOut'.
    deckTimeoutMs :: !Int,
    -- | Narrate the transport — every command, every poll — on stderr.
    deckVerbose :: !Bool
  }
  deriving (Eq, Show)

-- | The configuration for a named session, with the CLI's own defaults: the
-- binary on @PATH@, a poll every second, and ten minutes for a turn — which is
-- @agent-deck session send@'s own @-timeout@ default, so the two agree on how
-- long a live agent is allowed to think.
defaultDeckConfig :: Text -> DeckConfig
defaultDeckConfig sess =
  DeckConfig
    { deckSession = sess,
      deckBinary = "agent-deck",
      deckPollMs = 1000,
      deckTimeoutMs = 600000,
      deckVerbose = False
    }

-- ---------------------------------------------------------------------------
-- Failure
-- ---------------------------------------------------------------------------

-- | The five ways this transport fails, each named, because an operator reading
-- one of these has to know whether to restart a session, fix a path or wait
-- longer.
--
-- Decode exhaustion is __not__ here: an answer that arrived and could not be
-- read is "Agentic.Exec"'s error (@askDecoding@, @Exec.lean:648@), thrown by
-- 'askDecoding' with the wording Lean uses. The split is the useful one — these
-- are failures to /obtain/ an answer, that one is a failure to /read/ one.
data DeckError
  = -- | The executable could not be run: the path, and what the OS said.
    DeckMissing !FilePath !Text
  | -- | A command exited nonzero: the command, its exit code, and what it said
    -- about it — the @error@ field of the JSON it refuses with, else its
    -- stderr, else its stdout.
    DeckCommandFailed !Text !Int !Text
  | -- | A command's stdout was not the JSON object expected: the command, the
    -- stdout it produced.
    DeckUnreadable !Text !Text
  | -- | An existing session cannot prove the requested routing constraints.
    DeckConfiguration !Text !Text
  | -- | The session is not in a state that can answer: the session, and the
    -- @status\/substate@ observed.
    DeckNotAlive !Text !Text
  | -- | The turn outran @deckTimeoutMs@: the session, the budget in
    -- milliseconds, and what was last observed — the @status\/substate@ the
    -- poll loop had seen, or the command that did not return.
    DeckTimedOut !Text !Int !Text
  deriving (Eq, Show)

instance Exception DeckError

-- | A 'DeckError' as one sentence, for a CLI that would rather print a line
-- than a constructor.
renderDeckError :: DeckError -> Text
renderDeckError = \case
  DeckMissing path why ->
    "could not run '" <> T.pack path <> "': " <> why
  DeckCommandFailed cmd code err ->
    "'"
      <> cmd
      <> "' exited "
      <> tshow code
      <> (if T.null err then "" else " saying '" <> trimAscii err <> "'")
  DeckUnreadable cmd out ->
    "'"
      <> cmd
      <> "' did not answer with the JSON object expected; it said '"
      <> clipText (trimAscii out)
      <> "'"
  DeckConfiguration sess why ->
    "session '" <> sess <> "' cannot realize the requested routing profile: " <> why
  DeckNotAlive sess seen ->
    "session '"
      <> sess
      <> "' is "
      <> seen
      <> ", so nothing will answer; start it (agent-deck session start "
      <> sess
      <> ") and run again"
  DeckTimedOut sess ms seen ->
    "session '"
      <> sess
      <> "' did not answer within "
      <> tshow ms
      <> "ms; last observed: "
      <> seen
      <> ". The question was abandoned rather than answered by this runtime"

-- ---------------------------------------------------------------------------
-- Liveness
-- ---------------------------------------------------------------------------

-- | What a session's @status@ means for a question in flight.
data Liveness
  = -- | The agent is working; wait.
    Busy
  | -- | The agent is not working; its reply, if any, is readable.
    Idle
  | -- | Stopped or errored: nothing will answer.
    Gone
  deriving (Eq, Show)

-- | The @status@ vocabulary of @agent-deck 1.11.0@, read for this purpose.
--
-- @waiting@ is 'Idle' and that is the common case rather than the odd one: it
-- is what the TUI calls a session that wants the operator's attention, and a
-- Claude session that has just finished a turn reports
-- @\"status\":\"waiting\"@ with @\"substate\":\"idle-at-empty-prompt\"@.
--
-- An unknown word is 'Busy' on purpose: waiting and then reporting 'DeckTimedOut'
-- with the unknown status quoted is a better failure than reading an unfamiliar
-- word as "the turn is over" and returning whatever text was lying around.
livenessOfStatus :: Text -> Liveness
livenessOfStatus = \case
  "running" -> Busy
  "waiting" -> Idle
  "idle" -> Idle
  "stopped" -> Gone
  "error" -> Gone
  _ -> Busy

-- | The two fields of @session show \<id\> --json@ this adapter reads.
data SessionState = SessionState
  { stateStatus :: !Text,
    stateSubstate :: !(Maybe Text)
  }
  deriving (Eq, Show)

-- | @status@, and @substate@ after it when there is one — what the verbose log
-- and the two failure messages quote.
stateWords :: SessionState -> Text
stateWords st = stateStatus st <> maybe "" ("/" <>) (stateSubstate st)

-- | @session show \<id\> --json@'s object, or 'Nothing' if that is not what
-- arrived. A missing session answers @{\"success\":false,\"code\":\"NOT_FOUND\",…}@
-- with exit code 2, so it is the exit code that reports it and this need not.
parseSessionState :: Text -> Maybe SessionState
parseSessionState raw = do
  o <- asObject raw
  st <- lookupString "status" o
  -- An empty @substate@ is the absence of one — @agent-deck@ writes @\"\"@ for
  -- a session whose tool reports no finer state — and reading it as a substate
  -- would put a stray @\/@ in every message that quotes one.
  pure (SessionState st (nonEmptyText (lookupString "substate" o)))

-- | Model facts exposed by @agent-deck list --json@. Missing fields remain
-- missing: verification must not turn absence into a backend default.
data SessionMetadata = SessionMetadata
  { metadataId :: !Text,
    metadataTitle :: !Text,
    metadataProvider :: !(Maybe Text),
    metadataModel :: !(Maybe Text),
    metadataThinking :: !(Maybe Text),
    metadataMaxOutput :: !(Maybe Integer)
  }
  deriving (Eq, Show)

parseSessionMetadata :: Text -> Maybe [SessionMetadata]
parseSessionMetadata raw = case A.decodeStrict (encodeUtf8 raw) of
  Just (Array values) -> Just (mapMaybe metadataOf (V.toList values))
  _ -> Nothing

metadataOf :: Value -> Maybe SessionMetadata
metadataOf (Object object) = do
  identifier <- lookupString "id" object
  let title = maybe identifier id (lookupString "title" object)
      provider = nonEmptyText (lookupString "provider" object)
      model = lookupString "model_id" object <|> lookupString "model" object
      arguments = lookupStrings "extra_args" object
      thinking = lookupString "thinking" object <|> lookupString "thinking_level" object <|> flagValue ["--effort", "--thinking"] arguments
      maxOutput =
        lookupInteger "max_output" object
          <|> lookupInteger "max_output_tokens" object
          <|> (flagValue ["--max-output", "--max-output-tokens", "--max-tokens"] arguments >>= readMaybe . T.unpack)
  pure (SessionMetadata identifier title provider model thinking maxOutput)
metadataOf _ = Nothing


-- | Verify every declared constraint before the first @session send@. An empty
-- list is the legacy unconfigured path and performs no additional command.
verifyDeckRealizations :: DeckConfig -> [ResolvedRealization] -> IO ()
verifyDeckRealizations _ [] = pure ()
verifyDeckRealizations cfg expected = do
  deadline <- deadlineIn (deckTimeoutMs cfg)
  (out, cmd) <- deckCommand cfg deadline ["list", "--json"]
  entries <- maybe (throwIO (DeckUnreadable cmd out)) pure (parseSessionMetadata out)
  metadata <- case filter matches entries of
    [entry] -> pure entry
    [] -> configurationError ("is absent from `agent-deck list --json`")
    _ -> configurationError "matches more than one session id/title"
  mapM_ (verify metadata) expected
  where
    matches entry = deckSession cfg == metadataId entry || deckSession cfg == metadataTitle entry
    configurationError = throwIO . DeckConfiguration (deckSession cfg)
    verify metadata realization = do
      let spec = resolvedSpec realization
          expectedProvider = routerProvider (resolvedRouter realization)
      require "provider" expectedProvider (metadataProvider metadata)
      require "model" (realizationModel spec) (metadataModel metadata)
      require "thinking" (thinkingName (realizationThinking spec)) (metadataThinking metadata)
      case realizationMaxOutput spec of
        Nothing -> pure ()
        Just wanted -> require "max-output" wanted (metadataMaxOutput metadata)
      when (not (null (realizationOptions spec))) $
        configurationError "agent-deck exposes no generic metadata for backend-specific options"
    require label wanted = \case
      Nothing -> configurationError ("does not report " <> label <> "; required " <> tshow wanted)
      Just actual
        | actual == wanted -> pure ()
        | otherwise -> configurationError ("reports " <> label <> " " <> tshow actual <> ", required " <> tshow wanted)
-- ---------------------------------------------------------------------------
-- The reply
-- ---------------------------------------------------------------------------

-- | @session output \<id\> --json@'s object: the last thing the session said,
-- and when it said it.
--
-- The timestamp is what makes a reply /this question's/ reply. It is optional
-- because the guard has to degrade honestly: if a build of @agent-deck@ stops
-- emitting one, 'sayDeck' accepts the first reply seen after the session goes
-- idle rather than waiting for a field that will never change.
data Reply = Reply
  { replyContent :: !Text,
    replyStamp :: !(Maybe Text)
  }
  deriving (Eq, Show)

-- | The reply object, or 'Nothing' if stdout was not one.
parseReply :: Text -> Maybe Reply
parseReply raw = do
  o <- asObject raw
  content <- lookupString "content" o
  pure (Reply content (nonEmptyText (lookupString "timestamp" o)))

-- ---------------------------------------------------------------------------
-- What goes on the wire
-- ---------------------------------------------------------------------------

-- | @Exec.renderQ c q {}@ (@Exec.lean:534@): the question as bytes, with a
-- header carrying everything that determines the reply, then the words.
--
-- > [question for model author
-- > model: deep
-- > answer (text): Reply with the text itself and nothing else.]
-- >
-- > Draft a patch satisfying:
-- > …
--
-- The @Selected@ argument is empty here and there is no configuration that
-- could make it otherwise: ACP has @session\/set_mode@ and
-- @session\/set_config_option@, and the @agent-deck@ CLI has neither, so both
-- scope axes travel in the header. @draw@ appears only when it is nonzero,
-- because a resample is a different question and the addressee is owed the fact
-- that it is being asked again on purpose.
renderQ :: forall (c :: Code). SCode c -> Request c -> Text
renderQ c request =
  "[question for "
    <> addresseeWord (qAddressee q)
    <> "\nintent: "
    <> intentName (reqIntent request)
    <> "\n"
    <> axis "model" (scopeModelAxis (qScope q))
    <> axis "mode" (scopeModeAxis (qScope q))
    <> draw
    <> "answer ("
    <> codeWord (fromSCode c)
    <> "): "
    <> answerSpec c
    <> "]\n\n"
    <> qPrompt q
  where
    q = reqQuestion request
    axis :: Text -> Maybe Text -> Text
    axis name = maybe "" (\v -> name <> ": " <> v <> "\n")

    draw :: Text
    draw
      | qDraw q == 0 = ""
      | otherwise = "draw: " <> tshow (qDraw q) <> " (an independent re-draw)\n"

-- ---------------------------------------------------------------------------
-- The answering service
-- ---------------------------------------------------------------------------

-- | The session, as a 'WorldIO': ask it, read what it said, and re-ask once if
-- the trusted base could not read it.
--
-- This is the @Oracle IO@ Lean retired with its transports (@Exec.lean:62@),
-- with the connection replaced by 'sayDeck' and the two protocol scope calls
-- replaced by the header 'renderQ' writes. Everything else — 'askDecoding', 'defaultRetries', the warning, the
-- abandonment message — is imported from "Agentic.Exec", so a run against a
-- live session and a run against 'Agentic.Exec.scriptedWorld' fail in the same
-- words for the same reason.
--
-- The log is 'stderrLog' unconditionally, not @deckVerbose@'s: a re-ask is the
-- reason a question was put twice and a bill therefore looks the way it does,
-- and that is owed to the operator whether or not they asked for transport
-- chatter.
worldOfDeck :: DeckConfig -> IO WorldIO
worldOfDeck = worldOfDeckWith settings
  where
    settings =
      defaultExecSettings {esLog = stderrLog, esRetryUndecodable = defaultRetries}

-- | 'worldOfDeck' under an operator's 'Agentic.Exec.ExecSettings'.
--
-- __This is where the failure vocabulary meets this transport.__ Every
-- 'DeckError' is a 'GapTransportRefusal': the agent-deck CLI reports no stop
-- reason, so this transport can never name a turn that ended cleanly with
-- nothing — that distinction is @--engine acp@'s, and the asymmetry is the
-- difference between the two engines rather than a defect here. The gap is
-- priced by @gapBudget@, answered by @esRecover@, re-asked here while that
-- answer is @RetryHere@, and otherwise handed to the fail-over walk, which
-- either puts the same question to the next model in its chain or raises the
-- 'DeckError' itself — so with no chain declared a run fails in exactly the
-- words it always did.
worldOfDeckWith :: ExecSettings -> DeckConfig -> IO WorldIO
worldOfDeckWith st cfg = do
  lane <- newTurnLaneIO
  pure
    WorldIO
      { worldAskIO = \c q ->
          withTransportGaps st deckGap c q (askDecodingWith st c q (sayDeck cfg c q)),
        worldAskAttemptIO = \context c q ->
          let controlledSettings = attemptExecSettings context st
           in withTransportGaps controlledSettings deckGap c q $
                askDecodingWith controlledSettings c q $ \extra ->
                  withPhysicalAttempt context (addresseeWord (qAddressee (reqQuestion q))) $
                    \_ -> sayDeck cfg c q extra,
        worldTurnLane = \_ _ -> Just lane
      }

-- | Which gap a 'DeckError' is, and the evidence — @Nothing@ for an exception
-- that is not this transport's to classify, which is rethrown untouched.
deckGap :: SomeException -> Maybe (TurnGap, Text)
deckGap e = case fromException e of
  Just de -> Just (GapTransportRefusal, renderDeckError de)
  Nothing -> Nothing

-- | Lean's @Say@ (@Exec.lean:585@) at this transport: render the question,
-- append what the caller wants appended, send it, wait for the session to
-- finish, and return the bytes.
--
-- The @extra@ is 'Agentic.Exec.nudge''s output on a re-ask and empty on a first
-- attempt; it is appended after the prompt, so the addressee sees what it said
-- and why it could not be read at the end of the message rather than before the
-- question.
--
-- Every turn gets a fresh @deckTimeoutMs@ budget, re-asks included: a second
-- attempt is a second turn, and charging it what the first one spent would make
-- a slow answer unaskable twice.
sayDeck :: forall (c :: Code). DeckConfig -> SCode c -> Request c -> Text -> IO Text
sayDeck cfg c q extra = do
  dl <- deadlineIn (deckTimeoutMs cfg)
  let message = renderQ c q <> extra
  chat cfg $
    "put "
      <> codeWord (fromSCode c)
      <> " to "
      <> addresseeWord (qAddressee (reqQuestion q))
      <> " ("
      <> tshow (T.length message)
      <> " characters)"
  before <- currentStamp cfg dl
  sendMessage cfg dl message
  awaitReply cfg dl before

-- | Wait for the session to stop working and say something new.
--
-- Two conditions, and both are needed. The session must be 'Idle' — it is
-- 'Busy' while the agent is composing — and the reply's @timestamp@ must differ
-- from the one taken before the send, because @session send@ returns as soon as
-- the message is submitted and there is a window in which the agent has not yet
-- begun and the session still looks idle. Without the second condition that
-- window is read as an instant answer, and the previous turn's text is recorded
-- as this question's answer.
awaitReply :: DeckConfig -> Deadline -> Maybe Text -> IO Text
awaitReply cfg dl before = go "not yet polled"
  where
    go :: Text -> IO Text
    go lastSeen = do
      left <- remainingMs dl
      when (left <= 0) $
        throwIO
          ( DeckTimedOut
              (deckSession cfg)
              (deckTimeoutMs cfg)
              (lastSeen <> ", with nothing said since the question went out")
          )
      st <- sessionState cfg dl
      let seen = stateWords st
      chat cfg ("poll: " <> seen)
      case livenessOfStatus (stateStatus st) of
        Gone -> throwIO (DeckNotAlive (deckSession cfg) seen)
        Busy -> nap >> go seen
        Idle ->
          currentReply cfg dl >>= \case
            Just r
              | fresh r -> do
                  chat cfg ("read " <> tshow (T.length (replyContent r)) <> " characters")
                  pure (replyContent r)
            _ -> nap >> go seen

    -- The reply is this question's when it is stamped differently from the one
    -- that was there before the send — or when there is no stamp at all to
    -- compare, in which case the wait for idleness is the whole guard.
    fresh :: Reply -> Bool
    fresh r = isNothing (replyStamp r) || replyStamp r /= before

    nap :: IO ()
    nap = threadDelay (max 0 (deckPollMs cfg) * 1000)

-- ---------------------------------------------------------------------------
-- The three commands
-- ---------------------------------------------------------------------------

-- | @agent-deck session send \<id\> \<message\>@.
--
-- The message is one @argv@ entry: no shell is involved, so it needs no
-- quoting, and @execve@ carries it whole. (@agent-deck@ also offers
-- @-message-file -@ for prompts too large for @ARG_MAX@; nothing this language
-- writes is close, and reaching for it would put a second failure mode — a
-- half-written pipe — on the common path.)
--
-- No liveness check precedes it, on purpose: @session send@ waits for the agent
-- to be ready before it types, which is a better version of the check this
-- module could make, and a session that cannot take a message at all fails here
-- with what it said about why.
sendMessage :: DeckConfig -> Deadline -> Text -> IO ()
sendMessage cfg dl message =
  void $
    deckCommand
      cfg
      dl
      ["session", "send", T.unpack (deckSession cfg), T.unpack message]

lookupStrings :: Text -> KM.KeyMap Value -> [Text]
lookupStrings key object = case KM.lookup (K.fromText key) object of
  Just (Array values) -> [value | String value <- V.toList values]
  _ -> []

lookupInteger :: Text -> KM.KeyMap Value -> Maybe Integer
lookupInteger key object = KM.lookup (K.fromText key) object >>= \case
  Number value -> either (const Nothing) Just (floatingOrInteger value :: Either Double Integer)
  String value -> readMaybe (T.unpack value)
  _ -> Nothing

flagValue :: [Text] -> [Text] -> Maybe Text
flagValue names = go
  where
    go [] = Nothing
    go [arg] = inline arg
    go (arg : value : rest)
      | arg `elem` names = Just value
      | otherwise = inline arg <|> go (value : rest)
    inline arg =
      let (name, suffix) = T.breakOn "=" arg
       in if name `elem` names then T.stripPrefix "=" suffix else Nothing

-- | @agent-deck session show \<id\> --json@, parsed.
sessionState :: DeckConfig -> Deadline -> IO SessionState
sessionState cfg dl = do
  (out, cmd) <- deckCommand cfg dl ["session", "show", T.unpack (deckSession cfg), "--json"]
  maybe (throwIO (DeckUnreadable cmd out)) pure (parseSessionState out)

-- | @agent-deck session output \<id\> --json@, parsed — 'Nothing' when the
-- session has not said anything this command can return.
--
-- A session with no reply yet is not an error: it is the ordinary state of a
-- session that was just started, and the caller's job is to keep waiting. So a
-- refusal to produce output is swallowed /here/ and nowhere else in this
-- module — and only that kind: a missing binary or an exhausted budget is
-- rethrown, because neither becomes true by waiting.
currentReply :: DeckConfig -> Deadline -> IO (Maybe Reply)
currentReply cfg dl = do
  r <- try (deckCommand cfg dl ["session", "output", T.unpack (deckSession cfg), "--json"])
  case r of
    Right (out, _) -> pure (parseReply out)
    Left e@DeckCommandFailed {} -> Nothing <$ chat cfg ("no output yet: " <> renderDeckError e)
    Left e@DeckUnreadable {} -> Nothing <$ chat cfg ("no output yet: " <> renderDeckError e)
    Left e -> throwIO e

-- | The timestamp of whatever the session last said, before this question is
-- put. 'Nothing' when there is nothing, which makes the first reply fresh.
currentStamp :: DeckConfig -> Deadline -> IO (Maybe Text)
currentStamp cfg dl = (>>= replyStamp) <$> currentReply cfg dl

-- | Run one @agent-deck@ command within what is left of the turn's budget, and
-- return its stdout together with the command as it would be typed (for a
-- failure message).
--
-- Stdout and stderr are read on two threads because a child that fills the
-- other pipe while this one is being drained deadlocks; both are decoded
-- leniently from UTF-8 rather than through the locale, so a reply with an em
-- dash in it survives a shell that says @LANG=C@.
deckCommand :: DeckConfig -> Deadline -> [String] -> IO (Text, Text)
deckCommand cfg dl args = do
  left <- remainingMs dl
  when (left <= 0) $
    timedOut ("the turn's budget was spent before `" <> cmdWords <> "` could be run")
  chat cfg ("$ " <> cmd)
  spawned <- try (timeout (left * 1000) capture)
  case spawned of
    Left e -> throwIO (DeckMissing (deckBinary cfg) (T.pack (show (e :: IOException))))
    Right Nothing -> timedOut ("`" <> cmdWords <> "` did not return in time")
    Right (Just (code, out, err)) -> case code of
      ExitSuccess -> pure (out, cmd)
      ExitFailure n -> throwIO (DeckCommandFailed cmd n (explain out err))
  where
    -- What the command said about its own failure. @agent-deck@ reports a
    -- refusal as JSON on *stdout* with an empty stderr — a missing session is
    -- @{"success":false,"code":"NOT_FOUND","error":"session 'x' not found"}@ and
    -- exit 2 — so a diagnostic that quoted stderr alone would say "exited 2"
    -- and nothing else, on the most common mistake there is.
    explain :: Text -> Text -> Text
    explain out err = case filter (not . T.null) [errorField out, trimAscii err, trimAscii out] of
      (d : _) -> clipText (oneLine d)
      [] -> ""

    errorField :: Text -> Text
    errorField out = maybe "" id (asObject out >>= lookupString "error")
    timedOut :: Text -> IO a
    timedOut = throwIO . DeckTimedOut (deckSession cfg) (deckTimeoutMs cfg)

    -- The command as it would be typed, for a diagnostic and for nothing else.
    -- A rendered question is one `argv` entry several lines long, so each
    -- argument is folded onto one line before it is clipped: a failure that
    -- reports the command has to stay one line, or the line that says which
    -- command failed is lost in the middle of the prompt that failed with it.
    cmd :: Text
    cmd = T.pack (deckBinary cfg) <> " " <> cmdWords

    -- The same without the executable, which in a timeout message is the one
    -- part the reader already knows and the longest thing on the line.
    cmdWords :: Text
    cmdWords = T.unwords (map (clipText . oneLine . T.pack) args)

    capture :: IO (ExitCode, Text, Text)
    capture =
      withCreateProcess
        (proc (deckBinary cfg) args) {std_out = CreatePipe, std_err = CreatePipe}
        $ \_ mOut mErr ph -> do
          outV <- newEmptyMVar
          errV <- newEmptyMVar
          void . forkIO $ putMVar outV =<< slurp mOut
          void . forkIO $ putMVar errV =<< slurp mErr
          out <- takeMVar outV
          err <- takeMVar errV
          code <- waitForProcess ph
          pure (code, utf8 out, utf8 err)

    -- A reader that cannot fail: a handle that errors mid-read must not leave
    -- the 'MVar' empty, which would block the parent until the turn's budget
    -- ran out and report a timeout for what was a read error.
    slurp :: Maybe Handle -> IO BS.ByteString
    slurp Nothing = pure BS.empty
    slurp (Just h) = either (\(_ :: IOException) -> BS.empty) id <$> try (BS.hGetContents h)

-- ---------------------------------------------------------------------------
-- Deadlines
-- ---------------------------------------------------------------------------

-- | A point on the monotonic clock, in nanoseconds. Monotonic and not
-- wall-clock, so a turn's budget is unaffected by a clock that steps.
newtype Deadline = Deadline Word64

deadlineIn :: Int -> IO Deadline
deadlineIn ms = do
  now <- getMonotonicTimeNSec
  pure (Deadline (now + fromIntegral (max 0 ms) * 1000000))

-- | Milliseconds left, never negative-wrapped: 'Word64' subtraction the other
-- way round would be an enormous positive number rather than a passed deadline.
remainingMs :: Deadline -> IO Int
remainingMs (Deadline end) = do
  now <- getMonotonicTimeNSec
  pure $ if now >= end then 0 else fromIntegral ((end - now) `div` 1000000)

-- ---------------------------------------------------------------------------
-- Small shared parts
-- ---------------------------------------------------------------------------

-- | Transport narration, on stderr, only when asked for. Distinct from
-- 'stderrLog', which reports what the /run/ did about an unreadable answer and
-- is never optional.
chat :: DeckConfig -> Text -> IO ()
chat cfg msg =
  when (deckVerbose cfg) $
    hPutStrLn stderr ("agent-deck: " <> T.unpack msg)

asObject :: Text -> Maybe (KM.KeyMap Value)
asObject raw = case A.decodeStrict (encodeUtf8 raw) of
  Just (Object o) -> Just o
  _ -> Nothing

lookupString :: Text -> KM.KeyMap Value -> Maybe Text
lookupString k o = case KM.lookup (K.fromText k) o of
  Just (String s) -> Just s
  _ -> Nothing

nonEmptyText :: Maybe Text -> Maybe Text
nonEmptyText = \case
  Just s | not (T.null s) -> Just s
  _ -> Nothing

utf8 :: BS.ByteString -> Text
utf8 = decodeUtf8With lenientDecode

-- | A fragment short enough for a one-line diagnostic.
clipText :: Text -> Text
clipText t
  | T.length t <= 120 = t
  | otherwise = T.take 117 t <> "..."

tshow :: (Show a) => a -> Text
tshow = T.pack . show

