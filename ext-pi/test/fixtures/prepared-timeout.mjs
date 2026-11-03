#!/usr/bin/env node
import { spawn } from "node:child_process";
import { appendFileSync } from "node:fs";
import readline from "node:readline";

const [binary, fault, log, ...args] = process.argv.slice(2);
const frontend = args[0] === "frontend";
const worker = spawn(binary, args, { stdio: frontend ? ["pipe", "pipe", "inherit"] : "inherit" });
const record = (value) => appendFileSync(log, `${JSON.stringify(value)}\n`);
worker.on("error", (error) => { console.error(error); process.exitCode = 1; });
worker.on("close", (code, signal) => {
  if (frontend) record({ operation: "closed", code, signal });
  process.exitCode = code ?? 1;
});

if (frontend) {
  const input = readline.createInterface({ input: process.stdin });
  input.on("line", (line) => {
    const request = JSON.parse(line);
    if (request.operation === "discard") record(request);
    worker.stdin.write(`${line}\n`);
  });
  input.on("close", () => worker.stdin.end());
  readline.createInterface({ input: worker.stdout }).on("line", (line) => {
    const reply = JSON.parse(line);
    if (reply.operation === "prepared") {
      record({ operation: "prepared", runId: reply.runId, approvalId: reply.approvalId });
      if (fault === "missing") delete reply.policy.timeoutMs;
      else reply.policy.timeoutMs = 900000;
    }
    process.stdout.write(`${JSON.stringify(reply)}\n`);
  });
}
