-- | JSON values decoded without discarding duplicate fields or excessive nesting.
module Agentic.Manager.Protocol.Json (decodeStrictValue) where

import Control.Monad (unless)
import Data.Aeson (Value)
import Data.Aeson.Decoding (toEitherValue)
import Data.Aeson.Decoding.ByteString (bsToTokens)
import Data.Aeson.Decoding.Tokens (Tokens (..), TkArray (..), TkRecord (..))
import qualified Data.ByteString as BS
import qualified Data.Set as Set

-- Callers enforce their byte ceiling before this bounded-depth decode.
decodeStrictValue :: BS.ByteString -> Either String Value
decodeStrictValue bytes = do
  let tokens = bsToTokens bytes
  rest <- checkTokens 0 tokens
  unless (BS.all (`elem` [9, 10, 13, 32]) rest) (Left "trailing JSON data")
  either (const (Left "invalid JSON")) (Right . fst) (toEitherValue tokens)

-- Check the real Aeson token stream before object maps can discard duplicates.
checkTokens :: Int -> Tokens k e -> Either String k
checkTokens depth tokens = case tokens of
  TkLit _ rest -> Right rest
  TkText _ rest -> Right rest
  TkNumber _ rest -> Right rest
  TkErr _ -> Left "invalid JSON"
  TkArrayOpen items -> container >> array items
  TkRecordOpen fields -> container >> record Set.empty fields
  where
    container = unless (depth < 64) (Left "invalid JSON")
    array (TkItem item) = checkTokens (depth + 1) item >>= array
    array (TkArrayEnd rest) = Right rest
    array (TkArrayErr _) = Left "invalid JSON"
    record seen (TkPair key value)
      | Set.member key seen = Left "invalid JSON"
      | otherwise = checkTokens (depth + 1) value >>= record (Set.insert key seen)
    record _ (TkRecordEnd rest) = Right rest
    record _ (TkRecordErr _) = Left "invalid JSON"
