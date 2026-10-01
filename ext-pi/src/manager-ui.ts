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
 * Every command goes through the `ManagerSession` of the active service
 * binding, and each send is recorded as a `CommandRecord`. A record states
 * only the outcome of the command (accepted, refused or uncertain) and the
 * state of its receipt. The phase of a request and the status of a run are
 * execution facts, and the commands report them separately. No command is
 * sent again by itself.
 *
 * @packageDocumentation
 */

import { readFile } from "node:fs/promises";
import type { ExtensionContext, Theme } from "@earendil-works/pi-coding-agent";
import { matchesKey, truncateToWidth, wrapTextWithAnsi, type Component, type TUI } from "@earendil-works/pi-tui";
import type { ClientFailure, Outcome } from "./manager/events.ts";
import { encodeJson, isJsonArray, isJsonObject, jsonMember, type JsonObject, type JsonValue } from "./manager/json.ts";
import {
  decodeCommandReceipt,
  decodeDraftView,
  decodeInputDeclaration,
  decodePreparation,
  requiredScopes,
  type DraftView,
  type InputDeclaration,
  type Operation,
  type Preparation,
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
   */
  async #command(ctx: ExtensionContext, session: ManagerSession, operation: Operation, target: string,
    prepared: Outcome<PendingCommand>, settle = true): Promise<
    | { kind: "receipt"; state: string }
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
      this.#record(ctx, session, operation, target, "uncertain",
        `${failureText(sent.failure)}. The command is not sent again. /wfm-status shows the manager state.`);
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
      return decoded.ok && SETTLED.includes(decoded.value.state);
    }, EFFECT_WAIT_MS);
    const final = settled.ok ? decodeCommandReceipt(settled.value.value) : undefined;
    const state = final !== undefined && final.ok ? final.value.state : receipt.state;
    const effect = final !== undefined && final.ok ? final.value.effect : null;
    const refusal = final !== undefined && final.ok && final.value.refusal !== null ? `, refusal ${final.value.refusal}` : "";
    const kind = effect !== null && isJsonObject(effect) ? text(jsonMember(effect, "kind")) : undefined;
    this.#record(ctx, session, operation, target, "accepted",
      `command ${receipt.id}, receipt ${state}${kind === undefined ? "" : ` (${kind})`}${refusal}`);
    return { kind: "receipt", state };
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

  /**
   * `/wfm [WORKFLOW]`: select a profile and a workflow, create a request,
   * collect its inputs, enqueue it, follow its admission, and open its
   * review.
   */
  async start(ctx: ExtensionContext, args: string): Promise<void> {
    const session = this.#session(ctx);
    if (session === undefined) return;
    if (!ctx.hasUI) return ctx.ui.notify("/wfm requires the interactive Pi interface", "error");
    const profiles = await this.#collection(session, "/v1/profiles");
    if (!profiles.ok) return ctx.ui.notify(`The manager profiles could not be read: ${failureText(profiles.failure)}`, "error");
    const rows = profiles.value.map(profileRow).filter((row): row is ProfileRow => row !== undefined && row.ready);
    if (rows.length === 0) return ctx.ui.notify("The manager offers no ready profile to this credential", "error");
    let profile = rows[0];
    if (rows.length > 1) {
      const labels = rows.map((row) => `${row.id}  ${row.workspace}  ${row.target}`);
      const chosen = await ctx.ui.select("Manager profile", labels);
      if (chosen === undefined) return;
      profile = rows[labels.indexOf(chosen)];
    }
    const catalogue = await this.#collection(session, `/v1/workflows?profileId=${profile.id}`);
    if (!catalogue.ok) return ctx.ui.notify(`The catalogue of ${profile.id} could not be read: ${failureText(catalogue.failure)}`, "error");
    const workflows = catalogue.value.map(workflowRow).filter((row): row is WorkflowRow => row !== undefined && row.profileId === profile.id);
    const name = args.trim();
    let workflow: WorkflowRow | undefined;
    if (name) {
      workflow = workflows.find((row) => row.name === name);
      if (workflow === undefined) return ctx.ui.notify(`The catalogue of ${profile.id} has no workflow ${name}`, "error");
    } else {
      const labels = workflows.map((row) => (row.blurb ? `${row.name}  ${row.blurb}` : row.name));
      const chosen = await ctx.ui.select(`Workflow of ${profile.id}`, labels);
      if (chosen === undefined) return;
      workflow = workflows[labels.indexOf(chosen)];
    }
    const requests = session.reference("/v1/requests");
    if (!requests.ok) return;
    const created = await this.#command(ctx, session, "create", requests.value.uri, session.prepare(requests.value, {
      workflowId: workflow.id, descriptorRevision: workflow.revision, profileId: workflow.profileId, profileRevision: workflow.profileRevision,
    }, null));
    if (created.kind !== "created") return;
    ctx.ui.notify(admissionLine(created.request), "info");
    await this.#continue(ctx, session, created.location);
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
    if (reference !== undefined) await this.#continue(ctx, session, reference);
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

  /** Continue a request from its current phase until its review is answered or the user stops. */
  async #continue(ctx: ExtensionContext, session: ManagerSession, reference: Reference): Promise<void> {
    const read = await this.#read(ctx, session, reference);
    if (read === undefined) return;
    let { request } = read;
    if (request.phase === "draft") {
      if (!(await this.#collect(ctx, session, reference))) return;
      const supplied = await this.#read(ctx, session, reference);
      if (supplied === undefined) return;
      if (supplied.request.readiness.missing.length > 0 || supplied.request.readiness.errors.length > 0) {
        return ctx.ui.notify(admissionLine(supplied.request), "warning");
      }
      const enqueued = await this.#command(ctx, session, "enqueue", reference.uri,
        session.prepare(reference, { operation: "enqueue" }, supplied.observed.etag));
      if (enqueued.kind !== "receipt" || enqueued.state !== "effect-observed") return;
      request = supplied.request;
    }
    if (!OPEN_PHASES.includes(request.phase)) return ctx.ui.notify(admissionLine(request), "info");
    await this.#awaitReview(ctx, session, reference);
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
   */
  async #collect(ctx: ExtensionContext, session: ManagerSession, reference: Reference): Promise<boolean> {
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
      const chosen = again?.name === name ? again.source
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
        const value = await ctx.ui.editor(`Input ${name}: exact ${source === "Literal text" ? "literal" : "captured"} text`, this.#drafts.get(key));
        if (value === undefined) return false;
        this.#drafts.set(key, value);
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

  /** Follow a request until its preparation is live, then show its review. */
  async #awaitReview(ctx: ExtensionContext, session: ManagerSession, reference: Reference): Promise<void> {
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
    if (!waited.ok) return ctx.ui.notify(`The request did not reach review: ${failureText(waited.failure)}. /wfm-review continues it.`, "warning");
    const request = decodeDraftView(waited.value.value);
    if (!request.ok || request.value.phase !== "review" || request.value.preparationId === null) return;
    const target = session.reference(`/v1/preparations/${request.value.preparationId}`);
    if (!target.ok) return;
    const live = await session.waitFor(target.value, (observed) => {
      const preparation = decodePreparation(observed.value);
      return preparation.ok;
    }, EFFECT_WAIT_MS);
    if (!live.ok) return ctx.ui.notify(`The preparation could not be read: ${failureText(live.failure)}`, "error");
    await this.#review(ctx, session, reference, live.value);
  }

  /** Show the review of one read of a live preparation and act on the choice of the user. */
  async #review(ctx: ExtensionContext, session: ManagerSession, requestRef: Reference, observed: Observed): Promise<void> {
    const decoded = decodePreparation(observed.value);
    if (!decoded.ok) return ctx.ui.notify("The preparation does not decode", "error");
    const preparation = decoded.value;
    if (preparation.state !== "live") return ctx.ui.notify(`Preparation ${preparation.id} is ${preparation.state} (${preparation.reason ?? "no reason"})`, "warning");
    if (observed.etag === null) return ctx.ui.notify("The preparation has no entity tag, so no approval can bind it", "error");
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
      return ctx.ui.notify(`Review declined. No approval was sent. Request ${preparation.requestId} stays in review, and /wfm-review opens it again.`, "info");
    }
    const target = session.reference(`/v1/preparations/${preparation.id}`);
    if (!target.ok) return;
    if (choice === "discard") return this.#discard(ctx, session, target.value, etag, preparation.requestId);
    if (choice === "withdraw") return this.#withdraw(ctx, session, requestRef);
    const approved = await this.#command(ctx, session, "approve", target.value.uri, session.prepare(target.value,
      { operation: "approve", ...Object.fromEntries(SELECTORS.map((name) => [name, preparation[name]])) }, etag), false);
    if (approved.kind !== "receipt" || approved.state === "refused") return;
    const started = await session.waitFor(requestRef, (value) => {
      const request = decodeDraftView(value.value);
      return request.ok && request.value.runId !== null;
    }, START_WAIT_MS);
    const request = started.ok ? decodeDraftView(started.value.value) : undefined;
    if (request === undefined || !request.ok || request.value.runId === null) {
      return ctx.ui.notify(`Request ${preparation.requestId} names no run yet. /wfm-status shows the service runs.`, "warning");
    }
    ctx.ui.notify(`Execution: the manager started run ${request.value.runId} for request ${request.value.id}.`, "info");
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
