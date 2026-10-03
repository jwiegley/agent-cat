import { spawn } from "node:child_process";
import { mkdir, mkdtemp, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import readline from "node:readline";
import { afterEach, describe, expect, it } from "vitest";
import { CurrentSessionBridge } from "../src/current-bridge.ts";

const created: string[] = [];
afterEach(async () => Promise.all(created.splice(0).map((path) => rm(path, { recursive: true, force: true }))));

describe("current Pi session ACP bridge", () => {
  it("authenticates its proxy and completes an ACP prompt", async () => {
    const directory = await mkdtemp(join(tmpdir(), "cb-"));
    created.push(directory);
    let prompt = "";
    let aborted = false;
    let turnNumber = 0;
    let resolveTurn!: (value: { id: string; messages: unknown[] }) => void;
    const sent: Array<{ text: string; options: unknown }> = [];
    const pi = {
      startTaskTurn: (text: string) => {
        prompt = text;
        const id = `turn-${++turnNumber}`;
        sent.push({ text, options: { taskTurn: id } });
        const completed = new Promise<{ id: string; messages: unknown[] }>((resolvePromise) => { resolveTurn = resolvePromise; });
        return {
          id, completed,
          steer: async (steering: string) => { sent.push({ text: steering, options: { deliverAs: "steer" } }); },
          followUp: async (followUp: string) => { sent.push({ text: followUp, options: { deliverAs: "followUp" } }); },
          abort: async () => { aborted = true; resolveTurn({ id, messages: [{ role: "assistant", content: [{ type: "text", text: "partial" }], stopReason: "aborted" }] }); },
        };
      },
    };
    const context = { isIdle: () => true };
    const bridge = new CurrentSessionBridge(pi as never, () => context as never);
    await bridge.start(directory);
    const target = bridge.target();
    const proxy = target.args.at(-1)!;
    const child = spawn(process.execPath, [proxy], { env: { ...process.env, ...target.env }, stdio: ["pipe", "pipe", "pipe"] });
    const lines = readline.createInterface({ input: child.stdout })[Symbol.asyncIterator]();
    const send = (value: unknown) => child.stdin.write(`${JSON.stringify(value)}\n`);

    send({ jsonrpc: "2.0", id: 0, method: "initialize", params: { protocolVersion: 1 } });
    expect(JSON.parse((await lines.next()).value).result.protocolVersion).toBe(1);
    send({ jsonrpc: "2.0", id: 1, method: "session/new", params: { cwd: directory, mcpServers: [] } });
    const sessionId = JSON.parse((await lines.next()).value).result.sessionId;
    send({ jsonrpc: "2.0", id: 2, method: "session/prompt", params: { sessionId, prompt: [{ type: "text", text: "hello" }] } });
    await until(() => prompt === "hello");
    send({ jsonrpc: "2.0", method: "session/steer", params: { sessionId, steerId: "follow-1", timing: "next-boundary", text: "later" } });
    expect(JSON.parse((await lines.next()).value).params).toEqual({ steerId: "follow-1", accepted: true });
    await until(() => sent.length === 2);
    expect(sent[1]).toEqual({ text: "later", options: { deliverAs: "followUp" } });
    send({ jsonrpc: "2.0", method: "session/steer", params: { sessionId, steerId: "steer-1", timing: "interrupt-now", text: "focus" } });
    expect(JSON.parse((await lines.next()).value).params).toEqual({ steerId: "steer-1", accepted: true });
    await until(() => sent.length === 3);
    expect(sent[2]).toEqual({ text: "focus", options: { deliverAs: "steer" } });
    resolveTurn({ id: "turn-1", messages: [{ role: "assistant", content: [{ type: "text", text: "world" }], stopReason: "stop" }] });
    expect(JSON.parse((await lines.next()).value).params.update.content.text).toBe("world");
    expect(JSON.parse((await lines.next()).value).result.stopReason).toBe("end_turn");
    send({ jsonrpc: "2.0", method: "session/steer", params: { sessionId, steerId: "steer-late", timing: "interrupt-now", text: "must not queue" } });
    expect(JSON.parse((await lines.next()).value).params).toEqual({ steerId: "steer-late", accepted: false });
    expect(sent).toHaveLength(3);
    send({ jsonrpc: "2.0", id: 3, method: "session/prompt", params: { sessionId, prompt: [{ type: "text", text: "abort" }] } });
    await until(() => sent.length === 4);
    send({ jsonrpc: "2.0", method: "session/cancel", params: { sessionId } });
    expect(JSON.parse((await lines.next()).value).params.update.content.text).toBe("partial");
    expect(JSON.parse((await lines.next()).value).result.stopReason).toBe("cancelled");

    child.stdin.end();
    await new Promise((resolve) => child.once("close", resolve));
    await bridge.close();
    expect(aborted).toBe(true);
  });

  it("binds a socket path that fits the address limit when the state directory is long", async () => {
    const directory = await mkdtemp(join(tmpdir(), "cb-"));
    created.push(directory);
    // The truncated form of the socket path in the state directory is the
    // state directory itself, which made an earlier bridge fail with
    // EADDRINUSE. Other lengths bound a truncated path silently.
    const fill = "x".repeat(Math.max(1, 103 - Buffer.byteLength(join(directory, "s/state"))));
    const stateDir = join(directory, `s${fill}`, "state");
    await mkdir(stateDir, { recursive: true });
    expect(Buffer.byteLength(stateDir)).toBeGreaterThanOrEqual(103);
    const pi = { startTaskTurn: () => { throw new Error("no turn in this test"); } };
    const bridge = new CurrentSessionBridge(pi as never, () => ({ isIdle: () => true }) as never);
    await bridge.start(stateDir);
    const target = bridge.target();
    const socketPath = target.env.AGENT_CAT_PI_BRIDGE_SOCKET!;
    expect(Buffer.byteLength(socketPath)).toBeLessThanOrEqual(103);
    expect((await stat(socketPath)).isSocket()).toBe(true);
    const child = spawn(process.execPath, [target.args.at(-1)!], { env: { ...process.env, ...target.env }, stdio: ["pipe", "pipe", "pipe"] });
    const lines = readline.createInterface({ input: child.stdout })[Symbol.asyncIterator]();
    child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id: 0, method: "initialize", params: { protocolVersion: 1 } })}\n`);
    expect(JSON.parse((await lines.next()).value).result.agentInfo.name).toBe("pi-current-session");
    child.stdin.end();
    await new Promise((resolve) => child.once("close", resolve));
    await bridge.close();
    await expect(stat(socketPath)).rejects.toThrow();
    await expect(stat(dirname(socketPath))).rejects.toThrow();
  });
});

async function until(predicate: () => boolean): Promise<void> {
  for (let count = 0; count < 100; count += 1) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error("condition not reached");
}
