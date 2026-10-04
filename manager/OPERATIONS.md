# Operator procedures of the local manager

This runbook states the procedures that an operator uses to run one local
workflow manager on one macOS machine. Each procedure names its
preconditions, the configuration that it uses, the exact requests, the
expected answers, the diagnostics to read and the bounded failure answers.
The [command contract](COMMANDS.md#local-credential-administration) and the
[storage contract](STORAGE.md) define the behavior that these procedures
use. The [protocol document](../doc/api/README.md) defines the `/v1` routes.
The [getting-started guide](../doc/getting-started.md) creates a manager,
starts it, connects the TUI, Pi and Emacs, and runs the daily commands of this
runbook in order.

## Create a manager root

`RUNNER --manager init --root ROOT [--port PORT]` creates a complete manager
root for the runner that runs the command. `ROOT` is an absolute directory
that does not exist or is empty. Its parent directory must exist. `PORT` is
the HTTPS port on `127.0.0.1`, and the default port is 8443. The command does
these steps in order:

1. It creates `ROOT` with mode 0700 and uses its canonical path in every file
   that it writes. On macOS, `/tmp` and `/var` are symbolic links into
   `/private`, and the manager refuses a configuration path with a symbolic
   link in it, so the canonical path is the only path that works.
2. It creates the directories `manager`, `admin`, `workspace`, `tls`, `bin`
   and `client` below `ROOT`, each with mode 0700.
3. It links `bin/agentic-run` to the executable that runs the command.
4. It writes `serve.json` and `offline.json` from the [reference configuration
   pair](#reference-configuration-pair), with the root and the port in place of
   the placeholders. The port goes into `https.port` and into
   `https.allowedHosts`. Both files have mode 0600.
5. It creates a self-signed certificate `tls/certificate.pem` for the address
   `127.0.0.1` and its key `tls/key.pem` with the `openssl` of `PATH`. Both
   files have mode 0600.
6. It validates `offline.json` with an offline `reload-profiles`.
7. It issues one credential for every configured profile through
   `offline.json`, with the scopes `observe`, `submit`, `control` and
   `export`, into `client/profile.credential`.
8. It writes the client profile `client/profile.json` with mode 0600 and
   prints the commands that start the manager, ask for its status, stop it
   and connect the TUI, Pi and Emacs.

A root that exists and is not empty, a relative root, a port outside 1 to
65535 and a root whose path leaves `admin/admin.sock` longer than 103 bytes,
the Unix socket address limit of macOS, refuse before any change. A step that fails stops the command with a
line that names the step, and the root keeps what the earlier steps made.
Remove that root and run the command again.

To make the certificate without `init`, run this command in the `tls`
directory. It writes the same two files:

```sh
cat > openssl.cnf <<'EOF'
[req]
distinguished_name = subject
x509_extensions = listener
prompt = no
[subject]
CN = 127.0.0.1
[listener]
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints = critical,CA:true
subjectAltName = IP:127.0.0.1
EOF
openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 3650 \
  -config openssl.cnf -keyout key.pem -out certificate.pem
chmod 600 key.pem certificate.pem && rm openssl.cnf
```

OpenSSL and the LibreSSL of macOS both accept this configuration-file form.

`manager/ci/bootstrap.sh` runs `init`, `serve`, `status`, `add-client` and
`shutdown` in a new root below `TMPDIR` with an isolated `HOME`. It checks
the modes, the listening line, the answer 200 of both client profiles and the
refusal lines of this runbook.

### Start the manager

`RUNNER --manager serve --config SERVE_FILE` runs in the foreground until a
`shutdown` request or a termination signal stops it. When the HTTPS listener
is bound, it writes one line to standard output:

```text
manager listening on https://127.0.0.1:PORT/v1
```

Standard error is the [private fault log](#private-fault-log). A certificate
or key file that the private-file rule refuses stops the start with status 1
and a line that names the member (`https.certificateFile` or `https.keyFile`),
the file and the rule: a regular file that the user owns, with mode 0600, at a
path with no symbolic-link component. A configuration path with a symbolic
link in it stops the start with a line that names the link.

## Two configurations for one manager root

The operator keeps two configuration files for one `managerRoot`. Both files
are private files of the operator account, with mode 0600.

- The serve configuration, written `SERVE_FILE` below, names
  `administrationRoot`. `RUNNER --manager serve --config SERVE_FILE` starts
  the manager, and `RUNNER --manager admin --config SERVE_FILE` sends one
  request to the serving manager through its local channel.
- The offline configuration, written `OFFLINE_FILE` below, is the same file
  without `administrationRoot`. `RUNNER --manager admin --config
  OFFLINE_FILE` opens the Store itself. Use it only when no manager serves.

A configured `administrationRoot` is authoritative even when no manager
serves. A request through `SERVE_FILE` then refuses with
`storage-unavailable` and never falls back to the offline path. An offline
request while a manager serves refuses with `storage-unavailable`, because the
serving manager holds the configuration lease. Offline `reload-profiles` is
the only exception: it takes no lease and opens no Store.

When one file changes, make the same change in the other file. The
[configuration contract](CONFIGURATION.md) defines the format. The serve
configuration also holds the `https` section with the members `host`,
`port`, `certificateFile`, `keyFile`, `allowedHosts`, `allowedOrigins` and
`allowedPeers`.

`RUNNER` is the configured registry executable, for example `agentic-run`.

### Reference configuration pair

The files [`doc/examples/manager-serve.json`](../doc/examples/manager-serve.json)
and [`doc/examples/manager-offline.json`](../doc/examples/manager-offline.json)
are a reference pair for one manager root. They are data files of the
package, and `init` reads the installed copies. The serve file listens with
HTTPS on `127.0.0.1` port 8443, admits the Host `127.0.0.1:8443` and the peer
`127.0.0.1`, names a private `administrationRoot`, and allows 4 execution
reservations, so that one request that waits in review does not block later
work. It installs two service-owned profiles:

- `scripted` runs the native runner with `--scripted`, which reaches no model
  and no network.
- `person` runs the native runner with `--engine acp --person-answer
  model:namer`. The default stub adapter answers every model ask, and a person
  answers the ask of the model `namer` through a decision of the manager, as in
  the `hello` workflow. Its environment holds `PATH` with the value
  `/usr/bin:/bin`, because the stub adapter is a `python3` script and a worker
  inherits no environment.

The offline file is the same file without `administrationRoot`.
[CONFIGURATION.md](CONFIGURATION.md#a-profile-for-a-real-engine) shows a
profile for a real engine.

Every path in the pair starts with the placeholder `/Users/OPERATOR/agent-cat`.
`init` replaces the placeholder and the port. To use the pair without `init`,
copy both files, replace the placeholder with the canonical path of an
existing private directory of the operator account, replace 8443 with the
port in `port` and in `allowedHosts`, and give each copy mode 0600. The
directories `manager`, `admin`, `workspace` and `tls` below it must exist with
mode 0700, the `tls` directory holds the certificate and the key of the
listener, and `bin/agentic-run` is the runner executable. Then validate the
offline copy as in [Validate a configuration
offline](#validate-a-configuration-offline). A copy of the offline file with
private fixture paths answers that validation with `profileIds`
`["scripted", "person"]` and a `revision`, and it leaves the manager root
empty.

## The administration command

`RUNNER --manager admin --config FILE` reads one JSON request from standard
input until end of file and writes one JSON line to standard output. A
successful answer has the form
`{"version": 1, "operation": OPERATION, "ok": true, "result": RESULT}`, and
the command exits with status 0. A refusal has the form
`{"version": 1, "operation": OPERATION, "ok": false, "error": {"code": CODE,
"message": ""}}`, and the command exits with status 1. A malformed request,
an unknown field or an unknown operation refuses before dispatch with
`operation` `null`. For example:

```sh
printf '%s' '{"version": 1, "operation": "status"}' | RUNNER --manager admin --config OFFLINE_FILE
```

The `message` of a refusal is always empty. For a refusal whose cause the
operator can act on, the command also writes one line that starts with
`manager admin:` to standard error and names that cause:

- A request through `SERVE_FILE` while no manager serves names the
  `administrationRoot` and states that no manager serves on it.
- A configuration path with a symbolic link in it names the link. Give the
  canonical path.
- A configuration file that cannot be read as a private file of the user, or
  that is not a valid configuration, is named with the rule that it breaks.
- An offline request that cannot take the manager root states that a serving
  manager holds it or that a configured directory is missing or not private.
- `issue-credential` with a profile identifier that the configuration does not
  define names that identifier.

The request bodies in this runbook are the bodies that the `operations` mode
of `manager/test/service_http.py` sends. The `release-quarantine` body is the
body that its `failures-manager` mode sends. Upper-case words in a body stand
for the values of the operator. Every path in a body is absolute.

The local channel has a deadline of fifteen seconds for one exchange. A
reply that does not arrive in that time is a lost reply, and the outcome of
the request is uncertain. The section
[Lost replies and uncertain mutations](#lost-replies-and-uncertain-mutations)
gives the procedure.

## Diagnostics

### Status

Request: `{"version": 1, "operation": "status"}`.

Through `SERVE_FILE`, the serving manager answers with its current facts. It
appends nothing to the manager log. Through `OFFLINE_FILE`, the command opens
the Store, answers and closes it. The answer holds `state`, `authorityEpoch`,
`streamId`, `processGeneration` and `activeReservations`, and the
operational facts `live`, `ready`, `queuedRequests`,
`oldestQueuedAgeSeconds`, `reservations`, `ownedWorkers`, `lostRuns`,
`unresolvedCommands` and `serviceFault`. The section
[Status facts](COMMANDS.md#status-facts) defines each fact.

- `state` is `serving` through the live channel, `draining` after a drain
  and `stopped` offline.
- `live` is `true` only when a serving lifetime answers. `ready` is `true`
  only when that lifetime admits work and its service fault cell is empty.
  A manager that is live and not ready serves reads and admits no new work.
- `reservations.quarantined` greater than 0 means that claims wait for
  cleanup evidence. See [Quarantine inspection and
  release](#quarantine-inspection-and-release).
- `lostRuns` counts runs without a terminal observation whose supervision is
  lost. `unresolvedCommands` counts commands whose outcome is uncertain.
- `serviceFault` names the class of the current service fault, or `none`.

The `streamId` of `status` is the stream identity of the Store, which also
names the manager log file `flow/STREAM.ndjson`. The `streamId` of
`GET /v1/capabilities` is a different value: the public stream identity that
the manager derives for each credential. The two values never match, and two
credentials receive two different public values.

Offline status opens the Store in restart mode. Each offline status creates
a new process generation, and it reconciles a restart as a serving lifetime
does: it quarantines each reservation that a crashed lifetime held. Two
offline status answers therefore have the same `authorityEpoch` and
`streamId` and two different `processGeneration` values. An offline status
writes no manager log.

### Store check

Request: `{"version": 1, "operation": "check-store"}`.

The result holds `integrity` and `quarantineIds`. `integrity` is `valid`
when the SQLite quick check passes, `corrupt` when it fails, and
`unavailable` when offline administration cannot open the Store, for example
while a `restore-in-progress` marker exists. `quarantineIds` lists at most
256 identities of quarantined reservations and of the claims that a
restoration carried forward.

### Quarantine check

Request: `{"version": 1, "operation": "check-quarantine", "quarantineId": "QUARANTINE_ID"}`.

The result holds `quarantineId`, `state`, `cleanupEvidenceId`,
`cleanupEvidenceDigest`, `processGeneration` and `expiresAt`. The state is
`clean`, `cleanup-required` or `unverifiable`. Only a `clean` answer carries
evidence, and that evidence expires 600 seconds after the check. An unknown
identity, or a reservation that is not quarantined, refuses with
`state-conflict`. The
[manager-loss section of WORKERS.md](WORKERS.md#manager-loss-and-restart)
states the facts of each state.

### Manager log and run logs

`RUNNER flow PATH...` reads and verifies logs. Give it the `flow` directory
of the manager root, which stands for every manager log in it, and the run
store directories `runs/runs/RUN/runtime` of the runs to inspect. The verb
writes one JSON object for each record and a final summary object. It exits
0 when every verification passes, 2 when every verification passes and a run
log ended without its stop or a manager log holds a lifetime without its
shutdown notice, 1 when a verification fails, and 3 when it cannot open a
store. The lifetime of a manager that still serves has no shutdown notice, so
the verb exits 2 until that manager stops. The summary names the retained floor of each manager log
as `floor`.

Each local administration operation of the live channel that changes state
appears in the manager log as a `command` record with the field
`administration` and its reply. `status`, `check-store` and
`check-quarantine` append nothing. Offline operations append nothing. A
restoration rotates the stream identity, so the next serving lifetime writes a
new file `flow/STREAM.ndjson`.

`GET /v1/routes` serves the manager log of the current stream to
credentials that the scope rules admit, as the protocol document states.

### Private fault log

The serve process writes its private fault log to standard error. Redirect
standard error to a private file, for example with
`2>>/PRIVATE_DIR/manager-faults.log`. Each line has the form
`manager-fault TIME CONTEXT class=LABEL`. A line holds fixed words, validated
identifiers and the public path of a refused response. It holds no path of
the file system, no exception text and no request content. Lines to look for:

- `manager-log open class=flow WORD`, where WORD is `oversized`,
  `undecodable` or `io-failure`: the manager log did not open. See
  [Manager-log pruning](#manager-log-pruning).
- `manager-log prune` with `stopped`: the pruner stopped for the rest of
  the lifetime.
- `manager-log reconciliation` with `stopped unreadable`: the asks of an
  earlier lifetime could not be read.
- `busy site=SITE class=store StoreBusy`: a Store admission waited out its
  five-second allowance.

A client that detaches while it reads `/v1/events`, for example the TUI after
`q`, can leave one line of the form `manager-fault TIME response GET
/v1/events started public=410 view-expired class=command ViewExpired`, or the
same line with `public=503 storage-unavailable class=unexpected
InvalidRequest`. The response had started, and the line records only that
the stream ended early. It needs no action.

### HTTP reads

`GET /v1/capabilities` with a current bearer answers 200 and reports the
authority epoch of the Store. Without a bearer every route answers 401.
`GET /v1/runs/RUN` reports the `supervision` of a run, which is `lost` after
a manager loss. `GET /v1/commands/COMMAND` reports the state of a command.

## Configuration validation (offline) and live profile reload

### Validate a configuration offline

Preconditions: the edited `OFFLINE_FILE` exists as a private file.

Configuration: `OFFLINE_FILE`. A manager may serve at the same time.

Request: `{"version": 1, "operation": "reload-profiles"}`.

Expected answer: `profileIds`, the profile identifiers in ascending order,
and `revision`. The `revision` of an offline validation comes from a
discarded registry and equals no installed revision. No Store file changes.

Failure answers: an invalid file refuses with `state-conflict`. A file that
the loader cannot read as a private file of the user, such as an absent file,
a file that others can read or a file above 2 MiB, refuses with
`storage-unavailable`.

### Reload profiles on the serving manager

Preconditions: a manager serves. The edited `SERVE_FILE` is in place, and it
keeps the `managerRoot`, `administrationRoot` and `https` values of the
running manager.

Configuration: `SERVE_FILE`.

Request: `{"version": 1, "operation": "reload-profiles"}`.

Expected answer: `profileIds` and `revision`. Every profile receives a new
revision, even when its values did not change. The manager probes each
profile before it answers. `GET /v1/profiles` then shows an added profile,
and `issue-credential` can name it. A review prepared under an earlier
profile revision refuses approval with 412 `stale-revision`, so the client
prepares the request again. The manager log holds the reload `command` and
its `receipt`.

Failure answers: a changed `managerRoot`, `administrationRoot` or `https`
section, and every other invalid file, refuse with `state-conflict`. An
unreadable file refuses with `storage-unavailable`. A refused reload changes
nothing, and the installed profiles keep serving.

Diagnostics: `GET /v1/profiles` shows the readiness of each profile.

## Client provisioning, rotation, revocation and listing

These operations work through `SERVE_FILE` while a manager serves and
through `OFFLINE_FILE` while none serves. The secret goes only to the output
file. The answer holds only metadata.

### Provision a client

A client needs a client profile: a private JSON file of version 1 with
exactly the members `version`, `endpoint`, `credentialFile` and `caFile`.
`endpoint` is the `https` URL of the `/v1` base. `credentialFile` is the
absolute path of the file that holds the bearer. `caFile` is the absolute
path of the certificate that signed the certificate of the listener, which
for the certificate of `init` is the certificate itself. The profile file and
the credential file have mode 0600. The TUI, Pi and Emacs read the same file:

```json
{"version": 1, "endpoint": "https://127.0.0.1:8443/v1", "credentialFile": "/PRIVATE_DIR/laptop.credential", "caFile": "ROOT/tls/certificate.pem"}
```

`RUNNER --manager add-client --config FILE --profile-file PROFILE_FILE
[--profile ID]...` issues one credential and writes this file. `FILE` is
`SERVE_FILE` while a manager serves and `OFFLINE_FILE` while none serves.
`PROFILE_FILE` is an absolute path that does not exist, in an existing
private directory. The credential file is `PROFILE_FILE` with the extension
`.credential` in place of `.json`. Each `--profile` names a configured
profile, and without the option the credential covers every configured
profile. The label of the credential is the base name of `PROFILE_FILE`, and
its scopes are `observe`, `submit`, `control` and `export`. The command
prints the commands that connect the TUI, Pi and Emacs with the new profile.
An unknown profile identifier refuses with a line that names it.

A credential covers only the profiles that it names. After a profile is added
to the configuration and loaded with `reload-profiles`, issue a new
credential that names it, for example with `add-client --profile NEW_ID`.

`add-client` sends the request below with its own label, scopes, profile
identifiers and output file. An operator can also send it directly.

Preconditions: the parent directory of the output file exists and is
private. The output file does not exist.

Request:

```json
{"version": 1, "operation": "issue-credential", "label": "LABEL", "scopes": ["observe", "submit", "control"], "profileIds": ["PROFILE_ID"], "expiresAt": "2999-01-01T00:00:00Z", "outputFile": "/PRIVATE_DIR/CREDENTIAL_FILE"}
```

The scopes are a subset of `observe`, `submit`, `control` and `export`. The
expiry is a future RFC 3339 time.

Expected answer: `result.credential` with `credentialId`, `clientId`,
`label`, `scopes`, `profileIds`, `expiresAt` and `state` `active`. The output
file holds the bearer: 64 lowercase hexadecimal characters with no newline.
Give the file to the client by a private path. The new credential belongs to
a new registered client.

Failure answers: a past expiry, an unknown profile and an existing output
file refuse. A refusal before the publication of the file creates no file.
After an uncertain outcome, keep the output file and check the listing. Do
not delete the file or repeat the request on the assumption that nothing
happened.

### List credentials

Request: `{"version": 1, "operation": "list-credentials"}`.

Expected answer: `result.credentials`, at most 256 records, each with the
metadata above and `state` `active`, `revoked` or `expired`. A credential
whose rotation cutoff has passed reads `revoked`, and its declared expiry is
unchanged.

### Rotate a credential with overlap and cutoff

Preconditions: the credential is active and has not been rotated before.
Rotate it before it expires.

Request:

```json
{"version": 1, "operation": "rotate-credential", "credentialId": "CREDENTIAL_ID", "expiresAt": "2999-01-01T00:00:00Z", "outputFile": "/PRIVATE_DIR/NEW_CREDENTIAL_FILE"}
```

Expected answer: `result.credential`, the new credential of the same client
with the same label, scopes and profiles, and `result.previousCredentialId`.
Both credentials authenticate during the overlap. The overlap lasts 60
seconds, or less when the declared expiry of the predecessor comes first. At
the cutoff the predecessor receives 401 `unauthenticated` on every route, and
`list-credentials` reports it `revoked`. Install the new file in the client
during the overlap. The idempotency ledger belongs to the client, so the new
credential that repeats an exact attempt of the predecessor receives the
retained receipt.

Failure answers: a revoked, expired or already rotated credential refuses
with `state-conflict` and publishes no file.

### Revoke a credential

Request: `{"version": 1, "operation": "revoke-credential", "credentialId": "CREDENTIAL_ID"}`.

Expected answer: `result` with `credentialId` and `state` `revoked`. The
credential receives 401 at its next authorization check, including the next
page of a page set, a receipt read, a download and a new POST, and its open
event stream ends. Revocation does not cancel accepted work. Another
credential with `control` on the profile can answer the questions of a live
run. To end a rotation overlap at once, revoke the predecessor.

## Drain, cancel of owned runs and shutdown

### Drain

Preconditions: a manager serves.

Configuration: `SERVE_FILE`. Offline, `drain` refuses with
`state-conflict`.

Request: `{"version": 1, "operation": "drain"}`.

Expected answer: `{"state": "draining"}`. A repeated drain answers the same.
The drain has no deadline and cannot be reversed for the rest of the
lifetime. `status` then reports `state` `draining`, `live` `true` and `ready`
`false`. The manager admits no new work: an enqueue, an input change, a
withdrawal, and the approval and discard of a live review receive 503
`storage-unavailable`. A request can still be created. A queued request stays
queued. A review whose approval has not committed becomes invalid with the
reason `worker-lost`, and its request returns to the queue at its original
position. Started runs continue, and their questions, recovery decisions and
controls work as usual. Reads and event streams keep serving until the
process ends. The manager log holds the drain `command` and its `receipt`.

Wait until `status` reports `activeReservations` 0 and `ownedWorkers` 0, or
cancel the runs that must not finish. Then shut down.

### Cancel an owned run

Preconditions: a credential with `control` on the profile of the run. The
run has `supervision` `owned`, and `GET /v1/runs/RUN/control` reports
`cancelAllowed` `true`.

Interface: HTTPS. Read `GET /v1/runs/RUN/control` and keep its `ETag`. Then
send `POST /v1/runs/RUN/control` with the headers `Authorization: Bearer
BEARER`, `Content-Type: application/json`, `Idempotency-Key:
AUTHORITY_EPOCH.NONCE` and `If-Match: ETAG`, and the body:

```json
{"operation":"cancel"}
```

Expected answer: 202 with a `CommandReceipt`. Read `GET /v1/commands/COMMAND`
until it is `acknowledged` or `effect-observed`. `GET /v1/runs/RUN/snapshot`
then reports the runtime status `cancelled`, and the reservation of the run is
released after its cleanup. A cancel works during a drain, and it keeps a
reserve of the manager log when ordinary commands refuse with
`storage-quota`.

Failure answers: a stale `If-Match` receives 412 `stale-revision`, and a
missing one receives 428 `precondition-required`. A run whose supervision is
`lost` offers no cancel.

### Shut down

Preconditions: a manager serves.

Configuration: `SERVE_FILE`.

Request: `{"version": 1, "operation": "shutdown"}`.

Expected answer: `{"state": "stopped"}`. The manager then ends as at a
termination signal: each owned run is cancelled with its cleanup, open event
and route streams end, the manager log receives the shutdown notice, and the
serve process exits with status 0. A drain in progress does not delay the
shutdown. A run that the shutdown cancelled has no terminal record, so the
next lifetime reports it with `supervision` `lost` and no cancel. The next
lifetime prepares the queued requests with no client command. No command
executes again.

The termination signal (SIGTERM) to the serve process has the same effect.
The keyboard signal (SIGINT) ends the process as an interrupted command.

Failure answers: when the shutdown command cannot be appended to the manager
log, the shutdown refuses with `storage-unavailable` and the manager keeps
serving. Use the termination signal in that case.

Offline, while no manager serves, `shutdown` through `OFFLINE_FILE` answers
`{"state": "stopped"}` and changes nothing. It proves that no manager holds
the configuration lease.

## Offline backup and restore

### Back up offline

Preconditions: no manager serves. Offline `status` reports
`activeReservations` 0. A backup with active reservations is valid, but a
restoration from it carries those reservations forward as unverifiable claims
that cannot be released. The destination does not exist, its parent is an
existing private directory, and it is outside the manager root.

Configuration: `OFFLINE_FILE`. Through `SERVE_FILE`, a serving manager
refuses `backup` with `state-conflict` and creates nothing.

Request:

```json
{"version": 1, "operation": "backup", "outputFile": "/PRIVATE_DIR/BACKUP_DIR"}
```

Expected answer: `backupId`, `sha256` and `bytes`. The directory has mode
0700 and holds `coordination.sqlite3`, the directory `captures` and the
completion binding `complete`, which is written last. `sha256` is the
SHA-256 digest of `coordination.sqlite3`, and `bytes` is its size. Every
backup of one manager root has the same `backupId`, and `sha256` tells two
backups apart. Keep the answer with the backup. The source Store keeps its
rows.

Failure answers: an existing destination refuses with `output-conflict` and
writes nothing. A destination inside the manager root, a parent that is not
private and every other failure refuse with `storage-unavailable`. A failure
after the creation of the destination leaves a directory without `complete`.
That directory is not a backup. Remove it before a retry into the same path.

### Restore with fencing evidence

Preconditions: no manager serves. The backup is complete and was taken from
this manager root.

1. Stop the manager with `shutdown` and confirm that the serve process
   exited.
2. Save the fencing evidence. Run offline `status` through `OFFLINE_FILE`
   and save the whole answer line, unchanged, in a private file in a private
   directory. Its `state` is `stopped`. The restoration compares its
   `authorityEpoch` and `streamId` with those of the stopped Store. It does
   not compare `processGeneration`, because each offline status creates a new
   one.
3. Restore through `OFFLINE_FILE`:

   ```json
   {"version": 1, "operation": "restore", "backupFile": "/PRIVATE_DIR/BACKUP_DIR", "fencingEvidenceFile": "/PRIVATE_DIR/fencing-evidence.json"}
   ```

   Expected answer: the new `authorityEpoch` and `streamId`,
   `credentialsRevoked` `true` and `reprovisioned` `false`. The Store now
   holds the state of the backup. Every restored credential is revoked.
4. Reprovision credentials. Issue a new credential for each client with
   `issue-credential` through `OFFLINE_FILE`, as in
   [Provision a client](#provision-a-client). A restored credential cannot be
   rotated, because it is revoked.
5. Check the result. Offline `status` reports the new identities, and
   `check-store` reports `valid`.
6. Start the manager with `SERVE_FILE`. The old credentials receive 401, and
   the new credentials read the restored state.

Failure answers: evidence that is not a stopped status answer, or that names
another authority epoch or stream, refuses with `state-conflict` and changes
nothing. An unreadable evidence file, a backup of another root, a backup
without `complete` or with a damaged copy, and every other failure refuse with
`storage-unavailable`. Through `SERVE_FILE`, a serving manager refuses
`restore` with `state-conflict` and reads neither file.

### Complete an interrupted restoration

A restoration that ends after it wrote its `restore-in-progress` marker
leaves the Store fenced. Then `RUNNER --manager serve` exits with status 2
and writes "manager service is unavailable" to standard error. Offline
`status` refuses with `storage-unavailable`, and `check-store` reports
`unavailable`.

Do not delete the marker. Send the same `restore` request again, with the
same backup and the same fencing evidence file. The restoration compares the
evidence with the identities that the marker records and requires the backup
whose `sha256` the marker records. It answers the same frozen result and
removes the marker last. Then continue at step 4 above.

Failure answers: evidence of other identities and another backup refuse with
`state-conflict` and leave the marker. A marker that an earlier version wrote
refuses every restoration with `state-conflict`.

## Manager-log pruning

The manager log of the current stream is its sealed segments in
`flow/sealed/STREAM/` and the active file `flow/STREAM.ndjson`. The writer
seals the active file when an append would take it above the segment size S,
which is max(65536, (L - R) div 16), where L is `globalMutationLedgerBytes`
and R is the reserve min(L, 16 * C).

The pruner runs one round when a serving lifetime opens its Store and one
round after each seal. A round removes the oldest sealed segments, one at a
time, while a trigger holds and nothing protects the segment, and it stops at
the first segment that it keeps. The triggers are the age of the newest
record of the segment above 604800 seconds and a log size above (L - R) div 2.
A segment that names a request that is not terminal, a run that is not
observed terminal and not lost, the parent run of such a request, or an ask
without a reply is protected. The newest sealed segment and the active file
are never removed. The retained floor is the start of the oldest sealed
segment that remains.

There is no timer. The age trigger is evaluated only at the open and after a
seal. To apply it to a manager that does not seal, restart the manager:
`shutdown`, then `serve` again. The open runs a round.

Procedure:

1. Read the floor in the summary of `RUNNER flow` on the `flow` directory, or
   the `oldestCursor` of `GET /v1/routes`. A cursor below the floor receives
   410 `cursor-expired`.
2. When the floor does not advance, look for live work in `status`: queued
   requests, reservations in review or running, and owned workers. Live work
   holds the floor. End or cancel that work, then restart.
3. When the private fault log has a `manager-log prune` line with `stopped`,
   the pruner stopped for the lifetime. Restart the manager.
4. After a restoration, the logs of earlier streams stay in `flow/` and are
   never pruned. They do not count toward the ceiling of the current log.
   Move them to a private archive or remove them while no manager serves.

When the log cannot open (`manager-log open class=flow` in the fault log), every
ordinary command and every review publication refuses with
`storage-unavailable`, and a cancel still works. Recover as follows:

1. Stop the manager.
2. Move `flow/STREAM.ndjson`, `flow/sealed/STREAM/` and `flow/claims/STREAM/`
   into a private archive directory with the same relative layout. For an
   oversized log, raise `globalMutationLedgerBytes` in both configuration
   files instead.
3. Start the manager. The new log begins at position 0 with its lifetime
   notice.
4. Read the archived log with `RUNNER flow`.

## Quarantine inspection and release

A manager that ends without its cleanup, for example after SIGKILL or a
power loss, leaves the reservations of its lifetime held. The next Store
open quarantines them. A quarantined reservation keeps its execution slot and
its resource keys, so queued requests can wait for capacity.

Configuration: `SERVE_FILE` while a manager serves, else `OFFLINE_FILE`.

1. Run `status`. `reservations.quarantined` counts the claims.
2. Run `check-store`. `quarantineIds` lists them.
3. Run `check-quarantine` for each identity.
   - `clean`: the reservation never launched a run, the run log holds its
     terminal record, the lock of the run is free, or the run never locked.
     Release it within 600 seconds.
   - `cleanup-required`: the run has no terminal record and its
     `owner.lock` is held, or its manifest exists without the lock. A
     process of the run can still hold the lock. Find and end that process
     by the ordinary tools of the operating system, then check again. The
     manager never signals a stored process identity.
   - `unverifiable`: the run store cannot be read, or the claim came from a
     restoration. It cannot be released.
4. Release a clean claim with the evidence of the last check:

   ```json
   {"version": 1, "operation": "release-quarantine", "quarantineId": "QUARANTINE_ID", "cleanupEvidenceId": "CLEANUP_EVIDENCE_ID", "cleanupEvidenceDigest": "CLEANUP_EVIDENCE_DIGEST"}
   ```

   Expected answer: `quarantineId` with `state` `released`. The slot and the
   resource keys are free. The run keeps its `lost` supervision. On a serving
   manager a queued request is then prepared with no client command. The
   manager log holds the release `command` and its `receipt`.

Failure answers: evidence that is not clean, or whose identity or digest
differs from the current evidence, refuses with `cleanup-unverified`. An
unknown identity, and a reservation that is not quarantined or is already
released, refuse with `state-conflict`. A refusal changes no Store row.

## Disk pressure

The command ledger and the manager log share the ceiling L,
`globalMutationLedgerBytes`, with the cancel reserve R. Captures have the
ceiling `globalCaptureBytes`.

- When the manager log and its claim checks reach L - R while live work
  holds the floor, every ordinary command and every review publication
  receives 429 `storage-quota`. A cancel still uses the reserve R.
- When the charge of the command ledger reaches its limit, ordinary commands
  receive 429 `storage-quota` across restarts, because no serving lifetime
  shrinks the charge. A cancel still uses the reserve.
- A capture upload above the aggregate capture ceiling receives 429
  `storage-quota`.

Procedure:

1. Read `status` and the manager-log size. A large `queuedRequests` count or
   long-lived reservations hold the floor of the manager log.
2. End or cancel the live work that holds the floor, then restart so that
   the open runs a pruning round.
3. When the refusals continue, stop the manager, raise
   `globalMutationLedgerBytes` (or `globalCaptureBytes`) in both
   configuration files, validate `OFFLINE_FILE` offline, and start the
   manager again.
4. Keep free space on the volume of the manager root above the configured
   ceilings. The manager does not measure free space.

## Disk write failure

A definite write failure of the Store, such as `EFBIG` under a file-size
limit, refuses
the command with 503 `storage-unavailable` and leaves no command row. The
failure stops the Store for the rest of the lifetime. Every later command and
read of that lifetime refuses with 503 `storage-unavailable`, including
`GET /v1/capabilities` and a withdrawal. The Store does not resume by itself.

Procedure:

1. Read the private fault log for the refusal class.
2. Free space, or remove the limit that caused the failure.
3. Stop the serve process with `shutdown`. When the local channel refuses,
   send the termination signal. The log of the lifetime can end without its
   shutdown notice.
4. Start the manager. It serves the committed state, and no command executes
   again. A command that received the 503 refusal has no row. A client can
   send it as a new attempt.
5. Before the start, run `check-store` through `OFFLINE_FILE`. It must
   report `valid`.

## Expired credentials

A credential receives 401 `unauthenticated` on every route from its declared
expiry, and `list-credentials` reports it `expired`. The manager checks
expiry at least once each second for open views and streams. An expired
credential cannot be rotated: `rotate-credential` refuses with
`state-conflict` and publishes no file.

Procedure:

1. Rotate each credential before its expiry. Use `list-credentials` to find
   credentials near their `expiresAt`.
2. After expiry, issue a new credential with `issue-credential`. It belongs
   to a new client, so the idempotency ledger of the old client is not
   available to it. Accepted work of the old client continues. Any
   credential with `control` on the profile can answer its questions or
   cancel its runs.
3. Revoke the expired credential when the listing must show that it is no
   longer in use.

## Lost replies and uncertain mutations

A mutation whose reply does not arrive has an uncertain outcome. No client
of this project sends it again automatically.

For an HTTPS mutation:

1. When the response carried a `Location`, read `GET /v1/commands/COMMAND`.
   It reports `accepted`, `dispatch-attempted`, `acknowledged`,
   `effect-observed`, `refused` or `unresolved`.
2. When no response arrived, read the resource that the mutation changes,
   such as the request, the run or its control, and decide.
3. To learn the outcome through the ledger, an operator can decide to repeat
   the exact attempt once, with the same method, URI, `Idempotency-Key`,
   body, media type and `If-Match`. When the manager admitted the first
   attempt, it returns the retained receipt and executes nothing again. A
   key of another authority epoch receives 409 `authority-changed`.
4. Never repeat an uncertain mutation with a new key.

A start or a control whose outcome is unknown after a manager loss reads
`unresolved`, and `status` counts it in `unresolvedCommands`. It never
executes again.

For a local administration request, the reply is lost after fifteen seconds.
Run `list-credentials`, `status` or `check-store` to observe the state. After
the next serving lifetime opens, the manager answers each orphaned
administration ask in the manager log with a `failure` reply: `committed-receipt-lost` when the
Store holds the committed effect of a credential operation or a release, and
`outcome-uncertain` for any other operation. Read these replies with
`RUNNER flow`. A credential file that exists after an uncertain issue can be
active or inert. Keep it until the listing shows its state.

## Corrupt store

Offline `check-store` reports `corrupt` when the SQLite quick check fails,
and `unavailable` when the Store cannot open.

Procedure:

1. Stop the manager and keep it stopped.
2. Copy the whole manager root into a private archive for investigation.
3. When offline `status` answers, save its answer as the fencing evidence and
   restore from the latest complete backup, as in
   [Restore with fencing evidence](#restore-with-fencing-evidence). A
   restoration requires readable current safety facts. When they are corrupt
   or missing, the restoration refuses before it publishes the database.
4. When offline `status` refuses, no fencing evidence exists, and these
   tools cannot restore the root. A backup restores only into the manager
   root from which it was taken, and a restoration into a new root is not
   supported. Keep the root out of service for investigation.

## Proxy or network failure between client and manager

The manager accepts only TLS 1.3. It accepts a connection only from a peer
address in `allowedPeers`, and a request only with a `Host` value from
`allowedHosts`. It refuses requests with `Forwarded`, `X-Forwarded-*` or
`Cookie` headers with 400 `malformed-request`. A proxy between client and
manager therefore forwards the TCP bytes unchanged, so that TLS runs end to
end. Its address is in `allowedPeers`, and the host and port that the client
uses are in `allowedHosts`. The tested form is a local TCP forwarder of this
kind. No test exercises a proxy that terminates TLS.

When the proxy or the network fails:

1. The client reports the manager as unreachable. The TUI reconnects with a
   backoff of at most 30 seconds, and an event stream resumes from its last
   event identifier.
2. Read `status` on the manager host. `live` and `ready` `true` show that the
   manager serves, so the fault is between client and manager.
3. Read `GET /v1/capabilities` on the manager host directly, with a host in
   `allowedHosts`.
4. Treat each mutation whose reply was lost as uncertain, as in
   [Lost replies and uncertain mutations](#lost-replies-and-uncertain-mutations).

## Restoring an older backup

A restoration returns the Store to the state of the backup. The work after
the backup is absent from the restored Store: its requests and runs are not
listed, and an unknown request or run is refused as for any other unknown
identifier. The run directories of that work stay in the manager root as
observational evidence.

The effects of that work are uncertain. A restoration does not undo an
external effect, and it does not prove that an effect did not happen. The
restoration records this uncertainty in the Store. It rotates the authority
epoch, so an `Idempotency-Key` of the earlier epoch receives 409
`authority-changed`, and a client cannot complete an earlier attempt by a
repeat. Runs that the backup recorded as owned read `lost`, and their
uncertain starts and controls read `unresolved`. `status` counts them in
`lostRuns` and `unresolvedCommands`.

Procedure:

1. Before the restoration, list the work that the backup does not hold:
   compare `GET /v1/requests` and `GET /v1/runs` with the backup time.
2. Restore as in [Restore with fencing evidence](#restore-with-fencing-evidence).
3. Give each client its new credential, and ask it to reconcile: read the
   restored resources, compare them with its own record of what it sent, and
   create new requests for work that must run again. A new request needs a
   new exact approval.
4. Read `status` and resolve each lost run and each quarantined claim.

## Rollback to explicit local clients

A rollback stops the use of the manager and returns each user to the explicit
local mode of a client. The manager root stays on disk as read-only history.
A later roll forward serves the same root again. A rollback is a choice of
executable and client mode. It is not a data operation. The schema upgrade
of a newer executable is the data compatibility of the Store, and a
restoration from a backup is operator recovery. The rollback uses neither.

Preconditions: a manager serves through `SERVE_FILE`.

Procedure:

1. Drain the manager as in [Drain](#drain). New admission work refuses with
   `storage-unavailable`. Queued requests stay queued.
2. Let each owned run finish, or cancel it through its HTTP control as in
   [Cancel an owned run](#cancel-an-owned-run). Wait until `status` reports
   `activeReservations` 0 and `ownedWorkers` 0.
3. Shut down as in [Shut down](#shut-down), and confirm that the serve
   process exited with status 0.
4. Back up offline through `OFFLINE_FILE` as in
   [Back up offline](#back-up-offline). Keep the answer with the backup.
5. Record the type, size and modification time of every path of the
   manager root, for example with the macOS system `stat` in
   `find MANAGER_ROOT -exec stat -f '%N %HT %z %Fm' {} +`.
6. Start each client in its explicit local mode. The TUI starts with
   `RUNNER --tui --local`. It keeps its runs under its own state root in
   `XDG_STATE_HOME` and reads neither the manager root nor the configuration
   files. The Emacs client returns to local mode with `wf-local`. The Pi
   extension runs in local mode when neither `AGENT_CAT_MANAGER_PROFILE` nor
   `AGENT_CAT_MANAGER_PROFILES` is set.
7. Read the manager history read-only. `RUNNER flow MANAGER_ROOT/flow
   MANAGER_ROOT/runs/runs/RUN/runtime ...` verifies and prints the manager
   log and the run logs, as in [Manager log and run logs](#manager-log-and-run-logs).
   The verified result files that the clients saved stay readable. These reads
   and the local runs change no file of the manager root. Compare the record
   of step 5 to confirm it.

Offline `status` and every other offline operation of
`RUNNER --manager admin` open the Store and change the manager root, so the
record of step 5 no longer matches. Read offline `status` only after the
comparison of step 7.

Roll forward: start `RUNNER --manager serve --config SERVE_FILE` on the same
root. The manager prepares the reviews of the queued requests with no client
command. Each review then needs its exact approval as usual. A cancelled run
stays cancelled, and no command executes again.

Limits:

- No live ownership transfer. A local client does not adopt a run of the
  manager, and the manager does not adopt a local run. A run that a shutdown
  cancelled reads `lost` in the next lifetime, as
  [Shut down](#shut-down) states.
- No manifest rewrite. The rollback does not rewrite the supervisor manifests
  of the run stores or retarget their stored invocation records. The local
  runs of the clients stay in their own state roots and do not enter the
  manager history.
- No newer database opened by an older executable. An executable refuses a
  Store whose schema version is newer than its own: offline `status` refuses
  with `storage-unavailable`, and `RUNNER --manager serve` exits with status
  2. The Store has no downgrade operation.

The `rollback` mode of `manager/test/service_http.py` executes this
procedure with the packaged `bin/agentic-run` as the manager, the runner of
the profile, the local TUI and the flow verb. It completes one run and saves
its verified result, leaves one run at its person question and one request
in the queue, drains, cancels the waiting run, shuts down and backs up
offline. It then records the type, size and modification time of every path
of the manager root, runs `harden` to completion in `RUNNER --tui --local`
by keys with its own `XDG_CONFIG_HOME` and `XDG_STATE_HOME` while no manager
listens, and reads the history with `RUNNER flow` and the saved result. The
record must not change, no process of the manager may remain, and the
cancelled run must stay cancelled. Offline `status` follows, and the record
must detect its writes. The roll forward then serves the root, prepares the
review of the queued request before any command of the lifetime, and
completes its run after the approval. The manager log holds one enqueue
command of that request, one receipt for each command and one start relay
for each run. The local suites of the Emacs client (`ci/emacs.sh` of
agent-workflows-emacs-native) and of the Pi extension (`npm test` and
`npm run test:integration` of `ext-pi`) cover their local modes.

## The procedure exercise

Case 7 of the `operations` mode of `manager/test/service_http.py` executes
these procedures in the order of this runbook on one disposable fixture, the
manager root that cases 1 to 6 left. It uses only the documented interfaces:
`RUNNER --manager admin` with both configurations, the `/v1` routes and
`RUNNER flow`. Its request bodies are the bodies above.

| Step | Procedure | Interfaces and checks |
| --- | --- | --- |
| 7a | Diagnostics and offline validation | Two offline `status` answers with one authority epoch and stream and two process generations, offline `check-store` `valid`, `check-quarantine` of each listed identity, the `storage-unavailable` refusal of `SERVE_FILE` while no manager serves, and offline `reload-profiles`. |
| 7b | Start and live reload | `serve`, live `status` `serving`, live and ready, and live `reload-profiles` with a new revision. |
| 7c | Provisioning, rotation, revocation and listing | `issue-credential`, `rotate-credential` with both credentials accepted during the overlap, `revoke-credential` of the predecessor with 401 at once, `list-credentials`, and a refused rotation of the revoked credential with no file. |
| 7d | Drain, cancel and shutdown | A run at its question, `drain`, `status` live and not ready, the HTTPS cancel, `status` with no reservation and no owned worker, and `shutdown` with exit status 0. |
| 7e | Backup, restore and reprovisioning | Offline `status` saved as fencing evidence, offline `backup`, `restore`, every restored credential revoked, offline `issue-credential`, and offline `status` and `check-store` with the new identities. |
| 7f | Start after the restoration | The old credential receives 401, and the new credential reads the restored run. |
| 7g | Expired credentials | A credential with an expiry five seconds ahead receives 401, lists `expired`, and refuses rotation. |
| 7h | Lost replies | An exact repeat of an enqueue returns the original receipt, and `GET /v1/commands/COMMAND` reads it. |
| 7i | Older backup | An attempt with a key of the earlier epoch receives 409 `authority-changed`, and `status` reports the lost runs and unresolved commands of the restored Store. |
| 7j | Diagnostics | `RUNNER flow` verifies the manager logs and run logs and shows the administration commands of the seventh lifetime with one reply each, the fault-log lines have the `manager-fault` form, and `check-store` reports `valid`. |

The other cases and modes own these steps, and case 7 cites them and does not
repeat them:

| Procedure step | Owner |
| --- | --- |
| Refused reloads and the stale review after a reload | Case 1 of `operations`. |
| The drain of reviews, queued requests and running runs | Case 2 of `operations`. |
| The cleanup of a shutdown and the next lifetime | Case 3 of `operations`. |
| The content of a backup and `output-conflict` | Case 4 of `operations`. |
| A fencing mismatch and the restored history | Case 5 of `operations`. |
| The status facts | Case 6 of `operations`. |
| The rotation cutoff and revocation during retained responses | `credential-lifecycle`. |
| Seal, prune and cursors below the floor | `routes`. |
| Quarantine inspection and release after a manager loss | `failures-manager` and `failures-launched`. |
| An interrupted backup and the completion of an interrupted restoration | `failures-backup`. |
| The `storage-quota` endings and the recovery of a log that cannot open | `storage`. |
| A disk write failure under a file-size limit | `faults-io`. |
| An unreachable manager behind a TCP forwarder | `tui-failures`. |
| The rollback to explicit local clients and the roll forward | `rollback`. |

No mode exercises a Store that the quick check reports `corrupt`, a true
`ENOSPC`, or a proxy on another host.

The exercise of these procedures by another human operator against
disposable local fixtures, which WM-042 requires, is pending. Case 7 is an
automated exercise and does not stand for that review.
