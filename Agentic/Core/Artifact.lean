import Agentic.Core.Report

/-!
# The artifact: what an act left outside the process, read back

`Decode .ack _ = some ()` — an acknowledgement carries no information. So every
proposition this package can state about an *act* is a proposition about the
question that was put, and what the act actually did is a fact about a file. This
module is where that fact is read back and compared with what was asked for, and
it is deliberately the smallest module in the package that touches a filesystem.

**The trust boundary, stated.** Nothing here is axiomatised and nothing here is a
theorem about the world: `IO.FS.readFile` returning bytes is not evidence that
those bytes are what an agent wrote, and a directory an agent may write to is a
directory anybody may write to. What these definitions buy is the *falsifiability*
of an act: an act that quietly applied something other than what was approved
produces a directory that fails `ArtifactCheck.ok`, and a harness that never
looks cannot tell that run from a correct one. The measured failure this exists
to catch — a patch applied after consent that reintroduced the exact defect the
reviewers objected to, with every semantic check passing — is recorded in
`demo/Main.lean`, which exercises the check in both directions on every run.

**What is proved here, and it is not much.** The pure part is three list
functions with characterizations (`mem_missingFrom_iff`, `missingFrom_eq_nil_iff`,
`addedLines_length_ge`). The `String` part is *not* proved and cannot be in this
Lean: `String.startsWith`, `String.splitOn` and friends do not reduce in the
kernel and have no infix/prefix characterization in core, so `occursIn` is not
provably "occurs in" and `stripAffix` is not provably the inverse of
`fun s => pre ++ s ++ suf`. Both are checked at runtime by their consumer, on
every run, before the check that rests on them — which is the same discipline
`Exec.norm`'s docstring sets for the trusted base.
-/

namespace Agentic.Core

/-! ## What a diff claims, and what a directory holds -/

/-- `[[addedLines patch]]` = the lines a unified diff claims to add: `+` lines,
less the `+++` header, trimmed, and less anything too short to identify a file
by (a bare `}` says nothing about which file it came from). -/
def addedLines (patch : String) : List String :=
  (patch.splitOn "\n").filterMap fun raw =>
    let l := raw.trimAscii.toString
    if l.startsWith "+++" || !l.startsWith "+" then none
    else
      let body := (l.drop 1).trimAscii.toString
      if body.length < 4 then none else some body

/-- **Every claimed line is long enough to identify something.** The filter's
whole purpose, as a proposition: a check that a directory contains the string
`}` would pass against any C file ever written, so a line that short is not
evidence and is not reported as a claim. -/
theorem addedLines_length_ge (patch : String) : ∀ l ∈ addedLines patch, 4 ≤ l.length := by
  intro l hl
  rw [addedLines, List.mem_filterMap] at hl
  obtain ⟨raw, _, h⟩ := hl
  simp only at h
  split_ifs at h with h₁ h₂
  have hl' := Option.some.inj h
  subst hl'
  omega

/-- `[[occursIn hay needle]]` = does `needle` occur in `hay`? `splitOn` cuts at
every occurrence, so "more than one piece" is "at least one occurrence".

Not proved equivalent to `List.IsInfix` on the underlying characters: `splitOn`
is an iterator loop over an opaque byte array, and no core lemma relates it to
anything. The equation is stated here as the *intent* and is exercised by its
consumers rather than proved. -/
def occursIn (hay needle : String) : Bool := (hay.splitOn needle).length > 1

/-- `[[missingFrom texts ls]]` = the claimed lines that no text holds. -/
def missingFrom (texts : List String) (ls : List String) : List String :=
  ls.filter (fun l => !texts.any (occursIn · l))

/-- **What the report of a failure says**, exactly: a line is reported missing
when it was claimed and no file holds it. -/
theorem mem_missingFrom_iff (texts ls : List String) (l : String) :
    l ∈ missingFrom texts ls ↔ l ∈ ls ∧ texts.all (fun t => !occursIn t l) = true := by
  simp [missingFrom, List.mem_filter]

/-- **…and what a success says**: nothing is missing exactly when every claimed
line occurs in some file. -/
theorem missingFrom_eq_nil_iff (texts ls : List String) :
    missingFrom texts ls = [] ↔ ∀ l ∈ ls, texts.any (occursIn · l) = true := by
  simp [missingFrom, List.filter_eq_nil_iff]

/-- `[[stripAffix pre suf s]]` = what `s` says between a known prefix and a known
suffix, or `none` where it does not have them. Used to recover the content of a
question from the words it was wrapped in, which is the only place a run's `IO`
layer can see it — the transcript holds questions and answers, and the content is
inside a question.

That this inverts `fun body => pre ++ body ++ suf` is a fact about
`String.startsWith`, `String.endsWith`, `drop` and `dropEnd`, none of which
reduce in this Lean's kernel. It is therefore checked at runtime, on every run,
before the check that depends on it. -/
def stripAffix (pre suf s : String) : Option String :=
  if s.startsWith pre && s.endsWith suf && pre.length + suf.length ≤ s.length then
    some (((s.drop pre.length).dropEnd suf.length).toString)
  else none

/-! ## The filesystem, and the check against it

Three `IO` definitions and one structure. The structure is what a consumer reads:
a check that *throws* cannot be asserted to fail, and asserting the failure is
the only way a check like this is known to have teeth.
-/

/-- The regular files of `dir`, as name and contents. A file that cannot be read
as text is skipped rather than fatal: the question here is what an act wrote, and
a directory the agent also put a binary in is not itself a failure. -/
def fileTexts (dir : String) : IO (List (String × String)) := do
  let entries ← (System.FilePath.mk dir).readDir
  let mut out : List (String × String) := []
  for e in entries do
    if !(← e.path.isDir) then
      match ← (IO.FS.readFile e.path).toBaseIO with
      | .ok txt => out := (e.fileName, txt) :: out
      | .error _ => pure ()
  return out.reverse

/-- What a run left in its directory, one name per line. -/
def listDir (dir : String) : IO (List String) := do
  let entries ← (System.FilePath.mk dir).readDir
  return (entries.map (·.fileName)).toList

/-- `[[mkScratchDir]]` = a fresh `mktemp -d`, and the reason a run of a workflow
that ends in an act is allowed to act at all.

`Acp.Permission.grant`'s stated assumption is that a tool call *inside the
session's working directory*, made *during a question that asked for an effect*,
is authorized by the act of starting the run there (`Agentic/Core/Acp.lean`,
`Exec.permissionByCode`). A run whose working directory is a repository is a run
authorized to edit that repository. So a run that acts is given a directory
nobody minds, and what the act leaves in it is what `ArtifactCheck` reads — and
what anything *else* left in it is what `WorkspaceDiff` reads. -/
def mkScratchDir : IO String := do
  let out ← IO.Process.run { cmd := "mktemp", args := #["-d"] }
  return out.trimAscii.toString

/-! ## The workspace: what the run is given to act on

`mkScratchDir` answers *where may a run write*. It does not answer *what is
there to write about*, and the measured failure that makes this section exist is
exactly that gap.

**The failure, recorded.** `agent-cat run example/harden.wf --adapter claude`
was run in a fresh, empty scratch directory. The author model answered —
correctly — that it could not produce a diff, because the working directory held
no parser to patch; the three reviewers approved that explanation; the owner was
asked to consent to it; and every check printed `ok`, because every check in
`cli/AgentCat.lean` is about the *shape* of a run and that run had the right
shape. The same failure is recorded from the other side in `demo/Main.lean`,
whose `seedText` was the demo's private fix for it. This section is that fix
made general: a workflow that acts on files needs something to act on, and which
files those are is an input to a run and not a constant in a demo.

**Why the header prints what was seeded.** An empty directory is a legitimate
state — some workflows create rather than change — so seeding nothing is not an
error. What is not acceptable is that it be *silent*: `Seeded.render` always
emits at least one line (`Seeded.render_ne_nil`), and when nothing was copied
that line says so in words. An author is allowed to be surprised by an empty
workspace once.

**The trust boundary.** Copying is ordinary `IO` and proves nothing: that the
bytes now in the scratch directory are the bytes of `DIR` is a fact about the
filesystem, not a theorem. What the code does guarantee by construction is the
direction of travel — every operation reads `DIR` and writes the scratch
directory, and there is no call here that could modify `DIR` — and that a
symbolic link is refused rather than followed, so a workspace cannot hand a run
a file the header did not name.
-/

/-- `[[Seeded]]` = what a run's fresh directory was given before the first
question was put: where the contents came from, what arrived, and what did not.

A value rather than a printout, for `ArtifactCheck`'s reason: a caller that
wants to *assert* something about the seeding — a test that a symlink was
refused, say — needs the facts and not the prose. -/
structure Seeded where
  /-- The directory the contents were copied from, or `none` when the run
  starts in an empty directory. -/
  source : Option String
  /-- One entry per ordinary file copied: its path relative to the workspace
  root, and its size in bytes. -/
  files : List (String × Nat) := []
  /-- One entry per thing that was *not* copied, with the reason it was not. -/
  refused : List (String × String) := []
  deriving Repr, Inhabited

/-- How deeply a workspace may nest before the copy stops descending. A bound
rather than a `partial` walk, for `Agentic/Core/Acp.lean`'s reason: every loop
in this package is structural on an explicit fuel, so a cyclic or pathological
directory is a reported refusal and never a hung run. -/
def workspaceDepth : Nat := 16

/-- One breadth-first level of the copy: every directory in `todo` is read, its
ordinary files are written into the matching destination, and its
subdirectories are created and handed to the next level.

Structural on the fuel, with the single recursive call outside both loops, so
the termination argument is the fuel and nothing else. Entries are sorted by
name, so the header a reader sees is a function of the workspace and not of the
order the filesystem happened to return. -/
private def copyLevel :
    Nat → List (System.FilePath × System.FilePath × String) →
    IO (List (String × Nat) × List (String × String))
  | _, [] => return ([], [])
  | 0, todo =>
    return ([], todo.map fun t =>
      (t.2.2, s!"is nested more than {workspaceDepth} directories deep, and was not descended into"))
  | fuel + 1, todo => do
    let mut files : List (String × Nat) := []
    let mut refused : List (String × String) := []
    let mut next : List (System.FilePath × System.FilePath × String) := []
    for (src, dst, rel) in todo do
      match ← (src.readDir).toBaseIO with
      | .error e => refused := refused ++ [(rel, s!"could not be listed ({e})")]
      | .ok entries =>
        for e in entries.qsort (fun a b => decide (a.fileName < b.fileName)) do
          let name := e.fileName
          let here := if rel.isEmpty then name else rel ++ "/" ++ name
          -- `symlinkMetadata` and not `metadata`: the latter follows the link,
          -- which is the thing this refuses to do.
          match ← (e.path.symlinkMetadata).toBaseIO with
          | .error err => refused := refused ++ [(here, s!"could not be inspected ({err})")]
          | .ok md =>
            match md.type with
            | .symlink =>
              refused := refused ++ [(here,
                "is a symbolic link; a workspace is copied and not followed, so a link \
                 would give the run a file this header does not name")]
            | .dir =>
              match ← (IO.FS.createDirAll (dst / name)).toBaseIO with
              | .error err => refused := refused ++ [(here, s!"could not be created ({err})")]
              | .ok _ => next := next ++ [(src / name, dst / name, here)]
            | .file =>
              match ← (IO.FS.readBinFile e.path).toBaseIO with
              | .error err => refused := refused ++ [(here, s!"could not be read ({err})")]
              | .ok bytes =>
                match ← (IO.FS.writeBinFile (dst / name) bytes).toBaseIO with
                | .error err => refused := refused ++ [(here, s!"could not be written ({err})")]
                | .ok _ => files := files ++ [(here, bytes.size)]
            | _ =>
              refused := refused ++ [(here,
                "is neither an ordinary file nor a directory, and a run is given neither")]
    let (f, r) ← copyLevel fuel next
    return (files ++ f, refused ++ r)

/-- `[[WorkspaceChoice]]` = what a caller said about the workspace: nothing
(`auto`, and the convention decides), a directory, or `off`.

Three constructors and not a `Option String`, because "the caller said nothing"
and "the caller said no workspace" are different instructions and only one of
them may consult the convention. -/
inductive WorkspaceChoice where
  /-- Nothing was said: use `conventionalWorkspace` if it is there. -/
  | auto
  /-- Use this directory, and fail if it is not one. -/
  | dir (path : String)
  /-- Start empty on purpose. -/
  | off
  deriving DecidableEq, Repr, Inhabited

/-- `[[conventionalWorkspace program]]` = the directory that sits beside a
program and holds what the program acts on: `example/harden.wf` →
`example/harden.d`.

The extension is *replaced* rather than appended, so the workspace is a sibling
named after the program rather than a child of its filename. An author who does
not want the convention writes `--no-workspace`; an author who wants a different
one writes `--workspace DIR`. -/
def conventionalWorkspace (program : String) : String :=
  ((System.FilePath.mk program).withExtension "d").toString

-- The convention, on the program it was written for, and on one whose name has
-- no extension at all. `#guard` and not a theorem: `withExtension` is `String`
-- surgery that this Lean's kernel does not reduce, so the claim is checked by
-- the evaluator at elaboration time, which is the same discipline `occursIn`
-- above is held to.
#guard conventionalWorkspace "example/harden.wf" == "example/harden.d"
#guard conventionalWorkspace "run" == "run.d"

/-- `[[seedWorkspace choice program dst]]` = `dst`, seeded, and the account of
what went into it.

**`DIR` is never written to.** Every filesystem call below either reads the
source or writes the destination; there is no call that could modify the
workspace, which is what makes running the same program twice against the same
workspace two runs of the same program.

**An absent workspace is not an error, and an unusable one is.** Under `auto`
the convention is a convenience: a program with no `.d` beside it runs in an
empty directory and the header says so. Under `dir` the caller named a
directory, so a name that is not a readable directory is a mistake and is
raised — a run that quietly ignored `--workspace` would be the very failure this
mechanism exists to prevent. -/
def seedWorkspace (choice : WorkspaceChoice) (program : String) (dst : String) : IO Seeded := do
  let src? : Option String ←
    match choice with
    | .off => pure none
    | .dir p => pure (some p)
    | .auto =>
      let p := conventionalWorkspace program
      if ← (System.FilePath.mk p).isDir then pure (some p) else pure none
  match src? with
  | none => return { source := none }
  | some src =>
    unless ← (System.FilePath.mk src).isDir do
      throw <| IO.userError s!"workspace: {src} is not a directory that can be read"
    let (files, refused) ←
      copyLevel workspaceDepth [(System.FilePath.mk src, System.FilePath.mk dst, "")]
    return { source := some src, files := files, refused := refused }

namespace Seeded

/-- How many bytes the run was handed. -/
def totalBytes (s : Seeded) : Nat := (s.files.map Prod.snd).sum

/-- `[[s.render]]` = the run header's account of the workspace: where it came
from, then one line per file with its size, then one line per refusal.

Printed on every run and not only on the interesting ones, for
`ArtifactCheck.render`'s reason: a report whose evidence appears only when
something went wrong is a report nobody has read before it matters. -/
def render (s : Seeded) : List String :=
  let refusals := s.refused.map fun r => s!"  refused {head 40 r.1}: {r.2}"
  match s.source with
  | none =>
    ["workspace: none — this run starts in an empty directory, so a question that \
      asks for a change to a file has no file to change"] ++ refusals
  | some src =>
    if s.files.isEmpty then
      [s!"workspace: {src} holds nothing to copy — this run starts in an empty directory"]
        ++ refusals
    else
      [s!"workspace: {src} → {s.files.length} \
          {if s.files.length == 1 then "file" else "files"}, {s.totalBytes} bytes"]
        ++ s.files.map (fun f => s!"  {pad 28 f.1}{f.2} bytes")
        ++ refusals

/-- **The header always says something.** The point of the section: an empty
workspace is a legitimate state and a silent one is not, so there is no `Seeded`
whose rendering is nothing at all. -/
theorem render_ne_nil (s : Seeded) : s.render ≠ [] := by
  unfold render
  cases s.source <;> simp
  split <;> simp

/-- **Nothing copied goes unmentioned.** One line of provenance, one line per
file, one line per refusal, and no line for anything else — so counting the
header's lines counts what the agent was given. -/
theorem render_length_of_seeded (s : Seeded) (src : String)
    (hs : s.source = some src) (hf : s.files ≠ []) :
    s.render.length = 1 + s.files.length + s.refused.length := by
  unfold render
  rw [hs]
  simp [List.isEmpty_iff, hf]
  omega

end Seeded

/-! ## The workspace before and after: what a run actually changed

`Seeded` says what a run was *given*. Nothing above says what it *left*, and the
measured defect that makes this section exist is precisely that gap
(`acat-08l`). In a refusing run of the flagship — the owner answered `no`, the
transcript held six turns, no act was put, and `Harden.no_ack_of_refused` was
satisfied — the scratch `parse.c` was nevertheless replaced by a hardened
version. The birth time of the file placed the write inside the *author's* draft
turn: an editing tool, granted permission by a connection-wide policy that could
not tell an ask from an act. Every check the run made passed, because every
check was about the shape of the run, and the bytes are not part of any shape.

**What this is.** Evidence about one run: a fingerprint of the run's directory
taken after seeding and again when the run ends, and the difference between
them. Files created, modified or removed, with sizes and a content hash.

**What this is not.**

* It is *not a theorem*. Nothing here is proved about any run; what is proved is
  that the comparison says "unchanged" when nothing changed
  (`WorkspaceDiff.of_self`) and that its verdict is exactly the disjunction it
  claims (`WorkspaceDiff.changed_eq_true_iff`). Whether the fingerprint is an
  honest reading of a filesystem is a fact about `IO.FS.readBinFile`, in the
  same class as `ArtifactCheck`'s reading of the same directory.
* It is *defeated by a write outside the workspace*. A run's directory is the
  only place looked at, so an agent that edits `~/.bashrc`, or the repository it
  was started from, leaves this check reporting nothing at all. The permission
  policy (`Exec.permissionByCode`) is what is supposed to prevent that; this is
  what notices when it did not.
* It cannot attribute a change to anybody. It says the bytes differ, not who
  differed them — a second process writing into the same temporary directory
  would be reported identically.
* The hash is FNV-1a, not a cryptographic digest: it detects an edit, and an
  adversary who wants a collision can have one.
-/

/-- The FNV-1a offset basis, as `UInt64`. -/
def hashBasis : UInt64 := 14695981039346656037

/-- The FNV-1a prime. -/
def hashPrime : UInt64 := 1099511628211

/-- `[[hashBytes bs]]` = FNV-1a over the bytes, in 64 bits.

Written out here rather than shelled out to `sha256sum`, for the reason every
loop in this package is structural on a fuel: a check that spawns a process to
say whether a file changed is a check that fails when the process is missing,
and a run that cannot tell whether it wrote to the workspace should not be a
run that reports success. Total, one pass, no allocation beyond the fold. -/
def hashBytes (bs : ByteArray) : UInt64 :=
  bs.foldl (fun h b => (h ^^^ b.toUInt64) * hashPrime) hashBasis

-- The empty file hashes to the basis, and one flipped byte does not hash to
-- what it flipped from. `#guard` and not theorems: `ByteArray.foldl` is a loop
-- over an opaque array that this Lean's kernel does not reduce, so the claims
-- are checked by the evaluator at elaboration time, which is the discipline
-- `occursIn` above is held to.
#guard hashBytes ByteArray.empty == hashBasis
#guard hashBytes ⟨#[1]⟩ != hashBytes ⟨#[2]⟩
#guard hashBytes ⟨#[1, 2]⟩ != hashBytes ⟨#[2, 1]⟩

/-- `[[hex n]]` = a `UInt64` in base sixteen, for a report a person reads. -/
def hex (n : UInt64) : String := String.ofList (Nat.toDigits 16 n.toNat)

/-- `[[FileStamp]]` = one file of a workspace as a fingerprint sees it: where it
is, how big it is, and what is in it.

The path is relative to the workspace root, so two fingerprints of the same
directory taken at different times are comparable, and a temporary directory's
name never appears in a diff. -/
structure FileStamp where
  /-- The path relative to the workspace root. -/
  path : String
  /-- The size in bytes. -/
  size : Nat
  /-- `hashBytes` of the contents. -/
  hash : UInt64
  deriving DecidableEq, Repr, Inhabited

/-- `[[Fingerprint]]` = a whole workspace, stamped: one entry per ordinary file,
in a deterministic order (each directory's entries sorted by name, shallowest
first). -/
abbrev Fingerprint := List FileStamp

/-- One breadth-first level of the fingerprint, structural on the fuel, exactly
as `copyLevel` is and for the same reason: a cyclic or pathological directory is
a reported entry and never a hung run.

Every unreadable thing becomes an entry whose path *says* it was unreadable
rather than being dropped: a file that appears and cannot be read is a change,
and a fingerprint that omitted it would report no change. A symbolic link is
recorded by its presence and not followed — the same refusal `copyLevel` makes —
so a link whose *target* changed is a change this does not see. -/
private def stampLevel : Nat → List (System.FilePath × String) → IO Fingerprint
  | _, [] => return []
  | 0, todo =>
    return todo.map fun t =>
      { path := s!"{t.2}/… (more than {workspaceDepth} deep, not descended into)"
      , size := 0, hash := 0 }
  | fuel + 1, todo => do
    let mut here : Fingerprint := []
    let mut next : List (System.FilePath × String) := []
    for (dir, rel) in todo do
      match ← dir.readDir.toBaseIO with
      | .error _ =>
        here := here ++ [{ path := s!"{rel} (could not be listed)", size := 0, hash := 0 }]
      | .ok entries =>
        for e in entries.qsort (fun a b => decide (a.fileName < b.fileName)) do
          let name := e.fileName
          let path := if rel.isEmpty then name else rel ++ "/" ++ name
          match ← e.path.symlinkMetadata.toBaseIO with
          | .error _ =>
            here := here ++ [{ path := s!"{path} (could not be inspected)", size := 0, hash := 0 }]
          | .ok md =>
            match md.type with
            | .dir => next := next ++ [(e.path, path)]
            | .symlink =>
              here := here ++ [{ path := s!"{path} (a symbolic link)", size := 0, hash := 0 }]
            | _ =>
              match ← (IO.FS.readBinFile e.path).toBaseIO with
              | .error _ =>
                here := here ++ [{ path := s!"{path} (could not be read)", size := 0, hash := 0 }]
              | .ok bytes =>
                here := here ++ [{ path := path, size := bytes.size, hash := hashBytes bytes }]
    let deeper ← stampLevel fuel next
    return here ++ deeper

/-- `[[fingerprint dir]]` = what `dir` holds, stamped. A directory that cannot
be read at all fingerprints as one entry saying so, which is a change from a
directory that could be. -/
def fingerprint (dir : String) : IO Fingerprint :=
  stampLevel workspaceDepth [(System.FilePath.mk dir, "")]

/-- `[[WorkspaceDiff]]` = two fingerprints of one directory, compared: what
appeared, what changed, and what went away. -/
structure WorkspaceDiff where
  /-- Files whose path was not there before. -/
  created : List FileStamp
  /-- Files whose path was there and whose contents are not what they were, as
  the stamp before and the stamp after. -/
  modified : List (FileStamp × FileStamp)
  /-- Files whose path is no longer there, as they last were. -/
  removed : List FileStamp
  deriving Repr, Inhabited

namespace WorkspaceDiff

/-- `[[WorkspaceDiff.of before after]]` = the difference between two
fingerprints of one directory.

`modified` tests the *whole stamp* for membership and not the hash against a
looked-up entry, which is what makes `of_self` hold with no side condition about
paths being distinct: a stamp that is in both fingerprints is unchanged by
construction, whatever else shares its path. -/
def of (before after : Fingerprint) : WorkspaceDiff where
  created := after.filter fun f => !before.any (·.path == f.path)
  modified := after.filterMap fun f =>
    if before.contains f then none
    else (before.find? (·.path == f.path)).map (fun g => (g, f))
  removed := before.filter fun g => !after.any (·.path == g.path)

/-- `[[d.changed]]` = did anything at all differ? -/
def changed (d : WorkspaceDiff) : Bool :=
  !(d.created.isEmpty && d.modified.isEmpty && d.removed.isEmpty)

/-- **What the verdict means**, exactly: the disjunction and nothing else, so a
reader of a `changed = true` knows one of the three lists names the evidence. -/
theorem changed_eq_true_iff (d : WorkspaceDiff) :
    d.changed = true ↔ d.created ≠ [] ∨ d.modified ≠ [] ∨ d.removed ≠ [] := by
  simp [changed, or_assoc]

/-- **A workspace compared with itself has not changed.** The property the check
rests on: a run that wrote nothing produces two equal fingerprints, and this says
those are reported as no change — so a `FAIL` from this check is never the
check's own doing. -/
@[simp] theorem of_self (f : Fingerprint) : of f f = ⟨[], [], []⟩ := by
  have hpath : ∀ g ∈ f, (f.any (·.path == g.path)) = true := by
    intro g hg; exact List.any_eq_true.mpr ⟨g, hg, by simp⟩
  refine WorkspaceDiff.mk.injEq .. ▸ ⟨?_, ?_, ?_⟩ <;>
    simp_all [List.filter_eq_nil_iff]

/-- **…and therefore reports no change.** -/
theorem changed_of_self (f : Fingerprint) : (of f f).changed = false := by
  simp [changed]

/-- `[[d.render]]` = the difference as lines, printed on every run and not only
on the interesting ones (`Seeded.render`'s rule): a report whose evidence
appears only when something went wrong is a report nobody has read before it
matters. -/
def render (d : WorkspaceDiff) : List String :=
  if !d.changed then
    ["--- the workspace after the run: unchanged ---"]
  else
    [s!"--- the workspace after the run: {d.created.length} created, \
        {d.modified.length} modified, {d.removed.length} removed ---"]
      ++ d.created.map (fun f =>
          s!"  created  {pad 28 f.path}{f.size} bytes  ({hex f.hash})")
      ++ d.modified.map (fun p =>
          s!"  modified {pad 28 p.2.path}{p.1.size} → {p.2.size} bytes  \
             ({hex p.1.hash} → {hex p.2.hash})")
      ++ d.removed.map (fun f =>
          s!"  removed  {pad 28 f.path}was {f.size} bytes  ({hex f.hash})")

/-- **The difference always says something**, `Seeded.render_ne_nil`'s rule
again: "nothing changed" is a fact a reader is owed and not an omission. -/
theorem render_ne_nil (d : WorkspaceDiff) : d.render ≠ [] := by
  unfold render; split <;> simp

/-- The paths a difference names, for a message that says which files. -/
def paths (d : WorkspaceDiff) : List String :=
  d.created.map (·.path) ++ d.modified.map (·.2.path) ++ d.removed.map (·.path)

/-- `[[d.unauthorised acted]]` = the complaint a run owes its operator, if it
owes one: a run that performed **no act** and whose workspace changed anyway.

`acted` is read off the run's transcript — was an `.ack` event in it — and not
off the command line, because whether an act ran is a fact about the meaning of
the run and the command line only says what was asked for.

**Why the asymmetry.** When an act ran, the difference is information: an act is
a question whose whole point is an effect, the permission layer granted it on
purpose (`Exec.permissionByCode`), and what it wrote is `ArtifactCheck`'s
business rather than this one's. When no act ran, *no question this run asked was
permitted to write*, so bytes that changed anyway were written by something
nobody authorized, and the run is a failure whatever else it proved. -/
def unauthorised (acted : Bool) (d : WorkspaceDiff) : Option String :=
  if acted || !d.changed then none
  else some <|
    s!"the run performed no act — no `ack` question was put, so nothing it asked \
       for was permitted to write — and yet the workspace changed: \
       {String.intercalate ", " d.paths}. Something wrote to the run's directory \
       without authorisation. This is evidence about this run and not a theorem: \
       it names bytes that differ, not who differed them, and a write outside \
       the run's directory would not appear here at all."

/-- **An act's run is never accused.** -/
@[simp] theorem unauthorised_of_acted (d : WorkspaceDiff) : d.unauthorised true = none := by
  simp [unauthorised]

/-- **…nor is a run that changed nothing.** -/
theorem unauthorised_of_unchanged (acted : Bool) {d : WorkspaceDiff}
    (h : d.changed = false) : d.unauthorised acted = none := by
  simp [unauthorised, h]

/-- **…and the complaint is made in exactly the one case.** -/
theorem unauthorised_isSome_iff (acted : Bool) (d : WorkspaceDiff) :
    (d.unauthorised acted).isSome = true ↔ acted = false ∧ d.changed = true := by
  unfold unauthorised
  cases acted <;> cases h : d.changed <;> simp

end WorkspaceDiff

/-- `[[ArtifactCheck]]` = a directory read back, against the lines something
claimed to write into it: what was there, what was claimed, and what is missing.

A value rather than an assertion, so that a harness can require the check to
*fail* — which is the only way its teeth are ever demonstrated. -/
structure ArtifactCheck where
  /-- Where it looked. -/
  dir : String
  /-- What it found: name and contents, one per regular file. -/
  files : List (String × String)
  /-- The identifiable lines the act was asked to write. -/
  claimed : List String
  /-- Those of them no file holds. -/
  missing : List String

namespace ArtifactCheck

/-- `[[ArtifactCheck.of dir claimed]]` = read `dir` back and record which of the
claimed lines is in nothing it holds.

**The comparison, and its limits.** Every claimed line must occur somewhere in
the directory's files. It is deliberately not an equality — a diff is not a file,
and a workflow does not generally tell an agent what to call what it writes — and
deliberately not a substring test against the diff as a whole, which a directory
containing only the diff would pass. It can be fooled by an agent that writes the
claimed lines and other damage besides. It cannot be fooled by an act that
quietly applied something other than what was approved. -/
def of (dir : String) (claimed : List String) : IO ArtifactCheck := do
  let files ← fileTexts dir
  return { dir := dir
         , files := files
         , claimed := claimed
         , missing := missingFrom (files.map (·.2)) claimed }

/-- `[[r.ok]]` = every claimed line is on disk, and something was claimed.

A patch with nothing identifiable in it counts as a failure: an act nobody can
check is not an act anybody should report as `ok`. -/
def ok (r : ArtifactCheck) : Bool := !r.claimed.isEmpty && r.missing.isEmpty

/-- **What `ok` means**, with both halves spelled out. -/
theorem ok_eq_true_iff (r : ArtifactCheck) :
    r.ok = true ↔ r.claimed ≠ [] ∧ r.missing = [] := by
  simp [ok]

/-- `[[r.render]]` = what was found, and what was not, as lines — printed either
way, because a check whose evidence is only shown on failure is a check nobody
reads. At most five missing lines are quoted; the count above them is exact. -/
def render (r : ArtifactCheck) : List String :=
  [s!"--- {r.dir} after the act ---"]
    ++ r.files.map (fun f => s!"  {pad 28 f.1}{f.2.length} bytes")
    ++ [s!"  the patch adds {r.claimed.length} identifiable lines, \
          of which {r.missing.length} are in no file here"]
    ++ (r.missing.take 5).map (fun l => s!"  missing: {head 72 l}")

end ArtifactCheck

end Agentic.Core
