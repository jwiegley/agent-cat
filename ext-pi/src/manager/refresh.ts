/**
 * Pure refresh coordination for one client session: per-resource
 * serialization with dirty coalescing and generation fencing, the bounded
 * reconnection backoff, and the reconciliation rule of an uncertain command.
 * Nothing here performs I/O. The functions return the next state and the
 * actions that the caller performs, and no action is a send.
 *
 * This module states the behavior of `Agentic.Manager.Client.Refresh` in
 * TypeScript. It imports no Haskell code. The `refresh` section of
 * `test/manager_client_vectors.json` is the shared definition that both
 * implementations pass.
 *
 * @packageDocumentation
 */

import type { ClientFailure } from "./events.ts";

/**
 * The generation of a fetch, a non-negative integer. A resnapshot or an
 * endpoint switch advances the current generation, and only a fetch of the
 * current generation installs.
 *
 * @public
 */
export type FetchGeneration = number;

/**
 * The one fetch in flight for a resource: its generation, and whether an
 * invalidation arrived after it started.
 *
 * @public
 */
export type Flight = { readonly generation: FetchGeneration; readonly dirty: boolean };

/**
 * The current generation and the fetch in flight for each resource key. A
 * key without a flight is idle. A state is never changed in place.
 *
 * @typeParam Key - the resource key. Keys are compared with `===`.
 * @public
 */
export type Refresh<Key> = { readonly generation: FetchGeneration; readonly flights: ReadonlyMap<Key, Flight> };

/**
 * Generation zero with every resource idle.
 *
 * @public
 */
export function newRefresh<Key>(): Refresh<Key> {
  return { generation: 0, flights: new Map() };
}

/**
 * What the caller does. `fetch` starts one fetch of the resource for the
 * generation. `install` installs the result of the completed fetch, a value
 * or a refusal. `discard` drops the result of the completed fetch without
 * installing it.
 *
 * @typeParam Key - the resource key.
 * @public
 */
export type RefreshAction<Key> = {
  readonly kind: "fetch" | "install" | "discard";
  readonly key: Key;
  readonly generation: FetchGeneration;
};

/**
 * The next state and the actions of one step, in order.
 *
 * @typeParam Key - the resource key.
 * @public
 */
export type RefreshStep<Key> = { readonly state: Refresh<Key>; readonly actions: readonly RefreshAction<Key>[] };

function withFlight<Key>(state: Refresh<Key>, key: Key, flight: Flight | undefined): Refresh<Key> {
  const flights = new Map(state.flights);
  if (flight === undefined) flights.delete(key);
  else flights.set(key, flight);
  return { generation: state.generation, flights };
}

/**
 * An invalidation of the resource. An idle resource starts a fetch of the
 * current generation. A resource with a fetch in flight only becomes dirty,
 * so any number of invalidations during one fetch give one later fetch.
 *
 * @public
 */
export function invalidateResource<Key>(key: Key, state: Refresh<Key>): RefreshStep<Key> {
  const flight = state.flights.get(key);
  if (flight !== undefined) return { state: withFlight(state, key, { generation: flight.generation, dirty: true }), actions: [] };
  return {
    state: withFlight(state, key, { generation: state.generation, dirty: false }),
    actions: [{ kind: "fetch", key, generation: state.generation }],
  };
}

/**
 * The completion of a fetch of the resource for the generation. Only the
 * fetch in flight of the current generation installs. When that resource is
 * dirty, exactly one further fetch starts, and otherwise the resource
 * becomes idle. Every other completion, in particular one of an earlier
 * generation, is discarded and changes nothing.
 *
 * @public
 */
export function completeFetch<Key>(key: Key, generation: FetchGeneration, state: Refresh<Key>): RefreshStep<Key> {
  const current = state.generation;
  const flight = state.flights.get(key);
  if (flight === undefined || generation !== current || flight.generation !== current) {
    return { state, actions: [{ kind: "discard", key, generation }] };
  }
  const install: RefreshAction<Key> = { kind: "install", key, generation };
  return flight.dirty
    ? { state: withFlight(state, key, { generation: current, dirty: false }), actions: [install, { kind: "fetch", key, generation: current }] }
    : { state: withFlight(state, key, undefined), actions: [install] };
}

/**
 * A resnapshot, after a 410 refusal or a new overview, or an endpoint
 * switch. The generation advances and every resource becomes idle, so each
 * fetch still in flight is discarded when it completes.
 *
 * @public
 */
export function advanceGeneration<Key>(state: Refresh<Key>): Refresh<Key> {
  return { generation: state.generation + 1, flights: new Map() };
}

/**
 * The `reconnectBackoffMaxSeconds` limit of `/capabilities`.
 *
 * @public
 */
export const RECONNECT_BACKOFF_MAX_SECONDS = 30;

/**
 * The delay in seconds before the next reconnection.
 *
 * @public
 */
export type Backoff = { readonly seconds: number };

/**
 * One second. A connection that delivered an event resets to it.
 *
 * @public
 */
export const INITIAL_BACKOFF: Backoff = { seconds: 1 };

/**
 * The delay in seconds before a reconnection, and the backoff after it. The
 * delay doubles from one second up to `RECONNECT_BACKOFF_MAX_SECONDS` and
 * then stays there.
 *
 * @public
 */
export function reconnectDelay(backoff: Backoff): { readonly delay: number; readonly next: Backoff } {
  return { delay: backoff.seconds, next: { seconds: Math.min(RECONNECT_BACKOFF_MAX_SECONDS, 2 * backoff.seconds) } };
}

/**
 * The jittered wait in microseconds for a delay in seconds and a fraction
 * from zero to one. The wait is between half the delay and the whole delay,
 * so it never passes `RECONNECT_BACKOFF_MAX_SECONDS`. A fraction outside
 * that range is clamped, and a fraction that is not a number counts as zero,
 * as in the Haskell client.
 *
 * @public
 */
export function jitteredMicroseconds(seconds: number, fraction: number): number {
  const clamped = fraction >= 1 ? 1 : fraction > 0 ? fraction : 0;
  return Math.floor(seconds * 1000000 * (0.5 + 0.5 * clamped));
}

/**
 * The state of a command receipt, as `Agentic.Manager.Protocol.Command`
 * names it.
 *
 * @public
 */
export const COMMAND_STATES = ["accepted", "dispatch-attempted", "acknowledged", "effect-observed", "refused", "unresolved"] as const;

/** @public */
export type CommandState = (typeof COMMAND_STATES)[number];

/**
 * The command state that the text names, or `undefined` for any other text.
 *
 * @public
 */
export function parseCommandState(text: string): CommandState | undefined {
  return COMMAND_STATES.find((state) => state === text);
}

/**
 * A sent command whose outcome is uncertain. It keeps its exact pending
 * command, with its bytes, key and precondition, the target resource, the
 * precondition entity tag, and the receipt location when an earlier
 * response gave one.
 *
 * @typeParam Command - the pending command with its exact bytes, key and precondition.
 * @typeParam Location - a resource location.
 * @public
 */
export type Uncertain<Command, Location> = {
  readonly command: Command;
  readonly target: Location;
  readonly precondition: string | null;
  readonly receipt: Location | null;
};

/**
 * The one read of a reconciliation.
 *
 * @typeParam Location - a resource location.
 * @public
 */
export type ReconcileRead<Location> = { readonly kind: "receipt" | "target"; readonly location: Location };

/**
 * The receipt location when one is known, or else the target resource.
 *
 * @public
 */
export function reconcileRead<Command, Location>(uncertain: Uncertain<Command, Location>): ReconcileRead<Location> {
  return uncertain.receipt === null
    ? { kind: "target", location: uncertain.target }
    : { kind: "receipt", location: uncertain.receipt };
}

/**
 * The result of the reconciliation read. `receipt` is the state of the
 * receipt that the receipt location gives. `target` is the entity tag of the
 * target resource and whether the caller sees the effect of the command in
 * it. `failure` is a refused or failed read.
 *
 * @public
 */
export type ReconcileObservation =
  | { readonly kind: "receipt"; readonly state: CommandState }
  | { readonly kind: "target"; readonly etag: string; readonly effectVisible: boolean }
  | { readonly kind: "failure"; readonly failure: ClientFailure };

/**
 * The report of a reconciliation. A command that stays uncertain is returned
 * unchanged, so its exact bytes, key and precondition remain for an explicit
 * exact resend. No report carries a send.
 *
 * @typeParam Command - the pending command.
 * @typeParam Location - a resource location.
 * @public
 */
export type Reconciled<Command, Location> =
  | { readonly kind: "effect-observed" }
  | { readonly kind: "refused" }
  | { readonly kind: "uncertain"; readonly uncertain: Uncertain<Command, Location> };

/**
 * Reconcile an uncertain command with the result of `reconcileRead`. With a
 * receipt location, only the receipt decides: `effect-observed` observes the
 * effect, `refused` reports the refusal, and every other state stays
 * uncertain. Without one, the target observes the effect only when the
 * caller sees the effect and the entity tag differs from the precondition.
 * A failed read and an observation of the other read stay uncertain.
 *
 * @public
 */
export function reconcile<Command, Location>(
  uncertain: Uncertain<Command, Location>,
  observation: ReconcileObservation,
): Reconciled<Command, Location> {
  if (uncertain.receipt !== null && observation.kind === "receipt") {
    if (observation.state === "effect-observed") return { kind: "effect-observed" };
    if (observation.state === "refused") return { kind: "refused" };
  }
  if (uncertain.receipt === null && observation.kind === "target" && observation.effectVisible
    && observation.etag !== uncertain.precondition) {
    return { kind: "effect-observed" };
  }
  return { kind: "uncertain", uncertain };
}
