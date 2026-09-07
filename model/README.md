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

## Dependencies

`lean-toolchain` pins Lean 4.30.0, and `lakefile.toml` together with
`lake-manifest.json` pins Mathlib v4.30.0. The model depends on no Haskell,
runtime, engine, CLI, or extension code. The conformance package under
`../bisim` depends on this one by a local Lake path, and the model never
imports it.

## Build

```sh
nix develop path:. -c lake build
```

The default targets are `Agentic` and `Pollution`. `Agentic.Core.DslFlagship`
proves its theorems by running the checker, the cost algebra, and the
interpreter inside the kernel, which takes minutes and several gigabytes of
memory. Never run two full model builds at once.

## Conventions

Meaning and proofs belong here, and operational realization belongs elsewhere.
Keep the import narrative of the root aligned with the strata. Add no process,
wire-format, corpus, or engine concern. Preserve the narrow imports that the
conformance oracle uses, so that the oracle never depends on the expensive
flagship.
