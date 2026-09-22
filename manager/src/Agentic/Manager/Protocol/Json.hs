{-# LANGUAGE OverloadedStrings #-}
-- | JSON values decoded without discarding duplicate fields or excessive nesting.
module Agentic.Manager.Protocol.Json (decodeStrictValue, representableEditorSchema) where

import Control.Monad (unless)
import Data.Aeson (Value (..))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KM
import Data.Foldable (toList)
import qualified Data.Text as T
import Data.Aeson.Decoding (toEitherValue)
import Data.Aeson.Decoding.ByteString (bsToTokens)
import Data.Aeson.Decoding.Tokens (Tokens (..), TkArray (..), TkRecord (..))
import qualified Data.ByteString as BS
import qualified Data.Set as Set

-- | The frozen supplementary editor vocabulary. Reject the whole rendering when
-- a nested constraint cannot be represented, rather than silently weakening it.
representableEditorSchema :: Value -> Bool
representableEditorSchema (Object fields) = case KM.lookup "type" fields of
  Just(String kind) | kind `elem` ["null","boolean","integer","number","string"] -> keys==Set.singleton "type"
  Just(String "array") -> keys==Set.fromList ["type","items"] && maybe False representableEditorSchema (KM.lookup "items" fields)
  Just(String "object") -> keys==Set.fromList ["type","properties","required","additionalProperties"] &&
    KM.lookup "additionalProperties" fields==Just(Bool False) && case (KM.lookup "properties" fields,KM.lookup "required" fields) of
      (Just(Object properties),Just(Array required)) ->
        let names=map Key.toText(KM.keys properties)
            requested=[name|String name<-toList required]
        in KM.size properties<=256 && length requested==length required && length requested<=256 &&
          Set.size(Set.fromList requested)==length requested && Set.fromList requested==Set.fromList names &&
          all ((<=1024) . T.length) (names<>requested) && all representableEditorSchema (KM.elems properties)
      _ -> False
  _ -> False
  where keys=Set.fromList(KM.keys fields)
representableEditorSchema _ = False

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
      | Set.member key seen = Left "duplicate-field"
      | otherwise = checkTokens (depth + 1) value >>= record (Set.insert key seen)
    record _ (TkRecordEnd rest) = Right rest
    record _ (TkRecordErr _) = Left "invalid JSON"
