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
 * 4. `/wfm mixed-controls` starts a run. `/wfm-monitor` shows its runtime
 *    status, the observation freshness and its Bool question, and `q`
 *    closes it. `/wfm-answer` answers the question through the typed editor
 *    with `no`, which sends JSON `false`, and then offers only the recovery
 *    choices that the manager offers, of which the check selects Retry. A
 *    second `/wfm-monitor` shows terminal success with the Terminal and
 *    Result lines of the verified result.
 * 5. `/wfm mixed-controls` starts a second run. While the editor of
 *    `/wfm-answer` is open, the harness answers the question first through
 *    HTTP with its own credential, through the handshake file that
 *    `AGENT_CAT_MANAGER_HARNESS_ANSWER` names. The answer of the extension
 *    receives 412 `stale-revision`, the draft is kept, and nothing is sent
 *    again. The recovery head is then abandoned, or retried when the
 *    manager offers no abandon.
 * 6. `/wfm mixed-controls` starts a third run, which waits at its question.
 *    `/wfm-cancel` sends one cancel to the controls of the run after the
 *    confirmation, reports the receipt and then the runtime acknowledgement
 *    verbatim, and the run ends cancelled.
 * 7. `/wfm-result` retrieves the verified result of the run of step 4 and
 *    saves it to a new file with mode 0600 whose bytes have the size and
 *    SHA-256 that the monitor showed. A second save to the same path refuses
 *    and leaves the file unchanged. The harness compares the file with its
 *    own download.
 * 8. `/wfm-export` exports the same verified result once under a new name
 *    with the entity tag of the export collection as `If-Match`, shows the
 *    published receipt and its verified download, and lists the export.
 * 9. `/wfm-restart` creates a restart child request of the run of step 1
 *    through its lineage collection. The child is enqueued at once, its
 *    exact review shows the lineage, `a` and the confirmation approve it,
 *    and the child run succeeds and names the parent run and the lineage
 *    restart.
 * 10. The `agent_cat_workflow` tool starts mixed-controls twice through
 *    `manager-start`. The human confirms the request each time. The first
 *    exact review is declined, so no approve command exists, and the human
 *    then discards the preparation and withdraws the request. The second
 *    review is approved after its confirmation, and the manager starts the
 *    run. `manager-answer` answers its Bool question with `false` after the
 *    confirmation of the typed value, which sends JSON `false`, and
 *    `manager-control` retries its recovery after the confirmation of the
 *    control. No tool result names the bearer, the credential path or the
 *    client profile path.
 * 11. `/wfm-history` lists every run of `/v1/runs` over all its pages, in
 *    the order of the collection, with the restart child and its parent.
 * 12. The extension closes.
 */

import { createHash } from "node:crypto";
import { existsSync, lstatSync, mkdtempSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import extension from "../src/index.ts";
import type { Outcome } from "../src/manager/events.ts";
import { encodeJson, isJsonObject, jsonMember, type JsonObject, type JsonValue } from "../src/manager/json.ts";
import { ClientProfile } from "../src/manager/profile.ts";
import {
  decodeCommandReceipt,
  decodeControl,
  decodeDecision,
  decodeDraftView,
  decodeExportCollection,
  decodePreparation,
  decodeRunItem,
  type ControlView,
  type DecisionView,
  type DraftView,
} from "../src/manager/resources.ts";
import { ManagerSession, type Observed, type Reference, type SessionTransport } from "../src/manager/session.ts";
import { ManagerTransport, type CommandHeaders, type TransportOptions } from "../src/manager/transport.ts";
import type { Component } from "@earendil-works/pi-tui";

const PROFILE = process.env.AGENT_CAT_MANAGER_PROFILE;
const REPORT = process.env.AGENT_CAT_MANAGER_REPORT;
const HARNESS_ANSWER = process.env.AGENT_CAT_MANAGER_HARNESS_ANSWER;

/** The exact literal, with leading spaces, Unicode and an inner line end. `PI_UI_LITERAL` of the harness states it. */
const LITERAL = "  Café λ — exact literal.\n\tSecond line ✓";

/** The exact captured text. `PI_UI_CAPTURED` of the harness states it. */
const CAPTURED = "  Captured Ünïcode λ\r\nsecond line\n";

/** The literal of the declined request. */
const DECLINED = "declined review";

/** The literal of the run that the Pi user answers. `PI_UI_ANSWERED` of the harness states it. */
const ANSWERED = "Pi answer λ: explicit false.";

/** The literal of the run whose question the harness answers first. `PI_UI_STALE` of the harness states it. */
const STALE = "Pi stale λ: the harness answers first.";

/** The literal of the tool start whose review the human declines. `PI_UI_TOOL_DECLINED` of the harness states it. */
const TOOL_DECLINED = "Pi tool λ: the human declines the review.";

/** The literal of the tool start that the human approves. `PI_UI_TOOL_ANSWERED` of the harness states it. */
const TOOL_ANSWERED = "Pi tool λ: the model answers false.";

/** The literal of the run that `/wfm-cancel` cancels. `PI_UI_CANCELLED` of the harness states it. */
const CANCELLED = "Pi cancel λ: the run ends cancelled.";

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
  input?: (title: string) => string | undefined;
  /** The key for a drawn component, or `undefined` to keep it open until its next drawing. */
  review?: (screen: string) => string | undefined;
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
  let tool: { execute: (id: string, params: unknown, signal: unknown, update: unknown, ctx: unknown) => Promise<{ isError?: boolean; content: Array<{ text: string }> }> } | undefined;
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
        if (script.input === undefined) throw new Error(`unexpected input ${title}`);
        return script.input(title);
      },
      confirm: async (title: string, message: string) => {
        confirmations.push(`${title} ${message}`);
        if (script.confirm === undefined) throw new Error(`unexpected confirmation ${title}`);
        return script.confirm(title, message);
      },
      custom: <T>(factory: (tui: unknown, theme: unknown, keys: unknown, done: (value: T) => void) => unknown) =>
        new Promise<T>((resolve, reject) => {
          // Each drawing gives the screen to the script, which answers with a key or keeps the component open.
          let open = true;
          let component: Component | undefined;
          const show = () => {
            if (!open || component === undefined) return;
            const screen = component.render(120).join("\n");
            screens.push(screen);
            if (script.review === undefined) {
              open = false;
              return reject(new Error(`unexpected component: ${screen}`));
            }
            const key = script.review(screen);
            if (key !== undefined) component.handleInput?.(key);
          };
          const tui = { terminal: { rows: 400 }, requestRender: () => setImmediate(show) };
          const theme = { fg: (_color: string, value: string) => value };
          component = factory(tui, theme, {}, (value) => {
            open = false;
            resolve(value);
          }) as Component;
          show();
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

  /** The command identifier of the latest accepted command of an operation, from its notification. */
  function acceptedCommand(operation: string): string {
    const notice = [...notices].reverse().find((line) => line.startsWith(`Command ${operation} accepted: command `));
    const id = notice?.slice(`Command ${operation} accepted: command `.length).split(",")[0];
    if (id === undefined) throw new Error(`no accepted ${operation}: ${notices.join("\n")}`);
    return `/v1/commands/${id}`;
  }

  /** Create a mixed-controls request with a literal through /wfm, approve its review, and give its request and run. */
  async function startMixed(literal: string): Promise<{ requestId: string; runId: string }> {
    script = {
      select: (title) => (title.startsWith("Input input") ? "Literal text" : undefined),
      editor: () => literal,
      review: () => "a",
      confirm: () => true,
    };
    await run("wfm", "mixed-controls");
    const requestId = createdRequest();
    const request = draftOf(must(await session.get(ref(`/v1/requests/${requestId}`)), "mixed request"));
    expect(request.readiness.supplied).toEqual([{ source: "literal", name: "input", value: literal }]);
    expect(request.runId).not.toBeNull();
    return { requestId, runId: request.runId ?? "" };
  }

  /** Open /wfm-monitor of a run until a drawing satisfies the predicate, and give that drawing. */
  async function monitored(runId: string, ready: (screen: string) => boolean, step: string): Promise<string> {
    let seen: string | undefined;
    script = {
      review: (screen) => {
        if (!ready(screen)) return undefined;
        seen = screen;
        return "q";
      },
    };
    let timer: NodeJS.Timeout | undefined;
    const late = new Promise<never>((_, reject) => {
      timer = setTimeout(() => reject(new Error(`${step}: ${screens.at(-1)}`)), WAIT_MS);
    });
    try {
      await Promise.race([run("wfm-monitor", runId), late]);
    } finally {
      clearTimeout(timer);
    }
    if (seen === undefined) throw new Error(`${step}: the monitor closed without the expected screen`);
    return seen;
  }

  /** The next head decision of a run that is not in `handled`, with the controls that name it, or `undefined` at the end of the run. */
  async function nextHead(runId: string, handled: ReadonlySet<string>): Promise<{ decision: DecisionView; control: ControlView } | undefined> {
    const deadline = Date.now() + WAIT_MS;
    for (;;) {
      const snapshot = must(await session.get(ref(`/v1/runs/${runId}/snapshot`)), "snapshot");
      const runtime = isJsonObject(snapshot.value) ? jsonMember(snapshot.value, "runtime") : undefined;
      const status = runtime !== undefined && runtime !== null && isJsonObject(runtime) ? jsonMember(runtime, "status") : undefined;
      const control = must(decodeControl(must(await session.get(ref(`/v1/runs/${runId}/control`)), "control").value), "control decode");
      const head = control.decisionHeadId;
      if (head !== null && !handled.has(head)) {
        const decision = must(decodeDecision(must(await session.get(ref(`/v1/decisions/${head}`)), "head").value), "head decode");
        if (decision.state === "pending") return { decision, control };
      }
      if (typeof status === "string" && ["succeeded", "failed", "cancelled"].includes(status)) return undefined;
      if (Date.now() > deadline) throw new Error(`no next head of run ${runId}: ${JSON.stringify(control.value)}`);
      await new Promise((wake) => setTimeout(wake, 250));
    }
  }

  /** The labels of the recovery choices that the controls offer for a recovery head, read from the offers themselves. */
  function offeredChoices(control: ControlView, decision: DecisionView): string[] {
    if (decision.content.kind !== "recovery") return [];
    const offers = control.offers.filter((offer) => offer.occurrenceId === decision.occurrenceId && offer.generation === decision.generation);
    return decision.content.choices.filter((option) => offers.some((offer) => (offer.operation === "retry" && option.choice === "retry")
      || (offer.operation === "choose-recovery" && offer.choices.some((item) => item.choice === option.choice && item.target === option.target))))
      .map((option) => (option.choice === "retry" ? "Retry" : option.choice === "abandon" ? "Abandon"
        : option.target === null ? "Fail over" : `Fail over to ${option.target}`));
  }

  /** Ask the harness to answer a decision first through HTTP with its own credential, and give its answer command. */
  async function harnessAnswers(decision: string): Promise<string> {
    if (HARNESS_ANSWER === undefined) throw new Error("AGENT_CAT_MANAGER_HARNESS_ANSWER names no handshake file");
    writeFileSync(`${HARNESS_ANSWER}.tmp`, JSON.stringify({ decision }), { mode: 0o600 });
    renameSync(`${HARNESS_ANSWER}.tmp`, HARNESS_ANSWER);
    const done = `${HARNESS_ANSWER}.done`;
    const deadline = Date.now() + WAIT_MS;
    while (!existsSync(done)) {
      if (Date.now() > deadline) throw new Error("the harness did not answer first");
      await new Promise((wake) => setTimeout(wake, 100));
    }
    return (JSON.parse(readFileSync(done, "utf8")) as { command: string }).command;
  }

  /** The POSTs to a resource after an index of `posts`. */
  const postsTo = (resource: string, from = 0): Post[] => posts.slice(from).filter((post) => post.resource === resource);

  beforeAll(async () => {
    session = must(await ManagerSession.connect(must(await ClientProfile.load(PROFILE ?? ""), "profile")), "connect");
    state = mkdtempSync(join(tmpdir(), "agent-cat-pi-ui-state-"));
    ctx.cwd = state;
    previousState = process.env.AGENT_CAT_STATE_DIR;
    process.env.AGENT_CAT_STATE_DIR = state;
    extension({
      registerEntryRenderer: () => {}, registerTool: (definition: unknown) => { tool = definition as typeof tool; }, appendEntry: () => {}, sendUserMessage: () => {},
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

  it("monitors a run, answers its Bool question with JSON false, retries the offered recovery and sees terminal success", async () => {
    const { requestId, runId } = await startMixed(ANSWERED);
    const question = await monitored(runId, (screen) => screen.includes(`Independent confirmation? ${ANSWERED}`)
      && screen.includes("Observation: current") && screen.includes("Runtime: running"), "monitor question");
    expect(question).toContain(`Service run ${runId}, workflow mixed-controls`);
    expect(question).toContain("Delivery: live");
    expect(question).toMatch(/Decisions: [12] pending/);
    expect(question).not.toContain("Terminal:");
    const handled = new Set<string>();
    let answerCommand = "";
    let retryCommand = "";
    let answeredDecision = "";
    for (let head = await nextHead(runId, handled); head !== undefined; head = await nextHead(runId, handled)) {
      const { decision, control } = head;
      handled.add(decision.id);
      const before = posts.length;
      if (decision.content.kind === "question") {
        const titles: string[] = [];
        script = {
          editor: (title, prefill) => {
            titles.push(title);
            expect(prefill).toBeUndefined();
            return "no";
          },
        };
        await run("wfm-answer", runId);
        expect(titles).toHaveLength(1);
        expect(titles[0]).toContain(`Answer of decision ${decision.id} (flag: yes, no, true or false): Independent confirmation? ${ANSWERED}`);
        const sent = postsTo(`/v1/decisions/${decision.id}`, before);
        expect(sent).toHaveLength(1);
        expect(JSON.parse(String(sent[0].body))).toEqual({
          operation: "answer", occurrenceId: decision.occurrenceId.toString(), generation: decision.generation, value: false,
        });
        expect(notices, notices.join("\n")).toContain(`Answer false reached decision ${decision.id} of run ${runId}.`);
        answerCommand = acceptedCommand("answer");
        answeredDecision = decision.id;
      } else {
        const offered = offeredChoices(control, decision);
        expect(offered).toContain("Retry");
        let shown: string[] = [];
        script = {
          select: (title, options) => {
            expect(title).toContain(`Recovery of decision ${decision.id}`);
            shown = options;
            return "Retry";
          },
        };
        await run("wfm-answer", runId);
        expect(shown).toEqual(offered);
        const sent = postsTo(`/v1/runs/${runId}/control`, before);
        expect(sent).toHaveLength(1);
        expect(JSON.parse(String(sent[0].body))).toEqual({ operation: "retry", occurrenceId: decision.occurrenceId.toString(), generation: decision.generation });
        expect(notices, notices.join("\n")).toContain(`Recovery Retry reached decision ${decision.id} of run ${runId}.`);
        retryCommand = acceptedCommand("retry");
      }
    }
    expect(handled.size).toBe(2);
    expect(answerCommand && retryCommand).not.toBe("");
    const terminal = await monitored(runId, (screen) => screen.includes("Terminal: succeeded") && /Result SHA-256: [0-9a-f]{64}/.test(screen),
      "monitor terminal");
    expect(terminal).toContain("Runtime: succeeded");
    expect(terminal).toContain("Decisions: none pending");
    const bytes = /Result: verified ([0-9]+) bytes/.exec(terminal);
    const sha256 = /Result SHA-256: ([0-9a-f]{64})/.exec(terminal);
    expect(bytes).not.toBeNull();
    // The Terminal and Result lines end the monitor, above its key line.
    const lines = terminal.split("\n");
    expect(lines.slice(-4, -1)).toEqual(["Terminal: succeeded", `Result: verified ${bytes?.[1]} bytes`, `Result SHA-256: ${sha256?.[1]}`]);
    await succeeded(runId);
    Object.assign(report, {
      monitoredRequestId: requestId, monitoredRunId: runId, answeredDecisionId: answeredDecision, answerCommand, retryCommand,
      resultBytes: Number(bytes?.[1]), resultSha256: sha256?.[1],
    });
  }, STEP_MS);

  it("keeps the draft of an answer that the harness preempted with 412 and sends nothing again", async () => {
    const { requestId, runId } = await startMixed(STALE);
    const handled = new Set<string>();
    let staleDecision = "";
    let harnessCommand = "";
    let recovery = "";
    let stalePosts = 0;
    for (let head = await nextHead(runId, handled); head !== undefined; head = await nextHead(runId, handled)) {
      const { decision, control } = head;
      handled.add(decision.id);
      const before = posts.length;
      if (decision.content.kind === "question") {
        let editors = 0;
        script = {
          editor: async (_title, prefill) => {
            editors += 1;
            expect(prefill).toBeUndefined();
            // The harness answers first while the editor is open.
            harnessCommand = await harnessAnswers(`/v1/decisions/${decision.id}`);
            return "no";
          },
        };
        await run("wfm-answer", runId);
        expect(editors).toBe(1);
        stalePosts = postsTo(`/v1/decisions/${decision.id}`, before).length;
        expect(stalePosts).toBe(1);
        expect(notices.some((line) => line.startsWith("Command answer refused: 412 stale-revision"))).toBe(true);
        expect(notices, notices.join("\n")).toContain(
          `Decision ${decision.id} changed before the answer arrived (412 stale-revision). Nothing was sent again. The draft "no" is kept.`);
        expect(notices.at(-1)).toBe(`Decision ${decision.id} is no longer the pending head (404 unavailable-resource), `
          + `so the kept draft is not sent. /wfm-answer ${runId} acts on the next head.`);
        staleDecision = decision.id;
      } else {
        const offered = offeredChoices(control, decision);
        recovery = staleDecision !== "" && offered.includes("Abandon") ? "Abandon" : "Retry";
        let shown: string[] = [];
        script = {
          select: (_title, options) => {
            shown = options;
            return recovery;
          },
        };
        await run("wfm-answer", runId);
        expect(shown).toEqual(offered);
        expect(notices, notices.join("\n")).toContain(`Recovery ${recovery} reached decision ${decision.id} of run ${runId}.`);
      }
    }
    expect(staleDecision).not.toBe("");
    // Nothing more reached the preempted decision from the extension.
    await new Promise((wake) => setTimeout(wake, 1000));
    expect(postsTo(`/v1/decisions/${staleDecision}`)).toHaveLength(stalePosts);
    // The manager serves only pending decisions, and the queue no longer lists the answered one.
    expect(await session.get(ref(`/v1/decisions/${staleDecision}`))).toEqual({ ok: false, failure: { kind: "Refused", status: 404, code: "unavailable-resource" } });
    const queue = must(await session.get(ref(`/v1/decisions?runId=${runId}`)), "stale queue");
    const listed = jsonMember(queue.value as JsonObject, "items");
    expect(Array.isArray(listed) && listed.some((item) => isJsonObject(item) && jsonMember(item, "id") === staleDecision)).toBe(false);
    Object.assign(report, { staleRequestId: requestId, staleRunId: runId, staleDecisionId: staleDecision, harnessAnswerCommand: harnessCommand, staleRecovery: recovery });
  }, STEP_MS);

  it("cancels a run that waits at its question and reports the receipt and then the runtime acknowledgement", async () => {
    const { requestId, runId } = await startMixed(CANCELLED);
    // The run waits at its person question.
    await nextHead(runId, new Set());
    const control = `/v1/runs/${runId}/control`;
    const before = posts.length;
    const noticed = notices.length;
    const asked: string[] = [];
    script = {
      confirm: (title, message) => {
        asked.push(`${title} ${message}`);
        return true;
      },
    };
    await run("wfm-cancel", runId);
    expect(asked).toEqual([`Cancel manager run? ${runId}`]);
    const sent = postsTo(control, before);
    expect(sent).toHaveLength(1);
    expect(JSON.parse(String(sent[0].body))).toEqual({ operation: "cancel" });
    const cancelCommand = acceptedCommand("cancel");
    const settled = must(decodeCommandReceipt(must(await session.get(ref(cancelCommand)), "cancel receipt").value), "cancel receipt decode");
    const ack = settled.acknowledgement as JsonObject;
    const reported = notices.slice(noticed);
    // The receipt line comes first, and the acknowledgement line follows with the state and the message of the receipt.
    const receiptLine = reported.findIndex((line) => line.startsWith(`Command cancel accepted: command ${settled.id}, receipt `));
    const ackLine = reported.indexOf(`Acknowledgement of command ${settled.id}: ${String(jsonMember(ack, "state"))}: ${String(jsonMember(ack, "message"))}`);
    expect(receiptLine, reported.join("\n")).toBeGreaterThanOrEqual(0);
    expect(ackLine, reported.join("\n")).toBeGreaterThan(receiptLine);
    expect(["accepted", "queued", "delivered"]).toContain(jsonMember(ack, "state"));
    expect(reported.at(-1)).toBe(`Execution: run ${runId} is cancelled.`);
    const terminal = await until(`/v1/runs/${runId}/snapshot`, (observed) => {
      const runtime = isJsonObject(observed.value) ? jsonMember(observed.value, "runtime") : undefined;
      return runtime !== undefined && runtime !== null && isJsonObject(runtime) && jsonMember(runtime, "status") === "cancelled";
    }, `cancelled run ${runId}`);
    expect(jsonMember(jsonMember(terminal.value as JsonObject, "runtime") as JsonObject, "status")).toBe("cancelled");
    Object.assign(report, { cancelledRequestId: requestId, cancelledRunId: runId, cancelCommand });
  }, STEP_MS);

  it("saves the verified result once with mode 0600 and refuses a second save to the same path", async () => {
    const runId = String(report.monitoredRunId);
    const bytes = Number(report.resultBytes);
    const sha256 = String(report.resultSha256);
    // The harness reads the saved file, so it lies beside the report.
    const path = join(REPORT === undefined ? state : dirname(REPORT), "pi-client-ui-saved-result.bin");
    expect(existsSync(path)).toBe(false);
    const titles: string[] = [];
    script = { input: (title) => (titles.push(title), path) };
    const before = posts.length;
    await run("wfm-result", runId);
    expect(titles).toEqual([`Path of a new file for the verified ${bytes} bytes of run ${runId}`]);
    expect(notices.at(-1), notices.join("\n")).toBe(`Saved the verified ${bytes} bytes of run ${runId} to ${path}, SHA-256 ${sha256}.`);
    const saved = readFileSync(path);
    expect(lstatSync(path).isFile() && (lstatSync(path).mode & 0o777)).toBe(0o600);
    expect(saved.length).toBe(bytes);
    expect(createHash("sha256").update(saved).digest("hex")).toBe(sha256);
    // A second save to the same path refuses, and the file keeps its bytes.
    script = {};
    await run("wfm-result", `${runId} ${path}`);
    expect(notices.at(-1)).toMatch(new RegExp(`^The result of run ${runId} was not saved to ${path.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}: EEXIST`));
    expect(readFileSync(path).equals(saved)).toBe(true);
    expect(posts.length).toBe(before);
    Object.assign(report, { savedRunId: runId, savedPath: path });
  }, STEP_MS);

  it("exports the verified result once, shows the published receipt and its verified download, and lists the export", async () => {
    const runId = String(report.monitoredRunId);
    const name = "pi-client-ui-export.json";
    const collection = `/v1/runs/${runId}/exports`;
    const first = must(await session.get(ref(collection)), "export collection");
    expect(must(decodeExportCollection(first.value), "export collection decode").items).toEqual([]);
    script = {};
    const before = posts.length;
    await run("wfm-export", `${runId} ${name}`);
    const sent = posts.slice(before);
    expect(sent.map((post) => [post.resource, String(post.body), post.ifMatch]), notices.join("\n")).toEqual([[collection, JSON.stringify({ name }), first.etag]]);
    const command = acceptedCommand("export");
    const commandId = command.slice("/v1/commands/".length);
    const published = must(decodeExportCollection(must(await session.get(ref(collection)), "published collection").value), "published decode");
    expect(published.items).toHaveLength(1);
    const receipt = published.items[0];
    expect([receipt.id, receipt.commandId, receipt.name, receipt.state]).toEqual([`export_${commandId}`, commandId, name, "published"]);
    const exported = must(await session.download(ref(receipt.download ?? ""), receipt.bytes ?? 0n, receipt.sha256 ?? ""), "export download");
    const shown = notices.slice(-2);
    expect(shown[0], notices.join("\n")).toBe([
      `Export ${name}: export_${commandId} state published, command ${commandId}`,
      `Export download: verified ${exported.length} bytes, SHA-256 ${receipt.sha256}`,
    ].join("\n"));
    expect(shown[1]).toBe(`Exports of run ${runId}: 1\n  ${name}  export_${commandId}  published  ${receipt.bytes} bytes  SHA-256 ${receipt.sha256}`);
    Object.assign(report, {
      exportRunId: runId, exportName: name, exportId: receipt.id, exportCommand: command, exportBytes: exported.length, exportSha256: receipt.sha256,
    });
  }, STEP_MS);

  it("restarts a run through its lineage collection, approves the exact review with its lineage, and the child names its parent", async () => {
    const parent = String(report.literalRunId);
    // The supervision of the parent run has ended.
    await until(`/v1/runs/${parent}`, (observed) => {
      const item = decodeRunItem(observed.value);
      return item.ok && item.value.content.kind === "known" && !["owned", "cleanup-pending"].includes(item.value.content.supervision);
    }, "parent supervision");
    const collection = `/v1/runs/${parent}/lineage-requests`;
    const first = must(await session.get(ref(collection)), "lineage collection");
    let review = "";
    script = {
      review: (screen) => {
        review = screen;
        return "a";
      },
      confirm: () => true,
    };
    const before = posts.length;
    await run("wfm-restart", parent);
    const sent = posts.slice(before);
    expect([sent[0]?.resource, String(sent[0]?.body), sent[0]?.ifMatch]).toEqual([collection, '{"operation":"restart"}', first.etag]);
    const created = notices.find((line) => line.startsWith(`Lineage: restart of run ${parent} created child request `));
    expect(created, notices.join("\n")).toBeDefined();
    const requestId = created?.slice(`Lineage: restart of run ${parent} created child request `.length).split(".")[0] ?? "";
    // The child is enqueued without set-input, and its one approval starts the child run.
    expect(sent.slice(1).map((post) => [post.resource, JSON.parse(String(post.body)).operation])).toEqual([
      [`/v1/requests/${requestId}`, "enqueue"], [expect.stringMatching(/^\/v1\/preparations\//), "approve"],
    ]);
    expect(review.replace(/\s+/g, "")).toContain(`Lineage:restartofrun${parent}`);
    const child = draftOf(must(await session.get(ref(`/v1/requests/${requestId}`)), "child request"));
    expect([child.parentRunId, child.lineage]).toEqual([parent, "restart"]);
    const runId = child.runId ?? "";
    expect(notices, notices.join("\n")).toContain(`Execution: the manager started run ${runId} for request ${requestId}.`);
    await succeeded(runId);
    const item = must(decodeRunItem(must(await session.get(ref(`/v1/runs/${runId}`)), "child run").value), "child run decode");
    expect(item.content.kind === "known" && [item.content.parentRunId, item.content.lineage]).toEqual([parent, "restart"]);
    Object.assign(report, {
      restartParentRunId: parent, restartRequestId: requestId, restartRunId: runId, restartCommand: acceptedCommand("restart"),
      restartPreparationId: sent[2].resource.slice("/v1/preparations/".length),
    });
  }, STEP_MS);

  it("starts, answers and retries a run through the tool only after each human confirmation, and a declined review sends no approve", async () => {
    const results: string[] = [];
    const call = async (params: Record<string, unknown>) => {
      const result = await tool!.execute("live", params, undefined, undefined, ctx);
      results.push(result.content.map((item) => item.text).join("\n"));
      return result;
    };
    const asked: string[] = [];
    const confirm = (answer: boolean) => (title: string, message: string) => (asked.push(`${title}\n${message}`), answer);

    // The human confirms the request and declines its exact review.
    script = { confirm: confirm(true), review: () => "\u001b" };
    const declined = await call({ action: "manager-start", workflow: "mixed-controls", inputsJson: JSON.stringify({ input: TOOL_DECLINED }) });
    expect(declined.isError, results.at(-1)).toBe(true);
    expect(results.at(-1)).toContain("Review declined. No approval was sent.");
    expect(asked.at(-1)).toContain(`input input=${JSON.stringify(TOOL_DECLINED)} (literal)`);
    const declinedRequestId = createdRequest();
    const declinedPreparationId = await preparationOf(declinedRequestId);
    expect(postsTo(`/v1/preparations/${declinedPreparationId}`)).toEqual([]);
    script = { review: () => "d" };
    await run("wfm-review", declinedRequestId);
    script = {};
    await run("wfm-withdraw", declinedRequestId);
    expect(notices, notices.join("\n")).toContain(`Request ${declinedRequestId} is withdrawn.`);

    // The human confirms the request and approves its exact review.
    script = { confirm: confirm(true), review: () => "a" };
    const before = posts.length;
    const started = await call({ action: "manager-start", workflow: "mixed-controls", inputsJson: JSON.stringify({ input: TOOL_ANSWERED }) });
    expect(started.isError, results.at(-1)).not.toBe(true);
    const requestId = createdRequest();
    const request = draftOf(must(await session.get(ref(`/v1/requests/${requestId}`)), "tool request"));
    expect(request.readiness.supplied).toEqual([{ source: "literal", name: "input", value: TOOL_ANSWERED }]);
    const runId = request.runId ?? "";
    expect(results.at(-1)).toContain(`Execution: the manager started run ${runId} for request ${requestId}.`);
    const approvals = posts.slice(before).filter((post) => post.resource.startsWith("/v1/preparations/"));
    expect(approvals.map((post) => JSON.parse(String(post.body)).operation)).toEqual(["approve"]);
    const preparationId = approvals[0].resource.slice("/v1/preparations/".length);

    // The model answers false and retries the recovery, each after a confirmation.
    const handled = new Set<string>();
    let answerCommand = "";
    let retryCommand = "";
    let answeredDecision = "";
    for (let head = await nextHead(runId, handled); head !== undefined; head = await nextHead(runId, handled)) {
      const { decision } = head;
      handled.add(decision.id);
      const from = posts.length;
      script = { confirm: confirm(true) };
      if (decision.content.kind === "question") {
        const answered = await call({ action: "manager-answer", runId, answer: "false" });
        expect(answered.isError, results.at(-1)).not.toBe(true);
        expect(asked.at(-1)).toContain(`Send manager answer?\ndecision=${decision.id}\nrun=${runId}\n`);
        expect(asked.at(-1)).toContain("\nvalue=false");
        const sent = postsTo(`/v1/decisions/${decision.id}`, from);
        expect(sent.map((post) => JSON.parse(String(post.body)))).toEqual([{
          operation: "answer", occurrenceId: decision.occurrenceId.toString(), generation: decision.generation, value: false,
        }]);
        answerCommand = acceptedCommand("answer");
        answeredDecision = decision.id;
      } else {
        const retried = await call({ action: "manager-control", runId, controlKind: "retry" });
        expect(retried.isError, results.at(-1)).not.toBe(true);
        expect(asked.at(-1)).toContain(`Send manager control?\nkind=retry\nrun=${runId}\ndecision=${decision.id}`);
        expect(postsTo(`/v1/runs/${runId}/control`, from).map((post) => JSON.parse(String(post.body)).operation)).toEqual(["retry"]);
        retryCommand = acceptedCommand("retry");
      }
    }
    expect(handled.size).toBe(2);
    await succeeded(runId);
    // No tool result names the bearer, the credential path or the client profile path.
    const fields = JSON.parse(readFileSync(PROFILE ?? "", "utf8")) as { credentialFile: string };
    const bearer = readFileSync(fields.credentialFile, "utf8").trim();
    for (const text of results) {
      for (const secret of [bearer, fields.credentialFile, PROFILE ?? ""]) expect(text).not.toContain(secret);
    }
    Object.assign(report, {
      toolDeclinedRequestId: declinedRequestId, toolDeclinedPreparationId: declinedPreparationId, toolRequestId: requestId, toolRunId: runId,
      toolPreparationId: preparationId, toolAnsweredDecisionId: answeredDecision, toolAnswerCommand: answerCommand, toolRetryCommand: retryCommand,
    });
  }, STEP_MS);

  it("lists every run of the history over all pages in the order of the collection", async () => {
    await run("wfm-history");
    const lines = (notices.at(-1) ?? "").split("\n");
    const listed = must(await session.pageSet(ref("/v1/runs")), "runs").items.map((item) => must(decodeRunItem(item), "run item"));
    expect(lines[0]).toBe(`History: ${listed.length} managed runs and 0 observer entries`);
    expect(lines.slice(1).map((line) => line.trim().split(/\s+/)[0])).toEqual(listed.map((item) => item.id));
    for (const name of ["literalRunId", "capturedRunId", "monitoredRunId", "staleRunId", "cancelledRunId", "restartRunId", "toolRunId"]) {
      expect(listed.map((item) => item.id)).toContain(String(report[name]));
    }
    const line = (runId: unknown) => lines.find((entry) => entry.startsWith(`  ${String(runId)}  `)) ?? "";
    expect(line(report.restartRunId)).toContain(`succeeded, supervision `);
    expect(line(report.restartRunId)).toContain(`restart of run ${String(report.restartParentRunId)}`);
    expect(line(report.cancelledRunId)).toContain("  cancelled, ");
    Object.assign(report, { historyRuns: listed.map((item) => item.id) });
  }, STEP_MS);

  it("closes the extension and writes the report", async () => {
    for (const handler of events.get("session_shutdown") ?? []) await handler({ type: "session_shutdown" }, ctx);
    expect(await status()).toContain("Connection: closed. The manager keeps its runs under its own supervision.");
    if (REPORT !== undefined) writeFileSync(REPORT, `${JSON.stringify(report)}\n`, { mode: 0o600 });
  }, STEP_MS);
});
