import Agentic.Core.Certify
import Agentic.Core.Cost

/-!
# What a run warrants, and what it merely observed

`Agentic/Core/Certify.lean` proves that a run exhibits *a* world in which the
plan means the value the run returned (`certify_sound`), and its own header names
the one gap in that claim: `worldOf` totalizes by defaulting, so a cell the table
never recorded still answers, and a plan can be certified against a world the run
only partly determined. This module closes that gap — the notion is `Covered`,
and the theorem is `Plan.certify_sound_of_covered` — and then gives the bill as a
number and the transcript as lines, so that a harness and a serialiser read the
same arithmetic rather than two copies of it.

**Three kinds of thing live here, and the file is ordered by how much they
claim.**

1. **Coverage**, which is mathematics. `Trace.Covered t tr` says every event of
   `tr` is recorded in `t` with the answer `tr` reads. Its content is
   `Dlg.agree_of_covered`: a covered transcript pins *every* world extending the
   table to the same answers and the same transcript, so the certificate's `∃ ω`
   becomes a `∀ ω`. Nothing here mentions the interpreter, the oracle, `Id` or
   `IO`: like `certify`, coverage is a function of the meaning and the log.

2. **The bill as a number**, which is the bill of `Agentic/Core/Cost.lean` read
   through `Multiplicative ℕ ≅ ℕ` so that it can be printed and compared. Each of
   the two definitions carries the equation that says it is not a second count.

3. **Rendering**, which claims almost nothing and says so. A rendering is total
   and one-line-per-item (`Trace.length_render`, `Table.length_render`); it is
   *not* injective, because `head` truncates and `pad` pads, and a reader who
   wants the answer back has the `Table` for that. `sayAnswer` is the shipped
   spelling of an answer, and is pinned by the frozen corpus through
   `conformance/Conformance.lean`'s `say` string op — which is why it is here
   and not in a harness.

**What is deliberately not here.** A run report. `Turn` and `RunReport` stood at
the foot of this file until the Lean runtime went; the note where they stood says
what replaced them, and why nothing above that line moved.
-/

namespace Agentic.Core

/-! ## Coverage: the log warrants the replay

The check `Agentic/Core/Certify.lean`'s header asks for, as a definition with a
theorem. Read the two together: `certify` says *some* world agrees with the run,
and coverage says the log leaves *no* world extending it any freedom over what
the run did.
-/

/-- `[[e.recordedIn t]]` = the table records this event, with this answer. -/
def Event.recordedIn (e : Event) (t : Table) : Prop := lookup t e.c e.q = some e.a

/-- `[[Event.coveredB t e]]` = `e.recordedIn t`, decided.

Decidable because `lookup` is computable and every `El c` has decidable equality
(`instDecidableEqEl`), which is the same pair of facts that makes `certify` a
`Bool`. -/
def Event.coveredB (t : Table) (e : Event) : Bool :=
  match lookup t e.c e.q with
  | some a => a = e.a
  | none => false

/-- **The decision procedure decides it.** -/
@[simp] theorem Event.coveredB_eq_true_iff {t : Table} {e : Event} :
    Event.coveredB t e = true ↔ e.recordedIn t := by
  unfold Event.coveredB Event.recordedIn
  cases h : lookup t e.c e.q with
  | none => simp
  | some a => simp

/-- **A covered event is one `worldOf` did not default on.** The whole reason
coverage is worth checking: the defaulting totalization is what makes an
uncontacted addressee read as approval (`Verdict.instInhabited`), and this says
that on a covered event no defaulting happened. -/
theorem Event.worldOf_eq_of_recordedIn {t : Table} {e : Event} (h : e.recordedIn t) :
    worldOf t e.c e.q = e.a := by
  unfold Event.recordedIn at h
  simp [worldOf, h]

/-- `[[Trace.Covered t tr]]` = every event of the transcript is recorded in the
table, with the answer the transcript reads.

The transcript is in the meaning (`Dlg.trace`), so this is a statement relating
a *meaning* to a *log*, which is why it can be both checked at runtime and used
as a hypothesis in a theorem. -/
def Trace.Covered (t : Table) (tr : Trace) : Prop := ∀ e ∈ tr, e.recordedIn t

/-- `[[Trace.coveredB t tr]]` = `Trace.Covered t tr`, decided. -/
def Trace.coveredB (t : Table) (tr : Trace) : Bool := tr.all (Event.coveredB t)

/-- **The decision procedure decides it.** -/
@[simp] theorem Trace.coveredB_eq_true_iff {t : Table} {tr : Trace} :
    Trace.coveredB t tr = true ↔ Trace.Covered t tr := by
  simp [Trace.coveredB, Trace.Covered, List.all_eq_true]

@[simp] theorem Trace.covered_nil (t : Table) : Trace.Covered t [] := by
  intro e he; exact absurd he (by simp)

theorem Trace.covered_cons {t : Table} {e : Event} {tr : Trace}
    (h : e.recordedIn t) (ht : Trace.Covered t tr) : Trace.Covered t (e :: tr) := by
  intro e' he'
  rcases List.mem_cons.mp he' with rfl | he' <;> [exact h; exact ht e' he']

/-- **The theorem coverage exists for.** If the table records everything the
dialogue consulted in the world `ω`, then *every* world that agrees with the
table gives the dialogue the same answer and the same transcript.

Two things about the hypotheses are the content.

* There is **no hypothesis on `ω`**: it need not extend `t`, because coverage
  already pins it on exactly the cells the run touched, and off them the
  dialogue cannot look.
* The conclusion is an equality of *transcripts*, not merely of values, so this
  is the statement that the log determines the conversation and not just its
  outcome.

Compare `execM_trace_agree` of `Agentic/Core/Certify.lean`, which concludes the
same equality from *both* worlds extending the table a run of `execM` left
behind: that is a theorem about the interpreter and needs it, this is a theorem
about the meaning and does not. The interpreter reappears only in
`Plan.covered_execPure` below, which says the hypothesis is attainable. -/
theorem Dlg.agree_of_covered {A : Type} (t : Table) {ω ω' : Ω} (hω' : Extends ω' t) :
    ∀ p : Dlg A, Trace.Covered t (Dlg.trace ω p) →
      Dlg.run ω p = Dlg.run ω' p ∧ Dlg.trace ω p = Dlg.trace ω' p := by
  intro p
  induction p with
  | done a => intro _; exact ⟨rfl, rfl⟩
  | ask c q f ih =>
    intro hcov
    have hhead : (⟨c, q, ω c q⟩ : Event).recordedIn t :=
      hcov ⟨c, q, ω c q⟩ (by rw [Dlg.trace_ask]; exact List.mem_cons_self)
    have heq : ω' c q = ω c q := hω' c q _ hhead
    have htail : Trace.Covered t (Dlg.trace ω (f (ω c q))) := by
      intro e he
      exact hcov e (by rw [Dlg.trace_ask]; exact List.mem_cons_of_mem _ he)
    obtain ⟨hr, ht⟩ := ih (ω c q) htail
    refine ⟨?_, ?_⟩
    · rw [Dlg.run_ask, Dlg.run_ask, heq]; exact hr
    · rw [Dlg.trace_ask, Dlg.trace_ask, heq]; exact congrArg _ ht

/-- `[[Plan.Covered t p]]` = the table covers the transcript the *replay* has:
every event `Plan.trace (worldOf t) p Env.nil` consults is recorded in `t`, with
the answer the replay reads.

Stated at the replay's transcript rather than at a run's, because the replay is
the thing a consumer has: a certificate is checked against `worldOf t`, and this
says that check reached no defaulted cell. `Plan.covered_execPure` says the
condition is met by an actual run. -/
def Plan.Covered {A : Type} (t : Table) (p : Plan [] A) : Prop :=
  Trace.Covered t (Plan.trace (worldOf t) p Env.nil)

/-- `[[Plan.coveredB t p]]` = `Plan.Covered t p`, decided — the `Bool` a harness
prints. -/
def Plan.coveredB {A : Type} (t : Table) (p : Plan [] A) : Bool :=
  Trace.coveredB t (Plan.trace (worldOf t) p Env.nil)

@[simp] theorem Plan.coveredB_eq_true_iff {A : Type} {t : Table} {p : Plan [] A} :
    Plan.coveredB t p = true ↔ Plan.Covered t p := Trace.coveredB_eq_true_iff

/-- **Under coverage the replay is the only run the log admits.** Every world
agreeing with the table gives the plan the replay's value and the replay's
transcript — so "here is the transcript" is a claim about the run and not about
`worldOf`'s defaults. -/
theorem Plan.replay_of_covered {A : Type} {t : Table} {p : Plan [] A}
    (hcov : Plan.Covered t p) (ω : Ω) (hω : Extends ω t) :
    Plan.run ω p Env.nil = Plan.run (worldOf t) p Env.nil ∧
      Plan.trace ω p Env.nil = Plan.trace (worldOf t) p Env.nil := by
  obtain ⟨hr, ht⟩ := Dlg.agree_of_covered t hω (denote p Env.nil) hcov
  exact ⟨hr.symm, ht.symm⟩

/-- **The certificate, made informative** (the strongest form this package can
state, and the reason `Covered` is in the library).

`certify_sound` exhibits *one* world in which the plan means what the run said:
the defaulted one. That is a real warrant and a weak one — a run whose oracle
answered nothing at all satisfies it, because `worldOf Table.nil` answers
everything with the `Inhabited` default. Add coverage and the quantifier turns
over: **every** world consistent with the log assigns the plan the run's value,
and gives it the run's transcript event for event.

The two hypotheses are exactly the two checks a harness performs, and neither
implies the other. `certify_nil_ticks` and `not_covered_nil_ticks` below are one
run that certifies and is not covered; and coverage alone says nothing about the
value, since it constrains the transcript and the value is what `certify`
compares.

What is still outside, and no theorem can reach: that the log is an honest
record of what was said. Coverage says a replayed event is *in* the table; the
rule that nothing enters a table unanswered is a runner's, in `IO`
(`Exec.askDecoding`). -/
theorem Plan.certify_sound_of_covered {A : Type} [DecidableEq A] (p : Plan [] A) (t : Table)
    (a : A) (hcov : Plan.Covered t p) (hcert : certify p t a = true) :
    ∀ ω, Extends ω t →
      Plan.run ω p Env.nil = a ∧
        Plan.trace ω p Env.nil = Plan.trace (worldOf t) p Env.nil := by
  intro ω hω
  obtain ⟨hr, ht⟩ := Plan.replay_of_covered hcov ω hω
  exact ⟨hr.trans (of_decide_eq_true hcert), ht⟩

/-- **Coverage is attainable**: the pure interpreter's own table covers the plan
it ran. So the runtime check is not asking for something no run can produce —
at `Id` it cannot fail, exactly as `certify` cannot (`certify_execWith`), and a
`false` in `IO` is therefore a statement about the `IO` layer.

Note which fact does the work: `execM_pure` records every consulted cell with
the answer it got, and `Dlg.agree_of_covered` then says the replay follows the
same path — without which "the run's transcript is covered" would not give "the
replay's transcript is covered", the two being transcripts of different
worlds. -/
theorem Plan.covered_execPure {A : Type} (ω : Ω) (p : Plan [] A) :
    Plan.Covered (Plan.execPure ω p Env.nil Table.nil).2 p := by
  set t := (Plan.execPure ω p Env.nil Table.nil).2 with ht
  have hrun : Trace.Covered t (Dlg.trace ω (denote p Env.nil)) :=
    fun e he => (execM_pure ω (denote p Env.nil) Table.nil (extends_nil ω)).2.2 e he
  have hreplay : Dlg.trace ω (denote p Env.nil) = Dlg.trace (worldOf t) (denote p Env.nil) :=
    (Dlg.agree_of_covered t (worldOf_extends t) (denote p Env.nil) hrun).2
  intro e he
  exact hrun e (hreplay ▸ he)

/-! ### …and why it is needed: the certificate alone is vacuous on a `W Unit`

The owner's flagship workflow returns unit — `Plan [] Unit` in this stack — and
a `Unit`-valued plan has no value for a world to disagree about. Recorded as
theorems rather than as a caveat, because the honest reading of a harness's
`ok   the run certifies` line on such a workload is that the wrapper ran.
-/

/-- **The certificate is `true` for every plan whose answers are
indistinguishable**, every table, and every value: `Plan.run` cannot disagree
with a run when the codomain has one inhabitant up to equality. -/
theorem certify_subsingleton {A : Type} [DecidableEq A] [Subsingleton A] (p : Plan [] A)
    (t : Table) (a : A) : certify p t a = true := by
  simp [certify, Subsingleton.elim (Plan.run (worldOf t) p Env.nil) a]

/-- **…and at `W Unit`, which is what the owner writes.** `certify p t () = true`
for every closed unit-valued plan and every table — the empty one included, so a
run that asked nothing certifies. This is the gap `Plan.Covered` fills, stated
as a theorem so that no consumer has to take the caveat on trust. -/
theorem certify_unit_vacuous (p : Plan [] Unit) (t : Table) : certify p t () = true := rfl

/-- **The gap, exhibited.** One closed consultation, certified against the empty
table — and not covered by it, because nobody answered anything. A consumer that
reports `certified` without `covered` reports this run as warranted. -/
theorem certify_nil_ticks : certify (ticks (Γ := []) 1) Table.nil () = true :=
  certify_unit_vacuous _ _

theorem not_covered_nil_ticks : ¬ Plan.Covered Table.nil (ticks (Γ := []) 1) := by
  intro h
  have hmem : (⟨.ack, ackQ 0, ()⟩ : Event)
      ∈ Plan.trace (worldOf Table.nil) (ticks (Γ := []) 1) Env.nil := by
    simp [ticks, Plan.trace_askC]
    rfl
  have := h _ hmem
  rw [Event.recordedIn, lookup_nil] at this
  exact absurd this (by simp)

/-! ### The axiom claim, machine-checked

`Agentic/Core/Certify.lean` asserts that `certify_sound` reaches no axiom at all,
and says why that is worth asserting: a per-run warrant is a claim the package
makes, and one whose proof rests on choice is a claim about a different logic.
Coverage strengthens that warrant, so it is held to the same standard, and the
claim is recorded the way `test/Pollution.lean` records its own — as a build
failure. Add a `sorry`, or reach for a classical principle, and one of these
stops elaborating.

Note what the three of them together say: the whole chain from "the log covers
the replay" to "every world extending the log gives this value and this
transcript" is intuitionistic, quotient-free and choice-free, exactly like the
certificate it strengthens. Only the *decision procedures* (`Trace.coveredB` and
friends, which go through `List.all`) reach Mathlib's `propext` and `Quot.sound`,
and they are not what a warrant rests on.
-/

/-- info: 'Agentic.Core.Dlg.agree_of_covered' does not depend on any axioms -/
#guard_msgs in
#print axioms Dlg.agree_of_covered

/-- info: 'Agentic.Core.Plan.replay_of_covered' does not depend on any axioms -/
#guard_msgs in
#print axioms Plan.replay_of_covered

/-- info: 'Agentic.Core.Plan.certify_sound_of_covered' does not depend on any axioms -/
#guard_msgs in
#print axioms Plan.certify_sound_of_covered

/-- info: 'Agentic.Core.certify_unit_vacuous' does not depend on any axioms -/
#guard_msgs in
#print axioms certify_unit_vacuous

/-! ## The bill, as a number

`Agentic/Core/Cost.lean` prices a transcript in a monoid; a report prints a
number. These two definitions are that monoid read through
`Multiplicative ℕ ≅ ℕ`, each with the equation saying it is the same bill and
not a second count.
-/

/-- `[[billNat tr]]` = what the transcript comes to under `tick`, as a `Nat`.

**Equation** (`billNat_eq`, proved adjacent): `ofAdd (billNat tr) = billFresh tick tr`
— this is the bill of `Agentic/Core/Cost.lean` and not a second count, read
through the isomorphism `Multiplicative ℕ ≅ ℕ` so that it can be printed. -/
def billNat (tr : Trace) : Nat := Multiplicative.toAdd (billFresh tick tr)

/-- **The equation.** The number printed *is* the bill. -/
theorem billNat_eq (tr : Trace) : Multiplicative.ofAdd (billNat tr) = billFresh tick tr := rfl

/-- …and `tick` charges one per consultation, so the bill is the length of the
transcript (`billFresh_tick`). -/
theorem billNat_eq_length (tr : Trace) : billNat tr = tr.length := by
  simp [billNat, billFresh_tick]

/-- **The counting price at a list of keys**: `tick` charges one per question,
so a bill is a length. `billFresh_tick` of `Agentic/Core/Cost.lean` is this at
`t.map Event.key`; the memo bill needs it at the deduplicated list, which is
`memoNat_eq_dedup` below. -/
theorem billOfKeys_tick (ks : List Key) :
    billOfKeys tick ks = Multiplicative.ofAdd ks.length := by
  induction ks with
  | nil => rfl
  | cons k ks ih =>
    rw [billOfKeys_cons, ih, List.length_cons]
    show Multiplicative.ofAdd 1 * Multiplicative.ofAdd ks.length = _
    rw [← ofAdd_add, Nat.add_comm]

/-- `[[memoNat tr]]` = what the transcript comes to when each **distinct**
question is charged once: `Cost.billMemo` at `tick`, as a number.

**Equation** (`memoNat_eq_dedup`, proved adjacent): it is the number of distinct
questions in the transcript — hence exactly the number of entries a memoizing
run's table must hold. Checking it against the table's length is how a harness
observes `Dlg.execM`'s look-up-before-asking, and it is the honest form of that
check: `billMemo ∣ billFresh` in general (`billMemo_dvd_billFresh`), so "table
length = transcript length" would be a claim about a particular workload —
one where every question happens to be distinct — rather than about the
interpreter. -/
def memoNat (tr : Trace) : Nat := Multiplicative.toAdd (billMemo tick tr)

/-- **The equation.** The number checked *is* the memo bill. -/
theorem memoNat_eq (tr : Trace) : Multiplicative.ofAdd (memoNat tr) = billMemo tick tr := rfl

/-- …and it counts the distinct questions. -/
theorem memoNat_eq_dedup (tr : Trace) : memoNat tr = ((tr.map Event.key).dedup).length := by
  simp [memoNat, billMemo, billOfKeys_tick]

/-- `[[Trace.billIn bs tr]]` = is this transcript's bill one of the numbers a
cost analysis proved possible?

The runtime form of a `Cost.costM` membership: `Agentic/Core/Cost.lean` proves the
bill of every run lies in a finite set (`bill_mem_leaves`), a workload proves the
list of lengths its plan admits, and this is the check a report makes against
that list. -/
def Trace.billIn (bs : List Nat) (tr : Trace) : Bool := bs.contains (billNat tr)

theorem Trace.billIn_eq_true_iff (bs : List Nat) (tr : Trace) :
    Trace.billIn bs tr = true ↔ tr.length ∈ bs := by
  simp [Trace.billIn, billNat_eq_length]

/-- **The membership check against a proved set cannot fail on a replay.** If
every world's transcript has one of the lengths `bs` — the shape of
`Harden.length_trace_hardenPatch`, and of anything read off `Cost.costM` — then
the replay of any table has a bill in `bs`, because `worldOf t` is a world.

Which is exactly how much such a check is worth, and it is worth saying: the
proposition is a theorem about the *meaning*, so a harness that computes its bill
from `Plan.trace (worldOf t)` is checking that it computed what it says it
computed, and a harness that computes it from a log of its own is checking
something this theorem does not cover. -/
theorem Plan.billIn_replay {A : Type} (p : Plan [] A) (bs : List Nat)
    (h : ∀ ω, (Plan.trace ω p Env.nil).length ∈ bs) (t : Table) :
    Trace.billIn bs (Plan.trace (worldOf t) p Env.nil) = true :=
  (Trace.billIn_eq_true_iff _ _).mpr (h (worldOf t))

/-! ## Predicates a report reads off a transcript -/

/-- `[[Event.hasCode c e]]` = this event asked for an answer of kind `c`. Where a
workflow puts exactly one question of some code, this is how "that question was
put" becomes a statement about the transcript. -/
def Event.hasCode (c : Code) (e : Event) : Bool := e.c = c

@[simp] theorem Event.hasCode_eq_true_iff {c : Code} {e : Event} :
    Event.hasCode c e = true ↔ e.c = c := by simp [Event.hasCode]

/-- `[[Trace.anyFlagTrue tr]]` = somebody answered *yes* to a yes/no question in
this transcript.

The runtime half of a consent theorem: `El .flag` is `Bool`, so a `true` answer
to a `.flag` question is the only form assent takes in this package, and this is
that fact read off the bytes a run produced. -/
def Trace.anyFlagTrue (tr : Trace) : Bool :=
  tr.any fun e => match e with
    | ⟨.flag, _, ok⟩ => ok
    | _ => false

theorem Trace.anyFlagTrue_eq_true_iff {tr : Trace} :
    Trace.anyFlagTrue tr = true ↔ ∃ q : Q .flag, (⟨.flag, q, true⟩ : Event) ∈ tr := by
  constructor
  · intro h
    obtain ⟨e, he, hb⟩ := List.any_eq_true.mp h
    match e, hb with
    | ⟨.flag, q, true⟩, _ => exact ⟨q, he⟩
  · rintro ⟨q, hq⟩
    exact List.any_eq_true.mpr ⟨⟨.flag, q, true⟩, hq, rfl⟩

/-! ## Rendering: a transcript a human can read

Everything below is presentation. The two theorems are the two true statements:
each renderer is **total** and emits **one line per item**. Neither is injective
— `head` truncates and `pad` pads — and no theorem claims otherwise; a consumer
that needs the answer back reads the `Table`, which is the object the answer is
*in*.
-/

/-- `[[pad n s]]` = `s` in a field at least `n` characters wide, so the columns
line up. Presentation only; nothing downstream reads it. -/
def pad (n : Nat) (s : String) : String := s ++ "".pushn ' ' (n - s.length)

/-- `[[head n s]]` = the first `n` characters of `s` flattened onto one line,
with `…` if there was more. One event is one line, so a prompt quoting a whole
patch has to be cut somewhere. -/
def head (n : Nat) (s : String) : String :=
  let flat := s.replace "\n" "\\n"
  if flat.length ≤ n then flat else (flat.take n).toString ++ "…"

/-- `[[sayFlag b]]` = a yes/no answer in the words `Exec.answerSpec` asked for,
so that what is printed is what the addressee was told to say. Separate from
`sayAnswer` only because `El .flag` is `Bool` by unfolding and an `if` will not
unfold it. -/
def sayFlag (b : Bool) : String := if b then "yes" else "no"

/-- **The one rendering that is injective**, which is the one whose codomain is
finite: a printed flag can be read back. That `Decode .flag (sayFlag b) = some b`
— the round trip through the trusted base — is *not* provable here, because
`String` operations do not reduce in the kernel (`Exec.norm`'s docstring says
so); a harness that wants it checks it at runtime, as it checks any other fact
about bytes. -/
theorem sayFlag_injective : Function.Injective sayFlag := by
  intro b b' h
  cases b <;> cases b' <;> simp_all [sayFlag]

/-- `[[sayVerdict v]]` = a verdict as text a reader can take in, in the three
cases `Plan.caseV` branches on and `Exec.tag_decodeVerdict` classifies, because
those are the only three there are.

`Verdict.render` is the package's one renderer for a verdict
(`Agentic/Core/Question.lean`), *called* here and not copied: this module used to
define its own `Verdict.objections` and inline the join (obr `acat-j61`). What is
this module's own is the **three-case** presentation — approval and refusal
*named* rather than both collapsing to `""` — which is what a reader of a log
needs and what the prompt-side renderer deliberately does not do, since a
revision is told it was not approved by being asked again. Below the two named
cases there is nothing left to decide, so the third arm is `render` itself. -/
def sayVerdict (v : Verdict) : String :=
  if Verdict.approvedB v then "approve"
  else if v = Verdict.declined then "declined"
  else Verdict.render v

@[simp] theorem sayVerdict_approve : sayVerdict Verdict.approve = "approve" := rfl

@[simp] theorem sayVerdict_declined : sayVerdict Verdict.declined = "declined" := rfl

/-- The three cases are distinguished, which is as much as a renderer of an
infinite type can promise: approval and refusal are told apart, and an objecting
verdict prints its objections. -/
theorem sayVerdict_object {os : List Objection} (h : os ≠ []) :
    sayVerdict (Verdict.object os) = String.intercalate "; " os := by
  have hne : ¬ Verdict.Approved (Verdict.object os) := fun hc =>
    h ((Verdict.approved_object_iff os).mp hc)
  have hdec : Verdict.object os ≠ Verdict.declined := Verdict.object_ne_declined os
  rw [sayVerdict, if_neg (by simpa [Verdict.approvedB_eq_true_iff] using hne), if_neg hdec]
  simp only [Verdict.render, Verdict.objections_object]

/-- `[[sayAnswer c a]]` = the answer `Decode` read, written back out in the
vocabulary of its code — for a reader, not for the interpreter, which is why it
is here and not in `Agentic/Core/Exec.lean`. -/
def sayAnswer : (c : Code) → El c → String
  | .text, s => s
  | .verdict, v => sayVerdict v
  | .flag, b => sayFlag b
  | .ack, _ => "done"

/-- `[[Q.axes q]]` = the question's scope, as the two axes the interpreter reads
off it: the model axis (`session/set_config_option`) and the mode axis
(`session/set_mode`), each of which rides on the protocol where the adapter
takes it and in the prompt header where it does not. `-` is an axis the author
left silent. -/
def Q.axes {c : Code} (q : Q c) : String :=
  let m := match Exec.modelAxis q with | some m => m | none => "-"
  let d := match Exec.modeAxis q with | some d => d | none => "-"
  s!"model={m} mode={d}"

/-- `[[Event.render e]]` = one event as one line: who was asked, under what
scope, the head of what was said to them, and the head of what came back. -/
def Event.render (e : Event) : String :=
  s!"  {pad 24 (Exec.Addressee.render e.q.addressee)}{pad 20 (Q.axes e.q)}\
     {pad 10 s!"({Exec.Code.name e.c})"}{pad 46 (head 44 e.q.prompt)} -> \
     {head 40 (sayAnswer e.c e.a)}"

/-- `[[Trace.render tr]]` = the transcript, one event per line. -/
def Trace.render (tr : Trace) : List String := tr.map Event.render

/-- **Total, and one line per event.** The only thing worth proving about a
pretty-printer, and the thing a consumer counting lines relies on. -/
@[simp] theorem Trace.length_render (tr : Trace) : (Trace.render tr).length = tr.length :=
  List.length_map _

/-- `[[Table.size t]]` = how many answers the table holds, shadowed entries
included. `Table` is a `def` over a list of dependent triples, so this is where
the list is named. -/
def Table.size (t : Table) : Nat := (t : List ((c : Code) × Q c × El c)).length

/-- `[[Table.render t]]` = the log, one recorded answer per line, most recent
first — the order `lookup` reads it in, so a shadowed entry is visibly below the
one shadowing it. -/
def Table.render (t : Table) : List String :=
  (t : List ((c : Code) × Q c × El c)).map fun entry =>
    s!"  {pad 24 (Exec.Addressee.render entry.2.1.addressee)}\
       {pad 10 s!"({Exec.Code.name entry.1})"}{pad 46 (head 44 entry.2.1.prompt)} -> \
       {head 40 (sayAnswer entry.1 entry.2.2)}"

/-- **Total, and one line per entry.** -/
@[simp] theorem Table.length_render (t : Table) : (Table.render t).length = Table.size t :=
  List.length_map _

/-! ## Where the run report went

`Turn` and `RunReport` stood here: one value holding what an `IO` run produced —
its value, its log, the replayed transcript, the certificate, the coverage
verdict, and the per-turn and per-permission observations the `IO` layer made.
Every consumer of it was the Lean runtime (the command line, the MCP server, the
demo), and two of its fields were typed in `Agentic/Core/Acp.lean`, which is
gone. `agentic-run` on the Haskell side reports its own runs.

Nothing above this line moved, and the report was never more than a record of
things proved above it: the transcript is `Plan.trace (worldOf table) p Env.nil`,
the coverage verdict is `Plan.coveredB`, the certificate is `certify`, and the
warrant the report used to carry in a theorem of its own is
`Plan.certify_sound_of_covered`, stated in full generality above. A harness that
wants a report builds one out of those four.
-/

end Agentic.Core
