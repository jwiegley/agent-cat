
-- | Explicit terminal frontend for an agent-cat runner process.
module Agentic.Tui
  ( TuiConfig (..),
    runTui,
    runServiceTui,
  )
where

import Agentic.Tui.App (runApp, runServiceApp, withTerminationHandlers)
import qualified Agentic.Manager.Client as Client
import qualified Agentic.Tui.Service as Service
import qualified Agentic.Tui.ServiceLane as Lane
import Control.Exception (bracket)
import Agentic.Tui.Root (withPrivateRoot)
import Agentic.Tui.Types (TuiConfig (..))
import Control.Monad (unless)
import qualified Data.Text as T
import System.FilePath (isAbsolute)
import System.Exit (ExitCode (ExitFailure), exitWith)
import System.IO (hIsTerminalDevice, hPutStrLn, stderr, stdin, stdout)

runTui :: TuiConfig -> IO ()
runTui config = withTerminationHandlers $ do
  let runnerAlias = tuiRunnerAlias config
  unless (not (T.null runnerAlias) && T.length runnerAlias <= 256 && not (T.any (`elem` ['\NUL', '\n', '\r']) runnerAlias)) $
    ioError (userError "TUI runner alias is empty or invalid")
  unless (all isAbsolute [tuiRunner config, tuiWorkingDir config, tuiStateDir config]) $
    ioError (userError "TUI runner, working directory, and state directory must be absolute")
  inputTerminal <- hIsTerminalDevice stdin
  outputTerminal <- hIsTerminalDevice stdout
  unless (inputTerminal && outputTerminal) $
    ioError (userError "--tui requires terminal input and output; use list, plan, run, or machine mode for pipes")
  withPrivateRoot (tuiStateDir config) (runApp config)

-- | A terminal client session using only the explicitly supplied client profile.
-- A declared connection failure prints its one fixed line from
-- 'Lane.startupFailureText' and exits with status 1 before the terminal
-- interface starts. Service mode starts no local machine or helper process.
runServiceTui :: FilePath -> IO ()
runServiceTui profile = withTerminationHandlers $ do
  inputTerminal <- hIsTerminalDevice stdin
  outputTerminal <- hIsTerminalDevice stdout
  unless (inputTerminal && outputTerminal) $
    ioError (userError "--tui --service requires terminal input and output")
  bracket
    (Client.connectClientProfile profile >>= either startupFailure pure)
    Client.closeClient
    (\client -> either startupFailure (runServiceApp client) (Service.clientIdentity client))
  where
    startupFailure :: Client.ClientFailure -> IO a
    startupFailure failure = do
      hPutStrLn stderr (T.unpack (Lane.startupFailureText failure))
      exitWith (ExitFailure 1)
