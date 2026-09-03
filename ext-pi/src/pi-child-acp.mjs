#!/usr/bin/env node
import { isAbsolute, join } from "node:path";
import { pathToFileURL } from "node:url";
import readline from "node:readline";

const codingAgentModule = process.env.PI_PACKAGE_DIR
  ? pathToFileURL(join(process.env.PI_PACKAGE_DIR, "dist/index.js")).href
  : "@earendil-works/pi-coding-agent";
const { createAgentSession, DefaultResourceLoader, getAgentDir, SessionManager, SettingsManager } = await import(codingAgentModule);

let session;
let sessionId;
let activePromptId;
const lines = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
const promptTasks = new Set();

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
    else process.stderr.write(`pi child ACP error: ${failure instanceof Error ? failure.message : String(failure)}\n`);
  }
}
await Promise.allSettled(promptTasks);
session?.dispose();

async function handleControl(request) {
  const { id, method, params = {} } = request;
  if (method === "initialize") {
    result(id, { protocolVersion: 1, agentCapabilities: { loadSession: false, agentCat: { steer: true } }, agentInfo: { name: "pi-owned-child", version: "1" } });
  } else if (method === "session/new") {
    if (activePromptId !== undefined) throw new Error("cannot replace a session during an active prompt");
    if (session) session.dispose();
    if (typeof params.cwd !== "string" || !isAbsolute(params.cwd)) throw new Error("session cwd must be absolute");
    const agentDir = getAgentDir();
    const settingsManager = SettingsManager.create(params.cwd, agentDir);
    const resourceLoader = new DefaultResourceLoader({ cwd: params.cwd, agentDir, settingsManager, noExtensions: true });
    await resourceLoader.reload();
    const created = await createAgentSession({ cwd: params.cwd, sessionManager: SessionManager.inMemory(params.cwd), settingsManager, resourceLoader, noTools: "all" });
    session = created.session;
    sessionId = crypto.randomUUID();
    result(id, { sessionId });
  } else if (method === "session/steer") {
    const validTiming = params.timing === "interrupt-now" || params.timing === "next-boundary";
    let accepted = Boolean(session && activePromptId !== undefined && params.sessionId === sessionId && typeof params.text === "string" && validTiming);
    if (accepted) {
      try { await deliverSteering({ timing: params.timing, text: params.text }); }
      catch { accepted = false; }
    }
    notification("session/steer_ack", { steerId: params.steerId, accepted });
  } else if (method === "session/cancel") {
    if (session) await session.abort();
  } else if (id !== undefined) {
    error(id, -32601, `unknown method ${method}`);
  }
}

async function handlePrompt(request) {
  const { id, params = {} } = request;
  if (!session || params.sessionId !== sessionId) throw new Error("unknown session");
  if (activePromptId !== undefined) throw new Error("a prompt is already active");
  activePromptId = id;
  try {
    await session.prompt(promptText(params.prompt), { expandPromptTemplates: false });
    const answer = session.getLastAssistantText() ?? "";
    if (answer) notification("session/update", { sessionId, update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: answer } } });
    result(id, { stopReason: stopReason(session.messages) });
  } finally {
    activePromptId = undefined;
  }
}

async function deliverSteering(steering) {
  if (steering.timing === "next-boundary") await session.followUp(steering.text);
  else await session.steer(steering.text);
}

function promptText(value) {
  if (!Array.isArray(value)) throw new Error("prompt is not an array");
  return value.map((part) => {
    if (!part || typeof part !== "object" || part.type !== "text" || typeof part.text !== "string") throw new Error("only text ACP prompts are supported");
    return part.text;
  }).join("");
}

function stopReason(messages) {
  const assistant = [...messages].reverse().find((message) => message.role === "assistant");
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
