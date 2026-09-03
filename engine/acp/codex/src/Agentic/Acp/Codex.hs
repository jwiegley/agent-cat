module Agentic.Acp.Codex (codexAdapter, codexPin) where

import Agentic.Acp (AdapterSpec (..))

codexPin :: FilePath
codexPin = "/nix/store/i0wl19lx66n2093bv9g4g3lsxj16f9ry-codex-acp-0.13.0/bin/codex-acp"

codexAdapter :: AdapterSpec
codexAdapter = AdapterSpec ["codex-acp"] (Just codexPin) False
