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
which means the kernel must evaluate the checker on raw syntax; a well-founded
parser would make every one of those theorems unprovable without
`native_decide`, which is forbidden here because it would put
`Lean.ofReduceBool` in the axiom set that `Agentic/Core/Certify.lean` pins.
Recursion on a budget is structural recursion on `Nat`, and it reduces.

The budget is the input's length, and every step of both passes consumes at
least one item, so the exhausted branch is unreachable. That it is unreachable
is *not proved* — see the failed-morphism note in
`Agentic/Core/DslFlagship.lean` — so it returns a diagnosis like any other
failure rather than a `panic!`.

## Prompts: two spellings, one meaning

A prompt is a quoted string or a **fenced text block** (three-or-more
backticks; doc/research/dsl-redesign/block-syntax.md is the specification the
scanner below implements): the block's non-blank lines are dedented by their
longest common whitespace prefix, blank lines are kept empty, the lines are
joined with `\n`, and the result is scanned for holes exactly as a string body
is. Either way the token is a `Token.str` and nothing downstream can tell the
spellings apart.

A **hole** is `{name}`, `{name.reasons}` or `{$name}` — an answer spliced at
run time, a verdict's objections rendered at run time, or a define expanded
right here — and nothing else: any other `{` is refused at lex time with the
escape (`\{`) named. `define` is expanded in this module, so the raw syntax the
checker sees mentions only names a checker can resolve; a `{name}` whose name
is a define is refused (*write `{$name}`*), a `{$name}` with no earlier define
is refused, a duplicate `define` is refused, and a define's body may hole only
earlier defines — so expansion always yields literals, no define is cyclic, and
a question is closed exactly when every hole it wrote was a `{$…}`.
-/

namespace Agentic.Core.Dsl

/-! ## Tokens -/

/-- `[[Token]]` = one lexeme. Keywords are not distinguished from identifiers:
the language has no reserved words, only positions at which a particular word is
expected, which keeps the lexer a function of characters alone. -/
inductive Token where
  /-- A name, or a word used as a keyword. -/
  | ident (s : String)
  /-- A string literal or a fenced block, already split into chunks. Defines are
  expanded later, by the parser, which knows the define table. -/
  | str (p : Prompt)
  /-- A numeral. -/
  | num (n : Nat)
  /-- One of `{ } [ ] , = :`. -/
  | punct (c : Char)
  /-- The binding arrow `<-`. -/
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
  | .arrow => "<-"

/-! ## The lexer -/

private def isIdentStart (c : Char) : Bool := c.isAlpha || c == '_'

private def isIdentCont (c : Char) : Bool := c.isAlpha || c.isDigit || c == '_'

private def punctChars : List Char := ['{', '}', '[', ']', ',', '=', ':']

private def natOfDigits (ds : List Char) : Nat :=
  ds.foldl (fun n d => n * 10 + (d.toNat - 48)) 0

/-- A pending run of literal characters, pushed onto the chunk accumulator. -/
private def flushLit (acc : List Char) (chunks : Prompt) : Prompt :=
  if acc.isEmpty then chunks else Chunk.lit (String.ofList acc.reverse) :: chunks

/-- The body of a hole, the opening `{` already consumed: an optional `$`, a
name, an optional `.reasons`, and the closing brace. Returns the stored form —
`x`, `x.reasons` or `$x` — and the characters consumed (braces included).

One grammar for both prompt spellings, enforced at lex time: a `{` that does
not open one of the three hole forms is refused with the escape named, because
the alternative — carrying arbitrary text to the checker as a name — turns a
lexical mistake into a misleading scope error. -/
private def scanHole (p : Pos) (cs : List Char) :
    Except CheckError (String × Nat × List Char) := do
  let (dollar, cs, used) :=
    match cs with
    | '$' :: rest => (true, rest, 1)
    | _ => (false, cs, 0)
  match cs with
  | c :: _ =>
    if isIdentStart c then
      let name := cs.takeWhile isIdentCont
      let cs := cs.drop name.length
      let used := used + name.length
      if dollar then
        match cs with
        | '}' :: rest => .ok ("$" ++ String.ofList name, used + 2, rest)
        | '.' :: _ =>
          .error ⟨p, "a define is literal text and has no `.reasons`; \
                     only an answered verdict does", "$" ++ String.ofList name⟩
        | _ => .error ⟨p, "unterminated hole: no closing brace", String.ofList name⟩
      else
        match cs with
        | '}' :: rest => .ok (String.ofList name, used + 2, rest)
        | '.' :: cs' =>
          let field := cs'.takeWhile isIdentCont
          let cs' := cs'.drop field.length
          if String.ofList field == "reasons" then
            match cs' with
            | '}' :: rest =>
              .ok (String.ofList name ++ ".reasons", used + field.length + 3, rest)
            | _ => .error ⟨p, "unterminated hole: no closing brace", String.ofList name⟩
          else
            .error ⟨p, "the one projection a hole may write is `.reasons`, \
                       a verdict's objections as text", String.ofList field⟩
        | _ => .error ⟨p, "unterminated hole: no closing brace", String.ofList name⟩
    else
      .error ⟨p, "a hole is `{name}`, `{name.reasons}` or `{$define}`; \
                 a literal brace is written `\\{`", ""⟩
  | [] => .error ⟨p, "unterminated hole: the source ended", ""⟩

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
      match scanHole p cs with
      | .error e => .error e
      | .ok (name, used, rest) =>
        scanString fuel rest ⟨p.line, p.col + used + 1⟩ []
          (Chunk.interp name :: flushLit acc chunks)
    else if c == '\n' then
      scanString fuel cs ⟨p.line + 1, 1⟩ (c :: acc) chunks
    else
      scanString fuel cs ⟨p.line, p.col + 1⟩ (c :: acc) chunks

/-! ### Fenced text blocks -/

/-- One raw source line: the characters up to (not including) a newline, the
rest after it, and whether a newline was actually there. A `\r` immediately
before the newline is not part of the line, so CRLF-authored files behave
identically. -/
private def takeLine (cs : List Char) : List Char × List Char × Bool :=
  let line := cs.takeWhile (· != '\n')
  let rest := cs.drop line.length
  let line := match line.getLast? with
    | some '\r' => line.dropLast
    | _ => line
  match rest with
  | '\n' :: rest' => (line, rest', true)
  | _ => (line, rest, false)

private def isWs (c : Char) : Bool := c == ' ' || c == '\t'

/-- Whether a content line closes a fence of `n` backticks: its first
non-whitespace characters are exactly `n` backticks followed by nothing but
whitespace and, optionally, one of `,` `]` `}` — anything else (a longer run, a
word) keeps the line as content, which is what lets a pasted ```` ```haskell ````
live inside a three-backtick block. Returns the characters after the backtick
run when it closes. -/
private def fenceCloses (n : Nat) (line : List Char) : Option (List Char) :=
  let afterWs := line.dropWhile isWs
  let ticks := afterWs.takeWhile (· == '`')
  if ticks.length == n then
    let rest := afterWs.drop n
    let restWs := rest.dropWhile isWs
    match restWs with
    | [] => some rest
    | c :: _ => if c == ',' || c == ']' || c == '}' then some rest else none
  else none

/-- Collect the raw content lines of a fence, given fuel in characters. Returns
the lines, the characters after the closing run (with the newline that ended
the closing line, when there was one, still ahead of them), and the position
just past the run. -/
private def scanFenceLines (n : Nat) (openPos : Pos) :
    Nat → List Char → Nat → List (List Char) →
    Except CheckError (List (List Char) × List Char × Pos)
  | 0, _, _, _ =>
    .error ⟨openPos, "internal: lexer budget exhausted inside a text block", ""⟩
  | _ + 1, [], _, _ =>
    .error ⟨openPos, s!"this fence of {n} backticks is never closed", ""⟩
  | fuel + 1, cs, ln, acc =>
    let (line, rest, hadNl) := takeLine cs
    match fenceCloses n line with
    | some after =>
      -- Lexing resumes right after the run, on the closing line, followed by
      -- whatever `takeLine` set aside (the rest of the input past the line).
      let col := line.length - after.length + 1
      .ok (acc.reverse, after ++ (if hadNl then '\n' :: rest else rest), ⟨ln, col⟩)
    | none =>
      if hadNl then
        scanFenceLines n openPos fuel rest (ln + 1) (line :: acc)
      else
        .error ⟨openPos, s!"this fence of {n} backticks is never closed", ""⟩

/-- The agreement of two whitespace prefixes: their common prefix, refused when
they disagree at a position where both are whitespace (a tab against a space). -/
private def indentMeet (openPos : Pos) : List Char → List Char →
    Except CheckError (List Char)
  | a :: as, b :: bs =>
    if a == b then
      match indentMeet openPos as bs with
      | .error e => .error e
      | .ok r => .ok (a :: r)
    else
      .error ⟨openPos, "this block mixes tabs and spaces in its indentation", ""⟩
  | _, _ => .ok []

/-- The longest common whitespace prefix of the non-blank lines: a dedent that
silently guessed would move text the author aligned, so disagreement between
two whitespace characters is refused rather than resolved. -/
private def commonIndent (openPos : Pos) (lines : List (List Char)) :
    Except CheckError (List Char) :=
  let nonBlank := lines.filter (fun l => !(l.all isWs))
  match nonBlank with
  | [] => .ok []
  | first :: rest =>
    rest.foldlM (init := first.takeWhile isWs) fun acc l =>
      indentMeet openPos acc (l.takeWhile isWs)

/-- Dedent and join: blank lines are emitted empty (their whitespace dropped),
non-blank lines lose the common prefix, and the lines are joined with `\n` —
no trailing newline, because the closing fence's line break is a terminator. -/
private def dedentJoin (indent : List Char) (lines : List (List Char)) : List Char :=
  let strip := fun (l : List Char) =>
    if l.all isWs then [] else l.drop indent.length
  match lines.map strip with
  | [] => []
  | first :: rest => rest.foldl (fun acc l => acc ++ '\n' :: l) first

/-- Scan the dedented content for holes. Exactly two things are special: a hole
(`{…}`, the same grammar the quoted form has) and `\{` for a literal brace;
every other character — quotes, lone backslashes, short backtick runs — is
literal, so pasted Markdown survives verbatim except for `{`. -/
private def scanBlockChunks (openPos : Pos) :
    Nat → List Char → List Char → Prompt → Except CheckError Prompt
  | 0, _, _, _ =>
    .error ⟨openPos, "internal: lexer budget exhausted inside a text block", ""⟩
  | _ + 1, [], acc, chunks => .ok (flushLit acc chunks).reverse
  | fuel + 1, c :: cs, acc, chunks =>
    if c == '\\' then
      match cs with
      | '{' :: cs' => scanBlockChunks openPos fuel cs' ('{' :: acc) chunks
      | _ => scanBlockChunks openPos fuel cs (c :: acc) chunks
    else if c == '{' then
      match scanHole openPos cs with
      | .error e => .error e
      | .ok (name, _, rest) =>
        scanBlockChunks openPos fuel rest [] (Chunk.interp name :: flushLit acc chunks)
    else
      scanBlockChunks openPos fuel cs (c :: acc) chunks

/-- A fenced block, the opening backtick run already counted (`n ≥ 3`) and the
input positioned right after it. The rest of the opening line must be
whitespace; content begins on the next line. -/
private def scanBlock (n : Nat) (openPos : Pos) (cs : List Char) :
    Except CheckError (Prompt × List Char × Pos) := do
  let (line, rest, hadNl) := takeLine cs
  if !(line.all isWs) then
    .error ⟨openPos, "the content of a block begins on the next line: \
                     nothing but whitespace may follow the opening fence", String.ofList line⟩
  else if !hadNl then
    .error ⟨openPos, s!"this fence of {n} backticks is never closed", ""⟩
  else do
    let (lines, after, endPos) ←
      scanFenceLines n openPos (cs.length + 1) rest (openPos.line + 1) []
    let indent ← commonIndent openPos lines
    let content := dedentJoin indent lines
    let chunks ← scanBlockChunks openPos (content.length + 1) content [] []
    .ok (chunks, after, endPos)

/-- The lexer proper. Comments run from `--` to the end of the line; a `<`
begins the arrow `<-` and nothing else; a backtick begins a fence of three or
more and nothing else. -/
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
    else if c == '<' then
      match cs with
      | '-' :: cs' => lexAux fuel cs' ⟨p.line, p.col + 2⟩ (⟨.arrow, p⟩ :: acc)
      | _ => .error ⟨p, "stray `<`; `<-` binds an answer, and nothing else in the language \
                        begins with one", "<"⟩
    else if c == '`' then
      let ticks := (c :: cs).takeWhile (· == '`')
      let n := ticks.length
      if n < 3 then
        .error ⟨p, "a text block opens with three or more backticks", String.ofList ticks⟩
      else
        match scanBlock n p ((c :: cs).drop n) with
        | .error e => .error e
        | .ok (pr, cs', p') => lexAux fuel cs' p' (⟨.str pr, p⟩ :: acc)
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
  | _ => .error (unexpected ts "`<-`")

private def expectKw (k : String) (ts : List Tok) : Except CheckError (List Tok) :=
  match ts with
  | ⟨.ident k', _⟩ :: rest =>
    if k' == k then .ok rest else .error (unexpected ts s!"`{k}`")
  | _ => .error (unexpected ts s!"`{k}`")

/-- A keyword whose absence deserves more than its own name: the whole clause
that was expected, spelled out. -/
private def expectKwSaying (k : String) (what : String) (ts : List Tok) :
    Except CheckError (List Tok) :=
  match ts with
  | ⟨.ident k', _⟩ :: rest =>
    if k' == k then .ok rest else .error (unexpected ts what)
  | _ => .error (unexpected ts what)

/-- The opening brace of a block, and where it is. -/
private def expectOpen (ts : List Tok) : Except CheckError (Pos × List Tok) :=
  match ts with
  | ⟨.punct '{', p⟩ :: rest => .ok (p, rest)
  | _ => .error (unexpected ts "`{`")

/-- The closing brace after a terminal branching. A branching is the last thing
in its block — each arm *is* the rest of the workflow. -/
private def expectBlockEnd (ts : List Tok) : Except CheckError (List Tok) :=
  match ts with
  | ⟨.punct '}', _⟩ :: rest => .ok rest
  | _ =>
    .error (unexpected ts
      "`}`: `if` and `case` are tails, and a tail ends its block — \
       each arm is the rest of the workflow")

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
  | _ => .error (unexpected ts "a string literal or a text block")

/-- A string literal used as a *name* — an addressee's identifier or a serving
model's — which must therefore hole nothing. -/
private def expectPlainStr (ts : List Tok) : Except CheckError (String × List Tok) := do
  let (p, rest) ← expectStr ts
  match Prompt.closed p with
  | some s => .ok (s, rest)
  | none => .error ⟨posOf ts, "a name here is written, not computed: no holes", ""⟩

/-! ## `define`: literal text, expanded here -/

/-- The name a hole stores, split from its `.reasons` projection if any. -/
private def holeBase (nm : String) : String :=
  if nm.endsWith ".reasons" then
    String.ofList (nm.toList.take (nm.length - ".reasons".length))
  else nm

/-- A binder may not spell a define: the two namespaces must not silently
merge, because a `{name}` hole reads from one and a `{$name}` hole from the
other, and the reader has only the spelling to go by. -/
private def freshOfDefines (defs : List (String × Prompt)) (p : Pos) (x : String) :
    Except CheckError Unit :=
  if defs.any (fun d => d.1 == x) then
    .error ⟨p, "a binder may not spell a define; one of the two must be renamed", x⟩
  else .ok ()

/-- `[[expand defs pos p]]` = `p` with every `{$x}` replaced by the define `x`'s
literal chunks, every `{x}` checked not to name a define, and everything else
untouched.

Fail-closed on both sides of the sigil: an unknown `{$x}` and a `{x}` that
names a define are each refused, because both are programs whose text says
something their meaning would not. -/
private def expand (defs : List (String × Prompt)) (pos : Pos) : Prompt →
    Except CheckError Prompt
  | [] => .ok []
  | .lit s :: rest => do
    let r ← expand defs pos rest
    .ok (.lit s :: r)
  | .interp nm :: rest =>
    if nm.startsWith "$" then
      let name := String.ofList (nm.toList.drop 1)
      match defs.find? (fun d => d.1 == name) with
      | some d => do
        let r ← expand defs pos rest
        .ok (d.2 ++ r)
      | none =>
        .error ⟨pos, "no define answers to this hole; a `{$name}` names an \
                     earlier `define`", name⟩
    else
      match defs.find? (fun d => d.1 == holeBase nm) with
      | some _ =>
        .error ⟨pos, s!"`{holeBase nm}` is a define, and a define's hole carries \
                       the sigil: write it with `$` after the opening brace", nm⟩
      | none => do
        let r ← expand defs pos rest
        .ok (.interp nm :: r)

private def prompt (defs : List (String × Prompt)) (pos : Pos) (p : Prompt) :
    Except CheckError Prompt := do
  let e ← expand defs pos p
  .ok (Prompt.normalize e)

/-! ## The grammar -/

/-- `ask ::= "ask" ("model" | "tool" | "person") name ["served" "by" name]
["independent" "draw" nat] prompt`.

`served by` is legal only on a model addressee, because only there does it name
anything — it writes `atModel` into the question shape. `independent draw`
stays on all three: a blind re-review by a person is as deliberate a resample
as a fresh sample from a model. -/
private def parseAsk (defs : List (String × Prompt)) (ts : List Tok) :
    Except CheckError (RawAsk × List Tok) := do
  let p := posOf ts
  let ts ← expectKw "ask" ts
  let (addr, isModel, ts) ←
    match ts with
    | ⟨.ident k, kp⟩ :: rest =>
      if k == "model" then do
        let (name, rest) ← expectPlainStr rest
        .ok (Addressee.model name, true, rest)
      else if k == "tool" then do
        let (name, rest) ← expectPlainStr rest
        .ok (Addressee.tool name, false, rest)
      else if k == "person" then do
        let (name, rest) ← expectPlainStr rest
        .ok (Addressee.person name, false, rest)
      else .error ⟨kp, "expected an addressee: `model`, `tool` or `person`", k⟩
    | _ => .error (unexpected ts "an addressee: `model`, `tool` or `person`")
  let (model, ts) : Option String × List Tok ←
    match ts with
    | ⟨.ident "served", sp⟩ :: rest =>
      if isModel then do
        let rest ← expectKw "by" rest
        let (m, rest) ← expectPlainStr rest
        .ok (some m, rest)
      else
        .error ⟨sp, "`served by` names the model that serves a model addressee; \
                    a tool or a person is not served by one", "served"⟩
    | _ => .ok (none, ts)
  let (draw, ts) : Nat × List Tok ←
    match ts with
    | ⟨.ident "independent", _⟩ :: rest => do
      let rest ← expectKw "draw" rest
      let (n, rest) ← expectNat rest
      .ok (n, rest)
    | _ => .ok (0, ts)
  let ppos := posOf ts
  let (pr, ts) ← expectStr ts
  let pr ← prompt defs ppos pr
  .ok (⟨model, ⟨addr, draw⟩, pr, p⟩, ts)

/-- `panel ::= "panel" "," "all" "must" "approve" "[" ask {"," ask} "]"`.

The rule phrase is mandatory: once a menu exists, a panel that does not say its
rule leaves the reader to guess which one it is. The menu currently has this
one entry — the verdict monoid — and the phrase is where a second entry will
sit (doc/research/dsl-redesign/panel-rules.md; obr acat-f10). -/
private def parsePanelMembers (defs : List (String × Prompt)) :
    Nat → List Tok → Except CheckError (List RawAsk × List Tok)
  | 0, ts => .error ⟨posOf ts, "internal: parser budget exhausted in a panel", ""⟩
  | fuel + 1, ts => do
    let (a, ts) ← parseAsk defs ts
    match ts with
    | ⟨.punct ',', _⟩ :: rest => do
      let (as, ts) ← parsePanelMembers defs fuel rest
      .ok (a :: as, ts)
    | _ => .ok ([a], ts)

private def parsePanel (defs : List (String × Prompt)) (p : Pos) (ts : List Tok) :
    Except CheckError (RawRhs × List Tok) := do
  let ts ← expectPunct ',' ts
  let ts ← expectKwSaying "all"
    "a panel's rule, on the page: `panel, all must approve [ … ]`" ts
  let ts ← expectKw "must" ts
  let ts ← expectKw "approve" ts
  let ts ← expectPunct '[' ts
  let (ms, ts) ← parsePanelMembers defs (ts.length + 1) ts
  let ts ← expectPunct ']' ts
  .ok (.panel ms p, ts)

/-- `rhs ::= ask | panel` — a clause-position source. A `revising` here is
refused by name: its result is settled-or-not, which only a binding and its
`case` can receive. -/
private def parseRhs (defs : List (String × Prompt)) (ts : List Tok) :
    Except CheckError (RawRhs × List Tok) := do
  match ts with
  | ⟨.ident "panel", p⟩ :: rest => parsePanel defs p rest
  | ⟨.ident "revising", p⟩ :: _ =>
    .error ⟨p, "a bounded revision answers settled-or-not, which only a binding \
               can receive: write `x <- revising …` and `case x { settled … \
               unsettled … }`", "revising"⟩
  | _ => do
    let (a, ts) ← parseAsk defs ts
    .ok (.ask a, ts)

/-- An optional `: kind` between a binder and its arrow. -/
private def parseAnn (ts : List Tok) : Except CheckError (Option Code × List Tok) :=
  match ts with
  | ⟨.punct ':', _⟩ :: rest =>
    match rest with
    | ⟨.ident k, kp⟩ :: rest' =>
      match codeOfName k with
      | some c => .ok (some c, rest')
      | none =>
        .error ⟨kp, "expected an answer kind: `text`, `verdict`, `flag` or `receipt`", k⟩
    | _ => .error (unexpected rest "an answer kind")
  | _ => .ok (none, ts)

/-- `source ::= rhs | "revising" name "as" name "," "at" "most" nat
"amendments" "{" name [":" kind] "<-" rhs "amend" name "{" rhs "}" "}"`.

The loop body is the language's own machinery: one ordinary binding (the
review — its name is the author's, its kind is a verdict) and one `amend`
block whose head names the carrier and whose answer becomes the next
candidate. -/
private def parseSource (defs : List (String × Prompt)) (ts : List Tok) :
    Except CheckError (RawSource × List Tok) := do
  match ts with
  | ⟨.ident "revising", p⟩ :: rest => do
    let (subject, rest) ← expectIdent rest
    let rest ← expectKw "as" rest
    let (carrier, rest) ← expectIdent rest
    freshOfDefines defs p carrier
    let rest ← expectPunct ',' rest
    let rest ← expectKw "at" rest
    let rest ← expectKw "most" rest
    let (n, rest) ← expectNat rest
    -- The unit counts what the reader can see — the amend block's runs — and
    -- the spelling agrees with the numeral, so `at most 1 amendments` is
    -- refused rather than read charitably.
    let rest ← match rest with
      | ⟨.ident "amendments", up⟩ :: r =>
        if n == 1 then
          .error ⟨up, "one amendment: the unit agrees with its numeral", "amendments"⟩
        else .ok r
      | ⟨.ident "amendment", up⟩ :: r =>
        if n == 1 then .ok r
        else .error ⟨up, s!"{n} amendments: the unit agrees with its numeral", "amendment"⟩
      | _ => .error (unexpected rest "`amendments`, the unit the numeral counts")
    let (opos, rest) ← expectOpen rest
    let (rname, rest) ← expectIdent rest
    freshOfDefines defs opos rname
    let (rann, rest) ← parseAnn rest
    let rest ← expectArrow rest
    let (review, rest) ← parseRhs defs rest
    let rest ← expectKwSaying "amend"
      "`amend <carrier> { … }`: a bounded revision says how a rejected candidate \
       is rewritten, and its answer becomes the next candidate" rest
    let (aname, rest) ← expectIdent rest
    if aname != carrier then
      .error ⟨opos, s!"the `amend` head names the loop's carrier: write `amend {carrier}`",
              aname⟩
    else do
      let rest ← expectPunct '{' rest
      let (amend, rest) ← parseRhs defs rest
      let rest ← expectPunct '}' rest
      let rest ← expectPunct '}' rest
      .ok (.revising subject carrier n rname rann review amend p, rest)
  | _ => do
    let (r, ts) ← parseRhs defs ts
    .ok (.rhs r, ts)

/-- The comma-separated tail of a `known here:` list. -/
private def parseNameList : Nat → List String → List Tok →
    Except CheckError (List String × List Tok)
  | 0, acc, ts => .ok (acc.reverse, ts)
  | fuel + 1, acc, ts =>
    match ts with
    | ⟨.punct ',', _⟩ :: r => do
      let (y, r) ← expectIdent r
      parseNameList fuel (y :: acc) r
    | _ => .ok (acc.reverse, ts)

/-- `block ::= "{" ("stop" | statement {statement}) "}"`, the opening brace
already consumed and its position passed in as `opos`.

**Doing nothing says so**: `{ }` is refused, and a path that does nothing
writes `stop`. `first` remembers whether this block has said anything yet. -/
private def parseBlockFrom : Nat → List (String × Prompt) → Pos → Bool → List Tok →
    Except CheckError (RawBlock × List Tok)
  | 0, _, _, _, ts => .error ⟨posOf ts, "internal: parser budget exhausted", ""⟩
  | fuel + 1, defs, opos, first, ts =>
    match ts with
    | ⟨.punct '}', _⟩ :: rest =>
      if first then
        .error ⟨opos, "a path that does nothing says so: write `stop`", "{"⟩
      else .ok (.empty opos, rest)
    | ⟨.ident "stop", sp⟩ :: rest => do
      let rest ← expectPunct '}' rest
      .ok (.empty sp, rest)
    | ⟨.ident "known", p⟩ :: ⟨.ident "here", _⟩ :: rest => do
      let rest ← expectPunct ':' rest
      let (names, rest) ←
        match rest with
        | ⟨.ident "nothing", _⟩ :: r => .ok (([] : List String), r)
        | _ => do
          let (x, r) ← expectIdent rest
          parseNameList (r.length + 1) [x] r
      let (b, rest) ← parseBlockFrom fuel defs opos false rest
      .ok (.knownHere names b p, rest)
    | ⟨.ident "if", p⟩ :: rest => do
      let (x, rest) ← expectIdent rest
      let (o, rest) ← expectOpen rest
      let (y, rest) ← parseBlockFrom fuel defs o true rest
      let rest ← expectKw "else" rest
      let (o', rest) ← expectOpen rest
      let (n, rest) ← parseBlockFrom fuel defs o' true rest
      let rest ← expectBlockEnd rest
      .ok (.ifFlag x y n p, rest)
    | ⟨.ident "case", p⟩ :: rest => do
      let (x, rest) ← expectIdent rest
      let rest ← expectPunct '{' rest
      match rest with
      | ⟨.ident "approved", _⟩ :: rest => do
        let (o1, rest) ← expectOpen rest
        let (a, rest) ← parseBlockFrom fuel defs o1 true rest
        let rest ← expectKwSaying "objected"
          "the arms of a verdict, all three: `approved`, `objected` and `no answer`" rest
        let (o2, rest) ← expectOpen rest
        let (o, rest) ← parseBlockFrom fuel defs o2 true rest
        let rest ← expectKwSaying "no"
          "the arms of a verdict, all three: `approved`, `objected` and `no answer`" rest
        let rest ← expectKw "answer" rest
        let (o3, rest) ← expectOpen rest
        let (d, rest) ← parseBlockFrom fuel defs o3 true rest
        let rest ← expectPunct '}' rest
        let rest ← expectBlockEnd rest
        .ok (.caseVerdict x a o d p, rest)
      | ⟨.ident "settled", sp⟩ :: rest => do
        let (sname, rest) ← expectIdent rest
        freshOfDefines defs sp sname
        let (o1, rest) ← expectOpen rest
        let (s, rest) ← parseBlockFrom fuel defs o1 true rest
        let rest ← expectKwSaying "unsettled"
          "the two outcomes of a bounded revision: `settled <name>` and `unsettled`" rest
        let (o2, rest) ← expectOpen rest
        let (u, rest) ← parseBlockFrom fuel defs o2 true rest
        let rest ← expectPunct '}' rest
        let rest ← expectBlockEnd rest
        .ok (.caseResult x sname s u p, rest)
      | _ =>
        .error (unexpected rest
          "an arm: `approved` (a verdict's three) or `settled` (a revision's two); \
           a flag branches with `if … else`")
    | ⟨.ident "ask", _⟩ :: _ => do
      let p := posOf ts
      let (a, rest) ← parseAsk defs ts
      let (b, rest) ← parseBlockFrom fuel defs opos false rest
      .ok (.act a b p, rest)
    | ⟨.ident "panel", p⟩ :: _ =>
      .error ⟨p, "a panel's combined verdict has nowhere to go here: bind it, \
                 `x <- panel, …`", "panel"⟩
    | ⟨.ident "revising", p⟩ :: _ =>
      .error ⟨p, "a revising result must be bound: write `x <- revising …` and then \
                 `case x { settled … unsettled … }`", "revising"⟩
    | ⟨.ident x, p⟩ :: rest => do
      freshOfDefines defs p x
      let (ann, rest) ← parseAnn rest
      let rest ← expectArrow rest
      let (src, rest) ← parseSource defs rest
      let (b, rest) ← parseBlockFrom fuel defs opos false rest
      .ok (.bind x ann src b p, rest)
    | _ =>
      .error (unexpected ts
        "a statement: a binding (`x <- …`), an act (`ask …`), `if`, `case`, \
         `known here:`, or `stop`")

/-- `block ::= "{" … "}"`, braces and all. -/
private def parseBlock (fuel : Nat) (defs : List (String × Prompt)) (ts : List Tok) :
    Except CheckError (RawBlock × List Tok) := do
  let (o, ts) ← expectOpen ts
  parseBlockFrom fuel defs o true ts

/-- `{define}` — the literal-text preamble, with a caller's overrides.

An override *replaces the right-hand side of a `define` the program wrote*, at
the point the program writes it, so a name means one thing throughout and later
defines that hole it see the override. A duplicate `define` is refused — the
language refuses to guess everywhere else — and a body may hole only earlier
defines, so expansion always yields literals and no define is cyclic. -/
private def parseDefines (ov : List (String × Prompt)) :
    Nat → List (String × Prompt) → List Tok →
    Except CheckError (List (String × Prompt) × List Tok)
  | 0, _, ts => .error ⟨posOf ts, "internal: parser budget exhausted in the define preamble", ""⟩
  | fuel + 1, defs, ts =>
    match ts with
    | ⟨.ident "define", dp⟩ :: rest => do
      let (x, rest) ← expectIdent rest
      if defs.any (fun d => d.1 == x) then
        .error ⟨dp, "this name is already defined, and the earlier body would \
                    silently win; one define per name", x⟩
      else do
        let rest ← expectPunct '=' rest
        let bpos := posOf rest
        let (pr, rest) ← expectStr rest
        let body ← match ov.find? (fun o => o.1 == x) with
          | some o => .ok o.2
          | none => do
            let b ← prompt defs bpos pr
            if b.any (fun ch => match ch with | .interp _ => true | .lit _ => false) then
              .error ⟨bpos, "a define is literal text: only `{$name}` holes of \
                            earlier defines are legal in one", x⟩
            else .ok b
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
from one written that way.

**An override nobody asked for is an error.** A name the program does not define
is a mistake — a typo, or a program that has moved on — and guessing what it
was meant to say is the discipline this package refuses everywhere else. -/
def parseWith (ov : List (String × Prompt)) (s : String) : Except CheckError Raw := do
  let ts ← lex s
  let (defs, rest) ← parseDefines ov (ts.length + 1) [] ts
  match ov.find? (fun o => !defs.any (fun d => d.1 == o.1)) with
  | some o =>
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

end Agentic.Core.Dsl
