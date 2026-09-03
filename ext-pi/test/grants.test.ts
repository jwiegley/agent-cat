import { describe, expect, it } from "vitest";
import { MutationGrants } from "../src/grants.ts";

describe("model mutation grants", () => {
  it("are scoped, expiring, and one-time", () => {
    const grants = new MutationGrants();
    const control = grants.issue("control");
    expect(grants.consume(control, "start")).toBe(false);
    expect(grants.consume(control, "control")).toBe(false);
    const all = grants.issue("all");
    expect(grants.consume(all, "lineage")).toBe(true);
    expect(grants.consume(all, "control")).toBe(false);
    expect(grants.consume(grants.issue("start", -1), "start")).toBe(false);
  });
});
