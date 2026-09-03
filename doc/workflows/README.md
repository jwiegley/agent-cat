# Manual authoring workflow

`agent-cat-manual.js` is documentation tooling: the checked-in Pi dynamic workflow
for researching, drafting, reviewing, and validating the Texinfo manual. It is not
an agent-cat Haskell workflow and owns no runtime behavior.

## Public API and scope

Pass the file contents as the `script` of a Pi `workflow` tool call. Optional
arguments are `mode` (`whole` or `update`), `scope`, `requirements`, and bounded
`smoke`. A complete run uses fourteen calls across Inventory, Draft, Synthesize,
Review, Revise, and Validate.

## Dependencies and adjacent modules

The script depends on Pi's external dynamic-workflow API, not any agent-cat Cabal
package. It may read documentation and return candidate Texinfo; `doc/Makefile` and
its checkers remain the authority that accepts the result. The retained smoke record
is `../workflow-smoke.json`.

No model, provider, credential, or machine path is fixed in the script.

## Build and test

From the repository root:
```sh
nix develop path:. -c make -C doc check
make -C doc check-haskell
```

## Conventions

Keep the script byte-stable unless its fourteen-agent smoke evidence is rerun and
updated. It must not become a second workflow interpreter, runtime, or package
boundary.
