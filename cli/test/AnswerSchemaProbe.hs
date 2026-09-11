{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module AnswerSchemaProbe (main) where

import qualified Agentic.Planning as P
import Agentic.Schema
import Agentic.Schema.Json
import Control.Monad (forM, unless)
import qualified Data.Aeson as A
import Data.Aeson.Types (parseEither)
import qualified Data.ByteString.Lazy.Char8 as BL
import Data.Either (isLeft)
import Data.Maybe (isJust)
import Data.Ratio ((%))
import System.IO (hPutStrLn, stderr)

type NestedSchema =
  'SchemaProperty "rows"
    ('SchemaArray ('SchemaProperty "ratios" ('SchemaArray 'SchemaNumber) 'SchemaObject))
    ('SchemaProperty "flag" 'SchemaBoolean ('SchemaProperty "nothing" 'SchemaNull 'SchemaObject))

nestedSchema :: SchemaWitness NestedSchema
nestedSchema =
  schemaProperty @"rows" (schemaArray (schemaProperty @"ratios" (schemaArray schemaNumber) schemaObject)) $
    schemaProperty @"flag" schemaBoolean (schemaProperty @"nothing" schemaNull schemaObject)

json :: BL.ByteString -> A.Value
json = either error id . A.eitherDecode

check :: String -> Bool -> IO ()
check label ok = unless ok (fail label)

vector :: String -> SCode c -> A.Value -> A.Value
vector label code value = A.object
  [ "label" A..= label,
    "schema" A..= P.answerJsonSchema code,
    "value" A..= value,
    "accepted" A..= isJust (P.answerFromJson code value)
  ]

cases :: String -> SCode c -> [(BL.ByteString, Bool)] -> IO [A.Value]
cases label code samples = forM samples $ \(raw, expected) -> do
  let value = json raw
      name = label ++ ": " ++ BL.unpack raw
  check name (isJust (P.answerFromJson code value) == expected)
  pure (vector name code value)

main :: IO ()
main = do
  explicit <- sequence
    [ cases "text" SText [("\"\"", True), ("\"hello\"", True), ("null", False), ("false", False)],
      cases "flag" SFlag [("false", True), ("true", True), ("0", False), ("null", False)],
      cases "ack" SAck [("null", True), ("false", False), ("{}", False)],
      cases "verdict" SVerdict
        [ ("{\"tag\":\"approve\"}", True),
          ("{\"tag\":\"declined\"}", True),
          ("{\"tag\":\"approve\",\"extra\":false,\"objections\":null}", True),
          ("{\"tag\":\"declined\",\"extra\":{},\"objections\":7}", True),
          ("{\"tag\":\"object\",\"objections\":[]}", True),
          ("{\"tag\":\"object\",\"objections\":[\"\",\"fix\"],\"extra\":null}", True),
          ("{\"tag\":\"object\"}", False),
          ("{\"tag\":\"object\",\"objections\":null}", False),
          ("{\"tag\":\"object\",\"objections\":[false]}", False),
          ("{\"tag\":\"unknown\"}", False), ("{\"tag\":false}", False),
          ("{}", False), ("null", False)
        ],
      cases "exact rational" (SStructured schemaNumber)
        [ ("{\"numerator\":1,\"denominator\":3}", True),
          ("{\"numerator\":0,\"denominator\":1}", True),
          ("{\"numerator\":-2,\"denominator\":6}", True),
          ("{\"numerator\":1.0,\"denominator\":3e0}", True),
          ("{\"numerator\":1,\"denominator\":0}", False),
          ("{\"numerator\":1,\"denominator\":-3}", False),
          ("{\"numerator\":1.5,\"denominator\":3}", False),
          ("{\"numerator\":1,\"denominator\":1.5}", False),
          ("{\"numerator\":\"1\",\"denominator\":3}", False),
          ("{\"numerator\":false,\"denominator\":3}", False),
          ("{\"numerator\":1,\"denominator\":null}", False),
          ("{\"numerator\":1}", False), ("{\"denominator\":3}", False),
          ("{\"numerator\":1,\"denominator\":3,\"extra\":null}", False),
          ("0.3333333333333333", False), ("null", False)
        ],
      cases "nested exact" (SStructured nestedSchema)
        [ ("{\"rows\":[{\"ratios\":[{\"numerator\":1,\"denominator\":3}]}],\"flag\":false,\"nothing\":null}", True),
          ("{\"rows\":[],\"flag\":false,\"nothing\":null}", True),
          ("{\"rows\":[{\"ratios\":[]}],\"flag\":true,\"nothing\":null}", True),
          ("{\"rows\":[{\"ratios\":[{\"numerator\":1,\"denominator\":0}]}],\"flag\":false,\"nothing\":null}", False),
          ("{\"rows\":[{\"ratios\":[{\"numerator\":1,\"denominator\":-3}]}],\"flag\":false,\"nothing\":null}", False),
          ("{\"rows\":[{\"ratios\":[0.5]}],\"flag\":false,\"nothing\":null}", False),
          ("{\"rows\":[{\"ratios\":[],\"extra\":0}],\"flag\":false,\"nothing\":null}", False),
          ("{\"rows\":[{}],\"flag\":false,\"nothing\":null}", False),
          ("{\"rows\":[],\"flag\":false}", False),
          ("{\"rows\":[],\"flag\":false,\"nothing\":null,\"extra\":0}", False)
        ],
      cases "structured null" (SStructured schemaNull) [("null", True), ("false", False)],
      cases "structured boolean" (SStructured schemaBoolean) [("false", True), ("null", False)],
      cases "structured integer" (SStructured schemaInteger) [("-2", True), ("2.0", True), ("2.5", False), ("true", False)],
      cases "structured string" (SStructured schemaString) [("\"\"", True), ("null", False)],
      cases "empty object" (SStructured schemaObject) [("{}", True), ("{\"extra\":null}", False), ("[]", False)],
      cases "array" (SStructured (schemaArray schemaNumber)) [("[]", True), ("[null]", False), ("{}", False)]
    ]
  check "exact 1/3 remains exact" $
    P.answerFromJson (SStructured schemaNumber) (json "{\"numerator\":1,\"denominator\":3}") == Just (1 % 3)
  check "nested exact answer retains false and null" $
    P.answerFromJson (SStructured nestedSchema)
      (json "{\"rows\":[{\"ratios\":[{\"numerator\":1,\"denominator\":3}]}],\"flag\":false,\"nothing\":null}")
      == Just ([([1 % 3], ())], (False, ((), ())))
  check "model number schema unchanged" $ jsonSchemaDocument schemaNumber == json "{\"type\":\"number\"}"
  check "model number rendering unchanged" $ renderSchema schemaNumber == "{\"type\":\"number\"}"
  check "nested model schema unchanged" $ jsonSchemaDocument nestedSchema == json
    "{\"type\":\"object\",\"properties\":{\"rows\":{\"type\":\"array\",\"items\":{\"type\":\"object\",\"properties\":{\"ratios\":{\"type\":\"array\",\"items\":{\"type\":\"number\"}}},\"required\":[\"ratios\"],\"additionalProperties\":false}},\"flag\":{\"type\":\"boolean\"},\"nothing\":{\"type\":\"null\"}},\"required\":[\"rows\",\"flag\",\"nothing\"],\"additionalProperties\":false}"
  check "model finite decimal decoding unchanged" $ decode schemaNumber "0.5" == Just (1 % 2)
  check "model non-finite rational encoding unchanged" $ encode schemaNumber (1 % 3) == Nothing
  let codes = [SomeCode SText, SomeCode SFlag, SomeCode SAck, SomeCode SVerdict,
               SomeCode (SStructured schemaNull), SomeCode (SStructured schemaBoolean),
               SomeCode (SStructured schemaInteger), SomeCode (SStructured schemaNumber),
               SomeCode (SStructured schemaString), SomeCode (SStructured schemaObject),
               SomeCode (SStructured (schemaArray schemaNumber)), SomeCode (SStructured nestedSchema)]
  mapM_ (\some@(SomeCode code) -> do
      check ("observation code " ++ show some) $
        parseEither P.answerSchemaForObservationCode (codeJson some)
          == Right (codeName some, P.answerJsonSchema code)
      check ("authoring codec unchanged " ++ show some) $
        parseEither codeFromJson (codeToJson some) == Right some) codes
  check "observation receipt returns public receipt" $
    parseEither P.answerSchemaForObservationCode "receipt" == Right ("receipt", json "{\"type\":\"null\"}")
  check "authoring receipt still refused" $ isLeft (parseEither codeFromJson "receipt")
  let malformedSchemas =
        [ RepProperty "x" RepString (RepProperty "x" RepInteger RepObject),
          RepProperty "x" RepString RepString,
          RepArray (RepProperty "x" RepString RepNull)
        ]
      malformedCodes = ["ack", "unknown", A.Null, json "{}", json "{\"json\":{}}", json "{\"json\":{\"schema\":\"unknown\"}}"] ++
        [A.object ["json" A..= A.object ["schema" A..= schemaToJson schema]] | schema <- malformedSchemas]
  mapM_ (\raw -> check ("invalid observation " ++ show raw) $
      isLeft (parseEither P.answerSchemaForObservationCode raw)) malformedCodes
  let bounded = map json ["null", "false", "true", "0", "-1", "1.5", "\"\"", "[]", "{}",
                          "{\"numerator\":1,\"denominator\":3}", "{\"tag\":\"approve\",\"objections\":false}"]
      matrix = [vector (show (codeName some) ++ " bounded " ++ show value) code value |
                some@(SomeCode code) <- codes, value <- bounded]
      vectors = concat explicit ++ matrix
  BL.putStrLn (A.encode vectors)
  hPutStrLn stderr ("answer schema probe: Haskell checks passed, " ++ show (length vectors) ++ " bounded vectors emitted")
