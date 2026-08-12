-- The package's one monoid — `⋄`, with commutativity and idempotence as
-- separate licences — its two actions on a reader (scoping and the derivative),
-- and the partial order an idempotent join induces.
import Agentic.Monoid
-- Semirings (non-commutative base and commutative strengthening), complete
-- (arbitrary-index `csum`) semirings, the canonical additive order `≤+`, and
-- the two star classes: `StarSemiring`, one unrolling law over the
-- non-commutative base so that matrices may have a star, and `KleeneStar`,
-- which adds idempotent `+` and Kleene induction so that the star is the least
-- solution; also why countability is a remark about the models rather than a
-- premise of the meanings.
import Agentic.Semiring
-- Carriers: possibility (`Prop`), worst-case cost (max-plus with a genuine ⊥),
-- consensus weight (`Prob`, the Viterbi semiring built exactly as the
-- probabilities 2⁻ⁿ and 0), and the expectation semiring `P ⋉ M` as a
-- square-zero extension — complete over any complete module of moments
-- (`CompletePMod`) and starred by `⟨p*, p* m p*⟩`. The first three carry stars
-- that are least (`KleeneStar`); the fourth carries a star that answers the
-- unrolling law, its `+` not being idempotent.
import Agentic.Instances
-- `S`-matrices as resource-weighted transitions: identity, zero,
-- Chapman–Kolmogorov composition (a semiring), Kronecker product,
-- value-dependent sequencing = composition.
import Agentic.Matrix
-- Consultations and environments `ε`, pinning `ε[q ↦ a]`, the extensional
-- meaning space, caching-as-identity, and `share` ≠ `dup`.
import Agentic.Env
-- The monoid semiring (convolution over panel keys, a semiring in its own
-- right), the augmentation homomorphism, point masses and the collapse of the
-- deltas to convolution, the scheduler licences stated about the weighting
-- rather than about a list, and the two bridges (`panelOf`, `convFold`) from a
-- list representation to the panel it denotes.
import Agentic.Panel
-- Inhabitants for the panel keys: the free monoid on names, newtype-guarded
-- Tally/Width reducers, and the idempotent Bool-or witness for speculate/race.
import Agentic.Keys
-- Mazurkiewicz traces as a genuine quotient, sessions `Trace → S`, and the
-- Brzozowski derivative that fork and resume share.
import Agentic.Trace
-- Per-axis `Last` monoids; scoping as the monoid's right action on a reader,
-- with innermost-wins and the covariant composition law as theorems.
import Agentic.Scope
-- Gating as the scalar action of an indicator: refusal is `0` and annihilates
-- downstream, and nested guards intersect.
import Agentic.Gate
-- The information-ordered context: compaction as an interior operator, the
-- context-parameterised index family, and the `const ε` collapse.
import Agentic.Context
-- The retry solve `(M_A · d)* · M_B`, its loop equation and — under
-- `KleeneStar` — its leastness, at matrices as well as scalars; the
-- reachability star at possibility, least by induction on path length; the
-- read-outs at `Prop`, `Cost` (including the three-answer loop the leastness
-- principle was written for), `Prob` (Viterbi absorption) and expectation
-- (`p* m p*`, and the projection commuting with the solve); fuel as
-- truncation, bounded at the retry matrix.
import Agentic.Star
-- The Pareto preorder on resource factors, with an incomparability witness.
import Agentic.Pareto
-- The fragment grade: static | bounded n | monadic, with join (sequencing),
-- par (tensor widths add), and scale (fan multiplicities multiply, the body
-- counting at least as one copy of itself).
import Agentic.Frag
-- The syntax stratum: workflow terms as an inductive family indexed by Frag,
-- semiring-free; consultation identity is positional, so duplication is the
-- default and sharing is the explicit labeled shareT (§6a, Env.share_ne_dup).
import Agentic.Term
-- The meaning stratum: the two folds of §3 out of one syntax — the
-- quantitative muS into matrices (each clause a §4 type-class-morphism row)
-- and the site-keyed extensional muExt into partial functions — the width
-- fold that makes the grade discipline true, sharing made observable, and
-- workflow equality as the quotient by extensional meaning.
import Agentic.Meaning

/-!
# Agentic — the denotational design of agentic workflows

Root module. Each import formalizes one stratum of the semantic space; see
README.md for the mapping to the design document.

(Lean's header rule puts the imports above this docstring: a module's `import`
commands must precede every other command, module documentation included.)
-/
