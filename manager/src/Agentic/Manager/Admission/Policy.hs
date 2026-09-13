-- | Finite oldest-eligible admission over distinct slot and resource domains.
module Agentic.Manager.Admission.Policy
  ( Resource (..), Candidate (..), Held (..), effectiveResources, oldestEligible ) where

import Data.List (find, sortOn)
import qualified Data.Set as Set
import Data.Text (Text)

-- | An operator key or the separate conservative unclassified cohort.
data Resource = OperatorResource !Text | UnclassifiedResource deriving (Eq, Ord, Show)

-- | One queued selection under current profile and structural readiness facts.
data Candidate = Candidate
  { candidateRequest :: !Text,
    candidateOrdinal :: !Integer,
    candidateEnabled :: !Bool,
    candidateReady :: !Bool,
    candidateResources :: !(Set.Set Resource)
  } deriving (Eq, Show)

-- | One occupied global slot and its complete immutable exclusive footprint.
data Held = Held !Int !(Set.Set Resource) deriving (Eq, Show)

effectiveResources :: [Text] -> Set.Set Resource
effectiveResources [] = Set.singleton UnclassifiedResource
effectiveResources keys = Set.fromList (map OperatorResource keys)

-- | Choose globally oldest eligible work, never acquire a partial key set.
oldestEligible :: Int -> [Held] -> [Candidate] -> Maybe (Candidate, Int)
oldestEligible limit held candidates
  | length held >= limit = Nothing
  | otherwise = do
      slot <- find (`Set.notMember` occupied) [0 .. limit - 1]
      candidate <- find eligible (sortOn candidateOrdinal candidates)
      pure (candidate, slot)
  where
    occupied = Set.fromList [slot | Held slot _ <- held]
    claimed = Set.unions [keys | Held _ keys <- held]
    eligible candidate = candidateEnabled candidate && candidateReady candidate
      && Set.disjoint (candidateResources candidate) claimed
