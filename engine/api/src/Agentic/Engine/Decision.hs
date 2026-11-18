{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The neutral form of a decision question, which an engine that answers
-- decisions natively reads beside the prompt.
module Agentic.Engine.Decision
  ( EngineDecisionForm (..),
    EngineOption (..),
    EngineDecision (..),
    encodeEngineDecision,
    decodeEngineDecision,
  )
where

import Data.Aeson (Key, Value (..), object, (.=))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import Data.Foldable (toList)
import Data.List (nub)
import Data.List.NonEmpty (NonEmpty, nonEmpty)
import Data.Text (Text)

-- | The structure of the option set O, which selects the wire primitive that
-- asks the question. 'EngineChoice' denotes a set without structure,
-- 'EngineYesNo' denotes the two-point set of truth values, and 'EngineScale'
-- denotes a set totally ordered by its listing. The form does not change the
-- answer, which is a point of Δ(O) in every form.
data EngineDecisionForm = EngineChoice | EngineYesNo | EngineScale
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | One element of the option set O: its name, which is injective on O, and
-- the description that the author gave, if any.
data EngineOption = EngineOption
  { engineOptionName :: !Text,
    engineOptionDescription :: !(Maybe Text)
  }
  deriving (Eq, Show)

-- | A decision question in neutral form. Denotes the question whose answer is
-- a point of Δ(O), with O the listed options.
--
-- Answer contract: an engine that answers 'Agentic.Engine.engineDecision'
-- natively returns as 'Agentic.Engine.engineAnswer' a JSON object whose keys
-- are exactly the option names, in option order, each a finite decimal in
-- [0,1], with a positive sum, and reports 'Agentic.Engine.Completed'. An engine
-- that does not answer natively ignores the field and answers
-- 'Agentic.Engine.enginePrompt', which carries the same question in words.
--
-- A valid decision has distinct, non-empty option names, and an 'EngineYesNo'
-- decision has exactly the names @False@ and @True@ in that order.
data EngineDecision = EngineDecision
  { engineDecisionForm :: !EngineDecisionForm,
    engineDecisionInstructions :: !Text,
    engineDecisionOptions :: !(NonEmpty EngineOption),
    engineDecisionEvidence :: !Text
  }
  deriving (Eq, Show)

-- | The JSON object
-- @{"form": f, "instructions": t, "options": [{"name": n, "description": null | t}], "evidence": t}@,
-- with @f@ one of @choice@, @yes-no@ and @scale@. For every valid decision
-- @d@, @decodeEngineDecision (encodeEngineDecision d) = Right d@.
encodeEngineDecision :: EngineDecision -> Value
encodeEngineDecision decision =
  object
    [ "form" .= formName (engineDecisionForm decision),
      "instructions" .= engineDecisionInstructions decision,
      "options" .= map option (toList (engineDecisionOptions decision)),
      "evidence" .= engineDecisionEvidence decision
    ]
  where
    option entry =
      object
        [ "name" .= engineOptionName entry,
          "description" .= engineOptionDescription entry
        ]

-- | Reads exactly the encoding of 'encodeEngineDecision', and refuses an
-- unknown or missing field, a field of the wrong type, an empty option list
-- and every invalid decision.
decodeEngineDecision :: Value -> Either Text EngineDecision
decodeEngineDecision (Object fields) = do
  _ <- exactFields "engine decision" ["form", "instructions", "options", "evidence"] fields
  form <- textField fields "form" >>= formOf
  instructions <- textField fields "instructions"
  entries <-
    field fields "options" >>= \case
      Array values -> traverse option (toList values)
      _ -> Left "engine decision field 'options' is not an array"
  evidence <- textField fields "evidence"
  options <- maybe (Left "engine decision has no options") Right (nonEmpty entries)
  validNames form (map engineOptionName entries)
  Right (EngineDecision form instructions options evidence)
  where
    validNames form names
      | "" `elem` names = Left "engine decision has an option with an empty name"
      | nub names /= names = Left "engine decision has two options with one name"
      | form == EngineYesNo && names /= ["False", "True"] =
          Left "engine yes-no decision does not have exactly the options False and True"
      | otherwise = Right ()
    option (Object entry) = do
      _ <- exactFields "engine decision option" ["name", "description"] entry
      EngineOption
        <$> textField entry "name"
        <*> ( field entry "description" >>= \case
                Null -> Right Nothing
                String text -> Right (Just text)
                _ -> Left "field 'description' is neither a string nor null"
            )
    option _ = Left "engine decision option is not an object"
decodeEngineDecision _ = Left "engine decision is not an object"

formName :: EngineDecisionForm -> Text
formName EngineChoice = "choice"
formName EngineYesNo = "yes-no"
formName EngineScale = "scale"

formOf :: Text -> Either Text EngineDecisionForm
formOf text =
  case [form | form <- [minBound .. maxBound], formName form == text] of
    [form] -> Right form
    _ -> Left ("unknown engine decision form '" <> text <> "'")

exactFields :: Text -> [Key] -> KeyMap.KeyMap Value -> Either Text ()
exactFields what keys fields =
  case (filter (`notElem` keys) (KeyMap.keys fields), filter (not . (`KeyMap.member` fields)) keys) of
    (unknown : _, _) -> Left (what <> " has unknown field '" <> Key.toText unknown <> "'")
    (_, missing : _) -> Left (what <> " lacks field '" <> Key.toText missing <> "'")
    ([], []) -> Right ()

field :: KeyMap.KeyMap Value -> Key -> Either Text Value
field fields key = maybe (Left ("lacks field '" <> Key.toText key <> "'")) Right (KeyMap.lookup key fields)

textField :: KeyMap.KeyMap Value -> Key -> Either Text Text
textField fields key =
  field fields key >>= \case
    String text -> Right text
    _ -> Left ("field '" <> Key.toText key <> "' is not a string")
