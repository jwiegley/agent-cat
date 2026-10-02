import ManagerConformance.Exec
import ManagerConformance.Admission
import ManagerConformance.Checks

/-!
# The manager conformance library

This library is the Lean side of the manager conformance bridge. It imports
only `Agentic.Manager.*` and Lean core, with the `Mathlib.Data.Finmap` closure
that the manager model imports. It never imports `Agentic.Core` or the root
module of the model.

`ManagerConformance.Exec` instantiates the coordination model at `String`
identities and `String` values. It defines a finite evidence table and the
executable deciders of the guarded transitions, and it proves that each
decider equals its model transition. `ManagerConformance.Admission` reduces
the quantified guards of `admit` and `approve` to finite entries of the state,
gives their `Decidable` instances, and proves that the deciders of the two
transitions equal the model transitions. `ManagerConformance.Checks` guards
the axiom footprint of each equality and evaluates at least one accepted and
one refused closed witness for each decider.
-/
