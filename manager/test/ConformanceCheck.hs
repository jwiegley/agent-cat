{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

-- | The manager conformance lanes against the Lean manager oracle.
--
-- > manager-conformance-check admission [--seed S] [--n N] [--oracle PATH] [--counterexamples DIR]
-- > manager-conformance-check cases [--cases DIR] [--oracle PATH] [--counterexamples DIR]
-- > manager-conformance-check history --root PATH [--oracle PATH] [--counterexamples DIR]
-- > manager-conformance-check refusals --root PATH [--oracle PATH] [--counterexamples DIR]
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
-- The @history@ lane reads each retained manager root at or below
-- @--root@ through a private copy. "Agentic.Manager.Test.Conformance"
-- projects its final rows and encodes its command ledger and other stored
-- facts as a history. The lane folds the history through the oracle from the
-- initial state. The oracle must accept every entry, and the final state of
-- the fold must equal the projection of the final rows on the compared
-- dimensions. The lane prints the compared dimensions and each excluded
-- field by name.
--
-- The @refusals@ lane folds the same history and derives refused variants
-- from its accepted entries with "Agentic.Manager.Test.Refusals". The oracle
-- must refuse each variant. For a class with an implementation guard, the
-- guard must also refuse the variant and admit its base, on the private copy
-- of the root or on inputs from the history. The lane requires that each
-- retained root is unchanged, prints its counts by class, and lists each
-- variant that it compares with the oracle only.
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
import Agentic.Manager.Flow (readManagerLog)
import Agentic.Manager.Protocol.Preparation (ApprovalRequest)
import Agentic.Manager.Store (CoordinationStore)
import Agentic.Manager.Test.Conformance
import Agentic.Manager.Test.Oracle
import Agentic.Manager.Test.Refusals
import Control.Exception (handle)
import Crypto.Hash (Digest, SHA256, hash)
import Data.IORef (modifyIORef', newIORef, readIORef)
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
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, getTemporaryDirectory, listDirectory)
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
    optionCases :: !FilePath,
    optionRoot :: !(Maybe FilePath)
  }

defaultOptions :: Options
defaultOptions = Options 20261002 500 Nothing Nothing "bisim/manager/cases" Nothing

parseOptions :: [String] -> Either String Options
parseOptions = go defaultOptions
  where
    go o [] = Right o
    go o ("--seed" : v : rest) = number "--seed" v >>= \n -> go o {optionSeed = n} rest
    go o ("--n" : v : rest) = number "--n" v >>= \n -> go o {optionCount = n} rest
    go o ("--oracle" : v : rest) = go o {optionOracle = Just v} rest
    go o ("--counterexamples" : v : rest) = go o {optionCounterexamples = Just v} rest
    go o ("--cases" : v : rest) = go o {optionCases = v} rest
    go o ("--root" : v : rest) = go o {optionRoot = Just v} rest
    go _ (other : _) = Left ("unknown or incomplete option " <> other)
    number flag v = maybe (Left (flag <> " needs an integer, not " <> v)) Right (readMaybe v)

usage :: String
usage =
  unlines
    [ "usage: manager-conformance-check admission [--seed S] [--n N] [--oracle PATH] [--counterexamples DIR]",
      "       manager-conformance-check cases [--cases DIR] [--oracle PATH] [--counterexamples DIR]",
      "       manager-conformance-check history --root PATH [--oracle PATH] [--counterexamples DIR]",
      "       manager-conformance-check refusals --root PATH [--oracle PATH] [--counterexamples DIR]"
    ]

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  args <- getArgs
  (lane, rest) <- case args of
    "admission" : rest -> pure (admissionLane, rest)
    "cases" : rest -> pure (casesLane, rest)
    "history" : rest -> pure (historyLane, rest)
    "refusals" : rest -> pure (refusalsLane, rest)
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

-- ---------------------------------------------------------------------------
-- The history lane
-- ---------------------------------------------------------------------------

-- | The counts of one fold.
data Fold = Fold
  { foldState :: !Coordination,
    foldLedgerTransitions :: !Int,
    foldObservations :: !Int,
    foldStoredTransitions :: !Int,
    foldEnvironment :: !Int
  }

historyLane :: Options -> FilePath -> FilePath -> IO ()
historyLane options path directory = do
  given <- case optionRoot options of
    Just root -> pure root
    Nothing -> hPutStrLn stderr ("manager-conformance-check: history needs --root\n" <> usage) >> exitWith (ExitFailure 2)
  roots <- retainedRoots given
  when (null roots) $ do
    hPutStrLn stderr ("manager-conformance-check: no coordination database at or below " <> given)
    exitWith (ExitFailure 1)
  putStrLn ("manager-conformance-check history: root=" <> given <> " manager-roots=" <> show (length roots) <> " oracle=" <> path)
  putStrLn ("MANAGER-CONFORMANCE history compared-dimensions=" <> show (length comparedDimensions) <> ": " <> T.unpack (T.intercalate "; " comparedDimensions))
  forM_ excludedFields $ \field -> putStrLn ("MANAGER-CONFORMANCE history excluded field: " <> T.unpack field)
  results <- withOracle path $ \oracle -> forM (zip [0 :: Int ..] roots) (historyRoot oracle directory)
  let total f = sum (map f results)
  putStrLn $
    "MANAGER-CONFORMANCE history manager-roots=" <> show (length roots)
      <> " ledger=" <> show (total (\(l, _, _, _) -> l))
      <> " ledger-accepted=" <> show (total (\(_, a, _, _) -> a))
      <> " accepted-entries=" <> show (total (\(_, _, e, _) -> e))
      <> " mismatches=" <> show (total (\(_, _, _, m) -> m))
  finish "history" (total (\(_, _, _, m) -> m))

-- | Fold the history of one manager root through the oracle and compare the
-- final state with the projection. The result is the ledger size, the
-- accepted ledger commands, the accepted entries and the mismatches.
historyRoot :: Oracle -> FilePath -> (Int, FilePath) -> IO (Int, Int, Int, Int)
historyRoot oracle directory (number, root) = withRetainedRoot root $ \store flow -> do
  stored <- readStored store
  (history, _) <- rootHistory store flow
  let projection = projectStored stored
      name = "history-" <> show number
      ledgerAccepted = historyLedger history - historyRefused history
  folded <- foldHistory oracle root history (const (pure ()))
  let report fold result =
        putStrLn $
          "MANAGER-CONFORMANCE history root=" <> root
            <> " ledger=" <> show (historyLedger history)
            <> " ledger-refused=" <> show (historyRefused history)
            <> " ledger-accepted=" <> show ledgerAccepted
            <> " accepted-ledger-transitions=" <> show (foldLedgerTransitions fold)
            <> " accepted-ledger-observations=" <> show (foldObservations fold)
            <> " accepted-stored-transitions=" <> show (foldStoredTransitions fold)
            <> " environment-steps=" <> show (foldEnvironment fold)
            <> " approvals-from-log=" <> show (historyApprovalsFromLog history)
            <> " approvals-from-rows=" <> show (historyApprovalsFromRows history)
            <> " result=" <> result
      accepted fold = foldLedgerTransitions fold + foldObservations fold + foldStoredTransitions fold
  case folded of
    Left (mismatch, partial) -> do
      retain directory Nothing name mismatch
      report partial "mismatch"
      pure (historyLedger history, ledgerAccepted, accepted partial, 1)
    Right fold -> do
      let expected = comparedView projection
          actual = comparedView (foldState fold)
          differing = squareDifferences expected actual
          commandsAccepted = foldLedgerTransitions fold + foldObservations fold
      if commandsAccepted /= ledgerAccepted
        then do
          retain directory Nothing name $
            Mismatch "the history does not hold every accepted ledger command" (object ["root" .= root])
              (toJSON ledgerAccepted) (toJSON commandsAccepted)
          report fold "mismatch"
          pure (historyLedger history, ledgerAccepted, accepted fold, 1)
        else
          if null differing
            then do
              report fold "pass"
              pure (historyLedger history, ledgerAccepted, accepted fold, 0)
            else do
              retain directory Nothing name $
                Mismatch ("the final oracle state differs from the projection of the final rows in " <> T.intercalate ", " differing)
                  (object ["root" .= root]) (toJSON expected) (toJSON actual)
              report fold "mismatch"
              pure (historyLedger history, ledgerAccepted, accepted fold, 1)

-- ---------------------------------------------------------------------------
-- The refusals lane
-- ---------------------------------------------------------------------------

-- | How a variant was compared.
data Comparison = GuardCompared | OracleOnly !Text
  deriving (Eq, Show)

-- | The outcome of one variant.
data Outcome = Outcome
  { outcomeRoot :: !FilePath,
    outcomeClass :: !VariantClass,
    outcomeLabel :: !Text,
    outcomeComparison :: !Comparison,
    outcomeMismatch :: !Bool
  }

refusalsLane :: Options -> FilePath -> FilePath -> IO ()
refusalsLane options path directory = do
  given <- case optionRoot options of
    Just root -> pure root
    Nothing -> hPutStrLn stderr ("manager-conformance-check: refusals needs --root\n" <> usage) >> exitWith (ExitFailure 2)
  roots <- retainedRoots given
  when (null roots) $ do
    hPutStrLn stderr ("manager-conformance-check: no coordination database at or below " <> given)
    exitWith (ExitFailure 1)
  putStrLn ("manager-conformance-check refusals: root=" <> given <> " manager-roots=" <> show (length roots) <> " oracle=" <> path)
  forM_ [minBound .. maxBound] $ \c ->
    putStrLn $
      "MANAGER-CONFORMANCE refusals class " <> T.unpack (className c) <> ": "
        <> either (("compared with the oracle only, because " <>) . T.unpack) (("guard " <>) . T.unpack) (classGuard c)
  before <- mapM rootDigest roots
  results <- withOracle path (\oracle -> forM (zip [0 :: Int ..] roots) (refusalsRoot oracle directory))
  let outcomes = concatMap fst results
      unfolded = length [() | (_, False) <- results]
  after <- mapM rootDigest roots
  changed <- fmap concat . forM (zip3 [0 :: Int ..] roots (zip before after)) $ \(number, root, (b, a)) ->
    if b == a
      then pure []
      else do
        retain directory Nothing ("refusals-" <> show number <> "-unchanged") $
          Mismatch "the retained root changed during the lane" (object ["root" .= root]) (toJSON (map snd b)) (toJSON (map snd a))
        pure [root]
  let ofClass c = [o | o <- outcomes, outcomeClass o == c]
      compared os = length [() | o <- os, outcomeComparison o == GuardCompared]
      absent = [c | c <- [minBound .. maxBound], null (ofClass c)]
      unguarded = [c | c <- [minBound .. maxBound], either (const False) (const True) (classGuard c), not (null (ofClass c)), compared (ofClass c) == 0]
      mismatches = length (filter outcomeMismatch outcomes) + length changed + unfolded
  forM_ [minBound .. maxBound] $ \c ->
    putStrLn $
      "MANAGER-CONFORMANCE refusals class=" <> T.unpack (className c)
        <> " variants=" <> show (length (ofClass c))
        <> " guard-compared=" <> show (compared (ofClass c))
        <> " oracle-only=" <> show (length (ofClass c) - compared (ofClass c))
  forM_ [(o, reason) | o <- outcomes, OracleOnly reason <- [outcomeComparison o]] $ \(o, reason) ->
    putStrLn $
      "MANAGER-CONFORMANCE refusals oracle-only variant: " <> T.unpack (className (outcomeClass o)) <> " " <> T.unpack (outcomeLabel o)
        <> " root=" <> outcomeRoot o <> " (" <> T.unpack reason <> ")"
  putStrLn $
    "MANAGER-CONFORMANCE refusals manager-roots=" <> show (length roots)
      <> " variants=" <> show (length outcomes)
      <> " guard-compared=" <> show (compared outcomes)
      <> " oracle-only=" <> show (length outcomes - compared outcomes)
      <> " unchanged-roots=" <> show (length roots - length changed)
      <> " mismatches=" <> show mismatches
  unless (null absent) $ do
    putStrLn ("MANAGER-CONFORMANCE refusals FAIL: the roots derive no variant of " <> T.unpack (T.intercalate ", " (map className absent)))
    exitWith (ExitFailure 1)
  unless (null unguarded) $ do
    putStrLn ("MANAGER-CONFORMANCE refusals FAIL: no variant of " <> T.unpack (T.intercalate ", " (map className unguarded)) <> " is compared with its guard")
    exitWith (ExitFailure 1)
  finish "refusals" mismatches

-- | The SHA-256 of each regular file at or below a retained root, in path
-- order.
rootDigest :: FilePath -> IO [(FilePath, Text)]
rootDigest root = do
  names <- sort <$> listDirectory root
  concat <$> forM names (\name -> do
    let entry = root </> name
    directory <- doesDirectoryExist entry
    if directory
      then rootDigest entry
      else do
        bytes <- BS.readFile entry
        pure [(entry, T.pack (show (hash bytes :: Digest SHA256)))])

-- | Fold the history of one manager root, derive the refused variants of
-- its accepted entries, and check each variant with the oracle and with its
-- guard. The flag is false when the oracle does not accept the history.
refusalsRoot :: Oracle -> FilePath -> (Int, FilePath) -> IO ([Outcome], Bool)
refusalsRoot oracle directory (number, root) = withRetainedRoot root $ \store flow -> do
  (history, selectors) <- rootHistory store flow
  collected <- newIORef []
  folded <- foldHistory oracle root history (\visit -> modifyIORef' collected (reverse (deriveVariants visit) <>))
  case folded of
    Left (mismatch, _) -> do
      retain directory Nothing ("refusals-" <> show number <> "-history") mismatch
      putStrLn ("MANAGER-CONFORMANCE refusals root=" <> root <> " result=mismatch: the history is not accepted")
      pure ([], False)
    Right _ -> do
      variants <- reverse <$> readIORef collected
      outcomes <- forM (zip [0 :: Int ..] variants) $ \(index, variant) ->
        checkVariant oracle store selectors (historyEvidence history) directory ("refusals-" <> show number <> "-" <> show index) root variant
      let compared = length [() | o <- outcomes, outcomeComparison o == GuardCompared]
      putStrLn $
        "MANAGER-CONFORMANCE refusals root=" <> root
          <> " variants=" <> show (length outcomes)
          <> " guard-compared=" <> show compared
          <> " oracle-only=" <> show (length outcomes - compared)
          <> " result=" <> (if any outcomeMismatch outcomes then "mismatch" else "pass")
      pure (outcomes, True)

-- | The oracle must accept the control entry and each prefix entry, and must
-- refuse the variant entry. Each probe of the guard must meet its
-- expectation.
checkVariant :: Oracle -> CoordinationStore -> Map.Map Text ApprovalRequest -> Evidence -> FilePath -> String -> FilePath -> Variant -> IO Outcome
checkVariant oracle store selectors evidence directory name root Variant {..} = do
  control <- forM variantControl $ \(state, entry) -> snd <$> submit oracle (Query state evidence entry)
  let prefix state [] = pure (Right state)
      prefix state (entry : rest) = do
        (_, response) <- submit oracle (Query state evidence entry)
        case response of
          ResponseAccepted next -> prefix next rest
          other -> pure (Left (entry, other))
  reached <- prefix variantState variantPrefix
  final <- case reached of
    Right state -> Just . (,) (Query state evidence variantEntry) . snd <$> submit oracle (Query state evidence variantEntry)
    Left _ -> pure Nothing
  probes <- mapM (runProbe store selectors) variantProbes
  let oracleProblems =
        [ "the oracle does not accept the control entry of the variant" | Just response <- [control], not (accepted response) ]
          <> [ "the oracle does not accept the prefix entry " <> T.pack (show entry) | Left (entry, _) <- [reached] ]
          <> case final of
            Just (_, ResponseAccepted _) -> ["the oracle accepts the refused variant"]
            Just (_, ResponseError message) -> ["the oracle refuses a well-formed request: " <> message]
            _ -> []
      guardProblems = [problem | Just (Left problem) <- probes]
      comparison = case classGuard variantClass of
        Left reason -> OracleOnly reason
        Right _
          | null variantProbes -> OracleOnly "the variant has no probe"
          | any (== Nothing) (map (fmap (const ())) probes) -> OracleOnly "the root holds no submitted selectors of the command"
          | otherwise -> GuardCompared
      problems = oracleProblems <> map ("the guard disagrees: " <>) guardProblems
  case problems of
    [] -> pure ()
    first : _ ->
      retain directory Nothing name $
        Mismatch
          (className variantClass <> " " <> variantLabel <> ": " <> first)
          (object ["root" .= root, "class" .= className variantClass, "label" .= variantLabel, "query" .= fmap fst final, "problems" .= problems])
          (String "the oracle and the guard refuse the variant")
          (maybe Null (toJSON . snd) final)
  pure (Outcome root variantClass variantLabel comparison (not (null problems)))
  where
    accepted = \case
      ResponseAccepted _ -> True
      _ -> False

-- | Fold a history through the oracle from its initial state. Each
-- environment step changes the state before the next entry. The visitor sees
-- each accepted entry with the state before it, the state after it and the
-- items that follow it. The result is the final fold, or the first entry
-- that the oracle does not accept, or stored facts without an encoding, with
-- the fold before it.
foldHistory :: Oracle -> FilePath -> History -> (Visit -> IO ()) -> IO (Either (Mismatch, Fold) Fold)
foldHistory oracle root history visit = step (Fold (historyInitial history) 0 0 0 0) (zip [0 :: Int ..] (historyItems history))
  where
    evidence = historyEvidence history
    step fold [] = pure (Right fold)
    step fold ((index, item) : rest) = case item of
      Environment _ change ->
        step fold {foldState = change (foldState fold), foldEnvironment = foldEnvironment fold + 1} rest
      Unencodable reason ->
        pure (Left (Mismatch ("the stored facts have no encoding: " <> reason) (object ["root" .= root, "item" .= index]) (String "an encodable history") (String reason), fold))
      Submit kind entry -> do
        let request = Query (foldState fold) evidence entry
        (_, response) <- submit oracle request
        case response of
          ResponseAccepted next -> do
            visit (Visit index (foldState fold) entry next (map snd rest))
            step (count kind fold) {foldState = next} rest
          other ->
            pure (Left (Mismatch ("the oracle does not accept " <> describe kind) (object ["root" .= root, "item" .= index, "query" .= request]) (String "accepted") (toJSON other), fold))
    count kind fold = case kind of
      LedgerTransition _ -> fold {foldLedgerTransitions = foldLedgerTransitions fold + 1}
      LedgerObservation _ -> fold {foldObservations = foldObservations fold + 1}
      StoredTransition _ -> fold {foldStoredTransitions = foldStoredTransitions fold + 1}
    describe = \case
      LedgerTransition operation -> "the ledger command " <> operation
      LedgerObservation operation -> "the observation of the ledger command " <> operation
      StoredTransition transition -> "the stored transition " <> transition

-- | The final rows and the manager log of a retained root through its
-- private copy: the history, and the approval selectors of the manager log.
rootHistory :: CoordinationStore -> Maybe FilePath -> IO (History, Map.Map Text ApprovalRequest)
rootHistory store flow = do
  stored <- readStored store
  report <- case flow of
    Nothing -> pure Nothing
    Just dir -> do
      let file = dir </> (T.unpack (storedStream stored) <> ".ndjson")
      present <- doesFileExist file
      if present then Just <$> readManagerLog file else pure Nothing
  pure (encodeHistory (maybe Map.empty approvalArguments report) stored, maybe Map.empty approvalSelectorsOf report)

-- | The compared dimensions in which two states differ.
squareDifferences :: Coordination -> Coordination -> [Text]
squareDifferences a b =
  [ name
    | (name, same) <-
        [ ("reservations", coordinationReservations a == coordinationReservations b),
          ("preparations", coordinationPreparations a == coordinationPreparations b),
          ("requests.run", coordinationRequests a == coordinationRequests b),
          ("decisions", coordinationDecisions a == coordinationDecisions b),
          ("commands", coordinationCommands a == coordinationCommands b),
          ("artifacts", coordinationArtifacts a == coordinationArtifacts b)
        ],
      not same
  ]
