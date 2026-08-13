import Agentic

/-! The owner's workflow, in the authoring surface. See `Agentic/Surface.lean`
for the five words.
-/

namespace Agentic.Examples

def hardenPatch (spec : String) : W Unit := do
  let guide : String ← ask "Write out the house style guide."
  let patch ← revising 2 spec fun current => do
    let patch ← model "deep" <| ask s!"Draft a patch satisfying:\n{current}"
    let verdict ← panel
      [ ask s!"{guide}\nIs this patch correct?\n{patch}"
      , ask s!"{guide}\nIs this patch secure?\n{patch}"
      , ask s!"Could this patch be simpler?\n{patch}" ]
    pure (patch, verdict)
  let ok : Bool ← askHuman s!"Apply this patch?\n{patch}"
  if ok then ask s!"Apply:\n{patch}" else pure ()

end Agentic.Examples
