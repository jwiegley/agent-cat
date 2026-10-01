/**
 * The service-mode lifecycle of the extension with a fake Pi, a fake UI and
 * an injected fake transport. The fake transport answers the capabilities
 * and the overview of each endpoint, holds a follow loop open until `close`,
 * and records every GET and POST. The client profiles are real private
 * files with a real CA certificate, so `ClientProfile.load` runs unchanged.
 */

import { execFileSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import { chmodSync, writeFileSync } from "node:fs";
import { mkdir, mkdtemp, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { afterAll, afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import extension from "../src/index.ts";
import type { Outcome } from "../src/manager/events.ts";
import { encodeJson, parseJson, type JsonValue } from "../src/manager/json.ts";
import type { ClientProfile } from "../src/manager/profile.ts";
import type { SessionTransport } from "../src/manager/session.ts";
import type { ClientResponse, CommandHeaders, Delivery, FollowEnd, FollowOptions, StreamItem } from "../src/manager/transport.ts";
import { MANAGER_ROLE_MARKER, ROOT_ROLE_FILE } from "../src/root-role.ts";
import { ServiceMode } from "../src/service-mode.ts";
import { RunSupervisor } from "../src/supervisor.ts";

type Reply = Outcome<ClientResponse>;
type Route = (resource: string, count: number) => Reply | Promise<Reply>;

const CLOSED: Reply = { ok: false, failure: { kind: "ClientClosed" } };
const UNREACHABLE: Reply = { ok: false, failure: { kind: "TransportUnavailable" } };

/** One fake transport of one binding. It records each request and holds its follow loop open until `close`. */
class FakeTransport implements SessionTransport {
  readonly gets: string[] = [];
  readonly posts: string[] = [];
  closed = false;
  #deliver: ((item: StreamItem, via: Delivery) => void) | undefined;
  #end: ((end: FollowEnd) => void) | undefined;
  readonly #counts = new Map<string, number>();

  /**
   * `fenced` discards a reply that arrives after `close`, as
   * `ManagerTransport` does. An unfenced transport gives the late reply, so
   * only the fences of the session and of service mode remain.
   */
  constructor(readonly host: string, readonly route: Route, readonly fenced: boolean) {}

  async get(resource: string): Promise<Reply> {
    this.gets.push(resource);
    if (this.closed) return CLOSED;
    const count = (this.#counts.get(resource) ?? 0) + 1;
    this.#counts.set(resource, count);
    const reply = await this.route(resource, count);
    if (!this.fenced) this.late.push(resource);
    return this.closed && this.fenced ? CLOSED : reply;
  }

  /** The resources whose replies an unfenced transport gave, in order. */
  readonly late: string[] = [];

  /** The exact body and the If-Match value of each POST, in order. */
  readonly bodies: Array<{ readonly body: string; readonly ifMatch: string | null }> = [];

  async post(resource: string, body: JsonValue, command: CommandHeaders): Promise<Reply> {
    this.posts.push(resource);
    this.bodies.push({ body: encodeJson(body), ifMatch: command.ifMatch });
    return UNREACHABLE;
  }

  async postBytes(resource: string): Promise<Reply> {
    this.posts.push(resource);
    return UNREACHABLE;
  }

  followEvents(_start: string, deliver: (item: StreamItem, via: Delivery) => void, options: FollowOptions = {}): Promise<FollowEnd> {
    if (this.closed) return Promise.resolve({ kind: "closed" });
    this.#deliver = deliver;
    options.state?.("live");
    return new Promise((resolve) => {
      this.#end = resolve;
    });
  }

  async pollEvents(): Promise<never> {
    throw new Error("the fake transport does not poll");
  }

  async downloadVerified(): Promise<never> {
    throw new Error("the fake transport does not download");
  }

  dropStream(): void {}

  close(): void {
    this.closed = true;
    this.#end?.({ kind: "closed" });
  }

  /** Deliver one invalidation through the open stream. */
  emit(id: string, resource: string): void {
    this.#deliver?.({ kind: "invalidation", event: { id, name: "run.changed", data: { resource, revision: "rev_9" } } }, "stream");
  }
}

function ok(value: unknown, etag: string | null = null): Reply {
  const text = JSON.stringify(value);
  return { ok: true, value: { status: 200, value: parseJson(text) as JsonValue, etag, location: null, bytes: Buffer.byteLength(text) } };
}

function capabilities(versions: Record<string, unknown> = {}, scopes = ["observe", "submit"]): unknown {
  return {
    version: 1, authorityEpoch: "epoch_1", streamId: "s", scopes, profileIds: ["profile_1"],
    transports: ["sse", "polling"],
    limits: {
      requestTargetBytes: 8192, headerBytes: 16384, headerFields: 100, jsonBodyBytes: 2097152, jsonDepth: 64,
      nativeControlBytes: 1048576, captureBytes: 67108864, aggregateInputBytes: 67108864, artifactBytes: 67108864,
      sseBlockBytes: 16384, pageBytes: 1048576, pageSetBytes: 67108864, pageSetsPerClient: 2, pageSetLifetimeSeconds: 60,
      queuedRequests: 100, maxReservations: 16, reviewLifetimeSeconds: 600, sseReadersPerClient: 2,
      ssePendingBytesPerReader: 1048576, replaySeconds: 604800, replayBytes: 268435456, heartbeatSeconds: 15,
      reconnectIdleSeconds: 45, reconnectBackoffMaxSeconds: 30, ordinaryMutationsPerMinute: 30,
      drafts: 100, globalDrafts: 100, globalCaptureBytes: 67108864, globalPageSets: 2, globalConnections: 8,
      globalDatabaseReaders: 2, globalMutationLedgerBytes: 16777216, safetyControlsPerMinute: 100, executionReservations: 1,
    },
    versions: {
      api: [1], snapshot: [1], event: [1], descriptor: [2, 3], frontendSession: [1, 2], control: [1, 2], runtimeProtocol: [1, 2, 3],
      runtimeStore: [1, 2], managerStore: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12], invocation: [1], frontendManifest: ["legacy", "2", "3"],
      ...versions,
    },
  };
}

function run(id: string, status: string): unknown {
  const self = `/v1/runs/${id}`;
  return {
    kind: "run",
    run: {
      version: 1, id, revision: `${id}_rev`, profileId: "profile_1", workflowId: "wf_review", requestId: null, parentRunId: null,
      lineage: null, manifest: { kind: "versioned", frontendManifestVersion: 3 },
      runtime: { status, lastSequence: "7", protocolVersion: 2 }, supervision: "owned", integrity: "valid",
      verification: { state: "absent" }, limitations: [],
      links: {
        self, snapshot: `${self}/snapshot`, control: `${self}/control`, outputs: `${self}/outputs`, exports: `${self}/exports`,
        lineageRequests: `${self}/lineage-requests`,
      },
    },
  };
}

function request(id: string): unknown {
  return {
    kind: "request",
    request: {
      version: 1, id, revision: `${id}_rev`, workflowId: "wf_review", descriptorRevision: "catalogue_17", profileId: "profile_1",
      profileRevision: "profile_rev_4", phase: "draft",
      readiness: {
        declarations: [{ name: "subject", source: "command-tail", description: null, required: true, schema: { type: "string" } }],
        supplied: [], missing: ["subject"], errors: [],
      },
      admission: { state: "not-queued", position: null, reasons: ["missing-inputs"] },
      preparationId: null, runId: null, parentRunId: null, lineage: null, links: { self: `/v1/requests/${id}` },
    },
  };
}

function decision(id: string, runId: string): unknown {
  return {
    kind: "decision",
    decision: {
      version: 1, id, revision: `${id}_rev`, runId, profileId: "profile_1", generation: "generation_3", address: { occurrenceId: "0" },
      state: "pending", position: 0, observedSequence: "9", queue: `/v1/decisions?runId=${runId}`, kind: "question",
      question: {
        code: "flag", semanticSchema: "boolean", editorSchema: null, addressee: "person owner", scope: { model: null, mode: null },
        draw: "0", prompt: "Proceed?",
      },
    },
  };
}

function control(runId: string, headId: string): unknown {
  return {
    version: 1, runId, revision: `${runId}_control`, supervision: "owned", cancelAllowed: true, decisionHeadId: headId,
    offers: [{ operation: "answer", address: { occurrenceId: "0" }, generation: "generation_3", timings: [], choices: [], targets: [] }],
  };
}

function overview(cursor: string, items: unknown[]): unknown {
  return {
    version: 1, snapshotVersion: 1, cursor, oldestCursor: "s.0", items,
    page: { setId: "set_1", revision: "rev_1", expiresAt: new Date(Date.now() + 60000).toISOString(), index: 0, totalItems: items.length, next: null },
  };
}

/** A route that answers the capabilities and the overview of one endpoint. */
function manager(items: unknown[]): Route {
  return (resource) => {
    if (resource === "/v1/capabilities") return ok(capabilities());
    if (resource === "/v1/snapshot") return ok(overview("s.1", items));
    return { ok: false, failure: { kind: "Refused", status: 404, code: "not-found" } };
  };
}

let directory = "";
let caFile = "";
let credentialFile = "";

function writePrivate(path: string, text: string): string {
  writeFileSync(path, text, { mode: 0o600 });
  chmodSync(path, 0o600);
  return path;
}

/** A private client profile for a host. */
function profile(name: string, host: string, fields: Record<string, unknown> = {}): string {
  return writePrivate(join(directory, `${name}.json`), JSON.stringify({ version: 1, endpoint: `https://${host}:8443/v1`, credentialFile, caFile, ...fields }));
}

beforeAll(async () => {
  directory = await mkdtemp(join(tmpdir(), "agent-cat-service-mode-"));
  execFileSync("openssl", ["req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256", "-nodes", "-keyout", "ca.key",
    "-out", "ca.pem", "-days", "2", "-subj", "/CN=service-mode", "-addext", "basicConstraints=critical,CA:TRUE"], { cwd: directory, stdio: "pipe" });
  caFile = join(directory, "ca.pem");
  chmodSync(caFile, 0o644);
  credentialFile = writePrivate(join(directory, "credential"), randomBytes(24).toString("hex"));
});

afterAll(async () => {
  await rm(directory, { recursive: true, force: true });
});

const ENVIRONMENT = ["AGENT_CAT_MANAGER_PROFILE", "AGENT_CAT_MANAGER_PROFILES", "AGENT_CAT_STATE_DIR", "AGENT_CAT_RUNNER", "AGENTDECK_INSTANCE_ID"];
const saved = Object.fromEntries(ENVIRONMENT.map((name) => [name, process.env[name]]));

afterEach(() => {
  vi.restoreAllMocks();
  for (const name of ENVIRONMENT) {
    if (saved[name] === undefined) delete process.env[name];
    else process.env[name] = saved[name];
  }
});

/** A fake transport factory over the routes of each host. */
function transports(routes: Record<string, Route>, unfenced: readonly string[] = [])
  : { made: FakeTransport[]; transport: (profile: ClientProfile) => FakeTransport } {
  const made: FakeTransport[] = [];
  return {
    made,
    transport: (loaded) => {
      const route = routes[loaded.endpoint.host];
      if (route === undefined) throw new Error(`no route for ${loaded.endpoint.host}`);
      const made1 = new FakeTransport(loaded.endpoint.host, route, !unfenced.includes(loaded.endpoint.host));
      made.push(made1);
      return made1;
    },
  };
}

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
    expect(fake.made.flatMap((made) => made.gets).every((uri) => uri === "/v1/capabilities" || uri === "/v1/snapshot")).toBe(true);
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

  it.each([
    ["pending", '"decision_a1_rev"', "uncertain",
      "Command answer uncertain: TransportUnavailable. One read of /v1/decisions/decision_a1 does not settle it. The command is not sent again."],
    ["resolved", '"decision_a1_rev_2"', "accepted",
      "Command answer accepted: the send was uncertain (TransportUnavailable), and one read of /v1/decisions/decision_a1 observes its effect."],
  ] as const)("answers a flag question with JSON false and reconciles an uncertain send with one read while the decision is %s",
    async (later, tag, outcome, notice) => {
      const { local } = await localState();
      process.env.AGENT_CAT_STATE_DIR = local;
      process.env.AGENT_CAT_MANAGER_PROFILE = profile("answer", "alpha.test");
      const head = (decision("decision_a1", "run_a1") as { decision: Record<string, unknown> }).decision;
      const base = manager([run("run_a1", "running"), decision("decision_a1", "run_a1")]);
      const fake = transports({
        "alpha.test": (resource, count) => {
          if (resource === "/v1/capabilities") return ok(capabilities({}, ["observe", "submit", "control"]));
          if (resource === "/v1/decisions?runId=run_a1") {
            const page = { setId: "set_q", revision: "rev_q", expiresAt: new Date(Date.now() + 60000).toISOString(), index: 0, totalItems: 1, next: null };
            return ok({ version: 1, page, items: [head] });
          }
          if (resource === "/v1/decisions/decision_a1") return count === 1 ? ok(head, '"decision_a1_rev"') : ok({ ...head, state: later }, tag);
          if (resource === "/v1/runs/run_a1/control") return ok(control("run_a1", "decision_a1"), '"control_rev"');
          return base(resource, count);
        },
      });
      const pi = host({ manager: { transport: fake.transport } });
      const titles: string[] = [];
      Object.assign(pi.ctx.ui, { editor: async (title: string) => (titles.push(title), "  No ") });
      await pi.fire("session_start");
      await until(async () => (await pi.status()).includes("delivery live"));
      await pi.commands.get("wfm-answer")!.handler("run_a1", pi.ctx);
      const [made] = fake.made;
      expect(titles).toEqual(["Answer of decision decision_a1 (flag: yes, no, true or false): Proceed?"]);
      // One POST of the typed JSON false, bound to the decision revision that was read.
      expect(made.posts).toEqual(["/v1/decisions/decision_a1"]);
      expect(made.bodies).toEqual([{ body: '{"generation":"generation_3","occurrenceId":"0","operation":"answer","value":false}', ifMatch: '"decision_a1_rev"' }]);
      // The uncertain send is reconciled with one read of the decision and never sent again.
      expect(made.gets.filter((uri) => uri === "/v1/decisions/decision_a1")).toHaveLength(2);
      const record = pi.notices.find((line) => line.message.startsWith("Command answer "));
      expect(record?.message).toContain(notice);
      expect(await pi.status()).toMatch(new RegExp(`\n {2}answer {2}${outcome} {2}`));
      await new Promise((wake) => setTimeout(wake, 50));
      await pi.fire("session_shutdown");
      expect(made.posts).toEqual(["/v1/decisions/decision_a1"]);
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
