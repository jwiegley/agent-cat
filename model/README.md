# model

`model` is agent-cat's mathematical definition in Lean 4. It owns the semantic
objects, the laws and their proofs, the typed workflow representation, and the
kernel-checked flagship. A successful build is the product; the package
produces no runtime library and no application.

## Public modules

`Agentic.lean` is the root and imports the strata in order: the scope monoid,
schema-indexed values, questions, annotated requests, worlds, dialogues, the
`Plan` representation, its denotation, the level and cost folds, the commuting
theorems, the fold algebra, and the flagship `HardenPatch`. Beside the root,
`Agentic.Core` holds the first-order syntax and checker under `Dsl`, the
kernel-checked flagship term in `DslFlagship`, the JSON representation of
structured values, the reference interpreters `SemanticExec` and
`AnnotatedExec`, the trusted base `Exec`, the certificate layer `Certify`, and
the renderings `Report` and `Explain`. The `Pollution` target checks that
importing the model installs no unwanted global instance.

## Dependencies

Lean 4.30.0 is pinned by `lean-toolchain`, and Mathlib v4.30.0 by
`lakefile.toml` and `lake-manifest.json`. The model depends on no Haskell,
runtime, engine, CLI, or extension code. The conformance package under
`../bisim` depends on this one by a local Lake path; the model never imports
it.

## Build

```sh
nix develop path:. -c lake build
```

The default targets are `Agentic` and `Pollution`. `Agentic.Core.DslFlagship`
proves its theorems by running the checker, the cost algebra, and the
interpreter inside the kernel, which takes minutes and several gigabytes of
memory. Never run two full model builds at once.

## Conventions

Meaning and proofs belong here; operational realization belongs elsewhere.
Keep the root import narrative aligned with the strata. Add no process,
wire-format, corpus, or engine concern. Preserve the narrow imports that the
conformance oracle uses, so that it never depends on the expensive flagship.
