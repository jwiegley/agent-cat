CONSOLIDATED REVIEW FINDINGS RELEVANT TO SURFACE DESIGN (from 7 independent passes, 93 raw findings)

1. BRANCHING IS HIDDEN (3 passes, highest convergence). Plan.case wears three
   unrelated spellings: `if x {..} else {..}`, `case x {approve.. object.. declined..}`,
   and `approved given p {..} never approved {..}`. The third has no branching
   keyword, no scrutinee, no shared brace pair: the two arms are SIBLING
   STATEMENTS 28 lines after the `revising` they belong to, at the same
   indentation, joined by nothing lexical (unlike `else`, which is adjacent to
   its brace). The owner read them as replies to the preceding ask — the
   layout's own suggestion, not a misreading. Cure demanded by reviewers: every
   case node gets ONE spelling with a scrutinee and arms inside one brace pair.

2. THE REVISING CONSTRUCT IS A FROZEN LIBRARY IDIOM. Plan.revising (a derived
   combinator, not a former) is hard-coded as an 11-positional-field Raw
   constructor, six dedicated keywords, 45-line parse clause, 35-line check
   clause, and a clause category (braced single-RHS) that exists nowhere else
   and whose braces are speculative. Three DIFFERENT binders are all spelled
   `patch` in the flagship (check's candidate, revise's candidate, approved's
   result — de Bruijn 0 of three different contexts); the revise clause's value
   becomes the next candidate with nothing in the text saying so; `revise` vs
   `revising` collide (the library's own name for the continuation is
   `redraft`); `revise given x, x` is accepted and silently shadows the
   objection binder so the reviser never sees why it failed.

3. {name} MEANS TWO THINGS. A parse-time textual macro (`define`) and a runtime
   answer splice share one syntax. Which one it is DECIDES THE RUNG (askC/batch
   vs ask/pipeline). A define silently captures any later let/given binder of
   the same spelling (turning a data-flowing ask into a constant one, breaking
   revision loops with no diagnostic); duplicate defines are first-wins
   silently; forward references degrade to misleading unbound-name errors at
   the wrong position; expansion is eagerly exponential (2^N chunks) with no
   budget. Reviewers demand: visibly distinct syntax for macro vs answer
   (e.g. $spec vs {patch}), or collision refusal, plus dup/forward-ref refusal.

4. NO MEANING FUNCTION FOR THE SURFACE. The DSL is the only stratum in the
   repository with no [[·]]: its docstrings describe layout, no theorem relates
   check to denote, and surface shape was therefore settled by rubric rather
   than by equation — which is how a case came to be spelled as two sibling
   clauses. The redesign should give each construct a one-line meaning and
   should let surface structure MIRROR denotational structure (a case reads as
   a case, a bind reads as a bind).

5. SMALLER SURFACE DEFECTS, all evidenced: `{ }` carries four unrelated
   meanings (statement block, single-expression clause, case-arm group,
   loop-clause group); `for <kind>` is mandatory in four positions where the
   checker already fixes the kind (the approved Lean surface writes none);
   `using model` is accepted on person/tool addressees where it is inert;
   `ask .. for ack` is legal but binds a value nothing can consume; `up to 2
   revision`/`up to 1 revisions` both parse; act duplicates the ask-for-ack
   mechanism.

6. SEMANTIC TRAPS THE SURFACE SHOULD SURFACE OR FIX: a panel with any
   `declined` member annihilates all objections (why = ""), so the reviser is
   told it failed but not why; the never-approved arm differing between the
   Plan flagship (give up silently) and the owner's approved do-block (ask the
   owner anyway) is an unresolved design question the new surface will have to
   answer explicitly.

7. PREMISE FINDING (alexey): the level<=branch guarantee does not REQUIRE
   textuality — it lives in four Plan-level lemmas; a restricted Lean
   combinator API gets the same theorem without parser/checker, and the parser
   is provably outside the proof boundary (source->Raw is a runtime test, not
   a theorem; the raw syntax was transcribed by hand for the kernel proofs).
   The synthesis must state clearly what the textual surface buys (MCP/CLI,
   non-Lean authors) and what proof story binds text to Plan, and must not
   overclaim ("proved to elaborate to the same plan" is currently unfalsifiable
   because flagshipPlan is DEFINED as the checker's output).

8. THE COMPARISON TARGET IS ON A CONDEMNED CARRIER. example/HardenPatch.lean's
   twelve-line do-block is the style standard, but it is written against the
   superseded pre-Core stratum and its `revising` returns the last artefact
   rather than an Option (hence its unconditional consent ask). The design
   should match its READABILITY, not its carrier or its exhausted-path
   behavior; re-pointing it at Plan is separately tracked (acat-q1i).
