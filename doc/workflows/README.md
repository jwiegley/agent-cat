# Manual authoring workflow

`agent-cat-manual.js` is documentation tooling: a Pi dynamic workflow for
researching, drafting, reviewing, and validating the Texinfo manual. It is
neither an agent-cat Haskell workflow nor part of the runtime.

## Use

Pass the file's contents as the `script` of a Pi `workflow` tool call. The
optional arguments are `mode`, which is `whole` or `update`; `scope`;
`requirements`; and a bounded `smoke` flag. A complete run makes fourteen
agent calls across the phases Inventory, Draft, Synthesize, Review, Revise,
and Validate, and returns candidate Texinfo. The checkers in `doc/` and
`doc/Makefile` remain the authority that accepts a result. The retained smoke
record is `../workflow-smoke.json`, and `../check-workflow-smoke.py` confirms
that it still describes this script.

## Dependencies

The script depends on Pi's dynamic-workflow API and on no agent-cat Cabal
component. It fixes no model, provider, credential, or machine path.

## Check

```sh
nix develop path:. -c make -C doc check
make -C doc check-haskell
```

## Conventions

Keep the script byte-stable unless its smoke evidence is rerun and updated
together with it. It must not become a second workflow interpreter, runtime, or
package boundary.
