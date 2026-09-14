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
  "test/pi-remote-acp.test.mjs",
];
for (const test of tests) accessSync(new URL(test, root), constants.R_OK);
const vitest = fileURLToPath(new URL("node_modules/vitest/vitest.mjs", root));
const result = spawnSync(process.execPath, [vitest, "run", ...tests], { cwd: fileURLToPath(root), env: process.env, stdio: "inherit" });
if (result.error) throw result.error;
process.exit(result.status ?? 1);
