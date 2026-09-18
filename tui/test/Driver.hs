{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Agentic.Runtime (closeGroupPipes, createProcessGroup, groupErrors, groupInput, groupOutput, terminateProcessGroup, waitProcessGroup)
import Agentic.Tui (TuiConfig (..), runTui)
import Control.Concurrent (myThreadId, throwTo)
import Control.Concurrent.Async (concurrently)
import Control.Exception (AsyncException (UserInterrupt), bracket, finally)
import Control.Monad (void)
import qualified Data.ByteString as BS
import System.Environment (getArgs)
import System.Exit (exitWith)
import System.IO (hClose, hPutStr, stderr)
import System.Posix.Signals (Handler (CatchOnce), installHandler, sigTERM)
import System.Process (CreateProcess (std_in, std_out, std_err), StdStream (CreatePipe), proc)

main :: IO ()
main = do
  arguments <- getArgs
  case arguments of
    [] -> putStrLn "tui PTY driver: ready"
    "--spawn-probe" : executable : args -> do
      owner <- myThreadId
      (code, output, errors) <- bracket
        (installHandler sigTERM (CatchOnce (throwTo owner UserInterrupt)) Nothing)
        (\previous -> void (installHandler sigTERM previous Nothing)) $ \_ ->
          bracket
            (createProcessGroup (proc executable args) {std_in = CreatePipe, std_out = CreatePipe, std_err = CreatePipe})
            (\group -> terminateProcessGroup 2000000 group `finally` closeGroupPipes group) $ \group ->
              case (groupInput group, groupOutput group, groupErrors group) of
                (Just input, Just output, Just errors) -> do
                  hPutStr input "probe stdin"
                  hClose input
                  (out, err) <- concurrently (BS.hGetContents output) (BS.hGetContents errors)
                  code <- waitProcessGroup group
                  pure (code, out, err)
                _ -> ioError (userError "spawn probe did not create pipes")
      BS.putStr output
      BS.hPutStr stderr errors
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
