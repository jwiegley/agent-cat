import { readFileSync } from "node:fs";
import { createFauxCore, fauxAssistantMessage, fauxText, fauxToolCall, type AssistantMessage, type FauxContentBlock, type JsonObject, type Message } from "@earendil-works/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

/**
 * A Pi extension that registers a deterministic local provider for the host
 * checks of ext-pi. It makes no network request and needs no provider key.
 *
 * The variable `AGENT_CAT_FAUX_SCRIPT` names the script file. An empty file
 * gives fixed text replies: reply N is `agent-cat faux reply N`. Otherwise the
 * file holds a JSON array of replies, and Pi receives them in order, one for
 * each model call. A reply is one block or an array of blocks. A block is
 * `{"text": TEXT}` or `{"toolCall": {"name": NAME, "arguments": OBJECT}}`,
 * with an optional `id` in the tool call. A tool call can also hold
 * `"fromResult": {ARGUMENT: PATTERN}`. Each PATTERN is a regular expression
 * with one capture group. The provider searches the text of the tool results
 * of the context, from the newest to the oldest, and sets ARGUMENT to the
 * captured text of the first match. A model that reads an identifier, such
 * as a run identifier, from an earlier tool result does the same. A pattern
 * that matches no tool result is an error of the model call. A reply with a
 * tool call stops with `toolUse`. After the last scripted reply, the fixed
 * text replies continue.
 */
export const FAUX_PROVIDER = "agent-cat-faux";
export const FAUX_MODEL = "faux-1";
export const FAUX_SCRIPT_VARIABLE = "AGENT_CAT_FAUX_SCRIPT";
export const FAUX_FIXED_REPLY = "agent-cat faux reply";

/** One scripted block, with the arguments that a tool call reads from earlier tool results. */
type ScriptedBlock = { readonly block: FauxContentBlock; readonly fromResult: Readonly<Record<string, RegExp>> };
type ScriptedReply = ScriptedBlock[];

/** The replies of the script text. An empty text has no replies. */
export function parseFauxScript(text: string): ScriptedReply[] {
  if (text.trim() === "") return [];
  const parsed: unknown = JSON.parse(text);
  if (!Array.isArray(parsed)) throw new Error(`${FAUX_SCRIPT_VARIABLE} must hold a JSON array of replies`);
  return parsed.map((reply, index) => (Array.isArray(reply) ? reply : [reply]).map((block) => scriptBlock(block, index)));
}

function scriptBlock(block: unknown, index: number): ScriptedBlock {
  const where = `${FAUX_SCRIPT_VARIABLE} reply ${index + 1}`;
  if (typeof block !== "object" || block === null || Array.isArray(block)) throw new Error(`${where} has a block that is not an object`);
  const fields = block as Record<string, unknown>;
  const keys = Object.keys(fields);
  if (keys.length === 1 && typeof fields.text === "string") return { block: fauxText(fields.text), fromResult: {} };
  if (keys.length === 1 && typeof fields.toolCall === "object" && fields.toolCall !== null && !Array.isArray(fields.toolCall)) {
    const call = fields.toolCall as Record<string, unknown>;
    if (Object.keys(call).some((key) => !["name", "arguments", "id", "fromResult"].includes(key))) throw new Error(`${where} has a tool call with an unknown field`);
    if (typeof call.name !== "string" || call.name === "") throw new Error(`${where} has a tool call without a name`);
    if (typeof call.arguments !== "object" || call.arguments === null || Array.isArray(call.arguments)) throw new Error(`${where} has tool-call arguments that are not an object`);
    if (call.id !== undefined && typeof call.id !== "string") throw new Error(`${where} has a tool-call id that is not text`);
    const fromResult: Record<string, RegExp> = {};
    if (call.fromResult !== undefined) {
      if (typeof call.fromResult !== "object" || call.fromResult === null || Array.isArray(call.fromResult)) throw new Error(`${where} has a fromResult that is not an object`);
      for (const [argument, pattern] of Object.entries(call.fromResult)) {
        if (typeof pattern !== "string") throw new Error(`${where} has a fromResult pattern that is not text`);
        const expression = new RegExp(pattern);
        if (new RegExp(`${pattern}|`).exec("")!.length !== 2) throw new Error(`${where} has a fromResult pattern without exactly one capture group`);
        fromResult[argument] = expression;
      }
    }
    return { block: fauxToolCall(call.name, call.arguments as JsonObject, call.id === undefined ? {} : { id: call.id }), fromResult };
  }
  throw new Error(`${where} has a block that is neither {"text"} nor {"toolCall"}`);
}

/**
 * The text that a pattern captures from the newest tool result of the
 * messages that it matches.
 */
function capturedFromResults(messages: readonly Message[], argument: string, pattern: RegExp): string {
  for (const message of [...messages].reverse()) {
    if (message.role !== "toolResult") continue;
    const text = message.content.flatMap((part) => (part.type === "text" ? [part.text] : [])).join("\n");
    const match = pattern.exec(text);
    if (match !== null && match[1] !== undefined) return match[1];
  }
  throw new Error(`no tool result matches the fromResult pattern ${pattern.source} of the argument ${argument}`);
}

/**
 * The assistant message of model call `call` (from 1) of the script. The
 * arguments that a tool call reads with `fromResult` come from the tool
 * results of `messages`, the messages of the model context.
 */
export function fauxReply(script: readonly ScriptedReply[], call: number, messages: readonly Message[] = []): AssistantMessage {
  const scripted = script[call - 1];
  if (scripted === undefined) return fauxAssistantMessage(`${FAUX_FIXED_REPLY} ${call}`);
  const blocks = scripted.map(({ block, fromResult }) => {
    if (block.type !== "toolCall" || Object.keys(fromResult).length === 0) return block;
    const captured = Object.fromEntries(Object.entries(fromResult).map(([argument, pattern]) => [argument, capturedFromResults(messages, argument, pattern)]));
    return { ...block, arguments: { ...block.arguments, ...captured } };
  });
  return fauxAssistantMessage(blocks, { stopReason: blocks.some((block) => block.type === "toolCall") ? "toolUse" : "stop" });
}

export default function fauxModel(pi: ExtensionAPI): void {
  const path = process.env[FAUX_SCRIPT_VARIABLE];
  if (path === undefined || path === "") throw new Error(`${FAUX_SCRIPT_VARIABLE} must name the faux script file`);
  const script = parseFauxScript(readFileSync(path, "utf8"));
  const core = createFauxCore({ api: FAUX_PROVIDER, provider: FAUX_PROVIDER, models: [{ id: FAUX_MODEL, name: "agent-cat faux", input: ["text"] }] });
  let calls = 0;
  pi.registerProvider(FAUX_PROVIDER, {
    name: "agent-cat faux",
    baseUrl: "http://127.0.0.1:0",
    apiKey: "agent-cat-faux-local",
    api: core.api,
    streamSimple: (model, context, options) => {
      calls += 1;
      core.appendResponses([fauxReply(script, calls, context.messages)]);
      return core.streamSimple(model, context, options);
    },
    models: [{
      id: FAUX_MODEL,
      name: "agent-cat faux",
      reasoning: false,
      input: ["text"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: 128000,
      maxTokens: 16384,
    }],
  });
}
