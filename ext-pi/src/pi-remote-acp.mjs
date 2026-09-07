#!/usr/bin/env node
import { randomUUID } from "node:crypto";
import { open, readFile, unlink } from "node:fs/promises";
import { isAbsolute } from "node:path";
import readline from "node:readline";
import { openRemotePi } from "./pi-remote-runtime.mjs";

const socketPath = process.env.AGENT_CAT_PI_REMOTE_SOCKET;
if (!socketPath || !isAbsolute(socketPath)) {
  process.stderr.write("AGENT_CAT_PI_REMOTE_SOCKET must name an absolute Unix socket\n");
  process.exit(2);
}
const knownSessionId = process.env.AGENT_CAT_PI_REMOTE_SESSION;
if (!knownSessionId) {
  process.stderr.write("AGENT_CAT_PI_REMOTE_SESSION must name a known remote session\n");
  process.exit(2);
}

const leasePath = `${socketPath}.agent-cat-${encodeURIComponent(knownSessionId)}.lock`;
const leaseToken = `${process.pid}:${randomUUID()}`;
let lease;
let remote;
let sessionId;
let activePromptId;
const lines = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
const promptTasks = new Set();

try {
  for await (const line of lines) {
    if (!line.trim()) continue;
    let request;
    try {
      request = JSON.parse(line);
      if (request.method === "session/prompt") {
        const task = handlePrompt(request)
          .catch((failure) => error(request.id, -32000, failure instanceof Error ? failure.message : String(failure)))
          .finally(() => promptTasks.delete(task));
        promptTasks.add(task);
      } else {
        await handleControl(request);
      }
    } catch (failure) {
      if (request?.id !== undefined) error(request.id, -32000, failure instanceof Error ? failure.message : String(failure));
      else process.stderr.write(`Pi remote ACP error: ${failure instanceof Error ? failure.message : String(failure)}\n`);
    }
  }
  await Promise.allSettled(promptTasks);
} finally {
  await closeRemote();
  await releaseLease();
}

async function handleControl(request) {
  const { id, method, params = {} } = request;
  if (method === "initialize") {
    result(id, { protocolVersion: 1, agentCapabilities: { loadSession: false, agentCat: { steer: true } }, agentInfo: { name: "pi-known-remote", version: "1" } });
  } else if (method === "session/new") {
    if (activePromptId !== undefined) throw new Error("cannot replace a session during an active prompt");
    if (typeof params.cwd !== "string" || !isAbsolute(params.cwd)) throw new Error("session cwd must be absolute");
    await acquireLease();
    await closeRemote();
    try {
      remote = await openRemotePi(socketPath);
      if (!remote.listSessions().some((session) => session.sessionId === knownSessionId)) {
        throw new Error(`unknown remote session ${knownSessionId}`);
      }
      await remote.attach(knownSessionId);
      sessionId = knownSessionId;
      result(id, { sessionId });
    } catch (failure) {
      await closeRemote();
      await releaseLease();
      throw failure;
    }
  } else if (method === "session/steer") {
    const validTiming = params.timing === "interrupt-now" || params.timing === "next-boundary";
    let accepted = Boolean(remote && activePromptId !== undefined && params.sessionId === sessionId && typeof params.text === "string" && validTiming);
    if (accepted) {
      try {
        const response = params.timing === "next-boundary"
          ? await remote.followUp(params.text)
          : await remote.steer(params.text);
        accepted = response.accepted;
      } catch {
        accepted = false;
      }
    }
    notification("session/steer_ack", { steerId: params.steerId, accepted });
  } else if (method === "session/cancel") {
    const operationId = remote?.activeOperationId();
    if (operationId) await remote.requestAbort(operationId);
  } else if (id !== undefined) {
    error(id, -32601, `unknown method ${method}`);
  }
}

async function handlePrompt(request) {
  const { id, params = {} } = request;
  if (!remote || params.sessionId !== sessionId) throw new Error("unknown session");
  if (activePromptId !== undefined) throw new Error("a prompt is already active");
  activePromptId = id;
  let assistant;
  const unsubscribe = remote.subscribe((value) => {
    const event = value.event;
    if (event?.type === "message_end" && event.message?.role === "assistant") assistant = event.message;
  });
  try {
    const response = await remote.prompt(promptText(params.prompt));
    if (!response.accepted) throw new Error(response.error.message);
    if (response.error) throw new Error(response.error.message);
    assistant ??= lastAssistant(remote.snapshot()?.transcript);
    const answer = assistant?.content.filter((part) => part.type === "text").map((part) => part.text).join("") ?? "";
    if (answer) notification("session/update", { sessionId, update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: answer } } });
    result(id, { stopReason: stopReason(assistant) });
  } finally {
    unsubscribe();
    activePromptId = undefined;
  }
}

async function acquireLease() {
  if (lease) return;
  for (let attempt = 0; attempt < 2; attempt += 1) {
    try {
      lease = await open(leasePath, "wx", 0o600);
      await lease.writeFile(`${leaseToken}\n`);
      return;
    } catch (failure) {
      if (failure?.code !== "EEXIST") throw failure;
      const owner = await readFile(leasePath, "utf8").catch(() => "");
      const ownerPid = Number.parseInt(owner, 10);
      if (!Number.isInteger(ownerPid) || processExists(ownerPid)) {
        throw new Error(`remote session ${knownSessionId} is locked by another adapter`);
      }
      await unlink(leasePath).catch((error) => {
        if (error?.code !== "ENOENT") throw error;
      });
    }
  }
  throw new Error(`remote session ${knownSessionId} is locked by another adapter`);
}

async function releaseLease() {
  if (!lease) return;
  const handle = lease;
  lease = undefined;
  await handle.close();
  const owner = await readFile(leasePath, "utf8").catch(() => "");
  if (owner.trim() === leaseToken) {
    await unlink(leasePath).catch((error) => {
      if (error?.code !== "ENOENT") throw error;
    });
  }
}

async function closeRemote() {
  const connection = remote;
  remote = undefined;
  sessionId = undefined;
  if (connection) await connection.dispose().catch(() => {});
}

function processExists(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (failure) {
    return failure?.code === "EPERM";
  }
}

function promptText(value) {
  if (!Array.isArray(value)) throw new Error("prompt is not an array");
  return value.map((part) => {
    if (!part || typeof part !== "object" || part.type !== "text" || typeof part.text !== "string") throw new Error("only text ACP prompts are supported");
    return part.text;
  }).join("");
}

function lastAssistant(transcript = []) {
  return [...transcript].reverse().find((entry) => entry.type === "message" && entry.message?.role === "assistant")?.message;
}

function stopReason(assistant) {
  switch (assistant?.stopReason) {
    case "length": return "max_tokens";
    case "aborted": return "cancelled";
    case "error": return "refusal";
    default: return "end_turn";
  }
}

function result(id, value) {
  process.stdout.write(`${JSON.stringify({ jsonrpc: "2.0", id, result: value })}\n`);
}

function error(id, code, message) {
  process.stdout.write(`${JSON.stringify({ jsonrpc: "2.0", id, error: { code, message } })}\n`);
}

function notification(method, params) {
  process.stdout.write(`${JSON.stringify({ jsonrpc: "2.0", method, params })}\n`);
}
