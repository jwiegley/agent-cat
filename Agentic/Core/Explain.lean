import Agentic.Core.Dsl
import Agentic.Core.Report
import Mathlib.Data.Multiset.Sort

/-!
# What a checked program says about itself, before anybody runs it

The reporting layer of the analyses: two renderings, `Explain.planLines` and
`Explain.costLines`, that say what `Agentic/Core/Level.lean`,
`Agentic/Core/Cost.lean` and `Agentic/Core/Report.lean` already know about a
`Plan [] Unit`, and nothing else. `agent-cat plan` and `agent-cat cost` are these
two functions with a file read in front of them, and `Agentic/Core/Mcp.lean`'s
`workflow_check` is `Explain.costSummary` with a JSON encoder in front of it. One
fold, one set of numbers, three surfaces.

**Three things here are decisions rather than transcriptions.**

* **A rendering of the term is a rendering of the term.** `Plan.explain` walks the
  `Plan`, which is the object the theorems are about, and therefore shows what the
  term holds and *only* that: de Bruijn binders rather than the source's names, an
  unrolled `Plan.revising` rather than the `up to n revisions` that wrote it, and the arms of
  a `case` in the enumeration order of their `FinEnum` rather than by tag, because
  the tag type is quantified inside the constructor and no inhabitant of it is
  printable. Each of those three gaps is named in the legend the rendering prints;
  the third is pinned by `finEnum_toList_bool` and `finEnum_toList_vtag` below, so
  that a reader can tell which arm is which, and the second by
  `Dsl.RawBlock.revisionBounds`, which reads the numeral off the source where it
  is still there to read.

* **A prompt is a function, so it is shown at a probe.** An `ask` node's words are
  an `Expr Γ String`, i.e. `Env Γ → String`: there is no such thing as "the prompt
  of the node" until an environment is supplied. `Env.probe` supplies one whose
  answers are the *names of their own binders*, so the rendering shows the literal
  text of the term with `{#3}` exactly where the term splices the answer bound at
  `#3`. Applying the prompt to `default` instead — which is what `Cost.asks` does,
  for a different purpose — would print the same literals with the interpolations
  silently empty, i.e. a prompt the node does not have.

  What a probe cannot do is know which arm it is inside. A term may compute a value
  from a branch it has already taken — `Plan.revising`'s approved arm reads
  `(final δ).getD default`, which is the artefact exactly when the loop approved —
  and the probe, which approves nothing, shows the `default` there. That is the
  term's own computation at the probe's answers, and it is the same
  arm-independence that makes `Cost.costM` price an unreachable path; the legend
  `planLines` prints says so where a reader will meet it.

* **A bound that no world attains is printed as a bound.** `Cost.minFold` and
  `Cost.maxFold` are sound over every world (`Cost.minFold_le_bill`,
  `Cost.bill_le_maxFold`) and are *not* claimed to be attained: a `case` prices its
  arms independently while a world correlates them, and `Cost.minFold_not_attained`
  exhibits a tree whose minimum no world pays. So `costLines` prints the leaf bills
  as what they are — the bills the *tree* admits — and says so in the output. The
  one case in which it prints a number as a run's bill is `level p ≤ pipeline`,
  where the term fixes the whole sequence and the count is exact in every world
  (`Plan.length_trace_eq_askNodes` below). At the dynamic rung it prints the
  non-existence statement instead, because there is no number and a bound would be
  a false one.
-/

namespace Agentic.Core

/-! ## Naming a rung

`Agentic/Core/Level.lean` has the rungs and their order; a report has to print
them, and the word had better be one word per rung. -/

/-- `[[levelName ℓ]]` = the rung as the word a report and the MCP wire both
carry. -/
def levelName : Level → String
  | .batch => "batch"
  | .pipeline => "pipeline"
  | .branch => "branch"
  | .dynamic => "dynamic"

/-- **The word determines the rung**, so a reader who reads it back has lost
nothing. Four constructors and four words, decided rather than asserted. -/
theorem levelName_injective : Function.Injective levelName := by decide

/-- `[[sayNat? n]]` = an optional number, for a reader: the number, or a dash
where the analysis admits none. -/
def sayNat? : Option Nat → String
  | some n => toString n
  | none => "—"

/-! ## The arm order a rendering has to rely on

A `Plan.case` node carries its tag type inside the constructor, so a renderer that
walks the term can print *how many* arms there are and the order they are
enumerated in, and cannot print the tags themselves. These two equations are what
make that order readable: the two branchings the DSL writes are `Bool` and `VTag`,
and each enumerates the way the source text reads. -/

/-- The arms of a flag branching, in `FinEnum` order: the `false` arm first.
`Plan.caseB t f` is `cond`, so that is the `else` block of `if x { … } else
{ … }`. -/
theorem finEnum_toList_bool : FinEnum.toList (Tag.El .bool) = [false, true] := by decide

/-- …and of a verdict branching: `approve`, `object`, `declined`, which is the
order `case v { approve … object … declined … }` writes them in. -/
theorem finEnum_toList_vtag :
    FinEnum.toList (Tag.El .vtag) = [VTag.approve, .object, .declined] := by decide

/-! ## Probe environments: showing a prompt where its answers go -/

/-- `[[probeAnswer c n]]` = an answer of kind `c` that says nothing except which
binder it came from.

`{#n}` at `.text`, because that is the only kind that interpolates into a prompt;
one objection reading `{#n}` at `.verdict`, because `Verdict.render` — the
renderer the DSL's `revise given patch, why` binder is bound to — sends that to
exactly that string; and the `Inhabited` default at the two kinds no prompt can
mention. -/
def probeAnswer : (c : Code) → Nat → El c
  | .text, n => "{#" ++ toString n ++ "}"
  | .verdict, n => Verdict.object ["{#" ++ toString n ++ "}"]
  | .flag, _ => default
  | .ack, _ => default

/-- `[[Env.probe Γ]]` = the environment in which every answer is the name of its
own binder, counted from the root: in a context of length `d`, de Bruijn index `i`
answers `{#(d-1-i)}`.

Absolute rather than de Bruijn numbering on purpose. The index of a binder changes
with the depth at which it is read, and a reader matching a prompt against the
node that bound it should not have to do that arithmetic; the binder's distance
from the root does not change, so `binds #3` and `{#3}` are the same `3`
everywhere in a rendering. -/
def Env.probe : (Γ : Ctx) → Env Γ
  | [] => .nil
  | c :: Γ => Env.cons (probeAnswer c Γ.length) (Env.probe Γ)

/-! ## Two folds a rendering needs -/

/-- The node count, as an algebra. `Plan.size` just below is its fold: how many
nodes the term has, a `dyn` counting as one.

A `dyn` node's continuations are indexed by an answer, of which there are
unboundedly many, so "the number of nodes below it" is not a number — the same
fact as `Cost.no_finite_bill_set_at_dyn`, counted instead of priced. Every other
former's subterms are in the term, and a `case`'s arms are summed over its finite
tag type. -/
def Plan.sizeAlg : PlanAlg (fun _ _ => Nat) where
  ret _ := 1
  askC _ _ n := 1 + n
  ask _ _ _ n := 1 + n
  case := fun t _ arms =>
    1 + (FinEnum.toList t.El).foldl (fun acc x => acc + arms x) 0
  dyn _ _ _ := 1

/-- `[[Plan.size p]]` = how many nodes the term has, a `dyn` counting as one.
`Plan.sizeAlg.fold`. -/
def Plan.size : {Γ : Ctx} → {A : Type} → Plan Γ A → Nat :=
  fun p => Plan.sizeAlg.fold p

/-! ### The five defining equations of `Plan.size`, each a `rfl` -/

namespace Plan

theorem size_ret {Γ : Ctx} {A : Type} (e : Expr Γ A) : Plan.size (Plan.ret e) = 1 := rfl

theorem size_askC {Γ : Ctx} {A : Type} (c : Code) (q : Q c) (k : Plan (c :: Γ) A) :
    Plan.size (Plan.askC c q k) = 1 + Plan.size k := rfl

theorem size_ask {Γ : Ctx} {A : Type} (c : Code) (s : Q.Shape c) (e : Expr Γ String)
    (k : Plan (c :: Γ) A) : Plan.size (Plan.ask c s e k) = 1 + Plan.size k := rfl

theorem size_case {Γ : Ctx} {A : Type} (t : Tag) (e : Expr Γ t.El) (arms : t.El → Plan Γ A) :
    Plan.size (Plan.case t e arms)
      = 1 + (FinEnum.toList t.El).foldl (fun acc x => acc + Plan.size (arms x)) 0 := rfl

theorem size_dyn {Γ : Ctx} {A : Type} (b : Code) (e : Expr Γ (El b)) (f : El b → Plan Γ A) :
    Plan.size (Plan.dyn b e f) = 1 := rfl

end Plan

/-- The consultation count, as an algebra. `Plan.askNodes` just below is its
fold: how many consultations are *written* in the term, both arms of every
branching counted.

Not a bill: a run pays for the questions on the path it takes, and that is what
`Cost.costM`'s bag counts. This is the other number — how many questions the
author wrote — and the two coincide exactly where there is no branching, which is
`Plan.length_trace_eq_askNodes` below. -/
def Plan.askNodesAlg : PlanAlg (fun _ _ => Nat) where
  ret _ := 0
  askC _ _ n := 1 + n
  ask _ _ _ n := 1 + n
  case := fun t _ arms =>
    (FinEnum.toList t.El).foldl (fun acc x => acc + arms x) 0
  dyn _ _ _ := 0

/-- `[[Plan.askNodes p]]` = how many consultations are written in the term.
`Plan.askNodesAlg.fold`. -/
def Plan.askNodes : {Γ : Ctx} → {A : Type} → Plan Γ A → Nat :=
  fun p => Plan.askNodesAlg.fold p

/-! ### The five defining equations of `Plan.askNodes`, each a `rfl` -/

namespace Plan

theorem askNodes_ret {Γ : Ctx} {A : Type} (e : Expr Γ A) : Plan.askNodes (Plan.ret e) = 0 := rfl

theorem askNodes_askC {Γ : Ctx} {A : Type} (c : Code) (q : Q c) (k : Plan (c :: Γ) A) :
    Plan.askNodes (Plan.askC c q k) = 1 + Plan.askNodes k := rfl

theorem askNodes_ask {Γ : Ctx} {A : Type} (c : Code) (s : Q.Shape c) (e : Expr Γ String)
    (k : Plan (c :: Γ) A) : Plan.askNodes (Plan.ask c s e k) = 1 + Plan.askNodes k := rfl

theorem askNodes_case {Γ : Ctx} {A : Type} (t : Tag) (e : Expr Γ t.El)
    (arms : t.El → Plan Γ A) :
    Plan.askNodes (Plan.case t e arms)
      = (FinEnum.toList t.El).foldl (fun acc x => acc + Plan.askNodes (arms x)) 0 := rfl

theorem askNodes_dyn {Γ : Ctx} {A : Type} (b : Code) (e : Expr Γ (El b))
    (f : El b → Plan Γ A) : Plan.askNodes (Plan.dyn b e f) = 0 := rfl

end Plan

/-- **At or below `pipeline`, the questions written are the questions asked** —
in every world, with no hypothesis on the price.

This is the theorem behind the one number `Explain.costLines` prints as a bill
rather than as a bound: below the branch rung there is nothing to branch on, so
the transcript of *any* world is as long as the term is wide.
`Cost.length_trace_eq_of_le_pipeline` says the length is world-independent; this
says what the length is. -/
theorem Plan.length_trace_eq_askNodes {Γ : Ctx} {A : Type} (p : Plan Γ A)
    (h : level p ≤ Level.pipeline) :
    ∀ (γ : Env Γ) (ω : Ω), (Plan.trace ω p γ).length = p.askNodes := by
  induction p with
  | ret e => intro γ ω; simp [Plan.trace, Plan.askNodes_ret]
  | askC c q k ih =>
    intro γ ω
    rw [Plan.trace_askC, List.length_cons, ih h (.cons (ω c q) γ) ω, Plan.askNodes_askC]
    omega
  | ask c s e k ih =>
    intro γ ω
    rw [Plan.trace_ask, List.length_cons, ih (le_of_ask h).2 _ ω, Plan.askNodes_ask]
    omega
  | case t e arms _ => exact absurd (le_of_case h).1 (by decide)
  | dyn b e f _ => exact absurd h (by simp only [level_dyn]; decide)

/-- **…and the term is one node wider than it is deep.** The two folds differ by
the leaf, which is the sense in which `askNodes` counts questions and `size`
counts syntax. -/
theorem Plan.size_eq_askNodes_succ {Γ : Ctx} {A : Type} (p : Plan Γ A)
    (h : level p ≤ Level.pipeline) : p.size = p.askNodes + 1 := by
  induction p with
  | ret e => rfl
  | askC c q k ih => rw [Plan.size_askC, Plan.askNodes_askC, ih h]; omega
  | ask c s e k ih => rw [Plan.size_ask, Plan.askNodes_ask, ih (le_of_ask h).2]; omega
  | case t e arms _ => exact absurd (le_of_case h).1 (by decide)
  | dyn b e f _ => exact absurd h (by simp only [level_dyn]; decide)

namespace Explain

/-! ## Presentation -/

/-- `[[indent d]]` = the left margin at depth `d`. -/
def indent (d : Nat) : String := "".pushn ' ' (2 * d)

/-- `[[quoted d s]]` = a prompt under its node, one source line per output line,
so that a prompt with newlines in it reads as its addressee will read it. -/
def quoted (d : Nat) (s : String) : List String :=
  (s.splitOn "\n").map fun l => s!"{indent d}| {l}"

/-- `[[shapeLine c s]]` = the part of a question that is written in the term: its
kind, its addressee, its two scope axes and its draw.

`Q.axes` reads the axes off a *question*, and a shape is a question with its words
forgotten (`Q.withPrompt_shape`), so asking a shape for its own axes is asking the
question with the empty prompt — the move `Mcp.shapeJson` makes for the same
reason. -/
def shapeLine (c : Code) (s : Q.Shape c) : String :=
  let q := s.withPrompt ""
  s!"{pad 8 (Exec.Code.name c)}{pad 24 (Exec.Addressee.render s.addressee)}\
     {pad 22 (Q.axes q)}draw={s.draw}"

end Explain

/-- The rendering, as an algebra, at the carrier `P Γ A = Nat → List String` —
the depth is the accumulator, and the `case` clause is the only one that moves
it. `Plan.explain` just below is its fold.

A rendering of the **representation**: every line is read off the `Plan`
constructor it names, and nothing is recovered from the source text, which the
term does not contain. -/
def Plan.explainAlg : PlanAlg (fun _ _ => Nat → List String) where
  ret _ := fun d => [s!"{Explain.indent d}ret     (a leaf: the block is over)"]
  askC := fun {Γ} {_} c q k => fun d =>
      (s!"{Explain.indent d}askC    {Explain.shapeLine c q.shape}  binds #{Γ.length}"
        :: Explain.quoted (d + 1) q.prompt) ++ k d
  ask := fun {Γ} {_} c s e k => fun d =>
      (s!"{Explain.indent d}ask     {Explain.shapeLine c s}  binds #{Γ.length}"
        :: Explain.quoted (d + 1) (e (Env.probe Γ))) ++ k d
  case := fun t _ arms => fun d =>
      let ts := FinEnum.toList t.El
      s!"{Explain.indent d}case    {ts.length} arms, in the enumeration order of the tag type \
         the term carries"
        :: (ts.zipIdx.flatMap fun ti =>
              s!"{Explain.indent (d + 1)}arm {ti.2}:" :: arms ti.1 (d + 2))
  dyn _ _ _ := fun d =>
      [ s!"{Explain.indent d}dyn     a plan computed from an answer: its continuations are \
           indexed by an unbounded answer, so there is no finite term below this line. This is \
           the dynamic rung, and no source text reaches it (Dsl.parseAndCheck_level_le)." ]

/-- `[[Plan.explain d p]]` = the term at depth `d`, as lines.
`Plan.explainAlg.fold`. -/
def Plan.explain : {Γ : Ctx} → {A : Type} → Nat → Plan Γ A → List String :=
  fun d p => Plan.explainAlg.fold p d

/-! ### The five defining equations of `Plan.explain`, each a `rfl` -/

namespace Plan

theorem explain_ret {Γ : Ctx} {A : Type} (d : Nat) (e : Expr Γ A) :
    Plan.explain d (Plan.ret e)
      = [s!"{Explain.indent d}ret     (a leaf: the block is over)"] := rfl

theorem explain_askC {Γ : Ctx} {A : Type} (d : Nat) (c : Code) (q : Q c)
    (k : Plan (c :: Γ) A) :
    Plan.explain d (Plan.askC c q k)
      = (s!"{Explain.indent d}askC    {Explain.shapeLine c q.shape}  binds #{Γ.length}"
          :: Explain.quoted (d + 1) q.prompt) ++ Plan.explain d k := rfl

theorem explain_ask {Γ : Ctx} {A : Type} (d : Nat) (c : Code) (s : Q.Shape c)
    (e : Expr Γ String) (k : Plan (c :: Γ) A) :
    Plan.explain d (Plan.ask c s e k)
      = (s!"{Explain.indent d}ask     {Explain.shapeLine c s}  binds #{Γ.length}"
          :: Explain.quoted (d + 1) (e (Env.probe Γ))) ++ Plan.explain d k := rfl

theorem explain_case {Γ : Ctx} {A : Type}
    (d : Nat) (t : Tag) (e : Expr Γ t.El) (arms : t.El → Plan Γ A) :
    Plan.explain d (Plan.case t e arms)
      = (let ts := FinEnum.toList t.El
         s!"{Explain.indent d}case    {ts.length} arms, in the enumeration order of the tag \
            type the term carries"
           :: (ts.zipIdx.flatMap fun ti =>
                 s!"{Explain.indent (d + 1)}arm {ti.2}:" :: Plan.explain (d + 2) (arms ti.1))) :=
  rfl

theorem explain_dyn {Γ : Ctx} {A : Type} (d : Nat) (b : Code) (e : Expr Γ (El b))
    (f : El b → Plan Γ A) :
    Plan.explain d (Plan.dyn b e f)
      = [ s!"{Explain.indent d}dyn     a plan computed from an answer: its continuations are \
             indexed by an unbounded answer, so there is no finite term below this line. This \
             is the dynamic rung, and no source text reaches it \
             (Dsl.parseAndCheck_level_le)." ] := rfl

end Plan

/-! ## The front end, with the source syntax kept

`Dsl.parseAndCheckE` reads a text and returns the plan. A tool that also wants to
say something about what was *written* — and the one thing the term does not hold
is the `up to n revisions` of a bounded revision — needs the raw syntax as well,
and must not get it by parsing twice. -/

namespace Dsl

/-- `[[parseAndCheckRawProgramWith ov mods s]]` = the front end, keeping the
raw syntax of the block it ran: the same parse — imports resolved from `mods`,
functions checked into the table — the same check, the same diagnosis. The raw
kept is the *spliced main block*, because that is the one whose source-level
facts (the `at most n amendments` bounds) a rendering wants; a function body
cannot hold a bounded revision, so nothing is lost to the table.

`parseAndCheckRawProgramWith_eq` is the statement that this is not a second
front end. -/
def parseAndCheckRawProgramWith (ov : List (String × Prompt))
    (mods : List (String × String)) (s : String) :
    Except CheckError (Raw × Plan [] Unit) :=
  match parseProgramWith ov mods s with
  | .error e => .error e
  | .ok prog =>
    match checkProgram prog with
    | .error e => .error e
    | .ok p => .ok (prog.main, p)

/-- The moduleless spelling: a single file, keeping its raw syntax. -/
def parseAndCheckRawWith (ov : List (String × Prompt)) (s : String) :
    Except CheckError (Raw × Plan [] Unit) :=
  parseAndCheckRawProgramWith ov [] s

/-- The front end with no runtime parameters, which is the front end: `parse` is
`parseWith []` (`Dsl.parse_eq_parseWith_nil`), so this is not a second reading
of a program but the same one with an empty list of overrides. -/
def parseAndCheckRaw (s : String) : Except CheckError (Raw × Plan [] Unit) :=
  parseAndCheckRawWith [] s

/-- **A program loaded with no overrides is the program.** The obligation
`--define` carries: the default path must produce the identical term, so that
every theorem proved about `parse`'s output is a theorem about what the command
line actually ran. -/
theorem parseAndCheckRaw_eq_with_nil (s : String) :
    parseAndCheckRaw s = parseAndCheckRawWith [] s := rfl

/-- **One front end.** Forgetting the raw syntax gives
`Dsl.parseAndCheckProgramWith` back on the nose — the same plan on success and
the same `CheckError` on failure — so a tool built on this one diagnoses what a
tool built on that one diagnoses. This is the parity of `agent-cat
run|cost|plan` discharged by construction rather than by three call sites
agreeing. -/
theorem parseAndCheckRawProgramWith_eq (ov : List (String × Prompt))
    (mods : List (String × String)) (s : String) :
    (parseAndCheckRawProgramWith ov mods s).map Prod.snd
      = parseAndCheckProgramWith ov mods s := by
  cases hp : parseProgramWith ov mods s with
  | error e =>
    simp [parseAndCheckRawProgramWith, parseAndCheckProgramWith, Except.map, hp]
  | ok prog =>
    cases hc : checkProgram prog with
    | error e =>
      simp [parseAndCheckRawProgramWith, parseAndCheckProgramWith, Except.map, hp, hc]
    | ok p =>
      simp [parseAndCheckRawProgramWith, parseAndCheckProgramWith, Except.map, hp, hc]

/-- …and hence every program the *overriding, importing* front end accepts is
at or below the branch rung too: forgetting the raw syntax lands in
`Dsl.parseAndCheckProgramWith`, whose bound is `Dsl.checkProgram_level_le`'s. -/
theorem parseAndCheckRawProgramWith_level_le (ov : List (String × Prompt))
    (mods : List (String × String)) (s : String)
    (r : Raw) (p : Plan [] Unit)
    (h : parseAndCheckRawProgramWith ov mods s = .ok (r, p)) :
    level p ≤ Level.branch := by
  refine parseAndCheckProgramWith_level_le ov mods s p ?_
  rw [← parseAndCheckRawProgramWith_eq, h]
  rfl

/-- The moduleless spelling of the bound, which is what a single-file tool
holds. -/
theorem parseAndCheckRawWith_level_le (ov : List (String × Prompt)) (s : String)
    (r : Raw) (p : Plan [] Unit) (h : parseAndCheckRawWith ov s = .ok (r, p)) :
    level p ≤ Level.branch :=
  parseAndCheckRawProgramWith_level_le ov [] s r p h

/-- …and the moduleless, overrideless spelling of the parity, stated against
`parseAndCheckE`, which is `parseAndCheckProgramWith [] []` by definition. -/
theorem parseAndCheckRaw_eq (s : String) :
    (parseAndCheckRaw s).map Prod.snd = parseAndCheckE s :=
  parseAndCheckRawProgramWith_eq [] [] s

/-- …and hence every program this front end accepts is at or below the branch
rung, which is what makes a cost report over a source file compile
(`Dsl.parseAndCheck_level_le`). -/
theorem parseAndCheckRaw_level_le (s : String) (r : Raw) (p : Plan [] Unit)
    (h : parseAndCheckRaw s = .ok (r, p)) : level p ≤ Level.branch := by
  refine parseAndCheck_level_le s p ((parseAndCheck_ok_iff s p).mpr ?_)
  rw [← parseAndCheckRaw_eq, h]
  rfl

/-! ### The one thing the term does not hold -/

/-- **The draw index reaches the question** — for every ask the surface can
write, not just the battery's `independent draw 2` fixture: whatever plan a
binding's ask elaborates to, the first event of any run of it carries the
source-written draw. Stated here rather than in `Dsl.lean` because it speaks
of `Plan.trace`. -/
theorem bindForm_ask_head_draw {A : Type} {Γ : Ctx} (fns : Fns) (c : Code)
    (S : Bindings Γ) (a : RawAsk) (form : Plan (c :: Γ) A → Plan Γ A)
    (h : bindForm fns c S (.ask a) = .ok form)
    (k : Plan (c :: Γ) A) (ω : Ω) (γ : Env Γ) :
    ((Plan.trace ω (form k) γ).head?).map (fun e => e.q.draw)
      = some a.target.draw := by
  simp only [bindForm] at h
  cases hg : askGuard a with
  | error e => rw [hg] at h; exact absurd h (by simp)
  | ok u =>
    rw [hg] at h
    cases hc : Prompt.closed a.prompt with
    | none =>
      rw [hc] at h
      cases he : Prompt.expr S a.pos a.prompt with
      | error e => rw [he] at h; exact absurd h (by simp)
      | ok e => rw [he] at h; cases h; simp [askShape_draw]
    | some w => rw [hc] at h; cases h; simp [askShape_draw]

/-- `[[b.revisionBounds]]` = every `revising … at most n amendments` written in
`b`, with where it is written.

First-order in the syntax: a `RawRhs` has no block inside it, so the recursion
is `RawBlock`'s own, with one step into a binding's source. The bound printed
is one the checker allowed, because `checkBlock` refuses any numeral above
`maxRevisions` before it elaborates anything. -/
def RawBlock.revisionBounds : RawBlock → List (Pos × Nat)
  | .empty _ => []
  | .knownHere _ rest _ => rest.revisionBounds
  | .act _ rest _ => rest.revisionBounds
  | .callStmt _ _ rest _ => rest.revisionBounds
  | .bind _ _ (.rhs _) rest _ => rest.revisionBounds
  | .bind _ _ (.revising _ _ n _ _ _ _ rpos) rest _ => (rpos, n) :: rest.revisionBounds
  | .ifFlag _ y n _ => y.revisionBounds ++ n.revisionBounds
  | .caseVerdict _ a o d _ => a.revisionBounds ++ o.revisionBounds ++ d.revisionBounds
  | .caseResult _ _ s u _ => s.revisionBounds ++ u.revisionBounds

end Dsl

namespace Explain

/-! ## The two reports -/

/-- `[[planLines p]]` = the checked term, with the header a reader needs in order
to know what they are looking at: that it is the representation, how big it is,
and what rung it sits at. -/
def planLines {A : Type} (p : Plan [] A) : List String :=
  [ "--- the checked term, as the library holds it: a rendering of the REPRESENTATION \
     (Plan [] Unit) and not of the source text ---"
  , s!"nodes: {p.size}   consultations written: {p.askNodes}   level: {levelName (level p)}"
  , "legend: `binds #d` is the binder a question introduces, named by its distance from the \
     root, and `{#d}` inside a prompt is where the term splices that answer;"
  , "        `askC` carries its words in the term (a closed question, the batch rung), `ask` \
     computes them from the answers in scope (the pipeline rung);"
  , "        a `case` prints its arms in the enumeration order of its tag type — the `else` \
     arm then the `if` arm for a flag, `approved` then `objected` then `no answer` for a \
     verdict;"
  , "        a bounded revision is not a node: `Plan.revising` is `Nat.rec`, so the term holds \
     its unrolling and the `at most n amendments` that wrote it is a fact about the source;"
  , "        a prompt is shown at a probe environment, which does not know which arm it is \
     inside — an empty splice under an approved arm is `Plan.revising`'s own \
     `(final δ).getD default` at a probe that did not approve, and not a prompt a run puts." ]
    ++ Plan.explain 1 p

/-- `[[revisionLines b]]` = the `revising … at most n amendments` bounds the
*source* writes, with what each one buys.

Printed beside a plan rendering, and labelled as coming from the source, because
the term cannot hold it: by the time there is a plan the numeral has become the
unrolling. `at most n amendments` buys between one and `n+1` reviews — the loop
reviews first, and stops the moment a review approves — and at most `n`
amendments. -/
def revisionLines (b : Dsl.Raw) : List String :=
  match b.revisionBounds with
  | [] => []
  | bs =>
    "--- bounded revisions, read off the SOURCE text (the term holds the unrolling) ---"
      :: bs.map fun pn =>
        s!"  line {pn.1.line}, col {pn.1.col}: at most {pn.2} amendments → between 1 and \
           {pn.2 + 1} reviews, at most {pn.2} amendments, written out into the term"

/-- `[[costSummary p h]]` = the cheapest bill, the dearest bill and the number of
paths, from `Cost.costM`.

`h : level p ≤ Level.branch` is the argument `costM` demands, which is why
`Dsl.parseAndCheck_level_le` is the term every tool over source files is built on.
The folds are `Cost.minFold` and `Cost.maxFold` at `tick`, so the numbers
are consultations — and they are **bounds**: `Cost.minFold_not_attained` exhibits a
plan whose `minFold` no world pays.

`paths` is `Multiset.card`, so it counts paths *with multiplicity*: two arms that
cost the same are two paths, which is what a reader of `leafBills` below is
being shown. -/
def costSummary {A : Type} (p : Plan [] A) (h : level p ≤ Level.branch) :
    Option Nat × Option Nat × Nat :=
  let τ := costM tick p h Env.nil
  ( (minFold τ).recTopCoe none (fun s => some (Multiplicative.toAdd s))
  , (maxFold τ).recBotCoe none (fun s => some (Multiplicative.toAdd s))
  , Multiset.card τ )

/-- `[[leafBills p h]]` = the bill at every path of the cost analysis, with
repetitions: `costM`'s bag read through `Multiplicative ℕ ≅ ℕ`
(`Report.billNat`'s isomorphism) and sorted, because a multiset has no order of
its own to report.

What this list is *not* is the set of bills a run can produce; see `costLines` for
what is printed about that, and `Cost.minFold_not_attained` for why the
distinction is not pedantry. -/
def leafBills {A : Type} (p : Plan [] A) (h : level p ≤ Level.branch) : List Nat :=
  Multiset.sort ((costM tick p h Env.nil).map fun s => Multiplicative.toAdd s)
    (· ≤ ·)

/-- `[[sayNats l]]` = a list of numbers, as a set is written. -/
def sayNats (l : List Nat) : String := "{" ++ String.intercalate ", " (l.map toString) ++ "}"

/-- The sequence of question shapes, where the term fixes it, and the statement
that it does not where it does not. -/
def shapeLines {A : Type} (p : Plan [] A) : List String :=
  match shapes p with
  | some l =>
    s!"shape sequence: the term fixes all {l.length} of them \
       (Cost.shapes_eq_of_le_pipeline), world or no world:"
      :: l.map fun s => s!"  {shapeLine s.1 s.2}"
  | none =>
    [ "shape sequence: NOT fixed by the term (`Cost.shapes` is `none` at a `case`) — this \
       program branches, and the cost tree below is what stands in its place." ]

/-- `[[costLines p]]` = what can be said about what a program costs without running
it, and — where a number would not be true — what cannot be.

Three regimes, and the output says which one it is in.

* `level ≤ pipeline`: the term fixes the sequence, so the bill is one number and
  **every** world pays it (`Plan.length_trace_eq_askNodes`). That is the only case
  in which a number is printed as achievable.
* `pipeline < level ≤ branch`: the cost tree is finite and every run's bill is one
  of its leaves (`Cost.bill_mem_leaves`), so the extremes bound every world
  (`Cost.minFold_le_bill`, `Cost.bill_le_maxFold`). The leaves are printed as
  bounds, with the reason a leaf need not be a run.
* `level = dynamic`: there is no cost tree of any shape and no finite set of bills
  at all (`Cost.no_finite_bill_set_at_dyn`, `Cost.no_cost_tree_at_dyn`), so the
  non-existence statement is printed where a number would go. Unreachable from a
  source file — `Dsl.parseAndCheck_level_le` says the language cannot write a
  `dyn` — and written out because this function is defined on plans, not on
  files. -/
def costLines {A : Type} (p : Plan [] A) : List String :=
  let hdr :=
    [ s!"level: {levelName (level p)}   consultations written in the term: {p.askNodes}   \
         nodes: {p.size}" ]
  if h : level p ≤ Level.branch then
    let (lo, hi, paths) := costSummary p h
    let bills := leafBills p h
    let attainment : List String :=
      if level p ≤ Level.pipeline then
        [ s!"attained: exactly {p.askNodes} consultations, in every world — at or below the \
             `pipeline` rung the term fixes the question sequence, so this is a bill and not a \
             bound (Plan.length_trace_eq_askNodes, Cost.length_trace_eq_of_le_pipeline)." ]
      else
        [ "attained: NOT computed, and not computable from the term alone. The numbers above \
           are what the TREE admits, one per path, and a path is not a world: a `case` prices \
           its arms independently while a world correlates them, so a leaf need not be the \
           bill of any run (Cost.minFold_not_attained exhibits a tree whose minimum no world \
           pays). Read the cheapest above as a lower bound that may be unattained."
        , "what holds of every world: its bill is one of the leaves (Cost.bill_mem_leaves), \
           hence at least the cheapest and at most the dearest (Cost.minFold_le_bill, \
           Cost.bill_le_maxFold); and the cheapest and dearest bills that are actually run up \
           are attained by worlds (Cost.exists_min_bill, Cost.exists_max_bill) — which are in \
           general two other numbers, and which a reachability analysis this package does not \
           do would be needed to name." ]
    hdr
      ++ shapeLines p
      ++ [ s!"cost tree: {paths} leaves, cheapest {sayNat? lo}, dearest {sayNat? hi} \
              consultations (tick: one unit per consultation)"
         , s!"leaf bills, with multiplicity: {sayNats bills}"
         , s!"leaf bills, as a set:          {sayNats bills.dedup}" ]
      ++ attainment
  else
    hdr
      ++ [ "no cost report exists at this rung, and that is a theorem rather than a limitation \
            of this tool: a `dyn` plan is exhibited whose bills lie in NO finite set \
            (Cost.no_finite_bill_set_at_dyn), hence for which no cost tree of any shape exists \
            (Cost.no_cost_tree_at_dyn) and no static bill is definable \
            (Cost.no_static_bill_at_dyn)."
         , "nothing is printed in place of a number, because there is no number and a bound \
            would be a false one." ]

end Explain


end Agentic.Core
