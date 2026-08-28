import { chmod, copyFile, mkdir, mkdtemp, readFile, rm } from "node:fs/promises";
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
    expect(result).toMatchObject({ status: "succeeded", billFresh: "7", billMemo: "7" });
    expect([...result.occurrences.values()].some((occurrence) => occurrence.attempts.size > 0)).toBe(true);
  }, 60_000);

  it("executes the real stub agent-deck target", async () => {
    const { directory, runner, descriptor } = await setup();
    const deckState = join(directory, "deck-state");
    const deckBinary = join(directory, "agent-deck");
    await mkdir(deckState, { recursive: true });
    await copyFile(resolve("../haskell/test/stub-deck.sh"), deckBinary);
    await chmod(deckBinary, 0o700);
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
    expect(result).toMatchObject({ status: "succeeded", billFresh: "7", billMemo: "7" });
    expect(await readFile(join(deckState, "sends"), "utf8")).toBe("7\n");
  }, 60_000);
});

async function setup() {
  const directory = await mkdtemp(join(tmpdir(), "agent-cat-native-e2e-"));
  created.push(directory);
  const runner: RunnerConfig = { id: "e2e", executable: runnerPath!, allowedCwds: [directory] };
  const descriptor = (await discoverRunner(runner, directory)).find(({ name }) => name === "harden");
  if (!descriptor) throw new Error("harden descriptor is missing");
  return { directory, runner, descriptor };
}
