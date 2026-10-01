import { visibleWidth } from "@earendil-works/pi-tui";
import { describe, expect, it, vi } from "vitest";
import { admissionLine, ReviewComponent, reviewLines, type ReviewChoice } from "../src/manager-ui.ts";
import type { DraftView, Preparation } from "../src/manager/resources.ts";

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
