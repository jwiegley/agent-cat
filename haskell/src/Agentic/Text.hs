{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Agentic.Text
-- Description : The string layer, ported from @Agentic/Core/Exec.lean@.
--
-- A byte-faithful port of the Lean string layer — @norm@, @answerLines@,
-- @words@, @sole@, @decodeFlag@, @decodeVerdict@, @Decode@ and the @say@
-- renderers of @Agentic/Core/Report.lean@ — behind the conformance dispatcher
-- 'stringOp' of @conformance/Conformance.lean@.
--
-- The one thing this module exists to get right is that /every/ character
-- predicate here is ASCII-only, exactly as Lean core's is. Nothing in this
-- module may reach for @Data.Text.toLower@, @Data.Text.strip@,
-- @Data.Char.isSpace@ or @Data.Char.isAlphaNum@: each of those is Unicode-aware
-- and each diverges from the oracle on an input the corpus pins (U+0130 @İ@,
-- U+00A0 NBSP, @ß@, @Σ@).
--
-- Self-contained by design: it does not depend on @Agentic.Raw@.
module Agentic.Text
  ( Verdict (..)
  , stringOp

    -- * The decode/say surface, exported for the IO runner and the adapter
    -- ("Agentic.Exec", "Agentic.AgentDeck"): the trusted string base exists
    -- once, here, and consumers import it rather than copying it.
  , norm
  , decodeFlag
  , decodeVerdict
  , sayFlag
  , sayVerdict
  ) where

import Data.Aeson (Value, object, toJSON, (.=))
import qualified Data.Aeson as A
import Data.Text (Text)
import qualified Data.Text as T

-- ---------------------------------------------------------------------------
-- ASCII character predicates (Lean core, quoted)
-- ---------------------------------------------------------------------------

-- | @Char.isWhitespace@ from Lean core:
--
-- > @[inline] def isWhitespace (c : Char) : Bool :=
-- >   c = ' ' || c = '\t' || c = '\r' || c = '\n'
--
-- Exactly four characters. Not @\\v@ (U+000B), not @\\f@ (U+000C), not NBSP
-- (U+00A0), not any Unicode space separator.
isWhitespaceAscii :: Char -> Bool
isWhitespaceAscii c = c == ' ' || c == '\t' || c == '\r' || c == '\n'
{-# INLINE isWhitespaceAscii #-}

-- | @Char.toLower@ from Lean core: shift @A@–@Z@ by 32, leave every other code
-- point alone. Code-point count is preserved, so @İ@ (U+0130) survives intact
-- rather than expanding to @i@ + U+0307 the way full Unicode lowercasing would.
toLowerAscii :: Char -> Char
toLowerAscii c
  | c >= 'A' && c <= 'Z' = toEnum (fromEnum c + 32)
  | otherwise = c
{-# INLINE toLowerAscii #-}

-- | @Char.isAlphanum = isAlpha || isDigit@, all three bounded to ASCII ranges in
-- Lean core. This is the token/separator split @words@ uses.
isAlphanumAscii :: Char -> Bool
isAlphanumAscii c =
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
{-# INLINE isAlphanumAscii #-}

-- | @String.trimAscii@: drop ASCII whitespace from both ends. Lean drops from
-- the start and then from the end; the two commute, so the order here is
-- immaterial.
trimAscii :: Text -> Text
trimAscii = T.dropWhileEnd isWhitespaceAscii . T.dropWhile isWhitespaceAscii

-- ---------------------------------------------------------------------------
-- Exec.norm, Exec.answerLines, Exec.words
-- ---------------------------------------------------------------------------

-- | @Exec.norm s = s.trimAscii.toString.toLower@: ASCII-trim both ends, then
-- ASCII-lowercase.
norm :: Text -> Text
norm = T.map toLowerAscii . trimAscii

-- | @Exec.answerLines@:
--
-- > ((s.splitOn "\n").map (fun l => l.trimAscii.toString)).filter (fun l => !l.isEmpty)
--
-- Split on @"\\n"@ only — never on @"\\r\\n"@ as a unit; the @\\r@ of a CRLF
-- line is what the per-line ASCII trim removes. No lowercasing happens here, so
-- objections keep their original case. @answerLines ""@ and @answerLines "   "@
-- are both @[]@.
answerLines :: Text -> [Text]
answerLines = filter (not . T.null) . map trimAscii . T.splitOn "\n"

-- | @Exec.words@: 'norm' the string, then take the maximal runs of ASCII
-- alphanumerics, dropping empty runs and preserving order.
--
-- @wordsOf "" == []@ and @wordsOf "İstanbul" == ["stanbul"]@: the @İ@ survives
-- 'norm' and then splits the token, because it is not ASCII alphanumeric.
wordsOf :: Text -> [Text]
wordsOf = filter (not . T.null) . T.split (not . isAlphanumAscii) . norm

-- ---------------------------------------------------------------------------
-- Exec.sole, Exec.decodeFlag, Exec.decodeVerdict
-- ---------------------------------------------------------------------------

-- | @Exec.sole l ws@: is @ws@ a single token, and is that token one of @l@?
sole :: [Text] -> [Text] -> Bool
sole l = \case
  [w] -> w `elem` l
  _ -> False

-- | @Exec.yesWords@.
yesWords :: [Text]
yesWords = ["yes", "y", "true", "approve", "approved", "ok"]

-- | @Exec.noWords@.
noWords :: [Text]
noWords = ["no", "n", "false", "reject", "rejected", "deny"]

-- | @Exec.approveWords@.
approveWords :: [Text]
approveWords = ["approve", "approved", "lgtm"]

-- | @Exec.saidNo@: a /no/ word __anywhere__ in the reply.
saidNo :: Text -> Bool
saidNo s = any (`elem` noWords) (wordsOf s)

-- | @Exec.saidYes@: the reply is a /yes/ word and nothing else.
saidYes :: Text -> Bool
saidYes = sole yesWords . wordsOf

-- | @Exec.approvesB@: the reply is an approve word and nothing else. Note this
-- runs on the raw string through @words@, not on 'answerLines'.
approvesB :: Text -> Bool
approvesB = sole approveWords . wordsOf

-- | @Exec.decodeFlag@. The asymmetry is the safety property: @saidNo@ is tested
-- first, a /no/ word anywhere denies, a /yes/ must be the whole reply.
decodeFlag :: Text -> Maybe Bool
decodeFlag s
  | saidNo s = Just False
  | saidYes s = Just True
  | otherwise = Nothing

-- | A verdict, in the three cases @Verdict.tag@ classifies.
--
-- __Invariant.__ In Lean a @Verdict@ is @WithZero (FreeMonoid Objection)@, so
-- @Verdict.object []@ /is/ the monoid unit — that is, approval — and tags as
-- @approve@, never as @object@ with an empty list. Build objecting verdicts with
-- 'mkObject', never with the bare constructor, so @Object []@ cannot escape.
-- ('verdictJson' and 'sayVerdict' normalize it too, belt and braces.)
data Verdict
  = Approve
  | Declined
  | Object [Text]
  deriving (Eq, Show)

-- | The smart constructor carrying the Lean invariant: an empty objection list
-- is the unit of the verdict monoid, which is approval.
mkObject :: [Text] -> Verdict
mkObject [] = Approve
mkObject os = Object os

-- | @Exec.decodeVerdict@:
--
-- > let ls := answerLines s
-- > if ls = [] then Verdict.declined
-- > else if approvesB s then Verdict.approve
-- > else Verdict.object ls
decodeVerdict :: Text -> Verdict
decodeVerdict s
  | null ls = Declined
  | approvesB s = Approve
  | otherwise = mkObject ls
  where
    ls = answerLines s

-- | @Conformance.verdictJson@:
--
-- > {"tag": "approve"}
-- > {"tag": "declined"}
-- > {"tag": "object", "objections": [...]}
verdictJson :: Verdict -> Value
verdictJson = \case
  Approve -> object ["tag" .= ("approve" :: Text)]
  Declined -> object ["tag" .= ("declined" :: Text)]
  Object [] -> object ["tag" .= ("approve" :: Text)] -- the unit tags as approve
  Object os ->
    object
      [ "tag" .= ("object" :: Text)
      , "objections" .= os
      ]

-- ---------------------------------------------------------------------------
-- Code, Decode, answerJson, sayAnswer
-- ---------------------------------------------------------------------------

-- | The answer kinds, @Question.Code@. Local to this module so that
-- "Agentic.Text" stands alone; @Agentic.Raw@ carries the shared copy.
data Code
  = CText
  | CVerdict
  | CFlag
  | CAck
  deriving (Eq, Show)

-- | @Dsl.codeOfName@. The @.ack@ code is spelled @receipt@ on the wire — never
-- @ack@ — because that is the keyword @codeName@ writes.
codeOfName :: Text -> Maybe Code
codeOfName = \case
  "text" -> Just CText
  "verdict" -> Just CVerdict
  "flag" -> Just CFlag
  "receipt" -> Just CAck
  _ -> Nothing

-- | @answerJson c <$> Decode c s@, collapsed: the value of the @"answer"@ field
-- of a @decode@ reply.
--
-- @Decode@ is total except at @.flag@, and both the @.ack@ success and the
-- @.flag@ failure serialize as JSON @null@; the ambiguity is in the oracle, so
-- there is nothing here to tell apart.
--
-- @.text@ is __verbatim__: no normalization, no trimming.
decodeAnswerJson :: Code -> Text -> Value
decodeAnswerJson c s = case c of
  CText -> A.String s
  CVerdict -> verdictJson (decodeVerdict s)
  CFlag -> maybe A.Null A.Bool (decodeFlag s)
  CAck -> A.Null

-- | @Report.sayFlag@.
sayFlag :: Bool -> Text
sayFlag b = if b then "yes" else "no"

-- | @Report.sayVerdict@. @Verdict.approvedB@ is tested first, so the unit —
-- @Object []@ — renders as @"approve"@.
sayVerdict :: Verdict -> Text
sayVerdict = \case
  Approve -> "approve"
  Declined -> "declined"
  Object [] -> "approve"
  Object os -> T.intercalate "; " os

-- | @sayAnswer c <$> Decode c s@, collapsed: 'Nothing' where @Decode@ fails
-- (only reachable at @.flag@).
sayAnswer :: Code -> Text -> Maybe Text
sayAnswer c s = case c of
  CText -> Just s
  CVerdict -> Just (sayVerdict (decodeVerdict s))
  CFlag -> sayFlag <$> decodeFlag s
  CAck -> Just "done"

-- ---------------------------------------------------------------------------
-- The dispatcher
-- ---------------------------------------------------------------------------

-- | @Conformance.stringOp op code text@ — the __whole reply object__ of a
-- @{"string": {op, code?, text}}@ request, wrapper and all.
--
-- >>> stringOp "norm" Nothing "  HeLLo World  "     -- {"result":"hello world"}
-- >>> stringOp "words" Nothing "  two   words \t here " -- {"result":["two","words","here"]}
-- >>> stringOp "decodeVerdict" Nothing ""           -- {"result":{"tag":"declined"}}
-- >>> stringOp "decode" (Just "flag") "maybe"       -- {"result":{"answer":null}}
-- >>> stringOp "say" (Just "flag") "no"             -- {"result":"no"}
--
-- The two result shapes differ: @decode@ nests its payload under @"answer"@ and
-- always produces that object, while @say@ puts a bare string — or a bare
-- @null@ on a decode failure — directly under @"result"@.
--
-- The @error@ branches have no corpus vectors; they are reproduced byte for
-- byte anyway, backticks included.
stringOp :: Text -> Maybe Text -> Text -> Value
stringOp op mcode text = case op of
  "norm" -> wrap (A.String (norm text))
  "words" -> wrap (toJSON (wordsOf text))
  "decodeVerdict" -> wrap (verdictJson (decodeVerdict text))
  "decode" ->
    withCode "decode takes a code: text, verdict, flag or receipt" $ \c ->
      object ["result" .= object ["answer" .= decodeAnswerJson c text]]
  "say" ->
    withCode "say takes a code" $ \c ->
      wrap (maybe A.Null A.String (sayAnswer c text))
  _ -> err ("unknown string op `" <> op <> "`")
  where
    wrap :: Value -> Value
    wrap j = object ["result" .= j]

    err :: Text -> Value
    err msg = object ["error" .= msg]

    withCode :: Text -> (Code -> Value) -> Value
    withCode msg k = maybe (err msg) k (mcode >>= codeOfName)
