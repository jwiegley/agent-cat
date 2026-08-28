#!/usr/bin/env node
import { existsSync } from "node:fs";
import { dirname, isAbsolute, join } from "node:path";
import { pathToFileURL } from "node:url";
import readline from "node:readline";

const packageParent = process.env.PI_PACKAGE_DIR ? dirname(process.env.PI_PACKAGE_DIR) : undefined;
const clientRoot = packageParent
  ? [
      join(packageParent, "pi-client"),
      join(packageParent, "client"),
      join(process.env.PI_PACKAGE_DIR, "node_modules/@earendil-works/pi-client"),
    ].find(existsSync)
  : undefined;
const clientModule = clientRoot ? pathToFileURL(join(clientRoot, "dist/index.js")).href : "@earendil-works/pi-client";
const unixModule = clientRoot ? pathToFileURL(join(clientRoot, "dist/unix.js")).href : "@earendil-works/pi-client/unix";
const [{ PiClient }, { createUnixTransportFactory }] = await Promise.all([import(clientModule), import(unixModule)]);

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
const client = new PiClient({ transportFactory: createUnixTransportFactory({ path: socketPath }) });
let remote;
let sessionId;
let activePromptId;
let connectedOnce = false;
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
  if (remote) await remote.dispose();
  await client.dispose();
}

async function handleControl(request) {
  const { id, method, params = {} } = request;
  if (method === "initialize") {
    result(id, { protocolVersion: 1, agentCapabilities: { loadSession: false, agentCat: { steer: true } }, agentInfo: { name: "pi-known-remote", version: "1" } });
  } else if (method === "session/new") {
    if (activePromptId !== undefined) throw new Error("cannot replace a session during an active prompt");
    if (remote) await remote.dispose();
    if (typeof params.cwd !== "string" || !isAbsolute(params.cwd)) throw new Error("session cwd must be absolute");
    if (!client.connected) {
      if (connectedOnce) await client.reconnect();
      else await client.connect();
      connectedOnce = true;
    }
    remote = await client.acquireSession(knownSessionId, { mode: "exclusive" });
    sessionId = remote.id;
    result(id, { sessionId });
  } else if (method === "session/steer") {
    const validTiming = params.timing === "interrupt-now" || params.timing === "next-boundary";
    let accepted = Boolean(remote && activePromptId !== undefined && params.sessionId === sessionId && typeof params.text === "string" && validTiming);
    if (accepted) {
      try {
        if (params.timing === "next-boundary") await remote.followUp(params.text);
        else await remote.steer(params.text);
      } catch {
        accepted = false;
      }
    }
    notification("session/steer_ack", { steerId: params.steerId, accepted });
  } else if (method === "session/cancel") {
    if (remote) await remote.abort();
  } else if (id !== undefined) {
    error(id, -32601, `unknown method ${method}`);
  }
}

async function handlePrompt(request) {
  const { id, params = {} } = request;
  if (!remote || params.sessionId !== sessionId) throw new Error("unknown session");
  if (activePromptId !== undefined) throw new Error("a prompt is already active");
  activePromptId = id;
  try {
    const snapshot = await remote.prompt(promptText(params.prompt));
    const assistant = lastAssistant(snapshot.transcript);
    const answer = assistant?.content.filter((part) => part.type === "text").map((part) => part.text).join("") ?? "";
    if (answer) notification("session/update", { sessionId, update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: answer } } });
    result(id, { stopReason: stopReason(assistant) });
  } finally {
    activePromptId = undefined;
  }
}

function promptText(value) {
  if (!Array.isArray(value)) throw new Error("prompt is not an array");
  return value.map((part) => {
    if (!part || typeof part !== "object" || part.type !== "text" || typeof part.text !== "string") throw new Error("only text ACP prompts are supported");
    return part.text;
  }).join("");
}
function lastAssistant(transcript) {
  return [...transcript].reverse().find((item) => item.role === "assistant");
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
