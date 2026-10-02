import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { normalizeContext } from "@earendil-works/pi-ai";
import { describe, expect, it } from "vitest";
import type { ExtensionAPI, ProviderConfig } from "@earendil-works/pi-coding-agent";
import fauxModel, { FAUX_FIXED_REPLY, FAUX_MODEL, FAUX_PROVIDER, FAUX_SCRIPT_VARIABLE, fauxReply, parseFauxScript } from "./fixtures/faux-model.ts";

describe("faux model fixture", () => {
  it("gives fixed text replies for an empty script", () => {
    expect(parseFauxScript(" \n")).toEqual([]);
    const reply = fauxReply([], 2);
    expect(reply.content).toEqual([{ type: "text", text: `${FAUX_FIXED_REPLY} 2` }]);
    expect(reply.stopReason).toBe("stop");
  });

  it("gives the scripted replies in order, then the fixed replies", () => {
    const script = parseFauxScript(JSON.stringify([
      { text: "first" },
      [{ text: "calling" }, { toolCall: { name: "agent_cat_workflow", arguments: { action: "manager-status" }, id: "call-1" } }],
    ]));
    expect(fauxReply(script, 1).content).toEqual([{ type: "text", text: "first" }]);
    const second = fauxReply(script, 2);
    expect(second.stopReason).toBe("toolUse");
    expect(second.content).toEqual([
      { type: "text", text: "calling" },
      { type: "toolCall", id: "call-1", name: "agent_cat_workflow", arguments: { action: "manager-status" } },
    ]);
    expect(fauxReply(script, 3).content).toEqual([{ type: "text", text: `${FAUX_FIXED_REPLY} 3` }]);
  });

  it("refuses a script that is not an array of text and tool-call blocks", () => {
    expect(() => parseFauxScript("{}")).toThrow(/JSON array/);
    expect(() => parseFauxScript(JSON.stringify([{ text: "a", extra: 1 }]))).toThrow(/neither/);
    expect(() => parseFauxScript(JSON.stringify([{ toolCall: { name: "x", arguments: [] } }]))).toThrow(/arguments/);
  });

  it("registers a provider whose stream gives the script replies without a network request", async () => {
    const directory = mkdtempSync(join(tmpdir(), "faux-model-"));
    const previous = process.env[FAUX_SCRIPT_VARIABLE];
    try {
      const script = join(directory, "script.json");
      writeFileSync(script, JSON.stringify([{ text: "scripted" }]));
      process.env[FAUX_SCRIPT_VARIABLE] = script;
      const registered: Array<[string, ProviderConfig]> = [];
      fauxModel({ registerProvider: (name: string, config: ProviderConfig) => { registered.push([name, config]); } } as unknown as ExtensionAPI);
      expect(registered.map(([name, config]) => [name, config.models?.map((model) => model.id)])).toEqual([[FAUX_PROVIDER, [FAUX_MODEL]]]);
      const config = registered[0]![1];
      const model = { id: FAUX_MODEL, name: FAUX_MODEL, api: config.api!, provider: FAUX_PROVIDER, baseUrl: config.baseUrl!, reasoning: false,
        input: ["text" as const], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 128000, maxTokens: 16384 };
      const first = await config.streamSimple!(model, normalizeContext({ messages: [] })).result();
      const second = await config.streamSimple!(model, normalizeContext({ messages: [] })).result();
      expect([first.content, second.content]).toEqual([[{ type: "text", text: "scripted" }], [{ type: "text", text: `${FAUX_FIXED_REPLY} 2` }]]);
      expect(first.provider).toBe(FAUX_PROVIDER);
    } finally {
      if (previous === undefined) delete process.env[FAUX_SCRIPT_VARIABLE];
      else process.env[FAUX_SCRIPT_VARIABLE] = previous;
      rmSync(directory, { recursive: true, force: true });
    }
  });
});
