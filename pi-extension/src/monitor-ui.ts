import type { Theme } from "@earendil-works/pi-coding-agent";
import { matchesKey, truncateToWidth, type Component, type TUI } from "@earendil-works/pi-tui";
import { MonitorModel } from "./monitor.ts";
import type { RunSnapshot } from "./types.ts";

export class WorkflowMonitorComponent implements Component {
  readonly #tui: TUI;
  readonly #theme: Theme;
  readonly #model: MonitorModel;
  readonly #close: () => void;

  constructor(tui: TUI, theme: Theme, snapshot: RunSnapshot, close: () => void) {
    this.#tui = tui;
    this.#theme = theme;
    this.#model = new MonitorModel(snapshot);
    this.#close = close;
  }

  update(snapshot: RunSnapshot): void {
    this.#model.update(snapshot);
    this.#tui.requestRender();
  }

  handleInput(data: string): void {
    if (matchesKey(data, "escape") || matchesKey(data, "ctrl+c") || data === "q") return this.#close();
    if (matchesKey(data, "down") || data === "j") this.#model.move(1);
    else if (matchesKey(data, "up") || data === "k") this.#model.move(-1);
    else if (matchesKey(data, "return") || data === " ") this.#model.toggle();
    else return;
    this.#tui.requestRender();
  }

  render(width: number): string[] {
    const height = Math.max(8, this.#tui.terminal.rows - 4);
    return this.#model.render(width, height).map((line, index, lines) => {
      if (index === 0) return truncateToWidth(this.#theme.fg("accent", line), width);
      if (index === lines.length - 1) return truncateToWidth(this.#theme.fg("dim", line), width);
      if (line.startsWith("›")) return truncateToWidth(this.#theme.fg("success", line), width);
      return truncateToWidth(line, width);
    });
  }

  invalidate(): void {}
}
