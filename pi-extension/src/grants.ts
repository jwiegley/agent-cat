import { randomUUID } from "node:crypto";

export type GrantScope = "start" | "lineage" | "control" | "all";

export class MutationGrants {
  readonly #grants = new Map<string, { scope: GrantScope; expires: number }>();

  issue(scope: GrantScope, ttlMs = 10 * 60_000): string {
    const id = `grant-${randomUUID()}`;
    this.#grants.set(id, { scope, expires: Date.now() + ttlMs });
    return id;
  }

  consume(id: string | undefined, required: Exclude<GrantScope, "all">): boolean {
    if (!id) return false;
    const grant = this.#grants.get(id);
    this.#grants.delete(id);
    return Boolean(grant && grant.expires >= Date.now() && (grant.scope === required || grant.scope === "all"));
  }
}
