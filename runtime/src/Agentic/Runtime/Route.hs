{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE RankNTypes #-}

-- | Generic model-axis routing over an arbitrary backend table.
module Agentic.Runtime.Route
  ( Routes (..),
    routes,
    routesCovered,
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
import Data.Maybe (maybeToList)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T


-- ---------------------------------------------------------------------------
-- The table
-- ---------------------------------------------------------------------------

-- | A run's answerers: an optional default and routes claimed by serving model.
-- A routing-only run has no default and must prove its named map total before
-- execution.
--
-- Parametric in the backend because the same table is wanted twice at two
-- types: 'Backend' as the command line spelled it, and 'Agentic.Exec.WorldIO'
-- once transports are connected. The 'Functor' instance is that connection
-- step, making it impossible to connect a backend the table did not name.
--
-- 'routeNamed' preserves presentation and startup order. 'routeByModel' is the
-- same table for lookup. The two smart constructors are their only builders.
data Routes b = Routes
  { -- | The backend for an unclaimed question, absent under full pin coverage.
    routeDefault :: !(Maybe b),
    -- | The routes, in the order they were given.
    routeNamed :: ![(Text, b)],
    -- | The same routes, for lookup.
    routeByModel :: !(Map Text b)
  }
  deriving (Functor)

-- | Build a table with an explicit default.
routes :: b -> [(Text, b)] -> Routes b
routes defaultBackend = routeTable (Just defaultBackend)

-- | Build a named table with no default. Its caller must establish full
-- coverage before execution.
routesCovered :: [(Text, b)] -> Routes b
routesCovered = routeTable Nothing

routeTable :: Maybe b -> [(Text, b)] -> Routes b
routeTable defaultBackend named = Routes defaultBackend named (Map.fromList named)

-- | Route by model axis, then use the default when one exists.
--
-- A routing-only table returns 'Nothing' for an uncovered question. CLI
-- preflight proves that case unreachable before 'routedWorld' is installed.
backendFor :: Routes b -> Q c -> Maybe b
backendFor rs q = case scopeModelAxis (qScope q) of
  Just model -> case Map.lookup model (routeByModel rs) of
    Just backend -> Just backend
    Nothing -> routeDefault rs
  Nothing -> routeDefault rs

-- | Distinct backends in startup order: an explicit default when present, then
-- named routes. A fully covered table starts directly with its first named route.
routeBackends :: (Eq b) => Routes b -> [b]
routeBackends rs = nub (maybeToList (routeDefault rs) <> map snd (routeNamed rs))

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
    { worldAskIO = \code request -> case backendFor rs (reqQuestion request) of
        Just backend -> worldAskIO backend code request
        Nothing -> missing (reqQuestion request),
      worldAskAttemptIO = \context code request -> case backendFor rs (reqQuestion request) of
        Just backend -> worldAskAttemptIO backend context code request
        Nothing -> missing (reqQuestion request),
      worldTurnLane = \code shape ->
        backendFor rs (reqQuestion (withRequestPrompt shape T.empty))
          >>= \backend -> worldTurnLane backend code shape
    }
  where
    missing question =
      ioError
        ( userError
            ( "routing table has no backend for model axis "
                <> show (scopeModelAxis (qScope question))
            )
        )
