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
-- Description : The @[wf|…|]@ prompt quoter, and what a @{hole}@ may name.
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
-- __Chunking is normative.__ Lean's @Prompt.normalize@
-- (@Agentic\/Core\/Dsl\/Syntax.lean:152@) drops empty literals and
-- __deliberately does not fuse adjacent literals__, so a @define@ spliced into
-- a prompt contributes /its own chunk/: @example-000@'s drafting prompt is
-- three chunks and not one. This quoter reproduces exactly that — the
-- contiguous literal run between two holes is one chunk, a spliced 'Text' is
-- another beside it, and an empty literal never reaches the term.
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
-- names, so an author who shadows @lit@ locally cannot thereby break a prompt.
module Agentic.WF
  ( -- * The quoter
    wf,

    -- * What a hole may name
    --
    -- | The handle itself is "Agentic.Builder"'s, and is re-exported here so
    -- that a prompt and the block it is written in need one import between
    -- them.
    V (..),
    Says (..),

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
  )
import Data.Char (isAlphaNum, isSpace)
import Data.List (dropWhileEnd)
import Data.Text (Text)
import qualified Data.Text as T
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

-- ---------------------------------------------------------------------------
-- The quoter
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
wf =
  QuasiQuoter
    { quoteExp = wfExp,
      quotePat = const (fail "[wf|…|] is a prompt, and a prompt is an expression"),
      quoteType = const (fail "[wf|…|] is a prompt, and a prompt is an expression"),
      quoteDec = const (fail "[wf|…|] is a prompt, and a prompt is an expression")
    }

-- | One piece of the quoted text, before staging.
data Frag = FLit String | FHole String
  deriving (Eq, Show)

wfExp :: String -> Q Exp
wfExp raw = do
  frags <- either fail pure (parseWf raw)
  pieces <- mapM piece frags
  [|concat $(pure (ListE pieces))|]
  where
    piece :: Frag -> ExpQ
    piece (FLit t) = [|[lit (T.pack $(litE (stringL t)))]|]
    piece (FHole n) = [|says $(varE (mkName n))|]

-- ---------------------------------------------------------------------------
-- The rule
-- ---------------------------------------------------------------------------

-- | Layout, then holes, then @normalize@.
parseWf :: String -> Either String [Frag]
parseWf = fmap normalize . holes . layout

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
holes :: String -> Either String [Frag]
holes = go ""
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
            ( "[wf|…|]: `{` starts a hole, which is `{name}` for a name in \
              \scope; write `{{` for a literal brace. At: `"
                ++ take 24 ('{' : r)
                ++ "`"
            )
    go acc (c : r) = go (c : acc) r

    startChar c = c == '_' || (c >= 'a' && c <= 'z')
    identChar c = isAlphaNum c || c == '_' || c == '\''

-- | Lean's @Prompt.normalize@: an empty literal says nothing and is dropped.
-- Adjacent chunks are deliberately __not__ fused — @Prompt.expr@ is a
-- left-associated @++@, and the flagship's transcript agreements are
-- computations rather than appeals to @String.append_assoc@.
normalize :: [Frag] -> [Frag]
normalize = filter (/= FLit "")
