{-# LANGUAGE OverloadedStrings #-}

-- | The ACP adapter reports each permission request that it answers during a
-- turn to the attempt's update sink, and reports no other request.
--
-- The stub sends four requests. During the effect turn it sends one under a
-- foreign session and one under the prompt's session. After that turn it sends
-- a delayed request under the same session, which the adapter answers while it
-- opens the next session. During the text turn it sends one more under the
-- prompt's session. Only the two requests that match the active prompt reach
-- the sink.
--
-- Usage: runghc PermissionReport.hs WORKING-DIRECTORY
module Main (main) where

import Agentic.Acp (AcpConfig (..), adapterConfig, engineOfAcp, stubAdapter, withAcp)
import Agentic.Engine
import Control.Monad (unless)
import Data.IORef (modifyIORef', newIORef, readIORef)
import System.Environment (getArgs)
import System.Exit (die)

main :: IO ()
main = do
  arguments <- getArgs
  directory <- case arguments of
    [path] -> pure path
    _ -> die "usage: PermissionReport.hs WORKING-DIRECTORY"
  reports <- newIORef []
  let config =
        (adapterConfig stubAdapter ["--foreign-session-events", "--delayed-same-session-permission", "--write-on-ask"])
          { acpCwd = directory,
            acpTurnTimeoutMs = 60000
          }
      context =
        EngineContext
          { runEngineAttempt = \_ _ action -> action $ \update -> case update of
              EnginePermission report -> modifyIORef' reports (<> [report])
              _ -> pure ()
          }
      request target intent kind prompt = EngineRequest target Nothing Nothing 0 intent kind prompt True
  withAcp config $ \acp -> do
    let engine = engineOfAcp config acp
    effect <- startEngine engine context (request "tool apply" Effect ReceiptAnswer "Apply: +hardened line")
    _ <- runEngineTurn effect ""
    consultation <- startEngine engine context (request "model author" Consult TextAnswer "Draft a hardened parser.")
    _ <- runEngineTurn consultation ""
    pure ()
  seen <- readIORef reports
  let expected =
        [ EnginePermissionReport "the ack question put to tool apply" "apply the patch" (EnginePermissionGranted "allow"),
          EnginePermissionReport "the text question put to model author" "edit parse.c while answering" EnginePermissionRefused
        ]
  unless (seen == expected) $
    die ("ACP permission reports were " <> show seen <> ", wanted " <> show expected)
