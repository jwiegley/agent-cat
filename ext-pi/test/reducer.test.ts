import { describe, expect, it } from "vitest";
import { initialSnapshot, reduceEvent } from "../src/reducer.ts";
import type { RuntimeEvent } from "../src/types.ts";

function event(sequence: number, type: string, payload: Record<string, unknown> = {}): RuntimeEvent {
  return { protocolVersion: 1, runId: "run-1", sequence: String(sequence), timestamp: "2026-08-28T00:00:00.000Z", event: { type, ...payload } };
}

describe("runtime reducer", () => {
  it("reduces occurrence, attempt, trace, and terminal state", () => {
    const events = [
      event(0, "run.started", { workflow: "hello", target: "scripted" }),
      event(1, "occurrence.started", { occurrenceId: "0", code: "text", intent: "consult", addressee: "model", prompt: "p" }),
      event(2, "attempt.started", { occurrenceId: "0", attempt: "0", target: "scripted" }),
      event(3, "attempt.output", { occurrenceId: "0", attempt: "0", stream: "transport-text", chunk: "answer" }),
      event(4, "attempt.steered", { occurrenceId: "0", attempt: "0", controlId: "steer-1", timing: "interrupt-now", text: "focus" }),
      event(5, "attempt.completed", { occurrenceId: "0", attempt: "0", source: "scripted" }),
      event(6, "occurrence.completed", { occurrenceId: "0", source: "asked:model", answer: "answer" }),
      event(7, "trace.ordered", { occurrenceIds: ["0"] }),
      event(8, "run.completed", { billFresh: "1", billMemo: "1" }),
    ];
    const snapshot = events.reduce(reduceEvent, initialSnapshot("run-1"));
    expect(snapshot.status).toBe("succeeded");
    expect(snapshot.authoredOrder).toEqual(["0"]);
    expect(snapshot.occurrences.get("0")?.attempts.get("0:0")?.output).toBe("answer");
    expect(snapshot.occurrences.get("0")?.attempts.get("0:0")?.steers).toEqual([{ controlId: "steer-1", timing: "interrupt-now", text: "focus" }]);
    expect(snapshot.occurrences.get("0")?.replayable).toBe(false);
    expect(snapshot.billFresh).toBe("1");
  });

  it("rejects identical duplicates, gaps, and conflicts", () => {
    const first = event(0, "run.started", { workflow: "hello", target: "scripted" });
    const once = reduceEvent(initialSnapshot("run-1"), first);
    expect(() => reduceEvent(once, first)).toThrow("duplicate sequence");
    expect(() => reduceEvent(once, event(2, "run.completed", { billFresh: "0", billMemo: "0" }))).toThrow("sequence gap");
    expect(() => reduceEvent(once, { ...first, timestamp: "2026-08-28T00:00:00.001Z" })).toThrow("conflicting duplicate");
  });

  it("is immutable and bounds attempt output by UTF-8 bytes", () => {
    const running = reduceEvent(initialSnapshot("run-1"), event(0, "run.started", { workflow: "x", target: "x" }));
    const started = reduceEvent(running, event(1, "occurrence.started", { occurrenceId: "0", code: "text", intent: "consult", addressee: "model", prompt: "p" }));
    const attempted = reduceEvent(started, event(2, "attempt.started", { occurrenceId: "0", attempt: "0", target: "scripted" }));
    expect(started.occurrences.get("0")?.attempts.size).toBe(0);
    const output = reduceEvent(attempted, event(3, "attempt.output", { occurrenceId: "0", attempt: "0", chunk: "😀".repeat(20_000) }));
    const text = output.occurrences.get("0")?.attempts.get("0:0")?.output ?? "";
    expect(Buffer.byteLength(text)).toBeLessThanOrEqual(64 * 1024);
    expect(text).not.toContain("�");
    expect(attempted.occurrences.get("0")?.attempts.get("0:0")?.output).toBe("");
  });

  it("tracks interactive recovery without inventing an answer", () => {
    const running = reduceEvent(initialSnapshot("run-1"), event(0, "run.started", { workflow: "x", target: "x" }));
    const started = reduceEvent(running, event(1, "occurrence.started", { occurrenceId: "0", code: "flag", intent: "consult", addressee: "model", prompt: "p" }));
    const attempting = reduceEvent(started, event(2, "attempt.started", { occurrenceId: "0", attempt: "0", target: "model@a" }));
    const failed = reduceEvent(attempting, event(3, "attempt.failed", { occurrenceId: "0", attempt: "0", failure: "decode", message: "maybe" }));
    const pending = reduceEvent(failed, event(4, "occurrence.recovery-pending", { occurrenceId: "0", gap: "decode", message: "maybe", choices: [{ choice: "retry" }, { choice: "abandon" }] }));
    expect(pending.occurrences.get("0")?.state).toBe("recovering");
    expect(pending.occurrences.get("0")?.answer).toBeUndefined();
    const chosen = reduceEvent(pending, event(5, "occurrence.recovery-chosen", { occurrenceId: "0", controlId: "retry-1", choice: "retry" }));
    const retried = reduceEvent(chosen, event(6, "occurrence.retried", { occurrenceId: "0", controlId: "retry-1" }));
    expect(retried.occurrences.get("0")?.state).toBe("running");
    expect(retried.occurrences.get("0")?.recovery?.choices).toEqual([{ choice: "retry" }, { choice: "abandon" }]);
    expect(retried.occurrences.get("0")?.recovery?.chosen).toEqual({ controlId: "retry-1", choice: "retry", target: undefined });
    expect(retried.occurrences.get("0")?.recovery?.retries).toEqual(["retry-1"]);
  });

  it("accepts only scheduler-reserved pre-dispatch redirects", () => {
    const running = reduceEvent(initialSnapshot("run-1"), event(0, "run.started", { workflow: "x", target: "x" }));
    const started = reduceEvent(running, event(1, "occurrence.started", { occurrenceId: "0", code: "text", intent: "consult", addressee: "model", prompt: "p" }));
    const pending = reduceEvent(started, event(2, "occurrence.dispatch-pending", { occurrenceId: "0", targets: ["model@a", "model@b"] }));
    expect(pending.occurrences.get("0")?.dispatch?.open).toBe(true);
    expect(() => reduceEvent(pending, event(3, "occurrence.redirected", { occurrenceId: "0", controlId: "redirect-1", target: "model@x" }))).toThrow("not reserved");
    const redirected = reduceEvent(pending, event(3, "occurrence.redirected", { occurrenceId: "0", controlId: "redirect-1", target: "model@b" }));
    expect(redirected.occurrences.get("0")?.dispatch).toEqual({ targets: ["model@a", "model@b"], open: false, redirect: { controlId: "redirect-1", target: "model@b" } });
  });

  it("validates timestamps, lifecycle transitions, and authored references", () => {
    expect(() => reduceEvent(initialSnapshot("run-1"), { ...event(0, "run.started", { workflow: "x", target: "x" }), timestamp: "not-a-time" })).toThrow("timestamp");
    const started = reduceEvent(initialSnapshot("run-1"), event(0, "run.started", { workflow: "x", target: "x" }));
    const occurrence = reduceEvent(started, event(1, "occurrence.started", { occurrenceId: "0", code: "text", intent: "consult", addressee: "model", prompt: "p" }));
    expect(() => reduceEvent(occurrence, event(2, "occurrence.started", { occurrenceId: "0", code: "text", intent: "consult", addressee: "model", prompt: "p" }))).toThrow("duplicate occurrence");
    expect(() => reduceEvent(occurrence, event(2, "trace.ordered", { occurrenceIds: ["missing"] }))).toThrow("unknown");
    const attempt = reduceEvent(occurrence, event(2, "attempt.started", { occurrenceId: "0", attempt: "0", target: "model" }));
    expect(() => reduceEvent(attempt, event(3, "attempt.failed", { occurrenceId: "0", attempt: "0", failure: "mystery", message: "bad" }))).toThrow("failure class");
    const completedAttempt = reduceEvent(attempt, event(3, "attempt.completed", { occurrenceId: "0", attempt: "0", source: "model" }));
    expect(() => reduceEvent(completedAttempt, event(4, "occurrence.failed", { occurrenceId: "0", failure: "mystery", message: "bad" }))).toThrow("failure class");
    expect(() => reduceEvent(completedAttempt, event(4, "attempt.output", { occurrenceId: "0", attempt: "0", chunk: "late" }))).toThrow("cannot accept output");
    const completedOccurrence = reduceEvent(completedAttempt, event(4, "occurrence.completed", { occurrenceId: "0", source: "model", answer: "a" }));
    const ordered = reduceEvent(completedOccurrence, event(5, "trace.ordered", { occurrenceIds: ["0"] }));
    expect(() => reduceEvent(ordered, event(6, "trace.ordered", { occurrenceIds: ["0"] }))).toThrow("more than once");
    expect(() => reduceEvent(ordered, event(6, "run.completed", { billFresh: "-1", billMemo: "1" }))).toThrow("unsigned decimal");
    const terminal = reduceEvent(ordered, event(6, "run.completed", { billFresh: "1", billMemo: "1" }));
    expect(() => reduceEvent(terminal, event(7, "control.ack", { controlId: "late", state: "failed", message: "late" }))).toThrow("post-terminal");
  });

  it("rejects illegal transitions across every lifecycle family", () => {
    const running = reduceEvent(initialSnapshot("run-1"), event(0, "run.started", { workflow: "x", target: "x" }));
    expect(() => reduceEvent(running, event(1, "run.failed", { failure: "mystery", message: "bad" }))).toThrow("failure class");
    expect(() => reduceEvent(initialSnapshot("run-1"), event(0, "occurrence.started", { occurrenceId: "0", code: "text", intent: "consult", addressee: "model", prompt: "p" }))).toThrow("before run");
    expect(() => reduceEvent(running, event(1, "occurrence.started", { occurrenceId: "18446744073709551616", code: "text", intent: "consult", addressee: "model", prompt: "p" }))).toThrow("unsigned range");
    const occurrence = reduceEvent(running, event(1, "occurrence.started", { occurrenceId: "0", code: "text", intent: "consult", addressee: "model", prompt: "p" }));
    const attempt = reduceEvent(occurrence, event(2, "attempt.started", { occurrenceId: "0", attempt: "0", target: "model" }));
    expect(() => reduceEvent(attempt, event(3, "attempt.started", { occurrenceId: "0", attempt: "0", target: "model" }))).toThrow("duplicate attempt");
    expect(() => reduceEvent(attempt, event(3, "occurrence.completed", { occurrenceId: "0", source: "model", answer: "a" }))).toThrow("active attempt");
    expect(() => reduceEvent(attempt, event(3, "attempt.steered", { occurrenceId: "0", attempt: "0", controlId: "s", timing: "later", text: "x" }))).toThrow("steering timing");
    const completedAttempt = reduceEvent(attempt, event(3, "attempt.completed", { occurrenceId: "0", attempt: "0", source: "model" }));
    expect(() => reduceEvent(completedAttempt, event(4, "attempt.completed", { occurrenceId: "0", attempt: "0", source: "model" }))).toThrow("while completed");
    const pending = reduceEvent(occurrence, event(2, "occurrence.recovery-pending", { occurrenceId: "0", gap: "decode", message: "bad", choices: [{ choice: "retry" }, { choice: "abandon" }] }));
    expect(() => reduceEvent(pending, event(3, "occurrence.retried", { occurrenceId: "0", controlId: "r" }))).toThrow("retry/failover");
    expect(() => reduceEvent(occurrence, event(2, "occurrence.recovery-pending", { occurrenceId: "0", gap: "decode", message: "bad", choices: [{ choice: "retry" }, { choice: "retry" }] }))).toThrow("duplicates");
    expect(() => reduceEvent(occurrence, event(2, "occurrence.recovery-chosen", { occurrenceId: "0", controlId: "r", choice: "retry" }))).toThrow("not waiting");
    const dispatch = reduceEvent(occurrence, event(2, "occurrence.dispatch-pending", { occurrenceId: "0", targets: ["a", "b"] }));
    expect(() => reduceEvent(dispatch, event(3, "occurrence.dispatch-pending", { occurrenceId: "0", targets: ["a"] }))).toThrow("cannot open dispatch");
    const completedOccurrence = reduceEvent(completedAttempt, event(4, "occurrence.completed", { occurrenceId: "0", source: "model", answer: "a" }));
    expect(() => reduceEvent(completedOccurrence, event(5, "occurrence.completed", { occurrenceId: "0", source: "model", answer: "a" }))).toThrow("while completed");
    expect(() => reduceEvent(completedOccurrence, event(5, "run.completed", { billFresh: "1", billMemo: "1" }))).toThrow("authored trace");
    const accepted = reduceEvent(running, event(1, "control.ack", { controlId: "c", state: "accepted", message: "ok" }));
    expect(() => reduceEvent(accepted, event(2, "control.ack", { controlId: "c", state: "accepted", message: "again" }))).toThrow("acknowledgement transition");
    expect(() => reduceEvent(running, { ...event(1, "run.failed", { failure: "runtime", message: "x" }), sequence: "18446744073709551616" })).toThrow("64-bit range");
  });

  it("does not invent unknown occurrence or event state", () => {
    expect(() => reduceEvent(initialSnapshot("run-1"), event(0, "control.ack", { controlId: "early", state: "unsupported", message: "too early" }))).toThrow("starting");
    const running = reduceEvent(initialSnapshot("run-1"), event(0, "run.started", { workflow: "x", target: "x" }));
    const acknowledged = reduceEvent(running, event(1, "control.ack", { controlId: "steer-1", state: "unsupported", message: "target cannot steer" }));
    expect(acknowledged.controlAcks.get("steer-1")).toEqual({ controlId: "steer-1", state: "unsupported", message: "target cannot steer" });
    const failed = reduceEvent(running, event(1, "run.failed", { failure: "transport", message: "adapter died" }));
    expect(failed).toMatchObject({ status: "failed", failureClass: "transport", failure: "adapter died" });
    expect(() => reduceEvent(running, event(1, "occurrence.completed", { occurrenceId: "9", source: "x", answer: "x" }))).toThrow("unknown occurrence");
    expect(() => reduceEvent(running, event(1, "future.event"))).toThrow("unknown runtime event");
  });
});
