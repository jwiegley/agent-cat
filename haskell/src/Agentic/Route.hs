{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RankNTypes #-}

-- |
-- Module      : Agentic.Route
-- Description : Which backend answers which request — execution policy only.
--
-- One run, several model backends. A route is a pair @NAME=BACKEND@ where
-- @NAME@ is a __serving model__ — a @served by@ pin, or one of its
-- @falling back to@ spares — and @BACKEND@ is a transport to start or to send
-- to. The whole runtime is 'routedWorld', a 'WorldIO' that dispatches both the
-- request and prompt-independent turn lane to backend selected by its question's
-- model axis.
--
-- __The resolution rule, stated once.__ /A question is routed by its model
-- axis; 'Nothing' takes the default./ Four things follow, and the first is why
-- the rule is this one and not the obvious alternative of routing the party:
--
--   * __It is the only rule under which a fail-over ladder can cross
--     providers__, which is the entire capability. @Agentic.Exec.candidates@
--     relabels @scopeModelAxis@ and leaves every other field alone, so a
--     question that fell over is routed by its /new/ label the next time round
--     the loop — with no change to "Agentic.Exec" at all. Route the party
--     instead and every rung of one party's ladder lands on one backend, which
--     is the case that made the ladder worth writing.
--
--   * __The pin already has exactly one meaning per run, and the party does
--     not.__ "Agentic.Chains" states the precondition and @agentic-run@ refuses
--     to start a program that breaks it: a chain is a property of the model and
--     not of the question. A table keyed on those same names inherits that
--     coherence for free. Party names are per-program and per-role, and two
--     programs in one registry may both have a @reviewer@.
--
--   * __Attribution needs no new field.__ The trace records the model axis of
--     whoever actually answered, so /route table + trace/ says which backend
--     answered every event, totally and after the fact — the table from the run
--     header, the axis from "Agentic.World"'s own @scopeJson@. Route the party
--     and the trace says nothing about which backend answered a party whose pin
--     fell over.
--
--   * __It makes @--require-pinned@ the honest precondition it claims to be.__
--     "Agentic.Guards"' @guardUnpinnedAsk@ refuses a program that leaves a
--     model ask without a @served by@ so that no question quietly reaches
--     whatever model the transport happened to have. A route is that guarantee
--     promoted from /which model/ to /which machine/.
--
-- __There is no backend-level fail-over, and there will not be one.__ A route
-- is a total, deterministic function of the pin, fixed for the run: it may not
-- vary by attempt, by clock, or by a liveness probe. The reason is the memo
-- table. One pin tried at two backends is the same question — same code, same
-- addressee, same scope, same prompt, same draw, hence the same @EventKey@ —
-- put twice to two processes; the first answer is inserted and the second is a
-- request the table cannot distinguish from the first and the bill cannot
-- see. Cross-provider recovery goes through the /pin ladder/, which relabels
-- the key, and there is nowhere else for it to go. The corollary an implementer
-- must not miss: __a route whose backend is dead is a dead question__, not a
-- question that silently tries elsewhere. If the author wanted a spare they
-- wrote one.
--
-- __What this module is not.__ It is not part of the language. Nothing here is
-- a port of anything in Lean and nothing here carries a @.lean@ citation,
-- exactly as "Agentic.Chains" carries none and for the same reason: no kernel,
-- no oracle, no corpus. A route changes /who is asked on which machine/ and
-- cannot change what was asked, what came back, what it cost, or what any of it
-- means. The structures that decide a frozen reply — @EventKey@, @Event@,
-- @eventJson@, @scopeJson@, @billFresh@, @billMemo@ — name no backend, so two
-- runs of one program differing only in their route table produce
-- __byte-identical traces and identical bills__ whenever they produce identical
-- answers. There is no field in which they could differ.
module Agentic.Route
  ( -- * Where a question is put
    Backend (..),
    Scheme (..),
    schemeOf,
    schemeWord,

    -- * What the command line said
    parseBackend,
    parseRoute,
    backendSpelling,

    -- * The table
    Routes (..),
    routes,
    backendFor,
    routeBackends,

    -- * The layer
    routedWorld,
  )
where

import Agentic.Exec (WorldIO (..))
import Agentic.Plan
  ( Q (qScope),
    QScope (scopeModelAxis),
    Request (reqQuestion),
    withRequestPrompt
  )
import Agentic.WF (wft)
import Data.List (nub)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T

-- ---------------------------------------------------------------------------
-- Where a question is put
-- ---------------------------------------------------------------------------

-- | A transport, named the way an operator names it on the command line.
--
-- The two are the two engines @run@ already has, and this type adds neither: an
-- 'BackendAcp' word is what @--adapter@ takes and reaches
-- 'Agentic.Acp.adapterArgv' verbatim, a 'BackendDeck' word is what @--session@
-- takes and reaches 'Agentic.AgentDeck.defaultDeckConfig' verbatim. Nothing new
-- is parsed anywhere in this module: those two functions already turn a word
-- into a backend, and the grammar below is the colon and a lookup.
--
-- 'Eq' is load-bearing rather than decorative — it is what 'routeBackends'
-- deduplicates by, so two pins routed to the same adapter share one process
-- (§3.1) and the header does not overstate how many agents this run started.
data Backend
  = -- | @acp:stub@ | @acp:claude@ | @acp:codex@ | @acp:\/path\/to\/adapter@ —
    -- an adapter this run starts and owns the pipe to.
    BackendAcp !Text
  | -- | @deck:\<id\>@ — a live @agent-deck@ session somebody else started.
    BackendDeck !Text
  deriving (Eq, Ord, Show)

-- | Which of the two transports a backend is.
--
-- It exists for one caller: the run's flag check. @--binary@ and @--poll@ are
-- the deck engine's and @--adapter@, @--adapter-arg@ and @--scratch@ are the
-- acp engine's, and until routing existed a run /was/ one engine, so "not the
-- acp engine's to take" was a complete sentence. With a @deck:@ route under an
-- @acp@ default it is not, and the rule generalizes to the __set of schemes
-- this run's table uses__, default included.
data Scheme
  = SchemeAcp
  | SchemeDeck
  deriving (Eq, Ord, Show, Enum, Bounded)

schemeOf :: Backend -> Scheme
schemeOf = \case
  BackendAcp _ -> SchemeAcp
  BackendDeck _ -> SchemeDeck

-- | How a scheme names itself in a refusal — today's words, unchanged, because
-- a run with one scheme must refuse a foreign flag in exactly the sentence it
-- always did.
schemeWord :: Scheme -> Text
schemeWord = \case
  SchemeAcp -> "the acp engine"
  SchemeDeck -> "the deck engine"

-- ---------------------------------------------------------------------------
-- What the command line said
-- ---------------------------------------------------------------------------

-- | @scheme:value@, split on the __first__ colon.
--
-- The first and not the last, and not on every colon: a @deck:@ value may be a
-- session title that contains one, and an @acp:@ value may be a path
-- (@acp:C:\\adapters\\x@ on a machine that spells paths that way). Splitting
-- anywhere else would make a legal name unnameable.
--
-- Every failure is one refusal, naming both shapes, because everything that is
-- not one of the two shapes is the same mistake: the operator has written
-- something this run cannot start or send to, and what they need is the two
-- things they may write instead.
--
-- __Surrounding whitespace is not part of either half__, and stripping it is a
-- refusal and not a convenience. No adapter is named @\" \"@ and no session is
-- addressed by a blank, so a value that is only whitespace is a value the
-- operator did not give — and being one character rather than none, it used to
-- pass every check this module and the command line make, put a blank name in
-- the header, and be discovered by @posix_spawnp@ after the run had already
-- started an adapter. A usage error must arrive before anything is spawned or
-- it is not a usage error. Trimmed, it is exactly the refusal @acp:@ gets,
-- arriving where every other malformed shape does.
parseBackend :: Text -> Either Text Backend
parseBackend spec = case T.breakOn ":" spec of
  (scheme, rest)
    | Just raw <- T.stripPrefix ":" rest,
      let value = T.strip raw,
      not (T.null value) ->
        case T.strip scheme of
          "acp" -> Right (BackendAcp value)
          "deck" -> Right (BackendDeck value)
          _ -> unknown
  _ -> unknown
  where
    unknown =
      Left $
        "unknown backend '"
          <> spec
          <> [wft|' in --route: a backend is acp:<adapter> (start an adapter of this run's own) or deck:<id> (send to a live agent-deck session)|]

-- | A backend as the operator would have written it: the printed inverse of
-- 'parseBackend'.
--
-- @'parseBackend' ('backendSpelling' b) == Right b@ for every backend
-- 'parseBackend' can produce, which is what makes this the grammar's own
-- spelling rather than a second one: it lives beside the parser so the two
-- cannot drift, and a caller that wants a backend named in one word does not
-- invent @acp:@ for itself.
--
-- It is deliberately __not__ what the run's header prints for a single backend.
-- That line carries the adapter's whole argv, because an operator reading a
-- header wants to know which program was started; a caller naming a backend
-- inside a sentence wants the word they typed.
backendSpelling :: Backend -> Text
backendSpelling = \case
  BackendAcp w -> "acp:" <> w
  BackendDeck s -> "deck:" <> s

-- | @NAME=BACKEND@, split on the first @=@.
--
-- The first @=@ for the reason @--input-file@ splits on the first @=@: no model
-- name contains one, and a value may contain as many as it likes.
--
-- The name is trimmed for 'parseBackend''s reason and with the same
-- consequence: no model is pinned under a name with a space on the end, so a
-- name that is blank after trimming is a name the operator did not give, and it
-- takes the shape refusal rather than reaching 'routes' as a key nothing can
-- ever match.
parseRoute :: Text -> Either Text (Text, Backend)
parseRoute spec = case T.breakOn "=" spec of
  (raw, rest)
    | Just b <- T.stripPrefix "=" rest,
      let name = T.strip raw,
      not (T.null name) ->
        (,) name <$> parseBackend b
  _ -> Left ("--route takes NAME=BACKEND, not '" <> spec <> "'")

-- ---------------------------------------------------------------------------
-- The table
-- ---------------------------------------------------------------------------

-- | A run's answerers: the one every question takes unless a route claims it,
-- and the routes, which claim by serving model.
--
-- Parametric in the backend because the same table is wanted twice at two
-- types: 'Backend' as the command line spelled it — which is what the refusals
-- and the header are about — and 'Agentic.Exec.WorldIO' once the transports are
-- connected, which is what 'routedWorld' dispatches over. The 'Functor'
-- instance is the connect step, and keeping it a @fmap@ is what makes it
-- impossible to connect a backend the header did not name.
--
-- __Why the routes are held twice.__ 'routeNamed' is the order the operator
-- typed, which is the order the run starts them and the order the header prints
-- them — an operator must be able to read the header against their own command
-- line. 'routeByModel' is the same table for lookup, which is what
-- 'backendFor' does once per request. 'routes' is the only thing that
-- builds either, so they cannot disagree.
data Routes b = Routes
  { -- | Every question no route claims: every unpinned ask, every tool, every
    -- person, and every pinned model this table does not name.
    routeDefault :: !b,
    -- | The routes, in the order they were given.
    routeNamed :: ![(Text, b)],
    -- | The same routes, for lookup.
    routeByModel :: !(Map Text b)
  }
  deriving (Functor)

-- | The table of a default and the routes that refine it.
--
-- The only constructor callers should use. A name given twice would be
-- resolved here by 'Data.Map.Strict.fromList', which retains the /last/ value
-- for a repeated key — while 'routeNamed' would still carry both, so the header
-- would announce a backend the lookup never used. That is not a policy, because
-- it is unreachable: the CLI refuses a name routed twice before this is called
-- (§1.5), because an operator who wrote two backends for one model believes
-- something about the run that no resolution of the clash would make true.
routes :: b -> [(Text, b)] -> Routes b
routes d named = Routes d named (Map.fromList named)

-- | __A question is routed by its model axis. 'Nothing' takes the default.__
--
-- One field, and it is the field "Agentic.Exec" has already computed, already
-- relabels on a fail-over, and already records in the trace. A question with no
-- model axis — an unpinned model ask, a tool, a person — takes the default,
-- because there is no name on it to route by and inventing one would be the
-- runner deciding something the program declined to say.
backendFor :: Routes b -> Q c -> b
backendFor rs q = case scopeModelAxis (qScope q) of
  Just m -> Map.findWithDefault (routeDefault rs) m (routeByModel rs)
  Nothing -> routeDefault rs

-- | The distinct backends of a table, in the order a run starts them: __the
-- default first__, then the named routes in the order they were typed.
--
-- The default first because every run needs it, so a run whose default will not
-- start fails before spawning anything else. Typed order after it so the
-- operator can read the header against their own command line.
--
-- __Deduplicated__, which is the whole reason this is a function and not
-- @map snd@: two pins routed to @acp:codex@ are the same provider, two
-- processes would double nothing, and a header that counted route lines rather
-- than processes would say this run started more agents than it did.
--
-- The deduplication is safe today for a reason that is a constraint on
-- tomorrow: 'Agentic.Acp.acpFreshPerQuestion' is 'True' and the CLI never
-- overrides it, so two pins sharing an adapter never share a conversation.
-- __Any future flag exposing @acpFreshPerQuestion = False@ must either disable
-- this or key sessions by pin__, or two pins would silently share context.
routeBackends :: (Eq b) => Routes b -> [b]
routeBackends rs = nub (routeDefault rs : map snd (routeNamed rs))

-- ---------------------------------------------------------------------------
-- The layer
-- ---------------------------------------------------------------------------

-- | Dispatch each request by its question's model axis.
--
-- Installed at exactly the position one @worldOfAcp cfg acp@ occupies today, so
-- that @runPlanWith@, the memo table, the chain walk, @billFresh@, @billMemo@
-- and every field of @EventKey@ are untouched __by construction rather than by
-- argument__: a 'WorldIO' carries an answerer and a prompt-independent lane
-- selector; 'routedWorld' maps both through the same backend table. Exactly as
-- "Agentic.Exec" requires, it can answer or fail but cannot forge or delete an
-- event, while the selected lane lets the scheduler preserve that backend's
-- plan order before prompt dependencies are ready. __Routing is substitution at
-- the same type.__ That is the argument in full.
--
-- Three consequences follow from the position rather than from care:
--
--   * __A @toolExec@ question is never routed.__
--     'Agentic.Shell.executingWorld' answers it before consulting the world
--     beneath, so a program-authored command reaches no backend at all and D5's
--     guarantee — a gate is an exit code and not a model's claim about one — is
--     unaffected by which providers the run reached.
--   * __Announcement is unchanged.__ @announcingWorld@ is outermost, prints one
--     line per reusable miss or effect occurrence; memo hits print nothing.
--     Routing changes neither count nor wording.
--   * __The chain walk is above routing, not beside it.__ @askOrMemo@ computes
--     the candidate sequence as a pure function of the question and the chain
--     table, consults the memo, and only then calls @worldAskIO@. Routing is
--     what happens /inside/ that call.
routedWorld :: Routes WorldIO -> WorldIO
routedWorld rs =
  WorldIO
    { worldAskIO = \c q -> worldAskIO (backendFor rs (reqQuestion q)) c q,
      worldTurnLane = \c shape ->
        let backend = backendFor rs (reqQuestion (withRequestPrompt shape T.empty))
         in worldTurnLane backend c shape
    }
