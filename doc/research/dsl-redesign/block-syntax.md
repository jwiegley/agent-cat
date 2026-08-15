# Text blocks, v2 — multi-line Markdown prompts

Amended after adversarial validation (wf_0e4307d2: byte-fidelity audit + 14-finding
edge-case attack). Wherever a STRING LITERAL in prompt or define position may
appear, a text block may appear instead; addressee names and `using model` names
take quoted strings only (`expectPlainStr` refuses a block token).

## The rules

1. OPENING. A fence of three or more backticks (count N), followed on its line by
   nothing but whitespace and, optionally, a `--` comment. Anything else after the
   fence is refused: "the content of a block begins on the next line". Content
   begins on the next line.

2. CLOSING. The first subsequent line whose first non-whitespace characters are
   exactly N backticks followed by nothing but whitespace and, optionally, one of
   `,` `]` `}` `)` and a comment — lexing resumes at that punctuation. A line of N
   backticks followed by a word character is CONTENT (so a pasted ```` ```haskell ````
   inside a three-backtick block does not close it), and a backtick run longer or
   shorter than N is content. Markdown whose content includes a bare three-backtick
   line is quoted with a four-backtick outer fence — CommonMark's own escalation
   rule. An unterminated block is refused at the opening fence's position.

3. LINES AND DEDENT. Content is split on `\n`; a single `\r` immediately before a
   `\n` is not part of the line (CRLF-authored files behave identically). A line is
   BLANK when it contains no non-whitespace character; blank lines are emitted
   empty — their whitespace is dropped — and do not participate in the dedent.
   The longest common whitespace prefix of the non-blank lines, compared
   character-wise, is stripped from each. If two non-blank lines' leading
   whitespace disagrees at a position where both are whitespace (a tab against a
   space), the block is refused: "this block mixes tabs and spaces in its
   indentation". A block with no non-blank line has common prefix "" and denotes
   its blank lines verbatim.

4. JOIN. The dedented lines are joined with `\n`. No trailing newline: the closing
   fence's line break is a terminator, not content. A final blank content line
   adds one if wanted.

5. HOLES AND THE ONE ESCAPE. A hole is exactly `{` `$`? name `}` where name
   is isIdentStart isIdentCont* — the same hole grammar the quoted form has:
   `{x}` splices an ANSWER as text (a text answer is itself; a verdict is its
   objections), `{$x}` expands a DEFINE (literal text, so the question stays
   closed). `\{` is a literal brace. EVERYTHING ELSE IS LITERAL: quotes, lone
   backslashes, short backtick runs, tabs, Markdown's own escapes. Any other `{`
   is refused at lex time with a message naming `\{`. Two stated limits: a literal
   backslash immediately before a hole cannot be written in a block (use the
   quoted form); and pasted Markdown survives verbatim EXCEPT `{`, which must be
   written `\{` wherever it is not a hole — including inside code spans.

6. CHUNKS. A literal run is flushed only at a hole boundary or at the closing
   fence; line boundaries never split chunks. The chunk list of a block IS the
   chunk list of its dedented join:

       lex (block b) = lex (quote (dedentJoin b))

   where `quote` doubles `\`, escapes `"` as `\"`, `{` as `\{` where not a hole,
   and newlines as `\n`. This identity is pinned the way the flagship's parse is
   pinned — a `decide` on `DecidableEq Raw` in test/DslSmoke.lean comparing the
   block spelling of each flagship prompt against its quoted spelling. It is a
   runtime test, not a kernel theorem, exactly like `parse flagshipSource = .ok
   flagshipRaw` (DslFlagship.lean:114-117) — stated honestly.

## Meaning

A block is a string: same Chunk lists, so Prompt.closed, the checker, Plan, level
and the cost tree are untouched. The dedent is per-block and applies to the source
text before any hole is filled — what the addressee is told is the file's text
shifted left, with holes then filled (a multi-line define splices without
re-indentation, as in the quoted form).

## Fidelity for the amended flagship — the honest statement

- Six of the seven blocks dedent+join to the byte-identical prompt strings the
  quoted flagship carried (verified by hand against DslFlagship.lean:118-180).
- (Historical: at validation time the amend block read `{why.reasons}`; round
  twelve deleted the projection, and the hole is now `{verdict}`.) It read
  `{why.reasons}` where the incumbent wrote `{why}`: the new
  surface moves the verdict renderer from the binder to the use site. chunkExpr
  splits the name at the dot and produces THE SAME Expr the incumbent produced
  (Verdict.render ∘ Env.head at the same de Bruijn index), so the elaborated Plan
  node is the same term — but the SOURCE is a different spelling, and no
  byte-identity is claimed for it.
- The kernel theorems are about flagshipRaw, not about the parser; re-spelling the
  file obsoletes every recorded Pos, so flagshipRaw is re-transcribed (new
  positions, new constructors) and test/DslSmoke.lean's `parse flagshipSource =
  .ok flagshipRaw` is re-baselined. DslFlagship.lean:100's leading-newline
  invariant is re-stated for the new file or dropped.
- A companion example must exercise what the flagship does not: an interior blank
  line, a `\{`, a three-backtick fence under a four-backtick outer fence, a
  trailing blank line, and a `{$x}`/`{x}` pair in one prompt.

## Lexer feasibility (from the attack, confirmed)

A fence scanner recursing on remaining characters, seeded from the same
`cs.length + 1` budget, preserves Parse.lean:10-26's fuel discipline — every path
consumes at least the N backticks and a newline. Kernel-reducibility is untouched;
`decide +kernel` costs scale with the same character counts as scanString.
