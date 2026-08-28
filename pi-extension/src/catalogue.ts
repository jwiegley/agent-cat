import { execFile } from "node:child_process";
import { promisify } from "node:util";
import type { RunnerConfig, WorkflowDescriptor } from "./types.ts";

const execFileAsync = promisify(execFile);
const MAX_OUTPUT = 4 * 1024 * 1024;
const TIMEOUT_MS = 15_000;

export async function discoverRunner(config: RunnerConfig, cwd: string): Promise<WorkflowDescriptor[]> {
  const stdout = await invoke(config, ["list", "--json"], cwd);
  const parsed: unknown = JSON.parse(stdout);
  if (!Array.isArray(parsed)) throw new Error(`runner ${config.id} list is not an array`);
  const names = new Set<string>();
  return parsed.map((value) => {
    const descriptor = parseDescriptor(config.id, value);
    if (names.has(descriptor.name)) throw new Error(`runner ${config.id} lists duplicate workflow ${descriptor.name}`);
    names.add(descriptor.name);
    return descriptor;
  });
}

export function qualify(runnerId: string, workflow: string): string {
  return `${runnerId}:${workflow}`;
}

export async function readHelp(config: RunnerConfig, workflow: string, cwd: string): Promise<string> {
  assertName(workflow, "workflow");
  return invoke(config, ["help", workflow], cwd);
}

export async function readPlan(
  config: RunnerConfig,
  workflow: string,
  inputFiles: ReadonlyMap<string, string>,
  cwd: string,
): Promise<Record<string, unknown>> {
  assertName(workflow, "workflow");
  const args = ["plan", workflow, "--json", "--raw"];
  for (const [name, path] of inputFiles) {
    assertName(name, "input");
    args.push("--input-file", `${name}=${path}`);
  }
  const parsed: unknown = JSON.parse(await invoke(config, args, cwd));
  if (!isObject(parsed) || !isObject(parsed.program)) throw new Error(`runner ${config.id} plan has no program object`);
  return parsed;
}

export async function checkLineage(
  config: RunnerConfig, operation: "restart" | "resume" | "fork", parentStore: string, workflow: string,
  inputFiles: ReadonlyMap<string, string>, targetArgs: string[], cwd: string,
 ): Promise<void> {
  assertName(workflow, "workflow");
  const args = ["lineage-check", operation, parentStore, workflow, ...targetArgs];
  for (const [name, path] of inputFiles) {
    assertName(name, "input");
    args.push("--input-file", `${name}=${path}`);
  }
  await invoke(config, args, cwd);
}

export function canonicalJson(value: unknown): string {
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  if (isObject(value)) {
    return `{${Object.keys(value)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${canonicalJson(value[key])}`)
      .join(",")}}`;
  }
  return JSON.stringify(value);
}

async function invoke(config: RunnerConfig, args: string[], cwd: string): Promise<string> {
  const { stdout } = await execFileAsync(config.executable, [...(config.prefixArgs ?? []), ...args], {
    cwd,
    timeout: TIMEOUT_MS,
    maxBuffer: MAX_OUTPUT,
    encoding: "utf8",
    shell: false,
  });
  return stdout;
}

function parseDescriptor(runnerId: string, value: unknown): WorkflowDescriptor {
  if (!isObject(value)) throw new Error(`runner ${runnerId} returned a non-object workflow`);
  const descriptor: WorkflowDescriptor = {
    runnerId,
    name: text(value.name, "name"),
    blurb: text(value.blurb, "blurb"),
    level: text(value.level, "level"),
    size: number(value.size, "size"),
    askNodes: number(value.askNodes, "askNodes"),
    minFold: nullableNumber(value.minFold, "minFold"),
    maxFold: nullableNumber(value.maxFold, "maxFold"),
    paths: number(value.paths, "paths"),
    inputs: texts(value.inputs, "inputs"),
    runFacts: texts(value.runFacts, "runFacts"),
    pins: texts(value.pins, "pins"),
    descriptorVersion: number(value.descriptorVersion, "descriptorVersion"),
    runnerVersion: text(value.runnerVersion, "runnerVersion"),
    protocolVersions: numbers(value.protocolVersions, "protocolVersions"),
    storeVersions: numbers(value.storeVersions, "storeVersions"),
    capabilities: capabilities(value.capabilities),
  };
  assertName(descriptor.name, "workflow");
  if (descriptor.descriptorVersion !== 1) throw new Error(`unsupported descriptor version ${descriptor.descriptorVersion}`);
  if (!descriptor.protocolVersions.includes(1)) throw new Error(`runner ${runnerId} does not support protocol 1`);
  return descriptor;
}

function assertName(value: string, label: string): void {
  if (!value || value.includes("\0") || value.includes("\n")) throw new Error(`invalid ${label} name`);
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function text(value: unknown, label: string): string {
  if (typeof value !== "string") throw new Error(`${label} is not text`);
  return value;
}

function number(value: unknown, label: string): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value)) throw new Error(`${label} is not a safe integer`);
  return value;
}

function nullableNumber(value: unknown, label: string): number | null {
  return value === null ? null : number(value, label);
}

function texts(value: unknown, label: string): string[] {
  if (!Array.isArray(value) || !value.every((entry) => typeof entry === "string")) throw new Error(`${label} is not text[]`);
  return [...value];
}

function numbers(value: unknown, label: string): number[] {
  if (!Array.isArray(value)) throw new Error(`${label} is not number[]`);
  return value.map((entry) => number(entry, label));
}

function capabilities(value: unknown): Record<string, boolean | number> {
  if (!isObject(value)) throw new Error("capabilities is not an object");
  const result: Record<string, boolean | number> = {};
  for (const [key, entry] of Object.entries(value)) {
    if (typeof entry !== "boolean" && (typeof entry !== "number" || !Number.isSafeInteger(entry))) {
      throw new Error(`capability ${key} is invalid`);
    }
    result[key] = entry;
  }
  return result;
}
