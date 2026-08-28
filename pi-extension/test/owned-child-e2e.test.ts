import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { discoverRunner } from "../src/catalogue.ts";
import { prepareLaunch, preflightLineage } from "../src/launch.ts";
import { RunSupervisor } from "../src/supervisor.ts";
import type { RunnerConfig } from "../src/types.ts";
import { piPackageRoot } from "./fixtures/pi-package-root.ts";

const runnerPath = process.env.AGENT_CAT_E2E_RUNNER;
const created: string[] = [];
afterEach(async () => Promise.all(created.splice(0).map((path) => rm(path, { recursive: true, force: true }))));

describe.runIf(Boolean(runnerPath))("owned Pi child through the extension supervisor", () => {
  it("answers a structured workflow and resumes from agent-cat's durable answer without another model request", async () => {
    const directory = await mkdtemp(join(tmpdir(), "agent-cat-child-e2e-"));
    created.push(directory);
    const agentDir = join(directory, "agent");
    const counter = join(directory, "model-requests");
    await mkdir(agentDir, { recursive: true });
    await writeFile(join(agentDir, "models.json"), JSON.stringify({ providers: { fixture: {
      baseUrl: "http://fixture.invalid/v1", api: "openai-completions", apiKey: "fixture-key",
      models: [{ id: "fixture-model", name: "Fixture", reasoning: false, input: ["text"], contextWindow: 8192, maxTokens: 1024, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }],
    } } }));
    await writeFile(join(agentDir, "settings.json"), JSON.stringify({ defaultProvider: "fixture", defaultModel: "fixture-model" }));

    const runner: RunnerConfig = { id: "e2e", executable: runnerPath!, allowedCwds: [directory] };
    const descriptor = (await discoverRunner(runner, directory)).find(({ name }) => name === "structured");
    if (!descriptor) throw new Error("structured descriptor is missing");
    const targetArgs = ["--engine", "acp", "--adapter", process.execPath, "--adapter-arg", resolve("src/pi-child-acp.mjs")];
    const stateDir = join(directory, "state");
    const childEnvironment = {
      AGENT_CAT_FIXTURE_COUNTER: counter,
      NODE_OPTIONS: [process.env.NODE_OPTIONS, `--import=${resolve("test/fixtures/openai-fetch-preload.mjs")}`].filter(Boolean).join(" "),
      PI_CODING_AGENT_DIR: agentDir,
      PI_PACKAGE_DIR: piPackageRoot,
    };

    const parent = await prepareLaunch({ runner, descriptor, cwd: directory, stateDir, inputs: {}, targetKind: "child", targetArgs });
    Object.assign(parent.env, childEnvironment);
    const parentResult = await new RunSupervisor().start(parent).finished;
    expect(parentResult).toMatchObject({ status: "succeeded", billFresh: "1", billMemo: "1" });
    expect(await requestCount(counter)).toBe(1);

    await preflightLineage({ runner, descriptor, cwd: directory, stateDir, inputs: {}, targetArgs, operation: "resume", parentRuntimeDir: join(parent.storeDir, "runtime") });
    const child = await prepareLaunch({
      runner, descriptor, cwd: directory, stateDir, inputs: {}, targetKind: "child", targetArgs,
      lineage: { operation: "resume", parentRunId: parent.manifest.runId, parentRuntimeDir: join(parent.storeDir, "runtime"), edits: [] },
    });
    Object.assign(child.env, childEnvironment);
    const childResult = await new RunSupervisor().start(child).finished;
    expect(childResult.status).toBe("succeeded");
    expect(childResult.occurrences.get("0")?.state).toBe("reused");
    expect(childResult.occurrences.get("0")?.attempts.size).toBe(0);
    expect(await requestCount(counter)).toBe(1);
  }, 60_000);
});

async function requestCount(path: string): Promise<number> {
  try {
    return (await readFile(path, "utf8")).trim().split("\n").filter(Boolean).length;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return 0;
    throw error;
  }
}
