module Main (main) where

import Data.Text (Text)
import Harden (harden, hello)
import Surface

prompts :: Raw -> [(Text, Prompt)]
prompts = goB
  where
    goB RawEmpty = []
    goB (RawBind _ _ src rest) = goS src ++ goB rest
    goB (RawAct a rest) = [ofAsk a] ++ goB rest
    goB (RawIfFlag _ y n) = goB y ++ goB n
    goB (RawCaseResult _ _ st un) = goB st ++ goB un
    goB (RawKnownHere _ rest) = goB rest
    goS (SrcRhs r) = goR r
    goS (SrcRevising _ _ _ _ _ rev am) = goR rev ++ goR am
    goR (RhsAsk a) = [ofAsk a]
    goR (RhsPanel ms) = map ofAsk ms
    ofAsk a = (rAddr a, rPrompt a)

main :: IO ()
main = do
  mapM_ pr (prompts harden)
  putStrLn "== hello =="
  mapM_ pr (prompts hello)
  where
    pr (addr, p) = do
      putStrLn ("=== " ++ show addr)
      mapM_ (putStrLn . ("   " ++) . show) p
