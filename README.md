# agentic-hs

The Haskell implementation of the operational terms of `agent-cat`
(`/Users/johnw/src/agent-cat`, a Lean 4 formalization of agentic workflows) —
the raw syntax of the agentic DSL, its JSON codec, the term-level guards, the
ask counts and the string layer, and above them the typed `Plan`, its meaning
in a world and the production surface that builds one — kept honest by
replaying a frozen corpus produced by the Lean formalization.

Lean is normative. This repository does not ask to be believed on its own
authority: every claim it makes about the language is checked against 121
request/reply pairs the Lean oracle emitted, and the check is two programs you
can run in one command each.

```
nix develop -c cabal run tier0
nix develop -c cabal run tier1
```

```
tier0: kinds: 22 string, 5 guard, 35 other, 59 checked, 0 ping, 0 unclassified
tier0: 121 passed, 0 failed, 35 other-refusals (codec-only), of 121 files
tier1: 16 passed, 0 failed, of 16 cases
```

`tier0` replays every entry through the codec, the guards and the string layer.
`tier1` **rebuilds** sixteen of the checked entries in the production surface
and holds the rebuilt program against the frozen one on both fronts: the
program it prints, and the whole reply — folds, counts, and one trace and two
bills per world.

## Running it

The flake devShell is the only environment; nothing is installed globally.

```sh
nix develop -c cabal build          # build the library and both runners
nix develop -c cabal run tier0      # replay the frozen corpus
nix develop -c cabal run tier1      # rebuild the curated cases and compare
```

(A flake in a git working tree is read *through git*, so `flake.nix` and
`flake.lock` are tracked; if you ever see `Path 'flake.nix' … is not tracked
by Git` after adding files, either track them or route around git with
`nix develop path:. -c …`.)

Both runners take an optional corpus directory and otherwise read
`/Users/johnw/src/agent-cat/test/corpus`:

```sh
nix develop -c cabal run tier0 -- /path/to/some/other/corpus
```

Each prints one line per failure — naming the file, what was compared, the
expected value and the actual one — then its summary line. Each exits `0` if
and only if nothing failed, so both are usable directly as CI gates.

## What is covered

| module | what it is |
| --- | --- |
| `Agentic.Raw` | the `Raw` AST and a codec byte-compatible with Lean's derived `ToJson`/`FromJson` |
| `Agentic.Guards` | the five term-level guards, in firing order, and the two ask counts |
| `Agentic.Text` | the string layer — `norm`, `words`, `decodeVerdict`, `decodeFlag`, `say` — ASCII-only, as Lean core is |
| `Agentic.Plan` | the typed `Plan` — five formers, `DataKinds` codes, de Bruijn `Expr` — and its static folds `level`, `size`, `askNodes`, `codes`, `costSummary` |
| `Agentic.World` | `WorldSpec` and `toWorld`, the `trace` of a plan through a world, the fresh and memo bills, and the oracle's event JSON |
| `Agentic.Builder` | the production surface: typed combinators that both print a `RawProgram` and elaborate to the `Plan` the Lean checker elaborates the same construct to |
| `tier0/Main.hs`, `tier1/` | the two runners |

**Not** in scope, and deliberately absent: the parser, and the typing judgment.
The builder gets well-formedness from Haskell's own types instead — an unbound
name, a kind mismatch, a duplicate function name, an empty panel and `served
by` on a tool are type errors or are unrepresentable — so the refusals those
rules produce are reachable only through `Agentic.Guards`, which is what tier0
already replays. Positions are oracle-only throughout, like `message` and
`excerpt`: the builder prints `0:0` and tier1 zeroes both sides.

## What tier0 compares

| entry | rule |
| --- | --- |
| `request.string` (22) | `stringOp op code text` must equal the whole reply value |
| `request.program` (99) | decode, re-encode, and match the request's `program` value |
| refused with one of the five (5) | `guardCheck` must return that guard and its `n` |
| refused `other` (35) | the codec round-trip and nothing else — the typing judgment decided these, and it is not ported |
| checked (59) | `guardCheck` must fire nothing, and `askCounts` must equal `(blockAsks, fnAsks)` |

## What tier1 compares

Sixteen checked entries, rebuilt from their surface source in `Agentic.Builder`
and compared whole — no field skipped, a missing or extra key a failure:

| front | rule |
| --- | --- |
| the printed program | `toJSON (progRawOut built)` against `request.program`, positions zeroed on both sides, and the print decoded back and re-encoded so a print no reader accepts fails here |
| the static folds | `level`, `size`, `askNodes`, `codes`, `costSummary` folded from the elaborated `Plan` |
| the ask counts | `Agentic.Guards.askCounts` on the *printed* program — week-one code, which is what makes this a cross-check of the builder rather than a second reading of the same term |
| each world | per `request.worlds` in order: the world re-serialized, its trace event by event (`code`, `addressee`, `scope`, `prompt`, `draw`, `answer`), and `billFresh` / `billMemo` |

The sixteen are chosen to reach every rung and every corner the corpus fixes:
all three reachable levels (`batch`, `pipeline`, `branch`), all four answer
codes, all three parties, draws 0–3, both scope states, `codes` as `null`, `[]`
and a list, bounded revisions at 0, 1, 2 and 3 amendments including two nested
inside a settled arm, and both of the only two entries where the memo bill falls
below the fresh one. The five guard vectors and the refused entries are
**unrepresentable** in the builder by design; tier0 covers them.

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
agentic.cabal      library (src) + executables tier0 and tier1
src/Agentic/Raw.hs      the Raw AST and its JSON codec
src/Agentic/Guards.hs   guardCheck, askCounts
src/Agentic/Text.hs     stringOp, Verdict
src/Agentic/Plan.hs     the typed Plan and its static folds
src/Agentic/World.hs    WorldSpec, toWorld, trace, the bills, the event JSON
src/Agentic/Builder.hs  the production surface and its elaboration
tier0/Main.hs           the corpus runner
tier1/Cases.hs          the rebuilt cases, each quoting its surface source
tier1/Main.hs           the rebuilt-case runner; it owns every comparison
PORTING.md              week one: the types, the encoding, the guard order,
                        the string layer, the comparison rules
PORTING2-core.md        week two: Agentic.Plan and Agentic.World
PORTING2-elab.md        week two: the elaboration, Agentic.Builder, tier1
```

## Sources of record

* **The design** — why there is a Haskell implementation at all, and why it is
  connected to Lean by reimplementation-plus-conformance rather than by
  extraction, FFI or a subprocess oracle —
  `/Users/johnw/src/agent-cat/doc/research/dsl-redesign/connection.md`. That
  page is the design of record for this repository.
* **The port** — [`PORTING.md`](PORTING.md),
  [`PORTING2-core.md`](PORTING2-core.md) and
  [`PORTING2-elab.md`](PORTING2-elab.md), which every module here is written
  against.
* **The wire format** —
  `/Users/johnw/src/agent-cat/doc/conformance-schema.md`.
* **The arbiter** — `/Users/johnw/src/agent-cat/test/corpus/*.json`. Where
  `PORTING.md` and the corpus disagree, the corpus wins; where `PORTING.md` and
  the Lean source disagree, Lean wins.

Nothing under `/Users/johnw/src/agent-cat` is ever edited from here. It is read,
and it is obeyed.
