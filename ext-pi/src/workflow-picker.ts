import { keyText, type ExtensionContext, type Theme } from "@earendil-works/pi-coding-agent";
import {
  fuzzyFilter, getKeybindings, Input, SelectList, truncateToWidth,
  type Component, type Focusable, type SelectItem, type TUI,
} from "@earendil-works/pi-tui";

/** A workflow chosen from the supplied catalogue, or undefined when cancelled. */
export async function pickWorkflow<T>(
  ctx: ExtensionContext,
  title: string,
  rows: readonly T[],
  label: (row: T) => string,
): Promise<T | undefined> {
  const items = rows.map((row, index) => ({ value: String(index), label: label(row) }));
  if (ctx.mode !== "tui") {
    const labels = items.map((item) => item.label);
    const chosen = await ctx.ui.select(title, labels);
    return chosen === undefined ? undefined : rows[labels.indexOf(chosen)];
  }
  const chosen = await ctx.ui.custom<SelectItem | undefined>((tui, theme, _keys, done) =>
    new WorkflowPickerComponent(tui, theme, title, items, done));
  return chosen === undefined ? undefined : rows[Number(chosen.value)];
}

/** The current search and selection over an unchanged workflow catalogue. */
export class WorkflowPickerComponent implements Component, Focusable {
  readonly #tui: TUI;
  readonly #theme: Theme;
  readonly #title: string;
  readonly #items: SelectItem[];
  readonly #done: (item: SelectItem | undefined) => void;
  readonly #input = new Input({ placeholder: "Type to filter workflows" });
  #matches: SelectItem[];
  #maxVisible = 10;
  #list: SelectList;

  constructor(tui: TUI, theme: Theme, title: string, items: SelectItem[], done: (item: SelectItem | undefined) => void) {
    this.#tui = tui;
    this.#theme = theme;
    this.#title = title;
    this.#items = items;
    this.#matches = items;
    this.#done = done;
    this.#list = this.#makeList();
    this.#input.onSubmit = () => {
      const item = this.#list.getSelectedItem();
      if (item !== null) this.#done(item);
    };
  }

  get focused(): boolean { return this.#input.focused; }
  set focused(value: boolean) { this.#input.focused = value; }

  #makeList(): SelectList {
    const list = new SelectList(this.#matches, this.#maxVisible, {
      selectedPrefix: (text) => this.#theme.fg("accent", text),
      selectedText: (text) => this.#theme.fg("accent", text),
      description: (text) => this.#theme.fg("muted", text),
      scrollInfo: (text) => this.#theme.fg("dim", text),
      noMatch: () => this.#theme.fg("muted", "  No matching workflows"),
    });
    list.onSelect = this.#done;
    list.onCancel = () => this.#done(undefined);
    return list;
  }

  handleInput(data: string): void {
    const keys = getKeybindings();
    if (keys.matches(data, "tui.select.up") || keys.matches(data, "tui.select.down")
      || keys.matches(data, "tui.select.confirm") || keys.matches(data, "tui.select.cancel")) {
      this.#list.handleInput(data);
    } else {
      const before = this.#input.getValue();
      this.#input.handleInput(data);
      const query = this.#input.getValue();
      if (query !== before) {
        this.#matches = fuzzyFilter(this.#items, query, (item) => item.label);
        this.#list = this.#makeList();
      }
    }
    this.#tui.requestRender();
  }

  render(width: number): string[] {
    const maxVisible = Math.max(1, Math.min(10, this.#tui.terminal.rows - 8));
    if (maxVisible !== this.#maxVisible) {
      const selected = this.#list.getSelectedItem()?.value;
      this.#maxVisible = maxVisible;
      this.#list = this.#makeList();
      const index = this.#matches.findIndex((item) => item.value === selected);
      if (index >= 0) this.#list.setSelectedIndex(index);
    }
    return [
      this.#theme.fg("accent", `${this.#title} (${this.#matches.length}/${this.#items.length})`),
      ...this.#input.render(width),
      "",
      ...this.#list.render(width),
      "",
      this.#theme.fg("dim", `Type to filter · ${keyText("tui.select.up")}/${keyText("tui.select.down")} navigate · ${keyText("tui.select.confirm")} select · ${keyText("tui.select.cancel")} cancel`),
    ].map((line) => truncateToWidth(line, width));
  }

  invalidate(): void {
    this.#input.invalidate();
    this.#list.invalidate();
  }
}
