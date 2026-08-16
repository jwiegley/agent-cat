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

A **hole** is `{name}`, and nothing else: any other `{` is refused at lex
time with the escape (`\{`) named. A hole *names* — a define, expanded where
it stands, or a binding, spliced when the program runs — and the two
namespaces are disjoint by construction (a binder may not spell a define), so
the name alone decides and there is nothing further to mark. `define` is
expanded in this module, so the raw syntax the checker sees mentions only
names a checker can resolve; a duplicate `define` is refused, and a define's
body may hole only earlier defines — so expansion always yields literals, no
define is cyclic, and a question is closed exactly when every hole it wrote
named a define.
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
  /-- One of `{ } [ ] , = : ( )`. -/
  | punct (c : Char)
  /-- The binding arrow `<-`. -/
  | arrow
  /-- The result arrow `->` of a function header. -/
  | resArrow
  /-- `$name`: a labelled-argument reference in a call. -/
  | label (s : String)
  /-- A labelled fenced block: the argument a `$name` names. -/
  | lstr (l : String) (p : Prompt)
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
  | .resArrow => "->"
  | .label s => "$" ++ s
  | .lstr l _ => "```" ++ l

/-! ## The lexer -/

private def isIdentStart (c : Char) : Bool := c.isAlpha || c == '_'

private def isIdentCont (c : Char) : Bool := c.isAlpha || c.isDigit || c == '_'

private def punctChars : List Char := ['{', '}', '[', ']', ',', '=', ':', '(', ')']

private def natOfDigits (ds : List Char) : Nat :=
  ds.foldl (fun n d => n * 10 + (d.toNat - 48)) 0

/-- A pending run of literal characters, pushed onto the chunk accumulator. -/
private def flushLit (acc : List Char) (chunks : Prompt) : Prompt :=
  if acc.isEmpty then chunks else Chunk.lit (String.ofList acc.reverse) :: chunks

/-- The body of a hole, the opening `{` already consumed: a name and the
closing brace. Returns the name and the characters consumed (braces included).

One grammar for both prompt spellings, enforced at lex time: a `{` that does
not open a hole is refused with the escape named, because the alternative —
carrying arbitrary text to the checker as a name — turns a lexical mistake
into a misleading scope error. A hole *names*: a define (expanded where it
stands) or a binding (spliced when the program runs), and the two namespaces
are disjoint by construction, so the name alone decides. -/
private def scanHole (p : Pos) (cs : List Char) :
    Except CheckError (String × Nat × List Char) := do
  match cs with
  | c :: _ =>
    if isIdentStart c then
      let base := cs.takeWhile isIdentCont
      let cs := cs.drop base.length
      -- One dot, for a module's name: `{library.spec}`. Modules do not nest.
      let (name, used, cs) :=
        match cs with
        | '.' :: d :: _ =>
          if isIdentStart d then
            let fld := (cs.drop 1).takeWhile isIdentCont
            (String.ofList base ++ "." ++ String.ofList fld,
             base.length + 1 + fld.length, cs.drop (1 + fld.length))
          else (String.ofList base, base.length, cs)
        | _ => (String.ofList base, base.length, cs)
      match cs with
      | '}' :: rest => .ok (name, used + 2, rest)
      | _ => .error ⟨p, "unterminated hole: no closing brace", name⟩
    else
      .error ⟨p, "a hole is `{name}`; a literal brace is written `\\{`", ""⟩
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
        -- `used` already counts both braces, so the hole advances the column
        -- by exactly `used`; anything more would shift every later diagnosis
        -- on the line (found by the round-fourteen discovery pass).
        scanString fuel rest ⟨p.line, p.col + used⟩ []
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
      | '}' :: cs' => scanBlockChunks openPos fuel cs' ('}' :: acc) chunks
      | _ => scanBlockChunks openPos fuel cs (c :: acc) chunks
    else if c == '{' then
      match scanHole openPos cs with
      | .error e => .error e
      | .ok (name, _, rest) =>
        scanBlockChunks openPos fuel rest [] (Chunk.interp name :: flushLit acc chunks)
    else
      scanBlockChunks openPos fuel cs (c :: acc) chunks

/-- A fenced block, the opening backtick run already counted (`n ≥ 3`) and the
input positioned right after it. The rest of the opening line is an optional
LABEL — an ident immediately after the run, which makes this block the argument
a `$label` in a call names — then whitespace; content begins on the next
line. -/
private def scanBlock (n : Nat) (openPos : Pos) (cs : List Char) :
    Except CheckError (Option String × Prompt × List Char × Pos) := do
  let (lbl, cs) :=
    match cs with
    | d :: _ =>
      if isIdentStart d then
        let ids := cs.takeWhile isIdentCont
        (some (String.ofList ids), cs.drop ids.length)
      else (none, cs)
    | [] => (none, cs)
  let (line, rest, hadNl) := takeLine cs
  if !(line.all isWs) then
    .error ⟨openPos, "the content of a block begins on the next line: \
                     nothing but a label and whitespace may follow the opening \
                     fence", String.ofList line⟩
  else if !hadNl then
    .error ⟨openPos, s!"this fence of {n} backticks is never closed", ""⟩
  else do
    let (lines, after, endPos) ←
      scanFenceLines n openPos (cs.length + 1) rest (openPos.line + 1) []
    let indent ← commonIndent openPos lines
    let content := dedentJoin indent lines
    let chunks ← scanBlockChunks openPos (content.length + 1) content [] []
    .ok (lbl, chunks, after, endPos)

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
      | '>' :: cs' => lexAux fuel cs' ⟨p.line, p.col + 2⟩ (⟨.resArrow, p⟩ :: acc)
      | _ => .error ⟨p, "stray `-`; `--` begins a comment and `->` a function's \
                        result, and nothing else in the language begins with one", "-"⟩
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
        | .ok (none, pr, cs', p') => lexAux fuel cs' p' (⟨.str pr, p⟩ :: acc)
        | .ok (some l, pr, cs', p') => lexAux fuel cs' p' (⟨.lstr l pr, p⟩ :: acc)
    else if c == '"' then
      match scanString (fuel + 1) cs ⟨p.line, p.col + 1⟩ [] [] with
      | .error e => .error e
      | .ok (pr, cs', p') => lexAux fuel cs' p' (⟨.str pr, p⟩ :: acc)
    else if c.isDigit then
      let ds := (c :: cs).takeWhile Char.isDigit
      lexAux fuel ((c :: cs).drop ds.length) ⟨p.line, p.col + ds.length⟩
        (⟨.num (natOfDigits ds), p⟩ :: acc)
    else if c == '$' then
      match cs with
      | d :: _ =>
        if isIdentStart d then
          let ids := cs.takeWhile isIdentCont
          lexAux fuel (cs.drop ids.length) ⟨p.line, p.col + 1 + ids.length⟩
            (⟨.label (String.ofList ids), p⟩ :: acc)
        else
          .error ⟨p, "a `$name` names a labelled block argument; a name follows \
                     the dollar", "$"⟩
      | [] =>
        .error ⟨p, "a `$name` names a labelled block argument; a name follows \
                   the dollar", "$"⟩
    else if isIdentStart c then
      let ids := (c :: cs).takeWhile isIdentCont
      let rest0 := (c :: cs).drop ids.length
      -- One dot, for a module's name: `library.spec`. Modules do not nest.
      let (name, len, rest) :=
        match rest0 with
        | '.' :: d :: _ =>
          if isIdentStart d then
            let fld := (rest0.drop 1).takeWhile isIdentCont
            (String.ofList ids ++ "." ++ String.ofList fld,
             ids.length + 1 + fld.length, rest0.drop (1 + fld.length))
          else (String.ofList ids, ids.length, rest0)
        | _ => (String.ofList ids, ids.length, rest0)
      lexAux fuel rest ⟨p.line, p.col + len⟩ (⟨.ident name, p⟩ :: acc)
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
/-! ## The parse environment

Everything the grammar needs to resolve a name: the defines (literal text,
expanded here), the functions' arities (for arity-directed calls), the module
names in scope, and — when a library is being read — its name, so that its own
top-level names come out qualified. -/

/-- The tables a parse runs against. -/
structure PEnv where
  /-- Defines, under their full (possibly dotted) names. -/
  defs : List (String × Prompt) := []
  /-- Function arities, under full names, in stratified order. -/
  fnAr : List (String × Nat) := []
  /-- The module names in scope, for the reservation refusals. -/
  mods : List String := []
  /-- The module being parsed, when it is a library. -/
  qual : Option String := none
  /-- Qualify residual references — true exactly in a library's priming, where
  every unqualified name is the library's own and must survive the splice
  under its dotted name. -/
  qualRefs : Bool := false
  deriving Inhabited

/-- A name, resolved to its full spelling: dotted names pass through, and an
unqualified name inside a library is the library's own. -/
def PEnv.q (env : PEnv) (x : String) : String :=
  if x.toList.contains '.' then x
  else match env.qual with
    | some m => m ++ "." ++ x
    | none => x

/-- The closed list of words that begin a statement, a clause or a header. A
binder, a parameter or a function may not spell one: a name is read exactly
where these words are read, so one of the two must yield. -/
private def stmtWords : List String :=
  ["stop", "known", "if", "case", "ask", "panel", "revising", "answer",
   "amend", "settled", "unsettled", "else", "import", "define", "function",
   "workflow"]

/-- A name being introduced may not spell a statement word, a define, a
function, or a module: every name in a program means exactly one thing, and
the disjointness is what lets one spelling serve everywhere. -/
private def freshOfTables (env : PEnv) (p : Pos) (what x : String) :
    Except CheckError Unit :=
  if stmtWords.contains x then
    .error ⟨p, s!"{what} may not spell a word that begins a statement: \
                 {String.intercalate ", " stmtWords}", x⟩
  else if env.defs.any (fun d => d.1 == env.q x) then
    .error ⟨p, s!"{what} may not spell a define; one of the two must be renamed", x⟩
  else if env.fnAr.any (fun f => f.1 == env.q x) then
    .error ⟨p, s!"{what} may not spell a function; one of the two must be renamed", x⟩
  else if env.mods.contains x then
    .error ⟨p, s!"{what} may not spell an imported module's name", x⟩
  else .ok ()

/-! ## `define`: literal text, expanded here -/

/-- `[[expand env p]]` = `p` with every hole that names a define replaced by
the define's literal chunks, and every other hole left for the checker to
resolve against the bindings — under its full name when a library's priming is
being read, so the splice needs no rewriting afterwards.

Expansion-wins is safe, not a precedence rule: a binder may not spell a define
(`freshOfTables`), so a hole's name lives in exactly one namespace and nothing
can be captured. -/
private def expand (env : PEnv) : Prompt → Prompt
  | [] => []
  | .lit s :: rest => .lit s :: expand env rest
  | .interp nm :: rest =>
    let full := env.q nm
    match env.defs.find? (fun d => d.1 == full) with
    | some d => d.2 ++ expand env rest
    | none => .interp (if env.qualRefs then full else nm) :: expand env rest

private def prompt (env : PEnv) (p : Prompt) : Prompt :=
  Prompt.normalize (expand env p)

/-! ### The define expansion is a monoid map

Stated here because `expand` is private. These carry the ∀-content of the
battery's override pins: a literal survives every table, a hole becomes
exactly the found body, and expansion distributes over concatenation — for
every prompt, not just the fixtures. The bridge from `--define` to the entry
`find?` retrieves is `parseModuleSrc`'s header loop, which stays pinned by
the battery: these lemmas are its two ends. -/

theorem expand_lit (env : PEnv) (s : String) (rest : Prompt) :
    expand env (.lit s :: rest) = .lit s :: expand env rest := rfl

theorem expand_interp_hit (env : PEnv) (nm : String) (rest : Prompt)
    (d : String × Prompt)
    (h : env.defs.find? (fun d => d.1 == env.q nm) = some d) :
    expand env (.interp nm :: rest) = d.2 ++ expand env rest := by
  simp [expand, h]

theorem expand_append (env : PEnv) (p q : Prompt) :
    expand env (p ++ q) = expand env p ++ expand env q := by
  induction p with
  | nil => rfl
  | cons ch rest ih =>
    cases ch <;> simp [expand, ih]
    split <;> simp

/-! ## The grammar -/

/-- `ask ::= "ask" ("model" | "tool" | "person") name ["served" "by" name]
["independent" "draw" nat] prompt`.

`served by` is legal only on a model addressee, because only there does it name
anything — it writes `atModel` into the question shape. `independent draw`
stays on all three: a blind re-review by a person is as deliberate a resample
as a fresh sample from a model. -/
private def parseAsk (env : PEnv) (ts : List Tok) :
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
  let (pr, ts) ← expectStr ts
  .ok (⟨model, ⟨addr, draw⟩, prompt env pr, p⟩, ts)

/-! ### Calls: arity-directed juxtaposition

The parser holds the function table, so at a call head it knows the arity and
reads exactly that many single-token arguments. The stratification that makes
the table available before any use is the same rule that refuses recursion. -/

/-- A call head, resolved: dotted names pass through, an unqualified name in a
library is its own. Returns the full name and the arity. -/
private def resolveFn (env : PEnv) (x : String) : Option (String × Nat) :=
  let full := env.q x
  (env.fnAr.find? (fun f => f.1 == full)).map (fun f => (full, f.2))

/-- An argument before label resolution. -/
private inductive PArg where
  | val (a : RawArg)
  | lab (l : String) (pos : Pos)

/-- Exactly `arity` single-token arguments. A name that is a define expands to
its words; a name followed by `<-` or `:` is the next statement, refused by
count; a statement word is likewise refused by count. -/
private def parseArgTokens (env : PEnv) (fname : String) (arity : Nat) :
    Nat → List Tok → Nat → List PArg → Except CheckError (List PArg × List Tok)
  | 0, ts, _, _ =>
    .error ⟨posOf ts, "internal: parser budget exhausted in a call", ""⟩
  | _ + 1, ts, 0, acc => .ok (acc.reverse, ts)
  | fuel + 1, ts, k + 1, acc =>
    let got := arity - (k + 1)
    let unit := if arity == 1 then "argument" else "arguments"
    let short (t : Tok) (why : String) : Except CheckError (List PArg × List Tok) :=
      .error ⟨t.pos, s!"`{fname}` takes {arity} {unit} and got {got}: {why}",
              t.tok.excerpt⟩
    match ts with
    | ⟨.ident x, p⟩ :: rest =>
      if stmtWords.contains x then
        short ⟨.ident x, p⟩ "the next statement begins here"
      else
        match rest with
        | ⟨.arrow, _⟩ :: _ =>
          short ⟨.ident x, p⟩ "the next statement begins here (a binding follows)"
        | ⟨.punct ':', _⟩ :: _ =>
          short ⟨.ident x, p⟩ "the next statement begins here (a binding follows)"
        | _ =>
          -- A call is not an argument: what a call answers has no name yet,
          -- so a function's name standing here can only be a mistake.
          match resolveFn env x with
          | some (fn, _) =>
            .error ⟨p, s!"a call is not an argument: bind it above — \
                         `y <- {fn} …` — and pass `y`", x⟩
          | none =>
          let full := env.q x
          match env.defs.find? (fun d => d.1 == full) with
          | some d => parseArgTokens env fname arity fuel rest k (.val (.lit d.2 p) :: acc)
          | none =>
            let nm := if env.qualRefs then full else x
            parseArgTokens env fname arity fuel rest k (.val (.name nm p) :: acc)
    | ⟨.str pr, p⟩ :: rest =>
      parseArgTokens env fname arity fuel rest k (.val (.lit (prompt env pr) p) :: acc)
    | ⟨.label l, p⟩ :: rest =>
      parseArgTokens env fname arity fuel rest k (.lab l p :: acc)
    | ⟨.lstr _ _, p⟩ :: _ =>
      .error ⟨p, "a labelled block answers a `$label` and follows the call's \
                 arguments; here an argument itself is expected", "```"⟩
    | t :: _ => short t "this is not an argument (a name, words, or a `$label`)"
    | [] =>
      .error ⟨⟨0, 0⟩, s!"`{fname}` takes {arity} {unit} and got {got}, \
                        but the source ended", ""⟩

/-- The labelled fences following a call, one per distinct label. -/
private def collectLabelled (env : PEnv) :
    Nat → List Tok → List (String × Prompt × Pos) →
    Except CheckError (List (String × Prompt × Pos) × List Tok)
  | 0, ts, _ =>
    .error ⟨posOf ts, "internal: parser budget exhausted in labelled blocks", ""⟩
  | fuel + 1, ts, acc =>
    match ts with
    | ⟨.lstr l pr, p⟩ :: rest =>
      if acc.any (fun a => a.1 == l) then
        .error ⟨p, "two labelled blocks answer to one label in this call; \
                   one label, one block", l⟩
      else
        collectLabelled env fuel rest ((l, prompt env pr, p) :: acc)
    | _ => .ok (acc.reverse, ts)

/-- A whole call: the head already resolved, the arguments read by arity, and
every `$label` satisfied by exactly one labelled fence. -/
private def parseCall (env : PEnv) (fname : String) (arity : Nat) (ts : List Tok) :
    Except CheckError (List RawArg × List Tok) := do
  let (pargs, ts) ← parseArgTokens env fname arity (ts.length + 1) ts arity []
  let (fences, ts) ← collectLabelled env (ts.length + 1) ts []
  let args ← pargs.mapM fun a =>
    match a with
    | .val v => .ok v
    | .lab l p =>
      match fences.find? (fun f => f.1 == l) with
      | some f => .ok (RawArg.lit f.2.1 p)
      | none => .error ⟨p, s!"`${l}` names no labelled block: write ```{l} \
                             after the call's arguments", l⟩
  -- A fence no `$label` wrote is a mistake, not decoration.
  match fences.find? (fun f => !pargs.any (fun a =>
      match a with | .lab l _ => l == f.1 | .val _ => false)) with
  | some f =>
    .error ⟨f.2.2, s!"no `${f.1}` in the call names this labelled block", f.1⟩
  | none => .ok (args, ts)

/-- `panel ::= "panel" "," "all" "must" "approve" "[" ask {"," ask} "]"`. -/
private def parsePanelMembers (env : PEnv) :
    Nat → List Tok → Except CheckError (List RawAsk × List Tok)
  | 0, ts => .error ⟨posOf ts, "internal: parser budget exhausted in a panel", ""⟩
  | fuel + 1, ts => do
    let (a, ts) ← parseAsk env ts
    match ts with
    | ⟨.punct ',', _⟩ :: rest => do
      let (as, ts) ← parsePanelMembers env fuel rest
      .ok (a :: as, ts)
    | _ => .ok ([a], ts)

private def parsePanel (env : PEnv) (p : Pos) (ts : List Tok) :
    Except CheckError (RawRhs × List Tok) := do
  let ts ← expectPunct ',' ts
  let ts ← expectKwSaying "all"
    "a panel's rule, on the page: `panel, all must approve [ … ]`" ts
  let ts ← expectKw "must" ts
  let ts ← expectKw "approve" ts
  let ts ← expectPunct '[' ts
  let (ms, ts) ← parsePanelMembers env (ts.length + 1) ts
  let ts ← expectPunct ']' ts
  .ok (.panel ms p, ts)

/-- `rhs ::= ask | panel | call` — a clause-position source. A `revising` here
is refused by name: its result is settled-or-not, which only a binding and its
`case` can receive. -/
private def parseRhs (env : PEnv) (ts : List Tok) :
    Except CheckError (RawRhs × List Tok) := do
  match ts with
  | ⟨.ident "panel", p⟩ :: rest => parsePanel env p rest
  | ⟨.ident "revising", p⟩ :: _ =>
    .error ⟨p, "a bounded revision answers settled-or-not, which only a binding \
               can receive: write `x <- revising …` and `case x { settled … \
               unsettled … }`", "revising"⟩
  | ⟨.ident "ask", _⟩ :: _ => do
    let (a, ts) ← parseAsk env ts
    .ok (.ask a, ts)
  | ⟨.ident x, p⟩ :: rest =>
    match resolveFn env x with
    | some (fname, ar) => do
      let (args, ts) ← parseCall env fname ar rest
      .ok (.call fname args p, ts)
    | none =>
      .error ⟨p, "expected a question (`ask …`), a panel, or the name of a \
                 function declared above", x⟩
  | _ => .error (unexpected ts "a question, a panel, or a function's name")

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
("amendment" | "amendments") "{" name [":" kind] "<-" rhs "amend" name "{" rhs
"}" "}"`. -/
private def parseSource (env : PEnv) (ts : List Tok) :
    Except CheckError (RawSource × List Tok) := do
  match ts with
  | ⟨.ident "revising", p⟩ :: rest => do
    let (subject, rest) ← expectIdent rest
    let subject := if env.qualRefs then env.q subject else subject
    let rest ← expectKw "as" rest
    let (carrier, rest) ← expectIdent rest
    freshOfTables env p "a loop's carrier" carrier
    let rest ← expectPunct ',' rest
    let rest ← expectKw "at" rest
    let rest ← expectKw "most" rest
    let (n, rest) ← expectNat rest
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
    freshOfTables env opos "a review binding" rname
    let (rann, rest) ← parseAnn rest
    let rest ← expectArrow rest
    let (review, rest) ← parseRhs env rest
    let rest ← expectKwSaying "amend"
      "`amend <carrier> { … }`: a bounded revision says how a rejected candidate \
       is rewritten, and its answer becomes the next candidate" rest
    let (aname, rest) ← expectIdent rest
    if aname != carrier then
      .error ⟨opos, s!"the `amend` head names the loop's carrier: write `amend {carrier}`",
              aname⟩
    else do
      let rest ← expectPunct '{' rest
      let (amend, rest) ← parseRhs env rest
      let rest ← expectPunct '}' rest
      let rest ← expectPunct '}' rest
      .ok (.revising subject carrier n rname rann review amend p, rest)
  | _ => do
    let (r, ts) ← parseRhs env ts
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
private def parseBlockFrom (env : PEnv) : Nat → Pos → Bool → List Tok →
    Except CheckError (RawBlock × List Tok)
  | 0, _, _, ts => .error ⟨posOf ts, "internal: parser budget exhausted", ""⟩
  | fuel + 1, opos, first, ts =>
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
      let (b, rest) ← parseBlockFrom env fuel opos false rest
      .ok (.knownHere names b p, rest)
    | ⟨.ident "if", p⟩ :: rest => do
      let (x, rest) ← expectIdent rest
      let (o, rest) ← expectOpen rest
      let (y, rest) ← parseBlockFrom env fuel o true rest
      let rest ← expectKw "else" rest
      let (o', rest) ← expectOpen rest
      let (n, rest) ← parseBlockFrom env fuel o' true rest
      let rest ← expectBlockEnd rest
      .ok (.ifFlag x y n p, rest)
    | ⟨.ident "case", p⟩ :: rest => do
      let (x, rest) ← expectIdent rest
      let rest ← expectPunct '{' rest
      match rest with
      | ⟨.ident "approved", _⟩ :: rest => do
        let (o1, rest) ← expectOpen rest
        let (a, rest) ← parseBlockFrom env fuel o1 true rest
        let rest ← expectKwSaying "objected"
          "the arms of a verdict, all three: `approved`, `objected` and `no answer`" rest
        let (o2, rest) ← expectOpen rest
        let (o, rest) ← parseBlockFrom env fuel o2 true rest
        let rest ← expectKwSaying "no"
          "the arms of a verdict, all three: `approved`, `objected` and `no answer`" rest
        let rest ← expectKw "answer" rest
        let (o3, rest) ← expectOpen rest
        let (d, rest) ← parseBlockFrom env fuel o3 true rest
        let rest ← expectPunct '}' rest
        let rest ← expectBlockEnd rest
        .ok (.caseVerdict x a o d p, rest)
      | ⟨.ident "settled", sp⟩ :: rest => do
        let (sname, rest) ← expectIdent rest
        freshOfTables env sp "a settled binder" sname
        let (o1, rest) ← expectOpen rest
        let (s, rest) ← parseBlockFrom env fuel o1 true rest
        let rest ← expectKwSaying "unsettled"
          "the two outcomes of a bounded revision: `settled <name>` and `unsettled`" rest
        let (o2, rest) ← expectOpen rest
        let (u, rest) ← parseBlockFrom env fuel o2 true rest
        let rest ← expectPunct '}' rest
        let rest ← expectBlockEnd rest
        .ok (.caseResult x sname s u p, rest)
      | _ =>
        .error (unexpected rest
          "an arm: `approved` (a verdict's three) or `settled` (a revision's two); \
           a flag branches with `if … else`")
    | ⟨.ident "ask", _⟩ :: _ => do
      let p := posOf ts
      let (a, rest) ← parseAsk env ts
      let (b, rest) ← parseBlockFrom env fuel opos false rest
      .ok (.act a b p, rest)
    | ⟨.ident "panel", p⟩ :: _ =>
      .error ⟨p, "a panel's combined verdict has nowhere to go here: bind it, \
                 `x <- panel, …`", "panel"⟩
    | ⟨.ident "revising", p⟩ :: _ =>
      .error ⟨p, "a revising result must be bound: write `x <- revising …` and then \
                 `case x { settled … unsettled … }`", "revising"⟩
    | ⟨.ident x, p⟩ :: rest =>
      match resolveFn env x with
      | some (fname, ar) => do
        let (args, rest) ← parseCall env fname ar rest
        let (b, rest) ← parseBlockFrom env fuel opos false rest
        .ok (.callStmt fname args b p, rest)
      | none => do
        freshOfTables env p "a binder" x
        let (ann, rest) ← parseAnn rest
        let rest ← expectArrow rest
        let (src, rest) ← parseSource env rest
        let (b, rest) ← parseBlockFrom env fuel opos false rest
        let x := if env.qualRefs then env.q x else x
        .ok (.bind x ann src b p, rest)
    | _ =>
      .error (unexpected ts
        "a statement: a binding (`x <- …`), an act (`ask …`), a call, `if`, \
         `case`, `known here:`, or `stop`")

/-- `block ::= "{" … "}"`, braces and all. -/
private def parseBlock (env : PEnv) (fuel : Nat) (ts : List Tok) :
    Except CheckError (RawBlock × List Tok) := do
  let (o, ts) ← expectOpen ts
  parseBlockFrom env fuel o true ts

/-! ### A library's priming: straight-line statements at top level

The priming is a *prefix* of every importing program, so it has exactly one
exit: bindings, acts and calls, and nothing that branches, loops, stops or
asserts scope. A library's top-level bindings carry their kind annotation,
because inference scans forward and "forward", after the splice, is somebody
else's file: a library's questions must not depend on who imports it. -/

private def parsePrimer (env : PEnv) : Nat → List Tok →
    Except CheckError (RawBlock × List Tok)
  | 0, ts => .error ⟨posOf ts, "internal: parser budget exhausted in a priming", ""⟩
  | fuel + 1, ts =>
    match ts with
    | [] => .ok (.empty (posOf ts), [])
    | ⟨.ident "ask", _⟩ :: _ => do
      let p := posOf ts
      let (a, rest) ← parseAsk env ts
      let (b, rest) ← parsePrimer env fuel rest
      .ok (.act a b p, rest)
    | ⟨.ident w, p⟩ :: _ =>
      if w == "if" || w == "case" || w == "revising" || w == "stop" then
        .error ⟨p, "a library's priming is a prefix of every importing program, \
                   so it is straight-line: bindings, acts and calls only", w⟩
      else if w == "known" then
        .error ⟨p, "`known here` asserts a workflow's scope, and a priming is \
                   spliced into somebody else's; leave it to the importer", w⟩
      else if w == "panel" then
        .error ⟨p, "a panel's combined verdict has nowhere to go here: bind it, \
                   `x <- panel, …`", "panel"⟩
      else
        match resolveFn env w with
        | some (fname, ar) => do
          let (args, rest) ← parseCall env fname ar (ts.drop 1)
          let (b, rest) ← parsePrimer env fuel rest
          .ok (.callStmt fname args b p, rest)
        | none => do
          freshOfTables env p "a binder" w
          let (ann, rest) ← parseAnn (ts.drop 1)
          if ann.isNone then
            .error ⟨p, "a library's top-level binding carries its kind — \
                       inference scans forward, and forward is the importer's \
                       file; a library's questions must not depend on who \
                       imports it", w⟩
          else do
            let rest ← expectArrow rest
            let (src, rest) ← parseRhs env rest
            let (b, rest) ← parsePrimer env fuel rest
            .ok (.bind (env.q w) ann (.rhs src) b p, rest)
    | t :: _ => .error ⟨t.pos, "expected a priming statement: a binding \
                               (`x : kind <- …`), an act (`ask …`), or a call",
                        t.tok.excerpt⟩

/-! ### Function definitions -/

/-- `function name ( p : kind , … ) -> kind { body }`. -/
private def parseFnBody (env : PEnv) (fname : String) (result : Code) :
    Nat → List Tok → List RawBodyStmt →
    Except CheckError (List RawBodyStmt × Option String × Pos × List Tok)
  | 0, ts, _ => .error ⟨posOf ts, "internal: parser budget exhausted in a body", ""⟩
  | fuel + 1, ts, acc =>
    match ts with
    | ⟨.punct '}', p⟩ :: rest =>
      if result == Code.ack then .ok (acc.reverse, none, p, rest)
      else
        .error ⟨p, s!"a value function ends with `answer <name>`; `{fname}` \
                     answers `{codeName result}`", "}"⟩
    | ⟨.ident "answer", ap⟩ :: rest =>
      if result == Code.ack then
        .error ⟨ap, "a `-> receipt` function's body just ends: the end of the \
                    block is the answer, and there is nothing to name", "answer"⟩
      else do
        let (x, rest) ← expectIdent rest
        let rest ← expectPunct '}' rest
        .ok (acc.reverse, some x, ap, rest)
    | ⟨.ident "ask", _⟩ :: _ => do
      let p := posOf ts
      let (a, rest) ← parseAsk env ts
      parseFnBody env fname result fuel rest (.act a p :: acc)
    | ⟨.ident w, p⟩ :: _ =>
      if w == "if" || w == "case" || w == "revising" || w == "stop" || w == "known" then
        .error ⟨p, "a function is a reusable sequence of questions, not a \
                   reusable decision: return a `flag` or a `verdict` and branch \
                   at the call site, where the branch is read", w⟩
      else
        match resolveFn env w with
        | some (g, ar) => do
          let (args, rest) ← parseCall env g ar (ts.drop 1)
          parseFnBody env fname result fuel rest (.callS g args p :: acc)
        | none => do
          freshOfTables env p "a binder" w
          let (ann, rest) ← parseAnn (ts.drop 1)
          let rest ← expectArrow rest
          let (rhs, rest) ← parseRhs env rest
          parseFnBody env fname result fuel rest (.bind w ann rhs p :: acc)
    | t :: _ =>
      .error ⟨t.pos, "expected a body statement (a binding, an act, a call) or \
                     `answer <name>`", t.tok.excerpt⟩
    | [] => .error ⟨⟨0, 0⟩, "expected `answer` or `}`, but the source ended", ""⟩

/-- The parameter list: `( p : kind , … )`, at least one parameter. -/
private def parseParams (env : PEnv) :
    Nat → List Tok → List (String × Code) →
    Except CheckError (List (String × Code) × List Tok)
  | 0, ts, _ => .error ⟨posOf ts, "internal: parser budget exhausted in parameters", ""⟩
  | fuel + 1, ts, acc => do
    let pp := posOf ts
    let (x, ts) ← expectIdent ts
    freshOfTables env pp "a parameter" x
    if acc.any (fun a => a.1 == x) then
      .error ⟨pp, "two parameters answer to one name; rename one", x⟩
    else do
      let ts ← expectPunct ':' ts
      let kp := posOf ts
      let (kname, ts) ← expectIdent ts
      let k ← match codeOfName kname with
        | some c => .ok c
        | none =>
          .error ⟨kp, "expected an answer kind: `text`, `verdict`, `flag` or \
                      `receipt`", kname⟩
      match k with
      | .flag =>
        .error ⟨kp, "a `flag` parameter is refused: nothing in a body can \
                    consume one — `if` is not written in a body, and a flag \
                    has no text for a hole", kname⟩
      | .ack =>
        .error ⟨kp, "a `receipt` parameter is refused: a receipt carries no \
                    information, and ordering is the sequence of statements", kname⟩
      | _ =>
      match ts with
      | ⟨.punct ',', _⟩ :: rest => parseParams env fuel rest ((x, k) :: acc)
      | ⟨.punct ')', _⟩ :: rest => .ok (((x, k) :: acc).reverse, rest)
      | _ => .error (unexpected ts "`,` or `)`")

/-- One `function` definition, the keyword already consumed. -/
private def parseFn (env : PEnv) (fp : Pos) (ts : List Tok) :
    Except CheckError (RawFn × List Tok) := do
  let (name, ts) ← expectIdent ts
  freshOfTables env fp "a function" name
  let ts ← expectPunct '(' ts
  let (params, ts) ← parseParams env (ts.length + 1) ts []
  let ts ← match ts with
    | ⟨.resArrow, _⟩ :: rest => .ok rest
    | _ => .error (unexpected ts "`->`, the function's result")
  let kp := posOf ts
  let (kname, ts) ← expectIdent ts
  let result ← match codeOfName kname with
    | some c => .ok c
    | none =>
      .error ⟨kp, "expected an answer kind: `text`, `verdict`, `flag` or \
                  `receipt`", kname⟩
  let ts ← expectPunct '{' ts
  let (body, answer, apos, ts) ← parseFnBody env (env.q name) result (ts.length + 1) ts []
  .ok (⟨env.q name, params, result, body, answer, apos, fp⟩, ts)

/-! ### Headers, files, and the module walk -/

/-- The `import` lines at the top of a file. Imports come first — a name's
meaning must be decidable from what is above it. -/
def importsOf (s : String) : Except CheckError (List (String × Pos)) := do
  let ts ← lex s
  let rec go : Nat → List Tok → List (String × Pos) →
      Except CheckError (List (String × Pos))
    | 0, _, acc => .ok acc.reverse
    | fuel + 1, ⟨.ident "import", ip⟩ :: rest, acc =>
      match rest with
      | ⟨.ident m, mp⟩ :: rest' =>
        if m.toList.contains '.' then
          .error ⟨mp, "a module's name has no dot: modules do not nest", m⟩
        else go fuel rest' ((m, ip) :: acc)
      | _ => .error (unexpected rest "a module's name")
    | _, _, acc => .ok acc.reverse
  go (ts.length + 1) ts []

/-- What one parsed file contributes. -/
private structure ModOut where
  env : PEnv
  fns : List RawFn
  primer : Option Raw
  workflow : Option Raw

/-- The headers (`define` and `function`, in order, `import` lines skipped) and
then the file's body: a `workflow` block for a program, bare priming statements
for a library. -/
private def parseModuleSrc (env0 : PEnv) (ov : List (String × Prompt))
    (qual : Option String) (src : String) : Except CheckError ModOut := do
  let ts ← lex src
  -- skip the import lines the walk has already honoured
  let rec skipImports : Nat → List Tok → List Tok
    | 0, ts => ts
    | fuel + 1, ⟨.ident "import", _⟩ :: ⟨.ident _, _⟩ :: rest => skipImports fuel rest
    | _, ts => ts
  let ts := skipImports (ts.length + 1) ts
  let rec headers (fuel : Nat) (env : PEnv) (fns : List RawFn) (ts : List Tok) :
      Except CheckError (PEnv × List RawFn × List Tok) :=
    match fuel, ts with
    | 0, _ => .error ⟨posOf ts, "internal: parser budget exhausted in the headers", ""⟩
    | _ + 1, ⟨.ident "import", ip⟩ :: _ =>
      .error ⟨ip, "imports come first, before any define or function", "import"⟩
    | fuel + 1, ⟨.ident "define", dp⟩ :: rest => do
      let (x, rest) ← expectIdent rest
      let full := env.q x
      if env.defs.any (fun d => d.1 == full) then
        .error ⟨dp, "this name is already defined, and the earlier body would \
                    silently win; one define per name", x⟩
      else do
        let rest ← expectPunct '=' rest
        let bpos := posOf rest
        let (pr, rest) ← expectStr rest
        let body ← match ov.find? (fun o => o.1 == full) with
          | some o => .ok o.2
          | none =>
            let b := prompt env pr
            if b.any (fun ch => match ch with | .interp _ => true | .lit _ => false) then
              .error ⟨bpos, "a define is literal text: only holes naming earlier \
                            defines are legal in one", x⟩
            else .ok b
        headers fuel { env with defs := env.defs ++ [(full, body)] } fns rest
    | fuel + 1, ⟨.ident "function", fp⟩ :: rest => do
      let (fn, rest) ← parseFn env fp rest
      headers fuel { env with fnAr := env.fnAr ++ [(fn.name, fn.params.length)] }
        (fns ++ [fn]) rest
    | _, ts => .ok (env, fns, ts)
  let (env, fns, ts) ← headers (ts.length + 1)
    { env0 with qual := qual, qualRefs := false } [] ts
  -- An override nobody asked for is an error, diagnosed where the missing
  -- `define` would have had to be written. Checked for the program, whose
  -- table by now holds every module's defines.
  let _ ← if qual.isNone then
      match ov.find? (fun o => !env.defs.any (fun d => d.1 == o.1)) with
      | some o =>
        .error (⟨posOf ts, s!"this program has no `define {o.1}` to override", o.1⟩ :
          CheckError)
      | none => .ok ()
    else .ok ()
  match ts with
  | ⟨.ident "workflow", wp⟩ :: rest =>
    if qual.isSome then
      .error ⟨wp, "this file has a `workflow` block, so it is a program; a \
                  program is run, not imported", "workflow"⟩
    else do
      let (b, rest) ← parseBlock env (rest.length + 1) rest
      match rest with
      | [] => .ok ⟨env, fns, none, some b⟩
      | _ => .error (unexpected rest "the end of the source after the workflow")
  | _ =>
    if qual.isNone then
      match ts with
      | [] => .error ⟨⟨0, 0⟩, "expected `workflow`, but the source ended", ""⟩
      | _ => do
        -- No `workflow` block, so the file is a library — and a library may be
        -- run: its priming, then nothing. What the standing context costs is
        -- worth being able to ask, so `agent-cat cost library.wf` answers.
        let (b, rest) ← parsePrimer { env with qualRefs := false } (ts.length + 1) ts
        match rest with
        | [] => .ok ⟨env, fns, some b, none⟩
        | t :: _ =>
          .error ⟨t.pos, "a file is a program (`workflow { … }`) or a library \
                         (its priming, then the end of the file); expected \
                         `workflow`, or the end of the library", t.tok.excerpt⟩
    else do
      let (b, rest) ← parsePrimer { env with qualRefs := true } (ts.length + 1) ts
      match rest with
      | [] => .ok ⟨env, fns, some b, none⟩
      | t :: _ => .error ⟨t.pos, "expected the end of the library", t.tok.excerpt⟩

/-- Splice one straight-line block ahead of another: the priming's single
`.empty` exit becomes the next block. Total; the parser guarantees a priming is
straight-line, so the branching clauses are unreachable from any program. -/
def spliceBlock : Raw → Raw → Raw
  | .empty _, b => b
  | .bind x a s r p, b => .bind x a s (spliceBlock r b) p
  | .act a r p, b => .act a (spliceBlock r b) p
  | .callStmt f as r p, b => .callStmt f as (spliceBlock r b) p
  | .knownHere n r p, b => .knownHere n (spliceBlock r b) p
  | t, _ => t

/-- The import walk: post-order depth-first from the main file, each module
emitted once, cycles refused by the in-progress stack, every module found in
the `(name, source)` list the front end was given. Pure: the CLI does the
filesystem; this does the language. -/
private def walkImports (ov : List (String × Prompt))
    (mods : List (String × String)) :
    Nat → List String → List String → PEnv → List RawFn → List Raw →
    List (String × Pos) →
    Except CheckError (List String × PEnv × List RawFn × List Raw)
  | 0, _, _, _, _, _, _ =>
    .error ⟨⟨0, 0⟩, "internal: the module walk exhausted its budget", ""⟩
  | _ + 1, visited, _, env, fns, primers, [] => .ok (visited, env, fns, primers)
  | fuel + 1, visited, stack, env, fns, primers, (m, ip) :: rest =>
    if stack.contains m then
      -- The stack is innermost-first; the cycle reads outermost-first, closed
      -- by the name that reappeared.
      .error ⟨ip, s!"the imports cycle: {String.intercalate " -> " (stack.reverse ++ [m])}", m⟩
    else if visited.contains m then
      walkImports ov mods fuel visited stack env fns primers rest
    else
      match mods.find? (fun q => q.1 == m) with
      | none =>
        .error ⟨ip, s!"module `{m}` is not among the sources this front end was \
                      given (the CLI resolves `{m}.wf` beside the program)", m⟩
      | some (_, src) => do
        -- A diagnosis inside a library names its file: the position is in the
        -- library's text, not the program's.
        let inMod := fun (e : CheckError) =>
          { e with message := s!"in module `{m}`: {e.message}" }
        let subs ← (importsOf src).mapError inMod
        let (visited, env, fns, primers) ←
          walkImports ov mods fuel visited (m :: stack) env fns primers subs
        let out ← (parseModuleSrc { env with mods := env.mods ++ [m] } ov
          (some m) src).mapError inMod
        let primers := match out.primer with
          | some p => primers ++ [p]
          | none => primers
        let env' : PEnv :=
          { out.env with mods := env.mods ++ [m], qual := none, qualRefs := false }
        let env := env' 
        walkImports ov mods fuel (m :: visited) stack env (fns ++ out.fns) primers rest

/-- `[[parseProgramWith ov mods main]]` = the whole program: every reachable
library's functions, and one block — the primings, post-order, ahead of the
workflow. -/
def parseProgramWith (ov : List (String × Prompt))
    (mods : List (String × String)) (main : String) :
    Except CheckError RawProgram := do
  let imps ← importsOf main
  let fuel := mods.foldl (fun n q => n + q.2.length + 2) (imps.length + 2)
  let (_, env, fns, primers) ← walkImports ov mods fuel [] [] {} [] [] imps
  let out ← parseModuleSrc env ov none main
  let all := fns ++ out.fns
  match out.workflow, out.primer with
  | some w, _ => .ok ⟨all, primers.foldr spliceBlock w⟩
  -- A library run alone: its priming is the whole program.
  | none, some b => .ok ⟨all, primers.foldr spliceBlock b⟩
  | none, none => .error ⟨⟨0, 0⟩, "a program has a `workflow` block", ""⟩

/-- `[[parseWith ov s]]` = the raw syntax of a single-file program: the program
front end with no modules. Kept for the flagship's parse pin and every caller
that reads one file. -/
def parseWith (ov : List (String × Prompt)) (s : String) : Except CheckError Raw := do
  let prog ← parseProgramWith ov [] s
  .ok prog.main

/-- `[[parse s]]` = the raw syntax `s` writes, or the first thing in `s` that is
not syntax. -/
def parse (s : String) : Except CheckError Raw := parseWith [] s

end Agentic.Core.Dsl
