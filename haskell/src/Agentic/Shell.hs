{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- |
-- Module      : Agentic.Shell
-- Description : The world that answers a @toolExec@ question by running its command.
--
-- D5: an addressee whose answer the __runner__ obtains by running a
-- program-authored command, so that a check can be an exit code rather than a
-- model's claim about one.
--
-- __It is a layer, not a world__ — @'WorldIO' -> 'WorldIO'@, exactly the shape
-- 'Agentic.Exec.announcingWorld' already has. Three consequences fall out of
-- that shape alone and are the reason for it: it composes with /every/ world
-- (scripted, deck, acp) identically; it is trivially removable; and
-- "Agentic.Exec" keeps its stated property that no declaration in it is
-- effectful except the interpreter — the process spawn is here, in a transport
-- module beside the two that already exist, and not there.
--
-- == The factorization theorem, and why it survives
--
-- The equation the whole @IO@ layer is held to (@Agentic\/Core\/Exec.lean:646@'s
-- @execM_pure@, with @Plan.execPure_fst@ @\@:747\@@) is
--
-- > runPlanIO (pureWorldIO w) p  ==  pure (runPlan w p, trace w p)
--
-- and D5 does not touch it, for a structural reason rather than an argued one:
-- 'executingWorld' is a @WorldIO -> WorldIO@, and @pureWorldIO w@ is not it.
-- Nothing in @runPlanIO@, @execIn@, @askOrMemo@, @questionKey@ or @memoLookup@
-- changes for D5. A pure 'Agentic.World.World' answers a @toolExec@ question
-- from its 'Agentic.World.WorldSpec' like any other question — @toWorld@
-- dispatches on the /code/, never on the addressee — so __the kernel executes
-- nothing, ever__, and the oracle's observation of a program full of
-- @toolExec@ asks is computed exactly as today.
--
-- == Why no capability lattice
--
-- Three facts, in decreasing order of importance.
--
--   1. __@cmd@ and @args@ are 'Text', not a prompt.__ There is no interpolation
--      syntax at an argv, so there is no path from any answer to any command
--      line. An authoring surface that offered @{name}@ inside an argv would
--      reintroduce every problem a grant lattice exists to bound, and must not
--      be written.
--   2. __The argv is in the value tier1 pins__, whole, as part of the printed
--      program: a command that changed would fail the freeze.
--   3. __The runner already spawns processes to answer questions__ —
--      "Agentic.AgentDeck" runs three subprocesses per question. D5 changes
--      /which/ process the runner spawns, not /whether/ it spawns one.
--
-- agent-functor needs a lattice because its @permitExec@ matches untrusted
-- input — argv the agent chose mid-turn. We are not declining a safety
-- mechanism; we are declining a problem, and this paragraph is where that is
-- said once.
module Agentic.Shell
  ( -- * The layer
    ShellConfig (..),
    defaultShellConfig,
    executingWorld,

    -- * Its named failures
    ShellError (..),
    renderShellError,

    -- * The answer table
    answerByRunning,
  )
where

import Agentic.Exec
  ( TurnGap (GapTransportRefusal),
    WorldIO (..),
    addresseeWord,
    codeWord,
    oneLine,
    raiseGap,
    trimAscii,
  )
import Agentic.Plan
  ( El,
    Q (..),
    SCode (SAck, SFlag, SText, SVerdict),
    fromSCode,
    verdictApprove,
    verdictObject,
  )
import Agentic.Raw (Addressee (AddrToolExec), Code)
import Control.Exception (Exception, IOException, try)
import Data.Text (Text)
import qualified Data.Text as T
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.Process (CreateProcess (cwd), proc, readCreateProcessWithExitCode)
import System.Timeout (timeout)

-- ---------------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------------

-- | What the executing layer needs that a question does not carry.
data ShellConfig = ShellConfig
  { -- | The directory a command runs in. Explicit and never inherited by
    -- accident: the runner sets it to the directory the engine works in — the
    -- per-run scratch under @--engine acp@, the process cwd under
    -- @--engine deck@, with the deck case /announced/, because the deck engine
    -- sends into a session somebody else started and the two need not agree.
    shellCwd :: !FilePath,
    -- | The wall clock a single command gets, in milliseconds. A hung command
    -- must produce a named failure rather than a hang, on the same principle
    -- @deckTimeoutMs@ already applies to a turn.
    shellTimeoutMs :: !Int,
    -- | Where the layer narrates what it ran.
    shellLog :: Text -> IO ()
  }

-- | The process's own directory, a two-minute budget, and a silent log.
defaultShellConfig :: ShellConfig
defaultShellConfig =
  ShellConfig
    { shellCwd = ".",
      shellTimeoutMs = 120000,
      shellLog = \_ -> pure ()
    }

-- ---------------------------------------------------------------------------
-- Failure of the mechanism, as opposed to failure of the command
-- ---------------------------------------------------------------------------

-- | __A command that ran and exited nonzero is not one of these.__ That is an
-- /answer/, and the answer table below is what it means. These are the ways the
-- gate could not be run at all, in the shape "Agentic.AgentDeck"'s @DeckError@
-- has, so that an operator can tell \"the gate said no\" from \"the gate could
-- not be run\".
--
-- Under D6 these classify as gaps; a nonzero exit never does, and must never
-- fail over — a red gate is not a reason to ask a different model.
data ShellError
  = -- | the command is not on @PATH@, or is not executable
    ShellMissing !Text !Text
  | -- | the command outlived its budget and was killed
    ShellTimedOut !Text !Int
  deriving (Eq, Show)

instance Exception ShellError

-- | A 'ShellError' as one sentence.
renderShellError :: ShellError -> Text
renderShellError = \case
  ShellMissing cmd why ->
    "the command `"
      <> cmd
      <> "` could not be run: "
      <> why
      <> ". The gate did not say no; it did not run."
  ShellTimedOut cmd ms ->
    "the command `"
      <> cmd
      <> "` did not finish within "
      <> T.pack (show ms)
      <> "ms and was killed. The gate did not say no; it did not finish."

-- ---------------------------------------------------------------------------
-- The layer
-- ---------------------------------------------------------------------------

-- | Answer a @toolExec@ question by running its command; hand every other
-- question to the world beneath.
--
-- __Composition order matters and belongs to the runner__: announcing
-- outermost, so the command's ask and its answer are narrated like every other
-- consultation; executing next, so the layer sits between the narration and the
-- engine. A @toolExec@ question is therefore answered before either adapter is
-- consulted, so neither @sayAcp@ nor @sayDeck@ ever sees one, no
-- @session\/prompt@ carries it, and ACP's permission handler is not the path by
-- which anything runs.
executingWorld :: ShellConfig -> WorldIO -> WorldIO
executingWorld cfg inner = WorldIO $ \c q -> case qAddressee q of
  AddrToolExec _ cmd args -> answerByRunning cfg c q cmd args
  _ -> worldAskIO inner c q

-- | The answer table, per code.
--
-- The rule in one sentence: __the exit status is the answer wherever the answer
-- type can express failure, and the run is abandoned where it cannot.__
--
-- +-------------+------------------+-------------------------------------------+
-- | code        | exit 0           | exit /n/ ≠ 0                              |
-- +=============+==================+===========================================+
-- | @receipt@   | @()@             | __abandon the run__                       |
-- | @flag@      | 'True'           | 'False'                                   |
-- | @verdict@   | approve          | object [first nonblank stderr line, else  |
-- |             |                  | stdout's, else @exited n@]                |
-- | @text@      | stdout, verbatim | __abandon the run__                       |
-- +-------------+------------------+-------------------------------------------+
--
-- @El ack@ has one inhabitant and @El text@ has no distinguished failure value,
-- so any answer manufactured for a nonzero exit would be /definitionally
-- identical in the memo table/ to one a successful command gave — which is
-- @askDecoding@'s own reason for abandoning rather than defaulting, and
-- @requiresCompletedTurn@'s for refusing an ack from an interrupted turn.
-- @flag@ and @verdict@ have exactly the room a failure needs: two values, and
-- objection lines. So a gate at @verdict@ never abandons and takes the objected
-- arm with the __command's own first failing line__ as the objection.
--
-- __Known cost, recorded.__ @grep@ exits 1 for \"no match\", which is an answer
-- and not a failure; under this table a @text@ ask on @grep@ abandons the run.
-- The author's escape is to ask it as a @flag@, or to name a command whose
-- nonzero exit really is a failure. The conservative side is taken because the
-- opposite mistake is the one with evidence behind it: coercing a failed turn
-- to @\"\"@ is what let a review report @done@ while three of its five reviewers
-- had produced nothing.
--
-- __The words go to the child's standard input.__ The argv is program-authored
-- and interpolation-free; the prompt is interpolated and is /data/. Writing it
-- to stdin gives the words a meaning at this addressee, keeps splices on the
-- data channel where they are harmless, and lets a check script read what it is
-- checking. A command that never reads stdin does not wedge the run: the writer
-- is forked and its broken pipe is ignored.
--
-- __No shell.__ @proc cmd args@, never @system@ or @sh -c@. @cmd@ resolves on
-- @PATH@ when it has no directory part, the same rule @deckBinary@ documents.
answerByRunning ::
  forall (c :: Code).
  ShellConfig ->
  SCode c ->
  Q c ->
  Text ->
  [Text] ->
  IO (El c)
answerByRunning cfg c q cmd args = do
  shellLog cfg $
    "run "
      <> cmd
      <> (if null args then "" else " " <> T.unwords args)
      <> " (for the "
      <> codeWord (fromSCode c)
      <> " question put to "
      <> addresseeWord (qAddressee q)
      <> ")"
  outcome <-
    timeout (shellTimeoutMs cfg * 1000) $
      try @IOException
        ( readCreateProcessWithExitCode
            (proc (T.unpack cmd) (map T.unpack args)) {cwd = Just (shellCwd cfg)}
            (T.unpack (qPrompt q))
        )
  case outcome of
    -- A mechanism failure, not an answer: a gap, so the run policy prices it
    -- and the fail-over walk may act on it.
    Nothing ->
      gap (ShellTimedOut cmd (shellTimeoutMs cfg))
    Just (Left e) ->
      gap (ShellMissing cmd (T.pack (show e)))
    Just (Right (code, out, err)) -> answerAt code (T.pack out) (T.pack err)
  where
    gap :: ShellError -> IO a
    gap e =
      raiseGap
        GapTransportRefusal
        (renderShellError e)
        (userError (T.unpack (renderShellError e)))

    answerAt :: ExitCode -> Text -> Text -> IO (El c)
    answerAt code out err = case c of
      SAck -> case code of
        ExitSuccess -> pure ()
        ExitFailure n -> abandon n out err
      SText -> case code of
        ExitSuccess -> pure out
        ExitFailure n -> abandon n out err
      SFlag -> pure (code == ExitSuccess)
      SVerdict -> case code of
        ExitSuccess -> pure verdictApprove
        ExitFailure n -> pure (verdictObject [objection n out err])

    -- The command's own first failing line, which is what a model was being
    -- asked to reproduce faithfully and was not.
    objection :: Int -> Text -> Text -> Text
    objection n out err =
      case firstNonblank err ++ firstNonblank out of
        (l : _) -> l
        [] -> "exited " <> T.pack (show n)

    firstNonblank :: Text -> [Text]
    firstNonblank t = take 1 (filter (not . T.null) (map trimAscii (T.lines t)))

    abandon :: Int -> Text -> Text -> IO x
    abandon n out err =
      ioError . userError . T.unpack $
        "the command `"
          <> cmd
          <> "` exited "
          <> T.pack (show n)
          <> " answering a "
          <> codeWord (fromSCode c)
          <> " for "
          <> addresseeWord (qAddressee q)
          <> ", and a "
          <> codeWord (fromSCode c)
          <> " has no value that says so: the run is abandoned rather than "
          <> "recording an answer indistinguishable, in the table, from one a "
          <> "command that succeeded gave. (prompt: '"
          <> oneLine (qPrompt q)
          <> "'; it said: '"
          <> oneLine (T.take 400 (err <> out))
          <> "'). Ask it as a `flag` or a `verdict` if a nonzero exit is an "
          <> "answer here."
