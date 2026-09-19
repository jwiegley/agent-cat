{-# LANGUAGE OverloadedStrings #-}

-- | The frozen public export document shape, not a semantic answer decoder.
module Agentic.Manager.Protocol.Artifact (validExportDocument, validExportName) where

import Data.Aeson (Value (..))
import qualified Data.Aeson.KeyMap as KM
import Data.Foldable (toList)
import qualified Data.Text as T

validExportName :: T.Text -> Bool
validExportName name = not (T.null name) && T.length name <= 128 && alpha (T.head name)
  && T.all (\c -> alpha c || c `elem` ("._-" :: String)) name
  where alpha c = c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9'

-- Structured values deliberately retain the contract's arbitrary JSON branch.
-- Native exact rational objects and public decimal fixtures are not normalized.
validExportDocument :: Value -> Bool
validExportDocument document@(Object fields) = depth 0 document && KM.size fields == 2 &&
  case (KM.lookup "code" fields,KM.lookup "value" fields) of
    (Just (String "text"),Just (String value)) -> T.length value <= 67108864
    (Just (String "flag"),Just (Bool _)) -> True
    (Just (String "receipt"),Just Null) -> True
    (Just (String "verdict"),Just (Object verdict)) -> case KM.lookup "tag" verdict of
      Just (String tag) | tag `elem` ["approve","declined"] -> KM.size verdict == 1
      Just (String "object") | KM.size verdict == 2 -> case KM.lookup "objections" verdict of
        Just (Array values) -> length values <= 256 && all objection values
        _ -> False
      _ -> False
    (Just (Object code),Just _) | KM.size code == 1 -> case KM.lookup "json" code of
      Just (Object json) | KM.size json == 1 -> maybe False semantic (KM.lookup "schema" json)
      _ -> False
    _ -> False
  where
    objection (String value) = T.length value <= 65536
    objection _ = False
validExportDocument _ = False

semantic :: Value -> Bool
semantic (String name) = name `elem` ["null","boolean","integer","number","string","object"]
semantic (Object fields) | KM.size fields == 1 = case (KM.lookup "array" fields,KM.lookup "property" fields) of
  (Just (Object array),Nothing) | KM.size array == 1 -> maybe False semantic (KM.lookup "items" array)
  (Nothing,Just (Object property)) | KM.size property == 3 ->
    case (KM.lookup "name" property,KM.lookup "schema" property,KM.lookup "rest" property) of
      (Just (String name),Just schema,Just rest) -> T.length name <= 1024 && semantic schema && objectSchema rest
      _ -> False
  _ -> False
semantic _ = False

objectSchema :: Value -> Bool
objectSchema (String "object") = True
objectSchema value@(Object fields) = KM.member "property" fields && semantic value
objectSchema _ = False

depth :: Int -> Value -> Bool
depth level (Object fields) = level < 64 && all (depth (level+1)) (KM.elems fields)
depth level (Array values) = level < 64 && all (depth (level+1)) (toList values)
depth _ _ = True
