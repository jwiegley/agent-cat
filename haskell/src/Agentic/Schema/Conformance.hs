{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

-- | Exact, total conformance representation of schema values.
module Agentic.Schema.Conformance
  ( SomeAnswer (..),
    lookupAnswer,
    coversAnswer,
    uniqueAnswers,
    encodeExact,
  )
where

import Agentic.Schema
import Agentic.Schema.Json (schemaFromJson, schemaToJson)
import Data.Aeson (FromJSON (..), ToJSON (..), Value)
import qualified Data.Aeson as A
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson.Types (Parser)
import Data.Proxy (Proxy (..))
import Data.Ratio ((%), denominator, numerator)
import qualified Data.Text as T
import qualified Data.Vector as V
import Data.Type.Equality ((:~:) (Refl))
import GHC.TypeLits (symbolVal)

data SomeAnswer where
  SomeAnswer :: SchemaWitness schema -> SchemaEl schema -> SomeAnswer

encodeExact :: SchemaWitness schema -> SchemaEl schema -> Value
encodeExact schema value = withSchema schema (\witness -> encodeShape witness value)

encodeShape :: SSchema schema -> SchemaEl schema -> Value
encodeShape SSNull () = A.Null
encodeShape SSBoolean value = A.Bool value
encodeShape SSInteger value = A.toJSON value
encodeShape SSNumber value =
  A.object ["numerator" A..= numerator value, "denominator" A..= denominator value]
encodeShape SSString value = A.String value
encodeShape (SSArray items) values = A.Array (V.fromList (map (encodeShape items) values))
encodeShape SSObject () = A.Object KM.empty
encodeShape schema@(SSProperty _ _) values = A.Object (KM.fromList (encodeFields schema values))

encodeFields :: SSchema schema -> SchemaEl schema -> [(K.Key, Value)]
encodeFields SSObject () = []
encodeFields (SSProperty @name schema rest) (value, values) =
  (K.fromText (T.pack (symbolVal (Proxy @name))), encodeShape schema value)
    : encodeFields rest values
encodeFields _ _ = []

decodeShape :: SSchema schema -> Value -> Maybe (SchemaEl schema)
decodeShape SSNull A.Null = Just ()
decodeShape SSBoolean (A.Bool value) = Just value
decodeShape SSInteger value = case A.fromJSON value of
  A.Success integer -> Just integer
  A.Error _ -> Nothing
decodeShape SSNumber (A.Object object)
  | KM.size object == 2 = do
      numeratorValue <- KM.lookup "numerator" object
      denominatorValue <- KM.lookup "denominator" object
      num <- case A.fromJSON numeratorValue of A.Success value -> Just value; A.Error _ -> Nothing
      den <- case A.fromJSON denominatorValue of A.Success value -> Just value; A.Error _ -> Nothing
      if den <= (0 :: Integer) then Nothing else Just (num % den)
decodeShape SSString (A.String value) = Just value
decodeShape (SSArray items) (A.Array values) = traverse (decodeShape items) (V.toList values)
decodeShape SSObject (A.Object object)
  | KM.null object = Just ()
decodeShape schema@(SSProperty _ _) (A.Object object)
  | length (schemaFields (demoteSSchema schema)) == KM.size object = decodeFields schema object
decodeShape _ _ = Nothing

decodeFields :: SSchema schema -> A.Object -> Maybe (SchemaEl schema)
decodeFields SSObject _ = Just ()
decodeFields (SSProperty @name schema rest) object = do
  value <- KM.lookup (K.fromText (T.pack (symbolVal (Proxy @name)))) object >>= decodeShape schema
  values <- decodeFields rest object
  pure (value, values)
decodeFields _ _ = Nothing

schemaFields :: SchemaRep -> [(T.Text, SchemaRep)]
schemaFields = \case
  RepProperty name schema rest -> (name, schema) : schemaFields rest
  _ -> []

instance ToJSON SomeAnswer where
  toJSON (SomeAnswer schema value) =
    A.object ["schema" A..= schemaToJson (demoteSchema schema), "value" A..= encodeExact schema value]

instance Eq SomeAnswer where
  left == right = A.toJSON left == A.toJSON right

instance Show SomeAnswer where
  show = show . A.toJSON

instance FromJSON SomeAnswer where
  parseJSON = A.withObject "SchemaAnswer" $ \object -> do
    schemaValue <- (object A..: "schema" :: Parser Value)
    rep <- schemaFromJson schemaValue
    raw <- object A..: "value"
    case promoteSchema rep of
      Nothing -> fail "SchemaAnswer: invalid schema"
      Just (SomeSchema schema) ->
        case withSchema schema (\witness -> decodeShape witness raw) of
          Nothing -> fail "SchemaAnswer: value does not match schema"
          Just value -> pure (SomeAnswer schema value)

lookupAnswer :: [SomeAnswer] -> SchemaWitness schema -> Maybe (SchemaEl schema)
lookupAnswer [] _ = Nothing
lookupAnswer (SomeAnswer schema value : rest) wanted =
  case sameSchema schema wanted of
    Just Refl -> Just value
    Nothing -> lookupAnswer rest wanted

coversAnswer :: [SomeAnswer] -> SomeSchema -> Bool
coversAnswer answers (SomeSchema schema) = case lookupAnswer answers schema of
  Just _ -> True
  Nothing -> False

uniqueAnswers :: [SomeAnswer] -> Bool
uniqueAnswers [] = True
uniqueAnswers (SomeAnswer schema _ : rest) =
  all (\(SomeAnswer other _) -> demoteSchema schema /= demoteSchema other) rest
    && uniqueAnswers rest
