import { access, chmod, copyFile, mkdir, mkdtemp, readFile, readdir, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { discoverRunner } from "../src/catalogue.ts";
import { prepareLaunch } from "../src/launch.ts";
import { RunSupervisor } from "../src/supervisor.ts";
import type { RunnerConfig } from "../src/types.ts";

const runnerPath = process.env.AGENT_CAT_E2E_RUNNER;
const created: string[] = [];
afterEach(async () => Promise.all(created.splice(0).map((path) => rm(path, { recursive: true, force: true }))));

describe.runIf(Boolean(runnerPath))("native agent-cat targets through the extension supervisor", () => {
  it("executes the real stub ACP target", async () => {
    const { directory, runner, descriptor } = await setup();
    const launch = await prepareLaunch({
      runner,
      descriptor,
      cwd: directory,
      stateDir: join(directory, "state"),
      inputs: {},
      targetKind: "acp",
      targetArgs: [
        "--engine", "acp", "--adapter", "/usr/bin/env",
        "--adapter-arg", "python3", "--adapter-arg", resolve("../test/stub_adapter.py"),
        "--timeout", "30000",
      ],
    });
    const result = await new RunSupervisor().start(launch).finished;
    expect(result, `${result.failureClass}: ${result.failure}`).toMatchObject({ status: "succeeded", billFresh: "7", billMemo: "7" });
    expect([...result.occurrences.values()].some((occurrence) => occurrence.attempts.size > 0)).toBe(true);
  }, 60_000);

  it("streams declared stdin separately from fd-3 controls", async () => {
    const { directory, runner, descriptor } = await setup("review-lite");
    const payload = "UNIQUE-A\nUNIQUE-B\n\n";
    const launch = await prepareLaunch({
      runner, descriptor, cwd: directory, stateDir: join(directory, "state"),
      inputs: { subject: payload }, targetKind: "scripted", targetArgs: ["--scripted"],
    });
    expect(launch).toMatchObject({ controlFd: 3, stdinFile: expect.any(String) });
    expect(launch.args.join(" ")).not.toContain("subject=");
    expect(launch.args.join(" ")).not.toContain("UNIQUE-A");
    const result = await new RunSupervisor().start(launch).finished;
    expect(result, `${result.failureClass}: ${result.failure}`).toMatchObject({ status: "succeeded", billFresh: "8", billMemo: "8" });
    let diagnostics = "";
    try { diagnostics = await readFile(join(launch.storeDir, "stderr.log"), "utf8"); }
    catch (error) { if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error; }
    expect(diagnostics).not.toContain("UNIQUE-A");
    const runtimeManifest = await readFile(join(launch.storeDir, "runtime", "manifest.json"), "utf8");
    const privateProgram = join(launch.storeDir, "runtime", "program.json");
    expect(runtimeManifest).not.toContain("UNIQUE-A");
    expect(runtimeManifest).toContain("program.json");
    expect(await readFile(privateProgram, "utf8")).toContain("UNIQUE-A");
    expect((await stat(privateProgram)).mode & 0o777).toBe(0o600);
    expect(await readdir(launch.storeDir)).not.toContain("inputs");
  }, 60_000);

  it("executes the real stub agent-deck target", async () => {
    const { directory, runner, descriptor } = await setup();
    const { deckState, deckBinary } = await setupDeck(directory);
    const launch = await prepareLaunch({
      runner,
      descriptor,
      cwd: directory,
      stateDir: join(directory, "state"),
      inputs: {},
      targetKind: "deck",
      targetArgs: ["--session", "stub", "--binary", deckBinary, "--poll", "20", "--timeout", "30000"],
    });
    Object.assign(launch.env, { DECK_STUB_STATE: deckState, DECK_STUB_MODE: "happy" });
    const result = await new RunSupervisor().start(launch).finished;
    expect(result, `${result.failureClass}: ${result.failure}`).toMatchObject({ status: "succeeded", billFresh: "7", billMemo: "7" });
    expect(await readFile(join(deckState, "sends"), "utf8")).toBe("7\n");
    expect(await readFile(join(deckState, "message-mode"), "utf8")).toBe("600\n");
    expect(await readFile(join(deckState, "argv"), "utf8")).not.toContain("[question for");
  }, 60_000);

  it("keeps Agent Deck prompt text out of argv and failure diagnostics", async () => {
    const { directory, runner, descriptor } = await setup("review-lite");
    const { deckState, deckBinary } = await setupDeck(directory);
    const secret = "PRIVATE-DECK-PROMPT";
    const launch = await prepareLaunch({
      runner, descriptor, cwd: directory, stateDir: join(directory, "state"),
      inputs: { subject: secret }, targetKind: "deck",
      targetArgs: ["--session", "stub", "--binary", deckBinary, "--poll", "20", "--timeout", "1000"],
    });
    Object.assign(launch.env, { DECK_STUB_STATE: deckState, DECK_STUB_MODE: "send-fail" });
    const run = new RunSupervisor().start(launch);
    await until(() => [...run.snapshot.occurrences.values()].some(({ state }) => state === "recovering"));
    const occurrence = [...run.snapshot.occurrences.values()].find(({ state }) => state === "recovering")!;
    await run.recover(occurrence.id, "abandon");
    const result = await run.finished;
    expect(result.status).toBe("failed");
    expect(result.failure).not.toContain(secret);
    const argv = await readFile(join(deckState, "argv"), "utf8");
    expect(argv).not.toContain(secret);
    expect(await readFile(join(deckState, "message-mode"), "utf8")).toBe("600\n");
    const argvLines = argv.trimEnd().split("\n");
    const messageFile = argvLines[argvLines.indexOf("--message-file") + 1];
    expect(messageFile).toBeTruthy();
    await expect(access(messageFile)).rejects.toThrow();
    const diagnostics = await readFile(join(launch.storeDir, "stderr.log"), "utf8");
    expect(diagnostics).not.toContain(secret);
  }, 15_000);
});

async function setup(workflow = "harden") {
  const directory = await mkdtemp(join(tmpdir(), "agent-cat-native-e2e-"));
  created.push(directory);
  const runner: RunnerConfig = { id: "e2e", executable: runnerPath!, allowedCwds: [directory] };
  const descriptor = (await discoverRunner(runner, directory)).find(({ name }) => name === workflow);
  if (!descriptor) throw new Error(`${workflow} descriptor is missing`);
  return { directory, runner, descriptor };
}

async function setupDeck(directory: string) {
  const deckState = join(directory, "deck-state");
  const deckBinary = join(directory, "agent-deck");
  await mkdir(deckState, { recursive: true });
  await copyFile(resolve("../haskell/test/stub-deck.sh"), deckBinary);
  await chmod(deckBinary, 0o700);
  return { deckState, deckBinary };
}

async function until(predicate: () => boolean): Promise<void> {
  for (let count = 0; count < 500; count += 1) {
    if (predicate()) return;
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 10));
  }
  throw new Error("condition not reached");
}
