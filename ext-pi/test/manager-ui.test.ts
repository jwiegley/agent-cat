import { visibleWidth } from "@earendil-works/pi-tui";
import { describe, expect, it, vi } from "vitest";
import {
  admissionLine,
  recoveryActions,
  ReviewComponent,
  reviewLines,
  serviceMonitorLines,
  ServiceMonitorComponent,
  type MonitorState,
  type ReviewChoice,
  type ServiceMonitor,
} from "../src/manager-ui.ts";
import { parseJson, type JsonObject } from "../src/manager/json.ts";
import { decodeControl, decodeDecision, type ControlView, type DecisionView, type DraftView, type Preparation } from "../src/manager/resources.ts";

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
