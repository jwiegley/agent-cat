{-# LANGUAGE TemplateHaskellQuotes #-}

-- | The @[wf|…|]@ prompt quoter: @[__i|…|]@'s layout rule, @{name}@ holes,
-- and Lean's @Prompt.normalize@ (empty literals dropped, adjacent chunks never
-- fused).
module Quote (wf) where

import Data.Char (isAlphaNum, isSpace)
import qualified Data.Text as T
import Language.Haskell.TH
import Language.Haskell.TH.Quote (QuasiQuoter (..))
import Surface (lit, says)

wf :: QuasiQuoter
wf =
  QuasiQuoter
    { quoteExp = wfExp,
      quotePat = const (fail "[wf|…|] is an expression"),
      quoteType = const (fail "[wf|…|] is an expression"),
      quoteDec = const (fail "[wf|…|] is an expression")
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
    piece (FLit t) = [|[lit (T.pack $(litE (stringL t)))]|]
    piece (FHole n) = [|says $(varE (mkName n))|]

-- ---------------------------------------------------------------------------
-- The rule
-- ---------------------------------------------------------------------------

-- | Layout, then holes, then normalize.
parseWf :: String -> Either String [Frag]
parseWf = fmap normalize . holes . layout

-- | @[__i|…|]@'s rule: CRLF is LF, surrounding blank lines go, the common
-- leading whitespace of the remaining lines goes, line breaks stay, and there
-- is no trailing newline.
layout :: String -> String
layout =
  join'
    . dedent
    . dropWhileEnd' blank
    . dropWhile blank
    . lines
    . crlf
  where
    crlf ('\r' : '\n' : r) = '\n' : crlf r
    crlf (c : r) = c : crlf r
    crlf [] = []
    blank = all isSpace
    join' [] = ""
    join' xs = foldr1 (\a b -> a ++ '\n' : b) xs
    dropWhileEnd' p = reverse . dropWhile p . reverse

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
        (nm, '}' : r')
          | not (null nm),
            startChar (head nm) ->
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
-- Adjacent chunks are deliberately not fused.
normalize :: [Frag] -> [Frag]
normalize = filter (/= FLit "")
