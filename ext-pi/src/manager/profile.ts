/**
 * The client profile of one manager session and the trusted reader of its
 * credential.
 *
 * This module states the profile rules of `connectClientProfile`,
 * `parseClientProfile`, `readClientFile`, `checkedEndpoint` and
 * `readCredential` of `Agentic.Manager.Client` in TypeScript. It imports no
 * Haskell code. A profile is version 1 and has exactly the fields `version`,
 * `endpoint`, `credentialFile` and `caFile`. The endpoint is an `https` URL
 * whose path is `/v1`, with no user information, query or fragment. Both
 * files have absolute paths.
 *
 * Only this module reads the credential file. A `ClientProfile` keeps the
 * credential path and the credential fingerprint in private fields, and its
 * JSON and inspection forms name only the endpoint. The transport receives
 * the bearer only as the value of one `Authorization` header. The bearer
 * never enters a tool argument, a tool result, a transcript entry or a
 * notification.
 *
 * @packageDocumentation
 */

import { createHash, timingSafeEqual, X509Certificate } from "node:crypto";
import { constants, promises as fs } from "node:fs";
import { isAbsolute } from "node:path";
import { inspect } from "node:util";
import type { Outcome } from "./events.ts";
import { boundedInteger, isJsonObject, JsonNumber, tryParseJson } from "./json.ts";

/** The largest profile file, in bytes. */
export const PROFILE_FILE_BYTES = 16384;

/** The largest CA file, in bytes. */
export const CA_FILE_BYTES = 1048576;

/** The largest credential file, in bytes. */
export const CREDENTIAL_FILE_BYTES = 512;

/** The smallest credential, in bytes. */
export const CREDENTIAL_MIN_BYTES = 32;

/** The longest file path of a profile, in UTF-8 bytes. */
const PATH_BYTES = 4096;

/** The longest endpoint, in characters. */
const ENDPOINT_CHARACTERS = 8192;

const PROFILE_FIELDS = ["version", "endpoint", "credentialFile", "caFile"] as const;

/**
 * The endpoint of a profile. `host` is the name or address without brackets,
 * and `base` is the path `/v1`.
 *
 * @public
 */
export type ClientEndpoint = { readonly url: string; readonly host: string; readonly port: number; readonly base: "/v1" };

function failed(kind: "InvalidClientProfile" | "ClientFileUnavailable" | "InvalidEndpoint" | "CredentialUnavailable"): Outcome<never> {
  return { ok: false, failure: { kind } };
}

/**
 * Whether a profile path is absolute, at most 4096 UTF-8 bytes long and free
 * of NUL, LF and CR.
 *
 * @public
 */
export function validClientPath(path: string): boolean {
  return isAbsolute(path) && Buffer.byteLength(path, "utf8") <= PATH_BYTES && !/[\0\n\r]/.test(path);
}

/**
 * The endpoint of an endpoint text, or `InvalidEndpoint`. The text starts
 * with `https://`, holds no space, control character, `@`, `?`, `#` or `\`,
 * and names the path `/v1` or `/v1/`.
 *
 * @public
 */
export function checkedEndpoint(endpoint: string): Outcome<ClientEndpoint> {
  if (endpoint.length > ENDPOINT_CHARACTERS || !endpoint.startsWith("https://")
    || /[\u0000- @?#\\]/.test(endpoint)) return failed("InvalidEndpoint");
  let parsed: URL;
  try {
    parsed = new URL(endpoint);
  } catch (error) {
    if (error instanceof TypeError) return failed("InvalidEndpoint");
    throw error;
  }
  if (parsed.protocol !== "https:" || parsed.username !== "" || parsed.password !== "" || parsed.search !== ""
    || parsed.hash !== "" || (parsed.pathname !== "/v1" && parsed.pathname !== "/v1/") || parsed.hostname === "") {
    return failed("InvalidEndpoint");
  }
  const host = parsed.hostname.startsWith("[") ? parsed.hostname.slice(1, -1) : parsed.hostname;
  const port = parsed.port === "" ? 443 : Number(parsed.port);
  return { ok: true, value: { url: endpoint, host, port, base: "/v1" } };
}

/**
 * The bytes of a regular file of at most `limit` bytes that no group or
 * other user can write, read without following a final symbolic link. A
 * private file is also owned by the effective user, has no group or other
 * permission bits and has one link. Every other file gives
 * `ClientFileUnavailable`.
 */
async function readClientFile(isPrivate: boolean, limit: number, path: string): Promise<Outcome<Buffer>> {
  if (!validClientPath(path)) return failed("InvalidClientProfile");
  let handle: fs.FileHandle;
  try {
    handle = await fs.open(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  } catch (error) {
    if (isSystemError(error)) return failed("ClientFileUnavailable");
    throw error;
  }
  try {
    const status = await handle.stat();
    const uid = process.geteuid === undefined ? -1 : process.geteuid();
    if (!status.isFile() || status.size > limit || (status.mode & 0o022) !== 0
      || (isPrivate && (status.uid !== uid || (status.mode & 0o077) !== 0 || status.nlink !== 1))) {
      return failed("ClientFileUnavailable");
    }
    const buffer = Buffer.alloc(limit + 1);
    let filled = 0;
    for (;;) {
      const { bytesRead } = await handle.read(buffer, filled, buffer.length - filled, null);
      if (bytesRead === 0) break;
      filled += bytesRead;
      if (filled > limit) return failed("ClientFileUnavailable");
    }
    return { ok: true, value: buffer.subarray(0, filled) };
  } catch (error) {
    if (isSystemError(error)) return failed("ClientFileUnavailable");
    throw error;
  } finally {
    await handle.close();
  }
}

function isSystemError(error: unknown): error is NodeJS.ErrnoException {
  return error instanceof Error && typeof (error as NodeJS.ErrnoException).code === "string";
}

/**
 * The bearer of credential bytes: 32 to 512 visible ASCII bytes other than
 * the comma, or `CredentialUnavailable`.
 */
function credentialOf(bytes: Buffer): Outcome<string> {
  if (bytes.length < CREDENTIAL_MIN_BYTES || bytes.length > CREDENTIAL_FILE_BYTES
    || !bytes.every((byte) => byte > 32 && byte < 127 && byte !== 44)) return failed("CredentialUnavailable");
  return { ok: true, value: bytes.toString("latin1") };
}

/** The endpoint, credential path and CA path of profile text, or `InvalidClientProfile`. */
function parseClientProfile(text: string): Outcome<{ endpoint: string; credentialFile: string; caFile: string }> {
  const value = tryParseJson(text);
  if (value === undefined || !isJsonObject(value)) return failed("InvalidClientProfile");
  const names = Object.keys(value);
  if (names.length !== PROFILE_FIELDS.length || !PROFILE_FIELDS.every((name) => Object.hasOwn(value, name))) {
    return failed("InvalidClientProfile");
  }
  const { version, endpoint, credentialFile, caFile } = value;
  if (!(version instanceof JsonNumber) || boundedInteger(version, 1n, 1n) === undefined) return failed("InvalidClientProfile");
  if (typeof endpoint !== "string" || typeof credentialFile !== "string" || typeof caFile !== "string"
    || !validClientPath(credentialFile) || !validClientPath(caFile)) return failed("InvalidClientProfile");
  return { ok: true, value: { endpoint, credentialFile, caFile } };
}

/** Whether PEM text holds at least one certificate and every certificate block parses. */
function certificatesOf(pem: string): boolean {
  const blocks = pem.match(/-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----/g) ?? [];
  if (blocks.length === 0) return false;
  try {
    for (const block of blocks) new X509Certificate(block);
    return true;
  } catch (error) {
    if (isSystemError(error)) return false;
    throw error;
  }
}

function fingerprint(bearer: string): Buffer {
  return createHash("sha256").update(bearer, "latin1").digest();
}

/**
 * One loaded client profile: its endpoint, the PEM text of its CA file, and
 * the private source of its credential.
 *
 * @public
 */
export class ClientProfile {
  /** The endpoint that every request of the session uses. */
  readonly endpoint: ClientEndpoint;
  /** The PEM text of the CA file, the only trust anchors of the session. */
  readonly ca: string;
  readonly #credentialFile: string;
  readonly #fingerprint: Buffer;

  private constructor(endpoint: ClientEndpoint, ca: string, credentialFile: string, print: Buffer) {
    this.endpoint = endpoint;
    this.ca = ca;
    this.#credentialFile = credentialFile;
    this.#fingerprint = print;
  }

  /**
   * Load the profile at an absolute path. The profile file is private. The
   * CA file is a regular file of at most 1 MiB that holds at least one PEM
   * certificate. The credential file is private and holds 32 to 512 visible
   * ASCII bytes other than the comma. Every refusal happens before any
   * request: `InvalidClientProfile` for a profile that does not parse or has
   * another field set, `InvalidEndpoint` for the endpoint,
   * `ClientFileUnavailable` for a file that is missing, too large, not
   * regular or not private, and `CredentialUnavailable` for credential bytes
   * outside the bounds.
   */
  static async load(path: string): Promise<Outcome<ClientProfile>> {
    const bytes = await readClientFile(true, PROFILE_FILE_BYTES, path);
    if (!bytes.ok) return bytes;
    const text = utf8(bytes.value);
    const fields = text === undefined ? failed("InvalidClientProfile") : parseClientProfile(text);
    if (!fields.ok) return fields;
    const endpoint = checkedEndpoint(fields.value.endpoint);
    if (!endpoint.ok) return endpoint;
    const caBytes = await readClientFile(false, CA_FILE_BYTES, fields.value.caFile);
    if (!caBytes.ok) return caBytes;
    const ca = utf8(caBytes.value);
    if (ca === undefined || !certificatesOf(ca)) return failed("InvalidClientProfile");
    const credential = await readClientFile(true, CREDENTIAL_FILE_BYTES, fields.value.credentialFile);
    if (!credential.ok) return credential;
    const bearer = credentialOf(credential.value);
    if (!bearer.ok) return bearer;
    return { ok: true, value: new ClientProfile(endpoint.value, ca, fields.value.credentialFile, fingerprint(bearer.value)) };
  }

  /**
   * The `Authorization` header value of one request. The credential file is
   * read again, and a bearer whose fingerprint differs from the fingerprint
   * at load gives `CredentialChanged`.
   */
  async authorization(): Promise<Outcome<string>> {
    const bytes = await readClientFile(true, CREDENTIAL_FILE_BYTES, this.#credentialFile);
    if (!bytes.ok) return bytes;
    const bearer = credentialOf(bytes.value);
    if (!bearer.ok) return bearer;
    if (!timingSafeEqual(fingerprint(bearer.value), this.#fingerprint)) return { ok: false, failure: { kind: "CredentialChanged" } };
    return { ok: true, value: `Bearer ${bearer.value}` };
  }

  /** The JSON form names only the endpoint. */
  toJSON(): { endpoint: string } {
    return { endpoint: this.endpoint.url };
  }

  [inspect.custom](): string {
    return `ClientProfile(${this.endpoint.url})`;
  }
}

function utf8(bytes: Buffer): string | undefined {
  try {
    return new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(bytes);
  } catch (error) {
    if (error instanceof TypeError) return undefined;
    throw error;
  }
}
