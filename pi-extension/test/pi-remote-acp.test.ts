import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import readline from "node:readline";
import { RemoteSession } from "@earendil-works/pi-coding-agent/client";
import { createUnixServer } from "@earendil-works/pi-server/unix";
import { TestServerService } from "@earendil-works/pi-server/testing";
import { selectRemoteTarget } from "../src/index.ts";
import { afterEach, describe, expect, it } from "vitest";
import { piPackageRoot } from "./fixtures/pi-package-root.ts";

const created: string[] = [];
afterEach(async () => Promise.all(created.splice(0).map((path) => rm(path, { recursive: true, force: true }))));

describe.runIf(typeof (RemoteSession.prototype as unknown as { followUp?: unknown }).followUp === "function")("known remote Pi ACP adapter", () => {
  it("selects a session discovered through the authenticated transport", async () => {
    const directory = await mkdtemp(join(tmpdir(), "agent-cat-remote-discovery-"));
    created.push(directory);
    const socketPath = join(directory, "server.sock");
    const service = new TestServerService();
    service.seed("session-a", "Alpha", directory);
    service.seed("session-b", "Beta", directory);
    const server = createUnixServer(service, { path: socketPath });
    await server.start();
    try {
      const selected = await selectRemoteTarget({ ui: { select: async (_title: string, choices: string[]) => choices.find((choice) => choice.startsWith("session-b")) } } as never, { socket: socketPath });
      expect(selected?.env.AGENT_CAT_PI_REMOTE_SESSION).toBe("session-b");
      expect(selected?.env.AGENT_CAT_PI_REMOTE_SOCKET).toBe(socketPath);
    } finally {
      await server.close();
    }
  });

  it("uses an exclusive lease, forwards snapshots, aborts, reconnects, releases, and reattaches", async () => {
    const directory = await mkdtemp(join(tmpdir(), "agent-cat-remote-"));
    created.push(directory);
    const socketPath = join(directory, "server.sock");
    const service = new TestServerService();
    service.seed("known-session", "Known", directory);
    const canary = join(directory, "live-session.jsonl");
    await writeFile(canary, "owner data\n", "utf8");
    let server = createUnixServer(service, { path: socketPath });
    await server.start();
    const first = await openAdapter(socketPath, directory);
    try {
      expect(first.sessionId).toBe("known-session");
      const competing = await spawnAdapter(socketPath);
      await initialize(competing);
      send(competing.child, { jsonrpc: "2.0", id: 1, method: "session/new", params: { cwd: directory, mcpServers: [] } });
      expect(JSON.parse((await competing.lines.next()).value).error.message).toMatch(/lease|locked|owned/i);
      expect(await close(competing.child)).toBe(0);

      send(first.child, { jsonrpc: "2.0", id: 2, method: "session/prompt", params: { sessionId: first.sessionId, prompt: [{ type: "text", text: "hello" }] } });
      await until(() => service.latestRuntime("known-session").getPhase() === "turn");
      send(first.child, { jsonrpc: "2.0", method: "session/steer", params: { sessionId: first.sessionId, steerId: "remote-steer", timing: "next-boundary", text: "focus" } });
      expect(JSON.parse((await first.lines.next()).value).params).toEqual({ steerId: "remote-steer", accepted: true });
      await until(() => (service.latestRuntime("known-session") as unknown as { followUps: unknown[] }).followUps.length === 1);
      expect((service.latestRuntime("known-session") as unknown as { followUps: unknown[] }).followUps).toEqual([{ text: "focus" }]);
      send(first.child, { jsonrpc: "2.0", method: "session/steer", params: { sessionId: first.sessionId, steerId: "remote-interrupt", timing: "interrupt-now", text: "interrupt" } });
      expect(JSON.parse((await first.lines.next()).value).params).toEqual({ steerId: "remote-interrupt", accepted: true });
      await until(() => service.latestRuntime("known-session").steers.length === 1);
      expect(service.latestRuntime("known-session").steers).toEqual([{ text: "interrupt" }]);
      service.latestRuntime("known-session").finishPrompt();
      expect(JSON.parse((await first.lines.next()).value).params.update.content.text).toBe("reply:hello");
      expect(JSON.parse((await first.lines.next()).value).result.stopReason).toBe("end_turn");
      send(first.child, { jsonrpc: "2.0", method: "session/steer", params: { sessionId: first.sessionId, steerId: "remote-late", timing: "next-boundary", text: "late" } });
      expect(JSON.parse((await first.lines.next()).value).params).toEqual({ steerId: "remote-late", accepted: false });

      send(first.child, { jsonrpc: "2.0", id: 3, method: "session/prompt", params: { sessionId: first.sessionId, prompt: [{ type: "text", text: "cancel me" }] } });
      await until(() => service.latestRuntime("known-session").getPhase() === "turn");
      send(first.child, { jsonrpc: "2.0", method: "session/cancel", params: { sessionId: first.sessionId } });
      expect(JSON.parse((await first.lines.next()).value).result.stopReason).toBe("cancelled");
      await server.close();
      server = createUnixServer(service, { path: socketPath });
      await server.start();
      send(first.child, { jsonrpc: "2.0", id: 4, method: "session/new", params: { cwd: directory, mcpServers: [] } });
      expect(JSON.parse((await first.lines.next()).value).result.sessionId).toBe("known-session");
      expect(await readFile(canary, "utf8")).toBe("owner data\n");
    } finally {
      expect(await close(first.child)).toBe(0);
    }

    const reattached = await openAdapter(socketPath, directory);
    expect(reattached.sessionId).toBe("known-session");
    expect(await close(reattached.child)).toBe(0);
    await server.close();
  }, 30_000);
});

async function openAdapter(socketPath: string, cwd: string) {
  const adapter = await spawnAdapter(socketPath);
  await initialize(adapter);
  send(adapter.child, { jsonrpc: "2.0", id: 1, method: "session/new", params: { cwd, mcpServers: [] } });
  const sessionId = JSON.parse((await adapter.lines.next()).value).result.sessionId;
  return { ...adapter, sessionId };
}

async function spawnAdapter(socketPath: string): Promise<{ child: ChildProcessWithoutNullStreams; lines: AsyncIterator<string> }> {
  const child = spawn(process.execPath, [resolve("src/pi-remote-acp.mjs")], {
    env: { ...process.env, AGENT_CAT_PI_REMOTE_SOCKET: socketPath, AGENT_CAT_PI_REMOTE_SESSION: "known-session", PI_PACKAGE_DIR: piPackageRoot },
    stdio: ["pipe", "pipe", "pipe"],
  });
  const lines = readline.createInterface({ input: child.stdout })[Symbol.asyncIterator]();
  return { child, lines };
}

async function initialize(adapter: { child: ChildProcessWithoutNullStreams; lines: AsyncIterator<string> }): Promise<void> {
  send(adapter.child, { jsonrpc: "2.0", id: 0, method: "initialize", params: { protocolVersion: 1 } });
  expect(JSON.parse((await adapter.lines.next()).value).result.protocolVersion).toBe(1);
}

function send(child: ChildProcessWithoutNullStreams, value: unknown): void {
  child.stdin.write(`${JSON.stringify(value)}\n`);
}

function close(child: ChildProcessWithoutNullStreams): Promise<number | null> {
  const closed = new Promise<number | null>((resolvePromise) => child.once("close", resolvePromise));
  child.stdin.end();
  return closed;
}

async function until(predicate: () => boolean): Promise<void> {
  for (let count = 0; count < 500; count += 1) {
    try {
      if (predicate()) return;
    } catch {}
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 10));
  }
  throw new Error("condition not reached");
}
