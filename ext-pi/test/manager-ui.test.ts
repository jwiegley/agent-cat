import { lstatSync, mkdtempSync, readdirSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { visibleWidth } from "@earendil-works/pi-tui";
import { describe, expect, it, vi } from "vitest";
import {
  acknowledgementLine,
  answerObserved,
  controlPassed,
  exportLines,
  forkTargets,
  saveExact,
  admissionLine,
  cancelOffered,
  controlSettled,
  recoveryActions,
  redirectOffers,
  redirectPlace,
  steerOffers,
  ReviewComponent,
  reviewLines,
  serviceMonitorLines,
  ServiceMonitorComponent,
  type MonitorState,
  type ReviewChoice,
  type ServiceMonitor,
} from "../src/manager-ui.ts";
import { parseJson, type JsonObject } from "../src/manager/json.ts";
import {
  decodeCommandReceipt,
  decodeControl,
  decodeDecision,
  decodeExportCollection,
  decodeLineageCollection,
  forkReplacementValue,
  lineageBody,
  storedAnswerText,
  type CommandReceipt,
  type ControlView,
  type DecisionView,
  type DraftView,
  type Preparation,
} from "../src/manager/resources.ts";

const DIGEST = "a".repeat(64);

function preparation(): Preparation {
  return {
    id: "prep_1", revision: "rev_p", requestId: "req_1", requestRevision: "rev_r", profileId: "profile_1", profileRevision: "rev_profile",
    descriptorRevision: "rev_d", state: "live", expiresAt: "2026-10-01T12:00:00Z", reviewDigest: DIGEST, processGeneration: "gen_7",
    reason: null,
    review: {
      programHash: "b".repeat(64), personAnswering: "local-control", policy: { kind: "scripted" }, workflowId: "wf_1",
      profileId: "profile_1", workspaceLabel: "Workspace Café", targetLabel: "Deterministic scripted",
      inputs: [{ name: "input", source: "capture", bytes: 23n, sha256: "c".repeat(64) }],
      plan: "step one asks the model\nstep two stops", runFacts: ["routes"], pins: ["deep"], warnings: [],
      resultCode: "text", lineage: { parentRunId: "run_1", operation: "fork", edits: [{ operation: "drop", occurrenceId: 4n }] },
    },
  };
}

describe("manager review", () => {
  it("lists every approval selector and every consent fact of the review", () => {
    const lines = reviewLines(preparation(), '"etag-1"');
    for (const expected of [
      `  reviewDigest: ${DIGEST}`, "  requestRevision: rev_r", "  profileRevision: rev_profile", "  descriptorRevision: rev_d",
      "  processGeneration: gen_7", '  If-Match: "etag-1"', `Program SHA-256: ${"b".repeat(64)}`, "Person answering: local-control",
      "Workflow: wf_1", "Profile: profile_1", "Workspace: Workspace Café", "Target: Deterministic scripted", 'Policy: {"kind":"scripted"}',
      'Result code: "text"', `  input: capture, 23 bytes, SHA-256 ${"c".repeat(64)}`, "  step one asks the model", "  step two stops",
      "Run facts: routes", "Pins: deep", "Warnings: none", "Lineage: fork of run run_1", "  drop occurrence 4",
    ]) expect(lines).toContain(expected);
  });

  it("wraps and scrolls the complete review and ends with the choice of a key", () => {
    const requestRender = vi.fn();
    const tui = { terminal: { rows: 12 }, requestRender } as never;
    const theme = { fg: (_color: string, value: string) => value } as never;
    const lines = reviewLines(preparation(), '"etag-1"');
    const choices: ReviewChoice[] = [];
    const component = new ReviewComponent(tui, theme, lines, (choice) => choices.push(choice));
    const shown: string[] = [];
    for (let step = 0; step < 80; step += 1) {
      const rendered = component.render(40);
      expect(rendered.every((line) => visibleWidth(line) <= 40)).toBe(true);
      shown.push(rendered[0]);
      component.handleInput("j");
    }
    // Every wrapped line of the review is reachable, and nothing is cut.
    expect(shown.join("").replace(/\s+/g, "")).toContain(DIGEST);
    expect(component.render(40).join(" ").replace(/\s+/g, " ")).toContain("a approve after confirmation, d discard, w withdraw");
    for (const key of ["a", "d", "w", "q", "\u001b"]) component.handleInput(key);
    expect(choices).toEqual(["approve", "discard", "withdraw", "decline", "decline"]);
    expect(requestRender).toHaveBeenCalled();
  });

  it("states the phase, the admission, the queue position and the blocking reasons of a request", () => {
    const request = {
      id: "req_1", phase: "queued", admission: { state: "waiting", position: 2, reasons: ["capacity", "profile-busy"] },
      readiness: { declarations: [], supplied: [], missing: [], errors: [] },
    } as unknown as DraftView;
    expect(admissionLine(request)).toBe("Request req_1: queued, admission waiting, queue position 2, waiting for capacity, profile-busy");
  });
});

/** A decision of run_21 from its wire JSON. */
function decisionOf(fields: Record<string, unknown>): DecisionView {
  const decoded = decodeDecision(parseJson(JSON.stringify({
    version: 1, id: "decision_3", revision: "decisionrev_1", runId: "run_21", profileId: "profile_main", generation: "generation_3",
    address: { occurrenceId: "0" }, state: "pending", position: 0, observedSequence: "9", queue: "/v1/decisions?runId=run_21", ...fields,
  })));
  if (!decoded.ok) throw new Error(JSON.stringify(decoded.failure));
  return decoded.value;
}

const QUESTION = {
  kind: "question",
  question: {
    code: "flag", semanticSchema: "boolean", editorSchema: null, addressee: "person owner", scope: { model: null, mode: null }, draw: "0",
    prompt: "Independent confirmation?\nSecond line.",
  },
};

const RECOVERY = {
  kind: "recovery", gap: "transport", message: "Recovery needs an operator choice.",
  choices: [{ choice: "retry", target: null }, { choice: "failover", target: "spare" }, { choice: "abandon", target: null }],
};

function offer(operation: string, choices: unknown[] = []): unknown {
  return { operation, address: { occurrenceId: "0" }, generation: "generation_3", timings: [], choices, targets: [] };
}

function controlOf(offers: unknown[], fields: Record<string, unknown> = {}): ControlView {
  const decoded = decodeControl(parseJson(JSON.stringify({
    version: 1, runId: "run_21", revision: "controlrev_2", supervision: "owned", cancelAllowed: true, offers, decisionHeadId: "decision_3", ...fields,
  })));
  if (!decoded.ok) throw new Error(JSON.stringify(decoded.failure));
  return decoded.value;
}

function snapshotOf(status: string | null, fields: Record<string, unknown> = {}): JsonObject {
  return parseJson(JSON.stringify({
    runId: "run_21", workflow: "mixed-controls", runtime: status === null ? null : { status, lastSequence: "9", protocolVersion: 2 },
    supervision: "owned", verification: { state: status === "succeeded" ? "verified" : "absent" }, failure: null, failureClass: null, ...fields,
  })) as JsonObject;
}

function stateOf(fields: Partial<MonitorState>): MonitorState {
  return {
    runId: "run_21", delivery: "live", snapshot: { value: snapshotOf("running"), failure: undefined },
    control: { value: controlOf([offer("answer")]), failure: undefined }, queue: { value: [decisionOf(QUESTION)], failure: undefined },
    result: { kind: "none" }, ...fields,
  };
}

describe("reconciliation of an answer or a recovery choice", () => {
  const question = (code: unknown, semanticSchema: unknown = null) => decisionOf({ kind: "question", question: { ...QUESTION.question, code, semanticSchema } });

  it("names the answer text that the runtime stores only when that text names the sent value exactly", () => {
    expect(storedAnswerText(question("flag"), false)).toBe("no");
    expect(storedAnswerText(question("flag"), true)).toBe("yes");
    expect(storedAnswerText(question("receipt"), null)).toBe("done");
    expect(storedAnswerText(question("text"), "Café λ")).toBe("Café λ");
    expect(storedAnswerText(question("text"), "λ".repeat(500))).toBe("λ".repeat(500));
    expect(storedAnswerText(question("verdict"), { tag: "approve" })).toBe("approve");
    expect(storedAnswerText(question("verdict"), { tag: "declined" })).toBe("declined");
    expect(storedAnswerText(question("verdict"), { tag: "object", objections: ["too long", "no tests"] })).toBe("too long; no tests");
    // The runtime changes or cuts these texts, or another answer stores the same text.
    for (const [code, value] of [
      ["text", "two\nlines"], ["text", " padded"], ["text", "tab\t"], ["text", "λ".repeat(501)], ["flag", "no"], ["receipt", ""],
      ["verdict", { tag: "object", objections: ["a; b"] }], ["verdict", { tag: "object", objections: ["approve"] }],
      ["verdict", { tag: "object", objections: [] }], ["verdict", { tag: "approve", objections: [] }],
    ] as const) expect(storedAnswerText(question(code), value as never), `${code} ${JSON.stringify(value)}`).toBeUndefined();
    expect(storedAnswerText(question({ json: { schema: "boolean" } }, "boolean"), true)).toBeUndefined();
    expect(storedAnswerText(decisionOf(RECOVERY), null)).toBeUndefined();
  });

  it("sees an answer in the snapshot only when the occurrence stopped waiting and stores exactly the sent answer", () => {
    const decision = decisionOf(QUESTION);
    const snapshot = (occurrence: Record<string, unknown>) => parseJson(JSON.stringify({
      items: [{ occurrenceId: "1", state: "completed", answer: "no", decisionId: "decision_9", personPending: false },
        { occurrenceId: "0", state: "running", answer: null, decisionId: "decision_3", personPending: true, ...occurrence }],
    }));
    expect(answerObserved(snapshot({ state: "completed", answer: "no", personPending: false }), decision, "no")).toBe(true);
    expect(answerObserved(snapshot({ state: "completed", answer: "yes", personPending: false }), decision, "no")).toBe(false);
    expect(answerObserved(snapshot({ answer: "no" }), decision, "no")).toBe(false);
    expect(answerObserved(snapshot({ state: "failed", answer: "no", personPending: false }), decision, "no")).toBe(false);
    expect(answerObserved(parseJson('{"items":[]}'), decision, "no")).toBe(false);
  });

  it("sees an answer in the controls only for a running run with a later head, and a recovery choice for any other head", () => {
    const decision = decisionOf(QUESTION);
    const controls = (fields: Record<string, unknown>) => controlOf([], fields).value;
    expect(controlPassed(controls({ decisionHeadId: "decision_4" }), decision, "answer")).toBe(true);
    expect(controlPassed(controls({}), decision, "answer")).toBe(false);
    expect(controlPassed(controls({ decisionHeadId: null }), decision, "answer")).toBe(false);
    expect(controlPassed(controls({ decisionHeadId: "decision_4", cancelAllowed: false }), decision, "answer")).toBe(false);
    expect(controlPassed(controls({ decisionHeadId: null, cancelAllowed: false }), decision, "recovery")).toBe(true);
    expect(controlPassed(controls({ decisionHeadId: "decision_4" }), decision, "recovery")).toBe(true);
    expect(controlPassed(controls({ cancelAllowed: false }), decision, "recovery")).toBe(false);
    expect(controlPassed(parseJson('{"version":1}'), decision, "recovery")).toBe(false);
  });
});

describe("manager decisions and the live monitor", () => {
  it("offers only the recovery choices that the manager offers for the head decision", () => {
    const recovery = decisionOf(RECOVERY);
    const actions = recoveryActions(controlOf([offer("retry"), offer("choose-recovery", [{ choice: "abandon", target: null }])]), recovery);
    expect(actions.map((action) => [action.label, action.operation])).toEqual([["Retry", "retry"], ["Abandon", "choose-recovery"]]);
    // A fail-over offer names its target, and a choice without an offer is not listed.
    expect(recoveryActions(controlOf([offer("choose-recovery", [{ choice: "failover", target: "spare" }])]), recovery)
      .map((action) => action.label)).toEqual(["Fail over to spare"]);
    // Controls of another head, a lost run or another generation offer nothing.
    expect(recoveryActions(controlOf([offer("retry")], { decisionHeadId: "decision_4" }), recovery)).toEqual([]);
    expect(recoveryActions(controlOf([offer("retry")], { supervision: "lost" }), recovery)).toEqual([]);
    expect(recoveryActions(controlOf([{ ...(offer("retry") as object), generation: "generation_2" }]), recovery)).toEqual([]);
    expect(recoveryActions(controlOf([offer("retry")]), decisionOf(QUESTION))).toEqual([]);
  });

  it("states the runtime status, the freshness, the decisions and the offers of a running run", () => {
    const lines = serviceMonitorLines(stateOf({}));
    expect(lines).toEqual([
      "Service run run_21, workflow mixed-controls", "Delivery: live", "Observation: current", "Runtime: running", "Decisions: 1 pending",
      "  Head decision_3: pending question (flag: yes, no, true or false): Independent confirmation? Second line.",
      "Offers: answer, cancel",
    ]);
    const recovery = serviceMonitorLines(stateOf({ queue: { value: [decisionOf(RECOVERY)], failure: undefined } }));
    expect(recovery).toContain("  Head decision_3: pending recovery (transport): Recovery needs an operator choice.; choices Retry, Fail over to spare, Abandon");
    // A failed read keeps the last complete observation and names the failure.
    const stale = serviceMonitorLines(stateOf({ snapshot: { value: snapshotOf("running", { supervision: "lost" }), failure: "429 storage-quota" } }));
    expect(stale).toContain("Observation: stale (429 storage-quota); the last complete observation is retained");
    expect(stale).toContain("Runtime: running; supervision lost");
    expect(serviceMonitorLines(stateOf({ snapshot: { value: undefined, failure: "TransportUnavailable" } })))
      .toContain("Observation: refused (TransportUnavailable); no complete observation is installed");
    expect(serviceMonitorLines(stateOf({ snapshot: { value: snapshotOf(null), failure: undefined } }))).toContain("Runtime: not yet observed");
    expect(serviceMonitorLines(stateOf({})).some((line) => line.startsWith("Terminal:"))).toBe(false);
  });

  it("ends a terminal run with the Terminal line and the Result lines", () => {
    const succeeded = { snapshot: { value: snapshotOf("succeeded"), failure: undefined }, queue: { value: [], failure: undefined } };
    expect(serviceMonitorLines(stateOf({ ...succeeded, result: { kind: "verified", bytes: 81, sha256: "d".repeat(64) } })).slice(-5)).toEqual([
      "Decisions: none pending", "Offers: answer, cancel", "Terminal: succeeded", "Result: verified 81 bytes", `Result SHA-256: ${"d".repeat(64)}`,
    ]);
    expect(serviceMonitorLines(stateOf({ ...succeeded, result: { kind: "retrieving" } })).at(-1)).toBe("Result: retrieving the verified bytes");
    expect(serviceMonitorLines(stateOf({ ...succeeded, result: { kind: "failed", code: "DigestMismatch" } })).at(-1))
      .toBe("Result: not retrieved (DigestMismatch); the next change of the run retries");
    const absent = snapshotOf("succeeded", { verification: { state: "absent" } });
    expect(serviceMonitorLines(stateOf({ snapshot: { value: absent, failure: undefined } })).at(-1)).toBe("Result: no download; verification is absent");
    const failed = snapshotOf("failed", { failure: "abandoned\nby the operator", failureClass: "recovery" });
    expect(serviceMonitorLines(stateOf({ snapshot: { value: failed, failure: undefined } })).slice(-3)).toEqual([
      "Terminal: failed", "Failure: recovery: abandoned by the operator", "Result: no download for a run that did not succeed",
    ]);
  });

  it("keeps the Terminal and Result lines in view at a small height and closes with q", () => {
    const requestRender = vi.fn();
    const tui = { terminal: { rows: 12 }, requestRender } as never;
    const theme = { fg: (_color: string, value: string) => value } as never;
    const queue = Array.from({ length: 20 }, (_, index) => decisionOf({ ...QUESTION, id: `decision_${index + 3}`, position: index }));
    const state = stateOf({
      snapshot: { value: snapshotOf("succeeded"), failure: undefined }, queue: { value: queue, failure: undefined },
      result: { kind: "verified", bytes: 81, sha256: "d".repeat(64) },
    });
    const monitor = { state: () => state } as unknown as ServiceMonitor;
    let closed = 0;
    const component = new ServiceMonitorComponent(tui, theme, monitor, () => {
      closed += 1;
    });
    for (const width of [40, 80]) {
      const rendered = component.render(width);
      expect(rendered.length).toBeLessThanOrEqual(12);
      expect(rendered.every((line) => visibleWidth(line) <= width)).toBe(true);
      const joined = rendered.join(" ").replace(/\s+/g, "");
      expect(joined).toContain("Terminal:succeeded");
      expect(joined).toContain(`ResultSHA-256:${"d".repeat(64)}`);
    }
    component.handleInput("j");
    expect(requestRender).toHaveBeenCalled();
    component.handleInput("q");
    expect(closed).toBe(1);
  });
});

/** A command receipt of run_21 from its wire JSON. */
function receiptOf(operation: string, state: string, ack: string | null): CommandReceipt {
  const decoded = decodeCommandReceipt(parseJson(JSON.stringify({
    version: 1, id: "cmd_4", profileId: "profile_main", operation, requiredScopes: ["control"], resource: "/v1/runs/run_21/control", state,
    acceptedAt: "2026-10-01T12:00:00Z", dispatchAttemptedAt: state === "accepted" ? null : "2026-10-01T12:00:01Z",
    acknowledgement: ack === null ? null : { commandId: "cmd_4", state: ack, message: `runtime says ${ack}`, command: operation, occurrenceId: "0", attemptId: null },
    effect: state === "effect-observed" ? { kind: "redirected", runtimeSequence: "3", address: { occurrenceId: "0" }, resource: "/v1/runs/run_21" } : null,
    refusal: null, links: { self: "/v1/commands/cmd_4", resource: "/v1/runs/run_21/control" },
  })));
  if (!decoded.ok) throw new Error(JSON.stringify(decoded.failure));
  return decoded.value;
}

describe("manager run controls", () => {
  const steer = { operation: "steer", address: { occurrenceId: "0", attemptId: "1" }, generation: null, timings: ["next-boundary"], choices: [], targets: [] };
  const redirect = { operation: "redirect", address: { occurrenceId: "0" }, generation: null, timings: [], choices: [], targets: ["model@spare"] };

  it("offers cancel, steer and redirect only from owned controls that offer them", () => {
    const owned = controlOf([steer, redirect, { ...redirect, targets: [] }]);
    expect(cancelOffered(owned)).toBe(true);
    expect(steerOffers(owned).map((offer) => [offer.occurrenceId, offer.attemptId, offer.timings])).toEqual([[0n, 1n, ["next-boundary"]]]);
    expect(redirectOffers(owned).map((offer) => offer.targets)).toEqual([["model@spare"]]);
    const lost = controlOf([steer, redirect], { supervision: "lost" });
    expect([cancelOffered(lost), steerOffers(lost), redirectOffers(lost)]).toEqual([false, [], []]);
    expect(cancelOffered(controlOf([], { cancelAllowed: false }))).toBe(false);
  });

  it("names the dispatch window or the one attempt in flight as the place of a redirect", () => {
    const snapshot = (occurrence: unknown) => parseJson(JSON.stringify({ items: [occurrence] })) as JsonObject;
    expect(redirectPlace(snapshot({ occurrenceId: "0", dispatch: { targets: [], open: true, redirect: null }, attempts: [] }), 0n)).toEqual({ kind: "dispatch" });
    const attempt = (number: string, state: string) => ({ address: { occurrenceId: "0", attemptId: number }, state });
    expect(redirectPlace(snapshot({ occurrenceId: "0", dispatch: null, attempts: [attempt("0", "failed"), attempt("1", "running")] }), 0n))
      .toEqual({ kind: "attempt", attemptId: "1" });
    expect(redirectPlace(snapshot({ occurrenceId: "0", dispatch: null, attempts: [] }), 0n)).toEqual({ kind: "unknown" });
    expect(redirectPlace(snapshot({ occurrenceId: "1", dispatch: null, attempts: [] }), 0n)).toEqual({ kind: "unknown" });
  });

  it("settles a control receipt on its effect, a rejecting acknowledgement, or the accepting acknowledgement of a cancel", () => {
    expect(controlSettled("redirect", receiptOf("redirect", "effect-observed", "delivered"))).toBe(true);
    expect(controlSettled("redirect", receiptOf("redirect", "acknowledged", "accepted"))).toBe(false);
    for (const rejected of ["rejected-stale", "unsupported", "failed"]) {
      expect(controlSettled("steer", receiptOf("steer", "acknowledged", rejected))).toBe(true);
    }
    expect(controlSettled("cancel", receiptOf("cancel", "acknowledged", "accepted"))).toBe(true);
    expect(controlSettled("cancel", receiptOf("cancel", "dispatch-attempted", null))).toBe(false);
    expect(acknowledgementLine(receiptOf("redirect", "acknowledged", "rejected-stale"))).toBe("Acknowledgement of command cmd_4: rejected-stale: runtime says rejected-stale");
    expect(acknowledgementLine(receiptOf("cancel", "dispatch-attempted", null))).toBe("Command cmd_4 has no runtime acknowledgement (receipt dispatch-attempted).");
  });
});

describe("manager results, lineage and exports", () => {
  it("publishes the exact bytes once with mode 0600 and refuses an existing path, a symbolic link and a relative path", async () => {
    const root = mkdtempSync(join(tmpdir(), "agent-cat-save-"));
    try {
      const bytes = Buffer.from('{"code":"text","value":"Café λ"}\n', "utf8");
      const path = join(root, "result.json");
      expect(await saveExact(path, bytes)).toEqual({ saved: true, leftover: null });
      expect(readFileSync(path).equals(bytes)).toBe(true);
      expect(lstatSync(path).mode & 0o777).toBe(0o600);
      const second = await saveExact(path, Buffer.from("other"));
      expect(second.saved).toBe(false);
      expect(!second.saved && second.reason).toContain("EEXIST");
      expect(readFileSync(path).equals(bytes)).toBe(true);
      writeFileSync(join(root, "target"), "kept");
      symlinkSync(join(root, "target"), join(root, "link"));
      expect((await saveExact(join(root, "link"), bytes)).saved).toBe(false);
      expect(readFileSync(join(root, "target"), "utf8")).toBe("kept");
      expect(await saveExact("relative.json", bytes)).toEqual({ saved: false, reason: "the destination must be one absolute single-line file path" });
      expect((await saveExact(join(root, "missing", "result.json"), bytes)).saved).toBe(false);
      // No private file remains after a save or a refusal.
      expect(readdirSync(root).sort()).toEqual(["link", "result.json", "target"]);
    } finally {
      rmSync(root, { recursive: true, force: true });
    }
  });

  it("names the completed and reused occurrences of a snapshot as fork targets and types each replacement by its code", () => {
    const snapshot = parseJson(JSON.stringify({
      items: [
        { occurrenceId: "3", state: "reused", code: "ack", intent: "Acknowledge", answer: null },
        { occurrenceId: "1", state: "completed", code: "structured", intent: "Plan", answer: "{\"ok\":true}" },
        { occurrenceId: "2", state: "failed", code: "text", intent: "Failed", answer: null },
      ],
    })) as JsonObject;
    expect(forkTargets(snapshot)).toEqual([
      { occurrenceId: 1n, code: "structured", intent: "Plan", answer: '{"ok":true}' },
      { occurrenceId: 3n, code: "ack", intent: "Acknowledge", answer: null },
    ]);
    expect(forkReplacementValue("text", "  as given ")).toEqual({ ok: true, value: "  as given " });
    expect(forkReplacementValue("flag", " Yes ")).toEqual({ ok: true, value: true });
    expect(forkReplacementValue("ack", "")).toEqual({ ok: true, value: null });
    expect(forkReplacementValue("ack", "x").ok).toBe(false);
    expect(forkReplacementValue("structured", "not json").ok).toBe(false);
    expect(lineageBody("restart", [{ operation: "drop", occurrenceId: 1n }])).toEqual({ operation: "restart" });
    expect(lineageBody("fork", [{ operation: "replace", occurrenceId: 3n, answer: null }, { operation: "drop", occurrenceId: 1n }])).toEqual({
      operation: "fork", edits: [{ occurrenceId: "1", operation: "drop" }, { occurrenceId: "3", operation: "replace", answer: null }],
    });
  });

  it("decodes the export and lineage collections and refuses a page whose eligibility and refusal disagree", () => {
    const page = { setId: "set_1", revision: "rev_1", expiresAt: "2026-10-01T12:00:00Z", index: 0, totalItems: 1, next: null };
    const receipt = {
      version: 1, id: "export_cmd_9", runId: "run_1", commandId: "cmd_9", name: "result.json", code: "text", state: "published",
      sha256: DIGEST, bytes: "33", download: "/v1/artifacts/artifact_2",
    };
    const exports = decodeExportCollection(parseJson(JSON.stringify({ version: 1, page, items: [receipt], runId: "run_1" })));
    expect(exports.ok && exports.value.revision).toBe("rev_1");
    expect(exports.ok && exportLines(exports.value.items[0], 33)).toEqual([
      "Export result.json: export_cmd_9 state published, command cmd_9", `Export download: verified 33 bytes, SHA-256 ${DIGEST}`,
    ]);
    expect(decodeExportCollection(parseJson(JSON.stringify({ version: 1, page, items: [{ ...receipt, runId: "run_2" }], runId: "run_1" }))).ok).toBe(false);
    expect(decodeExportCollection(parseJson(JSON.stringify({ version: 1, page, items: [{ ...receipt, name: "../x" }], runId: "run_1" }))).ok).toBe(false);
    const lineage = (eligible: string[], refusal: string | null) =>
      decodeLineageCollection(parseJson(JSON.stringify({ version: 1, page, items: [], runId: "run_1", eligible, refusal })));
    expect(lineage(["restart", "fork"], null)).toEqual({ ok: true, value: { runId: "run_1", revision: "rev_1", eligible: ["restart", "fork"], refusal: null, children: [] } });
    expect(lineage([], "quarantined").ok).toBe(true);
    expect(lineage([], null).ok).toBe(false);
    expect(lineage(["restart"], "quarantined").ok).toBe(false);
  });
});
