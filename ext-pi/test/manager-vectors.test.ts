import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import {
  closeSse,
  decodeEventBatch,
  decodeEventBlock,
  decodeInvalidation,
  decodeRouteBlock,
  decodeRouteRecord,
  encodeEventBatch,
  encodeInvalidation,
  encodeRouteRecord,
  feedSse,
  newSseParser,
  problemFailure,
  validCursor,
  validETag,
  type ClientFailure,
  type Outcome,
  type SseBlock,
  type SseEvent,
} from "../src/manager/events.ts";
import {
  JsonNumber,
  boundedInteger,
  encodeJson,
  isJsonArray,
  isJsonObject,
  jsonEqual,
  jsonMember,
  parseJson,
  type JsonValue,
} from "../src/manager/json.ts";

/**
 * The events section of `test/manager_client_vectors.json`, run with the pass
 * criteria of `eventVectors` in `manager/test/ClientCheck.hs`. The file is
 * read with the lossless parser, so that numbers such as `410.0` reach the
 * decoders as written.
 */
const VECTORS = parseJson(readFileSync(new URL("../../test/manager_client_vectors.json", import.meta.url), "utf8"));

/** The number of cases of each subsection. A change to the vector file changes these counts. */
const EXPECTED_COUNTS = {
  sse: 27,
  invalidations: 16,
  batches: 13,
  routeRecords: 17,
  cursors: 16,
  etags: 6,
  problems: 10,
} as const;

function member(value: JsonValue | undefined, name: string): JsonValue | undefined {
  return value !== undefined && isJsonObject(value) ? jsonMember(value, name) : undefined;
}

function list(value: JsonValue | undefined): readonly JsonValue[] {
  return value !== undefined && isJsonArray(value) ? value : [];
}

function textOf(value: JsonValue | undefined): string | undefined {
  return typeof value === "string" ? value : undefined;
}

function integerOf(value: JsonValue | undefined): number {
  if (!(value instanceof JsonNumber)) throw new Error(`expected a number, found ${value === undefined ? "nothing" : encodeJson(value)}`);
  const integer = boundedInteger(value, BigInt(Number.MIN_SAFE_INTEGER), BigInt(Number.MAX_SAFE_INTEGER));
  if (integer === undefined) throw new Error(`expected a safe integer, found ${value.source}`);
  return Number(integer);
}

function label(kind: string, vector: JsonValue): string {
  return `${kind} ${textOf(member(vector, "name")) ?? "unnamed"}`;
}

/** The cases of one subsection, refused when the subsection is empty. */
function cases(name: keyof typeof EXPECTED_COUNTS): readonly JsonValue[] {
  const items = list(member(member(VECTORS, "events"), name));
  if (items.length === 0) throw new Error(`vector section ${name} is empty`);
  return items;
}

/** The bytes of a stream description: text, hexadecimal and repeated segments. */
function streamBytes(vector: JsonValue): Uint8Array {
  const encoder = new TextEncoder();
  const parts = list(member(vector, "stream")).map((segment) => {
    const chars = textOf(member(segment, "text"));
    if (chars !== undefined) return encoder.encode(chars);
    const digits = textOf(member(segment, "hex"));
    if (digits !== undefined && /^(?:[0-9a-fA-F]{2})*$/.test(digits)) return Uint8Array.from(Buffer.from(digits, "hex"));
    const repeated = textOf(member(segment, "repeat"));
    if (repeated !== undefined) return encoder.encode(repeated.repeat(integerOf(member(segment, "count"))));
    throw new Error(`${label("sse", vector)} has a malformed segment`);
  });
  return Uint8Array.from(Buffer.concat(parts));
}

function expectedBlock(value: JsonValue): SseBlock {
  if (value === "heartbeat") return { kind: "heartbeat" };
  const advance = textOf(member(value, "advance"));
  if (advance !== undefined) return { kind: "advance", id: advance };
  const event = member(value, "event");
  const name = textOf(member(event, "name"));
  const data = member(event, "data");
  const payload = typeof data === "string" ? data
    : textOf(member(data, "repeat"))?.repeat(integerOf(member(data, "count")));
  if (name === undefined || payload === undefined) throw new Error("malformed expected SSE block");
  return { kind: "dispatch", event: { id: textOf(member(event, "id")) ?? null, name, data: payload } };
}

type Fed = { blocks: SseBlock[]; result: Outcome<string | null> };

/** Feed the chunks in order: the dispatched blocks, and the refusal or the last complete event identifier at close. */
function feedAll(initial: string | null, chunks: readonly Uint8Array[]): Fed {
  let parser = newSseParser(initial);
  const blocks: SseBlock[] = [];
  for (const chunk of chunks) {
    const fed = feedSse(parser, chunk);
    if (!fed.ok) return { blocks, result: fed };
    parser = fed.value.parser;
    blocks.push(...fed.value.blocks);
  }
  return { blocks, result: { ok: true, value: closeSse(parser) } };
}

function chunksAt(points: readonly number[], bytes: Uint8Array): Uint8Array[] {
  const bounds = [0, ...points, bytes.length];
  return bounds.slice(1).map((end, index) => bytes.slice(bounds[index], end));
}

function isInvalidResponse(failure: ClientFailure): boolean {
  return failure.kind === "InvalidResponse";
}

function sameBlocks(actual: readonly SseBlock[], expected: readonly SseBlock[]): boolean {
  return actual.length <= expected.length && actual.every((block, index) => JSON.stringify(block) === JSON.stringify(expected[index]));
}

/** One SSE vector: the number of splits it ran, and every split whose outcome disagrees. */
function runSse(vector: JsonValue): { splits: number; wrong: string[] } {
  const bytes = streamBytes(vector);
  const expected = list(member(vector, "expected")).map(expectedBlock);
  const size = bytes.length;
  const listed = list(member(vector, "splits")).map((split) => list(split).map(integerOf));
  for (const points of listed) {
    const bounds = [0, ...points, size];
    if (!bounds.slice(1).every((point, index) => bounds[index] < point)) {
      throw new Error(`${label("sse", vector)} lists an invalid split ${JSON.stringify(points)}`);
    }
  }
  if (listed.length === 0) throw new Error(`${label("sse", vector)} lists no split point`);
  const interior = Array.from({ length: Math.max(size - 1, 0) }, (_, index) => index + 1);
  const exhaustive = size <= 2048 ? interior.map((point) => [point]) : [];
  const splits = [[], ...listed, ...exhaustive, interior];
  const refusing = member(vector, "refuse") === true;
  const lastId = textOf(member(vector, "lastId")) ?? null;
  const initial = textOf(member(vector, "initialId")) ?? null;
  const wrong: string[] = [];
  for (const points of splits) {
    const { blocks, result } = feedAll(initial, chunksAt(points, bytes));
    const agrees = refusing
      ? !result.ok && isInvalidResponse(result.failure) && sameBlocks(blocks, expected)
      : result.ok && result.value === lastId && blocks.length === expected.length && sameBlocks(blocks, expected);
    if (!agrees) wrong.push(`split ${JSON.stringify(points)}: ${JSON.stringify({ blocks, result })}`);
    if (wrong.length > 0) break;
  }
  return { splits: splits.length, wrong };
}

/** Whether the dispatched events of a vector decode as it states. */
function decodesAsStated(vector: JsonValue, decode: (event: SseEvent) => Outcome<unknown>): boolean {
  const events = list(member(vector, "expected")).map(expectedBlock)
    .flatMap((block) => (block.kind === "dispatch" ? [block.event] : []));
  const results = events.map(decode);
  return member(vector, "decodeValid") === true
    ? results.every((result) => result.ok)
    : results.some((result) => !result.ok && isInvalidResponse(result.failure));
}

/** One JSON vector: a valid case decodes and encodes back to the same value, an invalid case refuses with `InvalidResponse`. */
function jsonVectorPasses<Decoded>(
  vector: JsonValue,
  decode: (value: JsonValue) => Outcome<Decoded>,
  encode: (decoded: Decoded) => JsonValue,
): boolean {
  const source = textOf(member(vector, "json"));
  if (source === undefined) throw new Error(`${label("vector", vector)} has no json`);
  const value = parseJson(source);
  const decoded = decode(value);
  const valid = member(vector, "valid") === true;
  return decoded.ok ? valid && jsonEqual(encode(decoded.value), value) : isInvalidResponse(decoded.failure) && !valid;
}

describe("manager client vectors: events", () => {
  it("has the stated number of cases in every subsection", () => {
    const counts = Object.fromEntries(Object.keys(EXPECTED_COUNTS).map((name) =>
      [name, cases(name as keyof typeof EXPECTED_COUNTS).length]));
    expect(counts).toEqual(EXPECTED_COUNTS);
  });

  it("parses every SSE stream whole, at each listed split, at every single split and byte by byte", () => {
    let ran = 0;
    let splits = 0;
    let decodeChecks = 0;
    for (const vector of cases("sse")) {
      const outcome = runSse(vector);
      expect(outcome.wrong, label("sse", vector)).toEqual([]);
      splits += outcome.splits;
      const decode = textOf(member(vector, "decode"));
      if (decode === "invalidation") {
        expect(decodesAsStated(vector, decodeEventBlock), label("sse decode", vector)).toBe(true);
        decodeChecks += 1;
      } else if (decode === "route") {
        expect(decodesAsStated(vector, decodeRouteBlock), label("sse decode", vector)).toBe(true);
        decodeChecks += 1;
      } else if (decode !== undefined) {
        throw new Error(`unknown decode ${decode}`);
      }
      ran += 1;
    }
    expect(ran).toBe(EXPECTED_COUNTS.sse);
    expect(decodeChecks).toBe(12);
    expect(splits).toBe(2751);
  });

  it("decodes and re-encodes invalidations", () => {
    const ran = cases("invalidations").filter((vector) => {
      expect(jsonVectorPasses(vector, decodeInvalidation, encodeInvalidation), label("invalidation", vector)).toBe(true);
      return true;
    }).length;
    expect(ran).toBe(EXPECTED_COUNTS.invalidations);
  });

  it("decodes and re-encodes event batches", () => {
    const ran = cases("batches").filter((vector) => {
      expect(jsonVectorPasses(vector, decodeEventBatch, encodeEventBatch), label("batch", vector)).toBe(true);
      return true;
    }).length;
    expect(ran).toBe(EXPECTED_COUNTS.batches);
  });

  it("decodes and re-encodes route records", () => {
    const ran = cases("routeRecords").filter((vector) => {
      expect(jsonVectorPasses(vector, decodeRouteRecord, encodeRouteRecord), label("route record", vector)).toBe(true);
      return true;
    }).length;
    expect(ran).toBe(EXPECTED_COUNTS.routeRecords);
  });

  it("checks cursor syntax", () => {
    const ran = cases("cursors").filter((vector) => {
      const cursor = textOf(member(vector, "cursor"));
      if (cursor === undefined) throw new Error("cursor vector without cursor");
      expect(validCursor(cursor), `cursor ${cursor}`).toBe(member(vector, "valid") === true);
      return true;
    }).length;
    expect(ran).toBe(EXPECTED_COUNTS.cursors);
  });

  it("checks entity-tag syntax and equality", () => {
    const ran = cases("etags").filter((vector) => {
      const a = textOf(member(vector, "a"));
      const b = textOf(member(vector, "b"));
      const [validA, validB] = list(member(vector, "valid"));
      if (a === undefined || b === undefined || typeof validA !== "boolean" || typeof validB !== "boolean") {
        throw new Error("malformed etag vector");
      }
      expect([validETag(a), validETag(b), a === b], `etag ${a} ${b}`).toEqual([validA, validB, member(vector, "equal") === true]);
      return true;
    }).length;
    expect(ran).toBe(EXPECTED_COUNTS.etags);
  });

  it("maps problem bodies to client failures", () => {
    const ran = cases("problems").filter((vector) => {
      const status = integerOf(member(vector, "status"));
      const stated = member(vector, "expected");
      const refused = list(member(stated, "refused"));
      const expected: ClientFailure = stated === "InvalidResponse"
        ? { kind: "InvalidResponse" }
        : refused.length === 2 && typeof refused[1] === "string"
          ? { kind: "Refused", status: integerOf(refused[0]), code: refused[1] }
          : (() => { throw new Error(`${label("problem", vector)} has no expected failure`); })();
      const body = member(vector, "body");
      if (body === undefined) throw new Error(`${label("problem", vector)} has no body`);
      expect(problemFailure(status, body), label("problem", vector)).toEqual(expected);
      return true;
    }).length;
    expect(ran).toBe(EXPECTED_COUNTS.problems);
  });
});

describe("lossless JSON", () => {
  it("keeps false, null, large numerics and Unicode of a route-record body through decode and re-encode", () => {
    const vector = cases("routeRecords")[0];
    const source = textOf(member(vector, "json"));
    if (source === undefined) throw new Error("route record vector without json");
    const value = parseJson(source);
    const decoded = decodeRouteRecord(value);
    if (!decoded.ok) throw new Error("the route record does not decode");
    expect(encodeJson(encodeRouteRecord(decoded.value))).toBe(encodeJson(value));
    const body = decoded.value.payload.kind === "body" ? decoded.value.payload.value : null;
    expect(member(body ?? null, "text")).toBe("héllo ✓ \u{1d11e}");
    expect(member(body ?? null, "flag")).toBe(false);
    expect(member(body ?? null, "none")).toBe(null);
    expect(member(body ?? null, "big")).toEqual(new JsonNumber("123456789012345678901234567890"));
    expect(member(body ?? null, "huge")).toEqual(new JsonNumber("1e400"));
    expect(encodeJson(member(body ?? null, "nested") ?? null)).toBe("{\"list\":[false,null,0]}");
  });

  it("keeps integers above 2^53 exact and compares numbers by decimal value", () => {
    const value = parseJson("[9007199254740993,18446744073709551615,1.0,10e-1,-0,1e400]");
    expect(encodeJson(value)).toBe("[9007199254740993,18446744073709551615,1.0,10e-1,-0,1e400]");
    expect(jsonEqual(parseJson("[1,0,1e400]"), parseJson("[1.0,-0,10e399]"))).toBe(true);
    expect(jsonEqual(parseJson("9007199254740993"), parseJson("9007199254740992"))).toBe(false);
    expect(jsonEqual(parseJson("{\"a\":1,\"b\":[true]}"), parseJson("{\"b\":[true],\"a\":1.0}"))).toBe(true);
    expect(jsonEqual(parseJson("{\"a\":1}"), parseJson("{\"a\":1,\"b\":null}"))).toBe(false);
    expect(jsonEqual(parseJson("false"), parseJson("null"))).toBe(false);
  });

  it("refuses text that is not JSON", () => {
    expect(() => parseJson("{\"a\":1,}")).toThrow(SyntaxError);
    expect(() => parseJson("1 2")).toThrow(SyntaxError);
  });
});
