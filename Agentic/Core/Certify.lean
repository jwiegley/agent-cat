import Agentic.Core.Exec

/-!
# Certification: what a run warrants, and the decidable check that warrants it

Rederivation kernel §5(ii) and §5(iii), and open question 10 ("what must the
runtime-adherence theorem SAY?"). The compiled probes are
`attack-realizability-lean/B_adequacy.lean` and
`attack-realizability-lean/C_certificate.lean`; this module is those two probes
ported onto the `Plan`/`denote`/`Table` of the package, where `Code`, `El` and
`Q` are *definitions* rather than the probes' three axioms.

Two statements, and the difference between them is the whole design.

* **Adequacy** (`Plan.adequacy`) is a theorem about the interpreter, quantified
  over every answering service: whatever the agents did, the value the run
  returned is the value the plan *means* in every world extending the run's
  table, and the transcript the run would replay from its own table is the
  transcript it actually saw. It is stated at `Id`, because a statement about
  what an `IO` action returns would require modelling `IO`, and it is stated
  over the `execPure` factorization of `Agentic/Core/Exec.lean` — `execWith` and
  `execPure` are one definition differing in one argument, so a theorem about
  the interpreter at `Id` is a theorem about the term that runs against a live
  adapter.

* **The certificate** (`certify`, `certify_sound`) is a `Bool`. It needs no
  adequacy theorem, no interpreter and no monad: replay the logged table as a
  defaulted world, evaluate the plan purely, compare. `certify_sound` therefore
  depends on nothing but the meaning — `#print axioms certify_sound` is empty,
  which is the claim the kernel makes for it and the reason `IO` is never
  modelled. Each run carries its own machine-checked warrant.

The two meet at `certify_execWith`: the certificate is not merely sound but
*complete for this interpreter* — at `Id`, a run of `execWith` always certifies.
That is what makes wiring the check into every execution (`Plan.runCertified`)
a check on the trust boundary rather than a check on the mathematics: at `Id` it
cannot fail, so if it fails in `IO` the `Oracle IO` did something no `Oracle`
can do.

**What is outside.** The certificate certifies *this* run's value against *this*
run's table. It does not certify the workflow, the next run, or that the table
is an honest record of what was said — the log is only as good as the rule that
`Agentic/Core/Exec.lean`'s oracle is the only path to an answer. Its one real
gap is in the other direction: `worldOf` totalizes by defaulting, so a cell the
table never recorded still answers, and a plan can be certified against a world
the run only partly determined. The check for that is *coverage* — every event
of the replayed transcript recorded in the table, with the answer the replay
reads (`Plan.Covered`, in `Agentic/Core/Report.lean`, where
`Plan.certify_sound_of_covered` turns this module's *some* world into *every*
world extending the log) — and coverage is meaningful only because
no cell nobody answered is ever written *into* a table. Two rules keep it that
way, and both are in `Agentic/Core/Exec.lean`: an answer the trusted base could
not read aborts the run (`Exec.oracle`), and an *act* — or anything asked of a
person — whose turn did not complete aborts it too
(`Exec.requiresCompletedTurn`). Either way the alternative would be a log entry
indistinguishable, in the table, from one somebody gave.
-/

namespace Agentic.Core

/-! ## Adequacy: the interpreter against an arbitrary history-dependent agent

`Agentic/Core/Exec.lean` proves the value half (`execM_adequacy`) — every world
extending the final table assigns the dialogue the value the run returned, with
no hypothesis on the oracle. What is added here is the transcript half, and then
both are stated at a closed `Plan`, which is the form open question 10 asks for.
-/

/-- **The transcript is determined by the table.** Two worlds that both extend
the table a run left behind cannot be told apart by that run: they answer the
same questions with the same answers, in the same order.

The reason this is not immediate from `execM_adequacy` is that a world extending
the table is pinned only on the cells the run *reached*, and which cells those
are is itself a function of the answers — a world differing at the first cell
would take the dialogue somewhere else entirely. The induction is what rules
that out: at each step, both worlds are forced to agree with the table at the
question just asked, so both continue into the same subtree.

Its consequence is the one worth having: instantiating `ω'` at `worldOf t` says
that **replaying the log reproduces the transcript**, so the table is a faithful
record of the conversation and not merely of its outcome. -/
theorem execM_trace_agree {A : Type} (o : Oracle Id) (p : Dlg A) :
    ∀ t : Table, ∀ ω ω' : Ω,
      Extends ω (Dlg.execM o p t).2 → Extends ω' (Dlg.execM o p t).2 →
      Dlg.trace ω p = Dlg.trace ω' p := by
  induction p with
  | done a => intro t ω ω' _ _; rfl
  | ask c q f ih =>
    intro t
    rw [Dlg.execM]
    cases ha : lookup t c q with
    | some a =>
      simp only []
      intro ω ω' hω hω'
      have e : ω c q = a := (execM_adequacy o (f a) t).1 ω hω c q a ha
      have e' : ω' c q = a := (execM_adequacy o (f a) t).1 ω' hω' c q a ha
      rw [Dlg.trace_ask, Dlg.trace_ask, e, e', ih a t ω ω' hω hω']
    | none =>
      simp only []
      intro ω ω' hω hω'
      have e : ω c q = o c q t :=
        Extends.head ((execM_adequacy o (f (o c q t)) (Table.cons c q (o c q t) t)).1 ω hω)
      have e' : ω' c q = o c q t :=
        Extends.head ((execM_adequacy o (f (o c q t)) (Table.cons c q (o c q t) t)).1 ω' hω')
      rw [Dlg.trace_ask, Dlg.trace_ask, e, e',
        ih (o c q t) (Table.cons c q (o c q t) t) ω ω' hω hω']

/-- **Adequacy, at a closed plan** (kernel §5(ii); the probe is
`attack-realizability-lean/B_adequacy.lean`).

Let a run of the memoizing interpreter against **any** answering service `o` —
history-dependent, free to lie, to drift, to contradict itself, and answering
from the whole of what has already been said — return the value `a` and leave
behind the table `t`. Then:

* every total world `ω` agreeing with `t` assigns the plan exactly `a`, and
* every such `ω` gives the plan exactly the transcript that replaying `t` gives.

**There is no hypothesis about the oracle**, and that absence is the content:
looking the question up before asking it discharges MF's `Functional τ`
structurally, so no property of the agents is assumed and none is needed. The
run does not merely produce a value; it *exhibits a world* in which the plan
means that value, and hands over the finite evidence.

Stated over the `execPure` factorization: `Plan.execWith o` and
`Plan.execPure ω = Plan.execWith (pureOracle ω)` are one definition differing in
the oracle argument alone, so this is a theorem about the same term that
`Agentic.Core.exec` runs in `IO`. At `Id` because a theorem about what an `IO`
action returns would require modelling `IO`; `certify` is what carries the
conclusion to an actual `IO` run. -/
theorem Plan.adequacy {A : Type} (o : Oracle Id) (p : Plan [] A) {a : A} {t : Table}
    (h : Plan.execWith o p Env.nil Table.nil = (a, t)) :
    (∀ ω, Extends ω t → Plan.run ω p Env.nil = a) ∧
    (∀ ω, Extends ω t → Plan.trace ω p Env.nil = Plan.trace (worldOf t) p Env.nil) := by
  have hfst : (Dlg.execM o (denote p Env.nil) Table.nil).1 = a := congrArg Prod.fst h
  have hsnd : (Dlg.execM o (denote p Env.nil) Table.nil).2 = t := congrArg Prod.snd h
  refine ⟨fun ω hω => ?_, fun ω hω => ?_⟩
  · have hω' : Extends ω (Dlg.execM o (denote p Env.nil) Table.nil).2 := by
      rw [hsnd]; exact hω
    calc Plan.run ω p Env.nil
        = (Dlg.execM o (denote p Env.nil) Table.nil).1 :=
          (execM_adequacy o (denote p Env.nil) Table.nil).2 ω hω'
      _ = a := hfst
  · have hω' : Extends ω (Dlg.execM o (denote p Env.nil) Table.nil).2 := by
      rw [hsnd]; exact hω
    have hworld : Extends (worldOf t) (Dlg.execM o (denote p Env.nil) Table.nil).2 := by
      rw [hsnd]; exact worldOf_extends t
    exact execM_trace_agree o (denote p Env.nil) Table.nil ω (worldOf t) hω' hworld

/-! ## The certificate: adequacy as a decidable check on the log

Nothing below mentions the interpreter, the oracle, `Id` or `IO`. That is the
point: `certify` is a function of the *meaning* and the *log*, so its soundness
proof reaches nothing that could carry an axiom.
-/

/-- `[[certify p t a]] = decide (run (worldOf t) p ∅ = a)`: replay the logged
answers as a total world and ask whether the plan, evaluated purely, comes to
what the run said it came to.

Computable because everything in it is: `worldOf` defaults with `Inhabited El`,
`denote` is a fold, and `DecidableEq A` decides the comparison. This is the
per-run warrant of kernel §5(iii) — not a proof about runs in general, but a
`Bool` that this run either produced or did not. -/
def certify {A : Type} [DecidableEq A] (p : Plan [] A) (t : Table) (a : A) : Bool :=
  decide (Plan.run (worldOf t) p Env.nil = a)

/-- **The certificate is sound, with zero axioms** (kernel §5(iii); the probe is
`attack-realizability-lean/C_certificate.lean`).

A `true` certificate exhibits a world: there really is a total answer sheet in
which the plan means the value the run reported. The witness is `worldOf t`
itself, which is why the proof is one line and why `#print axioms` is empty —
`IO` is not modelled, no oracle-fidelity axiom is introduced, and no classical
principle is used. The trust boundary left over is the log, not the logic. -/
theorem certify_sound {A : Type} [DecidableEq A] (p : Plan [] A) (t : Table) (a : A) :
    certify p t a = true → ∃ ω : Ω, Plan.run ω p Env.nil = a :=
  fun h => ⟨worldOf t, of_decide_eq_true h⟩

/-- **…and complete for this interpreter.** At `Id`, a run of `execWith` always
certifies: the check can never fail on a run of the term the theorems are about.

This is what makes wiring the check into every execution meaningful rather than
decorative. The mathematics cannot make it fail, so a `false` in `IO` is a
statement about the `IO` layer — a log that does not answer what the run was
told, which is exactly the failure mode `Oracle IO` is the boundary for. -/
theorem certify_execWith {A : Type} [DecidableEq A] (o : Oracle Id) (p : Plan [] A) :
    certify p (Plan.execWith o p Env.nil Table.nil).2
      (Plan.execWith o p Env.nil Table.nil).1 = true :=
  decide_eq_true
    ((Plan.adequacy o p (a := (Plan.execWith o p Env.nil Table.nil).1)
        (t := (Plan.execWith o p Env.nil Table.nil).2) rfl).1
      _ (worldOf_extends _))

/-- The certificate is honest about the pure interpreter too: running a plan
against a world and certifying the result against the table that run produced
succeeds. `Plan.execPure` is `Plan.execWith` at `pureOracle ω`, so this is
`certify_execWith` at that oracle and is recorded because it is the equation a
reader checks first. -/
theorem certify_execPure {A : Type} [DecidableEq A] (ω : Ω) (p : Plan [] A) :
    certify p (Plan.execPure ω p Env.nil Table.nil).2
      (Plan.execPure ω p Env.nil Table.nil).1 = true :=
  certify_execWith (pureOracle ω) p

/-! ## The axiom claims, machine-checked

The two claims of kernel §5 are claims about *axiom sets*, so they are asserted
here the way `test/Pollution.lean` asserts its own: as build failures. Add a
`sorry`, a `Classical.choice`, or a `Fintype` to the syntax and one of these
stops elaborating.

**Zero axioms for the certificate.** `certify_sound` reaches `Plan`, `denote`,
`worldOf`, `lookup`, `Q` and `El` and nothing else, none of which is a quotient
or a choice — which is what `Agentic/Core/Plan.lean`'s closed `Tag` and
`Agentic/Core/Question.lean`'s `Verdict.instInhabited` are each written for.

**Adequacy is `propext`-only**, which is the class the probe
`attack-realizability-lean/B_adequacy.lean` reports (`[Code, El, Qq, propext]`,
its first three being the axioms standing in for this package's definitions). No
`Classical.choice`, no `Quot.sound`, and nothing of Mathlib's.
-/

/-- info: 'Agentic.Core.certify_sound' does not depend on any axioms -/
#guard_msgs in
#print axioms certify_sound

/-- info: 'Agentic.Core.Plan.adequacy' depends on axioms: [propext] -/
#guard_msgs in
#print axioms Plan.adequacy

/-! ## Wiring: every execution carries its warrant

The interpreter is monad-polymorphic and so is the wrapper, which is the only
way the `Id` theorem above and the `IO` entry point below can be about one term.
-/

/-- `[[Plan.runCertified o p]]` = run the plan and hand back the value, the
table the run constructed, and the verdict of `certify` on the two.

The `Bool` is the run's warrant, computed after the fact from the log alone; it
is not consulted by the run and cannot change it. At `Id` it is provably `true`
(`Plan.runCertified_certified`), so at `IO` — where no proof is possible,
because `IO` is not modelled — it is precisely a check that the trust boundary
held. -/
def Plan.runCertified {m : Type → Type} [Monad m] {A : Type} [DecidableEq A]
    (o : Oracle m) (p : Plan [] A) : m (A × Table × Bool) :=
  (fun r : A × Table => (r.1, r.2, certify p r.2 r.1)) <$>
    Plan.execWith o p Env.nil Table.nil

/-- **At `Id` the warrant is always granted.** `certify_execWith`, read through
the wrapper: the mathematics cannot produce an uncertified run. -/
theorem Plan.runCertified_certified {A : Type} [DecidableEq A] (o : Oracle Id)
    (p : Plan [] A) : (Plan.runCertified o p).2.2 = true :=
  certify_execWith o p

/-- `[[execCertifiedIO st cfg p]]` = `Agentic.Core.execIO` with the warrant
attached: the plan run against a live adapter, returning the answer, the world
the run constructed, and whether replaying that world reproduces the answer.

An `IO` definition and not a theorem, like everything else that makes bytes
happen. What is proved is the `Id` instantiation of the same wrapper
(`Plan.runCertified_certified`); what this adds is that the check is actually
performed, on every run, against the log the run kept. -/
def execCertifiedIO {A : Type} [DecidableEq A] (st : Exec.Settings := {})
    (cfg : Acp.Config := {}) (p : Plan [] A) : IO (A × Table × Bool) :=
  Acp.withConn cfg fun conn => Plan.runCertified (Exec.oracle st conn) p

end Agentic.Core
