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
`Agentic/Core/Dsl.lean` proves things about the flagship *by `decide`*, which
means the kernel must evaluate `parseAndCheck` on a string; a well-founded
parser would make every one of those theorems unprovable without
`native_decide`, which is forbidden here because it would put
`Lean.ofReduceBool` in the axiom set that `Agentic/Core/Certify.lean` pins.
Recursion on a budget is structural recursion on `Nat`, and it reduces.

The budget is the input's length, and every step of both passes consumes at
least one item, so the exhausted branch is unreachable. That it is unreachable
is *not proved* — see the failed-morphism note in `Agentic/Core/Dsl.lean` — so
it returns a diagnosis like any other failure rather than a `panic!`.

`define` is expanded here, by textual substitution into prompt chunks, so the
raw syntax the checker sees mentions only names a checker can resolve. Adjacent
literal chunks are fused afterwards (`Prompt.normalize`), which is what makes a
prompt assembled from three macros one string rather than three.
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
  /-- One of `{ } [ ] ( ) , = @`. -/
  | punct (c : Char)
  /-- `->`, which separates an arm's tag from its block. -/
  | arrow
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
  | .arrow => "->"

/-! ## The lexer -/

private def isIdentStart (c : Char) : Bool := c.isAlpha || c == '_'

private def isIdentCont (c : Char) : Bool := c.isAlpha || c.isDigit || c == '_'

private def punctChars : List Char := ['{', '}', '[', ']', '(', ')', ',', '=', '@']

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

/-- The lexer proper. Comments run from `--` to the end of the line; `->` is the
one two-character lexeme. -/
private def lexAux : Nat → List Char → Pos → List Tok → Except CheckError (List Tok)
  | 0, _, p, _ => .error ⟨p, "internal: lexer budget exhausted", ""⟩
  | _ + 1, [], _, acc => .ok acc.reverse
  | fuel + 1, c :: cs, p, acc =>
    if c == '\n' then lexAux fuel cs ⟨p.line + 1, 1⟩ acc
    else if c == ' ' || c == '\t' || c == '\r' then lexAux fuel cs ⟨p.line, p.col + 1⟩ acc
    else if c == '-' then
      match cs with
      | '-' :: cs' => lexAux fuel (cs'.dropWhile (fun d => d != '\n')) p acc
      | '>' :: cs' => lexAux fuel cs' ⟨p.line, p.col + 2⟩ (⟨.arrow, p⟩ :: acc)
      | _ => .error ⟨p, "stray `-`; `--` begins a comment and `->` an arm", "-"⟩
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

private def expectArrow (ts : List Tok) : Except CheckError (List Tok) :=
  match ts with
  | ⟨.arrow, _⟩ :: rest => .ok rest
  | _ => .error (unexpected ts "`->`")

private def expectKw (k : String) (ts : List Tok) : Except CheckError (List Tok) :=
  match ts with
  | ⟨.ident k', _⟩ :: rest =>
    if k' == k then .ok rest else .error (unexpected ts s!"`{k}`")
  | _ => .error (unexpected ts s!"`{k}`")

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

/-- `ask ::= [sig] "ask" code target prompt`, with `sig ::= "@model" string`. -/
private def parseAsk (defs : List (String × Prompt)) (ts : List Tok) :
    Except CheckError (RawAsk × List Tok) := do
  let (model, ts) : Option String × List Tok ←
    match ts with
    | ⟨.punct '@', _⟩ :: rest => do
      let rest ← expectKw "model" rest
      let (m, rest) ← expectPlainStr rest
      .ok (some m, rest)
    | _ => .ok (none, ts)
  let p := posOf ts
  let ts ← expectKw "ask" ts
  let (cname, ts) ← expectIdent ts
  let code : Code ←
    match codeOfName cname with
    | some c => .ok c
    | none => .error ⟨p, "expected an answer kind: `text`, `verdict`, `flag` or `ack`", cname⟩
  let (tgt, ts) ← parseTarget ts
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

/-- `rhs ::= ask | panel` -/
private def parseRhs (defs : List (String × Prompt)) (ts : List Tok) :
    Except CheckError (RawRhs × List Tok) := do
  match ts with
  | ⟨.ident "panel", p⟩ :: rest => do
    let rest ← expectPunct '[' rest
    let (ms, rest) ← parsePanelMembers (rest.length + 1) defs rest
    let rest ← expectPunct ']' rest
    .ok (.panel ms p, rest)
  | _ => do
    let (a, ts) ← parseAsk defs ts
    .ok (.ask a, ts)

/-- `block ::= {stmt} tail`.

The budget decreases at every nested block and at every statement; a block
nested `n` deep and `m` statements long needs `n + m` of it, and the caller
supplies the token count, which bounds both. -/
private def parseBlock : Nat → List (String × Prompt) → List Tok →
    Except CheckError (RawBlock × List Tok)
  | 0, _, ts => .error ⟨posOf ts, "internal: parser budget exhausted", ""⟩
  | fuel + 1, defs, ts =>
    match ts with
    | ⟨.ident "let", p⟩ :: rest => do
      let (x, rest) ← expectIdent rest
      let rest ← expectPunct '=' rest
      let (rhs, rest) ← parseRhs defs rest
      let (b, rest) ← parseBlock fuel defs rest
      .ok (.bind x rhs b p, rest)
    | ⟨.ident "done", p⟩ :: rest => .ok (.done p, rest)
    | ⟨.ident "act", p⟩ :: rest => do
      let (tgt, rest) ← parseTarget rest
      let (pr, rest) ← expectStr rest
      .ok (.act tgt (prompt defs pr) p, rest)
    | ⟨.ident "case", p⟩ :: rest => do
      let (x, rest) ← expectIdent rest
      let rest ← expectPunct '{' rest
      -- The arms, whose *shape* is the branching: `FinEnum` demands every arm,
      -- so a source text that omits one is rejected here rather than carried
      -- into a term that could not represent the omission anyway.
      match rest with
      | ⟨.ident "yes", _⟩ :: _ => do
        let rest ← expectKw "yes" rest
        let rest ← expectArrow rest
        let rest ← expectPunct '{' rest
        let (y, rest) ← parseBlock fuel defs rest
        let rest ← expectPunct '}' rest
        let rest ← expectKw "no" rest
        let rest ← expectArrow rest
        let rest ← expectPunct '{' rest
        let (n, rest) ← parseBlock fuel defs rest
        let rest ← expectPunct '}' rest
        let rest ← expectPunct '}' rest
        .ok (.caseFlag x y n p, rest)
      | ⟨.ident "approve", _⟩ :: _ => do
        let rest ← expectKw "approve" rest
        let rest ← expectArrow rest
        let rest ← expectPunct '{' rest
        let (a, rest) ← parseBlock fuel defs rest
        let rest ← expectPunct '}' rest
        let rest ← expectKw "object" rest
        let rest ← expectArrow rest
        let rest ← expectPunct '{' rest
        let (o, rest) ← parseBlock fuel defs rest
        let rest ← expectPunct '}' rest
        let rest ← expectKw "declined" rest
        let rest ← expectArrow rest
        let rest ← expectPunct '{' rest
        let (d, rest) ← parseBlock fuel defs rest
        let rest ← expectPunct '}' rest
        let rest ← expectPunct '}' rest
        .ok (.caseVerdict x a o d p, rest)
      | _ =>
        .error (unexpected rest
          "the arms of a branching: `yes` and `no` for a flag, or `approve`, `object` \
           and `declined` for a verdict")
    | ⟨.ident "revising", p⟩ :: rest => do
      let (subject, rest) ← expectIdent rest
      let rest ← expectKw "upto" rest
      let (n, rest) ← expectNat rest
      -- check (x) { rhs }
      let rest ← expectKw "check" rest
      let rest ← expectPunct '(' rest
      let (cv, rest) ← expectIdent rest
      let rest ← expectPunct ')' rest
      let rest ← expectPunct '{' rest
      let (chk, rest) ← parseRhs defs rest
      let rest ← expectPunct '}' rest
      -- with (x, why) { ask }
      let rest ← expectKw "with" rest
      let rest ← expectPunct '(' rest
      let (av, rest) ← expectIdent rest
      let rest ← expectPunct ',' rest
      let (wv, rest) ← expectIdent rest
      let rest ← expectPunct ')' rest
      let rest ← expectPunct '{' rest
      let (rev, rest) ← parseRhs defs rest
      let rest ← expectPunct '}' rest
      -- accepted (x) { block }
      let rest ← expectKw "accepted" rest
      let rest ← expectPunct '(' rest
      let (pv, rest) ← expectIdent rest
      let rest ← expectPunct ')' rest
      let rest ← expectPunct '{' rest
      let (acc, rest) ← parseBlock fuel defs rest
      let rest ← expectPunct '}' rest
      -- exhausted { block }
      let rest ← expectKw "exhausted" rest
      let rest ← expectPunct '{' rest
      let (exh, rest) ← parseBlock fuel defs rest
      let rest ← expectPunct '}' rest
      .ok (.revising subject n cv chk av wv rev pv acc exh p, rest)
    | ⟨.ident "ask", p⟩ :: _ =>
      .error ⟨p, "a block ends in `done` or `act`; this one ends with an answer, and a closed \
                 workflow has nowhere to return one", "ask"⟩
    | ⟨.ident "panel", p⟩ :: _ =>
      .error ⟨p, "a block ends in `done` or `act`; this one ends with an answer, and a closed \
                 workflow has nowhere to return one", "panel"⟩
    | ⟨.punct '@', p⟩ :: _ =>
      .error ⟨p, "a block ends in `done` or `act`; this one ends with an answer, and a closed \
                 workflow has nowhere to return one", "@"⟩
    | _ =>
      .error (unexpected ts
        "a statement (`let`) or a tail (`done`, `act`, `case`, `revising`)")

/-- `{define}` — the macro preamble. -/
private def parseDefines : Nat → List (String × Prompt) → List Tok →
    Except CheckError (List (String × Prompt) × List Tok)
  | 0, defs, ts => .ok (defs, ts)
  | fuel + 1, defs, ts =>
    match ts with
    | ⟨.ident "define", _⟩ :: rest => do
      let (x, rest) ← expectIdent rest
      let rest ← expectPunct '=' rest
      let (pr, rest) ← expectStr rest
      parseDefines fuel (defs ++ [(x, prompt defs pr)]) rest
    | _ => .ok (defs, ts)

/-- `[[parse s]]` = the raw syntax `s` writes, or the first thing in `s` that is
not syntax. -/
def parse (s : String) : Except CheckError Raw := do
  let ts ← lex s
  let (defs, ts) ← parseDefines (ts.length + 1) [] ts
  let ts ← expectKw "workflow" ts
  let ts ← expectPunct '{' ts
  let (b, ts) ← parseBlock (ts.length + 1) defs ts
  let ts ← expectPunct '}' ts
  match ts with
  | [] => .ok b
  | _ => .error (unexpected ts "the end of the source after the workflow")

end Agentic.Core.Dsl
