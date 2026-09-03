#!/usr/bin/env node
import { spawn } from "node:child_process";

const runId = process.argv[3] ?? "tree-run";
const marker = process.env.FIXTURE_TREE_MARKER ?? "agent-cat-tree-child";
spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)", marker], { stdio: "ignore" });
process.on("SIGTERM", () => {});
process.stdin.resume();
process.stdout.write(process.env.FIXTURE_TREE_MALFORMED === "1"
  ? "{malformed protocol frame}\n"
  : `${JSON.stringify({ protocolVersion: 1, runId, sequence: "0", timestamp: new Date().toISOString(), event: { type: "run.started", workflow: "tree", target: "fixture" } })}\n`);
setInterval(() => {}, 1000);
