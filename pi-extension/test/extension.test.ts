import { mkdtemp, readFile, readdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import extension from "../src/index.ts";

const created: string[] = [];
afterEach(async () => Promise.all(created.splice(0).map((path) => rm(path, { recursive: true, force: true }))));

describe("Pi extension lifecycle", () => {
  it("shows an active widget and appends a terminal transcript entry", async () => {
    const directory = await mkdtemp(join(tmpdir(), "agent-cat-extension-ui-"));
    created.push(directory);
    const previousRunner = process.env.AGENT_CAT_RUNNER;
    const previousState = process.env.AGENT_CAT_STATE_DIR;
    process.env.AGENT_CAT_RUNNER = resolve("test/fixtures/runner.mjs");
    process.env.AGENT_CAT_STATE_DIR = join(directory, "state");
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
      const ui = {
        select: async (title: string) => title === "Execution target" ? "scripted (offline)" : undefined,
        editor: async () => "subject",
        confirm: async () => true,
        notify: () => {},
        setWidget: (_id: string, value: unknown) => widgets.push(value),
        setStatus: () => {},
        custom: async () => undefined,
      };
      const ctx = { cwd: directory, mode: "tui", hasUI: true, isProjectTrusted: () => true, ui, isIdle: () => true, abort: () => {}, sessionManager: { getBranch: () => [] } };
      for (const handler of events.get("session_start") ?? []) await handler({ type: "session_start" }, ctx);
      await commands.get("workflow")!.handler("agent-cat:fixture", ctx);
      await until(() => entries.length === 1);
      expect(entries[0]).toEqual({ type: "agent-cat-run", data: expect.objectContaining({ status: "succeeded", billFresh: "1", billMemo: "1", storeDir: expect.stringContaining("/runs/") }) });
      expect(widgets.some((value) => typeof value === "function")).toBe(true);
      await until(() => widgets.at(-1) === undefined);
      for (const handler of events.get("session_shutdown") ?? []) await handler({ type: "session_shutdown" }, ctx);
    } finally {
      if (previousRunner === undefined) delete process.env.AGENT_CAT_RUNNER;
      else process.env.AGENT_CAT_RUNNER = previousRunner;
      if (previousState === undefined) delete process.env.AGENT_CAT_STATE_DIR;
      else process.env.AGENT_CAT_STATE_DIR = previousState;
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
    await commands.get("workflow")!.handler("agent-cat:fixture", ctx);
    expect(notices).toEqual([expect.stringContaining("requires interactive approval")]);
    notices.length = 0;
    await commands.get("workflow")!.handler("agent-cat:fixture", {
      ...ctx, hasUI: true, isProjectTrusted: () => false,
    });
    expect(notices).toEqual([expect.stringContaining("requires a trusted project")]);
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
      expect(commands.has("workflows")).toBe(false);
      await commands.get("wf")!.handler("", ctx);
      expect(notices.at(-1)).toContain("agent-cat:fixture");
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
