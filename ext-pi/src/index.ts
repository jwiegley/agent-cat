import { join } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Text } from "@earendil-works/pi-tui";
import { Type, type Static } from "typebox";
import { discoverRunner, readHelp, readRouting, supportsRoutingInspection } from "./catalogue.ts";
import { configuredManagerProfiles, configuredRemote, configuredRunners, retentionPolicy, stateDirectory } from "./config.ts";
import { CurrentSessionBridge } from "./current-bridge.ts";
import { assertNoCredentialArgs, prepareLaunch, preflightLineage, previewPlan, type LineageEdit, type PreparedLaunch } from "./launch.ts";
import { formatControl, formatMonitor } from "./monitor.ts";
import { WorkflowMonitorComponent } from "./monitor-ui.ts";
import { openRemotePi } from "./pi-remote-runtime.mjs";
import type { SessionOptions } from "./manager/session.ts";
import { ManagerRequests, toolContext, type CommandRecord, type ModelForkEdit } from "./manager-ui.ts";
import { ServiceMode, type ServiceSelection } from "./service-mode.ts";
import { RunSupervisor, type OwnedRun } from "./supervisor.ts";
import type { ClientMode, ControlAckSnapshot, RoutingInspection, RunnerConfig, RunSnapshot, TargetKind, WorkflowDescriptor } from "./types.ts";

/**
 * Options of the extension that Pi does not give. `manager` holds the
 * session options of service mode, for example a test transport.
 */
export type ExtensionHooks = { readonly manager?: SessionOptions };

export default function agentCatExtension(pi: ExtensionAPI, hooks: ExtensionHooks = {}): void {
  const supervisor = new RunSupervisor();
  let lastContext: ExtensionContext | undefined;
  let service: ServiceMode | undefined;
  const requests = new ManagerRequests(() => service);
  const currentBridge = new CurrentSessionBridge(pi, () => lastContext);
  const supervise = (prepared: PreparedLaunch, ctx: ExtensionContext, workflow: string) => {
    const run = supervisor.start(prepared);
    let recorded = false;
    run.subscribe((snapshot) => {
      updateWidget(ctx, supervisor, service);
      if (!recorded && ["succeeded", "failed", "cancelled", "orphaned"].includes(snapshot.status)) {
        recorded = true;
        pi.appendEntry("agent-cat-run", {
          runId: snapshot.runId, status: snapshot.status, workflow: snapshot.workflow ?? workflow,
          billFresh: snapshot.billFresh, billMemo: snapshot.billMemo, failureClass: snapshot.failureClass, failure: snapshot.failure,
          storeDir: prepared.storeDir, parentRunId: prepared.manifest.parentRunId, lineage: prepared.manifest.lineage,
        });
      }
    });
    ctx.ui.notify(`Started ${workflow} as ${prepared.manifest.runId}`, "info");
    return run;
  };

  /**
   * Starts a lineage child of a local run. Without `model`, the human
   * confirms the operation and enters the inputs and the fork edits. With
   * `model`, the inputs and the edits come from the model, and the child
   * starts only after the human confirms the exact lineage review. The
   * result is the started run, the text of a refusal or a decline, or
   * `undefined` when the human stops the collection.
   */
  const launchLineage = async (
    operation: "restart" | "resume" | "fork",
    parentRunId: string,
    ctx: ExtensionContext,
    model?: { readonly inputs: Record<string, string>; readonly edits: LineageEdit[] },
  ): Promise<OwnedRun | string | undefined> => {
    const refuse = (message: string): string => {
      ctx.ui.notify(message, "error");
      return message;
    };
    if (!ctx.isProjectTrusted()) return refuse(`${operation} requires a trusted project`);
    if (!ctx.hasUI) return refuse(`${operation} requires interactive approval`);
    const parent = supervisor.get(parentRunId);
    if (!parent) return refuse(`Unknown parent run ${parentRunId}`);
    if (!["succeeded", "failed", "cancelled", "orphaned"].includes(parent.snapshot.status)) {
      return refuse("Lineage operations require a terminal or orphaned parent run");
    }
    const selected = (await discover(ctx)).find(
      ({ runner, descriptor }) => runner.id === parent.manifest.runnerId && descriptor.name === parent.manifest.workflow,
    );
    if (!selected) return refuse("The parent workflow runner is no longer configured");
    let inputs = model?.inputs;
    if (!inputs) {
      if (!(await ctx.ui.confirm(`${operation} workflow run?`, `${operation} creates a new workflow run and never mutates the parent. Inputs will be collected again.`))) return;
      inputs = await collectInputs(ctx, selected.descriptor);
      if (!inputs) return;
    }
    let edits = model?.edits ?? [];
    if (operation === "fork" && model === undefined) {
      const collected = await collectForkEdits(ctx, parent.snapshot);
      if (collected === undefined) return;
      edits = collected;
    }
    const remote = configuredRemote();
    const targetKind = parent.manifest.targetKind;
    let targetSpec: { args: string[]; env: NodeJS.ProcessEnv } | undefined;
    if (targetKind === "current") {
      if (!currentBridge.supported) return refuse("Current-session lineage requires Pi ExtensionAPI.startTaskTurn");
      if (currentBridge.busy) return refuse("The current Pi session is already assigned to a workflow");
      targetSpec = currentBridge.target();
    } else if (targetKind === "child") targetSpec = ownedChildTarget();
    else if (targetKind === "remote") targetSpec = remote ? await selectRemoteTarget(ctx, remote) : undefined;
    else targetSpec = { args: [...parent.manifest.targetArgs], env: {} };
    if (!targetSpec) return refuse("The parent's remote target is no longer configured");
    if (model !== undefined) {
      const review = lineageReview({ operation, parentRunId, runner: selected.runner, descriptor: selected.descriptor, cwd: ctx.cwd, targetKind, targetArgs: targetSpec.args, inputs, edits });
      if (!(await ctx.ui.confirm(`${operation} workflow run?`, review))) return declinedText(operation);
    }
    const stateDir = stateDirectory();
    const parentRuntimeDir = join(parent.storeDir, "runtime");
    try {
      await preflightLineage({ runner: selected.runner, descriptor: selected.descriptor, cwd: ctx.cwd, stateDir, inputs, targetArgs: targetSpec.args, operation, parentRuntimeDir, edits });
    } catch (error) {
      return refuse(error instanceof Error ? error.message : String(error));
    }
    const prepared = await prepareLaunch({
      runner: selected.runner,
      descriptor: selected.descriptor,
      cwd: ctx.cwd,
      stateDir,
      inputs,
      targetKind,
      targetArgs: targetSpec.args,
      persona: parent.manifest.persona,
      lineage: { operation, parentRunId, parentRuntimeDir, edits },
    });
    Object.assign(prepared.env, targetSpec.env);
    return supervise(prepared, ctx, selected.descriptor.name);
  };

  pi.registerEntryRenderer<{ runId: string; status: string; workflow?: string; billFresh?: string; billMemo?: string; failureClass?: string; failure?: string; storeDir?: string; parentRunId?: string; lineage?: string }>("agent-cat-run", (entry, _options, theme) => {
    const data = entry.data;
    const lines = [
      theme.fg(data?.status === "succeeded" ? "success" : data?.status === "failed" ? "error" : "muted", `agent-cat ${data?.runId}: ${data?.status} ${data?.workflow ?? ""}`),
      data?.billFresh ? `bill fresh=${data.billFresh} memo=${data.billMemo ?? "?"}` : undefined,
      data?.failure ? `failure ${data.failureClass ?? "unknown"}: ${data.failure}` : undefined,
      data?.lineage ? `${data.lineage} of ${data.parentRunId}` : undefined,
      data?.storeDir ? `run store: ${data.storeDir}` : undefined,
    ].filter((line): line is string => Boolean(line));
    return new Text(lines.join("\n"), 0, 0);
  });

  pi.on("session_start", async (_event, ctx) => {
    lastContext = ctx;
    const mode = configuredManagerProfiles();
    // Local restore and retention apply only to the local state directory,
    // after the root-role check of RunSupervisor.restore. Service mode never
    // restores, prunes or reconstructs manager runs.
    await supervisor.restore(stateDirectory(), retentionPolicy());
    await currentBridge.start(stateDirectory());
    await service?.close();
    service = undefined;
    if (mode.kind === "service") {
      const started: ServiceMode = new ServiceMode(mode.profiles, {
        session: hooks.manager,
        onChange: () => {
          if (lastContext !== undefined && service === started) updateWidget(lastContext, supervisor, started);
        },
      });
      service = started;
      void started.start().then((selection) => notifySelection(ctx, selection));
    }
    updateWidget(ctx, supervisor, service);
  });
  pi.on("input", async (event, ctx) => {
    if (currentBridge.busy && event.source !== "extension") {
      ctx.ui.notify("The current session is exclusively assigned to an agent-cat workflow; cancel that run before sending another prompt", "warning");
      return { action: "handled" };
    }
    return { action: "continue" };
  });
  pi.on("session_shutdown", async () => {
    // Closing service mode closes the manager transport and sends no
    // command, so every manager run continues under manager supervision.
    await service?.close();
    await supervisor.shutdown();
    await currentBridge.close();
  });

  pi.registerCommand("wf", {
    description: "Run an agent-cat workflow in the current Agent Deck session",
    getArgumentCompletions: async (prefix) => {
      if (!lastContext) return null;
      const catalogue = await discover(lastContext);
      const items = catalogue
        .map(({ runner, descriptor }) => ({ value: `${runner.id}:${descriptor.name}`, label: `${runner.id}:${descriptor.name}`, description: descriptor.blurb }))
        .filter((item) => item.value.startsWith(prefix));
      return items.length ? items : null;
    },
    handler: async (args, ctx) => {
      if (!ctx.hasUI) return ctx.ui.notify("/wf requires interactive approval and is unavailable in this mode", "error");
      if (!ctx.isProjectTrusted()) return ctx.ui.notify("/wf requires a trusted project", "error");
      const sessionId = process.env.AGENTDECK_INSTANCE_ID?.trim();
      if (!sessionId) return ctx.ui.notify("/wf requires a current Agent Deck session (AGENTDECK_INSTANCE_ID is unavailable)", "error");
      let invocation: WorkflowCommand;
      try { invocation = parseWorkflowCommand(args); }
      catch (error) { return ctx.ui.notify(error instanceof Error ? error.message : String(error), "error"); }
      const catalogue = await discover(ctx);
      if (catalogue.length === 0) return ctx.ui.notify("No AGENT_CAT_RUNNER is configured", "warning");
      let selected = invocation.workflow ? selectWorkflow(catalogue, invocation.workflow) : undefined;
      if (invocation.workflow && !selected) return ctx.ui.notify(`Unknown workflow: ${invocation.workflow}`, "error");
      if (!invocation.workflow) {
        const choices = catalogue.map(({ runner, descriptor }) => `${runner.id}:${descriptor.name} — ${descriptor.blurb}`);
        const choice = await ctx.ui.select("agent-cat workflows", choices);
        if (!choice) return;
        selected = catalogue[choices.indexOf(choice)];
      }
      if (!selected) return;
      let supplied: Record<string, string>;
      try { supplied = bindWorkflowSources(selected.descriptor, invocation); }
      catch (error) { return ctx.ui.notify(error instanceof Error ? error.message : String(error), "error"); }
      const inputs = await collectInputs(ctx, selected.descriptor, supplied);
      if (!inputs) return;
      const sourceSummary = Object.entries(supplied).map(([name, value]) => `${name}=${Buffer.byteLength(value)}B`).join(", ") || "none";
      if (!(await ctx.ui.confirm(
        "Launch agent-cat workflow?",
        `workflow=${selected.runner.id}:${selected.descriptor.name}\nrunner=${selected.runner.executable}\ncwd=${ctx.cwd}\ntarget=current Agent Deck session (${sessionId}); external pane/workspace, not sandboxed\nprebound inputs=${sourceSummary}\neffects=${selected.descriptor.capabilities.effects ?? "unknown"}\nmay call a paid model; persistence=private full prompts/answers plus input hashes`,
      ))) return;
      const prepared = await prepareLaunch({
        runner: selected.runner,
        descriptor: selected.descriptor,
        cwd: ctx.cwd,
        stateDir: stateDirectory(),
        inputs,
        targetKind: "deck",
        targetArgs: ["--session", sessionId],
      });
      supervise(prepared, ctx, selected.descriptor.name);
    },
  });

  pi.registerCommand("wf-help", {
    description: "Show exact runner help for an agent-cat workflow",
    handler: async (args, ctx) => {
      const selected = selectWorkflow(await discover(ctx), args.trim());
      if (!selected) return ctx.ui.notify(`Unknown workflow: ${args.trim()}`, "error");
      ctx.ui.notify(await readHelp(selected.runner, selected.descriptor.name, ctx.cwd), "info");
    },
  });

  pi.registerCommand("wf-plan", {
    description: "Show the runner's raw plan for an agent-cat workflow",
    handler: async (args, ctx) => {
      const selected = selectWorkflow(await discover(ctx), args.trim());
      if (!selected) return ctx.ui.notify(`Unknown workflow: ${args.trim()}`, "error");
      if (!ctx.hasUI && selected.descriptor.inputs.length > 0) return ctx.ui.notify("workflow plan inputs require interactive UI", "error");
      const inputs = await collectInputs(ctx, selected.descriptor);
      if (!inputs) return;
      const plan = await previewPlan({ runner: selected.runner, descriptor: selected.descriptor, cwd: ctx.cwd, stateDir: stateDirectory(), inputs });
      ctx.ui.notify(JSON.stringify(plan, null, 2), "info");
    },
  });

  pi.registerCommand("wf-launch", {
    description: "Run an agent-cat workflow with an explicit execution target",
    getArgumentCompletions: async (prefix) => {
      if (!lastContext) return null;
      const catalogue = await discover(lastContext);
      const items = catalogue
        .map(({ runner, descriptor }) => ({ value: `${runner.id}:${descriptor.name}`, label: `${runner.id}:${descriptor.name}`, description: descriptor.blurb }))
        .filter((item) => item.value.startsWith(prefix));
      return items.length ? items : null;
    },
    handler: async (args, ctx) => {
      if (!ctx.hasUI) return ctx.ui.notify("/wf-launch requires interactive approval and is unavailable in this mode", "error");
      if (!ctx.isProjectTrusted()) return ctx.ui.notify("/wf-launch requires a trusted project", "error");
      const catalogue = await discover(ctx);
      const selected = selectWorkflow(catalogue, args.trim());
      if (!selected) return ctx.ui.notify(`Unknown workflow: ${args.trim()}`, "error");
      const remote = configuredRemote();
      const targets: string[] = [TARGET_LABEL.scripted];
      if (supportsRoutingInspection(selected.descriptor)) targets.push(TARGET_LABEL.routing);
      targets.push(TARGET_LABEL.acp, TARGET_LABEL.deck);
      if (currentBridge.supported) targets.push(TARGET_LABEL.current);
      targets.push(TARGET_LABEL.child);
      if (remote) targets.push(TARGET_LABEL.remote);
      const target = await ctx.ui.select("Execution target", targets);
      if (!target) return;
      let routingSelection: RoutingLaunchSelection;
      if (target.startsWith("routing configuration")) {
        try {
          const configured = await collectRoutingSelection(ctx, selected.runner, selected.descriptor);
          if (!configured) return;
          routingSelection = configured;
        } catch (error) {
          ctx.ui.notify(error instanceof Error ? error.message : String(error), "error");
          return;
        }
      } else {
        routingSelection = { args: [], managedAxes: new Set() };
      }
      let targetKind: TargetKind = "scripted";
      let targetSpec: { args: string[]; env: NodeJS.ProcessEnv };
      if (target.startsWith("routing configuration")) {
        targetKind = "routing";
        targetSpec = { args: [], env: {} };
      } else if (target.startsWith("native ACP")) {
        targetKind = "acp";
        const adapter = await ctx.ui.input("ACP adapter (stub, claude, codex, droid, or absolute path)", "stub");
        if (!adapter?.trim()) return;
        const rawArgs = await ctx.ui.editor("Adapter argv JSON array (use [] for none)", "[]");
        if (rawArgs === undefined) return;
        const adapterArgs = parseStringArray(rawArgs, "adapter argv");
        try { assertNoCredentialArgs(adapterArgs); } catch (error) { ctx.ui.notify(error instanceof Error ? error.message : String(error), "error"); return; }
        const routes = await collectRoutes(ctx, selected.descriptor.pins.filter((pin) => !routingSelection.managedAxes.has(pin)));
        if (!routes) return;
        const acpArgs = ["--engine", "acp", "--adapter", adapter.trim(), ...adapterArgs.flatMap((arg) => ["--adapter-arg", arg]), ...routes];
        try { assertNoCredentialArgs(acpArgs); } catch (error) { ctx.ui.notify(error instanceof Error ? error.message : String(error), "error"); return; }
        if (!(await ctx.ui.confirm("Use live ACP adapter?", "The adapter may call a paid model. Agent-cat owns its scratch cwd and intent permissions; this is not an OS sandbox."))) return;
        targetSpec = { args: acpArgs, env: {} };
      } else if (target.startsWith("native agent-deck")) {
        targetKind = "deck";
        const sessionId = await ctx.ui.input("agent-deck session ID");
        if (!sessionId?.trim()) return;
        const routes = await collectRoutes(ctx, selected.descriptor.pins.filter((pin) => !routingSelection.managedAxes.has(pin)));
        if (!routes) return;
        if (!(await ctx.ui.confirm("Use live agent-deck session?", "The external pane may call a paid model and uses its own workspace. Agent-cat remains the workflow interpreter."))) return;
        targetSpec = { args: ["--session", sessionId.trim(), ...routes], env: {} };
      } else if (target.startsWith("current")) {
        targetKind = "current";
        if (currentBridge.busy) return ctx.ui.notify("The current Pi session is already assigned to a workflow", "error");
        if (!(await ctx.ui.confirm("Use current Pi session?", "Workflow questions will start model turns in this session and may incur provider charges."))) return;
        targetSpec = currentBridge.target();
      } else if (target.startsWith("owned")) {
        targetKind = "child";
        if (selected.descriptor.capabilities.effectful === true) return ctx.ui.notify("Owned child targets run without tools; use the current session for effectful workflows", "error");
        if (!(await ctx.ui.confirm(...TARGET_CONFIRMATION.child))) return;
        targetSpec = ownedChildTarget();
      } else if (target.startsWith("authenticated remote")) {
        targetKind = "remote";
        if (!remote) throw new Error("remote target disappeared");
        const remoteTarget = await selectRemoteTarget(ctx, remote);
        if (!remoteTarget) return;
        if (!(await ctx.ui.confirm(...TARGET_CONFIRMATION.remote))) return;
        targetSpec = remoteTarget;
      } else {
        targetSpec = { args: ["--scripted"], env: {} };
      }
      if (routingSelection.args.length > 0) targetSpec = { ...targetSpec, args: [...targetSpec.args, ...routingSelection.args] };
      const review = launchReview({ runner: selected.runner, descriptor: selected.descriptor, cwd: ctx.cwd, targetKind, routing: routingSelection.inspection?.persona.name });
      if (!(await ctx.ui.confirm("Launch agent-cat workflow?", review))) return;
      const inputs = await collectInputs(ctx, selected.descriptor);
      if (!inputs) return;
      const prepared = await prepareLaunch({
        runner: selected.runner,
        descriptor: selected.descriptor,
        cwd: ctx.cwd,
        stateDir: stateDirectory(),
        inputs,
        targetKind,
        targetArgs: targetSpec.args,
        persona: routingSelection.inspection?.persona.name,
      });
      Object.assign(prepared.env, targetSpec.env);
      supervise(prepared, ctx, selected.descriptor.name);
    },
  });

  for (const operation of ["restart", "resume", "fork"] as const) {
    pi.registerCommand(`wf-${operation}`, {
      description: `${operation} an agent-cat workflow as a new immutable child run`,
      handler: async (args, ctx) => {
        const parentRunId = args.trim();
        if (!parentRunId) return ctx.ui.notify(`Usage: /wf-${operation} PARENT_RUN_ID`, "warning");
        await launchLineage(operation, parentRunId, ctx);
      },
    });
  }

  pi.registerCommand("wf-diff", {
    description: "Show immutable lineage differences for a child run",
    handler: async (args, ctx) => {
      const child = supervisor.get(args.trim());
      if (!child) return ctx.ui.notify(`Unknown child run ${args.trim()}`, "error");
      const parentId = child.manifest.parentRunId;
      const parent = parentId ? supervisor.get(parentId) : undefined;
      if (!parent) return ctx.ui.notify("Run has no available parent", "warning");
      const changedInputs = Object.keys({ ...parent.manifest.inputHashes, ...child.manifest.inputHashes })
        .filter((name) => parent.manifest.inputHashes[name] !== child.manifest.inputHashes[name]);
      const occurrenceIds = [...new Set([...parent.snapshot.occurrences.keys(), ...child.snapshot.occurrences.keys()])].sort((left, right) => BigInt(left) < BigInt(right) ? -1 : BigInt(left) > BigInt(right) ? 1 : 0);
      const occurrenceLines = occurrenceIds.map((id) => {
        const before = parent.snapshot.occurrences.get(id);
        const after = child.snapshot.occurrences.get(id);
        if (!before) return `occurrence ${id}: added`;
        if (!after) return `occurrence ${id}: removed`;
        const beforeAttempts = JSON.stringify([...before.attempts.values()].map(({ state, target, failureClass }) => ({ state, target, failureClass })));
        const afterAttempts = JSON.stringify([...after.attempts.values()].map(({ state, target, failureClass }) => ({ state, target, failureClass })));
        const changes = [
          before.state === after.state ? undefined : `state ${before.state}→${after.state}`,
          before.source === after.source ? undefined : `source ${before.source ?? "none"}→${after.source ?? "none"}`,
          before.reuseKind === after.reuseKind ? undefined : `reuse ${before.reuseKind ?? "none"}→${after.reuseKind ?? "none"}`,
          before.answer === after.answer ? undefined : "answer changed",
          before.attempts.size === after.attempts.size ? undefined : `attempts ${before.attempts.size}→${after.attempts.size}`,
          beforeAttempts === afterAttempts ? undefined : "attempt history changed",
        ].filter((change): change is string => change !== undefined);
        return `occurrence ${id}: ${changes.join(", ") || "unchanged"}`;
      });
      const lines = [
        `${child.manifest.lineage ?? "child"} ${child.manifest.runId} of ${parentId}`,
        `program: ${parent.manifest.programHash === child.manifest.programHash ? "unchanged" : "changed"}`,
        `target: ${JSON.stringify(parent.manifest.targetArgs) === JSON.stringify(child.manifest.targetArgs) ? "unchanged" : "changed"}`,
        `inputs: ${changedInputs.length ? changedInputs.join(", ") : "unchanged"}`,
        `answer edits: ${child.manifest.lineageEdits?.length ? JSON.stringify(child.manifest.lineageEdits) : "none"}`,
        ...occurrenceLines,
      ];
      ctx.ui.notify(lines.join("\n"), "info");
    },
  });

  pi.registerCommand("wf-status", {
    description: "Show recent agent-cat workflow runs",
    handler: async (_args, ctx) => {
      const mode = configuredManagerProfiles();
      const rows = supervisor.snapshots().map((snapshot) => `${snapshot.runId}  ${snapshot.status}  ${snapshot.workflow ?? "starting"}`);
      ctx.ui.notify([modeLine(mode), rows.join("\n") || "No active workflow runs"].join("\n"), "info");
    },
  });

  pi.registerCommand("wfm-status", {
    description: "Show the manager endpoint, its delivery state, and its service runs, requests and decision heads",
    handler: async (_args, ctx) => {
      if (service === undefined) return ctx.ui.notify(SERVICE_UNCONFIGURED, "warning");
      ctx.ui.notify(formatServiceStatus(service, requests.records()), service.connection.kind === "connected" ? "info" : "warning");
    },
  });

  pi.registerCommand("wfm", {
    description: "Create a manager request: select a workflow, enter its exact inputs, enqueue it, and review and approve it",
    handler: async (args, ctx) => { await requests.start(ctx, args); },
  });

  pi.registerCommand("wfm-review", {
    description: "Continue a manager request: collect its missing inputs, follow its admission, or show its exact review",
    handler: async (args, ctx) => requests.review(ctx, args),
  });

  pi.registerCommand("wfm-withdraw", {
    description: "Withdraw a manager request before its start",
    handler: async (args, ctx) => requests.withdraw(ctx, args),
  });

  pi.registerCommand("wfm-discard", {
    description: "Discard the live preparation of a manager request in review",
    handler: async (args, ctx) => requests.discard(ctx, args),
  });

  pi.registerCommand("wfm-monitor", {
    description: "Show the live monitor of a manager run: runtime status, observation freshness, decisions, and the terminal result",
    handler: async (args, ctx) => requests.monitor(ctx, args),
  });

  pi.registerCommand("wfm-answer", {
    description: "Answer the head decision of a manager run with a typed answer, or send a recovery choice that the manager offers",
    handler: async (args, ctx) => { await requests.answer(ctx, args); },
  });

  pi.registerCommand("wfm-cancel", {
    description: "Cancel a manager run after confirmation when its controls allow the cancel, and report the receipt and the runtime acknowledgement",
    handler: async (args, ctx) => { await requests.cancel(ctx, args); },
  });

  pi.registerCommand("wfm-steer", {
    description: "Steer the attempt of a manager run that its controls offer, and report the receipt and the runtime acknowledgement",
    handler: async (args, ctx) => { await requests.steer(ctx, args); },
  });

  pi.registerCommand("wfm-redirect", {
    description: "Redirect an occurrence of a manager run to an offered target, in its dispatch window or for its attempt in flight, and report the receipt and the runtime acknowledgement",
    handler: async (args, ctx) => { await requests.redirect(ctx, args); },
  });

  pi.registerCommand("wfm-result", {
    description: "Retrieve the verified result of a manager run and save its exact bytes to a new file with mode 0600",
    handler: async (args, ctx) => { await requests.result(ctx, args); },
  });

  pi.registerCommand("wfm-history", {
    description: "List every run of the manager history over all pages, with legacy entries labelled observer",
    handler: async (_args, ctx) => requests.history(ctx),
  });

  for (const operation of ["restart", "resume", "fork"] as const) {
    pi.registerCommand(`wfm-${operation}`, {
      description: `Create a ${operation} child request of a manager run, show its exact review with its lineage, and approve it to start the child run`,
      handler: async (args, ctx) => { await requests.lineage(ctx, operation, args); },
    });
  }

  pi.registerCommand("wfm-export", {
    description: "Export the verified result of a manager run under a name, verify the exported bytes, and list the exports of the run",
    handler: async (args, ctx) => { await requests.export(ctx, args); },
  });

  pi.registerCommand("wfm-endpoints", {
    description: "Choose the active manager client profile",
    handler: async (args, ctx) => {
      if (service === undefined) return ctx.ui.notify(SERVICE_UNCONFIGURED, "warning");
      const current = service;
      const labels = current.profiles.map((path, index) => `${index + 1}  ${path}${index === current.active ? "  (active)" : ""}`);
      let index: number;
      const chosen = args.trim();
      if (chosen) {
        index = /^[1-9][0-9]*$/.test(chosen) ? Number(chosen) - 1 : current.profiles.indexOf(chosen);
        if (index < 0 || index >= current.profiles.length) return ctx.ui.notify(`Unknown manager profile ${chosen}`, "error");
      } else {
        if (!ctx.hasUI) return ctx.ui.notify("Usage: /wfm-endpoints PROFILE_NUMBER\n" + labels.join("\n"), "warning");
        const selected = await ctx.ui.select("Manager profile", labels);
        if (!selected) return;
        index = labels.indexOf(selected);
      }
      notifySelection(ctx, await current.select(index));
    },
  });

  pi.registerCommand("wf-monitor", {
    description: "Inspect one active or recent agent-cat workflow run",
    handler: async (args, ctx) => {
      let runId = args.trim();
      if (!runId) {
        if (!ctx.hasUI) return ctx.ui.notify("Usage: /wf-monitor RUN_ID", "warning");
        const snapshots = supervisor.snapshots().reverse();
        if (snapshots.length === 0) return ctx.ui.notify("No workflow runs", "info");
        const selected = await ctx.ui.select("Workflow run", snapshots.map((snapshot) => `${snapshot.runId}  ${snapshot.status}  ${snapshot.workflow ?? "starting"}`));
        if (!selected) return;
        runId = selected.split(/\s+/, 1)[0];
      }
      const run = supervisor.get(runId);
      if (!run) return ctx.ui.notify(`Unknown run ${runId}`, "error");
      if (ctx.mode !== "tui") return ctx.ui.notify(formatMonitor(run.snapshot), run.snapshot.status === "failed" ? "error" : "info");
      await ctx.ui.custom<void>((tui, theme, _kb, done) => {
        let unsubscribe = () => {};
        const component = new WorkflowMonitorComponent(tui, theme, run.snapshot, () => {
          unsubscribe();
          done();
        });
        unsubscribe = run.subscribe((snapshot) => component.update(snapshot));
        return component;
      });
    },
  });

  pi.registerCommand("wf-steer", {
    description: "Steer one active agent-cat attempt",
    handler: async (args, ctx) => {
      if (!ctx.hasUI) return ctx.ui.notify("workflow steering requires interactive approval", "error");
      if (!ctx.isProjectTrusted()) return ctx.ui.notify("workflow steering requires a trusted project", "error");
      let runId = args.trim();
      if (!runId) {
        const active = supervisor.activeSnapshots();
        if (active.length === 0) return ctx.ui.notify("No active workflow runs", "info");
        const selectedRun = await ctx.ui.select("Workflow run", active.map((snapshot) => `${snapshot.runId}  ${snapshot.workflow ?? "starting"}`));
        if (!selectedRun) return;
        runId = selectedRun.split(/\s+/, 1)[0];
      }
      const run = supervisor.get(runId);
      if (!run) return ctx.ui.notify(`Unknown run ${runId}`, "error");
      const attempts = [...run.snapshot.occurrences].flatMap(([occurrenceId, occurrence]) =>
        [...occurrence.attempts.values()].filter((attempt) => attempt.state === "running").map((attempt) => `${occurrenceId} ${attempt.id}  ${attempt.target ?? "unknown target"}`),
      );
      if (attempts.length === 0) return ctx.ui.notify("The run has no active attempt", "warning");
      const selectedAttempt = await ctx.ui.select("Active attempt", attempts);
      if (!selectedAttempt) return;
      const [occurrenceId, attemptId] = selectedAttempt.split(/\s+/, 2);
      const text = await ctx.ui.editor("Steering text");
      if (!text?.trim()) return;
      const timing = await ctx.ui.select("Steering timing", ["interrupt-now", "next-boundary"] as const);
      if (timing !== "interrupt-now" && timing !== "next-boundary") return;
      notifyControl(ctx, "steer", await run.steer(occurrenceId, attemptId, text, timing));
    },
  });

  pi.registerCommand("wf-retry", {
    description: "Retry one recoverable agent-cat occurrence",
    handler: async (args, ctx) => {
      if (!ctx.hasUI) return ctx.ui.notify("workflow retry requires interactive approval", "error");
      if (!ctx.isProjectTrusted()) return ctx.ui.notify("workflow retry requires a trusted project", "error");
      let runId = args.trim();
      if (!runId) {
        const active = supervisor.activeSnapshots();
        if (active.length === 0) return ctx.ui.notify("No active workflow runs", "info");
        const selectedRun = await ctx.ui.select("Workflow run", active.map((snapshot) => `${snapshot.runId}  ${snapshot.workflow ?? "starting"}`));
        if (!selectedRun) return;
        runId = selectedRun.split(/\s+/, 1)[0];
      }
      const run = supervisor.get(runId);
      if (!run) return ctx.ui.notify(`Unknown run ${runId}`, "error");
      const recoverable = [...run.snapshot.occurrences.values()].filter((occurrence) => occurrence.state === "recovering" && occurrence.recovery?.choices.some((choice) => choice.choice === "retry"));
      if (recoverable.length === 0) return ctx.ui.notify("The run has no recoverable occurrence", "warning");
      const selected = await ctx.ui.select("Recoverable occurrence", recoverable.map((occurrence) => `${occurrence.id}  ${occurrence.recovery?.gap ?? "gap"}: ${occurrence.recovery?.message ?? ""}`));
      if (!selected) return;
      const occurrenceId = selected.split(/\s+/, 1)[0];
      notifyControl(ctx, "retry", await run.retry(occurrenceId));
    },
  });

  pi.registerCommand("wf-recover", {
    description: "Choose retry, failover, or abandon for a recoverable occurrence",
    handler: async (args, ctx) => {
      if (!ctx.hasUI) return ctx.ui.notify("workflow recovery requires interactive approval", "error");
      if (!ctx.isProjectTrusted()) return ctx.ui.notify("workflow recovery requires a trusted project", "error");
      let runId = args.trim();
      if (!runId) {
        const active = supervisor.activeSnapshots();
        if (active.length === 0) return ctx.ui.notify("No active workflow runs", "info");
        const selectedRun = await ctx.ui.select("Workflow run", active.map((snapshot) => `${snapshot.runId}  ${snapshot.workflow ?? "starting"}`));
        if (!selectedRun) return;
        runId = selectedRun.split(/\s+/, 1)[0];
      }
      const run = supervisor.get(runId);
      if (!run) return ctx.ui.notify(`Unknown run ${runId}`, "error");
      const recoverable = [...run.snapshot.occurrences.values()].filter((occurrence) => occurrence.state === "recovering");
      if (recoverable.length === 0) return ctx.ui.notify("The run has no recoverable occurrence", "warning");
      const labels = recoverable.map((occurrence) => `${occurrence.id}  ${occurrence.recovery?.gap ?? "gap"}: ${occurrence.recovery?.message ?? ""}`);
      const selected = await ctx.ui.select("Recoverable occurrence", labels);
      if (!selected) return;
      const occurrence = recoverable[labels.indexOf(selected)];
      const choices = occurrence.recovery?.choices.map((offered) => offered.choice) ?? [];
      const choice = await ctx.ui.select("Recovery choice", choices);
      if (choice !== "retry" && choice !== "failover" && choice !== "abandon") return;
      notifyControl(ctx, choice, await run.recover(occurrence.id, choice));
    },
  });

  pi.registerCommand("wf-redirect", {
    description: "Redirect one occurrence: to a reserved target in its dispatch window, or to a live candidate of its fail-over chain while its attempt runs",
    handler: async (args, ctx) => {
      if (!ctx.hasUI) return ctx.ui.notify("workflow redirect requires interactive approval", "error");
      if (!ctx.isProjectTrusted()) return ctx.ui.notify("workflow redirect requires a trusted project", "error");
      const trimmed = args.trim();
      const [runId, occurrenceId] = trimmed.split(/\s+/, 2);
      const target = trimmed.split(/\s+/).slice(2).join(" ");
      if (!runId || !occurrenceId || !target) return ctx.ui.notify("Usage: /wf-redirect RUN_ID OCCURRENCE_ID TARGET", "warning");
      const run = supervisor.get(runId);
      if (!run) return ctx.ui.notify(`Unknown run ${runId}`, "error");
      try {
        const ack = await run.redirect(occurrenceId, target);
        notifyControl(ctx, "redirect", ack, run.snapshot, occurrenceId);
      } catch (error) {
        ctx.ui.notify(error instanceof Error ? error.message : String(error), "error");
      }
    },
  });

  pi.registerCommand("wf-cancel", {
    description: "Cancel one owned agent-cat workflow run",
    handler: async (args, ctx) => {
      if (!ctx.hasUI) return ctx.ui.notify("workflow cancellation requires interactive approval", "error");
      if (!ctx.isProjectTrusted()) return ctx.ui.notify("workflow cancellation requires a trusted project", "error");
      const runId = args.trim();
      const run = supervisor.get(runId);
      if (!run) return ctx.ui.notify(`Unknown run ${runId}`, "error");
      if (!(await ctx.ui.confirm("Cancel workflow run?", runId))) return;
      try {
        await run.cancel("cancelled by user command");
      } catch (error) {
        ctx.ui.notify(error instanceof Error ? error.message : String(error), "error");
      }
    },
  });

async function collectForkEdits(ctx: ExtensionContext, snapshot: RunSnapshot): Promise<LineageEdit[] | undefined> {
  const editable = [...snapshot.occurrences.values()].filter((occurrence) => occurrence.answer !== undefined);
  if (editable.length === 0) return [];
  const remaining = new Map(editable.map((occurrence) => [occurrence.id, occurrence]));
  const edits: LineageEdit[] = [];
  while (remaining.size > 0) {
    const choice = await ctx.ui.select("Fork answer edits", ["finish editing", "drop an answer", "replace an answer"] as const);
    if (!choice) return undefined;
    if (choice === "finish editing") return edits;
    const occurrences = [...remaining.values()];
    const labels = occurrences.map((occurrence) => `${occurrence.id} — ${occurrence.answer}`);
    const selected = await ctx.ui.select("Parent answer", labels);
    if (!selected) return undefined;
    const occurrenceId = occurrences[labels.indexOf(selected)].id;
    if (choice === "drop an answer") edits.push({ type: "drop", occurrenceId });
    else {
      const value = await ctx.ui.editor("Replacement answer as JSON");
      if (value === undefined) return undefined;
      try { JSON.parse(value); } catch { throw new Error("replacement answer is not JSON"); }
      edits.push({ type: "replace", occurrenceId, value });
    }
    remaining.delete(occurrenceId);
  }
  return edits;
}

function parseLineageEdits(value: string | undefined): LineageEdit[] {
  if (!value) return [];
  let parsed: unknown;
  try { parsed = JSON.parse(value); } catch { throw new Error("forkEditsJson is not valid JSON"); }
  if (!Array.isArray(parsed)) throw new Error("forkEditsJson must be an array");
  const edits = parsed.map((entry) => {
    if (typeof entry !== "object" || entry === null || Array.isArray(entry)) throw new Error("fork edit is not an object");
    const edit = entry as Record<string, unknown>;
    if ((edit.type !== "drop" && edit.type !== "replace") || typeof edit.occurrenceId !== "string" || !/^(0|[1-9][0-9]*)$/.test(edit.occurrenceId)) throw new Error("fork edit requires type and decimal occurrenceId");
    if (edit.type === "replace") {
      if (typeof edit.value !== "string") throw new Error("replacement fork edit requires JSON value text");
      try { JSON.parse(edit.value); } catch { throw new Error("replacement fork edit value is not JSON"); }
    }
    return edit.type === "drop"
      ? { type: "drop" as const, occurrenceId: edit.occurrenceId }
      : { type: "replace" as const, occurrenceId: edit.occurrenceId, value: edit.value as string };
  });
  if (new Set(edits.map((edit) => edit.occurrenceId)).size !== edits.length) throw new Error("a fork answer may be edited only once");
  return edits;
}

  // The parameter schema leaves additional properties open. A field that
  // the model adds, such as grantId, approved or consent, reaches execute,
  // and execute reads none of them, so it never replaces the confirmation.
  pi.registerTool({
    name: "agent_cat_workflow",
    label: "agent-cat workflow",
    description: "Discover, launch, inspect, control, restart, resume, or fork agent-cat workflows: local runs through list, status, inspect, start, restart, resume, fork and the controls, and manager runs in service mode through manager-list, manager-status, manager-inspect, manager-result, manager-start, manager-answer, manager-control, manager-lineage and manager-export. "
      + "Each mutation requires a trusted project, an interactive Pi UI, and a human confirmation of its exact content in Pi: a manager start shows its request and then its exact review, an answer its typed value, a control its kind, target and text, a lineage operation its edits and then its exact review, and an export its scope and name. "
      + "No parameter replaces that confirmation, and a declined confirmation sends nothing. The tool never takes or gives a credential.",
    parameters: TOOL_PARAMETERS,
    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
      if (params.action.startsWith("manager-")) return managerAction(requests, service, params, ctx);
      if (params.action === "list") {
        const catalogue = lastContext ? await discover(lastContext) : [];
        return { content: [{ type: "text", text: catalogue.map(({ runner, descriptor }) => `${runner.id}:${descriptor.name} — ${descriptor.blurb}`).join("\n") || "No configured workflows" }], details: {} };
      }
      if (params.action === "status") {
        const snapshots = supervisor.snapshots();
        return { content: [{ type: "text", text: JSON.stringify(snapshots.map(({ runId, status, workflow }) => ({ runId, status, workflow }))) }], details: {} };
      }
      if (params.action === "inspect") {
        if (!ctx.isProjectTrusted()) return { content: [{ type: "text", text: "inspect requires a trusted project" }], details: {}, isError: true };
        if (!params.runId) return { content: [{ type: "text", text: "inspect requires runId" }], details: {}, isError: true };
        const run = supervisor.get(params.runId);
        if (!run) return { content: [{ type: "text", text: `Unknown run ${params.runId}` }], details: {}, isError: true };
        return { content: [{ type: "text", text: formatMonitor(run.snapshot) }], details: {} };
      }
      if (params.action === "start") {
        if (!ctx.isProjectTrusted()) return toolRefusal("start requires a trusted project");
        if (!ctx.hasUI) return toolRefusal(uiRequiredText("start"));
        if (!params.workflow) return toolRefusal("start requires workflow");
        try {
          const selected = selectWorkflow(await discover(ctx), params.workflow);
          if (!selected) throw new Error(`Unknown workflow: ${params.workflow}`);
          const inputs = parseInputsJson(params.inputsJson, selected.descriptor);
          const launchTarget = params.launchTarget ?? "scripted";
          const targetKind: TargetKind = launchTarget === "child" ? "child" : launchTarget === "remote" ? "remote" : "scripted";
          let targetSpec: { args: string[]; env: NodeJS.ProcessEnv };
          if (launchTarget === "child") {
            if (selected.descriptor.capabilities.effectful === true) throw new Error("tool-free child target refuses effectful workflow");
            if (!(await ctx.ui.confirm(...TARGET_CONFIRMATION.child))) return toolRefusal(declinedText("start"));
            targetSpec = ownedChildTarget();
          } else if (launchTarget === "remote") {
            const remote = configuredRemote();
            if (!remote) throw new Error("remote target is not configured");
            const selectedRemote = await selectRemoteTarget(ctx, remote);
            if (!selectedRemote) throw new Error("no remote session selected");
            if (!(await ctx.ui.confirm(...TARGET_CONFIRMATION.remote))) return toolRefusal(declinedText("start"));
            targetSpec = selectedRemote;
          } else targetSpec = { args: ["--scripted"], env: {} };
          const review = launchReview({ runner: selected.runner, descriptor: selected.descriptor, cwd: ctx.cwd, targetKind, inputs });
          if (!(await ctx.ui.confirm("Launch agent-cat workflow?", review))) return toolRefusal(declinedText("start"));
          const prepared = await prepareLaunch({ runner: selected.runner, descriptor: selected.descriptor, cwd: ctx.cwd, stateDir: stateDirectory(), inputs, targetKind, targetArgs: targetSpec.args });
          Object.assign(prepared.env, targetSpec.env);
          const run = supervise(prepared, ctx, selected.descriptor.name);
          return { content: [{ type: "text", text: `Started ${selected.descriptor.name} as ${run.manifest.runId}` }], details: {} };
        } catch (error) {
          return { content: [{ type: "text", text: error instanceof Error ? error.message : String(error) }], details: {}, isError: true };
        }
      }
      if (params.action === "restart" || params.action === "resume" || params.action === "fork") {
        if (!ctx.isProjectTrusted()) return toolRefusal(`${params.action} requires a trusted project`);
        if (!ctx.hasUI) return toolRefusal(uiRequiredText(params.action));
        if (!params.parentRunId) return toolRefusal(`${params.action} requires parentRunId`);
        try {
          const edits = params.action === "fork" ? parseLineageEdits(params.forkEditsJson) : [];
          const run = await launchLineage(params.action, params.parentRunId, ctx, { inputs: parseInputsJson(params.inputsJson), edits });
          if (typeof run === "string") throw new Error(run);
          if (!run) throw new Error(`${params.action} was not launched`);
          return { content: [{ type: "text", text: `Started ${params.action} child ${run.manifest.runId}` }], details: {} };
        } catch (error) {
          return { content: [{ type: "text", text: error instanceof Error ? error.message : String(error) }], details: {}, isError: true };
        }
      }
      if (!params.runId) return toolRefusal(`${params.action} requires runId`);
      if (!ctx.isProjectTrusted()) return toolRefusal(`${params.action} requires a trusted project`);
      if (!ctx.hasUI) return toolRefusal(uiRequiredText(params.action));
      const run = supervisor.get(params.runId);
      if (!run) return toolRefusal(`Unknown run ${params.runId}`);
      const runId = params.runId;
      // Each control is sent only after the human confirms its exact kind,
      // run, occurrence, attempt, target and text.
      const confirmed = (kind: string, fields: ReadonlyArray<readonly [string, string]> = []) =>
        ctx.ui.confirm("Send workflow control?", [`kind=${kind}`, `run=${runId}`, ...fields.map(([name, value]) => `${name}=${value}`)].join("\n"));
      if (params.action === "redirect") {
        if (!params.occurrenceId || !params.target) return toolRefusal("redirect requires occurrenceId and target");
        if (!(await confirmed("redirect", [["occurrence", params.occurrenceId], ["target", JSON.stringify(params.target)]]))) return toolRefusal(declinedText("redirect control"));
        try {
          const ack = await run.redirect(params.occurrenceId, params.target);
          return controlToolResult("redirect", ack, run.snapshot, params.occurrenceId);
        } catch (error) {
          return { content: [{ type: "text", text: error instanceof Error ? error.message : String(error) }], details: {}, isError: true };
        }
      }
      if (params.action === "recover") {
        if (!params.occurrenceId || !params.recoveryChoice) return toolRefusal("recover requires occurrenceId and recoveryChoice");
        if (!(await confirmed(params.recoveryChoice, [["occurrence", params.occurrenceId]]))) return toolRefusal(declinedText(`${params.recoveryChoice} control`));
        try {
          return controlToolResult(params.recoveryChoice, await run.recover(params.occurrenceId, params.recoveryChoice));
        } catch (error) {
          return { content: [{ type: "text", text: error instanceof Error ? error.message : String(error) }], details: {}, isError: true };
        }
      }
      if (params.action === "retry") {
        if (!params.occurrenceId) return toolRefusal("retry requires occurrenceId");
        if (!(await confirmed("retry", [["occurrence", params.occurrenceId]]))) return toolRefusal(declinedText("retry control"));
        try {
          return controlToolResult("retry", await run.retry(params.occurrenceId));
        } catch (error) {
          return { content: [{ type: "text", text: error instanceof Error ? error.message : String(error) }], details: {}, isError: true };
        }
      }
      if (params.action === "steer") {
        if (!params.occurrenceId || !params.attemptId || !params.text || !params.timing) {
          return toolRefusal("steer requires occurrenceId, attemptId, text, and timing");
        }
        const steering = [["occurrence", params.occurrenceId], ["attempt", params.attemptId], ["timing", params.timing], ["text", JSON.stringify(params.text)]] as const;
        if (!(await confirmed("steer", steering))) return toolRefusal(declinedText("steer control"));
        try {
          return controlToolResult("steer", await run.steer(params.occurrenceId, params.attemptId, params.text, params.timing));
        } catch (error) {
          return { content: [{ type: "text", text: error instanceof Error ? error.message : String(error) }], details: {}, isError: true };
        }
      }
      if (!(await confirmed("cancel"))) return toolRefusal(declinedText("cancel control"));
      await run.cancel("cancelled by model tool");
      return { content: [{ type: "text", text: `Cancellation requested for ${params.runId}` }], details: {} };
    },
  });
}

/**
 * The parameters of the `agent_cat_workflow` tool. The schema leaves
 * additional properties open, and no parameter carries a credential, a
 * credential path or a client profile.
 */
const TOOL_PARAMETERS = Type.Object({
  action: Type.Union([
    Type.Literal("list"), Type.Literal("status"), Type.Literal("inspect"), Type.Literal("start"), Type.Literal("restart"), Type.Literal("resume"), Type.Literal("fork"),
    Type.Literal("cancel"), Type.Literal("steer"), Type.Literal("retry"), Type.Literal("recover"), Type.Literal("redirect"),
    Type.Literal("manager-list"), Type.Literal("manager-status"), Type.Literal("manager-inspect"), Type.Literal("manager-result"),
    Type.Literal("manager-start"), Type.Literal("manager-answer"), Type.Literal("manager-control"), Type.Literal("manager-lineage"), Type.Literal("manager-export"),
  ]),
  runId: Type.Optional(Type.String()),
  parentRunId: Type.Optional(Type.String()),
  workflow: Type.Optional(Type.String()),
  profileId: Type.Optional(Type.String()),
  inputsJson: Type.Optional(Type.String()),
  launchTarget: Type.Optional(Type.Union([Type.Literal("scripted"), Type.Literal("child"), Type.Literal("remote")])),
  forkEditsJson: Type.Optional(Type.String()),
  occurrenceId: Type.Optional(Type.String()),
  attemptId: Type.Optional(Type.String()),
  text: Type.Optional(Type.String()),
  answer: Type.Optional(Type.String()),
  timing: Type.Optional(Type.Union([Type.Literal("interrupt-now"), Type.Literal("next-boundary")])),
  recoveryChoice: Type.Optional(Type.Union([Type.Literal("retry"), Type.Literal("failover"), Type.Literal("abandon")])),
  controlKind: Type.Optional(Type.Union([
    Type.Literal("cancel"), Type.Literal("steer"), Type.Literal("retry"), Type.Literal("failover"), Type.Literal("abandon"), Type.Literal("redirect"),
  ])),
  lineageOperation: Type.Optional(Type.Union([Type.Literal("restart"), Type.Literal("resume"), Type.Literal("fork")])),
  target: Type.Optional(Type.String()),
  name: Type.Optional(Type.String()),
  path: Type.Optional(Type.String()),
});

type ToolParameters = Static<typeof TOOL_PARAMETERS>;

/**
 * One service action of the tool. Each action calls the function of the
 * matching human command of `ManagerRequests` with the values of the model,
 * so a tool action and a human command reach the same manager transitions.
 * A mutation first requires a trusted project and an interactive Pi UI, and
 * it refuses before any request without them. The function of the command
 * then asks for the human confirmation of the exact content. The
 * notifications of the command are the text of the result. They name no
 * bearer, no credential path and no client profile path.
 */
async function managerAction(requests: ManagerRequests, service: ServiceMode | undefined, params: ToolParameters, ctx: ExtensionContext) {
  const action = params.action;
  const read = ["manager-list", "manager-status", "manager-inspect"].includes(action) || (action === "manager-result" && params.path === undefined);
  if (action !== "manager-list" && action !== "manager-status" && !ctx.isProjectTrusted()) return toolRefusal(`${action} requires a trusted project`);
  if (!read && !ctx.hasUI) return toolRefusal(uiRequiredText(action));
  if (action === "manager-status") {
    if (service === undefined) return toolRefusal(SERVICE_UNCONFIGURED);
    return { content: [{ type: "text" as const, text: formatServiceStatus(service, requests.records(), false) }], details: {} };
  }
  const needs = (fields: ReadonlyArray<keyof ToolParameters>): string | undefined => {
    const missing = fields.filter((field) => params[field] === undefined);
    return missing.length === 0 ? undefined : `${action} requires ${missing.join(", ")}`;
  };
  const call = toolContext(ctx);
  const runId = params.runId ?? "";
  let reached: boolean;
  try {
    switch (action) {
      case "manager-list":
        reached = await requests.catalogue(call.ctx);
        break;
      case "manager-inspect": {
        const missing = needs(["runId"]);
        if (missing !== undefined) return toolRefusal(missing);
        reached = await requests.inspect(call.ctx, runId);
        break;
      }
      case "manager-result": {
        const missing = needs(["runId"]);
        if (missing !== undefined) return toolRefusal(missing);
        reached = await requests.result(call.ctx, runId, { path: params.path });
        break;
      }
      case "manager-start": {
        const missing = needs(["workflow"]);
        if (missing !== undefined) return toolRefusal(missing);
        reached = await requests.start(call.ctx, "", { workflow: params.workflow ?? "", profileId: params.profileId, inputs: parseInputsJson(params.inputsJson) });
        break;
      }
      case "manager-answer": {
        const missing = needs(["runId", "answer"]);
        if (missing !== undefined) return toolRefusal(missing);
        reached = await requests.answer(call.ctx, runId, { kind: "answer", text: params.answer ?? "" });
        break;
      }
      case "manager-control": {
        const missing = needs(["runId", "controlKind"]);
        if (missing !== undefined) return toolRefusal(missing);
        const kind = params.controlKind;
        if (kind === "cancel") reached = await requests.cancel(call.ctx, runId, true);
        else if (kind === "steer") {
          const absent = needs(["occurrenceId", "attemptId", "timing", "text"]);
          if (absent !== undefined) return toolRefusal(absent);
          reached = await requests.steer(call.ctx, runId,
            { occurrenceId: params.occurrenceId ?? "", attemptId: params.attemptId ?? "", timing: params.timing ?? "", text: params.text ?? "" });
        } else if (kind === "redirect") {
          const absent = needs(["occurrenceId", "target"]);
          if (absent !== undefined) return toolRefusal(absent);
          reached = await requests.redirect(call.ctx, runId, { occurrenceId: params.occurrenceId ?? "", target: params.target ?? "" });
        } else reached = await requests.answer(call.ctx, runId, { kind: "recovery", choice: kind ?? "retry", target: params.target });
        break;
      }
      case "manager-lineage": {
        const missing = needs(["runId", "lineageOperation"]);
        if (missing !== undefined) return toolRefusal(missing);
        reached = await requests.lineage(call.ctx, params.lineageOperation ?? "restart", runId, { edits: parseModelForkEdits(params.forkEditsJson) });
        break;
      }
      case "manager-export": {
        const missing = needs(["runId", "name"]);
        if (missing !== undefined) return toolRefusal(missing);
        reached = await requests.export(call.ctx, `${runId} ${params.name ?? ""}`, true);
        break;
      }
      default:
        return toolRefusal(`Unknown action ${action}`);
    }
  } catch (error) {
    return toolRefusal(error instanceof Error ? error.message : String(error));
  }
  const text = call.lines.join("\n") || `${action} gave no report.`;
  return { content: [{ type: "text" as const, text }], details: {}, ...(reached ? {} : { isError: true }) };
}

/**
 * The fork edits of a model for a manager run: a JSON array of
 * `{"type":"drop","occurrenceId":"N"}` and
 * `{"type":"replace","occurrenceId":"N","value":"TEXT"}`, where `TEXT` is
 * the answer text that the code of the occurrence types.
 */
function parseModelForkEdits(value: string | undefined): ModelForkEdit[] {
  if (!value) return [];
  let parsed: unknown;
  try { parsed = JSON.parse(value); } catch { throw new Error("forkEditsJson is not valid JSON"); }
  if (!Array.isArray(parsed)) throw new Error("forkEditsJson must be an array");
  return parsed.map((entry): ModelForkEdit => {
    if (typeof entry !== "object" || entry === null || Array.isArray(entry)) throw new Error("fork edit is not an object");
    const edit = entry as Record<string, unknown>;
    if ((edit.type !== "drop" && edit.type !== "replace") || typeof edit.occurrenceId !== "string" || !/^(0|[1-9][0-9]*)$/.test(edit.occurrenceId)) {
      throw new Error("fork edit requires type and decimal occurrenceId");
    }
    if (edit.type === "drop") return { type: "drop", occurrenceId: edit.occurrenceId };
    if (typeof edit.value !== "string") throw new Error("replacement fork edit requires value text");
    return { type: "replace", occurrenceId: edit.occurrenceId, value: edit.value };
  });
}

/** The inputs of a model: a JSON object of string values, exactly the declared inputs when a descriptor is given. */
function parseInputsJson(value: string | undefined, descriptor?: WorkflowDescriptor): Record<string, string> {
  let parsed: unknown = {};
  if (value) {
    try { parsed = JSON.parse(value); } catch { throw new Error("inputsJson is not valid JSON"); }
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed) || !Object.values(parsed).every((entry) => typeof entry === "string")) {
    throw new Error("inputsJson must be a JSON object of string values");
  }
  const inputs = parsed as Record<string, string>;
  if (descriptor) {
    const expected = descriptor.inputs.map(({ name }) => name).sort();
    const actual = Object.keys(inputs).sort();
    if (expected.length !== actual.length || expected.some((name, index) => name !== actual[index])) throw new Error(`inputs must be exactly: ${descriptor.inputs.map(({ name }) => name).join(", ") || "(none)"}`);
  }
  return inputs;
}

/** The label of each local execution target in the launch review. */
const TARGET_LABEL: Readonly<Record<TargetKind, string>> = {
  scripted: "scripted (offline, no commands)",
  routing: "routing configuration (live, full pin coverage)",
  acp: "native ACP adapter (live, agent-cat scratch)",
  deck: "native agent-deck session (live, external pane)",
  current: "current Pi session (live, current project, not sandboxed)",
  child: "owned Pi child (live, agent-cat scratch, no tools)",
  remote: "authenticated remote Pi session (live, remote workspace, not sandboxed)",
};

/** The containment of each local execution target in the launch review. */
const TARGET_CONTAINMENT: Readonly<Record<TargetKind, string>> = {
  scripted: "offline scripted table; no command execution",
  routing: "configured engines; full pin coverage required",
  acp: "agent-cat scratch directory; adapter is not an OS sandbox",
  deck: "external agent-deck pane/workspace; not a sandbox",
  current: "current Pi project workspace; not sandboxed",
  child: "agent-cat scratch directory; Pi tools disabled",
  remote: "authenticated remote Pi workspace; not sandboxed",
};

/** The target confirmation that a launch on a live Pi target shows before its launch review. */
const TARGET_CONFIRMATION = {
  child: ["Create owned Pi child?", "Workflow questions will use the default configured model and may incur provider charges. Tools are disabled."],
  remote: ["Use authenticated remote Pi session?", "This acquires an exclusive session lease and workflow questions may incur provider charges."],
} as const;

/** The exact values of the inputs, in the order of the descriptor, as review lines. */
function inputLines(descriptor: WorkflowDescriptor, inputs: Record<string, string>): string[] {
  return descriptor.inputs.filter(({ name }) => Object.hasOwn(inputs, name)).map(({ name }) => `input ${name}=${JSON.stringify(inputs[name])}`);
}

/**
 * The launch review of a local start. `/wf-launch` shows it before it
 * collects the inputs. The start action of the tool shows the same review
 * with the exact inputs of the model appended.
 */
function launchReview(review: {
  readonly runner: RunnerConfig;
  readonly descriptor: WorkflowDescriptor;
  readonly cwd: string;
  readonly targetKind: TargetKind;
  readonly routing?: string;
  readonly inputs?: Record<string, string>;
}): string {
  return [
    `runner=${review.runner.executable}`,
    `cwd=${review.cwd}`,
    `target=${TARGET_LABEL[review.targetKind]}`,
    `routing=${review.routing ?? "not used"}`,
    `containment=${TARGET_CONTAINMENT[review.targetKind]}`,
    `effects=${review.descriptor.capabilities.effects ?? "unknown"}`,
    "persistence=private full prompts/answers plus input hashes",
    ...(review.inputs ? inputLines(review.descriptor, review.inputs) : []),
  ].join("\n");
}

/** The exact review of a model-initiated lineage operation: the parent, the target, the inputs and the fork edits. */
function lineageReview(review: {
  readonly operation: "restart" | "resume" | "fork";
  readonly parentRunId: string;
  readonly runner: RunnerConfig;
  readonly descriptor: WorkflowDescriptor;
  readonly cwd: string;
  readonly targetKind: TargetKind;
  readonly targetArgs: readonly string[];
  readonly inputs: Record<string, string>;
  readonly edits: readonly LineageEdit[];
}): string {
  return [
    `operation=${review.operation}`,
    `parent=${review.parentRunId}`,
    `workflow=${review.runner.id}:${review.descriptor.name}`,
    `runner=${review.runner.executable}`,
    `cwd=${review.cwd}`,
    `target=${TARGET_LABEL[review.targetKind]}`,
    `target arguments=${JSON.stringify(review.targetArgs)}`,
    `containment=${TARGET_CONTAINMENT[review.targetKind]}`,
    `effects=${review.descriptor.capabilities.effects ?? "unknown"}`,
    ...inputLines(review.descriptor, review.inputs),
    ...review.edits.map((edit) => edit.type === "drop"
      ? `edit drop occurrence ${edit.occurrenceId}`
      : `edit replace occurrence ${edit.occurrenceId} value=${edit.value}`),
  ].join("\n");
}

function uiRequiredText(action: string): string {
  return `${action} requires an interactive Pi UI for the human confirmation of its exact review. Nothing was sent.`;
}

function declinedText(action: string): string {
  return `The human declined the ${action}. Nothing was sent.`;
}

function toolRefusal(text: string) {
  return { content: [{ type: "text" as const, text }], details: {}, isError: true };
}

const SERVICE_UNCONFIGURED = "Service mode is not configured. Set AGENT_CAT_MANAGER_PROFILE or AGENT_CAT_MANAGER_PROFILES.";

const SERVICE_TERMINAL = ["succeeded", "failed", "cancelled", "orphaned"];

/**
 * The connection line of the status. `paths` false names a profile by its
 * number instead of its path, as a tool result does.
 */
function connectionLine(service: ServiceMode, paths: boolean): string {
  const connection = service.connection;
  const profile = (path: string): string => paths ? path : `profile ${service.profiles.indexOf(path) + 1}`;
  switch (connection.kind) {
    case "connecting": return `Connection: connecting to ${profile(connection.profile)}`;
    case "connected":
      return `Connection: connected to ${connection.endpoint} (endpoint identity ${connection.identity}), delivery ${connection.delivery}`
        + (connection.overview === "loaded" ? "" : ", overview unavailable");
    case "refused": return `Connection: refused for ${profile(connection.profile)}: ${connection.reason}. No manager command is sent.`;
    case "unreachable": return `Connection: unreachable for ${profile(connection.profile)}: ${connection.reason}. No manager command is sent. /wfm-endpoints connects again.`;
    case "closed": return "Connection: closed. The manager keeps its runs under its own supervision.";
  }
}

/**
 * The text of `/wfm-status`: the profile, the connection, the capabilities,
 * the service observations, and the command records of the active binding.
 * The command records state command outcomes, and the observations state
 * execution, so the two are listed separately. With `paths` false, the
 * text names no client profile path, as the `manager-status` action of the
 * tool gives it to the model.
 */
export function formatServiceStatus(service: ServiceMode, commands: readonly CommandRecord[] = [], paths = true): string {
  const lines = [
    `Service mode: profile ${service.active + 1} of ${service.profiles.length}${paths ? `, ${service.profiles[service.active]}` : ""}`,
    connectionLine(service, paths),
  ];
  const capabilities = service.capabilities;
  if (capabilities !== undefined && service.connection.kind === "connected") lines.push(`Manager capabilities: ${capabilities}`);
  const runs = service.runs();
  const requests = service.requests();
  const decisions = service.decisions();
  lines.push(runs.length ? "Service runs:" : "Service runs: none");
  for (const run of runs) lines.push(`  ${run.runId}  ${run.status}  ${run.supervision ?? "unknown"} supervision  ${run.workflowId ?? "unreadable manifest"}`);
  lines.push(requests.length ? "Requests:" : "Requests: none");
  for (const request of requests) lines.push(`  ${request.requestId}  ${request.phase}  ${request.workflowId}${request.runId ? `  run ${request.runId}` : ""}`);
  lines.push(decisions.length ? "Decision heads:" : "Decision heads: none");
  for (const decision of decisions) lines.push(`  ${decision.decisionId}  ${decision.state} ${decision.kind}  run ${decision.runId}`);
  if (commands.length > 0) {
    lines.push("Command receipts:");
    for (const command of commands) lines.push(`  ${command.operation}  ${command.outcome}  ${command.detail}  ${command.target}`);
  }
  return lines.join("\n");
}

function notifySelection(ctx: ExtensionContext, selection: ServiceSelection): void {
  if (selection.kind === "closed") return;
  if (selection.kind === "kept") {
    return ctx.ui.notify(`Manager profile ${selection.profile} refused: ${selection.reason}. The earlier endpoint stays active.`, "error");
  }
  const connection = selection.connection;
  if (connection.kind === "connected") return ctx.ui.notify(`Manager connected: ${connection.endpoint}`, "info");
  if (connection.kind === "refused" || connection.kind === "unreachable") {
    return ctx.ui.notify(`Manager ${connection.kind}: ${connection.reason}`, connection.kind === "refused" ? "error" : "warning");
  }
}

function modeLine(mode: ClientMode): string {
  if (mode.kind === "local") return "Mode: local";
  return `Mode: service with ${mode.profiles.length} manager profile${mode.profiles.length === 1 ? "" : "s"}. Current-session, owned-child, deck, ACP, and remote Pi targets stay local.`;
}

function notifyControl(ctx: ExtensionContext, action: string, ack: ControlAckSnapshot, snapshot?: RunSnapshot, occurrenceId?: string): void {
  ctx.ui.notify(formatControl(action, ack, snapshot, occurrenceId), ack.state === "delivered" ? "info" : "error");
}

function controlToolResult(action: string, ack: ControlAckSnapshot, snapshot?: RunSnapshot, occurrenceId?: string) {
  return {
    content: [{ type: "text" as const, text: formatControl(action, ack, snapshot, occurrenceId) }],
    details: {},
    ...(ack.state === "delivered" ? {} : { isError: true }),
  };
}

async function discover(ctx: ExtensionContext): Promise<Array<{ runner: RunnerConfig; descriptor: WorkflowDescriptor }>> {
  const rows: Array<{ runner: RunnerConfig; descriptor: WorkflowDescriptor }> = [];
  for (const runner of configuredRunners(ctx.cwd)) {
    for (const descriptor of await discoverRunner(runner, ctx.cwd)) rows.push({ runner, descriptor });
  }
  return rows;
}

function selectWorkflow(rows: Array<{ runner: RunnerConfig; descriptor: WorkflowDescriptor }>, name: string) {
  return rows.find(({ runner, descriptor }) => name === `${runner.id}:${descriptor.name}` || name === descriptor.name);
}

type WorkflowCommand = { workflow?: string; commandTail?: string; body?: string };

export function parseWorkflowCommand(args: string): WorkflowCommand {
  const newline = args.indexOf("\n");
  const firstLine = (newline < 0 ? args : args.slice(0, newline)).replace(/\r$/, "").trimStart();
  const bodyText = newline < 0 ? "" : args.slice(newline + 1).trimStart();
  if (!firstLine.trim()) {
    if (bodyText) throw new Error("/wf multiline input requires a workflow name on the first line");
    return {};
  }
  const separator = firstLine.search(/[ \t]/);
  const workflow = separator < 0 ? firstLine : firstLine.slice(0, separator);
  const tailText = separator < 0 ? "" : firstLine.slice(separator).replace(/^[ \t]+/, "");
  return {
    workflow,
    ...(tailText.trim() ? { commandTail: tailText } : {}),
    ...(bodyText ? { body: bodyText } : {}),
  };
}

function bindWorkflowSources(descriptor: WorkflowDescriptor, invocation: WorkflowCommand): Record<string, string> {
  const inputs: Record<string, string> = {};
  const commandTail = descriptor.inputs.find(({ source }) => source === "command-tail");
  const stdin = descriptor.inputs.find(({ source }) => source === "stdin");
  if (invocation.commandTail !== undefined) {
    if (!commandTail) throw new Error(`workflow ${descriptor.name} has no command-tail input for first-line text`);
    inputs[commandTail.name] = invocation.commandTail;
  }
  if (invocation.body !== undefined) {
    if (!stdin) throw new Error(`workflow ${descriptor.name} has no standard-input declaration for multiline body`);
    inputs[stdin.name] = invocation.body;
  }
  return inputs;
}

async function collectInputs(ctx: ExtensionContext, descriptor: WorkflowDescriptor, supplied: Record<string, string> = {}): Promise<Record<string, string> | undefined> {
  const inputs: Record<string, string> = { ...supplied };
  for (const { name } of descriptor.inputs) {
    if (Object.prototype.hasOwnProperty.call(inputs, name)) continue;
    const value = await ctx.ui.editor(`Input: ${name}`);
    if (value === undefined) return undefined;
    inputs[name] = value;
  }
  return inputs;
}

export type RoutingLaunchSelection = { args: string[]; managedAxes: Set<string>; inspection?: RoutingInspection };

export async function collectRoutingSelection(
  ctx: ExtensionContext, runner: RunnerConfig, descriptor: WorkflowDescriptor,
): Promise<RoutingLaunchSelection | undefined> {
  if (!supportsRoutingInspection(descriptor)) return { args: [], managedAxes: new Set() };
  let inspection = await readRouting(runner, ctx.cwd);
  if (!inspection) return { args: [], managedAxes: new Set() };

  const configuredChoice = `configured (${inspection.persona.name})`;
  const personaChoices = [configuredChoice, ...inspection.availablePersonas.map((name) => `persona: ${name}`)];
  const personaChoice = await ctx.ui.select("Routing persona", personaChoices);
  if (!personaChoice) return undefined;
  const args: string[] = [...inspection.launch.arguments];
  if (personaChoice !== configuredChoice) {
    const persona = personaChoice.slice("persona: ".length);
    args.push("--persona", persona);
    if (persona !== inspection.persona.name) {
      const selected = await readRouting(runner, ctx.cwd, { persona });
      if (!selected) throw new Error("runner lost version-2 routing while selecting a persona");
      inspection = selected;
    }
  }

  const managedRungs = inspection.profiles
    .filter(({ name }) => descriptor.pins.includes(name))
    .flatMap(({ rungs }) => rungs);
  if (managedRungs.length > 0 && await ctx.ui.confirm("Override routed models?", "Optional model aliases; configured choices preserve the resolved persona profile.")) {
    for (const rung of managedRungs) {
      const configured = `configured (${rung.modelAlias})`;
      const choice = await ctx.ui.select(`Model alias for ${rung.axis}`, [configured, ...inspection.availableModels.map(({ alias }) => alias)]);
      if (!choice) return undefined;
      if (choice !== configured) args.push("--realize", `${rung.axis}=${choice}`);
    }
  }
  args.push("--offline", "--expect-routing-fingerprint", inspection.launch.fingerprint);
  return { args, managedAxes: new Set(managedRungs.map(({ axis }) => axis)), inspection };
}


async function collectRoutes(ctx: ExtensionContext, pins: string[]): Promise<string[] | undefined> {
  if (pins.length === 0 || !(await ctx.ui.confirm("Configure pin routes?", `Optional pins: ${pins.join(", ")}`))) return [];
  const args: string[] = [];
  for (const pin of pins) {
    const route = await ctx.ui.input(`Backend for ${pin} (blank uses default; otherwise acp:NAME or deck:ID)`);
    if (route === undefined) return undefined;
    const backend = route.trim();
    if (!backend) continue;
    const colon = backend.indexOf(":");
    const scheme = colon < 0 ? "" : backend.slice(0, colon);
    const target = colon < 0 ? "" : backend.slice(colon + 1);
    if ((scheme !== "acp" && scheme !== "deck") || !target.trim()) throw new Error(`Invalid route backend ${backend}`);
    args.push("--route", `${pin}=${backend}`);
  }
  return args;
}

function parseStringArray(value: string, label: string): string[] {
  let parsed: unknown;
  try { parsed = JSON.parse(value); } catch { throw new Error(`${label} is not valid JSON`); }
  if (!Array.isArray(parsed) || !parsed.every((entry) => typeof entry === "string")) throw new Error(`${label} must be a JSON string array`);
  return parsed;
}


function ownedChildTarget(): { args: string[]; env: NodeJS.ProcessEnv } {
  const adapter = fileURLToPath(new URL("./pi-child-acp.mjs", import.meta.url));
  return { args: ["--engine", "acp", "--adapter", process.execPath, "--adapter-arg", adapter], env: {} };
}

export async function selectRemoteTarget(ctx: ExtensionContext, remote: { socket: string; sessionId?: string }): Promise<{ args: string[]; env: NodeJS.ProcessEnv } | undefined> {
  if (remote.sessionId) return knownRemoteTarget({ socket: remote.socket, sessionId: remote.sessionId });
  const connection = await openRemotePi(remote.socket);
  try {
    const sessions = connection.listSessions();
    if (sessions.length === 0) { ctx.ui.notify("The authenticated Pi server reported no sessions", "warning"); return undefined; }
    const choices = sessions.map((session) => session.sessionId);
    const selected = await ctx.ui.select("Authenticated remote Pi session", choices);
    if (!selected) return undefined;
    return knownRemoteTarget({ socket: remote.socket, sessionId: sessions[choices.indexOf(selected)].sessionId });
  } finally {
    await connection.dispose();
  }
}

function knownRemoteTarget(remote: { socket: string; sessionId: string }): { args: string[]; env: NodeJS.ProcessEnv } {
  const adapter = fileURLToPath(new URL("./pi-remote-acp.mjs", import.meta.url));
  return {
    args: ["--engine", "acp", "--adapter", process.execPath, "--adapter-arg", adapter],
    env: { AGENT_CAT_PI_REMOTE_SOCKET: remote.socket, AGENT_CAT_PI_REMOTE_SESSION: remote.sessionId },
  };
}


/**
 * The status line and the widget of the extension. Local runs and service
 * runs have separate sections, and only active runs are listed.
 */
function updateWidget(ctx: ExtensionContext, supervisor: RunSupervisor, service: ServiceMode | undefined): void {
  const snapshots = supervisor.activeSnapshots();
  const remote = service?.runs().filter((run) => !SERVICE_TERMINAL.includes(run.status)) ?? [];
  const counts = [
    snapshots.length ? `${snapshots.length} active workflow${snapshots.length === 1 ? "" : "s"}` : undefined,
    remote.length ? `${remote.length} service run${remote.length === 1 ? "" : "s"}` : undefined,
  ].filter((part): part is string => part !== undefined);
  ctx.ui.setStatus("agent-cat", counts.length ? counts.join(", ") : undefined);
  if (snapshots.length === 0 && remote.length === 0) return ctx.ui.setWidget("agent-cat-runs", undefined);
  const connection = service?.connection;
  const endpoint = connection?.kind === "connected" ? connection.endpoint : "manager";
  ctx.ui.setWidget("agent-cat-runs", (_tui, theme) => new Text([
    ...(snapshots.length ? [theme.fg("muted", "Local runs")] : []),
    ...snapshots.map((run) => `${theme.fg(run.status === "failed" ? "error" : "accent", run.status)} ${run.runId} ${run.workflow ?? "starting"}`),
    ...(remote.length ? [theme.fg("muted", `Service runs (${endpoint})`)] : []),
    ...remote.map((run) => `${theme.fg("accent", run.status)} ${run.runId} ${run.workflowId ?? "unreadable manifest"}`),
  ].join("\n"), 0, 0));
}
