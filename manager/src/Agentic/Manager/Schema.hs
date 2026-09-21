{-# LANGUAGE OverloadedStrings #-}

-- | Versioned relational coordination facts. Stored identities are not capabilities.
module Agentic.Manager.Schema (schemaVersion, schemaStatements, commandMigration, draftMigration, admissionMigration, approvalMigration, ingestionMigration, controlMigration, artifactMigration, historyMigration, restartMigration, retentionMigration) where

import Data.Text (Text)

schemaVersion :: Int
schemaVersion = 11

-- | Retention clocks are observations of eligibility, never cleanup authority.
retentionMigration :: [Text]
retentionMigration =
  [ "CREATE TRIGGER client_identity_retained BEFORE DELETE ON clients BEGIN SELECT RAISE(ABORT,'client identity retained'); END",
    "CREATE TRIGGER client_retirement_permanent BEFORE UPDATE OF retired ON clients WHEN OLD.retired=1 AND NEW.retired!=1 BEGIN SELECT RAISE(ABORT,'client identity retired'); END",
    "CREATE TRIGGER credential_identity_retained BEFORE DELETE ON credentials BEGIN SELECT RAISE(ABORT,'credential identity retained'); END",
    "CREATE TRIGGER client_identity_immutable BEFORE UPDATE OF id ON clients WHEN NEW.id!=OLD.id BEGIN SELECT RAISE(ABORT,'client identity immutable'); END",
    "CREATE TRIGGER credential_identity_immutable BEFORE UPDATE OF id,client_id,verifier ON credentials WHEN NEW.id!=OLD.id OR NEW.client_id!=OLD.client_id OR NEW.verifier!=OLD.verifier BEGIN SELECT RAISE(ABORT,'credential identity immutable'); END",
    "ALTER TABLE invalidations ADD COLUMN recorded_at INTEGER NOT NULL DEFAULT 0",
    "UPDATE invalidations SET recorded_at=unixepoch()",
    "ALTER TABLE service_metadata ADD COLUMN event_bytes INTEGER NOT NULL DEFAULT 0 CHECK(event_bytes>=0)",
    "UPDATE service_metadata SET event_bytes=(SELECT coalesce(sum(length(stream_id)+length(sequence)+length(kind)+length(resource_uri)+length(revision)+256),0) FROM invalidations)",
    "CREATE INDEX invalidations_order ON invalidations(length(sequence),sequence)",
    "CREATE TRIGGER event_charge AFTER INSERT ON invalidations BEGIN UPDATE service_metadata SET event_bytes=event_bytes+length(NEW.stream_id)+length(NEW.sequence)+length(NEW.kind)+length(NEW.resource_uri)+length(NEW.revision)+256; END",
    "CREATE TRIGGER event_release AFTER DELETE ON invalidations BEGIN UPDATE service_metadata SET event_bytes=event_bytes-length(OLD.stream_id)-length(OLD.sequence)-length(OLD.kind)-length(OLD.resource_uri)-length(OLD.revision)-256; END",
    "ALTER TABLE commands ADD COLUMN inactive_since TEXT",
    "ALTER TABLE runs ADD COLUMN terminal_observed INTEGER NOT NULL DEFAULT 0 CHECK(terminal_observed IN (0,1))",
    "ALTER TABLE captures ADD COLUMN collection_since INTEGER",
    "ALTER TABLE capture_uploads ADD COLUMN collection_since INTEGER",
    "ALTER TABLE capture_uploads ADD COLUMN published_bytes INTEGER CHECK(published_bytes BETWEEN 0 AND 67108864)",
    "ALTER TABLE capture_uploads ADD COLUMN published_sha256 TEXT CHECK(length(published_sha256)=64)",
    "CREATE VIEW retention_local_commands AS SELECT c.id FROM commands c JOIN requests r ON r.id=c.request_id AND r.profile_id=c.profile_id WHERE c.operation IN ('create','capture') AND c.state='accepted' AND c.run_id IS NULL AND c.preparation_id IS NULL AND c.decision_id IS NULL AND c.dispatch_generation IS NULL AND c.attempted_at IS NULL AND c.acknowledgement IS NULL AND c.effect_evidence IS NULL AND NOT EXISTS(SELECT 1 FROM start_intents s WHERE s.command_id=c.id) AND NOT EXISTS(SELECT 1 FROM control_intents s WHERE s.command_id=c.id) AND ((c.operation='create' AND r.client_id=c.client_id AND c.resource_uri='/v1/requests' AND EXISTS(SELECT 1 FROM request_origins o WHERE o.command_id=c.id AND o.request_id=r.id) AND NOT EXISTS(SELECT 1 FROM command_captures l WHERE l.command_id=c.id)) OR (c.operation='capture' AND c.resource_uri='/v1/captures?requestId='||r.id AND (SELECT count(*) FROM command_captures l WHERE l.command_id=c.id)=1 AND EXISTS(SELECT 1 FROM command_captures l JOIN captures p ON p.id=l.capture_id WHERE l.command_id=c.id AND p.request_id=r.id AND p.client_id=c.client_id AND p.profile_id=c.profile_id) AND NOT EXISTS(SELECT 1 FROM request_origins o WHERE o.command_id=c.id)))",
    "CREATE VIEW retention_pending_commands AS SELECT id,request_id,run_id FROM commands WHERE retired=0 AND (state IN ('dispatch-attempted','acknowledged','unresolved') OR (state='accepted' AND id NOT IN (SELECT id FROM retention_local_commands)))",
    "CREATE INDEX command_request_retention ON commands(request_id,state)",
    "CREATE INDEX command_run_retention ON commands(run_id,state)",
    "CREATE TRIGGER request_retention_reset AFTER UPDATE ON requests BEGIN UPDATE commands SET inactive_since=NULL WHERE request_id=NEW.id; UPDATE captures SET collection_since=NULL WHERE request_id=NEW.id; UPDATE capture_uploads SET collection_since=NULL WHERE request_id=NEW.id; END",
    "CREATE TRIGGER run_retention_reset AFTER UPDATE OF revision,control_revision,supervision,terminal_observed ON runs BEGIN UPDATE commands SET inactive_since=NULL WHERE run_id=NEW.id OR request_id=NEW.request_id; UPDATE captures SET collection_since=NULL WHERE request_id=NEW.request_id; UPDATE capture_uploads SET collection_since=NULL WHERE request_id=NEW.request_id; END",
    "CREATE TRIGGER command_retention_reset AFTER UPDATE OF state ON commands BEGIN UPDATE commands SET inactive_since=NULL WHERE id=NEW.id OR request_id=NEW.request_id OR run_id=NEW.run_id OR request_id=(SELECT request_id FROM runs WHERE id=NEW.run_id); UPDATE captures SET collection_since=NULL WHERE request_id=NEW.request_id OR request_id=(SELECT request_id FROM runs WHERE id=NEW.run_id); END",
    "CREATE TRIGGER command_retention_insert AFTER INSERT ON commands BEGIN UPDATE commands SET inactive_since=NULL WHERE request_id=NEW.request_id OR run_id=NEW.run_id OR request_id=(SELECT request_id FROM runs WHERE id=NEW.run_id); UPDATE captures SET collection_since=NULL WHERE request_id=NEW.request_id OR request_id=(SELECT request_id FROM runs WHERE id=NEW.run_id); END"
  ] <> ["CREATE TRIGGER " <> name <> " AFTER " <> operation <> " ON " <> table <> " BEGIN UPDATE captures SET collection_since=NULL WHERE id=" <> reference <> "; END"
       | (name,operation,table,reference) <-
           [("input_capture_insert","INSERT","request_inputs","NEW.capture_id"),
            ("input_capture_update","UPDATE OF capture_id","request_inputs","NEW.capture_id OR id=OLD.capture_id"),
            ("input_capture_delete","DELETE","request_inputs","OLD.capture_id"),
            ("preparation_capture_insert","INSERT","preparation_captures","NEW.capture_id"),
            ("command_capture_insert","INSERT","command_captures","NEW.capture_id")]]
  <> ["CREATE TRIGGER " <> name <> " AFTER " <> operation <> " ON " <> table <> " BEGIN UPDATE commands SET inactive_since=NULL WHERE request_id=NEW.request_id; UPDATE captures SET collection_since=NULL WHERE request_id=NEW.request_id; END"
     | (name,operation,table) <- [("reservation_retention_insert","INSERT","reservations"),
         ("reservation_retention_update","UPDATE OF state","reservations"),
         ("preparation_retention_insert","INSERT","preparations"),
         ("preparation_retention_update","UPDATE OF state","preparations"),
         ("run_retention_insert","INSERT","runs")]]
  <> ["CREATE TRIGGER capture_provenance_reset AFTER UPDATE OF request_id,client_id,profile_id,private_reference,bytes,sha256 ON captures BEGIN UPDATE captures SET collection_since=NULL WHERE id=NEW.id; UPDATE commands SET inactive_since=NULL WHERE id IN (SELECT command_id FROM command_captures WHERE capture_id=NEW.id) OR request_id=NEW.request_id; END",
      "CREATE TRIGGER upload_provenance_reset AFTER UPDATE OF state,published_bytes,published_sha256 ON capture_uploads BEGIN UPDATE capture_uploads SET collection_since=NULL WHERE id=NEW.id; END",
      "CREATE TRIGGER lineage_collection_reset AFTER INSERT ON requests WHEN NEW.parent_run_id IS NOT NULL BEGIN UPDATE captures SET collection_since=NULL WHERE request_id=(SELECT request_id FROM runs WHERE id=NEW.parent_run_id); END",
      "CREATE TRIGGER retired_capture_reset AFTER UPDATE OF retired ON commands BEGIN UPDATE captures SET collection_since=NULL WHERE id IN (SELECT capture_id FROM command_captures WHERE command_id=NEW.id); END"]

-- | Negative occupancy facts retained across restoration, never execution authority.
restartMigration :: [Text]
restartMigration =
  [ "CREATE TABLE request_restart_bindings (request_id TEXT PRIMARY KEY NOT NULL REFERENCES requests(id), digest TEXT NOT NULL CHECK(length(digest)=64)) STRICT",
    "CREATE TRIGGER request_restart_binding_immutable BEFORE UPDATE ON request_restart_bindings BEGIN SELECT RAISE(ABORT,'restart binding immutable'); END",
    "CREATE TABLE restoration_quarantine (id TEXT PRIMARY KEY NOT NULL, slot INTEGER NOT NULL CHECK(slot BETWEEN 0 AND 15), resources TEXT NOT NULL CHECK(length(resources)<=65536)) STRICT",
    "CREATE TABLE restorations (id TEXT PRIMARY KEY NOT NULL, previous_epoch TEXT NOT NULL, backup_epoch TEXT NOT NULL, effects_uncertain INTEGER NOT NULL CHECK(effects_uncertain=1)) STRICT"
  ]

-- | Observation addresses and immutable lineage facts confer no worker authority.
historyMigration :: [Text]
historyMigration =
  [ "CREATE TABLE history_roots (identity TEXT NOT NULL, profile_id TEXT NOT NULL, path TEXT NOT NULL, legacy INTEGER NOT NULL CHECK(legacy IN (0,1)), PRIMARY KEY(identity,profile_id), UNIQUE(path,profile_id)) STRICT",
    "CREATE TABLE history_entries (id TEXT PRIMARY KEY NOT NULL, root_identity TEXT NOT NULL, profile_id TEXT NOT NULL, component TEXT NOT NULL, UNIQUE(root_identity,component), FOREIGN KEY(root_identity,profile_id) REFERENCES history_roots(identity,profile_id)) STRICT",
    "CREATE TABLE history_views (id TEXT PRIMARY KEY NOT NULL, revision TEXT NOT NULL, digest TEXT NOT NULL CHECK(length(digest)=64)) STRICT",
    "CREATE TABLE history_results (entry_id TEXT PRIMARY KEY NOT NULL REFERENCES history_entries(id), reference BLOB NOT NULL CHECK(length(reference)<=1048576)) STRICT",
    "CREATE TRIGGER history_results_immutable BEFORE UPDATE ON history_results BEGIN SELECT RAISE(ABORT,'history result immutable'); END",
    "CREATE TRIGGER history_roots_immutable BEFORE UPDATE ON history_roots BEGIN SELECT RAISE(ABORT,'history root immutable'); END",
    "CREATE TRIGGER history_entries_immutable BEFORE UPDATE ON history_entries BEGIN SELECT RAISE(ABORT,'history address immutable'); END",
    "CREATE TABLE request_lineage (request_id TEXT PRIMARY KEY NOT NULL REFERENCES requests(id), parent_manifest BLOB NOT NULL CHECK(length(parent_manifest)<=1048576)) STRICT",
    "CREATE TRIGGER request_lineage_immutable BEFORE UPDATE ON request_lineage BEGIN SELECT RAISE(ABORT,'lineage parent immutable'); END",
    "CREATE TRIGGER lineage_request_immutable BEFORE UPDATE OF parent_run_id,lineage_operation,lineage_edits ON requests WHEN OLD.parent_run_id IS NOT NULL BEGIN SELECT RAISE(ABORT,'lineage request immutable'); END"
  ]

-- | Keep export acceptance and its command in one transaction, with the
-- existing foreign key checked at commit rather than at the intent insert.
artifactMigration :: [Text]
artifactMigration =
  [ "CREATE TABLE exports_v8 (id TEXT PRIMARY KEY NOT NULL, revision TEXT NOT NULL, run_id TEXT NOT NULL REFERENCES runs(id), artifact_id TEXT NOT NULL REFERENCES artifacts(id), command_id TEXT NOT NULL UNIQUE REFERENCES commands(id) DEFERRABLE INITIALLY DEFERRED, destination_root_identity TEXT NOT NULL, name TEXT NOT NULL, expected_sha256 TEXT NOT NULL, receipt BLOB, state TEXT CHECK(state IN ('published','unresolved')), UNIQUE(destination_root_identity,name), FOREIGN KEY(artifact_id,run_id) REFERENCES artifacts(id,run_id)) STRICT",
    "INSERT INTO exports_v8 SELECT id,revision,run_id,artifact_id,command_id,destination_root_identity,name,expected_sha256,receipt,state FROM exports",
    "DROP TABLE exports",
    "ALTER TABLE exports_v8 RENAME TO exports"
  ]

-- Non-content correlation bindings never reconstruct the original live payload or ticket.
controlMigration :: [Text]
controlMigration =
  [ "ALTER TABLE decisions ADD COLUMN observed_order TEXT",
    "UPDATE decisions SET observed_order=(SELECT sequence FROM invalidations WHERE resource_uri='/v1/decisions/'||decisions.id ORDER BY length(sequence),sequence LIMIT 1)",
    "CREATE TABLE control_intents (command_id TEXT PRIMARY KEY REFERENCES commands(id) DEFERRABLE INITIALLY DEFERRED, run_id TEXT NOT NULL REFERENCES runs(id), decision_id TEXT REFERENCES decisions(id), native_command TEXT NOT NULL CHECK(native_command IN ('cancelRun','steerOccurrence','retryOccurrence','failoverOccurrence','abandonOccurrence','redirectOccurrence','answerPerson')), occurrence_id TEXT, attempt_id TEXT, generation TEXT, native_sha256 TEXT NOT NULL CHECK(length(native_sha256)=64), native_bytes INTEGER NOT NULL CHECK(native_bytes BETWEEN 1 AND 1048576), effect_sha256 TEXT CHECK(length(effect_sha256)=64), effect_bytes INTEGER CHECK(effect_bytes BETWEEN 0 AND 1048576), CHECK((effect_sha256 IS NULL)=(effect_bytes IS NULL)), CHECK(attempt_id IS NULL OR occurrence_id IS NOT NULL), CHECK((decision_id IS NULL)=(generation IS NULL))) STRICT",
    "CREATE TRIGGER control_intents_immutable BEFORE UPDATE ON control_intents BEGIN SELECT RAISE(ABORT,'control intent immutable'); END",
    "CREATE TRIGGER control_intents_retained BEFORE DELETE ON control_intents BEGIN SELECT RAISE(ABORT,'control intent retained'); END"
  ]

schemaStatements :: [Text]
schemaStatements =
  [ "CREATE TABLE service_metadata (singleton INTEGER PRIMARY KEY CHECK(singleton=1), authority_epoch TEXT NOT NULL UNIQUE, stream_id TEXT NOT NULL UNIQUE, sequence TEXT NOT NULL CHECK(length(sequence) BETWEEN 1 AND 20 AND sequence NOT GLOB '*[^0-9]*' AND (sequence='0' OR substr(sequence,1,1) BETWEEN '1' AND '9') AND (length(sequence)<20 OR sequence<='18446744073709551615')), retained_floor TEXT NOT NULL CHECK(length(retained_floor) BETWEEN 1 AND 20 AND retained_floor NOT GLOB '*[^0-9]*' AND (retained_floor='0' OR substr(retained_floor,1,1) BETWEEN '1' AND '9') AND (length(retained_floor)<20 OR retained_floor<='18446744073709551615')), revision TEXT NOT NULL) STRICT",
    "CREATE TABLE clients (id TEXT PRIMARY KEY NOT NULL, revision TEXT NOT NULL, authorization_revision TEXT NOT NULL, retired INTEGER NOT NULL DEFAULT 0 CHECK(retired IN (0,1))) STRICT",
    "CREATE TABLE credentials (id TEXT PRIMARY KEY NOT NULL, client_id TEXT NOT NULL REFERENCES clients(id), verifier BLOB NOT NULL UNIQUE, expires_at TEXT NOT NULL, revoked INTEGER NOT NULL CHECK(revoked IN (0,1))) STRICT",
    "CREATE TABLE credential_scopes (credential_id TEXT NOT NULL REFERENCES credentials(id), profile_id TEXT NOT NULL, scope TEXT NOT NULL CHECK(scope IN ('observe','submit','control','export')), PRIMARY KEY(credential_id,profile_id,scope)) STRICT",
    "CREATE TABLE requests (id TEXT PRIMARY KEY NOT NULL, revision TEXT NOT NULL, client_id TEXT NOT NULL REFERENCES clients(id), workflow_id TEXT NOT NULL, descriptor_revision TEXT NOT NULL, profile_id TEXT NOT NULL, profile_revision TEXT NOT NULL, phase TEXT NOT NULL CHECK(phase IN ('draft','queued','preparing','review','start-pending','associated','withdrawn','refused')), admission TEXT NOT NULL CHECK(admission IN ('not-queued','waiting','reserved','released','refused')), queue_ordinal TEXT UNIQUE, blocking_reasons BLOB NOT NULL, validation_errors BLOB NOT NULL, parent_run_id TEXT REFERENCES runs(id), lineage_operation TEXT CHECK(lineage_operation IN ('restart','resume','fork')), lineage_edits BLOB, UNIQUE(id,profile_id), CHECK((parent_run_id IS NULL)=(lineage_operation IS NULL))) STRICT",
    "CREATE TABLE captures (id TEXT PRIMARY KEY NOT NULL, revision TEXT NOT NULL, request_id TEXT NOT NULL REFERENCES requests(id), client_id TEXT NOT NULL REFERENCES clients(id), profile_id TEXT NOT NULL, private_reference BLOB NOT NULL UNIQUE, bytes INTEGER NOT NULL CHECK(bytes BETWEEN 0 AND 67108864), sha256 TEXT NOT NULL CHECK(length(sha256)=64), UNIQUE(id,request_id), FOREIGN KEY(request_id,profile_id) REFERENCES requests(id,profile_id)) STRICT",
    "CREATE TABLE request_inputs (request_id TEXT NOT NULL REFERENCES requests(id), name TEXT NOT NULL, declaration_ordinal INTEGER NOT NULL CHECK(declaration_ordinal BETWEEN 0 AND 255), declaration BLOB NOT NULL, source TEXT CHECK(source IN ('literal','capture')), literal BLOB, capture_id TEXT, FOREIGN KEY(capture_id,request_id) REFERENCES captures(id,request_id), PRIMARY KEY(request_id,name), UNIQUE(request_id,declaration_ordinal), CHECK((source IS NULL AND literal IS NULL AND capture_id IS NULL) OR (source IS 'literal' AND literal IS NOT NULL AND capture_id IS NULL) OR (source IS 'capture' AND literal IS NULL AND capture_id IS NOT NULL))) STRICT",
    "CREATE TABLE reservations (id TEXT PRIMARY KEY NOT NULL, request_id TEXT NOT NULL REFERENCES requests(id), slot INTEGER UNIQUE CHECK(slot BETWEEN 0 AND 15), process_generation TEXT NOT NULL, state TEXT NOT NULL CHECK(state IN ('held','cleanup-pending','quarantined','released')), CHECK((slot IS NULL)=(state='released')), UNIQUE(id,request_id)) STRICT",
    "CREATE UNIQUE INDEX one_active_reservation ON reservations(request_id) WHERE state!='released'",
    "CREATE TABLE reservation_resources (resource_key TEXT PRIMARY KEY NOT NULL, reservation_id TEXT NOT NULL REFERENCES reservations(id)) STRICT",
    "CREATE TRIGGER release_without_claims BEFORE UPDATE OF state ON reservations WHEN NEW.state='released' AND EXISTS(SELECT 1 FROM reservation_resources WHERE reservation_id=OLD.id) BEGIN SELECT RAISE(ABORT,'reservation retains resource claims'); END",
    "CREATE TRIGGER claim_active_reservation BEFORE INSERT ON reservation_resources WHEN (SELECT state FROM reservations WHERE id=NEW.reservation_id)='released' BEGIN SELECT RAISE(ABORT,'reservation is released'); END",
    "CREATE TRIGGER move_claim_to_active_reservation BEFORE UPDATE OF reservation_id ON reservation_resources WHEN (SELECT state FROM reservations WHERE id=NEW.reservation_id)='released' BEGIN SELECT RAISE(ABORT,'reservation is released'); END",
    "CREATE TABLE preparations (id TEXT PRIMARY KEY NOT NULL, revision TEXT NOT NULL, request_id TEXT NOT NULL REFERENCES requests(id), request_revision TEXT NOT NULL, profile_revision TEXT NOT NULL, reservation_id TEXT NOT NULL REFERENCES reservations(id), process_generation TEXT NOT NULL, worker_identity TEXT NOT NULL, root_identity TEXT NOT NULL, native_run_id TEXT NOT NULL, expires_at TEXT NOT NULL, review_digest TEXT NOT NULL, review BLOB NOT NULL, private_binding BLOB NOT NULL, state TEXT NOT NULL CHECK(state IN ('live','consumed','invalidated')), reason TEXT CHECK(reason IN ('expired','input-changed','profile-changed','worker-lost','discarded','authority-changed','consumed')), UNIQUE(id,request_id), FOREIGN KEY(reservation_id,request_id) REFERENCES reservations(id,request_id)) STRICT",
    "CREATE UNIQUE INDEX one_live_preparation ON preparations(request_id) WHERE state='live'",
    "CREATE TABLE preparation_captures (preparation_id TEXT NOT NULL REFERENCES preparations(id), capture_id TEXT NOT NULL REFERENCES captures(id), PRIMARY KEY(preparation_id,capture_id)) STRICT",
    "CREATE TABLE runs (id TEXT PRIMARY KEY NOT NULL, revision TEXT NOT NULL, control_revision TEXT NOT NULL, request_id TEXT UNIQUE REFERENCES requests(id), preparation_id TEXT UNIQUE REFERENCES preparations(id), profile_id TEXT NOT NULL, root_identity TEXT NOT NULL, native_run_id TEXT NOT NULL, parent_run_id TEXT REFERENCES runs(id), supervision TEXT NOT NULL CHECK(supervision IN ('owned','cleanup-pending','lost','observer')), runtime_snapshot BLOB, snapshot_version INTEGER, result_state TEXT NOT NULL CHECK(result_state IN ('absent','referenced','verified','unavailable')), result_artifact_id TEXT REFERENCES artifacts(id), UNIQUE(profile_id,root_identity,native_run_id), FOREIGN KEY(preparation_id,request_id) REFERENCES preparations(id,request_id), FOREIGN KEY(result_artifact_id,id) REFERENCES artifacts(id,run_id), CHECK((runtime_snapshot IS NULL)=(snapshot_version IS NULL))) STRICT",
    "CREATE TABLE ingestions (run_id TEXT NOT NULL REFERENCES runs(id), sequence TEXT NOT NULL CHECK(length(sequence) BETWEEN 1 AND 20 AND sequence NOT GLOB '*[^0-9]*' AND (sequence='0' OR substr(sequence,1,1) BETWEEN '1' AND '9') AND (length(sequence)<20 OR sequence<='18446744073709551615')), envelope_digest TEXT NOT NULL, envelope BLOB NOT NULL, PRIMARY KEY(run_id,sequence)) STRICT",
    "CREATE TABLE commands (id TEXT PRIMARY KEY NOT NULL, revision TEXT NOT NULL, profile_id TEXT NOT NULL, operation TEXT NOT NULL CHECK(operation IN ('create','capture','set-input','remove-input','enqueue','withdraw','approve','discard','cancel','steer','retry','choose-recovery','redirect','answer','export','restart','resume','fork')), client_id TEXT NOT NULL REFERENCES clients(id), authority_epoch TEXT NOT NULL, method TEXT NOT NULL CHECK(method='POST'), resource_uri TEXT NOT NULL, idempotency_key TEXT NOT NULL, body BLOB, media_type TEXT, precondition TEXT, receipt BLOB, retired INTEGER NOT NULL CHECK(retired IN (0,1)), request_id TEXT REFERENCES requests(id), run_id TEXT REFERENCES runs(id), preparation_id TEXT REFERENCES preparations(id), decision_id TEXT REFERENCES decisions(id), accepted_at TEXT NOT NULL, dispatch_generation TEXT, attempted_at TEXT, acknowledgement BLOB, effect_evidence BLOB, state TEXT NOT NULL CHECK(state IN ('accepted','dispatch-attempted','acknowledged','effect-observed','refused','unresolved')), UNIQUE(client_id,method,resource_uri,idempotency_key), CHECK(retired=0 OR (body IS NULL AND media_type IS NULL AND precondition IS NULL AND receipt IS NULL))) STRICT",
    "CREATE TABLE command_captures (command_id TEXT NOT NULL REFERENCES commands(id), capture_id TEXT NOT NULL REFERENCES captures(id), PRIMARY KEY(command_id,capture_id)) STRICT",
    "CREATE TABLE decisions (id TEXT PRIMARY KEY NOT NULL, revision TEXT NOT NULL, run_id TEXT NOT NULL REFERENCES runs(id), occurrence_id TEXT NOT NULL, attempt_id TEXT, generation TEXT NOT NULL, observed_sequence TEXT NOT NULL CHECK(length(observed_sequence) BETWEEN 1 AND 20 AND observed_sequence NOT GLOB '*[^0-9]*' AND (observed_sequence='0' OR substr(observed_sequence,1,1) BETWEEN '1' AND '9') AND (length(observed_sequence)<20 OR observed_sequence<='18446744073709551615')), kind TEXT NOT NULL CHECK(kind IN ('question','recovery')), state TEXT NOT NULL CHECK(state IN ('pending','submitting','resolved','invalidated')), question_artifact_id TEXT REFERENCES artifacts(id), recovery_options BLOB, command_id TEXT UNIQUE REFERENCES commands(id), UNIQUE(run_id,occurrence_id,attempt_id,generation,kind), FOREIGN KEY(question_artifact_id,run_id) REFERENCES artifacts(id,run_id)) STRICT",
    "CREATE UNIQUE INDEX decision_identity ON decisions(run_id,occurrence_id,coalesce(attempt_id,''),generation,kind)",
    "CREATE TABLE artifacts (id TEXT PRIMARY KEY NOT NULL, revision TEXT NOT NULL, run_id TEXT NOT NULL REFERENCES runs(id), private_reference BLOB NOT NULL, code BLOB NOT NULL, verification TEXT NOT NULL CHECK(verification IN ('referenced','verified','unavailable')), verification_failure TEXT, UNIQUE(run_id,private_reference), UNIQUE(id,run_id)) STRICT",
    "CREATE TABLE exports (id TEXT PRIMARY KEY NOT NULL, revision TEXT NOT NULL, run_id TEXT NOT NULL REFERENCES runs(id), artifact_id TEXT NOT NULL REFERENCES artifacts(id), command_id TEXT NOT NULL UNIQUE REFERENCES commands(id), destination_root_identity TEXT NOT NULL, name TEXT NOT NULL, expected_sha256 TEXT NOT NULL, receipt BLOB, state TEXT CHECK(state IN ('published','unresolved')), UNIQUE(destination_root_identity,name), FOREIGN KEY(artifact_id,run_id) REFERENCES artifacts(id,run_id)) STRICT",
    "CREATE TABLE invalidations (stream_id TEXT NOT NULL REFERENCES service_metadata(stream_id), sequence TEXT NOT NULL CHECK(length(sequence) BETWEEN 1 AND 20 AND sequence NOT GLOB '*[^0-9]*' AND (sequence='0' OR substr(sequence,1,1) BETWEEN '1' AND '9') AND (length(sequence)<20 OR sequence<='18446744073709551615')), kind TEXT NOT NULL CHECK(kind IN ('request.changed','preparation.changed','run.changed','decision.changed','command.changed','artifact.changed','service.changed')), resource_uri TEXT NOT NULL, revision TEXT NOT NULL, PRIMARY KEY(stream_id,sequence)) STRICT",
    "CREATE INDEX replay_order ON invalidations(stream_id,length(sequence),sequence)"
  ]

-- | Version-two ledger additions. Version-one records and original receipts survive.
commandMigration :: [Text]
commandMigration =
  [ "ALTER TABLE commands ADD COLUMN body_sha256 BLOB CHECK(body_sha256 IS NULL OR length(body_sha256)=32)",
    "ALTER TABLE commands ADD COLUMN refusal TEXT CHECK(refusal IN ('state-conflict','stale-revision','unsupported-operation','ownership-unavailable','supervision-unavailable','invalid-answer','invalid-lineage-edit','export-conflict','storage-unavailable'))",
    "ALTER TABLE commands ADD COLUMN body_bytes INTEGER CHECK(body_bytes IS NULL OR body_bytes BETWEEN 0 AND 67108864)",
    "ALTER TABLE commands ADD COLUMN reserved_bytes INTEGER NOT NULL DEFAULT 131072 CHECK(reserved_bytes BETWEEN 0 AND 131072)",
    "CREATE TABLE command_ledger_usage (singleton INTEGER PRIMARY KEY CHECK(singleton=1), bytes INTEGER NOT NULL CHECK(bytes>=0)) STRICT",
    "INSERT INTO command_ledger_usage SELECT 1,coalesce(sum(reserved_bytes+coalesce(length(body),0)),0) FROM commands",
    "CREATE TRIGGER command_charge_insert AFTER INSERT ON commands BEGIN UPDATE command_ledger_usage SET bytes=bytes+NEW.reserved_bytes+coalesce(length(NEW.body),0) WHERE singleton=1; END",
    "CREATE TRIGGER command_charge_update AFTER UPDATE OF reserved_bytes,body ON commands BEGIN UPDATE command_ledger_usage SET bytes=bytes+NEW.reserved_bytes+coalesce(length(NEW.body),0)-OLD.reserved_bytes-coalesce(length(OLD.body),0) WHERE singleton=1; END",
    "CREATE TRIGGER command_replay_protection BEFORE DELETE ON commands BEGIN SELECT RAISE(ABORT,'command replay protection is retained'); END",
    "CREATE TABLE command_ordinary_rate (credential_id TEXT PRIMARY KEY NOT NULL REFERENCES credentials(id), minute INTEGER NOT NULL, count INTEGER NOT NULL CHECK(count>=0)) STRICT",
    "CREATE TABLE command_safety_rate (singleton INTEGER PRIMARY KEY CHECK(singleton=1), minute INTEGER NOT NULL, count INTEGER NOT NULL CHECK(count>=0)) STRICT",
    "INSERT INTO command_safety_rate VALUES (1,0,0)"
  ]

-- | Version-three input representation and bounded durable upload reservations.
draftMigration :: [Text]
draftMigration =
  [ "ALTER TABLE command_captures RENAME TO command_captures_v2",
    "CREATE TABLE command_captures (command_id TEXT NOT NULL REFERENCES commands(id) DEFERRABLE INITIALLY DEFERRED, capture_id TEXT NOT NULL REFERENCES captures(id), PRIMARY KEY(command_id,capture_id)) STRICT",
    "INSERT INTO command_captures SELECT command_id,capture_id FROM command_captures_v2",
    "DROP TABLE command_captures_v2",
    "CREATE TABLE request_origins (request_id TEXT PRIMARY KEY NOT NULL REFERENCES requests(id), command_id TEXT NOT NULL UNIQUE REFERENCES commands(id) DEFERRABLE INITIALLY DEFERRED, view BLOB NOT NULL CHECK(length(view)<=1048576)) STRICT",
    "CREATE TRIGGER request_origin_immutable BEFORE UPDATE ON request_origins BEGIN SELECT RAISE(ABORT,'request origin is immutable'); END",
    "CREATE TRIGGER request_origin_retained BEFORE DELETE ON request_origins WHEN (SELECT retired FROM commands WHERE id=OLD.command_id)=0 BEGIN SELECT RAISE(ABORT,'request origin is retained'); END",
    "ALTER TABLE request_inputs RENAME TO request_inputs_v2",
    "CREATE TABLE request_inputs (request_id TEXT NOT NULL REFERENCES requests(id), name TEXT NOT NULL, declaration_ordinal INTEGER NOT NULL CHECK(declaration_ordinal BETWEEN 0 AND 255), declaration BLOB NOT NULL, source TEXT CHECK(source IN ('literal','capture')), literal_bytes INTEGER CHECK(literal_bytes BETWEEN 0 AND 67108864), literal_transport_bytes INTEGER CHECK(literal_transport_bytes BETWEEN 0 AND 67108864), literal_chunks INTEGER CHECK(literal_chunks BETWEEN 0 AND 1024), literal_digest BLOB CHECK(literal_digest IS NULL OR length(literal_digest)=32), capture_id TEXT, PRIMARY KEY(request_id,name), UNIQUE(request_id,declaration_ordinal), FOREIGN KEY(capture_id,request_id) REFERENCES captures(id,request_id), CHECK((source IS NULL AND literal_bytes IS NULL AND literal_transport_bytes IS NULL AND literal_chunks IS NULL AND literal_digest IS NULL AND capture_id IS NULL) OR (source IS 'literal' AND literal_bytes IS NOT NULL AND literal_chunks IS NOT NULL AND literal_chunks=(literal_bytes+65535)/65536 AND literal_digest IS NOT NULL AND capture_id IS NULL) OR (source IS 'capture' AND literal_bytes IS NULL AND literal_transport_bytes IS NULL AND literal_chunks IS NULL AND literal_digest IS NULL AND capture_id IS NOT NULL))) STRICT",
    "CREATE TABLE request_literal_chunks (request_id TEXT NOT NULL, name TEXT NOT NULL, ordinal INTEGER NOT NULL CHECK(ordinal BETWEEN 0 AND 1023), bytes BLOB NOT NULL CHECK(length(bytes) BETWEEN 1 AND 65536), PRIMARY KEY(request_id,name,ordinal), FOREIGN KEY(request_id,name) REFERENCES request_inputs(request_id,name) ON DELETE CASCADE) STRICT",
    "CREATE TRIGGER literal_chunk_bounds BEFORE INSERT ON request_literal_chunks WHEN NOT EXISTS(SELECT 1 FROM request_inputs WHERE request_id=NEW.request_id AND name=NEW.name AND source='literal' AND NEW.ordinal<literal_chunks AND length(NEW.bytes)=min(65536,literal_bytes-NEW.ordinal*65536)) BEGIN SELECT RAISE(ABORT,'literal chunk does not match its input'); END",
    "INSERT INTO request_inputs SELECT request_id,name,declaration_ordinal,declaration,source,CASE WHEN source='literal' THEN length(literal) END,CASE WHEN source='literal' THEN length(literal) END,CASE WHEN source='literal' THEN (length(literal)+65535)/65536 END,CASE WHEN source='literal' THEN zeroblob(32) END,capture_id FROM request_inputs_v2",
    "WITH RECURSIVE positions(n) AS (VALUES(0) UNION ALL SELECT n+1 FROM positions WHERE n<31) INSERT INTO request_literal_chunks SELECT request_id,name,n,substr(literal,n*65536+1,65536) FROM request_inputs_v2 JOIN positions ON n<(length(literal)+65535)/65536 WHERE source='literal'",
    "DROP TABLE request_inputs_v2",
    "CREATE TABLE capture_uploads (id TEXT PRIMARY KEY NOT NULL, request_id TEXT NOT NULL REFERENCES requests(id), client_id TEXT NOT NULL REFERENCES clients(id), profile_id TEXT NOT NULL, profile_revision TEXT NOT NULL, process_generation TEXT NOT NULL, reserved_bytes INTEGER NOT NULL CHECK(reserved_bytes BETWEEN 0 AND 67108864), created_at TEXT NOT NULL, state TEXT NOT NULL CHECK(state IN ('pending','orphan')), FOREIGN KEY(request_id,profile_id) REFERENCES requests(id,profile_id)) STRICT"
  ]

-- | Version-four queue order and independently retained native admission observations.
admissionMigration :: [Text]
admissionMigration =
  [ "ALTER TABLE requests ADD COLUMN input_revision TEXT",
    "ALTER TABLE requests ADD COLUMN queue_origin_revision TEXT",
    "ALTER TABLE requests ADD COLUMN queue_generation TEXT",
    "ALTER TABLE requests ADD COLUMN enqueue_command TEXT REFERENCES commands(id) DEFERRABLE INITIALLY DEFERRED",
    "ALTER TABLE reservations ADD COLUMN request_revision TEXT",
    "ALTER TABLE reservations ADD COLUMN profile_revision TEXT",
    "ALTER TABLE reservations ADD COLUMN queue_ordinal TEXT",
    "ALTER TABLE reservations ADD COLUMN pending_command TEXT REFERENCES commands(id) DEFERRABLE INITIALLY DEFERRED",
    "ALTER TABLE reservations ADD COLUMN pending_kind TEXT CHECK(pending_kind IN ('edit','withdraw','expired','closed','worker-lost'))",
    "CREATE TRIGGER admission_ordinal_insert BEFORE INSERT ON requests WHEN NEW.queue_ordinal IS NOT NULL AND NOT(length(NEW.queue_ordinal) BETWEEN 1 AND 20 AND NEW.queue_ordinal NOT GLOB '*[^0-9]*' AND (NEW.queue_ordinal='0' OR substr(NEW.queue_ordinal,1,1) BETWEEN '1' AND '9') AND (length(NEW.queue_ordinal)<20 OR NEW.queue_ordinal<='18446744073709551615')) BEGIN SELECT RAISE(ABORT,'invalid queue ordinal'); END",
    "CREATE TRIGGER admission_ordinal_update BEFORE UPDATE OF queue_ordinal ON requests WHEN NEW.queue_ordinal IS NOT NULL AND NOT(length(NEW.queue_ordinal) BETWEEN 1 AND 20 AND NEW.queue_ordinal NOT GLOB '*[^0-9]*' AND (NEW.queue_ordinal='0' OR substr(NEW.queue_ordinal,1,1) BETWEEN '1' AND '9') AND (length(NEW.queue_ordinal)<20 OR NEW.queue_ordinal<='18446744073709551615')) BEGIN SELECT RAISE(ABORT,'invalid queue ordinal'); END",
    "CREATE TABLE admission_queue_clock (singleton INTEGER PRIMARY KEY CHECK(singleton=1), last_ordinal TEXT NOT NULL CHECK(length(last_ordinal) BETWEEN 1 AND 20 AND last_ordinal NOT GLOB '*[^0-9]*' AND (last_ordinal='0' OR substr(last_ordinal,1,1) BETWEEN '1' AND '9') AND (length(last_ordinal)<20 OR last_ordinal<='18446744073709551615'))) STRICT",
    "INSERT INTO admission_queue_clock SELECT 1,coalesce((SELECT queue_ordinal FROM requests WHERE queue_ordinal IS NOT NULL ORDER BY length(queue_ordinal) DESC,queue_ordinal DESC LIMIT 1),'0')",
    "DROP TRIGGER release_without_claims",
    "DROP TRIGGER claim_active_reservation",
    "DROP TRIGGER move_claim_to_active_reservation",
    "ALTER TABLE reservation_resources RENAME TO reservation_resources_v3",
    "CREATE TABLE reservation_resources (kind TEXT NOT NULL CHECK(kind IN ('operator','unclassified')), resource_key TEXT NOT NULL, reservation_id TEXT NOT NULL REFERENCES reservations(id), PRIMARY KEY(kind,resource_key), CHECK(kind='operator' OR resource_key='')) STRICT",
    "INSERT INTO reservation_resources SELECT 'operator',resource_key,reservation_id FROM reservation_resources_v3",
    "DROP TABLE reservation_resources_v3",
    "CREATE TRIGGER release_without_claims BEFORE UPDATE OF state ON reservations WHEN NEW.state='released' AND EXISTS(SELECT 1 FROM reservation_resources WHERE reservation_id=OLD.id) BEGIN SELECT RAISE(ABORT,'reservation retains resource claims'); END",
    "CREATE TRIGGER claim_active_reservation BEFORE INSERT ON reservation_resources WHEN (SELECT state FROM reservations WHERE id=NEW.reservation_id)='released' BEGIN SELECT RAISE(ABORT,'reservation is released'); END",
    "CREATE TRIGGER move_claim_to_active_reservation BEFORE UPDATE OF reservation_id ON reservation_resources WHEN (SELECT state FROM reservations WHERE id=NEW.reservation_id)='released' BEGIN SELECT RAISE(ABORT,'reservation is released'); END",
    "CREATE TABLE admission_observations (reservation_id TEXT PRIMARY KEY NOT NULL REFERENCES reservations(id), native_run_id TEXT NOT NULL, root_identity TEXT NOT NULL, observed_at TEXT NOT NULL, review_expires_at TEXT NOT NULL, state TEXT NOT NULL CHECK(state IN ('prepared','invalidated','handed-off')), reason TEXT CHECK(reason IN ('input-changed','withdrawn','expired','closed','worker-lost'))) STRICT"
  ]

-- | Version-five immutable consent/start association, separate from Runtime evidence.
approvalMigration :: [Text]
approvalMigration =
  [ "CREATE TABLE start_intents (command_id TEXT PRIMARY KEY NOT NULL REFERENCES commands(id) DEFERRABLE INITIALLY DEFERRED, client_id TEXT NOT NULL REFERENCES clients(id), request_id TEXT NOT NULL UNIQUE REFERENCES requests(id), preparation_id TEXT NOT NULL UNIQUE REFERENCES preparations(id), run_id TEXT NOT NULL UNIQUE REFERENCES runs(id), reservation_id TEXT NOT NULL REFERENCES reservations(id), process_generation TEXT NOT NULL, worker_identity TEXT NOT NULL, FOREIGN KEY(preparation_id,request_id) REFERENCES preparations(id,request_id), FOREIGN KEY(reservation_id,request_id) REFERENCES reservations(id,request_id)) STRICT",
    "CREATE TRIGGER start_intent_immutable BEFORE UPDATE ON start_intents BEGIN SELECT RAISE(ABORT,'start intent is immutable'); END",
    "CREATE TRIGGER start_intent_retained BEFORE DELETE ON start_intents BEGIN SELECT RAISE(ABORT,'start intent is retained'); END"
  ]

-- | Version-six immutable original-wire evidence backing versioned projections.
ingestionMigration :: [Text]
ingestionMigration =
  [ "CREATE TRIGGER ingestion_immutable BEFORE UPDATE ON ingestions BEGIN SELECT RAISE(ABORT,'ingestion is immutable'); END",
    "CREATE TRIGGER ingestion_retained BEFORE DELETE ON ingestions BEGIN SELECT RAISE(ABORT,'ingestion prefix is retained'); END",
    "CREATE TRIGGER ingestion_frame_bound BEFORE INSERT ON ingestions WHEN length(NEW.envelope) NOT BETWEEN 1 AND 1048577 OR (length(NEW.envelope)=1048577 AND substr(NEW.envelope,-1)!=X'0A') OR length(NEW.envelope_digest)!=64 BEGIN SELECT RAISE(ABORT,'invalid ingestion evidence'); END",
    "CREATE TRIGGER observed_run_identity BEFORE UPDATE OF profile_id,root_identity,native_run_id ON runs WHEN EXISTS(SELECT 1 FROM ingestions WHERE run_id=OLD.id) BEGIN SELECT RAISE(ABORT,'observed run identity is immutable'); END",
    "CREATE INDEX ingestion_order ON ingestions(run_id,length(sequence),sequence)"
  ]
