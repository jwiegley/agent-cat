#!/usr/bin/env node
import { accessSync, constants } from "node:fs";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { RemoteSession } from "@earendil-works/pi-coding-agent/client";

const runner = process.env.AGENT_CAT_E2E_RUNNER;
if (!runner) throw new Error("AGENT_CAT_E2E_RUNNER must name the built agentic-run executable");
accessSync(runner, constants.X_OK);
if (typeof RemoteSession.prototype.followUp !== "function") {
  throw new Error("integration tests require the accompanying local Pi packages (RemoteSession.followUp is absent)");
}

const vitest = fileURLToPath(new URL("../node_modules/vitest/vitest.mjs", import.meta.url));
const result = spawnSync(process.execPath, [vitest, "run",
  "test/native-targets-e2e.test.ts",
  "test/owned-child-e2e.test.ts",
  "test/current-bridge.test.ts",
  "test/pi-child-acp.test.ts",
  "test/pi-remote-acp.test.ts",
], { cwd: fileURLToPath(new URL("..", import.meta.url)), env: process.env, stdio: "inherit" });
if (result.error) throw result.error;
process.exit(result.status ?? 1);
