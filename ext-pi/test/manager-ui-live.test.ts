/**
 * The live check of the human path of service mode, `/wfm` and its
 * companion commands, against a running protected manager. It runs only when
 * `AGENT_CAT_MANAGER_PROFILE` names a client profile, as the `pi-client`
 * mode of `manager/test/service_http.py` sets it. When
 * `AGENT_CAT_MANAGER_REPORT` names a file, the last step writes the
 * identifiers of the check there, and the harness checks each of them
 * against manager facts that it reads with its own credential.
 *
 * The extension runs in service mode with a fake Pi host whose fake UI
 * answers each select, editor, confirmation and custom component. A
 * recording transport keeps every POST that the extension sends. The steps
 * share one extension:
 *
 * 1. `/wfm` of `prompt-source` with an exact Unicode literal that starts
 *    with spaces. While the editor is open, the check changes the request
 *    through its own session, so the first `set-input` of the extension is
 *    refused with 412. The editor opens again with the kept draft. The
 *    review component shows the complete exact review, `a` and the
 *    confirmation approve it, and the manager starts a run that succeeds.
 * 2. `/wfm captured-input` with captured editor text. The capture goes
 *    through `POST /v1/captures`, the receipt names the size and SHA-256 of
 *    the exact bytes, `set-input` binds it, and the approved run succeeds.
 * 3. `/wfm prompt-source`, and Escape declines the review. Nothing is sent
 *    to the preparation, and the request stays in review. `/wfm-review` then
 *    discards the preparation with `d`, and `/wfm-withdraw` withdraws the
 *    request.
 * 4. The extension closes.
 */

import { createHash } from "node:crypto";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import extension from "../src/index.ts";
import type { Outcome } from "../src/manager/events.ts";
import { encodeJson, isJsonObject, jsonMember, type JsonObject, type JsonValue } from "../src/manager/json.ts";
import { ClientProfile } from "../src/manager/profile.ts";
import { decodeCommandReceipt, decodeDraftView, decodePreparation, type DraftView } from "../src/manager/resources.ts";
import { ManagerSession, type Observed, type Reference, type SessionTransport } from "../src/manager/session.ts";
import { ManagerTransport, type CommandHeaders, type TransportOptions } from "../src/manager/transport.ts";
import type { ReviewComponent } from "../src/manager-ui.ts";

const PROFILE = process.env.AGENT_CAT_MANAGER_PROFILE;
const REPORT = process.env.AGENT_CAT_MANAGER_REPORT;

/** The exact literal, with leading spaces, Unicode and an inner line end. `PI_UI_LITERAL` of the harness states it. */
const LITERAL = "  Café λ — exact literal.\n\tSecond line ✓";

/** The exact captured text. `PI_UI_CAPTURED` of the harness states it. */
const CAPTURED = "  Captured Ünïcode λ\r\nsecond line\n";

/** The literal of the declined request. */
const DECLINED = "declined review";

const STEP_MS = 600_000;
const WAIT_MS = 120_000;
const SELECTORS = ["reviewDigest", "requestRevision", "profileRevision", "descriptorRevision", "processGeneration"] as const;

type Post = { readonly resource: string; readonly body: string | Buffer; readonly ifMatch: string | null };

function must<Value>(outcome: Outcome<Value>, step: string): Value {
  if (!outcome.ok) throw new Error(`${step}: ${JSON.stringify(outcome.failure)}`);
  return outcome.value;
}

/** A transport that records each POST and delegates to `ManagerTransport`. */
function recording(posts: Post[]): (profile: ClientProfile, options: TransportOptions) => SessionTransport {
  return (profile, options) => {
    const transport = new ManagerTransport(profile, options);
    return {
      get: (resource) => transport.get(resource),
      post: (resource: string, body: JsonValue, command: CommandHeaders) => {
        posts.push({ resource, body: encodeJson(body), ifMatch: command.ifMatch });
        return transport.post(resource, body, command);
      },
      postBytes: (resource: string, bytes: Uint8Array, command: CommandHeaders) => {
        posts.push({ resource, body: Buffer.from(bytes), ifMatch: command.ifMatch });
        return transport.postBytes(resource, bytes, command);
      },
      followEvents: (start, deliver, follow) => transport.followEvents(start, deliver, follow),
      pollEvents: (cursor) => transport.pollEvents(cursor),
      downloadVerified: (resource, size, sha256) => transport.downloadVerified(resource, size, sha256),
      dropStream: () => transport.dropStream(),
      close: () => transport.close(),
    };
  };
}

/** The scripted answers of the fake UI for one command. */
type Script = {
  select?: (title: string, options: string[]) => string | undefined;
  editor?: (title: string, prefill: string | undefined) => Promise<string | undefined> | string | undefined;
  confirm?: (title: string, message: string) => boolean;
  review?: (screen: string) => string;
};

describe.runIf(PROFILE)("the human path of service mode against a live manager", () => {
  let session: ManagerSession;
  const posts: Post[] = [];
  const notices: string[] = [];
  const screens: string[] = [];
  const confirmations: string[] = [];
  const commands = new Map<string, { handler: (args: string, ctx: unknown) => Promise<void> }>();
  const events = new Map<string, Array<(event: unknown, ctx: unknown) => Promise<unknown>>>();
  let script: Script = {};
  let state = "";
  let previousState: string | undefined;
  const report: Record<string, unknown> = {};

  const ctx = {
    cwd: "", mode: "tui", hasUI: true, isProjectTrusted: () => true,
    ui: {
      notify: (message: string) => notices.push(message),
      setWidget: () => {},
      setStatus: () => {},
      select: async (title: string, options: string[]) => {
        const chosen = script.select?.(title, options);
        if (chosen === undefined) throw new Error(`unexpected select ${title}: ${options.join(" | ")}`);
        return chosen;
      },
      editor: async (title: string, prefill?: string) => {
        if (script.editor === undefined) throw new Error(`unexpected editor ${title}`);
        return script.editor(title, prefill);
      },
      input: async (title: string) => {
        throw new Error(`unexpected input ${title}`);
      },
      confirm: async (title: string, message: string) => {
        confirmations.push(`${title} ${message}`);
        if (script.confirm === undefined) throw new Error(`unexpected confirmation ${title}`);
        return script.confirm(title, message);
      },
      custom: <T>(factory: (tui: unknown, theme: unknown, keys: unknown, done: (value: T) => void) => unknown) =>
        new Promise<T>((resolve) => {
          const tui = { terminal: { rows: 400 }, requestRender: () => {} };
          const theme = { fg: (_color: string, value: string) => value };
          const component = factory(tui, theme, {}, resolve) as ReviewComponent;
          const screen = component.render(120).join("\n");
          screens.push(screen);
          if (script.review === undefined) throw new Error("unexpected review");
          component.handleInput(script.review(screen));
        }),
    },
  };

  const run = (name: string, args = "") => commands.get(name)!.handler(args, ctx);
  const ref = (uri: string): Reference => must(session.reference(uri), `reference ${uri}`);

  /** Read a resource every 250 milliseconds until the predicate holds. */
  async function until(uri: string, ready: (observed: Observed) => boolean, step: string): Promise<Observed> {
    const deadline = Date.now() + WAIT_MS;
    for (;;) {
      const observed = await session.get(ref(uri));
      if (observed.ok && ready(observed.value)) return observed.value;
      if (Date.now() > deadline) throw new Error(`${step}: ${JSON.stringify(observed)}`);
      await new Promise((wake) => setTimeout(wake, 250));
    }
  }

  const draftOf = (observed: Observed): DraftView => must(decodeDraftView(observed.value), "request");

  /** The request identifier of the latest accepted create. */
  function createdRequest(): string {
    const notice = [...notices].reverse().find((line) => line.startsWith("Command create accepted: request "));
    const id = notice?.slice("Command create accepted: request ".length).split(" ")[0];
    if (id === undefined) throw new Error(`no create notice: ${notices.join("\n")}`);
    return id;
  }

  async function status(): Promise<string> {
    await run("wfm-status");
    return notices.at(-1) ?? "";
  }

  async function succeeded(runId: string): Promise<void> {
    const terminal = await until(`/v1/runs/${runId}/snapshot`, (observed) => {
      const runtime = isJsonObject(observed.value) ? jsonMember(observed.value, "runtime") : undefined;
      const status = runtime !== undefined && runtime !== null && isJsonObject(runtime) ? jsonMember(runtime, "status") : undefined;
      return typeof status === "string" && ["succeeded", "failed", "cancelled"].includes(status);
    }, `terminal run ${runId}`);
    expect(jsonMember(jsonMember(terminal.value as JsonObject, "runtime") as JsonObject, "status")).toBe("succeeded");
  }

  /**
   * Check the review screen against the preparation as the manager states it
   * now, and give the preparation. The component wraps long lines at
   * spaces, so the comparison ignores whitespace.
   */
  async function reviewed(screen: string, preparationId: string): Promise<JsonObject> {
    const read = must(await session.get(ref(`/v1/preparations/${preparationId}`)), "preparation");
    const preparation = must(decodePreparation(read.value), "preparation decode");
    const review = preparation.review;
    const compact = (value: string): string => value.replace(/\s+/g, "");
    const shown = compact(screen);
    for (const fact of [
      ...SELECTORS.map((name) => `${name}: ${preparation[name]}`), `Program SHA-256: ${review.programHash}`,
      `Person answering: ${review.personAnswering}`, `Workflow: ${review.workflowId}`, `Profile: ${review.profileId}`,
      `Workspace: ${review.workspaceLabel}`, `Target: ${review.targetLabel}`, `Policy: ${encodeJson(review.policy)}`,
      `Result code: ${encodeJson(review.resultCode)}`,
      ...review.inputs.map((input) => `${input.name}: ${input.source}, ${input.bytes} bytes, SHA-256 ${input.sha256}`),
      `Plan: ${review.plan}`,
    ]) expect(shown, `the review screen lacks ${fact}`).toContain(compact(fact));
    return read.value as JsonObject;
  }

  /** The preparation identifier of a request. */
  async function preparationOf(requestId: string): Promise<string> {
    return draftOf(must(await session.get(ref(`/v1/requests/${requestId}`)), "request")).preparationId ?? "";
  }

  beforeAll(async () => {
    session = must(await ManagerSession.connect(must(await ClientProfile.load(PROFILE ?? ""), "profile")), "connect");
    state = mkdtempSync(join(tmpdir(), "agent-cat-pi-ui-state-"));
    ctx.cwd = state;
    previousState = process.env.AGENT_CAT_STATE_DIR;
    process.env.AGENT_CAT_STATE_DIR = state;
    extension({
      registerEntryRenderer: () => {}, registerTool: () => {}, appendEntry: () => {}, sendUserMessage: () => {},
      registerCommand: (name: string, value: unknown) => commands.set(name, value as never),
      on: (name: string, handler: (event: unknown, ctx: unknown) => Promise<unknown>) => events.set(name, [...(events.get(name) ?? []), handler]),
    } as never, { manager: { transport: recording(posts) } });
    for (const handler of events.get("session_start") ?? []) await handler({ type: "session_start" }, ctx);
    const deadline = Date.now() + WAIT_MS;
    while (!(await status()).includes("delivery live")) {
      if (Date.now() > deadline) throw new Error(`the extension did not connect: ${notices.at(-1)}`);
      await new Promise((wake) => setTimeout(wake, 100));
    }
  }, STEP_MS);

  afterAll(async () => {
    await session?.close();
    if (previousState === undefined) delete process.env.AGENT_CAT_STATE_DIR;
    else process.env.AGENT_CAT_STATE_DIR = previousState;
    if (state) rmSync(state, { recursive: true, force: true });
  });

  it("enters an exact literal, keeps the draft over a changed request, approves the displayed review and starts the run", async () => {
    let editors = 0;
    script = {
      select: (title, options) => title.startsWith("Workflow of ") ? options.find((option) => option.startsWith("prompt-source"))
        : title.startsWith("Input input") ? "Literal text" : undefined,
      editor: async (_title, prefill) => {
        editors += 1;
        if (editors === 1) {
          // The request changes while the editor is open.
          expect(prefill).toBeUndefined();
          const requestId = createdRequest();
          const current = must(await session.get(ref(`/v1/requests/${requestId}`)), "request before the change");
          const pending = must(session.prepare(ref(`/v1/requests/${requestId}`),
            { operation: "set-input", input: { name: "input", source: "literal", value: "changed elsewhere" } }, current.etag), "prepare change");
          const sent = await session.send(pending);
          if (sent.kind !== "delivered") throw new Error(`change: ${JSON.stringify(sent)}`);
          await until(sent.location.uri, (observed) => {
            const receipt = decodeCommandReceipt(observed.value);
            return receipt.ok && receipt.value.state === "effect-observed";
          }, "change effect");
          return LITERAL;
        }
        // The editor opens again with the kept draft.
        expect(prefill).toBe(LITERAL);
        return prefill;
      },
      review: () => "a",
      confirm: () => true,
    };
    const before = posts.length;
    await run("wfm");
    const requestId = createdRequest();
    expect(editors).toBe(2);
    expect(notices.some((line) => line.startsWith("Command set-input refused: 412 stale-revision"))).toBe(true);
    expect(notices.some((line) => line.includes(`Request ${requestId} changed while the editor was open. The draft of input is kept`))).toBe(true);
    const request = draftOf(must(await session.get(ref(`/v1/requests/${requestId}`)), "literal request"));
    expect(request.readiness.supplied).toEqual([{ source: "literal", name: "input", value: LITERAL }]);
    expect(request.runId).not.toBeNull();
    const runId = request.runId ?? "";
    expect(notices, notices.join("\n")).toContain(`Execution: the manager started run ${runId} for request ${requestId}.`);
    // The consumed preparation is the target of the one approve POST.
    const approved = posts.slice(before).filter((post) => post.resource.startsWith("/v1/preparations/"));
    expect(approved).toHaveLength(1);
    const preparationId = approved[0].resource.slice("/v1/preparations/".length);
    const preparation = await reviewed(screens.at(-1) ?? "", preparationId);
    expect(jsonMember(preparation, "state")).toBe("consumed");
    expect(screens.at(-1)?.replace(/\s+/g, "")).toContain(`Reviewofrequest${requestId},preparation${preparationId}`);
    expect(confirmations.at(-1)).toContain(`review digest ${jsonMember(preparation, "reviewDigest")}`);
    const approve = posts.slice(before).filter((post) => post.resource === `/v1/preparations/${preparationId}`);
    expect(approve).toHaveLength(1);
    const body = JSON.parse(String(approve[0].body)) as Record<string, string>;
    expect(body).toEqual({ operation: "approve", ...Object.fromEntries(SELECTORS.map((name) => [name, jsonMember(preparation, name)])) });
    expect(screens.at(-1)).toContain(`If-Match: ${approve[0].ifMatch}`);
    // The command receipts are listed apart from the execution state.
    const shown = await status();
    expect(shown.indexOf("Command receipts:")).toBeGreaterThan(shown.indexOf("Service runs:"));
    expect(shown).toMatch(new RegExp(`\n {2}approve {2}accepted {2}command \\S+, receipt [a-z-]+ {2}/v1/preparations/${preparationId}`));
    expect(shown).toMatch(/\n {2}set-input {2}refused {2}412 stale-revision/);
    await succeeded(runId);
    Object.assign(report, { literalRequestId: requestId, literalRunId: runId, literalPreparationId: preparationId, approveBody: body });
  }, STEP_MS);

  it("captures exact editor text through /v1/captures and the run receives the captured bytes", async () => {
    script = {
      select: (title) => (title.startsWith("Input input") ? "Captured text" : undefined),
      editor: () => CAPTURED,
      review: () => "a",
      confirm: () => true,
    };
    const before = posts.length;
    await run("wfm", "captured-input");
    const requestId = createdRequest();
    const bytes = Buffer.from(CAPTURED, "utf8");
    const sha256 = createHash("sha256").update(bytes).digest("hex");
    const captures = posts.slice(before).filter((post) => post.resource === `/v1/captures?requestId=${requestId}`);
    expect(captures).toHaveLength(1);
    expect(Buffer.isBuffer(captures[0].body) && captures[0].body.equals(bytes)).toBe(true);
    expect(captures[0].ifMatch).toBeNull();
    const receipt = notices.find((line) => line.startsWith("Command capture accepted: capture "));
    expect(receipt).toContain(`of request ${requestId}, ${bytes.length} bytes, SHA-256 ${sha256}, command /v1/commands/`);
    const request = draftOf(must(await session.get(ref(`/v1/requests/${requestId}`)), "captured request"));
    const captureId = receipt?.slice("Command capture accepted: capture ".length).split(" ")[0];
    expect(request.readiness.supplied).toEqual([{ source: "capture", name: "input", captureId }]);
    expect(screens.at(-1)?.replace(/\s+/g, "")).toContain(`input:capture,${bytes.length}bytes,SHA-256${sha256}`);
    const runId = request.runId ?? "";
    expect(notices, notices.join("\n")).toContain(`Execution: the manager started run ${runId} for request ${requestId}.`);
    await succeeded(runId);
    Object.assign(report, { capturedRequestId: requestId, capturedRunId: runId, captureId, captureSha256: sha256, captureBytes: bytes.length });
  }, STEP_MS);

  it("declines a review without a send, then discards the preparation and withdraws the request", async () => {
    script = {
      select: (title) => (title.startsWith("Input input") ? "Literal text" : undefined),
      editor: () => DECLINED,
      review: () => "\u001b",
    };
    const confirmed = confirmations.length;
    await run("wfm", "prompt-source");
    const requestId = createdRequest();
    const preparationId = await preparationOf(requestId);
    expect(preparationId).not.toBe("");
    expect(confirmations.length).toBe(confirmed);
    expect(notices.at(-1), notices.join("\n")).toBe(`Review declined. No approval was sent. Request ${requestId} stays in review, and /wfm-review opens it again.`);
    expect(posts.filter((post) => post.resource === `/v1/preparations/${preparationId}`)).toEqual([]);
    const held = draftOf(must(await session.get(ref(`/v1/requests/${requestId}`)), "declined request"));
    expect([held.phase, held.runId]).toEqual(["review", null]);
    const live = must(decodePreparation(must(await session.get(ref(`/v1/preparations/${preparationId}`)), "declined preparation").value), "decode");
    expect(live.state).toBe("live");
    await reviewed(screens.at(-1) ?? "", preparationId);

    // The same review opens again, and d discards its preparation.
    script = { review: () => "d" };
    await run("wfm-review", requestId);
    const discards = posts.filter((post) => post.resource === `/v1/preparations/${preparationId}`);
    expect(discards.map((post) => JSON.parse(String(post.body)))).toEqual([{ operation: "discard" }]);
    expect(notices, notices.join("\n")).toContain(`Request ${requestId} is a draft again. /wfm-review prepares a new review.`);
    script = {};
    await run("wfm-withdraw", requestId);
    expect(notices, notices.join("\n")).toContain(`Request ${requestId} is withdrawn.`);
    const withdrawn = draftOf(await until(`/v1/requests/${requestId}`, (observed) => draftOf(observed).phase === "withdrawn", "withdrawn"));
    expect(withdrawn.runId).toBeNull();
    Object.assign(report, { declinedRequestId: requestId, declinedPreparationId: preparationId });
  }, STEP_MS);

  it("closes the extension and writes the report", async () => {
    for (const handler of events.get("session_shutdown") ?? []) await handler({ type: "session_shutdown" }, ctx);
    expect(await status()).toContain("Connection: closed. The manager keeps its runs under its own supervision.");
    if (REPORT !== undefined) writeFileSync(REPORT, `${JSON.stringify(report)}\n`, { mode: 0o600 });
  }, STEP_MS);
});
