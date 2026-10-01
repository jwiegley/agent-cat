import { execFileSync } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import type { IncomingMessage, ServerResponse } from "node:http";
import { createServer, type Server } from "node:https";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { TLSSocket } from "node:tls";
import { afterAll, beforeAll, beforeEach, describe, expect, it } from "vitest";
import { encodeJson, JsonNumber, jsonMember, isJsonObject, parseJson } from "../src/manager/json.ts";
import { ClientProfile } from "../src/manager/profile.ts";
import { ManagerSession } from "../src/manager/session.ts";
import { commandKey, ManagerTransport, RESPONSE_BYTES, type Delivery, type StreamItem } from "../src/manager/transport.ts";

/** One request that the local manager received. */
type Seen = { method: string; url: string; headers: IncomingMessage["headers"]; protocol: string | null; body: string };

type Handler = (request: IncomingMessage, response: ServerResponse, seen: Seen) => void;

let directory = "";
let server: Server;
let port = 0;
let caFile = "";
let otherCaFile = "";
let credentialFile = "";
let credential = "";
let handler: Handler = (_request, response) => response.writeHead(500).end();
const seen: Seen[] = [];

function openssl(...args: string[]): void {
  execFileSync("openssl", args, { cwd: directory, stdio: "pipe" });
}

/** A self-signed EC P-256 CA certificate and key. */
function makeCa(name: string): void {
  openssl("req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256", "-nodes",
    "-keyout", `${name}.key`, "-out", `${name}.pem`, "-days", "2", "-subj", `/CN=${name}`,
    "-addext", "basicConstraints=critical,CA:TRUE", "-addext", "keyUsage=critical,keyCertSign,cRLSign");
}

function writePrivate(path: string, text: string, mode = 0o600): string {
  writeFileSync(path, text, { mode });
  chmodSync(path, mode);
  return path;
}

let profiles = 0;

/** A private profile file with the given fields. */
function profileFile(fields: Record<string, unknown>, mode = 0o600): string {
  profiles += 1;
  return writePrivate(join(directory, `profile-${profiles}.json`), JSON.stringify(fields), mode);
}

function fields(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return { version: 1, endpoint: `https://127.0.0.1:${port}/v1`, credentialFile, caFile, ...overrides };
}

async function transport(overrides: Record<string, unknown> = {}, pollIntervalMs = 50): Promise<ManagerTransport> {
  const profile = await ClientProfile.load(profileFile(fields(overrides)));
  if (!profile.ok) throw new Error(`profile refused: ${profile.failure.kind}`);
  return new ManagerTransport(profile.value, { random: () => 0, pollIntervalMs });
}

function json(response: ServerResponse, status: number, text: string, headers: Record<string, string> = {}): void {
  response.writeHead(status, {
    "Content-Type": status < 300 ? "application/json" : "application/problem+json",
    "Cache-Control": "no-store",
    ...headers,
  }).end(text);
}

function invalidation(id: string, resource: string, revision: string): string {
  return `id: ${id}\nevent: request.changed\ndata: {"version":1,"resource":"${resource}","revision":"${revision}"}\n\n`;
}

function eventStream(response: ServerResponse): void {
  response.writeHead(200, { "Content-Type": "text/event-stream", "Cache-Control": "no-store" });
}

function waitFor(condition: () => boolean, milliseconds = 5000): Promise<void> {
  const deadline = Date.now() + milliseconds;
  return new Promise((resolve, reject) => {
    const check = () => {
      if (condition()) resolve();
      else if (Date.now() > deadline) reject(new Error("condition not reached"));
      else setTimeout(check, 10);
    };
    check();
  });
}

beforeAll(async () => {
  directory = mkdtempSync(join(tmpdir(), "manager-transport-"));
  makeCa("ca");
  makeCa("other-ca");
  openssl("req", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256", "-nodes",
    "-keyout", "leaf.key", "-out", "leaf.csr", "-subj", "/CN=127.0.0.1");
  writeFileSync(join(directory, "leaf.ext"),
    "subjectAltName=IP:127.0.0.1\nbasicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\n");
  openssl("x509", "-req", "-in", "leaf.csr", "-CA", "ca.pem", "-CAkey", "ca.key", "-CAcreateserial",
    "-out", "leaf.pem", "-days", "2", "-extfile", "leaf.ext");
  caFile = join(directory, "ca.pem");
  otherCaFile = join(directory, "other-ca.pem");
  chmodSync(caFile, 0o644);
  chmodSync(otherCaFile, 0o644);
  credential = randomBytes(24).toString("hex");
  credentialFile = writePrivate(join(directory, "credential"), credential);
  server = createServer({
    key: readFileSync(join(directory, "leaf.key")),
    cert: readFileSync(join(directory, "leaf.pem")),
    minVersion: "TLSv1.3",
  }, (request, response) => {
    const chunks: Buffer[] = [];
    request.on("data", (chunk: Buffer) => chunks.push(chunk));
    request.on("end", () => {
      const entry: Seen = {
        method: request.method ?? "",
        url: request.url ?? "",
        headers: request.headers,
        protocol: (request.socket as TLSSocket).getProtocol(),
        body: Buffer.concat(chunks).toString("utf8"),
      };
      seen.push(entry);
      handler(request, response, entry);
    });
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  port = (server.address() as AddressInfo).port;
});

afterAll(async () => {
  server.closeAllConnections();
  await new Promise<void>((resolve) => server.close(() => resolve()));
  rmSync(directory, { recursive: true, force: true });
});

beforeEach(() => {
  seen.length = 0;
  handler = (_request, response) => response.writeHead(500).end();
});

describe("client profile", () => {
  it("refuses an extra field, a relative path, a non-https endpoint and an open credential before any request", async () => {
    const extra = await ClientProfile.load(profileFile(fields({ label: "x" })));
    const relative = await ClientProfile.load(profileFile(fields({ credentialFile: "credential" })));
    const plain = await ClientProfile.load(profileFile(fields({ endpoint: `http://127.0.0.1:${port}/v1` })));
    const userinfo = await ClientProfile.load(profileFile(fields({ endpoint: `https://user@127.0.0.1:${port}/v1` })));
    const otherPath = await ClientProfile.load(profileFile(fields({ endpoint: `https://127.0.0.1:${port}/v2` })));
    const groupFile = writePrivate(join(directory, "credential-group"), credential, 0o640);
    const otherFile = writePrivate(join(directory, "credential-other"), credential, 0o604);
    const group = await ClientProfile.load(profileFile(fields({ credentialFile: groupFile })));
    const other = await ClientProfile.load(profileFile(fields({ credentialFile: otherFile })));
    const openProfile = await ClientProfile.load(profileFile(fields(), 0o644));
    const shortFile = writePrivate(join(directory, "credential-short"), "short");
    const short = await ClientProfile.load(profileFile(fields({ credentialFile: shortFile })));
    const version = await ClientProfile.load(profileFile(fields({ version: 2 })));
    expect([extra, relative, plain, userinfo, otherPath, group, other, openProfile, short, version].map((outcome) =>
      outcome.ok ? "loaded" : outcome.failure.kind)).toEqual([
      "InvalidClientProfile", "InvalidClientProfile", "InvalidEndpoint", "InvalidEndpoint", "InvalidEndpoint",
      "ClientFileUnavailable", "ClientFileUnavailable", "ClientFileUnavailable", "CredentialUnavailable",
      "InvalidClientProfile",
    ]);
    expect(seen).toEqual([]);
  });

  it("names only the endpoint in its JSON form", async () => {
    const profile = await ClientProfile.load(profileFile(fields()));
    expect(profile.ok).toBe(true);
    if (!profile.ok) return;
    const shown = JSON.stringify(profile.value);
    expect(shown).toBe(JSON.stringify({ endpoint: `https://127.0.0.1:${port}/v1` }));
    expect(shown).not.toContain(credential);
  });

  it("refuses a request after the credential changes", async () => {
    const changing = writePrivate(join(directory, "credential-changing"), credential);
    const client = await transport({ credentialFile: changing });
    writePrivate(changing, randomBytes(24).toString("hex"));
    expect(await client.get("/v1/capabilities")).toEqual({ ok: false, failure: { kind: "CredentialChanged" } });
    expect(seen).toEqual([]);
  });
});

describe("transport", () => {
  it("performs a GET over TLS 1.3 with the bearer and gives the ETag and the lossless body", async () => {
    handler = (_request, response) =>
      json(response, 200, '{"version":1,"id":"r1","big":123456789012345678901234567890}', { ETag: '"rev-1"' });
    const client = await transport();
    const outcome = await client.get("/v1/requests/r1");
    expect(outcome.ok).toBe(true);
    if (!outcome.ok) return;
    expect(outcome.value.status).toBe(200);
    expect(outcome.value.etag).toBe('"rev-1"');
    expect(isJsonObject(outcome.value.value) && jsonMember(outcome.value.value, "big")).toEqual(
      new JsonNumber("123456789012345678901234567890"));
    expect(seen).toHaveLength(1);
    expect(seen[0]).toMatchObject({ method: "GET", url: "/v1/requests/r1", protocol: "TLSv1.3" });
    expect(seen[0].headers).toMatchObject({
      authorization: `Bearer ${credential}`,
      accept: "application/json",
      "accept-encoding": "identity",
      connection: "close",
    });
    client.close();
  });

  it("performs a POST with the JSON body, the idempotency key and If-Match", async () => {
    handler = (_request, response) =>
      json(response, 202, '{"version":1,"state":"accepted"}', { Location: "/v1/commands/c1" });
    const client = await transport();
    const key = commandKey("epoch-1");
    expect(key.ok).toBe(true);
    if (!key.ok) return;
    const body = parseJson('{"version":1,"answer":false,"occurrence":18446744073709551615}');
    const outcome = await client.post("/v1/decisions/d1/answer", body, { idempotencyKey: key.value, ifMatch: '"rev-2"' });
    expect(outcome.ok && outcome.value.location).toBe("/v1/commands/c1");
    expect(seen).toHaveLength(1);
    expect(seen[0]).toMatchObject({ method: "POST", url: "/v1/decisions/d1/answer", body: encodeJson(body) });
    expect(seen[0].headers).toMatchObject({
      "content-type": "application/json",
      "idempotency-key": key.value,
      "if-match": '"rev-2"',
      authorization: `Bearer ${credential}`,
    });
    expect(key.value).toMatch(/^epoch-1\.[A-Za-z0-9_-]{22}$/);
    client.close();
  });

  it("gives the failure of a problem response", async () => {
    handler = (_request, response) => json(response, 404, '{"status":404,"code":"not-found","title":"Not found"}');
    const client = await transport();
    expect(await client.get("/v1/requests/r9")).toEqual({ ok: false, failure: { kind: "Refused", status: 404, code: "not-found" } });
    client.close();
  });

  it("does not follow a redirect", async () => {
    handler = (request, response) => {
      if (request.url === "/v1/requests/a") response.writeHead(302, { Location: "/v1/requests/b" }).end();
      else json(response, 200, '{"version":1}');
    };
    const client = await transport();
    expect(await client.get("/v1/requests/a")).toEqual({ ok: false, failure: { kind: "RedirectRefused" } });
    await new Promise((resolve) => setTimeout(resolve, 100));
    expect(seen.map((entry) => entry.url)).toEqual(["/v1/requests/a"]);
    client.close();
  });

  it("refuses an oversized body", async () => {
    handler = (_request, response) => {
      response.writeHead(200, { "Content-Type": "application/json", "Cache-Control": "no-store" });
      const piece = Buffer.alloc(65536, 0x20);
      for (let written = 0; written <= RESPONSE_BYTES; written += piece.length) response.write(piece);
      response.end();
    };
    const client = await transport();
    expect(await client.get("/v1/requests/big")).toEqual({ ok: false, failure: { kind: "ResponseTooLarge" } });
    handler = (_request, response) => json(response, 200, " ".repeat(RESPONSE_BYTES + 1));
    expect(await client.get("/v1/requests/declared")).toEqual({ ok: false, failure: { kind: "ResponseTooLarge" } });
    client.close();
  });

  it("trusts only the CA file of the profile", async () => {
    const client = await transport({ caFile: otherCaFile });
    expect(await client.get("/v1/capabilities")).toEqual({ ok: false, failure: { kind: "TransportUnavailable" } });
    expect(seen).toEqual([]);
    client.close();
  });
});

describe("event delivery", () => {
  it("reconnects the stream with Last-Event-ID after the manager drops it", async () => {
    let connections = 0;
    handler = (_request, response) => {
      connections += 1;
      eventStream(response);
      if (connections === 1) {
        response.write(invalidation("s.1", "/v1/requests/r1", "v1"));
        response.write("id: s.2\nevent: request.chan");
        setTimeout(() => response.socket?.destroy(), 50);
      } else {
        response.write(": heartbeat\n\n");
        response.write(invalidation("s.2", "/v1/requests/r1", "v2"));
      }
    };
    const client = await transport();
    const delivered: [string, Delivery][] = [];
    const ended = await client.followEvents("s.0", (item: StreamItem, via) => {
      delivered.push([item.kind === "invalidation" ? item.event.id : "heartbeat", via]);
      if (item.kind === "invalidation" && item.event.id === "s.2") client.close();
    });
    expect(ended).toEqual({ kind: "closed" });
    expect(delivered).toEqual([["s.1", "stream"], ["heartbeat", "stream"], ["s.2", "stream"]]);
    expect(seen.map((entry) => [entry.headers.accept, entry.headers["last-event-id"]])).toEqual([
      ["text/event-stream", "s.0"],
      ["text/event-stream", "s.1"],
    ]);
  });

  it("polls the event resource when the stream is refused", async () => {
    handler = (request, response) => {
      if (request.headers.accept === "text/event-stream") {
        json(response, 429, '{"status":429,"code":"too-many-readers"}');
      } else {
        json(response, 200, JSON.stringify({
          version: 1,
          cursor: "s.4",
          oldestCursor: "s.0",
          events: [{ id: "s.4", event: "run.changed", data: { version: 1, resource: "/v1/runs/u1", revision: "v4" } }],
          hasMore: false,
        }));
      }
    };
    const client = await transport();
    const delivered: [string, Delivery][] = [];
    const ended = await client.followEvents("s.3", (item, via) => {
      if (item.kind === "invalidation") delivered.push([item.event.data.resource, via]);
      client.close();
    });
    expect(ended).toEqual({ kind: "closed" });
    expect(delivered).toEqual([["/v1/runs/u1", "poll"]]);
    expect(seen.map((entry) => [entry.headers.accept, entry.headers["last-event-id"]])).toEqual([
      ["text/event-stream", "s.3"],
      ["application/json", "s.3"],
    ]);
  });

  it("ends with a resnapshot after a 410 refusal", async () => {
    handler = (_request, response) => json(response, 410, '{"status":410,"code":"cursor-expired"}');
    const client = await transport();
    const ended = await client.followEvents("s.7", () => undefined);
    expect(ended).toEqual({ kind: "resnapshot", cursor: "s.7", failure: { kind: "Refused", status: 410, code: "cursor-expired" } });
    client.close();
  });

  it("ends an open stream on close and discards a late response", async () => {
    const held: ServerResponse[] = [];
    handler = (request, response) => {
      if (request.url === "/v1/events") {
        eventStream(response);
        response.write(": heartbeat\n\n");
      } else {
        held.push(response);
      }
    };
    const client = await transport();
    const items: StreamItem[] = [];
    const stream = client.streamEvents("s.0", (item) => items.push(item));
    await waitFor(() => items.length === 1);
    const late = client.get("/v1/requests/slow");
    await waitFor(() => held.length === 1);
    client.close();
    expect(await stream).toEqual({ ok: false, failure: { kind: "ClientClosed" } });
    expect(await late).toEqual({ ok: false, failure: { kind: "ClientClosed" } });
    if (!held[0].destroyed) json(held[0], 200, '{"version":1}');
    expect(await client.get("/v1/requests/after")).toEqual({ ok: false, failure: { kind: "ClientClosed" } });
    expect(seen.map((entry) => entry.url)).toEqual(["/v1/events", "/v1/requests/slow"]);
    expect(items).toEqual([{ kind: "heartbeat" }]);
  });
});

/** Capabilities that the session accepts, with the given authority epoch. */
function capabilities(epoch: string): string {
  const fixed = {
    requestTargetBytes: 8192, headerBytes: 16384, headerFields: 100, jsonBodyBytes: 2097152, jsonDepth: 64,
    nativeControlBytes: 1048576, captureBytes: 67108864, aggregateInputBytes: 67108864, artifactBytes: 67108864,
    sseBlockBytes: 16384, pageBytes: 1048576, pageSetBytes: 67108864, pageSetsPerClient: 2, pageSetLifetimeSeconds: 60,
    queuedRequests: 100, maxReservations: 16, reviewLifetimeSeconds: 600, sseReadersPerClient: 2,
    ssePendingBytesPerReader: 1048576, replaySeconds: 604800, replayBytes: 268435456, heartbeatSeconds: 15,
    reconnectIdleSeconds: 45, reconnectBackoffMaxSeconds: 30, ordinaryMutationsPerMinute: 30,
  };
  const configured = {
    drafts: 100, globalDrafts: 100, globalCaptureBytes: 67108864, globalPageSets: 2, globalConnections: 8,
    globalDatabaseReaders: 2, globalMutationLedgerBytes: 16777216, safetyControlsPerMinute: 100, executionReservations: 1,
  };
  return JSON.stringify({
    version: 1, authorityEpoch: epoch, streamId: "s", scopes: ["observe", "submit"], profileIds: ["profile_1"],
    transports: ["sse", "polling"], limits: { ...fixed, ...configured },
    versions: {
      api: [1], snapshot: [1], event: [1], descriptor: [2, 3], frontendSession: [1, 2], control: [1, 2], runtimeProtocol: [1, 2, 3],
      runtimeStore: [1, 2], managerStore: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12], invocation: [1], frontendManifest: ["legacy", "2", "3"],
    },
  });
}

/** An empty overview page set of one page at the cursor. */
function emptyOverview(cursor: string): string {
  return JSON.stringify({
    version: 1, snapshotVersion: 1, cursor, oldestCursor: "s.0", items: [],
    page: { setId: "set_1", revision: "rev_1", expiresAt: new Date(Date.now() + 60000).toISOString(), index: 0, totalItems: 0, next: null },
  });
}

/** The number of an event cursor `s.N`. */
function cursorNumber(cursor: string | string[] | undefined): number {
  return Number(String(cursor).split(".")[1]);
}

async function session(options: Parameters<typeof ManagerSession.connect>[1] = {}): Promise<ManagerSession> {
  const profile = await ClientProfile.load(profileFile(fields()));
  if (!profile.ok) throw new Error(`profile refused: ${profile.failure.kind}`);
  const connected = await ManagerSession.connect(profile.value, { random: () => 0, pollIntervalMs: 50, ...options });
  if (!connected.ok) throw new Error(`session refused: ${connected.failure.kind}`);
  return connected.value;
}

describe("manager session", () => {
  it("refuses unsupported capabilities when it connects", async () => {
    handler = (_request, response) => json(response, 200, capabilities("epoch-1").replace('"managerStore":[1,', '"managerStore":[13,1,'));
    const profile = await ClientProfile.load(profileFile(fields()));
    if (!profile.ok) throw new Error("profile refused");
    expect(await ManagerSession.connect(profile.value)).toEqual({ ok: false, failure: { kind: "UnsupportedVersion" } });
  });

  it("binds each reference to its endpoint identity and never retargets it after a switch", async () => {
    let epoch = 0;
    handler = (request, response) => {
      if (request.url === "/v1/capabilities") json(response, 200, capabilities(`epoch-${(epoch += 1)}`));
      else if (request.url === "/v1/snapshot") json(response, 200, emptyOverview("s.0"));
      else json(response, 200, '{"version":1}', { ETag: '"rev-1"' });
    };
    const client = await session();
    const reference = client.reference("/v1/requests/r1");
    if (!reference.ok) throw new Error("reference refused");
    expect((await client.get(reference.value)).ok).toBe(true);
    const before = { identity: client.identity, generation: client.generation, epoch: client.epoch };
    const profile = await ClientProfile.load(profileFile(fields()));
    if (!profile.ok) throw new Error("profile refused");
    const switched = await client.switchEndpoint(profile.value);
    expect(switched.ok && switched.value.cursor).toBe("s.0");
    expect(client.identity).not.toBe(before.identity);
    expect(client.generation).toBe(before.generation + 1);
    expect([before.epoch, client.epoch]).toEqual(["epoch-1", "epoch-2"]);
    expect(await client.get(reference.value)).toEqual({ ok: false, failure: { kind: "WrongEndpoint" } });
    expect(client.prepare(reference.value, { operation: "enqueue" }, null)).toEqual({ ok: false, failure: { kind: "WrongEndpoint" } });
    expect(seen.filter((entry) => entry.url === "/v1/requests/r1")).toHaveLength(1);
    await client.close();
  });

  it("keeps an uncertain command and reconciles it without a resend", async () => {
    let tag = '"rev-1"';
    handler = (request, response) => {
      if (request.url === "/v1/capabilities") json(response, 200, capabilities("epoch-1"));
      else if (request.method === "POST") response.socket?.destroy();
      else json(response, 200, '{"version":1}', { ETag: tag });
    };
    const client = await session();
    const target = client.reference("/v1/requests/r1");
    if (!target.ok) throw new Error("reference refused");
    const pending = client.prepare(target.value, { operation: "enqueue" }, '"rev-1"');
    if (!pending.ok) throw new Error("prepare refused");
    const sent = await client.send(pending.value);
    expect(sent.kind).toBe("uncertain");
    if (sent.kind !== "uncertain") return;
    expect(sent.uncertain).toEqual({ command: pending.value, target: target.value, precondition: '"rev-1"', receipt: null });
    const unchanged = await client.reconcileCommand(sent.uncertain, () => true);
    expect(unchanged).toEqual({ kind: "uncertain", uncertain: sent.uncertain });
    tag = '"rev-2"';
    expect(await client.reconcileCommand(sent.uncertain, () => false)).toEqual({ kind: "uncertain", uncertain: sent.uncertain });
    expect(await client.reconcileCommand(sent.uncertain, () => true)).toEqual({ kind: "effect-observed" });
    expect(seen.filter((entry) => entry.method === "POST")).toHaveLength(1);
    await client.close();
  });

  it("verifies a download against the size and SHA-256 that the manager states", async () => {
    const bytes = Buffer.from("Café λ result\n", "utf8");
    const digest = createHash("sha256").update(bytes).digest("hex");
    handler = (request, response) => {
      if (request.url === "/v1/capabilities") json(response, 200, capabilities("epoch-1"));
      else response.writeHead(200, {
        "Content-Type": "application/octet-stream", "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff",
        "Content-Disposition": "attachment",
      }).end(bytes);
    };
    const client = await session();
    const artifact = client.reference("/v1/artifacts/a1/content");
    if (!artifact.ok) throw new Error("reference refused");
    const size = BigInt(bytes.length);
    const verified = await client.download(artifact.value, size, digest);
    expect(verified.ok && verified.value.equals(bytes)).toBe(true);
    const otherDigest = createHash("sha256").update("other").digest("hex");
    expect(await client.download(artifact.value, size, otherDigest)).toEqual({ ok: false, failure: { kind: "InvalidResponse" } });
    expect(await client.download(artifact.value, size + 1n, digest)).toEqual({ ok: false, failure: { kind: "InvalidResponse" } });
    await client.close();
  });

  it("resumes after a forced drop from the last delivered event and polls while poll delivery is preferred", async () => {
    let reads = 0;
    handler = (request, response) => {
      const next = cursorNumber(request.headers["last-event-id"]) + 1;
      const event = { id: `s.${next}`, event: "request.changed", data: { version: 1, resource: "/v1/requests/r1", revision: `v${next}` } };
      if (request.url === "/v1/capabilities") json(response, 200, capabilities("epoch-1"));
      else if (request.url === "/v1/snapshot") json(response, 200, emptyOverview("s.0"));
      else if (request.url === "/v1/requests/r1") json(response, 200, '{"version":1}', { ETag: `"rev-${(reads += 1)}"` });
      else if (request.headers.accept === "text/event-stream") {
        eventStream(response);
        response.write(invalidation(event.id, event.data.resource, event.data.revision));
      } else {
        json(response, 200, JSON.stringify({ version: 1, cursor: event.id, oldestCursor: "s.0", events: [event], hasMore: false }));
      }
    };
    const delivered: [string, Delivery][] = [];
    const connections: [Delivery, string][] = [];
    const client = await session({ onEvent: (event, via) => delivered.push([event.id, via]), onConnect: (via, cursor) => connections.push([via, cursor]) });
    const started = await client.start();
    expect(started.ok && started.value.cursor).toBe("s.0");
    await waitFor(() => delivered.length === 1);
    client.forceReconnect();
    await waitFor(() => delivered.length === 2);
    expect(delivered).toEqual([["s.1", "stream"], ["s.2", "stream"]]);
    expect(connections).toEqual([["stream", "s.0"], ["stream", "s.1"]]);
    client.setDelivery("poll");
    await waitFor(() => delivered.length >= 4);
    expect(delivered.slice(2, 4)).toEqual([["s.3", "poll"], ["s.4", "poll"]]);
    expect(connections.slice(2, 4)).toEqual([["poll", "s.2"], ["poll", "s.3"]]);
    client.setDelivery("sse");
    await waitFor(() => delivered.some(([, via], index) => index > 3 && via === "stream"));
    const ids = delivered.map(([id]) => cursorNumber(id));
    expect(ids).toEqual(ids.map((_, index) => index + 1));
    const reference = client.reference("/v1/requests/r1");
    if (!reference.ok) throw new Error("reference refused");
    const watched = await client.waitFor(reference.value, () => true, 5000);
    const first = watched.ok ? watched.value.etag : null;
    client.forceReconnect();
    const reread = await client.waitFor(reference.value, (observed) => observed.etag !== first, 5000);
    expect(reread.ok).toBe(true);
    await client.close();
    expect(client.followEnd).toEqual({ kind: "closed" });
  });
});
