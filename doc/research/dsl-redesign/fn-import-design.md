# Functions and imports for the agent-cat surface

*Round fourteen, proposed. Meanings first. This document is written against
`doc/research/dsl-redesign/GRAMMAR.md` (the design of record, through its
round-12/13 notes) and against the implementation as it stands in
`Agentic/Core/Dsl/{Syntax,Parse,Check}.lean`, `Agentic/Core/Dsl.lean` and
`Agentic/Core/Plan.lean`. Where it changes the design of record it says so.
One design; alternatives appear only where they were rejected, with the reason.*

---

## MEANING

### What the library already fixes

Three facts of `Agentic/Core/Plan.lean` decide almost everything here, so they
are stated before anything is proposed.

1. `Expr Γ A = Env Γ → A`. A prompt is a pure function of what is known.
2. `Sub Γ Δ = Env Δ → Env Γ`, a *semantic* context morphism, and
   `Plan.sub : Plan Γ A → Sub Γ Δ → Plan Δ A` transports a term along one.
   `denote_sub` (Denote.lean) says `denote (sub p σ) δ = denote p (σ δ)`.
3. `Ctx = List Code`, and `Env Γ` is the product of `El c` over `Γ` — no more
   and no less.

### A function is an open plan over exactly its parameters

Do not assume it; solve for it. A function must be a thing that (i) is written
once, (ii) is used at many sites in many contexts, and (iii) leaves the four
formers and the branch rung intact. So it is some `X` with an operation

```
callAt : X → (the site's context Δ) → (the arguments) → Plan Δ (something)
```

The only operation the syntax owns that changes a term's context is `Plan.sub`,
whose second argument is a `Sub Γ Δ`. So `X = Plan Γ A` for some `Γ`, and a call
is `Plan.sub` at some `σ : Sub Γ Δ`. Now solve for `Γ`. Compute what a `Sub Γ Δ`
*is* when `Γ = [c₁, …, cₙ]`:

```
Sub Γ Δ  =  Env Δ → Env [c₁,…,cₙ]  ≅  ∏ᵢ (Env Δ → El cᵢ)  =  ∏ᵢ Expr Δ (El cᵢ)
```

**A context morphism out of a list of codes is exactly an argument list of that
many typed expressions, on the nose.** That is the whole calling convention, and
it was in the library before this document. So:

> **A function is a named plan over the context of its parameters:**
> `function f (p₁ : c₁, …, pₙ : cₙ) -> k` denotes
> `Pf : Plan Γf (El k)` where `Γf = cₙ :: … :: c₁ :: []`
> (innermost-first, so `p₁` is the outermost binding, exactly as
> `Bindings.push` builds it).

Three consequences fall out of the type rather than out of a rule, and each is a
property some surveyed system had to bolt on later:

* **A body cannot see the caller.** `Env Γf` has `n` slots. There is no place
  for the caller's environment to arrive. PDL's documented default — "when we
  call a function, we implicitly pass the current background context", with
  `pdl_context: []` as the opt-out — is *unwritable* here, not forbidden.
  (`survey.md`: four of six llm-call DSLs shipped an implicit accumulator and
  every one later bolted on a correction.)
* **A function has a rung of its own.** `level_sub` says
  `level (sub Pf σ) = level Pf`. The cost class of a call is the cost class of
  the function, at every site, in every program. That is *why* a function is a
  substituted term and not a macro: a macro has no rung until it is expanded.
* **The β-law is already proved.** `denote_sub` gives
  `denote (sub Pf σ) δ = denote Pf (σ δ)`, i.e. *the meaning of a call is the
  meaning of the function at the values of its arguments*. No new theorem, no
  new equation, no new fold.

Rejected, with reasons:

* **A macro (textual inlining at parse time).** Bodies duplicate their binders
  per site, so names must be gensym'd; that breaks no-shadowing, breaks
  `known here`, and breaks "who can see it is answerable by searching the page"
  (rule 3). And a macro has no level of its own to state.
* **A closure (`Plan.dyn`).** `dyn` is the quarantine; a call through it would
  make the shape depend on an answer, which is the one thing the surface exists
  to forbid.
* **A `Plan.Cont`.** A continuation is what the *call site* supplies — and it
  does: the rest of the block is the graft's continuation. A function is a value
  producer, on the other side of that graft.

### What a call means

At a site with context `Δ` and names `S : Bindings Δ`, each argument denotes an
`Expr Δ (El cᵢ)`: a **name** denotes its `Binding.val` (at the parameter's kind,
by `Binding.at?`), and a **text** denotes `Prompt.expr S pos chunks` — which is
the general case, with a hole-free literal the constant case. Build

```
σ = fun δ => Env.cons (eₙ δ) (… (Env.cons (e₁ δ) Env.nil)) : Sub Γf Δ
```

and the call is `Plan.sub Pf σ : Plan Δ (El k)`. Then:

* **in a binding**, `x <- f a…` is `Plan.graft (sub Pf σ) (fun _ τ e => Plan.sub rest (fun δ => Env.cons (e δ) (τ δ)))` — which is *character for character* what `bindForm`'s panel case already emits, with the panel's plan replaced by the call's;
* **in a statement** (a `-> receipt` function), `f a…` is `Plan.seq (sub Pf σ) rest`;
* **in a clause** (a panel-free `RawRhs` position: a loop's `review`, a loop's `amend`), it is `sub Pf σ` itself, exactly like `rhsPlan`'s `ask` case.

No new former. No new node. Nothing in `Plan` moves.

### What an import means

A library is not a thing that runs. It is a **plan prefix plus a namespace**.

> `import L` in file F means: F's statements are preceded by L's top-level
> statements, once, and L's defines, functions and top-level bindings are
> reachable from F under the names `L.name`.

"Executes its top-level actions immediately" is the owner's phrase for *is a
prefix*: there is no load time in this semantics because there is no run time
either — the meaning of a file is a `Plan`, and priming is the front of it.
Formally, with `⨟` the splice of one straight-line block onto another's tail,

```
⟦ import L₁ … import Lₘ ; body ⟧  =  ⟦ prime(L₁) ⨟ … ⨟ prime(Lₘ) ⨟ body ⟧
```

with the `Lᵢ` enumerated in **post-order depth-first** over the import graph and
each file emitted **once** (diamond dedup), and with every unqualified name of
`prime(Lᵢ)` rewritten to `Lᵢ.name`. That rewriting is total and capture-free
without any lookup, because *every* unqualified name in a library's priming is
that library's own: priming cannot mention the importer (it is above it) and
cannot mention a parameter (it is not in a body). Names already carrying a dot
were resolved when that library was parsed and are left alone.

Two payoffs worth naming, both consequences of the existing semantics rather
than of new machinery:

* **A closed question is asked once, everywhere.** `Ω = (c : Code) → Q c → El c`
  is total, so identical questions have identical answers. A priming question
  that mentions no earlier binding elaborates to `Plan.askC` with its words *in
  the term*; it is the same `Q` in every program that imports the library, and
  `billMemo` charges it once. Standing context is established once because the
  question is one question, not because a loader remembered something.
* **Priming binds, and the bindings survive.** A library's `guide <- ask …` is
  an ordinary binding of the merged program, reachable downstream as
  `L.guide`. That is what the owner asked for ("primed answers usable
  downstream"), and it costs nothing: it *is* a binding.

### The cost story

Calls are inlined per site, so the cost tree is exact by inheritance rather than
by a new theorem: `Cost.costTree` is a fold over the elaborated `Plan`, and the
elaborated plan has no call node in it. The tree of a program with calls **is**
the tree of its inlining, because the inlining is what the checker built.

Finiteness needs two acyclicity facts, and both are refusals rather than
analyses:

* **Recursion is refused by stratification.** A call head resolves against the
  function table *as it stands*; the table is built left to right, per file, and
  a file's imports are complete before the file is read. So a function may name
  only functions defined earlier — no self-call, no mutual call. The checker
  therefore performs *no recursion over the call graph at all*: each function is
  a finished `Plan` when it enters the table, and a call is one `Plan.sub`.
* **Import cycles are refused** by the in-progress stack of the module walk.

One hazard the acyclicity does not kill, and it must be priced: a DAG inlines
with multiplication (f calls g twice, g calls h twice, …). See
LEVEL-AND-COST for `maxQuestions`, the analogue of `maxRevisions`.

---

## FUNCTIONS

### The form

```
function name ( p₁ : kind , … , pₙ : kind ) -> kind { body }
```

a third top-level form beside `define` and `workflow`, read in the header, in
order, before the body of the file.

*Rejected:* reusing `define` (`define f(x) = …`) — one word would mean two
things, and a define is literal text a hole names; a function is neither text
nor holeable. *Rejected:* curried parameter groups `(a : text) (b : text)` —
they promise partial application, which does not exist here. *Rejected:*
`function name (…) : kind` — the header would then carry two different meanings
of `:` ("the kind of this parameter" and "the kind of the whole function"), and
the second is not a binder's annotation. `->` reads as a signature and costs the
lexer two lines.

### The body

```
body  ::=  "{" { statement } "answer" ref "}"       -- when the result kind is text | verdict | flag
        |  block                                     -- when the result kind is receipt
```

The result is written **`answer <ref>`**, naming a parameter or a binding of the
body. It denotes `Plan.ret e` at that name's expression. `answer` is the
domain's own word: `El c` is an answer, `no answer` is a tag, an addressee
answers. (*Rejected:* `return`, `yield`, `give` — programming words; and the
implicit "last binding is the result", because implicit.)

`answer` names a binding or a parameter and **nothing else**: not a literal
(a function that asks nothing and hands back a constant is a `define`), not a
define, not a function. The parser holds all three tables and says which it
found.

The two-line form costs nothing. `d <- ask model "author" "…"` followed by
`answer d` elaborates to `Plan.ask c s e (Plan.ret (Expr.var .here))`, which is
`Plan.ask1 c s e` — the one-node authoring form, on the nose.

**A `-> receipt` function's body is an ordinary block**, ending the way blocks
end (`stop`, or the statements running out). This is not a second body form: `El
.ack = Unit` (`Question.lean:232`), so `Plan Γf (El .ack)` **is** `Plan Γf Unit`,
which **is** what `checkBlock` returns, and `.empty`'s `Plan.ret (fun _ => ())`
**is** `answer nothing`. The "procedure" the owner asked about is the `.ack`
instance of the one former, discovered rather than added. `answer` in a receipt
body is refused for one spelling; the end of the block is the answer.

### The honest v1 restriction: no branchings, no loops in a body

A body is statements and a result. `if`, `case` and `revising` are refused
inside one. Three reasons, all real:

1. **A value-returning branching has no spelling.** Rule 7 — arms export no
   bindings, because a value leaving an arm would need a sum code and `Ctx`
   holds `Code`s. Arms that each `answer` would be a new consumption discipline,
   not new syntax.
2. **A branching body multiplies the caller invisibly.** `graft` replaces every
   `ret` leaf, so a body with *k* leaves replicates the *caller's remaining
   workflow* *k* times — the tail-replication hazard already recorded for the
   loop's consuming `case`. A one-line call that doubles the program is exactly
   the kind of thing the reader cannot see.
3. It keeps `rhsPlan_level_le`'s statement (`≤ Level.pipeline`) verbatim; see
   LEVEL-AND-COST.

The restriction has a positive statement, and it is the sentence to put in the
reference: **a function is a reusable sequence of questions, not a reusable
decision.** Decisions stay where they are read. The escape is better than the
restriction: return a `flag` or a `verdict` and branch at the call site, where
the branch is visible in the workflow that depends on it.

Loops fall out of the same rule rather than needing their own: a `revising`
result is *pending* and must be consumed by the next statement's `case`, and a
`case` is a branching. In the syntax this is enforced by type — a body's binding
takes a `RawRhs`, not a `RawSource`, so the checker has no case to refuse.

### Parameter and result kinds

| kind | as a parameter | as a result |
|---|---|---|
| `text` | yes | yes |
| `verdict` | yes | yes |
| `flag` | **no** | yes |
| `receipt` | **no** | yes (the procedure) |

A `flag` parameter is refused because nothing in a v1 body can consume one:
`if` is not written in a body, and a flag has no canonical text, so it cannot
reach a hole either. The language refuses to accept what it cannot use, and the
refusal names the reason so the day bodies branch, it lifts.

A `receipt` parameter is refused because a receipt carries no information
(`El .ack = Unit`). A parameter carrying no information is an ordering edge, and
an ordering-only edge was already rejected once, on the record
(`survey.md` [K], against Dagster's `deps=`): ordering is the sequence of
statements.

Verdict parameters are the reason to have parameters at all: the survey's
[L]/(a) note — "`review -> verdict` and `amend (why : verdict) -> patch` already
are that pattern at the one place clause boundaries exist" — is precisely this
form, and it was recorded as "the shape to use if a reusable sub-program former
is ever added".

### Defines, and the namespace

* **Defines are visible inside a body** and this is not implicit context: a
  define is literal text expanded by the parser, so after expansion a body
  mentions no name that is not a parameter or its own binding. `{L.verdictSpec}`
  in a library function is the ergonomic escape that covers most of what
  caller-visibility would have bought.
* **The three namespaces are pairwise disjoint.** A binder may not spell a
  define (today's `freshOfDefines`); extended: a binder, a parameter and a
  function may not spell a define, a function, or an imported module's name.
  Every name in a program means exactly one thing, which is round thirteen's
  argument (delete the sigil, let disjointness decide) applied to two new
  tables. A hole `{f}` naming a function is refused by name — "a function is not
  text; call it and bind its answer".
* **A function may not be named a word that begins a statement or a header:**
  `ask panel revising if case known stop answer` and `import define function
  workflow`. A function name is read exactly where those words are read, so one
  of the two must yield, and the closed list is short enough to print in the
  refusal. This also turns today's confusing parse error for `case <- ask …`
  into a diagnosis; the same check is applied to binders.
* Parameter names are local to their body and collide with nothing: a body's
  initial `Bindings` is exactly its parameters, so there is nothing to shadow.
  Two functions may reuse a parameter name.

---

## CALLS

### Juxtaposition, made deterministic

```
call  ::=  fnref { arg } { labelled-fence }
arg   ::=  ref | text | "$" name
```

**Every argument is exactly one token.** That is the whole determinism argument,
and it is bought by one refusal: **a call may not be an argument.** A nested
call would need parentheses, parentheses are an expression grammar, and rule 3
says there is no expression language. Feed one call to another by binding:
`d <- draft spec` then `r <- review d`. That is sharing-by-binding, and it is
what makes the dataflow searchable.

**The deciding rule is arity, not lookahead.** The parser holds the function
table (functions are declared in the header, before the body, and imports are
complete before the file is read), so at a call head it knows *n* and reads
exactly *n* argument tokens.

**Bounded lookahead, proved.**

*At a statement head*, the token is `}` (the block ends) or an ident. If the
ident is one of the eight statement words, that production is taken. Otherwise
the tables decide: a function name begins a call statement; anything else begins
a binding, whose next token must be `:` or `<-`. Every branch is selected by the
current token plus a table — **zero tokens of lookahead**. (The binding branch
then *expects* `:` or `<-`; expectation is not lookahead.)

*At an argument position*, the arity is known and each argument is one token,
classified by the token itself — **zero tokens of lookahead**.

*Why the owner's candidate rule cannot be the deciding rule.* "An ident followed
by `<-` or `:` begins the next statement" separates an argument from a *binding*
and from nothing else. It does not separate an argument from `stop`, from
`ask …`, or from another call statement, none of which is followed by `<-` or
`:`. Concretely, with `notify` of arity 2:

```
notify "ready" 
stop
```

would swallow `stop` as the second argument. The language is newline-insensitive,
so end-of-line cannot rescue it either. The rule is therefore **retained as a
refusal, not as a decision**: while reading `f`'s arguments, an ident
immediately followed by `<-` or `:` is refused as *"`f` takes 3 arguments and the
next statement begins after 2"*. That is one token of lookahead used only to
improve a diagnosis, never to choose a production.

Note the convergence worth stating in the reference: **arity-directed parsing
requires functions before uses, which is the same stratification that refuses
recursion.** One rule buys bounded lookahead and termination of inlining.

*Rejected:* a `call` keyword (`call f a b`). It would make the statement head
keyword-decided and would drop the "a function may not be named a statement
word" rule — but it adds a word saying nothing the head does not, and the
binding form would become `x <- call f a`, which is not the Haskell feel the
owner asked for. The trade is recorded, not taken.

### Where a call may stand

| position | allowed | elaboration |
|---|---|---|
| binding source, `x <- f a…` | yes (result must not be `receipt`) | `graft (sub Pf σ) k` |
| statement, `f a…` | yes (result must be `receipt`) | `seq (sub Pf σ) rest` |
| a loop's `review` clause | yes (must answer `verdict`) | `sub Pf σ` |
| a loop's `amend` clause | yes (must answer the carrier's kind) | `sub Pf σ` |
| a panel member | **no** in v1 | — |
| an argument | **no** | — |
| `answer` | **no** | — |

A `-> receipt` call in a binding is refused ("a receipt binds nothing that can
be consumed"), and a value call as a bare statement is refused the way a bare
`panel` already is ("its answer has nowhere to go: bind it, `x <- f …`").

**Panel members stay questions in v1**, and the refusal is free: the panel
production reads `ask` and only `ask`, so a call there gets an "expected `ask`"
which is improved to name the rule. The reason is not squeamishness. Both menu
entries are read-outs *per member*: `all must approve` sinks to *no answer* on
one silent member, and `at least n` derives its decline note from *the shape's
addressee* (GRAMMAR: "decline notes derive from the shape's addressee — no
parallel list"). A member that is a whole sub-plan has no single addressee and
no single silence, so the read-out's own theorems would have to be restated.
Factor the panel *into* a function instead — `function reviewed (…) -> verdict {
v <- panel, … answer v }` — which is the flagship's own shape and is legal
today. Recorded as the natural v2 extension once the quorum rule lands
(acat-f10).

### Argument checking

* A **name** argument must answer exactly the parameter's kind
  (`Binding.at? c`). No rendering: `f v` at a `text` parameter with `v` a
  verdict is refused, and the refusal names the escape — `f "{v}"`, since the
  hole is the one place a verdict becomes text (round twelve). One spelling per
  idea.
* A **text** argument (quoted string or fenced block) fills a `text` parameter
  and nothing else. Its chunks are elaborated in the **caller's** bindings, so a
  hole in an argument names the caller's names — which is right, because the
  argument is written at the call site.
* A **define** may be an argument, written bare: `harden L.spec`. The parser
  expands it into literal chunks exactly as it expands a hole. This is not a new
  rule; it is round thirteen's rule ("a hole names a define or a binding, and
  the disjoint namespaces decide") at a new position, and it is what makes
  `library.spec` usable as an argument.
* A **binding annotation on a call** is positional, like a panel's: the kind is
  the function's declared result, so `x <- f a` needs no inference and no
  annotation, and an annotation that disagrees is refused at its own position.
* **A call argument is a new ground site for inference.** A name passed at a
  `text` parameter is grounded `text`, at a `verdict` parameter `verdict`. This
  strengthens rule 4 rather than complicating it, and it is positional, like a
  panel member.

### The trailing block, and `$label`

The owner's "special syntax" for a trailing fenced block needs **no rule at
all**. A fenced block is one `str` token, an argument is one token, and arity
decides where the arguments stop. So

```
foo arg1 arg2 ```
  A long argument
```
```

is the ordinary literal-argument rule with the third argument written as a
block. It is legal in any position, not only the last; the *idiom* is trailing
because the existing close rule (`fenceCloses`) lets only whitespace, `,`, `]`
or `}` follow a closing run, so a non-final block argument's successor must
start on a later line. That is the existing rule and it needs no change.

For several long arguments, the `$label` form:

```
foo arg1 arg2 $long1 $long2
```long1
    A long argument
```
```long2
    Another long argument
```
```

**Exactly specified:**

* `$name` lexes to a `Token.label`. A `$` not followed by an ident start is
  refused, naming the form.
* A **labelled fence** is an opening run of *n* ≥ 3 backticks followed
  immediately (no space) by a name, then nothing but whitespace to end of line.
  This is the info-string position the existing rule reserved — the current
  message "nothing but whitespace may follow the opening fence" becomes
  "nothing but a label and whitespace". The **closing** rule is untouched, so a
  pasted ```` ```haskell ```` *inside* a block is still content.
* Labelled fences appear **immediately after the call's arguments**, before
  anything else, in **any order**, one per distinct label the call wrote. This
  is local to the call production: no statement-level machinery, and the
  newline-insensitivity of the language makes "on the following lines" a
  non-issue.
* A label may be written **twice** in one call, and both arguments get those
  words. Repeated use is how sharing works everywhere else in this language;
  refusing it would be the one place a name may not be used twice.
* **Refusals:** a `$label` with no fence; a fence whose label no pending call
  wrote; two fences with the same label in one group; a labelled fence where a
  prompt is expected (`expectStr` refuses it — "a labelled block answers a
  `$label` in a call").
* **Labels never reach the checker.** The parser substitutes each fence's chunks
  for its `$label`, exactly as it expands a define, so a `Raw` mentions only
  things a checker can be asked to resolve. All four refusals above are parse
  time, where the positions are.

*Named hazard:* an author pasting Markdown whose *outer* fence carries an info
string (```` ```haskell ````) now writes a labelled fence. With no pending call
it is refused with a message naming the label rule; the fix is to drop the tag
(this language's blocks have no language tag) or to use a longer fence.

### Dotted references

A reference is `name` or `mod . name` — **exactly one dot**. Two dots are
refused, naming the reason: modules do not nest, because imports are not
re-exported. Dotted names are legal in every *reference* position — holes, call
heads, arguments, `if`/`case` scrutinees, a `revising` subject, `answer`,
`known here` lists — and in **no binder position**: not a `<-` binder, not a
loop's carrier or review name, not a `settled` binder, not an `amend` head, not
a parameter. One sentence carries it: **a dotted name is a reference, never a
binder.** The hole lexer's `scanHole` and the ident lexer share one `scanName`
that implements the one-dot rule, so `{library.spec}` needs no separate story.

---

## IMPORTS

### The two file shapes

```
file  ::=  { header } ( "workflow" block | { primer } )
```

A file with a `workflow` block is a **program**; a file without is a
**library**. Nothing is magic about the name `library` — the owner's example
names a file, and `import library` then `library.spec` is that file's name doing
ordinary work.

A **library's top level is its priming**: bare statements, no braces, no
`workflow` keyword. Braces would be wrong: a block's bindings die at `}`, and
the whole point is that `L.guide` survives into the importer.

A library's priming is **straight-line**: bindings, acts, calls and
`known here`. No `if`, no `case`, no `revising`, no `stop`. Reason, and it is a
consequence rather than a taste: the priming is a *prefix*, so it must have
exactly one exit; a branching prefix would replicate the entire importing
workflow once per arm, and priming is not a decision. This also makes the splice
exact — the block has one `.empty` tail, so "replace the tail" needs no
reasoning about arms.

**A library's top-level bindings must carry their kind annotation.** This is a
new rule and it is load-bearing. Kind inference scans forward for the first
ground use; after the splice, "forward" reaches into the *importer*. Without the
annotation, one importer writing `{L.guide}` and another writing `if L.guide`
would make the library ask two different questions — the `Code` is part of the
`Q`, so it is a different question with a different elicitation schema. A
library's questions must not depend on who imports it. Parameters and results
are annotated by construction, so functions were already immune; this closes the
one hole. The refusal names the annotation, as rule 4's does.

**A program may not be imported** ("`x.wf` has a `workflow` block; a program is
run, not imported") — there is no honest answer to what its workflow block would
mean inside someone else's. **A library may be run**, and running it means its
priming and then nothing; `agent-cat cost library.wf` prices the standing
context, which is worth being able to ask.

### Placement, resolution, order

* `import L` is a header form. Headers are read **in order**, and each may
  reference only what is above it — the same rule `define` already has. Imports
  need not come first; they need only come before their first use.
* **The CLI resolves; the core does not.** A module name is a bare identifier
  and resolves to `<name>.wf` beside the importing file. No paths, no `..`, no
  search path: a name that is a path is a name whose meaning depends on the
  shell's working directory. **All modules of one program live in one
  directory**, so a module name identifies a file program-wide and a dotted name
  means one thing everywhere. (A search path is a later CLI flag, if wanted; it
  would not change the core.)
* *Rejected:* `import L as M`. Two names for one module means two files can
  disagree about what a dotted name means.
* **Execution order** is post-order depth-first over the import graph, in the
  order the `import` lines are written, each file emitted once. So a diamond
  (P imports A and B; both import N) puts N's priming first, once. Within a
  file, headers and statements are in source order.
* **Transitive imports execute but do not export.** If A imports B and P imports
  A, then B's priming runs (it is part of A's meaning) but P sees `A.x` and not
  `B.y`. A name's meaning must be decidable from the file you are reading and
  the files it names. P may `import B` itself to see `B.y`; the dedup makes B's
  priming run once either way.
* **Cycles are refused**, naming the cycle, by the in-progress stack of the
  walk.
* **What is exported:** the library's defines, its functions, and its top-level
  bindings — all three under `L.`. Its *imports* are not re-exported, and its
  function bodies' local names are not exported (they are invisible outside the
  body by construction).

### The API split

The core stays pure: string in, plan out. The core also *asks for* the strings
it needs, so the CLI does the filesystem and nothing else.

```lean
-- pure, in Agentic/Core/Dsl/Parse.lean
def importsOf (s : String) : Except CheckError (List (String × Pos))

def parseProgramWith (ov : List (String × Prompt))
    (mods : List (String × String)) (main : String) : Except CheckError RawProgram

-- pure, in Agentic/Core/Dsl/Check.lean
def checkProgram (prog : RawProgram) : Except CheckError (Plan [] Unit)
def parseAndCheckProgramWith (ov) (mods) (main) : Except CheckError (Plan [] Unit)
```

The CLI loop: read the program, ask `importsOf`, read those files, ask again,
until closed (capped, so a runaway directory is a diagnosis and not a hang);
then one call to `parseAndCheckProgramWith` with the whole map. The core's
module walk recurses on a `Nat` budget — the number of modules — so it reduces in
the kernel like everything else.

**One compatibility theorem is owed**, and it is what keeps every existing
statement true:

```lean
theorem parseAndCheckProgram_eq_of_no_imports
    (ov) (s : String) (h : importsOf s = .ok []) :
    parseAndCheckProgramWith ov [("main", s)] "main" = parseAndCheckWith ov s
```

*Rejected:* checking libraries separately and linking `Plan`s. A library's
priming extends the *context*, so separate checking would need `checkBlock` to
return a context extension — real machinery, for a result the splice reaches
with none. Recorded as the shape to use if a language server ever wants
per-file checking.

### Names across modules

* Exported names are always qualified, so a library can never collide with the
  importer's own names. The shadowing problem is dissolved rather than ruled on.
* Two libraries may both define `spec`; they are `a.spec` and `b.spec`.
* A module's name is reserved program-wide: no define, function, binder or
  parameter may spell it. Otherwise the reader would have to hunt for a dot to
  know what a name is.
* `known here` now lists dotted names (`known here: L.guide, draft`), which is
  the right documentation and cannot rot.
* `--define` matches against the merged define table, so `--define
  library.spec=…` works and a typo is still refused by the existing "this
  program has no `define x` to override".

### The MCP server in v1: imports refused

`workflow_check(source)`, `workflow_start(source)` and the session record's
`source` field are **sourceless** — the surface takes a program as one string,
with no filesystem and no project. An `import` there names something the server
cannot be given. The refusal is exact and cheap (`importsOf source ≠ []` before
anything is parsed) and it is diagnosed like any other refusal, with the
position of the `import` and the two workarounds: inline the library, or use
`agent-cat`.

*Rejected for v1:* a `modules` object argument. It would put a second, wire-only
spelling of the program's file layout into the protocol, which the language
would then have to keep in step with the CLI's resolution rule; and
`workflow_start`'s session would have to carry the whole map for
`workflow_transcript` to reconstruct. Recorded as the shape for the day it is
wanted: a `modules` map plus an explicit statement that the server resolves
nothing.

---

## GRAMMAR

Braces delimit; indentation means nothing; comments run `--` to end of line;
there are no reserved words except the closed list a *name* may not spell.
Changes against the design of record are marked `NEW`.

```
file       ::= { header } ( "workflow" block | { primer } )              -- NEW
header     ::= "import" modname                                          -- NEW
             | "define" name "=" text
             | function                                                  -- NEW

function   ::= "function" name "(" [ param { "," param } ] ")"           -- NEW
                 "->" kind body
param      ::= name ":" ( "text" | "verdict" )                           -- NEW

body       ::= "{" { statement } "answer" ref "}"    -- result kind ≠ receipt
             | block                                 -- result kind = receipt

primer     ::= name ":" kind "<-" rhs                -- annotation MANDATORY  NEW
             | ask
             | callstmt
             | "known" "here" ":" ( "nothing" | ref { "," ref } )

block      ::= "{" statement { statement } "}"
             | "{" "stop" "}"

statement  ::= name [ ":" kind ] "<-" source
             | ask
             | callstmt                                                  -- NEW
             | "if" ref block "else" block
             | "case" ref "{" arms "}"
             | "known" "here" ":" ( "nothing" | ref { "," ref } )

source     ::= rhs | loop
rhs        ::= ask
             | "panel" "," rule "[" ask { "," ask } "]"
             | call                                                      -- NEW
callstmt   ::= call                       -- the head must declare `-> receipt`
call       ::= fnref { arg } { labelled }  -- exactly as many args as fnref declares
arg        ::= ref | text | "$" name                                     -- NEW
labelled   ::= a fenced block whose opening fence carries a label         -- NEW

ask        ::= "ask" "model"  plainstring [ "served" "by" plainstring ]
                              [ "independent" "draw" number ] text
             | "ask" "tool"   plainstring [ "independent" "draw" number ] text
             | "ask" "person" plainstring [ "independent" "draw" number ] text

rule       ::= "all" "must" "approve"
             | "at" "least" number "must" "approve"

loop       ::= "revising" ref "as" name "," "at" "most" number "amendments" "{"
                 name [ ":" kind ] "<-" rhs
                 "amend" name "{" rhs "}"
               "}"

arms       ::= "approved" block "objected" block "no" "answer" block
             | "settled" name block "unsettled" block

kind       ::= "text" | "verdict" | "flag" | "receipt"
name       ::= identStart identCont*
ref        ::= name | modname "." name        -- a reference, never a binder    NEW
fnref      ::= ref
modname    ::= name
text       ::= a quoted string, or a fenced block (block-syntax.md)
plainstring::= a quoted string with no holes
```

**Lexer changes**, all bounded and deterministic:

* `-` peeks one character: `-` opens a comment (unchanged), `>` is the arrow
  `->`, anything else is the existing refusal.
* `$` followed by an ident start lexes `Token.label`; otherwise refused, naming
  the form.
* `(` and `)` join `punctChars`. They appear only in a function header, which is
  where a signature belongs.
* One `scanName` shared by the ident lexer and `scanHole`: a name, then at most
  one `.` followed by a name. Two dots refused by name.
* An opening fence of *n* ≥ 3 backticks may carry a label immediately after the
  run; the rest of the line must be whitespace. A labelled fence lexes to
  `Token.fence label prompt`, which every prompt position refuses.

**Rules the grammar does not carry** (added to GRAMMAR.md's numbered list):

13. **A function is checked once, over its parameters and nothing else.** Its
    body sees its parameters and the defines above it. It does not see the
    caller, the priming, or anything else.
14. **A call is a substitution.** Arity decides where arguments stop; an
    argument is one token; a call may not be an argument.
15. **A function may reference only functions defined above it**, which refuses
    recursion and is the same fact that makes the parse deterministic.
16. **A library is a prefix and a namespace.** Its priming is straight-line, its
    top-level bindings are annotated, and its exports are reached under one dot.
17. **A dotted name is a reference, never a binder**; imports are not
    re-exported, so a name has at most one dot.
18. **One spelling per name**, across defines, functions, modules, binders and
    parameters — and no name may spell a word that begins a statement or a
    header.

---

## REFUSALS

Each new class, with the diagnosis it should carry.

**Functions**

| # | refused | said |
|---|---|---|
| F1 | a `flag` parameter | "nothing in a function body can consume a flag: `if` is not written in a body" |
| F2 | a `receipt` parameter | "a receipt carries no information; a parameter that carries none is an ordering edge, and ordering is the sequence of statements" |
| F3 | `if` / `case` / `revising` in a body | "a function is a reusable sequence of questions, not a reusable decision: return a flag or a verdict and branch where it is read" |
| F4 | a value function not ending in `answer` | "a `-> text` function ends with `answer <name>`" |
| F5 | `answer` in a `-> receipt` function | "a `-> receipt` function hands back nothing; its body ends where its statements end" |
| F6 | `answer` naming a literal, a define or a function | "`answer` names a binding or a parameter" |
| F7 | a function named as a define / another function / a module / a statement word | "one spelling per name" / the closed word list |
| F8 | a self-call or a forward call | "a function may call only functions defined above it, which is what makes a program's cost finite" |

**Calls**

| # | refused | said |
|---|---|---|
| C1 | too few / too many arguments | "`L.drafted` takes 3 arguments and 1 is written" (with the `<-`/`:` boundary as the hint) |
| C2 | an argument of the wrong kind | "`L.reviewed`'s second argument is `patch : text`, but `why` answers `verdict`; a verdict becomes text at a hole, so write `\"{why}\"`" |
| C3 | a call as an argument | "a call is not an argument: bind it, and pass the name" |
| C4 | a `-> receipt` call in a binding | "a receipt binds nothing that can be consumed" |
| C5 | a value call as a bare statement | "its answer has nowhere to go: bind it, `x <- L.f …`" |
| C6 | a call as a panel member | "a panel's members are questions: its rule reads out per member and per addressee. Factor the panel into the function instead" |
| C7 | a `$label` with no fence | "`$rubric` has no block: write ```` ```rubric ```` after the call" |
| C8 | a fence whose label no call wrote | "this block is labelled `rubric`, and no call above it asked for one" |
| C9 | two fences with one label in a group | "one block per label" |
| C10 | a labelled fence where a prompt is expected | "a labelled block answers a `$label` in a call" |

**Imports and names**

| # | refused | said |
|---|---|---|
| I1 | a module with no source | "no source was given for `library`; `agent-cat` looks for `library.wf` beside this file" |
| I2 | an import cycle | "`a` imports `b` imports `a`" |
| I3 | importing a file with `workflow` | "`x.wf` has a `workflow` block; a program is run, not imported" |
| I4 | a branching / loop / `stop` in a library's top level | "a library's top level is its priming, and priming is not a decision: it runs once, before everything" |
| I5 | an unannotated library top-level binding | "a library's questions must not depend on who imports it: write `guide : text <- …`" |
| I6 | a dotted name whose module is not imported | "`m.x` names a module this file does not import; imports are not re-exported" |
| I7 | a name with two dots | "a name has at most one dot: a module and a name in it" |
| I8 | a dot in a binder | "a dotted name is a reference, never a binder" |
| I9 | a hole naming a function | "`f` is a function; a function is not text — call it and bind its answer" |
| I10 | `import` on the MCP surface | "this surface takes one program and has no files to resolve `library` against: inline it, or use `agent-cat`" |

**Resources**

| # | refused | said |
|---|---|---|
| R1 | more than `maxQuestions` question nodes after inlining | "a call is unrolled into the term it writes; this program expands to N questions, and at most 4096 may be named" |

---

## EXAMPLES

### `example/library.wf`

```
-- A library: standing context, shared words, and reusable questions. It has no
-- `workflow` block, so it is imported, not run; its top-level statements are
-- the priming, and they are the first questions of every program that imports
-- it. Its top-level bindings are annotated, because a library's questions must
-- not depend on who imports it.

define spec        = "harden the parser"
define verdictSpec = "Reply with exactly APPROVE if acceptable, or OBJECTION: <one line> if not."
define flagSpec    = "Reply with exactly yes or no."

function drafted (guide : text, goal : text, shape : text) -> text {
  d <- ask model "author" served by "deep" ```
      {guide}
      Draft a patch satisfying:
      {goal}
      {shape}
      Reply with a unified diff only.
  ```
  answer d
}

function reviewed (guide : text, patch : text) -> verdict {
  v <- panel, all must approve [
    ask model "reviewer-correct" ```
        {guide}
        Is this patch correct?
        {patch}
        {verdictSpec}
    ```,
    ask model "reviewer-secure" ```
        {guide}
        Is this patch secure?
        {patch}
        {verdictSpec}
    ```
  ]
  answer v
}

function judged (patch : text, rubric : text, context : text) -> verdict {
  v <- ask model "judge" ```
      {context}
      Judge this patch against the rubric.
      {patch}
      {rubric}
      {verdictSpec}
  ```
  answer v
}

-- A procedure: a reusable act sequence. Its body is an ordinary block, because
-- `El .ack = Unit` and a block already is a plan of a receipt.
function applied (patch : text) -> receipt {
  ask tool "apply" ```
      Apply:
      {patch}
      Write the patched file here, then reply DONE.
  ```
  ask tool "test" "Run the test suite, then reply with its last line."
}

-- The priming. Asked once, before anything an importer writes. The first is a
-- closed question, so it is the same `Q` in every program that imports this
-- file and a memoizing runtime pays for it once.
guide : text <- ask tool "cat" "Write out the house style guide, at most four short lines."

ask model "author" ```
    {guide}
    You are drafting patches for this codebase. Hold this style guide.
```
```

### `example/harden-imported.wf`

```
import library

define aim = "Harden the parser against malformed input, minimally."

workflow {

  known here: library.guide

  -- a dotted function call: two short arguments (a dotted binding, a local
  -- define) and one trailing block
  draft <- library.drafted library.guide aim ```
      Keep the diff under forty lines. The standing objective is:
      {library.spec}
  ```

  result <- revising draft as patch, at most 2 amendments {

    why <- library.reviewed library.guide patch

    amend patch {
      ask model "author" served by "deep" ```
          {library.guide}
          Revise this patch:
          {patch}
          {why}
          Reply with the revised diff only.
      ```
    }
  }

  case result {

    settled patch {

      -- a call with two $labels
      second <- library.judged patch $rubric $context
      ```rubric
          A patch passes when it is minimal, tested, and reversible.
          Nothing else counts.
      ```
      ```context
          {library.guide}
          You have already reviewed this patch once; this is the second reading.
      ```

      case second {
        approved {
          ok <- ask person "owner" ```
              Apply this patch?
              {patch}
              {library.flagSpec}
          ```

          if ok { library.applied patch } else { stop }
        }
        objected { stop }
        no answer { stop }
      }
    }

    unsettled { stop }
  }
}
```

What it shows, item by item: priming acts at load (`guide`, then the standing
act, both spliced before `draft`); a function with two short args and one
trailing block (`library.drafted`); a call with two `$labels`
(`library.judged`); a dotted define in a hole (`{library.spec}`); a dotted
function call (all four); a receipt-returning procedure (`library.applied`, in
statement position inside the `if` arm).

### One ill-typed file per new refusal class

```
-- F1  a flag parameter
function gated (ok : flag) -> text { … }
--       ^ nothing in a function body can consume a flag

-- F3  a branching in a body
function reviewed (p : text) -> verdict { if p { … } else { … } }
--                                        ^ a function is not a reusable decision

-- F4  no answer
function drafted (g : text) -> text { d <- ask model "a" "{g}" }
--                                                          ^ ends with `answer <name>`

-- F8  recursion
function reviewed (p : text) -> verdict { v <- reviewed p  answer v }
--                                             ^ only functions defined above it

-- C1  arity
draft <- library.drafted library.guide
--       ^ takes 3 arguments and 1 is written

-- C2  argument kind
v2 <- library.reviewed why patch
--                     ^ `guide : text`, but `why` answers `verdict`; write "{why}"

-- C3  a call as an argument
v <- library.judged library.drafted g a s $r $c
--                  ^ a call is not an argument: bind it

-- C4/C5 the two directions
r <- library.applied patch        -- a receipt binds nothing
library.reviewed g patch          -- its answer has nowhere to go: bind it

-- C7/C8/C9  labels
v <- library.judged p $rubric     -- $rubric has no block
```rubric …```                     -- (elsewhere) no call above asked for one
```rubric …``` ```rubric …```      -- one block per label

-- I3  importing a program
import harden                     -- harden.wf has a `workflow` block

-- I5  an unannotated library binding
guide <- ask tool "cat" "…"       -- in a library: write `guide : text <- …`

-- I6  an unimported module
{other.spec}                      -- names a module this file does not import

-- F7  collision
define reviewed = "…"
function reviewed (p : text) -> verdict { … }    -- one spelling per name
```

---

## LEVEL-AND-COST

### Every construct's rung

| construct | formers emitted | rung |
|---|---|---|
| `answer x` | `ret` | `batch` |
| a receipt body's end / `stop` | `ret` | `batch` |
| a body binding of a closed ask | `askC` | join with the rest |
| a body binding of an open ask | `ask` | `pipeline` ⊔ rest |
| a body binding of a panel | `zipWith` over `ask`s | `pipeline` |
| a body act | `askC`/`ask` + `sub` | ≤ `pipeline` |
| a call inside a body | `sub` of an earlier body | ≤ `pipeline` (`level_sub`) |
| **a function's plan** | — | **≤ `pipeline`** |
| a call in a binding | `graft (sub Pf σ) k` | ≤ `pipeline` ⊔ `level k` |
| a call statement | `seq (sub Pf σ) rest` | ≤ `pipeline` ⊔ `level rest` |
| a call in a clause | `sub Pf σ` | ≤ `pipeline` |
| a primer statement | as its own statement | unchanged |
| `import` | none | — |

Because v1 bodies have no branching, **no function reaches the branch rung**,
and so `rhsPlan_level_le`'s statement (`level p ≤ Level.pipeline`) survives
verbatim — which matters, because `bindForm_level_le`, `checkBlock_level_le` and
`level_revising_le`'s two hypotheses all consume it at that strength. The
program's rung is what it was: ≤ `branch`, and `= branch` exactly when a
branching is written.

### Which existing lemmas carry the proof

* **`level_sub`** — the load-bearing one. *A call does not move a rung*: renaming
  rewrites only the pure `Expr`s, so `level (sub Pf σ) = level Pf`. Every call
  case is an application of this plus one more lemma.
* **`level_graft_le`** — the binding call, the panel inside a body, and the loop's
  consuming `case`, unchanged.
* **`level_seq_le`** — the call statement (itself a corollary of `level_graft_le`
  and `level_sub`).
* **`level_panel_le'`**, **`level_caseB_le`**, **`level_caseV_le`**,
  **`level_revising_le`** — untouched.

### What the checker's induction needs that does not exist

1. **`bindForm_level_le` generalized.** Today it is stated at `Level.branch`.
   Bodies need it at `Level.pipeline`. One lemma at an arbitrary `ℓ` with
   `Level.pipeline ≤ ℓ`, instantiated twice; the proof is the existing script
   with each `by decide` replaced by the hypothesis.
2. **`FnLevel : FnEnv → Prop`**, the exact analogue of the existing `PendLevel`:
   `∀ e ∈ F, level e.plan ≤ Level.pipeline`. Data in the table, the bound
   outside it — the discipline `Pend` already follows, and the reason is the
   same: the table must stay first-order data that reduces in the kernel.
3. **`checkBody_level_le`** — *the new lemma the induction needs.*
   `FnLevel F → checkBody F Γ S c b = .ok p → level p ≤ Level.pipeline`, by
   structural induction on `RawBody`: five cases (`answer`, `done`, `bind`,
   `act`, `knownHere`), each discharged by (1) or by `level_ret`.
4. **`checkFns_level_le`** — `checkFns fns = .ok F → FnLevel F`, an induction on
   the list where each step is (3) under the `FnLevel` accumulated so far. This
   is where stratification does its proof work: the table only ever grows, so
   the induction hypothesis is always available for the callees.
5. `rhsPlan_level_le`, `checkMembers_level_le`, `bindForm_level_le` and
   `checkBlock_level_le` each gain the `F` parameter and the `FnLevel F`
   hypothesis, threaded unchanged through every recursive call, plus one new
   case each where a call can appear. `parseAndCheck_level_le`'s **statement is
   unchanged**; its proof gains one step through (4).

### Exactness of the cost tree under inlining

`Cost.costTree` folds the elaborated `Plan`. The elaborated plan has no call
node, so there is nothing new to price: **the tree of a program with calls is
the tree of its inlining, because the inlining is what the checker built.** No
new theorem is required for exactness; that is the point of choosing `Plan.sub`
over a call former.

Two things about it should be said out loud rather than left to be discovered.

* **A v1 call multiplies nothing.** A function's plan has no `case` node, so it
  has exactly one `ret` leaf, so grafting the caller's remainder onto it neither
  drops nor duplicates a path: a call adds its body's question nodes to every
  path through the call site and does nothing else. If the reference is to
  promise this, it wants one small lemma — `costTree_graft_caseFree`, that
  `leaves (costTree (graft p k)) = (leaves (costTree k)).map (bill p * ·)` when
  `p` has no `case` — cheap, and flagged here as *optional*: nothing in the
  pipeline needs it.
* **Two calls are two nodes and one answer.** Identical questions get identical
  answers (`Ω` is a total function of questions), so calling a function twice
  with the same arguments asks *one* question twice: `billFresh` charges two
  factors, `billMemo` charges one, and the answer is the same in both. That is
  the pre-existing property of writing a question twice; functions make it easy
  to hit, so the reference should point at `billMemo` where it points at
  `billFresh` today.

### The one new resource limit

Inlining a DAG multiplies: *f* calling *g* twice, *g* calling *h* twice, and so
on, is 2ᵏ nodes. This is the same class of hazard as the loop's unrolling, and it
takes the same answer as `maxRevisions` — a limit refused with an ordinary
`CheckError`, computed **before** elaboration, because the quantity is the size
of the elaboration itself and not merely of its result:

```lean
def maxQuestions : Nat := 4096
```

Each `FnEntry` carries a `nodes : Nat`, the inlined question count, summed over
its statements with a call contributing its callee's `nodes` and a `revising …
at most n` contributing `(n+1)·review + n·amend` — which is the product the
GRAMMAR's recorded obligation ("price the product in `RawBlock.bounded`, not
each numeral") asks for, so this counter subsumes that item rather than adding
to it. The workflow is checked against the same limit.

---

## IMPLEMENTATION-COST, honestly

### Files, and what happens in each

**`Agentic/Core/Dsl/Syntax.lean`** (+~130 lines, no proofs). `RawArg`
(`name | text`, positions), `RawBody` (five constructors; note its `bind` takes a
`RawRhs`, so "no loops in a body" is enforced by the type and the checker has no
case to refuse), `RawFn`, `RawProgram := { fns : List RawFn, main : RawBlock }`,
`RawRhs.call`, `RawBlock.callAct`. `Raw` becomes `RawProgram`.

**`Agentic/Core/Dsl/Parse.lean`** (+~350 lines, the bulk of the work, no
proofs). Lexer: `->`, `$label`, `(`/`)`, the shared `scanName` with the one-dot
rule, labelled fences. Tables: defines (existing), functions (name → params,
result, body), modules, and the closed statement-word list; one `freshName`
checking all four. Productions: `function`, `import`, the call with
arity-directed arguments and its label group, the program/library split. The
module walk: budget-recursive over the module count, with an in-progress stack
for the cycle refusal, parsing each module in post-order and merging its tables
under a prefix. Two structural rewriting passes over `RawBlock`/`RawRhs`/`RawAsk`/
`Prompt`: `qualifyPrimer` (prefix every unqualified name — total and capture-free,
because every unqualified name in a primer is that library's own) and
`qualifyBody` (call heads only — everything else in a body is a parameter or a
body-local binder). Both are ~30 lines each and neither needs fuel.

**`Agentic/Core/Dsl/Check.lean`** (+~180 lines). `FnEnv`/`FnEntry` (`Type 1`,
holding a `Plan`, like `Pend`), `checkFns` (a fold), `checkBody` (five cases),
the call cases in `rhsPlan`/`bindForm`/`checkBlock`, and argument checking. The
one genuinely fiddly piece is the argument substitution: write

```lean
def Ctx.extend : Ctx → List Code → Ctx
  | Γ, []      => Γ
  | Γ, c :: cs => Ctx.extend (c :: Γ) cs

def checkArgs {Δ : Ctx} (S : Bindings Δ) :
    {Γ : Ctx} → Sub Γ Δ → (ps : List Code) → List RawArg →
    Except CheckError (Sub (Ctx.extend Γ ps) Δ)
```

so the parameter context is *computed the same way* in the table (`extend []
params`) and at the call site, the types line up definitionally, and no equality
proof is needed anywhere. `checkBlock` gains `F : FnEnv` as its first parameter,
threaded unchanged.

**`Agentic/Core/Dsl.lean`** (+~150 lines, all proof). Items (1)–(5) of
LEVEL-AND-COST. The mechanical part is real: `checkBlock_level_le`'s script is
fifteen clauses of `simp only [checkBlock] at h; split at h; …`, each of which
gains one bound variable and passes one more hypothesis down. Robust, tedious,
no insight required.

**`Agentic/Core/Explain.lean`.** `parseAndCheckRawWith`'s type changes with
`Raw`; `RawBlock.revisionBounds` walks `prog.main` (a body cannot hold a
`revising`, so nothing else). `Plan.explain` is untouched and, usefully,
`agent-cat plan` now prints the *inlined* term — which is the honest thing to
print, because that is what runs.

**`cli/AgentCat.lean`.** The loader loop (~60 lines of `IO`, with a hard cap on
the module count so a runaway directory is a diagnosis). `--define` needs no
change: the merged define table already contains the qualified names, and the
existing "no such define to override" refusal still catches typos.

**The one tax that is not local: positions must name their file.** After the
splice a diagnosis can point into a library — an unbound hole in a primer, say —
and today the CLI would print it against the *program's* text at the wrong line.
Fix: add `module : String := ""` to `Dsl.Pos`, stamped by the parser as each
module is qualified, and printed by `ToString CheckError`. The field is defaulted
so structure-instance literals (including all thirty-odd in `flagshipRaw`) are
unchanged, but **anonymous constructors `⟨line, col⟩` will not elaborate against
a three-field structure**, and Parse.lean has roughly twenty-five of them.
Introduce `Pos.at (line col : Nat) : Pos` and rewrite them; mechanical, one
commit, no semantic risk. `Mcp.checkErrorJson` gains the field.

**`Agentic/Core/Mcp.lean`.** The import refusal (a three-line guard on
`importsOf` before anything is parsed) plus the schema note; `checkErrorJson`
gains `module`.

### What `flagshipRaw` and the kernel proofs feel

`flagshipRaw` gains a one-line wrapper — `{ fns := [], main := <the existing
term> }` — and is **not re-transcribed**. `checkFns []` reduces to `.ok []` in one
step, `FnEnv` is `[]` throughout, and no clause of `checkBlock` scrutinises it
except a `List.find?` at call heads, of which the flagship has none. So the nine
`decide +kernel` proofs recompute over a plan that is definitionally the one they
computed before, and the honest expectation is *no material change* to the
module's ~107 s. The one thing that can move it is the equation compiler's output
for `checkBlock` with an extra match argument; that is a constant factor and it
must be **measured, not assumed**, since it is the single most expensive module
in the build. `DecidableEq` grows by four constructors, which affects only the
runtime `parse flagshipSource = .ok flagshipRaw` test.

### What the battery needs

1. `parse flagshipSource = .ok flagshipRaw` re-baselines against the wrapper.
2. A small two-file example pinned the flagship way: `parseProgram [(…)] "main"
   = .ok <transcribed RawProgram>`, by `decide` on first-order data. Keep it
   small; the flagship is where large means expensive.
3. **The inlining identity**, which is the statement that a function costs
   nothing: `x <- f a` where `f`'s body is one question is the same `Plan` as the
   question written inline. Propositional, not `rfl` — it closes by `Plan.sub_id`
   and `Env.cons_head_tail` — and worth having as a named theorem. Its receipt
   sibling *is* `rfl`: inlining a one-act procedure is the act.
4. **The label identity**: `f a $x` with a ```` ```x ```` block parses to the same
   `RawProgram` as `f a "…"`. A `decide`, pinning that labels are pure syntax.
5. **Module order and dedup**: a diamond (P imports A and B, both import N)
   whose parsed `main` begins with N's primer exactly once.
6. **The cycle refusal**, and **I3** (importing a program).
7. One `decide` per new refusal class in `DslSmoke`, plus the CLI-level parity
   check (`plan`/`cost`/`run` refuse identically) for the two-file ill-typed
   example, and the module name appearing in the rendered diagnosis.
8. `McpSmoke`: `workflow_check` on a source with an `import` returns the tool
   error with the position of the `import`.
9. A cost `decide` on the library example: leaves, min and max, so the exactness
   claim is a computation and not a sentence.
10. `test/Pollution.lean` unchanged — nothing here declares an instance.

### The honest summary

The new machinery is one table, one substitution and two rewriting passes. The
kernel is untouched, `Plan` is untouched, no former is added, no fuel discipline
is added, and no theorem changes its statement — `parseAndCheck_level_le` is
proved through one new lemma (`checkBody_level_le`) and one generalisation
(`bindForm_level_le` at `pipeline`). The cost is concentrated in three places, in
this order: the parser (arity-directed calls, the module walk, the two
qualification passes), the mechanical widening of `checkBlock_level_le`'s
fifteen clauses, and the `Pos.module` tax across Parse.lean's anonymous
constructors. The risk that deserves a measurement rather than a promise is
`DslFlagship`'s elaboration time under `checkBlock`'s extra parameter.