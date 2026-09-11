# model

`model` is the mathematical definition of agent-cat in Lean 4. It owns the
semantic objects, the laws and their proofs, the typed workflow
representation, and the kernel-checked flagship. A successful build is the
product. The package produces no runtime library and no application.

## Public modules

`Agentic.lean` is the root, and it imports the strata in order. It begins with
the scope monoid, schema-indexed values, questions, annotated requests, worlds,
and dialogues. It continues with the `Plan` representation, its denotation, the
level and cost folds, the commuting theorems, and the fold algebra, and it ends
with the flagship `HardenPatch`. Beside the root, `Agentic.Core` holds the
first-order syntax and its checker under `Dsl`, the kernel-checked flagship
term in `DslFlagship`, and the JSON representation of structured values. It
also holds the reference interpreters `SemanticExec` and `AnnotatedExec`, the
trusted base `Exec`, the certificate layer `Certify`, and the renderings
`Report` and `Explain`. The `Pollution` target checks that an import of the
model installs no unwanted global instance.

## Manager coordination

`Agentic.Manager.History` defines a finite ordered history of coordination
entries and unchanged indexed observations. `P` selects one run's observations,
`Q` folds coordination facts, and `M` pairs `Q` with the finite partial map of
observed runs. A reserved run identity without an observation has no runtime
value. `Materialized` represents that map with Mathlib `Finmap`.

`Agentic.Manager.Coordination` defines the independent request, readiness,
profile, reservation, preparation, supervision, decision, receipt, capture, and
artifact dimensions. Its guarded operations specify oldest-eligible admission,
exact single-use approval, per-run mandatory FIFO reservation and resolution,
delivery knowledge, confirmed cleanup, and verified artifact observations.
`Agentic.Manager.Meaning` specializes the history fold to partial coordination
endomorphisms and separately supplied observation effects. Its ambient function
space is not an authorization vocabulary. The safety laws apply to the named
guarded operations. Realizations must restrict their operations accordingly.

The principal equations are the following.

```text
P r (h ++ k) = P r h ++ P r k
Q step initial (h ++ k) = foldl step (Q step initial h) k
R step initial (xs ++ ys) = foldl step (R step initial xs) ys
decode (advance qStep rStep r0 s e) = stepMeaning qStep rStep r0 (decode s) e
decode (foldl advance initial h) = M qStep q0 rStep r0 h
```

The observation fold is a parameter, not a second runtime interpreter. Its
instantiation with the existing snapshot fold requires validated contiguous
observations of the same run and protocol. Live preparation, unexpired review,
correlated native decision evidence, exact reservation cleanup, and artifact
verification are explicit environment hypotheses. Stored labels provide none
of those hypotheses. The model proves neither physical liveness nor byte
durability, and it does not prove equality of independently executed workflows.

The storage equation `decode(stepStorage(s, e)) = stepManager(decode(s), e)`
remains an implementation obligation. This package has no SQLite `stepStorage`
to which that equation could apply. The proved refinement concerns abstract
finite-map materialization. Runtime ingestion, storage realization, lifecycle
and authorization coverage, and their conformance bridge remain separate
obligations rather than consequences of the abstract proofs.

`test/ManagerChecks.lean` supplies positive mathematical witnesses and refusal
cases. It also checks the following exact axiom footprints with `#guard_msgs`.
The complete theorem statements are beside their proofs in the modules above.

| Theorems | Axiom footprint |
|---|---|
| `P_append` | `propext` |
| `Q_append`, `R_append`, `M_coordination`, `coordination_intent` | `propext`, `Quot.sound` |
| `M_domain`, `Materialized.decode_advance`, `coordination_refinement` | `propext`, `Classical.choice`, `Quot.sound` |
| `Coordination.admit_exclusive`, `Coordination.admit_oldest` | `propext`, `Classical.choice`, `Quot.sound` |
| `Coordination.approval_valid`, `Coordination.approve_single_use` | `propext`, `Classical.choice`, `Quot.sound` |
| `Coordination.openDecision_fifo`, `Coordination.answer_fifo`, `Coordination.answer_nonhead`, `Coordination.answer_reserved`, `Coordination.resolve_fifo` | `propext`, `Classical.choice`, `Quot.sound` |
| `Coordination.delivery_preserves_decisions`, `Coordination.release_confirmed`, `Coordination.verify_exact` | `propext`, `Classical.choice`, `Quot.sound` |

## Dependencies

`lean-toolchain` pins Lean 4.30.0, and `lakefile.toml` together with
`lake-manifest.json` pins Mathlib v4.30.0. The model depends on no Haskell,
runtime, engine, CLI, or extension code. The conformance package under
`../bisim` depends on this one by a local Lake path, and the model never
imports it.

## Build

From the repository root, use the attached Nix environment.

```sh
direnv exec . lake --dir model build
```

The default targets are `Agentic`, `Pollution`, and `ManagerChecks`. Explicit
Core and Manager namespace globs include modules that the root does not import.
`Agentic.Core.DslFlagship` proves its theorems by running the checker, the cost
algebra, and the interpreter inside the kernel, which takes minutes and several
gigabytes of memory. Never run two full model builds at once.

The manager coverage gate uses an isolated model workspace under `~/Products`,
containing the current model sources and the pinned dependency checkouts. An
existing build cache can be copied with that workspace. `MODEL_WORKSPACE` names
that copy and `MODEL_EVIDENCE` names a separate output directory.

```sh
direnv exec . python3 model/ci/check-manager.py \
  --workspace "$MODEL_WORKSPACE" --artifacts "$MODEL_EVIDENCE"
```

The gate verifies source identity and builds the default targets with warnings
treated as errors. In a separate negative fixture it requires an otherwise
unimported manager module and the witness target to fail when broken. Removing
the manager glob in a control fixture demonstrates the silent omission that
the gate detects. Build-cache downloads are disabled, and logs and negative
fixtures remain under the specified evidence directory.

## Conventions

Meaning and proofs belong here, and operational realization belongs elsewhere.
Keep the import narrative of the root aligned with the strata. Add no process,
wire-format, corpus, or engine concern. Preserve the narrow imports that the
conformance oracle uses, so that the oracle never depends on the expensive
flagship.
