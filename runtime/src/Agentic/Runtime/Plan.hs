{-# LANGUAGE OverloadedStrings #-}

-- | Exact post-input workflow facts published by @plan --json --raw@.
module Agentic.Runtime.Plan
  ( ExactPlanSummary (..),
    PlanFold (..),
    decodeExactPlan,
  )
where

import Agentic.Runtime.Descriptor
import Control.Monad (unless, when)
import Data.Aeson (FromJSON (parseJSON), Value (..), eitherDecodeStrict', withObject, (.:))
import Data.Aeson.Key (toText)
import qualified Data.Aeson.KeyMap as KeyMap
import Data.Aeson.Types (Object, Parser, parseEither)
import qualified Data.ByteString as BS
import Data.List (nub)
import Data.Text (Text)
import qualified Data.Text as T

-- | One run of equal request-occurrence count in the exact cost histogram.
data PlanFold = PlanFold
  { planFoldConsults :: !Integer,
    planFoldPaths :: !Integer
  }
  deriving (Eq, Show)

-- | The non-program facts of one workflow after its exact inputs are supplied.
data ExactPlanSummary = ExactPlanSummary
  { exactPlanDescriptor :: !WorkflowDescriptor,
    exactPlanCodes :: !(Maybe [Text]),
    exactPlanFold :: ![PlanFold]
  }
  deriving (Eq, Show)

-- | Decode the exact summary and return its opaque raw program separately.
decodeExactPlan :: BS.ByteString -> Either Text (ExactPlanSummary, Value)
decodeExactPlan bytes = do
  value <- either (Left . T.pack) Right (eitherDecodeStrict' bytes)
  either (Left . T.pack) Right (parseEither parseExactPlan value)

parseExactPlan :: Value -> Parser (ExactPlanSummary, Value)
parseExactPlan = withObject "exact workflow plan" $ \object -> do
  program <- object .: "program"
  case program of
    Object _ -> pure ()
    _ -> fail "exact workflow plan program is not an object"
  codes <- object .: "codes"
  folds <- object .: "fold"
  when (length folds > 4096) (fail "exact workflow plan fold exceeds 4096 rows")
  case codes of
    Nothing -> pure ()
    Just values -> do
      when (length values > 1048576) (fail "exact workflow plan code sequence is oversized")
      unless (all validCode values) (fail "exact workflow plan code sequence is invalid")
  let descriptorObject = KeyMap.delete "program" (KeyMap.delete "codes" (KeyMap.delete "fold" object))
  descriptor <- parseJSON (Object descriptorObject)
  unless (workflowDescriptorVersion descriptor == descriptorVersion) $
    fail "exact workflow plan descriptor version is not 2"
  validateFold descriptor folds
  pure (ExactPlanSummary descriptor codes folds, program)
  where
    validCode value = not (T.null value) && T.length value <= 256 && not (T.any (`elem` ['\NUL', '\n', '\r']) value)

instance FromJSON PlanFold where
  parseJSON = withObject "exact workflow plan fold row" $ \object -> do
    onlyKeys "exact workflow plan fold row" ["consults", "paths"] object
    consults <- object .: "consults"
    paths <- object .: "paths"
    when (consults < 0) (fail "exact workflow plan fold consults is negative")
    when (paths <= 0) (fail "exact workflow plan fold paths is not positive")
    pure (PlanFold consults paths)

validateFold :: WorkflowDescriptor -> [PlanFold] -> Parser ()
validateFold descriptor folds = do
  let paths = sum (map planFoldPaths folds)
      values = map planFoldConsults folds
  unless (paths == workflowPaths descriptor) (fail "exact workflow plan fold paths disagree with summary")
  unless (length values == length (nub values)) (fail "exact workflow plan fold has duplicate consult counts")
  case values of
    [] -> unless (workflowMinFold descriptor == Nothing && workflowMaxFold descriptor == Nothing) $
      fail "empty exact workflow plan fold has finite bounds"
    _ ->
      unless
        (workflowMinFold descriptor == Just (minimum values) && workflowMaxFold descriptor == Just (maximum values))
        (fail "exact workflow plan fold bounds disagree with summary")

onlyKeys :: String -> [Text] -> Object -> Parser ()
onlyKeys label allowed object = case filter (`notElem` allowed) (map toText (KeyMap.keys object)) of
  [] -> pure ()
  unknown -> fail (label <> " has unknown field(s): " <> T.unpack (T.intercalate ", " unknown))
