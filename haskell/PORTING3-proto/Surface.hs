{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE EmptyCase #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeFamilyDependencies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}

-- | Prototype of the monadic surface. The Builder side is stubbed down to the
-- printed Raw (no Plan), because what is being validated here is the
-- type-level plumbing and the quoter's chunking, not the elaboration.
module Surface where

import Data.Kind (Constraint, Type)
import Data.Text (Text)
import qualified Data.Text as T
import GHC.OverloadedLabels (IsLabel (..))
import GHC.TypeLits (ErrorMessage (..), KnownSymbol, Symbol, TypeError, symbolVal)
import Data.Proxy (Proxy (..))
import Prelude hiding ((>>), (>>=))

-- ---------------------------------------------------------------------------
-- Stubs of Agentic.Raw / Agentic.Builder
-- ---------------------------------------------------------------------------

data Code = CodeText | CodeFlag | CodeVerdict | CodeAck
  deriving (Eq, Show)

data Chunk = Lit Text | Interp Text deriving (Eq, Show)

type Prompt = [Chunk]

data RawAsk = RawAsk
  { rServe :: Maybe Text,
    rAddr :: Text,
    rDraw :: Integer,
    rPrompt :: Prompt
  }
  deriving (Eq, Show)

data RawRhs = RhsAsk RawAsk | RhsPanel [RawAsk] deriving (Eq, Show)

data RawSource
  = SrcRhs RawRhs
  | SrcRevising Text Text Integer Text (Maybe Code) RawRhs RawRhs
  deriving (Eq, Show)

data Raw
  = RawEmpty
  | RawBind Text (Maybe Code) RawSource Raw
  | RawAct RawAsk Raw
  | RawIfFlag Text Raw Raw
  | RawCaseResult Text Text Raw Raw
  | RawKnownHere [Text] Raw
  deriving (Eq, Show)

type Entry = (Symbol, Code)

type Scope = [Entry]

-- The two Builder values the surface prints into.
newtype Blk (s :: Scope) = Blk {blkRaw :: Raw}

newtype Rhs (s :: Scope) (c :: Code) = Rhs {rhsRaw :: RawRhs}

newtype Ask (s :: Scope) = Ask {askRaw :: RawAsk}

newtype Piece (s :: Scope) = Piece {pieceRaw :: Chunk}

type Words (s :: Scope) = [Piece s]

lit :: Text -> Piece s
lit = Piece . Lit

-- ---------------------------------------------------------------------------
-- The typed scope (verbatim from Agentic.Builder)
-- ---------------------------------------------------------------------------

type family SymEq (n :: Symbol) (m :: Symbol) :: Bool where
  SymEq n n = 'True
  SymEq n m = 'False

type family LookupC (n :: Symbol) (s :: Scope) :: Code where
  LookupC n ('(n, c) ': s) = c
  LookupC n ('(m, d) ': s) = LookupC n s
  LookupC n '[] =
    TypeError
      ('Text "unbound name; nothing in scope answers to `" ':<>: 'Text n ':<>: 'Text "`")

class KnownVar (n :: Symbol) (s :: Scope) where
  varOf :: Int

class KnownVar' (eq :: Bool) (n :: Symbol) (s :: Scope) where
  varOf' :: Int

instance (m ~ n) => KnownVar' 'True n ('(m, c) ': s) where
  varOf' = 0

instance KnownVar n s => KnownVar' 'False n ('(m, d) ': s) where
  varOf' = 1 + varOf @n @s

instance KnownVar' (SymEq n m) n ('(m, d) ': s) => KnownVar n ('(m, d) ': s) where
  varOf = varOf' @(SymEq n m) @n @('(m, d) ': s)

type family Fresh (n :: Symbol) (s :: Scope) :: Constraint where
  Fresh n '[] = ()
  Fresh n ('(n, c) ': s) =
    TypeError ('Text "this name is already in scope: " ':<>: 'Text n)
  Fresh n ('(m, d) ': s) = Fresh n s

class KnownScope (s :: Scope) where
  scopeNames :: [Text]

instance KnownScope '[] where scopeNames = []

instance (KnownSymbol n, KnownScope s) => KnownScope ('(n, c) ': s) where
  scopeNames = nameText @n : scopeNames @s

nameText :: forall n. KnownSymbol n => Text
nameText = T.pack (symbolVal (Proxy @n))

class Spliceable (c :: Code)

instance Spliceable 'CodeText

instance Spliceable 'CodeVerdict

instance
  TypeError ('Text "a flag has no text of its own") =>
  Spliceable 'CodeFlag

instance
  TypeError ('Text "a receipt has no text of its own") =>
  Spliceable 'CodeAck

hole :: forall n s. (KnownSymbol n, KnownVar n s, Spliceable (LookupC n s)) => Piece s
hole = Piece (Interp (nameText @n))

-- ---------------------------------------------------------------------------
-- Names: labels and handles
-- ---------------------------------------------------------------------------

-- | The author's name for a binding, written @#guide@.
data Label (n :: Symbol) = Label

instance n ~ n' => IsLabel n (Label n') where fromLabel = Label

-- | A live binding: the name it prints under, and the kind it answers.
data V (n :: Symbol) (c :: Code) = V

-- | @label =: source@ — a statement awaiting a block's @>>=@.
data Named (n :: Symbol) src = Named src

(=:) :: Label n -> src -> Named n src
_ =: src = Named src

infix 1 =:

-- ---------------------------------------------------------------------------
-- Parties and questions
-- ---------------------------------------------------------------------------

data PartyK = IsModel | IsTool | IsPerson

data Party (p :: PartyK) = Party
  { pAddr :: Text,
    pServe :: Maybe Text,
    pDraw :: Integer
  }

model :: Text -> Party 'IsModel
model i = Party ("model:" <> i) Nothing 0

tool :: Text -> Party 'IsTool
tool i = Party ("tool:" <> i) Nothing 0

person :: Text -> Party 'IsPerson
person i = Party ("person:" <> i) Nothing 0

-- | Only a model is served by a model: on a tool or a person this does not
-- typecheck.
servedBy :: Party 'IsModel -> Text -> Party 'IsModel
servedBy p m = p {pServe = Just m}

draws :: Party p -> Integer -> Party p
draws p n = p {pDraw = n}

ask :: Party p -> Words s -> Ask s
ask p w = Ask (RawAsk (pServe p) (pAddr p) (pDraw p) (map pieceRaw w))

-- | A question in binding position, at @flag@: @if@ can decide on it.
confirm :: Party p -> Words s -> Rhs s 'CodeFlag
confirm p w = one (ask p w)

one :: Ask s -> Rhs s c
one = Rhs . RhsAsk . askRaw

-- | The kind words, for the two positions that need to say one.
data SCode (c :: Code) = SCode Code

text :: SCode 'CodeText
text = SCode CodeText

flag :: SCode 'CodeFlag
flag = SCode CodeFlag

verdict :: SCode 'CodeVerdict
verdict = SCode CodeVerdict

-- | @ask … `answering` flag@: the kind, stated, printing nothing.
answering :: Ask s -> SCode c -> Rhs s c
answering a _ = one a

panel :: [Ask s] -> Rhs s 'CodeVerdict
panel [] = error "a panel needs at least one member"
panel ms = Rhs (RhsPanel (map askRaw ms))

-- ---------------------------------------------------------------------------
-- The workflow block
-- ---------------------------------------------------------------------------

-- | Lean's @Pend Γ@, at the type level: after a bounded revision the block is
-- pending its @case@, and no other statement may stand there.
data Stage = Open Scope | Pending Code Scope

type family Res (i :: Stage) = (r :: Type) | r -> i where
  Res ('Open s) = Blk s
  Res ('Pending c s) = Arms c s

-- | The two arms a pending @case result@ owes. @ns@ is existential exactly as
-- @revisingCaseI@ leaves it free.
data Arms (c :: Code) (s :: Scope) where
  Arms :: Text -> Blk ('(ns, c) ': s) -> Blk s -> Arms c s

-- | A block, in continuation-passing style over the stage index: given what
-- follows, the whole block.
newtype W (i :: Stage) (j :: Stage) a = W {unW :: (a -> Res j) -> Res i}

-- | Uninhabited: a terminal has no value, so nothing can follow one.
data Term

absurdTerm :: Term -> a
absurdTerm t = case t of {}

type family NoFollow a :: Constraint where
  NoFollow Term =
    TypeError ('Text "nothing follows a terminal: `stop`, `if` and `case` end a block")
  NoFollow a = ()

runW :: W ('Open s) j Term -> Blk s
runW (W f) = f absurdTerm

-- | What a statement does to a block. One instance per statement shape, and
-- the instance head is what fixes the two stages and the value bound.
class Step st (i :: Stage) (j :: Stage) a | st -> i j a where
  step :: st -> (a -> Res j) -> Res i

-- | A statement that is already a block (an act, a knownHere, a terminal).
instance Step (W i j a) i j a where
  step = unW

-- | @x <- #x =: ask …@ — a bare question answers @text@, which is Lean's
-- "a hole reads it as text" made structural.
instance
  (KnownSymbol n, Fresh n s) =>
  Step (Named n (Ask s)) ('Open s) ('Open ('(n, 'CodeText) ': s)) (V n 'CodeText)
  where
  step (Named a) k =
    Blk (RawBind (nameText @n) Nothing (SrcRhs (RhsAsk (askRaw a))) (blkRaw (k V)))

-- | @x <- #x =: panel […]@, @… =: confirm …@, @… =: ask … `answering` verdict@.
instance
  (KnownSymbol n, Fresh n s) =>
  Step (Named n (Rhs s c)) ('Open s) ('Open ('(n, c) ': s)) (V n c)
  where
  step (Named r) k =
    Blk (RawBind (nameText @n) Nothing (SrcRhs (rhsRaw r)) (blkRaw (k V)))

-- | @#result =: revising …@ — the block becomes pending its @case@.
instance
  KnownSymbol n =>
  Step (Named n (Loop c s)) ('Open s) ('Pending c s) ()
  where
  step (Named lp) k = loopRun lp (nameText @n) (k ())

bindW :: (Step st i j a, NoFollow a) => st -> (a -> W j k b) -> W i k b
bindW m f = W (\kk -> step m (\a -> unW (f a) kk))

thenW ::
  forall st i j a k b.
  (Step st i j a, NoFollow a) =>
  st ->
  W j k b ->
  W i k b
thenW m n = bindW @st @i @j @a m (\_ -> n)

-- ---------------------------------------------------------------------------
-- Statements and terminals
-- ---------------------------------------------------------------------------

stop :: W ('Open s) j Term
stop = W (\_ -> Blk RawEmpty)

act :: Party p -> Words s -> W ('Open s) ('Open s) ()
act p w = W (\k -> Blk (RawAct (askRaw (ask p w)) (blkRaw (k ()))))

knownHere :: forall s. KnownScope s => W ('Open s) ('Open s) ()
knownHere = W (\k -> Blk (RawKnownHere (scopeNames @s) (blkRaw (k ()))))

ifFlag ::
  forall n s j.
  (KnownSymbol n, KnownVar n s, LookupC n s ~ 'CodeFlag) =>
  V n 'CodeFlag ->
  W ('Open s) j Term ->
  W ('Open s) j Term ->
  W ('Open s) j Term
ifFlag _ yes no = W (\_ -> Blk (RawIfFlag (nameText @n) (raw yes) (raw no)))
  where
    raw = blkRaw . runW

-- ---------------------------------------------------------------------------
-- The bounded revision
-- ---------------------------------------------------------------------------

newtype Bound = Bound Integer

atMost :: Integer -> Bound
atMost = Bound

-- | The loop, awaiting the result's name and the two arms of its @case@.
newtype Loop (c :: Code) (s :: Scope) = Loop {loopRun :: Text -> Arms c s -> Blk s}

-- | The review and the amendment, with the review binding's name existential
-- exactly as @revisingCaseI@ leaves it.
data Clauses (nc :: Symbol) (c :: Code) (s :: Scope) where
  Clauses ::
    Text ->
    Maybe Code ->
    Rhs ('(nc, c) ': s) 'CodeVerdict ->
    Rhs ('(nr, 'CodeVerdict) ': '(nc, c) ': s) c ->
    Clauses nc c s

newtype Amendment (nc :: Symbol) (nr :: Symbol) (c :: Code) (s :: Scope)
  = Amendment (Rhs ('(nr, 'CodeVerdict) ': '(nc, c) ': s) c)

amend :: Ask ('(nr, 'CodeVerdict) ': '(nc, c) ': s) -> Amendment nc nr c s
amend = Amendment . one

-- | A review is a question, a panel, or a call — always at @verdict@, by
-- position.
class ReviewSrc src (s :: Scope) where
  reviewRhs :: src -> Rhs s 'CodeVerdict

instance s ~ s' => ReviewSrc (Ask s') s where reviewRhs = one

instance (s ~ s', c ~ 'CodeVerdict) => ReviewSrc (Rhs s' c) s where
  reviewRhs (Rhs r) = Rhs r

-- | The revision block's @>>=@: exactly one review binding, then one
-- amendment. There is no @>>@, so there is no other shape.
bindR ::
  forall nr src nc c s.
  (KnownSymbol nr, Fresh nr ('(nc, c) ': s), ReviewSrc src ('(nc, c) ': s)) =>
  Named nr src ->
  (V nr 'CodeVerdict -> Amendment nc nr c s) ->
  Clauses nc c s
bindR (Named src) f = case f V of
  Amendment am -> Clauses (nameText @nr) Nothing (reviewRhs @src @('(nc, c) ': s) src) am

revising ::
  forall subj carrier c s.
  ( KnownSymbol subj,
    KnownSymbol carrier,
    KnownVar subj s,
    c ~ LookupC subj s,
    Fresh carrier s
  ) =>
  V subj c ->
  Label carrier ->
  Bound ->
  (V carrier c -> Clauses carrier c s) ->
  Loop c s
revising _ _ (Bound n) body = Loop $ \resultName arms ->
  case (body V, arms) of
    (Clauses revName revAnn review am, Arms settledName settled unsettled) ->
      Blk
        ( RawBind
            resultName
            Nothing
            ( SrcRevising
                (nameText @subj)
                (nameText @carrier)
                n
                revName
                revAnn
                (rhsRaw review)
                (rhsRaw am)
            )
            (RawCaseResult resultName settledName (blkRaw settled) (blkRaw unsettled))
        )

caseResult ::
  forall sname c s j.
  (KnownSymbol sname, Fresh sname s) =>
  Label sname ->
  (V sname c -> W ('Open ('(sname, c) ': s)) j Term) ->
  W ('Open s) j Term ->
  W ('Pending c s) j Term
caseResult _ settled unsettled =
  W (\_ -> Arms (nameText @sname) (runW (settled V)) (runW unsettled))

-- ---------------------------------------------------------------------------
-- Programs
-- ---------------------------------------------------------------------------

workflow :: W ('Open '[]) ('Open '[]) Term -> Raw
workflow = blkRaw . runW

-- ---------------------------------------------------------------------------
-- Prompts: what a @{hole}@ may name
-- ---------------------------------------------------------------------------

-- | Anything a @{…}@ may name: a live binding, or a define.
class Says a (s :: Scope) where
  says :: a -> Words s

instance
  (KnownSymbol n, KnownVar n s, Spliceable (LookupC n s), LookupC n s ~ c) =>
  Says (V n c) s
  where
  says _ = [hole @n]

instance Says Text s where
  says t = [lit t]

instance s ~ s' => Says [Piece s'] s where
  says = id
