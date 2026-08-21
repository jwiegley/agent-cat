{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskellQuotes #-}
{-# LANGUAGE TypeApplications #-}
-- @TypeFamilies@ is not for a family of this module's own — there is none left
-- here — but for the @MonoLocalBinds@ it implies, which is what keeps a
-- 'KnownIx' constraint in an instance head out of
-- @-Wsimplifiable-class-constraints@.
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

-- |
-- Module      : Agentic.WF
-- Description : The @[wf|…|]@ and @[wft|…|]@ prompt quoters, and what a
--               @{hole}@ may name.
--
-- A prompt in this language is prose in a fence with @{name}@ holes in it.
-- This module is that fence, as a quasiquoter, and nothing else: it is not a
-- parser of the language (@connection.md@ D10) — there is no concrete syntax
-- to parse, here or in Lean — and the only production it knows is the hole.
--
-- __The grammar.__ The only metacharacter is @{@.
--
--   * @{name}@, where @name@ is a Haskell variable identifier, is a hole.
--   * @{{@ is a literal @{@.
--   * @}@ is always literal and is never doubled, so a prompt full of JSON
--     braces needs no escaping on the closing side.
--   * A @{@ that is neither of the above is a compile error quoting the
--     fragment. A mistyped hole is the one failure mode that would change a
--     prompt without saying so, and prompts are what the corpus compares.
--
-- __The layout__ is @string-interpolate@'s @[__i|…|]@ rule, which is the rule
-- the frozen prompts were laid out under: CRLF becomes LF, leading and
-- trailing whitespace-only lines are dropped, the longest common
-- leading-whitespace prefix of the remaining non-blank lines is stripped from
-- every line, the lines are joined with @\\n@, and there is __no trailing
-- newline__. A prompt that must end in one is spelled
-- @[wf|…|] '<>' ['Agentic.Builder.lit' "\\n"]@.
--
-- __Every multi-line string in this tree is written at this fence.__ The
-- owner's ruling of 2026-08-21 is total, and it has no fixture exception: a
-- canned diff, a usage line and a refusal a gate greps are all @[wft|…|]@,
-- and the pass that made them so proved each one byte for byte against the
-- literal it replaced. Three consequences an author meets. A text that carries
-- __no__ newline has exactly one spelling here — one line of source, however
-- wide it comes out — because the fence joins its lines with @\\n@ and cannot
-- be talked out of it. A __trailing__ newline is @[wft|…|] '<>' "\\n"@, for
-- the same reason. And whitespace at the very __edge__ of the text — a leading
-- space, a blank first or last line — cannot ride the fence edge, because
-- 'layout' drops blank edge lines and strips the common margin; splice it with
-- a hole or with @'<>'@.
--
-- __Three things, and only three, leave a gap literal standing__, and each
-- names itself in a comment where it stands. A text that is a @Symbol@ in a
-- /type/ cannot be a fence at all: the quoters are expression quoters and
-- their @quoteType@ says so, in those words. A module at or below this one in
-- the import graph — "Agentic.Builder", which this module imports, and
-- "Agentic.Raw" and "Agentic.Text" beneath it — cannot import the quoter
-- without a module cycle. And this module itself cannot quote with the quoter
-- it defines: the Template Haskell stage restriction. Nineteen literals in
-- this tree are of one of the three kinds; every other multi-line string is a
-- fence.
--
-- __Chunking is normative, and this quoter is where the rule lives.__ Two
-- halves. (1) __Adjacent literals are deliberately not fused__, so a @define@
-- spliced into a prompt contributes /its own chunk/: @example-000@'s drafting
-- prompt is three chunks and not one. That half is Lean's, enforced by
-- construction: @Prompt.expr@ (@Agentic\/Core\/Dsl\/Check.lean:159@) emits the
-- chunks left-associated, so a prompt chunked the way an author would write the
-- same string in Lean elaborates to the very same @Expr@ — which is what makes
-- the flagship's transcript agreements computations rather than appeals to
-- @String.append_assoc@. (2) __An empty literal is dropped__, because it says
-- nothing. That half is this quoter's own: Lean carried a @Prompt.normalize@
-- stating it, no Lean code ever applied it, and obr @acat-o5o@ retired the
-- statement in favour of the implementation — @normalize@ below. This quoter
-- reproduces both: the contiguous literal run between two holes is one chunk, a
-- spliced 'Text' is another beside it, and an empty literal never reaches the
-- term.
--
-- __Two quoters, one rule.__ A prompt is 'Words' and a @define@ is a 'Text',
-- and both are written at this fence: 'wf' yields the first, 'wft' the second.
-- They are two applications of one @promptQuoter@ over one @parseFence@ — same
-- layout, same hole scan, same @normalize@ — differing only in what a fragment
-- is staged as. That is the whole cost of having two, and it is why a block
-- moved from @wfText [wf|…|]@ to @[wft|…|]@ cannot move a byte.
--
-- __What a hole may name__ is the 'Says' class: a live binding ('V'), which
-- splices as an @interp@ chunk under the name that binding /prints/, or a
-- @define@ — a plain 'Text' or a @Words@ value — which splices as the literal
-- chunks it is. That is what makes @{spec}@ and @{patch}@ look identical in
-- the source and mean different things: the /type/ of what the name resolves
-- to decides, and nothing in the fence has to be told which it is.
--
-- __The printed name comes from the handle, never from the source.__ A hole
-- names a Haskell variable, and a Haskell variable's spelling is not readable
-- without Template Haskell — which the surface no longer uses. So @{guide}@
-- resolves to the /value/ @guide@, and what the chunk prints is the name that
-- value carries ('vName'), which is the same 'Text' the binder printed. Binder
-- and hole therefore agree by construction rather than by convention, and the
-- one class of bug the labelled surface allowed has no spelling here.
--
-- __Staging.__ A hole emits @'varE' ('mkName' n)@, an /unqualified/ name that
-- resolves in the ordinary lexical scope at the splice site — lambda binders,
-- @where@ bindings and top-level bindings alike. That is what lets @{patch}@
-- mean the carrier inside a revision and the settled binder inside the arm,
-- two different values with the same spelling, correct in both places, and it
-- is what makes a typo a plain @Variable not in scope: guiide@ rather than a
-- type-level puzzle. @lit@ and @says@ are emitted as statically resolved
-- names, so an author who shadows @lit@ locally cannot thereby break a prompt,
-- and so is the 'saysText' a @[wft|…|]@ hole goes through.
module Agentic.WF
  ( -- * The quoters
    wf,
    wft,

    -- * What a hole may name
    --
    -- | The handle itself is "Agentic.Builder"'s, and is re-exported here so
    -- that a prompt and the block it is written in need one import between
    -- them.
    V (..),
    Says (..),
    saysText,
    Scopeless,

    -- * Finding a handle's binding
    KnownIx,
  )
where

import Agentic.Builder
  ( KnownIx,
    Piece,
    Scope,
    Spliceable,
    V (..),
    Words,
    hole,
    lit,
    wordsClosed,
  )
import Data.Char (isAlphaNum, isSpace)
import Data.Kind (Constraint, Type)
import Data.List (dropWhileEnd)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import GHC.TypeLits (ErrorMessage (Text), TypeError)
import Language.Haskell.TH (Exp (ListE), ExpQ, Q, litE, mkName, stringL, varE)
import Language.Haskell.TH.Quote (QuasiQuoter (..))

-- ---------------------------------------------------------------------------
-- What a hole may name
-- ---------------------------------------------------------------------------

-- | Anything a @{…}@ may name.
--
-- The three instances are the three things a hole may resolve to, and no
-- more: a name in scope, a @define@ that is a string, and a
-- @define@ that is itself a fence.
class Says a (s :: Scope) where
  -- | The chunks this value contributes, in place.
  says :: a -> Words s

-- | A live binding: one @interp@ chunk, under the name the binding prints. The
-- kind must have a text of its own, so a flag hole is refused here exactly as
-- @usePrompt@ refuses it.
instance
  (KnownIx h s, Spliceable c) =>
  Says (V h c) s
  where
  says v = [hole @h @s @c v]

-- | A @define@: one literal chunk, never fused with the literals beside it.
instance Says Text s where
  says t = [lit t]

-- | A @define@ written as a fence, or one that holes an earlier define: its
-- own chunks, spliced in place.
instance s ~ s' => Says [Piece s'] s where
  says = id

-- | What a hole says, as the 'Text' it is: 'says' at the empty scope, read back
-- by 'Agentic.Builder.wordsClosed'.
--
-- This is the /same/ path a @define@ hole takes in a @[wf|…|]@ prompt and not a
-- second one, which is what makes @{name}@ mean one thing in both fences: a
-- 'Text' says itself, a @define@ written as a fence says the chunks it is, and
-- 'T.concat' of those chunks is what @wfText [wf|…|]@ always computed.
--
-- The @""@ is unreachable: at the empty scope no piece can be an @interp@,
-- because a hole naming a binding needs a live handle and there are none. It is
-- written rather than an @error@ so that a define is a value and not a bottom.
saysText :: forall a. (Scopeless a, Says a '[]) => a -> Text
saysText = fromMaybe T.empty . wordsClosed . says @a @'[]

-- | The constraint a @[wft|…|]@ hole stands under: whatever it names must be a
-- @define@, because a 'Text' has no scope for a binding to be live in.
--
-- 'Says' refuses a handle here anyway — @KnownIx h '[]@ is exactly the \"this
-- binding is not live here\" refusal, at the empty scope — but it refuses it as
-- a scope walk that ran out, which is not what the author did wrong. This one
-- fires first, at the hole, and says what to do instead; the 'KnownIx' refusal
-- stays behind it as the backstop it always was.
--
-- It is a /compile/ error, so it cannot be a case in a suite that has to
-- compile; the wording is pinned by being written here and nowhere else.
type family Scopeless (a :: Type) :: Constraint where
  Scopeless (V h c) =
    TypeError
      -- Not a [wft|...|] twice over: a Symbol in a type, and the text itself carries |], which is what ends a fence.
      ( 'Text "a hole in a [wft|…|] prompt names a define — a value in Haskell \
              \scope — and never a binding, because the text it yields has no \
              \scope for one to be live in. Write the prompt as [wf|…|] in the \
              \block where that handle is live, and splice this text into it."
      )
  Scopeless _ = ()

-- ---------------------------------------------------------------------------
-- The quoters
-- ---------------------------------------------------------------------------

-- | A prompt: prose, with @{name}@ holes.
--
-- > [wf|
-- >     {guide}
-- >     Is this patch correct?
-- >     {patch}
-- >     {verdictSpec}|]
--
-- is, after layout and the hole scan,
--
-- > concat [ says guide
-- >        , [lit (T.pack "\nIs this patch correct?\n")]
-- >        , says patch
-- >        , [lit (T.pack "\n")]
-- >        , says verdictSpec ]
--
-- — five chunks where @guide@ and @patch@ are bindings and @verdictSpec@ is a
-- @define@, which is @example-000@'s first panel member, chunk for chunk.
wf :: QuasiQuoter
wf = promptQuoter "[wf|…|]" chunks (\es -> [|concat $(pure (ListE es))|])
  where
    chunks (FLit t) = [|[lit (T.pack $(litE (stringL t)))]|]
    chunks (FHole n) = [|says $(varE (mkName n))|]

-- | A prompt's __text__: the same fence, the same layout, the same holes, read
-- straight off as the 'Text' they say.
--
-- > correctnessLens :: Text
-- > correctnessLens = [wft|
-- >     Correctness lens. Read the change below and report only defects that
-- >     are wrong on inputs this code will actually see.|]
--
-- __Why there are two of these.__ A @define@ is a 'Text', and a define worth
-- reading at the width it is sent at is written at this fence — so until 'wft'
-- there was one way to write one, and it was to write the prompt and then
-- convert it: @wfText [wf|…|]@, in front of every define in every authoring
-- module, with a copy of the conversion in each of them. The owner's ruling on
-- that was \"I don't like repeating things that I don't have to repeat\", and
-- the conversion is now written once, here, and named in the brackets.
--
-- __It is the same fence, and that is load-bearing.__ 'wft' and 'wf' are two
-- applications of one @promptQuoter@ over one @parseFence@: one layout rule,
-- one hole scan, one @normalize@. They differ in what a fragment is staged as
-- and in nothing else — 'wf' stages a literal as a @lit@ chunk and a hole as its
-- 'says' chunks; 'wft' stages the same literal as the 'Text' it is and the same
-- hole as the text that hole 'saysText'. So @[wft|…|]@ is 'T.concat' of exactly
-- the texts @wfText [wf|…|]@ concatenated, in order, and a block moved from one
-- spelling to the other cannot move a byte. A copied layout function would have
-- made that a claim to be tested; a shared one makes it a fact about the two
-- expressions.
--
-- __A hole here names a define.__ There is no scope around a 'Text', so there
-- is no binding to be live in one, and every @{name}@ resolves through
-- 'saysText' — the define half of 'Says', unchanged. A hole naming a handle is
-- refused at the hole by 'Scopeless', in those words.
wft :: QuasiQuoter
wft = promptQuoter "[wft|…|]" saying (\es -> [|T.concat $(pure (ListE es))|])
  where
    saying (FLit t) = [|T.pack $(litE (stringL t))|]
    saying (FHole n) = [|saysText $(varE (mkName n))|]

-- | A fence, given a name to refuse under, what to stage each fragment as, and
-- how to join the staged list.
--
-- Everything both quoters have in common is here or in @parseFence@, which is
-- everything except those last two arguments. A quoter is an expression and
-- three refusals, and the refusals are one sentence written once.
promptQuoter :: String -> (Frag -> ExpQ) -> ([Exp] -> ExpQ) -> QuasiQuoter
promptQuoter name frag join =
  QuasiQuoter
    { quoteExp = \raw ->
        either fail pure (parseFence name raw) >>= mapM frag >>= join,
      quotePat = notAnExpression,
      quoteType = notAnExpression,
      quoteDec = notAnExpression
    }
  where
    notAnExpression :: String -> Q a
    notAnExpression =
      const (fail (name ++ " is a prompt, and a prompt is an expression"))

-- | One piece of the quoted text, before staging.
data Frag = FLit String | FHole String
  deriving (Eq, Show)

-- ---------------------------------------------------------------------------
-- The rule
-- ---------------------------------------------------------------------------

-- | Layout, then holes, then @normalize@ — the rule itself, which both quoters
-- run and neither owns. The name is the fence's own spelling, and is used only
-- to say which fence a malformed hole was found in.
parseFence :: String -> String -> Either String [Frag]
parseFence name = fmap normalize . holes name . layout

-- | @[__i|…|]@'s rule: CRLF is LF, surrounding blank lines go, the common
-- leading whitespace of the remaining lines goes, line breaks stay, and there
-- is no trailing newline.
layout :: String -> String
layout =
  joinLines
    . dedent
    . dropWhileEnd blank
    . dropWhile blank
    . lines
    . crlf
  where
    crlf ('\r' : '\n' : r) = '\n' : crlf r
    crlf (c : r) = c : crlf r
    crlf [] = []

    blank = all isSpace

    joinLines [] = ""
    joinLines xs = foldr1 (\a b -> a ++ '\n' : b) xs

    dedent ls = map (drop (length pre)) ls
      where
        pre = case map (takeWhile isSpace) (filter (not . blank) ls) of
          [] -> ""
          (p : ps) -> foldl common p ps
        common a b = map fst (takeWhile (uncurry (==)) (zip a b))

-- | The only syntax: @{name}@ is a hole, @{{@ is a literal brace, @}@ is
-- always literal. A @{@ that is neither is an error naming the fragment.
holes :: String -> String -> Either String [Frag]
holes name = go ""
  where
    go acc [] = Right [FLit (reverse acc)]
    go acc ('{' : '{' : r) = go ('{' : acc) r
    go acc ('{' : r) =
      case span identChar r of
        (nm@(c0 : _), '}' : r')
          | startChar c0 ->
              (\rest -> FLit (reverse acc) : FHole nm : rest) <$> go "" r'
        _ ->
          Left
            ( name
                -- Not a [wft|...|]: this module defines the quoter, and cannot quote with itself.
                ++ ": `{` starts a hole, which is `{name}` for a name in \
                   \scope; write `{{` for a literal brace. At: `"
                ++ take 24 ('{' : r)
                ++ "`"
            )
    go acc (c : r) = go (c : acc) r

    startChar c = c == '_' || (c >= 'a' && c <= 'z')
    identChar c = isAlphaNum c || c == '_' || c == '\''

-- | An empty literal says nothing and is dropped. __The authoring surface owns
-- this rule and nothing downstream may repeat it__: @Agentic.Raw.Prompt@ is a
-- codec type and must round-trip a corpus prompt verbatim, adjacent @Lit@s
-- included. Lean stated the rule as @Dsl.Prompt.normalize@ and never applied it;
-- obr @acat-o5o@ deleted the statement and left the implementation here, where
-- it runs.
--
-- Adjacent chunks are deliberately __not__ fused — @Prompt.expr@
-- (@Agentic\/Core\/Dsl\/Check.lean:159@) is a left-associated @++@, and the
-- flagship's transcript agreements are computations rather than appeals to
-- @String.append_assoc@.
normalize :: [Frag] -> [Frag]
normalize = filter (/= FLit "")
