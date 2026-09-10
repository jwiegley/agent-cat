import { execFile } from "node:child_process";
import { promisify } from "node:util";
import type { RoutingInspection, RunnerConfig, WorkflowDescriptor, WorkflowInput } from "./types.ts";

const execFileAsync = promisify(execFile);
const MAX_OUTPUT = 4 * 1024 * 1024;
const TIMEOUT_MS = 15_000;

export async function discoverRunner(config: RunnerConfig, cwd: string): Promise<WorkflowDescriptor[]> {
  let stdout: string;
  try {
    stdout = await invoke(config, ["list", "--json", "--descriptor-version", "3"], cwd);
  } catch (error) {
    if (!isUnsupportedDescriptorVersion(error)) throw error;
    stdout = await invoke(config, ["list", "--json"], cwd);
  }
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

export function supportsRoutingInspection(descriptor: WorkflowDescriptor): boolean {
  return descriptor.descriptorVersion >= 3
    && descriptor.capabilities.routingInspection === true
    && descriptor.capabilities.routingJsonVersion === 2
    && descriptor.capabilities.personaRouting === true
    && descriptor.capabilities.modelAliasRouting === true;
}

export function negotiateProtocolVersion(descriptor: WorkflowDescriptor, supported: readonly number[] = [1, 2]): number {
  const common = descriptor.protocolVersions.filter((version) => supported.includes(version)).sort((left, right) => right - left);
  if (common.length === 0) throw new Error(`runner ${descriptor.runnerId} has no supported machine protocol`);
  return common[0];
}

export async function readRouting(
  config: RunnerConfig, cwd: string, options: { persona?: string; mode?: "offline" | "refresh" } = {},
): Promise<RoutingInspection | undefined> {
  const args = ["--routing", "--json"];
  if (options.persona !== undefined) { assertName(options.persona, "persona"); args.push("--persona", options.persona); }
  if (options.mode === "offline") args.push("--offline");
  if (options.mode === "refresh") args.push("--refresh-models");
  return parseRoutingInspection(config.id, JSON.parse(await invoke(config, args, cwd, 70_000)));
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

async function invoke(config: RunnerConfig, args: string[], cwd: string, timeout = TIMEOUT_MS): Promise<string> {
  const { stdout } = await execFileAsync(config.executable, [...(config.prefixArgs ?? []), ...args], {
    cwd,
    timeout,
    maxBuffer: MAX_OUTPUT,
    encoding: "utf8",
  });
  return stdout;
}

export function parseDescriptor(runnerId: string, value: unknown): WorkflowDescriptor {
  if (!isObject(value)) throw new Error(`runner ${runnerId} returned a non-object workflow`);
  const descriptorVersion = number(value.descriptorVersion, "descriptorVersion");
  if (![1, 2, 3].includes(descriptorVersion)) throw new Error(`unsupported descriptor version ${descriptorVersion}`);
  if (descriptorVersion >= 2) onlyKeys(value, descriptorKeys(descriptorVersion), "workflow descriptor");
  if (descriptorVersion >= 2 && !Object.prototype.hasOwnProperty.call(value, "result")) throw new Error("result is missing");
  const descriptor: WorkflowDescriptor = {
    runnerId,
    name: text(value.name, "name"),
    blurb: text(value.blurb, "blurb"),
    result: value.result,
    level: text(value.level, "level"),
    size: naturalNumber(value.size, "size"),
    askNodes: naturalNumber(value.askNodes, "askNodes"),
    minFold: nullableNaturalNumber(value.minFold, "minFold"),
    maxFold: nullableNaturalNumber(value.maxFold, "maxFold"),
    paths: naturalNumber(value.paths, "paths"),
    inputs: workflowInputs(value.inputs, descriptorVersion),
    runFacts: texts(value.runFacts, "runFacts"),
    pins: texts(value.pins, "pins"),
    descriptorVersion,
    runnerVersion: text(value.runnerVersion, "runnerVersion"),
    protocolVersions: numbers(value.protocolVersions, "protocolVersions"),
    storeVersions: numbers(value.storeVersions, "storeVersions"),
    capabilities: capabilities(value.capabilities, descriptorVersion),
    personAnsweringModes: descriptorVersion >= 3 ? texts(value.personAnsweringModes, "personAnsweringModes") : [],
  };
  assertName(descriptor.name, "workflow");
  const duplicate = descriptor.inputs.find((input, index) => descriptor.inputs.findIndex(({ name }) => name === input.name) !== index);
  if (duplicate) throw new Error(`input ${duplicate.name} was listed twice`);
  for (const source of ["command-tail", "stdin"] as const) {
    const names = descriptor.inputs.filter((input) => input.source === source).map(({ name }) => name);
    if (names.length > 1) throw new Error(`multiple ${source} inputs: ${names.join(", ")}`);
  }
  if (!descriptor.protocolVersions.includes(1)) throw new Error(`runner ${runnerId} does not support protocol 1`);
  if (!descriptor.storeVersions.includes(1)) throw new Error(`runner ${runnerId} does not support store 1`);
  if (new Set(descriptor.protocolVersions).size !== descriptor.protocolVersions.length) throw new Error("protocolVersions contains duplicates");
  if (new Set(descriptor.storeVersions).size !== descriptor.storeVersions.length) throw new Error("storeVersions contains duplicates");
  if (descriptor.minFold !== null && descriptor.maxFold !== null && descriptor.minFold > descriptor.maxFold) throw new Error("minFold exceeds maxFold");
  if (descriptorVersion >= 3) {
    if (!descriptor.protocolVersions.includes(2)) throw new Error("descriptor version 3 does not support protocol 2");
    if (!descriptor.storeVersions.includes(2)) throw new Error("descriptor version 3 does not support store 2");
    if (descriptor.personAnsweringModes.length !== 1 || descriptor.personAnsweringModes[0] !== "local-control") {
      throw new Error("descriptor version 3 has unsupported person answering modes");
    }
  }
  return descriptor;
}

const capabilityKeys = [
  "structuredRun", "wholeRunCancel", "controlFd", "requestControls", "steering",
  "interactiveRetry", "schedulerRedirect", "semanticResume", "immutableFork",
  "restartFromScratch", "protocolNegotiation", "routingInspection", "routingJsonVersion",
  "personaRouting", "modelAliasRouting", "consults", "observes", "effects", "effectful", "toolExecution",
];

function descriptorKeys(version: number): string[] {
  return [
    "descriptorVersion", "runnerVersion", "protocolVersions", "storeVersions", "capabilities",
    "name", "blurb", "result", "level", "size", "askNodes", "minFold", "maxFold", "paths",
    "inputs", "runFacts", "pins", ...(version >= 3 ? ["personAnsweringModes"] : []),
  ];
}

function onlyKeys(value: Record<string, unknown>, allowed: string[], label: string): void {
  const unknown = Object.keys(value).filter((key) => !allowed.includes(key));
  if (unknown.length) throw new Error(`${label} has unknown field(s): ${unknown.join(", ")}`);
}

function workflowInputs(value: unknown, descriptorVersion: number): WorkflowInput[] {
  if (descriptorVersion === 1) return texts(value, "inputs").map((name) => ({ name, source: "prompt" }));
  if (!Array.isArray(value)) throw new Error("inputs is not an input descriptor array");
  return value.map((entry, index) => {
    if (!isObject(entry)) throw new Error(`inputs[${index}] is not an object`);
    if (Object.keys(entry).some((key) => key !== "name" && key !== "source")) throw new Error(`inputs[${index}] has an unknown field`);
    const name = text(entry.name, `inputs[${index}].name`);
    assertName(name, "input");
    const source = text(entry.source, `inputs[${index}].source`);
    if (source !== "prompt" && source !== "command-tail" && source !== "stdin") throw new Error(`inputs[${index}] has unknown source ${source}`);
    return { name, source };
  });
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

function nullableNaturalNumber(value: unknown, label: string): number | null {
  return value === null ? null : naturalNumber(value, label);
}

function naturalNumber(value: unknown, label: string): number {
  const result = number(value, label);
  if (result < 0) throw new Error(`${label} is negative`);
  return result;
}

function texts(value: unknown, label: string): string[] {
  if (!Array.isArray(value) || !value.every((entry) => typeof entry === "string")) throw new Error(`${label} is not text[]`);
  return [...value];
}

function numbers(value: unknown, label: string): number[] {
  if (!Array.isArray(value)) throw new Error(`${label} is not number[]`);
  return value.map((entry) => number(entry, label));
}

function capabilities(value: unknown, descriptorVersion: number): Record<string, boolean | number> {
  if (!isObject(value)) throw new Error("capabilities is not an object");
  if (descriptorVersion >= 2) onlyKeys(value, capabilityKeys, "workflow descriptor capabilities");
  const booleanKeys = new Set([
    "structuredRun", "wholeRunCancel", "requestControls", "steering", "interactiveRetry",
    "schedulerRedirect", "semanticResume", "immutableFork", "restartFromScratch",
    "protocolNegotiation", "routingInspection", "personaRouting", "modelAliasRouting",
    "effectful", "toolExecution",
  ]);
  const numericKeys = new Set(["controlFd", "routingJsonVersion", "consults", "observes", "effects"]);
  const result: Record<string, boolean | number> = Object.fromEntries(
    [...booleanKeys].map((key) => [key, false]),
  );
  Object.assign(result, { consults: 0, observes: 0, effects: 0 });
  for (const [key, entry] of Object.entries(value)) {
    if (booleanKeys.has(key)) {
      if (typeof entry !== "boolean") throw new Error(`capability ${key} is invalid`);
    } else if (numericKeys.has(key)) {
      if (typeof entry !== "number" || !Number.isSafeInteger(entry) || entry < 0) throw new Error(`capability ${key} is invalid`);
    } else if (typeof entry !== "boolean" && (typeof entry !== "number" || !Number.isSafeInteger(entry) || entry < 0)) {
      throw new Error(`capability ${key} is invalid`);
    }
    result[key] = entry as boolean | number;
  }
  if (descriptorVersion >= 2 && result.controlFd !== undefined && (typeof result.controlFd !== "number" || result.controlFd < 3)) {
    throw new Error("capability controlFd is invalid");
  }
  if (descriptorVersion >= 2 && result.effectful !== ((result.effects as number) > 0)) {
    throw new Error("capability effectful disagrees with effects");
  }
  return result;
}

function parseRoutingInspection(runnerId: string, value: unknown): RoutingInspection | undefined {
  if (!isObject(value)) throw new Error(`runner ${runnerId} routing inspection is not an object`);
  const version = number(value.version, "routing version");
  if (version === 1) return undefined;
  if (version !== 2) throw new Error(`runner ${runnerId} returned unsupported routing inspection version`);
  assertSanitizedRouting(value);
  if (!isObject(value.persona)) throw new Error("routing persona is not an object");
  const persona = { name: text(value.persona.name, "routing persona name"), source: text(value.persona.source, "routing persona source") };
  if (!isObject(value.launch)) throw new Error("routing launch is not an object");
  if (text(value.launch.targetKind, "routing launch target kind") !== "routing") throw new Error("routing launch target kind is invalid");
  const launch = {
    arguments: texts(value.launch.arguments, "routing launch arguments"),
    fingerprint: text(value.launch.fingerprint, "routing launch fingerprint"),
  };
  if (launch.arguments.length === 0 || launch.arguments.length > 16 || launch.arguments.some((argument) => !argument || argument.length > 4096 || /[\0\r\n]/.test(argument))) throw new Error("routing launch arguments are invalid");
  if (!/^[0-9a-f]{64}$/.test(launch.fingerprint)) throw new Error("routing launch fingerprint is invalid");
  const availablePersonas = texts(value.availablePersonas, "availablePersonas");
  if (!availablePersonas.includes(persona.name)) throw new Error("selected routing persona is absent from availablePersonas");
  if (!Array.isArray(value.availableModels)) throw new Error("availableModels is not an array");
  const availableModels = value.availableModels.map((entry, index) => {
    if (!isObject(entry)) throw new Error(`availableModels[${index}] is not an object`);
    return { alias: text(entry.alias, `availableModels[${index}].alias`), engine: text(entry.engine, `availableModels[${index}].engine`) };
  });
  if (new Set(availablePersonas).size !== availablePersonas.length) throw new Error("availablePersonas contains duplicates");
  if (new Set(availableModels.map(({ alias }) => alias)).size !== availableModels.length) throw new Error("availableModels contains duplicate aliases");
  if (!Array.isArray(value.profiles)) throw new Error("routing profiles is not an array");
  const profiles = value.profiles.map((profile, index) => {
    if (!isObject(profile) || !Array.isArray(profile.rungs)) throw new Error(`profiles[${index}] is invalid`);
    return {
      name: text(profile.name, `profiles[${index}].name`),
      rungs: profile.rungs.map((rung, rungIndex) => {
        if (!isObject(rung)) throw new Error(`profiles[${index}].rungs[${rungIndex}] is not an object`);
        return {
          axis: text(rung.axis, `profiles[${index}].rungs[${rungIndex}].axis`),
          modelAlias: text(rung.modelAlias, `profiles[${index}].rungs[${rungIndex}].modelAlias`),
          model: text(rung.model, `profiles[${index}].rungs[${rungIndex}].model`),
        };
      }),
    };
  });
  return { version: 2, persona, launch, availablePersonas, availableModels, profiles, warnings: texts(value.warnings, "routing warnings"), raw: value };
}

function isUnsupportedDescriptorVersion(error: unknown): boolean {
  if (typeof error !== "object" || error === null) return false;
  const failure = error as { code?: unknown; killed?: unknown; signal?: unknown; stderr?: unknown };
  if (typeof failure.code !== "number" || failure.code === 0 || failure.killed === true || failure.signal) return false;
  const stderr = typeof failure.stderr === "string" ? failure.stderr : Buffer.isBuffer(failure.stderr) ? failure.stderr.toString("utf8") : "";
  return /(?:unknown|unrecognized|unsupported|invalid|unexpected|no) (?:option|argument)[^\n]*--descriptor-version/i.test(stderr);
}

function assertSanitizedRouting(value: unknown): void {
  const forbidden = new Set([
    "secret", "secrets", "secretref", "secretreference", "secretvalue",
    "environment", "environments", "environmentname", "environmentvalue",
    "header", "headers", "auth", "authorization", "credential", "credentials", "credentialvalue",
    "token", "accesstoken", "authtoken", "bearertoken", "refreshtoken", "sessiontoken",
    "apikey", "password", "passwordvalue", "cookie", "cookievalue",
    "url", "endpoint", "endpointurl", "baseurl", "catalogurl", "catalogueurl",
  ]);
  const visit = (entry: unknown): void => {
    if (Array.isArray(entry)) { entry.forEach(visit); return; }
    if (!isObject(entry)) return;
    for (const [key, child] of Object.entries(entry)) {
      const normalized = key.toLowerCase().replace(/[^a-z0-9]/g, "");
      if (forbidden.has(normalized)) throw new Error(`routing inspection contains forbidden field ${key}`);
      visit(child);
    }
  };
  visit(value);
}
