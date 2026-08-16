> **SUPERSEDED — pre-attack draft. Do not decide from this page.**
>
> `haskell-question.md` beside this file is the design of record for this
> question. This draft was written before the adversarial pass; forty-seven
> findings from two attackers apply to it, **six of them fatal**:
>
> 1. **Round 17 has not shipped.** Part 5 step 1 ("Ship round 17 as landed. It is
>    done.") is false — `Parse.lean:523/912` still carry `answer` — and the whole
>    cost case rests on believing it has.
> 2. **The option set omits the option that dominates.** Ship the do-core and
>    descope the calculus, priced from `expr-design.md` §8.9.
> 3. **The differential test cannot detect the bug class it is offered against.**
>    `Cost.shapes` carries no prompt text; `Cost.asks` renders every answer as
>    `default`; and `agent-cat plan --json` was deliberately refused.
> 4. **A multi-question helper cannot be a do-statement** under either printed
>    bind — both take a `Step`, which is one question.
> 5. **The sharing rule is false in agent-cat's own vocabulary.** `Ω` is a
>    function of the question, so identical questions share an answer; a repeated
>    `Step` multiplies events, not answers.
> 6. **§1.9 Mistake 3's transcript cannot be produced by either printed signature
>    for `>>`**, and it underwrote the errors row.
>
> Forty-one further corrections apply, including: G7 is structural and lost, not
> portable; rule 6 becomes a *silent meaning change*, not a saving; Safe Haskell
> is inverted; the emitted binders read `{v0}`; the source map is blocked on
> `acat-pos-module-attribution-oxq`; and the census is off — `Agentic/` is 26,155
> lines and 867 theorem/lemma declarations, not "~16k" and "~530".
>
> The recommendation below (option (c), staged) is **not** preserved.

# The Haskell question

*A design for the strongest honest version of "write agent-cat workflows in
Haskell", and a three-way comparison against continuing the `.wf` surface.
Draft for the owner's decision; nothing here is approved.*

Sources: REPORT A (agent-functor autopsy), REPORT B (agent-cat guarantees and
cost inventory), REPORT C (prior-art sweep), plus a direct read of
`Agentic/Core/Plan.lean`, `Agentic/Core/Question.lean`,
`doc/research/dsl-redesign/{GRAMMAR.md, calculus-design.md}` and
`example/{harden.wf, library.wf, harden-imported.wf}`.

---

## 0. The one-paragraph answer

The best-possible Haskell library is not an arrow library, not a selective
functor, and not a graded monad with `Frag` in the type. It is **`Plan` itself,
transliterated** — the same five-former first-order syntax, with two changes
that Haskell makes possible and Lean does not: the continuation of an `ask` is a
Haskell lambda whose argument is a *variable token* rather than an answer, and
the prompt is a first-order `Tmpl` built by a quasi-quoter rather than an
arbitrary `Env Γ → String`. Those two moves buy do-notation, the whole of
Haskell as the construction-time macro language (which is exactly what the
round-18 calculus is being built to imitate), and a *more* legible prompt than
the Lean side has today. What they cost is every theorem: `level p ≤ branch`
degrades from a machine-checked statement about every accepted program to a
property of an export list, and the cost algebra degrades from ~530 kernel-
checked theorems to a QuickCheck battery. The interesting option is therefore
neither (a) nor (b) but (c): **build the Haskell library's front half, emit
`.wf` as the IR, keep every theorem and the runner in Lean** — because the front
half is the part Haskell does better, and the theorems are the part Lean does
better, and the seam between them is a pretty-printer.

---

# Part 1 — The library design: `Plan`-in-Haskell

## 1.1 The crux, named first

The pipeline rung is *static shape, value-dependent payload*. REPORT C is right
that no standard class captures it: `Applicative` gives shape without payload,
`Monad` gives payload with dynamic shape, and the arrow classes
(`FreerPreArrow`, `Category`+`Strong`) give payload with static shape *at the
price of point-free plumbing*. agent-functor pays that price and its `Flow` has
no binders at all; REPORT A's item **A** is the bill arriving.

agent-cat already solved this and the solution ports verbatim. From
`Plan.lean`'s header:

> the dilemma *point-free plumbing or host binding* is false, and the third
> option is to own the binder … a question's **words** are built by an `Expr`,
> an ordinary function of the answers in scope, while the question's **shape** —
> who is asked, under what scope, at which draw — is written in the term.

So the Haskell answer is: **there is no class**. Do not look for one. Expose a
GADT whose `ask` node is ask-and-bind (already A-normal, so no analysis has to
reconstruct where an answer went), carry the shape as data, and give the node a
continuation. The only question left is what the continuation's argument is —
and that is where Haskell can beat Lean's de Bruijn indices.

### The central move: bind gives you a name, not an answer

```haskell
-- Agentic.Plan (constructors NOT exported)

newtype Var s (c :: Code) = MkVar Int   -- a de Bruijn *level*; abstract

data Plan s a where
  Ret     :: a -> Plan s a
  Ask     :: SCode c -> Shape c -> Tmpl s -> (Var s c -> Plan s a) -> Plan s a
  IfFlag  :: Var s 'Flag    -> Plan s a -> Plan s a -> Plan s a
  OnVerd  :: Var s 'Verdict -> VerdictArms s a -> Plan s a
```

`Ask`'s continuation is a Haskell function, but its argument is a `Var s c`, and
**there is no exported eliminator from `Var s c` to `El c`**. There is no
`answerOf`, no `unVar`, no `Show`, no `Eq` on the answer. The only two things
the library exports that consume a `Var` are:

1. `hole :: Renderable c => Var s c -> Tmpl s` — splicing into a prompt;
2. `ifFlag :: Var s 'Flag -> …` and `onVerdict :: Var s 'Verdict -> …` —
   the two eliminations.

That is agent-cat's **rule 3 — "two consumption sites, and no third"** made into
a Haskell type rather than a parser rule. The continuation may compute anything
it likes at construction time (that is the point), but it cannot compute
anything *from an answer*, because it never has one. Therefore the shape of the
program downstream of a question cannot depend on that question's answer, and
the pipeline rung is structural, exactly as `shapes_eq_of_le_pipeline` is
structural in Lean: not because a predicate on the term says so, but because
there is no place in the node for it to flow.

There is no `Dyn` constructor. `level p ≤ branch` is therefore true **by absence
of a constructor**, checked by GHC's exhaustiveness checker at every fold. That
is the strongest non-theorem form of G1, and §2 prices exactly how much weaker
than a theorem it is.

### Traversal stays first-order

HOAS-with-levels is traversable: to fold under an `Ask`, apply its continuation
to `MkVar depth`. Every fold (`level`, `costTree`, `shapes`, `asks`, `planLines`,
`denote`, `certify`) is a total pure function of the term, exactly as in Lean.
The `s` parameter is a phantom brand, à la `ST`:

```haskell
runPlan  :: Oracle IO -> (forall s. Plan s ()) -> IO RunReport
checkPlan ::            (forall s. Plan s ()) -> Either Refusal (Checked)
```

**Why levels and a phantom brand instead of a type-level context `Plan (g :: [Code]) a`.**
The literal transliteration of Lean would index by the context. It is more
precise — scope escape becomes ill-typed — and it is *worse for this owner*,
because the error a non-expert sees for a scope mistake becomes a mismatch
between two type-level lists of `Code`s inside a desugared `Agentic.Do.>>=`
application. Haskell's own lexical scoping already prevents scope escape in
every case except deliberately stashing a `Var` in a data structure; that
residual case is caught by a **scope pass in `checkPlan`** that refuses with a
position and a sentence. Trading a type error for a checker refusal is a
*gain* against the owner's stated values ("refused with a position, one
sentence, and the escape named"). It is recorded here as the design's first
deliberate divergence from the Lean shape.

## 1.2 The four kinds, and shapes

```haskell
data Code = Text | Verdict | Flag | Receipt        -- promoted

type family El (c :: Code) where
  El 'Text = Text; El 'Verdict = Verdict; El 'Flag = Bool; El 'Receipt = ()

data SCode c where
  SText :: SCode 'Text ; SVerdict :: SCode 'Verdict
  SFlag :: SCode 'Flag ; SReceipt :: SCode 'Receipt

data Shape (c :: Code) = Shape
  { addressee :: Addressee, scope :: QScope, draw :: Word }
```

`Shape` is `Q.Shape` on the nose, including `draw`. `El` mirrors
`Question.lean`'s `El` with `ack` renamed `Receipt` to match the surface. The
addressee is *typed*, borrowing agent-functor's best idea (REPORT A §5.3):

```haskell
data Party = IsModel | IsTool | IsPerson
data Addr (p :: Party) where
  Model  :: Text -> Addr 'IsModel
  Tool   :: Text -> Addr 'IsTool
  Person :: Text -> Addr 'IsPerson

servedBy :: Addr 'IsModel -> Text -> Addr 'IsModel
```

`served by` off a tool or a person becomes a type error rather than a refusal
the Lean checker still has to grow (GRAMMAR.md's implementation obligation
"`served by` is refused off `ask model` (no such refusal exists today)"). This
is a refusal that **evaporates**, and §2.3 counts how many do.

## 1.3 Prompts: `Tmpl` is first-order, and this is not negotiable

agent-functor's `peRender :: a -> Prompt` is an opaque function, which is why
`agent-functor plan` cannot print a brief and `cost` cannot price by shape
(REPORT A §1, delta **A**). Lean's `Expr Γ String` is *also* a function — but
the only `Expr`s that appear in an accepted `.wf` program are the ones
`Dsl/Check.lean` builds from the `{name}` hole grammar, so in practice the
prompt is data wearing a function's type. A Haskell library that let users pass
`\env -> …` would lose that, and with it G4's probe rendering.

So: **prompts are a first-order datatype.**

```haskell
data Tmpl s where
  Lit  :: Text -> Tmpl s              -- literal chunk (a define expands to this)
  Hole :: Renderable c => Var s c -> Tmpl s
  Cat  :: [Tmpl s] -> Tmpl s

class Renderable (c :: Code) where render :: El c -> Text
instance Renderable 'Text    where render = id
instance Renderable 'Verdict where render = Verdict.render
```

with the two refusals as custom type errors, in the surface's own words:

```haskell
instance TypeError
  ( 'Text "a flag has no canonical text."
    ':$$: 'Text "A yes/no answer cannot be spliced into a prompt; ask the"
    ':$$: 'Text "question the flag decides, or eliminate it with `ifFlag`." )
  => Renderable 'Flag
```

Consequences, all of them agent-cat properties recovered:

* `shapes`, `asks`, `costTree` and `planLines` are folds of the value alone.
* **Probe rendering is exact.** `Env.probe` becomes `renderAt probeEnv`, and the
  text printed by `plan` is the true template with placeholder answers — the
  same epistemic status it has in Lean, not agent-functor's `prompt reviewer`.
* **The batch rung is still decidable from the source.** A question is closed
  exactly when its `Tmpl` contains no `Hole` — which is exactly GRAMMAR.md rule
  5's "every hole it wrote named a define", because a define is an ordinary
  Haskell `Text` CAF and the quasi-quoter turns `{spec}` at type `Text` into a
  `Lit` chunk and `{patch}` at type `Var s 'Text` into a `Hole`. The two
  namespaces stay disjoint *by type*, not by a parser rule.
* Per-token cost bounds get *better* than Lean has today: literal chunk lengths
  are known statically, so a token-bounded interval needs only a declared bound
  on answer size.

**The escape hatch, and why it is quarantined.** Someone will want
`\answers -> …`. It lives in `Agentic.Plan.Unsafe` as
`Opaque :: SrcLoc -> (ProbeEnv -> Text) -> Tmpl s`, and it is *structurally
detectable*: `checkPlan` refuses any plan containing an `Opaque` unless the
caller passes `allowOpaque`, and `plan`/`cost` print `<computed at Foo.hs:41:7>`
and mark the node's rung `opaque`. This is the analysis lattice made honest
rather than a hole papered over — the same instinct as `Plan.dyn` being kept and
quarantined rather than deleted.

## 1.4 The quasi-quoter — specified, and better than agent-functor's

Name: `[prompt| … |]`, exported from `Agentic.Prompt`. It is not
`string-interpolate` and it is not `PyF`; it is bespoke, because REPORT C is
right that a bespoke QQ "is the only place a Haskell surface can emit
`(position, one sentence, escape)`".

Spec:

1. **Hole syntax is `{name}`** — PyF's spelling, agent-cat's spelling, so the
   `.wf` and Haskell surfaces read alike and a prompt can be moved between them
   unchanged. `\{` and `\}` are literal braces. Nothing else is special.
   Deliberately *not* `#{}` (agent-functor's, via `string-interpolate`) and
   deliberately not named `i` — REPORT A's finding that `i` shadows the most
   popular loop variable in Haskell and becomes a `-Werror` failure at every
   `\i ->` in an importing module is a self-inflicted wound we do not repeat.
2. **A hole resolves against Haskell binders in scope**, by TH
   `lookupValueName`. A name with no binding is refused *at the quasi-quoter*,
   with the QQ's own position and message —
   `Harden.hs:22:9: no name `patchh` here. Did you mean `patch`?` — not a GHC
   scope error at a desugared position.
3. **A hole is typed.** `{x}` elaborates to `Hole x` if `x :: Var s c` and to
   `Lit x` if `x :: Text`. Anything else, and anything at `'Flag`/`'Receipt`, is
   the `Renderable` `TypeError` above. This is the fix for agent-functor's
   `Show`-typed `#{}` hole, which silently `Show`s a wrong-kinded value.
4. **Indentation**: strip the common leading indent ignoring blank lines (PyF's
   rule), keep interior newlines (`__i`'s rule), and **re-indent a multi-line
   spliced value to the column of its hole** — which of the three surveyed
   packages only `neat-interpolation` does, and which is the difference between
   a nested prompt that reads and one that does not.
5. **No `{-# LANGUAGE QuasiQuotes #-}` sprawl mitigation is possible** — the
   extension is required at every use site and cannot be re-exported. This is a
   real, unfixable ergonomic tax; it is one line in a `default-extensions`
   stanza per package, and it is honest to say it is there.
6. **`[promptFile|prompts/plan-probe.md|]`, improved.** agent-functor's design —
   check the path in `Q` at compile time, read the file at run time so editing
   prose needs no rebuild — is genuinely good and is kept. The improvement:
   *also* parse the file's holes at compile time, resolve them against scope,
   and embed **the hole set plus a content hash** in the splice. At run time the
   file is read and its hole set recomputed; if it differs, the program refuses
   by naming the file, the added or removed hole, and the compile-time hash.
   Net effect: **edit the prose freely with no rebuild; change a hole and get a
   refusal instead of a silently different question.** agent-functor cannot do
   this because it has no notion of what a hole means.

Worked example, the flagship's reviewer panel:

```haskell
reviewers :: Var s 'Text -> Var s 'Text -> NonEmpty (Step s 'Verdict)
reviewers guide patch =
  ask (Model "reviewer-correct") [prompt|
      {guide}
      Is this patch correct?
      {patch}
      {verdictSpec}
  |] :|
  [ ask (Model "reviewer-secure") [prompt| … |]
  , ask (Model "reviewer-simple") [prompt| … |] ]
```

`verdictSpec :: Text` is an ordinary top-level CAF — agent-cat's `define`,
with no new mechanism.

## 1.5 Statements, do-notation, and what `>>` means

`QualifiedDo` (REPORT C: rebinds `>>=`, `>>`, `fmap`, `<*>`, `join`, `fail` — and
notably *not* `select`, which is why the selective route is a dead end for
do-notation anyway):

```haskell
module Agentic.Do ((>>=), (>>)) where

(>>=) :: Step s c -> (Var s c -> Plan s a) -> Plan s a
(>>)  :: Step s 'Receipt -> Plan s a -> Plan s a
```

Note the type of `>>`. **A statement-position question must be a receipt.** That
is GRAMMAR.md rule 11 ("a statement-position ask is the act … it binds nothing
and asks for nothing back") expressed as a type, and it means agent-cat's
deliberate refusal to import `-Wunused-do-bind` culture (round 17 §1.1) is
unnecessary: discarding a text answer is not a warning, it is ill-typed. Give
`>>` a `Discardable c` constraint with a `TypeError` at the three non-receipt
codes and the message is the surface's own:

```
this question's answer is discarded.
A statement-position question is an act; write `act (Tool "apply") …`,
or bind the answer with `x <- …`.
```

`Step s c` is the thing a statement can be:

```haskell
data Step s c where
  One   :: SCode c -> Addr p -> Shape c -> Tmpl s -> Step s c
  Panel :: PanelRule -> NonEmpty (Step s 'Verdict) -> Step s 'Verdict

ask   :: KnownCode c => Addr p -> Tmpl s -> Step s c
act   ::                Addr p -> Tmpl s -> Step s 'Receipt
draw  :: Word -> Step s c -> Step s c          -- `independent draw n`
```

**Kind inference.** agent-cat infers the kind from the constraint sites (rule 4:
a hole forces `text`, `if` forces `flag`, panel members force `verdict`, a
statement ask is `receipt`). Haskell gets *most* of this for free by
unification — `ifFlag x` forces `x :: Var s 'Flag`, `panel` forces its members
to `'Verdict`, `>>` forces `'Receipt` — but a hole is `Renderable`, satisfied by
both `'Text` and `'Verdict`, so exactly agent-cat's one ambiguity reappears as
an *ambiguous type variable* rather than as the "ground-free component" refusal.
Two mitigations, both shipped: monomorphic aliases `askText`, `askVerdict`,
`askFlag` for the common case, and a `TypeError`-carrying default that names the
escape. §1.9 shows the residual error honestly; it is the worst of the three.

## 1.6 Panels, revision, sharing, draws

**Panels** (rule 10, the closed two-entry menu):

```haskell
data PanelRule = AllMustApprove | AtLeast Word
panel :: PanelRule -> NonEmpty (Step s 'Verdict) -> Step s 'Verdict
```

`NonEmpty` makes "a panel needs at least one member" unwritable — one of
agent-cat's two *exempt* battery cases (unreachable from source, tested against
hand-built `Raw`) simply ceases to exist. `AtLeast 0` and `AtLeast k` with
`k > length members` are checker refusals with positions. The quorum read-out
stays a pure function in the leaf, so the panel stays at the pipeline rung, and
`panel` costs exactly `k` questions in every world — unchanged.

**Bounded revision** (rules 8 and 9). The `Pending` discipline — "on every path
from the binding, exactly one `case` consumes it, and nothing else may touch it"
— is a whole class of checker machinery in Lean (`checkBlock` gains a
continuation-returning mode carrying pending loop results). In Haskell it
evaporates, because the eliminator can be the *only* way to build the node:

```haskell
data Round s = Round
  { review :: Step s 'Verdict
  , amend  :: Var s 'Verdict -> Step s 'Text }

revising
  :: Var s 'Text -> Amendments -> (Var s 'Text -> Round s)
  -> (Var s 'Text -> Plan s a)   -- settled
  -> Plan s a                    -- unsettled
  -> Plan s a
```

There is no pending value, so it cannot be mishandled; `settled`/`unsettled` are
mandatory by arity. `Amendments` is a smart constructor `atMost :: Word ->
Either Refusal Amendments` bounded by `maxRevisions = 64`; the ergonomic wrinkle
is that this is CPS and does not sit inside a `do` block as prettily as the
`.wf` spelling. Recorded as a real ergonomic loss, not talked away.

**Sharing is the meaning.** In the pure denotation the world is still a
function — `type World = forall c. SCode c -> Q c -> El c` — so G5's central
fact ("the same question twice is the same answer") is unchanged and needs no
side condition. And Haskell settles round 18's §5.5 divergence in *one* rule
instead of three:

> **A `Var` used twice is one question. A `Step` used twice is two questions.**

Because a `Step` is a value and using it in two constructor positions builds two
`Ask` nodes, while a `Var` is a reference to one node. Round 18 needed a
"source-versus-term criterion" (C2) to distinguish
`(\x -> compare x x) (ask …)` from `let q = \x -> ask …; compare (q p) (q p)`;
in Haskell both spellings mean two questions, uniformly and predictably, and the
one-question spelling is `x <- ask …; compare x x`. One line in the guide
instead of three, and it is the line Haskell programmers already believe.

**Draw indices** are `Shape.draw`, set by `draw n`, and they key the runner's
content-addressed store exactly as agent-functor's `--reroll` does. This is the
one place where agent-functor is ahead of both: it has a *durable* realisation
of sharing-by-question (content-addressed leaf store, fork/resume as one code
path, `Exec` never cacheable), and whichever option wins, that machinery should
be built.

## 1.7 Libraries are Haskell modules

`example/library.wf` becomes `Harden/Library.hs`:

```haskell
module Harden.Library (guide, drafted, reviewed, applied, verdictSpec) where

verdictSpec :: Text
verdictSpec = "Reply with exactly APPROVE if acceptable, or OBJECTION: …"

drafted :: Var s 'Text -> Text -> Text -> Step s 'Text
drafted guide goal shape = ask (Model "author" `servedBy` "deep") [prompt| … |]

reviewed :: Var s 'Text -> Var s 'Text -> Step s 'Verdict
reviewed guide patch = panel AllMustApprove (reviewers guide patch)

applied :: Var s 'Text -> Plan s a -> Plan s a
applied patch k = Wf.do { act (Tool "apply") [prompt| … |]; act (Tool "test") …; k }
```

What is gained: the real module system, Hackage, HLS, Hoogle, `cabal repl`,
versioning, and the fact that `drafted`'s type *is* its arity-and-kind contract.
`fn-import-design.md`'s hard-won properties — a body cannot see its caller,
recursion cannot be written, calls cannot be arguments — split three ways: the
first is free (lexical scoping), the second is **lost** (Haskell has recursion,
and a recursive `Plan` builder diverges at construction time — a hang, not a
refusal; mitigated only by a node budget in `checkPlan`, which cannot fire
because the builder never returns), the third is unnecessary.

What is lost: a library's **priming** (its top-level statements, asked once
before anything the importer writes, so a closed priming question is shared
across every importing program) becomes an explicit `withLibrary :: (Var s 'Text
-> Plan s a) -> Plan s a` the importer must remember to call. Arguably better —
no spooky action — but it is a guarantee traded for a convention. And
`known here:` — the checker-verified visibility assertion — has no Haskell
counterpart at all beyond a bespoke pass over the built term.

## 1.8 What the refusals become

Four fates, and the honest census matters more than the mechanism:

| fate | which refusals | count, roughly |
|---|---|---|
| **evaporates** (the mistake is unwritable) | empty panel, `served by` off a tool, pending mishandling, arms exporting bindings, `answer` in a receipt body, statement-word collisions, define/binder namespace collision, most arity errors | ~30 of 201 |
| **becomes a `TypeError`** with the surface's own words | flag/receipt in a hole, discarded non-receipt answer, non-verdict panel member, `ret`/`pure` recognized-mistake | ~15 |
| **becomes an ordinary GHC error** in GHC's words, at GHC's position | kind mismatches, arity, name not found outside a prompt, ambiguity | ~55 |
| **stays a checker refusal**, position + one sentence + escape | budgets (`maxRevisions`, `maxQuestions`), quorum bounds, scope-escape, opaque templates, non-total elimination where a record cannot express it, backend/model pairing, every runtime-shaped diagnosis | ~60 |
| **disappears because the concept does** | kind inference from first ground use and its ground-free refusal; shadowing (rule 6 — Haskell permits it, `-Wname-shadowing` is a warning); the `{$x}` sigil history; parse-level refusals of the `.wf` grammar | ~40 |

The middle row is the damage. Sixty of two hundred and one diagnoses move from
"a position, one sentence, and the escape named" to GHC's phrasing at a
desugared position — and the coverage audit cannot police them, because they are
not our refusal sites. The battery and `coverage_audit.py` port cleanly to the
~60 that stay ours, and `Refusal` carries a real position via TH `Loc` in the QQ
and `HasCallStack` on every exported combinator.

Two structural rules are **lost outright** and should be said plainly: **rule 6,
no shadowing**, and **rule 4's kind inference**. The first is a warning in
Haskell; the second becomes "write the type", which is not worse, but it is not
the same language.

## 1.9 The three commonest mistakes, with the errors a non-expert actually sees

*(GHC 9.8-shaped. These are reconstructions, not captures — no such library
exists yet — but they are the shapes GHC produces for these constructions and
they are not flattered.)*

### Mistake 1 — splicing a flag into a prompt

```haskell
ok <- askFlag (Person "owner") [prompt| Apply this patch? {patch} {flagSpec} |]
act (Tool "log") [prompt| owner said {ok} |]
```

```
Harden.hs:58:34: error: [GHC-64725]
    • a flag has no canonical text.
      A yes/no answer cannot be spliced into a prompt; ask the
      question the flag decides, or eliminate it with `ifFlag`.
    • In the first argument of ‘Agentic.Prompt.hole’, namely ‘ok’
      In the expression:
        Agentic.Prompt.cat
          [Agentic.Prompt.lit "owner said ", Agentic.Prompt.hole ok]
      In the second argument of ‘act’, namely
        ‘[prompt| owner said {ok} |]’
   |
58 | act (Tool "log") [prompt| owner said {ok} |]
   |                                  ^^^^^^^^^^
```

**Verdict: good.** The first bullet is ours, verbatim, with the escape named.
The cost is the next eight lines, which show the quasi-quoter's expansion — a
non-expert has to learn to read past them. agent-cat prints four lines and a
caret and stops.

### Mistake 2 — using an answer as a Haskell value

```haskell
draft <- ask (Model "author") [prompt| … |]
if Text.length draft > 4000 then … else …
```

```
Harden.hs:41:20: error: [GHC-83865]
    • Couldn't match expected type ‘Text’
                  with actual type ‘Var s0 'Text’
    • In the first argument of ‘Text.length’, namely ‘draft’
      In the first argument of ‘(>)’, namely ‘Text.length draft’
      In a stmt of a qualified 'do' block:
        if Text.length draft > 4000 then … else …
```

**Verdict: mixed, and this is the important one.** The diagnosis is *correct and
short*, and it points at the right token. But the escape is not named, and there
is **no way to name it**: you cannot attach a `TypeError` to a failed match
against a concrete type in someone else's function. The author is told they
cannot do this; they are not told that the reason is that a test on an answer
is the dynamic rung, or that the way out is to ask the question the test decides
and eliminate the flag. agent-cat's refusal here is
`rule 3: there is no expression language — no test, comparison, arithmetic, or
transformation`, and it says the escape. That sentence is the eighteen rounds,
and GHC will not say it.

### Mistake 3 — a bare question in statement position

```haskell
Wf.do
  ask (Model "author") [prompt| Summarise the patch. {patch} |]
  act (Tool "file")    [prompt| … |]
```

```
Harden.hs:33:3: error: [GHC-64725]
    • this question's answer is discarded.
      A statement-position question is an act; write
      `act (Model "author") …`, or bind the answer with `x <- …`.
    • In a stmt of a qualified 'do' block:
        ask (Model "author") [prompt| Summarise the patch. {patch} |]
      In the expression:
        Agentic.Do.do
          ask (Model "author") …
          act (Tool "file") …
```

**Verdict: good**, and better than agent-cat, which infers `receipt` silently and
carries the "absence of an arrow marks *discard*, not *consequence*" caveat in
prose.

### The fourth, which cannot be made good

```haskell
v <- ask (Model "judge") [prompt| … {verdictSpec} |]
onVerdict v VerdictArms{ … }
```
— where `ask` is the polymorphic one and the hole did not disambiguate:

```
Harden.hs:44:8: error: [GHC-39999]
    • Ambiguous type variable ‘c0’ arising from a use of ‘ask’
      prevents the constraint ‘(KnownCode c0)’ from being solved.
      Probable fix: use a type annotation to specify what ‘c0’ should be.
      Potentially matching instances:
        instance KnownCode 'Text  -- Defined in ‘Agentic.Plan’
        instance KnownCode 'Verdict -- Defined in ‘Agentic.Plan’
        ...plus two others
    • In a stmt of a qualified 'do' block: v <- ask (Model "judge") …
```

**Verdict: bad**, and this is the class REPORT C's whole §5 warns about — every
failure surfaces as a constraint error against a normalised type the author
never wrote. It is why the library exports `askText`/`askVerdict`/`askFlag` and
the guide tells you to use them, which is a workaround, not a fix. And the
scope-escape case (`Couldn't match type ‘s’ with ‘s0’ … would escape its scope`)
is `runST`'s famously confusing error, which is exactly why §1.1 pushes scope
checking into `checkPlan` rather than the type.

---

# Part 2 — The static-analysis story

## 2.1 The ledger, with fidelity

| # | Guarantee | In Lean | In `Plan`-in-Haskell | Fidelity |
|---|---|---|---|---|
| G1 | every accepted program ≤ branch | theorem (`parseAndCheck_level_le`, 14 lemmas) | **no `Dyn` constructor**; `level` is an exhaustive fold | *by construction of a datatype*, corroborated by GHC's coverage checker; not machine-checked, and true only of the exported API |
| G2 | finite cost tree, min/max bills | theorem (`bill_mem_leaves`, `exists_min_bill`) | `costTree :: Plan s a -> CostTree`, total and finite by the same argument | code survives whole; **correctness becomes QuickCheck** over random plans × random worlds |
| G3 | rung ladder (batch/pipeline/branch/dyn) | four theorems | three of four survive as properties; `no_finite_bill_set_at_dyn` becomes **vacuous** | `shapes_eq_trace_of_le_pipeline` is nearly tautological in this rep (the shape is in the node), so the property test is cheap and strong; `bill_exact_pipeline` is a real property test |
| G4 | plan/cost surfaces, honest renderings | theorem-backed exactness at ≤ pipeline | **survives, and improves**: `Tmpl` is data, so probe rendering is exact and `{#3}` splice positions are printable | equal or better |
| G5 | sharing is the meaning | `Ω` is a function — a *type* | pure denotation keeps `World = forall c. SCode c -> Q c -> El c`; the IO runner needs a cache to honour it | denotation: equal. Runner: a tested invariant, as in agent-functor |
| G6 | trace agreement with hand specs in named worlds | four `decide +kernel` proofs | golden tests | theorem → golden. Cheap, and honestly good enough for what it checks |
| G7 | soundness by construction (the checker's type) | `Raw → Except CheckError (Plan [] Unit)` | `(forall s. Plan s ()) -> Either Refusal Checked` — the same reading of the same signature | **survives in form**; loses "the elaborated term is priced before it is built", since in Haskell the term is built first (a diverging builder hangs rather than refuses) |
| G8 | axiom pinning, no `native_decide` | `#print axioms` empty | — | **lost entirely.** There is no kernel |
| G9 | one meaning, congruence free | `denote` is *the* fold; `run`/`trace` by definition | same discipline, enforceable by module structure | design property, not a theorem; adequacy of the IO runner is property + golden |
| G10 | refusal UX + coverage audit | 201 byte-pinned diagnoses, audit forbids untested sites | ~60 refusals stay ours and keep the battery; ~55 become GHC's | **the largest loss.** See §1.8's census |
| G11 | per-run certification | `certify_sound`, no axioms | `certify :: Checked -> Log -> Bool` + property test | code survives; the soundness statement becomes a property |

## 2.2 Where analysis degrades from theorem to property test, precisely

Everything in `Cost.lean`, `Level.lean`, `Denote.lean` and `Certify.lean`
survives **as code, unchanged in shape** — these are first-order data and folds,
REPORT B's PORTABLE column, and that assessment is right. What does not survive
is the quantifier. Concretely, four statements move:

1. `bill ∈ leaves(costTree p)` — from a theorem to a property over generated
   plans and generated worlds. Generation is easy here (the world is a total
   function of the question; every answer type is inhabited), so a few hundred
   lines of QuickCheck gives high confidence. It is not `bill_mem_leaves`.
2. `denote` adequacy against the IO runner — from `Plan.adequacy` (stated at
   `Id`, with the `IO` side already a trust boundary in Lean) to a differential
   test between a pure runner and a mock oracle. Note that this one was *already*
   a trust boundary in Lean, so the loss is smaller than it looks.
3. `level p ≤ branch` — from a theorem about every accepted *program* to a fact
   about a datatype. The residual risk is not "a user writes `dyn`"; it is
   `unsafeCoerce`, an orphan instance, a `-XSafe` violation, or a future
   maintainer adding a constructor. Mitigations: `{-# LANGUAGE Safe #-}` on the
   core module, `Trustworthy` on exactly one, and a test that folds over every
   constructor so a new one breaks the build. That is a discipline, not a proof.
4. The `checkPlan` refusals themselves — in Lean, `parseAndCheckRaw_eq` proves
   the CLI, the MCP tool and the battery accept and refuse the same texts with
   the same messages. In Haskell that becomes "there is one function and three
   callers", verified by reading.

## 2.3 Probe soundness when users hold real Haskell functions

This is the question that decides whether the library is worth building, and the
answer is **it is only sound if you do not let them**.

If `Tmpl` is first-order (§1.3), the probe rendering is *the template*, and what
`plan` prints stands in exactly the relation to the run that
`Explain.planLines` at `Env.probe` does in Lean: the words that are not answers
are the words that will be sent, and the words that are answers are shown as the
names of their own binders. That is sound, and it is checkable — `shapes` and
`asks` are folds of the value.

If you admit `Opaque :: (ProbeEnv -> Text) -> Tmpl s`, then for that node:
`plan` prints a fiction, `cost` cannot bound tokens, and the batch/pipeline
distinction is unknowable (an opaque function might mention no answer, or every
answer). REPORT A's finding that agent-functor's `plan` prints
`prompt reviewer` rather than the brief is precisely this failure, arrived at by
default rather than by choice. The design therefore: `Opaque` exists, in
`Agentic.Plan.Unsafe`, is structurally detectable, downgrades the node's rung to
`opaque` in every report, and is refused by `checkPlan` without an explicit
`allowOpaque`. **A user holding real Haskell functions is fine at construction
time and forbidden inside a prompt.** That line is the whole of the analysis
story, and it is the line agent-functor did not draw.

The same line applies to `Case`: agent-cat's `case` scrutinises a variable, and
so does `IfFlag`/`OnVerdict` here. There is no `Case :: (Env -> t) -> (t -> Plan)`
node, so arms are always in the term and `costTree` is always finite.

---

# Part 3 — The verified-evaluator story: three options, priced

## Option A — pure Haskell, property and golden tests

**What you build.** Core types and `Plan` (~1,200 lines); the quasi-quoter
(~700, and Template Haskell is fiddly — hole resolution, `Loc` capture,
indentation, the `promptFile` hash protocol); `checkPlan` with ~60
position-carrying refusal sites (~900); `level`/`costTree`/`explain` folds
(~700); `denote`/`trace`/`certify` (~600); the property battery, ~80 properties
(~800); the refusal battery, ~200 cases plus the coverage audit (~1,300); a
runner — ACP client, content-addressed store, fork/resume, preflight (~2,500);
CLI and MCP server (~900).

**Price: ~33–37 focused days** greenfield, and that assumes no live-agent
acceptance surprises, which REPORT A says is where agent-functor's last two
steps stalled.

**What it buys.** Real confidence in the folds. QuickCheck over generated plans
and generated worlds is a strong test regime here — the world is total, every
answer type is inhabited, and the properties are shrinkable. Golden tests over
`plan`/`cost` output pin the surfaces byte-for-byte, which is agent-functor's
best-demonstrated discipline (`REFACTOR.md`'s normaliser keeps everything the
tool computes verbatim while collapsing model prose).

**What it does not buy.** Nothing about `denote` is *proved*. G8 is gone. And
the thing the owner's values put first — "every operation bound to its
denotation by theorem", "the checker's type is the type-soundness theorem" — is
reduced to the second half of that sentence, which is genuinely still true
(`(forall s. Plan s ()) -> Either Refusal Checked` is a reading of a signature)
but is much less than what exists today.

## Option B — Liquid Haskell on the evaluator core

**Realistic scope**, per REPORT C's measured numbers: ~1.7 lines of annotation
per 100 LoC, 96% of recursive functions proved terminating across major
libraries. Applied here it would carry: totality of every fold, `costTree`
finiteness, budget arithmetic (`maxRevisions`, `maxQuestions`, `atMost`)
including the "fuel never exhausted" class of facts, and no-partial-function
guarantees in the checker.

**What it cannot carry, and this is disqualifying for the flagship.**
Refinement equality translates to builtin SMT operators and cannot be customised
via `Eq` instances. agent-cat's central object is site-keyed extensional
equality whose kernel *is* workflow equality (`Plan.Equiv` is the kernel of
`denote`). LH cannot see that as equality, so `bill ∈ leaves`, `minFold ≤ bill`,
and every morphism equation stay out of reach. A general `denote` is also not
structurally recursive without a hand-supplied metric — survivable, since fuel
already exists, but it is annotation work.

**Price: +5–8 days on top of Option A**, plus a standing SMT-flakiness tax that
is well documented and unpleasant in CI.

**Verdict: not worth it for the flagship, plausibly worth it for the budget
arithmetic** if Option A is chosen. It is a totality checker here, not a proof
assistant, and it should be described that way rather than sold as verification.

## Option C — two languages: Haskell surface, `.wf` as IR, Lean keeps everything

**The elaboration boundary, specified.** The Haskell frontend emits **`.wf`
source text**, not a serialized `RawProgram`. Three reasons, in order of weight:

1. It goes through the *existing single front end*. `Dsl.parseAndCheckRaw` is
   still the only entry, so `parseAndCheckRaw_eq` — "the CLI, MCP
   `workflow_check` and the battery accept and refuse the same texts with the
   same messages" — is still true and still means what it means. Emitting `Raw`
   directly would bypass every parse-level refusal and require a new trusted
   decoder.
2. The output is readable and reviewable. `agent-cat plan` on it shows a human
   what their Haskell meant, and the MCP "one self-contained program" contract
   is *better* served (imports are already refused there; the frontend inlines).
3. No new format, no versioning problem, no second serializer to keep in sync.

**Why the emission is easy.** A `Plan` built with `Wf.do` is already in A-normal
form — every intermediate is bound — which is precisely the normal form round
18's `Norm.lean` is being written to produce. The pretty-printer walks the term,
mints `.wf` binder names from the `Var` levels, prints each `Tmpl` as a fenced
block with `{name}` holes, and emits the shape words (`ask model "x" served by
"deep" independent draw 2`). It is a few hundred lines and it has no analysis in
it, because the analysis stays in Lean.

**Source maps, which buy back most of G10.** Every emitted statement carries a
trailing comment `-- @src Harden.hs:41:7`, from the `HasCallStack`/TH `Loc`
already captured for refusals. `agent-cat --source-map` rewrites a diagnosis'
position to point at the Haskell before printing it. So a budget refusal, a
quorum bound, an ill-kinded hole that slipped past Haskell's types — all still
land on the author's own line. The `.wf` positions remain available (`--no-source-map`)
for anyone reading the generated text.

**What the Lean checker still catches after a Haskell-side bug.** Precisely:
every *well-formedness* bug. If the frontend emits a program that is ill-kinded,
over-budget, non-totally-eliminated, above the branch rung, shadowing, or with a
hole naming nothing, the Lean checker refuses it, and the refusal is a real
refusal with a real position. The frontend therefore **cannot make the runner
unsound**, and the flagship guarantee still covers everything that is run.

**What it does not catch, and this is the honest limit.** It catches no
*fidelity* bug. A frontend that emits a well-typed program which is not the
program the author wrote — a mis-ordered panel, a hole bound to the wrong
`Var` because of a level-minting off-by-one, a lost `draw` index — produces a
perfectly checked, perfectly priced, wrong workflow. Nothing on the Lean side
can know. Mitigation is differential testing: the Haskell side computes its own
`shapes` and `asks` folds (cheap — they are the same folds, and they are the
part that is nearly tautological), emits `.wf`, and a test asserts
`agent-cat plan --json` agrees. That is a real second implementation of two
small folds, and it is the price of the seam. About 3 days of the estimate
below.

**Price: ~13–16 focused days.** Builder types and `Var`/`Tmpl` (3), the
quasi-quoter (4), the pretty-printer and binder minting (2), source maps and the
CLI flag (1½), differential folds and the battery (3), docs and the worked pair
(1½). **And round 18 is not run** — its 10–11 days come back, because the
application, lambdas, composition, `$`, `.`, `>>>`, `>>=`, partial application,
higher-order `let`s and the whole `Norm.lean` normalizer *are Haskell*, already
implemented, already with the Haskell Report's fixities, which is what ruling 9
says the answer should be anyway.

That last sentence is the strongest single argument in this document and it
should be weighed before anything else: **round 18 is a plan to reimplement a
fragment of Haskell inside a `.wf` parser, for a Haskell author, and Option C
gets it from GHC for free while keeping every theorem.**

---

# Part 4 — The three-way comparison

| Dimension | (a) Continue the DSL — round 18 as designed | (b) Pure Haskell library — `Plan`-in-Haskell / improved agent-functor | (c) Hybrid — Haskell frontend, Lean kernel |
|---|---|---|---|
| **Guarantees kept** | All eleven. G1 quantified over every accepted program; ~530 theorems; empty axiom sets | G1 by datatype, G2/G3/G6/G9/G11 as property + golden, G8 lost, G10 at ~30% | All eleven, **for everything that runs**. G1 quantifies over emitted IR, and the emitted IR is what runs. G10 survives via source maps except for the ~55 refusals GHC now owns first |
| **Authoring ergonomics (this owner)** | Sentence-like, tiny, no tooling. Round 18 adds Haskell's operators but explicitly "does not make the surface shorter". No HLS, no Hoogle, no REPL, no packages | Best. Real modules, HLS, Hoogle, `cabal repl`, arbitrary construction-time abstraction (`foldr` over `[1..n]` for a cadence — agent-functor's `workLoop`, which is a genuinely nice answer) | Same as (b) for Haskell-authored workflows; `.wf` remains available and hand-authored for the ones that want to read like a page |
| **Errors for a non-expert** | Best by a distance: position, one sentence, escape, 201 cases pinned byte-for-byte, coverage audit | Mixed. Three of the four commonest mistakes get a good message (two of them ours); the fourth is an ambiguous-type-variable error and cannot be fixed. GHC owns ~55 diagnoses in GHC's words | (b)'s Haskell errors *plus* Lean's refusals mapped back to Haskell positions. Strictly better than (b), strictly worse than (a): a mistake is now diagnosed by whichever layer sees it first, and the author must learn two voices |
| **Cost from here** | **10–11 focused days** (owner's own estimate, adversarially attacked, with a pre-agreed cut line: option (b), refuse an arrow in a `let` parameter annotation, kills the higher-order path in one line) | **~33–37 days** greenfield; **~25 days** if agent-functor's runtime is adopted — someone else's 28k lines, 13 documented holes, four operational (MCP runs unresumable, `Sample` drops unaudited, lexical `canonicalizePath`, two live acceptance runs never done). Plus writing off ~16k lines of Lean | **~13–16 days**, and **round 18's 10–11 days come back**. Net ≈ +3 to +5 days against (a), for the whole of Haskell as the macro layer |
| **Maintenance** | ~107 s and several GB per `DslFlagship` elaboration; never two Lean builds at once (two concurrent runs exhausted 48 GB); ~350 pinned assertions; the `include_str` hazard; six smoke binaries run serially | GHC builds in seconds; HLS works; but every guarantee is now a test you must keep green, and property tests rot quietly in a way theorems do not | Both build systems. The Lean side is unchanged (same 107 s, same serialization discipline); the Haskell side adds a cabal project and a TH dependency. **Two error surfaces and a source map that will drift** is the real recurring tax |
| **MCP / self-contained program** | Best. `workflow_check(source)` takes one text; `importRefusal` fires before parsing; an agent can *author* a workflow, which is the tool's stated purpose | **Worst, and possibly fatal.** A "program" is a Haskell value. `workflow_check(source)` would need GHC at run time, or ship a mini-interpreter, or accept only pre-built plans. The stated purpose — "an agent can be driven by a workflow instead of being trusted to remember one" — does not survive an agent having to emit Haskell the server cannot compile | Unchanged from (a): MCP still takes `.wf`, agents still author `.wf`, humans may author Haskell. **This is (c)'s second-strongest argument** |
| **Multi-vendor backends** | Today: two adapters, no type-level model/backend pairing, no preflight. The gap is real but small — Lean's dependent types make agent-functor's phantom `BackendTag`/`AcceptsModel` trick *easier* than it is in Haskell | Best today: four backends, live-verified against three simultaneously, mispairing is a type error, preflight collects all errors before any spend, model-catalogue abstinence on evidence (`"gpt-5"` is a substring of all twenty advertised codex models) | Lean-side, i.e. (a)'s position, plus the freedom to port agent-functor's design deliberately. ~3 days either way, orthogonal to this decision |
| **Risk** | The language finishes before the tool is useful. agent-cat's runner is thin next to agent-functor's; eighteen rounds of surface with two adapters and no fork/resume is a real exposure. Plus the campaign's own recorded reopening condition: "if a third [unspellable normal form] appears, this page is wrong" | Losing the thing that makes this project *this* project. G1 demotes from a type-soundness theorem to a linter; the refusal battery becomes a test of a code generator. And adopting agent-functor means depending on another author's unfinished 28k lines | Drift. Two surfaces, two diagnoses, a source map that must be maintained, and the possibility that nobody writes the Haskell frontend because `.wf` is already good enough. Also: **a generated `.wf` breaks the identity between the text a human approved and the term the theorems are about**, which REPORT B names as the largest single write-off |

## Prose on the three

**(a) is the safe, designed, cheap option, and its cost estimate is the only one
in this document that has been adversarially attacked.** Sixty findings, three
fatal, all closed; a re-elaboration risk of "near zero" because `Dsl.lean`,
`Explain.lean` and `DslFlagship.lean` are not edited for content; a pre-agreed
de-scoping lever. Nothing else here has been through that. If the decision is
made on evidence quality rather than on ambition, (a) wins outright.

What is uncomfortable about (a) is what it is *for*. Round 18 imports
application, `.`, `$`, `>>>`, `<<<`, `>>=`, `=<<`, lambdas, partial application
and higher-order `let`s, at Haskell's own fixities, under a ruling that "the
Haskell Report is the default answer to every syntax question" — for a veteran
Haskell author. The 3½ days of parser work and 4 days of `Norm.lean` are days
spent reimplementing beta reduction, a fixity table, a position discipline and a
node budget that GHC has had since 1990. §5.5's three-line sharing divergence,
which needed a "source-versus-term criterion" to get right, is one uniform rule
in Haskell. That is not an argument that (a) is wrong; it is an argument that
(a)'s round 18 specifically is the expensive way to buy what (c) gets free.

**(b) is the option the owner's values argue against most clearly, and the one
the owner's fluency argues for most clearly.** The library in Part 1 is good —
better than agent-functor by a wide margin, because the prompt is first-order and
the continuation binds a name rather than an answer. But it trades every theorem
for a test suite, it makes the MCP surface hard, and it starts from either
thirty-five days of greenfield or a dependency on someone else's unfinished
codebase. Its honest case is: *if the goal has changed from "meanings first" to
"ship an agent runner that people use", (b) is the fastest route to the second
goal and the theorems were never load-bearing for it.* That is a legitimate
position and the owner should be asked directly whether it is his.

**(c) is additive rather than substitutive, and that is the point people miss.**
The Lean side is *unchanged*: same checker, same theorems, same CLI, same MCP,
same battery, same `example/harden.wf` byte-identical and kernel-pinned. `.wf`
stays a hand-authored surface at its landed round-17 form. What is added is a
second front door for people (one person) who would rather write Haskell, whose
output goes through exactly the same door as everyone else's. There is no
"IR-ification" of the language unless the owner stops writing `.wf`, and that is
his choice to make later, per workflow, rather than now, once, for everything.

---

# Part 5 — Recommendation, and the dissent

## The recommendation

**Take (c), staged, and shelve round 18 rather than running it.**

1. Ship round 17 as landed. It is done.
2. **Do not run the round-18 campaign.** Its design document is good and does not
   rot; it stays available. Its 10–11 days are the budget for step 3.
3. Build `agent-cat-hs`: the front half of Part 1 — `Var`, `Tmpl`, the `[prompt|…|]`
   quasi-quoter, the `Wf.do` bind, panels, `revising`, typed addressees —
   emitting `.wf` with `-- @src` comments, plus `agent-cat --source-map`.
   ~13–16 days.
4. **Bake-off.** Write the same three real workflows twice: once in `.wf`, once
   in Haskell. Not the flagship — three workflows the owner actually wants to
   run. Then decide whether `.wf` remains the authored surface, becomes a
   second-class one, or the Haskell frontend is deleted. The decision is cheap to
   reverse in either direction, which is the main reason to sequence it this way.
5. Regardless of the outcome, port two things from agent-functor, because they
   are orthogonal and both are better than what exists: the **content-addressed
   leaf store with fork/resume as one code path** (which is `Ω`-is-a-function
   made durable, and is the strongest single idea in that repository), and the
   **typed backend/model pairing with preflight** (easier in Lean than in
   Haskell). ~5–6 days, and they are the difference between a language and a
   tool.

The reasoning in one line: **the theorems and the refusal UX are the part Lean
does better and Haskell cannot replace; the macro layer and the tooling are the
part Haskell does better and Lean is about to spend eleven days imitating.**
Option (c) assigns each half to the language that already has it, and the seam
is a pretty-printer with a source map.

## The strongest counter-argument

*This is a real dissent. It is the argument I would make if I were arguing the
other side, and I think it is close to winning.*

**The smallness is the product, and a Haskell frontend cannot preserve it.**

Eighteen rounds did not buy expressiveness. They bought *refusals*: no reserved
words, no expression language over answers, one binding shape, two consumption
sites and no third, no shadowing, elimination total, arms export no bindings, a
closed two-entry panel menu, no polymorphism, no recursion, no data types beyond
four kinds. The value of that list is not that the resulting programs are
checkable — plenty of things are checkable. It is that **you can read the page
and know what happens**, and that a question's identity is decided by reading,
not by evaluating.

A Haskell frontend has all of Haskell at construction time. That is sold above
as the feature; it is also the loss. A `.wf` file emitted by four hundred lines
of Haskell with type classes, a `Map` of reviewers and a `foldr` over `[1..n]`
is checked, priced, refused-or-accepted, and **unreadable as intent**. The
theorem still holds over it. The reason the owner wanted the theorem does not.
Rule 5's "a question is closed exactly when every hole it wrote named a define,
which the preamble at the top of the file decides" is a statement about a human
reading a file. Under a Haskell frontend, deciding which questions are closed
requires running the generator.

Three supporting points:

* **The MCP purpose is the tell.** "An agent can be driven by a workflow instead
  of being trusted to remember one" requires the workflow to be one text an
  agent can read *and write*. `.wf` was designed for that reader. Haskell was
  not, and the frontend does not help — an agent authoring a workflow will still
  write `.wf`, which means the `.wf` surface must stay first-class anyway, which
  means round 18's question — *is the `.wf` surface good enough for real
  programs?* — is still live and still has to be answered.
* **Two surfaces is not additive, it is multiplicative.** Every future
  feature — a new panel rule, a fifth kind, a change to `revising` — must land
  in the Lean checker, the `.wf` parser, the Haskell builder, the pretty-printer,
  the source map, and two batteries. The estimate above prices building the
  frontend, not carrying it. Round 18's estimate, by contrast, prices work that
  makes the *one* surface complete and then stops.
* **(c)'s cost estimate is the softest number in this document.** Round 18's
  10–11 days survived sixty adversarial findings. The 13–16 days for the
  frontend has had no adversarial pass at all, its hardest component is Template
  Haskell (which is where estimates go to die), and its differential-folds item
  quietly admits to a second implementation of the analysis. A fair
  risk-adjusted comparison is probably 10–11 days against 20–25.

**The dissent's recommendation, stated fully so it can be chosen:** run round 18
as designed, with option (b) held in reserve as the cut line; spend the
following two weeks on the runner (content-addressed store, fork/resume,
preflight, typed backends) so the tool catches up to the language; and revisit
the Haskell question in six months, when there are ten real workflows to read
and it will be obvious from the text whether the surface is too small.

---

## Appendix — things true under every option

1. **The prompt must be first-order.** agent-functor's opaque `a -> Prompt` is
   the single defect that makes its `plan` useless and its `cost` shape-blind.
   Whatever is chosen, do not let a prompt become a function.
2. **Content addressing is the invalidation.** No dependency cone is needed; a
   perturbed leaf changes the next leaf's rendered brief, hence its key, hence
   its miss. Build the store.
3. **A hit is a replay, not a reproduction.** Mark it `Cached`, never `Done`.
4. **Salt the key with backend and model**, or a fork onto another model reports
   someone else's work as the new model's.
5. **Acts are never cacheable.** A cached `verify` serves a stale "tests pass".
6. **`verify` runs the checks itself; `agentVerify` trusts a claim.** agent-cat
   does not draw this distinction and should.
7. **The `{name}` hole spelling should be the same in both surfaces** if there
   are ever two, so a prompt can move between them unchanged.
