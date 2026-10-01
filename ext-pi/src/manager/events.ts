/**
 * Pure live-delivery decoding of the manager client: an incremental
 * server-sent-event block parser, the invalidation and batch records of
 * `/v1/events`, the record of a route stream, and the mapping of a problem
 * response to a client failure. Nothing here performs I/O or holds a session.
 *
 * This module states the behavior of `Agentic.Manager.Client.Events` and
 * `Agentic.Manager.Client.Failure` in TypeScript. It imports no Haskell code.
 * The `events` section of `test/manager_client_vectors.json` is the shared
 * definition that both implementations pass.
 *
 * @packageDocumentation
 */

import {
  JsonNumber,
  WORD64_MAX,
  isJsonObject,
  jsonMember,
  numberEqual,
  tryParseJson,
  word64,
  type JsonObject,
  type JsonValue,
} from "./json.ts";

/**
 * The fixed local failures of the client that carry no detail.
 *
 * @public
 */
export type FixedClientFailure =
  | "ClientClosed"
  | "InvalidEndpoint"
  | "WrongEndpoint"
  | "CredentialUnavailable"
  | "CredentialChanged"
  | "TransportUnavailable"
  | "RedirectRefused"
  | "InvalidResponse"
  | "ResponseTooLarge"
  | "UnsupportedVersion"
  | "ClientFileUnavailable"
  | "InvalidClientProfile";

/**
 * A fixed local failure of the client, or the refusal of a problem response
 * with its HTTP status and problem code.
 *
 * @public
 */
export type ClientFailure =
  | { readonly kind: FixedClientFailure }
  | { readonly kind: "Refused"; readonly status: number; readonly code: string };

/**
 * A decoded value, or the failure that refused it.
 *
 * @typeParam Value - the type of the decoded value.
 * @public
 */
export type Outcome<Value> = { readonly ok: true; readonly value: Value } | { readonly ok: false; readonly failure: ClientFailure };

const INVALID_RESPONSE: Outcome<never> = { ok: false, failure: { kind: "InvalidResponse" } };

function decided<Value>(value: Value | undefined): Outcome<Value> {
  return value === undefined ? INVALID_RESPONSE : { ok: true, value };
}

/**
 * The largest complete block, terminating blank line included, that the
 * manager writes and the parser accepts.
 *
 * @public
 */
export const SSE_BLOCK_BYTES = 16384;

/** A list built by prepending, newest first. */
type Chain<Item> = { readonly head: Item; readonly tail: Chain<Item> } | null;

function oldestFirst<Item>(chain: Chain<Item>): Item[] {
  const items: Item[] = [];
  for (let cell = chain; cell !== null; cell = cell.tail) items.push(cell.head);
  return items.reverse();
}

/**
 * The state of one connection: the pieces of its incomplete line, the
 * complete lines of its incomplete block, the bytes of that block so far, and
 * the last complete event identifier.
 *
 * @public
 */
export type SseParser = {
  readonly pieces: Chain<Uint8Array>;
  readonly lines: Chain<Uint8Array>;
  readonly bytes: number;
  readonly lastId: string | null;
};

/**
 * One dispatched block. `id` is the `id` line of this block, when it has one.
 * `name` is its last `event` line, or `message` without one. `data` joins its
 * `data` lines with LF.
 *
 * @public
 */
export type SseEvent = { readonly id: string | null; readonly name: string; readonly data: string };

/**
 * The outcome of one complete block. A block with `data` dispatches an event.
 * A block with an `id` and no `data` advances the last event identifier and
 * dispatches nothing. A block of comment lines only is a heartbeat. A block of
 * other fields only gives no outcome.
 *
 * @public
 */
export type SseBlock =
  | { readonly kind: "dispatch"; readonly event: SseEvent }
  | { readonly kind: "advance"; readonly id: string }
  | { readonly kind: "heartbeat" };

/**
 * A parser for a new connection. A reconnection supplies the identifier that
 * it sent in `Last-Event-ID`, which stays the last complete event identifier
 * until a later block carries an `id`.
 *
 * @public
 */
export function newSseParser(lastEventId: string | null = null): SseParser {
  return { pieces: null, lines: null, bytes: 0, lastId: lastEventId };
}

function joinBytes(parts: readonly Uint8Array[]): Uint8Array {
  const joined = new Uint8Array(parts.reduce((total, part) => total + part.length, 0));
  let offset = 0;
  for (const part of parts) {
    joined.set(part, offset);
    offset += part.length;
  }
  return joined;
}

/**
 * Accept the next bytes of the response, split at any point, and give the
 * outcomes of the blocks that they complete, in order. A line ends at LF or
 * CRLF, and a blank line ends a block. A carriage return elsewhere, a block
 * that is not UTF-8, an `id` that is not a cursor, and a block above
 * `SSE_BLOCK_BYTES` refuse with `InvalidResponse`, and the connection is then
 * unusable. An incomplete block is refused as soon as it passes the bound.
 * The parser that this call receives is not changed.
 *
 * @public
 */
export function feedSse(start: SseParser, chunk: Uint8Array): Outcome<{ parser: SseParser; blocks: SseBlock[] }> {
  let { pieces, lines, bytes, lastId } = start;
  const blocks: SseBlock[] = [];
  let offset = 0;
  for (;;) {
    const index = chunk.indexOf(10, offset);
    if (index < 0) {
      const total = bytes + chunk.length - offset;
      if (total > SSE_BLOCK_BYTES) return INVALID_RESPONSE;
      if (offset < chunk.length) pieces = { head: chunk.slice(offset), tail: pieces };
      return { ok: true, value: { parser: { pieces, lines, bytes: total, lastId }, blocks } };
    }
    const total = bytes + index - offset + 1;
    if (total > SSE_BLOCK_BYTES) return INVALID_RESPONSE;
    let line = joinBytes(oldestFirst({ head: chunk.slice(offset, index), tail: pieces }));
    offset = index + 1;
    if (line.length > 0 && line[line.length - 1] === 13) line = line.subarray(0, line.length - 1);
    if (line.includes(13)) return INVALID_RESPONSE;
    pieces = null;
    if (line.length === 0) {
      const ended = blockOf(oldestFirst(lines));
      if (ended === undefined) return INVALID_RESPONSE;
      if (ended.id !== null) lastId = ended.id;
      if (ended.block !== null) blocks.push(ended.block);
      lines = null;
      bytes = 0;
    } else {
      lines = { head: line, tail: lines };
      bytes = total;
    }
  }
}

/**
 * The last complete event identifier at the end of a connection. The bytes of
 * an incomplete final block are discarded and dispatch nothing.
 *
 * @public
 */
export function closeSse(parser: SseParser): string | null {
  return parser.lastId;
}

/** The outcome and the identifier of one complete block, or `undefined` when it refuses. */
function blockOf(rawLines: readonly Uint8Array[]): { id: string | null; block: SseBlock | null } | undefined {
  const decoder = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true });
  const texts: string[] = [];
  for (const raw of rawLines) {
    try {
      texts.push(decoder.decode(raw));
    } catch (error) {
      if (error instanceof TypeError) return undefined;
      throw error;
    }
  }
  const fields = texts.filter((line) => !line.startsWith(":")).map((line): [string, string] => {
    const colon = line.indexOf(":");
    if (colon < 0) return [line, ""];
    const value = line.slice(colon + 1);
    return [line.slice(0, colon), value.startsWith(" ") ? value.slice(1) : value];
  });
  const values = (name: string) => fields.filter(([field]) => field === name).map(([, value]) => value);
  const ids = values("id");
  const names = values("event");
  const payload = values("data");
  if (!ids.every(validCursor)) return undefined;
  const id = ids.length === 0 ? null : ids[ids.length - 1];
  let block: SseBlock | null = null;
  if (payload.length > 0) {
    block = { kind: "dispatch", event: { id, name: names.length === 0 ? "message" : names[names.length - 1], data: payload.join("\n") } };
  } else if (id !== null) {
    block = { kind: "advance", id };
  } else if (fields.length === 0 && texts.length > 0) {
    block = { kind: "heartbeat" };
  }
  return { id, block };
}

/**
 * A bounded identifier: 1 to 128 ASCII letters, digits, `_` and `-`.
 *
 * @public
 */
export function validId(value: string): boolean {
  return /^[A-Za-z0-9_-]{1,128}$/.test(value);
}

/** A revision, which has the syntax of an identifier. */
export const validRevision = validId;

/** A resource path below `/v1/` of at most 8192 characters. */
export function validResource(value: string): boolean {
  return value.length > 4 && value.length <= 8192 && value.startsWith("/v1/") && /^[A-Za-z0-9_\-/?=&.%]*$/.test(value);
}

/**
 * A canonical event cursor: an identifier, a dot and a canonical unsigned
 * 64-bit decimal. Event, route and manager-route cursors share this syntax.
 *
 * @public
 */
export function validCursor(value: string): boolean {
  const parts = value.split(".");
  if (parts.length !== 2) return false;
  const [stream, number] = parts;
  return validId(stream) && /^(?:0|[1-9][0-9]{0,19})$/.test(number) && BigInt(number) <= WORD64_MAX;
}

/**
 * A strong entity tag: a quoted identifier. Two tags match only when they are
 * equal as text, and a tag carries no order.
 *
 * @public
 */
export function validETag(value: string): boolean {
  return value.length >= 3 && value.length <= 130 && value.startsWith("\"") && value.endsWith("\"")
    && validId(value.slice(1, -1));
}

/**
 * The seven event names of the `/v1/events` stream.
 *
 * @public
 */
export const EVENT_NAMES = [
  "request.changed",
  "preparation.changed",
  "run.changed",
  "decision.changed",
  "command.changed",
  "artifact.changed",
  "service.changed",
] as const;

/** One of the seven event names. */
export type EventName = (typeof EVENT_NAMES)[number];

/** The event name of a text, or `undefined` for any other text. */
export function parseEventName(text: string): EventName | undefined {
  return EVENT_NAMES.find((name) => name === text);
}

/**
 * A versioned resource invalidation. The revision is an equality token.
 *
 * @public
 */
export type Invalidation = { readonly resource: string; readonly revision: string };

/**
 * One event of a JSON batch or of the `/v1/events` stream.
 *
 * @public
 */
export type InvalidationEvent = { readonly id: string; readonly name: EventName; readonly data: Invalidation };

/**
 * One JSON polling batch. `oldestCursor` is used as supplied.
 *
 * @public
 */
export type EventBatch = {
  readonly cursor: string;
  readonly oldestCursor: string;
  readonly events: readonly InvalidationEvent[];
  readonly hasMore: boolean;
};

/**
 * An inline body, a claim check with its digest and size, or the sequence
 * number of an event record.
 *
 * @public
 */
export type RoutePayload =
  | { readonly kind: "body"; readonly value: JsonValue }
  | { readonly kind: "claim"; readonly sha256: string; readonly bytes: bigint }
  | { readonly kind: "event"; readonly sequence: bigint };

/**
 * One record of a run route or manager route: the fields of the local flow
 * reader with `id` and `class`. The record at position p has the identifier
 * of position p+1.
 *
 * @public
 */
export type RouteRecord = {
  readonly id: string;
  readonly class: "public" | "actor";
  readonly position: bigint;
  readonly schema: RouteSchema;
  readonly from: JsonValue;
  readonly to: JsonValue;
  readonly about: JsonValue;
  readonly replyTo: bigint | null;
  readonly at: string;
  readonly payload: RoutePayload;
};

/** The schemas of route records. */
export const ROUTE_SCHEMAS = [
  "start", "control", "question", "answer", "engine-start", "turn", "steer", "done", "event",
  "permission", "command", "receipt", "review", "relay", "notice",
] as const;

/** One schema of a route record. */
export type RouteSchema = (typeof ROUTE_SCHEMAS)[number];

/** The object of a value when its own members are exactly the given names. */
function closed(value: JsonValue | undefined, names: readonly string[]): JsonObject | undefined {
  if (value === undefined || !isJsonObject(value)) return undefined;
  const present = Object.keys(value);
  return present.length === names.length && names.every((name) => Object.hasOwn(value, name)) ? value : undefined;
}

function text(value: JsonValue | undefined): string | undefined {
  return typeof value === "string" ? value : undefined;
}

function versionOne(fields: JsonObject): boolean {
  const version = jsonMember(fields, "version");
  return version instanceof JsonNumber && numberEqual(version, ONE);
}

const ONE = new JsonNumber("1");

function cursorField(fields: JsonObject, name: string): string | undefined {
  const value = text(jsonMember(fields, name));
  return value !== undefined && validCursor(value) ? value : undefined;
}

function parseInvalidation(value: JsonValue | undefined): Invalidation | undefined {
  const fields = closed(value, ["version", "resource", "revision"]);
  if (fields === undefined || !versionOne(fields)) return undefined;
  const resource = text(jsonMember(fields, "resource"));
  const revision = text(jsonMember(fields, "revision"));
  if (resource === undefined || revision === undefined || !validResource(resource) || !validRevision(revision)) return undefined;
  return { resource, revision };
}

function parseInvalidationEvent(value: JsonValue | undefined): InvalidationEvent | undefined {
  const fields = closed(value, ["id", "event", "data"]);
  if (fields === undefined) return undefined;
  const id = cursorField(fields, "id");
  const nameText = text(jsonMember(fields, "event"));
  const name = nameText === undefined ? undefined : parseEventName(nameText);
  const data = parseInvalidation(jsonMember(fields, "data"));
  return id === undefined || name === undefined || data === undefined ? undefined : { id, name, data };
}

function parseEventBatch(value: JsonValue): EventBatch | undefined {
  const fields = closed(value, ["version", "cursor", "oldestCursor", "events", "hasMore"]);
  if (fields === undefined || !versionOne(fields)) return undefined;
  const cursor = cursorField(fields, "cursor");
  const oldestCursor = cursorField(fields, "oldestCursor");
  const listed = jsonMember(fields, "events");
  const hasMore = jsonMember(fields, "hasMore");
  if (cursor === undefined || oldestCursor === undefined || !Array.isArray(listed) || listed.length > 256
    || typeof hasMore !== "boolean") return undefined;
  const events: InvalidationEvent[] = [];
  for (const item of listed as readonly JsonValue[]) {
    const event = parseInvalidationEvent(item);
    if (event === undefined) return undefined;
    events.push(event);
  }
  return { cursor, oldestCursor, events, hasMore };
}

const ROUTE_HEADER = ["id", "class", "position", "schema", "from", "to", "about", "replyTo", "at"] as const;

function parseRoutePayload(name: "body" | "claim" | "event", value: JsonValue): RoutePayload | undefined {
  if (name === "body") return { kind: "body", value };
  if (name === "claim") {
    const claim = closed(value, ["sha256", "bytes"]);
    if (claim === undefined) return undefined;
    const sha256 = text(jsonMember(claim, "sha256"));
    const bytes = word64(jsonMember(claim, "bytes"));
    return sha256 === undefined || !/^[0-9a-f]{64}$/.test(sha256) || bytes === undefined
      ? undefined : { kind: "claim", sha256, bytes };
  }
  const event = closed(value, ["sequence"]);
  const sequence = event === undefined ? undefined : word64(jsonMember(event, "sequence"));
  return sequence === undefined ? undefined : { kind: "event", sequence };
}

function parseRouteRecord(value: JsonValue): RouteRecord | undefined {
  if (!isJsonObject(value)) return undefined;
  const bodies = (["body", "claim", "event"] as const).filter((name) => Object.hasOwn(value, name));
  if (bodies.length !== 1) return undefined;
  const bodyName = bodies[0];
  const fields = closed(value, [bodyName, ...ROUTE_HEADER]);
  if (fields === undefined) return undefined;
  const id = cursorField(fields, "id");
  const kind = text(jsonMember(fields, "class"));
  const position = word64(jsonMember(fields, "position"));
  const schema = text(jsonMember(fields, "schema"));
  const from = fields.from;
  const to = fields.to;
  const about = fields.about;
  const reply = fields.replyTo;
  const replyTo = reply === null ? null : word64(reply);
  const at = text(jsonMember(fields, "at"));
  if (id === undefined || kind === undefined || position === undefined || schema === undefined
    || replyTo === undefined || at === undefined) return undefined;
  if (kind !== "public" && kind !== "actor") return undefined;
  const routeSchema = ROUTE_SCHEMAS.find((known) => known === schema);
  if (routeSchema === undefined) return undefined;
  if (position >= WORD64_MAX || id.slice(id.lastIndexOf(".") + 1) !== (position + 1n).toString()) return undefined;
  if (from !== "manager" && !isJsonObject(from)) return undefined;
  if (to !== "public" && !isJsonObject(to)) return undefined;
  if (!isJsonObject(about)) return undefined;
  const payload = parseRoutePayload(bodyName, fields[bodyName]);
  if (payload === undefined) return undefined;
  return { id, class: kind, position, schema: routeSchema, from, to, about, replyTo, at, payload };
}

/**
 * Decode an invalidation, or refuse with `InvalidResponse`.
 *
 * @public
 */
export function decodeInvalidation(value: JsonValue): Outcome<Invalidation> {
  return decided(parseInvalidation(value));
}

/** The JSON value of an invalidation. */
export function encodeInvalidation(invalidation: Invalidation): JsonValue {
  return { version: ONE, resource: invalidation.resource, revision: invalidation.revision };
}

/**
 * Decode one event of a batch, or refuse with `InvalidResponse`.
 *
 * @public
 */
export function decodeInvalidationEvent(value: JsonValue): Outcome<InvalidationEvent> {
  return decided(parseInvalidationEvent(value));
}

/** The JSON value of one event of a batch. */
export function encodeInvalidationEvent(event: InvalidationEvent): JsonValue {
  return { id: event.id, event: event.name, data: encodeInvalidation(event.data) };
}

/**
 * Decode a JSON polling batch of at most 256 events, or refuse with
 * `InvalidResponse`.
 *
 * @public
 */
export function decodeEventBatch(value: JsonValue): Outcome<EventBatch> {
  return decided(parseEventBatch(value));
}

/** The JSON value of a polling batch. */
export function encodeEventBatch(batch: EventBatch): JsonValue {
  return {
    version: ONE,
    cursor: batch.cursor,
    oldestCursor: batch.oldestCursor,
    events: batch.events.map(encodeInvalidationEvent),
    hasMore: batch.hasMore,
  };
}

/**
 * Decode a route record, or refuse with `InvalidResponse`. An inline body is
 * kept as its lossless JSON value.
 *
 * @public
 */
export function decodeRouteRecord(value: JsonValue): Outcome<RouteRecord> {
  return decided(parseRouteRecord(value));
}

/** The JSON value of a route record. */
export function encodeRouteRecord(record: RouteRecord): JsonValue {
  const header: Record<string, JsonValue> = {
    id: record.id,
    class: record.class,
    position: JsonNumber.ofBigInt(record.position),
    schema: record.schema,
    from: record.from,
    to: record.to,
    about: record.about,
    replyTo: record.replyTo === null ? null : JsonNumber.ofBigInt(record.replyTo),
    at: record.at,
  };
  const payload = record.payload;
  if (payload.kind === "body") header.body = payload.value;
  else if (payload.kind === "claim") header.claim = { sha256: payload.sha256, bytes: JsonNumber.ofBigInt(payload.bytes) };
  else header.event = { sequence: JsonNumber.ofBigInt(payload.sequence) };
  return header;
}

/** The data of a block as one JSON value, or `undefined` when it is not JSON. */
function blockData(event: SseEvent): JsonValue | undefined {
  return tryParseJson(event.data);
}

/**
 * The invalidation of one dispatched block of `/v1/events`. The block carries
 * its own `id`, one of the seven event names, and an invalidation as data.
 *
 * @public
 */
export function decodeEventBlock(event: SseEvent): Outcome<InvalidationEvent> {
  const name = parseEventName(event.name);
  const data = blockData(event);
  const invalidation = data === undefined ? undefined : parseInvalidation(data);
  return event.id === null || name === undefined || invalidation === undefined
    ? INVALID_RESPONSE : { ok: true, value: { id: event.id, name, data: invalidation } };
}

/**
 * The record of one dispatched block of a route stream. The block carries the
 * identifier of the record and the event name `route.` and its schema.
 *
 * @public
 */
export function decodeRouteBlock(event: SseEvent): Outcome<RouteRecord> {
  const data = blockData(event);
  const record = data === undefined ? undefined : parseRouteRecord(data);
  return event.id === null || record === undefined || record.id !== event.id || event.name !== `route.${record.schema}`
    ? INVALID_RESPONSE : { ok: true, value: record };
}

/**
 * The failure of a problem response with the given HTTP status. A body whose
 * `status` equals that status and whose `code` is a bounded identifier gives
 * `Refused` with that status and code, so a 410 `view-expired` or
 * `cursor-expired` problem gives `Refused` 410 with its code. Every other body
 * gives `InvalidResponse`.
 *
 * @public
 */
export function problemFailure(status: number, body: JsonValue): ClientFailure {
  if (!Number.isSafeInteger(status) || !isJsonObject(body)) return { kind: "InvalidResponse" };
  const stated = jsonMember(body, "status");
  const code = jsonMember(body, "code");
  return stated instanceof JsonNumber && numberEqual(stated, JsonNumber.ofBigInt(BigInt(status)))
    && typeof code === "string" && validId(code)
    ? { kind: "Refused", status, code }
    : { kind: "InvalidResponse" };
}
