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
import {
  INITIAL_BACKOFF,
  RECONNECT_BACKOFF_MAX_SECONDS,
  advanceGeneration,
  completeFetch,
  invalidateResource,
  jitteredMicroseconds,
  newRefresh,
  parseCommandState,
  reconcile,
  reconcileRead,
  reconnectDelay,
  type Backoff,
  type ReconcileObservation,
  type Refresh,
  type RefreshAction,
  type RefreshStep,
  type Uncertain,
} from "../src/manager/refresh.ts";

/**
 * The events and refresh sections of `test/manager_client_vectors.json`, run
 * with the pass criteria of `eventVectors` and `refreshVectors` in
 * `manager/test/ClientCheck.hs`. The file is read with the lossless parser,
 * so that numbers such as `410.0` reach the decoders as written.
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

/** The number of cases of each subsection of the refresh section. */
const REFRESH_COUNTS = {
  sequences: 13,
  backoff: 4,
  jitter: 5,
  reconciliation: 17,
} as const;

/** The cases of one refresh subsection, refused when the subsection is empty. */
function refreshCases(name: keyof typeof REFRESH_COUNTS): readonly JsonValue[] {
  const items = list(member(member(VECTORS, "refresh"), name));
  if (items.length === 0) throw new Error(`vector section refresh.${name} is empty`);
  return items;
}

/** One action of a sequence step: kind, resource key and generation. */
function expectedAction(stepLabel: string, value: JsonValue): RefreshAction<string> {
  const [kind, key, generation] = list(value);
  if (list(value).length !== 3 || typeof key !== "string" || generation === undefined) {
    throw new Error(`${stepLabel} has a malformed action`);
  }
  if (kind !== "fetch" && kind !== "install" && kind !== "discard") throw new Error(`${stepLabel} names an unknown action`);
  return { kind, key, generation: integerOf(generation) };
}

/**
 * Run a coordinator sequence. Each step states its exact actions. Every step
 * also keeps the coordinator rules: an install has the current generation, a
 * completion of another generation never installs, an invalidation of a
 * resource in flight starts nothing, a completion starts at most one fetch,
 * and an advance leaves every resource idle. The result is the number of
 * steps that ran.
 */
function runSequence(vector: JsonValue): number {
  const name = label("refresh sequence", vector);
  let state: Refresh<string> = newRefresh();
  const steps = list(member(vector, "steps"));
  steps.forEach((step, index) => {
    const stepLabel = `${name} step ${index + 1}`;
    const current = state.generation;
    const expected = list(member(step, "actions")).map((action) => expectedAction(stepLabel, action));
    const invalidated = textOf(member(step, "invalidate"));
    const completed = textOf(member(step, "complete"));
    let next: RefreshStep<string>;
    let rule: boolean;
    if (invalidated !== undefined && completed === undefined) {
      const inFlight = state.flights.has(invalidated);
      next = invalidateResource(invalidated, state);
      rule = inFlight
        ? next.actions.length === 0
        : JSON.stringify(next.actions) === JSON.stringify([{ kind: "fetch", key: invalidated, generation: current }]);
    } else if (completed !== undefined && invalidated === undefined) {
      const generation = integerOf(member(step, "generation"));
      next = completeFetch(completed, generation, state);
      const installs = next.actions.filter((action) => action.kind === "install");
      const fetches = next.actions.filter((action) => action.kind === "fetch");
      rule = installs.every((action) => action.generation === current)
        && (generation === current || installs.length === 0) && fetches.length <= 1;
    } else if (invalidated === undefined && completed === undefined
      && (member(step, "resnapshot") === true || member(step, "endpointSwitch") === true)) {
      next = { state: advanceGeneration(state), actions: [] };
      rule = next.state.flights.size === 0 && integerOf(member(step, "generation")) === current + 1
        && next.state.generation === current + 1;
    } else {
      throw new Error(`${stepLabel} names no single step kind`);
    }
    expect(next.actions, stepLabel).toEqual(expected);
    expect(rule, `${stepLabel} keeps the coordinator rules`).toBe(true);
    state = next.state;
  });
  return steps.length;
}

/**
 * Run a backoff vector: the delay of each failure in order, every delay
 * within one second and the cap, and a delivered event resets the next delay
 * to one second.
 */
function runBackoff(vector: JsonValue): number[] {
  const name = label("backoff", vector);
  let backoff: Backoff = INITIAL_BACKOFF;
  let delivered = false;
  const delays: number[] = [];
  for (const step of list(member(vector, "steps"))) {
    if (step === "failure") {
      const { delay, next } = reconnectDelay(backoff);
      expect(delivered && delay !== 1, `${name}: no reset after delivery`).toBe(false);
      delays.push(delay);
      backoff = next;
      delivered = false;
    } else if (step === "delivered") {
      backoff = INITIAL_BACKOFF;
      delivered = true;
    } else {
      throw new Error(`${name} has an unknown step`);
    }
  }
  expect(delays, name).toEqual(list(member(vector, "delays")).map(integerOf));
  expect(delays.every((delay) => delay >= 1 && delay <= RECONNECT_BACKOFF_MAX_SECONDS), name).toBe(true);
  return delays;
}

/** The fraction of a jitter vector as a double, as the Haskell checker reads it. */
function fractionOf(value: JsonValue | undefined): number {
  if (!(value instanceof JsonNumber)) throw new Error("jitter vector without a fraction");
  return Number(value.source);
}

/** The observation of a reconciliation vector. */
function observationOf(name: string, observation: JsonValue | undefined): ReconcileObservation {
  const state = member(observation, "receiptState");
  const etag = member(observation, "targetETag");
  const failure = member(observation, "failure");
  if (typeof state === "string" && etag === undefined && failure === undefined) {
    const parsed = parseCommandState(state);
    if (parsed === undefined) throw new Error(`${name} names an unknown receipt state`);
    return { kind: "receipt", state: parsed };
  }
  if (state === undefined && typeof etag === "string" && failure === undefined) {
    return { kind: "target", etag, effectVisible: member(observation, "effectVisible") === true };
  }
  if (state === undefined && etag === undefined && failure !== undefined) {
    if (failure === "InvalidResponse" || failure === "TransportUnavailable") return { kind: "failure", failure: { kind: failure } };
    const refused = list(member(failure, "refused"));
    const [status, code] = refused;
    if (refused.length === 2 && status !== undefined && typeof code === "string") {
      return { kind: "failure", failure: { kind: "Refused", status: integerOf(status), code } };
    }
    throw new Error(`${name} names an unknown failure`);
  }
  throw new Error(`${name} has a malformed observation`);
}

/**
 * Run a reconciliation vector. The read is the receipt location when one is
 * known and otherwise the target. A command that stays uncertain comes back
 * unchanged with its exact bytes, key and precondition, and no report sends.
 * The result is the report.
 */
function runReconciliation(vector: JsonValue): string {
  const name = label("reconciliation", vector);
  const target = textOf(member(vector, "target"));
  if (target === undefined) throw new Error(`${name} has no target`);
  const command = member(vector, "command");
  if (command === undefined) throw new Error(`${name} has no command`);
  const receipt = textOf(member(vector, "receipt")) ?? null;
  const uncertain: Uncertain<JsonValue, string> = {
    command,
    target,
    precondition: textOf(member(vector, "precondition")) ?? null,
    receipt,
  };
  const read = reconcileRead(uncertain);
  expect(read, `${name} read`).toEqual(receipt === null ? { kind: "target", location: target } : { kind: "receipt", location: receipt });
  expect(read.kind, `${name} read`).toBe(textOf(member(vector, "read")));
  const outcome = reconcile(uncertain, observationOf(name, member(vector, "observation")));
  expect(Object.keys(outcome).sort(), `${name} carries no send`).toEqual(outcome.kind === "uncertain" ? ["kind", "uncertain"] : ["kind"]);
  expect(outcome.kind, `${name} report`).toBe(textOf(member(vector, "report")));
  if (outcome.kind === "uncertain") {
    expect(outcome.uncertain, `${name} keeps the uncertain command`).toBe(uncertain);
    expect(outcome.uncertain, `${name} keeps the uncertain command`).toEqual(uncertain);
    expect(jsonEqual(outcome.uncertain.command, command), `${name} keeps the exact command`).toBe(true);
    expect(encodeJson(outcome.uncertain.command), `${name} keeps the exact bytes, key and precondition`).toBe(encodeJson(command));
  }
  return outcome.kind;
}

describe("manager client vectors: refresh", () => {
  it("has the stated number of cases in every subsection", () => {
    const counts = Object.fromEntries(Object.keys(REFRESH_COUNTS).map((name) =>
      [name, refreshCases(name as keyof typeof REFRESH_COUNTS).length]));
    expect(counts).toEqual(REFRESH_COUNTS);
  });

  it("runs every coordinator sequence with its exact actions and the coordinator rules", () => {
    const steps = refreshCases("sequences").map(runSequence);
    expect(steps.length).toBe(REFRESH_COUNTS.sequences);
    expect(steps.reduce((total, count) => total + count, 0)).toBe(87);
  });

  it("doubles the reconnection delay up to the cap and resets it after a delivered event", () => {
    const delays = refreshCases("backoff").map(runBackoff);
    expect(delays.length).toBe(REFRESH_COUNTS.backoff);
    expect(delays.flat().length).toBe(24);
  });

  it("jitters each wait between half the delay and the whole delay", () => {
    const ran = refreshCases("jitter").filter((vector) => {
      const seconds = integerOf(member(vector, "seconds"));
      const waited = jitteredMicroseconds(seconds, fractionOf(member(vector, "fraction")));
      expect(waited, label("jitter", vector)).toBe(integerOf(member(vector, "microseconds")));
      expect(waited <= 1000000 * RECONNECT_BACKOFF_MAX_SECONDS && 2 * waited >= 1000000 * seconds, label("jitter", vector)).toBe(true);
      return true;
    }).length;
    expect(ran).toBe(REFRESH_COUNTS.jitter);
  });

  it("reconciles each uncertain command by one read and keeps an uncertain one unchanged", () => {
    const reports = refreshCases("reconciliation").map(runReconciliation);
    expect(reports.length).toBe(REFRESH_COUNTS.reconciliation);
    const tally = Object.fromEntries(["effect-observed", "refused", "uncertain"].map((report) =>
      [report, reports.filter((kind) => kind === report).length]));
    expect(tally).toEqual({ "effect-observed": 3, refused: 1, uncertain: 13 });
  });

  it("returns new states and never changes the state that it receives", () => {
    const start = newRefresh<string>();
    const fetched = invalidateResource("/v1/runs/run_1", start);
    expect(start.flights.size).toBe(0);
    const dirty = invalidateResource("/v1/runs/run_1", fetched.state);
    expect(fetched.state.flights.get("/v1/runs/run_1")).toEqual({ generation: 0, dirty: false });
    const completed = completeFetch("/v1/runs/run_1", 0, dirty.state);
    expect(dirty.state.flights.get("/v1/runs/run_1")).toEqual({ generation: 0, dirty: true });
    expect(completed.state.flights.get("/v1/runs/run_1")).toEqual({ generation: 0, dirty: false });
    const advanced = advanceGeneration(completed.state);
    expect(completed.state.generation).toBe(0);
    expect(advanced).toEqual({ generation: 1, flights: new Map() });
  });

  it("counts a fraction that is not a number as zero", () => {
    expect(jitteredMicroseconds(4, Number.NaN)).toBe(2000000);
  });
});
