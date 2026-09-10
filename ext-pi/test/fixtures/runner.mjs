#!/usr/bin/env node
import readline from "node:readline";
import { createHash } from "node:crypto";
import { createReadStream, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const args = process.argv.slice(2);
let descriptorMode = args[0]?.startsWith("--descriptor-") ? args.shift() : "--descriptor-v2";
if (descriptorMode === "--descriptor-v2" && args[0] === "list" && args.includes("--descriptor-version")) {
  descriptorMode = "--descriptor-v3-auto";
}
if (descriptorMode === "--descriptor-v3-error" && args.includes("--descriptor-version")) {
  process.stderr.write("descriptor catalogue crashed\n");
  process.exit(2);
}
if (descriptorMode === "--descriptor-legacy-reject-v3" && args.includes("--descriptor-version")) {
  process.stderr.write("unknown option --descriptor-version\n");
  process.exit(1);
}
const descriptorInputs = {
  "--descriptor-v1": ["subject"],
  "--descriptor-legacy-reject-v3": ["subject"],
  "--descriptor-v3-error": ["subject"],
  "--descriptor-v2": [{ name: "subject", source: "prompt" }],
  "--descriptor-v3-v1-routing": [{ name: "subject", source: "prompt" }],
  "--descriptor-v3": [{ name: "subject", source: "prompt" }],
  "--descriptor-v3-auto": [{ name: "subject", source: "prompt" }],
  "--descriptor-v3-unsafe": [{ name: "subject", source: "prompt" }],
  "--descriptor-v3-unsafe-case": [{ name: "subject", source: "prompt" }],
  "--descriptor-v3-unsafe-url": [{ name: "subject", source: "prompt" }],
  "--descriptor-sources": [{ name: "args", source: "command-tail" }, { name: "input", source: "stdin" }, { name: "tone", source: "prompt" }],
  "--descriptor-stdin": [{ name: "subject", source: "stdin" }],
  "--descriptor-v3-stdin": [{ name: "subject", source: "stdin" }],
  "--descriptor-stdin-no-control": [{ name: "subject", source: "stdin" }],
  "--descriptor-bad-source": [{ name: "subject", source: "guessed" }],
  "--descriptor-duplicate": [{ name: "subject", source: "prompt" }, { name: "subject", source: "stdin" }],
  "--descriptor-multi-stdin": [{ name: "left", source: "stdin" }, { name: "right", source: "stdin" }],
}[descriptorMode];
const descriptor = {
  descriptorVersion: ["--descriptor-v1", "--descriptor-legacy-reject-v3"].includes(descriptorMode) ? 1 : descriptorMode.startsWith("--descriptor-v3") ? 3 : 2,
  runnerVersion: "fixture-1",
  protocolVersions: descriptorMode.startsWith("--descriptor-v3") ? [1, 2] : [1],
  storeVersions: descriptorMode.startsWith("--descriptor-v3") ? [1, 2] : [1],
  capabilities: {
    structuredRun: true, wholeRunCancel: true, requestControls: false, semanticResume: false,
    consults: 1, observes: 0, effects: 0, effectful: false, toolExecution: false,
    ...(["--descriptor-v1", "--descriptor-legacy-reject-v3", "--descriptor-stdin-no-control"].includes(descriptorMode) ? {} : { controlFd: 3 }),
    ...(["--descriptor-v3", "--descriptor-v3-v1-routing", "--descriptor-v3-unsafe", "--descriptor-v3-unsafe-case", "--descriptor-v3-unsafe-url"].includes(descriptorMode) ? {
      protocolNegotiation: true, routingInspection: true, routingJsonVersion: 2,
      personaRouting: true, modelAliasRouting: true,
    } : {}),
  },
  name: descriptorMode === "--descriptor-sources" ? "review" : "fixture",
  blurb: "fixture workflow",
  ...(["--descriptor-v1", "--descriptor-legacy-reject-v3"].includes(descriptorMode) ? {} : { result: "receipt" }),
  level: "batch",
  size: 2,
  askNodes: 1,
  minFold: 1,
  maxFold: 1,
  paths: 1,
  inputs: descriptorInputs,
  runFacts: [],
  pins: ["worker"],
  ...(descriptorMode.startsWith("--descriptor-v3") ? { personAnsweringModes: ["local-control"] } : {}),
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
    launch: { targetKind: "routing", arguments: ["--routing"], fingerprint: "f".repeat(64) },
    availablePersonas: ["personal", "work"],
    availableModels: persona === "work"
      ? [{ alias: "work-model", engine: "work-engine" }]
      : [{ alias: "personal-model", engine: "personal-engine" }, { alias: "shared-model", engine: "personal-engine" }],
    profiles: [{ name: "worker", rungs: [{ axis: "worker", modelAlias: alias, model: `${alias}-exact` }] }],
    warnings: [],
    engines: [], models: [], sources: [],
  };
  if (descriptorMode === "--descriptor-v3-unsafe") value.secrets = { leaked: "sentinel" };
  if (descriptorMode === "--descriptor-v3-unsafe-case") value.api_Key = "sentinel";
  if (descriptorMode === "--descriptor-v3-unsafe-url") value.endpointUrl = "https://private.invalid";
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
  const protocolIndex = args.indexOf("--protocol-version");
  const protocolVersion = protocolIndex >= 0 ? Number(args[protocolIndex + 1]) : 1;
  let seq = 0;
  const emit = (event) => console.log(JSON.stringify({ protocolVersion, runId, sequence: String(seq++), timestamp: new Date().toISOString(), event }));
  const acknowledge = (control, state, message) => emit({
    type: "control.ack", controlId: control.controlId, state, message,
    ...(protocolVersion === 2 ? {
      command: process.env.FIXTURE_BAD_CONTROL_CORRELATION === "1" && state === "delivered" ? "cancelRun" : control.command.type,
      occurrenceId: control.expectedOccurrenceId, attemptId: control.expectedAttemptId,
    } : {}),
  });
  const completed = () => {
    const value = process.env.FIXTURE_LARGE_INTEGER_RESULT === "1" ? "9007199254740993" : JSON.stringify("done");
    const noncanonical = process.env.FIXTURE_NONCANONICAL_RESULT;
    const version = noncanonical === "version" ? "1e0" : "1";
    const runIdJson = noncanonical === "run-id"
      ? `"\\u${runId.charCodeAt(0).toString(16).padStart(4, "0")}${runId.slice(1)}"`
      : JSON.stringify(runId);
    const codeJson = noncanonical === "code" ? '"\\u0072eceipt"' : '"receipt"';
    const artifact = Buffer.from(`{"artifactVersion":${version},"result":{"code":${codeJson},"value":${value}},"runId":${runIdJson}}\n`);
    if (protocolVersion === 2) writeFileSync(join(process.env.AGENT_CAT_RUN_STORE, "result.json"), artifact, { mode: 0o600, flag: "wx" });
    emit({
      type: "run.completed", billFresh: "1", billMemo: "1",
      ...(protocolVersion === 2 ? { result: {
        artifactVersion: 1, path: "result.json", sha256: createHash("sha256").update(artifact).digest("hex"),
        bytes: String(artifact.length), code: "receipt", preview: "done",
      } } : {}),
    });
  };
  if (process.env.FIXTURE_SECRET) {
    process.stderr.write("Authoriza");
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 25);
    process.stderr.write(`tion: Bearer ${process.env.FIXTURE_SECRET}\ntok`);
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 25);
    process.stderr.write(`en=${process.env.FIXTURE_SECRET}\n`);
  }
  if (process.env.FIXTURE_STDERR_BYTES) process.stderr.write("x".repeat(Number(process.env.FIXTURE_STDERR_BYTES)));
  emit({ type: "run.started", workflow: descriptor.name, target: "scripted", ...(protocolVersion === 2 ? { personAnswering: "engine" } : {}) });
  if (process.env.FIXTURE_HANG === "1") {
    emit({ type: "occurrence.started", occurrenceId: "0", code: "text", intent: "consult", addressee: "model", prompt: "subject" });
    emit({ type: "attempt.started", occurrenceId: "0", attempt: "0", target: "scripted" });
    const rl = readline.createInterface({ input: controlInput() });
    rl.on("line", (line) => {
      const control = JSON.parse(line);
      if (control.command.type === "steerOccurrence") {
        if (process.env.FIXTURE_CONTROL_STATE) {
          acknowledge(control, process.env.FIXTURE_CONTROL_STATE, "target rejected control");
        } else {
          acknowledge(control, "accepted", "steer accepted");
          emit({ type: "attempt.steered", occurrenceId: "0", attempt: "0", controlId: control.controlId, timing: control.command.timing, text: control.command.text });
          acknowledge(control, "delivered", "steer delivered");
        }
      } else {
        acknowledge(control, "accepted", "cancellation accepted");
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
      acknowledge(control, "accepted", "redirect accepted");
      emit({ type: "occurrence.redirected", occurrenceId: "0", controlId: control.controlId, target: control.command.target });
      acknowledge(control, "delivered", "redirect delivered");
      emit({ type: "attempt.started", occurrenceId: "0", attempt: "0", target: control.command.target });
      emit({ type: "attempt.completed", occurrenceId: "0", attempt: "0", source: control.command.target });
      emit({ type: "occurrence.completed", occurrenceId: "0", source: `asked:${control.command.target}`, answer: "done" });
      emit({ type: "trace.ordered", occurrenceIds: ["0"] });
      completed();
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
      acknowledge(control, "accepted", "recovery accepted");
      emit({ type: "occurrence.recovery-chosen", occurrenceId: "0", controlId: control.controlId, choice, ...(choice === "failover" ? { target: "model@spare" } : {}) });
      if (choice !== "abandon") emit({ type: "occurrence.retried", occurrenceId: "0", controlId: control.controlId });
      acknowledge(control, "delivered", "recovery delivered");
      if (choice === "abandon") {
        emit({ type: "occurrence.failed", occurrenceId: "0", failure: "decode", message: "abandoned" });
        emit({ type: "run.failed", failure: "decode", message: "abandoned" });
      } else {
        const target = choice === "failover" ? "model@spare" : "scripted";
        emit({ type: "attempt.started", occurrenceId: "0", attempt: "1", target });
        emit({ type: "attempt.completed", occurrenceId: "0", attempt: "1", source: target });
        emit({ type: "occurrence.completed", occurrenceId: "0", source: `asked:${target}`, answer: "done" });
        emit({ type: "trace.ordered", occurrenceIds: ["0"] });
        completed();
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
    completed();
  }
} else {
  process.stderr.write(`unexpected args: ${JSON.stringify(args)}\n`);
  process.exitCode = 1;
}
