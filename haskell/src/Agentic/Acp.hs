-- | An ACP adapter, spawned and spoken to, as an answering service.
--
-- "Agentic.Exec" runs a plan against a 'WorldIO'; this module builds one out of
-- a child process that speaks the Agent Client Protocol — line-delimited
-- JSON-RPC 2.0 over its stdio — so that a program written in
-- "Agentic.Builder" can be executed by Claude's or Codex's ACP adapter. It is
-- the Haskell counterpart of @Agentic\/Core\/Acp.lean@ (the transport) driven
-- by @Agentic\/Core\/Exec.lean@'s @Exec.oracle@ (the discipline), and it is the
-- sibling of "Agentic.AgentDeck", which reaches an agent the other way: through
-- the @agent-deck@ command line, into a session somebody else started.
--
-- == What this transport can promise that the deck cannot
--
-- @Exec.requiresCompletedTurn@ (@Exec.lean:1190@, ported as
-- 'requiresCompletedTurn') says that an @ack@ — or /any/ answer from a person —
-- may not be recorded from a turn the agent did not finish: @Decode .ack@ is
-- total, so a receipt from an interrupted turn is the same term in the table as
-- one from a completed act, and recording it would be recording an act nobody
-- performed. "Agentic.AgentDeck" says in as many words that it __cannot__ apply
-- that rule, because the @agent-deck@ CLI reports no stop reason.
--
-- __ACP does.__ @session\/prompt@ answers with a @stopReason@, one of five
-- words of which exactly one — @end_turn@ — means the agent finished
-- ('StopReason', 'stopCompleted'). So an act's completion is /verifiable here/,
-- and 'sayAcp' abandons the run on a @cancelled@ act instead of quietly
-- recording a receipt. That is the whole reason this transport exists beside
-- the deck's, and it is the one place a run's meaning depends on which one was
-- used — not because the semantics differ (a world is a function of the
-- question, whichever pipe carried it), but because this one can refuse to
-- write down something that did not happen.
--
-- == The wire, in four calls
--
-- 1. @initialize@ — @protocolVersion: 1@ (an /integer/, and it is checked in
--    the reply), @clientCapabilities@ advertising no filesystem and no
--    terminal, and a @clientInfo@. The reply's @agentCapabilities@ is captured
--    ('Capabilities', 'acpCapabilities').
-- 2. @session\/new@ — @{cwd, mcpServers: []}@, @cwd@ made absolute because the
--    protocol requires it; the reply's @sessionId@ is what prompts go to.
-- 3. @session\/prompt@ — @{sessionId, prompt: [{type:\"text\", text}]}@, one
--    per question (per /attempt/: a re-ask is a second prompt). While it is
--    outstanding the adapter streams @session\/update@ notifications, and
--    __only @agent_message_chunk@ is an answer__ ('chunkText'): the other kinds
--    measured on the real wire — @usage_update@, @tool_call@,
--    @tool_call_update@, @available_commands_update@, @session_info_update@,
--    @config_option_update@ — are progress, and are ignored. The request's own
--    reply ends the turn, so no heuristic decides when the agent has stopped
--    speaking.
-- 4. @session\/request_permission@ — the agent asking /us/, mid-turn. See
--    below.
--
-- Everything else the agent may ask of us — every @fs\/*@ and @terminal\/*@
-- method — is answered @-32601@, honestly, because the handshake advertised no
-- such capability.
--
-- == Every addressee is this adapter
--
-- A question carries an 'Agentic.Raw.Addressee' — @model \"reviewer-secure\"@,
-- @tool \"apply\"@, @person \"owner\"@ — and all three kinds are prompted here,
-- the person included. Lean has a second route for that one
-- (@Settings.askPersonOnStdin@, a question printed on stderr and a line read
-- from stdin) and its CLI turns it on for a /live/ adapter and off for the
-- stub, which answers for the human; this port has only the off position, which
-- is the stub's, and a run against a live adapter therefore lets the agent play
-- the owner. That is a limitation of this version and is named rather than
-- hidden: the addressee is not lost — it is the first thing 'renderQ' says — but
-- nothing here asks a human anything.
--
-- == Which questions may write
--
-- 'permissionByCode' is @Exec.permissionByCode@ (@Exec.lean:925@): a tool call
-- requested during an __act__ is granted, and one requested during an ask —
-- text, verdict or flag — is declined in the schema's own words
-- (@{\"outcome\":\"cancelled\"}@). The policy is a function of the /question/
-- and not of the connection, which is the repair of a measured defect: with one
-- connection-wide @grant@, an agent drafting a patch could rewrite the
-- workspace during a turn that had asked it only to think. 'sayAcp' sets the
-- policy immediately before each prompt, because "the question under way" is a
-- fact it has and the pump does not.
--
-- Every decision is announced on stderr through 'Agentic.Exec.stderrLog', which
-- is @Settings.onPermission@'s default (@Exec.lean:1034@): a run that denied an
-- agent the workspace and paid a retry for it must not look identical to one
-- nobody asked anything of.
--
-- == A question forgets its predecessors
--
-- 'acpFreshPerQuestion' defaults to 'True' and is @Settings.freshSessionPerQuestion@
-- (@Exec.lean:1012@): a new @session\/new@ before every question, because a
-- world is a function of the /question/ (@World.lean@ — @Ω := (c : Code) → Q c
-- → El c@) and a single session is a memory of the ones before it. It is an
-- approximation and it is a policy, not a theorem: nothing here can make an
-- agent forget. Where a run continues somebody else's transcript the two are
-- alternatives rather than companions — which is why Lean turns it off under
-- @--session@; this port has no @--session@ (see the departures below), so the
-- rule reduces to "always fresh".
--
-- == What is not here
--
-- Decoding, re-asking and abandonment-on-unreadable are "Agentic.Exec"'s
-- ('askDecoding'), exactly as in "Agentic.AgentDeck", so a run against an
-- adapter and a run against a table fail in the same words. The rendered
-- question is 'renderQ' — imported from "Agentic.AgentDeck", never re-worded,
-- because @Exec.renderQ@ is one function in Lean and two copies of a prompt
-- header is how two transports come to tell an addressee two different answer
-- formats.
--
-- == Deliberate departures from @Agentic\/Core\/Acp.lean@
--
-- * __One clock, not two.__ Lean bounds a single pipe operation
--   (@readTimeoutMs@) /and/ a whole request (@turnTimeoutMs@). Here
--   'acpTurnTimeoutMs' bounds the whole request and nothing else: a blocked
--   read happens inside a request, so the request's budget already interrupts
--   it, and one clock is one number for an operator to set.
-- * __No message fuel.__ Lean's @maxMessages@ exists so that no loop in that
--   file is @partial@; Haskell needs no such argument, and a chattering adapter
--   is bounded by the wall clock, which is the bound that was doing the work.
-- * __A foreign response id is an error__ ('AcpIdMismatch'), where Lean skips
--   it and keeps pumping. This client has at most one request outstanding and
--   answers the agent's requests with the agent's own ids, so a @result@ whose
--   id is not the one in flight is a desynchronized stream, and continuing to
--   read one is how a reply gets attributed to the wrong question.
-- * __No @session\/load@, no @session\/fork@, no scope calls.__ v1 opens
--   sessions of its own; the model and mode axes travel in 'renderQ'\'s header,
--   which is the fallback @Exec.lean@ documents for a transport with no call
--   for them (it is what "Agentic.AgentDeck" does, for want of any call at
--   all). Capabilities are still read at the handshake, because that is what a
--   client that later wants to ask for a handoff must not skip.
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Agentic.Acp
  ( -- * The configuration
    AcpConfig (..),
    defaultAcpConfig,

    -- * Which program is the adapter
    adapterArgv,
    resolveArgv,
    stubScript,
    claudePin,
    codexPin,

    -- * The connection
    Acp,
    withAcp,
    acpProgram,
    acpCapabilities,
    acpSessionId,

    -- * The answering service
    worldOfAcp,
    sayAcp,

    -- * The calls
    newSession,
    promptTurn,

    -- * What the agent advertised
    Capabilities (..),
    capabilitiesOf,

    -- * How a turn ended
    StopReason (..),
    stopReasonOfText,
    renderStopReason,
    stopCompleted,
    Turn (..),

    -- * Which questions may write
    Permission (..),
    permissionByCode,
    pickAllow,
    permissionChoice,
    permissionResponse,
    permissionTool,
    PermissionDecision (..),
    renderPermissionDecision,

    -- * What an update says
    chunkText,

    -- * Failure
    AcpError (..),
    renderAcpError,
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception
  ( Exception,
    IOException,
    SomeException,
    bracket,
    onException,
    throwIO,
    try,
  )
import Control.Monad (void, when)
import Data.Aeson (Value (..), object, (.=))
import qualified Data.Aeson as A
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.Lazy as BL
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Scientific (toBoundedInteger)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Text.Encoding (decodeUtf8With)
import Data.Text.Encoding.Error (lenientDecode)
import qualified Data.Vector as V
import System.Directory (canonicalizePath, doesFileExist)
import System.Environment (lookupEnv)
import System.Exit (ExitCode)
import System.FilePath (splitSearchPath, (</>))
import System.IO
  ( BufferMode (BlockBuffering, LineBuffering),
    Handle,
    hClose,
    hFlush,
    hSetBinaryMode,
    hSetBuffering,
    stdout,
  )
import System.Process
  ( CreateProcess (..),
    ProcessHandle,
    StdStream (CreatePipe, Inherit),
    createProcess,
    getProcessExitCode,
    proc,
    terminateProcess,
    waitForProcess,
  )
import System.Timeout (timeout)

import Agentic.AgentDeck (renderQ)
import Agentic.Exec
  ( WorldIO (..),
    addresseeWord,
    askDecoding,
    codeWord,
    defaultRetries,
    requiresCompletedTurn,
    stderrLog,
    trimAscii,
  )
import Agentic.Plan (Q (..), SCode, fromSCode)
import Agentic.Raw (Addressee, Code (CodeAck))

-- ---------------------------------------------------------------------------
-- The configuration
-- ---------------------------------------------------------------------------

-- | Which program to start, where it runs, how long one turn may take, and
-- whether each question gets a session of its own.
--
-- @acpCommand@ is an @argv@ and not a program plus a shell string: no shell is
-- involved anywhere in this module, so an adapter argument needs no quoting and
-- cannot be re-split. 'adapterArgv' builds one from the name a command line
-- says, and 'resolveArgv' turns it into the @argv@ that is actually executed.
--
-- There is deliberately no retry knob: how many times an unreadable answer is
-- re-asked is 'Agentic.Exec.defaultRetries', a fact about the language's
-- trusted base rather than about this transport.
data AcpConfig = AcpConfig
  { -- | The adapter's @argv@; the head is the program.
    acpCommand :: ![String],
    -- | The session's working directory — where the adapter is started, what
    -- @session\/new@ is told, and therefore the only place an act is authorized
    -- to write.
    acpCwd :: !FilePath,
    -- | Milliseconds one request may take in total, after which the child is
    -- killed and 'AcpTimedOut' names the question. @0@ or less is unbounded.
    acpTurnTimeoutMs :: !Int,
    -- | Open a new session before every question. 'True' by default; see the
    -- module header.
    acpFreshPerQuestion :: !Bool,
    -- | Narrate the transport — every call, every turn — on stderr.
    acpVerbose :: !Bool
  }
  deriving (Eq, Show)

-- | The configuration for an @argv@, with Lean's own defaults: the current
-- directory, fifteen minutes to a turn (@Acp.Config.turnTimeoutMs@,
-- @Acp.lean:482@ — a real turn that writes code can legitimately run for
-- minutes), and a session per question.
defaultAcpConfig :: [String] -> AcpConfig
defaultAcpConfig argv =
  AcpConfig
    { acpCommand = argv,
      acpCwd = ".",
      acpTurnTimeoutMs = 900000,
      acpFreshPerQuestion = True,
      acpVerbose = False
    }

-- ---------------------------------------------------------------------------
-- Which program is the adapter
-- ---------------------------------------------------------------------------

-- | Where the test double lives, relative to this directory. @Acp.lean:193@
-- names it relative to the repository root; @haskell\/@ is one level down, so
-- the path is one @..@ longer and names the same file.
stubScript :: FilePath
stubScript = "../test/stub_adapter.py"

-- | The machine-local pin for the claude adapter (@Acp.lean:186@), used only
-- when @claude-agent-acp@ is not on @PATH@. A store path is machine-local by
-- construction; naming it is what makes an unconfigured run work on the owner's
-- machine without making it a dependency anywhere else.
claudePin :: FilePath
claudePin =
  "/nix/store/vhmm2z9psm5vcwgl8p6sa4c99y4chn0m-claude-agent-acp-0.64.0/bin/claude-agent-acp"

-- | The machine-local pin for the codex adapter (@Acp.lean:190@); see
-- 'claudePin'.
codexPin :: FilePath
codexPin = "/nix/store/i0wl19lx66n2093bv9g4g3lsxj16f9ry-codex-acp-0.13.0/bin/codex-acp"

-- | @Acp.Adapter.ofName@ (@Acp.lean:217@) and the pure half of
-- @Adapter.resolve@: the @argv@ a command line's word names.
--
-- Three names and a fallback, exactly as Lean has them — @stub@ is the
-- deterministic double run under @python3@, @claude@ and @codex@ are the two
-- real adapters by the names they install themselves under, and anything else
-- is read as a path, so a caller can point at an adapter this module has never
-- heard of.
--
-- What is /not/ decided here is where those two programs are: that is
-- 'resolveArgv', because it is a question about this machine.
adapterArgv :: Text -> [String]
adapterArgv name
  | name == "stub" = ["python3", stubScript]
  | name == "claude" = ["claude-agent-acp"]
  | name == "codex" = ["codex-acp"]
  | otherwise = [T.unpack name]

-- | @Acp.Adapter.resolve@ (@Acp.lean:285@) in @IO@: the @argv@ that will
-- actually be executed.
--
-- Two things happen, and both are Lean's:
--
-- * __the program__ — a bare name with a machine-local pin is looked for on
--   @PATH@ first and at the pin second, and being in neither place is an error
--   /here/, naming both places, rather than an @ENOENT@ from @spawn@ naming
--   neither. (On macOS it would not even be that: a failed exec can surface as
--   a child that exits nonzero, so without this the diagnosis for "the tool is
--   not installed" is an exit code.) A name with no pin is left to @execvp@,
--   and a path is taken as given;
-- * __the arguments__ — one that names a file relative to /this/ directory is
--   made absolute, because the child is started in the run's own working
--   directory, where @..\/test\/stub_adapter.py@ names nothing
--   (@AcpSmoke.lean:355@ does the same by hand, and for the same reason).
resolveArgv :: [String] -> IO [String]
resolveArgv [] = throwIO (AcpAdapterMissing "" "an empty argv names no program")
resolveArgv (prog : args) = (:) <$> resolveProgram prog <*> traverse absolutize args
  where
    resolveProgram :: String -> IO String
    -- A path is taken as given, and made absolute if it names something here:
    -- an adapter path is written relative to the directory the command line was
    -- typed in, and the child is started in the run's own directory, where the
    -- same words name nothing.
    resolveProgram p
      | '/' `elem` p = absolutize p
      | otherwise = case adapterPin p of
          Nothing -> pure p
          Just pin ->
            searchPath p >>= \case
              Just found -> pure found
              Nothing -> do
                there <- doesFileExist pin
                if there
                  then pure pin
                  else
                    throwIO . AcpAdapterMissing p $
                      "it is not on PATH and the machine-local pin '"
                        <> T.pack pin
                        <> "' does not exist"

    absolutize :: String -> IO String
    absolutize a
      | '/' `notElem` a = pure a
      | otherwise = do
          there <- doesFileExist a
          if there then canonicalizePath a else pure a

-- | The two programs this module knows a store path for.
adapterPin :: String -> Maybe FilePath
adapterPin = \case
  "claude-agent-acp" -> Just claudePin
  "codex-acp" -> Just codexPin
  _ -> Nothing

-- | The first entry of @PATH@ holding a file of this name (@Acp.lean:258@).
searchPath :: String -> IO (Maybe FilePath)
searchPath name =
  lookupEnv "PATH" >>= \case
    Nothing -> pure Nothing
    Just path -> firstFile [dir </> name | dir <- splitSearchPath path, not (null dir)]
  where
    firstFile [] = pure Nothing
    firstFile (p : ps) = do
      -- A directory of this name is not the program: `doesFileExist` is false
      -- for one, which is Lean's `pathExists && !isDir` in one call.
      there <- doesFileExist p
      if there then pure (Just p) else firstFile ps

-- ---------------------------------------------------------------------------
-- Failure
-- ---------------------------------------------------------------------------

-- | The six ways this transport fails, each named, because an operator reading
-- one of these has to know whether to install something, restart something, or
-- wait longer.
--
-- Decode exhaustion is __not__ here, and neither is the refusal to record an
-- unfinished act: the first is "Agentic.Exec"'s error and the second is
-- 'sayAcp'\'s, both raised as an @IOError@ with Lean's own wording, because
-- both are failures to /read/ or /credit/ an answer rather than failures to
-- obtain one. The split is the same one "Agentic.AgentDeck" makes.
data AcpError
  = -- | The adapter could not be started or could not be found: the program,
    -- and where it was looked for.
    AcpAdapterMissing !String !Text
  | -- | The adapter closed its output or died while a request was outstanding:
    -- the program, and what was outstanding.
    AcpAdapterDied !Text !Text
  | -- | A line was not JSON, or not one of the three shapes JSON-RPC admits:
    -- the program, what was wrong, the offending line.
    AcpNotJson !Text !Text !Text
  | -- | A reply arrived for a request this client did not make: the program,
    -- the id in flight, the id that arrived.
    AcpIdMismatch !Text !Text !Text
  | -- | The protocol was spoken but not as v1 requires: the program, and what
    -- was missing or wrong.
    AcpProtocol !Text !Text
  | -- | The agent answered a call with a JSON-RPC error: the program, the
    -- method, the error object.
    AcpRefused !Text !Text !Text
  | -- | A request outran 'acpTurnTimeoutMs': the program, the budget, and the
    -- question that was being put.
    AcpTimedOut !Text !Int !Text
  deriving (Eq, Show)

instance Exception AcpError

-- | An 'AcpError' as one sentence, for a CLI that would rather print a line
-- than a constructor.
renderAcpError :: AcpError -> Text
renderAcpError = \case
  AcpAdapterMissing prog why ->
    "no adapter '" <> T.pack prog <> "': " <> why
  AcpAdapterDied prog what ->
    "'" <> prog <> "' closed its output while " <> what <> " was outstanding"
  AcpNotJson prog why line ->
    "'"
      <> prog
      <> "' said a line this client could not read ("
      <> why
      <> "); offending line: '"
      <> clipText (trimAscii line)
      <> "'"
  AcpIdMismatch prog wanted got ->
    "'"
      <> prog
      <> "' answered request "
      <> got
      <> " while request "
      <> wanted
      <> " was the one in flight; the stream is out of step and no reply can be "
      <> "attributed to a question"
  AcpProtocol prog why ->
    "'" <> prog <> "' is not speaking ACP v1 as this client implements it: " <> why
  AcpRefused prog method err ->
    "'" <> prog <> "' answered '" <> method <> "' with error " <> clipText err
  AcpTimedOut prog ms what ->
    "'"
      <> prog
      <> "' did not answer "
      <> what
      <> " within "
      <> tshow ms
      <> "ms; it was killed. The question was abandoned rather than answered by "
      <> "this runtime"

-- ---------------------------------------------------------------------------
-- What the agent advertised
-- ---------------------------------------------------------------------------

-- | @Acp.Capabilities@ (@Acp.lean:376@): what the agent said at @initialize@,
-- in the two words a client acts on, plus everything it said.
--
-- The two flags are read from two places because the schema keeps them in two:
-- @loadSession@ is a top-level boolean and @fork@ is a /presence/ under
-- @sessionCapabilities@. Neither call is made by this port; they are read
-- because an absence must never be mistaken for a promise, and because the
-- client that one day asks for a handoff must ask before it sends.
data Capabilities = Capabilities
  { capLoadSession :: !Bool,
    capForkSession :: !Bool,
    -- | The @agentCapabilities@ object verbatim, or 'Null' if there was none.
    capRaw :: !Value
  }
  deriving (Eq, Show)

-- | @Acp.capabilitiesOf@ (@Acp.lean:393@). Total and forgiving in the direction
-- that costs nothing: anything unreadable reads as /not advertised/, so an
-- agent that said nothing advertised nothing.
capabilitiesOf :: Value -> Capabilities
capabilitiesOf initResult =
  Capabilities
    { capLoadSession = field "loadSession" agent == Just (Bool True),
      capForkSession = case field "sessionCapabilities" agent >>= field "fork" of
        Nothing -> False
        Just Null -> False
        Just _ -> True,
      capRaw = agent
    }
  where
    agent = maybe Null id (field "agentCapabilities" initResult)

-- ---------------------------------------------------------------------------
-- How a turn ended
-- ---------------------------------------------------------------------------

-- | @Acp.StopReason@ (@Acp.lean:691@): the protocol's account of why a turn
-- stopped. ACP v1 defines five words and this is them, plus 'StopOther' for a
-- word a future adapter invents, kept verbatim rather than flattened.
--
-- The distinction is not decoration: 'StopEndTurn' is the only one of the five
-- that means /the agent finished saying what it had to say/, and 'sayAcp'
-- refuses to record an acknowledgement from any of the others.
data StopReason
  = -- | The agent finished its turn. The only completed one.
    StopEndTurn
  | -- | The model hit its output limit mid-answer.
    StopMaxTokens
  | -- | The turn hit the adapter's cap on agent round trips.
    StopMaxTurnRequests
  | -- | The model declined to answer.
    StopRefusal
  | -- | The turn was cancelled — by the client, or by the adapter.
    StopCancelled
  | -- | A word this client does not know.
    StopOther !Text
  deriving (Eq, Show)

-- | @StopReason.ofString@ (@Acp.lean:709@).
stopReasonOfText :: Text -> StopReason
stopReasonOfText = \case
  "end_turn" -> StopEndTurn
  "max_tokens" -> StopMaxTokens
  "max_turn_requests" -> StopMaxTurnRequests
  "refusal" -> StopRefusal
  "cancelled" -> StopCancelled
  s -> StopOther s

-- | @StopReason.render@ (@Acp.lean:718@). Lean proves this a left inverse of
-- 'stopReasonOfText' (@render_ofString@) — losslessly, because the refusal to
-- credit an incomplete turn is only as good as the reading of the word
-- @end_turn@, and an operator reading a log is owed what /arrived/ rather than
-- what was understood.
renderStopReason :: StopReason -> Text
renderStopReason = \case
  StopEndTurn -> "end_turn"
  StopMaxTokens -> "max_tokens"
  StopMaxTurnRequests -> "max_turn_requests"
  StopRefusal -> "refusal"
  StopCancelled -> "cancelled"
  StopOther s -> s

-- | @StopReason.completed@ (@Acp.lean:759@): exactly one stop reason says the
-- agent finished, so a caller enforcing "the turn must have completed" is
-- enforcing one protocol word and not a heuristic.
stopCompleted :: StopReason -> Bool
stopCompleted StopEndTurn = True
stopCompleted _ = False

-- | @Acp.Turn@ (@Acp.lean:779@): what one @session\/prompt@ produced — every
-- @agent_message_chunk@ concatenated in arrival order, and the reason the turn
-- ended.
--
-- The stop reason is kept rather than dropped because @refusal@ and @cancelled@
-- are turns with (usually) empty text, and an interpreter that could not tell
-- those from an agent who said nothing would be recording an answer nobody
-- gave.
data Turn = Turn
  { turnText :: !Text,
    turnStop :: !StopReason
  }
  deriving (Eq, Show)

-- ---------------------------------------------------------------------------
-- Which questions may write
-- ---------------------------------------------------------------------------

-- | @Acp.Permission@ (@Acp.lean:326@): what this client answers a
-- @session\/request_permission@ request with.
--
-- 'Grant' selects the agent's own least-standing-authority allow option
-- ('pickAllow'). The assumption is stated and proved nowhere: the runtime is
-- speaking to an adapter it started, in a working directory the caller chose,
-- and a tool call inside that directory is authorized /by a question that asked
-- for one/.
--
-- 'Cancel' answers in the schema's own vocabulary — @{\"outcome\":\"cancelled\"}@
-- — which is the documented way to decline, and unlike a @-32601@ it tells the
-- agent that the request was understood and denied. (Lean measured the
-- alternative: a refused method makes the model retry with another tool and end
-- the turn with an apology, which is prose the decoder will read as an answer.)
data Permission = Grant | Cancel
  deriving (Eq, Show)

-- | @Exec.permissionByCode@ (@Exec.lean:925@): an act may write and an ask may
-- not.
--
-- This is a decision about /questions/, which is why it is a function of the
-- code and not a field of the connection. A connection-wide grant made @ask@
-- and @act@ indistinguishable to the permission layer, so a draft turn could
-- write to the workspace with the same authority as a consented act; that is
-- the defect this replaces, and @test\/stub_adapter.py --write-on-ask@ is its
-- negative control.
permissionByCode :: Code -> Addressee -> Permission
permissionByCode CodeAck _ = Grant
permissionByCode _ _ = Cancel

-- | @Acp.pickAllow@ (@Acp.lean:857@): the option selected when a request is
-- granted — @allow_once@ if the agent offered one, else @allow_always@, else
-- the first option of any kind, else nothing at all.
--
-- Least standing authority first, deliberately: @allow_once@ makes the agent
-- ask again for the next tool call, which costs one round trip and keeps every
-- act individually visible on the wire. A request with no options is not
-- grantable and falls through to @cancelled@.
pickAllow :: Value -> Maybe Text
pickAllow params = case field "options" params of
  Just (Array opts) ->
    let ofKind k = firstJust [optionId o | o <- V.toList opts, field "kind" o == Just (String k)]
     in case ofKind "allow_once" of
          Just i -> Just i
          Nothing -> case ofKind "allow_always" of
            Just i -> Just i
            Nothing -> firstJust (map optionId (take 1 (V.toList opts)))
  _ -> Nothing
  where
    optionId o = field "optionId" o >>= textOf
    firstJust = foldr (\x acc -> maybe acc Just x) Nothing

-- | @Acp.permissionChoice@ (@Acp.lean:878@): nothing at all under 'Cancel', and
-- 'pickAllow'\'s option under 'Grant'. Separated from the response it becomes
-- because the /decision/ is what a caller asserts about.
permissionChoice :: Permission -> Value -> Maybe Text
permissionChoice Cancel _ = Nothing
permissionChoice Grant params = pickAllow params

-- | @Acp.permissionResponse@ (@Acp.lean:898@): the schema's own two shapes.
-- Neither is an error, because a permission request is a question and not a
-- call the client failed to implement.
permissionResponse :: Maybe Text -> Value
permissionResponse = \case
  Nothing -> object ["outcome" .= object ["outcome" .= ("cancelled" :: Text)]]
  Just i ->
    object ["outcome" .= object ["outcome" .= ("selected" :: Text), "optionId" .= i]]

-- | @Acp.permissionTool@ (@Acp.lean:915@): the title of the tool call a request
-- is about. Total and forgiving — a decision that was made must be recorded
-- whether or not the agent described what it was for.
permissionTool :: Value -> Text
permissionTool params =
  maybe "an unnamed tool call" id (field "toolCall" params >>= field "title" >>= textOf)

-- | @Acp.PermissionDecision@ (@Acp.lean:341@): one request, answered — the
-- question that was under way, the tool call it asked for, and whether this
-- client granted it.
data PermissionDecision = PermissionDecision
  { decisionQuestion :: !Text,
    decisionTool :: !Text,
    decisionGranted :: !Bool
  }
  deriving (Eq, Show)

-- | @PermissionDecision.render@ (@Acp.lean:351@), verbatim including the pad
-- that keeps the two words the same width.
renderPermissionDecision :: PermissionDecision -> Text
renderPermissionDecision d =
  "permission "
    <> (if decisionGranted d then "granted" else "DENIED ")
    <> " to '"
    <> decisionTool d
    <> "' during "
    <> decisionQuestion d

-- ---------------------------------------------------------------------------
-- What an update says
-- ---------------------------------------------------------------------------

-- | @Acp.chunkText@ (@Acp.lean:825@): the text of a @session\/update@ when that
-- update is an @agent_message_chunk@, and 'Nothing' for every other kind.
--
-- The six other kinds measured on the real wire are progress, not answer, and
-- this client is entitled to ignore them and does. An @agent_message_chunk@
-- whose content is /not/ text is a protocol violation and is reported as one:
-- dropping it silently would lose an answer.
--
-- What this cannot do is tell an answer from the adapter's own narration — codex
-- was measured prefixing a turn with "Model metadata … not found" as a genuine
-- @agent_message_chunk@ — which is one more reason the trusted base downstream
-- is narrow.
chunkText :: Value -> Either Text (Maybe Text)
chunkText params = case field "update" params >>= field "sessionUpdate" >>= textOf of
  Nothing -> Left "a session/update carried no update.sessionUpdate string"
  Just kind
    | kind /= "agent_message_chunk" -> Right Nothing
    | otherwise -> case field "update" params >>= field "content" of
        Nothing -> Left "an agent_message_chunk carried no content"
        Just content -> case field "type" content >>= textOf of
          Just "text" -> case field "text" content >>= textOf of
            Just t -> Right (Just t)
            Nothing -> Left "an agent_message_chunk of type 'text' carried no text"
          Just ty -> Left ("agent_message_chunk carried content of type '" <> ty <> "', not 'text'")
          Nothing -> Left "an agent_message_chunk carried content with no type"

-- ---------------------------------------------------------------------------
-- The connection
-- ---------------------------------------------------------------------------

-- | A handle to one live adapter: a child that has completed the @initialize@
-- handshake, a private monotone supply of JSON-RPC ids, and the session prompts
-- are sent to.
--
-- It represents nothing whatever about what the process will say. No world, no
-- table and no transcript is reachable from it: this is where the proof
-- boundary begins, and every claim on the far side of it is made in
-- "Agentic.Exec" against a table the interpreter itself recorded.
data Acp = Acp
  { acpConfig :: !AcpConfig,
    -- | The resolved program, for messages that name what actually ran.
    acpProgram :: !String,
    acpStdin :: !Handle,
    acpStdout :: !Handle,
    acpChild :: !ProcessHandle,
    acpNextId :: !(IORef Int),
    acpSession :: !(IORef (Maybe Text)),
    acpCaps :: !(IORef Capabilities),
    -- | The question under way and how a permission request arriving during it
    -- is answered (@Acp.Conn.asked@, @Acp.lean:675@).
    acpAsked :: !(IORef (Text, Permission))
  }

-- | What the agent advertised at @initialize@, as the handshake read it.
acpCapabilities :: Acp -> IO Capabilities
acpCapabilities = readIORef . acpCaps

-- | The session prompts are going to, if one has been opened.
acpSessionId :: Acp -> IO (Maybe Text)
acpSessionId = readIORef . acpSession

-- | @Acp.withConn@ (@Acp.lean:1413@): one live conversation for the duration of
-- @k@, closed on every exit path, success or exception.
--
-- The bracket is the form callers should use. 'connectAcp' spawns, shakes hands
-- and opens a session; a failure in any of the three closes the child before
-- the error leaves, so a failed connect leaves no process behind.
withAcp :: AcpConfig -> (Acp -> IO a) -> IO a
withAcp cfg = bracket (connectAcp cfg) closeAcp

-- | Spawn the adapter, shake hands, and open a session.
connectAcp :: AcpConfig -> IO Acp
connectAcp cfg = do
  -- Flush first: spawning forks, and a fork can inherit the parent's unflushed
  -- stdout. Observed on macOS in the Lean runtime, where without this the first
  -- "message" read back was the parent's own output.
  hFlush stdout
  argv <- resolveArgv (acpCommand cfg)
  (prog, args) <- case argv of
    (p : as) -> pure (p, as)
    [] -> throwIO (AcpAdapterMissing "" "an empty argv names no program")
  chat cfg ("$ " <> T.unwords (map T.pack argv) <> " (cwd " <> T.pack (acpCwd cfg) <> ")")
  spawned <-
    try . createProcess $
      (proc prog args)
        { std_in = CreatePipe,
          std_out = CreatePipe,
          -- The child's stderr is the human's: an adapter's diagnostics are for
          -- the operator running the build and not for this parser.
          std_err = Inherit,
          cwd = Just (acpCwd cfg)
        }
  (hin, hout, ph) <- case spawned of
    Left (e :: IOException) -> throwIO (AcpAdapterMissing prog (T.pack (show e)))
    Right (Just hin, Just hout, _, ph) -> pure (hin, hout, ph)
    Right _ -> throwIO (AcpAdapterMissing prog "the child was started without both pipes")
  -- Bytes, not the locale's characters: the framing is the newline and the
  -- payload is UTF-8, which this module decodes itself.
  hSetBinaryMode hin True
  hSetBinaryMode hout True
  -- Buffered writes, flushed by hand at the end of every line: a prompt is one
  -- line and can be tens of kilobytes, and a message half-written is a message.
  hSetBuffering hin (BlockBuffering Nothing)
  hSetBuffering hout LineBuffering
  acp <-
    Acp cfg prog hin hout ph
      <$> newIORef 0
      <*> newIORef Nothing
      <*> newIORef (Capabilities False False Null)
      <*> newIORef ("no question (the handshake, or a caller that set none)", Cancel)
  flip onException (closeAcp acp) $ do
    handshake acp
    void (newSession acp)
    pure acp

-- | End the conversation. Every step is best-effort and swallows its own
-- failure, because this runs on exit paths — including failing ones, where a
-- second error would hide the first.
--
-- __Where this differs from Lean.__ @Acp.Conn.close@ (@Acp.lean:1366@) cancels,
-- kills and reaps. Here the turn in flight is cancelled, then __stdin is
-- closed__ and the child is given 'graceMs' to exit of its own accord — EOF on
-- stdin is how a conforming adapter is told the conversation is over, and one
-- that takes it exits @0@ and needs no signal. The kill is what happens when it
-- does not.
closeAcp :: Acp -> IO ()
closeAcp acp = do
  quietly (cancelTurn acp)
  quietly (hClose (acpStdin acp))
  waitFor (acpChild acp) graceMs >>= \case
    Just _ -> pure ()
    Nothing -> do
      chat (acpConfig acp) "the adapter did not exit on EOF; killing it"
      quietly (terminateProcess (acpChild acp))
      quietly (void (waitForProcess (acpChild acp)))
  where
    -- Every failure here is swallowed, and 'SomeException' is the width that
    -- matters rather than 'IOException': a cancellation written into a pipe
    -- whose far end has already died raises 'AcpAdapterDied', and a close that
    -- re-raised it would replace the error the run is actually about with the
    -- news that the corpse is cold.
    quietly :: IO () -> IO ()
    quietly act = void (try act :: IO (Either SomeException ()))

-- | How long a closing connection waits for the adapter to exit on EOF before
-- it kills it.
graceMs :: Int
graceMs = 1000

-- | Poll for the child's exit for at most this many milliseconds.
--
-- Polling rather than @timeout . waitForProcess@ on purpose: @waitForProcess@
-- blocks in a safe foreign call, which an asynchronous exception cannot
-- interrupt, so a timeout wrapped around it would be the hang it was meant to
-- prevent.
waitFor :: ProcessHandle -> Int -> IO (Maybe ExitCode)
waitFor ph ms
  | ms <= 0 = getProcessExitCode ph
  | otherwise =
      getProcessExitCode ph >>= \case
        Just code -> pure (Just code)
        Nothing -> threadDelay (20 * 1000) >> waitFor ph (ms - 20)

-- ---------------------------------------------------------------------------
-- The three shapes a line can have
-- ---------------------------------------------------------------------------

-- | @Rpc.Msg@ (@Rpc.lean:52@): one decoded line of the wire.
--
-- Ids stay raw 'Value' because a request from the agent must be answered with
-- the id it chose, unchanged: codex echoes a string id verbatim and claude uses
-- integers. The agent's ids and ours are drawn from different counters that
-- both start at zero, which is why the presence of @method@ is tested first.
data Msg
  = MsgResponse !Value !(Either Value Value)
  | MsgRequest !Value !Text !Value
  | MsgNotification !Text !Value

-- | @Rpc.Msg.ofLine@ (@Rpc.lean:62@). Failure carries the reason; the caller
-- still has the line.
--
-- It takes the bytes rather than the 'Text' they decode to, because the line is
-- UTF-8 and JSON is defined on bytes: reading it any other way would put a
-- second decoder between the adapter and the parser.
msgOfLine :: BS.ByteString -> Either Text Msg
msgOfLine line = case A.decodeStrict line of
  Nothing -> Left "the line is not JSON"
  Just j -> case field "method" j >>= textOf of
    Just method -> case field "id" j of
      Just i -> Right (MsgRequest i method (params j))
      Nothing -> Right (MsgNotification method (params j))
    Nothing -> case field "id" j of
      Nothing -> Left "the line is neither a request, a notification nor a response"
      Just i -> case field "error" j of
        Just e -> Right (MsgResponse i (Left e))
        Nothing -> Right (MsgResponse i (Right (maybe Null id (field "result" j))))
  where
    params j = maybe Null id (field "params" j)

-- ---------------------------------------------------------------------------
-- Reading and writing
-- ---------------------------------------------------------------------------

-- | Write one JSON value as one line, and flush: the framing /is/ the newline.
writeJson :: Acp -> Value -> IO ()
writeJson acp j = do
  r <- try (BL.hPut (acpStdin acp) (A.encode j <> "\n") >> hFlush (acpStdin acp))
  case r of
    Right () -> pure ()
    Left (_ :: IOException) ->
      throwIO (AcpAdapterDied (T.pack (acpProgram acp)) "a message this client was writing")

-- | One line of adapter output. Lines are not small: the real adapter's command
-- catalogue arrived as a single 39,598-byte line, and the stub reproduces it at
-- that size, so "the framing is the newline" is a claim this path has to keep.
readJsonLine :: Acp -> Text -> IO BS.ByteString
readJsonLine acp what = do
  r <- try (BS.hGetLine (acpStdout acp))
  case r of
    Right bs -> pure (BS.dropWhileEnd (== '\r') bs)
    -- End of file is the adapter closing its output; any other read error is
    -- the same conversation ending less politely, and the operator's next step
    -- is the same either way.
    Left (_ :: IOException) -> throwIO (AcpAdapterDied (T.pack (acpProgram acp)) what)

-- ---------------------------------------------------------------------------
-- The request loop
-- ---------------------------------------------------------------------------

-- | @Acp.Conn.pump@ (@Acp.lean:1042@): read messages until the reply to request
-- @wantId@ arrives, feeding every @agent_message_chunk@ to @onChunk@ on the way
-- and answering every request the agent makes of us as it comes.
--
-- @answering@ says whether the updates arriving belong to /this/ request. During
-- a @session\/prompt@ they do, and a chunk that is not text is a protocol
-- violation this client reports rather than drops, because dropping it would
-- lose an answer. During @session\/new@ they do not: what arrives there is the
-- adapter's own bookkeeping.
pump :: Acp -> Int -> Text -> (Text -> IO ()) -> Bool -> IO (Either Value Value)
pump acp wantId what onChunk answering = go
  where
    prog = T.pack (acpProgram acp)

    go :: IO (Either Value Value)
    go = do
      bytes <- readJsonLine acp what
      let line = decodeUtf8With lenientDecode bytes
      if BS.all (`elem` (" \t\r\n" :: String)) bytes
        then go
        else case msgOfLine bytes of
          Left why -> throwIO (AcpNotJson prog why line)
          Right (MsgResponse i payload)
            | intOf i == Just wantId -> pure payload
            | otherwise -> throwIO (AcpIdMismatch prog (tshow wantId) (compact i))
          Right (MsgRequest i method ps) -> answerAgentRequest acp i method ps >> go
          Right (MsgNotification method ps)
            | method /= "session/update" -> go
            | otherwise -> case chunkText ps of
                Left why
                  | answering -> throwIO (AcpProtocol prog (why <> "; line: " <> clipText line))
                  | otherwise -> go
                Right Nothing -> go
                Right (Just txt) -> onChunk txt >> go

-- | Answer a request the agent made of us.
--
-- @session\/request_permission@ is answered by the policy for the question under
-- way and the decision is announced; everything else — every @fs\/*@ and
-- @terminal\/*@ method — is answered @-32601@, honestly, because the handshake
-- advertised no such capability and a conforming agent should not have asked.
answerAgentRequest :: Acp -> Value -> Text -> Value -> IO ()
answerAgentRequest acp i method params
  | method == "session/request_permission" = do
      (question, policy) <- readIORef (acpAsked acp)
      let choice = permissionChoice policy params
          decision =
            PermissionDecision
              { decisionQuestion = question,
                decisionTool = permissionTool params,
                decisionGranted = maybe False (const True) choice
              }
      -- Reported unconditionally, which is `Settings.onPermission`'s default
      -- (`Exec.lean:1034`): granting an act is the run working, and denying one
      -- is why a turn cost what it cost.
      stderrLog (renderPermissionDecision decision)
      writeJson acp (rpcResult i (permissionResponse choice))
  | otherwise =
      writeJson acp . rpcErrorFrame i methodNotFound $
        method <> ": this client advertised no such capability"

-- | @Acp.Conn.tryRequest@ (@Acp.lean:1101@): send a request and hand back
-- __either__ the agent's @result@ __or__ the agent's @error@ object, as a value.
--
-- The 'Either' is the protocol's own error/result split and nothing else: a
-- transport failure is still an exception, because that is the conversation
-- ending rather than the agent declining.
--
-- The whole request is bounded by 'acpTurnTimeoutMs'; on expiry the child is
-- killed, because a read abandoned mid-line has desynchronized the stream and
-- ending the conversation is the only honest thing left to do.
tryRequest :: Acp -> Text -> Text -> Value -> (Text -> IO ()) -> Bool -> IO (Either Value Value)
tryRequest acp what method params onChunk answering = do
  i <- atomicModifyIORef' (acpNextId acp) (\n -> (n + 1, n))
  withTurnBudget acp what $ do
    writeJson acp (rpcRequest i method params)
    pump acp i what onChunk answering

-- | 'tryRequest', raising the agent's error if it sent one.
request :: Acp -> Text -> Text -> Value -> (Text -> IO ()) -> Bool -> IO Value
request acp what method params onChunk answering =
  tryRequest acp what method params onChunk answering >>= \case
    Right result -> pure result
    Left e -> throwIO (AcpRefused (T.pack (acpProgram acp)) method (compact e))

-- | Bound one request by the turn budget, killing the child on expiry.
withTurnBudget :: Acp -> Text -> IO a -> IO a
withTurnBudget acp what act
  | ms <= 0 = act
  | otherwise =
      timeout (ms * 1000) act >>= \case
        Just a -> pure a
        Nothing -> do
          void (try (terminateProcess (acpChild acp)) :: IO (Either IOException ()))
          throwIO (AcpTimedOut (T.pack (acpProgram acp)) ms what)
  where
    ms = acpTurnTimeoutMs (acpConfig acp)

-- | Send a notification: no id, and no reply expected or waited for.
notify :: Acp -> Text -> Value -> IO ()
notify acp method params = writeJson acp (rpcNotification method params)

-- ---------------------------------------------------------------------------
-- The calls
-- ---------------------------------------------------------------------------

-- | @Acp.Conn.handshake@ (@Acp.lean:1141@).
--
-- We advertise no filesystem and no terminal capability, so a conforming agent
-- sends us no @fs\/*@ or @terminal\/*@ request; @session\/request_permission@ is
-- not capability-gated and arrives anyway. @protocolVersion@ is /checked/ — it
-- insists on @1@, since the shapes here are v1's — and @agentCapabilities@ is
-- recorded on the connection.
handshake :: Acp -> IO ()
handshake acp = do
  res <-
    request
      acp
      "the initialize handshake"
      "initialize"
      ( object
          [ "protocolVersion" .= (1 :: Int),
            "clientCapabilities"
              .= object
                [ "fs" .= object ["readTextFile" .= False, "writeTextFile" .= False],
                  "terminal" .= False
                ],
            "clientInfo" .= object ["name" .= ("agentic-hs" :: Text), "version" .= ("0.1.0" :: Text)]
          ]
      )
      (const (pure ()))
      False
  case field "protocolVersion" res >>= intOf of
    Just 1 -> writeIORef (acpCaps acp) (capabilitiesOf res)
    Just v ->
      throwIO . AcpProtocol (T.pack (acpProgram acp)) $
        "it speaks ACP protocol version " <> tshow v <> "; this client implements 1"
    Nothing ->
      throwIO . AcpProtocol (T.pack (acpProgram acp)) $
        "initialize returned no protocolVersion: " <> clipText (compact res)

-- | @Acp.Conn.newSession@ (@Acp.lean:1169@): open a session in 'acpCwd' — made
-- absolute, because the protocol requires an absolute path — and remember its
-- id.
--
-- The @session\/update@ notifications that may arrive while this call is
-- outstanding are the adapter's own bookkeeping, not an answer, which is what
-- the 'False' below says.
newSession :: Acp -> IO Text
newSession acp = do
  dir <- canonicalizePath (acpCwd (acpConfig acp))
  res <-
    request
      acp
      "a new session"
      "session/new"
      (object ["cwd" .= dir, "mcpServers" .= ([] :: [Value])])
      (const (pure ()))
      False
  case field "sessionId" res >>= textOf of
    Just sid -> do
      writeIORef (acpSession acp) (Just sid)
      chat (acpConfig acp) ("session " <> sid)
      pure sid
    Nothing ->
      throwIO . AcpProtocol (T.pack (acpProgram acp)) $
        "session/new returned no sessionId: " <> clipText (compact res)

-- | @Acp.Conn.promptTurn@ (@Acp.lean:1306@): send one text prompt and collect
-- the turn. Chunks accumulate in arrival order; the request's own reply is what
-- ends the turn, so no heuristic decides when the agent has finished speaking.
promptTurn :: Acp -> Text -> Text -> IO Turn
promptTurn acp what text = do
  sid <-
    readIORef (acpSession acp) >>= \case
      Just sid -> pure sid
      Nothing ->
        throwIO (AcpProtocol (T.pack (acpProgram acp)) "no session; nothing was opened to prompt")
  acc <- newIORef []
  res <-
    request
      acp
      what
      "session/prompt"
      ( object
          [ "sessionId" .= sid,
            "prompt" .= [object ["type" .= ("text" :: Text), "text" .= text]]
          ]
      )
      (\chunk -> atomicModifyIORef' acc (\cs -> (chunk : cs, ())))
      True
  said <- T.concat . reverse <$> readIORef acc
  case field "stopReason" res >>= textOf of
    Just stop -> pure (Turn said (stopReasonOfText stop))
    Nothing ->
      throwIO . AcpProtocol (T.pack (acpProgram acp)) $
        "session/prompt returned no stopReason: " <> clipText (compact res)

-- | @Acp.Conn.cancel@ (@Acp.lean:1358@): cancel the turn in flight, if there is
-- a session at all. A notification, so it does not wait.
cancelTurn :: Acp -> IO ()
cancelTurn acp =
  readIORef (acpSession acp) >>= \case
    Nothing -> pure ()
    Just sid -> notify acp "session/cancel" (object ["sessionId" .= sid])

-- ---------------------------------------------------------------------------
-- The answering service
-- ---------------------------------------------------------------------------

-- | The adapter, as a 'WorldIO': open this question's session, put it, read
-- what came back, and re-ask once if the trusted base could not read it.
--
-- This is @Exec.oracle@ (@Exec.lean:1425@) with the scope calls left out (the
-- header carries both axes) and the session policy kept: 'acpFreshPerQuestion'
-- opens a session __once per question and not once per attempt__, because a
-- re-ask is the same question put again and not a different world.
--
-- Everything after that — 'askDecoding', 'defaultRetries', the re-ask warning,
-- the abandonment message — is "Agentic.Exec"'s, so a run against an adapter, a
-- run against an @agent-deck@ session and a run against a table fail in the same
-- words for the same reason.
--
-- The 'AcpConfig' is taken beside the connection rather than read off it,
-- because these two fields are the /caller's policy/ for the run — how a
-- question is isolated, and how loudly the transport narrates — where the
-- connection's copy is the recipe it was started from. Pass the one 'withAcp'
-- was given and the two are the same object.
worldOfAcp :: AcpConfig -> Acp -> WorldIO
worldOfAcp cfg acp = WorldIO $ \c q -> do
  when (acpFreshPerQuestion cfg) (void (newSession acp))
  askDecoding stderrLog defaultRetries c q (sayAcp cfg acp c q)

-- | @Exec.say@ (@Exec.lean:1286@) at this transport: name the question under
-- way, set the permission policy for it, prompt, and __insist that the bytes
-- are somebody's answer__.
--
-- The @extra@ is 'Agentic.Exec.nudge'\'s output on a re-ask and empty on a first
-- attempt; it is appended after the prompt, so the addressee sees what it said
-- and why it could not be read at the end of the message rather than before the
-- question.
--
-- Every turn that did not end in @end_turn@ is logged, whatever the code,
-- because an operator is owed the fact that the agent was cut off. A turn that
-- did not complete where 'requiresCompletedTurn' says one was needed __abandons
-- the run__, quoting the stop reason, the addressee and the words: the table
-- records a code, a question and an answer and nothing else, so a cell entered
-- from an interrupted turn is indistinguishable from one an addressee gave, and
-- no check further down can recover the difference. That is the same policy as
-- decode exhaustion, at the other kind of evidence.
sayAcp :: forall (c :: Code). AcpConfig -> Acp -> SCode c -> Q c -> Text -> IO Text
sayAcp cfg acp c q extra = do
  writeIORef (acpAsked acp) (what, permissionByCode code (qAddressee q))
  let message = renderQ c q <> extra
  chat cfg ("put " <> what <> " (" <> tshow (T.length message) <> " characters)")
  turn <- promptTurn acp what message
  chat cfg ("turn ended " <> renderStopReason (turnStop turn))
  if stopCompleted (turnStop turn)
    then pure (turnText turn)
    else do
      stderrLog $
        "turn for a "
          <> codeWord code
          <> " from "
          <> who
          <> " ended '"
          <> renderStopReason (turnStop turn)
          <> "', not 'end_turn'"
      when (requiresCompletedTurn code (qAddressee q)) $
        ioError . userError . T.unpack $
          "the turn that would have answered a "
            <> codeWord code
            <> " from "
            <> who
            <> " ended '"
            <> renderStopReason (turnStop turn)
            <> "' rather than completing (prompt: '"
            <> qPrompt q
            <> "'; what arrived: '"
            <> trimAscii (turnText turn)
            <> "'). The run is abandoned: an unfinished turn did not perform the act "
            <> "it was asked to perform, and a recorded acknowledgement of it would be "
            <> "indistinguishable, in the table, from one that did."
      pure (turnText turn)
  where
    code = fromSCode c
    who = addresseeWord (qAddressee q)
    -- How the record and the diagnosis name this question, and what
    -- `Acp.Conn.underQuestion` is handed (`Exec.lean:1290`), word for word.
    what = "the " <> codeWord code <> " question put to " <> who

-- ---------------------------------------------------------------------------
-- The four frames one can write
-- ---------------------------------------------------------------------------

-- | @Rpc.request@ (@Rpc.lean:86@). Our own ids are always numeric.
rpcRequest :: Int -> Text -> Value -> Value
rpcRequest i method params =
  object ["jsonrpc" .= ("2.0" :: Text), "id" .= i, "method" .= method, "params" .= params]

-- | @Rpc.notification@ (@Rpc.lean:91@).
rpcNotification :: Text -> Value -> Value
rpcNotification method params =
  object ["jsonrpc" .= ("2.0" :: Text), "method" .= method, "params" .= params]

-- | @Rpc.result@ (@Rpc.lean:95@), carrying the id of the request it answers —
-- the agent's own id, unchanged, whatever shape it had.
rpcResult :: Value -> Value -> Value
rpcResult i payload = object ["jsonrpc" .= ("2.0" :: Text), "id" .= i, "result" .= payload]

-- | @Rpc.errorFrame@ (@Rpc.lean:104@).
rpcErrorFrame :: Value -> Int -> Text -> Value
rpcErrorFrame i code message =
  object
    [ "jsonrpc" .= ("2.0" :: Text),
      "id" .= i,
      "error" .= object ["code" .= code, "message" .= message]
    ]

-- | The method does not exist, or is not available on this peer
-- (@Rpc.lean:115@).
methodNotFound :: Int
methodNotFound = -32601

-- ---------------------------------------------------------------------------
-- Small shared parts
-- ---------------------------------------------------------------------------

-- | Transport narration, on stderr, only when asked for. Distinct from
-- 'stderrLog', which reports what the /run/ did about something it noticed and
-- is never optional.
chat :: AcpConfig -> Text -> IO ()
chat cfg msg = when (acpVerbose cfg) (stderrLog ("acp: " <> msg))

field :: Text -> Value -> Maybe Value
field k = \case
  Object o -> KM.lookup (K.fromText k) o
  _ -> Nothing

textOf :: Value -> Maybe Text
textOf = \case
  String s -> Just s
  _ -> Nothing

intOf :: Value -> Maybe Int
intOf = \case
  Number n -> toBoundedInteger n
  _ -> Nothing

-- | A value as the one line a diagnostic quotes.
compact :: Value -> Text
compact = decodeUtf8With lenientDecode . BL.toStrict . A.encode

-- | A fragment short enough for a one-line diagnostic.
clipText :: Text -> Text
clipText t
  | T.length t <= 160 = t
  | otherwise = T.take 157 t <> "..."

tshow :: (Show a) => a -> Text
tshow = T.pack . show
