## VERDICT: **weak** — 1 fatal, 6 major, 5 minor. The machinery checks out; the thesis does not.

What survives verification is real and should be kept: the level/cost arithmetic, the elaboration choice (A over B), and the n=k case analysis. What fails is the document's headline claim and, more seriously, both of the rationales it leans on at the one place it matters — inside `revising`.

---

## (a) Meaning equations and elaboration claims

**FATAL — the "one-parameter family of folds" is vacuous; ρ is not a homomorphism.**
The document's answer to the owner is that R1 and R2 are "the same equation at different `n`", justified by `φ = ρ ∘ foldMap μ`. But `ρₙ` is not a monoid morphism: `ρₙ(1_M) = ρₙ(0,0,[]) = declined ≠ 1_Verdict` for every `n ≥ 1`. With ρ unconstrained, the factorization has **zero content** — every k-ary `Verdict^k → Verdict` factors through the free monoid on `Verdict` with μ = inclusion. So "the fold is not an arbitrary k-ary function: it factors" is true of arbitrary k-ary functions. R1 *is* a fold (`foldMap` into `Verdict`, `Denote.lean:365`). R2 at n<k is a fold **plus a cut**, and the cut is exactly the part that carries the meaning.

The concrete cost the design never notices: **R1 is associative, R2 is not.** `panel[panel[a,b],c] = panel[a,b,c]` holds for R1 by `mul_assoc` and fails for R2 at n=2. The design has traded a law for a parameter — doctrine step 6 and anti-pattern 10 inverted — and presents the trade as unification. The honest reframing ("R1 is the monoid fold; R2 is a counted read-out that happens to agree with it at n=k") costs the document its one-sentence answer, which is presumably why it wasn't reached.

**Verified correct (credit).** The n=k equality is exact, case by case, against the real formers: `S<k ⟺ somebody declined ⟹ declined` (`declined_mul`/`mul_declined`, `Question.lean:149,152`); `A≥k ⟺ approved_prod` (`Question.lean:198`); otherwise `R` is the objection concatenation, `object_mul_object` (`Question.lean:139`). Note `object [] = approve` definitionally (`approved_object_iff`, `Question.lean:172`), so μ's three-way case split is well defined and exhaustive. Good.

**Verified correct — bind-k-then-case (B) really is `≤ branch` with cost exactly k.** `level_case` (`Level.lean:137`) gives `max branch (sup batch) = branch`; `costTree`'s case clause (`Cost.lean:677`) emits `.node T _ (fun t => costTree (arms t))` with every arm a `ret` → `leaf 1`, then the k enclosing `ask` clauses (`Cost.lean:673`) apply `map (price · *)` uniformly, so every leaf is `p₁*…*p_k` and `bill_mem_leaves` (`Cost.lean:691`) is exact. The design's conclusion is right and its reason for refusing (B) is right. One wording error: "puts arms in the term that nothing branches on" — the `case` genuinely branches on the threshold tag; the correct objection is that the branch is *pure*, not that it is absent.

**Verified correct — (A) is `pipeline` with cost k.** `level_mapP` is an equality (`Level.lean:277`), `level_zipWith_le` is the join (`Level.lean:283`), and members are `ask1` = `pipeline` (`Level.lean:321`). `checkRhs_level_le`'s statement (`Dsl.lean:197`, docstring quoted accurately) does survive.

**MAJOR — the `object R` branch must never return `object []`, and nothing says so.**
If it ever did, the verdict would *be* `approve` (`object [] = 1`) and `revising` would silently settle. The property does hold — `A < n ≤ S` forces at least one objector, and an objector's list is nonempty because an empty one is `approve` — but this is a two-step argument on which the entire loop contract rests, and the document does not state it, let alone prove it. It is also fragile: any future μ that emits `[]` for some non-approving member breaks it.

**MAJOR — the `notes : List String` parameter is an unchecked parallel-array invariant.**
`Plan.panelQuorum n notes ps` with `List.zipWith` **silently truncates** on length mismatch, dropping members from the fold while leaving them in the trace — cost k, verdict over fewer than k. This is anti-pattern 9 ("invariant maintained by documentation") in the very combinator the document introduces, and unlike the threshold it gets no checker refusal. It is also the doctrine's own diagnostic firing in plain sight: *"the equation requires an argument that is not available ⟹ the specification is not compositional."* The design passes a side list instead of augmenting the specification.

**MINOR — the stated elaboration does not typecheck.** `ps.zipWith mapP μᵢ` is `List.zipWith (f : Plan → ? → ?) ps ?`, but `mapP` takes its function first and `μᵢ` is not a list. Trivially fixable, but it is the document's only definition of the new combinator.

**MINOR — misattributed citation.** "Quorum, 'everyone approved' and the objection product are all this one equation at three monoids" is at `Denote.lean:364` and `Morphism.lean:396`, not `Plan.lean:562` (which is `instMonoidElVerdict`). `Plan.lean:570` for the `(ℕ,+)` remark is correct. `Check.lean` citations drift by ~1–5 lines (249 ✓, 231 ✓, "256" is 257).

**MINOR — "hold, word for word" is false for `approved_panel_perm`.** `trace_panel_perm` (`Denote.lean:442`) and `billFresh_panel_perm` (`Cost.lean:247`) are trace facts and do transfer. `approved_panel_perm` (`Denote.lean:413`) is proved by `rw [run_panel, approved_prod_el]` — a rewrite against the *product*. Under R2 the aggregate is not a product, so the theorem is still **true** (approval ⟺ `A ≥ n`, and `A` is a count) but needs a new proof. The design lists it as unchanged.

---

## The quorum verdict's objection story: what `{verdict.reasons}` actually shows

Concretely, k=3, `at least 2 must approve`, two objectors and one decliner: A=0, S=2, so `S ≥ n` and `A < n` → `object R` with

```
R = obj₁ ++ obj₂ ++ ["<addressee₃> did not answer"]
```

and `{verdict.reasons}` renders as `"obj₁; obj₂; addressee₃ did not answer"` (`HardenPatch.render`, line 91, `String.intercalate "; "` over `objections`, which returns `[]` on `declined` — the design's empty-string claim for R1 is confirmed by real code). So the mechanism works. Three things about it are not coherent:

**MAJOR — R2 does exactly what R1's rationale calls indefensible.** R1 argues the decline must annihilate because demoting it "would silently convert 'the security reviewer never looked' into 'the security reviewer had a complaint', which is worse than losing the reasons." R2 then performs precisely that demotion, and the only thing distinguishing the two afterwards is an English sentence in a `String` channel — `Objection := String`, so there is no type-level distinction and no downstream consumer can recover it. The document states both arguments approvingly, on facing pages, without noticing they are the same argument with opposite conclusions.

**MAJOR — presentation has been pulled into the meaning.** The panel's denotation now depends on a rendered English sentence built from `Addressee`. That requires a chosen rendering nobody has written down (`model "x"` → `x`? `model x`?), and it is **not injective on members**: the document's own self-consistency example is three `ask model "auditor" independent draw i` members, so two decliners produce two identical, indistinguishable notes with the draw index lost. This is the doctrine's founding diagnosis (presentation vs. modelling) and its "strip the incidental" step, both violated in the one place the design adds meaning.

**MAJOR — the approve branch discards `R` entirely, and this is unremarked.** With `at least 1 must approve`, k=3, one approver and two objectors: `A=1 ≥ 1` → `approve` = `1`, `render approve = ""`. Two reviewers' objections are destroyed with no trace and no diagnostic. Under R1 this is impossible (approve ⟺ everyone approved ⟺ R empty). R2 therefore introduces a *second* silent-loss hazard, structurally identical to acat-88m but on the approval side, and the document's ledger records only the decline side ("Empty in exactly two cases"). It is wrong: there is a third.

---

## (c) Interaction with the revising loop

**FATAL to R1's stated justification — `revising` has no "no answer" arm.**
R1 defends inheriting acat-88m with: *"the `no answer` arm exists precisely so a workflow can escalate rather than amend."* Read `Plan.revising` (`Plan.lean:611–623`). The check's result is consumed by

```lean
caseB (fun θ => Verdict.approvedB (v θ)) (.ret … some …) (graft (revise …) …)
```

— a **two-way** `caseB` on `approvedB`, i.e. `v = approve`. There is no third arm. A `declined` panel verdict is not distinguishable from an objecting one inside the loop: it takes the revise branch and hands `amend` an empty `{verdict.reasons}`, burning a real `ask` on a revision request that says nothing, for up to `n` rounds, before falling out as `unsettled` at fuel 0. The escalation arm the design invokes exists only in the *outer* `case result { settled / unsettled }`, which is reached after the budget is spent and which cannot tell "the reviewers objected until we ran out of tries" from "the security reviewer never answered." So R1's central defence is false in the flagship's own program, which is the only program in the document.

R2 narrows but does not remove this: it fires whenever `S < n`, e.g. `at least 2 must approve` with two silent reviewers — amend with an empty string, twice, then `unsettled`.

**Credit where due.** The design *did* notice the loop contract in the general form: every rule yields `verdict`, panels of `flag` are refused with a correct reason (nothing picks between `∧` and `∨`; `Check.lean:257` already refuses non-verdict panels), and `Verdict.approvedB` is the exit test for all three rules. Point (c)'s "any rule that yields a flag breaks the loop contract" was anticipated and answered. The failure is one level down, in the *justification* rather than the typing.

---

## (b) Cold reading

- `all must approve` — a cold reader gets the approval condition right and the failure payload wrong. They will not guess that one silent member erases three objections. Acceptable only because the document says so out loud.
- `at least 2 must approve` — two wrong guesses. (i) A reader will not guess that two silent members yield *no answer* rather than *rejection*, nor that "no answer" is what drives the amend loop. (ii) A reader will not guess that approving at 2-of-3 **deletes** the third's objection.
- **MAJOR — `a majority must approve` is ambiguous in exactly the way the menu exists to prevent.** Majority of *members* or of *answers*? With k=5, two declines, two approvals and one objection: the design gives `object` (A=2 < 3); a reader who understood "majority" as "of those who answered" expects `approve`. The REFUSALS table refuses `at most n may object` precisely because "the disagreement is invisible in the phrase" — the same defect is present here and goes unlisted. (The arithmetic itself is fine: `⌊k/2⌋+1` is strictly-more-than-half for all k, and the `k<3` refusal is consistent.)
- **MAJOR — R3 violates the anti-synonym rule the document enforces one row above.** `[[a majority]] = [[at least ⌊k/2⌋+1]]` is asserted as an *equality of meanings*. With k=3, `at least 2 must approve` and `a majority must approve` are both legal and denote the same fold — two spellings, one meaning, the thing R4 is refused for being. The stability-under-editing argument is a fact about programmers, not meanings, and is not available to a document that refuses `any may veto` on purely denotational grounds.

---

## (d) The best-of-n workaround, against the actual grammar

**MAJOR — `independent draw n` is not shown to exist, and the only evidence in the snapshot contradicts its spelling.** The design's support is `Question.lean:294`, a field of `Q.Shape` — a *kernel* citation offered for a *surface* claim. The only parser in the snapshot spells it `draw <nat>`, positioned immediately after the addressee string and *before* `using model`/`for` (`Parse.lean:267`, `parseTarget`, and `Syntax.lean:171`). The word `independent` appears nowhere in `Parse.lean`, `Syntax.lean` or `Check.lean` except in a docstring. Meanwhile the design's own SURFACE section gives a grammar in which `ask` is an unexpanded nonterminal, so it never exhibits the production that would make its four-line example parse — in particular where `independent draw 1` sits relative to round-8's `via "deep"`. The claim "**checked** against the round-8 surface" is not supported by anything in the document or the snapshot.

Everything *else* about R5 is right: four questions, `pipeline`, exact bill of 4; the argument that the draw index is necessary (Ω is a function of the question) is sound; the refusal reasoning (a panel is k questions and a pure fold, best-of is n questions **and one more question**) is the correct distinction; and the `attack-adequacy.md:256` citation about pure-`argmax` kernels is accurate. So R5's *conclusion* survives, but its "the claim that it is already writable is true" is currently unverified and, on the only evidence available, misspelled.

---

## (e) An expression language in disguise?

**Yes, mildly — not in the surface, in the kernel.** The surface is genuinely closed: three phrases, one numeral, no combinators, no member predicates. But `ρₙ` is one point of an unrestricted, law-free function space `M → Verdict` living inside an `Expr` leaf (`Expr Γ A = Env Γ → A`, `Plan.lean:147`). Under R1 the panel's reducer is a *type class instance* — the meaning is `run_panel`, and there is nothing to choose. Under R2 the reducer is an anonymous host function with no morphism law attached, and the surface exposes a coordinate of it. That is the structure of an expression language with the parser removed: adding a fourth entry costs nothing structurally, so the closure of the menu is maintained by documentation rather than by mathematics (anti-pattern 9). The design's own "decisive argument" for elaboration (A) tells on this — it is an argument about preserving a *theorem's statement*, not about what a panel *means*, which is the doctrine's asymmetry run backwards.

The threshold numeral itself, and the checker computing `⌊k/2⌋+1`, are fine.

---

## Remaining findings

**MAJOR — every load-bearing theorem is in the "optional" column.** `run_panelQuorum`/`trace_panelQuorum` are "*optional*… not required to compile"; the agreement lemma `panelQuorum k ps ≐ panel ps` is "*optional but recommended*… nothing depends on it." But the agreement lemma is the *entire* content of "the annihilating monoid product is the quorum fold at its top threshold", which the document calls "the load-bearing result of this document", and `trace_panelQuorum` is the entire content of "the second equation is independent of φ — that is the whole cost story." A design that ships its two headline results as optional prose has, by the doctrine's fourth completion test, left everything to prove.

**MINOR — internal contradiction on special-casing.** R2 says "At `n = k` this degenerates to R1 exactly, **so nothing is special-cased**." The IMPLEMENTATION-COST table says `checkRhs` "emits `Plan.panel` for `all` (**unchanged path**) or `Plan.panelQuorum` otherwise" — i.e. it special-cases, and must, because `n = k` is *refused* by the checker. The claimed equality is therefore a theorem about a phrase the language forbids you to write, invoked to justify an elaboration split it doesn't perform.

**MINOR — migration cost of the mandatory phrase is understated.** "What does not move" names only `flagship-v4.wf`. Bare `panel [` appears in `example/harden.wf:15` and in the published guide's grammar box (`doc/dsl-guide.html:154, 378`) and prose ("a panel approves exactly when every member approves"). Refusing the bare form is the single most invasive decision in the document; its blast radius is one example file, one grammar box, and one paragraph of shipped documentation, none of which is listed.

**MINOR — axiom hygiene not addressed.** The package machine-checks axiom sets at seven constants (`Certify.lean:226,230`, `Mcp.lean`, `Report.lean`), and `Verdict.instInhabited` is deliberately spelled `Option.some []` rather than `1` because Mathlib's `One (WithZero (FreeMonoid α))` "carries `Classical.choice` in its dependency graph" (`Question.lean:107–117`). `panelQuorum`'s `ret 1` at `Multiplicative ℕ × Multiplicative ℕ × FreeMonoid Objection` reintroduces exactly that family into `Plan.lean`. The risk is low in fact (none of the guarded constants reaches `panelQuorum`), but a design table that says "`Cost.lean`: **nothing**, 0" and "zero new kernel constructs" should say which guards it can reach and why it cannot break them. It does not mention them at all.

---

### Shortest path to "adequate"

1. Drop the family framing. Say: R1 is the monoid fold and is nestable; R2 is a counted read-out that is not a homomorphism and does not nest; they agree at n=k, which is a lemma, not a unification.
2. Fix the decline story once, in the element type, or inherit annihilation everywhere. The current split — annihilate under R1 because demotion is dishonest, demote under R2 because annihilation is indefensible — cannot both be right.
3. State the approve-branch loss (`A ≥ n` discards `R`) in the ledger beside acat-88m.
4. Either give `revising` a third arm on `VTag` (`Plan.caseV` already exists, `Plan.lean:553`) or delete R1's "escalate rather than amend" defence, which is false as the loop is written.
5. Derive the decline note's identity from the member rather than a parallel `List String`, or drop the note.
6. Exhibit the `ask` production that makes `independent draw n` parse, or say it is proposed.
7. Move the two headline lemmas out of the optional column.