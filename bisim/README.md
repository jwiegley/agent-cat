# bisim

`bisim` is the test-only boundary where the Haskell implementation is checked
against the normative Lean model. It owns the Lean conformance codec and
oracle, the frozen corpus, the corpus generator, and the Haskell generators,
guards, oracle client, and frozen-vector runner. No production component
depends on it. Lean runs as a subprocess and is never linked into an
executable.

## Layout

`bisim/lean` is the Lake package `agentic-bisim`. It requires the model by a
local path, and it imports only the cheap closure of the model. It never
imports `Agentic.Core.DslFlagship` or `Agentic.Core.HardenPatch`. It builds
the `Conformance` library and the executables `conformance-oracle` and
`corpus-gen`. The same package builds the separate library
`ManagerConformance` from `bisim/manager`. That library imports only
`Agentic.Manager.*` and Lean core, with the `Mathlib.Data.Finmap` closure that
the manager model imports. It never imports a module of `Agentic.Core` or the
root module of the model. It instantiates the coordination model at string
identities and values, defines a finite evidence table, and gives an
executable decider for each of the transitions `openDecision`, `answer`,
`resolve`, `release` and `verify`. `ManagerConformance.Admission` reduces the
quantifiers of the admission and approval guards to the finite entries of the
requests, profiles, slots and reservations of the state. It proves each
reduction, gives `Decidable` instances for `eligible`, `canAdmit` and
`canApprove`, and defines the deciders of `admit` and `approve`. A theorem
proves that each decider equals its model transition.
`ManagerConformance.Checks` fixes the axiom footprint of each equality and of
each reduction. It evaluates at least one accepted and one refused closed
witness for each decider. The admission witnesses include a refusal because
of an overlapping held reservation, and the approval witnesses include the
refusal after a change of the process generation. `ManagerConformance.Codec` fixes the JSON
encoding of version `agent-cat-manager-conformance/1`. The executable
`manager-oracle` evaluates one history entry for each request line with the
deciders of the library. The executable `manager-cases` writes the retained
cases of `ManagerConformance.Cases` to `bisim/manager/cases`, which is outside
`bisim/corpus`. `bisim/manager/README.md` specifies the encoding, the
representation assumptions and the scope of the oracle. `ManagerConformance`,
`manager-oracle` and `manager-cases` are not default targets, so `lake build`
keeps its cost. `bisim/corpus` holds the
frozen vectors. `bisim/haskell/src` is
the internal `bisim-support` library of the `agentic` package. It exposes
`Agentic.Bisim` over the hidden modules `Agentic.Gen`, `Agentic.Guards`, and
`Agentic.Oracle`. `bisim/haskell/tier0` is the `tier0` executable, which
replays the frozen vectors without Lean. The `tier1` and live `bisim`
executables need cost and workflow definitions, so they live under
`cli/verification` with the private `verification` library.

## Dependencies

```text
bisim/lean -> model                        (Lake path dependency, tests only)
bisim/manager -> model Agentic.Manager.*   (Lake path dependency, tests only)
bisim-support -> dsl, plan
cli/verification -> bisim-support, cost, dsl, plan
```

## Build and test

```sh
nix develop path:./model -c bash -c 'cd bisim && lake build && lake exe corpus-gen'
nix develop path:. -c cabal build all
./bisim/ci/tier0.sh
N=500 SEED=1 ./bisim/ci/tier1.sh
```

The command `lake --dir bisim build --wfail ManagerConformance manager-oracle
manager-cases` builds the manager conformance library and its two
executables. It reuses the prebuilt Mathlib artifacts and elaborates only the
manager modules of the model and the library itself. `bisim/manager/README.md`
gives the command that replays the retained manager cases through the oracle.

### The manager conformance gate

The sources of the manager conformance lane are in four directories.
`model/Agentic/Manager` holds the model, with the entry module
`Agentic.Manager.Meaning`. `bisim/manager` holds the library
`ManagerConformance` and the entry modules `ManagerOracle` of
`manager-oracle` and `ManagerCases` of `manager-cases`. `manager/test` holds
`ConformanceCheck.hs` of `manager-conformance-check` and `VerticalCheck.hs`,
and `cli/test` holds `ManagerApprovalProbe.hs` of `manager-vertical-check`.

The script `bisim/ci/manager.sh` is the gate of the lane. Each subcommand
runs one step under its own timeout, and the script without a subcommand
prints the order of the steps and exits with status 2.

```sh
timeout 300 bash bisim/ci/manager.sh closure
timeout 1800 bash bisim/ci/manager.sh lean
timeout 900 bash bisim/ci/manager.sh build
for step in cases admission vertical history refusals corpus; do
  timeout 900 bash bisim/ci/manager.sh "$step"
done
timeout 1800 bash bisim/ci/manager.sh control-oracle
timeout 1800 bash bisim/ci/manager.sh control-model
timeout 300 bash bisim/ci/manager.sh control-case
```

The step `closure` checks the import closure, and `lean` builds
`ManagerConformance` and `manager-oracle` alone. The step `build` builds the
Haskell executables, and `cases`, `admission`, `history` and `refusals` run
the lanes. The step `vertical` runs the direct-versus-managed check at N8 and
records its root for `history` and `refusals`, and `corpus` requires that
`git status --short bisim/corpus` is empty. Each control works on a copy
under `$TMPDIR` and must fail: `control-oracle` with a broken oracle,
`control-model` with a broken model, and `control-case` with a changed
retained case.

The library proves that each decider equals its model transition, that the
finite guards are equivalent to the model guards, and that the step of the
oracle is the coordination step of the model. Each of these twelve theorems
has the axiom footprint `propext`, `Classical.choice` and `Quot.sound`, which
`ManagerConformance/Checks.lean` fixes. Every identity and value is an opaque
string, and the oracle trusts the evidence table that its caller supplies.
The theorems and the lanes make no claim about the HTTP service, the SQLite
commit, process containment or engine effects. `bisim/manager/README.md`
states the theorems, the representation assumptions, the controls and these
boundaries in full.

`corpus-gen` must leave every corpus byte unchanged. A diff is a change to the
specification. The script `tier1.sh` requires the prebuilt oracle and refuses
to build it, which preserves the one-build rule for the expensive model. The
chapter "Conformance Boundary" of the manual specifies the wire format and
states what the corpus pins.

## Conventions

Lean observations are authoritative, and a Haskell comparison must not weaken
them. Keep the corpus frozen byte for byte unless the specification changes.
Keep the Haskell side of this directory limited to DSL and planner
dependencies. Cost and workflow definitions belong to the private verification
library. Use deterministic local processes only. Treat a transport error as a
failure of the harness and not as a conformance divergence.
