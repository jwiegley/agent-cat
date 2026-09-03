# model

`model` is agent-cat's mathematical definition in Lean. It owns the semantic
objects, laws, proofs, typed workflow representation, and checked flagship. A
successful build is the module's product; it produces no runtime library or
application artifact.

## Public API

The Lean modules rooted at `Agentic` are the public mathematical API.
`Agentic.lean` is the narrative root, while `Agentic.Core.*` exposes the
individual strata. The `Pollution` target checks that importing the model does
not install unwanted global instances.

Conformance wire codecs, the oracle process, corpus generation, and frozen
vectors are not part of this module. They live in [`../bisim`](../bisim) and
consume `model` through Lake's local package dependency.

## Dependencies

- Lean 4.30.0, pinned by `lean-toolchain`
- Mathlib v4.30.0, pinned by `lakefile.toml` and `lake-manifest.json`
- No agent-cat Haskell, runtime, engine, CLI, or extension package

The dependency direction is `bisim -> model`; `model` never imports `bisim`.

## Build

From this directory:

```sh
nix develop path:. -c lake build
```

This builds `Agentic` and `Pollution`. `Agentic.Core.DslFlagship` is deliberately
expensive because its kernel-checked proofs compute the flagship. Never launch
two full model builds concurrently.

## Conventions

- Meaning and proofs belong here; operational realization belongs elsewhere.
- Keep the root import narrative aligned with the mathematical strata.
- Do not add process, wire-format, corpus, or engine concerns.
- Preserve the narrow imports used by `bisim`; do not make its oracle import the
  expensive flagship module.
