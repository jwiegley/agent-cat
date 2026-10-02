/**
 * The fake Pi host of the live checks of service mode. It loads the
 * extension with a fake UI that answers each select, editor, input,
 * confirmation and custom component from the current `script`, and with a
 * transport that records each POST and delegates to `ManagerTransport`. The
 * live checks `test/manager-ui-live.test.ts` and
 * `test/manager-controls-live.test.ts` share it.
 */

import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import extension from "../../src/index.ts";
import { encodeJson, type JsonValue } from "../../src/manager/json.ts";
import type { ClientProfile } from "../../src/manager/profile.ts";
import type { SessionTransport } from "../../src/manager/session.ts";
import { ManagerTransport, type CommandHeaders, type TransportOptions } from "../../src/manager/transport.ts";
import type { Component } from "@earendil-works/pi-tui";

/** One POST of the extension: the resource, the exact body and the `If-Match` value. */
export type Post = { readonly resource: string; readonly body: string | Buffer; readonly ifMatch: string | null };

/** The scripted answers of the fake UI for one command. */
export type Script = {
  select?: (title: string, options: string[]) => string | undefined;
  editor?: (title: string, prefill: string | undefined) => Promise<string | undefined> | string | undefined;
  confirm?: (title: string, message: string) => boolean;
  input?: (title: string) => string | undefined;
  /** The key for a drawn component, or `undefined` to keep it open until its next drawing. */
  review?: (screen: string) => string | undefined;
};

/** The `agent_cat_workflow` tool as the extension registers it. */
export type LiveTool = {
  execute: (id: string, params: unknown, signal: unknown, update: unknown, ctx: unknown) => Promise<{ isError?: boolean; content: Array<{ text: string }> }>;
};

type Handler = (event: unknown, ctx: unknown) => Promise<unknown>;

/** A transport that records each POST and delegates to `ManagerTransport`. */
function recording(posts: Post[]): (profile: ClientProfile, options: TransportOptions) => SessionTransport {
  return (profile, options) => {
    const transport = new ManagerTransport(profile, options);
    return {
      get: (resource) => transport.get(resource),
      post: (resource: string, body: JsonValue, command: CommandHeaders) => {
        posts.push({ resource, body: encodeJson(body), ifMatch: command.ifMatch });
        return transport.post(resource, body, command);
      },
      postBytes: (resource: string, bytes: Uint8Array, command: CommandHeaders) => {
        posts.push({ resource, body: Buffer.from(bytes), ifMatch: command.ifMatch });
        return transport.postBytes(resource, bytes, command);
      },
      followEvents: (start, deliver, follow) => transport.followEvents(start, deliver, follow),
      pollEvents: (cursor) => transport.pollEvents(cursor),
      downloadVerified: (resource, size, sha256) => transport.downloadVerified(resource, size, sha256),
      dropStream: () => transport.dropStream(),
      close: () => transport.close(),
    };
  };
}

/**
 * The extension in service mode with the fake Pi host. `open` loads it with
 * a new local state directory, starts its session and waits for live
 * delivery. `close` ends its session, and `restore` restores the state
 * directory variable and removes the directory.
 */
export class LivePi {
  readonly posts: Post[] = [];
  readonly notices: string[] = [];
  readonly screens: string[] = [];
  readonly confirmations: string[] = [];
  readonly commands = new Map<string, { handler: (args: string, ctx: unknown) => Promise<void> }>();
  readonly events = new Map<string, Handler[]>();
  /** The answers of the fake UI for the next command. */
  script: Script = {};
  tool: LiveTool | undefined;
  /** The local state directory of the extension. */
  state = "";
  #previousState: string | undefined;

  readonly ctx = {
    cwd: "", mode: "tui", hasUI: true, isProjectTrusted: () => true,
    ui: {
      notify: (message: string) => this.notices.push(message),
      setWidget: () => {},
      setStatus: () => {},
      select: async (title: string, options: string[]) => {
        const chosen = this.script.select?.(title, options);
        if (chosen === undefined) throw new Error(`unexpected select ${title}: ${options.join(" | ")}`);
        return chosen;
      },
      editor: async (title: string, prefill?: string) => {
        if (this.script.editor === undefined) throw new Error(`unexpected editor ${title}`);
        return this.script.editor(title, prefill);
      },
      input: async (title: string) => {
        if (this.script.input === undefined) throw new Error(`unexpected input ${title}`);
        return this.script.input(title);
      },
      confirm: async (title: string, message: string) => {
        this.confirmations.push(`${title} ${message}`);
        if (this.script.confirm === undefined) throw new Error(`unexpected confirmation ${title}`);
        return this.script.confirm(title, message);
      },
      custom: <T>(factory: (tui: unknown, theme: unknown, keys: unknown, done: (value: T) => void) => unknown) =>
        new Promise<T>((resolve, reject) => {
          // Each drawing gives the screen to the script, which answers with a key or keeps the component open.
          let open = true;
          let component: Component | undefined;
          const show = () => {
            if (!open || component === undefined) return;
            const screen = component.render(120).join("\n");
            this.screens.push(screen);
            if (this.script.review === undefined) {
              open = false;
              return reject(new Error(`unexpected component: ${screen}`));
            }
            const key = this.script.review(screen);
            if (key !== undefined) component.handleInput?.(key);
          };
          const tui = { terminal: { rows: 400 }, requestRender: () => setImmediate(show) };
          const theme = { fg: (_color: string, value: string) => value };
          component = factory(tui, theme, {}, (value) => {
            open = false;
            resolve(value);
          }) as Component;
          show();
        }),
    },
  };

  /** Run one command of the extension with its arguments. */
  run(name: string, args = ""): Promise<void> {
    const command = this.commands.get(name);
    if (command === undefined) throw new Error(`the extension registers no command ${name}`);
    return command.handler(args, this.ctx);
  }

  /** The notification of `/wfm-status`. */
  async status(): Promise<string> {
    await this.run("wfm-status");
    return this.notices.at(-1) ?? "";
  }

  /** The POSTs to a resource after an index of `posts`. */
  postsTo(resource: string, from = 0): Post[] {
    return this.posts.slice(from).filter((post) => post.resource === resource);
  }

  /**
   * Load the extension with a new local state directory whose name starts
   * with `prefix`, start its session and wait at most `waitMs` milliseconds
   * until `/wfm-status` shows live delivery.
   */
  async open(prefix: string, waitMs: number): Promise<void> {
    this.state = mkdtempSync(join(tmpdir(), prefix));
    this.ctx.cwd = this.state;
    this.#previousState = process.env.AGENT_CAT_STATE_DIR;
    process.env.AGENT_CAT_STATE_DIR = this.state;
    extension({
      registerEntryRenderer: () => {}, registerTool: (definition: unknown) => { this.tool = definition as LiveTool; }, appendEntry: () => {}, sendUserMessage: () => {},
      registerCommand: (name: string, value: unknown) => this.commands.set(name, value as never),
      on: (name: string, handler: Handler) => this.events.set(name, [...(this.events.get(name) ?? []), handler]),
    } as never, { manager: { transport: recording(this.posts) } });
    await this.emit("session_start");
    const deadline = Date.now() + waitMs;
    while (!(await this.status()).includes("delivery live")) {
      if (Date.now() > deadline) throw new Error(`the extension did not connect: ${this.notices.at(-1)}`);
      await new Promise((wake) => setTimeout(wake, 100));
    }
  }

  /** End the session of the extension. */
  async close(): Promise<void> {
    await this.emit("session_shutdown");
  }

  /** Restore the state directory variable and remove the local state directory. */
  restore(): void {
    if (this.#previousState === undefined) delete process.env.AGENT_CAT_STATE_DIR;
    else process.env.AGENT_CAT_STATE_DIR = this.#previousState;
    if (this.state) rmSync(this.state, { recursive: true, force: true });
  }

  async emit(type: "session_start" | "session_shutdown"): Promise<void> {
    for (const handler of this.events.get(type) ?? []) await handler({ type }, this.ctx);
  }
}
