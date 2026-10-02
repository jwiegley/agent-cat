/**
 * The stream test hooks of service mode. They are registered only when
 * `testHooksEnabled` holds, which the Pi host harness arranges.
 * `/wfm-debug-reconnect` closes the open event stream of the active session
 * through `ManagerSession.forceReconnect`, as a lost connection does, and
 * `/wfm-debug-events` lists the stream connections and the delivered events
 * after that drop. The harness compares the list with the events that it
 * reads from the manager. The hooks send no manager command.
 *
 * @packageDocumentation
 */

import type { InvalidationEvent } from "./manager/events.ts";
import type { SessionOptions } from "./manager/session.ts";
import type { Delivery } from "./manager/transport.ts";

/**
 * The record of the event connections and the delivered events of the
 * sessions of one extension instance.
 *
 * @public
 */
export class StreamLog {
  readonly #connections: Array<{ readonly via: Delivery; readonly cursor: string }> = [];
  readonly #events: string[] = [];
  #drop: { readonly at: string; readonly connections: number; readonly events: number } | undefined;

  /** The session options that record each connection and each delivered event, and then call the hooks of `base`. */
  options(base: SessionOptions = {}): SessionOptions {
    return {
      ...base,
      onConnect: (via, cursor) => {
        this.#connections.push({ via, cursor });
        base.onConnect?.(via, cursor);
      },
      onEvent: (event: InvalidationEvent, via) => {
        this.#events.push(event.id);
        base.onEvent?.(event, via);
      },
    };
  }

  /**
   * Mark a drop of the event stream, and give the last delivered event
   * identifier, or the cursor of the last connection when no event was
   * delivered. The follow loop reconnects from that position.
   */
  drop(): string {
    const at = this.#events.at(-1) ?? this.#connections.at(-1)?.cursor ?? "none";
    this.#drop = { at, connections: this.#connections.length, events: this.#events.length };
    return at;
  }

  /** The lines of `/wfm-debug-events`: the drop position, the connections after it, and the events delivered after it in order. */
  lines(): string[] {
    const drop = this.#drop;
    if (drop === undefined) return ["Test hook: no event stream drop is recorded"];
    const connections = this.#connections.slice(drop.connections).map((connection) => `${connection.via} ${connection.cursor}`);
    return [
      `Test hook: event stream dropped after event ${drop.at}`,
      `Connections after the drop: ${connections.join(", ") || "none"}`,
      `Events delivered after the drop: ${eventList(this.#events.slice(drop.events))}`,
    ];
  }
}

/**
 * The text of a list of event identifiers. Identifiers of one stream are
 * listed once with the stream and then by sequence number, so that a long
 * list stays short on the screen.
 */
function eventList(events: readonly string[]): string {
  if (events.length === 0) return "0";
  const stream = events[0].slice(0, events[0].lastIndexOf("."));
  if (events.every((id) => id.lastIndexOf(".") === stream.length && id.startsWith(`${stream}.`))) {
    return `${events.length} of stream ${stream}: ${events.map((id) => id.slice(stream.length + 1)).join(" ")}`;
  }
  return `${events.length}: ${events.join(" ")}`;
}
