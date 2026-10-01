/**
 * The HTTPS transport of one manager session over the versioned `/v1`
 * protocol.
 *
 * This module states the transport rules of `Agentic.Manager.Client` and the
 * follow rules of `serviceEventWorker` in `Agentic.Tui.App` and of
 * `afterStream` and `afterPoll` in `Agentic.Tui.ServiceLane` in TypeScript.
 * It imports no Haskell code. Each request uses `node:https` with the CA file
 * of the profile as its only trust anchors and TLS 1.3 only. It uses its own
 * agent, so no environment proxy, connection pool or cookie applies. It
 * sends `Accept-Encoding: identity` and `Connection: close`, follows no
 * redirect, and waits at most 15 seconds for a response. A response body is
 * bounded at 1 MiB.
 *
 * `close` aborts every open request, the open event stream and every wait.
 * Every result that arrives after `close` is discarded and gives
 * `ClientClosed`. `dropStream` closes only the open event stream.
 *
 * @packageDocumentation
 */

import { createHash, randomBytes } from "node:crypto";
import type { ClientRequest, IncomingMessage } from "node:http";
import { request as httpsRequest } from "node:https";
import { isIP } from "node:net";
import {
  closeSse,
  decodeEventBatch,
  decodeEventBlock,
  feedSse,
  newSseParser,
  problemFailure,
  validCursor,
  validETag,
  validId,
  validResource,
  type ClientFailure,
  type EventBatch,
  type FixedClientFailure,
  type InvalidationEvent,
  type Outcome,
} from "./events.ts";
import { encodeJson, isJsonObject, JsonNumber, numberEqual, tryParseJson, type JsonValue } from "./json.ts";
import type { ClientProfile } from "./profile.ts";
import { INITIAL_BACKOFF, jitteredMicroseconds, reconnectDelay, type Backoff } from "./refresh.ts";

/** The longest wait for a complete JSON response, in milliseconds. */
export const RESPONSE_TIMEOUT_MS = 15000;

/** The largest JSON or problem response body, in bytes. */
export const RESPONSE_BYTES = 1048576;

/** The largest command body, in bytes. */
export const COMMAND_BYTES = 2097152;

/** The largest capture body, in bytes: the `captureBytes` limit of `/capabilities`. */
export const CAPTURE_BYTES = 67108864;

/** The largest artifact download, in bytes: the `artifactBytes` limit of `/capabilities`. */
export const ARTIFACT_BYTES = 67108864;

/** The `reconnectIdleSeconds` limit of `/capabilities`, in milliseconds. */
export const RECONNECT_IDLE_MS = 45000;

/** The number of consecutive stream ends without a delivery that starts polling. */
export const STREAM_FAILURE_LIMIT = 2;

/** The interval between two JSON polling batches, in milliseconds. */
export const POLL_INTERVAL_MS = 1000;

/** The largest number of response header lines. */
const HEADER_COUNT = 100;

/** The largest response header size, in bytes. */
const HEADER_BYTES = 16384;

/** Response headers that occur at most once. */
const UNIQUE_HEADERS = [
  "content-type", "content-length", "transfer-encoding", "content-encoding", "etag", "location", "cache-control",
  "content-disposition",
] as const;

const ONE = JsonNumber.ofBigInt(1n);

function failed(kind: FixedClientFailure): Outcome<never> {
  return { ok: false, failure: { kind } };
}

const CLOSED: Outcome<never> = failed("ClientClosed");
const TRANSPORT: Outcome<never> = failed("TransportUnavailable");
const INVALID: Outcome<never> = failed("InvalidResponse");
const TOO_LARGE: Outcome<never> = failed("ResponseTooLarge");

/**
 * One bounded JSON response. A 2xx response has `version` 1. `etag` is a
 * strong entity tag and `location` a resource below `/v1/`, when present.
 *
 * @public
 */
export type ClientResponse = {
  readonly status: number;
  readonly value: JsonValue;
  readonly etag: string | null;
  readonly location: string | null;
  readonly bytes: number;
};

/**
 * One complete item of the `/v1/events` stream: an invalidation or a
 * comment-only heartbeat.
 *
 * @public
 */
export type StreamItem = { readonly kind: "invalidation"; readonly event: InvalidationEvent } | { readonly kind: "heartbeat" };

/**
 * The source of a delivered item: the event stream or a JSON polling batch.
 *
 * @public
 */
export type Delivery = "stream" | "poll";

/**
 * The delivery that a follow loop prefers. `sse` follows the event stream
 * and polls only as its fallback. `poll` reads JSON polling batches and
 * connects no stream.
 *
 * @public
 */
export type DeliveryPreference = "sse" | "poll";

/**
 * The delivery state of a follow loop. `live` follows an open event stream,
 * `polling` follows successful JSON polling batches, and `unreachable`
 * follows a stream connection that did not open or a polling batch that
 * failed.
 *
 * @public
 */
export type FollowState = "live" | "polling" | "unreachable";

/**
 * Options of `followEvents`. `prefer` is read before each stream connection
 * and after each polling batch, so a change takes effect at the next
 * connection or batch. `connected` receives the delivery and the cursor that
 * each stream connection and each polling batch sends in `Last-Event-ID`.
 * `state` receives the delivery state after each stream connection opens or
 * fails to open and after each polling batch.
 *
 * @public
 */
export type FollowOptions = {
  readonly prefer?: () => DeliveryPreference;
  readonly connected?: (via: Delivery, cursor: string) => void;
  readonly state?: (state: FollowState) => void;
};

/**
 * The end of `followEvents`. `closed` follows `close`. `resnapshot` follows a
 * 410 refusal, after which the caller reads a new overview. `refused` follows
 * a credential refusal. `cursor` is the last complete event identifier.
 *
 * @public
 */
export type FollowEnd =
  | { readonly kind: "closed" }
  | { readonly kind: "resnapshot"; readonly cursor: string; readonly failure: ClientFailure }
  | { readonly kind: "refused"; readonly cursor: string; readonly failure: ClientFailure };

/**
 * The idempotency key and the optional `If-Match` entity tag of one command.
 *
 * @public
 */
export type CommandHeaders = { readonly idempotencyKey: string; readonly ifMatch: string | null };

/**
 * Options of a transport. `random` gives the jitter fraction of each
 * reconnection wait. `pollIntervalMs` is the interval between two polling
 * batches.
 *
 * @public
 */
export type TransportOptions = { readonly random?: () => number; readonly pollIntervalMs?: number };

/** One open response and the means to end its exchange. */
type Opened = {
  readonly request: ClientRequest;
  readonly response: IncomingMessage;
  readonly status: number;
  readonly headers: ReadonlyMap<string, string>;
  /** Stop the response timer. The event stream uses its idle bound instead. */
  readonly stopTimer: () => void;
  /** End the exchange and close its connection. */
  readonly release: () => void;
};

/**
 * A new idempotency key of an authority epoch: the epoch, a dot and 16
 * random bytes in unpadded base64url. An epoch that is not an identifier of
 * at most 105 characters gives `UnsupportedVersion`.
 *
 * @public
 */
export function commandKey(epoch: string): Outcome<string> {
  if (!validId(epoch) || epoch.length > 105) return failed("UnsupportedVersion");
  return { ok: true, value: `${epoch}.${randomBytes(16).toString("base64url")}` };
}

function validKey(key: string): boolean {
  return key.length > 0 && key.length <= 128 && /^[\x21-\x7e]+$/.test(key);
}

function mediaType(headers: ReadonlyMap<string, string>): string | undefined {
  return headers.get("content-type")?.split(";")[0];
}

function utf8(bytes: Buffer): string | undefined {
  try {
    return new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(bytes);
  } catch (error) {
    if (error instanceof TypeError) return undefined;
    throw error;
  }
}

/** The end of a follow loop that a failure gives, or `null` when it reconnects or polls. */
function followEnd(failure: ClientFailure, cursor: string): FollowEnd | null {
  if (failure.kind === "ClientClosed") return { kind: "closed" };
  if (failure.kind === "Refused" && failure.status === 410) return { kind: "resnapshot", cursor, failure };
  if ((failure.kind === "Refused" && failure.status === 401) || failure.kind === "CredentialUnavailable"
    || failure.kind === "CredentialChanged") return { kind: "refused", cursor, failure };
  return null;
}

/**
 * The transport of one manager session. It is bound to the endpoint, the CA
 * file and the credential of one loaded profile.
 *
 * @public
 */
export class ManagerTransport {
  readonly #profile: ClientProfile;
  readonly #random: () => number;
  readonly #pollIntervalMs: number;
  readonly #active = new Set<ClientRequest>();
  readonly #streams = new Set<ClientRequest>();
  /** The number of `dropStream` calls, so that a stream that was opening during a drop is dropped too. */
  #drops = 0;
  readonly #sleepers = new Set<() => void>();
  #closed = false;

  constructor(profile: ClientProfile, options: TransportOptions = {}) {
    this.#profile = profile;
    this.#random = options.random ?? Math.random;
    this.#pollIntervalMs = options.pollIntervalMs ?? POLL_INTERVAL_MS;
  }

  /** Whether `close` was called. */
  get closed(): boolean {
    return this.#closed;
  }

  /**
   * Abort every open request, the open event stream and every wait. Every
   * later call and every late result gives `ClientClosed`.
   */
  close(): void {
    this.#closed = true;
    for (const request of this.#active) request.destroy();
    this.#active.clear();
    for (const wake of this.#sleepers) wake();
  }

  /**
   * Close the open event stream as a dropped connection does, and keep the
   * transport open. A stream that is still opening at the call is closed
   * when its response arrives, before it delivers anything. The open
   * `streamEvents` call gives `TransportUnavailable`, so `followEvents`
   * reconnects with the last complete event identifier, or polls when its
   * preference is `poll`.
   */
  dropStream(): void {
    this.#drops += 1;
    for (const request of this.#streams) request.destroy();
  }

  /** One GET of a resource below `/v1/`, with the `ETag` of the response. */
  get(resource: string): Promise<Outcome<ClientResponse>> {
    return this.#exchangeJson("GET", resource, {}, null);
  }

  /**
   * One POST of a JSON body with its idempotency key and, when given, its
   * `If-Match` entity tag. The transport sends it once and never resends it.
   */
  async post(resource: string, body: JsonValue, command: CommandHeaders): Promise<Outcome<ClientResponse>> {
    const bytes = Buffer.from(encodeJson(body), "utf8");
    if (bytes.length > COMMAND_BYTES) return TOO_LARGE;
    if (!validKey(command.idempotencyKey) || (command.ifMatch !== null && !validETag(command.ifMatch))) return INVALID;
    const headers: Record<string, string> = { "Content-Type": "application/json", "Idempotency-Key": command.idempotencyKey };
    if (command.ifMatch !== null) headers["If-Match"] = command.ifMatch;
    return this.#exchangeJson("POST", resource, headers, bytes);
  }

  /**
   * One POST of raw bytes with `Content-Type: application/octet-stream`, its
   * idempotency key and, when given, its `If-Match` entity tag, as a capture
   * sends them. The body is at most `CAPTURE_BYTES`. The response is JSON,
   * and the transport sends the bytes once and never resends them.
   */
  async postBytes(resource: string, bytes: Uint8Array, command: CommandHeaders): Promise<Outcome<ClientResponse>> {
    if (bytes.length > CAPTURE_BYTES) return TOO_LARGE;
    if (!validKey(command.idempotencyKey) || (command.ifMatch !== null && !validETag(command.ifMatch))) return INVALID;
    const headers: Record<string, string> = { "Content-Type": "application/octet-stream", "Idempotency-Key": command.idempotencyKey };
    if (command.ifMatch !== null) headers["If-Match"] = command.ifMatch;
    return this.#exchangeJson("POST", resource, headers, Buffer.from(bytes));
  }

  /**
   * One GET of an artifact download, verified as `downloadVerified` of
   * `Agentic.Manager.Client` verifies it. The size is at most
   * `ARTIFACT_BYTES` and the digest is 64 lowercase hexadecimal digits, or
   * the call gives `InvalidResponse` before any request. A response other
   * than 200 gives the failure of its problem response. A 200 response must
   * have `application/octet-stream`, `Cache-Control: no-store`,
   * `X-Content-Type-Options: nosniff` and an `attachment` disposition, and
   * its exact bytes must have the stated size and SHA-256, or the call gives
   * `InvalidResponse`. The bytes are never decoded or reserialized.
   */
  async downloadVerified(resource: string, size: bigint, sha256: string): Promise<Outcome<Buffer>> {
    if (size < 0n || size > BigInt(ARTIFACT_BYTES) || !/^[0-9a-f]{64}$/.test(sha256)) return INVALID;
    const opened = await this.#open("GET", resource, { Accept: "application/octet-stream" }, null);
    if (!opened.ok) return opened;
    const { status, headers } = opened.value;
    const bytes = await this.#consume(opened.value, status === 200 ? ARTIFACT_BYTES : RESPONSE_BYTES);
    if (!bytes.ok) return bytes;
    if (status !== 200) return this.#problem(status, headers, bytes.value);
    if (mediaType(headers) !== "application/octet-stream" || headers.get("cache-control") !== "no-store"
      || headers.get("x-content-type-options") !== "nosniff" || !(headers.get("content-disposition") ?? "").startsWith("attachment")
      || BigInt(bytes.value.length) !== size || createHash("sha256").update(bytes.value).digest("hex") !== sha256) return INVALID;
    return { ok: true, value: bytes.value };
  }

  /** One JSON polling batch of `/v1/events` after the cursor, sent in `Last-Event-ID`. */
  async pollEvents(cursor: string): Promise<Outcome<EventBatch>> {
    if (!validCursor(cursor)) return INVALID;
    const response = await this.#exchangeJson("GET", "/v1/events", { "Last-Event-ID": cursor }, null);
    if (!response.ok) return response;
    return response.value.status === 200 ? decodeEventBatch(response.value.value) : INVALID;
  }

  /**
   * One SSE connection to `/v1/events` that resumes after the cursor, sent in
   * `Last-Event-ID`. It requires status 200, `text/event-stream` and
   * `Cache-Control: no-store`, and gives each complete invalidation and
   * heartbeat to `deliver` in order. It ends when the manager ends the
   * response or when `idleMs`, at most `RECONNECT_IDLE_MS`, passes without a
   * byte, and it then gives the last complete event identifier. A refusal
   * gives the failure of its problem response. It never reconnects by itself.
   */
  streamEvents(cursor: string, deliver: (item: StreamItem) => void, idleMs: number = RECONNECT_IDLE_MS): Promise<Outcome<string>> {
    return this.#streamEvents(cursor, deliver, idleMs, () => undefined);
  }

  /** `streamEvents`, with `accepted` called once when the stream response is accepted. */
  async #streamEvents(cursor: string, deliver: (item: StreamItem) => void, idleMs: number, accepted: () => void): Promise<Outcome<string>> {
    if (!validCursor(cursor) || !(idleMs > 0 && idleMs <= RECONNECT_IDLE_MS)) return INVALID;
    const drops = this.#drops;
    const opened = await this.#open("GET", "/v1/events", { Accept: "text/event-stream", "Last-Event-ID": cursor }, null);
    if (!opened.ok) return opened;
    if (drops !== this.#drops) {
      // A drop while the stream was opening drops this stream as well.
      opened.value.release();
      return TRANSPORT;
    }
    const { response, status, headers, stopTimer, request } = opened.value;
    this.#streams.add(request);
    const release = () => {
      this.#streams.delete(request);
      opened.value.release();
    };
    if (status !== 200) {
      const body = await this.#consume({ ...opened.value, release }, RESPONSE_BYTES);
      return body.ok ? this.#problem(status, headers, body.value) : body;
    }
    if (mediaType(headers) !== "text/event-stream" || headers.get("cache-control") !== "no-store") {
      release();
      return INVALID;
    }
    stopTimer();
    accepted();
    return new Promise((resolve) => {
      let parser = newSseParser(cursor);
      let settled = false;
      let idle: NodeJS.Timeout | undefined;
      const settle = (outcome: Outcome<string>) => {
        if (settled) return;
        settled = true;
        clearTimeout(idle);
        release();
        resolve(this.#fence(outcome));
      };
      const finish = () => {
        const last = closeSse(parser);
        settle(last === null ? INVALID : { ok: true, value: last });
      };
      const arm = () => {
        clearTimeout(idle);
        idle = setTimeout(finish, idleMs);
      };
      arm();
      response.on("data", (chunk: Buffer) => {
        if (settled) return;
        arm();
        const fed = feedSse(parser, chunk);
        if (!fed.ok) return settle(fed);
        parser = fed.value.parser;
        const items: StreamItem[] = [];
        for (const block of fed.value.blocks) {
          if (block.kind === "heartbeat") items.push({ kind: "heartbeat" });
          else if (block.kind === "dispatch") {
            const event = decodeEventBlock(block.event);
            if (!event.ok) return settle(event);
            items.push({ kind: "invalidation", event: event.value });
          }
        }
        for (const item of items) {
          if (this.#closed) return settle(CLOSED);
          deliver(item);
        }
      });
      response.on("end", finish);
      response.on("close", () => settle(TRANSPORT));
    });
  }

  /**
   * Follow `/v1/events` from a cursor until `close`, a 410 refusal or a
   * credential refusal. After the manager ends the stream or a failure, it
   * reconnects with `Last-Event-ID` set to the last complete event
   * identifier after the jittered reconnection backoff. A connection that
   * delivered an item resets the backoff. After `STREAM_FAILURE_LIMIT`
   * consecutive ends without a delivery, or after another refusal of the
   * stream, it polls the same resource every `pollIntervalMs` from the
   * cursor, and it connects the stream again when the backoff has passed.
   * While `prefer` gives `poll`, it polls from the cursor and connects no
   * stream, and it connects the stream again after `prefer` gives `sse`.
   */
  async followEvents(start: string, deliver: (item: StreamItem, via: Delivery) => void, options: FollowOptions = {}): Promise<FollowEnd> {
    const prefer = options.prefer ?? (() => "sse");
    const connected = options.connected ?? (() => undefined);
    const state = options.state ?? (() => undefined);
    let cursor = start;
    let backoff: Backoff = INITIAL_BACKOFF;
    let failures = 0;
    for (;;) {
      if (prefer() === "poll") {
        const polled = await this.#pollUntil(cursor, () => prefer() !== "poll", deliver, connected, state);
        if (typeof polled !== "string") return polled;
        cursor = polled;
        backoff = INITIAL_BACKOFF;
        failures = 0;
        continue;
      }
      let delivered = false;
      let opened = false;
      let latest = cursor;
      connected("stream", cursor);
      const outcome = await this.#streamEvents(cursor, (item) => {
        delivered = true;
        if (item.kind === "invalidation") latest = item.event.id;
        deliver(item, "stream");
      }, RECONNECT_IDLE_MS, () => {
        opened = true;
        state("live");
      });
      cursor = outcome.ok ? outcome.value : latest;
      const failure = outcome.ok ? null : outcome.failure;
      const ended = failure === null ? null : followEnd(failure, cursor);
      if (ended !== null) return ended;
      if (!opened) state("unreachable");
      failures = (delivered ? 0 : failures) + 1;
      const { delay, next } = reconnectDelay(delivered ? INITIAL_BACKOFF : backoff);
      backoff = next;
      const wait = jitteredMicroseconds(delay, this.#random()) / 1000;
      if (failure?.kind === "Refused" || failures >= STREAM_FAILURE_LIMIT) {
        const due = Date.now() + wait;
        const polled = await this.#pollUntil(cursor, () => Date.now() >= due || prefer() === "poll", deliver, connected, state);
        if (typeof polled !== "string") return polled;
        cursor = polled;
      } else {
        await this.#sleep(wait);
        if (this.#closed) return { kind: "closed" };
      }
    }
  }

  /** Poll from the cursor until `done` holds after a batch, and give the cursor reached, or the end. */
  async #pollUntil(start: string, done: () => boolean, deliver: (item: StreamItem, via: Delivery) => void,
    connected: (via: Delivery, cursor: string) => void, state: (state: FollowState) => void): Promise<string | FollowEnd> {
    let cursor = start;
    for (;;) {
      connected("poll", cursor);
      const batch = await this.pollEvents(cursor);
      if (this.#closed) return { kind: "closed" };
      state(batch.ok ? "polling" : "unreachable");
      if (batch.ok) {
        for (const event of batch.value.events) {
          if (this.#closed) return { kind: "closed" };
          deliver({ kind: "invalidation", event }, "poll");
        }
        cursor = batch.value.cursor;
        if (batch.value.hasMore) continue;
      } else {
        const ended = followEnd(batch.failure, cursor);
        if (ended !== null) return ended;
      }
      await this.#sleep(this.#pollIntervalMs);
      if (this.#closed) return { kind: "closed" };
      if (done()) return cursor;
    }
  }

  #sleep(milliseconds: number): Promise<void> {
    return new Promise((resolve) => {
      if (this.#closed) return resolve();
      const wake = () => {
        clearTimeout(timer);
        this.#sleepers.delete(wake);
        resolve();
      };
      const timer = setTimeout(wake, milliseconds);
      this.#sleepers.add(wake);
    });
  }

  #fence<Value>(outcome: Outcome<Value>): Outcome<Value> {
    return this.#closed ? CLOSED : outcome;
  }

  /** The failure of a problem response. */
  #problem(status: number, headers: ReadonlyMap<string, string>, bytes: Buffer): Outcome<never> {
    if (mediaType(headers) !== "application/problem+json" || headers.get("cache-control") !== "no-store") return INVALID;
    const text = utf8(bytes);
    const value = text === undefined ? undefined : tryParseJson(text);
    return value === undefined ? INVALID : { ok: false, failure: problemFailure(status, value) };
  }

  async #exchangeJson(method: "GET" | "POST", resource: string, headers: Record<string, string>, body: Buffer | null): Promise<Outcome<ClientResponse>> {
    const opened = await this.#open(method, resource, { Accept: "application/json", ...headers }, body);
    if (!opened.ok) return opened;
    const { status, headers: received } = opened.value;
    const bytes = await this.#consume(opened.value, RESPONSE_BYTES);
    if (!bytes.ok) return bytes;
    if (status < 200 || status >= 300) return this.#problem(status, received, bytes.value);
    if (mediaType(received) !== "application/json" || received.get("cache-control") !== "no-store") return INVALID;
    const text = utf8(bytes.value);
    const value = text === undefined ? undefined : tryParseJson(text);
    if (value === undefined) return INVALID;
    const version = isJsonObject(value) ? value.version : undefined;
    if (!(version instanceof JsonNumber) || !numberEqual(version, ONE)) return failed("UnsupportedVersion");
    const etag = received.get("etag") ?? null;
    const location = received.get("location") ?? null;
    if ((etag !== null && !validETag(etag)) || (location !== null && !validResource(location))) return INVALID;
    return { ok: true, value: { status, value, etag, location, bytes: bytes.value.length } };
  }

  /** The whole body of an open response, refused with `ResponseTooLarge` above the limit. */
  #consume(opened: Opened, limit: number): Promise<Outcome<Buffer>> {
    const { response, headers, release } = opened;
    const declared = headers.get("content-length");
    if (declared !== undefined && Number(declared) > limit) {
      release();
      return Promise.resolve(this.#fence(TOO_LARGE));
    }
    return new Promise((resolve) => {
      const chunks: Buffer[] = [];
      let total = 0;
      let settled = false;
      const settle = (outcome: Outcome<Buffer>) => {
        if (settled) return;
        settled = true;
        release();
        resolve(this.#fence(outcome));
      };
      response.on("data", (chunk: Buffer) => {
        total += chunk.length;
        if (total > limit) settle(TOO_LARGE);
        else chunks.push(chunk);
      });
      response.on("end", () => settle({ ok: true, value: Buffer.concat(chunks) }));
      response.on("close", () => settle(TRANSPORT));
    });
  }

  /**
   * Send one request with the bearer of one credential read and give its
   * open response after the header checks. A redirect status gives
   * `RedirectRefused`, a `Content-Encoding` or a repeated framing header
   * gives `InvalidResponse`, and too many or too large headers give
   * `ResponseTooLarge`.
   */
  async #open(method: "GET" | "POST", resource: string, headers: Record<string, string>, body: Buffer | null): Promise<Outcome<Opened>> {
    if (this.#closed) return CLOSED;
    if (!validResource(resource)) return failed("InvalidEndpoint");
    const authorization = await this.#profile.authorization();
    if (!authorization.ok) return this.#fence(authorization);
    if (this.#closed) return CLOSED;
    const { host, port } = this.#profile.endpoint;
    return new Promise((resolve) => {
      const request = httpsRequest({
        host,
        port,
        method,
        path: resource,
        servername: isIP(host) === 0 ? host : undefined,
        ca: this.#profile.ca,
        minVersion: "TLSv1.3",
        maxVersion: "TLSv1.3",
        agent: false,
        maxHeaderSize: HEADER_BYTES,
        headers: {
          ...headers,
          Authorization: authorization.value,
          "Accept-Encoding": "identity",
          Connection: "close",
          ...(body === null ? {} : { "Content-Length": String(body.length) }),
        },
      });
      this.#active.add(request);
      const timer = setTimeout(() => request.destroy(), RESPONSE_TIMEOUT_MS);
      const release = () => {
        clearTimeout(timer);
        this.#active.delete(request);
        request.destroy();
      };
      let settled = false;
      const settle = (outcome: Outcome<Opened>) => {
        if (settled) return;
        settled = true;
        const fenced = this.#fence(outcome);
        if (!fenced.ok) release();
        resolve(fenced);
      };
      request.on("error", () => settle(TRANSPORT));
      request.on("close", () => settle(TRANSPORT));
      request.on("response", (response) => {
        // The consumer observes a failed body through its close event.
        response.on("error", () => undefined);
        const names = new Map<string, number>();
        const received = new Map<string, string>();
        let size = 0;
        for (let index = 0; index + 1 < response.rawHeaders.length; index += 2) {
          const name = response.rawHeaders[index].toLowerCase();
          const value = response.rawHeaders[index + 1];
          size += name.length + value.length + 4;
          names.set(name, (names.get(name) ?? 0) + 1);
          if (!received.has(name)) received.set(name, value);
        }
        const status = response.statusCode ?? 0;
        if (names.size > HEADER_COUNT || response.rawHeaders.length / 2 > HEADER_COUNT || size > HEADER_BYTES) return settle(TOO_LARGE);
        if (UNIQUE_HEADERS.some((name) => (names.get(name) ?? 0) > 1)
          || (received.has("transfer-encoding") && received.has("content-length"))) return settle(INVALID);
        if (status >= 300 && status < 400) return settle(failed("RedirectRefused"));
        if (received.has("content-encoding")) return settle(INVALID);
        settle({ ok: true, value: { request, response, status, headers: received, stopTimer: () => clearTimeout(timer), release } });
      });
      request.end(body ?? undefined);
    });
  }
}
