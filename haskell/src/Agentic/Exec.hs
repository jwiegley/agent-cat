{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators #-}

-- |
-- Module      : Agentic.Exec
-- Description : The interpreter in @IO@: the memoizing fold, and the decode loop.
--
-- A port of @Agentic\/Core\/Exec.lean@ from the line where the theorems stop
-- (@Exec.lean:463@, \"the interpreter: a memoizing fold, with the answering
-- service an argument\") to the line where the transport begins. Three layers,
-- in Lean's order, and the order is the point:
--
-- 1. __The trusted base__ — 'decodeEl', @Exec.lean:273@'s @Decode@. It is one
--    total parser per code and it is not written here: every clause delegates
--    to "Agentic.Text", which is the byte-faithful port and the /only/ place in
--    this package that decides what an addressee's bytes mean. A second copy of
--    that decision is exactly what @Exec.lean:249@–@:259@ says must not exist.
-- 2. __The memoizing fold__ — 'runPlanIO', @Exec.lean:511@'s @Dlg.execM@ at
--    @m := IO@, fused through @denote@ the way "Agentic.World"'s 'traceIn' is
--    (@Exec.lean:725@: @Plan.execWith o p γ t = Dlg.execM o (denote p γ) t@, and
--    @:732@ says that equation is @rfl@ because nothing else was written).
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
--   (@Exec.lean:500@–@:510@). A question already answered is not put again.
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
-- @Exec.lean:626@), the factorization theorem @Exec.lean:654@ becomes an
-- equation anyone can run:
--
-- > runPlanIO (pureWorldIO w) p  ==  pure (runPlan w p, trace w p)
--
-- == What is deliberately not ported
--
-- The @Oracle@'s history argument (@Exec.lean:484@: @(c : Code) → Q c → Table →
-- m (El c)@) is dropped from 'WorldIO'. Adequacy quantifies over
-- history-dependent oracles, so an oracle that cannot see the history is a
-- special case of the ones @execM_adequacy@ covers: dropping the argument
-- weakens the /answerer/, never the theorem. Nothing downstream consults it —
-- neither the stub nor a CLI transport has a use for the table — and an argument
-- nobody reads invites somebody to start reading it.
--
-- @Exec.Settings@ is not ported as a record either. Two of its fields are
-- semantics-adjacent and appear here as arguments ('askDecoding' takes the log
-- and the retry count); the rest — session policy, permission policy, ACP scope
-- selection, turn reporting — are facts about a transport this runner does not
-- have, and belong to whichever adapter does. 'requiresCompletedTurn' is here
-- because it is a decision about what bytes may mean and an adapter that can
-- observe how a turn ended owes it.
module Agentic.Exec
  ( -- * The answering service
    WorldIO (..),
    pureWorldIO,
    announcingWorld,

    -- * The interpreter
    runPlanIO,

    -- * The trusted base, at the typed answer
    decodeEl,
    sayEl,

    -- * The decode loop
    attemptDecoding,
    askDecoding,
    defaultRetries,
    stderrLog,

    -- * What a question says about itself on the wire
    codeWord,
    addresseeWord,
    answerSpec,
    nudge,
    requiresCompletedTurn,

    -- * The scripted world
    scriptedWorld,
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
  ( Addressee (AddrModel, AddrPerson, AddrTool),
    Code (CodeAck, CodeFlag, CodeText, CodeVerdict),
  )
import Agentic.Text (decodeFlag, decodeVerdict, sayFlag, sayVerdict)
import Agentic.World
  ( Event (Event),
    EventKey,
    Trace,
    World (worldAnswer),
    eventKey,
  )
import Data.List (find)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Type.Equality ((:~:) (Refl))
import System.IO (hPutStrLn, stderr)

-- ---------------------------------------------------------------------------
-- The answering service
-- ---------------------------------------------------------------------------

-- | @Oracle IO@ (@Exec.lean:484@), less the history argument: given a code and
-- a question, produce an answer, in @IO@.
--
-- A rank-2 newtype for the same reason "Agentic.World"'s 'World' is one — the
-- answer's type depends on the code — and the two differ in exactly the monad,
-- which is the sense in which the @IO@ layer is /only/ the answering service.
--
-- Two things this type says, and they are the reason it is this type
-- (@Exec.lean:469@–@:483@):
--
-- * it returns @IO (El c)@ and not @IO (El c, table)@, so an answerer can
--   invent an answer but cannot forge or delete a recorded one. That is
--   structural, not a discipline the code follows;
-- * it is where @IO@ is quarantined. No other declaration in this module is
--   effectful except 'runPlanIO', which only runs this one.
newtype WorldIO = WorldIO
  {worldAskIO :: forall (c :: Code). SCode c -> Q c -> IO (El c)}

-- | @pureOracle ω@ (@Exec.lean:626@): the answering service that /is/ the world
-- @ω@, ignoring the history because a world is a function of the question.
--
-- This is the factorization written as a definition. 'runPlanIO' at this
-- 'WorldIO' returns the meaning and the pure transcript:
--
-- > runPlanIO (pureWorldIO w) p  ==  pure (runPlan w p, trace w p)
--
-- which is @Plan.execPure_fst@ (@Exec.lean:755@) and @execM_pure@'s third
-- conclusion (@:654@) at once. The memo table changes nothing here precisely
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
-- Reporting only. Removing it changes no answer, exactly as @Settings.onTurn@
-- (@Exec.lean:1042@) changes none.
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
-- a key is inserted only where the lookup said nothing (@Exec.lean:551@'s
-- @le_cons_of_lookup_none@ is that hypothesis), so no insert ever overwrites
-- and \"first wins\" and \"last wins\" coincide.
data Memo = Memo
  { memoTable :: !(Map EventKey Event),
    -- | most recent first; 'runPlanIO' reverses it once, at the end
    memoSaid :: [Event]
  }

-- | @Plan.execWith o p Env.nil Table.nil@ (@Exec.lean:725@, @:1386@'s
-- @execIO@): run a closed plan against an answering service and return the
-- answer together with the transcript.
--
-- __Look up before asking; record after answering__ (@Exec.lean:500@). A
-- question whose 'EventKey' — code, addressee, scope, prompt and draw, which is
-- exactly what 'billMemo' charges by — has already been answered is answered
-- from the table and the service is not invoked. That is what makes the run
-- /functional/ with no hypothesis on the answerer, which is the whole of
-- @execM_adequacy@ (@Exec.lean:585@): one question, one answer, however
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
-- the DSL never elaborates to one (@Check.lean:55@), but it is a former of the
-- language and this fold is total on the language, so it takes the same clause
-- @denote@ gives it — the two share a meaning clause on purpose
-- (@Denote.lean:60@).
--
-- __The prompt is evaluated before the answer is bound__, so a splice reads
-- what was already answered and never what this question will answer. Getting
-- that backwards is the one way this fold can differ from 'traceIn' while still
-- typechecking.
runPlanIO :: WorldIO -> Plan '[] a -> IO (a, Trace)
runPlanIO w p = do
  (a, m) <- execIn w ENil p (Memo Map.empty [])
  pure (a, reverse (memoSaid m))

-- | The fold proper, in an arbitrary context. Not exported: a plan is run
-- closed and from the empty table, which is the only case any theorem is
-- stated at.
execIn :: WorldIO -> Env g -> Plan g a -> Memo -> IO (a, Memo)
execIn w y pl m = case pl of
  PRet e -> pure (e y, m)
  PAskC c q k -> do
    (a, m') <- askOrMemo w c q m
    execIn w (ECons a y) k m'
  PAsk c s e k -> do
    let q = withPrompt s (e y)
    (a, m') <- askOrMemo w c q m
    execIn w (ECons a y) k m'
  PCase _ e arms -> execIn w y (arms (e y)) m
  PDyn _ e f -> execIn w y (f (e y)) m

-- | @Exec.lean:531@ (@execM_ask_hit@) and @:538@ (@execM_ask_miss@), the two
-- clauses of the @ask@ case, plus the transcript entry both of them make.
--
-- The hit is the identity on the table; the miss asks, records, and only then
-- continues, so the continuation runs in the extended world.
askOrMemo :: WorldIO -> SCode c -> Q c -> Memo -> IO (El c, Memo)
askOrMemo w c q m = case memoLookup c key (memoTable m) of
  Just a -> pure (a, said a m)
  Nothing -> do
    a <- worldAskIO w c q
    pure (a, said a m {memoTable = Map.insert key (Event c q a) (memoTable m)})
  where
    key = questionKey c q
    said a m' = m' {memoSaid = Event c q a : memoSaid m'}

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

-- | @Decode@ (@Exec.lean:273@) — the total function per code taking the bytes
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
-- 'Nothing' is one code wide (@Decode_eq_none@, @Exec.lean:300@): a @flag@ is
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

-- | @Exec.Code.name@ (@Exec.lean:786@) — how a code names itself in a prompt
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

-- | @Addressee.render@ (@Exec.lean:793@) — how an addressee names itself in a
-- prompt header and in an error.
addresseeWord :: Addressee -> Text
addresseeWord = \case
  AddrModel i -> "model " <> i
  AddrTool i -> "tool " <> i
  AddrPerson i -> "person " <> i

-- | @Exec.answerSpec@ (@Exec.lean:816@) — what the addressee must say for
-- 'decodeEl' to read it, sent with every question because the trusted base is
-- narrow on purpose and an addressee cannot be expected to guess it.
--
-- These four sentences are the exact bytes Lean sends, and an adapter that
-- appends a format line to a prompt should append one of these rather than a
-- paraphrase: an addressee told two different formats in one prompt obeys
-- neither (@Exec.lean:812@).
answerSpec :: Code -> Text
answerSpec = \case
  CodeText -> "Reply with the text itself and nothing else."
  CodeVerdict -> "Reply with exactly APPROVE if acceptable, or OBJECTION: <one line> if not."
  CodeFlag -> "Reply with exactly yes or no."
  CodeAck -> "Do what was asked, then reply with exactly DONE."

-- | @Exec.nudge@ (@Exec.lean:874@) — what to append when a reply could not be
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

-- | @Exec.requiresCompletedTurn@ (@Exec.lean:1190@) — may an answer to this
-- question be recorded from a turn the agent did __not__ finish?
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
-- The decode loop
-- ---------------------------------------------------------------------------

-- | @Settings.retries@'s default (@Exec.lean:960@): re-ask once, so a question
-- is put at most twice.
--
-- Only a @flag@ can trigger a re-ask at all (@Decode_eq_none@), so this is not
-- a general error-handling budget; it is the width of the one code whose answer
-- set is narrower than what an addressee can say.
defaultRetries :: Int
defaultRetries = 1

-- | @Settings.log@'s default (@Exec.lean:1032@): a warning goes to stderr,
-- prefixed @agentic:@.
--
-- Warnings report what the run is /about/ to do about something it noticed;
-- they are never a substitute for doing it, which is why an answer that could
-- not be read at all is an error and not a log line.
stderrLog :: Text -> IO ()
stderrLog msg = hPutStrLn stderr ("agentic: " <> T.unpack msg)

-- | @Exec.attempt@ (@Exec.lean:1279@): ask, decode, and on a failure to decode
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
attemptDecoding lg retries c say = go (max 0 retries) T.empty
  where
    go :: Int -> Text -> IO (Either Text (El c))
    go n extra = do
      reply <- say extra
      case decodeEl c reply of
        Just a -> pure (Right a)
        Nothing
          | n <= 0 -> pure (Left reply)
          | otherwise -> do
              lg $
                "could not read a "
                  <> codeWord (fromSCode c)
                  <> " from '"
                  <> trimAscii reply
                  <> "'; re-asking"
              go (n - 1) (nudge c reply)

-- | @Exec.oracle@'s decode half (@Exec.lean:1344@): 'attemptDecoding', and — if
-- every attempt was unreadable — __abandon the run__ with an 'ioError' quoting
-- the words that could not be read.
--
-- __Why exhaustion is an error and not a default__ (@Exec.lean:1299@). Every
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
askDecoding lg retries c q say =
  attemptDecoding lg retries c say >>= \case
    Right a -> pure a
    Left reply ->
      ioError . userError . T.unpack $
        "no readable "
          <> codeWord (fromSCode c)
          <> " from "
          <> addresseeWord (qAddressee q)
          <> " after "
          <> T.pack (show (max 0 retries + 1))
          <> " attempts; last reply: '"
          <> trimAscii reply
          <> "' (prompt: '"
          <> qPrompt q
          <> "'). The run is abandoned: recording an answer nobody gave would be "
          <> "indistinguishable, in the table, from one they did."

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
-- @\"Apply this patch?\"@ and @\"Apply:\"@ are already prefixes in
-- @example\/harden.wf@, while @\"correct?\"@ and @\"secure?\"@ are not — and
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
scriptedWorld table = WorldIO $ \c q ->
  askDecoding stderrLog defaultRetries c q (\_extra -> pure (scriptedReply table c q))

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
