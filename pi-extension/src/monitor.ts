import type { OccurrenceSnapshot, RunSnapshot } from "./types.ts";

export class MonitorModel {
  #snapshot: RunSnapshot;
  #selectedId?: string;
  readonly #collapsed = new Set<string>();

  constructor(snapshot: RunSnapshot) {
    this.#snapshot = snapshot;
    this.#selectedId = occurrenceIds(snapshot)[0];
  }

  get snapshot(): RunSnapshot {
    return this.#snapshot;
  }

  get selectedId(): string | undefined {
    return this.#selectedId;
  }

  update(snapshot: RunSnapshot): void {
    this.#snapshot = snapshot;
    const ids = occurrenceIds(snapshot);
    if (!this.#selectedId || !ids.includes(this.#selectedId)) this.#selectedId = ids[0];
  }

  move(delta: number): void {
    const ids = occurrenceIds(this.#snapshot);
    if (ids.length === 0) return;
    const current = Math.max(0, ids.indexOf(this.#selectedId ?? ids[0]));
    this.#selectedId = ids[Math.max(0, Math.min(ids.length - 1, current + delta))];
  }

  toggle(): void {
    if (!this.#selectedId) return;
    if (this.#collapsed.has(this.#selectedId)) this.#collapsed.delete(this.#selectedId);
    else this.#collapsed.add(this.#selectedId);
  }

  render(width: number, height = 30): string[] {
    const safeWidth = Math.max(20, width);
    const ids = occurrenceIds(this.#snapshot);
    const header = fit(`${this.#snapshot.runId}  ${this.#snapshot.status}  ${this.#snapshot.workflow ?? "starting"}  target=${this.#snapshot.target ?? "pending"}`, safeWidth);
    const footer = fit("↑/↓ select  enter fold  esc close", safeWidth);
    const prefix = this.#snapshot.failure ? [fit(`failure (${this.#snapshot.failureClass ?? "unknown"}): ${this.#snapshot.failure}`, safeWidth)] : [];
    for (const ack of [...this.#snapshot.controlAcks.values()].slice(-3)) {
      prefix.push(fit(`control ${ack.controlId}: ${ack.state} — ${ack.message}`, safeWidth));
    }
    const blocks = ids.map((id) => this.#block(id, safeWidth));
    const selectedIndex = Math.max(0, ids.indexOf(this.#selectedId ?? ""));
    const room = Math.max(1, height - 2);
    let start = prefix.length;
    for (let index = 0; index < selectedIndex; index += 1) start += blocks[index].length;
    const selectedLength = blocks[selectedIndex]?.length ?? 0;
    const all = [...prefix, ...blocks.flat()];
    const offset = Math.max(0, Math.min(start, start + selectedLength - room, Math.max(0, all.length - room)));
    return [header, ...all.slice(offset, offset + room), footer];
  }

  #block(id: string, width: number): string[] {
    const occurrence = this.#snapshot.occurrences.get(id);
    if (!occurrence) return [fit(`  [${id}] unavailable`, width)];
    const selected = id === this.#selectedId;
    const marker = selected ? "›" : " ";
    const folded = this.#collapsed.has(id);
    const lines = [fit(`${marker} [${id}] ${folded ? "▸" : "▾"} ${occurrence.state} ${occurrence.intent ?? "?"}/${occurrence.code ?? "?"} → ${occurrence.addressee ?? "?"}`, width)];
    if (folded) return lines;
    appendWrapped(lines, "    prompt: ", occurrence.prompt, width);
    if (occurrence.failureClass) lines.push(fit(`    failure class: ${occurrence.failureClass}`, width));
    if (occurrence.dispatch) {
      lines.push(fit(`    dispatch ${occurrence.dispatch.open ? "pending" : "closed"}: ${occurrence.dispatch.targets.join(", ")}`, width));
      if (occurrence.dispatch.redirect) lines.push(fit(`      redirected by ${occurrence.dispatch.redirect.controlId} → ${occurrence.dispatch.redirect.target}`, width));
    }
    if (occurrence.recovery) {
      appendWrapped(lines, `    recovery (${occurrence.recovery.gap}): `, occurrence.recovery.message, width);
      if (occurrence.recovery.retries.length) lines.push(fit(`      retries: ${occurrence.recovery.retries.join(", ")}`, width));
      if (occurrence.recovery.choices.length) lines.push(fit(`      options: ${occurrence.recovery.choices.map((choice) => choice.target ? `${choice.choice}:${choice.target}` : choice.choice).join(", ")}`, width));
      if (occurrence.recovery.chosen) lines.push(fit(`      chosen: ${occurrence.recovery.chosen.choice}${occurrence.recovery.chosen.target ? `:${occurrence.recovery.chosen.target}` : ""} (${occurrence.recovery.chosen.controlId})`, width));
    }
    for (const attempt of occurrence.attempts.values()) {
      lines.push(fit(`    attempt ${attempt.id}: ${attempt.state} target=${attempt.target ?? "?"}${attempt.failure ? ` failure=${attempt.failureClass ?? "unknown"}:${attempt.failure}` : ""}`, width));
      appendWrapped(lines, "      output: ", attempt.output || undefined, width);
      for (const steer of attempt.steers) appendWrapped(lines, `      steer ${steer.controlId} (${steer.timing}): `, steer.text, width);
    }
    appendWrapped(lines, `    answer (${occurrence.source ?? "unknown"}${occurrence.reuseKind ? `, ${occurrence.reuseKind}` : ""}${occurrence.replayable ? "" : ", non-replayable"}): `, occurrence.answer, width);
    return lines;
  }
}

export function occurrenceIds(snapshot: RunSnapshot): string[] {
  return [...snapshot.authoredOrder, ...[...snapshot.occurrences.keys()].filter((id) => !snapshot.authoredOrder.includes(id))];
}

export function formatMonitor(snapshot: RunSnapshot): string {
  return new MonitorModel(snapshot).render(120, 200).join("\n").slice(0, 24_000);
}

function appendWrapped(lines: string[], prefix: string, value: string | undefined, width: number): void {
  if (!value) return;
  const normalized = value.replace(/\s+/g, " ").trim();
  const room = Math.max(1, width - prefix.length);
  const chunks: string[] = [];
  for (let offset = 0; offset < normalized.length; offset += room) chunks.push(normalized.slice(offset, offset + room));
  if (chunks.length === 0) chunks.push("");
  lines.push(fit(prefix + chunks[0], width));
  for (const chunk of chunks.slice(1)) lines.push(fit(" ".repeat(prefix.length) + chunk, width));
}

function fit(value: string, width: number): string {
  return value.length <= width ? value : `${value.slice(0, Math.max(0, width - 1))}…`;
}
