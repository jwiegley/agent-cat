import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { createHash } from "node:crypto";
import { join } from "node:path";
import { canonicalJson, parseDescriptor, readRouting, supportsRoutingInspection } from "./catalogue.ts";
import { allowedCwd, assertExactInputs, assertNoCredentialArgs, canonicalExecutable, type PreparedLaunch } from "./launch.ts";
import { encodeJson, isJsonObject, jsonMember, parseJson } from "./manager/json.ts";
import { assertLocalStateRoot } from "./root-role.ts";
import { parseLaunchManifest } from "./supervisor.ts";
import type { FrontendInvocation, RunnerConfig, WorkflowDescriptor } from "./types.ts";

export type NativeLaunch = { prepared: PreparedLaunch; review: string; discard: () => Promise<void> };

/** Hold the native preparation through approval instead of resolving its target again. */
export async function prepareRoutedLaunch(options: {
  runner: RunnerConfig; descriptor: WorkflowDescriptor; cwd: string; stateDir: string;
  inputs: Record<string, string>; persona: string; signal?: AbortSignal;
}): Promise<NativeLaunch> {
  const { runner, descriptor, inputs, persona, stateDir } = options;
  if (!supportsRoutingInspection(descriptor)) throw new Error("configured workflow persona requires version-2 routing inspection");
  const executable = await canonicalExecutable(runner.executable);
  const cwd = await allowedCwd(options.cwd, runner.allowedCwds);
  assertExactInputs(descriptor.inputs.map(({ name }) => name), inputs);
  await assertLocalStateRoot(stateDir);
  const inspection = await readRouting({ ...runner, executable }, cwd, { persona, signal: options.signal });
  options.signal?.throwIfAborted();
  if (!inspection || inspection.persona.name !== persona) throw new Error("configured workflow persona was not resolved");
  const targetArgs = [...inspection.launch.arguments, "--persona", persona, "--offline", "--expect-routing-fingerprint", inspection.launch.fingerprint];
  assertNoCredentialArgs([...(runner.prefixArgs ?? []), ...targetArgs]);
  const invocation: FrontendInvocation = { version: 1, runnerAlias: runner.id, executable, prefixArgs: runner.prefixArgs ?? [] };
  const request = JSON.stringify({
    version: 1, operation: "prepare", workflow: descriptor.name, stateDirectory: stateDir,
    targetArguments: targetArgs, personAnswering: "engine", invocation,
    inputs: descriptor.inputs.map(({ name }) => ({ name, source: "literal", value: inputs[name] })),
  });
  if (Buffer.byteLength(request) + 1 > 2 * 1024 * 1024) throw new Error("native preparation request exceeds 2097152 bytes");
  const args = [...invocation.prefixArgs, "frontend"];
  const env = { ...process.env };
  const child = spawn(executable, args, { cwd, env, shell: false, stdio: ["pipe", "pipe", "pipe"], detached: process.platform !== "win32", signal: options.signal });
  const closed = new Promise<void>((resolve) => child.once("close", () => resolve()));
  let failed: Error | undefined;
  child.on("error", (error) => { failed = error; });
  child.stdin.on("error", (error) => { failed = error; });
  let approvalId: string | undefined;
  let started = false;
  let disposal: Promise<void> | undefined;
  const discard = (): Promise<void> => disposal ??= (async () => {
    if (started) return;
    if (approvalId && child.exitCode === null && child.signalCode === null && !child.stdin.destroyed) {
      child.stdin.end(`${JSON.stringify({ version: 1, operation: "discard", approvalId })}\n`);
    } else terminate(child, "SIGTERM");
    if (!(await exited(closed, 2_000))) terminate(child, "SIGTERM");
    if (!(await exited(closed, 2_000))) terminate(child, "SIGKILL");
    if (!(await exited(closed, 2_000))) throw new Error("native preparation did not terminate");
  })();
  try {
    const reply = firstReply(child);
    child.stdin.write(`${request}\n`);
    const { value, raw, stderr, stderrDropping } = await reply;
    const fields = object(value, "prepared reply");
    if (fields.version !== 1 || fields.operation !== "prepared") throw new Error("unsupported native prepared reply");
    const allowed = ["version", "operation", "approvalId", "runId", "rootIdentity", "cwd", "descriptor", "plan", "programHash", "targetKind", "targetArguments", "policy", "personAnswering", "server", "invocation", "inputs"];
    if (Object.keys(fields).some((key) => !allowed.includes(key))) throw new Error("native prepared reply has unknown fields");
    const rootIdentity = text(fields.rootIdentity, "rootIdentity");
    approvalId = text(fields.approvalId, "approvalId");
    if (canonicalJson(parseDescriptor(runner.id, fields.descriptor)) !== canonicalJson(descriptor)) throw new Error("workflow descriptor changed during preparation");
    if (canonicalJson(fields.invocation) !== canonicalJson(invocation)) throw new Error("native preparation changed the configured invocation");
    if (fields.cwd !== cwd || fields.personAnswering !== "engine") throw new Error("native preparation changed cwd or person answering");
    const policy = object(fields.policy, "prepared policy");
    const exact = parseJson(raw);
    const exactPolicy = isJsonObject(exact) ? jsonMember(exact, "policy") : undefined;
    if (exactPolicy === undefined) throw new Error("native prepared policy is missing");
    if (policy.persona !== persona) throw new Error("native preparation changed the selected persona");
    const server = object(fields.server, "prepared server");
    if (server.runnerVersion !== descriptor.runnerVersion) throw new Error("runner version changed during preparation");
    if (!Array.isArray(fields.inputs) || fields.inputs.length !== descriptor.inputs.length) throw new Error("native preparation changed workflow inputs");
    const hashes: Record<string, string> = {};
    for (const [index, { name }] of descriptor.inputs.entries()) {
      const input = object(fields.inputs[index], "prepared input");
      const sha256 = createHash("sha256").update(inputs[name]).digest("hex");
      if (input.name !== name || input.sha256 !== sha256 || input.bytes !== String(Buffer.byteLength(inputs[name]))) throw new Error("native preparation changed workflow input bytes");
      hashes[name] = sha256;
    }
    const manifest = parseLaunchManifest({
      frontendManifestVersion: 3, invocation, runId: fields.runId, runnerId: server.runnerId,
      runnerExecutable: server.executable, runnerVersion: server.runnerVersion, workflow: descriptor.name,
      cwd, targetKind: fields.targetKind, targetArgs: fields.targetArguments, inputHashes: hashes,
      programHash: fields.programHash, createdAt: new Date().toISOString(), persona, policyDigest: policy.policyDigest,
      personAnswering: "engine", ownerId: `frontend:${fields.runId}`, runtimeStore: "runtime",
    });
    assertNoCredentialArgs(manifest.targetArgs);
    const storeDir = join(stateDir, "runs", manifest.runId);
    const prepared: PreparedLaunch = {
      manifest, storeDir, inputFiles: new Map(descriptor.inputs.map(({ name }, index) => [name, join(storeDir, "inputs", `${index}.txt`)])),
      protocolVersion: 2, command: executable, args, env,
      frontend: { child, stderr, stderrDropping, approve: () => {
        if (started || disposal || failed || child.exitCode !== null || child.signalCode !== null || child.stdin.destroyed) throw new Error("native preparation is no longer available");
        child.stdin.write(`${JSON.stringify({ version: 1, operation: "start", approvalId })}\n`);
        started = true;
      } },
    };
    const review = [
      `workflow=${runner.id}:${descriptor.name}`, `approvalId=${approvalId}`, `runId=${manifest.runId}`,
      `runner=${canonicalJson(invocation)}`, `server=${canonicalJson(server)}`, `cwd=${cwd}`,
      `stateDirectory=${stateDir}`, `rootIdentity=${rootIdentity}`, `programHash=${manifest.programHash}`,
      `target=${manifest.targetKind}`, `target arguments=${canonicalJson(manifest.targetArgs)}`,
      `policy=${encodeJson(exactPolicy)}`, `inputs=${canonicalJson(fields.inputs)}`,
      `effects=${descriptor.capabilities.effects ?? "unknown"}`,
      "may call a paid model; not an operating-system sandbox; persistence=private full prompts/answers and captured inputs",
      ...inspection.warnings.map((warning) => `routing warning=${warning}`),
    ].join("\n");
    return { prepared, review, discard };
  } catch (error) {
    await discard();
    throw error;
  }
}

function firstReply(child: ChildProcessWithoutNullStreams): Promise<{ value: unknown; raw: string; stderr: string; stderrDropping: boolean }> {
  return new Promise((resolve, reject) => {
    let bytes = Buffer.alloc(0);
    let raw = "";
    let stderr = "";
    let truncated = false;
    let partialLine = false;
    const timer = setTimeout(() => finish(new Error("native preparation timed out")), 70_000);
    const diagnostic = (chunk: string) => {
      partialLine = !chunk.endsWith("\n");
      if (truncated) return;
      stderr += chunk;
      if (Buffer.byteLength(stderr) > 64 * 1024) { stderr = "[REDACTED OVERLONG PREPARATION DIAGNOSTIC]\n"; truncated = true; }
    };
    const ended = () => finish(new Error("native preparation ended before approval; no workflow was started"));
    const data = (chunk: Buffer) => {
      bytes = Buffer.concat([bytes, chunk]);
      if (bytes.length > 64 * 1024 * 1024 + 4096) return finish(new Error("native prepared reply exceeds its byte bound"));
      const newline = bytes.indexOf(10);
      if (newline < 0) return;
      try {
        if (bytes.subarray(newline + 1).length !== 0) throw new Error("native runner emitted data before approval");
        raw = bytes.subarray(0, newline).toString("utf8");
        const value: unknown = JSON.parse(raw);
        finish(undefined, value);
      } catch (error) { finish(error instanceof Error ? error : new Error("invalid native prepared reply")); }
    };
    const finish = (error?: Error, value?: unknown) => {
      clearTimeout(timer);
      child.stdout.pause();
      child.stderr.pause();
      child.stdout.off("data", data);
      child.stderr.off("data", diagnostic);
      child.off("close", ended);
      child.off("error", finish);
      if (error) reject(error);
      else resolve({ value, raw, stderr, stderrDropping: truncated && partialLine });
    };
    child.stdout.on("data", data);
    child.stderr.setEncoding("utf8");
    child.stderr.on("data", diagnostic);
    child.once("close", ended);
    child.once("error", finish);
  });
}

function object(value: unknown, label: string): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) throw new Error(`${label} is not an object`);
  return value as Record<string, unknown>;
}
function text(value: unknown, label: string): string {
  if (typeof value !== "string" || !value || value.length > 4096 || /[\0\r\n]/.test(value)) throw new Error(`invalid native ${label}`);
  return value;
}
function terminate(child: ChildProcessWithoutNullStreams, signal: NodeJS.Signals): void {
  if (!child.pid || child.exitCode !== null || child.signalCode !== null) return;
  try {
    if (process.platform === "win32") child.kill(signal);
    else process.kill(-child.pid, signal);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ESRCH") throw error;
  }
}
function exited(closed: Promise<void>, timeout: number): Promise<boolean> {
  return new Promise((resolve) => {
    const timer = setTimeout(() => resolve(false), timeout);
    void closed.then(() => { clearTimeout(timer); resolve(true); });
  });
}
