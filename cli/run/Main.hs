-- | @agentic-run@ — list, plan, price and run the worked examples.
--
-- Four verbs over the programs of "Example.Harden", which are the walked
-- examples of @agent-cat\/example@ rebuilt in "Agentic.Workflow" — the
-- authoring surface, whose 'Agentic.Builder.Program' the CLI reads.
--
-- __The CLI itself is "Agentic.Cli"__, parameterized by the registry it serves.
-- This executable is that function applied to one registry, and
-- @agent-workflows@' @wf@ — the owner's separate, private toolbox repository —
-- is the same function applied to the other. The
-- argument for the split is in "Agentic.Cli"'s haddock, and in one line it is
-- this: @ci\/examples.sh@ pins every registered program's numbers __by
-- equality__, which is right for eight fixtures that are evidence about the
-- language and wrong for a toolbox whose rubrics are edited on a Tuesday. So
-- the registry is a value and the parser is shared; the two tables are held to
-- two gates.
--
-- Everything an operator can type, every refusal, every exit code and the whole
-- usage message live in "Agentic.Cli". __The move was not behaviour-neutral__:
-- it added the @list@ verb — this header said "three verbs" before it — and the
-- usage message grew a line. What the gates hold unchanged is the three verbs
-- that predate the move: @ci\/examples.sh@, @ci\/acp.sh@ and @ci\/deck.sh@ drive
-- @plan@, @cost@ and @run@ from outside and would have said so had any of them
-- shifted. No gate types @list@, so nothing but its own output covers it.
module Main (main) where

import Agentic.Cli (cliMain)
import Example.Registry (examplesRegistry)

main :: IO ()
main = cliMain examplesRegistry
