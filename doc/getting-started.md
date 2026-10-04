# Getting started

This guide takes an operator from a checkout of agent-cat to daily use on one
macOS machine. It installs the runner `agentic-run`, runs workflows in local
mode, starts the workflow manager, and connects the terminal interface (TUI),
Pi and Emacs to it. The last sections add real engines and list the daily
operator commands.

Follow the sections in order, and type each command as it is written. Each
step states the exit status that it gives. A step marked **Operator login**
contacts a paid provider. It needs the login of the operator and can incur
cost.

## Prerequisites

- macOS with Nix, with the `nix-command` and `flakes` features enabled.
- `python3` and `openssl` on `PATH`. macOS supplies both in `/usr/bin`. The
  stub adapter is a `python3` script, and `--manager init` uses `openssl` to
  make the certificate of the manager.
- A checkout of this repository. The commands of section 1 run in the root of
  that checkout. All other commands run in any directory.
- For the Pi client of section 4 only: Node 22 on `PATH`, the built Pi fork at
  version 1.0.1, and the `ext-pi/node_modules` directory that links the fork.
  The section [Install and start](../ext-pi/README.md#install-and-start) of
  `ext-pi/README.md` states these prerequisites.
- For the Emacs client of section 4 only: GNU Emacs and a checkout of the
  branch `emacs-native` of the agent-workflows repository, which holds the
  service client `emacs/wf-service.el`.

## 1. Install the runner

Install the runner into the Nix profile of the account:

```sh
nix profile add .#agentic-run
agentic-run --version
```

Both commands exit 0, and the second prints `agentic-run 0.1.0.0`. The Nix
installer puts `~/.nix-profile/bin` on `PATH`, and `agentic-run` is there.
The first build compiles the runner and can take several minutes. Nix
releases that have no `nix profile add` command give the same command the
name `nix profile install`. After a change of the checkout, for example after
`git pull`, run `nix profile upgrade agentic-run` to install the new build.

To build the runner without an installation, run `nix build` and put the
`result/bin` directory of the checkout on `PATH`:

```sh
nix build .#agentic-run
export PATH="$PWD/result/bin:$PATH"
```

To run one command with no installation and no change of `PATH`, put the
arguments of the runner after `--`:

```sh
nix run .#agentic-run -- list
```

Each of these commands exits 0. The rest of this guide uses the installed
`agentic-run`. The section "Building and verifying" of
[`README.md`](../README.md#building-and-verifying) states the maintainer
route, which builds with Cabal in the development shell.

## 2. A first local run

Local mode runs a workflow in the foreground of one command. It needs no
manager. Each command below exits 0.

```sh
agentic-run list
agentic-run help hello
agentic-run plan hello
```

`list` prints the registered workflows with one line each. `help hello`
prints the help page of the `hello` workflow. `plan hello` prints its static
analysis: the level `pipeline`, three asks and a cost of 3 requests on one
path. None of these commands starts an adapter or asks a question.

```sh
agentic-run run hello --scripted
agentic-run run harden --scripted
```

`--scripted` answers every question from a table of fixed replies that is
registered beside the workflow. It contacts no model, no tool and no person.
The run prints each question and its answer, and it ends with `the run is
over.`, the answer of the workflow and the two bills `billFresh` and
`billMemo`. `harden`
is the flagship workflow: a panel of three reviewers, a bounded revision and
the consent of the owner.

```sh
agentic-run run hello --engine acp --adapter stub
```

`--engine acp` starts an adapter process and speaks the Agent Client Protocol
to it. The `stub` adapter is a deterministic local script that the package
installs. It answers each question with fixed text and reaches no network.
This run therefore exercises the complete live path at no cost.

A run with no `--scripted`, `--engine` or `--session` uses the routing file,
which section 5 describes. Such a run needs a fully pinned workflow, so
`agentic-run run hello` exits 1. Its message names the model question without
a pin and suggests `--scripted`.

### The local terminal interface

```sh
agentic-run --tui
```

The TUI opens on the Workflows list. `Up` and `Down` select a workflow, and
`Enter` opens it. To run `hello`:

1. Press `Down` once to select `hello`, and press `Enter`. A workflow with
   inputs first opens an editor for each input, where `Ctrl-D` accepts the
   value, and `hello` has no inputs.
2. The target screen then opens. `s` selects the scripted replies, and `l` or
   `Enter` selects the routing file of section 5. Press `s`.
3. The review shows the workflow, the target, the request range and the
   effects. Press `y` or `Enter` to start the run. `n` or `Esc` returns.
4. The live monitor shows each request and its answer. When the run ends,
   the header shows `Succeeded`. `r` shows the verified result. `s` opens a
   prompt for a new absolute path, and `Ctrl-D` saves a copy of the result
   there.
5. Press `Esc` to return to the browser, where the Runs section lists the
   run. Press `q` to quit. The TUI exits with status 0.

`?` lists the keys of the current screen. The TUI keeps its runs in
`~/.local/state/agent-cat/tui`, and the Runs section lists them after a
restart.

## 3. Start the workflow manager

The workflow manager is a local HTTPS service. It keeps requests, reviews,
runs and results in a store, runs each approved request as a worker process,
and serves the TUI, Pi and Emacs clients. One command creates its root
directory:

```sh
agentic-run --manager init --root "$HOME/agent-cat-manager"
```

The command exits 0. The root must not exist, or it must be empty. The
command writes these files and prints the commands that use them:

- `serve.json` and `offline.json`, the two configuration files of the
  manager. `serve.json` names the administration socket, and the commands of
  a serving manager use it. `offline.json` is for administration while no
  manager serves.
- `tls/certificate.pem` and `tls/key.pem`, a self-signed certificate for
  `127.0.0.1`.
- `client/profile.json` and `client/profile.credential`, the client profile
  and its credential. The TUI, Pi and Emacs connect with this profile.
- `bin/agentic-run`, a link to the runner that ran `init`. The manager runs
  each workflow with it.

The manager listens on `127.0.0.1` port 8443. To use another port, add
`--port PORT` to `init`.

The root holds two profiles. A profile names the runner, the execution target
and the workspace of the runs that it admits:

- `scripted` runs each workflow with `--scripted`. It reaches no model.
- `person` runs each workflow with the stub adapter, and a person answers
  the questions to the model `namer` through the manager. In `hello`, that
  question asks for something to greet.

Start the manager in a second terminal. It stays in the foreground:

```sh
agentic-run --manager serve --config "$HOME/agent-cat-manager/serve.json" 2>>"$HOME/agent-cat-manager/manager-faults.log"
```

When the manager listens, it prints one line:

```text
manager listening on https://127.0.0.1:8443/v1
```

Standard error is the private fault log of the manager, and the redirection
keeps it in `manager-faults.log`. The manager runs until a `shutdown`
request, as section 6 states.

Ask the manager for its status from the first terminal:

```sh
printf '%s' '{"version": 1, "operation": "status"}' | agentic-run --manager admin --config "$HOME/agent-cat-manager/serve.json"
```

The command exits 0 and prints one JSON line. A serving manager that admits
work reports `"state":"serving"`, `"live":true` and `"ready":true`.

## 4. Connect the clients

### The TUI

```sh
agentic-run --tui --service "$HOME/agent-cat-manager/client/profile.json"
```

The TUI opens on the Manager profiles list, with the endpoint
`127.0.0.1:8443` in its header. To run `hello` through the manager:

1. Select `scripted` with `Up` and `Down`, and press `Enter`. The Manager
   workflows list opens.
2. Select `hello`, and press `Enter`. The request screen opens with the
   phase `draft`.
3. Press `Enter` to request the review. The manager prepares the exact
   review, and the TUI shows `Approve exact manager review`. `d` shows its
   details, and `Esc` returns.
4. Press `y` to approve the review and start the run. Only `y` approves.
   `Enter` does not approve, and `X` discards the review.
5. The live monitor shows each request. When the run ends, it shows
   `Terminal: succeeded` and `Result: verified`.
6. Press `s`, type the path of a new file, for example
   `/Users/NAME/hello-result.json`, and press `Ctrl-D`. The TUI writes the
   verified result bytes to that file with mode 0600.
7. Press `q`. The TUI detaches and exits with status 0. The manager keeps the run, and
   `H` in the workflow browser lists it in History.

`X` on the review opens the dialog `Confirm discard`. `y` discards the
review, and `n`, `q` or `Esc` closes the dialog and sends nothing. A review
that is not approved or discarded stays open at the manager and holds an
execution reservation of its profile. `O` in the workflow browser opens the
Manager overview, which lists the open requests and reviews. Select the
request, and press `Enter` to open its review again.

To answer a question as the person, select the profile `person` instead of
`scripted` in step 1, and follow steps 2 to 4. The live monitor then opens
the `Your answer` editor with the question `Name one thing worth greeting.`
Type the answer, for example `the world`, and press `Ctrl-D` to send it.
`Enter` in the editor inserts a new line. The run then continues and ends as
in step 5. A run that waits for an answer holds its profile, and a later
request of the same profile waits in the queue until that run ends. `D` in
the workflow browser lists every pending question of the manager, and
`Enter` opens the run of the selected question.

`?` lists the keys of each screen. [`tui/README.md`](../tui/README.md)
describes the TUI in full.

### Pi

The Pi extension connects the Pi coding agent to the manager. The section
[Install and start](../ext-pi/README.md#install-and-start) of
`ext-pi/README.md` starts Pi with the extension. Its subsection "First
service run" sets `AGENT_CAT_MANAGER_PROFILE` to the client profile of
section 3 and runs `hello` with `/wfm hello`.

### Emacs

The Emacs client is part of the separate agent-workflows repository. Its
service client, `emacs/wf-service.el`, is on the branch `emacs-native` of that
repository. The branch `main` does not have it. On this machine the worktree
`~/src/agent-workflows-emacs-native` holds that branch, so the `load-path` of
the client is `~/src/agent-workflows-emacs-native/emacs`. The section "Using
service mode" of the `README.md` of that worktree loads the client, names the
client profile of section 3 in `wf-manager-profiles`, and runs a workflow
with `M-x wf-service` and `M-x wf-run`.

## 5. Real engines

A real engine is an ACP adapter that a provider supplies. The runner knows
three of them: `claude` (the program `claude-agent-acp`), `codex` (the
program `codex-acp`) and `droid` (the Droid command line, `droid`).

### Install and log in

**Operator login.** Install the adapter so that it is on `PATH`. From the
root of the checkout, these commands install the builds of the Nix package
set that the flake pins:

```sh
nix profile add --inputs-from . nixpkgs#claude-agent-acp
nix profile add --inputs-from . nixpkgs#codex-acp
```

Each adapter uses the login of its provider. Log in to Claude Code for
`claude-agent-acp` and to the Codex command line for `codex-acp`, as the
provider documents. Droid needs a local login or the variable
`FACTORY_API_KEY`. Never put a credential in a command line or in a routing
file.

### Choose a model

**Operator login.** List the model and effort values that an adapter offers,
and run a workflow with one of them:

```sh
agentic-run adapter-options --adapter claude
agentic-run run hello --engine acp --adapter claude --model ID --effort LEVEL
```

`adapter-options` starts the adapter, opens one session, prints the offered
values and exits 0. It sends no prompt. `--model` and `--effort` set the
model and the effort of every session before its prompt. A value that the
adapter does not offer stops the run before any prompt with exit status 2.
The message names the adapter, for example `adapter 'stub'`, and lists the
offered values. Without the two options, the
adapter uses its own defaults.

The stub adapter offers model and effort values too, so this form of the
command can be tried at no cost:

```sh
agentic-run adapter-options --adapter stub
```

### The routing file

A run with no `--scripted`, `--engine` or `--session` takes its engines and
models from the routing file `~/.config/agent-cat/routing.yaml`. The file
`cli/model-definitions.example.yaml` of the checkout is a minimal working
routing file. From the root of the checkout, install it and check it:

```sh
mkdir -p ~/.config/agent-cat
cp cli/model-definitions.example.yaml ~/.config/agent-cat/routing.yaml
agentic-run --routing
```

`--routing` exits 0 and prints the resolved policy. The file defines one
engine for each built-in adapter and one persona for each engine. The default
persona `stub` uses the stub adapter. `--persona NAME` or the variable
`AGENT_CAT_PERSONA` selects another persona. Replace the model identifiers of
the `claude`, `codex` and `droid` models with values that `adapter-options`
lists.

A run that uses only the routing file needs a fully pinned workflow. Every
model question of the workflow names its serving profile with `servedBy`,
and the workflow asks no tool or person question. None of the bundled
workflows meets this rule, so a bundled workflow runs with `--engine acp` or
`--session`. [`doc/model-routing-v2.md`](model-routing-v2.md) states the
complete routing contract.

### A manager profile for a real engine

**Operator login.** A worker of the manager inherits no environment. Its
environment is exactly the `environment` list of its profile. A profile for
a real engine therefore binds `PATH` to the directories of the adapter,
`HOME` to the home directory where the adapter keeps its login, and
`XDG_CONFIG_HOME` to the configuration directory. Add this profile to the
`profiles` list of both `serve.json` and `offline.json`, with `NAME` replaced
by the account name:

```json
{
  "id": "claude",
  "runner": "native",
  "workspace": "/Users/NAME/agent-cat-manager/workspace",
  "workspaceLabel": "Local workspace",
  "targetLabel": "Claude through ACP",
  "targetArguments": ["--engine", "acp", "--adapter", "claude"],
  "environment": [
    {"name": "PATH", "value": "/Users/NAME/.nix-profile/bin:/usr/bin:/bin"},
    {"name": "HOME", "value": "/Users/NAME"},
    {"name": "XDG_CONFIG_HOME", "value": "/Users/NAME/.config"}
  ],
  "ownership": "service-owned",
  "quarantined": false,
  "personAnswering": "local-control",
  "resourceKeys": []
}
```

`targetArguments` also accepts `--model ID` and `--effort LEVEL`. Load the
profile with `reload-profiles` and give a client a credential that names it
with `add-client --profile claude`, as section 6 states.
[`manager/CONFIGURATION.md`](../manager/CONFIGURATION.md#a-profile-for-a-real-engine)
also shows a profile that routes through the routing file.

## 6. Daily operator commands

Every administration request is one JSON line on standard input of
`agentic-run --manager admin --config FILE`. The answer is one JSON line on
standard output. The command exits 0 when the answer has `"ok":true` and 1
when it has `"ok":false`. While the manager serves, `FILE` is `serve.json`.
While no manager serves, `FILE` is `offline.json`.
[`manager/OPERATIONS.md`](../manager/OPERATIONS.md) is the complete runbook.

### Status and the store check

```sh
printf '%s' '{"version": 1, "operation": "status"}' | agentic-run --manager admin --config "$HOME/agent-cat-manager/serve.json"
printf '%s' '{"version": 1, "operation": "check-store"}' | agentic-run --manager admin --config "$HOME/agent-cat-manager/serve.json"
```

Both commands exit 0. `check-store` reports `"integrity":"valid"` for a
sound store.

### Clients and credentials

`add-client` issues a credential and writes a further client profile, for
example for a second client. The directory of the profile must exist and be
private. `mkdir -p` also exits 0 when the directory exists:

```sh
mkdir -p -m 700 "$HOME/agent-cat-clients"
agentic-run --manager add-client --config "$HOME/agent-cat-manager/serve.json" --profile-file "$HOME/agent-cat-clients/laptop.json" --profile person
```

The command exits 0, writes `laptop.json` and `laptop.credential`, and prints
the commands that connect the TUI, Pi and Emacs with the new profile. Without
`--profile`, the credential covers every profile of the manager.

`issue-credential` issues a credential with chosen scopes and writes only the
credential file. This request issues a credential that can only observe the
runs of the profile `scripted`:

```sh
printf '{"version": 1, "operation": "issue-credential", "label": "observer", "scopes": ["observe"], "profileIds": ["scripted"], "expiresAt": "2999-01-01T00:00:00Z", "outputFile": "%s"}' "$HOME/agent-cat-clients/observer.credential" | agentic-run --manager admin --config "$HOME/agent-cat-manager/serve.json"
```

The command exits 0. The scopes are a subset of `observe`, `submit`,
`control` and `export`.

A client uses a credential file through a client profile. This command writes
the profile `observer.json` beside the credential, with mode 0600:

```sh
(umask 077 && printf '{"version": 1, "endpoint": "https://127.0.0.1:8443/v1", "credentialFile": "%s", "caFile": "%s"}\n' "$HOME/agent-cat-clients/observer.credential" "$HOME/agent-cat-manager/tls/certificate.pem" > "$HOME/agent-cat-clients/observer.json")
```

The command exits 0. `agentic-run --tui --service
"$HOME/agent-cat-clients/observer.json"` then connects with the observer
credential. It shows the workflows and the runs of `scripted`. A key that
submits or controls work, for example `Enter` on a workflow, shows a
numbered refusal such as `Key 1: create did not start: this credential lacks
submit.` and sends nothing. The section
[Provision a client](../manager/OPERATIONS.md#provision-a-client) of
`manager/OPERATIONS.md` states the format of the profile.

### Reload the profiles

After a change of the profiles in `serve.json` and `offline.json`, load them
into the serving manager:

```sh
printf '%s' '{"version": 1, "operation": "reload-profiles"}' | agentic-run --manager admin --config "$HOME/agent-cat-manager/serve.json"
```

The command exits 0 and lists the profile identifiers. A credential covers
only the profiles that it names. After a profile is added, issue a new
credential that names it, for example with `add-client --profile NEW_ID`.

### The manager log and the fault log

The manager records every request, command and receipt in its manager log
below `manager/flow`, and each run keeps its own run log below
`manager/runs/runs`. `flow` reads both and verifies them against each other:

```sh
agentic-run flow "$HOME/agent-cat-manager/manager/flow" "$HOME/agent-cat-manager/manager/runs/runs/"*/runtime
```

The command prints one JSON object for each record and a summary object. The
summary has `"verified":true` when every verification passes. The command then
exits 0 after a `shutdown`. While the manager serves, its current lifetime has
no shutdown notice yet, and the command exits 2 with `"verified":true`. Exit
status 1 means that a verification failed.

The fault log is the standard error of the serve process, which section 3
redirects to `manager-faults.log` in the manager root. Each line starts with
`manager-fault`. A line about `/v1/events` after a client quits needs no
action. [`manager/OPERATIONS.md`](../manager/OPERATIONS.md#private-fault-log)
lists the lines that need action.

### Drain and shut down

`drain` stops the admission of new work. Started runs continue:

```sh
printf '%s' '{"version": 1, "operation": "drain"}' | agentic-run --manager admin --config "$HOME/agent-cat-manager/serve.json"
```

The command exits 0, and `status` then reports `"state":"draining"`. Wait
until `status` reports `"activeReservations":0`, and then shut the manager
down:

```sh
printf '%s' '{"version": 1, "operation": "shutdown"}' | agentic-run --manager admin --config "$HOME/agent-cat-manager/serve.json"
```

The command exits 0, and the serve process exits with status 0. To start
the manager again, run the `serve` command of section 3.

### Back up the store

A backup runs while no manager serves, through `offline.json`. The
destination must not exist, and its directory must be private:

```sh
printf '%s' '{"version": 1, "operation": "status"}' | agentic-run --manager admin --config "$HOME/agent-cat-manager/offline.json"
mkdir -p -m 700 "$HOME/agent-cat-backups"
printf '{"version": 1, "operation": "backup", "outputFile": "%s"}' "$HOME/agent-cat-backups/backup-1" | agentic-run --manager admin --config "$HOME/agent-cat-manager/offline.json"
```

Each command exits 0. The offline `status` reports `"state":"stopped"`. The
backup answer holds `backupId`, `sha256` and `bytes`. Keep the answer with the
backup. [`manager/OPERATIONS.md`](../manager/OPERATIONS.md#offline-backup-and-restore)
states the restoration.

### After an upgrade of the runner

`bin/agentic-run` in the manager root is a link to the build that ran
`init`, and the manager runs every workflow with that build. After
`nix profile upgrade agentic-run`, stop the manager, point the link at the
new build, and start the manager again:

```sh
ln -sfn "$(readlink -f "$(command -v agentic-run)")" "$HOME/agent-cat-manager/bin/agentic-run"
```

The command exits 0.
