# D1 + D8: calls and inputs in the authoring surface

Implementation design for decisions **D1** (expose `function` / `callStmt` / `callV`
through `Agentic.Workflow`) and **D8** (give a program inputs), from
`doc/research/isaac-workflows.md` §6. Owner-approved; this document is what wave 2
implements from. Everything below is derived from the code as it stands on `main`
at the time of writing; no step here re-derives anything.

Absolute paths are used throughout. The files wave 2 touches are:

| file | change |
| --- | --- |
| `/Users/johnw/src/agent-cat/haskell/src/Agentic/Workflow.hs` | all of D1's surface, and D8's `Parameterized` |
| `/Users/johnw/src/agent-cat/haskell/src/Agentic/Builder.hs` | **none** (see §2.6) |
| `/Users/johnw/src/agent-cat/haskell/src/Agentic/Workflow/Do.hs` | **none** (see §3.1) |
| `/Users/johnw/src/agent-cat/haskell/run/Main.hs` | D8's CLI |
| `/Users/johnw/src/agent-cat/haskell/example/Example/Isaac.hs` | the worked example (§9) |
| `/Users/johnw/src/agent-cat/haskell/example/Example/Harden.hs` | registry type only |
| `/Users/johnw/src/agent-cat/haskell/tier1/Cases.hs`, `tier1/Main.hs` | new coverage (§10) |

---

## 1. What is decided here, and what is not

**Decided.** The `W`-level `function` form and its body grammar; the parameter list's
type-level threading; `call` and `call_`; how `workflow` elaborates at a non-empty
function table; the printed shapes, checked against the three frozen call vectors;
and D8's inputs, their CLI, and what `plan`/`cost` say about a program that has them.

**Not decided here** (named only where they touch this work):

* `revising` variants and the unsettled ending — D3/D4's sibling. One interaction:
  `amend` cannot take a call today (§7.4).
* `panelText` — D2's sibling. No interaction: a panel member is a `RawAsk`, and a
  call is not one.
* Exec policies, failure taxonomy, deciders — D5/D6/D7's siblings. One interaction:
  `ask_` (§4.4).

---

## 2. The ground this stands on

Facts established by reading the tree; wave 2 does not need to re-check them.

### 2.1 The machinery already exists at the Builder tier

`/Users/johnw/src/agent-cat/haskell/src/Agentic/Builder.hs` already exports, and
tier1 already pins, every piece D1 needs:

* `Params`, `param`, `noParams`, `ParamCtx`, `ParamCtxGo`, `Fn (..)`, `function`
  (Builder.hs:677–777);
* `Body (..)`, `bindB`/`bindBI`, `bindAsB`/`bindAsBI`, `actB`, `callSB`,
  `answerB`/`answerBI`, `endB` (Builder.hs:789–886);
* `Arg (..)`, `argName`/`argNameI`, `argWords`, `Args (..)` with `ANil` and `(:>)`
  (Builder.hs:620–668);
* `callV` (Builder.hs:604), `callStmt` (Builder.hs:975);
* `SomeFn (..)`, `program` (Builder.hs:1288–1303).

None of it changes. D1 is **sugar only**, in the module's own sense: every new
combinator in `Agentic.Workflow` is an application of one of the above.

### 2.2 The three frozen call vectors

All three are already rebuilt in `/Users/johnw/src/agent-cat/haskell/tier1/Cases.hs`
at the **Builder** tier (`module000` at Cases.hs:404, `battery144` at Cases.hs:444,
`battery147`), compared **exactly**. The research doc's "tier1 gains coverage of
three frozen cases" means the *authoring* surface cannot reach them; tier1 already
reaches them one tier down. §10 says what new coverage is actually available.

Their printed shapes, from `/Users/johnw/src/agent-cat/test/corpus/`:

* **`module-000-…`** — one function `lib.drafted` with one `text` param `goal`,
  body one bind, `answer d`. `main`: an annotated bind (`ann: "text"`), a bind
  whose source is `{"call": {"fn": "lib.drafted", "args": [{"name": {"x": "lib.guide"}}]}}`,
  an act whose prompt is **four** chunks (`"use "`, interp `x`, `" "`, `"hello"`),
  `stop`. Reply: `size 4`, `level pipeline`, `fnAsks [["lib.drafted",1]]`,
  `blockAsks 3`, `askNodes 3`, `codes [text,text,receipt]`.
* **`battery-144-…`** — **three** declared functions (`mk`, `judged`, `applied`),
  only `applied` called, and called as a *statement*
  (`{"callStmt": {"fn": "applied", "args": [{"name": {"x": "d"}}]}}`). `applied`'s
  body is a single act and its `answer` is `null`. Reply: `size 3`,
  `fnAsks [["mk",1],["judged",1],["applied",1]]` — **the table prices every
  declared function, called or not** — `blockAsks 2`, `codes [text,receipt]`.
* **`battery-147-…`** — one function `f` answering a `flag`, never called; `main`
  is `empty`. Reply: `size 1`, `level batch`, `fnAsks [["f",1]]`, `askNodes 0`,
  `codes []`.

Dotted names (`lib.drafted`, `lib.guide`) are ordinary `Text` in `RawFn`/`RawBind`.
Nothing in the surface restricts a name's spelling; the surface *generates* binding
names (`b0`, `b1`, …) and takes function and parameter names from the author.

### 2.3 How a call is priced

`/Users/johnw/src/agent-cat/haskell/src/Agentic/Guards.hs`:

* `fnTable` (Guards.hs:107) folds the declaration list left to right, each entry
  priced `bodyAsks` **against the table before it**;
* `callAsks` (Guards.hs:101) is `lookup`, and **an unknown callee costs zero**;
* `rhsAsks fns (RhsCall f _ _) = callAsks fns f` — **the arguments are ignored**
  (Guards.hs:120), and `bodyAsks` treats `BodyCallS` the same way (Guards.hs:128).

So, to answer the question posed in the brief directly: **Lean's checker does not
price function parameters at all.** A parameter is a binding nobody asked for; it
costs nothing. What a call costs is the callee's own `bodyAsks`, computed against
the strictly-earlier table. Two consequences carry into the design:

1. the table must be in dependency order, or a call prices `0` and the printed
   program is one Lean refuses (§5.2);
2. a duplicated statement replaced by a call to a function containing it costs
   exactly the same (§8).

`guardCheck` does **not** catch a call naming a later or absent function — that is
the typing judgment, deliberately not ported (Guards.hs:15–23). §5.2 adds the check.

### 2.4 Every static fold is context-polymorphic

In `/Users/johnw/src/agent-cat/haskell/src/Agentic/Plan.hs`, `level` (771),
`size` (785), `askNodes` (800), `codes` (817) and `costM` (863) all have the shape
`Plan g a -> …`. They are structural over the term and never build an `Env`.

**Therefore no fold ever needs a probe environment.** A `Fn`'s own
`fnPlan :: Plan (ParamCtx ps) (El r)` can be folded directly if a per-function
report is ever wanted, and a parameterized `main` — had we one — would fold with no
environment either. The only thing that needs a closed context is *execution*:
`runPlanIO :: WorldIO -> Plan '[] a -> IO (a, Trace)` (Exec.hs:260) starts at `ENil`.

### 2.5 `graft` adds no node

`graft` (Plan.hs) keeps a `PAsk`/`PAskC` and recurses; at `PRet` it hands off to the
continuation. So `callStmt f as rest` — `graft (callPlanOf f as) (Cont …)` — produces
the *same node shape* as writing the callee's statements inline. §8 turns this into
the cost statement for the worked example.

### 2.6 Builder needs no change at all

The one thing `Agentic.Workflow` needs from Builder that Builder does not export is
the parameter list's printed names, for a body's `Live`. Builder exports
`Params (..)`, so `PCons`'s `Proxy n` and its `KnownSymbol n` context are in scope
and `Agentic.Workflow` can walk the GADT itself (§3.2, `paramNames`). Wave 2 must
therefore leave `Builder.hs` **byte-identical**, which is what makes "no existing
tier1 entry can change" a fact rather than a hope.

---

## 3. D1, part one: a function body is a `W` block

### 3.1 The stage

`Stage` gains one constructor and `Res` one equation:

```haskell
data Stage
  = Open Scope
  | Review Code Scope
  | Amending Code Scope
  | Body Code Scope          -- NEW: a function body, at its result kind

type family Res (i :: Stage) = (r :: Type) | r -> i where
  Res ('Open s)      = Blk s
  Res ('Review c s)  = Clauses c s
  Res ('Amending c s) = Amendment c s
  Res ('Body r s)    = B.Body s r          -- NEW
```

`Res`'s injectivity survives: `B.Body s r` is a fourth distinct type constructor, and
both indices are recoverable from it.

**Naming note.** The promoted `'Body` and Builder's type `Body` would clash in the
type namespace. `Agentic.Workflow` imports Builder's `Body` only qualified, so the
stage constructor is `Body` and Builder's type is written `B.Body` — consistent with
how every other Builder entry point is written in that module.

`Agentic.Workflow.Do` needs **no change**: `bindW`/`thenW` are already
stage-polymorphic, so `W.do` works in a body the moment the `Step` instances exist.

The body's runner, beside `runW` and `runRev`:

```haskell
-- | The body a function's @do@ finally is, under the names its parameters are.
runBody :: Live -> W ('Body r s) j Term -> B.Body s r
runBody live (W f) = f live absurdTerm
```

### 3.2 The parameter list — the hard half, spelled out

This is what the review calls the hard half, so here are the actual types.

**Why the author names parameters.** `Params`'s cons carries `Fresh n acc`
(Builder.hs:696). The authoring surface pushes every scope entry as
`An c = '("", c)`, and `Fresh "" '[ '("", c) ]` reduces to Builder's own
`TypeError` — so a two-parameter function is *unrepresentable* if the surface keeps
generating anonymous entries. Two ways out: generate distinct type-level symbols
(needs a `Nat`→`Symbol` encoding, which GHC has no primitive for), or have the author
name them. **The author names them**, and it is not a concession:

* a parameter's name is *printed* in the function's signature (`params: [["goal","text"]]`
  in all three vectors) and again in every hole of the body, so unlike a binding's
  name it is part of what a reader of the printed program sees;
* the function's own name is already author-given, for the same reason;
* D8 needs a name to bind an input by at the command line — `--input-arg subject=…`
  has nothing to say otherwise.

The one entry point:

```haskell
-- | One parameter, named and kinded: @takes \@"goal" Text@.
--
-- The name is a type-level 'Symbol' because that is what makes two parameters of
-- one name a compile error ('Fresh'), and it is the very 'Text' the printed
-- signature and every hole in the body carry.
takes ::
  forall n c cs acc s hs.
  (KnownSymbol n, Fresh n acc) =>
  Answer c ->
  Params cs ('(n, c) ': acc) s hs ->
  Params (c ': cs) acc s (V ('(n, c) ': acc) c, hs)
takes a rest = withAnswer a (B.param @n @c rest)

-- | The end of a parameter list. Re-exported from "Agentic.Builder".
noParams :: Params '[] acc acc ()
```

`withAnswer :: Answer c -> (KnownCode c => r) -> r` already exists in
`Agentic.Workflow` (unexported) and supplies the `KnownCode c` that `B.param` wants.
`Answer` is the surface's own four-constructor kind vocabulary (`Text`, `Flag`,
`Verdict`, `Receipt`), so a parameter list reads in the same words as
`answering`/`annotated`.

Each `takes` is a function from *the rest of the list* to *the whole list*, so lists
compose with `(.)` and end at `noParams`:

```haskell
(takes @"correctness" Text . takes @"haskell" Text . takes @"claims" Text) noParams
```

**Currying the handles.** Builder hands a body its handles as a nested tuple ending
in `()` (`paramHandles`, Builder.hs:723). A six-parameter tuple pattern is not
something to ask an author for, so the surface curries it:

```haskell
-- | The handles a parameter list hands its body, as a curried function.
--
-- The instance head is @(V h c, hs)@ rather than @(a, hs)@ so that the family
-- reduces only on a real handle tuple, and so that D8's input tuples (which are
-- 'Text's) take their own instance rather than this one.
class Curries (hs :: Type) where
  type Curried hs (r :: Type) :: Type
  applyTo :: Curried hs r -> hs -> r

instance Curries () where
  type Curried () r = r
  applyTo r () = r

instance Curries hs => Curries (V h c, hs) where
  type Curried (V h c, hs) r = V h c -> Curried hs r
  applyTo f (v, hs) = applyTo (f v) hs
```

`hs` is concrete the moment the parameter list is written, so `Curried hs r`
reduces before the body is elaborated and each lambda binder's type is known — which
is what keeps `[wf|{goal}|]`'s inference eager, exactly as the `Step` instances'
head-dispatch discipline does elsewhere in the module.

**The names a body is live under.** A body has no `known here` (`RawBodyStmt` has
no such constructor), so `Live` is used only for `genName`'s depth. It is seeded
with the parameter names, innermost first — the parameters are pushed in source
order, so the reverse of the printed list:

```haskell
-- | The parameter names, in source order. "Agentic.Builder" computes the same
-- list for the printed signature; walking the GADT here is what keeps that
-- module untouched.
paramNames :: Params ps acc s hs -> [Text]
paramNames = \case
  PNil -> []
  PCons p _ rest -> T.pack (symbolVal p) : paramNames rest
```

### 3.3 `function`

```haskell
-- | A function: a name, a parameter list, and a body that is a straight-line
-- @W.do@ block over exactly those parameters.
--
-- > libDrafted :: Fn '[ 'CodeText] 'CodeText
-- > libDrafted = function "lib.drafted" (takes @"goal" Text noParams) \goal -> W.do
-- >     d <- ask (model "author") [wf|draft: {goal}|]
-- >     answer d
--
-- The result kind is read off the body's terminal — @answer x@ at @x@'s kind,
-- @done@ at @receipt@ — so nothing has to be said twice.
function ::
  forall r ps s hs.
  (KnownCode r, Codes s ~ ParamCtx ps, Curries hs) =>
  Text ->
  Params ps '[] s hs ->
  Curried hs (W ('Body r s) ('Body r s) Term) ->
  Fn ps r
function nm ps body =
  B.function nm ps (\hs -> runBody (reverse (paramNames ps)) (applyTo body hs))
```

`Codes s ~ ParamCtx ps` is Builder's own constraint; both sides reduce to the same
concrete list once the parameter list is written, so it discharges by reduction and
never appears in an author's error.

`-Wall` includes `-Wmissing-signatures`, so every top-level `Fn` binding will carry
one, and it is written with the promoted codes:
`reviewReport :: Fn '[ 'CodeText, 'CodeText, 'CodeText, 'CodeText, 'CodeText, 'CodeText] 'CodeAck`.
Wave 2 should expect that and not try to sugar it — `Answer`'s constructors are
values and cannot stand in a type.

### 3.4 The two terminals of a body

```haskell
-- | @answer x@ — the body's value, at the kind the handle carries, which is the
-- function's declared result.
answer :: forall h s c j. KnownIx h s => V h c -> W ('Body c s) j Term
answer v = W (\_ _ -> B.answerB @h @s v)

-- | The end of a @-> receipt@ body: it answers nothing, and the caller gets a
-- receipt. Not 'stop': a block that stops ends the workflow, and a body that is
-- done hands control back to its caller.
done :: W ('Body 'CodeAck s) j Term
done = W (\_ _ -> B.endB)
```

`stop` stays `'Open`-only, deliberately: overloading it would make one word mean
"the workflow ends" in one place and "this procedure returns" in another. A `done`
written in a workflow block is `Couldn't match ‘Open’ with ‘Body’`; a `stop` written
in a body is the same error the other way.

`done` in a value-returning body is `Couldn't match ‘CodeText’ with ‘CodeAck’`, which
is the right refusal (a `-> text` function must answer something).

### 3.5 Statements become values, so they work at both stages

`act` is today a `W` value fixed at `'Open` (Workflow.hs:760). A function body needs
it too — `battery-144`'s `applied` is a body that *is* one act, and the worked
example's report tail is an act. Rather than a class over stages, `act` becomes a
**statement value with one `Step` instance per stage**, which is exactly the
module's stated discipline ("every instance dispatches on two heads and nothing
else — the statement's type constructor and the stage's"):

```haskell
-- | A statement-position question. It binds nothing and its answer is a receipt.
newtype Acting (s :: Scope) = Acting (Ask s)

act :: Party p -> Words s -> Acting s
act p w = Acting (ask p w)

-- | A statement-position call. Only a @-> receipt@ function may stand here,
-- which is the type, and — unlike an act — it adds __no__ context slot. That
-- contrast is what @battery-144@ pins.
data Calling (s :: Scope) where
  Calling :: Fn ps 'CodeAck -> Args s ps -> Calling s

call_ :: Fn ps 'CodeAck -> Args s ps -> Calling s
call_ = Calling
```

with four instances:

```haskell
instance (s' ~ s, j ~ 'Open s, a ~ ()) => Step (Acting s') ('Open s) j a where
  step _ live (Acting q) k = B.act q (k () live)

instance (s' ~ s, j ~ 'Body r s, a ~ ()) => Step (Acting s') ('Body r s) j a where
  step _ live (Acting q) k = B.actB q (k () live)

instance (s' ~ s, j ~ 'Open s, a ~ ()) => Step (Calling s') ('Open s) j a where
  step _ live (Calling f as) k = B.callStmt f as (k () live)

instance (s' ~ s, j ~ 'Body r s, a ~ ()) => Step (Calling s') ('Body r s) j a where
  step _ live (Calling f as) k = B.callSB f as (k () live)
```

Every existing use of `act` in `Example.Harden` and `Example.Isaac` is a `W.do`
statement, so the type change is source-compatible: the `Step (W i' j' a')` instance
that used to carry it is replaced by the `Step (Acting s')` one, and nothing else
about those modules moves.

### 3.6 The body's binding statements

Three more `Step` instances, each the exact mirror of its `'Open` twin with
`B.bindI`/`B.bindAsI` replaced by `B.bindBI`/`B.bindAsBI`:

```haskell
-- | @x <- ask …@ in a body: a bare question is a text question, here as there.
instance (s' ~ s, j ~ 'Body r (An 'CodeText ': s), a ~ V (An 'CodeText ': s) 'CodeText)
  => Step (Ask s') ('Body r s) j a where
  step mn live q k = B.bindBI x (B.one @'CodeText q) (k (V x VHere) (x : live))
    where x = fromMaybe (genName live) mn

-- | @x <- panel […]@, @x <- confirm …@, @x <- call f …@, @x <- ask … `answering` c@.
instance (s' ~ s, j ~ 'Body r (An c ': s), a ~ V (An c ': s) c)
  => Step (Rhs s' c) ('Body r s) j a where
  step mn live rhs k = B.bindBI x rhs (k (V x VHere) (x : live))
    where x = fromMaybe (genName live) mn

-- | @x : c <- …@ in a body.
instance (s' ~ s, j ~ 'Body r (An c ': s), a ~ V (An c ': s) c)
  => Step (Ann s' c) ('Body r s) j a where
  step mn live (Ann sc rhs) k = B.bindAsBI sc x rhs (k (V x VHere) (x : live))
    where x = fromMaybe (genName live) mn
```

The index-level Builder forms (`bindBI`, `bindAsBI`) leave the pushed scope entry a
free type variable, which is what lets the surface push `An c` entries onto a scope
whose *parameter* entries carry real symbols. `Fresh` is not consulted there and
must not be: parameters and generated binding names live in one namespace, and §6.3
is how that namespace is kept clean.

`named` needs no new instance: `Step (Nm st)` is already stage-polymorphic.

### 3.7 What a body must refuse

A body is a straight line (`RawBodyStmt` has three constructors and no others).
Two refusals are worth a message rather than a missing instance, following the
module's precedent at `'Amending`:

```haskell
instance TypeError ('TL.Text "a function body is a straight line: it has no bounded \
                             \revision, no branch and no `known here` — those belong \
                             \to the workflow that calls it")
  => Step (Loop c' s') ('Body r s) j a
```

and the mirror for `Acting`/`Calling` at `'Review` and `'Amending` (an act inside a
revision is not expressible in `RawRhs`):

```haskell
instance TypeError ('TL.Text "a bounded revision reviews first — `verdict <- panel […]` \
                             \— and then amends, and has no other statement")
  => Step (Acting s') ('Review c s) j a
```
(and the same for `Calling`, and for both at `'Amending`).

`ifThenElse`, `caseVerdict`, `knownHere` and `stop` stay typed at `'Open` and give
GHC's own `Couldn't match ‘Open’ with ‘Body’`, which names the right thing.

---

## 4. D1, part two: calls

### 4.1 A value call needs no new machinery at all

`B.callV f as :: Rhs s r`, and the surface already binds an `Rhs` at three stages.
So:

```haskell
-- | A value call: the callee's questions, inlined at the call site in body order,
-- with the caller's arguments in their prompts. No node is added.
call :: Fn ps r -> Args s ps -> Rhs s r
call = B.callV
```

and `x <- call drafted (arg guide :> noArgs)` works in a workflow block, in a
function body (§3.6) and **as a review clause** — `verdict <- call reviewTier (arg patch :> noArgs)`
inside `revising` — because the `'Review` stage's `Rhs` instance already accepts any
`Rhs (An c ': s) 'CodeVerdict`. That last one is G2's payoff in one line: incite's
shared review tier becomes one `Fn` three workflows call.

### 4.2 Arguments

An argument is either a name in the caller's scope (printed `ArgName`) or literal
words (printed `ArgLit`). The surface overloads one word for both, mirroring `Says`:

```haskell
-- | What may stand as one argument at a call site.
--
-- __Not 'Says'.__ A handle passed as an argument prints as a /name/
-- (@{"name": {"x": "d"}}@), where the same handle in a prompt prints as an
-- @interp@ chunk. The two classes therefore differ in exactly the instance that
-- matters, and reusing 'Says' here would silently pass a binding by its rendered
-- text instead of by reference.
class Gives a (s :: Scope) (c :: Code) where
  arg :: a -> Arg s c

-- | A binding in scope, which must answer the parameter's kind exactly.
instance KnownIx h s => Gives (V h c) s c where
  arg = B.argName

-- | A @define@ written as a fence, elaborated in the /caller's/ bindings, so a
-- hole in it reads the caller's names.
instance (s ~ s', c ~ 'CodeText) => Gives [Piece s'] s c where
  arg = B.argWords

-- | A @define@ that is a string.
instance c ~ 'CodeText => Gives Text s c where
  arg t = B.argWords [lit t]
```

The kind equalities sit in the context rather than the head, so a `Text` passed
where a `verdict` parameter stands is
`Couldn't match ‘'CodeVerdict’ with ‘'CodeText’` rather than a missing instance.

The list is Builder's, re-exported, with one synonym for symmetry with `noParams`:

```haskell
Args ((:>), ANil)     -- re-exported
noArgs = ANil
```

so a call site reads

```haskell
call_ reviewReport
  (arg correctness :> arg haskell :> arg claims :> arg failures :> arg braids :> arg cuts :> noArgs)
```

A variadic `call_ f a b c …` was considered and rejected for wave 2: it needs a
type family over the parameter list whose result is a function type, and it buys
only the `:>`s. The list form is Builder's own spelling and reads as a list.

### 4.3 What cannot be a call

* **A panel member** — `RhsPanel` holds `RawAsk`s. Correct, and no change.
* **An amendment** — `amend :: Ask (…) -> W ('Amending c s) j Term` takes an `Ask`,
  though `SrcRevising` carries a `RawRhs` and could hold a call. Generalizing
  `amend` to an `Rhs` (or overloading it) is a two-line change that belongs with
  the D3/D4 sibling, who owns `revising`. **D1 does not need it and must not do
  it**, to keep the two waves from editing the same lines.
* **A recursive call** — a `Fn` value must exist before it is applied. Haskell's
  `where`-group recursion would loop at build time rather than type-error; §5.2's
  table check catches the honest version of the mistake.

### 4.4 Interaction with the concurrent `ask_` wave

The sibling wave adds `ask_` to `Agentic.Workflow`. Under this design the statement
forms are values, not `W`s, so:

* if `ask_` is a **new name for the statement-position ask**, it should be
  `ask_ :: Party p -> Words s -> Acting s` — the same value `act` produces — and it
  then works in a function body for free;
* if `ask_` is something else (a statement-position ask with a new field), it should
  still return `Acting s` rather than `W ('Open s) ('Open s) ()`, or it will be the
  one statement that cannot appear in a body.

`call_` is named for that symmetry: `X` binds, `X_` stands as a statement.

**A function body ending in an act** is the ordinary case, and the plan is
`askNode @'CodeAck a (weakenP (bodyPlan rest))` — the same node an inline act builds
(§2.5). Nothing about `ask_`'s new `ExecSettings` fields interacts with calls: a
call adds no node, so whatever an act carries, it carries identically inside a
function and outside one.

---

## 5. D1, part three: the function table

### 5.1 `defining`

```haskell
-- | A whole program: the function table in declaration order, and the workflow.
--
-- > reviewLiteProgram = defining [SomeFn reviewReport] W.do …
defining :: [SomeFn] -> W ('Open '[]) ('Open '[]) Term -> Program
defining fns b = case tableProblem prog of
  Just msg -> error (T.unpack msg)
  Nothing -> prog
  where
    prog = B.program fns (runW [] b)

-- | A whole program with no functions — 'defining' at the empty table, which is
-- what it has always been.
workflow :: W ('Open '[]) ('Open '[]) Term -> Program
workflow = defining []
```

`workflow` keeps its type and its meaning, so `Example.Harden`, `Example.Isaac` and
`tier1` see no change until they choose to declare a function.

### 5.2 The two checks `defining` owes

A `Fn` is a Haskell value, so a *call* cannot name something that does not exist.
But two things about the *table* are not decidable from the call sites, and both
produce a printed program the language refuses while GHC is content:

1. **a duplicate name** — Guards' `DupFunction`;
2. **a callee that is not declared strictly earlier** — `callAsks` answers `0` for
   an unknown name (Guards.hs:101), so the program silently prices wrong and Lean
   refuses it as `unbound`. This is the one new obligation `defining` creates:
   *every function you call must be in the list, and before its callers.*

`defining` checks both, on a CAF, with `error` — the same idiom `panel []` already
uses (Workflow.hs:429), so it fires the first time anything touches the program:

```haskell
-- | @Nothing@ if the table is one the language accepts: no name twice, and every
-- call naming an entry that precedes it. Neither is decidable from the 'Fn'
-- values — a call names a Haskell binding, and the /list/ is what says when it
-- was declared.
tableProblem :: Program -> Maybe Text
```

It walks `progRawOut`: `RhsCall`, `BodyCallS`, `RawCallStmt`, and the `review`/`amend`
of a `SrcRevising`, through every arm. Messages, in the module's register:

* `"two functions answer to one name: \"applied\""`
* `"\"a\" calls \"b\", which defining lists after it — a function may call only a function declared before it, so that the table can be priced"`
* `"the workflow calls \"b\", which defining was not given — list it, or the printed program names a function that does not exist"`

`guardCheck` is deliberately *not* called here: it answers a different question (which
of five refusals `checkProgram` fires first), and `PanelEmpty`/`ServedBy` are already
unrepresentable or already `error`ed at their own site.

---

## 6. The printed shapes, against the three frozen vectors

Written in the new surface, each producing the frozen `Raw` up to alpha and
position — which is the comparison `tier1` already makes for the two walked examples.

### 6.1 `module-000`

```haskell
libDrafted :: Fn '[ 'CodeText] 'CodeText
libDrafted = function "lib.drafted" (takes @"goal" Text noParams) \goal -> W.do
    d <- ask (model "author") [wf|draft: {goal}|]
    answer d

module000 :: Program
module000 = defining [SomeFn libDrafted] W.do
    guide <- ask (tool "cat") [wf|style guide|] `annotated` Text
    x     <- call libDrafted (arg guide :> noArgs)
    act (tool "t") [wf|use {x} {greeting}|]
    stop
  where
    greeting :: Text
    greeting = "hello"
```

prints: `fns: [{name: "lib.drafted", params: [["goal","text"]], result: "text",
body: [bind b1 ← ask model "author" ["draft: ", interp goal]], answer: "b1"}]`;
`main: bind "b0" ann=text ← ask tool "cat" ["style guide"]; bind "b1" ann=null ←
call lib.drafted [name b0]; act tool "t" ["use ", interp b1, " ", "hello"]; empty`.

Four chunks in the act, unfused, because `{greeting}` is a `define` and `Says Text`
contributes a chunk of its own — the frozen entry's exact shape. Under `canonProgram`
the frozen `lib.guide`/`x`/`goal`/`d` and the surface's `b0`/`b1`/`goal`/`b1` both
become `c0`/`c1`/`c0`/`c1`; `fnName` is not canonicalized, so `"lib.drafted"` must be —
and is — written exactly.

### 6.2 `battery-144`

```haskell
fnMk :: Fn '[ 'CodeText] 'CodeText
fnMk = function "mk" (takes @"goal" Text noParams) \goal -> W.do
    d <- ask (model "author") [wf|draft: {goal}|]
    answer d

fnJudged :: Fn '[ 'CodeText] 'CodeVerdict
fnJudged = function "judged" (takes @"patch" Text noParams) \patch -> W.do
    v <- ask (model "judge") [wf|judge: {patch}|] `answering` Verdict
    answer v

fnApplied :: Fn '[ 'CodeText] 'CodeAck
fnApplied = function "applied" (takes @"patch" Text noParams) \patch -> W.do
    act (tool "apply") [wf|apply: {patch}|]
    done

battery144 :: Program
battery144 = defining [SomeFn fnMk, SomeFn fnJudged, SomeFn fnApplied] W.do
    d <- ask (tool "t") [wf|w|] `annotated` Text
    call_ fnApplied (arg d :> noArgs)
    stop
```

`judged` uses `answering Verdict` and not `annotated`, because the frozen bind's
`ann` is `null`. `applied`'s `answer` field is `null`, which is what `done` prints.
The table is `[mk, judged, applied]` in declaration order and `fnAsks` reports all
three at `1` each, though only `applied` is called — the list, not the call graph,
is what is printed and priced. `blockAsks` is `1 + callAsks "applied" = 2`.

### 6.3 `battery-147`

```haskell
fnF :: Fn '[ 'CodeText] 'CodeFlag
fnF = function "f" (takes @"p" Text noParams) \p -> W.do
    x <- confirm (model "m") [wf|{p}|]
    answer x

battery147 :: Program
battery147 = defining [SomeFn fnF] stop
```

`main` is `stop` on its own — not a `W.do` block — and prints `empty`. `level` is
`batch` because main's plan is a bare `PRet`: an uncalled function contributes no
node. (Had `f` been called, the level would be `pipeline`; see §8.)

---

## 7. What the surface still cannot say, and why that is right

* **A body has no branch, no loop, no `known here`.** `RawBodyStmt` has three
  constructors. A function is a reusable *sequence of questions*, not a reusable
  decision — which is exactly why G1's cheap proposal mitigates the duplicated tail
  without becoming a joining conditional.
* **No recursion.** A `Fn` value must exist before it is applied, and §5.2 refuses
  the table order that would fake it.
* **A literal argument is text.** `RawArg` is `ArgName | ArgLit Prompt`, so the only
  non-name argument is words. A `flag` or `verdict` parameter can be filled only by a
  binding.
* **A panel member and an amendment are asks**, not calls (§4.3).

---

## 8. What calling costs, and what it changes

Three statements wave 2 can rely on, each with its evidence.

**Cost is unchanged.** `rhsAsks`/`bodyAsks` price a call at the callee's own ask
count with the arguments ignored (§2.3), so replacing a duplicated statement by a
call to a function containing it leaves `blockAsks`, `fnAsks`'s total and every path
in `costM` where they were. The duplicated tail in *both* arms pays once per arm,
before and after.

**Shape is unchanged.** `graft` keeps the callee's `PAsk`/`PAskC` nodes and splices
the caller's continuation at the callee's `PRet` (§2.5), and `callStmt` adds no
context slot. So `size`, `askNodes` and `codes` are the same term-level numbers.

**`level` can move, from `batch` to `pipeline`.** This is the one non-obvious
consequence and wave 2 must not be surprised by it. `askNode` decides `PAskC`
(closed) versus `PAsk` (open) from the *chunks* at build time, and `level` joins
`Pipeline` at every `PAsk` (Plan.hs:771). A parameter hole is an `interp` chunk, so a
prompt that was closed inline — all literals and defines — becomes open the moment
it is moved into a function and the literal becomes an argument. A `batch` program
can therefore become `pipeline` under this refactor, with no other number moving.
The corpus already carries the shape: `battery-147`'s `f` has an open prompt and the
entry is `batch` only because `f` is never called.

---

## 9. The worked example: `review-lite`'s duplicated tail

Today (`/Users/johnw/src/agent-cat/haskell/example/Example/Isaac.hs`,
`reviewLiteProgram` at Isaac.hs:1074) the closing act is written twice, once per arm
of the router's `if`, differing in exactly one hole: the then-arm splices the
`haskell` binding, the else-arm splices the `noHaskellEdits` define.

With D1 the tail is one definition and one line per arm:

```haskell
-- | @review-lite@'s fold, as a procedure both arms of the router call.
--
-- The six blocks are parameters, so the two arms differ in one argument and can
-- no longer differ in anything else: the report's order, its brief and its tool
-- are one text now, where they were two.
reviewReport ::
  Fn '[ 'CodeText, 'CodeText, 'CodeText, 'CodeText, 'CodeText, 'CodeText] 'CodeAck
reviewReport =
  function
    "review-lite.report"
    ( takes @"correctness" Text
        . takes @"haskell" Text
        . takes @"claims" Text
        . takes @"failures" Text
        . takes @"braids" Text
        . takes @"cuts" Text
        $ noParams
    )
    \correctness haskell claims failures braids cuts -> W.do
      act (tool "write-report") [wf|
          {reviewReportBrief}
          {correctness}
          {haskell}
          {claims}
          {failures}
          {braids}
          {cuts}|]
      done

reviewLiteProgram :: Program
reviewLiteProgram = defining [SomeFn reviewReport] W.do
    …
    if touchesHaskell
      then W.do
        haskell <- ask (model "haskell" `servedBy` "fable") [wf|{haskellHouseLens}{subject}|]
        call_ reviewReport
          (arg correctness :> arg haskell :> arg claims :> arg failures :> arg braids :> arg cuts :> noArgs)
        stop
      else W.do
        call_ reviewReport
          (arg correctness :> arg noHaskellEdits :> arg claims :> arg failures :> arg braids :> arg cuts :> noArgs)
        stop
```

`noHaskellEdits :: Text` (Isaac.hs:462) reaches the second parameter through
`Gives Text s 'CodeText` and prints as an `ArgLit`, which is the literal-argument
form `RawArg` already has.

**Numbers.** `size 13`, `askNodes 10`, `minFold 8 / maxFold 9 over 2 paths` are all
unchanged by §8's first two statements. `level` stays `branch` (the `if` decides
it). The printed program changes — the haddock's `> level branch, size 13, askNodes 10`
block stays true, and the surrounding prose about the duplicated tail must be
rewritten, since the gap it documents is the one this closes.

---

## 10. D8: a program's inputs

### 10.1 `Params` is the wrong mechanism for `main`, and here is why

The research doc proposes "`main` is a function of its arguments — the same `Params`
machinery". It cannot be, and the reason is structural rather than a matter of
effort:

* `RawProgram` is `progFns` and `progMain :: Raw`. **There is nowhere to print
  `main`'s parameters.** A `Raw` block declares no signature.
* A `main` block whose prompts hole a name no printed binder introduces is a program
  Lean refuses (`unbound`). So a parameterized `main` would print an illegal program.
* Making it legal means a new field on `RawProgram`, which is a codec change, a
  tier0 round-trip change and a corpus question — precisely the "no-Raw" boundary
  the wave plan draws.
* `main` also cannot be a `Fn`: a `Fn`'s body is a straight line, and `review-lite`
  branches.

### 10.2 An input is a `define`, and a `define` is not a binding

The language already has a construct for author-supplied text that reaches a prompt
as data and leaves no node behind: the `define`. `module-000`'s `lib.greeting`
splices as its own literal chunk and appears nowhere else in the printed program;
`Example.Harden`'s `spec`, `verdictSpec` and `flagSpec` are Haskell `Text` bindings
spliced by `Says Text s`.

**So an input is a define supplied at run time, and a program with inputs is a
Haskell function of them.** This needs no type-level machinery at all — a define
never enters a scope, is never `Fresh`-checked, and cannot collide with a binding
name — and it has the property the doc actually asked for: the operator's text
arrives as *data* rather than as an *answer*, and the program you print is the
program you run.

The surface's whole contribution is to carry the input *names* and *arity* beside
the function, so a command line can bind them:

```haskell
-- | A program that needs inputs before it is a program.
--
-- Each input is a @define@ the caller supplies: a 'Text' the program splices into
-- prompts exactly as it splices a define written in the source. There is no
-- type-level machinery here because there is nothing to check — a define is not a
-- binding, so nothing may shadow it and nothing may read it out of scope.
data Parameterized = Parameterized
  { -- | the names, in source order, that @--input-arg@ binds by
    inputNames :: [Text],
    -- | the program, given one text per name in that order
    supply :: [Text] -> Either Text Program
  }

-- | The inputs a program takes. The type index counts them, so the body may be
-- an ordinary curried Haskell function.
data Ins (hs :: Type) where
  INil :: Ins ()
  ICons :: Text -> Ins hs -> Ins (Text, hs)

noInputs :: Ins ()
noInputs = INil

input :: Text -> Ins hs -> Ins (Text, hs)
input = ICons

instance Curries hs => Curries (Text, hs) where
  type Curried (Text, hs) r = Text -> Curried hs r
  applyTo f (t, hs) = applyTo (f t) hs

-- | @taking (input "subject" noInputs) \subject -> workflow W.do …@
taking :: Curries hs => Ins hs -> Curried hs Program -> Parameterized
```

`supply` returns `Left` on the wrong number of texts, which the CLI is the only
caller of and which it turns into a usage message.

Written out, `review-lite`'s opening leaf disappears:

```haskell
reviewLite :: Parameterized
reviewLite = taking (input "subject" noInputs) \subject ->
  defining [SomeFn reviewReport] W.do
    correctness <- ask (model "correctness" `servedBy` "fable") [wf|
        {correctnessLens}
        {subject}|]
    …
```

`{subject}` resolves through `Says Text s` at every scope in the block, including
inside the `if` arms — one more reason the define route works where a scope-indexed
`Words s` would not.

**Inputs are text.** A flag input would have to be an `Arg` at flag kind, which
`RawArg` cannot express, or a `Says` instance at flag, which the language refuses on
purpose. An author who wants to select between two *programs* on a boolean writes an
ordinary Haskell function; that is not what `--input` is for, and the CLI need not
know about it.

### 10.3 The command line

Three flags, each unambiguous on its own:

```
--input FILE            the sole input, read from a file
--input-file NAME=FILE  that input, read from a file
--input-arg NAME=VALUE  that input, inline
```

`--input FILE` is the common case and takes no `NAME=`, so a path containing `=`
is never misread; the two named forms split on the first `=`, and no declared name
contains one. All three are repeatable except `--input`, which names one input by
being the only one.

They are accepted by **all three verbs** — `plan`, `cost` and `run` — because
`plan --raw` prints prompts and an operator pricing a run wants to price the run
they will make.

The registry becomes a sum, so that `hardenProgram` and `helloProgram` keep their
type and `tier1` is untouched:

```haskell
data Example = Fixed Program | Needs Parameterized

examples :: [(Text, Example)]
exampleNames :: [Text]
lookupExample :: Text -> Maybe Example
```

Resolution, and every refusal it makes (all exit `1`, the usage code):

| situation | message |
| --- | --- |
| an input flag on a `Fixed` example | `harden takes no input` |
| `--input FILE` where the example takes ≠ 1 input | `X takes 2 inputs (subject, budget); name them with --input-arg or --input-file` |
| an unknown name | `X has no input named 'q'; it takes subject` |
| a name bound twice | `input 'subject' was given twice` |
| a file that will not read | `could not read PATH: …` |
| a missing input, at `run` | `run needs every input: 'subject' was not given` |

A file's contents are read as UTF-8 and **one trailing newline is stripped**, so that
an input from a file splices like a define written in the source — `[wf|…|]` produces
no trailing newline either, and a silent blank line in a prompt is the kind of
difference this repository exists to prevent.

### 10.4 What `plan` and `cost` print

Every static fold is structural over the term (§2.4) and no fold reads a prompt, and
an input reaches the term only as literal chunks inside prompts. **Therefore
`level`, `size`, `askNodes`, `codes`, `costSummary`, `blockAsks` and `fnAsks` are the
same for every input**, and `plan`/`cost` can answer without one:

```
review-lite, as elaborated:

  inputs    subject (text) — not given; the folds below do not depend on it
  level     branch
  size      12
  …
```

and, when given:

```
  inputs    subject (text) = 4.1 kB from ./commit.diff
```

— the name, the source and the size, never the value, which can be a whole diff.

So the answer to "do the folds need a probe env?" is **no, twice over**: with inputs
as defines the plan is closed before any fold runs, and even an open plan folds
without an environment because every fold has type `Plan g a -> …`.

`run` requires every input. `plan`/`cost` bind a missing one to `""` and say so on
the `inputs` line — including under `--raw`, where the note prints immediately above
the program, because a program printed with an empty subject is a different text
from the one that will run and the operator must not have to infer that.

This is worth a property test in wave 2: for two different inputs, `observeValue`
agrees on everything but the prompts.

### 10.5 `--scripted`, `ci/examples.sh`, and the pinned numbers

`scriptFor`/`isaacScript` match a canned reply against a **prefix** of the prompt
(run/Main.hs's note on `scriptFor`). Two rules follow, and they are cheap:

* **splice an input after the brief, never before it**, so the prefix keys keep
  matching. Every Isaac prompt is already `{brief}` then `{subject}`.
* the script entry that answered the removed tool leaf becomes dead and must be
  deleted; the text it returned becomes the `--input-arg` the CI run passes.

Converting an example **removes a leaf**, so its `size`, `askNodes`, `codes` and
`costSummary` all move, and with them the haddock table in `Example.Isaac`, the
`> level …` block on each program, `doc/research/isaac-workflows.md` §3, and the
pins in `ci/examples.sh` (D10's regression pin). None of this is frozen-corpus, so
there is no refreeze — but the numbers must move in the same commit as the program,
or the pin fails and the haddock lies.

**Convert exactly one example in wave 2** — `review-lite`, which is also D1's worked
example — and leave the other four to a follow-up. That keeps one reviewable diff
carrying one number change.

---

## 11. tier1 impact

**No existing entry changes.** `Builder.hs` is untouched (§2.6); the nineteen
Builder-tier cases are compared exactly and are unaffected; `hardenProgram` and
`helloProgram` keep their type and their text, since neither declares a function.
The only edit `Example.Harden` needs is the registry's `Fixed` wrapper (§10.3), which
`Cases.hs` does not go through — it imports the two programs directly.

**New coverage is available and worth taking.** The three call vectors are pinned at
the Builder tier; adding a **`Agentic.Workflow` twin of each** pins the new surface's
function and call elaboration against the same frozen replies. `canonProgram`
already canonicalizes `fnParams` and body binders (tier1/Main.hs:390–414) and leaves
`fnName` alone, so a W twin compares up to alpha as long as the function's name is
written exactly — which §6 does.

One small change is needed first: `nameRule` keys the alpha rule by *file path*
(tier1/Main.hs:154), so a W twin sharing a path with its Builder original would
weaken the original to `Alpha`. Fix by moving the rule into the case list:

```haskell
cases :: [(FilePath, NameRule, Program)]
```

and deleting `alphaNamed`. Roughly fifteen lines across `Cases.hs` and `Main.hs`,
and the count in the runner's summary line goes from twenty-one to twenty-four.

---

## 12. The new exports of `Agentic.Workflow`, with signatures

Added to the export list; nothing is removed, and `act`'s type changes from
`Party p -> Words s -> W ('Open s) ('Open s) ()` to `Party p -> Words s -> Acting s`.

```haskell
-- * Functions
Fn,                                     -- re-exported type, for signatures
SomeFn (..),                            -- re-exported
Params,                                 -- re-exported type
noParams,                               -- re-exported
takes    :: forall n c cs acc s hs. (KnownSymbol n, Fresh n acc)
         => Answer c -> Params cs ('(n,c) ': acc) s hs
         -> Params (c ': cs) acc s (V ('(n,c) ': acc) c, hs)
function :: forall r ps s hs. (KnownCode r, Codes s ~ ParamCtx ps, Curries hs)
         => Text -> Params ps '[] s hs
         -> Curried hs (W ('Body r s) ('Body r s) Term) -> Fn ps r
answer   :: forall h s c j. KnownIx h s => V h c -> W ('Body c s) j Term
done     :: W ('Body 'CodeAck s) j Term
runBody  :: Live -> W ('Body r s) j Term -> B.Body s r
Curries (..)                            -- class + associated Curried

-- * Calls
call     :: Fn ps r -> Args s ps -> Rhs s r
call_    :: Fn ps 'CodeAck -> Args s ps -> Calling s
Acting, Calling                         -- the two statement values
Arg, Args ((:>), ANil), noArgs
Gives (..)                              -- class, exporting `arg`

-- * Programs
defining :: [SomeFn] -> W ('Open '[]) ('Open '[]) Term -> Program
workflow :: W ('Open '[]) ('Open '[]) Term -> Program          -- = defining []

-- * Inputs
Parameterized (..)
Ins
noInputs :: Ins ()
input    :: Text -> Ins hs -> Ins (Text, hs)
taking   :: Curries hs => Ins hs -> Curried hs Program -> Parameterized

-- * Existing, changed
act      :: Party p -> Words s -> Acting s                     -- was a W value
Stage (..)                                                     -- gains `Body`
```

New language extensions on `Agentic.Workflow`: `GADTs` is already on; add
`TypeApplications` (already on), and nothing else — `Curries`'s associated family
needs `TypeFamilies` (on) and `UndecidableInstances` (on).

---

## 13. What must not compile

Recorded as the messages they produce, in the module's existing register — wave 2
should add each to the `What must not compile` section of `Agentic.Workflow`'s
haddock and check each by hand once:

* a branch, loop or `known here` in a function body —
  *a function body is a straight line: it has no bounded revision, no branch and no
  `known here` — those belong to the workflow that calls it*;
* two parameters of one name — Builder's `Fresh`:
  *this name is already in scope, and a live name is not introduced twice*;
* `done` in a value-returning body — `Couldn't match ‘'CodeText’ with ‘'CodeAck’`;
* a body with no terminal — `Couldn't match ‘()’ with ‘Term’`;
* a statement after `answer` or `done` —
  *nothing follows a terminal* (`NoFollow`, unchanged);
* a value function standing as a statement call — `Couldn't match ‘'CodeText’ with
  ‘'CodeAck’` on `call_`'s first argument;
* an argument of the wrong kind — `Couldn't match ‘'CodeVerdict’ with ‘'CodeText’`;
* a handle passed as an argument where its binding is not live — the existing
  `KnownIx` `TypeError`;
* the wrong number of arguments — `Couldn't match ‘Args s '[]’ with ‘Args s '[ 'CodeText]’`.

And two that are **value**-level refusals, on a CAF, because the type level cannot
see them (§5.2):

* two functions of one name;
* a call naming a function `defining` was not given, or was given later.

---

## 14. Implementation checklist for wave 2, in order

Each step builds and is testable on its own. Steps 1–7 are D1; 8–12 are D8.

1. **`Agentic.Workflow`: the stage.** Add `Body Code Scope` to `Stage`, the `Res`
   equation, and `runBody`. Nothing else compiles yet; check that
   `cabal build agentic` still passes with the existing examples.
2. **The parameter list.** `Curries`/`Curried`/`applyTo`, `paramNames`, `takes`,
   re-export `noParams`, `Params`, `Fn`, `SomeFn`. No behaviour yet.
3. **`function`, `answer`, `done`, and the three body `Step` instances**
   (`Ask`, `Rhs`, `Ann` at `'Body`). Verify by writing `libDrafted` from §6.1 in a
   scratch module and printing it.
4. **Statements as values.** Convert `act` to `Acting` with its two `Step`
   instances; add `Calling`, `call_`, `call`. Confirm `Example.Harden` and
   `Example.Isaac` still compile unchanged and that `tier1` is still green — this is
   the step that proves the type change is source-compatible.
5. **Arguments.** `Gives`/`arg`, re-export `Args`/`Arg`, add `noArgs`.
6. **The table.** `defining`, `tableProblem`, `workflow = defining []`. Test
   `tableProblem` directly on three hand-built bad programs (duplicate name, late
   callee, absent callee) — a plain unit check in `tier1` or a scratch test is
   enough; it must not be left to a reviewer's eye.
7. **The refusal instances** of §3.7 and the haddock of §13. Check each message by
   hand once, and record it in the module's `What must not compile` list.
   *Gate: `tier1` green, `ci/examples.sh` unchanged, `cabal build` warning-free.*
8. **`Agentic.Workflow`: inputs.** `Parameterized`, `Ins`, `input`, `noInputs`,
   `taking`, and the `Curries (Text, hs)` instance.
9. **The registry.** `Example` sum in `Example.Harden`; `lookupExample` returns it;
   `Example.Isaac`'s five stay `Fixed` for now.
10. **The CLI.** `run/Main.hs`: the three flags, the resolution table and the six
    refusals of §10.3, the `inputs` line of §10.4 in `planCmd` and `costCmd`, and
    the announcement in `runCmd`. Extend `usage`.
11. **Convert `review-lite`.** `reviewReport` as a `Fn` (§9), both arms calling it,
    the opening tool leaf replaced by `taking (input "subject" noInputs)`, the dead
    script entry deleted, the haddock's numbers and prose updated, and the
    `ci/examples.sh` pin updated in the same commit.
12. **tier1 coverage.** Move the `NameRule` into `cases`, delete `alphaNamed`, and
    add the three `Agentic.Workflow` twins of §6 as `Alpha` cases.
    *Gate: `tier1` green at twenty-four cases, `ci/examples.sh` green with its new
    `review-lite` numbers, `cabal build` warning-free.*

**A property worth adding at step 10** (cheap, and it pins §10.4's claim): for a
`Parameterized` example and two different input texts, `observeValue` agrees on
every field but the prompts inside `worlds`.

---

## 15. Risks, and the one namespace hazard

**The generated-name namespace.** A parameter named `b2` collides with the name a
body binding at depth 2 generates: the type level cannot see it (body binds use the
index-level `bindBI`, which has no `Fresh`), so GHC accepts a program Lean refuses.
The same hazard exists today for `named "b1"`. Close it once, for both:

```haskell
-- | The names the surface generates for itself, which an author may not take:
-- @b0, b1, …@ for bindings and @r0, r1, …@ for a revision's result. 'named' and
-- 'takes' refuse them, which is what keeps "fresh by construction" true.
reserved :: Text -> Bool
```

used by `named` (on its `Text`) and by `takes` (on `symbolVal`), erroring on a CAF.
Six lines, and it makes the module's freshness claim exact again.

**Inference.** The `Curried hs r` family appears in `function`'s argument type. It
reduces as soon as the parameter list is written, which it always is at the call
site. If wave 2 hits a wanted that will not reduce, the cause is a parameter list
that is polymorphic in `hs` — which no author writes and no example needs.

**Table order.** §5.2's check is the whole of the defence, and it runs on a CAF.
Make sure `tableProblem` is forced by `defining` itself and not merely available:
`case tableProblem prog of Just msg -> error …` in the definition, as written.
