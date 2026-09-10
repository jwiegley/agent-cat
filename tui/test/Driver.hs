{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Agentic.Tui (TuiConfig (..), runTui)
import System.Environment (getArgs)
import System.Exit (exitWith)
import System.IO (hPutStr, stderr)
import System.Process (CreateProcess (close_fds, new_session), proc, readCreateProcessWithExitCode)

main :: IO ()
main = do
  arguments <- getArgs
  case arguments of
    [] -> putStrLn "tui PTY driver: ready"
    "--spawn-probe" : executable : args -> do
      (code, output, errors) <- readCreateProcessWithExitCode
        (proc executable args) {close_fds = True, new_session = True} "probe stdin"
      putStr output
      hPutStr stderr errors
      exitWith code
    [runner, stateDirectory, workingDirectory] ->
      runTui
        TuiConfig
          { tuiRunnerAlias = "fixture",
            tuiRunner = runner,
            tuiRunnerArgs = [],
            tuiWorkingDir = workingDirectory,
            tuiStateDir = stateDirectory
          }
    _ -> ioError (userError "tui PTY driver takes RUNNER STATE_DIRECTORY WORKING_DIRECTORY")
