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
-- Description : The interpreter in @IO@: the memoizing fold, and the decode loop.
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
-- 2. __The memoizing fold__ — 'runPlanIO', @Exec.lean:503@'s @Dlg.execM@ at
--    @m := IO@, fused through @denote@ the way "Agentic.World"'s 'traceIn' is
--    (@Exec.lean:724@: @Plan.execWith o p γ t = Dlg.execM o (denote p γ) t@, and
--    @:726@ says that equation is @rfl@ because nothing else was written).
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
-- * the table is Lean's @Table@ — consulted before asking, extended after
--   answering, and that pair of lines is the whole of kernel §5's argument
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
-- > billMemo  t == the number of times the 'WorldIO' was actually invoked
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
    Plan (PAsk, PAskC, PCase, PDyn, PRet),
    Q (..),
    SCode (SAck, SFlag, SText, SVerdict),
    defaultEl,
    fromSCode,
    withPrompt,
  )
import Agentic.Raw
  ( Addressee (AddrModel, AddrPerson, AddrTool, AddrToolExec),
    Code (CodeAck, CodeFlag, CodeText, CodeVerdict),
  )
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
import Control.Exception
  ( Exception (displayException, toException),
    SomeAsyncException,
    SomeException,
    fromException,
    throwIO,
    try,
  )
import Data.List (find, nub)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Data.Type.Equality ((:~:) (Refl))
import System.IO (hPutStrLn, stderr)

-- ---------------------------------------------------------------------------
-- The answering service
-- ---------------------------------------------------------------------------

-- | @Oracle IO@ (@Exec.lean:476@), less the history argument: given a code and
-- a question, produce an answer, in @IO@.
--
-- A rank-2 newtype for the same reason "Agentic.World"'s 'World' is one — the
-- answer's type depends on the code — and the two differ in exactly the monad,
-- which is the sense in which the @IO@ layer is /only/ the answering service.
--
-- Two things this type says, and they are the reason it is this type
-- (@Exec.lean:461@–@:475@):
--
-- * it returns @IO (El c)@ and not @IO (El c, table)@, so an answerer can
--   invent an answer but cannot forge or delete a recorded one. That is
--   structural, not a discipline the code follows;
-- * it is where @IO@ is quarantined. No other declaration in this module is
--   effectful except 'runPlanIO', which only runs this one.
newtype WorldIO = WorldIO
  {worldAskIO :: forall (c :: Code). SCode c -> Q c -> IO (El c)}

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
pureWorldIO w = WorldIO (\c q -> pure (worldAnswer w c q))

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
announcingWorld out (WorldIO ask) = WorldIO $ \c q -> do
  out $
    codeWord (fromSCode c)
      <> " -> "
      <> addresseeWord (qAddressee q)
      <> ": "
      <> oneLine (qPrompt q)
  a <- ask c q
  out $ "  <- " <> oneLine (sayEl c a)
  pure a

-- ---------------------------------------------------------------------------
-- The interpreter: the memoizing fold
-- ---------------------------------------------------------------------------

-- | What the fold threads: Lean's @Table@ (@World.lean:118@, a list of
-- @⟨c, q, a⟩@) as a map keyed by the answer-forgetting projection of that
-- triple, plus the transcript in reverse.
--
-- The table is a 'Map' rather than an association list because @lookup@ is the
-- only operation on it and Lean's cons-order is unobservable through @lookup@:
-- a key is inserted only where the lookup said nothing (@World.lean:193@'s
-- @le_cons_of_lookup_none@ is that hypothesis, discharged at @Exec.lean:543@),
-- so no insert ever overwrites
-- and \"first wins\" and \"last wins\" coincide.
data Memo = Memo
  { memoTable :: !(Map EventKey Event),
    -- | most recent first; 'runPlanIO' reverses it once, at the end
    memoSaid :: [Event],
    -- | the models that reported their allowance spent, which a later question
    -- pinning one of them skips __without asking__. Threaded through the fold
    -- rather than held in an 'Data.IORef.IORef', so 'noChains' stays a value
    -- and @runPlanIO = runPlanWith noChains@ needs no @IO@ to say it.
    memoSpent :: !(Set Text)
  }

-- | @Plan.execWith o p Env.nil Table.nil@ (@Exec.lean:717@; Lean's @execIO@
-- entry point around it is retired, @Exec.lean:978@): run a closed plan against
-- an answering service and return the answer together with the transcript.
--
-- __Look up before asking; record after answering__ (@Exec.lean:490@). A
-- question whose 'EventKey' — code, addressee, scope, prompt and draw, which is
-- exactly what 'billMemo' charges by — has already been answered is answered
-- from the table and the service is not invoked. That is what makes the run
-- /functional/ with no hypothesis on the answerer, which is the whole of
-- @execM_adequacy@ (@Exec.lean:577@): one question, one answer, however
-- faithless the addressee.
--
-- A deliberate resample is not defeated by it: @draw@ is a field of the
-- question, so a second draw is a different question and misses the table by
-- construction (§3 q1).
--
-- The five clauses are @denote@'s fold in @IO@ and nothing more:
--
-- > PRet e       -- the answer, from what is known
-- > PAskC c q k  -- ask-or-memo, then continue with the answer consed on
-- > PAsk c s e k -- the same, at the question 'withPrompt' builds from what is known
-- > PCase _ e f  -- select the arm; nothing is asked and nothing is recorded
-- > PDyn _ e f   -- likewise, and it is here only for totality
--
-- 'PDyn' cannot be reached from @Agentic.Builder@ (no combinator makes one) and
-- the DSL never elaborates to one (@Check.lean:57@), but it is a former of the
-- language and this fold is total on the language, so it takes the same clause
-- @denote@ gives it — the two share a meaning clause on purpose
-- (@Denote.lean:60@).
--
-- __The prompt is evaluated before the answer is bound__, so a splice reads
-- what was already answered and never what this question will answer. Getting
-- that backwards is the one way this fold can differ from 'traceIn' while still
-- typechecking.
runPlanIO :: WorldIO -> Plan '[] a -> IO (a, Trace)
runPlanIO = runPlanWith noChains

-- | 'runPlanIO' under a chain table: the same fold, with 'askOrMemo' walking
-- the models a pinned question may be answered by rather than the one it names
-- (D6).
--
-- __The factorization survives, definitionally rather than by argument.__ With
-- an empty chain table and an empty spent set 'candidates' answers @[q]@, the
-- loop runs one iteration, the lookup and the insert are both at
-- @questionKey c q@, and the recovery fork is never consulted because no gap
-- arrives at a pure world. @runPlanWith noChains@ is therefore the 'askOrMemo'
-- of before, clause for clause, and
--
-- > runPlanIO (pureWorldIO w) p  ==  pure (runPlan w p, trace w p)
--
-- holds verbatim, with @runPlanIO = runPlanWith noChains@.
--
-- __The live trace may disagree with a frozen one, and that is the feature.__
-- The trace records the model that __actually answered__ — @Event c qi a@ is
-- built from the candidate that answered, and its scope serializes with no
-- change whatsoever — so a program whose frozen trace says @deep@ may, on a day
-- the allowance is spent, produce a live trace that says @broad@. That
-- divergence is the observation, and it is available to an operator precisely
-- because a fail-over is not written into the table under the primary's key.
-- The failed attempt itself is recorded nowhere: an 'Event' carries an answer
-- and a failed attempt has none, so the trace records the dialogue and
-- @stderr@ records the attempts.
runPlanWith :: Chains -> WorldIO -> Plan '[] a -> IO (a, Trace)
runPlanWith ch w p = do
  (a, m) <- execIn w ch ENil p (Memo Map.empty [] Set.empty)
  pure (a, reverse (memoSaid m))

-- | The fold proper, in an arbitrary context. Not exported: a plan is run
-- closed and from the empty table, which is the only case any theorem is
-- stated at.
execIn :: WorldIO -> Chains -> Env g -> Plan g a -> Memo -> IO (a, Memo)
execIn w ch y pl m = case pl of
  PRet e -> pure (e y, m)
  PAskC c q k -> do
    (a, m') <- askOrMemo w ch c q m
    execIn w ch (ECons a y) k m'
  PAsk c s e k -> do
    let q = withPrompt s (e y)
    (a, m') <- askOrMemo w ch c q m
    execIn w ch (ECons a y) k m'
  PCase _ e arms -> execIn w ch y (arms (e y)) m
  PDyn _ e f -> execIn w ch y (f (e y)) m

-- | @Exec.lean:523@ (@execM_ask_hit@) and @:530@ (@execM_ask_miss@), the two
-- clauses of the @ask@ case, plus the transcript entry both of them make — and,
-- since D6, the walk over the models a pinned question may be answered by.
--
-- In words: __for each live candidate in order, consult the table, then the
-- wire.__ The hit is the identity on the table; the miss asks, records, and
-- only then continues, so the continuation runs in the extended world.
--
-- Four properties, which are @Agent.Run.overChain@'s four discharged at these
-- types:
--
-- * /the whole action is retried/ — trivially: the action is one question;
-- * /re-run under the next connection's own recorder/ — the answer is memoized
--   under @questionKey c qi@, the __answerer's__ key, never the primary's.
--   Writing it under the primary's would put in the table an answer attributed
--   to a model that did not give it;
-- * /the exhaustion never escapes/ — when nothing is left, 'tgeFinal' is raised,
--   which is exactly what the run would have raised with no chain declared. So
--   with no alternates anywhere every diagnostic in this package is
--   byte-identical to the one before fail-over existed;
-- * /a spent model is not asked again/ — 'memoSpent' is why repetition stays
--   cheap and consistent. Walk an ask node twice, having lost @deep@ to
--   exhaustion on the first walk: the second walk's candidate list is
--   @[broad]@, the lookup at @broad@'s key hits, and nothing is put. The memo
--   invariant — a question already answered is not put again — survives a
--   fail-over intact. A __non__-exhaustion gap does not mark the model spent,
--   so the second walk does re-ask it, and that is right: a turn that failed
--   once is not a model that is finished.
--
-- __@billFresh@ is unchanged by construction__ (one event per ask node walked)
-- and @billMemo@ is unchanged in the ordinary fail-over, because the dead
-- attempts record nothing. It rises in exactly one situation — a node answered
-- by one model early and by another later — and that rise is correct: two
-- different models said the same words, which by 'EventKey'\'s own definition
-- is two questions.
askOrMemo :: WorldIO -> Chains -> SCode c -> Q c -> Memo -> IO (El c, Memo)
askOrMemo w ch c q m = do
  let live = candidates ch (memoSpent m) q
      skipped = [x | x <- chainOf ch q, x `Set.member` memoSpent m]
  mapM_ (chainLog ch . spentSkip) skipped
  case live of
    [] -> abandonAllSpent c q (chainOf ch q)
    qs -> go qs m
  where
    said qi a m' = m' {memoSaid = Event c qi a : memoSaid m'}

    go [] _ = abandonAllSpent c q (chainOf ch q)
    go (qi : rest) m' = case memoLookup c (questionKey c qi) (memoTable m') of
      Just a -> pure (a, said qi a m')
      Nothing -> do
        attempt <- try (worldAskIO w c qi)
        case attempt of
          Right a ->
            pure
              ( a,
                said
                  qi
                  a
                  m'
                    { memoTable =
                        Map.insert (questionKey c qi) (Event c qi a) (memoTable m')
                    }
              )
          Left (e :: SomeException)
            -- An interrupt is the operator talking, not a gap.
            | Just (_ :: SomeAsyncException) <- fromException e -> throwIO e
            | otherwise -> case fromException e of
                Nothing -> throwIO e
                Just tge -> do
                  let m'' =
                        if tgeGap tge == GapExhausted
                          then
                            m'
                              { memoSpent = case modelOf qi of
                                  Just i -> Set.insert i (memoSpent m')
                                  Nothing -> memoSpent m'
                              }
                          else m'
                  case rest of
                    (nxt : _) -> do
                      chainLog ch $
                        fromMaybe (addresseeWord (qAddressee qi)) (modelOf qi)
                          <> ": "
                          <> tgeWhy tge
                          <> "; falling back to "
                          <> fromMaybe "the next candidate" (modelOf nxt)
                      go rest m''
                    [] -> throwIO (tgeFinal tge)

    spentSkip i =
      i
        <> " " <> [wft|reported its allowance spent earlier in this run; not asking it again|]

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

-- | @lookup t c q@ (@World.lean:134@). The stored event carries its own code
-- witness, so recovering the answer at the caller's code is a matching of two
-- singletons.
--
-- The 'Nothing' of the inner match is unreachable — 'ekCode' is part of the key,
-- so a hit is at the same code — and it is written rather than @error@'d
-- because an unreachable branch that asks nobody a question costs nothing and a
-- partial function in the interpreter costs a run.
memoLookup :: SCode c -> EventKey -> Map EventKey Event -> Maybe (El c)
memoLookup c key tbl = case Map.lookup key tbl of
  Nothing -> Nothing
  Just (Event c' _ a) -> case sameCode c c' of
    Just Refl -> Just a
    Nothing -> Nothing

-- | Two code witnesses are the same code, with the type-level evidence. @El@ is
-- not injective, so this is the only way an answer comes back out of the table
-- at the type it went in.
sameCode :: SCode c -> SCode c' -> Maybe (c :~: c')
sameCode SText SText = Just Refl
sameCode SVerdict SVerdict = Just Refl
sameCode SFlag SFlag = Just Refl
sameCode SAck SAck = Just Refl
sameCode _ _ = Nothing

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
-- Every clause but the first and last is "Agentic.Text"'s. __Nothing here
-- decides anything__: this function is a re-indexing of the trusted base at
-- 'El', and if it ever grows a clause of its own the package has two answers to
-- the question of what an addressee said.
--
-- 'Nothing' is one code wide (@Decode_eq_none@, @Exec.lean:292@): a @flag@ is
-- the one code whose answer set is smaller than what an addressee can say, so
-- it is the one place the runtime has to be prepared to re-ask.
decodeEl :: SCode c -> Text -> Maybe (El c)
decodeEl SText s = Just s
decodeEl SVerdict s = Just (decodeVerdict s)
decodeEl SFlag s = decodeFlag s
decodeEl SAck _ = Just ()

-- | @Report.sayAnswer@ — an answer as the one word or line a report prints. The
-- inverse direction of 'decodeEl', and like it, all of the deciding lives in
-- "Agentic.Text" ('sayFlag', 'sayVerdict').
sayEl :: SCode c -> El c -> Text
sayEl SText s = s
sayEl SVerdict v = sayVerdict v
sayEl SFlag b = sayFlag b
sayEl SAck _ = "done"

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
codeWord :: Code -> Text
codeWord = \case
  CodeText -> "text"
  CodeVerdict -> "verdict"
  CodeFlag -> "flag"
  CodeAck -> "ack"

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
-- These four sentences are the exact bytes Lean sends, and an adapter that
-- appends a format line to a prompt should append one of these rather than a
-- paraphrase: an addressee told two different formats in one prompt obeys
-- neither (@Exec.lean:804@).
answerSpec :: Code -> Text
answerSpec = \case
  CodeText -> "Reply with the text itself and nothing else."
  CodeVerdict -> "Reply with exactly APPROVE if acceptable, or OBJECTION: <one line> if not."
  CodeFlag -> "Reply with exactly yes or no."
  CodeAck -> "Do what was asked, then reply with exactly DONE."

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
    <> answerSpec (fromSCode c)
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
requiresCompletedTurn :: Code -> Addressee -> Bool
requiresCompletedTurn CodeAck _ = True
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
    -- code. One code wide (@Decode_eq_none@): only a @flag@ can produce it.
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
-- 3. __The loud arm.__ If 'esLoudArm' is set and the code is @flag@ — the only
--    code that can be undecodable at all — a spent question takes the
--    configured arm with a warning instead of abandoning. Everything else, and
--    every code but @flag@, abandons exactly as before.
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
scriptedWorldWith st table = WorldIO $ \c q ->
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
