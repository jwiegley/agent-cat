{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

-- |
-- Module      : Agentic.Schema.Json
-- Description : JSON representation of schema-indexed structured values.
module Agentic.Schema.Json
  ( decode,
    decodeAs,
    encode,
    encodeAs,
    render,
    renderAs,
    jsonSchemaDocument,
    renderSchema,
    codeJson,
    schemaToJson,
    schemaFromJson,
    codeToJson,
    codeFromJson,
  )
where

import Agentic.Schema
import Data.Aeson (Value)
import qualified Data.Aeson as A
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson.Decoding.Text (textToTokens)
import qualified Data.Aeson.Decoding.Tokens as Tokens
import Data.Aeson.Types (Parser)
import qualified Data.ByteString.Lazy as BL
import Data.Proxy (Proxy (..))
import Data.Ratio ((%), denominator, numerator)
import Data.Scientific (Scientific, base10Exponent, coefficient, scientific)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Data.Vector as V
import GHC.TypeLits (symbolVal)

-- | Largest accepted absolute base-10 exponent. Bounds untrusted amplification.
maxDecimalExponent :: Int
maxDecimalExponent = 4096

scientificToRational :: Scientific -> Maybe Rational
scientificToRational number
  | decimalExponent < negate maxDecimalExponent = Nothing
  | decimalExponent > maxDecimalExponent = Nothing
  | decimalExponent >= 0 = Just (fromInteger (coefficient number * 10 ^ decimalExponent))
  | otherwise = Just (coefficient number % (10 ^ negate decimalExponent))
  where
    decimalExponent = base10Exponent number

factorOut :: Integer -> Integer -> (Int, Integer)
factorOut prime = go 0
  where
    go count value
      | value `mod` prime == 0 = go (count + 1) (value `div` prime)
      | otherwise = (count, value)

-- | A rational has a JSON realization exactly when its reduced denominator has
-- no prime factors other than two and five.
rationalToScientific :: Rational -> Maybe Scientific
rationalToScientific number =
  if rest == 1
    then
      let scale = max twos fives
          multiplier = 2 ^ (scale - twos) * 5 ^ (scale - fives)
       in if scale <= maxDecimalExponent
            then Just (scientific (numerator number * multiplier) (negate scale))
            else Nothing
    else Nothing
  where
    (twos, afterTwos) = factorOut 2 (denominator number)
    (fives, rest) = factorOut 5 afterTwos

schemaFields :: SchemaRep -> [(Text, SchemaRep)]
schemaFields = \case
  RepProperty name schema rest -> (name, schema) : schemaFields rest
  _ -> []

exactObject :: SchemaRep -> A.Object -> Bool
exactObject schema object =
  length fields == KM.size object
    && all (\(name, _) -> KM.member (K.fromText name) object) fields
  where
    fields = schemaFields schema

noDuplicateObjectKeys :: Text -> Bool
noDuplicateObjectKeys = tokensOk (const True) . textToTokens

tokensOk :: (continuation -> Bool) -> Tokens.Tokens continuation error -> Bool
tokensOk done = \case
  Tokens.TkLit _ continuation -> done continuation
  Tokens.TkText _ continuation -> done continuation
  Tokens.TkNumber _ continuation -> done continuation
  Tokens.TkArrayOpen array -> arrayOk done array
  Tokens.TkRecordOpen record -> recordOk Set.empty done record
  Tokens.TkErr _ -> False

arrayOk :: (continuation -> Bool) -> Tokens.TkArray continuation error -> Bool
arrayOk done = \case
  Tokens.TkItem value -> tokensOk (arrayOk done) value
  Tokens.TkArrayEnd continuation -> done continuation
  Tokens.TkArrayErr _ -> False

recordOk ::
  Set.Set K.Key ->
  (continuation -> Bool) ->
  Tokens.TkRecord continuation error ->
  Bool
recordOk seen done = \case
  Tokens.TkPair key value
    | key `Set.member` seen -> False
    | otherwise -> tokensOk (recordOk (Set.insert key seen) done) value
  Tokens.TkRecordEnd continuation -> done continuation
  Tokens.TkRecordErr _ -> False

decode :: SchemaWitness schema -> Text -> Maybe (SchemaEl schema)
decode schema text = do
  if not (noDuplicateObjectKeys text) then Nothing else do
    value <- A.decodeStrict' (TE.encodeUtf8 text)
    withSchema schema (\witness -> decodeValue witness value)

-- | Decode JSON directly into a Haskell type carrying 'HasSchema'.
decodeAs :: forall value. HasSchema value => Text -> Maybe value
decodeAs = fmap fromSchemaEl . decode (schemaOf @value)

decodeValue :: SSchema schema -> Value -> Maybe (SchemaEl schema)
decodeValue SSNull A.Null = Just ()
decodeValue SSBoolean (A.Bool value) = Just value
decodeValue SSInteger (A.Number value) = do
  rational <- scientificToRational value
  if denominator rational == 1 then Just (numerator rational) else Nothing
decodeValue SSNumber (A.Number value) = scientificToRational value
decodeValue SSString (A.String value) = Just value
decodeValue (SSArray items) (A.Array values) = traverse (decodeValue items) (V.toList values)
decodeValue SSObject (A.Object object)
  | KM.null object = Just ()
decodeValue schema@(SSProperty _ _) (A.Object object)
  | exactObject (demoteSSchema schema) object = decodeFields schema object
decodeValue _ _ = Nothing

decodeFields :: SSchema schema -> A.Object -> Maybe (SchemaEl schema)
decodeFields SSObject _ = Just ()
decodeFields (SSProperty @name schema rest) object = do
  raw <- KM.lookup (K.fromText (T.pack (symbolVal (Proxy @name)))) object
  value <- decodeValue schema raw
  values <- decodeFields rest object
  pure (value, values)
decodeFields _ _ = Nothing

equalValue :: SSchema schema -> SchemaEl schema -> SchemaEl schema -> Bool
equalValue SSNull () () = True
equalValue SSBoolean left right = left == right
equalValue SSInteger left right = left == right
equalValue SSNumber left right = left == right
equalValue SSString left right = left == right
equalValue (SSArray item) left right =
  length left == length right && and (zipWith (equalValue item) left right)
equalValue SSObject () () = True
equalValue (SSProperty field rest) (left, lefts) (right, rights) =
  equalValue field left right && equalValue rest lefts rights

encode :: SchemaWitness schema -> SchemaEl schema -> Maybe Value
encode schema value = withSchema schema $ \witness -> do
  candidate <- encodeValue witness value
  decoded <- decodeValue witness candidate
  if equalValue witness decoded value then Just candidate else Nothing

-- | Encode a Haskell type through its derived semantic schema.
encodeAs :: forall value. HasSchema value => value -> Maybe Value
encodeAs = encode (schemaOf @value) . toSchemaEl

encodeValue :: SSchema schema -> SchemaEl schema -> Maybe Value
encodeValue SSNull () = Just A.Null
encodeValue SSBoolean value = Just (A.Bool value)
encodeValue SSInteger value = Just (A.Number (fromInteger value))
encodeValue SSNumber value = A.Number <$> rationalToScientific value
encodeValue SSString value = Just (A.String value)
encodeValue (SSArray items) values = A.Array . V.fromList <$> traverse (encodeValue items) values
encodeValue SSObject () = Just (A.Object KM.empty)
encodeValue schema@(SSProperty _ _) values = A.Object . KM.fromList <$> encodeFields schema values

encodeFields :: SSchema schema -> SchemaEl schema -> Maybe [(K.Key, Value)]
encodeFields SSObject () = Just []
encodeFields (SSProperty @name schema rest) (value, values) = do
  encoded <- encodeValue schema value
  encodedRest <- encodeFields rest values
  pure ((K.fromText (T.pack (symbolVal (Proxy @name))), encoded) : encodedRest)
encodeFields _ _ = Nothing

renderValue :: Value -> Text
renderValue = TE.decodeUtf8 . BL.toStrict . A.encode

render :: SchemaWitness schema -> SchemaEl schema -> Maybe Text
render schema value = renderValue <$> encode schema value

-- | Render a Haskell type through its derived semantic schema.
renderAs :: forall value. HasSchema value => value -> Maybe Text
renderAs = render (schemaOf @value) . toSchemaEl

jsonSchemaDocument :: SchemaWitness schema -> Value
jsonSchemaDocument = jsonSchemaRep . demoteSchema

jsonSchemaRep :: SchemaRep -> Value
jsonSchemaRep = \case
  RepNull -> typeObject "null"
  RepBoolean -> typeObject "boolean"
  RepInteger -> typeObject "integer"
  RepNumber -> typeObject "number"
  RepString -> typeObject "string"
  RepArray items -> A.object ["type" A..= ("array" :: Text), "items" A..= jsonSchemaRep items]
  schema@RepObject -> objectSchema schema
  schema@RepProperty {} -> objectSchema schema
  where
    typeObject name = A.object ["type" A..= (name :: Text)]
    objectSchema schema =
      A.object
        [ "type" A..= ("object" :: Text),
          "properties" A..= A.object [K.fromText name A..= jsonSchemaRep field | (name, field) <- schemaFields schema],
          "required" A..= map fst (schemaFields schema),
          "additionalProperties" A..= False
        ]

renderSchema :: SchemaWitness schema -> Text
renderSchema = renderValue . jsonSchemaDocument

-- | Observation-wire code: old strings unchanged, structured codes carry schema.
codeJson :: SomeCode -> Value
codeJson (SomeCode SAck) = A.String "receipt"
codeJson code@(SomeCode (SStructured _)) = codeToJson code
codeJson code = A.String (codeName code)

schemaToJson :: SchemaRep -> Value
schemaToJson = \case
  RepNull -> "null"
  RepBoolean -> "boolean"
  RepInteger -> "integer"
  RepNumber -> "number"
  RepString -> "string"
  RepArray items -> A.object ["array" A..= A.object ["items" A..= schemaToJson items]]
  RepObject -> "object"
  RepProperty name schema rest ->
    A.object
      [ "property"
          A..= A.object
            [ "name" A..= name,
              "schema" A..= schemaToJson schema,
              "rest" A..= schemaToJson rest
            ]
      ]

schemaFromJson :: Value -> Parser SchemaRep
schemaFromJson = \case
  A.String "null" -> pure RepNull
  A.String "boolean" -> pure RepBoolean
  A.String "integer" -> pure RepInteger
  A.String "number" -> pure RepNumber
  A.String "string" -> pure RepString
  A.String "object" -> pure RepObject
  value -> A.withObject "Schema" parseObject value
  where
    parseObject object = case KM.toList object of
      [(tag, payload)]
        | tag == "array" -> A.withObject "Schema.array" (\o -> do
            items <- (o A..: "items" :: Parser Value)
            RepArray <$> schemaFromJson items) payload
        | tag == "property" ->
            A.withObject "Schema.property" (\o -> do
              name <- o A..: "name"
              schema <- (o A..: "schema" :: Parser Value) >>= schemaFromJson
              rest <- (o A..: "rest" :: Parser Value) >>= schemaFromJson
              pure (RepProperty name schema rest)) payload
      _ -> fail "Schema: expected null, boolean, integer, number, string, array, object or property"

codeToJson :: SomeCode -> Value
codeToJson (SomeCode code) = case code of
  SText -> "text"
  SVerdict -> "verdict"
  SFlag -> "flag"
  SAck -> "ack"
  SStructured schema -> A.object ["json" A..= A.object ["schema" A..= schemaToJson (demoteSchema schema)]]

codeFromJson :: Value -> Parser SomeCode
codeFromJson = \case
  A.String "text" -> pure (SomeCode SText)
  A.String "verdict" -> pure (SomeCode SVerdict)
  A.String "flag" -> pure (SomeCode SFlag)
  A.String "ack" -> pure (SomeCode SAck)
  value -> A.withObject "Code" parseObject value
  where
    parseObject object = case KM.toList object of
      [(tag, payload)]
        | tag == "json" -> A.withObject "Code.json" parseStructured payload
      _ -> fail "Code: expected text, verdict, flag, ack or a JSON-coded structured schema"
    parseStructured object = do
      raw <- (object A..: "schema" :: Parser Value) >>= schemaFromJson
      case promoteSchema raw of
        Just (SomeSchema schema) -> pure (SomeCode (SStructured schema))
        Nothing -> fail "Code.json: invalid schema"
