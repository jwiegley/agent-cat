
-- | Explicit terminal frontend for an agent-cat runner process.
module Agentic.Tui
  ( TuiConfig (..),
    runTui,
    runServiceTui,
  )
where

import Agentic.Tui.App (runApp, runServiceApp, withTerminationHandlers)
import qualified Agentic.Manager.Client as Client
import Control.Exception (bracket)
import Agentic.Tui.Root (withPrivateRoot)
import Agentic.Tui.Types (TuiConfig (..))
import Control.Monad (unless)
import qualified Data.Text as T
import System.FilePath (isAbsolute)
import System.IO (hIsTerminalDevice, stdin, stdout)

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
runServiceTui :: FilePath -> IO ()
runServiceTui profile = withTerminationHandlers $ do
  inputTerminal <- hIsTerminalDevice stdin
  outputTerminal <- hIsTerminalDevice stdout
  unless (inputTerminal && outputTerminal) $
    ioError (userError "--tui --service requires terminal input and output")
  bracket
    (Client.connectClientProfile profile >>= either (ioError . userError . show) pure)
    Client.closeClient
    runServiceApp
