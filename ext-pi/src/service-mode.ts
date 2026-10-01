/**
 * The service mode of the extension: one manager session for the active
 * client profile, and the service observations that its overview gives.
 *
 * Service mode starts when `configuredManagerProfiles` names client
 * profiles. It connects to the first profile, reads the overview and follows
 * the event stream of the manager. It holds the runs, requests and decision
 * heads of the overview as service observations, each keyed by the endpoint
 * identity of the binding and its identifier. A service observation is not
 * an `OwnedRun` or a `RestoredRun`. It has no local reducer, no file-system
 * monitor, no local process and no local run store, and it grants no
 * supervision or control authority.
 *
 * Service mode sends no manager command. `close` closes the transport, and
 * the work of the manager continues under its own supervision. A switch
 * between profiles uses `ManagerSession.switchEndpoint`, which advances the
 * refresh generation, discards every read of the earlier binding that is in
 * flight, and refuses every reference of the earlier binding with
 * `WrongEndpoint`.
 *
 * @packageDocumentation
 */

import type { ClientFailure } from "./manager/events.ts";
import { isJsonArray, jsonMember } from "./manager/json.ts";
import { ClientProfile } from "./manager/profile.ts";
import type { DecisionState, RequestPhase, RunStatus, SupervisionState } from "./manager/resources.ts";
import { ManagerSession, type DeliveryState, type Reference, type SessionOptions } from "./manager/session.ts";

/**
 * One run of the manager overview, as a service observation.
 *
 * `status` is the runtime status, `pending` for a run without a runtime
 * record, or `unreadable` for a run whose manifest the manager could not
 * read.
 *
 * @public
 */
export type ServiceRunView = {
  readonly endpoint: string;
  readonly runId: string;
  readonly reference: Reference;
  readonly workflowId: string | null;
  readonly status: RunStatus | "pending" | "unreadable";
  readonly supervision: SupervisionState | null;
};

/**
 * One request of the manager overview, as a service observation.
 *
 * @public
 */
export type ServiceRequestView = {
  readonly endpoint: string;
  readonly requestId: string;
  readonly reference: Reference;
  readonly workflowId: string;
  readonly phase: RequestPhase;
  readonly runId: string | null;
};

/**
 * One decision head of the manager overview, as a service observation. A
 * decision head is the decision at position 0 of the queue of its run.
 *
 * @public
 */
export type ServiceDecisionView = {
  readonly endpoint: string;
  readonly decisionId: string;
  readonly reference: Reference;
  readonly runId: string;
  readonly state: DecisionState;
  readonly kind: "question" | "recovery";
};

/**
 * The connection of service mode. `refused` follows an unsupported profile,
 * a capability version that the client does not support, or a refused
 * credential. `unreachable` follows a manager that does not answer. Neither
 * state sends a command, and a new selection of a profile connects again.
 *
 * @public
 */
export type ServiceConnection =
  | { readonly kind: "connecting"; readonly profile: string }
  | {
    readonly kind: "connected";
    readonly profile: string;
    readonly endpoint: string;
    readonly identity: string;
    readonly delivery: DeliveryState;
    readonly overview: "loaded" | "unavailable";
  }
  | { readonly kind: "refused"; readonly profile: string; readonly reason: string }
  | { readonly kind: "unreachable"; readonly profile: string; readonly reason: string }
  | { readonly kind: "closed" };

/**
 * The result of one profile selection. `kept` is a switch that the new
 * profile refused, after which the earlier binding stays active.
 *
 * @public
 */
export type ServiceSelection =
  | { readonly kind: "connected"; readonly connection: ServiceConnection }
  | { readonly kind: "failed"; readonly connection: ServiceConnection }
  | { readonly kind: "kept"; readonly profile: string; readonly reason: string; readonly connection: ServiceConnection }
  | { readonly kind: "closed" };

/**
 * Options of service mode. `session` holds the session options of every
 * connection. `onChange` is called after each change of the connection or
 * of the observations, until `close`.
 *
 * @public
 */
export type ServiceModeOptions = {
  readonly session?: SessionOptions;
  readonly onChange?: () => void;
};

/** The refusal state and reason of a failure to connect. */
export function connectionProblem(failure: ClientFailure): { kind: "refused" | "unreachable"; reason: string } {
  switch (failure.kind) {
    case "InvalidClientProfile":
    case "InvalidEndpoint":
    case "ClientFileUnavailable":
    case "CredentialUnavailable":
      return { kind: "refused", reason: `unsupported profile (${failure.kind})` };
    case "UnsupportedVersion":
      return { kind: "refused", reason: "the manager offers no capability version that this client supports" };
    case "CredentialChanged":
      return { kind: "refused", reason: "the credential file changed after the profile was loaded" };
    case "Refused":
      if (failure.status === 401 || failure.status === 403) {
        return { kind: "refused", reason: `the manager refused the credential (${failure.status} ${failure.code})` };
      }
      if (failure.status >= 500) return { kind: "unreachable", reason: `the manager is unavailable (${failure.status} ${failure.code})` };
      return { kind: "refused", reason: `the manager refused the connection (${failure.status} ${failure.code})` };
    case "TransportUnavailable":
      return { kind: "unreachable", reason: "the manager does not answer" };
    default:
      return { kind: "refused", reason: `the connection failed (${failure.kind})` };
  }
}

/** The text of the capabilities that the manager grants this client: its scopes, profiles and transports. */
function capabilityText(session: ManagerSession): string {
  const list = (name: string): string => {
    const value = jsonMember(session.capabilities, name);
    return value !== undefined && isJsonArray(value) ? value.filter((item) => typeof item === "string").join(", ") || "none" : "none";
  };
  return `scopes ${list("scopes")}; profiles ${list("profileIds")}; transports ${list("transports")}`;
}

/**
 * Service mode over the configured client profiles.
 *
 * @public
 */
export class ServiceMode {
  /** The configured profile paths, in order. */
  readonly profiles: readonly string[];
  readonly #options: ServiceModeOptions;
  #active = 0;
  #session: ManagerSession | undefined;
  #connection: ServiceConnection;
  #runs = new Map<string, ServiceRunView>();
  #requests = new Map<string, ServiceRequestView>();
  #decisions = new Map<string, ServiceDecisionView>();
  /** The selection lane: one selection at a time, in order. */
  #lane: Promise<unknown> = Promise.resolve();
  #closed = false;

  constructor(profiles: readonly string[], options: ServiceModeOptions = {}) {
    if (profiles.length === 0) throw new Error("service mode requires at least one client profile");
    this.profiles = profiles;
    this.#options = options;
    this.#connection = { kind: "connecting", profile: profiles[0] };
  }

  /** The index of the active profile. */
  get active(): number {
    return this.#active;
  }

  /** The current connection. */
  get connection(): ServiceConnection {
    return this.#connection;
  }

  /** The session of the active binding, while one is connected. */
  get session(): ManagerSession | undefined {
    return this.#session;
  }

  /** The capabilities that the manager grants the active binding, as text, or `undefined`. */
  get capabilities(): string | undefined {
    return this.#session === undefined ? undefined : capabilityText(this.#session);
  }

  /** The service runs of the active binding, in overview order. */
  runs(): ServiceRunView[] {
    return [...this.#runs.values()];
  }

  /** The service requests of the active binding, in overview order. */
  requests(): ServiceRequestView[] {
    return [...this.#requests.values()];
  }

  /** The decision heads of the active binding, in overview order. */
  decisions(): ServiceDecisionView[] {
    return [...this.#decisions.values()];
  }

  /** Connect to the first profile. */
  start(): Promise<ServiceSelection> {
    return this.select(0);
  }

  /**
   * Select the profile at an index. Selections run one at a time. With a
   * following session, the session switches to the new endpoint, and a
   * refused switch keeps the earlier binding. Otherwise a new session
   * connects, and the earlier session closes.
   */
  select(index: number): Promise<ServiceSelection> {
    if (!Number.isInteger(index) || index < 0 || index >= this.profiles.length) {
      return Promise.reject(new RangeError(`profile index ${index} is outside 0 to ${this.profiles.length - 1}`));
    }
    const selection = this.#lane.then(() => this.#select(index));
    this.#lane = selection;
    return selection;
  }

  async #select(index: number): Promise<ServiceSelection> {
    if (this.#closed) return { kind: "closed" };
    const path = this.profiles[index];
    const current = this.#session;
    const switching = current !== undefined && current.followEnd === undefined;
    if (!switching) {
      this.#session = undefined;
      if (current !== undefined) await current.close();
      this.#active = index;
      this.#connection = { kind: "connecting", profile: path };
      this.#clear();
      this.#changed();
    }
    const loaded = await ClientProfile.load(path);
    if (this.#closed) return { kind: "closed" };
    if (!loaded.ok) return this.#failed(index, loaded.failure, switching);
    if (switching) {
      const before = current.identity;
      const switched = await current.switchEndpoint(loaded.value);
      if (this.#closed) return { kind: "closed" };
      if (!switched.ok && current.identity === before) return this.#failed(index, switched.failure, true);
      this.#active = index;
      this.#install();
      return { kind: "connected", connection: this.#connection };
    }
    const connected = await ManagerSession.connect(loaded.value, { ...this.#options.session, onChange: () => this.#install() });
    if (this.#closed) {
      if (connected.ok) await connected.value.close();
      return { kind: "closed" };
    }
    if (!connected.ok) return this.#failed(index, connected.failure, false);
    const session = connected.value;
    this.#session = session;
    const overview = await session.start();
    if (this.#closed) return { kind: "closed" };
    if (!overview.ok) {
      this.#session = undefined;
      await session.close();
      return this.#failed(index, overview.failure, false);
    }
    this.#install();
    return { kind: "connected", connection: this.#connection };
  }

  #failed(index: number, failure: ClientFailure, kept: boolean): ServiceSelection {
    const problem = connectionProblem(failure);
    if (kept) {
      this.#install();
      return { kind: "kept", profile: this.profiles[index], reason: problem.reason, connection: this.#connection };
    }
    this.#active = index;
    this.#connection = { kind: problem.kind, profile: this.profiles[index], reason: problem.reason };
    this.#clear();
    this.#changed();
    return { kind: "failed", connection: this.#connection };
  }

  /**
   * Install the connection and the observations from the session. Only the
   * overview of the current binding is installed, and the session installs
   * an overview only when its refresh generation is current.
   */
  #install(): void {
    const session = this.#session;
    if (this.#closed || session === undefined) return;
    const end = session.followEnd;
    if (end !== undefined && end.kind !== "closed") {
      const problem = end.kind === "refused" ? connectionProblem(end.failure)
        : { kind: "unreachable" as const, reason: "the manager refused the event cursor, and a new overview failed" };
      this.#connection = { kind: problem.kind, profile: this.profiles[this.#active], reason: problem.reason };
      this.#clear();
      this.#changed();
      return;
    }
    const overview = session.overview;
    this.#connection = {
      kind: "connected",
      profile: this.profiles[this.#active],
      endpoint: session.endpoint,
      identity: session.identity,
      delivery: session.deliveryState,
      overview: overview !== undefined && overview.ok ? "loaded" : "unavailable",
    };
    this.#clear();
    if (overview !== undefined && overview.ok) {
      for (const { member, reference } of overview.value.items) {
        if (reference.endpoint !== session.identity) continue;
        const key = `${reference.endpoint} ${reference.uri}`;
        if (member.kind === "run") {
          const { run } = member;
          this.#runs.set(key, {
            endpoint: reference.endpoint,
            runId: run.id,
            reference,
            workflowId: run.content.kind === "known" ? run.content.workflowId : null,
            status: run.content.kind === "unreadable" ? "unreadable" : run.content.runtime?.status ?? "pending",
            supervision: run.content.kind === "known" ? run.content.supervision : null,
          });
        } else if (member.kind === "request") {
          const { request } = member;
          this.#requests.set(key, {
            endpoint: reference.endpoint, requestId: request.id, reference, workflowId: request.workflowId, phase: request.phase, runId: request.runId,
          });
        } else if (member.kind === "decision" && member.decision.position === 0) {
          const { decision } = member;
          this.#decisions.set(key, {
            endpoint: reference.endpoint, decisionId: decision.id, reference, runId: decision.runId, state: decision.state, kind: decision.content.kind,
          });
        }
      }
    }
    this.#changed();
  }

  #clear(): void {
    this.#runs = new Map();
    this.#requests = new Map();
    this.#decisions = new Map();
  }

  #changed(): void {
    if (!this.#closed) this.#options.onChange?.();
  }

  /**
   * Close service mode. The session closes its transport and its event
   * stream. No command is sent, and the manager keeps every run under its
   * own supervision. A connection that completes after `close` is closed at
   * once.
   */
  async close(): Promise<void> {
    if (this.#closed) return;
    this.#closed = true;
    this.#connection = { kind: "closed" };
    this.#clear();
    const session = this.#session;
    this.#session = undefined;
    if (session !== undefined) await session.close();
  }
}
