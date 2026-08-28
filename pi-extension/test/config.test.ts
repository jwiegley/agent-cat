import { describe, expect, it } from "vitest";
import { configuredRemote, configuredRunners, retentionPolicy, stateDirectory } from "../src/config.ts";

describe("trusted extension configuration", () => {
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
