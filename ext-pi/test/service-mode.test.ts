/**
 * The service-mode lifecycle of the extension with a fake Pi, a fake UI and
 * the injected fake transport of `test/fixtures/fake-manager.ts`.
 */

import { mkdir, mkdtemp, readdir, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import extension from "../src/index.ts";
import { isJsonObject, jsonMember, parseJson, type JsonValue } from "../src/manager/json.ts";
import {
  capabilities, clientProfiles, control, decision, manager, ok, overview, request, run, transports, UNREACHABLE, type PostRoute, type Reply, type Route,
} from "./fixtures/fake-manager.ts";
import { MANAGER_ROLE_MARKER, ROOT_ROLE_FILE } from "../src/root-role.ts";
import { ServiceMode } from "../src/service-mode.ts";
import { RunSupervisor } from "../src/supervisor.ts";

let directory = "";
let profiles: Awaited<ReturnType<typeof clientProfiles>>;

/** A private client profile for a host. */
function profile(name: string, host: string, fields: Record<string, unknown> = {}): string {
  return profiles.profile(name, host, fields);
}

beforeAll(async () => {
  profiles = await clientProfiles("agent-cat-service-mode-");
  directory = profiles.directory;
});

afterAll(async () => {
  await profiles.remove();
});

const ENVIRONMENT = [
  "AGENT_CAT_MANAGER_PROFILE", "AGENT_CAT_MANAGER_PROFILES", "AGENT_CAT_STATE_DIR", "AGENT_CAT_RUNNER", "AGENTDECK_INSTANCE_ID", "AGENT_CAT_PI_TEST_HOOKS",
];
const saved = Object.fromEntries(ENVIRONMENT.map((name) => [name, process.env[name]]));

afterEach(() => {
  vi.restoreAllMocks();
  for (const name of ENVIRONMENT) {
    if (saved[name] === undefined) delete process.env[name];
    else process.env[name] = saved[name];
  }
});

type Handler = (event: unknown, ctx: unknown) => Promise<unknown>;

/** The extension with a fake Pi and UI. */
function host(hooks: Parameters<typeof extension>[1]) {
  const commands = new Map<string, { handler: (args: string, ctx: unknown) => Promise<void> }>();
  const events = new Map<string, Handler[]>();
  const tools: Array<{ execute: (...args: unknown[]) => Promise<{ content: Array<{ text: string }> }> }> = [];
  const entries: Array<{ type: string; data: unknown }> = [];
  const notices: Array<{ message: string; level: string }> = [];
  const statuses: Array<string | undefined> = [];
  const widgets: unknown[] = [];
  extension({
    registerEntryRenderer: () => {},
    registerCommand: (name: string, command: unknown) => commands.set(name, command as never),
    registerTool: (tool: unknown) => tools.push(tool as never),
    on: (name: string, handler: Handler) => events.set(name, [...(events.get(name) ?? []), handler]),
    appendEntry: (type: string, data: unknown) => entries.push({ type, data }),
    sendUserMessage: () => {},
  } as never, hooks);
  const ui = {
    select: async (_title: string, choices: string[]) => choices[0],
    editor: async () => "subject",
    confirm: async () => true,
    input: async () => "",
    notify: (message: string, level: string) => notices.push({ message, level }),
    setWidget: (_id: string, value: unknown) => widgets.push(value),
    setStatus: (_id: string, value: string | undefined) => statuses.push(value),
    custom: async () => undefined,
  };
  const ctx = {
    cwd: directory, mode: "tui", hasUI: true, isProjectTrusted: () => true, ui, isIdle: () => true, abort: () => {},
    sessionManager: { getBranch: () => [] },
  };
  const fire = async (name: string) => {
    for (const handler of events.get(name) ?? []) await handler({ type: name }, ctx);
  };
  const status = async (): Promise<string> => {
    await commands.get("wfm-status")!.handler("", ctx);
    return notices.at(-1)!.message;
  };
  const widget = (): string => {
    const last = widgets.at(-1);
    if (typeof last !== "function") return "";
    const text = last({}, { fg: (_color: string, value: string) => value }) as { render: (width: number) => string[] };
    return text.render(200).map((line) => line.trimEnd()).join("\n");
  };
  return { commands, ctx, entries, notices, statuses, tools, fire, status, widget };
}

async function until(condition: () => boolean | Promise<boolean>, milliseconds = 5000): Promise<void> {
  const deadline = Date.now() + milliseconds;
  while (!(await condition())) {
    if (Date.now() > deadline) throw new Error("condition not reached");
    await new Promise((wake) => setTimeout(wake, 10));
  }
}

async function localState(): Promise<{ local: string; managerRoot: string }> {
  const root = await mkdtemp(join(directory, "state-"));
  const local = join(root, "local");
  const managerRoot = join(root, "manager");
  await mkdir(join(managerRoot, "runs", "partial"), { recursive: true, mode: 0o700 });
  await writeFile(join(managerRoot, ROOT_ROLE_FILE), MANAGER_ROLE_MARKER, { mode: 0o600 });
  return { local, managerRoot };
}

describe("service mode of the extension", () => {
  it("names the workflow of each service run in the widget and the status from the workflow catalogue", async () => {
    const { local } = await localState();
    process.env.AGENT_CAT_STATE_DIR = local;
    process.env.AGENT_CAT_MANAGER_PROFILE = profile("named", "alpha.test");
    const base = manager([run("run_a1", "running"), request("req_a1")]);
    const expiresAt = new Date(Date.now() + 60000).toISOString();
    const catalogue = {
      version: 1, items: [{ id: "wf_review", name: "review" }],
      page: { setId: "set_w", revision: "workflows_rev", expiresAt, index: 0, totalItems: 1, next: null },
    };
    const fake = transports({ "alpha.test": (resource, count) => (resource === "/v1/workflows?profileId=profile_1" ? ok(catalogue, '"workflows_rev"') : base(resource, count)) });
    const pi = host({ manager: { transport: fake.transport } });
    await pi.fire("session_start");
    await until(() => pi.widget().includes("running run_a1 review"));
    expect(pi.widget()).toBe("Service runs (https://alpha.test:8443/v1)\nrunning run_a1 review");
    const text = await pi.status();
    expect(text).toContain("Service runs:\n  run_a1  running  owned supervision  review");
    expect(text).toContain("Requests:\n  req_a1  draft  review");
    await pi.fire("session_shutdown");
  });

  it("opens one manager session, restores only local runs, and closes the transport without a command", async () => {
    const { local, managerRoot } = await localState();
    process.env.AGENT_CAT_STATE_DIR = local;
    process.env.AGENT_CAT_MANAGER_PROFILE = profile("one", "alpha.test");
    process.env.AGENT_CAT_RUNNER = resolve("test/fixtures/runner.mjs");
    process.env.AGENTDECK_INSTANCE_ID = "current-deck-session";
    const restore = vi.spyOn(RunSupervisor.prototype, "restore");
    const fake = transports({ "alpha.test": manager([run("run_a1", "running"), request("req_a1"), decision("decision_a1", "run_a1")]) });
    const pi = host({ manager: { transport: fake.transport } });
    await pi.fire("session_start");
    await until(async () => (await pi.status()).includes("delivery live"));
    const text = await pi.status();
    expect(text).toMatch(/^Service mode: profile 1 of 1, .*one\.json\nConnection: connected to https:\/\/alpha\.test:8443\/v1 \(endpoint identity [0-9a-f]{32}\), delivery live\n/);
    expect(text).toContain("Service runs:\n  run_a1  running  owned supervision  wf_review");
    expect(text).toContain("Requests:\n  req_a1  draft  wf_review");
    expect(text).toContain("Decision heads:\n  decision_a1  pending question  run run_a1");
    // The service capabilities are the grants of the manager. No local target is offered as one.
    const offered = text.split("\n").find((line) => line.startsWith("Manager capabilities: "));
    expect(offered).toBe("Manager capabilities: scopes observe, submit; profiles profile_1; transports sse, polling");
    expect(offered).not.toMatch(/current|child|deck|acp|remote/i);
    // Restore ran once, for the local state directory only, and the manager root is untouched.
    expect(restore.mock.calls.map(([path]) => path)).toEqual([local]);
    expect((await readdir(managerRoot)).sort()).toEqual([ROOT_ROLE_FILE, "runs"]);
    expect(await readdir(join(managerRoot, "runs"))).toEqual(["partial"]);
    // The widget lists the service run in its own section.
    expect(pi.widget()).toBe("Service runs (https://alpha.test:8443/v1)\nrunning run_a1 wf_review");
    expect(pi.statuses.at(-1)).toBe("1 service run");
    // Local launches keep working in service mode.
    await pi.commands.get("wf")!.handler("fixture", pi.ctx);
    await until(() => pi.entries.length === 1);
    expect(pi.entries[0]).toEqual({ type: "agent-cat-run", data: expect.objectContaining({ status: "succeeded", storeDir: expect.stringContaining(local) }) });
    const [tool] = pi.tools;
    const listed = await tool.execute("call", { action: "status" }, undefined, undefined, pi.ctx);
    expect(JSON.parse(listed.content[0].text)).toEqual([expect.objectContaining({ status: "succeeded" })]);
    // Shutdown closes the transport and sends no manager command.
    await pi.fire("session_shutdown");
    expect(fake.made).toHaveLength(1);
    expect(fake.made[0].closed).toBe(true);
    expect(await pi.status()).toContain("Connection: closed. The manager keeps its runs under its own supervision.");
    // A reload starts a new session and leaves the earlier transport closed.
    await pi.fire("session_start");
    await until(async () => (await pi.status()).includes("delivery live"));
    expect(fake.made).toHaveLength(2);
    expect(restore.mock.calls.map(([path]) => path)).toEqual([local, local]);
    await pi.fire("session_shutdown");
    expect(fake.made.every((made) => made.closed)).toBe(true);
    expect(fake.made.flatMap((made) => made.posts)).toEqual([]);
    // The only reads are the capabilities, the overview and the workflow catalogue that names the workflows of the runs.
    expect(new Set(fake.made.flatMap((made) => made.gets))).toEqual(new Set(["/v1/capabilities", "/v1/snapshot", "/v1/workflows?profileId=profile_1"]));
  });

  it("switches endpoints, discards a late overview of the earlier endpoint, and never retargets a stored reference", async () => {
    let release: (reply: Reply) => void = () => {};
    const held = new Promise<Reply>((resolve) => {
      release = resolve;
    });
    const fake = transports({
      "alpha.test": (resource, count) => resource === "/v1/snapshot" && count > 1 ? held : manager([run("run_a1", "running")])(resource, count),
      "beta.test": manager([run("run_b1", "running")]),
      "gamma.test": () => UNREACHABLE,
    }, ["alpha.test"]);
    const service = new ServiceMode([profile("alpha", "alpha.test"), profile("beta", "beta.test"), profile("gamma", "gamma.test")],
      { session: { transport: fake.transport } });
    expect((await service.start()).kind).toBe("connected");
    const [alpha] = fake.made;
    const stored = service.runs()[0];
    expect(stored.runId).toBe("run_a1");
    const session = service.session!;
    const generation = session.generation;
    // An invalidation reads the overview of alpha again, and that read is held.
    alpha.emit("s.2", "/v1/runs/run_a1");
    await until(() => alpha.gets.filter((uri) => uri === "/v1/snapshot").length === 2);
    const switched = await service.select(1);
    expect(switched.kind).toBe("connected");
    const beta = fake.made[1];
    expect(session.generation).toBeGreaterThan(generation);
    expect(service.runs().map((view) => [view.runId, view.endpoint])).toEqual([["run_b1", session.identity]]);
    // The late overview of alpha arrives after the switch and is never installed.
    release(ok(overview("s.2", [run("run_a2", "running")])));
    await until(() => alpha.late.filter((uri) => uri === "/v1/snapshot").length === 2);
    await new Promise((wake) => setTimeout(wake, 50));
    expect(service.runs().map((view) => view.runId)).toEqual(["run_b1"]);
    // A stored reference of alpha is refused and never sent to beta.
    expect(await session.get(stored.reference)).toEqual({ ok: false, failure: { kind: "WrongEndpoint" } });
    expect(beta.gets).not.toContain(stored.reference.uri);
    expect(alpha.closed).toBe(true);
    // A switch to an unreachable endpoint keeps beta active.
    const kept = await service.select(2);
    expect(kept).toMatchObject({ kind: "kept", reason: "the manager does not answer" });
    expect(service.active).toBe(1);
    expect(service.connection).toMatchObject({ kind: "connected", endpoint: "https://beta.test:8443/v1" });
    expect(service.runs().map((view) => view.runId)).toEqual(["run_b1"]);
    await service.close();
    expect(fake.made.every((made) => made.closed)).toBe(true);
    expect(fake.made.flatMap((made) => made.posts)).toEqual([]);
  });

  it("commits a switch only after the overview of the new endpoint loads, and otherwise keeps the earlier binding", async () => {
    const answering = (items: unknown[]): Route => (resource, count) =>
      resource.startsWith("/v1/runs/") ? ok({ version: 1 }, '"rev-1"') : manager(items)(resource, count);
    const fake = transports({
      "alpha.test": answering([run("run_a1", "running")]),
      // Gamma grants its capabilities, and its first overview read fails.
      "gamma.test": (resource) => resource === "/v1/capabilities" ? ok(capabilities()) : UNREACHABLE,
      "beta.test": answering([run("run_b1", "running")]),
    });
    const service = new ServiceMode([profile("alpha", "alpha.test"), profile("gamma", "gamma.test"), profile("beta", "beta.test")],
      { session: { transport: fake.transport } });
    // No outcome reports a connection while the follow loop has ended.
    const reports: string[] = [];
    service.subscribe(() => {
      if (service.connection.kind === "connected" && service.session?.followEnd !== undefined) reports.push(service.connection.identity);
    });
    expect((await service.start()).kind).toBe("connected");
    const session = service.session!;
    const [alpha] = fake.made;
    const before = { endpoint: session.endpoint, identity: session.identity, generation: session.generation };
    const watched = session.reference("/v1/runs/run_a1");
    if (!watched.ok) throw new Error("reference refused");
    const reads = (transport: { gets: string[] }, uri: string) => transport.gets.filter((get) => get === uri).length;
    expect(session.watch(watched.value).ok).toBe(true);
    await until(() => reads(alpha, "/v1/runs/run_a1") === 1);

    const kept = await service.select(1);
    expect(kept).toMatchObject({
      kind: "kept", reason: "the manager does not answer",
      connection: { kind: "connected", endpoint: "https://alpha.test:8443/v1", identity: before.identity },
    });
    expect(service.active).toBe(0);
    expect(session.followEnd).toBeUndefined();
    expect({ endpoint: session.endpoint, identity: session.identity, generation: session.generation }).toEqual(before);
    expect(service.runs().map((view) => [view.runId, view.endpoint])).toEqual([["run_a1", before.identity]]);
    // The new transport of the refused switch is closed, and nothing reaches it later.
    const gamma = fake.made[1];
    expect(gamma.closed).toBe(true);
    expect(gamma.gets).toEqual(["/v1/capabilities", "/v1/snapshot"]);
    expect(alpha.closed).toBe(false);
    // The follow loop of alpha still runs, and its watched resource is read again.
    alpha.emit("s.2", "/v1/runs/run_a1");
    await until(() => reads(alpha, "/v1/runs/run_a1") === 2);
    expect((await session.get(watched.value)).ok).toBe(true);
    expect(gamma.gets).toEqual(["/v1/capabilities", "/v1/snapshot"]);

    // A switch whose overview loads commits the new binding with that overview.
    const switched = await service.select(2);
    expect(switched).toMatchObject({ kind: "connected", connection: { kind: "connected", endpoint: "https://beta.test:8443/v1" } });
    const beta = fake.made[2];
    expect(alpha.closed).toBe(true);
    expect(session.followEnd).toBeUndefined();
    expect(session.identity).not.toBe(before.identity);
    const installed = session.overview;
    if (installed === undefined || !installed.ok) throw new Error("overview not installed");
    expect(installed.value.items.map((item) => [item.reference.uri, item.reference.endpoint])).toEqual([["/v1/runs/run_b1", session.identity]]);
    expect((await session.get(installed.value.items[0].reference)).ok).toBe(true);
    expect(await session.get(watched.value)).toEqual({ ok: false, failure: { kind: "WrongEndpoint" } });
    expect(beta.gets).not.toContain("/v1/runs/run_a1");
    // The follow loop continues on beta.
    expect(session.watch(installed.value.items[0].reference).ok).toBe(true);
    await until(() => reads(beta, "/v1/runs/run_b1") === 2);
    beta.emit("s.2", "/v1/runs/run_b1");
    await until(() => reads(beta, "/v1/runs/run_b1") === 3);
    expect(reports).toEqual([]);
    await service.close();
    expect(fake.made.every((made) => made.closed)).toBe(true);
    expect(fake.made.flatMap((made) => made.posts)).toEqual([]);
  });

  it("switches the endpoint through /wfm-endpoints", async () => {
    const { local } = await localState();
    process.env.AGENT_CAT_STATE_DIR = local;
    process.env.AGENT_CAT_MANAGER_PROFILES = JSON.stringify([profile("first", "alpha.test"), profile("second", "beta.test")]);
    const fake = transports({ "alpha.test": manager([run("run_a1", "running")]), "beta.test": manager([run("run_b1", "succeeded")]) });
    const pi = host({ manager: { transport: fake.transport } });
    await pi.fire("session_start");
    await until(async () => (await pi.status()).includes("run_a1"));
    await pi.commands.get("wfm-endpoints")!.handler("2", pi.ctx);
    expect(pi.notices.at(-1)).toEqual({ message: "Manager connected: https://beta.test:8443/v1", level: "info" });
    const text = await pi.status();
    expect(text).toMatch(/^Service mode: profile 2 of 2, .*second\.json\n/);
    expect(text).toContain("  run_b1  succeeded  owned supervision  wf_review");
    expect(text).not.toContain("run_a1");
    // A terminal service run is not active, so the widget is empty.
    expect(pi.widget()).toBe("");
    await pi.fire("session_shutdown");
    expect(fake.made.flatMap((made) => made.posts)).toEqual([]);
  });

  it("shows a refused credential at session start and starts no mutation", async () => {
    const { local } = await localState();
    process.env.AGENT_CAT_STATE_DIR = local;
    process.env.AGENT_CAT_MANAGER_PROFILE = profile("refused", "alpha.test");
    const fake = transports({ "alpha.test": () => ({ ok: false, failure: { kind: "Refused", status: 401, code: "unauthenticated" } }) });
    const pi = host({ manager: { transport: fake.transport } });
    await pi.fire("session_start");
    await until(() => pi.notices.some((notice) => notice.level === "error"));
    expect(pi.notices.at(-1)).toEqual({ message: "Manager refused: the manager refused the credential (401 unauthenticated)", level: "error" });
    const text = await pi.status();
    expect(text).toContain("Connection: refused for ");
    expect(text).toContain("the manager refused the credential (401 unauthenticated). No manager command is sent.");
    expect(text).toContain("Service runs: none");
    expect(fake.made.flatMap((made) => made.gets)).toEqual(["/v1/capabilities"]);
    expect(fake.made.flatMap((made) => made.posts)).toEqual([]);
    expect(fake.made[0].closed).toBe(true);
    await pi.fire("session_shutdown");
  });

  it("notifies a credential that the manager refuses during the session, and a later /wfm starts nothing", async () => {
    const { local } = await localState();
    process.env.AGENT_CAT_STATE_DIR = local;
    process.env.AGENT_CAT_MANAGER_PROFILE = profile("revoked", "alpha.test");
    const fake = transports({ "alpha.test": manager([run("run_a1", "running")]) });
    const pi = host({ manager: { transport: fake.transport } });
    await pi.fire("session_start");
    await until(async () => (await pi.status()).includes("delivery live"));
    const before = pi.notices.length;
    // The manager revokes the credential, and the follow loop ends with the refusal.
    fake.made[0].end({ kind: "refused", cursor: "s.1", failure: { kind: "Refused", status: 401, code: "unauthenticated" } });
    await until(() => pi.notices.slice(before).some((notice) => notice.level === "error"));
    expect(pi.notices.slice(before)).toEqual([{
      message: "Manager refused: the manager refused the credential (401 unauthenticated). No manager command is sent.", level: "error",
    }]);
    await pi.commands.get("wfm")!.handler("", pi.ctx);
    expect(pi.notices.at(-1)).toEqual({ message: "The manager is not connected. /wfm-status states the connection.", level: "error" });
    const text = await pi.status();
    expect(text).toContain("the manager refused the credential (401 unauthenticated). No manager command is sent.");
    expect(text).toContain("Service runs: none");
    expect(fake.made.flatMap((made) => made.posts)).toEqual([]);
    await pi.fire("session_shutdown");
  });

  it("offers the stream test hooks only when AGENT_CAT_PI_TEST_HOOKS is 1, and lists the events delivered after a forced drop", async () => {
    const { local } = await localState();
    process.env.AGENT_CAT_STATE_DIR = local;
    process.env.AGENT_CAT_MANAGER_PROFILE = profile("hooks", "alpha.test");
    const plain = host({ manager: { transport: transports({ "alpha.test": manager([]) }).transport } });
    expect([plain.commands.has("wfm-debug-reconnect"), plain.commands.has("wfm-debug-events")]).toEqual([false, false]);
    process.env.AGENT_CAT_PI_TEST_HOOKS = "1";
    const fake = transports({ "alpha.test": manager([run("run_a1", "running")]) });
    const pi = host({ manager: { transport: fake.transport } });
    await pi.fire("session_start");
    await until(async () => (await pi.status()).includes("delivery live"));
    const [made] = fake.made;
    made.emit("s.2", "/v1/runs/run_a1");
    await pi.commands.get("wfm-debug-reconnect")!.handler("", pi.ctx);
    expect(made.drops).toBe(1);
    expect(pi.notices.at(-1)).toEqual({ message: "Test hook: dropped the event stream after event s.2", level: "info" });
    made.emit("s.3", "/v1/runs/run_a1");
    made.emit("s.5", "/v1/runs/run_a1");
    await pi.commands.get("wfm-debug-events")!.handler("", pi.ctx);
    expect(pi.notices.at(-1)).toEqual({
      message: "Test hook: event stream dropped after event s.2\nConnections after the drop: none\nEvents delivered after the drop: 2 of stream s: 3 5",
      level: "info",
    });
    expect(made.posts).toEqual([]);
    await pi.fire("session_shutdown");
  });

  it.each([
    ["an unsupported profile", () => profile("unsupported", "alpha.test", { version: 2 }), "refused", "unsupported profile (InvalidClientProfile)", 0],
    ["an unsupported capability version", () => profile("version", "version.test"), "refused",
      "the manager offers no capability version that this client supports", 1],
    ["an unreachable manager", () => profile("unreachable", "gamma.test"), "unreachable", "the manager does not answer", 1],
  ] as const)("shows the refusal state of %s and sends nothing else", async (_name, path, kind, reason, connections) => {
    const fake = transports({
      "alpha.test": manager([]),
      "version.test": (resource) => resource === "/v1/capabilities" ? ok(capabilities({ api: [2] })) : manager([])(resource, 1),
      "gamma.test": () => UNREACHABLE,
    });
    const service = new ServiceMode([path()], { session: { transport: fake.transport } });
    expect(await service.start()).toEqual({ kind: "failed", connection: { kind, profile: service.profiles[0], reason } });
    expect(fake.made).toHaveLength(connections);
    expect(fake.made.flatMap((made) => made.gets)).toEqual(connections === 0 ? [] : ["/v1/capabilities"]);
    expect(fake.made.every((made) => made.closed && made.posts.length === 0)).toBe(true);
    expect(service.runs()).toEqual([]);
    await service.close();
  });

  describe("reconciliation of an uncertain answer or recovery choice", () => {
    const DECISION_URI = "/v1/decisions/decision_a1";
    const CONTROL_URI = "/v1/runs/run_a1/control";
    const SNAPSHOT_URI = "/v1/runs/run_a1/snapshot";
    /** The manager serves only pending decisions, so an answered decision reads as 404. */
    const ANSWERED: Reply = { ok: false, failure: { kind: "Refused", status: 404, code: "unavailable-resource" } };

    const flag = (decision("decision_a1", "run_a1") as { decision: Record<string, unknown> }).decision;
    const text = { ...flag, question: { ...(flag.question as Record<string, unknown>), code: "text", semanticSchema: null } };
    const recovery = Object.fromEntries([...Object.entries(flag).filter(([name]) => name !== "question"),
      ["kind", "recovery"], ["gap", "transport"], ["message", "Recovery needs an operator choice."], ["choices", [{ choice: "abandon", target: null }]]]);

    /** The run snapshot of run_a1 with occurrence 0. */
    function snapshotOf(status: string, occurrence: Record<string, unknown> = {}): unknown {
      return {
        snapshotVersion: 1, runId: "run_a1", runtime: { status, lastSequence: "9", protocolVersion: 2 },
        items: [{ occurrenceId: "0", state: "running", code: "flag", answer: null, decisionId: "decision_a1", personPending: true, attempts: [], ...occurrence }],
      };
    }

    /** The controls of run_a1. */
    function controlsOf(fields: Record<string, unknown> = {}): unknown {
      return { ...(control("run_a1", "decision_a1") as Record<string, unknown>), ...fields };
    }

    const RECOVERY_CONTROLS = controlsOf({
      offers: [{ operation: "choose-recovery", address: { occurrenceId: "0" }, generation: "generation_3", timings: [], choices: [{ choice: "abandon", target: null }], targets: [] }],
    });

    type Case = {
      readonly head: Record<string, unknown>;
      readonly typed: string;
      readonly controls?: unknown;
      readonly snapshotAfter?: Reply;
      readonly controlAfter?: Reply;
    };

    /**
     * Answer the head of run_a1 once. The POST fails as a lost connection
     * does, so the send is uncertain. The first read of each resource gives
     * its state before the send, and every later read its state after it.
     */
    async function uncertainSend(fixture: Case) {
      const { local } = await localState();
      process.env.AGENT_CAT_STATE_DIR = local;
      process.env.AGENT_CAT_MANAGER_PROFILE = profile("answer", "alpha.test");
      const base = manager([run("run_a1", "running"), decision("decision_a1", "run_a1")]);
      const fake = transports({
        "alpha.test": (resource, count) => {
          if (resource === "/v1/capabilities") return ok(capabilities({}, ["observe", "submit", "control"]));
          if (resource === "/v1/decisions?runId=run_a1") {
            const page = { setId: "set_q", revision: "rev_q", expiresAt: new Date(Date.now() + 60000).toISOString(), index: 0, totalItems: 1, next: null };
            return ok({ version: 1, page, items: [fixture.head] });
          }
          if (resource === DECISION_URI) return count === 1 ? ok(fixture.head, '"decision_a1_rev"') : ANSWERED;
          if (resource === CONTROL_URI) return count === 1 ? ok(fixture.controls ?? controlsOf(), '"control_rev"') : fixture.controlAfter ?? ANSWERED;
          if (resource === SNAPSHOT_URI) return count === 1 ? ok(snapshotOf("running"), '"snapshot_rev"') : fixture.snapshotAfter ?? ANSWERED;
          return base(resource, count);
        },
      });
      const pi = host({ manager: { transport: fake.transport } });
      Object.assign(pi.ctx.ui, { editor: async () => fixture.typed, select: async (_title: string, choices: string[]) => choices[0] });
      await pi.fire("session_start");
      await until(async () => (await pi.status()).includes("delivery live"));
      const before = pi.notices.length;
      await pi.commands.get("wfm-answer")!.handler("run_a1", pi.ctx);
      const [made] = fake.made;
      const notices = pi.notices.slice(before).map((notice) => notice.message);
      const status = await pi.status();
      await pi.fire("session_shutdown");
      const reads = (uri: string) => made.gets.filter((get) => get === uri).length;
      return { made, notices, status, reads };
    }

    it.each([
      ["the occurrence stores the sent answer", ok(snapshotOf("running", { state: "completed", answer: "no", personPending: false }), '"snapshot_rev_2"'), "accepted"],
      ["the occurrence stores the answer of another client", ok(snapshotOf("running", { state: "completed", answer: "yes", personPending: false }), '"snapshot_rev_2"'), "uncertain"],
      ["the occurrence still waits on the decision", ok(snapshotOf("running"), '"snapshot_rev_2"'), "uncertain"],
      ["the run failed without the answer", ok(snapshotOf("failed", { state: "failed", answer: "transport lost", personPending: false }), '"snapshot_rev_2"'), "uncertain"],
      ["the run was cancelled without the answer", ok(snapshotOf("cancelled", { state: "cancelled", personPending: false }), '"snapshot_rev_2"'), "uncertain"],
      ["the snapshot keeps the entity tag of the read before the send", ok(snapshotOf("running", { state: "completed", answer: "no", personPending: false }), '"snapshot_rev"'), "uncertain"],
      ["the snapshot read fails", { ok: false, failure: { kind: "TransportUnavailable" } } as Reply, "uncertain"],
    ] as const)("reconciles an uncertain flag answer from the occurrence of the run snapshot when %s", async (_name, snapshotAfter, outcome) => {
      const { made, notices, status, reads } = await uncertainSend({ head: flag, typed: "  No ", snapshotAfter });
      // One POST of the typed JSON false, bound to the decision revision that was read, and never sent again.
      expect(made.posts).toEqual([DECISION_URI]);
      expect(made.bodies).toEqual([{ body: '{"generation":"generation_3","occurrenceId":"0","operation":"answer","value":false}', ifMatch: '"decision_a1_rev"' }]);
      // The snapshot is read once before the send and once to reconcile. The decision and the controls are read only for the head.
      expect([reads(SNAPSHOT_URI), reads(DECISION_URI), reads(CONTROL_URI)]).toEqual([2, 1, 1]);
      const record = notices.find((line) => line.startsWith("Command answer "));
      expect(record).toContain(outcome === "accepted"
        ? `Command answer accepted: the send was uncertain (TransportUnavailable), and one read of ${SNAPSHOT_URI} observes its effect.`
        : `Command answer uncertain: TransportUnavailable. One read of ${SNAPSHOT_URI} does not settle it. The command is not sent again.`);
      expect(notices.includes("Answer false reached decision decision_a1 of run run_a1.")).toBe(outcome === "accepted");
      expect(status).toMatch(new RegExp(`\n {2}answer {2}${outcome} {2}`));
    });

    it.each([
      ["the running run moved its head to a later decision", ok(controlsOf({ decisionHeadId: "decision_a2" }), '"control_rev_2"'), "accepted"],
      ["the head is unchanged", ok(controlsOf(), '"control_rev_2"'), "uncertain"],
      ["the controls keep the entity tag of the read before the send", ok(controlsOf({ decisionHeadId: "decision_a2" }), '"control_rev"'), "uncertain"],
      ["the run has no head", ok(controlsOf({ decisionHeadId: null }), '"control_rev_2"'), "uncertain"],
      ["the run is terminal", ok(controlsOf({ decisionHeadId: "decision_a2", cancelAllowed: false, offers: [] }), '"control_rev_2"'), "uncertain"],
    ] as const)("reconciles an uncertain answer that the snapshot does not store whole from the controls when %s", async (_name, controlAfter, outcome) => {
      // The runtime stores a text answer on one line, so a two-line answer is not stored whole.
      const { made, notices, status, reads } = await uncertainSend({ head: text, typed: "first line\nsecond line", controlAfter });
      expect(made.posts).toEqual([DECISION_URI]);
      expect(made.bodies.map((sent) => sent.ifMatch)).toEqual(['"decision_a1_rev"']);
      expect([reads(SNAPSHOT_URI), reads(DECISION_URI), reads(CONTROL_URI)]).toEqual([0, 1, 2]);
      const record = notices.find((line) => line.startsWith("Command answer "));
      expect(record).toContain(outcome === "accepted"
        ? `and one read of ${CONTROL_URI} observes its effect.` : `One read of ${CONTROL_URI} does not settle it. The command is not sent again.`);
      expect(status).toMatch(new RegExp(`\n {2}answer {2}${outcome} {2}`));
    });

    it.each([
      ["the abandoned run names no head", ok(controlsOf({ decisionHeadId: null, cancelAllowed: false, offers: [] }), '"control_rev_2"'), "accepted"],
      ["the run moved its head to a later decision", ok(controlsOf({ decisionHeadId: "decision_a2" }), '"control_rev_2"'), "accepted"],
      ["the failed run still names the recovery decision", ok(controlsOf({ cancelAllowed: false, offers: [] }), '"control_rev_2"'), "uncertain"],
      ["the controls keep the entity tag of the read before the send", ok(controlsOf({ decisionHeadId: null }), '"control_rev"'), "uncertain"],
    ] as const)("reconciles an uncertain recovery choice from the controls when %s", async (_name, controlAfter, outcome) => {
      const { made, notices, status, reads } = await uncertainSend({ head: recovery, typed: "", controls: RECOVERY_CONTROLS, controlAfter });
      expect(made.posts).toEqual([DECISION_URI]);
      expect(made.bodies).toEqual([{ body: '{"choice":"abandon","generation":"generation_3","occurrenceId":"0","operation":"choose-recovery"}', ifMatch: '"decision_a1_rev"' }]);
      expect([reads(SNAPSHOT_URI), reads(DECISION_URI), reads(CONTROL_URI)]).toEqual([0, 1, 2]);
      const record = notices.find((line) => line.startsWith("Command choose-recovery "));
      expect(record).toContain(outcome === "accepted"
        ? `and one read of ${CONTROL_URI} observes its effect.` : `One read of ${CONTROL_URI} does not settle it. The command is not sent again.`);
      expect(notices.includes("Recovery Abandon reached decision decision_a1 of run run_a1.")).toBe(outcome === "accepted");
      expect(status).toMatch(new RegExp(`\n {2}choose-recovery {2}${outcome} {2}`));
    });
  });

  describe("run controls of /wfm-cancel, /wfm-steer and /wfm-redirect", () => {
    const ACCEPTED_AT = "2026-10-01T12:00:00Z";

    /** A command receipt of run_a1 with its acknowledgement and effect. */
    function receipt(operation: string, state: string, ack: [string, string] | null, effect: string | null): unknown {
      return {
        version: 1, id: "cmd_1", profileId: "profile_1", operation, requiredScopes: ["control"], resource: "/v1/runs/run_a1/control", state,
        acceptedAt: ACCEPTED_AT, dispatchAttemptedAt: state === "accepted" ? null : ACCEPTED_AT,
        acknowledgement: ack === null ? null : {
          commandId: "cmd_1", state: ack[0], message: ack[1], command: operation,
          occurrenceId: operation === "cancel" ? null : "0", attemptId: operation === "steer" ? "0" : null,
        },
        effect: effect === null ? null : {
          kind: effect, runtimeSequence: "12", address: operation === "steer" ? { occurrenceId: "0", attemptId: "0" } : { occurrenceId: "0" },
          resource: "/v1/runs/run_a1",
        },
        refusal: null, links: { self: "/v1/commands/cmd_1", resource: "/v1/runs/run_a1/control" },
      };
    }

    function controls(offers: unknown[], fields: Record<string, unknown> = {}): unknown {
      return { version: 1, runId: "run_a1", revision: "run_a1_control", supervision: "owned", cancelAllowed: true, decisionHeadId: null, offers, ...fields };
    }

    const REDIRECT = { operation: "redirect", address: { occurrenceId: "0" }, generation: null, timings: [], choices: [], targets: ["model controlled@spare"] };
    const STEER = { operation: "steer", address: { occurrenceId: "0", attemptId: "0" }, generation: null, timings: ["interrupt-now", "next-boundary"], choices: [], targets: [] };

    /** The extension over one manager whose controls and settled receipt the case gives. */
    async function controlled(control: unknown, settled: unknown, snapshot: unknown) {
      const { local } = await localState();
      process.env.AGENT_CAT_STATE_DIR = local;
      process.env.AGENT_CAT_MANAGER_PROFILE = profile("controls", "alpha.test");
      const base = manager([run("run_a1", "running")]);
      const fake = transports({
        "alpha.test": (resource, count) => {
          if (resource === "/v1/capabilities") return ok(capabilities({}, ["observe", "submit", "control"]));
          if (resource === "/v1/runs/run_a1/control") return ok(control, '"control_rev"');
          if (resource === "/v1/runs/run_a1/snapshot") return ok(snapshot, '"snapshot_rev"');
          if (resource === "/v1/commands/cmd_1") return ok(settled);
          return base(resource, count);
        },
      }, [], {
        "alpha.test": (resource, body) => {
          const operation = isJsonObject(body) ? jsonMember(body, "operation") : undefined;
          const accepted = JSON.stringify(receipt(String(operation), "accepted", null, null));
          return resource === "/v1/runs/run_a1/control"
            ? { ok: true, value: { status: 202, value: parseJson(accepted) as JsonValue, etag: null, location: "/v1/commands/cmd_1", bytes: accepted.length } }
            : undefined;
        },
      });
      const pi = host({ manager: { transport: fake.transport } });
      await pi.fire("session_start");
      await until(async () => (await pi.status()).includes("delivery live"));
      return { pi, made: () => fake.made[0] };
    }

    const running = { items: [{ occurrenceId: "0", dispatch: null, attempts: [{ address: { occurrenceId: "0", attemptId: "0" }, state: "running" }] }] };
    const windowOpen = { items: [{ occurrenceId: "0", dispatch: { targets: ["model controlled@spare"], open: true, redirect: null }, attempts: [] }] };

    it("sends the live redirect of the attempt in flight and reports the receipt, then the delivered acknowledgement", async () => {
      const { pi, made } = await controlled(controls([REDIRECT]),
        receipt("redirect", "effect-observed", ["delivered", "redirect delivered to the in-flight attempt"], "redirected"), running);
      const titles: string[][] = [];
      Object.assign(pi.ctx.ui, { select: async (_title: string, choices: string[]) => (titles.push(choices), choices[0]) });
      const before = pi.notices.length;
      await pi.commands.get("wfm-redirect")!.handler("run_a1", pi.ctx);
      expect(titles).toEqual([["model controlled@spare  occurrence 0, attempt 0 in flight"]]);
      expect(made().posts).toEqual(["/v1/runs/run_a1/control"]);
      expect(made().bodies).toEqual([{ body: '{"occurrenceId":"0","operation":"redirect","target":"model controlled@spare"}', ifMatch: '"control_rev"' }]);
      expect(pi.notices.slice(before).map((notice) => notice.message)).toEqual([
        "Command redirect accepted: command cmd_1, receipt effect-observed (redirected)",
        "Acknowledgement of command cmd_1: delivered: redirect delivered to the in-flight attempt",
        "Redirected occurrence 0 of run run_a1 from attempt 0 to model controlled@spare.",
      ]);
      await pi.fire("session_shutdown");
    });

    it("reports a rejected-stale acknowledgement of a redirect verbatim and states no redirect", async () => {
      const { pi, made } = await controlled(controls([REDIRECT]),
        receipt("redirect", "acknowledged", ["rejected-stale", "redirect target is not a live candidate that remains in the approved fail-over chain"], null), windowOpen);
      const titles: string[][] = [];
      Object.assign(pi.ctx.ui, { select: async (_title: string, choices: string[]) => (titles.push(choices), choices[0]) });
      const before = pi.notices.length;
      await pi.commands.get("wfm-redirect")!.handler("run_a1", pi.ctx);
      expect(titles).toEqual([["model controlled@spare  occurrence 0, dispatch window open"]]);
      expect(made().posts).toEqual(["/v1/runs/run_a1/control"]);
      expect(pi.notices.slice(before)).toEqual([
        { message: "Command redirect accepted: command cmd_1, receipt acknowledged", level: "info" },
        { message: "Acknowledgement of command cmd_1: rejected-stale: redirect target is not a live candidate that remains in the approved fail-over chain", level: "warning" },
      ]);
      await pi.fire("session_shutdown");
    });

    it("steers the offered attempt with the editor text and timing and reports the receipt and the acknowledgement", async () => {
      const { pi, made } = await controlled(controls([STEER]),
        receipt("steer", "effect-observed", ["delivered", "steer delivered"], "steered"), running);
      const titles: string[] = [];
      Object.assign(pi.ctx.ui, {
        select: async (title: string, choices: string[]) => (titles.push(`${title}: ${choices.join(", ")}`), choices[1]),
        editor: async (title: string) => (titles.push(title), "Focus on the tests"),
      });
      const before = pi.notices.length;
      await pi.commands.get("wfm-steer")!.handler("run_a1", pi.ctx);
      expect(titles).toEqual(["Steering text for occurrence 0 attempt 0 of run run_a1", "Steering timing: interrupt-now, next-boundary"]);
      expect(made().bodies).toEqual([{
        body: '{"attemptId":"0","occurrenceId":"0","operation":"steer","text":"Focus on the tests","timing":"next-boundary"}', ifMatch: '"control_rev"',
      }]);
      expect(pi.notices.slice(before).map((notice) => notice.message)).toEqual([
        "Command steer accepted: command cmd_1, receipt effect-observed (steered)",
        "Acknowledgement of command cmd_1: delivered: steer delivered",
        "Steer next-boundary reached occurrence 0 attempt 0 of run run_a1.",
      ]);
      await pi.fire("session_shutdown");
    });

    it("cancels after confirmation, reports the receipt and the accepting acknowledgement, and then the cancelled run", async () => {
      const { pi, made } = await controlled(controls([]), receipt("cancel", "acknowledged", ["accepted", "cancellation accepted"], null),
        { items: [], runtime: { status: "cancelled", lastSequence: "9", protocolVersion: 2 } });
      const confirmations: string[] = [];
      Object.assign(pi.ctx.ui, { confirm: async (title: string, message: string) => (confirmations.push(`${title} ${message}`), true) });
      const before = pi.notices.length;
      await pi.commands.get("wfm-cancel")!.handler("run_a1", pi.ctx);
      expect(confirmations).toEqual(["Cancel manager run? run_a1"]);
      expect(made().bodies).toEqual([{ body: '{"operation":"cancel"}', ifMatch: '"control_rev"' }]);
      expect(pi.notices.slice(before).map((notice) => notice.message)).toEqual([
        "Command cancel accepted: command cmd_1, receipt acknowledged",
        "Acknowledgement of command cmd_1: accepted: cancellation accepted",
        "Execution: run run_a1 is cancelled.",
      ]);
      await pi.fire("session_shutdown");
    });

    it.each([
      ["no offers", controls([], { cancelAllowed: false })],
      ["controls that the manager does not own", controls([REDIRECT, STEER], { supervision: "lost" })],
    ])("sends no control for %s", async (_name, control) => {
      const { pi, made } = await controlled(control, receipt("cancel", "accepted", null, null), running);
      for (const [command, operation] of [["wfm-cancel", "cancel"], ["wfm-steer", "steer"], ["wfm-redirect", "redirect"]] as const) {
        await pi.commands.get(command)!.handler("run_a1", pi.ctx);
        expect(pi.notices.at(-1)).toEqual({ message: `The manager offers no ${operation} for run run_a1. Nothing was sent.`, level: "warning" });
      }
      expect(made().posts).toEqual([]);
      await pi.fire("session_shutdown");
    });
  });

  describe("history, lineage and exports of /wfm-history, /wfm-fork and /wfm-export", () => {
    const PAGE = { setId: "set_runs", revision: "runs_rev", index: 0, totalItems: 3 };

    function runItem(id: string, fields: Record<string, unknown> = {}): unknown {
      return { ...(run(id, "succeeded") as { run: Record<string, unknown> }).run, ...fields };
    }

    const LEGACY = runItem("run_z9", {
      requestId: null, manifest: { kind: "legacy" }, runtime: null, supervision: "observer", verification: { state: "verified", artifactId: "artifact_4" },
      limitations: ["legacy"],
    });

    /** The extension over one manager with these extra routes and an optional POST route. */
    async function served(routes: Record<string, unknown>, postRoute?: PostRoute) {
      const { local } = await localState();
      process.env.AGENT_CAT_STATE_DIR = local;
      process.env.AGENT_CAT_MANAGER_PROFILE = profile("history", "alpha.test");
      const base = manager([run("run_a1", "succeeded")]);
      const fake = transports({
        "alpha.test": (resource, count) => {
          const route = routes[resource];
          if (route !== undefined) return ok(route, `"${resource.split("/").at(-1)}_rev"`);
          return base(resource, count);
        },
      }, [], postRoute === undefined ? {} : { "alpha.test": postRoute });
      const pi = host({ manager: { transport: fake.transport } });
      await pi.fire("session_start");
      await until(async () => (await pi.status()).includes("delivery live"));
      return { pi, made: () => fake.made[0] };
    }

    function lineagePage(eligible: string[], refusal: string | null): unknown {
      return {
        version: 1, runId: "run_a1", eligible, refusal, items: [],
        page: { setId: "set_l", revision: "lineage-requests_rev", expiresAt: new Date(Date.now() + 60000).toISOString(), index: 0, totalItems: 0, next: null },
      };
    }

    it("lists every run over all pages of /v1/runs and labels the legacy entry observer", async () => {
      const expiresAt = new Date(Date.now() + 60000).toISOString();
      const { pi, made } = await served({
        "/v1/workflows?profileId=profile_1": {
          version: 1, items: [{ id: "wf_review", name: "review" }], page: { ...PAGE, setId: "set_w", revision: "workflows_rev", expiresAt, totalItems: 1, next: null },
        },
        "/v1/runs": { version: 1, items: [runItem("run_a1")], page: { ...PAGE, expiresAt, next: "/v1/runs?pageToken=page_2" } },
        "/v1/runs?pageToken=page_2": {
          version: 1, items: [runItem("run_b2", { requestId: "req_c1", parentRunId: "run_a1", lineage: "restart" }), LEGACY],
          page: { ...PAGE, expiresAt, index: 1, next: null },
        },
      });
      await pi.commands.get("wfm-history")!.handler("", pi.ctx);
      expect(made().gets.filter((uri) => uri.startsWith("/v1/runs"))).toEqual(["/v1/runs", "/v1/runs?pageToken=page_2"]);
      expect(pi.notices.at(-1)).toEqual({
        level: "info",
        message: [
          "History: 2 managed runs and 1 observer entries",
          "  run_a1  review  profile profile_1  succeeded, supervision owned, result absent",
          "  run_b2  review  profile profile_1  succeeded, supervision owned, restart of run run_a1, result absent",
          "  run_z9  review  profile profile_1  no runtime evidence, observer (legacy entry, read only), result verified",
        ].join("\n"),
      });
      expect(made().posts).toEqual([]);
      await pi.fire("session_shutdown");
    });

    it("keeps the workflow identifier when the catalogue does not name the workflow", async () => {
      const expiresAt = new Date(Date.now() + 60000).toISOString();
      const { pi } = await served({
        "/v1/runs": { version: 1, items: [runItem("run_a1")], page: { ...PAGE, expiresAt, totalItems: 1, next: null } },
      });
      await pi.commands.get("wfm-history")!.handler("", pi.ctx);
      expect(pi.notices.at(-1)).toEqual({
        level: "info",
        message: [
          "History: 1 managed runs and 0 observer entries",
          "  run_a1  wf_review  profile profile_1  succeeded, supervision owned, result absent",
          "Workflow names: the catalogue could not be read (404 not-found)",
        ].join("\n"),
      });
      await pi.fire("session_shutdown");
    });

    it("sends a fork with a typed replacement and a drop, bound to the lineage collection, and sends it once", async () => {
      const { pi, made } = await served({
        "/v1/runs/run_a1/lineage-requests": lineagePage(["restart", "resume", "fork"], null),
        "/v1/runs/run_a1/snapshot": {
          items: [
            { occurrenceId: "1", state: "completed", code: "text", intent: "Summarize", answer: "old summary" },
            { occurrenceId: "0", state: "completed", code: "flag", intent: "Confirm", answer: "true" },
            { occurrenceId: "2", state: "running", code: "text", intent: "Later", answer: null },
          ],
        },
      }, () => ({ ok: false, failure: { kind: "Refused", status: 412, code: "stale-revision" } }));
      const asked: string[] = [];
      let lists = 0;
      Object.assign(pi.ctx.ui, {
        select: async (title: string, choices: string[]) => {
          asked.push(`${title}: ${choices.join(" | ")}`);
          if (title.startsWith("Answer of occurrence 0")) return "Replace the answer";
          if (title.startsWith("Answer of occurrence 1")) return "Drop the answer";
          lists += 1;
          return lists === 1 ? choices[0] : lists === 2 ? choices[1] : "Send the fork with these edits";
        },
        editor: async (title: string, prefill: string) => {
          asked.push(`${title} [${prefill}]`);
          return prefill === "true" ? "maybe" : "no";
        },
      });
      await pi.commands.get("wfm-fork")!.handler("run_a1", pi.ctx);
      expect(asked).toEqual([
        "Fork edits of run run_a1: occurrence 0 (flag): keep; Confirm | occurrence 1 (text): keep; Summarize | Send the fork with these edits | Stop without a fork",
        "Answer of occurrence 0 of run run_a1: Keep the answer | Drop the answer | Replace the answer",
        "Replacement answer of occurrence 0 (flag) [true]",
        "Replacement answer of occurrence 0 (flag) [maybe]",
        "Fork edits of run run_a1: occurrence 0 (flag): replace with false; Confirm | occurrence 1 (text): keep; Summarize | Send the fork with these edits | Stop without a fork",
        "Answer of occurrence 1 of run run_a1: Keep the answer | Drop the answer | Replace the answer",
        "Fork edits of run run_a1: occurrence 0 (flag): replace with false; Confirm | occurrence 1 (text): drop; Summarize | Send the fork with these edits | Stop without a fork",
      ]);
      expect(pi.notices.some((notice) => notice.message.startsWith("The replacement is refused before any send: a flag answer must be yes, no, true, or false."))).toBe(true);
      expect(made().posts).toEqual(["/v1/runs/run_a1/lineage-requests"]);
      expect(made().bodies).toEqual([{
        body: '{"edits":[{"answer":false,"occurrenceId":"0","operation":"replace"},{"occurrenceId":"1","operation":"drop"}],"operation":"fork"}',
        ifMatch: '"lineage-requests_rev"',
      }]);
      expect(pi.notices.at(-1)).toEqual({ message: "Command fork refused: 412 stale-revision", level: "warning" });
      await pi.fire("session_shutdown");
    });

    it("sends no lineage request that the collection does not list as eligible and no export with an invalid name", async () => {
      const { pi, made } = await served({ "/v1/runs/run_a1/lineage-requests": lineagePage([], "quarantined") });
      await pi.commands.get("wfm-restart")!.handler("run_a1", pi.ctx);
      expect(pi.notices.at(-1)).toEqual({
        message: "restart is not eligible: the manager lists no lineage operation for run run_a1; refusal quarantined. Nothing was sent.", level: "warning",
      });
      await pi.commands.get("wfm-export")!.handler("run_a1 ../escape", pi.ctx);
      expect(pi.notices.at(-1)?.message).toContain("The export name must be 1 to 128 ASCII letters");
      expect(made().posts).toEqual([]);
      await pi.fire("session_shutdown");
    });
  });

  it("closes a connection that completes after close", async () => {
    let release: (reply: Reply) => void = () => {};
    const held = new Promise<Reply>((resolve) => {
      release = resolve;
    });
    const fake = transports({ "alpha.test": (resource) => resource === "/v1/capabilities" ? held : manager([])(resource, 1) });
    const service = new ServiceMode([profile("late", "alpha.test")], { session: { transport: fake.transport } });
    const started = service.start();
    await until(() => fake.made.length === 1 && fake.made[0].gets.length === 1);
    await service.close();
    release(ok(capabilities()));
    expect(await started).toEqual({ kind: "closed" });
    expect(fake.made[0].closed).toBe(true);
    expect(fake.made[0].gets).toEqual(["/v1/capabilities"]);
    expect(service.connection).toEqual({ kind: "closed" });
  });
});
