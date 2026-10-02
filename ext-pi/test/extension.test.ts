import { createHash } from "node:crypto";
import { access, mkdir, mkdtemp, readFile, readdir, rm, stat, utimes, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { Value } from "typebox/value";
import extension, { parseWorkflowCommand } from "../src/index.ts";
import { MANAGER_ROLE_MARKER, ROOT_ROLE_FILE } from "../src/root-role.ts";

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
