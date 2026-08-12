import Agentic.Monoid
import Agentic.Semiring

/-!
# Mazurkiewicz traces and sessions

A workflow's history is a *sequence* of turns, but not every reordering of
that sequence is a different history: a panel of reviewers consulted
concurrently may be consulted in any order, while the stages of a pipeline may
not. This module builds the object in which that distinction is an *equality*
rather than a side condition — the free partially commutative monoid on an
alphabet of turns, quotiented by an independence relation.

The quotient is genuine: `Trace` is `Quot` of an inductively generated
equivalence, `mul` is defined by lifting `List.append` through it (which costs
a congruence proof), and the monoid laws are transported through
`Quot.inductionOn`. Nothing here is a wrapper around lists with an equality
that happens to agree; two independent schedules are *the same trace*.

A session is then a semiring-valued judgment of every history, and the
Brzozowski derivative is the act of continuing a session past a prefix.

The trace monoid is stated once, as the package's `PMonoid` (`Agentic.Monoid`),
and not a second time as bespoke `Mul`/`One` instances with their own three
law theorems. That also settles the module's place in the import graph: this
file needs the monoid, not the panel, so it imports `Agentic.Monoid` and the
edge `Trace → Panel` — which existed only to reach `PMonoid` and pointed the
wrong way, a concurrency object depending on a fan-in construction that ought
to depend on it — is gone.
-/

namespace Agentic

section Traces

variable {A : Type} {ind : A → A → Prop}

/-- A `Swap ind u v` is a representation of *one* rescheduling step: two
adjacent turns that are independent of one another are exchanged, and nothing
else about the history changes. The independence relation `ind` is the design
input — it says which pairs of turns do not observe each other — and it is
supplied per alphabet, not fixed here. Symmetry of `ind` is not assumed: the
equivalence closure below makes the generated relation symmetric regardless. -/
inductive Swap (ind : A → A → Prop) : List A → List A → Prop
  /-- Exchange the adjacent independent turns `a` and `b` in the context
  `u ++ · ++ v`. -/
  | swap {u v : List A} {a b : A} : ind a b → Swap ind (u ++ a :: b :: v) (u ++ b :: a :: v)

/-- A `TraceEqv ind u v` is a representation of *`u` and `v` are the same
history*: one can be turned into the other by finitely many exchanges of
adjacent independent turns. This is the equivalence closure of `Swap`,
generated explicitly because Lean's core library has no `EqvGen`. -/
inductive TraceEqv (ind : A → A → Prop) : List A → List A → Prop
  /-- One rescheduling step is a rescheduling. -/
  | step {u v : List A} : Swap ind u v → TraceEqv ind u v
  /-- A history is itself. -/
  | refl (u : List A) : TraceEqv ind u u
  /-- Rescheduling is reversible. -/
  | symm {u v : List A} : TraceEqv ind u v → TraceEqv ind v u
  /-- Reschedulings compose. -/
  | trans {u v w : List A} : TraceEqv ind u v → TraceEqv ind v w → TraceEqv ind u w

/-- Prefixing a common history preserves a rescheduling step: the exchanged
pair is still adjacent, just further along. This is the list surgery that the
congruence of `append` rests on. -/
theorem Swap.append_left {u v : List A} (w : List A) (h : Swap ind u v) :
    Swap ind (w ++ u) (w ++ v) := by
  cases h with
  | @swap p q a b hab =>
    rw [← List.append_assoc, ← List.append_assoc]
    exact Swap.swap hab

/-- Appending a common suffix preserves a rescheduling step. -/
theorem Swap.append_right {u v : List A} (w : List A) (h : Swap ind u v) :
    Swap ind (u ++ w) (v ++ w) := by
  cases h with
  | @swap p q a b hab =>
    rw [List.append_assoc, List.append_assoc]
    exact Swap.swap hab

/-- Prefixing a common history preserves sameness of histories: the left
congruence of `append` for the trace equivalence. -/
theorem TraceEqv.append_left {u v : List A} (w : List A) (h : TraceEqv ind u v) :
    TraceEqv ind (w ++ u) (w ++ v) := by
  induction h with
  | step hs => exact TraceEqv.step (hs.append_left w)
  | refl _ => exact TraceEqv.refl _
  | symm _ ih => exact TraceEqv.symm ih
  | trans _ _ ih₁ ih₂ => exact TraceEqv.trans ih₁ ih₂

/-- Appending a common suffix preserves sameness of histories: the right
congruence of `append` for the trace equivalence. -/
theorem TraceEqv.append_right {u v : List A} (w : List A) (h : TraceEqv ind u v) :
    TraceEqv ind (u ++ w) (v ++ w) := by
  induction h with
  | step hs => exact TraceEqv.step (hs.append_right w)
  | refl _ => exact TraceEqv.refl _
  | symm _ ih => exact TraceEqv.symm ih
  | trans _ _ ih₁ ih₂ => exact TraceEqv.trans ih₁ ih₂

/-- A `Trace ind` is a representation of an *interaction history up to
scheduling*: a sequence of turns in which independent adjacent turns may be
exchanged freely, and dependent ones may not. It is the free partially
commutative (Mazurkiewicz) monoid on the alphabet `A`.

Taking the quotient — rather than carrying lists plus a "these are equivalent"
predicate — is the point. A meaning defined on `Trace ind` *cannot* observe
the order of independent turns: the type makes the invariance a theorem about
the meaning space instead of a discipline on its users. -/
def Trace {A : Type} (ind : A → A → Prop) : Type := Quot (TraceEqv ind)

namespace Trace

/-- The history denoted by a concrete schedule: the class of the list `u`. -/
def mk (u : List A) : Trace ind := Quot.mk (TraceEqv ind) u

/-- The one-turn history. -/
def single (a : A) : Trace ind := mk [a]

/-- The empty history: no turns have been taken. -/
def one : Trace ind := mk []

/-- Concatenation of histories: take the turns of the first, then those of the
second. It is well defined on classes because `append` respects rescheduling
on both sides — that is exactly `TraceEqv.append_left` and
`TraceEqv.append_right`. -/
def mul (x y : Trace ind) : Trace ind :=
  Quot.lift
    (fun u : List A =>
      Quot.lift (fun v : List A => mk (u ++ v))
        (fun _ _ h => Quot.sound (h.append_left u)) y)
    (fun u u' h =>
      Quot.inductionOn (motive := fun y =>
          Quot.lift (fun v : List A => mk (u ++ v))
              (fun _ _ h' => Quot.sound (h'.append_left u)) y
            = Quot.lift (fun v : List A => mk (u' ++ v))
              (fun _ _ h' => Quot.sound (h'.append_left u')) y)
        y (fun w => Quot.sound (h.append_right w)))
    x

/-- **Histories combine, and this is the package's monoid.** Concatenation of
histories is `⋄` and the empty history is `PMonoid.unit`; the three laws are
proved here, by induction on the classes, because nothing else can prove them —
they are facts about `append` transported through the quotient.

This instance is the trace monoid's *only* presentation. It used to be
accompanied by bespoke `Mul` and `One` instances and by `mul_assoc`,
`one_mul`, `mul_one` proved a second time in that notation; those are gone,
and the three names below are one-line readings of the fields.

Its point is that the *key* of a panel may be a history up to scheduling: the
weight of a session is then indexed by what happened, with independent turns
already identified. That instantiation was unavailable while `MSemiring`
demanded `DecidableEq` of its keys, since equality of traces is equality of
classes of a quotient by a generated equivalence and no one is going to decide
it (acat-192). -/
instance instPMonoid : PMonoid (Trace ind) where
  op := Trace.mul
  unit := Trace.one
  op_assoc x y z :=
    Quot.inductionOn x fun u =>
      Quot.inductionOn y fun v =>
        Quot.inductionOn z fun w => by
          show (mk (u ++ v ++ w) : Trace ind) = mk (u ++ (v ++ w))
          rw [List.append_assoc]
  unit_op x := Quot.inductionOn x fun _ => rfl
  op_unit x :=
    Quot.inductionOn x fun u => by
      show (mk (u ++ []) : Trace ind) = mk u
      rw [List.append_nil]

/-- The key operation on histories is concatenation, definitionally. -/
theorem op_eq_mul (x y : Trace ind) : x ⋄ y = Trace.mul x y := rfl

/-- Concatenation of classes is the class of the concatenation: the defining
computation rule of `⋄` on traces, and the only fact about it later proofs
need. -/
theorem mk_mul_mk (u v : List A) : (mk u : Trace ind) ⋄ mk v = mk (u ++ v) := rfl

/-- The empty history is the class of the empty schedule. -/
theorem one_eq_mk : (PMonoid.unit : Trace ind) = mk [] := rfl

/-- A one-turn history is the class of the one-element schedule. -/
theorem single_eq_mk (a : A) : (single a : Trace ind) = mk [a] := rfl

/-- Concatenation of histories is unbracketed: a history has no grouping (the
monoid field, in notation). -/
theorem mul_assoc (x y z : Trace ind) : x ⋄ y ⋄ z = x ⋄ (y ⋄ z) :=
  PMonoid.op_assoc x y z

/-- The empty history is a left unit: starting from nothing changes nothing. -/
theorem one_mul (x : Trace ind) : PMonoid.unit ⋄ x = x :=
  PMonoid.unit_op x

/-- The empty history is a right unit: continuing with nothing changes
nothing. -/
theorem mul_one (x : Trace ind) : x ⋄ PMonoid.unit = x :=
  PMonoid.op_unit x

/-- Independent turns commute.

Which schedules are EQUAL is chosen here: independent turns commute, dependent
ones do not — the panel's permutation invariance and the pipeline's
order-sensitivity in one object. The proof is `Quot.sound` of a single
adjacent transposition with empty context on both sides; everything else about
the quotient exists to make this one equation true without making any other
equation true. -/
theorem indep_comm {a b : A} (h : ind a b) :
    (single a : Trace ind) ⋄ single b = single b ⋄ single a :=
  Quot.sound (TraceEqv.step (Swap.swap (u := []) (v := []) h))

/-- With no independence at all, rescheduling is equality: the quotient
collapses to lists. This is the negative half of the design claim — the
quotient identifies independent schedules and *nothing else*. -/
theorem eq_of_traceEqv_of_indep_empty (hind : ∀ a b : A, ¬ ind a b)
    {u v : List A} (h : TraceEqv ind u v) : u = v := by
  induction h with
  | step hs => cases hs with | swap hab => exact absurd hab (hind _ _)
  | refl _ => rfl
  | symm _ ih => exact ih.symm
  | trans _ _ ih₁ ih₂ => exact ih₁.trans ih₂

/-- Dependent turns really do not commute: when nothing is independent,
distinct turns denote distinct orders. Without this the previous theorem could
be satisfied by a quotient that identified everything, and "order matters"
would be a claim about notation rather than about meaning. -/
theorem single_mul_single_ne_of_indep_empty (hind : ∀ a b : A, ¬ ind a b)
    {a b : A} (hab : a ≠ b) :
    (single a : Trace ind) ⋄ single b ≠ single b ⋄ single a := by
  intro h
  have hlist :=
    congrArg
      (Quot.lift (fun u : List A => u)
        (fun _ _ hr => eq_of_traceEqv_of_indep_empty hind hr))
      h
  have h2 : [a, b] = [b, a] := hlist
  injection h2 with h3 _
  exact hab h3

end Trace

/-- A `Session S ind` is a representation of a semiring-valued judgment of
every possible interaction history: it assigns to each trace — each history up
to scheduling — a resource in `S`. Over `Prop` it is the set of admissible
histories, over `Cost` the worst-case budget of reaching one, over an
expectation semiring its measure. Because the domain is the quotient, a
session cannot distinguish two schedules that differ only in the order of
independent turns; the invariance is structural, not asserted. -/
def Session (S : Type) [CompleteCSemiring S] {A : Type} (ind : A → A → Prop) : Type :=
  Trace ind → S

variable {S : Type} [CompleteCSemiring S]

/-- The Brzozowski derivative of a session by a prefix: what the session says
about everything that can still happen once `u` has happened.

Fork and resume are the same operation: continue the session past a prefix. A
fork hands the continuation `deriv u f` to another agent; a resume evaluates
it later; a cache stores it.

**Continuing past a prefix IS the left action of a monoid on a reader** —
`actL` of `Agentic.Monoid`, at no distance whatever, exactly as entering a
scope is `actR`. The two laws below are that action's two laws, imported
rather than reproved; what is specific to sessions is the monoid, which is the
trace monoid, and not the action. -/
def deriv (u : Trace ind) (f : Session S ind) : Session S ind :=
  actL u f

/-- Continuing past nothing is not continuing: the empty prefix acts trivially
(`actL_unit`). -/
theorem deriv_one (f : Session S ind) : deriv PMonoid.unit f = f :=
  actL_unit f

/-- Continuing past `u ⋄ v` is continuing past `u` and then past `v`: the
derivative is a monoid action (contravariantly composed, which is what makes
resume-after-fork associate). It is `actL_compose`, and the reversal of the
operands against `withScope_compose` is the difference between the two
actions. -/
theorem deriv_mul (u v : Trace ind) (f : Session S ind) :
    deriv (u ⋄ v) f = deriv v (deriv u f) :=
  actL_compose u v f

/-- Independent turns are indistinguishable to *every* session: the
permutation invariance of a panel, transported to judgments. This is the
payoff of quotienting — it is a theorem about all meanings at once, with no
hypothesis on the session. -/
theorem deriv_indep_comm {a b : A} (h : ind a b) (f : Session S ind) :
    deriv (Trace.single a ⋄ Trace.single b) f
      = deriv (Trace.single b ⋄ Trace.single a) f := by
  rw [Trace.indep_comm h]

end Traces

end Agentic
