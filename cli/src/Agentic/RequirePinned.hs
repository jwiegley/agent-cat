{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}

-- | CLI policies for symbolic model-pin coverage.
module Agentic.RequirePinned (guardFullPinCoverage, guardUnpinnedAsk) where

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
guardUnpinnedAsk prog = refusal <$> firstAsk askUnpinned prog
  where
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

-- | Refuse routing-only execution unless every engine-bound question carries a
-- model pin. Program-authored commands are already answered by the executing
-- layer and therefore need no backend route.
guardFullPinCoverage :: RawProgram -> Maybe Text
guardFullPinCoverage prog = refusal <$> firstAsk coverageGap prog
  where
    refusal (whereAt, gap) =
      "routing without --engine or --session requires full pin coverage, but "
        <> gap
        <> " in "
        <> whereAt
        <> ". Give every model ask a `served by` pin; a tool or person question requires --engine or --session."

-- | The first unpinned model ask of a 'RawAsk'.
askUnpinned :: RawAsk -> Maybe Text
askUnpinned (RawAsk override (RawTarget adr _) _ _) = case (override, adr) of
  (Nothing, AddrModel i) -> Just i
  _ -> Nothing

coverageGap :: RawAsk -> Maybe Text
coverageGap (RawAsk override (RawTarget adr _) _ _) = case (override, adr) of
  (Nothing, AddrModel i) -> Just ("model `" <> i <> "` is asked without `served by`")
  (_, AddrTool i) -> Just ("tool `" <> i <> "` cannot carry `served by`")
  (_, AddrPerson i) -> Just ("person `" <> i <> "` cannot carry `served by`")
  (_, AddrToolExec {}) -> Nothing
  _ -> Nothing

-- | Traverse asks in source reading order, returning their enclosing function
-- or main block with the first match.
firstAsk :: (RawAsk -> Maybe a) -> RawProgram -> Maybe (Text, a)
firstAsk match prog = firstOf (map matchingFn (progFns prog) ++ [matchingMain])
  where
    matchingFn f = fmap (\gap -> ("function `" <> fnName f <> "`", gap)) (matchingBody (fnBody f))
    matchingMain = fmap (\gap -> ("`main`", gap)) (matchingRaw (progMain prog))

    matchingRhs (RhsAsk ask') = match ask'
    matchingRhs (RhsPanel members _) = firstOf (map match members)
    matchingRhs (RhsPanelText members _) = firstOf (map (match . tmAsk) members)
    matchingRhs RhsDecide {} = Nothing
    matchingRhs RhsCall {} = Nothing

    matchingBody = firstOf . map matchingStatement
    matchingStatement (BodyBind _ _ rhs _) = matchingRhs rhs
    matchingStatement (BodyAct ask' _) = match ask'
    matchingStatement BodyCallS {} = Nothing

    matchingRaw (RawEmpty _) = Nothing
    matchingRaw (RawAnswer _ _) = Nothing
    matchingRaw (RawKnownHere _ rest _) = matchingRaw rest
    matchingRaw (RawAct ask' rest _) = match ask' <|> matchingRaw rest
    matchingRaw (RawCallStmt _ _ rest _) = matchingRaw rest
    matchingRaw (RawBind _ _ (SrcRhs rhs) rest _) = matchingRhs rhs <|> matchingRaw rest
    matchingRaw (RawBind _ _ (SrcRevising _ _ _ _ _ review amend _) rest _) =
      matchingRhs review <|> matchingRhs amend <|> matchingRaw rest
    matchingRaw (RawBind _ _ (SrcRevisingOn _ _ _ _ _ review amend _) rest _) =
      matchingRhs review <|> matchingRhs amend <|> matchingRaw rest
    matchingRaw (RawIfFlag _ yes no _) = matchingRaw yes <|> matchingRaw no
    matchingRaw (RawCaseVerdict _ accept object defer _) =
      matchingRaw accept <|> matchingRaw object <|> matchingRaw defer
    matchingRaw (RawCaseResult _ _ _ success unsuccessful _) = matchingRaw success <|> matchingRaw unsuccessful
    matchingRaw (RawCaseEnding _ _ _ _ success unsuccessful abandoned _) =
      matchingRaw success <|> matchingRaw unsuccessful <|> matchingRaw abandoned
