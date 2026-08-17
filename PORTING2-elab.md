# PORTING2-elab.md — the week-two elaboration spec: `Agentic.Builder` and the rebuilt cases

Companion to `PORTING.md` (week one: `Agentic.Raw`, `Agentic.Text`,
`Agentic.Guards`, tier0). This file owns

* `src/Agentic/Builder.hs` — the production surface: typed combinators that
  carry the author's names and enough `Agentic.Raw` data to print a
  `RawProgram`, and that **elaborate to the same `Plan` the Lean checker
  elaborates the corresponding surface construct to**;
* `tier1/Main.hs` + `tier1/Cases.hs` — the rebuilt-case discipline and the
  twelve cases to rebuild.

The sibling spec (`PORTING2-core.md`) owns `src/Agentic/Plan.hs` (the GADT, the
folds) and `src/Agentic/World.hs` (`WorldSpec`, `trace`, the bills, `eventJson`).
**§0.2 below lists, by name and signature, everything `Builder.hs` consumes from
those two modules.** That list is a contract between the two specs; if the
core spec spells a name differently, the core spec wins and only the names in
§0.2 change here — no shape in §0.2 is negotiable, because every one of them is
pinned to a Lean definition quoted in §1.

**What week two is not.** No Haskell parser, no Haskell typing judgment. The
builder gets well-formedness from Haskell's own types: `checkBlock`'s refusals
(`unbound`, `freshName`, `at?`, `argExpr`'s kind mismatch, `bindKind`'s "nothing
fixes the kind") are type errors in the builder, not runtime `Either`s. What is
ported is the **elaboration rule** at each construct — which `Plan` nodes get
built, in what order, with what `Expr` splices — because that is what makes
traces and folds comparable to the frozen corpus.

---

## 0 Sources of truth, and the interface to the core spec

### 0.1 Lean files

| what | file |
|---|---|
| the target syntax (five formers, `Expr`/`Env`/`Var`/`Sub`, `graft`, `Cont`, `panel`, `revising`, `caseB`, `caseV`, `VTag`) | `Agentic/Core/Plan.lean` |
| the elaboration | `Agentic/Core/Dsl/Check.lean` |
| the source syntax it consumes | `Agentic/Core/Dsl/Syntax.lean` |
| `Q`, `Q.Shape`, `withPrompt`, `Addressee`, `QScope`, `Sig`, `atModel`, `Code`, `El` | `Agentic/Core/Question.lean` |
| `denote`, `Plan.trace` | `Agentic/Core/Denote.lean` |
| `billFresh` (:166), `billMemo` (:176) | `Agentic/Core/Cost.lean` |
| the reply JSON tier1 reproduces | `conformance/Conformance.lean` |
| the surface sources of the rebuilt cases | `test/DslCases.lean`, `test/CorpusGen.lean` |

All paths are relative to `/Users/johnw/src/agent-cat`. Never write there.

### 0.2 What `Builder.hs` imports from `Agentic.Plan` / `Agentic.World`

```haskell
-- Agentic.Plan
type family El (c :: Code) :: Type          -- text→Text, verdict→Verdict, flag→Bool, ack→()
data Env (g :: [Code]) where                -- ECons's tail is LAZY: Lean's Env.consBy
  ENil  :: Env '[]
  ECons :: El c -> Env g -> Env (c ': g)
data Var (g :: [Code]) (c :: Code) where
  VZ :: Var (c ': g) c
  VS :: Var g c -> Var (c' ': g) c
varGet   :: Var g c -> Env g -> El c
type Expr (g :: [Code]) a = Env g -> a
type Sub  (g :: [Code]) (d :: [Code]) = Env d -> Env g
wkSub    :: Sub g (c ': g)                                  -- Env.tail
liftSub  :: Sub g d -> Sub (c ': g) (c ': d)
idSub    :: Sub g g
data Plan (g :: [Code]) a where
  PRet  :: Expr g a -> Plan g a
  PAskC :: SCode c -> Q c -> Plan (c ': g) a -> Plan g a
  PAsk  :: SCode c -> Shape c -> Expr g Text -> Plan (c ': g) a -> Plan g a
  PCase :: (FinEnum t, Eq t) => Expr g t -> (t -> Plan g a) -> Plan g a
  PDyn  :: Expr g b -> (b -> Plan g a) -> Plan g a
subPlan :: Plan g a -> Sub g d -> Plan d a
type Cont g a b = forall d. Sub g d -> Expr d a -> Plan d b   -- RankNTypes
graft   :: Plan g a -> Cont g a b -> Plan g b
ask1    :: SCode c -> Shape c -> Expr g Text -> Plan g (El c)
askC1   :: SCode c -> Q c -> Plan g (El c)
caseB   :: Expr g Bool -> Plan g a -> Plan g a -> Plan g a
caseV   :: Expr g Verdict -> (VTag -> Plan g a) -> Plan g a
panelP  :: [Plan g Verdict] -> Plan g Verdict            -- foldr zipWith (*) (PRet (const 1))
revisingP :: SCode c -> Cont g (El c) Verdict -> Cont g (El c, Verdict) (El c)
          -> Integer -> Cont g (El c) (Maybe (El c))
data SCode (c :: Code) where                             -- the singleton `Code` needs
  SText :: SCode 'CodeText ; SVerdict :: SCode 'CodeVerdict
  SFlag :: SCode 'CodeFlag ; SAck    :: SCode 'CodeAck
class KnownCode (c :: Code) where sCode :: SCode c       -- and its reflection
sCodeVal :: SCode c -> Code                              -- back to Agentic.Raw's Code
data Q (c :: Code)     = Q     { qAddressee, qScope, qPrompt, qDraw }
data Shape (c :: Code) = Shape { shAddressee :: Addressee, shScope :: QScope, shDraw :: Integer }
withPrompt :: Shape c -> Text -> Q c
unitScope  :: QScope                                     -- (Nothing, Nothing)
atModelScope :: Text -> QScope -> QScope                 -- Scope.fst m * s
renderVerdict :: Verdict -> Text                         -- Verdict.render
```

Two notes that belong to the core spec but that the builder depends on:

* `Var`/`Env` indices are **Lean's**: index `0` is the most recently bound
  answer, and `Codes` of a builder scope (§2.1) must be the `Plan` context in
  that order.
* `ECons`'s tail must be lazy (`Env.consBy`, `Plan.lean:79-90`) or `revising` at
  a large bound is exponential. In Haskell this is free.

---

## 1 The elaboration, construct by construct

### 1.0 The four pieces of shared machinery

**(a) `Bindings Γ` — the naming environment, and why the builder's context is an
association list.** `Check.lean:65-96`:

```lean
structure Binding (Γ : Ctx) where
  name : String
  code : Code
  val : Expr Γ (El code)

abbrev Bindings (Γ : Ctx) : Type := List (Binding Γ)

def Binding.at? {Γ : Ctx} (b : Binding Γ) (c : Code) : Option (Expr Γ (El c)) :=
  if h : b.code = c then some (h ▸ b.val) else none

def Bindings.find? {Γ : Ctx} (S : Bindings Γ) (x : String) : Option (Binding Γ) :=
  List.find? (fun b => b.name == x) S

def Bindings.push {Γ : Ctx} (x : String) (c : Code) (S : Bindings Γ) : Bindings (c :: Γ) :=
  ⟨x, c, Expr.var .here⟩ :: S.rename Sub.wk
```

`Bindings.push` is the whole of name resolution: the new name gets de Bruijn `0`
and every older name is weakened by one. So a source name **is** a de Bruijn
index, computed by the plumbing. §2.1 makes this a type-level association list
and `push` a type-level cons; the weakening is then what the `KnownVar` instance
walk performs, one `VS` per entry stepped over.

`Bindings.find?` is innermost-first and `freshName` (`Check.lean:105-111`) makes
shadowing a refusal, so a scope has at most one live binding per name — which is
what licences a type-level assoc list keyed by `Symbol` with a "not already
present" constraint.

**(b) `Prompt.expr` — how a hole reads a binding out of `Env`.**
`Check.lean:126-165`:

```lean
private def chunkExpr {Γ : Ctx} (S : Bindings Γ) (pos : Pos) :
    Chunk → Except CheckError (Expr Γ String)
  | .lit s => .ok (fun _ => s)
  | .interp nm =>
    match lookupBinding S pos nm with
    | .error err => .error err
    | .ok b =>
      match b.at? .text with
      | some e => .ok e
      | none =>
        match b.at? .verdict with
        | some e => .ok (fun δ => Verdict.render (e δ))
        | none => .error ⟨pos, s!"only a text or a verdict answer interpolates …", nm⟩
```

and the fold, deliberately left-associated:

```lean
private def Prompt.exprFrom … (acc : Expr Γ String) : Prompt → …
  | [] => .ok acc
  | ch :: rest => … Prompt.exprFrom S pos (fun δ => acc δ ++ e δ) rest

def Prompt.expr {Γ : Ctx} (S : Bindings Γ) (pos : Pos) : Prompt → …
  | [] => .ok (fun _ => "")
  | ch :: rest => … Prompt.exprFrom S pos e rest
```

So: **a hole at `text` splices the answer itself; a hole at `verdict` splices
`Verdict.render` of it — its objections joined by `"; "`, with approval and
refusal both splicing as `""` (`Syntax.lean:63`); a hole at `flag` or `ack` is
refused.** The empty prompt is `const ""`. The left-association is a
term-identity concern in Lean's proofs only: `Text` concatenation is
associative, so `T.concat [piece₁ γ, …, pieceₙ γ]` is the same observable and is
what Haskell should write.

**(c) `askShape` — the shape, and the one place `served by` lands.**
`Check.lean:170-176`:

```lean
def askShape (m : Option String) (c : Code) (t : RawTarget) : Q.Shape c :=
  let s : Q.Shape c := { addressee := t.addressee, scope := 1, draw := t.draw }
  match m with
  | none => s
  | some mid => atModel mid c s
```

with `atModel m = fun _ s => { s with scope := Agentic.Scope.fst m * s.scope }`
(`Question.lean:425`). Since the written scope is the unit, the result is exactly
`scope = (Just m, Nothing)` — model axis set, mode axis silent. Corpus
confirmation (`battery-119`): an ask with `"model": "deep"` traces with
`"scope": {"model": "deep", "mode": null}` and an unadorned one with
`{"model": null, "mode": null}`. The addressee and the draw pass through
untouched; `served by` never touches the words.

**(d) `askPlan` / `bindForm` — closed questions become `askC`, open ones `ask`.**
`Check.lean:330-343` and `459-483`:

```lean
def askPlan {Γ : Ctx} (c : Code) (S : Bindings Γ) (a : RawAsk) : … :=
  … let s := askShape a.model c a.target
  match Prompt.closed a.prompt with
  | some words => .ok (Plan.askC1 c (s.withPrompt words))
  | none => … .ok (Plan.ask1 c s e)

def bindForm {A : Type} {Γ : Ctx} (fns : Fns) (c : Code) (S : Bindings Γ) (r : RawRhs) :
    Except CheckError (Plan (c :: Γ) A → Plan Γ A) :=
  match r with
  | .ask a =>
    … match Prompt.closed a.prompt with
    | some words => .ok (fun k => Plan.askC c (s.withPrompt words) k)
    | none => … .ok (fun k => Plan.ask c s e k)
  | .panel ms pos => … .ok (fun k =>
      Plan.graft v (fun _ σ e => Plan.sub k (fun δ => Env.cons (e δ) (σ δ))))
  | .call f args pos => … .ok (fun k =>
      Plan.graft v (fun _ σ e => Plan.sub k (fun δ => Env.cons (e δ) (σ δ))))
```

`Prompt.closed` (`Syntax.lean:140`) returns the concatenated literals when the
prompt has no `interp`, and `none` as soon as one appears — including the empty
prompt, which is closed at `""`. **The builder must make this decision from the
`Chunk` list, not from the `Expr`**: `askC` versus `ask` is exactly what `level`
reads to separate `batch` from `pipeline`, so getting it wrong is a fold
mismatch, not a cosmetic one.

`bindForm` at an `.ask` is **one node** — `Plan.ask` *is* ask-and-bind. At a
panel or a call it is a `graft` whose continuation conses the produced value
onto the leaf's environment. (For an `.ask`, `graft (ask1 …) k` reduces to the
same `PAsk c s e k` up to `sub_id`; the builder should still follow Lean and
build the node directly, so that the two implementations agree node-for-node and
not merely up to a theorem.)

### 1.1 `x <- ask …` — a binding whose source is one question

`Check.lean:584-610`:

```lean
  | Γ, S, none, .bind x ann (.rhs rhs) rest pos =>
    match freshName S pos x with … | .ok _ =>
    match (match rhs with
           | .panel _ _ => .ok (ann.getD Code.verdict)
           | .call f _ _ => … .ok (ann.getD fe.result)
           | .ask _ => bindKind (fnSigsOf fns) pos x ann rest : Except CheckError Code) with
    | .error err => .error err
    | .ok c =>
    match bindForm fns c S rhs with … | .ok form =>
      match checkBlock fns (c :: Γ) (Bindings.push x c S) none rest with
      | .error err => .error err
      | .ok k => .ok (form k)
```

Nodes built, in order: **one** node (`PAskC` or `PAsk`) at the imposed code `c`,
whose continuation is the rest of the block checked in `c :: Γ` with `x` pushed
at index `0`. Nothing else.

**Where `c` comes from.** Three disjoint rules:

* a **panel** answers `verdict`, an annotation only confirms it
  (`ann.getD Code.verdict`);
* a **call** answers its declared result (`ann.getD fe.result`), and binding a
  `-> receipt` function is refused;
* a plain **ask** takes its annotation, or infers from the first ground use in
  reading order — `bindKind` / `useKindB` (`Check.lean:205-283`). The scan is:
  a `{x}` hole says `text`; `if x` says `flag`; a verdict `case x` says
  `verdict`; a name passed to a parameter says the parameter's kind; a `revising`
  subject shares its carrier's kind; first match in reading order wins; no use
  at all is a refusal.

The builder does not port `useKindB`. The author supplies `c` at the type level,
and the printed `ann` field is a *separate* argument (`bind` prints
`ann = Nothing`, `bindAs` prints `ann = Just c`). A wrong pairing — `ann =
Nothing` where Lean's inference would have produced a different code — is caught
twice by tier1: the printed Raw still matches, but the trace's `code` and the
world's answer diverge from the frozen reply.

**Draw and `served by`** ride in `RawAsk` and are elaborated by `askShape`
(§1.0c). `askGuard` (`Check.lean:322`) refuses `served by` on a tool or a
person; in the builder that refusal is structural — the served-by variant of the
ask combinator only accepts a model addressee (§2.2).

### 1.2 The act — a statement-position ask

`Check.lean:559-565`:

```lean
  | Γ, S, none, .act a rest _pos =>
    match bindForm fns Code.ack S (.ask a) with
    | .error err => .error err
    | .ok form =>
      match checkBlock fns Γ S none rest with
      | .error err => .error err
      | .ok k => .ok (form (Plan.sub k Sub.wk))
```

The act is an ask **at `Code.ack`** whose answer occupies a context slot that
the continuation immediately weakens past: the rest of the block is checked in
`Γ` (not `ack :: Γ`) and then read into `ack :: Γ` by `Sub.wk`. So the act binds
nothing, *and* it still adds one binder to the de Bruijn spine — which is why
`Sub.wk` is there and why a builder that "just continues" would produce
off-by-one splices in everything after an act. `battery-115` ("names straddling
an act") is the corpus's pin on this.

Trace consequence: the event's code is `receipt` and its answer is `null`
(`answerJson .ack _ = Json.null`).

### 1.3 The panel

`Check.lean:345-357` and `431-455`:

```lean
def checkMembers {Γ : Ctx} (S : Bindings Γ) :
    List RawAsk → Except CheckError (List (Plan Γ (El .verdict)))
  | [] => .ok []
  | a :: as => … askPlan Code.verdict S a … .ok (p :: ps)

  | .panel ms pos =>
    match ms with
    | [] => .error ⟨pos, "a panel needs at least one member", "panel"⟩
    | _ => match c with
      | .verdict => … .ok (Plan.panel ps)
      | c => .error ⟨pos, s!"{what}: a panel combines its members in the verdict monoid, …"⟩
```

Every member is elaborated by `askPlan` **at `.verdict`** — positionally, never
by inference — and the list is combined by `Plan.panel` (`Plan.lean:595`):

```lean
def panel [Monoid (El c)] (ps : List (Plan Γ (El c))) : Plan Γ (El c) :=
  ps.foldr (zipWith (· * ·)) (.ret (fun _ => 1))
```

with `zipWith` (`Plan.lean:442`) grafting `q` under `p`'s binders:

```lean
def zipWith (f : A → B → C) (p : Plan Γ A) (q : Plan Γ B) : Plan Γ C :=
  graft p (fun _ σ e => graft (sub q σ) (fun _ τ e' => .ret (fun θ => f (e (τ θ)) (e' θ))))
```

So the verdict combination is `v₁ * (v₂ * (… * (vₙ * 1)))` in the **verdict
monoid** — `WithZero (FreeMonoid Objection)`: `declined` is the annihilating
zero, `approve` the unit, and objection lists concatenate in member order. The
monoid is noncommutative on purpose (an objection list is a record), so the
builder must fold right, from the unit, in member order. The trace is the
members' events in source order (`trace_panel` is `flatten` of the members'
traces), then whatever follows. A panel's value reaches the rest of the block by
`graft` (§1.0d), not by a new binder form.

`battery-113` pins all of it: three members traced `alpha, beta, gamma`, then the
act whose prompt splices the combined verdict (`"objections: "` — empty, because
all three approved), then the `approved` arm.

### 1.4 The bounded revision and its `case` — one graft, unrolled

This is the only construct where the surface's two statements elaborate to one
term. `Check.lean:611-664`:

```lean
  | Γ, S, none, .bind x ann (.revising subj carrier n rname rann review amend rpos) rest pos =>
    if maxRevisions < n then .error ⟨rpos, s!"a bounded revision is unrolled …"⟩ else
    match ann with
    | some _ => .error ⟨pos, "a revising result is settled-or-not, which is not one of the four kinds; …"⟩
    | none =>
    … (rann must be none or verdict) …
    … freshName x, freshName carrier, freshName rname …
    match lookupBinding S rpos subj with … | .ok b =>
    let Swith : Bindings (Code.verdict :: b.code :: Γ) :=
      ⟨carrier, b.code, fun δ => Env.head (Env.tail δ)⟩ ::
      ⟨rname, Code.verdict, fun δ => Env.head δ⟩ ::
      Bindings.rename Sub.wk (Bindings.rename Sub.wk S)
    match rhsPlan fns Code.verdict (Bindings.push carrier b.code S) review
        "the review of a bounded revision" with … | .ok reviewP =>
    match rhsPlan fns b.code Swith amend "the `amend` of a bounded revision" with … | .ok amendP =>
      checkBlock fns Γ S
        (some ⟨x, b.code,
          Plan.revising (checkCont reviewP) (reviseCont amendP) n Γ Sub.id b.val⟩)
        rest
```

Read off, in order:

1. **The candidate's kind is the subject's kind** (`b.code`), looked up in scope.
   The loop's result gets **no** annotation and **no** context slot: it is
   carried as a `Pend Γ` (`Check.lean:527`) that the next statement must consume.
2. **The review clause** is elaborated at `Code.verdict` in
   `Bindings.push carrier b.code S` — i.e. the candidate is de Bruijn `0` under
   the *carrier's* name. Being a `RawRhs` it may be an ask, a **panel**
   (`battery-135`), or a call.
3. **The amend clause** is elaborated at `b.code` in `Swith`: the *review
   binding* is de Bruijn `0` at `Code.verdict` under the author's chosen name,
   and the *candidate* is de Bruijn `1` under the carrier's name. Note the
   `Bindings` **list** order is `[carrier, rname, …]` while the **context** is
   `verdict :: b.code :: Γ`; nothing observes the list order here (a loop clause
   is an rhs, so no `known here` can appear inside it), but the builder's scope
   index must be context-ordered: `rname` innermost.
4. A `{v}` hole in the amend prompt therefore splices `Verdict.render` of index
   `0`, and a `{carrier}` hole splices index `1` (at `text`) or renders it (at
   `verdict`, as `battery-114` does).

The three continuations (`Check.lean:491-513`):

```lean
def checkCont {Γ : Ctx} {c : Code} (chk : Plan (c :: Γ) (El .verdict)) : Plan.Cont Γ (El c) Verdict :=
  fun _ σ a => Plan.sub chk (fun δ => Env.cons (a δ) (σ δ))

def reviseCont {Γ : Ctx} {c : Code} (rev : Plan (.verdict :: c :: Γ) (El c)) :
    Plan.Cont Γ (El c × Verdict) (El c) :=
  fun _ σ av => Plan.sub rev (fun δ => Env.cons (av δ).2 (Env.cons (av δ).1 (σ δ)))

def finishCont {Γ : Ctx} {c : Code} (acc : Plan (c :: Γ) Unit) (exh : Plan Γ Unit) :
    Plan.Cont Γ (Option (El c)) Unit :=
  fun _ σ final =>
    Plan.caseB (fun δ => (final δ).isSome)
      (Plan.sub acc (fun δ => Env.cons ((final δ).getD default) (σ δ)))
      (Plan.sub exh σ)
```

and the unroll (`Plan.lean:621-635`):

```lean
def revising {Γ : Ctx} {c : Code}
    (check : Cont Γ (El c) Verdict) (revise : Cont Γ (El c × Verdict) (El c)) :
    Nat → Cont Γ (El c) (Option (El c))
  | 0 => fun _ σ a =>
      graft (check _ σ a) fun _ τ v =>
        .ret (fun θ => if Verdict.approvedB (v θ) then some (a (τ θ)) else none)
  | n + 1 => fun _ σ a =>
      graft (check _ σ a) fun _ τ v =>
        caseB (fun θ => Verdict.approvedB (v θ))
          (.ret (fun θ => some (a (τ θ))))
          (graft (revise _ (Sub.comp σ τ) (fun θ => (a (τ θ), v θ))) fun _ ρ a' =>
            revising check revise n _ (Sub.comp (Sub.comp σ τ) ρ) a')
```

**Check first, revise in the recursive call.** At bound `n`: `n + 1` checks and
at most `n` amendments.

* At each round the review runs; then a `caseB` on `Verdict.approvedB` (which is
  `decide (v = approve)` — approval *exactly*, so a refusal is not a settlement).
* **At settle**: the arm is `ret (some candidate)`; the loop stops there and
  nothing further of the unroll is traced.
* **At exhaustion** (the `| 0 =>` clause): the last round has **no `caseB` and no
  amend** — it is one check followed by `ret (if approved then some a else none)`.
  A bound of `0` is therefore a single check and a single `ret`; `battery-120`
  pins that shape (size 7, paths 2 — the only branch being `finishCont`'s
  `caseB`).
* Each round's candidate expression is the previous amend's answer read through
  the accumulated substitution, so the candidate is *re-read*, never re-asked.

Then the consuming `case` (`Check.lean:702-716`):

```lean
  | Γ, S, some pd, .caseResult x sname settled unsettled pos =>
    if x != pd.name then .error ⟨pos, s!"the pending revising result is `{pd.name}`, …"⟩ else
    match freshName S pos sname with … | .ok _ =>
    match checkBlock fns (pd.code :: Γ) (Bindings.push sname pd.code S) none settled with … | .ok settledP =>
    match checkBlock fns Γ S none unsettled with … | .ok unsettledP =>
      .ok (Plan.graft pd.plan (finishCont settledP unsettledP))
```

so the pair elaborates to **one** `graft` of the unrolled loop with a `caseB` at
every leaf: the settled arm checked in `pd.code :: Γ` with the artefact bound at
index `0` under the `settled` binder's name, the unsettled arm checked in `Γ`.
Because `graft` replaces *every* `ret` leaf, both arms are replicated once per
exit of the unroll — which is precisely the `(n+1)*(st+un)` term of `blockAsks`
(`PORTING.md §4.3`) and the reason `vector-002`'s nested loops reach size 92.

**The builder must expose these two surface statements as one combinator**
(§2.2, `revisingCase`), because the type of the intermediate is
`Plan Γ (Option (El c))` and `Ctx` has no code for it.

### 1.5 `if x { … } else { … }`

`Check.lean:665-679`:

```lean
  | Γ, S, none, .ifFlag x y n pos =>
    match lookupBinding S pos x with … | .ok bnd =>
    match bnd.at? .flag with
    | none => .error ⟨pos, s!"an `if` branches on a flag, but `{x}` answers `{codeName bnd.code}`", x⟩
    | some e =>
    … .ok (Plan.caseB e y' n')
```

One `PCase` at `Bool` (`caseB e t f = .case e (fun b => cond b t f)`,
`Plan.lean:479`), both arms in the term, each arm the rest of the workflow
checked in the **same** `Γ` with the **same** `S`. No binder is added — the flag
is read through the existing variable.

### 1.6 `case x { approved … objected … no answer … }`

`Check.lean:681-700`:

```lean
    match bnd.at? .verdict with
    | none => .error ⟨pos, s!"the arms `approved`, `objected` and `no answer` branch on a `verdict`, …"⟩
    | some e => … .ok (Plan.caseV e (fun t => match t with
        | .approve => a' | .object => o' | .declined => d'))
```

One `PCase` at `VTag` via `caseV e arms = .case (fun γ => Verdict.tag (e γ)) arms`
(`Plan.lean:563`), with

```lean
def Verdict.tag (v : Verdict) : VTag :=
  if v = Verdict.declined then .declined else if v = Verdict.approve then .approve else .object
```

Arm order in the term is the `FinEnum` order `[approve, object, declined]`
(`Plan.lean:508`), which the folds (`costSummary`'s path enumeration) read; the
surface's arm order is `approved, objected, no answer`, i.e. the same. The
verdict itself stays readable in every arm as an expression — the tag decides the
shape, the objections ride in the environment.

**The closed set of tag types the elaboration ever produces is exactly two:**
`Bool` (from `ifFlag`, from `finishCont`, and from `revising`'s per-round
`caseB`) and `VTag` (from `caseVerdict`). Nothing else. `Plan.hs`'s `PCase` needs
no more than these two instances.

### 1.7 `known here: …`

`Check.lean:551-557`:

```lean
  | Γ, S, none, .knownHere names rest pos =>
    let live := S.map (·.name)
    if names == live then checkBlock fns Γ S none rest
    else .error ⟨pos, s!"`known here` asserts the names in scope, innermost first, and they are: …"⟩
```

**A checked `known here` elaborates to nothing at all**: the plan is the rest of
the block, unchanged, in the same context. It contributes no node, no binder, no
event, and does not appear in `size`. It is an assertion the *checker* discharges
and the builder can discharge by construction: the printed `names` are computed
from the type-level scope, innermost first (§2.2), so a rebuilt case cannot print
a wrong one. `known here: nothing` is `names = []`, which is what an empty scope
computes.

Dotted names (`module-001`: `known here: lib.guide`) are ordinary names.

### 1.8 A function definition

`Check.lean:288-302`, `750-756`, `783-834`, `836-866`:

```lean
def paramCtx (l : List Code) : Ctx := l.foldl (fun Γ c => c :: Γ) []

def paramBindings : (ps : List (String × Code)) → (acc : Ctx) → Bindings acc → …
  | [], _, S => S
  | (pn, c) :: ps, acc, S => paramBindings ps (c :: acc) (Bindings.push pn c S)
```

`paramCtx` is a left fold, so **the parameter list is reversed into the context**:
for `(p₁ : c₁, p₂ : c₂)` the context is `c₂ :: c₁ :: []` and `p₂` is de Bruijn
`0`. A body is checked **once**, over exactly its parameters, in that context —
"a body cannot see the caller" is the type, not a rule.

A body's statements are `checkBody`, and each clause is the *same* elaboration as
the corresponding block statement: `bind` uses `bindForm` and pushes; `act` uses
`bindForm … Code.ack` and weakens the continuation by `Sub.wk`; `callS` grafts.
The only new rule is the kind of a body binding, which may additionally be
grounded by the `answer` naming it (`bodyBindKind`, `Check.lean:765-781`). The
terminal is

```lean
  | some x => … (fun _ SΔ => … match b.at? f.result with
      | some e => .ok (Plan.ret e)
      | none => .error ⟨f.answerPos, s!"`answer {x}`: …"⟩)
  | none => match f.result with
    | .ack => … (fun _ _ => .ok (Plan.ret (fun _ => ())))
    | c => .error ⟨f.answerPos, s!"a value function ends with `answer <name>`; …"⟩
```

— `answer x` is `PRet` of `x`'s expression at the declared result kind; a
`-> receipt` function ends with `PRet (const ())`. A function body may contain
**no** branching and **no** loop (`RawBodyStmt` has no such constructors): a
function is a reusable sequence of questions, not a reusable decision.

### 1.9 A call — substitution, not a node

`Check.lean:359-429`:

```lean
def argExpr {Γ : Ctx} (S : Bindings Γ) (fname pname : String) (c : Code) :
    RawArg → Except CheckError (Expr Γ (El c))
  | .name x pos => … match b.at? c with
      | some e => .ok e
      | none => … (and the special diagnosis for a verdict passed to text)
  | .lit p pos => match c with
    | .text => Prompt.expr S pos p
    | c => .error ⟨pos, s!"words fill a `text` parameter, …"⟩

def checkArgs {Δ : Ctx} (S : Bindings Δ) (fname : String) :
    (ps : List (String × Code)) → List RawArg → (acc : Ctx) → Sub acc Δ →
    Except CheckError (Sub ((ps.map Prod.snd).foldl (fun Γ c => c :: Γ) acc) Δ)
  | [], [], _, σ => .ok σ
  | (pn, c) :: ps, a :: as, acc, σ =>
    … checkArgs S fname ps as (c :: acc) (fun δ => Env.cons (e δ) (σ δ))

def callPlan {Δ : Ctx} (S : Bindings Δ) (fns : Fns) (f : String) (args : List RawArg) (pos : Pos) :
    Except CheckError (Σ c : Code, Plan Δ (El c)) :=
  … match checkArgs S f fe.params args [] (fun _ => Env.nil) with
    | .ok σ => .ok ⟨fe.result, Plan.sub fe.plan σ⟩
```

**A call is `Plan.sub` of the callee's plan along the argument list.** `Sub Γf Δ`
is *definitionally* an argument list of typed expressions, so the fold above is
the calling convention: arguments left to right, each consed onto the environment
being built, starting from `Env.nil`. Combined with `paramCtx`'s reversal this
puts `pᵢ`'s argument exactly where `pᵢ`'s binding reads it. No node is added, so
the callee's questions appear inlined at the call site, in body order, with
caller-evaluated arguments in their prompts. `module-000` pins this: the caller's
`lib.guide` answer is spliced into `lib.drafted`'s `"draft: {goal}"` prompt.

An argument that is a **name** must answer the parameter's kind *exactly* —
`b.at? c`, no silent rendering; a verdict passed to a `text` parameter is refused
by name (`battery-180`). An argument that is **words** fills a `text` parameter
and is elaborated in the **caller's** bindings, so `argWords [hole @"x"]` is
legal and reads the caller's `x`.

Two call positions:

* **value call** (`Check.lean:584-610` via `bindForm`'s `.call` branch): the
  result reaches the rest by `graft` + `Env.cons`, exactly like a panel;
* **statement call** (`Check.lean:569-583`): only a `-> receipt` function may
  stand there, and it elaborates to
  `Plan.graft p (fun _ σ _ => Plan.sub k σ)` — the answer is discarded and **no
  context slot is added** (contrast the act, §1.2, which does add one).

The table is stratified: `Fns.find?` answers with the first match, a duplicate
name is refused (`checkFnsList`), and a call may name only an earlier entry —
which is what refuses recursion. In the builder this is Haskell's `let`: a
function value must exist before it can be applied.

### 1.10 Summary table — what each construct contributes

| surface | nodes built | context after | events |
|---|---|---|---|
| `x <- ask …` (closed prompt) | `PAskC c q k` | `c ': g`, `x` at 0 | 1 |
| `x <- ask …` (holed prompt) | `PAsk c s e k` | `c ': g`, `x` at 0 | 1 |
| `ask …` (act) | `PAskC/PAsk ack … (subPlan k wkSub)` | `g` (slot weakened) | 1, code `receipt`, answer `null` |
| `x <- panel [a₁..aₙ]` | `graft (panelP [ask…]) (cons ∘ σ)` | `verdict ': g` | n, in member order |
| `x <- f a…` | `graft (subPlan fnPlan σ) (cons ∘ σ)` | `r ': g` | callee's, inlined |
| `f a…` (statement) | `graft (subPlan fnPlan σ) (\σ _ -> subPlan k σ)` | `g` (no slot) | callee's |
| `if x {y} else {n}` | `caseB (var x) y n` | unchanged in both arms | 0 |
| `case x {a}{o}{d}` | `caseV (var x) arms` | unchanged in all arms | 0 |
| `known here: …` | none | unchanged | 0 |
| `x <- revising … case x {settled p}{unsettled}` | `graft (revisingP chk rev n idSub (var subj)) (finishCont settled unsettled)` | settled arm: `c ': g`, `p` at 0; unsettled: `g` | 1..(2n+1) per §1.4 |
| `stop` / end of block | `PRet (const ())` | — | 0 |

---

## 2 The Builder API

### 2.1 The encoding decision: the typed context is a type-level association list

**Chosen, and to be implemented as spelled here: the builder's context is a
type-level list of `(Symbol, Code)` pairs; a name is a `Symbol`; the de Bruijn
index is computed by a class instance walk; the `Plan` context is the projection
of the codes.** This is the exact shape of Lean's `Bindings Γ` (§1.0a) — an
association list from name to code, extended by cons, with shadowing refused —
so the mirror is one-to-one, and *no manual weakening is ever written*: a hole
resolves against the scope at its own position, and the instance walk emits one
`VS` per entry it steps over, which is what `Bindings.rename Sub.wk` does in
Lean.

Rejected alternatives, for the record: an indexed monad (`>>=` at
`Blk s -> (a -> Blk s') -> …`) buys nothing, because a block's statements bind
*names* rather than values and its branchings are terminal — `$`-chained
continuation-taking combinators mirror `RawBlock`'s `rest` field exactly; and
handing back a `Var g c` proxy from the binder forces the author to weaken every
older name by hand at every depth, which is the one bookkeeping the Lean side
does not make the author do.

```haskell
{-# LANGUAGE DataKinds, TypeFamilies, GADTs, RankNTypes, PolyKinds,
             ScopedTypeVariables, TypeApplications, AllowAmbiguousTypes,
             UndecidableInstances, ConstraintKinds, TypeOperators,
             FlexibleContexts, FlexibleInstances, KindSignatures #-}

import Agentic.Raw (Code(..))          -- promoted: 'CodeText, 'CodeVerdict, 'CodeFlag, 'CodeAck
import GHC.TypeLits (Symbol, KnownSymbol, symbolVal, TypeError, ErrorMessage(..))
import Data.Type.Equality (type (==))

-- | One live binding: the author's name, and the kind of answer it stands for.
--   Lean: `Binding Γ` minus the `val`, which is recovered by `varOf`.
type Entry = (Symbol, Code)

-- | The names in scope, innermost first. Lean: `Bindings Γ`.
type Scope = [Entry]

-- | The Plan context a scope projects to. Lean: the `Γ` a `Bindings Γ` is over.
type family Codes (s :: Scope) :: [Code] where
  Codes '[]              = '[]
  Codes ('(n, c) ': s)   = c ': Codes s
```

Name resolution, as a closed family plus a boolean-dispatched class (no
overlapping instances):

```haskell
-- | The kind a name stands for. An unbound name is a type error that names it.
--   Lean: `Bindings.find?` + the `unbound` diagnosis.
type family LookupC (n :: Symbol) (s :: Scope) :: Code where
  LookupC n ('(n, c) ': s) = c                       -- non-linear match: innermost wins
  LookupC n ('(m, d) ': s) = LookupC n s
  LookupC n '[] = TypeError ('Text "unbound name; nothing in scope answers to `"
                             ':<>: 'Text n ':<>: 'Text "`")

-- | …and the de Bruijn index that reads it. Lean: `Expr.var` after `Bindings.push`'s
--   repeated `Sub.wk`, one `VS` per entry stepped over.
class KnownVar (n :: Symbol) (s :: Scope) where
  varOf :: Var (Codes s) (LookupC n s)

class KnownVar' (eq :: Bool) (n :: Symbol) (s :: Scope) where
  varOf' :: Var (Codes s) (LookupC n s)

instance (m ~ n, LookupC n ('(m, c) ': s) ~ c) => KnownVar' 'True n ('(m, c) ': s) where
  varOf' = VZ
instance (KnownVar n s, LookupC n ('(m, d) ': s) ~ LookupC n s)
      => KnownVar' 'False n ('(m, d) ': s) where
  varOf' = VS (varOf @n @s)

instance KnownVar' (n == m) n ('(m, d) ': s) => KnownVar n ('(m, d) ': s) where
  varOf = varOf' @(n == m) @n @('(m, d) ': s)

-- | Reading a name, as an expression. Lean: `Binding.val`.
nameExpr :: forall n s. KnownVar n s => Expr (Codes s) (El (LookupC n s))
nameExpr = varGet (varOf @n @s)
```

No shadowing, as a constraint — Lean's `freshName`, verbatim in the message:

```haskell
type family Fresh (n :: Symbol) (s :: Scope) :: Constraint where
  Fresh n '[]             = ()
  Fresh n ('(n, c) ': s)  = TypeError ('Text "this name is already in scope, and a live \
                                              \name is not introduced twice; rename one \
                                              \of the two: " ':<>: 'Text n)
  Fresh n ('(m, d) ': s)  = Fresh n s
```

The scope's names, reified for `known here` and for the printer:

```haskell
class KnownScope (s :: Scope) where scopeNames :: [Text]     -- innermost first
instance KnownScope '[] where scopeNames = []
instance (KnownSymbol n, KnownScope s) => KnownScope ('(n, c) ': s) where
  scopeNames = T.pack (symbolVal (Proxy @n)) : scopeNames @s
```

### 2.2 The types and the combinators

Everything carries its Raw beside its Plan; there is no separate print pass.

```haskell
-- | A block: the Raw it prints (positions all 0:0) and the Plan it elaborates to.
data Blk (s :: Scope) = Blk { blkRaw :: Raw, blkPlan :: Plan (Codes s) () }

-- | One piece of a prompt. Lean: `Chunk` + `chunkExpr`.
data Piece (s :: Scope) = Piece { pieceRaw :: Chunk, pieceExpr :: Expr (Codes s) Text }
type Words (s :: Scope) = [Piece s]

lit :: Text -> Piece s
lit t = Piece (Lit t) (const t)

-- | A hole. Only `text` and `verdict` have a text of their own; the other two
--   are a *type* error, which is Lean's `chunkExpr` refusal.
hole :: forall n s. (KnownSymbol n, KnownVar n s, Spliceable (LookupC n s)) => Piece s
hole = Piece (Interp (nameText @n)) (splice @(LookupC n s) . nameExpr @n @s)

class Spliceable (c :: Code) where splice :: El c -> Text
instance Spliceable 'CodeText    where splice = id
instance Spliceable 'CodeVerdict where splice = renderVerdict     -- Verdict.render
instance TypeError ('Text "only a text or a verdict answer interpolates into a prompt \
                          \— a flag has no text of its own") => Spliceable 'CodeFlag
instance TypeError ('Text "only a text or a verdict answer interpolates into a prompt \
                          \— a receipt has no text of its own") => Spliceable 'CodeAck
```

An ask is *not* yet at a code — the code comes from the position or the binder,
exactly as in Lean, so `Ask` is code-agnostic and is elaborated at a code by
`askAt`:

```haskell
-- | One question as written: whom, which draw, what words, and the served-by
--   override. Lean: `RawAsk` (whose `kind is not a field`).
data Ask (s :: Scope) = Ask
  { askAddr  :: Addressee
  , askDraw  :: Integer
  , askServe :: Maybe Text          -- legal only at a model addressee (below)
  , askWords :: Words s
  }

askModel  :: Text -> Words s -> Ask s                      -- draw 0
askTool   :: Text -> Words s -> Ask s
askPerson :: Text -> Words s -> Ask s
served    :: Text -> Ask s -> Ask s   -- ONLY defined to accept an AddrModel ask; see note
draw      :: Integer -> Ask s -> Ask s

-- | Lean: `askShape` + `askPlan`/`bindForm`'s `.ask` branch. Note the
--   closed/open decision is made on the CHUNKS, not on the Expr.
askRaw   :: Ask s -> RawAsk                            -- pos = Pos 0 0
askShapeH:: SCode c -> Ask s -> Shape c
askNode  :: KnownCode c => Ask s -> Plan (c ': Codes s) a -> Plan (Codes s) a
askAt    :: KnownCode c => Ask s -> Plan (Codes s) (El c)   -- Lean: askPlan (ask1/askC1)
```

`served` must refuse a tool or a person. Two equally acceptable spellings, pick
the first: keep the addressee's party in a phantom index
(`Ask s (p :: Party)`, with `served :: Text -> Ask s 'PModel -> Ask s 'PModel`),
or make `askModel'` the only constructor that takes a served-by name
(`askModelServed :: Text -> Text -> Words s -> Ask s`). Either way the
`askGuard` refusal is unrepresentable rather than checked.

Clause-position sources — Lean's `RawRhs`, at an imposed code:

```haskell
-- | A source, at the code its position or its binder fixes.
data Rhs (s :: Scope) (c :: Code) = Rhs
  { rhsRaw  :: RawRhs
  , rhsPlan :: Plan (Codes s) (El c)                        -- Lean: rhsPlan
  , rhsForm :: forall a. Plan (c ': Codes s) a -> Plan (Codes s) a   -- Lean: bindForm
  }

-- one question
one   :: KnownCode c => Ask s -> Rhs s c
-- a panel: verdict only, at least one member (a NonEmpty makes `panelEmpty`
-- unrepresentable, which is why tier1 cannot rebuild vector-004)
panel :: NonEmpty (Ask s) -> Rhs s 'CodeVerdict
-- a call
callV :: Fn ps r -> Args s ps -> Rhs s r
```

`one`'s `rhsForm` builds the single node; `panel`'s and `callV`'s build the
`graft (…) (\σ e -> subPlan k (\d -> ECons (e d) (σ d)))` of §1.0d.

Arguments and functions:

```haskell
data Arg (s :: Scope) (c :: Code) = Arg { argRaw :: RawArg, argExpr :: Expr (Codes s) (El c) }
argName  :: forall n s. (KnownSymbol n, KnownVar n s) => Arg s (LookupC n s)   -- exact kind
argWords :: Words s -> Arg s 'CodeText                                         -- text only

data Args (s :: Scope) (ps :: [Code]) where
  ANil  :: Args s '[]
  (:>)  :: Arg s c -> Args s cs -> Args s (c ': cs)         -- infixr 5

-- | A checked function: its Raw and its plan over exactly its parameters.
--   Lean: `FnEntry`. `ParamCtx` is `paramCtx`: the left fold, i.e. the reverse.
type family ParamCtx (ps :: [Code]) :: [Code]
data Fn (ps :: [Code]) (r :: Code) = Fn { fnRaw :: RawFn, fnPlan :: Plan (ParamCtx ps) (El r) }
```

A function body is its own small builder, mirroring `RawBodyStmt` and
`checkBody` — no branchings, no loops, by type:

```haskell
data Body (s :: Scope) (r :: Code) = Body { bodyRaw :: [RawBodyStmt], bodyPlan :: Plan (Codes s) (El r) }

bindB   :: forall n c s r. (KnownSymbol n, Fresh n s, KnownCode c)
        => Rhs s c -> Body ('(n, c) ': s) r -> Body s r
bindAsB :: forall n c s r. (…)                                     -- prints ann = Just c
        => Rhs s c -> Body ('(n, c) ': s) r -> Body s r
actB    :: Ask s -> Body s r -> Body s r                           -- weakens by wkSub
callSB  :: Fn ps 'CodeAck -> Args s ps -> Body s r -> Body s r
answerB :: forall n s. (KnownSymbol n, KnownVar n s) => Body s (LookupC n s)
endB    :: Body s 'CodeAck                                         -- a `-> receipt` body's end

-- | Lean: `checkFn`. `ps`/`names` give the params in SOURCE order; the context
--   is their reverse (§1.8).
function :: forall name ps r. (KnownSymbol name, …)
         => ParamNames ps -> (Body (ParamScope ps) r) -> Fn ps r
```

The block combinators. Each takes the rest of the block as its last argument, so
a program is a `$`-chain that reads in source order:

```haskell
stop      :: Blk s
bind      :: forall n c s. (KnownSymbol n, Fresh n s, KnownCode c)
          => Rhs s c -> Blk ('(n, c) ': s) -> Blk s               -- prints ann = Nothing
bindAs    :: forall n c s. (KnownSymbol n, Fresh n s, KnownCode c)
          => Rhs s c -> Blk ('(n, c) ': s) -> Blk s               -- prints ann = Just c
act       :: Ask s -> Blk s -> Blk s
callStmt  :: Fn ps 'CodeAck -> Args s ps -> Blk s -> Blk s
ifFlag    :: forall n s. (KnownSymbol n, KnownVar n s, LookupC n s ~ 'CodeFlag)
          => Blk s -> Blk s -> Blk s
caseVerdict :: forall n s. (KnownSymbol n, KnownVar n s, LookupC n s ~ 'CodeVerdict)
          => Blk s -> Blk s -> Blk s -> Blk s        -- approved, objected, no answer
knownHere :: forall s. KnownScope s => Blk s -> Blk s            -- a no-op; names computed

-- | The loop and its consuming `case`, as ONE combinator (§1.4).
--   `subj` is the subject in scope; `c` is its kind, hence the candidate's.
revisingCase
  :: forall subj carrier rev settled s c.
     ( KnownSymbol carrier, KnownSymbol rev, KnownSymbol settled
     , KnownVar subj s, c ~ LookupC subj s, KnownCode c
     , Fresh carrier s, Fresh rev s, Fresh settled s )
  => Text                                        -- the loop result's name (printed only)
  -> Integer                                     -- the bound n (0 ≤ n ≤ 64)
  -> Maybe Code                                  -- the review's printed annotation
  -> Rhs ('(carrier, c) ': s) 'CodeVerdict       -- the review
  -> Rhs ('(rev, 'CodeVerdict) ': '(carrier, c) ': s) c   -- the amend
  -> Blk ('(settled, c) ': s)                    -- the settled arm
  -> Blk s                                       -- the unsettled arm
  -> Blk s

-- | The whole program: the function table in declaration order, and the block.
data Program = Program { progRawOut :: RawProgram, progPlan :: Plan '[] () }
data SomeFn where SomeFn :: Fn ps r -> SomeFn
program :: [SomeFn] -> Blk '[] -> Program
```

Note the amend's scope: `rev` innermost, then `carrier`, then the enclosing
scope — the context order of §1.4 step 3.

`revisingCase`'s `Text` first argument is the loop-result name; it appears only
in the printed `RawBind`'s `x` and in nothing else, since the result never enters
a scope. The bound is an `Integer` and not a type-level `Nat`: the unroll is a
value-level recursion (`revisingP`), and Lean's own `maxRevisions` check is a
runtime refusal too. `revisingCase` should `error` on `n > 64` — tier1 rebuilds
only checked entries, so an unreachable path.

### 2.3 A worked example — `semantic-000`, rebuilt

```haskell
semantic000 :: Program
semantic000 = program [] $
  bind @"g" @'CodeText (one (askTool "cat" [lit "read the file"])) $
  act (askTool "log" [hole @"g", lit "||", hole @"g"]) $
  act (askTool "audit" [lit "seen: ", hole @"g"]) $
  stop
```

prints (modulo pos) the corpus's `request.program` byte for byte, and elaborates
to

```
PAskC text q₀                               -- closed prompt ⇒ askC
  (PAsk ack s₁ e₁                           -- holed prompt ⇒ ask
     (subPlan (PAsk ack s₂ e₂ (subPlan (PRet (const ())) wkSub)) wkSub))
```

with `e₁ = \d -> varGet VZ d <> "||" <> varGet VZ d` and
`e₂ = "seen: " <> varGet VZ d`.

The point to get right is that **both** acts build their prompt at the scope
`'[ '("g", 'CodeText) ]` — `g` is `VZ` in each — and it is the whole
*continuation plan*, not the prompt, that `act` weakens past its own `ack` slot.
`subPlan` then pushes that weakening into the nested expressions, so in the
final term the second act's `g` reads through one `Env.tail`. This is §1.2's
`Sub.wk` and it is the single most likely place for a hand-written builder to be
off by one; the encoding of §2.1 gets it right for free, because `act`'s
continuation is typed at the *same* scope `s` while its plan is
`subPlan (blkPlan rest) wkSub`. `battery-115` ("names straddling an act") is the
corpus's dedicated pin, and is a good thirteenth case if this one ever fails.

---

## 3 The printer, and the pos rule

**Positions are not representable in the builder.** Every `Pos` the builder
emits is `Pos 0 0` — in `RawAsk.askPos`, in every `Raw` constructor's trailing
position, in `RawArg`, in `RawFn`'s `fnPos`/`fnAnswerPos`, everywhere. `pos` is
oracle-only for this whole program, exactly like `message` and `excerpt`
(`PORTING.md §4.1`).

Comparison strips positions on **both** sides:

```haskell
-- | Every Pos in a program, set to 0:0. Total, structural, and applied to both
--   the built program and the corpus's decoded one before (==).
zeroPos :: RawProgram -> RawProgram
```

`zeroPos` must recurse into: `RawProgram.progFns` (each `RawFn`'s `fnPos`,
`fnAnswerPos`, and every `RawBodyStmt`), `RawProgram.progMain` (every `Raw`
node's trailing pos), every `RawAsk` (`askPos`) including panel members and loop
clauses, and every `RawArg`. It is idempotent on the builder's own output, so
applying it to both sides costs nothing and cannot mask a mismatch.

The comparison is on the **Haskell value**, not on JSON: `zeroPos built ==
zeroPos (decoded corpus program)`. Week one already proved the codec faithful, so
a value comparison is strictly stronger than an `Aeson.Value` one and gives a
better failure message. tier1 should also assert `toJSON (zeroPos built)` decodes
back to the same value, reusing week one's round-trip harness.

---

## 4 tier1: the rebuilt-case discipline

### 4.1 What tier1 checks, per case

For each rebuilt case, holding the corpus entry's `reply` as the expectation:

1. **printed Raw** — `zeroPos (progRawOut built) == zeroPos (corpus request.program)`.
2. **static folds** — `level`, `size`, `askNodes`, `codes`, `costSummary`
   (`minFold`, `maxFold`, `paths`) computed by `Agentic.Plan` on
   `progPlan built`, against `reply`'s fields.
3. **counts** — `blockAsks` and `fnAsks` from `Agentic.Guards.askCounts` applied
   to the *printed* program, against `reply`'s fields. (This is week one code, and
   running it on the rebuilt Raw cross-checks the builder against the corpus's
   own program.)
4. **per world** — for each `WorldSpec` in `request.worlds`, in order:
   `map eventJson (trace (toWorld w) (progPlan built) ENil)` against
   `reply.worlds[i].trace`, and `billFresh tick` / `billMemo tick` against
   `billFresh` / `billMemo`. Compare the trace as `[Aeson.Value]`, whole events,
   no field skipped — `code`, `addressee`, `scope`, `prompt`, `draw`, `answer`
   are all normative.

A case fails loudly with the entry name, which check failed, and the first
differing element. `tier1` takes the corpus dir as `argv[1]`, defaulting to
`/Users/johnw/src/agent-cat/test/corpus`, and exits non-zero on any failure.

`Cases.hs` exports `cases :: [(FilePath, Program)]` — the corpus file's basename
paired with the rebuilt program — and nothing else; `Main.hs` owns the
comparison. The cabal file gains `Agentic.Plan`, `Agentic.World`,
`Agentic.Builder` under `exposed-modules` and a `tier1` executable
(`hs-source-dirs: tier1`, `main-is: Main.hs`), edited only by the tier1 agent.

### 4.2 The twelve cases

Each is a **checked** entry (`reply` has `worlds`, not `refused`). The surface
source is quoted so the case author transcribes rather than invents; where the
corpus entry was hand-built or generated, the generator's source is quoted from
`test/CorpusGen.lean`. Positions in the quoted sources are irrelevant (§3).

---

**1. `semantic-000-sharing-one-binding-holed-three-times.json`**
Covers: inferred kind (`text`, from the first hole), two acts, the `Sub.wk`
index shift, **two worlds** (`echo` and `wrap "<" ">"`), `pipeline`.
Source (`DslCases.lean:682`, `semSrc0`):
```
workflow {
  g <- ask tool "cat" "read the file"
  ask tool "log" "{g}||{g}"
  ask tool "audit" "seen: {g}"
}
```
Worlds: `[{}, { text := .wrap "<" ">" }]`. Expect size 4, askNodes 3,
codes `[text, receipt, receipt]`, costSummary `(3, 3, 1)`, traces of 3 events,
bills `(3,3)` in both worlds.

**2. `semantic-001-a-loop-that-settles-at-round-two.json`**
Covers: `revisingCase` at bound 3, both arms of the consuming case, **two
worlds** — one where the first check approves (3 events) and one where every
check objects and the loop exhausts (9 events, the `| 0 =>` clause reached).
Source (`DslCases.lean:685`, `semSrc1`):
```
workflow {
  d : text <- ask model "author" "draft"
  r <- revising d as patch, at most 3 amendments {
    v <- ask model "critic" "review {patch}"
    amend patch { ask model "author" "amend {patch} given {v}" }
  }
  case r { settled final { ask tool "apply" "apply {final}" }
           unsettled { ask tool "log" "gave up" } }
}
```
Worlds: `[{}, { verdict := .const (.object ["not good enough"]), flag := .const false }]`.
Expect size 31, askNodes 16, codes `null`, costSummary `(3, 9, 8)`; world 1
trace 3 events, world 2 trace 9 events (`draft`, then four `review …` alternating
with three `amend …`, then `gave up`). Note `d` is **annotated** `: text`, so
`bindAs`, printing `ann = "text"`.

**3. `semantic-002-draws-are-distinct-questions.json`**
Covers: the `draw` field, the **`byDraw` world** (the corpus's only non-echo,
non-wrap, non-const world spec), two annotated bindings.
Source (`CorpusGen.lean:132-136`, written inline in the generator):
```
workflow { a : text <- ask model "m" "one"
           b : text <- ask model "m" independent draw 1 "one"
           ask tool "t" "{a} {b}" }
```
Worlds: `[{ text := .byDraw }]`. Expect trace
`[(text, "one", draw 0, "draw:0"), (text, "one", draw 1, "draw:1"),
(receipt, "draw:0 draw:1", draw 0)]`, bills `(3,3)`.

**4. `semantic-003-a-flag-carrier-loop.json`**
Covers: **`if`/`else` on a flag**, an inferred flag kind (`ok` is grounded by the
`if`), an empty `else` arm, **two worlds** taking the two arms (3 events vs 2).
Source (`CorpusGen.lean:138-142`):
```
workflow { d : text <- ask tool "t" "w"
  ok <- ask person "o" "go?"
  if ok { ask tool "a" "went {d}" } else { stop } }
```
Worlds: `[{}, { verdict := .const (.object ["not good enough"]), flag := .const false }]`.
Expect size 6, askNodes 3, codes `null`, costSummary `(2, 3, 2)`.
**The entry's name is wrong — there is no loop in it** (§5).

**5. `battery-113-three-panel-members-answered-differently.json`**
Covers: a **panel** of three, the verdict monoid fold, a verdict **spliced into
a prompt** (`Verdict.render`), a **`case` on a verdict** with all three arms.
Source (`DslCases.lean:688`, `semSrc2`):
```
workflow {
  p <- panel, all must approve [ ask model "alpha" "check one",
                                ask model "beta" "check two",
                                ask model "gamma" "check three" ]
  ask tool "log" "objections: {p}"
  case p { approved { ask tool "t" "went-approved" }
           objected { ask tool "t" "went-objected" }
           no answer { ask tool "t" "went-noanswer" } }
}
```
World: `[{}]`. Expect size 11, askNodes 7, codes `null`, costSummary `(5, 5, 3)`,
trace of 5 events ending `objections: ` (all approved, so the render is empty)
and `went-approved`. `p` carries **no** annotation (`ann = null`), since a panel's
kind is positional.

**6. `battery-117-two-draws-of-one-prompt-are-two-questions.json`**
Covers: the **memo bill strictly below the fresh bill** — `billFresh 4`,
`billMemo 3` — which is one of only **two** entries in the whole corpus where
they differ (§5), plus repeated identical questions and a three-hole prompt.
Source (`DslCases.lean:698`, `semSrc6`):
```
workflow {
  a <- ask model "oracle" "same words"
  b <- ask model "oracle" "same words"
  c <- ask model "oracle" independent draw 1 "same words"
  ask tool "log" "{a}|{b}|{c}"
}
```
World: `[{}]`. Expect size 5, askNodes 4, codes
`[text, text, text, receipt]`, costSummary `(4, 4, 1)`, trace of 4 events,
bills `(4, 3)`.

**7. `battery-119-served-by-and-independent-draw-together-in-every-ask-position.json`**
Covers: **`served by`** on a bound ask, on an act, and on a panel member — i.e.
`atModel`'s scope in the trace — combined with non-zero draws in every position,
and a `case` on a verdict with three empty arms.
Source (`DslCases.lean:409`, "served by and independent draw together, in every ask position"):
```
workflow {
  a : text <- ask model "author" served by "deep" independent draw 2 "draft it"
  ask model "logger" served by "cheap" independent draw 1 "note {a}"
  p <- panel, all must approve [
    ask model "one" served by "deep" independent draw 3 "review {a}",
    ask tool "lint" independent draw 1 "lint {a}",
    ask person "owner" independent draw 2 "ok? {a}"
  ]
  case p { approved { stop } objected { stop } no answer { stop } }
}
```
World: `[{}]`. Expect size 9, askNodes 5, codes `null`, costSummary `(5, 5, 3)`,
and traced scopes `{"model":"deep"}`, `{"model":"cheap"}`, `{"model":"deep"}`,
`{"model":null}`, `{"model":null}` with draws 2, 1, 3, 1, 2.

**8. `battery-107-known-here-innermost-first.json`**
Covers: **`known here`** as a no-op, innermost-first name order, and a hole
reading a name across it.
Source (`DslCases.lean:372`):
```
workflow { a : text <- ask tool "c" "a"
           b : text <- ask tool "c" "b {a}"
           known here: b, a
           ask tool "log" "{a} {b}" }
```
World: `[{}]`. Expect size 4 (the `known here` contributes **no** node),
askNodes 3, codes `[text, text, receipt]`, trace prompts `a`, `b a`, `a b a`.

**9. `module-000-an-import-a-dotted-call-a-dotted-define-in-a-hole.json`**
Covers: a **function** with one parameter and an `answer`, a **value call**
inlining it with argument substitution, **dotted names** (`lib.guide`,
`lib.drafted`), the library **priming spliced ahead of the workflow**, an expanded
define appearing as a plain `lit` chunk, and a non-empty `fnAsks`.
Source (`DslCases.lean:637-641`, module case with `libOk` as `lib`):
```
-- lib:
define greeting = "hello"
function drafted (goal : text) -> text {
  d <- ask model "author" "draft: {goal}"
  answer d
}
guide : text <- ask tool "cat" "style guide"

-- main:
import lib
workflow {
  x <- lib.drafted lib.guide
  ask tool "t" "use {x} {lib.greeting}"
}
```
The **builder writes the post-import-walk form**: `fns = [lib.drafted]`, and
`main` begins with `bindAs @"lib.guide" @'CodeText` (the priming, annotated),
then `bind @"x"` of `callV drafted (argName @"lib.guide" :> ANil)` with
`ann = null`, then the act whose prompt is
`[lit "use ", hole @"x", lit " ", lit "hello"]` — **two adjacent literals, not
fused** (`Prompt.normalize` does not fuse; the define expanded into its own
chunk). World `[{}]`. Expect size 4, askNodes 3, codes
`[text, text, receipt]`, `fnAsks = [["lib.drafted", 1]]`, trace prompts
`style guide`, `draft: style guide`, `use draft: style guide hello`.

**10. `battery-144-a-statement-call-of-a-procedure.json`**
Covers: a **statement call** of a `-> receipt` function (the graft that adds
**no** context slot, §1.9), a table of **three** functions of which only one is
called, and `fnAsks` over the whole table.
Source (`DslCases.lean:488`, `fnsPre ++ …`):
```
function mk (goal : text) -> text {
  d <- ask model "author" "draft: {goal}"
  answer d
}
function judged (patch : text) -> verdict {
  v <- ask model "judge" "judge: {patch}"
  answer v
}
function applied (patch : text) -> receipt {
  ask tool "apply" "apply: {patch}"
}
workflow { d : text <- ask tool "t" "w"
 applied d }
```
World: `[{}]`. Expect size 3, askNodes 2, codes `[text, receipt]`,
costSummary `(2, 2, 1)`,
`fnAsks = [["mk",1],["judged",1],["applied",1]]`, trace prompts `w`,
`apply: w`. Note `applied`'s body is a single **act** and its `answer` is
`null`.

**11. `vector-002-blockasks-graft-at-depth.json`**
Covers: the **nested graft** — a `revisingCase` inside another's settled arm, so
the inner loop and its arms are replicated once per exit of the outer unroll —
and **two worlds**, one settling both loops at their first check (4 events) and
one exhausting the outer loop (6 events, unsettled arm `stop`).
Source (`CorpusGen.lean:76-89`, `graftDepthSrc`):
```
workflow { d : text <- ask model "a" "draft"
  r <- revising d as c, at most 2 amendments {
    v <- ask model "m" "review {c}"
    amend c { ask model "a" "fix {c} {v}" }
  }
  case r { settled x {
    r2 <- revising x as c2, at most 3 amendments {
      v2 <- ask model "m2" "review again {c2}"
      amend c2 { ask model "a" "refix {c2} {v2}" }
    }
    case r2 { settled y { ask tool "t" "apply {y}" }
              unsettled { stop } }
  } unsettled { stop } }
}
```
Worlds: `[{}, { verdict := .const (.object ["not good enough"]), flag := .const false }]`.
Expect size **92**, askNodes 39, codes `null`, costSummary `(2, 14, 27)`,
`blockAsks 39`; world 2's trace is `draft`, then three
`review …`/`fix …` pairs ending on the third `review`, then nothing (6 events).
This is the case that will catch an off-by-one in the unroll or a graft that
replicates the arms the wrong number of times.

**12. `battery-121-a-bounded-revision-whose-candidate-is-not-text.json`**
Covers: a loop whose **candidate is a flag** (so the amend clause is elaborated
at `'CodeFlag` and the settled binder is a flag), an **`if` inside the settled
arm**, and a review whose prompt mentions nothing (a closed question inside a
loop, hence `askC` inside the unroll).
Source (`DslCases.lean:707`, `semSrc9`):
```
workflow {
  ready : flag <- ask person "owner" "is the release ready?"
  r <- revising ready as cand, at most 2 amendments {
    v <- ask model "m" "does the release look ready?"
    amend cand { ask person "owner" "is it ready now?" }
  }
  case r {
    settled done { if done { ask tool "ship" "ship it" } else { stop } }
    unsettled { stop }
  }
}
```
World: `[{}]`. Expect size 26, askNodes 9, codes `null`, costSummary
`(2, 7, 9)`, trace `[(flag, "is the release ready?", true),
(verdict, "does the release look ready?", approve), (receipt, "ship it")]`.

---

**Two cheap extras**, if the twelve go green and more coverage is wanted:
`battery-120-a-revision-bounded-at-zero-amendments` (bound **0**: the `| 0 =>`
clause as the *whole* loop, no per-round `caseB` at all — size 7, paths 2), and
`battery-090-a-loop-nested-in-a-settled-arm` (the parsed-surface twin of
case 11, size 33, trace `draft`, `review draft`, `again draft`, `draft`).

**Deliberately not rebuildable, and that is the point.** The five guard vectors
(`vector-000` duplicate function names, `vector-003` question budget,
`vector-004` empty panel, `vector-005` served-by on a tool) and every refused
battery entry are **unrepresentable** in the builder — a duplicate function name
is a duplicate Haskell binding, an empty panel is not a `NonEmpty`, served-by on
a tool has no constructor, and the budget refusal needs 8192 questions. tier0
already covers all of them through `Agentic.Guards`. tier1 must not try to reach
them, and `Cases.hs` should say so in a comment so nobody later "fixes" the
builder by weakening it.

---

## 5 Mechanical verification, and what it turned up

Before this spec was written, the elaboration reading above was transcribed into
a small Python interpreter
(`…/scratchpad/elabspec/tr.py`: `chunkExpr`/`Prompt.expr`, `askShape`,
`askPlan`/`bindForm`, `checkMembers` + the verdict monoid, the `revising`
unroll with `checkCont`/`reviseCont`/`finishCont`, `paramCtx`/`checkArgs`/
`callPlan`, `useKindB`/`bindKind`/`bodyBindKind`, the act's weakened slot, and
`WorldSpec.toWorld` + `eventJson`) and replayed against **every checked program
entry of the frozen corpus**.

Result: **63 of 63 world observations reproduce exactly** — all 59 checked
program entries, counting the four two-world entries twice — comparing every
event field (`code`, `addressee`, `scope`, `prompt`, `draw`, `answer`) in order,
plus `billFresh` (event count under `tick`) and `billMemo` (distinct
`(code, addressee, scope, prompt, draw)` keys). Zero mismatches, zero refusals.
That includes the two checks this spec was asked to make first:

* **`semantic-000` under both worlds**: `echo` gives prompts
  `read the file` / `read the file||read the file` / `seen: read the file`;
  `wrap "<" ">"` gives `read the file` / `<read the file>||<read the file>` /
  `seen: <read the file>`, in that order, with codes `text, receipt, receipt`.
  Both match the frozen traces exactly — which confirms that one binding holed
  three times is asked **once** and that the splice reads the *world's answer*,
  not the prompt.
* **A revising entry's trace length**: `semantic-001` gives 3 events in the
  approving world and **9** in the objecting one — `1 draft + 4 reviews +
  3 amendments + 1 log`, i.e. `n + 1 = 4` checks and `n = 3` amendments at bound
  3, which is "check first, revise in the recursive call" and not `n` checks.
  `vector-002` gives 4 and 6 by the same rule at depth two. All match.

Three disagreements between the corpus's **names** and its **contents** surfaced.
None is a semantic disagreement — the frozen numbers are all consistent with the
Lean definitions — but each one misleads a case author, so the case list above
routes around them:

1. **`vector-001-billmemo-below-billfresh` does not exhibit `billMemo <
   billFresh`.** Its reply is `billFresh 3, billMemo 3`. `CorpusGen.lean:158-163`
   builds it from `semSrc0` — the *same* source as `semantic-000` — whose three
   questions are pairwise distinct, so the memo bill cannot be lower. The only
   two entries in the whole corpus where the two bills differ are
   `battery-117` (4 vs 3) and `battery-137` (3 vs 2). Case 6 above is
   `battery-117` for that reason; rebuilding `vector-001` would test nothing that
   `semantic-000` does not already test.
2. **`semantic-001` / `battery-112` never settle "at round two".** Every world in
   the corpus answers verdicts by `const` (no world uses `byPrefix` at
   `verdict` — checked: the corpus's only non-trivial world spec anywhere is
   `semantic-002`'s `byDraw`), so a loop either approves at its **first** check or
   never approves at all. "Settles at round two" is untested by the frozen
   corpus. Recommendation: nothing for week two to fix — the exhausting world
   exercises the `| n+1 =>` and `| 0 =>` clauses and the settling world
   exercises the settle arm — but if the oracle is ever regenerated, one
   `verdict := .byPrefix [("review draft", .object […])] .approve` world would
   pin the mid-loop settle that these two names promise.
3. **`semantic-003-a-flag-carrier-loop` contains no loop.** Its program
   (`CorpusGen.lean:138-142`) is `d <- ask tool "t" "w"; ok <- ask person "o"
   "go?"; if ok { ask tool "a" "went {d}" } else { stop }`. The flag-carrier loop
   the name describes is `semSrc9`, which the corpus froze as
   `battery-121`. Case 4 above therefore takes `semantic-003` for what it is (the
   two-world `if`/`else` pin) and case 12 takes `battery-121` for the flag-carrier
   loop.

One coupling to flag to the core spec: **`PCase`'s tag types are exactly `Bool`
and `VTag`** (§1.6), and `codes` is `null` for every entry with any branching, so
`Plan.hs` needs no more `FinEnum` instances than those two — and the two must
enumerate in Lean's order (`[False, True]`, `Plan.lean:462`; `[approve, object,
declined]`, `Plan.lean:508`) because `costSummary`'s path enumeration reads it.
