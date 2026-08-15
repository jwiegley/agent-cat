# Panel rules: what a panel *is*, and the closed menu of ways to read one

Answer to the owner's question, in one sentence up front: **"all must approve" is not a syntactic wart and it is not a boolean expression — it is one point of a one-parameter family of folds, the parameter being a threshold `n` between 1 and the number of members.** So the phrase stays, it becomes mandatory, and the menu has exactly three entries, all of them the same equation at different `n`.

Paths below are relative to `/private/tmp/claude-501/-Users-johnw-src-agent-cat/b2c08087-6acb-43d8-8ba4-e7c90b1ca4b5/scratchpad/dsl-review-snapshot/`. This document is also at `/private/tmp/claude-501/-Users-johnw-src-agent-cat/b2c08087-6acb-43d8-8ba4-e7c90b1ca4b5/scratchpad/wg-panelrules/design.md`.

---

## MEANING

### A panel is k questions and a fold of their k verdicts

A panel of `k` members denotes two things and nothing else:

1. **k questions**, asked in written order. This part is fixed. No rule on the menu changes which questions are asked, how many, or in what order — `trace_panel` (`Agentic/Core/Denote.lean:378`) says the transcript is the concatenation of the members' transcripts, and every fold below leaves that equation untouched. **The menu is a menu of read-outs, not of schedules.** That single fact is what makes the whole family cost exactly `k`.

2. **a fold** `φ : Verdict^k → Verdict` of the k answers.

Written as the morphism equation the package already states for the unanimity case (`run_panel`, `Denote.lean:365`), generalized to an arbitrary fold:

```
run   ω (denote (panel_φ ps) γ) = φ (ps.map (fun p => run ω (denote p γ)))
trace ω (denote (panel_φ ps) γ) = (ps.map (fun p => trace ω (denote p γ))).flatten
```

The second equation is independent of `φ`. That is the whole cost story.

### The fold is not an arbitrary k-ary function: it factors

Doctrine step 6 — adopt the standard structure rather than a bespoke one. Every fold worth having factors as

```
φ  =  ρ ∘ foldMap μ            μ : Verdict → M   (per member),  ρ : M → Verdict
```

for a monoid `M`: measure each member into `M`, combine with `M`'s product, read out. `Plan.lean:562` already anticipates exactly this — *"Quorum, 'everyone approved' and the objection product are all this one equation at three monoids"* — and `Plan.lean:570` names quorum as *"a morphism out of (ℕ,+)"*. This design is that sentence taken literally.

Fix the measurement once, for the whole family. For member `i` with verdict `v`:

```
μᵢ(v) = ( approvals , answers , notes )
        approvals = 1 if v = approve else 0                 in (ℕ,+)
        answers   = 0 if v = declined else 1                in (ℕ,+)
        notes     = []            if v = approve
                    reasons v     if v objected
                    ["<addresseeᵢ> did not answer"]  if v = declined
```

`M = (ℕ,+) × (ℕ,+) × FreeMonoid Objection`. The addressee's name is *term-level data* (`Q.Shape.addressee`, `Question.lean:289`), so the decline note is a closed string the checker computes; nothing is looked up at run time.

Write `A` for the approvals, `S` for the answers and `R` for the concatenated notes of a run. Then the whole menu is three lines:

```
[[panel, at least n must approve]]  =  if S < n      then declined
                                       else if A ≥ n then approve
                                       else               object R

[[panel, all must approve]]         =  [[panel, at least k must approve]]
                                    =  v₁ * v₂ * … * v_k          (the monoid product)

[[panel, a majority must approve]]  =  [[panel, at least (⌊k/2⌋+1) must approve]]
```

The first line reads, in English: *the panel has no answer when too few members answered for the threshold to be reachable; otherwise it approves when the threshold is met, and otherwise it objects, quoting everything that was said against it.*

### Why the second line is an equality and not an analogy

At `n = k`: `S < k` ⟺ somebody declined ⟹ `declined`, which is what the zero of `WithZero` does (`declined_mul`, `mul_declined`, `Question.lean:149-152`). `A ≥ k` ⟺ everybody approved, which is `approved_prod` (`Question.lean:198`). Otherwise nobody declined, so `R` contains no decline notes and is exactly the concatenation of the objection lists, which is `object_mul_object` (`Question.lean:139`). Every case agrees on the nose, so

> **the annihilating monoid product is the quorum fold at its top threshold.**

That is the load-bearing result of this document. It means the menu is one meaning with three spellings, not three meanings; it means `all must approve` can keep elaborating to the existing `Plan.panel` verbatim (zero proof churn); and it means the objection-annihilation hazard **acat-88m** is not a wart of the panel but a fact about the threshold `n = k`, where it is arguably correct.

---

## RULES

Each rule below gets: the equation, the treatment of objections, the treatment of declines (acat-88m: inherit or fix — decided deliberately), what `{v.reasons}` means, the elaboration, and the result kind.

Two facts hold for **every** rule and are not repeated:

* **Result kind is `verdict`, always.** Three reasons, any one sufficient. (a) `Verdict` is the only `El c` carrying a monoid, declared only at `.verdict` and deliberately so (`Plan.lean:558-562`); a panel of flags would need a chosen monoid on `Bool` and *nothing picks between `∧` and `∨`* — picking would be the boolean expression language coming in by the back door. (b) The `revising` loop's review position demands a verdict, and seeding a revising loop is what panels are for. (c) `VTag` (`Plan.lean:495`) gives a downstream `case` the same three arms after every rule, so a reader who learns one panel has learned all of them.
* **Cost is exactly `k` questions, in every world, under every rule.** Verified below against `Cost.lean`.

### R1 — `all must approve` — ADOPT (unchanged)

```
[[all]] (v₁…v_k) = v₁ * … * v_k
```

* **Objections:** concatenated, in member order. The order is a record and is preserved; `Verdict`'s monoid is deliberately non-commutative.
* **Declines:** **annihilate. acat-88m INHERITED, deliberately.** One silent member erases every other member's objections and the panel answers `declined`. The decision is deliberate because at `n = k` a decline is not an opinion the panel can outvote — it makes the panel's own question unanswerable, and the `no answer` arm exists precisely so a workflow can escalate rather than amend. Demoting a decline to an objection under a rule *named* "all must approve" would silently convert "the security reviewer never looked" into "the security reviewer had a complaint", which is worse than losing the reasons.
* **`{v.reasons}`:** every objection every member raised, joined by `"; "` (`Verdict.render`, `HardenPatch.lean:91`). **When a member declines, this is the empty string** — the concrete, checkable face of acat-88m: the `amend` clause receives a revision request with nothing in it. One line in the reference says so, and points at R2 as the way out.
* **Elaboration:** `Plan.panel ps` — the existing derived form, untouched.
* **Kind:** verdict.

### R2 — `at least n must approve` — ADOPT (new)

```
[[at least n]] (v₁…v_k) = if S < n then declined else if A ≥ n then approve else object R
```

* **Objections:** every non-approving member's objections, concatenated in member order, plus one stated line per member who did not answer.
* **Declines:** **do not annihilate. acat-88m FIXED for n < k, deliberately.** A decline counts as a non-approval and contributes a note. The reasoning is denotational rather than merciful: the count `A` is *already* a lossy read-out that forgets which member said what, so there is nothing left for annihilation to protect; and a quorum that discarded four reviewers' objections because a fifth timed out would be indefensible. The annihilation survives only where it is true — `S < n`, i.e. *even if every member who answered had approved, the threshold could not have been met*. That is "the panel could not decide", and it is the honest reading of `declined`. At `n = k` this degenerates to R1 exactly, so nothing is special-cased.
* **`{v.reasons}`:** the objections of the members who did not approve, plus `"<name> did not answer"` for each silent member. Empty in exactly two cases: the panel approved (nothing to say), or the panel could not decide (`declined`, the residual hazard, now confined to the case where fewer than `n` members spoke at all).
* **Elaboration:** `Plan.panelQuorum n notes ps` — new *derived* combinator, built from `mapP` and `zipWith`, **no new `Plan` former, no kernel change**.
* **Kind:** verdict.
* **`n = 1` is the owner's "at least 1 must approve"**, and it is also every sensible reading of "any may approve": the panel approves if anybody approved, declines only if *nobody answered*, and otherwise objects with the whole record. No separate rule is needed for it.

### R3 — `a majority must approve` — ADOPT (new, sugar with a reason)

```
[[a majority]] = [[at least (⌊k/2⌋+1)]]          -- strictly more than half
```

Everything else is R2's. It earns its own phrase for one reason that `at least 2` cannot give: **it is stable under editing the member list.** Add a fourth reviewer to `at least 2 must approve` and the rule silently becomes "half", which nobody wrote down; add one to `a majority must approve` and the threshold follows. Refused when `k < 3`, where a majority is everybody (see REFUSALS).

### R4 — `any may veto` — REFUSE (not distinct)

A veto rule says the panel fails if anybody objects, i.e. it approves iff everybody approves, i.e. `n = k`, i.e. R1. It is R1 said from the other side. One meaning, one spelling — the doctrine's anti-pattern 8.

Two honest caveats worth a line in the reference:

* **The duality is exact only when nobody declines.** "All must approve" and "any may veto" agree on approvals and objections but a decline is neither an approval nor a veto; the family resolves this by counting *answers* (`S`) separately from *approvals* (`A`), which is why `M` has two ℕ factors and not one.
* **The genuinely different thing people mean by "veto" is early exit** — stop asking once someone objects. That is not a fold; it changes *which questions are asked*, so it is a different plan with a data-dependent bill of 1…k (a `case` between asks, `branch` rung, a cost tree with unequal leaves). It is already writable as nested asks and a `case`. It is not a panel and must not be spelled as one; see REFUSALS.

### R5 — `best of n` — REFUSE, with the workaround shown

**The claim that it is already writable is true.** Checked against the round-8 surface: `independent draw` is a member of the vocabulary, the draw is a field of the question *shape* (`Question.lean:294`), and kinds are inferred from consumption sites. So generate-n-then-judge is:

````
draft1 <- ask model "author" independent draw 1 ```{$spec}
    Reply with a unified diff only.```
draft2 <- ask model "author" independent draw 2 ```{$spec}
    Reply with a unified diff only.```
draft3 <- ask model "author" independent draw 3 ```{$spec}
    Reply with a unified diff only.```

best <- ask model "judge" ```
    Three candidate patches follow. Reply with the best one, verbatim, nothing else.
    A:
    {draft1}
    B:
    {draft2}
    C:
    {draft3}
```
````

Four questions, `pipeline` rung, exact bill of 4, no new syntax, no new kernel. `independent draw` is *required*, not decorative: without it the three asks are the same question, and the world is a function of the question, so they would be the same answer three times over — the language makes resampling explicit instead of hoping the runtime is nondeterministic.

Why refusing it as a *panel rule* is the right answer and not a dodge:

* A panel folds **verdicts**; best-of ranks **candidates**. They do not share a carrier, a result kind, or a shape — a panel is `k` questions and a pure fold, while best-of is `n` questions **and one more question**. Calling the second a panel rule would make the word "panel" mean "some questions and then possibly another question", and the cost claim (`exactly k`) would stop being true of the construct's name.
* The judge is a model, so the scorer is not pure. Every kernel in the dossier that made `bestOf` look applicative did it with a pure `argmax` (`doc/research/attack-adequacy.md:256`); with a real judge the shape is n asks then one ask, which is what the four lines above already write.

One honest limitation to record in the reference: the judge **re-emits** the winner rather than *selecting* it, because selecting candidate `i` would need either an expression language (index a list) or a k-way tag to `case` on, and the language has neither. The mitigation is the prompt (`verbatim`), the same mitigation the language already leans on for "reply with a unified diff only".

### R6 — `at most n may object` — REFUSE (redundant and trappy)

The complement threshold. Agrees with `at least (k−n) must approve` when nobody declines and disagrees when somebody does — and the disagreement is invisible in the phrase, which is exactly the kind of trap the menu exists to prevent.

### R7 — weighted / named vetoes ("the security reviewer is binding") — REFUSE

A predicate over member identities is the boolean expression language with a domain-flavoured name. There is no closed phrase for it, and the workaround is honest and already available: put the binding reviewer in its own `panel, all must approve` (or a bare `ask`) and the advisory ones in another.

---

## SURFACE

**Chosen: an explicit rule phrase on every panel, from a closed menu of three.**

```
source ::= ask
         | "panel" "," panelrule "[" ask { "," ask } "]"

panelrule ::= "all" "must" "approve"
            | "at" "least" number "must" "approve"
            | "a" "majority" "must" "approve"
```

Applying the house rule — *a keyword says what it means to a cold reader* — the moment the menu has more than one entry, a bare `panel [...]` is a silent default, and a reader who has not memorized the reference cannot tell whether this panel blocks on one objection or two. The phrase costs four words on a construct that already spans a dozen lines, and it is read before the members, which is the order the reader needs. **Bare `panel [...]` is therefore refused, not defaulted.**

Applying the no-expression-language rule:

* The menu is a **closed set of three phrases**, each naming a single fold. There is no grammar for combining them: no `and`, no `or`, no `not`, no parentheses, no comparison operators, no member predicates.
* The **only** free parameter anywhere in the menu is one numeral in one phrase.
* **The numeral is checked against `k` — at check time, not parse time**, and the reason is consistency: every other panel refusal already lives in `checkRhs` (`Check.lean:249` "a panel needs at least one member", `Check.lean:231` kind agreement, `Check.lean:256` monoid availability), and "your threshold does not fit your member list" is the same species of complaint at the same position. Three refusals, each naming both numbers:
  * `n = 0` or `n > k` — out of range.
  * `n = k` — *"at least 3 of 3 is `all must approve`; write that"*. One meaning, one spelling; the anti-synonym rule applied to the numeral.
  * `a majority` with `k < 3` — *"a majority of two is both of them; write `all must approve`"*, since `⌊k/2⌋+1 = k` for `k ≤ 2`.

  Consequence stated honestly: this is a checker-enforced side condition on a `Raw` that could hold an out-of-range numeral — the "invariant maintained by documentation" anti-pattern in miniature. It is bought off by the fact that `checkRhs` is the *only* consumer of the rule field, so there is nowhere else the condition could be violated.
* The written form is kept in `Raw` (`all` / `atLeast n` / `majority` as three constructors) and normalized to a threshold only in the checker. Normalizing in the parser would destroy exactly the information the anti-synonym refusals need.

Parse determinism: after `panel` comes `,`, then one token of lookahead decides — `all`, `at`, `a` are three distinct identifiers. No lexer change, no new reserved words (the language has none; positions decide, `Parse.lean:46`).

### The two elaborations, and which one wins

Both were checked against `Level.lean` and `Cost.lean`. Both stay `≤ branch` and both cost exactly `k`. They are not equally good.

**(A) Applicative chain with the read-out at the leaf — ADOPTED.**

```
panelQuorum n notes ps = mapP ρₙ (foldr (zipWith (·*·)) (ret 1) (ps.zipWith mapP μᵢ))
```

The threshold is a *pure read-out in the `ret` leaf's `Expr`*, not a branch — `Expr Γ A = Env Γ → A` is an arbitrary pure function of what is known (`Plan.lean:147`), and `zipWith` takes an arbitrary `f : A → B → C` (`Plan.lean:442`). Nothing about a threshold needs a `case`.

* **Level.** After the grafts normalize, the term is `k` nested `ask` nodes ending in one `ret`. `level_ask` (`Level.lean:134`) gives `max pipeline …`, `level_ret` gives `batch`, so `level = pipeline`. Stated lemma-wise: `level_mapP` is an *equality* (`Level.lean:277`) and `level_zipWith_le` is the join (`Level.lean:283`), so the induction of `level_panel_le` (`Level.lean:299`) transfers verbatim.
* **Cost.** `costTree` (`Cost.lean:668`) on that term is `map (p₁ *) (map (p₂ *) (… (leaf 1)))` — **one leaf**, `p₁ * … * p_k`, world-independent. Exactly `k` events, exactly `k` charges, and `bill_mem_leaves` (`Cost.lean:691`) is trivially exact rather than merely sound.
* **The decisive argument.** `checkRhs_level_le` (`Dsl.lean:200`) currently states `level v.plan ≤ Level.pipeline` — *strictly stronger* than the `≤ branch` that `parseAndCheck_level_le` needs — and its docstring records the design commitment: *"nothing in the language's expression layer reaches the branch rung at all — the branching does that, and only the branching."* Elaboration (A) keeps that theorem's statement **unchanged**. Elaboration (B) would falsify it.

**(B) Bind k, then `case` over an `Expr` — REFUSED.**

`k` asks binding `v₁…v_k`, then `case (fun γ => thresholdTag n γ)` with `ret` arms. `level_case` (`Level.lean:137`) gives `max branch (sup batch) = branch`; `costTree` gives `node T (fun _ => leaf 1)` under the `k` price maps, so every leaf equals `p₁ * … * p_k` and the bill is still exactly `k`. So it is *sound* — but it costs a rung for nothing, it weakens `checkRhs_level_le` from `pipeline` to `branch`, and it puts arms in the term that nothing branches on. It exists in this document only to be ruled out: **a threshold is a read-out, not a branch.**

### What survives reordering (unchanged by the menu)

The scheduling licences are stated on `panel` today and hold, word for word, for the family, because they are facts about the trace and about `Approved`: `trace_panel_perm` (`Denote.lean:442`), `billFresh_panel_perm` (`Cost.lean:247`), `approved_panel_perm` (`Denote.lean:413`). The aggregate verdict is still *not* permutation-invariant, and for the same reason as before: the count is commutative but the objection list is a record.

---

## REFUSALS

Each with the one line it gets in the reference.

| Refused | The line in the reference |
|---|---|
| bare `panel [ … ]` | *A panel that does not say its rule leaves the reader to guess which of three it is.* |
| `panel, any may veto` | *That is `all must approve` said from the other side; one meaning, one spelling.* |
| `panel, any must approve` / `panel, at least one may approve` | *Write `at least 1 must approve`; the family already has that point.* |
| `panel, at most n may object` | *The same threshold in the complement, and it disagrees with `at least n must approve` about silent members — where the disagreement is invisible in the phrase.* |
| `panel, best of 3` | *A panel folds verdicts; best-of ranks candidates and needs a judge, which is another question, not a fold. Write n draws and one judge ask.* |
| `panel, 60% must approve` / fractions / `k-1` | *The threshold is a numeral you can check against the member list by eye; a percentage needs a rounding rule, which is a second decision nobody wrote down.* |
| boolean combinations of rules | *The menu is a set of names, not a syntax; there is nothing to combine them with.* |
| per-member weights or a binding member | *That is a predicate over members, i.e. an expression language. Put the binding member in its own panel.* |
| early exit / short-circuit veto | *Stopping early changes which questions are asked, so it is a different program with a bill between 1 and k. Write the asks and a `case`.* |
| `panel` at `flag` or `text` | *Only `verdict` carries a monoid, and nothing picks between `and` and `or` on a yes/no.* (already refused, `Check.lean:256`; the reason gets sharper) |
| `at least k must approve` (numeral equal to member count) | *That is `all must approve`; write that.* |
| `a majority must approve` with fewer than three members | *A majority of two is both of them; write `all must approve`.* |
| **not refused, filed** — a `declined` verdict that carries reasons | *The verdict monoid's zero has no payload, so a panel that cannot decide has nothing to quote; carrying both would change `El .verdict` and every proof about the product.* (acat-88m, standing) |

The last row is the honest one. The principled repair is the doctrine's own diagnostic — *a bias silently lost means the element type is wrong* — and it is to replace `WithZero (FreeMonoid Objection)` with something like `FreeMonoid Objection × Any`, so that "somebody refused" is a flag beside the record rather than a zero on top of it. That is a kernel change touching `El`, `VTag`, the three `case` arms, and every theorem about `declined_mul`. It is out of scope for a panel-rule menu, and this design deliberately shrinks its blast radius instead: after R2, annihilation fires only when the threshold was unreachable, and at `n = k` — where it is the correct answer anyway.

---

## EXAMPLES

### The flagship's panel, in the chosen syntax (unchanged text)

````
result <- revising draft as patch, at most 2 revisions {

  verdict <- panel, all must approve [
    ask model "reviewer-correct" ```
        {guide}
        Is this patch correct?
        {patch}
        {$verdictSpec}
    ```,
    ask model "reviewer-secure" ```
        {guide}
        Is this patch secure?
        {patch}
        {$verdictSpec}
    ```,
    ask model "reviewer-simple" ```
        Could this patch be simpler?
        {patch}
        {$verdictSpec}
    ```
  ]

  amend {
    ask model "author" via "deep" ```
        {guide}
        Revise this patch:
        {patch}
        {verdict.reasons}
        Reply with the revised diff only.
    ```
  }
}
````

Byte-identical to `flagship-v4.wf`. `all must approve` was already the written phrase, so the flagship does not move, its elaboration does not move, and `denote_flagshipPlan` stays a `rfl`.

### One quorum example — two of three reviewers

````
verdict <- panel, at least 2 must approve [
  ask model "reviewer-correct" ```{guide}
      Is this patch correct?
      {patch}
      {$verdictSpec}```,
  ask model "reviewer-secure" ```{guide}
      Is this patch secure?
      {patch}
      {$verdictSpec}```,
  ask model "reviewer-simple" ```Could this patch be simpler?
      {patch}
      {$verdictSpec}```
]
````

Reading: three questions, always; approves when two of the three approve; answers `no answer` only if two or more reviewers are silent (the threshold is then unreachable); otherwise objects, and `{verdict.reasons}` hands the `amend` clause the dissenters' objections *plus* a line for any silent reviewer — which is the case where `all must approve` would have handed it an empty string.

### The same rule doing self-consistency voting

````
safe <- panel, a majority must approve [
  ask model "auditor" independent draw 1 ```{$auditSpec}
      {patch}```,
  ask model "auditor" independent draw 2 ```{$auditSpec}
      {patch}```,
  ask model "auditor" independent draw 3 ```{$auditSpec}
      {patch}```
]
````

Three independent draws of one question to one addressee, majority vote. Legal because `draw` is a shape field, and *necessary*: drop `independent draw` and the three members are literally the same question, hence the same answer, and the vote decides nothing while costing three. (A cheap optional refusal for exactly this footgun is listed in the cost table below.)

---

## IMPLEMENTATION-COST

**No kernel change.** `Code`, `El`, `Verdict`, `VTag`, `Q`, and the five `Plan` formers are all untouched. No new constructor anywhere in the meaning; the new combinator is *derived*, like `panel` itself.

| Where | What | Size |
|---|---|---|
| `Agentic/Core/Dsl/Syntax.lean:189` | new `inductive PanelRule \| all \| atLeast (n : Nat) \| majority`, `deriving Repr, DecidableEq, Inhabited`; `RawRhs.panel` gains a `rule : PanelRule` field | ~8 lines + one field |
| — matches on `.panel` | `RawRhs.pos` (`Syntax.lean:244`), the parser's constructor site, `checkRhs`, `checkBinder`, and three `cases r with \| panel` in `Dsl.lean` all gain one bound name; all but the checker can bind `_` | ~6 one-token edits |
| `Agentic/Core/Dsl/Parse.lean:344` | `parsePanelRule`: consume `,` then one of three fixed token sequences, one token of lookahead. **No lexer change, no new reserved words** | ~20 lines |
| `Agentic/Core/Dsl/Check.lean:245` | `checkRhs`'s `.panel` clause matches the rule, computes `n` from the member count, emits `Plan.panel` for `all` (**unchanged path**) or `Plan.panelQuorum` otherwise | ~15 lines |
| `Check.lean` (same clause) | three new refusal messages: out of range; `n = k`; `majority` with `k < 3` | ~9 lines |
| `Agentic/Core/Plan.lean:585` | new derived `Plan.panelQuorum (n : Nat) (notes : List String) (ps : …)` from `mapP` + `zipWith` at `M = Multiplicative ℕ × Multiplicative ℕ × FreeMonoid Objection`, plus `ρₙ` | ~14 lines; pulls `Mathlib.Algebra.Group.TypeTags` into `Plan.lean` (already in the build via `Cost.lean`'s `tick`) |
| `Agentic/Core/Level.lean:299` | **the one level lemma that extends**: `level_panelQuorum_le`, the same induction as `level_panel_le`, resting on the same two lemmas (`level_mapP` equality, `level_zipWith_le` join) | ~8 lines |
| `Agentic/Core/Dsl.lean:112` | `level_panelQuorum_le'`, the checker-shaped variant of the above, mirroring `level_panel_le'` | ~7 lines |
| `Agentic/Core/Dsl.lean:200` | `checkRhs_level_le` gains one `split` arm. **Its statement — `≤ Level.pipeline` — does not weaken**, which is why `checkBinder_level_le`, `checkBlock_level_le` and `parseAndCheck_level_le` keep their statements *and* their proofs | ~6 lines |
| `Agentic/Core/Cost.lean` | **nothing.** `costTree` is defined on formers and `panelQuorum` introduces none | 0 |
| `Agentic/Core/Denote.lean:365` | *optional*: `run_panelQuorum` (the foldMap morphism equation) and `trace_panelQuorum` (`= flatten`, mirroring `trace_panel`), which is what upgrades "exactly k" from a corollary of `bill_mem_leaves` to a stated theorem | ~20 lines, not required to compile |
| `Agentic/Core/Denote.lean` | *optional but recommended*: the agreement lemma `panelQuorum k ps ≐ panel ps`, which is what licenses calling this one family | ~30–60 lines, fiddly; nothing depends on it |
| `Check.lean` | *optional, recommended*: refuse two syntactically identical members in one panel (`RawAsk` has `DecidableEq`) — *"these two members ask the identical question, so they get the identical answer; add `independent draw n` or change the addressee"* | ~6 lines |
| reference doc | three rows for the menu, one line per rule on how it treats a silent member, one line on the `best of n` workaround | prose |

**What does not move.** `flagship-v4.wf` is unchanged text and elaborates to the same `Plan` (its panel is `all must approve`, which still means `Plan.panel`), so `denote_flagshipPlan` stays a `rfl` and the nineteen `decide +kernel` cost proofs in `DslFlagship.lean` are untouched. No existing theorem statement is weakened; one is extended by a branch, one new lemma is added at each of two levels.

Total: roughly 100 lines of code, 25 lines of proof, three new refusal messages, one new derived combinator, zero new kernel constructs.