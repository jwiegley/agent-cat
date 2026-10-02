import { createHash } from "node:crypto";
import { access, mkdir, mkdtemp, readFile, readdir, rm, stat, utimes, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { readFileSync } from "node:fs";
import { afterAll, afterEach, beforeAll, describe, expect, it } from "vitest";
import { Value } from "typebox/value";
import extension, { parseWorkflowCommand } from "../src/index.ts";
import { isJsonObject, jsonMember, parseJson, type JsonValue } from "../src/manager/json.ts";
import { requiredScopes, type Operation } from "../src/manager/resources.ts";
import { MANAGER_ROLE_MARKER, ROOT_ROLE_FILE } from "../src/root-role.ts";
import {
  capabilities, clientProfiles, control, decision, manager, ok, run, transports, type Reply,
} from "./fixtures/fake-manager.ts";

const created: string[] = [];
afterEach(async () => Promise.all(created.splice(0).map((path) => rm(path, { recursive: true, force: true }))));

describe("Pi extension lifecycle", () => {
  it("launches selected and named /wf runs in the current Agent Deck session", async () => {
    const directory = await mkdtemp(join(tmpdir(), "agent-cat-extension-ui-"));
    created.push(directory);
    const previousRunner = process.env.AGENT_CAT_RUNNER;
    const previousState = process.env.AGENT_CAT_STATE_DIR;
    const previousDeckSession = process.env.AGENTDECK_INSTANCE_ID;
    process.env.AGENT_CAT_RUNNER = resolve("test/fixtures/runner.mjs");
    process.env.AGENT_CAT_STATE_DIR = join(directory, "state");
    process.env.AGENTDECK_INSTANCE_ID = "current-deck-session";
    try {
      const commands = new Map<string, { handler: (args: string, ctx: unknown) => Promise<void> }>();
      const events = new Map<string, Array<(event: unknown, ctx: unknown) => Promise<unknown>>>();
      const entries: Array<{ type: string; data: unknown }> = [];
      const widgets: unknown[] = [];
      const pi = {
        registerEntryRenderer: () => {},
        registerCommand: (name: string, command: unknown) => commands.set(name, command as never),
        registerTool: () => {},
        on: (name: string, handler: (event: unknown, ctx: unknown) => Promise<unknown>) => events.set(name, [...(events.get(name) ?? []), handler]),
        appendEntry: (type: string, data: unknown) => entries.push({ type, data }),
        sendUserMessage: () => {},
      };
      extension(pi as never);
      let workflowSelections = 0;
      const ui = {
        select: async (title: string, choices: string[]) => {
          if (title !== "agent-cat workflows") throw new Error(`unexpected selector: ${title}`);
          workflowSelections += 1;
          return choices[0];
        },
        editor: async () => "subject",
        confirm: async () => true,
        notify: () => {},
        setWidget: (_id: string, value: unknown) => widgets.push(value),
        setStatus: () => {},
        custom: async () => undefined,
      };
      const ctx = { cwd: directory, mode: "tui", hasUI: true, isProjectTrusted: () => true, ui, isIdle: () => true, abort: () => {}, sessionManager: { getBranch: () => [] } };
      for (const handler of events.get("session_start") ?? []) await handler({ type: "session_start" }, ctx);
      await commands.get("wf")!.handler("", ctx);
      await until(() => entries.length === 1);
      await commands.get("wf")!.handler("fixture", ctx);
      await until(() => entries.length === 2);
      expect(workflowSelections).toBe(1);
      for (const entry of entries) {
        expect(entry).toEqual({ type: "agent-cat-run", data: expect.objectContaining({ status: "succeeded", billFresh: "1", billMemo: "1", storeDir: expect.stringContaining("/runs/") }) });
      }
      const runIds = await readdir(join(directory, "state", "runs"));
      expect(runIds).toHaveLength(2);
      for (const runId of runIds) {
        const manifest = JSON.parse(await readFile(join(directory, "state", "runs", runId, "supervisor-manifest.json"), "utf8"));
        expect(manifest).toMatchObject({ targetKind: "deck", targetArgs: ["--session", "current-deck-session"] });
      }
      expect(widgets.some((value) => typeof value === "function")).toBe(true);
      await until(() => widgets.at(-1) === undefined);
      for (const handler of events.get("session_shutdown") ?? []) await handler({ type: "session_shutdown" }, ctx);
    } finally {
      if (previousRunner === undefined) delete process.env.AGENT_CAT_RUNNER;
      else process.env.AGENT_CAT_RUNNER = previousRunner;
      if (previousState === undefined) delete process.env.AGENT_CAT_STATE_DIR;
      else process.env.AGENT_CAT_STATE_DIR = previousState;
      if (previousDeckSession === undefined) delete process.env.AGENTDECK_INSTANCE_ID;
      else process.env.AGENTDECK_INSTANCE_ID = previousDeckSession;
    }
  });

  it("refuses session start against a manager root before the bridge or retention writes", async () => {
    const directory = await mkdtemp(join(tmpdir(), "agent-cat-extension-manager-root-"));
    created.push(directory);
    const managerRoot = join(directory, "manager");
    await mkdir(join(managerRoot, "runs", "partial"), { recursive: true, mode: 0o700 });
    await writeFile(join(managerRoot, ROOT_ROLE_FILE), MANAGER_ROLE_MARKER, { mode: 0o600 });
    const stale = new Date(Date.now() - 400 * 86_400_000);
    await utimes(join(managerRoot, "runs", "partial"), stale, stale);
    const previousState = process.env.AGENT_CAT_STATE_DIR;
    process.env.AGENT_CAT_STATE_DIR = managerRoot;
    try {
      const events = new Map<string, Array<(event: unknown, ctx: unknown) => Promise<unknown>>>();
      extension({
        registerEntryRenderer: () => {}, registerTool: () => {}, registerCommand: () => {}, appendEntry: () => {}, sendUserMessage: () => {},
        startTaskTurn: async () => {},
        on: (name: string, handler: (event: unknown, ctx: unknown) => Promise<unknown>) => events.set(name, [...(events.get(name) ?? []), handler]),
      } as never);
      const ctx = { cwd: directory, mode: "tui", hasUI: true, ui: { notify: () => {}, setWidget: () => {}, setStatus: () => {} } };
      const [start] = events.get("session_start") ?? [];
      await expect(start!({}, ctx)).rejects.toThrow("is a manager state root");
      expect((await readdir(managerRoot)).sort()).toEqual([ROOT_ROLE_FILE, "runs"]);
      expect(await readdir(join(managerRoot, "runs"))).toEqual(["partial"]);
    } finally {
      if (previousState === undefined) delete process.env.AGENT_CAT_STATE_DIR;
      else process.env.AGENT_CAT_STATE_DIR = previousState;
    }
  });

  it("parses raw command-tail and leading-trimmed multiline input", () => {
    expect(parseWorkflowCommand("  agent-cat:review Scope  with spaces  \r\n\n\t  Body line\n  indented\n")).toEqual({
      workflow: "agent-cat:review",
      commandTail: "Scope  with spaces  ",
      body: "Body line\n  indented\n",
    });
    expect(parseWorkflowCommand("")).toEqual({});
    expect(() => parseWorkflowCommand("\n  body")).toThrow("requires a workflow name");
  });

  it("binds multiline /wf sources and prompts only unbound inputs", async () => {
    const directory = await mkdtemp(join(tmpdir(), "agent-cat-extension-sources-"));
    created.push(directory);
    const previousRunner = process.env.AGENT_CAT_RUNNER;
    const previousRunners = process.env.AGENT_CAT_RUNNERS;
    const previousState = process.env.AGENT_CAT_STATE_DIR;
    const previousDeckSession = process.env.AGENTDECK_INSTANCE_ID;
    delete process.env.AGENT_CAT_RUNNER;
    process.env.AGENT_CAT_RUNNERS = JSON.stringify([{
      id: "agent-cat", executable: resolve("test/fixtures/runner.mjs"),
      prefixArgs: ["--descriptor-sources"], allowedCwds: [directory],
    }]);
    process.env.AGENT_CAT_STATE_DIR = join(directory, "state");
    process.env.AGENTDECK_INSTANCE_ID = "current-deck-session";
    try {
      const commands = new Map<string, { handler: (args: string, ctx: unknown) => Promise<void> }>();
      const events = new Map<string, Array<(event: unknown, ctx: unknown) => Promise<unknown>>>();
      const entries: unknown[] = [];
      const prompts: string[] = [];
      const confirmations: string[] = [];
      let approve = true;
      extension({
        registerEntryRenderer: () => {}, registerTool: () => {}, sendUserMessage: () => {},
        registerCommand: (name: string, command: unknown) => commands.set(name, command as never),
        appendEntry: (_type: string, data: unknown) => entries.push(data),
        on: (name: string, handler: (event: unknown, ctx: unknown) => Promise<unknown>) => events.set(name, [...(events.get(name) ?? []), handler]),
      } as never);
      const ui = {
        select: () => { throw new Error("named /wf must not open selector"); },
        editor: async (title: string) => { prompts.push(title); return `prompted:${title}`; },
        confirm: async (_title: string, message: string) => { confirmations.push(message); return approve; },
        notify: () => {}, setWidget: () => {}, setStatus: () => {}, custom: async () => undefined,
      };
      const ctx = { cwd: directory, mode: "tui", hasUI: true, isProjectTrusted: () => true, ui, isIdle: () => true, abort: () => {}, sessionManager: { getBranch: () => [] } };
      for (const handler of events.get("session_start") ?? []) await handler({}, ctx);
      const tail = "Scope of  review  ";
      const body = "Body\n  indented\n";
      await commands.get("wf")!.handler(`review ${tail}\n\n \t${body}`, ctx);
      await until(() => entries.length === 1);
      expect(prompts).toEqual(["Input: tone"]);
      const [runId] = await readdir(join(directory, "state", "runs"));
      const manifestText = await readFile(join(directory, "state", "runs", runId, "supervisor-manifest.json"), "utf8");
      const manifest = JSON.parse(manifestText);
      const hash = (value: string) => createHash("sha256").update(value).digest("hex");
      expect(manifest).toMatchObject({
        workflow: "review", targetKind: "deck", targetArgs: ["--session", "current-deck-session"],
        inputHashes: { args: hash(tail), input: hash(body), tone: hash("prompted:Input: tone") },
      });
      expect(manifestText).not.toContain(tail);
      expect(manifestText).not.toContain(body);
      expect(confirmations[0]).not.toContain(tail);
      expect(confirmations[0]).not.toContain(body);

      prompts.length = 0;
      approve = false;
      await commands.get("wf")!.handler("review", ctx);
      expect(prompts).toEqual(["Input: args", "Input: input", "Input: tone"]);
      expect(await readdir(join(directory, "state", "runs"))).toEqual([runId]);
      for (const handler of events.get("session_shutdown") ?? []) await handler({}, ctx);
    } finally {
      if (previousRunner === undefined) delete process.env.AGENT_CAT_RUNNER; else process.env.AGENT_CAT_RUNNER = previousRunner;
      if (previousRunners === undefined) delete process.env.AGENT_CAT_RUNNERS; else process.env.AGENT_CAT_RUNNERS = previousRunners;
      if (previousState === undefined) delete process.env.AGENT_CAT_STATE_DIR; else process.env.AGENT_CAT_STATE_DIR = previousState;
      if (previousDeckSession === undefined) delete process.env.AGENTDECK_INSTANCE_ID; else process.env.AGENTDECK_INSTANCE_ID = previousDeckSession;
    }
  });

  it("rejects undeclared /wf tail and body before prompts, confirmation, or run state", async () => {
    const directory = await mkdtemp(join(tmpdir(), "agent-cat-extension-source-refusal-"));
    created.push(directory);
    const previousRunner = process.env.AGENT_CAT_RUNNER;
    const previousRunners = process.env.AGENT_CAT_RUNNERS;
    const previousState = process.env.AGENT_CAT_STATE_DIR;
    const previousDeckSession = process.env.AGENTDECK_INSTANCE_ID;
    process.env.AGENT_CAT_RUNNER = resolve("test/fixtures/runner.mjs");
    delete process.env.AGENT_CAT_RUNNERS;
    process.env.AGENT_CAT_STATE_DIR = join(directory, "state");
    process.env.AGENTDECK_INSTANCE_ID = "current-deck-session";
    try {
      const commands = new Map<string, { handler: (args: string, ctx: unknown) => Promise<void> }>();
      const notices: string[] = [];
      extension({
        registerEntryRenderer: () => {}, registerTool: () => {}, on: () => {}, appendEntry: () => {}, sendUserMessage: () => {},
        registerCommand: (name: string, command: unknown) => commands.set(name, command as never),
      } as never);
      const ctx = {
        cwd: directory, mode: "tui", hasUI: true, isProjectTrusted: () => true,
        ui: {
          notify: (message: string) => notices.push(message),
          select: () => { throw new Error("must not select"); },
          editor: () => { throw new Error("must not prompt"); },
          confirm: () => { throw new Error("must not confirm"); },
        },
      };
      await commands.get("wf")!.handler("fixture unexpected tail", ctx);
      expect(notices.pop()).toContain("no command-tail input");
      await commands.get("wf")!.handler("fixture\n\n  private body", ctx);
      expect(notices.pop()).toContain("no standard-input declaration");
      await expect(access(join(directory, "state", "runs"))).rejects.toThrow();
    } finally {
      if (previousRunner === undefined) delete process.env.AGENT_CAT_RUNNER; else process.env.AGENT_CAT_RUNNER = previousRunner;
      if (previousRunners === undefined) delete process.env.AGENT_CAT_RUNNERS; else process.env.AGENT_CAT_RUNNERS = previousRunners;
      if (previousState === undefined) delete process.env.AGENT_CAT_STATE_DIR; else process.env.AGENT_CAT_STATE_DIR = previousState;
      if (previousDeckSession === undefined) delete process.env.AGENTDECK_INSTANCE_ID; else process.env.AGENTDECK_INSTANCE_ID = previousDeckSession;
    }
  });

  it.each(["wf", "wf-launch"])("refuses /%s launches without interactive approval or project trust", async (command) => {
    const commands = new Map<string, { handler: (args: string, ctx: unknown) => Promise<void> }>();
    extension({
      registerEntryRenderer: () => {}, registerTool: () => {}, on: () => {}, appendEntry: () => {}, sendUserMessage: () => {},
      registerCommand: (name: string, command: unknown) => commands.set(name, command as never),
    } as never);
    const notices: string[] = [];
    const ctx = {
      hasUI: false, cwd: "/work", mode: "print",
      ui: { notify: (message: string) => notices.push(message), select: () => { throw new Error("must not prompt"); } },
    };
    await commands.get(command)!.handler("agent-cat:fixture", ctx);
    expect(notices).toEqual([expect.stringContaining(`/${command} requires interactive approval`)]);
    notices.length = 0;
    await commands.get(command)!.handler("agent-cat:fixture", {
      ...ctx, hasUI: true, isProjectTrusted: () => false,
    });
    expect(notices).toEqual([expect.stringContaining(`/${command} requires a trusted project`)]);
  });

  it("refuses /wf outside a current Agent Deck session", async () => {
    const previousDeckSession = process.env.AGENTDECK_INSTANCE_ID;
    delete process.env.AGENTDECK_INSTANCE_ID;
    try {
      const commands = new Map<string, { handler: (args: string, ctx: unknown) => Promise<void> }>();
      extension({
        registerEntryRenderer: () => {}, registerTool: () => {}, on: () => {}, appendEntry: () => {}, sendUserMessage: () => {},
        registerCommand: (name: string, command: unknown) => commands.set(name, command as never),
      } as never);
      const notices: string[] = [];
      await commands.get("wf")!.handler("fixture", {
        hasUI: true, cwd: "/work", mode: "tui", isProjectTrusted: () => true,
        ui: { notify: (message: string) => notices.push(message), select: () => { throw new Error("must not prompt"); } },
      });
      expect(notices).toEqual([expect.stringContaining("AGENTDECK_INSTANCE_ID is unavailable")]);
    } finally {
      if (previousDeckSession === undefined) delete process.env.AGENTDECK_INSTANCE_ID;
      else process.env.AGENTDECK_INSTANCE_ID = previousDeckSession;
    }
  });

  it.each(["print", "json", "rpc"] as const)("degrades safely in %s mode", async (mode) => {
    const commands = new Map<string, { handler: (args: string, ctx: unknown) => Promise<void> }>();
    const previousRunner = process.env.AGENT_CAT_RUNNER;
    process.env.AGENT_CAT_RUNNER = resolve("test/fixtures/runner.mjs");
    try {
      extension({
        registerEntryRenderer: () => {}, registerTool: () => {}, on: () => {}, appendEntry: () => {}, sendUserMessage: () => {},
        registerCommand: (name: string, command: unknown) => commands.set(name, command as never),
      } as never);
      const notices: string[] = [];
      const ctx = { hasUI: false, cwd: process.cwd(), mode, ui: { notify: (message: string) => notices.push(message) } };
      expect([...commands.keys()].sort()).toEqual([
        "wf", "wf-cancel", "wf-diff", "wf-fork", "wf-help", "wf-launch", "wf-monitor",
        "wf-plan", "wf-recover", "wf-redirect", "wf-restart", "wf-resume", "wf-retry", "wf-status", "wf-steer",
        "wfm", "wfm-answer", "wfm-cancel", "wfm-discard", "wfm-endpoints", "wfm-export", "wfm-fork", "wfm-history", "wfm-monitor",
        "wfm-redirect", "wfm-restart", "wfm-result", "wfm-resume", "wfm-review", "wfm-status", "wfm-steer", "wfm-withdraw",
      ]);
      await commands.get("wf")!.handler("fixture", ctx);
      expect(notices.at(-1)).toContain("requires interactive approval");
      for (const name of ["wfm", "wfm-review", "wfm-withdraw", "wfm-discard", "wfm-monitor", "wfm-answer", "wfm-cancel", "wfm-steer", "wfm-redirect",
        "wfm-result", "wfm-history", "wfm-restart", "wfm-resume", "wfm-fork", "wfm-export"]) {
        await commands.get(name)!.handler("", ctx);
        expect(notices.at(-1)).toContain("Service mode is not configured");
      }
      await commands.get("wf-status")!.handler("", ctx);
      expect(notices.at(-1)).toBe("Mode: local\nNo active workflow runs");
      process.env.AGENT_CAT_MANAGER_PROFILES = '["/profiles/first.json","/profiles/second.json"]';
      await commands.get("wf-status")!.handler("", ctx);
      expect(notices.at(-1)).toBe("Mode: service with 2 manager profiles. Current-session, owned-child, deck, ACP, and remote Pi targets stay local.\nNo active workflow runs");
      delete process.env.AGENT_CAT_MANAGER_PROFILES;
      await commands.get("wf-launch")!.handler("agent-cat:fixture", ctx);
      expect(notices.at(-1)).toContain("requires interactive approval");
    } finally {
      if (previousRunner === undefined) delete process.env.AGENT_CAT_RUNNER; else process.env.AGENT_CAT_RUNNER = previousRunner;
      delete process.env.AGENT_CAT_MANAGER_PROFILES;
    }
  });

  it("builds native ACP argv and validates descriptor-pin routes without a shell", async () => {
    const directory = await mkdtemp(join(tmpdir(), "agent-cat-extension-acp-"));
    created.push(directory);
    const previousRunner = process.env.AGENT_CAT_RUNNER;
    const previousState = process.env.AGENT_CAT_STATE_DIR;
    process.env.AGENT_CAT_RUNNER = resolve("test/fixtures/runner.mjs");
    process.env.AGENT_CAT_STATE_DIR = join(directory, "state");
    try {
      const commands = new Map<string, { handler: (args: string, ctx: unknown) => Promise<void> }>();
      const events = new Map<string, Array<(event: unknown, ctx: unknown) => Promise<unknown>>>();
      const entries: unknown[] = [];
      extension({
        registerEntryRenderer: () => {}, registerTool: () => {}, appendEntry: (_type: string, data: unknown) => entries.push(data), sendUserMessage: () => {},
        registerCommand: (name: string, command: unknown) => commands.set(name, command as never),
        on: (name: string, handler: (event: unknown, ctx: unknown) => Promise<unknown>) => events.set(name, [...(events.get(name) ?? []), handler]),
      } as never);
      const ui = {
        select: async (title: string) => title === "Execution target" ? "native ACP adapter (live, agent-cat scratch)" : undefined,
        input: async (title: string) => title.startsWith("ACP adapter") ? "/trusted/adapter" : title.startsWith("Backend for worker") ? "deck:worker-pane" : undefined,
        editor: async (title: string) => title.startsWith("Adapter argv") ? '["--flag","literal;$(no-shell)"]' : "subject",
        confirm: async () => true, notify: () => {}, setWidget: () => {}, setStatus: () => {}, custom: async () => undefined,
      };
      const ctx = { cwd: directory, mode: "tui", hasUI: true, isProjectTrusted: () => true, ui, isIdle: () => true, abort: () => {}, sessionManager: { getBranch: () => [] } };
      for (const handler of events.get("session_start") ?? []) await handler({}, ctx);
      await commands.get("wf-launch")!.handler("agent-cat:fixture", ctx);
      await until(() => entries.length === 1);
      const [runId] = await readdir(join(directory, "state", "runs"));
      const manifest = JSON.parse(await readFile(join(directory, "state", "runs", runId, "supervisor-manifest.json"), "utf8"));
      expect(manifest.targetKind).toBe("acp");
      expect(manifest.targetArgs).toEqual(["--engine", "acp", "--adapter", "/trusted/adapter", "--adapter-arg", "--flag", "--adapter-arg", "literal;$(no-shell)", "--route", "worker=deck:worker-pane"]);
      for (const handler of events.get("session_shutdown") ?? []) await handler({}, ctx);
    } finally {
      if (previousRunner === undefined) delete process.env.AGENT_CAT_RUNNER; else process.env.AGENT_CAT_RUNNER = previousRunner;
      if (previousState === undefined) delete process.env.AGENT_CAT_STATE_DIR; else process.env.AGENT_CAT_STATE_DIR = previousState;
    }
  });

  it("uses descriptor-v3 sanitized routing choices in a routing-only launch", async () => {
    const directory = await mkdtemp(join(tmpdir(), "agent-cat-extension-routing-v3-"));
    created.push(directory);
    const previousRunner = process.env.AGENT_CAT_RUNNER;
    const previousRunners = process.env.AGENT_CAT_RUNNERS;
    const previousState = process.env.AGENT_CAT_STATE_DIR;
    delete process.env.AGENT_CAT_RUNNER;
    process.env.AGENT_CAT_RUNNERS = JSON.stringify([{
      id: "agent-cat", executable: resolve("test/fixtures/runner.mjs"),
      prefixArgs: ["--descriptor-v3"], allowedCwds: [directory],
    }]);
    process.env.AGENT_CAT_STATE_DIR = join(directory, "state");
    try {
      const commands = new Map<string, { handler: (args: string, ctx: unknown) => Promise<void> }>();
      const events = new Map<string, Array<(event: unknown, ctx: unknown) => Promise<unknown>>>();
      const entries: unknown[] = [];
      const selectors: string[] = [];
      const confirmations: string[] = [];
      extension({
        registerEntryRenderer: () => {}, registerTool: () => {}, sendUserMessage: () => {},
        registerCommand: (name: string, command: unknown) => commands.set(name, command as never),
        appendEntry: (_type: string, data: unknown) => entries.push(data),
        on: (name: string, handler: (event: unknown, ctx: unknown) => Promise<unknown>) => events.set(name, [...(events.get(name) ?? []), handler]),
      } as never);
      const ui = {
        select: async (title: string, choices: string[]) => {
          selectors.push(title);
          if (title === "Execution target") return "routing configuration (live, full pin coverage)";
          if (title === "Routing persona") return "persona: personal";
          if (title === "Model alias for worker") return "shared-model";
          throw new Error(`unexpected selector ${title}: ${choices.join(",")}`);
        },
        input: async (title: string) => title.startsWith("ACP adapter") ? "/trusted/adapter" : undefined,
        editor: async (title: string) => title.startsWith("Adapter argv") ? "[]" : "subject",
        confirm: async (title: string) => { confirmations.push(title); return true; },
        notify: () => {}, setWidget: () => {}, setStatus: () => {}, custom: async () => undefined,
      };
      const ctx = { cwd: directory, mode: "tui", hasUI: true, isProjectTrusted: () => true, ui, isIdle: () => true, abort: () => {}, sessionManager: { getBranch: () => [] } };
      for (const handler of events.get("session_start") ?? []) await handler({}, ctx);
      await commands.get("wf-launch")!.handler("agent-cat:fixture", ctx);
      await until(() => entries.length === 1);
      const [runId] = await readdir(join(directory, "state", "runs"));
      const manifestPath = join(directory, "state", "runs", runId, "supervisor-manifest.json");
      const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
      expect(manifest.targetKind).toBe("routing");
      expect(manifest.targetArgs).toEqual([
        "--routing", "--persona", "personal", "--realize", "worker=shared-model",
        "--offline", "--expect-routing-fingerprint", "f".repeat(64),
      ]);
      expect(JSON.stringify(manifest)).not.toContain("sentinel");
      expect((await stat(manifestPath)).mode & 0o077).toBe(0);
      expect(selectors).toEqual(["Execution target", "Routing persona", "Model alias for worker"]);
      expect(confirmations).not.toContain("Configure pin routes?");
      for (const handler of events.get("session_shutdown") ?? []) await handler({}, ctx);
    } finally {
      if (previousRunner === undefined) delete process.env.AGENT_CAT_RUNNER; else process.env.AGENT_CAT_RUNNER = previousRunner;
      if (previousRunners === undefined) delete process.env.AGENT_CAT_RUNNERS; else process.env.AGENT_CAT_RUNNERS = previousRunners;
      if (previousState === undefined) delete process.env.AGENT_CAT_STATE_DIR; else process.env.AGENT_CAT_STATE_DIR = previousState;
    }
  });

  it("preserves descriptor-v3 routing choices for routing-only lineage", async () => {
    const directory = await mkdtemp(join(tmpdir(), "agent-cat-extension-routing-v3-"));
    created.push(directory);
    const previousRunner = process.env.AGENT_CAT_RUNNER;
    const previousRunners = process.env.AGENT_CAT_RUNNERS;
    const previousState = process.env.AGENT_CAT_STATE_DIR;
    delete process.env.AGENT_CAT_RUNNER;
    process.env.AGENT_CAT_RUNNERS = JSON.stringify([{
      id: "agent-cat", executable: resolve("test/fixtures/runner.mjs"),
      prefixArgs: ["--descriptor-v3"], allowedCwds: [directory],
    }]);
    process.env.AGENT_CAT_STATE_DIR = join(directory, "state");
    try {
      const commands = new Map<string, { handler: (args: string, ctx: unknown) => Promise<void> }>();
      const events = new Map<string, Array<(event: unknown, ctx: unknown) => Promise<unknown>>>();
      const entries: unknown[] = [];
      const selectors: string[] = [];
      const confirmations: string[] = [];
      extension({
        registerEntryRenderer: () => {}, registerTool: () => {}, sendUserMessage: () => {},
        registerCommand: (name: string, command: unknown) => commands.set(name, command as never),
        appendEntry: (_type: string, data: unknown) => entries.push(data),
        on: (name: string, handler: (event: unknown, ctx: unknown) => Promise<unknown>) => events.set(name, [...(events.get(name) ?? []), handler]),
      } as never);
      const ui = {
        select: async (title: string, choices: string[]) => {
          selectors.push(title);
          if (title === "Execution target") return "routing configuration (live, full pin coverage)";
          if (title === "Routing persona") return "persona: personal";
          if (title === "Model alias for worker") return "shared-model";
          throw new Error(`unexpected selector ${title}: ${choices.join(",")}`);
        },
        input: async () => undefined,
        editor: async () => "subject",
        confirm: async (title: string) => { confirmations.push(title); return true; },
        notify: () => {}, setWidget: () => {}, setStatus: () => {}, custom: async () => undefined,
      };
      const ctx = { cwd: directory, mode: "tui", hasUI: true, isProjectTrusted: () => true, ui, isIdle: () => true, abort: () => {}, sessionManager: { getBranch: () => [] } };
      for (const handler of events.get("session_start") ?? []) await handler({}, ctx);
      await commands.get("wf-launch")!.handler("agent-cat:fixture", ctx);
      await until(() => entries.length === 1);
      const [runId] = await readdir(join(directory, "state", "runs"));
      const manifestPath = join(directory, "state", "runs", runId, "supervisor-manifest.json");
      const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
      expect(manifest.targetKind).toBe("routing");
      expect(manifest.targetArgs.slice(-5)).toEqual([
        "--realize", "worker=shared-model", "--offline", "--expect-routing-fingerprint", "f".repeat(64),
      ]);
      expect(JSON.stringify(manifest)).not.toContain("sentinel");
      expect((await stat(manifestPath)).mode & 0o077).toBe(0);
      await commands.get("wf-resume")!.handler(runId, ctx);
      await until(() => entries.length === 2);
      const manifests = await Promise.all((await readdir(join(directory, "state", "runs"))).map(async (id) =>
        JSON.parse(await readFile(join(directory, "state", "runs", id, "supervisor-manifest.json"), "utf8")),
      ));
      const child = manifests.find((value) => value.parentRunId === runId);
      expect(child).toMatchObject({ targetKind: "routing", lineage: "resume", parentRunId: runId });
      expect(child.targetArgs).toEqual(manifest.targetArgs);
      expect(selectors).toEqual(["Execution target", "Routing persona", "Model alias for worker"]);
      expect(confirmations).not.toContain("Configure pin routes?");
      for (const handler of events.get("session_shutdown") ?? []) await handler({}, ctx);
    } finally {
      if (previousRunner === undefined) delete process.env.AGENT_CAT_RUNNER; else process.env.AGENT_CAT_RUNNER = previousRunner;
      if (previousRunners === undefined) delete process.env.AGENT_CAT_RUNNERS; else process.env.AGENT_CAT_RUNNERS = previousRunners;
      if (previousState === undefined) delete process.env.AGENT_CAT_STATE_DIR; else process.env.AGENT_CAT_STATE_DIR = previousState;
    }
  });

  it("requires a human confirmation of the exact review for every model-initiated mutation", async () => {
  const directory = await mkdtemp(join(tmpdir(), "agent-cat-extension-tool-"));
  created.push(directory);
  const previousRunner = process.env.AGENT_CAT_RUNNER;
  const previousState = process.env.AGENT_CAT_STATE_DIR;
  const previousHang = process.env.FIXTURE_HANG;
  process.env.AGENT_CAT_RUNNER = resolve("test/fixtures/runner.mjs");
  process.env.AGENT_CAT_STATE_DIR = join(directory, "state");
  try {
    const commands = new Map<string, { handler: (args: string, ctx: unknown) => Promise<void> }>();
    const events = new Map<string, Array<(event: unknown, ctx: unknown) => Promise<unknown>>>();
    let tool: any;
    let answer = false;
    const reviews: Array<{ title: string; body: string }> = [];
    const notices: string[] = [];
    const entries: unknown[] = [];
    extension({
      registerEntryRenderer: () => {}, registerCommand: (name: string, command: unknown) => commands.set(name, command as never),
      registerTool: (definition: unknown) => { tool = definition; }, appendEntry: (_type: string, data: unknown) => entries.push(data), sendUserMessage: () => {},
      on: (name: string, handler: (event: unknown, ctx: unknown) => Promise<unknown>) => events.set(name, [...(events.get(name) ?? []), handler]),
    } as never);
    const ui = {
      select: async (title: string) => title === "Execution target" ? "scripted (offline, no commands)" : undefined,
      editor: async () => "x",
      confirm: async (title: string, body: string) => { reviews.push({ title, body }); return answer; },
      notify: (message: string) => notices.push(message), setWidget: () => {}, setStatus: () => {},
    };
    const ctx = { cwd: directory, mode: "tui", hasUI: true, isProjectTrusted: () => true, ui, isIdle: () => true, abort: () => {}, sessionManager: { getBranch: () => [] } };
    const runs = async () => (await readdir(join(directory, "state", "runs")).catch(() => [])).length;
    const status = async () => JSON.parse((await tool.execute("status", { action: "status" }, undefined, undefined, ctx)).content[0].text) as Array<{ runId: string; status: string }>;
    for (const handler of events.get("session_start") ?? []) await handler({}, ctx);

    // No command and no tool parameter issues or carries a grant.
    expect(tool.name).toBe("agent_cat_workflow");
    expect(commands.has("wf-grant")).toBe(false);
    expect(tool.description).not.toContain("grant");
    expect(tool.description).toContain("confirm");
    expect(Object.keys(tool.parameters.properties)).not.toContain("grantId");
    expect(tool.parameters.additionalProperties).not.toBe(false);
    const extra = { action: "start", workflow: "agent-cat:fixture", inputsJson: '{"subject":"x"}', launchTarget: "scripted", grantId: "grant-model", approved: true, consent: "yes" };
    expect(Value.Check(tool.parameters, extra)).toBe(true);

    // The human /wf-launch review of the same launch, declined.
    await commands.get("wf-launch")!.handler("agent-cat:fixture", ctx);
    const humanReview = reviews.at(-1)!;
    expect(humanReview.title).toBe("Launch agent-cat workflow?");
    expect(humanReview.body).toContain("target=scripted (offline, no commands)");

    const untrustedStart = await tool.execute("untrusted-start", extra, undefined, undefined, { ...ctx, isProjectTrusted: () => false });
    expect(untrustedStart).toMatchObject({ isError: true, content: [{ text: expect.stringContaining("trusted project") }] });
    const reviewCount = reviews.length;
    const headless = await tool.execute("headless-start", extra, undefined, undefined, { ...ctx, hasUI: false });
    expect(headless).toMatchObject({ isError: true, content: [{ text: expect.stringContaining("interactive Pi UI") }] });
    expect(reviews.length).toBe(reviewCount);

    // A declined start launches nothing, whatever extra field the model sends.
    const declined = await tool.execute("declined-start", extra, undefined, undefined, ctx);
    expect(declined).toMatchObject({ isError: true, content: [{ text: expect.stringContaining("declined") }] });
    expect(reviews.at(-1)).toEqual({ title: "Launch agent-cat workflow?", body: `${humanReview.body}\ninput subject="x"` });
    expect(await runs()).toBe(0);
    expect(await status()).toEqual([]);

    answer = true;
    const started = await tool.execute("start", extra, undefined, undefined, ctx);
    expect(started.isError).not.toBe(true);
    const parentRunId = started.content[0].text.match(/[0-9a-f-]{36}/)![0];
    await until(() => entries.length === 1);
    const inspected = await tool.execute("inspect", { action: "inspect", runId: parentRunId }, undefined, undefined, ctx);
    expect(inspected.content[0].text).toContain(parentRunId);
    const untrustedInspect = await tool.execute("inspect-untrusted", { action: "inspect", runId: parentRunId }, undefined, undefined, { ...ctx, isProjectTrusted: () => false });
    expect(untrustedInspect.isError).toBe(true);

    // Lineage shows its exact review, and a decline launches nothing.
    answer = false;
    const declinedResume = await tool.execute("declined-resume", { action: "resume", parentRunId, inputsJson: '{"subject":"x"}', grantId: "grant-model" }, undefined, undefined, ctx);
    expect(declinedResume).toMatchObject({ isError: true, content: [{ text: expect.stringContaining("declined") }] });
    expect(reviews.at(-1)!.title).toBe("resume workflow run?");
    expect(reviews.at(-1)!.body).toContain(`operation=resume\nparent=${parentRunId}\nworkflow=agent-cat:fixture`);
    expect(reviews.at(-1)!.body).toContain('input subject="x"');
    expect(await runs()).toBe(1);
    const headlessResume = await tool.execute("headless-resume", { action: "resume", parentRunId, inputsJson: '{"subject":"x"}' }, undefined, undefined, { ...ctx, hasUI: false });
    expect(headlessResume.isError).toBe(true);
    expect(await runs()).toBe(1);
    answer = true;
    const resumed = await tool.execute("resume", { action: "resume", parentRunId, inputsJson: '{"subject":"x"}' }, undefined, undefined, ctx);
    expect(resumed.isError).not.toBe(true);
    await until(() => entries.length === 2);
    const forked = await tool.execute("fork", { action: "fork", parentRunId, inputsJson: '{"subject":"x"}', forkEditsJson: '[{"type":"drop","occurrenceId":"0"}]' }, undefined, undefined, ctx);
    expect(forked.isError).not.toBe(true);
    expect(reviews.at(-1)!.title).toBe("fork workflow run?");
    expect(reviews.at(-1)!.body).toContain("edit drop occurrence 0");
    const forkRunId = forked.content[0].text.match(/[0-9a-f-]{36}/)![0];
    await until(() => entries.length === 3);
    const forkManifest = JSON.parse(await readFile(join(directory, "state", "runs", forkRunId, "supervisor-manifest.json"), "utf8"));
    expect(forkManifest.lineageEdits).toEqual([{ type: "drop", occurrenceId: "0" }]);
    await commands.get("wf-diff")!.handler(forkRunId, ctx);
    expect(notices.at(-1)).toContain("answer edits:");
    expect(notices.at(-1)).toContain("occurrence 0:");

    // A control shows its exact content, and a declined control is not delivered.
    process.env.FIXTURE_HANG = "1";
    const hanging = await tool.execute("hanging", extra, undefined, undefined, ctx);
    const hangingRunId = hanging.content[0].text.match(/[0-9a-f-]{36}/)![0];
    const running = async () => (await status()).find((run) => run.runId === hangingRunId)?.status;
    await untilAsync(async () => (await tool.execute("inspect", { action: "inspect", runId: hangingRunId }, undefined, undefined, ctx)).content[0].text.includes("attempt 0:0: running"));
    answer = false;
    const declinedCancel = await tool.execute("declined-cancel", { action: "cancel", runId: hangingRunId, grantId: "grant-model", approved: true }, undefined, undefined, ctx);
    expect(declinedCancel).toMatchObject({ isError: true, content: [{ text: expect.stringContaining("declined") }] });
    expect(reviews.at(-1)).toEqual({ title: "Send workflow control?", body: `kind=cancel\nrun=${hangingRunId}` });
    const headlessCancel = await tool.execute("headless-cancel", { action: "cancel", runId: hangingRunId }, undefined, undefined, { ...ctx, hasUI: false });
    expect(headlessCancel.isError).toBe(true);
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 100));
    expect(await running()).toBe("running");
    answer = true;
    const steered = await tool.execute("steer", { action: "steer", runId: hangingRunId, occurrenceId: "0", attemptId: "0:0", text: "focus\non tests", timing: "next-boundary" }, undefined, undefined, ctx);
    expect(steered).toMatchObject({ content: [{ text: expect.stringContaining("steer delivered") }] });
    expect(steered.isError).not.toBe(true);
    expect(reviews.at(-1)).toEqual({
      title: "Send workflow control?",
      body: `kind=steer\nrun=${hangingRunId}\noccurrence=0\nattempt=0:0\ntiming=next-boundary\ntext="focus\\non tests"`,
    });
    const cancelled = await tool.execute("cancel", { action: "cancel", runId: hangingRunId }, undefined, undefined, ctx);
    expect(cancelled.isError).not.toBe(true);
    await untilAsync(async () => (await running()) === "cancelled");
    for (const handler of events.get("session_shutdown") ?? []) await handler({}, ctx);
  } finally {
    if (previousRunner === undefined) delete process.env.AGENT_CAT_RUNNER; else process.env.AGENT_CAT_RUNNER = previousRunner;
    if (previousState === undefined) delete process.env.AGENT_CAT_STATE_DIR; else process.env.AGENT_CAT_STATE_DIR = previousState;
    if (previousHang === undefined) delete process.env.FIXTURE_HANG; else process.env.FIXTURE_HANG = previousHang;
  }
});
});

describe("service actions of the agent_cat_workflow tool", () => {
  let profiles: Awaited<ReturnType<typeof clientProfiles>>;
  beforeAll(async () => {
    profiles = await clientProfiles("agent-cat-extension-service-");
  });
  afterAll(async () => {
    await profiles.remove();
  });
  const saved = { profile: process.env.AGENT_CAT_MANAGER_PROFILE, state: process.env.AGENT_CAT_STATE_DIR };
  afterEach(() => {
    if (saved.profile === undefined) delete process.env.AGENT_CAT_MANAGER_PROFILE; else process.env.AGENT_CAT_MANAGER_PROFILE = saved.profile;
    if (saved.state === undefined) delete process.env.AGENT_CAT_STATE_DIR; else process.env.AGENT_CAT_STATE_DIR = saved.state;
  });

  const SHA = "a".repeat(64);
  const PAGE = () => ({ setId: "set_1", revision: "rev_1", expiresAt: new Date(Date.now() + 60000).toISOString(), index: 0, totalItems: 1, next: null });

  /** A command receipt of the fake manager. */
  function receipt(id: string, operation: Operation, resource: string, state: string, effect: unknown): unknown {
    return {
      version: 1, id, profileId: "profile_1", operation, requiredScopes: [...requiredScopes(operation)], resource, state,
      acceptedAt: "2026-10-01T12:00:00Z", dispatchAttemptedAt: null, acknowledgement: null, effect, refusal: null,
      links: { self: `/v1/commands/${id}`, resource },
    };
  }

  function accepted(value: unknown, status = 202): Reply {
    const location = status === 201 ? `/v1/requests/${String((value as { id: string }).id)}` : `/v1/commands/${String((value as { id: string }).id)}`;
    const text = JSON.stringify(value);
    return { ok: true, value: { status, value: parseJson(text) as JsonValue, etag: null, location, bytes: Buffer.byteLength(text) } };
  }

  /**
   * A stateful fake manager with one ready profile, one workflow `review`
   * with the input `subject`, and the running run run_a1 whose head is the
   * flag question decision_a1. Each create makes a new request req_tN, an
   * enqueue moves it to review with the live preparation prep_tN, and an
   * approval starts run run_tN.
   */
  async function serviceHost() {
    process.env.AGENT_CAT_MANAGER_PROFILE = profiles.profile("tool", "alpha.test");
    process.env.AGENT_CAT_STATE_DIR = await mkdtemp(join(profiles.directory, "state-"));
    const requests = new Map<string, { phase: string; supplied: unknown[]; revision: number; runId: string | null }>();
    const settled = new Map<string, unknown>();
    let commands = 0;
    const view = (id: string) => {
      const state = requests.get(id)!;
      return {
        version: 1, id, revision: `${id}_rev_${state.revision}`, workflowId: "wf_review", descriptorRevision: "catalogue_17", profileId: "profile_1",
        profileRevision: "profile_rev_4", phase: state.phase,
        readiness: {
          declarations: [{ name: "subject", source: "command-tail", description: null, required: true, schema: { type: "string" } }],
          supplied: state.supplied, missing: state.supplied.length > 0 ? [] : ["subject"], errors: [],
        },
        admission: state.phase === "draft" ? { state: "not-queued", position: null, reasons: state.supplied.length > 0 ? [] : ["missing-inputs"] }
          : { state: "reserved", position: null, reasons: [] },
        preparationId: state.phase === "draft" ? null : `prep_${id.slice(4)}`, runId: state.runId, parentRunId: null, lineage: null,
        links: { self: `/v1/requests/${id}` },
      };
    };
    const preparation = (id: string) => ({
      version: 1, id, revision: `${id}_rev`, requestId: `req_${id.slice(5)}`, requestRevision: "request_rev_2", profileId: "profile_1",
      profileRevision: "profile_rev_4", descriptorRevision: "catalogue_17", state: "live", expiresAt: "2026-10-01T12:10:00Z", reviewDigest: SHA,
      processGeneration: "process_A",
      review: {
        programHash: SHA, personAnswering: "local-control", policy: { kind: "scripted" }, workflowId: "wf_review", profileId: "profile_1",
        workspaceLabel: "Review workspace", targetLabel: "Deterministic worker", inputs: [{ name: "subject", source: "literal", bytes: "8", sha256: SHA }],
        plan: "Review the supplied subject.", runFacts: [], pins: [], warnings: [], resultCode: "receipt",
      },
      reason: null,
    });
    const head = (decision("decision_a1", "run_a1") as { decision: Record<string, unknown> }).decision;
    const base = manager([run("run_a1", "running"), decision("decision_a1", "run_a1")]);
    const fake = transports({
      "alpha.test": (resource, count) => {
        if (resource === "/v1/capabilities") return ok(capabilities({}, ["observe", "submit", "control"]));
        if (resource === "/v1/profiles") {
          return ok({ version: 1, page: PAGE(), items: [{ id: "profile_1", workspaceLabel: "Review workspace", targetLabel: "Deterministic worker", readiness: "ready" }] });
        }
        if (resource === "/v1/workflows?profileId=profile_1") {
          return ok({
            version: 1, page: PAGE(), items: [{
              id: "wf_review", name: "review", blurb: "Review a subject", revision: "catalogue_17", profileId: "profile_1", profileRevision: "profile_rev_4",
              inputs: [{ name: "subject", source: "command-tail", description: null, required: true, schema: { type: "string" } }],
            }],
          });
        }
        const request = /^\/v1\/requests\/(req_t[0-9]+)$/.exec(resource);
        if (request !== null && requests.has(request[1])) return ok(view(request[1]), `"${request[1]}_rev_${requests.get(request[1])!.revision}"`);
        const prepared = /^\/v1\/preparations\/(prep_t[0-9]+)$/.exec(resource);
        if (prepared !== null) return ok(preparation(prepared[1]), `"${prepared[1]}_rev"`);
        if (settled.has(resource)) return ok(settled.get(resource));
        if (resource === "/v1/decisions?runId=run_a1") return ok({ version: 1, page: PAGE(), items: [head] });
        if (resource === "/v1/decisions/decision_a1") return ok(head, '"decision_a1_rev"');
        if (resource === "/v1/runs/run_a1/control") return ok(control("run_a1", "decision_a1"), '"control_rev"');
        return base(resource, count);
      },
    }, [], {
      "alpha.test": (resource, body) => {
        const operation = isJsonObject(body) ? jsonMember(body, "operation") : undefined;
        if (resource === "/v1/requests") {
          const id = `req_t${requests.size + 1}`;
          requests.set(id, { phase: "draft", supplied: [], revision: 1, runId: null });
          return accepted(view(id), 201);
        }
        commands += 1;
        const id = `cmd_${commands}`;
        const send = (op: Operation, effect: unknown): Reply => {
          settled.set(`/v1/commands/${id}`, receipt(id, op, resource, "effect-observed", effect));
          return accepted(receipt(id, op, resource, "accepted", null));
        };
        const request = /^\/v1\/requests\/(req_t[0-9]+)$/.exec(resource);
        if (request !== null && operation === "set-input") {
          const state = requests.get(request[1])!;
          state.supplied = [jsonMember(body as never, "input")];
          state.revision += 1;
          return send("set-input", { kind: "input-changed", runtimeSequence: null, address: null, resource });
        }
        if (request !== null && operation === "enqueue") {
          const state = requests.get(request[1])!;
          state.phase = "review";
          state.revision += 1;
          return send("enqueue", { kind: "enqueued", runtimeSequence: null, address: null, resource });
        }
        const prepared = /^\/v1\/preparations\/prep_(t[0-9]+)$/.exec(resource);
        if (prepared !== null && operation === "approve") {
          const state = requests.get(`req_${prepared[1]}`)!;
          state.phase = "associated";
          state.runId = `run_${prepared[1]}`;
          state.revision += 1;
          setTimeout(() => fake.made[0].emit(`s.${commands + 1}`, `/v1/requests/req_${prepared[1]}`), 0);
          return send("approve", null);
        }
        if (resource === "/v1/decisions/decision_a1" && operation === "answer") {
          return send("answer", { kind: "answer-accepted", runtimeSequence: "12", address: { occurrenceId: "0" }, resource });
        }
        return undefined;
      },
    });
    const commandsMap = new Map<string, { handler: (args: string, ctx: unknown) => Promise<void> }>();
    const events = new Map<string, Array<(event: unknown, ctx: unknown) => Promise<unknown>>>();
    let tool: any;
    extension({
      registerEntryRenderer: () => {}, registerCommand: (name: string, command: unknown) => commandsMap.set(name, command as never),
      registerTool: (definition: unknown) => { tool = definition; }, appendEntry: () => {}, sendUserMessage: () => {},
      on: (name: string, handler: (event: unknown, ctx: unknown) => Promise<unknown>) => events.set(name, [...(events.get(name) ?? []), handler]),
    } as never, { manager: { transport: fake.transport } });
    const confirmations: Array<{ title: string; body: string }> = [];
    const answers: boolean[] = [];
    const notices: string[] = [];
    const ui = {
      select: async (_title: string, choices: string[]) => choices.includes("Approve this review") ? "Approve this review" : choices[0],
      editor: async () => "Exact λ subject",
      input: async () => undefined,
      confirm: async (title: string, body: string) => {
        confirmations.push({ title, body });
        const answer = answers.shift();
        if (answer === undefined) throw new Error(`unexpected confirmation ${title}`);
        return answer;
      },
      notify: (message: string) => notices.push(message), setWidget: () => {}, setStatus: () => {}, custom: async () => undefined,
    };
    const ctx = { cwd: profiles.directory, mode: "rpc", hasUI: true, isProjectTrusted: () => true, ui, isIdle: () => true, abort: () => {}, sessionManager: { getBranch: () => [] } };
    for (const handler of events.get("session_start") ?? []) await handler({}, ctx);
    for (let count = 0; ; count += 1) {
      await commandsMap.get("wfm-status")!.handler("", ctx);
      if (notices.at(-1)?.includes("delivery live")) break;
      if (count > 500) throw new Error(`no connection: ${notices.join("\n")}`);
      await new Promise((wake) => setTimeout(wake, 10));
    }
    const execute = async (params: Record<string, unknown>, context: unknown = ctx) =>
      tool.execute("call", params, undefined, undefined, context) as Promise<{ isError?: boolean; content: Array<{ text: string }> }>;
    return { commands: commandsMap, events, ctx, made: () => fake.made[0], confirmations, answers, notices, execute };
  }

  it("starts a manager run only after the human confirms the request and its exact review, and a decline or a missing UI sends nothing", async () => {
    const pi = await serviceHost();
    const start = { action: "manager-start", workflow: "review", inputsJson: '{"subject":"Exact λ subject"}', grantId: "grant-model", approved: true };
    const posts = () => pi.made().bodies.map((post, index) => [pi.made().posts[index], JSON.parse(post.body).operation ?? "create"]);
    const credential = readFileSync(profiles.credentialFile, "utf8");
    const results: string[] = [];
    const call = async (params: Record<string, unknown>, context?: unknown) => {
      const result = await pi.execute(params, context);
      results.push(result.content.map((item) => item.text).join("\n"));
      return result;
    };

    // Without a UI the tool refuses before any request.
    const gets = pi.made().gets.length;
    const headless = await call(start, { ...pi.ctx, hasUI: false });
    expect(headless).toMatchObject({ isError: true, content: [{ text: expect.stringContaining("interactive Pi UI") }] });
    expect(pi.made().gets.length).toBe(gets);
    expect(pi.made().posts).toEqual([]);
    expect(pi.confirmations).toEqual([]);

    // A declined request sends nothing.
    pi.answers.push(false);
    const declined = await call(start);
    expect(declined).toMatchObject({ isError: true, content: [{ text: expect.stringContaining("The human declined the request of review. Nothing was sent.") }] });
    expect(pi.confirmations.at(-1)).toEqual({
      title: "Create manager request?",
      body: [
        "profile=profile_1", "workspace=Review workspace", "target=Deterministic worker", "workflow=review (wf_review)", "descriptorRevision=catalogue_17",
        "profileRevision=profile_rev_4", 'input subject="Exact λ subject" (literal)',
      ].join("\n"),
    });
    expect(pi.made().posts).toEqual([]);

    // A declined review sends no approve POST, and the request stays in review.
    pi.answers.push(true, false);
    const unapproved = await call(start);
    expect(unapproved.isError).toBe(true);
    expect(unapproved.content[0].text).toContain("Review declined. No approval was sent. Request req_t1 stays in review");
    expect(pi.confirmations.at(-1)?.title).toBe("Approve this exact review?");
    expect(pi.confirmations.at(-1)?.body).toContain("review digest " + SHA);
    expect(posts()).toEqual([["/v1/requests", "create"], ["/v1/requests/req_t1", "set-input"], ["/v1/requests/req_t1", "enqueue"]]);
    expect(JSON.parse(pi.made().bodies[1].body)).toEqual({ operation: "set-input", input: { name: "subject", source: "literal", value: "Exact λ subject" } });

    // A confirmed review sends one approve POST, and the manager starts the run.
    pi.answers.push(true, true);
    const before = pi.made().posts.length;
    const approved = await call(start);
    expect(approved.isError).not.toBe(true);
    expect(approved.content[0].text).toContain("Execution: the manager started run run_t2 for request req_t2.");
    const tool = posts().slice(before);
    expect(tool).toEqual([["/v1/requests", "create"], ["/v1/requests/req_t2", "set-input"], ["/v1/requests/req_t2", "enqueue"], ["/v1/preparations/prep_t2", "approve"]]);
    expect(JSON.parse(pi.made().bodies.at(-1)!.body)).toEqual({
      operation: "approve", reviewDigest: SHA, requestRevision: "request_rev_2", profileRevision: "profile_rev_4", descriptorRevision: "catalogue_17",
      processGeneration: "process_A",
    });

    // The human /wfm reaches the same manager transitions.
    pi.answers.push(true);
    const human = pi.made().posts.length;
    await pi.commands.get("wfm")!.handler("review", pi.ctx);
    expect(posts().slice(human).map(([, operation]) => operation)).toEqual(tool.map(([, operation]) => operation));
    expect(pi.notices).toContain("Execution: the manager started run run_t3 for request req_t3.");

    // The read actions need no confirmation and name no client profile path.
    const confirmed = pi.confirmations.length;
    const status = await call({ action: "manager-status" });
    expect(status.content[0].text).toMatch(/^Service mode: profile 1 of 1\nConnection: connected to https:\/\/alpha\.test:8443\/v1/);
    expect((await call({ action: "manager-list" })).content[0].text).toBe("Profile profile_1  Review workspace  Deterministic worker\n  review  inputs subject (command-tail)  Review a subject");
    expect(pi.confirmations.length).toBe(confirmed);
    for (const text of results) {
      expect(text).not.toContain(credential);
      expect(text).not.toContain(profiles.credentialFile);
      expect(text).not.toContain(profiles.directory);
    }
    for (const handler of pi.events.get("session_shutdown") ?? []) await handler({}, pi.ctx);
  });

  it("answers a manager decision with JSON false only after the human confirms the typed value", async () => {
    const pi = await serviceHost();
    const answer = { action: "manager-answer", runId: "run_a1", answer: "false" };
    expect((await pi.execute(answer, { ...pi.ctx, hasUI: false })).isError).toBe(true);
    pi.answers.push(false);
    const declined = await pi.execute(answer);
    expect(declined).toMatchObject({ isError: true, content: [{ text: expect.stringContaining("The human declined the answer of decision decision_a1. Nothing was sent.") }] });
    expect(pi.confirmations.at(-1)).toEqual({
      title: "Send manager answer?",
      body: 'decision=decision_a1\nrun=run_a1\ncode=flag: yes, no, true or false\nprompt="Proceed?"\nvalue=false',
    });
    expect(pi.made().posts).toEqual([]);
    pi.answers.push(true);
    const sent = await pi.execute(answer);
    expect(sent.isError).not.toBe(true);
    expect(sent.content[0].text).toContain("Answer false reached decision decision_a1 of run run_a1.");
    expect(pi.made().posts).toEqual(["/v1/decisions/decision_a1"]);
    expect(pi.made().bodies).toEqual([{ body: '{"generation":"generation_3","occurrenceId":"0","operation":"answer","value":false}', ifMatch: '"decision_a1_rev"' }]);
    // A recovery choice for a question head sends nothing.
    const wrong = await pi.execute({ action: "manager-control", runId: "run_a1", controlKind: "retry" });
    expect(wrong).toMatchObject({ isError: true, content: [{ text: expect.stringContaining("is a question") }] });
    expect(pi.made().posts).toEqual(["/v1/decisions/decision_a1"]);
    for (const handler of pi.events.get("session_shutdown") ?? []) await handler({}, pi.ctx);
  });
});

async function until(predicate: () => boolean): Promise<void> {
  for (let count = 0; count < 200; count += 1) {
    if (predicate()) return;
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 10));
  }
  throw new Error("condition not reached");
}

async function untilAsync(predicate: () => Promise<boolean>): Promise<void> {
  for (let count = 0; count < 200; count += 1) {
    if (await predicate()) return;
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 10));
  }
  throw new Error("condition not reached");
}
