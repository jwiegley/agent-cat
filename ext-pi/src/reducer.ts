import { createHash } from "node:crypto";
import type { AttemptSnapshot, OccurrenceSnapshot, PublicTodoItem, PublicToolProgress, PublicUsage, RunSnapshot, RuntimeEvent } from "./types.ts";

const OUTPUT_TAIL = 64 * 1024;
const MAX_WORD64 = (1n << 64n) - 1n;
const MAX_WORD32 = (1n << 32n) - 1n;
const MAX_OCCURRENCES = 2_048;
const MAX_ATTEMPTS = 512;
const MAX_STEERS = 256;
const MAX_CONTROLS = 256;
const MAX_OPTIONS = 64;
const MAX_HISTORY = 64;

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
  if (envelope.protocolVersion !== 1 && envelope.protocolVersion !== 2) throw new Error(`unsupported protocol version ${envelope.protocolVersion}`);
  if (current.protocolVersion !== undefined && current.protocolVersion !== envelope.protocolVersion) throw new Error("protocol version changed within one run");
  if (envelope.runId !== current.runId) throw new Error(`run id changed from ${current.runId} to ${envelope.runId}`);
  if (typeof envelope.timestamp !== "string" || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$/.test(envelope.timestamp) || !Number.isFinite(Date.parse(envelope.timestamp))) {
    throw new Error("timestamp is not canonical UTC ISO-8601");
  }
  if (!/^(0|[1-9][0-9]*)$/.test(envelope.sequence)) throw new Error("sequence is not an unsigned decimal string");

  const seen = current.eventDigests;
  const encodedEnvelope = JSON.stringify(envelope);
  const digest = createHash("sha256").update(encodedEnvelope).digest("hex");
  const prior = seen.get(envelope.sequence);
  if (prior !== undefined) {
    throw new Error(prior === digest ? `duplicate sequence ${envelope.sequence}` : `conflicting duplicate sequence ${envelope.sequence}`);
  }

  const sequence = BigInt(envelope.sequence);
  if (sequence > MAX_WORD64) throw new Error("sequence exceeds unsigned 64-bit range");
  const expected = current.lastSequence === undefined ? 0n : current.lastSequence + 1n;
  if (sequence !== expected) throw new Error(`sequence gap: expected ${expected}, got ${sequence}`);
  if (isTerminal(current.status)) throw new Error(`post-terminal event ${envelope.event.type}`);
  const nextDigests = new Map([[envelope.sequence, digest]]);

  const next: RunSnapshot = {
    ...current,
    protocolVersion: envelope.protocolVersion,
    lastSequence: sequence,
    occurrences: new Map([...current.occurrences].map(([id, occurrence]) => [id, { ...occurrence, personQuestion: occurrence.personQuestion ? { ...occurrence.personQuestion } : undefined, dispatch: occurrence.dispatch ? { ...occurrence.dispatch, targets: [...occurrence.dispatch.targets], redirect: occurrence.dispatch.redirect ? { ...occurrence.dispatch.redirect } : undefined } : undefined, recovery: occurrence.recovery ? { ...occurrence.recovery, retries: [...occurrence.recovery.retries], choices: [...occurrence.recovery.choices] } : undefined, attempts: new Map([...occurrence.attempts].map(([attemptId, attempt]) => [attemptId, { ...attempt, steers: [...attempt.steers], messages: [...attempt.messages], tools: new Map(attempt.tools), todos: [...attempt.todos], usage: attempt.usage ? { ...attempt.usage } : undefined, reasoningSummaries: [...attempt.reasoningSummaries] }])) }])),
    authoredOrder: [...current.authoredOrder],
    eventDigests: nextDigests,
    controlAcks: new Map(current.controlAcks),
    result: current.result ? { ...current.result } : undefined,
  };
  apply(next, envelope.event, envelope.protocolVersion);
  return next;
}

export function snapshotValue(snapshot: RunSnapshot): unknown {
  const occurrences = [...snapshot.occurrences.values()]
    .sort((left, right) => compareDecimal(left.id, right.id))
    .map((occurrence) => ({
      id: occurrence.id,
      state: occurrence.state,
      code: occurrence.code ?? null,
      intent: occurrence.intent ?? null,
      addressee: occurrence.addressee ?? null,
      prompt: occurrence.prompt ?? null,
      answer: occurrence.answer ?? null,
      dispatch: occurrence.dispatch ? {
        targets: [...occurrence.dispatch.targets],
        open: occurrence.dispatch.open,
        redirect: occurrence.dispatch.redirect ?? null,
      } : null,
      recovery: occurrence.recovery ? {
        gap: occurrence.recovery.gap,
        message: occurrence.recovery.message,
        retries: [...occurrence.recovery.retries],
        choices: occurrence.recovery.choices.map((choice) => ({
          choice: choice.choice,
          ...(choice.target === undefined ? {} : { target: choice.target }),
        })),
        chosen: occurrence.recovery.chosen ? {
          controlId: occurrence.recovery.chosen.controlId,
          choice: occurrence.recovery.chosen.choice,
          target: occurrence.recovery.chosen.target ?? null,
        } : null,
      } : null,
      reuseKind: occurrence.reuseKind ?? null,
      source: occurrence.source ?? null,
      failureClass: occurrence.failureClass ?? null,
      replayable: occurrence.replayable,
      attempts: [...occurrence.attempts.values()]
        .sort((left, right) => compareAttempt(left.id, right.id))
        .map((attempt) => ({
          id: attempt.id,
          target: attempt.target ?? null,
          state: attempt.state,
          output: attempt.output,
          steers: attempt.steers.map((steer) => ({ ...steer })),
          failure: attempt.failure ?? null,
          failureClass: attempt.failureClass ?? null,
          ...(attempt.messages.length ? { messages: [...attempt.messages] } : {}),
          ...(attempt.tools.size ? { tools: [...attempt.tools.values()].sort((left, right) => compareText(left.id, right.id)).map((tool) => ({ ...tool })) } : {}),
          ...(attempt.todos.length ? { todos: attempt.todos.map((todo) => ({ ...todo })) } : {}),
          ...(attempt.usage ? { usage: { ...attempt.usage } } : {}),
          ...(attempt.reasoningSummaries.length ? { reasoningSummaries: [...attempt.reasoningSummaries] } : {}),
        })),
      ...(occurrence.personQuestion ? {
        personQuestion: { ...occurrence.personQuestion },
        personPending: occurrence.personPending ?? false,
      } : {}),
    }));
  return {
    runId: snapshot.runId,
    status: snapshot.status,
    lastSequence: snapshot.lastSequence?.toString() ?? null,
    workflow: snapshot.workflow ?? null,
    target: snapshot.target ?? null,
    occurrences,
    authoredOrder: [...snapshot.authoredOrder],
    traceRecorded: snapshot.traceRecorded,
    controlAcks: [...snapshot.controlAcks.values()]
      .sort((left, right) => compareText(left.controlId, right.controlId))
      .map((acknowledgement) => ({ ...acknowledgement })),
    billFresh: snapshot.billFresh ?? null,
    billMemo: snapshot.billMemo ?? null,
    failure: snapshot.failure ?? null,
    failureClass: snapshot.failureClass ?? null,
    ...(snapshot.personAnswering ? { personAnswering: snapshot.personAnswering } : {}),
    ...(snapshot.result ? { result: { ...snapshot.result } } : {}),
  };
}

function compareDecimal(left: string, right: string): number {
  const a = BigInt(left);
  const b = BigInt(right);
  return a < b ? -1 : a > b ? 1 : 0;
}

function compareAttempt(left: string, right: string): number {
  const [leftOccurrence, leftAttempt] = left.split(":");
  const [rightOccurrence, rightAttempt] = right.split(":");
  return compareDecimal(leftOccurrence, rightOccurrence) || compareDecimal(leftAttempt, rightAttempt);
}

function compareText(left: string, right: string): number {
  return left < right ? -1 : left > right ? 1 : 0;
}

function apply(snapshot: RunSnapshot, event: RuntimeEvent["event"], protocolVersion: number): void {
  switch (event.type) {
    case "run.started":
      if (snapshot.status !== "starting" && snapshot.status !== "cancelling") throw new Error("run.started is not first");
      if (snapshot.status !== "cancelling") snapshot.status = "running";
      snapshot.workflow = text(event.workflow, "workflow");
      snapshot.target = text(event.target, "target");
      if (protocolVersion === 2) {
        const answering = text(event.personAnswering, "personAnswering");
        if (answering !== "engine" && answering !== "local-control") throw new Error(`unknown person answering mode ${answering}`);
        snapshot.personAnswering = answering;
      }
      return;
    case "occurrence.started": {
      const id = occurrenceId(event);
      if (snapshot.status !== "running") throw new Error("occurrence started before run");
      if (snapshot.occurrences.has(id)) throw new Error(`duplicate occurrence ${id}`);
      if (snapshot.occurrences.size >= MAX_OCCURRENCES) throw new Error(`runtime snapshot exceeds ${MAX_OCCURRENCES} occurrences`);
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
      if (attemptCount(snapshot) >= MAX_ATTEMPTS) throw new Error(`runtime snapshot exceeds ${MAX_ATTEMPTS} attempts`);
      if (occurrence.dispatch) occurrence.dispatch.open = false;
      occurrence.attempts.set(id, {
        id, state: "running", target: text(event.target, "target"), output: "", steers: [],
        messages: [], tools: new Map(), todos: [], reasoningSummaries: [],
      });
      return;
    }
    case "attempt.output": {
      const attempt = attemptOf(snapshot, event);
      requireAttemptRunning(attempt, "output");
      attempt.output = tail(attempt.output + text(event.chunk, "chunk"));
      return;
    }
    case "attempt.progress": {
      if (protocolVersion !== 2) throw new Error("attempt progress is unavailable in protocol version 1");
      const attempt = attemptOf(snapshot, event);
      requireAttemptRunning(attempt, "progress");
      applyProgress(attempt, event.progress);
      return;
    }
    case "attempt.steered": {
      const occurrence = occurrenceOf(snapshot, event);
      const attempt = attemptOf(snapshot, event);
      requireAttemptRunning(attempt, "steering");
      if (steerCount(snapshot) >= MAX_STEERS) throw new Error(`runtime snapshot exceeds ${MAX_STEERS} steer records`);
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
      if (occurrence.state !== "running" || occurrence.attempts.size !== 0 || occurrence.personPending) {
        throw new Error(`occurrence ${occurrence.id} cannot be reused while physically active`);
      }
      occurrence.state = "reused";
      occurrence.reuseKind = text(event.answerGroup, "answerGroup");
      if (occurrence.dispatch) occurrence.dispatch.open = false;
      return;
    }
    case "occurrence.recovery-pending": {
      const occurrence = occurrenceOf(snapshot, event);
      if (occurrence.state !== "running") throw new Error(`occurrence ${occurrence.id} cannot enter recovery while ${occurrence.state}`);
      occurrence.state = "recovering";
      if (!Array.isArray(event.choices) || event.choices.length === 0) throw new Error("recovery choices are missing");
      if (event.choices.length > MAX_OPTIONS) throw new Error(`runtime snapshot recovery exceeds ${MAX_OPTIONS} choices`);
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
      if (occurrence.recovery.retries.length >= MAX_HISTORY) throw new Error(`runtime snapshot recovery exceeds ${MAX_HISTORY} retries`);
      occurrence.recovery.retries.push(runtimeControlId(event));
      occurrence.state = "running";
      return;
    }
    case "occurrence.dispatch-pending": {
      const occurrence = occurrenceOf(snapshot, event);
      if (occurrence.state !== "running" || occurrence.dispatch) throw new Error(`occurrence ${occurrence.id} cannot open dispatch`);
      if (!Array.isArray(event.targets) || event.targets.length === 0 || !event.targets.every((target) => typeof target === "string") || new Set(event.targets).size !== event.targets.length) throw new Error("dispatch targets are invalid");
      if (event.targets.length > MAX_OPTIONS) throw new Error(`runtime snapshot dispatch exceeds ${MAX_OPTIONS} targets`);
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
    case "occurrence.person-answer-pending": {
      if (protocolVersion !== 2) throw new Error("person answer event is unavailable in protocol version 1");
      const occurrence = occurrenceOf(snapshot, event);
      if (occurrence.state !== "running" || !occurrence.addressee?.startsWith("person ")
        || occurrence.attempts.size !== 0 || occurrence.personPending || occurrence.personQuestion) {
        throw new Error(`occurrence ${occurrence.id} cannot wait for a person answer`);
      }
      occurrence.personQuestion = questionRef(event.question);
      occurrence.personPending = true;
      return;
    }
    case "occurrence.completed": {
      const occurrence = occurrenceOf(snapshot, event);
      if (occurrence.state !== "running" && occurrence.state !== "reused") throw new Error(`occurrence ${occurrence.id} cannot complete while ${occurrence.state}`);
      if (occurrence.personPending) throw new Error(`occurrence ${occurrence.id} completed while waiting for a person answer`);
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
      const command = protocolVersion === 2 ? controlCommand(event.command) : undefined;
      const occurrenceId = protocolVersion === 2 && event.occurrenceId !== null && event.occurrenceId !== undefined
        ? decimalText(event.occurrenceId, "occurrenceId", MAX_WORD64) : undefined;
      const attempt = protocolVersion === 2 && event.attemptId !== null && event.attemptId !== undefined
        ? attemptReference(event.attemptId) : undefined;
      const prior = snapshot.controlAcks.get(controlId);
      const nextAck = {
        controlId,
        state,
        message: text(event.message, "message"),
        ...(command ? { command } : {}),
        ...(occurrenceId ? { occurrenceId } : {}),
        ...(attempt ? { attemptId: attempt } : {}),
      };
      if (prior && JSON.stringify(prior) === JSON.stringify(nextAck)) return;
      if (!prior && snapshot.controlAcks.size >= MAX_CONTROLS) throw new Error(`runtime snapshot exceeds ${MAX_CONTROLS} control acknowledgements`);
      if (prior && (
        prior.command !== command
        || prior.occurrenceId !== occurrenceId
        || JSON.stringify(prior.attemptId) !== JSON.stringify(attempt)
      )) throw new Error("control acknowledgement correlation mismatch: command or target identity changed");
      if (prior && ((prior.state !== "accepted" && prior.state !== "queued") || state === "accepted" || state === "queued")) throw new Error(`invalid acknowledgement transition ${prior.state} -> ${state}`);
      if (command === "answerPerson" && (state === "delivered" || state === "failed")
        && (!prior || prior.state !== "accepted")) {
        throw new Error("person answer terminal acknowledgement was not preceded by acceptance");
      }
      if (command === "answerPerson") {
        if (!occurrenceId) throw new Error("person answer acknowledgement has no occurrence id");
        if (attempt) throw new Error("person answer acknowledgement has an attempt id");
        const occurrence = snapshot.occurrences.get(occurrenceId);
        if (!occurrence?.personPending) throw new Error(`occurrence ${occurrenceId} is not waiting for a person answer`);
        if (state === "delivered") occurrence.personPending = false;
      }
      snapshot.controlAcks.set(controlId, nextAck);
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
      if (protocolVersion === 2) snapshot.result = resultRef(event.result);
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

function applyProgress(attempt: AttemptSnapshot, value: unknown): void {
  if (!isRecord(value)) throw new Error("public progress is not an object");
  const kind = text(value.kind, "public progress kind");
  if (kind === "message" || kind === "reasoning-summary") {
    const content = boundedProgressText(value.text, kind, 4096);
    const target = kind === "message" ? attempt.messages : attempt.reasoningSummaries;
    target.push(content);
    const maximum = kind === "message" ? 64 : 32;
    if (target.length > maximum) target.splice(0, target.length - maximum);
    return;
  }
  if (kind === "tool") {
    if (!isRecord(value.tool)) throw new Error("public tool update is not an object");
    const identifier = progressIdentifier(value.tool.id, "public tool id");
    const previous = attempt.tools.get(identifier);
    if (!previous && attempt.tools.size >= 128) throw new Error("runtime snapshot exceeds 128 public tools in one attempt");
    const update: PublicToolProgress = {
      id: identifier,
      ...optionalProgressText(value.tool.title, "public tool title", 1024, "title"),
      ...optionalProgressText(value.tool.toolKind, "public tool kind", 128, "toolKind"),
      ...optionalToolStatus(value.tool.status),
      ...optionalProgressText(value.tool.summary, "public tool summary", 4096, "summary"),
    };
    attempt.tools.set(identifier, { ...previous, ...update });
    return;
  }
  if (kind === "todos") {
    if (!Array.isArray(value.items) || value.items.length > 128) throw new Error("public todo snapshot is invalid");
    attempt.todos = value.items.map((item): PublicTodoItem => {
      if (!isRecord(item)) throw new Error("public todo item is not an object");
      const priority = text(item.priority, "public todo priority");
      const status = text(item.status, "public todo status");
      if (!["high", "medium", "low"].includes(priority)) throw new Error(`unknown public todo priority ${priority}`);
      if (!["pending", "in_progress", "completed"].includes(status)) throw new Error(`unknown public todo status ${status}`);
      return { content: boundedProgressText(item.content, "public todo content", 1024), priority: priority as PublicTodoItem["priority"], status: status as PublicTodoItem["status"] };
    });
    return;
  }
  if (kind === "usage") {
    if (!isRecord(value.usage)) throw new Error("public usage is not an object");
    const used = naturalText(value.usage.used, "public usage used");
    const size = naturalText(value.usage.size, "public usage size");
    if (BigInt(size) <= 0n || BigInt(used) > BigInt(size)) throw new Error("public usage is outside its context window");
    attempt.usage = { used, size } as PublicUsage;
    return;
  }
  throw new Error(`unknown public progress kind ${kind}`);
}

function boundedProgressText(value: unknown, label: string, maximum: number): string {
  const result = text(value, label);
  if (!result || Array.from(result).length > maximum) throw new Error(`${label} is empty or too long`);
  return result;
}

function progressIdentifier(value: unknown, label: string): string {
  const result = text(value, label);
  if (!result || Array.from(result).length > 128 || !/^[\p{L}\p{N}._:-]+$/u.test(result)) throw new Error(`${label} is invalid`);
  return result;
}

function optionalProgressText(value: unknown, label: string, maximum: number, key: "title" | "toolKind" | "summary"): Partial<PublicToolProgress> {
  return value === undefined ? {} : { [key]: boundedProgressText(value, label, maximum) };
}

function optionalToolStatus(value: unknown): Partial<PublicToolProgress> {
  if (value === undefined) return {};
  const status = text(value, "public tool status");
  if (!["pending", "in_progress", "completed", "failed", "cancelled"].includes(status)) throw new Error(`unknown public tool status ${status}`);
  return { status: status as PublicToolProgress["status"] };
}

function attemptCount(snapshot: RunSnapshot): number {
  return [...snapshot.occurrences.values()].reduce((total, occurrence) => total + occurrence.attempts.size, 0);
}

function steerCount(snapshot: RunSnapshot): number {
  return [...snapshot.occurrences.values()].reduce(
    (total, occurrence) => total + [...occurrence.attempts.values()].reduce((attemptTotal, attempt) => attemptTotal + attempt.steers.length, 0),
    0,
  );
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

function attemptReference(value: unknown): string {
  if (!isRecord(value)) throw new Error("attemptId is not an object");
  return `${decimalText(value.occurrenceId, "attempt occurrenceId", MAX_WORD64)}:${decimalText(value.attemptNumber, "attemptNumber", MAX_WORD32)}`;
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

function integerNumber(value: unknown, field: string): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value)) throw new Error(`${field} is not a safe integer`);
  return value;
}

function questionRef(value: unknown): import("./types.ts").QuestionRef {
  if (!isRecord(value)) throw new Error("question reference is not an object");
  const reference = {
    artifactVersion: integerNumber(value.artifactVersion, "artifactVersion"),
    path: text(value.path, "path"),
    sha256: text(value.sha256, "sha256"),
    bytes: naturalText(value.bytes, "bytes"),
  };
  if (reference.artifactVersion !== 1 || !/^person\/questions\/(0|[1-9][0-9]*)\.json$/.test(reference.path)) throw new Error("invalid question artifact reference");
  validateArtifactReference(reference.sha256, reference.bytes);
  return reference;
}

function resultRef(value: unknown): import("./types.ts").ResultRef {
  if (!isRecord(value)) throw new Error("result reference is not an object");
  if (!Object.prototype.hasOwnProperty.call(value, "code")) throw new Error("result reference code is missing");
  const reference = {
    artifactVersion: integerNumber(value.artifactVersion, "artifactVersion"),
    path: text(value.path, "path"),
    sha256: text(value.sha256, "sha256"),
    bytes: naturalText(value.bytes, "bytes"),
    code: value.code,
    preview: text(value.preview, "preview"),
  };
  if (reference.artifactVersion !== 1 || reference.path !== "result.json" || Array.from(reference.preview).length > 500 || /[\r\n]/.test(reference.preview)) throw new Error("invalid result artifact reference");
  validateArtifactReference(reference.sha256, reference.bytes);
  return reference;
}

function validateArtifactReference(sha256: string, bytes: string): void {
  if (!/^[0-9a-f]{64}$/.test(sha256)) throw new Error("invalid artifact SHA-256");
  const count = BigInt(bytes);
  if (count <= 0n || count > 67_108_864n) throw new Error("artifact byte count is outside the supported bound");
}

function controlCommand(value: unknown): string {
  const command = text(value, "command");
  if (!["cancelRun", "steerOccurrence", "retryOccurrence", "failoverOccurrence", "abandonOccurrence", "redirectOccurrence", "answerPerson", "invalid"].includes(command)) {
    throw new Error(`unknown runtime control command ${command}`);
  }
  return command;
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
