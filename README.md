# agentic-hs

The Haskell implementation of the operational terms of `agent-cat`
(`/Users/johnw/src/agent-cat`, a Lean 4 formalization of agentic workflows) —
the raw syntax of the agentic DSL, its JSON codec, the term-level guards, the
ask counts and the string layer — kept honest by replaying a frozen corpus
produced by the Lean formalization.

Lean is normative. This repository does not ask to be believed on its own
authority: every claim it makes about the language is checked against 121
request/reply pairs the Lean oracle emitted, and the check is a program you can
run in one command.

```
nix develop -c cabal run tier0
```

```
tier0: kinds: 22 string, 5 guard, 35 other, 59 checked, 0 ping, 0 unclassified
tier0: 121 passed, 0 failed, 35 other-refusals (codec-only), of 121 files
```

## Running it

The flake devShell is the only environment; nothing is installed globally.

```sh
nix develop -c cabal build          # build the library and the runner
nix develop -c cabal run tier0      # replay the frozen corpus
```

(A flake in a git working tree is read *through git*, so `flake.nix` and
`flake.lock` are tracked; if you ever see `Path 'flake.nix' … is not tracked
by Git` after adding files, either track them or route around git with
`nix develop path:. -c …`.)

`tier0` takes an optional corpus directory and otherwise reads
`/Users/johnw/src/agent-cat/test/corpus`:

```sh
nix develop -c cabal run tier0 -- /path/to/some/other/corpus
```

It prints one line per failing entry — naming the file, what was compared, the
expected value and the actual one — then the two summary lines above. It exits
`0` if and only if nothing failed, so it is usable directly as a CI gate.

## What week one covers

Four things, and deliberately no more:

| module | what it is |
| --- | --- |
| `Agentic.Raw` | the `Raw` AST and a codec byte-compatible with Lean's derived `ToJson`/`FromJson` |
| `Agentic.Guards` | the five term-level guards, in firing order, and the two ask counts |
| `Agentic.Text` | the string layer — `norm`, `words`, `decodeVerdict`, `decodeFlag`, `say` — ASCII-only, as Lean core is |
| `tier0/Main.hs` | the corpus runner |

**Not** in scope, and not compared: the typing judgment, the parser, `Plan`
denotation, worlds, traces, bills, and the reply fields that carry them
(`level`, `size`, `askNodes`, `codes`, `costSummary`, `worlds`). Those are later
weeks. The runner ignores those fields silently rather than failing on them —
but it never ignores an entry it cannot classify, which is always a failure.

## What tier0 compares

| entry | rule |
| --- | --- |
| `request.string` (22) | `stringOp op code text` must equal the whole reply value |
| `request.program` (99) | decode, re-encode, and match the request's `program` value |
| refused with one of the five (5) | `guardCheck` must return that guard and its `n` |
| refused `other` (35) | the codec round-trip and nothing else — the typing judgment decided these, and it is not ported |
| checked (59) | `guardCheck` must fire nothing, and `askCounts` must equal `(blockAsks, fnAsks)` |

Comparison is on `Data.Aeson.Value`, never on bytes, so object key order and
number formatting are free. `refused.pos`, `.excerpt` and `.message` are
oracle-only and are never compared: they are functions of written characters and
of the checker's wording, neither of which this side has.

Values in failure messages are printed with every non-ASCII and non-printing
character escaped. The corpus turns on differences that are invisible in a
terminal — U+00A0 against a space, `İ` against `i`, a stripped `\r` — and a
diagnostic that hides them would be worse than none.

## Layout

```
flake.nix          the devShell: one GHC with aeson, plus cabal-install
agentic.cabal      library (src) + executable tier0 (tier0)
src/Agentic/Raw.hs      the Raw AST and its JSON codec
src/Agentic/Guards.hs   guardCheck, askCounts
src/Agentic/Text.hs     stringOp, Verdict
tier0/Main.hs           the corpus runner
PORTING.md              the porting spec: the types, the encoding, the
                        guard order, the string layer, the comparison rules
```

## Sources of record

* **The design** — why there is a Haskell implementation at all, and why it is
  connected to Lean by reimplementation-plus-conformance rather than by
  extraction, FFI or a subprocess oracle —
  `/Users/johnw/src/agent-cat/doc/research/dsl-redesign/connection.md`. That
  page is the design of record for this repository.
* **The port** — [`PORTING.md`](PORTING.md), which every module here is written
  against.
* **The wire format** —
  `/Users/johnw/src/agent-cat/doc/conformance-schema.md`.
* **The arbiter** — `/Users/johnw/src/agent-cat/test/corpus/*.json`. Where
  `PORTING.md` and the corpus disagree, the corpus wins; where `PORTING.md` and
  the Lean source disagree, Lean wins.

Nothing under `/Users/johnw/src/agent-cat` is ever edited from here. It is read,
and it is obeyed.
