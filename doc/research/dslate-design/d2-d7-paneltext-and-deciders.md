# D2 + D7: `panelText` and the closed decider vocabulary

Implementation design for wave 3. Owner-ruled: D2 yes, D7 yes at exactly four
constructors. This document decides every open question in both so that wave 3
writes code and does not re-litigate shapes.

Everything below is stated so that the Lean side and the Haskell side cannot
diverge: where a string function is new, its algorithm is spelled in full and it
is pinned by a corpus vector, in the family of `Exec.norm` and
`Exec.decodeVerdict`.

---

## 0. Corrections to §4's premises, established by reading the sources

Five claims in `doc/research/isaac-workflows.md` §4 do not survive contact with
the code. None of them changes the decisions, but three change the cost and one
changes what a decider must actually do, so they are recorded first.

1. **`Explain.lean` needs no new fold clause — for either decision.** G8's
   honest cost says "one new fold clause in `Explain.lean`". There is none to
   write. `Explain.lean` folds `PlanF`'s five constructors (`ret`, `askC`,
   `ask`, `case`, `dyn`) and never mentions `panel`; `Plan.panel`
   (`Agentic/Core/Plan.lean:930`) is *derived* — `ps.foldr (zipWith (· * ·))
   (.ret (fun _ => 1))` — so it is already ordinary nodes by the time any fold
   sees it. `panelText` is derived the same way and is likewise invisible to
   `Explain.lean`, `Cost.lean` and `Level.lean`. **D2 is cheaper than
   advertised.**

2. **Three of the four deciders do not live where §4 says.** `tripEnding`,
   `isRed` and `decideFactsResolved` are in
   `/Users/johnw/src/incite/workflows/Incite/Feature.hs` (lines 653, 833, 1594),
   not `Review.hs`. `Review.hs` holds `diffNamesHaskell` (:247) and
   `routeHaskell` (:261).

3. **`greenGateBrief` and `factsGateBrief` do not exist.** The real consumers
   are `greenGate`/`checkLoop` (Feature.hs:1866, :1887) and `grindFlow`
   (Feature.hs:1560). Any docstring wave 3 writes should cite the real names.

4. **`agent-functor` has no `diffNames`.** Grep across the repository returns
   nothing. The only path matcher in either tree is `matchGlob`
   (`/Users/johnw/src/agent-functor/src/Agent/Grant.hs:75`), and incite has no
   glob machinery at all — `diffNamesHaskell` is a suffix test.

5. **`containsLine` has no witness in incite.** §4 asserts the four deciders
   "cover `tripEnding`, `isRed`, `decideFactsResolved` and `diffNamesHaskell` —
   which is every pure decider in incite". In fact `isRed` *and*
   `decideFactsResolved` are both `anyLineStartsWith`; `containsLine` (exact
   line equality) reconstructs neither. The honest accounting is: three
   deciders cover all four incite functions, and `containsLine` is a fourth
   admitted on its own merits — it is the only exact-match member of the
   family, and it is what a program wants when the program itself dictated the
   sentinel ("end with a line that is exactly `READY`"), where a prefix test
   would admit `READY-ISH` and a decider that admits more than the program
   asked for is the failure mode this vocabulary exists to remove. Ship four;
   do not pretend `containsLine` has an incite ancestor.

---

## Part 1 — `panelText`

### 1.1 What it is

`panelText` is `panel`'s twin at `.text`: the same fan-out, the same one
question per member, the same trace, and a different fold. `panel` folds into
the verdict monoid; `panelText` folds into the free monoid over **fenced
blocks**, in member order. The result is a document whose reader can tell which
member said what.

The monoid is `(String, ++, "")` *after* each member's answer has been wrapped in
its own tag pair. Associative, non-commutative, and — this is the property that
matters and the one `panel` also has — `doc (ms ++ ns) = doc ms ++ doc ns`, so a
fan split in two and folded separately folds to the same document.

### 1.2 The names, and where they come from

**Explicit labels, carried in the `Raw`. Not the addressee id.**

Two members of one spread routinely share an addressee: incite's
`haskellIfEdited` (Review.hs:187) names its block `"haskell"` while both of its
leaves are `withBackend claudeAgent fable5`, and `spreadPinned gsPins backends
gsLenses` (Feature.hs:1560) is a comprehension over `(lens, backend)` pairs in
which the *lens* names the block and the backend is orthogonal. Deriving the
fence from `RawTarget.addressee` would collide every such spread into
indistinguishable blocks and would make the document's names change when an
operator repoints a lens at a different model — a rename of the wrong thing.

So a member is a pair: a label and an ask.

### 1.3 The fence, exactly

**Spelling: `<name>` … `</name>`, XML-shaped, newline-delimited.**

```
block n b  =  "<" ++ n ++ ">\n" ++ escapeClose n b ++ "\n</" ++ n ++ ">\n"
doc ms     =  concat (map (uncurry block) ms)          -- no separator
```

Two members, verbatim bytes:

```
<alpha>
BODY-A
</alpha>
<beta>
BODY-B
</beta>
```

Justification, against the alternatives:

- **Against `## heading`** — Isaac's reason, adopted as stated in G8: bodies
  emit their own headings, and a heading marks a start with nothing marking the
  end. A reader of the fold cannot tell where `alpha` stopped.
- **Against custom brackets (`<<<name>>>`, `===name===`)** — a custom delimiter
  buys nothing over `<name>` on collision (both can appear in a body; §1.4
  handles that identically either way) and loses the one advantage the XML
  shape has, which is that it is the delimiter every addressee in this system
  has seen ten thousand times. The document is read by a *model* downstream —
  incite's `refineWith "synthesis"` (Feature.hs:1561) is the consumer — and the
  fence is a prompt-engineering decision as much as a syntax one.
- **Nesting** — `<a>` inside `<outer>` survives, because §1.4's escape rewrites
  only the closing tag of *this* fence.

**The body is verbatim.** No trim, no normalization. This is forced: `.text`
already decodes verbatim (`Agentic.Text.decodeAnswerJson`: "`.text` is
__verbatim__: no normalization, no trimming"), and a fold that trimmed would put
a second, contradictory rule about text into the language.

**Tag name validity, checked.** A label must be non-empty, must begin with an
ASCII letter, and every character must be ASCII alphanumeric, `-`, `_` or `.`.
Anything else is a `CheckError` at the member's position. This is what makes
`</name>` an unambiguous byte string to search for, and it forbids `<`, `>` and
`/` inside a tag by construction.

**Duplicate labels are refused**, in the family of the empty-panel refusal. Two
`<a>` blocks in one document make the names not a key, which defeats the whole
point of naming them.

### 1.4 Escaping — decided: yes, and minimally

A member's answer is a model's text. If it may contain `</alpha>`, a member can
forge the end of its own block and open a block of its own choosing, and the
synthesis that reads the document is steered by a member. That is exactly the
failure `diffNamesHaskell` exists to prevent, one layer down, so the same answer
applies: **do not trust the body**.

```
escapeClose n b  =  b with every occurrence of  "</" ++ n ++ ">"
                    replaced by                 "<\/" ++ n ++ ">"
```

One backslash inserted after the `<`. Left to right, non-overlapping. In Lean
this is `b.replace ("</" ++ n ++ ">") ("<\\/" ++ n ++ ">")`; in Haskell
`T.replace ("</" <> n <> ">") ("<\\/" <> n <> ">") b`. Both are left-to-right
non-overlapping scans, and the replacement cannot contain the needle, so no
re-scan question arises. The needle is non-empty because §1.3 forbids an empty
label — which is also what keeps `Data.Text.replace` total (it errors on an
empty needle).

Why *only* the fence's own closing tag, and not all of `</`:

- It preserves nesting exactly. An inner document's `</a>`, `</b>` pass through
  an outer `<outer>` fence untouched. Rewriting every `</` would mangle them,
  and "a tag pair nests when fans union" is the reason the tag pair was chosen.
- The mangled case — an inner member sharing a name with an enclosing fence —
  is precisely the ambiguous one, and mangling is the safe resolution of it.

The counter-case, recorded: `Verdict.render` intercalates objections with `"; "`
and escapes nothing, so the kernel has a precedent for lossy advisory
rendering. The distinction is that an objection list is read by a *person* and
this document is read by a *model that will act on it*.

### 1.5 The `Raw` constructor

`Agentic/Core/Dsl/Syntax.lean`, a fourth constructor on `RawRhs`:

```lean
  /-- `panel as text [ name: ask, … ]`: several questions, each member's answer
  fenced under its own name and the blocks concatenated in member order. -/
  | panelText (members : List (String × RawAsk)) (pos : Pos)
```

Label first in the pair: it is how the source reads.

`RawRhs.pos` gains `| .panelText _ p => p`.

Haskell mirror, `Agentic/Raw.hs` beside `RhsPanel`:

```haskell
  | RhsPanelText ![(Text, RawAsk)] !Pos
```

JSON, additive, in the existing `ctorObj` style:

```
RhsPanelText ms pos -> ctorObj "panelText" ["members" .= ms, "pos" .= pos]
```

with each member `{"name": …, "ask": …}`. A `List (String × RawAsk)` needs an
explicit object shape on the wire — do not serialize it as a two-element array,
because the corpus is read by humans.

### 1.6 Elaboration

A new derived combinator in `Agentic/Core/Plan.lean`, beside `panel`:

```lean
def panelText (parts : List (String × Plan Γ (El .text))) : Plan Γ (El .text) :=
  parts.foldr
    (fun p acc => zipWith (fun a rest => Dsl.block p.1 a ++ rest) p.2 acc)
    (.ret (fun _ => ""))
```

— the same right fold from the unit that `panel` is, with the fence applied to
each member as it is folded in. Two simp lemmas, mirroring `panel_nil` /
`panel_cons`.

**No `Monoid (El .text)` instance is installed.** `Plan.lean:907` declares the
monoid "**only** at `.verdict`: nothing here installs arithmetic on
`El .flag = Bool`", and the same discipline applies here for a sharper reason:
an instance at `.text` would make `Plan.panel` typecheck at `.text` and fold
member answers *unfenced*, giving the language two ways to fold a text fan, one
of which throws away the names. `panelText` is written out so that there is
exactly one.

`Check.lean` changes, all additive:

- `checkMembersText : Bindings Γ → List (String × RawAsk) → Except CheckError
  (List (String × Plan Γ (El .text)))` — `checkMembers` with the label carried
  through, each ask at `Code.text` positionally, plus the label validity and
  duplicate checks of §1.3.
- `rhsPlan`, a clause mirroring the panel clause:
  - `[]` → `.error ⟨pos, "a text panel needs at least one member", "panelText"⟩`
  - `c ≠ .text` → `.error ⟨pos, s!"{what}: a text panel fences its members'
    answers into a document, so it answers `text`, not `{codeName c}`",
    "panelText"⟩`
  - otherwise `.ok (Plan.panelText ps)`
- `bindForm`, the `graftForm` branch verbatim, exactly as `.panel` and `.call`
  take it.
- `bindKind`, both sites (`:591` and `:794`):
  `| .panelText _ _ => .ok (ann.getD Code.text)` — positional, never inferred.
- `useKindR`: `| .panelText ms _ => ms.findSome? (fun p => usePrompt x p.2.prompt)`
  — a member's prompt may mention a binding, and inference must see it.
- `rhsAsks`: `| .panelText ms _ => ms.length`. This is the guard the brief asks
  for: `rhsAsks = length members`, no more, no less.

`answerSpec` is **unchanged**. Each member is asked at `.text`, so it carries
`"Reply with the text itself and nothing else."` — the fence is applied by the
fold, not requested of the answerer, and no answerer is ever told about a tag.

### 1.7 Cost, level, size, trace

Identical in form to `panel` with the same member count, because it is the same
nodes:

| fold | `panelText` with *n* members |
| --- | --- |
| `askNodes` | *n* |
| `size` | *n* + 1 |
| `level` | `batch` if every member's prompt is closed, else `pipeline` |
| `costSummary` | *n* added to every path; **paths unchanged** |

`zipWith` is `graft`-based and reaches no `dyn` (`Plan.lean:800`), so the rung
does not move. There is no branch, so the path count does not move.

**Trace: *n* events, and the document is not one of them.** `traceIn`
(`World.hs:349`) emits one `Event c q a` per `PAskC`/`PAsk` and nothing at
`PRet`; the fold lives in the `Expr` at the `ret` leaf and is evaluated against
the `Env`. So the trace holds *n* `.text` events carrying each member's raw
reply verbatim, in member order, and the fenced document appears nowhere in it.
That is correct and worth a docstring: the trace is what was asked and what was
answered; the document is what the program then computed.

### 1.8 Guards

`Agentic.Guards` gains one line, not one constructor: `PanelEmpty` already means
"a fan with no members" and `rhsGuard` should fire it for
`RhsPanelText [] _` too. `vector-004` stays the pinned witness; a second
vector at `panelText` is worth adding but reuses the same `Guard`.

The label refusals (invalid character, duplicate) are `CheckError`s and not
`Guard`s: guards are the program-budget family, and these are well-formedness.

### 1.9 Haskell authoring surface

`Agentic/Plan.hs`, beside `panel`:

```haskell
panelText :: [(Text, Plan g Text)] -> Plan g Text
panelText = foldr (\(n, p) -> zipWithP (\a rest -> block n a <> rest)) (PRet (exprConst ""))
```

`Agentic/Builder.hs`, beside `panel`:

```haskell
panelText :: NonEmpty (Text, Ask s) -> Rhs s 'CodeText
```

`NonEmpty` for the same reason `panel` takes one: tier0 owns the empty refusal,
and tier1 must not be able to reach it. Add a line to the "deliberately absent"
list in `tier1/Cases.hs` alongside the `vector-004` note.

### 1.10 Corpus impact

**No refreeze.** Adding a `RawRhs` constructor changes no existing entry's
serialization, and no frozen entry mentions `panelText`. `lake exe corpus-gen`
must remain a no-op over the existing 128.

New fixtures (§3 has the checklist):

- a two-member `panelText`, closed prompts — pins the document bytes, the
  member order, the batch rung, `askNodes = 2`;
- a member whose body contains its own closing tag — pins the escape;
- a member whose body contains a *sibling's* closing tag — pins that the escape
  does **not** fire, which is the nesting property;
- a `panelText` at a non-`text` binder — pins the kind refusal;
- an empty `panelText` — pins `PanelEmpty`;
- duplicate labels, and an invalid label — pin the two `CheckError`s;
- string-layer vectors for `fence` (§3).

---

## Part 2 — the four deciders

### 2.1 The shape, chosen

**One new `RawRhs` constructor carrying a decider tag, a subject name, and a
list of literal needles.** Not a new `RawSource`, not a new `RawBlock` binding
form.

```lean
/-- `[[Decider]]` = the closed vocabulary of pure classifications. Four, named
in the kernel, held identically in Lean and Haskell, and closed: a fifth is a
language change and is reviewed as one. -/
inductive Decider where
  | lastNonEmptyLineIs
  | containsLine
  | anyLineStartsWith
  | anyPathMatches
  deriving Repr, DecidableEq, Inhabited
```

```lean
  /-- `decide d x [w₁, …]`: a pure classification of the text bound to `x`,
  answering `flag`. It asks nothing. -/
  | decide (d : Decider) (subject : String) (needles : List String) (pos : Pos)
```

Why `RawRhs` and not a new binding form:

- `RawRhs` is the *clause-position source* — the value position — and a decider
  is a value. Its docstring says "one question, a panel of them, or a call";
  the third of those already need not be an ask in any interesting sense.
- It reuses `bind` whole: annotation, inference, `knownHere`, the `case` that
  follows. A new `RawBlock` form would duplicate all of it.
- It works in a **function body for free**, because `RawBodyStmt.bind` takes a
  `RawRhs`. A `RawBlock` form would not, and D1's whole point is that a
  discipline lives in one function; a decider that cannot go in one is half a
  feature.

Why a **list** of needles rather than one: see §2.5 — with a single needle,
reconstructing `diffNamesHaskell` costs five bindings and a four-deep `if`
chain, which is 32 paths in `costSummary` for one classification. With a list
it is one binding and no branch at all. "Any of" is the right primitive.

Why the needles are **literal `String`s and never a `Prompt`**: a needle that
could interpolate a binding is a needle a model can author, and a decider whose
test a model chooses is not a decider — it is the same untrusted steering
`diffNamesHaskell` exists to overrule. **A decider's needles are program text,
always.** This is the safety property of the whole vocabulary and it is bought
by one field's type.

Why the subject is a **name and not a literal**: deciding a literal is a
constant the author could have written.

Why the result is a **flag and never a verdict**: nothing in incite wants one.
`decideRed` and `decideFactsResolved` are routings; `tripEnding` is a
classification. A verdict-yielding decider would manufacture a review nobody
gave, and `caseVerdict`'s `noAnswer` arm — "protocol violation" — would become
unreachable-by-construction in a way that lies about where the verdict came
from.

Refused, in the `PanelEmpty` family (§2.8): an empty needle list (always
`false`, silently) and any empty needle string (`"" isPrefixOf l` is always
`true`, silently).

`RawRhs.pos` gains `| .decide _ _ _ p => p`.

Haskell mirror:

```haskell
data Decider = LastNonEmptyLineIs | ContainsLine | AnyLineStartsWith | AnyPathMatches
  deriving (Eq, Show)

  | RhsDecide !Decider !Text ![Text] !Pos
```

JSON: `ctorObj "decide" ["decider" .= …, "subject" .= …, "needles" .= …, "pos" .= …]`,
the decider spelled by the same camel-case names as the Lean constructors, with
a `deciderName`/`deciderOfName` retraction theorem beside `codeName`/`codeOfName`
in `Syntax.lean` — same reason: an authoring surface's keyword, the checker's
diagnosis and the corpus's field must be one table.

### 2.2 The string layer: one normalization, spelled once

Every decider is defined from `Exec`'s **already-pinned** ASCII primitives plus
exactly two new ones. This is the whole conformance strategy: the divergence
surface is what is new, and what is new is small.

Already pinned, reused unchanged:

- `String.trimAscii` — drops `' '`, `'\t'`, `'\r'`, `'\n'` from both ends. Four
  characters, ASCII only (`Agentic/Text.hs:44`).
- `Char.toLower` — shifts `A`–`Z` by 32 and leaves every other code point
  alone. **Never `Data.Text.toLower`**, which is full Unicode and diverges on
  `İ` (U+0130) — an input the corpus already pins.
- `Exec.answerLines s = ((s.splitOn "\n").map (·.trimAscii.toString)).filter
  (not ·.isEmpty)` — split on `"\n"` only, trim each line, drop the blanks.
  This *is* "the non-empty lines", already frozen.

New, and the only two functions wave 3 must write from scratch on this layer:

```
-- `[[bare s]]` = `s` with the decoration characters dropped from both ends:
-- exactly five, ` * _ SPACE . (U+0060, U+002A, U+005F, U+0020, U+002E).
-- Isaac's set (`lastNonEmptyLine`, Feature.hs), adopted whole, because models bold and
-- backtick their markers and a decider that misses `**WORK COMPLETE**` misses
-- the common case. incite's test/Spec.hs:337 pins the negative half:
-- ?!:;,)]}>"'#~-+= must NOT be dropped.
bare : String → String

-- `[[fields s]]` = the maximal runs of non-ASCII-whitespace in `s`, in order,
-- dropping empties. NOT `Exec.words`, which norms and splits on
-- non-alphanumerics and would shatter `a/Foo.hs` into ["a","foo","hs"].
fields : String → List String
```

**The one normalization rule, uniform across all three line deciders:**

> A **line** is trimmed (by `answerLines`), then `bare`d, then ASCII-lowercased.
> A **needle** is ASCII-lowercased and nothing else.

Stated as functions:

```
dlines s = (Exec.answerLines s).map (fun l => (bare l).toLower)
dneedle w = w.toLower
```

The asymmetry is deliberate and load-bearing in one direction: a needle is
**not** trimmed and **not** `bare`d, so a trailing space in a needle survives.
That is what lets `anyLineStartsWith ["✗ "]` reconstruct `isRed` faithfully —
incite pins `isRed "✗" == False` (test/Spec.hs:546), and a needle-trimming rule
would silently widen it to match a bare `✗`. For the two equality deciders a
needle with a trailing space simply never matches, which is correct: a `bare`d
line has no trailing space, so the author's stray space is a visible bug rather
than a hidden one.

Case folding is applied on both sides for all three line deciders. Relative to
incite this **widens** `decideFactsResolved` and `isRed`, which are
case-sensitive there. The widening is uniformly in the safe direction: both
return "refuse / it is red", so folding case can only make a refusal more
likely, never less. Recorded as a deliberate divergence.

**A second deliberate divergence, and it is a bug fix.** incite's `tripEnding`
filters for non-blank with `T.strip` but keeps the *unstripped* line, then
`dropAround`s a set that contains neither `\r` nor `\t`. So a CRLF worker whose
last line is `WORK COMPLETE\r` classifies as `EndViolation` — the run dies on a
line ending. Here `answerLines` trims ASCII whitespace *before* `bare` runs, so
CRLF classifies correctly. Wave 3 must write this down at the definition so
nobody "restores fidelity" and reintroduces it.

### 2.3 The four algorithms, in full

```
lastNonEmptyLineIs ws s  =  match (dlines s).getLast? with
                            | none   => false
                            | some l => ws.any (fun w => l == dneedle w)

containsLine ws s        =  (dlines s).any (fun l => ws.any (fun w => l == dneedle w))

anyLineStartsWith ws s   =  (dlines s).any (fun l => ws.any (fun w => (dneedle w).isPrefixOf l))

anyPathMatches gs s      =  (headerPaths s).any (fun p => gs.any (fun g => matchGlob g p))
```

with

```
diffHeaders : List String :=
  ["diff --git ", "+++ ", "--- ", "rename from ", "rename to "]

-- The paths a diff *header* names. Case-SENSITIVE and NOT lowercased: git
-- writes these prefixes exactly, and paths are case-significant.
headerPaths s =
  (Exec.answerLines s).filter (fun l => diffHeaders.any (·.isPrefixOf l))
  |>.flatMap fields
```

Notes that decide the edge cases, each one a place the two languages could
otherwise drift:

- **`getLast?` on `dlines`** is literally "the last non-empty line", because
  `answerLines` has already dropped the blanks. Empty input and whitespace-only
  input both give `[]` → `none` → `false`. This matches incite's
  `EndViolation`-on-empty.
- **`diffHeaders`' trailing spaces are significant**: a bare markdown rule
  `---` or `+++` is not a header. Copied from incite exactly.
- **`headerPaths` prefix-tests the *trimmed* line** (via `answerLines`), where
  incite tests the raw line. This makes an indented header — a diff quoted
  inside a fenced block, which is how a diff normally reaches a prompt —
  visible where incite's is blind. The direction is loud: more paths found
  means the expensive lens runs more often, and G3's whole point is that the
  false-negative is the costly error.
- **`headerPaths` does not lowercase, does not strip `a/`/`b/`, and does not
  special-case `/dev/null`.** No path surgery at all: `/dev/null` matches no
  extension glob and is inert, exactly as in incite. `*` crossing `/` (below) is
  what makes prefix-stripping unnecessary.
- **`fields` and not `Exec.words`.** Stated again because it is the single
  easiest mistake to make here: `Exec.words` would lowercase and destroy paths.

**`matchGlob`, normative spelling** — structural, with a measure that shrinks in
every branch, so it ports to Lean without `WellFounded.fix`:

```
matchGlob (pat str : String) : Bool := go pat.data str.data
where
  go : List Char → List Char → Bool
  | [],        xs      => xs.isEmpty
  | '*' :: ps, []      => go ps []
  | '*' :: ps, x :: xs => go ps (x :: xs) || go ('*' :: ps) xs
  | '?' :: ps, _ :: xs => go ps xs
  | '?' :: _,  []      => false
  | p   :: ps, x :: xs => p == x && go ps xs
  | _   :: _,  []      => false
  termination_by ps xs => ps.length + xs.length
```

`*` matches any run **including `/`**; `?` matches exactly one character and
never the empty string; every other character is literal; the match is
**case-sensitive** and anchored at both ends.

That `*` crosses `/` is not an oversight, it is the mechanism: it is what makes
`*.hs` match `a/Foo.hs` and `b/src/Bar.hs` without any `a/`-stripping, which is
how one glob replaces incite's untargeted suffix test. Checked against the two
cases that matter: `matchGlob "*.hs" "x.lhs"` is `false` (as `.hs` is not a
suffix of `x.lhs`), and `matchGlob "*.hs" ".hs"` is `true`.

This denotes the same relation as agent-functor's `matchGlob` (`Grant.hs:75`),
which is written as a linear greedy two-pointer with one backtrack point
*because its patterns come from untrusted input*. Ours do not — §2.1 rules the
needles to be program-authored literals — so the naive form's theoretical
blow-up is unreachable and the simpler, provably-terminating spelling wins.
Wave 3 should say so at the definition, and should carry a corpus vector for
the multi-star case anyway.

### 2.4 Elaboration, and the fact that a decider is free

`Check.lean`, `rhsPlan`, a fourth clause. The decider's value is a `.ret` of an
`Expr Γ Bool` built from the subject's binding:

```lean
| .decide d x ws pos =>
  -- refuse ws = [] and any "" ∈ ws here (§2.8)
  match c with
  | .flag =>
    match lookupBinding S pos x with
    | .error err => .error err
    | .ok b =>
      match b.at? Code.text with
      | some e => .ok (.ret (fun γ => Decider.run d ws (e γ)))
      | none   => .error ⟨pos, s!"a decider reads `text`, and `{x}` answers
                                `{codeName b.code}`", x⟩
  | c => .error ⟨pos, s!"{what}: a decider answers `flag`, not `{codeName c}`",
                 "decide"⟩
```

`bindForm` takes the `graftForm` branch verbatim, like `.panel` and `.call`.

`bindKind` (both sites): `| .decide _ _ _ _ => .ok (ann.getD Code.flag)`.

`useKindR`: `| .decide _ x' _ _ => if x' == x then some Code.text else none` —
so a decider **grounds its subject's kind**. `y <- ask …` with no annotation
followed by `f <- decide lastNonEmptyLineIs y ["WORK COMPLETE"]` infers
`y : text`, which is the ergonomic that makes the vocabulary pleasant to use.

`rhsAsks`: `| .decide _ _ _ _ => 0`.

**A decider costs nothing in every fold — including `size`.** The brief expects
`size` to move. It does not, and the reason is `Plan.graft_ret`
(`Agentic/Core/Plan.lean:767`):

```
graft (Plan.ret e) k = k _ Sub.id e
```

so a binding whose source is a `.ret` elaborates to
`Plan.sub k (fun δ => Env.cons (e δ) δ)` — the continuation with the value
substituted in, and **no node at all**. `Plan.sub` is a renaming and preserves
`size`, `askNodes` and `level`. Therefore:

| fold | effect of one decider binding |
| --- | --- |
| `askNodes` | 0 |
| `size` | 0 |
| `level` | unchanged (a decider does not reach the branch rung) |
| `costSummary` min/max | 0 |
| `costSummary` paths | 1× (unchanged) |
| printed `Raw` | changed — this is the only observable |

The branch a decider feeds is an ordinary `ifFlag`, which is `Plan.case` and
reaches `branch` exactly as an asked flag does, doubling the paths exactly as an
asked flag does. So the *net* effect of replacing an asked flag with a decider
is: **one fewer question on every path, same number of paths, same rung.** That
is D7's yield, and `costSummary` is unchanged in form as G3 promised — it is
unchanged in form *and strictly smaller in value*.

One consequence worth a docstring: a program of closed asks and deciders stays
at `batch`. A decider never raises the rung.

### 2.5 The `diffNamesHaskell` reconstruction, verified

incite (`Review.hs:247`):

```haskell
diffNamesHaskell input =
  or [ ext `T.isSuffixOf` w
     | l <- T.lines input
     , any (`T.isPrefixOf` l) ["diff --git ", "+++ ", "--- ", "rename from ", "rename to "]
     , w <- T.words l
     , ext <- haskellTriggerExtensions ]

haskellTriggerExtensions = [".hs", ".lhs", ".hs-boot", ".hsc", ".cabal"]
```

Here, **one binding**:

```
haskellTouched <- decide anyPathMatches diff ["*.hs", "*.lhs", "*.hs-boot", "*.hsc", "*.cabal"]
```

The correspondence is exact given §2.3: `headerPaths` reproduces the
lines-filtered-by-header-prefix-then-`T.words` structure, and `matchGlob "*<ext>"`
reproduces `T.isSuffixOf ext` because `*` crosses `/` and is anchored at the
end. So `anyPathMatches` is the decider that covers it, and it is the *only* one
that does — it is not `anyLineStartsWith`, because the test is two-level (a
prefix on the line, then a suffix on each token of that line).

**The safety property, preserved.** `routeHaskell`'s guard is a conjunction:

```haskell
| verdictWord == "none" && not (diffNamesHaskell input) = Right "No Haskell edits."
| otherwise = Left input
```

The triage model can answer a well-formed `none` while having looked in the
wrong place. `diffNamesHaskell` is the pure second opinion that overrules it,
and it is asymmetric on purpose: a false `true` costs one wasted lens run, a
false `false` costs a review that silently never happened. In agent-cat this
becomes the router's flag and the decider's flag, nested:

```
route <- ask model "triage" …            -- a flag: "is this a Haskell-free diff?"
touched <- decide anyPathMatches diff [ … ]
if touched { <lens> } else { if route { <skip> } else { <lens> } }
```

which is the conjunction written as the language writes conjunctions. Note what
this costs: 1 question (was 1), 4 paths, and the property that was **dropped
entirely** in §3's transcription is back.

The three remaining reconstructions, for the record:

| incite | agent-cat |
| --- | --- |
| `tripEnding` (4-way, Feature.hs:653) | three `lastNonEmptyLineIs` bindings — `["WORK COMPLETE"]`, `["WORK REMAINS"]`, `["WORK BLOCKED"]` — and a nested `if` chain whose final `else` is the violation arm. 0 questions, 8 paths. Today: 1 paid question per loop, and the four-way answer is a `flag` it cannot even express. |
| `isRed` (Feature.hs:833) | `anyLineStartsWith gateLog ["✗ "]`. The trailing space is preserved by §2.2's needle rule. |
| `decideFactsResolved` (Feature.hs:1594) | `anyLineStartsWith report ["FACTS PATHS UNRESOLVED"]` — one needle, prefix not equality, any line not the last, exactly as incite. |

`tripEnding`'s `EndViolation` arm and `containsLine` are the two places where
this vocabulary is honestly a little loose: an 8-path chain classifies four ways,
and `containsLine` has no ancestor. Both are stated rather than hidden.

### 2.6 String-layer conformance

The deciders and the fence join `norm`/`words`/`decodeVerdict` under the
`{"string": …}` request. The protocol extension is additive; the existing
request shape `{"op", "code"?, "text"}` is untouched, and an old oracle meeting a
new request answers `{"error": "unknown string op `…`"}`, which is a loud
failure and not a silent one.

New ops, in `Conformance.stringOp` and `Agentic.Text.stringOp` together:

| op | request fields | result |
| --- | --- | --- |
| `bare` | `text` | string |
| `fields` | `text` | array of strings |
| `headerPaths` | `text` | array of strings |
| `matchGlob` | `pattern`, `text` | bool |
| `decide` | `decider`, `needles`, `text` | bool |
| `fence` | `name`, `text` | string (the whole `block n b`) |

The four low-level ops exist so that a divergence is *localizable*: a `decide`
mismatch with `bare`, `fields`, `headerPaths` and `matchGlob` all green is a
composition bug, and with one of them red is that function's bug. This is the
same reason `norm` and `words` are pinned separately from `decode`.

`Agentic.Text`'s module header must gain the deciders to its list of "every
character predicate here is ASCII-only" — the module is the right home for all
of this, it already stands alone, and `bare`/`fields`/`matchGlob` belong beside
`trimAscii` rather than in `Agentic.Exec`.

Vectors, at minimum (§3 has the full list): the CRLF marker line, `**WORK
COMPLETE**`, a whitespace-only input, `İ` through `bare` and through a needle,
`"✗"` versus `"✗ "`, `*.hs` against `x.lhs` / `a/Foo.hs` / `.hs` / `/dev/null`,
a two-star glob, an indented `diff --git` header, and a header line whose path
contains a space.

### 2.7 The loud default — interaction point, not this design's call

G3's second proposal (an unreadable flag takes the loud arm rather than
abandoning the run) is `Agentic.Exec` policy and belongs with **D5/D6**. Two
things this design owes them:

1. **Which arm is loud is not a constant.** It depends on how the program wrote
   its `if`, so a runner cannot pick it without a per-ask annotation, and an
   annotation is a `Raw` change and therefore not cheap. The cheapest honest
   version is a `Settings` field defaulting to `false`, which agrees with
   `decodeFlag`'s existing deny-bias (`saidNo` is tested first, a *no* anywhere
   denies, a *yes* must be the whole reply).
2. **The deciders mostly retire the question.** A classification that no longer
   round-trips through an answerer cannot be unreadable. Wherever D7 lands a
   decider, the loud-default policy stops applying to that branch entirely.

### 2.8 Guards

Add one `Guard` constructor, `DeciderEmpty`, covering both an empty needle list
and any empty needle string — they are the same mistake (a test that is
constantly false, or constantly true, with nothing in the source to show it).
`rhsGuard` fires it on `RhsDecide _ _ ws _` when `null ws || any T.null ws`.

It is a `Guard` and not a `CheckError` because it is exactly the shape of
`PanelEmpty`: a well-typed program whose fan is degenerate. The Haskell builder
takes `NonEmpty Text`, so tier1 cannot reach the first half — same discipline as
`panel`, same note in `tier1/Cases.hs`.

### 2.9 Haskell authoring surface

`Agentic/Builder.hs`, following the established `combinator`/`combinatorI`
split (`ifFlag` at :987 is the model):

```haskell
decide ::
  forall h s. (KnownIx h s) =>
  Decider -> V h 'CodeText -> NonEmpty Text -> Rhs s 'CodeFlag
decide d v ws = decideI d (vName v) (readV @h @s v) ws

decideI :: Decider -> Text -> Var (Codes s) 'CodeText -> NonEmpty Text -> Rhs s 'CodeFlag
```

Taking `V h 'CodeText` makes "a decider reads text" a **type** error at the
authoring surface, so the `CheckError` of §2.4 is a tier0-only refusal — which
is the discipline `tier1/Cases.hs` already states ("every kind refusal is a type
error").

---

## Part 3 — Implementation checklist for wave 3

Ordered so that each step compiles on its own.

### Lean kernel

1. `Agentic/Core/Plan.lean` — `Plan.panelText` beside `panel`, plus
   `panelText_nil` / `panelText_cons` simp lemmas. Do **not** add
   `Monoid (El .text)`; note in the docstring why not.
2. `Agentic/Core/Exec.lean` (or a new `Agentic/Core/Decider.lean` if Exec is
   already large) — `bare`, `fields`, `headerPaths`, `diffHeaders`, `matchGlob`,
   `Decider.run`, and `Dsl.block` / `Dsl.escapeClose`. Every one ASCII-only;
   every one with the incite citation and the divergence note it owns.
3. `Agentic/Core/Dsl/Syntax.lean` — `Decider`, `deciderName`/`deciderOfName`
   with the retraction theorem, `RawRhs.panelText`, `RawRhs.decide`, and the two
   `RawRhs.pos` clauses.
4. `Agentic/Core/Dsl/Check.lean` — `checkMembersText`, label validity, duplicate
   labels; `rhsPlan` ×2 clauses; `bindForm` ×2; `bindKind` ×2 at **both** sites
   (`:591` and `:794` — the second is easy to miss); `useKindR` ×2; `rhsAsks`
   ×2. Add a `check_panelText_nil` theorem beside `check_panel_nil`.
5. Confirm by inspection that `Explain.lean`, `Cost.lean` and `Level.lean` need
   **no** edit (§0.1). If either decision seems to want one, the elaboration is
   wrong.

### Haskell mirror

6. `Agentic/Raw.hs` — `Decider`, `RhsPanelText`, `RhsDecide`, `ToJSON`/`FromJSON`
   both, `rhsPos`.
7. `Agentic/Text.hs` — `bare`, `fields`, `headerPaths`, `matchGlob`,
   `runDecider`, `block`, `escapeClose`; extend `stringOp` with the six new ops;
   update the module header's ASCII-only paragraph.
8. `Agentic/Plan.hs` — `panelText`.
9. `Agentic/Builder.hs` — `panelText :: NonEmpty (Text, Ask s) -> Rhs s 'CodeText`,
   `decide`/`decideI`; export both; extend the `zeroAsk` traversal (:346) to the
   two new constructors — **this is easy to miss and tier1 zeroes positions
   through it**.
10. `Agentic/Guards.hs` — `DeciderEmpty`; `rhsGuard` for `RhsPanelText []` →
    `PanelEmpty` and for degenerate `RhsDecide` → `DeciderEmpty`; update the
    precedence documentation block at :249–:278.
11. `Agentic/Oracle.hs` — a request builder for the new string ops; keep the
    argument order identical to `Agentic.Text.stringOp`'s, for the reason its
    docstring already gives.

### Corpus and tests

12. New program fixtures under `test/corpus/`: the seven `panelText` entries of
    §1.10 and, for D7, one per decider at a minimum plus the
    `diffNamesHaskell` five-glob reconstruction, a decider inside a function
    body, a decider grounding its subject's kind by inference, the
    `DeciderEmpty` vectors, and a decider-fed `if` whose `costSummary` is
    checked to have the same paths and one fewer question than the asked-flag
    version of the same program. That last one is the fixture that *proves* D7's
    yield rather than asserting it.
13. New string-layer vectors: the list in §2.6, plus `fence` vectors for the
    empty body, the self-closing-tag body, and the sibling-closing-tag body.
14. `lake exe corpus-gen && git status --short test/corpus` must print nothing
    for the existing 128 entries. **No refreeze** — if one appears, the
    elaboration touched something it should not have.
15. `tier1/Cases.hs` — rebuild the new checked entries; extend the "deliberately
    absent" list with the empty `panelText`, the duplicate label, the empty
    needle list and the wrong-kind subject.

### Documentation

16. Correct §4 G3/G8 and §6 D2/D7 of `doc/research/isaac-workflows.md` for the
    five findings of §0 — in particular the `Explain.lean` cost claim, the
    Feature.hs locations, the non-existent `greenGateBrief`/`factsGateBrief`,
    the non-existent `agent-functor` `diffNames`, and `containsLine`'s missing
    ancestor.
17. Every new string function carries its incite citation **by symbol name and
    file**, not by line number — D11 is on this same slate and a new stale
    citation would be a self-inflicted wound.

### Interaction points with the sibling designs

- **D1/D8** — a decider in a function body needs nothing from D1 (it rides
  `RawBodyStmt.bind`), but D1's `Params` threading must not special-case
  `RawRhs`'s constructor list; both new constructors must appear in whatever
  traversal D1 adds.
- **D3/D4** — `revisingYielding`'s yielded candidate is a `text` handle, which
  is exactly a decider's subject. The natural composition is
  `unsettled c { ok <- decide lastNonEmptyLineIs c [...] ; if ok { … } }`, and
  it needs no coordination beyond both landing.
- **D5/D6** — the loud default (§2.7), and D5's program-authored argv produces
  a receipt whose text is exactly what `anyLineStartsWith` is for. If both land,
  `greenGate` is reconstructible end to end: a `tool` party runs the checks, the
  World authors the receipt, and `anyLineStartsWith [«✗ »]` reads it — with no
  question paid and no answerer able to lie about the exit code.
