import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import readline from "node:readline";
import {
  createRemoteServiceEndpoint,
  defineService,
  RemoteServiceProvider,
  replicatedState,
} from "@earendil-works/chord";
import { createUnixServer } from "@earendil-works/pi-server/unix";
import { piPackageRoot } from "./fixtures/pi-package-root.ts";

process.env.PI_PACKAGE_DIR = piPackageRoot;
const { selectRemoteTarget } = await import("../src/index.ts");

const serverId = "00000000-0000-4000-8000-000000000001";
const SessionDirectory = defineService("pi.session-directory");
const SessionManagement = defineService("pi.session-management");
const AgentController = defineService("pi.agent-controller");
const Transcript = defineService("pi.transcript");
const children = new Set();
const directory = await mkdtemp(join(tmpdir(), "agent-cat-pi-current-"));
const socketPath = join(directory, `${serverId}.sock`);
const host = createHost(["session-a", "session-b"]);
let server = createUnixServer(host, { path: socketPath, serverId });

try {
  await server.start();
  const selected = await selectRemoteTarget(
    {
      ui: {
        notify() {},
        select: async (_title, choices) => choices.find((choice) => choice === "session-b"),
      },
    },
    { socket: socketPath },
  );
  assert.equal(selected?.env.AGENT_CAT_PI_REMOTE_SESSION, "session-b");
  assert.equal(selected?.env.AGENT_CAT_PI_REMOTE_SOCKET, socketPath);

  const first = await openAdapter(socketPath, "session-a");
  const competing = await spawnAdapter(socketPath, "session-a");
  await initialize(competing);
  send(competing.child, {
    jsonrpc: "2.0",
    id: 1,
    method: "session/new",
    params: { cwd: directory, mcpServers: [] },
  });
  assert.match((await nextMessage(competing)).error.message, /locked/i);
  assert.equal(await close(competing.child), 0);

  send(first.child, {
    jsonrpc: "2.0",
    id: 2,
    method: "session/prompt",
    params: { sessionId: first.sessionId, prompt: [{ type: "text", text: "hello" }] },
  });
  await until(() => host.runtime("session-a").phase === "turn");
  send(first.child, {
    jsonrpc: "2.0",
    method: "session/steer",
    params: { sessionId: first.sessionId, steerId: "follow", timing: "next-boundary", text: "focus" },
  });
  assert.deepEqual((await nextMessage(first)).params, { steerId: "follow", accepted: true });
  assert.deepEqual(host.runtime("session-a").followUps, ["focus"]);
  send(first.child, {
    jsonrpc: "2.0",
    method: "session/steer",
    params: { sessionId: first.sessionId, steerId: "steer", timing: "interrupt-now", text: "now" },
  });
  assert.deepEqual((await nextMessage(first)).params, { steerId: "steer", accepted: true });
  assert.deepEqual(host.runtime("session-a").steers, ["now"]);
  host.runtime("session-a").finishPrompt();
  assert.equal((await nextMessage(first)).params.update.content.text, "reply:hello");
  assert.equal((await nextMessage(first)).result.stopReason, "end_turn");

  send(first.child, {
    jsonrpc: "2.0",
    id: 3,
    method: "session/prompt",
    params: { sessionId: first.sessionId, prompt: [{ type: "text", text: "cancel me" }] },
  });
  await until(() => host.runtime("session-a").phase === "turn");
  send(first.child, { jsonrpc: "2.0", method: "session/cancel", params: { sessionId: first.sessionId } });
  assert.equal((await nextMessage(first)).result.stopReason, "cancelled");

  await server.close();
  server = createUnixServer(host, { path: socketPath, serverId });
  await server.start();
  send(first.child, {
    jsonrpc: "2.0",
    id: 4,
    method: "session/new",
    params: { cwd: directory, mcpServers: [] },
  });
  assert.equal((await nextMessage(first)).result.sessionId, "session-a");
  assert.equal(await close(first.child), 0);

  const reattached = await openAdapter(socketPath, "session-a");
  assert.equal(reattached.sessionId, "session-a");
  assert.equal(await close(reattached.child), 0);
} finally {
  for (const child of children) child.kill("SIGKILL");
  await server.close().catch(() => {});
  await rm(directory, { recursive: true, force: true });
}

function createHost(sessionIds) {
  const metadata = new Map(sessionIds.map((id, index) => [id, {
    id,
    createdAt: index + 1,
    storageVersion: 1,
    cwd: directory,
  }]));
  const runtimes = new Map(sessionIds.map((id) => [id, createRuntime()]));
  const directoryState = replicatedState({
    revision: 1,
    sessions: [...metadata.values()].map(({ id, createdAt }) => ({ serverId, sessionId: id, createdAt })),
  });

  return {
    serverServices: {
      attachClient(presentation) {
        const provider = new RemoteServiceProvider([
          { service: SessionDirectory, mode: "singleton" },
          { service: SessionManagement, mode: "singleton" },
        ]);
        provider.provide(SessionDirectory, { state: directoryState });
        provider.provide(SessionManagement, {
          async create() { throw new Error("not supported"); },
          async remove() { throw new Error("not supported"); },
          attach: (sessionId, context) => presentation.attachSession(sessionId, context),
          detach: (context) => presentation.detachSession(context),
        });
        return endpointAttachment(provider);
      },
    },
    async resolveSession(sessionId) {
      const resolved = metadata.get(sessionId);
      if (!resolved) throw new Error(`unknown session ${sessionId}`);
      return resolved;
    },
    async openSession(resolved) {
      const runtime = runtimes.get(resolved.id);
      return {
        attachClient() {
          return endpointAttachment(runtime.provider());
        },
        async close() {},
      };
    },
    runtime(sessionId) {
      return runtimes.get(sessionId);
    },
  };
}

function createRuntime() {
  const state = replicatedState({
    snapshot: { transcript: [], operation: null, queues: [] },
    event: null,
  });
  let sequence = 0;
  let pending;
  const runtime = {
    phase: "idle",
    steers: [],
    followUps: [],
    provider() {
      const provider = new RemoteServiceProvider([
        { service: AgentController, mode: "singleton" },
        { service: Transcript, mode: "singleton" },
      ]);
      provider.provide(Transcript, { state });
      provider.provide(AgentController, {
        prompt({ message }, context) {
          if (pending) return Promise.resolve({ accepted: false, operationId: null, error: { code: "busy", message: "busy" } });
          const operationId = `operation-${++sequence}`;
          runtime.phase = "turn";
          state.state.snapshot = { ...state.state.snapshot, operation: { id: operationId } };
          state.state.event = null;
          state.publish(context);
          return new Promise((resolvePromise) => {
            pending = { message, operationId, context, resolve: resolvePromise };
          });
        },
        async requestAbort(operationId) {
          if (pending?.operationId !== operationId) throw new Error("unknown operation");
          runtime.finishPrompt("aborted");
        },
        async steer({ message }) {
          if (!pending) return { accepted: false, entryId: null, error: { code: "idle", message: "idle" } };
          runtime.steers.push(message);
          return { accepted: true, entryId: `steer-${runtime.steers.length}`, error: null };
        },
        async followUp({ message }) {
          if (!pending) return { accepted: false, entryId: null, error: { code: "idle", message: "idle" } };
          runtime.followUps.push(message);
          return { accepted: true, entryId: `follow-${runtime.followUps.length}`, error: null };
        },
        async nextRun() { return { accepted: false, entryId: null, error: { code: "unsupported", message: "unsupported" } }; },
        async cancelQueued() { return { outcome: "not_found" }; },
        async resume() { return { accepted: false, operationId: null, error: { code: "unsupported", message: "unsupported" } }; },
        async compact() { return { accepted: false, operationId: null, error: { code: "unsupported", message: "unsupported" } }; },
        async navigate() { return { accepted: false, operationId: null, error: { code: "unsupported", message: "unsupported" } }; },
      });
      return provider;
    },
    finishPrompt(stopReason = "stop") {
      if (!pending) throw new Error("no prompt is active");
      const current = pending;
      pending = undefined;
      runtime.phase = "idle";
      const timestamp = Date.now();
      const assistant = {
        role: "assistant",
        content: stopReason === "aborted" ? [] : [{ type: "text", text: `reply:${current.message}` }],
        api: "faux",
        provider: "faux",
        model: "faux",
        usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
        stopReason,
        timestamp,
      };
      const entry = {
        type: "message",
        id: `entry-${sequence}`,
        parentId: null,
        timestamp: new Date(timestamp).toISOString(),
        message: assistant,
      };
      state.state.snapshot = {
        ...state.state.snapshot,
        transcript: [...state.state.snapshot.transcript, entry],
        operation: null,
      };
      state.state.event = { type: "message_end", runId: current.operationId, message: assistant };
      state.publish(current.context);
      current.resolve({ accepted: true, operationId: current.operationId, error: null });
    },
  };
  return runtime;
}

function endpointAttachment(provider) {
  const endpoint = createRemoteServiceEndpoint(provider);
  return {
    invokeService: (call, publish, context) => endpoint.invoke(call, publish, context),
    release() {
      endpoint.dispose();
      provider.dispose();
    },
  };
}

async function openAdapter(socket, sessionId) {
  const adapter = await spawnAdapter(socket, sessionId);
  await initialize(adapter);
  send(adapter.child, {
    jsonrpc: "2.0",
    id: 1,
    method: "session/new",
    params: { cwd: directory, mcpServers: [] },
  });
  const response = await nextMessage(adapter);
  if (response.error) throw new Error(response.error.message);
  return { ...adapter, sessionId: response.result.sessionId };
}

async function spawnAdapter(socket, sessionId) {
  const child = spawn(process.execPath, [resolve("src/pi-remote-acp.mjs")], {
    env: {
      ...process.env,
      AGENT_CAT_PI_REMOTE_SOCKET: socket,
      AGENT_CAT_PI_REMOTE_SESSION: sessionId,
      PI_PACKAGE_DIR: piPackageRoot,
    },
    stdio: ["pipe", "pipe", "pipe"],
  });
  children.add(child);
  child.once("close", () => children.delete(child));
  return {
    child,
    lines: readline.createInterface({ input: child.stdout })[Symbol.asyncIterator](),
    stderr: child.stderr,
  };
}

async function initialize(adapter) {
  send(adapter.child, { jsonrpc: "2.0", id: 0, method: "initialize", params: { protocolVersion: 1 } });
  assert.equal((await nextMessage(adapter)).result.protocolVersion, 1);
}

function send(child, value) {
  child.stdin.write(`${JSON.stringify(value)}\n`);
}

async function nextMessage(adapter) {
  const next = await adapter.lines.next();
  if (!next.value) {
    let stderr = "";
    for await (const chunk of adapter.stderr) stderr += chunk;
    throw new Error(`adapter exited without a response: ${stderr.trim()}`);
  }
  return JSON.parse(next.value);
}

function close(child) {
  const closed = new Promise((resolvePromise) => child.once("close", resolvePromise));
  child.stdin.end();
  return closed;
}

async function until(predicate) {
  for (let count = 0; count < 500; count += 1) {
    if (predicate()) return;
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 10));
  }
  throw new Error("condition not reached");
}
