/**
 * Pure decoders of the public resources of the manager client, their
 * projections, and the typed answer of a decision. Nothing here performs I/O
 * or holds a session.
 *
 * The draft, preparation and receipt decoders state the behavior of the
 * shared protocol codecs `Agentic.Manager.Protocol.Draft`,
 * `Agentic.Manager.Protocol.Preparation` and `Agentic.Manager.Protocol.Command`,
 * and each `encode` function gives their canonical encoding. The decision,
 * control, run and overview decoders, their projections, `answerValue` and
 * `answerBody` state the behavior of the service parsers of
 * `Agentic.Tui.Service`. It imports no Haskell code. The `resources` section
 * of `test/manager_client_vectors.json` is the shared definition that both
 * implementations pass.
 *
 * A decoded value grants no ownership, approval, supervision or control
 * authority. It is display and precondition data.
 *
 * @packageDocumentation
 */

import { validId, validResource, type Outcome } from "./events.ts";
import {
  JsonNumber,
  WORD64_MAX,
  boundedInteger,
  decimalOf,
  encodeJson,
  isJsonArray,
  isJsonObject,
  jsonEqual,
  jsonMember,
  tryParseJson,
  type JsonObject,
  type JsonValue,
} from "./json.ts";
import { COMMAND_STATES, type CommandState } from "./refresh.ts";

const INVALID_RESPONSE: Outcome<never> = { ok: false, failure: { kind: "InvalidResponse" } };

function decided<Value>(value: Value | undefined): Outcome<Value> {
  return value === undefined ? INVALID_RESPONSE : { ok: true, value };
}

// ---------------------------------------------------------------------------
// Field readers. Each gives `undefined` when the value does not agree, and a
// missing member is `undefined`, so a missing nullable member refuses.

/** The number of Unicode code points of a text, as `Data.Text.length` counts them. */
function textLength(value: string): number {
  let count = 0;
  for (let index = 0; index < value.length; index += 1) {
    const unit = value.charCodeAt(index);
    if (unit >= 0xd800 && unit <= 0xdbff && index + 1 < value.length) {
      const next = value.charCodeAt(index + 1);
      if (next >= 0xdc00 && next <= 0xdfff) index += 1;
    }
    count += 1;
  }
  return count;
}

function bounded(value: string, lower: number, upper: number): boolean {
  const length = textLength(value);
  return length >= lower && length <= upper;
}

function textOf(value: JsonValue | undefined): string | undefined {
  return typeof value === "string" ? value : undefined;
}

function boundedText(value: JsonValue | undefined, lower: number, upper: number): string | undefined {
  return typeof value === "string" && bounded(value, lower, upper) ? value : undefined;
}

function boolOf(value: JsonValue | undefined): boolean | undefined {
  return typeof value === "boolean" ? value : undefined;
}

const INT64_MIN = -(2n ** 63n);
const INT64_MAX = 2n ** 63n - 1n;

/**
 * A Haskell `Int`: an integral number inside the signed 64-bit range, or
 * inside the narrower range that the caller gives. Each caller compares the
 * result with a small range, so the conversion to `number` loses nothing that
 * decides.
 */
function intOf(value: JsonValue | undefined, minimum: bigint = INT64_MIN, maximum: bigint = INT64_MAX): number | undefined {
  if (!(value instanceof JsonNumber)) return undefined;
  const integer = boundedInteger(value, minimum, maximum);
  return integer === undefined ? undefined : Number(integer);
}

function oneOf<Choice extends string>(value: JsonValue | undefined, choices: readonly Choice[]): Choice | undefined {
  return typeof value === "string" ? choices.find((choice) => choice === value) : undefined;
}

/** `null` for JSON null, the parsed value otherwise, and `undefined` for a missing or refused value. */
function nullable<Parsed>(value: JsonValue | undefined, parse: (value: JsonValue) => Parsed | undefined): Parsed | null | undefined {
  if (value === undefined) return undefined;
  return value === null ? null : parse(value);
}

/** The parsed items of an array of at most `limit` items, or `undefined`. */
function listOf<Parsed>(value: JsonValue | undefined, parse: (item: JsonValue) => Parsed | undefined, limit = Infinity): Parsed[] | undefined {
  if (value === undefined || !isJsonArray(value) || value.length > limit) return undefined;
  const items: Parsed[] = [];
  for (const item of value) {
    const parsed = parse(item);
    if (parsed === undefined) return undefined;
    items.push(parsed);
  }
  return items;
}

function unique(values: readonly string[]): boolean {
  return new Set(values).size === values.length;
}

/** The object of a value when its own members are exactly the given names. */
function exact(value: JsonValue | undefined, names: readonly string[]): JsonObject | undefined {
  if (value === undefined || !isJsonObject(value)) return undefined;
  const present = Object.keys(value);
  return present.length === names.length && names.every((name) => Object.hasOwn(value, name)) ? value : undefined;
}

/** The object of a value when each of its own members has one of the given names. */
function within(value: JsonValue | undefined, names: readonly string[]): JsonObject | undefined {
  if (value === undefined || !isJsonObject(value)) return undefined;
  return Object.keys(value).every((name) => names.includes(name)) ? value : undefined;
}

function versionOne(fields: JsonObject): boolean {
  return intOf(jsonMember(fields, "version")) === 1;
}

/** A lowercase hexadecimal SHA-256 digest. */
function validDigest(value: string): boolean {
  return /^[0-9a-f]{64}$/.test(value);
}

/** A canonical unsigned decimal of at most `digits` digits, and at most `maximum` when one is given. */
function canonicalDecimal(value: string, digits: number, maximum?: bigint): bigint | undefined {
  if (value.length > digits || !/^(?:0|[1-9][0-9]*)$/.test(value)) return undefined;
  const number = BigInt(value);
  return maximum === undefined || number <= maximum ? number : undefined;
}

/** A canonical unsigned 64-bit decimal text of any length, as the protocol `decimal` reads it. */
function word64Text(value: JsonValue | undefined): bigint | undefined {
  return typeof value === "string" ? canonicalDecimal(value, Infinity, WORD64_MAX) : undefined;
}

const MAXIMUM_DAY = [31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];

/**
 * An RFC 3339 timestamp of 20 to 64 characters as the protocol accepts it:
 * a valid Gregorian date, a time below 24:00:00 with optional fraction
 * digits, and `Z` or an offset below 24:00. Letters are case-insensitive.
 */
function validTimestamp(value: string): boolean {
  if (!bounded(value, 20, 64)) return false;
  const match = /^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\.[0-9]+)?(?:Z|[+-]([0-9]{2}):([0-9]{2}))$/
    .exec(value.toUpperCase());
  if (match === null) return false;
  const [year, month, day, hour, minute, second] = match.slice(1, 7).map(Number);
  const leap = year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0);
  const zoneHour = match[7] === undefined ? 0 : Number(match[7]);
  const zoneMinute = match[8] === undefined ? 0 : Number(match[8]);
  return year !== 0 && month >= 1 && month <= 12 && day >= 1
    && day <= (month === 2 && !leap ? 28 : MAXIMUM_DAY[month - 1])
    && hour < 24 && minute < 60 && second < 60 && zoneHour < 24 && zoneMinute < 60;
}

// ---------------------------------------------------------------------------
// Observation codes and semantic schemas.

/** The depth rule of one owner: the depth step of each nesting level and the deepest depth accepted. */
type DepthRule = { readonly step: number; readonly deepest: number };

/** The depth rule of `Agentic.Manager.Protocol.Preparation`. */
const REVIEW_DEPTH: DepthRule = { step: 2, deepest: 64 };

/** The depth rule of `Agentic.Tui.Service`. */
const DECISION_DEPTH: DepthRule = { step: 1, deepest: 63 };

const SEMANTIC_PRIMITIVES = ["null", "boolean", "integer", "number", "string", "object"] as const;

/** A semantic schema as data: a primitive, an array of one item schema, or a chain of named properties. */
function semanticSchema(value: JsonValue, depth: number, rule: DepthRule): boolean {
  if (depth > rule.deepest) return false;
  if (typeof value === "string") return oneOf(value, SEMANTIC_PRIMITIVES) !== undefined;
  if (isJsonObject(value) && Object.hasOwn(value, "array")) {
    const array = exact(jsonMember(exact(value, ["array"]) ?? {}, "array"), ["items"]);
    const items = array === undefined ? undefined : jsonMember(array, "items");
    return items !== undefined && semanticSchema(items, depth + rule.step, rule);
  }
  return semanticObject(value, depth, new Set(), rule);
}

function semanticObject(value: JsonValue, depth: number, seen: ReadonlySet<string>, rule: DepthRule): boolean {
  if (depth > rule.deepest) return false;
  if (value === "object") return true;
  const property = exact(jsonMember(exact(value, ["property"]) ?? {}, "property"), ["name", "schema", "rest"]);
  if (property === undefined) return false;
  const name = boundedText(jsonMember(property, "name"), 0, 1024);
  const schema = jsonMember(property, "schema");
  const rest = jsonMember(property, "rest");
  return name !== undefined && !seen.has(name) && schema !== undefined && rest !== undefined
    && semanticSchema(schema, depth + rule.step, rule) && semanticObject(rest, depth + rule.step, new Set([...seen, name]), rule);
}

const PRIMITIVE_CODES = ["text", "verdict", "flag", "receipt"] as const;

/** A primitive observation code, or `{"json":{"schema":S}}` with a semantic schema `S`. */
function observationCode(value: JsonValue | undefined, rule: DepthRule): JsonValue | undefined {
  if (value === undefined) return undefined;
  if (typeof value === "string") return oneOf(value, PRIMITIVE_CODES) === undefined ? undefined : value;
  const json = exact(jsonMember(exact(value, ["json"]) ?? {}, "json"), ["schema"]);
  const schema = json === undefined ? undefined : jsonMember(json, "schema");
  return schema !== undefined && semanticSchema(schema, 0, rule) ? value : undefined;
}

// ---------------------------------------------------------------------------
// Requests and readiness (Agentic.Manager.Protocol.Draft).

/** A non-empty input name of at most 1024 characters without NUL. */
function inputNameValid(name: string): boolean {
  return bounded(name, 1, 1024) && !name.includes("\0");
}

function inputName(value: JsonValue | undefined): string | undefined {
  return typeof value === "string" && inputNameValid(value) ? value : undefined;
}

/** @public */
export const INPUT_SOURCES = ["prompt", "command-tail", "stdin"] as const;
/** @public */
export type InputSource = (typeof INPUT_SOURCES)[number];

/**
 * One declared workflow input. Every declaration is a required string input
 * without description.
 *
 * @public
 */
export type InputDeclaration = { readonly name: string; readonly source: InputSource };

/**
 * One supplied input: literal text, or the opaque selector of a capture.
 *
 * @public
 */
export type SuppliedInput =
  | { readonly source: "literal"; readonly name: string; readonly value: string }
  | { readonly source: "capture"; readonly name: string; readonly captureId: string };

/** @public */
export const INPUT_ERROR_CODES = ["unknown-input", "invalid-input", "capture-unavailable", "size-limit"] as const;
/** @public */
export type InputErrorCode = (typeof INPUT_ERROR_CODES)[number];

/** @public */
export type InputError = { readonly name: string; readonly code: InputErrorCode };

/**
 * The readiness of a request. `missing` names each declaration without a
 * supplied input, in declaration order.
 *
 * @public
 */
export type Readiness = {
  readonly declarations: readonly InputDeclaration[];
  readonly supplied: readonly SuppliedInput[];
  readonly missing: readonly string[];
  readonly errors: readonly InputError[];
};

/** @public */
export const REQUEST_PHASES = ["draft", "queued", "preparing", "review", "start-pending", "associated", "withdrawn", "refused"] as const;
/** @public */
export type RequestPhase = (typeof REQUEST_PHASES)[number];
/** @public */
export const ADMISSION_STATES = ["not-queued", "waiting", "reserved", "released", "refused"] as const;
/** @public */
export type AdmissionState = (typeof ADMISSION_STATES)[number];
/** @public */
export const ADMISSION_REASONS = [
  "missing-inputs", "profile-busy", "workspace-busy", "target-busy", "store-busy", "capacity", "quarantined", "storage-quota",
] as const;
/** @public */
export type AdmissionReason = (typeof ADMISSION_REASONS)[number];
/** @public */
export const LINEAGE_OPERATIONS = ["restart", "resume", "fork"] as const;
/** @public */
export type LineageOperation = (typeof LINEAGE_OPERATIONS)[number];

/**
 * One versioned request resource. The admission position is 1 to 100 or
 * absent.
 *
 * @public
 */
export type DraftView = {
  readonly id: string;
  readonly revision: string;
  readonly workflowId: string;
  readonly descriptorRevision: string;
  readonly profileId: string;
  readonly profileRevision: string;
  readonly phase: RequestPhase;
  readonly readiness: Readiness;
  readonly admission: { readonly state: AdmissionState; readonly position: number | null; readonly reasons: readonly AdmissionReason[] };
  readonly preparationId: string | null;
  readonly runId: string | null;
  readonly parentRunId: string | null;
  readonly lineage: LineageOperation | null;
};

const STRING_SCHEMA: JsonValue = { type: "string" };

function parseInputDeclaration(value: JsonValue): InputDeclaration | undefined {
  const fields = exact(value, ["name", "source", "description", "required", "schema"]);
  if (fields === undefined) return undefined;
  const name = inputName(jsonMember(fields, "name"));
  const source = oneOf(jsonMember(fields, "source"), INPUT_SOURCES);
  const schema = jsonMember(fields, "schema");
  return name !== undefined && source !== undefined && jsonMember(fields, "description") === null
    && jsonMember(fields, "required") === true && schema !== undefined && jsonEqual(schema, STRING_SCHEMA)
    ? { name, source } : undefined;
}

function parseSuppliedInput(value: JsonValue): SuppliedInput | undefined {
  if (!isJsonObject(value)) return undefined;
  const name = inputName(jsonMember(value, "name"));
  const source = textOf(jsonMember(value, "source"));
  if (name === undefined) return undefined;
  if (source === "literal") {
    const fields = exact(value, ["name", "source", "value"]);
    const literal = fields === undefined ? undefined : boundedText(jsonMember(fields, "value"), 0, 2097152);
    return literal === undefined ? undefined : { source, name, value: literal };
  }
  if (source === "capture") {
    const fields = exact(value, ["name", "source", "captureId"]);
    const captureId = fields === undefined ? undefined : textOf(jsonMember(fields, "captureId"));
    return captureId === undefined || !validId(captureId) ? undefined : { source, name, captureId };
  }
  return undefined;
}

function parseInputError(value: JsonValue): InputError | undefined {
  const fields = exact(value, ["name", "code"]);
  if (fields === undefined) return undefined;
  const name = inputName(jsonMember(fields, "name"));
  const code = oneOf(jsonMember(fields, "code"), INPUT_ERROR_CODES);
  return name === undefined || code === undefined ? undefined : { name, code };
}

function parseReadiness(value: JsonValue | undefined): Readiness | undefined {
  const fields = exact(value, ["declarations", "supplied", "missing", "errors"]);
  if (fields === undefined) return undefined;
  const declarations = listOf(jsonMember(fields, "declarations"), parseInputDeclaration);
  const supplied = listOf(jsonMember(fields, "supplied"), parseSuppliedInput);
  const missing = listOf(jsonMember(fields, "missing"), textOf);
  const errors = listOf(jsonMember(fields, "errors"), parseInputError);
  if (declarations === undefined || supplied === undefined || missing === undefined || errors === undefined) return undefined;
  const names = declarations.map((declaration) => declaration.name);
  const present = supplied.map((input) => input.name);
  const expectedMissing = names.filter((name) => !present.includes(name));
  const sized = [names, present, missing, errors].every((items) => items.length <= 256);
  return sized && unique(names) && unique(present) && present.every((name) => names.includes(name))
    && missing.length === expectedMissing.length && missing.every((name, index) => name === expectedMissing[index])
    ? { declarations, supplied, missing, errors } : undefined;
}

function parseDraftView(value: JsonValue): DraftView | undefined {
  const fields = exact(value, [
    "version", "id", "revision", "workflowId", "descriptorRevision", "profileId", "profileRevision", "phase", "readiness",
    "admission", "preparationId", "runId", "parentRunId", "lineage", "links",
  ]);
  if (fields === undefined || !versionOne(fields)) return undefined;
  const admission = exact(jsonMember(fields, "admission"), ["state", "position", "reasons"]);
  if (admission === undefined) return undefined;
  const ids = ["id", "revision", "workflowId", "descriptorRevision", "profileId", "profileRevision"]
    .map((name) => textOf(jsonMember(fields, name)));
  const [id, revision, workflowId, descriptorRevision, profileId, profileRevision] = ids;
  const phase = oneOf(jsonMember(fields, "phase"), REQUEST_PHASES);
  const readiness = parseReadiness(jsonMember(fields, "readiness"));
  const state = oneOf(jsonMember(admission, "state"), ADMISSION_STATES);
  const position = nullable(jsonMember(admission, "position"), (number) => intOf(number, 1n, 100n));
  const reasons = listOf(jsonMember(admission, "reasons"), (reason) => oneOf(reason, ADMISSION_REASONS), 8);
  const identity = (member: JsonValue) => (typeof member === "string" && validId(member) ? member : undefined);
  const preparationId = nullable(jsonMember(fields, "preparationId"), identity);
  const runId = nullable(jsonMember(fields, "runId"), identity);
  const parentRunId = nullable(jsonMember(fields, "parentRunId"), identity);
  const lineage = nullable(jsonMember(fields, "lineage"), (operation) => oneOf(operation, LINEAGE_OPERATIONS));
  if (id === undefined || revision === undefined || workflowId === undefined || descriptorRevision === undefined
    || profileId === undefined || profileRevision === undefined || !ids.every((text) => text !== undefined && validId(text))
    || phase === undefined || readiness === undefined || state === undefined || position === undefined || reasons === undefined
    || !unique(reasons) || preparationId === undefined || runId === undefined || parentRunId === undefined || lineage === undefined) {
    return undefined;
  }
  const links = jsonMember(fields, "links");
  if (links === undefined || !jsonEqual(links, { self: `/v1/requests/${id}` })) return undefined;
  return {
    id, revision, workflowId, descriptorRevision, profileId, profileRevision, phase, readiness,
    admission: { state, position, reasons }, preparationId, runId, parentRunId, lineage,
  };
}

/** Decode an input declaration, or refuse with `InvalidResponse`. @public */
export function decodeInputDeclaration(value: JsonValue): Outcome<InputDeclaration> {
  return decided(parseInputDeclaration(value));
}

/** The canonical encoding of an input declaration. @public */
export function encodeInputDeclaration(declaration: InputDeclaration): JsonValue {
  return { name: declaration.name, source: declaration.source, description: null, required: true, schema: STRING_SCHEMA };
}

/** Decode a supplied input, or refuse with `InvalidResponse`. @public */
export function decodeSuppliedInput(value: JsonValue): Outcome<SuppliedInput> {
  return decided(parseSuppliedInput(value));
}

/** The canonical encoding of a supplied input. @public */
export function encodeSuppliedInput(input: SuppliedInput): JsonValue {
  return input.source === "literal"
    ? { name: input.name, source: "literal", value: input.value }
    : { name: input.name, source: "capture", captureId: input.captureId };
}

/** Decode an input error, or refuse with `InvalidResponse`. @public */
export function decodeInputError(value: JsonValue): Outcome<InputError> {
  return decided(parseInputError(value));
}

/** The canonical encoding of an input error. @public */
export function encodeInputError(error: InputError): JsonValue {
  return { name: error.name, code: error.code };
}

/** Decode a readiness, or refuse with `InvalidResponse`. @public */
export function decodeReadiness(value: JsonValue): Outcome<Readiness> {
  return decided(parseReadiness(value));
}

/** The canonical encoding of a readiness. @public */
export function encodeReadiness(readiness: Readiness): JsonValue {
  return {
    declarations: readiness.declarations.map(encodeInputDeclaration),
    supplied: readiness.supplied.map(encodeSuppliedInput),
    missing: [...readiness.missing],
    errors: readiness.errors.map(encodeInputError),
  };
}

/**
 * Decode a request resource, or one item of the request collection, or
 * refuse with `InvalidResponse`.
 *
 * @public
 */
export function decodeDraftView(value: JsonValue): Outcome<DraftView> {
  return decided(parseDraftView(value));
}

/** The canonical encoding of a request resource. @public */
export function encodeDraftView(draft: DraftView): JsonValue {
  return {
    version: new JsonNumber("1"),
    id: draft.id,
    revision: draft.revision,
    workflowId: draft.workflowId,
    descriptorRevision: draft.descriptorRevision,
    profileId: draft.profileId,
    profileRevision: draft.profileRevision,
    phase: draft.phase,
    readiness: encodeReadiness(draft.readiness),
    admission: {
      state: draft.admission.state,
      position: draft.admission.position === null ? null : JsonNumber.ofBigInt(BigInt(draft.admission.position)),
      reasons: [...draft.admission.reasons],
    },
    preparationId: draft.preparationId,
    runId: draft.runId,
    parentRunId: draft.parentRunId,
    lineage: draft.lineage,
    links: { self: `/v1/requests/${draft.id}` },
  };
}

/**
 * The receipt of one capture: its opaque identifier, the request and the
 * profile that it is bound to, and the size and SHA-256 of the exact
 * captured bytes. A capture supplies no input until a `set-input` names its
 * identifier.
 *
 * @public
 */
export type CaptureReceipt = {
  readonly id: string;
  readonly requestId: string;
  readonly profileId: string;
  readonly bytes: bigint;
  readonly sha256: string;
};

/** The largest capture, in bytes, as `CaptureReceipt` of `Agentic.Manager.Protocol.Draft` bounds it. */
const CAPTURE_BYTES = 67108864n;

function parseCaptureReceipt(value: JsonValue): CaptureReceipt | undefined {
  const fields = exact(value, ["version", "id", "requestId", "profileId", "bytes", "sha256"]);
  if (fields === undefined || !versionOne(fields)) return undefined;
  const id = textOf(jsonMember(fields, "id"));
  const requestId = textOf(jsonMember(fields, "requestId"));
  const profileId = textOf(jsonMember(fields, "profileId"));
  const size = textOf(jsonMember(fields, "bytes"));
  const bytes = size === undefined ? undefined : canonicalDecimal(size, 8, CAPTURE_BYTES);
  const sha256 = textOf(jsonMember(fields, "sha256"));
  return id === undefined || !validId(id) || requestId === undefined || !validId(requestId) || profileId === undefined
    || !validId(profileId) || bytes === undefined || sha256 === undefined || !validDigest(sha256)
    ? undefined : { id, requestId, profileId, bytes, sha256 };
}

/**
 * Decode a capture receipt, or refuse with `InvalidResponse`. The byte
 * count is canonical decimal text of at most 67108864, and the digest is 64
 * lowercase hexadecimal digits.
 *
 * @public
 */
export function decodeCaptureReceipt(value: JsonValue): Outcome<CaptureReceipt> {
  return decided(parseCaptureReceipt(value));
}

// ---------------------------------------------------------------------------
// Preparations and reviews (Agentic.Manager.Protocol.Preparation).

/**
 * A captured or literal input of a review with its exact byte count and
 * SHA-256 digest.
 *
 * @public
 */
export type ReviewInput = { readonly name: string; readonly source: "literal" | "capture"; readonly bytes: bigint; readonly sha256: string };

/**
 * One typed answer edit of a fork. A replacement names the SHA-256 digest of
 * its answer and never the answer.
 *
 * @public
 */
export type ReviewEdit =
  | { readonly operation: "drop"; readonly occurrenceId: bigint }
  | { readonly operation: "replace"; readonly occurrenceId: bigint; readonly sha256: string };

/**
 * The lineage of a restart, resume or fork preparation. Only a fork carries
 * edits.
 *
 * @public
 */
export type ReviewLineage = { readonly parentRunId: string; readonly operation: LineageOperation; readonly edits: readonly ReviewEdit[] };

/**
 * The bounded consent facts of one preparation. The policy and the result
 * code are kept as their validated JSON values. A root review has no lineage.
 *
 * @public
 */
export type Review = {
  readonly programHash: string;
  readonly personAnswering: "engine" | "local-control";
  readonly policy: JsonValue;
  readonly workflowId: string;
  readonly profileId: string;
  readonly workspaceLabel: string;
  readonly targetLabel: string;
  readonly inputs: readonly ReviewInput[];
  readonly plan: string;
  readonly runFacts: readonly string[];
  readonly pins: readonly string[];
  readonly warnings: readonly string[];
  readonly resultCode: JsonValue;
  readonly lineage: ReviewLineage | null;
};

/** @public */
export const PREPARATION_STATES = ["live", "consumed", "invalidated"] as const;
/** @public */
export type PreparationState = (typeof PREPARATION_STATES)[number];
/** @public */
export const PREPARATION_REASONS = [
  "expired", "input-changed", "profile-changed", "worker-lost", "discarded", "authority-changed", "consumed",
] as const;
/** @public */
export type PreparationReason = (typeof PREPARATION_REASONS)[number];

/**
 * One versioned preparation. It is not a live worker and not an approval
 * permit.
 *
 * @public
 */
export type Preparation = {
  readonly id: string;
  readonly revision: string;
  readonly requestId: string;
  readonly requestRevision: string;
  readonly profileId: string;
  readonly profileRevision: string;
  readonly descriptorRevision: string;
  readonly state: PreparationState;
  readonly expiresAt: string;
  readonly reviewDigest: string;
  readonly processGeneration: string;
  readonly review: Review;
  readonly reason: PreparationReason | null;
};

const POLICY_KEYS = [
  "kind", "default", "coverage", "routes", "pollMs", "timeoutMs", "verbose", "realizations", "routingVersion", "persona",
  "personaSource", "policyDigest", "personAnswers",
] as const;
const REALIZATION_KEYS = [
  "profile", "axis", "rung", "backend", "router", "provider", "model", "thinking", "maxOutput", "executionFingerprint",
  "modelAlias", "engine",
] as const;
const THINKING_LEVELS = ["off", "minimal", "low", "medium", "high", "xhigh", "max"] as const;
const PERSONA_SOURCES = ["command-line", "environment", "project", "user-default"] as const;

function policyLabel(value: JsonValue | undefined): boolean {
  return boundedText(value, 0, 1024) !== undefined;
}

/** Null, or an integral number from 1 to 2^31-1. A missing member refuses. */
function nullablePositive(value: JsonValue | undefined): boolean {
  return value === null || (value instanceof JsonNumber && boundedInteger(value, 1n, 2147483647n) !== undefined);
}

function validRealization(value: JsonValue): boolean {
  const fields = within(value, REALIZATION_KEYS);
  if (fields === undefined) return false;
  const fingerprint = jsonMember(fields, "executionFingerprint");
  const rung = jsonMember(fields, "rung");
  return ["profile", "axis", "backend", "router", "provider", "model"].every((name) => policyLabel(jsonMember(fields, name)))
    && rung instanceof JsonNumber && boundedInteger(rung, 0n, 2147483647n) !== undefined
    && oneOf(jsonMember(fields, "thinking"), THINKING_LEVELS) !== undefined
    && nullablePositive(jsonMember(fields, "maxOutput"))
    && ["modelAlias", "engine"].every((name) => !Object.hasOwn(fields, name) || policyLabel(jsonMember(fields, name)))
    && (fingerprint === undefined || (typeof fingerprint === "string" && validDigest(fingerprint)));
}

function validPersonAnswers(value: JsonValue): boolean {
  const addresses = listOf(value, textOf);
  return addresses !== undefined && addresses.length > 0 && addresses.length <= 256
    && addresses.every((address) => bounded(address, 1, 1024)
      && ["model:", "tool:"].some((prefix) => address.startsWith(prefix) && address.length > prefix.length));
}

/** The frozen allowlisted policy of one prepared response: a scripted policy or a routed policy. */
function validPolicy(value: JsonValue | undefined): boolean {
  if (value === undefined || !isJsonObject(value)) return false;
  const kind = textOf(jsonMember(value, "kind"));
  if (kind === "scripted") return within(value, ["kind"]) !== undefined;
  if (kind !== "routed" || within(value, POLICY_KEYS) === undefined) return false;
  const hasDefault = Object.hasOwn(value, "default");
  if (hasDefault === Object.hasOwn(value, "coverage")) return false;
  if (hasDefault ? !policyLabel(jsonMember(value, "default")) : jsonMember(value, "coverage") !== "full") return false;
  const routes = jsonMember(value, "routes");
  if (routes === undefined || !isJsonArray(routes) || routes.length > 64) return false;
  const routesValid = routes.every((route) => {
    const fields = within(route, ["name", "backend"]);
    return fields !== undefined && policyLabel(jsonMember(fields, "name")) && policyLabel(jsonMember(fields, "backend"));
  });
  const realizations = jsonMember(value, "realizations");
  if (!routesValid || !nullablePositive(jsonMember(value, "pollMs")) || !nullablePositive(jsonMember(value, "timeoutMs"))
    || boolOf(jsonMember(value, "verbose")) === undefined
    || realizations === undefined || !isJsonArray(realizations) || realizations.length > 256 || !realizations.every(validRealization)) {
    return false;
  }
  const answers = jsonMember(value, "personAnswers");
  if (answers !== undefined && !validPersonAnswers(answers)) return false;
  const persona = ["routingVersion", "persona", "personaSource", "policyDigest"].filter((name) => Object.hasOwn(value, name));
  if (persona.length === 0) return true;
  const digest = textOf(jsonMember(value, "policyDigest"));
  return persona.length === 4 && intOf(jsonMember(value, "routingVersion")) === 2 && policyLabel(jsonMember(value, "persona"))
    && oneOf(jsonMember(value, "personaSource"), PERSONA_SOURCES) !== undefined && digest !== undefined && validDigest(digest);
}

function parseReviewInput(value: JsonValue): ReviewInput | undefined {
  const fields = within(value, ["name", "source", "bytes", "sha256"]);
  if (fields === undefined) return undefined;
  const name = boundedText(jsonMember(fields, "name"), 1, 1024);
  const source = oneOf(jsonMember(fields, "source"), ["literal", "capture"] as const);
  const bytes = word64Text(jsonMember(fields, "bytes"));
  const sha256 = textOf(jsonMember(fields, "sha256"));
  return name === undefined || source === undefined || bytes === undefined || sha256 === undefined || !validDigest(sha256)
    ? undefined : { name, source, bytes, sha256 };
}

function parseReviewEdit(value: JsonValue): ReviewEdit | undefined {
  if (!isJsonObject(value)) return undefined;
  const operation = textOf(jsonMember(value, "operation"));
  if (operation === "drop") {
    const fields = within(value, ["operation", "occurrenceId"]);
    const occurrenceId = fields === undefined ? undefined : word64Text(jsonMember(fields, "occurrenceId"));
    return occurrenceId === undefined ? undefined : { operation, occurrenceId };
  }
  if (operation === "replace") {
    const fields = within(value, ["operation", "occurrenceId", "sha256"]);
    if (fields === undefined) return undefined;
    const sha256 = textOf(jsonMember(fields, "sha256"));
    const occurrenceId = word64Text(jsonMember(fields, "occurrenceId"));
    return sha256 === undefined || !validDigest(sha256) || occurrenceId === undefined ? undefined : { operation, occurrenceId, sha256 };
  }
  return undefined;
}

function parseReviewLineage(value: JsonValue): ReviewLineage | undefined {
  const fields = within(value, ["parentRunId", "operation", "edits"]);
  if (fields === undefined) return undefined;
  const parentRunId = textOf(jsonMember(fields, "parentRunId"));
  const operation = textOf(jsonMember(fields, "operation"));
  const edits = listOf(jsonMember(fields, "edits"), parseReviewEdit);
  if (parentRunId === undefined || !validId(parentRunId) || operation === undefined || edits === undefined) return undefined;
  const known = oneOf(operation, LINEAGE_OPERATIONS);
  return known !== undefined && edits.length <= 2048 && (edits.length === 0 || known === "fork")
    ? { parentRunId, operation: known, edits } : undefined;
}

function boundedTexts(value: JsonValue | undefined): string[] | undefined {
  return listOf(value, (item) => boundedText(item, 0, 4096), 256);
}

function parseReview(value: JsonValue | undefined): Review | undefined {
  const fields = within(value, [
    "programHash", "personAnswering", "policy", "workflowId", "profileId", "workspaceLabel", "targetLabel", "inputs", "plan",
    "runFacts", "pins", "warnings", "resultCode", "lineage",
  ]);
  if (fields === undefined) return undefined;
  const programHash = textOf(jsonMember(fields, "programHash"));
  const personAnswering = oneOf(jsonMember(fields, "personAnswering"), ["engine", "local-control"] as const);
  const policy = jsonMember(fields, "policy");
  const workflowId = textOf(jsonMember(fields, "workflowId"));
  const profileId = textOf(jsonMember(fields, "profileId"));
  const workspaceLabel = boundedText(jsonMember(fields, "workspaceLabel"), 0, 4096);
  const targetLabel = boundedText(jsonMember(fields, "targetLabel"), 0, 4096);
  const inputs = listOf(jsonMember(fields, "inputs"), parseReviewInput, 256);
  const plan = boundedText(jsonMember(fields, "plan"), 0, 524288);
  const runFacts = boundedTexts(jsonMember(fields, "runFacts"));
  const pins = boundedTexts(jsonMember(fields, "pins"));
  const warnings = boundedTexts(jsonMember(fields, "warnings"));
  const resultCode = observationCode(jsonMember(fields, "resultCode"), REVIEW_DEPTH);
  const lineageValue = jsonMember(fields, "lineage");
  const lineage = lineageValue === undefined ? null : parseReviewLineage(lineageValue);
  if (programHash === undefined || !validDigest(programHash) || personAnswering === undefined || policy === undefined
    || !validPolicy(policy) || workflowId === undefined || !validId(workflowId) || profileId === undefined || !validId(profileId)
    || workspaceLabel === undefined || targetLabel === undefined || inputs === undefined || plan === undefined
    || runFacts === undefined || pins === undefined || warnings === undefined || resultCode === undefined || lineage === undefined) {
    return undefined;
  }
  return {
    programHash, personAnswering, policy, workflowId, profileId, workspaceLabel, targetLabel, inputs, plan, runFacts, pins,
    warnings, resultCode, lineage,
  };
}

function parsePreparation(value: JsonValue): Preparation | undefined {
  const fields = within(value, [
    "version", "id", "revision", "requestId", "requestRevision", "profileId", "profileRevision", "descriptorRevision", "state",
    "expiresAt", "reviewDigest", "processGeneration", "review", "reason",
  ]);
  if (fields === undefined || !versionOne(fields)) return undefined;
  const names = ["id", "revision", "requestId", "requestRevision", "profileId", "profileRevision", "descriptorRevision",
    "processGeneration"] as const;
  const ids = names.map((name) => textOf(jsonMember(fields, name)));
  const [id, revision, requestId, requestRevision, profileId, profileRevision, descriptorRevision, processGeneration] = ids;
  const state = oneOf(jsonMember(fields, "state"), PREPARATION_STATES);
  const expiresAt = textOf(jsonMember(fields, "expiresAt"));
  const reviewDigest = textOf(jsonMember(fields, "reviewDigest"));
  const review = parseReview(jsonMember(fields, "review"));
  const reason = nullable(jsonMember(fields, "reason"), (text) => oneOf(text, PREPARATION_REASONS));
  if (id === undefined || revision === undefined || requestId === undefined || requestRevision === undefined
    || profileId === undefined || profileRevision === undefined || descriptorRevision === undefined
    || processGeneration === undefined || !ids.every((text) => text !== undefined && validId(text)) || state === undefined
    || expiresAt === undefined || !validTimestamp(expiresAt) || reviewDigest === undefined || !validDigest(reviewDigest)
    || review === undefined || reason === undefined) {
    return undefined;
  }
  return {
    id, revision, requestId, requestRevision, profileId, profileRevision, descriptorRevision, state, expiresAt, reviewDigest,
    processGeneration, review, reason,
  };
}

/** Decode a review input, or refuse with `InvalidResponse`. @public */
export function decodeReviewInput(value: JsonValue): Outcome<ReviewInput> {
  return decided(parseReviewInput(value));
}

/** The canonical encoding of a review input. The byte count is canonical decimal text. @public */
export function encodeReviewInput(input: ReviewInput): JsonValue {
  return { name: input.name, source: input.source, bytes: input.bytes.toString(), sha256: input.sha256 };
}

/** Decode a review edit, or refuse with `InvalidResponse`. @public */
export function decodeReviewEdit(value: JsonValue): Outcome<ReviewEdit> {
  return decided(parseReviewEdit(value));
}

/** The canonical encoding of a review edit. The occurrence is canonical decimal text. @public */
export function encodeReviewEdit(edit: ReviewEdit): JsonValue {
  return edit.operation === "drop"
    ? { operation: "drop", occurrenceId: edit.occurrenceId.toString() }
    : { operation: "replace", occurrenceId: edit.occurrenceId.toString(), sha256: edit.sha256 };
}

/** Decode a review lineage, or refuse with `InvalidResponse`. @public */
export function decodeReviewLineage(value: JsonValue): Outcome<ReviewLineage> {
  return decided(parseReviewLineage(value));
}

/** The canonical encoding of a review lineage. @public */
export function encodeReviewLineage(lineage: ReviewLineage): JsonValue {
  return { parentRunId: lineage.parentRunId, operation: lineage.operation, edits: lineage.edits.map(encodeReviewEdit) };
}

/**
 * Decode a review, or refuse with `InvalidResponse`. A missing lineage is a
 * root review, and a null lineage refuses.
 *
 * @public
 */
export function decodeReview(value: JsonValue): Outcome<Review> {
  return decided(parseReview(value));
}

/** The canonical encoding of a review. A root review has no lineage member. @public */
export function encodeReview(review: Review): JsonValue {
  const encoded: Record<string, JsonValue> = {
    programHash: review.programHash,
    personAnswering: review.personAnswering,
    policy: review.policy,
    workflowId: review.workflowId,
    profileId: review.profileId,
    workspaceLabel: review.workspaceLabel,
    targetLabel: review.targetLabel,
    inputs: review.inputs.map(encodeReviewInput),
    plan: review.plan,
    runFacts: [...review.runFacts],
    pins: [...review.pins],
    warnings: [...review.warnings],
    resultCode: review.resultCode,
  };
  if (review.lineage !== null) encoded.lineage = encodeReviewLineage(review.lineage);
  return encoded;
}

/** Decode a preparation, or refuse with `InvalidResponse`. @public */
export function decodePreparation(value: JsonValue): Outcome<Preparation> {
  return decided(parsePreparation(value));
}

/** The canonical encoding of a preparation. @public */
export function encodePreparation(preparation: Preparation): JsonValue {
  return {
    version: new JsonNumber("1"),
    id: preparation.id,
    revision: preparation.revision,
    requestId: preparation.requestId,
    requestRevision: preparation.requestRevision,
    profileId: preparation.profileId,
    profileRevision: preparation.profileRevision,
    descriptorRevision: preparation.descriptorRevision,
    state: preparation.state,
    expiresAt: preparation.expiresAt,
    reviewDigest: preparation.reviewDigest,
    processGeneration: preparation.processGeneration,
    review: encodeReview(preparation.review),
    reason: preparation.reason,
  };
}

// ---------------------------------------------------------------------------
// Command receipts (Agentic.Manager.Protocol.Command).

/** The frozen command operations. @public */
export const OPERATIONS = [
  "create", "capture", "set-input", "remove-input", "enqueue", "withdraw", "approve", "discard", "cancel", "steer", "retry",
  "choose-recovery", "redirect", "answer", "export", "restart", "resume", "fork",
] as const;
/** @public */
export type Operation = (typeof OPERATIONS)[number];

/** The profile scopes that an operation requires, in their fixed order. @public */
export function requiredScopes(operation: Operation): readonly string[] {
  switch (operation) {
    case "create": case "capture": case "set-input": case "remove-input": case "enqueue": case "withdraw":
      return ["submit"];
    case "approve": case "discard":
      return ["submit", "control"];
    case "cancel": case "steer": case "retry": case "choose-recovery": case "redirect": case "answer":
      return ["control"];
    case "export":
      return ["observe", "export"];
    case "restart": case "resume": case "fork":
      return ["observe", "submit"];
  }
}

/** The refusal codes of a refused receipt. @public */
export const RECEIPT_REFUSALS = [
  "state-conflict", "stale-revision", "unsupported-operation", "ownership-unavailable", "supervision-unavailable",
  "invalid-answer", "invalid-lineage-edit", "export-conflict", "storage-unavailable",
] as const;
/** @public */
export type ReceiptRefusal = (typeof RECEIPT_REFUSALS)[number];

/**
 * The frozen projection of one command receipt. The acknowledgement and the
 * effect are kept as their validated JSON values. Accepted intent is not an
 * attempted or acknowledged delivery.
 *
 * @public
 */
export type CommandReceipt = {
  readonly id: string;
  readonly profileId: string;
  readonly operation: Operation;
  readonly resource: string;
  readonly state: CommandState;
  readonly acceptedAt: string;
  readonly dispatchAttemptedAt: string | null;
  readonly acknowledgement: JsonValue | null;
  readonly effect: JsonValue | null;
  readonly refusal: ReceiptRefusal | null;
};

/** A missing member refuses, null passes, and text must be a canonical decimal of the bounds. */
function optionalDecimal(value: JsonValue | undefined, digits: number, maximum: bigint): boolean {
  return value === null || (typeof value === "string" && canonicalDecimal(value, digits, maximum) !== undefined);
}

function requiredDecimal(value: JsonValue | undefined, digits: number, maximum: bigint): boolean {
  return typeof value === "string" && canonicalDecimal(value, digits, maximum) !== undefined;
}

const WORD32_MAX = 4294967295n;

/** The UTF-8 size of the compact encoding, which bounds an acknowledgement and an effect. */
function encodedBytes(value: JsonValue): number {
  return Buffer.byteLength(encodeJson(value), "utf8");
}

const ACKNOWLEDGEMENT_STATES = ["accepted", "queued", "delivered", "rejected-stale", "unsupported", "failed"] as const;
const ACKNOWLEDGED_COMMANDS = ["cancel", "steer", "retry", "choose-recovery", "redirect", "answer"] as const;

function validAcknowledgement(value: JsonValue): boolean {
  const fields = exact(value, ["commandId", "state", "message", "command", "occurrenceId", "attemptId"]);
  if (fields === undefined) return false;
  const commandId = textOf(jsonMember(fields, "commandId"));
  const command = nullable(jsonMember(fields, "command"), (name) => oneOf(name, ACKNOWLEDGED_COMMANDS));
  const occurrence = jsonMember(fields, "occurrenceId");
  const attempt = jsonMember(fields, "attemptId");
  const message = textOf(jsonMember(fields, "message"));
  return commandId !== undefined && validId(commandId) && oneOf(jsonMember(fields, "state"), ACKNOWLEDGEMENT_STATES) !== undefined
    && message !== undefined && textLength(message) <= 4096 && command !== undefined
    && optionalDecimal(occurrence, 20, WORD64_MAX) && optionalDecimal(attempt, 10, WORD32_MAX)
    && (attempt === null || occurrence !== null)
    && (command !== "answer" || (occurrence !== null && attempt === null))
    && encodedBytes(value) <= 32768;
}

const EFFECT_KINDS = [
  "started", "cancelled", "steered", "retried", "recovery-chosen", "redirected", "answer-accepted", "input-changed", "enqueued",
  "withdrawn", "discarded", "exported", "lineage-created",
] as const;

function validEffect(value: JsonValue): boolean {
  const fields = exact(value, ["kind", "runtimeSequence", "address", "resource"]);
  if (fields === undefined) return false;
  const resource = textOf(jsonMember(fields, "resource"));
  const address = jsonMember(fields, "address");
  let addressValid = address === null;
  if (address !== undefined && address !== null && isJsonObject(address)) {
    const withAttempt = Object.hasOwn(address, "attemptId");
    const shaped = exact(address, withAttempt ? ["occurrenceId", "attemptId"] : ["occurrenceId"]);
    addressValid = shaped !== undefined && requiredDecimal(jsonMember(shaped, "occurrenceId"), 20, WORD64_MAX)
      && (!withAttempt || requiredDecimal(jsonMember(shaped, "attemptId"), 10, WORD32_MAX));
  }
  return oneOf(jsonMember(fields, "kind"), EFFECT_KINDS) !== undefined
    && optionalDecimal(jsonMember(fields, "runtimeSequence"), 20, WORD64_MAX)
    && resource !== undefined && validResource(resource) && addressValid && encodedBytes(value) <= 16384;
}

function parseCommandReceipt(value: JsonValue): CommandReceipt | undefined {
  const fields = exact(value, [
    "version", "id", "profileId", "operation", "requiredScopes", "resource", "state", "acceptedAt", "dispatchAttemptedAt",
    "acknowledgement", "effect", "refusal", "links",
  ]);
  if (fields === undefined || !versionOne(fields)) return undefined;
  const id = textOf(jsonMember(fields, "id"));
  const profileId = textOf(jsonMember(fields, "profileId"));
  const operation = oneOf(jsonMember(fields, "operation"), OPERATIONS);
  const resource = textOf(jsonMember(fields, "resource"));
  const state = oneOf(jsonMember(fields, "state"), COMMAND_STATES);
  const acceptedAt = textOf(jsonMember(fields, "acceptedAt"));
  const dispatchAttemptedAt = nullable(jsonMember(fields, "dispatchAttemptedAt"), textOf);
  const acknowledgement = nullable(jsonMember(fields, "acknowledgement"), (ack) => (validAcknowledgement(ack) ? ack : undefined));
  const effect = nullable(jsonMember(fields, "effect"), (evidence) => (validEffect(evidence) ? evidence : undefined));
  const refusal = nullable(jsonMember(fields, "refusal"), (code) => oneOf(code, RECEIPT_REFUSALS));
  if (id === undefined || !validId(id) || profileId === undefined || !validId(profileId) || operation === undefined
    || resource === undefined || !validResource(resource) || state === undefined || acceptedAt === undefined
    || !validTimestamp(acceptedAt) || dispatchAttemptedAt === undefined
    || (dispatchAttemptedAt !== null && !validTimestamp(dispatchAttemptedAt))
    || acknowledgement === undefined || effect === undefined || refusal === undefined) {
    return undefined;
  }
  const scopes = jsonMember(fields, "requiredScopes");
  if (scopes === undefined || !jsonEqual(scopes, [...requiredScopes(operation)])) return undefined;
  const links = exact(jsonMember(fields, "links"), ["self", "resource"]);
  if (links === undefined || jsonMember(links, "self") !== `/v1/commands/${id}` || jsonMember(links, "resource") !== resource) {
    return undefined;
  }
  const attempted = dispatchAttemptedAt !== null;
  const acknowledged = acknowledgement !== null;
  const observed = effect !== null;
  const refused = refusal !== null;
  const consistent = {
    "accepted": !attempted && !acknowledged && !observed && !refused,
    "dispatch-attempted": attempted && !acknowledged && !observed && !refused,
    "acknowledged": attempted && acknowledged && !observed && !refused,
    "effect-observed": observed && !refused,
    "refused": refused && !observed,
    "unresolved": !observed && !refused,
  }[state];
  return consistent
    ? { id, profileId, operation, resource, state, acceptedAt, dispatchAttemptedAt, acknowledgement, effect, refusal }
    : undefined;
}

/**
 * Decode a command receipt, or refuse with `InvalidResponse`. The required
 * scopes and the links must agree with the operation, the identity and the
 * resource, and the timestamps, acknowledgement, effect and refusal must
 * agree with the state.
 *
 * @public
 */
export function decodeCommandReceipt(value: JsonValue): Outcome<CommandReceipt> {
  return decided(parseCommandReceipt(value));
}

/** The canonical encoding of a command receipt. @public */
export function encodeCommandReceipt(receipt: CommandReceipt): JsonValue {
  return {
    version: new JsonNumber("1"),
    id: receipt.id,
    profileId: receipt.profileId,
    operation: receipt.operation,
    requiredScopes: [...requiredScopes(receipt.operation)],
    resource: receipt.resource,
    state: receipt.state,
    acceptedAt: receipt.acceptedAt,
    dispatchAttemptedAt: receipt.dispatchAttemptedAt,
    acknowledgement: receipt.acknowledgement,
    effect: receipt.effect,
    refusal: receipt.refusal,
    links: { self: `/v1/commands/${receipt.id}`, resource: receipt.resource },
  };
}

// ---------------------------------------------------------------------------
// Service readers of Agentic.Tui.Service: identifiers, links and decimals.

function identifier(value: JsonValue | undefined): string | undefined {
  return typeof value === "string" && validId(value) ? value : undefined;
}

/** A resource link: 4 to 8192 characters below `/v1/` of letters, digits and `_/?=&.%-`. */
function resourceLink(value: JsonValue | undefined): string | undefined {
  return typeof value === "string" && bounded(value, 4, 8192) && value.startsWith("/v1/") && /^[A-Za-z0-9_/?=&.%-]*$/.test(value)
    ? value : undefined;
}

/** A canonical natural decimal text of 1 to 4096 digits. */
function natural(value: JsonValue | undefined): bigint | undefined {
  return typeof value === "string" ? canonicalDecimal(value, 4096) : undefined;
}

/** A canonical unsigned 64-bit decimal text of 1 to 20 digits. */
function uint64(value: JsonValue | undefined): bigint | undefined {
  return typeof value === "string" ? canonicalDecimal(value, 20, WORD64_MAX) : undefined;
}

/** A canonical unsigned 32-bit decimal text of 1 to 10 digits. */
function uint32(value: JsonValue | undefined): bigint | undefined {
  return typeof value === "string" ? canonicalDecimal(value, 10, WORD32_MAX) : undefined;
}

function occurrenceAddress(value: JsonValue | undefined): bigint | undefined {
  const fields = exact(value, ["occurrenceId"]);
  return fields === undefined ? undefined : uint64(jsonMember(fields, "occurrenceId"));
}

function attemptAddress(value: JsonValue | undefined): { occurrenceId: bigint; attemptId: bigint } | undefined {
  const fields = exact(value, ["occurrenceId", "attemptId"]);
  if (fields === undefined) return undefined;
  const occurrenceId = uint64(jsonMember(fields, "occurrenceId"));
  const attemptId = uint32(jsonMember(fields, "attemptId"));
  return occurrenceId === undefined || attemptId === undefined ? undefined : { occurrenceId, attemptId };
}

/** @public */
export const SUPERVISION_STATES = ["owned", "cleanup-pending", "lost", "observer"] as const;
/** @public */
export type SupervisionState = (typeof SUPERVISION_STATES)[number];

// ---------------------------------------------------------------------------
// Decisions and controls.

/**
 * One recovery choice. Only a failover names a target.
 *
 * @public
 */
export type RecoveryOption = { readonly choice: "retry" | "failover" | "abandon"; readonly target: string | null };

/**
 * The editor schema of a question in the frozen editor vocabulary: a
 * primitive type, an array of one item schema, or a closed object whose
 * properties are all required.
 *
 * @public
 */
export type EditorSchema =
  | { readonly type: "null" | "boolean" | "integer" | "number" | "string" }
  | { readonly type: "array"; readonly items: EditorSchema }
  | { readonly type: "object"; readonly properties: ReadonlyMap<string, EditorSchema> };

/**
 * The content of a decision. A question carries its observation code, its
 * editor schema when the manager gives one, and its prompt.
 *
 * @public
 */
export type DecisionContent =
  | { readonly kind: "question"; readonly code: JsonValue; readonly editor: EditorSchema | null; readonly prompt: string }
  | { readonly kind: "recovery"; readonly gap: string; readonly message: string; readonly choices: readonly RecoveryOption[] };

/** @public */
export const DECISION_STATES = ["pending", "submitting", "resolved", "invalidated"] as const;
/** @public */
export type DecisionState = (typeof DECISION_STATES)[number];

/**
 * One decision. `value` is the exact JSON value that was decoded.
 *
 * @public
 */
export type DecisionView = {
  readonly id: string;
  readonly revision: string;
  readonly runId: string;
  readonly profileId: string;
  readonly generation: string;
  readonly occurrenceId: bigint;
  readonly state: DecisionState;
  readonly position: number;
  readonly observedSequence: bigint;
  readonly content: DecisionContent;
  readonly value: JsonValue;
};

/** @public */
export const OFFER_OPERATIONS = ["steer", "retry", "choose-recovery", "redirect", "answer"] as const;
/** @public */
export type OfferOperation = (typeof OFFER_OPERATIONS)[number];

/**
 * One published control offer. A steer offer addresses an attempt, and every
 * other offer addresses an occurrence.
 *
 * @public
 */
export type ControlOffer = {
  readonly operation: OfferOperation;
  readonly occurrenceId: bigint;
  readonly attemptId: bigint | null;
  readonly generation: string | null;
  readonly timings: readonly ("interrupt-now" | "next-boundary")[];
  readonly choices: readonly RecoveryOption[];
  readonly targets: readonly string[];
};

/**
 * The published controls of one run. `value` is the exact JSON value that
 * was decoded. An offer is not ownership.
 *
 * @public
 */
export type ControlView = {
  readonly runId: string;
  readonly revision: string;
  readonly supervision: SupervisionState;
  readonly cancelAllowed: boolean;
  readonly decisionHeadId: string | null;
  readonly offers: readonly ControlOffer[];
  readonly value: JsonValue;
};

function parseRecoveryOption(value: JsonValue): RecoveryOption | undefined {
  const fields = exact(value, ["choice", "target"]);
  if (fields === undefined) return undefined;
  const choice = oneOf(jsonMember(fields, "choice"), ["retry", "failover", "abandon"] as const);
  const target = nullable(jsonMember(fields, "target"), (text) => boundedText(text, 0, 1024));
  return choice === undefined || target === undefined || (choice !== "failover" && target !== null) ? undefined : { choice, target };
}

const EDITOR_TYPES = ["null", "boolean", "integer", "number", "string", "array", "object"] as const;

function parseEditorSchema(value: JsonValue, depth: number): EditorSchema | undefined {
  if (!isJsonObject(value) || depth >= 64) return undefined;
  const type = oneOf(jsonMember(value, "type"), EDITOR_TYPES);
  if (type === undefined) return undefined;
  if (type === "array") {
    const fields = exact(value, ["type", "items"]);
    const items = fields === undefined ? undefined : jsonMember(fields, "items");
    const item = items === undefined ? undefined : parseEditorSchema(items, depth + 1);
    return item === undefined ? undefined : { type, items: item };
  }
  if (type === "object") {
    const fields = exact(value, ["type", "properties", "required", "additionalProperties"]);
    const properties = fields === undefined ? undefined : jsonMember(fields, "properties");
    if (fields === undefined || properties === undefined || !isJsonObject(properties)) return undefined;
    const names = Object.keys(properties);
    if (names.length > 256 || !names.every((name) => bounded(name, 0, 1024))) return undefined;
    const schemas = new Map<string, EditorSchema>();
    for (const name of [...names].sort()) {
      const property = jsonMember(properties, name);
      const schema = property === undefined ? undefined : parseEditorSchema(property, depth + 1);
      if (schema === undefined) return undefined;
      schemas.set(name, schema);
    }
    const required = listOf(jsonMember(fields, "required"), (name) => boundedText(name, 0, 1024), 256);
    const additional = boolOf(jsonMember(fields, "additionalProperties"));
    if (required === undefined || !unique(required) || additional !== false) return undefined;
    const requested = new Set(required);
    return requested.size === schemas.size && [...schemas.keys()].every((name) => requested.has(name))
      ? { type, properties: schemas } : undefined;
  }
  return exact(value, ["type"]) === undefined ? undefined : { type };
}

function parseQuestion(value: JsonValue | undefined): DecisionContent | undefined {
  const fields = exact(value, ["code", "semanticSchema", "editorSchema", "addressee", "scope", "draw", "prompt"]);
  if (fields === undefined) return undefined;
  const code = observationCode(jsonMember(fields, "code"), DECISION_DEPTH);
  const schema = jsonMember(fields, "semanticSchema");
  if (code === undefined || schema === undefined || (schema !== null && !semanticSchema(schema, 0, DECISION_DEPTH))) return undefined;
  if (isJsonObject(code)) {
    const structured = jsonMember(code, "json");
    const stated = structured !== undefined && isJsonObject(structured) ? jsonMember(structured, "schema") : undefined;
    if (structured !== undefined && isJsonObject(structured) && (stated === undefined || !jsonEqual(stated, schema))) return undefined;
  }
  const editor = nullable(jsonMember(fields, "editorSchema"), (editorValue) => parseEditorSchema(editorValue, 0));
  const scope = exact(jsonMember(fields, "scope"), ["model", "mode"]);
  const scoped = scope !== undefined
    && nullable(jsonMember(scope, "model"), (text) => boundedText(text, 0, 1024)) !== undefined
    && nullable(jsonMember(scope, "mode"), (text) => boundedText(text, 0, 1024)) !== undefined;
  const prompt = boundedText(jsonMember(fields, "prompt"), 0, 524288);
  return editor === undefined || boundedText(jsonMember(fields, "addressee"), 0, 1024) === undefined || !scoped
    || natural(jsonMember(fields, "draw")) === undefined || prompt === undefined
    ? undefined : { kind: "question", code, editor, prompt };
}

const DECISION_FIELDS = [
  "version", "id", "revision", "runId", "profileId", "generation", "address", "state", "position", "observedSequence", "queue", "kind",
] as const;

function parseDecision(value: JsonValue): DecisionView | undefined {
  if (!isJsonObject(value)) return undefined;
  const kind = oneOf(jsonMember(value, "kind"), ["question", "recovery"] as const);
  if (kind === undefined) return undefined;
  const fields = exact(value, [...DECISION_FIELDS, ...(kind === "question" ? ["question"] : ["gap", "message", "choices"])]);
  if (fields === undefined || !versionOne(fields)) return undefined;
  const runId = identifier(jsonMember(fields, "runId"));
  const queue = resourceLink(jsonMember(fields, "queue"));
  const position = intOf(jsonMember(fields, "position"));
  if (runId === undefined || queue !== `/v1/decisions?runId=${runId}` || position === undefined || position < 0 || position > 2047) {
    return undefined;
  }
  let content: DecisionContent | undefined;
  if (kind === "question") {
    content = parseQuestion(jsonMember(fields, "question"));
  } else {
    const gap = boundedText(jsonMember(fields, "gap"), 0, 4096);
    const message = boundedText(jsonMember(fields, "message"), 0, 4096);
    const choices = listOf(jsonMember(fields, "choices"), parseRecoveryOption, 16);
    content = gap === undefined || message === undefined || choices === undefined ? undefined : { kind, gap, message, choices };
  }
  const id = identifier(jsonMember(fields, "id"));
  const revision = identifier(jsonMember(fields, "revision"));
  const profileId = identifier(jsonMember(fields, "profileId"));
  const generation = identifier(jsonMember(fields, "generation"));
  const occurrenceId = occurrenceAddress(jsonMember(fields, "address"));
  const state = oneOf(jsonMember(fields, "state"), DECISION_STATES);
  const observedSequence = uint64(jsonMember(fields, "observedSequence"));
  return content === undefined || id === undefined || revision === undefined || profileId === undefined || generation === undefined
    || occurrenceId === undefined || state === undefined || observedSequence === undefined
    ? undefined
    : { id, revision, runId, profileId, generation, occurrenceId, state, position, observedSequence, content, value };
}

function parseOffer(value: JsonValue): ControlOffer | undefined {
  const fields = exact(value, ["operation", "address", "generation", "timings", "choices", "targets"]);
  if (fields === undefined) return undefined;
  const operation = oneOf(jsonMember(fields, "operation"), OFFER_OPERATIONS);
  if (operation === undefined) return undefined;
  const address = operation === "steer"
    ? attemptAddress(jsonMember(fields, "address"))
    : (() => {
      const occurrenceId = occurrenceAddress(jsonMember(fields, "address"));
      return occurrenceId === undefined ? undefined : { occurrenceId, attemptId: null };
    })();
  const timings = listOf(jsonMember(fields, "timings"), (timing) => oneOf(timing, ["interrupt-now", "next-boundary"] as const), 2);
  const generation = nullable(jsonMember(fields, "generation"), identifier);
  const choices = listOf(jsonMember(fields, "choices"), parseRecoveryOption, 16);
  const targets = listOf(jsonMember(fields, "targets"), (target) => boundedText(target, 0, 1024), 256);
  return address === undefined || timings === undefined || !unique(timings) || generation === undefined || choices === undefined
    || targets === undefined
    ? undefined
    : { operation, occurrenceId: address.occurrenceId, attemptId: address.attemptId, generation, timings, choices, targets };
}

function parseControl(value: JsonValue): ControlView | undefined {
  const fields = exact(value, ["version", "runId", "revision", "supervision", "cancelAllowed", "offers", "decisionHeadId"]);
  if (fields === undefined || !versionOne(fields)) return undefined;
  const runId = identifier(jsonMember(fields, "runId"));
  const revision = identifier(jsonMember(fields, "revision"));
  const supervision = oneOf(jsonMember(fields, "supervision"), SUPERVISION_STATES);
  const cancelAllowed = boolOf(jsonMember(fields, "cancelAllowed"));
  const decisionHeadId = nullable(jsonMember(fields, "decisionHeadId"), identifier);
  const offers = listOf(jsonMember(fields, "offers"), parseOffer, 512);
  return runId === undefined || revision === undefined || supervision === undefined || cancelAllowed === undefined
    || decisionHeadId === undefined || offers === undefined
    ? undefined : { runId, revision, supervision, cancelAllowed, decisionHeadId, offers, value };
}

/**
 * Decode a decision, or refuse with `InvalidResponse`. The view keeps the
 * exact JSON value that it decodes.
 *
 * @public
 */
export function decodeDecision(value: JsonValue): Outcome<DecisionView> {
  return decided(parseDecision(value));
}

/**
 * Decode the controls of a run, or refuse with `InvalidResponse`. The view
 * keeps the exact JSON value that it decodes.
 *
 * @public
 */
export function decodeControl(value: JsonValue): Outcome<ControlView> {
  return decided(parseControl(value));
}

// ---------------------------------------------------------------------------
// Runs and overview members.

/** @public */
export const RUN_STATUSES = ["starting", "running", "cancelling", "succeeded", "failed", "cancelled", "orphaned"] as const;
/** @public */
export type RunStatus = (typeof RUN_STATUSES)[number];
/** @public */
export const UNREADABLE_CATEGORIES = ["manifest-unavailable", "malformed-manifest", "unsupported-manifest"] as const;
/** @public */
export const RUN_INTEGRITIES = ["valid", "corrupt", "incomplete", "unknown"] as const;
/** @public */
export const RUN_LIMITATIONS = [
  "legacy", "foreign-owner", "corrupt-journal", "incompatible-invocation", "quarantined", "lost-supervision",
] as const;
/** @public */
export const UNAVAILABLE_REASONS = ["missing", "corrupt", "unsupported-version", "size-limit", "ownership-unavailable"] as const;

/**
 * The verification of the result of a run.
 *
 * @public
 */
export type Verification =
  | { readonly state: "absent" }
  | { readonly state: "referenced" | "verified"; readonly artifactId: string }
  | { readonly state: "unavailable"; readonly artifactId: string | null; readonly reason: (typeof UNAVAILABLE_REASONS)[number] };

/**
 * The runtime summary of a run: its status, its last sequence and its
 * protocol version. It is absent without validated native evidence.
 *
 * @public
 */
export type RunRuntime = { readonly status: RunStatus; readonly lastSequence: bigint; readonly protocolVersion: number };

/**
 * A run whose manifest the manager read, or a retained catalogue entry whose
 * manifest it could not read, with only its public category. A null manifest
 * version is a legacy manifest.
 *
 * @public
 */
export type RunContent =
  | { readonly kind: "unreadable"; readonly category: (typeof UNREADABLE_CATEGORIES)[number] }
  | {
    readonly kind: "known";
    readonly workflowId: string;
    readonly requestId: string | null;
    readonly parentRunId: string | null;
    readonly lineage: LineageOperation | null;
    readonly manifestVersion: number | null;
    readonly runtime: RunRuntime | null;
    readonly supervision: SupervisionState;
    readonly integrity: (typeof RUN_INTEGRITIES)[number];
    readonly verification: Verification;
    readonly limitations: readonly (typeof RUN_LIMITATIONS)[number][];
  };

/**
 * One item of the run collection, or the run of one overview member. It is
 * display data and grants no supervision, control or signalling authority.
 *
 * @public
 */
export type RunItem = { readonly id: string; readonly revision: string; readonly profileId: string; readonly content: RunContent };

/**
 * One member of the overview page set, tagged by its kind.
 *
 * @public
 */
export type OverviewMember =
  | { readonly kind: "request"; readonly request: DraftView }
  | { readonly kind: "preparation"; readonly preparation: Preparation }
  | { readonly kind: "run"; readonly run: RunItem }
  | { readonly kind: "decision"; readonly decision: DecisionView };

function linksAgree(value: JsonValue | undefined, expected: readonly (readonly [string, string])[]): boolean {
  const fields = exact(value, expected.map(([name]) => name));
  return fields !== undefined && expected.every(([name, uri]) => resourceLink(jsonMember(fields, name)) === uri);
}

function parseVerification(value: JsonValue | undefined): Verification | undefined {
  if (value === undefined || !isJsonObject(value)) return undefined;
  const state = oneOf(jsonMember(value, "state"), ["absent", "referenced", "verified", "unavailable"] as const);
  if (state === undefined) return undefined;
  if (state === "absent") return exact(value, ["state"]) === undefined ? undefined : { state };
  if (state === "referenced" || state === "verified") {
    const artifactId = exact(value, ["state", "artifactId"]) === undefined ? undefined : identifier(jsonMember(value, "artifactId"));
    return artifactId === undefined ? undefined : { state, artifactId };
  }
  if (exact(value, ["state", "artifactId", "reason"]) === undefined) return undefined;
  const artifactId = nullable(jsonMember(value, "artifactId"), identifier);
  const reason = oneOf(jsonMember(value, "reason"), UNAVAILABLE_REASONS);
  return artifactId === undefined || reason === undefined ? undefined : { state, artifactId, reason };
}

function parseRuntime(value: JsonValue): RunRuntime | undefined {
  const fields = exact(value, ["status", "lastSequence", "protocolVersion"]);
  if (fields === undefined) return undefined;
  const status = oneOf(jsonMember(fields, "status"), RUN_STATUSES);
  const lastSequence = uint64(jsonMember(fields, "lastSequence"));
  const protocolVersion = intOf(jsonMember(fields, "protocolVersion"));
  return status === undefined || lastSequence === undefined || protocolVersion === undefined || ![1, 2, 3].includes(protocolVersion)
    ? undefined : { status, lastSequence, protocolVersion };
}

/** The frontend manifest version of a versioned manifest, `null` for a legacy manifest, or `undefined`. */
function parseManifest(value: JsonValue | undefined): number | null | undefined {
  if (value === undefined || !isJsonObject(value)) return undefined;
  const kind = oneOf(jsonMember(value, "kind"), ["legacy", "versioned"] as const);
  if (kind === "legacy") return exact(value, ["kind"]) === undefined ? undefined : null;
  if (kind === undefined || exact(value, ["kind", "frontendManifestVersion"]) === undefined) return undefined;
  const version = intOf(jsonMember(value, "frontendManifestVersion"));
  return version === 2 || version === 3 ? version : undefined;
}

const KNOWN_RUN_FIELDS = [
  "version", "id", "revision", "profileId", "workflowId", "requestId", "parentRunId", "lineage", "manifest", "runtime",
  "supervision", "integrity", "verification", "limitations", "links",
] as const;

function parseRunContent(fields: JsonObject, self: string): RunContent | undefined {
  if (Object.hasOwn(fields, "kind")) {
    if (exact(fields, ["version", "kind", "id", "revision", "profileId", "category", "links"]) === undefined
      || oneOf(jsonMember(fields, "kind"), ["unreadable-manifest"] as const) === undefined
      || !linksAgree(jsonMember(fields, "links"), [["self", self]])) {
      return undefined;
    }
    const category = oneOf(jsonMember(fields, "category"), UNREADABLE_CATEGORIES);
    return category === undefined ? undefined : { kind: "unreadable", category };
  }
  if (exact(fields, KNOWN_RUN_FIELDS) === undefined) return undefined;
  const links: readonly (readonly [string, string])[] = [
    ["self", self], ["snapshot", `${self}/snapshot`], ["control", `${self}/control`], ["outputs", `${self}/outputs`],
    ["exports", `${self}/exports`], ["lineageRequests", `${self}/lineage-requests`],
  ];
  if (!linksAgree(jsonMember(fields, "links"), links)) return undefined;
  const workflowId = identifier(jsonMember(fields, "workflowId"));
  const requestId = nullable(jsonMember(fields, "requestId"), identifier);
  const parentRunId = nullable(jsonMember(fields, "parentRunId"), identifier);
  const lineage = nullable(jsonMember(fields, "lineage"), (operation) => oneOf(operation, LINEAGE_OPERATIONS));
  const manifestVersion = parseManifest(jsonMember(fields, "manifest"));
  const runtime = nullable(jsonMember(fields, "runtime"), parseRuntime);
  const supervision = oneOf(jsonMember(fields, "supervision"), SUPERVISION_STATES);
  const integrity = oneOf(jsonMember(fields, "integrity"), RUN_INTEGRITIES);
  const verification = parseVerification(jsonMember(fields, "verification"));
  const limitations = listOf(jsonMember(fields, "limitations"), (limitation) => oneOf(limitation, RUN_LIMITATIONS), 6);
  return workflowId === undefined || requestId === undefined || parentRunId === undefined || lineage === undefined
    || manifestVersion === undefined || runtime === undefined || supervision === undefined || integrity === undefined
    || verification === undefined || limitations === undefined || !unique(limitations)
    ? undefined
    : {
      kind: "known", workflowId, requestId, parentRunId, lineage, manifestVersion, runtime, supervision, integrity, verification,
      limitations,
    };
}

function parseRunItem(value: JsonValue): RunItem | undefined {
  if (!isJsonObject(value) || !versionOne(value)) return undefined;
  const id = identifier(jsonMember(value, "id"));
  if (id === undefined) return undefined;
  const content = parseRunContent(value, `/v1/runs/${id}`);
  const revision = identifier(jsonMember(value, "revision"));
  const profileId = identifier(jsonMember(value, "profileId"));
  return content === undefined || revision === undefined || profileId === undefined ? undefined : { id, revision, profileId, content };
}

const OVERVIEW_KINDS = ["request", "preparation", "run", "decision"] as const;

function parseOverviewMember(value: JsonValue): OverviewMember | undefined {
  if (!isJsonObject(value)) return undefined;
  const kind = oneOf(jsonMember(value, "kind"), OVERVIEW_KINDS);
  const fields = kind === undefined ? undefined : exact(value, ["kind", kind]);
  const member = fields === undefined || kind === undefined ? undefined : jsonMember(fields, kind);
  if (member === undefined) return undefined;
  switch (kind) {
    case "request": {
      const request = parseDraftView(member);
      return request === undefined ? undefined : { kind, request };
    }
    case "preparation": {
      const preparation = parsePreparation(member);
      return preparation === undefined ? undefined : { kind, preparation };
    }
    case "run": {
      const run = parseRunItem(member);
      return run === undefined ? undefined : { kind, run };
    }
    case "decision": {
      const decision = parseDecision(member);
      return decision === undefined ? undefined : { kind, decision };
    }
    default:
      return undefined;
  }
}

/** Decode one item of the run collection, or refuse with `InvalidResponse`. @public */
export function decodeRunItem(value: JsonValue): Outcome<RunItem> {
  return decided(parseRunItem(value));
}

/**
 * Decode one member of the overview page set, `{"kind":K,K:member}`, by its
 * kind, or refuse with `InvalidResponse`.
 *
 * @public
 */
export function decodeOverviewMember(value: JsonValue): Outcome<OverviewMember> {
  return decided(parseOverviewMember(value));
}

// ---------------------------------------------------------------------------
// Projections of the decoded fields. A UInt64 or UInt32 value is canonical
// decimal text, and an absent optional value is null.

function decimalText(value: bigint): string {
  return value.toString();
}

function integerNumber(value: number): JsonNumber {
  return JsonNumber.ofBigInt(BigInt(value));
}

function choiceProjection(option: RecoveryOption): JsonValue {
  return { choice: option.choice, target: option.target };
}

/** The projection of the decoded fields of a decision. @public */
export function decisionProjection(view: DecisionView): JsonValue {
  const content: JsonValue = view.content.kind === "question"
    ? { kind: "question", code: view.content.code, prompt: view.content.prompt }
    : { kind: "recovery", gap: view.content.gap, message: view.content.message, choices: view.content.choices.map(choiceProjection) };
  return {
    id: view.id,
    revision: view.revision,
    runId: view.runId,
    profileId: view.profileId,
    generation: view.generation,
    occurrenceId: decimalText(view.occurrenceId),
    state: view.state,
    position: integerNumber(view.position),
    observedSequence: decimalText(view.observedSequence),
    content,
  };
}

function offerProjection(offer: ControlOffer): JsonValue {
  return {
    operation: offer.operation,
    occurrenceId: decimalText(offer.occurrenceId),
    attemptId: offer.attemptId === null ? null : decimalText(offer.attemptId),
    generation: offer.generation,
    timings: [...offer.timings],
    choices: offer.choices.map(choiceProjection),
    targets: [...offer.targets],
  };
}

/** The projection of the decoded fields of the controls of a run. @public */
export function controlProjection(view: ControlView): JsonValue {
  return {
    runId: view.runId,
    revision: view.revision,
    supervision: view.supervision,
    cancelAllowed: view.cancelAllowed,
    decisionHeadId: view.decisionHeadId,
    offers: view.offers.map(offerProjection),
  };
}

function verificationProjection(verification: Verification): JsonValue {
  switch (verification.state) {
    case "absent":
      return { state: "absent" };
    case "referenced":
    case "verified":
      return { state: verification.state, artifactId: verification.artifactId };
    case "unavailable":
      return { state: "unavailable", artifactId: verification.artifactId, reason: verification.reason };
  }
}

/** The projection of the decoded fields of a run item, with the runtime status as its text. @public */
export function runProjection(item: RunItem): JsonValue {
  const content = item.content;
  return {
    id: item.id,
    revision: item.revision,
    profileId: item.profileId,
    content: content.kind === "unreadable"
      ? { kind: "unreadable", category: content.category }
      : {
        kind: "known",
        workflowId: content.workflowId,
        requestId: content.requestId,
        parentRunId: content.parentRunId,
        lineage: content.lineage,
        manifestVersion: content.manifestVersion === null ? null : integerNumber(content.manifestVersion),
        runtime: content.runtime === null ? null : {
          status: content.runtime.status,
          lastSequence: decimalText(content.runtime.lastSequence),
          protocolVersion: integerNumber(content.runtime.protocolVersion),
        },
        supervision: content.supervision,
        integrity: content.integrity,
        verification: verificationProjection(content.verification),
        limitations: [...content.limitations],
      },
  };
}

/**
 * The projection of an overview member, tagged by its kind: the canonical
 * encoding of a request or a preparation, and the projection of a run or a
 * decision.
 *
 * @public
 */
export function memberProjection(member: OverviewMember): JsonValue {
  switch (member.kind) {
    case "request":
      return { kind: "request", request: encodeDraftView(member.request) };
    case "preparation":
      return { kind: "preparation", preparation: encodePreparation(member.preparation) };
    case "run":
      return { kind: "run", run: runProjection(member.run) };
    case "decision":
      return { kind: "decision", decision: decisionProjection(member.decision) };
  }
}

// ---------------------------------------------------------------------------
// Typed answers.

/**
 * The refusal of an answer before any command is built, with a reason for
 * the operator.
 *
 * @public
 */
export type AnswerFailure = { readonly kind: "InvalidAnswer"; readonly reason: string };

/**
 * A typed answer value, or the refusal of the answer.
 *
 * @public
 */
export type AnswerOutcome = { readonly ok: true; readonly value: JsonValue } | { readonly ok: false; readonly failure: AnswerFailure };

function refuseAnswer(reason: string): AnswerOutcome {
  return { ok: false, failure: { kind: "InvalidAnswer", reason } };
}

/** The white space that Haskell `isSpace` names: tab to carriage return, and the space separators. */
const SPACE = "\\t\\n\\v\\f\\r \\u00a0\\u1680\\u2000-\\u200a\\u202f\\u205f\\u3000";
const SURROUNDING_SPACE = new RegExp(`^[${SPACE}]+|[${SPACE}]+$`, "g");

function strip(input: string): string {
  return input.replace(SURROUNDING_SPACE, "");
}

const PERSON_ANSWER_BYTES = 1024 * 1024;

function jsonAnswer(input: string): AnswerOutcome {
  if (Buffer.byteLength(input, "utf8") > PERSON_ANSWER_BYTES) return refuseAnswer(`person answer exceeds ${PERSON_ANSWER_BYTES} UTF-8 bytes`);
  const value = tryParseJson(input);
  return value === undefined ? refuseAnswer("answer is not JSON") : { ok: true, value };
}

/**
 * The JSON answer of the editor input for a question with a primitive code.
 * A flag takes yes, no, true or false in any letter case and gives JSON
 * `true` or `false`. A receipt takes empty input and gives `null`. A text
 * answer is the input itself. A verdict takes JSON text.
 */
function personAnswerValue(code: string, input: string): AnswerOutcome {
  switch (code) {
    case "text":
      return { ok: true, value: input };
    case "flag": {
      // Upper case and then lower case folds the letters of these words as full case folding does.
      const word = strip(input).toUpperCase().toLowerCase();
      if (word === "y" || word === "yes" || word === "true") return { ok: true, value: true };
      if (word === "n" || word === "no" || word === "false") return { ok: true, value: false };
      return refuseAnswer("a flag answer must be yes, no, true, or false");
    }
    case "receipt":
      return strip(input) === "" ? { ok: true, value: null } : refuseAnswer("a receipt answer must be empty");
    case "verdict":
      return jsonAnswer(input);
    default:
      return refuseAnswer(`unsupported person answer code ${code}`);
  }
}

function editorNoun(schema: EditorSchema): string {
  switch (schema.type) {
    case "null": return "null";
    case "boolean": return "a boolean";
    case "integer": return "an integer";
    case "number": return "a number";
    case "string": return "a string";
    case "array": return "an array";
    case "object": return "an object";
  }
}

/**
 * Check a JSON answer against the editor schema of its question. The reason
 * names the first field that does not agree, for example
 * `answer field ok must be a boolean`.
 */
function editorCheck(schema: EditorSchema, value: JsonValue, place = "answer"): string | undefined {
  switch (schema.type) {
    case "null":
      return value === null ? undefined : `${place} must be ${editorNoun(schema)}`;
    case "boolean":
      return typeof value === "boolean" ? undefined : `${place} must be ${editorNoun(schema)}`;
    case "integer":
      return value instanceof JsonNumber && decimalOf(value).exponent >= 0n ? undefined : `${place} must be ${editorNoun(schema)}`;
    case "number":
      return value instanceof JsonNumber ? undefined : `${place} must be ${editorNoun(schema)}`;
    case "string":
      return typeof value === "string" ? undefined : `${place} must be ${editorNoun(schema)}`;
    case "array": {
      if (!isJsonArray(value)) return `${place} must be ${editorNoun(schema)}`;
      for (const [index, item] of value.entries()) {
        const problem = editorCheck(schema.items, item, `${place} item ${index}`);
        if (problem !== undefined) return problem;
      }
      return undefined;
    }
    case "object": {
      if (!isJsonObject(value)) return `${place} must be ${editorNoun(schema)}`;
      const given = Object.keys(value).sort();
      const lacking = [...schema.properties.keys()].find((name) => !Object.hasOwn(value, name));
      if (lacking !== undefined) return `${place} lacks the field ${lacking}`;
      const unknown = given.find((name) => !schema.properties.has(name));
      if (unknown !== undefined) return `${place} has the unknown field ${unknown}`;
      for (const [name, field] of schema.properties) {
        const problem = editorCheck(field, value[name], `${place} field ${name}`);
        if (problem !== undefined) return problem;
      }
      return undefined;
    }
  }
}

/**
 * The typed JSON answer of the editor input for a decision, or the refusal
 * `InvalidAnswer` before any command is built. A question with a primitive
 * code converts the input by its code, so the flag input `no` gives JSON
 * `false` and an empty receipt gives `null`. A structured question takes
 * JSON text that must agree with the editor schema of the decision, and a
 * structured question without an editor schema refuses. A recovery decision
 * takes no answer.
 *
 * @public
 */
export function answerValue(decision: DecisionView, input: string): AnswerOutcome {
  const content = decision.content;
  if (content.kind === "recovery") return refuseAnswer("a recovery decision takes no answer");
  if (typeof content.code === "string") return personAnswerValue(content.code, input);
  if (content.editor === null) return refuseAnswer("the decision gives no editor schema for its structured answer");
  const answer = jsonAnswer(input);
  if (!answer.ok) return answer;
  const problem = editorCheck(content.editor, answer.value);
  return problem === undefined ? answer : refuseAnswer(problem);
}

/**
 * The closed answer body of a decision: the operation, the occurrence as
 * canonical decimal text, the generation of the decision, and the typed
 * value.
 *
 * @public
 */
export function answerBody(decision: DecisionView, value: JsonValue): JsonObject {
  return { operation: "answer", occurrenceId: decimalText(decision.occurrenceId), generation: decision.generation, value };
}
