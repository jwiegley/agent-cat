module Agentic.Acp.Droid (droidAdapter) where

import Agentic.Acp (AdapterSpec (..))

-- | Factory Droid's native ACP mode. Following adapter arguments remain literal.
droidAdapter :: AdapterSpec
droidAdapter = AdapterSpec ["droid", "exec", "--output-format", "acp"] Nothing True
