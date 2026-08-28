import { createServer } from "node:http";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { discoverRunner } from "../src/catalogue.ts";
import { prepareLaunch, preflightLineage } from "../src/launch.ts";
import { RunSupervisor } from "../src/supervisor.ts";
import type { RunnerConfig } from "../src/types.ts";

const runnerPath = process.env.AGENT_CAT_E2E_RUNNER;
const created: string[] = [];
afterEach(async () => Promise.all(created.splice(0).map((path) => rm(path, { recursive: true, force: true }))));

describe.runIf(Boolean(runnerPath))("owned Pi child through the extension supervisor", () => {
  it("answers a structured workflow and resumes from agent-cat's durable answer without another model request", async () => {
    const directory = await mkdtemp(join(tmpdir(), "agent-cat-child-e2e-"));
    created.push(directory);
    const fixture = await startModelFixture();
    try {
      const agentDir = join(directory, "agent");
      await mkdir(agentDir, { recursive: true });
      await writeFile(join(agentDir, "models.json"), JSON.stringify({ providers: { fixture: {
        baseUrl: `${fixture.url}/v1`, api: "openai-completions", apiKey: "fixture-key",
        models: [{ id: "fixture-model", name: "Fixture", reasoning: false, input: ["text"], contextWindow: 8192, maxTokens: 1024, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }],
      } } }));
      await writeFile(join(agentDir, "settings.json"), JSON.stringify({ defaultProvider: "fixture", defaultModel: "fixture-model" }));

      const runner: RunnerConfig = { id: "e2e", executable: runnerPath!, allowedCwds: [directory] };
      const descriptor = (await discoverRunner(runner, directory)).find(({ name }) => name === "structured");
      if (!descriptor) throw new Error("structured descriptor is missing");
      const targetArgs = ["--engine", "acp", "--adapter", process.execPath, "--adapter-arg", resolve("src/pi-child-acp.mjs")];
      const stateDir = join(directory, "state");
      const parent = await prepareLaunch({ runner, descriptor, cwd: directory, stateDir, inputs: {}, targetKind: "child", targetArgs });
      parent.env.PI_CODING_AGENT_DIR = agentDir;
      const parentResult = await new RunSupervisor().start(parent).finished;
      expect(parentResult).toMatchObject({ status: "succeeded", billFresh: "1", billMemo: "1" });
      expect(fixture.requests()).toBe(1);

      await preflightLineage({ runner, descriptor, cwd: directory, stateDir, inputs: {}, targetArgs, operation: "resume", parentRuntimeDir: join(parent.storeDir, "runtime") });
      const child = await prepareLaunch({
        runner, descriptor, cwd: directory, stateDir, inputs: {}, targetKind: "child", targetArgs,
        lineage: { operation: "resume", parentRunId: parent.manifest.runId, parentRuntimeDir: join(parent.storeDir, "runtime"), edits: [] },
      });
      child.env.PI_CODING_AGENT_DIR = agentDir;
      const childResult = await new RunSupervisor().start(child).finished;
      expect(childResult.status).toBe("succeeded");
      expect(childResult.occurrences.get("0")?.state).toBe("reused");
      expect(childResult.occurrences.get("0")?.attempts.size).toBe(0);
      expect(fixture.requests()).toBe(1);
    } finally {
      await fixture.close();
    }
  }, 60_000);
});

async function startModelFixture(): Promise<{ url: string; requests: () => number; close: () => Promise<void> }> {
  let requests = 0;
  const server = createServer((request, response) => {
    if (request.method !== "POST" || request.url !== "/v1/chat/completions") {
      response.writeHead(404).end();
      return;
    }
    request.resume();
    request.on("end", () => {
      requests += 1;
      response.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-cache", connection: "close" });
      response.write(`data: ${JSON.stringify({ id: "fixture", object: "chat.completion.chunk", choices: [{ index: 0, delta: { role: "assistant", content: '{"title":"Child result","priority":1,"steps":["decode"]}' }, finish_reason: null }] })}\n\n`);
      response.write(`data: ${JSON.stringify({ id: "fixture", object: "chat.completion.chunk", choices: [{ index: 0, delta: {}, finish_reason: "stop" }] })}\n\n`);
      response.end("data: [DONE]\n\n");
    });
  });
  await new Promise<void>((resolvePromise, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => resolvePromise());
  });
  const address = server.address();
  if (!address || typeof address === "string") throw new Error("fixture server has no TCP address");
  return {
    url: `http://127.0.0.1:${address.port}`,
    requests: () => requests,
    close: () => new Promise<void>((resolvePromise, reject) => {
      server.close((error) => error ? reject(error) : resolvePromise());
      server.closeAllConnections();
    }),
  };
}
