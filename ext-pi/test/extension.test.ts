import { createHash } from "node:crypto";
import { access, mkdtemp, readFile, readdir, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import extension, { parseWorkflowCommand, routingLineageArgs } from "../src/index.ts";

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

  it("refuses mutable launches without interactive approval", async () => {
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
    await commands.get("wf")!.handler("agent-cat:fixture", ctx);
    expect(notices).toEqual([expect.stringContaining("requires interactive approval")]);
    notices.length = 0;
    await commands.get("wf")!.handler("agent-cat:fixture", {
      ...ctx, hasUI: true, isProjectTrusted: () => false,
    });
    expect(notices).toEqual([expect.stringContaining("requires a trusted project")]);
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
      expect(commands.has("wf")).toBe(true);
      expect(commands.has("workflow")).toBe(true);
      expect(commands.has("workflows")).toBe(false);
      await commands.get("wf")!.handler("fixture", ctx);
      expect(notices.at(-1)).toContain("requires interactive approval");
      await commands.get("workflow-status")!.handler("", ctx);
      expect(notices.at(-1)).toContain("No active workflow runs");
      await commands.get("workflow")!.handler("agent-cat:fixture", ctx);
      expect(notices.at(-1)).toContain("requires interactive approval");
    } finally {
      if (previousRunner === undefined) delete process.env.AGENT_CAT_RUNNER; else process.env.AGENT_CAT_RUNNER = previousRunner;
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
      await commands.get("workflow")!.handler("agent-cat:fixture", ctx);
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

  it("extracts only explicit persona and realization choices for rebuilt lineage targets", () => {
    expect(routingLineageArgs([
      "--engine", "acp", "--adapter-arg", "--persona", "--route", "worker=acp:stub",
      "--persona", "work", "--realize", "worker=work-model", "--realize", "worker#2=spare-model",
    ])).toEqual(["--persona", "work", "--realize", "worker=work-model", "--realize", "worker#2=spare-model"]);
    expect(routingLineageArgs(["--adapter-arg", "--persona"])).toEqual([]);
  });

  it("uses descriptor-v3 sanitized routing choices and preserves them for owned-child lineage", async () => {
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
          if (title === "Execution target") return "owned Pi child (live, agent-cat scratch, no tools)";
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
      await commands.get("workflow")!.handler("agent-cat:fixture", ctx);
      await until(() => entries.length === 1);
      const [runId] = await readdir(join(directory, "state", "runs"));
      const manifestPath = join(directory, "state", "runs", runId, "supervisor-manifest.json");
      const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
      expect(manifest.targetKind).toBe("child");
      expect(manifest.targetArgs.slice(-4)).toEqual([
        "--persona", "personal", "--realize", "worker=shared-model",
      ]);
      expect(JSON.stringify(manifest)).not.toContain("sentinel");
      expect((await stat(manifestPath)).mode & 0o077).toBe(0);
      await commands.get("workflow-resume")!.handler(runId, ctx);
      await until(() => entries.length === 2);
      const manifests = await Promise.all((await readdir(join(directory, "state", "runs"))).map(async (id) =>
        JSON.parse(await readFile(join(directory, "state", "runs", id, "supervisor-manifest.json"), "utf8")),
      ));
      const child = manifests.find((value) => value.parentRunId === runId);
      expect(child).toMatchObject({ targetKind: "child", lineage: "resume", parentRunId: runId });
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

  it("uses one-time grants for model starts and lineage operations", async () => {
    const directory = await mkdtemp(join(tmpdir(), "agent-cat-extension-tool-"));
    created.push(directory);
    const previousRunner = process.env.AGENT_CAT_RUNNER;
    const previousState = process.env.AGENT_CAT_STATE_DIR;
    process.env.AGENT_CAT_RUNNER = resolve("test/fixtures/runner.mjs");
    process.env.AGENT_CAT_STATE_DIR = join(directory, "state");
    try {
      const commands = new Map<string, { handler: (args: string, ctx: unknown) => Promise<void> }>();
      const events = new Map<string, Array<(event: unknown, ctx: unknown) => Promise<unknown>>>();
      let tool: any;
      let grantScope = "start";
      const notices: string[] = [];
      const entries: unknown[] = [];
      extension({
        registerEntryRenderer: () => {}, registerCommand: (name: string, command: unknown) => commands.set(name, command as never),
        registerTool: (definition: unknown) => { tool = definition; }, appendEntry: (_type: string, data: unknown) => entries.push(data), sendUserMessage: () => {},
        on: (name: string, handler: (event: unknown, ctx: unknown) => Promise<unknown>) => events.set(name, [...(events.get(name) ?? []), handler]),
      } as never);
      const ui = {
        select: async (title: string) => title === "One-time model grant" ? grantScope : undefined,
        confirm: async () => true, notify: (message: string) => notices.push(message), setWidget: () => {}, setStatus: () => {},
      };
      const ctx = { cwd: directory, mode: "tui", hasUI: true, isProjectTrusted: () => true, ui, isIdle: () => true, abort: () => {}, sessionManager: { getBranch: () => [] } };
      for (const handler of events.get("session_start") ?? []) await handler({}, ctx);
      await commands.get("workflow-grant")!.handler("", ctx);
      const startGrant = notices.at(-1)!.match(/grant-[0-9a-f-]+/)![0];
      const untrustedStart = await tool.execute("untrusted-start", { action: "start", workflow: "agent-cat:fixture", inputsJson: '{"subject":"x"}', launchTarget: "scripted", grantId: startGrant }, undefined, undefined, { ...ctx, isProjectTrusted: () => false });
      expect(untrustedStart).toMatchObject({ isError: true, content: [{ text: expect.stringContaining("trusted project") }] });
      const started = await tool.execute("start", { action: "start", workflow: "agent-cat:fixture", inputsJson: '{"subject":"x"}', launchTarget: "scripted", grantId: startGrant }, undefined, undefined, ctx);
      expect(started.isError).not.toBe(true);
      const parentRunId = started.content[0].text.match(/[0-9a-f-]{36}/)![0];
      await until(() => entries.length === 1);
      const inspected = await tool.execute("inspect", { action: "inspect", runId: parentRunId }, undefined, undefined, ctx);
      expect(inspected.content[0].text).toContain(parentRunId);
      const untrustedInspect = await tool.execute("inspect-untrusted", { action: "inspect", runId: parentRunId }, undefined, undefined, { ...ctx, isProjectTrusted: () => false });
      expect(untrustedInspect.isError).toBe(true);
      const reusedGrant = await tool.execute("again", { action: "start", workflow: "agent-cat:fixture", inputsJson: '{"subject":"x"}', grantId: startGrant }, undefined, undefined, ctx);
      expect(reusedGrant.isError).toBe(true);
      grantScope = "control";
      await commands.get("workflow-grant")!.handler("", ctx);
      const controlGrant = notices.at(-1)!.match(/grant-[0-9a-f-]+/)![0];
      const untrustedControl = await tool.execute("untrusted", { action: "cancel", runId: parentRunId, grantId: controlGrant }, undefined, undefined, { ...ctx, isProjectTrusted: () => false });
      expect(untrustedControl).toMatchObject({ isError: true, content: [{ text: expect.stringContaining("trusted project") }] });
      const trustedControl = await tool.execute("trusted", { action: "cancel", runId: parentRunId, grantId: controlGrant }, undefined, undefined, ctx);
      expect(trustedControl.isError).not.toBe(true);
      grantScope = "lineage";
      await commands.get("workflow-grant")!.handler("", ctx);
      const lineageGrant = notices.at(-1)!.match(/grant-[0-9a-f-]+/)![0];
      const resumed = await tool.execute("resume", { action: "resume", parentRunId, inputsJson: '{"subject":"x"}', grantId: lineageGrant }, undefined, undefined, ctx);
      expect(resumed.isError).not.toBe(true);
      await until(() => entries.length === 2);
      await commands.get("workflow-grant")!.handler("", ctx);
      const forkGrant = notices.at(-1)!.match(/grant-[0-9a-f-]+/)![0];
      const forked = await tool.execute("fork", { action: "fork", parentRunId, inputsJson: '{"subject":"x"}', forkEditsJson: '[{"type":"drop","occurrenceId":"0"}]', grantId: forkGrant }, undefined, undefined, ctx);
      expect(forked.isError).not.toBe(true);
      const forkRunId = forked.content[0].text.match(/[0-9a-f-]{36}/)![0];
      await until(() => entries.length === 3);
      const forkManifest = JSON.parse(await readFile(join(directory, "state", "runs", forkRunId, "supervisor-manifest.json"), "utf8"));
      expect(forkManifest.lineageEdits).toEqual([{ type: "drop", occurrenceId: "0" }]);
      await commands.get("workflow-diff")!.handler(forkRunId, ctx);
      expect(notices.at(-1)).toContain("answer edits:");
      expect(notices.at(-1)).toContain("occurrence 0:");
      for (const handler of events.get("session_shutdown") ?? []) await handler({}, ctx);
    } finally {
      if (previousRunner === undefined) delete process.env.AGENT_CAT_RUNNER; else process.env.AGENT_CAT_RUNNER = previousRunner;
      if (previousState === undefined) delete process.env.AGENT_CAT_STATE_DIR; else process.env.AGENT_CAT_STATE_DIR = previousState;
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
