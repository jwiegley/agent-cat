import { saveExact } from "./manager-ui.ts";
import { resultSummary } from "./monitor.ts";
import { readVerifiedResult } from "./supervisor.ts";
import type { ResultRef } from "./types.ts";

/**
 * The most characters of a result that the extension shows at once. A longer
 * result is cut there, and the text names the command that saves all of it.
 */
export const LOCAL_RESULT_DISPLAY_LIMIT = 24_000;

/**
 * The verified result of a local run in the form an operator reads: its code
 * and its text. The text of a string value is the string itself, exactly.
 * The text of any other value is the JSON of the value exactly as the
 * artifact spells it, so no digit of a number is rounded.
 */
export type LocalResult = { code: unknown; text: string };

/**
 * Read the result of a succeeded local run from its run store. The artifact
 * is verified against the reference of the terminal event first, and the
 * result of an artifact that fails verification is never returned.
 */
export async function readLocalResult(storeDir: string, runId: string, reference: ResultRef): Promise<LocalResult> {
  const { code, value, valueJson } = await readVerifiedResult(storeDir, runId, reference);
  return { code, text: typeof value === "string" ? value : valueJson };
}

/**
 * The text of a result as the extension shows it: all of it when it has at
 * most `LOCAL_RESULT_DISPLAY_LIMIT` characters, and otherwise its first
 * `LOCAL_RESULT_DISPLAY_LIMIT` characters and a line that says so. A
 * character here is one Unicode code point, so the cut never divides one.
 */
export function shownResultText(runId: string, result: LocalResult): string {
  const { text } = result;
  // A text of at most LIMIT code units has at most LIMIT code points.
  if (text.length <= LOCAL_RESULT_DISPLAY_LIMIT) return text;
  // Count without a copy: a result may have tens of megabytes.
  let count = 0;
  let cut = text.length;
  let index = 0;
  for (const character of text) {
    if (count === LOCAL_RESULT_DISPLAY_LIMIT) cut = index;
    count += 1;
    index += character.length;
  }
  if (count <= LOCAL_RESULT_DISPLAY_LIMIT) return text;
  return [
    text.slice(0, cut),
    `[The result has ${count} characters and the first ${LOCAL_RESULT_DISPLAY_LIMIT} are shown. /wf-result ${runId} PATH saves all of it to a new file.]`,
  ].join("\n");
}

/**
 * The lines above a shown result: the run and its workflow, then the
 * reference that the artifact was verified against.
 */
export function resultHeading(runId: string, workflow: string | undefined, reference: Pick<ResultRef, "bytes" | "sha256" | "code">): string[] {
  return [`agent-cat ${runId}: result of ${workflow ?? "the workflow"}`, resultSummary(reference).replace(/^result: /, "verified ")];
}

/**
 * The notification that shows a verified result: `resultHeading`, a blank
 * line, and `shownResultText`.
 */
export function formatLocalResult(shown: { runId: string; workflow: string | undefined; reference: Pick<ResultRef, "bytes" | "sha256" | "code">; result: LocalResult }): string {
  const { runId, workflow, reference, result } = shown;
  return [...resultHeading(runId, workflow, reference), "", shownResultText(runId, result)].join("\n");
}

/**
 * Save the exact UTF-8 text of a result as a new file at one absolute path,
 * through `saveExact`: a private file with mode 0600 that a hard link then
 * publishes, so an existing entry at the path is never replaced and a
 * failure leaves nothing at the path.
 */
export async function saveLocalResult(path: string, text: string): Promise<{ saved: true; bytes: number; leftover: string | null } | { saved: false; reason: string }> {
  const bytes = Buffer.from(text, "utf8");
  const outcome = await saveExact(path, bytes);
  if (outcome.saved) return { saved: true, bytes: bytes.length, leftover: outcome.leftover };
  if (!/^EEXIST\b/.test(outcome.reason)) return outcome;
  // saveExact appends this clause when its private file could not be
  // removed. The operator must still be told of that copy of the result.
  const remains = outcome.reason.indexOf("; the private file ");
  return { saved: false, reason: `a file already exists there${remains < 0 ? "" : outcome.reason.slice(remains)}` };
}
