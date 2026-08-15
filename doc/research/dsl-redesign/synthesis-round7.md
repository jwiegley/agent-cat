# The round-seven synthesis (SUPERSEDED in detail by rounds 8-10; see GRAMMAR.md)

Winner: dataflow-first, amended by grafts. Produced by three independent designers
(mirror-lean, dataflow-first, and one blinded from the incumbent grammar), attacked
by nine adversaries (readability / elaboration-fidelity / expressiveness), then judged.


## scores

Six axes, 0-5 each. Attack findings weighted by whether they survived my own verification against the snapshot.

              directness | keywords | dataflow | fidelity | expressiv | parse | TOTAL
mirror-lean        4     |    2     |    2     |    1     |     1     |   3   | 13/30
dataflow-first     5     |    3     |    5     |    3     |     3     |   4   | 23/30
blind              3     |    3     |    3     |    4     |     2     |   1   | 16/30

THREE ATTACKER FATALS I CHECKED AND REJECTED FIRST (they drove three verdicts and two are wrong about the elaboration target):

(a) mirror-lean readability, "the grammar cannot express the approved loop: on exhaustion keep the last artefact and carry on." Cites Agentic/Surface.lean:134-141, where `revising : Nat -> s -> ... -> W s` returns `pure s` on both exits. But the DSL does not elaborate to Surface.W; it elaborates to Plan, and `Plan.revising` (Plan.lean:611-623) has return type `Nat -> Cont G (El c) (Option (El c))` and writes `.ret (fun th => if Verdict.approvedB (v th) then some ... else none)` at fuel 0. Exhaustion is `none`. Core/HardenPatch.lean:255-264 gates the whole consent tail behind `Plan.caseB (fun th => (final th).isSome)`, and DslFlagship.lean:315-319 names the world where "the loop exhausts its two revisions and the owner is never troubled" (13 consultations, no consent). TWO MANDATORY EXITS ARE FORCED BY THE KERNEL, not chosen by a designer: Ctx holds Codes and there is no code for "maybe a text". REJECTED as a defect in any design; it is a real pre-existing divergence between Agentic/Surface.lean and Agentic/Core/Plan.lean that no surface can repair.

(b) dataflow-first readability, "`| never settled { }` silently discards a reviewed patch the standard would always have consented on." Same error, plus: the incumbent example/harden.wf:41 writes exactly `never approved { }`. Not a regression introduced by any design. What IS real, and I repair, is that an empty brace pair is the worst possible spelling for "this path ends having done nothing".

(c) mirror-lean fidelity, "the flagship's draft node elaborates to Plan.ask, not the Plan.askC1 that HardenPatch.lean:279 writes." ACCEPTED, and it decides a structural question. `Prompt.closed` (Dsl/Syntax.lean:136-140) is `| .interp _ :: _ => none` — closedness is decided syntactically on chunks. The incumbent's `define spec = "harden the parser"` is expanded by `expand` (Parse.lean:254-260) into a `.lit`, which is why DslFlagship.lean:129-130 records the draft prompt as THREE LITERALS and why the node is `Plan.askC` at the batch rung. A `workflow f(spec: text)` parameter that becomes a Bindings entry makes `{spec}` a Chunk.interp, the prompt open, the node `Plan.ask` — a different constructor at a different rung with no rfl between them. Consequence for the final design: KEEP `define`, ADD NO WORKFLOW PARAMETERS.

=== MIRROR-LEAN 13/30 ===

Directness 4. "Read the left column" is the best single sentence anyone wrote and it is right: six names in arrival order at one indentation IS the do-block. But 29 body lines against the standard's 11 (example/HardenPatch.lean:9-19), and the three things the Lean puts on the page — the panel's reducer, the loop's `pure (patch, verdict)` wire, the exhaustion outcome — are all absent.

Keywords 2. The design concedes `ask`/`act` are deliberate twins. `under model "deep" ask model "author"` puts `model` in two senses on one line; worse, Surface.lean:86-90 documents "an inner `model` overrides an outer one — innermost wins", under which the outer "deep" is dead text on the program's central line, and the grammar states no precedence. `to judge`/`to rewrite` read as imperative steps, not as the loop's two continuations — the cold read took them that way and had to be argued out of it, which is the owner's complaint (c) reproduced verbatim.

Dataflow 2. Three fatals verified. `let patch = draft until approved, at most 2 rewrites { ... }` binds `patch` to a value that appears nowhere in the `loop` production — the grammar has no result expression. `to rewrite candidate, objections:` receives its second argument positionally with nothing connecting it to `judge`; rename it `blah` and the program means the same thing. And free lines and paid lines share one syntax (`producer ::= prompt | question | loop`), so `let verdictSpec = "..."` and `let guide = ask tool "cat" ...` are the same shape — Lean distinguishes them with an always-present character (`:=` vs `<-`). For a project whose CLI exists to "read a program, price it, or run it", losing the free/paid column is expensive.

Fidelity 1. Finding (c) above. Beyond it: `arm ::= label block` with `{ arm }` admits missing, duplicated, reordered and family-mixed arms, none refused by the four stated rules — the incumbent needs no rule because RawBlock.ifFlag(x)(yes no) and RawBlock.caseVerdict(x)(approve object declined) (Syntax.lean:206-217) carry every arm as a mandatory field. No cap on the loop bound against maxRevisions=64 and checkBlock_bounded (Check.lean:342-353, 427-433), which exist because the bound is the DEPTH OF THE ELABORATION. And the ill-typed remedy list offers `to rewrite candidate, objections:` as a legal use of a verdict, which it is not — the design deleted the incumbent's rule that the second binder holds the verdict RENDERED (Check.lean:106-111), so its own flagship's `{objections}` is refused by its own rule (3).

Expressiveness 1. `who` has no `draw`, and this is not merely a gap: Omega is a function of Q (Question.lean:256-262), so three textually identical asks are ONE question — the natural program is well-formed and is a constant. Question.lean:261-262 names `draw` as the entire mechanism. `.ack` is reachable only through the tail-position `act`, so no path can act twice or act then ask. Loops do not nest. Nothing may follow a branch.

Parse 3. Braces delimit and indentation means nothing — genuinely good. Against: `char` undefined while `{` is significant, so `"{spec}"` has two derivations; and `act tool "apply" "Apply:..."` puts two adjacent string literals in one phrase, which Parse.lean:284-292 says the incumbent grammar was arranged specifically to prevent.

=== DATAFLOW-FIRST 23/30 — WINNER ===

Directness 5, decisive. `guide : text <- ask tool "cat" "..."` is `let guide : String <- ask "..."` with the ascription made mandatory. The approved surface puts the answer's type AT THE BINDER (example/HardenPatch.lean:10,18). This is the only one of three that does the same; the other two put it at the ask (`for text`), which reads well but is not what the owner approved. `<-` is the arrow, `:` is `:`.

Keywords 3. `review`/`amend` are the best loop-clause words the whole competition produced — one loop word, two clause words, no gerund/verb near-homograph, which is the owner's complaint (b) answered directly. `{x.reasons}` and `_ :` are both excellent. Against: `visible` is unguessable and drew fire from all three of its own attackers; `branch on improving x` calls a loop a branch and puts a seed where every other `branch on` puts a tested value; `settled`/`never settled` name a state where the incumbent named a reason.

Dataflow 5. Every value has one binding site; every binding site has the same two-part shape (name : code); there are exactly three places one can appear; so computing scope at any line is one upward scan. Consumption is `{x}` in a prompt or `branch on x` and nothing else. Panel members contain no arrows, which DRAWS their independence. `{x.reasons}` renders a verdict where it is used rather than by a binder invented three lines earlier. `visible` — repaired — is the only documentation in the language the checker refuses to let rot.

Fidelity 3. One genuine fatal: a single `string` production serves prompts, addressee names, `under model` and `define`, so `ask model "reviewer-{role}"` is grammatical and computes a Q.Shape, which has no Plan former (Plan.ask takes `s : Q.Shape c`, term-level data, Plan.lean:259) and voids shapes_eq_of_le_pipeline's hypothesis-free status. Repair is one production and THE INCUMBENT ALREADY IMPLEMENTS IT: expectPlainStr (Parse.lean:243-247), "an addressee's name is written, not computed: no interpolation here". A one-line repair does not sink a design. Also verified: the `define` closure rule as stated is false, because `expand` substitutes CHUNKS and a define containing a live interp leaves one behind. Repaired. Against these, the hand-trace matches Harden.hardenPatch former for former — eight questions, seven addressees, two outer caseBs, guide bound once.

Expressiveness 3. Three of five workloads clean. Has `draw`. Has a free-position ack statement, which the incumbent's tail-only `act` does not — a real gain at zero semantic cost, since Harden.applyQ (Core/HardenPatch.lean:166) is an ordinary .ack question and example/HardenPatch.lean:19 writes it as `ask`. Against: no computed scrutinee, single-question clause bodies, no rejoin after a branch.

Parse 4. Braces mandatory on every arm body and clause body — the best bracketing of the three; the expressiveness attacker tried to break the `branch on improving x` / `branch on x` overlap and could not (`at` vs `|` decides with one token). Two real holes: `visible` is an unterminated optional list in a language whose parser has no reserved words (Parse.lean:46), so `{ visible visible }` has two parses; and two `|` ladders nest with no cue, disambiguated only by the arm vocabularies happening to be disjoint. Both repaired.

=== BLIND 16/30 ===

Directness 3. The `>`-quoted prompt line is a real idea — prompt text is the majority of a workflow file and quoting it as quoted lines is honest — but it is furthest from the approved surface's look and spends ~55 lines against 11.

Keywords 3. `independent draw 2` is the best spelling of Q.draw anyone produced, and the audit explains why the short form fails and why deletion is worse. `receipt` for `ack` is right — `ack` is jargon. Against: `served by "deep"` dresses the program's only two privilege-widening lines as deployment notes; `accepted as final:` sits three lines above `person "owner"` and teaches that the owner did the accepting when it means the panel approved; `give`/`done`/`answers`/`nothing` is four words for two concepts.

Dataflow 3. The name column is good and rule 2 (the pre-loop `draft` going stale) identifies a real hazard. But rule 2 over-fires — Plan.revising's continuations are `Cont G ...`, context-polymorphic precisely so they can read all of G (Plan.lean:611-614), so `draft` is a fixed answer to a fixed question and darkening it deletes drift review. `{review}` crosses from `check:` into `rewrite:`, a sibling block at equal indent, by special rule against the indentation model the language teaches. And the loop carrier is written every round with no assignment anywhere on the page.

Fidelity 4 — best of the three, the only "adequate" verdict in nine attacks. dyn genuinely unreachable, level bound sound, flagship hand-trace matches on case structure, question count, addressees, guide sharing. The two majors are presentational (rows 2 and 4 conflict on askC1 vs ask1; the author-facing level trichotomy is false in both directions while the <= branch bound is untouched).

Expressiveness 2. One fatal I verified and weight heavily: THERE IS NO LITERAL TEXT. "No variables other than answers", so a constant shared across three prompts must be pasted three times (byte-identity semantically load-bearing since Omega is a function of Q) or bought with a real tool question — which adds a consultation to the bill AND moves all three consumers from askC to ask, off the batch rung, because they now quote an answer. The flagship's headline readability feature costs a rung. And `never accepted:` in a value-returning workflow has no legal answer: rule 4 forces it to answer the artefact's code and rules 1-2 forbid every candidate name.

Parse 1 — fatal, and it is why blind cannot win. The EBNF says "layout by indentation" and contains NO LAYOUT TERMINALS AT ALL: no INDENT, no DEDENT, no NEWLINE, no offside rule. `prompt ::= promptline { promptline }` has no indentation constraint, so a less-indented `>` line joins the prompt under the published grammar and does not under the intended one. The two readings differ in Q.prompt, hence in Q, hence — since Omega is a function of Q (Question.lean:256) — in the answer and the bill. Separately, the spec never says whether the space after `>` is a delimiter, and one of its two claims (character-for-character identity with Harden.draftText, versus the plain reading of promptline) must be false with nothing saying which.

## grafts

FROM BLIND (design 3):
- `revising X as P` — the loop carrier bound at the loop HEAD rather than as two same-spelled parameters in two clause scopes. This kills mirror-lean's "two `candidate` bindings wearing one name" major and dataflow-first's "no argument site anywhere" fatal in one move: there is now exactly one `patch`, introduced once, read by both clauses.
- `revising` itself — the kernel's own word (Plan.revising, Surface.revising, incumbent `revising ... up to n revisions`), kept over dataflow-first's `improving` so a reader who knows the Lean can map across, and because with `review`/`amend` beside it there is no longer a gerund/verb pair to confuse it with. This repairs dataflow-first's "branch on improving is not a branch" major and mirror-lean's vocabulary-drift minor at once.
- `independent draw N` — the best spelling of Q.draw produced by anyone. Repairs mirror-lean's fatal (no draw at all, so the natural resample program is well-formed and is a constant, since Omega is a function of Q) and dataflow-first's "draw N reads as the opposite of what it means" major.
- `receipt` for `.ack` — `ack` is jargon and fails house rule 8; `receipt` says what an acknowledgement carrying no information is for.
- Refusing `{x}` where x is a receipt (blind's rule 7) — `El .ack = Unit`, there is nothing to render, and it is enforced rather than left to convention.
- The honesty discipline of naming the one word the designer is least sure of, which I repeat for `giving`.

FROM MIRROR-LEAN (design 1):
- The "read the left column" framing as the design's own test: the column of names in arrival order at one indentation IS the do-block. This is what I checked the final flagship against.
- Keeping the unit beside the numeral — `at most 2 revisions`, not `2 rounds`. Parse.lean:429-435 records this as the project's one hard-won lesson: "the numeral is the one thing three independent readers of Plan.revising got backwards". dataflow-first's `rounds` counts something Plan.revising does not.
- The insistence that a keyword pair must complete itself in the head, which is why the loop's two outcomes are attached by `giving` rather than floating.

FROM THE INCUMBENT (things the competition deleted and should not have):
- `define` — kept, and it is load-bearing, not nostalgia. Without it the flagship's draft node is Plan.ask instead of Plan.askC (verified: Prompt.closed, Syntax.lean:136-140; DslFlagship.lean:129-130 records three literals), and blind's own flagship pays a real question plus a rung for every shared constant.
- `using model "m"` — kept UNCHANGED. The competition produced three replacements (`under model` from mirror-lean and dataflow-first, `served by` from blind) and all three are worse: `under` is a bare preposition that reads as a second addressee, `served by` reads as infrastructure and was called fatal by blind's own reader. `using model "deep"` is the only one of the four that names the relation and says using WHAT, and it already passes expectPlainStr. Deliberately not renamed.
- `expectPlainStr` (Parse.lean:243-247) — restored, which repairs dataflow-first's only genuine fidelity fatal.
- The incumbent lexer's brace rule (Parse.lean:88-127) — an unescaped `{` always opens an interpolation, `\{`/`\}` escape, empty and unterminated holes diagnosed. This closes the "char is undefined" grammar ambiguity that ALL THREE designs left open and that three separate attackers filed.
- `panel` the word — one of the five words of the approved surface (Surface.lean:113). Kept, and blind's honesty instinct is grafted onto it as `panel, all must approve [...]`, which puts on the page the fan-in rule that Surface.lean:124-129 states only in a docstring and that was the single largest unanswerable cold-read guess in two of three readability attacks.

MY OWN ADDITIONS (neither grafted nor incumbent):
- `amend (why : verdict) -> patch` — the arrow points at the name it rebinds, so the loop's back-edge, the only assignment in the language, is WRITTEN. This repairs blind's "the loop carrier is mutated with no assignment anywhere on the page" fatal and dataflow-first's "three wires carried by declaration order and type-name coincidence" fatal simultaneously, at the cost of one arrow target.
- `giving { ... }` — one word attaching the loop's two outcomes to the loop, which is the owner's complaint (a) answered. Flagged as the word I am least sure of.
- `stop`, with `{ }` refused — every dead end says so out loud, repairing dataflow-first's "both of the program's termination points are spelled as absence" major.
- `known here: ... | nothing` — dataflow-first's `visible`, renamed to say what it means, with a mandatory non-empty list (killing the `{ visible visible }` parse ambiguity), legal in any block or clause body, and defined as exactly the binder names innermost-first including `_`.
- Rule 9, rejoin after a branch — free semantically (graft pushes through case structurally, Plan.lean:425-426, and the checker already does it twice), repairs a MAJOR in all three designs.

## finalGrammar

Braces delimit. Indentation means nothing. Comments run `--` to end of line. The lexer is the incumbent's, unchanged (Dsl/Parse.lean:74-127).

program     ::= { define } "workflow" block

define      ::= "define" name "=" defstring

block       ::= "{" ( statement { statement } | "stop" ) "}"

statement   ::= binding
              | scopenote
              | branch
              | revision

binding     ::= binder "<-" source
binder      ::= name ":" code
              | "_" ":" "receipt"

source      ::= ask
              | "panel" "," "all" "must" "approve" "[" ask { "," ask } "]"

ask         ::= "ask" who [ "using" "model" plainstring ]
                           [ "independent" "draw" number ] prompt
who         ::= ( "model" | "tool" | "person" ) plainstring

scopenote   ::= "known" "here" ":" ( "nothing" | name { "," name } )

branch      ::= "branch" "on" name "{" arm arm [ arm ] "}"
arm         ::= tag block
tag         ::= "yes" | "no"                                  -- a flag: exactly these two
              | "approved" | "objected" | "no" "answer"       -- a verdict: exactly these three

revision    ::= "revising" name "as" name "," "at" "most" number "revisions" "{"
                  "review" "->" "verdict" "{" source "}"
                  "amend" "(" name ":" "verdict" ")" "->" name "{" source "}"
                "}"
                "giving" "{"
                  "settled" "(" name ":" code ")" block
                  "never" "settled" block
                "}"

code        ::= "text" | "verdict" | "flag" | "receipt"

prompt      ::= '"' { plain | escape | hole } '"'
defstring   ::= '"' { plain | escape | hole } '"'
plainstring ::= '"' { plain | escape } '"'
plain       ::= any character other than '"', '\' and '{'
escape      ::= "\n" | "\t" | "\r" | "\\" | "\"" | "\{" | "\}"
hole        ::= "{" name [ "." "reasons" ] "}"

name        ::= letter { letter | digit | "_" } | "_"
number      ::= digit { digit }

NINE RULES THE GRAMMAR DOES NOT CARRY. A reader is told these once; each exists because the elaboration target requires it, and each is enforced.

1. A block is statements, or the word `stop`. `{ }` is not writable: a path that does nothing says so. Both spellings elaborate to `ret`.

2. A name may be introduced in exactly three places, and every one has the same two-part shape NAME AND KIND: left of `<-`, in the `settled` arm's parentheses, and in `amend`'s parentheses. The loop's carrier is introduced by `as` at the loop head and its kind is the subject's. There is no fourth place.

3. A value is consumed in exactly two ways: `{x}` inside a prompt, and `branch on x`. There is no expression language — no test, no comparison, no arithmetic, no transformation, no way to pass a name anywhere else.

4. `{x}` interpolates text only. Where x is a verdict, write `{x.reasons}` — the objections joined by "; ", which is Verdict.render (Core/HardenPatch.lean:91) written where it is used. Where x is a flag or a receipt there is no rendering and the program is refused; a receipt carries no information (El .ack = Unit). `_` may not be interpolated and may not be branched on.

5. A `define` is literal text. Inside a defstring, `{x}` must name an EARLIER define; anything else is refused at parse time. So expansion always yields literals, no define can be cyclic, and the batch rung is decidable by eye: a question is closed exactly when every name it interpolates is a define. A binder may not spell a define.

6. An addressee's name, a `using model` name and a `define` name are written, not computed. They take plainstring, which has no hole.

7. `branch on` requires a flag (arms yes, no) or a verdict (arms approved, objected, no answer). Every arm is written, in that order, or the program is refused. No default, no fallthrough. Names bound inside an arm die with the arm.

8. `at most n revisions` counts revisions: the loop reviews first, so `at most 2 revisions` is three reviews and at most two amendments. n may name at most 64 (maxRevisions, Dsl/Check.lean:353) because the bound is the depth of the elaboration, not a runtime counter.

9. A branch or a revision may be followed by further statements, which run on every arm. Nothing bound inside an arm is in scope there.

PARSE DETERMINISM. Every statement begins with an identifier and is decided by ONE token of lookahead after it: `name :` is a binding, `known here` is a scope note, `branch on` is a branch, `revising name` is a revision, `stop }` ends a block. The language has no reserved words (Parse.lean:46), so a binder may be named `branch`, `known` or `stop` without ambiguity — positions decide, exactly as the incumbent does it. A `source` begins with `ask` or `panel`. The one two-token tag, `no answer`, is decided by whether the token after `no` is `{` or `answer`. All arm lists and all clause bodies are brace-enclosed, so nesting is unambiguous and there is no `|`-ladder to mis-attach.

## finalFlagship

define spec        = "harden the parser"
define verdictSpec = "Reply with exactly APPROVE if acceptable, or OBJECTION: <one line> if not."
define flagSpec    = "Reply with exactly yes or no."

workflow {

  guide : text <- ask tool "cat"
      "Write out the house style guide, at most four short lines."

  draft : text <- ask model "author" using model "deep"
      "Draft a patch satisfying:\n{spec}\nReply with a unified diff only."

  revising draft as patch, at most 2 revisions {

    review -> verdict {
      panel, all must approve [
        ask model "reviewer-correct"
            "{guide}\nIs this patch correct?\n{patch}\n{verdictSpec}",
        ask model "reviewer-secure"
            "{guide}\nIs this patch secure?\n{patch}\n{verdictSpec}",
        ask model "reviewer-simple"
            "Could this patch be simpler?\n{patch}\n{verdictSpec}"
      ]
    }

    amend (why : verdict) -> patch {
      ask model "author" using model "deep"
          "{guide}\nRevise this patch:\n{patch}\n{why.reasons}\nReply with the revised diff only."
    }

  } giving {

    settled (patch : text) {
      known here: patch, draft, guide

      ok : flag <- ask person "owner"
          "Apply this patch?\n{patch}\n{flagSpec}"

      branch on ok {
        yes {
          _ : receipt <- ask tool "apply"
              "Apply:\n{patch}\nWrite the patched file here, then reply DONE."
        }
        no { stop }
      }
    }

    never settled { stop }
  }
}

PROMPT FIDELITY. Every prompt is Agentic/Core/HardenPatch.lean's, character for character — checked against the chunk lists recorded in DslFlagship.lean:119-178, which are what the checker actually receives: guideQ (:64), draftText (:78, three literals with spec expanded), correctText (:109), secureText (:121), simplerText (:134), reviseText (:95), consentText (:146), applyText (:160). Adjacent literals are deliberately not fused (Prompt.normalize, Syntax.lean:142-159) and Prompt.exprFrom left-associates (Check.lean:125-139), so the elaborated prompts are the same ++-chains Harden writes by hand.

WHAT THE PAGE GIVES A READER WITHOUT A GLOSSARY. Down the left edge: guide, draft, patch, why, patch (again — the same artefact, after the loop), ok, _. Each is introduced once, by one of exactly three shapes, and each carries its kind in the same column. Across from each is what was said, in quotation marks. `{guide}` occurs in four prompts and you can count them; the simplicity reviewer is the one that does not get it. `amend (why : verdict) -> patch` says on one line what the loop's three wires are: it is told the verdict, it may read the patch, and what it answers IS THE NEXT PATCH — the arrow points at the name it rebinds, so the loop's assignment is written rather than performed by section order. `panel, all must approve` states the fan-in rule that Agentic/Surface.lean:124-129 gives only in a docstring and that no previous surface put on the page. The brace that closes the loop is the line where the schedule changes: everything above it runs every round, everything under `giving` runs once, at exit. And `known here: patch, draft, guide` is the checker's own Gamma in the reader's own words, refused if wrong.

STRUCTURE CHECK against Core/HardenPatch.lean: revising ... 2 contributes two caseBs, finishCont one, consent one — four case nodes; three loop exits x three tail leaves = 9 cost-tree leaves; eight questions; seven addressees; guide bound once and read in three prompts. Identical to the incumbent's.

## finalHello

The port of example/hello.wf, which must keep working and keep its rung:

-- The smallest program the language can write that is still a workflow: two
-- questions and an act. `pipeline` rather than `branch`, so its bill is known
-- exactly rather than bounded.
define brief = "Reply in one short line."

workflow {
  subject : text <- ask tool "cat"
      "Name one thing worth greeting.\n{brief}"

  greeting : text <- ask model "greeter"
      "Write a greeting for this, and nothing else:\n{subject}\n{brief}"

  _ : receipt <- ask tool "say"
      "Say it:\n{greeting}\nThen reply DONE."
}

`subject`'s prompt names only a define, so it is closed: Plan.askC, batch. `greeting` and the receipt each name an answer, so each is Plan.ask, pipeline. No `case` anywhere, so level = pipeline — exactly what example/hello.wf:1-4 claims of itself, preserved.

The two-line version, for a reader meeting the language:

workflow {
  greeting : text <- ask tool "cat" "Say hello, in one line."
}

One closed question, batch, and the block runs out. An answer nobody reads is accepted rather than refused: the consultation happened and the transcript records it (Denote.lean:130-131).

## planMapping

Plan has five formers (Plan.lean:238-285). This surface reaches four. There is no row for `dyn`, and none for `bindP` (Plan.lean:462-464), the one derived form that needs it.

| construct | Plan | level contribution |
| `define x = "..."` | none — textual, expanded by `expand` (Parse.lean:254-260) into .lit chunks before any Raw exists | none |
| `workflow { B }` | `checkBlock [] [] B : Plan [] Unit` | level of B |
| `{ stop }`, or a block whose statements run out | `ret (fun _ => ())` (RawBlock.empty) | batch (level_ret) |
| `x : c <- ask W "..."`, prompt all literal | `Plan.askC c (s.withPrompt words) k` (checkBinder, Check.lean:275) | level k (level_askC) |
| `x : c <- ask W "...{y}..."` | `Plan.ask c s e k`, e : Expr G String | pipeline ⊔ level k (level_ask) |
| `_ : receipt <- ask W "..."` | the same two at c = .ack; the answer is bound under `_`, which rule 4 forbids interpolating | as above |
| `using model "m"` | none — askShape (Check.lean:159-163) writes `atModel m` into the SHAPE; licensed by under_ask1 and under_askC1, both rfl (Check.lean:170, 176) | none |
| `independent draw n` | none — `draw := n` in the shape (Q.Shape.draw, Question.lean:294) | none |
| `x : verdict <- panel, all must approve [a1..ak]` | `graft (Plan.panel ps) (fun _ s e => sub k ...)` (checkBinder, panel case). Plan.panel is `foldr (zipWith (·*·))` (Plan.lean:585); the monoid is installed only at .verdict (Plan.lean:562) | join of members ⊔ level k (level_panel_le, level_graft_le) |
| `known here: ...` | none — an assertion on Bindings, the identity on the continuation | none |
| `branch on x { yes A no B }` | `Plan.caseB e A' B'` = case at Bool | branch ⊔ arms (level_case) |
| `branch on x { approved A objected B no answer C }` | `Plan.caseV e arms` = case at VTag via Verdict.tag (Plan.lean:515) | branch ⊔ arms |
| `revising a as p, at most n revisions { review -> verdict { R } amend (w : verdict) -> p { M } } giving { settled (p' : c) B1 never settled B2 }` | `graft (Plan.revising (checkCont R') (reviseCont M') n G Sub.id b.val) (finishCont B1' B2')` — the incumbent's own three continuations (Check.lean:300-323), unchanged | branch ⊔ ... (level_revising_le, Dsl.lean:124) |
| `review -> verdict { ... }` | checkCont: the artefact is de Bruijn 0, and all of S remains in scope | joined above |
| `amend (w : verdict) -> p { ... }` | reviseCont: the verdict is de Bruijn 0, the artefact 1 | joined above |
| `giving { settled (p') ... never settled ... }` | finishCont = caseB on `(final d).isSome`, the artefact reaching the settled arm as de Bruijn 0 and the exhausted arm reaching G unextended (Check.lean:314-323) | joined above |
| a branch or a revision followed by further statements | `graft` pushes the rest through every arm structurally (Plan.lean:425-426) — no dyn, no rung change | unchanged |
| `{y}` in a prompt | Expr from the binder, ++-chained left-associated (Check.lean:125-139) | none |
| `{w.reasons}` | the verdict binder composed with Verdict.render — the SAME Expr G String the incumbent's `why` binder holds (Check.lean:443) | none |

WHY dyn IS UNWRITABLE. `dyn (e : Expr G B) (f : B -> Plan G A)` needs a plan computed from an answer. Rule 3 gives an answer exactly two destinations. Into a prompt, it reaches ask's words slot — and `Q c ≅ Q.Shape c × String` (Question.lean:298-300) with the shape written in the term, so the answer cannot reach the shape. Into `branch on`, it reaches a finite classifier — Bool or VTag, the two FinEnums the kernel ships (Plan.lean:295, 508) — with every arm written. Nothing in the grammar has a block on its right-hand side indexed by a value; nothing binds the outcome of a branch or a revision to a name; there is no workflow-valued name, no workflow parameter, no way to pass a block. The only repetition is `revising`, whose bound is a literal numeral and whose meaning is its unrolling (Nat.rec, Plan.lean:607-608).

WHY EVERY PROGRAM IS AT LEVEL <= BRANCH. `level` (Level.lean:120-126) is a five-clause fold whose only `dynamic` producer is the dyn clause. Induct on the block: `stop` gives batch; a closed ask gives level k; an open ask gives max pipeline (level k) with pipeline <= branch (Level.lean:182); a panel is bounded by level_panel_le and level_graft_le with level_sub moving nothing; a `known here` emits no node; a branch is max branch (sup arms); a revision is graft of Nat.rec-unrolled graft/caseB/ret and closes at branch by induction on the numeral; a following statement is grafted, and level_graft_le bounds the graft by the max of its parts. A finite join of values none of which is `dynamic` is not `dynamic`, and the largest constant introduced is branch. This is exactly parseAndCheck_level_le (Dsl.lean:361-367), preserved with the same four formers and no side condition on the source.

## critiqueAnswers

THE OWNER: "I take it that 'approved given patch' followed by 'never approved' [are] representing branches? Is this simply a way to declare ways to respond to the preceding ask...?"

Two branch-introducing keywords floated after the loop's closing brace with nothing drawing the connection, so the reader had to guess whether they were arms, statements or handlers, and OF WHAT. In the final surface they are inside a brace pair attached to the loop by one word:

  revising draft as patch, at most 2 revisions { ... } giving { settled (...) {...}  never settled {...} }

`giving` says the loop produces one of these; the brace says which; the two arms sit at the same indentation inside it and neither can be written without the other. This is the same shape as `branch on ok { yes {...} no {...} }`, so a reader learns ONE arm-list shape and meets it in both places. Nothing floats.

The two outcomes are mandatory because the kernel makes them mandatory: Plan.revising answers `Option (El c)` (Plan.lean:611-614) and Ctx holds Codes, so there is no code for "maybe a text" and the surface cannot hide the `none`. `settled (patch : text)` names the artefact where it exists; `never settled` takes no binder, which is what it means; and `never settled { stop }` says out loud that this path ends having done nothing, where the rejected surface wrote `never approved { }` and said it with an absence.

THE OWNER: "Why both 'revise' and 'revising'?"

One loop word and two clause words that cannot be confused with it or with each other:
  - `revising` — the kernel's own word (Plan.revising, Surface.revising), kept so a reader who knows the Lean can map across.
  - `review` — what looks at a candidate and says whether it stands.
  - `amend` — what produces the next candidate.
`revise` is deleted. There is no gerund/verb pair anywhere in the language. `review -> verdict` and `amend (why : verdict) -> patch` each state on their own line what they answer, so neither can be read as an imperative step.

THE OWNER (via the dispatch): "...question-asking steps nested inside other constructs so the reader cannot tell what responds to what."

Three changes. First, every clause writes its answer on its head line: `review -> verdict` and `amend (...) -> patch`. The nested `ask` inside `review` responds to nothing; it PRODUCES the verdict named on the line above it. Second, the loop's inputs are named at the loop head — `revising draft as patch` — so `patch` is one name with one meaning in both clauses, instead of two same-spelled parameters in two scopes (which is what mirror-lean and dataflow-first both wrote and what two attackers filed as a fatal). Third, `amend`'s arrow points at `patch`, so the loop's back-edge — the only assignment in the language — is WRITTEN, not performed by the ordinal position of a section in the EBNF (which is what blind's reader had to reverse-engineer, and filed as a fatal).

THE OWNER: "The Lean code at least had a very direct structure and flow, and it was easy to see how data was moving and who could see it. This DSL ... lost exactly that."

This was the specification. The final surface answers it with four properties a reader can rely on without a glossary.

(1) ONE BINDING-SITE SHAPE, THREE PLACES. A name is introduced only as `name : code` — left of `<-`, in `settled (...)`, or in `amend (...)` — plus the loop head's `as patch`. So "what is in scope here" is one upward scan: the defines, then every `name : code` above this line in this block, then the `name : code` in the header of each enclosing clause or arm. Nothing is bound silently and nothing is bound by a keyword's ordinal position.

(2) TWO CONSUMPTION SITES, AND NO THIRD. `{x}` in a prompt, and `branch on x`. There is no expression language, so an answer cannot be tested, transformed, compared, counted or passed. "Who could see the style guide" is answered by searching for `{guide}` — four prompts, and the fourth reviewer's absence from the list is visible in the same scan. This is the surface half of what guide_once proves.

(3) THE KIND TRAVELS WITH THE NAME, IN ONE COLUMN. `guide : text`, `ok : flag`, `why : verdict`, `_ : receipt`. This is where example/HardenPatch.lean:10,18 puts it (`let guide : String <-`, `let ok : Bool <-`), so the column that answers "what does this name hold" is the same column the approved surface uses. It also makes the discard honest: `_ : receipt` says in one shape both that something was done and that nothing came back.

(4) A VERDICT NEVER SILENTLY BECOMES TEXT. `{why.reasons}` writes the renderer where it is used. The rejected surface bound `why` at text behind the scenes (Check.lean:106-111, 443); a reader had to know that a name spelled in a `revise` header was a different KIND from a name spelled in a `check` header.

And `known here: patch, draft, guide` lets an author freeze the answer to WHO CAN SEE WHAT on the page, innermost first, in the checker's own order. If it is wrong the program is refused. It is the one piece of documentation in the language that cannot rot.

THE OWNER: "feels sloppy and imprecise in comparison" / "the directness and clarity of the Lean expression."

Line for line against example/HardenPatch.lean:
  let guide : String <- ask "..."          ->  guide : text <- ask tool "cat" "..."
  model "deep" <| ask s!"..."              ->  ask model "author" using model "deep" "..."
  panel [ ask ..., ask ..., ask ... ]      ->  panel, all must approve [ ask ..., ask ..., ask ... ]
  revising 2 spec fun current => ...       ->  revising draft as patch, at most 2 revisions { ... }
  pure (patch, verdict)                    ->  review -> verdict { ... } and amend (...) -> patch { ... }
  let ok : Bool <- askHuman s!"..."        ->  ok : flag <- ask person "owner" "..."
  if ok then ask s!"..." else pure ()      ->  branch on ok { yes { ... } no { stop } }

Two places where the surface is MORE explicit than the approved Lean, and both matter. The addressee is written at every ask — the Lean's bare `ask` cannot distinguish a shell tool from a model from a human, and seven distinct addressees live in Core/HardenPatch.lean while none appears in the example. And the panel's fan-in rule is on the page rather than in a Monoid instance's docstring.

HOUSE RULE 8 AUDIT ("a keyword either says what it means to a cold reader or does not exist"). Kept, with the cold reading each is meant to produce: `define` (names a piece of text, once, at the top); `workflow` (what follows is the program); `ask` (put a question to somebody); `model`/`tool`/`person` (who is being asked); `using model "m"` (the question is served by the model named m); `independent draw n` (a separate, independent sample of the same question); `panel, all must approve` (several asked side by side, and one objection sinks it); `known here` (the names in scope at this line, innermost first); `branch on x` (the workflow divides here and x decides); `yes`/`no` (the two answers to a flag); `approved`/`objected`/`no answer` (the three things a verdict can be — `no answer` chosen over the kernel's `declined` because `declined` does not say WHO declined, and a reader guessed the owner); `revising x as p, at most n revisions` (keep revising x, calling it p, at most n times); `review -> verdict` (what looks at it and judges); `amend (why : verdict) -> patch` (what fixes it, given the reasons, producing the next patch); `giving` (and what comes out is one of these); `settled`/`never settled` (it came to rest on this / it never came to rest); `text`/`verdict`/`flag`/`receipt` (the four kinds of answer); `reasons` (what a verdict objected to, as text); `_` (the answer goes nowhere); `stop` (nothing further is done on this path).
Deleted, with why each failed: `let` (says nothing the arrow does not); `for text` at the ask (the kind belongs at the binder, where the reader meets the name); `act` (invited the belief that a doing differs from an asking — Harden.applyQ is an ordinary .ack question and the owner's own Lean writes it as `ask`); `if`/`else` beside `case` (two constructs for one idea); `given` (a signature already says what is given, and its kind too); `check`/`revise` (near-homographs of `revising`); `approved given p`/`never approved` (the owner's exact complaint, now arms of a brace attached to the loop); `up to n revisions` (kept as `at most n revisions`, same unit, clearer quantifier); `visible` (unguessable, renamed `known here`); `flag` was considered for renaming to `yes or no` and kept, because it is the code name the checker already prints.

## implementationDelta

=== Dsl/Parse.lean ===

Lexer UNCHANGED. It already resolves the brace question the right way — an unescaped `{` always opens an interpolation, `\{` and `\}` escape, empty and unterminated holes are diagnosed (Parse.lean:88-127) — which closes the "char is undefined" hole all three designs left open and three separate attackers filed. `{why.reasons}` already lexes as `Chunk.interp "why.reasons"` with no change, because the name scan is `takeWhile (fun d => d != '}' && d != '"' && d != '\n')`.

Changed productions: the code moves from the ask to the binder (`name ":" code "<-"` replaces `let name =` plus trailing `for code`); `panel [` becomes `panel, all must approve [`; `if`/`else` and `case` collapse into one `branch on x { tag block ... }`; the whole `revising`/`check given`/`revise given`/`approved given`/`never approved` complex becomes `revising a as p, at most n revisions { review ... amend ... } giving { settled (...) ... never settled ... }`; `act` is deleted in favour of a `_ : receipt <-` binding, which may appear anywhere a statement may; `stop` is added and `{ }` refused; `known here: ...` is added with a mandatory non-empty list or the word `nothing`, which removes the unterminated optional list that made `{ visible visible }` ambiguous.

New refusals, one line each: a defstring's holes must name earlier defines; a binder may not spell a define; `_` may not be interpolated or branched on. `expectPlainStr` (Parse.lean:243-247) is UNCHANGED and continues to guard addressee names and `using model` — the production dataflow-first deleted and this design restores.

`RawAsk` keeps its `code` field, filled by the parser from the binder, so Raw's type is unchanged for asks and checkAsk/checkAskAt/checkMembers/checkRhsAt need no signature change. One consequence: checkMembers' "members must agree in answer kind" error becomes unreachable, since all members now take the binder's code. Keep the clause, note it as unreachable.

=== Dsl/Syntax.lean ===

Chunk, Prompt, Prompt.closed, Prompt.normalize, CheckError, RawTarget and RawAsk UNCHANGED. In RawBlock: `act` deleted; `ifFlag`, `caseVerdict` and `revising` each gain a `rest : RawBlock` field so a branch may be followed by statements; `empty` stays, and is what `stop` parses to.

Deliberately NOT taken: neither design's promised diagnostics — column positions inside a string literal — are claimed here, because Chunk carries no Pos and chunkExpr receives the enclosing statement's position (Check.lean:112, confirmed by flagshipRaw recording `pos := { line := 16, col := 9 }` for a whole three-chunk reviewer prompt). Both fidelity attackers filed this as a major against the design that claimed it; this design does not claim it. Errors report at the statement with the offending name as the excerpt, which is what CheckError already does.

=== Dsl/Check.lean ===

Binding, Bindings, Bindings.push, Prompt.exprFrom, askShape, under_ask1, under_askC1, checkAsk, checkRhs, checkBinder, checkCont, reviseCont, finishCont, maxRevisions and checkBlock_bounded's STATEMENT are UNCHANGED.

Three changes:
1. `chunkExpr` splits the interp name at the first `.`. A bare `{x}` at .verdict now errors naming `.reasons` as the fix; `{x.reasons}` at .verdict produces `fun d => Verdict.render (...)`; `{x}` at .ack errors ("a receipt carries no information"). Correspondingly the revising clause's `Swith` binds the second name at `Code.verdict` holding `Env.head` rather than at `Code.text` holding `Verdict.render ∘ Env.head` (Check.lean:443) — the renderer moves from the binder to the use site. THE RESULTING Expr IS THE SAME TERM, which is what keeps the flagship's Plan identical.
2. `checkBlock` loses its `.act` clause and grafts `rest` in the three tail clauses; a `known here` clause is added, comparing the asserted list against S's names in order and reporting both lists on mismatch.
3. `RawBlock.bounded` gains `rest.bounded` conjuncts in three cases; checkBlock_bounded's statement is unchanged and its proof gains three trivial steps.

=== Dsl.lean ===

`checkBlock_level_le` loses the `.act` case and gains three `level_graft_le` (Level.lean:230) steps for the grafted continuations. EVERY THEOREM STATEMENT, including parseAndCheck_level_le, is UNCHANGED.

=== Explain.lean ===

Printer changes only, but real ones: `revisionLines` and the prose around it (Explain.lean:330-411) name `revising ... up to n revisions`, `approved`, and the arms, so every renamed keyword is a string to update. No structural change.

=== doc/dsl-guide.html, example/*.wf === Rewritten.

=== KERNEL === Agentic/Core/HardenPatch.lean, Plan.lean, Level.lean, Denote.lean, Cost.lean, Question.lean UNTOUCHED. No kernel change is proposed.


=== WHICH DslFlagship THEOREMS SURVIVE VERBATIM ===

The structural fact that decides this: `flagshipPlan` is DEFINED as `match check [] [] flagshipRaw with | .ok p => p | .error _ => ...` (DslFlagship.lean:187-190). It is whatever the checker builds. So the question for every theorem is not "does the statement mention changed syntax" but "does the checker still build the same Plan".

IT DOES, provided four elaboration decisions hold, and all four are deliberate:
 - `spec` remains a define, so the draft prompt is still three literals (DslFlagship.lean:129-130), still closed, still Plan.askC under `deep` — the batch-rung node Core/HardenPatch.lean:279 writes.
 - `verdictSpec` and `flagSpec` remain defines, so the reviewer and consent prompts keep their unfused adjacent literals and their left-associated ++-chains.
 - `{why.reasons}` produces the same `Expr G String` at the same de Bruijn index that the incumbent's `why` binder produced.
 - `_ : receipt <- ask tool "apply" "..."` as the last statement of the `yes` arm emits `Plan.ask .ack s e (.ret fun _ => ())` — byte-identical to what RawBlock.act emitted; and `stop` emits the `ret` that RawBlock.empty emitted.

VERBATIM, statement and proof: render_eq_harden_render (:74); flagshipPlan's definition (:187); check_flagshipRaw (:211, a cases on the checker's result, not a comparison of plans); parseAndCheck_of_parse (:227); parseAndCheck_flagship (:238, it takes `parse flagshipSource = .ok flagshipRaw` as a HYPOTHESIS).

VERBATIM STATEMENT, decide +kernel recomputes over a Raw of the same size (no re-proof, only re-execution): flagshipRaw_accepted (:206); level_flagshipPlan = branch (:249); level_flagshipPlan_le (:253); card_leaves_flagship = 9 (:260); minFold_flagship = 5 (:268); maxFold_flagship = 15 (:275); trace_flagship_refuse/apply/stubborn/echo (:304-326, all four); bill_flagship_refuse/apply/stubborn/echo = 6/7/13/15 (:335-357, all four); flagshipUpTo (:363); flagship_bill_le (:368); minFold_flagship_le_bill (:375).

REWRITTEN BY HAND: `flagshipRaw` (:118-180) — new positions, new constructors for the branch/loop shape, `Chunk.interp "why.reasons"`, no `.act`, `rest` fields. `flagshipSource` (:102) keeps its definition; the file's bytes change.

NOTHING IN DslFlagship.lean NEEDS RE-PROOF. flagshipRaw needs re-transcription and everything downstream of it needs recomputation, at unchanged cost.

OUTSIDE THAT MODULE:
 - test/DslSmoke.lean — re-run `parse flagshipSource = .ok flagshipRaw` on the new file and the new flagshipRaw. Raw's DecidableEq is untouched.
 - test/CliSmoke.lean:231 pins the ill-typed refusal at `example/ill-typed.wf:10:14:`. The ported program moves the offending statement, so THIS PIN CHANGES; if the message text is also pinned, that changes too, since the diagnosis now names `.reasons` as the fix.
 - test/CliSmoke.lean:162 requires example/harden.wf to be byte-for-byte Dsl.flagshipSource — still true, on the new bytes.
 - Dsl.lean's theorems: statements unchanged, three proofs gain graft steps.

The ported example/ill-typed.wf, which must keep being refused identically by plan, cost and run:

  workflow {
    review : verdict <- ask model "reviewer"
      "Is the parser correct?"

    note : text <- ask model "scribe"
      "Write this up: {review}"
  }

refused by chunkExpr at the `note` statement, excerpt `review`: "only a text answer interpolates into a prompt, but `review` answers `verdict` — a verdict approves, objects with reasons, or gives no answer. Write `{review.reasons}` for the objections as text, or `branch on review { ... }` to take a different path for each."

## regressions

Eight, stated plainly with reasons, because a synthesis that claims only gains is not one.

1. THE IRREVERSIBLE LINE IS QUIETER. example/harden.wf:36 writes `act tool "apply" "..."` — a verb, in tail position, that names a deed. The final surface writes `_ : receipt <- ask tool "apply" "..."`, which is a discarded question. I made this trade on purpose: Harden.applyQ (Core/HardenPatch.lean:166) IS an ordinary .ack question, example/HardenPatch.lean:19 writes it as `ask`, and the free-position form buys "publish then notify" and "apply then verify", which the tail-only `act` could not express at all (mirror-lean's expressiveness attacker filed exactly this as a fatal against the tail-only form). But on the single axis of THE ONE LINE THAT CHANGES THE WORLD SHOULD SHOUT, the incumbent is better and this design is worse. `receipt` and the `_` column mitigate; they do not eliminate. dataflow-first's readability attacker was right about the direction of the loss and wrong that it outweighs the gain.

2. LOCAL REASONING ABOUT BRANCHES IS WEAKER. In the rejected surface every arm is the rest of the workflow, so a reader who reaches an arm knows nothing follows. Rule 9 allows statements after a branch. I took this because the alternative is source duplication exponential in the number of sequential gates (two gates before a loop is four textual copies of the loop, its four prompts and its two outcome blocks), and because `graft` pushes a continuation through `case` structurally with no dyn and no rung change (Plan.lean:425-426) — the checker already performs exactly this move twice, at the panel binder and at finishCont. But a reader must now look past a closing brace to know what happens next, and the incumbent never made them.

3. `known here` IS A SECOND SOURCE OF TRUTH ABOUT SCOPE. It is redundant with rule 2 by construction, which is what makes it checkable and also what makes it one more thing to write, read and keep in step. The incumbent has no analogue and pays no such cost. I kept it because it is the only construct in the competition that directly answers "who could see it" in the reader's own words, and because the checker refuses it when wrong — but it is a net addition to what a reader must learn, and all three of dataflow-first's attackers flagged its ancestor.

4. THE LANGUAGE NOW HAS ONE PROJECTION. `{x.reasons}` is the only postfix anything in the grammar. The incumbent had none: `why` was bound at text and the renderer lived at the binder (Check.lean:106-111). One more concept, in exchange for a verdict never silently becoming text.

5. MORE MULTI-TOKEN KEYWORDS. `panel, all must approve`, `known here`, `no answer`, `never settled`, `at most n revisions`. The parser has no reserved words (Parse.lean:46) and decides by position, so this costs no determinism — but it is more surface for a lexer-level typo to land in, and the incumbent's vocabulary is mostly single words.

6. `giving` IS THE WORD I AM LEAST SURE OF. It is the only word in the final design with no precedent in the codebase, in the approved surface, or in any of the three proposals. It reads correctly to me — "revising ... giving one of these" — but it has not been cold-read by anyone. If it fails, the replacement that keeps the grammar and loses the word is to write the two arms directly after the loop's closing brace with no connective, which reintroduces exactly the floating-arms problem the owner rejected; so the honest fallback is a different word in the same slot, not a different structure.

7. TWO THINGS I DECLINE TO REPAIR, BOTH SHARED WITH THE INCUMBENT, so neither is a regression against the rejected surface but both are stated limits.
   (a) NO COMPUTED SCRUTINEE. Plan.case takes any `Expr G T` at any FinEnum T (Plan.lean:278), so majority-of-three and quorum are single supported nodes at Level.branch, and Plan.lean:568-570 names quorum as "a morphism out of (N, +)". Two attackers filed this as fatal (against dataflow-first and against blind). Repairing it needs an expression language, which destroys rule 3 — the property that makes the owner's question answerable by search. The incumbent restricts to a bare name too (ifFlag (x : String), Syntax.lean:206). Declined, with the cost stated: resample-and-vote is unwritable; only unanimity, the verdict monoid, is available.
   (b) CLAUSE BODIES TAKE ONE QUESTION OR ONE PANEL, NOT A BLOCK. Plan.revising's arguments are Conts and checkCont already accepts a whole `Plan (c :: G) (El .verdict)`, so a block would elaborate today. Allowing it needs a second flavour of block with a value-producing tail, i.e. a `give` keyword — one more word for a concept the language otherwise does not have, and blind's readability attacker filed `give`/`done`/`answers`/`nothing` as four words for two concepts. I keep the incumbent's brace-wrapped single question, which Parse.lean:355-358 records was written in braces "so that the clause can be relaxed later to a block without moving a character of what exists". The door stays open where the codebase already decided to leave it. Cost stated: a review that runs a linter and then has a model read its output, and a nested bounded revision, are both unwritable.

8. THE FLAGSHIP IS NOT SHORTER. example/harden.wf is 42 lines, 34 non-blank; the final flagship is 44 lines, 35 non-blank. Against the approved Lean's 11. The gain is entirely in what the lines say, not in how many there are, and any claim otherwise would be false. (dataflow-first's own fidelity attacker caught its design claiming "twelve lines of Lean become twenty-six here" when the file was 37 non-blank; I have counted mine mechanically rather than repeat the error.)

ONE FURTHER THING THAT IS NOT A REGRESSION BUT SHOULD BE RECORDED FOR THE OWNER. Agentic/Surface.lean:134-141's `revising` returns the last artefact on exhaustion and always reaches the consent gate; Agentic/Core/Plan.lean:611-623's `revising` returns `none` on exhaustion and Core/HardenPatch.lean:255-264 gates the consent tail behind `isSome`, so DslFlagship.lean:317-319's stubborn world never troubles the owner. These are different workflows. Three of the nine attack passes filed fatals grounded in the Surface reading. No textual surface can reconcile them, because the divergence is between two layers of the kernel; the surface must show whichever one it elaborates to, and it elaborates to the Plan.
