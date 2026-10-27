import { createHash } from "node:crypto";
import { mkdir, mkdtemp, readFile, readdir, realpath, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import extension from "../src/index.ts";
import { discoverRunner } from "../src/catalogue.ts";
import { prepareRoutedLaunch, type NativeLaunch } from "../src/frontend.ts";
import { parseLaunchManifest, RunSupervisor } from "../src/supervisor.ts";
import type { RunnerConfig } from "../src/types.ts";

const binary = process.env.AGENT_CAT_E2E_ROUTING_RUNNER;
const created: string[] = [];
const pending: NativeLaunch[] = [];
const supervisors: RunSupervisor[] = [];
afterEach(async () => {
  await Promise.all(pending.splice(0).map((held) => held.discard()));
  await Promise.all(supervisors.splice(0).map((supervisor) => supervisor.shutdown()));
  vi.unstubAllEnvs();
  await Promise.all(created.splice(0).map((path) => rm(path, { recursive: true, force: true })));
});

// These cases use the native frontend and the existing local ACP fixture, never a paid model.
describe.runIf(Boolean(binary))("configured /wf native routing", () => {
  it("discards a held target without a prompt or run, and reviews the exact prepared invocation", async () => {
    const test = await setup();
    const held = await prepare(test);
    expect(await runNames(test.state)).toEqual([]);
    expect(await adapterTranscript(test.adapterLog)).not.toContain("prompt matched");
    expect(held.review).toContain('"runnerAlias":"configured-wf"');
    expect(held.review).toContain('"persona":"fixture"');
    expect(held.review).toContain('"backend":"acp:');
    expect(held.review).toContain("stub-default");
    expect(held.review).toContain(JSON.stringify(held.prepared.manifest.targetArgs));
    expect(held.prepared.manifest.targetArgs).toContain("--scratch");
    expect(held.review).not.toContain("PRIVATE SOURCE");
    expect(held.prepared.args).not.toContain("PRIVATE SOURCE");
    expect(held.prepared.frontend?.child.pid).toBeGreaterThan(0);
    await held.discard();
    expect(held.prepared.frontend?.child.exitCode).toBe(0);
    expect(await runNames(test.state)).toEqual([]);
    expect(await adapterTranscript(test.adapterLog)).not.toContain("prompt matched");
  }, 60_000);

  it("preserves native policy integers beyond JavaScript's safe range in the approval", async () => {
    const test = await setup();
    const document = await readFile(test.routing, "utf8");
    expect(document).toContain('"max-output":65536');
    await writeFile(test.routing, document.replace('"max-output":65536', '"max-output":9007199254740993'));
    const held = await prepare(test);
    expect(held.review).toContain('"maxOutput":9007199254740993');
    expect(held.review).not.toContain('"maxOutput":9007199254740992');
    await held.discard();
    expect(await runNames(test.state)).toEqual([]);
  }, 60_000);

  it("executes the held target after configuration changes and restores its native manifest", async () => {
    const test = await setup();
    const held = await prepare(test);
    await writeFile(test.routing, "version: 99\n");
    const supervisor = new RunSupervisor();
    supervisors.push(supervisor);
    const result = await supervisor.start(held.prepared).finished;
    expect(result, `${result.failureClass}: ${result.failure}`).toMatchObject({ status: "succeeded", protocolVersion: 2, billFresh: "1" });
    expect(await adapterTranscript(test.adapterLog)).toContain("prompt matched");
    const manifest = parseLaunchManifest(JSON.parse(await readFile(join(held.prepared.storeDir, "supervisor-manifest.json"), "utf8")));
    expect(manifest).toMatchObject({ frontendManifestVersion: 3, persona: "fixture", targetKind: "routing", invocation: { runnerAlias: "configured-wf", prefixArgs: test.runner.prefixArgs } });
    expect(manifest.targetArgs).toEqual(held.prepared.manifest.targetArgs);
    expect(manifest.policyDigest).toBe(held.prepared.manifest.policyDigest);
    expect(await readFile(join(held.prepared.storeDir, "inputs", "1.txt"), "utf8")).toBe("PRIVATE SOURCE\n  second line\n");
    expect((await stat(join(held.prepared.storeDir, "inputs", "1.txt"))).mode & 0o777).toBe(0o600);
    const restored = new RunSupervisor();
    supervisors.push(restored);
    await restored.restore(test.state);
    expect(restored.get(result.runId)?.snapshot).toMatchObject({ status: "succeeded" });
    expect(restored.get(result.runId)?.manifest.invocation?.runnerAlias).toBe("configured-wf");
  }, 60_000);

  it.each(["file", "text"])("binds /wf %s input privately through native approval", async (source) => {
    const test = await setup();
    const notices: string[] = [];
    const entries: Array<{ status: string; storeDir: string }> = [];
    const confirmations: string[] = [];
    const commands = new Map<string, { handler: (args: string, ctx: unknown) => Promise<void> }>();
    const events = new Map<string, Array<(event: unknown, ctx: unknown) => Promise<unknown>>>();
    vi.stubEnv("AGENT_CAT_RUNNER", "");
    vi.stubEnv("AGENT_CAT_RUNNERS", JSON.stringify([{ ...test.runner, workflowPersonas: { "pinned-sources": "fixture" } }]));
    vi.stubEnv("AGENT_CAT_STATE_DIR", test.state);
    vi.stubEnv("AGENTDECK_INSTANCE_ID", "parent-deck-must-not-receive-source");
    extension({
      registerEntryRenderer: () => {}, registerTool: () => {}, sendUserMessage: () => {},
      registerCommand: (name: string, command: unknown) => commands.set(name, command as never),
      appendEntry: (_type: string, data: unknown) => entries.push(data as never),
      on: (name: string, handler: (event: unknown, ctx: unknown) => Promise<unknown>) => events.set(name, [...(events.get(name) ?? []), handler]),
    } as never);
    let approve = false;
    const ctx = {
      cwd: test.directory, mode: "tui", hasUI: true, isProjectTrusted: () => true, isIdle: () => true,
      abort: () => {}, sessionManager: { getBranch: () => ["PARENT CONTEXT MUST NOT BE FORWARDED"] },
      ui: {
        editor: async (_title: string) => "", select: () => { throw new Error("named /wf must not select a target"); },
        confirm: async (_title: string, message: string) => {
          confirmations.push(message);
          expect(await runNames(test.state)).toEqual([]);
          expect(await adapterTranscript(test.adapterLog)).not.toContain("prompt matched");
          return approve;
        },
        notify: (message: string) => notices.push(message), setWidget: () => {}, setStatus: () => {},
      },
    };
    for (const handler of events.get("session_start") ?? []) await handler({}, ctx);
    try {
      const file = source === "file" ? join(test.directory, "input with spaces.docx") : "";
      const text = source === "text" ? "PRIVATE SOURCE\n  second line\n" : "";
      const command = `configured-wf:pinned-sources${file ? ` ${file}` : `\n\n${text}`}`;
      await commands.get("wf")!.handler(command, ctx);
      expect(await runNames(test.state)).toEqual([]);
      expect(entries).toEqual([]);
      approve = true;
      await commands.get("wf")!.handler(command, ctx);
      expect(confirmations, notices.join("\n")).toHaveLength(2);
      await until(() => entries.length === 1);
      expect(entries[0].status, notices.join("\n")).toBe("succeeded");
      const manifest = parseLaunchManifest(JSON.parse(await readFile(join(entries[0].storeDir, "supervisor-manifest.json"), "utf8")));
      expect(manifest.inputHashes).toEqual({ file: hash(file), text: hash(text) });
      expect(manifest.targetKind).toBe("routing");
      expect(manifest.targetArgs).not.toContain("parent-deck-must-not-receive-source");
      expect(await readFile(join(entries[0].storeDir, "inputs", "0.txt"), "utf8")).toBe(file);
      expect(await readFile(join(entries[0].storeDir, "inputs", "1.txt"), "utf8")).toBe(text);
      const program = await readFile(join(entries[0].storeDir, "runtime", "program.json"), "utf8");
      if (file) expect(program).toContain(file);
      if (text) expect(program).toContain("PRIVATE SOURCE");
      expect(program).not.toContain("PARENT CONTEXT MUST NOT BE FORWARDED");
      expect(confirmations).toHaveLength(2);
      if (file) expect(confirmations[1]).not.toContain(file);
      if (text) expect(confirmations[1]).not.toContain(text);
      expect(confirmations[1]).not.toContain("PARENT CONTEXT MUST NOT BE FORWARDED");
      if (source === "text") {
        ctx.ui.confirm = async () => true;
        ctx.ui.editor = async (title: string) => title === "Input: text" ? text : file;
        await commands.get("wf-resume")!.handler(manifest.runId, ctx);
        expect(notices.filter((message) => message.startsWith("Started ")), notices.join("\n")).toHaveLength(2);
        await until(() => entries.length === 2);
        expect(entries[1].status, notices.join("\n")).toBe("succeeded");
        const child = parseLaunchManifest(JSON.parse(await readFile(join(entries[1].storeDir, "supervisor-manifest.json"), "utf8")));
        expect(child).toMatchObject({ runnerId: "configured-wf", parentRunId: manifest.runId, lineage: "resume", targetArgs: manifest.targetArgs });
      }
    } finally {
      for (const handler of events.get("session_shutdown") ?? []) await handler({}, ctx);
    }
  }, 60_000);

  it.each(["missing-persona", "missing-pin"])("refuses %s before approval without Deck fallback", async (fault) => {
    const test = await setup(fault);
    await expect(prepare(test, fault === "missing-persona" ? "unknown" : "fixture")).rejects.toThrow();
    expect(await runNames(test.state)).toEqual([]);
    expect(await adapterTranscript(test.adapterLog)).not.toContain("prompt matched");
  }, 60_000);

  it.each(["missing-adapter", "missing-model"])("reports %s honestly after approval without another model", async (fault) => {
    const test = await setup(fault);
    const held = await prepare(test);
    expect(await adapterTranscript(test.adapterLog)).not.toContain("prompt matched");
    const supervisor = new RunSupervisor();
    supervisors.push(supervisor);
    const result = await supervisor.start(held.prepared).finished;
    expect(result, `${result.failureClass}: ${result.failure}`).toMatchObject({ status: "failed" });
    expect(result.result).toBeUndefined();
    expect(await adapterTranscript(test.adapterLog)).not.toContain("prompt matched");
    expect(held.prepared.manifest.targetArgs).not.toContain("--session");
  }, 60_000);

  it("rejects an aborted preparation rather than accepting stale approval", async () => {
    const test = await setup();
    const controller = new AbortController();
    const held = await prepareRoutedLaunch({ ...test, cwd: test.directory, stateDir: test.state, persona: "fixture", inputs: { file: "", text: "private" }, signal: controller.signal });
    pending.push(held);
    controller.abort();
    expect(() => held.prepared.frontend!.approve()).toThrow("native preparation is no longer available");
    await held.discard();
    expect(await runNames(test.state)).toEqual([]);
    expect(await adapterTranscript(test.adapterLog)).not.toContain("prompt matched");
  }, 60_000);

  it("refuses oversized pasted text before spawning the prepared worker", async () => {
    const test = await setup();
    await expect(prepareRoutedLaunch({ ...test, cwd: test.directory, stateDir: test.state, persona: "fixture", inputs: { file: "", text: "x".repeat(2 * 1024 * 1024) } })).rejects.toThrow("native preparation request exceeds 2097152 bytes");
    expect(await runNames(test.state)).toEqual([]);
    expect(await adapterTranscript(test.adapterLog)).not.toContain("prompt matched");
  }, 60_000);

  it("bounds preparation diagnostics before transferring them to the supervisor", async () => {
    const test = await setup("noisy");
    const held = await prepare(test);
    const supervisor = new RunSupervisor();
    supervisors.push(supervisor);
    expect(await supervisor.start(held.prepared).finished).toMatchObject({ status: "succeeded" });
    const diagnostics = await readFile(join(held.prepared.storeDir, "stderr.log"), "utf8");
    expect(diagnostics).toMatch(/\[REDACTED OVERLONG (?:PREPARATION )?DIAGNOSTIC\]/);
    expect(diagnostics).not.toContain("x".repeat(100));
  }, 60_000);

  it("cancels the native run through its retained control pipe", async () => {
    const test = await setup();
    const held = await prepare(test);
    const supervisor = new RunSupervisor();
    supervisors.push(supervisor);
    const run = supervisor.start(held.prepared);
    await run.cancel();
    expect(await run.finished).toMatchObject({ status: "cancelled" });
    const frames = (await readFile(join(held.prepared.storeDir, "live-events.ndjson"), "utf8")).trimEnd().split("\n").map((line) => JSON.parse(line));
    expect(frames.some(({ event }) => event.type === "run.cancelled")).toBe(true);
    expect(await adapterTranscript(test.adapterLog)).not.toContain("prompt matched");
  }, 60_000);
});

async function setup(fault?: string) {
  const directory = await realpath(await mkdtemp(join(tmpdir(), "agent-cat-wf-routing-")));
  created.push(directory);
  const config = join(directory, "config");
  await mkdir(join(config, "agent-cat"), { recursive: true, mode: 0o700 });
  const adapter = join(directory, "adapter");
  const adapterLog = join(directory, "adapter.log");
  await writeFile(adapter, `#!/bin/sh\nexec python3 '${resolve("../engine/acp/test/stub_adapter.py")}' 2>>'${adapterLog}'\n`, { mode: 0o700 });
  const routing = join(config, "agent-cat", "routing.yaml");
  await writeFile(routing, JSON.stringify({
    version: 2, "default-persona": "fixture", secrets: {},
    engines: { local: { backend: `acp:${fault === "missing-adapter" ? join(directory, "absent-adapter") : adapter}`, provider: "fixture" } },
    models: { selected: { engine: "local", select: [{ exact: fault === "missing-model" ? "absent-model" : "stub-default" }] } },
    personas: { fixture: { engines: ["local"], models: ["selected"], profiles: fault === "missing-pin" ? {} : { deep: { chain: [{ model: "selected", thinking: "high", "max-output": 65536 }] } } } },
  }), { mode: 0o600 });
  let executable = binary!;
  if (fault === "noisy") {
    executable = join(directory, "noisy-runner");
    await writeFile(executable, `#!/bin/sh\nif [ "$1" = frontend ]; then python3 -c 'import sys; sys.stderr.write("x" * 70000 + "\\n")'; fi\nexec '${binary!}' "$@"\n`, { mode: 0o700 });
  }
  const runner: RunnerConfig = {
    id: "configured-wf", executable: "/usr/bin/env", allowedCwds: [directory],
    prefixArgs: ["-u", "AGENT_CAT_PERSONA", `XDG_CONFIG_HOME=${config}`, `XDG_CACHE_HOME=${join(directory, "cache")}`, executable],
  };
  const descriptor = (await discoverRunner(runner, directory)).find(({ name }) => name === "pinned-sources");
  if (!descriptor) throw new Error("pinned-sources native fixture is missing");
  return { directory, runner, descriptor, state: join(directory, "state"), routing, adapterLog };
}

async function prepare(test: Awaited<ReturnType<typeof setup>>, persona = "fixture") {
  const held = await prepareRoutedLaunch({ ...test, cwd: test.directory, stateDir: test.state, persona, inputs: { file: "", text: "PRIVATE SOURCE\n  second line\n" } });
  pending.push(held);
  return held;
}
async function runNames(state: string): Promise<string[]> {
  try { return await readdir(join(state, "runs")); }
  catch (error) { if ((error as NodeJS.ErrnoException).code === "ENOENT") return []; throw error; }
}
async function adapterTranscript(path: string): Promise<string> {
  try { return await readFile(path, "utf8"); }
  catch (error) { if ((error as NodeJS.ErrnoException).code === "ENOENT") return ""; throw error; }
}
function hash(text: string): string { return createHash("sha256").update(text).digest("hex"); }
async function until(predicate: () => boolean): Promise<void> {
  const deadline = Date.now() + 20_000;
  while (!predicate()) {
    if (Date.now() > deadline) throw new Error("native /wf fixture timed out");
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}
