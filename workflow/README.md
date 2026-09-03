# workflow

`workflow` holds the compiled workflow definitions. Each child directory is a
set of Haskell modules whose only local dependency is `dsl`; they build into
the internal `examples` library of the `agentic` package together with the
registry data under `cli/example`.

## Layout

`example` holds the teaching workflows `Harden`, `Hello`, and `Structured`.
`extra` holds `Isaac`, the five workflows derived from incite. `core` is
reserved for stable, generally useful workflows and holds no module at
present; it is not listed in `agentic.cabal`.

## Dependencies

```text
workflow/{example,extra} -> dsl
cli -> workflow/{example,extra}
cli/verification -> workflow/example   (tests only)
```

Workflow directories never depend on one another.

## Build and test

```sh
nix develop path:. -c cabal build all
./cli/ci/examples.sh
./bisim/ci/tier0.sh
```

## Conventions

These directories hold definitions and authoring data only. Models are named
symbolically. Registry rows, help pages, canned replies, model definitions,
planning, pricing, and execution live above this layer.
