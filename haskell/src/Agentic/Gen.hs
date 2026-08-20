{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

-- |
-- Module      : Agentic.Gen
-- Description : QuickCheck generators for the live bisimulation.
--
-- Three generators and a self-test, per @connection.md@ §3.4:
--
-- * 'genCase' — generator __(b)__, the primary one. A well-formed program built
--   through "Agentic.Builder", so it comes with /both/ halves of the property:
--   a printed 'Agentic.Raw.RawProgram' for the oracle and a native
--   'Agentic.Plan.Plan' for the Haskell side. This is the only generator that
--   can drive the whole observation record — traces, bills, @costSummary@.
--
-- * 'genRawProgram' — generator __(a)__, the refusal path. A backwards,
--   constructive generator biased to shapes that trip the five term-level
--   guards. Its comparands are the refusal identity and the Raw-level ask
--   counts, and nothing else: a randomly generated 'Agentic.Raw.RawProgram'
--   has no Haskell 'Agentic.Plan.Plan'.
--
-- * 'genTrapText' — inputs for the D12 string-layer request, biased to the
--   traps that separate Lean's ASCII-only character predicates from Haskell's
--   Unicode-aware ones.
--
-- * 'selfTest' — Cardano's @generatesWithin@ precedent, made concrete: the
--   generators are run under a wall-clock budget and their output is forced. A
--   backwards generator over a language with calls and bounded revisions can
--   blow up; a red test beats a hung CI job.
--
-- == How a runtime generator drives a type-level-name-directed builder
--
-- "Agentic.Builder"\'s /binders/ are directed by 'GHC.TypeLits.Symbol'
-- literals, so nothing here can call @bind \@"x"@: a name drawn at runtime is
-- not a 'GHC.TypeLits.Symbol', and 'Fresh' cannot be discharged for one that
-- is. The generators drive the builder's @I@-suffixed /index-level/ entry
-- points instead — 'bindI', 'holeI', 'revisingCaseI' and the rest — which take
-- the printed 'Data.Text.Text' and the de Bruijn 'Var' directly, rather than a
-- handle at a scope the type level has to line up. Those are the builder's own definitions
-- (the named forms are wrappers over them), so this module tests the builder's
-- print-and-elaborate linkage and not a parallel one.
--
-- What the index level gives up, this module owes back by construction:
--
-- [Freshness] every binder along a path is named for the length of the scope it
--   is pushed onto, from a per-role letter — @x@ for a binding, @c@ for a
--   carrier, @v@ for a review, @z@ for a settled binder, @r@ for a loop result,
--   @p@ for a parameter — so two live names can never collide.
--
-- [@known here@] 'knownHereI' is handed 'liveNames' of the very scope the
--   block sits in, innermost first, which is what Lean compares against.
--
-- [Kind inference] Lean's @bindKind@ takes an unannotated binding's kind from
--   its /first ground use/. Rather than port that scan, the generators annotate
--   every ask-binding except in three shapes where the very next statement
--   grounds the kind unambiguously — a hole in the following act (@text@), an
--   immediate @if@ (@flag@), an immediate @case@ (@verdict@) — and in the two
--   shapes whose kind is positional and never inferred at all, a panel
--   (@verdict@) and a call (its declared result).
module Agentic.Gen
  ( -- * The primary generator
    GenCase (..),
    genCase,
    shrinkGenCase,

    -- * The refusal-path generator
    genRawProgram,
    shrinkRawProgram,

    -- * Worlds
    genWorldSpec,
    genWorldSpecFor,
    programFragments,

    -- * The string layer
    genTrapText,

    -- * The generator's own test
    selfTest,
    planSizeAtMost,
  )
where

import Agentic.Builder
  ( Arg,
    Args (ACons, ANil),
    Ask,
    Blk,
    Body,
    Code (..),
    Codes,
    Fn,
    ParamCtx,
    Params,
    Piece,
    Program (..),
    Rhs,
    Scope,
    SomeFn (SomeFn),
    Words,
    act,
    actB,
    answerBI,
    argNameI,
    argWords,
    askModel,
    askModelFallingBack,
    askModelServed,
    askPerson,
    askTool,
    askToolRunning,
    bindAsBI,
    bindAsI,
    bindI,
    callSB,
    callStmt,
    callV,
    caseVerdictI,
    decideI,
    draw,
    endB,
    function,
    holeI,
    ifFlagI,
    knownHereI,
    lit,
    noParams,
    one,
    panel,
    panelText,
    param,
    program,
    revisingCaseI,
    revisingOnCaseI,
    stop,
  )
import Agentic.Guards (askCounts)
import Agentic.Plan
  ( KnownCode,
    Plan (PAsk, PAskC, PCase, PDyn, PRet),
    SCode (SAck, SFlag, SText, SVerdict),
    Var (VHere, VThere),
    tagValues,
  )
import Agentic.Raw
  ( Addressee (AddrModel, AddrPerson, AddrTool, AddrToolExec),
    Chunk (Interp, Lit),
    Pos (Pos),
    Prompt,
    Raw (..),
    RawArg (ArgLit, ArgName),
    RawAsk (RawAsk),
    RawBodyStmt (BodyAct, BodyBind, BodyCallS),
    RawFn (..),
    RawProgram (..),
    RawRhs (RhsAsk, RhsCall, RhsDecide, RhsPanel, RhsPanelText),
    Served (Served),
    TextMember (TextMember),
    servedBy1,
    RawSource (SrcRevising, SrcRevisingOn, SrcRhs),
    RawTarget (RawTarget),
  )
import Agentic.World
  ( FlagSpec (FByPrefix, FConst, FPromptEq),
    TextSpec (TByDraw, TByPrefix, TConst, TEcho, TWrap),
    VLit (VLitApprove, VLitDeclined, VLitObject),
    VerdictSpec (VByPrefix, VConst),
    WorldSpec (WorldSpec),
    toWorld,
    trace,
  )
import Control.Exception (evaluate)
import Control.Monad (replicateM)
import Data.Aeson (encode, toJSON)
import qualified Data.ByteString.Lazy as LBS
import Data.List (nub)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NE
import Data.Text (Text)
import qualified Data.Text as T
import Data.Type.Equality ((:~:) (Refl))
import System.Timeout (timeout)
import Test.QuickCheck (Gen, choose, elements, frequency, generate, vectorOf)

-- ---------------------------------------------------------------------------
-- Codes, at the value level
-- ---------------------------------------------------------------------------

-- | Run a continuation at the promoted code a runtime 'Code' names, with the
-- singleton /and/ its 'KnownCode' instance both in hand. This is the one place
-- a runtime choice of answer kind crosses into the type level.
withCode :: Code -> (forall c. KnownCode c => SCode c -> r) -> r
withCode CodeText k = k SText
withCode CodeVerdict k = k SVerdict
withCode CodeFlag k = k SFlag
withCode CodeAck k = k SAck

-- | Decidable equality of promoted codes. 'Agentic.Plan.El' is not injective,
-- so this is how an argument or a hole is matched to the kind its position
-- demands.
eqCode :: SCode c -> SCode d -> Maybe (c :~: d)
eqCode SText SText = Just Refl
eqCode SVerdict SVerdict = Just Refl
eqCode SFlag SFlag = Just Refl
eqCode SAck SAck = Just Refl
eqCode _ _ = Nothing

-- | The three kinds a generated binding may take. @receipt@ is deliberately
-- absent: a receipt has no text of its own, nothing branches on one, and a
-- @-> receipt@ function's answer "has nowhere to go" (@Check.lean:780@), so a
-- binding at @ack@ is a shape the language admits and no honest program writes.
bindableCodes :: [Code]
bindableCodes = [CodeText, CodeVerdict, CodeFlag]

-- ---------------------------------------------------------------------------
-- The generator's runtime scope
-- ---------------------------------------------------------------------------

-- | One live name, at a scope the type records: what the printer writes, the
-- kind it answers, and the de Bruijn index that reads it.
--
-- This is exactly what @Agentic.Builder@\'s binders hand out at runtime — a
-- 'Agentic.Builder.V' carries the first and the third components, and
-- 'Agentic.Builder.readV' is the walk that keeps the third current.
data Bound (s :: Scope) where
  Bound :: KnownCode c => Text -> SCode c -> Var (Codes s) c -> Bound s

-- | The live names of a scope, __innermost first__ — the order @known here@
-- asserts and the order 'Agentic.Builder.scopeNames' computes.
type Live s = [Bound s]

boundName :: Bound s -> Text
boundName (Bound x _ _) = x

liveNames :: Live s -> [Text]
liveNames = map boundName

-- | Read a live name under one more binding: the 'VThere' that
-- 'Agentic.Builder.readV'\'s instance walk inserts, one per entry stepped
-- over.
wkBound :: forall n c s. Bound s -> Bound ('(n, c) ': s)
wkBound (Bound y d v) = Bound y d (VThere v)

-- | Push a binding, innermost. The scope entry's name is a free type variable —
-- an index-level scope carries its names in the 'Live' list, not in the type.
pushLive :: forall n c s. KnownCode c => Text -> SCode c -> Live s -> Live ('(n, c) ': s)
pushLive x c ns = Bound x c VHere : map wkBound ns

-- | The name a new binding of role @role@ takes at this scope. Scope length
-- strictly increases along a path and each role has its own letter, so no two
-- live names — and no loop result, which is checked for freshness too —
-- can ever collide.
freshFor :: Text -> Live s -> Text
freshFor role ns = role <> T.pack (show (length ns))

-- ---------------------------------------------------------------------------
-- Functions, with their arity and result kind kept
-- ---------------------------------------------------------------------------

-- | A parameter list's kinds, kept at the value level so a call site can build
-- the 'Args' its callee demands. @Agentic.Builder.SomeFn@ forgets these, which
-- is right for the printed table and useless for generating calls.
data PList (ps :: [Code]) where
  PLNil :: PList '[]
  PLCons :: KnownCode c => SCode c -> PList cs -> PList (c ': cs)

-- | A checked function together with everything a call site needs of it.
data GFn where
  GFn :: KnownCode r => Text -> PList ps -> SCode r -> Fn ps r -> GFn

-- | A parameter list, its scope, and that scope's live names — existential in
-- both indices, with @paramCtx@\'s reversal witnessed by the equality.
data SomeParams where
  SomeParams ::
    (Codes s ~ ParamCtx ps) =>
    PList ps ->
    Params ps '[] s hs ->
    Live s ->
    SomeParams

-- | Parameters at fixed names, which is the one compromise the type level
-- forces: 'Agentic.Builder.param' takes its name as a 'GHC.TypeLits.Symbol',
-- so the pool of parameter names has to be written down. Two are enough — the
-- generator declares functions of arity 0, 1 or 2 — and @p0@\/@p1@ cannot
-- collide with a body's bindings, which are named @x@/n/.
someParams :: [Code] -> SomeParams
someParams = \case
  [] -> SomeParams PLNil noParams []
  [a] -> withCode a $ \sa ->
    SomeParams
      (PLCons sa PLNil)
      (param @"p0" noParams)
      [Bound "p0" sa VHere]
  (a : b : _) -> withCode a $ \sa -> withCode b $ \sb ->
    SomeParams
      (PLCons sa (PLCons sb PLNil))
      (param @"p0" (param @"p1" noParams))
      [Bound "p1" sb VHere, Bound "p0" sa (VThere VHere)]

-- ---------------------------------------------------------------------------
-- The words of a prompt
-- ---------------------------------------------------------------------------

-- | The literal vocabulary. Small and shared with 'genWorldSpec', so a
-- @byPrefix@ table drawn from it matches a generated program often enough to
-- exercise the table and rarely enough to exercise the default.
litPool :: [Text]
litPool =
  [ "draft ",
    "review ",
    "check ",
    "apply ",
    "note: ",
    "seen: ",
    "go?",
    "one",
    "two",
    "",
    " ",
    "the release",
    "objections: ",
    "ship it",
    "gave up"
  ]

-- | A literal chunk. One in eight is a trap string, so the codec and the world
-- specs meet non-ASCII on the wire.
genLit :: Gen Text
genLit = frequency [(7, elements litPool), (1, genTrapText)]

-- | Every hole the scope admits: a @text@ answer splices itself, a @verdict@
-- splices @Verdict.render@, and a @flag@ or a @receipt@ has no text of its own
-- and is refused — here by 'Agentic.Builder.Spliceable' having no instance for
-- it, which is why the match below dispatches on the singleton.
holePieces :: forall s. Live s -> [Piece s]
holePieces = foldr (\b acc -> maybe acc (: acc) (holeOf b)) []
  where
    holeOf :: Bound s -> Maybe (Piece s)
    holeOf (Bound x c v) = case c of
      SText -> Just (holeI x v)
      SVerdict -> Just (holeI x v)
      SFlag -> Nothing
      SAck -> Nothing

genPiece :: forall s. Live s -> Gen (Piece s)
genPiece ns = case holePieces ns of
  [] -> lit <$> genLit
  hs -> frequency [(3, lit <$> genLit), (2, elements hs)]

-- | Words, zero to four pieces. The empty prompt is deliberately reachable:
-- it is closed, it prints as @[]@, and it is where @battery-137@ lives.
genWords :: forall s. Live s -> Gen (Words s)
genWords ns = do
  k <- frequency [(1, pure 0), (3, pure 1), (4, pure 2), (2, pure 3), (1, pure 4)]
  vectorOf k (genPiece ns)

-- | Words that certainly splice the innermost binding, so that the statement
-- following an unannotated binding grounds its kind at @text@ — Lean's
-- @usePrompt@ reads a hole as @text@ and nothing else.
genWordsHoling :: forall n s. Text -> Live ('(n, 'CodeText) ': s) -> Gen (Words ('(n, 'CodeText) ': s))
genWordsHoling x ns = do
  pre <- genWords ns
  post <- genWords ns
  pure (pre ++ [holeI x VHere] ++ post)

-- ---------------------------------------------------------------------------
-- Questions
-- ---------------------------------------------------------------------------

modelIds :: [Text]
modelIds = ["author", "critic", "oracle", "deep", "cheap", "m"]

toolIds :: [Text]
toolIds = ["cat", "log", "apply", "lint", "t"]

personIds :: [Text]
personIds = ["owner", "reviewer", "o"]

-- | The commands a generated @toolExec@ addressee runs (D5).
--
-- Never run by anything the bisimulation touches — the kernel executes nothing,
-- ever, because a pure @World@ dispatches on the code and never on the
-- addressee — so what these exercise is the codec, the ordering key and the
-- memo table: two commands at one tool id are two questions.
execCmds :: [Text]
execCmds = ["nix", "true", "false", "cabal", "gh"]

-- | …and the arguments beside them, including the empty argv, which is the
-- shape a bare command takes.
genExecArgs :: Gen [Text]
genExecArgs =
  frequency
    [ (2, pure []),
      (3, pure ["flake", "check"]),
      (2, pure ["build"]),
      (1, pure ["pr", "list", "--json", "number"])
    ]

-- | One question. @served by@ is offered __only__ on a model addressee, which
-- is 'Agentic.Builder.askModelServed'\'s whole point: @askGuard@\'s refusal is
-- unrepresentable rather than avoided.
genAsk :: forall s. Live s -> Gen (Ask s)
genAsk ns = do
  ws <- genWords ns
  a <-
    frequency
      [ (6, (\i -> askModel i ws) <$> elements modelIds),
        (2, (\i m -> askModelServed i m ws) <$> elements modelIds <*> elements modelIds),
        -- D6: a pin with a spare. It must reach the typed generator too, or the
        -- bisimulation never puts a chained `served by` to the oracle.
        ( 1,
          (\i m sp -> askModelFallingBack i m [sp] ws)
            <$> elements modelIds
            <*> elements modelIds
            <*> elements modelIds
        ),
        (4, (\i -> askTool i ws) <$> elements toolIds),
        -- D5: a tool the runner runs. Priced exactly as a tool, because the
        -- addressee is priced nowhere.
        ( 2,
          (\i cmd args -> askToolRunning i cmd args ws)
            <$> elements toolIds
            <*> elements execCmds
            <*> genExecArgs
        ),
        (2, (\i -> askPerson i ws) <$> elements personIds)
      ]
  d <- frequency [(6, pure 0), (2, pure 1), (1, pure 2), (1, pure 3)]
  pure (if d == (0 :: Integer) then a else draw d a)

-- ---------------------------------------------------------------------------
-- Clause-position sources
-- ---------------------------------------------------------------------------

-- | A call at a demanded kind, if any declared function answers it and its
-- arguments can be filled from this scope.
--
-- A @-> receipt@ function is excluded: binding its answer is refused by name
-- (@Check.lean:780@), and it reaches a program only through
-- 'Agentic.Builder.callStmt' and 'Agentic.Builder.callSB'.
callAlt :: forall c s. Live s -> SCode c -> GFn -> Maybe (Gen (Rhs s c))
callAlt ns c (GFn _ pl r f) = case r of
  SAck -> Nothing
  _ -> case eqCode c r of
    Nothing -> Nothing
    Just Refl -> fmap (callV f <$>) (genArgs ns pl)

-- | A statement call: a @-> receipt@ function whose arguments this scope fills.
data AckCall (s :: Scope) where
  AckCall :: Fn ps 'CodeAck -> Gen (Args s ps) -> AckCall s

ackCall :: forall s. Live s -> GFn -> Maybe (AckCall s)
ackCall ns (GFn _ pl r f) = case r of
  SAck -> AckCall f <$> genArgs ns pl
  _ -> Nothing

-- | Lean's @checkArgs@, from the generator's side: an argument per parameter,
-- in source order, or 'Nothing' where a parameter's kind has no filler in
-- scope. Only @text@ has a filler that needs no name — literal words,
-- elaborated in the /caller's/ bindings.
genArgs :: forall s ps. Live s -> PList ps -> Maybe (Gen (Args s ps))
genArgs _ PLNil = Just (pure ANil)
genArgs ns (PLCons c cs) = do
  gh <- genArg ns c
  gt <- genArgs ns cs
  pure (ACons <$> gh <*> gt)

genArg :: forall c s. Live s -> SCode c -> Maybe (Gen (Arg s c))
genArg ns c = case c of
  SText ->
    Just $
      frequency
        ( (2, argWords <$> genWords ns)
            : [(3, elements named) | not (null named)]
        )
  _ -> if null named then Nothing else Just (elements named)
  where
    named = [a | Just a <- map (argOf c) ns]

argOf :: forall c s. SCode c -> Bound s -> Maybe (Arg s c)
argOf c (Bound x d v) = case eqCode c d of
  Just Refl -> Just (argNameI x v)
  Nothing -> Nothing

-- | A source at an imposed kind: one question, a panel of one to three
-- members, or a call. A panel answers @verdict@ and nothing else, which is why
-- the alternative is inside the singleton match rather than beside it.
genRhs :: forall c s. KnownCode c => [GFn] -> Live s -> SCode c -> Gen (Rhs s c)
genRhs fns ns c = frequency (askAlt : panelAlts ++ callAlts)
  where
    askAlt = (8, one <$> genAsk ns)

    panelAlts = case c of
      SVerdict ->
        [ ( 3,
            do
              k <- choose (1 :: Int, 3)
              ms <- vectorOf k (genAsk ns)
              pure (panel (neFromList ms))
          )
        ]
      _ -> []

    callAlts = [(4, g) | Just g <- map (callAlt ns c) fns]

neFromList :: [a] -> NonEmpty a
neFromList = NE.fromList

-- ---------------------------------------------------------------------------
-- Function bodies
-- ---------------------------------------------------------------------------

-- | A body and the result kind it answers at, which is settled by the terminal
-- statement: @answer x@ answers at @x@'s kind, and a body with no @answer@ is
-- a @-> receipt@ one.
data SomeBody (s :: Scope) where
  SomeBody :: KnownCode r => SCode r -> Body s r -> SomeBody s

genBody :: forall s. [GFn] -> Int -> Live s -> Gen (SomeBody s)
genBody fns fuel ns
  | fuel <= 0 = terminal
  | otherwise = frequency ((2, terminal) : bindAlt : actAlt : callAlts)
  where
    answers = concatMap ansOf ns
    ansOf :: Bound s -> [SomeBody s]
    ansOf (Bound x c v) = case c of
      SAck -> []
      _ -> [SomeBody c (answerBI x v)]

    terminal
      | null answers = pure (SomeBody SAck endB)
      | otherwise =
          -- A `-> receipt` body is the only thing a statement call may name, so
          -- it is drawn a third of the time rather than as an afterthought.
          frequency [(2, pure (SomeBody SAck endB)), (4, elements answers)]

    actAlt =
      ( 4,
        do
          a <- genAsk ns
          SomeBody r b <- genBody fns (fuel - 1) ns
          pure (SomeBody r (actB a b))
      )

    -- Every body binding is annotated: `bodyBindKind` takes the annotation
    -- where there is one, and porting its ground-use scan buys nothing here.
    bindAlt =
      ( 6,
        do
          cd <- elements bindableCodes
          withCode cd $ \sc -> do
            rhs <- genRhs fns ns sc
            let x = freshFor "x" ns
            SomeBody r b <- genBody fns (fuel - 1) (pushLive x sc ns)
            pure (SomeBody r (bindAsBI sc x rhs b))
      )

    callAlts = concatMap alt fns
      where
        alt gf = case ackCall ns gf of
          Nothing -> []
          Just (AckCall f g) ->
            [ ( 3,
                do
                  as <- g
                  SomeBody r b <- genBody fns (fuel - 1) ns
                  pure (SomeBody r (callSB f as b))
              )
            ]

-- | One function, over the table declared before it — which is what makes the
-- table stratified and refuses recursion.
genFn :: [GFn] -> Text -> Gen GFn
genFn fns name = do
  arity <- frequency [(2, pure 0), (4, pure 1), (3, pure 2)]
  cds <- vectorOf arity (elements bindableCodes)
  case someParams cds of
    SomeParams pl ps live -> do
      fuel <- choose (1 :: Int, 4)
      SomeBody r b <- genBody fns fuel live
      pure (GFn name pl r (function name ps (const b)))

-- ---------------------------------------------------------------------------
-- Blocks
-- ---------------------------------------------------------------------------

-- | A workflow block.
--
-- @fuel@ bounds the statements on any one path and is split at every branching;
-- @rd@ bounds the nesting of bounded revisions, whose unroll replicates both
-- arms of the consuming @case@ once per exit and is the one construct here that
-- /multiplies/ rather than adds; @br@ is 'False' on the branch-free draws.
--
-- Measured over five thousand draws, 'genCase'\'s settings put the elaborated
-- term at median size 22, 90th percentile 73 and maximum 282 — the range the
-- corpus occupies, with @vector-002@\'s 92 near the middle of the tail.
genBlk :: forall s. [GFn] -> Int -> Int -> Bool -> Live s -> Gen (Blk s)
genBlk fns fuel rd br ns
  | fuel <= 0 = pure stop
  | otherwise =
      frequency
        ( stopAlt
            : actAlt
            : annotatedBindAlt
            : panelBindAlt
            : panelTextBindAlt
            : bindThenActAlt
            : knownHereAlt
            : (branchAlts ++ callAlts ++ decideAlts)
        )
  where
    -- Everything that puts a `case` node in the term. Held back on one draw in
    -- five so that `level` reaches `batch` and `pipeline` and `Cost.codes`
    -- comes back non-null — the comparand the schema calls "usually null" and
    -- which nothing else here would pin.
    branchAlts
      | br = bindThenIfAlt : bindThenCaseAlt : (flagAlts ++ verdictAlts ++ revAlts)
      | otherwise = []

    rest1 = genBlk fns (fuel - 1) rd br ns
    half = max 0 ((fuel - 1) `div` 2)
    third = max 0 ((fuel - 1) `div` 3)

    stopAlt = (1, pure stop)

    actAlt = (7, act <$> genAsk ns <*> rest1)

    knownHereAlt = (2, knownHereI (liveNames ns) <$> rest1)

    -- The safe shape: annotated, so `bindKind` never runs.
    annotatedBindAlt =
      ( 8,
        do
          cd <- elements bindableCodes
          withCode cd $ \sc -> do
            rhs <- genRhs fns ns sc
            let x = freshFor "x" ns
            rst <- genBlk fns (fuel - 1) rd br (pushLive x sc ns)
            pure (bindAsI sc x rhs rst)
      )

    -- A panel's kind is positional and never inferred, so this one carries no
    -- annotation and still cannot be got wrong.
    panelBindAlt =
      ( 4,
        do
          k <- choose (1 :: Int, 3)
          ms <- vectorOf k (genAsk ns)
          let x = freshFor "x" ns
          rst <- genBlk fns (fuel - 1) rd br (pushLive x SVerdict ns)
          pure (bindI x (panel (neFromList ms)) rst)
      )

    -- A text panel's kind is positional too (D2), and its members carry the
    -- labels the fence writes. The labels are drawn from a small pool and
    -- deduplicated, because two members answering to one name is a refusal and
    -- this generator draws only well-formed programs.
    panelTextBindAlt =
      ( 3,
        do
          k <- choose (1 :: Int, 3)
          ms <- vectorOf k (genAsk ns)
          let x = freshFor "x" ns
              labels = take k ["alpha", "beta", "gamma"]
          rst <- genBlk fns (fuel - 1) rd br (pushLive x SText ns)
          pure (bindI x (panelText (neFromList (zip labels ms))) rst)
      )

    -- A decider (D7) over a live `text` binding: no question, no node, and a
    -- flag the rest of the block may branch on. One per live text name.
    decideAlts = concatMap alt ns
      where
        alt (Bound x c v) = case c of
          SText ->
            [ ( 3,
                do
                  d <- elements [minBound .. maxBound]
                  k <- choose (1 :: Int, 2)
                  ws <- neFromList <$> vectorOf k genNeedle
                  let f = freshFor "f" ns
                  rst <- genBlk fns (fuel - 1) rd br (pushLive f SFlag ns)
                  pure (bindI f (decideI d x v ws) rst)
              )
            ]
          _ -> []

    -- Unannotated, grounded by the very next statement: a hole reads as `text`.
    bindThenActAlt =
      ( 3,
        do
          a <- genAsk ns
          let x = freshFor "x" ns
              ns' = pushLive x SText ns
          ws <- genWordsHoling x ns'
          a2 <- withWords ns' ws
          rst <- genBlk fns (max 0 (fuel - 2)) rd br ns'
          pure (bindI x (one a) (act a2 rst))
      )

    -- Unannotated, grounded by an immediate `if`.
    bindThenIfAlt =
      ( 3,
        do
          a <- genAsk ns
          let x = freshFor "x" ns
              ns' = pushLive x SFlag ns
          y <- genBlk fns half rd br ns'
          n <- genBlk fns half rd br ns'
          pure (bindI x (one a) (ifFlagI x VHere y n))
      )

    -- Unannotated, grounded by an immediate `case`.
    bindThenCaseAlt =
      ( 3,
        do
          a <- genAsk ns
          let x = freshFor "x" ns
              ns' = pushLive x SVerdict ns
          p <- genBlk fns third rd br ns'
          q <- genBlk fns third rd br ns'
          r <- genBlk fns third rd br ns'
          pure (bindI x (one a) (caseVerdictI x VHere p q r))
      )

    flagAlts = concatMap alt ns
      where
        alt (Bound x c v) = case c of
          SFlag ->
            [ ( 4,
                ifFlagI x v
                  <$> genBlk fns half rd br ns
                  <*> genBlk fns half rd br ns
              )
            ]
          _ -> []

    verdictAlts = concatMap alt ns
      where
        alt (Bound x c v) = case c of
          SVerdict ->
            [ ( 4,
                caseVerdictI x v
                  <$> genBlk fns third rd br ns
                  <*> genBlk fns third rd br ns
                  <*> genBlk fns third rd br ns
              )
            ]
          _ -> []

    callAlts = concatMap alt fns
      where
        alt gf = case ackCall ns gf of
          Nothing -> []
          Just (AckCall f g) -> [(3, callStmt f <$> g <*> rest1)]

    revAlts
      | rd <= 0 = []
      | otherwise = concatMap alt ns
      where
        alt (Bound sx sc sv) = case sc of
          SAck -> []
          _ ->
            [ ( 4,
                do
                  n <-
                    frequency
                      [(3, pure 0), (3, pure 1), (2, pure 2), (2, pure 3)]
                  rann <- frequency [(3, pure Nothing), (1, pure (Just CodeVerdict))]
                  let carrier = freshFor "c" ns
                      rname = freshFor "v" ns
                      sname = freshFor "z" ns
                      resname = freshFor "r" ns
                      nsC = pushLive carrier sc ns
                      nsR = pushLive rname SVerdict nsC
                      -- Both exits bind the candidate (D3), and the generator
                      -- passes the settled name twice — which is what the
                      -- authoring surface does and what every frozen entry
                      -- carries, so a generated program stays in the shape the
                      -- corpus is in.
                      nsS = pushLive sname sc ns
                      sub = max 0 ((fuel - 1) `div` (fromInteger n + 2))
                  review <- genRhs fns nsC SVerdict
                  amend <- genRhs fns nsR sc
                  st <- genBlk fns sub (rd - 1) br nsS
                  un <- genBlk fns sub (rd - 1) br nsS
                  pure
                    ( revisingCaseI
                        sx
                        sv
                        carrier
                        rname
                        sname
                        sname
                        resname
                        n
                        rann
                        review
                        amend
                        st
                        un
                    )
              ),
              -- The three-way loop (D4), at the same live subject. Its exit is
              -- replicated `2n+1` times rather than `n+1`, so its fuel is cut
              -- harder: a generated `revisingOn` with a deep tail is the one
              -- shape that can reach the affordability refusal by accident.
              ( 2,
                do
                  n <- frequency [(4, pure 0), (3, pure 1), (2, pure 2)]
                  rann <- frequency [(3, pure Nothing), (1, pure (Just CodeVerdict))]
                  let carrier = freshFor "c" ns
                      rname = freshFor "v" ns
                      sname = freshFor "z" ns
                      resname = freshFor "r" ns
                      nsC = pushLive carrier sc ns
                      nsR = pushLive rname SVerdict nsC
                      nsS = pushLive sname sc ns
                      sub = max 0 ((fuel - 1) `div` (2 * fromInteger n + 3))
                  review <- genRhs fns nsC SVerdict
                  amend <- genRhs fns nsR sc
                  st <- genBlk fns sub (rd - 1) br nsS
                  un <- genBlk fns sub (rd - 1) br nsS
                  ab <- genBlk fns sub (rd - 1) br nsS
                  pure
                    ( revisingOnCaseI
                        sx
                        sv
                        carrier
                        rname
                        sname
                        sname
                        sname
                        resname
                        n
                        rann
                        review
                        amend
                        st
                        un
                        ab
                    )
              )
            ]

-- | The needles a generated decider tests for.
--
-- Program text, always — that is the safety property of the whole vocabulary
-- and it is bought by the field's type — so the pool is Isaac's own markers and
-- the globs that reconstruct @diffNamesHaskell@, plus the two boundary cases
-- the string vectors pin: a needle with a trailing space (@"✗ "@, which is what
-- makes @anyLineStartsWith@ faithful to @isRed@) and a needle whose case the
-- ASCII fold moves.
genNeedle :: Gen Text
genNeedle =
  elements
    [ "WORK COMPLETE",
      "WORK REMAINS",
      "WORK BLOCKED",
      "READY",
      "FACTS PATHS UNRESOLVED",
      "\10007 ",
      "*.hs",
      "*.cabal",
      "b/src/*.hs",
      "done"
    ]

-- | An addressee for a prompt already built. Kept separate from 'genAsk'
-- because 'bindThenActAlt' needs the words fixed and the target free.
withWords :: forall s. Live s -> Words s -> Gen (Ask s)
withWords _ ws = do
  a <-
    frequency
      [ (6, (\i -> askModel i ws) <$> elements modelIds),
        (2, (\i m -> askModelServed i m ws) <$> elements modelIds <*> elements modelIds),
        -- D6: a pin with a spare. It must reach the typed generator too, or the
        -- bisimulation never puts a chained `served by` to the oracle.
        ( 1,
          (\i m sp -> askModelFallingBack i m [sp] ws)
            <$> elements modelIds
            <*> elements modelIds
            <*> elements modelIds
        ),
        (4, (\i -> askTool i ws) <$> elements toolIds),
        -- D5: a tool the runner runs. Priced exactly as a tool, because the
        -- addressee is priced nowhere.
        ( 2,
          (\i cmd args -> askToolRunning i cmd args ws)
            <$> elements toolIds
            <*> elements execCmds
            <*> genExecArgs
        ),
        (2, (\i -> askPerson i ws) <$> elements personIds)
      ]
  d <- frequency [(7, pure 0), (2, pure 1), (1, pure 2)]
  pure (if d == (0 :: Integer) then a else draw d a)

-- ---------------------------------------------------------------------------
-- The primary generator
-- ---------------------------------------------------------------------------

-- | One property case: a well-formed program, and the worlds to observe it in.
data GenCase = GenCase
  { gcProgram :: Program,
    gcWorlds :: [WorldSpec]
  }

-- | A well-formed program and its worlds.
--
-- Frequencies, and what each is for:
--
-- * __0–3 functions__ (4:3:2:1), each of arity 0–2 (2:4:3) with a body of one
--   to four statements. Declared in order, each seeing only the table before
--   it, which is Lean\'s stratification and is what refuses recursion. A body
--   ends in @answer x@ two draws in three and in a bare @-> receipt@ one draw in
--   three, because only a receipt function may stand as a statement call.
--
-- * __The block__ at revision depth 2 and fuel 5–16 (7), 16–24 (2) or 24–34
--   (1) — the deep tail is what reaches the top of the size range.
--
-- * __One draw in five is branch-free__: no @if@, no @case@, no bounded
--   revision, at fuel 2–9. Without it @level@ never leaves @branch@ and
--   @Cost.codes@ is always @null@; with it roughly a quarter of programs pin
--   their whole question sequence.
--
-- * __Statement weights__: an annotated binding 8, an act 7, a panel binding 4,
--   @known here@ 2, @stop@ 1, the three unannotated grounded shapes 3 each,
--   and — once per live name of the right kind — an @if@ 4, a @case@ 4, a
--   bounded revision 4, a statement call 3. So a program with names in scope
--   branches and revises often, and one without cannot.
--
-- * __Sources__ (8:4:3:3): a question, a panel of 1–3 members at @verdict@
--   only, a text panel of 1–3 labelled members at @text@ (D2), a call at a
--   matching result. A decider (D7) is not a source draw but a per-live-name
--   alternative, weight 3, once per live @text@ binding — it asks nothing, so
--   what it exercises is the fold that must /not/ move.
--
-- * __Questions__: model 6, model @served by@ 2, model @served by … or …@ 1
--   (D6), tool 4, tool @running@ 2 (D5), person 2; draw 0 six times in ten,
--   then 1, 2, 3.
--
-- * __Words__: 0–4 pieces (1:3:4:2:1), each a literal 3 to a hole 2, with one
--   literal in eight drawn from 'genTrapText'. Holes are text and verdict only:
--   a flag and a receipt have no text of their own.
--
-- * __Revision bounds__ 0–3 (3:3:2:2), nested at most twice; a three-way
--   @revising on@ (D4) at weight 2 against the two-way loop's 4, bounded 0–2
--   because its exit is replicated @2n+1@ times.
--
-- * __Worlds__: one to three, drawn by 'genWorldSpecFor' from the fragments the
--   program actually writes.
--
-- Two coverage facts worth having on record, both measured: every draw of four
-- hundred passes 'Agentic.Guards.guardCheck' with 'Nothing' — a generated
-- program never trips a term-level guard, which is generator (a)\'s job — and
-- the memo bill comes in strictly below the fresh bill on roughly one world in
-- seven, a case the frozen corpus contains exactly twice.
genCase :: Gen GenCase
genCase = do
  nf <- frequency [(4, pure 0), (3, pure 1), (2, pure 2), (1, pure 3)]
  fns <- genFns nf
  br <- frequency [(4, pure True), (1, pure False)]
  fuel <-
    if br
      then frequency [(7, choose (5, 16)), (2, choose (16, 24)), (1, choose (24, 34))]
      else choose (2, 9)
  blk <- genBlk fns fuel (if br then 2 else 0) br []
  let prog = program (map (\(GFn _ _ _ f) -> SomeFn f) fns) blk
      frags = programFragments (progRawOut prog)
  k <- choose (1 :: Int, 3)
  ws <- vectorOf k (genWorldSpecFor frags)
  pure (GenCase prog ws)

genFns :: Int -> Gen [GFn]
genFns n = go 0 []
  where
    go i acc
      | i >= n = pure acc
      | otherwise = do
          f <- genFn acc ("fn" <> T.pack (show i))
          go (i + 1) (acc ++ [f])

-- | Shrinking, best effort and __sound only in one direction__: a 'Program' is
-- a printed 'Agentic.Raw.RawProgram' and an elaborated
-- 'Agentic.Plan.Plan' that must stay in step, and nothing here can rebuild the
-- pair. So only the world list shrinks — which is genuinely useful, because a
-- three-world failure almost always fails in one of the three, and naming that
-- one is most of the diagnosis.
shrinkGenCase :: GenCase -> [GenCase]
shrinkGenCase (GenCase p ws)
  | length ws <= 1 = []
  | otherwise = [GenCase p [w] | w <- ws]

-- ---------------------------------------------------------------------------
-- Worlds
-- ---------------------------------------------------------------------------

-- | Every literal a program writes, with its non-empty proper prefixes: the
-- pool a @byPrefix@ key is drawn from so that a table sometimes matches.
--
-- The /evaluated/ prompt a world sees begins with the first chunk, so a key
-- that is a prefix of some literal fires exactly when that literal opens a
-- prompt — which is common enough to exercise the table and rare enough to
-- exercise the default.
programFragments :: RawProgram -> [Text]
programFragments prog =
  nub (concatMap prefixes (concatMap promptLits allPrompts))
  where
    allPrompts = concatMap fnPrompts (progFns prog) ++ blockPrompts (progMain prog)

    prefixes t = [T.take k t | k <- [1 .. T.length t]]

    promptLits :: Prompt -> [Text]
    promptLits = concatMap $ \case
      Lit t -> [t]
      Interp _ -> []

    fnPrompts f = concatMap stmtPrompts (fnBody f)

    stmtPrompts = \case
      BodyBind _ _ r _ -> rhsPrompts r
      BodyAct (RawAsk _ _ p _) _ -> [p]
      BodyCallS _ as _ -> concatMap argPrompts as

    argPrompts = \case
      ArgName _ _ -> []
      ArgLit p _ -> [p]

    rhsPrompts = \case
      RhsAsk (RawAsk _ _ p _) -> [p]
      RhsPanel ms _ -> [p | RawAsk _ _ p _ <- ms]
      RhsPanelText ms _ -> [p | TextMember _ (RawAsk _ _ p _) <- ms]
      -- A decider puts no question, so it writes no prompt.
      RhsDecide {} -> []
      RhsCall _ as _ -> concatMap argPrompts as

    blockPrompts = \case
      RawEmpty _ -> []
      RawBind _ _ src r _ -> srcPrompts src ++ blockPrompts r
      RawAct (RawAsk _ _ p _) r _ -> p : blockPrompts r
      RawIfFlag _ y n _ -> blockPrompts y ++ blockPrompts n
      RawCaseVerdict _ a o d _ -> concatMap blockPrompts [a, o, d]
      RawCaseResult _ _ _ st un _ -> blockPrompts st ++ blockPrompts un
      RawCaseEnding _ _ _ _ st un ab _ -> concatMap blockPrompts [st, un, ab]
      RawKnownHere _ r _ -> blockPrompts r
      RawCallStmt _ as r _ -> concatMap argPrompts as ++ blockPrompts r

    srcPrompts = \case
      SrcRhs r -> rhsPrompts r
      SrcRevising _ _ _ _ _ rev am _ -> rhsPrompts rev ++ rhsPrompts am
      SrcRevisingOn _ _ _ _ _ rev am _ -> rhsPrompts rev ++ rhsPrompts am

-- | A world spec whose tables are drawn from the shared literal pool, so it
-- sometimes matches whatever it is applied to. This is the bare generator the
-- bisimulation's contract names; inside 'genCase', 'genWorldSpecFor' does
-- better by using the program's own fragments.
genWorldSpec :: Gen WorldSpec
genWorldSpec = genWorldSpecFor litPool

-- | A world spec whose @byPrefix@ keys are drawn from the given fragments,
-- three in four, and from junk otherwise. All five 'TextSpec' constructors, both
-- 'VerdictSpec' ones and all three 'FlagSpec' ones are reachable.
genWorldSpecFor :: [Text] -> Gen WorldSpec
genWorldSpecFor frags =
  WorldSpec <$> genTextSpec <*> genVerdictSpec <*> genFlagSpec
  where
    key
      | null frags = elements junkKeys
      | otherwise = frequency [(3, elements frags), (1, elements junkKeys)]

    junkKeys = ["", "z", "draft ", "no-such-prefix", "İ"]

    -- First match wins over the table in order, so the order is observable and
    -- the generator must not sort.
    table :: Gen a -> Gen [(Text, a)]
    table v = do
      k <- frequency [(2, pure 0), (3, pure 1), (2, pure 2), (1, pure 3)]
      vectorOf k ((,) <$> key <*> v)

    genTextSpec =
      frequency
        [ (5, pure TEcho),
          (3, TWrap <$> elements ["<", "[", "", "«"] <*> elements [">", "]", "", "»"]),
          (2, TConst <$> genLit),
          (2, pure TByDraw),
          (3, TByPrefix <$> table genLit <*> genLit)
        ]

    genVerdictSpec =
      frequency
        [ (5, VConst <$> genVLit),
          (3, VByPrefix <$> table genVLit <*> genVLit)
        ]

    genVLit =
      frequency
        [ (4, pure VLitApprove),
          (2, pure VLitDeclined),
          (3, VLitObject <$> objections)
        ]

    objections = do
      k <- frequency [(1, pure 0), (3, pure 1), (2, pure 2)]
      vectorOf k (elements ["too long", "unclear", "missing a citation", "İ"])

    genFlagSpec =
      frequency
        [ (5, FConst <$> elements [True, False]),
          (2, FPromptEq <$> key),
          (3, FByPrefix <$> table (elements [True, False]) <*> elements [True, False])
        ]

-- ---------------------------------------------------------------------------
-- The refusal-path generator
-- ---------------------------------------------------------------------------

pos0 :: Pos
pos0 = Pos 0 0

-- | An unchecked program, biased to the shapes the six term-level guards
-- refuse.
--
-- Frequencies: an empty panel 3, a revision bound straddling 64 3, a question
-- count straddling 4096 3, @served by@ on a tool or a person 3, two functions
-- of one name 3, a program the builder itself produced 3, and free-form raw
-- syntax 4.
--
-- This is a /constructive/ generator and not a Pałka-style inversion of the
-- typing rules: the comparands on this path are the refusal identity and the
-- Raw-level ask counts (§3.5 rows 1–3), and both are decided by shape, so
-- inverting the whole judgment to reach them would buy nothing. The free-form
-- share is the part that may or may not typecheck in Lean; for it the agreement
-- being tested is "the Haskell's six guards pass" against "Lean did not refuse
-- for one of those five reasons", which is agreement about a boolean.
--
-- Measured over four hundred draws, 'Agentic.Guards.guardCheck' answers:
-- 'Agentic.Guards.PanelEmpty' 63, 'Agentic.Guards.DupFunction' 61,
-- 'Agentic.Guards.ServedBy' 42, 'Agentic.Guards.RevisionBound' 38,
-- 'Agentic.Guards.QuestionBudget' 16, and 'Nothing' 180 — the last being the
-- deliberate other side of each boundary (a bound of 64 and not 65, a count of
-- 4096 and not 4097, a @served by@ on a model), where the reply must come back
-- /checked/ with ask counts that still agree.
genRawProgram :: Gen RawProgram
genRawProgram =
  frequency
    [ (3, rawWellFormed),
      (3, rawEmptyPanel),
      (3, rawRevisionBound),
      (3, rawBudget),
      (3, rawServedBy),
      (3, rawDupFunction),
      (4, rawFreeform)
    ]

-- | A program the typed builder produced: certainly checked, so it pins the
-- refusal boolean from the other side.
rawWellFormed :: Gen RawProgram
rawWellFormed = (progRawOut . gcProgram) <$> genCase

-- | __The base a defacement is written onto is a well-formed program.__
--
-- This is the whole difference between a refusal-path generator that reports
-- something and one that reports @other@. Lean's six guards fire /during/ the
-- typed traversal, so a program that is ill-typed earlier in traversal order
-- refuses for the type error and the guard is never reached; and @other@ is
-- explicitly not a comparand (@connection.md@ §3.6). Defacing a program the
-- typed builder produced puts the guard first in traversal order, because
-- everything before it checks.
--
-- Each defacement below is written so that its own statement refuses
-- /immediately/, before @checkBlock@ recurses past it: an empty panel refuses in
-- @rhsPlan@ before the kind test, a @served by@ refuses in @askGuard@ before
-- the shape is built. Nothing after the injection point is ever checked, so a
-- @known here@ made stale by the extra binding cannot mask the guard.
rawBase :: Gen RawProgram
rawBase = rawWellFormed

-- | An empty panel, bound at a random depth of @main@ or written into a
-- function body. Lean's emptiness test precedes the kind test, so the binding's
-- annotation is free.
rawEmptyPanel :: Gen RawProgram
rawEmptyPanel = do
  p <- rawBase
  ann <- elements [Nothing, Just CodeVerdict, Just CodeText]
  let stmt rest = RawBind "bad" ann (SrcRhs (RhsPanel [] pos0)) rest pos0
  frequency
    [ (3, (\m -> p {progMain = m}) <$> placeStmt stmt (progMain p)),
      ( 1,
        pure
          p
            { progFns =
                progFns p
                  ++ [ RawFn
                         { fnName = "withEmptyPanel",
                           fnParams = [],
                           fnResult = CodeVerdict,
                           fnBody = [BodyBind "bad" ann (RhsPanel [] pos0) pos0],
                           fnAnswer = Just "bad",
                           fnAnswerPos = pos0,
                           fnPos = pos0
                         }
                     ]
            }
      )
    ]

-- | A bounded revision whose bound straddles @maxRevisions@: @64@ is accepted
-- and @65@ refused, so the interesting range is a few either side.
--
-- Written whole rather than injected, because the accepted side has to
-- /typecheck/ for the boundary to be a boundary: the subject is bound here, the
-- carrier and the review binding are fresh, the review answers @verdict@ and the
-- amend answers the subject's kind, and the consuming @case@ follows
-- immediately. At @n = 64@ that is a checked program of some four hundred
-- nodes; at @n = 65@ it is 'Agentic.Guards.RevisionBound', which
-- @overRevised@ raises in a pre-pass over raw @main@ — before the program
-- budget and before @checkBlock@, so nothing else can pre-empt it.
--
-- The typed builder cannot reach either side: 'Agentic.Builder.revisingCaseI'
-- refuses a bound over 64 outright, and 'genCase' keeps bounds at 3 or below
-- because the unroll replicates its arms once per exit.
rawRevisionBound :: Gen RawProgram
rawRevisionBound = do
  n <- frequency [(3, choose (60, 64)), (3, choose (65, 70)), (1, choose (0, 3))]
  who <- elements toolIds
  pure
    ( RawProgram
        []
        ( RawBind
            "d"
            (Just CodeText)
            (SrcRhs (RhsAsk (closedAsk (AddrModel "author") [Lit "draft"])))
            ( RawBind
                "loop"
                Nothing
                ( SrcRevising
                    "d"
                    "cand"
                    n
                    "verd"
                    Nothing
                    ( RhsAsk
                        ( closedAsk
                            (AddrModel "critic")
                            [Lit "review ", Interp "cand"]
                        )
                    )
                    ( RhsAsk
                        ( closedAsk
                            (AddrModel "author")
                            [Lit "fix ", Interp "cand", Lit " ", Interp "verd"]
                        )
                    )
                    pos0
                )
                ( RawCaseResult
                    "loop"
                    "done"
                    "done"
                    (RawAct (closedAsk (AddrTool who) [Lit "apply ", Interp "done"]) (RawEmpty pos0) pos0)
                    (RawEmpty pos0)
                    pos0
                )
                pos0
            )
            pos0
        )
    )

-- | An ask with no @served by@ and no independent draw.
closedAsk :: Addressee -> Prompt -> RawAsk
closedAsk who ws = RawAsk Nothing (RawTarget who 0) ws pos0

-- | A question count straddling @maxQuestions@: @4096@ is accepted and @4097@
-- refused.
--
-- The count is reached through a __chain of multiplying calls__ and never
-- through a literal list of four thousand asks: write the target in base 16 and
-- let each level of the table multiply the one below it by sixteen, so a
-- program worth four thousand questions is some fifty statements of JSON. Every
-- function in the chain answers @receipt@, takes no parameters and is called as
-- a statement, so the chain typechecks and the budget is what refuses it.
--
-- @rawBudget@ also reaches the guard's /other/ site: the program-level budget
-- fires on @main@, and the per-function one fires while the table is still
-- being built, ahead of everything in @main@.
rawBudget :: Gen RawProgram
rawBudget = do
  target <- frequency [(5, choose (4090, 4102)), (1, choose (1, 60))] :: Gen Integer
  if target < 256
    then pure (RawProgram [] (nActs target))
    else do
      let (e2, r2) = target `divMod` 256
          (e1, e0) = r2 `divMod` 16
          f0 = actsFn "q0" e2
          f1 = callsFn "q1" "q0" 16 e1
      inFn <- frequency [(4, pure False), (1, pure True)]
      pure $
        if inFn
          then RawProgram [f0, f1, callsFn "q2" "q1" 16 (e0 + 1)] (RawEmpty pos0)
          else RawProgram [f0, f1] (callsBlock "q1" 16 e0)
  where
    actsFn :: Text -> Integer -> RawFn
    actsFn nm k =
      RawFn
        { fnName = nm,
          fnParams = [],
          fnResult = CodeAck,
          fnBody = replicate (fromInteger k) (BodyAct plainAsk pos0),
          fnAnswer = Nothing,
          fnAnswerPos = pos0,
          fnPos = pos0
        }
    callsFn :: Text -> Text -> Int -> Integer -> RawFn
    callsFn nm callee k extra =
      RawFn
        { fnName = nm,
          fnParams = [],
          fnResult = CodeAck,
          fnBody =
            replicate k (BodyCallS callee [] pos0)
              ++ replicate (fromInteger extra) (BodyAct plainAsk pos0),
          fnAnswer = Nothing,
          fnAnswerPos = pos0,
          fnPos = pos0
        }
    callsBlock :: Text -> Int -> Integer -> Raw
    callsBlock callee k extra =
      foldr
        (\_ r -> RawCallStmt callee [] r pos0)
        (nActs extra)
        [1 .. k]
    nActs :: Integer -> Raw
    nActs k = foldr (\_ r -> RawAct plainAsk r pos0) (RawEmpty pos0) [1 .. k]
    plainAsk :: RawAsk
    plainAsk = RawAsk Nothing (RawTarget (AddrTool "t") 0) [Lit "tick"] pos0

-- | @served by@ naming the model that serves a tool or a person — the one
-- refusal 'Agentic.Builder.askModelServed' makes unrepresentable, hence
-- reachable only here.
--
-- The prompt is literal-only, so the injected act is well-formed at whatever
-- depth it lands: it names nothing, and @askGuard@ refuses it before the shape
-- is built. One draw in eight addresses a /model/ instead, where @served by@ is
-- exactly right — a negative control that must come back checked, with
-- @blockAsks@ one higher than the base's.
rawServedBy :: Gen RawProgram
rawServedBy = do
  p <- rawBase
  who <-
    frequency
      [ (4, AddrTool <$> elements toolIds),
        (3, AddrPerson <$> elements personIds),
        (1, AddrModel <$> elements modelIds)
      ]
  m <- elements modelIds
  d <- frequency [(6, pure 0), (2, pure 1), (1, pure 2)]
  k <- frequency [(1, pure 0), (3, pure 1), (2, pure 2)]
  ws <- map Lit <$> vectorOf k genLit
  let a = RawAsk (Just (servedBy1 m)) (RawTarget who d) ws pos0
      stmt rest = RawAct a rest pos0
  frequency
    [ (3, (\mn -> p {progMain = mn}) <$> placeStmt stmt (progMain p)),
      ( 1,
        pure
          p
            { progFns =
                progFns p
                  ++ [ RawFn
                         { fnName = "served",
                           fnParams = [],
                           fnResult = CodeAck,
                           fnBody = [BodyAct a pos0],
                           fnAnswer = Nothing,
                           fnAnswerPos = pos0,
                           fnPos = pos0
                         }
                     ]
            }
      )
    ]

-- | Two functions answering to one name. @Fns.find?@ returns the __first__
-- match, which is the divergence class a @Data.Map@-keyed port would land in
-- (@connection.md@ §1.4); the guard refuses the program before that matters,
-- and this is what fires it.
--
-- The duplicate is an exact copy inserted immediately after its original, so
-- every function ahead of it still checks and @checkFnsList@ reaches the name
-- clash rather than a type error. A base with no functions gets a trivial pair.
rawDupFunction :: Gen RawProgram
rawDupFunction = do
  p <- rawBase
  case progFns p of
    [] -> pure p {progFns = [trivialFn, trivialFn]}
    fs -> do
      i <- choose (0, length fs - 1)
      let (pre, post) = splitAt (i + 1) fs
      pure p {progFns = pre ++ [fs !! i] ++ post}
  where
    trivialFn =
      RawFn
        { fnName = "twice",
          fnParams = [],
          fnResult = CodeAck,
          fnBody =
            [BodyAct (RawAsk Nothing (RawTarget (AddrTool "t") 0) [Lit "tick"] pos0) pos0],
          fnAnswer = Nothing,
          fnAnswerPos = pos0,
          fnPos = pos0
        }

-- | Free-form raw syntax over a small name pool: mostly ill-typed, sometimes
-- not, and the share that answers the question "does the Haskell side ever
-- claim a guard that Lean does not".
rawFreeform :: Gen RawProgram
rawFreeform = do
  nf <- frequency [(3, pure 0), (3, pure 1), (2, pure 2), (1, pure 3)]
  let fnNames = ["h" <> T.pack (show i) | i <- [0 .. nf - 1 :: Int]]
  fs <- mapM (genRawFn fnNames) fnNames
  fuel <- choose (1, 6)
  -- Callees the table holds and callees it does not, on purpose: an unknown
  -- head costs zero questions (@Check.lean@ raises no error there, the typing
  -- judgment does), which is a clause of `callAsks` nothing else reaches.
  b <- genRawBlock (fnNames ++ ["nosuch"]) fuel namePool
  pure (RawProgram fs b)

namePool :: [Text]
namePool = ["a", "b", "c", "d", "subj", "x", "y"]

genRawPrompt :: [Text] -> Gen Prompt
genRawPrompt names = do
  k <- frequency [(1, pure 0), (3, pure 1), (3, pure 2), (1, pure 3)]
  vectorOf k piece
  where
    piece
      | null names = Lit <$> genLit
      | otherwise = frequency [(3, Lit <$> genLit), (2, Interp <$> elements names)]

genRawAsk :: [Text] -> Gen RawAsk
genRawAsk names = do
  ws <- genRawPrompt names
  who <-
    frequency
      [ (5, AddrModel <$> elements modelIds),
        (3, AddrTool <$> elements toolIds),
        (2, AddrPerson <$> elements personIds),
        (2, AddrToolExec <$> elements toolIds <*> elements execCmds <*> genExecArgs)
      ]
  d <- frequency [(6, pure 0), (2, pure 1), (1, pure 2), (1, pure 3)]
  -- Model 5, tool 3, person 2 as before, plus a `toolExec` — D5's fourth
  -- flavour — and a `served by` that is sometimes a chain rather than a single
  -- name (D6). Without both the bisimulation exercises neither codec.
  srv <-
    frequency
      [ (8, pure Nothing),
        (2, Just . servedBy1 <$> elements modelIds),
        (1, fmap Just (Served <$> elements modelIds <*> ((: []) <$> elements modelIds)))
      ]
  pure (RawAsk (guardServed who srv) (RawTarget who d) ws pos0)
  where
    -- A free-form ask keeps `served by` to models; the dedicated generator
    -- above is where the guard is aimed on purpose, so it is not diluted here.
    guardServed (AddrModel _) s = s
    guardServed _ _ = Nothing

genRawRhs :: [Text] -> [Text] -> Gen RawRhs
genRawRhs fnNames names =
  frequency
    ( [ (6, RhsAsk <$> genRawAsk names),
        ( 3,
          do
            k <- frequency [(1, pure 0), (4, pure 1), (3, pure 2), (2, pure 3)]
            RhsPanel <$> vectorOf k (genRawAsk names) <*> pure pos0
        )
      ]
        ++ [ ( 3,
               do
                 f <- elements fnNames
                 k <- choose (0 :: Int, 2)
                 as <- vectorOf k (genRawArg names)
                 pure (RhsCall f as pos0)
             )
             | not (null fnNames)
           ]
    )

genRawArg :: [Text] -> Gen RawArg
genRawArg names
  | null names = flip ArgLit pos0 <$> genRawPrompt []
  | otherwise =
      frequency
        [ (3, flip ArgName pos0 <$> elements names),
          (2, flip ArgLit pos0 <$> genRawPrompt names)
        ]

genRawBlock :: [Text] -> Int -> [Text] -> Gen Raw
genRawBlock fnNames fuel names
  | fuel <= 0 = pure (RawEmpty pos0)
  | otherwise =
      frequency
        ( [ (1, pure (RawEmpty pos0)),
            (5, RawAct <$> genRawAsk names <*> rest <*> pure pos0),
            ( 6,
              do
                x <- elements ["a", "b", "c", "d"]
                ann <- frequency [(3, pure Nothing), (2, Just <$> elements [CodeText, CodeVerdict, CodeFlag])]
                r <- genRawRhs fnNames names
                RawBind x ann (SrcRhs r)
                  <$> genRawBlock fnNames (fuel - 1) (x : names)
                  <*> pure pos0
            ),
            (2, RawKnownHere names <$> rest <*> pure pos0)
          ]
            ++ [ ( 3,
                   do
                     f <- elements fnNames
                     k <- choose (0 :: Int, 2)
                     as <- vectorOf k (genRawArg names)
                     RawCallStmt f as <$> rest <*> pure pos0
                 )
                 | not (null fnNames)
               ]
            ++ [ ( 3,
                   do
                     x <- elements names
                     RawIfFlag x <$> half <*> half <*> pure pos0
                 )
                 | not (null names)
               ]
            ++ [ ( 3,
                   do
                     x <- elements names
                     RawCaseVerdict x <$> third <*> third <*> third <*> pure pos0
                 )
                 | not (null names)
               ]
        )
  where
    rest = genRawBlock fnNames (fuel - 1) names
    half = genRawBlock fnNames (max 0 ((fuel - 1) `div` 2)) names
    third = genRawBlock fnNames (max 0 ((fuel - 1) `div` 3)) names

genRawFn :: [Text] -> Text -> Gen RawFn
genRawFn fnNames nm = do
  k <- choose (0 :: Int, 2)
  ps <- vectorOf k ((,) <$> elements ["p0", "p1"] <*> elements bindableCodes)
  nb <- choose (0 :: Int, 3)
  -- Only the entries declared *before* this one, so a free-form call is
  -- sometimes stratified and sometimes a forward reference.
  let earlier = takeWhile (/= nm) fnNames
  body <- vectorOf nb (genRawBodyStmt earlier (map fst ps))
  res <- elements [CodeText, CodeVerdict, CodeFlag, CodeAck]
  ans <-
    if res == CodeAck
      then pure Nothing
      else frequency [(3, pure (Just "r")), (1, pure Nothing)]
  pure
    RawFn
      { fnName = nm,
        fnParams = ps,
        fnResult = res,
        fnBody = body,
        fnAnswer = ans,
        fnAnswerPos = pos0,
        fnPos = pos0
      }

genRawBodyStmt :: [Text] -> [Text] -> Gen RawBodyStmt
genRawBodyStmt fnNames names =
  frequency
    ( [ ( 5,
          do
            ann <- frequency [(2, pure Nothing), (3, Just <$> elements bindableCodes)]
            r <- genRawRhs fnNames names
            pure (BodyBind "r" ann r pos0)
        ),
        (4, BodyAct <$> genRawAsk names <*> pure pos0)
      ]
        ++ [ ( 2,
               do
                 f <- elements fnNames
                 k <- choose (0 :: Int, 2)
                 as <- vectorOf k (genRawArg names)
                 pure (BodyCallS f as pos0)
             )
             | not (null fnNames)
           ]
    )

-- | Put a statement-former somewhere down the spine of a block, so a guard is
-- not always the first thing @checkBlock@ meets.
--
-- __One place it must not go.__ A bounded revision leaves a @Pend@ that the
-- /very next/ statement has to consume, and @checkBlock@ refuses every other
-- statement by name while it is pending. So the descent never treats a
-- @revising@ binding's @rest@ as an insertion point; it either inserts before
-- the whole revising statement, or steps over it into an arm of the consuming
-- @case@.
placeStmt :: (Raw -> Raw) -> Raw -> Gen Raw
placeStmt f b = frequency ((3, pure (f b)) : deeper)
  where
    at g x = g <$> placeStmt f x

    deeper = case b of
      RawBind x a src@(SrcRevising {}) (RawCaseResult cx sn un0 st un cp) p ->
        [ (1, at (\st' -> RawBind x a src (RawCaseResult cx sn un0 st' un cp) p) st),
          (1, at (\un' -> RawBind x a src (RawCaseResult cx sn un0 st un' cp) p) un)
        ]
      RawBind _ _ (SrcRevising {}) _ _ -> []
      RawBind x a src@(SrcRevisingOn {}) (RawCaseEnding cx sn un0 an st un ab cp) p ->
        [ (1, at (\st' -> RawBind x a src (RawCaseEnding cx sn un0 an st' un ab cp) p) st),
          (1, at (\un' -> RawBind x a src (RawCaseEnding cx sn un0 an st un' ab cp) p) un),
          (1, at (\ab' -> RawBind x a src (RawCaseEnding cx sn un0 an st un ab' cp) p) ab)
        ]
      RawBind _ _ (SrcRevisingOn {}) _ _ -> []
      RawBind x a src r p -> [(2, at (\r' -> RawBind x a src r' p) r)]
      RawAct a r p -> [(2, at (\r' -> RawAct a r' p) r)]
      RawKnownHere n r p -> [(2, at (\r' -> RawKnownHere n r' p) r)]
      RawCallStmt fn as r p -> [(2, at (\r' -> RawCallStmt fn as r' p) r)]
      RawIfFlag x y n p ->
        [ (1, at (\y' -> RawIfFlag x y' n p) y),
          (1, at (\n' -> RawIfFlag x y n' p) n)
        ]
      RawCaseVerdict x u v w p ->
        [ (1, at (\u' -> RawCaseVerdict x u' v w p) u),
          (1, at (\v' -> RawCaseVerdict x u v' w p) v),
          (1, at (\w' -> RawCaseVerdict x u v w' p) w)
        ]
      RawCaseResult x sn un0 st un p ->
        [ (1, at (\st' -> RawCaseResult x sn un0 st' un p) st),
          (1, at (\un' -> RawCaseResult x sn un0 st un' p) un)
        ]
      RawCaseEnding x sn un0 an st un ab p ->
        [ (1, at (\st' -> RawCaseEnding x sn un0 an st' un ab p) st),
          (1, at (\un' -> RawCaseEnding x sn un0 an st un' ab p) un),
          (1, at (\ab' -> RawCaseEnding x sn un0 an st un ab' p) ab)
        ]
      RawEmpty _ -> []

-- | Shrinking a raw program is sound in a way shrinking a 'GenCase' is not:
-- there is no 'Agentic.Plan.Plan' to keep in step, so any structural
-- simplification is a legal candidate. Drop a function, or truncate the block.
shrinkRawProgram :: RawProgram -> [RawProgram]
shrinkRawProgram (RawProgram fs m) =
  [RawProgram (dropAt i fs) m | i <- [0 .. length fs - 1]]
    ++ [RawProgram fs m' | m' <- shrinkRaw m]
  where
    dropAt i xs = take i xs ++ drop (i + 1) xs

    shrinkRaw = \case
      RawEmpty _ -> []
      RawBind _ _ _ r _ -> [r]
      RawAct _ r _ -> [r]
      RawKnownHere _ r _ -> [r]
      RawCallStmt _ _ r _ -> [r]
      RawIfFlag _ y n _ -> [y, n]
      RawCaseVerdict _ a o d _ -> [a, o, d]
      RawCaseResult _ _ _ st un _ -> [st, un]
      RawCaseEnding _ _ _ _ st un ab _ -> [st, un, ab]

-- ---------------------------------------------------------------------------
-- The string layer's inputs
-- ---------------------------------------------------------------------------

-- | Strings for the @{"string": …}@ request, biased to the D12 traps.
--
-- Every atom below is a place Lean's ASCII-only character predicates
-- (@Char.isWhitespace@, @Char.toLower@, @Char.isAlphanum@) and Haskell's
-- Unicode-aware ones disagree, or a place @answerLines@\/@words@\/@decodeFlag@
-- have a boundary:
--
-- * @İ@ (U+0130) and @ı@ (U+0131) — Unicode lowercasing changes the code-point
--   count of the first; ASCII lowercasing leaves both alone.
-- * @ß@ and @Σ@\/@ς@ — Unicode case folding maps @ß@ to @ss@ and @Σ@ to @σ@ or
--   @ς@ by position; ASCII does neither.
-- * NBSP (U+00A0) — a Unicode space that @trimAscii@ must __not__ strip.
-- * CRLF — @answerLines@ splits on @\\n@ only and the @\\r@ falls to the
--   per-line trim, so a CRLF file and an LF file must decode alike.
-- * blank lines and the empty string — @answerLines@ drops empties, and an
--   empty line list is @Verdict.declined@.
-- * multi-word yes\/no spellings — @saidNo@ fires on a /no/ word anywhere,
--   @saidYes@ only on a reply that is a /yes/ word and nothing else, and that
--   asymmetry is the safety property.
--
-- Wave three adds the atoms the D2 fence and the D7 deciders turn on, so that
-- the string-layer property puts something a decider can decide about rather
-- than an empty document: bolded and backticked markers (@bare@'s five
-- decorations), a CRLF marker line (the divergence from incite that is a bug
-- fix), diff headers indented and not, a bare markdown rule (which is __not__ a
-- header, the trailing space being significant), a path with a space in it, and
-- a body carrying a closing tag of its own.
genTrapText :: Gen Text
genTrapText =
  frequency
    [ (2, pure ""),
      (3, elements atoms),
      (2, elements decisive),
      (4, joined)
    ]
  where
    atoms =
      [ "\x0130", -- İ
        "\x0131", -- ı
        "ß",
        "\x03A3", -- Σ
        "\x03C2", -- ς
        "\x00A0", -- NBSP
        "\r\n",
        "\n",
        "\n\n",
        "\r",
        "\t",
        " ",
        "   ",
        "İstanbul",
        "HeLLo İstanbul",
        "straße",
        "ΣΣς",
        "hello world",
        "Plain ASCII text.",
        "42",
        -- D7: the markers, decorated and not, and the line endings.
        "WORK COMPLETE",
        "**WORK COMPLETE**",
        "`WORK COMPLETE`",
        "progress\nWORK COMPLETE\r\n",
        "one\r\nWORK REMAINS\r\n",
        "\10007 lint",
        "\10007",
        "FACTS PATHS UNRESOLVED: three",
        -- D7: the diff headers, indented and not, and the rule that is not one.
        "diff --git a/Foo.hs b/Foo.hs",
        "    diff --git a/src/Bar.lhs b/src/Bar.lhs",
        "--- a/x.cabal\n+++ b/x.cabal",
        "---",
        "+++",
        "rename from a/Old.hs\nrename to b/New.hs",
        "diff --git a/a file.hs b/a file.hs",
        "--- /dev/null\n+++ b/New.hs",
        -- D2: a body that closes its own fence, and one that closes a
        -- sibling's.
        "x </alpha> y",
        "x </beta> y",
        "<alpha>\ninner\n</alpha>\n"
      ]

    decisive =
      [ "yes",
        "y",
        "true",
        "approve",
        "approved",
        "ok",
        "lgtm",
        "no",
        "n",
        "false",
        "reject",
        "rejected",
        "deny",
        "APPROVE",
        "Approved",
        "yes please",
        "approve it",
        "no way",
        "I say no",
        "not approved",
        "looks good to me",
        "yes\r\n",
        "  approve  ",
        "approve\nbut also no",
        "line one\nline two",
        "\n\napprove\n\n",
        "yes no",
        "ok\x00A0",
        "approve İ"
      ]

    joined = do
      k <- choose (2 :: Int, 4)
      parts <- vectorOf k (frequency [(2, elements atoms), (2, elements decisive)])
      sep <- elements ["", " ", "\n", "\r\n", "\x00A0", "\t"]
      pure (T.intercalate sep parts)

-- ---------------------------------------------------------------------------
-- The generator's own test
-- ---------------------------------------------------------------------------

-- | @'planSizeAtMost' k p@ — does @p@ have at most @k@ nodes? Short-circuits,
-- so it is safe to ask of a term a generator may have blown up.
--
-- This is 'Agentic.Plan.size' with a budget: the same clauses, the same
-- self-counting @case@, stopped as soon as the budget is gone.
planSizeAtMost :: forall g a. Integer -> Plan g a -> Bool
planSizeAtMost lim p0 = go lim p0 >= 0
  where
    go :: forall g' a'. Integer -> Plan g' a' -> Integer
    go n _ | n < 0 = -1
    go n (PRet _) = n - 1
    go n (PAskC _ _ k) = go (n - 1) k
    go n (PAsk _ _ _ k) = go (n - 1) k
    go n (PCase t _ arms) =
      foldl (\m x -> if m < 0 then -1 else go m (arms x)) (n - 1) (tagValues t)
    go n PDyn {} = n - 1

-- | Cardano's @generatesWithin@, concretely: 100 'GenCase's, 100
-- 'genRawProgram's and 200 'genTrapText's, forced, inside a 30-second wall
-- clock. 'False' on the budget, on a plan above 4000 nodes, or on a printed
-- program above 4 MB — each of which is a generator blow-up and not a
-- divergence, and each of which the bisimulation runner wants as a red test
-- rather than as a hung job.
--
-- The bounded revision is why this exists: its unroll replicates both arms of
-- the consuming @case@ once per exit, so a bound and a nesting depth that look
-- innocent multiply. The frequencies in 'genCase' hold the product down; this
-- checks that they still do.
selfTest :: IO Bool
selfTest = (== Just True) <$> timeout (30 * 1000000) body
  where
    -- Every alternative below is forced with 'evaluate', and forced /inside/
    -- the timeout. A generator returns a lazy value and 'timeout' returns the
    -- moment its action does, so a body that merely built thunks would let the
    -- blow-up this test exists to catch happen after the clock stopped.
    body = do
      as <- replicateM 100 oneCase
      bs <- replicateM 100 oneRaw
      cs <- replicateM 200 oneText
      evaluate (and as && and bs && and cs)

    oneCase = do
      GenCase p ws <- generate genCase
      let raw = progRawOut p
          n = LBS.length (encode (toJSON raw))
          wn = sum [LBS.length (encode (toJSON w)) | w <- ws]
          (blockN, fnN) = askCounts raw
      evaluate
        ( n > 0
            && n < 4000000
            && wn > 0
            && not (null ws)
            && blockN >= 0
            && length fnN >= 0
            && planSizeAtMost 4000 (progPlan p)
            -- The term is bounded before the run is asked for, so a blown-up
            -- program is reported rather than traced.
            && all (\w -> length (trace (toWorld w) (progPlan p)) >= 0) ws
        )

    oneRaw = do
      rp <- generate genRawProgram
      let n = LBS.length (encode (toJSON rp))
          (blockN, _) = askCounts rp
      evaluate (n > 0 && n < 4000000 && blockN >= 0)

    oneText = do
      t <- generate genTrapText
      evaluate (T.length t >= 0)
