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
session's working directory* is authorized by the act of starting the run there
(`Agentic/Core/Acp.lean`). A run whose working directory is a repository is a run
authorized to edit that repository. So a run that acts is given a directory
nobody minds, and what the act leaves in it is what `ArtifactCheck` reads. -/
def mkScratchDir : IO String := do
  let out ← IO.Process.run { cmd := "mktemp", args := #["-d"] }
  return out.trimAscii.toString

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
