import { randomUUID } from "node:crypto";
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { appendFile, mkdir, readFile, readdir, rename, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { initialSnapshot, reduceEvent } from "./reducer.ts";
import type { PreparedLaunch } from "./launch.ts";
import type { ControlAckSnapshot, LaunchManifest, RunSnapshot, RuntimeEvent } from "./types.ts";

const MAX_FRAME = 1024 * 1024;
const MAX_STDERR_LOG = 10 * 1024 * 1024;
const STDERR_TRUNCATION_MARKER = Buffer.from("\n[agent-cat stderr truncated at 10485760 bytes]\n");

type Listener = (snapshot: RunSnapshot) => void;

export interface RunHandle {
  readonly snapshot: RunSnapshot;
  readonly manifest: LaunchManifest;
  readonly storeDir: string;
  readonly finished: Promise<RunSnapshot>;
  subscribe(listener: Listener): () => void;
  cancel(reason?: string): Promise<void>;
  steer(occurrenceId: string, attemptId: string, text: string, timing: "interrupt-now" | "next-boundary"): Promise<ControlAckSnapshot>;
  retry(occurrenceId: string): Promise<ControlAckSnapshot>;
  recover(occurrenceId: string, choice: "retry" | "failover" | "abandon"): Promise<ControlAckSnapshot>;
  redirect(occurrenceId: string, target: string): Promise<ControlAckSnapshot>;
  disposeMonitor?(): void;
}

export class RunSupervisor {
  readonly #runs = new Map<string, OwnedRun>();
  readonly #history = new Map<string, RunHandle>();

  start(prepared: PreparedLaunch): OwnedRun {
    if (this.#runs.has(prepared.manifest.runId) || this.#history.has(prepared.manifest.runId)) throw new Error(`duplicate run ${prepared.manifest.runId}`);
    const run = new OwnedRun(prepared, () => {
      this.#runs.delete(prepared.manifest.runId);
      this.#history.set(prepared.manifest.runId, run);
      while (this.#history.size > 100) this.#history.delete(this.#history.keys().next().value!);
    });
    this.#runs.set(prepared.manifest.runId, run);
    run.start();
    return run;
  }

  get(runId: string): RunHandle | undefined {
    return this.#runs.get(runId) ?? this.#history.get(runId);
  }

  activeSnapshots(): RunSnapshot[] {
    return [...this.#runs.values()].map((run) => run.snapshot).filter((snapshot) => !isTerminal(snapshot.status));
  }

  async restore(stateDir: string, policy: { days: number; maxRuns: number } = { days: 30, maxRuns: 100 }): Promise<void> {
    const root = join(stateDir, "runs");
    let entries;
    try {
      entries = await readdir(root, { withFileTypes: true });
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") return;
      throw error;
    }
    const records: Array<{ storeDir: string; manifest: LaunchManifest; snapshot: RunSnapshot; created: number; ownerLive: boolean }> = [];
    for (const entry of entries.filter((item) => item.isDirectory())) {
      const storeDir = join(root, entry.name);
      const manifest = parseLaunchManifest(JSON.parse(await readFile(join(storeDir, "supervisor-manifest.json"), "utf8")));
      const created = Date.parse(manifest.createdAt);
      if (!Number.isFinite(created)) throw new Error(`run ${manifest.runId} has an invalid createdAt`);
      const ownerLive = await ownerIsLive(storeDir);
      let snapshot: RunSnapshot;
      try {
        snapshot = await restoreSnapshot(storeDir, manifest.runId, ownerLive);
      } catch (error) {
        snapshot = {
          ...initialSnapshot(manifest.runId),
          status: "failed",
          failureClass: "corrupt-store",
          failure: error instanceof Error ? error.message : String(error),
        };
      }
      records.push({ storeDir, manifest, snapshot, created, ownerLive });
    }
    records.sort((left, right) => left.created - right.created);
    const protectedParents = new Set(records.flatMap(({ manifest }) => manifest.parentRunId ? [manifest.parentRunId] : []));
    const remove = new Set<string>();
    const cutoff = policy.days === 0 ? Number.NEGATIVE_INFINITY : Date.now() - policy.days * 86_400_000;
    for (const record of records) {
      if (record.created < cutoff && isPrunable(record, protectedParents)) remove.add(record.manifest.runId);
    }
    if (policy.maxRuns > 0) {
      for (const record of records) {
        if (records.length - remove.size <= policy.maxRuns) break;
        if (isPrunable(record, protectedParents)) remove.add(record.manifest.runId);
      }
    }
    for (const record of records) {
      if (remove.has(record.manifest.runId)) {
        await rm(record.storeDir, { recursive: true, force: true });
      } else if (!this.#runs.has(record.manifest.runId) && !this.#history.has(record.manifest.runId)) {
        this.#history.set(record.manifest.runId, new RestoredRun(record.manifest, record.storeDir, record.snapshot, record.ownerLive));
      }
    }
  }

  snapshots(): RunSnapshot[] {
    return [...this.#history.values(), ...this.#runs.values()].map((run) => run.snapshot);
  }

  async shutdown(): Promise<void> {
    for (const run of this.#history.values()) run.disposeMonitor?.();
    await Promise.allSettled([...this.#runs.values()].map((run) => run.cancel("extension shutdown")));
  }
}

export class OwnedRun {
  readonly #prepared: PreparedLaunch;
  readonly #onTerminal: () => void;
  readonly #listeners = new Set<Listener>();
  readonly finished: Promise<RunSnapshot>;
  #resolveFinished!: (snapshot: RunSnapshot) => void;
  #snapshot: RunSnapshot;
  #child?: ChildProcessWithoutNullStreams;
  #buffer = "";
  #terminal = false;
  #forcedTermination = false;
  #cancelRequested = false;
  #stderrBytes = 0;
  #stderrQueue: Promise<void> = Promise.resolve();
  #eventMirrorQueue: Promise<void> = Promise.resolve();
  #leaseQueue: Promise<void> = Promise.resolve();
  #leaseTimer?: NodeJS.Timeout;
  readonly #ownerId = randomUUID();
  #fatalCleanup?: Promise<void>;
  readonly #controlWaiters = new Map<string, { resolve: (ack: ControlAckSnapshot) => void; reject: (error: Error) => void; timeout: NodeJS.Timeout }>();
  readonly #secretValues: string[];

  constructor(prepared: PreparedLaunch, onTerminal: () => void) {
    this.#prepared = prepared;
    this.#onTerminal = onTerminal;
    this.#snapshot = initialSnapshot(prepared.manifest.runId);
    this.#secretValues = Object.entries(prepared.env)
      .filter(([key, value]) => /(?:token|secret|password|api[_-]?key|authorization)/i.test(key) && typeof value === "string" && value.length >= 8)
      .map(([, value]) => value as string);
    this.finished = new Promise((resolve) => {
      this.#resolveFinished = resolve;
    });
  }

  get manifest(): PreparedLaunch["manifest"] {
    return this.#prepared.manifest;
  }

  get storeDir(): string {
    return this.#prepared.storeDir;
  }

  get snapshot(): RunSnapshot {
    return this.#snapshot;
  }

  subscribe(listener: Listener): () => void {
    this.#listeners.add(listener);
    listener(this.#snapshot);
    return () => this.#listeners.delete(listener);
  }

  steer(occurrenceId: string, attemptId: string, text: string, timing: "interrupt-now" | "next-boundary"): Promise<ControlAckSnapshot> {
    if (this.#terminal || isTerminal(this.#snapshot.status)) throw new Error("run is terminal");
    if (!text.trim()) throw new Error("steering text is empty");
    if (Buffer.byteLength(text) > 64 * 1024) throw new Error("steering text exceeds 65536 bytes");
    const occurrence = this.#snapshot.occurrences.get(occurrenceId);
    const attempt = occurrence?.attempts.get(attemptId);
    if (!attempt || attempt.state !== "running") throw new Error(`attempt ${attemptId} is not active`);
    const prefix = `${occurrenceId}:`;
    const attemptNumber = attemptId.startsWith(prefix) ? attemptId.slice(prefix.length) : "";
    if (!/^(0|[1-9][0-9]*)$/.test(attemptNumber)) throw new Error(`invalid attempt id ${attemptId}`);
    const controlId = `steer-${randomUUID()}`;
    return this.#sendControlAwait(controlId, {
      controlId,
      expectedOccurrenceId: occurrenceId,
      expectedAttemptId: { occurrenceId, attemptNumber },
      command: { type: "steerOccurrence", timing, text },
    });
  }

  retry(occurrenceId: string): Promise<ControlAckSnapshot> {
    return this.recover(occurrenceId, "retry");
  }

  recover(occurrenceId: string, choice: "retry" | "failover" | "abandon"): Promise<ControlAckSnapshot> {
    if (this.#terminal || isTerminal(this.#snapshot.status)) throw new Error("run is terminal");
    const occurrence = this.#snapshot.occurrences.get(occurrenceId);
    if (!occurrence || occurrence.state !== "recovering") throw new Error(`occurrence ${occurrenceId} is not waiting for recovery`);
    if (!occurrence.recovery?.choices.some((offered) => offered.choice === choice)) throw new Error(`recovery choice ${choice} was not offered for occurrence ${occurrenceId}`);
    const controlId = `${choice}-${randomUUID()}`;
    const type = choice === "retry" ? "retryOccurrence" : choice === "failover" ? "failoverOccurrence" : "abandonOccurrence";
    return this.#sendControlAwait(controlId, {
      controlId,
      expectedOccurrenceId: occurrenceId,
      expectedAttemptId: null,
      command: { type },
    });
  }

  redirect(occurrenceId: string, target: string): Promise<ControlAckSnapshot> {
    if (this.#terminal || isTerminal(this.#snapshot.status)) throw new Error("run is terminal");
    const occurrence = this.#snapshot.occurrences.get(occurrenceId);
    if (!occurrence?.dispatch?.open) throw new Error(`occurrence ${occurrenceId} is not waiting for redirect`);
    if (!occurrence.dispatch.targets.includes(target)) throw new Error(`target ${target} was not reserved`);
    if ([...occurrence.attempts.values()].some((attempt) => attempt.state === "running")) throw new Error("cannot redirect an active attempt");
    const controlId = `redirect-${randomUUID()}`;
    return this.#sendControlAwait(controlId, {
      controlId,
      expectedOccurrenceId: occurrenceId,
      expectedAttemptId: null,
      command: { type: "redirectOccurrence", target },
    });
  }

  start(): void {
    this.#queueOwnerHeartbeat();
    this.#leaseTimer = setInterval(() => this.#queueOwnerHeartbeat(), 2_000);
    this.#leaseTimer.unref();
    if (this.#child) throw new Error("run already started");
    const child = spawn(this.#prepared.command, this.#prepared.args, {
      cwd: this.#prepared.manifest.cwd,
      env: this.#prepared.env,
      shell: false,
      stdio: ["pipe", "pipe", "pipe"],
      detached: process.platform !== "win32",
    });
    this.#child = child;
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdin.on("error", (error: NodeJS.ErrnoException) => {
      if (error.code !== "EPIPE" && error.code !== "ERR_STREAM_DESTROYED") this.#fail(`control pipe failed: ${error.message}`);
    });
    child.stdout.on("data", (chunk: string) => this.#consume(chunk));
    child.stderr.on("data", (chunk: string) => this.#queueStderr(chunk));
    child.on("error", (error) => this.#fail(`spawn failed: ${error.message}`));
    child.on("close", (code, signal) => void this.#closed(code, signal));
  }

  async cancel(reason = "cancelled by operator"): Promise<void> {
    if (this.#terminal || isTerminal(this.#snapshot.status) || this.#cancelRequested) return void (await this.finished);
    this.#cancelRequested = true;
    const child = this.#child;
    if (!child) return;
    this.#notify();
    const control = { controlId: `cancel-${Date.now()}`, expectedOccurrenceId: null, expectedAttemptId: null, command: { type: "cancelRun" } };
    this.#sendControl(control);
    const exited = await waitForExit(child, 5_000);
    if (!exited) {
      this.#forcedTermination = true;
      if (process.platform === "win32") child.kill("SIGTERM");
      else process.kill(-child.pid!, "SIGTERM");
      if (!(await waitForExit(child, 2_000))) {
        if (process.platform === "win32") child.kill("SIGKILL");
        else process.kill(-child.pid!, "SIGKILL");
      }
    }
    await appendFile(join(this.#prepared.storeDir, "supervisor.log"), `${new Date().toISOString()} ${reason}\n`, { mode: 0o600 });
    await this.finished;
  }

  #sendControl(control: unknown): void {
    const child = this.#child;
    if (!child || child.stdin.destroyed || !child.stdin.writable) throw new Error("run control channel is unavailable");
    child.stdin.write(`${JSON.stringify(control)}\n`);
  }

  #sendControlAwait(controlId: string, control: unknown): Promise<ControlAckSnapshot> {
    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        this.#controlWaiters.delete(controlId);
        reject(new Error(`control ${controlId} was not acknowledged`));
      }, 10_000);
      timeout.unref();
      this.#controlWaiters.set(controlId, { resolve, reject, timeout });
      try { this.#sendControl(control); }
      catch (error) {
        clearTimeout(timeout);
        this.#controlWaiters.delete(controlId);
        reject(error instanceof Error ? error : new Error(String(error)));
      }
    });
  }

  #settleControl(controlId: string, ack: ControlAckSnapshot): void {
    if (!['delivered', 'rejected-stale', 'unsupported', 'failed'].includes(ack.state)) return;
    const waiter = this.#controlWaiters.get(controlId);
    if (!waiter) return;
    clearTimeout(waiter.timeout);
    this.#controlWaiters.delete(controlId);
    waiter.resolve(ack);
  }


  #consume(chunk: string): void {
    this.#buffer += chunk;
    if (this.#buffer.length > MAX_FRAME * 2) return this.#fail("protocol buffer exceeded limit");
    for (;;) {
      const newline = this.#buffer.indexOf("\n");
      if (newline < 0) break;
      const line = this.#buffer.slice(0, newline);
      this.#buffer = this.#buffer.slice(newline + 1);
      this.#eventMirrorQueue = this.#eventMirrorQueue
        .then(() => appendFile(join(this.#prepared.storeDir, "live-events.ndjson"), `${line}\n`, { mode: 0o600 }))
        .catch((error) => this.#fail(`event mirror failed: ${error instanceof Error ? error.message : String(error)}`));
      if (!line) continue;
      if (Buffer.byteLength(line) > MAX_FRAME) return this.#fail("protocol frame exceeded limit");
      try {
        const envelope = JSON.parse(line) as RuntimeEvent;
        this.#snapshot = reduceEvent(this.#snapshot, envelope);
        if (envelope.event.type === "control.ack") {
          const controlId = String(envelope.event.controlId);
          const ack = this.#snapshot.controlAcks.get(controlId);
          if (ack) this.#settleControl(controlId, ack);
        }
        this.#notify();
      } catch (error) {
        this.#fail(`protocol failure: ${error instanceof Error ? error.message : String(error)}`);
      }
    }
  }

  async #closed(code: number | null, signal: NodeJS.Signals | null): Promise<void> {
    if (this.#terminal) return;
    if (this.#buffer.trim()) this.#fail("protocol ended with a torn frame");
    if (!isTerminal(this.#snapshot.status)) {
      if (this.#cancelRequested) {
        this.#snapshot = {
          ...this.#snapshot,
          status: "cancelled",
          failureClass: this.#forcedTermination ? "forced-termination" : "missing-terminal-event",
          failure: this.#forcedTermination ? "process group required forced termination" : "process exited without run.cancelled",
        };
        this.#notify();
      } else {
        this.#fail(`process exited without terminal event (code=${code}, signal=${signal})`);
      }
    }
    this.#terminal = true;
    try {
      if (this.#fatalCleanup) await this.#fatalCleanup;
      await this.#stderrQueue;
      await this.#eventMirrorQueue;
      if (this.#leaseTimer) clearInterval(this.#leaseTimer);
      await this.#leaseQueue;
      await rm(join(this.#prepared.storeDir, "owner.json"), { force: true });
      await this.#persistSnapshot();
      await rm(join(this.#prepared.storeDir, "inputs"), { recursive: true, force: true });
    } catch (error) {
      this.#snapshot = { ...this.#snapshot, status: "failed", failure: `persistence failure: ${error instanceof Error ? error.message : String(error)}` };
      this.#notify();
    } finally {
      for (const [controlId, waiter] of this.#controlWaiters) {
        clearTimeout(waiter.timeout);
        waiter.reject(new Error(`run ended before control ${controlId} reached a terminal acknowledgement`));
      }
      this.#controlWaiters.clear();
      this.#onTerminal();
      this.#resolveFinished(this.#snapshot);
    }
  }

  #queueOwnerHeartbeat(): void {
    this.#leaseQueue = this.#leaseQueue.then(async () => {
      const final = join(this.#prepared.storeDir, "owner.json");
      const temp = `${final}.tmp-${this.#ownerId}`;
      await writeFile(temp, `${JSON.stringify({ version: 1, ownerId: this.#ownerId, pid: process.pid, heartbeat: new Date().toISOString() })}\n`, { mode: 0o600 });
      await rename(temp, final);
    }).catch((error) => this.#fail(`owner lease persistence failed: ${error instanceof Error ? error.message : String(error)}`));
  }

  #queueStderr(chunk: string): void {
    this.#stderrQueue = this.#stderrQueue.then(async () => {
      if (this.#stderrBytes >= MAX_STDERR_LOG) return;
      let redacted = chunk
        .replace(/(authorization\s*:\s*bearer\s+)\S+/gi, "$1[REDACTED]")
        .replace(/((?:api[_-]?key|token|secret|password)\s*[:=]\s*)\S+/gi, "$1[REDACTED]");
      for (const secret of this.#secretValues) redacted = redacted.split(secret).join("[REDACTED]");
      const bytes = Buffer.from(redacted);
      const contentLimit = MAX_STDERR_LOG - STDERR_TRUNCATION_MARKER.length;
      const remaining = Math.max(0, contentLimit - this.#stderrBytes);
      const output = bytes.length <= remaining
        ? bytes
        : Buffer.concat([utf8Prefix(bytes, remaining), STDERR_TRUNCATION_MARKER]);
      if (output.length === 0) return;
      await appendFile(join(this.#prepared.storeDir, "stderr.log"), output, { mode: 0o600 });
      this.#stderrBytes += output.length;
    }).catch((error) => this.#fail(`stderr persistence failed: ${error instanceof Error ? error.message : String(error)}`));
  }

  #fail(message: string): void {
    if (this.#terminal) return;
    if (this.#snapshot.status !== "failed") {
      this.#snapshot = { ...this.#snapshot, status: "failed", failureClass: "supervisor", failure: message };
      this.#notify();
    }
    if (!this.#fatalCleanup) this.#fatalCleanup = this.#terminateFatalProcessGroup();
  }

  async #terminateFatalProcessGroup(): Promise<void> {
    const child = this.#child;
    if (!child || child.exitCode !== null || child.signalCode !== null) return;
    child.stdin.destroy();
    this.#signalProcessGroup("SIGTERM");
    await Promise.race([waitForExit(child, 1_000), delay(1_000)]);
    this.#signalProcessGroup("SIGKILL");
    await waitForExit(child, 2_000);
  }

  #signalProcessGroup(signal: NodeJS.Signals): void {
    const child = this.#child;
    if (!child?.pid) return;
    try {
      if (process.platform === "win32") child.kill(signal);
      else process.kill(-child.pid, signal);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ESRCH") throw error;
    }
  }

  #notify(): void {
    for (const listener of this.#listeners) listener(this.#snapshot);
  }

  async #persistSnapshot(): Promise<void> {
    await mkdir(this.#prepared.storeDir, { recursive: true, mode: 0o700 });
    const serializable = {
      ...this.#snapshot,
      lastSequence: this.#snapshot.lastSequence?.toString(),
      occurrences: [...this.#snapshot.occurrences].map(([id, value]) => [id, { ...value, attempts: [...value.attempts] }]),
      eventDigests: [...this.#snapshot.eventDigests],
      controlAcks: [...this.#snapshot.controlAcks],
    };
    await writeFile(join(this.#prepared.storeDir, "snapshot.json"), `${JSON.stringify(serializable)}\n`, { mode: 0o600 });
  }
}

class RestoredRun implements RunHandle {
  readonly manifest: LaunchManifest;
  readonly storeDir: string;
  readonly finished: Promise<RunSnapshot>;
  readonly #listeners = new Set<Listener>();
  #snapshot: RunSnapshot;
  #timer?: NodeJS.Timeout;
  #resolveFinished?: (snapshot: RunSnapshot) => void;
  constructor(manifest: LaunchManifest, storeDir: string, snapshot: RunSnapshot, ownerLive: boolean) {
    this.manifest = manifest;
    this.storeDir = storeDir;
    this.#snapshot = snapshot;
    if (ownerLive && !isTerminal(snapshot.status)) {
      this.finished = new Promise((resolve) => { this.#resolveFinished = resolve; });
      this.#timer = setInterval(() => {
        void this.#refresh().catch((error) => {
          this.#snapshot = { ...this.#snapshot, status: "failed", failureClass: "reattachment", failure: error instanceof Error ? error.message : String(error) };
          for (const listener of this.#listeners) listener(this.#snapshot);
          this.disposeMonitor();
          this.#resolveFinished?.(this.#snapshot);
        });
      }, 1_000);
      this.#timer.unref();
    } else {
      this.finished = Promise.resolve(snapshot);
    }
  }
  get snapshot(): RunSnapshot { return this.#snapshot; }
  subscribe(listener: Listener): () => void { this.#listeners.add(listener); listener(this.#snapshot); return () => this.#listeners.delete(listener); }
  async cancel(): Promise<void> { throw new Error(this.#controlError()); }
  async steer(): Promise<ControlAckSnapshot> { throw new Error(this.#controlError()); }
  async retry(): Promise<ControlAckSnapshot> { throw new Error(this.#controlError()); }
  async recover(): Promise<ControlAckSnapshot> { throw new Error(this.#controlError()); }
  async redirect(): Promise<ControlAckSnapshot> { throw new Error(this.#controlError()); }
  disposeMonitor(): void { if (this.#timer) clearInterval(this.#timer); }
  #controlError(): string { return isTerminal(this.#snapshot.status) ? "restored run has no live control channel" : "run is controlled by another live supervisor"; }
  async #refresh(): Promise<void> {
    const live = await ownerIsLive(this.storeDir);
    this.#snapshot = await restoreSnapshot(this.storeDir, this.manifest.runId, live);
    for (const listener of this.#listeners) listener(this.#snapshot);
    if (isTerminal(this.#snapshot.status)) {
      this.disposeMonitor();
      this.#resolveFinished?.(this.#snapshot);
      this.#resolveFinished = undefined;
    }
  }
}

async function restoreSnapshot(storeDir: string, runId: string, ownerLive = false): Promise<RunSnapshot> {
  const journals: RunSnapshot[] = [];
  let journalSnapshot: RunSnapshot | undefined;
  for (const path of [join(storeDir, "runtime", "events.ndjson"), join(storeDir, "live-events.ndjson")]) {
    try {
      const bytes = await readFile(path, "utf8");
      if (bytes && !bytes.endsWith("\n")) throw new Error(`${path} has a torn final protocol record`);
      let reduced = initialSnapshot(runId);
      for (const line of bytes.split("\n").filter(Boolean)) {
        if (Buffer.byteLength(line) > MAX_FRAME) throw new Error("stored protocol frame exceeded limit");
        reduced = reduceEvent(reduced, JSON.parse(line) as RuntimeEvent);
      }
      for (const prior of journals) {
        assertJournalPrefix(prior, reduced);
        const exactRequired = !ownerLive;
        if (exactRequired && ((prior.lastSequence ?? -1n) !== (reduced.lastSequence ?? -1n) || snapshotDifference(prior, reduced).length > 0)) {
          throw new Error("stored protocol journals disagree in terminal length or state");
        }
      }
      journals.push(reduced);
      if (!journalSnapshot || (reduced.lastSequence ?? -1n) > (journalSnapshot.lastSequence ?? -1n)) journalSnapshot = reduced;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    }
  }
  let snapshot: RunSnapshot;
  try {
    snapshot = parseSnapshot(JSON.parse(await readFile(join(storeDir, "snapshot.json"), "utf8")), runId);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    snapshot = journalSnapshot ?? initialSnapshot(runId);
  }
  if (journalSnapshot && isTerminal(journalSnapshot.status)) {
    if (isTerminal(snapshot.status) && snapshotDifference(snapshot, journalSnapshot).length > 0) {
      throw new Error(`stored snapshot disagrees with the terminal protocol journal (${snapshotDifference(snapshot, journalSnapshot).join(", ")})`);
    }
    return journalSnapshot;
  }
  if (isTerminal(snapshot.status)) {
    const supervisorTerminal = (snapshot.status === "failed" || snapshot.status === "cancelled")
      && ["supervisor", "forced-termination", "missing-terminal-event"].includes(snapshot.failureClass ?? "");
    if (!supervisorTerminal) throw new Error("terminal snapshot has no matching terminal protocol event");
    return snapshot;
  }
  if (ownerLive) return journalSnapshot ?? snapshot;
  const current = journalSnapshot ?? snapshot;
  return { ...current, status: "orphaned", failureClass: "lost-ownership", failure: "supervisor ownership was lost; restart, resume, or fork is required" };
}

function snapshotDifference(left: RunSnapshot, right: RunSnapshot): string[] {
  const leftValue = JSON.parse(snapshotProjection(left)) as Record<string, unknown>;
  const rightValue = JSON.parse(snapshotProjection(right)) as Record<string, unknown>;
  return [...new Set([...Object.keys(leftValue), ...Object.keys(rightValue)])]
    .filter((key) => JSON.stringify(leftValue[key]) !== JSON.stringify(rightValue[key]));
}

function snapshotProjection(snapshot: RunSnapshot): string {
  return JSON.stringify({
    ...snapshot,
    lastSequence: snapshot.lastSequence?.toString(),
    occurrences: [...snapshot.occurrences].map(([id, occurrence]) => [id, { ...occurrence, attempts: [...occurrence.attempts] }]),
    eventDigests: [...snapshot.eventDigests],
    controlAcks: [...snapshot.controlAcks],
  });
}

async function ownerIsLive(storeDir: string): Promise<boolean> {
  try {
    const owner = record(JSON.parse(await readFile(join(storeDir, "owner.json"), "utf8")), "owner lease");
    if (owner.version !== 1 || typeof owner.pid !== "number" || !Number.isSafeInteger(owner.pid) || owner.pid <= 0 || typeof owner.heartbeat !== "string") return false;
    const heartbeat = Date.parse(owner.heartbeat);
    if (!Number.isFinite(heartbeat) || Date.now() - heartbeat > 10_000) return false;
    try { process.kill(owner.pid, 0); return true; }
    catch (error) { return (error as NodeJS.ErrnoException).code === "EPERM"; }
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return false;
    throw error;
  }
}

function parseLaunchManifest(value: unknown): LaunchManifest {
  const object = record(value, "supervisor manifest");
  const hashes = record(object.inputHashes, "inputHashes");
  if (!Object.values(hashes).every((entry) => typeof entry === "string")) throw new Error("inputHashes is invalid");
  const targetArgs = stringArray(object.targetArgs, "targetArgs");
  const targetKind = string(object.targetKind, "targetKind");
  if (!["scripted", "acp", "deck", "current", "child", "remote"].includes(targetKind)) throw new Error("targetKind is invalid");
  const lineage = object.lineage;
  if (lineage !== undefined && lineage !== "restart" && lineage !== "resume" && lineage !== "fork") throw new Error("lineage is invalid");
  const rawEdits = object.lineageEdits ?? [];
  if (!Array.isArray(rawEdits)) throw new Error("lineageEdits is invalid");
  const lineageEdits: NonNullable<LaunchManifest["lineageEdits"]> = rawEdits.map((entry) => {
    const edit = record(entry, "lineage edit");
    const type = string(edit.type, "lineage edit type");
    if (type !== "drop" && type !== "replace") throw new Error("lineage edit type is invalid");
    const occurrenceId = string(edit.occurrenceId, "lineage edit occurrenceId");
    if (!/^(0|[1-9][0-9]*)$/.test(occurrenceId)) throw new Error("lineage edit occurrenceId is invalid");
    const replacementHash = edit.replacementHash === undefined ? undefined : string(edit.replacementHash, "lineage edit replacementHash");
    if (type === "replace" && !replacementHash) throw new Error("replacement lineage edit has no hash");
    if (type === "drop" && replacementHash !== undefined) throw new Error("drop lineage edit has a replacement hash");
    return { type, occurrenceId, replacementHash };
  });
  if (new Set(lineageEdits.map((edit) => edit.occurrenceId)).size !== lineageEdits.length) throw new Error("lineage answer was edited more than once");
  const parentRunId = object.parentRunId === undefined ? undefined : string(object.parentRunId, "parentRunId");
  if ((parentRunId === undefined) !== (lineage === undefined)) throw new Error("parentRunId and lineage must appear together");
  if (lineage !== "fork" && lineageEdits.length > 0) throw new Error("only fork lineage may contain answer edits");
  return {
    runId: string(object.runId, "runId"), runnerId: string(object.runnerId, "runnerId"), workflow: string(object.workflow, "workflow"),
    cwd: string(object.cwd, "cwd"), targetKind: targetKind as LaunchManifest["targetKind"], targetArgs, inputHashes: hashes as Record<string, string>,
    programHash: string(object.programHash, "programHash"), createdAt: string(object.createdAt, "createdAt"),
    parentRunId, lineage, lineageEdits,
  };
}

function parseSnapshot(value: unknown, runId: string): RunSnapshot {
  const object = record(value, "run snapshot");
  if (object.runId !== runId) throw new Error("snapshot runId does not match its directory manifest");
  const statuses = ["starting", "running", "cancelling", "succeeded", "failed", "cancelled", "orphaned"] as const;
  if (!statuses.includes(object.status as never)) throw new Error("snapshot status is invalid");
  const occurrences = new Map<string, RunSnapshot["occurrences"] extends Map<string, infer T> ? T : never>();
  if (!Array.isArray(object.occurrences)) throw new Error("snapshot occurrences is invalid");
  for (const item of object.occurrences) {
    if (!Array.isArray(item) || item.length !== 2) throw new Error("snapshot occurrence entry is invalid");
    const id = string(item[0], "occurrence id");
    const occurrence = record(item[1], "occurrence");
    const attempts = new Map();
    if (!Array.isArray(occurrence.attempts)) throw new Error("snapshot attempts is invalid");
    for (const attemptItem of occurrence.attempts) {
      if (!Array.isArray(attemptItem) || attemptItem.length !== 2) throw new Error("snapshot attempt entry is invalid");
      attempts.set(string(attemptItem[0], "attempt id"), record(attemptItem[1], "attempt") as never);
    }
    occurrences.set(id, { ...occurrence, id, attempts } as never);
  }
  const eventDigests = new Map<string, string>();
  if (!Array.isArray(object.eventDigests)) throw new Error("snapshot eventDigests is invalid");
  for (const item of object.eventDigests) {
    if (!Array.isArray(item) || item.length !== 2) throw new Error("snapshot event digest is invalid");
    eventDigests.set(string(item[0], "event sequence"), string(item[1], "event digest"));
  }
  const controlAcks = new Map<string, ControlAckSnapshot>();
  const rawControlAcks = object.controlAcks ?? [];
  if (!Array.isArray(rawControlAcks)) throw new Error("snapshot controlAcks is invalid");
  for (const item of rawControlAcks) {
    if (!Array.isArray(item) || item.length !== 2) throw new Error("snapshot control acknowledgement is invalid");
    const value = record(item[1], "control acknowledgement");
    const controlId = string(item[0], "control id");
    controlAcks.set(controlId, { controlId, state: string(value.state, "control state"), message: string(value.message, "control message") });
  }
  const sequence = object.lastSequence;
  if (sequence !== undefined && (typeof sequence !== "string" || !/^(0|[1-9][0-9]*)$/.test(sequence))) throw new Error("snapshot sequence is invalid");
  const authoredOrder = stringArray(object.authoredOrder, "authoredOrder");
  const traceRecorded = object.traceRecorded === undefined ? authoredOrder.length > 0 : object.traceRecorded;
  if (typeof traceRecorded !== "boolean") throw new Error("snapshot traceRecorded is invalid");
  return { ...object, runId, status: object.status as RunSnapshot["status"], lastSequence: sequence === undefined ? undefined : BigInt(sequence), occurrences, authoredOrder, traceRecorded, eventDigests, controlAcks } as RunSnapshot;
}

function utf8Prefix(bytes: Buffer, maximum: number): Buffer {
  const text = bytes.subarray(0, maximum).toString("utf8").replace(/�$/, "");
  return Buffer.from(text);
}

function record(value: unknown, label: string): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) throw new Error(`${label} is not an object`);
  return value as Record<string, unknown>;
}
function string(value: unknown, label: string): string { if (typeof value !== "string") throw new Error(`${label} is not text`); return value; }
function stringArray(value: unknown, label: string): string[] { if (!Array.isArray(value) || !value.every((entry) => typeof entry === "string")) throw new Error(`${label} is not text[]`); return [...value]; }

function isPrunable(record: { manifest: LaunchManifest; snapshot: RunSnapshot }, protectedParents: Set<string>): boolean {
  return record.snapshot.status !== "orphaned" && isTerminal(record.snapshot.status) && !protectedParents.has(record.manifest.runId);
}

function isTerminal(status: RunSnapshot["status"]): boolean {
  return status === "succeeded" || status === "failed" || status === "cancelled" || status === "orphaned";
}

function delay(milliseconds: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function assertJournalPrefix(left: RunSnapshot, right: RunSnapshot): void {
  const shorter = (left.lastSequence ?? -1n) <= (right.lastSequence ?? -1n) ? left : right;
  const longer = shorter === left ? right : left;
  for (const [sequence, digest] of shorter.eventDigests) {
    if (longer.eventDigests.get(sequence) !== digest) throw new Error(`stored protocol journals disagree at sequence ${sequence}`);
  }
}

function waitForExit(child: ChildProcessWithoutNullStreams, timeoutMs: number): Promise<boolean> {
  if (child.exitCode !== null || child.signalCode !== null) return Promise.resolve(true);
  return new Promise((resolve) => {
    const timeout = setTimeout(() => resolve(false), timeoutMs);
    child.once("close", () => {
      clearTimeout(timeout);
      resolve(true);
    });
  });
}
