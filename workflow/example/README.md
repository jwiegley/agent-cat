# workflow/example

`agentic-workflow-example` owns small teaching and representation examples, including
canonical `hardenProgram`.

## Public API

`Harden` exports frozen flagship `hardenProgram`.
`Hello` exports frozen `helloProgram`.
`Structured` exports structured-answer programs and host record boundary.

## Dependencies and adjacent modules

The sole local dependency is `agentic-dsl`. CLI registers these values; bisim uses
them through a test-only edge. No sibling workflow or runtime package is allowed.

## Build and test

```sh
nix develop path:../.. -c cabal build agentic-workflow-example
./cli/ci/examples.sh
./bisim/ci/tier0.sh
```

## Conventions

Keep examples small, symbolic, and engine-independent. CLI help and canned answers
stay in CLI composition.
