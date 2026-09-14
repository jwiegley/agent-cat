import { test } from "vitest";

test("remote Pi discovery, exclusive adapter ownership, controls, and reattachment", async () => {
  await import("./pi-remote-current.mjs");
});
