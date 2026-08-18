-- |
-- Module      : Agentic.Guards
--
-- The five term-level guards and the two ask counts, ported from
-- @\/Users\/johnw\/src\/agent-cat\/Agentic\/Core\/Dsl\/Check.lean@, which is
-- the source of record for both.
--
-- Two things live here and nothing else:
--
-- * 'guardCheck' — which of the five guards Lean's @checkProgram@ fires
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
-- * the five guard vectors get their guard, one entry per guard:
--   @vector-000@ 'DupFunction', @vector-003@ 'QuestionBudget' with
--   @n = 8193@, @vector-004@ 'PanelEmpty', @vector-005@ 'ServedBy',
--   @battery-110@ 'RevisionBound';
-- * every @checked@ entry gets 'Nothing' — a false positive there is a bug;
-- * entries refused @other@ are unconstrained, and tier0 does not look.
--
-- The algorithm below was checked mechanically against all 121 corpus entries:
-- 5\/5 guard vectors, 59\/59 checked entries 'Nothing' with matching counts,
-- and — a bonus, not a contract — 'Nothing' on all 35 @other@ entries too.
module Agentic.Guards
  ( Guard (..)
  , guardCheck
  , askCounts
  ) where

import Control.Applicative ((<|>))
import Data.Maybe (fromMaybe)
import Data.Text (Text)

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
  )

-- * The constants

-- | @Check.lean:519@. The comparison is @maxRevisions < n@, so the bound is
-- inclusive: @n = 64@ is accepted and @n = 65@ refused.
maxRevisions :: Integer
maxRevisions = 64

-- | @Check.lean:874@. Likewise @maxQuestions < n@: @4096@ accepted, @4097@
-- refused.
maxQuestions :: Integer
maxQuestions = 4096

-- * The guards

-- | The five term-level guards, in the spelling of the oracle's classifier
-- (@Conformance.lean@'s @classify@). The oracle's sixth tag, @other@, is
-- everything the typing judgment refuses and is not represented here — this
-- module answers 'Nothing' for it.
data Guard
  = -- | @"a panel needs at least one member"@
    PanelEmpty
  | -- | @"at most 64 amendments"@
    RevisionBound
  | -- | @"… elaborates to n questions …"@; carries that @n@
    QuestionBudget
  | -- | @"`served by` names the model …"@
    ServedBy
  | -- | @"two functions answer to one name"@
    DupFunction
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
    RawCaseResult _ _ st un _ ->
      loop + (n + 1) * (blockAsks fns st + blockAsks fns un)
    _ -> loop + blockAsks fns rest
  where
    loop = (n + 1) * rhsAsks fns rev + n * rhsAsks fns am
blockAsks fns (RawIfFlag _ y n _) = blockAsks fns y + blockAsks fns n
blockAsks fns (RawCaseVerdict _ a o d _) =
  blockAsks fns a + blockAsks fns o + blockAsks fns d
blockAsks fns (RawCaseResult _ _ st un _) = blockAsks fns st + blockAsks fns un

-- | @(blockAsks of main under the priced table, the table in declaration
-- order)@ — exactly the corpus reply's @blockAsks@ and @fnAsks@.
askCounts :: RawProgram -> (Integer, [(Text, Integer)])
askCounts prog = (blockAsks table (progMain prog), table)
  where
    table = fnTable (progFns prog)

-- * The two traversal guards

-- | @askGuard@ (@Check.lean:320@): a @served by@ override names the model that
-- serves a /model/ addressee, so it fires exactly when the override is present
-- and the addressee is a tool or a person.
askGuard :: RawAsk -> Maybe Refusal
askGuard (RawAsk (Just _) (RawTarget adr _) _ _) =
  case adr of
    AddrModel _ -> Nothing
    _ -> Just (ServedBy, Nothing)
askGuard _ = Nothing

-- | @rhsPlan@ (@Check.lean:435@). The emptiness test precedes the kind test,
-- so an empty panel bound at @text@ still refuses 'PanelEmpty'; a /non-empty/
-- panel bound at @text@ refuses @other@, which is not ours to report. Members
-- are then checked left to right (@checkMembers@). A call raises neither
-- guard.
rhsGuard :: RawRhs -> Maybe Refusal
rhsGuard (RhsAsk a) = askGuard a
rhsGuard (RhsPanel [] _) = Just (PanelEmpty, Nothing)
rhsGuard (RhsPanel ms _) = firstOf (map askGuard ms)
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
blockGuard (RawIfFlag _ y n _) = blockGuard y <|> blockGuard n
blockGuard (RawCaseVerdict _ a o d _) = blockGuard a <|> blockGuard o <|> blockGuard d
blockGuard (RawCaseResult _ _ st un _) = blockGuard st <|> blockGuard un

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
overRevised (RawIfFlag _ y n _) = overRevised y <|> overRevised n
overRevised (RawCaseVerdict _ a o d _) = overRevised a <|> overRevised o <|> overRevised d
overRevised (RawCaseResult _ _ s u _) = overRevised s <|> overRevised u

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
firstOf :: [Maybe Refusal] -> Maybe Refusal
firstOf = foldr (<|>) Nothing
