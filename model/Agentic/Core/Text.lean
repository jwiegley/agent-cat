/-!
# The string layer: the bytes the language decides about

The Haskell mirror of this module is `dsl/src/Agentic/Text.hs`, and the
division is the same one: **every character predicate here is ASCII-only**, on
purpose and by construction. Nothing below calls a Unicode-aware primitive; the
one place a full-Unicode `toLower` would silently disagree between the two
implementations (`İ`, U+0130) is pinned by the corpus's string-layer vectors.

Three groups of declarations live here, and they are together because they are
all *decisions about what bytes mean* and because they must sit **below**
`Agentic/Core/Plan.lean` in the import graph — `Plan.panelText` folds with
`Dsl.block`, and `Dsl.Decider.run` is the meaning of a `RawRhs` constructor.

* `Exec.answerLines` — the nonblank ASCII-trimmed lines of a reply. It used to
  live in `Agentic/Core/Exec.lean` beside `norm` and `words`; it moved here
  unchanged, under the same name, because the deciders are defined from it and
  they must be visible to the checker. Its corpus pins are unaffected.
* `Exec.bare`, `Exec.fields`, `Exec.diffHeaders`, `Exec.headerPaths`,
  `Exec.matchGlob` — the primitives the four deciders (D7) are composed from.
  Each is pinned separately by a string-layer vector, so that a `decide`
  mismatch with all four green is a composition bug and with one red is that
  function's bug: the same reason `norm` and `words` are pinned apart from
  `decode`.
* `Dsl.escapeClose`, `Dsl.block`, `Dsl.validLabel` — the fence a `panelText`
  (D2) folds its members into, and what a label may be spelled with.

Every citation below names an incite symbol **by symbol name and file**, never
by line number.
-/

namespace Agentic.Core

namespace Exec

/-- `[[answerLines s]]` = the nonblank lines of `s`, each ASCII-trimmed: the
objections a reviewer raised, one per line, with the blank lines a model likes
to emit discarded.

Split on `"\n"` only, trim each line, drop the blanks. This *is* "the non-empty
lines" for every decider below, and trimming **before** anything else is what
makes a CRLF worker's `WORK COMPLETE\r` classify correctly — see `bare`. -/
def answerLines (s : String) : List String :=
  ((s.splitOn "\n").map (fun l => l.trimAscii.toString)).filter (fun l => !l.isEmpty)

/-- The five decoration characters `bare` drops: `` ` ``, `*`, `_`, a space and
`.` (U+0060, U+002A, U+005F, U+0020, U+002E).

Isaac's set, from `lastNonEmptyLine` in incite's `Incite/Feature.hs`, adopted
whole, because models bold and backtick their markers and a decider that misses
`**WORK COMPLETE**` misses the common case. The negative half is pinned by
incite's own spec: `?!:;,)]}>"'#~-+=` must **not** be dropped, and none of them
is here. -/
def bareChar (ch : Char) : Bool :=
  ch == '`' || ch == '*' || ch == '_' || ch == ' ' || ch == '.'

/-- `[[bare s]]` = `s` with the decoration characters dropped from both ends.

**A deliberate divergence from incite, and it is a bug fix.** incite's
`tripEnding` filters for non-blank with a strip but keeps the *unstripped* line,
then drops a set containing neither `\r` nor `\t` — so a CRLF worker whose last
line is `WORK COMPLETE\r` classifies as a protocol violation and the run dies on
a line ending. Here `answerLines` trims ASCII whitespace *before* `bare` runs,
so CRLF classifies correctly. Do not "restore fidelity" and reintroduce it. -/
def bare (s : String) : String :=
  String.ofList (((s.toList.dropWhile bareChar).reverse.dropWhile bareChar).reverse)

/-- The four ASCII whitespace characters `fields` splits on — the same four
`String.trimAscii` strips, written out so the two implementations cannot drift
onto a Unicode-aware predicate. -/
def asciiSpace (ch : Char) : Bool :=
  ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r'

/-- `[[fields s]]` = the maximal runs of non-ASCII-whitespace in `s`, in order,
dropping empties.

**Not `Exec.words`**, and this is the single easiest mistake to make in the
decider layer: `words` normalizes and splits on non-alphanumerics, so it would
shatter `a/Foo.hs` into `["a", "foo", "hs"]` and destroy every path. `fields`
lowercases nothing and splits on whitespace alone. -/
def fields (s : String) : List String :=
  let flush : List Char → List String → List String := fun cur acc =>
    if cur.isEmpty then acc else String.ofList cur :: acc
  let go := s.toList.foldr
    (fun ch (p : List Char × List String) =>
      if asciiSpace ch then (([] : List Char), flush p.1 p.2) else (ch :: p.1, p.2))
    (([], []) : List Char × List String)
  flush go.1 go.2

/-- The five line prefixes that introduce a path in a diff. **The trailing
spaces are significant**: a bare markdown rule `---` or `+++` is not a header.
Copied exactly from `diffNamesHaskell` in incite's `Incite/Review.hs`. -/
def diffHeaders : List String :=
  ["diff --git ", "+++ ", "--- ", "rename from ", "rename to "]

/-- `[[headerPaths s]]` = the paths a diff *header* names.

Case-**sensitive** and not lowercased: git writes these prefixes exactly, and
paths are case-significant. No path surgery at all — no `a/`/`b/` stripping and
no `/dev/null` special case, because `*` crosses `/` in `matchGlob` and
`/dev/null` matches no extension glob and is inert.

**A second deliberate divergence:** the prefix test runs against the *trimmed*
line (via `answerLines`), where incite tests the raw one. That makes an indented
header — a diff quoted inside a fenced block, which is how a diff normally
reaches a prompt — visible where incite's is blind. The direction is loud: more
paths found means the expensive lens runs more often, and the false negative is
the costly error. -/
def headerPaths (s : String) : List String :=
  ((answerLines s).filter (fun l => diffHeaders.any (fun h => h.isPrefixOf l))).flatMap fields

/-- The glob matcher's worker, over character lists.

`*` matches any run **including `/`**; `?` matches exactly one character and
never the empty string; every other character is literal; the match is
case-sensitive and anchored at both ends.

That `*` crosses `/` is not an oversight, it is the mechanism: it is what makes
`*.hs` match `a/Foo.hs` and `b/src/Bar.hs` with no `a/`-stripping, so one glob
replaces incite's untargeted suffix test.

This denotes the same relation as `matchGlob` in agent-functor's
`Agent/Grant.hs`, which is written as a linear greedy two-pointer with one
backtrack point *because its patterns come from untrusted input*. Ours do not —
a decider's needles are program-authored literals, by the type of the field — so
the naive form's theoretical blow-up is unreachable and the simpler,
provably-terminating spelling wins. -/
def globGo : List Char → List Char → Bool
  | [], xs => xs.isEmpty
  | '*' :: ps, [] => globGo ps []
  | '*' :: ps, x :: xs => globGo ps (x :: xs) || globGo ('*' :: ps) xs
  | '?' :: ps, _ :: xs => globGo ps xs
  | '?' :: _, [] => false
  | p :: ps, x :: xs => p == x && globGo ps xs
  | _ :: _, [] => false
termination_by ps xs => ps.length + xs.length

/-- `[[matchGlob pat str]]` = does the glob `pat` match the whole of `str`? -/
def matchGlob (pat str : String) : Bool := globGo pat.toList str.toList

/-- The one normalization rule, half one: **a line** is trimmed (by
`answerLines`), then `bare`d, then ASCII-lowercased. -/
def dlines (s : String) : List String := (answerLines s).map (fun l => (bare l).toLower)

/-- …and half two: **a needle** is ASCII-lowercased and nothing else.

The asymmetry is deliberate and load-bearing in one direction: a needle is not
trimmed and not `bare`d, so a trailing space in a needle survives, which is what
lets `anyLineStartsWith ["✗ "]` reconstruct incite's `isRed` faithfully — it
pins `isRed "✗" == False`, and a needle-trimming rule would silently widen it.
For the two equality deciders a needle with a trailing space simply never
matches, which is correct: a `bare`d line has no trailing space, so the author's
stray space is a visible bug rather than a hidden one.

Case folding is applied on both sides for all three line deciders. Relative to
incite this **widens** `decideFactsResolved` and `isRed`, which are
case-sensitive there; the widening is uniformly in the safe direction, since
both return "refuse / it is red" and folding case can only make a refusal more
likely. -/
def dneedle (w : String) : String := w.toLower

end Exec

namespace Dsl

/-- `[[escapeClose n b]]` = `b` with every occurrence of this fence's own
closing tag defanged by one backslash after the `<`.

A member's answer is a model's text. If it may contain `</alpha>`, a member can
forge the end of its own block and open a block of its own choosing, and the
synthesis that reads the document is steered by a member. So: **do not trust the
body.**

Why *only* the fence's own closing tag and not all of `</`: it preserves nesting
exactly — an inner document's `</a>`, `</b>` pass through an outer `<outer>`
fence untouched — and the mangled case, an inner member sharing a name with an
enclosing fence, is precisely the ambiguous one, where mangling is the safe
resolution. Left to right, non-overlapping, and the replacement cannot contain
the needle, so no re-scan question arises; the needle is non-empty because
`validLabel` forbids an empty label. -/
def escapeClose (n b : String) : String :=
  b.replace ("</" ++ n ++ ">") ("<\\/" ++ n ++ ">")

/-- `[[block n b]]` = one member's answer, fenced under its own name:
`"<" ++ n ++ ">\n" ++ escapeClose n b ++ "\n</" ++ n ++ ">\n"`.

XML-shaped and newline-delimited, against `## heading` (a heading marks a start
with nothing marking the end, so a reader of the fold cannot tell where a member
stopped) and against custom brackets (which buy nothing on collision and lose
the one advantage the XML shape has: it is the delimiter every addressee in this
system has seen ten thousand times, and this document is read by a *model*).

**The body is verbatim** — no trim, no normalization — which is forced, because
`.text` already decodes verbatim and a fold that trimmed would put a second,
contradictory rule about text into the language. -/
def block (n b : String) : String :=
  "<" ++ n ++ ">\n" ++ escapeClose n b ++ "\n</" ++ n ++ ">\n"

/-- `[[validLabel n]]` = may `n` name a `panelText` member's block?

Non-empty, beginning with an ASCII letter, every character ASCII alphanumeric or
`-`, `_`, `.`. This is what makes `</name>` an unambiguous byte string to search
for, and it forbids `<`, `>` and `/` inside a tag by construction. -/
def validLabel (n : String) : Bool :=
  match n.toList with
  | [] => false
  | c :: cs =>
    c.isAlpha && (c :: cs).all (fun ch => ch.isAlphanum || ch == '-' || ch == '_' || ch == '.')

end Dsl

end Agentic.Core
