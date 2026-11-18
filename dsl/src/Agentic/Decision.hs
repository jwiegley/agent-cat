{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}

-- |
-- Module      : Agentic.Decision
-- Description : Finite option sets, their answer records, and the probability simplex over them.
--
-- A decision asks which of a finite set T of options is right. Its answer is a
-- record of one number per option, a point of ℚ^T, and the answer means the
-- distribution v/Σv in the simplex Δ(T) whenever v lies in the cone
-- C(T) = {v ≥ 0, Σv > 0}. Outside the cone an answer means nothing. This
-- module states that reading in Haskell: 'Weights' is ℚ^T, 'Dist' is Δ(T),
-- and 'distribution' is the projection π : C(T) → Δ(T).
module Agentic.Decision
  ( -- * Option sets
    Options,
    OptionNames,
    DecisionSchema,
    NumberFields,
    NumberRecord (..),
    options,
    optionName,
    rank,
    optionCount,
    ChoiceSize,
    ScaleSize,

    -- * Probabilities
    Prob,
    prob,
    probValue,

    -- * The answer record (any representative of ℚ^T)
    Weights,
    weightsOf,
    weight,

    -- * Δ(T)
    Dist,
    distribution,
    weights,
    probabilityOf,
    expectation,
    dirac,
    mix,
    pushforward,
    modes,
    bernoulli,
    probabilityOfTrue,
    meanLevel,
  )
where

import Agentic.Schema
  ( HasSchema (..),
    KnownSchema (..),
    Schema (SchemaNumber, SchemaObject, SchemaProperty),
    SchemaEl,
  )
import Data.Kind (Constraint, Type)
import Data.List.NonEmpty (NonEmpty ((:|)))
import qualified Data.Map.Strict as M
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Generics
  ( C1,
    Constructor,
    D1,
    Generic (Rep, from),
    M1 (M1),
    Meta (MetaCons),
    U1,
    V1,
    conName,
    (:+:) (L1, R1),
  )
import GHC.TypeLits
  ( CmpNat,
    ErrorMessage (ShowType, Text, (:<>:)),
    Nat,
    Symbol,
    TypeError,
    type (+),
  )

-- ---------------------------------------------------------------------------
-- Option sets
-- ---------------------------------------------------------------------------

-- | The constructor names of a nullary sum type, in declaration order. Denotes
-- the injective naming n : T → Name of the finite option set. A constructor
-- with fields, or an empty type, is a type error.
type OptionNames t = GNames (Rep t)

type family GNames (f :: Type -> Type) :: [Symbol] where
  GNames (D1 m f) = GNames f
  GNames (f :+: g) = Append (GNames f) (GNames g)
  GNames (C1 ('MetaCons n fx s) U1) = '[n]
  GNames (C1 ('MetaCons n fx s) f) =
    TypeError ('Text "a decision option takes no fields, and " ':<>: 'ShowType n ':<>: 'Text " has some")
  GNames V1 = TypeError ('Text "a decision needs options, and this type has none")

type family Append (xs :: [Symbol]) (ys :: [Symbol]) :: [Symbol] where
  Append '[] ys = ys
  Append (x ': xs) ys = x ': Append xs ys

type family Length (xs :: [k]) :: Nat where
  Length '[] = 0
  Length (x ': xs) = 1 + Length xs

-- | The answer record of a decision: the product ℚ^T, written as one
-- @number@ field per option, in option order.
type DecisionSchema t = NumberFields (OptionNames t)

-- | The product ℚ^ns of one rational per name, as the schema algebra writes a
-- record: @NumberFields [n₁, …, nₖ]@ is
-- @property n₁ number (… (property nₖ number object))@.
type family NumberFields (ns :: [Symbol]) :: Schema where
  NumberFields '[] = 'SchemaObject
  NumberFields (n ': ns) = 'SchemaProperty n 'SchemaNumber (NumberFields ns)

-- | The isomorphism between the nested-pair interpretation of a number record
-- and the list of its values, in field order.
--
-- > recordFromList (recordToList el) == el
-- > recordToList (recordFromList xs) == take k (xs <> repeat 0)   -- k the field count
class NumberRecord (ns :: [Symbol]) where
  -- | Total: missing values are 0, and surplus values are dropped.
  recordFromList :: [Rational] -> SchemaEl (NumberFields ns)
  recordToList :: SchemaEl (NumberFields ns) -> [Rational]

instance NumberRecord '[] where
  recordFromList _ = ()
  recordToList () = []

instance NumberRecord ns => NumberRecord (n ': ns) where
  recordFromList values = case values of
    [] -> (0, recordFromList @ns [])
    value : rest -> (value, recordFromList @ns rest)
  recordToList (value, rest) = value : recordToList @ns rest

-- | The constructor name of a value of a sum type, read from its generic
-- representation.
class GConName (f :: Type -> Type) where
  gconName :: f p -> Text

instance GConName f => GConName (D1 m f) where
  gconName (M1 x) = gconName x

instance (GConName f, GConName g) => GConName (f :+: g) where
  gconName (L1 x) = gconName x
  gconName (R1 x) = gconName x

instance Constructor c => GConName (C1 c f) where
  gconName m = T.pack (conName m)

-- | A decision's option set: the finite set T = [minBound .. maxBound] with the
-- constructor naming. A constraint synonym, so an author writes no instance.
-- The naming law
--
-- > map optionName options == names of DecisionSchema t, in field order
--
-- holds for every derived 'Enum', and a hand-written 'Enum' that reorders the
-- constructors breaks it.
type Options t =
  ( Generic t,
    GConName (Rep t),
    Bounded t,
    Enum t,
    Ord t,
    KnownSchema (DecisionSchema t),
    NumberRecord (OptionNames t)
  )

-- | The option set T, in option order: @[minBound .. maxBound]@.
options :: forall t. Options t => [t]
options = [minBound .. maxBound]

-- | The naming n : T → Name: the generic constructor name of the value.
optionName :: Options t => t -> Text
optionName = gconName . from

-- | The scale coordinate ι : T → ℚ, the position in option order:
-- @rank t = fromEnum t − fromEnum minBound@.
rank :: forall t. Options t => t -> Rational
rank t = fromIntegral (fromEnum t - fromEnum (minBound @t))

-- | |T|.
optionCount :: forall t. Options t => Int
optionCount = length (options @t)

-- | Wire limits shared by every provider: a choice has 2–255 options.
type ChoiceSize t = Within "choice" 2 255 (Length (OptionNames t))

-- | Wire limits shared by every provider: a scale has 2–10 levels.
type ScaleSize t = Within "scale" 2 10 (Length (OptionNames t))

-- | @Within form lo hi n@ reduces to @()@ when lo ≤ n ≤ hi, and otherwise to a
-- type error that names the form, the bounds and n.
type family Within (form :: Symbol) (lo :: Nat) (hi :: Nat) (n :: Nat) :: Constraint where
  Within form lo hi n = WithinOrdering form lo hi n (CmpNat n lo) (CmpNat n hi)

type family WithinOrdering (form :: Symbol) (lo :: Nat) (hi :: Nat) (n :: Nat) (below :: Ordering) (above :: Ordering) :: Constraint where
  WithinOrdering form lo hi n 'LT above = TypeError (WithinMessage form lo hi n)
  WithinOrdering form lo hi n below 'GT = TypeError (WithinMessage form lo hi n)
  WithinOrdering form lo hi n below above = ()

type WithinMessage (form :: Symbol) (lo :: Nat) (hi :: Nat) (n :: Nat) =
  'Text "a " ':<>: 'Text form ':<>: 'Text " takes from " ':<>: 'ShowType lo
    ':<>: 'Text " to " ':<>: 'ShowType hi ':<>: 'Text " options, and this one has "
    ':<>: 'ShowType n

-- ---------------------------------------------------------------------------
-- Probabilities
-- ---------------------------------------------------------------------------

-- | The interval ℚ ∩ [0,1], which is Δ(Bool) through 'bernoulli'.
newtype Prob = Prob Rational
  deriving (Eq, Ord, Show)

-- | @prob r = Just p@ exactly when 0 ≤ r ≤ 1, and then @probValue p = r@.
prob :: Rational -> Maybe Prob
prob r
  | 0 <= r && r <= 1 = Just (Prob r)
  | otherwise = Nothing

probValue :: Prob -> Rational
probValue (Prob r) = r

-- ---------------------------------------------------------------------------
-- The answer record
-- ---------------------------------------------------------------------------

-- | The vector space ℚ^T: a decision as answered, any representative of its
-- meaning. This is the wire record. Equality is pointwise over 'options'.
newtype Weights t = Weights (t -> Rational)

-- | The record with the given coordinates: @weight (weightsOf f) = f@.
weightsOf :: (t -> Rational) -> Weights t
weightsOf = Weights

-- | The coordinate of a record at one option.
weight :: Weights t -> t -> Rational
weight (Weights f) = f

instance Options t => Eq (Weights t) where
  Weights f == Weights g = all (\t -> f t == g t) options

instance (Options t, Show t) => Show (Weights t) where
  showsPrec d (Weights f) =
    showParen (d > 10) (showString "Weights " . showsPrec 11 [(t, f t) | t <- options])

-- | The schema isomorphism ℚ^T ≅ @SchemaEl (DecisionSchema t)@ (law L1):
--
-- > fromSchemaEl . toSchemaEl = id
-- > toSchemaEl . fromSchemaEl = id
instance Options t => HasSchema (Weights t) where
  type SchemaOf (Weights t) = DecisionSchema t
  schemaOf = schemaWitness
  toSchemaEl (Weights f) = recordFromList @(OptionNames t) (map f options)
  fromSchemaEl el =
    let table = M.fromList (zip options (recordToList @(OptionNames t) el))
     in Weights (\t -> M.findWithDefault 0 t table)

-- ---------------------------------------------------------------------------
-- Δ(T)
-- ---------------------------------------------------------------------------

-- | The probability simplex Δ(T) = {p : T → ℚ≥0 | Σp = 1}, the free convex
-- space on T (Mathlib @stdSimplex ℚ T@). The representation is canonical: it
-- holds no zero entry and its entries sum to 1, so 'Eq' is semantic equality.
newtype Dist t = Dist (M.Map t Rational)

deriving instance Eq t => Eq (Dist t)

deriving instance Show t => Show (Dist t)

canonical :: M.Map t Rational -> Dist t
canonical = Dist . M.filter (/= 0)

mass :: Ord t => Dist t -> t -> Rational
mass (Dist table) t = M.findWithDefault 0 t table

-- | The projection π : C(T) → Δ(T), π(v) = v/Σv, defined exactly on the cone
-- (law L3):
--
-- > distribution w == Nothing  ⇔  (∃t. weight w t < 0) ∨ Σ w == 0
-- > distribution (scaled c w) == distribution w      for c > 0
-- > distribution (weights d) == Just d
distribution :: Options t => Weights t -> Maybe (Dist t)
distribution (Weights f)
  | any (< 0) values || total == 0 = Nothing
  | otherwise = Just (canonical (M.fromList [(t, f t / total) | t <- options]))
  where
    values = map f options
    total = sum values

-- | The inclusion Δ(T) ↪ ℚ^T.
weights :: Options t => Dist t -> Weights t
weights d = Weights (mass d)

-- | The chance of a set of options, ⟨1_S, p⟩, with S read as a set:
--
-- > probabilityOf d s == expectation (\t -> if t `elem` s then 1 else 0) d
-- > probabilityOf d options == 1
probabilityOf :: Options t => Dist t -> [t] -> Rational
probabilityOf d s = sum (map (mass d) (Set.toList (Set.fromList s)))

-- | The affine reading ⟨f, p⟩ = Σₜ f(t)·p(t). It is linear in f, affine in p,
-- and @expectation f (dirac t) == f t@.
expectation :: Options t => (t -> Rational) -> Dist t -> Rational
expectation f (Dist table) = sum [f t * p | (t, p) <- M.toList table]

-- | The vertex δₜ of Δ(T).
dirac :: Options t => t -> Dist t
dirac t = Dist (M.singleton t 1)

-- | The binary convex combination @mix λ p q = (1−λ)p + λq@, which satisfies
-- the convex-space laws (L5):
--
-- > mix 0 p q == p
-- > mix λ p p == p
-- > mix λ p q == mix (1−λ) q p
-- > mix λ p (mix μ q r) == mix (λμ) (mix ρ p q) r   when λ(1−μ) == (1−λμ)ρ
mix :: Options t => Prob -> Dist t -> Dist t -> Dist t
mix (Prob l) (Dist p) (Dist q) =
  canonical (M.unionWith (+) (M.map ((1 - l) *) p) (M.map (l *) q))

-- | The functor action of Δ on a map f : T → U, the image measure
-- (Mathlib @PMF.map@):
--
-- > pushforward id == id
-- > pushforward (g . f) == pushforward g . pushforward f
-- > probabilityOf (pushforward f d) [u] == probabilityOf d [t | t <- options, f t == u]
pushforward :: Ord u => (t -> u) -> Dist t -> Dist u
pushforward f (Dist table) = Dist (M.fromListWith (+) [(f t, p) | (t, p) <- M.toList table])

-- | The argmax set {t | p(t) = max p}, in option order. It is never empty,
-- because the entries of a distribution sum to 1, and it is equivariant
-- under bijections σ (law L10):
--
-- > Set (modes (pushforward σ d)) == Set (σ <$> modes d)
modes :: Options t => Dist t -> NonEmpty t
modes d@(Dist table) = case filter (\t -> mass d t == top) options of
  t : ts -> t :| ts
  [] -> error "Agentic.Decision.modes: a distribution has no option of maximal mass"
  where
    top = maximum (0 : M.elems table)

-- | The isomorphism ℚ ∩ [0,1] ≅ Δ(Bool) that sends p to the distribution
-- with chance p of 'True' (law L8):
--
-- > probabilityOfTrue . bernoulli == id
-- > bernoulli . probabilityOfTrue == id
bernoulli :: Prob -> Dist Bool
bernoulli (Prob p) = canonical (M.fromList [(False, 1 - p), (True, p)])

-- | The inverse of 'bernoulli': the chance ⟨1_{True}, p⟩.
probabilityOfTrue :: Dist Bool -> Prob
probabilityOfTrue d = Prob (mass d True)

-- | The expected level ⟨ι, p⟩ of a scale, @meanLevel = expectation rank@, so
-- that @0 ≤ meanLevel d ≤ |T| − 1@.
meanLevel :: Options t => Dist t -> Rational
meanLevel = expectation rank
