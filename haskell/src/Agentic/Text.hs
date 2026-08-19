{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- |
-- Module      : Agentic.Text
-- Description : The string layer, ported from @Agentic/Core/Text.lean@.
--
-- A byte-faithful port of the Lean string layer — @norm@, @answerLines@,
-- @words@, @sole@, @decodeFlag@, @decodeVerdict@, @Decode@ and the @say@
-- renderers of @Agentic/Core/Report.lean@ — behind the conformance dispatcher
-- 'stringOpOf' of @conformance/Conformance.lean@.
--
-- Since wave three it holds two more groups, both ported from
-- @Agentic/Core/Text.lean@, which is where Lean moved them so that the checker
-- (which sits below @Exec@ in the import graph) can see them:
--
--   * @bare@, @fields@, @diffHeaders@, @headerPaths@, @matchGlob@ and the one
--     normalization rule (@dlines@ \/ @dneedle@) the four deciders of D7 are
--     composed from, and 'runDecider' itself;
--   * @escapeClose@, @block@ and @validLabel@ — the fence a @panelText@ (D2)
--     folds its members into, and what a label may be spelled with.
--
-- The one thing this module exists to get right is that /every/ character
-- predicate here is ASCII-only, exactly as Lean core's is — the deciders and
-- the fence included. Nothing in this module may reach for
-- @Data.Text.toLower@, @Data.Text.strip@, @Data.Char.isSpace@ or
-- @Data.Char.isAlphaNum@: each of those is Unicode-aware and each diverges
-- from the oracle on an input the corpus pins (U+0130 @İ@, U+00A0 NBSP, @ß@,
-- @Σ@).
--
-- Self-contained by design: it does not depend on @Agentic.Raw@. That is why
-- 'Decider' — which Lean declares in @Agentic/Core/Dsl/Syntax.lean@ beside the
-- @RawRhs@ constructor that carries it — is declared /here/ and re-exported by
-- "Agentic.Raw" for the codec: its four algorithms are string-layer decisions,
-- they are pinned by string-layer vectors, and a copy of the type in @Raw@
-- would put the import arrow the wrong way round. One type, one table
-- ('deciderName' \/ 'deciderOfName'), one implementation.
module Agentic.Text
  ( Verdict (..)
  , stringOp
  , stringOpOf

    -- * The closed decider vocabulary (D7)
  , Decider (..)
  , deciderName
  , deciderOfName
  , runDecider

    -- * The primitives the deciders are composed from
  , answerLines
  , bare
  , fields
  , diffHeaders
  , headerPaths
  , matchGlob

    -- * The fence a text panel folds into (D2)
  , escapeClose
  , block
  , validLabel

    -- * The decode/say surface, exported for the IO runner and the adapter
    -- ("Agentic.Exec", "Agentic.AgentDeck"): the trusted string base exists
    -- once, here, and consumers import it rather than copying it.
  , norm
  , decodeFlag
  , decodeVerdict
  , sayFlag
  , sayVerdict
  ) where

import Data.Aeson (Result (Success), Value, fromJSON, object, toJSON, (.=))
import qualified Data.Aeson as A
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
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
-- The decider primitives (Agentic/Core/Text.lean)
-- ---------------------------------------------------------------------------

-- | @Exec.bareChar@ — the five decoration characters 'bare' drops: @`@, @*@,
-- @_@, a space and @.@ (U+0060, U+002A, U+005F, U+0020, U+002E).
--
-- Isaac's set, from @lastNonEmptyLine@ in incite's @Incite\/Feature.hs@,
-- adopted whole, because models bold and backtick their markers and a decider
-- that misses @**WORK COMPLETE**@ misses the common case. The negative half is
-- pinned by incite's own spec: @?!:;,)]}>\"'#~-+=@ must __not__ be dropped, and
-- none of them is here.
bareChar :: Char -> Bool
bareChar ch = ch == '`' || ch == '*' || ch == '_' || ch == ' ' || ch == '.'
{-# INLINE bareChar #-}

-- | @Exec.bare@ — @s@ with the decoration characters dropped from both ends.
--
-- __A deliberate divergence from incite, and it is a bug fix.__ incite's
-- @tripEnding@ filters for non-blank with a strip but keeps the /unstripped/
-- line, then drops a set containing neither @\\r@ nor @\\t@ — so a CRLF worker
-- whose last line is @WORK COMPLETE\\r@ classifies as a protocol violation and
-- the run dies on a line ending. Here 'answerLines' trims ASCII whitespace
-- /before/ 'bare' runs, so CRLF classifies correctly. Do not \"restore
-- fidelity\" and reintroduce it.
bare :: Text -> Text
bare = T.dropWhileEnd bareChar . T.dropWhile bareChar

-- | @Exec.asciiSpace@ — the four ASCII whitespace characters 'fields' splits
-- on, the same four 'trimAscii' strips, written out so the two implementations
-- cannot drift onto a Unicode-aware predicate.
asciiSpace :: Char -> Bool
asciiSpace = isWhitespaceAscii
{-# INLINE asciiSpace #-}

-- | @Exec.fields@ — the maximal runs of non-ASCII-whitespace in @s@, in order,
-- dropping empties.
--
-- __Not 'wordsOf'__, and this is the single easiest mistake to make in the
-- decider layer: @words@ normalizes and splits on non-alphanumerics, so it
-- would shatter @a\/Foo.hs@ into @[\"a\", \"foo\", \"hs\"]@ and destroy every
-- path. 'fields' lowercases nothing and splits on whitespace alone.
fields :: Text -> [Text]
fields = filter (not . T.null) . T.split asciiSpace

-- | @Exec.diffHeaders@ — the five line prefixes that introduce a path in a
-- diff. __The trailing spaces are significant__: a bare markdown rule @---@ or
-- @+++@ is not a header. Copied exactly from @diffNamesHaskell@ in incite's
-- @Incite\/Review.hs@.
diffHeaders :: [Text]
diffHeaders = ["diff --git ", "+++ ", "--- ", "rename from ", "rename to "]

-- | @Exec.headerPaths@ — the paths a diff /header/ names.
--
-- Case-__sensitive__ and not lowercased: git writes these prefixes exactly, and
-- paths are case-significant. No path surgery at all — no @a\/@\/@b\/@
-- stripping and no @\/dev\/null@ special case, because @*@ crosses @\/@ in
-- 'matchGlob' and @\/dev\/null@ matches no extension glob and is inert.
--
-- __A second deliberate divergence:__ the prefix test runs against the
-- /trimmed/ line (via 'answerLines'), where incite tests the raw one. That
-- makes an indented header — a diff quoted inside a fenced block, which is how
-- a diff normally reaches a prompt — visible where incite's is blind. The
-- direction is loud: more paths found means the expensive lens runs more often,
-- and the false negative is the costly error.
headerPaths :: Text -> [Text]
headerPaths s =
  concatMap fields
    (filter (\l -> any (`T.isPrefixOf` l) diffHeaders) (answerLines s))

-- | @Exec.globGo@ — the glob matcher's worker, over character lists.
--
-- @*@ matches any run __including @\/@__; @?@ matches exactly one character and
-- never the empty string; every other character is literal; the match is
-- case-sensitive and anchored at both ends.
--
-- That @*@ crosses @\/@ is not an oversight, it is the mechanism: it is what
-- makes @*.hs@ match @a\/Foo.hs@ and @b\/src\/Bar.hs@ with no @a\/@-stripping,
-- so one glob replaces incite's untargeted suffix test.
--
-- This denotes the same relation as @matchGlob@ in agent-functor's
-- @Agent\/Grant.hs@, which is written as a linear greedy two-pointer with one
-- backtrack point /because its patterns come from untrusted input/. Ours do not
-- — a decider's needles are program-authored literals, by the type of the
-- field — so the naive form's theoretical blow-up is unreachable and the
-- simpler, provably-terminating spelling wins.
globGo :: [Char] -> [Char] -> Bool
globGo [] xs = null xs
globGo ('*' : ps) [] = globGo ps []
globGo ('*' : ps) (x : xs) = globGo ps (x : xs) || globGo ('*' : ps) xs
globGo ('?' : ps) (_ : xs) = globGo ps xs
globGo ('?' : _) [] = False
globGo (p : ps) (x : xs) = p == x && globGo ps xs
globGo (_ : _) [] = False

-- | @Exec.matchGlob@ — does the glob @pat@ match the whole of @str@?
matchGlob :: Text -> Text -> Bool
matchGlob pat str = globGo (T.unpack pat) (T.unpack str)

-- | @Exec.dlines@ — the one normalization rule, half one: __a line__ is trimmed
-- (by 'answerLines'), then 'bare'd, then ASCII-lowercased.
dlines :: Text -> [Text]
dlines s = map (T.map toLowerAscii . bare) (answerLines s)

-- | @Exec.dneedle@ — …and half two: __a needle__ is ASCII-lowercased and
-- nothing else.
--
-- The asymmetry is deliberate and load-bearing in one direction: a needle is
-- not trimmed and not 'bare'd, so a trailing space in a needle survives, which
-- is what lets @anyLineStartsWith [\"✗ \"]@ reconstruct incite's @isRed@
-- faithfully — it pins @isRed \"✗\" == False@, and a needle-trimming rule would
-- silently widen it. For the two equality deciders a needle with a trailing
-- space simply never matches, which is correct: a 'bare'd line has no trailing
-- space, so the author's stray space is a visible bug rather than a hidden one.
--
-- Case folding is applied on both sides for all three line deciders. Relative
-- to incite this __widens__ @decideFactsResolved@ and @isRed@, which are
-- case-sensitive there; the widening is uniformly in the safe direction, since
-- both return \"refuse \/ it is red\" and folding case can only make a refusal
-- more likely.
dneedle :: Text -> Text
dneedle = T.map toLowerAscii

-- ---------------------------------------------------------------------------
-- The closed decider vocabulary (Dsl.Decider, Agentic/Core/Dsl/Syntax.lean)
-- ---------------------------------------------------------------------------

-- | The closed vocabulary of pure classifications (D7).
--
-- Four, named in the kernel, held identically in Lean and Haskell, and
-- __closed__: a fifth is a language change and is reviewed as one. Each reads
-- the text bound to a name and answers @flag@, asking nothing — so a
-- classification that used to round-trip through an answerer becomes a fact
-- about the text, and a decider's test can never be chosen by a model.
data Decider
  = -- | The last non-empty line is one of the needles.
    LastNonEmptyLineIs
  | -- | Some line is exactly one of the needles.
    ContainsLine
  | -- | Some line begins with one of the needles.
    AnyLineStartsWith
  | -- | Some path named by a diff header matches one of the globs.
    AnyPathMatches
  deriving (Eq, Ord, Show, Enum, Bounded)

-- | @deciderName@ — the keyword that writes the decider.
deciderName :: Decider -> Text
deciderName = \case
  LastNonEmptyLineIs -> "lastNonEmptyLineIs"
  ContainsLine -> "containsLine"
  AnyLineStartsWith -> "anyLineStartsWith"
  AnyPathMatches -> "anyPathMatches"

-- | @deciderOfName@ — …and the keyword parsed back, a retraction of
-- 'deciderName' (@deciderOfName_deciderName@ is the machine-checked statement
-- of it), so an authoring surface's keyword, the checker's diagnosis and the
-- corpus's field are one table.
deciderOfName :: Text -> Maybe Decider
deciderOfName = \case
  "lastNonEmptyLineIs" -> Just LastNonEmptyLineIs
  "containsLine" -> Just ContainsLine
  "anyLineStartsWith" -> Just AnyLineStartsWith
  "anyPathMatches" -> Just AnyPathMatches
  _ -> Nothing

-- | @Decider.run d ws s@ — the classification @d@ makes of the text @s@ against
-- the needles @ws@. The four total algorithms, in full.
--
--   * 'LastNonEmptyLineIs' — @getLast?@ on 'dlines' is literally \"the last
--     non-empty line\", because 'answerLines' has already dropped the blanks.
--     Empty input and whitespace-only input both give 'False', which matches
--     incite's @tripEnding@ reporting a protocol violation on empty.
--   * 'ContainsLine' — exact line equality, the only exact-match member of the
--     family. It has __no incite ancestor__ and is admitted on its own merits:
--     it is what a program wants when the program itself dictated the sentinel
--     (\"end with a line that is exactly @READY@\"), where a prefix test would
--     admit @READY-ISH@.
--   * 'AnyLineStartsWith' — reconstructs both @isRed@ and
--     @decideFactsResolved@ from incite's @Incite\/Feature.hs@; prefix, not
--     equality, any line, not the last.
--   * 'AnyPathMatches' — reconstructs @diffNamesHaskell@ from incite's
--     @Incite\/Review.hs@ in one binding, and is the /only/ decider that covers
--     it, because the test is two-level: a prefix on the line, then a suffix on
--     each token of that line.
runDecider :: Decider -> [Text] -> Text -> Bool
runDecider LastNonEmptyLineIs ws s = case dlines s of
  [] -> False
  ls -> let l = last ls in any (\w -> l == dneedle w) ws
runDecider ContainsLine ws s = any (\l -> any (\w -> l == dneedle w) ws) (dlines s)
runDecider AnyLineStartsWith ws s =
  any (\l -> any (\w -> dneedle w `T.isPrefixOf` l) ws) (dlines s)
runDecider AnyPathMatches gs s =
  any (\p -> any (\g -> matchGlob g p) gs) (headerPaths s)

-- ---------------------------------------------------------------------------
-- The fence a text panel folds into (Dsl.block, Agentic/Core/Text.lean)
-- ---------------------------------------------------------------------------

-- | @Dsl.escapeClose n b@ — @b@ with every occurrence of this fence's own
-- closing tag defanged by one backslash after the @\<@.
--
-- A member's answer is a model's text. If it may contain @\<\/alpha\>@, a
-- member can forge the end of its own block and open a block of its own
-- choosing, and the synthesis that reads the document is steered by a member.
-- So: __do not trust the body.__
--
-- Why /only/ the fence's own closing tag and not all of @\<\/@: it preserves
-- nesting exactly — an inner document's @\<\/a\>@, @\<\/b\>@ pass through an
-- outer @\<outer\>@ fence untouched — and the mangled case, an inner member
-- sharing a name with an enclosing fence, is precisely the ambiguous one, where
-- mangling is the safe resolution. Left to right, non-overlapping, and the
-- replacement cannot contain the needle, so no re-scan question arises; the
-- needle is non-empty whatever @n@ is, which is what keeps 'T.replace' total.
escapeClose :: Text -> Text -> Text
escapeClose n = T.replace ("</" <> n <> ">") ("<\\/" <> n <> ">")

-- | @Dsl.block n b@ — one member's answer, fenced under its own name.
--
-- XML-shaped and newline-delimited, against @## heading@ (a heading marks a
-- start with nothing marking the end, so a reader of the fold cannot tell where
-- a member stopped) and against custom brackets (which buy nothing on collision
-- and lose the one advantage the XML shape has: it is the delimiter every
-- addressee in this system has seen ten thousand times, and this document is
-- read by a /model/).
--
-- __The body is verbatim__ — no trim, no normalization — which is forced,
-- because @.text@ already decodes verbatim and a fold that trimmed would put a
-- second, contradictory rule about text into the language.
block :: Text -> Text -> Text
block n b = "<" <> n <> ">\n" <> escapeClose n b <> "\n</" <> n <> ">\n"

-- | @Dsl.validLabel n@ — may @n@ name a @panelText@ member's block?
--
-- Non-empty, beginning with an ASCII letter, every character ASCII alphanumeric
-- or @-@, @_@, @.@. This is what makes @\<\/name\>@ an unambiguous byte string
-- to search for, and it forbids @\<@, @\>@ and @\/@ inside a tag by
-- construction.
validLabel :: Text -> Bool
validLabel n = case T.uncons n of
  Nothing -> False
  Just (c, _) -> isAlphaAscii c && T.all ok n
  where
    isAlphaAscii ch = (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z')
    ok ch = isAlphanumAscii ch || ch == '-' || ch == '_' || ch == '.'

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

-- | @Conformance.stringOpOf@ — the __whole reply object__ of a
-- @{"string": …}@ request, dispatched off the whole object because the wave-three
-- ops (D2's fence, D7's deciders) carry fields the three original ones did not.
--
-- __The extension is additive__: @{\"op\", \"code\"?, \"text\"}@ still means
-- exactly what it meant, an unknown op falls through to 'stringOp' and answers
-- @{\"error\": \"unknown string op …\"}@, which is a loud failure and not a
-- silent one.
--
-- The four low-level ops (@bare@, @fields@, @headerPaths@, @matchGlob@) exist
-- so that a divergence is /localizable/: a @decide@ mismatch with all four
-- green is a composition bug, and with one of them red is that function's bug.
-- Same reason @norm@ and @words@ are pinned apart from @decode@.
stringOpOf :: Value -> Value
stringOpOf sj = case op of
  "bare" -> wrap (A.String (bare text))
  "fields" -> wrap (toJSON (fields text))
  "headerPaths" -> wrap (toJSON (headerPaths text))
  "matchGlob" -> case str "pattern" of
    Just pat -> wrap (A.Bool (matchGlob pat text))
    Nothing -> err "matchGlob takes a `pattern`"
  "fence" -> case str "name" of
    Just n -> wrap (A.String (block n text))
    Nothing -> err "fence takes a `name`"
  "decide" -> case str "decider" >>= deciderOfName of
    Nothing ->
      err
        "decide takes a decider: lastNonEmptyLineIs, containsLine, \
        \anyLineStartsWith or anyPathMatches"
    Just d -> case needles of
      Nothing -> err "decide takes `needles`, a list of strings"
      Just ws -> wrap (A.Bool (runDecider d ws text))
  _ -> stringOp op (str "code") text
  where
    fld k = case sj of
      A.Object o -> KM.lookup (K.fromText k) o
      _ -> Nothing
    str k = case fld k of
      Just (A.String s) -> Just s
      _ -> Nothing
    op = maybe T.empty id (str "op")
    text = maybe T.empty id (str "text")
    needles = case fromJSON <$> fld "needles" of
      Just (Success ws) -> Just (ws :: [Text])
      _ -> Nothing
    wrap j = object ["result" .= j]
    err msg = object ["error" .= (msg :: Text)]

-- | @Conformance.stringOp op code text@ — the reply object of the three
-- original ops and the two coded ones, unchanged in shape and in meaning.
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
