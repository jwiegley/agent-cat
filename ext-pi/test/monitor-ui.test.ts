import { describe, expect, it, vi } from "vitest";
import { WorkflowMonitorComponent } from "../src/monitor-ui.ts";
import type { RunSnapshot } from "../src/types.ts";

function snapshot(): RunSnapshot {
  return {
    runId: "run-ui",
    status: "running",
    workflow: "hello",
    occurrences: new Map([
      ["0", { id: "0", state: "running", prompt: "one", replayable: true, attempts: new Map() }],
      ["1", { id: "1", state: "running", prompt: "two", replayable: true, attempts: new Map() }],
    ]),
    authoredOrder: ["0", "1"],
    traceRecorded: false,
    eventDigests: new Map(),
    controlAcks: new Map(),
  };
}

describe("workflow monitor component", () => {
  it("navigates, folds, resizes, updates, and closes", () => {
    const requestRender = vi.fn();
    const tui = { terminal: { rows: 20 }, requestRender } as never;
    const theme = { fg: (_color: string, value: string) => value } as never;
    const close = vi.fn();
    const component = new WorkflowMonitorComponent(tui, theme, snapshot(), close);
    expect(component.render(60).some((line) => line.startsWith("› [0]"))).toBe(true);
    component.handleInput("j");
    expect(component.render(30).some((line) => line.startsWith("› [1]"))).toBe(true);
    component.handleInput("\r");
    expect(component.render(30).some((line) => line.includes("[1] ▸"))).toBe(true);
    const terminal = snapshot();
    terminal.status = "cancelled";
    component.update(terminal);
    expect(component.render(24)[0]).toContain("cancelled");
    component.handleInput("\u001b");
    expect(requestRender).toHaveBeenCalled();
    expect(close).toHaveBeenCalledOnce();
  });
});
