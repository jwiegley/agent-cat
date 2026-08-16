# The Haskell question

*A decision page for the owner: continue the `.wf` surface, replace it with a
Haskell library, put a Haskell surface in front of it, or ship less language than
round 18 designs. Four options, priced from the campaign's own line items.
Nothing here is approved.*

*This page supersedes `haskell-question-draft.md`, which was written before the
adversarial pass. Forty-seven findings from two attackers — one on the library
design, one on the comparison and the recommendation — are applied here; six were
fatal. §0.2 names what each cost. The draft's recommendation is **not**
preserved: it rested on a false premise (that round 17 has shipped — it has not)
and on an option set that omitted the option which dominates it.*

Sources: the agent-functor autopsy, the agent-cat guarantee-and-cost inventory,
and the prior-art sweep, all three commissioned for this question; plus direct
reads of `Agentic/Core/{Plan,Question,Cost,Level,Explain,Dsl}.lean`,
`Agentic/Core/Dsl/{Syntax,Parse,Check}.lean`, `cli/AgentCat.lean`,
`test/DslSmoke.lean`, `example/{harden,library}.wf`, and
`doc/research/dsl-redesign/{GRAMMAR.md, expr-design.md, calculus-design.md,
fn-import-design.md, fn-import-attack.md}`.

**`expr-design.md` — round 17, approved 2026-08-15, and by GRAMMAR.md's own note
the design of record "which supersedes the grammar below where they disagree" —
was not read by the draft.** Three of its comparisons were therefore against
superseded text. It is read here, and §1.11 and §3.4 are re-run against it.

---

## 0. The one-paragraph answer

The best-possible Haskell library is not an arrow library, not a selective
functor, and not a graded monad with `Frag` in the type. It is `Plan` itself,
transliterated — the same five-former first-order syntax, with the continuation
of an `ask` a Haskell lambda whose argument is a *variable token* rather than an
answer, and the prompt a first-order `Tmpl` built by a quasi-quoter rather than
an arbitrary `Env Γ → String`. That library is worth designing, and Part 1
designs it. What it costs is not "every theorem" in the abstract: it costs G7
specifically, which is the one the owner's values name twice, and it costs G8
entirely, and it demotes G10 to a number nobody has counted. **But the option
that dominates on this page's own reasoning is neither the library nor the
hybrid.** The strongest argument the draft could muster for a Haskell frontend
was that round 18 spends eleven days reimplementing beta reduction, a fixity
table and a normalizer that GHC has had since 1990. That is an argument against
*the calculus*, not against the DSL, and its cheapest answer is to cut the
calculus rather than to add a second language. Ship the do-core — two days — and
the surface keeps everything the theorems are about, in the text a human reads.
The Haskell question then reduces to one capability, **static iteration over
data**, which is real, which neither round 17 nor round 18 can express at any
price, and which — this is the finding that changes the picture — is delivered by
a program that *prints* `.wf` text, not by a typed builder. The typed builder is
redundant with the Lean checker that backstops it, and §5.2 lists exactly what it
catches that the checker would not.

### 0.1 The four options, named once

| | Option | What ships |
|---|---|---|
| **(a)** | The round-18 campaign as designed | The do-core *and* the static function calculus: lambdas, `.`, `$`, `>>>`, `<<<`, `>>=`, `=<<`, partial application, higher-order `let`s, `Norm.lean` |
| **(b)** | A pure Haskell library | `Plan`-in-Haskell as corrected in Part 1. `.wf` is deleted or frozen; the Lean side is written off |
| **(c)** | The hybrid | A Haskell frontend emitting `.wf` as an IR into the unchanged Lean checker and runner |
| **(d)** | The do-core, calculus descoped | `.wf` keeps do-notation, the deleted `answer`, default-text parameters, the trailing-bind refusals — and never grows lambdas, composition or operators. Authors who need abstraction get it from (b)/(c) later, or never |

### 0.2 What the adversarial pass changed

Six findings were fatal. Each is repaired in place and named here so a reader can
check the repair rather than take it on faith.

| Fatal | What was wrong | The repair |
|---|---|---|
| **Round 17 has not shipped** | The whole cost case rested on believing it had. `Parse.lean:523` still carries `answer` in `stmtWords`; `:912` still parses `answer name` as a body terminator. Shelving round 18 does not return 10–11 days of pure calculus work — round 18 *bundles* the do-core | Every cost row re-derived from `calculus-design.md` §10.6 and `expr-design.md` §8.9. Shelving the calculus returns ≈ 8–9 days and **retains** a ~2-day do-core obligation. §3 |
| **The option set omitted (d)** | The draft's own strongest argument is an argument against the calculus, and its cheapest answer is to cut the calculus | Option (d) added as a fourth column, priced by subtraction from §8.9. The recommendation is argued against it explicitly. §3.4, §6 |
| **The differential test cannot detect the bug it was offered against** | `Cost.shapes` (`Cost.lean:321–326`) carries `⟨c, s⟩` and no prompt text at all; `Cost.asks` (`:336–341`) renders every in-scope answer as `default`. A hole mis-bound to a different `Var` *of the same kind* renders identically. And the `agent-cat plan --json` the test calls for was deliberately refused (`cli/AgentCat.lean:63–66`) | Replaced by golden `.wf` pins per worked example plus a probe-env discrimination requirement — each binder gets a *distinct* witness — plus a round-trip property. Repriced 3 → 5–7 days. §3.3.2 |
| **A multi-question helper cannot be a do-statement** | Both binds took a `Step` on the left, and a `Step` is exactly one question or one panel. Every reusable multi-question fragment would have had to be CPS — which is the point-free plumbing bill §1.1 opens by claiming the design does not pay | A `Codensity`-shaped `Wf s c` wrapper and a two-instance `Bindable` class. §1.2, §1.6 |
| **The sharing rule was false in agent-cat's own vocabulary** | "A `Step` used twice is two questions" conflates events with questions. `Ω : (c : Code) → Q c → El c` is a function of the question alone, so two identical questions are **one answer**, `billFresh` 2, `billMemo` 1 (`calculus-design.md:1686–1691`) | Restated in Ω's terms as two rules. Haskell does not settle §5.5's three lines into one; it deletes line 2 and merges the rest, and it inverts the line round 18 thought hardest about. §1.7 |
| **`Mistake 3`'s transcript cannot be produced by either printed signature** | Under the monomorphic `>>` the program compiles silently as an act; under `Discardable` nothing determines `c` and GHC emits an ambiguity error. Either way the verdict was wrong, and it underwrote one of the three "good message" cases | The `Discardable` bind is adopted **and the polymorphic `ask` is deleted from the export list**. Then every `Step`'s code is ground at the call site, the ambiguity class disappears entirely, and the surviving verdict is "equal to round 17's refusal, in worse prose". §1.6, §1.11 |

Forty-one further corrections are applied throughout. Nine that changed a
conclusion rather than a wording: G7 moves from "survives in form" to structural
(§2.1); rule 6 gets a row of its own, **"becomes a silent meaning change"**
(§1.10); `runPlan` is gated on `Checked` (§1.2); lazy construction turns
recursive builders into refusals rather than hangs — a *recovered* guarantee
(§1.8); Safe Haskell is inverted and its mitigation replaced (§2.2); the emitter
carries four analyses and a near-certain brace-escaping bug (§3.3.1); the source
map is blocked on an open bug and breaks the property offered as reason #1 for
emitting text (§3.3.3); the fluency appeals are cut and replaced by the
capability argument (§4.2); and the census is recounted, which moves one figure
by 60% in the direction that flattered (b) (§0.3).

### 0.3 The census, recounted

The draft called the census "more important than the mechanism" and then sourced
none of it. Every figure below carries the command that produced it, run in the
repository root on 2026-08-16.

| Figure | Draft said | Actual | Command |
|---|---|---|---|
| Lines of Lean written off under (b) | ~16k | **26,155** under `Agentic/`; **29,663** with `cli`, `mcp`, `test` | `find Agentic -name '*.lean' \| xargs wc -l \| tail -1` |
| Theorem/lemma declarations | ~530 | **867** under `Agentic/` | `grep -rhoE '^ *(theorem\|lemma) ' Agentic --include='*.lean' \| wc -l` |
| Battery cases | 201 | **201**, confirmed twice: `batteryCases` 190 + `batteryCasesM` 11, and computed at run time by `test/DslSmoke.lean:881` | entry count over both lists |
| Surface implementation | 2,662 lines | **2,662** — `Syntax` 367, `Parse` 1,316, `Check` 979 | `wc -l Agentic/Core/Dsl/*.lean` |

The write-off figure is the one that matters: (b) discards 40–80% more Lean than
the draft credited it with, and the error ran in (b)'s favour.

**The §1.10 fate census is an unverified estimate and is labelled as one.** The
draft's five-way partition of the 201 diagnoses (~30 / ~15 / ~55 / ~60 / ~40) has
no derivation. Deriving it means walking `batteryCases`/`batteryCasesM` and
assigning each case a fate — real work, not done here. Consequently every claim
derived from it is withdrawn, including "G10 at ~30%". What survives is the
*shape* of the partition, which is argued structurally rather than counted, and
the one hard number: 201.

---

# Part 1 — The library design: `Plan`-in-Haskell

*This part is the strongest honest version of (b), and it is also the front half
of (c). It absorbs all twenty-six design-attack findings. Read it as a design
that would work, not as an endorsement of building it.*

## 1.1 The crux, named first

The pipeline rung is *static shape, value-dependent payload*. The prior-art sweep
is right that no standard class captures it: `Applicative` gives shape without
payload, `Monad` gives payload with dynamic shape, and the arrow classes
(`FreerPreArrow`, `Category` + `Strong`) give payload with static shape *at the
price of point-free plumbing*. agent-functor pays that price and its `Flow` has
no binders at all.

agent-cat already solved this. From `Plan.lean`'s header:

> the dilemma *point-free plumbing or host binding* is false, and the third
> option is to own the binder … a question's **words** are built by an `Expr`,
> an ordinary function of the answers in scope, while the question's **shape** —
> who is asked, under what scope, at which draw — is written in the term.

So the Haskell answer is: **there is no class**. Do not look for one. Expose a
GADT whose `ask` node is ask-and-bind (already A-normal, so no analysis has to
reconstruct where an answer went), carry the shape as data, and give the node a
continuation. The only question left is what the continuation's argument is.

## 1.2 The central move: bind gives you a name, not an answer

```haskell
-- Agentic.Plan (constructors NOT exported)

newtype Var s (c :: Code) = MkVar Int   -- a de Bruijn *level*; abstract
type role Var nominal nominal           -- `coerce` cannot retype an answer

data Plan s a where
  Ret     :: a -> Plan s a
  Ask     :: SCode c -> Shape c -> Tmpl s -> (Var s c -> Plan s a) -> Plan s a
  IfFlag  :: Var s 'Flag    -> Plan s a -> Plan s a -> Plan s a
  OnVerd  :: Var s 'Verdict -> Plan s a -> Plan s a -> Plan s a -> Plan s a
```

`Ask`'s continuation is a Haskell function, but its argument is a `Var s c`, and
**there is no exported eliminator from `Var s c` to `El c`**. No `answerOf`, no
`unVar`, no `Show`, no `Eq`. The only things the library exports that consume a
`Var` are `hole` (splicing into a prompt) and `ifFlag` / `onVerdict` (the two
eliminations). That is GRAMMAR.md rule 3 — *"two consumption sites, and no
third"* — made into a Haskell type rather than a parser rule. The continuation
may compute anything it likes at construction time; it cannot compute anything
*from an answer*, because it never has one.

**Verdict arms are positional, not a record.** The draft used
`VerdictArms{ … }`, and a record does not make elimination total: GHC's
missing-field check on record *construction* is `-Wmissing-fields`, a warning
inside `-Wall` and off by default, and the constructed value carries an
`error "Missing field in record construction"` thunk. `VerdictArms{ approved = p,
objected = q }` would compile, check, price, and crash *mid-run, after spending*,
on the declined path — the path rule 10 exists to make you handle. Positional
arity is the mechanism §1.7 already uses for `settled`/`unsettled`, and it is
applied here: `onVerdict v approvedArm objectedArm noAnswerArm`, order fixed and
documented.

### Traversal, and why the fold is writable

To fold under an `Ask`, apply its continuation to `MkVar depth`. But rendering a
hole means fetching the answer for `MkVar n` out of a heterogeneous environment,
and that needs a runtime witness of `c` to project safely. The draft's
`Hole :: Renderable c => Var s c -> Tmpl s` hides `c` existentially and captures
only a dictionary, so the fold is unwritable without `unsafeCoerce`. **The `Hole`
node therefore carries an `SCode` witness:**

```haskell
data Tmpl s where
  Lit  :: Text -> Tmpl s
  Hole :: Renderable c => SCode c -> Var s c -> Tmpl s
  Cat  :: Seq (Tmpl s) -> Tmpl s
```

and the probe/run environment is a `Seq (Some SCode El)` projected through
`testEquality` on `SCode`. State the residual honestly: the level-to-binder
correspondence is now an *invariant of the traversal*, not a type, so `renderAt`
returns `Either InternalError Text` and there must be a property "no plan built
through the exported API ever reaches the error branch". **In Lean that was an
`rfl`**: `Var Γ c` is membership-as-data and `Var.get` is total by construction
(`Plan.lean:128–139`). This is a fifth entry in §2.2's list, and it is the one
that hurts most quietly.

### `runPlan` consumes `Checked`

```haskell
checkPlan :: (forall s. Plan s ()) -> Either Refusal Checked
runPlan   :: Oracle IO -> Checked -> IO RunReport
plan, cost, explain :: Checked -> [Text]
```

`Checked` is abstract and constructible only by `checkPlan`. The draft's
`runPlan :: Oracle IO -> (forall s. Plan s ()) -> IO RunReport` made every
surviving refusal *advisory*: a user calls `runPlan` and spends money on a
program the checker would have refused. In Lean the only way to obtain a
`Plan [] Unit` from source is through `parseAndCheck` (`Dsl.lean:599`), which is
why the signature is the theorem. One line restores the sentence the design leads
with; §2.1 states what it does **not** restore.

### Why levels and a phantom brand, and what that costs

The literal transliteration of Lean would index by the context,
`Plan (g :: [Code]) a`. It is more precise — scope escape becomes ill-typed — and
the error a non-expert sees for a scope mistake becomes a mismatch between two
type-level lists of `Code`s inside a desugared `Agentic.Do.>>=` application.
Haskell's own lexical scoping already prevents scope escape except for
deliberately stashing a `Var` in a data structure, and that residue is caught by
a scope pass in `checkPlan`.

The draft called this trade "a *gain* against the owner's stated values". **It is
a gain in error UX and a loss in the value the owner puts first.** Rejecting the
indexed representation is precisely what costs G7 (§2.1), and it should be
recorded as the design's first deliberate divergence with that price attached,
not as a free win.

## 1.3 The four kinds, and shapes

```haskell
data Code = Text | Verdict | Flag | Receipt        -- promoted

type family El (c :: Code) where
  El 'Text = Text; El 'Verdict = Verdict; El 'Flag = Bool; El 'Receipt = ()

data SCode c where
  SText :: SCode 'Text ; SVerdict :: SCode 'Verdict
  SFlag :: SCode 'Flag ; SReceipt :: SCode 'Receipt

data Shape (c :: Code) = Shape
  { shapeAddressee :: Addressee, shapeScope :: QScope, shapeDraw :: Natural }
```

Three corrections against the draft's printed types, all of which stopped it
compiling or diverging from Lean:

* The field selector `draw` and the combinator `draw` were two top-level bindings
  of one name. The combinator is `independentDraw`; the field is `shapeDraw`.
* The draft's `One :: SCode c -> Addr p -> Shape c -> Tmpl s -> Step s c` carried
  the addressee **twice**, with nothing keeping the copies in sync — a `servedBy`
  applied after construction updates one and the renderer reads the other. Lean
  has exactly one addressee, a field of `Q.Shape` (`Question.lean:289–297`).
  `Addr p` is deleted from the node; the phantom party lives only in `ask`'s
  argument, where it has done its job before the `Step` exists.
* `draw :: Word` wraps silently at 2⁶⁴, and a wrapped draw index is a *different
  question* the author did not write. Lean has `draw : Nat`
  (`Question.lean:294–297`); the Haskell field is `Natural`.

The addressee is *typed*, borrowing agent-functor's best idea:

```haskell
data Party = IsModel | IsTool | IsPerson
data Addr (p :: Party) where
  Model  :: Text -> Addr 'IsModel
  Tool   :: Text -> Addr 'IsTool
  Person :: Text -> Addr 'IsPerson

servedBy :: Addr 'IsModel -> Text -> Addr 'IsModel
```

`served by` off a tool or a person becomes a type error rather than a refusal the
Lean checker still has to grow. GRAMMAR.md records that refusal as an outstanding
implementation obligation — *"`served by` is refused off `ask model` (no such
refusal exists today)"* — so this is the one place the Haskell types catch
something Lean does not catch **today**. §5.2 returns to it, because it is a
one-line Lean obligation that has to be written for the `.wf` surface anyway.

## 1.4 Prompts: `Tmpl` is first-order, and this is not negotiable

agent-functor's `peRender :: a -> Prompt` is an opaque function, which is why
`agent-functor plan` cannot print a brief and `cost` cannot price by shape.
Lean's `Expr Γ String` is *also* a function — but the only `Expr`s that appear in
an accepted `.wf` program are the ones `Dsl/Check.lean` builds from the `{name}`
hole grammar, so in practice the prompt is data wearing a function's type. A
Haskell library that let users pass `\env -> …` would lose that, and with it G4's
probe rendering.

So: **prompts are a first-order datatype**, per §1.2's `Tmpl`, with the two
refusals as custom type errors in the surface's own words:

```haskell
class Renderable (c :: Code) where render :: El c -> Text; codeOf :: SCode c

instance TypeError
  ( 'Text "a flag has no canonical text."
    ':$$: 'Text "A yes/no answer cannot be spliced into a prompt; ask the"
    ':$$: 'Text "question the flag decides, or eliminate it with `ifFlag`." )
  => Renderable 'Flag
```

**`Renderable` is exported abstractly** — methods hidden, with a closed helper
`renderAnswer :: SCode c -> El c -> Text` re-exported over the four codes — so no
user instance is writable. Without that, a user's own
`instance Renderable 'Flag` produces "Duplicate instance declarations" at their
instance head and turns every use site into an overlap report rather than the
surface's sentence.

**`Tmpl`'s strictness is bounded.** `Tmpl` is data, but its data is lazy Haskell
data: `Cat (repeat (Lit "x"))` and `Lit undefined` are both well-typed. For such a
node `plan` diverges, `cost`'s token interval is unbounded, and "a question is
closed exactly when its `Tmpl` contains no `Hole`" does not terminate — the same
hole `Opaque` is quarantined for, arriving through the front door and undetectable
by inspecting the constructor. So `Cat`/`Lit` are unexported, the spine is a
strict `Seq`, and the smart constructors carry budgets: `cat` forces the spine and
refuses past a stated chunk count, `lit` forces to WHNF and refuses past a stated
length.

Consequences, all of them agent-cat properties recovered:

* `shapes`, `asks`, `costTree` and `planLines` are folds of the value alone.
* **Probe rendering is exact.** `Env.probe` becomes `renderAt probeEnv`, and the
  text printed by `plan` is the true template with placeholder answers — the same
  epistemic status it has in Lean.
* Per-token cost bounds get better than Lean has today: literal chunk lengths are
  known statically **given the smart constructors above**, and excluding
  `promptFile` nodes (§1.5 item 6).
* **The batch rung is decidable from the built term — not from the text.** The
  draft claimed decidability "from the source", on the grounds that a define is
  an ordinary Haskell `Text` CAF "with no new mechanism". Both halves are false.
  GRAMMAR.md rule 5 requires a define to be **literal text expanded at parse
  time**, containing only earlier-define holes, "so expansion yields literals and
  cannot be cyclic", and closedness is decided by "the preamble at the top of the
  file". A Haskell `Text` CAF may be `a <> b`, a `mconcat`, a `Map` lookup, or
  mutually recursive with another CAF. Deciding which questions are closed
  therefore requires running the generator. That is the dissent's central charge
  (§5.1), and the draft asserted it away one section before the dissent got to
  make it. If literality matters, the mechanism that restores it is a `define`
  newtype constructible only from a string literal via the quasi-quoter; it is
  not free and it is not designed here.

### The one place the Haskell design strictly beats the landed `.wf` design

`fn-import-attack.md` A3 records that in `.wf` **a question reached through a
call can never be closed**. A parameter is always an `Expr`, so `Prompt.closed`
fails and the checker emits `Plan.ask` rather than `Plan.askC`:

> `x <- g "hi"` gives `Plan.ask .text s (fun δ => (σ δ).head) …`. Written inline,
> `Prompt.closed ["hi"] = some "hi"` (`Syntax.lean:140`, `Check.lean:315`), so
> the checker emits **`Plan.askC`**. Different constructors — not equal, not
> propositionally, not at all. The theorem holds only when every argument is a
> *name*.

So every question a round-16 library exports as a function falls off the batch
rung, and `asks_eq_of_le_batch` — the strongest thing the rung ladder says —
stops applying to exactly the code an author factors out. In the Haskell design a
`Text`-typed argument splices as a `Lit`, so `drafted guide goal shape` with
`guide :: Text` yields a *closed* question and `askC` survives across the
abstraction boundary. **This is a genuine (b)/(c) win and it is the closed-question
payoff the imports design leads with and does not deliver.**

It forces an honest restatement of rule 5, which belongs in the comparison rather
than in a footnote: closedness is decided by *the helper's type signature* rather
than by "the preamble at the top of the file". Defensible, arguably stronger, and
a different sentence.

### The escape hatch, and why it is quarantined

Someone will want `\answers -> …`. It lives in `Agentic.Plan.Unsafe` as
`Opaque :: SrcLoc -> (ProbeEnv -> Text) -> Tmpl s`, and it is *structurally
detectable*: `checkPlan` refuses any plan containing an `Opaque` unless the caller
passes `allowOpaque`, and `plan`/`cost` print `<computed at Foo.hs:41:7>` and mark
the node's rung `opaque`. This is the analysis lattice made honest rather than a
hole papered over — the same instinct as `Plan.dyn` being kept and quarantined
rather than deleted.

## 1.5 The quasi-quoter — specified, with TH's real limits

Name: `[prompt| … |]`, exported from `Agentic.Prompt`. It is not
`string-interpolate` and it is not `PyF`; it is bespoke, because a bespoke QQ is
the only place a Haskell surface can emit *(position, one sentence, escape)*.

1. **Hole syntax is `{name}`** — PyF's spelling, agent-cat's spelling, so a
   prompt can be moved between the two surfaces unchanged. `\{` and `\}` are
   literal braces. Nothing else is special. Deliberately *not* `#{}` and
   deliberately not named `i` — agent-functor's `i` shadows the most popular loop
   variable in Haskell and becomes a `-Werror` failure at every `\i ->` in an
   importing module.

2. **A hole resolves against Haskell binders in scope**, by TH `lookupValueName`.
   A name with no binding is refused. **The draft's "Did you mean `patch`?" is
   deleted**: there is no TH API to enumerate names in scope — `lookupValueName`
   answers yes/no for a name you already hold — so the suggestion cannot be
   computed for a local binder, which is every interesting case. GHC's own scope
   error carries "Perhaps you meant `patch`" and it is left to do so.

3. **A hole is typed — resolved at the type level, not in TH.** The draft had the
   quasi-quoter elaborate `{x}` to `Hole x` if `x :: Var s c` and `Lit x` if
   `x :: Text`. **Template Haskell cannot do this.** `reify`/`reifyType` fail on
   local bindings ("can't be reified because it is local"), and `patch`, `guide`,
   `draft` all come from `<-` in a `Wf.do` block or from a lambda parameter. The
   repair is to emit one overloaded call and let instance resolution dispatch:

   ```haskell
   class Splice a where splice :: a -> Tmpl s
   instance Renderable c => Splice (Var s c)
   instance                 Splice Text
   ```

   The `Renderable 'Flag` `TypeError` still fires through the first instance, so
   §1.11's Mistake 1 survives. Two costs to record: `OverloadedStrings` makes a
   bare string literal in a hole ambiguous (`Splice a0`), so defines must be
   `Text`-annotated CAFs; and the error for an unspliceable value is now
   "No instance for (Splice Int)" rather than a sentence.

4. **Indentation**: strip the common leading indent ignoring blank lines (PyF's
   rule), keep interior newlines (`__i`'s rule), and re-indent a multi-line
   spliced value to the column of its hole — which of the three surveyed packages
   only `neat-interpolation` does, and which is the difference between a nested
   prompt that reads and one that does not.

5. **No `QuasiQuotes` sprawl mitigation is possible.** The extension is required
   at every use site and cannot be re-exported. One line in a
   `default-extensions` stanza per package, and it is honest to say it is there.

6. **`[promptFile|prompts/plan-probe.md|]`, bounded.** agent-functor's design —
   check the path in `Q` at compile time, read the file at run time so editing
   prose needs no rebuild — is genuinely good and is kept, with the hole set and a
   content hash embedded so a changed hole is a refusal rather than a silently
   different question. **But run-time prose undoes what §1.4 just bought, and the
   draft did not say so.** For a `promptFile` node the `Lit` chunk lengths are not
   known statically; `agent-cat cost` computed at 10:00 does not price the run at
   10:05; and the question `Q` contains the prompt string, so the content-addressed
   key changes whenever the prose changes and "asked once, everywhere" holds only
   between edits. This is the `include_str` hazard, which Part 4 charges to the
   Lean side as a maintenance cost, reintroduced as a feature. So: `promptFile`
   nodes are marked **`prose-at-run-time`** in `plan`/`cost` output — the treatment
   `Opaque` gets, one rung down — their token interval is reported unbounded above
   unless a `--pin-prompts` mode hashes at check time, the reference states that a
   prose edit changes the question and invalidates the store, and a
   `promptFileStrict` variant embeds the content at compile time for anything that
   must be priced.

**Every diagnosis originating inside a prompt loses column precision.** TH cannot
attach source spans to generated expressions: a quasi-quoter's output has no
interior positions, so every type error arising from spliced code is reported at
the *whole quasi-quote*. §1.11's transcripts are re-rendered accordingly, and this
is a real regression against agent-cat's "a position" — one that the source map of
(c) cannot recover, because it cannot map what TH never recorded.

## 1.6 Statements, do-notation, and what `>>` means

`QualifiedDo` alone rebinds `>>=`, `>>` and `fail`. It does **not** rebind
`fmap`/`<*>`/`join`; those are rebound only when `ApplicativeDo` is also on. That
matters operationally, because `ApplicativeDo` is a module-wide extension a user
can acquire by accident from a shared `default-extensions` stanza, and when it is
on GHC tries to desugar `Wf.do` applicatively and reports "Variable not in scope:
`Agentic.Do.<*>`" at a desugared position, for a program the author did not
change. It is also *semantically* unsatisfiable: `<*> :: Plan s (a -> b) -> Plan s
a -> Plan s b` cannot be written, because an `Ask`'s continuation binds a `Var`,
never a value.

**So `ApplicativeDo` must be off in any module containing a `Wf.do` block**, and
`Agentic.Do` exports `fmap`, `<*>`, `join` and `fail` at types whose contexts are
`TypeError`s naming the extension and the fix. Four lines of code convert an
unreadable scope error into one of ours.

```haskell
module Agentic.Do ((>>=), (>>)) where

class Bindable f where
  (>>=) :: f c -> (Var s c -> Plan s a) -> Plan s a
  (>>)  :: Discardable c => f c -> Plan s a -> Plan s a

instance Bindable (Step s)   -- one question, or one panel
instance Bindable (Wf s)     -- a multi-question helper

newtype Wf s c = Wf { withAnswer :: forall a. (Var s c -> Plan s a) -> Plan s a }
```

**The `Wf` wrapper is the fatal repair.** The draft's binds took a `Step` on the
left, and a `Step` is exactly one question (`One`) or one panel (`Panel`).
Therefore no user-defined helper containing more than one question could ever
appear as a do-statement, and none could be bound with `<-`. That is not a corner:
it is the whole of what round-16 functions and `example/library.wf` exist to
provide. Extend the draft's own `drafted` to two questions and its type must
become `(Var s 'Text -> Plan s a) -> Plan s a`, so the call site changes from
`patch <- drafted guide goal shape` to
`drafted guide goal shape $ \patch -> Wf.do {…}` — three helpers is three levels
of CPS nesting with the tail of the program at the innermost brace, which is
exactly the point-free plumbing bill §1.1 opens by disclaiming. Both instance
heads are ground, so no ambiguity is introduced; `ask`/`act`/`panel`/`independentDraw`
keep returning `Step` because they need the node to modify, and `Wf` is what a
multi-question library function returns.

**A statement-position question must be a receipt**, expressed as a `Discardable`
constraint with a `TypeError` at the three non-receipt codes:

```
this question's answer is discarded.
A statement-position question is an act; write `act (Tool "apply") …`,
or bind the answer with `x <- …`.
```

**And the polymorphic `ask` is deleted from the export list.** Only `askText`,
`askVerdict`, `askFlag` and `act` are exported. This is what makes `Discardable`
fire: with a polymorphic `ask`, nothing determines `c` — `Addr p` does not, and
the `Tmpl`'s `Renderable` constraints are on the *holes*, not on the ask — so GHC
reports an ambiguous type variable instead of the surface's sentence. With the
monomorphic constructors, every `Step`'s code is ground at the call site, the
message fires, and the draft's "fourth mistake, which cannot be made good"
disappears entirely because no exported combinator leaves a `Code` variable free.

The consequence must be stated rather than hidden: **rule 4's kind inference is
fully surrendered.** The draft's claim that "Haskell gets most of it for free by
unification" is withdrawn. You write the constructor that names the kind.

### Do-notation costs the language its terminator-free blocks

A `Wf.do` block's type is the type of its last statement, and `>>` returns
`Plan s a`. So a block whose last statement is an act has type `Step s 'Receipt`,
not `Plan s a`. The flagship's `then` arm ends in a bare `ask tool "apply"`
(`example/harden.wf`), so under the draft's types that arm does not typecheck
where `ifFlag` wants a `Plan`. And the `else` arm needs `stop :: Plan s a`, which
is uninhabited for arbitrary `a` because `Ret` needs a value.

The fix is `done :: Plan s ()` (with `stop = done`), arms and workflows fixed at
`Plan s ()`. **This reinstates exactly the closing word round 17 deleted** —
GRAMMAR.md's round-seventeen note reads "any Unit-valued statement may end a
block, assertions included — the requirement is the type, not a closing word".
Every act-ending block, every `stop` arm and every receipt body now ends in an
explicit `done`, and the error for the omission is a plain
`Couldn't match type 'Step s 'Receipt' with 'Plan s ()'` in GHC's words at the
closing brace, for the single commonest omission in the language. That is a *new*
mistake with no agent-cat counterpart, and it belongs in the census and in the
errors row. With the `Wf` wrapper, `blk :: Wf s 'Receipt -> Plan s ()` at least
names the terminator once per block rather than once per act.

### No statement can follow a branching, permanently

Because `ifFlag`/`onVerdict` return `Plan`, nothing can follow them in a block.
In `.wf` that is one of round 11's four *temporary* v1 deltas — GRAMMAR.md:
"branchings are terminal in their block (statements after a branch would need the
graft-through-case elaboration — same day)". Lifting it in `.wf` needs
graft-through-case. Lifting it in Haskell needs a class over `>>`, which
reintroduces the ambiguity this design just escaped by deleting polymorphic `ask`.
So under (b)/(c) the delta is permanent, and it should be scored as such.

## 1.7 Panels, revision, sharing, draws

**Panels** (rule 10, the closed two-entry menu):

```haskell
data PanelRule = AllMustApprove | AtLeast Natural
panel :: PanelRule -> NonEmpty (Step s 'Verdict) -> Step s 'Verdict
```

`NonEmpty` makes "a panel needs at least one member" unwritable — one of
agent-cat's two *exempt* battery cases ceases to exist. `AtLeast 0` and `AtLeast
k` with `k > length members` are checker refusals with positions. The quorum
read-out stays a pure function in the leaf, so the panel stays at the pipeline
rung, and `panel` costs exactly `k` questions in every world.

**`AtLeast` is not implemented on the Lean side.** `obr` shows `acat-f10` open,
and GRAMMAR.md's round-eleven note records "the panel menu ships entry one only".
Under (c) that makes `acat-f10` — with its three required theorems
(agreement-at-top-threshold, trace-independence, and the lemma that a failed
quorum never renders `object []`) — a hard prerequisite, priced in §3.3.

**Bounded revision** (rules 8 and 9), generalized over the carrier kind:

```haskell
data Round s c = Round
  { review :: Step s 'Verdict
  , amend  :: Var s 'Verdict -> Step s c }

revising
  :: Var s c -> Amendments -> (Var s c -> Round s c)
  -> (Var s c -> Plan s a)   -- settled
  -> Plan s a                -- unsettled
  -> Plan s a
```

The draft hard-coded the carrier at `'Text`. GRAMMAR.md rules 4 and 8 say the
loop subject, its carrier and its `settled` binder share **one kind**, not that
the kind is text; a verdict-carried revision is writable in `.wf` today, and the
Lean primitive is already general (`Plan.revising {c : Code} …`). One type
variable fixes it, and without it (c)'s emitter has no way to produce the general
form.

The `Pending` discipline — "on every path from the binding, exactly one `case`
consumes it, and nothing else may touch it" — is a whole class of checker
machinery in Lean, and it evaporates here because the eliminator is the only way
to build the node: there is no pending value, and `settled`/`unsettled` are
mandatory by arity. The ergonomic wrinkle is that this is CPS and does not sit
inside a `do` block as prettily as the `.wf` spelling. Recorded as a real loss.

**`Amendments` is total.** The draft's `atMost :: Word -> Either Refusal
Amendments` is unusable in the middle of a pure builder — the author threads
`Either` through the whole construction or writes `fromRight (error …) (atMost
2)`, which is what will actually happen — and it contradicts the census, which
files budget refusals under `checkPlan`'s job. So `atMost :: Natural ->
Amendments` records the numeral in the node and `checkPlan` refuses over-budget
with the surface's existing sentence (`Check.lean:597–599`: *"a bounded revision
is unrolled into the term it writes, so its bound may name at most 64
amendments"*) and the `HasCallStack` position. **No `Either` appears in the
builder anywhere**; every smart constructor is total and every refusal is
`checkPlan`'s.

### Sharing, restated in Ω's terms

The draft's rule — *"A `Var` used twice is one question. A `Step` used twice is
two questions"* — is false in agent-cat's own vocabulary, and it was the
justification offered for shelving round 18 §5.5. A question is
`Q c ≅ Q.Shape c × String` (`Question.lean:299–305`) and the world is
`Ω : (c : Code) → Q c → El c`, a total function of the question alone. Two `Ask`
nodes built from the same `Step` carry the same addressee, scope and draw and, if
the `Tmpl` renders alike, the same prompt. They are **one question asked twice**.
Two rules, in the language's own words:

> **1. One node or many, identical questions share an answer.** That is `Ω` being
> a function, and it is unchanged. `Cost.lean:127–130` rules out the other
> reading: *"a price is a fact about what is asked and of whom, not about where in
> a plan it was asked."*
>
> **2. What a repeated `Step` multiplies is *events*, not answers.** `billFresh`
> counts nodes, `billMemo` counts questions, and `agent-cat cost` already prints
> both. Resampling is `independentDraw`, and nothing else.

And the claim that Haskell settles §5.5's divergence in one rule instead of three
is backwards on the facts. `calculus-design.md:1686–1706` gives three lines:

* Line 1 — two questions *written* are two events, one answer, `billFresh` 2,
  `billMemo` 1. **Haskell agrees; unchanged.**
* Line 2 — one *source* argument substituted twice is **one** event, because a
  source argument is hoisted to one binder before substitution. **Haskell cannot
  express this**: reusing a `Step` value always builds two `Ask` nodes.
* Line 3 — one *arrow* argument applied twice is two events. **Haskell agrees.**

So Haskell does not collapse three lines into one; it **deletes line 2 and merges
what remains with line 3** — and line 2 is the one round 18 thought hardest about,
made one event deliberately "because it is what a reader expects a lambda to do".
Haskell inverts it. That is a deliberate divergence from the landed design and it
needs the owner's ruling, not a footnote. The guide sentence is unchanged in
length ("reusing a step costs twice; bind it to share"); it is one line about a
smaller language. And a `.wf` author porting a sharing idiom silently doubles his
`billFresh`, which belongs in the porting hazards.

**Draw indices** are `shapeDraw`, set by `independentDraw n`, and they key the
runner's content-addressed store exactly as agent-functor's `--reroll` does. That
machinery — content-addressed leaf store, fork/resume as one code path, `Exec`
never cacheable — is `Ω`-is-a-function made durable, it is the strongest single
idea in that repository, and it should be built whichever option wins. It is
priced once, above the table, in §3.

## 1.8 Libraries are Haskell modules

`example/library.wf` becomes `Harden/Library.hs`:

```haskell
module Harden.Library (guide, drafted, reviewed, applied, verdictSpec) where

verdictSpec :: Text
verdictSpec = "Reply with exactly APPROVE if acceptable, or OBJECTION: …"

drafted :: Var s 'Text -> Text -> Text -> Wf s 'Text
reviewed :: Var s 'Text -> Var s 'Text -> Step s 'Verdict
applied :: Var s 'Text -> Wf s 'Receipt
```

Note the types: `drafted` and `applied` return `Wf`, not `Step`, precisely because
they may ask more than one question — which is the §1.6 repair doing its job. With
it, `patch <- drafted guide goal shape` and a bare `applied patch` both typecheck
as ordinary do-statements, flat, the way `example/library.wf` writes them.

What is gained: the real module system, Hackage, HLS, Hoogle, `cabal repl`,
versioning, and the fact that `drafted`'s type *is* its arity-and-kind contract.

`fn-import-design.md`'s hard-won properties split three ways. A body cannot see
its caller: **free** (lexical scoping). Calls cannot be arguments: **unnecessary**.
Recursion cannot be written: **mostly recovered**, and the draft gave this away
wrongly.

### Recursive builders are refused, not hung — a recovered guarantee

The draft conceded that a recursive `Plan` builder "diverges at construction time
— a hang, not a refusal; mitigated only by a node budget in `checkPlan`, which
cannot fire because the builder never returns". **That is wrong in the case that
matters.** Haskell is lazy, and a recursive builder that goes through `ask` is
*productive*: `grow p = Wf.do { v <- askText …; grow p }` is `Ask … (\v -> grow
p)`, in WHNF immediately. A budgeted left-to-right consumer reaches node 4097 and
refuses without ever forcing the rest; the infinite term is never built.

So `checkPlan`'s budget is written as a strict accumulator over a *lazily
produced* node stream — `asks`, `nodes` and `costTree` as lazy producers, the
consumer stopping at `maxQuestions` — and it refuses with

> this program's construction exceeds 4096 questions; the loop around it has no
> bound

naming the `HasCallStack` frame of the last `ask`. That is exactly what
`blockAsks` refuses in Lean (`Check.lean:857`, `maxQuestions := 4096`). The honest
residue is *unproductive* recursion (`loop v = loop v`, no `ask` between), which
hangs or dies with `<<loop>>` under GHC's black-hole detector. **The flagship
property — a finite cost tree, priced before the run — is recovered for the whole
class the draft said defeats it.**

### What is genuinely lost

A library's **priming** — its top-level statements, asked once before anything the
importer writes, so a closed priming question is shared across every importing
program — becomes an explicit `withLibrary :: (Var s 'Text -> Plan s a) -> Plan s
a` the importer must remember to call. Arguably better (no spooky action), but it
is a guarantee traded for a convention. And `known here:` — the checker-verified
visibility assertion — has no Haskell counterpart beyond a bespoke pass.

## 1.9 What the Haskell types can build that `.wf` cannot spell

This subsection exists because (c) emits `.wf`, and round 18 recorded a reopening
condition about exactly this class: *"The attack found exactly one such normal
form and C31 closed it; a discarded panel is a second. **If a third appears, this
page is wrong and should be said to be wrong.**"* (`calculus-design.md:2989–2995`)

Enumerated against GRAMMAR.md's grammar block:

| # | The Haskell type admits | The `.wf` grammar says | Decision |
|---|---|---|---|
| i | `panel :: PanelRule -> NonEmpty (Step s 'Verdict) -> Step s 'Verdict` — so a panel may contain a panel | `source ::= "panel" "," rule "[" ask { "," ask } "]"` — **asks only** | Restrict the type: members are `Step`s built by `askVerdict` only, not arbitrary `Step s 'Verdict`. Not semantically neutral to flatten, since rule 10 gives associativity up deliberately for `at least n` |
| ii | `independentDraw :: Natural -> Step s c -> Step s c` applies to a panel | `independent draw` is a clause of `ask`, not of `panel` | Restrict the type, or a frontend refusal with its own diagnosis |
| iii | `AtLeast n` | not implemented (`acat-f10` open; "the panel menu ships entry one only") | Hard prerequisite of (c): ~2 days on the Lean side |
| iv | `revising` at a verdict carrier (§1.7) | writable in `.wf`; the draft's `'Text`-only type was the narrower one | Fixed by generalizing; no refusal needed |
| v | A continuation shared across both arms of an `ifFlag` — `ifFlag ok (k a) (k b)` — one Haskell term, two references | `.wf` has no way to share a continuation across arms | Emission duplicates it into both. See §3.3.1(iv): the blowup is 2ⁿ in nested branches and the frontend must refuse it with its own diagnosis |

That is **three** constructs requiring a frontend restriction or a new refusal
(i, ii, v), against a reopening condition that fires at three. The condition was
written about round 18's own normal forms rather than about a Haskell frontend, so
it does not literally fire — but the shape of the problem is the same, and the
honest reading is that (c) grows its own refusal battery for constructs the Lean
side will never see. That battery is priced in §3.3 and it is not in the draft's
13–16 days.

## 1.10 What the refusals become

Five fates. **The counts are an unverified estimate** (§0.3) and no claim is
derived from them; the row that matters is the fifth, which the draft did not
have.

| fate | which refusals |
|---|---|
| **evaporates** (the mistake is unwritable) | empty panel, `served by` off a tool, pending mishandling, arms exporting bindings, `answer` in a receipt body, statement-word collisions, define/binder namespace collision, most arity errors |
| **becomes a `TypeError`** in the surface's own words | flag/receipt in a hole, discarded non-receipt answer, non-verdict panel member, `ret`/`pure` recognized-mistake, `ApplicativeDo` on |
| **becomes an ordinary GHC error** in GHC's words, at GHC's position | kind mismatches, arity (including the *new* missing-`done` error), name not found outside a prompt, non-total verdict elimination (now an arity mismatch, moved here from "evaporates") |
| **stays a checker refusal**, position + one sentence + escape | budgets (`maxRevisions`, `maxQuestions`, including the construction-budget refusal of §1.8), quorum bounds, scope-escape, opaque templates, `promptFile` hole drift, backend/model pairing, the frontend's own generator-blowup refusal (§3.3.5), every runtime-shaped diagnosis |
| **becomes a silent meaning change** | **rule 6, no shadowing** — and it may be the only member |

### The fifth row, which is the one that should worry a reader

The draft filed rule 6 under "disappears because the concept does", where it reads
as a saving, and glossed it as "a warning in Haskell". **It is not downgraded to a
warning; it is unrecoverable, and the mistake it prevents is meaning-changing
rather than cosmetic.**

Under HOAS the author's names are erased at construction: `Ask … (\patch -> …)`
retains no name, so no `checkPlan` pass can restore rule 6 — there is nothing left
to compare. The quasi-quoter cannot catch it either, because it cannot enumerate
scope (§1.5 item 2). And `-Wname-shadowing` is in `-Wall`, not on by default, and
the library cannot impose it on a user's package.

Consequence: an author who rebinds `patch` inside a `settled` arm silently ships a
prompt that splices the *inner* `patch` — a different question, which checks,
prices and runs. That is the exact class the eighteen rounds of refusals exist
for, arriving as a wrong answer with no diagnosis anywhere.

**The mitigation, priced.** The only construction that recovers it is a named
binder:

```haskell
askText' :: Text -> Addr p -> Tmpl s -> Step s 'Text
```

`checkPlan` then compares names on every path from a binding and refuses a repeat
with rule 6's own sentence. This is worth more than it looks, because **it fixes
the `{v0}` readability problem of §3.3.4 at the same time** — the emitter uses the
author's names instead of minted levels. The two repairs are one repair. Its
price: one extra argument on every ask, an obligation authors will forget — and
forgetting it is itself silent, which is the same failure again — plus a scope
pass in `checkPlan` and the reserved-word table the emitter needs anyway. Call it
+1 day and a permanent ergonomic tax, and note what it does *not* buy: rule 6 then
holds for the questions you named, not by construction.

The construction that *would* restore it by construction is a whole-block
`[wf| … |]` TH quoter reading the do-block syntactically — at which point the
design has reimplemented `.wf` inside Haskell, and that conclusion belongs in the
recommendation rather than in a footnote. It is in §6.

### The rest of the damage

The middle rows are where G10 goes. A large share of the 201 diagnoses move from
"a position, one sentence, and the escape named" to GHC's phrasing at a desugared
position — and `coverage_audit.py` cannot police them, because they are not our
refusal sites. The battery and the audit port cleanly to the ones that stay ours,
and `Refusal` carries a real position via TH `Loc` in the QQ and `HasCallStack` on
every exported combinator. **But every diagnosis originating inside a prompt loses
column precision** (§1.5), so "a position" becomes "this prompt" for the whole
class of hole errors.

Rule 4's kind inference is **surrendered outright** (§1.6), not softened. That is
not worse than writing the type; it is not the same language.

## 1.11 The commonest mistakes, with the errors a non-expert sees

*(GHC 9.8-shaped. These are reconstructions, not captures — no such library
exists. Per the attack's own instruction, they should be checked against a stub
module before this page is used for a decision, because the draft's versions were
not producible by the code they accompanied.)*

### Mistake 1 — splicing a flag into a prompt

```haskell
ok <- askFlag (Person "owner") [prompt| Apply this patch? {patch} {flagSpec} |]
act (Tool "log") [prompt| owner said {ok} |]
```

The first bullet is ours, verbatim, with the escape named. **But the caret spans
the whole quasi-quote**, not the token — TH records no interior positions — so in
the `reviewers` panel's five-line fenced prompt with three holes the author is
told "somewhere in this prompt". Below it come eight lines showing the
quoter's expansion, which a non-expert has to learn to read past. agent-cat prints
four lines and a caret at the hole, and stops.

**Verdict: good on content, a real regression on position.**

### Mistake 2 — using an answer as a Haskell value

```haskell
draft <- askText (Model "author") [prompt| … |]
if Text.length draft > 4000 then … else …
```

```
Harden.hs:41:20: error: [GHC-83865]
    • Couldn't match expected type ‘Text’ with actual type ‘Var s0 'Text’
    • In the first argument of ‘Text.length’, namely ‘draft’
```

**Verdict: mixed, and this is the important one.** The diagnosis is correct and
short and points at the right token. But the escape is not named, and there is
**no way to name it**: you cannot attach a `TypeError` to a failed match against a
concrete type in someone else's function. The author is told they cannot do this;
they are not told that the reason is that a test on an answer is the dynamic rung,
or that the way out is to ask the question the test decides and eliminate the
flag. agent-cat's refusal here is rule 3 — *there is no expression language — no
test, comparison, arithmetic, or transformation* — and it says the escape. That
sentence is the eighteen rounds, and GHC will not say it.

Note also that this mistake **exists only because the surface is Haskell**. In
`.wf` it is unwritable. §5.2 returns to that.

### Mistake 3 — a bare question in statement position

The draft printed `ask (Model "author") …` here and claimed a good message. Under
the corrected design there is no polymorphic `ask`, so the program is:

```haskell
Wf.do
  askText (Model "author") [prompt| Summarise the patch. {patch} |]
  act (Tool "file")        [prompt| … |]
```

```
Harden.hs:33:3: error: [GHC-64725]
    • this question's answer is discarded.
      A statement-position question is an act; write `act (Model "author") …`,
      or bind the answer with `x <- …`.
    • In a stmt of a qualified 'do' block: askText (Model "author") …
```

**Verdict: equal to round 17's refusal, in slightly worse prose.** The draft
scored this "better than agent-cat, which infers `receipt` silently and carries
the caveat in prose" — comparing against superseded text. Round 17 already
replaced the silent-receipt reading with a positional rule plus a refusal
(`expr-design.md` §1.1, `Check.lean:566`):

> ``…`{f}` answers `text`, and its answer has nowhere to go: bind it,
> `x <- {f} …` ``

and it explicitly retired the "absence of an arrow marks discard, not
consequence" caveat: *"The elided binder is not a discard, and the difference is a
refusal."* Round 17 also already argues, from the same place, that agent-cat does
**not** import `-Wunused-do-bind` culture — a paragraph the draft presented as a
Haskell gain.

### Mistake 4 — the missing terminator

```haskell
ifFlag ok (Wf.do { act (Tool "apply") [prompt| … |] }) stop
```

```
Harden.hs:70:13: error: [GHC-83865]
    • Couldn't match type ‘Step s 'Receipt’ with ‘Plan s ()’
    • In the first argument of ‘ifFlag’ …
```

**Verdict: bad, and it is new.** GHC's words, at the closing brace, for the single
commonest omission the design creates (§1.6). agent-cat has no counterpart because
`.wf` needs no terminator.

**So of the four commonest mistakes: one good on content and weak on position, one
mixed and unfixable, one equal to round 17, and one new and bad.** The draft's
"three of four get a good message" does not survive.

---

# Part 2 — The static-analysis story

## 2.1 The ledger, with fidelity

| # | Guarantee | In Lean | In `Plan`-in-Haskell | Fidelity |
|---|---|---|---|---|
| G1 | every accepted program ≤ branch | `Dsl.parseAndCheck_level_le` (`Dsl.lean:599`) through fourteen lemmas | no `Dyn` constructor | **weaker than it looks.** `level` returns `.dynamic` only from `.dyn` (`Level.lean:120–125`), so in a `Dyn`-free datatype the property is trivial. The Lean theorem's *content* is that the **elaborator** never produces `dyn` — nontrivial, since `bindP` is derived through it (`Plan.lean:28–34`) — and there is no elaborator here, because the user builds the term. What is left is a datatype plus an unenforced convention about the client's imports (§2.2). The draft's "checked by GHC's exhaustiveness checker" is a non-sequitur and is deleted: exhaustiveness says nothing about which constructors exist |
| G2 | finite cost tree, min/max bills | `bill_mem_leaves`, `exists_min_bill` | `costTree`, total and finite **given** the lazy-stream budget of §1.8 | code survives whole; correctness becomes QuickCheck over random plans × random worlds |
| G3 | rung ladder | four theorems | **three and a vacuity** | `no_finite_bill_set_at_dyn` becomes *vacuous*, and a vacuous theorem is not a survival — its content is the reason the lattice has a top, i.e. the justification for refusing `dyn` at all. `shapes_eq_of_le_pipeline` is nearly tautological in this representation (the shape is in the node). `bill_exact_pipeline` is a real property test |
| G4 | plan/cost surfaces | theorem-backed exactness at ≤ pipeline | `Tmpl` is data | **split.** *Content*: better — probe rendering is exact and `{#3}` splice positions are printable, as `Explain.lean:113–114` prints them. *Warrant*: worse — theorem-backed exactness becomes a golden test. The draft's "equal or better" conflated the two, and the column is about warrant |
| G5 | sharing is the meaning | `Ω` is a function — a *type* | pure denotation keeps `World = forall c. SCode c -> Q c -> El c` | denotation: equal. Runner: a tested invariant. §1.7's two rules replace the draft's false one |
| G6 | trace agreement in named worlds | four `decide +kernel` proofs | golden tests | theorem → golden. Cheap, and honestly good enough for what it checks |
| G7 | soundness by construction | `Raw → Except CheckError (Plan [] Unit)` | — | **STRUCTURAL — lost, and this is the correction.** See below |
| G8 | axiom pinning, no `native_decide` | `#print axioms` empty | — | **lost entirely.** There is no kernel |
| G9 | one meaning, congruence free | `denote` is *the* fold | same discipline, enforceable by module structure | design property, not a theorem |
| G10 | refusal UX + coverage audit | 201 byte-pinned diagnoses, audit forbids untested sites | a share stays ours and keeps the battery | **the largest loss**, plus a new failure mode with no Lean counterpart (§1.10's fifth row) and a loss of column precision inside every prompt |
| G11 | per-run certification | `certify_sound`, no axioms | `certify :: Checked -> Log -> Bool` + property | code survives; the soundness statement becomes a property |

### G7 is structural, not portable

This is the clearest case in the draft of a structural guarantee sold as portable,
and it is the guarantee the owner's values name twice.

Lean's `Plan` is **intrinsically well-scoped and well-kinded**: `Plan : Ctx → Type
→ Type 1`, with

```lean
| ask {Γ : Ctx} {A : Type} (c : Code) (s : Q.Shape c) (e : Expr Γ String)
    (k : Plan (c :: Γ) A) : Plan Γ A                    -- Plan.lean:259–260
```

A prompt can only mention answers actually in scope, at their actual codes, and
the continuation is *typed* in the extended context. So `Raw → Except CheckError
(Plan [] Unit)` is a type-soundness statement: an accepted program **is** a
well-formed term, by type, and an ill-scoped one is not expressible.

The Haskell analogue has none of this. `Var s c = MkVar Int` is an unconstrained
level; `Plan s a` admits terms holding stale or sibling-branch levels; the design
concedes it by pushing scope checking into `checkPlan`. And the *direction* of the
signature is reversed: in Lean the **result** type carries the invariant, while
`checkPlan :: (forall s. Plan s ()) -> Either Refusal Checked` takes the plan as
its argument and returns an unindexed stamp. Gating `runPlan` on `Checked` (§1.2)
makes the refusals binding, which is necessary and was missing — but it does not
make the type express anything.

What would have to be true instead: `checkPlan` returns a value in a type that no
ill-scoped plan inhabits. That is the indexed representation `Plan (g :: [Code])
a` which §1.2 rejects for error-message reasons. **Rejecting it is what costs
G7**, and G7 belongs beside G8 in the "structurally dependent on Lean" column, not
in "survives in form".

## 2.2 Where analysis degrades from theorem to property test, precisely

Everything in `Cost.lean`, `Level.lean`, `Denote.lean` and `Certify.lean` survives
**as code, unchanged in shape** — first-order data and folds. What does not
survive is the quantifier. Five statements move:

1. `bill ∈ leaves(costTree p)` — theorem → property over generated plans and
   worlds. Generation is easy (the world is total; every answer type is
   inhabited), so a few hundred lines of QuickCheck gives high confidence. It is
   not `bill_mem_leaves`.

2. `denote` adequacy against the IO runner — from `Plan.adequacy` (stated at `Id`,
   with the `IO` side already a trust boundary in Lean) to a differential test
   between a pure runner and a mock oracle. This loss is smaller than it looks.

3. `level p ≤ branch` — theorem about every accepted *program* → fact about a
   datatype. The residual risk is `unsafeCoerce`, an orphan instance, or a future
   maintainer adding a constructor.

   **The draft's mitigation was inverted and is replaced.** `{-# LANGUAGE Safe #-}`
   constrains *the module it is written on* — it forbids that module from using
   `unsafeCoerce`, orphan instances and TH, and forbids it from importing non-Safe
   modules. It says nothing about clients. A user's workflow module, compiled
   ordinarily, may `import Unsafe.Coerce` and manufacture a `Var s 'Flag` from a
   `Var s 'Text` regardless of what the library declares. Worse, the direction
   that *would* work — compiling every workflow module `-XSafe` — is unavailable,
   because a workflow module needs TH for `[prompt| … |]` and TemplateHaskell is
   on Safe Haskell's forbidden list.

   The real mitigations: (a) `type role Var nominal nominal`, so `coerce` is
   blocked even where a newtype constructor leaks; (b) a single exhaustive `case`
   over every `Plan`/`Tmpl` constructor in the test suite, so adding a constructor
   breaks the build — this one the draft already had, and it is the one that
   works; (c) a CI lint grepping workflow packages for
   `unsafeCoerce`/`Agentic.Plan.Unsafe`. Restated honestly: `level p ≤ branch` is
   a property of a datatype **plus an unenforced convention about the client's
   imports**.

4. **`renderAt`'s totality** — the fifth item, and the one that was an `rfl` in
   Lean. Per §1.2, the level-to-binder correspondence is a traversal invariant
   rather than a type, so `renderAt` returns `Either InternalError Text` and needs
   a property that no plan built through the exported API reaches the error
   branch.

5. The `parseAndCheckRaw_eq` item is **deleted**, because the draft misquoted the
   theorem and used the misquote in both directions. Verbatim, at
   `Agentic/Core/Explain.lean:336–338`:

   ```lean
   theorem parseAndCheckRaw_eq (s : String) :
       (parseAndCheckRaw s).map Prod.snd = parseAndCheckE s :=
     parseAndCheckRawProgramWith_eq [] [] s
   ```

   It says the raw-returning front end agrees with the plan-returning one, **at
   `[] []` only** — no `--define` overrides, no imports. The general form is
   `parseAndCheckRawProgramWith_eq` (`:301`). It is *not* "the CLI, MCP
   `workflow_check` and the battery accept and refuse the same texts with the same
   messages"; what it does is reconcile two front ends that different callers use
   (the CLI calls `parseAndCheckRawProgramWith` at `cli/AgentCat.lean:320`, MCP
   calls `parseAndCheckE` at `Mcp.lean:1142`). The draft's claim that Haskell
   degrades this to "one function and three callers, verified by reading"
   manufactures a Lean advantage that does not exist: one function with several
   callers is already the Lean situation. The honest residual is that a pure
   Haskell side loses the *proof* that its raw and plan front ends agree — which
   under (c) it keeps, because there is only one front end.

## 2.3 Probe soundness when users hold real Haskell functions

The answer is **it is only sound if you do not let them**.

If `Tmpl` is first-order and its constructors are budgeted (§1.4), the probe
rendering *is* the template, and what `plan` prints stands in exactly the relation
to the run that `Explain.planLines` at `Env.probe` does in Lean: the words that
are not answers are the words that will be sent, and the words that are answers
are shown as the names of their own binders.

If you admit `Opaque :: (ProbeEnv -> Text) -> Tmpl s`, then for that node `plan`
prints a fiction, `cost` cannot bound tokens, and the batch/pipeline distinction
is unknowable. agent-functor's `plan` printing `prompt reviewer` rather than the
brief is precisely this failure, arrived at by default rather than by choice.
Hence: `Opaque` exists, in `Agentic.Plan.Unsafe`, is structurally detectable,
downgrades the node's rung in every report, and is refused by `checkPlan` without
`allowOpaque`. **A user holding real Haskell functions is fine at construction
time and forbidden inside a prompt.** That line is the whole of the analysis
story, and it is the line agent-functor did not draw.

The same line applies to elimination: `IfFlag`/`OnVerd` scrutinise a variable, so
arms are always in the term and `costTree` is always finite. There is no
`Case :: (Env -> t) -> (t -> Plan)` node.

---

# Part 3 — The four options, priced

## 3.0 The shared floor, stated once so it is not double-counted

Two pieces of work are needed under **every** option and are therefore charged to
none of them in the table below:

* **The content-addressed leaf store with fork/resume as one code path.** This is
  `Ω`-is-a-function made durable, the strongest single idea in agent-functor, and
  it is the difference between a language and a tool.
* **Typed backend/model pairing with preflight** — mispairing as a type error,
  all errors collected before any spend, and model-catalogue abstinence on
  evidence (`"gpt-5"` is a substring of all twenty advertised codex models). Lean's
  dependent types make agent-functor's phantom `BackendTag`/`AcceptsModel` trick
  *easier* than it is in Haskell.

**~5–6 days, orthogonal to this decision.** The draft charged this work inside
(b)'s headline number and to nobody in the two options it was recommending
between — a 5–6 day asymmetry in the recommendation's favour. It is stated here
once. Option (b) additionally needs a CLI and an MCP server, which (a)/(c)/(d)
already have; that is inside (b)'s own number below, itemized.

## 3.1 Option (a) — the round-18 campaign as designed

**Price: 10–11 focused days.** Line items from `calculus-design.md` §10.6:
`Norm.lean` 4 days; `Parse.lean` (the expression parser, `parseType`,
`parseLambda`, the `let` header, `PEnv.fnSigs`/`PEnv.lets`, six lexer changes
including the dedicated `.` branch, `fenceCloses` widening, parse-time binder
minting) 3½ days; `Check.lean` 2 hours; battery ~151 new cases 3 days; examples
and docs 1 day; credit −1½ days for round 17's bang, never written.

**Estimation method: line-item over existing code, battery-censused (−18/+151
against today's 201, ~26 edited), adversarially attacked (60 findings, three
fatal), with a recorded re-elaboration risk of near zero and a pre-agreed cut
lever.** It is the only number on this page that has been through that.

**It includes round 17's do-core.** The `obr` checklist for the campaign bundles
it explicitly: `answer` deleted cold, last-statement-is-result, receipt bodies do
not lift, trailing-bind refusals with primings exempt, default-text parameters.
`Parse.lean:523/912/1036` confirm none of it has shipped.

**What it buys.** Application, `.` (infixr 9), `$` (infixr 0), `>>>`/`<<<`
(infixr 1, Kleisli), `>>=` (infixl 1), `=<<` (infixr 1), lambdas at every
expression position, static partial application, higher-order `let`s — at
Haskell's own fixities under ruling 9. Nine of the twelve statements in the
showcase are unchanged, and the page says plainly that round 18 *"does not make
the surface shorter than it was"*.

**Cut lever, recorded in advance:** refuse an arrow in a `let`'s parameter
annotation, and the whole higher-order path disappears in one line, invalidating
no other decision.

## 3.2 Option (b) — the pure Haskell library

**What you build.** Core types and `Plan` (~1,200 lines); the quasi-quoter (~700,
and TH is fiddly — the `Splice` class, `Loc` capture, indentation, the
`promptFile` hash protocol); `checkPlan` with its position-carrying refusal sites
(~900); `level`/`costTree`/`explain` folds (~700); `denote`/`trace`/`certify`
(~600); ~80 properties (~800); the refusal battery plus the coverage audit
(~1,300); **a runner — ACP client, content-addressed store, fork/resume,
preflight (~2,500); CLI and MCP server (~900)**.

**Price, split so the row compares like with like:**

* **Language: ~25 days.**
* **Runner, CLI and MCP that (a)/(c)/(d) already have or get from the shared
  floor: ~8–10 days.**
* **Total ~33–37 days greenfield.**

**Estimation method: a LoC guess — nine components summing to ~9,600 lines —
divided by an unstated productivity rate of roughly 270 lines/day, greenfield, no
case census, no adversarial pass.** Estimates of that construction, for a system
whose hardest component is Template Haskell, read 1.5–2× in practice. **The honest
band is 35–60 days all-in**, and the language half alone is 25–40.

Adopting agent-functor's runtime instead cuts it to ~25 days plus a dependency on
someone else's unfinished 28k lines: thirteen documented holes, four of them
operational — MCP runs write no run record and are therefore **unresumable**,
`Sample` drops are unaudited, `canonicalizePath` is lexical so a symlink escapes a
grant, and two live acceptance runs were never done.

**Plus the write-off: 26,155 lines of Lean under `Agentic/`, 29,663 with `cli`,
`mcp` and `test`, and 867 theorem/lemma declarations** (§0.3). Not the ~16k the
draft claimed.

**What it buys.** Real confidence in the folds. QuickCheck over generated plans
and worlds is a strong regime here — the world is total, every answer type is
inhabited, the properties shrink. Golden tests over `plan`/`cost` pin the surfaces
byte-for-byte, which is agent-functor's best-demonstrated discipline.

**What it does not buy.** Nothing about `denote` is proved. G8 is gone. G7 is gone
structurally (§2.1). And the thing the owner's values put first is reduced to a
sentence that is no longer true of the signature.

### The Liquid Haskell sub-option, reduced to what it can carry

The draft priced Liquid Haskell on the evaluator core at +5–8 days and claimed it
would carry "totality of every fold, `costTree` finiteness, budget arithmetic".
**The totality claim contradicts Part 1's representation.** LH proves totality by a
structural or user-supplied metric on the arguments, and HOAS has none:
`costTree (Ask _ _ _ k) = … costTree (k (MkVar d))` is a function application, not
a subterm, and §1.8 establishes that it is genuinely not smaller. LH can prove
totality of *no* fold over `Plan`. Two further blockers: LH's GADT support is
marginal and `Plan`/`Tmpl`/`SCode` are GADTs with a phantom brand and an
existential; and `Data.Text` has no refined specification to reason against.

What is left is real but small: refined integer bounds in the budget and quorum
arithmetic (`atMost`, `maxQuestions`, `maxRevisions`, quorum), and no-partial-
function obligations in `checkPlan`'s pure fragment. **Reprice at +2–3 days**, and
describe it as a bounds checker rather than as verification. The disqualifying
fact for the flagship stands independently: refinement equality translates to
builtin SMT operators and cannot be customised via `Eq` instances, and agent-cat's
central object is site-keyed extensional equality whose kernel *is* workflow
equality.

## 3.3 Option (c) — the hybrid: Haskell surface, `.wf` as IR, Lean keeps everything

**The elaboration boundary.** The Haskell frontend emits `.wf` **source text**,
not a serialized `RawProgram`, for three reasons: it goes through the existing
single front end, so no new trusted decoder and no bypassed parse-level refusals;
the output is inspectable; and there is no second serializer to keep in sync.

**Why the emission looks easy.** A `Plan` built with `Wf.do` is already in A-normal
form. The pretty-printer walks the term, mints binder names, prints each `Tmpl` as
a fenced block with `{name}` holes, and emits the shape words.

**Why it is not.** Five things the draft's "a few hundred lines and it has no
analysis in it" does not carry.

### 3.3.1 The pretty-printer carries at least four analyses

1. **Name minting must respect the round-16 rule.** GRAMMAR.md: *"a binder,
   parameter, or function name may not spell a statement word, a function, or an
   imported module's name"*. So the printer needs the reserved-word and define
   tables — a shared table across two languages, which is exactly the drift the
   maintenance row names and the line item does not carry. `Parse.lean:522`'s
   `stmtWords` is the source of truth, and it moves whenever the surface moves.

2. **Brace escaping in `Lit` chunks — the near-certain fidelity bug.** In `.wf`,
   inside a fenced block "everything else is literal" but `{name}` **is a hole**
   and `\{`/`\}` are the escapes (GRAMMAR.md, round thirteen). A Haskell `Text`
   CAF spliced as a `Lit` routinely contains braces: a JSON example, a code
   fragment, a format string. If the emitter does not escape them,
   `{"role": "user"}` becomes a hole named `"role": "user"` and the Lean checker
   refuses at a position inside a generated prompt with a name the author never
   wrote. **That is the lucky case.** The unlucky case is a literal `{patch}`
   inside an example block, which resolves against a live binder, checks cleanly,
   prices cleanly, and asks a different question. Nothing on the Lean side can
   know — (c)'s stated blind spot, instantiated on the first real workflow.

   **The rule: the emitter escapes `{` and `}` in every `Lit` chunk as `\{`/`\}`
   and emits `Hole`s alone unescaped.** Its test is the round-trip property of
   §3.3.2. Fence-width selection is the same class of bug and the same one line:
   choose a backtick run longer than any run in the content.

3. **Kind annotation policy.** The Haskell side knows every kind exactly; `.wf`
   infers by first-ground-use, and round 11's landed delta refuses some
   annotations (a *bound* ask may still be annotated `: receipt`, binding a name
   nothing can consume — "a refusal to add"). So the printer must decide where to
   annotate and where annotating changes a diagnosis.

4. **Branch-shared continuation blowup.** `ifFlag ok (k a) (k b)` is one Haskell
   term with two references; `.wf` has no way to share a continuation across arms,
   so emission duplicates it into both. Nested, that is 2ⁿ. A program the author
   reads as small blows `maxQuestions = 4096` (`Check.lean:857`), and the refusal
   is about generated text. **The frontend must refuse this itself, with its own
   diagnosis and the Haskell position** — see §3.3.5.

**Reprice: 4 days, not 2.**

### 3.3.2 The fidelity limit, and what actually tests it

The Lean checker catches every *well-formedness* bug: ill-kinded, over-budget,
non-totally-eliminated, above the branch rung, shadowing, a hole naming nothing.
The frontend therefore cannot make the runner unsound.

It catches **no fidelity bug**. A frontend emitting a well-typed program that is
not the program the author wrote — a mis-ordered panel, a hole bound to the wrong
`Var`, a lost draw index — produces a perfectly checked, perfectly priced, wrong
workflow.

**The draft's mitigation cannot detect the failure it was offered against, and the
code says so.** It proposed comparing the Haskell side's `shapes` and `asks` folds
against the Lean side's. But:

* `Cost.shapes` (`Cost.lean:321–326`) carries `⟨c, s⟩` — code and shape — and **no
  prompt text at all**.
* `Cost.asks` (`:336–341`) renders the prompt as `s.withPrompt (e γ)` where γ is
  built by `.cons default γ` at every binder: **every in-scope answer is
  `default`**. A hole mis-bound to a different `Var` *of the same kind* renders to
  the identical string.

So the instrument is blind to exactly the bug class it was introduced to cover.
The draft then named a *different* instrument — "a test asserts `agent-cat plan
--json` agrees" — which is neither fold, does not exist, and was deliberately
refused (`cli/AgentCat.lean:63–66`: *"**There is no `--json`.** … adding a second
one here would be a second encoder to keep true."*).

**The replacement, which can fail:**

1. **Golden `.wf` pins per worked example.** The emitted text itself is the
   artifact under test, byte for byte. This is the only thing that catches a
   brace-escaping bug.
2. **Probe-env discrimination.** The differential must compare renderings under an
   environment giving each binder a *distinct* witness — its minted name — not
   `default`. That requires a Haskell-side equivalent of `Explain.planLines`,
   which prints `{#d}` splice positions (`Explain.lean:113–114`). **That is a
   second implementation of the explainer, not "two small folds".**
3. **A round-trip property**: parse the emitted `.wf`, re-render every prompt at
   `Env.probe`, assert byte equality against the Haskell `renderAt probeEnv`.
4. And it re-opens the CLI's no-second-encoder decision, because the comparison
   needs a machine-readable rendering that the CLI refuses on stated grounds.

**Reprice: 5–7 days, not 3.**

### 3.3.3 Source maps are blocked, and they break reason #1

The draft priced `-- @src Harden.hs:41:7` comments plus `agent-cat --source-map`
at 1½ days and claimed they "buy back most of G10". Three problems.

**They break the property offered as reason #1 for emitting text.** Reason #1 is
that going through `Dsl.parseAndCheckRaw` keeps `parseAndCheckRaw_eq` true. A flag
that rewrites a diagnosis' position before printing it is precisely a CLI that no
longer prints what the battery and `workflow_check` print for the same text.
Either scope the theorem's gloss to `--no-source-map`, or drop reason #1.

**The mechanism does not exist to build on.** `obr show
acat-pos-module-attribution-oxq` is OPEN: `Dsl.Pos` carries only line and column
with **no module field**, the CLI's `caretLines` already slices the wrong file for
a library diagnosis, and the prescribed fix requires a `Pos.at` helper across ~25
anonymous constructors in `Parse.lean` **and** that "flagshipRaw/battery position
pins recompute". That last clause **destroys the re-elaboration-risk-near-zero
property** that (c) inherits from (a) — the ~107 s `DslFlagship` module and its
nine `decide +kernel` proofs come back. A cross-*file* remap is strictly harder
than the cross-module one already blocked.

**And it cannot map what TH never recorded** (§1.5): a refusal at a hole maps to a
whole quasi-quote at best.

**Reprice: 3½–4½ days, with `acat-pos-module-attribution-oxq` as a prerequisite,
and the near-zero re-elaboration risk withdrawn.**

**"The Lean side is unchanged" is false three times over.** (c) requires
`--source-map`, the machine-readable rendering the differential test needs, and
`acat-f10`. Those are Lean-side changes and their days are in the total.

### 3.3.4 Emitted binder names are `{v0}`, not `{patch}`

HOAS erases the author's names. `Ask … (\patch -> …)` retains only a level, so the
printer mints `v0`, `v1`, `v2`, and every prompt in the emitted flagship reads
`{v3}` where the author wrote `{patch}`.

**Reason #2 for emitting text — readability — is therefore demoted to
traceability**, and it is demoted in exactly the place the dissent attacks. The
source map does not recover it: `-- @src Harden.hs:41:7` gives a line, not a name.

Two honest responses, and the page takes the first while pricing the second:

* **(a) Accept it.** Rewrite reason #2 as *traceable, not readable*, and concede
  §5.1's readability point in the recommendation rather than in an appendix.
* **(b) Take the naming obligation.** `askText' "patch" …` per §1.10 — which is
  the same +1 day that recovers rule 6, because it is the same repair. It is the
  only version of (c) in which the emitted text is a document a human approves,
  and authors will forget it silently.

### 3.3.5 The frontend must refuse the `maxQuestions` class first

The advertised macro layer collides with `maxQuestions = 4096` in a way the source
map cannot help with. A `foldr` over `[1..n]` generating a cadence inlines to
thousands of `.wf` statements, each with its own fenced prompt. When the count
exceeds the bound, the Lean checker refuses at *one* emitted line — line 12,349 —
and the source map rewrites it to the single `foldr` that generated all of them.
The author is told one question is one too many, at a position that produced four
thousand.

**The frontend already walks the term for the differential test; it must refuse
first**, in Haskell, with the Haskell position of the generating expression and the
count:

> this expression generates 4,097 questions; the program bound is 4,096.

That refusal stays ours, and it instantiates a general rule worth stating:
**whenever a Lean-side bound can be exceeded by a Haskell-side generator, the
frontend must own the refusal, because only it knows what generated what.** The
same rule covers §3.3.1(iv)'s branch-shared blowup and §1.9's unspellable
constructs. Together they are the frontend's own refusal battery: **1–2 days**.

### 3.3.6 The `.wf` interface needs a version handshake

The `.wf` text is an unversioned interface between two independently released
programs, and the draft treated it as having no interface risk ("No new format, no
versioning problem, no second serializer"). True of the *bytes*, false of the
*grammar*: the frontend hard-codes a spelling of `revising … at most n
amendments`, of `panel, all must approve [`, of fence rules, of `served by`. Every
future `.wf` change — round 18's operators, a fifth kind, a third panel entry,
lifting the round-11 deltas — desynchronises them, and the failure mode is a parse
refusal at a generated line for a user who changed nothing.

**The mechanism:** emit `-- @wf-version N` as the first line; `agent-cat` refuses
an unknown version by name ("this program was generated for surface version 4;
this build speaks 3"); the frontend embeds the SHA of the grammar it targets and a
CI job builds both trees and fails on divergence. **½ day, plus a standing cost —
one job, one refusal site, and a coordinated release whenever the surface moves.**

### 3.3.7 The price of (c), re-derived

| Item | Draft | Corrected | Why |
|---|---|---|---|
| Builder types, `Var`/`Tmpl` | 3 | 3 | now with `Wf`, the `SCode` witness, strict `Tmpl`, role annotations |
| The quasi-quoter | 4 | 4 | the `Splice` repair removes the reify problem and adds a class |
| Pretty-printer and binder minting | 2 | **4** | four analyses, §3.3.1 |
| Source maps and the CLI flag | 1½ | **3½–4½** | blocked on `acat-pos-module-attribution-oxq`, incl. flagship pin recomputation, §3.3.3 |
| Differential testing and the battery | 3 | **5–7** | golden pins + probe discrimination + a second explainer + a machine rendering the CLI refuses, §3.3.2 |
| The frontend's own refusal battery | — | **1–2** | §1.9, §3.3.1(iv), §3.3.5 |
| Version handshake, grammar hash, CI | — | **½** | §3.3.6 |
| `acat-f10` (`at least n must approve` + three theorems) | — | **2** | `AtLeast` is in the Part 1 API and is unimplemented |
| Docs and the worked pair | 1½ | 1½ | |
| **Subtotal** | **13–16** | **24½–29½** | |
| Plus the do-core (c) must also fund | 0 | **2** | `.wf` "at its landed round-17 form" does not exist |
| **Total** | | **~26–32** | |
| Optional: the naming obligation (§1.10 / §3.3.4) | — | +1 | recovers rule 6 *and* readable emitted names |

**And round 18 does not return 10–11 days.** Shelving the calculus returns
`Norm.lean` (4) + the expression-parser share of `Parse.lean` (~2½ of 3½) + the
calculus battery share (~2 of 3) ≈ **8–9 days**, and *retains* the ~2-day do-core
obligation. Also: §5.5's battery entries do not "come back"; under (c) they are
**re-decided**, because Haskell inverts line 2 (§1.7).

**Estimation method: a task list, extended by the adversarial pass, with no case
census and no second attack.** It should be read as softer than (a)'s number even
after this correction.

## 3.4 Option (d) — ship the do-core, descope the calculus

**What ships.** Round 17's do-notation reading, made official: blocks are do-blocks
over `Plan`; the last statement of a function body is its answer and the `answer`
keyword is **deleted cold**, with no migration clause, because no agent-cat
scripts exist in the wild and `answer` leaving `stmtWords` is the purer "no
reserved words" outcome. Parameter annotations default to `text`. Trailing
bindings are refused in blocks, arms and bodies (not in a library's priming). Any
Unit-valued statement may end a block, assertions included — the requirement is the
type, not a closing word. The fence-close drift is fixed.

**What never ships.** Lambdas, `.`, `$`, `>>>`, `<<<`, `>>=`, `=<<`, partial
application, higher-order `let`s, `Norm.lean`, and the whole expression grammar.
The surface stays at round 16's abstraction level — `function` and `import`,
arity-directed calls, no expression language over answers — with round 17's
noise removed. §5.5's substitution-sharing question never arises, because there is
no substitution.

**Price: ~2 days (1½–2½).**

**Estimation method: subtraction from `expr-design.md` §8.9's three-day total,
using round 18's own line items.** Round 18 books a **−1½ day credit** for "round
17's bang, never written", and that credit is exactly §8.9's `Parse.lean` line
item; what remains of that line is D15/D17/D18 refusals, D16, D19 and D20 —
roughly half a day. §8.9's battery day covers ~42 cases; §10.6 records that
**−18** of them are bang cases never written and **~30** survive, so call it half
to one day. `Check.lean`'s two clauses plus the seven `isTemp`/`showName` sites
shrink, because temporaries are minted only by the bang. Examples and docs, half a
day.

**This estimate has not been separately attacked, but it is a strict subset of a
line item that has been** — which is the strongest form of estimate short of an
attack, and stronger than anything (b) or (c) has.

**What it buys.** One surface. All eleven guarantees over the text a human
approved. `workflow_check(source)` on one self-contained program, unchanged. The
201-case battery and `coverage_audit.py` unchanged in kind. No source map, no
second builder, no differential test, no version handshake, no second error
surface. And it frees the ~8–9 days the calculus would have consumed for the
runner work §3.0 says must happen regardless.

**What it costs.** The macro layer — whose value the draft never demonstrated with
a single workflow, and which §4.2 now attempts to demonstrate. And it leaves round
18's own question live and unanswered: **is the `.wf` surface good enough for real
programs?** (d) does not answer that question; it defers it until there are real
programs to read.

---

# Part 4 — The comparison

## 4.1 The table

*Shared floor of ~5–6 days (§3.0) is excluded from every cell. Read the "Cost from
here" row with its methods, not as four commensurable numbers.*

| Dimension | (a) Round 18 as designed | (b) Pure Haskell library | (c) Hybrid | (d) Do-core, calculus descoped |
|---|---|---|---|---|
| **Guarantees kept** | All eleven. G1 quantified over every accepted program; 867 theorem/lemma declarations; empty axiom sets | G1 by datatype (and see §2.1 — the Lean theorem's content does not transfer), G2/G3/G6/G9/G11 as property + golden, **G7 lost structurally**, G8 lost, G10 heavily reduced | **All eleven, of the emitted IR. Zero of them quantify over the Haskell source.** The author-to-IR step is covered by golden and differential tests only. For a Haskell-authored workflow the guarantee is (theorem ∘ untheorized frontend) | All eleven, of the text the author wrote. Identical to today plus round 17 |
| **Auditability of the approved artifact** | **The text you read *is* the term the theorems are about.** `flagshipSource := include_str "example/harden.wf"` plus `render_eq_harden_render` say so. Rule 5's closedness is decided by "the preamble at the top of the file" — a statement about a human reading a file | **There is no text.** A program is a Haskell value; auditing it means reading Haskell and trusting the folds | **The text you read is generated.** Reviewing a workflow means reviewing a generator. Closedness (rule 5) becomes a property of a built value, not of a page (§1.4). Binders read `{v0}` unless the naming obligation is taken (§3.3.4). `harden.wf` becomes a golden file protecting a generator rather than a design | Same as (a) |
| **Who can author** | Owner, any reader of a page, and an agent over MCP | Owner and Haskell programmers. An agent must emit Haskell or a serialized format | Owner in Haskell; readers and agents still in `.wf`, which therefore stays first-class — so round 18's question stays live | Owner, any reader, an agent |
| **Errors for a non-expert** | Best by a distance: position, one sentence, escape; 201 cases pinned byte-for-byte; a coverage audit that fails the build on an untested refusal site | Mixed, and worse than the draft claimed: of the four commonest mistakes, one good-on-content but caret-wide, one mixed and unfixable, one equal to round 17, one **new and bad** (the missing terminator). Every in-prompt diagnosis loses column precision. GHC owns a large share in GHC's words | (b)'s Haskell errors *plus* Lean's refusals mapped back — where the map exists (§3.3.3). A mistake is diagnosed by whichever layer sees it first and the author learns two voices | Same as (a) |
| **Silent meaning change** | None. Rule 6 refuses shadowing | **Shadowing is unrecoverable** (§1.10): the inner `patch` is spliced, and it checks, prices and runs. Mitigation is `askText' "patch"`, +1 day, and forgetting it is itself silent | Same as (b), and it survives into the emitted text | None |
| **Cost from here** | **10–11 days.** *Method: line-item over existing code, battery-censused, adversarially attacked, cut lever pre-agreed* | **~25 language + ~8–10 runner/CLI/MCP = 33–37 nominal; 35–60 risk-adjusted.** *Method: LoC guess at ~270 lines/day, greenfield, no census, no attack.* Plus writing off 26,155 lines of Lean | **~26–32.** *Method: task list extended by one attack, no case census, no second attack.* Includes the ~2-day do-core, ~5½–6½ days of Lean-side prerequisites, and the frontend's own refusal battery. Shelving the calculus returns only ~8–9 | **~2 days.** *Method: subtraction from an attacked line item, using round 18's own −1½ credit and −18 battery cases* |
| **Maintenance** | ~107 s and several GB per `DslFlagship` elaboration; never two Lean builds at once (two concurrent runs exhausted 48 GB); ~350 pinned assertions; the `include_str` hazard; six smoke binaries run serially | GHC builds in seconds; HLS works. But every guarantee is a test you must keep green, and property tests rot quietly in a way theorems do not | **Both build systems**, plus: two error surfaces, a source map that will drift, the reserved-word table shared across two languages, the `-- @wf-version` handshake and its CI job, and a coordinated release whenever the surface moves | (a)'s bill, minus `Norm.lean` and the expression parser — the two files where every genuinely novel algorithm would have lived |
| **MCP / self-contained program** | Best. `workflow_check(source)` takes one text; `importRefusal` fires before parsing; an agent can *author* a workflow, which is the tool's stated purpose | **Worse, not fatal.** The draft's three bad answers omit the obvious fourth: a serialized first-order program format checked by `checkPlan` — which is what `Raw` already is on the Lean side. ~2–3 days for a format, a decoder and its refusals. The residual is real and narrower: the agent-facing surface stops being prose, and "an agent can be driven by a workflow instead of being trusted to remember one" survives only if an LLM can write that format | Unchanged from (a) — `.wf` in, agents author `.wf`. **This is (c)'s strongest argument**, and it cuts both ways: it means `.wf` must stay first-class, which means round 18's question is still live | Unchanged from (a) |
| **Abstraction available to the author** | Lambdas, composition, partial application, higher-order `let`s — but no recursion, no data, no lists, no iteration | Everything Haskell has at construction time, including **static iteration over data** (§4.2) | Same as (b) | Round 16's functions and imports only. No iteration, and no calculus |
| **Batch rung across an abstraction boundary** | Still lost. `fn-import-attack.md` A3: a question reached through a call can never be closed, because a parameter is always an `Expr` | **Recovered** — a `Text`-typed argument splices as a `Lit`, so `askC` survives the boundary (§1.4). A genuine win, at the cost of restating rule 5 as a property of a type signature | Same as (b) | Still lost |
| **Multi-vendor backends** | Two adapters today. Lean's dependent types make the phantom-tag trick *easier* than in Haskell | Best today via agent-functor: four backends, live-verified against three simultaneously, mispairing a type error, preflight before any spend | (a)'s position plus the freedom to port deliberately | Same as (a) |
| **Risk** | The language finishes before the tool is useful. Eighteen rounds of surface against two adapters and no fork/resume is real exposure. Plus the recorded reopening condition | Losing the thing that makes this project *this* project. G7 demotes from a type-soundness theorem; G1's real content does not transfer; the refusal battery becomes a test of a code generator | Drift, and the possibility that nobody writes the Haskell frontend because `.wf` is already good enough. Plus: a generated `.wf` breaks the identity between the text a human approved and the term the theorems are about — the largest single write-off | **The abstraction ceiling is reached and the surface cannot grow.** If a real workflow needs iteration, (d) has no answer inside `.wf` at all |

## 4.2 The capability delta: static iteration over data

*Every appeal to the owner's Haskell fluency is cut from this page. Fluency is a
reason a thing will be pleasant, not a reason it is right, and it is the argument
that will look weakest in six months. What (b)/(c) can do and `.wf` cannot must
carry the case on its own.*

There is exactly one such capability, and the draft buried it in a parenthesis:
**static iteration over data.** `.wf` has no lists, no recursion (round 18 §11:
*"It does not add recursion"*), and `kind ::= text | verdict | flag | receipt`
with `Ctx` a `List Code` and no code for anything else. So a workflow whose *shape*
depends on a collection known at construction time is unwritable in round 17 and
in round 18 alike, at any price.

Three workflows that need it. **These are candidates constructed from the
capability, not workflows the owner has named** — and that is the test. If the
owner wants none of them, the capability argument for (b)/(c) is empty and the
decision reduces to cost, where (d) wins outright.

**W1 — review every changed file.** `git diff --name-only` yields *n* paths; ask
one reviewer question per path, then a judge over the joined verdicts.
*The `.wf` spelling that fails:* `statement` has no iteration form and no list
kind, so the only spelling is *n* hand-written statements — and *n* is not known
when the file is written. *Emitted:* twelve files → twelve asks with fenced
prompts, ≈ 110–140 lines of `.wf` from ~12 lines of Haskell.

**W2 — a rubric-driven audit.** One closed question per item of a house-style
rubric held as a Haskell list. Each question is closed — no hole names a binder —
so the whole fan sits at the **batch** rung and `asks_eq_of_le_batch` gives the
exact question list before the run.
*The `.wf` spelling that fails:* the rubric would be *n* `define`s and *n* asks,
so adding a rule is an edit in two places; and per A3, factoring the ask into a
`function` drops the questions off the batch rung entirely. *Emitted:* twelve
rubric items → twelve `askC` statements, ≈ 100 lines.

**W3 — a reviewer roster from a table.** A panel whose members come from a
`[(model, servedBy, angle)]` list, so adding a reviewer is a list entry and the
same roster drives three workflows.
*The `.wf` spelling that fails:* `source ::= "panel" "," rule "[" ask { "," ask }
"]"` — the member list is literal syntax, so a panel's arity is fixed where it is
written, and round 16's functions cannot vary it because a body is fixed at
declaration. *Emitted:* five reviewers × three workflows = fifteen asks; the
roster is one five-line Haskell list.

Note what these three have in common and what they do **not** need. They need a
loop that runs at construction time and emits statements. They do not need a
GADT, a phantom brand, `Renderable`, `Discardable`, or a typed addressee. §5.2 is
where that observation becomes the decision.

---

# Part 5 — The two arguments that decide it

## 5.1 Auditability: the smallness is the product

*This is the strongest argument against (b) and (c), and it is close to decisive.*

Eighteen rounds did not buy expressiveness. They bought **refusals**: no reserved
words, no expression language over answers, one binding shape, two consumption
sites and no third, no shadowing, elimination total, arms export no bindings, a
closed two-entry panel menu, no polymorphism, no recursion, no data types beyond
four kinds. The value of that list is not that the resulting programs are
checkable — plenty of things are checkable. It is that **you can read the page and
know what happens**, and that a question's identity is decided by reading rather
than by evaluating.

A Haskell frontend has all of Haskell at construction time. That is sold as the
feature; it is also the loss. A `.wf` file emitted by four hundred lines of
Haskell with type classes, a `Map` of reviewers and a `foldr` over `[1..n]` is
checked, priced, refused-or-accepted, and **unreadable as intent**. The theorem
still holds over it. The reason the owner wanted the theorem does not.

Three supporting points, each now grounded rather than asserted:

* **Rule 5 is a statement about a human reading a file.** *"A question is closed —
  batch rung — exactly when every hole it wrote named a define, which the preamble
  at the top of the file decides."* Under a Haskell frontend, deciding which
  questions are closed requires running the generator (§1.4). The draft asserted
  the opposite one section before this argument could be made.

* **The emitted binders read `{v0}`** (§3.3.4). So even the traceability that
  survives readability is degraded, unless the naming obligation is taken — and
  taking it is the same +1 day that recovers rule 6, and forgetting it is silent.

* **The MCP purpose is the tell.** *"An agent can be driven by a workflow instead
  of being trusted to remember one"* requires the workflow to be one text an agent
  can read *and write*. `.wf` was designed for that reader. So the `.wf` surface
  must stay first-class under (c) — which means round 18's question, *is the `.wf`
  surface good enough for real programs?*, is **still live and still unanswered**.
  The draft shelved the campaign without saying what now answers it. (d) at least
  answers it honestly: it defers the question until there are real programs to
  read.

* **Two surfaces is multiplicative, not additive.** Every future feature — a new
  panel rule, a fifth kind, a change to `revising` — must land in the Lean
  checker, the `.wf` parser, the Haskell builder, the pretty-printer, the source
  map, the version handshake and two batteries. §3.3.7 prices building the
  frontend, not carrying it.

## 5.2 Redundancy: what does the Haskell type discipline actually catch?

*This is the argument that changes the answer, and the draft did not make it.*

Under (c), the Lean checker is the backstop and it produces better messages for
the same mistakes, at a position, in one sentence, with the escape named, pinned
byte-for-byte by a 201-case battery that a coverage audit forbids you to bypass.
So run the test: **list what the GADT, the phantom brand, `Renderable`,
`Discardable`, `NonEmpty` and the typed addressee catch that the Lean checker
would not catch on the emitted text.**

| The Haskell type catches | Does Lean catch it on the emitted `.wf`? |
|---|---|
| Flag or receipt in a hole (`Renderable` TypeError) | **Yes.** GRAMMAR.md: *"Flags and receipts have no canonical text and are refused."* |
| A discarded non-receipt answer (`Discardable`) | **Yes**, and better: `Check.lean:566`, ``…`{f}` answers `text`, and its answer has nowhere to go: bind it, `x <- {f} …` `` |
| A non-verdict panel member | **Yes.** Rule 4: panel members force `verdict` |
| An empty panel (`NonEmpty`) | **Yes.** `check_panel_nil` (`Check.lean:717`) — it is one of the two *exempt* battery cases precisely because it is unreachable from source |
| Budgets and quorum bounds (`checkPlan`) | **Yes.** `maxRevisions := 64` (`Check.lean:502`), `maxQuestions := 4096` (`:857`), with their own sentences |
| Scope escape (the phantom brand, and `checkPlan`'s pass) | **Vacuous.** In `.wf` an ill-scoped program is not writable; the mistake exists only because the surface is Haskell |
| Using an answer as a Haskell value (§1.11 Mistake 2) | **Vacuous.** Rule 3 means there is no expression language to write it in |
| Kind ambiguity (GHC-39999) | **Vacuous**, and the §1.6 repair deletes it anyway |
| `served by` off a tool or a person | **No — and this is the only entry.** GRAMMAR.md records the Lean refusal as an outstanding obligation: *"`served by` is refused off `ask model` (no such refusal exists today)"* |

**One entry.** And it is one refusal site in `Check.lean` that has to be written
for the `.wf` surface anyway, whichever option wins.

Everything else the types buy is either (i) already a Lean refusal with a better
message, or (ii) a defence against a mistake that exists **only because the
surface is Haskell** — a tax the design levies on itself and then books as a
feature.

Meanwhile the two refusals that genuinely *cannot* be Lean's — the
generator-blowup refusal of §3.3.5 and the branch-shared duplication refusal of
§3.3.1(iv) — are frontend **passes over the emitted statements**, not type-level
constructions. A program that prints text can do both.

### The honest residue of (c)

Run that conclusion forward. Under (c), the 24½–29½ days of frontend buys a
second, weaker checker standing in front of a stronger one. Everything the macro
layer actually delivers — modules, HLS, Hoogle, `foldr` over `[1..n]`, versioning,
the three workflows of §4.2 — is available from **any program that prints `.wf`
text**: a few hundred lines of ordinary Haskell with no GADT, no phantom brand, no
quasi-quoter, no `Splice` class, and no type-level anything, plus the two frontend
refusal passes and the brace-escaping rule of §3.3.1(ii).

**Price that: 2–3 days, plus the golden `.wf` pins and the round-trip property
(~2 days), against 26–32 for the typed builder.** It forfeits the type-level
catches, all of which §5.2's table just showed to be redundant or self-inflicted.
It keeps the emitter's four analyses because those are about `.wf`, not about
Haskell.

It is not a fifth option; it is what (c) reduces to once the redundancy test is
run, and it is the shape (c) should take if it is ever built.

## 5.3 The dissents against each other

The two arguments point the same way — toward keeping the `.wf` surface as the
authored artifact — but they disagree about what to build when the capability is
finally needed. §5.1 says any generator breaks the read-the-page property, so the
answer is to write the statements by hand and accept the ceiling. §5.2 says the
generator is coming eventually and the cheap one is strictly better than the
expensive one. §6 splits them: §5.1 governs *now* and §5.2 governs *the trigger*.

---

# Part 6 — Recommendation

## 6.1 The recommendation

**Take (d). Ship the do-core, descope the calculus, and hold the Haskell question
behind a named trigger.**

1. **Implement round 17's do-core: ~2 days.** `answer` deleted cold, last
   statement is the result, default-text parameters, trailing-bind refusals with
   primings exempt, the assertion ruling, the fence-close fix. This is work
   (a)/(c)/(d) all require and (b) makes moot; it is the only item on this page
   that is unconditionally worth doing today.

2. **Do not run the calculus.** `calculus-design.md` is good and does not rot; it
   stays available and its reopening condition stays recorded. Its ~8–9 days of
   calculus-specific work are the budget for step 3.

3. **Spend the returned ~8–9 days plus the shared floor's 5–6 on the runner**
   (§3.0): the content-addressed leaf store with fork/resume as one code path, and
   typed backend/model pairing with preflight. That is the difference between a
   language and a tool, and (a)'s own risk cell names the thin runner as its
   exposure while the fix sits outside its price.

4. **Write the three workflows of §4.2 in `.wf` by hand**, at whatever *n* they
   actually need, before deciding anything else. This is the decision procedure
   the draft's "bake-off" lacked, and it has a criterion stated in advance:

   > **The trigger.** If writing them by hand is merely tedious, (d) holds and the
   > Haskell question closes. If a workflow's *n* is not known when the file is
   > written — a per-file review over a changeset whose size varies — then `.wf`
   > cannot express it at any price and the trigger has fired.

5. **When the trigger fires, build the `.wf` printer of §5.2, not the typed
   builder.** 2–3 days plus ~2 for the golden pins and the round-trip property,
   against 26–32. Take the naming obligation from the start (`askText' "patch"`),
   because it is what makes the emitted text readable *and* what recovers rule 6,
   and it costs a day only if it is designed in rather than retrofitted.

The reasoning in one line: **the calculus is the expensive way to buy an
abstraction the surface does not yet need, and the typed Haskell builder is the
expensive way to buy a capability that a printer delivers.** (d) declines both
purchases and pays for the runner instead.

### What this recommendation is not

It is not a rejection of Part 1. The library there is good — better than
agent-functor by a wide margin, because the prompt is first-order and the
continuation binds a name rather than an answer — and if the goal ever changes
from *meanings first* to *ship an agent runner people use*, (b) is the fastest
route to the second goal and the theorems were never load-bearing for it. That is
a legitimate position, it is a values question rather than a technical one, and it
should be decided deliberately rather than arrived at by increments.

## 6.2 The dissent against this recommendation

*Stated fully so it can be chosen.*

**(d) freezes the surface one round short of usable, and the campaign's own
question goes unanswered.** Round 18 exists because the owner named four
directives — Kleisli pipelines, function composition, lambdas, "the whole deal" —
and (d) delivers none of them. The trigger in step 4 is a test of *iteration*, but
the calculus was never about iteration; it was about writing a workflow without a
binder for every intermediate. §4.2 measures the wrong thing, and a surface that
cannot say `judged . normalize` will be abandoned for reasons the trigger never
detects.

Three supporting points:

* **(a)'s number is the only attacked one, and it is small.** Ten to eleven days,
  sixty findings, three fatal and all closed, a re-elaboration risk of near zero
  because `Dsl.lean`, `Explain.lean` and `DslFlagship.lean` are not edited for
  content, and a pre-agreed de-scoping lever that kills the higher-order path in
  one line. If the decision is made on evidence quality rather than on ambition,
  (a) wins outright — and this page has just spent five sections demonstrating
  that unattacked estimates move by factors of two.

* **The A3 win is real and (d) does not get it.** Under (d), every question a
  library exports as a function is off the batch rung forever (§1.4). That is the
  closed-question payoff the imports design leads with and does not deliver, and
  the only routes to it are (b) and (c).

* **Descoping is not free of the risk it avoids.** §5.1's ceiling argument cuts
  both ways: a surface that cannot grow is a surface that gets replaced. Deferring
  the calculus for a runner may simply move the abandonment date.

**The dissent's recommendation, stated so it can be chosen:** run round 18 as
designed with option (b) held as the cut line; spend the following two weeks on
the runner; and revisit the Haskell question in six months, when there are ten
real workflows to read and it will be obvious from the text whether the surface is
too small.

**Where the two positions actually differ** is narrow and worth naming: both agree
the do-core ships, both agree the runner is underbuilt, both agree the typed
Haskell builder should not be built. They differ on whether the calculus is worth
8–9 days *now* rather than later, and that is a question about how soon real
workflows will be written — which is a fact about the owner's next two months, not
about this page.

## 6.3 What is true under every option

1. **The prompt must be first-order.** agent-functor's opaque `a -> Prompt` is the
   single defect that makes its `plan` useless and its `cost` shape-blind.
   Whatever is chosen, do not let a prompt become a function.
2. **Content addressing is the invalidation.** No dependency cone is needed; a
   perturbed leaf changes the next leaf's rendered brief, hence its key, hence its
   miss. Build the store.
3. **A hit is a replay, not a reproduction.** Mark it `Cached`, never `Done`.
4. **Salt the key with backend and model**, or a fork onto another model reports
   someone else's work as the new model's.
5. **Acts are never cacheable.** A cached `verify` serves a stale "tests pass".
6. **`verify` runs the checks itself; `agentVerify` trusts a claim.** agent-cat
   does not draw this distinction and should.
7. **The `{name}` hole spelling should be the same in both surfaces** if there are
   ever two, so a prompt can move between them unchanged.
8. **`served by` off a tool must be refused in `Check.lean`.** It is a recorded
   obligation, it is one site, and it is the only thing the Haskell type discipline
   catches that Lean does not.
9. **`acat-pos-module-attribution-oxq` blocks more than it looks like it blocks.**
   Any future cross-file position work — a source map, a better library
   diagnosis — is behind it, and closing it recomputes the flagship pins.

---

## Appendix — what this page does not do

* **It does not check the GHC transcripts.** §1.11's four errors are
  reconstructions. Before this page is used for a decision, they should be
  produced from a stub module, because the draft's versions were not producible by
  the code they accompanied and that error survived into a recommendation.
* **It does not derive the §1.10 fate census.** The five-way partition of the 201
  diagnoses is labelled an estimate and nothing is derived from it. Deriving it
  means walking `batteryCases`/`batteryCasesM` and assigning each case a fate.
* **It does not name the owner's real workflows.** §4.2's three are constructed
  from the capability. The trigger in §6.1 step 4 is written so that the owner's
  own workflows, not this page's guesses, decide it.
* **It does not settle §5.5's line 2.** Haskell inverts the sharing rule round 18
  decided deliberately (§1.7). Under (b) or (c) that needs an owner ruling, and it
  is not one this page can make.
