/**
 * The human path of service mode in Pi: `/wfm` and its companion commands.
 *
 * `ManagerRequests` selects a profile and a workflow from the manager
 * catalogue, creates a request, collects each declared input with its exact
 * bytes, captures an input through `POST /v1/captures` when the user chooses
 * a capture, enqueues the request, follows its admission until the
 * preparation is live, and shows the complete exact review in a native Pi
 * component. Only an explicit confirmation of the displayed review sends
 * `approve`, with the preparation entity tag as `If-Match` and the review
 * selectors of that display. A declined review sends nothing.
 *
 * `/wfm-monitor` shows a `ServiceMonitor` of one run in a native Pi
 * component: the runtime status, the observation freshness, the decision
 * queue, the offers and, at the end, the Terminal and Result lines of the
 * verified result. `/wfm-answer` acts on the head of the decision queue of a
 * run: a typed answer through `answerValue` and `answerBody`, or one of the
 * recovery choices that `recoveryActions` finds in the offers of the run.
 * `/wfm-cancel`, `/wfm-steer` and `/wfm-redirect` send a run control only
 * when the controls of the run offer it, and each reports the command
 * receipt and then the runtime acknowledgement verbatim.
 *
 * `/wfm-result` retrieves the verified result of a succeeded run and saves
 * the exact bytes to a new file through `saveExact`. `/wfm-history` lists
 * every run of `/v1/runs` over all its pages. `/wfm-restart`, `/wfm-resume`
 * and `/wfm-fork` create a child request through the lineage collection of
 * a run, enqueue it and show its exact review with the lineage, and only an
 * approval starts the child run. `/wfm-export` exports the verified result
 * of a run, verifies the exported bytes and lists the exports of the run.
 *
 * Every command goes through the `ManagerSession` of the active service
 * binding, and each send is recorded as a `CommandRecord`. A record states
 * only the outcome of the command (accepted, refused or uncertain) and the
 * state of its receipt. The phase of a request and the status of a run are
 * execution facts, and the commands report them separately. No command is
 * sent again by itself.
 *
 * The `manager-...` actions of the `agent_cat_workflow` tool call the same
 * functions with the values of the model: `ModelStart`, `ModelDecision`,
 * `ModelSteer`, `ModelRedirect` and `ModelForkEdit`. Each function then asks
 * for a human confirmation of the exact content of each model-initiated
 * mutation, and a decline sends nothing. `toolContext` gives the
 * notifications of the call to the tool result. Each function gives whether
 * the command reached its effect.
 *
 * @packageDocumentation
 */

import { randomBytes } from "node:crypto";
import { constants } from "node:fs";
import { link, open, readFile, unlink, type FileHandle } from "node:fs/promises";
import { basename, dirname, isAbsolute, join, resolve, sep } from "node:path";
import type { ExtensionContext, Theme } from "@earendil-works/pi-coding-agent";
import { matchesKey, truncateToWidth, wrapTextWithAnsi, type Component, type TUI } from "@earendil-works/pi-tui";
import type { ClientFailure, Outcome } from "./manager/events.ts";
import { encodeJson, isJsonArray, isJsonObject, jsonMember, JsonNumber, type JsonObject, type JsonValue } from "./manager/json.ts";
import {
  answerBody,
  answerValue,
  decodeCommandReceipt,
  decodeControl,
  decodeDecision,
  decodeDraftView,
  decodeExportCollection,
  decodeExportReceipt,
  decodeInputDeclaration,
  decodeLineageCollection,
  decodePreparation,
  decodeRunItem,
  exportNameValid,
  forkReplacementValue,
  lineageBody,
  requiredScopes,
  type CommandReceipt,
  type ControlOffer,
  type ControlView,
  type DecisionView,
  type DraftView,
  type ExportReceipt,
  type ForkEdit,
  type InputDeclaration,
  type LineageOperation,
  type Operation,
  type Preparation,
  type RecoveryOption,
  type RunItem,
} from "./manager/resources.ts";
import type { ManagerSession, Observed, PendingCommand, Reference } from "./manager/session.ts";
import type { ServiceMode } from "./service-mode.ts";

/**
 * The record of one command send. `outcome` is the outcome of the send:
 * `accepted` for a delivered command, `refused` for a definite refusal, and
 * `uncertain` for a send whose outcome is not known. `detail` names the
 * receipt and its last observed state, or the reason of the refusal.
 *
 * @public
 */
export type CommandRecord = {
  readonly endpoint: string;
  readonly operation: Operation;
  readonly target: string;
  readonly outcome: "accepted" | "refused" | "uncertain";
  readonly detail: string;
};

/** One profile of `/v1/profiles`. */
type ProfileRow = { readonly id: string; readonly workspace: string; readonly target: string; readonly ready: boolean };

/** One workflow of the catalogue of a profile. */
type WorkflowRow = {
  readonly id: string;
  readonly name: string;
  readonly blurb: string;
  readonly revision: string;
  readonly profileId: string;
  readonly profileRevision: string;
  readonly inputs: readonly InputDeclaration[];
};

/** The choice of the review component. */
export type ReviewChoice = "approve" | "decline" | "discard" | "withdraw";

/**
 * The values that a model gives to a model-initiated start through the
 * `agent_cat_workflow` tool: the workflow name, the profile when the manager
 * offers more than one ready profile, and the exact literal of each declared
 * input. The human path collects the same values through the Pi dialogs.
 *
 * @public
 */
export type ModelStart = {
  readonly workflow: string;
  readonly profileId: string | undefined;
  readonly inputs: Readonly<Record<string, string>>;
};

/**
 * The values that a model gives to a model-initiated decision command: the
 * typed text of an answer, which `answerValue` types as the editor text of
 * the human path, or a recovery choice and its fail-over target.
 *
 * @public
 */
export type ModelDecision =
  | { readonly kind: "answer"; readonly text: string }
  | { readonly kind: "recovery"; readonly choice: RecoveryOption["choice"]; readonly target: string | undefined };

/**
 * The values that a model gives to a model-initiated steer or redirect. The
 * occurrence and the attempt are decimal text, as the controls of the run
 * publish them.
 *
 * @public
 */
export type ModelSteer = { readonly occurrenceId: string; readonly attemptId: string; readonly timing: string; readonly text: string };

/** @public */
export type ModelRedirect = { readonly occurrenceId: string; readonly target: string };

/**
 * One fork edit that a model gives: drop the answer of an occurrence, or
 * replace it with text that `forkReplacementValue` types by the code of the
 * occurrence, as the editor text of the human path.
 *
 * @public
 */
export type ModelForkEdit =
  | { readonly type: "drop"; readonly occurrenceId: string }
  | { readonly type: "replace"; readonly occurrenceId: string; readonly value: string };

/**
 * A context for one action of the `agent_cat_workflow` tool. It is the Pi
 * context of the call, except that each notification also becomes one entry
 * of `lines`, in order. The tool result gives these lines to the model, and
 * the human sees each notification as it happens.
 *
 * @public
 */
export function toolContext(ctx: ExtensionContext): { readonly ctx: ExtensionContext; readonly lines: string[] } {
  const lines: string[] = [];
  const notify: ExtensionContext["ui"]["notify"] = (message, level) => {
    lines.push(message);
    ctx.ui.notify(message, level);
  };
  const ui = Object.create(ctx.ui, { notify: { value: notify } }) as ExtensionContext["ui"];
  return { ctx: Object.create(ctx, { ui: { value: ui } }) as ExtensionContext, lines };
}

/** Notify the reason that a command stops, and give `false`. */
function stopped(ctx: ExtensionContext, message: string, level: "info" | "warning" | "error" = "error"): false {
  ctx.ui.notify(message, level);
  return false;
}

/** Notify that the human declined a model-initiated mutation, and give `false`. */
function declined(ctx: ExtensionContext, what: string): false {
  return stopped(ctx, `The human declined the ${what}. Nothing was sent.`, "warning");
}

/** The exact content of a model-initiated run control, as its confirmation shows it. */
function controlContent(kind: string, runId: string, fields: ReadonlyArray<readonly [string, string]>): string {
  return [`kind=${kind}`, `run=${runId}`, ...fields.map(([name, value]) => `${name}=${value}`)].join("\n");
}

/** The longest wait for the receipt of one command to settle, in milliseconds. */
const EFFECT_WAIT_MS = 120_000;

/** The longest wait for a live preparation after enqueue, in milliseconds. */
const REVIEW_WAIT_MS = 600_000;

/** The longest wait for the run of an approved request, in milliseconds. */
const START_WAIT_MS = 120_000;

/** The receipt states after which a receipt no longer changes. */
const SETTLED = ["effect-observed", "refused", "unresolved"];

/** The request phases in which the human path continues. */
const OPEN_PHASES = ["draft", "queued", "preparing", "review"];

/** The input sources that the input editor offers. */
const SOURCES = ["Literal text", "Captured text", "Captured file"] as const;

const SELECTORS = ["reviewDigest", "requestRevision", "profileRevision", "descriptorRevision", "processGeneration"] as const;

function failureText(failure: ClientFailure | null): string {
  if (failure === null) return "the response does not agree with the command";
  return failure.kind === "Refused" ? `${failure.status} ${failure.code}` : failure.kind;
}

function text(value: JsonValue | undefined): string | undefined {
  return typeof value === "string" ? value : undefined;
}

/** The items of a collection value, or an empty list. */
function itemsOf(value: JsonValue[]): JsonObject[] {
  return value.filter((item): item is JsonObject => isJsonObject(item));
}

function profileRow(item: JsonObject): ProfileRow | undefined {
  const id = text(jsonMember(item, "id"));
  const workspace = text(jsonMember(item, "workspaceLabel"));
  const target = text(jsonMember(item, "targetLabel"));
  if (id === undefined || workspace === undefined || target === undefined) return undefined;
  return { id, workspace, target, ready: jsonMember(item, "readiness") === "ready" };
}

function workflowRow(item: JsonObject): WorkflowRow | undefined {
  const fields = ["id", "name", "revision", "profileId", "profileRevision"].map((name) => text(jsonMember(item, name)));
  const declared = jsonMember(item, "inputs");
  if (fields.some((field) => field === undefined) || declared === undefined || !isJsonArray(declared)) return undefined;
  const inputs: InputDeclaration[] = [];
  for (const value of declared) {
    const decoded = decodeInputDeclaration(value);
    if (!decoded.ok) return undefined;
    inputs.push(decoded.value);
  }
  const [id, name, revision, profileId, profileRevision] = fields as string[];
  return { id, name, blurb: text(jsonMember(item, "blurb")) ?? "", revision, profileId, profileRevision, inputs };
}

/** The admission line of a request: its phase, its admission state, its queue position and its blocking reasons. */
export function admissionLine(request: DraftView): string {
  const { admission } = request;
  const parts = [`Request ${request.id}: ${request.phase}`, `admission ${admission.state}`];
  if (admission.position !== null) parts.push(`queue position ${admission.position}`);
  if (admission.reasons.length > 0) parts.push(`waiting for ${admission.reasons.join(", ")}`);
  if (request.readiness.missing.length > 0) parts.push(`missing inputs ${request.readiness.missing.join(", ")}`);
  return parts.join(", ");
}

/**
 * The lines of the complete exact review of a preparation: every approval
 * selector, the entity tag that `approve` binds as `If-Match`, and every
 * consent fact of the review. Nothing is shortened. The component wraps
 * long lines.
 *
 * @public
 */
export function reviewLines(preparation: Preparation, etag: string): string[] {
  const { review } = preparation;
  const lines = [
    `Review of request ${preparation.requestId}, preparation ${preparation.id} (${preparation.state}, expires ${preparation.expiresAt})`,
    "Approval selectors:",
    ...SELECTORS.map((name) => `  ${name}: ${preparation[name]}`),
    `  If-Match: ${etag}`,
    `Program SHA-256: ${review.programHash}`,
    `Person answering: ${review.personAnswering}`,
    `Workflow: ${review.workflowId}`,
    `Profile: ${review.profileId}`,
    `Workspace: ${review.workspaceLabel}`,
    `Target: ${review.targetLabel}`,
    `Policy: ${encodeJson(review.policy)}`,
    `Result code: ${encodeJson(review.resultCode)}`,
    review.inputs.length > 0 ? "Inputs:" : "Inputs: none",
    ...review.inputs.map((input) => `  ${input.name}: ${input.source}, ${input.bytes} bytes, SHA-256 ${input.sha256}`),
    "Plan:",
    ...review.plan.split("\n").map((line) => `  ${line}`),
    review.runFacts.length > 0 ? `Run facts: ${review.runFacts.join(", ")}` : "Run facts: none",
    review.pins.length > 0 ? `Pins: ${review.pins.join(", ")}` : "Pins: none",
    ...(review.warnings.length > 0 ? ["Warnings:", ...review.warnings.map((warning) => `  ${warning}`)] : ["Warnings: none"]),
  ];
  if (review.lineage !== null) {
    const { lineage } = review;
    lines.push(`Lineage: ${lineage.operation} of run ${lineage.parentRunId}`);
    for (const edit of lineage.edits) {
      lines.push(edit.operation === "drop" ? `  drop occurrence ${edit.occurrenceId}`
        : `  replace occurrence ${edit.occurrenceId} with the answer of SHA-256 ${edit.sha256}`);
    }
  }
  return lines;
}

/** The key line of the review component. */
export const REVIEW_KEYS = "a approve after confirmation, d discard, w withdraw, Escape or q decline, j k scroll";

/**
 * The native review component. It shows the complete exact review, scrolls
 * with `j`, `k` and the arrow keys, and ends with a `ReviewChoice`. `a`
 * gives `approve`, which the caller confirms before any send. Escape, `q`
 * and `n` give `decline`.
 *
 * @public
 */
export class ReviewComponent implements Component {
  readonly #tui: TUI;
  readonly #theme: Theme;
  readonly #lines: readonly string[];
  readonly #done: (choice: ReviewChoice) => void;
  #offset = 0;

  constructor(tui: TUI, theme: Theme, lines: readonly string[], done: (choice: ReviewChoice) => void) {
    this.#tui = tui;
    this.#theme = theme;
    this.#lines = lines;
    this.#done = done;
  }

  handleInput(data: string): void {
    if (data === "a") return this.#done("approve");
    if (data === "d") return this.#done("discard");
    if (data === "w") return this.#done("withdraw");
    if (matchesKey(data, "escape") || matchesKey(data, "ctrl+c") || data === "q" || data === "n") return this.#done("decline");
    if (matchesKey(data, "down") || data === "j") this.#offset += 1;
    else if (matchesKey(data, "up") || data === "k") this.#offset = Math.max(0, this.#offset - 1);
    else return;
    this.#tui.requestRender();
  }

  render(width: number): string[] {
    const columns = Math.max(1, width);
    const wrapped = this.#lines.flatMap((line) => wrapTextWithAnsi(line, columns));
    const keys = wrapTextWithAnsi(REVIEW_KEYS, columns);
    const height = Math.max(4, this.#tui.terminal.rows - 5 - keys.length);
    this.#offset = Math.min(this.#offset, Math.max(0, wrapped.length - height));
    const shown = wrapped.slice(this.#offset, this.#offset + height);
    const position = `Lines ${this.#offset + 1}-${this.#offset + shown.length} of ${wrapped.length}`;
    return [
      ...shown.map((line, index) => (index === 0 && this.#offset === 0 ? this.#theme.fg("accent", line) : line)),
      truncateToWidth(this.#theme.fg("dim", position), width),
      ...keys.map((line) => this.#theme.fg("dim", line)),
    ];
  }

  invalidate(): void {}
}

// ---------------------------------------------------------------------------
// Decisions, recovery choices and the live monitor of a service run.

/**
 * The offers of the controls of a run that address a decision: the controls
 * are owned and name the decision as their head, the decision is pending at
 * position 0, and each offer addresses the occurrence and the generation of
 * the decision. Any other decision has no offer.
 *
 * @public
 */
export function decisionOffers(control: ControlView, decision: DecisionView): ControlOffer[] {
  if (control.runId !== decision.runId || control.supervision !== "owned" || control.decisionHeadId !== decision.id
    || decision.state !== "pending" || decision.position !== 0) return [];
  return control.offers.filter((offer) => offer.occurrenceId === decision.occurrenceId && offer.attemptId === null
    && offer.generation === decision.generation);
}

/**
 * One recovery choice that the manager offers for a recovery decision.
 * `operation` names the command: `retry` goes to the controls of the run,
 * and `choose-recovery` goes to the decision.
 *
 * @public
 */
export type RecoveryAction = {
  readonly label: string;
  readonly option: RecoveryOption;
  readonly operation: "retry" | "choose-recovery";
};

function recoveryLabel(option: RecoveryOption): string {
  if (option.choice === "retry") return "Retry";
  if (option.choice === "abandon") return "Abandon";
  return option.target === null ? "Fail over" : `Fail over to ${option.target}`;
}

/**
 * The recovery choices of a recovery decision that the manager offers, in
 * the order of the decision. A choice is offered when a `retry` offer
 * addresses the decision, for the choice `retry`, or when a
 * `choose-recovery` offer of the decision carries the same choice and
 * target. A retry prefers the `retry` offer, as the TUI does. A choice
 * without an offer is not listed, and a question has no recovery choice.
 *
 * @public
 */
export function recoveryActions(control: ControlView, decision: DecisionView): RecoveryAction[] {
  if (decision.content.kind !== "recovery") return [];
  const offers = decisionOffers(control, decision);
  const actions: RecoveryAction[] = [];
  for (const option of decision.content.choices) {
    const retry = option.choice === "retry" && offers.some((offer) => offer.operation === "retry");
    const chosen = offers.some((offer) => offer.operation === "choose-recovery"
      && offer.choices.some((item) => item.choice === option.choice && item.target === option.target));
    if (retry || chosen) actions.push({ label: recoveryLabel(option), option, operation: retry ? "retry" : "choose-recovery" });
  }
  return actions;
}

/** The acknowledgement states that accept, queue or deliver a control. */
const ACCEPTING = ["accepted", "queued", "delivered"];

/** The acknowledgement states that end a control without an effect. */
const REJECTING = ["rejected-stale", "unsupported", "failed"];

/**
 * Whether the controls of a run allow the cancel: they are owned and allow
 * it. The manager allows a cancel while it owns the live run and the run is
 * running.
 *
 * @public
 */
export function cancelOffered(control: ControlView): boolean {
  return control.supervision === "owned" && control.cancelAllowed;
}

/**
 * The steer offers of owned controls. Each names one attempt and at least
 * one timing.
 *
 * @public
 */
export function steerOffers(control: ControlView): ControlOffer[] {
  return control.supervision !== "owned" ? []
    : control.offers.filter((offer) => offer.operation === "steer" && offer.attemptId !== null && offer.timings.length > 0);
}

/**
 * The redirect offers of owned controls that name at least one target: the
 * dispatch-window redirect and the live redirect of an attempt in flight.
 *
 * @public
 */
export function redirectOffers(control: ControlView): ControlOffer[] {
  return control.supervision !== "owned" ? []
    : control.offers.filter((offer) => offer.operation === "redirect" && offer.targets.length > 0);
}

/**
 * The place of a redirect offer in the run snapshot: the open dispatch
 * window of the occurrence, its one attempt in flight, or neither.
 *
 * @public
 */
export type RedirectPlace =
  | { readonly kind: "dispatch" }
  | { readonly kind: "attempt"; readonly attemptId: string }
  | { readonly kind: "unknown" };

/**
 * The place of the occurrence of a redirect offer in a run snapshot.
 *
 * @public
 */
export function redirectPlace(snapshot: JsonObject, occurrenceId: bigint): RedirectPlace {
  const items = jsonMember(snapshot, "items");
  const occurrence = items !== undefined && isJsonArray(items)
    ? items.find((item) => memberOf(item, "occurrenceId") === occurrenceId.toString()) : undefined;
  if (occurrence === undefined) return { kind: "unknown" };
  if (memberOf(memberOf(occurrence, "dispatch"), "open") === true) return { kind: "dispatch" };
  const attempts = memberOf(occurrence, "attempts");
  const running = attempts !== undefined && isJsonArray(attempts)
    ? attempts.filter((attempt) => memberOf(attempt, "state") === "running").map((attempt) => text(memberOf(memberOf(attempt, "address"), "attemptId")))
    : [];
  return running.length === 1 && running[0] !== undefined ? { kind: "attempt", attemptId: running[0] } : { kind: "unknown" };
}

function placeText(place: RedirectPlace): string {
  if (place.kind === "dispatch") return "dispatch window open";
  if (place.kind === "attempt") return `attempt ${place.attemptId} in flight`;
  return "place not published";
}

/** The runtime acknowledgement of a receipt: its state and its message. */
function acknowledgementOf(receipt: CommandReceipt): { state: string; message: string } | undefined {
  const ack = receipt.acknowledgement;
  if (ack === null || !isJsonObject(ack)) return undefined;
  const state = text(jsonMember(ack, "state"));
  const message = text(jsonMember(ack, "message"));
  return state === undefined || message === undefined ? undefined : { state, message };
}

/** The effect kind of a receipt. */
function effectKind(receipt: CommandReceipt): string | undefined {
  return receipt.effect !== null && isJsonObject(receipt.effect) ? text(jsonMember(receipt.effect, "kind")) : undefined;
}

/**
 * Whether the receipt of a run control has settled for the report. Every
 * receipt settles at `effect-observed`, `refused` or `unresolved`. An
 * acknowledgement that rejects the control (`rejected-stale`,
 * `unsupported` or `failed`) settles it without an effect. A cancel also
 * settles on an accepting acknowledgement, because the runtime cancellation
 * names no control, so its receipt records no effect.
 *
 * @public
 */
export function controlSettled(operation: Operation, receipt: CommandReceipt): boolean {
  if (SETTLED.includes(receipt.state)) return true;
  const ack = acknowledgementOf(receipt);
  if (receipt.state !== "acknowledged" || ack === undefined) return false;
  return REJECTING.includes(ack.state) || (operation === "cancel" && ACCEPTING.includes(ack.state));
}

/**
 * The report of the runtime acknowledgement of a receipt, with its state
 * and its message verbatim.
 *
 * @public
 */
export function acknowledgementLine(receipt: CommandReceipt): string {
  const ack = acknowledgementOf(receipt);
  return ack === undefined
    ? `Command ${receipt.id} has no runtime acknowledgement (receipt ${receipt.state}).`
    : `Acknowledgement of command ${receipt.id}: ${ack.state}: ${ack.message}`;
}

/** A prompt on one line: each line end becomes one space. */
function oneLine(value: string): string {
  return value.replace(/\r?\n/g, " ");
}

/** The answer form of a question code, for the editor title and the monitor. */
function codeLabel(decision: DecisionView): string {
  if (decision.content.kind !== "question") return "recovery";
  const { code } = decision.content;
  if (code === "flag") return "flag: yes, no, true or false";
  if (code === "receipt") return "receipt: empty";
  return typeof code === "string" ? code : "structured JSON";
}

/** The line of one decision of the queue of a run. */
function decisionLine(decision: DecisionView): string {
  const place = decision.position === 0 ? `Head ${decision.id}` : `${decision.id} at position ${decision.position}`;
  if (decision.content.kind === "question") {
    return `  ${place}: ${decision.state} question (${codeLabel(decision)}): ${oneLine(decision.content.prompt)}`;
  }
  const choices = decision.content.choices.map(recoveryLabel).join(", ") || "none";
  return `  ${place}: ${decision.state} recovery (${decision.content.gap}): ${oneLine(decision.content.message)}; choices ${choices}`;
}

/**
 * The retrieval of the verified result of a succeeded run: not started,
 * waiting for the verification of the manager, in progress, verified with
 * the size and SHA-256 of the exact downloaded bytes, or failed with a
 * failure code.
 *
 * @public
 */
export type ResultRetrieval =
  | { readonly kind: "none" }
  | { readonly kind: "waiting" }
  | { readonly kind: "retrieving" }
  | { readonly kind: "verified"; readonly bytes: number; readonly sha256: string }
  | { readonly kind: "failed"; readonly code: string };

/**
 * One observation of the live monitor: the last complete read, kept after a
 * later read fails, and the failure code of the latest read when it failed.
 *
 * @public
 */
export type Kept<Value> = { readonly value: Value | undefined; readonly failure: string | undefined };

/**
 * The state that the live monitor shows: the run, the delivery state of the
 * session, the run snapshot, the controls and the decision queue of the run,
 * and the retrieval of its result.
 *
 * @public
 */
export type MonitorState = {
  readonly runId: string;
  readonly delivery: string;
  readonly snapshot: Kept<JsonObject>;
  readonly control: Kept<ControlView>;
  readonly queue: Kept<readonly DecisionView[]>;
  readonly result: ResultRetrieval;
};

/** The terminal runtime statuses. */
const TERMINAL_STATUSES = ["succeeded", "failed", "cancelled", "orphaned"];

/** A member of a JSON object, or `undefined`. */
function memberOf(value: JsonValue | undefined, name: string): JsonValue | undefined {
  return value !== undefined && isJsonObject(value) ? jsonMember(value, name) : undefined;
}

/** The runtime status of a run snapshot, or `undefined` before native evidence. */
export function snapshotStatus(snapshot: JsonObject): string | undefined {
  return text(memberOf(memberOf(snapshot, "runtime"), "status"));
}

/**
 * The lines of the live monitor of a service run. They state the run and
 * its workflow, the delivery state, the freshness of the observation, the
 * runtime status with any supervision other than `owned`, the pending
 * decisions of the run with the head first, and the offered controls. A
 * terminal run then has the Terminal line and the Result lines: the verified
 * size and SHA-256 of the retrieved bytes, or the state of the retrieval.
 * The last read that completed stays in view after a later read fails, and
 * the freshness line names the failure.
 *
 * @public
 */
export function serviceMonitorLines(state: MonitorState): string[] {
  const snapshot = state.snapshot.value;
  const workflow = snapshot === undefined ? undefined : text(jsonMember(snapshot, "workflow"));
  const lines = [`Service run ${state.runId}${workflow === undefined ? "" : `, workflow ${workflow}`}`, `Delivery: ${state.delivery}`];
  const kept = [state.snapshot, state.control, state.queue];
  const failure = kept.find((item) => item.failure !== undefined)?.failure;
  if (kept.every((item) => item.value === undefined && item.failure === undefined)) lines.push("Observation: not yet read");
  else if (failure === undefined) lines.push(kept.every((item) => item.value !== undefined) ? "Observation: current" : "Observation: reading");
  else if (kept.every((item) => item.value !== undefined)) lines.push(`Observation: stale (${failure}); the last complete observation is retained`);
  else lines.push(`Observation: refused (${failure}); no complete observation is installed`);
  if (snapshot !== undefined) {
    const supervision = text(jsonMember(snapshot, "supervision"));
    const status = snapshotStatus(snapshot);
    lines.push(`Runtime: ${status ?? "not yet observed"}${supervision === undefined || supervision === "owned" ? "" : `; supervision ${supervision}`}`);
  }
  const pending = (state.queue.value ?? []).filter((decision) => decision.state === "pending" || decision.state === "submitting");
  if (state.queue.value !== undefined) {
    lines.push(pending.length === 0 ? "Decisions: none pending" : `Decisions: ${pending.length} pending`);
    for (const decision of [...pending].sort((a, b) => a.position - b.position)) lines.push(decisionLine(decision));
  }
  const control = state.control.value;
  if (control !== undefined) {
    const operations = [...new Set(control.offers.map((offer) => offer.operation)), ...(control.cancelAllowed ? ["cancel"] : [])];
    lines.push(`Offers: ${operations.join(", ") || "none"}`);
  }
  return [...lines, ...outcomeLines(state)];
}

/**
 * The Terminal line and the Result lines of a terminal run, as the TUI
 * names them. A run that is not terminal has no outcome lines.
 *
 * @public
 */
export function outcomeLines(state: MonitorState): string[] {
  const snapshot = state.snapshot.value;
  const status = snapshot === undefined ? undefined : snapshotStatus(snapshot);
  if (snapshot === undefined || status === undefined || !TERMINAL_STATUSES.includes(status)) return [];
  const lines = [`Terminal: ${status}`];
  const failure = text(jsonMember(snapshot, "failure"));
  if (failure !== undefined) lines.push(`Failure: ${text(jsonMember(snapshot, "failureClass")) ?? "unclassified"}: ${oneLine(failure)}`);
  if (status !== "succeeded") return [...lines, "Result: no download for a run that did not succeed"];
  const verification = text(memberOf(jsonMember(snapshot, "verification"), "state")) ?? "absent";
  const { result } = state;
  switch (result.kind) {
    case "verified":
      return [...lines, `Result: verified ${result.bytes} bytes`, `Result SHA-256: ${result.sha256}`];
    case "failed":
      return [...lines, `Result: not retrieved (${result.code}); the next change of the run retries`];
    case "retrieving":
    case "waiting":
      return [...lines, result.kind === "retrieving" ? "Result: retrieving the verified bytes" : "Result: waiting for the verification of the manager"];
    case "none":
      return [...lines, ["verified", "referenced"].includes(verification) ? "Result: retrieving the verified bytes"
        : `Result: no download; verification is ${verification}`];
  }
}

/**
 * The size, SHA-256 and download of the verified result output of a run, or
 * `undefined`. The artifact must be the one that the verification of the
 * output names.
 */
function verifiedArtifact(outputs: JsonValue): { download: string; bytes: bigint; sha256: string } | undefined {
  const items = memberOf(outputs, "items");
  if (items === undefined || !isJsonArray(items)) return undefined;
  for (const item of items) {
    const verification = memberOf(item, "verification");
    if (memberOf(item, "kind") !== "result" || memberOf(verification, "state") !== "verified") continue;
    const artifact = memberOf(item, "artifact");
    if (text(memberOf(artifact, "id")) === undefined || memberOf(artifact, "id") !== memberOf(verification, "artifactId")) continue;
    const download = text(memberOf(artifact, "download"));
    const sha256 = text(memberOf(artifact, "sha256"));
    const size = memberOf(artifact, "bytes");
    const bytes = typeof size === "string" && /^[0-9]+$/.test(size) ? BigInt(size)
      : size instanceof JsonNumber && /^[0-9]+$/.test(size.source) ? BigInt(size.source) : undefined;
    if (download !== undefined && sha256 !== undefined && bytes !== undefined) return { download, bytes, sha256 };
  }
  return undefined;
}

/** The watched resources of a live monitor. */
type MonitorReferences = { readonly snapshot: Reference; readonly control: Reference; readonly queue: Reference };

/**
 * The live monitor of one service run. It watches the run snapshot, the
 * controls and the decision queue of the run through the session, so each
 * related event of the manager reads them again. Each read that completes
 * replaces the kept read of its resource, and a failed read keeps the
 * earlier one. When the snapshot of a succeeded run names a referenced or
 * verified result, the monitor reads the outputs of the run, downloads the
 * verified result once through `ManagerSession.download`, which checks the
 * size and the SHA-256, and keeps only the size and the digest. A result
 * that the manager has not verified yet is read again after the next change
 * of the snapshot. The monitor sends no command.
 *
 * @public
 */
export class ServiceMonitor {
  readonly runId: string;
  readonly #session: ManagerSession;
  readonly #references: MonitorReferences;
  #snapshot: Kept<JsonObject> = { value: undefined, failure: undefined };
  #control: Kept<ControlView> = { value: undefined, failure: undefined };
  #queue: Kept<readonly DecisionView[]> = { value: undefined, failure: undefined };
  #result: ResultRetrieval = { kind: "none" };
  /** The entity tag of the snapshot at the last retrieval attempt. */
  #attempted: string | null | undefined;
  #changed: () => void = () => {};
  #closed = false;

  private constructor(session: ManagerSession, runId: string, references: MonitorReferences) {
    this.#session = session;
    this.runId = runId;
    this.#references = references;
  }

  /** The monitor of a run of the current binding, or the refusal of its references. */
  static open(session: ManagerSession, runId: string): Outcome<ServiceMonitor> {
    const snapshot = session.reference(`/v1/runs/${runId}/snapshot`);
    const control = session.reference(`/v1/runs/${runId}/control`);
    const queue = session.reference(`/v1/decisions?runId=${runId}`);
    if (!snapshot.ok) return snapshot;
    if (!control.ok) return control;
    if (!queue.ok) return queue;
    return { ok: true, value: new ServiceMonitor(session, runId, { snapshot: snapshot.value, control: control.value, queue: queue.value }) };
  }

  /** Watch the resources of the run and call `changed` after each change of the monitor. */
  start(changed: () => void): Outcome<undefined> {
    this.#changed = changed;
    for (const reference of Object.values(this.#references)) {
      const watched = this.#session.watch(reference);
      if (!watched.ok) return watched;
    }
    this.refresh();
    return { ok: true, value: undefined };
  }

  /** Wait until each watched resource has an installed read, at most `timeoutMs` each, and take the reads. */
  async settled(timeoutMs: number): Promise<void> {
    for (const reference of Object.values(this.#references)) await this.#session.waitFor(reference, () => true, timeoutMs);
    this.refresh();
  }

  /** Stop the monitor. Later changes call nothing. */
  close(): void {
    this.#closed = true;
    this.#changed = () => {};
  }

  /** The state that the monitor shows now. */
  state(): MonitorState {
    return {
      runId: this.runId, delivery: this.#session.deliveryState, snapshot: this.#snapshot, control: this.#control, queue: this.#queue,
      result: this.#result,
    };
  }

  /** The lines of `serviceMonitorLines` for the state now. */
  lines(): string[] {
    return serviceMonitorLines(this.state());
  }

  /** Take the installed reads of the session, and start the retrieval of a succeeded result. */
  refresh(): void {
    if (this.#closed) return;
    const snapshot = this.#take(this.#references.snapshot, this.#snapshot, (value) => (isJsonObject(value) ? value : undefined));
    this.#snapshot = snapshot.kept;
    this.#control = this.#take(this.#references.control, this.#control, (value) => {
      const decoded = decodeControl(value);
      return decoded.ok ? decoded.value : undefined;
    }).kept;
    this.#queue = this.#take(this.#references.queue, this.#queue, (value) => {
      const items = memberOf(value, "items");
      if (items === undefined || !isJsonArray(items)) return undefined;
      const decisions: DecisionView[] = [];
      for (const item of items) {
        const decoded = decodeDecision(item);
        if (!decoded.ok) return undefined;
        decisions.push(decoded.value);
      }
      return decisions;
    }).kept;
    const value = this.#snapshot.value;
    const verification = value === undefined ? undefined : text(memberOf(jsonMember(value, "verification"), "state"));
    if (value !== undefined && snapshotStatus(value) === "succeeded" && (verification === "verified" || verification === "referenced")
      && this.#result.kind !== "verified" && this.#result.kind !== "retrieving" && snapshot.etag !== this.#attempted) {
      this.#attempted = snapshot.etag;
      this.#result = { kind: "retrieving" };
      void this.#retrieve();
    }
  }

  #take<Value>(reference: Reference, kept: Kept<Value>, decode: (value: JsonValue) => Value | undefined)
    : { kept: Kept<Value>; etag: string | null | undefined } {
    const installed = this.#session.current(reference);
    if (installed === undefined) return { kept, etag: undefined };
    if (!installed.ok) return { kept: { value: kept.value, failure: failureText(installed.failure) }, etag: undefined };
    const value = decode(installed.value.value);
    return value === undefined
      ? { kept: { value: kept.value, failure: "InvalidResponse" }, etag: undefined }
      : { kept: { value, failure: undefined }, etag: installed.value.etag };
  }

  async #retrieve(): Promise<void> {
    const outputs = this.#session.reference(`/v1/runs/${this.runId}/outputs`);
    const read = outputs.ok ? await this.#session.get(outputs.value) : outputs;
    if (this.#closed) return;
    if (!read.ok) {
      this.#result = { kind: "failed", code: failureText(read.failure) };
      return this.#changed();
    }
    const artifact = verifiedArtifact(read.value.value);
    if (artifact === undefined) {
      // Reading the outputs makes the manager verify a referenced result,
      // and the next change of the snapshot starts the retrieval again.
      this.#result = { kind: "waiting" };
      return this.#changed();
    }
    const location = this.#session.reference(artifact.download);
    const bytes = location.ok ? await this.#session.download(location.value, artifact.bytes, artifact.sha256) : location;
    if (this.#closed) return;
    this.#result = bytes.ok ? { kind: "verified", bytes: bytes.value.length, sha256: artifact.sha256 }
      : { kind: "failed", code: failureText(bytes.failure) };
    this.#changed();
  }
}

/** The key line of the live monitor. */
export const MONITOR_KEYS = "q or Escape closes, j k scroll; /wfm-answer answers the head decision";

/**
 * The native live monitor component. It shows the lines of a
 * `ServiceMonitor` and keeps the Terminal and Result lines in view at every
 * height. `j`, `k` and the arrow keys scroll the other lines, and `q` or
 * Escape closes it.
 *
 * @public
 */
export class ServiceMonitorComponent implements Component {
  readonly #tui: TUI;
  readonly #theme: Theme;
  readonly #monitor: ServiceMonitor;
  readonly #close: () => void;
  #offset = 0;

  constructor(tui: TUI, theme: Theme, monitor: ServiceMonitor, close: () => void) {
    this.#tui = tui;
    this.#theme = theme;
    this.#monitor = monitor;
    this.#close = close;
  }

  handleInput(data: string): void {
    if (matchesKey(data, "escape") || matchesKey(data, "ctrl+c") || data === "q") return this.#close();
    if (matchesKey(data, "down") || data === "j") this.#offset += 1;
    else if (matchesKey(data, "up") || data === "k") this.#offset = Math.max(0, this.#offset - 1);
    else return;
    this.#tui.requestRender();
  }

  render(width: number): string[] {
    const columns = Math.max(1, width);
    const state = this.#monitor.state();
    const outcome = outcomeLines(state);
    const all = serviceMonitorLines(state);
    const body = all.slice(0, all.length - outcome.length).flatMap((line) => wrapTextWithAnsi(line, columns));
    const ending = outcome.flatMap((line) => wrapTextWithAnsi(line, columns));
    const keys = wrapTextWithAnsi(MONITOR_KEYS, columns);
    const height = Math.max(1, this.#tui.terminal.rows - 4 - keys.length - ending.length);
    this.#offset = Math.min(this.#offset, Math.max(0, body.length - height));
    const shown = body.slice(this.#offset, this.#offset + height);
    return [
      ...shown.map((line, index) => (index === 0 && this.#offset === 0 ? this.#theme.fg("accent", line) : line)),
      ...ending.map((line) => this.#theme.fg(line.startsWith("Terminal: succeeded") ? "success" : "accent", line)),
      ...keys.map((line) => this.#theme.fg("dim", line)),
    ];
  }

  invalidate(): void {}
}

// ---------------------------------------------------------------------------
// Results, history, lineage and exports.

/**
 * The outcome of `saveExact`: the destination holds the exact bytes, with
 * the private file removed or left at `leftover`, or nothing was published
 * and `reason` states why.
 *
 * @public
 */
export type SaveOutcome =
  | { readonly saved: true; readonly leftover: string | null }
  | { readonly saved: false; readonly reason: string };

function errorText(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

/** Remove a file, and give the failure text when the removal fails. */
async function removeFile(path: string): Promise<string | undefined> {
  try {
    await unlink(path);
    return undefined;
  } catch (error) {
    return errorText(error);
  }
}

/**
 * Publish exactly these bytes as a new file at one absolute path, as
 * `Agentic.Tui.Save` does. The bytes go to a new private file in the
 * destination directory first: an exclusive create with mode 0600 that does
 * not follow a symbolic link, a full write and an fsync. A hard link then
 * publishes that file at the destination. A link never replaces an existing
 * entry, so an existing file, directory or symbolic link at the destination
 * refuses the save and stays as it is. A failure before the link removes the
 * private file. After the link, the destination holds the exact bytes and
 * the save succeeds. When the private file cannot then be removed, the
 * outcome names it.
 *
 * @public
 */
export async function saveExact(path: string, bytes: Uint8Array): Promise<SaveOutcome> {
  if (!isAbsolute(path) || path.endsWith(sep) || basename(path) === "" || /[\0\n\r]/.test(path)) {
    return { saved: false, reason: "the destination must be one absolute single-line file path" };
  }
  const temporary = join(dirname(path), `.${basename(path)}.${randomBytes(12).toString("hex")}.partial`);
  let handle: FileHandle;
  try {
    handle = await open(temporary, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
  } catch (error) {
    return { saved: false, reason: errorText(error) };
  }
  let failure: string | undefined;
  try {
    await handle.chmod(0o600);
    await handle.writeFile(bytes);
    await handle.sync();
  } catch (error) {
    failure = errorText(error);
  }
  try {
    await handle.close();
  } catch (error) {
    failure ??= errorText(error);
  }
  if (failure === undefined) {
    try {
      await link(temporary, path);
    } catch (error) {
      failure = errorText(error);
    }
  }
  const removal = await removeFile(temporary);
  if (failure !== undefined) {
    return { saved: false, reason: removal === undefined ? failure : `${failure}; the private file ${temporary} remains (${removal})` };
  }
  return { saved: true, leftover: removal === undefined ? null : temporary };
}

/** The runtime status of a run item, or the reason that it has none. */
function itemStatus(run: RunItem): string {
  if (run.content.kind === "unreadable") return `unreadable (${run.content.category})`;
  return run.content.runtime?.status ?? "no runtime evidence";
}

/**
 * The line of one run of the history: its identifier, workflow, profile,
 * runtime status and supervision, its lineage, and the verification of its
 * result. A legacy entry has `observer` supervision and is labelled as a
 * read-only observer entry.
 *
 * @public
 */
export function historyLine(run: RunItem): string {
  if (run.content.kind === "unreadable") return `  ${run.id}  profile ${run.profileId}  ${itemStatus(run)}`;
  const { content } = run;
  const parts = [`  ${run.id}  ${content.workflowId}  profile ${run.profileId}  ${itemStatus(run)}`];
  parts.push(content.supervision === "observer" ? "observer (legacy entry, read only)" : `supervision ${content.supervision}`);
  if (content.lineage !== null && content.parentRunId !== null) parts.push(`${content.lineage} of run ${content.parentRunId}`);
  parts.push(`result ${content.verification.state}`);
  return parts.join(", ");
}

/**
 * The lines of the history: a count of the managed runs and of the observer
 * entries, then one `historyLine` for each run in the order of the
 * collection.
 *
 * @public
 */
export function historyLines(runs: readonly RunItem[]): string[] {
  const observers = runs.filter((run) => run.content.kind === "known" && run.content.supervision === "observer").length;
  return [`History: ${runs.length - observers} managed runs and ${observers} observer entries`, ...runs.map(historyLine)];
}

/**
 * An occurrence of a parent run that a fork edit may name: a completed or
 * reused occurrence, whose answer the runtime persisted, with its
 * observation code, its intent and its published answer text.
 *
 * @public
 */
export type ForkTarget = { readonly occurrenceId: bigint; readonly code: string; readonly intent: string; readonly answer: string | null };

/**
 * The fork targets of a run snapshot, in occurrence order.
 *
 * @public
 */
export function forkTargets(snapshot: JsonObject): ForkTarget[] {
  const items = jsonMember(snapshot, "items");
  if (items === undefined || !isJsonArray(items)) return [];
  const targets: ForkTarget[] = [];
  for (const item of items) {
    const id = text(memberOf(item, "occurrenceId"));
    const state = text(memberOf(item, "state"));
    const code = text(memberOf(item, "code"));
    if (id === undefined || !/^(?:0|[1-9][0-9]*)$/.test(id) || code === undefined || (state !== "completed" && state !== "reused")) continue;
    targets.push({ occurrenceId: BigInt(id), code, intent: text(memberOf(item, "intent")) ?? "", answer: text(memberOf(item, "answer")) ?? null });
  }
  return targets.sort((a, b) => (a.occurrenceId < b.occurrenceId ? -1 : a.occurrenceId > b.occurrenceId ? 1 : 0));
}

/** The text of the fork edit of an occurrence for its selection label. */
function editLabel(edit: ForkEdit | undefined): string {
  if (edit === undefined) return "keep";
  return edit.operation === "drop" ? "drop" : `replace with ${encodeJson(edit.answer)}`;
}

/**
 * The lines of one export receipt and of its verified download.
 *
 * @public
 */
export function exportLines(receipt: ExportReceipt, downloaded: number): string[] {
  return [
    `Export ${receipt.name}: ${receipt.id} state ${receipt.state}, command ${receipt.commandId}`,
    `Export download: verified ${downloaded} bytes, SHA-256 ${receipt.sha256 ?? "none"}`,
  ];
}

/** The line of one receipt of the export collection of a run. */
function exportItemLine(receipt: ExportReceipt): string {
  const size = receipt.bytes === null ? "no size" : `${receipt.bytes} bytes`;
  return `  ${receipt.name}  ${receipt.id}  ${receipt.state}  ${size}  SHA-256 ${receipt.sha256 ?? "none"}`;
}

/** The effect resource of a receipt, or `undefined`. */
function effectResource(receipt: CommandReceipt): string | undefined {
  return receipt.effect !== null && isJsonObject(receipt.effect) ? text(jsonMember(receipt.effect, "resource")) : undefined;
}

/** The run argument and the rest of the arguments of a command: `RUN REST`. */
function runAndRest(args: string): { run: string; rest: string } {
  const trimmed = args.trim();
  const space = trimmed.search(/\s/);
  return space < 0 ? { run: trimmed, rest: "" } : { run: trimmed.slice(0, space), rest: trimmed.slice(space).trim() };
}

/**
 * The commands of the human path over the active service binding.
 *
 * @public
 */
export class ManagerRequests {
  readonly #service: () => ServiceMode | undefined;
  readonly #records: CommandRecord[] = [];
  /** The editor drafts of each input, keyed by endpoint identity, request and input name. */
  readonly #drafts = new Map<string, string>();
  /** The answer drafts of each decision, keyed by endpoint identity and decision. */
  readonly #answerDrafts = new Map<string, string>();

  constructor(service: () => ServiceMode | undefined) {
    this.#service = service;
  }

  /** The command records of the active binding, oldest first. */
  records(): CommandRecord[] {
    const session = this.#service()?.session;
    return session === undefined ? [] : this.#records.filter((record) => record.endpoint === session.identity);
  }

  /** The kept editor draft of an input of a request of the active binding. */
  draft(requestId: string, name: string): string | undefined {
    const session = this.#service()?.session;
    return session === undefined ? undefined : this.#drafts.get(draftKey(session, requestId, name));
  }

  #session(ctx: ExtensionContext): ManagerSession | undefined {
    const service = this.#service();
    if (service === undefined) {
      ctx.ui.notify("Service mode is not configured. Set AGENT_CAT_MANAGER_PROFILE or AGENT_CAT_MANAGER_PROFILES.", "warning");
      return undefined;
    }
    const session = service.session;
    if (session === undefined || service.connection.kind !== "connected") {
      ctx.ui.notify("The manager is not connected. /wfm-status states the connection.", "error");
      return undefined;
    }
    return session;
  }

  #record(ctx: ExtensionContext, session: ManagerSession, operation: Operation, target: string,
    outcome: CommandRecord["outcome"], detail: string): void {
    this.#records.push({ endpoint: session.identity, operation, target, outcome, detail });
    ctx.ui.notify(`Command ${operation} ${outcome}: ${detail}`, outcome === "accepted" ? "info" : outcome === "refused" ? "warning" : "error");
  }

  /** Whether the credential holds every scope of the operation. Nothing is sent otherwise. */
  #permitted(ctx: ExtensionContext, session: ManagerSession, operation: Operation): boolean {
    const granted = jsonMember(session.capabilities, "scopes");
    const scopes = granted !== undefined && isJsonArray(granted) ? granted : [];
    const missing = requiredScopes(operation).filter((scope) => !scopes.includes(scope));
    if (missing.length === 0) return true;
    ctx.ui.notify(`The credential lacks the scope ${missing.join(", ")} that ${operation} requires. Nothing was sent.`, "error");
    return false;
  }

  /**
   * Send one command once. With `settle`, wait until its receipt settles.
   * It gives the receipt state, `refused` for a definite refusal, and
   * `uncertain` when the outcome is unknown. A create gives `created` with
   * its request, and a capture gives `captured` with its identifier. An
   * approval does not settle its receipt: the run that the request names is
   * its execution fact.
   *
   * An uncertain send is reconciled with one read under the rules of
   * `reconcile` in `src/manager/refresh.ts`: the target observes the effect
   * only when `effectVisible` sees it and the entity tag differs from the
   * precondition. A reconciled effect gives the receipt state
   * `effect-observed`. Otherwise the command stays uncertain. The command is
   * never sent again.
   */
  async #command(ctx: ExtensionContext, session: ManagerSession, operation: Operation, target: string,
    prepared: Outcome<PendingCommand>, settle = true, effectVisible: (value: JsonValue) => boolean = () => false,
    settledWhen: (receipt: CommandReceipt) => boolean = (receipt) => SETTLED.includes(receipt.state)): Promise<
    | { kind: "receipt"; state: string; receipt?: CommandReceipt }
    | { kind: "created"; request: DraftView; location: Reference }
    | { kind: "captured"; captureId: string }
    | { kind: "refused"; failure: ClientFailure }
    | { kind: "uncertain" }
  > {
    if (!this.#permitted(ctx, session, operation)) return { kind: "refused", failure: { kind: "Refused", status: 403, code: "insufficient-scope" } };
    if (!prepared.ok) {
      this.#record(ctx, session, operation, target, "refused", `not sent: ${failureText(prepared.failure)}`);
      return { kind: "refused", failure: prepared.failure };
    }
    const sent = await session.send(prepared.value);
    if (sent.kind === "refused") {
      this.#record(ctx, session, operation, target, "refused", failureText(sent.failure));
      return { kind: "refused", failure: sent.failure };
    }
    if (sent.kind === "uncertain") {
      const reconciled = await session.reconcileCommand(sent.uncertain, effectVisible);
      if (reconciled.kind === "effect-observed") {
        this.#record(ctx, session, operation, target, "accepted",
          `the send was uncertain (${failureText(sent.failure)}), and one read of ${target} observes its effect. The command is not sent again.`);
        return { kind: "receipt", state: "effect-observed" };
      }
      if (reconciled.kind === "refused") {
        this.#record(ctx, session, operation, target, "refused", "the send was uncertain, and its receipt states refused");
        return { kind: "receipt", state: "refused" };
      }
      this.#record(ctx, session, operation, target, "uncertain",
        `${failureText(sent.failure)}. One read of ${target} does not settle it. The command is not sent again. /wfm-status shows the manager state.`);
      return { kind: "uncertain" };
    }
    if (sent.capture !== null) {
      const capture = sent.capture;
      this.#record(ctx, session, operation, target, "accepted",
        `capture ${capture.id} of request ${capture.requestId}, ${capture.bytes} bytes, SHA-256 ${capture.sha256}, command ${sent.location.uri}`);
      return { kind: "captured", captureId: capture.id };
    }
    if (sent.receipt === null) {
      const created = decodeDraftView(sent.response.value);
      if (operation !== "create" || sent.response.status !== 201 || !created.ok) {
        this.#record(ctx, session, operation, target, "uncertain", "the response does not agree with the command");
        return { kind: "uncertain" };
      }
      this.#record(ctx, session, operation, target, "accepted", `request ${created.value.id} (${created.value.phase})`);
      return { kind: "created", request: created.value, location: sent.location };
    }
    const receipt = sent.receipt;
    if (!settle) {
      this.#record(ctx, session, operation, target, "accepted", `command ${receipt.id}, receipt ${receipt.state}`);
      return { kind: "receipt", state: receipt.state };
    }
    const settled = await session.waitFor(sent.location, (observed) => {
      const decoded = decodeCommandReceipt(observed.value);
      return decoded.ok && settledWhen(decoded.value);
    }, EFFECT_WAIT_MS);
    const decoded = settled.ok ? decodeCommandReceipt(settled.value.value) : undefined;
    const final = decoded !== undefined && decoded.ok ? decoded.value : receipt;
    const refusal = final.refusal !== null ? `, refusal ${final.refusal}` : "";
    const kind = effectKind(final);
    this.#record(ctx, session, operation, target, "accepted",
      `command ${receipt.id}, receipt ${final.state}${kind === undefined ? "" : ` (${kind})`}${refusal}`);
    return { kind: "receipt", state: final.state, receipt: final };
  }

  /**
   * Send one run control to the controls of the run with the control entity
   * tag as `If-Match`, wait until `controlSettled` holds for its receipt, and
   * report the receipt and then the runtime acknowledgement verbatim. Gives
   * the settled receipt, or `undefined` when the send gave none.
   */
  async #runControl(ctx: ExtensionContext, session: ManagerSession, operation: "cancel" | "steer" | "redirect", controls: Observed,
    body: JsonValue): Promise<CommandReceipt | undefined> {
    const sent = await this.#command(ctx, session, operation, controls.reference.uri, session.prepare(controls.reference, body, controls.etag),
      true, () => false, (receipt) => controlSettled(operation, receipt));
    if (sent.kind !== "receipt" || sent.receipt === undefined) return undefined;
    const ack = acknowledgementOf(sent.receipt);
    ctx.ui.notify(acknowledgementLine(sent.receipt), ack !== undefined && ACCEPTING.includes(ack.state) ? "info" : "warning");
    return sent.receipt;
  }

  /** One read of the controls of a run, or `undefined` after a notification. */
  async #controls(ctx: ExtensionContext, session: ManagerSession, runId: string): Promise<{ observed: Observed; control: ControlView } | undefined> {
    const reference = session.reference(`/v1/runs/${runId}/control`);
    if (!reference.ok) return undefined;
    const observed = await session.get(reference.value);
    const control = observed.ok ? decodeControl(observed.value.value) : observed;
    if (!observed.ok || !control.ok) {
      ctx.ui.notify(`The controls of run ${runId} could not be read: ${failureText(control.ok ? null : control.failure)}`, "error");
      return undefined;
    }
    if (control.value.runId !== runId) {
      ctx.ui.notify(`The controls of run ${runId} name run ${control.value.runId}. Nothing was sent.`, "error");
      return undefined;
    }
    return { observed: observed.value, control: control.value };
  }

  /** The running service runs of the active binding, for the selection of a run control. */
  #liveRuns(service: ServiceMode): { runId: string; label: string }[] {
    return service.runs().filter((run) => run.status === "running")
      .map((run) => ({ runId: run.runId, label: `${run.runId}  ${run.status}  ${run.workflowId ?? "unreadable manifest"}` }));
  }

  /**
   * `/wfm-cancel [RUN_ID]`: cancel a service run after a confirmation, only
   * when its controls allow the cancel. The receipt records the runtime
   * acknowledgement, and the snapshot of the run then states its terminal
   * status, which the command reports. With `model`, the confirmation
   * shows the kind and the run of the model-initiated cancel. Gives whether
   * the runtime accepted the cancel.
   */
  async cancel(ctx: ExtensionContext, args: string, model = false): Promise<boolean> {
    const session = this.#session(ctx);
    const service = this.#service();
    if (session === undefined || service === undefined) return false;
    if (!ctx.hasUI) return stopped(ctx, "/wfm-cancel requires the interactive Pi interface");
    const runId = await this.#chooseRun(ctx, args, this.#liveRuns(service), "Run to cancel");
    if (runId === undefined) return false;
    const read = await this.#controls(ctx, session, runId);
    if (read === undefined) return false;
    if (!cancelOffered(read.control)) return stopped(ctx, `The manager offers no cancel for run ${runId}. Nothing was sent.`, "warning");
    if (model) {
      if (!(await ctx.ui.confirm("Send manager control?", controlContent("cancel", runId, [])))) return declined(ctx, "cancel control");
    } else if (!(await ctx.ui.confirm("Cancel manager run?", runId))) return stopped(ctx, `No cancel was sent for run ${runId}.`, "info");
    const receipt = await this.#runControl(ctx, session, "cancel", read.observed, { operation: "cancel" });
    const ack = receipt === undefined ? undefined : acknowledgementOf(receipt);
    if (ack === undefined || !ACCEPTING.includes(ack.state)) return false;
    const snapshot = session.reference(`/v1/runs/${runId}/snapshot`);
    if (!snapshot.ok) return true;
    const ended = await session.waitFor(snapshot.value, (observed) => {
      const status = isJsonObject(observed.value) ? snapshotStatus(observed.value) : undefined;
      return status !== undefined && TERMINAL_STATUSES.includes(status);
    }, EFFECT_WAIT_MS);
    const status = ended.ok && isJsonObject(ended.value.value) ? snapshotStatus(ended.value.value) : undefined;
    ctx.ui.notify(status === undefined
      ? `Execution: run ${runId} has not reached a terminal status yet. /wfm-monitor ${runId} shows the run.`
      : `Execution: run ${runId} is ${status}.`, status === "cancelled" ? "info" : "warning");
    return true;
  }

  /**
   * `/wfm-steer [RUN_ID]`: steer the attempt of a steer offer of the run
   * with text from the editor and one of the timings of the offer. Empty
   * text sends nothing. The steer completes on the effect `steered`. With
   * `model`, the attempt, the timing and the text come from the model, they
   * must agree with a steer offer, and the confirmation shows the kind, the
   * run, the occurrence, the attempt, the timing and the text. Gives whether
   * the steer reached its effect.
   */
  async steer(ctx: ExtensionContext, args: string, model?: ModelSteer): Promise<boolean> {
    const session = this.#session(ctx);
    const service = this.#service();
    if (session === undefined || service === undefined) return false;
    if (!ctx.hasUI) return stopped(ctx, "/wfm-steer requires the interactive Pi interface");
    const runId = await this.#chooseRun(ctx, args, this.#liveRuns(service), "Run to steer");
    if (runId === undefined) return false;
    const read = await this.#controls(ctx, session, runId);
    if (read === undefined) return false;
    const offers = steerOffers(read.control);
    if (offers.length === 0) return stopped(ctx, `The manager offers no steer for run ${runId}. Nothing was sent.`, "warning");
    const labels = offers.map((offer) => `occurrence ${offer.occurrenceId} attempt ${offer.attemptId}`);
    let chosen: string | undefined;
    let message: string | undefined;
    let timing: string | undefined;
    if (model !== undefined) {
      chosen = `occurrence ${model.occurrenceId} attempt ${model.attemptId}`;
      const offered = offers.find((offer) => `occurrence ${offer.occurrenceId} attempt ${offer.attemptId}` === chosen);
      if (offered === undefined) return stopped(ctx, `The manager offers no steer for ${chosen} of run ${runId}. It offers ${labels.join(", ")}. Nothing was sent.`, "warning");
      if (!offered.timings.some((item) => item === model.timing)) {
        return stopped(ctx, `The steer offer of ${chosen} has the timings ${offered.timings.join(", ")}, not ${model.timing}. Nothing was sent.`, "warning");
      }
      if (!model.text.trim()) return stopped(ctx, `The steering text is empty. No steer was sent for run ${runId}.`, "warning");
      const content = controlContent("steer", runId, [["occurrence", model.occurrenceId], ["attempt", model.attemptId], ["timing", model.timing], ["text", JSON.stringify(model.text)]]);
      if (!(await ctx.ui.confirm("Send manager control?", content))) return declined(ctx, "steer control");
      [message, timing] = [model.text, model.timing];
    } else {
      chosen = labels.length === 1 ? labels[0] : await ctx.ui.select("Attempt to steer", labels);
      if (chosen === undefined) return stopped(ctx, `No steer was sent for run ${runId}.`, "info");
      message = await ctx.ui.editor(`Steering text for ${chosen} of run ${runId}`);
      if (message === undefined || !message.trim()) return stopped(ctx, `The steering text is empty. No steer was sent for run ${runId}.`, "info");
      const choice = offers[labels.indexOf(chosen)];
      timing = choice.timings.length === 1 ? choice.timings[0] : await ctx.ui.select("Steering timing", [...choice.timings]);
    }
    const offer = offers[labels.indexOf(chosen)];
    if (timing !== "interrupt-now" && timing !== "next-boundary") return stopped(ctx, `No steer was sent for run ${runId}.`, "info");
    const receipt = await this.#runControl(ctx, session, "steer", read.observed, {
      operation: "steer", occurrenceId: offer.occurrenceId.toString(), attemptId: String(offer.attemptId), timing, text: message,
    });
    if (receipt === undefined || effectKind(receipt) !== "steered") return false;
    ctx.ui.notify(`Steer ${timing} reached ${chosen} of run ${runId}.`, "info");
    return true;
  }

  /**
   * `/wfm-redirect [RUN_ID]`: redirect an occurrence to a target of a
   * redirect offer of the run. The manager offers the dispatch-window
   * redirect while the dispatch window of the occurrence is open, and the
   * live redirect for the attempt in flight of an occurrence that is not an
   * effect. One read of the run snapshot names the place of each offer. The
   * redirect completes on the effect `redirected`. With `model`, the
   * occurrence and the target come from the model, they must agree with a
   * redirect offer, and the confirmation shows the kind, the run, the
   * occurrence, the target and its place. Gives whether the redirect reached
   * its effect.
   */
  async redirect(ctx: ExtensionContext, args: string, model?: ModelRedirect): Promise<boolean> {
    const session = this.#session(ctx);
    const service = this.#service();
    if (session === undefined || service === undefined) return false;
    if (!ctx.hasUI) return stopped(ctx, "/wfm-redirect requires the interactive Pi interface");
    const runId = await this.#chooseRun(ctx, args, this.#liveRuns(service), "Run to redirect");
    if (runId === undefined) return false;
    const read = await this.#controls(ctx, session, runId);
    if (read === undefined) return false;
    const offers = redirectOffers(read.control);
    if (offers.length === 0) return stopped(ctx, `The manager offers no redirect for run ${runId}. Nothing was sent.`, "warning");
    const snapshotRef = session.reference(`/v1/runs/${runId}/snapshot`);
    if (!snapshotRef.ok) return false;
    const snapshot = await session.get(snapshotRef.value);
    if (!snapshot.ok || !isJsonObject(snapshot.value.value)) {
      return stopped(ctx, `The snapshot of run ${runId} could not be read: ${failureText(snapshot.ok ? null : snapshot.failure)}. Nothing was sent.`);
    }
    const snapshotValue = snapshot.value.value;
    const choices = offers.flatMap((offer) => {
      const place = redirectPlace(snapshotValue, offer.occurrenceId);
      return offer.targets.map((target) => ({ offer, target, place, label: `${target}  occurrence ${offer.occurrenceId}, ${placeText(place)}` }));
    });
    const labels = choices.map((choice) => choice.label);
    let choice: (typeof choices)[number];
    if (model !== undefined) {
      const offered = choices.find((item) => item.offer.occurrenceId.toString() === model.occurrenceId && item.target === model.target);
      if (offered === undefined) {
        return stopped(ctx, `The manager offers no redirect of occurrence ${model.occurrenceId} of run ${runId} to ${JSON.stringify(model.target)}. `
          + `It offers ${labels.join("; ")}. Nothing was sent.`, "warning");
      }
      const content = controlContent("redirect", runId, [["occurrence", model.occurrenceId], ["target", JSON.stringify(model.target)], ["place", placeText(offered.place)]]);
      if (!(await ctx.ui.confirm("Send manager control?", content))) return declined(ctx, "redirect control");
      choice = offered;
    } else {
      const selected = await ctx.ui.select(`Redirect target of run ${runId}`, labels);
      if (selected === undefined) return stopped(ctx, `No redirect was sent for run ${runId}.`, "info");
      choice = choices[labels.indexOf(selected)];
    }
    const receipt = await this.#runControl(ctx, session, "redirect", read.observed,
      { operation: "redirect", occurrenceId: choice.offer.occurrenceId.toString(), target: choice.target });
    if (receipt === undefined || effectKind(receipt) !== "redirected") return false;
    const from = choice.place.kind === "attempt" ? ` from attempt ${choice.place.attemptId}` : "";
    ctx.ui.notify(`Redirected occurrence ${choice.offer.occurrenceId} of run ${runId}${from} to ${choice.target}.`, "info");
    return true;
  }

  /** The terminal service runs of the active binding, for the selection of a result, export or lineage command. */
  #terminalRuns(service: ServiceMode): { runId: string; label: string }[] {
    return service.runs().filter((run) => TERMINAL_STATUSES.includes(run.status))
      .map((run) => ({ runId: run.runId, label: `${run.runId}  ${run.status}  ${run.workflowId ?? "unreadable manifest"}` }));
  }

  /** One read of `/v1/runs/{id}`, decoded, or `undefined` after a notification. */
  async #run(ctx: ExtensionContext, session: ManagerSession, runId: string): Promise<RunItem | undefined> {
    const reference = session.reference(`/v1/runs/${runId}`);
    if (!reference.ok) return undefined;
    const observed = await session.get(reference.value);
    const run = observed.ok ? decodeRunItem(observed.value.value) : observed;
    if (!run.ok || run.value.id !== runId) {
      ctx.ui.notify(`Run ${runId} could not be read: ${failureText(run.ok ? null : run.failure)}`, "error");
      return undefined;
    }
    return run.value;
  }

  /**
   * The verified result bytes of a succeeded managed run. The run must have
   * succeeded with a referenced or verified result. The outputs of the run
   * are read until the manager states a verified result, whose artifact is
   * the one that the verification names. `ManagerSession.download` then
   * checks the downloaded bytes against that size and SHA-256.
   */
  async #verifiedResult(ctx: ExtensionContext, session: ManagerSession, runId: string)
    : Promise<{ bytes: Buffer; sha256: string } | undefined> {
    const run = await this.#run(ctx, session, runId);
    if (run === undefined) return undefined;
    if (run.content.kind === "unreadable") return void ctx.ui.notify(`Run ${runId} is unreadable (${run.content.category}). Nothing was saved.`, "warning");
    const { content } = run;
    if (content.supervision === "observer") {
      return void ctx.ui.notify(`Run ${runId} is a legacy entry. A legacy entry publishes no size and digest for its result, so nothing was retrieved.`, "warning");
    }
    if (content.runtime?.status !== "succeeded") {
      return void ctx.ui.notify(`Run ${runId} is ${itemStatus(run)}. Only a succeeded run has a verified result. Nothing was retrieved.`, "warning");
    }
    if (content.verification.state !== "verified" && content.verification.state !== "referenced") {
      return void ctx.ui.notify(`Run ${runId} has no verified result: verification is ${content.verification.state}. Nothing was retrieved.`, "warning");
    }
    const outputs = session.reference(`/v1/runs/${runId}/outputs`);
    if (!outputs.ok) return undefined;
    // Reading the outputs makes the manager verify a referenced result, and
    // the change of the run reads them again.
    const read = await session.waitFor(outputs.value, (observed) => verifiedArtifact(observed.value) !== undefined, EFFECT_WAIT_MS);
    const artifact = read.ok ? verifiedArtifact(read.value.value) : undefined;
    if (!read.ok || artifact === undefined) {
      return void ctx.ui.notify(`The manager states no verified result for run ${runId}: ${failureText(read.ok ? null : read.failure)}. Nothing was retrieved.`, "error");
    }
    const location = session.reference(artifact.download);
    const bytes = location.ok ? await session.download(location.value, artifact.bytes, artifact.sha256) : location;
    if (!bytes.ok) return void ctx.ui.notify(`The result of run ${runId} was not retrieved: ${failureText(bytes.failure)}. Nothing was saved.`, "error");
    return { bytes: bytes.value, sha256: artifact.sha256 };
  }

  /**
   * `/wfm-result [RUN_ID [PATH]]`: retrieve the verified result of a
   * succeeded run, check its size and SHA-256 against the verification of
   * the manager, and save the exact bytes to a new file at the path that the
   * user names through `saveExact`. A relative path names a file below the
   * current directory of Pi. An existing path refuses the save, and nothing
   * is written.
   *
   * With `model`, the path comes from the model. A model-initiated save is a
   * local mutation, so it is written only after the human confirms the path,
   * the size and the SHA-256 in Pi. Without a path, the command gives the
   * verified bytes as UTF-8 text when they are valid UTF-8, and saves
   * nothing. Gives whether the result was retrieved and, when a path was
   * named, saved.
   */
  async result(ctx: ExtensionContext, args: string, model?: { readonly path: string | undefined }): Promise<boolean> {
    const session = this.#session(ctx);
    const service = this.#service();
    if (session === undefined || service === undefined) return false;
    const { run, rest } = runAndRest(args);
    const runId = await this.#chooseRun(ctx, run, this.#terminalRuns(service), "Run whose result to save");
    if (runId === undefined) return false;
    const verified = await this.#verifiedResult(ctx, session, runId);
    if (verified === undefined) return false;
    const summary = `Run ${runId}: verified ${verified.bytes.length} bytes, SHA-256 ${verified.sha256}.`;
    const named = model !== undefined ? model.path
      : rest || (ctx.hasUI ? await ctx.ui.input(`Path of a new file for the verified ${verified.bytes.length} bytes of run ${runId}`) : undefined);
    if (!named) {
      if (model === undefined) ctx.ui.notify(`${summary} No path was named, so nothing was saved.`, "info");
      else {
        let decoded: string | undefined;
        try {
          decoded = new TextDecoder("utf-8", { fatal: true }).decode(verified.bytes);
        } catch {
          decoded = undefined;
        }
        ctx.ui.notify(decoded === undefined ? `${summary} The bytes are not UTF-8 text, so the result gives no text. Nothing was saved.`
          : `${summary} Nothing was saved. The exact UTF-8 text follows.\n${decoded}`, "info");
      }
      return true;
    }
    const path = resolve(ctx.cwd, named);
    if (model !== undefined) {
      if (!ctx.hasUI) return stopped(ctx, "A save of a manager result requires an interactive Pi UI for the human confirmation of its path. Nothing was written.");
      if (!(await ctx.ui.confirm("Save manager result?", `run=${runId}\npath=${path}\nbytes=${verified.bytes.length}\nsha256=${verified.sha256}`))) {
        return declined(ctx, `save of the result of run ${runId}`);
      }
    }
    const saved = await saveExact(path, verified.bytes);
    if (!saved.saved) return stopped(ctx, `The result of run ${runId} was not saved to ${path}: ${saved.reason}. Nothing was written there.`);
    const leftover = saved.leftover === null ? "" : ` The private file ${saved.leftover} could not be removed.`;
    ctx.ui.notify(`Saved the verified ${verified.bytes.length} bytes of run ${runId} to ${path}, SHA-256 ${verified.sha256}.${leftover}`, "info");
    return true;
  }

  /**
   * `/wfm-history`: every run of `/v1/runs` over all its pages, managed runs
   * and legacy entries in the identifier order of the collection, each with
   * `historyLine`.
   */
  async history(ctx: ExtensionContext): Promise<void> {
    const session = this.#session(ctx);
    if (session === undefined) return;
    const listed = await this.#collection(session, "/v1/runs");
    if (!listed.ok) return ctx.ui.notify(`The run history could not be read: ${failureText(listed.failure)}`, "error");
    const runs: RunItem[] = [];
    for (const item of listed.value) {
      const run = decodeRunItem(item);
      if (!run.ok) return ctx.ui.notify(`The run history could not be read: ${failureText(run.failure)}`, "error");
      runs.push(run.value);
    }
    ctx.ui.notify(historyLines(runs).join("\n"), "info");
  }

  /**
   * `/wfm-restart`, `/wfm-resume` and `/wfm-fork [RUN_ID]`: create a child
   * request of a run through its lineage collection, with the entity tag of
   * the first page as `If-Match`, only when the page lists the operation as
   * eligible. A fork first collects its edits: drop or replace the answer of
   * each completed occurrence, where a replacement is typed by the code of
   * the occurrence. The child inputs come from the parent run, so the child
   * is enqueued at once, and its exact review, with its lineage rows, opens
   * in the review component. Only an explicit approval starts the child run.
   *
   * With `model`, the fork edits come from the model and are typed as the
   * editor text of the human path. The lineage request is sent only after
   * the human confirms the operation, the run and each edit in Pi, and the
   * child run starts only after the human approves its exact review. Gives
   * whether the child run started.
   */
  async lineage(ctx: ExtensionContext, operation: LineageOperation, args: string,
    model?: { readonly edits: readonly ModelForkEdit[] }): Promise<boolean> {
    const session = this.#session(ctx);
    const service = this.#service();
    if (session === undefined || service === undefined) return false;
    if (!ctx.hasUI) return stopped(ctx, `/wfm-${operation} requires the interactive Pi interface`);
    if (model !== undefined && operation !== "fork" && model.edits.length > 0) return stopped(ctx, `A ${operation} takes no fork edits. Nothing was sent.`, "warning");
    const runId = await this.#chooseRun(ctx, args, this.#terminalRuns(service), `Run to ${operation}`);
    if (runId === undefined) return false;
    const collection = session.reference(`/v1/runs/${runId}/lineage-requests`);
    if (!collection.ok) return false;
    const observed = await session.get(collection.value);
    const page = observed.ok ? decodeLineageCollection(observed.value.value) : observed;
    if (!observed.ok || !page.ok || page.value.runId !== runId || observed.value.etag !== `"${page.value.revision}"`) {
      return stopped(ctx, `The lineage collection of run ${runId} could not be read: ${failureText(page.ok ? null : page.failure)}. Nothing was sent.`);
    }
    const { eligible, refusal } = page.value;
    if (!eligible.includes(operation)) {
      return stopped(ctx, eligible.length === 0
        ? `${operation} is not eligible: the manager lists no lineage operation for run ${runId}; refusal ${refusal ?? "none"}. Nothing was sent.`
        : `${operation} is not eligible: the manager lists only ${eligible.join(", ")} for run ${runId}. Nothing was sent.`, "warning");
    }
    let edits: ForkEdit[] = [];
    if (operation === "fork") {
      const chosen = model === undefined ? await this.#forkEdits(ctx, session, runId) : await this.#modelForkEdits(ctx, session, runId, model.edits);
      if (chosen === undefined) return false;
      edits = chosen;
    }
    if (model !== undefined) {
      const content = [`operation=${operation}`, `run=${runId}`, ...edits.map((edit) => edit.operation === "drop"
        ? `edit drop occurrence ${edit.occurrenceId}` : `edit replace occurrence ${edit.occurrenceId} value=${encodeJson(edit.answer)}`)];
      if (!(await ctx.ui.confirm(`${operation} manager run?`, content.join("\n")))) return declined(ctx, `${operation} of run ${runId}`);
    }
    const known = new Set(page.value.children.map((child) => child.id));
    const sent = await this.#command(ctx, session, operation, collection.value.uri,
      session.prepare(collection.value, lineageBody(operation, edits), observed.value.etag), true, (value) => {
        const current = decodeLineageCollection(value);
        return current.ok && current.value.children.some((child) => !known.has(child.id) && child.lineage === operation);
      });
    if (sent.kind !== "receipt" || sent.state !== "effect-observed") return false;
    const resource = sent.receipt === undefined ? undefined : effectResource(sent.receipt);
    if (sent.receipt === undefined || effectKind(sent.receipt) !== "lineage-created" || resource === undefined || !resource.startsWith("/v1/requests/")) {
      return stopped(ctx, `The ${operation} of run ${runId} created a child request. /wfm-review continues it.`, "info");
    }
    const child = session.reference(resource);
    if (!child.ok) return false;
    ctx.ui.notify(`Lineage: ${operation} of run ${runId} created child request ${resource.slice("/v1/requests/".length)}. `
      + "Its inputs come from the parent run.", "info");
    return this.#continue(ctx, session, child.value);
  }

  /** The fork targets of one read of the snapshot of a run, or `undefined` after a notification. */
  async #forkTargets(ctx: ExtensionContext, session: ManagerSession, runId: string): Promise<ForkTarget[] | undefined> {
    const reference = session.reference(`/v1/runs/${runId}/snapshot`);
    if (!reference.ok) return undefined;
    const snapshot = await session.get(reference.value);
    if (!snapshot.ok || !isJsonObject(snapshot.value.value)) {
      return void ctx.ui.notify(`The snapshot of run ${runId} could not be read: ${failureText(snapshot.ok ? null : snapshot.failure)}. Nothing was sent.`, "error");
    }
    const targets = forkTargets(snapshot.value.value);
    if (targets.length === 0) return void ctx.ui.notify(`Run ${runId} has no completed occurrence whose answer a fork edits. Nothing was sent.`, "warning");
    return targets;
  }

  /**
   * The fork edits of a model, typed by the code of each occurrence of the
   * snapshot as `#forkEdits` types the editor text. An edit of an occurrence
   * that the snapshot does not list, a second edit of one occurrence, and a
   * refused replacement give `undefined` after a notification.
   */
  async #modelForkEdits(ctx: ExtensionContext, session: ManagerSession, runId: string, edits: readonly ModelForkEdit[])
    : Promise<ForkEdit[] | undefined> {
    const targets = await this.#forkTargets(ctx, session, runId);
    if (targets === undefined) return undefined;
    const typed = new Map<string, ForkEdit>();
    for (const edit of edits) {
      const target = targets.find((item) => item.occurrenceId.toString() === edit.occurrenceId);
      if (target === undefined) {
        return void ctx.ui.notify(`Run ${runId} has no completed occurrence ${edit.occurrenceId}. A fork edits only `
          + `${targets.map((item) => item.occurrenceId).join(", ")}. Nothing was sent.`, "warning");
      }
      if (typed.has(edit.occurrenceId)) return void ctx.ui.notify(`Occurrence ${edit.occurrenceId} has more than one edit. Nothing was sent.`, "warning");
      if (edit.type === "drop") typed.set(edit.occurrenceId, { operation: "drop", occurrenceId: target.occurrenceId });
      else {
        const answer = forkReplacementValue(target.code, edit.value);
        if (!answer.ok) {
          return void ctx.ui.notify(`The replacement of occurrence ${edit.occurrenceId} (${target.code}) is refused before any send: ${answer.failure.reason}. `
            + "Nothing was sent.", "warning");
        }
        typed.set(edit.occurrenceId, { operation: "replace", occurrenceId: target.occurrenceId, answer: answer.value });
      }
    }
    return [...typed.values()];
  }

  /**
   * Collect the edits of a fork of a run from its snapshot: for each
   * completed or reused occurrence, keep, drop or replace its answer. A
   * replacement opens the editor and is typed by `forkReplacementValue`, and
   * a refused text opens the editor again with the text. Gives the edits
   * when the user sends the fork, and `undefined` when the user stops.
   */
  async #forkEdits(ctx: ExtensionContext, session: ManagerSession, runId: string): Promise<ForkEdit[] | undefined> {
    const targets = await this.#forkTargets(ctx, session, runId);
    if (targets === undefined) return undefined;
    const edits = new Map<bigint, ForkEdit>();
    const send = "Send the fork with these edits";
    const stop = "Stop without a fork";
    for (;;) {
      const labels = targets.map((target) => `occurrence ${target.occurrenceId} (${target.code}): ${editLabel(edits.get(target.occurrenceId))}; ${oneLine(target.intent)}`);
      const selected = await ctx.ui.select(`Fork edits of run ${runId}`, [...labels, send, stop]);
      if (selected === send) return [...edits.values()];
      if (selected === undefined || selected === stop) return void ctx.ui.notify(`No fork was sent for run ${runId}.`, "info");
      const target = targets[labels.indexOf(selected)];
      const action = await ctx.ui.select(`Answer of occurrence ${target.occurrenceId} of run ${runId}`, ["Keep the answer", "Drop the answer", "Replace the answer"]);
      if (action === "Keep the answer") edits.delete(target.occurrenceId);
      else if (action === "Drop the answer") edits.set(target.occurrenceId, { operation: "drop", occurrenceId: target.occurrenceId });
      else if (action === "Replace the answer") {
        const current = edits.get(target.occurrenceId);
        let draft = current?.operation === "replace" ? (typeof current.answer === "string" && target.code === "text" ? current.answer : encodeJson(current.answer))
          : target.answer ?? "";
        for (;;) {
          const entered = await ctx.ui.editor(`Replacement answer of occurrence ${target.occurrenceId} (${target.code})`, draft);
          if (entered === undefined) break;
          draft = entered;
          const answer = forkReplacementValue(target.code, entered);
          if (answer.ok) {
            edits.set(target.occurrenceId, { operation: "replace", occurrenceId: target.occurrenceId, answer: answer.value });
            break;
          }
          ctx.ui.notify(`The replacement is refused before any send: ${answer.failure.reason}. The editor opens again with the text.`, "warning");
        }
      }
    }
  }

  /**
   * `/wfm-export [RUN_ID [NAME]]`: export the verified result of a run as
   * `NAME` with the entity tag of the first page of its export collection as
   * `If-Match`. After the effect `exported`, the command reads the export
   * receipt that the effect names, downloads the exported bytes and checks
   * them against the size and SHA-256 of the receipt, and lists the export
   * collection of the run.
   *
   * With `model`, the name comes from the arguments that the model gives,
   * and the export is sent only after the human confirms its scope, the
   * verified result of the run, and its name in Pi. Gives whether the
   * exported bytes verified.
   */
  async export(ctx: ExtensionContext, args: string, model = false): Promise<boolean> {
    const session = this.#session(ctx);
    const service = this.#service();
    if (session === undefined || service === undefined) return false;
    const { run, rest } = runAndRest(args);
    const runId = await this.#chooseRun(ctx, run, this.#terminalRuns(service), "Run whose result to export");
    if (runId === undefined) return false;
    const name = rest || (ctx.hasUI && !model ? await ctx.ui.input(`Export name for the verified result of run ${runId}`) : undefined);
    if (!name) return stopped(ctx, `No export name was named for run ${runId}. Nothing was sent.`, "info");
    if (!exportNameValid(name)) {
      return stopped(ctx, "The export name must be 1 to 128 ASCII letters, digits, dots, underscores or hyphens that start with a letter or a digit. "
        + "Nothing was sent.", "warning");
    }
    const collection = session.reference(`/v1/runs/${runId}/exports`);
    if (!collection.ok) return false;
    const observed = await session.get(collection.value);
    const page = observed.ok ? decodeExportCollection(observed.value.value) : observed;
    if (!observed.ok || !page.ok || page.value.runId !== runId || observed.value.etag !== `"${page.value.revision}"`) {
      return stopped(ctx, `The export collection of run ${runId} could not be read: ${failureText(page.ok ? null : page.failure)}. Nothing was sent.`);
    }
    if (model) {
      if (!ctx.hasUI) return stopped(ctx, "A model-initiated export requires an interactive Pi UI for the human confirmation of its scope and name. Nothing was sent.");
      if (!(await ctx.ui.confirm("Export manager result?", `scope=verified result of run ${runId}\nname=${name}`))) return declined(ctx, `export ${name} of run ${runId}`);
    }
    const sent = await this.#command(ctx, session, "export", collection.value.uri,
      session.prepare(collection.value, { name }, observed.value.etag), true, (value) => {
        const current = decodeExportCollection(value);
        return current.ok && current.value.items.some((item) => item.name === name && item.state === "published");
      });
    if (sent.kind !== "receipt" || sent.state !== "effect-observed") return false;
    if (sent.receipt === undefined || effectKind(sent.receipt) !== "exported" || effectResource(sent.receipt) !== `/v1/exports/export_${sent.receipt.id}`) {
      await this.#listExports(ctx, session, runId);
      return false;
    }
    const command = sent.receipt.id;
    const detail = session.reference(`/v1/exports/export_${command}`);
    if (!detail.ok) return false;
    const read = await session.get(detail.value);
    const receipt = read.ok ? decodeExportReceipt(read.value.value) : read;
    if (!receipt.ok || receipt.value.id !== `export_${command}` || receipt.value.commandId !== command || receipt.value.runId !== runId
      || receipt.value.name !== name || receipt.value.state !== "published" || receipt.value.bytes === null || receipt.value.sha256 === null
      || receipt.value.download === null) {
      return stopped(ctx, `The export receipt export_${command} does not state the published export: ${failureText(receipt.ok ? null : receipt.failure)}`);
    }
    const location = session.reference(receipt.value.download);
    const bytes = location.ok ? await session.download(location.value, receipt.value.bytes, receipt.value.sha256) : location;
    if (!bytes.ok) return stopped(ctx, `The export ${name} of run ${runId} did not verify: ${failureText(bytes.failure)}`);
    ctx.ui.notify(exportLines(receipt.value, bytes.value.length).join("\n"), "info");
    await this.#listExports(ctx, session, runId);
    return true;
  }

  /** Read the export collection of a run once and list its receipts. */
  async #listExports(ctx: ExtensionContext, session: ManagerSession, runId: string): Promise<void> {
    const collection = session.reference(`/v1/runs/${runId}/exports`);
    if (!collection.ok) return;
    const observed = await session.get(collection.value);
    const page = observed.ok ? decodeExportCollection(observed.value.value) : observed;
    if (!page.ok) return ctx.ui.notify(`The export collection of run ${runId} could not be read: ${failureText(page.failure)}`, "error");
    ctx.ui.notify([`Exports of run ${runId}: ${page.value.items.length}`, ...page.value.items.map(exportItemLine)].join("\n"), "info");
  }

  /** The complete page set of a collection, read again after a transient page-set refusal. */
  async #collection(session: ManagerSession, uri: string): Promise<Outcome<JsonObject[]>> {
    const reference = session.reference(uri);
    if (!reference.ok) return reference;
    for (let attempt = 0; ; attempt += 1) {
      const set = await session.pageSet(reference.value);
      if (set.ok) return { ok: true, value: itemsOf(set.value.items) };
      const transient = set.failure.kind === "Refused" && set.failure.status === 429 && set.failure.code === "storage-quota";
      if (!transient || attempt >= 50) return set;
      await new Promise((wake) => setTimeout(wake, 200));
    }
  }

  async #read(ctx: ExtensionContext, session: ManagerSession, reference: Reference): Promise<{ observed: Observed; request: DraftView } | undefined> {
    const observed = await session.get(reference);
    const request = observed.ok ? decodeDraftView(observed.value.value) : undefined;
    if (!observed.ok || request === undefined || !request.ok) {
      ctx.ui.notify(`The request ${reference.uri} could not be read: ${observed.ok ? "InvalidResponse" : failureText(observed.failure)}`, "error");
      return undefined;
    }
    return { observed: observed.value, request: request.value };
  }

  /** The ready profiles of the credential and the catalogue of each, as complete page sets, or `undefined` after a notification. */
  async #catalogue(ctx: ExtensionContext, session: ManagerSession): Promise<Array<{ profile: ProfileRow; workflows: WorkflowRow[] }> | undefined> {
    const profiles = await this.#collection(session, "/v1/profiles");
    if (!profiles.ok) return void ctx.ui.notify(`The manager profiles could not be read: ${failureText(profiles.failure)}`, "error");
    const rows = profiles.value.map(profileRow).filter((row): row is ProfileRow => row !== undefined && row.ready);
    if (rows.length === 0) return void ctx.ui.notify("The manager offers no ready profile to this credential", "error");
    const listed: Array<{ profile: ProfileRow; workflows: WorkflowRow[] }> = [];
    for (const profile of rows) {
      const catalogue = await this.#collection(session, `/v1/workflows?profileId=${profile.id}`);
      if (!catalogue.ok) return void ctx.ui.notify(`The catalogue of ${profile.id} could not be read: ${failureText(catalogue.failure)}`, "error");
      listed.push({ profile, workflows: catalogue.value.map(workflowRow).filter((row): row is WorkflowRow => row !== undefined && row.profileId === profile.id) });
    }
    return listed;
  }

  /**
   * The catalogue of the manager in one notification: each ready profile
   * with its workspace and target, and each workflow of its catalogue with
   * its declared inputs. The command sends nothing. Gives whether the
   * catalogue was read.
   */
  async catalogue(ctx: ExtensionContext): Promise<boolean> {
    const session = this.#session(ctx);
    if (session === undefined) return false;
    const listed = await this.#catalogue(ctx, session);
    if (listed === undefined) return false;
    const lines = listed.flatMap(({ profile, workflows }) => [
      `Profile ${profile.id}  ${profile.workspace}  ${profile.target}`,
      ...(workflows.length === 0 ? ["  no workflow"] : workflows.map((row) =>
        `  ${row.name}  inputs ${row.inputs.map((input) => `${input.name} (${input.source})`).join(", ") || "none"}${row.blurb ? `  ${row.blurb}` : ""}`)),
    ]);
    ctx.ui.notify(lines.join("\n"), "info");
    return true;
  }

  /**
   * `/wfm [WORKFLOW]`: select a profile and a workflow, create a request,
   * collect its inputs, enqueue it, follow its admission, and open its
   * review.
   *
   * With `model`, the profile, the workflow and the exact literal of each
   * declared input come from the model. The model must name every declared
   * input and no other. The request is created only after the human
   * confirms the profile, the workflow, its revisions and each input value
   * in Pi. The request then follows the human path: `set-input` of each
   * literal, `enqueue`, and the exact review, whose approval needs its own
   * confirmation. Gives whether the manager started the run.
   */
  async start(ctx: ExtensionContext, args: string, model?: ModelStart): Promise<boolean> {
    const session = this.#session(ctx);
    if (session === undefined) return false;
    if (!ctx.hasUI) return stopped(ctx, "/wfm requires the interactive Pi interface");
    const listed = await this.#catalogue(ctx, session);
    if (listed === undefined) return false;
    let chosenProfile = listed[0];
    if (model?.profileId !== undefined) {
      const named = listed.find((row) => row.profile.id === model.profileId);
      if (named === undefined) return stopped(ctx, `The manager offers no ready profile ${model.profileId}. Nothing was sent.`, "warning");
      chosenProfile = named;
    } else if (listed.length > 1) {
      if (model !== undefined) {
        return stopped(ctx, `The manager offers the ready profiles ${listed.map((row) => row.profile.id).join(", ")}. Name one with profileId. Nothing was sent.`, "warning");
      }
      const labels = listed.map(({ profile }) => `${profile.id}  ${profile.workspace}  ${profile.target}`);
      const chosen = await ctx.ui.select("Manager profile", labels);
      if (chosen === undefined) return false;
      chosenProfile = listed[labels.indexOf(chosen)];
    }
    const { profile, workflows } = chosenProfile;
    const name = model?.workflow ?? args.trim();
    let workflow: WorkflowRow | undefined;
    if (name) {
      workflow = workflows.find((row) => row.name === name);
      if (workflow === undefined) return stopped(ctx, `The catalogue of ${profile.id} has no workflow ${name}`);
    } else {
      const labels = workflows.map((row) => (row.blurb ? `${row.name}  ${row.blurb}` : row.name));
      const chosen = await ctx.ui.select(`Workflow of ${profile.id}`, labels);
      if (chosen === undefined) return false;
      workflow = workflows[labels.indexOf(chosen)];
    }
    if (model !== undefined) {
      const declared = workflow.inputs.map((input) => input.name);
      const given = Object.keys(model.inputs);
      if (given.length !== declared.length || declared.some((input) => !Object.hasOwn(model.inputs, input))) {
        return stopped(ctx, `The inputs of ${workflow.name} must be exactly: ${declared.join(", ") || "(none)"}. Nothing was sent.`, "warning");
      }
      const content = [
        `profile=${profile.id}`, `workspace=${profile.workspace}`, `target=${profile.target}`, `workflow=${workflow.name} (${workflow.id})`,
        `descriptorRevision=${workflow.revision}`, `profileRevision=${workflow.profileRevision}`,
        ...declared.map((input) => `input ${input}=${JSON.stringify(model.inputs[input])} (literal)`),
      ];
      if (!(await ctx.ui.confirm("Create manager request?", content.join("\n")))) return declined(ctx, `request of ${workflow.name}`);
    }
    const requests = session.reference("/v1/requests");
    if (!requests.ok) return false;
    const created = await this.#command(ctx, session, "create", requests.value.uri, session.prepare(requests.value, {
      workflowId: workflow.id, descriptorRevision: workflow.revision, profileId: workflow.profileId, profileRevision: workflow.profileRevision,
    }, null));
    if (created.kind !== "created") return false;
    ctx.ui.notify(admissionLine(created.request), "info");
    return this.#continue(ctx, session, created.location, model?.inputs);
  }

  /**
   * `/wfm-review [REQUEST_ID]`: continue a request of the active binding. A
   * draft collects its missing inputs and is enqueued, a queued or preparing
   * request is followed, and a request in review shows its review.
   */
  async review(ctx: ExtensionContext, args: string): Promise<void> {
    const session = this.#session(ctx);
    if (session === undefined) return;
    if (!ctx.hasUI) return ctx.ui.notify("/wfm-review requires the interactive Pi interface", "error");
    const reference = await this.#chooseRequest(ctx, session, args, OPEN_PHASES, "Request to continue");
    if (reference !== undefined) await this.#continue(ctx, session, reference, undefined);
  }

  /** `/wfm-withdraw [REQUEST_ID]`: withdraw a request before its start intent. */
  async withdraw(ctx: ExtensionContext, args: string): Promise<void> {
    const session = this.#session(ctx);
    if (session === undefined) return;
    const reference = await this.#chooseRequest(ctx, session, args, OPEN_PHASES, "Request to withdraw");
    if (reference !== undefined) await this.#withdraw(ctx, session, reference);
  }

  /** `/wfm-discard [REQUEST_ID]`: discard the live preparation of a request in review. */
  async discard(ctx: ExtensionContext, args: string): Promise<void> {
    const session = this.#session(ctx);
    if (session === undefined) return;
    const reference = await this.#chooseRequest(ctx, session, args, ["review"], "Request whose review to discard");
    if (reference === undefined) return;
    const read = await this.#read(ctx, session, reference);
    if (read === undefined) return;
    if (read.request.preparationId === null) return ctx.ui.notify(`Request ${read.request.id} has no preparation`, "error");
    const preparation = session.reference(`/v1/preparations/${read.request.preparationId}`);
    if (!preparation.ok) return;
    const observed = await session.get(preparation.value);
    if (!observed.ok) return ctx.ui.notify(`The preparation could not be read: ${failureText(observed.failure)}`, "error");
    await this.#discard(ctx, session, preparation.value, observed.value.etag, read.request.id);
  }

  /**
   * `/wfm-monitor [RUN_ID]`: the live monitor of a service run. In the Pi TUI
   * it is a `ServiceMonitorComponent` that each change of service mode draws
   * again, until `q` or Escape. Outside the TUI, one notification gives the
   * lines after the first reads. The monitor sends no command.
   */
  async monitor(ctx: ExtensionContext, args: string): Promise<void> {
    const session = this.#session(ctx);
    const service = this.#service();
    if (session === undefined || service === undefined) return;
    const runId = await this.#chooseRun(ctx, args, service.runs().map((run) => ({ runId: run.runId, label: `${run.runId}  ${run.status}  ${run.workflowId ?? "unreadable manifest"}` })),
      "Run to monitor");
    if (runId === undefined) return;
    if (ctx.mode !== "tui") {
      await this.#inspect(ctx, session, runId);
      return;
    }
    const opened = ServiceMonitor.open(session, runId);
    if (!opened.ok) return ctx.ui.notify(`Run ${runId} cannot be monitored: ${failureText(opened.failure)}`, "error");
    const monitor = opened.value;
    await ctx.ui.custom<void>((tui, theme, _keys, done) => {
      let unsubscribe = () => {};
      const component = new ServiceMonitorComponent(tui, theme, monitor, () => {
        unsubscribe();
        monitor.close();
        done();
      });
      unsubscribe = service.subscribe(() => {
        monitor.refresh();
        tui.requestRender();
      });
      const started = monitor.start(() => tui.requestRender());
      if (!started.ok) ctx.ui.notify(`Run ${runId} cannot be watched: ${failureText(started.failure)}`, "error");
      return component;
    });
  }

  /**
   * The monitor lines of a run in one notification, after the first reads,
   * as `/wfm-monitor` gives them outside the Pi TUI. The command sends
   * nothing. Gives whether the run was watched.
   */
  async inspect(ctx: ExtensionContext, args: string): Promise<boolean> {
    const session = this.#session(ctx);
    const service = this.#service();
    if (session === undefined || service === undefined) return false;
    const runId = await this.#chooseRun(ctx, args, service.runs().map((run) => ({ runId: run.runId, label: run.runId })), "Run to inspect");
    return runId !== undefined && this.#inspect(ctx, session, runId);
  }

  async #inspect(ctx: ExtensionContext, session: ManagerSession, runId: string): Promise<boolean> {
    const opened = ServiceMonitor.open(session, runId);
    if (!opened.ok) return stopped(ctx, `Run ${runId} cannot be monitored: ${failureText(opened.failure)}`);
    const monitor = opened.value;
    const started = monitor.start(() => {});
    if (!started.ok) return stopped(ctx, `Run ${runId} cannot be watched: ${failureText(started.failure)}`);
    await monitor.settled(EFFECT_WAIT_MS);
    monitor.close();
    ctx.ui.notify(monitor.lines().join("\n"), "info");
    return true;
  }

  /** The kept answer draft of a decision of the active binding. */
  answerDraft(decisionId: string): string | undefined {
    const session = this.#service()?.session;
    return session === undefined ? undefined : this.#answerDrafts.get(answerKey(session, decisionId));
  }

  /**
   * `/wfm-answer [RUN_ID]`: act on the head decision of a run, as the queue
   * `/v1/decisions?runId=RUN_ID` gives it. A question opens the typed editor,
   * and `answerValue` gives the typed JSON value, so the flag input `no`
   * gives JSON `false`. The answer binds the decision revision that was read
   * before the editor opened. A 412 `stale-revision` keeps the typed text as
   * a draft, states it, and sends nothing again. The editor opens again with
   * the draft only while the same decision is still the pending head, and a
   * decision that another client answered reads as 404
   * `unavailable-resource`, since the manager serves only pending
   * decisions. A
   * recovery decision offers only the choices of `recoveryActions`.
   *
   * With `model`, the typed text of an answer, or a recovery choice and its
   * target, comes from the model, and the head must be a question or a
   * recovery decision to match. The command is sent only after the human
   * confirms the decision and the typed value, or the recovery choice, in
   * Pi. Gives whether the answer or the choice reached its effect.
   */
  async answer(ctx: ExtensionContext, args: string, model?: ModelDecision): Promise<boolean> {
    const session = this.#session(ctx);
    const service = this.#service();
    if (session === undefined || service === undefined) return false;
    if (!ctx.hasUI) return stopped(ctx, "/wfm-answer requires the interactive Pi interface");
    const heads = service.decisions().filter((decision) => decision.state === "pending");
    const runId = await this.#chooseRun(ctx, args,
      heads.map((decision) => ({ runId: decision.runId, label: `${decision.runId}  ${decision.kind}  ${decision.decisionId}` })), "Run whose decision to answer");
    if (runId === undefined) return false;
    for (;;) {
      const head = await this.#head(ctx, session, runId);
      if (head === undefined) return false;
      const recovery = head.decision.content.kind === "recovery";
      if (model !== undefined && recovery !== (model.kind === "recovery")) {
        return stopped(ctx, recovery
          ? `The head decision ${head.decision.id} of run ${runId} is a recovery decision. A recovery choice answers it. Nothing was sent.`
          : `The head decision ${head.decision.id} of run ${runId} is a question. A typed answer answers it. Nothing was sent.`, "warning");
      }
      if (recovery) return this.#recover(ctx, session, head, model?.kind === "recovery" ? model : undefined);
      const answered = await this.#answerQuestion(ctx, session, head, model?.kind === "answer" ? model.text : undefined);
      if (answered !== "again") return answered;
    }
  }

  /** A run identifier from the arguments, or from a selection of the given runs. */
  async #chooseRun(ctx: ExtensionContext, args: string, runs: readonly { runId: string; label: string }[], title: string)
    : Promise<string | undefined> {
    const chosen = args.trim();
    if (chosen) {
      if (/^[A-Za-z0-9_-]+$/.test(chosen)) return chosen;
      ctx.ui.notify(`Unknown run ${chosen}`, "error");
      return undefined;
    }
    if (runs.length === 0) {
      ctx.ui.notify("No run of the manager is open for this command", "info");
      return undefined;
    }
    if (!ctx.hasUI) {
      ctx.ui.notify(`Usage: name a run: ${runs.map((run) => run.runId).join(", ")}`, "warning");
      return undefined;
    }
    const labels = runs.map((run) => run.label);
    const selected = await ctx.ui.select(title, labels);
    return selected === undefined ? undefined : runs[labels.indexOf(selected)].runId;
  }

  /**
   * The head decision of a run from its queue, with one read of the
   * decision and one read of the controls of the run, or `undefined` after a
   * notification.
   */
  async #head(ctx: ExtensionContext, session: ManagerSession, runId: string): Promise<Head | undefined> {
    const queue = await this.#collection(session, `/v1/decisions?runId=${runId}`);
    if (!queue.ok) {
      ctx.ui.notify(`The decision queue of run ${runId} could not be read: ${failureText(queue.failure)}`, "error");
      return undefined;
    }
    const listed = queue.value.map((item) => decodeDecision(item));
    const found = listed.find((decoded) => decoded.ok && decoded.value.position === 0 && decoded.value.state === "pending");
    if (found === undefined || !found.ok) {
      ctx.ui.notify(`Run ${runId} has no pending decision head. /wfm-monitor ${runId} shows the run.`, "info");
      return undefined;
    }
    const decisionRef = session.reference(`/v1/decisions/${found.value.id}`);
    const controlRef = session.reference(`/v1/runs/${runId}/control`);
    if (!decisionRef.ok || !controlRef.ok) return undefined;
    const [decisionRead, controlRead] = [await session.get(decisionRef.value), await session.get(controlRef.value)];
    const decision = decisionRead.ok ? decodeDecision(decisionRead.value.value) : decisionRead;
    const control = controlRead.ok ? decodeControl(controlRead.value.value) : controlRead;
    if (!decisionRead.ok || !decision.ok || !controlRead.ok || !control.ok) {
      const failure = !decision.ok ? decision.failure : !control.ok ? control.failure : null;
      ctx.ui.notify(`The head decision of run ${runId} could not be read: ${failureText(failure)}`, "error");
      return undefined;
    }
    return { runId, decision: decision.value, decisionObserved: decisionRead.value, control: control.value, controlObserved: controlRead.value };
  }

  /**
   * Answer a question head once through the typed editor, or with the typed
   * text of a model after the human confirms the decision and the typed
   * value. Gives `again` when a 412 left the same decision pending at the
   * head, so the editor opens again with the draft, and otherwise whether
   * the answer reached its effect. A model answer that receives 412 is not
   * sent again.
   */
  async #answerQuestion(ctx: ExtensionContext, session: ManagerSession, head: Head, supplied: string | undefined): Promise<boolean | "again"> {
    const { decision, runId } = head;
    if (decision.content.kind !== "question") return false;
    if (!decisionOffers(head.control, decision).some((offer) => offer.operation === "answer")) {
      return stopped(ctx, `The manager offers no answer for decision ${decision.id} of run ${runId}. Nothing was sent.`, "warning");
    }
    const key = answerKey(session, decision.id);
    let value: JsonValue;
    let typed: string;
    if (supplied !== undefined) {
      const answer = answerValue(decision, supplied);
      if (!answer.ok) return stopped(ctx, `The answer is refused before any send: ${answer.failure.reason}. Nothing was sent.`, "warning");
      [value, typed] = [answer.value, supplied];
      const content = [`decision=${decision.id}`, `run=${runId}`, `code=${codeLabel(decision)}`, `prompt=${JSON.stringify(decision.content.prompt)}`,
        `value=${encodeJson(value)}`];
      if (!(await ctx.ui.confirm("Send manager answer?", content.join("\n")))) return declined(ctx, `answer of decision ${decision.id}`);
    } else for (;;) {
      const entered = await ctx.ui.editor(`Answer of decision ${decision.id} (${codeLabel(decision)}): ${oneLine(decision.content.prompt)}`,
        this.#answerDrafts.get(key));
      if (entered === undefined) {
        ctx.ui.notify(`No answer was sent for decision ${decision.id}.`, "info");
        return false;
      }
      typed = entered;
      this.#answerDrafts.set(key, typed);
      const answer = answerValue(decision, typed);
      if (answer.ok) {
        value = answer.value;
        break;
      }
      ctx.ui.notify(`The answer is refused before any send: ${answer.failure.reason}. The draft is kept, and the editor opens again.`, "warning");
    }
    const target = head.decisionObserved.reference;
    const sent = await this.#command(ctx, session, "answer", target.uri, session.prepare(target, answerBody(decision, value), head.decisionObserved.etag),
      true, (observed) => {
        const current = decodeDecision(observed);
        return current.ok && current.value.state !== "pending";
      });
    if (sent.kind === "refused" && sent.failure.kind === "Refused" && sent.failure.status === 412) {
      if (supplied !== undefined) {
        return stopped(ctx, `Decision ${decision.id} changed before the answer arrived (412 stale-revision). Nothing was sent again.`, "warning");
      }
      ctx.ui.notify(`Decision ${decision.id} changed before the answer arrived (412 stale-revision). Nothing was sent again. `
        + `The draft ${JSON.stringify(typed)} is kept.`, "warning");
      // The manager serves only pending decisions, so a decision that was
      // answered elsewhere reads as 404 unavailable-resource.
      const again = await session.get(target);
      const current = again.ok ? decodeDecision(again.value.value) : again;
      if (current.ok && current.value.state === "pending" && current.value.position === 0) return "again";
      const reason = current.ok ? `state ${current.value.state}, position ${current.value.position}` : failureText(current.failure);
      ctx.ui.notify(`Decision ${decision.id} is no longer the pending head (${reason}), so the kept draft is not sent. `
        + `/wfm-answer ${runId} acts on the next head.`, "info");
      return false;
    }
    if (sent.kind !== "receipt" || sent.state !== "effect-observed") return false;
    this.#answerDrafts.delete(key);
    ctx.ui.notify(`Answer ${encodeJson(value)} reached decision ${decision.id} of run ${runId}.`, "info");
    return true;
  }

  /**
   * Send one recovery choice that the manager offers for a recovery head,
   * after the selection of the user, or the choice of a model after the
   * human confirms its kind, run, decision, occurrence and choice. A model
   * choice must name exactly one offered choice. Gives whether the choice
   * reached its effect.
   */
  async #recover(ctx: ExtensionContext, session: ManagerSession, head: Head,
    model: Extract<ModelDecision, { kind: "recovery" }> | undefined): Promise<boolean> {
    const { decision, runId } = head;
    if (decision.content.kind !== "recovery") return false;
    const actions = recoveryActions(head.control, decision);
    if (actions.length === 0) {
      return stopped(ctx, `The manager offers no recovery choice for decision ${decision.id} of run ${runId}. Nothing was sent.`, "warning");
    }
    const labels = actions.map((action) => action.label);
    let action: RecoveryAction;
    if (model !== undefined) {
      const matching = actions.filter((item) => item.option.choice === model.choice && (model.target === undefined || item.option.target === model.target));
      if (matching.length !== 1) {
        return stopped(ctx, `${matching.length === 0 ? "The manager offers no such recovery choice" : "More than one offered choice matches; name the target"} `
          + `for decision ${decision.id} of run ${runId}. It offers ${labels.join(", ")}. Nothing was sent.`, "warning");
      }
      action = matching[0];
      const content = controlContent(model.choice, runId, [["decision", decision.id], ["occurrence", decision.occurrenceId.toString()], ["choice", action.label]]);
      if (!(await ctx.ui.confirm("Send manager control?", content))) return declined(ctx, `${model.choice} control`);
    } else {
      const selected = await ctx.ui.select(`Recovery of decision ${decision.id} (${decision.content.gap}): ${oneLine(decision.content.message)}`, labels);
      if (selected === undefined) return stopped(ctx, `No recovery choice was sent for decision ${decision.id}.`, "info");
      action = actions[labels.indexOf(selected)];
    }
    const address = { occurrenceId: decision.occurrenceId.toString(), generation: decision.generation };
    const sent = action.operation === "retry"
      ? await this.#command(ctx, session, "retry", head.controlObserved.reference.uri,
        session.prepare(head.controlObserved.reference, { operation: "retry", ...address }, head.controlObserved.etag), true, (observed) => {
          const control = decodeControl(observed);
          return control.ok && control.value.decisionHeadId !== decision.id;
        })
      : await this.#command(ctx, session, "choose-recovery", head.decisionObserved.reference.uri,
        session.prepare(head.decisionObserved.reference, { operation: "choose-recovery", ...address, choice: action.option.choice },
          head.decisionObserved.etag), true, (observed) => {
          const current = decodeDecision(observed);
          return current.ok && current.value.state !== "pending";
        });
    if (sent.kind !== "receipt" || sent.state !== "effect-observed") return false;
    ctx.ui.notify(`Recovery ${action.label} reached decision ${decision.id} of run ${runId}.`, "info");
    return true;
  }

  async #chooseRequest(ctx: ExtensionContext, session: ManagerSession, args: string, phases: readonly string[], title: string)
    : Promise<Reference | undefined> {
    const chosen = args.trim();
    if (chosen) {
      const reference = session.reference(`/v1/requests/${chosen}`);
      if (!reference.ok || !/^[A-Za-z0-9_-]+$/.test(chosen)) {
        ctx.ui.notify(`Unknown request ${chosen}`, "error");
        return undefined;
      }
      return reference.value;
    }
    const open = (this.#service()?.requests() ?? []).filter((request) => phases.includes(request.phase));
    if (open.length === 0) {
      ctx.ui.notify("No request of the manager is open for this command", "info");
      return undefined;
    }
    if (!ctx.hasUI) {
      ctx.ui.notify(`Usage: name a request: ${open.map((request) => request.requestId).join(", ")}`, "warning");
      return undefined;
    }
    const labels = open.map((request) => `${request.requestId}  ${request.phase}  ${request.workflowId}`);
    const selected = await ctx.ui.select(title, labels);
    return selected === undefined ? undefined : open[labels.indexOf(selected)].reference;
  }

  /**
   * Continue a request from its current phase until its review is answered
   * or the user stops. `inputs` are the confirmed literals of a model start,
   * which `#collect` supplies in place of the dialogs. Gives whether the
   * manager started the run.
   */
  async #continue(ctx: ExtensionContext, session: ManagerSession, reference: Reference,
    inputs?: Readonly<Record<string, string>>): Promise<boolean> {
    const read = await this.#read(ctx, session, reference);
    if (read === undefined) return false;
    let { request } = read;
    if (request.phase === "draft") {
      if (!(await this.#collect(ctx, session, reference, inputs))) return false;
      const supplied = await this.#read(ctx, session, reference);
      if (supplied === undefined) return false;
      if (supplied.request.readiness.missing.length > 0 || supplied.request.readiness.errors.length > 0) {
        return stopped(ctx, admissionLine(supplied.request), "warning");
      }
      const enqueued = await this.#command(ctx, session, "enqueue", reference.uri,
        session.prepare(reference, { operation: "enqueue" }, supplied.observed.etag));
      if (enqueued.kind !== "receipt" || enqueued.state !== "effect-observed") return false;
      request = supplied.request;
    }
    if (!OPEN_PHASES.includes(request.phase)) return stopped(ctx, admissionLine(request), "info");
    return this.#awaitReview(ctx, session, reference);
  }

  /**
   * Collect each missing declared input with its exact bytes. A literal is
   * the exact editor text. A capture sends the exact editor text or the
   * exact bytes of a local file through `/v1/captures`, and `set-input`
   * binds its identifier. Each editor text is kept as a draft until its
   * `set-input` reaches its effect. The `set-input` binds the request
   * revision that was read before the editor opened, so a request that
   * changed during editing refuses it with 412, and the editor opens again
   * for the same input with the draft. Gives whether every input was
   * supplied.
   *
   * With `inputs`, each missing input is the confirmed literal of a model
   * start. A refusal with 412 then stops the collection, and nothing is sent
   * again.
   */
  async #collect(ctx: ExtensionContext, session: ManagerSession, reference: Reference,
    inputs: Readonly<Record<string, string>> | undefined): Promise<boolean> {
    let again: { readonly name: string; readonly source: (typeof SOURCES)[number] } | undefined;
    for (;;) {
      const read = await this.#read(ctx, session, reference);
      if (read === undefined) return false;
      const { observed, request } = read;
      // After a refusal for a changed request, the same input is edited
      // again from its draft, also when the change supplied it.
      const name = again?.name ?? request.readiness.missing[0];
      if (name === undefined) return true;
      const declaration = request.readiness.declarations.find((item) => item.name === name);
      const key = draftKey(session, request.id, name);
      const modelValue = inputs !== undefined && Object.hasOwn(inputs, name) ? inputs[name] : undefined;
      if (inputs !== undefined && modelValue === undefined) return stopped(ctx, `The model gave no value for the input ${name} of request ${request.id}. Nothing more was sent.`, "warning");
      const chosen = modelValue !== undefined ? "Literal text" : again?.name === name ? again.source
        : await ctx.ui.select(`Input ${name} (declared source ${declaration?.source ?? "prompt"})`, [...SOURCES]);
      const source = SOURCES.find((item) => item === chosen);
      if (source === undefined) return false;
      again = undefined;
      let input: JsonValue;
      if (source === "Captured file") {
        const path = await ctx.ui.input(`Local file whose exact bytes supply ${name}`);
        if (!path) return false;
        let bytes: Buffer;
        try {
          bytes = await readFile(path);
        } catch (error) {
          ctx.ui.notify(`The file could not be read: ${error instanceof Error ? error.message : String(error)}`, "error");
          continue;
        }
        const captured = await this.#capture(ctx, session, request.id, bytes);
        if (captured === undefined) return false;
        input = { name, source: "capture", captureId: captured };
      } else {
        const value = modelValue ?? await ctx.ui.editor(`Input ${name}: exact ${source === "Literal text" ? "literal" : "captured"} text`, this.#drafts.get(key));
        if (value === undefined) return false;
        if (modelValue === undefined) this.#drafts.set(key, value);
        if (source === "Literal text") input = { name, source: "literal", value };
        else {
          const captured = await this.#capture(ctx, session, request.id, Buffer.from(value, "utf8"));
          if (captured === undefined) return false;
          input = { name, source: "capture", captureId: captured };
        }
      }
      // The input binds the revision that the user edited. A request that
      // changed in the meantime refuses with 412, and the draft is kept.
      const set = await this.#command(ctx, session, "set-input", reference.uri,
        session.prepare(reference, { operation: "set-input", input }, observed.etag));
      if (set.kind === "refused" && set.failure.kind === "Refused" && set.failure.status === 412) {
        if (modelValue !== undefined) {
          return stopped(ctx, `Request ${request.id} changed before the input ${name} arrived (412). Nothing was sent again. /wfm-review continues the request.`, "warning");
        }
        ctx.ui.notify(`Request ${request.id} changed while the editor was open. The draft of ${name} is kept, and the editor opens again.`, "warning");
        again = { name, source };
        continue;
      }
      if (set.kind !== "receipt" || set.state !== "effect-observed") return false;
      this.#drafts.delete(key);
    }
  }

  /** Capture exact bytes for a request and give the capture identifier. */
  async #capture(ctx: ExtensionContext, session: ManagerSession, requestId: string, bytes: Uint8Array): Promise<string | undefined> {
    const captured = await this.#command(ctx, session, "capture", `/v1/captures?requestId=${requestId}`,
      session.prepareCapture(requestId, bytes));
    return captured.kind === "captured" ? captured.captureId : undefined;
  }

  /** Follow a request until its preparation is live, then show its review. Gives whether the manager started the run. */
  async #awaitReview(ctx: ExtensionContext, session: ManagerSession, reference: Reference): Promise<boolean> {
    let shown = "";
    const waited = await session.waitFor(reference, (observed) => {
      const decoded = decodeDraftView(observed.value);
      if (!decoded.ok) return false;
      const line = admissionLine(decoded.value);
      if (line !== shown) {
        shown = line;
        ctx.ui.notify(line, "info");
      }
      return (decoded.value.phase === "review" && decoded.value.preparationId !== null) || !OPEN_PHASES.includes(decoded.value.phase);
    }, REVIEW_WAIT_MS);
    if (!waited.ok) return stopped(ctx, `The request did not reach review: ${failureText(waited.failure)}. /wfm-review continues it.`, "warning");
    const request = decodeDraftView(waited.value.value);
    if (!request.ok || request.value.phase !== "review" || request.value.preparationId === null) return false;
    const target = session.reference(`/v1/preparations/${request.value.preparationId}`);
    if (!target.ok) return false;
    const live = await session.waitFor(target.value, (observed) => {
      const preparation = decodePreparation(observed.value);
      return preparation.ok;
    }, EFFECT_WAIT_MS);
    if (!live.ok) return stopped(ctx, `The preparation could not be read: ${failureText(live.failure)}`);
    return this.#review(ctx, session, reference, live.value);
  }

  /** Show the review of one read of a live preparation and act on the choice of the user. Gives whether the manager started the run. */
  async #review(ctx: ExtensionContext, session: ManagerSession, requestRef: Reference, observed: Observed): Promise<boolean> {
    const decoded = decodePreparation(observed.value);
    if (!decoded.ok) return stopped(ctx, "The preparation does not decode");
    const preparation = decoded.value;
    if (preparation.state !== "live") return stopped(ctx, `Preparation ${preparation.id} is ${preparation.state} (${preparation.reason ?? "no reason"})`, "warning");
    if (observed.etag === null) return stopped(ctx, "The preparation has no entity tag, so no approval can bind it");
    const etag = observed.etag;
    const lines = reviewLines(preparation, etag);
    let choice: ReviewChoice | undefined;
    if (ctx.mode === "tui") {
      choice = await ctx.ui.custom<ReviewChoice>((tui, theme, _keys, done) => new ReviewComponent(tui, theme, lines, done));
    } else {
      ctx.ui.notify(lines.join("\n"), "info");
      const actions = ["Approve this review", "Decline", "Discard the preparation", "Withdraw the request"];
      const selected = await ctx.ui.select("Review", actions);
      choice = (["approve", "decline", "discard", "withdraw"] as const)[actions.indexOf(selected ?? "Decline")];
    }
    if (choice === "approve") {
      const confirmed = await ctx.ui.confirm("Approve this exact review?",
        `Approve preparation ${preparation.id} of request ${preparation.requestId} with review digest ${preparation.reviewDigest}`
        + ` and If-Match ${etag}. The manager then starts the run.`);
      if (!confirmed) choice = "decline";
    }
    if (choice === "decline" || choice === undefined) {
      return stopped(ctx, `Review declined. No approval was sent. Request ${preparation.requestId} stays in review, and /wfm-review opens it again.`, "info");
    }
    const target = session.reference(`/v1/preparations/${preparation.id}`);
    if (!target.ok) return false;
    if (choice === "discard") {
      await this.#discard(ctx, session, target.value, etag, preparation.requestId);
      return false;
    }
    if (choice === "withdraw") {
      await this.#withdraw(ctx, session, requestRef);
      return false;
    }
    const approved = await this.#command(ctx, session, "approve", target.value.uri, session.prepare(target.value,
      { operation: "approve", ...Object.fromEntries(SELECTORS.map((name) => [name, preparation[name]])) }, etag), false);
    if (approved.kind !== "receipt" || approved.state === "refused") return false;
    const started = await session.waitFor(requestRef, (value) => {
      const request = decodeDraftView(value.value);
      return request.ok && request.value.runId !== null;
    }, START_WAIT_MS);
    const request = started.ok ? decodeDraftView(started.value.value) : undefined;
    if (request === undefined || !request.ok || request.value.runId === null) {
      return stopped(ctx, `Request ${preparation.requestId} names no run yet. /wfm-status shows the service runs.`, "warning");
    }
    ctx.ui.notify(`Execution: the manager started run ${request.value.runId} for request ${request.value.id}.`, "info");
    return true;
  }

  async #discard(ctx: ExtensionContext, session: ManagerSession, target: Reference, etag: string | null, requestId: string): Promise<void> {
    const discarded = await this.#command(ctx, session, "discard", target.uri, session.prepare(target, { operation: "discard" }, etag));
    if (discarded.kind === "receipt" && discarded.state === "effect-observed") {
      ctx.ui.notify(`Request ${requestId} is a draft again. /wfm-review prepares a new review.`, "info");
    }
  }

  async #withdraw(ctx: ExtensionContext, session: ManagerSession, reference: Reference): Promise<void> {
    const read = await this.#read(ctx, session, reference);
    if (read === undefined) return;
    const withdrawn = await this.#command(ctx, session, "withdraw", reference.uri,
      session.prepare(reference, { operation: "withdraw" }, read.observed.etag));
    if (withdrawn.kind === "receipt" && withdrawn.state === "effect-observed") ctx.ui.notify(`Request ${read.request.id} is withdrawn.`, "info");
  }
}

function draftKey(session: ManagerSession, requestId: string, name: string): string {
  return JSON.stringify([session.identity, requestId, name]);
}

function answerKey(session: ManagerSession, decisionId: string): string {
  return JSON.stringify([session.identity, "decision", decisionId]);
}

/** The head decision of a run with the reads that its commands bind. */
type Head = {
  readonly runId: string;
  readonly decision: DecisionView;
  readonly decisionObserved: Observed;
  readonly control: ControlView;
  readonly controlObserved: Observed;
};
