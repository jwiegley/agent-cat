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
  arms reach *distinct* arms (no theorem constrains the `VTag` mapping — a
  permutation type-checks); what a `{v}` hole splices in each of a verdict's
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

/-! ## The battery: every construction, and every mistaken use of one -/

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
   "2:28: the content of a block begins on the next line: nothing but whitespace may follow the opening fence at `md`"),
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
  ("a stray dash",
   "workflow { - }",
   "1:12: stray `-`; `--` begins a comment, and nothing else in the language begins with one at `-`"),
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
   "3:17: a binder may not spell a define; one of the two must be renamed at `c`"),
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
  ("a source that does not begin with workflow",
   "stop",
   "1:1: expected `workflow` at `stop`"),
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
   "0:0: expected a statement: a binding (`x <- …`), an act (`ask …`), `if`, `case`, `known here:`, or `stop`, but the source ended"),
  ("a statement that is not one",
   "workflow { [ }",
   "1:12: expected a statement: a binding (`x <- …`), an act (`ask …`), `if`, `case`, `known here:`, or `stop` at `[`"),
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
   "workflow { p <- panel, all must approve [ ask model \"a\" \"x\" ]\n           case p { approved { stop } objected { stop } no answer { stop } } }",
   "ok"),
  ("a panel result spliced as its objections",
   "workflow { p <- panel, all must approve [ ask model \"a\" \"x\", ask model \"b\" \"y\" ]\n           ask tool \"log\" \"{p}\" }",
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
   "3:54: a binder may not spell a define; one of the two must be renamed at `v`"),
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
   "2:17: a bounded revision is unrolled into the term it writes, so its bound may name at most 64 amendments at `at most 65 amendments`")
]

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
    IO.println s!"battery: {batteryCases.length} cases"

    -- 1. The parser reads the flagship source as the raw syntax the kernel
    -- proofs are about — the hypothesis of `Dsl.parseAndCheck_flagship`.
    match Dsl.parse flagshipSource with
    | .error e => throw <| IO.userError s!"FAIL the flagship does not parse: {e}"
    | .ok r =>
      checkTrue "the flagship parses to Dsl.flagshipRaw" (decide (r = flagshipRaw))
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

    -- 3. The verdict arms reach distinct arms: nothing constrains the `VTag`
    -- mapping, so it is pinned by running the plan.
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

    IO.println "dsl smoke: all checks passed"
    return (0 : UInt32)
  catch e =>
    IO.eprintln s!"dsl smoke: {e}"
    return 1
