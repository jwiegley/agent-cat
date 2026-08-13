import Agentic.Core.Denote
import Agentic.Core.Acp

/-!
# The interpreter: the fold at the execution monad, and the one place `IO` enters

Rederivation kernel §5 (runtime adherence), §5(i) (commutation is `rfl` because
the interpreter *is* the fold), §5(ii) (adequacy against an adversarial agent,
compiled as `attack-realizability-lean/B_adequacy.lean`), and §5's closing
paragraph: *"the entire remaining trust boundary is one total parsing function
per `Code`"*. This module is where that sentence becomes code.

**The shape of the file is the argument.** Three layers, in this order, and the
order is the point.

1. **`Decode`** — one total parser per code. This is the trusted base and
   nothing below it is proved; see its docstring, which says so in as many
   words.
2. **`Dlg.execM`** — the memoizing fold, monad-polymorphic, with the answering
   service passed in as an argument (`Oracle m`). *Every* theorem in this file
   is about this function. At `m := Id` the oracle is an arbitrary,
   history-dependent, lying, drifting strategy and adequacy holds with **no
   hypothesis about it**; at `m := Id` with the oracle `fun c q _ => pure (ω c q)`
   it computes `Dlg.run ω`, which is the factorization theorem.
3. **`Exec.oracle`** — the `IO` answering service over `Agentic.Core.Acp`. It is
   an `Oracle IO`, and *no declaration the theorems are about mentions `IO`*:
   the interpreter at `m := IO` is the interpreter at `m := Id`, instantiated.
   `exec` is one line and every part of it is from layers 1–3.

**What is proved, exactly.**

* `execM_le` — the table only grows: `t ≤ (execM o p t).2`, for every oracle
  at `Id`.
* `execM_adequacy` — for every oracle at `Id`, every world extending the final
  table extends the initial one and assigns `p` the value the run returned.
  No hypothesis whatsoever about the oracle: the memo table discharges
  functionality *structurally*, which is §5(ii)'s whole claim.
* `execM_pure` — the factorization: at the oracle `pureOracle ω` the run returns
  `Dlg.run ω p`, the final table is extended by `ω`, and every cell the run
  asked about is recorded with the answer `ω` gives it — so
  `worldOf` of the final table agrees with `ω` on exactly the trace
  (`worldOf_execM_pure`).
* `Plan.execWith_eq_execM_denote` — `rfl`. The interpreter is `denote` followed
  by `execM`; §5(i) costs nothing because nothing else was written.
* `Plan.execPure_fst` and `Plan.worldOf_execPure` — the same two facts at a
  closed plan and the empty table, where they carry no hypothesis at all:
  `exec` with the oracle removed *is* `run ω ∘ denote`, and the table it leaves
  behind is a world agreeing with `ω` on the transcript.

**What is `IO`, and is therefore definitions and not theorems.** `Exec.oracle`
and everything it calls. It renders a question into a prompt, sends it over the
transport, decodes the reply, re-asks on a decode failure, and — when no attempt
could be read — **fails the run**, because the one thing an answering service
must never do is record an answer nobody gave. No declaration in this file is an
`axiom`; the trust boundary is *documented*, never asserted as a proposition. An
adapter that lies merely exhibits a different world, and `execM_adequacy`
quantifies over all of them. Since none of that has a proof, it has a test
instead: `test/ExecSmoke.lean` (`lake exe exec_smoke`) drives `exec` against
`test/stub_adapter.py` and checks, among other things, that a plan asking one
question twice prompts the adapter once, and that an unreadable answer aborts
the run rather than entering the table.
-/

namespace Agentic.Core

/-! ## The trusted base: one total parser per code

Everything in this section is a *decision about what bytes mean*. It is the
only such decision in the package, and it is deliberately concentrated in four
clauses so that it can be read in one sitting. -/

namespace Exec

/-- `[[norm s]]` = the bytes an answer-word parser actually looks at: ASCII
whitespace stripped from both ends, then lowercased.

Factored out and named because every claim below about `Decode` is stated
*through* it: `String` operations do not reduce in the kernel in this Lean
(literals are byte arrays behind opaque primitives), so a theorem like
`Decode .flag "yes" = some true` is not provable by `decide` and is not worth an
axiom. Stating the hypotheses as membership facts about `norm s` is the honest
form: it says exactly what the parser branches on and leaves the byte-level
behaviour of `trimAscii`/`toLower` where it belongs, in Lean core. -/
def norm (s : String) : String := s.trimAscii.toString.toLower

/-- `[[answerLines s]]` = the nonblank lines of `s`, each ASCII-trimmed: the
objections a reviewer raised, one per line, with the blank lines a model likes
to emit discarded. -/
def answerLines (s : String) : List String :=
  ((s.splitOn "\n").map (fun l => l.trimAscii.toString)).filter (fun l => !l.isEmpty)

/-- The spellings accepted as *yes*. -/
def yesWords : List String := ["yes", "y", "true", "approve", "ok"]

/-- The spellings accepted as *no*. -/
def noWords : List String := ["no", "n", "false", "reject", "deny"]

/-- The one spelling that means "nothing was objected to". -/
def approveWord : String := "approve"

/-- `[[decodeFlag s]]` = the yes/no `s` states, or `none` if it states neither.

**The only clause of `Decode` that can fail**, which is `Decode_eq_none` below.
A `flag` is the one code whose answer set is smaller than what an addressee can
say, so it is the one place the runtime has to be prepared to re-ask. -/
def decodeFlag (s : String) : Option Bool :=
  if norm s ∈ yesWords then some true
  else if norm s ∈ noWords then some false
  else none

/-- `[[decodeVerdict s]]` = the verdict `s` records.

Total, and that is §3 q8 discharged at the wire: **refusal is an answer**, so
there is no failure mode here to propagate. Three clauses, and each is a
meaning:

* an addressee who said nothing at all `declined` — an empty turn is what a
  `stopReason` of `refusal` or `cancelled` arrives as, and recording it as
  approval would be recording an answer nobody gave;
* the single word *approve* is `1`, the unit of the verdict monoid;
* anything else is the formal product of its nonblank lines, one objection per
  line, so that `Verdict.object` and hence `Approved`'s morphism into
  conjunction see exactly what the reviewer wrote. -/
def decodeVerdict (s : String) : Verdict :=
  let ls := answerLines s
  if ls = [] then Verdict.declined
  else if ls.map norm = [approveWord] then Verdict.approve
  else Verdict.object ls

end Exec

open Exec in
/-- `[[Decode]]` = **the trusted base**: for each code, the total function taking
the bytes an addressee produced to the thing it is thereby taken to have said.

*Say it plainly.* Nothing in this package proves that these four clauses are the
right reading of an addressee's words. They cannot be proved; they are the
definition of what the words *mean to us*, and kernel §5 names them as the
entire remaining trust boundary once refusal is an answer. What the package does
instead of proving them is (a) make them total, (b) make them the *only* such
decision — no other function in the repository turns a `String` into an `El c` —
and (c) prove everything downstream against an arbitrary world, so that a
misparse is a different world and not a broken theorem.

The four clauses:

```
Decode .text    s = some s                     -- what was said is what was said
Decode .flag    s = decodeFlag s               -- yes/no/true/false…, or none
Decode .verdict s = some (decodeVerdict s)     -- total: refusal is an answer
Decode .ack     s = some ()                    -- an acknowledgement carries nothing
```

`Option`-valued because exactly one code can fail to parse (`Decode_eq_none`);
the runtime's response to that failure — re-ask, then default — is
`Exec.oracle`, and it is `IO`, not a theorem. -/
def Decode : (c : Code) → String → Option (El c)
  | .text, s => some s
  | .flag, s => decodeFlag s
  | .verdict, s => some (decodeVerdict s)
  | .ack, _ => some ()

/-- **Clause equation.** Free text is returned verbatim: the trusted base does
not paraphrase. -/
@[simp] theorem Decode_text (s : String) : Decode .text s = some s := rfl

/-- **Clause equation.** An acknowledgement carries no information, so anything
at all acknowledges. -/
@[simp] theorem Decode_ack (s : String) : Decode .ack s = some () := rfl

/-- **Clause equation.** A verdict always parses. -/
@[simp] theorem Decode_verdict (s : String) :
    Decode .verdict s = some (Exec.decodeVerdict s) := rfl

/-- **Clause equation.** -/
@[simp] theorem Decode_flag (s : String) : Decode .flag s = Exec.decodeFlag s := rfl

/-- **The failure surface is one code wide.** If the trusted base cannot read an
answer, the question asked for a `flag`; `text`, `verdict` and `ack` are total.

This is why the re-ask loop in `Exec.oracle` is not a general error-handling
layer: it exists for the single code whose answer set is smaller than what an
addressee can say. -/
theorem Decode_eq_none {c : Code} {s : String} (h : Decode c s = none) : c = .flag := by
  cases c with
  | text => exact absurd h (by simp)
  | verdict => exact absurd h (by simp)
  | ack => exact absurd h (by simp)
  | flag => rfl

/-- …and the contrapositive in the form the interpreter uses: every code but
`flag` answers. -/
theorem Decode_isSome {c : Code} (s : String) (h : c ≠ .flag) : (Decode c s).isSome := by
  cases hc : Decode c s with
  | none => exact absurd (Decode_eq_none hc) h
  | some _ => rfl

namespace Exec

/-- **Clause equation, the yes side.** -/
theorem decodeFlag_eq_some_true {s : String} (h : norm s ∈ yesWords) :
    decodeFlag s = some true := by simp [decodeFlag, h]

/-- **Clause equation, the no side.** The `yes` list is consulted first, so a
spelling appearing in both would read as yes; that the two lists are disjoint is
a fact about six string literals which this Lean cannot reduce, and it is
therefore a *hypothesis* here rather than a lemma — an honest statement of what
the parser branches on, and the reason the lists are named constants a reader
can check by eye. -/
theorem decodeFlag_eq_some_false {s : String} (h₁ : norm s ∉ yesWords)
    (h₂ : norm s ∈ noWords) : decodeFlag s = some false := by
  simp [decodeFlag, h₁, h₂]

/-- **…and the failure is exactly "neither spelling".** The one re-ask trigger in
the whole runtime, characterized. -/
theorem decodeFlag_eq_none_iff {s : String} :
    decodeFlag s = none ↔ norm s ∉ yesWords ∧ norm s ∉ noWords := by
  unfold decodeFlag
  by_cases h₁ : norm s ∈ yesWords
  · simp [h₁]
  · by_cases h₂ : norm s ∈ noWords <;> simp [h₁, h₂]

/-- **Clause equation.** An addressee who said nothing declined. -/
theorem decodeVerdict_eq_declined {s : String} (h : answerLines s = []) :
    decodeVerdict s = Verdict.declined := by simp [decodeVerdict, h]

/-- **Clause equation.** The single word *approve* is the unit of the verdict
monoid. -/
theorem decodeVerdict_eq_approve {s : String} (h₁ : answerLines s ≠ [])
    (h₂ : (answerLines s).map norm = [approveWord]) :
    decodeVerdict s = Verdict.approve := by simp [decodeVerdict, h₁, h₂]

/-- **Clause equation.** Anything else is the formal product of the lines. -/
theorem decodeVerdict_eq_object {s : String} (h₁ : answerLines s ≠ [])
    (h₂ : (answerLines s).map norm ≠ [approveWord]) :
    decodeVerdict s = Verdict.object (answerLines s) := by simp [decodeVerdict, h₁, h₂]

/-- **The classifier a `caseV` branches on, read off the wire.** Silence
declines, *approve* approves, and everything else objects — so the three arms of
`Plan.caseV` are in bijection with the three clauses of the parser, and no
fourth reading of a reply exists. -/
theorem tag_decodeVerdict (s : String) :
    Verdict.tag (decodeVerdict s) =
      (if answerLines s = [] then VTag.declined
       else if (answerLines s).map norm = [approveWord] then VTag.approve
       else VTag.object) := by
  by_cases h₁ : answerLines s = []
  · simp [decodeVerdict_eq_declined h₁, h₁]
  · by_cases h₂ : (answerLines s).map norm = [approveWord]
    · simp [decodeVerdict_eq_approve h₁ h₂, h₁, h₂]
    · rw [decodeVerdict_eq_object h₁ h₂]
      have hne : answerLines s ≠ [] := h₁
      simp only [h₁, h₂, if_false, Verdict.tag]
      rw [if_neg (Verdict.object_ne_declined _), if_neg ?hap]
      case hap =>
        intro hcon
        exact hne ((Verdict.approved_object_iff (answerLines s)).mp hcon)

end Exec

/-! ## The interpreter: a memoizing fold, with the answering service an argument

Nothing in this section mentions `IO`. The interpreter is polymorphic in the
monad the answering service lives in, so the term that runs against a real
adapter and the term the theorems below are about are *the same term*. -/

/-- `[[Oracle m]]` = an answering service in `m`: given a code, a question, and
everything the run has heard so far, it produces an answer.

Three things are said by this type and they are the reason it is this type.

* **It is history-dependent.** The `Table` argument is `B_adequacy.lean`'s
  `Strategy` — the oracle may consult everything already said, so it may lie,
  drift, contradict itself, or answer differently on a second run. Adequacy is
  proved against all of them.
* **It cannot rewrite history.** It returns `m (El c)` and not `m (El c × Table)`,
  so an oracle can invent an answer but cannot forge or delete a recorded one.
  That is a structural fact about the type, not a discipline the code follows.
* **It is where `IO` is quarantined.** `Exec.oracle` is the only `Oracle IO` in
  the package; every other effectful declaration in this file exists to build it
  or to run it, and none of them is mentioned by a theorem. -/
abbrev Oracle (m : Type → Type) : Type := (c : Code) → Q c → Table → m (El c)

/-- `[[OracleM]] = StateT Table IO`: the execution monad — a run is an `IO`
computation threading the finite world it is constructing.

The state *is* the world being built (`Agentic.Core.Table`, and `worldOf` is its
totalization), which is why the interpreter needs no separate log: the memo
table and the transcript are the same object seen twice. -/
abbrev OracleM : Type → Type := StateT Table IO

/-- `[[Dlg.execM o p t]]` = run the dialogue `p` against the answering service
`o`, starting from what `t` already records, and return the answer together with
the table the run leaves behind.

**Look up before asking; record after answering.** Those two lines are the whole
of kernel §5's argument. `lookup` before the ask is what makes the run
*functional* — one question, one answer, however faithless the addressee — with
no hypothesis on the oracle, and `Table.cons` after it is what makes the run
exhibit a world: `worldOf` sends `cons` to `pin` (`worldOf_cons`) and the
prepend preserves every older lookup exactly because the key was absent
(`lookup_cons_of`). The memo table is not a cache bolted onto an interpreter; it
is the finite world the run constructs, and consulting it is what discharges
MF's `Functional τ` hypothesis structurally.

A deliberate resample is *not* defeated by this: `Q.draw` is a field of the
question, so a second draw is a different question and misses the table by
construction (§3 q1). -/
def Dlg.execM {m : Type → Type} [Monad m] {A : Type} (o : Oracle m) :
    Dlg A → Table → m (A × Table)
  | .done a, t => pure (a, t)
  | .ask c q f, t =>
      match lookup t c q with
      | some a => Dlg.execM o (f a) t
      | none => do
          let a ← o c q t
          Dlg.execM o (f a) (Table.cons c q a t)

namespace Dlg

variable {m : Type → Type} [Monad m] {A : Type}

/-- A finished dialogue asks nothing and records nothing. -/
@[simp] theorem execM_done (o : Oracle m) (a : A) (t : Table) :
    execM o (.done a) t = pure (a, t) := rfl

/-- **The cache hit is the identity on the table**: a question the run has
already put is not put again. -/
theorem execM_ask_hit (o : Oracle m) (c : Code) (q : Q c) (f : El c → Dlg A)
    {t : Table} {a : El c} (h : lookup t c q = some a) :
    execM o (.ask c q f) t = execM o (f a) t := by
  rw [execM, h]

/-- **The cache miss asks, then records**, and records before continuing, so the
continuation runs in the extended world. -/
theorem execM_ask_miss (o : Oracle m) (c : Code) (q : Q c) (f : El c → Dlg A)
    {t : Table} (h : lookup t c q = none) :
    execM o (.ask c q f) t =
      o c q t >>= fun a => execM o (f a) (Table.cons c q a t) := by
  rw [execM, h]

end Dlg

/-! ### What the run does to the table -/

/-- **The table only grows.** For every oracle, the final table extends the
initial one in the extension order of `Agentic/Core/World.lean` — the run adds
answers and never disturbs one, because `Table.cons` is only reached where
`lookup` said `none`, which is `le_cons_of_lookup_none`'s hypothesis exactly. -/
theorem execM_le {A : Type} (o : Oracle Id) (p : Dlg A) :
    ∀ t : Table, t ≤ (Dlg.execM o p t).2 := by
  induction p with
  | done a => intro t; exact le_refl t
  | ask c q f ih =>
    intro t
    rw [Dlg.execM]
    cases ha : lookup t c q with
    | some a => simpa using ih a t
    | none =>
      simp only []
      exact le_trans (le_cons_of_lookup_none _ ha) (ih _ _)

/-- **Adequacy, against an adversarial agent** (kernel §5(ii); the compiled probe
is `attack-realizability-lean/B_adequacy.lean`).

For **every** oracle — history-dependent, and free to lie, drift or
contradict itself — and every world `ω` that agrees with the table the run left
behind:

* `ω` agrees with the table the run started from, and
* `ω` assigns the dialogue exactly the value the run returned.

**There is no hypothesis about the oracle**, and that is the theorem's whole
content: consulting the memo table before asking discharges functionality
structurally, so no `Functional τ` side condition is needed and no property of
the agents is assumed. What the run produced is what the plan *means* in some
world, and the run exhibits that world.

Stated at `m := Id`, because a theorem about what an `IO` action returns would
require modelling `IO`. The interpreter is one definition instantiated at two
monads, so this is a theorem about the same term that runs against an adapter;
the per-run certificate is what carries it to an actual `IO` run. -/
theorem execM_adequacy {A : Type} (o : Oracle Id) (p : Dlg A) :
    ∀ t : Table,
      (∀ ω, Extends ω (Dlg.execM o p t).2 → Extends ω t) ∧
      (∀ ω, Extends ω (Dlg.execM o p t).2 → Dlg.run ω p = (Dlg.execM o p t).1) := by
  induction p with
  | done a => intro t; exact ⟨fun _ h => h, fun _ _ => rfl⟩
  | ask c q f ih =>
    intro t
    rw [Dlg.execM]
    cases ha : lookup t c q with
    | some a =>
      simp only []
      obtain ⟨h1, h2⟩ := ih a t
      refine ⟨h1, fun ω hω => ?_⟩
      have hωa : ω c q = a := h1 ω hω c q a ha
      rw [Dlg.run_ask, hωa]
      exact h2 ω hω
    | none =>
      simp only []
      obtain ⟨h1, h2⟩ := ih (o c q t) (Table.cons c q (o c q t) t)
      refine ⟨fun ω hω c₀ q₀ a₀ hf => h1 ω hω c₀ q₀ a₀ (lookup_cons_of ha hf), fun ω hω => ?_⟩
      have hωa : ω c q = o c q t :=
        h1 ω hω c q _ (lookup_cons_self t c q (o c q t))
      rw [Dlg.run_ask, hωa]
      exact h2 ω hω

/-! ### The pure boundary: the interpreter at a function-world

`pureOracle ω` is the answering service that simply *is* the world `ω`. Running
the interpreter against it is running the meaning, and the three conclusions of
`execM_pure` say so: the value is `Dlg.run ω`, the table is a finite
approximation of `ω`, and the cells the run touched are exactly the transcript's.

This is the factorization the file exists to establish. The `IO` layer is the
oracle argument and nothing else, so replacing that argument by a function
recovers the denotational semantics **on the nose**, with no interpreter of a
second kind and no simulation relation. -/

/-- `[[pureOracle ω]]` = the answering service that answers as the world `ω`
does, ignoring the history because a world is a function of the question
(§3 q1). -/
def pureOracle (ω : Ω) : Oracle Id := fun c q _ => pure (ω c q)

/-- Every event of a transcript records the answer the world gives; the
transcript is a *reading* of `ω` and not an independent log. -/
theorem Dlg.mem_trace_answer {A : Type} (ω : Ω) (p : Dlg A) :
    ∀ e ∈ Dlg.trace ω p, ω e.c e.q = e.a := by
  induction p with
  | done a => intro e he; simp at he
  | ask c q f ih =>
    intro e he
    rw [Dlg.trace_ask, List.mem_cons] at he
    rcases he with rfl | he
    · rfl
    · exact ih _ e he

/-- **The factorization theorem.** At the oracle `pureOracle ω`:

1. the run returns `Dlg.run ω p` — the *meaning*, recovered by the interpreter
   with no adequacy gap;
2. `ω` extends the table the run leaves behind, so the run's record is a finite
   approximation of the world it ran in;
3. every cell the run asked about is recorded in that table with the answer it
   got — the table *covers the transcript*.

Together with `execM_le` these say that the interpreter is `Dlg.run` paired with
a memo table that agrees with the world exactly on what was consulted, which is
the sense in which the `IO` layer is only the oracle: swap the oracle for a
function and the semantics is back, on the nose. -/
theorem execM_pure {A : Type} (ω : Ω) (p : Dlg A) :
    ∀ t : Table, Extends ω t →
      (Dlg.execM (pureOracle ω) p t).1 = Dlg.run ω p ∧
      Extends ω (Dlg.execM (pureOracle ω) p t).2 ∧
      ∀ e ∈ Dlg.trace ω p, lookup (Dlg.execM (pureOracle ω) p t).2 e.c e.q = some e.a := by
  induction p with
  | done a => intro t ht; exact ⟨rfl, ht, by simp⟩
  | ask c q f ih =>
    intro t ht
    rw [Dlg.execM]
    cases ha : lookup t c q with
    | some a =>
      simp only []
      have hωa : ω c q = a := ht c q a ha
      obtain ⟨h1, h2, h3⟩ := ih a t ht
      refine ⟨by rw [Dlg.run_ask, hωa]; exact h1, h2, ?_⟩
      intro e he
      rw [Dlg.trace_ask, List.mem_cons] at he
      rcases he with rfl | he
      · have hle : t ≤ (Dlg.execM (pureOracle ω) (f a) t).2 := execM_le _ _ t
        exact hle c q a ha |>.trans (by rw [hωa])
      · rw [hωa] at he; exact h3 e he
    | none =>
      simp only []
      have hcons : Extends ω (Table.cons c q (ω c q) t) := by
        intro c₀ q₀ a₀ h
        by_cases hc : c = c₀
        · subst hc
          by_cases hq : q₀ = q
          · subst hq; rw [lookup_cons_self] at h; exact (Option.some.inj h) ▸ rfl
          · rw [lookup_cons_of_ne_q t c _ hq] at h; exact ht c q₀ a₀ h
        · rw [lookup_cons_of_ne_code t q q₀ _ hc] at h; exact ht c₀ q₀ a₀ h
      obtain ⟨h1, h2, h3⟩ := ih (ω c q) (Table.cons c q (ω c q) t) hcons
      refine ⟨by rw [Dlg.run_ask]; exact h1, h2, ?_⟩
      intro e he
      rw [Dlg.trace_ask, List.mem_cons] at he
      rcases he with rfl | he
      · have hle : Table.cons c q (ω c q) t
            ≤ (Dlg.execM (pureOracle ω) (f (ω c q)) (Table.cons c q (ω c q) t)).2 :=
          execM_le _ _ _
        exact hle c q (ω c q) (lookup_cons_self t c q (ω c q))
      · exact h3 e he

/-- **…and hence the run's own world agrees with `ω` on everything the run
consulted.** `worldOf` of the final table is a total world, computed from the
log alone, that is indistinguishable from `ω` along the transcript — which is
what makes a per-run certificate possible at all.

Note what is *not* claimed: off the transcript the two worlds differ freely,
because `worldOf` defaults there, and `Inhabited Verdict` is `approve` — a cell
nobody asked about reads as approval. Every theorem here is therefore stated
*on* the transcript and never off it, and a consumer that wants a replay pinned
to the log must check that the log *covers* the transcript (`covered`, in
`demo/Main.lean`). Nothing puts a defaulted cell *into* a table: `Exec.oracle`
fails the run rather than recording an answer it could not read, so the only
defaults in sight are `worldOf`'s own, on cells no run ever touched. -/
theorem worldOf_execM_pure {A : Type} (ω : Ω) (p : Dlg A) (t : Table) (ht : Extends ω t) :
    ∀ e ∈ Dlg.trace ω p,
      worldOf (Dlg.execM (pureOracle ω) p t).2 e.c e.q = ω e.c e.q := by
  intro e he
  have h := (execM_pure ω p t ht).2.2 e he
  rw [worldOf, h, Option.getD_some, Dlg.mem_trace_answer ω p e he]

/-! ### The interpreter at a plan: `denote`, then `execM`

§5(i) of the kernel says commutation with the meaning is `rfl` *because the
interpreter is the fold*. It is `rfl` here because that is literally how the
following definition is written: there is no second traversal of the syntax. -/

/-- `[[Plan.execWith o p γ t]]` = interpret the plan by folding it into its
meaning and running the meaning. -/
def Plan.execWith {m : Type → Type} [Monad m] {Γ : Ctx} {A : Type}
    (o : Oracle m) (p : Plan Γ A) (γ : Env Γ) (t : Table) : m (A × Table) :=
  Dlg.execM o (denote p γ) t

/-- **§5(i), and it costs nothing.** The interpreter *is* `denote` followed by
the fold at the execution monad; the commutation is `rfl` because writing it any
other way is what would have made the theorem hard. -/
theorem Plan.execWith_eq_execM_denote {m : Type → Type} [Monad m] {Γ : Ctx} {A : Type}
    (o : Oracle m) (p : Plan Γ A) (γ : Env Γ) (t : Table) :
    Plan.execWith o p γ t = Dlg.execM o (denote p γ) t := rfl

/-- `[[Plan.execPure ω p γ]]` = **the interpreter with the `IO` taken out**: the
same fold, the same memo table, the same order of operations, with the answering
service replaced by the world `ω` itself.

This is the whole factorization written as a definition. `exec` and `execPure`
differ in one argument — the `Oracle` — and in nothing else, which is the
precise sense in which the `IO` layer is *only* the oracle function. The two
theorems below say what that buys: the value is the meaning, and the table is a
finite world agreeing with `ω` exactly where the run looked. -/
def Plan.execPure {Γ : Ctx} {A : Type} (ω : Ω) (p : Plan Γ A) (γ : Env Γ) :
    Table → A × Table :=
  Plan.execWith (pureOracle ω) p γ

/-- **The factorization, at a plan.** A closed plan interpreted against the
world `ω` returns exactly `Plan.run ω p Env.nil` — the value the plan *means* —
with no hypothesis, because the empty table is extended by every world.

`Plan.run ω p Env.nil` is by definition `Dlg.run ω (denote p Env.nil)`, so this
equation is literally *"exec with a pure oracle is `run ω ∘ denote`"*. -/
theorem Plan.execPure_fst {A : Type} (ω : Ω) (p : Plan [] A) :
    (Plan.execPure ω p Env.nil Table.nil).1 = Plan.run ω p Env.nil :=
  (execM_pure ω (denote p Env.nil) Table.nil (extends_nil ω)).1

/-- …and the table it leaves behind agrees with `ω` on exactly the plan's
transcript: `worldOf` of the run's own record is indistinguishable from the
world the run ran in, on every cell the run asked about. -/
theorem Plan.worldOf_execPure {A : Type} (ω : Ω) (p : Plan [] A) :
    ∀ e ∈ Plan.trace ω p Env.nil,
      worldOf (Plan.execPure ω p Env.nil Table.nil).2 e.c e.q = ω e.c e.q :=
  worldOf_execM_pure ω (denote p Env.nil) Table.nil (extends_nil ω)

/-- **Adequacy, at a plan.** For every oracle at `Id`, every world extending the
run's table assigns the plan the value the run returned. -/
theorem Plan.execWith_adequacy {A : Type} (o : Oracle Id) (p : Plan [] A) (ω : Ω)
    (h : Extends ω (Plan.execWith o p Env.nil Table.nil).2) :
    Plan.run ω p Env.nil = (Plan.execWith o p Env.nil Table.nil).1 :=
  (execM_adequacy o (denote p Env.nil) Table.nil).2 ω h

/-! ## The `IO` layer: rendering, the transport, and the answering service

From here down there are no theorems, and there should not be: these are
*definitions* that make bytes happen. The proof boundary is `Oracle IO` — swap
this section for any other `Oracle` and every theorem above still holds of the
same interpreter. -/

namespace Exec

open Agentic.Core.Acp

/-- How a code names itself in a prompt header. -/
def Code.name : Code → String
  | .text => "text"
  | .verdict => "verdict"
  | .flag => "flag"
  | .ack => "ack"

/-- How an addressee names itself in a prompt header. -/
def Addressee.render : Addressee → String
  | .model id => s!"model {id}"
  | .tool id => s!"tool {id}"
  | .person id => s!"person {id}"

/-- The model axis of a question's scope, if the author set one.
`Agentic.Scope.axis₁` at `QScope`; `LastOpt` is `Option`, and the innermost
setting has already won by the time the interpreter sees the question. -/
def modelAxis {c : Code} (q : Q c) : Option String := Agentic.Scope.axis₁ q.scope

/-- The mode axis of a question's scope, if the author set one. -/
def modeAxis {c : Code} (q : Q c) : Option String :=
  (q.scope : Agentic.LastOpt String × Agentic.LastOpt String).2

/-- What the addressee must say for `Decode` to read it. Sent with every
question, because the trusted base is narrow on purpose and an addressee cannot
be expected to guess it. -/
def answerSpec : Code → String
  | .text => "Reply with the text itself and nothing else."
  | .verdict =>
      "Reply with exactly APPROVE if you have no objection; " ++
      "otherwise reply with one objection per line and nothing else."
  | .flag => "Reply with exactly yes or no."
  | .ack => "Reply with ok."

/-- `[[renderQ c q]]` = the question as bytes on the wire: a header naming
everything that determines the reply, the answer format, then the words.

**Where the scope goes, and why.** A question's scope is two axes, and ACP v1
treats them differently:

* the **mode** axis is a protocol concept — `session/set_mode` — so
  `Exec.selectScope` sends it as a call and it is deliberately *absent* from
  the header when `Settings.useSessionMode` is on;
* the **model** axis is **not** a protocol concept: ACP v1 defines no
  `session/set_model` (see `Agentic/Core/Acp.lean`), and inventing an
  adapter-specific `session/set_config_option` here would be guessing. It
  therefore goes into the header, as an instruction the addressee can read.

That is the documented choice: *select via the protocol where the protocol says
how, otherwise say it in words*. The alternative — silently dropping a scope the
transport cannot express — would make `under (atModel m)` a no-op at runtime
while remaining meaningful in the semantics, and a scope operator that means
something to `denote` and nothing to the adapter is the worst of both.

`draw` is in the header whenever it is nonzero, because a resample is a
*different question* (§3 q1) and the addressee is entitled to know that it is
being asked again on purpose rather than by mistake. -/
def renderQ (c : Code) (q : Q c) (sentMode : Bool) : String :=
  let model := match modelAxis q with
    | some m => s!"model: {m}\n"
    | none => ""
  let mode := match modeAxis q with
    | some m => if sentMode then "" else s!"mode: {m}\n"
    | none => ""
  let draw := if q.draw = 0 then "" else s!"draw: {q.draw} (an independent re-draw)\n"
  s!"[question for {Addressee.render q.addressee}\n{model}{mode}{draw}\
     answer ({Code.name c}): {answerSpec c}]\n\n{q.prompt}"

/-- What to append when a reply could not be read, so the second attempt is not
a verbatim repeat of the first. -/
def nudge (c : Code) (reply : String) : String :=
  s!"\n\n[Your previous reply could not be read as a {Code.name c}: \
     {reply.trimAscii.toString}\n{answerSpec c}]"

/-- `[[Settings]]` = the policy an `IO` run needs and the semantics does not:
how many times to re-ask, whether a person is at a keyboard, whether the mode
axis goes over the protocol, and where warnings go.

The value represents *this runtime's choices*. Nothing here is visible to any
theorem: two runs with different `Settings` exhibit two worlds, and every result
in this file quantifies over all of them. -/
structure Settings where
  /-- How many times to re-ask after a reply the trusted base could not read.
  Only a `flag` can trigger this (`Decode_eq_none`). -/
  retries : Nat := 1
  /-- Route `Addressee.person` questions to this process's stdin instead of the
  adapter. Off by default, so an unattended run never blocks on a keyboard and
  the adapter's stub answers for the human. -/
  askPersonOnStdin : Bool := false
  /-- Send the scope's mode axis as `session/set_mode`. Off makes the mode a
  prompt header instead, for an adapter that does not implement the call. -/
  useSessionMode : Bool := true
  /-- Where a warning goes: a turn that ended oddly, a reply being re-asked.
  Warnings report what the run is *about* to do about something it noticed; they
  are never a substitute for doing it, which is why an answer that could not be
  read at all is an error and not a log line. -/
  log : String → IO Unit := fun msg => do (← IO.getStderr).putStrLn s!"agentic: {msg}"

/-- Put the question to the person at the keyboard. One line, because a
transport that needed a terminator would need a protocol, and this is a
convenience for supervised runs rather than an interface. -/
def askPersonStdin (who : String) (text : String) : IO String := do
  let out ← IO.getStdout
  out.putStrLn s!"\n--- question for {who} ---"
  out.putStrLn text
  out.putStr "> "
  out.flush
  let line ← (← IO.getStdin).getLine
  return line.trimAscii.toString

/-- Send the mode axis over the protocol, where the protocol has a call for it.
The model axis has none in ACP v1 and rides in the header instead; see
`renderQ`. Returns whether the mode was in fact sent, which is what keeps the
header and the protocol from saying it twice. -/
def selectScope (st : Settings) (conn : Conn) {c : Code} (q : Q c) : IO Bool := do
  match modeAxis q, st.useSessionMode with
  | some m, true => conn.setMode m; return true
  | _, _ => return false

/-- Put one question and return the bytes that came back — over the transport,
or to the keyboard when the addressee is a person and the runtime was told a
person is there.

**This is `askHuman`'s routing rule**, and it is one `match`: a
`Addressee.person` question goes to stdin when `Settings.askPersonOnStdin` is
set, and otherwise to the adapter, which is what makes an unattended run
possible (the stub answers for the human) without a second interpreter. -/
def say (st : Settings) (conn : Conn) (c : Code) (q : Q c) (sentMode : Bool)
    (extra : String) : IO String := do
  let text := renderQ c q sentMode ++ extra
  match q.addressee with
  | .person who =>
      if st.askPersonOnStdin then askPersonStdin who text else conn.prompt text
  | _ =>
      let turn ← conn.promptTurn text
      if turn.stopReason != "end_turn" then
        st.log s!"turn ended with stopReason '{turn.stopReason}' ({Code.name c}); \
                  the reply is being read as given"
      return turn.text

/-- `[[attempt st conn c q sentMode n extra]]` = ask, decode, and on a failure to
decode ask again — structurally, `n + 1` attempts in all.

`.ok a` is the answer the trusted base read. `.error reply` is the **last
unreadable reply, verbatim**: it is returned rather than discarded because it is
the only evidence the caller has of what was actually said, and the caller's job
is to report it, never to replace it with an answer of its own. -/
def attempt (st : Settings) (conn : Conn) (c : Code) (q : Q c) (sentMode : Bool) :
    Nat → String → IO (Except String (El c))
  | 0, extra => do
      let reply ← say st conn c q sentMode extra
      return match Decode c reply with
        | some a => .ok a
        | none => .error reply
  | n + 1, extra => do
      let reply ← say st conn c q sentMode extra
      match Decode c reply with
      | some a => return .ok a
      | none =>
          st.log s!"could not read a {Code.name c} from '{reply.trimAscii.toString}'; re-asking"
          attempt st conn c q sentMode n (nudge c reply)

/-- `[[Exec.oracle st conn]]` = the answering service that puts questions to a
live adapter: select the scope the protocol can express, render, prompt, decode,
re-ask on a decode failure, and — if every attempt was unreadable — **abandon the
run** with an `IO.userError` quoting the words that could not be read.

**Why exhaustion is an error and not a default** (`acat-qzl`, LOW #4, and the
repair of it). Every `El c` is inhabited, which is what makes total worlds exist
and `worldOf` definable, so `return default` typechecks here and was once
written here. It is wrong, and the reason is a fact about `Table`: an entry
carries a code, a question and an answer, and *nothing else*. A defaulted cell
is therefore definitionally identical to one an addressee gave — `Table.cons
.flag cq false t` is the same term whether the owner said "no" or said "banana"
— so every downstream check is blind to it. `certify` replays it, `covered`
finds it, the transcript prints `-> no` for a person who never said no, and a
logged warning on stderr is not a proposition anybody's proof reads. The
mitigation *cannot* be a check further down: the information needed to make the
check is destroyed at the moment of the `cons`.

So the invented answer is never made. What survives is the boundary as stated:
the run either has an answer somebody gave, or it has no run.

* Only `.flag` can fail to decode at all (`Decode_eq_none`), so this path is one
  code wide: `.verdict` is total, and *refusal is an answer* — an unreadable
  review reads as objections and never as approval.
* `Settings.retries` says how many times to re-ask first, and each failed
  attempt is logged with the words that failed, so the error is the end of a
  visible sequence rather than a surprise.
* The error names the code, the addressee, the attempt count, the prompt and the
  last reply — trimmed of surrounding whitespace and otherwise untouched —
  because that reply is the only record of what was said and it is about to be
  the only thing the operator has.

The cost is honest and worth naming: an abandoned run loses the table it had
built, since `StateT Table IO` drops its state on an exception. That is the
price of refusing to fabricate, and a caller who wants the partial log can catch
the error at the boundary it chooses.

Note what this function is *not*: it is not proved to do anything. It is an
`Oracle IO`, the argument the theorems above quantify over, and an adapter that
lies through it merely exhibits a different world. What is ruled out here is not
lying — no runtime can rule that out — but *this* runtime lying on the
addressee's behalf. -/
def oracle (st : Settings) (conn : Conn) : Oracle IO := fun c q _ => do
  let sentMode ← selectScope st conn q
  match ← attempt st conn c q sentMode st.retries "" with
  | .ok a => return a
  | .error reply =>
      throw <| IO.userError s!"no readable {Code.name c} from \
        {Addressee.render q.addressee} after {st.retries + 1} attempts; \
        last reply: '{reply.trimAscii.toString}' (prompt: '{q.prompt}'). \
        The run is abandoned: recording an answer nobody gave would be \
        indistinguishable, in the table, from one they did."

end Exec

/-! ## The entry points -/

/-- `[[exec st conn p]]` = the plan, run for real: the fold of
`Agentic/Core/Denote.lean` at the execution monad, with the live adapter as its
answering service.

One line, and every part of it is elsewhere: `denote` is the meaning,
`Dlg.execM` is the memoizing fold and its theorems, `Exec.oracle` is the trust
boundary. There is no fourth thing, which is the point of §5(i). -/
def exec {A : Type} (st : Exec.Settings) (conn : Acp.Conn) (p : Plan [] A) : OracleM A :=
  StateT.mk (Plan.execWith (Exec.oracle st conn) p Env.nil)

/-- The same, spelled out: the `IO` interpreter is the fold, and the oracle is
the only argument that is not. -/
theorem exec_eq {A : Type} (st : Exec.Settings) (conn : Acp.Conn) (p : Plan [] A)
    (t : Table) : exec st conn p t = Dlg.execM (Exec.oracle st conn) (denote p Env.nil) t :=
  rfl

/-- Run a closed plan against a fresh adapter and return the answer together
with the world the run constructed. The `Table` is the run's warrant: it is what
a certificate is checked against. -/
def execIO {A : Type} (st : Exec.Settings := {}) (cfg : Acp.Config := {})
    (p : Plan [] A) : IO (A × Table) :=
  Acp.withConn cfg fun conn => Plan.execWith (Exec.oracle st conn) p Env.nil Table.nil

end Agentic.Core
