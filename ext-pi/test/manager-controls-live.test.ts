/**
 * The live check of the run controls `/wfm-steer` and `/wfm-redirect` of
 * service mode against a running protected manager. It runs only when
 * `AGENT_CAT_MANAGER_PROFILE` names a client profile and
 * `AGENT_CAT_MANAGER_STEER_RUN` and `AGENT_CAT_MANAGER_REDIRECT_RUN` name
 * two runs, as the `pi-client-controls` mode of
 * `manager/test/service_http.py` sets them. The harness creates and
 * approves both runs with its own credential before the check starts: the
 * steer run is a run of the steerable ACP fixture that holds its first turn
 * until a steer, and the redirect run is a run whose first model candidate
 * holds its turn and whose spare candidate is the stub fixture. When
 * `AGENT_CAT_MANAGER_REPORT` names a file, the last step writes the
 * identifiers of the check there, and the harness checks each of them
 * against manager facts that it reads with its own credential.
 *
 * The extension runs in service mode with the fake Pi host of
 * `test/fixtures/live-pi.ts`. The steps share one extension:
 *
 * 1. While the steer run holds its first turn, `/wfm-steer` reads the
 *    controls of the run, takes the one steer offer, sends the editor text
 *    with the timing `interrupt-now`, and reports that the steer reached the
 *    attempt.
 * 2. When the dispatch window of the redirect run has closed and its first
 *    candidate holds its turn, the controls offer the live redirect to the
 *    spare target only. `/wfm-redirect` lists exactly that target with the
 *    attempt in flight, sends the redirect, and reports the redirect from
 *    the attempt to the spare target.
 * 3. The extension closes. The one steer and the one redirect are the only
 *    POSTs of the extension.
 */

import { writeFileSync } from "node:fs";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { redirectOffers, redirectPlace, steerOffers } from "../src/manager-ui.ts";
import type { Outcome } from "../src/manager/events.ts";
import { isJsonObject, jsonMember, type JsonObject } from "../src/manager/json.ts";
import { ClientProfile } from "../src/manager/profile.ts";
import { decodeCommandReceipt, decodeControl, type ControlOffer, type ControlView } from "../src/manager/resources.ts";
import { ManagerSession, type Reference } from "../src/manager/session.ts";
import { LivePi, type Post } from "./fixtures/live-pi.ts";

const PROFILE = process.env.AGENT_CAT_MANAGER_PROFILE;
const REPORT = process.env.AGENT_CAT_MANAGER_REPORT;
const STEER_RUN = process.env.AGENT_CAT_MANAGER_STEER_RUN;
const REDIRECT_RUN = process.env.AGENT_CAT_MANAGER_REDIRECT_RUN;

/** The steering text. `PI_CONTROLS_STEER_TEXT` of the harness states it. */
const STEER_TEXT = "Pi steer λ: focus on the patch.";

const STEP_MS = 600_000;
const WAIT_MS = 120_000;

function must<Value>(outcome: Outcome<Value>, step: string): Value {
  if (!outcome.ok) throw new Error(`${step}: ${JSON.stringify(outcome.failure)}`);
  return outcome.value;
}

describe.runIf(PROFILE && STEER_RUN && REDIRECT_RUN)("the run controls of service mode against a live manager", () => {
  let session: ManagerSession;
  const pi = new LivePi();
  const { notices } = pi;
  const report: Record<string, unknown> = {};
  const ref = (uri: string): Reference => must(session.reference(uri), `reference ${uri}`);

  /** Read the controls of a run every 250 milliseconds until the predicate holds. */
  async function controlsUntil(runId: string, ready: (control: ControlView) => boolean, step: string): Promise<ControlView> {
    const deadline = Date.now() + WAIT_MS;
    for (;;) {
      const control = must(decodeControl(must(await session.get(ref(`/v1/runs/${runId}/control`)), "control").value), "control decode");
      if (ready(control)) return control;
      if (Date.now() > deadline) throw new Error(`${step}: ${JSON.stringify(control.value)}`);
      await new Promise((wake) => setTimeout(wake, 250));
    }
  }

  /** The command identifier of the latest accepted command of an operation, from its notification. */
  function acceptedCommand(operation: string): string {
    const notice = [...notices].reverse().find((line) => line.startsWith(`Command ${operation} accepted: command `));
    const id = notice?.slice(`Command ${operation} accepted: command `.length).split(",")[0];
    if (id === undefined) throw new Error(`no accepted ${operation}: ${notices.join("\n")}`);
    return `/v1/commands/${id}`;
  }

  /** The settled receipt of a command and its effect kind. */
  async function effectOf(command: string): Promise<string | undefined> {
    const receipt = must(decodeCommandReceipt(must(await session.get(ref(command)), "receipt").value), "receipt decode");
    expect(receipt.state).toBe("effect-observed");
    return receipt.effect !== null && isJsonObject(receipt.effect) ? String(jsonMember(receipt.effect, "kind")) : undefined;
  }

  /** The one POST to the controls of a run after an index of `posts`, decoded. */
  function onePost(runId: string, from: number): { post: Post; body: unknown } {
    const sent = pi.postsTo(`/v1/runs/${runId}/control`, from);
    expect(sent).toHaveLength(1);
    expect(sent[0].ifMatch).toMatch(/^"/);
    return { post: sent[0], body: JSON.parse(String(sent[0].body)) };
  }

  beforeAll(async () => {
    session = must(await ManagerSession.connect(must(await ClientProfile.load(PROFILE ?? ""), "profile")), "connect");
    await pi.open("agent-cat-pi-controls-state-", WAIT_MS);
  }, STEP_MS);

  afterAll(async () => {
    await session?.close();
    pi.restore();
  });

  it("steers the held attempt of a run with the editor text through the offered steer", async () => {
    const runId = STEER_RUN ?? "";
    const control = await controlsUntil(runId, (value) => steerOffers(value).length === 1, "steer offer");
    const offer: ControlOffer = steerOffers(control)[0];
    expect(offer.timings).toContain("interrupt-now");
    const chosen = `occurrence ${offer.occurrenceId} attempt ${offer.attemptId}`;
    const editors: string[] = [];
    const selects: string[] = [];
    pi.script = {
      editor: (title) => (editors.push(title), STEER_TEXT),
      select: (title, options) => {
        selects.push(title);
        return title === "Steering timing" ? options.find((option) => option === "interrupt-now") : undefined;
      },
    };
    const before = pi.posts.length;
    await pi.run("wfm-steer", runId);
    expect(editors).toEqual([`Steering text for ${chosen} of run ${runId}`]);
    // One offer needs no attempt choice. The timing is asked only when the offer names more than one.
    expect(selects).toEqual(offer.timings.length > 1 ? ["Steering timing"] : []);
    const { body } = onePost(runId, before);
    expect(body).toEqual({
      operation: "steer", occurrenceId: offer.occurrenceId.toString(), attemptId: String(offer.attemptId), timing: "interrupt-now", text: STEER_TEXT,
    });
    const command = acceptedCommand("steer");
    expect(await effectOf(command)).toBe("steered");
    expect(notices, notices.join("\n")).toContain(`Steer interrupt-now reached ${chosen} of run ${runId}.`);
    Object.assign(report, {
      steerRunId: runId, steerCommand: command, steerOccurrenceId: offer.occurrenceId.toString(), steerAttemptId: String(offer.attemptId),
      steerText: STEER_TEXT,
    });
  }, STEP_MS);

  it("redirects the attempt in flight of a run to the offered spare target", async () => {
    const runId = REDIRECT_RUN ?? "";
    // The live redirect is offered after the dispatch window closed, while one attempt runs, with the spare target only.
    const control = await controlsUntil(runId, (value) => {
      const offers = redirectOffers(value);
      return offers.length === 1 && offers[0].targets.length === 1 && offers[0].targets[0].endsWith("@spare");
    }, "live redirect offer");
    const offer = redirectOffers(control)[0];
    const target = offer.targets[0];
    const snapshot = must(await session.get(ref(`/v1/runs/${runId}/snapshot`)), "snapshot");
    const place = redirectPlace(snapshot.value as JsonObject, offer.occurrenceId);
    if (place.kind !== "attempt") throw new Error(`the redirect occurrence has no attempt in flight: ${JSON.stringify(snapshot.value)}`);
    const attemptId = place.attemptId;
    const listed: string[][] = [];
    pi.script = {
      select: (title, options) => {
        listed.push(options);
        return title === `Redirect target of run ${runId}` ? options[0] : undefined;
      },
    };
    const before = pi.posts.length;
    await pi.run("wfm-redirect", runId);
    expect(listed).toEqual([[`${target}  occurrence ${offer.occurrenceId}, attempt ${attemptId} in flight`]]);
    const { body } = onePost(runId, before);
    expect(body).toEqual({ operation: "redirect", occurrenceId: offer.occurrenceId.toString(), target });
    const command = acceptedCommand("redirect");
    expect(await effectOf(command)).toBe("redirected");
    expect(notices, notices.join("\n")).toContain(`Redirected occurrence ${offer.occurrenceId} of run ${runId} from attempt ${attemptId} to ${target}.`);
    Object.assign(report, {
      redirectRunId: runId, redirectCommand: command, redirectOccurrenceId: offer.occurrenceId.toString(), redirectAttemptId: attemptId,
      redirectTarget: target,
    });
  }, STEP_MS);

  it("closes the extension after one steer and one redirect and writes the report", async () => {
    // Only the offered controls were sent, each once.
    expect(pi.posts.map((post) => [post.resource, JSON.parse(String(post.body)).operation])).toEqual([
      [`/v1/runs/${String(report.steerRunId)}/control`, "steer"], [`/v1/runs/${String(report.redirectRunId)}/control`, "redirect"],
    ]);
    await pi.close();
    expect(await pi.status()).toContain("Connection: closed. The manager keeps its runs under its own supervision.");
    if (REPORT !== undefined) writeFileSync(REPORT, `${JSON.stringify(report)}\n`, { mode: 0o600 });
  }, STEP_MS);
});
