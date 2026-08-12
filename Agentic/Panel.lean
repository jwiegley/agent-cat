import Agentic.Monoid
import Agentic.Semiring

/-!
# Panels: fan-out, fan-in, and the monoid semiring

A *panel* sends the same question to several members and combines their
verdicts. **Its meaning is an element of the monoid semiring `S⟨K⟩`** — a
weight in `S` for every key in `K` — and not a list of anything. The keys `K`
are whatever the members return and combine (votes, scores, tallies,
transcripts), the weights `S` are the resource algebra of §2, and combining
two independent panellists is convolution: summing over every pair of keys
whose combination is the key observed.

Four remarks fix the shape of this module.

* Convolution is *not* the pointwise product. Both are applicative functors
  on `K → S`; only convolution is the panel. The docstring of `MSemiring`
  says which is which and why the difference matters.

* **The deltas collapse to convolution** (§5.1's derivation, as a theorem).
  `MSemiring.delta k` is the panel certain to report `k`, and `conv_delta`
  says `δ a ⋆ δ b = δ (a ⋄ b)`: convolving two certain members reproduces the
  key monoid exactly. `convFold_delta` extends this to a whole list of certain
  members — the convolution fold of point masses is the point mass at
  `foldPanel` — which is what makes `foldPanel` *the reducer of the
  denotation* rather than an unrelated list operation.

* **Two reorderings, two licences, and they are different licences.**
  Alternation `msAdd` is pointwise `+` in `S`, so it is commutative
  unconditionally: reordering the *contributions* accumulated into one panel
  costs no hypothesis at all (`msAdd_comm`, `panelOf_perm`). What
  commutativity of the *key monoid* buys is something else — reordering the
  *convolution factors*, i.e. the members whose verdicts get combined
  (`conv_comm`, `convFold_perm`). Only the second is the scheduler's licence
  of §5.1, and conflating the two would make the scheduler's licence look
  free.

* Idempotence is the *duplication* licence, and at the denotation it is
  narrower than the list statement suggests. `conv_delta_idem` — a certain
  member convolved with itself is that member — needs `IdemCMonoid K`;
  `msAdd_idem` — the same alternative offered twice is offered once — needs
  `IdemAdd S`. No general `conv f f = f` is claimed, because none is true.

Representation and denotation are bridged in one direction, explicitly.
`foldPanel` is *one reducer applied to one list representation*; `panelOf`
sends a list of weighted contributions to the weighting it denotes, and
`convFold` sends a list of certain members to the panel they convolve to. The
theorems about lists (`foldPanel_perm`, `foldPanel_dup`) are true and are
consumed by `Agentic.Keys`, but they are facts about lists; their denotational
counterparts (`convFold_perm`, `convFold_dup`) are what a weighting can see.

The key algebra itself is not defined here. `PMonoid`, `CMonoid` and the `⋄`
notation live in `Agentic.Monoid`, where the package's one monoid is stated
once for the panel keys, the scopes, the histories and the grades together;
this module is what convolution does with it.
-/

namespace Agentic

section Aggregation

variable {S : Type} [CompleteCSemiring S]

/-- A guard may be pushed through an aggregation: refusing the whole family is
refusing each member of it. This is the one bookkeeping lemma every
convolution proof below needs, and it is where `csum_zero` earns its keep. -/
theorem csum_ite_zero {ι : Type} (P : Prop) [Decidable P] (F : ι → S) :
    (if P then csum F else (0 : S)) = csum fun i => if P then F i else 0 := by
  by_cases hP : P
  · rw [if_pos hP]
    exact csum_congr fun i => (if_pos hP).symm
  · rw [if_neg hP]
    exact csum_zero.symm.trans (csum_congr fun _ => (if_neg hP).symm)

/-- A triply-indexed aggregation may be rotated: the outermost index may be
moved to the innermost place. Two applications of Fubini; stated once so the
convolution proofs read as reindexings rather than as manipulations. -/
theorem csum_rotate3 {ι₁ ι₂ ι₃ : Type} (B : ι₁ → ι₂ → ι₃ → S) :
    csum (fun a => csum fun x => csum fun y => B a x y)
      = csum (fun x => csum fun y => csum fun a => B a x y) :=
  (csum_swap fun a x => csum fun y => B a x y).trans
    (csum_congr fun x => csum_swap fun a y => B a x y)

/-- A quadruply-indexed aggregation may be reordered from `(a, b, x, y)` to
`(x, y, b, a)`. This is the reindexing that turns the left bracketing of a
convolution into the right one. -/
theorem csum_reorder4 {ι₁ ι₂ ι₃ ι₄ : Type} (A : ι₁ → ι₂ → ι₃ → ι₄ → S) :
    csum (fun a => csum fun b => csum fun x => csum fun y => A a b x y)
      = csum (fun x => csum fun y => csum fun b => csum fun a => A a b x y) :=
  (csum_congr fun a => csum_rotate3 fun b x y => A a b x y).trans
    ((csum_swap fun a x => csum fun y => csum fun b => A a b x y).trans
      (csum_congr fun x => csum_rotate3 fun a y b => A a b x y))

end Aggregation

/-- An `MSemiring S K` is a representation of a *panel-valued weighting*: a
weight in `S` for every key in `K`. It is the monoid semiring `S⟨K⟩` — Elliott's
`b ← a` applicative, whose `liftA2` is convolution; on the Reader `a → b` the
same formula would be the pointwise product, which is a different (and wrong)
operation for panels. The distinction is the whole content of this module: the
pointwise product asks each key to agree with itself, whereas convolution asks
every *pair* of keys whose combination is the key observed, which is what
fanning out to independent members and fanning their verdicts back in
actually means. -/
def MSemiring (S K : Type) [CompleteCSemiring S] [PMonoid K] : Type :=
  K → S

namespace MSemiring

open Classical

section Core

variable {S K : Type} [CompleteCSemiring S] [PMonoid K]

/-- The unit panel: the whole weight sits on the empty verdict, and every
other key is impossible. This is `pure unit`, the panel with no members.

The test against the empty verdict is classical, which is what allows the key
monoid to be *any* monoid — a Mazurkiewicz trace of turns, say, whose equality
is a quotient nobody is asked to decide. The cost is that this definition, and
convolution with it, are `noncomputable`. -/
noncomputable def convOne : MSemiring S K :=
  fun k => if k = PMonoid.unit then 1 else 0

/-- Convolution: the weight of observing key `c` from two independent
contributions is the aggregate, over every pair of keys combining to `c`, of
the two weights sequenced. This is fan-out followed by fan-in, and it is the
`liftA2` of the monoid semiring. Classical, for the same reason `convOne`
is: whether two verdicts combine to the one observed is a fact about the key
monoid, not a decision procedure the panel has to carry. -/
noncomputable def conv (f g : MSemiring S K) : MSemiring S K :=
  fun c => csum fun p : K × K => if p.1 ⋄ p.2 = c then f p.1 * g p.2 else 0

/-- The **point mass** at `k`: the panel certain to report the verdict `k`, at
no cost, and certain not to report anything else. This is `pure k` of the
monoid-semiring applicative, and it is the object §5.1 starts from — the
derivation there posits copy, tensor and a reducer, computes what two members'
deltas must convolve to, and finds convolution.

Classical, and for exactly the reason `convOne` is: the test against `k` is a
fact about the key monoid, not a decision procedure. Where the design writes
`δ`, this is that `δ`, and `convOne = delta unit` by `rfl`. -/
noncomputable def delta (k : K) : MSemiring S K :=
  fun c => if c = k then 1 else 0

/-- The point mass is certain: it places the free weight `1` on its own
verdict. -/
theorem delta_self (k : K) : (delta k : MSemiring S K) k = 1 := if_pos rfl

/-- The point mass is certain the other way round too: it places no weight
anywhere else. Together with `delta_self` this characterises `delta` — the two
equations are what "certain to report `k`" means, and they are the form in
which consumers should read a point mass rather than unfolding the `if`, whose
decidability instance is classical and does not match a carrier's own. -/
theorem delta_of_ne {c k : K} (h : c ≠ k) : (delta k : MSemiring S K) c = 0 := if_neg h

/-- The empty panel is the point mass at the empty verdict — by definition, not
by coincidence: `convOne` *is* `delta PMonoid.unit`, and the unit of the monoid
semiring is the unit of the key monoid seen as a certain verdict. -/
theorem delta_unit : (delta PMonoid.unit : MSemiring S K) = convOne := rfl

/-- **The deltas collapse to convolution** (§5.1). Two members, each certain of
its own verdict, convolve to the member certain of the combined verdict:
`δ a ⋆ δ b = δ (a ⋄ b)`. This is the whole content of the design's derivation
of the panel, and it is what says the monoid semiring *extends* the key monoid
rather than merely being indexed by it — the point masses form a copy of `K`
inside `S⟨K⟩`.

The proof is the pair sum collapsing twice: every term with `k₁ ≠ a` carries a
factor `0`, and so does every term with `k₂ ≠ b`, leaving the single term
`1 * 1` guarded by `a ⋄ b = c`. -/
theorem conv_delta (a b : K) :
    conv (delta a) (delta b) = (delta (a ⋄ b) : MSemiring S K) := by
  funext c
  calc conv (delta a) (delta b) c
      = csum (fun k1 : K => csum fun k2 : K =>
          if k1 ⋄ k2 = c then
            (if k1 = a then (1 : S) else 0) * (if k2 = b then (1 : S) else 0) else 0) :=
        csum_prod fun k1 k2 : K =>
          if k1 ⋄ k2 = c then
            (if k1 = a then (1 : S) else 0) * (if k2 = b then (1 : S) else 0) else 0
    _ = csum (fun k2 : K =>
          if a ⋄ k2 = c then
            (if a = a then (1 : S) else 0) * (if k2 = b then (1 : S) else 0) else 0) :=
        csum_point a _ fun k1 hk1 =>
          (csum_congr fun _ => by rw [if_neg hk1, zero_mul, ite_self]).trans csum_zero
    _ = (if a ⋄ b = c then (1 : S) else 0) := by
        refine (csum_point b _ fun k2 hk2 => ?_).trans ?_
        · rw [if_neg hk2, mul_zero, ite_self]
        · rw [if_pos (rfl : a = a), one_mul, if_pos (rfl : b = b)]
    _ = delta (a ⋄ b) c := by
        by_cases h : a ⋄ b = c
        · rw [if_pos h]
          show (1 : S) = if c = a ⋄ b then 1 else 0
          rw [if_pos h.symm]
        · rw [if_neg h]
          show (0 : S) = if c = a ⋄ b then 1 else 0
          rw [if_neg fun he => h he.symm]

/-- Convolving with the empty panel on the left changes nothing: adding a
member who contributes the empty verdict at no cost is adding no member. -/
theorem conv_one_left (g : MSemiring S K) : conv convOne g = g := by
  funext c
  have hvanish : ∀ k1 : K, k1 ≠ PMonoid.unit →
      (csum fun k2 : K =>
        if k1 ⋄ k2 = c then (if k1 = PMonoid.unit then (1 : S) else 0) * g k2 else 0) = 0 :=
    fun k1 hk1 =>
      (csum_congr fun k2 => by rw [if_neg hk1, zero_mul, ite_self]).trans csum_zero
  calc conv convOne g c
      = csum (fun k1 : K => csum fun k2 : K =>
          if k1 ⋄ k2 = c then (if k1 = PMonoid.unit then (1 : S) else 0) * g k2 else 0) :=
        csum_prod fun k1 k2 : K =>
          if k1 ⋄ k2 = c then (if k1 = PMonoid.unit then (1 : S) else 0) * g k2 else 0
    _ = csum (fun k2 : K =>
          if (PMonoid.unit : K) ⋄ k2 = c then
            (if (PMonoid.unit : K) = PMonoid.unit then (1 : S) else 0) * g k2 else 0) :=
        csum_point PMonoid.unit _ hvanish
    _ = csum (fun k2 : K => if k2 = c then g k2 else 0) :=
        csum_congr fun k2 => by
          rw [PMonoid.unit_op, if_pos (rfl : (PMonoid.unit : K) = PMonoid.unit), one_mul]
    _ = g c :=
        (csum_point c (fun k2 : K => if k2 = c then g k2 else 0)
          fun _ hk2 => if_neg hk2).trans (if_pos rfl)

/-- Convolving with the empty panel on the right changes nothing. -/
theorem conv_one_right (f : MSemiring S K) : conv f convOne = f := by
  funext c
  have hvanish : ∀ k2 : K, k2 ≠ PMonoid.unit →
      (csum fun k1 : K =>
        if k1 ⋄ k2 = c then f k1 * (if k2 = PMonoid.unit then (1 : S) else 0) else 0) = 0 :=
    fun k2 hk2 =>
      (csum_congr fun k1 => by rw [if_neg hk2, mul_zero, ite_self]).trans csum_zero
  calc conv f convOne c
      = csum (fun k1 : K => csum fun k2 : K =>
          if k1 ⋄ k2 = c then f k1 * (if k2 = PMonoid.unit then (1 : S) else 0) else 0) :=
        csum_prod fun k1 k2 : K =>
          if k1 ⋄ k2 = c then f k1 * (if k2 = PMonoid.unit then (1 : S) else 0) else 0
    _ = csum (fun k2 : K => csum fun k1 : K =>
          if k1 ⋄ k2 = c then f k1 * (if k2 = PMonoid.unit then (1 : S) else 0) else 0) :=
        csum_swap _
    _ = csum (fun k1 : K =>
          if k1 ⋄ (PMonoid.unit : K) = c then
            f k1 * (if (PMonoid.unit : K) = PMonoid.unit then (1 : S) else 0) else 0) :=
        csum_point PMonoid.unit _ hvanish
    _ = csum (fun k1 : K => if k1 = c then f k1 else 0) :=
        csum_congr fun k1 => by
          rw [PMonoid.op_unit, if_pos (rfl : (PMonoid.unit : K) = PMonoid.unit), mul_one]
    _ = f c :=
        (csum_point c (fun k1 : K => if k1 = c then f k1 else 0)
          fun _ hk1 => if_neg hk1).trans (if_pos rfl)

/-- Convolution is associative: a panel of panels is a panel, and the
bracketing of the members is not part of the meaning. The proof is the honest
reindexing — expand each nested convolution into an aggregation over a triple
of keys and an auxiliary key naming the partial combination, reorder by
Fubini, and collapse the auxiliary key by point-mass. Associativity of `⋄` and
of `*` then match the two sides term by term. -/
theorem conv_assoc (f g h : MSemiring S K) :
    conv (conv f g) h = conv f (conv g h) := by
  funext c
  -- Expand the left bracketing over `(u, k3, k1, k2)`, where `u` names `k1 ⋄ k2`.
  have hLexp : ∀ u k3 : K,
      (if u ⋄ k3 = c then conv f g u * h k3 else 0)
        = csum (fun k1 : K => csum fun k2 : K =>
            if u ⋄ k3 = c then
              (if k1 ⋄ k2 = u then f k1 * g k2 else 0) * h k3 else 0) := by
    intro u k3
    have e1 : conv f g u
        = csum (fun k1 : K => csum fun k2 : K => if k1 ⋄ k2 = u then f k1 * g k2 else 0) :=
      csum_prod fun k1 k2 : K => if k1 ⋄ k2 = u then f k1 * g k2 else 0
    rw [e1, csum_mul_right, csum_ite_zero]
    exact csum_congr fun _ => by rw [csum_mul_right, csum_ite_zero]
  -- Expand the right bracketing over `(k1, v, k2, k3)`, where `v` names `k2 ⋄ k3`.
  have hRexp : ∀ k1 v : K,
      (if k1 ⋄ v = c then f k1 * conv g h v else 0)
        = csum (fun k2 : K => csum fun k3 : K =>
            if k1 ⋄ v = c then
              f k1 * (if k2 ⋄ k3 = v then g k2 * h k3 else 0) else 0) := by
    intro k1 v
    have e1 : conv g h v
        = csum (fun k2 : K => csum fun k3 : K => if k2 ⋄ k3 = v then g k2 * h k3 else 0) :=
      csum_prod fun k2 k3 : K => if k2 ⋄ k3 = v then g k2 * h k3 else 0
    rw [e1, csum_mul_left, csum_ite_zero]
    exact csum_congr fun _ => by rw [csum_mul_left, csum_ite_zero]
  have hL : conv (conv f g) h c
      = csum (fun k1 : K => csum fun k2 : K => csum fun k3 : K =>
          if (k1 ⋄ k2) ⋄ k3 = c then f k1 * g k2 * h k3 else 0) := by
    calc conv (conv f g) h c
        = csum (fun u : K => csum fun k3 : K =>
            if u ⋄ k3 = c then conv f g u * h k3 else 0) :=
          csum_prod fun u k3 : K => if u ⋄ k3 = c then conv f g u * h k3 else 0
      _ = csum (fun u : K => csum fun k3 : K => csum fun k1 : K => csum fun k2 : K =>
            if u ⋄ k3 = c then
              (if k1 ⋄ k2 = u then f k1 * g k2 else 0) * h k3 else 0) :=
          csum_congr fun u => csum_congr fun k3 => hLexp u k3
      _ = csum (fun k1 : K => csum fun k2 : K => csum fun k3 : K => csum fun u : K =>
            if u ⋄ k3 = c then
              (if k1 ⋄ k2 = u then f k1 * g k2 else 0) * h k3 else 0) :=
          csum_reorder4 fun u k3 k1 k2 =>
            if u ⋄ k3 = c then (if k1 ⋄ k2 = u then f k1 * g k2 else 0) * h k3 else 0
      _ = csum (fun k1 : K => csum fun k2 : K => csum fun k3 : K =>
            if (k1 ⋄ k2) ⋄ k3 = c then f k1 * g k2 * h k3 else 0) :=
          csum_congr fun k1 => csum_congr fun k2 => csum_congr fun k3 => by
            refine (csum_point (k1 ⋄ k2) _ ?_).trans ?_
            · intro u hu
              rw [if_neg (show ¬ (k1 ⋄ k2 = u) from fun he => hu he.symm), zero_mul, ite_self]
            · rw [if_pos (rfl : k1 ⋄ k2 = k1 ⋄ k2)]
  have hR : conv f (conv g h) c
      = csum (fun k1 : K => csum fun k2 : K => csum fun k3 : K =>
          if k1 ⋄ (k2 ⋄ k3) = c then f k1 * (g k2 * h k3) else 0) := by
    calc conv f (conv g h) c
        = csum (fun k1 : K => csum fun v : K =>
            if k1 ⋄ v = c then f k1 * conv g h v else 0) :=
          csum_prod fun k1 v : K => if k1 ⋄ v = c then f k1 * conv g h v else 0
      _ = csum (fun k1 : K => csum fun v : K => csum fun k2 : K => csum fun k3 : K =>
            if k1 ⋄ v = c then
              f k1 * (if k2 ⋄ k3 = v then g k2 * h k3 else 0) else 0) :=
          csum_congr fun k1 => csum_congr fun v => hRexp k1 v
      _ = csum (fun k1 : K => csum fun k2 : K => csum fun k3 : K => csum fun v : K =>
            if k1 ⋄ v = c then
              f k1 * (if k2 ⋄ k3 = v then g k2 * h k3 else 0) else 0) :=
          csum_congr fun k1 => csum_rotate3 fun v k2 k3 =>
            if k1 ⋄ v = c then f k1 * (if k2 ⋄ k3 = v then g k2 * h k3 else 0) else 0
      _ = csum (fun k1 : K => csum fun k2 : K => csum fun k3 : K =>
            if k1 ⋄ (k2 ⋄ k3) = c then f k1 * (g k2 * h k3) else 0) :=
          csum_congr fun k1 => csum_congr fun k2 => csum_congr fun k3 => by
            refine (csum_point (k2 ⋄ k3) _ ?_).trans ?_
            · intro v hv
              rw [if_neg (show ¬ (k2 ⋄ k3 = v) from fun he => hv he.symm), mul_zero, ite_self]
            · rw [if_pos (rfl : k2 ⋄ k3 = k2 ⋄ k3)]
  rw [hL, hR]
  exact csum_congr fun k1 => csum_congr fun k2 => csum_congr fun k3 => by
    rw [PMonoid.op_assoc, mul_assoc]

/-- The impossible panel: no weight on any verdict. This is the `0` of the
monoid semiring — the panel that cannot report at all, as against `convOne`,
the panel with no members, which reports the empty verdict for free. -/
def convZero : MSemiring S K := fun _ => 0

/-- Alternatives of panel-valued weightings, keywise: `msAdd f g` is the weight
of reaching a verdict by `f` *or* by `g`. This is the `+` of the monoid
semiring, and it is *fallback between two panels* — not `conv`, which runs both
and combines their verdicts. The design's insistence that sums are alternatives
and convolution is the panel is exactly the difference between these two
operations on the same carrier `K → S`. -/
def msAdd (f g : MSemiring S K) : MSemiring S K := fun k => f k + g k

/-- Alternatives of panels are unordered, because alternatives of weights
are. -/
theorem msAdd_comm (f g : MSemiring S K) : msAdd f g = msAdd g f := by
  funext k
  exact add_comm (f k) (g k)

/-- Alternatives of panels are unbracketed. -/
theorem msAdd_assoc (f g h : MSemiring S K) :
    msAdd (msAdd f g) h = msAdd f (msAdd g h) := by
  funext k
  exact add_assoc (f k) (g k) (h k)

/-- Alternatives may be moved past one another: the left-commutation law, which
is `msAdd_comm` and `msAdd_assoc` together and is what makes a *list* of
alternatives reorderable one transposition at a time (`panelOf_perm`). -/
theorem msAdd_left_comm (f g h : MSemiring S K) :
    msAdd f (msAdd g h) = msAdd g (msAdd f h) := by
  rw [← msAdd_assoc, msAdd_comm f g, msAdd_assoc]

/-- The impossible panel is the unit of alternation: an alternative that cannot
happen is no alternative. -/
theorem zero_msAdd (f : MSemiring S K) : msAdd convZero f = f := by
  funext k
  exact zero_add (f k)

/-- Convolving with the impossible panel is impossible: a member who cannot
report at all stops the whole panel. -/
theorem conv_zero_left (g : MSemiring S K) : conv convZero g = convZero := by
  funext c
  show csum (fun p : K × K => if p.1 ⋄ p.2 = c then (0 : S) * g p.2 else 0) = 0
  exact (csum_congr fun _ => by rw [zero_mul, ite_self]).trans csum_zero

/-- Convolving with the impossible panel on the right is impossible too: a
member who cannot report at all stops the whole panel, whichever half of it
that member sits in. -/
theorem conv_zero_right (f : MSemiring S K) : conv f convZero = convZero := by
  funext c
  show csum (fun p : K × K => if p.1 ⋄ p.2 = c then f p.1 * (0 : S) else 0) = 0
  exact (csum_congr fun _ => by rw [mul_zero, ite_self]).trans csum_zero

/-- Convolution distributes over alternatives on the left: offering a member a
choice of two ways to report is offering the panel a choice of two panels. -/
theorem conv_msAdd_left (f g h : MSemiring S K) :
    conv f (msAdd g h) = msAdd (conv f g) (conv f h) := by
  funext c
  show csum (fun p : K × K => if p.1 ⋄ p.2 = c then f p.1 * (g p.2 + h p.2) else 0)
      = csum (fun p : K × K => if p.1 ⋄ p.2 = c then f p.1 * g p.2 else 0)
        + csum (fun p : K × K => if p.1 ⋄ p.2 = c then f p.1 * h p.2 else 0)
  rw [← csum_add]
  exact csum_congr fun p => by
    by_cases hp : p.1 ⋄ p.2 = c
    · rw [if_pos hp, if_pos hp, if_pos hp, left_distrib]
    · rw [if_neg hp, if_neg hp, if_neg hp, add_zero]

/-- Convolution distributes over alternatives on the right. -/
theorem conv_msAdd_right (f g h : MSemiring S K) :
    conv (msAdd f g) h = msAdd (conv f h) (conv g h) := by
  funext c
  show csum (fun p : K × K => if p.1 ⋄ p.2 = c then (f p.1 + g p.1) * h p.2 else 0)
      = csum (fun p : K × K => if p.1 ⋄ p.2 = c then f p.1 * h p.2 else 0)
        + csum (fun p : K × K => if p.1 ⋄ p.2 = c then g p.1 * h p.2 else 0)
  rw [← csum_add]
  exact csum_congr fun p => by
    by_cases hp : p.1 ⋄ p.2 = c
    · rw [if_pos hp, if_pos hp, if_pos hp, right_distrib]
    · rw [if_neg hp, if_neg hp, if_neg hp, add_zero]

/-- The total weight of a panel-valued weighting: fan-in over every key at
once, forgetting which verdict was reached and keeping only how much weight
reached one. -/
def total (f : MSemiring S K) : S :=
  csum fun k : K => f k

/-- The empty panel has total weight `1`: the augmentation of the unit is the
unit. -/
theorem total_one : total (convOne : MSemiring S K) = 1 := by
  refine (csum_point PMonoid.unit _ fun k hk => if_neg hk).trans ?_
  rw [if_pos (rfl : (PMonoid.unit : K) = PMonoid.unit)]

/-- The impossible panel has total weight `0`: fan-in over a panel that never
reports aggregates nothing. -/
theorem total_zero : total (convZero : MSemiring S K) = 0 := csum_zero

/-- A certain member has total weight `1`: the point mass is *normalised*, so
`delta` places a whole unit of weight and places it in one place. With
`total_conv` this is the sanity check on `conv_delta` — both sides of the
collapse have total weight `1` — and it is why `delta` is the right notion of
"certain" rather than merely "supported at one key". -/
theorem total_delta (k : K) : total (delta k : MSemiring S K) = 1 :=
  (csum_point k _ fun _ hc => if_neg hc).trans (if_pos rfl)

/-- Fan-in commutes with alternation: the total weight of a fallback between
two panels is the alternative of their totals. This is the additive half of the
augmentation, and it is `csum_add` — the two-point agreement axiom read at the
key index, which is why it costs a line here and used to be unavailable. -/
theorem total_add (f g : MSemiring S K) : total (msAdd f g) = total f + total g :=
  csum_add f g

/-- The multiplicative half of the augmentation: the total weight of a
convolved panel is the product of the totals, so an aggregate figure computed
from the whole panel agrees with the aggregate figures computed from its
independent halves. Distributivity alone does the work; no commutativity of
`K` is needed, which is why the key monoid may be an ordered transcript and the
audit still closes.

**The augmentation is a semiring homomorphism**, and the four laws are now all
present to say so: `total_zero`, `total_one`, `total_add` and this one give
`Σ 0 = 0`, `Σ 1 = 1`, `Σ (f + g) = Σ f + Σ g` and `Σ (f ⋆ g) = Σ f · Σ g`. Both
sides are now structures rather than collections of equations: the source is
`instNSemiring` below and the target is `S` itself, so "homomorphism" names a
map between two semirings of the package and not a coincidence of four
theorems. -/
theorem total_conv (f g : MSemiring S K) : total (conv f g) = total f * total g := by
  calc total (conv f g)
      = csum (fun c : K => csum fun k1 : K => csum fun k2 : K =>
          if k1 ⋄ k2 = c then f k1 * g k2 else 0) :=
        csum_congr fun c => csum_prod fun k1 k2 : K => if k1 ⋄ k2 = c then f k1 * g k2 else 0
    _ = csum (fun k1 : K => csum fun k2 : K => csum fun c : K =>
          if k1 ⋄ k2 = c then f k1 * g k2 else 0) :=
        csum_rotate3 fun c k1 k2 => if k1 ⋄ k2 = c then f k1 * g k2 else 0
    _ = csum (fun k1 : K => csum fun k2 : K => f k1 * g k2) :=
        csum_congr fun k1 => csum_congr fun k2 =>
          (csum_point (k1 ⋄ k2) (fun c : K => if k1 ⋄ k2 = c then f k1 * g k2 else 0)
            fun _ hc => if_neg fun he => hc he.symm).trans
              (if_pos (rfl : k1 ⋄ k2 = k1 ⋄ k2))
    _ = csum (fun k1 : K => f k1 * csum fun k2 : K => g k2) :=
        csum_congr fun k1 => (csum_mul_left (f k1) fun k2 => g k2).symm
    _ = total f * total g := (csum_mul_right _ fun k1 => f k1).symm

/-- **The monoid semiring is a semiring.** `S⟨K⟩` carries `NSemiring`:
alternation of panels is `+` with the impossible panel as `0`, convolution is
`*` with the empty panel as `1`, and the fourteen laws are the theorems above.

This instance was unavailable until the semiring base was split from
commutativity, and the reason is the whole point of the split: convolution is
commutative exactly when the key monoid is (the direction this module proves is
`conv_comm`, below), and `PMonoid` deliberately does not require it — an
ordered transcript is a legitimate verdict type. Against the
old `CSemiring` alone, `S⟨K⟩` could therefore be *exhibited* as a list of nine
loose theorems but never *instantiated*, and the design's central construction
sat outside its own algebraic hierarchy. It is inside it now.

Noncomputable, for the reason `convOne` and `conv` are: the test against the
empty verdict is classical, which is what lets the key monoid be any monoid at
all — a Mazurkiewicz trace of turns, say. -/
noncomputable instance instNSemiring : NSemiring (MSemiring S K) where
  add := msAdd
  mul := conv
  zero := convZero
  one := convOne
  add_comm := msAdd_comm
  add_assoc := msAdd_assoc
  zero_add := zero_msAdd
  mul_assoc := conv_assoc
  one_mul := conv_one_left
  mul_one := conv_one_right
  left_distrib := conv_msAdd_left
  right_distrib := conv_msAdd_right
  zero_mul := conv_zero_left
  mul_zero := conv_zero_right

/-! ### From a list of contributions to the weighting it denotes

A panel is *reported* as a list — this member said that, with this weight —
and it *means* an element of `S⟨K⟩`. `panelOf` is the bridge, and the theorems
below say what survives the crossing.
-/

/-- Scaling a panel-valued weighting by a resource: `msSmul s f` charges every
verdict of `f` an extra `s`. This is the semimodule action of `S` on `S⟨K⟩` —
the same action `Agentic.Gate.smul` performs on matrices — and it is what lets
a contribution carry a weight instead of being certain. -/
def msSmul (s : S) (f : MSemiring S K) : MSemiring S K :=
  fun k => s * f k

/-- Fan-in of a scaled panel scales its fan-in: the augmentation is
`S`-linear. -/
theorem total_msSmul (s : S) (f : MSemiring S K) :
    total (msSmul s f) = s * total f :=
  (csum_mul_left s fun k => f k).symm

/-- A weighted certain contribution carries exactly its own weight. -/
theorem total_smul_delta (s : S) (k : K) :
    total (msSmul s (delta k) : MSemiring S K) = s := by
  rw [total_msSmul, total_delta, mul_one]

/-- **The denotation of a list of contributions**: each pair `(k, s)` — this
member reported `k` at weight `s` — becomes the scaled point mass
`s · δ k`, and the contributions are combined by *alternation*, since a list of
reports is a list of ways the panel could have been observed.

This is the bridge the module had been missing. `foldPanel` reduces a list of
*keys* with the key monoid; `panelOf` interprets a list of *weighted keys* as
the weighting it denotes, so that a claim about a panel's list representation
can be turned into a claim about the panel. Note that the combination here is
`msAdd` and not `conv`: these are alternatives, not independent members. -/
noncomputable def panelOf (contribs : List (K × S)) : MSemiring S K :=
  contribs.foldr (fun p acc => msAdd (msSmul p.2 (delta p.1)) acc) convZero

/-- One contribution denotes its own scaled point mass. -/
theorem panelOf_singleton (k : K) (s : S) :
    (panelOf [(k, s)] : MSemiring S K) = msSmul s (delta k) := by
  show msAdd (msSmul s (delta k)) convZero = msSmul s (delta k)
  rw [msAdd_comm, zero_msAdd]

/-- **Reordering contributions is free — at the denotation, and with no
hypothesis on the keys.** A permutation of the reports denotes the same
weighting, because alternation is commutative pointwise in `S` and nothing
else is used.

This is the honest form of the reorder licence, and stating it exposes a
distinction the list-level `foldPanel_perm` obscures: accumulating reports in a
different order was *never* the thing commutativity of `K` was needed for. What
`CMonoid K` licences is reordering the *convolution factors* — `conv_comm`,
below — which is a different theorem about a different operation. A panel whose
keys are ordered transcripts still admits arbitrary arrival order of its
contributions; what it does not admit is exchanging two members inside a
convolution. -/
theorem panelOf_perm {l l' : List (K × S)} (hp : l.Perm l') :
    (panelOf l : MSemiring S K) = panelOf l' := by
  induction hp with
  | nil => rfl
  | cons p _ ih => exact congrArg (fun z => msAdd (msSmul p.2 (delta p.1)) z) ih
  | swap _ _ _ => exact msAdd_left_comm _ _ _
  | trans _ _ ih₁ ih₂ => exact ih₁.trans ih₂

/-- Fan-in over a reported panel is the alternation of the reported weights:
the keys drop out entirely, which is what the augmentation forgetting the
verdict means when the panel is presented as a list. -/
theorem total_panelOf (l : List (K × S)) :
    total (panelOf l : MSemiring S K) = l.foldr (fun p acc => p.2 + acc) 0 := by
  induction l with
  | nil => exact total_zero
  | cons p ps ih =>
    show total (msAdd (msSmul p.2 (delta p.1)) (panelOf ps)) = p.2 + _
    rw [total_add, total_smul_delta, ih]

end Core

/-! ### The scheduler's licence, at the denotation

Commutativity of the key monoid is what lets two *members* be exchanged. It is
charged for here and nowhere else, in a section of its own so that the instance
`conv` runs on is the commutative one and no diamond can form.
-/

section Commutative

variable {S K : Type} [CompleteCSemiring S] [CMonoid K]

/-- **Convolution inherits commutativity from the key monoid.** Two members of
a panel may be exchanged: `f ⋆ g = g ⋆ f`. This is the scheduler's licence
of §5.1 stated where it belongs — about the panel's *meaning*, not about a list
that happens to represent it — and it is the licence `instNSemiring` cannot
carry, since `NSemiring` deliberately does not assume `mul_comm`.

The proof is a reindexing of the pair sum by the swap: Fubini exchanges the two
aggregations, `CMonoid.op_comm` matches the guards, and `mul_comm` of `S`
matches the weights.

The hypothesis is not idle generality. Over the free key monoid the licence
genuinely fails, and `Agentic.Keys` exhibits the failure at the denotation:
two certain members reporting `[0]` and `[1]` convolve to different weightings
in the two orders. -/
theorem conv_comm (f g : MSemiring S K) : conv f g = conv g f := by
  funext c
  calc conv f g c
      = csum (fun k1 : K => csum fun k2 : K => if k1 ⋄ k2 = c then f k1 * g k2 else 0) :=
        csum_prod fun k1 k2 : K => if k1 ⋄ k2 = c then f k1 * g k2 else 0
    _ = csum (fun k2 : K => csum fun k1 : K => if k1 ⋄ k2 = c then f k1 * g k2 else 0) :=
        csum_swap _
    _ = csum (fun k2 : K => csum fun k1 : K => if k2 ⋄ k1 = c then g k2 * f k1 else 0) :=
        csum_congr fun k2 => csum_congr fun k1 => by
          rw [CMonoid.op_comm k1 k2, mul_comm (f k1) (g k2)]
    _ = conv g f c :=
        (csum_prod fun k2 k1 : K => if k2 ⋄ k1 = c then g k2 * f k1 else 0).symm

end Commutative

/-! ### The duplication licence, at the denotation

Idempotence is the licence to *speculate*: run a member twice, race two copies,
accept an at-least-once delivery. At the denotation it splits in two, because
`S⟨K⟩` has two operations and each has its own idempotence hypothesis.

Neither is the general law `conv f f = f`, and that law is not available: the
augmentation forces `total f = total f * total f` on any panel satisfying it,
so it is a property of particular weightings (the point masses, whose total is
`1`) and not a licence an idempotent key monoid confers on all of them.
-/

section Idempotent

variable {S : Type} [CompleteCSemiring S]

/-- **Speculation on a certain member is free.** At an idempotent key monoid, a
member certain of its verdict may be run twice and convolved with itself
without changing the panel: `δ k ⋆ δ k = δ k`. This is the smallest true
statement of the duplication licence at the denotation, and it is exactly
`conv_delta` composed with `op_idem`.

It does *not* generalise to `conv f f = f` for arbitrary `f`, and the
augmentation says why: `total (conv f f) = total f * total f`, which returns
`total f` only when the total weight is idempotent under `*`. The point mass
satisfies that (`total_delta` is `1`); a spread-out weighting need not. -/
theorem conv_delta_idem {K : Type} [IdemCMonoid K] (k : K) :
    conv (delta k) (delta k) = (delta k : MSemiring S K) := by
  rw [conv_delta, IdemCMonoid.op_idem]

/-- **Duplicating an alternative is free** whenever the resource algebra's
alternation is a join: offering the same panel twice as a fallback offers it
once. This is the other half of the duplication licence, and it is charged to
`S` rather than to `K` — `IdemAdd` (possibility, worst-case cost) has it, a
counting or probabilistic carrier does not. -/
theorem msAdd_idem {K : Type} [PMonoid K] [IdemAdd S] (f : MSemiring S K) :
    msAdd f f = f := by
  funext k
  exact add_idem (f k)

end Idempotent

end MSemiring

/-! ## The reducer, and the list it reduces

What follows is about *lists*, and saying so is the point. A panel is not a
list; its meaning is the `MSemiring` element above. A list of contributions is
one *representation* a scheduler happens to hold, and `foldPanel` is one
reducer applied to that representation — the free one, `⋄` folded from the
right. The theorems in this section are therefore theorems about lists, and
they earn their place by being what `Agentic.Keys` consumes and by being
transportable to the denotation: `MSemiring.convFold_delta`, at the end of the
module, shows that folding a list of *certain* members by convolution is the
point mass at `foldPanel`, whence the denotational forms of the two licences.
-/

/-- The reducer of a list of contributions: combine them from the right,
starting from the empty verdict. This is the free reducer on the key monoid,
and it is what a scheduler holding a list of members' verdicts computes. -/
def foldPanel {F : Type} [PMonoid F] (l : List F) : F :=
  l.foldr PMonoid.op PMonoid.unit

section Reducer

variable {F : Type}

/-- The empty panel reduces to the empty verdict. -/
theorem foldPanel_nil [PMonoid F] : foldPanel ([] : List F) = PMonoid.unit := rfl

/-- Reducing a panel is combining the first member with the reduction of the
rest. -/
theorem foldPanel_cons [PMonoid F] (x : F) (l : List F) :
    foldPanel (x :: l) = x ⋄ foldPanel l := rfl

/-- A panel may be split into two and its halves reduced separately: the
reducer is a monoid homomorphism from lists. This is the licence to *shard* a
panel, and it needs only associativity. -/
theorem foldPanel_append [PMonoid F] (l l' : List F) :
    foldPanel (l ++ l') = foldPanel l ⋄ foldPanel l' := by
  induction l with
  | nil => exact (PMonoid.unit_op _).symm
  | cons x xs ih =>
    show x ⋄ foldPanel (xs ++ l') = (x ⋄ foldPanel xs) ⋄ foldPanel l'
    rw [ih]
    exact (PMonoid.op_assoc _ _ _).symm

/-- The reducer's algebra is a licence on the scheduler: commutative ⇒ the
scheduler may reorder. Members may return in any order — out of a thread pool,
as network replies arrive, in whatever order retries settle — and the reduced
verdict is unchanged. Without `CMonoid.op_comm` this theorem is false, and the
scheduler owes the design a fixed order.

This is a fact about the list; `MSemiring.convFold_perm` is the same licence
about the weighting the list denotes. -/
theorem foldPanel_perm [CMonoid F] {l l' : List F} (hp : l.Perm l') :
    foldPanel l = foldPanel l' := by
  induction hp with
  | nil => rfl
  | cons x _ ih => exact congrArg (fun z => x ⋄ z) ih
  | swap x y l =>
    show y ⋄ (x ⋄ foldPanel l) = x ⋄ (y ⋄ foldPanel l)
    rw [← PMonoid.op_assoc, ← PMonoid.op_assoc, CMonoid.op_comm y x]
  | trans _ _ ih₁ ih₂ => exact ih₁.trans ih₂

/-- Idempotence is a licence on *duplication*: for a semilattice-like reducer
— one whose `⋄` is idempotent, as `max`, `min`, union and "any" all are — a
panel run twice reduces to the same verdict as the panel run once, so
at-least-once delivery is safe and retries need no deduplication.

Again a fact about the list; `MSemiring.convFold_dup` is the same licence about
the weighting. -/
theorem foldPanel_dup [PMonoid F] (hidem : ∀ x : F, x ⋄ x = x) (l : List F) :
    foldPanel (l ++ l) = foldPanel l := by
  rw [foldPanel_append, hidem]

end Reducer

namespace MSemiring

open Classical

/-! ## The bridge: the reducer *is* the denotation's reducer

`foldPanel` reduces a list of keys and `conv` convolves weightings, and until
the two are related the first is an operation on a representation that the
second cannot see. `convFold` convolves a list of *certain* members, and
`convFold_delta` identifies it with the point mass at `foldPanel`. The two
scheduler licences then transport to the denotation as corollaries, which is
what makes them licences on the panel rather than on the scheduler's
bookkeeping.
-/

section Bridge

variable {S K : Type} [CompleteCSemiring S] [PMonoid K]

/-- The panel denoted by a list of *certain* members: each member reports its
key with certainty, and the panel is their convolution. Unlike `panelOf`, which
alternates weighted contributions, this combines independent members — the
two ways a list can denote a panel, and the reason both are written down. -/
noncomputable def convFold (l : List K) : MSemiring S K :=
  l.foldr (fun k acc => conv (delta k) acc) convOne

/-- **The reducer is the denotation's reducer.** Convolving a list of certain
members is the point mass at their reduction: `⋆ᵢ δ kᵢ = δ (foldPanel l)`.
This is `conv_delta` iterated, and it is the statement that `foldPanel` is not
an incidental list operation but the shadow, on point masses, of convolution
itself. -/
theorem convFold_delta (l : List K) : (convFold l : MSemiring S K) = delta (foldPanel l) := by
  induction l with
  | nil => exact delta_unit.symm
  | cons x xs ih =>
    show conv (delta x) (convFold xs) = delta (x ⋄ foldPanel xs)
    rw [ih, conv_delta]

end Bridge

/-- **The scheduler's reorder licence, about the panel.** At a commutative key
monoid, a permuted list of certain members denotes the *same weighting* — not
merely the same reduced list element. This is `foldPanel_perm` transported
across `convFold_delta`, and it is what a weighting can see. -/
theorem convFold_perm {S K : Type} [CompleteCSemiring S] [CMonoid K]
    {l l' : List K} (hp : l.Perm l') : (convFold l : MSemiring S K) = convFold l' := by
  rw [convFold_delta, convFold_delta, foldPanel_perm hp]

/-- **The speculation licence, about the panel.** At an idempotent commutative
key monoid, running the whole panel twice denotes the same weighting as running
it once: at-least-once delivery does not change the panel's meaning. This is
`foldPanel_dup` transported across `convFold_delta`. -/
theorem convFold_dup {S K : Type} [CompleteCSemiring S] [IdemCMonoid K]
    (l : List K) : (convFold (l ++ l) : MSemiring S K) = convFold l := by
  rw [convFold_delta, convFold_delta, foldPanel_dup IdemCMonoid.op_idem]

end MSemiring

end Agentic
