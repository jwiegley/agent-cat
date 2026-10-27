import { describe, expect, it } from "vitest";
import { configuredManagerProfiles, configuredRemote, configuredRunners, retentionPolicy, stateDirectory } from "../src/config.ts";

describe("trusted extension configuration", () => {
  it.skipIf(process.env.AGENT_CAT_MANAGER_LIVE === "1")("does not inherit a live manager in the ordinary test run", () => {
    expect(process.env.AGENT_CAT_MANAGER_PROFILE).toBe("");
    expect(process.env.AGENT_CAT_MANAGER_PROFILES).toBe("");
    expect(configuredManagerProfiles()).toEqual({ kind: "local" });
  });

  it("does not inherit the operator's workflow runners", () => {
    expect(process.env.AGENT_CAT_RUNNER).toBe("");
    expect(process.env.AGENT_CAT_RUNNERS).toBe("");
    expect(process.env.AGENT_CAT_RUNNER_ID).toBe("agent-cat");
    expect(configuredRunners("/work")).toEqual([]);
  });

  it("loads runners only from explicit absolute user configuration", () => {
    expect(configuredRunners("/work", {})).toEqual([]);
    expect(() => configuredRunners("/work", { AGENT_CAT_RUNNER: "relative/runner" })).toThrow("must be an absolute path");
    expect(configuredRunners("/work", { AGENT_CAT_RUNNER: "/trusted/runner" })).toEqual([{ id: "agent-cat", executable: "/trusted/runner", allowedCwds: ["/work"] }]);
    expect(configuredRunners("/work", {
      AGENT_CAT_RUNNERS: JSON.stringify([
        { id: "first", executable: "/trusted/first" },
        { id: "second", executable: "/trusted/second", prefixArgs: ["run"], allowedCwds: ["/work", "/other"] },
      ]),
    })).toEqual([
      { id: "first", executable: "/trusted/first", prefixArgs: [], allowedCwds: ["/work"] },
      { id: "second", executable: "/trusted/second", prefixArgs: ["run"], allowedCwds: ["/work", "/other"] },
    ]);
    expect(() => configuredRunners("/work", { AGENT_CAT_RUNNERS: "[]" })).toThrow("non-empty");
    expect(() => configuredRunners("/work", { AGENT_CAT_RUNNER: "/one", AGENT_CAT_RUNNERS: "[]" })).toThrow("not both");
  });

  it("selects native personas only for explicitly configured workflow names", () => {
    const entry = { id: "wf", executable: "/trusted/wf", workflowPersonas: { "translate-en": "sacred-text" } };
    const [runner] = configuredRunners("/work", { AGENT_CAT_RUNNERS: JSON.stringify([entry]) });
    expect(runner.workflowPersonas).toEqual({ "translate-en": "sacred-text" });
    expect(runner.workflowPersonas?.["translate-ar"]).toBeUndefined();
    expect(configuredRunners("/work", { AGENT_CAT_RUNNER: "/trusted/wf" })[0].workflowPersonas).toBeUndefined();
  });

  it.each([[], null, "persona", { workflow: "" }, { workflow: 3 }, { "": "persona" }, { "bad\nname": "persona" }, { workflow: "bad\rname" }].map((value) => ({ value })))(
    "refuses malformed workflow persona mappings $value instead of using the Deck default", ({ value: workflowPersonas }) => {
      expect(() => configuredRunners("/work", { AGENT_CAT_RUNNERS: JSON.stringify([{ id: "wf", executable: "/trusted/wf", workflowPersonas }]) })).toThrow("workflowPersonas must map");
    },
  );

  it("selects service mode only from explicit absolute manager profiles", () => {
    expect(configuredManagerProfiles({})).toEqual({ kind: "local" });
    expect(configuredManagerProfiles({ AGENT_CAT_RUNNER: "/trusted/runner", AGENT_CAT_PI_REMOTE_SOCKET: "/private/socket" })).toEqual({ kind: "local" });
    expect(configuredManagerProfiles({ AGENT_CAT_MANAGER_PROFILE: "/profiles/one.json" })).toEqual({ kind: "service", profiles: ["/profiles/one.json"] });
    const eight = Array.from({ length: 8 }, (_, index) => `/profiles/${index}.json`);
    expect(configuredManagerProfiles({ AGENT_CAT_MANAGER_PROFILES: JSON.stringify(eight) })).toEqual({ kind: "service", profiles: eight });
    expect(() => configuredManagerProfiles({ AGENT_CAT_MANAGER_PROFILE: "/one.json", AGENT_CAT_MANAGER_PROFILES: '["/two.json"]' })).toThrow("not both");
    expect(() => configuredManagerProfiles({ AGENT_CAT_MANAGER_PROFILE: "profiles/one.json" })).toThrow("must be an absolute path");
    expect(() => configuredManagerProfiles({ AGENT_CAT_MANAGER_PROFILES: '["/one.json","relative.json"]' })).toThrow("AGENT_CAT_MANAGER_PROFILES[1] must be an absolute path");
    expect(() => configuredManagerProfiles({ AGENT_CAT_MANAGER_PROFILES: "[]" })).toThrow("1 to 8 paths");
    expect(() => configuredManagerProfiles({ AGENT_CAT_MANAGER_PROFILES: JSON.stringify([...eight, "/profiles/8.json"]) })).toThrow("1 to 8 paths");
    expect(() => configuredManagerProfiles({ AGENT_CAT_MANAGER_PROFILES: '"/one.json"' })).toThrow("1 to 8 paths");
    expect(() => configuredManagerProfiles({ AGENT_CAT_MANAGER_PROFILES: "[/one.json]" })).toThrow("not valid JSON");
    expect(() => configuredManagerProfiles({ AGENT_CAT_MANAGER_PROFILES: "[1]" })).toThrow("must be an absolute path");
    expect(() => configuredManagerProfiles({ AGENT_CAT_MANAGER_PROFILES: '["/one.json","/one.json"]' })).toThrow("duplicated");
  });

  it("requires complete remote and private-state configuration", () => {
    expect(configuredRemote({ AGENT_CAT_PI_REMOTE_SOCKET: "/private/socket" })).toEqual({ socket: "/private/socket", sessionId: undefined });
    expect(() => configuredRemote({ AGENT_CAT_PI_REMOTE_SESSION: "session" })).toThrow("SOCKET is required");
    expect(() => stateDirectory({ AGENT_CAT_STATE_DIR: "relative" })).toThrow("must be absolute");
  });

  it("validates configurable retention bounds", () => {
    expect(retentionPolicy({})).toEqual({ days: 30, maxRuns: 100 });
    expect(retentionPolicy({ AGENT_CAT_RETENTION_DAYS: "0", AGENT_CAT_MAX_RUNS: "7" })).toEqual({ days: 0, maxRuns: 7 });
    expect(() => retentionPolicy({ AGENT_CAT_RETENTION_DAYS: "-1" })).toThrow("unsigned decimal");
  });
});
