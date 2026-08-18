# The connection

*A decision page for the owner: how the production Haskell program is connected
to the Lean formalization. Four mechanisms — extraction, FFI, subprocess oracle,
reimplementation-plus-bisimulation — priced against the actual repository, with
the measurements that produced each number. This page decides
`obr acat-haskell-program-xgw` phase 2 and nothing else: the effectful runner
(ACP/deck backends, store, IO) is Haskell-owned under every option and is not
argued here.*

Sources: three commissioned sweeps — codegen (2026-08-16), FFI/subprocess
(2026-08-16, with live measurements against the prebuilt binaries), and
conformance architecture (2026-08-16) — then **an adversarial pass over the
resulting draft (2026-08-16) that returned two fatal findings and seventeen
others**, all of which are applied here. Plus direct reads of
`Agentic/Core/{Plan,Denote,Dlg,Question,World,Cost,Certify,Report,Exec,Explain,Mcp,Rpc}.lean`,
`Agentic/Core/Dsl/{Syntax,Parse,Check}.lean`, `test/{DslSmoke,McpSmoke}.lean`,
`lakefile.toml`, `lean-toolchain`, `flake.nix`, and Mathlib's
`Data/List/Defs.lean`. No `lake build` and no `lake exe` were run in producing this
page; sweep 2's timings came from binaries already present in `.lake/build/bin`.

**What the adversarial pass changed, for a reader comparing against the draft.**
Two structural repairs: the conformance boundary now runs the other way (§3.1, D5 —
the draft's `RawProgram`-in boundary required a Haskell elaborator that D10 and §3.6
had already deleted), and the third verification tier is coverage rather than
`certify` (§3.10, D9 — `certify` at `Plan [] Unit` is `rfl`). Eight smaller
corrections carry through the rest: the dedup direction (Lean keeps the **last**
occurrence), the MCP surface's actual reach (§1.3), the renominated most-likely bug
(§3.5), the rescoped week one (§7), the priced harness (§1.5b), the Mathlib CI
precondition (§3.9), the demoted closure fact (§0, §2), and two further dissents
(§5.2b, §5.2c).

---

## 0. The one-paragraph answer

**Reimplement, and connect by conformance testing over a Lean oracle process —
because the other three mechanisms are, respectively, non-existent, actively
harmful, and already built.** Extraction does not exist: there is no Lean→Haskell
path at any maturity level in 2026, and a bespoke one would be a compiler-internals
metaprogram larger than the ~500 lines of fold code it could mechanize. FFI is
feasible and is a bad trade: it buys back 132 ms of one-time process start against
LLM calls measured in seconds, and it costs 456 Mathlib object files and `-lLean`
inside the production binary, behind an ABI the Lean manual itself calls unstable,
with the run state living in Lean's heap — which is *worse* for the pure-Haskell
framing than a pipe, not better. The subprocess is not a proposal but a running
system: `Agentic/Core/Mcp.lean` is 1,678 lines, in `defaultTargets`, driven by two
smoke tests, and sweep 2 ran a complete flagship workflow through it in 134.55 ms
end to end, of which the entire semantic workload was ~1.5 ms. **That system is the
right oracle and the wrong production dependency** — so it becomes the test
harness's transport, exactly as Cardano extracts Agda only for its conformance
suite and never ships it. (It is not, however, *free* as an oracle: the four MCP
tools step a run and do not expose the observation record this page compares — §1.3.)

And the reimplementation is smaller than the brief implies, but only because of a
decision the brief did not contain and that this page now makes explicitly
(**D5**, §3.1): **the Haskell does not elaborate `Raw`.** `.wf` staying out of
production deletes the 964-line parser from the Haskell obligation, and the only
total function from `RawProgram` to `Plan [] Unit` is `Dsl.checkProgram`
(`Check.lean:949`) — so if the conformance *input* were a `RawProgram`, the Haskell
would have to port the ~630-line checker to answer any question about it. It does
not. The boundary inverts: the **typed builder is the source of the term**, it
emits a serialized `RawProgram` for the oracle to check and observe, and it
elaborates to a native `Plan` the Haskell observes for itself. The residual Haskell
semantic core is ~1,550–1,850 lines, and the new seam this buys — the **Raw
emitter**, the builder-term→`RawProgram` translation, which nothing on either side
checks — is named in §4 rather than hidden. (It emits the `Raw` *datatype*, as JSON;
D10 stands and no `.wf` text is generated anywhere.)

One structural fact should be read before the tables, in its correct scope: `Plan`
contains closures (`Expr Γ A = Env Γ → A`, `Plan.lean:151`; `case` storing its arms
as `T → Plan Γ A`, `:278`; `dyn`, `:285`), so plans are neither serializable nor
comparable in any language, and conformance can only ever be checked
**observationally**. That is why the harness has the shape it has — and it is
identical under all four mechanisms, which is exactly why it discriminates between
none of them. Extraction emits *code*, not data; closures are what every compiler
emits, and §1.1 correctly locates extraction's real obstacles elsewhere (index
erasure, higher-rank `Cont`, `Type 1` residence, Mathlib carriers). FFI's obstacle
is heap ownership, not serializability. The mechanism choice below is made on
evidence about tooling, not on this fact.

### 0.1 The decisions, numbered

| # | Decision | Where argued |
|---|---|---|
| **D1** | **Reimplement the semantic core in Haskell.** Production ships no Lean. | §1.4, §5 |
| **D2** | **No extraction, no bespoke generator.** Not now, not behind a flag, not as a stretch goal. | §1.1, §6.1–6.3 |
| **D3** | **No FFI.** Not now and not later; the composition argument in §2 shows it is not a deferred upgrade path but a dead branch. | §1.2, §6.4 |
| **D4** | **Keep the Lean side as an *oracle process*, used by tests only.** A new `lean_exe conformance-oracle` speaking line-delimited JSON, importing `Agentic.Core.{Dsl,Cost,Denote,Report}` and **not** `DslFlagship`. Not the MCP server: the four tools step a run and do not emit the record (§1.3). | §1.3, §3.2 |
| **D5** | **The boundary inverts: the conformance input is the Haskell typed builder's term, transported as a serialized `RawProgram`.** The builder emits `Raw` for the oracle and elaborates to a native `Plan` for itself; the harness property is `oracle(print b) ≡ observe(elaborate b)`. Never a `Plan` on the wire — it cannot be. | §3.1 |
| **D6** | **Two tiers.** Tier 0: frozen JSON vectors, committed, no Lean required, runs on every Haskell commit. Tier 1: live differential + shrinking against the oracle binary, runs where the binary is available. | §3.9 |
| **D7** | **Refusal parity is compared by a *code assigned in the oracle*, not by rendered message and not by a new field in `CheckError`.** `CheckError` has no classification field (`Syntax.lean:95–102`) and its messages are pinned inside theorems; the enum is a total function from message text to a closed set, living in the oracle only. Compared: guard identity and, for `maxQuestions`, the computed `n`. Not compared: `pos`, `excerpt`. | §3.6, §6.7 |
| **D8** | **No normalization in the comparison of *traces*.** A trace is a free monoid and its order is the observation. For **bills** the rule is a guard against a future non-commutative price, not a live divergence class — every price in the repo is `Multiplicative ℕ`. | §3.5, §6.8 |
| **D9** | **The third tier is *coverage*, not `certify`.** `certify` at `Plan [] Unit` is constant-true by `rfl` (`Report.lean:247`) and is not an upgrade over anything. The per-run claim with content is `Plan.coveredB` + `Mcp.reporterOf_warrants`. Recorded, priced, deferred. | §3.10, §5.2 |
| **D10** | **The Haskell parser is not written.** `.wf` parsing stays Lean-only and stays tested where it already is. | §1.4, §6.5 |
| **D11** | **The Haskell does not implement `checkProgram` either.** The ~630-line checker, its 36 `.error` sites, `Bindings`/kind inference and the import walk stay Lean-only. The Haskell's only static obligations are the four guards (§3.6 A) and the Raw-level ask counts `blockAsks`/`bodyAsks`/`rhsAsks`. The alternative — port it — is priced and rejected at §6.12. | §3.1, §6.12 |
| **D12** | **A second oracle request kind for the string layer.** `norm`, `words`, `decodeVerdict`, `Decode` per code, and the report-side `sayAnswer`, frozen as a Tier-0 vector table. It is the surface this page ranks highest-risk and the only one that needs no `Plan` at all. | §3.2, §3.5 |
| **D13** | **The oracle carries a per-request wall-clock budget, and `timeout` is a distinct observation value**, not a comparison failure. The two implementations have different asymptotics on the same program (`Env.consBy`, §1.4), so an asymmetry must be recordable as an asymmetry. | §3.2, §1.4 |

### 0.2 What the sweeps changed about the plan as briefed

Five corrections, each of which moves a cost or a target by more than a factor of two.

| Correction | The brief assumed | Actual |
|---|---|---|
| **The `Plan`-indexed boundary is unusable on the Haskell side** | `RawProgram` in, observations out, symmetrically | every comparand except the Raw-level ask counts is a fold over `Plan`, and the only way from `Raw` to `Plan` is `Dsl.checkProgram` (`Check.lean:949`). A `RawProgram`-in boundary silently requires the Haskell to own the checker. **D5 inverts the boundary instead** (§3.1); the alternative is priced at §6.12 |
| **Size of the Haskell semantic obligation** | "the semantic core that must agree" reads as seven items, one of which is the checker | the parser (964 loc) is out under D10 and the checker under D11; what returns to the budget is `costTree`+`minFold`/`maxFold`/`leaves` (~150–250 loc plus a `WithTop`/`WithBot` ordered shim), which the draft promised as a comparand and never priced. Residual: **~1,550–1,850 loc**, of which ~500 is one-clause-per-constructor folds |
| **The oracle is nearly free** | building an executable spec is a project | `lakefile.toml` already carries **nine** `lean_exe` targets; `Agentic.Core.Dsl` builds in ~1.5 s and `agent-cat` cold in ~6 s **provided `DslFlagship` is not imported** (~6 minutes and gigabytes, `lakefile.toml:13`, `:24–25`, `:95`). But that six seconds is *for the DSL layer above an already-built Mathlib* — Tier 1's real precondition is a warm Mathlib cache or a pinned store path (§3.9) |
| **Where the divergences will actually be** | the interesting risk is `denote`/`Plan` | (a) string semantics — `Exec.norm s = s.trimAscii.toString.toLower` (`Exec.lean:98`) is ASCII-only where Haskell's `toLower` is Unicode, across `norm`/`words`/`decodeVerdict`; (b) **duplicate function names**: `Fns` is a `List`, `Fns.find?` returns the *first* match (`Check.lean:305–309`), and nothing in `checkFnsList`/`checkProgram` refuses two `function f` declarations — a Haskell keyed on `Map.fromList` (last wins) resolves every such call to the wrong body |
| **The memoized ask count is *not* the bug** | (the draft nominated it) | `checkFnsList`'s `{ fe with asks := n }` (`Check.lean:913–923`) is computed against a table whose every entry already holds its own transitive count, computed the same way — a correct dynamic program over a stratified table, not an approximation. The `none => 0` branch of `rhsAsks` (`:881–884`) can only fire on a forward call, and every forward call is refused before the count is read (`:421`, `:600`, `:802`). Week one was aimed at a bug that is not there |

---

## 1. The four mechanisms

Each is priced for *this* codebase, naming the exact boundary object it would
cross.

### 1.1 M1 — Extraction / code generation (Lean → Haskell)

**The boundary it would cross.** All of it: `Plan`, `Env`, `Var`, `Dlg`,
`denote`, `Plan.trace`, `billFresh`/`billMemo`, `Level`, `Decode`, `checkProgram`
— generated Haskell, compiled into the production binary.

**2026 tooling reality.** There is nothing. Sweep 1 searched GitHub repo and code
search, the Lean Zulip archive, arXiv, and the FRO/Peregrine ecosystems: no
Lean→Haskell transpiler, extractor, or backend exists at any maturity, maintained
or abandoned. The nearest four things and what they actually are:

| Thing | What it does | Haskell? |
|---|---|---|
| [lean4export](https://github.com/leanprover/lean4export) (pushed 2026-08-11) | dumps kernel declarations for *proof re-checking*, consumed by [lean4lean](https://github.com/digama0/lean4lean) / [nanoda_lib](https://github.com/ammkrn/nanoda_lib) | no — and no executable semantics |
| Lean's own codegen | `Expr` → LCNF → C. [Lean 4.30.0 (2026-05-26)](https://lean-lang.org/doc/reference/latest/releases/v4.30.0/) moved C emission from IR to LCNF (#12781) and broke metaprogram APIs (#13005) | no |
| [lean-to-lambdabox](https://github.com/inria-cambium/lean-to-lambdabox) + [Peregrine](https://peregrine-project.github.io/) | erasure from elaborated Lean `Expr` to λ□, then λ□ → C, Wasm, Rust, OCaml, CakeML, Elm | **no Haskell backend.** 5★, no releases |
| [auser/lean4-prod](https://github.com/auser/lean4-prod) | Lean→Rust over LCNF, `@[prod]`-annotated | no. **3 commits, 1★** |

The Peregrine numbers are the ones to record because it is the only credible
mechanical route and it still fails: per the [MPRI report (Dima, 2025-10-01)](https://www.normalesup.org/~sdima/2025_extraction_report.pdf),
I/O, async and fixed-width integers are unsupported, `Nat`/`Array` need
hand-written OCaml axioms, output is ~2.5× slower than Lean's own C, and only the
OCaml and Wasm backends are marked verified. Its `hs-lib/` ships the λ□ AST *as a
Haskell datatype*, so a λ□→Haskell printer is writeable — and its output would be
`unsafeCoerce`-laden untyped-λ□-shaped Haskell, which is the opposite of typed-builder
authoring.

**A bespoke generator, scoped.** Sweep 1 measured the fragment: ~2,460 lines of
non-comment non-proof executable Lean against ~1,510 of proof, across the twelve
modules that must agree. Of that, the entire proof-carrying semantic core —
`Question` 72, `Dlg` 59, `World` 26, `Plan` 112, `Denote` 69, `Level` 33, `Cost`
121, `Certify` 12 — is **~500 lines**. Layer by layer:

| Layer | Mechanically generatable? |
|---|---|
| Raw AST (`Dsl/Syntax.lean`, ~112 loc) | yes, trivially |
| Parser (~964 loc) | in principle, into ugly Haskell; string primitives need bridging anyway |
| `Plan`/`Env`/`Var`/`Dlg` types | **no** — the target GADT is a design decision with several defensible encodings; only a human picks one |
| The folds (~500 loc) | yes, *given* a fixed hand-written GADT. This is the only place a generator earns anything |
| Checker (~630 loc) | **no** — `paramBindings` (`Check.lean:750`) has result type computed by a `foldl` over a *runtime* list; `FnEntry`/`Pend Γ` live in `Type 1` |
| Mathlib carriers | no — ~150 loc of hand shim beats chasing `Quot`-based `Multiset` and instance chains |

**Verdict.** The generator would be larger than its output, would own an
LCNF-or-`Expr`-level metaprogram against an API that demonstrably churns *at the
exact version this repo pins*, and would be the thing that breaks on every
toolchain bump. The maintained precedent, [agda2hs](https://github.com/agda/agda2hs)
(209★, pushed 2026-08-05), is a warning rather than an encouragement: it extracts
only a carved-out subset, requires `--erasure`, **explicitly erases indices of
indexed datatypes** (which is exactly the well-scopedness that makes `Plan`
`Plan`), forbids the stdlib in favour of a mirrored prelude, and does not support
higher-rank types — which rules out `Cont Γ A B := ∀ Δ, Sub Γ Δ → Expr Δ A → Plan Δ B`
(`Plan.lean:410`) outright. Adopting that discipline means rewriting the Lean to
suit the extractor, which contradicts "the Lean is retained in full as the proven
specification."

| | |
|---|---|
| **Setup cost** | 4–8 weeks for a bespoke generator; ∞ for an off-the-shelf one |
| **Per-change cost** | breaks on every Lean release; a CI job whose entire purpose is detecting compiler-API drift |
| **Proves vs tests** | would prove nothing by itself — extraction correctness is unverified for every non-OCaml/Wasm backend that exists |
| **Failure modes** | silent miscompilation; `unsafeCoerce` everywhere types depend on values ([coq#1257](https://github.com/coq/coq/issues/1257), open since **2006**); GHC-version-pinned preamble breakage ([coq#14256](https://github.com/coq/coq/issues/14256), GHC 9.0 dropping `unsafeCoerce#`) |
| **"Pure Haskell" framing** | nominally preserved, actually destroyed — generated Haskell is not authorable, not reviewable, and not typed the way a builder is |

**Rejected (D2).**

### 1.2 M2 — FFI (Lean linked into the Haskell binary)

**The boundary it would cross.** `Dlg.Ask` and friends — and this is the decisive
detail. `Agentic/Core/Mcp.lean:157–171` already contains the exact init/step/finish
decomposition an FFI boundary would need, *and it is proved*:

```lean
structure Dlg.Ask (A : Type) where
  c : Code
  q : Q c
  k : El c → Dlg A          -- Mcp.lean:157-171
def Dlg.resume {A} (t : Table) : Dlg A → Dlg A     -- Mcp.lean:173
def Dlg.pending? {A} : Dlg A → Option (Dlg.Ask A)  -- Mcp.lean:182
```

with `Dlg.execM_resume`, `Dlg.resume_pending`, `Dlg.execM_deliver`
(`Mcp.lean:206–260`), each pinned by `#print axioms` at `:266–278` to depend on
**no axioms**. The docstring states the boundary constraint outright: "The pair
`(Dlg A, Table)` a run in progress consists of cannot be sent over a wire, but
this can: `c` and `q` are data, and `k` stays in the server."

**`k : El c → Dlg A` is a closure.** Under FFI it lives on the Lean heap as an
opaque `lean_object*` that Haskell holds by handle. **The run state therefore
lives in Lean's heap**, and the Haskell program becomes a refcount-manager for a
foreign heap. That is strictly worse for the pure-Haskell framing than a
subprocess, where the state at least sits behind a serialized boundary with a
replay story.

**2026 mechanics, with one correction to the obvious straw-man.**
`@[export] f : @&String → ...` does not do what it looks like: per the
[Lean reference §12.4 FFI](https://lean-lang.org/doc/reference/latest/Run-Time-Code/Foreign-Function-Interface/),
"Return values and `@[export]` parameters are always owned at the moment" — `@&`
is an `@[extern]`-direction annotation. Every string Haskell passes in is
*consumed*; Haskell must `lean_inc` first. Initialization is
`lean_setup_args` (required, since `Acp.lean` spawns children) → per-module
`initialize_<pkg>_<Module>(builtin)` with `lean_io_result_is_ok` checks →
optional `lean_init_task_manager()` → `lean_io_mark_end_initialization()`;
initializers are "idempotent … but not thread-safe." And the manual's opening
caveat is that the interface "was designed for internal use in Lean and should be
considered unstable."

Dependent types must be erased at the boundary — there is no C representation of
a dependent pair, so `Q c`/`El c` must be tagged-by-code. **Which is precisely
what `Mcp.answerSchema` (`Mcp.lean:350`), `sayAnswer` and `Decode`
(`Exec.lean:273`) already do.** A workable handle-based boundary —
`acat_check` / `acat_start` / `acat_pending` / `acat_answer` / `acat_report` — is
byte-for-byte the same API surface as the four MCP tools. FFI here means building
a second, unsafer transport for an interface that already has one.

**GC interaction is milder than folklore, thread affinity is not.** Lean uses
reference counting with in-place reuse and no cycle collector
([reference §12.2](https://lean-lang.org/doc/reference/latest/Run-Time-Code/Reference-Counting/),
[Counting Immutable Beans](https://arxiv.org/pdf/1908.05647)), so there is no
stop-the-world pause to interleave with GHC's, no moving collector, and no need
for `StablePtr` on the Lean side. But Lean requires `lean_initialize_thread()` on
foreign threads, its RC has a non-atomic single-threaded fast path, and GHC's
`forkIO` threads migrate between capabilities at the scheduler's discretion.
[lean-rs](https://github.com/jcreinhold/lean-rs) states the contract plainly:
Lean handles are `!Send + !Sync` (`04-concurrency.md`). Every Lean call must
therefore go through one dedicated bound thread serving a queue — **which is a
subprocess with extra steps and no process isolation.**

**The build cost, measured.** From `.lake/build/bin/agent-cat.rsp`: **734 object
files link into `agent-cat`, of which 20 are Agentic's own** — 456 Mathlib
(including `Mathlib/Tactic/Linter/*` and `Mathlib/Lean/Elab/InfoTree`), 135 Aesop,
73 Batteries, 13 Plausible, 8 ProofWidgets, 10 import-graph. The link line pulls
`-lLean`, i.e. the whole frontend. Binaries are ~100 MB; `libleanshared.dylib` is
158 MB; `libLean.a` is 193 MB. **No shared facet is built** for Agentic or any
dependency — only `.o.export` objects — so FFI requires either adding
`LeanLib.sharedFacet` and getting shared builds of the entire Mathlib chain, or
linking all 734 objects directly. Mathlib is not removable from the semantic
core: `Denote.lean:2` is `Mathlib.Algebra.BigOperators.Group.List.Basic`, needed
for `List.prod` in `run_panel`.

And the nearest thing to a precedent — disclosed to the same standard this page
applies to the projects it rejects, because otherwise the numbers are being used
selectively. **lean-rs is 4 stars, 1 fork, 386 commits, one author, macOS/Linux
only, supporting Lean 4.30.0–4.34.0-rc1.** It is not "the decisive precedent"; it
is *the only worked example of a real typed Lean FFI, by a single author*. Its
substance was checked and holds exactly as quoted: `!Send + !Sync`
(`04-concurrency.md`); the worker-pool pattern recommended for long-running hosts;
`LeanWorkerRestartPolicy::memory_bounded` with RSS budgets; panic containment "via
process boundary"; **JSON rows** as the data plane (`18-worker-data-streaming.md`).
And one detail the draft omitted that strengthens the argument more than the star
count weakens it: lean-rs splits into three crates in which **only the child links
`libleanshared` at all** — the parent/supervisor deliberately does not. The
isolation is architectural, not a fallback the author reached for after something
failed. Sweep 2 found no project anywhere embedding Lean *and Mathlib* as a library
in a foreign host.

| | |
|---|---|
| **Setup cost** | 2–3 weeks to a first typed call, *plus* an unbounded shared-facet build project that does not exist today |
| **Per-change cost** | ABI churn per Lean release; marshalling layer edited on every boundary change; RSS/leak soak tests forever |
| **Buys** | ~132 ms of one-time process start, against LLM calls of 1–30 s. Four to six orders of magnitude of nothing |
| **Failure modes** | owned-object over/under-`lean_inc` (leak or use-after-free, invisible to property tests); handle used after free or from the wrong thread; silent RC corruption under `forkIO` migration; segfault takes the Haskell process with it |
| **"Pure Haskell" framing** | actively worse than the subprocess: the run state is a foreign heap object |

**Rejected (D3).**

### 1.3 M3 — Subprocess oracle (Lean behind a pipe)

**The boundary it would cross.** Line-delimited JSON. `Agentic/Core/Rpc.lean` is
a generic JSON-RPC 2.0 layer (155 lines, `Msg.ofLine`, standard error codes,
round-trip `#guard`s at `:129–146`); `Agentic/Core/Mcp.lean` (1,678 lines) is an
MCP dispatcher on top of it, in `defaultTargets`, with two smoke tests —
`test/McpSmoke.lean` over a line list and `test/McpClientSmoke.lean` over a real
pipe with a real Python client (`test/mcp_client.py`).

**It is finished, and sweep 2 drove it end to end** against `example/harden.wf`
with `--no-elicitation`:

| step | wall |
|---|---|
| `initialize` (**includes spawn + all module initializers**) | 132.41 ms |
| `workflow_check` (parse + typecheck + `Cost.costTree` → `level: branch`, `bill: 5…15 over 9 paths`) | 0.52 ms |
| `workflow_start` (denote + `Dlg.resume` to first question) | 0.48 ms |
| `workflow_answer` × 7 (`Decode`, table extend, resume) | 0.04–0.27 ms each |
| whole run to final report incl. bill + certificate | **134.55 ms** |

The entire semantic workload is ~1.5 ms; everything else is process start. The
four tools **step a run**, and that is a different thing from emitting the record
§3 compares. Honestly tabulated:

| brief's semantic core | MCP surface | on the surface? | file |
|---|---|---|---|
| `checkProgram` | `workflow_check` → `Dsl.parseAndCheckE` | yes | `Mcp.lean:850`, `runCheck` `:1136` |
| Level, `costSummary` | `workflow_check` → `checkSummary`, `Cost.costTree` | yes | `Mcp.lean:1088` |
| `denote`/`Dlg` stepping | `workflow_start` / `workflow_answer` | yes | `Mcp.lean:900`, `:929` |
| `Decode` per kind | applied inside `workflow_answer` | **only as a side effect** — never callable on a text alone | `Mcp.lean:929`, `Exec.lean:273` |
| **structured `Plan.trace`** | — | **no.** `reportJson` emits `"transcript"` = `r.heard.map heardJson` (the *arrival* list) and `"replay"` = `(Trace.render rep.transcript).map Json.str` — a **pretty-printer's string list** (`Trace.render = tr.map Event.render`, `Report.lean:518`), of which the only theorem is that it has the same length (`Trace.length_render`, `:522`) | `Mcp.lean:1195–1226` |
| **per-world traces** | — | **no.** One run, one table, one world | |
| `Plan.size` / `Plan.askNodes` / `Cost.asks` | — | **no** | `Explain.lean:140`, `:155` |
| `billFresh`/`billMemo` | final report, as two `Nat`s | yes | `Report.lean:665`, `:669` |
| `value` | `("value", Json.str "()")`, hardcoded | yes, and vacuously — every program is a `Plan [] Unit` | `Mcp.lean:1201` |

A Haskell asked to match `"replay"` would have to reproduce `Event.render`'s column
padding byte-for-byte. **So D4's oracle shares essentially nothing with the MCP
server except `Rpc.lean`'s framing**, and the "2–4 days for a Haskell client against
the existing MCP surface" figure prices a different program. It has been moved out
of the §1.5 mechanism comparison into a separate harness line (§1.5b), and D4's
oracle is re-derived in §3.2 from what it actually is: a new executable emitting
`Trace` as *data* — `Event.toSigma` (`Dsl.lean:50–61`) already gives the Σ-shape and
the `DecidableEq`.

Two further limits of the surface, both load-bearing for §3.4(c):

- **`importRefusal` (`Mcp.lean:1126–1134`) refuses any source containing an
  `import`, before parsing**, in the surface's own words. The whole function/import
  layer is unreachable through the four tools — including `example/library.wf` and
  `example/harden-imported.wf`. This is not a defect of the oracle design, because
  `RawProgram` is the *post*-import-walk object: `parseProgramWith`, `qualifyPrimer`
  and module resolution sit outside the conformance boundary by construction and
  are Lean-only under D10. The two imported examples enter the corpus by being
  walked once and frozen as a single `RawProgram` each.
- **`heardMatchesReplay` is not a self-check, and must not be cited as one.** It is
  `decide (r.trace = rep.transcript)` where `r.trace = r.heard.map (·.event)`
  (`Mcp.lean:627`) is *memo-deduped* — `deliver` appends one `Heard` per delivered
  answer and `Dlg.resume` then walks past every question the table now answers
  (`Mcp.lean:173–180`, `:1319–1321`), so a repeated question is never surfaced twice
  — while `rep.transcript = Plan.trace (worldOf table) p Env.nil`
  (`Report.lean:628`) carries full multiplicity, `billFresh` being its length
  (`Report.lean:681`). The two are equal **exactly when `billFresh = billMemo`**; on
  any program with a memo hit the field is `false` by construction. The repo's only
  pinned run has `fresh = 6, memo = 6` (`test/McpSmoke.lean:299–300`), so this has
  never been exercised. Filed as `acat-heard-matches-replay-memo-v55`. The harness
  wanting this signal should compare `heard` against the **dedup** of the replay,
  and week one should carry a vector with `billMemo < billFresh` — `semSrc0`
  (`test/DslSmoke.lean:764`, "one binding, holed three times, asked once") is the
  candidate. The same defect sits in `partialBillJson` (`Mcp.lean:1229`), whose
  docstring claims the mid-flight and final bills are "the same function" while it
  folds the heard list and the final report folds the replay.

**As a production dependency.** It works, and sweep 2 recommends it. Recovery is
provably exact and cheap: a run is a pure function of `(source, [answer])`, so
the Haskell store holds those two things and nothing else, and replay after a
crash costs 132 ms + N × 0.05 ms. Two operational hazards worth recording either
way: `Settings.maxMessages` defaults to **1,000,000** (`Mcp.lean:696` — the loop
is structural in this number, which is how the file avoids `partial`), so a
long-lived server must be supervised for exhaustion; and sweep 2 measured **54.37 s
for the first exec of a 100 MB unsigned binary on this macOS host** (Gatekeeper),
then 0.10 s, then 0.02 s — a design that spawns per question is fine warm and
catastrophic cold.

| | |
|---|---|
| **Setup cost** | ~2–4 days for a Haskell client **against the existing MCP surface** — i.e. for a production client that steps runs. This is *not* the oracle's cost: the oracle must emit the observation record, which the surface does not (above), and §3.2 prices it separately at ~150–250 lines plus §7's five days |
| **Per-change cost** | JSON schema parity only |
| **Proves vs tests** | the Lean side of what it computes is proved (`execM_resume`, `resume_pending`, `execM_deliver`, all axiom-free); the *wire* is tested |
| **Failure modes** | crash → respawn + replay (bounded, sound); stray stdout would corrupt the stream (nothing in the server prints there; `Settings.log` goes to stderr); `State.runs` never evicts, so RSS grows per completed run |
| **"Pure Haskell" framing** | Lean becomes a runtime dependency of production — out-of-process, restartable, replayable, crash-isolated, over a documented text protocol, but a runtime dependency, and that must be said plainly rather than finessed |

**Adopted as the test oracle (D4); rejected as a production dependency, over
sweep 2's own dissent (§5.2).**

### 1.4 M4 — Reimplementation + bisimulation

**The boundary it would cross.** A typed-builder term, transported as a serialized
`RawProgram`, with an observation record coming back (§3.1, D5). No `Plan` ever
crosses; it cannot.

**What actually has to be written.** Sweep 1's translatability analysis, applied
under D10 (no Haskell parser), D11 (no Haskell elaborator) and a typed builder:

| Piece | Haskell | Notes |
|---|---|---|
| `Code`/`El`/`Q`, singletons | ~120 loc | `Code` is a **closed 4-element enum** (`Question.lean:215`) and `El` a 4-clause type function into `String \| Verdict \| Bool \| Unit`. This is what makes the whole port tractable |
| `Env`/`Var`/`Plan` GADT | ~300 loc | `case`'s `{T} [FinEnum T] [DecidableEq T]` (`Plan.lean:278`) and `dyn`'s `{B}` (`:285`) become ordinary existentials with constraints. `Type 1` residence simply disappears. `Cont`'s rank-2 type needs `RankNTypes` and works |
| Folds: `sub`, `under`, `graft`, `denote`, `Dlg.bind`, `run`, `trace`, `level`, `billFresh`/`billMemo`, `codes`/`shapes`/`asks` | ~500 loc | one clause per constructor, near line-for-line |
| Builder-side guards (four, §3.6) + kind discipline | ~200–350 loc | not a port of `Check.lean` (D11); a redesign in which most of `Check.lean`'s 34 refusals become unrepresentable |
| `blockAsks`/`bodyAsks`/`rhsAsks` over the builder's own `Raw` | ~60 loc | folds over raw syntax against a name→asks table, needing no `Plan` (`Check.lean:877–907`). The only static comparand available on both sides in week one |
| Mathlib shim | ~150 loc | `Verdict = Maybe [Text]` with its monoid — and this one is *exact*: `Verdict = WithZero (FreeMonoid Objection)` (`Question.lean:97`), so the Haskell type loses nothing. Plus a `FinEnum` class, `Level` as derived `Ord`, `Multiset` as list-up-to-permutation. **Nothing in `Agentic/Core` is `noncomputable`** — every `noncomputable` in the repo is in the abstract semiring stratum, out of the executable core |
| `Cost.costTree` + `minFold`/`maxFold`/`leaves` + `paths` | ~150–250 loc | **the line the draft promised and never priced.** `Explain.costSummary p h = (τ.minFold, τ.maxFold, Multiset.card τ.leaves)` over `Cost.costTree` (`Cost.lean:668`), a `Fintype`-indexed tree (`node T inst f`) needing a `WithTop`/`WithBot` ordered shim on top of the row above. Kept because §5.2's whole argument for M4 is that a Haskell runner must be able to *type a budget check*; drop it and that argument weakens with it |
| `Decode`/`norm`/`words` | ~120 loc | the highest-divergence-risk surface in the entire program, and under D12 the only one testable with no `Plan` on either side |
| Raw JSON codec + **Raw printer** (harness only) | ~180 loc | `RawBlock`/`RawFn`/`RawProgram` already derive `Repr, DecidableEq, Inhabited` (`Dsl/Syntax.lean:275, 314, 325`). The printer is new under D5 and is the seam §4 names |
| **Total** | **~1,550–1,850 loc** | |

Two consequences of Haskell's evaluation order, one free and one not:

- **Free.** `Env.consBy`'s delayed tail (`Plan.lean:85`) and the 2ⁿ-cost story its
  docstring documents (3 ms at n=2 → 122 s at n=24) is a Lean-strictness artifact:
  Lean's `Unit → _` closures are re-entered, Haskell's thunks are memoized. Haskell
  does not inherit it.
- **Not free.** That means **the two implementations have different asymptotics on
  the same program.** A Tier-1 mismatch can therefore present as *the oracle
  hanging* rather than as a diff — a program that is 0.1 s in Haskell and minutes in
  Lean. The generator-termination property of §3.4 is aimed at the generator and
  answers a different question. D13 is the answer to this one: a per-request
  wall-clock budget on the oracle, with `timeout` recorded as a distinct observation
  value rather than a red test.

| | |
|---|---|
| **Setup cost** | 3–5 weeks for the core; harness in parallel (§7 starts it in week one) — and the harness is its own line item, §1.5b |
| **Per-change cost** | **dual edit forever**, *plus* the JSON-schema tax it pays as an oracle consumer. Every change to the semantic core is two edits, a schema check and a corpus refresh. This is the real price and §5.2 is built on it |
| **Proves vs tests** | proves nothing new; tests agreement on a sampled corpus. The Lean theorems remain true of the Lean |
| **Failure modes** | string semantics (`Exec.norm`'s ASCII-only `toLower` vs Haskell's Unicode, `Exec.lean:98`); **duplicate function names** resolved first-wins by `Fns.find?` (`Check.lean:305–309`) against a Haskell `Map` that resolves last-wins; `List.dedup` last-vs-first in `billMemo` (§3.5 — Lean keeps the **last**); the Raw printer, which D5 makes load-bearing and nothing checks; **and the one testing cannot reach — a consistent misunderstanding present in both artifacts, written by the same author** (§4) |
| **"Pure Haskell" framing** | fully achieved. This is the only option that achieves it |

**Adopted (D1).**

### 1.5 Side by side

The draft's single-column table conflated three different quantities and, by
presenting a *test client* (M3, 2–4 days) as a peer of three *production artifacts*,
made the adopted combination look cheapest. Split honestly, and noting that the
recommendation adopts **M4 and M3 together**, so their costs add:

| | M1 extraction | M2 FFI | M3 subprocess | M4 reimplement+bisim |
|---|---|---|---|---|
| Exists in 2026 | **no** | yes, unstable | **yes, running** | n/a |
| **Production artifact** | 4–8 wk (bespoke generator) | 2–3 wk + an unbounded shared-facet build project | 2–4 days (a client that steps runs) | **3–5 wk** (~1,550–1,850 loc) |
| **Connection + oracle** | ~0 (the generated code *is* the connection) — but see "needs the harness" | ~1 wk marshalling on top of the build project | ~0 (the client *is* the connection) | **§3.2 oracle: ~150–250 loc Lean + §7's five days** |
| **Recurring** | per Lean release, forever | per Lean release + marshalling + RSS/leak soak | JSON schema parity | **dual edit forever, *and* JSON schema parity** |
| Lean in production | yes (as generated code) | yes (linked, in-heap) | yes (subprocess) | **no** |
| Binary size added | ~100 MB of Mathlib | ~100 MB of Mathlib + `-lLean` | 0 (separate process) | **0** |
| Needs the harness anyway | **yes** | **yes** | yes (wire only) | yes |
| Proves anything new | no | no | no | no |
| Pure-Haskell framing | nominal only | **worse than a pipe** | honest but qualified | **achieved** |

### 1.5b The harness, which is not in any of those columns

The row "needs the harness anyway: yes / yes / yes / yes" concedes that the
harness is common to all four mechanisms and therefore cancels *between* them — but
it does not cancel against zero, and the draft priced it nowhere while it is plainly
the largest single line item after the core. Named and estimated:

| Harness component | Estimate | Note |
|---|---|---|
| `conformance-oracle` (`lean_exe`), §3.2 | ~150–250 loc Lean | includes the D12 string-layer request kind and D13's budget |
| Observation-record schema + Haskell codec | ~250 loc | `doc/conformance-schema.md` plus both sides' encoders |
| World DSL (`WorldSpec`), both sides, §3.3 | ~150 loc ×2 | ten combinators; the easy part |
| Curated corpus conversion, §3.4(c) | ~3 days | one-time, five `.wf` + ~19 `semSrc*` + the refusal table |
| Comparison + structured diff, §3.5, §3.7 | ~300 loc | Cardano's `diffConformance` shape; a bare `assertEqual` on a `Trace` is unreadable and will be ignored |
| Generators (a) + (b), §3.4 | ~400–600 loc | the backwards-from-rules generator is the expensive half |
| Shrinker, §3.7 | ~200 loc | shrink toward well-formedness, world last |
| CI: serialized oracle lane + artifact publication, §3.9 | ~2–4 days | plus whoever owns the Mathlib cache |
| **Harness total** | **~3–5 weeks**, roughly the size of the core itself | of which §7's week one is the first fifth |

The row that decides the mechanism is still "needs the harness anyway": nothing on
this page can be proved into place, so the question is only what you are testing
*across* — and three of the four options put a large, unstable, Mathlib-shaped
dependency on the production side of the line in exchange for a harness they need
regardless. But with the harness priced, the honest total for the recommendation is
**6–10 weeks, not 3–5**, and the dual-edit tax runs forever on top of it.

---

## 2. Do they compose?

**Yes for the harness; no for the mechanisms.**

**The harness is mechanism-independent**, and the closure fact is why — with the
emphasis in the right place. Because `Plan` contains functions, no route can
compare plans; every route must feed a term in and compare observations out. That
makes a conformance suite written against a term-in/record-out interface serve an
extracted implementation, an FFI'd one, a subprocess one, or a hand-written one
without a line changing on the comparison side. **It is therefore a fact about the
comparison, not a discriminator between the mechanisms** — it is equally true of
all four, and nobody proposed serializing a `Plan`, so ruling that out rules out
nothing. Only the *driver* — the function that turns a term into an observation
record — is mechanism-specific, and it is one typeclass instance. Under D5 the two
instances are not quite symmetric, and the harness should say so in its types: the
`Oracle` instance takes a printed `RawProgram`, the `Native` instance takes the
builder term the print came from. Cardano's harness is exactly
this shape: `class ExecSpecRule rule era` with `runAgdaRule` as the swappable
oracle call ([`ExecSpecRule/Core.hs`](https://raw.githubusercontent.com/IntersectMBO/cardano-ledger/master/libs/cardano-ledger-conformance/src/Test/Cardano/Ledger/Conformance/ExecSpecRule/Core.hs)).
Build the harness with two instances from day one — `Oracle` (subprocess) and
`Native` (Haskell) — and a third could be added later at the cost of one instance.

**The mechanisms themselves do not compose into an upgrade path**, and it is worth
being explicit because "reimplement now, extract later" is the natural thing to
hope for:

1. **Extraction later is not a live option.** It is not blocked on effort; it is
   blocked on a tool that does not exist and whose nearest relative (agda2hs)
   would require rewriting the Lean to suit it. Nothing built now brings it closer.
2. **FFI later replaces the subprocess oracle, not the Haskell core.** If FFI
   arrived, its only use would be making the harness's oracle call in-process —
   saving 132 ms per *test process*, not per test. That is not worth the shared-facet
   build project even hypothetically.
3. **The one thing that does compose forward is *coverage*** (§3.10). It is
   additive, mechanism-independent, sits behind the same boundary, and upgrades a
   *sampled* claim into a *per-run* one. If any later work strengthens the
   connection, it is this and not extraction — and it is `Plan.coveredB` +
   `reporterOf_warrants`, **not** `certify`, which is constant-true on everything
   this language writes.

So the composition answer for the ledger: **the harness is the durable asset and
should be built to outlive every mechanism; the mechanisms are a one-time choice
and the choice is now.**

---

## 3. The bisimulation harness (phase 2 of `acat-haskell-program-xgw`)

### 3.1 The boundary, fixed first — and the direction it runs (D5, D11)

**The problem the draft of this page had, stated plainly, because it is the one
thing on this page that had to change.** Every comparand in §3.5 except the
Raw-level ask counts is a fold over `Plan`: `Cost.codes` (`:304`), `shapes`
(`:321`), `asks` (`:336`), `Level.level`, `Plan.size`/`askNodes`
(`Explain.lean:140`, `:155`), `Plan.trace`, `billFresh`/`billMemo`, `costSummary`.
The only total function from `RawProgram` to `Plan [] Unit` is
`Dsl.checkProgram` (`Check.lean:949`). So a boundary of the form "**In:** a
`RawProgram`" requires the Haskell to own an elaborator — while D10 deletes the
parser and §3.6 replaces `Check.lean` with a typed builder. The boundary and the
budget contradicted each other.

**The decision (D5): the boundary inverts.** The **Haskell typed builder is the
source of the term.** From one builder term `b`:

- the Haskell **prints** a `RawProgram` and sends it to the oracle, which checks
  and observes it;
- the Haskell **elaborates** `b` to its own native `Plan` and observes that.

The harness property is `oracle(print b) ≡ observe(elaborate b)`, and the Haskell
never elaborates anything it did not build. `RawProgram` remains the transport —
the wire format is unchanged — but it is no longer an *input* the Haskell must
interpret.

**What this costs, said once and not softened.** The **Raw printer becomes
load-bearing and nothing checks it.** If `print` misrenders a term, both sides
agree about a program that is not the one the builder wrote, and the suite is
green. This is a new untested seam, it is named again in §4, and it is the honest
price of not porting the checker. ("Print" here means *emitting the `Raw` datatype
as JSON*, not emitting `.wf` text — D10 stands, and no text is generated. The seam
is the builder-term→`Raw` translation, not a pretty-printer.) Two partial
mitigations, neither a proof: **an asymmetry check** — the builder guarantees
well-formedness, so any oracle refusal on a term the builder produced is by
construction a printer bug and should be a loud, separately-named failure rather
than a refusal-parity diff; and **the curated corpus of §3.4(c), which runs the
other way** — hand-written `.wf`, parsed by Lean, frozen as `Raw`, then rebuilt
through the builder and re-printed, so a printer that disagrees with the parser
shows up as a `Raw` inequality on a known-good term. Neither reaches a printer bug
that maps one well-formed term to a different well-formed term outside the curated
set. That residue is real and it is §4's.

**The alternative, priced and rejected.** The Haskell implements `checkProgram`:
~630 loc of `Check.lean` plus `Bindings`/`Binding.at?`/`Bindings.push`
(`Check.lean:67–106`), kind inference (`bindKind`/`useKindB`) and all 36 `.error`
sites — roughly doubling the core estimate and voiding D7's "four guards". Recorded
at §6.12. It buys a symmetric `RawProgram`-in boundary and full two-sided refusal
parity; it is rejected because it is the largest and riskiest half of the Haskell
obligation and it duplicates the part of the Lean that carries the most theorems.

**In:** a builder term, transported as a `RawProgram`, as JSON. **Out:** one
observation record:

```
{ "refused": { "guard": "<one of four>", "n": <Nat|null>,      -- compared
               "pos": [l,c], "excerpt": "...", "message": "..." } }  -- oracle-only
| { "level": "...", "size": n, "askNodes": n,
    "codes": [...] | null, "shapes": [...] | null, "asks": n | null,
    "costSummary": { "minFold": ..., "maxFold": ..., "paths": n },
    "blockAsks": n, "fnAsks": [ [name, n] ],
    "worlds": [ { "world": <WorldSpec>, "trace": [Event],
                  "billFresh": ..., "billMemo": ... } ] }
| { "timeout": { "ms": n } }
```

Four changes from the draft's record, each with its reason:

- **`value` is deleted.** Every program is a `Plan [] Unit` (`Check.lean:949`), so
  `Dlg.run ω (denote p γ)` is always `()`; `reportJson` already hardcodes
  `("value", Json.str "()")` (`Mcp.lean:1201`). It is a comparand that costs harness
  code and can never carry a divergence. Deleting it is a *strengthening* of the
  design's honesty, because it says out loud that **the trace carries the entire
  observation**.
- **The refusal record splits** into a compared part (`guard`, and for
  `maxQuestions` the computed `n`, which both sides produce) and an oracle-only
  diagnostic part (`pos`, `excerpt`, `message`). Under D10 the Haskell side has no
  source text at all, so `Pos` and `excerpt` (`Syntax.lean:97`, `:101`) are
  functions of characters it never had. See §3.6.
- **`codes`/`shapes`/`asks` are nullable and usually null**: all three return `none`
  at `case` and `dyn` (`Cost.lean:308–309`, `:326–327`, `:341–342`), so on any
  `branch`-level program — which includes `example/harden.wf`, the flagship, and
  every program with an `if`, a `case` or a `revising` — they carry nothing. They
  are pipeline-only comparands and are labelled as such.
- **`timeout` is a third alternative of the record** (D13), not an error.

`Event = ⟨c, q, a⟩` and `Trace = List Event` are first-order and carry
`DecidableEq` (`Dlg.lean:112`, `:124`; `Dsl.lean:59`), and `Event.toSigma`
(`Dsl.lean:50–61`) is the Σ-shape to serialize — which is what makes the comparison
a comparison rather than a normalization exercise. Note that this is **not** what
the MCP server emits: `reportJson`'s `"replay"` is `Trace.render`, a string list
(§1.3).

Never on the wire: a `Plan`, a `Dlg`, an `Ω`, a `Table` containing anything but
data. Never on the *generated* path: `.wf` text (D10 — the parser is not shipping,
so generating text tests a component that is not in production). Outside the
boundary entirely: the import walk. `RawProgram` is the post-import-walk object, so
`parseProgramWith`, `qualifyPrimer` and module resolution are Lean-only under D10;
`example/library.wf` and `example/harden-imported.wf` enter the corpus walked once
and frozen as a single `RawProgram` each.

### 3.2 The oracle (D4)

A new `[[lean_exe]] conformance-oracle` in `lakefile.toml`, ~150–250 lines,
reusing `Rpc.lean`'s framing and `Explain.costSummary` (`Explain.lean:445`). Its
import list is the whole design: `Agentic.Core.Dsl`, `Cost`, `Denote`, `Report` —
**and not `Agentic.Core.DslFlagship`**, which `lakefile.toml:13` documents at ~6
minutes and several gigabytes. `Agentic.Core.Dsl` is ~1.5 s and `agent-cat` cold is
~6 s (`lakefile.toml:24–25`) — *above an already-built Mathlib*; §3.9 states the
real precondition.

It does **not** reuse `reportJson`. Per §1.3, that function emits arrivals and a
pretty-printer's string list, not the structured `Trace` the record needs; the
oracle emits `Event.toSigma` data directly.

Three request kinds:

1. **`{"program": <RawProgram>, "worlds": [<WorldSpec>]}`** → the observation record
   of §3.1.
2. **`{"decode": {"code": c, "text": s}}` → `answer | null`, plus `norm`, `words`,
   `decodeVerdict` and the report-side `sayAnswer`** (D12; `Exec.lean:98`, `:120`,
   `:240`, `:273`). This is the cheapest high-yield item in the whole design: it
   costs no `Plan` on either side, and it is the only Tier-0 coverage of the surface
   this page ranks first for divergence risk. The hazard is concrete —
   `Exec.norm s = s.trimAscii.toString.toLower` is **ASCII-only** in Lean where
   Haskell's `toLower` is Unicode — and on a `RawProgram`-in/world-out boundary the
   surface is *never otherwise reached*, because answers come from `ω` and
   `Plan.trace ω p Env.nil` never calls `Decode`. The frozen Tier-0 vector table
   must include, at minimum: ASCII/Unicode case pairs (`İ`, `ß`, `Σ`/`ς`, Turkish
   dotless `ı`), non-breaking space, CRLF, leading and trailing blank lines, the
   empty string, and multi-word approve (`decodeVerdict_ne_approve_of_two`,
   `Exec.lean:428`).
3. **`{"ping": ...}`** → liveness, so a hung request is distinguishable from a dead
   process under D13.

**The refusal classification lives here and only here (D7).** `CheckError` is
`⟨pos, message, excerpt⟩` with no classification field (`Dsl/Syntax.lean:95–102`);
adding one would edit `Syntax.lean` and every `.error ⟨…⟩` literal in `Check.lean`
and `Parse.lean` — **including literals inside proved theorems**, e.g.
`check_panel_nil` pins `.error ⟨ppos, "a panel needs at least one member", "panel"⟩`
on the nose (`Check.lean:734–740`), and `test/DslSmoke.lean`'s refusal table pins
messages byte-for-byte. So the code is a **total function from the message text to a
small closed enum, written in the oracle**, one file, no proof touched, no
`CheckError` change. It is the oracle's artifact, not the checker's, and if the
checker's wording changes the oracle's classifier is what needs updating — a
one-line edit in a test-only executable, caught by the frozen corpus on the same
commit.

The oracle needs `FromJson`/`ToJson` for `RawBlock`/`RawFn`/`RawProgram` —
derivable, and additive: **no file under `Agentic/Core` that carries a proof is
touched.** This matters for the review story: the oracle cannot break a theorem
because it does not edit anything a theorem is about.

**D13's budget.** Each request carries a wall-clock ceiling; on expiry the oracle
answers `{"timeout": {"ms": n}}` and the harness records an *asymmetry*, not a
failure. §1.4 explains why this is necessary rather than defensive: `Env.consBy`'s
strictness artifact means the two implementations genuinely have different
asymptotics, and without this rule the first `n = 24` program in the corpus turns
CI red for a reason that is not a divergence.

Precedent note for the ledger: Cardano imports its extracted Agda
(`import qualified MAlonzo.Code.Ledger.Core.Foreign.API as Agda`) **in
`cardano-ledger-conformance`, not in the node**. The executable spec is a test
dependency and only ever a test dependency. That is D4 exactly.

### 3.3 The mock agent

`Ω = (c : Code) → Q c → El c`. `test/DslSmoke.lean:765` already builds worlds this
way. Three consequences make this the easy part:

1. **A world is a function, not a script.** No history, no state, no "next
   answer." Determinism and "the same question twice is the same answer" are
   consequences of the *type* (`Question.lean`, §3 q1), not of harness discipline.
2. **Therefore the world must be specified as data**, not serialized as a
   function. A small closed `WorldSpec` DSL shared by both sides:
   `Echo | Const v | ByDraw | ByPromptPrefix [(Text, El c)] | Approve | Object [Text]`,
   plus a default per code. Ten combinators cover the entire existing pin suite —
   `DslSmoke`'s own worlds are exactly these shapes (`fun q => "draw" ++ toString q.draw`,
   `fun q => q.prompt == "is it ready now?"`, `fun _ => Verdict.object ["too long"]`).
3. **`Q` carries scope and draw**, so a world keyed on `q.draw` distinguishes
   resamplings. `semSrc6`/`semSrc7` in `DslSmoke.lean` already pin the two hard
   cases — two draws are two questions; a `define`-holed prompt is the same event
   in disagreeing worlds — and they are the highest-value seeds in the corpus.

### 3.4 Generators, ranked — reordered by D5

The draft ranked these the other way round. Under D5 the ranking follows from the
boundary: only a term the *builder* produced has a `Plan` on the Haskell side, so
only (b) can drive the full observation record.

**(b) Generate via the Haskell typed builder. — Primary.** If the builder makes
ill-formed terms unrepresentable, `Arbitrary` over the builder's types yields only
well-formed programs for free, and each one comes with both halves of the property:
a printed `RawProgram` for the oracle and a native `Plan` for the Haskell. Cheapest
source of deep, weird-but-valid programs, and the only source that exercises
`trace`, the bills and `costSummary`. Blind spot: it will never generate an
over-`maxQuestions` or over-`maxRevisions` program by accident, because nothing in
the types stops it — hence (a).

**(a) Generate `Raw` in Haskell, backwards from the typing rules. — Refusal path
only.** Naive random `Raw` is ~all refusals (unbound names, kind mismatches). Under
D11 a randomly generated `Raw` has **no Haskell `Plan`**, so this generator cannot
produce the full record; its comparands are exactly the ones the Haskell can compute
from `Raw` alone — the refusal boolean, the four guard identities (§3.6 A) and the
`blockAsks`/`bodyAsks`/`rhsAsks` counts (`Check.lean:877–907`). That is a narrower
job than the draft assigned it, and still a real one: it is the half of the refusal
surface the builder cannot reach. Follow Pałka et al.
([AST 2011](https://dl.acm.org/doi/10.1145/1982595.1982615)): pick a target
`Ctx`/`Bindings`, choose a constructor whose `checkBlock` clause can succeed there,
recurse on the premises. `Check.lean:547` is a readable spec of the rules to invert;
the `Bindings`/`Binding.at?`/`Bindings.push` triple (`:67–106`) is the environment
discipline to thread. Note the asymmetry it introduces and do not paper over it:
for programs from (a), a Lean `.ok` against a Haskell "my four guards pass" is
agreement about a boolean, not about a plan.

**(c) The curated corpus. — Not optional.** `example/{harden,hello,library,ill-typed,harden-imported}.wf`,
the ~19 `semSrc*` strings and the refusal table in `DslSmoke.lean`, converted once
to frozen JSON `Raw`. The Sail number is the argument: on the RISC-V C emulator,
the *handwritten* suite reached 73% line / 64% branch while Sail-generated random
tests reached **49% / 30%**, the shortfall concentrated in exactly the constructs
the generator did not know to build. Random generation underperforms curated
cases and does not replace them. (§5.2c presses this figure into an argument for
dropping the generators entirely, and is answered there.)

Under D5, (c) runs in the *opposite* direction from (a) and (b), and that is its
second value: a curated case starts as hand-written `.wf`, is parsed by Lean into
`Raw`, is frozen — and is then rebuilt through the **Haskell builder** so that the
builder's printed `Raw` can be checked against the frozen one. That is the only
place on the page where the Raw printer of §3.1 is checked against anything, and it
is why (c) is "not optional" in a stronger sense than the draft meant. The two
importing examples (`library.wf`, `harden-imported.wf`) are walked once and frozen
as a single `RawProgram` each, since the import walk is outside the boundary (§3.1)
and `importRefusal` puts it outside the MCP surface too (§1.3).

And the discipline for (c), inherited verbatim from `DslSmoke.lean:735–741`:
expectations are "stated independently of the implementation — by the discovery
pass, from the grammar's rules — and is NOT regenerated from observed output, so a
failure here is a bug or a wrong reading of the rules, never a baseline to
refresh."

Also build, because the precedents say you will regret not having it: a
**generator-termination property** (Cardano's `generatesWithin`) — backwards-from-rules
generators over a language with functions, calls and bounded revisions can blow
up, and you want that as a red test rather than a hung CI job.

### 3.5 Comparands, cheapest first

Compare **projections in order**, so a failure names its own layer. The column on
the right says which generator can produce the comparand at all (§3.4):

| # | Comparand | Available from |
|---|---|---|
| 1 | **Refused or not** — a boolean, first | (a) and (b) |
| 2 | **Refusal identity** — the oracle's guard code (§3.6), plus the computed `n` for `maxQuestions`. `pos`/`excerpt`/`message` are oracle-only and **not compared** | (a) and (b) |
| 3 | **Raw-level ask counts** — `Check.blockAsks`/`bodyAsks`/`rhsAsks` (`Check.lean:877–907`), folds over raw syntax against a name→asks table, needing **no `Plan` on either side**. The highest signal per unit of harness in the whole design, and the only §3.5 item week one can honestly reach | (a) and (b) |
| 4 | **`Decode`/`norm`/`words`/`decodeVerdict`/`sayAnswer`** (D12), against a frozen vector table | neither — its own request kind |
| 5 | **`Plan`-level static folds** — `Level.level`, `Plan.size`/`askNodes` (`Explain.lean:140`, `:155`); and `Cost.codes` (`:304`), `shapes` (`:321`), `asks` (`:336`), which are `none` above `pipeline` and therefore **null on most of the interesting corpus** | (b) only |
| 6 | **`Plan.trace ω p Env.nil`** (`Denote.lean:109`) per world, compared event-by-event with the index of first divergence in the message. **The trace is the whole observation** | (b) only |
| 7 | **`billFresh tick` / `billMemo tick`** (`Cost.lean:166`, `:176`) | (b) only |
| 8 | **`costSummary`** — `(minFold, maxFold, paths)` (`Explain.lean:445`) | (b) only |

The draft listed **the value** — `Dlg.run ω (denote p γ)` — as a comparand. It is
deleted (§3.1): every program is `Plan [] Unit`, so it is always `()`.

**The dedup direction, corrected — the draft had it backwards and the guidance it
derived pointed the implementer at the bug.** `billMemo price t =
billOfKeys price ((t.map Event.key).dedup)` (`Cost.lean:176`), and Mathlib's
`List.dedup` "removes duplicates from `l` (**taking only the last occurrence**)",
with the worked example `dedup [1, 0, 2, 2, 1] = [0, 2, 1]`
(`Mathlib/Data/List/Defs.lean:242–248`; `dedup` is `pwFilter (· ≠ ·)`). Haskell's
`Data.List.nub` is exactly the keeps-**first** function, so the draft's sentence —
"`List.dedup` keeps the first occurrence … a Haskell `nub`-that-keeps-last gives a
different answer" — instructed the implementer to write the diverging version. The
Haskell equivalent is **`reverse . nubBy (==) . reverse`**, not `nub`.

**D8, re-founded on traces rather than bills.** The rule "no normalization in the
comparison" is correct, but its home is comparand 6, not 7:

- **Traces.** `Plan.trace` is the free monoid on events (`Dlg.lean:112`, `:124`) and
  its order *is* the observation. No sorting, no `nub`-to-`Set`, ever. A
  Cardano-style `SpecNormalize` here would erase the divergence class the suite
  exists to find.
- **Bills.** Say the honest thing: **at every price in this repo the dedup order is
  currently unobservable.** `tick` (`Cost.lean:258`) and `byVendor` (`:484`) both
  land in `Multiplicative ℕ`, which is commutative, so `billOfKeys` over any
  permutation of the same key set gives the same answer. The no-normalization rule
  for bills is a **guard against a future non-commutative price**, not a live
  divergence class — and the implementer still owes the correct
  `reverse . nubBy (==) . reverse`, because the day a non-commutative price lands,
  the divergence is silent. The draft cited `billMemo_not_monoid_hom`
  (`Cost.lean:276`) in support of this; that theorem is about `t ++ t` versus
  `t * t` — memoization not distributing over concatenation — and proves a different
  thing. The citation is removed from this argument and kept where it belongs, §4.
- **Panels.** `billFresh_perm` requires `CommMonoid` (`Cost.lean:239`), and at
  `tick` the carrier *is* commutative — so a panel-order divergence is **invisible
  in the bill and visible in the trace**. Compare traces at panels, not bills.

**The most likely real bug, renominated.** The draft nominated `checkFnsList`'s
memoized ask count. **That is not a bug.** `n = bodyAsks acc f.body`
(`Check.lean:913–923`) is computed against a table each of whose entries already
holds its own transitive count computed the same way — a correct dynamic program
over a stratified table, not an approximation, so a Haskell that recomputes
transitively gets the same number. The one branch that could diverge, `rhsAsks`'s
`none => 0` for an unknown callee (`:881–884`), fires only on a forward call, and
every forward call is refused as "no function answers to this name" (`:421`, `:600`,
`:802`) before the count is ever read.

The genuine hazard in the same code is different and sharper. **`Fns` is a `List`
and `Fns.find?` returns the *first* entry with a given name** (`Check.lean:305–309`,
`List.find? (fun f => f.name == x) fns`), and **nothing in `checkFnsList` or
`checkProgram` refuses two `function f` declarations** — verified by reading both
(`:913–923`, `:949–964`): there is no nodup check anywhere in the file. A Haskell
keyed on `Map.fromList` or `Map.insert`, which are last-wins, therefore resolves
every call to the wrong body, silently, with a well-typed program on both sides.
It is a one-line corpus vector and the suite would find it on day five. Filed as a
repo finding too — `acat-dup-function-check-gap-kys`: either refuse duplicates in
`checkFnsList` or document first-wins as intended.

### 3.6 Refusal parity: four guards, not thirty (D7)

Of ~34 `.error` sites in `Check.lean`, D10 and a typed builder remove most.
Sorted honestly:

**A — genuinely term-level. This is the whole refusal-parity suite.**

| Line | Refusal | Note |
|---|---|---|
| `Check.lean:437` | "a panel needs at least one member" | pinned universally at `:730–737` for **every** table and scope. Eliminable if Haskell uses `NonEmpty`; otherwise must agree |
| `:519`, `:614–616`, `:955` | `maxRevisions = 64` | a raw `Nat` bound; no type prevents it. **The compared part is the guard identity only.** `overRevised` (`:927–939`) scans raw syntax, main only, in reading order, and runs *before* the question count so the diagnosis lands at the revising's own line — that ordering is observable **only in `pos`**, which the Haskell side cannot produce under D10, so it is a **Lean-only property with no Haskell counterpart**, not a comparand |
| `:874`, `:917–919`, `:960–962` | `maxQuestions = 4096`, enforced **per function** then **whole-program** | compared as guard identity **plus the computed `n`**, which both sides produce from `blockAsks`/`bodyAsks` over `Raw` alone. The graft arithmetic at `:900–903` — `(n+1) * rhsAsks rev + n * rhsAsks am + (n+1) * (blockAsks st + blockAsks un)` — is the subtlest formula in the file and the highest-value differential target on the page |
| `:324` | `askGuard` — "`served by` names the model that serves a model addressee" | a shape constraint on `RawAsk`; eliminable by putting the served-by model inside `Addressee.model` |

**B — term-level only if the builder is loosely typed**; normally compile errors:
`:139`, `:369/:373/:379`, `:395/:397` (arity, both at position `⟨0,0⟩` and held
apart by theorems at `:405/:412`), `:445/:453`, `:582/:832`, `:596/:798`, `:629`,
`:671`, `:687`, `:849`.

**C — artifacts of the string surface, no Haskell counterpart:** `:114`
(no shadowing — a rule about *names*; a HOAS builder has none), `:274/:777` (kind
inference), `:421/:600/:802` (unknown function name — a Haskell function is a
value), `:555`, `:621`, `:862`, `:704/:718` (the `Pend` discipline). **(C) is
where design work pays**: `:704/:718` vanish entirely if the Haskell `revising`
combinator returns a `Result` value and `caseResult` is an ordinary function on
it. Three refusals disappear rather than being duplicated.

**What is compared, and where the code comes from.** Cardano gave up here — its
`OpaqueErrorString` "behaves like unit in comparisons" and `checkConformance`
matches `(Left _, Left _) -> pure ()`. agent-cat should not: four guards is small
enough to compare exactly. But the draft's "compare a *code*" collided with §3.2's
promise that the oracle touches no file a theorem is about, because **`CheckError`
has no code**: it is `⟨pos, message, excerpt⟩` (`Dsl/Syntax.lean:95–102`), and
adding a field would edit `Syntax.lean` plus every `.error ⟨…⟩` literal in
`Check.lean` and `Parse.lean` — including literals pinned inside theorems, such as
`check_panel_nil`'s `.error ⟨ppos, "a panel needs at least one member", "panel"⟩`
(`Check.lean:734–740`), and `test/DslSmoke.lean`'s byte-for-byte refusal table.

D7 resolves it the only way that keeps both promises: **the code is a classification
defined in the oracle** — a total function from the message text to a closed
four-element enum — and it is the *oracle's* artifact, not the checker's. One file,
no proof touched. The messages stay pinned exactly where they already are.

And the split, stated once so §3.1's record reads correctly:

| Field | Compared? | Why |
|---|---|---|
| guard identity (the enum) | **yes** | both sides have it: the Haskell's four guards, the oracle's classifier |
| `n`, for `maxQuestions` | **yes** | both sides compute it from `Raw` via `blockAsks`/`bodyAsks` |
| `pos` | no — oracle-only | a function of written characters; under D10 the Haskell has no source text |
| `excerpt` | no — oracle-only | same |
| `message` | no — oracle-only | recorded for the diff, never asserted |

### 3.7 Shrinking and the corpus

Shrink **on the builder term** for cases from generator (b), and on `Raw` for cases
from generator (a) — never on text — and shrink **toward well-formedness**: plain
`genericShrink` produces mostly-refused terms and hands you a refusal as the minimal
counterexample to a trace divergence. Under D5 the distinction matters, because only
a builder term still has a `Plan` on the Haskell side after shrinking; a shrunk
`Raw` that the builder cannot express drops back to the refusal-path comparands.
Practical scheme: (i) structural shrinks that preserve checkability — drop a
trailing statement, replace a block with `.empty`, collapse an
`ifFlag`/`caseVerdict` to one arm, decrease a revising bound, drop a panel to one
member, drop a function and its calls; (ii) re-run the oracle's check after each
shrink and reject shrinks that turn `.ok` into `.error` *unless* the original
failure was itself a refusal-parity failure; (iii) shrink the **world last** —
replacing `ByPromptPrefix` with `Const` usually preserves the divergence and makes
it readable; (iv) never shrink across a `timeout` observation (D13) — a timeout is
not a divergence and shrinking toward it wastes the budget.

Then **freeze**: append the shrunk `(RawProgram, WorldSpec)` plus the oracle's
observation to the committed corpus. Cardano's equivalent is
`CONFORMANCE_CBOR_DUMP_PATH` → `dumpCbor`; yours is a JSON file in git. And per
§3.4's discipline: the corpus is never regenerated wholesale from output. A
frozen vector changes only when someone writes down why the meaning changed.

There is precedent for the frozen-term technique in this repo already:
`flagshipRaw` (`DslFlagship.lean:98`) is a hand-frozen `Raw`, produced by the
parser and then pinned, with `parseProgramWith [] [] flagshipSource = .ok flagshipProgram`
checked by `decide`. The exchange format for the corpus is therefore already
designed; it needs a JSON codec instead of `Repr`.

Failure output must be a structured diff (Cardano's `diffConformance` with
coloured `Impl:`/`Agda:` annotations). A bare `assertEqual` on a `Trace` is
unreadable and will be ignored.

### 3.8 Where it lives

| Artifact | Home | Why |
|---|---|---|
| `conformance-oracle` (`lean_exe`) | **agent-cat**, new target in `lakefile.toml` | it is a view of the spec; it must move when the spec moves |
| Raw/observation JSON schema | **agent-cat**, `doc/conformance-schema.md` + the Lean codec | one owner for the format, and it is the spec's format |
| Frozen corpus (`*.json`) | **agent-cat**, `test/corpus/` | the corpus is a spec artifact. Versioned with the theorems it samples, reviewable in the same PR that changes a meaning |
| Generators, shrinkers, comparison, CI | **the Haskell repo**, `test/conformance/` | it is a Haskell test suite; it depends on Haskell types and `Arbitrary` instances |

**Not a third repo.** A conformance repo depending on both would need a
lockstep-version dance for a suite that has exactly two consumers.

### 3.9 CI shape, and the one-build rule (D6)

The hard constraint is machine-wide: one Lean build at a time. The design must
therefore make Lean builds *rare*, not merely serialized.

**Tier 0 — frozen vectors. Runs on every Haskell commit. Requires no Lean at
all.** The committed corpus is read as data; the Haskell implementation is run
against it; observations are compared. This is the whole point of freezing: the
oracle's output is a *build artifact of the spec*, produced when the spec changes,
not when the Haskell changes. Tier 0 has no Lean dependency, no toolchain pin, and
no build-lock contention. It should be the gate on every PR.

**Tier 1 — live differential. Runs where the oracle binary exists.** Generated
programs, both implementations, shrink on mismatch, append to the corpus. Needs
`conformance-oracle` as a **prebuilt binary**, never a `lake build` inside the
test run. Two ways to get it, both compatible with the rule:

- a single serialized CI lane (a job-level mutex or a self-hosted runner
  concurrency group of one) that builds the oracle when
  `hash(lean-toolchain, Agentic/**, lakefile.toml)` changes, and publishes the
  binary as an artifact / Nix store path;
- locally, the binary already in `.lake/build/bin`, which is how sweep 2 ran its
  measurements without building anything.

**Tier 1's real precondition, which "seconds-scale, i.e. CI-shaped" omitted:
Mathlib.** The six seconds quoted from `lakefile.toml:24–25` is explicitly "from
cold **for the DSL layer**" — that is, above an already-built Mathlib.
`lakefile.toml:34–35` requires mathlib from git at `v4.30.0`, and the link line
confirms the weight: `.lake/build/bin/agent-cat.rsp` lists 734 objects, 456 of them
Mathlib. So the lane needs **a warm Mathlib cache (`lake exe cache get`) or a pinned
Nix store path**, and a cache miss costs gigabytes or hours — precisely the case a
toolchain bump produces, which is the case Tier 1 exists to survive. Someone owns
that: the serialized lane's first step is cache acquisition, and if it fails the
lane must fail loudly rather than fall back to building. The correct and useful part
of the original claim survives intact — **skipping `DslFlagship` avoids the six
minutes and the gigabytes** (`lakefile.toml:13`, `:95`), and that is what keeps the
oracle's own build in the seconds once Mathlib is present.

For scale: `lakefile.toml` already carries **nine** `lean_exe` targets — `acp_smoke`,
`exec_smoke`, `harden_demo`, `dsl_smoke`, `workflow_mcp`, `mcp_smoke`,
`mcp_client_smoke`, `agent-cat`, `cli_smoke` (`:59`, `:70`, `:82`, `:98`, `:111`,
`:125`, `:140`, `:158`, `:170`). A tenth is not a new kind of thing.

The Haskell suite must **fail loudly with "oracle binary not found; Tier 1
skipped"** rather than silently degrading to Tier 0 — a green suite that quietly
tested nothing is the failure mode this whole page exists to avoid.

**Cadence.** Tier 0 on every commit. Tier 1 nightly and on any PR touching
`Agentic/Core/**` or the Haskell semantic core. Corpus additions from Tier 1 land
as ordinary reviewed commits, not as bot pushes.

Four repo hygiene items to fix while here, independent of route. The last two were
found by the adversarial pass over this page and are filed, not fixed here:

- **`flake.nix:16–20` is factually wrong.** It says "there is deliberately no
  lean-toolchain file for elan to consult" and "The package is self-contained (no
  Mathlib)". `lean-toolchain` exists and reads `leanprover/lean4:v4.30.0`;
  `lakefile.toml:34–35` requires mathlib from git. Anyone attempting the packaging
  will be misled.
- **`Settings.maxMessages = 1000000`** (`Mcp.lean:696`) is a ceiling any
  long-lived server hits eventually. It needs supervision, or a note that it does.
- **`heardMatchesReplay` is `false` on any run with a memo hit** (§1.3), and
  `partialBillJson`'s docstring (`Mcp.lean:1229`) claims the mid-flight and final
  bills are "the same function" while one folds the heard list and the other folds
  the replay. Filed as `acat-heard-matches-replay-memo-v55`.
- **Duplicate `function f` declarations are not refused**, and `Fns.find?` resolves
  the call to the *first* (`Check.lean:305–309`; no nodup check in `checkFnsList`
  `:913–923` or `checkProgram` `:949–964`). Either refuse duplicates or document
  first-wins as intended. Filed as `acat-dup-function-check-gap-kys`. Until then the
  Haskell must match first-wins deliberately rather than by using a `Map`.

### 3.10 The coverage tier (D9 — recorded, deferred)

**First, the correction, because the draft sold the wrong thing.** The draft built
this tier on `certify` (`Certify.lean:166`, `certify_sound` `:178`) and claimed
"every accepted run carries a machine-checked certificate rather than a sampled
coincidence." **That is false as written: the certificate is `rfl`.**
`Dsl.checkProgram` returns `Plan [] Unit` (`Check.lean:949`), and

```lean
theorem certify_unit_vacuous (p : Plan [] Unit) (t : Table) :
    certify p t () = true := rfl        -- Report.lean:247, axiom-pinned :295–297
```

so `certify` is **constant-true for every program this language can write, at every
table, including the empty one**. The repo says so on the wire: `reportJson`'s
certificate object carries `("vacuous", Json.bool true)` and a `note` reading
"certified is `certify p t ()`, and on a closed workflow … it is true for every
table, the empty one included. **The field that carries content is `covered`**"
(`Mcp.lean:1209–1222`); `test/McpSmoke.lean:304` pins `vacuous = true`; and
`certify_unit_vacuous` is named twice in the very file the draft read
(`Mcp.lean:75`, `:577`). `certify` regains content only for `Plan [] A` with
`A ≠ Unit`, which the DSL never produces. **It is not an upgrade over anything and
must not be offered as one.**

**The real per-run channel is coverage**, and it is already computed, already
reported, and already proved:

```lean
def Plan.coveredB {A} (t : Table) (p : Plan [] A) : Bool :=
  Trace.coveredB t (Plan.trace (worldOf t) p Env.nil)          -- Report.lean:163

theorem Mcp.reporterOf_warrants (p : Plan [] Unit) (t : Table)
    (hcov : (reporterOf p t).covered = true) (ω : Ω) (hω : Extends ω t) :
    Plan.run ω p Env.nil = (reporterOf p t).value ∧
      Plan.trace ω p Env.nil = (reporterOf p t).transcript    -- Mcp.lean:585
```

The strength of the two claims is the whole difference. `certify_sound` says
***some*** world agrees. `reporterOf_warrants` says ***every*** world agreeing with
this log assigns the plan this value and this transcript — which is the statement a
consumer of a workflow's output actually wants, and it is discharged by coverage
alone, `certify`'s hypothesis being free (`Mcp.lean:589`, `RunReport.warrants`
`Report.lean:656`). `RunReport.of` computes `covered := Plan.coveredB table p`
(`Report.lean:633`) and `of_covered_eq_true_iff` (`:644`) says the reported field is
the property.

*That* is the translation-validation channel in seL4's sense
([Sewell, Myreen & Klein, PLDI '13](https://dl.acm.org/doi/10.1145/2499370.2462183)):
instead of proving the Haskell correct once, mechanically validate this particular
run. If the Haskell runner emits its `Table` and its transcript and the Lean oracle
returns `covered = true` together with a transcript equal to the Haskell's, the run
carries a machine-checked statement about **every** world consistent with its log —
not a sample, and not a `rfl`.

Deferred for one reason, stated plainly: **using it in production puts the Lean
process back in production**, which is the thing D1 buys. Its honest home is (a)
inside the harness, where `covered` and the replayed transcript are two more fields
of the record and cost nothing new, and (b) as an optional `--covered` mode for
staging or high-stakes runs, where 132 ms and 100 MB on disk are acceptable in
exchange for a per-run warrant. Revisit when the Haskell runner has real users and
someone asks what the workflow's output is worth.

---

## 4. What the suite can never establish

Testing samples; the theorems quantify. Everything of the form ∀ω, ∀p, ∀Γ stays
Lean-only, and there are **867** of them (`grep -rhoE '^ *(theorem|lemma) ' Agentic --include='*.lean' | wc -l`,
per `haskell-question.md` §0.3). The load-bearing examples:

- **∀ ω.** Traces are compared at finitely many worlds. `DslFlagship.lean:411+`
  already says this about its own four named worlds: the universally quantified
  form "needs the `Plan.Denotes` route rather than reduction." A property suite is
  strictly weaker than four *proved* worlds, which is itself strictly weaker
  than ∀ω.
- **Algebraic laws.** `billFresh_append` (`Cost.lean:202`), `billMemo_dvd_billFresh`
  (`:211`), `billMemo_le_billFresh` (`:219`), `billFresh_perm` (`:239`),
  `billFresh_panel_perm` (`:247` — the scheduling licence), and above all
  `billMemo_not_monoid_hom` (`:276`), which is a *negative* result no quantity of
  passing samples would ever justify.
- **Totality of the folds on a fragment.** `asks_isSome_of_le_pipeline` (`:358`),
  `codes_isSome_of_le_pipeline` (`:368`), `shapes_isSome_of_le_pipeline` (`:379`).
- **Refusal universals.** `Check.lean:730–737`: an empty panel is refused for
  *every* table and scope, with exactly that diagnosis.
- **Level soundness.** `Dsl.parseAndCheck_level_le`, which every tool over source
  files is built on (`Explain.lean:441`), and `Cost.bill_mem_leaves`, which
  underwrites `agent-cat run`'s check that a run's bill is a leaf of the cost tree.
- **Axiom hygiene.** `certify_sound` pinned at no axioms with `#guard_msgs` — which
  is why `native_decide` is forbidden repo-wide. No Haskell test has an axiom set
  to pin.

**And the seam D5 creates, named here rather than buried in §3.1.** Under the
inverted boundary the Haskell **emits** the `RawProgram` the oracle checks. Nothing
on either side verifies that the emitted program is the term the builder wrote. A
translation bug that maps one well-formed builder term to a *different well-formed*
`RawProgram` produces agreement about the wrong program, and the suite is green
forever. This is the price of not porting the checker (D11); it is a real hole; and
the two things that partially cover it — the asymmetry check (any oracle refusal on
a builder-produced term is by construction a translation bug) and the curated corpus
running parser→`Raw`→builder→`Raw` — catch ill-formed output and the curated cases
respectively, not well-formed-but-wrong output in general. Recorded here beside the
"same author" blind spot because it has the same character: it is a hole the suite
cannot see into, not a cost the suite pays.

**And the blind spot that matters most.** Differential testing of two artifacts by
the same author will find mistakes in either and **will not find a consistent
misunderstanding present in both** (Hughes,
[*Testing the Hard Stuff and Staying Sane*](https://www.cs.tufts.edu/~nr/cs257/archive/john-hughes/quviq-testing.pdf)).
If the Lean `blockAsks` graft formula is wrong about what the elaborator actually
builds and the Haskell copies it, the suite passes forever. The two mitigations
are the two the repo already practises: the discovery-pin discipline
(`DslSmoke.lean:735–741`), and Lean-side theorems that check two folds against
*each other* rather than against a baseline.

**How to present it.** Four rungs, three of them available here:

1. **Tested agreement.** "On N generated and M curated programs across K worlds,
   the two agree on refusal, static folds, trace, value and both bills." This is
   Cardano's claim, and Cardano settles tens of billions of dollars on it.
2. **Proved test-model soundness** (Peras' move, FUNARCH '24 §4.2): prove *in
   Lean* that whatever simplified executable model the harness runs is sound
   w.r.t. `denote`/`Plan.trace`. Converts one leg from tested to proved.
3. **Per-run *coverage*** (§3.10): `Plan.coveredB` plus `Mcp.reporterOf_warrants` —
   every world agreeing with this run's log assigns the plan this transcript. Not a
   sample. **Not** `certify`, which the draft put on this rung and which is
   `rfl` on every program this language writes (`Report.lean:247`).
4. Extraction — unavailable.

And the sentence to reuse, which the repo has already written about its own
parser (`DslFlagship.lean:411+`): *"everything downstream of the parser is proved,
and the parser itself is tested."* The Haskell version has the same shape and
deserves the same lack of hedging: **everything about the meaning is proved in
Lean; the Haskell's agreement with that meaning is tested, on a corpus that is
generated, shrunk, frozen, and never regenerated from output — and, where coverage
is checked, warranted per run rather than sampled.** With a section headed
"What is not proved" naming each gap and its actual obstacle, as
`DslFlagship.lean` already does, and as the FUNARCH report models: *"It is
possible a specification may, at some point, diverge from its implementation.
Also, the specification itself may contain errors."*

---

## 5. Recommendation

### 5.1 The recommendation

**M4, with M3 as the oracle transport.** Reimplement the semantic core in Haskell
(~1,550–1,850 loc: no parser under D10, no elaborator under D11, four refusal
guards, and `costTree` priced in); ship no Lean in production; build the conformance
harness against the **inverted boundary** of D5 — a typed-builder term transported
as a serialized `RawProgram`, observations back — served by a new
`conformance-oracle` executable; run it in two tiers so that the everyday gate needs
no Lean at all. Record **coverage** (not `certify`) as the available upgrade and do
not take it yet. Reject extraction as non-existent and FFI as a strictly worse
version of the pipe.

**The honest total is 6–10 weeks, not 3–5** (§1.5b: the harness is roughly the size
of the core and the draft priced it nowhere), and the recurring cost is dual edit
*plus* JSON-schema parity, forever.

### 5.2 The dissents worth recording

Three, in ascending order of how hard they are to answer. The first is sweep 2's own
recommendation; the other two are absent from the draft because the draft's frame —
four whole-program mechanisms — cannot express them, and both are stronger.

#### 5.2a Don't reimplement anything (sweep 2)

It is not a straw man:

> **Don't reimplement anything.** The interface exists, is tested two ways, and a
> full flagship workflow ran through it in 134.55 ms with a ~1.5 ms semantic
> workload. Recovery is a pure function of `(source, [answer])` and is *provably*
> exact — `Dlg.execM_resume` says resumption changes nothing an interpreter would
> do. The effectful runner stays entirely Haskell-owned either way; the Lean
> process answers questions about *meaning* and never performs an act
> (`Mcp.lean`'s trust boundary: "The act happens elsewhere"). So "pure Haskell"
> costs you ~1,400 lines of new unproved code, a permanent dual-edit tax on every
> semantic change, a conformance suite that can never establish what the 867
> theorems already establish, and a guaranteed class of bugs — string handling,
> memoized ask counts, dedup order — that simply cannot exist if there is only one
> implementation. In exchange it removes a dependency that is out-of-process,
> restartable, replayable and crash-isolated. That is a bad trade dressed as
> architectural purity.

**This dissent is correct about everything except the one thing that decides it.**
The dual-edit tax is real and permanent and this page does not minimize it: it is
the largest cost on the page and it does not appear in any setup estimate. But the
subprocess route makes the production system's meaning *unavailable to its own
types*. A Haskell runner that must ask a subprocess what a plan costs cannot type
a budget check, cannot make an ill-formed plan unrepresentable at the call site,
and cannot let a caller pattern-match a `Plan`. Sweep 2 sees this and draws the
right conclusion from within its own scope — "the argument for having Haskell
compute nothing semantic" — but "Haskell computes nothing semantic" is a
description of a client, not of the production system the owner decided to build.

**What would make the dissent win, stated falsifiably** — if any of these is true
in six months, reopen:

1. The semantic core changes more than roughly monthly. The dual-edit tax scales
   with churn; at high churn the subprocess dominates on cost alone.
2. Nobody outside the runner ever needs to *construct* or *inspect* a `Plan` in
   Haskell — i.e. the typed builder turns out to be used only by the runner
   itself, in which case authoring is not a real requirement and the whole
   reimplementation is serving nothing.
3. Tier 1 finds divergences at a rate that does not decay after the first month.
   A steady-state trickle of real divergences is evidence the two artifacts are
   too complex to keep in agreement by testing, and the honest response is one
   implementation rather than more tests.

#### 5.2b Split the boundary, not the codebase — **the strongest dissent on the page**

Keep Lean for *static* analysis only: parse, `checkProgram`, `level`, `costTree` —
that is, `agent-cat check` and `workflow_check`, which are **author-time, one-shot
and latency-irrelevant**, and which carry most of the 867 theorems. Give Haskell
only `denote`/`trace`/`bill`, which a typed builder makes close to trivial.

This is strong because it is *already most of the way to D11*. D11 says the Haskell
does not own the checker; 5.2b observes that if the Haskell does not own the checker,
the natural place for the checker is a Lean process the author invokes once, not a
Lean process the harness invokes and production never sees. It deletes the same
largest-and-riskiest half of the Haskell obligation, deletes `costTree` and its
`WithTop`/`WithBot` shim as well, needs no Raw printer under some framings, **and it
puts no Lean on the run path at all** — so it satisfies the owner's decision that the
runner is Haskell-owned. It is not the subprocess dissent wearing a hat: nothing in
5.2b runs Lean while a workflow executes.

**Why it is rejected.** Because the artifact the owner decided to build is a Haskell
*program*, not a Haskell runner with a Lean front end, and 5.2b relocates rather than
removes the dependency: shipping it means shipping ~100 MB of Mathlib alongside the
binary for anyone who wants to check a workflow before running it, and it makes
`agent-cat check` a different product from `agent-cat run` in packaging, platform
support and install story. It also caps the typed builder: a caller who constructs a
`Plan` in Haskell and wants to know its cost bound before running it is back to
asking a subprocess, which is the exact failure §5.2a is rejected for. The rejection
is a judgement about product shape, not about cost — **on cost, 5.2b wins.**

**Falsifiable reopen condition.** Authoring never happens outside the runner. If, at
six months, every `Plan` constructed in Haskell is constructed by the runner itself
and no downstream consumer ever inspects or budgets one, then the typed builder is
serving nobody, `checkProgram`-in-Haskell was never needed, and 5.2b is simply the
cheaper version of the same product. Reopen.

#### 5.2c Reimplement, but skip Tier 1

Build the frozen curated corpus and stop: no generators, no shrinker, no live
differential. **This page's own Sail figure is the argument against its own
generator** — on the RISC-V C emulator the handwritten suite reached 73% line / 64%
branch while Sail-generated random tests reached 49% / 30% — and §1.5b shows the
generator plus shrinker plus live oracle is the single largest unpriced line item,
roughly 1.5–2 weeks of the harness's 3–5.

**Why it is rejected.** The curated corpus is written by the same author as both
implementations, so it inherits §4's blind spot completely: it can only contain cases
someone thought of. The generator's value is not coverage percentage but *surprise* —
it is the only thing in the design that can produce a program nobody intended, and the
`blockAsks` graft formula at `Check.lean:900–903` is exactly the kind of arithmetic
that is right on every case a human writes and wrong on the fourth nesting. Sail's
numbers say generated tests are a poor *replacement* for curated ones, which §3.4(c)
already concedes; they do not say generated tests are a poor *supplement*.

**Falsifiable reopen condition.** At six months, count the divergences Tier 1 found
that the curated corpus would not have. If that number is zero — every real
divergence was also caught by a hand-written vector — then the generator is paying
1.5–2 weeks plus permanent CI time for nothing, and it should be deleted rather than
maintained. Reopen.

### 5.3 The dissent that is *not* worth recording as live

"Reimplement now, extract later." §2 kills it: extraction is not deferred work,
it is absent tooling, and nothing built under D1 brings it closer. (The draft's §5.3
disposed only of this one, which was never a live option — which is why 5.2b and
5.2c now stand where a rejection argument should be.)

---

## 6. Rejected alternatives, recorded

1. **Off-the-shelf Lean→Haskell extraction.** Does not exist, at any maturity, in
   2026. Sweep 1 searched GitHub repo + code search, Lean Zulip, arXiv,
   FRO/Peregrine. The canonical statement of intent remains the 2018 Zulip thread
   where Simon Hudon joked about not knowing "in which decade."
2. **Writing a λ□→Haskell backend for Peregrine.** Writeable — the λ□ AST already
   ships as a Haskell datatype in Peregrine's `hs-lib/`, and the Elm backend is the
   nearest sibling. Rejected: output would be untyped-λ□-shaped, `unsafeCoerce`-laden
   Haskell, which is precisely not typed-builder authoring; the Lean frontend
   carries no verification marker and is 5★ with no releases.
3. **A bespoke LCNF-level generator.** Rejected: mechanizable target is ~500 loc
   of folds; the checker and the GADT design are not mechanizable at all; the
   generator would exceed its output and pin to an API that broke at v4.30.0, the
   version this repo uses.
4. **FFI, in every variant** (static link, `libleanshared`, one-bound-thread
   queue). Rejected on §1.2's grounds, of which the sharpest is that
   one-bound-thread-serving-a-queue *is* a subprocess without the isolation, and
   that lean-rs — the only real typed Lean FFI — recommends the process boundary.
5. **A Haskell port of `Dsl/Parse.lean`.** Rejected (D10): 964 lines to reproduce
   a component that is not in production, on the highest-divergence-risk surface
   in the codebase (Lean `Char.toLower` is ASCII-only; Haskell's is Unicode).
6. **Serializing or comparing `Plan` values.** Impossible, not merely rejected:
   `Expr Γ A = Env Γ → A` (`Plan.lean:151`) makes a plan a value containing
   closures, and `Plan.Equiv` is *observational* by design (`Denote.lean` docstring).
7. **Cardano's `OpaqueErrorString` coarsening of refusal comparison.** Rejected
   (D7): correct for a ledger with a large error surface; unnecessary here, where
   the term-level refusal set is four guards. **But not by adding a code to
   `CheckError`** — that would edit `Syntax.lean:95–102` and literals pinned inside
   theorems (`Check.lean:734–740`). The enum is the oracle's, defined as a total
   function from message text to a closed set (§3.6).
8. **A `SpecNormalize`-style canonicalization before comparison.** Rejected (D8)
   for **traces**, where order is the observation and a sort would erase the
   divergence class the suite was built to find. For **bills** the rule is retained
   as a guard against a future non-commutative price, and the honest statement is
   that at `tick` and `byVendor` — every price in the repo — the carrier is
   `Multiplicative ℕ` and dedup order is unobservable today. (Normalization
   permitted, narrowly, where a comparand is genuinely a set — and each such site
   is recorded as a weakening.)
9. **A third repository for the harness.** Rejected: a lockstep-version dance for
   a suite with exactly two consumers.
10. **Generating `.wf` text as the primary generator.** Rejected: tests a
    component that is not shipping. The *existing* `.wf` corpus is kept, converted
    once, frozen (§3.4c).
11. **Restructuring the Lean to suit an agda2hs-style extractor.** Rejected:
    index erasure would delete the well-scopedness that is the point of `Plan`,
    higher-rank `Cont` is out of scope for such tools, every Mathlib carrier would
    need a mirrored prelude — and it contradicts the standing decision that the
    Lean is retained *in full* as the proven specification.
12. **A Haskell port of `Dsl/Check.lean` — the symmetric `RawProgram`-in
    boundary.** This is the alternative to D5/D11 and it is the one real fork on the
    page, so it is priced rather than waved off: ~630 loc of `Check.lean`, plus
    `Bindings`/`Binding.at?`/`Bindings.push` (`:67–106`), `bindKind`/`useKindB` kind
    inference, `paramBindings` (`:750`) whose result type is computed by a `foldl`
    over a *runtime* list, and all 36 `.error` sites — call it **+700–900 loc**, so
    ~2,250–2,750 total, roughly doubling the core and voiding D7's "four guards" in
    favour of thirty-plus refusal-parity obligations. What it buys is real: a
    symmetric boundary, two-sided refusal parity including `pos` if the Haskell also
    had a parser (it does not, D10), generator (a) restored to primary, and **no Raw
    printer seam**. Rejected because it duplicates the densest theorem-carrying file
    in the repo for a component that is not on the run path, and because §5.2b is a
    better answer to the same question: if the checker is not worth porting, the
    honest move is to notice where it *should* live, not to make the Haskell a worse
    copy of it.
13. **Comparing the value** (`Dlg.run ω (denote p γ)`). Rejected as vacuous, not as
    expensive: every program is a `Plan [] Unit` (`Check.lean:949`) and `reportJson`
    hardcodes `("value", Json.str "()")` (`Mcp.lean:1201`). The trace carries the
    entire observation.
14. **`certify` as the third tier.** Rejected as *vacuous*, which is stronger than
    rejected as costly: `certify_unit_vacuous` (`Report.lean:247`) makes it `rfl` on
    every program this language writes. Replaced by coverage (D9, §3.10).
15. **Citing `heardMatchesReplay` as a self-check on the server's bookkeeping.**
    Rejected: it is `false` by construction on any run with a memo hit (§1.3), and
    the repo's only pinned run has `fresh = memo`, so it has never been exercised.

---

## 7. Week one

The smallest thing that de-risks the format before any semantics is written. Five
days, and it touches no file that carries a proof.

**The correction that reshapes it.** The draft's day 4–5 promised "the static folds
only — `codes`, `shapes`, `asks`, `level`, `size`, `askNodes`. No `Plan`, no
`denote`, no world, no bill." All six are **`Plan`-indexed**, so that day secretly
required the `Plan` GADT *and* an elaborator — the two things the same section
explicitly defers to weeks two through five. And three of the six (`codes`,
`shapes`, `asks`) return `none` at `case` and `dyn` (`Cost.lean:308–309`,
`:326–327`, `:341–342`), so on `example/harden.wf`, the flagship, and every program
containing an `if`, a `case` or a `revising`, they are constantly `null`. Week one
is therefore rescoped to what is genuinely **Raw-level on both sides**.

| Day | Deliverable | Where |
|---|---|---|
| 1–2 | `[[lean_exe]] conformance-oracle` — line-delimited JSON on stdin/stdout, request kinds 1 and 2 (§3.2), reusing `Rpc.lean` framing and `Explain.costSummary`, emitting `Trace` as `Event.toSigma` **data** and never `Trace.render`. `FromJson`/`ToJson` for `RawBlock`/`RawFn`/`RawProgram` (derived). The refusal classifier: message text → four-element enum, **in the oracle**. Imports `Agentic.Core.{Dsl,Cost,Denote,Report}`, **not `DslFlagship`** | agent-cat |
| 2 | `doc/conformance-schema.md` — the observation record of §3.1, written down once, versioned, with the compared/oracle-only split explicit | agent-cat |
| 3 | Tier-0 corpus v0: `example/*.wf` (the two importing ones walked once and frozen as single `RawProgram`s) + the ~19 `semSrc*` sources + the `DslSmoke` refusal table, run through the oracle, frozen as `test/corpus/*.json`. **Plus three vectors written for this week specifically** (below) | agent-cat |
| 4–5 | Haskell: `Raw*` types + JSON codec + **Raw-level comparands only** — (i) the refusal boolean, (ii) the four guard identities of §3.6 A with the computed `n` for `maxQuestions`, (iii) `blockAsks`/`bodyAsks`/`rhsAsks` over `Raw` against a name→asks table, and (iv) the D12 string-layer vector table (`norm`/`words`/`decodeVerdict`/`Decode`/`sayAnswer`). **No `Plan`, no GADT, no elaborator, no `denote`, no world, no bill, no `level`/`size`/`askNodes`** | Haskell repo, `test/conformance/` |

**The three vectors that make day 5 worth reaching:**

1. **Duplicate function names** — two `function f` declarations of different arity or
   different question count, one call site. `Fns.find?` is first-wins
   (`Check.lean:305–309`) and nothing refuses the duplicate; a Haskell keyed on
   `Map.fromList` is last-wins. This replaces the draft's memoized-ask-count
   nomination, which is not a bug (§3.5).
2. **`billMemo < billFresh`** — `semSrc0` (`test/DslSmoke.lean:764`), one binding
   holed three times and asked once. It settles `heardMatchesReplay`'s behaviour in
   the corpus rather than in prose (§1.3), and it is the vector that will one day
   catch a `nub`-instead-of-`reverse . nubBy (==) . reverse` dedup.
3. **The `blockAsks` graft at depth** — a `revising` at bound `n` whose body is a
   `caseResult`, exercising
   `(n+1) * rhsAsks rev + n * rhsAsks am + (n+1) * (blockAsks st + blockAsks un)`
   (`Check.lean:900–903`) at two levels of nesting. Subtlest arithmetic in the file,
   and reachable from `Raw` with no `Plan` in sight.

**Week-one definition of done:** a green Tier-0 run comparing the refusal boolean,
the four guard identities, the Raw-level ask counts and the string-layer vector
table across the whole curated corpus plus the three vectors above, with **no Lean
in the loop** — the oracle ran once on day 3 and its output is now data in git.

Why this order. These are the only comparands that exist on both sides before the
GADT lands, and two of them point at the two things this page now believes are the
most probable real divergences: the first-wins function lookup and the ASCII/Unicode
`toLower` split. So week one both proves out the boundary format *and* aims the
first test at a real target. If day 5 is red, that is the harness working on
schedule.

**Explicitly not week one:** the `Plan` GADT, `denote`, `level`/`size`/`askNodes`,
`codes`/`shapes`/`asks` (which are `null` on most of the corpus anyway), the world
DSL, `costTree`, the Raw printer, generators, shrinking, Tier 1, and any CI change.
Those are weeks two through five, and each of them is cheaper once the record format
is frozen.

---

## Appendix — citation index

**Repository** (all absolute, all read for this page):
`/Users/johnw/src/agent-cat/Agentic/Core/Plan.lean` (`Expr` :151, `Env.consBy` :85,
`case` :278, `dyn` :285, `Cont` :410, `revising` :621) ·
`Denote.lean` (`Plan.trace` :109, Mathlib import :2) ·
`Dlg.lean` (`Event` :112, `Trace` :124) ·
`Question.lean` (`Verdict` :97, `Code` :215, instances :224–260) ·
`Cost.lean` (`billFresh` :166, `billMemo` :176, laws :189–280,
`billMemo_not_monoid_hom` :276, `codes`/`shapes`/`asks` :304/:321/:336,
totality :358–397, `leaves` :631) ·
`Certify.lean` (`certify` :166, `certify_sound` :178, `runCertified` :246) ·
`Report.lean` — **the file the §3.1 observation record is a paraphrase of, absent
from the draft's index, and where finding 2 came from** (`certify_unit_vacuous` :247
+ axiom pin :295–297, `Trace.render` :518, `Trace.length_render` :522, `Table.size`
:528, `Plan.coveredB` :163 + `coveredB_eq_true_iff` :166, `RunReport` :596,
`RunReport.of` :628 + `of_covered_eq_true_iff` :644, `warrants` :656,
`billFresh`/`billMemo` at the report :665/:669, `billFresh = |transcript|` :681) ·
`World.lean` (`worldOf` :222 — `RunReport.of`'s transcript is defined through it) ·
`Exec.lean` (`Decode` :273, `Decode_eq_none` :296, decoders :98–273) ·
`Explain.lean` (`size`/`askNodes` :140/:155, `parseAndCheck_level_le` :441,
`costSummary` :445) ·
`Mcp.lean` (`certify_unit_vacuous` named :75, :577, `Dlg.Ask`/`resume`/`pending?`
:157–185, proofs :206–260, axiom pins :266–278, `answerSchema` :350,
`questionJson` :382, `reporterOf_warrants` :585–589, `Run` :597, `r.trace` :627,
`Settings` :696, `workflow_check` :850, tools :1001, `importRefusal` :1126–1134,
`runCheck` :1136, `reportJson` :1195–1226 incl. hardcoded `value` :1201 and the
certificate note :1209–1222, `partialBillJson` :1229, `deliver` :1317–1331,
`serve` :1658) ·
`Rpc.lean` (round-trip `#guard`s :129–146) ·
`Dsl/Syntax.lean` (`RawBlock` :248/:275, `RawFn` :299/:314, `RawProgram` :319/:325) ·
`Dsl/Check.lean` (`Bindings` :67–106, `Fns`/`Fns.find?` **:305–309 — first-wins**,
`askGuard` :324, empty panel :437 + universal pin :730–737, `checkBlock` :547,
`maxRevisions` :519, `paramBindings` :750, `maxQuestions` :874,
`blockAsks`/`bodyAsks`/`rhsAsks` :877–907, `checkFnsList` :913–923,
`overRevised` :927–946, `checkProgram` :949–964, unknown-function refusals
:421/:600/:802) ·
`Dsl/Parse.lean` · `DslFlagship.lean` (`flagshipRaw` :83–100, "What is not proved" :404+) ·
`test/DslSmoke.lean` (discovery-pin discipline :735–741, `evsOf` :742, `world` :765,
`semSrc0` :764, `semSrc0`–`semSrc18`, refusal table) ·
`test/McpSmoke.lean` (`fresh = memo = 6` :299–300, `vacuous = true` :304) ·
`lakefile.toml` (build-cost notes :13, :24–25, :95; mathlib require :34–35;
**nine** `lean_exe` at :59, :70, :82, :98, :111, :125, :140, :158, :170) ·
`lean-toolchain` (`leanprover/lean4:v4.30.0`) ·
`flake.nix:16–20` (the wrong comment) ·
`.lake/packages/mathlib/Mathlib/Data/List/Defs.lean:242–249`
(`dedup` = `pwFilter (· ≠ ·)`, **last occurrence**, `dedup [1,0,2,2,1] = [0,2,1]`) ·
`.lake/build/bin/agent-cat.rsp` (734 objects, 456 Mathlib) ·
`doc/research/dsl-redesign/haskell-question.md` §0.3 (26,155 lines; 867
theorems) — that page, and the rest of the redesign round, were deleted with the
`.wf` language on 2026-08-18 and are in git history.

**External:**
[Lean reference §12.4 FFI](https://lean-lang.org/doc/reference/latest/Run-Time-Code/Foreign-Function-Interface/) ·
[§12.2 Reference Counting](https://lean-lang.org/doc/reference/latest/Run-Time-Code/Reference-Counting/) ·
[Lean 4.30.0 release notes](https://lean-lang.org/doc/reference/latest/releases/v4.30.0/) ·
[Counting Immutable Beans](https://arxiv.org/pdf/1908.05647) ·
[lean4export](https://github.com/leanprover/lean4export) ·
[lean4lean](https://github.com/digama0/lean4lean) ·
[lean-to-lambdabox](https://github.com/inria-cambium/lean-to-lambdabox) ·
[Peregrine](https://peregrine-project.github.io/) ·
[Dima, extraction report 2025](https://www.normalesup.org/~sdima/2025_extraction_report.pdf) ·
[auser/lean4-prod](https://github.com/auser/lean4-prod) ·
[agda2hs](https://github.com/agda/agda2hs) ·
[hs-to-coq](https://github.com/plclub/hs-to-coq) ·
[Cogent](https://github.com/au-ts/cogent) ·
[coq#1257](https://github.com/coq/coq/issues/1257) ·
[coq#14256](https://github.com/coq/coq/issues/14256) ·
[lean-rs](https://github.com/jcreinhold/lean-rs) ·
[lean4-alloy](https://github.com/tydeu/lean4-alloy) ·
[Control.Concurrent — bound threads](https://hackage.haskell.org/package/base/docs/Control-Concurrent.html) ·
[GHC FFI users guide](https://ghc.gitlab.haskell.org/ghc/doc/users_guide/exts/ffi.html) ·
[Chapman, Bailly, Vinogradova — *Applying Continuous Formal Methods to Cardano*, FUNARCH '24](https://doi.org/10.1145/3677998.3678222) ·
[`cardano-ledger-conformance` `ExecSpecRule/Core.hs`](https://raw.githubusercontent.com/IntersectMBO/cardano-ledger/master/libs/cardano-ledger-conformance/src/Test/Cardano/Ledger/Conformance/ExecSpecRule/Core.hs) ·
[formal-ledger-specifications](https://github.com/IntersectMBO/formal-ledger-specifications) ·
[plutus-metatheory](https://github.com/input-output-hk/plutus-metatheory) ·
[sail-riscv](https://github.com/riscv/sail-riscv) ·
[Sail RISC-V status, 2025](https://lists.riscv.org/g/tech-golden-model/attachment/381/0/riscv-nasummit2025-sail-slides.pdf) ·
[Sewell, Myreen, Klein — *Translation Validation for a Verified OS Kernel*, PLDI '13](https://dl.acm.org/doi/10.1145/2499370.2462183) ·
[seL4 Proofs](https://sel4.systems/Verification/proofs.html) ·
[Hughes — *Testing the Hard Stuff and Staying Sane*](https://www.cs.tufts.edu/~nr/cs257/archive/john-hughes/quviq-testing.pdf) ·
[*Find More Bugs with QuickCheck!*](https://smallbone.se/papers/more-bugs.pdf) ·
[Pałka et al., AST 2011](https://dl.acm.org/doi/10.1145/1982595.1982615) ·
[Fetscher et al., ESOP 2015](https://users.eecs.northwestern.edu/~baf111/random-judgments/random-judgments-esop15.pdf)

**Evidence gaps, named rather than papered over.** (i) No published post-mortem
catalogues Cardano's specific conformance drift incidents — spec-was-wrong vs.
impl-was-wrong triage lives in PRs, not indexed prose; the FUNARCH report's own
honesty clause is the strongest citable statement. (ii) The ~2,460/~1,510
executable/proof line split for the twelve semantic modules is sweep 1's
non-comment non-proof count, not a `wc -l`; the raw totals are `Mcp` 1,678,
`Exec` 1,390, `Parse` 1,316, `Cost` 1,036, `Check` 996, `Syntax` 367, `Certify` 269,
`Rpc` 155. (iii) The ~1,550–1,850 loc Haskell estimate is a design estimate, not a
measurement, and it assumes D10, D11 and a typed builder that makes group-(B)
refusals unrepresentable; if the builder ends up loosely typed, add ~250 loc and
eleven refusal-parity obligations. (iv) §1.5b's harness estimate is the softest
number on the page — nothing was measured, and the generator line in particular is a
guess informed by Cardano's and Sail's harnesses rather than by anything in this
repo; treat 3–5 weeks as a floor. (v) The lean-rs figures (4 stars, 1 fork, 386
commits, one author, Lean 4.30.0–4.34.0-rc1, macOS/Linux) were fetched during the
attack pass, not during sweep 2, and are as of 2026-08-16. (vi) One shim claim is
*better* than an estimate and is worth recording as a fact rather than a hope:
`Verdict = WithZero (FreeMonoid Objection)` (`Question.lean:97`), so §1.4's
"`Verdict = Maybe [Text]` with its monoid" is **exact** — one of the few places a
Mathlib carrier maps onto a Haskell type with nothing lost. (vii) The repo findings
this page produced, filed rather than fixed here:
`acat-heard-matches-replay-memo-v55` (`heardMatchesReplay` false on any memo hit;
`partialBillJson`'s docstring wrong for the same reason) and
`acat-dup-function-check-gap-kys` (duplicate `function f` declarations unrefused,
resolved first-wins by `Fns.find?`). Neither is touched by this page.
