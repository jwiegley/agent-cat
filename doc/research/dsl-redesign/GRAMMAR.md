# The redesigned surface, as approved

*Round ten of the worked example, approved by the owner on 2026-08-14. This is
the **design of record** for the replacement of `Agentic/Core/Dsl/*`; obr
`acat-k28` tracks implementation. The historical layers (the round-seven
synthesis, the survey, the panel-rules derivation, the round history) sit
beside this file; where they disagree with this file, this file is right.
`flagship.wf` in this directory is the approved example.*

The surface elaborates into `Plan`'s four writable formers — `ret`, `askC`,
`ask`, `case` — and has no syntax for `dyn`. Every writable program has a
finite cost tree at level ≤ branch. Question shapes are term-level data; only
prompt words are computed from earlier answers. Sharing is by binding: asking
twice is one answer, and deliberate resampling is a distinct draw index.

## Implementation status (round eleven, landed)

The surface below is implemented in `Agentic/Core/Dsl/{Syntax,Parse,Check}.lean`
as of the commit that carries this note, with every smoke green and all nine
flagship kernel proofs recomputed (the module now elaborates in ~107 s, down
from five-six minutes). Four deliberate v1 deltas against this document, each
tracked: the consuming `case` of a revising result must be the **next**
statement (the spec's "later in the same block" is a relaxation for the day a
workflow needs it); branchings are terminal in their block (statements after a
branch would need the graft-through-case elaboration — same day); the panel
menu ships entry one only (`at least n must approve` is acat-f10); and a
*bound* ask may still be annotated `: receipt`, which binds a name nothing can
consume — a refusal to add. Kind inference is first-ground-use with the
ground-free refusal, exactly as §rules-4 states.

Round twelve (owner): the `.reasons` projection is deleted — it implied fields
a verdict does not have. A `{v}` hole splices a verdict as its objections,
which is the kind's one canonical text; flags and receipts remain refused. The
elaborated term is unchanged (`Verdict.render` at the hole).

Round thirteen (owner): the `{$x}` define sigil is deleted — one hole
spelling, `{name}`, resolved by the disjoint namespaces (the binder-spells-
define refusal is what carries the guarantee the sigil carried). The survey's
rung-at-a-glance argument is consciously traded away: the rung is still an
exact fact of the source — `agent-cat plan` names it per question — just not
a glyph in the prompt. Brace escaping: `\{` and `\}` in both prompt
spellings; in blocks everything else is literal.

Round sixteen (owner): **functions and imports, landed.** Both derived rather
than invented — `Sub Γ Δ ≅ ∏ᵢ Expr Δ (El cᵢ)` says a function *is* an open
plan over its parameter context and a call *is* `Plan.sub`; an import is a plan
prefix plus a namespace. The design of record for the two features is
`fn-import-design.md` beside this file, with its adversarial pass in
`fn-import-attack.md`; the grammar below carries the productions. What holds by
construction: a body cannot see its caller (by type), recursion cannot be
written (a call head resolves against the functions already declared above),
calls cannot be arguments (parsing is arity-directed and needs no lookahead),
and the whole function table sits at or below the pipeline rung (`FnLevel`,
threaded through `Dsl.checkProgram_level_le`). A library's top-level
statements are its priming and run at load, before anything the importer
writes; its exports read as `lib.name`; a file with a `workflow` block cannot
be imported, and a library may be run — its priming, then nothing. The
elaborated term is priced before it is built: `maxQuestions` refuses a table
entry or a program whose inlining would exceed the bound. One softening of
"no reserved words": a binder, parameter, or function name may not spell a
statement word, a function, or an imported module's name — each such name is
refused where it is written, so every name in a program means exactly one
thing.

Round seventeen (owner, approved 2026-08-15): **the do-notation reading, bang
lifting, and the noise audit — design of record: `expr-design.md` beside this
file, which supersedes the grammar below where they disagree.** Blocks are
officially do-blocks over `Plan`: the last statement of a function body is its
answer and the `answer` keyword is deleted — cold, with no migration clause,
because no agent-cat scripts exist in the wild and `answer` leaving the
statement words is the purer "no reserved words" outcome. `!(source)` stands
exactly where a name may stand and lifts post-order to the head of its
statement, never across a brace; two divergences from Idris are language rules
(two identical bangs are one answer — `independent draw` resamples; a bang in
an arm is asked on that path only). Parameter annotations default to `text`.
Receipt bodies do not lift. Trailing bindings are refused in blocks, arms and
bodies (not in a library's priming); any Unit-valued statement may end a block,
assertions included — the requirement is the type, not a closing word. The
fence-close drift is fixed: `)` and a trailing `--` comment may follow a
closing fence, as `block-syntax.md` rule 2 always said.

## Grammar

Braces delimit; indentation means nothing. Comments run `--` to end of line.
There are no reserved words: positions decide.

```
program    ::= { import } { define | function } "workflow" block
library    ::= { import } { define | function } { primer }   -- no workflow block

import     ::= "import" name          -- the file <name>.wf beside the program; the CLI resolves

define     ::= "define" name "=" text

function   ::= "function" name "(" param { "," param } ")" "->" kind "{" body "}"
param      ::= name ":" ( "text" | "verdict" )     -- flag and receipt parameters are refused
body       ::= { bodystmt } "answer" name          -- a value function ends with its answer…
             | { bodystmt }                        -- …and a `-> receipt` body just ends
bodystmt   ::= name [ ":" kind ] "<-" ( ask | panel | call )
             | ask                                 -- an act
             | call                                -- a `-> receipt` function, run for its doing

call       ::= fname { argument } { labelledblock }
argument   ::= name | text | "$" label             -- a call is not an argument: bind it
labelledblock ::= a fenced block whose opening fence carries the label

primer     ::= name ":" kind "<-" ( ask | panel | call )   -- annotated, always
             | ask
             | call

block      ::= "{" statement { statement } "}"
             | "{" "stop" "}"

statement  ::= name [ ":" kind ] "<-" source      -- bind an answer (kind usually inferred)
             | ask                                 -- statement ask: the act; answers receipt
             | call                                -- statement call: a `-> receipt` function
             | "if" name block "else" block        -- flag elimination; both arms mandatory
             | "case" name "{" arms "}"            -- sum elimination
             | "known" "here" ":" ( "nothing" | name { "," name } )   -- optional, checker-verified

source     ::= ask
             | "panel" "," rule "[" ask { "," ask } "]"
             | call
             | loop

ask        ::= "ask" "model"  plainstring [ "served" "by" plainstring ]
                              [ "independent" "draw" number ] text
             | "ask" "tool"   plainstring [ "independent" "draw" number ] text
             | "ask" "person" plainstring [ "independent" "draw" number ] text

rule       ::= "all" "must" "approve"
             | "at" "least" number "must" "approve"

loop       ::= "revising" name "as" name "," "at" "most" number "amendments" "{"
                 name [ ":" kind ] "<-" source     -- the review binding; must be a verdict
                 "amend" name "{" source "}"       -- the amend head names the loop carrier
               "}"

arms       ::= "approved" block "objected" block "no" "answer" block   -- a verdict
             | "settled" name block "unsettled" block                  -- a loop result

kind       ::= "text" | "verdict" | "flag" | "receipt"
text       ::= a quoted string, or a fenced block (see block-syntax.md)
plainstring::= a quoted string with no holes (names are written, not computed)
```

Holes inside `text`: one spelling, `{name}`. A hole *names*: a define is
expanded where it stands, and a binding is spliced *as text* when the program
runs — a text answer is itself, a verdict is its objections joined by `"; "`
(each kind has at most one way to be text, so there is nothing to project).
Flags and receipts have no canonical text and are refused. The two namespaces
are disjoint by construction — a binder may not spell a define — so the name
alone decides. `\{` is a literal brace (`\}` likewise, in both spellings).

## The rules the grammar does not carry

1. **A block is statements, or the word `stop`.** `{ }` is unwritable; a path
   that does nothing says so. Both elaborate to `ret`.

2. **One binding shape.** A name is introduced only left of `<-`, as a
   `settled` arm's binder, or at a loop head's `as`. Nothing is bound by a
   keyword's position.

3. **Two consumption sites, and no third.** `{x}` in a prompt, and
   `if x` / `case x`. There is no expression language — no test, comparison,
   arithmetic, or transformation — which is what makes "who can see it"
   answerable by searching the page.

4. **Kinds are inferred** from the constraint sites: a `{x}` hole forces
   `text` (a verdict binding is grounded positionally or by annotation,
   never by a hole); `if` forces `flag`; verdict arms
   force `verdict`; panel members, panel results, and the review binding are
   `verdict`; a statement-position ask is `receipt`; the loop subject, its
   carrier, and its `settled` binder share one kind. Annotations remain legal
   everywhere. **The honest side condition** (from the round-8 audit): an
   annotation is *required* for any constraint component that never touches a
   ground site — "used somewhere" is not sufficient — and the refusal names
   the component. Note the consequence and state it in the reference: under
   inference, adding or removing a downstream use can change which question
   is asked.

5. **Define hygiene.** A define is literal text, expanded at parse time.
   Inside a define, only holes naming earlier defines are legal, so expansion
   yields literals and cannot be cyclic. A binder may not spell a define —
   the disjointness that makes the one hole spelling unambiguous. A question
   is closed — batch rung — exactly when every hole it wrote named a define,
   which the preamble at the top of the file decides.

6. **No shadowing.** A live name may not be introduced again; dead names are
   reusable (which is what lets `settled patch` name what the loop revised).

7. **Elimination is total.** `if` writes both arms; `case` writes every arm
   of its kind, in order; no defaults, no fallthrough. Arms export no
   bindings (a value leaving an arm would need a sum code, and `Ctx` holds
   `Code`s).

8. **The loop.** `revising s as c, at most n amendments { v <- …  amend c {…} }`:
   the body binds one verdict; the loop settles when it approves; otherwise
   the `amend` block's answer replaces the carrier named in its head (the
   head's name must match the `as` name). `n` counts amendments — reviews
   number between 1 and n+1. `n ≤ maxRevisions`.

9. **The loop's result is settled-or-not.** It binds like everything else
   and is eliminated by `case … { settled x {…} unsettled {…} }`. There is
   no code for "maybe a text", so the result is a *pending* value riding the
   graft's continuation: on every path from the binding, exactly one such
   `case` consumes it, and nothing else may touch it. (Per-path; a case
   inside another construct's arm is legal.)

10. **The panel menu is closed** — two entries. `all must approve` is the
    verdict monoid: objections concatenate in member order; one silent
    member sinks the panel to *no answer* (deliberately: silence is not an
    opinion to outvote). It is associative — panels flatten lawfully.
    `at least n must approve` is a counted read-out: fewer than `n` answers
    is *no answer*; `n` approvals approve; otherwise it objects with every
    non-approver's objections plus a named note per silent member (this is
    where the annihilation hazard is fixed, and where associativity is
    deliberately given up for the parameter). Both cost exactly `k`
    questions in every world — the menu changes the read-out, never the
    schedule — and the quorum read-out is a *pure function in the leaf*, so
    the whole expression layer stays at the pipeline rung. Refused, each
    with its one-line reason recorded in `panel-rules.md`: bare `panel [`,
    `a majority` (ambiguous between members and answerers), `any may veto`
    (unanimity said backwards), `at least k of k` (write `all`), best-of
    (rank candidates with n draws and a judge ask — a different shape),
    percentages, weights or binding members, early exit.

11. **A statement-position ask is the act.** It binds nothing and asks for
    nothing back (kind `receipt`). Stated limits, from the round-8 cold
    read: the absence of an arrow marks *discard*, not *consequence* — the
    permission layer keys on the receipt kind, and the reference must say
    so; and a receipt is unverified, so a prompt must not demand a
    completion token nothing checks.

12. **`stop` is a clean end**, on every path; the surface does not encode
    success or failure of an ending, and the reference says so rather than
    letting the reader guess.

## Elaboration and theorem survival

The kernel is untouched. Every statement of the flagship theorems survives:
five verbatim including proofs; the `decide +kernel` results (level =
branch, nine leaves, min 5 / max 15, the four trace and four bill
equations) recompute over a re-transcribed `flagshipRaw` at unchanged cost.
`parse flagshipSource = .ok flagshipRaw` re-baselines with the new file.

Implementation obligations recorded by the adversarial passes (all tracked
on `acat-k28`):

- the ground-free-component refusal, and a rewritten `example/ill-typed.wf`
  built around a genuine conflict (inference deletes the current one);
- `checkBlock` gains a continuation-returning mode carrying pending loop
  results (the option value stays lexically reachable inside the graft's
  lambda — no `Ctx` entry, no kernel change);
- graft replicates the loop's tail once per exit: price the product in
  `RawBlock.bounded`, not each numeral;
- a `{v}` hole at a verdict supplies the renderer at the use site, updating
  Check.lean's "interpolation is text-only" invariant to "text or verdict,
  each by its one canonical rendering";
- `served by` is refused off `ask model` (no such refusal exists today);
- for the quorum rule: the agreement-at-top-threshold and
  trace-independence theorems are **required**, as is the lemma that a
  failed quorum never renders `object []` (an empty objection *is*
  `approve`, and the loop's exit rests on it); decline notes derive from
  the shape's addressee — no parallel list;
- the text-block scanner joins the lexer's fuel discipline; the
  block/string chunk identity is pinned by a `decide` test in DslSmoke.

## Hazards, named

A panel under `all must approve` with a silent member hands `amend` an empty
`{verdict}` — the reference points at `at least n` as the way out. A
receipt verifies nothing. The kind of a question can change when its uses
change (rule 4). Prompt text like `verdictSpec` helps an addressee satisfy
the kind's decoder; it is a courtesy, and the two can drift.
