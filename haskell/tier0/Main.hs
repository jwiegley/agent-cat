-- | Tier 0: the conformance runner.
--
-- Replays the frozen corpus produced by the Lean oracle
-- (@test/corpus/*.json@ at the repository root) against this
-- implementation, and reports every divergence. The comparison rules are
-- @PORTING.md@ §6; week one compares the JSON codec, the five term-level
-- guards, the two ask counts and the string layer, and nothing else.
--
-- Usage: @tier0 [corpusDir]@, defaulting to
-- @../test/corpus@ (this executable runs from @haskell/@). Exit status is 0 iff nothing
-- failed.
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Main (main) where

import Control.Exception
  ( SomeAsyncException
  , SomeException
  , evaluate
  , fromException
  , throwIO
  , try
  )
import Control.Monad (forM, unless)
import Data.Aeson (Result (..), Value (..), eitherDecodeStrict', fromJSON, toJSON)
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.Bits (shiftR, (.&.))
import qualified Data.ByteString as BS
import Data.Char (ord)
import Data.List (sort, sortOn)
import Data.Maybe (catMaybes)
import Data.Scientific (floatingOrInteger)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import qualified Data.Vector as V
import Numeric (showHex)
import System.Directory (doesDirectoryExist, listDirectory)
import System.Environment (getArgs)
import System.Exit (exitFailure, exitSuccess)
import System.FilePath (takeExtension, (</>))

import Agentic.Guards (Guard (..), askCounts, guardCheck)
import Agentic.Raw (RawProgram)
import Agentic.Text (stringOp)

-- ---------------------------------------------------------------------------
-- Entry classification and results
-- ---------------------------------------------------------------------------

-- | What kind of corpus entry this was, for the tally of PORTING.md §6.6.
data Kind
  = KString    -- ^ @request.string@ (22 expected)
  | KGuard     -- ^ @request.program@, refused with one of the five (5)
  | KOther     -- ^ @request.program@, refused @other@ — codec only (35)
  | KChecked   -- ^ @request.program@, checked (59)
  | KPing      -- ^ @request.ping@ — ignored (none exist)
  | KBroken    -- ^ the entry, or its reply, fits none of the rules — always a failure
  deriving (Eq, Show)

-- | One entry's verdict: the reasons it failed (empty means it passed) and
-- the class it was counted in.
data Report = Report {repFails :: [Text], repKind :: Kind}

ok :: Kind -> Report
ok = Report []

bad :: Kind -> Text -> Report
bad k msg = Report [msg] k

-- ---------------------------------------------------------------------------
-- Driver
-- ---------------------------------------------------------------------------

defaultCorpus :: FilePath
defaultCorpus = "../test/corpus"

main :: IO ()
main = do
  args <- getArgs
  let dir = case args of
        (d : _) -> d
        [] -> defaultCorpus
  present <- doesDirectoryExist dir
  unless present $ do
    TIO.putStrLn ("tier0: no such corpus directory: " <> T.pack dir)
    exitFailure
  files <- (sort . filter ((== ".json") . takeExtension)) <$> listDirectory dir
  if null files
    then do
      TIO.putStrLn ("tier0: no *.json entries under " <> T.pack dir)
      exitFailure
    else do
      results <- forM files $ \f -> (,) f <$> runFile (dir </> f)
      mapM_ report results
      let total = length results
          failed = length [() | (_, r) <- results, not (null (repFails r))]
          passed = total - failed
          kindly k = length [() | (_, r) <- results, repKind r == k]
          others = kindly KOther
      TIO.putStrLn $
        "tier0: kinds: "
          <> tshow (kindly KString)
          <> " string, "
          <> tshow (kindly KGuard)
          <> " guard, "
          <> tshow others
          <> " other, "
          <> tshow (kindly KChecked)
          <> " checked, "
          <> tshow (kindly KPing)
          <> " ping, "
          <> tshow (kindly KBroken)
          <> " unclassified"
      TIO.putStrLn $
        "tier0: "
          <> tshow passed
          <> " passed, "
          <> tshow failed
          <> " failed, "
          <> tshow others
          <> " other-refusals (codec-only), of "
          <> tshow total
          <> " files"
      if failed == 0 then exitSuccess else exitFailure
  where
    report (f, r) =
      unless (null (repFails r)) $
        TIO.putStrLn ("FAIL " <> T.pack f <> ": " <> T.intercalate "; " (repFails r))

-- | Read one corpus file and check it. Pure failure of the implementation
-- (a bottom in @guardCheck@ or @askCounts@) is caught and reported as a
-- failure rather than killing the run.
runFile :: FilePath -> IO Report
runFile path = do
  bytes <- BS.readFile path
  case eitherDecodeStrict' bytes of
    Left err -> pure (bad KBroken ("not valid JSON: " <> T.pack err))
    Right v -> do
      let r = checkEntry v
      caught <- try (evaluate (let fs = repFails r in sum (map T.length fs) `seq` fs))
      case caught :: Either SomeException [Text] of
        Right fs -> pure r {repFails = fs}
        Left e
          -- An interrupt is the user talking, not a conformance failure.
          | Just (_ :: SomeAsyncException) <- fromException e -> throwIO e
          | otherwise -> pure r {repFails = ["implementation raised: " <> squash (tshow e)]}

-- ---------------------------------------------------------------------------
-- The comparison rules (PORTING.md §6)
-- ---------------------------------------------------------------------------

checkEntry :: Value -> Report
checkEntry entry =
  case (field "request" entry, field "reply" entry) of
    (Just req, Just reply)
      | Just s <- field "string" req -> checkString s reply
      | Just p <- field "program" req -> checkProgram p reply
      | Just _ <- field "ping" req -> ok KPing
      | otherwise -> bad KBroken "request has none of string, program, ping"
    _ -> bad KBroken "entry lacks a request or a reply"

-- | §6.1 — a string entry compares the whole reply value.
checkString :: Value -> Value -> Report
checkString s reply =
  case (field "op" s >>= asText, field "text" s >>= asText) of
    (Just op, Just txt) ->
      let actual = stringOp op (field "code" s >>= asText) txt
       in if actual == reply
            then ok KString
            else
              bad KString $
                "string op `"
                  <> op
                  <> "` reply mismatch: expected "
                  <> clip (render reply)
                  <> ", actual "
                  <> clip (render actual)
    _ -> bad KString "request.string lacks a textual op or text"

-- | §6.2–§6.5 — a program entry always round-trips the codec, and then
-- compares whatever its reply class licenses.
checkProgram :: Value -> Value -> Report
checkProgram pv reply =
  case fromJSON pv :: Result RawProgram of
    Error err -> Report ["program decode failed: " <> squash (T.pack err)] kind
    Success p -> Report (codec p ++ semantics p) kind
  where
    kind = classOf reply

    -- §6.2: re-encoding must reproduce the request's program value exactly.
    codec p = case firstDiff pv (toJSON p) of
      Nothing -> []
      Just d -> ["codec round-trip differs at " <> d]

    semantics p = case kind of
      KGuard -> guardChecks p
      KChecked -> checkedChecks p
      KOther -> [] -- §6.4: an `other` refusal is codec-only.
      -- A reply the rules do not classify is a failure, never a quiet pass:
      -- a runner that skips what it does not recognise cannot go red when
      -- the corpus moves under it.
      _ -> case field "refused" reply of
        Just r ->
          [ "unknown refusal guard "
              <> maybe "(absent)" (render . String) (field "guard" r >>= asText)
          ]
        Nothing -> ["reply is neither a refusal nor a checked result (no `level`)"]

    -- §6.3: the guard and its n must match; pos/excerpt/message never do.
    guardChecks p =
      let expected = do
            r <- field "refused" reply
            g <- field "guard" r >>= asText
            pure (g, field "n" r >>= asInteger)
          actual = fmap (\(g, n) -> (guardName g, n)) (guardCheck p)
       in [ "refusal guard: expected " <> sayGuard expected <> ", actual " <> sayGuard actual
          | expected /= actual
          ]

    -- §6.5: a checked program raises no guard and its counts must match.
    checkedChecks p =
      let (blockA, fnsA) = askCounts p
          blockE = field "blockAsks" reply >>= asInteger
          fnsE = field "fnAsks" reply >>= asPairs
          fired = fmap (\(g, n) -> (guardName g, n)) (guardCheck p)
       in concat
            [ ["a checked program fired guard " <> sayGuard fired | fired /= Nothing]
            , [ "blockAsks: expected " <> maybe "(absent)" tshow blockE <> ", actual " <> tshow blockA
              | blockE /= Just blockA
              ]
            , [ "fnAsks: expected " <> maybe "(absent)" sayPairs fnsE <> ", actual " <> sayPairs fnsA
              | fnsE /= Just fnsA
              ]
            ]

-- | Which comparison class a reply belongs to.
classOf :: Value -> Kind
classOf reply = case field "refused" reply of
  Just r -> case field "guard" r >>= asText of
    Just g
      | g `elem` fiveGuards -> KGuard
      | g == "other" -> KOther
    _ -> KBroken
  Nothing
    | Just _ <- field "level" reply -> KChecked
    | otherwise -> KBroken

-- ---------------------------------------------------------------------------
-- Guards, rendered by name so no derived instances are assumed
-- ---------------------------------------------------------------------------

guardName :: Guard -> Text
guardName = \case
  PanelEmpty -> "panelEmpty"
  RevisionBound -> "revisionBound"
  QuestionBudget -> "questionBudget"
  ServedBy -> "servedBy"
  DupFunction -> "dupFunction"

fiveGuards :: [Text]
fiveGuards = map guardName [PanelEmpty, RevisionBound, QuestionBudget, ServedBy, DupFunction]

sayGuard :: Maybe (Text, Maybe Integer) -> Text
sayGuard = \case
  Nothing -> "no guard"
  Just (g, Nothing) -> g
  Just (g, Just n) -> g <> " n=" <> tshow n

sayPairs :: [(Text, Integer)] -> Text
sayPairs ps = "[" <> T.intercalate ", " [n <> "=" <> tshow k | (n, k) <- ps] <> "]"

-- ---------------------------------------------------------------------------
-- Value inspection
-- ---------------------------------------------------------------------------

field :: Text -> Value -> Maybe Value
field k (Object o) = case KM.lookup (K.fromText k) o of
  Just Null -> Nothing -- a missing key and an explicit null read alike.
  other -> other
field _ _ = Nothing

asText :: Value -> Maybe Text
asText (String t) = Just t
asText _ = Nothing

asInteger :: Value -> Maybe Integer
asInteger (Number n) = case floatingOrInteger n :: Either Double Integer of
  Right i -> Just i
  Left _ -> Nothing
asInteger _ = Nothing

-- | @[["name", n], …]@ as an ordered association list.
asPairs :: Value -> Maybe [(Text, Integer)]
asPairs (Array xs) = mapM pair (V.toList xs)
  where
    pair (Array p) = case V.toList p of
      [a, b] -> (,) <$> asText a <*> asInteger b
      _ -> Nothing
    pair _ = Nothing
asPairs _ = Nothing

-- ---------------------------------------------------------------------------
-- Structural diffing: the first place two values part company
-- ---------------------------------------------------------------------------

-- | @firstDiff expected actual@ names the first divergence as a JSON path
-- plus the two offending fragments, so a codec bug points at its own field
-- rather than dumping a whole program.
firstDiff :: Value -> Value -> Maybe Text
firstDiff = go "$"
  where
    go path expected actual = case (expected, actual) of
      (Object a, Object b)
        | not (null missing) -> Just (path <> ": missing key(s) " <> keyList missing)
        | not (null extra) -> Just (path <> ": unexpected key(s) " <> keyList extra)
        | otherwise ->
            firstJust
              [ go (path <> "." <> K.toText k) va vb
              | k <- sort (KM.keys a)
              , Just va <- [KM.lookup k a]
              , Just vb <- [KM.lookup k b]
              ]
        where
          missing = sort [k | k <- KM.keys a, not (KM.member k b)]
          extra = sort [k | k <- KM.keys b, not (KM.member k a)]
      (Array a, Array b)
        | V.length a /= V.length b ->
            Just $
              path
                <> ": array length: expected "
                <> tshow (V.length a)
                <> ", actual "
                <> tshow (V.length b)
        | otherwise ->
            firstJust
              [ go (path <> "[" <> tshow i <> "]") x y
              | (i, (x, y)) <- zip [(0 :: Int) ..] (zip (V.toList a) (V.toList b))
              ]
      _
        | expected == actual -> Nothing
        | otherwise ->
            Just $
              path
                <> ": expected "
                <> clip (render expected)
                <> ", actual "
                <> clip (render actual)

    keyList ks = T.intercalate ", " (map (render . String . K.toText) ks)

firstJust :: [Maybe a] -> Maybe a
firstJust xs = case catMaybes xs of
  (x : _) -> Just x
  [] -> Nothing

-- ---------------------------------------------------------------------------
-- Rendering: canonical, one line, and ASCII-safe
-- ---------------------------------------------------------------------------

-- | Keys sorted so two renderings are comparable by eye, and every
-- non-printable or non-ASCII character escaped — the corpus turns on
-- invisible differences (NBSP against space, dotted capital against @i@),
-- and a diagnostic that hides them is worse than none.
render :: Value -> Text
render = \case
  Null -> "null"
  Bool True -> "true"
  Bool False -> "false"
  Number n -> case floatingOrInteger n :: Either Double Integer of
    Right i -> tshow i
    Left d -> tshow d
  String s -> renderString s
  Array xs -> "[" <> T.intercalate "," (map render (V.toList xs)) <> "]"
  Object o ->
    "{"
      <> T.intercalate
        ","
        [ renderString (K.toText k) <> ":" <> render v
        | (k, v) <- sortOn fst (KM.toList o)
        ]
      <> "}"

renderString :: Text -> Text
renderString t = "\"" <> T.concatMap esc t <> "\""
  where
    esc c = case c of
      '"' -> "\\\""
      '\\' -> "\\\\"
      '\n' -> "\\n"
      '\r' -> "\\r"
      '\t' -> "\\t"
      _
        | ord c < 0x20 || ord c > 0x7e -> uni (ord c)
        | otherwise -> T.singleton c
    uni n
      | n <= 0xffff = hex4 n
      | otherwise =
          let n' = n - 0x10000
           in hex4 (0xd800 + (n' `shiftR` 10)) <> hex4 (0xdc00 + (n' .&. 0x3ff))
    hex4 n = "\\u" <> T.justifyRight 4 '0' (T.pack (showHex n ""))

-- | Keep every failure to one line, however large the offending value.
clip :: Text -> Text
clip t
  | T.length t > 400 = T.take 400 t <> "..."
  | otherwise = t

squash :: Text -> Text
squash = T.unwords . T.words

tshow :: Show a => a -> Text
tshow = T.pack . show
