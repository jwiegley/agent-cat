import Agentic.Core.Dsl.Syntax

/-!
# The parser: source text to raw syntax

Stage 3, part two. A lexer and a recursive-descent parser, no dependencies
beyond the raw syntax, total, returning `Except CheckError` with a position and
an expected-token message on failure.

**Both passes recurse on a `Nat` budget, and that is a requirement rather than
a shortcut.** Neither pass recurses on a structurally smaller argument — a lexer
consumes a prefix of a character list and a parser consumes a prefix of a token
list, and neither prefix is a subterm — so Lean would compile either as a
well-founded recursion, and `WellFounded.fix` **does not reduce in the kernel**.
`Agentic/Core/DslFlagship.lean` proves things about the flagship *by `decide`*,
which means the kernel must evaluate `parseAndCheck` on a string; a well-founded
parser would make every one of those theorems unprovable without
`native_decide`, which is forbidden here because it would put
`Lean.ofReduceBool` in the axiom set that `Agentic/Core/Certify.lean` pins.
Recursion on a budget is structural recursion on `Nat`, and it reduces.

The budget is the input's length, and every step of both passes consumes at
least one item, so the exhausted branch is unreachable. That it is unreachable
is *not proved* — see the failed-morphism note in
`Agentic/Core/DslFlagship.lean` — so it returns a diagnosis like any other
failure rather than a `panic!`.

`define` is expanded here, by textual substitution into prompt chunks, so the
raw syntax the checker sees mentions only names a checker can resolve. Empty
literal chunks are dropped afterwards (`Prompt.normalize`); adjacent ones are
deliberately *not* fused, for the reason that function's docstring gives.

**One structural rule, and the grammar is its consequences.** A scope is a pair
of braces and `parseBlockFrom` is the one function that closes them, so
indentation means nothing anywhere; a name is introduced by a word that says a
name is being introduced (`define`, `let`, `given`), so no construct binds
silently; and a block is a list of statements that may end in a tail, so a block
which runs out is over and `{ }` is the way to write doing nothing.
-/

namespace Agentic.Core.Dsl

/-! ## Tokens -/

/-- `[[Token]]` = one lexeme. Keywords are not distinguished from identifiers:
the language has no reserved words, only positions at which a particular word is
expected, which keeps the lexer a function of characters alone. -/
inductive Token where
  /-- A name, or a word used as a keyword. -/
  | ident (s : String)
  /-- A string literal, already split into chunks and macro-expanded. -/
  | str (p : Prompt)
  /-- A numeral. -/
  | num (n : Nat)
  /-- One of `{ } [ ] , =`: a scope, a list, a separator, a binding. -/
  | punct (c : Char)
  deriving Repr, Inhabited

/-- `[[Tok]]` = a lexeme and where it was written. -/
structure Tok where
  /-- The lexeme. -/
  tok : Token
  /-- Where it begins. -/
  pos : Pos
  deriving Repr, Inhabited

/-- How a token is quoted back in a diagnosis. -/
def Token.excerpt : Token → String
  | .ident s => s
  | .str _ => "\"…\""
  | .num n => toString n
  | .punct c => String.ofList [c]

/-! ## The lexer -/

private def isIdentStart (c : Char) : Bool := c.isAlpha || c == '_'

private def isIdentCont (c : Char) : Bool := c.isAlpha || c.isDigit || c == '_'

private def punctChars : List Char := ['{', '}', '[', ']', ',', '=']

private def natOfDigits (ds : List Char) : Nat :=
  ds.foldl (fun n d => n * 10 + (d.toNat - 48)) 0

/-- A pending run of literal characters, pushed onto the chunk accumulator. -/
private def flushLit (acc : List Char) (chunks : Prompt) : Prompt :=
  if acc.isEmpty then chunks else Chunk.lit (String.ofList acc.reverse) :: chunks

/-- Scan the body of a string literal, the opening quote already consumed.
Returns the chunks in source order, the rest of the input, and the position just
past the closing quote. -/
private def scanString : Nat → List Char → Pos → List Char → Prompt →
    Except CheckError (Prompt × List Char × Pos)
  | 0, _, p, _, _ => .error ⟨p, "internal: lexer budget exhausted inside a string literal", ""⟩
  | _ + 1, [], p, _, _ => .error ⟨p, "unterminated string literal", ""⟩
  | fuel + 1, c :: cs, p, acc, chunks =>
    if c == '"' then
      .ok ((flushLit acc chunks).reverse, cs, ⟨p.line, p.col + 1⟩)
    else if c == '\\' then
      match cs with
      | [] => .error ⟨p, "unterminated escape in a string literal", ""⟩
      | e :: cs' =>
        let decoded : Option Char :=
          if e == 'n' then some '\n'
          else if e == 't' then some '\t'
          else if e == 'r' then some '\r'
          else if e == '\\' then some '\\'
          else if e == '"' then some '"'
          else if e == '{' then some '{'
          else if e == '}' then some '}'
          else none
        match decoded with
        | none =>
          .error ⟨p, "unknown escape; the escapes are \\n \\t \\r \\\\ \\\" and the two braces",
            String.ofList ['\\', e]⟩
        | some d => scanString fuel cs' ⟨p.line, p.col + 2⟩ (d :: acc) chunks
    else if c == '{' then
      let name := cs.takeWhile (fun d => d != '}' && d != '"' && d != '\n')
      let rest := cs.drop name.length
      match rest with
      | '}' :: rest' =>
        if name.isEmpty then
          .error ⟨p, "empty interpolation; write a name between the braces", ""⟩
        else
          scanString fuel rest' ⟨p.line, p.col + name.length + 2⟩ []
            (Chunk.interp (String.ofList name) :: flushLit acc chunks)
      | _ => .error ⟨p, "unterminated interpolation: no closing brace", String.ofList name⟩
    else if c == '\n' then
      scanString fuel cs ⟨p.line + 1, 1⟩ (c :: acc) chunks
    else
      scanString fuel cs ⟨p.line, p.col + 1⟩ (c :: acc) chunks

/-- The lexer proper. Comments run from `--` to the end of the line, and there
is no two-character lexeme: every lexeme is a word, a number, a string or one of
six punctuation marks. -/
private def lexAux : Nat → List Char → Pos → List Tok → Except CheckError (List Tok)
  | 0, _, p, _ => .error ⟨p, "internal: lexer budget exhausted", ""⟩
  | _ + 1, [], _, acc => .ok acc.reverse
  | fuel + 1, c :: cs, p, acc =>
    if c == '\n' then lexAux fuel cs ⟨p.line + 1, 1⟩ acc
    else if c == ' ' || c == '\t' || c == '\r' then lexAux fuel cs ⟨p.line, p.col + 1⟩ acc
    else if c == '-' then
      match cs with
      | '-' :: cs' => lexAux fuel (cs'.dropWhile (fun d => d != '\n')) p acc
      | _ => .error ⟨p, "stray `-`; `--` begins a comment, and nothing else in the language \
                        begins with one", "-"⟩
    else if c == '"' then
      match scanString (fuel + 1) cs ⟨p.line, p.col + 1⟩ [] [] with
      | .error e => .error e
      | .ok (pr, cs', p') => lexAux fuel cs' p' (⟨.str pr, p⟩ :: acc)
    else if c.isDigit then
      let ds := (c :: cs).takeWhile Char.isDigit
      lexAux fuel ((c :: cs).drop ds.length) ⟨p.line, p.col + ds.length⟩
        (⟨.num (natOfDigits ds), p⟩ :: acc)
    else if isIdentStart c then
      let ids := (c :: cs).takeWhile isIdentCont
      lexAux fuel ((c :: cs).drop ids.length) ⟨p.line, p.col + ids.length⟩
        (⟨.ident (String.ofList ids), p⟩ :: acc)
    else if punctChars.contains c then
      lexAux fuel cs ⟨p.line, p.col + 1⟩ (⟨.punct c, p⟩ :: acc)
    else
      .error ⟨p, "unexpected character", String.ofList [c]⟩

/-- `[[lex s]]` = the lexemes of `s`, in order, or the first thing that is not
one. The budget is the character count, and every step consumes at least one
character. -/
def lex (s : String) : Except CheckError (List Tok) :=
  let cs := s.toList
  lexAux (cs.length + 1) cs ⟨1, 1⟩ []

/-! ## Token-level helpers -/

/-- The token list, as a source of positions. -/
private def posOf : List Tok → Pos
  | [] => ⟨0, 0⟩
  | t :: _ => t.pos

/-- The uniform "expected X" diagnosis. -/
private def unexpected (ts : List Tok) (what : String) : CheckError :=
  match ts with
  | [] => ⟨⟨0, 0⟩, s!"expected {what}, but the source ended", ""⟩
  | t :: _ => ⟨t.pos, s!"expected {what}", t.tok.excerpt⟩

private def expectPunct (c : Char) (ts : List Tok) : Except CheckError (List Tok) :=
  match ts with
  | ⟨.punct c', _⟩ :: rest =>
    if c' == c then .ok rest else .error (unexpected ts s!"`{String.ofList [c]}`")
  | _ => .error (unexpected ts s!"`{String.ofList [c]}`")

private def expectKw (k : String) (ts : List Tok) : Except CheckError (List Tok) :=
  match ts with
  | ⟨.ident k', _⟩ :: rest =>
    if k' == k then .ok rest else .error (unexpected ts s!"`{k}`")
  | _ => .error (unexpected ts s!"`{k}`")

/-- A keyword whose absence deserves more than its own name: the whole clause
that was expected, spelled out. Used where the missing word is the head of a
construct a reader has to be told the *shape* of — the two outcome clauses of a
bounded revision — rather than a word they can see is missing. -/
private def expectKwSaying (k : String) (what : String) (ts : List Tok) :
    Except CheckError (List Tok) :=
  match ts with
  | ⟨.ident k', _⟩ :: rest =>
    if k' == k then .ok rest else .error (unexpected ts what)
  | _ => .error (unexpected ts what)

/-- The opening brace of a block, and where it is. The position is kept because
an empty block has no other token of its own to be diagnosed at, and because
`{ }` is where a reader looks to see what did not happen. -/
private def expectOpen (ts : List Tok) : Except CheckError (Pos × List Tok) :=
  match ts with
  | ⟨.punct '{', p⟩ :: rest => .ok (p, rest)
  | _ => .error (unexpected ts "`{`")

/-- The closing brace of a block, after its tail. A tail is the last thing in
its block — each arm and each outcome *is* the rest of the workflow — so the
diagnosis says that rather than naming a brace. -/
private def expectBlockEnd (ts : List Tok) : Except CheckError (List Tok) :=
  match ts with
  | ⟨.punct '}', _⟩ :: rest => .ok rest
  | _ =>
    .error (unexpected ts
      "`}`: `act`, `if`, `case` and `revising` are tails, and a tail ends its block — \
       each arm and each outcome is the rest of the workflow")

private def expectIdent (ts : List Tok) : Except CheckError (String × List Tok) :=
  match ts with
  | ⟨.ident x, _⟩ :: rest => .ok (x, rest)
  | _ => .error (unexpected ts "a name")

private def expectNat (ts : List Tok) : Except CheckError (Nat × List Tok) :=
  match ts with
  | ⟨.num n, _⟩ :: rest => .ok (n, rest)
  | _ => .error (unexpected ts "a number")

private def expectStr (ts : List Tok) : Except CheckError (Prompt × List Tok) :=
  match ts with
  | ⟨.str p, _⟩ :: rest => .ok (p, rest)
  | _ => .error (unexpected ts "a string literal")

/-- A string literal used as a *name* — an addressee's identifier — which must
therefore mention nothing in scope. -/
private def expectPlainStr (ts : List Tok) : Except CheckError (String × List Tok) := do
  let (p, rest) ← expectStr ts
  match Prompt.closed p with
  | some s => .ok (s, rest)
  | none => .error ⟨posOf ts, "an addressee's name is written, not computed: no interpolation here", ""⟩

/-! ## `define`: textual macros, expanded here -/

/-- `[[expand defs p]]` = `p` with every `{x}` naming a macro replaced by the
macro's chunks. Macros are expanded when they are defined, against the macros
before them, so one pass suffices and a macro cannot refer to itself. -/
private def expand (defs : List (String × Prompt)) : Prompt → Prompt
  | [] => []
  | .lit s :: rest => .lit s :: expand defs rest
  | .interp x :: rest =>
    match defs.find? (fun d => d.1 == x) with
    | some d => d.2 ++ expand defs rest
    | none => .interp x :: expand defs rest

private def prompt (defs : List (String × Prompt)) (p : Prompt) : Prompt :=
  Prompt.normalize (expand defs p)

/-! ## The grammar -/

/-- `target ::= ("model" | "tool" | "person") string ["draw" nat]` -/
private def parseTarget (ts : List Tok) : Except CheckError (RawTarget × List Tok) := do
  match ts with
  | ⟨.ident k, p⟩ :: rest =>
    let mk : String → Addressee ←
      if k == "model" then .ok Addressee.model
      else if k == "tool" then .ok Addressee.tool
      else if k == "person" then .ok Addressee.person
      else .error ⟨p, "expected an addressee: `model`, `tool` or `person`", k⟩
    let (name, rest) ← expectPlainStr rest
    match rest with
    | ⟨.ident "draw", _⟩ :: rest' => do
      let (n, rest') ← expectNat rest'
      .ok (⟨mk name, n⟩, rest')
    | _ => .ok (⟨mk name, 0⟩, rest)
  | _ => .error (unexpected ts "an addressee: `model`, `tool` or `person`")

/-- `ask ::= "ask" target ["using" "model" string] "for" code string`.

Three prepositions, in the order a reader needs them: *who* is asked, *which
model serves it*, *what kind of answer* is wanted, and then the words. The kind
sits between the addressee's name and the prompt, so no two string literals are
ever adjacent in an `ask` and nobody has to know an arity to see where the
phrase ends. -/
private def parseAsk (defs : List (String × Prompt)) (ts : List Tok) :
    Except CheckError (RawAsk × List Tok) := do
  let p := posOf ts
  let ts ← expectKw "ask" ts
  let (tgt, ts) ← parseTarget ts
  let (model, ts) : Option String × List Tok ←
    match ts with
    | ⟨.ident "using", _⟩ :: rest => do
      let rest ← expectKw "model" rest
      let (m, rest) ← expectPlainStr rest
      .ok (some m, rest)
    | _ => .ok (none, ts)
  let ts ← expectKw "for" ts
  let kp := posOf ts
  let (cname, ts) ← expectIdent ts
  let code : Code ←
    match codeOfName cname with
    | some c => .ok c
    | none => .error ⟨kp, "expected an answer kind: `text`, `verdict`, `flag` or `ack`", cname⟩
  -- The one order the grammar fixes and a reader can get wrong. `using model`
  -- says *who serves* the addressee, so it belongs beside the addressee and
  -- before `for`; written after the kind it would put two string literals side
  -- by side, which is the adjacency the phrase order exists to prevent.
  let ts ← match ts with
    | ⟨.ident "using", up⟩ :: _ =>
      .error ⟨up, "`using model` says which model serves the addressee, so it is written \
                  beside the addressee and before `for`: \
                  `ask <addressee> \"name\" using model \"m\" for <kind> \"words\"`", "using"⟩
    | _ => .ok ts
  let (pr, ts) ← expectStr ts
  .ok (⟨model, code, tgt, prompt defs pr, p⟩, ts)

/-- `panel ::= "panel" "[" ask {"," ask} "]"` -/
private def parsePanelMembers : Nat → List (String × Prompt) → List Tok →
    Except CheckError (List RawAsk × List Tok)
  | 0, _, ts => .error ⟨posOf ts, "internal: parser budget exhausted in a panel", ""⟩
  | fuel + 1, defs, ts => do
    let (a, ts) ← parseAsk defs ts
    match ts with
    | ⟨.punct ',', _⟩ :: rest => do
      let (as, ts) ← parsePanelMembers fuel defs rest
      .ok (a :: as, ts)
    | _ => .ok ([a], ts)

/-- `rhs ::= ask | panel`.

A bounded revision is refused here by name. It is the one construct a reader
might reasonably try to bind — it produces an artefact — and it cannot be bound:
`Plan.revising` yields an `Option (El c)`, which `Ctx = List Code` has no room
for, so its result is consumed by two outcome clauses rather than by a name. -/
private def parseRhs (defs : List (String × Prompt)) (ts : List Tok) :
    Except CheckError (RawRhs × List Tok) := do
  match ts with
  | ⟨.ident "panel", p⟩ :: rest => do
    let rest ← expectPunct '[' rest
    let (ms, rest) ← parsePanelMembers (rest.length + 1) defs rest
    let rest ← expectPunct ']' rest
    .ok (.panel ms p, rest)
  | ⟨.ident "revising", p⟩ :: _ =>
    .error ⟨p, "a bounded revision has two outcomes and is not an answer to bind: write its \
               `approved given …` and `never approved` clauses after its braces", "revising"⟩
  | _ => do
    let (a, ts) ← parseAsk defs ts
    .ok (.ask a, ts)

/-- `rhs` in braces, which is what a `check` or `revise` clause carries. Written
`{ rhs }` rather than bare so that the clause can be relaxed later to a block
without moving a character of what exists. -/
private def parseBracedRhs (defs : List (String × Prompt)) (ts : List Tok) :
    Except CheckError (RawRhs × List Tok) := do
  let ts ← expectPunct '{' ts
  let (r, ts) ← parseRhs defs ts
  let ts ← expectPunct '}' ts
  .ok (r, ts)

/-- `block ::= "{" {binding} [tail] "}"`, the opening brace already consumed and
its position passed in as `opos`.

**The block consumes its own closing brace**, and the empty block is what a
block that runs out of statements is, so `{ }` does nothing and needs no word to
say so. `opos` is where that nothing is written.

The budget decreases at every nested block and at every statement; a block
nested `n` deep and `m` statements long needs `n + m` of it, and the caller
supplies the token count, which bounds both. -/
private def parseBlockFrom : Nat → List (String × Prompt) → Pos → List Tok →
    Except CheckError (RawBlock × List Tok)
  | 0, _, _, ts => .error ⟨posOf ts, "internal: parser budget exhausted", ""⟩
  | fuel + 1, defs, opos, ts =>
    match ts with
    | ⟨.ident "let", p⟩ :: rest => do
      let (x, rest) ← expectIdent rest
      let rest ← expectPunct '=' rest
      let (rhs, rest) ← parseRhs defs rest
      let (b, rest) ← parseBlockFrom fuel defs opos rest
      .ok (.bind x rhs b p, rest)
    | ⟨.punct '}', _⟩ :: rest => .ok (.empty opos, rest)
    | ⟨.ident "act", p⟩ :: rest => do
      let (tgt, rest) ← parseTarget rest
      let (pr, rest) ← expectStr rest
      let rest ← expectBlockEnd rest
      .ok (.act tgt (prompt defs pr) p, rest)
    | ⟨.ident "if", p⟩ :: rest => do
      let (x, rest) ← expectIdent rest
      let (o, rest) ← expectOpen rest
      let (y, rest) ← parseBlockFrom fuel defs o rest
      let rest ← expectKw "else" rest
      let (o', rest) ← expectOpen rest
      let (n, rest) ← parseBlockFrom fuel defs o' rest
      let rest ← expectBlockEnd rest
      .ok (.ifFlag x y n p, rest)
    | ⟨.ident "case", p⟩ :: rest => do
      let (x, rest) ← expectIdent rest
      let rest ← expectPunct '{' rest
      -- The arms, whose *shape* is the branching: `FinEnum` demands every arm,
      -- so a source text that omits one is rejected here rather than carried
      -- into a term that could not represent the omission anyway. `if` takes
      -- the two-valued branching, so `case` is a verdict's three tags and
      -- nothing else.
      let rest ← expectKwSaying "approve"
        "the arms of a verdict branching, all three: `approve`, `object` and `declined` \
         (a two-way branching on a flag is `if … else`)" rest
      let (o1, rest) ← expectOpen rest
      let (a, rest) ← parseBlockFrom fuel defs o1 rest
      let rest ← expectKw "object" rest
      let (o2, rest) ← expectOpen rest
      let (o, rest) ← parseBlockFrom fuel defs o2 rest
      let rest ← expectKw "declined" rest
      let (o3, rest) ← expectOpen rest
      let (d, rest) ← parseBlockFrom fuel defs o3 rest
      let rest ← expectPunct '}' rest
      let rest ← expectBlockEnd rest
      .ok (.caseVerdict x a o d p, rest)
    | ⟨.ident "revising", p⟩ :: rest => do
      let (subject, rest) ← expectIdent rest
      let rest ← expectKw "up" rest
      let rest ← expectKw "to" rest
      let (n, rest) ← expectNat rest
      -- Both spellings of the noun, so that `up to 1 revision` is English. The
      -- unit is named where the numeral is because the numeral is the one thing
      -- three independent readers of `Plan.revising` got backwards.
      let rest ← match rest with
        | ⟨.ident "revisions", _⟩ :: r => .ok r
        | ⟨.ident "revision", _⟩ :: r => .ok r
        | _ => .error (unexpected rest "`revisions`, the unit the numeral counts")
      -- The loop's own braces hold exactly the loop: `check` and `revise` are
      -- `Plan.revising`'s two continuations. The two outcomes belong to the
      -- graft and are written outside them.
      let rest ← expectPunct '{' rest
      let rest ← expectKw "check" rest
      let rest ← expectKw "given" rest
      let (cv, rest) ← expectIdent rest
      let (chk, rest) ← parseBracedRhs defs rest
      let rest ← expectKwSaying "revise"
        "`revise given <artefact>, <why> { … }`: a bounded revision says how a rejected \
         candidate is rewritten" rest
      let rest ← expectKw "given" rest
      let (av, rest) ← expectIdent rest
      let rest ← expectPunct ',' rest
      let (wv, rest) ← expectIdent rest
      let (rev, rest) ← parseBracedRhs defs rest
      let rest ← expectPunct '}' rest
      -- approved given x { block }
      let rest ← expectKwSaying "approved"
        "`approved given <name> { … }`: a bounded revision writes both of its outcomes" rest
      let rest ← expectKw "given" rest
      let (pv, rest) ← expectIdent rest
      let (o1, rest) ← expectOpen rest
      let (acc, rest) ← parseBlockFrom fuel defs o1 rest
      -- never approved { block }
      let rest ← expectKwSaying "never"
        "`never approved { … }`: a bounded revision writes both of its outcomes, and this \
         is the one in which there is no artefact to hand over" rest
      let rest ← expectKw "approved" rest
      let (o2, rest) ← expectOpen rest
      let (exh, rest) ← parseBlockFrom fuel defs o2 rest
      let rest ← expectBlockEnd rest
      .ok (.revising subject n cv chk av wv rev pv acc exh p, rest)
    | ⟨.ident "ask", p⟩ :: _ =>
      .error ⟨p, "a question here has nowhere to put its answer: write `let x = ask …`, \
                 or `act` if the point is the doing", "ask"⟩
    | ⟨.ident "panel", p⟩ :: _ =>
      .error ⟨p, "a question here has nowhere to put its answer: write `let x = panel …`, \
                 or `act` if the point is the doing", "panel"⟩
    | _ =>
      .error (unexpected ts
        "a statement (`let`), a tail (`act`, `if`, `case`, `revising`), or `}`")

/-- `block ::= "{" {binding} [tail] "}"`, braces and all. -/
private def parseBlock (fuel : Nat) (defs : List (String × Prompt)) (ts : List Tok) :
    Except CheckError (RawBlock × List Tok) := do
  let (o, ts) ← expectOpen ts
  parseBlockFrom fuel defs o ts

/-- `{define}` — the macro preamble, with a caller's overrides.

An override *replaces the right-hand side of a `define` the program wrote*, at
the point the program writes it, so a name means one thing throughout and later
macros that mention it see the override. It does not introduce a name: a program
that never wrote `define x` has no `x` to override, and `parseWith` refuses the
attempt rather than quietly turning some `{x}` that meant a let-bound answer
into a constant. -/
private def parseDefines (ov : List (String × Prompt)) :
    Nat → List (String × Prompt) → List Tok →
    Except CheckError (List (String × Prompt) × List Tok)
  | 0, defs, ts => .ok (defs, ts)
  | fuel + 1, defs, ts =>
    match ts with
    | ⟨.ident "define", _⟩ :: rest => do
      let (x, rest) ← expectIdent rest
      let rest ← expectPunct '=' rest
      let (pr, rest) ← expectStr rest
      let body := match ov.find? (fun o => o.1 == x) with
        | some o => o.2
        | none => prompt defs pr
      parseDefines ov fuel (defs ++ [(x, body)]) rest
    | _ => .ok (defs, ts)

/-- `[[parseWith ov s]]` = the raw syntax `s` writes when each `define` named in
`ov` is given the words `ov` gives it, or the first thing in `s` that is not
syntax.

**A runtime parameter, and why it is one.** A program that hardcodes
`define spec = "harden the parser"` can only ever be run against that
specification; `--define spec="harden the CSV reader"` lets the same checked
program name a real target. The substitution happens *at load time*, before the
checker ever sees a term, so nothing downstream can tell an overridden program
from one written that way — which is exactly the property that keeps every
theorem about the language true of it.

**The no-override path is not merely equivalent, it is the same function.**
`parse` below is `parseWith []`, and `List.find?` on the empty list is `none`,
so a run that overrides nothing takes the identical code path and builds the
identical term (`parse_eq_parseWith_nil`). That is what makes the flagship's
`decide +kernel` proofs unaffected by this feature's existence.

**An override nobody asked for is an error.** A name the program does not define
is a mistake — a typo, or a program that has moved on — and guessing what it
was meant to say is the discipline this package refuses everywhere else, so it
is reported with the name quoted. -/
def parseWith (ov : List (String × Prompt)) (s : String) : Except CheckError Raw := do
  let ts ← lex s
  let (defs, rest) ← parseDefines ov (ts.length + 1) [] ts
  match ov.find? (fun o => !defs.any (fun d => d.1 == o.1)) with
  | some o =>
    -- Pointed at the end of the preamble, which is where the missing `define`
    -- would have had to be written.
    .error ⟨posOf rest, s!"this program has no `define {o.1}` to override", o.1⟩
  | none => do
    let ts ← expectKw "workflow" rest
    let (b, ts) ← parseBlock (ts.length + 1) defs ts
    match ts with
    | [] => .ok b
    | _ => .error (unexpected ts "the end of the source after the workflow")

/-- `[[parse s]]` = the raw syntax `s` writes, or the first thing in `s` that is
not syntax. -/
def parse (s : String) : Except CheckError Raw := parseWith [] s

/-- **Overriding nothing is parsing.** Stated rather than assumed, because every
proved fact about the flagship is a fact about `parse` and this is what says the
override machinery did not move it. -/
theorem parse_eq_parseWith_nil (s : String) : parse s = parseWith [] s := rfl

end Agentic.Core.Dsl
