{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}

-- | Optional CLI policy requiring every model ask to carry a symbolic pin.
module Agentic.RequirePinned (guardUnpinnedAsk) where

import Agentic.DSL
  ( Addressee (..),
    Raw (..),
    RawAsk (..),
    RawBodyStmt (..),
    RawFn (..),
    RawProgram (..),
    RawRhs (..),
    RawSource (..),
    RawTarget (..),
    TextMember (..),
  )
import Agentic.WF (wft)
import Control.Applicative ((<|>))
import Data.Text (Text)

-- * Small helpers

-- | Lean's @Option.orElse@ chain, left to right: the first refusal wins.
--
-- Polymorphic because 'guardUnpinnedAsk' reads the same traversal at a
-- different answer, and two copies of "first one wins" is exactly how two
-- traversals come to disagree about which ask a program is refused over.
firstOf :: [Maybe a] -> Maybe a
firstOf = foldr (<|>) Nothing

-- * The opt-in pin guard

-- | The one guard that is ours and not Lean's: refuse a program in which some
-- __model__ ask does not name the model that serves it.
--
-- 'Nothing' is \"every model ask is pinned\"; @Just why@ is the refusal, worded
-- so that a caller can print it and an operator can act on it by editing one
-- line of the program.
--
-- == Why this exists, and why it is a guard rather than a wrapper
--
-- @agent-functor@ pins a whole subtree at once — @stackPin (remediate …)@ wraps
-- a scope and every leaf under it inherits the model, so a leaf /added later/
-- is pinned by construction and nobody has to remember. Here the pin is a
-- property of the question (@ask (model \"reviewer\") \`servedBy\` \"deep\"@),
-- which is better in every respect but that one: the argument for a pin is made
-- site by site where it belongs, and the deliberate /absence/ of a pin is
-- written by not writing it. The one thing the scope wrapper gives that the
-- per-question pin cannot is the guarantee over what has not been written yet
-- (@isaac-workflows@ G10, D9).
--
-- So we take the guarantee the way this language takes guarantees: not by
-- wrapping a subtree, but by __refusing a program__. A program whose author
-- wants @stackPin@'s promise runs this over it; a leaf added later without a
-- pin fails the check rather than quietly reaching whatever model the transport
-- happened to have. It is the same closure by a different mechanism, and the
-- mechanism is the one 'PanelEmpty' and 'ServedBy' already use.
--
-- == What it does and does not look at
--
-- Only /model/ addressees, because only a model ask can carry a @served by@ at
-- all: the same override on a tool or a person — a @running@ tool included — is
-- already refused outright by 'ServedBy', so a program that reaches this check
-- has no pinnable tool ask in it to miss.
--
-- __An alternates list counts as pinned__, and that needs no clause: pinned is
-- @isJust askModel@, and a chain names, exhaustively and in the program text,
-- every model that may answer. The guard's property — that no question reaches
-- whatever model the runner happens to be pointed at — is preserved by a chain,
-- since every alternate is itself a model name.
--
-- The traversal is @checkProgram@'s: every function body in declaration order,
-- statement by statement, and then @main@ — each statement's own asks before
-- its children, children in declared order, a panel's members left to right, a
-- revision's review before its amendment before its rest. Reading order, so the
-- ask it names is the first one an author scanning the program would reach.
--
-- __Opt-in, and it changes nothing by itself.__ It is not in 'guardCheck', it
-- fires on no corpus entry, and no existing program is affected until a caller
-- asks for it. @agentic-run --require-pinned@ is that caller.
guardUnpinnedAsk :: RawProgram -> Maybe Text
guardUnpinnedAsk prog =
  refusal
    <$> firstOf (map unpinnedFn (progFns prog) ++ [unpinnedBlock (progMain prog)])
  where
    unpinnedFn f = fmap (\i -> ("function `" <> fnName f <> "`", i)) (unpinnedBody (fnBody f))
    unpinnedBlock b = fmap (\i -> ("`main`", i)) (blockUnpinned b)

    -- Names the model, and where it is asked, because a program with six
    -- lenses has six places to look and a refusal that names none of them
    -- costs the reader the search this check was meant to save.
    refusal (whereAt, i) =
      "model `"
        <> i
        <> "` is asked in "
        <> whereAt
        <> " " <> [wft|without `served by`, and this program was checked with the pin required: every model ask must name the model that serves it. Write `ask (model "|]
        <> i
        <> [wft|" `servedBy` "…") …`, or run without the requirement. Who answers is a property of the question here, so an unpinned ask is a question nobody has said who answers.|]

-- | The first unpinned model ask of an 'RawAsk', which is the whole of the
-- test: an override that is present pins, and an addressee that is not a model
-- cannot be pinned and is not asked to be.
askUnpinned :: RawAsk -> Maybe Text
askUnpinned (RawAsk override (RawTarget adr _) _ _) = case (override, adr) of
  (Nothing, AddrModel i) -> Just i
  _ -> Nothing

-- | 'rhsGuard'\'s traversal, at this test.
rhsUnpinned :: RawRhs -> Maybe Text
rhsUnpinned (RhsAsk a) = askUnpinned a
rhsUnpinned (RhsPanel ms _) = firstOf (map askUnpinned ms)
rhsUnpinned (RhsPanelText ms _) = firstOf (map (askUnpinned . tmAsk) ms)
-- A decider asks nobody, so there is no question here to leave unpinned.
rhsUnpinned RhsDecide {} = Nothing
rhsUnpinned RhsCall {} = Nothing

-- | 'bodyGuard'\'s traversal, at this test.
unpinnedBody :: [RawBodyStmt] -> Maybe Text
unpinnedBody = firstOf . map stmt
  where
    stmt (BodyBind _ _ r _) = rhsUnpinned r
    stmt (BodyAct a _) = askUnpinned a
    stmt BodyCallS {} = Nothing

-- | 'blockGuard'\'s traversal, at this test.
blockUnpinned :: Raw -> Maybe Text
blockUnpinned (RawEmpty _) = Nothing
blockUnpinned (RawAnswer _ _) = Nothing
blockUnpinned (RawKnownHere _ rest _) = blockUnpinned rest
blockUnpinned (RawAct a rest _) = askUnpinned a <|> blockUnpinned rest
blockUnpinned (RawCallStmt _ _ rest _) = blockUnpinned rest
blockUnpinned (RawBind _ _ (SrcRhs r) rest _) = rhsUnpinned r <|> blockUnpinned rest
blockUnpinned (RawBind _ _ (SrcRevising _ _ _ _ _ rev am _) rest _) =
  rhsUnpinned rev <|> rhsUnpinned am <|> blockUnpinned rest
blockUnpinned (RawBind _ _ (SrcRevisingOn _ _ _ _ _ rev am _) rest _) =
  rhsUnpinned rev <|> rhsUnpinned am <|> blockUnpinned rest
blockUnpinned (RawIfFlag _ y n _) = blockUnpinned y <|> blockUnpinned n
blockUnpinned (RawCaseVerdict _ a o d _) =
  blockUnpinned a <|> blockUnpinned o <|> blockUnpinned d
blockUnpinned (RawCaseResult _ _ _ st un _) = blockUnpinned st <|> blockUnpinned un
blockUnpinned (RawCaseEnding _ _ _ _ st un ab _) =
  blockUnpinned st <|> blockUnpinned un <|> blockUnpinned ab
