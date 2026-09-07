# Manual authoring workflow

`agent-cat-manual.js` is documentation tooling. It is a Pi dynamic workflow
that researches, drafts, reviews, and validates the Texinfo manual. It is not
an agent-cat Haskell workflow, and it is not part of the runtime.

## Use

Pass the contents of the file as the `script` of a Pi `workflow` tool call.
The optional arguments are `mode`, which is `whole` or `update`, `scope`,
`requirements`, and a bounded `smoke` flag. A complete run makes fourteen agent
calls across the phases Inventory, Draft, Synthesize, Review, Revise, and
Validate, and it returns candidate Texinfo. The checkers in `doc/` and
`doc/Makefile` remain the authority that accepts a result. The retained smoke
record is `../workflow-smoke.json`, and `../check-workflow-smoke.py` confirms
that this record still describes this script.

## Dependencies

The script depends on the dynamic-workflow API of Pi and on no agent-cat Cabal
component. It fixes no model, provider, credential, or machine path.

## Check

```sh
nix develop path:. -c make -C doc check
make -C doc check-haskell
```

## Conventions

Keep the script stable byte for byte unless the smoke evidence is rerun and
updated together with it. The script must not become a second workflow
interpreter, runtime, or package boundary.
