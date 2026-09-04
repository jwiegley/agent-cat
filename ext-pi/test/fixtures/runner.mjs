#!/usr/bin/env node
import readline from "node:readline";
import { createReadStream, mkdirSync } from "node:fs";

const args = process.argv.slice(2);
const descriptorMode = args[0]?.startsWith("--descriptor-") ? args.shift() : "--descriptor-v2";
const descriptorInputs = {
  "--descriptor-v1": ["subject"],
  "--descriptor-v2": [{ name: "subject", source: "prompt" }],
  "--descriptor-v3": [{ name: "subject", source: "prompt" }],
  "--descriptor-v3-v1-routing": [{ name: "subject", source: "prompt" }],
  "--descriptor-v3-unsafe": [{ name: "subject", source: "prompt" }],
  "--descriptor-sources": [{ name: "args", source: "command-tail" }, { name: "input", source: "stdin" }, { name: "tone", source: "prompt" }],
  "--descriptor-stdin": [{ name: "subject", source: "stdin" }],
  "--descriptor-stdin-no-control": [{ name: "subject", source: "stdin" }],
  "--descriptor-bad-source": [{ name: "subject", source: "guessed" }],
  "--descriptor-duplicate": [{ name: "subject", source: "prompt" }, { name: "subject", source: "stdin" }],
  "--descriptor-multi-stdin": [{ name: "left", source: "stdin" }, { name: "right", source: "stdin" }],
}[descriptorMode];
const descriptor = {
  descriptorVersion: descriptorMode === "--descriptor-v1" ? 1 : descriptorMode.startsWith("--descriptor-v3") ? 3 : 2,
  runnerVersion: "fixture-1",
  protocolVersions: [1],
  storeVersions: [1],
  capabilities: {
    structuredRun: true, wholeRunCancel: true, requestControls: false, semanticResume: false,
    consults: 1, observes: 0, effects: 0, effectful: false, toolExecution: false,
    ...(["--descriptor-v1", "--descriptor-stdin-no-control"].includes(descriptorMode) ? {} : { controlFd: 3 }),
    ...(descriptorMode.startsWith("--descriptor-v3") ? {
      protocolNegotiation: true, routingInspection: true, routingJsonVersion: 2,
      personaRouting: true, modelAliasRouting: true,
    } : {}),
  },
  name: descriptorMode === "--descriptor-sources" ? "review" : "fixture",
  blurb: "fixture workflow",
  level: "batch",
  size: 2,
  askNodes: 1,
  minFold: 1,
  maxFold: 1,
  paths: 1,
  inputs: descriptorInputs,
  runFacts: [],
  pins: ["worker"],
};

const controlInput = () => process.env.AGENT_CAT_CONTROL_FD === "3"
  ? createReadStream("", { fd: 3, autoClose: false })
  : process.stdin;

if (args[0] === "--routing" && args[1] === "--json") {
  const personaIndex = args.indexOf("--persona");
  const persona = personaIndex >= 0 ? args[personaIndex + 1] : "personal";
  const alias = persona === "work" ? "work-model" : "personal-model";
  const value = descriptorMode === "--descriptor-v3-v1-routing"
    ? { version: 1, profiles: [{ options: { url: "opaque-v1-option" } }] }
    : {
    version: 2,
    persona: { name: persona, source: personaIndex >= 0 ? "command-line" : "user-default" },
    availablePersonas: ["personal", "work"],
    availableModels: persona === "work"
      ? [{ alias: "work-model", engine: "work-engine" }]
      : [{ alias: "personal-model", engine: "personal-engine" }, { alias: "shared-model", engine: "personal-engine" }],
    profiles: [{ name: "worker", rungs: [{ axis: "worker", modelAlias: alias, model: `${alias}-exact` }] }],
    warnings: [],
    engines: [], models: [], sources: [],
  };
  if (descriptorMode === "--descriptor-v3-unsafe") value.secrets = { leaked: "sentinel" };
  console.log(JSON.stringify(value));
} else if (args[0] === "list" && args[1] === "--json") {
  console.log(JSON.stringify([descriptor]));
} else if (args[0] === "help") {
  process.stdout.write("exact fixture help\n");
} else if (args[0] === "plan") {
  if (process.env.FIXTURE_PLAN_FAIL === "1") { process.stderr.write("plan failed\n"); process.exitCode = 3; }
  else console.log(JSON.stringify({ ...descriptor, codes: ["text"], fold: [{ consults: 1, paths: 1 }], program: { main: { fixture: true }, fns: [] } }));
} else if (args[0] === "lineage-check") {
  if (process.env.FIXTURE_LINEAGE_REFUSE === "1") {
    process.stderr.write("lineage mismatch\n");
    process.exitCode = 3;
  } else process.exitCode = 0;
} else if (args[0] === "machine" || args[0] === "machine-restart" || args[0] === "machine-resume" || args[0] === "machine-fork") {
  if (process.env.AGENT_CAT_RUN_STORE) mkdirSync(process.env.AGENT_CAT_RUN_STORE, { recursive: true, mode: 0o700 });
  const runId = args[1];
  let seq = 0;
  const emit = (event) => console.log(JSON.stringify({ protocolVersion: 1, runId, sequence: String(seq++), timestamp: new Date().toISOString(), event }));
  if (process.env.FIXTURE_SECRET) process.stderr.write(`Authorization: Bearer ${process.env.FIXTURE_SECRET}\ntoken=${process.env.FIXTURE_SECRET}\n`);
  if (process.env.FIXTURE_STDERR_BYTES) process.stderr.write("x".repeat(Number(process.env.FIXTURE_STDERR_BYTES)));
  emit({ type: "run.started", workflow: descriptor.name, target: "scripted" });
  if (process.env.FIXTURE_HANG === "1") {
    emit({ type: "occurrence.started", occurrenceId: "0", code: "text", intent: "consult", addressee: "model", prompt: "subject" });
    emit({ type: "attempt.started", occurrenceId: "0", attempt: "0", target: "scripted" });
    const rl = readline.createInterface({ input: controlInput() });
    rl.on("line", (line) => {
      const control = JSON.parse(line);
      if (control.command.type === "steerOccurrence") {
        if (process.env.FIXTURE_CONTROL_STATE) {
          emit({ type: "control.ack", controlId: control.controlId, state: process.env.FIXTURE_CONTROL_STATE, message: "target rejected control" });
        } else {
          emit({ type: "control.ack", controlId: control.controlId, state: "accepted", message: "steer accepted" });
          emit({ type: "attempt.steered", occurrenceId: "0", attempt: "0", controlId: control.controlId, timing: control.command.timing, text: control.command.text });
          emit({ type: "control.ack", controlId: control.controlId, state: "delivered", message: "steer delivered" });
        }
      } else {
        emit({ type: "control.ack", controlId: control.controlId, state: "accepted", message: "cancellation accepted" });
        emit({ type: "run.cancelled", message: "cancelled" });
        rl.close();
        process.exit(130);
      }
    });
  } else if (process.env.FIXTURE_REDIRECT === "1") {
    emit({ type: "occurrence.started", occurrenceId: "0", code: "text", intent: "consult", addressee: "model", prompt: "subject" });
    emit({ type: "occurrence.dispatch-pending", occurrenceId: "0", targets: ["model@primary", "model@spare"] });
    const rl = readline.createInterface({ input: controlInput() });
    rl.once("line", (line) => {
      const control = JSON.parse(line);
      emit({ type: "control.ack", controlId: control.controlId, state: "accepted", message: "redirect accepted" });
      emit({ type: "occurrence.redirected", occurrenceId: "0", controlId: control.controlId, target: control.command.target });
      emit({ type: "control.ack", controlId: control.controlId, state: "delivered", message: "redirect delivered" });
      emit({ type: "attempt.started", occurrenceId: "0", attempt: "0", target: control.command.target });
      emit({ type: "attempt.completed", occurrenceId: "0", attempt: "0", source: control.command.target });
      emit({ type: "occurrence.completed", occurrenceId: "0", source: `asked:${control.command.target}`, answer: "done" });
      emit({ type: "trace.ordered", occurrenceIds: ["0"] });
      emit({ type: "run.completed", billFresh: "1", billMemo: "1" });
      rl.close();
      process.exit(0);
    });
  } else if (process.env.FIXTURE_RECOVER === "1") {
    emit({ type: "occurrence.started", occurrenceId: "0", code: "text", intent: "consult", addressee: "model", prompt: "subject" });
    emit({ type: "attempt.started", occurrenceId: "0", attempt: "0", target: "model@primary" });
    emit({ type: "attempt.failed", occurrenceId: "0", attempt: "0", failure: "decode", message: "unreadable" });
    const recoveryChoices = process.env.FIXTURE_NO_FAILOVER === "1" ? [{ choice: "retry" }, { choice: "abandon" }] : [{ choice: "retry" }, { choice: "failover", target: "model@spare" }, { choice: "abandon" }];
    emit({ type: "occurrence.recovery-pending", occurrenceId: "0", gap: "decode", message: "unreadable", choices: recoveryChoices });
    const rl = readline.createInterface({ input: controlInput() });
    rl.once("line", (line) => {
      const control = JSON.parse(line);
      const choice = control.command.type === "failoverOccurrence" ? "failover" : control.command.type === "abandonOccurrence" ? "abandon" : "retry";
      emit({ type: "control.ack", controlId: control.controlId, state: "accepted", message: "recovery accepted" });
      emit({ type: "occurrence.recovery-chosen", occurrenceId: "0", controlId: control.controlId, choice, ...(choice === "failover" ? { target: "model@spare" } : {}) });
      if (choice !== "abandon") emit({ type: "occurrence.retried", occurrenceId: "0", controlId: control.controlId });
      emit({ type: "control.ack", controlId: control.controlId, state: "delivered", message: "recovery delivered" });
      if (choice === "abandon") {
        emit({ type: "occurrence.failed", occurrenceId: "0", failure: "decode", message: "abandoned" });
        emit({ type: "run.failed", failure: "decode", message: "abandoned" });
      } else {
        const target = choice === "failover" ? "model@spare" : "scripted";
        emit({ type: "attempt.started", occurrenceId: "0", attempt: "1", target });
        emit({ type: "attempt.completed", occurrenceId: "0", attempt: "1", source: target });
        emit({ type: "occurrence.completed", occurrenceId: "0", source: `asked:${target}`, answer: "done" });
        emit({ type: "trace.ordered", occurrenceIds: ["0"] });
        emit({ type: "run.completed", billFresh: "1", billMemo: "1" });
      }
      rl.close();
      process.exit(0);
    });
  } else {
    emit({ type: "occurrence.started", occurrenceId: "0", code: "text", intent: "consult", addressee: "model", prompt: "subject" });
    emit({ type: "attempt.started", occurrenceId: "0", attempt: "0", target: "scripted" });
    emit({ type: "attempt.completed", occurrenceId: "0", attempt: "0", source: "scripted" });
    emit({ type: "occurrence.completed", occurrenceId: "0", source: "asked:model", answer: "done" });
    emit({ type: "trace.ordered", occurrenceIds: ["0"] });
    emit({ type: "run.completed", billFresh: "1", billMemo: "1" });
  }
} else {
  process.stderr.write(`unexpected args: ${JSON.stringify(args)}\n`);
  process.exitCode = 1;
}
