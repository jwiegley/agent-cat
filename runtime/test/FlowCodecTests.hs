{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | Exact round trips of the carried plan values: 'requestJson' with
-- 'requestFromJson', and 'answerJson' with 'answerFromJsonExact'.
module FlowCodecTests (flowCodecTests) where

import Agentic.Plan
import Agentic.Planning
  ( Addressee (AddrModel, AddrPerson, AddrToolExec),
    answerFromJson,
    answerFromJsonExact,
    answerJson,
    requestFromJson,
    requestJson,
  )
import Agentic.Schema (Code (CodeStructured), Schema (SchemaNull, SchemaNumber, SchemaObject, SchemaProperty, SchemaString), schemaNull, schemaNumber, schemaObject, schemaProperty, schemaString)
import Control.Monad (unless)
import Data.Aeson (Value (Array, Bool, Null, Number, String), eitherDecode, encode, object, (.=))
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.KeyMap as KeyMap
import Data.Either (isLeft)
import Data.Maybe (isJust)
import Data.Ratio ((%))
import Data.Text (Text)
import qualified Data.Text as T

type Ledger =
  'SchemaProperty "amount" 'SchemaNumber
    ('SchemaProperty "third" 'SchemaNumber
      ('SchemaProperty "label" 'SchemaString
        ('SchemaProperty "nothing" 'SchemaNull 'SchemaObject)))

ledgerCode :: SCode ('CodeStructured Ledger)
ledgerCode =
  SStructured $
    schemaProperty @"amount" schemaNumber $
      schemaProperty @"third" schemaNumber $
        schemaProperty @"label" schemaString (schemaProperty @"nothing" schemaNull schemaObject)

unicode :: Text
unicode = "Gr\252\223e, \26085\26412, \55348\56606, \"quoted\"\n\\tab"

question :: Addressee -> Integer -> Q c
question addressee = Q addressee (QScope (Just "claude") Nothing) unicode

flowCodecTests :: IO ()
flowCodecTests = do
  let text = Request (question (AddrModel "writer") 0) Consult
      verdict = Request (Q (AddrPerson "owner") scopeUnit "approve?" 2) Observe
      flag = Request (Q (AddrToolExec "gate" "make" ["check", "--all"]) (QScope Nothing (Just "strict")) "" 1) Consult
      receipt = Request (question (AddrModel "actor") 3) Effect
      structured = Request (question (AddrModel "ledger") 12345678901234567890) Observe
  exact "text" SText text unicode
  exact "verdict approve" SVerdict verdict Approve
  exact "verdict declined" SVerdict verdict Declined
  exact "verdict object" SVerdict verdict (Object ["fix \10003", ""])
  exact "flag false" SFlag flag False
  exact "flag true" SFlag flag True
  exact "receipt" SAck receipt ()
  exact "structured" ledgerCode structured
    (123456789012345678901234567890123 % 1000, (1 % 3, (unicode, ((), ()))))
  check "receipt answer is JSON null" (answerJson SAck () == Null)
  check "flag false answer is JSON false" (answerJson SFlag False == Bool False)

  -- Negative controls.
  let approveExtra = object ["tag" .= ("approve" :: Text), "extra" .= False]
  check "lenient answerFromJson still accepts a verdict extra" (isJust (answerFromJson SVerdict approveExtra))
  refused "verdict with an extra key" (answerFromJsonExact SVerdict approveExtra)
  refused "object verdict without objections"
    (answerFromJsonExact SVerdict (object ["tag" .= ("object" :: Text), "objections" .= ([] :: [Text])]))
  refused "rational outside lowest terms"
    (answerFromJsonExact (SStructured schemaNumber) (object ["numerator" .= (-2 :: Int), "denominator" .= (6 :: Int)]))
  refused "flag answer at the text code" (answerFromJsonExact SText (Bool False))
  let encoded = requestJson SText text
      withField key value = case encoded of
        Aeson.Object fields -> Aeson.Object (KeyMap.insert key value fields)
        _ -> encoded
      withoutField key = case encoded of
        Aeson.Object fields -> Aeson.Object (KeyMap.delete key fields)
        _ -> encoded
  refused "request with an unknown field" (requestFromJson SText (withField "extra" Null))
  mapM_
    (\key -> refused ("request without " <> show key) (requestFromJson SText (withoutField key)))
    ["code", "intent", "addressee", "scope", "prompt", "draw"]
  refused "request whose code differs" (requestFromJson SFlag encoded)
  refused "request whose structured schema differs" (requestFromJson ledgerCode (requestJson (SStructured schemaNumber) structured))
  refused "effect intent at a text code" (requestFromJson SText (withField "intent" (String "effect")))
  refused "unknown intent" (requestFromJson SText (withField "intent" (String "command")))
  refused "addressee with an extra field"
    (requestFromJson SText (withField "addressee" (object ["model" .= object ["id" .= ("writer" :: Text), "extra" .= True]])))
  refused "scope with an extra key"
    (requestFromJson SText (withField "scope" (object ["model" .= Null, "mode" .= Null, "extra" .= Null])))
  refused "scope without mode" (requestFromJson SText (withField "scope" (object ["model" .= Null])))
  refused "fractional draw" (requestFromJson SText (withField "draw" (Number 1.5)))
  refused "draw as text" (requestFromJson SText (withField "draw" (String "0")))
  refused "prompt as a number" (requestFromJson SText (withField "prompt" (Number 1)))
  refused "request as an array" (requestFromJson SText (Array mempty))
  putStrLn "flow codec checks passed: exact request and answer round trips, refused extra, unknown, missing and differing forms"
  where
    exact :: (Eq (El c), Show (El c)) => String -> SCode c -> Request c -> El c -> IO ()
    exact label code request answer = do
      let requestValue = requestJson code request
          answerValue = answerJson code answer
      check (label <> " request round trip") (requestFromJson code requestValue == Right request)
      check (label <> " request byte round trip") ((eitherDecode (encode requestValue) >>= first' . requestFromJson code) == Right request)
      check (label <> " answer round trip") (answerFromJsonExact code answerValue == Right answer)
      check (label <> " answer byte round trip") ((eitherDecode (encode answerValue) >>= first' . answerFromJsonExact code) == Right answer)
    first' :: Either Text a -> Either String a
    first' = either (Left . T.unpack) Right
    refused :: String -> Either Text a -> IO ()
    refused label result = check ("refuses " <> label) (isLeft result)
    check :: String -> Bool -> IO ()
    check label ok = unless ok (fail ("flow codec: " <> label))
