/**
 * Lossless JSON values of the manager client.
 *
 * `JSON.parse` turns every number into a binary floating-point value, so
 * `123456789012345678901234567890`, `1e400` and integers above 2^53 lose their
 * value. `parseJson` keeps the source text of each number in a `JsonNumber`.
 * `encodeJson` writes that text back unchanged. `jsonEqual` compares two
 * values as the manager compares them: numbers by exact decimal value and
 * objects without regard to the order of their members.
 *
 * @packageDocumentation
 */

/**
 * One JSON number, held as its source text. The text is always a number of
 * the JSON grammar.
 *
 * @public
 */
export class JsonNumber {
  readonly source: string;

  constructor(source: string) {
    if (!NUMBER_GRAMMAR.test(source)) throw new SyntaxError(`not a JSON number: ${source}`);
    this.source = source;
  }

  /** The number of an unsigned or signed integer. */
  static ofBigInt(value: bigint): JsonNumber {
    return new JsonNumber(value.toString());
  }
}

/**
 * A JSON value whose numbers keep their source text.
 *
 * @public
 */
export type JsonValue = null | boolean | string | JsonNumber | readonly JsonValue[] | JsonObject;

/**
 * A JSON object. The decoders read members only through `jsonMember`, which
 * sees own members only.
 *
 * @public
 */
export type JsonObject = { readonly [name: string]: JsonValue };

const NUMBER_GRAMMAR = /^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$/;

/** The reviver context of `JSON.parse` in Node 22 and later. */
type ReviverContext = { readonly source?: string };

/**
 * Parse JSON text and keep the source text of each number. Invalid JSON text
 * throws `SyntaxError`, as `JSON.parse` does.
 *
 * @public
 */
export function parseJson(text: string): JsonValue {
  return JSON.parse(text, function revive(_key: string, value: unknown, context?: ReviverContext): unknown {
    if (typeof value !== "number") return value;
    if (context?.source === undefined) {
      throw new Error("JSON.parse does not supply the source text of numbers in this Node version");
    }
    return new JsonNumber(context.source);
  }) as JsonValue;
}

/**
 * Parse JSON text, or give `undefined` when the text is not JSON.
 *
 * @public
 */
export function tryParseJson(text: string): JsonValue | undefined {
  try {
    return parseJson(text);
  } catch (error) {
    if (error instanceof SyntaxError) return undefined;
    throw error;
  }
}

/**
 * Compact JSON text of a value: no white space, the members of each object in
 * code-unit order of their names, and each number as its source text.
 *
 * @public
 */
export function encodeJson(value: JsonValue): string {
  if (value === null) return "null";
  if (typeof value === "boolean") return value ? "true" : "false";
  if (typeof value === "string") return JSON.stringify(value);
  if (value instanceof JsonNumber) return value.source;
  if (isJsonArray(value)) return `[${value.map(encodeJson).join(",")}]`;
  const names = Object.keys(value).sort();
  return `{${names.map((name) => `${JSON.stringify(name)}:${encodeJson(value[name])}`).join(",")}}`;
}

/** Whether a value is a JSON array. */
export function isJsonArray(value: JsonValue): value is readonly JsonValue[] {
  return Array.isArray(value);
}

/** Whether a value is a JSON object. */
export function isJsonObject(value: JsonValue): value is JsonObject {
  return value !== null && typeof value === "object" && !(value instanceof JsonNumber) && !Array.isArray(value);
}

/** The own member of an object with the given name, or `undefined`. */
export function jsonMember(value: JsonObject, name: string): JsonValue | undefined {
  return Object.hasOwn(value, name) ? value[name] : undefined;
}

/**
 * The exact decimal value of a number: sign, coefficient digits without
 * leading or trailing zeros, and a power-of-ten exponent. Zero is
 * `{ negative: false, digits: "0", exponent: 0n }`, so `-0` equals `0`.
 *
 * @public
 */
export type Decimal = { readonly negative: boolean; readonly digits: string; readonly exponent: bigint };

/** The exact decimal value of a number. */
export function decimalOf(number: JsonNumber): Decimal {
  const match = /^(-?)(0|[1-9][0-9]*)(?:\.([0-9]+))?(?:[eE]([+-]?[0-9]+))?$/.exec(number.source);
  if (match === null) throw new SyntaxError(`not a JSON number: ${number.source}`);
  const [, sign, whole, fraction = "", power = "0"] = match;
  let digits = (whole + fraction).replace(/^0+/, "");
  let exponent = BigInt(power) - BigInt(fraction.length);
  if (digits === "") return { negative: false, digits: "0", exponent: 0n };
  const trailing = digits.length - digits.replace(/0+$/, "").length;
  digits = digits.slice(0, digits.length - trailing);
  exponent += BigInt(trailing);
  return { negative: sign === "-", digits, exponent };
}

/** Whether two numbers have the same exact decimal value. */
export function numberEqual(a: JsonNumber, b: JsonNumber): boolean {
  const x = decimalOf(a);
  const y = decimalOf(b);
  return x.negative === y.negative && x.digits === y.digits && x.exponent === y.exponent;
}

/**
 * The integer value of a number when it is integral and inside the closed
 * range from `minimum` to `maximum`, otherwise `undefined`. `7.0` and `70e-1`
 * give 7. `7.5`, `1e400` and every value outside the range give `undefined`.
 *
 * @public
 */
export function boundedInteger(number: JsonNumber, minimum: bigint, maximum: bigint): bigint | undefined {
  const { negative, digits, exponent } = decimalOf(number);
  if (exponent < 0n) return undefined;
  const limit = BigInt(Math.max(minimum.toString().length, maximum.toString().length));
  if (BigInt(digits.length) + exponent > limit) return undefined;
  const magnitude = BigInt(digits) * 10n ** exponent;
  const value = negative ? -magnitude : magnitude;
  return value >= minimum && value <= maximum ? value : undefined;
}

/** The largest unsigned 64-bit integer. */
export const WORD64_MAX = 18446744073709551615n;

/** The unsigned 64-bit integer of a value, or `undefined`. */
export function word64(value: JsonValue | undefined): bigint | undefined {
  return value instanceof JsonNumber ? boundedInteger(value, 0n, WORD64_MAX) : undefined;
}

/**
 * Whether two values are equal as the manager compares them: numbers by exact
 * decimal value, arrays element by element, and objects by their sets of
 * members.
 *
 * @public
 */
export function jsonEqual(a: JsonValue, b: JsonValue): boolean {
  if (a instanceof JsonNumber || b instanceof JsonNumber) {
    return a instanceof JsonNumber && b instanceof JsonNumber && numberEqual(a, b);
  }
  if (a === null || b === null || typeof a !== "object" || typeof b !== "object") return a === b;
  if (isJsonArray(a) || isJsonArray(b)) {
    return isJsonArray(a) && isJsonArray(b) && a.length === b.length && a.every((item, index) => jsonEqual(item, b[index]));
  }
  const names = Object.keys(a);
  return names.length === Object.keys(b).length
    && names.every((name) => Object.hasOwn(b, name) && jsonEqual(a[name], b[name]));
}
