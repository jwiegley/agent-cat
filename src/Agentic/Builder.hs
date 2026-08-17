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
-- (@Check.lean:67@) is a list from name to code, extended by @Bindings.push@,
-- with shadowing refused by @freshName@; 'Scope' is that list at the type
-- level, 'Fresh' is @freshName@, 'LookupC' is @Bindings.find?@ and 'KnownVar'
-- is the @Expr.var@ that @push@'s repeated @Sub.wk@ leaves behind — one
-- 'VThere' per entry stepped over. No weakening is ever written by hand.
module Agentic.Builder
  ( -- * The four answer kinds
    -- | Re-exported from "Agentic.Raw" so that a module of rebuilt cases needs
    -- no other import: every combinator below is applied at a promoted 'Code'.
    Code (..),

    -- * The typed scope
    Entry,
    Scope,
    Codes,
    LookupC,
    KnownVar (..),
    nameExpr,
    Fresh,
    KnownScope (..),

    -- * Words
    Piece (..),
    Words,
    lit,
    hole,
    Spliceable (..),
    wordsRaw,
    wordsExpr,
    wordsClosed,

    -- * Questions
    Ask (..),
    askModel,
    askModelServed,
    askTool,
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
    callV,

    -- * Arguments and functions
    Arg (..),
    argName,
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
    bindAsB,
    actB,
    callSB,
    answerB,
    endB,

    -- * Blocks
    Blk (..),
    stop,
    bind,
    bindAs,
    act,
    callStmt,
    ifFlag,
    caseVerdict,
    knownHere,
    revisingCase,

    -- * Programs
    Program (..),
    SomeFn (..),
    program,

    -- * The pos rule
    pos0,
    zeroPos,
  )
where

import Agentic.Plan hiding (panel)
import qualified Agentic.Plan as P
import Agentic.Raw
  ( Addressee (..),
    Chunk (..),
    Code (..),
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
  )
import Data.Kind (Constraint)
import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NE
import Data.Maybe (fromMaybe, isJust)
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
-- Lean: @Binding Γ@ (@Check.lean:67@) minus its @val@ field, which 'KnownVar'
-- recovers from the position of the entry in the list.
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

-- | Symbol equality as a closed family, so name resolution can dispatch on it
-- without overlapping instances. Two distinct literals are apart, which is all
-- a concrete program needs.
type family SymEq (n :: Symbol) (m :: Symbol) :: Bool where
  SymEq n n = 'True
  SymEq n m = 'False

-- | The kind a name stands for. Innermost wins, by the non-linear first
-- clause; an unbound name is a type error that names it.
--
-- Lean: @Bindings.find?@ (@Check.lean:89@, @List.find?@ so innermost-first)
-- plus the @unbound@ diagnosis (@Check.lean:99@).
type family LookupC (n :: Symbol) (s :: Scope) :: Code where
  LookupC n ('(n, c) ': s) = c
  LookupC n ('(m, d) ': s) = LookupC n s
  LookupC n '[] =
    TypeError
      ( 'Text "unbound name; nothing in scope answers to `"
          ':<>: 'Text n
          ':<>: 'Text "`"
      )

-- | The de Bruijn index that reads a name.
--
-- Lean: @Bindings.push@ (@Check.lean:94@) gives the new name @Expr.var .here@
-- and renames every older one along @Sub.wk@; the instance walk below is that
-- renaming, one 'VThere' per entry stepped over.
class KnownVar (n :: Symbol) (s :: Scope) where
  varOf :: Var (Codes s) (LookupC n s)

-- | The boolean-dispatched worker of 'KnownVar'.
class KnownVar' (eq :: Bool) (n :: Symbol) (s :: Scope) where
  varOf' :: Var (Codes s) (LookupC n s)

instance (m ~ n, LookupC n ('(m, c) ': s) ~ c) => KnownVar' 'True n ('(m, c) ': s) where
  varOf' = VHere

instance
  (KnownVar n s, LookupC n ('(m, d) ': s) ~ LookupC n s) =>
  KnownVar' 'False n ('(m, d) ': s)
  where
  varOf' = VThere (varOf @n @s)

instance KnownVar' (SymEq n m) n ('(m, d) ': s) => KnownVar n ('(m, d) ': s) where
  varOf = varOf' @(SymEq n m) @n @('(m, d) ': s)

-- | Reading a name, as an expression. Lean: @Binding.val@.
nameExpr :: forall n s. KnownVar n s => Expr (Codes s) (El (LookupC n s))
nameExpr = varGet (varOf @n @s)

-- | The name, as the printer writes it.
nameText :: forall n. KnownSymbol n => Text
nameText = T.pack (symbolVal (Proxy @n))

-- | No shadowing, as a constraint. Lean: @freshName@ (@Check.lean:111@),
-- whose refusal this reproduces verbatim.
type family Fresh (n :: Symbol) (s :: Scope) :: Constraint where
  Fresh n '[] = ()
  Fresh n ('(n, c) ': s) =
    TypeError
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
  RhsCall f as _ -> RhsCall f (map zeroArg as) pos0

zeroSource :: RawSource -> RawSource
zeroSource = \case
  SrcRhs r -> SrcRhs (zeroRhs r)
  SrcRevising subj carrier n rname rann review amend _ ->
    SrcRevising subj carrier n rname rann (zeroRhs review) (zeroRhs amend) pos0

zeroRaw :: Raw -> Raw
zeroRaw = \case
  RawEmpty _ -> RawEmpty pos0
  RawBind x ann src rest _ -> RawBind x ann (zeroSource src) (zeroRaw rest) pos0
  RawAct a rest _ -> RawAct (zeroAsk a) (zeroRaw rest) pos0
  RawIfFlag x y n _ -> RawIfFlag x (zeroRaw y) (zeroRaw n) pos0
  RawCaseVerdict x a o d _ ->
    RawCaseVerdict x (zeroRaw a) (zeroRaw o) (zeroRaw d) pos0
  RawCaseResult x sname st un _ ->
    RawCaseResult x sname (zeroRaw st) (zeroRaw un) pos0
  RawKnownHere names rest _ -> RawKnownHere names (zeroRaw rest) pos0
  RawCallStmt f as rest _ -> RawCallStmt f (map zeroArg as) (zeroRaw rest) pos0

-- ---------------------------------------------------------------------------
-- Words
-- ---------------------------------------------------------------------------

-- | One piece of a prompt: the 'Chunk' it prints and the text it computes.
-- Lean: @Chunk@ and @chunkExpr@ (@Check.lean:126@).
data Piece (s :: Scope) = Piece
  { pieceRaw :: Chunk,
    pieceExpr :: Expr (Codes s) Text
  }

-- | Everything said in one question, read left to right. Lean: @Prompt@.
type Words (s :: Scope) = [Piece s]

-- | Words written in the source. Lean: @chunkExpr@'s @.lit@ clause.
lit :: Text -> Piece s
lit t = Piece (Lit t) (const t)

-- | A hole: the answer a name stands for, spliced /as text/.
--
-- Lean: @chunkExpr@'s @.interp@ clause. A @text@ answer splices itself; a
-- @verdict@ splices @Verdict.render@ — its objections joined by @"; "@, so
-- approval and refusal both splice as @""@; a @flag@ or a @receipt@ has no
-- text of its own and is refused, here by 'Spliceable' having no instance for
-- it but a 'TypeError'.
hole ::
  forall n s.
  (KnownSymbol n, KnownVar n s, Spliceable (LookupC n s)) =>
  Piece s
hole = Piece (Interp (nameText @n)) (splice @(LookupC n s) . nameExpr @n @s)

-- | The kinds of answer that have a text of their own.
class Spliceable (c :: Code) where
  splice :: El c -> Text

instance Spliceable 'CodeText where
  splice = id

instance Spliceable 'CodeVerdict where
  splice = verdictRender

instance
  TypeError
    ( 'Text "only a text or a verdict answer interpolates into a prompt \
            \— a flag has no text of its own"
    ) =>
  Spliceable 'CodeFlag
  where
  splice = error "Spliceable CodeFlag: unreachable, the instance is a TypeError"

instance
  TypeError
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
-- (@Check.lean:157@), whose fold is left-associated; 'T.concat' is that same
-- string, associativity being a theorem about @++@ and not an observable.
wordsExpr :: Words s -> Expr (Codes s) Text
wordsExpr ps d = T.concat (map (\p -> pieceExpr p d) ps)

-- | The words where the prompt mentions no name, and 'Nothing' where it does.
--
-- Lean: @Prompt.closed@ (@Syntax.lean:140@). __The decision is made on the
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
    askServe :: Maybe Text,
    askWords :: Words s
  }

-- | @ask model "m" …@.
askModel :: Text -> Words s -> Ask s
askModel i w = Ask (AddrModel i) 0 Nothing w

-- | @ask model "m" served by "s" …@ — __the only__ constructor that takes a
-- serving model, which is how @askGuard@'s refusal (@Check.lean:320@:
-- "@served by@ names the model that serves a model addressee; a tool or a
-- person is not served by one") becomes unrepresentable rather than checked.
--
-- The alternative spelling — a phantom party index on 'Ask', with
-- @served :: Text -> Ask s 'PModel -> Ask s 'PModel@ — was rejected because a
-- panel combines members of /different/ parties (@battery-119@ panels a model,
-- a tool and a person), so an indexed 'Ask' would force an existential wrapper
-- at every panel member. The refusal is equally unrepresentable either way.
askModelServed :: Text -> Text -> Words s -> Ask s
askModelServed i m w = Ask (AddrModel i) 0 (Just m) w

-- | @ask tool "t" …@.
askTool :: Text -> Words s -> Ask s
askTool i w = Ask (AddrTool i) 0 Nothing w

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

-- | The shape a target writes. Lean: @askShape@ (@Check.lean:170@) — the
-- addressee and the draw as given, the scope at the unit of the scope monoid,
-- and @served by@ applied to /that/ by @atModel@, which sets the model axis
-- and leaves the mode axis silent. @served by@ never touches the words.
--
-- The 'SCode' argument is Lean's @(c : Code)@; @atModel@ ignores it, and it is
-- kept so a shape cannot be built at a kind its node does not use.
askShapeH :: SCode c -> Ask s -> Shape c
askShapeH _ a =
  let s = Shape {shAddressee = askAddr a, shScope = scopeUnit, shDraw = askDraw a}
   in maybe s (\m -> atModelShape m s) (askServe a)

-- | A question in binding position: __one__ node, because 'PAsk' /is/
-- ask-and-bind. Lean: @bindForm@'s @.ask@ branch (@Check.lean:468@).
askNode :: forall c s a. KnownCode c => Ask s -> Plan (c ': Codes s) a -> Plan (Codes s) a
askNode a k = case wordsClosed (askWords a) of
  Just w -> PAskC c (withPrompt (askShapeH c a) w) k
  Nothing -> PAsk c (askShapeH c a) (wordsExpr (askWords a)) k
  where
    c = sCode @c

-- | A question as a value. Lean: @askPlan@ (@Check.lean:330@), i.e. @askC1@
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
    -- | Lean: @rhsPlan@ (@Check.lean:431@).
    rhsPlan :: Plan (Codes s) (El c),
    -- | Lean: @bindForm@ (@Check.lean:459@).
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
-- Lean: @checkMembers@ (@Check.lean:345@) elaborates every member at
-- @.verdict@ — positionally, never by inference — and @Plan.panel@
-- (@Plan.lean:595@) folds them right, from the unit, in member order:
-- @v₁ * (v₂ * (… * (vₙ * 1)))@ in the verdict monoid, where @declined@
-- annihilates, @approve@ is the unit and objection lists concatenate. The
-- monoid is noncommutative on purpose, so the fold's direction is normative.
--
-- A panel answers @verdict@ and nothing else (@Check.lean:445@), and it needs
-- at least one member (@Check.lean:437@) — hence 'NonEmpty', which is why the
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

-- | A value call. Lean: @callPlan@ (@Check.lean:417@) — @Plan.sub@ of the
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
-- @argExpr@ (@Check.lean:359@).
data Arg (s :: Scope) (c :: Code) = Arg
  { argRaw :: RawArg,
    argExpr :: Expr (Codes s) (El c)
  }

-- | A name in scope, which must answer the parameter's kind __exactly__ — no
-- silent rendering, so a verdict does not fill a @text@ parameter
-- (@battery-180@). The kind is the name's, and the caller's parameter list is
-- what has to agree with it.
argName :: forall n s. (KnownSymbol n, KnownVar n s) => Arg s (LookupC n s)
argName = Arg (ArgName (nameText @n) pos0) (nameExpr @n @s)

-- | Words, which fill a @text@ parameter and are elaborated in the /caller's/
-- bindings — so a hole here reads the caller's names.
argWords :: Words s -> Arg s 'CodeText
argWords ws = Arg (ArgLit (wordsRaw ws) pos0) (wordsExpr ws)

-- | The arguments of one call, in source order.
data Args (s :: Scope) (ps :: [Code]) where
  ANil :: Args s '[]
  (:>) :: Arg s c -> Args s cs -> Args s (c ': cs)

infixr 5 :>

argsRaw :: Args s ps -> [RawArg]
argsRaw = \case
  ANil -> []
  a :> as -> argRaw a : argsRaw as

-- | The calling convention, verbatim: Lean's @checkArgs@ (@Check.lean:386@)
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
argSub ((a :: Arg s c) :> as) sigma =
  argSub as (subCons (argExpr a) sigma :: Sub (c ': acc) (Codes s))

-- ---------------------------------------------------------------------------
-- Functions
-- ---------------------------------------------------------------------------

-- | Lean's @paramCtx@ (@Check.lean:288@) is a /left/ fold, so a parameter list
-- is reversed into the context: for @(p₁ : c₁, p₂ : c₂)@ the context is
-- @c₂ ': c₁ ': '[]@ and @p₂@ is de Bruijn @0@.
type family ParamCtxGo (ps :: [Code]) (acc :: Ctx) :: Ctx where
  ParamCtxGo '[] acc = acc
  ParamCtxGo (c ': cs) acc = ParamCtxGo cs (c ': acc)

-- | @paramCtx@ itself.
type ParamCtx (ps :: [Code]) = ParamCtxGo ps '[]

-- | A parameter list: the codes @ps@ in __source__ order, and the 'Scope' they
-- push onto @acc@ — which, by the same left fold, is their reverse.
--
-- Lean: @paramBindings@ (@Check.lean:750@), which pushes the parameters in
-- source order so that the last one is de Bruijn @0@.
data Params (ps :: [Code]) (acc :: Scope) (s :: Scope) where
  PNil :: Params '[] acc acc
  PCons ::
    (KnownSymbol n, KnownCode c, Fresh n acc) =>
    Proxy n ->
    SCode c ->
    Params cs ('(n, c) ': acc) s ->
    Params (c ': cs) acc s

-- | The end of a parameter list.
noParams :: Params '[] acc acc
noParams = PNil

-- | One parameter, named and kinded: @param \@"goal" \@'CodeText noParams@.
param ::
  forall n c cs acc s.
  (KnownSymbol n, KnownCode c, Fresh n acc) =>
  Params cs ('(n, c) ': acc) s ->
  Params (c ': cs) acc s
param = PCons (Proxy @n) (sCode @c)

-- | The parameters as printed: @[name, code]@ pairs in source order.
paramsRaw :: Params ps acc s -> [(Text, Code)]
paramsRaw = \case
  PNil -> []
  PCons p c rest -> (T.pack (symbolVal p), fromSCode c) : paramsRaw rest

-- | A checked function: what it prints, and its plan over exactly its
-- parameters. Lean: @FnEntry@ (@Check.lean:292@).
--
-- The table's stratification — a duplicate name refused, a call naming only an
-- earlier entry, hence no recursion — is Haskell's @let@: a 'Fn' value must
-- exist before it can be applied.
data Fn (ps :: [Code]) (r :: Code) = Fn
  { fnRaw :: RawFn,
    fnPlan :: Plan (ParamCtx ps) (El r)
  }

-- | One function. Lean: @checkFn@ (@Check.lean:836@) — a body is checked
-- __once__, over exactly its parameters, and "a body cannot see the caller" is
-- the type and not a rule.
--
-- The name is a plain 'Text' because it is /printed/ and nothing else: the
-- call sites below name a 'Fn' value, not a string.
function ::
  forall ps r s.
  (KnownCode r, Codes s ~ ParamCtx ps) =>
  Text ->
  Params ps '[] s ->
  Body s r ->
  Fn ps r
function nm ps b =
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

-- | A call's plan: the callee's, read through its arguments.
callPlanOf :: forall ps r s. Fn ps r -> Args s ps -> Plan (Codes s) (El r)
callPlanOf f as = subP (fnPlan f) (argSub as (const ENil :: Sub '[] (Codes s)))

-- ---------------------------------------------------------------------------
-- Function bodies
-- ---------------------------------------------------------------------------

-- | A function body: the statements it prints, the @answer@ it names, and the
-- plan it elaborates to. Lean: @checkBody@ (@Check.lean:783@).
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

-- | @x <- …@ in a body; prints @ann = null@.
bindB ::
  forall n c s r.
  (KnownSymbol n, Fresh n s, KnownCode c) =>
  Rhs s c ->
  Body ('(n, c) ': s) r ->
  Body s r
bindB rhs rest =
  Body
    { bodyRaw = BodyBind (nameText @n) Nothing (rhsRaw rhs) pos0 : bodyRaw rest,
      bodyAnswer = bodyAnswer rest,
      bodyPlan = rhsForm rhs (bodyPlan rest)
    }

-- | @x : c <- …@ in a body; prints @ann = c@.
bindAsB ::
  forall n c s r.
  (KnownSymbol n, Fresh n s, KnownCode c) =>
  Rhs s c ->
  Body ('(n, c) ': s) r ->
  Body s r
bindAsB rhs rest =
  Body
    { bodyRaw =
        BodyBind (nameText @n) (Just (fromSCode (sCode @c))) (rhsRaw rhs) pos0
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
-- The declared result /is/ the name's kind, which is @checkFn@'s @b.at?
-- f.result@ made structural.
answerB :: forall n s. (KnownSymbol n, KnownVar n s) => Body s (LookupC n s)
answerB =
  Body
    { bodyRaw = [],
      bodyAnswer = Just (nameText @n),
      bodyPlan = PRet (nameExpr @n @s)
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
-- Lean (@Check.lean:584@): __one__ node at the imposed kind, whose
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
  Blk ('(n, c) ': s) ->
  Blk s
bind rhs rest =
  Blk
    (RawBind (nameText @n) Nothing (SrcRhs (rhsRaw rhs)) (blkRaw rest) pos0)
    (rhsForm rhs (blkPlan rest))

-- | @x : c <- …@; prints @ann = c@. Same elaboration as 'bind' — an
-- annotation grounds inference, it does not change the term.
bindAs ::
  forall n c s.
  (KnownSymbol n, Fresh n s, KnownCode c) =>
  Rhs s c ->
  Blk ('(n, c) ': s) ->
  Blk s
bindAs rhs rest =
  Blk
    ( RawBind
        (nameText @n)
        (Just (fromSCode (sCode @c)))
        (SrcRhs (rhsRaw rhs))
        (blkRaw rest)
        pos0
    )
    (rhsForm rhs (blkPlan rest))

-- | The act: a statement-position ask.
--
-- Lean (@Check.lean:559@): an ask at @Code.ack@ whose answer occupies a
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
-- (@Check.lean:580@). The answer is discarded and __no__ context slot is
-- added — the contrast with 'act' is deliberate and is what @battery-144@
-- pins. Only a @-> receipt@ function may stand here, which is the type.
callStmt :: Fn ps 'CodeAck -> Args s ps -> Blk s -> Blk s
callStmt f as rest =
  Blk
    (RawCallStmt (fnName (fnRaw f)) (argsRaw as) (blkRaw rest) pos0)
    (graft (callPlanOf f as) (Cont (\sigma _ -> subP (blkPlan rest) sigma)))

-- | @if x { … } else { … }@.
--
-- Lean (@Check.lean:665@): one @case@ at 'Bool' via @caseB@, both arms in the
-- term, each arm the rest of the workflow in the __same__ context with the
-- __same__ names. No binder is added — the flag is read through the existing
-- variable.
ifFlag ::
  forall n s.
  (KnownSymbol n, KnownVar n s, LookupC n s ~ 'CodeFlag) =>
  Blk s ->
  Blk s ->
  Blk s
ifFlag yes no =
  Blk
    (RawIfFlag (nameText @n) (blkRaw yes) (blkRaw no) pos0)
    (caseB (nameExpr @n @s) (blkPlan yes) (blkPlan no))

-- | @case x { approved … objected … no answer … }@.
--
-- Lean (@Check.lean:681@): one @case@ at @VTag@ via @caseV@, whose scrutinee
-- is @Verdict.tag@ of the name. The verdict itself stays readable in every arm
-- — the tag decides the shape, the objections ride in the environment.
caseVerdict ::
  forall n s.
  (KnownSymbol n, KnownVar n s, LookupC n s ~ 'CodeVerdict) =>
  Blk s ->
  Blk s ->
  Blk s ->
  Blk s
caseVerdict approved objected noAnswer =
  Blk
    ( RawCaseVerdict
        (nameText @n)
        (blkRaw approved)
        (blkRaw objected)
        (blkRaw noAnswer)
        pos0
    )
    (caseV (nameExpr @n @s) arms)
  where
    arms = \case
      VApprove -> blkPlan approved
      VObject -> blkPlan objected
      VDeclined -> blkPlan noAnswer

-- | @known here: …@ — an assertion, and __no node at all__.
--
-- Lean (@Check.lean:551@): a checked @known here@ elaborates to the rest of
-- the block, unchanged, in the same context; it contributes no binder, no
-- event, and does not appear in @size@. The names it prints are computed from
-- the type-level scope, innermost first, so a rebuilt case cannot print a
-- wrong one. @known here: nothing@ is what an empty scope computes.
knownHere :: forall s. KnownScope s => Blk s -> Blk s
knownHere rest =
  Blk (RawKnownHere (scopeNames @s) (blkRaw rest) pos0) (blkPlan rest)

-- ---------------------------------------------------------------------------
-- The bounded revision
-- ---------------------------------------------------------------------------

-- | The review clause's continuation: the candidate under review is de Bruijn
-- @0@. Lean: @checkCont@ (@Check.lean:491@).
checkCont :: Plan (c ': g) Verdict -> Cont g (El c) Verdict
checkCont chk = Cont (\sigma a -> subP chk (subCons a sigma))

-- | The amend clause's continuation: the review's verdict is de Bruijn @0@ and
-- the candidate is @1@. Lean: @reviseCont@ (@Check.lean:498@).
reviseCont :: Plan ('CodeVerdict ': c ': g) (El c) -> Cont g (El c, Verdict) (El c)
reviseCont rev =
  Cont (\sigma av -> subP rev (subCons (snd . av) (subCons (fst . av) sigma)))

-- | The two outcomes of a loop: a @caseB@ on whether it produced an artefact,
-- with the artefact reaching the settled arm as de Bruijn @0@. The unsettled
-- arm reads @default@, which no run ever sees. Lean: @finishCont@
-- (@Check.lean:505@).
finishCont ::
  forall c g.
  KnownCode c =>
  Plan (c ': g) () ->
  Plan g () ->
  Cont g (Maybe (El c)) ()
finishCont acc exh =
  Cont
    ( \sigma final ->
        caseB
          (isJust . final)
          (subP acc (subCons (fromMaybe (defaultEl (sCode @c)) . final) sigma))
          (subP exh sigma)
    )

-- | @x <- revising subj as carrier, at most n amendments { … }@ together with
-- the @case x { settled p { … } unsettled { … } }@ that consumes it — __one__
-- combinator, because the intermediate has type @Plan Γ (Option (El c))@ and
-- @Ctx@ has no code for "settled-or-not". Lean carries it as a @Pend Γ@
-- (@Check.lean:527@) that the very next statement must consume, and refuses
-- every other statement by name while it is pending; here the pairing is the
-- combinator's shape.
--
-- Elaboration (@Check.lean:611@ and @702@, @Plan.lean:621@):
--
-- * the candidate's kind is the __subject's__ kind, so it is 'LookupC' of the
--   subject and not a choice;
-- * the review is elaborated at @verdict@ with the candidate at index @0@
--   under the carrier's name; it may be an ask, a panel or a call;
-- * the amend is elaborated at the candidate's kind with the review's verdict
--   at index @0@ (under the review binding's name) and the candidate at @1@;
-- * the unroll is check-first: at bound @n@ there are @n+1@ checks and at most
--   @n@ amendments, each round's @caseB@ testing @Verdict.approvedB@ —
--   approval /exactly/, so a refusal is not a settlement — and the last round
--   has no @caseB@ and no amend at all;
-- * the whole loop is grafted with 'finishCont', which replicates both arms
--   once per exit of the unroll. That replication is the @(n+1)*(st+un)@ term
--   of @blockAsks@ and the reason @vector-002@ reaches size 92.
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
  forall subj carrier rev settled s c.
  ( KnownSymbol subj,
    KnownSymbol carrier,
    KnownSymbol rev,
    KnownSymbol settled,
    KnownVar subj s,
    c ~ LookupC subj s,
    KnownCode c,
    Fresh carrier s,
    Fresh rev ('(carrier, c) ': s),
    Fresh settled s
  ) =>
  -- | the loop result's name, printed only
  Text ->
  -- | the bound: @0 <= n <= 64@ (Lean's @maxRevisions@)
  Integer ->
  -- | the review's printed annotation: 'Nothing' or @Just 'CodeVerdict'@
  Maybe Code ->
  -- | the review, at @verdict@, seeing the candidate as the carrier
  Rhs ('(carrier, c) ': s) 'CodeVerdict ->
  -- | the amend, at the candidate's kind, seeing the verdict and the candidate
  Rhs ('(rev, 'CodeVerdict) ': '(carrier, c) ': s) c ->
  -- | the settled arm, with the artefact bound
  Blk ('(settled, c) ': s) ->
  -- | the unsettled arm
  Blk s ->
  Blk s
revisingCase resultName n reviewAnn review amend settled unsettled
  | n < 0 || n > 64 =
      error
        ( "revisingCase: a bounded revision is unrolled into the term it \
          \writes, so its bound may name at most 64 amendments, and not "
            ++ show n
        )
  | reviewAnn `notElem` [Nothing, Just CodeVerdict] =
      error
        "revisingCase: a review answers `verdict`, not anything else: the loop \
        \settles when it approves"
  | otherwise = Blk raw plan
  where
    raw =
      RawBind
        resultName
        Nothing
        ( SrcRevising
            (nameText @subj)
            (nameText @carrier)
            n
            (nameText @rev)
            reviewAnn
            (rhsRaw review)
            (rhsRaw amend)
            pos0
        )
        ( RawCaseResult
            resultName
            (nameText @settled)
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
    loop :: Plan (Codes s) (Maybe (El c))
    loop =
      runCont
        (revising @c @(Codes s) (checkCont (rhsPlan review)) (reviseCont (rhsPlan amend)) n)
        subId
        (nameExpr @subj @s)

    plan = graft loop (finishCont (blkPlan settled) (blkPlan unsettled))

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
