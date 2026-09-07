import { describe, expect, it } from "vitest";
import { formatMonitor, MonitorModel, occurrenceIds } from "../src/monitor.ts";
import type { OccurrenceSnapshot, RunSnapshot } from "../src/types.ts";

function occurrence(id: string, prompt = `prompt ${id}`): OccurrenceSnapshot {
  return {
    id,
    state: "completed",
    code: "text",
    intent: "consult",
    addressee: "worker",
    prompt,
    answer: `answer ${id}`,
    source: "asked:worker",
    replayable: true,
    attempts: new Map([[`${id}:0`, {
      id: `${id}:0`, state: "completed", target: "pi", output: `output ${id}`, steers: [],
      messages: [`message ${id}`],
      tools: new Map([[`tool-${id}`, { id: `tool-${id}`, title: "Read", toolKind: "read", status: "completed", summary: "done" }]]),
      todos: [{ content: "Check result", priority: "high", status: "completed" }],
      usage: { used: "10", size: "100" },
      reasoningSummaries: ["Public summary"],
    }]]),
  };
}

function snapshot(): RunSnapshot {
  return {
    runId: "run-monitor",
    status: "running",
    workflow: "review",
    target: "pi",
    occurrences: new Map([["0", occurrence("0")], ["1", occurrence("1")]]),
    authoredOrder: ["1", "0"],
    traceRecorded: false,
    eventDigests: new Map(),
    controlAcks: new Map(),
  };
}

describe("monitor model", () => {
  it("uses authored order and preserves focus across navigation and resize", () => {
    const state = snapshot();
    expect(occurrenceIds(state)).toEqual(["1", "0"]);
    const model = new MonitorModel(state);
    expect(model.selectedId).toBe("1");
    expect(model.render(40, 12).some((line) => line.startsWith("› [1]"))).toBe(true);
    model.move(1);
    expect(model.selectedId).toBe("0");
    const resized = model.render(24, 8);
    expect(model.selectedId).toBe("0");
    expect(resized.every((line) => line.length <= 24)).toBe(true);
  });

  it("renders typed public progress distinctly from answer output", () => {
    const rendered = formatMonitor(snapshot());
    expect(rendered).toContain("message 1");
    expect(rendered).toContain("tool completed Read [read]: done");
    expect(rendered).toContain("todo completed/high: Check result");
    expect(rendered).toContain("usage: 10/100");
    expect(rendered).toContain("reasoning summary: Public summary");
    expect(rendered).toContain("answer 1");
  });

  it("folds selected occurrences and keeps focus on live updates", () => {
    const model = new MonitorModel(snapshot());
    const expanded = model.render(80, 30).length;
    model.toggle();
    expect(model.render(80, 30).length).toBeLessThan(expanded);
    const updated = snapshot();
    updated.status = "succeeded";
    updated.occurrences.set("2", occurrence("2"));
    model.update(updated);
    expect(model.selectedId).toBe("1");
    expect(model.render(80, 30)[0]).toContain("succeeded");
  });

  it("bounds non-TUI monitor rendering", () => {
    const state = snapshot();
    for (let index = 0; index < 100; index += 1) {
      const id = String(index + 2);
      state.occurrences.set(id, occurrence(id, "x".repeat(2_000)));
    }
    expect(formatMonitor(state).length).toBeLessThanOrEqual(24_000);
  });
});
