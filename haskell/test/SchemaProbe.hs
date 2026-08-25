{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}

module Main (main) where

import qualified Agentic.Builder as B
import Agentic.Exec (askDecoding)
import qualified Agentic.Observe as O
import Agentic.Plan (Q (Q), scopeUnit)
import Agentic.Raw (Addressee (AddrModel))
import Agentic.Schema
import qualified Agentic.Schema.Conformance as C
import Agentic.Schema.Json
import Agentic.Schema.TH (deriveSchema)
import qualified Agentic.Workflow as W
import Agentic.World (defaultWorldSpec)
import qualified Data.Aeson as A
import qualified Data.Aeson.KeyMap as KM
import Data.Aeson.Types (parseEither)
import Data.IORef (newIORef, atomicModifyIORef', readIORef)
import Data.Maybe (isNothing)
import Data.Ratio ((%))
import Data.Type.Equality ((:~:) (Refl))
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import System.Exit (exitFailure)
import Test.QuickCheck (isSuccess, maxSuccess, quickCheckWithResult, stdArgs)
import Example.Structured (ReleasePlan (ReleasePlan), consumeModelJson, structuredAnswer)

data Approval = Approval
  { plan :: ReleasePlan,
    approved :: Bool
  }
  deriving (Eq, Show)

$(deriveSchema ''Approval)

type ExampleSchema =
  'SchemaProperty
    "count"
    'SchemaInteger
    ('SchemaProperty "name" 'SchemaString 'SchemaObject)

nameSchema :: SchemaWitness ('SchemaProperty "name" 'SchemaString 'SchemaObject)
nameSchema = schemaProperty @"name" schemaString schemaObject

exampleSchema :: SchemaWitness ExampleSchema
exampleSchema = schemaProperty @"count" schemaInteger nameSchema

exampleValue :: SchemaEl ExampleSchema
exampleValue = (3, ("Ada", ()))

schemaFunction :: B.Fn '[] ('CodeStructured ExampleSchema)
schemaFunction =
  B.function "schema.fn" B.noParams $ \() ->
    B.bindAsB @"value" (B.one (B.askModel "structured" [B.lit "answer"])) B.answerB

schemaAmendment ::
  W.W ('W.Amending ('CodeStructured ExampleSchema) '[]) ('W.Open '[]) W.Term
schemaAmendment =
  W.amend (W.ask (W.model "structured") [W.lit "amend"])

schemaProgram :: B.Program
schemaProgram =
  B.program [] $
    B.bindAsI (SStructured exampleSchema) "value"
      (B.one (B.askModel "structured" [B.lit "answer"])) B.stop

main :: IO ()
main = do
  let qc = stdArgs {maxSuccess = 200}
  recordLaw <- quickCheckWithResult qc $ \(count :: Integer) (name :: String) ->
    let value = (count, (T.pack name, ()))
     in case render exampleSchema value of
          Nothing -> False
          Just encoded -> decode exampleSchema encoded == Just value
  arrayLaw <- quickCheckWithResult qc $ \(values :: [Integer]) ->
    let schema = schemaArray schemaInteger
     in case render schema values of
          Nothing -> False
          Just encoded -> decode schema encoded == Just values
  numberLaw <- quickCheckWithResult qc $ \(value :: Rational) ->
    case render schemaNumber value of
      Nothing -> True
      Just encoded -> decode schemaNumber encoded == Just value
  replies <- newIORef ["not json", "{\"count\":3,\"name\":\"Ada\"}"]
  let question = Q (AddrModel "structured") scopeUnit "answer structurally" 0
      say _ = atomicModifyIORef' replies $ \case
        [] -> ([], "not json")
        reply : rest -> (rest, reply)
  decoded <- askDecoding (const (pure ())) 1 (SStructured exampleSchema) question say
  remaining <- readIORef replies
  let missingWorldRejected = case O.observeValue schemaProgram [defaultWorldSpec] of
        A.Object object -> KM.member "error" object
        _ -> False
  let expected =
        A.object
          [ "count" A..= (3 :: Integer),
            "name" A..= ("Ada" :: Text)
          ]
      workedPlan =
        ReleasePlan "Ship structured answers" 1 ["decode JSON", "consume typed fields"]
      workedSchema =
        RepProperty
          "title"
          RepString
          (RepProperty "priority" RepInteger (RepProperty "steps" (RepArray RepString) RepObject))
      exampleCode = SomeCode (SStructured exampleSchema)
      codeRoundTrips = case parseEither codeFromJson (codeToJson exampleCode) of
        Right decodedCode -> decodedCode == exampleCode
        Left _ -> False
      knownSchemaMatches = case sameSchema (schemaWitness @ExampleSchema) exampleSchema of
        Just Refl -> True
        Nothing -> False
      promotedSchemaMatches = case promoteSchema (demoteSchema exampleSchema) of
        Nothing -> False
        Just (SomeSchema promoted) -> case sameSchema promoted exampleSchema of
          Just Refl -> True
          Nothing -> False
      exactAnswer = C.SomeAnswer exampleSchema exampleValue
      exactRoundTrips = case (A.fromJSON (A.toJSON exactAnswer) :: A.Result C.SomeAnswer) of
        A.Success decodedAnswer -> A.toJSON decodedAnswer == A.toJSON exactAnswer
        A.Error _ -> False
      malformedExactRejected = case
          A.fromJSON (A.object ["schema" A..= schemaToJson (demoteSchema exampleSchema), "value" A..= A.object ["count" A..= (3 :: Integer)]])
            :: A.Result C.SomeAnswer of
        A.Success _ -> False
        A.Error _ -> True
      negativeDenominatorRejected = case
          A.fromJSON (A.object
            [ "schema" A..= schemaToJson (demoteSchema schemaNumber),
              "value" A..= A.object ["numerator" A..= (1 :: Integer), "denominator" A..= (-2 :: Integer)]
            ]) :: A.Result C.SomeAnswer of
        A.Success _ -> False
        A.Error _ -> True
      checks =
        [ ("semantic product is directly usable", fst exampleValue == 3),
          ("TH derives schema from record fields", demoteSchema (schemaOf @ReleasePlan) == workedSchema),
          ("TH semantic conversion round-trips", fromSchemaEl (toSchemaEl workedPlan) == workedPlan),
          ("TH JSON helpers round-trip", (renderAs workedPlan >>= consumeModelJson) == Just workedPlan),
          ("worked example consumes model JSON fields", consumeModelJson structuredAnswer == Just workedPlan),
          ("record codec commuting law", isSuccess recordLaw),
          ("array codec commuting law", isSuccess arrayLaw),
          ("representable number codec commuting law", isSuccess numberLaw),
          ( "TH composes nested records",
            let approval = Approval workedPlan True
             in (renderAs approval >>= decodeAs @Approval) == Just approval
          ),
          ("schema function results are first-class", schemaFunction `seq` True),
          ("schema revision candidates are first-class", schemaAmendment `seq` True),
          ("invalid structured reply is re-asked", decoded == exampleValue && null remaining),
          ("missing queried schema fixture is rejected", missingWorldRejected),
          ("structured value encodes", encode exampleSchema exampleValue == Just expected),
          ("field order in JSON is irrelevant", decode exampleSchema "{\"name\":\"Ada\",\"count\":3}" == Just exampleValue),
          ("missing field is rejected", isNothing (decode exampleSchema "{\"name\":\"Ada\"}")),
          ("extra field is rejected", isNothing (decode exampleSchema "{\"count\":3,\"name\":\"Ada\",\"extra\":true}")),
          ("wrong field type is rejected", isNothing (decode exampleSchema "{\"count\":\"three\",\"name\":\"Ada\"}")),
          ("duplicate JSON member is rejected", isNothing (decode exampleSchema "{\"count\":3,\"name\":\"Ada\",\"name\":\"Eve\"}")),
          ("escaped duplicate JSON member is rejected", isNothing (decode exampleSchema "{\"count\":3,\"name\":\"Ada\",\"\\u006eame\":\"Eve\"}")),
          ("finite rational decodes exactly", decode schemaNumber "0.5" == Just (1 % 2)),
          ("oversized negative decimal exponent is rejected", isNothing (decode schemaNumber "1e-999999")),
          ("oversized positive decimal exponent is rejected", isNothing (decode schemaNumber "1e999999")),
          ("finite rational encodes", encode schemaNumber (1 % 2) == A.decode "0.5"),
          ("non-finite rational has no JSON representation", isNothing (encode schemaNumber (1 % 3))),
          ("duplicate property is rejected",
            isNothing (promoteSchema (RepProperty "name" RepString (demoteSchema nameSchema)))),
          ("non-object property tail is rejected",
            isNothing (promoteSchema (RepProperty "bad" RepString RepString))),
          ("schema is part of code identity", codeRep exampleCode /= codeRep (SomeCode (SStructured nameSchema))),
          ("schema code wire round-trips", codeRoundTrips),
          ("KnownSchema reproduces the witness", knownSchemaMatches),
          ("promoteSchema reverses demoteSchema", promotedSchemaMatches),
          ("exact conformance answer round-trips", exactRoundTrips),
          ("malformed exact fixture is rejected", malformedExactRejected),
          ("negative exact denominator is rejected", negativeDenominatorRejected),
          ("exact conformance lookup preserves value", C.lookupAnswer [exactAnswer] exampleSchema == Just exampleValue),
          ("exact conformance distinguishes non-finite rationals", C.encodeExact schemaNumber (1 % 3) /= C.encodeExact schemaNumber (2 % 3))
        ]
      failed = [name | (name, ok) <- checks, not ok]
  mapM_ (TIO.putStrLn . ("FAIL " <>)) failed
  if null failed
    then TIO.putStrLn "schema probe: all checks passed"
    else exitFailure
