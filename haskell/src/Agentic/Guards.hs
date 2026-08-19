{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Agentic.Guards
--
-- The six term-level guards and the two ask counts, ported from
-- @\/Users\/johnw\/src\/agent-cat\/Agentic\/Core\/Dsl\/Check.lean@, which is
-- the source of record for both.
--
-- Two things live here and nothing else:
--
-- * 'guardCheck' — which of the six guards Lean's @checkProgram@ fires
--   /first/, and the count carried by a budget refusal.
-- * 'askCounts' — @blockAsks@ of @main@ under the priced function table,
--   together with that table.
--
-- The typing judgment is deliberately /not/ ported. Guards fire during Lean's
-- typed traversal, so a program that is ill-typed earlier in traversal order
-- refuses as @other@ before a guard is reached, and without the judgment this
-- module cannot tell which came first. The whole contract this module is held
-- to — and all that tier0 enforces — is therefore:
--
-- * the guard vectors get their guard, one entry per guard:
--   @vector-000@ 'DupFunction', @vector-003@ 'QuestionBudget' with
--   @n = 8193@, @vector-004@ 'PanelEmpty', @vector-005@ 'ServedBy',
--   @battery-110@ 'RevisionBound', @battery-212@\/@battery-213@
--   'DeciderEmpty', @battery-202@ 'PanelEmpty' at a /text/ panel;
-- * every @checked@ entry gets 'Nothing' — a false positive there is a bug;
-- * entries refused @other@ are unconstrained, and tier0 does not look.
--
-- The algorithm below is checked mechanically against every corpus entry by
-- @ci\/tier0.sh@ — each guard vector gets its guard, every checked entry gets
-- 'Nothing' with matching counts, and — a bonus, not a contract — 'Nothing' on
-- the @other@ entries too.
--
-- One more guard lives here and is not one of the six: 'guardUnpinnedAsk',
-- which is __opt-in__, Haskell-side only, and part of no conformance contract.
-- It is kept in this module because this is where a refusal over the shape of a
-- program belongs, and kept out of 'guardCheck' because @checkProgram@ does not
-- fire it and a port that added a seventh guard to that answer would be a port
-- of a different checker.
module Agentic.Guards
  ( Guard (..)
  , guardCheck
  , askCounts
  , guardUnpinnedAsk
  ) where

import Control.Applicative ((<|>))
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T

import Agentic.Raw
  ( Addressee (..)
  , Raw (..)
  , RawAsk (..)
  , RawBodyStmt (..)
  , RawFn (..)
  , RawProgram (..)
  , RawRhs (..)
  , RawSource (..)
  , RawTarget (..)
  , TextMember (..)
  )

-- * The constants

-- | @Check.lean:631@. The comparison is @maxRevisions < n@, so the bound is
-- inclusive: @n = 64@ is accepted and @n = 65@ refused.
maxRevisions :: Integer
maxRevisions = 64

-- | @Check.lean:1104@. Likewise @maxQuestions < n@: @4096@ accepted, @4097@
-- refused.
maxQuestions :: Integer
maxQuestions = 4096

-- * The guards

-- | The six term-level guards, in the spelling of the oracle's classifier
-- (@Conformance.lean@'s @classify@). The oracle's seventh tag, @other@, is
-- everything the typing judgment refuses and is not represented here — this
-- module answers 'Nothing' for it.
data Guard
  = -- | @"a panel needs at least one member"@ — and, since D2,
    -- @"a text panel needs at least one member"@ too: it means \"a fan with no
    -- members\" whichever monoid the fan folds into, so it is one guard.
    PanelEmpty
  | -- | @"at most 64 amendments"@
    RevisionBound
  | -- | @"… elaborates to n questions …"@; carries that @n@
    QuestionBudget
  | -- | @"`served by` names the model …"@
    ServedBy
  | -- | @"two functions answer to one name"@
    DupFunction
  | -- | @"a decider needs …"@ — both degeneracies of a decider (D7), no needle
    -- at all and a needle that says nothing, because they are one mistake: a
    -- test that is constantly false, or constantly true, with nothing in the
    -- source to show it.
    DeciderEmpty
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | A refusal: the guard, and the question count when the guard is
-- 'QuestionBudget'. 'Nothing' for the count on every other guard, matching
-- @refusedJson@'s @n@ field, which is non-null only for the two
-- @"elaborates to "@ messages.
type Refusal = (Guard, Maybe Integer)

-- * The function table

-- | The stratified table: each function's name paired with the number of
-- questions its body elaborates to, priced against the table /before/ it.
-- This is @Fns@ with everything but @name@ and @asks@ erased — the plan and
-- the signature belong to the typing judgment, which is not ported.
type Fns = [(Text, Integer)]

-- | @Fns.find?@ answers with the /first/ match, and so does 'lookup'. An
-- unknown callee costs zero questions: @Check.lean@ raises no error here,
-- because the error comes later, from the typing judgment.
callAsks :: Fns -> Text -> Integer
callAsks fns f = fromMaybe 0 (lookup f fns)

-- | @checkFnsList@'s accumulator, with the refusals dropped: each entry is
-- @bodyAsks@ of its body against the table so far, appended in declaration
-- order.
fnTable :: [RawFn] -> Fns
fnTable = go []
  where
    go acc [] = acc
    go acc (f : fs) = go (acc ++ [(fnName f, bodyAsks acc (fnBody f))]) fs

-- * The counting recurrences

-- | @rhsAsks@, verbatim. An ask is one question; a panel is one per member;
-- a call is the callee's priced asks, and its /arguments are ignored/.
rhsAsks :: Fns -> RawRhs -> Integer
rhsAsks _ (RhsAsk _) = 1
rhsAsks _ (RhsPanel ms _) = fromIntegral (length ms)
rhsAsks _ (RhsPanelText ms _) = fromIntegral (length ms)
-- A decider asks nothing: its value is a `.ret`, and `Plan.graft_ret` leaves no
-- node at all.
rhsAsks _ (RhsDecide _ _ _ _) = 0
rhsAsks fns (RhsCall f _ _) = callAsks fns f

-- | @bodyAsks@, verbatim. @callS@ is priced as @rhsAsks fns (.call f [] ⟨0,0⟩)@
-- — the arguments are literally discarded, so this is just 'callAsks'.
bodyAsks :: Fns -> [RawBodyStmt] -> Integer
bodyAsks _ [] = 0
bodyAsks fns (BodyBind _ _ r _ : rest) = rhsAsks fns r + bodyAsks fns rest
bodyAsks fns (BodyAct _ _ : rest) = 1 + bodyAsks fns rest
bodyAsks fns (BodyCallS f _ _ : rest) = callAsks fns f + bodyAsks fns rest

-- | @blockAsks@, verbatim — the size of the /elaborated/ term, computed over
-- the raw syntax.
--
-- Two facts carry the whole clause:
--
-- * A @revising@ bounded at @n@ runs its review @n+1@ times (once before any
--   amendment) and its amend @n@ times.
-- * When the very next statement is the consuming @caseResult@, that
--   @caseResult@'s two arms are replicated @n+1@ times, because the graft's
--   continuation appears once per exit. The Lean clause for
--   @revising@-followed-by-@caseResult@ /precedes/ the general @revising@
--   clause, so the match is on the pair @(src, rest)@ — hence the inner
--   'case' below, which must stay in this order.
--
-- A @revising@ with no consuming @caseResult@ does not replicate its tail.
-- Such a program is ill-typed and refuses as @other@, but the count is still
-- defined, and 'guardCheck' may still need it to decide the budget.
blockAsks :: Fns -> Raw -> Integer
blockAsks _ (RawEmpty _) = 0
blockAsks fns (RawKnownHere _ r _) = blockAsks fns r
blockAsks fns (RawAct _ r _) = 1 + blockAsks fns r
blockAsks fns (RawCallStmt f _ r _) = callAsks fns f + blockAsks fns r
blockAsks fns (RawBind _ _ (SrcRhs rhs) r _) = rhsAsks fns rhs + blockAsks fns r
blockAsks fns (RawBind _ _ (SrcRevising _ _ n _ _ rev am _) rest _) =
  case rest of
    RawCaseResult _ _ _ st un _ ->
      loop + (n + 1) * (blockAsks fns st + blockAsks fns un)
    _ -> loop + blockAsks fns rest
  where
    loop = (n + 1) * rhsAsks fns rev + n * rhsAsks fns am
-- The three-way loop's unroll has @2n+1@ @ret@ leaves — the approve-@ret@ and
-- the declined-@ret@ per round above the base, plus the base's — and the exit is
-- replicated once per leaf. The loop's own contribution is @revising@'s.
blockAsks fns (RawBind _ _ (SrcRevisingOn _ _ n _ _ rev am _) rest _) =
  case rest of
    RawCaseEnding _ _ _ _ st un ab _ ->
      loop + (2 * n + 1) * (blockAsks fns st + blockAsks fns un + blockAsks fns ab)
    _ -> loop + blockAsks fns rest
  where
    loop = (n + 1) * rhsAsks fns rev + n * rhsAsks fns am
blockAsks fns (RawIfFlag _ y n _) = blockAsks fns y + blockAsks fns n
blockAsks fns (RawCaseVerdict _ a o d _) =
  blockAsks fns a + blockAsks fns o + blockAsks fns d
blockAsks fns (RawCaseResult _ _ _ st un _) = blockAsks fns st + blockAsks fns un
blockAsks fns (RawCaseEnding _ _ _ _ st un ab _) =
  blockAsks fns st + blockAsks fns un + blockAsks fns ab

-- | @(blockAsks of main under the priced table, the table in declaration
-- order)@ — exactly the corpus reply's @blockAsks@ and @fnAsks@.
askCounts :: RawProgram -> (Integer, [(Text, Integer)])
askCounts prog = (blockAsks table (progMain prog), table)
  where
    table = fnTable (progFns prog)

-- * The two traversal guards

-- | @askGuard@ (@Check.lean:340@): a @served by@ override names the model that
-- serves a /model/ addressee, so it fires exactly when the override is present
-- and the addressee is a tool or a person.
askGuard :: RawAsk -> Maybe Refusal
askGuard (RawAsk (Just _) (RawTarget adr _) _ _) =
  case adr of
    AddrModel _ -> Nothing
    _ -> Just (ServedBy, Nothing)
askGuard _ = Nothing

-- | @rhsPlan@ (@Check.lean:478@). The emptiness test precedes the kind test,
-- so an empty panel bound at @text@ still refuses 'PanelEmpty'; a /non-empty/
-- panel bound at @text@ refuses @other@, which is not ours to report. Members
-- are then checked left to right (@checkMembers@). A call raises neither
-- guard.
--
-- The two D2\/D7 clauses follow the same rule. An empty @panelText@ is
-- 'PanelEmpty' — the oracle's @classify@ maps @"a text panel needs at least one
-- member"@ there, because it is a fan with no members whichever monoid it folds
-- into — and a degenerate decider is 'DeciderEmpty', which @rhsPlan@ refuses
-- before it elaborates anything, so it precedes the kind test exactly as the
-- empty panel does. A @panelText@'s /label/ refusals (an invalid character, two
-- members answering to one name) are @CheckError@s and classify as @other@,
-- which is not ours to report.
rhsGuard :: RawRhs -> Maybe Refusal
rhsGuard (RhsAsk a) = askGuard a
rhsGuard (RhsPanel [] _) = Just (PanelEmpty, Nothing)
rhsGuard (RhsPanel ms _) = firstOf (map askGuard ms)
rhsGuard (RhsPanelText [] _) = Just (PanelEmpty, Nothing)
rhsGuard (RhsPanelText ms _) = firstOf (map (askGuard . tmAsk) ms)
rhsGuard (RhsDecide _ _ ws _)
  | null ws || any T.null ws = Just (DeciderEmpty, Nothing)
  | otherwise = Nothing
rhsGuard RhsCall {} = Nothing

-- | @checkBody@: statement by statement, each statement's own guards before
-- the rest of the body.
bodyGuard :: [RawBodyStmt] -> Maybe Refusal
bodyGuard = firstOf . map stmt
  where
    stmt (BodyBind _ _ r _) = rhsGuard r
    stmt (BodyAct a _) = askGuard a
    stmt BodyCallS {} = Nothing

-- | @checkBlock@: each statement's own guards before its children, children in
-- declared order. A @callStmt@'s arguments raise no guard, so only its @rest@
-- is scanned; a @revising@ scans @review@, then @amend@, then @rest@.
blockGuard :: Raw -> Maybe Refusal
blockGuard (RawEmpty _) = Nothing
blockGuard (RawKnownHere _ rest _) = blockGuard rest
blockGuard (RawAct a rest _) = askGuard a <|> blockGuard rest
blockGuard (RawCallStmt _ _ rest _) = blockGuard rest
blockGuard (RawBind _ _ (SrcRhs r) rest _) = rhsGuard r <|> blockGuard rest
blockGuard (RawBind _ _ (SrcRevising _ _ _ _ _ rev am _) rest _) =
  rhsGuard rev <|> rhsGuard am <|> blockGuard rest
blockGuard (RawBind _ _ (SrcRevisingOn _ _ _ _ _ rev am _) rest _) =
  rhsGuard rev <|> rhsGuard am <|> blockGuard rest
blockGuard (RawIfFlag _ y n _) = blockGuard y <|> blockGuard n
blockGuard (RawCaseVerdict _ a o d _) = blockGuard a <|> blockGuard o <|> blockGuard d
blockGuard (RawCaseResult _ _ _ st un _) = blockGuard st <|> blockGuard un
blockGuard (RawCaseEnding _ _ _ _ st un ab _) =
  blockGuard st <|> blockGuard un <|> blockGuard ab

-- * The revision pre-pass

-- | @overRevised@, verbatim: the first @revising@ bound over 'maxRevisions' in
-- reading order over the raw @main@ block. Lean returns the position too; only
-- the firing matters here, since @pos@ is oracle-only.
--
-- It does not descend into function bodies, and cannot need to: a
-- 'RawBodyStmt' binding takes a 'RawRhs', so a @revising@ is unwritable there.
overRevised :: Raw -> Maybe Integer
overRevised (RawEmpty _) = Nothing
overRevised (RawKnownHere _ r _) = overRevised r
overRevised (RawAct _ r _) = overRevised r
overRevised (RawCallStmt _ _ r _) = overRevised r
overRevised (RawBind _ _ (SrcRhs _) r _) = overRevised r
overRevised (RawBind _ _ (SrcRevising _ _ n _ _ _ _ _) r _)
  | maxRevisions < n = Just n
  | otherwise = overRevised r
-- A `revising on` is a bounded revision too: it is refused above `maxRevisions`
-- by the same pre-scan and printed by the same report.
overRevised (RawBind _ _ (SrcRevisingOn _ _ n _ _ _ _ _) r _)
  | maxRevisions < n = Just n
  | otherwise = overRevised r
overRevised (RawIfFlag _ y n _) = overRevised y <|> overRevised n
overRevised (RawCaseVerdict _ a o d _) = overRevised a <|> overRevised o <|> overRevised d
overRevised (RawCaseResult _ _ _ s u _) = overRevised s <|> overRevised u
overRevised (RawCaseEnding _ _ _ _ s u a _) =
  overRevised s <|> overRevised u <|> overRevised a

-- * The entry point

-- | The first guard @checkProgram@ fires, in @checkProgram@'s own order.
--
-- The order is not the intuitive one, and three things about it are easy to
-- get backwards:
--
-- 1. /The whole function table is processed before anything in @main@./
--    @checkFnsList@ calls @checkFn@ on each entry as it goes, so a
--    'PanelEmpty' or a 'ServedBy' inside a function /body/ fires ahead of
--    every guard reachable from @main@. The loop is also per function, not per
--    phase: for @fns = [f0, f1]@, @f0@'s dup check, @f0@'s budget check and
--    @f0@'s body are all done before @f1@'s dup check — so a program whose
--    @f0@ body holds an empty panel and whose @f1@ duplicates @f0@'s name
--    refuses 'PanelEmpty', not 'DupFunction'.
--
-- 2. /'RevisionBound' is not a traversal guard./ It is @overRevised@, a
--    separate pre-pass over the raw @main@ run after the table and before both
--    the program budget and @checkBlock@. It therefore beats 'PanelEmpty' and
--    'ServedBy' in @main@ whatever their relative source positions.
--    (@checkBlock@ carries a second, byte-identical @maxRevisions@ refusal at
--    @Check.lean:614@ for hand-built entry points; @overRevised@ pre-empts it
--    on every path through @checkProgram@, so it is not ported.)
--
-- 3. /The program-level budget fires before the block traversal./ An
--    over-budget program refuses 'QuestionBudget' even when its @main@ also
--    holds an empty panel.
--
-- In full:
--
-- > for each f in prog.fns, in declaration order:
-- >     1. name already in the table       -> DupFunction
-- >     2. bodyAsks(table, f.body) > 4096  -> QuestionBudget (that n)
-- >     3. scan f.body, statement order    -> PanelEmpty / ServedBy
-- >     4. push (f.name, bodyAsks(table, f.body))
-- > then:
-- >     5. overRevised(main), reading order -> RevisionBound
-- >     6. blockAsks(table, main) > 4096    -> QuestionBudget (that n)
-- >     7. scan main, traversal order       -> PanelEmpty / ServedBy
-- > otherwise Nothing.
guardCheck :: RawProgram -> Maybe Refusal
guardCheck prog = fnPass [] (progFns prog)
  where
    fnPass :: Fns -> [RawFn] -> Maybe Refusal
    fnPass table [] = mainPass table
    fnPass table (f : fs)
      | any ((== fnName f) . fst) table = Just (DupFunction, Nothing)
      | maxQuestions < n = Just (QuestionBudget, Just n)
      | Just g <- bodyGuard (fnBody f) = Just g
      | otherwise = fnPass (table ++ [(fnName f, n)]) fs
      where
        n = bodyAsks table (fnBody f)

    mainPass :: Fns -> Maybe Refusal
    mainPass table
      | Just _ <- overRevised main = Just (RevisionBound, Nothing)
      | maxQuestions < n = Just (QuestionBudget, Just n)
      | otherwise = blockGuard main
      where
        main = progMain prog
        n = blockAsks table main

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
        <> " without `served by`, and this program was checked with the pin \
           \required: every model ask must name the model that serves it. \
           \Write `ask (model \""
        <> i
        <> "\" `servedBy` \"…\") …`, or run without the requirement. Who \
           \answers is a property of the question here, so an unpinned ask is \
           \a question nobody has said who answers."

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
