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

## Grammar

Braces delimit; indentation means nothing. Comments run `--` to end of line.
There are no reserved words: positions decide.

```
program    ::= { define } "workflow" block

define     ::= "define" name "=" text

block      ::= "{" statement { statement } "}"
             | "{" "stop" "}"

statement  ::= name [ ":" kind ] "<-" source      -- bind an answer (kind usually inferred)
             | ask                                 -- statement ask: the act; answers receipt
             | "if" name block "else" block        -- flag elimination; both arms mandatory
             | "case" name "{" arms "}"            -- sum elimination
             | "known" "here" ":" ( "nothing" | name { "," name } )   -- optional, checker-verified

source     ::= ask
             | "panel" "," rule "[" ask { "," ask } "]"
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

Holes inside `text`: `{x}` splices an answer (text only), `{x.reasons}`
renders a verdict's objections where it is used, `{$x}` expands a define.
`\{` is a literal brace.

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
   `text`; `{x.reasons}` forces `verdict`; `if` forces `flag`; verdict arms
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
   Inside a define, only `{$earlier-define}` holes are legal, so expansion
   yields literals and cannot be cyclic. A binder may not spell a define;
   `{x}` is refused if `x` names a define, and `{$x}` if it does not. A
   question is closed — batch rung — exactly when every hole is `{$…}`,
   readable at the question.

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
- `{x.reasons}` adds a projection chunk deliberately and updates
  Check.lean's "interpolation is text-only" invariant;
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
`{verdict.reasons}` — the reference points at `at least n` as the way out. A
receipt verifies nothing. The kind of a question can change when its uses
change (rule 4). Prompt text like `verdictSpec` helps an addressee satisfy
the kind's decoder; it is a courtesy, and the two can drift.
