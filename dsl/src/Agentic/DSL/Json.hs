{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Canonical JSON rendering at the DSL representation boundary.
module Agentic.DSL.Json
  ( printedValue,
    render,
    renderString,
  )
where

import Agentic.Builder (ProgramOf, progRawOut)
import Data.Aeson (Value (..), toJSON)
import Data.Char (ord)
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.List (sortOn)
import Data.Scientific (floatingOrInteger)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Vector as V

-- | The builder's first-order program as JSON.
printedValue :: ProgramOf r -> Value
printedValue = toJSON . progRawOut

-- | Stable compact JSON with sorted keys and visible non-ASCII characters.
render :: Value -> Text
render = \case
  Null -> "null"
  Bool True -> "true"
  Bool False -> "false"
  Number number -> case floatingOrInteger number :: Either Double Integer of
    Right integer -> tshow integer
    Left double -> tshow double
  String text -> renderString text
  Array values -> "[" <> T.intercalate "," (map render (V.toList values)) <> "]"
  Object object ->
    "{"
      <> T.intercalate
        ","
        [ renderString (K.toText key) <> ":" <> render value
        | (key, value) <- sortOn fst (KM.toList object)
        ]
      <> "}"

renderString :: Text -> Text
renderString text = "\"" <> T.concatMap escape text <> "\""
  where
    escape character = case character of
      '"' -> "\\\""
      '\\' -> "\\\\"
      '\n' -> "\\n"
      '\r' -> "\\r"
      '\t' -> "\\t"
      _
        | ord character < 0x20 || ord character > 0x7e -> unicode (ord character)
        | otherwise -> T.singleton character
    unicode number = "\\u" <> T.pack (pad (hex number ""))
    pad string = replicate (4 - length string) '0' <> string
    hex 0 accumulator = if null accumulator then "0" else accumulator
    hex number accumulator = hex (number `div` 16) (digit (number `mod` 16) : accumulator)
    digit number
      | number < 10 = toEnum (fromEnum '0' + number)
      | otherwise = toEnum (fromEnum 'a' + number - 10)

tshow :: (Show a) => a -> Text
tshow = T.pack . show
