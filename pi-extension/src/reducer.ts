import type { AttemptSnapshot, OccurrenceSnapshot, RunSnapshot, RuntimeEvent } from "./types.ts";

const OUTPUT_TAIL = 64 * 1024;
const MAX_WORD64 = (1n << 64n) - 1n;
const MAX_WORD32 = (1n << 32n) - 1n;

export function initialSnapshot(runId: string): RunSnapshot {
  return {
    runId,
    status: "starting",
    occurrences: new Map(),
    authoredOrder: [],
    traceRecorded: false,
    eventDigests: new Map(),
    controlAcks: new Map(),
  };
}

export function reduceEvent(current: RunSnapshot, envelope: RuntimeEvent): RunSnapshot {
  if (envelope.protocolVersion !== 1) throw new Error(`unsupported protocol version ${envelope.protocolVersion}`);
  if (envelope.runId !== current.runId) throw new Error(`run id changed from ${current.runId} to ${envelope.runId}`);
  if (typeof envelope.timestamp !== "string" || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$/.test(envelope.timestamp) || !Number.isFinite(Date.parse(envelope.timestamp))) {
    throw new Error("timestamp is not canonical UTC ISO-8601");
  }
  if (!/^(0|[1-9][0-9]*)$/.test(envelope.sequence)) throw new Error("sequence is not an unsigned decimal string");

  const seen = new Map(current.eventDigests);
  const digest = JSON.stringify(envelope);
  const prior = seen.get(envelope.sequence);
  if (prior !== undefined) {
    throw new Error(prior === digest ? `duplicate sequence ${envelope.sequence}` : `conflicting duplicate sequence ${envelope.sequence}`);
  }

  const sequence = BigInt(envelope.sequence);
  if (sequence > MAX_WORD64) throw new Error("sequence exceeds unsigned 64-bit range");
  const expected = current.lastSequence === undefined ? 0n : current.lastSequence + 1n;
  if (sequence !== expected) throw new Error(`sequence gap: expected ${expected}, got ${sequence}`);
  if (isTerminal(current.status)) throw new Error(`post-terminal event ${envelope.event.type}`);
  seen.set(envelope.sequence, digest);

  const next: RunSnapshot = {
    ...current,
    lastSequence: sequence,
    occurrences: new Map([...current.occurrences].map(([id, occurrence]) => [id, { ...occurrence, dispatch: occurrence.dispatch ? { ...occurrence.dispatch, targets: [...occurrence.dispatch.targets], redirect: occurrence.dispatch.redirect ? { ...occurrence.dispatch.redirect } : undefined } : undefined, recovery: occurrence.recovery ? { ...occurrence.recovery, retries: [...occurrence.recovery.retries], choices: [...occurrence.recovery.choices] } : undefined, attempts: new Map([...occurrence.attempts].map(([attemptId, attempt]) => [attemptId, { ...attempt, steers: [...attempt.steers] }])) }])),
    authoredOrder: [...current.authoredOrder],
    eventDigests: seen,
    controlAcks: new Map(current.controlAcks),
  };
  apply(next, envelope.event);
  return next;
}

function apply(snapshot: RunSnapshot, event: RuntimeEvent["event"]): void {
  switch (event.type) {
    case "run.started":
      if (snapshot.status !== "starting" && snapshot.status !== "cancelling") throw new Error("run.started is not first");
      if (snapshot.status !== "cancelling") snapshot.status = "running";
      snapshot.workflow = text(event.workflow, "workflow");
      snapshot.target = text(event.target, "target");
      return;
    case "occurrence.started": {
      const id = occurrenceId(event);
      if (snapshot.status !== "running") throw new Error("occurrence started before run");
      if (snapshot.occurrences.has(id)) throw new Error(`duplicate occurrence ${id}`);
      snapshot.occurrences.set(id, {
        id,
        state: "running",
        code: text(event.code, "code"),
        intent: text(event.intent, "intent"),
        addressee: text(event.addressee, "addressee"),
        prompt: text(event.prompt, "prompt"),
        replayable: true,
        attempts: new Map(),
      });
      return;
    }
    case "attempt.started": {
      const occurrence = occurrenceOf(snapshot, event);
      const id = attemptId(event);
      if (occurrence.state !== "running") throw new Error(`occurrence ${occurrence.id} cannot start an attempt while ${occurrence.state}`);
      if (occurrence.attempts.has(id)) throw new Error(`duplicate attempt ${id}`);
      if (occurrence.dispatch) occurrence.dispatch.open = false;
      occurrence.attempts.set(id, { id, state: "running", target: text(event.target, "target"), output: "", steers: [] });
      return;
    }
    case "attempt.output": {
      const attempt = attemptOf(snapshot, event);
      requireAttemptRunning(attempt, "output");
      attempt.output = tail(attempt.output + text(event.chunk, "chunk"));
      return;
    }
    case "attempt.steered": {
      const occurrence = occurrenceOf(snapshot, event);
      const attempt = attemptOf(snapshot, event);
      requireAttemptRunning(attempt, "steering");
      const timing = text(event.timing, "timing");
      if (timing !== "interrupt-now" && timing !== "next-boundary") throw new Error(`unknown steering timing ${timing}`);
      attempt.steers.push({
        controlId: runtimeControlId(event),
        timing,
        text: text(event.text, "text"),
      });
      occurrence.replayable = false;
      return;
    }
    case "attempt.completed": {
      const attempt = attemptOf(snapshot, event);
      requireAttemptRunning(attempt, "completion");
      attempt.state = "completed";
      return;
    }
    case "attempt.failed": {
      const attempt = attemptOf(snapshot, event);
      requireAttemptRunning(attempt, "failure");
      attempt.state = "failed";
      attempt.failure = text(event.message, "message");
      attempt.failureClass = runtimeFailureClass(event.failure);
      return;
    }
    case "occurrence.recovery-chosen": {
      const occurrence = occurrenceOf(snapshot, event);
      if (!occurrence.recovery || occurrence.state !== "recovering") throw new Error(`occurrence ${occurrence.id} was not waiting for recovery choice`);
      if (occurrence.recovery.chosen) throw new Error(`occurrence ${occurrence.id} already has a recovery choice`);
      const choice = text(event.choice, "choice") as "retry" | "failover" | "abandon";
      const target = typeof event.target === "string" ? event.target : undefined;
      if (!occurrence.recovery.choices.some((offered) => offered.choice === choice && offered.target === target)) throw new Error(`recovery choice ${choice} was not offered`);
      occurrence.recovery.chosen = { controlId: runtimeControlId(event), choice, target };
      return;
    }
    case "occurrence.reused": {
      const occurrence = occurrenceOf(snapshot, event);
      if (occurrence.state !== "running") throw new Error(`occurrence ${occurrence.id} cannot be reused while ${occurrence.state}`);
      occurrence.state = "reused";
      occurrence.reuseKind = text(event.answerGroup, "answerGroup");
      return;
    }
    case "occurrence.recovery-pending": {
      const occurrence = occurrenceOf(snapshot, event);
      if (occurrence.state !== "running") throw new Error(`occurrence ${occurrence.id} cannot enter recovery while ${occurrence.state}`);
      occurrence.state = "recovering";
      if (!Array.isArray(event.choices) || event.choices.length === 0) throw new Error("recovery choices are missing");
      const choices = event.choices.map((candidate) => {
        if (!isRecord(candidate)) throw new Error("recovery choice is invalid");
        const choice = text(candidate.choice, "choice") as "retry" | "failover" | "abandon";
        const target = typeof candidate.target === "string" ? candidate.target : undefined;
        if (choice !== "retry" && choice !== "failover" && choice !== "abandon") throw new Error(`unknown recovery choice ${choice}`);
        if (choice !== "failover" && target !== undefined) throw new Error(`only failover recovery may name a target`);
        return { choice, target };
      });
      if (new Set(choices.map((choice) => choice.choice)).size !== choices.length) throw new Error("recovery choices contain duplicates");
      occurrence.recovery = { gap: text(event.gap, "gap"), message: text(event.message, "message"), retries: [], choices };
      return;
    }
    case "occurrence.retried": {
      const occurrence = occurrenceOf(snapshot, event);
      if (!occurrence.recovery || occurrence.state !== "recovering" || !occurrence.recovery.chosen || occurrence.recovery.chosen.choice === "abandon") throw new Error(`occurrence ${occurrence.id} was not waiting for retry/failover recovery`);
      occurrence.recovery.retries.push(runtimeControlId(event));
      occurrence.state = "running";
      return;
    }
    case "occurrence.dispatch-pending": {
      const occurrence = occurrenceOf(snapshot, event);
      if (occurrence.state !== "running" || occurrence.dispatch) throw new Error(`occurrence ${occurrence.id} cannot open dispatch`);
      if (!Array.isArray(event.targets) || event.targets.length === 0 || !event.targets.every((target) => typeof target === "string") || new Set(event.targets).size !== event.targets.length) throw new Error("dispatch targets are invalid");
      occurrence.dispatch = { targets: [...event.targets], open: true };
      return;
    }
    case "occurrence.redirected": {
      const occurrence = occurrenceOf(snapshot, event);
      const target = text(event.target, "target");
      if (!occurrence.dispatch?.open || !occurrence.dispatch.targets.includes(target)) throw new Error(`redirect target ${target} was not reserved in an open dispatch`);
      occurrence.dispatch.open = false;
      occurrence.dispatch.redirect = { controlId: runtimeControlId(event), target };
      return;
    }
    case "occurrence.completed": {
      const occurrence = occurrenceOf(snapshot, event);
      if (occurrence.state !== "running" && occurrence.state !== "reused") throw new Error(`occurrence ${occurrence.id} cannot complete while ${occurrence.state}`);
      if ([...occurrence.attempts.values()].some((attempt) => attempt.state === "running")) throw new Error(`occurrence ${occurrence.id} completed with an active attempt`);
      occurrence.state = occurrence.state === "reused" ? "reused" : "completed";
      occurrence.source = text(event.source, "source");
      occurrence.answer = text(event.answer, "answer");
      return;
    }
    case "occurrence.failed": {
      const occurrence = occurrenceOf(snapshot, event);
      if (occurrence.state === "completed" || occurrence.state === "reused" || occurrence.state === "failed" || occurrence.state === "cancelled") throw new Error(`occurrence ${occurrence.id} failed after terminal state`);
      if ([...occurrence.attempts.values()].some((attempt) => attempt.state === "running")) throw new Error(`occurrence ${occurrence.id} failed with an active attempt`);
      occurrence.state = "failed";
      occurrence.answer = text(event.message, "message");
      occurrence.failureClass = runtimeFailureClass(event.failure);
      return;
    }
    case "trace.ordered":
      if (snapshot.traceRecorded) throw new Error("trace.ordered was emitted more than once");
      if (!Array.isArray(event.occurrenceIds) || !event.occurrenceIds.every((id) => typeof id === "string")
        || new Set(event.occurrenceIds).size !== event.occurrenceIds.length
        || event.occurrenceIds.some((id) => !snapshot.occurrences.has(id))) {
        throw new Error("trace.ordered occurrenceIds are invalid or unknown");
      }
      if (event.occurrenceIds.length !== snapshot.occurrences.size
        || [...snapshot.occurrences.values()].some((occurrence) => occurrence.state !== "completed" && occurrence.state !== "reused")) {
        throw new Error("trace.ordered was emitted before all occurrences completed");
      }
      snapshot.authoredOrder = [...event.occurrenceIds];
      snapshot.traceRecorded = true;
      return;
    case "control.ack": {
      if (snapshot.status !== "running" && snapshot.status !== "cancelling") throw new Error(`control acknowledged while run is ${snapshot.status}`);
      const controlId = runtimeControlId(event);
      const state = text(event.state, "state");
      if (!["accepted", "queued", "delivered", "rejected-stale", "unsupported", "failed"].includes(state)) throw new Error(`unknown control state ${state}`);
      const prior = snapshot.controlAcks.get(controlId);
      if (prior && ((prior.state !== "accepted" && prior.state !== "queued") || state === "accepted" || state === "queued")) throw new Error(`invalid acknowledgement transition ${prior.state} -> ${state}`);
      snapshot.controlAcks.set(controlId, {
        controlId,
        state,
        message: text(event.message, "message"),
      });
      return;
    }
    case "run.completed":
      if (snapshot.status !== "running" || !snapshot.traceRecorded || snapshot.authoredOrder.length !== snapshot.occurrences.size
        || [...snapshot.occurrences.values()].some((occurrence) => occurrence.state !== "completed" && occurrence.state !== "reused")) {
        throw new Error("run completed before authored trace/occurrences completed");
      }
      snapshot.status = "succeeded";
      snapshot.billFresh = naturalText(event.billFresh, "billFresh");
      snapshot.billMemo = naturalText(event.billMemo, "billMemo");
      return;
    case "run.failed":
      if (snapshot.status !== "running" && snapshot.status !== "cancelling") throw new Error(`run failed while ${snapshot.status}`);
      snapshot.status = "failed";
      snapshot.failure = text(event.message, "message");
      snapshot.failureClass = runtimeFailureClass(event.failure);
      return;
    case "run.cancelled":
      if (snapshot.status !== "running" && snapshot.status !== "cancelling") throw new Error(`run cancelled while ${snapshot.status}`);
      snapshot.status = "cancelled";
      snapshot.failureClass = "cancelled";
      snapshot.failure = text(event.message, "message");
      return;
    default:
      throw new Error(`unknown runtime event ${event.type}`);
  }
}

function occurrenceOf(snapshot: RunSnapshot, event: RuntimeEvent["event"]): OccurrenceSnapshot {
  const id = occurrenceId(event);
  const occurrence = snapshot.occurrences.get(id);
  if (!occurrence) throw new Error(`unknown occurrence ${id}`);
  return occurrence;
}

function attemptOf(snapshot: RunSnapshot, event: RuntimeEvent["event"]): AttemptSnapshot {
  const occurrence = occurrenceOf(snapshot, event);
  const id = attemptId(event);
  const attempt = occurrence.attempts.get(id);
  if (!attempt) throw new Error(`unknown attempt ${id}`);
  return attempt;
}

function attemptId(event: RuntimeEvent["event"]): string {
  return `${occurrenceId(event)}:${decimalText(event.attempt, "attempt", MAX_WORD32)}`;
}

function occurrenceId(event: RuntimeEvent["event"]): string {
  return decimalText(event.occurrenceId, "occurrenceId", MAX_WORD64);
}

function decimalText(value: unknown, field: string, maximum: bigint): string {
  const encoded = text(value, field);
  if (!/^(0|[1-9][0-9]*)$/.test(encoded)) throw new Error(`${field} is not an unsigned decimal string`);
  if (BigInt(encoded) > maximum) throw new Error(`${field} exceeds its unsigned range`);
  return encoded;
}

function runtimeControlId(event: RuntimeEvent["event"]): string {
  const id = text(event.controlId, "controlId");
  if (id.length > 128 || !/^[\p{L}\p{N}._-]+$/u.test(id)) throw new Error("controlId is invalid");
  return id;
}

function runtimeFailureClass(value: unknown): string {
  const failure = text(value, "failure");
  if (!["setup", "transport", "decode", "protocol", "cancelled", "runtime"].includes(failure)) throw new Error(`unknown failure class ${failure}`);
  return failure;
}

function naturalText(value: unknown, field: string): string {
  const encoded = text(value, field);
  if (!/^(0|[1-9][0-9]*)$/.test(encoded)) throw new Error(`${field} is not an unsigned decimal string`);
  return encoded;
}

function requireAttemptRunning(attempt: AttemptSnapshot, operation: string): void {
  if (attempt.state !== "running") throw new Error(`attempt ${attempt.id} cannot accept ${operation} while ${attempt.state}`);
}

function isTerminal(status: RunSnapshot["status"]): boolean {
  return status === "succeeded" || status === "failed" || status === "cancelled" || status === "orphaned";
}

function text(value: unknown, field: string): string {
  if (typeof value !== "string") throw new Error(`${field} is not text`);
  return value;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function tail(value: string): string {
  const bytes = Buffer.from(value);
  if (bytes.length <= OUTPUT_TAIL) return value;
  let start = bytes.length - OUTPUT_TAIL;
  while (start < bytes.length && (bytes[start] & 0xc0) === 0x80) start += 1;
  return bytes.subarray(start).toString("utf8");
}
