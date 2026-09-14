#!/usr/bin/env node
import { accessSync, constants } from "node:fs";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import "../src/pi-remote-runtime.mjs";

const runner = process.env.AGENT_CAT_E2E_RUNNER;
if (!runner) throw new Error("AGENT_CAT_E2E_RUNNER must name the built agentic-run executable");
accessSync(runner, constants.X_OK);

const root = new URL("..", import.meta.url);
const tests = [
  "test/native-targets-e2e.test.ts",
  "test/owned-child-e2e.test.ts",
  "test/current-bridge.test.ts",
  "test/pi-child-acp.test.ts",
];
const remote = "test/pi-remote-current.mjs";
for (const test of [...tests, remote]) accessSync(new URL(test, root), constants.R_OK);
const vitest = fileURLToPath(new URL("node_modules/vitest/vitest.mjs", root));
for (const args of [
  [vitest, "run", ...tests],
  [fileURLToPath(new URL(remote, root))],
]) {
  const result = spawnSync(process.execPath, args, { cwd: fileURLToPath(root), env: process.env, stdio: "inherit" });
  if (result.error) throw result.error;
  if (result.status !== 0) process.exit(result.status ?? 1);
}
