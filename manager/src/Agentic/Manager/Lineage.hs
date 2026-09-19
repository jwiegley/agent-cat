{-# LANGUAGE OverloadedStrings #-}

-- | A new request over immutable parent facts, with no launch overrides.
module Agentic.Manager.Lineage (LineageMutation (..), lineageOperation, lineageEdits) where

import Agentic.Runtime (FrontendEdit (..), LineageOperation (..))
import Control.Monad (unless)
import Data.Aeson (FromJSON (parseJSON), ToJSON (toJSON), withObject, (.:), object, (.=))
import qualified Data.Aeson.KeyMap as KM
import qualified Data.Set as Set
import Data.Text (Text)

data LineageMutation = RestartParent | ResumeParent | ForkParent ![FrontendEdit] deriving (Eq, Show)

lineageOperation :: LineageMutation -> LineageOperation
lineageOperation RestartParent = RestartRun
lineageOperation ResumeParent = ResumeRun
lineageOperation (ForkParent _) = ForkRun

lineageEdits :: LineageMutation -> [FrontendEdit]
lineageEdits (ForkParent edits) = edits
lineageEdits _ = []

instance FromJSON LineageMutation where
  parseJSON = withObject "lineage request" $ \o -> do
    operation <- o .: "operation"
    case operation :: Text of
      "restart" -> closed ["operation"] o >> pure RestartParent
      "resume" -> closed ["operation"] o >> pure ResumeParent
      "fork" -> do
        closed ["operation","edits"] o
        raw <- o .: "edits"
        edits <- traverse parseJSON raw
        unless (map toJSON edits == raw) (fail "canonical lineage edits")
        let occurrence (DropAnswer ident) = ident
            occurrence (ReplaceAnswer ident _) = ident
        unless (length edits <= 2048 && Set.size (Set.fromList (map occurrence edits)) == length edits) (fail "lineage edits")
        pure (ForkParent edits)
      _ -> fail "lineage operation"
    where closed keys o = unless (Set.fromList (KM.keys o) == Set.fromList keys) (fail "lineage fields")

instance ToJSON LineageMutation where
  toJSON value = object $ ["operation" .= lineageOperation value] <> case value of
    ForkParent edits -> ["edits" .= edits]
    _ -> []
