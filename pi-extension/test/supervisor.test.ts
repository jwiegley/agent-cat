import { execFile } from "node:child_process";
import { appendFile, cp, mkdir, mkdtemp, readFile, readdir, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { promisify } from "node:util";
import { afterEach, describe, expect, it } from "vitest";
import { discoverRunner } from "../src/catalogue.ts";
import { prepareLaunch } from "../src/launch.ts";
import { RunSupervisor, type OwnedRun } from "../src/supervisor.ts";
import type { RunnerConfig, RunSnapshot } from "../src/types.ts";

const created: string[] = [];
const execFileAsync = promisify(execFile);
afterEach(async () => Promise.all(created.splice(0).map((path) => rm(path, { recursive: true, force: true }))));

async function prepared(hang = false) {
  const directory = await mkdtemp(join(tmpdir(), "agent-cat-supervisor-"));
  created.push(directory);
  const runner: RunnerConfig = { id: "fixture", executable: resolve("test/fixtures/runner.mjs"), allowedCwds: [directory] };
  const [descriptor] = await discoverRunner(runner, directory);
  const launch = await prepareLaunch({ runner, descriptor, cwd: directory, stateDir: join(directory, "state"), inputs: { subject: "x" }, targetKind: "scripted", targetArgs: ["--scripted"] });
  if (hang) launch.env.FIXTURE_HANG = "1";
  return launch;
}

function terminal(run: OwnedRun): Promise<RunSnapshot> {
  return run.finished;
}

describe("run supervisor", () => {
  it("owns a successful run beyond launch", async () => {
    const supervisor = new RunSupervisor();
    const run = supervisor.start(await prepared());
    const result = await terminal(run);
    expect(result.status).toBe("succeeded");
    expect(result.billFresh).toBe("1");
    expect(result.occurrences.get("0")?.state).toBe("completed");
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
    expect(log).toContain("stderr truncated");
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
    expect((await terminal).status).toBe("cancelled");
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

  it("refuses an unknown durable target kind", async () => {
    const launch = await prepared();
    await new RunSupervisor().start(launch).finished;
    const manifestPath = join(launch.storeDir, "supervisor-manifest.json");
    const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
    manifest.targetKind = "guessed-from-argv";
    await writeFile(manifestPath, `${JSON.stringify(manifest)}\n`, "utf8");
    await expect(new RunSupervisor().restore(dirname(dirname(launch.storeDir)))).rejects.toThrow("targetKind is invalid");
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
    const eventsPath = join(newer, "live-events.ndjson");
    const events = (await readFile(eventsPath, "utf8")).trimEnd().split("\n").map((line) => ({ ...JSON.parse(line), runId: newerId }));
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
