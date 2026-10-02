{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

-- | The manager conformance lanes against the Lean manager oracle.
--
-- > manager-conformance-check admission [--seed S] [--n N] [--oracle PATH] [--counterexamples DIR]
-- > manager-conformance-check cases [--cases DIR] [--oracle PATH] [--counterexamples DIR]
--
-- The @admission@ lane generates admission situations from a fixed seed. For
-- each situation it computes 'oldestEligible', encodes the same situation as
-- a coordination state, and submits an @admit@ entry for each queued
-- candidate at each slot. The oracle must accept the candidate and the slot
-- that 'oldestEligible' chooses, with the expected next state, and must refuse
-- every other candidate. When 'oldestEligible' chooses nothing, the oracle
-- must refuse every entry.
--
-- The @cases@ lane replays the retained cases of @bisim/manager/cases@. The
-- response of the oracle must equal the retained response byte for byte. The
-- typed decoder of "Agentic.Manager.Test.Oracle" must refuse each request
-- that the oracle refuses as malformed, and must read every other request
-- and response back to the same bytes.
--
-- A mismatch writes a counterexample file, prints
-- @MANAGER-CONFORMANCE mismatch@, and makes the lane exit with status 1. A
-- missing oracle binary or a failed transport also exits with status 1.
module Main (main) where

import Agentic.Manager.Admission.Policy
  ( Candidate (..),
    Held (..),
    Resource (..),
    effectiveResources,
    oldestEligible,
  )
import Agentic.Manager.Test.Oracle
import Control.Exception (handle)
import Control.Monad (forM, forM_, unless, when)
import Data.Aeson (FromJSON, Value (..), eitherDecodeStrict', object, toJSON, (.=))
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import Data.Foldable (foldlM)
import Data.List (isSuffixOf, sort)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Numeric.Natural (Natural)
import System.Directory (createDirectoryIfMissing, doesFileExist, getTemporaryDirectory, listDirectory)
import System.Environment (getArgs)
import System.Exit (ExitCode (..), exitWith)
import System.FilePath ((</>))
import System.IO (BufferMode (..), hPutStrLn, hSetBuffering, stderr, stdout)
import Test.QuickCheck (Gen, choose, elements, frequency, shuffle, sublistOf, vectorOf)
import Test.QuickCheck.Gen (unGen)
import Test.QuickCheck.Random (mkQCGen)
import Text.Read (readMaybe)

-- ---------------------------------------------------------------------------
-- Command line
-- ---------------------------------------------------------------------------

data Options = Options
  { optionSeed :: !Int,
    optionCount :: !Int,
    optionOracle :: !(Maybe FilePath),
    optionCounterexamples :: !(Maybe FilePath),
    optionCases :: !FilePath
  }

defaultOptions :: Options
defaultOptions = Options 20261002 500 Nothing Nothing "bisim/manager/cases"

parseOptions :: [String] -> Either String Options
parseOptions = go defaultOptions
  where
    go o [] = Right o
    go o ("--seed" : v : rest) = number "--seed" v >>= \n -> go o {optionSeed = n} rest
    go o ("--n" : v : rest) = number "--n" v >>= \n -> go o {optionCount = n} rest
    go o ("--oracle" : v : rest) = go o {optionOracle = Just v} rest
    go o ("--counterexamples" : v : rest) = go o {optionCounterexamples = Just v} rest
    go o ("--cases" : v : rest) = go o {optionCases = v} rest
    go _ (other : _) = Left ("unknown or incomplete option " <> other)
    number flag v = maybe (Left (flag <> " needs an integer, not " <> v)) Right (readMaybe v)

usage :: String
usage =
  unlines
    [ "usage: manager-conformance-check admission [--seed S] [--n N] [--oracle PATH] [--counterexamples DIR]",
      "       manager-conformance-check cases [--cases DIR] [--oracle PATH] [--counterexamples DIR]"
    ]

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  args <- getArgs
  (lane, rest) <- case args of
    "admission" : rest -> pure (admissionLane, rest)
    "cases" : rest -> pure (casesLane, rest)
    _ -> hPutStrLn stderr usage >> exitWith (ExitFailure 2)
  options <- either (\e -> hPutStrLn stderr (e <> "\n" <> usage) >> exitWith (ExitFailure 2)) pure (parseOptions rest)
  oracle <- resolveOraclePath (optionOracle options)
  directory <- maybe ((</> "manager-conformance-counterexamples") <$> getTemporaryDirectory) pure (optionCounterexamples options)
  handle transportFailure (lane options oracle directory)

-- | A transport failure is not a conformance result. It stops the lane.
transportFailure :: OracleError -> IO a
transportFailure failure = do
  hPutStrLn stderr $ case failure of
    OracleMissing path -> "manager-conformance-check: oracle binary not found, and the lane is not green: " <> path
    OracleTimeout path -> "manager-conformance-check: the oracle wrote no response in time: " <> path
    OracleClosed path reason -> "manager-conformance-check: the oracle pipe failed: " <> path <> ": " <> reason
    OracleUnreadable path line reason ->
      "manager-conformance-check: the oracle wrote a line outside the encoding: " <> path <> ": " <> reason <> ": " <> BSC.unpack line
  exitWith (ExitFailure 1)

-- ---------------------------------------------------------------------------
-- Mismatches
-- ---------------------------------------------------------------------------

-- | One disagreement, with the request and both outcomes.
data Mismatch = Mismatch
  { mismatchReason :: !Text,
    mismatchRequest :: !Value,
    mismatchExpected :: !Value,
    mismatchOracle :: !Value
  }

-- | Write the counterexample @<directory>/<name>.json@ and report it.
retain :: FilePath -> Maybe Int -> String -> Mismatch -> IO ()
retain directory seed name Mismatch {..} = do
  createDirectoryIfMissing True directory
  let path = directory </> (name <> ".json")
  BS.writeFile path . (<> "\n") . encodeLine $
    object
      [ "seed" .= seed,
        "name" .= name,
        "reason" .= mismatchReason,
        "request" .= mismatchRequest,
        "expected" .= mismatchExpected,
        "oracle" .= mismatchOracle
      ]
  putStrLn ("MANAGER-CONFORMANCE mismatch " <> name <> ": " <> T.unpack mismatchReason <> " (" <> path <> ")")

-- | End a lane: status 1 after any mismatch, status 0 otherwise.
finish :: String -> Int -> IO ()
finish lane mismatches
  | mismatches == 0 = putStrLn ("MANAGER-CONFORMANCE " <> lane <> " PASS")
  | otherwise = do
      putStrLn ("MANAGER-CONFORMANCE " <> lane <> " FAIL mismatches=" <> show mismatches)
      exitWith (ExitFailure 1)

-- ---------------------------------------------------------------------------
-- The admission lane
-- ---------------------------------------------------------------------------

-- | The structural readiness of the inputs of a queued request.
data Inputs = InputsReady | InputsMissing | InputsInvalid
  deriving (Eq, Show)

data SituationProfile = SituationProfile
  { profileKeys :: ![Text],
    profileOn :: !Bool
  }

data SituationCandidate = SituationCandidate
  { candidateProfileIndex :: !Int,
    candidateQueueOrdinal :: !Natural,
    candidateInputs :: !Inputs
  }

-- | Profiles, queued candidates, held reservations and the slot limit.
data Situation = Situation
  { situationLimit :: !Int,
    situationProfiles :: ![SituationProfile],
    situationHeld :: ![Held],
    situationCandidates :: ![SituationCandidate]
  }

operatorKeys :: [Text]
operatorKeys = ["a", "b", "c", "d"]

-- | Held reservations occupy distinct slots below the limit and hold disjoint
-- keys, as the reservation exclusivity of the model requires. Queue ordinals
-- are distinct, as the store assigns them.
genSituation :: Gen Situation
genSituation = do
  situationLimit <- choose (1, 4)
  profileCount <- choose (1, 4)
  situationProfiles <-
    vectorOf profileCount $
      SituationProfile <$> sublistOf operatorKeys <*> frequency [(4, pure True), (1, pure False)]
  heldSlots <- sublistOf [0 .. situationLimit - 1]
  let universe = map OperatorResource operatorKeys <> [UnclassifiedResource]
  owners <- forM universe $ \resource ->
    if null heldSlots
      then pure Nothing
      else frequency [(2, pure Nothing), (1, Just . (,) resource <$> elements heldSlots)]
  let situationHeld =
        [Held slot (Set.fromList [resource | Just (resource, owner) <- owners, owner == slot]) | slot <- heldSlots]
  count <- choose (1, 6)
  ordinals <- take count <$> shuffle [0 .. 11 :: Natural]
  situationCandidates <- forM ordinals $ \ordinal ->
    SituationCandidate
      <$> choose (0, profileCount - 1)
      <*> pure ordinal
      <*> frequency [(4, pure InputsReady), (1, pure InputsMissing), (1, pure InputsInvalid)]
  pure Situation {..}

tshow :: Show a => a -> Text
tshow = T.pack . show

requestName, profileName, profileRevisionName, slotName, heldName :: Int -> Text
requestName n = "request-" <> tshow n
profileName n = "profile-" <> tshow n
profileRevisionName n = "profile-revision-" <> tshow n
slotName n = "slot-" <> tshow n
heldName n = "held-" <> tshow n

-- | Operator keys and the unclassified cohort have distinct names.
resourceName :: Resource -> Text
resourceName (OperatorResource key) = "key:" <> key
resourceName UnclassifiedResource = "unclassified"

encodedResources :: Set.Set Resource -> Set.Set Text
encodedResources = Set.map resourceName

profileAt :: Situation -> Int -> SituationProfile
profileAt situation index = situationProfiles situation !! index

-- | The candidates of the policy, in the order of the situation.
policyCandidates :: Situation -> [Candidate]
policyCandidates situation =
  [ Candidate
      { candidateRequest = requestName index,
        candidateOrdinal = toInteger (candidateQueueOrdinal c),
        candidateEnabled = profileOn profile,
        candidateReady = candidateInputs c == InputsReady,
        candidateResources = effectiveResources (profileKeys profile)
      }
    | (index, c) <- zip [0 ..] (situationCandidates situation),
      let profile = profileAt situation (candidateProfileIndex c)
  ]

encodeProfile :: Int -> SituationProfile -> Profile
encodeProfile index p =
  Profile (profileRevisionName index) (profileOn p) (encodedResources (effectiveResources (profileKeys p)))

encodeInputs :: Inputs -> Readiness
encodeInputs inputs = case inputs of
  InputsReady -> Readiness required supplied Set.empty
  InputsMissing -> Readiness required Map.empty Set.empty
  InputsInvalid -> Readiness required supplied required
  where
    required = Set.singleton "input-1"
    supplied = Map.singleton "input-1" "capture-1"

encodeCandidate :: SituationCandidate -> Request
encodeCandidate c =
  Request
    { requestRevision = "request-revision-1",
      requestProfile = profileName (candidateProfileIndex c),
      requestProfileRevision = profileRevisionName (candidateProfileIndex c),
      requestPhase = PhaseQueued,
      requestQueueOrdinal = Just (candidateQueueOrdinal c),
      requestInputs = encodeInputs (candidateInputs c),
      requestPreparation = Nothing,
      requestRun = Nothing
    }

-- | The coordination state of a situation.
encodeSituation :: Situation -> Coordination
encodeSituation situation =
  (emptyCoordination "generation-1" "authority-1")
    { coordinationSlots = Set.fromList (map slotName [0 .. situationLimit situation - 1]),
      coordinationProfiles =
        Map.fromList [(profileName i, encodeProfile i p) | (i, p) <- zip [0 ..] (situationProfiles situation)],
      coordinationRequests =
        Map.fromList [(requestName i, encodeCandidate c) | (i, c) <- zip [0 ..] (situationCandidates situation)],
      coordinationReservations =
        Map.fromList
          [(heldName slot, Reservation (slotName slot) (encodedResources keys)) | Held slot keys <- situationHeld situation]
    }

-- | The admit entry of one candidate at one slot, with the stored profile and
-- the keys of that profile.
admitEntry :: Situation -> Int -> Int -> Entry
admitEntry situation index slot =
  EntryStep (StepAdmit (requestName index) (encodeCandidate c) profile (Reservation (slotName slot) (profileResources profile)))
  where
    c = situationCandidates situation !! index
    profile = encodeProfile (candidateProfileIndex c) (profileAt situation (candidateProfileIndex c))

-- | The state after the policy admits a candidate at a slot.
expectedAdmission :: Situation -> Int -> Int -> Coordination
expectedAdmission situation index slot =
  state
    { coordinationRequests = Map.adjust (\r -> r {requestPhase = PhasePreparing}) (requestName index) (coordinationRequests state),
      coordinationReservations = Map.insert (requestName index) (Reservation (slotName slot) (profileResources profile)) (coordinationReservations state)
    }
  where
    state = encodeSituation situation
    c = situationCandidates situation !! index
    profile = encodeProfile (candidateProfileIndex c) (profileAt situation (candidateProfileIndex c))

data Tally = Tally
  { tallyAccepted :: !Int,
    tallyRefused :: !Int,
    tallySubmissions :: !Int,
    tallyOracleAccepted :: !Int,
    tallyOracleRefused :: !Int,
    tallyMismatches :: !Int
  }

admissionLane :: Options -> FilePath -> FilePath -> IO ()
admissionLane options path directory = do
  let seed = optionSeed options
      count = optionCount options
      situations = unGen (vectorOf count genSituation) (mkQCGen seed) 30
  putStrLn ("manager-conformance-check admission: seed=" <> show seed <> " n=" <> show count <> " oracle=" <> path)
  Tally {..} <- withOracle path $ \oracle ->
    foldlM (situationCheck oracle seed directory) (Tally 0 0 0 0 0 0) (zip [0 ..] situations)
  putStrLn $
    "MANAGER-CONFORMANCE admission situations=" <> show count
      <> " accepted=" <> show tallyAccepted
      <> " refused=" <> show tallyRefused
      <> " submissions=" <> show tallySubmissions
      <> " oracle-accepted=" <> show tallyOracleAccepted
      <> " oracle-refused=" <> show tallyOracleRefused
      <> " mismatches=" <> show tallyMismatches
  when (tallyMismatches == 0 && (tallyAccepted == 0 || tallyRefused == 0)) $ do
    putStrLn "MANAGER-CONFORMANCE admission FAIL: the situations do not contain both accepted and refused cases"
    exitWith (ExitFailure 1)
  finish "admission" tallyMismatches

-- | Submit every candidate at every slot of one situation, and compare the
-- responses with the choice of the policy. The first disagreement of the
-- situation is retained.
situationCheck :: Oracle -> Int -> FilePath -> Tally -> (Int, Situation) -> IO Tally
situationCheck oracle seed directory tally (number, situation) = do
  let state = encodeSituation situation
      held = situationHeld situation
      choice = oldestEligible (situationLimit situation) held (policyCandidates situation)
      chosen = [(index, slot) | Just (c, slot) <- [choice], (index, d) <- zip [0 ..] (policyCandidates situation), candidateRequest d == candidateRequest c]
      submissions = [(index, slot) | index <- [0 .. length (situationCandidates situation) - 1], slot <- [0 .. situationLimit situation - 1]]
  outcomes <- forM submissions $ \(index, slot) -> do
    let query = Query state emptyEvidence (admitEntry situation index slot)
    (_, response) <- submit oracle query
    pure (query, index, slot, response)
  let judged = [(query, response, judge index slot) | (query, index, slot, response) <- outcomes]
      -- The policy chooses the lowest free slot. The model accepts the
      -- chosen candidate at any free slot, so another slot of the chosen
      -- candidate is not compared, except that the response must not be an
      -- error.
      judge index slot = case chosen of
        [(cIndex, cSlot)]
          | index == cIndex && slot == cSlot -> Just (ResponseAccepted (expectedAdmission situation cIndex cSlot))
          | index == cIndex -> Nothing
        _ -> Just ResponseRefused
      firstMismatch =
        [ Mismatch (reason expected response) (toJSON query) (maybe (String "any response of the encoding") toJSON expected) (toJSON response)
          | (query, response, expected) <- judged,
            disagrees expected response
        ]
      accepted = length [() | (_, ResponseAccepted _, _) <- judged]
  case firstMismatch of
    m : _ -> retain directory (Just seed) (show number) m
    [] -> pure ()
  pure
    tally
      { tallyAccepted = tallyAccepted tally + fromEnum (isJust choice),
        tallyRefused = tallyRefused tally + fromEnum (not (isJust choice)),
        tallySubmissions = tallySubmissions tally + length outcomes,
        tallyOracleAccepted = tallyOracleAccepted tally + accepted,
        tallyOracleRefused = tallyOracleRefused tally + length outcomes - accepted,
        tallyMismatches = tallyMismatches tally + fromEnum (not (null firstMismatch))
      }
  where
    disagrees Nothing (ResponseError _) = True
    disagrees Nothing _ = False
    disagrees (Just expected) response = expected /= response
    reason _ (ResponseError message) = "the oracle refuses a well-formed request: " <> message
    reason (Just ResponseRefused) (ResponseAccepted _) = "the oracle accepts a candidate or slot that oldestEligible does not choose"
    reason (Just (ResponseAccepted _)) ResponseRefused = "the oracle refuses the candidate and slot that oldestEligible chooses"
    reason (Just (ResponseAccepted _)) (ResponseAccepted _) = "the next state of the oracle differs from the expected state"
    reason _ _ = "the oracle response differs from the expected response"

-- ---------------------------------------------------------------------------
-- The cases lane
-- ---------------------------------------------------------------------------

casesLane :: Options -> FilePath -> FilePath -> IO ()
casesLane options path directory = do
  let dir = optionCases options
  names <- sort . filter (".request.json" `isSuffixOf`) <$> listDirectory dir
  when (null names) $ do
    hPutStrLn stderr ("manager-conformance-check: no retained cases in " <> dir)
    exitWith (ExitFailure 1)
  putStrLn ("manager-conformance-check cases: dir=" <> dir <> " cases=" <> show (length names) <> " oracle=" <> path)
  results <- withOracle path $ \oracle -> forM names $ \file -> do
    let name = take (length file - length (".request.json" :: String)) file
    request <- oneLine (dir </> file)
    expected <- oneLine (dir </> (name <> ".expected.json"))
    reply <- exchangeLine oracle request
    let mismatch = caseMismatch request expected reply
    forM_ mismatch (retain directory Nothing name)
    pure (classify expected, isJust mismatch)
  let total kind = length [() | (k, _) <- results, k == kind]
      mismatches = length (filter snd results)
  putStrLn $
    "MANAGER-CONFORMANCE cases cases=" <> show (length results)
      <> " accepted=" <> show (total "accepted")
      <> " refused=" <> show (total "refused")
      <> " error=" <> show (total "error")
      <> " mismatches=" <> show mismatches
  finish "cases" mismatches
  where
    classify expected = case decodeLine expected of
      Right (ResponseAccepted _) -> "accepted"
      Right ResponseRefused -> "refused"
      Right (ResponseError _) -> "error"
      Left _ -> "unreadable" :: String

-- | The single line of a retained file, without its line break.
oneLine :: FilePath -> IO BS.ByteString
oneLine file = do
  present <- doesFileExist file
  unless present $ do
    hPutStrLn stderr ("manager-conformance-check: missing retained file " <> file)
    exitWith (ExitFailure 1)
  bytes <- BSC.dropWhileEnd (`elem` ("\r\n" :: String)) <$> BS.readFile file
  when (BSC.elem '\n' bytes) $ do
    hPutStrLn stderr ("manager-conformance-check: retained file holds more than one line: " <> file)
    exitWith (ExitFailure 1)
  pure bytes

decodeLine :: FromJSON a => BS.ByteString -> Either String a
decodeLine = eitherDecodeStrict'

-- | Compare the reply of the oracle with the retained response, and the typed
-- codec of this client with both retained files.
caseMismatch :: BS.ByteString -> BS.ByteString -> BS.ByteString -> Maybe Mismatch
caseMismatch request expected reply =
  case problems of
    [] -> Nothing
    reason : _ -> Just (Mismatch reason (text request) (text expected) (text reply))
  where
    text = String . T.pack . BSC.unpack
    expectedResponse = decodeLine expected :: Either String Response
    typedRequest = decodeLine request :: Either String Query
    problems =
      [ "the oracle response differs from the retained response byte for byte" | reply /= expected ]
        <> either (\e -> ["the client cannot decode the retained response: " <> T.pack e]) (const []) expectedResponse
        <> case (expectedResponse, typedRequest) of
          (Right (ResponseError _), Right _) -> ["the client decodes a request that the oracle refuses as malformed"]
          (Right (ResponseError _), Left _) -> []
          (Right _, Left e) -> ["the client cannot decode a request that the oracle reads: " <> T.pack e]
          (Right _, Right query)
            | encodeLine query /= request -> ["the client encodes the retained request differently"]
            | otherwise -> []
          (Left _, _) -> []
        <> case expectedResponse of
          Right response | encodeLine response /= expected -> ["the client encodes the retained response differently"]
          _ -> []
