import { isAbsolute } from "node:path";
import type { ClientMode, RunnerConfig } from "./types.ts";

export function configuredRunners(cwd: string, env: NodeJS.ProcessEnv = process.env): RunnerConfig[] {
  const configured = env.AGENT_CAT_RUNNERS;
  const single = env.AGENT_CAT_RUNNER;
  if (configured && single) throw new Error("configure AGENT_CAT_RUNNERS or AGENT_CAT_RUNNER, not both");
  if (!configured) {
    if (!single) return [];
    if (!isAbsolute(single)) throw new Error("AGENT_CAT_RUNNER must be an absolute path");
    return [{ id: env.AGENT_CAT_RUNNER_ID ?? "agent-cat", executable: single, allowedCwds: [cwd] }];
  }
  let parsed: unknown;
  try { parsed = JSON.parse(configured); } catch { throw new Error("AGENT_CAT_RUNNERS is not valid JSON"); }
  if (!Array.isArray(parsed) || parsed.length === 0) throw new Error("AGENT_CAT_RUNNERS must be a non-empty JSON array");
  const ids = new Set<string>();
  return parsed.map((value, index) => {
    if (typeof value !== "object" || value === null || Array.isArray(value)) throw new Error(`AGENT_CAT_RUNNERS[${index}] is not an object`);
    const entry = value as Record<string, unknown>;
    if (Object.keys(entry).some((key) => !["id", "executable", "prefixArgs", "allowedCwds"].includes(key))) throw new Error(`AGENT_CAT_RUNNERS[${index}] has an unknown field`);
    if (typeof entry.id !== "string" || !entry.id || ids.has(entry.id)) throw new Error(`AGENT_CAT_RUNNERS[${index}].id is empty or duplicated`);
    if (typeof entry.executable !== "string" || !isAbsolute(entry.executable)) throw new Error(`AGENT_CAT_RUNNERS[${index}].executable must be absolute`);
    const prefixArgs = optionalStrings(entry.prefixArgs, `AGENT_CAT_RUNNERS[${index}].prefixArgs`);
    const allowedCwds = entry.allowedCwds === undefined ? [cwd] : optionalStrings(entry.allowedCwds, `AGENT_CAT_RUNNERS[${index}].allowedCwds`);
    if (allowedCwds.length === 0 || allowedCwds.some((path) => !isAbsolute(path))) throw new Error(`AGENT_CAT_RUNNERS[${index}].allowedCwds must contain absolute paths`);
    ids.add(entry.id);
    return { id: entry.id, executable: entry.executable, prefixArgs, allowedCwds };
  });
}

export const MAX_MANAGER_PROFILES = 8;

/**
 * Reads the explicit client mode. Service mode is active only when `AGENT_CAT_MANAGER_PROFILES`
 * (a JSON array of 1 to 8 absolute client-profile paths) or `AGENT_CAT_MANAGER_PROFILE` (one
 * absolute path) is set. Local mode applies otherwise, and the local targets stay local in both.
 */
export function configuredManagerProfiles(env: NodeJS.ProcessEnv = process.env): ClientMode {
  const configured = env.AGENT_CAT_MANAGER_PROFILES;
  const single = env.AGENT_CAT_MANAGER_PROFILE;
  if (configured && single) throw new Error("configure AGENT_CAT_MANAGER_PROFILES or AGENT_CAT_MANAGER_PROFILE, not both");
  if (single) {
    if (!isAbsolute(single)) throw new Error("AGENT_CAT_MANAGER_PROFILE must be an absolute path");
    return { kind: "service", profiles: [single] };
  }
  if (!configured) return { kind: "local" };
  let parsed: unknown;
  try { parsed = JSON.parse(configured); } catch { throw new Error("AGENT_CAT_MANAGER_PROFILES is not valid JSON"); }
  if (!Array.isArray(parsed) || parsed.length === 0 || parsed.length > MAX_MANAGER_PROFILES) {
    throw new Error(`AGENT_CAT_MANAGER_PROFILES must be a JSON array of 1 to ${MAX_MANAGER_PROFILES} paths`);
  }
  const profiles: string[] = [];
  parsed.forEach((value, index) => {
    if (typeof value !== "string" || !isAbsolute(value)) throw new Error(`AGENT_CAT_MANAGER_PROFILES[${index}] must be an absolute path`);
    if (profiles.includes(value)) throw new Error(`AGENT_CAT_MANAGER_PROFILES[${index}] is duplicated`);
    profiles.push(value);
  });
  return { kind: "service", profiles };
}

export function stateDirectory(env: NodeJS.ProcessEnv = process.env): string {
  const configured = env.AGENT_CAT_STATE_DIR;
  if (configured) {
    if (!isAbsolute(configured)) throw new Error("AGENT_CAT_STATE_DIR must be absolute");
    return configured;
  }
  const home = env.HOME;
  if (!home) throw new Error("HOME is unavailable and AGENT_CAT_STATE_DIR is not configured");
  return `${home}/.pi/agent/agent-cat`;
}

export function configuredRemote(env: NodeJS.ProcessEnv = process.env): { socket: string; sessionId?: string } | undefined {
  const socket = env.AGENT_CAT_PI_REMOTE_SOCKET;
  const sessionId = env.AGENT_CAT_PI_REMOTE_SESSION;
  if (!socket && !sessionId) return undefined;
  if (!socket) throw new Error("AGENT_CAT_PI_REMOTE_SOCKET is required when a remote session is configured");
  if (!isAbsolute(socket)) throw new Error("AGENT_CAT_PI_REMOTE_SOCKET must be absolute");
  return { socket, sessionId };
}

/**
 * Whether the stream test hooks of service mode are enabled. Only the value
 * `1` of `AGENT_CAT_PI_TEST_HOOKS` enables them. The Pi host harness sets it.
 */
export function testHooksEnabled(env: NodeJS.ProcessEnv = process.env): boolean {
  return env.AGENT_CAT_PI_TEST_HOOKS === "1";
}

export function retentionPolicy(env: NodeJS.ProcessEnv = process.env): { days: number; maxRuns: number } {
  return {
    days: natural(env.AGENT_CAT_RETENTION_DAYS, 30, "AGENT_CAT_RETENTION_DAYS"),
    maxRuns: natural(env.AGENT_CAT_MAX_RUNS, 100, "AGENT_CAT_MAX_RUNS"),
  };
}

function optionalStrings(value: unknown, label: string): string[] {
  if (value === undefined) return [];
  if (!Array.isArray(value) || !value.every((entry) => typeof entry === "string")) throw new Error(`${label} must be a JSON string array`);
  return [...value];
}

function natural(value: string | undefined, fallback: number, name: string): number {
  if (value === undefined) return fallback;
  if (!/^(0|[1-9][0-9]*)$/.test(value)) throw new Error(`${name} must be an unsigned decimal integer`);
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed)) throw new Error(`${name} exceeds JavaScript's safe integer range`);
  return parsed;
}
