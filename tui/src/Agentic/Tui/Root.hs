-- | The shared private-directory contract with terminal-frontend diagnostics.
module Agentic.Tui.Root
  ( module Root,
    withPrivateRoot,
  )
where

import Agentic.Runtime as Root
  ( PrivateRoot,
    privateRootPath,
    privateRootIdentity,
    privatePathComponents,
    withPrivateDirectoryAt,
    assertPrivateRoot,
    ensurePrivateDirectoryAt,
    createPrivateDirectoryAt,
    openPrivateFileAt,
    writePrivateExclusiveAt,
    writePrivateAtomicAt,
    movePrivateAt,
    removePrivateFileAt,
    removePrivateDirectoryAt,
  )
import qualified Agentic.Runtime as Runtime

withPrivateRoot :: FilePath -> (PrivateRoot -> IO a) -> IO a
withPrivateRoot = Runtime.withPrivateRoot "TUI state root"
