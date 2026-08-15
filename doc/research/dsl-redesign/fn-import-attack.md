# Adversarial review — functions and imports, round fourteen

**Overall verdict: ADEQUATE.** The central derivation (a function *is* `Plan Γf`, a call *is* `Plan.sub`, an import *is* a prefix plus a namespace) is correct and is the strongest part of the document — it is solved out of `Sub Γ Δ = Env Δ → Env Γ` rather than asserted, and it reuses `graft`/`seq`/`sub` exactly as the existing checker does. No non-negotiable is broken outright. But the document contains five internal contradictions that make it un-implementable as written, one named theorem that is false, one advertised feature (`--define L.x`) that cannot work with the existing machinery, and one construction (`known here` across the splice) that is contradictory in two directions at once. Every defect has a small local repair; none requires re-deriving the design.

---

## (a) MEANING — **strong** core, three major defects

**Credited as sound.** `Sub Γ Δ ≅ ∏ᵢ Expr Δ (El cᵢ)` is exact (`Plan.lean:169`), so the calling convention is the library's, not a new one. `Γf = Ctx.extend [] params` computed the same way in the table and at the call site does make the types line up definitionally with no cast — I checked the fold: after `p₁`, `σ₁ = fun δ => Env.cons (e₁ δ) Env.nil : Sub [c₁] Δ`; after `p₂`, `Sub [c₂,c₁] Δ`; and `Bindings.push` builds the matching `Bindings` in the same order (`Check.lean:94`). The binding-call elaboration is character-for-character `bindForm`'s panel case (`Check.lean:323-324`). No clause reaches `dyn`: `sub`, `graft` and `seq` are all dyn-free by construction (`Plan.lean:448-451`). The `Cont` rejection is right — `Cont Γ A B = ∀ Δ, Sub Γ Δ → Expr Δ A → Plan Δ B` takes one value, not an argument list.

### A1 — **major** — the design silently adds a third consumption site and does not amend rule 3

GRAMMAR.md rule 3: *"Two consumption sites, and no third. `{x}` in a prompt, and `if x` / `case x`… which is what makes 'who can see it' answerable by searching the page."* `f v` consumes `v` at neither site, and sends it into a body that may live in another file. The document notices the inference half of this ("A call argument is a new ground site… This strengthens rule 4") and never notices the consumption half, while claiming "No new rule."

*Repair (smallest):* restate rule 3 as three consumption sites — a hole, a branching, and an argument — and add the sentence that makes it still answerable: *an argument's flow is followed by reading one signature, and a parameter is visible only inside one body.* This is honest and costs the design nothing; leaving it unstated is what makes the round-13 "delete the sigil, disjointness decides" argument look like it was applied to a rule it was never tested against.

### A2 — **major** — `-> receipt` bodies as "an ordinary block" contradicts F3, `FnLevel`, and "a v1 call multiplies nothing"

The grammar writes `body ::= … | block -- result kind = receipt`, and `block`'s `statement` includes `if`, `case`, `known here`, and `name [":" kind] "<-" source` with `source ::= rhs | loop`. So a `-> receipt` body may branch and may loop. That falsifies, in the same document:

- **F3** ("`if`/`case`/`revising` in a body" refused) and its stated mechanism (*"a body's binding takes a `RawRhs`, not a `RawSource`, so the checker has no case to refuse"*) — that mechanism is `RawBody`, which the receipt half does not use;
- **`FnLevel F : ∀ e ∈ F, level e.plan ≤ Level.pipeline`**, hence `checkBody_level_le` and `checkFns_level_le` (items 2–4 of LEVEL-AND-COST) — a branching body is at `branch`;
- **"A v1 call multiplies nothing… A function's plan has no `case` node, so it has exactly one `ret` leaf."** With *k* leaves, `seq (sub Pf σ) rest` grafts the caller's entire remainder at all *k*.

The sharpest form is at the import boundary, which the review brief asks about directly: a **library primer** may contain a `callstmt`; if that call's head is a branchy `-> receipt` function, the "prefix" no longer has one exit, the splice's "replace the one `.empty` tail" reasoning fails, and **the whole importing workflow is replicated once per arm of a library's priming**. I4 ("a branching in a library's top level") does not catch it — the branching is behind a call.

It also genuinely falsifies `rhsPlan_level_le`'s statement, not merely `FnLevel`: `s : receipt <- ask tool "t" "go"` is writable today (GRAMMAR.md:27-28 records `: receipt` on a bound ask as "a refusal to add"), so `r <- revising s as c, at most 2 amendments { v <- ask model "m" "ok?"  amend c { branchyReceiptFn } }` puts a branch-rung plan through `rhsPlan .ack` (`Check.lean:475`).

*Repair:* one line. Give the receipt body the same restricted form as the value body — statements only, no branchings, no loops — terminated by the statements running out instead of by `answer`. `RawBody` gains a `done` constructor emitting `Plan.ret (fun _ => ())`; `El .ack = Unit` (`Question.lean:232`) still makes the types work. Drop the "it *is* what `checkBlock` returns" reuse claim; it is what buys the bug.

### A3 — **major** — the inlining identity (battery item 3) is false, and it costs a rung

> *"`x <- f a` where `f`'s body is one question is the same `Plan` as the question written inline. Propositional, not `rfl` — it closes by `Plan.sub_id` and `Env.cons_head_tail`."*

Counterexample with a **literal** argument:

```
function g (p : text) -> text { d <- ask model "m" "{p}"  answer d }
x <- g "hi"          vs.        x <- ask model "m" "hi"
```

The call gives `Plan.ask .text s (fun δ => (σ δ).head) (ret (var .here))`. Written inline, `Prompt.closed ["hi"] = some "hi"` (`Syntax.lean:140`, `Check.lean:315`), so the checker emits **`Plan.askC`**. Different constructors — not equal, not propositionally, not at all. The theorem holds only when every argument is a *name*.

The consequence is larger than the theorem. **A question reached through a call can never be closed**, because a parameter is always an `Expr`. So factoring a standing prompt into a function moves it from `batch` to `pipeline` and forfeits precisely the IMPORTS payoff the document leads with ("A closed question is asked once, everywhere… it is the same `Q` in every program that imports the library"). That payoff survives only for primer statements *written directly* — as the example does — and is lost for anything a library exports as a function.

*Repair:* restate the theorem with "every argument is a name" as a hypothesis; and add one sentence to the reference: *a function's questions are open questions; a standing prompt that must be closed is written as a primer statement or a define, not behind a parameter.* (A zero-parameter `-> text` function stays closed and is the escape.)

### A4 — **minor** — memoization is preserved, but a function cannot be called at a fresh draw

The claim is right: `Ω` is total, so two calls with equal argument *values* are one question — `billFresh` twice, `billMemo` once. What follows and is not said: `independent draw n` lives in the shape, inside the body, so **there is no call-site spelling for "ask this again, independently."** `f x` twice is one answer, silently. This is rule "sharing is by binding" behaving correctly, but functions make it easy to hit by accident. Add it to REFUSALS/Hazards rather than leaving it to be discovered.

### A5 — **minor** — the argument substitution should use `Env.consBy`, not `Env.cons`

`checkArgs` builds `fun δ => Env.cons (eᵢ δ) (σ δ)`, and `Env.cons` is eager in its tail (`Plan.lean:93`). Reading *any* parameter therefore forces *all n* argument expressions — including block arguments with holes — at every question of the body, and inside `revising`'s unrolling once per round. This is the same shape as the measurement recorded in `Plan.lean:56-80` (3 ms → 122 s), which is why `Sub.lift` uses `consBy` (`Plan.lean:191`). Use `Env.consBy (eᵢ δ) (fun _ => σ δ)`; `consBy_eq_cons` is `rfl`, so nothing else moves.

---

## (b) DETERMINISM — **adequate**

**Credited.** Arity-directed parsing is genuinely deterministic and the "an argument is exactly one token" refusal is what buys it. I could not construct an ambiguity: the label group is local to the call production and closes on the first non-labelled-fence token, so consecutive calls each reusing `$x` parse correctly; `f (g x)` is closed off (`(` lexes as punct, then "expected an argument"); the design's own C3 example `library.judged library.drafted g a s $r $c` does fire C3 at argument 1. `fenceCloses` already permits `}` after a closing run (`Parse.lean:199`), so a trailing-block argument inside `if ok { … }` works.

### B1 — **major** — the retained boundary refusal covers `<-`/`:` only, so every other statement word is swallowed with a nonsense diagnosis

The document constructs `notify "ready"` / `stop` to argue *against* the owner's rule, then adopts arity and leaves the same program mis-diagnosed. With `notify` of arity 2, `stop` is an ident and `arg ::= ref | …` accepts it; the checker then says *"unbound name; nothing in scope answers to it: `stop`"* (`Check.lean:99`). Worse in a body:

```
function f (a : text) -> text {
  notify a          -- notify has arity 2
  answer a
}
```

`answer` is read as argument 2, the body terminator vanishes, and F4 fires at the wrong token. The same happens with `if`, `case`, `known`, `ask`, and a following call statement.

*Repair:* the closed word list already exists (rule 18). While reading arguments, refuse an ident drawn from it with C1's message — *"`notify` takes 2 arguments and the next statement begins after 1."* One list lookup, still zero lookahead, and it turns the language's worst diagnosis into its best.

### B2 — **minor** — a dotted statement head that is not a known function is diagnosed as a binding

`libary.drafted g a s` → not in the function table → binding branch → `expected `<-`` at `g`. But rule 17 says a dotted name is *never* a binder, so a dotted head is unambiguously a call. Route it to the call production and refuse by name: *"no function `libary.drafted`."*

### B3 — **minor** — a non-final block argument on one line dies with "never closed"

The document is right that a non-final block argument is legal and that the constraint is `fenceCloses` (`Parse.lean:191-200`). It does not say what happens when an author writes `foo ``` … ``` arg2` on one line: the run does not close, the rest of the file is swallowed as content, and the diagnosis is *"this fence of 3 backticks is never closed"* pointing at the opening. Widening `fenceCloses`'s follower set would break the "a pasted ```` ```haskell ```` inside a block is content" property, so the repair is diagnosis-only: when a fence is never closed, report the first line whose leading run of exactly *n* backticks was followed by a disallowed character.

### B4 — **minor** — `(`/`)` in `punctChars` trades a clean lexical refusal for a distant parse error

Today `(` is "unexpected character" at its own position. After the change it lexes silently everywhere and surfaces as "expected an argument"/"expected a statement" somewhere else. Since `(`/`)` occur in exactly one production, refuse them at lex time outside a function header, or keep the C3 message keyed on the `(` token specifically.

---

## (c) COST AND LEVEL — **adequate**

**Credited.** `level_sub` (`Level.lean:190`) does carry every call case; the generalization of `bindForm_level_le` to arbitrary `ℓ` with `pipeline ≤ ℓ` works (I checked all three cases — the `ask` case needs exactly `pipeline ≤ ℓ`, the `askC` and panel cases need nothing new). Nothing in the composition reaches `dyn`. A call in a loop clause is `sub Pf σ` and does not move the rung. The `parseAndCheck_level_le` statement does survive unchanged.

### C1 — **major** — `maxQuestions` does not price the loop's tail replication, and claims to subsume the obligation that names it

The proposed counter sums statements, "with a `revising … at most n` contributing `(n+1)·review + n·amend`," and asserts this "subsumes" the recorded obligation *"graft replicates the loop's tail once per exit: price the product in `RawBlock.bounded`, not each numeral."*

It does not. `Plan.revising check revise n` has **n+1 `ret` leaves** (`Plan.lean:611-623`: `revising 0` has one; `revising (n+1)` adds one), and `checkBlock`'s consuming case is `Plan.graft pd.plan (finishCont settledP unsettledP)` (`Check.lean:533`), so **`settledP` and `unsettledP` — the entire rest of the workflow — occur n+1 times in the elaborated term.** At `maxRevisions = 64` that is 65×; and a second `revising` inside a `settled` arm is writable today (`Parse.lean:692` parses a full block there), giving 65² ≈ 4200 copies, each carrying whatever calls were inlined into it. The proposed sum bounds none of this, so R1 does not bound the size of the elaboration it exists to bound.

*Repair:* make `nodes` a genuine size-of-elaboration recurrence over `RawBlock` rather than a sum, with the `caseResult` case `(n+1)·(settled + unsettled)` and the call case `callee.nodes`. Then it really does subsume `RawBlock.bounded`; as written it replaces a correct obligation with an incorrect one.

### C2 — **minor** — the stated reason for "no branchings in a body" is not the real reason

> *"It keeps `rhsPlan_level_le`'s statement (`≤ Level.pipeline`) verbatim… which matters, because `bindForm_level_le`, `checkBlock_level_le` and `level_revising_le`'s two hypotheses all consume it at that strength."*

They do not. Both consumers immediately weaken it: `Dsl.lean:202` is `le_trans (rhsPlan_level_le …) (by decide)` into `branch`, and `Dsl.lean:308-313` does the same for `level_revising_le`'s `hc`/`hr` at `ℓ := branch`. Restating `rhsPlan_level_le` at `≤ branch` would break nothing in the current file. The restriction is justified — but by reason 2 (tail replication), which is the one that actually bites. Saying reason 3 is load-bearing when it is not invites someone to lift the restriction the day reason 3 is relaxed.

### C3 — **fallout of A2** — `checkBody_level_le` and `checkFns_level_le` are unprovable at `pipeline` while receipt bodies are blocks

Stated here because it is the concrete proof obligation that fails, not merely a grammar inconsistency. With the A2 repair both go through as described.

---

## (d) HYGIENE — **weak**

**Credited, and this is the part that is genuinely well argued.** `qualifyPrimer` really is total and capture-free with no lookup: defines are already expanded by `parseAsk` before a `RawAsk` exists (`Parse.lean:460-461`), primers have no loops so there is no carrier or `settled` binder to worry about, and a primer cannot mention the importer. I5 (mandatory annotations on library top-level bindings) genuinely closes the inference-across-the-boundary hole — `bindKind` returns the annotation and never runs `useKindB` (`Check.lean:247-258`), so the `Code`, and hence the `Q`, cannot depend on the importer. `{library.spec}` needs no new hole story: `Bindings.find?` and `usePrompt` compare strings (`Check.lean:89`, `:211`), so a dotted `Chunk.interp "library.guide"` resolves with no change beyond `scanName`. Parameter/binder capture is handled by `freshName` because a body's initial `Bindings` is exactly its parameters.

### D1 — **major** — `known here` is contradictory in both directions after the splice

`checkBlock`'s `knownHere` compares the written list against **every** live name (`Check.lean:394-399`). Two consequences the design does not reconcile:

1. *The importer must name what it is forbidden to name.* "Transitive imports execute but do not export" + I6 ("a dotted name whose module is not imported") means P may not write `N.guide`; but N's primer binding **is** live in the merged program, so P's first `known here` must list `N.guide` or be refused.
2. *A library's own `known here` depends on its importer.* `library.wf` writing `known here: guide` is correct in a program that imports only it, and refused in a program that imports `other` first — the live list is then `library.guide, other.x`. That is exactly the failure mode I5 exists to prevent, one production over.

*Repair:* refuse `known here` in a primer (it asserts a fact about a prefix the library cannot see), and drop "transitive imports do not export" — since each module is emitted once and module names are reserved, `N.x` already means one thing program-wide, so hiding it buys nothing and costs this contradiction. One rule fewer, and `known here` becomes writable again in the importer.

### D2 — **major** — I6 has no mechanism in the described passes

For a library A whose function body calls `N.f`, the merged function table **must** contain `N.f` — otherwise A's exported functions do not resolve after the merge. So the merged table cannot be the thing I6 checks against. `qualifyPrimer`/`qualifyBody` are described as blanket prefixing passes with "no lookup", carrying no per-file visibility, so nothing in the design can distinguish "P wrote `N.x`" from "A wrote `N.x`".

*Repair:* make I6 a **parse-time check in each file's own scope**, against that file's own `import` list, before the merge. It is cheaper than a post-merge check and it is the only place the information exists.

### D3 — **major** — `--define library.spec=…` cannot work

The document asserts *"`--define` matches against the merged define table, so `--define library.spec=… ` works."* It cannot. Defines are expanded into literal chunks at parse time, per file (`Parse.lean:452-461`), and the override is applied inside `parseDefines` by matching `ov.find? (fun o => o.1 == x)` against the name **as written in that file** — `spec`, not `library.spec` (`Parse.lean:755`). By the time a merged table exists, every use of `spec` in `library.wf` is already literal text. Worse, `parseWith`'s guard *"this program has no `define x` to override"* (`Parse.lean:783-785`) will reject the flag outright.

*Repair:* `parseProgramWith` routes overrides by prefix — module `L` is parsed with `{k' ↦ v | (L.k', v) ∈ ov}`, key stripped — and the "no such define" guard runs once over the union of all modules' define names after the walk.

### D4 — **minor** — "a module's name is reserved program-wide" makes a library's validity depend on its importer

A library binding `other : text <- …` is fine in one program and refused in a program that also writes `import other`. That is the same disease I5 diagnoses. Scope the reservation to the file: a name may not spell a module *that file imports*, nor the file's own name.

### D5 — **minor** — nothing refuses two parameters with the same name

`function f (a : text, a : text) -> text` is not refused by any stated rule. It falls out for free if parameters are pushed through `freshName`; say so.

### D6 — **minor** — `answer` is listed as a dotted-legal position but can never take a dotted name

"Dotted names are legal in every reference position — … `answer`, `known here` lists." A body sees only its parameters and the defines above it (rule 13), so `answer L.x` is unreachable by construction. The dotted positions inside a body are exactly two: call heads, and holes naming dotted **defines** (`{L.verdictSpec}`).

---

## (e) UX AGAINST THE OWNER'S SYNTAX — **strong**, with one example-breaking defect

**Both owner forms are honored exactly as written.** `foo arg1 arg2 ``` … ``` ` is the ordinary literal-argument rule with arity deciding the stop — no new rule, exactly as claimed. `foo arg1 arg2 $long1 $long2` with labelled fences after the call is fully specified, refuses cleanly in all four failure modes, and never reaches the checker. A **block argument that is not last is legal**, and the document correctly identifies the one constraint (its successor must start on a later line, by `fenceCloses`) rather than pretending it is unrestricted. `library.spec` works in every reference position that is not a binder — including a `revising` subject, which `lookupBinding` resolves by string with no change (`Check.lean:460`).

### E1 — **major** — two of the three value functions in the design's own example do not check

`answer` is not a ground site for kind inference. `useKindB` has no case for it, and `bindKind` refuses a binding with no ground use, naming the annotation (`Check.lean:230-258`). So in `example/library.wf`:

```
function drafted (guide : text, goal : text, shape : text) -> text {
  d <- ask model "author" served by "deep" ```…```
  answer d                                   -- `d` has no ground use
}
```

is refused with *"nothing fixes what kind of answer `d` names."* Same for `judged`'s `v`. Only `reviewed` survives, because a panel is grounded positionally (`Check.lean:417-419`). The document's own two-line motivating form (*"`d <- ask …` followed by `answer d` elaborates to `Plan.ask1`, on the nose"*) is exactly the form that fails.

*Repair:* add one ground site — **`answer x` grounds `x` at the function's declared result kind** — positional, like a panel member and like the new argument site, and add the `answer` case to the body's `useKind` scan. This is a two-line change and it makes the example correct.

### E2 — **minor** — the shape functions cannot factor is the shape the language repeats most

`revising` is refused in a body, and it is the flagship's own structure. So the one thing an author writes twice is the one thing that cannot be abstracted. The v1 restriction is well-argued and I would keep it, but the reference should say this out loud beside "a function is a reusable sequence of questions, not a reusable decision," because a reader who has just written two loops will look for it first.

### E3 — **minor** — a call in an arm invites the fence-outside-the-brace mistake

`if ok { library.applied patch $note }` followed by ```` ```note ```` on the next line is the natural thing to write and is refused twice (C7 then C8) with no hint that the block belongs *inside* the brace. Give C7 the placement: *"`$note` has no block: write ```` ```note ```` after the call and before the `}` that closes this block."*

---

## Two smaller corrections worth folding in

- **The compatibility theorem is false as stated.** `parseAndCheckProgram_eq_of_no_imports` hypothesises only `importsOf s = .ok []`. Take `s = "function f () -> receipt { ask tool \"t\" \"go\" }  workflow { f }"`: `importsOf s = .ok []`, the left side is `.ok p`, and the right side is `.error` (the old `parseWith` reaches `expectKw "workflow"` at `function`, `Parse.lean:787`). Either add "and no `function` header" to the hypothesis, or — better — define the old entry point *as* the new one at the singleton map, so the compatibility statement is `rfl` and there is nothing to prove.

- **The document's own headline example does not exercise its own closed-question payoff.** The library's standing act holes `{guide}`, so it elaborates to `Plan.ask`, not `Plan.askC`. The claim survives — the act's words are a function of a closed question's answer, and `Ω` is total, so the `Q` is still the same in every importer — but the stated reason ("A closed question is asked once, everywhere") is not the reason. The reason is Ω's determinism plus the prefix being identical. Worth fixing in the prose, because A3 shows the closed/open distinction is doing real work elsewhere.

---

## What I would fix before writing any Lean

In this order, because the first three change the grammar and the tables:

1. Receipt bodies get the restricted body form (A2) — one grammar line, and it restores F3, `FnLevel`, `checkBody_level_le`, and the no-multiplication property.
2. `answer` becomes a ground site (E1) — two lines, and it makes the example check.
3. Drop "transitive imports do not export", refuse `known here` in a primer, and move I6 to parse time in each file's own scope (D1, D2).
4. Route `--define` overrides by module prefix in `parseProgramWith` (D3).
5. Make `nodes` a size-of-elaboration recurrence with the `(n+1)·tail` factor (C1).
6. Refuse the closed statement-word list at argument positions (B1).
7. Amend rule 3 to three consumption sites; restate the inlining identity with "every argument is a name"; state that a call's questions are never closed (A1, A3).

Files read: `/Users/johnw/src/agent-cat/doc/research/dsl-redesign/GRAMMAR.md`, `/Users/johnw/src/agent-cat/Agentic/Core/Dsl/Parse.lean`, `/Users/johnw/src/agent-cat/Agentic/Core/Dsl/Check.lean`, `/Users/johnw/src/agent-cat/Agentic/Core/Dsl/Syntax.lean`, `/Users/johnw/src/agent-cat/Agentic/Core/Plan.lean`, `/Users/johnw/src/agent-cat/Agentic/Core/Dsl.lean`, plus targeted reads of `/Users/johnw/src/agent-cat/Agentic/Core/Level.lean`, `/Users/johnw/src/agent-cat/Agentic/Core/Cost.lean`, `/Users/johnw/src/agent-cat/Agentic/Core/Question.lean`.