{-# LANGUAGE OverloadedStrings #-}

-- | Checks of the pure wire adapter: the request bodies, the limits, the
-- status table, and every response fixture.
module WireTests
  ( wireTests,
    choiceDecision,
    scaleDecision,
    yesNoDecision,
    fixture,
  )
where

import Agentic.Decisions.Wire
import Agentic.Engine.Decision
import Data.Aeson (Value (..))
import qualified Data.Aeson as Aeson
import Data.Aeson.Encoding (encodingToLazyByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Lazy.Char8 as BLC
import Data.List.NonEmpty (NonEmpty ((:|)))
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T

-- | A choice over three teams, the last named only.
choiceDecision :: EngineDecision
choiceDecision =
  EngineDecision
    EngineChoice
    "Which team should handle this ticket?"
    (EngineOption "Billing" (Just "Payments, charges, and refunds") :| [EngineOption "Technical" (Just "Bugs and outages"), EngineOption "Other" Nothing])
    "I was charged twice for the same order."

-- | A scale of three levels, the middle one described.
scaleDecision :: EngineDecision
scaleDecision =
  EngineDecision
    EngineScale
    "How urgent is this ticket?"
    (EngineOption "Routine" Nothing :| [EngineOption "Soon" (Just "Within a day"), EngineOption "Urgent" Nothing])
    "The site is down for every customer."

-- | A yes/no question with a meaning for True only.
yesNoDecision :: EngineDecision
yesNoDecision =
  EngineDecision
    EngineYesNo
    "Does the customer ask for a refund?"
    (EngineOption "False" Nothing :| [EngineOption "True" (Just "The message asks for money back")])
    "Please refund the extra payment."

fixture :: FilePath -> IO BS.ByteString
fixture name = BS.readFile ("engine/decisions/test/fixtures/" <> name)

wireTests :: IO [String]
wireTests = do
  decoded <- traverse fixtureCheck fixtureTable
  pure
    ( concat
        [ dialectChecks,
          requestChecks,
          limitChecks,
          statusChecks,
          bodyChecks,
          noteChecks,
          concat decoded
        ]
    )

dialectChecks :: [String]
dialectChecks =
  [ "dialect word does not round-trip: " <> show dialect
    | dialect <- [minBound .. maxBound],
      dialectOfWord (dialectWord dialect) /= Just dialect
  ]
    <> ["an unknown dialect word was accepted" | dialectOfWord "openrouter" /= Nothing]

-- | Each request body against the request shapes that sections 3.2, 4.2 and
-- 5.2 of @doc/research/decision-models.md@ record, and the order of the
-- options in the bytes.
requestChecks :: [String]
requestChecks =
  concat
    [ same "System One choice" (body SystemOne Map.empty choiceDecision) systemOneChoice,
      same "System One yes/no" (body SystemOne Map.empty yesNoDecision) systemOneYesNo,
      same "System One yes/no without meanings" (body SystemOne Map.empty bareYesNo) systemOneBareYesNo,
      same "System One scale" (body SystemOne Map.empty scaleDecision) systemOneScale,
      same "OpenAI choice" (body OpenAIDecisions Map.empty choiceDecision) openAIChoice,
      same "OpenAI yes/no" (body OpenAIDecisions Map.empty yesNoDecision) openAIPredicate,
      same "OpenAI scale" (body OpenAIDecisions Map.empty scaleDecision) openAIScore,
      same "System One with options" (body SystemOne realization choiceDecision) systemOneWithOptions,
      [ "System One criteria are not in option order: " <> BLC.unpack bytes
        | let bytes = bytesOf SystemOne Map.empty choiceDecision,
          not (inOrder ["\"Billing\"", "\"Technical\"", "\"Other\""] bytes)
      ],
      [ "OpenAI choices are not in option order: " <> BLC.unpack bytes
        | let bytes = bytesOf OpenAIDecisions Map.empty choiceDecision,
          not (inOrder ["\"Billing\"", "\"Technical\"", "\"Other\""] bytes)
      ],
      [ "reserved keys differ between dialects in an unexpected way"
        | reservedBodyKeys SystemOne /= ["model", "state", "questions"] || reservedBodyKeys OpenAIDecisions /= ["model", "input", "questions"]
      ]
    ]
  where
    realization = Map.fromList [("provider", Aeson.object ["order" Aeson..= ["TypeSafe" :: Text]]), ("model", String "overridden"), ("state", String "overridden")]
    bareYesNo = yesNoDecision {engineDecisionOptions = EngineOption "False" Nothing :| [EngineOption "True" (Just "")]}
    bytesOf dialect options decision = encodingToLazyByteString (encodeRequest dialect "m" options decision)
    body dialect options decision = Aeson.decode (bytesOf dialect options decision) :: Maybe Value
    same what actual expected =
      [ what <> " body is " <> show actual <> ", expected " <> show expected'
        | let expected' = Aeson.decode expected :: Maybe Value,
          actual /= expected' || actual == Nothing
      ]
    inOrder needles haystack = go needles (BL.toStrict haystack)
      where
        go [] _ = True
        go (needle : rest) remaining = case BS.breakSubstring needle remaining of
          (_, found) | BS.null found -> False
          (_, found) -> go rest (BS.drop (BS.length needle) found)
    systemOneChoice = "{\"model\":\"m\",\"state\":\"I was charged twice for the same order.\",\"questions\":{\"decision\":{\"type\":\"choice\",\"instructions\":\"Which team should handle this ticket?\",\"criteria\":{\"Billing\":\"Payments, charges, and refunds\",\"Technical\":\"Bugs and outages\",\"Other\":null}}}}"
    systemOneYesNo = "{\"model\":\"m\",\"state\":\"Please refund the extra payment.\",\"questions\":{\"decision\":{\"type\":\"noul\",\"instructions\":\"Does the customer ask for a refund?\",\"criteria\":{\"true\":\"The message asks for money back\"}}}}"
    systemOneBareYesNo = "{\"model\":\"m\",\"state\":\"Please refund the extra payment.\",\"questions\":{\"decision\":{\"type\":\"noul\",\"instructions\":\"Does the customer ask for a refund?\"}}}"
    systemOneScale = "{\"model\":\"m\",\"state\":\"The site is down for every customer.\",\"questions\":{\"decision\":{\"type\":\"score\",\"instructions\":\"How urgent is this ticket?\",\"criteria\":[\"Routine\",\"Soon: Within a day\",\"Urgent\"]}}}"
    openAIChoice = "{\"model\":\"m\",\"input\":\"I was charged twice for the same order.\",\"questions\":[{\"type\":\"choice\",\"name\":\"decision\",\"instructions\":\"Which team should handle this ticket?\",\"choices\":[{\"value\":\"Billing\",\"description\":\"Payments, charges, and refunds\"},{\"value\":\"Technical\",\"description\":\"Bugs and outages\"},{\"value\":\"Other\"}]}]}"
    openAIPredicate = "{\"model\":\"m\",\"input\":\"Please refund the extra payment.\",\"questions\":[{\"type\":\"predicate\",\"name\":\"decision\",\"instructions\":\"Does the customer ask for a refund?\\nIt counts as true when: The message asks for money back\"}]}"
    openAIScore = "{\"model\":\"m\",\"input\":\"The site is down for every customer.\",\"questions\":[{\"type\":\"score\",\"name\":\"decision\",\"instructions\":\"How urgent is this ticket?\",\"levels\":[{\"label\":\"Routine\"},{\"label\":\"Soon\",\"description\":\"Within a day\"},{\"label\":\"Urgent\"}]}]}"
    systemOneWithOptions = "{\"model\":\"m\",\"state\":\"I was charged twice for the same order.\",\"provider\":{\"order\":[\"TypeSafe\"]},\"questions\":{\"decision\":{\"type\":\"choice\",\"instructions\":\"Which team should handle this ticket?\",\"criteria\":{\"Billing\":\"Payments, charges, and refunds\",\"Technical\":\"Bugs and outages\",\"Other\":null}}}}"

limitChecks :: [String]
limitChecks =
  concat
    [ accepted "a three-option choice" defaultLimits choiceDecision,
      accepted "a three-level scale" defaultLimits scaleDecision,
      accepted "a yes/no question" defaultLimits yesNoDecision,
      refused "a choice over the option limit" (Limits 2 10) choiceDecision,
      refused "a scale over the level limit" (Limits 255 2) scaleDecision,
      refused "a one-option choice" defaultLimits (withOptions [EngineOption "Billing" Nothing] choiceDecision),
      refused "a choice of 256 options" defaultLimits (withOptions [EngineOption (T.pack ("O" <> show i)) Nothing | i <- [1 .. 256 :: Int]] choiceDecision),
      accepted "a choice of 255 options" defaultLimits (withOptions [EngineOption (T.pack ("O" <> show i)) Nothing | i <- [1 .. 255 :: Int]] choiceDecision),
      refused "a scale of 11 levels" defaultLimits (withOptions [EngineOption (T.pack ("L" <> show i)) Nothing | i <- [1 .. 11 :: Int]] scaleDecision),
      refused "a yes/no question with other names" defaultLimits (withOptions [EngineOption "No" Nothing, EngineOption "Yes" Nothing] yesNoDecision),
      refused "a choice naming one option twice" defaultLimits (withOptions [EngineOption "Billing" Nothing, EngineOption "Billing" Nothing] choiceDecision),
      refused "a choice with an empty name" defaultLimits (withOptions [EngineOption "" Nothing, EngineOption "Billing" Nothing] choiceDecision),
      refused "blank instructions" defaultLimits (choiceDecision {engineDecisionInstructions = "  "})
    ]
  where
    accepted what limits decision = ["checkLimits refused " <> what | Left _ <- [checkLimits limits decision]]
    refused what limits decision = ["checkLimits accepted " <> what | Right () <- [checkLimits limits decision]]

withOptions :: [EngineOption] -> EngineDecision -> EngineDecision
withOptions (first : rest) decision = decision {engineDecisionOptions = first :| rest}
withOptions [] decision = decision

statusChecks :: [String]
statusChecks =
  concat
    [ [ "status " <> show status <> " was not a success" | status <- [200, 201, 299], classifyStatus status Nothing /= Nothing],
      [ "status " <> show status <> " was not a transport failure"
        | status <- [408, 425, 429, 500, 502, 503, 504, 524, 529],
          not (isTransport (classifyStatus status Nothing))
      ],
      [ "status " <> show status <> " was not a protocol failure"
        | status <- [301, 302, 400, 401, 402, 403, 404, 413, 422, 501, 505],
          not (isProtocol (classifyStatus status Nothing))
      ],
      ["an in-flight 402 was not a transport failure" | not (isTransport (classifyStatus 402 (Just inFlight)))],
      ["a credits 402 was not a protocol failure" | not (isProtocol (classifyStatus 402 (Just credits)))],
      [ "a failure did not carry the vendor message: " <> show failure
        | let failure = classifyStatus 402 (Just credits),
          failure /= Just (WireProtocol "the endpoint answered HTTP 402: Insufficient credits")
      ]
    ]
  where
    errorBody source message = Aeson.object ["error" Aeson..= Aeson.object ["code" Aeson..= (402 :: Int), "message" Aeson..= (message :: Text), "metadata" Aeson..= Aeson.object ["limit_source" Aeson..= (source :: Text)]]]
    inFlight = errorBody "openrouter_in_flight_budget" "Too many requests are in flight"
    credits = errorBody "openrouter_credits" "Insufficient credits"

isTransport, isProtocol :: Maybe WireFailure -> Bool
isTransport (Just (WireTransport _)) = True
isTransport _ = False
isProtocol (Just (WireProtocol _)) = True
isProtocol _ = False

bodyChecks :: [String]
bodyChecks =
  concat
    [ ["a body with a repeated key was accepted" | Right _ <- [decodeBody "{\"answers\":{},\"answers\":{}}"]],
      ["a repeated probability key was accepted" | Right _ <- [decodeBody "{\"a\":{\"Billing\":0.5,\"Billing\":0.5}}"]],
      ["a body that is not JSON was accepted" | Right _ <- [decodeBody "{\"answers\":"]],
      ["a body with trailing text was accepted" | Right _ <- [decodeBody "{} {}"]],
      ["a body that is not UTF-8 was accepted" | Right _ <- [decodeBody "{\"a\":\"\xff\"}"]],
      ["a well-formed body was refused" | Left _ <- [decodeBody "{\"a\":[1,2,{\"b\":null}]}"]]
    ]

-- | A sum outside 1 ± 1/100 and a reported choice that is not the most
-- probable add notes to the narration, and change nothing else.
noteChecks :: [String]
noteChecks = case decodeBody body >>= decodeResponse SystemOne choiceDecision of
  Right answer ->
    [ "the answer of an unnormalized response changed: " <> T.unpack (wireAnswerJson answer)
      | wireAnswerJson answer /= "{\"Billing\":0.5,\"Technical\":0.3,\"Other\":0.0}"
    ]
      <> [ "the narration lacks its notes: " <> T.unpack (wireNarration answer)
           | wireNarration answer
               /= "decisions system-one: model unreported, input tokens unreported, output tokens unreported; note the probabilities sum to 0.8; note the reported choice 'Technical' is not the most probable option"
         ]
  Left failure -> ["an unnormalized response was refused: " <> show failure]
  where
    body = "{\"answers\":{\"decision\":{\"type\":\"choice\",\"choice\":\"Technical\",\"probabilities\":{\"Billing\":0.5,\"Technical\":0.3}}}}"

-- | What a fixture must decode to.
data Expect
  = Accepts !Text ![Text]
  | Refuses !Text

fixtureTable :: [(FilePath, Dialect, EngineDecision, Expect)]
fixtureTable =
  [ ( "jev-choice.json",
      SystemOne,
      choiceDecision,
      Accepts "{\"Billing\":0.88,\"Technical\":0.11,\"Other\":0.01}" ["decisions system-one: model typesafe/jev-1.14-20261014, input tokens 87, output tokens 0, cost 0.0000036, id gen-dec-1763400000-Jev1choice"]
    ),
    ( "jev-score.json",
      SystemOne,
      scaleDecision,
      Accepts "{\"Routine\":0.0,\"Soon\":0.79,\"Urgent\":0.21}" ["model typesafe/jev-1.14-20261014"]
    ),
    ( "jev-noul.json",
      SystemOne,
      yesNoDecision,
      Accepts "{\"False\":0.02,\"True\":0.98}" ["input tokens 64"]
    ),
    ( "drex-v1.5-score-array-legend.json",
      SystemOne,
      scaleDecision,
      Accepts "{\"Routine\":0.2489,\"Soon\":0.166,\"Urgent\":0.5851}" ["decisions system-one: model unreported, input tokens 87, output tokens 166"]
    ),
    ( "drex-max-score-object-legend.json",
      SystemOne,
      scaleDecision,
      Accepts "{\"Routine\":0.1,\"Soon\":0.3,\"Urgent\":0.6}" ["model drex-max-v1"]
    ),
    ( "kev-score-object-legend.json",
      SystemOne,
      scaleDecision,
      Accepts "{\"Routine\":0.0,\"Soon\":0.56,\"Urgent\":0.44}" ["model kev-latest, input tokens 101, output tokens 161"]
    ),
    ( "openai-choice.json",
      OpenAIDecisions,
      choiceDecision,
      Accepts "{\"Billing\":0.9,\"Technical\":0.06,\"Other\":0.04}" ["decisions openai: model gpt-6-luna, input tokens 42, output tokens 0"]
    ),
    ( "openai-score.json",
      OpenAIDecisions,
      scaleDecision,
      Accepts "{\"Routine\":0.1,\"Soon\":0.7,\"Urgent\":0.2}" ["model gpt-6-luna"]
    ),
    ( "openai-predicate.json",
      OpenAIDecisions,
      yesNoDecision,
      Accepts "{\"False\":0.75,\"True\":0.25}" ["model gpt-6-luna"]
    ),
    ("openrouter-refusal.json", SystemOne, choiceDecision, Refuses "the model refused the question"),
    ("missing-probabilities.json", SystemOne, choiceDecision, Refuses "the choice answer lacks the field 'probabilities'"),
    ("unknown-key.json", SystemOne, choiceDecision, Refuses "the answer names the option 'Shipping', which was not asked"),
    ("negative-value.json", SystemOne, choiceDecision, Refuses "the probability of 'Other' lies outside [0,1]"),
    ("huge-exponent.json", SystemOne, choiceDecision, Refuses "a probability has an exponent outside ±4096"),
    ("jev-choice.json", SystemOne, scaleDecision, Refuses "the answer has type 'choice', and this question expects 'score'"),
    ("jev-noul.json", OpenAIDecisions, yesNoDecision, Refuses "the field 'answers' is not an array"),
    ("openai-predicate.json", SystemOne, yesNoDecision, Refuses "the field 'answers' is not an object")
  ]

fixtureCheck :: (FilePath, Dialect, EngineDecision, Expect) -> IO [String]
fixtureCheck (name, dialect, decision, expect) = do
  bytes <- fixture name
  let outcome = decodeBody bytes >>= decodeResponse dialect decision
      label = name <> " as " <> T.unpack (dialectWord dialect)
  pure $ case (expect, outcome) of
    (Accepts json notes, Right answer) ->
      [label <> " answered " <> T.unpack (wireAnswerJson answer) <> ", expected " <> T.unpack json | wireAnswerJson answer /= json]
        <> [label <> " narration '" <> T.unpack (wireNarration answer) <> "' lacks '" <> T.unpack note <> "'" | note <- notes, not (note `T.isInfixOf` wireNarration answer)]
    (Accepts _ _, Left failure) -> [label <> " was refused: " <> show failure]
    (Refuses reason, Left (WireProtocol actual)) -> [label <> " was refused as '" <> T.unpack actual <> "', expected '" <> T.unpack reason <> "'" | actual /= reason]
    (Refuses _, Left failure) -> [label <> " was not a protocol failure: " <> show failure]
    (Refuses _, Right answer) -> [label <> " was accepted: " <> show answer]
