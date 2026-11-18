-- | The decisions engine's test suite: the pure wire checks, then the engine
-- against an in-process loopback stub, then law L13. It contacts no endpoint
-- outside this process.
module Main (main) where

import EngineTests (engineTests)
import System.Exit (exitFailure)
import WireTests (wireTests)

main :: IO ()
main = do
  wire <- wireTests
  engine <- engineTests
  let failures = wire <> engine
  mapM_ (putStrLn . ("engine-decisions-test: FAIL " <>)) failures
  if null failures
    then putStrLn "engine-decisions-test: every check passed"
    else exitFailure
