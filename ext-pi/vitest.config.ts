import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    env: {
      AGENT_CAT_RUNNER: "",
      AGENT_CAT_RUNNERS: "",
      AGENT_CAT_RUNNER_ID: "agent-cat",
      ...(process.env.AGENT_CAT_MANAGER_LIVE === "1" ? {} : {
        AGENT_CAT_MANAGER_PROFILE: "",
        AGENT_CAT_MANAGER_PROFILES: "",
      }),
    },
    fileParallelism: false,
    testTimeout: 15_000,
  },
});
