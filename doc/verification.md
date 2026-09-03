# Verification record

This record covers the modular working tree based on
`4d11cf37da7867cd36305d8d97e52c751f4302cb`, verified on 2026-09-03. No command
used a live model, network-backed adapter, production service, or paid account.
`engine/acp/ci/route-live.sh` was deliberately not run.

## Frozen artifacts

- Corpus: 193 files under `bisim/corpus/`, aggregate SHA-256
  `ddc3c072660c1bc09e2ef06e850ae314512dbafff06734ad23ef1d4a47be14e5`.
- Manual workflow: `doc/workflows/agent-cat-manual.js`, SHA-256
  `10f66aa25cf654376ce436c1b1e0c354b2f0697962f45668e7ab8ce19e2c2654`.
- Retained workflow smoke run: `agent-cat-manual-mtc8ywaw-oqxenx`; all fourteen
  agents completed, every review finding was applied, and validation passed.

## Lean model and bisimulation

```sh
nix flake check path:./model --no-build
nix develop path:./model -c bash -c 'cd model && lake build'
nix develop path:./model -c bash -c 'cd bisim && lake build && lake exe corpus-gen'
./bisim/ci/tier0.sh
N=500 SEED=1 ./bisim/ci/tier1.sh
```

Results:

- Model: 762 jobs, including `Agentic.Core.DslFlagship` and `Pollution`, passed.
- Bisim Lean package: 1503 jobs; oracle and corpus generator passed.
- Corpus regeneration: 193 entries re-observed, all byte-identical.
- Tier 0: 193/193 passed; 45 expected codec-only `other` refusals.
- Rebuilt Tier 1: 30/30 passed.
- Live differential: P1R 1/1, P1 500/500, P2 12000/12000, P3 419/500 with
  81 expected `other` skips; zero failures.

## Haskell workspace and interfaces

```sh
nix flake check --no-build
nix develop path:. -c cabal build all
nix develop path:. -c cabal test all
```

One `agentic` package builds the public library plus private `examples`,
`bisim-support`, and `verification` components. `cli/ci/policies.sh` checks the
same critical source-level edges: plan -> dsl, cost -> plan, runtime ->
plan + engine API, concrete engines -> engine API, workflow -> DSL, and
bisim -> DSL + plan.

The audit also confirmed unique Haskell module ownership, hidden implementation
modules behind DSL/Plan/Runtime/CLI facades, an `Engine` typeclass with ACP and
deck instances, and one shared `Thinking` representation. `ModelConfig` contains
only model, thinking, and maximum-output fields consumed by both engines. ACP-only
options terminate at `AcpModelConfig`; deck-only provider identity terminates at
`DeckModelConfig`. Repository workflows
have DSL as their sole local dependency; every `servedBy` value is a symbolic
profile mapped in CLI's model-definition example. There is no production dependency
on bisim, no MCP/TUI placeholder, and no obsolete pre-modular source tree.

## Runtime, CLI, and engines

```sh
./cli/ci/policies.sh
./cli/ci/citations.sh
./cli/ci/examples.sh
nix develop path:. -c ./cli/ci/routing-config.sh
./engine/acp/ci/acp.sh
./engine/agent-deck/ci/deck.sh
```

Results:

- Policy probe, lineage, and control probes passed, including memoization,
  scheduling, effects, persistence, restart/resume/fork, steering, recovery, and
  redirect behavior.
- 197 live Haskell-to-Lean citations resolved against 42 Lean files.
- Nine registered workflows retained every pinned plan, cost, help, and scripted
  result.
- Routing/model definitions retained strict schema validation, precedence,
  failover, preflight, and provenance behavior.
- ACP: 18/18 deterministic scenarios passed, including common settings and an
  ACP-only option observed on the stub wire.
- Agent-deck: 10/10 deterministic scenarios passed, including refusal of ACP-only
  options before any deck command.

## Documentation

```sh
nix develop path:. -c make -C doc check
make -C doc check-haskell
python3 doc/check-prose.py
```

Info and HTML rendered without diagnostics. Six source excerpts and two complete
Haskell examples matched live source. API/CLI coverage accounted for 231 items.
The compiler-derived ledger verified 127 public children and 112 exported-class
instances. CLI transcript/default checks and the retained manual workflow smoke
passed.

## Pi extension

```sh
cd ext-pi
npm run check
npm test
AGENT_CAT_E2E_RUNNER="$(cd .. && nix develop path:. -c cabal list-bin agentic-run)" npm run test:integration
```

TypeScript checking passed. Unit tests: 67 passed, five skipped. Integration tests:
10 passed against deterministic ACP/deck/current/child/remote fixtures.

## Final hygiene

`git diff --check`, staged-diff whitespace checking, relative documentation-link
validation, frozen-hash checks, forbidden-import scans, package inventory, module
uniqueness, obsolete-path checks, and a staged-addition secret scan all passed.
`doc/PLAN.org` is synchronized through obr issue `acat-eyr`.
