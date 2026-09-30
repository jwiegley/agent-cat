{-# LANGUAGE OverloadedStrings #-}

-- | Bounded immutable page sets, with scoped response loans and absolute expiry.
-- A windowed set holds the pages of one keyset window at a time, and each new
-- window renews its expiry.
module Agentic.Manager.Pages
  ( PageSets, Window (..), Producer (..), newPageSets, wholeSet, withPage, reservePageSet ) where

import Agentic.Manager.Fault (ManagerFault (PageSetCollision))
import Agentic.Manager.Protocol.Command
import Control.Concurrent.STM
import Control.Exception (mask, onException, throwIO)
import Control.Monad (unless, when)
import Crypto.Random (getRandomBytes)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson.Types (Pair)
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import qualified Data.ByteString as BS
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
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
    entryDeadline :: !Word64, entryContent :: !(Maybe Content),
    entryReaders :: !Int, entryRetired :: !Bool }

-- The encoded pages of the current window, the set index of its first page,
-- and what the next window needs when more members follow.
data Content = Content
  { contentRevision :: !Text, contentFirst :: !Int, contentPages :: !(V.Vector BS.ByteString),
    contentFollowing :: !(Maybe Following) }

-- The set facts that every later window repeats, and the last identifier of
-- the current window.
data Following = Following
  { followingAfter :: !Text, followingExpiry :: !Text, followingFields :: ![Pair], followingTotal :: !Int }

-- | The members of one window in set order, and the last identifier of the
-- window when more members follow it.
data Window = Window { windowItems :: ![Value], windowAfter :: !(Maybe Text) }

-- | The producers of one page set. 'produceFirst' returns the set revision,
-- its top-level fields, the total member count and the first window, at one
-- boundary. 'produceAfter' returns the window that follows a last identifier.
data Producer = Producer
  { produceFirst :: IO (Text, [Pair], Int, Window), produceAfter :: Text -> IO Window }

-- | A set of one window. Its total is its member count.
wholeSet :: IO (Text, [Pair], [Value]) -> Producer
wholeSet produce = Producer
  (do (revision, fields, values) <- produce
      pure (revision, fields, length values, Window values Nothing))
  (\_ -> throwIO ViewExpired)

newtype PageSets = PageSets (TVar (Map.Map Text Entry))

newPageSets :: IO PageSets
newPageSets = PageSets <$> newTVarIO Map.empty

-- A continuation either reads a page of the current window or builds the
-- window that follows it.
data Step = Serve !(Text, BS.ByteString, Bool) | Extend !Content !Following

-- | Reserve capacity before construction. Each continuation is compared with
-- the newly authorized client/view/query, never authorized by token possession.
-- The caller retains its response view through the supplied sender callback.
-- The token of the page after the last page of a window builds the next
-- window, replaces the held pages and renews the set lifetime. A token of any
-- other index outside the current window is expired.
withPage :: PageSets -> Text -> Text -> Text -> Int -> Maybe Text
  -> Producer -> (Text -> BS.ByteString -> IO a) -> IO a
withPage (PageSets entries) client view query limit token producer send = mask $ \restore ->
  case token of
    Nothing -> do
      now <- getMonotonicTimeNSec
      unless (limit > 0 && now <= maxBound - lifetime) (atomically (throwSTM StorageQuota))
      expiry <- T.pack . formatTime defaultTimeLocale "%FT%T%QZ" . addUTCTime 60 <$> getCurrentTime
      random <- getRandomBytes 16 :: IO BS.ByteString
      let ident = "set_" <> TE.decodeUtf8 (convertToBase Base16 random)
      atomically (reservePageSet (PageSets entries) client view query limit now ident)
      let abandon = atomically (release entries ident True)
      (value, terminal) <- (restore $ do
        (revision, fields, total, Window values after) <- produceFirst producer
        unless (validRevision revision) (atomically (throwSTM InvalidRequest))
        pages <- either (atomically . throwSTM) pure
          (materialize ident query revision expiry fields total 0 (isJust after) values)
        currentTime <- getMonotonicTimeNSec
        let content = Content revision 0 pages ((\last' -> Following last' expiry fields total) <$> after)
        atomically $ do
          current <- readTVar entries
          case Map.lookup ident current of
            Just held | not (entryRetired held) && currentTime < entryDeadline held ->
              writeTVar entries (Map.insert ident held {entryContent = Just content} current)
            _ -> throwSTM ViewExpired
        first <- maybe (atomically (throwSTM ViewTooLarge)) pure (pages V.!? 0)
        result <- send revision first
        pure (result, V.length pages == 1 && not (isJust after))) `onException` abandon
      atomically (release entries ident terminal)
      pure value
    Just supplied -> do
      (ident, index) <- either (atomically . throwSTM) pure (parseToken supplied)
      now <- getMonotonicTimeNSec
      step <- atomically $ do
        current <- clean now <$> readTVar entries
        case Map.lookup ident current of
          Just held | not (entryRetired held) && entryDeadline held > now
            && entryClient held == client && entryView held == view && entryQuery held == query ->
              case entryContent held of
                Just content -> do
                  chosen <- stepAt content index
                  writeTVar entries (Map.insert ident held {entryReaders = entryReaders held + 1} current)
                  pure chosen
                _ -> throwSTM ViewExpired
          _ -> throwSTM ViewExpired
      (revision, bytes, terminal) <- case step of
        Serve served -> pure served
        Extend content following ->
          restore (extend ident index content following) `onException` atomically (release entries ident False)
      value <- restore (send revision bytes) `onException` atomically (release entries ident True)
      atomically (release entries ident terminal)
      pure value
  where
    stepAt content index
      | Just bytes <- page content index = pure (Serve (serve content index bytes))
      | index == contentFirst content + V.length (contentPages content),
        Just following <- contentFollowing content = pure (Extend content following)
      | otherwise = throwSTM ViewExpired
    page content index
      | index >= contentFirst content = contentPages content V.!? (index - contentFirst content)
      | otherwise = Nothing
    serve content index bytes = (contentRevision content, bytes,
      index == contentFirst content + V.length (contentPages content) - 1 && not (isJust (contentFollowing content)))
    -- The window is built outside the entry and installed only while the
    -- entry still holds the window that it follows. A concurrent follower
    -- that installed the same window first supplies the page instead.
    extend ident index content following = do
      Window values after <- produceAfter producer (followingAfter following)
      pages <- either throwIO pure
        (materialize ident query (contentRevision content) (followingExpiry following) (followingFields following)
          (followingTotal following) index (isJust after) values)
      currentTime <- getMonotonicTimeNSec
      unless (currentTime <= maxBound - lifetime) (throwIO ViewExpired)
      let next = Content (contentRevision content) index pages ((\last' -> following {followingAfter = last'}) <$> after)
      atomically $ do
        current <- readTVar entries
        case Map.lookup ident current of
          Just held | not (entryRetired held) && currentTime < entryDeadline held, Just installed <- entryContent held ->
            if contentFirst installed == contentFirst content
              then do
                writeTVar entries (Map.insert ident held {entryContent = Just next,
                  entryDeadline = currentTime + lifetime} current)
                maybe (throwSTM ViewTooLarge) (pure . serve next index) (pages V.!? 0)
              else case page installed index of
                Just bytes -> pure (serve installed index bytes)
                Nothing -> throwSTM ViewExpired
          _ -> throwSTM ViewExpired

-- | Reserve one fresh page-set identifier and its capacity before construction.
-- An identifier that is already reserved is an internal collision, and the
-- capacity limits are the declared storage-quota refusal.
reservePageSet :: PageSets -> Text -> Text -> Text -> Int -> Word64 -> Text -> STM ()
reservePageSet (PageSets entries) client view query limit now ident = do
  current <- clean now <$> readTVar entries
  when (Map.member ident current) (throwSTM PageSetCollision)
  when (Map.size current >= limit || length (filter ((== client) . entryClient) (Map.elems current)) >= 2)
    (throwSTM StorageQuota)
  writeTVar entries (Map.insert ident (Entry client view query (now + lifetime) Nothing 1 False) current)

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

-- | The pages of one window. The first page has the given set index, the
-- total is the member count of the whole set, and the last page links to the
-- next index when another window follows. The page-set bound applies to each
-- window.
materialize :: Text -> Text -> Text -> Text -> [Pair] -> Int -> Int -> Bool -> [Value]
  -> Either CommandFailure (V.Vector BS.ByteString)
materialize ident query revision expiry fields total first continues values = do
  unless (all (`notElem` ["version", "page", "items"]) (map fst fields)) (Left InvalidRequest)
  V.fromList <$> build first 0 encodedItems
  where
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
          finalBytes = document index continues (map fst candidate)
      if null rest && BS.length finalBytes <= pageLimit
        then do
          unless (used + BS.length finalBytes <= setLimit) (Left ViewTooLarge)
          pure [finalBytes]
        else do
          let overhead = BS.length (document index True ([] :: [Value]))
              (chosen, tailItems) = takePage (pageLimit - overhead) 0 [] remaining
          when (null chosen) (Left ViewTooLarge)
          let bytes = document index (continues || not (null tailItems)) chosen
              charged = used + BS.length bytes
          unless (BS.length bytes <= pageLimit && charged <= setLimit) (Left ViewTooLarge)
          (bytes :) <$> build (index + 1) charged tailItems
    takePage :: Int -> Int -> [Value] -> [(Value, Int)] -> ([Value], [(Value, Int)])
    takePage _ _ chosen [] = (reverse chosen, [])
    takePage budget count chosen allItems@((value, size):rest)
      | count == 256 || size + separator > budget = (reverse chosen, allItems)
      | otherwise = takePage (budget - size - separator) (count + 1) (value : chosen) rest
      where separator = if count == 0 then 0 else 1
