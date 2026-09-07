import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { appendFile, cp, mkdir, mkdtemp, readFile, readdir, rename, rm, stat, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { promisify } from "node:util";
import { afterEach, describe, expect, it } from "vitest";
import { discoverRunner } from "../src/catalogue.ts";
import { prepareLaunch } from "../src/launch.ts";
import { parseLaunchManifest, RunSupervisor, type OwnedRun } from "../src/supervisor.ts";
import type { RunnerConfig, RunSnapshot } from "../src/types.ts";

const created: string[] = [];
const execFileAsync = promisify(execFile);
afterEach(async () => Promise.all(created.splice(0).map((path) => rm(path, { recursive: true, force: true }))));

async function installResult(runtimeDir: string, runId: string, code: unknown, value: unknown, preview = "done") {
  const bytes = Buffer.from(`${JSON.stringify({ artifactVersion: 1, result: { code, value }, runId })}\n`);
  await writeFile(join(runtimeDir, "result.json"), bytes, { mode: 0o600 });
  return {
    artifactVersion: 1, path: "result.json", sha256: createHash("sha256").update(bytes).digest("hex"),
    bytes: String(bytes.length), code, preview,
  };
}

function withResult(journal: string, result: Awaited<ReturnType<typeof installResult>>): string {
  return journal.split("\n").filter(Boolean).map((line) => {
    const envelope = JSON.parse(line) as { event: { type: string; result?: unknown } };
    if (envelope.event.type === "run.completed") envelope.event.result = result;
    return JSON.stringify(envelope);
  }).join("\n") + "\n";
}

async function prepared(hang = false, legacy = false) {
  const directory = await mkdtemp(join(tmpdir(), "agent-cat-supervisor-"));
  created.push(directory);
  const runner: RunnerConfig = {
    id: "fixture", executable: resolve("test/fixtures/runner.mjs"),
    allowedCwds: [directory], ...(legacy ? { prefixArgs: ["--descriptor-v1"] } : {}),
  };
  const [descriptor] = await discoverRunner(runner, directory);
  const launch = await prepareLaunch({ runner, descriptor, cwd: directory, stateDir: join(directory, "state"), inputs: { subject: "x" }, targetKind: "scripted", targetArgs: ["--scripted"] });
  if (hang) launch.env.FIXTURE_HANG = "1";
  return launch;
}

function terminal(run: OwnedRun): Promise<RunSnapshot> {
  return run.finished;
}

describe("run supervisor", () => {
  it("normalizes shared legacy and version-2 frontend manifests", async () => {
    const fixture = async (name: string): Promise<unknown> =>
      JSON.parse(await readFile(resolve("../test/fixtures/runtime/frontend-manifest", name), "utf8")) as unknown;
    const legacy = parseLaunchManifest(await fixture("legacy-ext-pi.json"));
    expect(legacy).toMatchObject({ runId: "run-legacy", runnerId: "fixture", targetKind: "scripted" });
    expect(legacy).not.toHaveProperty("frontendManifestVersion");
    expect(parseLaunchManifest(await fixture("v2.json"))).toMatchObject({
      frontendManifestVersion: 2, runId: "run-v2", runnerId: "fixture", runnerExecutable: "/bin/agentic-run",
      personAnswering: "engine", ownerId: "tui:owner", runtimeStore: "runtime",
    });
    const unknown = { ...(await fixture("v2.json") as Record<string, unknown>), future: true };
    expect(() => parseLaunchManifest(unknown)).toThrow("unknown field");
  });
  it("restores a Haskell-style version-2 manifest and shared protocol-v2 journal read-only", async () => {
    const directory = await mkdtemp(join(tmpdir(), "agent-cat-shared-frontend-"));
    created.push(directory);
    const stateDir = join(directory, "state");
    const runDir = join(stateDir, "runs", "run-1");
    await mkdir(join(runDir, "runtime"), { recursive: true, mode: 0o700 });
    const manifest = JSON.parse(await readFile(resolve("../test/fixtures/runtime/frontend-manifest/v2.json"), "utf8"));
    manifest.runId = "run-1";
    await writeFile(join(runDir, "supervisor-manifest.json"), `${JSON.stringify(manifest)}\n`, { mode: 0o600 });
    const personResult = await installResult(join(runDir, "runtime"), "run-1", "receipt", { ok: true });
    const personEvents = withResult(await readFile(resolve("../test/fixtures/runtime/protocol-v2/person-result.ndjson"), "utf8"), personResult);
    await writeFile(join(runDir, "runtime", "events.ndjson"), personEvents, { mode: 0o600 });
    const progressDir = join(stateDir, "runs", "run-progress");
    await mkdir(join(progressDir, "runtime"), { recursive: true, mode: 0o700 });
    await writeFile(join(progressDir, "supervisor-manifest.json"), `${JSON.stringify({ ...manifest, runId: "run-progress" })}\n`, { mode: 0o600 });
    const progressResult = await installResult(join(progressDir, "runtime"), "run-progress", "receipt", { ok: true });
    const progressEvents = withResult(
      (await readFile(resolve("../test/fixtures/runtime/protocol-v2/progress.ndjson"), "utf8")).replaceAll('"run-1"', '"run-progress"'),
      progressResult,
    );
    await writeFile(join(progressDir, "runtime", "events.ndjson"), progressEvents, { mode: 0o600 });
    const supervisor = new RunSupervisor();
    await supervisor.restore(stateDir);
    const restored = supervisor.get("run-1");
    expect(restored?.snapshot).toMatchObject({ status: "succeeded", protocolVersion: 2, personAnswering: "local-control" });
    expect(restored?.snapshot.result).toMatchObject({ path: "result.json", preview: "done" });
    await expect(restored?.cancel()).rejects.toThrow("no live control channel");
    const progress = supervisor.get("run-progress")?.snapshot.occurrences.get("0")?.attempts.get("0:0");
    expect(progress).toMatchObject({
      output: "answer", messages: ["Working"], usage: { used: "42", size: "100" },
      reasoningSummaries: ["Checked the public constraints."],
    });
    expect(progress?.tools.get("tool-1")).toMatchObject({ status: "completed", title: "Write parse.c" });
  });
  it("streams a valid cross-language journal beyond the former 64 MiB frontend limit", async () => {
    const directory = await mkdtemp(join(tmpdir(), "agent-cat-large-journal-"));
    created.push(directory);
    const stateDir = join(directory, "state");
    const runId = "run-large";
    const runDir = join(stateDir, "runs", runId);
    const runtimeDir = join(runDir, "runtime");
    await mkdir(runtimeDir, { recursive: true, mode: 0o700 });
    const manifest = JSON.parse(await readFile(resolve("../test/fixtures/runtime/frontend-manifest/v2.json"), "utf8"));
    manifest.runId = runId;
    await writeFile(join(runDir, "supervisor-manifest.json"), `${JSON.stringify(manifest)}\n`, { mode: 0o600 });
    let sequence = 0;
    const envelope = (event: Record<string, unknown>): string => JSON.stringify({
      protocolVersion: 2, runId, sequence: String(sequence++), timestamp: "2026-09-04T00:00:00Z", event,
    }) + "\n";
    const journal = join(runtimeDir, "events.ndjson");
    await writeFile(journal, envelope({ type: "run.started", workflow: "review", target: "scripted", personAnswering: "engine" }));
    await appendFile(journal, envelope({ type: "occurrence.started", occurrenceId: "0", code: "text", intent: "consult", addressee: "model reviewer", prompt: "prompt" }));
    await appendFile(journal, envelope({ type: "attempt.started", occurrenceId: "0", attempt: "0", target: "scripted" }));
    const chunk = "x".repeat(900_000);
    for (let index = 0; index < 76; index += 1) {
      await appendFile(journal, envelope({ type: "attempt.output", occurrenceId: "0", attempt: "0", stream: "transport-text", chunk }));
    }
    await appendFile(journal, envelope({ type: "attempt.completed", occurrenceId: "0", attempt: "0", source: "scripted" }));
    await appendFile(journal, envelope({ type: "occurrence.completed", occurrenceId: "0", source: "asked:model reviewer", answer: "done" }));
    await appendFile(journal, envelope({ type: "trace.ordered", occurrenceIds: ["0"] }));
    const result = await installResult(runtimeDir, runId, "text", "done");
    await appendFile(journal, envelope({ type: "run.completed", billFresh: "1", billMemo: "1", result }));
    expect((await stat(journal)).size).toBeGreaterThan(64 * 1024 * 1024);
    const supervisor = new RunSupervisor();
    await supervisor.restore(stateDir);
    const snapshot = supervisor.get(runId)?.snapshot;
    expect(snapshot?.status, snapshot?.failure).toBe("succeeded");
    expect(Buffer.byteLength(snapshot?.occurrences.get("0")?.attempts.get("0:0")?.output ?? "")).toBeLessThanOrEqual(64 * 1024);
  }, 30_000);
  it("restores dual journals with more than 65,536 protocol events", async () => {
    const directory = await mkdtemp(join(tmpdir(), "agent-cat-many-events-"));
    created.push(directory);
    const stateDir = join(directory, "state");
    const runId = "run-many-events";
    const runDir = join(stateDir, "runs", runId);
    const runtimeDir = join(runDir, "runtime");
    await mkdir(runtimeDir, { recursive: true, mode: 0o700 });
    const manifest = JSON.parse(await readFile(resolve("../test/fixtures/runtime/frontend-manifest/v2.json"), "utf8"));
    manifest.runId = runId;
    await writeFile(join(runDir, "supervisor-manifest.json"), `${JSON.stringify(manifest)}\n`, { mode: 0o600 });
    let sequence = 0;
    const envelope = (event: Record<string, unknown>): string => JSON.stringify({
      protocolVersion: 2, runId, sequence: String(sequence++), timestamp: "2026-09-04T00:00:00Z", event,
    }) + "\n";
    const lines = [
      envelope({ type: "run.started", workflow: "review", target: "scripted", personAnswering: "engine" }),
      envelope({ type: "occurrence.started", occurrenceId: "0", code: "text", intent: "consult", addressee: "model reviewer", prompt: "prompt" }),
      envelope({ type: "attempt.started", occurrenceId: "0", attempt: "0", target: "scripted" }),
    ];
    for (let index = 0; index < 65_537; index += 1) {
      lines.push(envelope({ type: "attempt.progress", occurrenceId: "0", attempt: "0", progress: { kind: "message", text: `step ${index}` } }));
    }
    lines.push(envelope({ type: "attempt.completed", occurrenceId: "0", attempt: "0", source: "scripted" }));
    lines.push(envelope({ type: "occurrence.completed", occurrenceId: "0", source: "asked:model reviewer", answer: "done" }));
    lines.push(envelope({ type: "trace.ordered", occurrenceIds: ["0"] }));
    const result = await installResult(runtimeDir, runId, "text", "done");
    lines.push(envelope({ type: "run.completed", billFresh: "1", billMemo: "1", result }));
    const journal = lines.join("");
    await writeFile(join(runtimeDir, "events.ndjson"), journal, { mode: 0o600 });
    await writeFile(join(runDir, "live-events.ndjson"), journal, { mode: 0o600 });
    const supervisor = new RunSupervisor();
    await supervisor.restore(stateDir);
    const snapshot = supervisor.get(runId)?.snapshot;
    expect(snapshot?.status, snapshot?.failure).toBe("succeeded");
    expect(snapshot?.lastSequence).toBe(65_543n);
    expect(snapshot?.eventDigests.size).toBe(1);
  }, 60_000);

  it("isolates mismatched and oversized frontend manifests without hiding healthy siblings", async () => {
    const directory = await mkdtemp(join(tmpdir(), "agent-cat-manifest-bounds-"));
    created.push(directory);
    const stateDir = join(directory, "state");
    const runsDir = join(stateDir, "runs");
    const mismatched = join(runsDir, "directory-id");
    const oversized = join(runsDir, "oversized-id");
    await mkdir(mismatched, { recursive: true });
    await mkdir(oversized, { recursive: true });
    const manifest = await readFile(resolve("../test/fixtures/runtime/frontend-manifest/v2.json"), "utf8");
    await writeFile(join(mismatched, "supervisor-manifest.json"), manifest);
    await writeFile(join(oversized, "supervisor-manifest.json"), "x".repeat(4 * 1024 * 1024 + 1));
    const supervisor = new RunSupervisor();
    await supervisor.restore(stateDir);
    expect(supervisor.get("directory-id")?.snapshot).toMatchObject({ status: "failed", failureClass: "corrupt-store", failure: expect.stringContaining("does not match") });
    expect(supervisor.get("oversized-id")?.snapshot).toMatchObject({ status: "failed", failureClass: "corrupt-store", failure: expect.stringContaining("exceeds") });
  });
  it("treats malformed owner leases as absent rather than corrupting a terminal store", async () => {
    const launch = await prepared();
    await new RunSupervisor().start(launch).finished;
    await writeFile(join(launch.storeDir, "owner.json"), "{not-json\n", "utf8");
    const restored = new RunSupervisor();
    await restored.restore(dirname(dirname(launch.storeDir)));
    expect(restored.get(launch.manifest.runId)?.snapshot.status).toBe("succeeded");
  });
  it("owns a successful run beyond launch", async () => {
    const supervisor = new RunSupervisor();
    const run = supervisor.start(await prepared());
    const result = await terminal(run);
    expect(result.status).toBe("succeeded");
    expect(result.protocolVersion).toBe(2);
    expect(result.result).toMatchObject({ path: "result.json", code: "receipt", preview: "done" });
    expect(result.billFresh).toBe("1");
    expect(result.occurrences.get("0")?.state).toBe("completed");
  });

  it("refuses a terminal run whose private result artifact fails digest verification", async () => {
    const launch = await prepared();
    await new RunSupervisor().start(launch).finished;
    const path = join(launch.storeDir, "runtime", "result.json");
    const bytes = await readFile(path);
    bytes[0] ^= 1;
    await writeFile(path, bytes);
    const restored = new RunSupervisor();
    await restored.restore(dirname(dirname(launch.storeDir)));
    expect(restored.get(launch.manifest.runId)?.snapshot).toMatchObject({
      status: "failed", failureClass: "corrupt-store", failure: expect.stringContaining("digest"),
    });
  });

  it("accepts a canonical private result whose JSON integer exceeds Number.MAX_SAFE_INTEGER", async () => {
    const launch = await prepared();
    launch.env.FIXTURE_LARGE_INTEGER_RESULT = "1";
    const result = await new RunSupervisor().start(launch).finished;
    expect(result.status, result.failure).toBe("succeeded");
  });

  it.each(["version", "run-id", "code"])("refuses non-canonical %s result metadata", async (variant) => {
    const launch = await prepared();
    launch.env.FIXTURE_NONCANONICAL_RESULT = variant;
    const result = await new RunSupervisor().start(launch).finished;
    expect(result).toMatchObject({ status: "failed", failure: expect.stringContaining("canonical") });
  });

  it("refuses result restoration through a symlinked runtime ancestor", async () => {
    const launch = await prepared();
    await new RunSupervisor().start(launch).finished;
    const runtime = join(launch.storeDir, "runtime");
    const outside = join(dirname(dirname(launch.storeDir)), "escaped-runtime");
    await rename(runtime, outside);
    await symlink(outside, runtime, "dir");
    const restored = new RunSupervisor();
    await restored.restore(dirname(dirname(launch.storeDir)));
    expect(restored.get(launch.manifest.runId)?.snapshot).toMatchObject({
      status: "failed", failureClass: "corrupt-store", failure: expect.stringContaining("symbolic link"),
    });
  });

  it("refuses invalid UTF-8 in an otherwise bounded protocol journal", async () => {
    const launch = await prepared();
    await new RunSupervisor().start(launch).finished;
    const path = join(launch.storeDir, "live-events.ndjson");
    const bytes = await readFile(path);
    const offset = bytes.indexOf(Buffer.from("fixture"));
    expect(offset).toBeGreaterThanOrEqual(0);
    bytes[offset] = 0xff;
    await writeFile(path, bytes);
    const restored = new RunSupervisor();
    await restored.restore(dirname(dirname(launch.storeDir)));
    expect(restored.get(launch.manifest.runId)?.snapshot).toMatchObject({ status: "failed", failureClass: "corrupt-store" });
  });

  it("retains descriptor-v1 control compatibility on stdin", async () => {
    const launch = await prepared(true, true);
    expect(launch).toMatchObject({ controlFd: undefined, protocolVersion: 1 });
    expect(launch.env.AGENT_CAT_CONTROL_STDIN).toBe("1");
    const run = new RunSupervisor().start(launch);
    await until(() => run.snapshot.status === "running");
    await run.cancel();
    expect((await run.finished).status).toBe("cancelled");
  });

  it("redacts configured secrets and bounds durable stderr", async () => {
    const launch = await prepared();
    launch.env.FIXTURE_SECRET = "super-secret-value";
    launch.env.FIXTURE_STDERR_BYTES = String(10 * 1024 * 1024 + 4096);
    await new RunSupervisor().start(launch).finished;
    const path = join(launch.storeDir, "stderr.log");
    const log = await readFile(path, "utf8");
    expect((await stat(path)).size).toBeLessThanOrEqual(10 * 1024 * 1024);
    expect(log).not.toContain("super-secret-value");
    expect(log).toContain("[REDACTED]");
    expect(log).toContain("[REDACTED OVERLONG DIAGNOSTIC]");
  });

  it("reattaches read-only to a live owner and follows it to terminal state", async () => {
    const launch = await prepared(true);
    const owner = new RunSupervisor();
    const owned = owner.start(launch);
    await until(() => owned.snapshot.status === "running");
    await untilAsync(async () => {
      try {
        await Promise.all([stat(join(launch.storeDir, "owner.json")), stat(join(launch.storeDir, "live-events.ndjson"))]);
        return true;
      } catch { return false; }
    });
    const observer = new RunSupervisor();
    await observer.restore(dirname(dirname(launch.storeDir)));
    const attached = observer.get(launch.manifest.runId);
    expect(attached?.snapshot.status).toBe("running");
    await expect(attached?.cancel()).rejects.toThrow("another live supervisor");
    const terminal = attached!.finished;
    await owned.cancel();
    const observed = await terminal;
    expect(observed.status, `${observed.failureClass}: ${observed.failure}`).toBe("cancelled");
    await observer.shutdown();
  }, 10_000);

  it("steers only a correlated active attempt and records non-replayable provenance", async () => {
    const supervisor = new RunSupervisor();
    const run = supervisor.start(await prepared(true));
    await until(() => run.snapshot.occurrences.get("0")?.attempts.has("0:0") === true);
    expect(() => run.steer("0", "0:9", "stale", "interrupt-now")).toThrow("not active");
    const ack = await run.steer("0", "0:0", "focus", "next-boundary");
    expect(ack.state).toBe("delivered");
    const controlId = ack.controlId;
    await until(() => run.snapshot.occurrences.get("0")?.attempts.get("0:0")?.steers.length === 1);
    expect(run.snapshot.occurrences.get("0")?.attempts.get("0:0")?.steers[0]).toEqual({ controlId, timing: "next-boundary", text: "focus" });
    expect(run.snapshot.occurrences.get("0")?.replayable).toBe(false);
    await run.cancel();
  });

  it("surfaces unsupported control acknowledgements instead of echoing success", async () => {
    const launch = await prepared(true);
    launch.env.FIXTURE_CONTROL_STATE = "unsupported";
    const run = new RunSupervisor().start(launch);
    await until(() => run.snapshot.occurrences.get("0")?.attempts.has("0:0") === true);
    const ack = await run.steer("0", "0:0", "focus", "interrupt-now");
    expect(ack).toMatchObject({ state: "unsupported", message: "target rejected control" });
    expect(run.snapshot.controlAcks.get(ack.controlId)).toEqual(ack);
    await run.cancel();
  });
  it("rejects a terminal protocol-v2 acknowledgement with mismatched control correlation", async () => {
    const launch = await prepared(true);
    launch.env.FIXTURE_BAD_CONTROL_CORRELATION = "1";
    const run = new RunSupervisor().start(launch);
    await until(() => run.snapshot.occurrences.get("0")?.attempts.has("0:0") === true);
    await expect(run.steer("0", "0:0", "focus", "next-boundary")).rejects.toThrow("correlation mismatch");
    expect((await run.finished).status).toBe("failed");
  });

  it("migrates legacy snapshots and restores terminal runs read-only", async () => {
    const launch = await prepared();
    const first = new RunSupervisor();
    await first.start(launch).finished;
    const legacy = JSON.parse(await readFile(join(launch.storeDir, "snapshot.json"), "utf8"));
    delete legacy.controlAcks;
    await writeFile(join(launch.storeDir, "snapshot.json"), `${JSON.stringify(legacy)}\n`, "utf8");
    const storedManifest = JSON.parse(await readFile(join(launch.storeDir, "supervisor-manifest.json"), "utf8"));
    storedManifest.parentRunId = "parent-run";
    storedManifest.lineage = "fork";
    storedManifest.lineageEdits = [{ type: "drop", occurrenceId: "0" }];
    await writeFile(join(launch.storeDir, "supervisor-manifest.json"), `${JSON.stringify(storedManifest)}\n`, "utf8");
    const restored = new RunSupervisor();
    await restored.restore(dirname(dirname(launch.storeDir)));
    const run = restored.get(launch.manifest.runId);
    expect(run?.snapshot.status, run?.snapshot.failure).toBe("succeeded");
    expect(run?.manifest.programHash).toBe(launch.manifest.programHash);
    expect(run?.snapshot.controlAcks.size).toBe(0);
    expect(run?.manifest.lineageEdits).toEqual([{ type: "drop", occurrenceId: "0" }]);
    await expect(run?.cancel()).rejects.toThrow("no live control channel");
  });

  it("isolates an invalid durable manifest as a corrupt run", async () => {
    const launch = await prepared();
    await new RunSupervisor().start(launch).finished;
    const manifestPath = join(launch.storeDir, "supervisor-manifest.json");
    const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
    manifest.targetKind = "guessed-from-argv";
    await writeFile(manifestPath, `${JSON.stringify(manifest)}\n`, "utf8");
    const restored = new RunSupervisor();
    await restored.restore(dirname(dirname(launch.storeDir)));
    expect(restored.get(launch.manifest.runId)?.snapshot).toMatchObject({
      status: "failed", failureClass: "corrupt-store", failure: expect.stringContaining("targetKind is invalid"),
    });
  });

  it("ignores an incomplete pre-manifest directory without hiding valid runs", async () => {
    const launch = await prepared();
    await new RunSupervisor().start(launch).finished;
    const runRoot = dirname(launch.storeDir);
    const incomplete = join(runRoot, "incomplete", "inputs");
    await mkdir(incomplete, { recursive: true, mode: 0o700 });
    await writeFile(join(incomplete, "0.txt"), "private", { mode: 0o600 });
    const restored = new RunSupervisor();
    await restored.restore(dirname(runRoot));
    expect(restored.get(launch.manifest.runId)?.snapshot.status).toBe("succeeded");
    expect(restored.get("incomplete")).toBeUndefined();
  });

  it("classifies a torn stored event journal as corruption even when a snapshot exists", async () => {
    const launch = await prepared();
    await new RunSupervisor().start(launch).finished;
    await appendFile(join(launch.storeDir, "live-events.ndjson"), "{torn");
    const restored = new RunSupervisor();
    await restored.restore(dirname(dirname(launch.storeDir)));
    expect(restored.get(launch.manifest.runId)?.snapshot).toMatchObject({
      status: "failed",
      failureClass: "corrupt-store",
      failure: expect.stringContaining("torn final protocol record"),
    });
  });

  it("classifies a snapshot that disagrees with its terminal journal as corruption", async () => {
    const launch = await prepared();
    await new RunSupervisor().start(launch).finished;
    const snapshot = JSON.parse(await readFile(join(launch.storeDir, "snapshot.json"), "utf8"));
    snapshot.billFresh = "999";
    await writeFile(join(launch.storeDir, "snapshot.json"), `${JSON.stringify(snapshot)}\n`, "utf8");
    const restored = new RunSupervisor();
    await restored.restore(dirname(dirname(launch.storeDir)));
    expect(restored.get(launch.manifest.runId)?.snapshot).toMatchObject({
      status: "failed",
      failureClass: "corrupt-store",
      failure: expect.stringContaining("disagrees"),
    });
  });

  it.each([false, true])("rejects unequal terminal journals with %s prefix divergence", async (diverge) => {
    const launch = await prepared();
    await new RunSupervisor().start(launch).finished;
    const lines = (await readFile(join(launch.storeDir, "live-events.ndjson"), "utf8")).trimEnd().split("\n");
    const first = JSON.parse(lines[0]);
    if (diverge) first.event.target = "tampered";
    const runtimeDir = join(launch.storeDir, "runtime");
    await mkdir(runtimeDir, { recursive: true });
    await writeFile(join(runtimeDir, "events.ndjson"), `${JSON.stringify(first)}\n`, "utf8");
    const restored = new RunSupervisor();
    await restored.restore(dirname(dirname(launch.storeDir)));
    expect(restored.get(launch.manifest.runId)?.snapshot).toMatchObject({
      status: "failed",
      failureClass: "corrupt-store",
      failure: expect.stringContaining("stored protocol journals disagree"),
    });
  });

  it("applies configurable retention only to terminal unreferenced runs", async () => {
    const launch = await prepared();
    await new RunSupervisor().start(launch).finished;
    const runRoot = dirname(launch.storeDir);
    const newerId = "newer-run";
    const newer = join(runRoot, newerId);
    await cp(launch.storeDir, newer, { recursive: true });
    const manifest = JSON.parse(await readFile(join(newer, "supervisor-manifest.json"), "utf8"));
    manifest.runId = newerId;
    manifest.createdAt = new Date(Date.parse(manifest.createdAt) + 1_000).toISOString();
    await writeFile(join(newer, "supervisor-manifest.json"), `${JSON.stringify(manifest)}\n`, "utf8");
    const snapshot = JSON.parse(await readFile(join(newer, "snapshot.json"), "utf8"));
    snapshot.runId = newerId;
    await writeFile(join(newer, "snapshot.json"), `${JSON.stringify(snapshot)}\n`, "utf8");
    const replacementResult = await installResult(join(newer, "runtime"), newerId, "receipt", "done");
    const eventsPath = join(newer, "live-events.ndjson");
    const events = (await readFile(eventsPath, "utf8")).trimEnd().split("\n").map((line) => {
      const event = { ...JSON.parse(line), runId: newerId };
      if (event.event.type === "run.completed") event.event.result = replacementResult;
      return event;
    });
    snapshot.result = replacementResult;
    await writeFile(eventsPath, `${events.map((event) => JSON.stringify(event)).join("\n")}\n`, "utf8");
    snapshot.eventDigests = events.map((event) => [event.sequence, JSON.stringify(event)]);
    await writeFile(join(newer, "snapshot.json"), `${JSON.stringify(snapshot)}\n`, "utf8");
    const restored = new RunSupervisor();
    await restored.restore(dirname(runRoot), { days: 0, maxRuns: 1 });
    expect((await readdir(runRoot)).sort()).toEqual([newerId]);
    const retained = restored.get(newerId)?.snapshot;
    expect(retained?.status, retained?.failure).toBe("succeeded");
  });

  it("forces an unresponsive process group and classifies cancellation honestly", async () => {
    const launch = await prepared();
    const marker = `agent-cat-tree-${process.pid}-${Date.now()}`;
    launch.command = resolve("test/fixtures/tree-runner.mjs");
    launch.env.FIXTURE_TREE_MARKER = marker;
    const run = new RunSupervisor().start(launch);
    await until(() => run.snapshot.status === "running");
    await run.cancel("forced cleanup test");
    expect(await run.finished).toMatchObject({ status: "cancelled", failureClass: "forced-termination" });
    const { stdout } = await execFileAsync("ps", ["-axo", "command="]);
    expect(stdout).not.toContain(marker);
  }, 12_000);

  it("uses the same process-group cleanup for fatal protocol failures", async () => {
    const launch = await prepared();
    const marker = `agent-cat-malformed-${process.pid}-${Date.now()}`;
    launch.command = resolve("test/fixtures/tree-runner.mjs");
    launch.env.FIXTURE_TREE_MARKER = marker;
    launch.env.FIXTURE_TREE_MALFORMED = "1";
    const result = await new RunSupervisor().start(launch).finished;
    expect(result).toMatchObject({ status: "failed", failureClass: "supervisor", failure: expect.stringContaining("protocol failure") });
    const { stdout } = await execFileAsync("ps", ["-axo", "command="]);
    expect(stdout).not.toContain(marker);
  }, 8_000);

  it("classifies a prepared but unowned run as orphaned", async () => {
    const launch = await prepared();
    const restored = new RunSupervisor();
    await restored.restore(dirname(dirname(launch.storeDir)));
    expect(restored.get(launch.manifest.runId)?.snapshot).toMatchObject({ status: "orphaned", failure: expect.stringContaining("ownership was lost") });
  });

  it("redirects only a dispatch-pending occurrence to a reserved target", async () => {
    const supervisor = new RunSupervisor();
    const launch = await prepared();
    launch.env.FIXTURE_REDIRECT = "1";
    const run = supervisor.start(launch);
    await until(() => run.snapshot.occurrences.get("0")?.dispatch?.open === true);
    expect(() => run.redirect("0", "model@unknown")).toThrow("not reserved");
    const ack = await run.redirect("0", "model@spare");
    expect(ack.state).toBe("delivered");
    const controlId = ack.controlId;
    const result = await run.finished;
    expect(result.status).toBe("succeeded");
    expect(result.occurrences.get("0")?.dispatch?.redirect).toEqual({ controlId, target: "model@spare" });
    expect(result.occurrences.get("0")?.attempts.get("0:0")?.target).toBe("model@spare");
  });

  it("rejects a recovery choice the runner did not offer", async () => {
    const launch = await prepared();
    launch.env.FIXTURE_RECOVER = "1";
    launch.env.FIXTURE_NO_FAILOVER = "1";
    const run = new RunSupervisor().start(launch);
    await until(() => run.snapshot.occurrences.get("0")?.state === "recovering");
    expect(() => run.recover("0", "failover")).toThrow("was not offered");
    await run.recover("0", "abandon");
    expect((await run.finished).status).toBe("failed");
  });

  it("retries only an occurrence waiting for interactive recovery", async () => {
    const supervisor = new RunSupervisor();
    const launch = await prepared();
    launch.env.FIXTURE_RECOVER = "1";
    const run = supervisor.start(launch);
    await until(() => run.snapshot.occurrences.get("0")?.state === "recovering");
    expect(() => run.retry("9")).toThrow("not waiting");
    const ack = await run.retry("0");
    expect(ack.state).toBe("delivered");
    const controlId = ack.controlId;
    const result = await run.finished;
    expect(result.status).toBe("succeeded");
    expect(result.occurrences.get("0")?.recovery?.retries).toEqual([controlId]);
  });

  it("chooses failover or abandon for a recoverable occurrence", async () => {
    for (const choice of ["failover", "abandon"] as const) {
      const launch = await prepared();
      launch.env.FIXTURE_RECOVER = "1";
      const run = new RunSupervisor().start(launch);
      await until(() => run.snapshot.occurrences.get("0")?.state === "recovering");
      const ack = await run.recover("0", choice);
      expect(ack.state).toBe("delivered");
      const result = await run.finished;
      expect(result.occurrences.get("0")?.recovery?.chosen).toEqual({ controlId: ack.controlId, choice, target: choice === "failover" ? "model@spare" : undefined });
      if (choice === "failover") {
        expect(result.status).toBe("succeeded");
        expect(result.occurrences.get("0")?.attempts.get("0:1")?.target).toBe("model@spare");
      } else expect(result.status).toBe("failed");
    }
  });

  it("cancels idempotently through the control protocol", async () => {
    const supervisor = new RunSupervisor();
    const run = supervisor.start(await prepared(true));
    const done = terminal(run);
    await run.cancel();
    await run.cancel();
    const result = await done;
    expect(result.status, `${result.failureClass}: ${result.failure}`).toBe("cancelled");
  });
});

async function until(predicate: () => boolean): Promise<void> {
  for (let count = 0; count < 200; count += 1) {
    if (predicate()) return;
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 10));
  }
  throw new Error("condition not reached");
}

  it("allows a verified lagging mirror after the live owner's runtime journal reaches terminal", async () => {
    const launch = await prepared();
    await new RunSupervisor().start(launch).finished;
    const livePath = join(launch.storeDir, "live-events.ndjson");
    const lines = (await readFile(livePath, "utf8")).trimEnd().split("\n");
    const runtimeDir = join(launch.storeDir, "runtime");
    await mkdir(runtimeDir, { recursive: true });
    await writeFile(join(runtimeDir, "events.ndjson"), `${lines.join("\n")}\n`, "utf8");
    await writeFile(livePath, `${lines[0]}\n`, "utf8");
    await writeFile(join(launch.storeDir, "owner.json"), `${JSON.stringify({ version: 1, ownerId: "live", pid: process.pid, heartbeat: new Date().toISOString() })}\n`, "utf8");
    const restored = new RunSupervisor();
    await restored.restore(dirname(dirname(launch.storeDir)));
    expect(restored.get(launch.manifest.runId)?.snapshot.status).toBe("succeeded");
  });

async function untilAsync(predicate: () => Promise<boolean>): Promise<void> {
  for (let count = 0; count < 300; count += 1) {
    if (await predicate()) return;
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 10));
  }
  throw new Error("condition not reached");
}
