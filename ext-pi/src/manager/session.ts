/**
 * One endpoint-bound manager session over the versioned `/v1` protocol.
 *
 * This module states the session rules of `connectClient`, `reference`,
 * `getPageSet`, `loadOverview`, `prepareCommand`, `sendCommand`,
 * `uncertainPending` and `downloadVerified` of `Agentic.Manager.Client`, and
 * the refresh rules of the service lane of the TUI, in TypeScript. It
 * imports no Haskell code. A session reads `/v1/capabilities` once when it
 * connects, and it keeps the authority epoch of that read for the
 * idempotency keys of its commands.
 *
 * Each `Reference` carries the endpoint identity of the session binding that
 * made it. A binding has a new random identity, so a reference of another
 * session, or of a binding before `switchEndpoint`, gives `WrongEndpoint`
 * and is never sent to the current endpoint.
 *
 * A decoded value or a reference grants no ownership, approval, supervision
 * or control authority. The session never resends a command by itself.
 *
 * @packageDocumentation
 */

import { randomBytes } from "node:crypto";
import { validCursor, validId, validRevision, validResource, type ClientFailure, type InvalidationEvent, type Outcome } from "./events.ts";
import { boundedInteger, isJsonArray, isJsonObject, jsonEqual, jsonMember, JsonNumber, type JsonObject, type JsonValue } from "./json.ts";
import type { ClientProfile } from "./profile.ts";
import {
  advanceGeneration,
  completeFetch,
  invalidateResource,
  newRefresh,
  reconcile,
  reconcileRead,
  type Reconciled,
  type Refresh,
  type RefreshAction,
  type Uncertain,
} from "./refresh.ts";
import { decodeCommandReceipt, decodeOverviewMember, type CommandReceipt, type OverviewMember } from "./resources.ts";
import {
  commandKey,
  ManagerTransport,
  type ClientResponse,
  type Delivery,
  type DeliveryPreference,
  type FollowEnd,
  type FollowState,
  type TransportOptions,
} from "./transport.ts";

function failed(kind: "InvalidResponse" | "WrongEndpoint" | "InvalidEndpoint" | "UnsupportedVersion" | "ClientClosed"): Outcome<never> {
  return { ok: false, failure: { kind } };
}

const INVALID = failed("InvalidResponse");

/**
 * A resource of one session binding: the endpoint identity of the binding
 * and a resource below `/v1/`.
 *
 * @public
 */
export type Reference = { readonly endpoint: string; readonly uri: string };

/**
 * One successful read of a resource: its reference, its status, its entity
 * tag and its lossless value.
 *
 * @public
 */
export type Observed = { readonly reference: Reference; readonly status: number; readonly etag: string | null; readonly value: JsonValue };

/**
 * One member of the overview: its decoded member, the reference of its
 * detail resource, which is the resource of its invalidations, and its
 * revision.
 *
 * @public
 */
export type OverviewItem = { readonly member: OverviewMember; readonly reference: Reference; readonly revision: string };

/**
 * One complete overview with the event cursor and the oldest resume
 * boundary of its database boundary.
 *
 * @public
 */
export type Overview = { readonly cursor: string; readonly oldestCursor: string; readonly items: readonly OverviewItem[] };

/**
 * A prepared command: its target, the exact JSON body, the idempotency key
 * of the authority epoch, and the optional `If-Match` entity tag. Sending it
 * again sends the same bytes under the same key and precondition.
 *
 * @public
 */
export type PendingCommand = {
  readonly reference: Reference;
  readonly body: JsonValue;
  readonly idempotencyKey: string;
  readonly ifMatch: string | null;
};

/**
 * The outcome of one send. `delivered` is a 2xx response with the location
 * that the manager names, and for a 202 response the decoded receipt.
 * `refused` is a 412 `stale-revision` refusal, which proves that the manager
 * holds no command under the key. Every other failure and every 2xx
 * response that does not agree with the command is `uncertain`, and the
 * command is kept unchanged for reconciliation.
 *
 * @public
 */
export type SendOutcome =
  | { readonly kind: "delivered"; readonly response: ClientResponse; readonly location: Reference; readonly receipt: CommandReceipt | null }
  | { readonly kind: "refused"; readonly failure: ClientFailure }
  | { readonly kind: "uncertain"; readonly failure: ClientFailure | null; readonly uncertain: Uncertain<PendingCommand, Reference> };

/**
 * The requests of a session to its transport. `ManagerTransport` is the
 * transport of every session, and a test can give another implementation.
 *
 * @public
 */
export type SessionTransport = Pick<ManagerTransport, "get" | "post" | "followEvents" | "pollEvents" | "downloadVerified" | "dropStream" | "close">;

/**
 * The delivery state of a session: `connecting` until its follow loop first
 * reports a state, and then the last state of the follow loop of its current
 * binding.
 *
 * @public
 */
export type DeliveryState = "connecting" | FollowState;

/**
 * Options of a session. `delivery` is the initial delivery preference.
 * `onEvent` receives each delivered invalidation with its delivery, and
 * `onConnect` receives the delivery and the `Last-Event-ID` cursor of each
 * stream connection and each polling batch. `onChange` is called after each
 * install of a read or of the overview, each change of the delivery state,
 * the end of the follow loop, a switch and `close`. `transport` makes the
 * transport of each binding, and it defaults to `ManagerTransport`.
 *
 * @public
 */
export type SessionOptions = TransportOptions & {
  readonly delivery?: DeliveryPreference;
  readonly onEvent?: (event: InvalidationEvent, via: Delivery) => void;
  readonly onConnect?: (via: Delivery, cursor: string) => void;
  readonly onChange?: () => void;
  readonly transport?: (profile: ClientProfile, options: TransportOptions) => SessionTransport;
};

/** The refresh key of the overview. */
const OVERVIEW = "/v1/snapshot";

/** The wait before a watched resource is read again after a transient read refusal, in milliseconds. */
const REREAD_MS = 100;

/** Whether a read failure is the declared page-set capacity or storage refusal that a later read can clear. */
function transientRead(failure: ClientFailure): boolean {
  return failure.kind === "Refused" && ((failure.status === 429 && failure.code === "storage-quota")
    || (failure.status === 503 && failure.code === "storage-unavailable"));
}

const MEMBER_COLLECTIONS: Readonly<Record<OverviewMember["kind"], string>> = {
  request: "requests",
  preparation: "preparations",
  run: "runs",
  decision: "decisions",
};

// ---------------------------------------------------------------------------
// Capabilities, as `requireCapabilities` of `Agentic.Manager.Client` checks them.

const NUMERIC_VERSIONS: readonly (readonly [string, readonly number[]])[] = [
  ["api", [1]], ["snapshot", [1]], ["event", [1]], ["descriptor", [2, 3]], ["frontendSession", [1, 2]], ["control", [1, 2]],
  ["runtimeProtocol", [1, 2, 3]], ["runtimeStore", [1, 2]], ["managerStore", [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]],
  ["invocation", [1]],
];

const FIXED_LIMITS: readonly (readonly [string, bigint])[] = [
  ["requestTargetBytes", 8192n], ["headerBytes", 16384n], ["headerFields", 100n], ["jsonBodyBytes", 2097152n], ["jsonDepth", 64n],
  ["nativeControlBytes", 1048576n], ["captureBytes", 67108864n], ["aggregateInputBytes", 67108864n], ["artifactBytes", 67108864n],
  ["sseBlockBytes", 16384n], ["pageBytes", 1048576n], ["pageSetBytes", 67108864n], ["pageSetsPerClient", 2n],
  ["pageSetLifetimeSeconds", 60n], ["queuedRequests", 100n], ["maxReservations", 16n], ["reviewLifetimeSeconds", 600n],
  ["sseReadersPerClient", 2n], ["ssePendingBytesPerReader", 1048576n], ["replaySeconds", 604800n], ["replayBytes", 268435456n],
  ["heartbeatSeconds", 15n], ["reconnectIdleSeconds", 45n], ["reconnectBackoffMaxSeconds", 30n], ["ordinaryMutationsPerMinute", 30n],
];

const CONFIGURED_LIMITS: readonly (readonly [string, bigint])[] = [
  ...["drafts", "globalDrafts", "globalCaptureBytes", "globalPageSets", "globalConnections", "globalDatabaseReaders",
    "globalMutationLedgerBytes", "safetyControlsPerMinute"].map((name) => [name, 2147483647n] as const),
  ["executionReservations", 16n],
];

function exactFields(value: JsonValue | undefined, names: readonly string[]): JsonObject | undefined {
  if (value === undefined || !isJsonObject(value)) return undefined;
  const keys = Object.keys(value);
  return keys.length === names.length && names.every((name) => Object.hasOwn(value, name)) ? value : undefined;
}

function distinct(values: readonly unknown[]): boolean {
  return new Set(values).size === values.length;
}

function texts(value: JsonValue | undefined): string[] | undefined {
  if (value === undefined || !isJsonArray(value)) return undefined;
  const strings = value.filter((item): item is string => typeof item === "string");
  return strings.length === value.length ? strings : undefined;
}

function integers(value: JsonValue | undefined): number[] | undefined {
  if (value === undefined || !isJsonArray(value)) return undefined;
  const numbers = value.map((item) => (item instanceof JsonNumber ? boundedInteger(item, -2147483648n, 2147483647n) : undefined));
  return numbers.every((item) => item !== undefined) ? numbers.map(Number) : undefined;
}

function limitOf(fields: JsonObject, name: string): bigint | undefined {
  const value = jsonMember(fields, name);
  return value instanceof JsonNumber ? boundedInteger(value, -(2n ** 63n), 2n ** 63n) : undefined;
}

/** The checked capabilities and their authority epoch. */
type Capabilities = { readonly fields: JsonObject; readonly epoch: string };

/** Whether the capabilities agree with this client: `UnsupportedVersion` for the versions, `InvalidResponse` otherwise. */
function checkCapabilities(value: JsonValue): Outcome<Capabilities> {
  const fields = exactFields(value, ["version", "authorityEpoch", "streamId", "versions", "scopes", "profileIds", "transports", "limits"]);
  if (fields === undefined) return INVALID;
  const versions = exactFields(jsonMember(fields, "versions"), ["frontendManifest", ...NUMERIC_VERSIONS.map(([name]) => name)]);
  const manifests = versions === undefined ? undefined : texts(jsonMember(versions, "frontendManifest"));
  if (versions === undefined || manifests === undefined || manifests.length === 0 || !distinct(manifests)
    || !manifests.every((name) => ["legacy", "2", "3"].includes(name))
    || !NUMERIC_VERSIONS.every(([name, supported]) => {
      const values = integers(jsonMember(versions, name));
      return values !== undefined && values.length > 0 && distinct(values) && values.every((item) => supported.includes(item));
    })) return failed("UnsupportedVersion");
  const version = jsonMember(fields, "version");
  const epoch = jsonMember(fields, "authorityEpoch");
  const stream = jsonMember(fields, "streamId");
  const scopes = texts(jsonMember(fields, "scopes"));
  const profiles = texts(jsonMember(fields, "profileIds"));
  const transports = texts(jsonMember(fields, "transports"));
  if (!(version instanceof JsonNumber) || boundedInteger(version, 1n, 1n) === undefined || typeof epoch !== "string" || !validId(epoch)
    || epoch.length > 105 || typeof stream !== "string" || !validId(stream) || scopes === undefined || scopes.length > 4
    || !distinct(scopes) || !scopes.every((scope) => ["observe", "submit", "control", "export"].includes(scope))
    || profiles === undefined || profiles.length > 256 || !profiles.every(validId) || !distinct(profiles)
    || transports === undefined || transports.length !== 2 || !distinct(transports)
    || !transports.every((name) => name === "sse" || name === "polling")) return INVALID;
  const limits = exactFields(jsonMember(fields, "limits"), [...FIXED_LIMITS, ...CONFIGURED_LIMITS].map(([name]) => name));
  if (limits === undefined || !FIXED_LIMITS.every(([name, expected]) => limitOf(limits, name) === expected)
    || !CONFIGURED_LIMITS.every(([name, maximum]) => {
      const configured = limitOf(limits, name);
      return configured !== undefined && configured > 0n && configured <= maximum;
    })) return INVALID;
  return { ok: true, value: { fields, epoch } };
}

// ---------------------------------------------------------------------------
// Page sets, as `getPageSet` of `Agentic.Manager.Client` reads them.

type PageInfo = {
  readonly setId: string;
  readonly revision: string;
  readonly expiresAt: string;
  readonly expiry: number;
  readonly index: number;
  readonly total: number;
  readonly next: string | null;
};

function pageInfo(value: JsonValue | undefined): PageInfo | undefined {
  const fields = exactFields(value, ["setId", "revision", "expiresAt", "index", "totalItems", "next"]);
  if (fields === undefined) return undefined;
  const setId = jsonMember(fields, "setId");
  const revision = jsonMember(fields, "revision");
  const expiresAt = jsonMember(fields, "expiresAt");
  const index = jsonMember(fields, "index");
  const total = jsonMember(fields, "totalItems");
  const next = jsonMember(fields, "next");
  if (typeof setId !== "string" || !validId(setId) || typeof revision !== "string" || !validId(revision)
    || typeof expiresAt !== "string" || expiresAt.length > 40 || !(index instanceof JsonNumber) || !(total instanceof JsonNumber)
    || (next !== null && (typeof next !== "string" || !validResource(next)))) return undefined;
  const expiry = Date.parse(expiresAt.toUpperCase());
  const indexValue = boundedInteger(index, 0n, 65535n);
  const totalValue = boundedInteger(total, 0n, 1048576n);
  if (Number.isNaN(expiry) || indexValue === undefined || totalValue === undefined) return undefined;
  return { setId, revision, expiresAt, expiry, index: Number(indexValue), total: Number(totalValue), next };
}

/** The path and the sorted query pairs without `pageToken`, or `undefined` for a repeated query name. */
function pageScope(uri: string): string | undefined {
  const mark = uri.indexOf("?");
  const path = mark < 0 ? uri : uri.slice(0, mark);
  const pairs = mark < 0 ? [] : [...new URLSearchParams(uri.slice(mark + 1))];
  if (!distinct(pairs.map(([name]) => name))) return undefined;
  const kept = pairs.filter(([name]) => name !== "pageToken").sort(([a, x], [b, y]) => (a < b ? -1 : a > b ? 1 : x < y ? -1 : x > y ? 1 : 0));
  return JSON.stringify([path, kept]);
}

/** The repeated fields of a page set, without its `page` and `items` members. */
function repeatedFields(fields: JsonObject): JsonObject {
  return Object.fromEntries(Object.entries(fields).filter(([name]) => name !== "page" && name !== "items"));
}

/** The largest number of bytes of one page set. */
const PAGE_SET_BYTES = 67108864;

/**
 * One manager session bound to the endpoint, the CA file and the credential
 * of one loaded profile, and to the capability epoch of its connection.
 *
 * Its refresh coordinator serializes the reads of each watched resource. An
 * invalidation of a resource marks every watched resource that equals it or
 * lies above or below it, and an invalidation of a request, preparation, run
 * or decision marks the overview. Invalidations during a read coalesce into
 * one later read, and a read of an earlier generation is discarded.
 *
 * @public
 */
export class ManagerSession {
  #transport: SessionTransport;
  #endpoint: string;
  #identity: string;
  #capabilities: Capabilities;
  readonly #options: SessionOptions;
  #delivery: DeliveryPreference;
  #refresh: Refresh<string> = newRefresh();
  readonly #watched = new Set<string>();
  readonly #installed = new Map<string, Outcome<Observed>>();
  #overview: Outcome<Overview> | undefined;
  readonly #waiters = new Set<() => void>();
  /** The read lane: watched resources are read one at a time, in order. */
  #lane: Promise<void> = Promise.resolve();
  #following: Promise<FollowEnd> | undefined;
  #followEnd: FollowEnd | undefined;
  #deliveryState: DeliveryState = "connecting";
  #closed = false;

  private constructor(transport: SessionTransport, endpoint: string, identity: string, capabilities: Capabilities, options: SessionOptions) {
    this.#transport = transport;
    this.#endpoint = endpoint;
    this.#identity = identity;
    this.#capabilities = capabilities;
    this.#options = options;
    this.#delivery = options.delivery ?? "sse";
  }

  /**
   * Connect to the endpoint of a loaded profile. The session reads
   * `/v1/capabilities` and refuses versions, scopes, transports or limits
   * that this client does not support.
   */
  static async connect(profile: ClientProfile, options: SessionOptions = {}): Promise<Outcome<ManagerSession>> {
    const bound = await ManagerSession.#bind(profile, options);
    if (!bound.ok) return bound;
    const { transport, identity, capabilities } = bound.value;
    return { ok: true, value: new ManagerSession(transport, profile.endpoint.url, identity, capabilities, options) };
  }

  static async #bind(profile: ClientProfile, options: SessionOptions)
    : Promise<Outcome<{ transport: SessionTransport; identity: string; capabilities: Capabilities }>> {
    const transport = options.transport?.(profile, options) ?? new ManagerTransport(profile, options);
    const response = await transport.get("/v1/capabilities");
    const capabilities = !response.ok ? response : response.value.status === 200 ? checkCapabilities(response.value.value) : INVALID;
    if (!capabilities.ok) {
      transport.close();
      return capabilities;
    }
    return { ok: true, value: { transport, identity: randomBytes(16).toString("hex"), capabilities: capabilities.value } };
  }

  /** The endpoint URL of the current binding. */
  get endpoint(): string {
    return this.#endpoint;
  }

  /** The endpoint identity of the current binding. */
  get identity(): string {
    return this.#identity;
  }

  /** The authority epoch of the capabilities of the current binding. */
  get epoch(): string {
    return this.#capabilities.epoch;
  }

  /** The capabilities of the current binding. */
  get capabilities(): JsonObject {
    return this.#capabilities.fields;
  }

  /** The current refresh generation. */
  get generation(): number {
    return this.#refresh.generation;
  }

  /** The current delivery preference. */
  get delivery(): DeliveryPreference {
    return this.#delivery;
  }

  /** The delivery state of the follow loop of the current binding. */
  get deliveryState(): DeliveryState {
    return this.#deliveryState;
  }

  /** Whether `close` was called. */
  get closed(): boolean {
    return this.#closed;
  }

  /** The end of the follow loop, once it has ended. */
  get followEnd(): FollowEnd | undefined {
    return this.#followEnd;
  }

  /** A reference of the current binding, or `InvalidEndpoint` for a resource that is not below `/v1/`. */
  reference(uri: string): Outcome<Reference> {
    return validResource(uri) ? { ok: true, value: { endpoint: this.#identity, uri } } : failed("InvalidEndpoint");
  }

  #check(reference: Reference): Outcome<undefined> {
    if (this.#closed) return failed("ClientClosed");
    return reference.endpoint === this.#identity ? { ok: true, value: undefined } : failed("WrongEndpoint");
  }

  /** One read of a resource of the current binding. A status other than 200 gives `InvalidResponse`. */
  async get(reference: Reference): Promise<Outcome<Observed>> {
    const checked = this.#check(reference);
    if (!checked.ok) return checked;
    const transport = this.#transport;
    const response = await transport.get(reference.uri);
    if (transport !== this.#transport) return failed("WrongEndpoint");
    if (!response.ok) return response;
    if (response.value.status !== 200) return INVALID;
    return { ok: true, value: { reference, status: 200, etag: response.value.etag, value: response.value.value } };
  }

  /**
   * One complete page set from its first page. Every page repeats the same
   * set identity, revision, expiry, total and metadata, the indexes follow
   * each other, each page has at most 256 items, the set holds at most 64
   * MiB, and every page arrives before the expiry. Any other page refuses
   * the whole set with `InvalidResponse`, and no partial set is given. A
   * page that arrives after `switchEndpoint` gives `WrongEndpoint`.
   */
  async pageSet(first: Reference): Promise<Outcome<{ metadata: JsonObject; items: JsonValue[] }>> {
    const scope = pageScope(first.uri);
    if (scope === undefined) return INVALID;
    const items: JsonValue[] = [];
    let location = first;
    let stamp: PageInfo | undefined;
    let metadata: JsonObject | undefined;
    let used = 0;
    for (let index = 0; ; index += 1) {
      if (pageScope(location.uri) !== scope) return INVALID;
      const checked = this.#check(location);
      if (!checked.ok) return checked;
      const transport = this.#transport;
      const response = await transport.get(location.uri);
      if (transport !== this.#transport) return failed("WrongEndpoint");
      if (!response.ok) return response;
      const { status, value, bytes } = response.value;
      if (status !== 200 || !isJsonObject(value)) return INVALID;
      const page = pageInfo(jsonMember(value, "page"));
      const pageItems = jsonMember(value, "items");
      if (page === undefined || pageItems === undefined || !isJsonArray(pageItems)) return INVALID;
      const repeated = repeatedFields(value);
      used += bytes;
      items.push(...pageItems);
      if (page.index !== index || Date.now() >= page.expiry || pageItems.length > 256 || items.length > page.total
        || used > PAGE_SET_BYTES
        || (stamp !== undefined && (stamp.setId !== page.setId || stamp.revision !== page.revision
          || stamp.expiresAt !== page.expiresAt || stamp.total !== page.total))
        || (metadata !== undefined && !jsonEqual(metadata, repeated))) return INVALID;
      if (page.next === null) return items.length === page.total ? { ok: true, value: { metadata: repeated, items } } : INVALID;
      if (pageItems.length === 0 || items.length >= page.total || index >= 65535) return INVALID;
      stamp = page;
      metadata = repeated;
      location = { endpoint: location.endpoint, uri: page.next };
    }
  }

  /**
   * The overview page set of `/v1/snapshot`, as `loadOverview` of
   * `Agentic.Manager.Client` assembles it. Its metadata has exactly
   * `version` 1, `snapshotVersion` 1, `cursor` and `oldestCursor`, and each
   * item decodes as an overview member.
   */
  async loadOverview(): Promise<Outcome<Overview>> {
    const first = this.reference(OVERVIEW);
    if (!first.ok) return first;
    const set = await this.pageSet(first.value);
    if (!set.ok) return set;
    const fields = exactFields(set.value.metadata, ["version", "snapshotVersion", "cursor", "oldestCursor"]);
    const version = fields === undefined ? undefined : jsonMember(fields, "version");
    const snapshotVersion = fields === undefined ? undefined : jsonMember(fields, "snapshotVersion");
    const cursor = fields === undefined ? undefined : jsonMember(fields, "cursor");
    const oldestCursor = fields === undefined ? undefined : jsonMember(fields, "oldestCursor");
    if (!(version instanceof JsonNumber) || boundedInteger(version, 1n, 1n) === undefined || !(snapshotVersion instanceof JsonNumber)
      || boundedInteger(snapshotVersion, 1n, 1n) === undefined || typeof cursor !== "string" || !validCursor(cursor)
      || typeof oldestCursor !== "string" || !validCursor(oldestCursor)) return INVALID;
    const items: OverviewItem[] = [];
    for (const value of set.value.items) {
      const member = decodeOverviewMember(value);
      if (!member.ok) return member;
      const { id, revision } = memberIdentity(member.value);
      if (!validId(id) || !validRevision(revision)) return INVALID;
      const reference = this.reference(`/v1/${MEMBER_COLLECTIONS[member.value.kind]}/${id}`);
      if (!reference.ok) return INVALID;
      items.push({ member: member.value, reference: reference.value, revision });
    }
    return { ok: true, value: { cursor, oldestCursor, items } };
  }

  /** The installed overview, once the first overview read has completed. */
  get overview(): Outcome<Overview> | undefined {
    return this.#overview;
  }

  /**
   * Install the overview and follow `/v1/events` from its cursor with the
   * current delivery preference. A 410 refusal of the follow loop advances
   * the generation, reads the overview again, refreshes every watched
   * resource, and follows from the new cursor. It gives the first overview
   * read.
   */
  async start(): Promise<Outcome<Overview>> {
    if (this.#following !== undefined) return failed("InvalidResponse");
    const overview = await this.#bootstrap();
    if (overview.ok) this.#following = this.#follow(overview.value.cursor);
    return overview;
  }

  async #bootstrap(): Promise<Outcome<Overview>> {
    this.#watched.add(OVERVIEW);
    const generation = this.#refresh.generation;
    const overview = await this.loadOverview();
    if (generation === this.#refresh.generation) {
      this.#overview = overview;
      this.#wake();
    }
    return overview;
  }

  async #follow(start: string): Promise<FollowEnd> {
    let cursor = start;
    for (;;) {
      const transport = this.#transport;
      const end = await transport.followEvents(cursor, (item, via) => {
        if (item.kind === "invalidation" && transport === this.#transport) this.#invalidated(item.event, via);
      }, {
        prefer: () => this.#delivery,
        connected: (via, at) => this.#options.onConnect?.(via, at),
        state: (state) => {
          if (transport !== this.#transport || this.#closed || state === this.#deliveryState) return;
          this.#deliveryState = state;
          this.#wake();
        },
      });
      if (end.kind === "resnapshot" && !this.#closed && transport === this.#transport) {
        this.#refresh = advanceGeneration(this.#refresh);
        const overview = await this.#bootstrap();
        if (overview.ok) {
          for (const key of this.#watched) if (key !== OVERVIEW) this.#invalidate(key);
          cursor = overview.value.cursor;
          continue;
        }
      }
      if (transport !== this.#transport && !this.#closed) {
        const overview = this.#overview;
        if (overview !== undefined && overview.ok) {
          cursor = overview.value.cursor;
          continue;
        }
      }
      this.#followEnd = end;
      this.#wake();
      return end;
    }
  }

  #invalidated(event: InvalidationEvent, via: Delivery): void {
    this.#options.onEvent?.(event, via);
    const resource = event.data.resource;
    for (const key of this.#watched) {
      if (key === OVERVIEW ? isMemberResource(resource) : related(key, resource)) this.#invalidate(key);
    }
  }

  /**
   * Watch a resource of the current binding: read it now, and read it again
   * after each related invalidation.
   */
  watch(reference: Reference): Outcome<undefined> {
    const checked = this.#check(reference);
    if (!checked.ok) return checked;
    if (!this.#watched.has(reference.uri)) {
      this.#watched.add(reference.uri);
      this.#invalidate(reference.uri);
    }
    return { ok: true, value: undefined };
  }

  /** The last installed read of a watched resource of the current binding. */
  current(reference: Reference): Outcome<Observed> | undefined {
    return reference.endpoint === this.#identity ? this.#installed.get(reference.uri) : failed("WrongEndpoint");
  }

  #invalidate(key: string): void {
    const step = invalidateResource(key, this.#refresh);
    this.#refresh = step.state;
    this.#perform(step.actions);
  }

  #perform(actions: readonly RefreshAction<string>[]): void {
    for (const action of actions) {
      if (action.kind === "fetch") this.#lane = this.#lane.then(() => this.#fetch(action.key, action.generation));
    }
  }

  async #fetch(key: string, generation: number): Promise<void> {
    if (key === OVERVIEW) {
      const overview = await this.loadOverview();
      this.#complete(key, generation, overview, () => {
        this.#overview = overview;
      });
    } else {
      const observed = await this.get({ endpoint: this.#identity, uri: key });
      this.#complete(key, generation, observed, () => {
        this.#installed.set(key, observed);
      });
    }
  }

  /**
   * Complete the read of a key. An installed read that the manager refused
   * with 429 `storage-quota` or 503 `storage-unavailable` is read again
   * after `REREAD_MS`, because no invalidation follows such a refusal. A
   * read is never a command, so this sends no command again.
   */
  #complete(key: string, generation: number, outcome: Outcome<unknown>, install: () => void): void {
    const step = completeFetch(key, generation, this.#refresh);
    this.#refresh = step.state;
    if (step.actions.some((action) => action.kind === "install")) {
      install();
      this.#wake();
      if (!outcome.ok && transientRead(outcome.failure)) {
        setTimeout(() => {
          if (!this.#closed && generation === this.#refresh.generation && this.#watched.has(key)) this.#invalidate(key);
        }, REREAD_MS);
      }
    }
    this.#perform(step.actions);
  }

  #wake(): void {
    for (const wake of [...this.#waiters]) wake();
    this.#options.onChange?.();
  }

  /**
   * Wait until the installed read of a watched resource satisfies the
   * predicate, and give that read. The resource is watched first. A read
   * failure does not end the wait, since a later invalidation reads the
   * resource again. The wait gives `TransportUnavailable` after `timeoutMs`,
   * and `ClientClosed` after `close`.
   */
  async waitFor(reference: Reference, ready: (observed: Observed) => boolean, timeoutMs: number): Promise<Outcome<Observed>> {
    const watched = this.watch(reference);
    if (!watched.ok) return watched;
    return this.#until(() => {
      const installed = this.current(reference);
      return installed !== undefined && installed.ok && ready(installed.value) ? installed : undefined;
    }, timeoutMs);
  }

  /** Wait until the installed overview satisfies the predicate. */
  async waitForOverview(ready: (overview: Overview) => boolean, timeoutMs: number): Promise<Outcome<Overview>> {
    return this.#until(() => {
      const overview = this.#overview;
      return overview !== undefined && overview.ok && ready(overview.value) ? overview : undefined;
    }, timeoutMs);
  }

  #until<Value>(found: () => Outcome<Value> | undefined, timeoutMs: number): Promise<Outcome<Value>> {
    return new Promise((resolve) => {
      let timer: NodeJS.Timeout | undefined;
      const check = () => {
        const outcome = this.#closed ? failed("ClientClosed") : found();
        if (outcome === undefined) return;
        clearTimeout(timer);
        this.#waiters.delete(check);
        resolve(outcome);
      };
      timer = setTimeout(() => {
        this.#waiters.delete(check);
        resolve({ ok: false, failure: { kind: "TransportUnavailable" } });
      }, timeoutMs);
      this.#waiters.add(check);
      check();
    });
  }

  /**
   * Prepare one command of the current binding with a new idempotency key of
   * the authority epoch.
   */
  prepare(reference: Reference, body: JsonValue, ifMatch: string | null): Outcome<PendingCommand> {
    const checked = this.#check(reference);
    if (!checked.ok) return checked;
    const key = commandKey(this.#capabilities.epoch);
    if (!key.ok) return key;
    return { ok: true, value: { reference, body, idempotencyKey: key.value, ifMatch } };
  }

  /**
   * Send a prepared command once. The session never sends it again by
   * itself. An explicit second call sends the same bytes under the same key
   * and precondition.
   */
  async send(pending: PendingCommand): Promise<SendOutcome> {
    const checked = this.#check(pending.reference);
    if (!checked.ok) return { kind: "refused", failure: checked.failure };
    const uncertain = (failure: ClientFailure | null): SendOutcome =>
      ({ kind: "uncertain", failure, uncertain: { command: pending, target: pending.reference, precondition: pending.ifMatch, receipt: null } });
    const response = await this.#transport.post(pending.reference.uri, pending.body,
      { idempotencyKey: pending.idempotencyKey, ifMatch: pending.ifMatch });
    if (!response.ok) {
      const failure = response.failure;
      return failure.kind === "Refused" && failure.status === 412 && failure.code === "stale-revision"
        ? { kind: "refused", failure } : uncertain(failure);
    }
    const location = response.value.location;
    if (location === null) return uncertain(null);
    const reference: Reference = { endpoint: pending.reference.endpoint, uri: location };
    if (response.value.status !== 202) return { kind: "delivered", response: response.value, location: reference, receipt: null };
    const receipt = decodeCommandReceipt(response.value.value);
    if (!receipt.ok || location !== `/v1/commands/${receipt.value.id}`) return uncertain(null);
    return { kind: "delivered", response: response.value, location: reference, receipt: receipt.value };
  }

  /**
   * Reconcile an uncertain command with one read: its receipt when the
   * location is known, and otherwise its target, where `effectVisible`
   * tells whether the caller sees the effect of the command. Nothing is
   * sent, and an `uncertain` report keeps the command unchanged.
   */
  async reconcileCommand(uncertain: Uncertain<PendingCommand, Reference>, effectVisible: (value: JsonValue) => boolean)
    : Promise<Reconciled<PendingCommand, Reference>> {
    const read = reconcileRead(uncertain);
    const observed = await this.get(read.location);
    if (!observed.ok) return reconcile(uncertain, { kind: "failure", failure: observed.failure });
    if (read.kind === "receipt") {
      const receipt = decodeCommandReceipt(observed.value.value);
      return reconcile(uncertain, receipt.ok ? { kind: "receipt", state: receipt.value.state } : { kind: "failure", failure: receipt.failure });
    }
    return observed.value.etag === null
      ? reconcile(uncertain, { kind: "failure", failure: { kind: "InvalidResponse" } })
      : reconcile(uncertain, { kind: "target", etag: observed.value.etag, effectVisible: effectVisible(observed.value.value) });
  }

  /**
   * Download an artifact of the current binding and verify its exact bytes
   * against the size and SHA-256 that the manager states for it.
   */
  async download(reference: Reference, size: bigint, sha256: string): Promise<Outcome<Buffer>> {
    const checked = this.#check(reference);
    if (!checked.ok) return checked;
    return this.#transport.downloadVerified(reference.uri, size, sha256);
  }

  /** One JSON polling batch after a cursor, without delivery to the watched resources. */
  pollEvents(cursor: string): ReturnType<ManagerTransport["pollEvents"]> {
    return this.#transport.pollEvents(cursor);
  }

  /**
   * Set the delivery preference. A change from `sse` to `poll` closes the
   * open event stream, and the follow loop continues from its last complete
   * event identifier with polling batches.
   */
  setDelivery(delivery: DeliveryPreference): void {
    const changed = delivery !== this.#delivery;
    this.#delivery = delivery;
    if (changed && delivery === "poll") this.#transport.dropStream();
  }

  /**
   * Close the open event stream as a dropped connection does. The follow
   * loop reconnects with `Last-Event-ID` set to the last complete event
   * identifier that it delivered. This is a test hook.
   */
  forceReconnect(): void {
    this.#transport.dropStream();
  }

  /**
   * Bind the session to the endpoint of another loaded profile. The new
   * binding reads its capabilities, receives a new endpoint identity and
   * advances the refresh generation, so every read in flight is discarded
   * and every reference of the earlier binding gives `WrongEndpoint`. The
   * watched resources, the installed reads and the overview are cleared,
   * the overview is read again, and the follow loop continues from its
   * cursor. A refused connection keeps the earlier binding.
   */
  async switchEndpoint(profile: ClientProfile): Promise<Outcome<Overview>> {
    if (this.#closed) return failed("ClientClosed");
    const bound = await ManagerSession.#bind(profile, this.#options);
    if (!bound.ok) return bound;
    const earlier = this.#transport;
    this.#transport = bound.value.transport;
    this.#endpoint = profile.endpoint.url;
    this.#identity = bound.value.identity;
    this.#capabilities = bound.value.capabilities;
    this.#deliveryState = "connecting";
    this.#refresh = advanceGeneration(this.#refresh);
    this.#watched.clear();
    this.#installed.clear();
    this.#overview = undefined;
    const overview = await this.#bootstrap();
    earlier.close();
    this.#wake();
    return overview;
  }

  /** Close the session: every open request, the event stream and every wait end. */
  async close(): Promise<void> {
    this.#closed = true;
    this.#transport.close();
    this.#wake();
    if (this.#following !== undefined) await this.#following;
  }
}

function memberIdentity(member: OverviewMember): { id: string; revision: string } {
  switch (member.kind) {
    case "request": return member.request;
    case "preparation": return member.preparation;
    case "run": return member.run;
    case "decision": return member.decision;
  }
}

/** Whether a resource is a request, preparation, run or decision, or lies below one. */
function isMemberResource(resource: string): boolean {
  const parts = resource.split("/");
  return parts.length >= 4 && parts[0] === "" && parts[1] === "v1"
    && Object.values(MEMBER_COLLECTIONS).includes(parts[2]) && parts[3] !== "";
}

/** Whether two resources are equal or one lies below the other. The query of a resource is not part of the comparison. */
function related(one: string, other: string): boolean {
  const a = one.split("?")[0];
  const b = other.split("?")[0];
  return a === b || a.startsWith(`${b}/`) || b.startsWith(`${a}/`);
}
