import Agentic.Core.DslFlagship

/-!
# The DSL, driven end to end: the complete battery

Run from the repository root:

```
lake exe dsl_smoke
```

Two layers, and what "complete" means for each.

* **`batteryCases`** — one case per behavior of the surface: every grammar
  production accepted by a program that uses it, and every refusal site in
  `Agentic/Core/Dsl/{Parse,Check}.lean` reached by a program that trips it,
  checked against its *whole* rendered diagnosis, position included, because a
  message that moves is a message a reader cannot act on. The case list was
  cross-checked mechanically against the refusal-site inventory of both
  modules: every `.error` in the parser and the checker is hit, with two
  classes of exception named below rather than hidden.

  1. *The six fuel branches* (`internal: … budget exhausted`) are unreachable
     by the budget invariant — every recursion is seeded with the input's
     length and every step consumes at least one item — which is documented,
     not proved, in `Agentic/Core/DslFlagship.lean`'s "What is not proved".
  2. *`a panel needs at least one member`* is unreachable from source text —
     the parser cannot produce an empty member list — and guards the
     hand-built-`Raw` entry point, so it is tested here against a hand-built
     `Raw`.

* **The semantic sections** — what a table of sources cannot say: that the
  flagship parses to the `Raw` the kernel proofs are about; that the verdict
  arms reach *distinct* arms through parsed source (the ∀-statement is
  `Dsl.checkBlock_caseVerdict_arms`; this is its fixture witness, and the one
  that would catch the arms' *words* drifting); what a `{v}` hole splices in each of a verdict's
  three states; that an `--define` override changes exactly the words it names
  and refuses a name the program never defined; that a source-chosen recursion
  depth is affordable at the bound (with a wall clock, because the exponential
  it guards against was real); that `independent draw` reaches the question;
  and that a text block and its quoted spelling are one program.
-/

open Agentic.Core
open Agentic.Core.Dsl

/-- One assertion, reported the way the other smoke tests report theirs. -/
def check (what want got : String) : IO Unit :=
  if want == got then pure () else
    throw <| IO.userError s!"FAIL {what}\n  want: {want}\n  got:  {got}"

/-- …and one that only has to hold. -/
def checkTrue (what : String) (b : Bool) : IO Unit :=
  if b then pure () else throw <| IO.userError s!"FAIL {what}"

/-- The outcome of a source text, as one line: `ok` or the diagnosis. -/
def outcome (src : String) : String :=
  match parseAndCheck src with
  | .ok _ => "ok"
  | .error e => e

/-- …and the same reading, with modules handed over the way the CLI hands
them. -/
def outcomeM (mods : List (String × String)) (src : String) : String :=
  match parseAndCheckProgramWith [] mods src with
  | .ok _ => "ok"
  | .error e => e.render

/-! ## The battery: every construction, and every mistaken use of one -/

/-- One function of each result kind, shared by the round-sixteen call cases.
Eleven lines, so a workflow appended to it always begins at line 12 — the
positions in the expected diagnoses count on that. -/
def fnsPre : String :=
  "function mk (goal : text) -> text {\n" ++
  "  d <- ask model \"author\" \"draft: {goal}\"\n" ++
  "  answer d\n}\n" ++
  "function judged (patch : text) -> verdict {\n" ++
  "  v <- ask model \"judge\" \"judge: {patch}\"\n" ++
  "  answer v\n}\n" ++
  "function applied (patch : text) -> receipt {\n" ++
  "  ask tool \"apply\" \"apply: {patch}\"\n}\n"

/-- A small library — a define, a function, one annotated priming binding —
shared by the module cases. -/
def libOk : String :=
  "define greeting = \"hello\"\n" ++
  "function drafted (goal : text) -> text {\n" ++
  "  d <- ask model \"author\" \"draft: {goal}\"\n" ++
  "  answer d\n}\n" ++
  "guide : text <- ask tool \"cat\" \"style guide\"\n"

/-- A chain of functions whose questions double per link: `f1` is one ask and
`f(i+1)` calls `f i` twice, so `f n` inlines to `2^(n-1)` questions — the
cheapest source text that outgrows `maxQuestions`. `f1` is four lines and each
later link five, so `f n`'s header sits at line `5n - 5` for `n ≥ 2`. -/
def chain (n : Nat) : String := Id.run do
  let mut s := "function f1 (p : text) -> text {\n  d <- ask model \"m\" \"1: {p}\"\n  answer d\n}\n"
  for i in [2:n+1] do
    s := s ++ s!"function f{i} (p : text) -> text \{\n  a <- f{i-1} p\n  b <- f{i-1} a\n  answer b\n}\n"
  return s

def batteryCases : List (String × String × String) :=
[
  ("hole unterminated in a string",
   "workflow { g : text <- ask tool \"t\" \"hm {name oops\" }",
   "1:41: unterminated hole: no closing brace at `name`"),
  ("hole with a non-name body",
   "workflow { g : text <- ask tool \"t\" \"hm {not a name}\" }",
   "1:41: unterminated hole: no closing brace at `not`"),
  ("hole against the end of the source",
   "workflow { g : text <- ask tool \"t\" ```\n  hm {name",
   "1:37: this fence of 3 backticks is never closed"),
  ("the retired sigil is not a hole",
   "workflow { ask tool \"t\" \"do {$spec}\" }",
   "1:29: a hole is `{name}`; a literal brace is written `\\{`"),
  ("an unterminated string literal",
   "workflow { g : text <- ask tool \"t\" \"never ends }",
   "1:50: unterminated string literal"),
  ("an unterminated escape",
   "workflow { g : text <- ask tool \"t\" \"ends in \\",
   "1:46: unterminated escape in a string literal"),
  ("an unknown escape",
   "workflow { g : text <- ask tool \"t\" \"bad \\q escape\" }",
   "1:42: unknown escape; the escapes are \\n \\t \\r \\\\ \\\" and the two braces at `\\q`"),
  ("all seven escapes are accepted",
   "workflow { ask tool \"t\" \"a\\n b\\t c\\r d\\\\ e\\\" f\\{ g\\}\" }",
   "ok"),
  ("a fence the source never closes",
   "workflow {\n  g : text <- ask tool \"t\" ```\n    line one\n}",
   "2:28: this fence of 3 backticks is never closed"),
  ("a fence whose last line has no newline",
   "workflow {\n  g : text <- ask tool \"t\" ```\n    a\n  ``",
   "2:28: this fence of 3 backticks is never closed"),
  ("a block mixing tabs and spaces",
   "workflow {\n  g : text <- ask tool \"t\" ```\n    a\n\tb\n  ```\n}",
   "2:28: this block mixes tabs and spaces in its indentation"),
  ("text after the opening fence",
   "workflow {\n  g : text <- ask tool \"t\" ```md\n    a\n  ```\n}",
   "2:28: expected a string literal or a text block at ````md`"),
  ("an opening fence at the end of the source",
   "workflow {\n  g : text <- ask tool \"t\" ```",
   "2:28: this fence of 3 backticks is never closed"),
  ("a fence of fewer than three backticks",
   "workflow {\n  g : text <- ask tool \"t\" ``\n    a\n  ``\n}",
   "2:28: a text block opens with three or more backticks at ````"),
  ("an escalated fence holds an inner fence",
   "define spec = \"S\"\nworkflow {\n  g <- ask tool \"t\" ````\n    a \\{brace} and \\}close \"quoted\"\n\n    ```\n    fenced\n    ```\n    {spec}\n  ````\n  ask tool \"log\" \"{g}\"\n}",
   "ok"),
  ("a block of only blank lines is the empty prompt",
   "workflow {\n  ask tool \"t\" ```\n\n  ```\n}",
   "ok"),
  ("CRLF content behaves as LF",
   "workflow {\n  ask tool \"t\" ```\r\n    a\r\n    b\r\n  ```\r\n}",
   "ok"),
  ("a stray angle bracket",
   "workflow { g < ask }",
   "1:14: stray `<`; `<-` binds an answer, and nothing else in the language begins with one at `<`"),
  ("an unexpected character",
   "workflow { g : text <- ask tool \"t\" \"hi\" ; }",
   "1:42: unexpected character at `;`"),
  ("comments run to the end of the line",
   "-- leading comment\nworkflow { -- inner comment\n  ask tool \"t\" \"hi\" -- trailing\n}",
   "ok"),
  ("a duplicate define",
   "define a = \"x\"\ndefine a = \"y\"\nworkflow { stop }",
   "2:1: this name is already defined, and the earlier body would silently win; one define per name at `a`"),
  ("an answer hole inside a define",
   "define a = \"x {later}\"\nworkflow { stop }",
   "1:12: a define is literal text: only holes naming earlier defines are legal in one at `a`"),
  ("a binder may not spell a define",
   "define a = \"x\"\nworkflow { a : text <- ask tool \"t\" \"hi\" }",
   "2:12: a binder may not spell a define; one of the two must be renamed at `a`"),
  ("a loop carrier may not spell a define",
   "define c = \"x\"\nworkflow { d : text <- ask model \"a\" \"draft\"\n           r <- revising d as c, at most 1 amendment {\n             v <- ask model \"m\" \"review {c}\"\n             amend c { ask model \"a\" \"fix {c} {v}\" }\n           }\n           case r { settled x { stop } unsettled { stop } } }",
   "3:17: a loop's carrier may not spell a define; one of the two must be renamed at `c`"),
  ("a define missing its equals sign",
   "define a \"x\"\nworkflow { stop }",
   "1:10: expected `=` at `\"…\"`"),
  ("a define missing its body",
   "define a =\nworkflow { stop }",
   "2:1: expected a string literal or a text block at `workflow`"),
  ("a define holed like any other name",
   "define spec = \"x\"\nworkflow { ask tool \"t\" \"do {spec}\" }",
   "ok"),
  ("a define holing an earlier define",
   "define a = \"A\"\ndefine b = \"b sees {a}\"\nworkflow { ask tool \"t\" \"{b}\" }",
   "ok"),
  ("a define written as a text block",
   "define spec = ```\n  a spec\n  of two lines\n```\nworkflow { ask tool \"t\" \"{spec}\" }",
   "ok"),
  ("a source that does not begin with workflow is a library, and stop is not priming",
   "stop",
   "1:1: a library's priming is a prefix of every importing program, so it is straight-line: bindings, acts and calls only at `stop`"),
  ("tokens after the workflow",
   "workflow { stop } trailing",
   "1:19: expected the end of the source after the workflow at `trailing`"),
  ("empty braces",
   "workflow { }",
   "1:10: a path that does nothing says so: write `stop` at `{`"),
  ("stop must end its block",
   "workflow { stop ask tool \"t\" \"hi\" }",
   "1:17: expected `}` at `ask`"),
  ("the source ends inside the workflow",
   "workflow { ask tool \"t\" \"hi\"",
   "0:0: expected a statement: a binding (`x <- …`), an act (`ask …`), a call, `if`, `case`, `known here:`, or `stop`, but the source ended"),
  ("a statement that is not one",
   "workflow { [ }",
   "1:12: expected a statement: a binding (`x <- …`), an act (`ask …`), a call, `if`, `case`, `known here:`, or `stop` at `[`"),
  ("an unbound name in a prompt",
   "workflow { g : text <- ask tool \"cat\" \"read {nowhere}\" }",
   "1:24: unbound name; nothing in scope answers to it at `nowhere`"),
  ("a name with nothing to fix its kind",
   "workflow { g <- ask tool \"cat\" \"hi\" }",
   "1:12: nothing fixes what kind of answer `g` names: use it (a hole, an `if`, a `case`), or annotate it — `g : text <- …` at `g`"),
  ("the first use fixes the kind; a later if disagrees",
   "workflow { g <- ask tool \"cat\" \"hi\"\n           n : text <- ask tool \"t\" \"{g}\"\n           if g { stop } else { stop } }",
   "3:12: an `if` branches on a flag, but `g` answers `text` at `g`"),
  ("an annotation that is not a kind",
   "workflow { g : word <- ask tool \"t\" \"hi\" }",
   "1:16: expected an answer kind: `text`, `verdict`, `flag` or `receipt` at `word`"),
  ("a binder missing its arrow",
   "workflow { g : text ask tool \"t\" \"hi\" }",
   "1:21: expected `<-` at `ask`"),
  ("an annotation missing its kind",
   "workflow { g : <- ask tool \"t\" \"hi\" }",
   "1:16: expected an answer kind at `<-`"),
  ("shadowing a live name",
   "workflow { g : text <- ask tool \"c\" \"a\"\n           g : text <- ask tool \"c\" \"b\" }",
   "2:12: this name is already in scope, and a live name is not introduced twice; rename one of the two at `g`"),
  ("a dead name is reusable",
   "workflow { ok : flag <- ask person \"o\" \"?\"\n           if ok { g : text <- ask tool \"c\" \"a\"\n                   ask tool \"log\" \"{g}\" }\n           else  { g : text <- ask tool \"c\" \"b\"\n                   ask tool \"log\" \"{g}\" } }",
   "ok"),
  ("every kind may be annotated",
   "workflow { t : text <- ask tool \"a\" \"t\"\n           v : verdict <- ask model \"b\" \"v\"\n           f : flag <- ask person \"c\" \"f\"\n           r : receipt <- ask tool \"d\" \"r\"\n           ask tool \"log\" \"{t} {v}\"\n           if f { stop } else { stop } }",
   "ok"),
  ("a flag has no text to splice",
   "workflow { ok : flag <- ask person \"o\" \"hi\"\n           g : text <- ask tool \"cat\" \"quoting {ok}\" }",
   "2:24: only a text or a verdict answer interpolates into a prompt — a verdict splices as its objections — but `ok` answers `flag`, which has no text of its own at `ok`"),
  ("a receipt has no text to splice",
   "workflow { r : receipt <- ask tool \"o\" \"go\"\n           g : text <- ask tool \"cat\" \"quoting {r}\" }",
   "2:24: only a text or a verdict answer interpolates into a prompt — a verdict splices as its objections — but `r` answers `receipt`, which has no text of its own at `r`"),
  ("an addressee that is not one",
   "workflow { g : text <- ask robot \"r\" \"hi\" }",
   "1:28: expected an addressee: `model`, `tool` or `person` at `robot`"),
  ("an ask against the end of the source",
   "workflow { g : text <- ask",
   "0:0: expected an addressee: `model`, `tool` or `person`, but the source ended"),
  ("an addressee name is written, not computed",
   "workflow { g : text <- ask tool \"{g}\" \"hi\" }",
   "1:33: a name here is written, not computed: no holes"),
  ("a served-by name is written, not computed",
   "workflow { g : text <- ask model \"a\" served by \"{g}\" \"hi\" }",
   "1:48: a name here is written, not computed: no holes"),
  ("served by on a tool",
   "workflow { g : text <- ask tool \"cat\" served by \"deep\" \"hi\" }",
   "1:39: `served by` names the model that serves a model addressee; a tool or a person is not served by one at `served`"),
  ("served by on a person",
   "workflow { g : text <- ask person \"o\" served by \"deep\" \"hi\" }",
   "1:39: `served by` names the model that serves a model addressee; a tool or a person is not served by one at `served`"),
  ("served missing its by",
   "workflow { g : text <- ask model \"a\" served \"deep\" \"hi\" }",
   "1:45: expected `by` at `\"…\"`"),
  ("independent missing its draw",
   "workflow { g : text <- ask model \"a\" independent 1 \"hi\" }",
   "1:50: expected `draw` at `1`"),
  ("a draw that is not a number",
   "workflow { g : text <- ask model \"a\" independent draw x \"hi\" }",
   "1:55: expected a number at `x`"),
  ("an ask missing its prompt",
   "workflow { g : text <- ask tool \"t\" }",
   "1:37: expected a string literal or a text block at `}`"),
  ("independent draw on a tool and a person",
   "workflow { a : text <- ask tool \"t\" independent draw 1 \"x\"\n           b : text <- ask person \"p\" independent draw 2 \"y\"\n           ask tool \"log\" \"{a} {b}\" }",
   "ok"),
  ("an act may be followed by statements",
   "workflow { ask tool \"warmup\" \"go\"\n           g : text <- ask tool \"c\" \"hi\"\n           ask tool \"log\" \"{g}\" }",
   "ok"),
  ("a panel without its rule phrase",
   "workflow { p <- panel [ ask model \"a\" \"x\" ] }",
   "1:23: expected `,` at `[`"),
  ("a panel rule missing must",
   "workflow { p <- panel, all approve [ ask model \"a\" \"x\" ] }",
   "1:28: expected `must` at `approve`"),
  ("a panel rule missing approve",
   "workflow { p <- panel, all must [ ask model \"a\" \"x\" ] }",
   "1:33: expected `approve` at `[`"),
  ("a panel missing its closing bracket",
   "workflow { p <- panel, all must approve [ ask model \"a\" \"x\" }",
   "1:61: expected `]` at `}`"),
  ("a panel bound at text",
   "workflow { p : text <- panel, all must approve [ ask model \"a\" \"x\" ] }",
   "1:24: this binding: a panel combines its members in the verdict monoid, so it answers `verdict`, not `text` at `panel`"),
  ("a panel needs no annotation",
   "workflow { p <- panel, all must approve [ ask model \"a\" \"x\" ]
           case p { approved { stop } objected { stop } no answer { stop } } }",
   "ok"),
  ("a panel result spliced as its objections",
   "workflow { p <- panel, all must approve [ ask model \"a\" \"x\", ask model \"b\" \"y\" ]
           ask tool \"log\" \"{p}\" }",
   "ok"),
  ("a panel at statement position",
   "workflow { panel, all must approve [ ask model \"a\" \"x\" ] }",
   "1:12: a panel's combined verdict has nowhere to go here: bind it, `x <- panel, …` at `panel`"),
  ("an if on a text answer",
   "workflow { d : text <- ask model \"a\" \"draft\"\n           if d { stop } else { stop } }",
   "2:12: an `if` branches on a flag, but `d` answers `text` at `d`"),
  ("an if missing its else",
   "workflow { ok : flag <- ask person \"o\" \"?\"\n           if ok { stop } }",
   "2:27: expected `else` at `}`"),
  ("an if on an unbound name",
   "workflow { if ok { stop } else { stop } }",
   "1:12: unbound name; nothing in scope answers to it at `ok`"),
  ("a statement after an if",
   "workflow { ok : flag <- ask person \"o\" \"?\"\n           if ok { stop } else { stop }\n           ask tool \"t\" \"go\" }",
   "3:12: expected `}`: `if` and `case` are tails, and a tail ends its block — each arm is the rest of the workflow at `ask`"),
  ("a case on a text answer",
   "workflow { d : text <- ask model \"a\" \"draft\"\n           case d { approved { stop } objected { stop } no answer { stop } } }",
   "2:12: the arms `approved`, `objected` and `no answer` branch on a `verdict`, but `d` answers `text` at `d`"),
  ("a verdict case missing objected",
   "workflow { v : verdict <- ask model \"m\" \"?\"\n           case v { approved { stop } no answer { stop } } }",
   "2:39: expected the arms of a verdict, all three: `approved`, `objected` and `no answer` at `no`"),
  ("a verdict case missing no answer",
   "workflow { v : verdict <- ask model \"m\" \"?\"\n           case v { approved { stop } objected { stop } } }",
   "2:57: expected the arms of a verdict, all three: `approved`, `objected` and `no answer` at `}`"),
  ("a case whose first arm is not one",
   "workflow { ok : flag <- ask person \"o\" \"yes?\"\n           case ok { yes { stop } no { stop } } }",
   "2:22: expected an arm: `approved` (a verdict's three) or `settled` (a revision's two); a flag branches with `if … else` at `yes`"),
  ("a case on an unbound name",
   "workflow { case v { approved { stop } objected { stop } no answer { stop } } }",
   "1:12: unbound name; nothing in scope answers to it at `v`"),
  ("a revising subject nothing binds",
   "workflow { r <- revising d as c, at most 1 amendment {\n             v <- ask model \"m\" \"review {c}\"\n             amend c { ask model \"a\" \"fix {c} {v}\" }\n           }\n           case r { settled x { stop } unsettled { stop } } }",
   "1:17: unbound name; nothing in scope answers to it at `d`"),
  ("a revising result must be bound",
   "workflow { d : text <- ask model \"a\" \"draft\"\n           revising d as c, at most 1 amendment {\n             v <- ask model \"m\" \"review {c}\"\n             amend c { ask model \"a\" \"fix {c} {v}\" }\n           } }",
   "2:12: a revising result must be bound: write `x <- revising …` and then `case x { settled … unsettled … }` at `revising`"),
  ("a revising in a clause position",
   "workflow { d : text <- ask model \"a\" \"draft\"\n           r <- revising d as c, at most 1 amendment {\n             v <- revising d as e, at most 1 amendment { w <- ask model \"m\" \"{e}\" amend e { ask model \"a\" \"{e}\" } }\n             amend c { ask model \"a\" \"fix {c}\" }\n           }\n           case r { settled x { stop } unsettled { stop } } }",
   "3:19: a bounded revision answers settled-or-not, which only a binding can receive: write `x <- revising …` and `case x { settled … unsettled … }` at `revising`"),
  ("a loop missing as",
   "workflow { d : text <- ask model \"a\" \"draft\"\n           r <- revising d c, at most 1 amendment {\n             v <- ask model \"m\" \"review {c}\"\n             amend c { ask model \"a\" \"fix {c} {v}\" }\n           }\n           case r { settled x { stop } unsettled { stop } } }",
   "2:28: expected `as` at `c`"),
  ("a loop missing its comma",
   "workflow { d : text <- ask model \"a\" \"draft\"\n           r <- revising d as c at most 1 amendment {\n             v <- ask model \"m\" \"review {c}\"\n             amend c { ask model \"a\" \"fix {c} {v}\" }\n           }\n           case r { settled x { stop } unsettled { stop } } }",
   "2:33: expected `,` at `at`"),
  ("a bound that is not a number",
   "workflow { d : text <- ask model \"a\" \"draft\"\n           r <- revising d as c, at most many amendments {\n             v <- ask model \"m\" \"review {c}\"\n             amend c { ask model \"a\" \"fix {c} {v}\" }\n           }\n           case r { settled x { stop } unsettled { stop } } }",
   "2:42: expected a number at `many`"),
  ("a loop missing its unit",
   "workflow { d : text <- ask model \"a\" \"draft\"\n           r <- revising d as c, at most 1 {\n             v <- ask model \"m\" \"review {c}\"\n             amend c { ask model \"a\" \"fix {c} {v}\" }\n           }\n           case r { settled x { stop } unsettled { stop } } }",
   "2:44: expected `amendments`, the unit the numeral counts at `{`"),
  ("one amendment, plural",
   "workflow { d : text <- ask model \"a\" \"draft\"\n           r <- revising d as c, at most 1 amendments {\n             v <- ask model \"m\" \"review {c}\"\n             amend c { ask model \"a\" \"fix {c} {v}\" }\n           }\n           case r { settled x { stop } unsettled { stop } } }",
   "2:44: one amendment: the unit agrees with its numeral at `amendments`"),
  ("two amendments, singular",
   "workflow { d : text <- ask model \"a\" \"draft\"\n           r <- revising d as c, at most 2 amendment {\n             v <- ask model \"m\" \"review {c}\"\n             amend c { ask model \"a\" \"fix {c} {v}\" }\n           }\n           case r { settled x { stop } unsettled { stop } } }",
   "2:44: 2 amendments: the unit agrees with its numeral at `amendment`"),
  ("a review annotated off verdict",
   "workflow { d : text <- ask model \"a\" \"draft\"\n           r <- revising d as c, at most 1 amendment {\n             v : text <- ask model \"m\" \"review {c}\"\n             amend c { ask model \"a\" \"fix {c} {v}\" }\n           }\n           case r { settled x { stop } unsettled { stop } } }",
   "2:17: a review answers `verdict`, not `text`: the loop settles when it approves at `v`"),
  ("a review annotated at verdict",
   "workflow { d : text <- ask model \"a\" \"draft\"\n           r <- revising d as c, at most 1 amendment {\n             v : verdict <- ask model \"m\" \"review {c}\"\n             amend c { ask model \"a\" \"fix {c} {v}\" }\n           }\n           case r { settled x { stop } unsettled { stop } } }",
   "ok"),
  ("a review binding may not spell a define",
   "define v = \"x\"\nworkflow { d : text <- ask model \"a\" \"draft\"\n           r <- revising d as c, at most 1 amendment {\n             v <- ask model \"m\" \"review {c}\"\n             amend c { ask model \"a\" \"fix {c} {v}\" }\n           }\n           case r { settled x { stop } unsettled { stop } } }",
   "3:54: a review binding may not spell a define; one of the two must be renamed at `v`"),
  ("an amend missing its keyword",
   "workflow { d : text <- ask model \"a\" \"draft\"\n           r <- revising d as c, at most 1 amendment {\n             v <- ask model \"m\" \"review {c}\"\n           }\n           case r { settled x { stop } unsettled { stop } } }",
   "4:12: expected `amend <carrier> { … }`: a bounded revision says how a rejected candidate is rewritten, and its answer becomes the next candidate at `}`"),
  ("an amend head off the carrier",
   "workflow { d : text <- ask model \"a\" \"draft\"\n           r <- revising d as c, at most 1 amendment {\n             v <- ask model \"m\" \"review {c}\"\n             amend d { ask model \"a\" \"fix {c} {v}\" }\n           }\n           case r { settled x { stop } unsettled { stop } } }",
   "2:54: the `amend` head names the loop's carrier: write `amend c` at `d`"),
  ("a revising result with an annotation",
   "workflow { d : text <- ask model \"a\" \"draft\"\n           r : text <- revising d as c, at most 1 amendment {\n             v <- ask model \"m\" \"review {c}\"\n             amend c { ask model \"a\" \"fix {c} {v}\" }\n           }\n           case r { settled x { stop } unsettled { stop } } }",
   "2:12: a revising result is settled-or-not, which is not one of the four kinds; it takes no annotation and is consumed by its `case` at `r`"),
  ("a loop nested in a settled arm",
   "workflow { d : text <- ask model \"a\" \"draft\"\n           r <- revising d as c, at most 1 amendment {\n             v <- ask model \"m\" \"review {c}\"\n             amend c { ask model \"a\" \"fix {c} {v}\" }\n           }\n           case r {\n             settled x {\n               r2 <- revising x as y, at most 1 amendment {\n                 w <- ask model \"m\" \"again {y}\"\n                 amend y { ask model \"a\" \"more {y} {w}\" }\n               }\n               case r2 { settled z { ask tool \"log\" \"{z}\" } unsettled { stop } }\n             }\n             unsettled { stop } }\n}",
   "ok"),
  ("a revising result nothing consumes",
   "workflow { d : text <- ask model \"a\" \"draft\"\n           r <- revising d as c, at most 1 amendment {\n             v <- ask model \"m\" \"review {c}\"\n             amend c { ask model \"a\" \"fix {c} {v}\" }\n           }\n}",
   "1:10: the revising result `r` is not yet consumed: `case r { settled … unsettled … }` is the next statement, and nothing else touches it at `r`"),
  ("a binding while a result is pending",
   "workflow { d : text <- ask model \"a\" \"draft\"\n           r <- revising d as c, at most 1 amendment {\n             v <- ask model \"m\" \"review {c}\"\n             amend c { ask model \"a\" \"fix {c} {v}\" }\n           }\n           g : text <- ask tool \"t\" \"hi\"\n           case r { settled x { stop } unsettled { stop } } }",
   "6:12: the revising result `r` is not yet consumed: `case r { settled … unsettled … }` is the next statement, and nothing else touches it at `r`"),
  ("an act while a result is pending",
   "workflow { d : text <- ask model \"a\" \"draft\"\n           r <- revising d as c, at most 1 amendment {\n             v <- ask model \"m\" \"review {c}\"\n             amend c { ask model \"a\" \"fix {c} {v}\" }\n           }\n           ask tool \"t\" \"go\"\n           case r { settled x { stop } unsettled { stop } } }",
   "6:12: the revising result `r` is not yet consumed: `case r { settled … unsettled … }` is the next statement, and nothing else touches it at `r`"),
  ("an if while a result is pending",
   "workflow { d : text <- ask model \"a\" \"draft\"\n           ok : flag <- ask person \"o\" \"?\"\n           r <- revising d as c, at most 1 amendment {\n             v <- ask model \"m\" \"review {c}\"\n             amend c { ask model \"a\" \"fix {c} {v}\" }\n           }\n           if ok { stop } else { stop }\n           case r { settled x { stop } unsettled { stop } } }",
   "8:12: expected `}`: `if` and `case` are tails, and a tail ends its block — each arm is the rest of the workflow at `case`"),
  ("a verdict case while a result is pending",
   "workflow { d : text <- ask model \"a\" \"draft\"\n           w : verdict <- ask model \"m\" \"?\"\n           r <- revising d as c, at most 1 amendment {\n             v <- ask model \"m\" \"review {c}\"\n             amend c { ask model \"a\" \"fix {c} {v}\" }\n           }\n           case w { approved { stop } objected { stop } no answer { stop } }\n           case r { settled x { stop } unsettled { stop } } }",
   "8:12: expected `}`: `if` and `case` are tails, and a tail ends its block — each arm is the rest of the workflow at `case`"),
  ("a known here while a result is pending",
   "workflow { d : text <- ask model \"a\" \"draft\"\n           r <- revising d as c, at most 1 amendment {\n             v <- ask model \"m\" \"review {c}\"\n             amend c { ask model \"a\" \"fix {c} {v}\" }\n           }\n           known here: d\n           case r { settled x { stop } unsettled { stop } } }",
   "6:12: the revising result `r` is not yet consumed: `case r { settled … unsettled … }` is the next statement, and nothing else touches it at `r`"),
  ("a stop while a result is pending",
   "workflow { d : text <- ask model \"a\" \"draft\"\n           r <- revising d as c, at most 1 amendment {\n             v <- ask model \"m\" \"review {c}\"\n             amend c { ask model \"a\" \"fix {c} {v}\" }\n           }\n           stop }",
   "6:12: the revising result `r` is not yet consumed: `case r { settled … unsettled … }` is the next statement, and nothing else touches it at `r`"),
  ("a case on the wrong pending name",
   "workflow { d : text <- ask model \"a\" \"draft\"\n           r <- revising d as c, at most 1 amendment {\n             v <- ask model \"m\" \"review {c}\"\n             amend c { ask model \"a\" \"fix {c} {v}\" }\n           }\n           case d { settled x { stop } unsettled { stop } } }",
   "6:12: the pending revising result is `r`, and it is consumed first at `d`"),
  ("a settled case on a name that is not a result",
   "workflow { g : text <- ask tool \"cat\" \"hi\"\n           case g { settled x { stop } unsettled { stop } } }",
   "2:12: `case g { settled … }` consumes a revising result, and `g` is not one: it is bound by `g <- revising …` as the statement before its `case` at `g`"),
  ("a settled arm missing unsettled",
   "workflow { d : text <- ask model \"a\" \"draft\"\n           r <- revising d as c, at most 1 amendment {\n             v <- ask model \"m\" \"review {c}\"\n             amend c { ask model \"a\" \"fix {c} {v}\" }\n           }\n           case r { settled x { stop } } }",
   "6:40: expected the two outcomes of a bounded revision: `settled <name>` and `unsettled` at `}`"),
  ("a settled arm missing its name",
   "workflow { d : text <- ask model \"a\" \"draft\"\n           r <- revising d as c, at most 1 amendment {\n             v <- ask model \"m\" \"review {c}\"\n             amend c { ask model \"a\" \"fix {c} {v}\" }\n           }\n           case r { settled { stop } unsettled { stop } } }",
   "6:29: expected a name at `{`"),
  ("the settled binder may shadow nothing live",
   "workflow { d : text <- ask model \"a\" \"draft\"\n           r <- revising d as c, at most 1 amendment {\n             v <- ask model \"m\" \"review {c}\"\n             amend c { ask model \"a\" \"fix {c} {v}\" }\n           }\n           case r { settled d { stop } unsettled { stop } } }",
   "6:12: this name is already in scope, and a live name is not introduced twice; rename one of the two at `d`"),
  ("a right known here",
   "workflow { g : text <- ask tool \"c\" \"a\"\n           known here: g\n           stop }",
   "ok"),
  ("known here: nothing, on an empty scope",
   "workflow { known here: nothing\n           ask tool \"t\" \"hi\" }",
   "ok"),
  ("a wrong known here",
   "workflow { g : text <- ask tool \"c\" \"a\"\n           known here: nothing\n           stop }",
   "2:12: `known here` asserts the names in scope, innermost first, and they are: g"),
  ("known here missing its colon",
   "workflow { g : text <- ask tool \"c\" \"a\"\n           known here g\n           stop }",
   "2:23: expected `:` at `g`"),
  ("known here, innermost first",
   "workflow { a : text <- ask tool \"c\" \"a\"\n           b : text <- ask tool \"c\" \"b {a}\"\n           known here: b, a\n           ask tool \"log\" \"{a} {b}\" }",
   "ok"),
  ("a hole opened against the end of the source",
   "workflow { ask tool \"t\" \"hm {",
   "1:29: unterminated hole: the source ended"),
  ("an if missing its brace",
   "workflow { ok : flag <- ask person \"o\" \"?\"\n           if ok stop else { stop } }",
   "2:18: expected `{` at `stop`"),
  ("an amendment bound above the limit",
   "workflow { d : text <- ask model \"a\" \"draft\"\n           r <- revising d as c, at most 65 amendments {\n             v <- ask model \"m\" \"review {c}\"\n             amend c { ask model \"a\" \"fix {c} {v}\" }\n           }\n           case r { settled x { stop } unsettled { stop } } }",
   "2:17: a bounded revision is unrolled into the term it writes, so its bound may name at most 64 amendments at `at most 65 amendments`"),
  ("one binding, holed three times, asked once",
   "workflow {\n  g <- ask tool \"cat\" \"read the file\"\n  ask tool \"log\" \"{g}||{g}\"\n  ask tool \"audit\" \"seen: {g}\"\n}",
   "ok"),
  ("a loop that settles at round two of four",
   "workflow {\n  d : text <- ask model \"author\" \"draft\"\n  r <- revising d as patch, at most 3 amendments {\n    v <- ask model \"critic\" \"review {patch}\"\n    amend patch { ask model \"author\" \"amend {patch} given {v}\" }\n  }\n  case r { settled final { ask tool \"apply\" \"apply {final}\" }\n           unsettled { ask tool \"log\" \"gave up\" } }\n}",
   "ok"),
  ("three panel members, answered differently",
   "workflow {\n  p <- panel, all must approve [ ask model \"alpha\" \"check one\",\n                                ask model \"beta\" \"check two\",\n                                ask model \"gamma\" \"check three\" ]
  ask tool \"log\" \"objections: {p}\"\n  case p { approved { ask tool \"t\" \"went-approved\" }\n           objected { ask tool \"t\" \"went-objected\" }\n           no answer { ask tool \"t\" \"went-noanswer\" } }\n}",
   "ok"),
  ("a revising subject of kind verdict",
   "workflow {\n  j : verdict <- ask model \"judge\" \"Judge the draft; object with reasons.\"\n  r <- revising j as c, at most 1 amendment {\n    v <- ask model \"meta\" \"Is this judgment fair?\\n{c}\"\n    amend c { ask model \"judge\" \"Rejudge, given: {c} and {v}\" }\n  }\n  case r {\n    settled p { case p { approved { ask tool \"log\" \"went-approved\" }\n                         objected { ask tool \"log\" \"went-objected\" }\n                         no answer { ask tool \"log\" \"went-noanswer\" } } }\n    unsettled { stop }\n  }\n}",
   "ok"),
  ("names straddling an act",
   "workflow {\n  a : text <- ask tool \"t\" \"AAA\"\n  ask tool \"warm\" \"an act between\"\n  b : text <- ask tool \"t\" \"BBB\"\n  ask tool \"log\" \"{a}|{b}\"\n}",
   "ok"),
  ("the four kinds, as the codes actually asked",
   "workflow {\n  t : text <- ask tool \"reader\" \"read\"\n  v : verdict <- ask model \"judge\" \"judge\"\n  f : flag <- ask person \"owner\" \"yes or no?\"\n  ask tool \"recorder\" \"record {t} and {v}\"\n  if f { ask tool \"t\" \"went-yes\" } else { ask tool \"t\" \"went-no\" }\n}",
   "ok"),
  ("two draws of one prompt are two questions",
   "workflow {\n  a <- ask model \"oracle\" \"same words\"\n  b <- ask model \"oracle\" \"same words\"\n  c <- ask model \"oracle\" independent draw 1 \"same words\"\n  ask tool \"log\" \"{a}|{b}|{c}\"\n}",
   "ok"),
  ("a define-holed prompt is still a closed question",
   "define spec = \"the house rules\"\nworkflow {\n  g : text <- ask person \"owner\" \"what shall I read?\"\n  ask tool \"brief\" \"brief against {spec}\"\n}",
   "ok"),
  ("served by and independent draw together, in every ask position",
   "workflow {\n  a : text <- ask model \"author\" served by \"deep\" independent draw 2 \"draft it\"\n  ask model \"logger\" served by \"cheap\" independent draw 1 \"note {a}\"\n  p <- panel, all must approve [\n    ask model \"one\" served by \"deep\" independent draw 3 \"review {a}\",\n    ask tool \"lint\" independent draw 1 \"lint {a}\",\n    ask person \"owner\" independent draw 2 \"ok? {a}\"\n  ]
  case p { approved { stop } objected { stop } no answer { stop } }\n}",
   "ok"),
  ("a revision bounded at zero amendments",
   "workflow {\n  d : text <- ask model \"a\" \"draft\"\n  r <- revising d as c, at most 0 amendments {\n    v <- ask model \"m\" \"review {c}\"\n    amend c { ask model \"a\" \"fix {c} {v}\" }\n  }\n  case r { settled x { ask tool \"log\" \"settled {x}\" }\n           unsettled { ask tool \"log\" \"unsettled\" } }\n}",
   "ok"),
  ("a bounded revision whose candidate is not text",
   "workflow {\n  ready : flag <- ask person \"owner\" \"is the release ready?\"\n  r <- revising ready as cand, at most 2 amendments {\n    v <- ask model \"m\" \"does the release look ready?\"\n    amend cand { ask person \"owner\" \"is it ready now?\" }\n  }\n  case r {\n    settled done { if done { ask tool \"ship\" \"ship it\" } else { stop } }\n    unsettled { stop }\n  }\n}",
   "ok"),
  ("two define holes in one prompt",
   "define a = \"A\"\ndefine b = \"B\"\nworkflow { ask tool \"t\" \"{a} and {b}\" }",
   "ok"),
  ("an override reaches a later define that holes it",
   "define target = \"the parser\"\ndefine brief  = \"Harden {target}, briefly.\"\nworkflow { ask tool \"t\" \"{brief}\" }",
   "ok"),
  ("adjacent holes and escapes against holes",
   "workflow { a : text <- ask tool \"t\" \"A\"\n           b : text <- ask tool \"t\" \"B\"\n           ask tool \"log\" \"{a}{b}\\{{a}\\}{b}\" }",
   "ok"),
  ("a backslash in a block is not a string escape",
   "workflow { a : text <- ask tool \"t\" \"A\"\n           ask tool \"log\" ```\n             C:\\path and \\\\{a} and \\{a} and {a} and a trailing \\\n             ```\n}",
   "ok"),
  ("crlf block content, observed rather than accepted",
   "workflow {\r\n  g : text <- ask tool \"t\" ```\r\n    line one\r\n    line two\r\n  ```\r\n}\r\n",
   "ok"),
  ("a block whose lines are not uniformly indented",
   "workflow {\n  g : text <- ask tool \"t\" ```\n        alpha\n      beta\n        \n  ```\n  ask tool \"log\" \"{g}\"\n}",
   "ok"),
  ("the scope at a loop's two exits, asserted",
   "workflow {\n  d : text <- ask model \"a\" \"draft\"\n  r <- revising d as c, at most 1 amendment {\n    v <- ask model \"m\" \"review {c}\"\n    amend c { ask model \"a\" \"fix {c} {v}\" }\n  }\n  case r {\n    settled x { known here: x, d\n                ask tool \"log\" \"{x}\" }\n    unsettled { known here: d\n                stop }\n  }\n}",
   "ok"),
  ("a kind fixed on the far side of a known here and a graft",
   "workflow {\n  d : text <- ask model \"a\" \"draft\"\n  note <- ask tool \"c\" \"notes\"\n  known here: note, d\n  r <- revising d as c, at most 1 amendment {\n    v <- ask model \"m\" \"review {c}\"\n    amend c { ask model \"a\" \"fix {c} {v}\" }\n  }\n  case r { settled x { ask tool \"log\" \"{x} and {note}\" }\n           unsettled { stop } }\n}",
   "ok"),
  ("kind inference that only the amend clause grounds",
   "workflow {\n  style <- ask tool \"cat\" \"the house style\"\n  d <- ask model \"a\" \"draft something\"\n  r <- revising d as p, at most 2 amendments {\n    v <- ask model \"m\" \"is the work acceptable?\"\n    amend p { ask model \"a\" \"improve {p} to match {style}\" }\n  }\n  case r { settled x { ask tool \"log\" \"{x}\" } unsettled { stop } }\n}",
   "ok"),
  ("first-use-wins across the arms of an if",
   "workflow {\n  ok : flag <- ask person \"o\" \"ready?\"\n  g <- ask tool \"c\" \"hi\"\n  if ok { ask tool \"log\" \"{g}\" }\n  else { if g { stop } else { stop } }\n}",
   "5:10: an `if` branches on a flag, but `g` answers `text` at `g`"),
  ("kind names spelled as binder names",
   "workflow { text : text <- ask tool \"t\" \"b\"\n           verdict <- ask model \"m\" \"judge {text}\"\n           case verdict { approved { stop } objected { stop } no answer { stop } } }",
   "ok"),
  ("a binder spelling a statement word (round sixteen: every name means one thing)",
   "workflow { known <- ask tool \"t\" \"a\"\n           ask tool \"log\" \"{known}\" }",
   "1:12: a binder may not spell a word that begins a statement: stop, known, if, case, ask, panel, revising, answer, amend, settled, unsettled, else, import, define, function, workflow at `known`"),
  ("a known here is a whole block body",
   "workflow {\n  ok : flag <- ask person \"o\" \"go ahead?\"\n  if ok { known here: ok } else { stop }\n}",
   "ok"),
  ("a panel in the amend position of a bounded revision",
   "workflow { d : text <- ask model \"a\" \"draft\"\n           r <- revising d as c, at most 1 amendment {\n             v <- ask model \"m\" \"review {c}\"\n             amend c { panel, all must approve [ ask model \"z\" \"fix {c}\" ] }\n           }\n           case r { settled x { stop } unsettled { stop } } }",
   "4:24: the `amend` of a bounded revision: a panel combines its members in the verdict monoid, so it answers `verdict`, not `text` at `panel`"),
  ("an addressee named by a define hole",
   "define cat = \"cat\"\nworkflow { g : text <- ask tool \"{cat}\" \"read something\"\n           ask tool \"log\" \"{g}\" }",
   "2:33: a name here is written, not computed: no holes"),
  ("empty prompts and an empty define",
   "define empty = \"\"\nworkflow { ask tool \"t\" \"\"\n           ask tool \"t\" \"{empty}\"\n           ask tool \"t\" \"pre{empty}post\" }",
   "ok"),
  ("a fence closed by a comma, a bracket and a brace",
   "workflow {\n  p <- panel, all must approve [ ask model \"a\" ```\n    is this ok\n    ```, ask model \"b\" ```\n    and this\n    ``` ]
  case p {\n    approved { ask tool \"t\" ```\n      approved\n      ```}\n    objected { stop }\n    no answer { stop } }\n}",
   "ok"),
  ("a closing fence indented other than its content",
   "workflow {\n  g : text <- ask tool \"t\" ```\n\t\tline one\n\t\tline two\n      ```\n  h : text <- ask tool \"t\" ```\n    line three\n```\n  ask tool \"log\" \"{g} {h}\"\n}",
   "ok"),
  ("a diagnosis column after a hole in a quoted string",
   "workflow { g : text <- ask tool \"t\" \"hi {g}\" ; }",
   "1:46: unexpected character at `;`"),
  ("a numeral abutting the next token",
   "workflow{d:text<-ask model\"a\"independent draw 2\"draft\"\nr<-revising d as c,at most 2amendments{v<-ask model\"m\"\"review {c}\"amend c{ask model\"a\"\"fix {c} {v}\"}}\ncase r{settled x{ask tool\"t\"\"{x}\"}unsettled{stop}}}",
   "ok"),
  ("columns count characters, not bytes",
   "workflow { ask tool \"t\" \"αβγ\" ; }",
   "1:31: unexpected character at `;`"),

  -- Round sixteen: functions, calls, and the single-file shapes of libraries.
  ("a value call with a short argument",
   fnsPre ++ "workflow { x <- mk \"a goal\"\n ask tool \"t\" \"use {x}\" }",
   "ok"),
  ("a statement call of a procedure",
   fnsPre ++ "workflow { d : text <- ask tool \"t\" \"w\"\n applied d }",
   "ok"),
  ("a trailing block fills the last argument",
   fnsPre ++ "workflow {\n  x <- mk ```\n      the goal\n  ```\n  ask tool \"t\" \"use {x}\"\n}",
   "ok"),
  ("a $label answered by a labelled block",
   fnsPre ++ "workflow {\n  x <- mk $goal\n  ```goal\n      the goal\n  ```\n  ask tool \"t\" \"use {x}\"\n}",
   "ok"),
  ("a function may answer a flag; the caller branches",
   "function f (p : text) -> flag {\n  x <- ask model \"m\" \"{p}\"\n  answer x\n}\nworkflow { stop }",
   "ok"),
  ("a library runs alone: its priming, then nothing",
   libOk,
   "ok"),
  ("a stray dash",
   "workflow { - }",
   "1:12: stray `-`; `--` begins a comment and `->` a function's result, and nothing else in the language begins with one at `-`"),
  ("a dollar at the end of the source",
   fnsPre ++ "workflow { x <- mk $",
   "12:20: a `$name` names a labelled block argument; a name follows the dollar at `$`"),
  ("a dollar before a non-name",
   fnsPre ++ "workflow { x <- mk $ goal }",
   "12:20: a `$name` names a labelled block argument; a name follows the dollar at `$`"),
  ("text after a fence that is not a label",
   "workflow {\n  g : text <- ask tool \"t\" ```two words\n    a\n  ```\n}",
   "2:28: the content of a block begins on the next line: nothing but a label and whitespace may follow the opening fence at ` words`"),
  ("a carrier spelling a statement word",
   "workflow { d : text <- ask tool \"t\" \"w\"\n r <- revising d as stop, at most 1 amendments {\n  v <- ask model \"m\" \"r {stop}\"\n  amend stop { ask model \"a\" \"f\" } }\n case r { settled x { ask tool \"t\" \"a {x}\" } unsettled { stop } } }",
   "2:7: a loop's carrier may not spell a word that begins a statement: stop, known, if, case, ask, panel, revising, answer, amend, settled, unsettled, else, import, define, function, workflow at `stop`"),
  ("a carrier spelling a function",
   fnsPre ++ "workflow { d : text <- ask tool \"t\" \"w\"\n r <- revising d as mk, at most 1 amendment {\n  v <- ask model \"m\" \"r {mk}\"\n  amend mk { ask model \"a\" \"f\" } }\n case r { settled x { stop } unsettled { stop } } }",
   "13:7: a loop's carrier may not spell a function; one of the two must be renamed at `mk`"),
  ("a call given too few arguments",
   fnsPre ++ "workflow { x <- mk }",
   "12:20: `mk` takes 1 argument and got 0: this is not an argument (a name, words, or a `$label`) at `}`"),
  ("a function's name standing as an argument",
   fnsPre ++ "workflow { x <- mk judged\n ask tool \"t\" \"use {x}\" }",
   "12:20: a call is not an argument: bind it above — `y <- judged …` — and pass `y` at `judged`"),
  ("a call given too many arguments",
   fnsPre ++ "workflow { x <- mk \"a\" \"b\" }",
   "12:24: expected a statement: a binding (`x <- …`), an act (`ask …`), a call, `if`, `case`, `known here:`, or `stop` at `\"…\"`"),
  ("a labelled block standing where an argument is expected",
   fnsPre ++ "workflow {\n  x <- mk ```goal\n      words\n  ```\n  ask tool \"t\" \"use {x}\"\n}",
   "13:11: a labelled block answers a `$label` and follows the call's arguments; here an argument itself is expected at `````"),
  ("two labelled blocks answering one label",
   fnsPre ++ "workflow {\n  x <- mk $goal\n  ```goal\n      a\n  ```\n  ```goal\n      b\n  ```\n  ask tool \"t\" \"use {x}\"\n}",
   "17:3: two labelled blocks answer to one label in this call; one label, one block at `goal`"),
  ("a $label no block answers",
   fnsPre ++ "workflow {\n  x <- mk $goal\n  ask tool \"t\" \"use {x}\"\n}",
   "13:11: `$goal` names no labelled block: write ```goal after the call's arguments at `goal`"),
  ("a labelled block no $label asked for",
   fnsPre ++ "workflow {\n  x <- mk \"a\"\n  ```goal\n      words\n  ```\n  ask tool \"t\" \"use {x}\"\n}",
   "14:3: no `$goal` in the call names this labelled block at `goal`"),
  ("a bind of a name that is not a function",
   "workflow { x <- banana \"y\" }",
   "1:17: expected a question (`ask …`), a panel, or the name of a function declared above at `banana`"),
  ("a bind of something that is not even a name",
   "workflow { x <- [ }",
   "1:17: expected a question, a panel, or a function's name at `[`"),
  ("a review that is not a source",
   "workflow { d : text <- ask tool \"t\" \"w\"\n r <- revising d as c, at most 1 amendment {\n  v <- banana\n  amend c { ask model \"a\" \"f\" } }\n case r { settled x { stop } unsettled { stop } } }",
   "3:8: expected a question (`ask …`), a panel, or the name of a function declared above at `banana`"),
  ("a review answering the wrong kind through a call",
   fnsPre ++ "workflow { d : text <- ask tool \"t\" \"w\"\n r <- revising d as c, at most 1 amendment {\n  v <- mk c\n  amend c { ask model \"a\" \"f {v}\" } }\n case r { settled x { stop } unsettled { stop } } }",
   "14:8: the review of a bounded revision: `mk` answers `text`, not `verdict` at `mk`"),
  ("a value function with no answer",
   "function f (p : text) -> text {\n  x <- ask model \"m\" \"{p}\"\n}\nworkflow { stop }",
   "3:1: a value function ends with `answer <name>`; `f` answers `text` at `}`"),
  ("a procedure with an answer",
   "function f (p : text) -> receipt {\n  ask tool \"t\" \"{p}\"\n  answer p\n}\nworkflow { stop }",
   "3:3: a `-> receipt` function's body just ends: the end of the block is the answer, and there is nothing to name at `answer`"),
  ("a body statement that branches",
   "function f (p : text) -> text {\n  if p { stop } else { stop }\n  answer p\n}\nworkflow { stop }",
   "2:3: a function is a reusable sequence of questions, not a reusable decision: return a `flag` or a `verdict` and branch at the call site, where the branch is read at `if`"),
  ("two parameters answering one name",
   "function f (p : text, p : text) -> text {\n  answer p\n}\nworkflow { stop }",
   "1:23: two parameters answer to one name; rename one at `p`"),
  ("a flag parameter",
   "function f (ok : flag) -> text {\n  d <- ask model \"m\" \"w\"\n  answer d\n}\nworkflow { stop }",
   "1:18: a `flag` parameter is refused: nothing in a body can consume one — `if` is not written in a body, and a flag has no text for a hole at `flag`"),
  ("a receipt parameter",
   "function f (r : receipt) -> text {\n  d <- ask model \"m\" \"w\"\n  answer d\n}\nworkflow { stop }",
   "1:17: a `receipt` parameter is refused: a receipt carries no information, and ordering is the sequence of statements at `receipt`"),
  ("a parameter list missing its comma",
   "function f (p : text q : text) -> text {\n  answer p\n}\nworkflow { stop }",
   "1:22: expected `,` or `)` at `q`"),
  ("a function missing its arrow",
   "function f (p : text) text {\n  answer p\n}\nworkflow { stop }",
   "1:23: expected `->`, the function's result at `text`"),
  ("a dotted module name",
   "import a.b\nworkflow { stop }",
   "1:8: a module's name has no dot: modules do not nest at `a.b`"),
  ("an import missing its name",
   "import \"lib\"\nworkflow { stop }",
   "1:8: expected a module's name at `\"…\"`"),
  ("an import after a define",
   "define d = \"w\"\nimport lib\nworkflow { stop }",
   "2:1: imports come first, before any define or function at `import`"),
  ("an empty source",
   "",
   "0:0: expected `workflow`, but the source ended"),
  ("a workflow-less source is read as a library",
   "banana",
   "1:1: a library's top-level binding carries its kind — inference scans forward, and forward is the importer's file; a library's questions must not depend on who imports it at `banana`"),
  ("junk after a priming in a workflow-less source",
   "g : text <- ask tool \"t\" \"w\"\n) x",
   "2:1: expected a priming statement: a binding (`x : kind <- …`), an act (`ask …`), or a call at `)`"),
  ("a verdict passed to a text parameter",
   fnsPre ++ "workflow {\n  v : verdict <- ask model \"m\" \"q\"\n  x <- mk v\n  ask tool \"t\" \"use {x}\"\n}",
   "14:11: `mk`'s parameter `goal` takes `text`, and `v` answers `verdict`; a hole is where a verdict becomes text — write the argument as words: \"{v}\" at `v`"),
  ("words passed to a verdict parameter",
   "function g (v : verdict) -> text {\n  d <- ask model \"m\" \"about {v}\"\n  answer d\n}\nworkflow { x <- g \"words\"\n ask tool \"t\" \"use {x}\" }",
   "5:19: words fill a `text` parameter, and `g`'s parameter `v` takes `verdict`; pass a name that answers it at `g`"),
  ("a flag passed to a text parameter",
   fnsPre ++ "workflow {\n  b : flag <- ask person \"p\" \"yes or no\"\n  x <- mk b\n  ask tool \"t\" \"use {x}\"\n}",
   "14:11: `mk`'s parameter `goal` takes `text`, but `b` answers `flag` at `b`"),
  ("a value call as a statement",
   fnsPre ++ "workflow { mk \"a goal\" }",
   "12:12: `mk` answers `text`, and its answer has nowhere to go: bind it, `x <- mk …` at `mk`"),
  ("a value call as a body statement",
   fnsPre ++ "function h (p : text) -> receipt {\n  mk p\n  ask tool \"t\" \"done\"\n}\nworkflow { d : text <- ask tool \"t\" \"w\"\n h d }",
   "13:3: `mk` answers `text`, and its answer has nowhere to go: bind it, `x <- mk …` at `mk`"),
  ("a procedure call bound",
   fnsPre ++ "workflow { x <- applied \"patch\" }",
   "12:12: `applied` answers `receipt`, which binds nothing that can be consumed; call it as a statement at `applied`"),
  ("a procedure call bound in a body",
   fnsPre ++ "function h (p : text) -> text {\n  x <- applied p\n  answer p\n}\nworkflow { stop }",
   "13:3: `applied` answers `receipt`, which binds nothing that can be consumed; call it as a statement at `applied`"),
  ("a body statement that is nothing",
   "function f (p : text) -> text {\n  ) x\n  answer p\n}\nworkflow { stop }",
   "2:3: expected a body statement (a binding, an act, a call) or `answer <name>` at `)`"),
  ("a body binding nothing grounds",
   "function f (p : text) -> text {\n  x <- ask model \"m\" \"{p}\"\n  answer p\n}\nworkflow { stop }",
   "2:3: nothing fixes what kind of answer `x` names: use it (a hole, an argument, the `answer`), or annotate it — `x : text <- …` at `x`"),
  ("an answer at the wrong kind",
   "function f (p : text) -> verdict {\n  v : text <- ask model \"m\" \"{p}\"\n  answer v\n}\nworkflow { stop }",
   "3:3: `answer v`: `v` answers `text`, but `f` answers `verdict` at `v`")
]

/-- The module cases: the same battery discipline, with the sources a CLI
would have read from beside the program. -/
def batteryCasesM : List (String × List (String × String) × String × String) :=
[
  ("an import, a dotted call, a dotted define in a hole",
   [("lib", libOk)],
   "import lib\nworkflow {\n  x <- lib.drafted lib.guide\n  ask tool \"t\" \"use {x} {lib.greeting}\"\n}",
   "ok"),
  ("known here sees the qualified priming",
   [("lib", libOk)],
   "import lib\nworkflow {\n  known here: lib.guide\n  ask tool \"t\" \"use {lib.guide}\"\n}",
   "ok"),
  ("a binder spelling a module",
   [("lib", libOk)],
   "import lib\nworkflow { lib <- ask tool \"t\" \"w\" }",
   "2:12: a binder may not spell an imported module's name at `lib`"),
  ("importing a program",
   [("prog", "workflow { stop }")],
   "import prog\nworkflow { stop }",
   "1:1: in module `prog`: this file has a `workflow` block, so it is a program; a program is run, not imported at `workflow`"),
  ("a library that branches",
   [("lib", "g : text <- ask tool \"t\" \"w\"\nif g { stop } else { stop }\n")],
   "import lib\nworkflow { ask tool \"t\" \"use {lib.g}\" }",
   "2:1: in module `lib`: a library's priming is a prefix of every importing program, so it is straight-line: bindings, acts and calls only at `if`"),
  ("a library asserting known here",
   [("lib", "g : text <- ask tool \"t\" \"w\"\nknown here: g\n")],
   "import lib\nworkflow { stop }",
   "2:1: in module `lib`: `known here` asserts a workflow's scope, and a priming is spliced into somebody else's; leave it to the importer at `known`"),
  ("a library binding with no annotation",
   [("lib", "g <- ask tool \"t\" \"w\"\n")],
   "import lib\nworkflow { stop }",
   "1:1: in module `lib`: a library's top-level binding carries its kind — inference scans forward, and forward is the importer's file; a library's questions must not depend on who imports it at `g`"),
  ("a library statement that is nothing",
   [("lib", "g : text <- ask tool \"t\" \"w\"\n= x\n")],
   "import lib\nworkflow { stop }",
   "2:1: in module `lib`: expected a priming statement: a binding (`x : kind <- …`), an act (`ask …`), or a call at `=`"),
  ("a cycle of two modules",
   [("a", "import b\ng : text <- ask tool \"t\" \"w\"\n"),
    ("b", "import a\nh : text <- ask tool \"t\" \"w\"\n")],
   "import a\nworkflow { stop }",
   "1:1: the imports cycle: a -> b -> a at `a`"),
  ("a module that imports itself",
   [("self", "import self\ng : text <- ask tool \"t\" \"w\"\n")],
   "import self\nworkflow { stop }",
   "1:1: the imports cycle: self -> self at `self`"),
  ("a module nobody handed over",
   [],
   "import zed\nworkflow { stop }",
   "1:1: module `zed` is not among the sources this front end was given (the CLI resolves `zed.wf` beside the program) at `zed`")
]

/-! ## The discovery pins (round fourteen): what a run must observe

Each expectation below was stated independently of the implementation — by the
discovery pass, from the grammar's rules — and is NOT regenerated from observed
output, so a failure here is a bug or a wrong reading of the rules, never a
baseline to refresh. -/

/-- The events of a source under a world, or `[]` where it does not check. -/
def evsOf (ω : Ω) (src : String) : List Event :=
  match parseAndCheckE src with
  | .error _ => []
  | .ok p => Plan.trace ω p Env.nil

/-- …and with overrides and modules, for the pins that need either. -/
def evsOfM (ω : Ω) (ov : List (String × Prompt)) (mods : List (String × String))
    (src : String) : List Event :=
  match parseAndCheckProgramWith ov mods src with
  | .error _ => []
  | .ok p => Plan.trace ω p Env.nil

def promptAt (evs : List Event) (i : Nat) : String :=
  match evs.drop i with | e :: _ => e.q.prompt | [] => "<none>"

def codesOf (evs : List Event) : String :=
  String.intercalate "," (evs.map fun e => codeName e.c)

def drawsOf (evs : List Event) : String :=
  String.intercalate "," (evs.map fun e => toString e.q.draw)

/-- A world from one function per kind, echoing prompts by default. -/
def world (t : Q .text → String := fun q => q.prompt)
    (v : Q .verdict → Verdict := fun _ => Verdict.approve)
    (f : Q .flag → Bool := fun _ => true) : Ω := fun c =>
  match c with
  | .text => t | .verdict => v | .flag => f | .ack => fun _ => ()

/-- one binding, holed three times, asked once -/
def semSrc0 : String := "workflow {\n  g <- ask tool \"cat\" \"read the file\"\n  ask tool \"log\" \"{g}||{g}\"\n  ask tool \"audit\" \"seen: {g}\"\n}"

/-- a loop that settles at round two of four -/
def semSrc1 : String := "workflow {\n  d : text <- ask model \"author\" \"draft\"\n  r <- revising d as patch, at most 3 amendments {\n    v <- ask model \"critic\" \"review {patch}\"\n    amend patch { ask model \"author\" \"amend {patch} given {v}\" }\n  }\n  case r { settled final { ask tool \"apply\" \"apply {final}\" }\n           unsettled { ask tool \"log\" \"gave up\" } }\n}"

/-- three panel members, answered differently -/
def semSrc2 : String := "workflow {\n  p <- panel, all must approve [ ask model \"alpha\" \"check one\",\n                                ask model \"beta\" \"check two\",\n                                ask model \"gamma\" \"check three\" ]
  ask tool \"log\" \"objections: {p}\"\n  case p { approved { ask tool \"t\" \"went-approved\" }\n           objected { ask tool \"t\" \"went-objected\" }\n           no answer { ask tool \"t\" \"went-noanswer\" } }\n}"

/-- a revising subject of kind verdict -/
def semSrc3 : String := "workflow {\n  j : verdict <- ask model \"judge\" \"Judge the draft; object with reasons.\"\n  r <- revising j as c, at most 1 amendment {\n    v <- ask model \"meta\" \"Is this judgment fair?\\n{c}\"\n    amend c { ask model \"judge\" \"Rejudge, given: {c} and {v}\" }\n  }\n  case r {\n    settled p { case p { approved { ask tool \"log\" \"went-approved\" }\n                         objected { ask tool \"log\" \"went-objected\" }\n                         no answer { ask tool \"log\" \"went-noanswer\" } } }\n    unsettled { stop }\n  }\n}"

/-- names straddling an act -/
def semSrc4 : String := "workflow {\n  a : text <- ask tool \"t\" \"AAA\"\n  ask tool \"warm\" \"an act between\"\n  b : text <- ask tool \"t\" \"BBB\"\n  ask tool \"log\" \"{a}|{b}\"\n}"

/-- the four kinds, as the codes actually asked -/
def semSrc5 : String := "workflow {\n  t : text <- ask tool \"reader\" \"read\"\n  v : verdict <- ask model \"judge\" \"judge\"\n  f : flag <- ask person \"owner\" \"yes or no?\"\n  ask tool \"recorder\" \"record {t} and {v}\"\n  if f { ask tool \"t\" \"went-yes\" } else { ask tool \"t\" \"went-no\" }\n}"

/-- two draws of one prompt are two questions -/
def semSrc6 : String := "workflow {\n  a <- ask model \"oracle\" \"same words\"\n  b <- ask model \"oracle\" \"same words\"\n  c <- ask model \"oracle\" independent draw 1 \"same words\"\n  ask tool \"log\" \"{a}|{b}|{c}\"\n}"

/-- a define-holed prompt is still a closed question -/
def semSrc7 : String := "define spec = \"the house rules\"\nworkflow {\n  g : text <- ask person \"owner\" \"what shall I read?\"\n  ask tool \"brief\" \"brief against {spec}\"\n}"

/-- a revision bounded at zero amendments -/
def semSrc8 : String := "workflow {\n  d : text <- ask model \"a\" \"draft\"\n  r <- revising d as c, at most 0 amendments {\n    v <- ask model \"m\" \"review {c}\"\n    amend c { ask model \"a\" \"fix {c} {v}\" }\n  }\n  case r { settled x { ask tool \"log\" \"settled {x}\" }\n           unsettled { ask tool \"log\" \"unsettled\" } }\n}"

/-- a bounded revision whose candidate is not text -/
def semSrc9 : String := "workflow {\n  ready : flag <- ask person \"owner\" \"is the release ready?\"\n  r <- revising ready as cand, at most 2 amendments {\n    v <- ask model \"m\" \"does the release look ready?\"\n    amend cand { ask person \"owner\" \"is it ready now?\" }\n  }\n  case r {\n    settled done { if done { ask tool \"ship\" \"ship it\" } else { stop } }\n    unsettled { stop }\n  }\n}"

/-- two define holes in one prompt -/
def semSrc10 : String := "define a = \"A\"\ndefine b = \"B\"\nworkflow { ask tool \"t\" \"{a} and {b}\" }"

/-- an override reaches a later define that holes it -/
def semSrc11 : String := "define target = \"the parser\"\ndefine brief  = \"Harden {target}, briefly.\"\nworkflow { ask tool \"t\" \"{brief}\" }"

/-- adjacent holes and escapes against holes -/
def semSrc12 : String := "workflow { a : text <- ask tool \"t\" \"A\"\n           b : text <- ask tool \"t\" \"B\"\n           ask tool \"log\" \"{a}{b}\\{{a}\\}{b}\" }"

/-- a backslash in a block is not a string escape -/
def semSrc13 : String := "workflow { a : text <- ask tool \"t\" \"A\"\n           ask tool \"log\" ```\n             C:\\path and \\\\{a} and \\{a} and {a} and a trailing \\\n             ```\n}"

/-- crlf block content, observed rather than accepted -/
def semSrc14 : String := "workflow {\r\n  g : text <- ask tool \"t\" ```\r\n    line one\r\n    line two\r\n  ```\r\n}\r\n"

/-- a block whose lines are not uniformly indented -/
def semSrc15 : String := "workflow {\n  g : text <- ask tool \"t\" ```\n        alpha\n      beta\n        \n  ```\n  ask tool \"log\" \"{g}\"\n}"

/-- empty prompts and an empty define -/
def semSrc16 : String := "define empty = \"\"\nworkflow { ask tool \"t\" \"\"\n           ask tool \"t\" \"{empty}\"\n           ask tool \"t\" \"pre{empty}post\" }"

/-- a fence closed by a comma, a bracket and a brace -/
def semSrc17 : String := "workflow {\n  p <- panel, all must approve [ ask model \"a\" ```\n    is this ok\n    ```, ask model \"b\" ```\n    and this\n    ``` ]
  case p {\n    approved { ask tool \"t\" ```\n      approved\n      ```}\n    objected { stop }\n    no answer { stop } }\n}"

/-- a closing fence indented other than its content -/
def semSrc18 : String := "workflow {\n  g : text <- ask tool \"t\" ```\n\t\tline one\n\t\tline two\n      ```\n  h : text <- ask tool \"t\" ```\n    line three\n```\n  ask tool \"log\" \"{g} {h}\"\n}"

/-! ## What a table of sources cannot say -/

/-- Branching on a verdict, with an arm-identifying act in each arm. -/
def srcCaseVerdict : String :=
  r#"workflow { v <- ask model "r" "is it ok?""# ++ "\n" ++
  r#"           case v { approved { ask tool "t" "went-approved" }"# ++ "\n" ++
  r#"                    objected { ask tool "t" "went-objected" }"# ++ "\n" ++
  r#"                    no answer { ask tool "t" "went-noanswer" } } }"#

/-- A verdict spliced into a prompt, for the render pins. -/
def srcInterpRender : String :=
  r#"workflow { v : verdict <- ask model "m" "judge this""# ++ "\n" ++
  r#"           ask tool "log" "said: {v}" }"#

/-- `independent draw`, an annotation, and a trailing act. -/
def srcCorners : String :=
  r#"workflow {"# ++ "\n" ++
  r#"  a : text <- ask model "m" independent draw 1 "say something""# ++ "\n" ++
  r#"  ask tool "t" "done here""# ++ "\n" ++
  r#"}"#

/-- One program, two prompt spellings. -/
def srcBlockSpelling : String :=
  "workflow {\n  g : text <- ask tool \"t\" ```\n    line one\n    line two\n  ```\n" ++
  "  ask tool \"log\" \"{g}\"\n}"
def srcStringSpelling : String :=
  "workflow {\n  g : text <- ask tool \"t\" \"line one\\nline two\"\n" ++
  "  ask tool \"log\" \"{g}\"\n}"

/-- An overridable program, for the `--define` path. -/
def srcOverridable : String :=
  "define spec = \"old words\"\nworkflow { ask tool \"t\" \"do {spec}\" }"

/-- A bounded revision at the checker's own bound. -/
def srcAtBound : String :=
  "workflow { d : text <- ask model \"a\" \"draft\"\n" ++
  s!"           r <- revising d as c, at most {maxRevisions} amendments " ++ "{\n" ++
  "             v <- ask model \"m\" \"review {c}\"\n" ++
  "             amend c { ask model \"a\" \"fix {c} {v}\" }\n" ++
  "           }\n" ++
  "           case r { settled x { ask tool \"t\" \"apply {x}\" }\n" ++
  "                    unsettled { stop } } }"

def main : IO UInt32 := do
  IO.println "dsl smoke: the battery, the flagship, and the semantics"
  try
    -- 0. Every construction, and every mistaken use of one.
    for (what, src, want) in batteryCases do
      check what want (outcome src)
    for (what, mods, src, want) in batteryCasesM do
      check what want (outcomeM mods src)
    IO.println s!"battery: {batteryCases.length + batteryCasesM.length} cases"

    -- 1. The parser reads the flagship source as the raw syntax the kernel
    -- proofs are about — the hypothesis of `Dsl.parseAndCheck_flagship`.
    match Dsl.parseProgramWith [] [] flagshipSource with
    | .error e => throw <| IO.userError s!"FAIL the flagship does not parse: {e}"
    | .ok prog =>
      checkTrue "the flagship parses to Dsl.flagshipProgram"
        (decide (prog = flagshipProgram))
    check "the flagship checks" "ok" (outcome flagshipSource)
    let rung : String :=
      match parseAndCheck flagshipSource with
      | .error e => s!"did not check: {e}"
      | .ok p => toString (repr (level p))
    check "…and the parsed flagship is at the branch rung"
      "Agentic.Core.Level.branch" rung

    -- 2. The one refusal no source text can reach: a hand-built `Raw` with an
    -- empty panel, at the entry point that exists for hand-built `Raw`s.
    let emptyPanel : Raw :=
      RawBlock.bind "p" none
        (RawSource.rhs (RawRhs.panel [] { line := 1, col := 1 }))
        (RawBlock.empty { line := 1, col := 1 }) { line := 1, col := 1 }
    check "an empty panel is refused at the hand-built entry point"
      "1:1: a panel needs at least one member at `panel`"
      (match Dsl.check [] [] emptyPanel with
       | .ok _ => "ok"
       | .error e => toString e)

    -- 3. The verdict arms reach distinct arms — `Dsl.checkBlock_caseVerdict_arms`
    -- is the ∀-statement; running the plan here is the fixture witness through
    -- the parser, which the theorem does not touch.
    match parseAndCheckE srcCaseVerdict with
    | .error e => throw <| IO.userError s!"FAIL the case program does not check: {e}"
    | .ok p =>
      let armOf (v : Verdict) : String :=
        let ω : Ω := fun c => match c with
          | .text => fun _ => "" | .verdict => fun _ => v
          | .flag => fun _ => true | .ack => fun _ => ()
        match (Plan.trace ω p Env.nil).getLast? with
        | some e => e.q.prompt
        | none => "no events"
      check "an approval reaches the `approved` arm" "went-approved" (armOf Verdict.approve)
      check "an objection reaches the `objected` arm" "went-objected"
        (armOf (Verdict.object ["no"]))
      check "a decline reaches the `no answer` arm" "went-noanswer"
        (armOf Verdict.declined)

    -- 4. What a `{v}` hole splices, in each of a verdict's three states.
    match parseAndCheckE srcInterpRender with
    | .error e => throw <| IO.userError s!"FAIL the render program does not check: {e}"
    | .ok p =>
      let saidOf (v : Verdict) : String :=
        let ω : Ω := fun c => match c with
          | .text => fun _ => "" | .verdict => fun _ => v
          | .flag => fun _ => true | .ack => fun _ => ()
        match (Plan.trace ω p Env.nil).getLast? with
        | some e => e.q.prompt
        | none => "no events"
      check "objections splice joined by \"; \"" "said: too long; unsafe"
        (saidOf (Verdict.object ["too long", "unsafe"]))
      check "an approval splices as nothing" "said: " (saidOf Verdict.approve)
      check "a decline splices as nothing" "said: " (saidOf Verdict.declined)

    -- 5. An override changes exactly the words it names; a name the program
    -- never defined is refused.
    match parseWith [("spec", [Chunk.lit "NEW WORDS"])] srcOverridable with
    | .error e => throw <| IO.userError s!"FAIL the override does not parse: {e}"
    | .ok r =>
      match check [] [] r with
      | .error e => throw <| IO.userError s!"FAIL the override does not check: {e}"
      | .ok p =>
        let ω : Ω := fun c => match c with
          | .text => fun _ => "" | .verdict => fun _ => Verdict.approve
          | .flag => fun _ => true | .ack => fun _ => ()
        check "an override replaces the define's words" "do NEW WORDS"
          (match (Plan.trace ω p Env.nil).head? with
           | some e => e.q.prompt
           | none => "no events")
    check "…and an override nobody asked for is refused"
      "2:1: this program has no `define nosuch` to override at `nosuch`"
      (match parseWith [("nosuch", [Chunk.lit "x"])] srcOverridable with
       | .ok _ => "ok"
       | .error e => toString e)

    -- 6. A source-chosen recursion depth is affordable at the bound. The wall
    -- clock is a guard against the exponential coming back, not a benchmark.
    match hb : parseAndCheckE srcAtBound with
    | .error e => throw <| IO.userError s!"FAIL the bound does not check: {e}"
    | .ok p =>
      let h := parseAndCheck_level_le _ p ((parseAndCheck_ok_iff _ p).mpr hb)
      let t0 ← IO.monoMsNow
      let τ := costTree tick p h Env.nil
      let leaves := Multiset.card τ.leaves
      let priced := decide (τ.maxFold ≠ ⊥)
      let t1 ← IO.monoMsNow
      check s!"the cost tree has 2n+2 leaves at n={maxRevisions}"
        (toString (2 * maxRevisions + 2)) (toString leaves)
      checkTrue "…and the worst path is priced" priced
      checkTrue s!"…and pricing it took under a second (took {t1 - t0} ms)"
        (t1 - t0 < 1000)
      let ωObject : Ω := fun c => match c with
        | .text => fun _ => "a patch" | .verdict => fun _ => Verdict.object ["no"]
        | .flag => fun _ => false | .ack => fun _ => ()
      let t2 ← IO.monoMsNow
      let tr := Plan.trace ωObject p Env.nil
      let t3 ← IO.monoMsNow
      check s!"…and the deepest run asks 2n+2 questions at n={maxRevisions}"
        (toString (2 * maxRevisions + 2)) (toString tr.length)
      checkTrue s!"…and running it took under a second (took {t3 - t2} ms)"
        (t3 - t2 < 1000)

    -- 7. `independent draw n` reaches the question, which is what makes
    -- resampling a different question rather than a stateful operation.
    let ω : Ω := fun c => match c with
      | .text => fun _ => "" | .verdict => fun _ => Verdict.approve
      | .flag => fun _ => true | .ack => fun _ => ()
    let tr : Trace :=
      match parseAndCheck srcCorners with
      | .error _ => []
      | .ok p => Plan.trace ω p Env.nil
    check "a resampled question carries its draw" "1"
      (match tr with | e :: _ => toString e.q.draw | [] => "no events")
    check "…and the act is the second and last event" "2" (toString tr.length)

    -- 8. A block is the string its dedented join spells: the two spellings of
    -- one program put the same questions in a world that reads prompts.
    let ωEchoish : Ω := fun c => match c with
      | .text => fun q => q.prompt | .verdict => fun _ => Verdict.approve
      | .flag => fun _ => true | .ack => fun _ => ()
    let traceOf (src : String) : Trace :=
      match parseAndCheck src with
      | .error _ => []
      | .ok p => Plan.trace ωEchoish p Env.nil
    checkTrue "a block prompt and its quoted spelling are one program"
      (decide (traceOf srcBlockSpelling = traceOf srcStringSpelling)
        && (traceOf srcBlockSpelling).length == 2)


    -- 9. The discovery pins.
    -- 9a. Sharing: one binding, holed three times, asked once.
    let evs := evsOf (world) semSrc0
    check "sharing: three consumptions are three events, one text question" "3"
      (toString evs.length)
    check "sharing: the doubled hole splices one answer twice"
      "read the file||read the file" (promptAt evs 1)
    check "sharing: the third consumption reads the same answer"
      "seen: read the file" (promptAt evs 2)

    -- 9b. A loop that settles at round two of four.
    let evs := evsOf (world (v := fun q =>
      if q.prompt == "review draft" then Verdict.object ["too short"] else Verdict.approve))
      semSrc1
    check "early settlement: five events, not the nine of exhaustion"
      "text,verdict,text,verdict,receipt" (codesOf evs)
    check "…the amend is told the candidate and the objections"
      "amend draft given too short" (promptAt evs 2)
    check "…round two reviews the AMENDED candidate"
      "review amend draft given too short" (promptAt evs 3)
    check "…and the settled arm receives it"
      "apply amend draft given too short" (promptAt evs 4)

    -- 9c. Three panel members, answered differently: the fold is a read-out.
    let mixed : Ω := world (v := fun q =>
      if q.addressee = Addressee.model "alpha" then Verdict.object ["A"]
      else if q.addressee = Addressee.model "beta" then Verdict.approve
      else Verdict.object ["C"])
    let evs := evsOf mixed semSrc2
    check "a mixed panel is five events" "5" (toString evs.length)
    check "…objections concatenate in member order" "objections: A; C" (promptAt evs 3)
    check "…and the mixed panel objects" "went-objected" (promptAt evs 4)
    let evs := evsOf (world) semSrc2
    check "…while a unanimous one approves" "went-approved" (promptAt evs 4)

    -- 9d. A revising subject of kind verdict: the carrier splices rendered.
    let evs := evsOf (world (v := fun _ => Verdict.object ["too long"])) semSrc3
    check "a verdict carrier splices as its objections"
      "Is this judgment fair?\ntoo long" (promptAt evs 1)
    -- j itself answers a verdict, so all four events are verdicts: the bind,
    -- round one's review, the amend, and round two's review of an identical
    -- question, which the world (a function) must answer identically.
    check "…and a constant objection exhausts the loop"
      "verdict,verdict,verdict,verdict" (codesOf evs)
    let evs := evsOf (world) semSrc3
    check "…an approving world settles at once and cases the verdict"
      "went-approved" (promptAt evs 2)

    -- 9e. Names straddling an act: the act's weakening moves no index.
    let evs := evsOf (world) semSrc4
    check "an act between two bindings shifts neither" "AAA|BBB" (promptAt evs 3)

    -- 9f. The four kinds, as the codes actually asked.
    let evs := evsOf (world (t := fun _ => "TXT") (v := fun _ => Verdict.object ["OBJ"])) semSrc5
    check "the trace's codes are the annotations' kinds"
      "text,verdict,flag,receipt,receipt" (codesOf evs)
    check "…text and a verdict splice by kind" "record TXT and OBJ" (promptAt evs 3)
    check "…a true flag takes the yes arm" "went-yes" (promptAt evs 4)
    let evs := evsOf (world (f := fun _ => false)) semSrc5
    check "…a false flag takes the no arm, five events still" "went-no" (promptAt evs 4)

    -- 9g. Two draws of one prompt are two questions; one draw is one.
    let evs := evsOf (world (t := fun q => "draw" ++ toString q.draw)) semSrc6
    check "two identical asks are two events" "4" (toString evs.length)
    checkTrue "…of the same question"
      (match evs with | e0 :: e1 :: _ => decide (e0 = e1) | _ => false)
    checkTrue "…and the fresh draw is a different question"
      (match evs with | e0 :: _ :: e2 :: _ => decide (e2 ≠ e0) | _ => false)
    check "…whose answers the world keys on the draw" "draw0|draw0|draw1" (promptAt evs 3)

    -- 9h. A define-holed prompt is a closed question: same event in every world.
    let t1 := evsOf (world (t := fun _ => "AAA")) semSrc7
    let t2 := evsOf (world (t := fun _ => "BBB")) semSrc7
    checkTrue "a define-holed question is the same event in disagreeing worlds"
      (match t1, t2 with
       | [a1, b1], [a2, b2] => decide (b1 = b2) && decide (a1 ≠ a2)
       | _, _ => false)
    check "…and the program sits at the batch rung" "Agentic.Core.Level.batch"
      (match parseAndCheckE semSrc7 with
       | .ok p => toString (repr (level p))
       | .error e => s!"did not check: {e}")

    -- 9i. A revision bounded at zero amendments: the amend is written, never asked.
    let evs := evsOf (world (v := fun _ => Verdict.object ["no"])) semSrc8
    check "zero amendments, objecting: draft, one review, the unsettled act"
      "text,verdict,receipt" (codesOf evs)
    check "…which says so" "unsettled" (promptAt evs 2)
    checkTrue "…and no amend question was ever put"
      (!evs.isEmpty && evs.all (fun e => !(e.q.prompt.startsWith "fix")))
    let evs := evsOf (world) semSrc8
    check "zero amendments, approving: settled with the original" "settled draft"
      (promptAt evs 2)

    -- 9j. A loop at a flag carrier: settled receives the candidate, at a kind
    -- no prompt can show. (A closed review is one question, so its answer is
    -- one answer: the loop settles at once or exhausts — that is the world
    -- being a function, not a gap.)
    let evs := evsOf (world (f := fun q => q.prompt == "is it ready now?")) semSrc9
    check "an approving world settles with the original flag, which is false"
      "flag,verdict" (codesOf evs)
    let evs := evsOf (world (v := fun _ => Verdict.object ["not ready"])
                            (f := fun q => q.prompt == "is it ready now?")) semSrc9
    check "an objecting world exhausts through two flag amendments"
      "flag,verdict,flag,verdict,flag,verdict" (codesOf evs)
    checkTrue "…and ships nothing"
      (!evs.isEmpty && evs.all (fun e => e.q.prompt != "ship it"))

    -- 9k. Two define holes in one prompt splice in place.
    let evs := evsOf (world) semSrc10
    check "two define holes, spliced where they stand" "A and B" (promptAt evs 0)

    -- 9l. An override reaches a later define that holes it.
    check "an override is seen by later defines" "Harden the CSV reader, briefly."
      (match parseWith [("target", [Chunk.lit "the CSV reader"])] semSrc11 with
       | .error e => s!"did not parse: {e}"
       | .ok r =>
         match Dsl.check [] [] r with
         | .error e => s!"did not check: {e}"
         | .ok p => promptAt (Plan.trace (world) p Env.nil) 0)

    -- 9m. Adjacent holes, and escapes against holes.
    let evs := evsOf (world (t := fun q => q.prompt)) semSrc12
    check "adjacent holes and brace escapes around a hole" "AB{A}B" (promptAt evs 2)

    -- 9n. A backslash in a block is not a string escape.
    let evs := evsOf (world (t := fun _ => "A")) semSrc13
    let bs := "\\"
    check "block backslashes are literal; the brace escapes are not"
      ("C:" ++ bs ++ "path and " ++ bs ++ "{a} and {a} and A and a trailing " ++ bs)
      (promptAt evs 1)

    -- 9o. CRLF block content equals its LF spelling.
    checkTrue "CRLF and LF spell one program"
      (decide (evsOf (world) semSrc14 ≠ [] ∧
        evsOf (world) semSrc14 = evsOf (world) (semSrc14.replace "\r" "")))
    check "…with no carriage return in the prompt" "line one\nline two"
      (promptAt (evsOf (world) semSrc14) 0)

    -- 9p. A block whose lines are not uniformly indented: the dedent is a meet.
    let evs := evsOf (world) semSrc15
    check "the dedent strips the COMMON indent and empties blank lines"
      "  alpha\nbeta\n" (promptAt evs 0)

    -- 9q. Empty prompts, and an empty define.
    let evs := evsOf (world) semSrc16
    check "an empty prompt asks with no words" "" (promptAt evs 0)
    check "…an empty define splices nothing" "" (promptAt evs 1)
    check "…and vanishes between its neighbours" "prepost" (promptAt evs 2)

    -- 9r. A fence closed by a comma, a bracket and a brace.
    let evs := evsOf (world) semSrc17
    check "fences close before , ] and }" "is this ok,and this,approved"
      (String.intercalate "," (evs.map fun e => e.q.prompt))

    -- 9s. A closing fence indented other than its content.
    let evs := evsOf (world) semSrc18
    check "the closing fence's indent is not content" "line one\nline two"
      (promptAt evs 0)
    check "…even shallower than the content" "line three" (promptAt evs 1)

    IO.println "discovery pins: done"

    -- 10. Round sixteen: functions and imports, as a run observes them. The
    -- expectations below were argued from the design (fn-import-design.md)
    -- before being run: a call is `Plan.sub`, so a call and its hand-inlining
    -- are one trace; an import is a plan prefix, so the priming leads; the
    -- three argument spellings normalize to one prompt; sharing is by the
    -- question, so one call twice is one answer twice.
    let wEcho : Ω := world (t := fun q => s!"<{q.prompt}>")

    -- 10a. The priming runs first; a dotted define expands; a dotted binding
    -- splices.
    let s16a := "import lib\nworkflow { ask tool \"t\" \"use {lib.guide} {lib.greeting}\" }"
    let e16a := evsOfM wEcho [] [("lib", libOk)] s16a
    check "priming first: the library's question leads the trace"
      "text,receipt" (codesOf e16a)
    check "…worded by the library" "style guide" (promptAt e16a 0)
    check "…and the program's act splices the answer and the dotted define"
      "use <style guide> hello" (promptAt e16a 1)

    -- 10b. A call is its inlining: `Plan.sub`, not a new former.
    let callSrc := fnsPre ++ "workflow { x <- mk \"the goal\"\n ask tool \"t\" \"use {x}\" }"
    let inlSrc := "workflow { x <- ask model \"author\" \"draft: the goal\"\n ask tool \"t\" \"use {x}\" }"
    checkTrue "a call and its hand-inlining are one trace"
      (decide (evsOf wEcho callSrc ≠ [] ∧ evsOf wEcho callSrc = evsOf wEcho inlSrc))

    -- 10c. Three spellings of one argument are one program.
    let trailSrc := fnsPre ++ "workflow {\n  x <- mk ```\n      the goal\n  ```\n  ask tool \"t\" \"use {x}\"\n}"
    let lblSrc := fnsPre ++ "workflow {\n  x <- mk $goal\n  ```goal\n      the goal\n  ```\n  ask tool \"t\" \"use {x}\"\n}"
    checkTrue "a short argument, a trailing block and a $label are one trace"
      (decide (evsOf wEcho callSrc ≠ [] ∧ evsOf wEcho callSrc = evsOf wEcho trailSrc
        ∧ evsOf wEcho trailSrc = evsOf wEcho lblSrc))

    -- 10d. A procedure's acts run in order, between the caller's statements.
    let procSrc := fnsPre ++
      "workflow { d : text <- ask tool \"cat\" \"the patch\"\n applied d\n ask tool \"log\" \"done\" }"
    let e16d := evsOf wEcho procSrc
    check "a procedure's acts, in order" "text,receipt,receipt" (codesOf e16d)
    check "…the first act reads the argument" "apply: <the patch>" (promptAt e16d 1)

    -- 10e. Same call, same answer: sharing survives inlining, because the
    -- inlined asks are the same question.
    let shareSrc := fnsPre ++
      "workflow { x <- mk \"g\"\n y <- mk \"g\"\n ask tool \"t\" \"cmp {x} :: {y}\" }"
    let e16e := evsOf wEcho shareSrc
    check "two calls with one argument are one question twice, one answer"
      "cmp <draft: g> :: <draft: g>" (promptAt e16e 2)

    -- 10f. `--define` reaches through the module prefix.
    let e16f := evsOfM wEcho [("lib.greeting", Prompt.normalize [.lit "swapped"])]
      [("lib", libOk)] s16a
    check "an override through the module prefix changes exactly those words"
      "use <style guide> swapped" (promptAt e16f 1)

    -- 10g. The examples on disk.
    let libFile ← try
        IO.FS.readFile "example/library.wf"
      catch e =>
        throw <| IO.userError s!"FAIL example/library.wf is not readable — \
                                run from the repository root: {e}"
    let progFile ← try
        IO.FS.readFile "example/harden-imported.wf"
      catch e =>
        throw <| IO.userError s!"FAIL example/harden-imported.wf is not readable — \
                                run from the repository root: {e}"
    check "example/harden-imported.wf checks against example/library.wf" "ok"
      (outcomeM [("library", libFile)] progFile)
    let e16g := evsOfM wEcho [] [("library", libFile)] progFile
    check "…and its consenting trace is priming, draft, review panel, judge, consent, apply"
      "text,receipt,text,verdict,verdict,verdict,flag,receipt,receipt" (codesOf e16g)
    check "example/library.wf runs alone: its priming, then nothing" "ok"
      (outcomeM [] libFile)

    -- 10h. The two resource bounds of the elaboration, at chain-built sources:
    -- `f n` inlines to 2^(n-1) questions and its header sits at line 5n-5.
    check "a function over the question budget is refused with the count"
      "65:1: `f14` elaborates to 8192 questions, and the bound is 4096 at `f14`"
      (outcome (chain 14 ++ "workflow { stop }"))
    check "a program over the question budget is refused with the count"
      "0:0: this program elaborates to 8193 questions, and the bound is 4096"
      (outcome (chain 13 ++ "workflow { a <- f13 \"x\"\n b <- f13 \"y\"\n ask tool \"t\" \"{a} {b}\" }"))

    -- 10i. The refusals no source text reaches, at the hand-built entry point
    -- (the parser is arity-directed and resolves every call head, so only a
    -- hand-built `RawProgram` can present these to the checker).
    let hbFn : RawFn :=
      { name := "f", params := [("p", Code.text), ("q", Code.text)], result := Code.text
      , body := [], answer := some "p", answerPos := { line := 1, col := 1 }
      , pos := { line := 1, col := 1 } }
    let hbOutcome (main : Raw) : String :=
      match checkProgram ⟨[hbFn], main⟩ with
      | .ok _ => "ok"
      | .error e => e.render
    check "a hand-built call with too few arguments is refused"
      "0:0: `f` is applied to too few arguments at `f`"
      (hbOutcome (RawBlock.bind "x" none
        (RawSource.rhs (RawRhs.call "f" [] { line := 2, col := 3 }))
        (RawBlock.empty { line := 3, col := 1 }) { line := 2, col := 1 }))
    check "…and with too many"
      "0:0: `f` is applied to too many arguments at `f`"
      (hbOutcome (RawBlock.bind "x" none
        (RawSource.rhs (RawRhs.call "f"
          [RawArg.lit (Prompt.normalize [.lit "a"]) { line := 2, col := 5 },
           RawArg.lit (Prompt.normalize [.lit "b"]) { line := 2, col := 7 },
           RawArg.lit (Prompt.normalize [.lit "c"]) { line := 2, col := 9 }]
          { line := 2, col := 3 }))
        (RawBlock.empty { line := 3, col := 1 }) { line := 2, col := 1 }))
    check "…and a call of a name no function answers"
      "2:1: no function answers to this name (functions are declared above their first use) at `nosuch`"
      (hbOutcome (RawBlock.callStmt "nosuch" []
        (RawBlock.empty { line := 3, col := 1 }) { line := 2, col := 1 }))

    IO.println "round sixteen pins: done"

    IO.println "dsl smoke: all checks passed"
    return (0 : UInt32)
  catch e =>
    IO.eprintln s!"dsl smoke: {e}"
    return 1
