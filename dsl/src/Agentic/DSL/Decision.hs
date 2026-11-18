{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- |
-- Module      : Agentic.DSL.Decision
-- Description : The planning vocabulary of decisions: the prompt codec, regions, and record projection.
--
-- A decision question travels inside an ordinary model question, as a header
-- in a fixed grammar followed by the evidence. 'renderDecisionPrompt' writes
-- the header and 'parseDecisionPrompt' reads it back, and the two are inverse
-- on valid questions (law L12). A region is a finite list of half-spaces of
-- the simplex Δ(T), and 'holdsRegion' reads it homogeneously on any record of
-- ℚ^T, so that it agrees with reading the half-spaces on the normalized
-- distribution (law L11).
module Agentic.DSL.Decision
  ( DecisionForm (..),
    DecisionQuestion (..),
    validDecisionQuestion,
    renderDecisionHeader,
    renderDecisionPrompt,
    parseDecisionPrompt,
    decisionSchemaRep,
    numberFieldNames,

    -- * Regions
    Halfspace (..),
    holdsRegion,
    numberRecordAt,
    numberFieldsAt,
  )
where

import Agentic.Schema
  ( SSchema (..),
    Schema (SchemaProperty),
    SchemaEl,
    SchemaRep (..),
    SchemaWitness,
    withSchema,
  )
import Control.Monad (unless, when)
import Data.Aeson (FromJSON (..), ToJSON (..), Value (Number), object, withObject, withScientific, (.:), (.=))
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson.Types (Parser)
import Data.Char (isSpace)
import Data.List (nub, sort)
import Data.List.NonEmpty (NonEmpty ((:|)))
import qualified Data.List.NonEmpty as NE
import Data.Proxy (Proxy (..))
import Data.Ratio (denominator, numerator, (%))
import qualified Data.Scientific as Sci
import Data.Text (Text)
import qualified Data.Text as T
import GHC.TypeLits (KnownSymbol, symbolVal)

-- ---------------------------------------------------------------------------
-- Questions
-- ---------------------------------------------------------------------------

-- | The wire primitive that asks a decision: a choice among unstructured
-- options, a yes/no question over Bool, or a scale over ordered levels. Every
-- form denotes a question whose answer is a point of Δ(T), so the form does
-- not change the answer type.
data DecisionForm = ChoiceForm | YesNoForm | ScaleForm
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | The data that fixes what a decision asks: the form, the instructions, and
-- the finite option set T as (name, description) pairs in option order. An
-- empty description means that the option is named only.
data DecisionQuestion = DecisionQuestion
  { dqForm :: !DecisionForm,
    dqInstructions :: !Text,
    dqOptions :: !(NonEmpty (Text, Text))
  }
  deriving (Eq, Show)

-- | @Right ()@ exactly when the instructions are non-empty after stripping, no
-- text contains a carriage return, every name is non-empty with no whitespace
-- and no colon, the names are distinct, a yes/no question has exactly the
-- options False and True in that order, a choice has 2 to 255 options, and a
-- scale has 2 to 10 levels.
validDecisionQuestion :: DecisionQuestion -> Either Text ()
validDecisionQuestion (DecisionQuestion form instructions optionList) = do
  when (T.null (T.strip instructions)) (Left "a decision needs instructions")
  when (any (T.any (== '\r')) (instructions : names <> descriptions)) $
    Left "a decision's text contains a carriage return"
  mapM_ checkName names
  unless (length (nub names) == length names) (Left "a decision names an option twice")
  case form of
    YesNoForm ->
      unless (names == ["False", "True"]) $
        Left "a yes/no decision has exactly the options False and True"
    ChoiceForm -> count "choice" 255
    ScaleForm -> count "scale" 10
  where
    names = map fst (NE.toList optionList)
    descriptions = map snd (NE.toList optionList)
    checkName name
      | T.null name = Left "a decision option needs a name"
      | T.any (\c -> isSpace c || c == ':') name =
          Left ("a decision option name has whitespace or a colon: " <> name)
      | otherwise = Right ()
    count noun upper =
      unless (length names >= 2 && length names <= upper) $
        Left
          ( "a "
              <> noun
              <> " takes from 2 to "
              <> T.pack (show (upper :: Int))
              <> " options, and this one has "
              <> T.pack (show (length names))
          )

formHeader :: DecisionForm -> Text
formHeader = \case
  ChoiceForm -> "Options (exactly one is right):"
  YesNoForm -> "Answers (True if the statement holds, False if it does not):"
  ScaleForm -> "Levels (from lowest to highest):"

guidance :: Text
guidance =
  "Give each option the probability that it is the right one, as a number from 0 to 1. The probabilities sum to 1."

evidenceLine :: Text
evidenceLine = "Evidence:"

-- | The header of a decision prompt, in the canonical grammar
--
-- > prompt     ::= instr1 "\n" ("  " line "\n")* formHeader "\n" option+ guidance "Evidence:\n" evidence
-- > option     ::= "  " name (": " line)? "\n" ("    " line "\n")*
--
-- It ends with @"Evidence:\\n"@. The first line of the instructions comes
-- first, so a scripted row keyed by the instructions matches the prompt as a
-- prefix when the instructions are one line.
renderDecisionHeader :: DecisionQuestion -> Text
renderDecisionHeader (DecisionQuestion form instructions optionList) =
  T.concat
    ( instructionLines
        <> [formHeader form <> "\n"]
        <> concatMap optionLines (NE.toList optionList)
        <> [guidance <> "\n", evidenceLine <> "\n"]
    )
  where
    instructionLines = case T.splitOn "\n" instructions of
      first : rest -> (first <> "\n") : map (\l -> "  " <> l <> "\n") rest
      [] -> ["\n"]
    optionLines (name, description)
      | T.null description = ["  " <> name <> "\n"]
      | otherwise = case T.splitOn "\n" description of
          first : rest -> ("  " <> name <> ": " <> first <> "\n") : map (\l -> "    " <> l <> "\n") rest
          [] -> ["  " <> name <> "\n"]

-- | @renderDecisionPrompt q e = renderDecisionHeader q <> e@. The evidence is
-- the verbatim tail, so text inside it cannot forge the header.
renderDecisionPrompt :: DecisionQuestion -> Text -> Text
renderDecisionPrompt question evidence = renderDecisionHeader question <> evidence

-- | The inverse of 'renderDecisionPrompt' (law L12):
--
-- > parseDecisionPrompt (renderDecisionPrompt q e) == Just (q, e)    for valid q
-- > parseDecisionPrompt p == Just (q, e)  ⇒  renderDecisionPrompt q e == p
--
-- The parser recognises a line by its indentation. A form header is at column
-- 0, an option line has exactly two leading spaces followed by a non-space,
-- and a continuation line has four leading spaces. It accepts only canonical
-- text, and it does not check 'validDecisionQuestion'.
parseDecisionPrompt :: Text -> Maybe (DecisionQuestion, Text)
parseDecisionPrompt prompt = do
  (first, afterFirst) <- line prompt
  let (continuations, afterInstructions) = indented "  " afterFirst
  (headerText, afterHeader) <- line afterInstructions
  form <- lookup headerText [(formHeader f, f) | f <- [minBound .. maxBound]]
  (optionList, afterOptions) <- optionsFrom afterHeader
  (guidanceText, afterGuidance) <- line afterOptions
  unless (guidanceText == guidance) Nothing
  (evidenceText, evidence) <- line afterGuidance
  unless (evidenceText == evidenceLine) Nothing
  firstOption : moreOptions <- pure optionList
  pure
    ( DecisionQuestion
        { dqForm = form,
          dqInstructions = T.intercalate "\n" (first : continuations),
          dqOptions = firstOption :| moreOptions
        },
      evidence
    )
  where
    line text = case T.breakOn "\n" text of
      (_, rest) | T.null rest -> Nothing
      (content, rest) -> Just (content, T.drop 1 rest)
    -- The lines that start with the given prefix, without it, up to the
    -- first line that does not.
    indented prefix text = case line text of
      Just (content, rest)
        | Just body <- T.stripPrefix prefix content ->
            let (more, remaining) = indented prefix rest in (body : more, remaining)
      _ -> ([], text)
    optionsFrom text = case line text of
      Just (content, rest)
        | Just body <- T.stripPrefix "  " content,
          Just (c, _) <- T.uncons body,
          not (isSpace c) -> do
            let (name, afterName) = T.break (== ':') body
                (continuations, remaining) = indented "    " rest
            option <-
              if T.null afterName
                then if null continuations && not (T.any isSpace name) then Just (name, "") else Nothing
                else do
                  description <- T.stripPrefix ": " afterName
                  let full = T.intercalate "\n" (description : continuations)
                  if T.null full || T.any isSpace name then Nothing else Just (name, full)
            (others, final) <- optionsFrom remaining
            pure (option : others, final)
      _ -> Just ([], text)

-- | The answer record of a question, @property n₁ number (… object)@ over the
-- option names in option order.
decisionSchemaRep :: DecisionQuestion -> SchemaRep
decisionSchemaRep = foldr (\(name, _) rest -> RepProperty name RepNumber rest) RepObject . dqOptions

-- | The field names of a non-empty record of numbers, in field order, and
-- 'Nothing' for any other schema:
--
-- > numberFieldNames (decisionSchemaRep q) == Just (map fst (toList (dqOptions q)))
numberFieldNames :: SchemaRep -> Maybe [Text]
numberFieldNames rep = case numberFields rep of
  Just names@(_ : _) -> Just names
  _ -> Nothing
  where
    numberFields = \case
      RepObject -> Just []
      RepProperty name RepNumber rest -> (name :) <$> numberFields rest
      _ -> Nothing

-- ---------------------------------------------------------------------------
-- Regions
-- ---------------------------------------------------------------------------

-- | A closed half-space H(w, θ) = {p ∈ Δ(T) | ⟨w, p⟩ ≥ θ}, with w given by its
-- non-zero coordinates by option name. On a representative v of ℚ^T it is
-- read homogeneously: ⟨w, v⟩ ≥ θ·Σv.
data Halfspace = Halfspace
  { halfspaceWeights :: ![(Text, Rational)],
    halfspaceAtLeast :: !Rational
  }
  deriving (Eq, Show)

-- | @{"weights":[{"option":n,"weight":R}],"atLeast":R}@, with every rational R
-- written @{"numerator":i,"denominator":d}@ in lowest terms.
instance ToJSON Halfspace where
  toJSON (Halfspace ws atLeast) =
    object
      [ "weights" .= [object ["option" .= name, "weight" .= rationalJson c] | (name, c) <- ws],
        "atLeast" .= rationalJson atLeast
      ]

-- | The inverse of 'toJSON'. It requires exactly the keys 'toJSON' writes, and
-- it refuses a rational whose denominator is not positive or that is not in
-- lowest terms. A numerator or a denominator is an integer spelling: reading
-- the JSON number as c × 10^e with every written digit in the coefficient c,
-- the exponent e is not negative. The spellings @10@, @100@ and @1e1@ are
-- therefore integers, and @1.0@, @10e-1@ and @100e-2@ are refused. Lean's JSON
-- parser reads these spellings with exponent zero, which @getInt?@ and
-- @getNat?@ in the Lean decoder require. The two decoders differ at very large
-- exponents only: the conversion to 'Integer' is aeson's, and it also refuses
-- an exponent e greater than 1024, so @1e1025@ is refused here although Lean,
-- which bounds no exponent, reads it as an integer. Every spelling that this
-- decoder accepts is one that Lean reads with exponent zero.
instance FromJSON Halfspace where
  parseJSON = withObject "Halfspace" $ \o -> do
    exactKeys "Halfspace" ["weights", "atLeast"] o
    rawWeights <- o .: "weights"
    ws <- mapM weightEntry rawWeights
    atLeast <- o .: "atLeast" >>= rationalParse
    pure (Halfspace ws atLeast)
    where
      weightEntry = withObject "Halfspace weight" $ \o -> do
        exactKeys "Halfspace weight" ["option", "weight"] o
        name <- o .: "option"
        c <- o .: "weight" >>= rationalParse
        pure (name, c)

rationalJson :: Rational -> Value
rationalJson r = object ["numerator" .= numerator r, "denominator" .= denominator r]

rationalParse :: Value -> Parser Rational
rationalParse = withObject "rational" $ \o -> do
  exactKeys "rational" ["numerator", "denominator"] o
  i <- o .: "numerator" >>= integerParse "numerator"
  d <- o .: "denominator" >>= integerParse "denominator"
  when (d <= 0) (fail "rational: the denominator is not positive")
  unless (gcd i d == 1) (fail "rational: not in lowest terms")
  pure (i % d)

-- | An integer in the spelling that 'rationalParse' accepts: a JSON number
-- whose base-10 exponent, with every written digit in the coefficient, is not
-- negative. The conversion itself is aeson's, which bounds the exponent.
integerParse :: String -> Value -> Parser Integer
integerParse field = withScientific ("rational " <> field) $ \s -> do
  when (Sci.base10Exponent s < 0) $
    fail ("rational: the " <> field <> " is not written as an integer")
  parseJSON (Number s)

exactKeys :: String -> [Text] -> KM.KeyMap Value -> Parser ()
exactKeys ty expected o =
  unless (sort (map K.toText (KM.keys o)) == sort expected) $
    fail (ty <> ": expected exactly the keys " <> show expected)

-- | Membership in a region R, read homogeneously on a record v of ℚ^T given
-- as (name, value) pairs:
--
-- > holdsRegion R v  ⇔  v ∈ C(T) ∧ ∀ (w, θ) ∈ R. ⟨w, v⟩ ≥ θ·Σv
--
-- With R = [] this is cone membership, which is "v is a distribution". A
-- weight that names no field of v multiplies 0.
holdsRegion :: [Halfspace] -> [(Text, Rational)] -> Bool
holdsRegion region record = inCone && all holds region
  where
    total = sum (map snd record)
    inCone = all ((>= 0) . snd) record && total > 0
    value name = maybe 0 id (lookup name record)
    holds (Halfspace ws atLeast) = atLeast * total <= sum [c * value name | (name, c) <- ws]

-- | The number record at a field path inside a structured value, as
-- (name, value) pairs in field order. The empty path is the value itself. It
-- is 'Just' exactly when 'numberFieldsAt' is 'Just' at the demoted schema,
-- and then the names agree:
--
-- > fmap (map fst) (numberRecordAt w p el) == numberFieldsAt (demoteSchema w) p
numberRecordAt :: SchemaWitness s -> [Text] -> SchemaEl s -> Maybe [(Text, Rational)]
numberRecordAt witness path el = withSchema witness (\shape -> recordAt shape path el)

recordAt :: SSchema s -> [Text] -> SchemaEl s -> Maybe [(Text, Rational)]
recordAt shape path el = case path of
  [] -> case numbersOf shape el of
    Just pairs@(_ : _) -> Just pairs
    _ -> Nothing
  step : rest -> fieldOf shape step rest el

numbersOf :: SSchema s -> SchemaEl s -> Maybe [(Text, Rational)]
numbersOf shape el = case shape of
  SSObject -> Just []
  property@(SSProperty field rest) -> case field of
    SSNumber -> ((propertyName property, fst el) :) <$> numbersOf rest (snd el)
    _ -> Nothing
  _ -> Nothing

fieldOf :: SSchema s -> Text -> [Text] -> SchemaEl s -> Maybe [(Text, Rational)]
fieldOf shape step rest el = case shape of
  property@(SSProperty field others)
    | propertyName property == step -> recordAt field rest (fst el)
    | otherwise -> fieldOf others step rest (snd el)
  _ -> Nothing

propertyName :: forall name field fields. KnownSymbol name => SSchema ('SchemaProperty name field fields) -> Text
propertyName _ = T.pack (symbolVal (Proxy @name))

-- | The field names of the number record at a field path inside a schema, the
-- first-order counterpart of 'numberRecordAt'. The empty path is the schema
-- itself, and @numberFieldsAt rep [] == numberFieldNames rep@.
numberFieldsAt :: SchemaRep -> [Text] -> Maybe [Text]
numberFieldsAt rep = \case
  [] -> numberFieldNames rep
  step : rest -> case rep of
    RepProperty name field others
      | name == step -> numberFieldsAt field rest
      | otherwise -> numberFieldsAt others (step : rest)
    _ -> Nothing
