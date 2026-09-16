#!/usr/bin/env node
import { accessSync, constants } from "node:fs";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const runner = process.env.AGENT_CAT_E2E_RUNNER;
if (!runner) throw new Error("AGENT_CAT_E2E_RUNNER must name the built agentic-run executable");
accessSync(runner, constants.X_OK);

const vitest = fileURLToPath(new URL("../node_modules/vitest/vitest.mjs", import.meta.url));
for (const args of [
  [vitest, "run",
    "test/native-targets-e2e.test.ts",
    "test/owned-child-e2e.test.ts",
    "test/current-bridge.test.ts",
    "test/pi-child-acp.test.ts",
  ],
  [fileURLToPath(new URL("./pi-remote-current.mjs", import.meta.url))],
]) {
  const result = spawnSync(process.execPath, args, { cwd: fileURLToPath(new URL("..", import.meta.url)), env: process.env, stdio: "inherit" });
  if (result.error) throw result.error;
  if (result.status !== 0) process.exit(result.status ?? 1);
}
