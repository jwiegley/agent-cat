/**
 * The live check of the manager session against a running protected
 * manager. It runs only when `AGENT_CAT_MANAGER_PROFILE` names a client
 * profile, as the `pi-client` mode of `manager/test/service_http.py` sets it.
 * When `AGENT_CAT_MANAGER_REPORT` names a file, the last step writes the
 * identifiers and digests of the journey there, and the harness checks each
 * of them against manager facts that it reads with its own credential.
 *
 * The steps run in order and share one session: connect and bootstrap the
 * overview, create a request of the mixed-controls workflow with an exact
 * Unicode literal, set the input, enqueue, read the live preparation,
 * approve the exact review, follow the run through the event stream with
 * one forced drop of the stream, answer the Bool question with JSON false,
 * observe one phase through polling delivery, send the offered retry, wait
 * for terminal success, download and verify the result, and compare every
 * delivered event with the polling listing of the same cursor. The last step
 * starts a second run, which waits at its person question, opens the
 * extension in service mode with a fake Pi host, and closes the extension
 * and the session during their live streams. The harness then confirms over
 * HTTP that the second run is still running under owned supervision.
 */

import { createHash } from "node:crypto";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, describe, expect, it } from "vitest";
import extension from "../src/index.ts";
import { validCursor, type InvalidationEvent, type Outcome } from "../src/manager/events.ts";
import { isJsonArray, isJsonObject, jsonMember, JsonNumber, type JsonObject, type JsonValue } from "../src/manager/json.ts";
import { ClientProfile } from "../src/manager/profile.ts";
import {
  answerBody,
  answerValue,
  decodeCommandReceipt,
  decodeControl,
  decodeDecision,
  decodeDraftView,
  decodePreparation,
  type CommandReceipt,
  type DraftView,
} from "../src/manager/resources.ts";
import { ManagerSession, type Observed, type Overview, type Reference } from "../src/manager/session.ts";
import type { Delivery } from "../src/manager/transport.ts";

const PROFILE = process.env.AGENT_CAT_MANAGER_PROFILE;
const REPORT = process.env.AGENT_CAT_MANAGER_REPORT;

/** The exact literal input, as `MIXED_TEXT` of the harness states it. */
const LITERAL = "Café λ — explicit false.\nSecond line.";

/** The timeout of each step. */
const STEP_MS = 600_000;

/** The longest wait for one manager fact. */
const WAIT_MS = 120_000;

const TERMINAL = ["succeeded", "failed", "cancelled"];
const SELECTORS = ["reviewDigest", "requestRevision", "profileRevision", "descriptorRevision", "processGeneration"] as const;

function must<Value>(outcome: Outcome<Value>, step: string): Value {
  if (!outcome.ok) throw new Error(`${step}: ${JSON.stringify(outcome.failure)}`);
  return outcome.value;
}

function object(value: JsonValue | undefined, step: string): JsonObject {
  if (value === undefined || !isJsonObject(value)) throw new Error(`${step}: not an object`);
  return value;
}

function text(value: JsonValue | undefined, step: string): string {
  if (typeof value !== "string") throw new Error(`${step}: not a text`);
  return value;
}

function items(value: JsonValue | undefined, step: string): readonly JsonValue[] {
  if (value === undefined || !isJsonArray(value)) throw new Error(`${step}: not an array`);
  return value;
}

/** The runtime status of a run snapshot, or null. */
function runtimeStatus(observed: Observed): string | null {
  const runtime = jsonMember(object(observed.value, "run snapshot"), "runtime");
  return runtime === null || runtime === undefined ? null : text(jsonMember(object(runtime, "runtime"), "status"), "runtime status");
}

type Seen = { readonly id: string; readonly resource: string; readonly via: Delivery };

describe.runIf(PROFILE)("manager session against a live manager", () => {
  let session: ManagerSession;
  let bootstrap: Overview;
  const delivered: Seen[] = [];
  const connections: { readonly via: Delivery; readonly cursor: string }[] = [];
  let workflow: JsonObject;
  let request: DraftView;
  let requestRef: Reference;
  let run = "";
  let answerCommand = "";
  let retryCommand = "";
  let reconnect = { cursor: "", connection: "" };
  let polled = 0;
  let polledFrom = 0;
  let pollConnections = 0;
  let result = { bytes: 0, sha256: "" };
  let report: Record<string, unknown> = {};

  const ref = (uri: string): Reference => must(session.reference(uri), `reference ${uri}`);

  /** Send one command once and give its receipt and location. A send that is not delivered fails the step. */
  async function command(uri: string, body: JsonValue, ifMatch: string | null): Promise<{ receipt: CommandReceipt; location: Reference }> {
    const pending = must(session.prepare(ref(uri), body, ifMatch), `prepare ${uri}`);
    const sent = await session.send(pending);
    if (sent.kind !== "delivered" || sent.receipt === null) throw new Error(`send ${uri}: ${JSON.stringify(sent)}`);
    return { receipt: sent.receipt, location: sent.location };
  }

  /** Wait through the session until the receipt reaches effect-observed. */
  async function effected(location: Reference, step: string): Promise<void> {
    const settled = await session.waitFor(location, (observed) => {
      const receipt = decodeCommandReceipt(observed.value);
      return receipt.ok && ["effect-observed", "refused", "unresolved"].includes(receipt.value.state);
    }, WAIT_MS);
    expect(must(decodeCommandReceipt(must(settled, step).value), step).state, step).toBe("effect-observed");
  }

  async function currentRequest(): Promise<Observed> {
    return must(await session.get(requestRef), "request read");
  }

  afterAll(async () => {
    await session?.close();
  });

  it("connects and bootstraps the overview", async () => {
    const profile = must(await ClientProfile.load(PROFILE ?? ""), "profile");
    session = must(await ManagerSession.connect(profile, {
      delivery: "sse",
      onEvent: (event: InvalidationEvent, via) => delivered.push({ id: event.id, resource: event.data.resource, via }),
      onConnect: (via, cursor) => connections.push({ via, cursor }),
    }), "connect");
    expect(session.epoch).toMatch(/^[A-Za-z0-9_-]+$/);
    bootstrap = must(await session.start(), "overview");
    expect(validCursor(bootstrap.cursor)).toBe(true);
    expect(validCursor(bootstrap.oldestCursor)).toBe(true);
    expect(connections[0]).toEqual({ via: "stream", cursor: bootstrap.cursor });
  }, STEP_MS);

  it("creates a request with the exact literal, sets its input and enqueues it", async () => {
    const profileId = text(items(jsonMember(session.capabilities, "profileIds"), "profiles")[0], "profile");
    const catalogue = must(await session.get(ref(`/v1/workflows?profileId=${profileId}`)), "catalogue");
    workflow = object(items(jsonMember(object(catalogue.value, "catalogue"), "items"), "catalogue items")
      .find((item) => isJsonObject(item) && jsonMember(item, "name") === "mixed-controls"), "mixed-controls workflow");
    const body: JsonObject = {
      workflowId: text(jsonMember(workflow, "id"), "workflow id"),
      descriptorRevision: text(jsonMember(workflow, "revision"), "descriptor revision"),
      profileId: text(jsonMember(workflow, "profileId"), "profile"),
      profileRevision: text(jsonMember(workflow, "profileRevision"), "profile revision"),
    };
    const pending = must(session.prepare(ref("/v1/requests"), body, null), "prepare create");
    const created = await session.send(pending);
    if (created.kind !== "delivered") throw new Error(`create: ${JSON.stringify(created)}`);
    expect(created.response.status).toBe(201);
    request = must(decodeDraftView(created.response.value), "created request");
    expect(request.phase).toBe("draft");
    expect(created.location.uri).toBe(`/v1/requests/${request.id}`);
    requestRef = created.location;
    for (const declaration of items(jsonMember(workflow, "inputs"), "inputs")) {
      const name = text(jsonMember(object(declaration, "input"), "name"), "input name");
      const current = await currentRequest();
      const set = await command(requestRef.uri, { operation: "set-input", input: { name, source: "literal", value: LITERAL } }, current.etag);
      await effected(set.location, `set-input ${name}`);
    }
    const supplied = await currentRequest();
    const draft = must(decodeDraftView(supplied.value), "supplied request");
    expect(draft.readiness.missing).toEqual([]);
    expect(draft.readiness.supplied.map((input) => input.source === "literal" && input.value)).toEqual(
      draft.readiness.supplied.map(() => LITERAL));
    const enqueue = await command(requestRef.uri, { operation: "enqueue" }, supplied.etag);
    await effected(enqueue.location, "enqueue");
  }, STEP_MS);

  it("reads the live preparation and approves the exact review", async () => {
    const prepared = must(await session.waitFor(requestRef, (observed) => {
      const draft = decodeDraftView(observed.value);
      return draft.ok && draft.value.preparationId !== null;
    }, WAIT_MS), "request preparation");
    const preparationId = must(decodeDraftView(prepared.value), "prepared request").preparationId ?? "";
    const preparationRef = ref(`/v1/preparations/${preparationId}`);
    const live = must(await session.waitFor(preparationRef, (observed) => {
      const preparation = decodePreparation(observed.value);
      return preparation.ok && preparation.value.state === "live";
    }, WAIT_MS), "live preparation");
    const preparation = must(decodePreparation(live.value), "preparation");
    expect(preparation.requestId).toBe(request.id);
    const declarations = items(jsonMember(workflow, "inputs"), "inputs").map((item) => object(item, "input"));
    for (const input of preparation.review.inputs) {
      const declaration = declarations.find((item) => jsonMember(item, "name") === input.name);
      const expected = Buffer.from(LITERAL + (declaration !== undefined && jsonMember(declaration, "source") === "prompt" ? "\n" : ""), "utf8");
      expect([input.source, input.bytes, input.sha256]).toEqual(
        ["literal", BigInt(expected.length), createHash("sha256").update(expected).digest("hex")]);
    }
    const selectors = object(live.value, "preparation value");
    const approve = await command(preparationRef.uri,
      { operation: "approve", ...Object.fromEntries(SELECTORS.map((name) => [name, text(jsonMember(selectors, name), name)])) }, live.etag);
    expect(approve.receipt.operation).toBe("approve");
    const associated = must(await session.waitFor(requestRef, (observed) => {
      const draft = decodeDraftView(observed.value);
      return draft.ok && draft.value.runId !== null;
    }, WAIT_MS), "associated run");
    run = must(decodeDraftView(associated.value), "associated request").runId ?? "";
    expect(run).not.toBe("");
  }, STEP_MS);

  it("follows the run through the stream, answers false, polls one phase, retries and succeeds", async () => {
    const snapshotRef = ref(`/v1/runs/${run}/snapshot`);
    const controlRef = ref(`/v1/runs/${run}/control`);
    must(session.watch(snapshotRef), "watch snapshot");
    must(session.watch(controlRef), "watch control");
    // One forced drop of the stream, after the stream delivered an event of the run.
    const runEvent = must(await until(() => delivered.some((seen) => seen.via === "stream" && seen.resource.startsWith(`/v1/runs/${run}`))), "run event");
    expect(runEvent).toBe(true);
    const before = connections.length;
    const last = delivered[delivered.length - 1];
    reconnect = { cursor: last.id, connection: "" };
    session.forceReconnect();
    must(await until(() => connections.length > before), "reconnection");
    expect(connections[before]).toEqual({ via: "stream", cursor: last.id });
    reconnect = { cursor: last.id, connection: connections[before].cursor };
    const handled = new Set<string>();
    let phase = "first";
    while (handled.size < 2) {
      const control = must(await session.waitFor(controlRef, (observed) => {
        const view = decodeControl(observed.value);
        return view.ok && view.value.decisionHeadId !== null && !handled.has(view.value.decisionHeadId);
      }, WAIT_MS), `decision head after ${phase}`);
      const controlView = must(decodeControl(control.value), "control");
      const head = controlView.decisionHeadId ?? "";
      handled.add(head);
      if (session.delivery === "poll") {
        // The polling phase began before the command of the first head, and
        // it ends when it has observed the next head. Every delivery of the
        // phase is a polling batch, and the batches named the run.
        const phaseEvents = delivered.slice(polledFrom);
        polled = phaseEvents.length;
        expect(polled).toBeGreaterThan(0);
        expect(phaseEvents.every((seen) => seen.via === "poll")).toBe(true);
        expect(phaseEvents.some((seen) => seen.resource.startsWith(`/v1/runs/${run}`))).toBe(true);
        expect(connections.slice(pollConnections).every((connection) => connection.via === "poll")).toBe(true);
        session.setDelivery("sse");
      }
      const decisionRef = ref(`/v1/decisions/${head}`);
      const observed = must(await session.waitFor(decisionRef, (value) => {
        const decision = decodeDecision(value.value);
        return decision.ok && decision.value.state === "pending";
      }, WAIT_MS), "pending decision");
      const decision = must(decodeDecision(observed.value), "decision");
      expect([decision.runId, decision.position]).toEqual([run, 0]);
      if (handled.size === 1) {
        polledFrom = delivered.length;
        pollConnections = connections.length;
        session.setDelivery("poll");
      }
      if (decision.content.kind === "question") {
        const answer = answerValue(decision, "false");
        if (!answer.ok) throw new Error(`answer refused: ${answer.failure.reason}`);
        expect(answer.value).toBe(false);
        const sent = await command(decisionRef.uri, answerBody(decision, answer.value), observed.etag);
        answerCommand = sent.location.uri;
        await effected(sent.location, "answer");
        phase = "answer";
      } else {
        const offer = controlView.offers.find((item) => item.operation === "retry" && item.occurrenceId === decision.occurrenceId
          && item.generation === decision.generation);
        expect(offer).toBeDefined();
        const sent = await command(controlRef.uri,
          { operation: "retry", occurrenceId: decision.occurrenceId.toString(), generation: decision.generation }, control.etag);
        retryCommand = sent.location.uri;
        await effected(sent.location, "retry");
        phase = "retry";
      }
    }
    expect(session.delivery).toBe("sse");
    const terminal = must(await session.waitFor(snapshotRef, (observed) => TERMINAL.includes(runtimeStatus(observed) ?? ""), WAIT_MS),
      "terminal run");
    expect(runtimeStatus(terminal)).toBe("succeeded");
    expect(connections.slice(pollConnections).some((connection) => connection.via === "stream")).toBe(true);
    expect([answerCommand, retryCommand].every((uri) => uri.startsWith("/v1/commands/"))).toBe(true);
  }, STEP_MS);

  it("downloads the result and verifies its size and SHA-256", async () => {
    const outputs = must(await session.get(ref(`/v1/runs/${run}/outputs`)), "outputs");
    const output = object(items(jsonMember(object(outputs.value, "outputs"), "items"), "output items")
      .find((item) => isJsonObject(item) && jsonMember(item, "kind") === "result"), "result output");
    expect(text(jsonMember(object(jsonMember(output, "verification"), "verification"), "state"), "verification")).toBe("verified");
    const artifact = object(jsonMember(output, "artifact"), "artifact");
    const size = jsonMember(artifact, "bytes");
    const stated = typeof size === "string" ? BigInt(size) : size instanceof JsonNumber ? BigInt(size.source) : -1n;
    const sha256 = text(jsonMember(artifact, "sha256"), "sha256");
    const bytes = must(await session.download(ref(text(jsonMember(artifact, "download"), "download")), stated, sha256), "download");
    expect(BigInt(bytes.length)).toBe(stated);
    expect(createHash("sha256").update(bytes).digest("hex")).toBe(sha256);
    result = { bytes: bytes.length, sha256 };
  }, STEP_MS);

  it("delivered every event of the polling listing once and in order", async () => {
    const listing: string[] = [];
    let cursor = bootstrap.cursor;
    for (let page = 0; page < 1024; page += 1) {
      const batch = must(await session.pollEvents(cursor), "event listing");
      listing.push(...batch.events.map((event) => event.id));
      cursor = batch.cursor;
      if (!batch.hasMore) break;
    }
    const ids = delivered.map((seen) => seen.id);
    expect(new Set(ids).size).toBe(ids.length);
    expect(listing.length).toBeGreaterThanOrEqual(ids.length);
    expect(ids).toEqual(listing.slice(0, ids.length));
    report = {
      requestId: request.id, runId: run, answerCommand, retryCommand, resultBytes: result.bytes, resultSha256: result.sha256,
      events: ids.length, pollEvents: polled, reconnectCursor: reconnect.cursor, reconnectLastEventId: reconnect.connection,
    };
  }, STEP_MS);

  it("starts a second run and closes the extension and the session during their live streams", async () => {
    // The second run of the same workflow waits at its person question.
    const created = await session.send(must(session.prepare(ref("/v1/requests"), {
      workflowId: text(jsonMember(workflow, "id"), "workflow id"),
      descriptorRevision: text(jsonMember(workflow, "revision"), "descriptor revision"),
      profileId: text(jsonMember(workflow, "profileId"), "profile"),
      profileRevision: text(jsonMember(workflow, "profileRevision"), "profile revision"),
    }, null), "prepare second create"));
    if (created.kind !== "delivered") throw new Error(`second create: ${JSON.stringify(created)}`);
    const second = must(decodeDraftView(created.response.value), "second request");
    const secondRef = created.location;
    for (const declaration of items(jsonMember(workflow, "inputs"), "inputs")) {
      const name = text(jsonMember(object(declaration, "input"), "name"), "input name");
      const current = must(await session.get(secondRef), "second request read");
      const set = await command(secondRef.uri, { operation: "set-input", input: { name, source: "literal", value: LITERAL } }, current.etag);
      await effected(set.location, `second set-input ${name}`);
    }
    const supplied = must(await session.get(secondRef), "second supplied request");
    await effected((await command(secondRef.uri, { operation: "enqueue" }, supplied.etag)).location, "second enqueue");
    const prepared = must(await session.waitFor(secondRef, (observed) => {
      const draft = decodeDraftView(observed.value);
      return draft.ok && draft.value.preparationId !== null;
    }, WAIT_MS), "second preparation");
    const preparationRef = ref(`/v1/preparations/${must(decodeDraftView(prepared.value), "second prepared").preparationId ?? ""}`);
    const live = must(await session.waitFor(preparationRef, (observed) => {
      const preparation = decodePreparation(observed.value);
      return preparation.ok && preparation.value.state === "live";
    }, WAIT_MS), "second live preparation");
    const selectors = object(live.value, "second preparation value");
    await command(preparationRef.uri,
      { operation: "approve", ...Object.fromEntries(SELECTORS.map((name) => [name, text(jsonMember(selectors, name), name)])) }, live.etag);
    const associated = must(await session.waitFor(secondRef, (observed) => {
      const draft = decodeDraftView(observed.value);
      return draft.ok && draft.value.runId !== null;
    }, WAIT_MS), "second run");
    const secondRun = must(decodeDraftView(associated.value), "second associated").runId ?? "";
    must(await session.waitFor(ref(`/v1/runs/${secondRun}/control`), (observed) => {
      const view = decodeControl(observed.value);
      return view.ok && view.value.decisionHeadId !== null;
    }, WAIT_MS), "second question");

    // The extension opens one manager session on the same profile and shows the run live.
    const state = mkdtempSync(join(tmpdir(), "agent-cat-pi-client-state-"));
    const previousState = process.env.AGENT_CAT_STATE_DIR;
    process.env.AGENT_CAT_STATE_DIR = state;
    try {
      const commands = new Map<string, { handler: (args: string, ctx: unknown) => Promise<void> }>();
      const events = new Map<string, Array<(event: unknown, ctx: unknown) => Promise<unknown>>>();
      const notices: string[] = [];
      extension({
        registerEntryRenderer: () => {}, registerTool: () => {}, appendEntry: () => {}, sendUserMessage: () => {},
        registerCommand: (name: string, value: unknown) => commands.set(name, value as never),
        on: (name: string, handler: (event: unknown, ctx: unknown) => Promise<unknown>) => events.set(name, [...(events.get(name) ?? []), handler]),
      } as never);
      const ctx = {
        cwd: state, mode: "tui", hasUI: true, isProjectTrusted: () => true,
        ui: { notify: (message: string) => notices.push(message), setWidget: () => {}, setStatus: () => {} },
      };
      const fire = async (name: string) => {
        for (const handler of events.get(name) ?? []) await handler({ type: name }, ctx);
      };
      const status = async (): Promise<string> => {
        await commands.get("wfm-status")!.handler("", ctx);
        return notices.at(-1) ?? "";
      };
      await fire("session_start");
      const deadline = Date.now() + WAIT_MS;
      let shown = await status();
      while (!(shown.includes("delivery live") && shown.includes(`  ${secondRun}  running  owned supervision`))) {
        if (Date.now() > deadline) throw new Error(`the extension did not show the second run live: ${shown}`);
        await new Promise((wake) => setTimeout(wake, 100));
        shown = await status();
      }
      expect(shown).toContain("Decision heads:\n  ");
      expect(shown).toContain(`run ${secondRun}`);
      await fire("session_shutdown");
      expect(await status()).toContain("Connection: closed. The manager keeps its runs under its own supervision.");
    } finally {
      if (previousState === undefined) delete process.env.AGENT_CAT_STATE_DIR;
      else process.env.AGENT_CAT_STATE_DIR = previousState;
      rmSync(state, { recursive: true, force: true });
    }

    // The session of the check closes during its live stream as well.
    expect(session.deliveryState).toBe("live");
    await session.close();
    expect(session.closed).toBe(true);
    if (REPORT !== undefined) {
      writeFileSync(REPORT, `${JSON.stringify({ ...report, secondRequestId: second.id, secondRunId: secondRun })}\n`, { mode: 0o600 });
    }
  }, STEP_MS);
});

/** Wait until the condition holds, checking every 50 milliseconds, for at most `WAIT_MS`. */
function until(condition: () => boolean): Promise<Outcome<boolean>> {
  const deadline = Date.now() + WAIT_MS;
  return new Promise((resolve) => {
    const check = () => {
      if (condition()) resolve({ ok: true, value: true });
      else if (Date.now() > deadline) resolve({ ok: false, failure: { kind: "TransportUnavailable" } });
      else setTimeout(check, 50);
    };
    check();
  });
}
