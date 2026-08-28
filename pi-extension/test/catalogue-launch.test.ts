import { mkdir, mkdtemp, readFile, readdir, realpath, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { discoverRunner, readHelp } from "../src/catalogue.ts";
import { prepareLaunch, preflightLineage, previewPlan } from "../src/launch.ts";
import type { RunnerConfig } from "../src/types.ts";

const created: string[] = [];
afterEach(async () => Promise.all(created.splice(0).map((path) => rm(path, { recursive: true, force: true }))));

async function setup(): Promise<{ directory: string; config: RunnerConfig }> {
  const directory = await mkdtemp(join(tmpdir(), "agent-cat-extension-"));
  created.push(directory);
  return {
    directory,
    config: { id: "fixture", executable: resolve("test/fixtures/runner.mjs"), allowedCwds: [directory] },
  };
}

describe("catalogue and launch", () => {
  it("discovers strict descriptors and preserves exact help", async () => {
    const { directory, config } = await setup();
    const [descriptor] = await discoverRunner(config, directory);
    expect(descriptor.name).toBe("fixture");
    expect(descriptor.inputs).toEqual(["subject"]);
    expect(await readHelp(config, "fixture", directory)).toBe("exact fixture help\n");
  });

  it("uses private input files and keeps values out of argv and manifest", async () => {
    const { directory, config } = await setup();
    const [descriptor] = await discoverRunner(config, directory);
    const prepared = await prepareLaunch({
      runner: config,
      descriptor,
      cwd: directory,
      stateDir: join(directory, "state"),
      inputs: { subject: "secret; $(touch nope)\nnext" },
      targetKind: "scripted",
      targetArgs: ["--scripted"],
    });
    expect(prepared.args.join(" ")).not.toContain("secret");
    const input = prepared.inputFiles.get("subject")!;
    expect(await readFile(input, "utf8")).toBe("secret; $(touch nope)\nnext");
    expect((await stat(input)).mode & 0o777).toBe(0o600);
    const manifest = await readFile(join(prepared.storeDir, "supervisor-manifest.json"), "utf8");
    expect(manifest).not.toContain("secret");
    expect(prepared.manifest.programHash).toMatch(/^[0-9a-f]{64}$/);
    expect(prepared.manifest.targetKind).toBe("scripted");
  });

  it("removes private preview inputs after reading the raw plan", async () => {
    const { directory, config } = await setup();
    const [descriptor] = await discoverRunner(config, directory);
    const stateDir = join(directory, "state");
    const plan = await previewPlan({ runner: config, descriptor, cwd: directory, stateDir, inputs: { subject: "preview secret" } });
    expect(plan.program).toEqual({ main: { fixture: true }, fns: [] });
    expect(await readdir(join(stateDir, "previews"))).toEqual([]);
  });

  it("removes a partially prepared run when plan inspection fails", async () => {
    const { directory, config } = await setup();
    const [descriptor] = await discoverRunner(config, directory);
    const stateDir = join(directory, "failed-state");
    process.env.FIXTURE_PLAN_FAIL = "1";
    try {
      await expect(prepareLaunch({
        runner: config, descriptor, cwd: directory, stateDir, inputs: { subject: "secret" }, targetKind: "scripted", targetArgs: ["--scripted"],
      })).rejects.toThrow("plan failed");
      expect(await readdir(join(stateDir, "runs"))).toEqual([]);
    } finally {
      delete process.env.FIXTURE_PLAN_FAIL;
    }
  });

  it("prepares immutable lineage argv only from a private parent runtime", async () => {
    const { directory, config } = await setup();
    const [descriptor] = await discoverRunner(config, directory);
    const stateDir = join(directory, "state");
    const parentRuntimeDir = join(stateDir, "runs", "parent", "runtime");
    await mkdir(parentRuntimeDir, { recursive: true, mode: 0o700 });
    const prepared = await prepareLaunch({
      runner: config, descriptor, cwd: directory, stateDir, inputs: { subject: "same input" }, targetKind: "scripted", targetArgs: ["--scripted"],
      lineage: { operation: "resume", parentRunId: "parent", parentRuntimeDir },
    });
    expect(prepared.args.slice(0, 4)).toEqual(["machine-resume", prepared.manifest.runId, await realpath(parentRuntimeDir), "fixture"]);
    expect(prepared.manifest).toMatchObject({ parentRunId: "parent", lineage: "resume" });
    await expect(prepareLaunch({
      runner: config, descriptor, cwd: directory, stateDir, inputs: { subject: "x" }, targetKind: "scripted", targetArgs: ["--scripted"],
      lineage: { operation: "fork", parentRunId: "outside", parentRuntimeDir: directory },
    })).rejects.toThrow("outside the configured run-state root");
  });

  it("refuses lineage preflight before creating a child run directory", async () => {
    const { directory, config } = await setup();
    const [descriptor] = await discoverRunner(config, directory);
    const stateDir = join(directory, "state");
    const parentRuntimeDir = join(stateDir, "runs", "parent", "runtime");
    await mkdir(parentRuntimeDir, { recursive: true, mode: 0o700 });
    process.env.FIXTURE_LINEAGE_REFUSE = "1";
    try {
      await expect(preflightLineage({ runner: config, descriptor, cwd: directory, stateDir, inputs: { subject: "x" }, targetArgs: ["--scripted"], operation: "resume", parentRuntimeDir })).rejects.toThrow();
      expect(await readdir(join(stateDir, "runs"))).toEqual(["parent"]);
    } finally {
      delete process.env.FIXTURE_LINEAGE_REFUSE;
    }
  });

  it("rejects missing inputs and cwd escapes", async () => {
    const { directory, config } = await setup();
    const [descriptor] = await discoverRunner(config, directory);
    await expect(prepareLaunch({ runner: config, descriptor, cwd: directory, stateDir: join(directory, "state"), inputs: {}, targetKind: "scripted", targetArgs: ["--scripted"] })).rejects.toThrow("inputs must be exactly");
    await expect(prepareLaunch({ runner: config, descriptor, cwd: tmpdir(), stateDir: join(directory, "state"), inputs: { subject: "x" }, targetKind: "scripted", targetArgs: ["--scripted"] })).rejects.toThrow("outside configured roots");
    await expect(prepareLaunch({ runner: config, descriptor, cwd: directory, stateDir: join(directory, "state"), inputs: { subject: "x" }, targetKind: "acp", targetArgs: ["--engine", "acp", "--adapter-arg", "--api-key", "secret-value"] })).rejects.toThrow("credential-bearing target argv is forbidden");
    await expect(prepareLaunch({ runner: config, descriptor, cwd: directory, stateDir: join(directory, "state"), inputs: { subject: "x" }, targetKind: "acp", targetArgs: ["--header", "X-API-Key: secret-value"] })).rejects.toThrow("credential-bearing target argv is forbidden");
    await expect(prepareLaunch({ runner: config, descriptor, cwd: directory, stateDir: join(directory, "state"), inputs: { subject: "x" }, targetKind: "acp", targetArgs: ["--adapter-arg", "--header", "--adapter-arg", "X-Auth-Token: secret-value"] })).rejects.toThrow("credential-bearing target argv is forbidden");
    await expect(prepareLaunch({ runner: config, descriptor, cwd: directory, stateDir: join(directory, "state"), inputs: { subject: "x" }, targetKind: "acp", targetArgs: ["--engine", "acp", "--adapter", "/opt/tokenizer/bin/adapter", "--adapter-arg", "--max-tokens", "--adapter-arg", "100"] })).resolves.toBeDefined();
  });
});
