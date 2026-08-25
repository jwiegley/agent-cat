{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators #-}

-- |
-- Module      : Agentic.Exec
-- Description : The interpreter in @IO@: STM dependency scheduling, memoization, and decoding.
--
-- A port of @Agentic\/Core\/Exec.lean@ from the line where the theorems stop
-- (@Exec.lean:455@, \"the interpreter: a memoizing fold, with the answering
-- service an argument\") to the line where the transport begins. Three layers,
-- in Lean's order, and the order is the point:
--
-- 1. __The trusted base__ — 'decodeEl', @Exec.lean:265@'s @Decode@. It is one
--    total parser per code and it is not written here: every clause delegates
--    to "Agentic.Text", which is the byte-faithful port and the /only/ place in
--    this package that decides what an addressee's bytes mean. A second copy of
--    that decision is exactly what @Exec.lean:248@–@:249@ says must not exist.
-- 2. __The memoizing interpreter__ — 'runPlanIO' realizes @Exec.lean:503@'s
--    @Dlg.execM@ observable while scheduling dependency-ready asks concurrently.
--    Prompt support is carried by 'Expr'; STM answer cells block only consumers,
--    memo reservations ensure equal questions race to one consultation, and trace
--    tickets restore plan order. This is no longer Lean's sequential @rfl@
--    implementation at @IO@, so the claim retained here is the executable pure
--    factorization below, not definitional equality of operational steps.
-- 3. __The answering service__ — 'WorldIO', Lean's @Oracle IO@, passed in. The
--    only 'WorldIO' here is 'scriptedWorld'; the live one is
--    @Agentic.AgentDeck@'s 'worldOfDeck', and it is built from the same
--    'askDecoding' loop.
--
-- == What the run observes, and why it is the pure semantics' observable
--
-- 'runPlanIO' returns @(a, 'Trace')@, and the 'Trace' is "Agentic.World"'s:
-- __one 'Event' per ask node walked__, memo hit or not. The memo /table/ and the
-- transcript are two objects here where Lean makes them one, and the split is
-- deliberate:
--
-- * the table is Lean's @Table@ — consulted before asking and extended after
--   answering. The check, in-flight reservation and insertion are one STM state
--   transition, so two equal ready questions still invoke the service once.
--   (@Exec.lean:507@–@:511@). A question already answered is not put again.
-- * the trace is @Plan.trace@ — what the /plan/ consulted, repetitions and all,
--   so that 'billFresh' and 'billMemo' mean here what they mean in
--   "Agentic.World". Lean reads its bills off @Plan.trace@ too
--   (@Cost.lean@); reading them off the memo table would make 'billFresh' and
--   'billMemo' the same number by construction and the memo bill unfalsifiable.
--
-- Hence the invariant a caller may lean on, and which a test should pin:
--
-- > billFresh t == the number of ask nodes the run walked
-- > billMemo  t == the number of distinct successfully answered questions in t

-- Failed transport attempts and decode retries are operational work but have no
-- 'Event', so neither bill pretends to count them.
--
-- and, at a pure world ('pureWorldIO', Lean's @pureOracle@ at
-- @Exec.lean:618@), the factorization theorem @Exec.lean:646@ becomes an
-- equation anyone can run:
--
-- > runPlanIO (pureWorldIO w) p  ==  pure (runPlan w p, trace w p)
--
-- == What is deliberately not ported
--
-- The @Oracle@'s history argument (@Exec.lean:476@: @(c : Code) → Q c → Table →
-- m (El c)@) is dropped from 'WorldIO'. Adequacy quantifies over
-- history-dependent oracles, so an oracle that cannot see the history is a
-- special case of the ones @execM_adequacy@ covers: dropping the argument
-- weakens the /answerer/, never the theorem. Nothing downstream consults it —
-- neither the stub nor a CLI transport has a use for the table — and an argument
-- nobody reads invites somebody to start reading it.
--
-- Only the /semantics-adjacent/ half of @Exec.Settings@ is ported. Lean's
-- record carries two fields — @retries@ and @log@ — and 'ExecSettings' carries
-- both, under those meanings, plus the run policy this port owes an operator
-- ('TurnGap', the per-gap budgets, the recovery fork, the loud arm and the
-- standing unattended answer). What is /not/ ported is the transport half —
-- session policy, permission policy, ACP scope selection, turn reporting —
-- because those are facts about a transport this runner does not have, and
-- belong to whichever adapter does. 'requiresCompletedTurn' is here because it
-- is a decision about what bytes may mean and an adapter that can observe how a
-- turn ended owes it.
--
-- __Every default in 'defaultExecSettings' reproduces the behaviour this module
-- had before it existed.__ The two settings-taking entry points
-- ('askDecodingWith', 'scriptedWorldWith') at 'defaultExecSettings' are the two
-- that do not take settings ('askDecoding' at 'defaultRetries',
-- 'scriptedWorld'), question for question and byte for byte in the log; the
-- policy is opt-in or it is not policy.
module Agentic.Exec
  ( -- * The answering service
    WorldIO (..),
    concurrentWorld,
    TurnLane,
    newTurnLaneIO,
    pureWorldIO,
    announcingWorld,

    -- * The interpreter
    runPlanIO,
    runPlanWith,

    -- * Fail-over
    Chains (..),
    noChains,
    chainsOf,
    candidates,
    TurnGapError (..),
    raiseGap,
    withTransportGaps,

    -- * The trusted base, at the typed answer
    decodeEl,
    sayEl,

    -- * The failure vocabulary, and the run policy
    TurnGap (..),
    gapWord,
    Recovery (..),
    GapAsk (..),
    Recover,
    budgetedRecovery,
    ExecSettings (..),
    defaultExecSettings,
    gapBudget,

    -- * The decode loop
    attemptDecoding,
    askDecoding,
    askDecodingWith,
    defaultRetries,
    stderrLog,

    -- * What a question says about itself on the wire
    codeWord,
    addresseeWord,
    answerSpec,
    nudge,
    requiresCompletedTurn,

    -- * Whose words a reply is
    transportBanners,
    splitTransportNarration,

    -- * The scripted world
    scriptedWorld,
    scriptedWorldWith,
    scriptedReply,
    scriptedDefault,

    -- * Rendering helpers
    oneLine,
    trimAscii,
  )
where

import Agentic.Plan
  ( El,
    Env (ECons, ENil),
    Expr,
    Plan (PAsk, PAskC, PCase, PDyn, PRet),
    Q (..),
    Shape (..),
    SCode (SAck, SFlag, SStructured, SText, SVerdict),
    defaultEl,
    evalExpr,
    exprUses,
    fromSCode,
    shapeOf,
    withPrompt,
  )
import Agentic.Raw
  ( Addressee (AddrModel, AddrPerson, AddrTool, AddrToolExec),
    Code,
    SomeCode (..),
  )
import Agentic.Schema (sameCode)
import Agentic.Schema.Json (decode, render, renderSchema)
import Agentic.Text (decodeFlag, decodeVerdict, sayFlag, sayVerdict)
import Agentic.Plan (QScope (scopeModelAxis))
import Agentic.WF (wft)
import Agentic.World
  ( Event (Event),
    EventKey,
    Trace,
    World (worldAnswer),
    eventKey,
  )
import Control.Concurrent (ThreadId, forkFinally, killThread)
import Control.Concurrent.STM
  ( STM,
    TMVar,
    TVar,
    atomically,
    modifyTVar',
    newEmptyTMVar,
    newEmptyTMVarIO,
    newTMVarIO,
    newTVarIO,
    orElse,
    putTMVar,
    readTMVar,
    readTVar,
    throwSTM,
    tryPutTMVar,
    tryReadTMVar,
    writeTVar,
  )
import Control.Exception
  ( Exception (displayException, toException),
    SomeAsyncException,
    SomeException,
    fromException,
    mask,
    onException,
    throwIO,
    try,
  )
import Control.Monad (void)
import Data.Foldable (traverse_)
import Data.IntSet (IntSet)
import qualified Data.IntSet as IntSet
import Data.List (find, nub)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Data.Type.Equality ((:~:) (Refl))
import System.IO (hPutStrLn, stderr)

-- ---------------------------------------------------------------------------
-- The answering service
-- ---------------------------------------------------------------------------

-- | A stateful answering lane. Reservations are linked in plan order: each
-- node waits for its predecessor's completion cell, while different lanes and
-- worlds with no lane remain concurrent.
newtype TurnLane = TurnLane (TVar (TMVar ()))
  deriving (Eq)

newTurnLaneIO :: IO TurnLane
newTurnLaneIO = do
  completed <- newTMVarIO ()
  TurnLane <$> newTVarIO completed

-- | @Oracle IO@ plus the stateful lane, if any, selected from a question's
-- prompt-independent shape. The answerer can invent an answer but cannot forge
-- an event; the lane lets the interpreter reserve transport order before a
-- prompt's dependencies are ready.
data WorldIO = WorldIO
  { worldAskIO :: forall (c :: Code). SCode c -> Q c -> IO (El c),
    worldTurnLane :: forall (c :: Code). SCode c -> Shape c -> Maybe TurnLane
  }

-- | An answering service whose calls need no ordering beyond data dependencies.
concurrentWorld :: (forall (c :: Code). SCode c -> Q c -> IO (El c)) -> WorldIO
concurrentWorld ask = WorldIO ask (\_ _ -> Nothing)

-- | @pureOracle ω@ (@Exec.lean:618@): the answering service that /is/ the world
-- @ω@, ignoring the history because a world is a function of the question.
--
-- This is the factorization written as a definition. 'runPlanIO' at this
-- 'WorldIO' returns the meaning and the pure transcript:
--
-- > runPlanIO (pureWorldIO w) p  ==  pure (runPlan w p, trace w p)
--
-- which is @Plan.execPure_fst@ (@Exec.lean:747@) and @execM_pure@'s third
-- conclusion (@:646@) at once. The memo table changes nothing here precisely
-- because a 'World' is a function: a repeated question would have got the same
-- answer had it been put again.
pureWorldIO :: World -> WorldIO
pureWorldIO w = concurrentWorld (\c q -> pure (worldAnswer w c q))

-- | Wrap an answering service so that every question it is actually put — and
-- the answer that came back — is announced, one line each.
--
-- __A memo hit announces nothing__, because nothing was asked: what this prints
-- is the sequence of consultations the run paid for, which is 'billMemo' many
-- lines, not 'billFresh' many. A caller that wants every ask /node/ instead
-- should print the 'Trace' 'runPlanIO' returns.
--
-- Reporting only. Removing it changes no answer. Lean once carried the same
-- knob as @Settings.onTurn@ and retired it with the rest of the wire policy
-- (@Exec.lean:878@, \"What used to be here\"); the property it had is the one
-- this has — a reporting hook is visible to no theorem.
announcingWorld :: (Text -> IO ()) -> WorldIO -> WorldIO
announcingWorld out inner =
  WorldIO
    { worldAskIO = \c q -> do
        out $
          codeWord (fromSCode c)
            <> " -> "
            <> addresseeWord (qAddressee q)
            <> ": "
            <> oneLine (qPrompt q)
        a <- worldAskIO inner c q
        out $ "  <- " <> oneLine (sayEl c a)
        pure a,
      worldTurnLane = worldTurnLane inner
    }

-- ---------------------------------------------------------------------------
-- The concurrent memoizing interpreter
-- ---------------------------------------------------------------------------

-- | The shared state of one run. Completed answers, in-flight reservations
-- and spent-model knowledge move in one 'TVar', so every claim observes one
-- atomic snapshot. A prompt already in flight may finish after a model becomes
-- spent; only work that has not started is skipped.
data Memo = Memo
  { memoTable :: !(Map EventKey Event),
    memoPending :: !(Map EventKey (TMVar (Either SomeException Event))),
    memoSpent :: !(Set Text)
  }

-- | One scheduled ask node: its typed answer and the event occupying that node's
-- position in the eventual trace.
data NodeResult (c :: Code) = NodeResult (El c) Event

type NodeCell c = TMVar (Either SomeException (NodeResult c))

-- | An execution environment whose answers may still be in flight.
data Pending (g :: [Code]) where
  PendingNil :: Pending '[]
  PendingCons :: NodeCell c -> Pending g -> Pending (c ': g)

data Ticket where
  Ticket :: NodeCell c -> Ticket

data Scheduler = Scheduler
  { schedulerMemo :: !(TVar Memo),
    schedulerThreads :: !(TVar [ThreadId]),
    schedulerFailed :: !(TMVar SomeException),
    schedulerEffects :: !TurnLane
  }

data Claim
  = ClaimCached Event
  | ClaimWait (TMVar (Either SomeException Event))
  | ClaimOwner (TMVar (Either SomeException Event))

-- | One FIFO link: wait for the predecessor, then publish this node's completion.
data Reservation = Reservation !(TMVar ()) !(TMVar ())

-- | @Plan.execWith o p Env.nil Table.nil@, with independent ask nodes allowed
-- to overlap. Every prompt expression carries the de Bruijn indices it reads;
-- a worker waits in STM for exactly those answer cells, so a shared earlier
-- answer blocks every consumer while sibling prompts that do not read one
-- another start together. Stateful transport lanes and the write-effect lane
-- reserve FIFO links during this traversal, before workers await dependencies;
-- every possible fail-over backend is reserved, so later ready work cannot
-- overtake an earlier blocked node on any lane it may use.
--
-- The observable remains the sequential meaning: the result is evaluated from
-- the same answers, and tickets are collected in plan order rather than worker
-- completion order. A case schedules only the selected arm. A concurrent memo
-- reservation preserves "one question, one answer" when equal questions race.
runPlanIO :: WorldIO -> Plan '[] a -> IO (a, Trace)
runPlanIO = runPlanWith noChains

-- | 'runPlanIO' under a fail-over chain table. The spent-model set is checked
-- atomically before each attempt; it is scheduling knowledge, not a lock, so
-- dependency-independent questions remain concurrent even at one model pin.
runPlanWith :: Chains -> WorldIO -> Plan '[] a -> IO (a, Trace)
runPlanWith ch w p = mask $ \restore -> do
  memo <- newTVarIO (Memo Map.empty Map.empty Set.empty)
  threads <- newTVarIO []
  failed <- newEmptyTMVarIO
  effects <- newTurnLaneIO
  let scheduler = Scheduler memo threads failed effects
      run = do
        (a, tickets) <- execIn scheduler w ch PendingNil p
        trace <- traverse (awaitTicket scheduler) tickets
        pure (a, trace)
  restore run `onException` cancelWorkers scheduler

-- | Schedule the fixed spine immediately. Prompt and branch expressions wait
-- only for the answer cells named by their dependency metadata.
execIn :: Scheduler -> WorldIO -> Chains -> Pending g -> Plan g a -> IO (a, [Ticket])
execIn scheduler w ch y pl = case pl of
  PRet e -> do
    a <- awaitExpr scheduler e y
    pure (a, [])
  PAskC c q k -> do
    cell <- spawn scheduler (reserveQuestion scheduler w ch c (shapeOf q)) $ do
      (a, event) <- askOrMemo scheduler w ch c q
      pure (NodeResult a event)
    (result, tickets) <- execIn scheduler w ch (PendingCons cell y) k
    pure (result, Ticket cell : tickets)
  PAsk c shape prompt k -> do
    cell <- spawn scheduler (reserveQuestion scheduler w ch c shape) $ do
      words' <- awaitExpr scheduler prompt y
      (a, event) <- askOrMemo scheduler w ch c (withPrompt shape words')
      pure (NodeResult a event)
    (result, tickets) <- execIn scheduler w ch (PendingCons cell y) k
    pure (result, Ticket cell : tickets)
  PCase _ e arms -> do
    tag <- awaitExpr scheduler e y
    execIn scheduler w ch y (arms tag)
  PDyn _ e f -> do
    a <- awaitExpr scheduler e y
    execIn scheduler w ch y (f a)

reserveQuestion :: Scheduler -> WorldIO -> Chains -> SCode c -> Shape c -> IO [Reservation]
reserveQuestion scheduler w ch c shape = atomically (traverse reserveLane (nub lanes))
  where
    q = withPrompt shape T.empty
    transportLanes =
      mapMaybe
        (\candidate -> worldTurnLane w c (shapeOf candidate))
        (candidates ch Set.empty q)
    lanes =
      (if writes then [schedulerEffects scheduler] else []) <> transportLanes
    writes = case c of
      SAck -> True
      _ -> case shAddressee shape of
        AddrToolExec {} -> True
        _ -> False

reserveLane :: TurnLane -> STM Reservation
reserveLane (TurnLane tailCell) = do
  previous <- readTVar tailCell
  completed <- newEmptyTMVar
  writeTVar tailCell completed
  pure (Reservation previous completed)

spawn :: Scheduler -> IO [Reservation] -> IO a -> IO (TMVar (Either SomeException a))
spawn scheduler reserve action = mask $ \restore -> do
  reservations <- reserve
  cell <- newEmptyTMVarIO
  tid <-
    forkFinally
      (restore (awaitReservations reservations >> abortIfFailed scheduler >> action))
      (\outcome ->
        atomically $ do
          traverse_ completeReservation reservations
          putTMVar cell outcome
          case outcome of
            Left e -> void (tryPutTMVar (schedulerFailed scheduler) e)
            Right _ -> pure ()
      )
      `onException` releaseReservations reservations
  atomically (modifyTVar' (schedulerThreads scheduler) (tid :))
  pure cell

releaseReservations :: [Reservation] -> IO ()
releaseReservations = atomically . traverse_ completeReservation

abortIfFailed :: Scheduler -> IO ()
abortIfFailed scheduler =
  atomically $ do
    failed <- tryReadTMVar (schedulerFailed scheduler)
    maybe (pure ()) throwSTM failed

awaitReservations :: [Reservation] -> IO ()
awaitReservations = atomically . traverse_ awaitReservation

awaitReservation :: Reservation -> STM ()
awaitReservation (Reservation previous _) = void (readTMVar previous)

completeReservation :: Reservation -> STM ()
completeReservation (Reservation _ completed) = void (tryPutTMVar completed ())

cancelWorkers :: Scheduler -> IO ()
cancelWorkers scheduler =
  atomically (readTVar (schedulerThreads scheduler)) >>= mapM_ killThread

awaitTicket :: Scheduler -> Ticket -> IO Event
awaitTicket scheduler (Ticket cell) = do
  NodeResult _ event <- awaitCell scheduler cell
  pure event

awaitCell :: Scheduler -> TMVar (Either SomeException a) -> IO a
awaitCell scheduler cell =
  atomically $
    (readTMVar cell >>= either throwSTM pure)
      `orElse` (readTMVar (schedulerFailed scheduler) >>= throwSTM)

awaitExpr :: Scheduler -> Expr g a -> Pending g -> IO a
awaitExpr scheduler expr pending = do
  env <-
    atomically $
      pendingEnv (exprUses expr) pending
        `orElse` (readTMVar (schedulerFailed scheduler) >>= throwSTM)
  pure (evalExpr expr env)

pendingEnv :: IntSet -> Pending g -> STM (Env g)
pendingEnv uses PendingNil
  | IntSet.null uses = pure ENil
  | otherwise = throwSTM (userError "expression dependency points outside its context")
pendingEnv uses (PendingCons cell rest) = do
  value <-
    if 0 `IntSet.member` uses
      then do
        NodeResult a _ <- readTMVar cell >>= either throwSTM pure
        pure a
      else pure unavailable
  tailEnv <- pendingEnv (dropHead uses) rest
  pure (ECons value tailEnv)
  where
    unavailable = error "Agentic.Exec: expression dependency metadata omitted a value it read"

dropHead :: IntSet -> IntSet
dropHead = IntSet.mapMonotonic (subtract 1) . IntSet.delete 0

-- | Consult a chain against the concurrent memo. A failed reservation is
-- removed after publishing its exception, preserving the old rule that a later
-- occurrence retries a transient gap; simultaneous occurrences still share the
-- one attempt they raced on.
askOrMemo :: Scheduler -> WorldIO -> Chains -> SCode c -> Q c -> IO (El c, Event)
askOrMemo scheduler w ch c q = go (candidates ch Set.empty q)
  where
    go [] = abandonAllSpent c q (chainOf ch q)
    go (qi : rest) = do
      available <- atomically (candidateAvailable scheduler qi)
      if not available
        then chainLog ch (spentSkip qi) >> go rest
        else do
          outcome <- try (consult scheduler w c qi) :: IO (Either SomeException Event)
          case outcome of
            Left e
              | Just tge <- fromException e,
                tgeGap tge == GapExhausted -> markSpent scheduler qi
            _ -> pure ()
          case outcome of
            Right event -> case eventAnswer c event of
              Just a -> pure (a, event)
              Nothing -> ioError (userError "memoized event has a different answer code from its key")
            Left e
              -- An interrupt is the operator talking, not a gap.
              | Just (_ :: SomeAsyncException) <- fromException e -> throwIO e
              | otherwise -> case fromException e of
                  Nothing -> throwIO e
                  Just tge -> do
                    next <- nextLive scheduler rest
                    case next of
                      Just qi' -> do
                        chainLog ch $
                          fromMaybe (addresseeWord (qAddressee qi)) (modelOf qi)
                            <> ": "
                            <> tgeWhy tge
                            <> "; falling back to "
                            <> fromMaybe "the next candidate" (modelOf qi')
                        go rest
                      Nothing -> throwIO (tgeFinal tge)

    spentSkip qi =
      fromMaybe (addresseeWord (qAddressee qi)) (modelOf qi)
        <> " " <> [wft|reported its allowance spent earlier in this run; not asking it again|]


candidateAvailable :: Scheduler -> Q c -> STM Bool
candidateAvailable scheduler q = do
  spent <- memoSpent <$> readTVar (schedulerMemo scheduler)
  pure (maybe True (`Set.notMember` spent) (modelOf q))

markSpent :: Scheduler -> Q c -> IO ()
markSpent scheduler q = case modelOf q of
  Nothing -> pure ()
  Just model ->
    atomically $
      modifyTVar'
        (schedulerMemo scheduler)
        (\memo -> memo {memoSpent = Set.insert model (memoSpent memo)})

nextLive :: Scheduler -> [Q c] -> IO (Maybe (Q c))
nextLive scheduler qs = atomically $ do
  spent <- memoSpent <$> readTVar (schedulerMemo scheduler)
  pure (find (maybe True (`Set.notMember` spent) . modelOf) qs)

consult :: Scheduler -> WorldIO -> SCode c -> Q c -> IO Event
consult scheduler w c q = mask $ \restore -> do
  let key = questionKey c q
  claim <- atomically (claimQuestion scheduler key)
  case claim of
    ClaimCached event -> pure event
    ClaimWait slot -> atomically (readTMVar slot >>= either throwSTM pure)
    ClaimOwner slot -> do
      outcome <- try (restore (worldAskIO w c q))
      case outcome of
        Right a -> do
          let event = Event c q a
          atomically $ do
            modifyTVar'
              (schedulerMemo scheduler)
              ( \memo ->
                  memo
                    { memoTable = Map.insert key event (memoTable memo),
                      memoPending = Map.delete key (memoPending memo)
                    }
              )
            putTMVar slot (Right event)
          pure event
        Left (e :: SomeException) -> do
          atomically $ do
            modifyTVar'
              (schedulerMemo scheduler)
              (\memo -> memo {memoPending = Map.delete key (memoPending memo)})
            putTMVar slot (Left e)
          throwIO e

claimQuestion :: Scheduler -> EventKey -> STM Claim
claimQuestion scheduler key = do
  memo <- readTVar (schedulerMemo scheduler)
  case Map.lookup key (memoTable memo) of
    Just event -> pure (ClaimCached event)
    Nothing -> case Map.lookup key (memoPending memo) of
      Just slot -> pure (ClaimWait slot)
      Nothing -> do
        slot <- newEmptyTMVar
        writeTVar
          (schedulerMemo scheduler)
          memo {memoPending = Map.insert key slot (memoPending memo)}
        pure (ClaimOwner slot)

-- | The model a question's scope names, if it names one.
modelOf :: Q c -> Maybe Text
modelOf = scopeModelAxis . qScope

-- | The whole chain a question pins, spent members included: the primary and
-- its alternates, or nothing at all when the question is unpinned.
chainOf :: Chains -> Q c -> [Text]
chainOf ch q = case modelOf q of
  Nothing -> []
  Just i -> nub (i : Map.findWithDefault [] i (chainAlternates ch))

-- | The models this question may still be put to, in order, each as the
-- question relabelled to name it — the __mode axis untouched__.
--
-- For an __unpinned__ question this is @[q]@, always: an unpinned question names
-- no model, so the runner cannot say who answered it and has nothing to fall
-- back from. Worth saying out loud, because it is an argument for pinning:
-- __fail-over is a service you get by pinning.__
candidates :: Chains -> Set Text -> Q c -> [Q c]
candidates ch spent q = case modelOf q of
  Nothing -> [q]
  Just i ->
    [ q {qScope = (qScope q) {scopeModelAxis = Just x}}
      | x <- nub (i : Map.findWithDefault [] i (chainAlternates ch)),
        not (x `Set.member` spent)
    ]

-- | Every model this question pins has already reported its allowance spent.
--
-- The run abandons __without touching the wire__, naming the models, because
-- asking a model known to be spent is spending a turn on a guess — which is the
-- one thing an unattended policy must not do.
abandonAllSpent :: SCode c -> Q c -> [Text] -> IO a
abandonAllSpent c q chain =
  ioError . userError . T.unpack $
    "no model is left to answer the "
      <> codeWord (fromSCode c)
      <> " question put to "
      <> addresseeWord (qAddressee q)
      <> ": every model it pins ("
      <> T.intercalate ", " chain
      <> ") reported its allowance spent earlier in this run (prompt: '"
      <> oneLine (qPrompt q)
      <> [wft|'). The run is abandoned rather than asking a model known to be spent, which would be spending a turn on a guess.|]

-- | The chain table a run walks, and where a fail-over narrates itself.
--
-- __The alternates are not in the question.__ Isaac's own sentence is the
-- argument (@Agent\/Op.hs@): a fallback \"is not part of that identity\", and
-- folding it into the identity would key two things off a field neither of them
-- knows about. At these types: 'Agentic.World.EventKey' includes the scope, so
-- a chain in the scope would make @served by "deep"@ and
-- @served by "deep" or "broad"@ — same words, same addressee, same draw — two
-- questions, splitting the memo table and the bills on a field that says
-- nothing about what is being asked. So the alternates are Raw-level program
-- text, and the runner collects them into this table before the run
-- (@Agentic.Chains@).
--
-- The consequence, stated rather than hidden: __the chain is a property of the
-- model, not of the question.__ A program may not say \"deep or broad\" here
-- and \"deep or cheap\" there; that is a runner precondition, and
-- @agentic-run@ refuses to start on an ill-defined table.
data Chains = Chains
  { -- | @primary -> alternates@, fixed for the run
    chainAlternates :: !(Map Text [Text]),
    -- | where a fail-over says what it is about to do. 'stderrLog' by default:
    -- the narration is a warning and not a consultation, which is the same
    -- split 'announcingWorld' and 'stderrLog' already make.
    chainLog :: Text -> IO ()
  }

-- | No alternates anywhere, which is what 'runPlanIO' passes and what makes it
-- the fold it always was.
noChains :: Chains
noChains = Chains Map.empty stderrLog

-- | A chain table with an operator's log.
chainsOf :: (Text -> IO ()) -> Map Text [Text] -> Chains
chainsOf lg t = Chains t lg

-- | The key a question is memoized under: 'eventKey' of the event it will
-- become.
--
-- Going through 'eventKey' rather than rebuilding the record is deliberate —
-- the memo key and the bill key are one key, and a port that wrote them out
-- twice could let them drift. The answer handed over is immaterial because
-- 'EventKey' forgets it (a world is a function, so equal questions have equal
-- answers anyway), and 'defaultEl' is the cheapest immaterial answer there is.
questionKey :: SCode c -> Q c -> EventKey
questionKey c q = eventKey (Event c q (defaultEl c))

-- | Recover the typed answer from the existential event stored at a memo key.
-- The impossible mismatch remains 'Nothing' rather than introducing a partial
-- function into the interpreter.

eventAnswer :: SCode c -> Event -> Maybe (El c)
eventAnswer c (Event c' _ a) = case sameCode c c' of
  Just Refl -> Just a
  Nothing -> Nothing


-- ---------------------------------------------------------------------------
-- The trusted base, at the typed answer
-- ---------------------------------------------------------------------------

-- | @Decode@ (@Exec.lean:265@) — the total function per code taking the bytes
-- an addressee produced to the thing it is thereby taken to have said.
--
-- > Decode .text    s = some s                  -- what was said is what was said
-- > Decode .flag    s = decodeFlag s            -- yes/no/true/false…, or none
-- > Decode .verdict s = some (decodeVerdict s)  -- total: refusal is an answer
-- > Decode .ack     s = some ()                 -- an acknowledgement carries nothing
--
-- Built-in decoding lives in "Agentic.Text"; structured decoding lives in the
-- JSON representation, "Agentic.Schema.Json". Both return the semantic `El`.
-- Flags and schema-indexed answers may be unreadable, so both can re-ask.
decodeEl :: SCode c -> Text -> Maybe (El c)
decodeEl SText s = Just s
decodeEl SVerdict s = Just (decodeVerdict s)
decodeEl SFlag s = decodeFlag s
decodeEl SAck _ = Just ()
decodeEl (SStructured schema) text = decode schema text

-- | @Report.sayAnswer@ — an answer as the one word or line a report prints. The
-- inverse direction of 'decodeEl', and like it, all of the deciding lives in
-- "Agentic.Text" ('sayFlag', 'sayVerdict').
sayEl :: SCode c -> El c -> Text
sayEl SText s = s
sayEl SVerdict v = sayVerdict v
sayEl SFlag b = sayFlag b
sayEl SAck _ = "done"
sayEl (SStructured schema) value =
  fromMaybe "<not representable as finite JSON>" (render schema value)

-- ---------------------------------------------------------------------------
-- What a question says about itself on the wire
-- ---------------------------------------------------------------------------

-- | @Exec.Code.name@ (@Exec.lean:777@) — how a code names itself in a prompt
-- header, a warning and an abandonment message.
--
-- __This is not @Agentic.Raw.codeName@.__ That one spells @CodeAck@ as
-- @receipt@, because that is the keyword the surface language and the oracle's
-- wire use. Lean's @IO@ layer spells it @ack@, in the prompt header, in the
-- re-ask nudge and in both error messages, so this port does too; a run's
-- diagnostics are compared against Lean's by eye and by test, and \"receipt\"
-- here would be a silent divergence in the one text a stuck operator reads.
codeWord :: SomeCode -> Text
codeWord (SomeCode code) = case code of
  SText -> "text"
  SVerdict -> "verdict"
  SFlag -> "flag"
  SAck -> "ack"
  SStructured _ -> "structured"

-- | @Addressee.render@ (@Exec.lean:784@) — how an addressee names itself in a
-- prompt header and in an error.
addresseeWord :: Addressee -> Text
addresseeWord = \case
  AddrModel i -> "model " <> i
  AddrTool i -> "tool " <> i
  AddrPerson i -> "person " <> i
  -- The command and not its arguments: an operator reading a progress line
  -- wants to know which gate ran, and the argv is in the printed program.
  AddrToolExec i cmd _ -> "tool " <> i <> " (" <> cmd <> ")"

-- | @Exec.answerSpec@ (@Exec.lean:807@) — what the addressee must say for
-- 'decodeEl' to read it, sent with every question because the trusted base is
-- narrow on purpose and an addressee cannot be expected to guess it.
--
-- These sentences are the exact bytes Lean sends. A structured code includes its
-- standard JSON Schema, so the addressee receives the same validator the decoder
-- uses.
answerSpec :: SCode c -> Text
answerSpec = \case
  SText -> "Reply with the text itself and nothing else."
  SVerdict -> "Reply with exactly APPROVE if acceptable, or OBJECTION: <one line> if not."
  SFlag -> "Reply with exactly yes or no."
  SAck -> "Do what was asked, then reply with exactly DONE."
  SStructured schema ->
    "Reply with exactly one JSON value matching this schema and nothing else: "
      <> renderSchema schema

-- | @Exec.nudge@ (@Exec.lean:866@) — what to append when a reply could not be
-- read, so the second attempt is not a verbatim repeat of the first.
--
-- > "\n\n[Your previous reply could not be read as a {code}: {reply}\n{answerSpec}]"
--
-- The reply is quoted back trimmed and otherwise untouched, because what was
-- said is the only evidence there is of why it could not be read.
nudge :: SCode c -> Text -> Text
nudge c reply =
  "\n\n[Your previous reply could not be read as a "
    <> codeWord (fromSCode c)
    <> ": "
    <> trimAscii reply
    <> "\n"
    <> answerSpec c
    <> "]"

-- | May an answer to this question be recorded from a turn the agent did
-- __not__ finish?
--
-- __This rule is stated here and nowhere else.__ Lean carried a
-- @Exec.requiresCompletedTurn@ beside its own ACP transport; that transport and
-- everything that was a policy about a wire are retired (@Exec.lean:62@,
-- @:878@), so the rule below is not a port of a surviving definition — it is
-- the definition, and a transport that changes it changes the meaning of a
-- receipt.
--
-- 'False' is /refusal is an answer/ (§3 q8): a @text@, @verdict@ or @flag@ from
-- a model or a tool is read as given even if the turn was cut short, because a
-- review that stopped mid-sentence is still a review with objections in it.
--
-- 'True' is the case that argument does not cover, and there are two:
--
-- * @ack@ — an act. The question does not ask what somebody thinks, it asks
--   them to do something and say when it is done, and @Decode .ack@ is total,
--   so a receipt from an interrupted turn is /the same term/ in the table as
--   one from a completed act. Recording it would be recording an act nobody
--   performed.
-- * a person. A person-addressed question whose turn was cancelled was not
--   answered by that person; the stand-in stopped, and nobody answered.
--
-- Exported because it is a decision about what bytes may mean, and so belongs
-- beside 'decodeEl' rather than inside whichever transport can observe a stop
-- reason. A transport that /cannot/ observe one — the agent-deck CLI does not
-- report why a turn ended — cannot apply this rule and owes its reader that
-- fact in as many words.
requiresCompletedTurn :: SomeCode -> Addressee -> Bool
requiresCompletedTurn (SomeCode SAck) _ = True
requiresCompletedTurn _ (AddrPerson _) = True
requiresCompletedTurn _ _ = False

-- ---------------------------------------------------------------------------
-- Whose words a reply is
-- ---------------------------------------------------------------------------

-- | The markers a __transport banner__ begins with: a line a transport writes
-- about /itself/ into the answer stream, in the addressee's voice, because the
-- wire it owns gave it no other channel to say it on.
--
-- One entry, and it is the one that was measured. @claude-agent-acp@ 0.64.0 put
--
-- > **Model fallback:** claude-fable-5 declined this request (cyber); retried
-- > with claude-opus-4-8. The session will continue on claude-opus-4-8.
--
-- at the head of a turn as an ordinary @agent_message_chunk@ — a sentence about
-- the transport's own routing, arriving on the wire as if the model had said
-- it. "Agentic.Acp" is where that costs something and where the ruling about it
-- is written down; this is the pattern the ruling is anchored on.
--
-- __0.64.0 is the version it was seen on.__ If a successor re-words the banner,
-- this marker stops matching and the failure is /under/-separation: the banner
-- travels again, visibly, in the transcript and in the prompts, exactly as it
-- did before this function existed. It cannot become over-separation, because
-- the only thing an unmatched pattern can do is nothing. That asymmetry is why
-- the list holds a literal rather than a shape, and it is what makes adding a
-- marker later a safe change and guessing one now an unsafe one.
--
-- __0.70.0: not reproduced, and the pattern is retained for the transcripts that
-- carry it.__ One live run on that version —
-- @agentic-run run harden --engine acp --adapter claude --timeout 180000@, the
-- fixture whose @cyber@-flagged content drew the fallback on 0.64.0 — put all six
-- questions, ended every turn @end_turn@, and produced no banner: no
-- @**Model fallback:**@ and no @declined@ anywhere in the trace or on stderr, on
-- an adapter that opened a fresh session per question. That is evidence about
-- one run's routing and not about the wording, since a fallback that does not
-- happen says nothing about how it would be announced — so the marker is
-- unchanged. A recorded transcript from 0.64.0 still separates correctly, which
-- is what the pattern is for and why deleting it on this evidence would be
-- trading a known-good separation for an unmeasured guess.
--
-- __Why one literal and not a shape.__ The list is matched as an exact
-- case-sensitive prefix of a trimmed line, and it holds a marker that has been
-- seen on a wire rather than a family that might exist. A rule like \"any
-- leading @**Label:**@\" or \"any leading paragraph in bold\" would separate a
-- model's own emphasis from its own answer the first time a reviewer opened
-- with @**Objection:**@ — and an answer edited by a pattern nobody measured is
-- exactly the failure this function exists to prevent, with the blame moved.
-- Adding a marker here is cheap; a marker that is wrong is not.
--
-- Codex's measured @Model metadata … not found@ prefix (see
-- 'Agentic.Acp.chunkText') is deliberately __absent__: no record in this
-- repository holds its exact wording, so any pattern for it would be a guess
-- about bytes, and under-separating a text answer costs prose in a prompt where
-- over-separating costs the answer itself.
transportBanners :: [Text]
transportBanners = ["**Model fallback:**"]

-- | Separate a reply's leading transport banners from the answer underneath:
-- @(narration, answer)@.
--
-- Leading lines whose trimmed form begins with one of 'transportBanners' are
-- the narration; a blank line between a banner and an answer is the banner's
-- paragraph break and is consumed — it lands in neither half, which is the
-- one whitespace the round trip below excuses. Everything from the first
-- line that is neither is the
-- answer, __byte for byte as it arrived__: nothing inside it is rewritten, and
-- the concatenation of the two halves is the reply again but for that
-- whitespace.
--
-- Three properties, and they are the whole contract:
--
-- 1. __No banner, nothing moves.__ @splitTransportNarration r == (\"\", r)@
--    whenever @r@\'s first line is not a banner — including when a banner
--    appears further down, which is left alone on purpose: a banner in the
--    middle of a turn cannot be told from a model quoting one, and the measured
--    defect is at the head.
-- 2. __Nothing is discarded.__ The narration is returned, not dropped, so a
--    caller can record it; a caller that drops it is answerable for that, and
--    'Agentic.Acp.sayAcp' does not.
-- 3. __A reply that was only narration answers nothing.__ The answer is then
--    empty, which is the truth — the addressee said nothing — and the trusted
--    base reads it as it reads any empty turn: @declined@ for a verdict,
--    unreadable for a flag, empty for a text.
--
-- Here rather than in "Agentic.Text" because this is not a decision about what
-- an addressee's bytes /mean/ — that decision exists once, in the byte-faithful
-- port, and this module may not grow a second copy of it. It is the question
-- underneath: __whose bytes they are__. The trusted base is handed the
-- addressee's, which is the same base and the same reading it always had.
--
-- Exported for the same reason 'requiresCompletedTurn' is: a transport whose
-- adapter narrates itself owes its reader this separation, and there is more
-- than one transport. "Agentic.Acp" applies it; "Agentic.AgentDeck" has not been
-- measured emitting a banner, and adopting it there is this one call when it is.
splitTransportNarration :: Text -> (Text, Text)
splitTransportNarration reply = peel [] (T.splitOn "\n" reply)
  where
    peel :: [Text] -> [Text] -> (Text, Text)
    peel seen ls = case ls of
      (l : rest)
        | isBanner l -> peel (l : seen) rest
        -- Only *after* a banner, which is what makes property (1) hold: with
        -- nothing seen yet a blank first line is part of the answer.
        | not (null seen) && T.null (trimAscii l) -> peel seen rest
      _ -> (T.intercalate "\n" (reverse seen), T.intercalate "\n" ls)

    isBanner :: Text -> Bool
    isBanner l = any (`T.isPrefixOf` trimAscii l) transportBanners

-- ---------------------------------------------------------------------------
-- The decode loop
-- ---------------------------------------------------------------------------

-- | @Settings.retries@'s default (@Exec.lean:890@): re-ask once, so a question
-- is put at most twice.
--
-- Only a @flag@ can trigger a re-ask at all (@Decode_eq_none@), so this is not
-- a general error-handling budget; it is the width of the one code whose answer
-- set is narrower than what an addressee can say.
defaultRetries :: Int
defaultRetries = 1

-- | @Settings.log@'s default (@Exec.lean:895@): a warning goes to stderr,
-- prefixed @agentic:@.
--
-- Warnings report what the run is /about/ to do about something it noticed;
-- they are never a substitute for doing it, which is why an answer that could
-- not be read at all is an error and not a log line.
stderrLog :: Text -> IO ()
stderrLog msg = hPutStrLn stderr ("agentic: " <> T.unpack msg)

-- ---------------------------------------------------------------------------
-- The failure vocabulary
-- ---------------------------------------------------------------------------

-- | __Why__ a question produced no answer — named by what came back, never by
-- what the runner will do about it.
--
-- @agent-functor@ bought this taxonomy with two dead @ship-feature@ runs and a
-- twenty-leaf fan-out (@isaac-workflows@ §G10, D6), and it transfers as
-- vocabulary before it transfers as code: the three constructors are declared
-- and priced here in this wave, and only the first is /raised/ here, because
-- only the first is something this module can observe.
--
-- The mapping to @~\/src\/agent-functor@'s @Agent.Run.TurnGap@, which is three
-- constructors over a leaf whose artefact is untyped @Text@:
--
-- * 'GapUndecodable' — no counterpart there;
-- * 'GapTransportRefusal' — its @TurnFailed@;
-- * 'GapEmptyOrProtocol' — its @TurnEmpty@;
-- * 'GapExhausted' — its @TurnExhausted@.
--
-- One of those four lines is not one-to-one, and the reason is the design:
--
-- * __'GapUndecodable' has no counterpart there and is the only one raised
--   here.__ A leaf in @agent-functor@ returns @Text@ and there is nothing to
--   decode; here the trusted base is narrow on purpose ('decodeEl'), so bytes
--   can arrive, be a perfectly good turn, and still not be an answer. That is
--   this language's own gap, and it is the one the decode loop is /about/.
--
-- * __@TurnFailed@ and @TurnExhausted@ used to arrive as one gap__, because
--   what makes them worth telling apart is that the same question put to a
--   /different/ model is expected to succeed — which is fail-over, and
--   splitting the gap before that mechanism existed would have been inventing a
--   distinction with nothing on the other side of it. D6 put something there,
--   so 'GapExhausted' is now its own constructor: it is the one gap that marks
--   its model spent for the rest of the run.
--
-- The last three are the /transport's/ to raise and not the decode loop's,
-- which is why nothing in this module constructs them: \"the adapter refused\"
-- and \"the turn ended with nothing\" are observations about a turn, and by the
-- time bytes reach 'decodeEl' there is no turn left to observe.
--
-- __The transports are wired to these budgets__ (D6), through
-- 'withTransportGaps': an adapter classifies its own named failures, and the
-- gap is then priced by 'gapBudget', answered by 'esRecover', re-asked there
-- while that answer is 'RetryHere', and otherwise handed to the fail-over walk.
-- Which failure is which gap is the transport's to say, and the asymmetry
-- between the two is real rather than a defect: "Agentic.Acp" can see a stop
-- reason and so can raise 'GapEmptyOrProtocol'; "Agentic.AgentDeck" cannot, and
-- names every one of its failures 'GapTransportRefusal'.
data TurnGap
  = -- | Bytes arrived and 'decodeEl' could not read them at the question's
    -- code. Flags and schema-indexed answers can produce it.
    GapUndecodable
  | -- | The transport named a failure — the adapter died mid-turn, the pipe
    -- closed, the provider answered 5xx, the model's allowance is spent.
    GapTransportRefusal
  | -- | The turn ended cleanly and produced nothing usable, or ended in a way
    -- the protocol says is not an answer ('requiresCompletedTurn').
    GapEmptyOrProtocol
  | -- | __This model has nothing left to spend.__ Split out of
    -- 'GapTransportRefusal' by D6, which is when the distinction acquired
    -- something on the other side of it: it is the one gap that says something
    -- about the /model/ rather than about the turn, so it is the one that marks
    -- the model spent for the rest of the run and is never re-asked here.
    --
    -- __Nothing raises it today__, and that is the same honesty
    -- 'RetryHere' ships with: neither transport can see a wire-level rate-limit
    -- tag (agent-deck reports no stop reason at all, and this client's ACP
    -- errors carry no @errorKind@), so the constructor is declared, priced at
    -- zero re-asks and consumed by the fail-over walk, waiting for the
    -- transport that can tell.
    GapExhausted
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | How a gap names itself in a warning and in a refusal.
gapWord :: TurnGap -> Text
gapWord = \case
  GapUndecodable -> "undecodable"
  GapTransportRefusal -> "transport-refusal"
  GapEmptyOrProtocol -> "empty-or-protocol"
  GapExhausted -> "exhausted"

-- | What to do about a gap: @agent-functor@'s @Recovery@, at the same three
-- constructors and for the same reason — there are exactly three things an
-- operator knows that the runner does not.
--
-- 'FailOver' is __implemented__ (D6): it hands the gap to 'askOrMemo', which is
-- the only layer that knows whether the chain has somewhere to go — exactly
-- @Agent.Run.overChain@'s reading that it \"is the only layer that can answer
-- it\". With somewhere to go it puts the same question to the next model; with
-- nowhere to go it raises 'tgeFinal', which is what the run would have raised
-- with no chain declared. So a policy that answers 'FailOver' at a question
-- with no spare abandons in exactly the words it always did.
data Recovery
  = -- | Put the same question again, to the same addressee.
    RetryHere
  | -- | Put it to the next model in the question's chain, if it has one, and
    -- otherwise stop exactly as 'Abandon' would.
    FailOver
  | -- | Stop. The run has no answer and will not invent one.
    Abandon
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | What a recovery policy is told about the gap it must answer for:
-- @agent-functor@'s @RecoverAsk@, less the fields only a fallback chain has
-- (its @raNext@ is the next model's label, and there is no chain to name).
--
-- Pure and 'Eq', so a policy is a total function testable without a transport,
-- which is the whole reason the fork is data rather than a branch in the loop.
data GapAsk = GapAsk
  { -- | Which gap.
    gaGap :: !TurnGap,
    -- | Re-asks already spent on __this question__, zero at the first gap.
    gaSpent :: !Int,
    -- | This gap's budget, as 'gapBudget' read it out of the settings.
    gaBudget :: !Int,
    -- | The evidence: the last unreadable reply, or the transport's words.
    gaWhy :: !Text
  }
  deriving (Eq, Show)

-- | How a gap is answered. @agent-functor@'s @Recover@ is
-- @RecoverAsk -> IO Recovery@ because its live path opens a modal and asks the
-- operator; this one is pure, because the only answers this wave can give are
-- read out of settings the operator wrote before the run started. An
-- interactive one would fit here by being an @IO@ of this.
type Recover = GapAsk -> Recovery

-- | The default policy, and the one that reproduces this module's behaviour
-- from before the fork existed: re-ask while the gap's budget holds, then hand
-- the gap on.
--
-- __'FailOver' and not 'Abandon' when the budget is spent__, since D6, and it
-- is not a change of behaviour: the layer that knows whether there is anywhere
-- to go is 'askOrMemo', and it degrades a fail-over with nowhere to go to
-- exactly the abandonment this module has always ended on. That is
-- @unattendedRecovery@'s own shape — \"fail over if the flow declared somewhere
-- to fail over to, else halt\" — with the \"else halt\" moved to the one place
-- that can decide it. An operator who wants a spare /not/ to be tried writes
-- @const Abandon@.
budgetedRecovery :: Recover
budgetedRecovery ga
  | gaSpent ga < gaBudget ga = RetryHere
  | otherwise = FailOver

-- ---------------------------------------------------------------------------
-- A gap, as an exception the fail-over walk can read
-- ---------------------------------------------------------------------------

-- | A gap on its way past 'askOrMemo', carrying __what to raise if there is
-- nowhere to go__.
--
-- 'WorldIO' stays exactly as it is — @forall c. SCode c -> Q c -> IO (El c)@ —
-- because widening it to let the answerer report /which/ model answered would
-- hand the answerer the power to forge the trace, which is strictly worse than
-- the forgery the type was designed to prevent. So a gap travels the one way a
-- value of that type can carry a failure: as an exception. The candidate
-- sequence stays a pure function of the question and the chain table, computed
-- by this module, so the world can only answer or fail; it can never name who
-- it was.
--
-- 'tgeFinal' is the whole of the \"exhaustion never escapes\" property: it is
-- the exception the run would have raised with no chain declared, kept verbatim
-- and re-raised unchanged when the chain is out of models. __With no alternates
-- declared anywhere, every diagnostic in this package is byte-identical to the
-- one before fail-over existed.__
data TurnGapError = TurnGapError
  { -- | which gap
    tgeGap :: !TurnGap,
    -- | the evidence, for the fail-over warning
    tgeWhy :: !Text,
    -- | what to raise when no candidate remains
    tgeFinal :: !SomeException
  }

-- | The wrapper is transparent: what a reader sees is the failure itself, so a
-- 'TurnGapError' that somehow escapes uncaught reads exactly as the error it
-- carries.
instance Show TurnGapError where
  show = show . tgeFinal

instance Exception TurnGapError where
  displayException = displayException . tgeFinal

-- | Raise a gap: the failure this question produced, and what to raise for it
-- when the chain has nowhere left to go.
raiseGap :: TurnGap -> Text -> IOError -> IO a
raiseGap g why final = throwIO (TurnGapError g why (toException final))

-- | Put a question through a transport under the run policy: a transport-level
-- failure becomes a gap, is priced by 'gapBudget', answered by 'esRecover', and
-- re-asked __here__ while that answer is 'RetryHere' — then handed to the
-- fail-over walk, which either moves to the next model or raises what the
-- transport itself threw.
--
-- This is the wiring the failure vocabulary was declared for and did not have:
-- before it, an adapter that could see a stop reason abandoned where the
-- failure was raised and the budgets in 'ExecSettings' described only the
-- decode loop. A transport passes its own classifier, because only it knows
-- which of its named failures is which gap — @agent-deck@ reports no stop
-- reason, so it can name none of them 'GapEmptyOrProtocol', and that asymmetry
-- is the difference between the two engines rather than a defect of this
-- function.
--
-- An exception the classifier does not claim is __rethrown untouched__: a
-- failure that is not a gap is not the recovery fork's to answer, and a runner
-- that swallowed it would re-run broken work on a second, pricier model and
-- bill twice for hiding the defect.
withTransportGaps ::
  forall c a.
  ExecSettings ->
  -- | which gap this transport's failure is, and the evidence; 'Nothing' for a
  -- failure that is not a gap at all
  (SomeException -> Maybe (TurnGap, Text)) ->
  SCode c ->
  Q c ->
  IO a ->
  IO a
withTransportGaps st classify c q act0 = go 0
  where
    go :: Int -> IO a
    go spent =
      try act0 >>= \case
        Right a -> pure a
        Left (e :: SomeException)
          | Just (_ :: SomeAsyncException) <- fromException e -> throwIO e
          | Just tge <- fromException e -> throwIO (tge :: TurnGapError)
          | otherwise -> case classify e of
              Nothing -> throwIO e
              Just (g, why) ->
                let ga = GapAsk g spent (gapBudget st g) why
                 in case esRecover st ga of
                      RetryHere -> do
                        esLog st $
                          gapWord g
                            <> " gap at "
                            <> addresseeWord (qAddressee q)
                            <> " for a "
                            <> codeWord (fromSCode c)
                            <> " ("
                            <> trimAscii why
                            <> "); asking again"
                        go (spent + 1)
                      Abandon -> throwIO e
                      FailOver -> throwIO (TurnGapError g why e)

-- ---------------------------------------------------------------------------
-- The run policy
-- ---------------------------------------------------------------------------

-- | @Exec.Settings@ (@Exec.lean:887@)'s two fields, plus the run policy this
-- port owes an operator.
--
-- Neither 'Eq' nor 'Show': two of its fields are functions, exactly as Lean's
-- @log@ is. The parts that /are/ decidable — the budgets, and what a policy
-- answers — are pure functions over 'TurnGap' and 'GapAsk' and are testable on
-- their own ('gapBudget', 'budgetedRecovery').
data ExecSettings = ExecSettings
  { -- | @Settings.log@. Default 'stderrLog'.
    esLog :: Text -> IO (),
    -- | @Settings.retries@: re-asks after the first attempt at a reply the
    -- trusted base could not read. __Default 1__, which is 'defaultRetries'.
    esRetryUndecodable :: !Int,
    -- | Re-asks after a transport refusal. __Default 0__ — today a transport
    -- failure abandons where it is raised, and this field records that as a
    -- number rather than as a fact about the code.
    esRetryTransportRefusal :: !Int,
    -- | Re-asks after a turn that ended with nothing usable. __Default 0__, for
    -- the same reason. (@agent-functor@ runs 2 \/ 1 \/ 0 across its own three;
    -- adopting its numbers would change what a run costs, so the numbers are
    -- the operator's and only the vocabulary is ours.)
    esRetryEmptyOrProtocol :: !Int,
    -- | How a gap is answered once it is raised. Default 'budgetedRecovery'.
    esRecover :: Recover,
    -- | D7's cheap half: the arm an unreadable @flag@ takes once its re-asks
    -- are spent, instead of abandoning the run. __Default 'Nothing'__, which is
    -- to abandon.
    --
    -- The arm is the operator's standing answer to \"what does an addressee who
    -- will not say yes or no mean\". The honest choice is the __loud__ arm —
    -- the branch that does the visible thing, so an unreadable flag cannot
    -- quietly skip work — but NOTHING HERE CHECKS THAT: the field is a bare
    -- answer, the language cannot see which branch of a given @if@ does the
    -- visible work, and an operator who configures the quiet arm gets exactly
    -- the quiet skip the loud choice exists to prevent. That safety is the
    -- operator's, and the log line says so each time the arm is taken —
    -- the one place an answer in the memo table came from the settings and
    -- not from the addressee.
    esLoudArm :: !(Maybe Bool),
    -- | The standing answer a __person__ question takes in an unattended run:
    -- the bytes an operator wrote before the run started, instead of a
    -- transport blocking on a person who is not there. __Default 'Nothing'__,
    -- which is to ask.
    --
    -- Bytes and not an answer: they go through 'decodeEl' like anything else,
    -- so an unreadable standing answer exhausts its budget and abandons rather
    -- than becoming a value nobody said. It is announced through 'esLog' every
    -- time it is taken.
    --
    -- This is @agent-functor@'s @unattendedRecovery@ discipline at the one
    -- place we have for it: \"honouring it here is reading an instruction, not
    -- guessing\". A run with no standing answer and nobody watching still waits
    -- on the transport, which is the right outcome for a program that asked a
    -- person a question in a room with no person in it.
    esStandingAnswer :: !(Maybe Text)
  }

-- | Every field at the value that makes the settings-taking entry points
-- behave exactly as the ones that predate them.
defaultExecSettings :: ExecSettings
defaultExecSettings =
  ExecSettings
    { esLog = stderrLog,
      esRetryUndecodable = defaultRetries,
      esRetryTransportRefusal = 0,
      esRetryEmptyOrProtocol = 0,
      esRecover = budgetedRecovery,
      esLoudArm = Nothing,
      esStandingAnswer = Nothing
    }

-- | This gap's re-ask budget, never negative — the one place the three fields
-- are read, so a caller cannot pick the wrong one for a gap.
gapBudget :: ExecSettings -> TurnGap -> Int
gapBudget st = \case
  GapUndecodable -> max 0 (esRetryUndecodable st)
  GapTransportRefusal -> max 0 (esRetryTransportRefusal st)
  GapEmptyOrProtocol -> max 0 (esRetryEmptyOrProtocol st)
  -- Not a settings field, and deliberately: re-asking a model that has said it
  -- has nothing left to spend cannot help, so the budget is zero by
  -- construction rather than by an operator's choice. What /can/ help is a
  -- different model, which is the fail-over walk.
  GapExhausted -> 0

-- | @Exec.attemptWith@ (@Exec.lean:913@): ask, decode, and on a failure to decode
-- ask again — @n + 1@ attempts in all, the second and later ones carrying the
-- 'nudge' that quotes back what could not be read.
--
-- @Right a@ is the answer the trusted base read. @Left reply@ is the __last
-- unreadable reply, verbatim__: it is returned rather than discarded because it
-- is the only evidence the caller has of what was actually said, and the
-- caller's job is to report it, never to replace it with an answer of its own.
--
-- The callback is Lean's @say@ with the question already closed over: it is
-- given the @extra@ to append to whatever it renders, and returns the bytes
-- that came back. A caller that ignores the @extra@ (a scripted world does)
-- will simply be handed the same unreadable reply again and exhaust the budget,
-- which is the honest behaviour for an addressee that repeats itself.
--
-- Written in terms of 'attemptRecovering' at 'defaultExecSettings', so this
-- function and 'askDecodingWith' cannot hold two opinions about when a question
-- is put again. At that policy the only answer that ever ends the loop is
-- 'Abandon', so the @Left@ here is what it always was.
attemptDecoding ::
  forall (c :: Code).
  -- | @Settings.log@
  (Text -> IO ()) ->
  -- | @Settings.retries@: this many re-asks after the first attempt
  Int ->
  SCode c ->
  -- | @say extra@
  (Text -> IO Text) ->
  IO (Either Text (El c))
attemptDecoding lg retries c say =
  attemptRecovering settings c say >>= \case
    Right a -> pure (Right a)
    Left (ga, _) -> pure (Left (gaWhy ga))
  where
    settings =
      defaultExecSettings {esLog = lg, esRetryUndecodable = retries}

-- | The decode loop proper, over 'ExecSettings': ask, decode, and on a failure
-- to decode consult 'esRecover' — re-asking with the 'nudge' while it answers
-- 'RetryHere', and handing back the unanswered 'GapAsk' with whatever it
-- answered instead.
--
-- Not exported. It settles /whether/ to ask again and never /what to do
-- instead/, because the two callers report a spent question differently and
-- only one of them ('askDecodingWith') has the question in hand to report it
-- with.
attemptRecovering ::
  forall (c :: Code).
  ExecSettings ->
  SCode c ->
  (Text -> IO Text) ->
  IO (Either (GapAsk, Recovery) (El c))
attemptRecovering st c say = go 0 T.empty
  where
    budget = gapBudget st GapUndecodable

    go :: Int -> Text -> IO (Either (GapAsk, Recovery) (El c))
    go spent extra = do
      reply <- say extra
      case decodeEl c reply of
        Just a -> pure (Right a)
        Nothing ->
          let ga = GapAsk GapUndecodable spent budget reply
           in case esRecover st ga of
                RetryHere -> do
                  esLog st $
                    "could not read a "
                      <> codeWord (fromSCode c)
                      <> " from '"
                      <> trimAscii reply
                      <> "'; re-asking"
                  go (spent + 1) (nudge c reply)
                answer -> pure (Left (ga, answer))

-- | @Exec.askDecoding@ (@Exec.lean:968@): 'attemptDecoding', and — if
-- every attempt was unreadable — __abandon the run__ with an 'ioError' quoting
-- the words that could not be read.
--
-- __Why exhaustion is an error and not a default__ (@Exec.lean:933@). Every
-- @El c@ is inhabited, so @pure (defaultEl c)@ typechecks here and would be
-- wrong. A memo entry carries a code, a question and an answer and /nothing
-- else/, so a defaulted cell is definitionally identical to one an addressee
-- gave: the transcript would print @-> no@ for a person who never said no, the
-- bills would charge for it, and no check further down could recover the
-- difference, because the information needed to make that check is destroyed at
-- the moment of the insert. So the invented answer is never made: the run
-- either has an answer somebody gave, or it has no run.
--
-- The cost is honest and worth naming — an abandoned run loses the table it had
-- built. A caller who wants the partial transcript catches the error at a
-- boundary of its choosing; this function does not choose one for it.
askDecoding ::
  forall (c :: Code).
  -- | @Settings.log@
  (Text -> IO ()) ->
  -- | @Settings.retries@
  Int ->
  SCode c ->
  Q c ->
  -- | @say extra@
  (Text -> IO Text) ->
  IO (El c)
askDecoding lg retries c =
  askDecodingWith defaultExecSettings {esLog = lg, esRetryUndecodable = retries} c

-- | 'askDecoding' over 'ExecSettings', and the entry point every policy field
-- is read at.
--
-- Three things happen here that 'askDecoding' at 'defaultExecSettings' does
-- not see, because all three are off by default:
--
-- 1. __The standing unattended answer.__ If 'esStandingAnswer' is set and the
--    addressee is a person, the transport is not consulted at all: the
--    operator's bytes are announced through 'esLog' and then decoded like any
--    other reply. A run with nobody watching takes the instruction its operator
--    wrote instead of blocking on a person who is not there.
--
-- 2. __The recovery fork.__ 'esRecover' decides each gap. 'RetryHere' re-asks
--    inside the loop; 'Abandon' falls through to (3); 'FailOver' also falls
--    through to (3), and then raises the abandonment as a 'TurnGapError' so
--    that 'askOrMemo' may put the same question to the next model in its chain
--    — with nowhere to go it raises the very same 'ioError', which is what
--    keeps this path byte-identical to the one before fail-over existed.
--
-- 3. __The loud arm.__ If 'esLoudArm' is set and the code is @flag@, a spent
--    question takes the configured arm with a warning instead of abandoning.
--    Structured questions can also be undecodable, but have no operator-supplied
--    Boolean arm; they and every other code abandon exactly as before.
--
-- __Why the loud arm is not the defaulting this module refuses.__ The
-- abandonment message spends a paragraph on why @pure (defaultEl c)@ is wrong,
-- and it still is: an invented answer is indistinguishable in the table from
-- one an addressee gave. What is different here is who invented it. A defaulted
-- cell is the /runner/ answering for the addressee, silently and always; the
-- loud arm is the /operator/ answering, once, in writing, before the run
-- started, having been told which arm is which — and it is announced every time
-- it is taken. That is the same distinction @agent-functor@ draws between
-- guessing and reading an instruction, and it is why the field is 'Maybe' and
-- empty by default rather than a 'Bool' with a sensible value.
askDecodingWith ::
  forall (c :: Code).
  ExecSettings ->
  SCode c ->
  Q c ->
  -- | @say extra@
  (Text -> IO Text) ->
  IO (El c)
askDecodingWith st c q say0 = do
  say <- standingSay
  attemptRecovering st c say >>= \case
    Right a -> pure a
    -- 'RetryHere' cannot arrive: 'attemptRecovering' consumes it and asks
    -- again, so the only answers that leave the loop are the two that end the
    -- question here. 'FailOver' and 'Abandon' differ only in whether the
    -- fail-over walk is allowed to try another model, and the loud arm — which
    -- is an answer, not a gap — is reached before either.
    Left (ga, answer) -> spent ga answer
  where
    -- The operator's standing answer, in place of the transport, for a person
    -- nobody is standing next to.
    standingSay :: IO (Text -> IO Text)
    standingSay = case (esStandingAnswer st, qAddressee q) of
      (Just canned, AddrPerson i) -> do
        esLog st $
          "unattended: person "
            <> i
            <> " is not being asked; the standing answer '"
            <> trimAscii canned
            <> "' is taken instead (prompt: '"
            <> oneLine (qPrompt q)
            <> "')"
        pure (\_extra -> pure canned)
      _ -> pure say0

    -- A question whose re-asks are spent: the loud arm if the operator named
    -- one and the code can take it, else the abandonment this module has always
    -- ended on — raised as a __gap__ when the policy said 'FailOver', so that
    -- 'askOrMemo' may put the same question to the next model in its chain.
    -- Decode exhaustion is exactly \"this addressee produced nothing usable and
    -- asking again did not help\", which is a gap and not a fact about the
    -- question; its message survives verbatim as 'tgeFinal', so a question with
    -- no spare abandons in the very words it always did.
    spent :: GapAsk -> Recovery -> IO (El c)
    spent ga answer = case (esLoudArm st, c) of
      (Just arm, SFlag) -> do
        esLog st $
          "no readable flag from "
            <> addresseeWord (qAddressee q)
            <> " after "
            <> T.pack (show (gaSpent ga + 1))
            <> " attempts; taking the operator-configured arm ("
            <> sayFlag arm
            <> [wft|) rather than abandoning the run — nothing checks that this arm is the loud one; that safety is the operator's. This answer is not |]
            <> addresseeWord (qAddressee q)
            <> "'s (last reply: '"
            <> trimAscii (gaWhy ga)
            <> "', prompt: '"
            <> oneLine (qPrompt q)
            <> "')."
        pure arm
      _ ->
        let final =
              userError . T.unpack $
                "no readable "
                  <> codeWord (fromSCode c)
                  <> " from "
                  <> addresseeWord (qAddressee q)
                  <> " after "
                  <> T.pack (show (gaSpent ga + 1))
                  <> " attempts; last reply: '"
                  <> trimAscii (gaWhy ga)
                  <> "' (prompt: '"
                  <> qPrompt q
                  <> [wft|'). The run is abandoned: recording an answer nobody gave would be indistinguishable, in the table, from one they did.|]
            why =
              "no readable "
                <> codeWord (fromSCode c)
                <> " after "
                <> T.pack (show (gaSpent ga + 1))
                <> " attempts"
         in case answer of
              FailOver -> raiseGap (gaGap ga) why final
              _ -> ioError final

-- ---------------------------------------------------------------------------
-- The scripted world
-- ---------------------------------------------------------------------------

-- | The answering service of @test\/stub_adapter.py@: canned replies keyed on
-- the prompt, decoded per code by the same trusted base a live reply goes
-- through.
--
-- __The table is matched by prefix, first entry wins__ — the rule
-- "Agentic.World"'s @byPrefix@ already implements for 'Agentic.World.TByPrefix'
-- worlds (@Conformance.lean@'s world DSL), so a scripted run and a pure
-- @byPrefix@ world agree on what a prompt matches. The Lean stub matches
-- /substrings/ instead (@stub_adapter.py:422@'s @answer_for@); this is the one
-- deliberate departure from it, and it is the safer rule, because a substring
-- key can match a prompt through an answer that was spliced into it. Callers
-- porting the stub's table must therefore key on what a prompt __starts__ with:
-- @\"Apply this patch?\"@ and @\"Apply:\"@ are already prefixes in the
-- flagship (@example-000@), while @\"correct?\"@ and @\"secure?\"@ are not — and
-- need not be, because an unmatched @verdict@ approves.
--
-- An unmatched prompt is answered by 'scriptedDefault' at its code rather than
-- by the stub's fixed refusal, so a scripted run settles instead of stalling on
-- the first prompt nobody wrote a line for.
--
-- Decoding is the real decoding: a canned @\"maybe\"@ at a @flag@ is unreadable,
-- is re-asked with the 'nudge', comes back the same, and abandons the run after
-- 'defaultRetries' + 1 attempts. That is not a defect of the stub — it is the
-- decode-exhaustion path, on the tested path.
scriptedWorld :: [(Text, Text)] -> WorldIO
scriptedWorld = scriptedWorldWith defaultExecSettings

-- | 'scriptedWorld' under an operator's 'ExecSettings'.
--
-- The table is the transport and the settings are the policy, which makes this
-- the one place a run policy can be exercised end to end without an agent: a
-- canned @\"maybe\"@ at a @flag@ is unreadable however it arrived, so the
-- budget, the fork, the loud arm and the standing answer are all reachable from
-- a list of pairs. That is how all four were exercised for this wave, at
-- @harden@'s @person owner@ flag, which a canned @\"maybe\"@ makes unreadable.
--
-- __No gate pins that yet.__ Nothing under @ci\/@ builds an 'ExecSettings' other
-- than 'defaultExecSettings', so what the gates cover is the defaults
-- reproducing the behaviour this module had before the policy existed — and
-- nothing about the policy itself. A scripted case under a non-default policy
-- is what would close that, and it is not in this wave.
scriptedWorldWith :: ExecSettings -> [(Text, Text)] -> WorldIO
scriptedWorldWith st table = concurrentWorld $ \c q ->
  askDecodingWith st c q (\_extra -> pure (scriptedReply table c q))

-- | The bytes the scripted table answers a question with: the first entry whose
-- key is a prefix of the prompt, else 'scriptedDefault'.
scriptedReply :: [(Text, Text)] -> SCode c -> Q c -> Text
scriptedReply table c q =
  fromMaybe (scriptedDefault c q) (snd <$> find (\e -> fst e `T.isPrefixOf` qPrompt q) table)

-- | What an unmatched prompt is answered with, per code:
--
-- * @text@ — the prompt itself, which is @Conformance.lean@'s @TextSpec.echo@
--   and the default world of the whole corpus;
-- * @flag@ — @yes@;
-- * @verdict@ — @APPROVE@;
-- * @receipt@ — @DONE@, the word 'answerSpec' asks an act for. It decodes to
--   @()@, as any bytes would.
--
-- These are /bytes/, not answers, and they go through 'decodeEl' like anything
-- else: the scripted world has no private channel to the answer type.
scriptedDefault :: SCode c -> Q c -> Text
scriptedDefault SText q = qPrompt q
scriptedDefault SFlag _ = "yes"
scriptedDefault SVerdict _ = "APPROVE"
scriptedDefault SAck _ = "DONE"
scriptedDefault code@(SStructured schema) _ =
  fromMaybe "null" (render schema (defaultEl code))

-- ---------------------------------------------------------------------------
-- Rendering helpers
-- ---------------------------------------------------------------------------

-- | A prompt as one line: nonblank lines, ASCII-trimmed, joined by a space.
--
-- Cosmetic, for a progress line that must not be four paragraphs tall. Nothing
-- decides anything by it.
oneLine :: Text -> Text
oneLine = T.intercalate " " . filter (not . T.null) . map trimAscii . T.splitOn "\n"

-- | @String.trimAscii@: ASCII whitespace dropped from both ends, the four
-- characters Lean core calls whitespace and no others.
--
-- Lean quotes replies back through it in every warning and both error messages,
-- so the port needs it to reproduce them. It is __only__ used to render
-- diagnostics: what an answer /means/ is decided in "Agentic.Text" and nowhere
-- else, and this is not that.
trimAscii :: Text -> Text
trimAscii = T.dropWhileEnd isWhitespaceAscii . T.dropWhile isWhitespaceAscii
  where
    isWhitespaceAscii ch = ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n'
