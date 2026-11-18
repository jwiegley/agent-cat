{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

-- | The decision law probe: laws L1 to L12 of the decision design, each a
-- QuickCheck property over three option sets (a four-way choice, a five-level
-- scale and Bool). The records include zero and negative ones, and the prompt
-- generators include newlines, leading spaces, empty descriptions and header
-- look-alikes inside the evidence. Law L11 runs through the authoring surface
-- itself: each reading is built with "Agentic.Workflow", and the probe reads
-- back both the region the surface prints and the plan it elaborates to. The
-- probe exits non-zero when any property fails.
module Main (main) where

import Agentic.Builder (Rhs (..), V (..))
import Agentic.DSL (Env (..), Plan (PRet), RawRhs (RhsWeigh), Var (VHere), evalExpr)
import Agentic.Decision
import Agentic.Plan.Decision
import Agentic.Schema
import Agentic.Workflow
  ( Decision,
    DecisionRecord,
    atLeast,
    chance,
    chanceYes,
    expectedLevel,
    isDistribution,
    levelAtLeast,
    mostLikely,
    noMoreThan,
  )
import Control.Exception (ErrorCall, evaluate, try)
import qualified Data.Aeson as A
import Data.List (intercalate, nub, sort)
import Data.List.NonEmpty (NonEmpty ((:|)))
import qualified Data.List.NonEmpty as NE
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, isJust, isNothing)
import Data.Ratio ((%))
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Generics (Generic)
import System.Exit (exitFailure)
import Test.QuickCheck

-- ---------------------------------------------------------------------------
-- Option sets
-- ---------------------------------------------------------------------------

data Colour = Red | Green | Blue | Violet
  deriving (Eq, Ord, Show, Enum, Bounded, Generic)

data Level = Never | Rarely | Sometimes | Often | Always
  deriving (Eq, Ord, Show, Enum, Bounded, Generic)

-- | A hand-written 'Enum' that reverses declaration order, the negative
-- control for the naming law.
data Swapped = First | Second
  deriving (Eq, Ord, Show, Generic)

instance Enum Swapped where
  fromEnum Second = 0
  fromEnum First = 1
  toEnum 0 = Second
  toEnum _ = First

instance Bounded Swapped where
  minBound = Second
  maxBound = First

type Nested =
  'SchemaProperty
    "ticket"
    'SchemaString
    ('SchemaProperty "verdict" (DecisionSchema Colour) 'SchemaObject)

-- ---------------------------------------------------------------------------
-- Generators
-- ---------------------------------------------------------------------------

genRational :: Gen Rational
genRational = do
  n <- choose (-20, 20)
  d <- choose (1, 12)
  pure (n % d)

genNonNegative :: Gen Rational
genNonNegative =
  frequency
    [ (3, fromInteger <$> choose (0, 3)),
      (2, (\n d -> n % d) <$> choose (0, 20) <*> choose (1, 12))
    ]

-- | Records of ℚ^T: zero records, records on the cone (with ties and zero
-- entries), records with one negative entry, and records of arbitrary sign.
genWeights :: forall t. Options t => Gen (Weights t)
genWeights = do
  values <-
    frequency
      [ (1, pure (map (const 0) ts)),
        (6, vectorOf n genNonNegative),
        (2, vectorOf n genNonNegative >>= negateOne),
        (2, vectorOf n genRational)
      ]
  pure (table values)
  where
    ts = options @t
    n = length ts
    negateOne values = do
      i <- choose (0, n - 1)
      c <- (\k d -> negate (k % d)) <$> choose (1, 5) <*> choose (1, 3)
      pure [if j == i then c else v | (j, v) <- zip [0 ..] values]
    table values = weightsOf (\t -> fromMaybe 0 (lookup t (zip ts values)))

genDist :: forall t. Options t => Gen (Dist t)
genDist = (genWeights @t) `suchThatMap` distribution

genProb :: Gen Prob
genProb =
  frequency
    [ (1, pure (probability 0)),
      (1, pure (probability 1)),
      (6, do d <- choose (1, 12); k <- choose (0, d); pure (probability (k % d)))
    ]

-- | A finite function T → U, shown as its table.
newtype Table a b = Table [(a, b)]
  deriving (Show)

apply :: Eq a => Table a b -> a -> b
apply (Table rows) a = fromMaybe (error "Table: no row") (lookup a rows)

genTable :: forall a b. Options a => Gen b -> Gen (Table a b)
genTable target = Table . zip (options @a) <$> vectorOf (length (options @a)) target

genPermutation :: forall a. Options a => Gen (Table a a)
genPermutation = Table . zip (options @a) <$> shuffle (options @a)

genSubset :: forall t. Options t => Gen [t]
genSubset = listOf (elements (options @t))

-- ---------------------------------------------------------------------------
-- Readings, built with the authoring surface
-- ---------------------------------------------------------------------------

record :: forall t. Options t => Weights t -> Maybe [(Text, Rational)]
record w = numberRecordAt (schemaWitness @(DecisionSchema t)) [] (toSchemaEl w)

-- | The scope of one decision binding, printed @x@.
type Here t = '[ '("x", Decision t)]

-- | The handle of that binding.
subject :: V (Here t) (Decision t)
subject = V "x" VHere

-- | What the surface makes of a test, read on the record @w@: 'Nothing' when
-- the surface refuses the test, and otherwise the verdict of the region it
-- prints and the verdict of the plan it elaborates to.
surface :: forall t. Options t => Rhs (Here t) 'CodeFlag -> Weights t -> IO (Maybe (Bool, Bool))
surface rhs w = do
  forced <- try (evaluate rhs)
  pure $ case forced of
    Left (_ :: ErrorCall) -> Nothing
    Right built -> Just (printed built, planned built)
  where
    printed built = case rhsRaw built of
      RhsWeigh "x" [] region _ -> maybe False (holdsRegion region) (record w)
      _ -> error "the surface printed something other than a weighing of x at the empty path"
    planned built = case rhsPlan built of
      PRet e -> evalExpr e (ECons (toSchemaEl w) ENil)
      _ -> error "the surface elaborated to something other than a ret"

-- | Whether a test of Δ(T) is constant on it. Every test checked this way is
-- a half-space, which is constant on the simplex exactly when it is constant
-- on the vertices.
constantOnSimplex :: forall t. Options t => (Dist t -> Bool) -> Bool
constantOnSimplex meaning = case map (meaning . dirac) (options @t) of
  first : rest -> all (== first) rest
  [] -> True

-- | Law L11 for a half-space test: the surface refuses it exactly when it is
-- constant on Δ(T), and otherwise the printed region and the elaborated plan
-- both read the record @w@ as the test reads its distribution.
halfspaceLaw :: forall t. Options t => Rhs (Here t) 'CodeFlag -> (Dist t -> Bool) -> Weights t -> Property
halfspaceLaw rhs meaning w = ioProperty $ do
  got <- surface rhs w
  pure $ case got of
    Nothing -> counterexample "the surface refused a test that is not constant" (constantOnSimplex meaning)
    Just verdicts ->
      counterexample ("the surface accepted a constant test, or read " <> show verdicts) $
        not (constantOnSimplex meaning) && agrees meaning w verdicts

-- | Law L11 for a test that the surface never refuses.
totalLaw :: forall t. Options t => Rhs (Here t) 'CodeFlag -> (Dist t -> Bool) -> Weights t -> Property
totalLaw rhs meaning w = ioProperty $ do
  got <- surface rhs w
  pure $ case got of
    Nothing -> counterexample "the surface refused the test" False
    Just verdicts -> counterexample ("the surface read " <> show verdicts) (agrees meaning w verdicts)

agrees :: Options t => (Dist t -> Bool) -> Weights t -> (Bool, Bool) -> Bool
agrees meaning w (printed, planned) = printed == expected && planned == expected
  where
    expected = maybe False meaning (distribution w)

dot :: Options t => [(Text, Rational)] -> Dist t -> Rational
dot ws d = sum [c * probabilityOf d [t | t <- options, optionName t == n] | (n, c) <- ws]

-- | A threshold that often equals the reading exactly, so that the boundary
-- of every half-space is exercised.
genThreshold :: Maybe Rational -> Gen Rational
genThreshold exact =
  frequency ([(2, genRational)] <> maybe [] (\r -> [(3, pure r)]) exact)

-- ---------------------------------------------------------------------------
-- Laws over one option set
-- ---------------------------------------------------------------------------

lawsFor ::
  forall t.
  (Options t, Show t, Eq (SchemaEl (DecisionSchema t)), DecisionRecord (DecisionSchema t)) =>
  String ->
  [(String, Property)]
lawsFor setName =
  [ named "L1 fromSchemaEl . toSchemaEl = id" $
      forAll (genWeights @t) $ \w -> fromSchemaEl (toSchemaEl w) == w,
    named "L1 toSchemaEl . fromSchemaEl = id" $
      forAll (vectorOf n genRational) $ \xs ->
        let el = recordFromList @(OptionNames t) xs
         in toSchemaEl (fromSchemaEl el :: Weights t) == el,
    named "L2 option names are the schema's field names" $
      property (Just (map optionName ts) == numberFieldNames (demoteSchema (schemaWitness @(DecisionSchema t)))),
    named "L2 decisionSchemaRep agrees with DecisionSchema" $
      property $ case map (\t -> (optionName t, "")) ts of
        first : rest ->
          decisionSchemaRep (DecisionQuestion ChoiceForm "pick" (first :| rest))
            == demoteSchema (schemaWitness @(DecisionSchema t))
        [] -> False,
    named "L3 distribution is invariant under positive scaling" $
      forAll (genWeights @t) $ \w -> forAll (genRational `suchThat` (> 0)) $ \c ->
        distribution (weightsOf (\t -> c * weight w t)) == distribution w,
    named "L3 distribution (weights d) = Just d" $
      forAll (genDist @t) $ \d -> distribution (weights d) == Just d,
    named "L3 distribution is defined exactly on the cone" $
      forAll (genWeights @t) $ \w ->
        isNothing (distribution w) == (any (\t -> weight w t < 0) ts || sum (map (weight w) ts) == 0),
    named "L4 probabilityOf d options = 1" $
      forAll (genDist @t) $ \d -> probabilityOf d ts == 1,
    named "L4 0 <= probabilityOf d s <= 1" $
      forAll (genDist @t) $ \d -> forAll (genSubset @t) $ \s ->
        let p = probabilityOf d s in 0 <= p && p <= 1,
    named "L5 mix 0 p q = p" $
      forAll (genDist @t) $ \p -> forAll (genDist @t) $ \q ->
        mix (probability 0) p q == p,
    named "L5 mix l p p = p" $
      forAll genProb $ \l -> forAll (genDist @t) $ \p -> mix l p p == p,
    named "L5 mix l p q = mix (1 - l) q p" $
      forAll genProb $ \l -> forAll (genDist @t) $ \p -> forAll (genDist @t) $ \q ->
        mix l p q == mix (probability (1 - probValue l)) q p,
    named "L5 mix l p (mix m q r) = mix (l m) (mix rho p q) r" $
      forAll genProb $ \l -> forAll genProb $ \m -> forAll genProb $ \free ->
        forAll (genDist @t) $ \p -> forAll (genDist @t) $ \q -> forAll (genDist @t) $ \r ->
          let lv = probValue l
              mv = probValue m
              rho
                | lv * mv == 1 = free
                | otherwise = probability (lv * (1 - mv) / (1 - lv * mv))
           in lv * (1 - mv) == (1 - lv * mv) * probValue rho
                && mix l p (mix m q r) == mix (probability (lv * mv)) (mix rho p q) r,
    named "L6 pushforward id = id" $
      forAll (genDist @t) $ \d -> pushforward id d == d,
    named "L6 pushforward (g . f) = pushforward g . pushforward f" $
      forAll (genDist @t) $ \d -> forAll (genTable @t (elements (options @Level))) $ \f ->
        forAll (genTable @Level (elements (options @Bool))) $ \g ->
          pushforward (apply g . apply f) d == pushforward (apply g) (pushforward (apply f) d),
    named "L6 pushforward is the image measure" $
      forAll (genDist @t) $ \d -> forAll (genTable @t (elements (options @Colour))) $ \f ->
        all
          (\u -> probabilityOf (pushforward (apply f) d) [u] == probabilityOf d [t | t <- ts, apply f t == u])
          (options @Colour),
    named "L7 expectation is linear in f" $
      forAll (genDist @t) $ \d -> forAll (genTable @t genRational) $ \f -> forAll (genTable @t genRational) $ \g ->
        forAll genRational $ \a -> forAll genRational $ \b ->
          expectation (\t -> a * apply f t + b * apply g t) d
            == a * expectation (apply f) d + b * expectation (apply g) d,
    named "L7 expectation is affine in d" $
      forAll genProb $ \l -> forAll (genDist @t) $ \p -> forAll (genDist @t) $ \q ->
        forAll (genTable @t genRational) $ \f ->
          expectation (apply f) (mix l p q)
            == (1 - probValue l) * expectation (apply f) p + probValue l * expectation (apply f) q,
    named "L7 expectation f (dirac t) = f t" $
      forAll (elements ts) $ \t -> forAll (genTable @t genRational) $ \f ->
        expectation (apply f) (dirac t) == apply f t,
    named "L7 probabilityOf d s = expectation (indicator s) d" $
      forAll (genDist @t) $ \d -> forAll (genSubset @t) $ \s ->
        probabilityOf d s == expectation (\t -> if t `elem` s then 1 else 0) d,
    named "L9 meanLevel = expectation rank, within [0, n - 1]" $
      forAll (genDist @t) $ \d ->
        let m = meanLevel d
         in m == expectation rank d && 0 <= m && m <= fromIntegral (n - 1),
    named "L9 first-order dominance implies a larger mean" $
      forAll (genDist @t) $ \d -> forAll (genDist @t) $ \e -> forAll (genTable @t (elements ts)) $ \f ->
        let up t = max t (apply f t)
            raised = pushforward up d
         in dominates raised d
              && meanLevel raised >= meanLevel d
              && (not (dominates d e) || meanLevel d >= meanLevel e),
    named "L10 modes commute with bijections" $
      forAll (genDist @t) $ \d -> forAll (genPermutation @t) $ \sigma ->
        Set.fromList (NE.toList (modes (pushforward (apply sigma) d)))
          == Set.fromList (map (apply sigma) (NE.toList (modes d))),
    named "L11 numberRecordAt reads the record in option order" $
      forAll (genWeights @t) $ \w -> record w == Just [(optionName t, weight w t) | t <- ts],
    named "L11 chance S at least" $
      forAll (genWeights @t) $ \w -> forAll (genSubset @t) $ \s ->
        forAll (genThreshold ((`probabilityOf` s) <$> distribution w)) $ \theta ->
          halfspaceLaw (chance s (subject @t) `atLeast` theta) (\d -> probabilityOf d s >= theta) w,
    named "L11 chance S no more than" $
      forAll (genWeights @t) $ \w -> forAll (genSubset @t) $ \s ->
        forAll (genThreshold ((`probabilityOf` s) <$> distribution w)) $ \theta ->
          halfspaceLaw (chance s (subject @t) `noMoreThan` theta) (\d -> probabilityOf d s <= theta) w,
    named "L11 expected level at least" $
      forAll (genWeights @t) $ \w ->
        forAll (genThreshold (meanLevel <$> distribution w)) $ \theta ->
          halfspaceLaw (expectedLevel (subject @t) `atLeast` theta) (\d -> meanLevel d >= theta) w,
    named "L11 expected level no more than" $
      forAll (genWeights @t) $ \w ->
        forAll (genThreshold (meanLevel <$> distribution w)) $ \theta ->
          halfspaceLaw (expectedLevel (subject @t) `noMoreThan` theta) (\d -> meanLevel d <= theta) w,
    named "L11 level at least l" $
      forAll (genWeights @t) $ \w -> forAll (elements ts) $ \l ->
        halfspaceLaw (levelAtLeast l (subject @t)) (\d -> meanLevel d >= rank l) w,
    named "L11 most likely t" $
      forAll (genWeights @t) $ \w -> forAll (elements ts) $ \t ->
        totalLaw (mostLikely t (subject @t)) ((t `elem`) . modes) w,
    named "L11 isDistribution is the empty region, which is the cone" $
      forAll (genWeights @t) $ \w ->
        totalLaw (isDistribution (subject @t)) (const True) w
          .&&. holds [] w == isJust (distribution w),
    named "L11 every region reads on the normalized record" $
      forAll (genWeights @t) $ \w -> forAll (listOf (genHalfspace @t)) $ \region ->
        holds region w
          == maybe False (\d -> all (\(Halfspace ws theta) -> dot ws d >= theta) region) (distribution w)
  ]
  where
    ts = options @t
    n = length ts
    named name p = (setName <> ": " <> name, p)
    holds region w = maybe False (holdsRegion region) (record w)
    dominates a b = and [probabilityOf a (above k) >= probabilityOf b (above k) | k <- ts]
    above k = [t | t <- ts, t >= k]

genHalfspace :: forall t. Options t => Gen Halfspace
genHalfspace = do
  chosen <- sublistOf (options @t)
  ws <- mapM (\t -> (,) (optionName t) <$> genRational) chosen
  Halfspace ws <$> genRational

probability :: Rational -> Prob
probability r = fromMaybe (error ("probability out of range: " <> show r)) (prob r)

-- ---------------------------------------------------------------------------
-- Laws over Bool and over the naming
-- ---------------------------------------------------------------------------

boolLaws :: [(String, Property)]
boolLaws =
  [ ("Bool: L8 probabilityOfTrue . bernoulli = id", forAll genProb $ \p -> probabilityOfTrue (bernoulli p) == p),
    ("Bool: L8 bernoulli . probabilityOfTrue = id", forAll (genDist @Bool) $ \d -> bernoulli (probabilityOfTrue d) == d),
    ( "Bool: L11 chance of yes at least",
      forAll (genWeights @Bool) $ \w ->
        forAll (genThreshold ((probValue . probabilityOfTrue) <$> distribution w)) $ \theta ->
          halfspaceLaw (chanceYes (subject @Bool) `atLeast` theta) (\d -> probValue (probabilityOfTrue d) >= theta) w
    ),
    ( "Bool: L11 chance of yes no more than",
      forAll (genWeights @Bool) $ \w ->
        forAll (genThreshold ((probValue . probabilityOfTrue) <$> distribution w)) $ \theta ->
          halfspaceLaw (chanceYes (subject @Bool) `noMoreThan` theta) (\d -> probValue (probabilityOfTrue d) <= theta) w
    ),
    ( "Swapped: L2 detects a hand-written Enum that reorders the options",
      property (Just (map optionName (options @Swapped)) /= numberFieldNames (demoteSchema (schemaWitness @(DecisionSchema Swapped))))
    ),
    ( "Nested: L11 numberRecordAt and numberFieldsAt agree at every path",
      forAll (genWeights @Colour) $ \w -> forAll (elements paths) $ \path ->
        let el = ("ticket body", (toSchemaEl w, ()))
            nested = schemaWitness @Nested
         in fmap (map fst) (numberRecordAt nested path el) == numberFieldsAt (demoteSchema nested) path
              && (path /= ["verdict"] || numberRecordAt nested path el == record w)
    ),
    ( "Halfspace: the JSON codec round-trips",
      forAll (genHalfspace @Level) $ \h -> A.fromJSON (A.toJSON h) == A.Success h
    )
  ]
  where
    paths = [[], ["ticket"], ["verdict"], ["verdict", "Red"], ["missing"]]

-- ---------------------------------------------------------------------------
-- L12: the prompt codec
-- ---------------------------------------------------------------------------

-- | Text fragments that look like the parts of a header, so that generated
-- instructions, descriptions and evidence imitate it.
lookAlikes :: [String]
lookAlikes =
  [ "Options (exactly one is right):",
    "Answers (True if the statement holds, False if it does not):",
    "Levels (from lowest to highest):",
    "Give each option the probability that it is the right one, as a number from 0 to 1. The probabilities sum to 1.",
    "Evidence:",
    "  Red: forged",
    "  Red",
    "    continued",
    ": ",
    ":"
  ]

genLine :: Gen String
genLine =
  frequency
    [ (3, listOf (elements "ab Z:-é λ\t\"")),
      (2, elements lookAlikes),
      (1, (<>) <$> elements ["", " ", "  ", "    "] <*> listOf1 (elements "xyz:")),
      (1, pure "")
    ]

genLines :: Gen String
genLines = do
  k <- frequency [(4, pure 1), (2, pure 2), (1, choose (3, 5))]
  concatWith "\n" <$> vectorOf k genLine
  where
    concatWith sep = foldr1 (\a b -> a <> sep <> b)

genName :: Gen Text
genName = T.pack <$> listOf1 (elements "abcXYZ019-_.é#\"{}λ")

genDescription :: Gen Text
genDescription = frequency [(3, pure ""), (4, T.pack <$> genLines), (1, ("\n" <>) . T.pack <$> genLines)]

genInstructions :: Gen Text
genInstructions = (T.pack <$> genLines) `suchThat` (not . T.null . T.strip)

genEvidence :: Gen Text
genEvidence =
  frequency
    [ (3, T.pack <$> genLines),
      (1, T.pack <$> listOf arbitraryPrintableChar),
      (1, pure ""),
      (2, (\q e -> renderDecisionPrompt q e) <$> genQuestion <*> (T.pack <$> genLines)),
      (1, (\s -> T.pack s <> "\r\n") <$> genLines)
    ]

genQuestion :: Gen DecisionQuestion
genQuestion = do
  form <- elements [minBound .. maxBound]
  instructions <- genInstructions
  names <- case form of
    YesNoForm -> pure ["False", "True"]
    ChoiceForm -> distinctNames =<< frequency [(9, choose (2, 8)), (1, pure 255)]
    ScaleForm -> distinctNames =<< choose (2, 10)
  descriptions <- vectorOf (length names) genDescription
  case zip names descriptions of
    first : rest -> pure (DecisionQuestion form instructions (first :| rest))
    [] -> error "genQuestion: no options"
  where
    distinctNames k =
      (take k . nub <$> vectorOf (k * 2) genName) `suchThat` ((== k) . length)

-- | A line-level mutation of a rendered header, which is usually not canonical.
genMutant :: Gen Text
genMutant = do
  q <- genQuestion
  e <- genEvidence
  let headerLines = T.splitOn "\n" (renderDecisionHeader q)
  mutated <- mutate headerLines
  pure (T.intercalate "\n" mutated <> e)
  where
    mutate ls = do
      i <- choose (0, max 0 (length ls - 1))
      let (before, after) = splitAt i ls
      extra <- T.pack <$> genLine
      oneof
        [ pure (before <> drop 1 after),
          pure (before <> take 1 after <> after),
          pure (before <> [extra] <> after),
          pure (before <> map (" " <>) (take 1 after) <> drop 1 after),
          pure (before <> map (T.drop 1) (take 1 after) <> drop 1 after),
          pure (before <> map (<> ": ") (take 1 after) <> drop 1 after),
          pure (before <> map (T.replace ": " ":") (take 1 after) <> drop 1 after),
          pure ls
        ]

-- | The lines a prompt is assembled from: the canonical spelling of each part
-- of a header, and near misses of each.
data Fragment
  = Instruction
  | InstructionMore
  | FormHeader
  | OptionLine
  | Continuation
  | Guidance
  | EvidenceLine
  | Noise
  deriving (Eq, Show, Enum, Bounded)

-- | One line for a fragment, canonical with probability 9/10.
genFragment :: Fragment -> Gen Text
genFragment fragment = frequency [(9, canonical), (1, nearMiss)]
  where
    pick = elements
    name = pick ["Red", "Blue", "False", "True", "a-1", "λ"]
    text = T.pack <$> genLine
    canonical = case fragment of
      Instruction -> pick ["Pick one", "Decide", "", "Options (exactly one is right):"]
      InstructionMore -> ("  " <>) <$> text
      FormHeader -> pick [formLine f | f <- [minBound .. maxBound]]
      OptionLine -> oneof [("  " <>) <$> name, (\n d -> "  " <> n <> ": " <> d) <$> name <*> (T.pack <$> listOf1 (elements "xy z:"))]
      Continuation -> ("    " <>) <$> text
      Guidance -> pick [guidanceText]
      EvidenceLine -> pick ["Evidence:"]
      Noise -> text
    nearMiss = case fragment of
      Instruction -> text
      InstructionMore -> (" " <>) <$> text
      FormHeader -> pick ["Options (exactly one is right): ", "options (exactly one is right):", " Levels (from lowest to highest):"]
      OptionLine ->
        oneof
          [ (\n -> "  " <> n <> ": ") <$> name,
            (\n -> "  " <> n <> ":x") <$> name,
            (\n -> "   " <> n) <$> name,
            (\n -> "  " <> n <> " x") <$> name,
            (\n -> "  " <> n <> ":") <$> name
          ]
      Continuation -> (\t -> "   " <> t) <$> text
      Guidance -> pick [guidanceText <> " ", T.init guidanceText]
      EvidenceLine -> pick ["Evidence: ", "evidence:", "Evidence"]
      Noise -> pick ["", "  ", "    ", ":"]
    formLine = \case
      ChoiceForm -> "Options (exactly one is right):"
      YesNoForm -> "Answers (True if the statement holds, False if it does not):"
      ScaleForm -> "Levels (from lowest to highest):"
    guidanceText = "Give each option the probability that it is the right one, as a number from 0 to 1. The probabilities sum to 1."

-- | Text assembled from header lines, option lines, guidance lines,
-- continuation lines and noise in arbitrary order. Most prompts follow the
-- order of the grammar, some of them perturbed by a swap, an insertion, a
-- deletion or a duplication of a line, and the others are a shuffle of those
-- lines or a sequence of fragments drawn at random. A real share of the text
-- parses.
genAssembled :: Gen Text
genAssembled = do
  ordered <- grammarOrder
  lines' <-
    frequency
      [ (6, pure ordered),
        (4, perturb ordered),
        (1, shuffle ordered),
        (1, listOf1 (elements [minBound .. maxBound] >>= genFragment))
      ]
  ending <- frequency [(2, pure "\n"), (2, ("\n" <>) <$> genEvidence), (1, pure "")]
  pure (T.intercalate "\n" lines' <> ending)
  where
    grammarOrder = do
      instruction <- genFragment Instruction
      more <- listOfUpTo 2 (genFragment InstructionMore)
      formLine <- genFragment FormHeader
      options' <- concat <$> (choose (1, 4) >>= \k -> vectorOf k optionBlock)
      guidance' <- genFragment Guidance
      evidence' <- genFragment EvidenceLine
      pure ([instruction] <> more <> [formLine] <> options' <> [guidance', evidence'])
    optionBlock = do
      option <- genFragment OptionLine
      continuations <- frequency [(3, pure []), (1, listOfUpTo 2 (genFragment Continuation))]
      pure (option : continuations)
    listOfUpTo k g = choose (0, k) >>= \m -> vectorOf m g
    perturb ls = do
      k <- choose (1, 2)
      foldr (=<<) (pure ls) (replicate k perturbOnce)
    perturbOnce ls = do
      i <- choose (0, max 0 (length ls - 1))
      let (before, after) = splitAt i ls
      extra <- elements [minBound .. maxBound] >>= genFragment
      elements
        [ before <> take 1 (drop 1 after) <> take 1 after <> drop 2 after,
          before <> [extra] <> after,
          before <> drop 1 after,
          before <> take 1 after <> after
        ]

-- | A property over prompts that reports, and requires, the share of them
-- that parse.
coverParse :: Testable prop => Double -> Double -> Text -> prop -> Property
coverParse parsed refused p =
  checkCoverage
    . cover parsed (isJust (parseDecisionPrompt p)) "parses"
    . cover refused (isNothing (parseDecisionPrompt p)) "is refused"

promptLaws :: [(String, Property)]
promptLaws =
  [ ("L12 generated questions are valid", forAll genQuestion $ \q -> validDecisionQuestion q == Right ()),
    ( "L12 parseDecisionPrompt (renderDecisionPrompt q e) = Just (q, e)",
      forAll genQuestion $ \q -> forAll genEvidence $ \e ->
        parseDecisionPrompt (renderDecisionPrompt q e) == Just (q, e)
    ),
    ( "L12 the header is the prompt's prefix and ends with Evidence:",
      forAll genQuestion $ \q -> forAll genEvidence $ \e ->
        renderDecisionHeader q `T.isPrefixOf` renderDecisionPrompt q e
          && "Evidence:\n" `T.isSuffixOf` renderDecisionHeader q
    ),
    ( "L12 canonicity on mutated prompts",
      forAll genMutant $ \p ->
        coverParse 20 20 p $
          maybe True (\(q, e) -> renderDecisionPrompt q e == p) (parseDecisionPrompt p)
    ),
    ( "L12 canonicity on assembled text",
      forAll genAssembled $ \p ->
        coverParse 10 20 p $
          maybe (property True) (\(q, e) -> renderDecisionPrompt q e === p) (parseDecisionPrompt p)
    ),
    ( "L12 the single-line instructions are the prompt's first line",
      forAll genQuestion $ \q -> forAll genEvidence $ \e ->
        not (T.any (== '\n') (dqInstructions q)) ==>
          (dqInstructions q <> "\n") `T.isPrefixOf` renderDecisionPrompt q e
    )
  ]

-- | Fixed prompts the parser must refuse, because no question renders them.
nonCanonical :: [(String, Bool)]
nonCanonical =
  [ ("an empty description after a colon is refused", refused (header ["  Red: ", "  Blue"])),
    ("a continuation after a named-only option is refused", refused (header ["  Red", "    more", "  Blue"])),
    ("an option with three leading spaces is refused", refused (header ["   Red", "  Blue"])),
    ("a colon without a space is refused", refused (header ["  Red:x", "  Blue"])),
    ("a prompt without options is refused", refused (header [])),
    ("a missing Evidence line is refused", isNothing (parseDecisionPrompt "Pick\nOptions (exactly one is right):\n  Red\n  Blue\n")),
    ("a well-formed header parses", isJust (parseDecisionPrompt (header ["  Red", "  Blue: blue", "    second"]))),
    ("names with a colon are invalid", invalid ChoiceForm [("a:b", ""), ("c", "")]),
    ("names with whitespace are invalid", invalid ChoiceForm [("a b", ""), ("c", "")]),
    ("duplicate names are invalid", invalid ChoiceForm [("a", ""), ("a", "")]),
    ("one option is invalid", invalid ChoiceForm [("a", "")]),
    ("eleven levels are invalid", invalid ScaleForm [(T.pack ('l' : show k), "") | k <- [1 .. 11 :: Int]]),
    ("a yes/no question must be False then True", invalid YesNoForm [("True", ""), ("False", "")]),
    ("a carriage return is invalid", invalid ChoiceForm [("a", "x\ry"), ("b", "")]),
    ("blank instructions are invalid", either (const True) (const False) (validDecisionQuestion (DecisionQuestion ChoiceForm "  \n " (("a", "") :| [("b", "")])))),
    ("a half-space rational not in lowest terms is refused", halfspaceRefused "{\"numerator\":2,\"denominator\":4}"),
    ("a half-space rational with a zero denominator is refused", halfspaceRefused "{\"numerator\":1,\"denominator\":0}"),
    ("a half-space rational with a negative denominator is refused", halfspaceRefused "{\"numerator\":1,\"denominator\":-2}"),
    ("a half-space rational with an extra key is refused", halfspaceRefused "{\"numerator\":1,\"denominator\":2,\"sign\":1}"),
    ("a half-space rational with a decimal numerator is refused", halfspaceRefused "{\"numerator\":1.0,\"denominator\":2}"),
    ("a half-space rational with a negative exponent is refused", halfspaceRefused "{\"numerator\":1,\"denominator\":10e-1}"),
    ("a half-space rational reads the integer 10", halfspaceReads "{\"numerator\":10,\"denominator\":1}" 10),
    ("a half-space rational reads the integer 100", halfspaceReads "{\"numerator\":1,\"denominator\":100}" (1 % 100)),
    ("a half-space rational reads 1e1 as the integer 10", halfspaceReads "{\"numerator\":1e1,\"denominator\":1}" 10)
  ]
  where
    guidanceLine = "Give each option the probability that it is the right one, as a number from 0 to 1. The probabilities sum to 1."
    header optionLines =
      T.unlines (["Pick", "Options (exactly one is right):"] <> optionLines <> [guidanceLine, "Evidence:"]) <> "tail"
    refused = isNothing . parseDecisionPrompt
    halfspaceWith rational = "{\"weights\":[{\"option\":\"Red\",\"weight\":" <> rational <> "}],\"atLeast\":{\"numerator\":0,\"denominator\":1}}"
    halfspaceRefused rational = isNothing (A.decode (halfspaceWith rational) :: Maybe Halfspace)
    halfspaceReads rational value = A.decode (halfspaceWith rational) == Just (Halfspace [("Red", value)] 0)
    invalid form opts = case opts of
      first : rest -> either (const True) (const False) (validDecisionQuestion (DecisionQuestion form "Pick" (first :| rest)))
      [] -> False

-- ---------------------------------------------------------------------------
-- Driver
-- ---------------------------------------------------------------------------

main :: IO ()
main = do
  let properties = lawsFor @Colour "Colour" <> lawsFor @Level "Level" <> lawsFor @Bool "Bool" <> boolLaws <> promptLaws
      args = stdArgs {maxSuccess = 300, chatty = False}
  results <- mapM (\(name, p) -> (,) name <$> quickCheckWithResult args p) properties
  let propertyFailures = [name | (name, result) <- results, not (isSuccess result)]
      cases = sum (map (numTests . snd) results)
  mapM_ (\(name, result) -> putStrLn ("FAIL " <> name) >> putStr (output result)) [r | r@(_, result) <- results, not (isSuccess result)]
  mapM_ (putStrLn . coverage) [r | r@(_, result) <- results, isSuccess result, not (Map.null (classes result))]
  let fixedFailures = [name | (name, ok) <- nonCanonical, not ok]
  mapM_ (putStrLn . ("FAIL " <>)) fixedFailures
  let failures = propertyFailures <> fixedFailures
  if null failures
    then
      putStrLn
        ( "decision probe: "
            <> show (length properties)
            <> " properties over "
            <> show cases
            <> " cases and "
            <> show (length nonCanonical)
            <> " fixed checks passed"
        )
    else do
      putStrLn ("decision probe: " <> show (length failures) <> " failed: " <> show (sort failures))
      exitFailure
  where
    coverage (name, result) =
      name
        <> ": "
        <> intercalate
          ", "
          [ className <> " " <> show (100 * count `div` max 1 (numTests result)) <> "%"
          | (className, count) <- Map.toList (classes result)
          ]
        <> " of "
        <> show (numTests result)
        <> " cases"
