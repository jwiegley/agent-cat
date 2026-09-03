module Agentic.Acp.Claude (claudeAdapter, claudePin) where

import Agentic.Acp (AdapterSpec (..))

claudePin :: FilePath
claudePin =
  "/nix/store/vhmm2z9psm5vcwgl8p6sa4c99y4chn0m-claude-agent-acp-0.64.0/bin/claude-agent-acp"

claudeAdapter :: AdapterSpec
claudeAdapter = AdapterSpec ["claude-agent-acp"] (Just claudePin) False
