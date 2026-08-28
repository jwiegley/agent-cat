import { spawn } from "node:child_process";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import readline from "node:readline";
import { afterEach, describe, expect, it } from "vitest";

const created: string[] = [];
afterEach(async () => Promise.all(created.splice(0).map((path) => rm(path, { recursive: true, force: true }))));

describe("owned Pi child ACP adapter", () => {
  it("performs the handshake, handles idle cancellation, and cleans up", async () => {
    const directory = await temporaryDirectory();
    const child = await openChild(directory);
    expect(child.sessionId).toMatch(/^[0-9a-f-]{36}$/);
    expect(await child.close()).toBe(0);
  }, 30_000);

  it("owns distinct child sessions concurrently", async () => {
    const [leftDirectory, rightDirectory] = await Promise.all([temporaryDirectory(), temporaryDirectory()]);
    const [left, right] = await Promise.all([openChild(leftDirectory), openChild(rightDirectory)]);
    expect(left.sessionId).not.toBe(right.sessionId);
    expect(await Promise.all([left.close(), right.close()])).toEqual([0, 0]);
  }, 30_000);
});

async function temporaryDirectory(): Promise<string> {
  const directory = await mkdtemp(join(tmpdir(), "agent-cat-child-"));
  created.push(directory);
  return directory;
}

async function openChild(directory: string): Promise<{ sessionId: string; close: () => Promise<number | null> }> {
  const child = spawn(process.execPath, [resolve("src/pi-child-acp.mjs")], { cwd: directory, stdio: ["pipe", "pipe", "pipe"] });
  const lines = readline.createInterface({ input: child.stdout })[Symbol.asyncIterator]();
  child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id: 0, method: "initialize", params: { protocolVersion: 1 } })}\n`);
  expect(JSON.parse((await lines.next()).value).result.protocolVersion).toBe(1);
  child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id: 1, method: "session/new", params: { cwd: directory, mcpServers: [] } })}\n`);
  const sessionId = JSON.parse((await lines.next()).value).result.sessionId;
  child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", method: "session/steer", params: { sessionId, steerId: "idle-steer", timing: "interrupt-now", text: "no" } })}\n`);
  expect(JSON.parse((await lines.next()).value).params).toEqual({ steerId: "idle-steer", accepted: false });
  return {
    sessionId,
    close: async () => {
      const closed = new Promise<number | null>((resolvePromise) => child.once("close", resolvePromise));
      child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", method: "session/cancel", params: { sessionId } })}\n`);
      child.stdin.end();
      return closed;
    },
  };
}
