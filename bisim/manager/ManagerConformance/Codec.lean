import ManagerConformance.Witnesses
import Lean.Data.Json

/-!
# The pinned encoding of the manager conformance lane

This module fixes the JSON encoding of version `agent-cat-manager-conformance/1`.
It encodes the coordination state `Coordination String String`, the evidence
table, and one history entry. `bisim/manager/README.md` specifies the encoding
for an implementation that is not written in Lean.

A history entry is an `Agentic.Manager.Entry` over `Step`. Its left
alternative is a tagged coordination transition with its arguments, and its
right alternative is an observation of a run. `Step.exec` interprets a tagged
transition by its decider, and `Step.exec_eq` proves that it is the model
transition at the evidence of the table. `step` evaluates one entry with the
coordination step of `Agentic.Manager.Meaning`. An observation leaves the
coordination state unchanged in this lane, because its coordination effects
reach the state only as the explicit transitions that it justifies.

Each encoder emits one canonical form. A finite set is an array of its
elements in strictly increasing order. A finite map is an array of
two-element arrays `[key, value]` in strictly increasing order of the keys.
An absent optional value is `null`, and its field is always present. An
alternative of an inductive type is an object whose field `tag` names the
alternative. Each decoder refuses a missing field, an unknown field, an
unknown tag or enumeration value, and a set or map that is not in strictly
increasing order. The request decoder refuses every version other than
`version`.
-/

namespace ManagerConformance

open Agentic.Manager
open Lean (Json)

/-- The version string of this encoding. -/
def version : String := "agent-cat-manager-conformance/1"

/-! ## The order of sets and map keys -/

/-- The order of the encoding on strings, as a Boolean comparison. -/
def keyLe (a b : String) : Bool := decide (a ≤ b)

theorem keyLe_trans (a b c : String) : keyLe a b → keyLe b c → keyLe a c := by
  simp only [keyLe, decide_eq_true_eq]
  exact String.le_trans

theorem keyLe_total (a b : String) : (keyLe a b || keyLe b a) = true := by
  rcases String.le_total a b with h | h <;> simp [keyLe, h]

/-- The elements of a finite set of strings in increasing order. Two sorted
permutations of one list are equal, so the sort is a function of the set. -/
def ascending (s : Finset String) : List String :=
  Quot.liftOn s.val (fun l => l.mergeSort keyLe) fun l₁ l₂ same =>
    List.Perm.eq_of_pairwise
      (fun _ _ _ _ ab ba => String.le_antisymm (of_decide_eq_true ab) (of_decide_eq_true ba))
      (List.pairwise_mergeSort keyLe_trans keyLe_total l₁)
      (List.pairwise_mergeSort keyLe_trans keyLe_total l₂)
      ((List.mergeSort_perm l₁ keyLe).trans (same.trans (List.mergeSort_perm l₂ keyLe).symm))

/-- A list is strictly increasing, so it has no repeated element. -/
def increasing : List String → Bool
  | a :: b :: rest => decide (a < b) && increasing (b :: rest)
  | _ => true

/-! ## Encoders -/

def encodeOption {α : Type} (f : α → Json) : Option α → Json
  | none => .null
  | some a => f a

def encodeSet (s : Finset String) : Json :=
  .arr ((ascending s).map Json.str).toArray

def encodeMap {β : Type} (f : β → Json) (m : Finmap (fun _ : String => β)) : Json :=
  .arr ((ascending m.keys).filterMap fun k =>
    (m.lookup k).map fun v => Json.arr #[.str k, f v]).toArray

def requestPhaseName : RequestPhase → String
  | .draft => "draft" | .queued => "queued" | .preparing => "preparing"
  | .review => "review" | .startPending => "startPending" | .associated => "associated"
  | .withdrawn => "withdrawn" | .refused => "refused"

def requestPhases : List RequestPhase :=
  [.draft, .queued, .preparing, .review, .startPending, .associated, .withdrawn, .refused]

def preparationPhaseName : PreparationPhase → String
  | .live => "live" | .consumed => "consumed" | .invalidated => "invalidated"

def preparationPhases : List PreparationPhase := [.live, .consumed, .invalidated]

def supervisionName : Supervision → String
  | .owned => "owned" | .cleanupPending => "cleanupPending" | .lost => "lost"
  | .observer => "observer"

def supervisions : List Supervision := [.owned, .cleanupPending, .lost, .observer]

def deliveryName : Delivery → String
  | .notAttempted => "notAttempted" | .attempted => "attempted"
  | .uncertain => "uncertain" | .failed => "failed"

def deliveries : List Delivery := [.notAttempted, .attempted, .uncertain, .failed]

def acknowledgementName : Acknowledgement → String
  | .accepted => "accepted" | .queued => "queued" | .delivered => "delivered"
  | .rejectedStale => "rejectedStale" | .unsupported => "unsupported"
  | .controlFailed => "controlFailed"

def acknowledgements : List Acknowledgement :=
  [.accepted, .queued, .delivered, .rejectedStale, .unsupported, .controlFailed]

def resolutionName : Resolution → String
  | .resolved => "resolved" | .notEffective => "notEffective"

def resolutions : List Resolution := [.resolved, .notEffective]

def encodeReadiness (r : Readiness String) : Json :=
  Json.mkObj [("required", encodeSet r.required), ("supplied", encodeMap .str r.supplied),
    ("invalid", encodeSet r.invalid)]

def encodeRequest (r : Request String) : Json :=
  Json.mkObj [("revision", .str r.revision), ("profile", .str r.profile),
    ("profileRevision", .str r.profileRevision), ("phase", .str (requestPhaseName r.phase)),
    ("queueOrdinal", encodeOption (fun n => (n : Json)) r.queueOrdinal),
    ("inputs", encodeReadiness r.inputs), ("preparation", encodeOption .str r.preparation),
    ("run", encodeOption .str r.run)]

def encodeProfile (p : Profile String) : Json :=
  Json.mkObj [("revision", .str p.revision), ("enabled", .bool p.enabled),
    ("resources", encodeSet p.resources)]

def encodeReservation (r : Reservation String) : Json :=
  Json.mkObj [("slot", .str r.slot), ("exclusive", encodeSet r.exclusive)]

def encodePrepared (p : Prepared String String) : Json :=
  Json.mkObj [("request", .str p.request), ("requestRevision", .str p.requestRevision),
    ("profile", .str p.profile), ("profileRevision", .str p.profileRevision),
    ("run", .str p.run), ("nativeRun", .str p.nativeRun), ("worker", .str p.worker),
    ("generation", .str p.generation), ("authority", .str p.authority),
    ("revision", .str p.revision), ("digest", .str p.digest), ("review", .str p.review),
    ("phase", .str (preparationPhaseName p.phase))]

def encodeKey (k : DecisionKey String) : Json :=
  Json.mkObj [("id", .str k.id), ("revision", .str k.revision),
    ("occurrence", .str k.occurrence), ("attempt", encodeOption .str k.attempt),
    ("generation", .str k.generation)]

def encodeDecision (d : Decision String) : Json :=
  Json.mkObj [("key", encodeKey d.key), ("command", encodeOption .str d.command)]

def encodeIntent : Intent String String → Json
  | .start p => Json.mkObj [("tag", "start"), ("prepared", encodePrepared p)]
  | .answer run key value => Json.mkObj [("tag", "answer"), ("run", .str run),
      ("decision", encodeKey key), ("value", .str value)]

def encodeReceipt (r : Receipt String String) : Json :=
  Json.mkObj [("client", .str r.client), ("intent", encodeIntent r.intent),
    ("delivery", .str (deliveryName r.delivery)),
    ("acknowledgements",
      .arr (r.acknowledgements.map fun a => Json.str (acknowledgementName a)).toArray),
    ("effect", encodeOption .str r.effect)]

def encodeArtifact : Artifact String String → Json
  | .referenced reference => Json.mkObj [("tag", "referenced"), ("reference", .str reference)]
  | .verified reference value => Json.mkObj [("tag", "verified"), ("reference", .str reference),
      ("value", .str value)]
  | .unavailable reference => Json.mkObj [("tag", "unavailable"), ("reference", .str reference)]

/-- The encoding of every field of the coordination state. -/
def encodeState (s : State) : Json :=
  Json.mkObj [("generation", .str s.generation), ("authority", .str s.authority),
    ("slots", encodeSet s.slots), ("profiles", encodeMap encodeProfile s.profiles),
    ("requests", encodeMap encodeRequest s.requests),
    ("reservations", encodeMap encodeReservation s.reservations),
    ("preparations", encodeMap encodePrepared s.preparations),
    ("runs", encodeMap .str s.runs),
    ("supervision", encodeMap (fun v => Json.str (supervisionName v)) s.supervision),
    ("decisions", encodeMap (fun ds => .arr (ds.map encodeDecision).toArray) s.decisions),
    ("commands", encodeMap encodeReceipt s.commands),
    ("captures", encodeMap .str s.captures),
    ("artifacts", encodeMap encodeArtifact s.artifacts)]

def encodeEvidence (t : EvidenceTable) : Json :=
  Json.mkObj [("live", .arr (t.live.map encodePrepared).toArray),
    ("unexpired", .arr (t.unexpired.map encodePrepared).toArray),
    ("cleaned", .arr (t.cleaned.map fun (owner, lease) =>
      Json.mkObj [("owner", .str owner), ("lease", encodeReservation lease)]).toArray),
    ("opened", .arr (t.opened.map fun (run, key) =>
      Json.mkObj [("run", .str run), ("key", encodeKey key)]).toArray),
    ("resolutions", .arr (t.resolutions.map fun (run, key, command, resolution) =>
      Json.mkObj [("run", .str run), ("key", encodeKey key), ("command", .str command),
        ("resolution", .str (resolutionName resolution))]).toArray),
    ("verified", .arr (t.verified.map fun (reference, value) =>
      Json.mkObj [("reference", .str reference), ("value", .str value)]).toArray)]

/-! ## History entries -/

/-- A tagged coordination transition with its arguments. -/
inductive Step where
  | admit (id : String) (request : Request String) (profile : Profile String)
      (lease : Reservation String)
  | approve (command client preparation revision digest : String)
      (prepared : Prepared String String) (request : Request String) (profile : Profile String)
  | openDecision (run : String) (key : DecisionKey String)
  | answer (command client run : String) (key : DecisionKey String) (value : String)
  | resolve (run command : String) (key : DecisionKey String) (resolution : Resolution)
  | delivery (command : String) (knowledge : Delivery)
  | release (owner : String)
  | verify (artifact reference value : String)
  deriving DecidableEq

/-- One history entry: a tagged transition, or an observation `(run, event)` with an opaque event. -/
abbrev HistoryEntry := Entry Step String String

/-- The decider of a tagged transition at the evidence of a table. -/
def Step.exec (t : EvidenceTable) : Step → Transition String String
  | .admit id r profile lease => fun s => admitExec s id r profile lease
  | .approve command client preparation revision digest p r profile => fun s =>
      approveExec s t command client preparation revision digest p r profile
  | .openDecision run key => fun s => openDecisionExec s t run key
  | .answer command client run key value => fun s => answerExec s command client run key value
  | .resolve run command key resolution => fun s => resolveExec s t run command key resolution
  | .delivery command knowledge => fun s => s.delivery command knowledge
  | .release owner => fun s => releaseExec s t owner
  | .verify artifact reference value => fun s => verifyExec s t artifact reference value

/-- The model transition of a tagged transition at abstract evidence. -/
noncomputable def Step.model (e : Evidence String String) : Step → Transition String String
  | .admit id r profile lease => fun s => s.admit id r profile lease
  | .approve command client preparation revision digest p r profile => fun s =>
      s.approve e command client preparation revision digest p r profile
  | .openDecision run key => fun s => s.openDecision e run key
  | .answer command client run key value => fun s => s.answer command client run key value
  | .resolve run command key resolution => fun s => s.resolve e run command key resolution
  | .delivery command knowledge => fun s => s.delivery command knowledge
  | .release owner => fun s => s.release e owner
  | .verify artifact reference value => fun s => s.verify e artifact reference value

/-- Each decider of a tagged transition is its model transition at the evidence of its table. -/
theorem Step.exec_eq (t : EvidenceTable) (step : Step) :
    step.exec t = step.model t.toEvidence := by
  cases step <;> funext s <;>
    simp only [Step.exec, Step.model, admitExec_eq, approveExec_eq, openDecisionExec_eq,
      answerExec_eq, resolveExec_eq, releaseExec_eq, verifyExec_eq]

/-- An observation has no coordination effect of its own in this lane. -/
def observe (s : State) (_run _event : String) : Option State := some s

/-- One history entry evaluated by the coordination step of the model meaning. -/
def step (t : EvidenceTable) (s : State) (entry : HistoryEntry) : Option State :=
  coordinationStep observe (some s) (Sum.map (Step.exec t) id entry)

/-- The oracle step is the model coordination step over the model transitions. -/
theorem step_eq (t : EvidenceTable) (s : State) (entry : HistoryEntry) :
    step t s entry =
      coordinationStep observe (some s) (Sum.map (Step.model t.toEvidence) id entry) := by
  have same : Step.exec t = Step.model t.toEvidence := funext (Step.exec_eq t)
  unfold step
  rw [same]

def encodeStep : Step → Json
  | .admit id r profile lease => Json.mkObj [("tag", "admit"), ("id", .str id),
      ("request", encodeRequest r), ("profile", encodeProfile profile),
      ("lease", encodeReservation lease)]
  | .approve command client preparation revision digest p r profile => Json.mkObj [
      ("tag", "approve"), ("command", .str command), ("client", .str client),
      ("preparation", .str preparation), ("revision", .str revision), ("digest", .str digest),
      ("prepared", encodePrepared p), ("request", encodeRequest r),
      ("profile", encodeProfile profile)]
  | .openDecision run key => Json.mkObj [("tag", "openDecision"), ("run", .str run),
      ("key", encodeKey key)]
  | .answer command client run key value => Json.mkObj [("tag", "answer"),
      ("command", .str command), ("client", .str client), ("run", .str run),
      ("key", encodeKey key), ("value", .str value)]
  | .resolve run command key resolution => Json.mkObj [("tag", "resolve"), ("run", .str run),
      ("command", .str command), ("key", encodeKey key),
      ("resolution", .str (resolutionName resolution))]
  | .delivery command knowledge => Json.mkObj [("tag", "delivery"), ("command", .str command),
      ("knowledge", .str (deliveryName knowledge))]
  | .release owner => Json.mkObj [("tag", "release"), ("owner", .str owner)]
  | .verify artifact reference value => Json.mkObj [("tag", "verify"),
      ("artifact", .str artifact), ("reference", .str reference), ("value", .str value)]

def encodeEntry : HistoryEntry → Json
  | .inl s => encodeStep s
  | .inr (run, event) => Json.mkObj [("tag", "observation"), ("run", .str run),
      ("event", .str event)]

/-- One oracle request: a state, an evidence table and one history entry. -/
structure Query where
  state : State
  evidence : EvidenceTable
  entry : HistoryEntry

def encodeQuery (q : Query) : Json :=
  Json.mkObj [("version", .str version), ("state", encodeState q.state),
    ("evidence", encodeEvidence q.evidence), ("entry", encodeEntry q.entry)]

/-! ## Decoders -/

abbrev Decode := Except String

/-- Refuse a value that is not an object with exactly the named fields. -/
def exactly (what : String) (j : Json) (names : List String) : Decode Unit := do
  let .obj kvs := j | throw s!"{what}: expected an object"
  for k in kvs.keys do
    unless names.contains k do throw s!"{what}: unknown field {k}"
  for n in names do
    unless kvs.contains n do throw s!"{what}: missing field {n}"

/-- Decode one field of an object. -/
def member {α : Type} (what : String) (j : Json) (name : String) (f : String → Json → Decode α) :
    Decode α := do
  f s!"{what}.{name}" (← (j.getObjVal? name).mapError fun _ => s!"{what}: missing field {name}")

def decodeString (what : String) : Json → Decode String
  | .str s => pure s
  | _ => throw s!"{what}: expected a string"

def decodeBool (what : String) : Json → Decode Bool
  | .bool b => pure b
  | _ => throw s!"{what}: expected a boolean"

def decodeNat (what : String) (j : Json) : Decode Nat :=
  j.getNat?.mapError fun _ => s!"{what}: expected a natural number"

def decodeOption {α : Type} (f : String → Json → Decode α) (what : String) : Json → Decode (Option α)
  | .null => pure none
  | j => some <$> f what j

def decodeList {α : Type} (f : String → Json → Decode α) (what : String) : Json → Decode (List α)
  | .arr items => items.toList.mapM (f s!"{what}[]")
  | _ => throw s!"{what}: expected an array"

def decodeEnum {α : Type} (all : List α) (name : α → String) (what : String) (j : Json) :
    Decode α := do
  let s ← decodeString what j
  match all.find? (name · == s) with
  | some a => pure a
  | none => throw s!"{what}: unknown value {s}"

def decodeSet (what : String) (j : Json) : Decode (Finset String) := do
  let items ← decodeList decodeString what j
  unless increasing items do throw s!"{what}: elements are not strictly increasing"
  pure items.toFinset

def decodeMap {β : Type} (f : String → Json → Decode β) (what : String) (j : Json) :
    Decode (Finmap (fun _ : String => β)) := do
  let pairs ← decodeList (fun what pair => match pair with
    | .arr #[key, value] => do pure (← decodeString what key, ← f what value)
    | _ => throw s!"{what}: expected a [key, value] pair") what j
  unless increasing (pairs.map (·.1)) do throw s!"{what}: keys are not strictly increasing"
  pure (pairs.foldl (fun m (k, v) => m.insert k v) ∅)

def decodeReadiness (what : String) (j : Json) : Decode (Readiness String) := do
  exactly what j ["required", "supplied", "invalid"]
  pure ⟨← member what j "required" decodeSet, ← member what j "supplied" (decodeMap decodeString),
    ← member what j "invalid" decodeSet⟩

def decodeRequest (what : String) (j : Json) : Decode (Request String) := do
  exactly what j ["revision", "profile", "profileRevision", "phase", "queueOrdinal", "inputs",
    "preparation", "run"]
  pure ⟨← member what j "revision" decodeString, ← member what j "profile" decodeString,
    ← member what j "profileRevision" decodeString,
    ← member what j "phase" (decodeEnum requestPhases requestPhaseName),
    ← member what j "queueOrdinal" (decodeOption decodeNat),
    ← member what j "inputs" decodeReadiness,
    ← member what j "preparation" (decodeOption decodeString),
    ← member what j "run" (decodeOption decodeString)⟩

def decodeProfile (what : String) (j : Json) : Decode (Profile String) := do
  exactly what j ["revision", "enabled", "resources"]
  pure ⟨← member what j "revision" decodeString, ← member what j "enabled" decodeBool,
    ← member what j "resources" decodeSet⟩

def decodeReservation (what : String) (j : Json) : Decode (Reservation String) := do
  exactly what j ["slot", "exclusive"]
  pure ⟨← member what j "slot" decodeString, ← member what j "exclusive" decodeSet⟩

def decodePrepared (what : String) (j : Json) : Decode (Prepared String String) := do
  exactly what j ["request", "requestRevision", "profile", "profileRevision", "run", "nativeRun",
    "worker", "generation", "authority", "revision", "digest", "review", "phase"]
  pure ⟨← member what j "request" decodeString, ← member what j "requestRevision" decodeString,
    ← member what j "profile" decodeString, ← member what j "profileRevision" decodeString,
    ← member what j "run" decodeString, ← member what j "nativeRun" decodeString,
    ← member what j "worker" decodeString, ← member what j "generation" decodeString,
    ← member what j "authority" decodeString, ← member what j "revision" decodeString,
    ← member what j "digest" decodeString, ← member what j "review" decodeString,
    ← member what j "phase" (decodeEnum preparationPhases preparationPhaseName)⟩

def decodeKey (what : String) (j : Json) : Decode (DecisionKey String) := do
  exactly what j ["id", "revision", "occurrence", "attempt", "generation"]
  pure ⟨← member what j "id" decodeString, ← member what j "revision" decodeString,
    ← member what j "occurrence" decodeString, ← member what j "attempt" (decodeOption decodeString),
    ← member what j "generation" decodeString⟩

def decodeDecision (what : String) (j : Json) : Decode (Decision String) := do
  exactly what j ["key", "command"]
  pure ⟨← member what j "key" decodeKey, ← member what j "command" (decodeOption decodeString)⟩

/-- The tag of an alternative, read before its other fields are checked. -/
def decodeTag (what : String) (j : Json) : Decode String :=
  member what j "tag" decodeString

def decodeIntent (what : String) (j : Json) : Decode (Intent String String) := do
  match ← decodeTag what j with
  | "start" =>
    exactly what j ["tag", "prepared"]
    pure (.start (← member what j "prepared" decodePrepared))
  | "answer" =>
    exactly what j ["tag", "run", "decision", "value"]
    pure (.answer (← member what j "run" decodeString) (← member what j "decision" decodeKey)
      (← member what j "value" decodeString))
  | tag => throw s!"{what}: unknown tag {tag}"

def decodeReceipt (what : String) (j : Json) : Decode (Receipt String String) := do
  exactly what j ["client", "intent", "delivery", "acknowledgements", "effect"]
  pure ⟨← member what j "client" decodeString, ← member what j "intent" decodeIntent,
    ← member what j "delivery" (decodeEnum deliveries deliveryName),
    ← member what j "acknowledgements"
      (decodeList (decodeEnum acknowledgements acknowledgementName)),
    ← member what j "effect" (decodeOption decodeString)⟩

def decodeArtifact (what : String) (j : Json) : Decode (Artifact String String) := do
  match ← decodeTag what j with
  | "referenced" =>
    exactly what j ["tag", "reference"]
    pure (.referenced (← member what j "reference" decodeString))
  | "verified" =>
    exactly what j ["tag", "reference", "value"]
    pure (.verified (← member what j "reference" decodeString)
      (← member what j "value" decodeString))
  | "unavailable" =>
    exactly what j ["tag", "reference"]
    pure (.unavailable (← member what j "reference" decodeString))
  | tag => throw s!"{what}: unknown tag {tag}"

def decodeState (what : String) (j : Json) : Decode State := do
  exactly what j ["generation", "authority", "slots", "profiles", "requests", "reservations",
    "preparations", "runs", "supervision", "decisions", "commands", "captures", "artifacts"]
  pure ⟨← member what j "generation" decodeString, ← member what j "authority" decodeString,
    ← member what j "slots" decodeSet, ← member what j "profiles" (decodeMap decodeProfile),
    ← member what j "requests" (decodeMap decodeRequest),
    ← member what j "reservations" (decodeMap decodeReservation),
    ← member what j "preparations" (decodeMap decodePrepared),
    ← member what j "runs" (decodeMap decodeString),
    ← member what j "supervision" (decodeMap (decodeEnum supervisions supervisionName)),
    ← member what j "decisions" (decodeMap (decodeList decodeDecision)),
    ← member what j "commands" (decodeMap decodeReceipt),
    ← member what j "captures" (decodeMap decodeString),
    ← member what j "artifacts" (decodeMap decodeArtifact)⟩

def decodeEvidence (what : String) (j : Json) : Decode EvidenceTable := do
  exactly what j ["live", "unexpired", "cleaned", "opened", "resolutions", "verified"]
  pure ⟨← member what j "live" (decodeList decodePrepared),
    ← member what j "unexpired" (decodeList decodePrepared),
    ← member what j "cleaned" (decodeList fun what j => do
      exactly what j ["owner", "lease"]
      pure (← member what j "owner" decodeString, ← member what j "lease" decodeReservation)),
    ← member what j "opened" (decodeList fun what j => do
      exactly what j ["run", "key"]
      pure (← member what j "run" decodeString, ← member what j "key" decodeKey)),
    ← member what j "resolutions" (decodeList fun what j => do
      exactly what j ["run", "key", "command", "resolution"]
      pure (← member what j "run" decodeString, ← member what j "key" decodeKey,
        ← member what j "command" decodeString,
        ← member what j "resolution" (decodeEnum resolutions resolutionName))),
    ← member what j "verified" (decodeList fun what j => do
      exactly what j ["reference", "value"]
      pure (← member what j "reference" decodeString, ← member what j "value" decodeString))⟩

def decodeEntry (what : String) (j : Json) : Decode HistoryEntry := do
  match ← decodeTag what j with
  | "admit" =>
    exactly what j ["tag", "id", "request", "profile", "lease"]
    pure (.inl (.admit (← member what j "id" decodeString) (← member what j "request" decodeRequest)
      (← member what j "profile" decodeProfile) (← member what j "lease" decodeReservation)))
  | "approve" =>
    exactly what j ["tag", "command", "client", "preparation", "revision", "digest", "prepared",
      "request", "profile"]
    pure (.inl (.approve (← member what j "command" decodeString)
      (← member what j "client" decodeString) (← member what j "preparation" decodeString)
      (← member what j "revision" decodeString) (← member what j "digest" decodeString)
      (← member what j "prepared" decodePrepared) (← member what j "request" decodeRequest)
      (← member what j "profile" decodeProfile)))
  | "openDecision" =>
    exactly what j ["tag", "run", "key"]
    pure (.inl (.openDecision (← member what j "run" decodeString) (← member what j "key" decodeKey)))
  | "answer" =>
    exactly what j ["tag", "command", "client", "run", "key", "value"]
    pure (.inl (.answer (← member what j "command" decodeString)
      (← member what j "client" decodeString) (← member what j "run" decodeString)
      (← member what j "key" decodeKey) (← member what j "value" decodeString)))
  | "resolve" =>
    exactly what j ["tag", "run", "command", "key", "resolution"]
    pure (.inl (.resolve (← member what j "run" decodeString)
      (← member what j "command" decodeString) (← member what j "key" decodeKey)
      (← member what j "resolution" (decodeEnum resolutions resolutionName))))
  | "delivery" =>
    exactly what j ["tag", "command", "knowledge"]
    pure (.inl (.delivery (← member what j "command" decodeString)
      (← member what j "knowledge" (decodeEnum deliveries deliveryName))))
  | "release" =>
    exactly what j ["tag", "owner"]
    pure (.inl (.release (← member what j "owner" decodeString)))
  | "verify" =>
    exactly what j ["tag", "artifact", "reference", "value"]
    pure (.inl (.verify (← member what j "artifact" decodeString)
      (← member what j "reference" decodeString) (← member what j "value" decodeString)))
  | "observation" =>
    exactly what j ["tag", "run", "event"]
    pure (.inr (← member what j "run" decodeString, ← member what j "event" decodeString))
  | tag => throw s!"{what}: unknown tag {tag}"

/-- Decode a request. The version is checked before any other field. -/
def decodeQuery (j : Json) : Decode Query := do
  let .obj _ := j | throw "request: expected an object"
  let given ← member "request" j "version" decodeString
  unless given == version do throw s!"request.version: unknown version {given}"
  exactly "request" j ["version", "state", "evidence", "entry"]
  pure ⟨← member "request" j "state" decodeState, ← member "request" j "evidence" decodeEvidence,
    ← member "request" j "entry" decodeEntry⟩

/-! ## Responses -/

/-- The response to one request: `{accepted, state}`, `{accepted: false}` or `{error}`. -/
def respond (j : Json) : Json :=
  match decodeQuery j with
  | .error message => Json.mkObj [("error", .str message)]
  | .ok q => match step q.evidence q.state q.entry with
    | some next => Json.mkObj [("accepted", true), ("state", encodeState next)]
    | none => Json.mkObj [("accepted", false)]

/-- The response to one line of text, which must hold one JSON request. The
line is read without its surrounding ASCII whitespace, as the oracle reads it. -/
def respondLine (line : String) : Json :=
  match Json.parse line.trimAscii.toString with
  | .error message => Json.mkObj [("error", .str s!"request: not JSON: {message}")]
  | .ok j => respond j

/-! ## Round trips on the witnesses -/

deriving instance DecidableEq for Coordination
deriving instance DecidableEq for EvidenceTable
deriving instance DecidableEq for Query

/-- Decoding the compressed text of an encoding gives the encoded value back. -/
def roundTrips {α : Type} [DecidableEq α] (encode : α → Json) (decode : String → Json → Decode α)
    (a : α) : Bool :=
  match Json.parse (encode a).compress >>= decode "value" with
  | .ok b => decide (b = a)
  | .error _ => false

section
open ManagerConformance.Witnesses

#guard [pending, reserved, queued, held, review].all (roundTrips encodeState decodeState)
#guard [table, liveTable, EvidenceTable.empty].all (roundTrips encodeEvidence decodeEvidence)
#guard ([.inl (.admit "request-2" older profile ⟨"slot-2", {"key-1"}⟩),
    .inl (.approve "command-1" "client-1" "preparation-1" "preparation-revision-1" "digest-1"
      prepared reviewed profile),
    .inl (.openDecision "run-1" third), .inl (.answer "command-1" "client-1" "run-1" first "yes"),
    .inl (.resolve "run-1" "command-1" first .notEffective), .inl (.delivery "command-1" .uncertain),
    .inl (.release "request-1"), .inl (.verify "artifact-1" "reference-1" "output"),
    .inr ("run-1", "event-1")] : List HistoryEntry).all (roundTrips encodeEntry decodeEntry)
-- The accepted approval records a start receipt, so its state encodes a command and an intent.
#guard ((approveExec review liveTable "command-1" "client-1" "preparation-1"
    "preparation-revision-1" "digest-1" prepared reviewed profile).map
    (roundTrips encodeState decodeState)) = some true
-- An accepted answer records an answer receipt, and an accepted verification records an artifact.
#guard ((answerExec pending "command-1" "client-1" "run-1" first "yes").bind
    (verifyExec · table "artifact-1" "reference-1" "output")).map
    (roundTrips encodeState decodeState) = some true
-- A query round-trips as a whole.
#guard roundTrips encodeQuery (fun _ j => decodeQuery j) ⟨pending, table, .inl (.release "request-1")⟩

/-- The encoded request of a release of `request-1` from `pending`. -/
private def releaseQuery : Json := encodeQuery ⟨pending, table, .inl (.release "request-1")⟩

-- An unknown version receives an error and no state.
#guard respond (releaseQuery.setObjVal! "version" "agent-cat-manager-conformance/2") ==
  Json.mkObj [("error", "request.version: unknown version agent-cat-manager-conformance/2")]
-- An unknown field of the request receives an error.
#guard respond (releaseQuery.setObjVal! "extra" true) ==
  Json.mkObj [("error", "request: unknown field extra")]
-- An unknown field inside the state receives an error.
#guard respond (releaseQuery.setObjVal! "state"
    ((encodeState pending).setObjVal! "clock" "now")) ==
  Json.mkObj [("error", "request.state: unknown field clock")]
-- A map whose keys are not strictly increasing receives an error.
#guard (decodeMap decodeString "runs" (.arr #[.arr #["run-2", "x"], .arr #["run-1", "y"]])).toOption.isNone
end

end ManagerConformance
