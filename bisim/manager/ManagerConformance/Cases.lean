import ManagerConformance.Codec

/-!
# The retained cases of the manager oracle

Each case is one oracle request and the outcome that it must have. The cases
cover the scenarios of `model/test/ManagerChecks.lean` at string identities,
and the witnesses of the deciders in `ManagerConformance.Checks`. The
executable `manager-cases` writes each case to `bisim/manager/cases` as a
request file and an expected response file. The malformed cases are request
texts that must receive an error and no state.

The `#guard` commands below fix the outcome of every case, the round trip of
every request, and the intermediate states of the chained scenarios, so a
change of a decider or of the encoding fails the build before it can change a
retained file.
-/

namespace ManagerConformance.Cases

open Agentic.Manager

/-- One retained request with the outcome that it must have. -/
structure Case where
  name : String
  query : Query
  accepted : Bool

/-! ## The scenarios of the model checks at string identities

`model/test/ManagerChecks.lean` uses natural-number identities and an
evidence world in which every fact holds. The same scenarios below use the
decimal strings of those identities, and a table that lists each fact that a
scenario uses. -/

namespace Model

def profile : Profile String := ⟨"4", true, {"30"}⟩
def lease : Reservation String := ⟨"7", {"30"}⟩
def request : Request String :=
  ⟨"2", "3", "4", .queued, some 0, ⟨{"10"}, Finmap.singleton "10" "20", ∅⟩, none, none⟩
def reviewed : Request String := { request with phase := .review, preparation := some "8" }
def prepared : Prepared String String :=
  ⟨"1", "2", "3", "4", "9", "10", "11", "5", "6", "12", "13", "exact review", .live⟩

def queued : State :=
  ⟨"5", "6", {"7"}, Finmap.singleton "3" profile, Finmap.singleton "1" request,
    ∅, ∅, ∅, ∅, ∅, ∅, Finmap.singleton "20" "captured input", ∅⟩

def review : State :=
  { queued with
    requests := Finmap.singleton "1" reviewed
    reservations := Finmap.singleton "1" lease
    preparations := Finmap.singleton "8" prepared
    runs := Finmap.singleton "9" "1"
    supervision := Finmap.singleton "9" .owned }

def first : DecisionKey String := ⟨"14", "15", "16", some "17", "18"⟩
def second : DecisionKey String := ⟨"24", "25", "26", some "27", "28"⟩
def opened : DecisionKey String := ⟨"34", "35", "36", some "37", "38"⟩

def pending : State :=
  { review with decisions := Finmap.singleton "9" [⟨first, none⟩, ⟨second, none⟩] }

/-- The state after command `40` of client `41` answered the head decision. -/
def answered : State :=
  { pending with
    decisions := Finmap.singleton "9" [⟨first, some "40"⟩, ⟨second, none⟩]
    commands := Finmap.singleton "40" ⟨"41", .answer "9" first "answer", .notAttempted, [], none⟩ }

/-- The same state after the delivery of command `40` became uncertain. -/
def uncertain : State :=
  { answered with
    commands := Finmap.singleton "40" ⟨"41", .answer "9" first "answer", .uncertain, [], none⟩ }

/-- Each fact that a scenario of the model checks uses. -/
def evidence : EvidenceTable :=
  ⟨[prepared], [prepared], [("1", lease)], [("9", opened)],
    [("9", first, "40", .resolved), ("9", first, "40", .notEffective)], [("51", "output")]⟩

def approve : HistoryEntry := .inl (.approve "40" "41" "8" "12" "13" prepared reviewed profile)

def cases : List Case := [
  ⟨"model-admit-ready", ⟨queued, evidence, .inl (.admit "1" request profile lease)⟩, true⟩,
  ⟨"model-approve-live", ⟨review, evidence, approve⟩, true⟩,
  ⟨"model-approve-generation", ⟨{ review with generation := "99" }, evidence, approve⟩, false⟩,
  ⟨"model-approve-authority", ⟨{ review with authority := "99" }, evidence, approve⟩, false⟩,
  ⟨"model-approve-not-live", ⟨review, { evidence with live := [] }, approve⟩, false⟩,
  ⟨"model-approve-expired", ⟨review, { evidence with unexpired := [] }, approve⟩, false⟩,
  ⟨"model-answer-head", ⟨pending, evidence, .inl (.answer "40" "41" "9" first "answer")⟩, true⟩,
  ⟨"model-answer-later", ⟨pending, evidence, .inl (.answer "40" "41" "9" second "answer")⟩, false⟩,
  ⟨"model-delivery-uncertain", ⟨answered, evidence, .inl (.delivery "40" .uncertain)⟩, true⟩,
  ⟨"model-answer-after-uncertain",
    ⟨uncertain, evidence, .inl (.answer "42" "41" "9" first "different")⟩, false⟩,
  ⟨"model-release-no-cleanup", ⟨review, { evidence with cleaned := [] }, .inl (.release "1")⟩, false⟩,
  ⟨"model-verify-unverified",
    ⟨review, { evidence with verified := [] }, .inl (.verify "50" "51" "output")⟩, false⟩,
  ⟨"model-open-decision", ⟨pending, evidence, .inl (.openDecision "9" opened)⟩, true⟩,
  ⟨"model-resolve-resolved", ⟨answered, evidence, .inl (.resolve "9" "40" first .resolved)⟩, true⟩,
  ⟨"model-resolve-not-effective",
    ⟨answered, evidence, .inl (.resolve "9" "40" first .notEffective)⟩, true⟩,
  ⟨"model-release-cleanup", ⟨review, evidence, .inl (.release "1")⟩, true⟩,
  ⟨"model-verify", ⟨review, evidence, .inl (.verify "50" "51" "output")⟩, true⟩,
  ⟨"model-observation", ⟨review, evidence, .inr ("9", "event-1")⟩, true⟩]

-- The chained scenario of the model checks: the answer reserves the head, the
-- uncertain delivery changes only the receipt, and a competing answer is refused.
#guard step evidence pending (.inl (.answer "40" "41" "9" first "answer")) = some answered
#guard step evidence answered (.inl (.delivery "40" .uncertain)) = some uncertain
#guard uncertain.decisions = answered.decisions
-- Resolution removes the reserved head, and a proof of non-effect releases only the reservation.
#guard (step evidence answered (.inl (.resolve "9" "40" first .resolved))).map
    (·.decisions.lookup "9") = some (some [⟨second, none⟩])
#guard (step evidence answered (.inl (.resolve "9" "40" first .notEffective))).map
    (·.decisions.lookup "9") = some (some [⟨first, none⟩, ⟨second, none⟩])
-- An observation leaves the coordination state unchanged.
#guard step evidence review (.inr ("9", "event-1")) = some review

end Model

/-! ## The witnesses of the deciders -/

namespace Deciders

open ManagerConformance.Witnesses

def approve : HistoryEntry :=
  .inl (.approve "command-1" "client-1" "preparation-1" "preparation-revision-1" "digest-1"
    prepared reviewed profile)

def cases : List Case := [
  ⟨"open-decision-appends", ⟨pending, table, .inl (.openDecision "run-1" third)⟩, true⟩,
  ⟨"open-decision-unopened", ⟨pending, .empty, .inl (.openDecision "run-1" third)⟩, false⟩,
  ⟨"open-decision-duplicate", ⟨pending, table, .inl (.openDecision "run-1" reopened)⟩, false⟩,
  ⟨"answer-head", ⟨pending, table, .inl (.answer "command-1" "client-1" "run-1" first "yes")⟩, true⟩,
  ⟨"answer-behind-head",
    ⟨pending, table, .inl (.answer "command-1" "client-1" "run-1" second "yes")⟩, false⟩,
  ⟨"answer-reserved-head",
    ⟨reserved, table, .inl (.answer "command-2" "client-2" "run-1" first "no")⟩, false⟩,
  ⟨"resolve-resolved", ⟨reserved, table, .inl (.resolve "run-1" "command-1" first .resolved)⟩, true⟩,
  ⟨"resolve-unlisted-not-effective",
    ⟨reserved, table, .inl (.resolve "run-1" "command-1" first .notEffective)⟩, false⟩,
  ⟨"release-cleaned", ⟨pending, table, .inl (.release "request-1")⟩, true⟩,
  ⟨"release-uncleaned", ⟨pending, .empty, .inl (.release "request-1")⟩, false⟩,
  ⟨"verify-verified", ⟨pending, table, .inl (.verify "artifact-1" "reference-1" "output")⟩, true⟩,
  ⟨"verify-unverified", ⟨pending, table, .inl (.verify "artifact-1" "reference-1" "other")⟩, false⟩,
  ⟨"admit-oldest",
    ⟨queued, .empty, .inl (.admit "request-2" older profile ⟨"slot-2", {"key-1"}⟩)⟩, true⟩,
  ⟨"admit-later-while-older-eligible",
    ⟨queued, .empty, .inl (.admit "request-3" later otherProfile ⟨"slot-2", {"key-2"}⟩)⟩, false⟩,
  ⟨"admit-held-key", ⟨held, .empty, .inl (.admit "request-2" older profile ⟨"slot-2", {"key-1"}⟩)⟩,
    false⟩,
  ⟨"admit-held-slot",
    ⟨held, .empty, .inl (.admit "request-3" later otherProfile ⟨"slot-1", {"key-2"}⟩)⟩, false⟩,
  ⟨"admit-independent-profile",
    ⟨held, .empty, .inl (.admit "request-3" later otherProfile ⟨"slot-2", {"key-2"}⟩)⟩, true⟩,
  ⟨"approve-live", ⟨review, liveTable, approve⟩, true⟩,
  ⟨"approve-generation", ⟨{ review with generation := "generation-2" }, liveTable, approve⟩, false⟩,
  ⟨"approve-not-live", ⟨review, .empty, approve⟩, false⟩]

end Deciders

/-- Every retained request with its outcome. -/
def cases : List Case := Model.cases ++ Deciders.cases

/-- The encoded request of the case `release-cleaned`, the base of the malformed cases. -/
def base : Lean.Json := encodeQuery ⟨Witnesses.pending, Witnesses.table, .inl (.release "request-1")⟩

/-- Request texts that must receive an error and no state. -/
def malformed : List (String × String) := [
  ("error-unknown-version",
    (base.setObjVal! "version" "agent-cat-manager-conformance/2").compress),
  ("error-missing-version", (Lean.Json.mkObj [("state", encodeState Witnesses.pending)]).compress),
  ("error-unknown-field", (base.setObjVal! "extra" true).compress),
  ("error-unknown-state-field",
    (base.setObjVal! "state" ((encodeState Witnesses.pending).setObjVal! "clock" "now")).compress),
  ("error-unknown-entry-tag",
    (base.setObjVal! "entry" (Lean.Json.mkObj [("tag", "retry"), ("command", "command-1")])).compress),
  ("error-unsorted-slots",
    (base.setObjVal! "state" ((encodeState Witnesses.queued).setObjVal! "slots"
      (.arr #["slot-2", "slot-1"]))).compress),
  ("error-not-json", "{\"version\":")]

-- Every case has its stated outcome, and every request round-trips.
#guard cases.all fun c => (step c.query.evidence c.query.state c.query.entry).isSome == c.accepted
#guard cases.all fun c => roundTrips encodeQuery (fun _ j => decodeQuery j) c.query
-- The cases include accepted and refused requests, and every name is distinct.
#guard cases.any (·.accepted) && cases.any (!·.accepted)
#guard ((cases.map (·.name)) ++ malformed.map (·.1)).Nodup
-- Every malformed request receives exactly one field, `error`.
#guard malformed.all fun (_, text) => match respondLine text with
  | .obj kvs => kvs.keys == ["error"]
  | _ => false

end ManagerConformance.Cases
