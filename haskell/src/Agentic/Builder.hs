{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}

-- |
-- Module      : Agentic.Builder
-- Description : The production surface: typed combinators that print a
--               'RawProgram' and elaborate to a 'Plan'.
--
-- This is the port of @Agentic/Core/Dsl/Check.lean@'s /elaboration/, and only
-- of the elaboration. There is no parser here and no typing judgment: the
-- refusals @checkBlock@ hands back — @unbound@, @freshName@, @Binding.at?@'s
-- kind mismatch, @argExpr@'s kind mismatch, @bindKind@'s "nothing fixes the
-- kind", @askGuard@'s @served by@ on a tool, an empty panel, a duplicate
-- function name, a call that names a later function — are all /type/ errors of
-- the combinators below, or are unrepresentable outright. What is ported is
-- which 'Plan' nodes each surface construct builds, in what order, with what
-- 'Expr' splices, because that is what makes a rebuilt case's trace and folds
-- comparable to the frozen corpus.
--
-- Two things ride together in every value here: the 'Agentic.Raw' data the
-- construct /prints/, and the 'Plan' it /elaborates to/. There is no separate
-- print pass, so the two cannot drift.
--
-- __Positions.__ A builder cannot say where a construct was written, so every
-- 'Pos' it emits is @0:0@ ('pos0'). Comparison against the corpus strips
-- positions on both sides with 'zeroPos'. @pos@ is oracle-only for this whole
-- program, exactly like @message@ and @excerpt@.
--
-- __The context is a type-level association list.__ @Bindings Γ@
-- (@Check.lean:78@) is a list from name to code, extended by @Bindings.push@,
-- with shadowing refused by @freshName@; 'Scope' is that list at the type
-- level and 'Fresh' is @freshName@.
--
-- __A binding is a value, not a name to be looked up.__ @Binding Γ@'s three
-- fields are the name it prints, the kind it answers and the @Expr.var@ that
-- reads it, and that is exactly what a 'V' carries: the 'Text' and the 'Var'.
-- A binder /hands/ its handle to the rest of the block, so every mention of a
-- binding is an ordinary Haskell variable, a typo is GHC's own
-- @Variable not in scope@, and there is no name resolution at the type level
-- at all. The one thing a handle cannot carry is how many binders will be
-- pushed after it, so reading one at depth is 'readV' — @push@'s repeated
-- @Sub.wk@, one 'VThere' per entry stepped over. No weakening is ever written
-- by hand.
module Agentic.Builder
  ( -- * The four answer kinds
    -- | Re-exported from "Agentic.Raw" so that a module of rebuilt cases needs
    -- no other import: every combinator below is applied at a promoted 'Code'.
    Code (..),

    -- * The typed scope
    Entry,
    Scope,
    Codes,
    V (..),
    ScopeEq,
    KnownIx (..),
    readV,
    Fresh,
    KnownScope (..),

    -- * Words
    Piece (..),
    Words,
    lit,
    hole,
    holeI,
    Spliceable (..),
    wordsRaw,
    wordsExpr,
    wordsClosed,

    -- * Questions
    Ask (..),
    askModel,
    askModelServed,
    askModelFallingBack,
    askTool,
    askToolRunning,
    askPerson,
    draw,
    askRaw,
    askShapeH,
    askNode,
    askAt,

    -- * Clause-position sources
    Rhs (..),
    one,
    panel,
    panelText,
    Decider (..),
    decide,
    decideI,
    callV,

    -- * Arguments and functions
    Arg (..),
    argName,
    argNameI,
    argWords,
    Args (..),
    ParamCtx,
    ParamCtxGo,
    Params (..),
    noParams,
    param,
    Fn (..),
    function,

    -- * Function bodies
    Body (..),
    bindB,
    bindBI,
    bindAsB,
    bindAsBI,
    actB,
    callSB,
    answerB,
    answerBI,
    endB,

    -- * Blocks
    Blk (..),
    stop,
    bind,
    bindI,
    bindAs,
    bindAsI,
    act,
    callStmt,
    ifFlag,
    ifFlagI,
    caseVerdict,
    caseVerdictI,
    knownHere,
    knownHereI,
    revisingCase,
    revisingCaseI,
    revisingOnCase,
    revisingOnCaseI,

    -- * Programs
    Program (..),
    SomeFn (..),
    program,

    -- * The pos rule
    pos0,
    zeroPos,
  )
where

import Agentic.Plan hiding (panel, panelText)
import qualified Agentic.Plan as P
import Agentic.Raw
  ( Addressee (..),
    Chunk (..),
    Code (..),
    Decider (..),
    Pos (..),
    Prompt,
    Raw (..),
    RawArg (..),
    RawAsk (RawAsk),
    RawBodyStmt (..),
    RawFn (..),
    RawProgram (..),
    RawRhs (..),
    RawSource (..),
    RawTarget (..),
    Served (..),
    TextMember (..),
    servedBy1,
  )
import Agentic.Text (runDecider)
import Data.Kind (Constraint, Type)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NE
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import qualified Data.Text as T
import GHC.TypeLits
  ( ErrorMessage (..),
    KnownSymbol,
    Symbol,
    TypeError,
    symbolVal,
  )

-- ---------------------------------------------------------------------------
-- The typed scope: Lean's @Bindings Γ@, at the type level
-- ---------------------------------------------------------------------------

-- | One live binding: the author's name, and the kind of answer it stands for.
--
-- Lean: @Binding Γ@ (@Check.lean:69@) minus its @val@ field, which the 'V' the
-- binder hands out carries.
type Entry = (Symbol, Code)

-- | The names in scope, innermost first. Lean: @Bindings Γ@.
type Scope = [Entry]

-- | The 'Plan' context a scope projects to: Lean's @Γ@ under a @Bindings Γ@.
--
-- Note the order — index @0@ is the most recently bound answer, in Haskell as
-- in Lean — so a scope and its context are extended by the same cons.
type family Codes (s :: Scope) :: Ctx where
  Codes '[] = '[]
  Codes ('(n, c) ': s) = c ': Codes s

-- | One live binding, as a value: the name it prints, and the index that reads
-- it __at the scope it was bound into__ — itself at index @0@, so @h@ is
-- @'(n, c) ': (whatever was live)@.
--
-- Lean: @Binding Γ@ (@Check.lean:69@) whole — @name@, @code@ and @val@. The
-- name is ordinary runtime data and the index is ordinary runtime data; the
-- scope index @h@ is what says /which/ binding this is, and it is the only
-- thing left at the type level. Every binder below hands one to the rest of
-- the block, so nothing here ever resolves a name.
data V (h :: Scope) (c :: Code) = V
  { -- | what the printer writes for this binding
    vName :: Text,
    -- | the de Bruijn index at the binding's own scope, i.e. 'VHere'
    vIx :: Var (Codes h) c
  }

-- | Structural equality of scopes as a closed family, so 'readV' can dispatch
-- on it without overlapping instances. A scope grows by one entry per binding,
-- so two live bindings never share a scope and equality here is exactly
-- identity of bindings.
type family ScopeEq (a :: Scope) (b :: Scope) :: Bool where
  ScopeEq a a = 'True
  ScopeEq a b = 'False

-- | Weakening a handle's index from the scope it was bound into to the scope
-- it is read at.
--
-- Lean: @Bindings.push@ (@Check.lean:96@) gives the new binding
-- @Expr.var .here@ and renames every older one along @Sub.wk@; the instance
-- walk below is that renaming, one 'VThere' per entry bound since. It is the
-- one thing a handle cannot carry — a binding does not know what will be bound
-- after it — and it is the whole of what the type level still decides.
class KnownIx (h :: Scope) (s :: Scope) where
  wkIx :: Var (Codes h) c -> Var (Codes s) c

-- | The boolean-dispatched worker of 'KnownIx'.
class KnownIx' (eq :: Bool) (h :: Scope) (s :: Scope) where
  wkIx' :: Var (Codes h) c -> Var (Codes s) c

instance KnownIx' (ScopeEq h s) h s => KnownIx h s where
  wkIx = wkIx' @(ScopeEq h s) @h @s

instance h ~ s => KnownIx' 'True h s where
  wkIx' = id

instance KnownIx h s => KnownIx' 'False h ('(n, d) ': s) where
  wkIx' v = VThere (wkIx @h @s v)

-- | The refusal @unbound@ (@Check.lean:101@) becomes this: a handle read where
-- its binding is no longer live.
instance
  TypeError
    ( 'Text "this binding is not live here; nothing in scope answers to it"
    ) =>
  KnownIx' 'False h '[]
  where
  wkIx' = error "KnownIx' 'False h '[]: unreachable, the instance is a TypeError"

-- | Reading a binding at the scope in hand. Lean: @Binding.val@ under
-- @push@'s accumulated weakening.
readV :: forall h s c. KnownIx h s => V h c -> Var (Codes s) c
readV v = wkIx @h @s (vIx v)

-- | The handle a binder hands out: its printed name, at index @0@.
hereV :: forall n c s. KnownSymbol n => V ('(n, c) ': s) c
hereV = V (nameText @n) VHere

-- | The name, as the printer writes it.
nameText :: forall n. KnownSymbol n => Text
nameText = T.pack (symbolVal (Proxy @n))

-- | No shadowing, as a constraint. Lean: @freshName@ (@Check.lean:113@),
-- whose refusal this reproduces verbatim.
type family Fresh (n :: Symbol) (s :: Scope) :: Constraint where
  Fresh n '[] = ()
  Fresh n ('(n, c) ': s) =
    TypeError
      -- Not a [wft|...|] twice over: this text is a Symbol in a type, and Agentic.WF imports this module (a cycle).
      ( 'Text "this name is already in scope, and a live name is not \
              \introduced twice; rename one of the two: "
          ':<>: 'Text n
      )
  Fresh n ('(m, d) ': s) = Fresh n s

-- | The scope's names, innermost first — what @known here@ asserts and what
-- 'knownHere' prints.
class KnownScope (s :: Scope) where
  scopeNames :: [Text]

instance KnownScope '[] where
  scopeNames = []

instance (KnownSymbol n, KnownScope s) => KnownScope ('(n, c) ': s) where
  scopeNames = nameText @n : scopeNames @s

-- ---------------------------------------------------------------------------
-- Positions
-- ---------------------------------------------------------------------------

-- | The one position a builder can emit.
pos0 :: Pos
pos0 = Pos 0 0

-- | Every 'Pos' in a program, set to @0:0@. Total and structural; idempotent
-- on this module's own output, so tier1 applies it to /both/ sides of a
-- comparison and cannot thereby mask a mismatch.
zeroPos :: RawProgram -> RawProgram
zeroPos p = RawProgram (map zeroFn (progFns p)) (zeroRaw (progMain p))

zeroFn :: RawFn -> RawFn
zeroFn f =
  f
    { fnBody = map zeroBodyStmt (fnBody f),
      fnAnswerPos = pos0,
      fnPos = pos0
    }

zeroBodyStmt :: RawBodyStmt -> RawBodyStmt
zeroBodyStmt = \case
  BodyBind x ann r _ -> BodyBind x ann (zeroRhs r) pos0
  BodyAct a _ -> BodyAct (zeroAsk a) pos0
  BodyCallS f as _ -> BodyCallS f (map zeroArg as) pos0

zeroAsk :: RawAsk -> RawAsk
zeroAsk (RawAsk m t p _) = RawAsk m t p pos0

zeroArg :: RawArg -> RawArg
zeroArg = \case
  ArgName x _ -> ArgName x pos0
  ArgLit p _ -> ArgLit p pos0

zeroRhs :: RawRhs -> RawRhs
zeroRhs = \case
  RhsAsk a -> RhsAsk (zeroAsk a)
  RhsPanel ms _ -> RhsPanel (map zeroAsk ms) pos0
  RhsPanelText ms _ ->
    RhsPanelText (map (\m -> m {tmAsk = zeroAsk (tmAsk m)}) ms) pos0
  RhsDecide d x ws _ -> RhsDecide d x ws pos0
  RhsCall f as _ -> RhsCall f (map zeroArg as) pos0

zeroSource :: RawSource -> RawSource
zeroSource = \case
  SrcRhs r -> SrcRhs (zeroRhs r)
  SrcRevising subj carrier n rname rann review amend _ ->
    SrcRevising subj carrier n rname rann (zeroRhs review) (zeroRhs amend) pos0
  SrcRevisingOn subj carrier n rname rann review amend _ ->
    SrcRevisingOn subj carrier n rname rann (zeroRhs review) (zeroRhs amend) pos0

zeroRaw :: Raw -> Raw
zeroRaw = \case
  RawEmpty _ -> RawEmpty pos0
  RawBind x ann src rest _ -> RawBind x ann (zeroSource src) (zeroRaw rest) pos0
  RawAct a rest _ -> RawAct (zeroAsk a) (zeroRaw rest) pos0
  RawIfFlag x y n _ -> RawIfFlag x (zeroRaw y) (zeroRaw n) pos0
  RawCaseVerdict x a o d _ ->
    RawCaseVerdict x (zeroRaw a) (zeroRaw o) (zeroRaw d) pos0
  RawCaseResult x sname uname st un _ ->
    RawCaseResult x sname uname (zeroRaw st) (zeroRaw un) pos0
  RawCaseEnding x sname uname aname st un ab _ ->
    RawCaseEnding x sname uname aname (zeroRaw st) (zeroRaw un) (zeroRaw ab) pos0
  RawKnownHere names rest _ -> RawKnownHere names (zeroRaw rest) pos0
  RawCallStmt f as rest _ -> RawCallStmt f (map zeroArg as) (zeroRaw rest) pos0

-- ---------------------------------------------------------------------------
-- Words
-- ---------------------------------------------------------------------------

-- | One piece of a prompt: the 'Chunk' it prints and the text it computes.
-- Lean: @Chunk@ and @chunkExpr@ (@Check.lean:128@).
data Piece (s :: Scope) = Piece
  { pieceRaw :: Chunk,
    pieceExpr :: Expr (Codes s) Text
  }

-- | Everything said in one question, read left to right. Lean: @Prompt@.
type Words (s :: Scope) = [Piece s]

-- | Words written in the source. Lean: @chunkExpr@'s @.lit@ clause.
lit :: Text -> Piece s
lit t = Piece (Lit t) (const t)

-- | A hole: the answer a binding stands for, spliced /as text/, under the name
-- that binding prints.
--
-- Lean: @chunkExpr@'s @.interp@ clause. A @text@ answer splices itself; a
-- @verdict@ splices @Verdict.render@ — its objections joined by @"; "@, so
-- approval and refusal both splice as @""@; a @flag@ or a @receipt@ has no
-- text of its own and is refused, here by 'Spliceable' having no instance for
-- it but a 'TypeError'.
hole ::
  forall h s c.
  (KnownIx h s, Spliceable c) =>
  V h c ->
  Piece s
hole v = holeI @c @s (vName v) (readV @h @s v)

-- | 'hole' at an index rather than at a name: the name as it is /printed/, and
-- the de Bruijn index that /reads/ it. See the note on index-level entry points
-- at the foot of this module.
holeI :: forall c s. Spliceable c => Text -> Var (Codes s) c -> Piece s
holeI x v = Piece (Interp x) (splice @c . varGet v)

-- | The kinds of answer that have a text of their own.
class Spliceable (c :: Code) where
  splice :: El c -> Text

instance Spliceable 'CodeText where
  splice = id

instance Spliceable 'CodeVerdict where
  splice = verdictRender

instance
  TypeError
    -- Not a [wft|...|] twice over: this text is a Symbol in a type, and Agentic.WF imports this module (a cycle).
    ( 'Text "only a text or a verdict answer interpolates into a prompt \
            \— a flag has no text of its own"
    ) =>
  Spliceable 'CodeFlag
  where
  splice = error "Spliceable CodeFlag: unreachable, the instance is a TypeError"

instance
  TypeError
    -- Not a [wft|...|] twice over: this text is a Symbol in a type, and Agentic.WF imports this module (a cycle).
    ( 'Text "only a text or a verdict answer interpolates into a prompt \
            \— a receipt has no text of its own"
    ) =>
  Spliceable 'CodeAck
  where
  splice = error "Spliceable CodeAck: unreachable, the instance is a TypeError"

-- | The prompt as written.
wordsRaw :: Words s -> Prompt
wordsRaw = map pieceRaw

-- | The words as a function of what is known. Lean: @Prompt.expr@
-- (@Check.lean:159@), whose fold is left-associated; 'T.concat' is that same
-- string, associativity being a theorem about @++@ and not an observable.
wordsExpr :: Words s -> Expr (Codes s) Text
wordsExpr ps d = T.concat (map (\p -> pieceExpr p d) ps)

-- | The words where the prompt mentions no name, and 'Nothing' where it does.
--
-- Lean: @Prompt.closed@ (@Syntax.lean:137@). __The decision is made on the
-- chunks, never on the 'Expr'__: closed-versus-open is exactly what separates
-- 'PAskC' from 'PAsk', hence @batch@ from @pipeline@ in the @level@ fold. The
-- empty prompt is closed, at @""@.
wordsClosed :: Words s -> Maybe Text
wordsClosed ws = T.concat <$> traverse litOf (wordsRaw ws)
  where
    litOf = \case
      Lit t -> Just t
      Interp _ -> Nothing

-- ---------------------------------------------------------------------------
-- Questions
-- ---------------------------------------------------------------------------

-- | One question as written: whom, which draw, the @served by@ override, and
-- the words. Lean: @RawAsk@, whose /kind is not a field/ — a question is
-- elaborated at the kind its position or its binder imposes.
data Ask (s :: Scope) = Ask
  { askAddr :: Addressee,
    askDraw :: Integer,
    -- | The @served by@ chain: the model that serves this question and the
    -- spares the runner may fall back to (D6). Widened from a @Maybe Text@,
    -- which is invisible to every existing call site because 'askModelServed'
    -- still takes one name.
    askServe :: Maybe Served,
    askWords :: Words s
  }

-- | @ask model "m" …@.
askModel :: Text -> Words s -> Ask s
askModel i w = Ask (AddrModel i) 0 Nothing w

-- | @ask model "m" served by "s" …@ — __the only__ constructor that takes a
-- serving model, which is how @askGuard@'s refusal (@Check.lean:340@:
-- "@served by@ names the model that serves a model addressee; a tool or a
-- person is not served by one") becomes unrepresentable rather than checked.
--
-- The alternative spelling — a phantom party index on 'Ask', with
-- @served :: Text -> Ask s 'PModel -> Ask s 'PModel@ — was rejected because a
-- panel combines members of /different/ parties (@battery-119@ panels a model,
-- a tool and a person), so an indexed 'Ask' would force an existential wrapper
-- at every panel member. The refusal is equally unrepresentable either way.
askModelServed :: Text -> Text -> Words s -> Ask s
askModelServed i m w = Ask (AddrModel i) 0 (Just (servedBy1 m)) w

-- | @ask model "m" served by "deep" or "broad" …@ — the same pin with the
-- models that may answer in its place, in the order the runner tries them
-- (D6). 'askModelServed' is this at an empty spare list, and the two print the
-- same @{"primary": …, "alternates": []}@ payload.
--
-- __The alternates are not part of the question.__ @Check.askShape@ takes the
-- primary alone, so two asks differing only here elaborate to the same plan,
-- put the same question and bill the same; what the alternates reach is
-- @Agentic.Chains@ and the runner, and nothing below it.
askModelFallingBack :: Text -> Text -> [Text] -> Words s -> Ask s
askModelFallingBack i m spares w = Ask (AddrModel i) 0 (Just (Served m spares)) w

-- | @ask tool "t" …@.
askTool :: Text -> Words s -> Ask s
askTool i w = Ask (AddrTool i) 0 Nothing w

-- | @ask tool "green" running "nix" ["flake", "check"] …@ — a tool whose answer
-- the /runner/ obtains by running a program-authored command (D5), so that a
-- check can be an exit code rather than a model's claim about one.
--
-- 'askTool''s type is deliberately unchanged: the nineteen rebuilt tier1 cases
-- must keep compiling untouched, and a fourth addressee flavour is written only
-- where it is used, so no frozen entry's printed program moves by one byte.
--
-- The words are not decoration and are not an argv: they are the question, and
-- the executing world writes them to the child's standard input. There is no
-- interpolation syntax at an argv — @cmd@ and the arguments are 'Text' and
-- never 'Words' — which is why no capability lattice is owed here.
askToolRunning :: Text -> Text -> [Text] -> Words s -> Ask s
askToolRunning i cmd args w = Ask (AddrToolExec i cmd args) 0 Nothing w

-- | @ask person "p" …@.
askPerson :: Text -> Words s -> Ask s
askPerson i w = Ask (AddrPerson i) 0 Nothing w

-- | @independent draw n@. Two draws of one prompt are two questions, which is
-- what the memo bill prices apart.
draw :: Integer -> Ask s -> Ask s
draw n a = a {askDraw = n}

-- | The question as printed.
askRaw :: Ask s -> RawAsk
askRaw a =
  RawAsk
    (askServe a)
    (RawTarget (askAddr a) (askDraw a))
    (wordsRaw (askWords a))
    pos0

-- | The shape a target writes. Lean: @askShape@ (@Check.lean:172@) — the
-- addressee and the draw as given, the scope at the unit of the scope monoid,
-- and @served by@ applied to /that/ by @atModel@, which sets the model axis
-- and leaves the mode axis silent. @served by@ never touches the words.
--
-- The 'SCode' argument is Lean's @(c : Code)@; @atModel@ ignores it, and it is
-- kept so a shape cannot be built at a kind its node does not use.
askShapeH :: SCode c -> Ask s -> Shape c
askShapeH _ a =
  let s = Shape {shAddressee = askAddr a, shScope = scopeUnit, shDraw = askDraw a}
   in maybe s (\srv -> atModelShape (srvPrimary srv) s) (askServe a)

-- | A question in binding position: __one__ node, because 'PAsk' /is/
-- ask-and-bind. Lean: @bindForm@ (@Check.lean:542@), its @.ask@ branch at @:551@.
askNode :: forall c s a. KnownCode c => Ask s -> Plan (c ': Codes s) a -> Plan (Codes s) a
askNode a k = case wordsClosed (askWords a) of
  Just w -> PAskC c (withPrompt (askShapeH c a) w) k
  Nothing -> PAsk c (askShapeH c a) (wordsExpr (askWords a)) k
  where
    c = sCode @c

-- | A question as a value. Lean: @askPlan@ (@Check.lean:350@), i.e. @askC1@
-- where the words are in the term and @ask1@ where they are computed.
askAt :: forall c s. KnownCode c => Ask s -> Plan (Codes s) (El c)
askAt a = case wordsClosed (askWords a) of
  Just w -> askC1 c (withPrompt (askShapeH c a) w)
  Nothing -> ask1 c (askShapeH c a) (wordsExpr (askWords a))
  where
    c = sCode @c

-- ---------------------------------------------------------------------------
-- Clause-position sources
-- ---------------------------------------------------------------------------

-- | A source at the kind its position or its binder fixes: one question, a
-- panel of them, or a call. Lean: @RawRhs@ with @rhsPlan@ (the value) and
-- @bindForm@ (the binding form) precomputed at that kind.
data Rhs (s :: Scope) (c :: Code) = Rhs
  { rhsRaw :: RawRhs,
    -- | Lean: @rhsPlan@ (@Check.lean:478@).
    rhsPlan :: Plan (Codes s) (El c),
    -- | Lean: @bindForm@ (@Check.lean:542@).
    rhsForm :: forall a. Plan (c ': Codes s) a -> Plan (Codes s) a
  }

-- | The binding form of everything that is not a bare question: the value's
-- plan grafted, with the value consed onto the leaf's environment. Lean:
-- @fun k => Plan.graft v (fun _ σ e => Plan.sub k (fun δ => Env.cons (e δ) (σ δ)))@.
--
-- Stated over a bare context rather than over @Codes s@ because 'Codes' is not
-- injective: the continuation's type is what fixes both indices here.
graftForm ::
  Plan g (El c) ->
  (forall a. Plan (c ': g) a -> Plan g a)
graftForm v k = graft v (Cont (\sigma e -> subP k (subCons e sigma)))

-- | One question, at the imposed kind.
one :: forall c s. KnownCode c => Ask s -> Rhs s c
one a =
  Rhs
    { rhsRaw = RhsAsk (askRaw a),
      rhsPlan = askAt @c a,
      rhsForm = \k -> askNode @c a k
    }

-- | @panel, all must approve […]@.
--
-- Lean: @checkMembers@ (@Check.lean:365@) elaborates every member at
-- @.verdict@ — positionally, never by inference — and @Plan.panel@
-- (@Plan.lean:975@) folds them right, from the unit, in member order:
-- @v₁ * (v₂ * (… * (vₙ * 1)))@ in the verdict monoid, where @declined@
-- annihilates, @approve@ is the unit and objection lists concatenate. The
-- monoid is noncommutative on purpose, so the fold's direction is normative.
--
-- A panel answers @verdict@ and nothing else (@Check.lean:492@), and it needs
-- at least one member (@Check.lean:484@) — hence 'NonEmpty', which is why the
-- @vector-004@ guard vector is not rebuildable here. That is the point:
-- @tier0@ owns the refusals.
panel :: NonEmpty (Ask s) -> Rhs s 'CodeVerdict
panel ms =
  Rhs
    { rhsRaw = RhsPanel (map askRaw members) pos0,
      rhsPlan = v,
      rhsForm = \k -> graftForm v k
    }
  where
    members = NE.toList ms
    v = P.panel (map (askAt @'CodeVerdict) members)

-- | @panel as text [ name: ask, … ]@ — 'panel'\'s twin at @text@ (D2).
--
-- Lean: @checkMembersText@ (@Check.lean:384@) elaborates every member at
-- @.text@ — positionally, never by inference — with the label carried through,
-- and @Plan.panelText@ (@Plan.lean:1008@) folds them right from the empty
-- document, wrapping each answer in 'Agentic.Text.block' as it goes:
-- @block n₁ a₁ ++ (block n₂ a₂ ++ … ++ "")@.
--
-- A text panel answers @text@ and nothing else, and it needs at least one
-- member — hence 'NonEmpty', which is why @battery-202@'s guard vector is not
-- rebuildable here. That is the point: @tier0@ owns the refusals, and so it
-- owns the two label refusals (an invalid character, two members answering to
-- one name) too.
panelText :: NonEmpty (Text, Ask s) -> Rhs s 'CodeText
panelText ms =
  Rhs
    { rhsRaw = RhsPanelText [TextMember n (askRaw a) | (n, a) <- members] pos0,
      rhsPlan = v,
      rhsForm = \k -> graftForm v k
    }
  where
    members = NE.toList ms
    v = P.panelText [(n, askAt @'CodeText a) | (n, a) <- members]

-- | @f <- decide lastNonEmptyLineIs t ["WORK COMPLETE"]@ — a pure
-- classification of the text bound to a handle, answering @flag@ (D7).
--
-- Taking a @'V' h 'CodeText@ makes \"a decider reads text\" a __type__ error at
-- the authoring surface, so @rhsPlan@'s kind refusal is a tier0-only refusal —
-- the discipline @tier1\/Cases.hs@ already states.
--
-- __It costs nothing in every fold, including @size@.__ Its value is a
-- 'Agentic.Plan.PRet', and @Plan.graft_ret@ says @graft (ret e) k = k _ Sub.id
-- e@, so the binding elaborates to the continuation with the value substituted
-- in and __no node at all__. The net effect of replacing an asked flag with a
-- decider is one fewer question on every path, the same number of paths, and
-- the same rung — which is what @vector-006@ and @vector-007@ pin as a pair.
decide ::
  forall h s.
  (KnownIx h s) =>
  Decider ->
  V h 'CodeText ->
  NonEmpty Text ->
  Rhs s 'CodeFlag
decide d v ws = decideI @s d (vName v) (readV @h @s v) ws

-- | 'decide' at an index rather than at a handle: the subject's name as it is
-- /printed/, and the de Bruijn index that /reads/ it.
decideI ::
  forall s.
  Decider ->
  Text ->
  Var (Codes s) 'CodeText ->
  NonEmpty Text ->
  Rhs s 'CodeFlag
decideI d x v ws =
  Rhs
    { rhsRaw = RhsDecide d x needles pos0,
      rhsPlan = value,
      rhsForm = \k -> graftForm value k
    }
  where
    needles = NE.toList ws
    value = PRet (\g -> runDecider d needles (varGet v g))

-- | A value call. Lean: @callPlan@ (@Check.lean:464@) — @Plan.sub@ of the
-- callee's plan along the argument list, so the callee's questions appear
-- inlined at the call site, in body order, with caller-evaluated arguments in
-- their prompts. No node is added.
callV :: Fn ps r -> Args s ps -> Rhs s r
callV f as =
  Rhs
    { rhsRaw = RhsCall (fnName (fnRaw f)) (argsRaw as) pos0,
      rhsPlan = v,
      rhsForm = \k -> graftForm v k
    }
  where
    v = callPlanOf f as

-- ---------------------------------------------------------------------------
-- Arguments
-- ---------------------------------------------------------------------------

-- | One argument at a call site, elaborated at the parameter's kind. Lean:
-- @argExpr@ (@Check.lean:406@).
data Arg (s :: Scope) (c :: Code) = Arg
  { argRaw :: RawArg,
    argExpr :: Expr (Codes s) (El c)
  }

-- | A binding in scope, which must answer the parameter's kind __exactly__ —
-- no silent rendering, so a verdict does not fill a @text@ parameter
-- (@battery-180@). The kind is the handle's, and the caller's parameter list is
-- what has to agree with it.
argName :: forall h s c. KnownIx h s => V h c -> Arg s c
argName v = argNameI @c @s (vName v) (readV @h @s v)

-- | 'argName' at an index rather than at a name.
argNameI :: forall c s. Text -> Var (Codes s) c -> Arg s c
argNameI x v = Arg (ArgName x pos0) (varGet v)

-- | Words, which fill a @text@ parameter and are elaborated in the /caller's/
-- bindings — so a hole here reads the caller's names.
argWords :: Words s -> Arg s 'CodeText
argWords ws = Arg (ArgLit (wordsRaw ws) pos0) (wordsExpr ws)

-- | The arguments of one call, in source order.
--
-- The cons is a named constructor and not an operator because the authoring
-- surface spells it @:>@ — 'Agentic.Workflow.Chain', one overloaded cons for
-- this chain and for a program's inputs — and an operator here would be a
-- second thing of that name. Everything below the surface builds and reads
-- 'ACons' itself.
data Args (s :: Scope) (ps :: [Code]) where
  ANil :: Args s '[]
  ACons :: Arg s c -> Args s cs -> Args s (c ': cs)

argsRaw :: Args s ps -> [RawArg]
argsRaw = \case
  ANil -> []
  ACons a as -> argRaw a : argsRaw as

-- | The calling convention, verbatim: Lean's @checkArgs@ (@Check.lean:433@)
-- folds the arguments left to right into the substitution the call runs along,
-- each consed onto the environment being built, starting from @Env.nil@.
-- Combined with 'ParamCtx''s reversal this puts each argument exactly where
-- its parameter's binding reads it.
--
-- The annotation on the accumulator is not decoration: @El@ is not injective,
-- so nothing else says at which code the argument is consed.
argSub ::
  forall s ps acc.
  Args s ps ->
  Sub acc (Codes s) ->
  Sub (ParamCtxGo ps acc) (Codes s)
argSub ANil sigma = sigma
argSub (ACons (a :: Arg s c) as) sigma =
  argSub as (subCons (argExpr a) sigma :: Sub (c ': acc) (Codes s))

-- ---------------------------------------------------------------------------
-- Functions
-- ---------------------------------------------------------------------------

-- | Lean's @paramCtx@ (@Check.lean:308@) is a /left/ fold, so a parameter list
-- is reversed into the context: for @(p₁ : c₁, p₂ : c₂)@ the context is
-- @c₂ ': c₁ ': '[]@ and @p₂@ is de Bruijn @0@.
type family ParamCtxGo (ps :: [Code]) (acc :: Ctx) :: Ctx where
  ParamCtxGo '[] acc = acc
  ParamCtxGo (c ': cs) acc = ParamCtxGo cs (c ': acc)

-- | @paramCtx@ itself.
type ParamCtx (ps :: [Code]) = ParamCtxGo ps '[]

-- | A parameter list: the codes @ps@ in __source__ order, the 'Scope' they push
-- onto @acc@ — which, by the same left fold, is their reverse — and @hs@, the
-- handles the body reads them through, nested in source order and ending in
-- @()@.
--
-- Lean: @paramBindings@ (@Check.lean:981@), which pushes the parameters in
-- source order so that the last one is de Bruijn @0@. A parameter is a binding
-- like any other, so it hands the body a 'V' like any other; @hs@ is that
-- tuple of handles, computed by the very fold that computes the scope.
data Params (ps :: [Code]) (acc :: Scope) (s :: Scope) (hs :: Type) where
  PNil :: Params '[] acc acc ()
  PCons ::
    (KnownSymbol n, KnownCode c, Fresh n acc) =>
    Proxy n ->
    SCode c ->
    Params cs ('(n, c) ': acc) s hs ->
    Params (c ': cs) acc s (V ('(n, c) ': acc) c, hs)

-- | The end of a parameter list.
noParams :: Params '[] acc acc ()
noParams = PNil

-- | One parameter, named and kinded: @param \@"goal" \@'CodeText noParams@.
param ::
  forall n c cs acc s hs.
  (KnownSymbol n, KnownCode c, Fresh n acc) =>
  Params cs ('(n, c) ': acc) s hs ->
  Params (c ': cs) acc s (V ('(n, c) ': acc) c, hs)
param = PCons (Proxy @n) (sCode @c)

-- | The parameters as printed: @[name, code]@ pairs in source order.
paramsRaw :: Params ps acc s hs -> [(Text, Code)]
paramsRaw = \case
  PNil -> []
  PCons p c rest -> (T.pack (symbolVal p), fromSCode c) : paramsRaw rest

-- | The handles the parameters bind, in source order: each at its own scope,
-- at index @0@, printing the name the list declared. The body reads them with
-- 'hole', 'argName' or 'answerB' exactly as it reads a binding of its own.
paramHandles :: Params ps acc s hs -> hs
paramHandles = \case
  PNil -> ()
  PCons p _ rest -> (V (T.pack (symbolVal p)) VHere, paramHandles rest)

-- | A checked function: what it prints, and its plan over exactly its
-- parameters. Lean: @FnEntry@ (@Check.lean:312@).
--
-- The table's stratification — a duplicate name refused, a call naming only an
-- earlier entry, hence no recursion — is Haskell's @let@: a 'Fn' value must
-- exist before it can be applied.
data Fn (ps :: [Code]) (r :: Code) = Fn
  { fnRaw :: RawFn,
    fnPlan :: Plan (ParamCtx ps) (El r)
  }

-- | One function. Lean: @checkFn@ (@Check.lean:1072@) — a body is checked
-- __once__, over exactly its parameters, and "a body cannot see the caller" is
-- the type and not a rule.
--
-- The body is a function of the parameters' handles, in source order:
--
-- > function "lib.drafted" (param @"goal" @'CodeText noParams) $ \(goal, ()) ->
-- >   bindB @"d" @'CodeText (one (askModel "author" [lit "draft: ", hole goal])) $ \d ->
-- >     answerB d
--
-- The name is a plain 'Text' because it is /printed/ and nothing else: the
-- call sites below name a 'Fn' value, not a string.
function ::
  forall ps r s hs.
  (KnownCode r, Codes s ~ ParamCtx ps) =>
  Text ->
  Params ps '[] s hs ->
  (hs -> Body s r) ->
  Fn ps r
function nm ps body =
  Fn
    { fnRaw =
        RawFn
          { fnName = nm,
            fnParams = paramsRaw ps,
            fnResult = fromSCode (sCode @r),
            fnBody = bodyRaw b,
            fnAnswer = bodyAnswer b,
            fnAnswerPos = pos0,
            fnPos = pos0
          },
      fnPlan = bodyPlan b
    }
  where
    b = body (paramHandles ps)

-- | A call's plan: the callee's, read through its arguments.
callPlanOf :: forall ps r s. Fn ps r -> Args s ps -> Plan (Codes s) (El r)
callPlanOf f as = subP (fnPlan f) (argSub as (const ENil :: Sub '[] (Codes s)))

-- ---------------------------------------------------------------------------
-- Function bodies
-- ---------------------------------------------------------------------------

-- | A function body: the statements it prints, the @answer@ it names, and the
-- plan it elaborates to. Lean: @checkBody@ (@Check.lean:1014@).
--
-- A body has no branching and no loop — @RawBodyStmt@ has no such
-- constructors, and neither has this type. A function is a reusable sequence
-- of questions, not a reusable decision.
data Body (s :: Scope) (r :: Code) = Body
  { bodyRaw :: [RawBodyStmt],
    -- | @answer x@ for a value function; 'Nothing' for a @-> receipt@ one.
    bodyAnswer :: Maybe Text,
    bodyPlan :: Plan (Codes s) (El r)
  }

-- | @x <- …@ in a body; prints @ann = null@. The rest of the body is a
-- function of the handle this binding hands it.
bindB ::
  forall n c s r.
  (KnownSymbol n, Fresh n s, KnownCode c) =>
  Rhs s c ->
  (V ('(n, c) ': s) c -> Body ('(n, c) ': s) r) ->
  Body s r
bindB rhs rest = bindBI @n (nameText @n) rhs (rest (hereV @n))

-- | 'bindB' at an index: the name as it is printed, the scope entry it pushes
-- left to the continuation's type.
bindBI ::
  forall n c s r.
  Text ->
  Rhs s c ->
  Body ('(n, c) ': s) r ->
  Body s r
bindBI x rhs rest =
  Body
    { bodyRaw = BodyBind x Nothing (rhsRaw rhs) pos0 : bodyRaw rest,
      bodyAnswer = bodyAnswer rest,
      bodyPlan = rhsForm rhs (bodyPlan rest)
    }

-- | @x : c <- …@ in a body; prints @ann = c@.
bindAsB ::
  forall n c s r.
  (KnownSymbol n, Fresh n s, KnownCode c) =>
  Rhs s c ->
  (V ('(n, c) ': s) c -> Body ('(n, c) ': s) r) ->
  Body s r
bindAsB rhs rest = bindAsBI @n (sCode @c) (nameText @n) rhs (rest (hereV @n))

-- | 'bindAsB' at an index. The 'SCode' is what the annotation prints.
bindAsBI ::
  forall n c s r.
  SCode c ->
  Text ->
  Rhs s c ->
  Body ('(n, c) ': s) r ->
  Body s r
bindAsBI c x rhs rest =
  Body
    { bodyRaw =
        BodyBind x (Just (fromSCode c)) (rhsRaw rhs) pos0
          : bodyRaw rest,
      bodyAnswer = bodyAnswer rest,
      bodyPlan = rhsForm rhs (bodyPlan rest)
    }

-- | A statement-position ask in a body: an ask at @receipt@ whose slot the
-- continuation immediately weakens past. See 'act'.
actB :: Ask s -> Body s r -> Body s r
actB a rest =
  Body
    { bodyRaw = BodyAct (askRaw a) pos0 : bodyRaw rest,
      bodyAnswer = bodyAnswer rest,
      bodyPlan = askNode @'CodeAck a (weakenP (bodyPlan rest))
    }

-- | A statement call in a body. Only a @-> receipt@ function may stand here,
-- and it adds __no__ context slot (contrast 'actB').
callSB :: Fn ps 'CodeAck -> Args s ps -> Body s r -> Body s r
callSB f as rest =
  Body
    { bodyRaw = BodyCallS (fnName (fnRaw f)) (argsRaw as) pos0 : bodyRaw rest,
      bodyAnswer = bodyAnswer rest,
      bodyPlan =
        graft (callPlanOf f as) (Cont (\sigma _ -> subP (bodyPlan rest) sigma))
    }

-- | @answer x@: 'PRet' of @x@'s expression, at the kind the function declares.
-- The declared result /is/ the handle's kind, which is @checkFn@'s @b.at?
-- f.result@ made structural.
answerB :: forall h s c. KnownIx h s => V h c -> Body s c
answerB v = answerBI @c @s (vName v) (readV @h @s v)

-- | 'answerB' at an index: the name as it is printed, and the index that reads
-- it. The function's result kind is that index's kind.
answerBI :: forall c s. Text -> Var (Codes s) c -> Body s c
answerBI x v =
  Body
    { bodyRaw = [],
      bodyAnswer = Just x,
      bodyPlan = PRet (varGet v)
    }

-- | The end of a @-> receipt@ body: @PRet (const ())@, and no @answer@.
endB :: Body s 'CodeAck
endB = Body {bodyRaw = [], bodyAnswer = Nothing, bodyPlan = PRet (const ())}

-- ---------------------------------------------------------------------------
-- Blocks
-- ---------------------------------------------------------------------------

-- | A block: the 'Raw' it prints and the 'Plan' it elaborates to. Every
-- combinator below takes the rest of the block as its last argument, so a
-- program is a @$@-chain that reads in source order — which is @RawBlock@'s
-- @rest@ field exactly.
data Blk (s :: Scope) = Blk
  { blkRaw :: Raw,
    blkPlan :: Plan (Codes s) ()
  }

-- | @stop@, and the end of a block. Lean: @.empty _ => .ok (.ret fun _ => ())@.
stop :: Blk s
stop = Blk (RawEmpty pos0) (PRet (const ()))

-- | @x <- …@; prints @ann = null@.
--
-- Lean (@Check.lean:782@): __one__ node at the imposed kind, whose
-- continuation is the rest of the block checked with @x@ pushed at index @0@.
-- Nothing else. Where Lean infers the kind from the first ground use
-- (@bindKind@ / @useKindB@), the author supplies it at the type level; the
-- printed annotation is a separate decision, and a wrong pairing is caught
-- twice by tier1 — the printed Raw still matches, but the trace's @code@ and
-- the world's answer diverge from the frozen reply.
bind ::
  forall n c s.
  (KnownSymbol n, Fresh n s, KnownCode c) =>
  Rhs s c ->
  (V ('(n, c) ': s) c -> Blk ('(n, c) ': s)) ->
  Blk s
bind rhs rest = bindI @n (nameText @n) rhs (rest (hereV @n))

-- | 'bind' at an index: the name as it is printed, the scope entry it pushes
-- left to the continuation's type.
bindI :: forall n c s. Text -> Rhs s c -> Blk ('(n, c) ': s) -> Blk s
bindI x rhs rest =
  Blk
    (RawBind x Nothing (SrcRhs (rhsRaw rhs)) (blkRaw rest) pos0)
    (rhsForm rhs (blkPlan rest))

-- | @x : c <- …@; prints @ann = c@. Same elaboration as 'bind' — an
-- annotation grounds inference, it does not change the term.
bindAs ::
  forall n c s.
  (KnownSymbol n, Fresh n s, KnownCode c) =>
  Rhs s c ->
  (V ('(n, c) ': s) c -> Blk ('(n, c) ': s)) ->
  Blk s
bindAs rhs rest = bindAsI @n (sCode @c) (nameText @n) rhs (rest (hereV @n))

-- | 'bindAs' at an index. The 'SCode' is what the annotation prints.
bindAsI :: forall n c s. SCode c -> Text -> Rhs s c -> Blk ('(n, c) ': s) -> Blk s
bindAsI c x rhs rest =
  Blk
    ( RawBind
        x
        (Just (fromSCode c))
        (SrcRhs (rhsRaw rhs))
        (blkRaw rest)
        pos0
    )
    (rhsForm rhs (blkPlan rest))

-- | The act: a statement-position ask.
--
-- Lean (@Check.lean:757@): an ask at @Code.ack@ whose answer occupies a
-- context slot that the continuation immediately weakens past — the rest of
-- the block is checked in @Γ@ and then read into @ack :: Γ@ by @Sub.wk@. So
-- the act binds nothing /and/ still adds one binder to the de Bruijn spine.
-- The continuation's scope is therefore unchanged (@s@ on both sides), while
-- its plan is weakened; 'subP' pushes that weakening into every splice after
-- the act, which is what makes @battery-115@ ("names straddling an act") come
-- out right.
--
-- Trace consequence: the event's code is @receipt@ and its answer is @null@.
act :: Ask s -> Blk s -> Blk s
act a rest =
  Blk
    (RawAct (askRaw a) (blkRaw rest) pos0)
    (askNode @'CodeAck a (weakenP (blkPlan rest)))

-- | A statement call: @Plan.graft p (fun _ σ _ => Plan.sub k σ)@
-- (@Check.lean:778@). The answer is discarded and __no__ context slot is
-- added — the contrast with 'act' is deliberate and is what @battery-144@
-- pins. Only a @-> receipt@ function may stand here, which is the type.
callStmt :: Fn ps 'CodeAck -> Args s ps -> Blk s -> Blk s
callStmt f as rest =
  Blk
    (RawCallStmt (fnName (fnRaw f)) (argsRaw as) (blkRaw rest) pos0)
    (graft (callPlanOf f as) (Cont (\sigma _ -> subP (blkPlan rest) sigma)))

-- | @if x { … } else { … }@.
--
-- Lean (@Check.lean:830@): one @case@ at 'Bool' via @caseB@, both arms in the
-- term, each arm the rest of the workflow in the __same__ context with the
-- __same__ names. No binder is added — the flag is read through the existing
-- variable.
ifFlag ::
  forall h s.
  KnownIx h s =>
  V h 'CodeFlag ->
  Blk s ->
  Blk s ->
  Blk s
ifFlag v yes no = ifFlagI (vName v) (readV @h @s v) yes no

-- | 'ifFlag' at an index.
ifFlagI :: forall s. Text -> Var (Codes s) 'CodeFlag -> Blk s -> Blk s -> Blk s
ifFlagI x v yes no =
  Blk
    (RawIfFlag x (blkRaw yes) (blkRaw no) pos0)
    (caseB (varGet v) (blkPlan yes) (blkPlan no))

-- | @case x { approved … objected … no answer … }@.
--
-- Lean (@Check.lean:846@): one @case@ at @VTag@ via @caseV@, whose scrutinee
-- is @Verdict.tag@ of the name. The verdict itself stays readable in every arm
-- — the tag decides the shape, the objections ride in the environment.
caseVerdict ::
  forall h s.
  KnownIx h s =>
  V h 'CodeVerdict ->
  Blk s ->
  Blk s ->
  Blk s ->
  Blk s
caseVerdict v approved objected noAnswer =
  caseVerdictI (vName v) (readV @h @s v) approved objected noAnswer

-- | 'caseVerdict' at an index.
caseVerdictI ::
  forall s.
  Text ->
  Var (Codes s) 'CodeVerdict ->
  Blk s ->
  Blk s ->
  Blk s ->
  Blk s
caseVerdictI x v approved objected noAnswer =
  Blk
    ( RawCaseVerdict
        x
        (blkRaw approved)
        (blkRaw objected)
        (blkRaw noAnswer)
        pos0
    )
    (caseV (varGet v) arms)
  where
    arms = \case
      VApprove -> blkPlan approved
      VObject -> blkPlan objected
      VDeclined -> blkPlan noAnswer

-- | @known here: …@ — an assertion, and __no node at all__.
--
-- Lean (@Check.lean:749@): a checked @known here@ elaborates to the rest of
-- the block, unchanged, in the same context; it contributes no binder, no
-- event, and does not appear in @size@. The names it prints are computed from
-- the type-level scope, innermost first, so a rebuilt case cannot print a
-- wrong one. @known here: nothing@ is what an empty scope computes.
knownHere :: forall s. KnownScope s => Blk s -> Blk s
knownHere rest = knownHereI (scopeNames @s) rest

-- | 'knownHere' at an index. __The names are not checked against anything__:
-- at the type level they are computed from the scope and cannot be wrong,
-- here they are the caller's assertion, and Lean refuses a wrong one. Pass the
-- live names, innermost first.
knownHereI :: forall s. [Text] -> Blk s -> Blk s
knownHereI names rest =
  Blk (RawKnownHere names (blkRaw rest) pos0) (blkPlan rest)

-- ---------------------------------------------------------------------------
-- The bounded revision
-- ---------------------------------------------------------------------------

-- | The review clause's continuation: the candidate under review is de Bruijn
-- @0@. Lean: @checkCont@ (@Check.lean:591@).
checkCont :: Plan (c ': g) Verdict -> Cont g (El c) Verdict
checkCont chk = Cont (\sigma a -> subP chk (subCons a sigma))

-- | The amend clause's continuation: the review's verdict is de Bruijn @0@ and
-- the candidate is @1@. Lean: @reviseCont@ (@Check.lean:598@).
reviseCont :: Plan ('CodeVerdict ': c ': g) (El c) -> Cont g (El c, Verdict) (El c)
reviseCont rev =
  Cont (\sigma av -> subP rev (subCons (snd . av) (subCons (fst . av) sigma)))

-- | The outcomes of a bounded revision, generalised over the exit tag: a @case@
-- on the ending the loop reports, with __the candidate reaching every arm__ as
-- de Bruijn @0@. Lean: @exitCont@ (@Check.lean:618@).
--
-- Written once and instantiated twice — at 'TBool' for @revising@'s two endings
-- (D3) and at 'TEnding' for @revising on@'s three (D4) — because the two want
-- the same continuation at two different tags.
--
-- @finishCont acc exh@ used to be here and is @exitCont TBool (\\b -> if b then
-- acc else exh)@; since @Plan.caseB e t f = .case .bool e (fun b => cond b t
-- f)@, __the emitted node, its tag and its arm order are literally
-- unchanged__, and @tagValues TBool = [False, True]@ keeps arm 0 the unsettled
-- arm and arm 1 the settled one. The one real difference: __both__ arms are now
-- @Plan (c ': g) ()@ and both are substituted with the candidate, where the
-- unsettled arm used to be @subP exh sigma@ at @g@ and the settled arm read a
-- 'defaultEl' no run ever saw. That is why 'KnownCode' is gone from here.
exitCont ::
  forall t c g.
  Tag t ->
  (t -> Plan (c ': g) ()) ->
  Cont g (El c, t) ()
exitCont t arms =
  Cont
    ( \sigma final ->
        PCase t (snd . final) (\x -> subP (arms x) (subCons (fst . final) sigma))
    )

-- | @x <- revising subj as carrier, at most n amendments { … }@ together with
-- the @case x { settled p { … } unsettled { … } }@ that consumes it — __one__
-- combinator, because the intermediate has type @Plan Γ (El c, Bool)@ and
-- @Ctx@ has no code for a candidate-and-ending pair. Lean carries it as a
-- @Pend Γ@
-- (@Check.lean:639@) that the very next statement must consume, and refuses
-- every other statement by name while it is pending; here the pairing is the
-- combinator's shape.
--
-- Elaboration (@Check.lean:814@ and @702@, @Plan.lean:1056@):
--
-- * the candidate's kind is the __subject's__ kind, so it is the subject
--   handle's and not a choice;
-- * the review is elaborated at @verdict@ with the candidate at index @0@
--   under the carrier's name; it may be an ask, a panel or a call;
-- * the amend is elaborated at the candidate's kind with the review's verdict
--   at index @0@ (under the review binding's name) and the candidate at @1@;
-- * the unroll is check-first: at bound @n@ there are @n+1@ checks and at most
--   @n@ amendments, each round's @caseB@ testing @Verdict.approvedB@ —
--   approval /exactly/, so a refusal is not a settlement — and the last round
--   has no @caseB@ and no amend at all;
-- * the whole loop is grafted with 'exitCont' at 'TBool', which replicates
--   both arms once per exit of the unroll. That replication is the
--   @(n+1)*(st+un)@ term of @blockAsks@ and the reason @vector-002@ reaches
--   size 92.
--
-- The 'Text' argument is the loop result's name: it is printed in the
-- 'RawBind' and in the 'RawCaseResult' and appears nowhere else, the result
-- never entering a scope.
--
-- __One deliberate strengthening.__ Lean checks @carrier@ and @rname@ for
-- freshness against the enclosing scope only, so it admits a program where the
-- two are the /same/ name — and resolves such a hole to the carrier, because
-- @Swith@ lists the carrier first even though the context binds the review
-- innermost. This builder refuses that program instead of resolving it
-- differently: @Fresh rev ('(carrier, c) ': s)@. No corpus entry writes one.
revisingCase ::
  forall carrier rev settled unsettled h s c.
  ( KnownSymbol carrier,
    KnownSymbol rev,
    KnownSymbol settled,
    KnownSymbol unsettled,
    KnownIx h s,
    Fresh carrier s,
    Fresh rev ('(carrier, c) ': s),
    Fresh settled s,
    Fresh unsettled s
  ) =>
  -- | the subject, whose kind the candidate's is
  V h c ->
  -- | the loop result's name, printed only
  Text ->
  -- | the bound: @0 <= n <= 64@ (Lean's @maxRevisions@)
  Integer ->
  -- | the review's printed annotation: 'Nothing' or @Just 'CodeVerdict'@
  Maybe Code ->
  -- | the review, at @verdict@, seeing the candidate as the carrier
  ( V ('(carrier, c) ': s) c ->
    Rhs ('(carrier, c) ': s) 'CodeVerdict
  ) ->
  -- | the amend, at the candidate's kind, seeing the verdict and the candidate
  ( V ('(carrier, c) ': s) c ->
    V ('(rev, 'CodeVerdict) ': '(carrier, c) ': s) 'CodeVerdict ->
    Rhs ('(rev, 'CodeVerdict) ': '(carrier, c) ': s) c
  ) ->
  -- | the settled arm, with the artefact bound
  ( V ('(settled, c) ': s) c ->
    Blk ('(settled, c) ': s)
  ) ->
  -- | the unsettled arm, with the last candidate bound
  ( V ('(unsettled, c) ': s) c ->
    Blk ('(unsettled, c) ': s)
  ) ->
  Blk s
revisingCase subj resultName n reviewAnn review amend settled unsettled =
  revisingCaseI @c @carrier @rev @settled @unsettled @s
    (vName subj)
    (readV @h @s subj)
    (nameText @carrier)
    (nameText @rev)
    (nameText @settled)
    (nameText @unsettled)
    resultName
    n
    reviewAnn
    (review carrierV)
    (amend carrierV (hereV @rev))
    (settled (hereV @settled))
    (unsettled (hereV @unsettled))
  where
    carrierV = hereV @carrier @c @s

-- | 'revisingCase' at an index: the four names as they are /printed/, and the
-- de Bruijn index that reads the subject. Every scope entry the clauses see is
-- left to their types, so the phantom symbols @nc@, @nr@ and @ns@ are free —
-- an index-level caller threads its own name supply and its own freshness.
--
-- The two @error@ guards are 'revisingCase'\'s, unchanged: a bound outside
-- @0 <= n <= 64@ and a review annotation other than @verdict@ are refusals, not
-- programs.
revisingCaseI ::
  forall c nc nr ns nu s.
  -- | the subject's name, as printed
  Text ->
  -- | the index that reads the subject
  Var (Codes s) c ->
  -- | the carrier's name
  Text ->
  -- | the review binding's name
  Text ->
  -- | the settled binder's name
  Text ->
  -- | the unsettled binder's name — it may be the settled one, because the two
  -- bind in disjoint arms, and an authoring surface that builds both arms at
  -- the same depth always makes them coincide
  Text ->
  -- | the loop result's name, printed only
  Text ->
  -- | the bound: @0 <= n <= 64@ (Lean's @maxRevisions@)
  Integer ->
  -- | the review's printed annotation: 'Nothing' or @Just 'CodeVerdict'@
  Maybe Code ->
  -- | the review, at @verdict@, seeing the candidate as the carrier
  Rhs ('(nc, c) ': s) 'CodeVerdict ->
  -- | the amend, at the candidate's kind, seeing the verdict and the candidate
  Rhs ('(nr, 'CodeVerdict) ': '(nc, c) ': s) c ->
  -- | the settled arm, with the artefact bound
  Blk ('(ns, c) ': s) ->
  -- | the unsettled arm, with the last candidate bound
  Blk ('(nu, c) ': s) ->
  Blk s
revisingCaseI
  subjName
  subjVar
  carrierName
  revName
  settledName
  unsettledName
  resultName
  n
  reviewAnn
  review
  amend
  settled
  unsettled
    | n < 0 || n > 64 =
        error
          -- Not a [wft|...|]: Agentic.WF imports this module, so importing the quoter here is a module cycle.
          ( "revisingCase: a bounded revision is unrolled into the term it \
            \writes, so its bound may name at most 64 amendments, and not "
              ++ show n
          )
    | reviewAnn `notElem` [Nothing, Just CodeVerdict] =
        error
          -- Not a [wft|...|]: Agentic.WF imports this module, so importing the quoter here is a module cycle.
          "revisingCase: a review answers `verdict`, not anything else: the loop \
          \settles when it approves"
    | otherwise = Blk raw plan
  where
    raw =
      RawBind
        resultName
        Nothing
        ( SrcRevising
            subjName
            carrierName
            n
            revName
            reviewAnn
            (rhsRaw review)
            (rhsRaw amend)
            pos0
        )
        ( RawCaseResult
            resultName
            settledName
            unsettledName
            (blkRaw settled)
            (blkRaw unsettled)
            pos0
        )
        pos0

    -- Lean: `Plan.revising (checkCont reviewP) (reviseCont amendP) n Γ Sub.id
    -- b.val` — the loop's Cont, applied at the block's own context, along the
    -- identity, to the subject's expression. The candidate is re-read through
    -- the accumulated substitutions at every round, never re-asked.
    --
    -- The type applications are forced: `Plan.revising`'s two type arguments
    -- appear only under `El`, which is not injective, so nothing at this call
    -- site determines `c` by unification.
    loop :: Plan (Codes s) (El c, Bool)
    loop =
      runCont
        (revising @c @(Codes s) (checkCont (rhsPlan review)) (reviseCont (rhsPlan amend)) n)
        subId
        (varGet subjVar)

    plan =
      graft
        loop
        (exitCont TBool (\b -> if b then blkPlan settled else blkPlan unsettled))

-- | @x <- revising on subj as carrier, at most n amendments { … }@ together
-- with the @case x { settled p { … } unsettled q { … } abandoned t { … } }@
-- that consumes it (D4) — one combinator, for the reason 'revisingCase' is one.
--
-- The loop is 'revisingCase''s in every respect but how it reads its verdict:
-- approval settles, an objection buys another trip, and a refusal __abandons__
-- the loop at once instead of spending a trip on it. Its unroll therefore has
-- @2n+1@ @ret@ leaves rather than @n+1@ — the approve-@ret@ and the
-- declined-@ret@ per round above the base — and the three-armed exit is
-- replicated once per leaf, which is the @(2n+1)*(st+un+ab)@ term of
-- @blockAsks@ and the reason a @revising on@ with a wide tail reaches the
-- affordability refusal at roughly half the bound a @revising@ does.
revisingOnCase ::
  forall carrier rev settled unsettled abandoned h s c.
  ( KnownSymbol carrier,
    KnownSymbol rev,
    KnownSymbol settled,
    KnownSymbol unsettled,
    KnownSymbol abandoned,
    KnownIx h s,
    Fresh carrier s,
    Fresh rev ('(carrier, c) ': s),
    Fresh settled s,
    Fresh unsettled s,
    Fresh abandoned s
  ) =>
  -- | the subject, whose kind the candidate's is
  V h c ->
  -- | the loop result's name, printed only
  Text ->
  -- | the bound: @0 <= n <= 64@
  Integer ->
  -- | the review's printed annotation
  Maybe Code ->
  -- | the review, at @verdict@, seeing the candidate as the carrier
  ( V ('(carrier, c) ': s) c ->
    Rhs ('(carrier, c) ': s) 'CodeVerdict
  ) ->
  -- | the amend, at the candidate's kind
  ( V ('(carrier, c) ': s) c ->
    V ('(rev, 'CodeVerdict) ': '(carrier, c) ': s) 'CodeVerdict ->
    Rhs ('(rev, 'CodeVerdict) ': '(carrier, c) ': s) c
  ) ->
  -- | the settled arm
  (V ('(settled, c) ': s) c -> Blk ('(settled, c) ': s)) ->
  -- | the unsettled arm
  (V ('(unsettled, c) ': s) c -> Blk ('(unsettled, c) ': s)) ->
  -- | the abandoned arm
  (V ('(abandoned, c) ': s) c -> Blk ('(abandoned, c) ': s)) ->
  Blk s
revisingOnCase subj resultName n reviewAnn review amend settled unsettled abandoned =
  revisingOnCaseI @c @carrier @rev @settled @unsettled @abandoned @s
    (vName subj)
    (readV @h @s subj)
    (nameText @carrier)
    (nameText @rev)
    (nameText @settled)
    (nameText @unsettled)
    (nameText @abandoned)
    resultName
    n
    reviewAnn
    (review carrierV)
    (amend carrierV (hereV @rev))
    (settled (hereV @settled))
    (unsettled (hereV @unsettled))
    (abandoned (hereV @abandoned))
  where
    carrierV = hereV @carrier @c @s

-- | 'revisingOnCase' at an index: the six names as they are /printed/, and the
-- de Bruijn index that reads the subject.
revisingOnCaseI ::
  forall c nc nr ns nu na s.
  Text ->
  Var (Codes s) c ->
  Text ->
  Text ->
  Text ->
  Text ->
  Text ->
  Text ->
  Integer ->
  Maybe Code ->
  Rhs ('(nc, c) ': s) 'CodeVerdict ->
  Rhs ('(nr, 'CodeVerdict) ': '(nc, c) ': s) c ->
  Blk ('(ns, c) ': s) ->
  Blk ('(nu, c) ': s) ->
  Blk ('(na, c) ': s) ->
  Blk s
revisingOnCaseI
  subjName
  subjVar
  carrierName
  revName
  settledName
  unsettledName
  abandonedName
  resultName
  n
  reviewAnn
  review
  amend
  settled
  unsettled
  abandoned
    | n < 0 || n > 64 =
        error
          -- Not a [wft|...|]: Agentic.WF imports this module, so importing the quoter here is a module cycle.
          ( "revisingOnCase: a bounded revision is unrolled into the term it \
            \writes, so its bound may name at most 64 amendments, and not "
              ++ show n
          )
    | reviewAnn `notElem` [Nothing, Just CodeVerdict] =
        error
          -- Not a [wft|...|]: Agentic.WF imports this module, so importing the quoter here is a module cycle.
          "revisingOnCase: a review answers `verdict`, not anything else: the \
          \loop reads its three tags"
    | otherwise = Blk raw plan
  where
    raw =
      RawBind
        resultName
        Nothing
        ( SrcRevisingOn
            subjName
            carrierName
            n
            revName
            reviewAnn
            (rhsRaw review)
            (rhsRaw amend)
            pos0
        )
        ( RawCaseEnding
            resultName
            settledName
            unsettledName
            abandonedName
            (blkRaw settled)
            (blkRaw unsettled)
            (blkRaw abandoned)
            pos0
        )
        pos0

    loop :: Plan (Codes s) (El c, Ending)
    loop =
      runCont
        ( revisingOn @c @(Codes s)
            (checkCont (rhsPlan review))
            (reviseCont (rhsPlan amend))
            n
        )
        subId
        (varGet subjVar)

    plan =
      graft
        loop
        ( exitCont TEnding $ \e -> case e of
            EndSettled -> blkPlan settled
            EndUnsettled -> blkPlan unsettled
            EndAbandoned -> blkPlan abandoned
        )

-- ---------------------------------------------------------------------------
-- Programs
-- ---------------------------------------------------------------------------

-- | A function of forgotten arity, for the table.
data SomeFn where
  SomeFn :: Fn ps r -> SomeFn

-- | A whole program after the import walk: what it prints, and what it means.
data Program = Program
  { progRawOut :: RawProgram,
    progPlan :: Plan '[] ()
  }

-- | The function table in declaration order, and the workflow.
program :: [SomeFn] -> Blk '[] -> Program
program fns b =
  Program
    { progRawOut = RawProgram [fnRaw f | SomeFn f <- fns] (blkRaw b),
      progPlan = blkPlan b
    }

-- ---------------------------------------------------------------------------
-- A note on the index-level entry points
-- ---------------------------------------------------------------------------

-- $indexLevel
--
-- A /binder/ above still names its binding as a 'Symbol' — that is what
-- 'Fresh' compares and what 'KnownScope' lists — and turns it into exactly two
-- runtime things: the 'Text' the printer writes and the 'V' it hands the rest
-- of the block. A /mention/ names nothing at the type level at all: it is the
-- handle, and a mistyped one is GHC's own @Variable not in scope@ at the site
-- that wrote it.
--
-- A /runtime/ producer of programs — the property generators of
-- @Agentic.Gen@ — cannot conjure a 'Symbol', and cannot discharge 'Fresh' for
-- one it conjured. So each binder has an @I@-suffixed twin that takes the
-- 'Text' directly and leaves the scope entry it pushes as a free type
-- variable, and each mention has one that takes the 'Text' and the 'Var'
-- directly: 'bindI', 'bindAsI', 'bindBI', 'bindAsBI', 'answerBI', 'holeI',
-- 'argNameI', 'ifFlagI', 'caseVerdictI', 'knownHereI', 'revisingCaseI'.
--
-- __The twin is the definition and the named form is the wrapper__, in every
-- case: @hole@ /is/ @holeI@ applied to a handle's two fields, @bind@ /is/
-- @bindI@ applied to @nameText@, and so on down the list. There is therefore
-- one elaboration in this module and not two, and a property that drives the
-- @I@ forms is testing the same print-and-elaborate linkage that tier1 drives
-- through the handle forms.
--
-- __What the caller now owes.__ The @I@ forms trade compile-time refusals for
-- obligations: names must be fresh along a path ('Fresh'), @known here@ must
-- list the live names innermost first ('KnownScope'), and a binding must be
-- read at the kind it was bound at (that one survives, in the 'Var'\'s index).
-- Lean still checks all three, so a generator that breaks one produces a
-- program the oracle refuses and the Haskell side accepts — a divergence
-- report about the generator rather than about the port.
