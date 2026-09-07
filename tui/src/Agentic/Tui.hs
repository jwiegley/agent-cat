
-- | Explicit terminal frontend for an agent-cat runner process.
module Agentic.Tui
  ( TuiConfig (..),
    runTui,
  )
where

import Agentic.Tui.App (runApp, withTerminationHandlers)
import Agentic.Tui.Client (loadInitialData)
import Agentic.Tui.Root (withPrivateRoot)
import Agentic.Tui.Types (TuiConfig (..))
import Control.Monad (unless)
import qualified Data.Text as T
import System.FilePath (isAbsolute)
import System.IO (hIsTerminalDevice, stdin, stdout)

runTui :: TuiConfig -> IO ()
runTui config = withTerminationHandlers $ do
  let runnerId = tuiRunnerId config
  unless (not (T.null runnerId) && T.length runnerId <= 256 && not (T.any (`elem` ['\NUL', '\n', '\r']) runnerId)) $
    ioError (userError "TUI runner id is empty or invalid")
  unless (all isAbsolute [tuiRunner config, tuiWorkingDir config, tuiStateDir config]) $
    ioError (userError "TUI runner, working directory, and state directory must be absolute")
  inputTerminal <- hIsTerminalDevice stdin
  outputTerminal <- hIsTerminalDevice stdout
  unless (inputTerminal && outputTerminal) $
    ioError (userError "--tui requires terminal input and output; use list, plan, run, or machine mode for pipes")
  withPrivateRoot (tuiStateDir config) $ \root -> do
    initial <- loadInitialData config root >>= either (ioError . userError . T.unpack) pure
    runApp config root initial
