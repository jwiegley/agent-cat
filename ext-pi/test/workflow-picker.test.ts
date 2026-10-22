import type { ExtensionContext, Theme } from "@earendil-works/pi-coding-agent";
import { visibleWidth, type SelectItem, type TUI } from "@earendil-works/pi-tui";
import { describe, expect, it, vi } from "vitest";
import { pickWorkflow, WorkflowPickerComponent } from "../src/workflow-picker.ts";

const theme = { fg: (_color: string, text: string) => text } as Theme;
const items = [
  { value: "hello", label: "alpha:hello — Greet someone" },
  { value: "first", label: "alpha:review — Inspect code" },
  { value: "second", label: "beta:review — Inspect code" },
];

function picker(choices: SelectItem[] = items) {
  const tui = { terminal: { rows: 24 }, requestRender: vi.fn() };
  const done = vi.fn();
  const component = new WorkflowPickerComponent(tui as unknown as TUI, theme, "Workflows", choices, done);
  return { component, done, tui, screen: () => component.render(100).join("\n") };
}

describe("workflow picker", () => {
  it("narrows with case-insensitive subsequences, qualified names, and descriptions", () => {
    for (const [query, expected] of [["RVW", "2/3"], ["BETA:RVW", "1/3"], ["greet", "1/3"]]) {
      const { component, screen, done } = picker();
      expect(screen()).toContain("3/3");
      component.handleInput(query!);
      expect(screen()).toContain(expected);
      if (query === "BETA:RVW") {
        component.handleInput("\r");
        expect(done).toHaveBeenCalledWith(items[2]);
        expect(done.mock.calls[0]![0]).toBe(items[2]);
      }
    }
  });

  it("navigates filtered rows without confusing their original identities", () => {
    const { component, screen, done } = picker();
    component.handleInput("review");
    expect(screen().indexOf("beta:review")).toBeLessThan(screen().indexOf("alpha:review"));
    component.handleInput("\u001b[B");
    component.handleInput("\u001b[A");
    component.handleInput("\u001b[B");
    component.handleInput("\u001b[D");
    component.handleInput("\r");
    expect(done.mock.calls[0]![0]).toBe(items[1]);
  });

  it.each(["j", "k", "q"])("treats %s as search text rather than navigation or cancellation", (key) => {
    const { component, screen, done } = picker();
    component.handleInput(key);
    expect(screen()).toContain("0/3");
    expect(screen()).toContain("No matching workflows");
    expect(done).not.toHaveBeenCalled();
  });

  it("ignores confirmation with no matches and recovers after Backspace", () => {
    const { component, screen, done } = picker();
    component.handleInput("beta:review!");
    component.handleInput("\r");
    component.handleInput("\u001b[B");
    component.handleInput("\u001b[A");
    expect(screen()).toContain("No matching workflows");
    expect(done).not.toHaveBeenCalled();
    component.handleInput("\u007f");
    expect(screen()).toContain("1/3");
    component.handleInput("\n");
    expect(done.mock.calls[0]![0]).toBe(items[2]);
  });

  it("restores the full catalogue when the query is cleared", () => {
    const { component, screen, done } = picker();
    component.handleInput("review");
    for (let i = 0; i < 6; i += 1) component.handleInput("\u007f");
    expect(screen()).toContain("3/3");
    component.handleInput("\r");
    expect(done.mock.calls[0]![0]).toBe(items[0]);
  });

  it.each(["\u001b", "\u0003"])("cancels immediately with %j even when no rows match", (key) => {
    const { component, done } = picker();
    component.handleInput("no-match");
    component.handleInput(key);
    expect(done).toHaveBeenCalledExactlyOnceWith(undefined);
  });

  it("keeps every row reachable and preserves selection through resizing", () => {
    const choices = Array.from({ length: 30 }, (_, i) => ({ value: String(i), label: `wf:task-${i}` }));
    const { component, screen, done, tui } = picker(choices);
    expect(screen()).toContain("30/30");
    expect(screen()).not.toContain("wf:task-29");
    for (let i = 1; i < choices.length; i += 1) component.handleInput("\u001b[B");
    expect(screen()).toContain("wf:task-29");
    tui.terminal.rows = 12;
    component.focused = true;
    expect(component.focused).toBe(true);
    for (const width of [60, 20, 8]) {
      expect(component.render(width).every((line) => visibleWidth(line) <= width)).toBe(true);
    }
    component.invalidate();
    component.handleInput("\r");
    expect(done.mock.calls[0]![0]).toBe(choices[29]);
    expect(tui.requestRender).toHaveBeenCalled();
  });

  it("handles an empty catalogue without selecting an invalid row", () => {
    const { component, screen, done } = picker([]);
    expect(screen()).toContain("0/0");
    component.handleInput("\r");
    expect(done).not.toHaveBeenCalled();
    component.handleInput("\u001b");
    expect(done).toHaveBeenCalledExactlyOnceWith(undefined);
  });

  it("returns the original row from a filtered TUI selection", async () => {
    const rows = [{ runner: "alpha", name: "review" }, { runner: "beta", name: "review" }];
    const ctx = {
      mode: "tui",
      ui: {
        select: () => { throw new Error("TUI picker must use its search component"); },
        custom: (factory: (tui: TUI, theme: Theme, keys: never, done: (item: SelectItem | undefined) => void) => WorkflowPickerComponent) =>
          new Promise<SelectItem | undefined>((resolve) => {
            const component = factory({ terminal: { rows: 24 }, requestRender: () => {} } as TUI, theme, {} as never, resolve);
            component.handleInput("beta");
            component.handleInput("\r");
          }),
      },
    } as unknown as ExtensionContext;
    expect(await pickWorkflow(ctx, "Workflows", rows, (row) => `${row.runner}:${row.name}`)).toBe(rows[1]);
  });

  it("preserves the ordinary selector and exact row mapping for RPC clients", async () => {
    const rows = [{ runner: "alpha", name: "review" }, { runner: "beta", name: "review" }];
    const select = vi.fn().mockResolvedValueOnce("beta:review").mockResolvedValueOnce(undefined);
    const ctx = {
      mode: "rpc", hasUI: true,
      ui: { select, custom: () => { throw new Error("RPC cannot display a custom component"); } },
    } as unknown as ExtensionContext;
    const label = (row: typeof rows[number]) => `${row.runner}:${row.name}`;
    expect(await pickWorkflow(ctx, "Workflows", rows, label)).toBe(rows[1]);
    expect(select).toHaveBeenCalledWith("Workflows", ["alpha:review", "beta:review"]);
    expect(await pickWorkflow(ctx, "Workflows", rows, label)).toBeUndefined();
  });
});
