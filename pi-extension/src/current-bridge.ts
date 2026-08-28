import { randomBytes, randomUUID, timingSafeEqual } from "node:crypto";
import { mkdir, rm, writeFile } from "node:fs/promises";
import net, { type Server, type Socket } from "node:net";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

const MAX_FRAME = 1024 * 1024;

type TaskTurnHandle = {
  id: string;
  completed: Promise<{ id: string; messages: readonly unknown[] }>;
  steer(text: string): Promise<void>;
  followUp(text: string): Promise<void>;
  abort(): Promise<void>;
};

type Pending = { socket: Socket; id: unknown; sessionId: string; turn: TaskTurnHandle };

export class CurrentSessionBridge {
  readonly #pi: ExtensionAPI;
  readonly #context: () => ExtensionContext | undefined;
  #server?: Server;
  #socketPath?: string;
  #tokenFile?: string;
  #token?: Buffer;
  #client?: Socket;
  #pending?: Pending;
  #sessionId?: string;

  get supported(): boolean {
    return typeof (this.#pi as ExtensionAPI & { startTaskTurn?: unknown }).startTaskTurn === "function";
  }

  constructor(pi: ExtensionAPI, context: () => ExtensionContext | undefined) {
    this.#pi = pi;
    this.#context = context;
  }

  get busy(): boolean {
    return this.#client !== undefined || this.#pending !== undefined;
  }

  async start(stateDir: string): Promise<void> {
    if (!this.supported || this.#server) return;
    const directory = join(stateDir, "bridge");
    await mkdir(directory, { recursive: true, mode: 0o700 });
    const instance = `${process.pid}-${randomUUID()}`;
    this.#socketPath = join(directory, `current-${instance}.sock`);
    this.#tokenFile = join(directory, `current-${instance}.token`);
    this.#token = randomBytes(32);
    await writeFile(this.#tokenFile, this.#token.toString("hex"), { mode: 0o600, flag: "wx" });
    this.#server = net.createServer((socket) => this.#accept(socket));
    await new Promise<void>((resolve, reject) => {
      this.#server!.once("error", reject);
      this.#server!.listen(this.#socketPath, () => {
        this.#server!.off("error", reject);
        resolve();
      });
    });
  }

  target(): { args: string[]; env: NodeJS.ProcessEnv } {
    if (!this.supported) throw new Error("current-session workflows require Pi ExtensionAPI.startTaskTurn");
    if (!this.#server || !this.#socketPath || !this.#tokenFile) throw new Error("current-session bridge is not started");
    const proxy = fileURLToPath(new URL("./acp-proxy.mjs", import.meta.url));
    return {
      args: ["--engine", "acp", "--adapter", process.execPath, "--adapter-arg", proxy],
      env: { AGENT_CAT_PI_BRIDGE_SOCKET: this.#socketPath, AGENT_CAT_PI_BRIDGE_TOKEN_FILE: this.#tokenFile },
    };
  }


  async close(): Promise<void> {
    if (this.#pending) void this.#pending.turn.abort();
    this.#client?.destroy();
    if (this.#server) await new Promise<void>((resolve) => this.#server!.close(() => resolve()));
    this.#server = undefined;
    await Promise.all([this.#socketPath ? rm(this.#socketPath, { force: true }) : Promise.resolve(), this.#tokenFile ? rm(this.#tokenFile, { force: true }) : Promise.resolve()]);
  }

  #accept(socket: Socket): void {
    if (this.#client) {
      socket.destroy();
      return;
    }
    let buffer = "";
    let authenticated = false;
    socket.setEncoding("utf8");
    socket.on("data", (chunk: string) => {
      buffer += chunk;
      if (buffer.length > MAX_FRAME * 2) return socket.destroy(new Error("ACP bridge frame exceeded limit"));
      for (;;) {
        const newline = buffer.indexOf("\n");
        if (newline < 0) break;
        const line = buffer.slice(0, newline);
        buffer = buffer.slice(newline + 1);
        if (Buffer.byteLength(line) > MAX_FRAME) return socket.destroy(new Error("ACP bridge frame exceeded limit"));
        try {
          const message: unknown = JSON.parse(line);
          if (!authenticated) {
            if (!this.#authenticate(message)) return socket.destroy(new Error("ACP bridge authentication failed"));
            authenticated = true;
            this.#client = socket;
          } else {
            this.#message(socket, message);
          }
        } catch (error) {
          socket.destroy(error instanceof Error ? error : new Error(String(error)));
        }
      }
    });
    socket.on("close", () => {
      if (this.#client === socket) {
        this.#client = undefined;
        this.#sessionId = undefined;
      }
      if (this.#pending?.socket === socket) {
        const pending = this.#pending;
        this.#pending = undefined;
        void pending.turn.abort();
      }
    });
  }

  #authenticate(message: unknown): boolean {
    if (!isObject(message) || typeof message.token !== "string" || !this.#token) return false;
    const candidate = Buffer.from(message.token, "hex");
    return candidate.length === this.#token.length && timingSafeEqual(candidate, this.#token);
  }

  #message(socket: Socket, value: unknown): void {
    if (!isObject(value) || typeof value.method !== "string") throw new Error("invalid ACP message");
    const id = value.id;
    const params = isObject(value.params) ? value.params : {};
    switch (value.method) {
      case "initialize":
        return send(socket, { jsonrpc: "2.0", id, result: { protocolVersion: 1, agentCapabilities: { loadSession: false, agentCat: { steer: true } }, agentInfo: { name: "pi-current-session", version: "1" } } });
      case "session/new": {
        this.#sessionId = `current-${randomUUID()}`;
        return send(socket, { jsonrpc: "2.0", id, result: { sessionId: this.#sessionId } });
      }
      case "session/prompt": {
        if (this.#pending) return rpcError(socket, id, -32000, "current Pi session is already answering");
        const context = this.#context();
        if (!context?.isIdle()) return rpcError(socket, id, -32000, "current Pi session is not idle");
        const sessionId = text(params.sessionId, "sessionId");
        if (sessionId !== this.#sessionId) return rpcError(socket, id, -32000, "unknown current Pi session");
        const prompt = promptText(params.prompt);
        try {
          const turn = (this.#pi as ExtensionAPI & { startTaskTurn(content: string, options?: { expandPromptTemplates?: boolean }): TaskTurnHandle }).startTaskTurn(prompt, { expandPromptTemplates: false });
          const pending = { socket, id, sessionId, turn };
          this.#pending = pending;
          void turn.completed
            .then((result) => { if (this.#pending === pending) this.#completeTurn(pending, result.messages); })
            .catch((error) => {
              if (this.#pending === pending) {
                this.#pending = undefined;
                rpcError(socket, id, -32000, error instanceof Error ? error.message : String(error));
              }
            });
        } catch (error) {
          rpcError(socket, id, -32000, error instanceof Error ? error.message : String(error));
        }
        return;
      }
      case "session/steer": {
        const steerId = text(params.steerId, "steerId");
        const timing = text(params.timing, "timing");
        const steeringText = text(params.text, "text");
        const pending = this.#pending;
        const validTiming = timing === "interrupt-now" || timing === "next-boundary";
        const accepted = params.sessionId === this.#sessionId && Boolean(pending) && validTiming;
        if (!accepted || !pending) {
          send(socket, { jsonrpc: "2.0", method: "session/steer_ack", params: { steerId, accepted: false } });
        } else {
          const delivery = timing === "next-boundary" ? pending.turn.followUp(steeringText) : pending.turn.steer(steeringText);
          void delivery.then(
            () => send(socket, { jsonrpc: "2.0", method: "session/steer_ack", params: { steerId, accepted: true } }),
            () => send(socket, { jsonrpc: "2.0", method: "session/steer_ack", params: { steerId, accepted: false } }),
          );
        }
        return;
      }
      case "session/cancel":
        if (this.#pending) void this.#pending.turn.abort();
        return;
      default:
        if (id !== undefined) rpcError(socket, id, -32601, `unknown method ${value.method}`);
    }
  }

  #completeTurn(pending: Pending, messages: readonly unknown[]): void {
    this.#pending = undefined;
    const answer = assistantResult(messages);
    if (answer.text) {
      send(pending.socket, {
        jsonrpc: "2.0", method: "session/update",
        params: { sessionId: pending.sessionId, update: { sessionUpdate: "agent_message_chunk", content: { type: "text", text: answer.text } } },
      });
    }
    send(pending.socket, { jsonrpc: "2.0", id: pending.id, result: { stopReason: answer.stopReason } });
  }
}

function send(socket: Socket, value: unknown): void {
  socket.write(`${JSON.stringify(value)}\n`);
}

function rpcError(socket: Socket, id: unknown, code: number, message: string): void {
  send(socket, { jsonrpc: "2.0", id, error: { code, message } });
}

function promptText(value: unknown): string {
  if (!Array.isArray(value)) throw new Error("prompt is not an array");
  return value.map((part) => {
    if (!isObject(part) || part.type !== "text" || typeof part.text !== "string") throw new Error("only text ACP prompts are supported");
    return part.text;
  }).join("");
}

function assistantResult(messages: readonly unknown[]): { text: string; stopReason: "end_turn" | "max_tokens" | "cancelled" | "refusal" } {
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    const message = messages[index];
    if (!isObject(message) || message.role !== "assistant" || !Array.isArray(message.content)) continue;
    const text = message.content.filter((part) => isObject(part) && part.type === "text" && typeof part.text === "string").map((part) => String(part.text)).join("");
    const reason = message.stopReason ?? message.status;
    if (reason === "length") return { text, stopReason: "max_tokens" };
    if (reason === "aborted") return { text, stopReason: "cancelled" };
    if (reason === "error") return { text, stopReason: "refusal" };
    return { text, stopReason: "end_turn" };
  }
  return { text: "", stopReason: "refusal" };
}

function text(value: unknown, field: string): string {
  if (typeof value !== "string") throw new Error(`${field} is not text`);
  return value;
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
