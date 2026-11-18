{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Agentic.Decisions.Wire
-- Description : The vendor wire of the decisions engine, as pure functions.
--
-- This module is the adapter between the neutral 'EngineDecision' and the
-- bodies that decision endpoints accept and return. Every vendor field name
-- of the decisions engine is written here and nowhere else. "Agentic.Decisions"
-- moves bytes and names no vendor field.
--
-- A decision asks which option of a finite set O is right, and its answer is
-- a point of the simplex Δ(O). An endpoint returns that point in a vendor
-- shape. 'decodeResponse' reads the shape back into the number record that
-- the answer contract of "Agentic.Engine.Decision" names: a JSON object whose
-- keys are exactly the option names, in option order, each a finite decimal
-- in [0,1], with a positive sum. The record is a representative of a point of
-- the cone C(O), so its reading v/Σv is the vendor's distribution. No answer
-- is ever invented: a missing, refused or malformed answer is a
-- 'WireProtocol' failure.
--
-- Each detail that no primary source confirms carries a comment that begins
-- with @UNCONFIRMED(Uk)@ beside the code that it governs, where @Uk@ names the
-- item of section 11 of @doc/research/decision-models.md@, which lists the
-- unconfirmed details U1 to U17.
module Agentic.Decisions.Wire
  ( -- * Dialects
    Dialect (..),
    dialectWord,
    dialectOfWord,

    -- * Limits
    Limits (..),
    defaultLimits,
    checkLimits,

    -- * Requests
    questionKey,
    reservedBodyKeys,
    encodeRequest,

    -- * Responses
    WireFailure (..),
    WireAnswer (..),
    decodeBody,
    decodeResponse,
    classifyStatus,
  )
where

import Agentic.Engine.Decision
  ( EngineDecision (..),
    EngineDecisionForm (..),
    EngineOption (..),
  )
import Control.Monad (unless, when)
import Data.Aeson (Encoding, Key, Value (..), (.=))
import qualified Data.Aeson.Encoding as E
import qualified Data.Aeson as Aeson
import Data.Aeson.Decoding.Text (textToTokens)
import qualified Data.Aeson.Decoding.Tokens as Tokens
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.Char (isControl)
import Data.Foldable (toList)
import Data.List (nub)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Scientific (FPFormat (Fixed), Scientific, base10Exponent, floatingOrInteger, formatScientific)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Vector as V

-- ---------------------------------------------------------------------------
-- Dialects
-- ---------------------------------------------------------------------------

-- | A wire dialect. Denotes a pair of maps: an encoding of a neutral decision
-- as a request body, and a partial decoding of a response body as a point of
-- Δ(O). 'SystemOne' is the body of OpenRouter's Decisions API, of TypeSafe's
-- System One API and of the local runners that copy it. 'OpenAIDecisions' is
-- the body of OpenAI's Decisions API.
--
-- The URL, the authentication header and every other header are configured
-- per endpoint, so this module names no path and no header.
--
-- UNCONFIRMED(U1): OpenRouter serves @/api/v1/systemone@ for Jev, and no source
-- confirms it for other models. The engine has no default URL, because the
-- routing definition always configures the URL. The OpenRouter example in
-- @doc/model-routing-v2.md@ uses the documented alpha path
-- @/api/alpha/decisions@, which may change.
--
-- UNCONFIRMED(U9): no primary source gives the URL or the authentication of the
-- hosted Nace (Drex) API. Only local runners at @/v1/systemone@ are covered.
--
-- UNCONFIRMED(U16): Kev on loopback requires @Authorization: Bearer@ when
-- @KEV_API_KEY@ is set. Whether an authenticated plain-HTTP loopback URL is
-- accepted is a routing decision outside this module.
data Dialect = SystemOne | OpenAIDecisions
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | The configuration word of a dialect. @dialectOfWord (dialectWord d) = Just d@.
dialectWord :: Dialect -> Text
dialectWord SystemOne = "system-one"
dialectWord OpenAIDecisions = "openai"

-- | The inverse of 'dialectWord' on its image, and 'Nothing' elsewhere.
dialectOfWord :: Text -> Maybe Dialect
dialectOfWord word = lookup word [(dialectWord dialect, dialect) | dialect <- [minBound .. maxBound]]

-- ---------------------------------------------------------------------------
-- Limits
-- ---------------------------------------------------------------------------

-- | The option sets that one endpoint accepts. Denotes the set of decisions
-- whose choice has at most 'limitOptions' options and whose scale has at most
-- 'limitLevels' levels. A yes/no decision always has two options.
data Limits = Limits
  { limitOptions :: !Int,
    limitLevels :: !Int
  }
  deriving (Eq, Show)

-- | 255 options and 10 levels, the limits that OpenRouter, TypeSafe and
-- OpenAI state for a choice and a scale.
--
-- UNCONFIRMED(U14): Respan states 679 or 255 options, and Tev1 accepts 24. An
-- endpoint that differs configures its own 'Limits'.
defaultLimits :: Limits
defaultLimits = Limits {limitOptions = 255, limitLevels = 10}

-- | @checkLimits l d = Right ()@ exactly when @d@ is a decision that an
-- endpoint with limits @l@ accepts: its instructions are not blank, its option
-- names are non-empty and distinct, a yes/no decision has exactly the options
-- @False@ and @True@, a choice has from 2 to @limitOptions l@ options, and a
-- scale has from 2 to @limitLevels l@ levels.
checkLimits :: Limits -> EngineDecision -> Either Text ()
checkLimits limits decision = do
  when (T.null (T.strip (engineDecisionInstructions decision))) $
    Left "a decision needs instructions, and these are blank"
  when ("" `elem` names) $
    Left "a decision option needs a name, and one is empty"
  unless (nub names == names) $
    Left "a decision names one option twice"
  case engineDecisionForm decision of
    EngineYesNo ->
      unless (names == ["False", "True"]) $
        Left "a yes/no decision has exactly the options False and True"
    EngineChoice -> within "a choice" "options" (limitOptions limits)
    EngineScale -> within "a scale" "levels" (limitLevels limits)
  where
    names = map engineOptionName (toList (engineDecisionOptions decision))
    count = length names
    within what unit bound
      | count < 2 = Left (what <> " needs at least 2 " <> unit <> ", and this one has " <> showText count)
      | count > bound =
          Left (what <> " of " <> showText count <> " " <> unit <> " exceeds this endpoint's limit of " <> showText bound)
      | otherwise = Right ()

-- ---------------------------------------------------------------------------
-- Requests
-- ---------------------------------------------------------------------------

-- | The name under which the one question of a request is asked and answered.
--
-- UNCONFIRMED(U15): no source states that every provider answers the questions
-- of one request independently. Each request carries exactly one question, so
-- nothing here depends on it.
questionKey :: Text
questionKey = "decision"

-- | The top-level body keys that the engine writes itself. A realization
-- option with one of these names is refused.
reservedBodyKeys :: Dialect -> [Text]
reservedBodyKeys SystemOne = ["model", "state", "questions"]
reservedBodyKeys OpenAIDecisions = ["model", "input", "questions"]

-- | The request body that asks @decision@ of the model @model@ through
-- @dialect@, with the realization options merged at the top level.
--
-- The body is an 'Encoding' rather than a 'Value', because a 'Value' object
-- does not keep the order of its keys, and the options of a choice are sent
-- in option order. The decoded body is an object in which each key of
-- @reservedBodyKeys dialect@ holds the engine's own value, and in which every
-- other key is a realization option. An option whose name is reserved is
-- left out here and refused by the engine before anything is sent. The
-- evidence is sent as one string.
encodeRequest :: Dialect -> Text -> Map Text Value -> EngineDecision -> Encoding
encodeRequest dialect model options decision =
  E.pairs
    ( body dialect
        <> mconcat [Key.fromText name .= value | (name, value) <- Map.toList options, name `notElem` reservedBodyKeys dialect]
    )
  where
    entries = toList (engineDecisionOptions decision)
    instructions = engineDecisionInstructions decision
    evidence = engineDecisionEvidence decision
    form = engineDecisionForm decision
    -- UNCONFIRMED(U8): Microsoft Foundry reads the deployment name from
    -- @model@ and takes an @api-key@ header or an Entra bearer token. The
    -- header is configured, and the model identifier is sent as given.
    --
    -- UNCONFIRMED(U7): Perplexity, Inception and Respan at their native
    -- @/v1/decisions@ paths are reachable with this body but not verified.
    -- Perplexity refuses unknown top-level fields, so a realization option
    -- reaches it only if it accepts the field.
    body SystemOne =
      "model" .= model
        <> "state" .= evidence
        <> E.pair "questions" (E.pairs (E.pair (Key.fromText questionKey) systemOneQuestion))
    body OpenAIDecisions =
      "model" .= model
        <> "input" .= evidence
        <> E.pair "questions" (E.list id [openAIQuestion])
    systemOneQuestion = case form of
      EngineChoice ->
        E.pairs
          ( "type" .= ("choice" :: Text)
              <> "instructions" .= instructions
              <> E.pair "criteria" (E.pairs (mconcat [Key.fromText (engineOptionName entry) .= described entry | entry <- entries]))
          )
      -- UNCONFIRMED(U6): OpenRouter is inferred, not documented, to translate
      -- @noul@ into OpenAI's @predicate@ for @openai/gpt-6-luna-decisions@.
      -- This dialect always sends @noul@.
      EngineYesNo ->
        E.pairs
          ( "type" .= ("noul" :: Text)
              <> "instructions" .= instructions
              <> case [(key, text) | (key, Just text) <- truthCriteria] of
                [] -> mempty
                criteria -> E.pair "criteria" (E.pairs (mconcat [key .= text | (key, text) <- criteria]))
          )
      -- UNCONFIRMED(U12): the OpenAPI schema and Ollama forbid a null score
      -- criterion, and TypeSafe's advanced.md allows one. Every level is sent
      -- as a string.
      EngineScale ->
        E.pairs
          ( "type" .= ("score" :: Text)
              <> "instructions" .= instructions
              <> "criteria" .= [maybe name (\text -> name <> ": " <> text) (described entry) | entry <- entries, let name = engineOptionName entry]
          )
    truthCriteria :: [(Key, Maybe Text)]
    truthCriteria =
      [ ("true", described =<< optionNamed "True"),
        ("false", described =<< optionNamed "False")
      ]
    optionNamed name = case [entry | entry <- entries, engineOptionName entry == name] of
      entry : _ -> Just entry
      [] -> Nothing
    openAIQuestion = case form of
      EngineChoice ->
        E.pairs
          ( "type" .= ("choice" :: Text)
              <> "name" .= questionKey
              <> "instructions" .= instructions
              <> E.pair "choices" (E.list (\entry -> E.pairs ("value" .= engineOptionName entry <> descriptionField entry)) entries)
          )
      EngineYesNo ->
        E.pairs
          ( "type" .= ("predicate" :: Text)
              <> "name" .= questionKey
              <> "instructions"
                .= ( instructions
                       <> maybe "" ("\nIt counts as true when: " <>) (described =<< optionNamed "True")
                       <> maybe "" ("\nIt counts as false when: " <>) (described =<< optionNamed "False")
                   )
          )
      EngineScale ->
        E.pairs
          ( "type" .= ("score" :: Text)
              <> "name" .= questionKey
              <> "instructions" .= instructions
              <> E.pair "levels" (E.list (\entry -> E.pairs ("label" .= engineOptionName entry <> descriptionField entry)) entries)
          )
    descriptionField entry = maybe mempty ("description" .=) (described entry)

-- | The description of an option, with an empty one read as none.
described :: EngineOption -> Maybe Text
described entry = case engineOptionDescription entry of
  Just text | not (T.null text) -> Just text
  _ -> Nothing

-- ---------------------------------------------------------------------------
-- Responses
-- ---------------------------------------------------------------------------

-- | Why a request yielded no point of Δ(O). Denotes the two classes of
-- failure: a transport failure, after which the same request may succeed,
-- and a protocol failure, after which it cannot.
data WireFailure = WireTransport !Text | WireProtocol !Text
  deriving (Eq, Show)

-- | An accepted answer. Denotes a point of the cone C(O) with one line of
-- narration. 'wireAnswerJson' is the JSON text of the number record that the
-- answer contract of "Agentic.Engine.Decision" names.
data WireAnswer = WireAnswer
  { wireAnswerJson :: !Text,
    wireNarration :: !Text
  }
  deriving (Eq, Show)

-- | Reads a response body as one JSON value. It refuses bytes that are not
-- UTF-8, text that is not one JSON value, and an object with a repeated key,
-- because a repeated key leaves its value ambiguous.
decodeBody :: BS.ByteString -> Either WireFailure Value
decodeBody bytes = do
  text <- either (const (Left (WireProtocol "the response is not UTF-8"))) Right (TE.decodeUtf8' bytes)
  unless (tokensOk (const True) (textToTokens text)) $
    Left (WireProtocol "the response is not one JSON value with distinct keys")
  either (const (Left (WireProtocol "the response is not one JSON value"))) Right (Aeson.eitherDecodeStrict' bytes)

-- | Reads the answer to @decision@ from a successful response body.
--
-- For every @Right a@, @wireAnswerJson a@ is a JSON object whose keys are the
-- option names of @decision@ in option order, whose values are finite
-- decimals in [0,1], and whose sum is positive. The value at an option is the
-- probability that the vendor gave it, and for a yes/no decision whose vendor
-- probability is @p@ the record is @{"False": 1 - p, "True": p}@ in exact
-- decimal arithmetic.
decodeResponse :: Dialect -> EngineDecision -> Value -> Either WireFailure WireAnswer
decodeResponse dialect decision value = do
  envelope <- asObject "the response" value
  answer <- theAnswer dialect envelope
  (record, notes) <- readAnswer dialect decision answer
  checkRecord record
  pure
    WireAnswer
      { wireAnswerJson = renderRecord record,
        wireNarration = narration dialect envelope record notes
      }

-- | The one answer object of a response.
theAnswer :: Dialect -> KeyMap.KeyMap Value -> Either WireFailure (KeyMap.KeyMap Value)
theAnswer SystemOne envelope = do
  answers <- field "the response" "answers" envelope >>= asObject "the field 'answers'"
  case KeyMap.toList answers of
    [(key, answer)] | Key.toText key == questionKey -> asObject "the answer" answer
    [] -> Left (protocol "the response carries no answer")
    entries -> case filter ((/= questionKey) . Key.toText . fst) entries of
      (other, _) : _ -> Left (protocol ("the response answers the question '" <> Key.toText other <> "', which was not asked"))
      [] -> Left (protocol "the response carries no answer")
theAnswer OpenAIDecisions envelope = do
  answers <- field "the response" "answers" envelope >>= asArray "the field 'answers'"
  case answers of
    [answer] -> do
      fields <- asObject "the answer" answer
      case KeyMap.lookup "name" fields of
        Nothing -> pure fields
        Just Null -> pure fields
        Just (String name) | name == questionKey -> pure fields
        Just _ -> Left (protocol "the response answers a question that was not asked")
    [] -> Left (protocol "the response carries no answer")
    _ -> Left (protocol "the response carries more answers than the one question asked")

-- | The number record of one answer, in option order, with the informational
-- notes about it.
readAnswer :: Dialect -> EngineDecision -> KeyMap.KeyMap Value -> Either WireFailure ([(Text, Scientific)], [Text])
readAnswer dialect decision answer = do
  kind <- field "the answer" "type" answer >>= asText "the answer's type"
  when (kind == "refusal") $
    Left (protocol "the model refused the question")
  case (engineDecisionForm decision, dialect) of
    (EngineChoice, SystemOne) -> do
      expect "choice" kind
      -- UNCONFIRMED(U4): OpenRouter marks @probabilities@ optional, and some
      -- models (Tev1 among them) may omit it. Without it no distribution is
      -- known, so the answer is refused.
      --
      -- UNCONFIRMED(U5): the vendors compute @confidence@ by different
      -- formulas, and it is a statistic of the distribution. It is ignored.
      probabilities <- field "the choice answer" "probabilities" answer >>= asObject "the choice probabilities"
      entries <- traverse (\(key, p) -> (,) (Key.toText key) <$> probability p) (KeyMap.toList probabilities)
      record <- byName entries
      pure (record, argmaxNote (KeyMap.lookup "choice" answer) record)
    (EngineChoice, OpenAIDecisions) -> do
      expect "choice" kind
      -- UNCONFIRMED(U4): as for System One, a choice without @probabilities@
      -- is refused.
      items <- field "the choice answer" "probabilities" answer >>= asArray "the choice probabilities"
      entries <- traverse openAIChoice items
      record <- byName entries
      pure (record, argmaxNote (KeyMap.lookup "choice" answer) record)
    (EngineScale, SystemOne) -> do
      expect "score" kind
      -- UNCONFIRMED(U10): Nace documents @legend@ both as an array and as an
      -- object. It restates the levels that were sent, so it is ignored in
      -- either shape.
      probabilities <- field "the score answer" "probabilities" answer >>= asObject "the score probabilities"
      entries <- traverse (\(key, p) -> (,) <$> levelName (Key.toText key) <*> probability p) (KeyMap.toList probabilities)
      record <- byName entries
      pure (record, [])
    (EngineScale, OpenAIDecisions) -> do
      expect "score" kind
      items <- field "the score answer" "probabilities" answer >>= asArray "the score probabilities"
      entries <- traverse openAIScore items
      record <- byName entries
      pure (record, [])
    (EngineYesNo, SystemOne) -> do
      expect "noul" kind
      p <- field "the yes/no answer" "noul" answer >>= probability >>= unitInterval
      pure ([("False", 1 - p), ("True", p)], [])
    (EngineYesNo, OpenAIDecisions) -> do
      expect "predicate" kind
      p <- field "the yes/no answer" "probability" answer >>= probability >>= unitInterval
      pure ([("False", 1 - p), ("True", p)], [])
  where
    names = map engineOptionName (toList (engineDecisionOptions decision))
    expect wanted kind =
      unless (kind == wanted) $
        Left (protocol ("the answer has type '" <> kind <> "', and this question expects '" <> wanted <> "'"))
    -- UNCONFIRMED(U2): no source says whether a provider omits an option whose
    -- probability is zero. A missing option reads as 0, and an option that was
    -- not asked is refused.
    byName entries = do
      let keys = map fst entries
      unless (nub keys == keys) $
        Left (protocol "the answer gives one option two probabilities")
      case filter (`notElem` names) keys of
        unknown : _ -> Left (protocol ("the answer names the option '" <> unknown <> "', which was not asked"))
        [] -> pure [(name, fromMaybe 0 (lookup name entries)) | name <- names]
    levelName key = case [name | (index, name) <- zip [0 :: Int ..] names, showText index == key] of
      [name] -> Right name
      _ -> Left (protocol ("the answer names the level '" <> key <> "', which was not asked"))
    openAIChoice item = do
      fields <- asObject "a choice probability" item
      name <- field "a choice probability" "value" fields >>= asText "a choice value"
      (,) name <$> (field "a choice probability" "probability" fields >>= probability)
    openAIScore item = do
      fields <- asObject "a score probability" item
      index <- field "a score probability" "value" fields >>= \case
        Number n | boundedExponent n, Right i <- (floatingOrInteger n :: Either Double Integer) -> Right i
        _ -> Left (protocol "a score probability's value is not an integer")
      name <- levelName (showText index)
      (,) name <$> (field "a score probability" "probability" fields >>= probability)

-- | A probability: a JSON number whose exponent is bounded, read without
-- loss. Its range is checked with the whole record.
probability :: Value -> Either WireFailure Scientific
probability = \case
  Number n
    | boundedExponent n -> Right n
    | otherwise -> Left (protocol "a probability has an exponent outside ±4096")
  _ -> Left (protocol "a probability is not a number")

-- | A yes/no probability, which must lie in [0,1] before its complement is
-- taken.
unitInterval :: Scientific -> Either WireFailure Scientific
unitInterval p
  | p < 0 || p > 1 = Left (protocol "the yes/no probability lies outside [0,1]")
  | otherwise = Right p

-- | Every value lies in [0,1], and the sum is positive.
checkRecord :: [(Text, Scientific)] -> Either WireFailure ()
checkRecord record = do
  case [name | (name, p) <- record, p < 0 || p > 1] of
    name : _ -> Left (protocol ("the probability of '" <> name <> "' lies outside [0,1]"))
    [] -> pure ()
  unless (sum (map snd record) > 0) $
    Left (protocol "the probabilities sum to zero")

-- | The JSON text of a number record, keys in the given order, numbers as
-- plain decimals.
renderRecord :: [(Text, Scientific)] -> Text
renderRecord record =
  "{" <> T.intercalate "," [jsonText (String name) <> ":" <> T.pack (formatScientific Fixed Nothing p) | (name, p) <- record] <> "}"
  where
    jsonText = TE.decodeUtf8 . BL.toStrict . Aeson.encode

-- | A note when the reported choice is not among the most probable options.
argmaxNote :: Maybe Value -> [(Text, Scientific)] -> [Text]
argmaxNote reported record = case reported of
  Just (String name)
    | name `notElem` [option | (option, p) <- record, p == top] ->
        ["the reported choice '" <> clean name <> "' is not the most probable option"]
  _ -> []
  where
    top = maximum (0 : map snd record)

-- | One line: the dialect, the model, the token counts, the cost and the
-- request identifier when the vendor reports them, and the notes.
--
-- UNCONFIRMED(U11): the local runners omit @model@, @id@ and @cost@, and
-- OpenAI omits @id@ and @cost@. Every narration field is optional.
--
-- UNCONFIRMED(U3): every source says the probabilities sum to approximately
-- 1, and none bounds the error. A sum outside 1 ± 1/100 adds a note and is
-- not refused, because the reading v/Σv does not depend on the sum.
narration :: Dialect -> KeyMap.KeyMap Value -> [(Text, Scientific)] -> [Text] -> Text
narration dialect envelope record notes =
  "decisions "
    <> dialectWord dialect
    <> ": model "
    <> maybe "unreported" clean (textAt ["model"])
    <> ", input tokens "
    <> maybe "unreported" numberText (numberAt ["usage", "input_tokens"])
    <> ", output tokens "
    <> maybe "unreported" numberText (numberAt ["usage", "output_tokens"])
    <> maybe "" ((", cost " <>) . numberText) (numberAt ["usage", "cost"])
    <> maybe "" ((", id " <>) . clean) (textAt ["id"])
    <> T.concat ["; note " <> note | note <- sumNote <> notes]
  where
    total = sum (map snd record)
    sumNote
      | total < 0.99 || total > 1.01 = ["the probabilities sum to " <> T.pack (formatScientific Fixed Nothing total)]
      | otherwise = []
    at path = go path (Object envelope)
      where
        go [] here = Just here
        go (key : rest) (Object fields) = KeyMap.lookup (Key.fromText key) fields >>= go rest
        go _ _ = Nothing
    textAt path = at path >>= \case
      String text -> Just text
      _ -> Nothing
    numberAt path = at path >>= \case
      Number n | boundedExponent n -> Just n
      _ -> Nothing
    numberText n = case floatingOrInteger n :: Either Double Integer of
      Right i -> showText i
      Left _ -> T.pack (formatScientific Fixed Nothing n)

-- | Classifies the status of a response, with its body when the body is one
-- JSON value. 'Nothing' means success (2xx). A status that a retry can cure
-- is a 'WireTransport' failure. Every other status is a 'WireProtocol'
-- failure, which includes a redirect, because redirects are not followed.
classifyStatus :: Int -> Maybe Value -> Maybe WireFailure
classifyStatus status body
  | status >= 200 && status < 300 = Nothing
  | status `elem` [408, 425, 429, 500, 502, 503, 504, 524, 529] = Just (WireTransport summary)
  -- UNCONFIRMED(U13): OpenRouter documents @error.metadata.limit_source@ with
  -- the value @openrouter_in_flight_budget@ as the transient 402, and no
  -- fixture from a live endpoint confirms it. Every other 402 is refused.
  | status == 402 && limitSource == Just "openrouter_in_flight_budget" = Just (WireTransport summary)
  -- UNCONFIRMED(U17): the dossier records OpenRouter's and TypeSafe's error
  -- statuses and envelopes, and not OpenAI's. An OpenAI error status is
  -- classified by the same table.
  | otherwise = Just (WireProtocol summary)
  where
    summary = "the endpoint answered HTTP " <> showText status <> maybe "" (\message -> ": " <> clean message) vendorMessage
    errorFields = case body of
      Just (Object fields) -> case KeyMap.lookup "error" fields of
        Just (Object inner) -> Just inner
        _ -> Nothing
      _ -> Nothing
    limitSource = do
      inner <- errorFields
      Object metadata <- KeyMap.lookup "metadata" inner
      String source <- KeyMap.lookup "limit_source" metadata
      pure source
    vendorMessage = case errorFields >>= KeyMap.lookup "message" of
      Just (String message) -> Just message
      _ -> case body of
        Just (Object fields) | Just (String detail) <- KeyMap.lookup "detail" fields -> Just detail
        _ -> Nothing

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

protocol :: Text -> WireFailure
protocol = WireProtocol

-- | The largest accepted absolute base-10 exponent of a vendor number. It
-- bounds the work of exact arithmetic on untrusted input.
boundedExponent :: Scientific -> Bool
boundedExponent n = abs (base10Exponent n) <= 4096

field :: Text -> Key -> KeyMap.KeyMap Value -> Either WireFailure Value
field what key fields =
  maybe (Left (protocol (what <> " lacks the field '" <> Key.toText key <> "'"))) Right (KeyMap.lookup key fields)

asObject :: Text -> Value -> Either WireFailure (KeyMap.KeyMap Value)
asObject _ (Object fields) = Right fields
asObject what _ = Left (protocol (what <> " is not an object"))

asArray :: Text -> Value -> Either WireFailure [Value]
asArray _ (Array items) = Right (V.toList items)
asArray what _ = Left (protocol (what <> " is not an array"))

asText :: Text -> Value -> Either WireFailure Text
asText _ (String text) = Right text
asText what _ = Left (protocol (what <> " is not a string"))

-- | Vendor text for one line of narration: control characters become spaces,
-- and the text is cut at 200 characters.
clean :: Text -> Text
clean = T.take 200 . T.map (\c -> if isControl c then ' ' else c)

showText :: Show a => a -> Text
showText = T.pack . show

-- | True when a token stream is one complete JSON value with no repeated key
-- in any object.
tokensOk :: (continuation -> Bool) -> Tokens.Tokens continuation error -> Bool
tokensOk done = \case
  Tokens.TkLit _ continuation -> done continuation
  Tokens.TkText _ continuation -> done continuation
  Tokens.TkNumber _ continuation -> done continuation
  Tokens.TkArrayOpen array -> arrayOk array
  Tokens.TkRecordOpen record -> recordOk Set.empty record
  Tokens.TkErr _ -> False
  where
    arrayOk = \case
      Tokens.TkItem value -> tokensOk arrayOk value
      Tokens.TkArrayEnd continuation -> done continuation
      Tokens.TkArrayErr _ -> False
    recordOk seen = \case
      Tokens.TkPair key value
        | key `Set.member` seen -> False
        | otherwise -> tokensOk (recordOk (Set.insert key seen)) value
      Tokens.TkRecordEnd continuation -> done continuation
      Tokens.TkRecordErr _ -> False
