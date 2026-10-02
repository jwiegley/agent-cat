/**
 * A fake manager for the service-mode tests of the extension. The fake
 * transport answers the capabilities and the overview of each endpoint,
 * holds a follow loop open until `close`, and records every GET and POST.
 * The client profiles are real private files with a real CA certificate, so
 * `ClientProfile.load` runs unchanged.
 */

import { execFileSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import { chmodSync, writeFileSync } from "node:fs";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Outcome } from "../../src/manager/events.ts";
import { encodeJson, parseJson, type JsonValue } from "../../src/manager/json.ts";
import type { ClientProfile } from "../../src/manager/profile.ts";
import type { SessionTransport } from "../../src/manager/session.ts";
import type { ClientResponse, CommandHeaders, Delivery, FollowEnd, FollowOptions, StreamItem } from "../../src/manager/transport.ts";

export type Reply = Outcome<ClientResponse>;
export type Route = (resource: string, count: number) => Reply | Promise<Reply>;
export type PostRoute = (resource: string, body: JsonValue) => Reply | undefined;

export const CLOSED: Reply = { ok: false, failure: { kind: "ClientClosed" } };
export const UNREACHABLE: Reply = { ok: false, failure: { kind: "TransportUnavailable" } };

/** One fake transport of one binding. It records each request and holds its follow loop open until `close`. */
export class FakeTransport implements SessionTransport {
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
  constructor(readonly host: string, readonly route: Route, readonly fenced: boolean, readonly postRoute?: PostRoute) {}

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
    return this.postRoute?.(resource, body) ?? UNREACHABLE;
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

export function ok(value: unknown, etag: string | null = null): Reply {
  const text = JSON.stringify(value);
  return { ok: true, value: { status: 200, value: parseJson(text) as JsonValue, etag, location: null, bytes: Buffer.byteLength(text) } };
}

export function capabilities(versions: Record<string, unknown> = {}, scopes = ["observe", "submit"]): unknown {
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

export function run(id: string, status: string): unknown {
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

export function request(id: string): unknown {
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

export function decision(id: string, runId: string): unknown {
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

export function control(runId: string, headId: string): unknown {
  return {
    version: 1, runId, revision: `${runId}_control`, supervision: "owned", cancelAllowed: true, decisionHeadId: headId,
    offers: [{ operation: "answer", address: { occurrenceId: "0" }, generation: "generation_3", timings: [], choices: [], targets: [] }],
  };
}

export function overview(cursor: string, items: unknown[]): unknown {
  return {
    version: 1, snapshotVersion: 1, cursor, oldestCursor: "s.0", items,
    page: { setId: "set_1", revision: "rev_1", expiresAt: new Date(Date.now() + 60000).toISOString(), index: 0, totalItems: items.length, next: null },
  };
}

/** A route that answers the capabilities and the overview of one endpoint. */
export function manager(items: unknown[]): Route {
  return (resource) => {
    if (resource === "/v1/capabilities") return ok(capabilities());
    if (resource === "/v1/snapshot") return ok(overview("s.1", items));
    return { ok: false, failure: { kind: "Refused", status: 404, code: "not-found" } };
  };
}


/**
 * A directory with a private credential file and a CA certificate, and a
 * writer of private client profiles that name them.
 */
export async function clientProfiles(prefix: string): Promise<{
  readonly directory: string;
  readonly credentialFile: string;
  readonly profile: (name: string, host: string, fields?: Record<string, unknown>) => string;
  readonly remove: () => Promise<void>;
}> {
  const directory = await mkdtemp(join(tmpdir(), prefix));
  execFileSync("openssl", ["req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256", "-nodes", "-keyout", "ca.key",
    "-out", "ca.pem", "-days", "2", "-subj", "/CN=service-mode", "-addext", "basicConstraints=critical,CA:TRUE"], { cwd: directory, stdio: "pipe" });
  const caFile = join(directory, "ca.pem");
  chmodSync(caFile, 0o644);
  const credentialFile = writePrivate(join(directory, "credential"), randomBytes(24).toString("hex"));
  return {
    directory,
    credentialFile,
    profile: (name, host, fields = {}) =>
      writePrivate(join(directory, `${name}.json`), JSON.stringify({ version: 1, endpoint: `https://${host}:8443/v1`, credentialFile, caFile, ...fields })),
    remove: () => rm(directory, { recursive: true, force: true }),
  };
}

function writePrivate(path: string, text: string): string {
  writeFileSync(path, text, { mode: 0o600 });
  chmodSync(path, 0o600);
  return path;
}

/** A fake transport factory over the routes of each host. */
export function transports(routes: Record<string, Route>, unfenced: readonly string[] = [], postRoutes: Record<string, PostRoute> = {})
  : { made: FakeTransport[]; transport: (profile: ClientProfile) => FakeTransport } {
  const made: FakeTransport[] = [];
  return {
    made,
    transport: (loaded) => {
      const route = routes[loaded.endpoint.host];
      if (route === undefined) throw new Error(`no route for ${loaded.endpoint.host}`);
      const made1 = new FakeTransport(loaded.endpoint.host, route, !unfenced.includes(loaded.endpoint.host), postRoutes[loaded.endpoint.host]);
      made.push(made1);
      return made1;
    },
  };
}

