import { createHash, randomUUID } from "node:crypto";
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { constants as fsConstants, createReadStream } from "node:fs";
import { appendFile, lstat, mkdir, open, readdir, realpath, rename, rm, stat, writeFile } from "node:fs/promises";
import { isAbsolute, join, relative } from "node:path";
import { initialSnapshot, reduceEvent } from "./reducer.ts";
import type { PreparedLaunch } from "./launch.ts";
import type { Writable } from "node:stream";
import type { ControlAckSnapshot, LaunchManifest, RunSnapshot, RuntimeEvent } from "./types.ts";

const MAX_FRAME = 1024 * 1024;
const MAX_METADATA_FILE = 4 * 1024 * 1024;
const MAX_SNAPSHOT_FILE = 64 * 1024 * 1024;
const MAX_JOURNAL_FILE = 512 * 1024 * 1024;
const MAX_STDERR_LOG = 10 * 1024 * 1024;
const MAX_STDERR_LINE = 64 * 1024;
const STDERR_TRUNCATION_MARKER = Buffer.from("\n[agent-cat stderr truncated at 10485760 bytes]\n");

type Listener = (snapshot: RunSnapshot) => void;
type MachineChild = ChildProcessWithoutNullStreams & { control: Writable };
type ControlCorrelation = { command: string; occurrenceId?: string; attemptId?: string };
type RestoreRecord = { storeDir: string; manifest: LaunchManifest; snapshot: RunSnapshot; created: number; ownerLive: boolean };
type ReducedJournal = { path: string; bytes: number; digest: string; snapshot: RunSnapshot };

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
    const cutoff = policy.days === 0 ? Number.NEGATIVE_INFINITY : Date.now() - policy.days * 86_400_000;
    const records: RestoreRecord[] = [];
    for (const entry of entries.filter((item) => item.isDirectory())) {
      const storeDir = join(root, entry.name);
      let manifestText: string;
      try { manifestText = await readTextBounded(join(storeDir, "supervisor-manifest.json"), MAX_METADATA_FILE); }
      catch (error) {
        if ((error as NodeJS.ErrnoException).code === "ENOENT") {
          if (policy.days > 0) {
            try { if ((await stat(storeDir)).mtimeMs < cutoff) await rm(storeDir, { recursive: true, force: true }); } catch {}
          }
          continue;
        }
        records.push(await corruptRestoreRecord(storeDir, entry.name, `supervisor manifest cannot be read: ${error instanceof Error ? error.message : String(error)}`));
        continue;
      }
      let manifest: LaunchManifest;
      try {
        manifest = parseLaunchManifest(JSON.parse(manifestText));
        if (manifest.runId !== entry.name) throw new Error("frontend manifest run id does not match its directory");
      }
      catch (error) {
        records.push(await corruptRestoreRecord(storeDir, entry.name, `supervisor manifest is corrupt: ${error instanceof Error ? error.message : String(error)}`));
        continue;
      }
      const created = Date.parse(manifest.createdAt);
      let ownerLive = false;
      let snapshot: RunSnapshot;
      try {
        if (!Number.isFinite(created)) throw new Error(`run ${manifest.runId} has an invalid createdAt`);
        ownerLive = await ownerIsLive(storeDir);
        snapshot = await restoreSnapshot(storeDir, manifest.runId, ownerLive);
      } catch (error) {
        snapshot = {
          ...initialSnapshot(manifest.runId),
          status: "failed",
          failureClass: "corrupt-store",
          failure: error instanceof Error ? error.message : String(error),
        };
      }
      records.push({ storeDir, manifest, snapshot, created: Number.isFinite(created) ? created : await storeTimestamp(storeDir), ownerLive });
    }
    records.sort((left, right) => left.created - right.created);
    const protectedParents = new Set(records.flatMap(({ manifest }) => manifest.parentRunId ? [manifest.parentRunId] : []));
    const remove = new Set<string>();
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
  #child?: MachineChild;
  #buffer = "";
  #terminal = false;
  #forcedTermination = false;
  #cancelRequested = false;
  #stderrBytes = 0;
  #stderrPending = "";
  #stderrDropping = false;
  #stderrQueue: Promise<void> = Promise.resolve();
  #eventMirrorQueue: Promise<void> = Promise.resolve();
  #leaseQueue: Promise<void> = Promise.resolve();
  #leaseTimer?: NodeJS.Timeout;
  readonly #ownerId: string;
  #fatalCleanup?: Promise<void>;
  readonly #controlWaiters = new Map<string, { resolve: (ack: ControlAckSnapshot) => void; reject: (error: Error) => void; timeout: NodeJS.Timeout; expected: ControlCorrelation }>();
  readonly #secretValues: string[];

  constructor(prepared: PreparedLaunch, onTerminal: () => void) {
    this.#prepared = prepared;
    this.#onTerminal = onTerminal;
    this.#ownerId = prepared.manifest.ownerId ?? randomUUID();
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
    const spawned = spawn(this.#prepared.command, this.#prepared.args, {
      cwd: this.#prepared.manifest.cwd,
      env: this.#prepared.env,
      shell: false,
      stdio: this.#prepared.controlFd === 3 ? ["pipe", "pipe", "pipe", "pipe"] : ["pipe", "pipe", "pipe"],
      detached: process.platform !== "win32",
    }) as ChildProcessWithoutNullStreams;
    const control = (this.#prepared.controlFd === 3 ? spawned.stdio[3] : spawned.stdin) as Writable;
    const child = Object.assign(spawned, { control });
    this.#child = child;
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.control.on("error", (error: NodeJS.ErrnoException) => {
      if (!this.#cancelRequested && error.code !== "EPIPE" && error.code !== "ERR_STREAM_DESTROYED") this.#fail(`control pipe failed: ${error.message}`);
    });
    if (this.#prepared.controlFd === 3) {
      child.stdin.on("error", (error: NodeJS.ErrnoException) => {
        if (!this.#cancelRequested && error.code !== "EPIPE" && error.code !== "ERR_STREAM_DESTROYED") this.#fail(`workflow stdin failed: ${error.message}`);
      });
      if (this.#prepared.stdinFile) {
        const source = createReadStream(this.#prepared.stdinFile);
        source.on("error", (error) => { if (!this.#cancelRequested) this.#fail(`workflow stdin failed: ${error.message}`); });
        source.pipe(child.stdin);
      } else child.stdin.end();
    }
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
    if (!child || child.control.destroyed || !child.control.writable) throw new Error("run control channel is unavailable");
    child.control.write(`${JSON.stringify(control)}\n`);
  }

  #sendControlAwait(controlId: string, control: unknown): Promise<ControlAckSnapshot> {
    return new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        this.#controlWaiters.delete(controlId);
        reject(new Error(`control ${controlId} was not acknowledged`));
      }, 10_000);
      timeout.unref();
      try {
        const expected = controlCorrelation(control);
        this.#controlWaiters.set(controlId, { resolve, reject, timeout, expected });
        this.#sendControl(control);
      }
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
    if (waiter && this.#snapshot.protocolVersion === 2
      && (ack.command !== waiter.expected.command || ack.occurrenceId !== waiter.expected.occurrenceId || ack.attemptId !== waiter.expected.attemptId)) {
      clearTimeout(waiter.timeout);
      this.#controlWaiters.delete(controlId);
      const error = new Error(`control ${controlId} acknowledgement correlation mismatch`);
      waiter.reject(error);
      this.#fail(error.message);
      return;
    }
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
      this.#queueStderr("", true);
      await this.#stderrQueue;
      await this.#eventMirrorQueue;
      if (this.#snapshot.status === "succeeded" && this.#snapshot.result) {
        await verifyResultArtifact(this.#prepared.storeDir, this.#snapshot.runId, this.#snapshot.result);
      }
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

  #queueStderr(chunk: string, final = false): void {
    this.#stderrQueue = this.#stderrQueue.then(async () => {
      this.#stderrPending += chunk;
      const output: string[] = [];
      for (;;) {
        if (this.#stderrDropping) {
          const newline = this.#stderrPending.indexOf("\n");
          if (newline < 0) { this.#stderrPending = ""; break; }
          this.#stderrPending = this.#stderrPending.slice(newline + 1);
          this.#stderrDropping = false;
        }
        const newline = this.#stderrPending.indexOf("\n");
        if (newline < 0) {
          if (Buffer.byteLength(this.#stderrPending) > MAX_STDERR_LINE) {
            output.push("[REDACTED OVERLONG DIAGNOSTIC]\n");
            this.#stderrPending = "";
            this.#stderrDropping = true;
          }
          break;
        }
        const line = this.#stderrPending.slice(0, newline);
        this.#stderrPending = this.#stderrPending.slice(newline + 1);
        output.push(Buffer.byteLength(line) > MAX_STDERR_LINE ? "[REDACTED OVERLONG DIAGNOSTIC]\n" : `${this.#redactDiagnostic(line)}\n`);
      }
      if (final && !this.#stderrDropping && this.#stderrPending) {
        output.push(this.#redactDiagnostic(this.#stderrPending));
        this.#stderrPending = "";
      }
      if (output.length === 0 || this.#stderrBytes >= MAX_STDERR_LOG) return;
      const bytes = Buffer.from(output.join(""));
      const contentLimit = MAX_STDERR_LOG - STDERR_TRUNCATION_MARKER.length;
      const remaining = Math.max(0, contentLimit - this.#stderrBytes);
      const retained = bytes.length <= remaining
        ? bytes
        : Buffer.concat([utf8Prefix(bytes, remaining), STDERR_TRUNCATION_MARKER]);
      if (retained.length === 0) return;
      await appendFile(join(this.#prepared.storeDir, "stderr.log"), retained, { mode: 0o600 });
      this.#stderrBytes += retained.length;
    }).catch((error) => this.#fail(`stderr persistence failed: ${error instanceof Error ? error.message : String(error)}`));
  }

  #redactDiagnostic(line: string): string {
    let redacted = line
      .replace(/(authorization\s*:\s*bearer\s+)\S+/gi, "$1[REDACTED]")
      .replace(/((?:api[_-]?key|token|secret|password)\s*[:=]\s*)\S+/gi, "$1[REDACTED]");
    for (const secret of this.#secretValues) redacted = redacted.split(secret).join("[REDACTED]");
    return redacted;
  }

  #fail(message: string): void {
    if (this.#terminal) return;
    if (this.#snapshot.status !== "failed") {
      this.#snapshot = { ...this.#snapshot, status: "failed", failureClass: "supervisor", failure: message };
      this.#notify();
    }
    for (const [controlId, waiter] of this.#controlWaiters) {
      clearTimeout(waiter.timeout);
      waiter.reject(new Error(`${message} (control ${controlId})`));
    }
    this.#controlWaiters.clear();
    if (!this.#fatalCleanup) this.#fatalCleanup = this.#terminateFatalProcessGroup();
  }

  async #terminateFatalProcessGroup(): Promise<void> {
    const child = this.#child;
    if (!child || child.exitCode !== null || child.signalCode !== null) return;
    child.stdin.destroy();
    child.control.destroy();
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
      occurrences: [...this.#snapshot.occurrences].map(([id, value]) => [id, {
        ...value, attempts: [...value.attempts].map(([attemptId, attempt]) => [attemptId, { ...attempt, tools: [...attempt.tools] }]),
      }]),
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

async function reduceJournal(path: string, runId: string): Promise<ReducedJournal> {
  const handle = await open(path, fsConstants.O_RDONLY | fsConstants.O_NOFOLLOW);
  try {
    const information = await handle.stat();
    if (!information.isFile()) throw new Error(`${path} is not a regular file`);
    if (information.size > MAX_JOURNAL_FILE) throw new Error(`${path} exceeds ${MAX_JOURNAL_FILE} bytes`);
    const stream = handle.createReadStream({ autoClose: false });
    const decoder = new TextDecoder("utf-8", { fatal: true });
    let total = 0;
    let buffered = "";
    let snapshot = initialSnapshot(runId);
    const digest = createHash("sha256");
    for await (const chunk of stream) {
      if (!Buffer.isBuffer(chunk)) throw new Error("stored protocol journal produced a non-byte chunk");
      total += chunk.length;
      if (total > MAX_JOURNAL_FILE) { stream.destroy(); throw new Error(`${path} exceeds ${MAX_JOURNAL_FILE} bytes`); }
      digest.update(chunk);
      buffered += decoder.decode(chunk, { stream: true });
      for (;;) {
        const newline = buffered.indexOf("\n");
        if (newline < 0) break;
        const line = buffered.slice(0, newline);
        buffered = buffered.slice(newline + 1);
        if (!line) continue;
        if (Buffer.byteLength(line) > MAX_FRAME) throw new Error("stored protocol frame exceeded limit");
        snapshot = reduceEvent(snapshot, JSON.parse(line) as RuntimeEvent);
      }
      if (Buffer.byteLength(buffered) > MAX_FRAME) throw new Error("stored protocol frame exceeded limit");
    }
    buffered += decoder.decode();
    if (buffered) throw new Error(`${path} has a torn final protocol record`);
    return { path, bytes: total, digest: digest.digest("hex"), snapshot };
  } finally {
    await handle.close();
  }
}

async function restoreSnapshot(storeDir: string, runId: string, ownerLive = false): Promise<RunSnapshot> {
  const journals: ReducedJournal[] = [];
  let journalSnapshot: RunSnapshot | undefined;
  for (const components of [["runtime", "events.ndjson"], ["live-events.ndjson"]]) {
    try {
      const path = await confinedPath(storeDir, components);
      const reduced = await reduceJournal(path, runId);
      for (const prior of journals) {
        await assertJournalPrefix(prior, reduced);
        const exactRequired = !ownerLive;
        if (exactRequired && ((prior.snapshot.lastSequence ?? -1n) !== (reduced.snapshot.lastSequence ?? -1n) || snapshotDifference(prior.snapshot, reduced.snapshot).length > 0)) {
          throw new Error("stored protocol journals disagree in terminal length or state");
        }
      }
      journals.push(reduced);
      if (!journalSnapshot || (reduced.snapshot.lastSequence ?? -1n) > (journalSnapshot.lastSequence ?? -1n)) journalSnapshot = reduced.snapshot;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    }
  }
  let snapshot: RunSnapshot;
  try {
    snapshot = parseSnapshot(JSON.parse(await readTextBounded(join(storeDir, "snapshot.json"), MAX_SNAPSHOT_FILE)), runId);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    snapshot = journalSnapshot ?? initialSnapshot(runId);
  }
  if (journalSnapshot && isTerminal(journalSnapshot.status)) {
    if (isTerminal(snapshot.status) && snapshotDifference(snapshot, journalSnapshot).length > 0) {
      throw new Error(`stored snapshot disagrees with the terminal protocol journal (${snapshotDifference(snapshot, journalSnapshot).join(", ")})`);
    }
    await verifySnapshotResult(storeDir, runId, journalSnapshot);
    return journalSnapshot;
  }
  if (isTerminal(snapshot.status)) {
    const supervisorTerminal = (snapshot.status === "failed" || snapshot.status === "cancelled")
      && ["supervisor", "forced-termination", "missing-terminal-event"].includes(snapshot.failureClass ?? "");
    if (!supervisorTerminal) throw new Error("terminal snapshot has no matching terminal protocol event");
    await verifySnapshotResult(storeDir, runId, snapshot);
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
  const { eventDigests: _eventDigests, ...projected } = snapshot;
  return JSON.stringify({
    ...projected,
    lastSequence: snapshot.lastSequence?.toString(),
    occurrences: [...snapshot.occurrences].map(([id, occurrence]) => [id, {
      ...occurrence, attempts: [...occurrence.attempts].map(([attemptId, attempt]) => [attemptId, { ...attempt, tools: [...attempt.tools] }]),
    }]),
    controlAcks: [...snapshot.controlAcks],
  });
}

async function ownerIsLive(storeDir: string): Promise<boolean> {
  try {
    const owner = record(JSON.parse(await readTextBounded(join(storeDir, "owner.json"), MAX_METADATA_FILE)), "owner lease");
    onlyKeys(owner, ["version", "ownerId", "pid", "heartbeat"], "owner lease");
    if (owner.version !== 1 || typeof owner.ownerId !== "string" || !owner.ownerId || typeof owner.pid !== "number" || !Number.isSafeInteger(owner.pid) || owner.pid <= 0 || typeof owner.heartbeat !== "string") return false;
    const heartbeat = Date.parse(owner.heartbeat);
    if (!Number.isFinite(heartbeat) || Math.abs(Date.now() - heartbeat) > 10_000) return false;
    try { process.kill(owner.pid, 0); return true; }
    catch (error) { return (error as NodeJS.ErrnoException).code === "EPERM"; }
  } catch {
    return false;
  }
}

async function storeTimestamp(storeDir: string): Promise<number> {
  try {
    const created = (await stat(storeDir)).mtimeMs;
    return Number.isFinite(created) ? created : Date.now();
  } catch { return Date.now(); }
}

async function corruptRestoreRecord(storeDir: string, runId: string, failure: string): Promise<RestoreRecord> {
  const created = await storeTimestamp(storeDir);
  return {
    storeDir, created, ownerLive: false, manifest: corruptLaunchManifest(runId, storeDir, created),
    snapshot: { ...initialSnapshot(runId), status: "failed", failureClass: "corrupt-store", failure },
  };
}

function corruptLaunchManifest(runId: string, storeDir: string, created: number): LaunchManifest {
  return {
    runId, runnerId: "corrupt", workflow: "unknown", cwd: storeDir, targetKind: "scripted",
    targetArgs: [], inputHashes: {}, programHash: "", createdAt: new Date(created).toISOString(),
  };
}

export function parseLaunchManifest(value: unknown): LaunchManifest {
  const object = record(value, "supervisor manifest");
  const versioned = object.frontendManifestVersion !== undefined;
  if (versioned) {
    if (object.frontendManifestVersion !== 2) throw new Error("unsupported frontend manifest version");
    onlyKeys(object, [
      "frontendManifestVersion", "runId", "runnerId", "runnerExecutable", "runnerVersion", "workflow", "cwd",
      "targetKind", "targetArgs", "inputHashes", "programHash", "createdAt", "parentRunId", "lineage", "lineageEdits",
      "persona", "policyDigest", "personAnswering", "ownerId", "runtimeStore",
    ], "frontend manifest");
  }
  const hashes = record(object.inputHashes, "inputHashes");
  if (!Object.values(hashes).every((entry) => typeof entry === "string")) throw new Error("inputHashes is invalid");
  const targetArgs = stringArray(object.targetArgs, "targetArgs");
  const targetKind = string(object.targetKind, "targetKind");
  if (!["scripted", "acp", "deck", "current", "child", "remote"].includes(targetKind)) throw new Error("targetKind is invalid");
  const lineageValue = object.lineage === null ? undefined : object.lineage;
  const lineage = lineageValue === undefined ? undefined : string(lineageValue, "lineage");
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
    if (versioned && replacementHash !== undefined && !digest(replacementHash)) throw new Error("replacement lineage edit hash is invalid");
    return { type, occurrenceId, replacementHash };
  });
  if (new Set(lineageEdits.map((edit) => edit.occurrenceId)).size !== lineageEdits.length) throw new Error("lineage answer was edited more than once");
  const parentValue = object.parentRunId === null ? undefined : object.parentRunId;
  const parentRunId = parentValue === undefined ? undefined : string(parentValue, "parentRunId");
  if ((parentRunId === undefined) !== (lineage === undefined)) throw new Error("parentRunId and lineage must appear together");
  if (lineage !== "fork" && lineageEdits.length > 0) throw new Error("only fork lineage may contain answer edits");
  const base: LaunchManifest = {
    runId: string(object.runId, "runId"), runnerId: string(object.runnerId, "runnerId"), workflow: string(object.workflow, "workflow"),
    cwd: string(object.cwd, "cwd"), targetKind: targetKind as LaunchManifest["targetKind"], targetArgs, inputHashes: hashes as Record<string, string>,
    programHash: string(object.programHash, "programHash"), createdAt: string(object.createdAt, "createdAt"),
    parentRunId, lineage, lineageEdits,
  };
  if (!versioned) return base;
  if (!/^[A-Za-z0-9._-]{1,128}$/.test(base.runId)) throw new Error("runId is invalid");
  if (!isAbsolute(base.cwd)) throw new Error("frontend cwd is not absolute");
  if (!digest(base.programHash) || !Object.values(base.inputHashes).every(digest)) throw new Error("frontend digest is invalid");
  const runnerExecutable = string(object.runnerExecutable, "runnerExecutable");
  if (!isAbsolute(runnerExecutable)) throw new Error("runnerExecutable is not absolute");
  const personAnswering = string(object.personAnswering, "personAnswering");
  if (personAnswering !== "engine" && personAnswering !== "local-control") throw new Error("personAnswering is invalid");
  if (object.runtimeStore !== "runtime") throw new Error("runtimeStore is invalid");
  const persona = optionalText(object.persona, "persona");
  const policyDigest = optionalText(object.policyDigest, "policyDigest");
  if (policyDigest !== undefined && !digest(policyDigest)) throw new Error("policyDigest is invalid");
  return {
    ...base, frontendManifestVersion: 2, runnerExecutable, runnerVersion: string(object.runnerVersion, "runnerVersion"),
    persona, policyDigest, personAnswering, ownerId: string(object.ownerId, "ownerId"), runtimeStore: "runtime",
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
      const attemptId = string(attemptItem[0], "attempt id");
      const attempt = record(attemptItem[1], "attempt");
      const tools = new Map<string, unknown>();
      const rawTools = attempt.tools ?? [];
      if (!Array.isArray(rawTools)) throw new Error("snapshot public tools is invalid");
      for (const toolItem of rawTools) {
        if (!Array.isArray(toolItem) || toolItem.length !== 2) throw new Error("snapshot public tool entry is invalid");
        tools.set(string(toolItem[0], "public tool id"), record(toolItem[1], "public tool"));
      }
      const rawTodos = attempt.todos ?? [];
      if (!Array.isArray(rawTodos)) throw new Error("snapshot public todos is invalid");
      attempts.set(attemptId, {
        ...attempt,
        messages: stringArray(attempt.messages ?? [], "public messages"),
        tools,
        todos: rawTodos.map((todo) => record(todo, "public todo")),
        usage: attempt.usage === undefined ? undefined : record(attempt.usage, "public usage"),
        reasoningSummaries: stringArray(attempt.reasoningSummaries ?? [], "public reasoning summaries"),
      } as never);
    }
    occurrences.set(id, { ...occurrence, id, attempts } as never);
  }
  const eventDigests = new Map<string, string>();
  if (!Array.isArray(object.eventDigests)) throw new Error("snapshot eventDigests is invalid");
  for (const item of object.eventDigests) {
    if (!Array.isArray(item) || item.length !== 2) throw new Error("snapshot event digest is invalid");
    const storedDigest = string(item[1], "event digest");
    const normalizedDigest = /^[0-9a-f]{64}$/.test(storedDigest)
      ? storedDigest
      : createHash("sha256").update(storedDigest).digest("hex");
    eventDigests.set(string(item[0], "event sequence"), normalizedDigest);
  }
  const controlAcks = new Map<string, ControlAckSnapshot>();
  const rawControlAcks = object.controlAcks ?? [];
  if (!Array.isArray(rawControlAcks)) throw new Error("snapshot controlAcks is invalid");
  for (const item of rawControlAcks) {
    if (!Array.isArray(item) || item.length !== 2) throw new Error("snapshot control acknowledgement is invalid");
    const value = record(item[1], "control acknowledgement");
    const controlId = string(item[0], "control id");
    controlAcks.set(controlId, {
      controlId, state: string(value.state, "control state"), message: string(value.message, "control message"),
      ...(value.command === undefined ? {} : { command: string(value.command, "control command") }),
      ...(value.occurrenceId === undefined ? {} : { occurrenceId: string(value.occurrenceId, "control occurrenceId") }),
      ...(value.attemptId === undefined ? {} : { attemptId: string(value.attemptId, "control attemptId") }),
    });
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

async function confinedPath(root: string, components: string[]): Promise<string> {
  const rootPath = await realpath(root);
  let current = root;
  for (const [index, component] of components.entries()) {
    if (!component || component === "." || component === ".." || component.includes("/") || component.includes("\\")) throw new Error("confined path has an invalid component");
    current = join(current, component);
    const information = await lstat(current);
    if (information.isSymbolicLink()) throw new Error(`${current} is a symbolic link`);
    if (index < components.length - 1 && !information.isDirectory()) throw new Error(`${current} is not a directory`);
    if (index === components.length - 1 && !information.isFile()) throw new Error(`${current} is not a regular file`);
    const resolved = await realpath(current);
    const descent = relative(rootPath, resolved);
    if (descent === ".." || descent.startsWith(`..${process.platform === "win32" ? "\\" : "/"}`) || isAbsolute(descent)) throw new Error(`${current} escapes its run store`);
  }
  return current;
}

async function readBytesBounded(path: string, maximum: number): Promise<Buffer> {
  const handle = await open(path, fsConstants.O_RDONLY | fsConstants.O_NOFOLLOW);
  try {
    const information = await handle.stat();
    if (!information.isFile()) throw new Error(`${path} is not a regular file`);
    if (information.size > maximum) throw new Error(`${path} exceeds ${maximum} bytes`);
    const chunks: Buffer[] = [];
    let total = 0;
    const buffer = Buffer.allocUnsafe(64 * 1024);
    for (;;) {
      const { bytesRead } = await handle.read(buffer, 0, buffer.length, null);
      if (bytesRead === 0) break;
      total += bytesRead;
      if (total > maximum) throw new Error(`${path} exceeds ${maximum} bytes`);
      chunks.push(Buffer.from(buffer.subarray(0, bytesRead)));
    }
    return Buffer.concat(chunks, total);
  } finally {
    await handle.close();
  }
}

async function readTextBounded(path: string, maximum: number): Promise<string> {
  return (await readBytesBounded(path, maximum)).toString("utf8");
}

async function verifySnapshotResult(storeDir: string, runId: string, snapshot: RunSnapshot): Promise<void> {
  if (snapshot.status === "succeeded" && snapshot.result) await verifyResultArtifact(storeDir, runId, snapshot.result);
}

function jsonHasOuterWhitespace(value: string): boolean {
  let inString = false;
  let escaped = false;
  for (const character of value) {
    if (inString) {
      if (escaped) escaped = false;
      else if (character === "\\") escaped = true;
      else if (character === '"') inString = false;
    } else if (character === '"') inString = true;
    else if (/\s/u.test(character)) return true;
  }
  return false;
}

async function verifyResultArtifact(storeDir: string, runId: string, reference: NonNullable<RunSnapshot["result"]>): Promise<void> {
  const expectedBytes = BigInt(reference.bytes);
  const path = await confinedPath(storeDir, ["runtime", "result.json"]);
  const bytes = await readBytesBounded(path, MAX_SNAPSHOT_FILE);
  if (BigInt(bytes.length) !== expectedBytes) throw new Error("result artifact byte count does not match its event");
  if (createHash("sha256").update(bytes).digest("hex") !== reference.sha256) throw new Error("result artifact digest does not match its event");
  if (bytes.length === 0 || bytes[bytes.length - 1] !== 10 || bytes.subarray(0, -1).includes(10)) throw new Error("result artifact is not canonical compact JSON followed by one newline");
  const compact = new TextDecoder("utf-8", { fatal: true }).decode(bytes.subarray(0, -1));
  if (jsonHasOuterWhitespace(compact)) throw new Error("result artifact is not canonical compact JSON followed by one newline");
  const value = JSON.parse(compact) as unknown;
  const artifact = record(value, "result artifact");
  const entries = compactObjectEntries(compact);
  if (JSON.stringify(entries.map(([key]) => key)) !== JSON.stringify(["artifactVersion", "result", "runId"])) throw new Error("result artifact has non-canonical, unknown, or missing fields");
  if (entries[0][1] !== "1" || artifact.artifactVersion !== 1) throw new Error("unsupported or non-canonical result artifact version");
  if (entries[2][1] !== JSON.stringify(runId) || artifact.runId !== runId) throw new Error("result artifact run id does not canonically match its event");
  const result = record(artifact.result, "result artifact payload");
  const resultEntries = compactObjectEntries(entries[1][1]);
  if (JSON.stringify(resultEntries.map(([key]) => key)) !== JSON.stringify(["code", "value"])) throw new Error("result artifact payload has non-canonical, unknown, or missing fields");
  if (resultEntries[0][1] !== JSON.stringify(reference.code) || JSON.stringify(result.code) !== JSON.stringify(reference.code)) throw new Error("result artifact code does not canonically match its event");
}

function compactObjectEntries(value: string): Array<[string, string]> {
  if (!value.startsWith("{") || !value.endsWith("}")) throw new Error("canonical JSON object is malformed");
  const entries: Array<[string, string]> = [];
  let index = 1;
  if (value[index] === "}") return entries;
  while (index < value.length - 1) {
    if (value[index] !== '"') throw new Error("canonical JSON object key is malformed");
    const keyEnd = jsonStringEnd(value, index);
    const keyText = value.slice(index, keyEnd);
    const key = JSON.parse(keyText) as unknown;
    if (typeof key !== "string" || JSON.stringify(key) !== keyText || value[keyEnd] !== ":") throw new Error("canonical JSON object key is malformed");
    const valueStart = keyEnd + 1;
    const valueEnd = jsonValueEnd(value, valueStart);
    const raw = value.slice(valueStart, valueEnd);
    JSON.parse(raw);
    entries.push([key, raw]);
    if (value[valueEnd] === "}") {
      if (valueEnd !== value.length - 1) throw new Error("canonical JSON object has trailing data");
      return entries;
    }
    if (value[valueEnd] !== ",") throw new Error("canonical JSON object separator is malformed");
    index = valueEnd + 1;
  }
  throw new Error("canonical JSON object is unterminated");
}

function jsonStringEnd(value: string, start: number): number {
  let escaped = false;
  for (let index = start + 1; index < value.length; index += 1) {
    if (escaped) escaped = false;
    else if (value[index] === "\\") escaped = true;
    else if (value[index] === '"') return index + 1;
  }
  throw new Error("canonical JSON string is unterminated");
}

function jsonValueEnd(value: string, start: number): number {
  if (value[start] === '"') return jsonStringEnd(value, start);
  if (value[start] !== "{" && value[start] !== "[") {
    let index = start;
    while (index < value.length && value[index] !== "," && value[index] !== "}") index += 1;
    return index;
  }
  let depth = 0;
  for (let index = start; index < value.length; index += 1) {
    if (value[index] === '"') index = jsonStringEnd(value, index) - 1;
    else if (value[index] === "{" || value[index] === "[") depth += 1;
    else if (value[index] === "}" || value[index] === "]") {
      depth -= 1;
      if (depth === 0) return index + 1;
    }
  }
  throw new Error("canonical JSON value is unterminated");
}

function record(value: unknown, label: string): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) throw new Error(`${label} is not an object`);
  return value as Record<string, unknown>;
}
function controlCorrelation(value: unknown): ControlCorrelation {
  const control = record(value, "runtime control");
  const command = record(control.command, "runtime control command");
  const occurrenceId = control.expectedOccurrenceId === null || control.expectedOccurrenceId === undefined
    ? undefined : string(control.expectedOccurrenceId, "expectedOccurrenceId");
  let attemptId: string | undefined;
  if (control.expectedAttemptId !== null && control.expectedAttemptId !== undefined) {
    const attempt = record(control.expectedAttemptId, "expectedAttemptId");
    attemptId = `${string(attempt.occurrenceId, "attempt occurrenceId")}:${string(attempt.attemptNumber, "attempt number")}`;
  }
  return { command: string(command.type, "control command type"), occurrenceId, attemptId };
}

function string(value: unknown, label: string): string { if (typeof value !== "string") throw new Error(`${label} is not text`); return value; }
function optionalText(value: unknown, label: string): string | undefined { return value === undefined || value === null ? undefined : string(value, label); }
function digest(value: string): boolean { return /^[0-9a-f]{64}$/.test(value); }
function onlyKeys(value: Record<string, unknown>, allowed: readonly string[], label: string): void {
  const unknown = Object.keys(value).filter((key) => !allowed.includes(key));
  if (unknown.length) throw new Error(`${label} has unknown field(s): ${unknown.join(", ")}`);
}
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

async function assertJournalPrefix(left: ReducedJournal, right: ReducedJournal): Promise<void> {
  const leftSequence = left.snapshot.lastSequence ?? -1n;
  const rightSequence = right.snapshot.lastSequence ?? -1n;
  if (leftSequence === rightSequence) {
    if (left.bytes !== right.bytes || left.digest !== right.digest) throw new Error("stored protocol journals disagree at equal sequence");
    return;
  }
  const shorter = leftSequence < rightSequence ? left : right;
  const longer = shorter === left ? right : left;
  if (shorter.bytes > longer.bytes) throw new Error("stored protocol journals disagree in prefix length");
  const digest = createHash("sha256");
  if (shorter.bytes > 0) {
    const handle = await open(longer.path, fsConstants.O_RDONLY | fsConstants.O_NOFOLLOW);
    try {
      const information = await handle.stat();
      if (!information.isFile() || information.size < shorter.bytes) throw new Error("stored protocol journal changed during prefix validation");
      const stream = handle.createReadStream({ start: 0, end: shorter.bytes - 1, autoClose: false });
      for await (const chunk of stream) digest.update(chunk);
    } finally {
      await handle.close();
    }
  }
  if (digest.digest("hex") !== shorter.digest) throw new Error(`stored protocol journals disagree before sequence ${shorter.snapshot.lastSequence ?? 0n}`);
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
