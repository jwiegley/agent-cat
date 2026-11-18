import { createHash } from "node:crypto";
import { mkdir, mkdtemp, readFile, readdir, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { formatLocalResult, readLocalResult, saveLocalResult, shownResultText, LOCAL_RESULT_DISPLAY_LIMIT } from "../src/local-result.ts";
import { resultSummary } from "../src/monitor.ts";
import type { ResultRef } from "../src/types.ts";

const created: string[] = [];
afterEach(async () => Promise.all(created.splice(0).map((path) => rm(path, { recursive: true, force: true }))));

/** A run store whose `runtime/result.json` is the canonical artifact of `value`. */
async function storeWith(runId: string, code: unknown, value: unknown, valueJson = JSON.stringify(value)): Promise<{ storeDir: string; reference: ResultRef }> {
  const storeDir = await mkdtemp(join(tmpdir(), "agent-cat-local-result-"));
  created.push(storeDir);
  await mkdir(join(storeDir, "runtime"), { mode: 0o700 });
  const artifact = Buffer.from(`{"artifactVersion":1,"result":{"code":${JSON.stringify(code)},"value":${valueJson}},"runId":${JSON.stringify(runId)}}\n`);
  await writeFile(join(storeDir, "runtime", "result.json"), artifact, { mode: 0o600 });
  return {
    storeDir,
    reference: {
      artifactVersion: 1, path: "result.json", sha256: createHash("sha256").update(artifact).digest("hex"),
      bytes: String(artifact.length), code, preview: "a preview that is not the value",
    } as ResultRef,
  };
}

describe("the verified result of a local run", () => {
  it("gives the text of a text result exactly, line breaks included", async () => {
    const value = "O people of the world!\n\n---\nQuality notes\nAll sections reviewed.";
    const { storeDir, reference } = await storeWith("run-1", "text", value);
    const result = await readLocalResult(storeDir, "run-1", reference);
    expect(result).toEqual({ code: "text", text: value });
  });

  it("gives a result that is not a string as the JSON of the artifact, exactly", async () => {
    const { storeDir, reference } = await storeWith("run-2", "ack", { done: true, items: [1, 2] });
    const result = await readLocalResult(storeDir, "run-2", reference);
    expect(result).toEqual({ code: "ack", text: '{"done":true,"items":[1,2]}' });
    // JSON.parse rounds this integer to 9007199254740992. The text keeps it.
    const large = await storeWith("run-2b", "count", 0, "9007199254740993");
    expect((await readLocalResult(large.storeDir, "run-2b", large.reference)).text).toBe("9007199254740993");
    const nested = await storeWith("run-2c", "counts", 0, '{"n":[9007199254740993,1.5]}');
    expect((await readLocalResult(nested.storeDir, "run-2c", nested.reference)).text).toBe('{"n":[9007199254740993,1.5]}');
  });

  it("refuses an artifact whose bytes, digest or run differ from the terminal event", async () => {
    const { storeDir, reference } = await storeWith("run-3", "text", "the result");
    await expect(readLocalResult(storeDir, "another-run", reference)).rejects.toThrow("run id");
    await expect(readLocalResult(storeDir, "run-3", { ...reference, sha256: "0".repeat(64) })).rejects.toThrow("digest");
    await writeFile(join(storeDir, "runtime", "result.json"), "{}\n");
    await expect(readLocalResult(storeDir, "run-3", reference)).rejects.toThrow("byte count");
    await rm(join(storeDir, "runtime", "result.json"));
    await expect(readLocalResult(storeDir, "run-3", reference)).rejects.toThrow();
  });

  it("names the run, the workflow and the verified reference above the text", async () => {
    const { storeDir, reference } = await storeWith("run-4", "text", "first line\nsecond line");
    const result = await readLocalResult(storeDir, "run-4", reference);
    const shown = formatLocalResult({ runId: "run-4", workflow: "translate-en", reference, result });
    expect(shown.split("\n")).toEqual([
      "agent-cat run-4: result of translate-en",
      `verified ${reference.bytes} bytes, SHA-256 ${reference.sha256}, code "text"`,
      "",
      "first line",
      "second line",
    ]);
    expect(resultSummary(reference)).toBe(`result: ${reference.bytes} bytes, SHA-256 ${reference.sha256}, code "text"`);
  });

  it("cuts a long text at the display limit and says how to get the rest", async () => {
    const value = "x".repeat(LOCAL_RESULT_DISPLAY_LIMIT + 500);
    const { storeDir, reference } = await storeWith("run-5", "text", value);
    const result = await readLocalResult(storeDir, "run-5", reference);
    const shown = formatLocalResult({ runId: "run-5", workflow: undefined, reference, result });
    expect(shown).toContain("agent-cat run-5: result of the workflow");
    expect(shown).toContain("x".repeat(LOCAL_RESULT_DISPLAY_LIMIT));
    expect(shown).not.toContain("x".repeat(LOCAL_RESULT_DISPLAY_LIMIT + 1));
    expect(shown.endsWith(`[The result has ${value.length} characters and the first ${LOCAL_RESULT_DISPLAY_LIMIT} are shown. /wf-result run-5 PATH saves all of it to a new file.]`)).toBe(true);
    const exact = { code: "text", text: "y".repeat(LOCAL_RESULT_DISPLAY_LIMIT) };
    expect(shownResultText("run-5", exact)).toBe(exact.text);
  });

  it("counts and cuts by code point, so the cut never divides a surrogate pair", () => {
    // Each of these characters is two UTF-16 code units.
    const text = "\u{1F600}".repeat(LOCAL_RESULT_DISPLAY_LIMIT + 1);
    const [first, note] = shownResultText("run-6", { code: "text", text }).split("\n");
    expect(first).toBe("\u{1F600}".repeat(LOCAL_RESULT_DISPLAY_LIMIT));
    expect(Array.from(first).every((character) => character === "\u{1F600}")).toBe(true);
    expect(note).toBe(`[The result has ${LOCAL_RESULT_DISPLAY_LIMIT + 1} characters and the first ${LOCAL_RESULT_DISPLAY_LIMIT} are shown. /wf-result run-6 PATH saves all of it to a new file.]`);
    expect(shownResultText("run-6", { code: "text", text: "\u{1F600}".repeat(LOCAL_RESULT_DISPLAY_LIMIT) })).toBe("\u{1F600}".repeat(LOCAL_RESULT_DISPLAY_LIMIT));
  });

  it("saves the exact text to a new private file and never overwrites", async () => {
    const directory = await mkdtemp(join(tmpdir(), "agent-cat-local-result-save-"));
    created.push(directory);
    const path = join(directory, "translation.txt");
    const text = "exact text \u{1F600}\n";
    expect(await saveLocalResult(path, text)).toEqual({ saved: true, bytes: Buffer.byteLength(text), leftover: null });
    expect(await readFile(path, "utf8")).toBe(text);
    expect((await stat(path)).mode & 0o777).toBe(0o600);
    expect(await readdir(directory)).toEqual(["translation.txt"]);
    expect(await saveLocalResult(path, "other text")).toEqual({ saved: false, reason: "a file already exists there" });
    expect(await readFile(path, "utf8")).toBe(text);
    // A failure leaves nothing behind, at the path or beside it.
    const missing = await saveLocalResult(join(directory, "no-such-directory", "x.txt"), "text");
    expect(missing.saved).toBe(false);
    expect((await saveLocalResult("relative.txt", "text")).saved).toBe(false);
    // A directory at the path refuses the link, as a file does.
    expect(await saveLocalResult(directory, "text")).toEqual({ saved: false, reason: "a file already exists there" });
    expect(await readdir(directory)).toEqual(["translation.txt"]);
  });
});
