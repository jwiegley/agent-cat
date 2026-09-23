{-# LANGUAGE OverloadedStrings #-}

-- | Bounded immutable page sets, with scoped response loans and absolute expiry.
module Agentic.Manager.Pages (PageSets, newPageSets, withPage) where

import Agentic.Manager.Protocol.Command
import Control.Concurrent.STM
import Control.Exception (mask, onException)
import Control.Monad (unless, when)
import Crypto.Random (getRandomBytes)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.Types (Pair)
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import qualified Data.ByteString as BS
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Clock (addUTCTime, getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import qualified Data.Vector as V
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import Text.Read (readMaybe)

-- No entry retains a database transaction, authorization watch or worker.
data Entry = Entry
  { entryClient :: !Text, entryView :: !Text, entryQuery :: !Text,
    entryDeadline :: !Word64, entryContent :: !(Maybe (Text, V.Vector BS.ByteString)),
    entryReaders :: !Int, entryRetired :: !Bool }

newtype PageSets = PageSets (TVar (Map.Map Text Entry))

newPageSets :: IO PageSets
newPageSets = PageSets <$> newTVarIO Map.empty

-- | Reserve capacity before construction. Each continuation is compared with
-- the newly authorized client/view/query, never authorized by token possession.
-- The caller retains its response view through the supplied sender callback.
withPage :: PageSets -> Text -> Text -> Text -> Int -> Maybe Text
  -> IO (Text, [Pair], [Value]) -> (Text -> BS.ByteString -> IO a) -> IO a
withPage (PageSets entries) client view query limit token produce send = mask $ \restore ->
  case token of
    Nothing -> do
      now <- getMonotonicTimeNSec
      unless (limit > 0 && now <= maxBound - lifetime) (atomically (throwSTM StorageQuota))
      expiry <- T.pack . formatTime defaultTimeLocale "%FT%T%QZ" . addUTCTime 60 <$> getCurrentTime
      random <- getRandomBytes 16 :: IO BS.ByteString
      let ident = "set_" <> TE.decodeUtf8 (convertToBase Base16 random)
          entry = Entry client view query (now + lifetime) Nothing 1 False
      atomically $ do
        current <- clean now <$> readTVar entries
        when (Map.member ident current) (throwSTM StorageUnavailable)
        when (Map.size current >= limit || length (filter ((== client) . entryClient) (Map.elems current)) >= 2)
          (throwSTM StorageQuota)
        writeTVar entries (Map.insert ident entry current)
      let abandon = atomically (release entries ident True)
      (value, terminal) <- (restore $ do
        (revision, fields, values) <- produce
        unless (validRevision revision) (atomically (throwSTM InvalidRequest))
        pages <- either (atomically . throwSTM) pure (materialize ident query revision expiry fields values)
        currentTime <- getMonotonicTimeNSec
        atomically $ do
          current <- readTVar entries
          case Map.lookup ident current of
            Just held | not (entryRetired held) && currentTime < entryDeadline held ->
              writeTVar entries (Map.insert ident held {entryContent = Just (revision, pages)} current)
            _ -> throwSTM ViewExpired
        first <- maybe (atomically (throwSTM ViewTooLarge)) pure (pages V.!? 0)
        result <- send revision first
        pure (result, V.length pages == 1)) `onException` abandon
      atomically (release entries ident terminal)
      pure value
    Just supplied -> do
      (ident, index) <- either (atomically . throwSTM) pure (parseToken supplied)
      now <- getMonotonicTimeNSec
      (revision, bytes, terminal) <- atomically $ do
        current <- clean now <$> readTVar entries
        case Map.lookup ident current of
          Just held | not (entryRetired held) && entryDeadline held > now
            && entryClient held == client && entryView held == view && entryQuery held == query ->
              case entryContent held of
                Just (revision, pages) | Just bytes <- pages V.!? index -> do
                  writeTVar entries (Map.insert ident held {entryReaders = entryReaders held + 1} current)
                  pure (revision, bytes, index == V.length pages - 1)
                _ -> throwSTM ViewExpired
          _ -> throwSTM ViewExpired
      value <- restore (send revision bytes) `onException` atomically (release entries ident True)
      atomically (release entries ident terminal)
      pure value

-- Expired or retired sends remain charged until their original callbacks unwind.
clean :: Word64 -> Map.Map Text Entry -> Map.Map Text Entry
clean now = Map.mapMaybe $ \entry ->
  let retired = entryRetired entry || entryDeadline entry <= now
   in if retired && entryReaders entry == 0 then Nothing else Just entry {entryRetired = retired}

release :: TVar (Map.Map Text Entry) -> Text -> Bool -> STM ()
release entries ident retire = modifyTVar' entries $ Map.update done ident
  where
    done entry =
      let remaining = entryReaders entry - 1
          retired = entryRetired entry || retire
       in if remaining == 0 && retired then Nothing
          else Just entry {entryReaders = remaining, entryRetired = retired}

lifetime :: Word64
lifetime = 60000000000

parseToken :: Text -> Either CommandFailure (Text, Int)
parseToken value = do
  let (prefix, number) = T.breakOnEnd "-" value
      ident = T.dropEnd 1 prefix
  unless (not (T.null prefix) && validId ident && T.length value <= 512) (Left ViewExpired)
  index <- maybe (Left ViewExpired) Right (readMaybe (T.unpack number))
  unless (index > 0 && T.pack (show index) == number) (Left ViewExpired)
  pure (ident, index)

materialize :: Text -> Text -> Text -> Text -> [Pair] -> [Value]
  -> Either CommandFailure (V.Vector BS.ByteString)
materialize ident query revision expiry fields values = do
  unless (all (`notElem` ["version", "page", "items"]) (map fst fields)) (Left InvalidRequest)
  V.fromList <$> build 0 0 encodedItems
  where
    total = length values
    encodedItems = [(value, BS.length (encoded value)) | value <- values]
    next index = query <> (if "?" `T.isInfixOf` query then "&" else "?")
      <> "pageToken=" <> ident <> "-" <> T.pack (show index)
    document :: Int -> Bool -> [Value] -> BS.ByteString
    document index more items = encoded $ object (fields <>
      ["version" .= (1 :: Int), "items" .= items,
       "page" .= object ["setId" .= ident, "revision" .= revision, "expiresAt" .= expiry,
         "index" .= index, "totalItems" .= total, "next" .= (if more then Just (next (index + 1)) else Nothing)]])
    pageLimit = 1048576
    setLimit = 67108864
    build :: Int -> Int -> [(Value, Int)] -> Either CommandFailure [BS.ByteString]
    build index used remaining = do
      let (candidate, rest) = splitAt 256 remaining
          finalBytes = document index False (map fst candidate)
      if null rest && BS.length finalBytes <= pageLimit
        then do
          unless (used + BS.length finalBytes <= setLimit) (Left ViewTooLarge)
          pure [finalBytes]
        else do
          let overhead = BS.length (document index True ([] :: [Value]))
              (chosen, tailItems) = takePage (pageLimit - overhead) 0 [] remaining
          when (null chosen) (Left ViewTooLarge)
          let bytes = document index (not (null tailItems)) chosen
              charged = used + BS.length bytes
          unless (BS.length bytes <= pageLimit && charged <= setLimit) (Left ViewTooLarge)
          (bytes :) <$> build (index + 1) charged tailItems
    takePage :: Int -> Int -> [Value] -> [(Value, Int)] -> ([Value], [(Value, Int)])
    takePage _ _ chosen [] = (reverse chosen, [])
    takePage budget count chosen allItems@((value, size):rest)
      | count == 256 || size + separator > budget = (reverse chosen, allItems)
      | otherwise = takePage (budget - size - separator) (count + 1) (value : chosen) rest
      where separator = if count == 0 then 0 else 1
