{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RankNTypes #-}

-- | Generic model-axis routing over an arbitrary backend table.
module Agentic.Runtime.Route
  ( Routes (..),
    routes,
    backendFor,
    routeBackends,
    routedWorld,
  )
where

import Agentic.Exec (WorldIO (..))
import Agentic.Plan
  ( Q (qScope),
    QScope (scopeModelAxis),
    Request (reqQuestion),
    withRequestPrompt,
  )
import Data.List (nub)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T


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
      worldAskAttemptIO = \context c q ->
        worldAskAttemptIO (backendFor rs (reqQuestion q)) context c q,
      worldTurnLane = \c shape ->
        let backend = backendFor rs (reqQuestion (withRequestPrompt shape T.empty))
         in worldTurnLane backend c shape
    }
