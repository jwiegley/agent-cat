import { createHash, randomUUID } from "node:crypto";
import { mkdir, realpath, rename, rm, writeFile } from "node:fs/promises";
import { isAbsolute, join, relative } from "node:path";
import { canonicalJson, checkLineage, readPlan } from "./catalogue.ts";
import type { LaunchManifest, RunnerConfig, TargetKind, WorkflowDescriptor } from "./types.ts";

export type PreparedLaunch = {
  manifest: LaunchManifest;
  storeDir: string;
  inputFiles: Map<string, string>;
  command: string;
  args: string[];
  env: NodeJS.ProcessEnv;
};

export type LineageEdit =
  | { type: "drop"; occurrenceId: string }
  | { type: "replace"; occurrenceId: string; value: string };

export async function prepareLaunch(options: {
  runner: RunnerConfig;
  descriptor: WorkflowDescriptor;
  cwd: string;
  stateDir: string;
  inputs: Record<string, string>;
  targetKind: TargetKind;
  targetArgs: string[];
  lineage?: { operation: "restart" | "resume" | "fork"; parentRunId: string; parentRuntimeDir: string; edits?: LineageEdit[] };
}): Promise<PreparedLaunch> {
  const executable = await canonicalExecutable(options.runner.executable);
  const cwd = await allowedCwd(options.cwd, options.runner.allowedCwds);
  const lineage = options.lineage ? { ...options.lineage, parentRuntimeDir: await realpath(options.lineage.parentRuntimeDir) } : undefined;
  if (lineage && !inside(await realpath(join(options.stateDir, "runs")), lineage.parentRuntimeDir)) {
    throw new Error("parent runtime store is outside the configured run-state root");
  }
  assertExactInputs(options.descriptor.inputs, options.inputs);
  assertNoCredentialArgs(options.targetArgs);

  const runId = randomUUID();
  const storeDir = join(options.stateDir, "runs", runId);
  const inputDir = join(storeDir, "inputs");
  try {
    await mkdir(inputDir, { recursive: true, mode: 0o700 });
    const inputFiles = new Map<string, string>();
  const inputHashes: Record<string, string> = {};
  for (const [index, name] of options.descriptor.inputs.entries()) {
    const value = options.inputs[name];
    const path = join(inputDir, `${index}.txt`);
    await writeFile(path, value, { encoding: "utf8", mode: 0o600, flag: "wx" });
    inputFiles.set(name, path);
    inputHashes[name] = sha256(value);
  }

  const lineageEditArgs = await writeForkEdits(inputDir, lineage?.edits ?? []);
  const plan = await readPlan({ ...options.runner, executable }, options.descriptor.name, inputFiles, cwd);
  const programHash = sha256(canonicalJson(plan.program));
  const manifest: LaunchManifest = {
    runId,
    runnerId: options.runner.id,
    workflow: options.descriptor.name,
    cwd,
    targetKind: options.targetKind,
    targetArgs: [...options.targetArgs],
    inputHashes,
    programHash,
    createdAt: new Date().toISOString(),
    parentRunId: lineage?.parentRunId,
    lineage: lineage?.operation,
    lineageEdits: lineage?.edits?.map((edit) => edit.type === "drop"
      ? { type: "drop", occurrenceId: edit.occurrenceId }
      : { type: "replace", occurrenceId: edit.occurrenceId, replacementHash: sha256(edit.value) }),
  };
  await atomicJson(join(storeDir, "supervisor-manifest.json"), manifest);

  const invocation = lineage
    ? [`machine-${lineage.operation}`, runId, lineage.parentRuntimeDir, options.descriptor.name, ...lineageEditArgs]
    : ["machine", runId, options.descriptor.name];
  const args = [
    ...(options.runner.prefixArgs ?? []),
    ...invocation,
    ...options.targetArgs,
  ];
  for (const [name, path] of inputFiles) args.push("--input-file", `${name}=${path}`);
  return {
    manifest,
    storeDir,
    inputFiles,
    command: executable,
    args,
    env: { ...process.env, AGENT_CAT_RUN_STORE: join(storeDir, "runtime"), AGENT_CAT_CONTROL_STDIN: "1", AGENT_CAT_RUN_OWNER: `pi-extension:${process.pid}` },
    };
  } catch (error) {
    await rm(storeDir, { recursive: true, force: true });
    throw error;
  }
}

export async function previewPlan(options: {
  runner: RunnerConfig;
  descriptor: WorkflowDescriptor;
  cwd: string;
  stateDir: string;
  inputs: Record<string, string>;
}): Promise<Record<string, unknown>> {
  const executable = await canonicalExecutable(options.runner.executable);
  const cwd = await allowedCwd(options.cwd, options.runner.allowedCwds);
  assertExactInputs(options.descriptor.inputs, options.inputs);
  const directory = join(options.stateDir, "previews", randomUUID());
  await mkdir(directory, { recursive: true, mode: 0o700 });
  const files = new Map<string, string>();
  try {
    for (const [index, name] of options.descriptor.inputs.entries()) {
      const path = join(directory, `${index}.txt`);
      await writeFile(path, options.inputs[name], { encoding: "utf8", mode: 0o600, flag: "wx" });
      files.set(name, path);
    }
    return await readPlan({ ...options.runner, executable }, options.descriptor.name, files, cwd);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
}

export function assertNoCredentialArgs(args: string[]): void {
  const credentialKeys = new Set([
    "api-key", "api_key", "apikey", "token", "access-token", "auth-token",
    "secret", "client-secret", "password", "authorization", "access-key",
  ]);
  const credentialKey = /(^|[-_])(api[-_]?key|access[-_]?key|auth|authorization|token|secret|password|cookie|credential)([-_]|$)/;
  const inspectArgs = args.filter((argument) => argument.trim().toLowerCase() !== "--adapter-arg");
  for (let index = 0; index < inspectArgs.length; index += 1) {
    const argument = inspectArgs[index].trim().toLowerCase();
    const key = argument.split("=", 1)[0].replace(/^--?/, "");
    const previous = index > 0 ? inspectArgs[index - 1].trim().toLowerCase() : "";
    const headerValue = previous === "--header" || previous === "-h"
      ? argument
      : key === "header" && argument.includes("=") ? argument.slice(argument.indexOf("=") + 1) : undefined;
    const headerName = headerValue?.split(":", 1)[0];
    const credentialHeader = headerName !== undefined && /(^|[-_])(api[-_]?key|access[-_]?key|auth|authorization|token|secret|password|cookie|credential)([-_]|$)/.test(headerName);
    const authorizationHeader = /^authorization\s*:/.test(argument);
    const embeddedCredentialKey = argument.split(/[=:]/).some((part) => credentialKey.test(part.replace(/^--?/, "")));
    if (credentialKeys.has(key) || credentialKey.test(key) || embeddedCredentialKey || authorizationHeader || credentialHeader) {
      throw new Error("credential-bearing target argv is forbidden; use inherited environment configuration");
    }
  }
}

async function writeForkEdits(directory: string, edits: LineageEdit[]): Promise<string[]> {
  const args: string[] = [];
  for (const [index, edit] of edits.entries()) {
    if (!/^(0|[1-9][0-9]*)$/.test(edit.occurrenceId)) throw new Error("fork edit occurrenceId must be an unsigned decimal string");
    if (edit.type === "drop") {
      args.push("--drop-answer", edit.occurrenceId);
    } else {
      let value: unknown;
      try { value = JSON.parse(edit.value); } catch { throw new Error(`replacement for occurrence ${edit.occurrenceId} is not JSON`); }
      const path = join(directory, `fork-replacement-${index}.json`);
      await writeFile(path, `${JSON.stringify(value)}\n`, { encoding: "utf8", mode: 0o600, flag: "wx" });
      args.push("--set-answer", `${edit.occurrenceId}=${path}`);
    }
  }
  return args;
}

function assertExactInputs(expected: string[], actual: Record<string, string>): void {
  const wanted = [...expected].sort();
  const got = Object.keys(actual).sort();
  if (wanted.length !== got.length || wanted.some((name, index) => name !== got[index])) {
    throw new Error(`inputs must be exactly: ${expected.join(", ") || "(none)"}`);
  }
}

async function canonicalExecutable(path: string): Promise<string> {
  if (!isAbsolute(path)) throw new Error("runner executable must be absolute");
  return realpath(path);
}

async function allowedCwd(path: string, roots: string[]): Promise<string> {
  const cwd = await realpath(path);
  const allowed = await Promise.all(roots.map((root) => realpath(root)));
  if (!allowed.some((root) => inside(root, cwd))) throw new Error(`cwd is outside configured roots: ${cwd}`);
  return cwd;
}

export async function preflightLineage(options: {
  runner: RunnerConfig; descriptor: WorkflowDescriptor; cwd: string; stateDir: string; inputs: Record<string, string>;
  targetArgs: string[]; operation: "restart" | "resume" | "fork"; parentRuntimeDir: string; edits?: LineageEdit[];
}): Promise<void> {
  const executable = await canonicalExecutable(options.runner.executable);
  const cwd = await allowedCwd(options.cwd, options.runner.allowedCwds);
  const parentRuntimeDir = await realpath(options.parentRuntimeDir);
  if (!inside(await realpath(join(options.stateDir, "runs")), parentRuntimeDir)) throw new Error("parent runtime store is outside the configured run-state root");
  assertExactInputs(options.descriptor.inputs, options.inputs);
  assertNoCredentialArgs(options.targetArgs);
  const directory = join(options.stateDir, "previews", randomUUID());
  await mkdir(directory, { recursive: true, mode: 0o700 });
  const files = new Map<string, string>();
  try {
    for (const [index, name] of options.descriptor.inputs.entries()) {
      const path = join(directory, `${index}.txt`);
      await writeFile(path, options.inputs[name], { encoding: "utf8", mode: 0o600, flag: "wx" });
      files.set(name, path);
    }
    const editArgs = await writeForkEdits(directory, options.edits ?? []);
    await checkLineage({ ...options.runner, executable }, options.operation, parentRuntimeDir, options.descriptor.name, files, [...editArgs, ...options.targetArgs], cwd);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
}

function inside(root: string, path: string): boolean {
  const rel = relative(root, path);
  return rel === "" || (!rel.startsWith("..") && !isAbsolute(rel));
}

function sha256(value: string): string {
  return createHash("sha256").update(value).digest("hex");
}

async function atomicJson(path: string, value: unknown): Promise<void> {
  const temp = `${path}.tmp-${process.pid}`;
  await writeFile(temp, `${JSON.stringify(value)}\n`, { encoding: "utf8", mode: 0o600, flag: "wx" });
  await rename(temp, path);
}
