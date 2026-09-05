import { join } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Text } from "@earendil-works/pi-tui";
import { Type } from "typebox";
import { discoverRunner, readHelp, readRouting, supportsRoutingInspection } from "./catalogue.ts";
import { configuredRemote, configuredRunners, retentionPolicy, stateDirectory } from "./config.ts";
import { CurrentSessionBridge } from "./current-bridge.ts";
import { MutationGrants, type GrantScope } from "./grants.ts";
import { assertNoCredentialArgs, prepareLaunch, preflightLineage, previewPlan, type LineageEdit, type PreparedLaunch } from "./launch.ts";
import { formatMonitor } from "./monitor.ts";
import { WorkflowMonitorComponent } from "./monitor-ui.ts";
import { openRemotePi } from "./pi-remote-runtime.mjs";
import { RunSupervisor } from "./supervisor.ts";
import type { ControlAckSnapshot, RoutingInspection, RunnerConfig, RunSnapshot, TargetKind, WorkflowDescriptor } from "./types.ts";

export default function agentCatExtension(pi: ExtensionAPI): void {
  const supervisor = new RunSupervisor();
  let lastContext: ExtensionContext | undefined;
  const currentBridge = new CurrentSessionBridge(pi, () => lastContext);
  const grants = new MutationGrants();
  const supervise = (prepared: PreparedLaunch, ctx: ExtensionContext, workflow: string) => {
    const run = supervisor.start(prepared);
    let recorded = false;
    run.subscribe((snapshot) => {
      updateWidget(ctx, supervisor);
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

  const launchLineage = async (operation: "restart" | "resume" | "fork", parentRunId: string, ctx: ExtensionContext, suppliedInputs?: Record<string, string>, suppliedEdits?: LineageEdit[]) => {
    if (!ctx.isProjectTrusted()) return ctx.ui.notify(`${operation} requires a trusted project`, "error");
    if (!suppliedInputs && !ctx.hasUI) return ctx.ui.notify(`${operation} requires interactive approval`, "error");
    const parent = supervisor.get(parentRunId);
    if (!parent) return ctx.ui.notify(`Unknown parent run ${parentRunId}`, "error");
    if (!["succeeded", "failed", "cancelled", "orphaned"].includes(parent.snapshot.status)) {
      return ctx.ui.notify("Lineage operations require a terminal or orphaned parent run", "error");
    }
    const selected = (await discover(ctx)).find(
      ({ runner, descriptor }) => runner.id === parent.manifest.runnerId && descriptor.name === parent.manifest.workflow,
    );
    if (!selected) return ctx.ui.notify("The parent workflow runner is no longer configured", "error");
    let inputs = suppliedInputs;
    if (!inputs) {
      if (!(await ctx.ui.confirm(`${operation} workflow run?`, `${operation} creates a new workflow run and never mutates the parent. Inputs will be collected again.`))) return;
      inputs = await collectInputs(ctx, selected.descriptor);
      if (!inputs) return;
    }
    let edits = suppliedEdits ?? [];
    if (operation === "fork" && suppliedEdits === undefined) {
      const collected = await collectForkEdits(ctx, parent.snapshot);
      if (collected === undefined) return;
      edits = collected;
    }
    const remote = configuredRemote();
    const targetKind = parent.manifest.targetKind;
    let targetSpec: { args: string[]; env: NodeJS.ProcessEnv } | undefined;
    if (targetKind === "current") {
      if (!currentBridge.supported) return ctx.ui.notify("Current-session lineage requires Pi ExtensionAPI.startTaskTurn", "error");
      if (currentBridge.busy) return ctx.ui.notify("The current Pi session is already assigned to a workflow", "error");
      targetSpec = currentBridge.target();
    } else if (targetKind === "child") targetSpec = ownedChildTarget();
    else if (targetKind === "remote") targetSpec = remote ? await selectRemoteTarget(ctx, remote) : undefined;
    else targetSpec = { args: [...parent.manifest.targetArgs], env: {} };
    if (!targetSpec) return ctx.ui.notify("The parent's remote target is no longer configured", "error");
    if (targetKind === "current" || targetKind === "child" || targetKind === "remote") {
      targetSpec = { ...targetSpec, args: [...targetSpec.args, ...routingLineageArgs(parent.manifest.targetArgs)] };
    }
    const stateDir = stateDirectory();
    const parentRuntimeDir = join(parent.storeDir, "runtime");
    try {
      await preflightLineage({ runner: selected.runner, descriptor: selected.descriptor, cwd: ctx.cwd, stateDir, inputs, targetArgs: targetSpec.args, operation, parentRuntimeDir, edits });
    } catch (error) {
      return ctx.ui.notify(error instanceof Error ? error.message : String(error), "error");
    }
    const prepared = await prepareLaunch({
      runner: selected.runner,
      descriptor: selected.descriptor,
      cwd: ctx.cwd,
      stateDir,
      inputs,
      targetKind,
      targetArgs: targetSpec.args,
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
    await currentBridge.start(stateDirectory());
    await supervisor.restore(stateDirectory(), retentionPolicy());
    updateWidget(ctx, supervisor);
  });
  pi.on("input", async (event, ctx) => {
    if (currentBridge.busy && event.source !== "extension") {
      ctx.ui.notify("The current session is exclusively assigned to an agent-cat workflow; cancel that run before sending another prompt", "warning");
      return { action: "handled" };
    }
    return { action: "continue" };
  });
  pi.on("session_shutdown", async () => {
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
      let routingSelection: RoutingLaunchSelection;
      try {
        const configured = await collectRoutingSelection(ctx, selected.runner, selected.descriptor);
        if (!configured) return;
        routingSelection = configured;
      } catch (error) {
        ctx.ui.notify(error instanceof Error ? error.message : String(error), "error");
        return;
      }
      let supplied: Record<string, string>;
      try { supplied = bindWorkflowSources(selected.descriptor, invocation); }
      catch (error) { return ctx.ui.notify(error instanceof Error ? error.message : String(error), "error"); }
      const inputs = await collectInputs(ctx, selected.descriptor, supplied);
      if (!inputs) return;
      const sourceSummary = Object.entries(supplied).map(([name, value]) => `${name}=${Buffer.byteLength(value)}B`).join(", ") || "none";
      if (!(await ctx.ui.confirm(
        `workflow=${selected.runner.id}:${selected.descriptor.name}\nrunner=${selected.runner.executable}\ncwd=${ctx.cwd}\ntarget=current Agent Deck session (${sessionId}); external pane/workspace, not sandboxed\nrouting=${routingSelection.inspection?.persona.name ?? "runner default"}\nprebound inputs=${sourceSummary}\neffects=${selected.descriptor.capabilities.effects ?? "unknown"}\nmay call a paid model; persistence=private full prompts/answers plus input hashes`,
        `workflow=${selected.runner.id}:${selected.descriptor.name}\nrunner=${selected.runner.executable}\ncwd=${ctx.cwd}\ntarget=current Agent Deck session (${sessionId}); external pane/workspace, not sandboxed\nprebound inputs=${sourceSummary}\neffects=${selected.descriptor.capabilities.effects ?? "unknown"}\nmay call a paid model; persistence=private full prompts/answers plus input hashes`,
      ))) return;
      const prepared = await prepareLaunch({
        runner: selected.runner,
        descriptor: selected.descriptor,
        cwd: ctx.cwd,
        stateDir: stateDirectory(),
        inputs,
        targetKind: "deck",
        targetArgs: ["--session", sessionId, ...routingSelection.args],
      });
      supervise(prepared, ctx, selected.descriptor.name);
    },
  });

  pi.registerCommand("workflow-help", {
    description: "Show exact runner help for an agent-cat workflow",
    handler: async (args, ctx) => {
      const selected = selectWorkflow(await discover(ctx), args.trim());
      if (!selected) return ctx.ui.notify(`Unknown workflow: ${args.trim()}`, "error");
      ctx.ui.notify(await readHelp(selected.runner, selected.descriptor.name, ctx.cwd), "info");
    },
  });

  pi.registerCommand("workflow-plan", {
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

  pi.registerCommand("workflow", {
    description: "Run an agent-cat workflow",
    getArgumentCompletions: async (prefix) => {
      if (!lastContext) return null;
      const catalogue = await discover(lastContext);
      const items = catalogue
        .map(({ runner, descriptor }) => ({ value: `${runner.id}:${descriptor.name}`, label: `${runner.id}:${descriptor.name}`, description: descriptor.blurb }))
        .filter((item) => item.value.startsWith(prefix));
      return items.length ? items : null;
    },
    handler: async (args, ctx) => {
      if (!ctx.hasUI) return ctx.ui.notify("/workflow requires interactive approval and is unavailable in this mode", "error");
      if (!ctx.isProjectTrusted()) return ctx.ui.notify("/workflow requires a trusted project", "error");
      const catalogue = await discover(ctx);
      const selected = selectWorkflow(catalogue, args.trim());
      if (!selected) return ctx.ui.notify(`Unknown workflow: ${args.trim()}`, "error");
      const remote = configuredRemote();
      const targets = [
        "scripted (offline, no commands)",
        "native ACP adapter (live, agent-cat scratch)",
        "native agent-deck session (live, external pane)",
      ];
      if (currentBridge.supported) targets.push("current Pi session (live, current project, not sandboxed)");
      targets.push("owned Pi child (live, agent-cat scratch, no tools)");
      if (remote) targets.push("authenticated remote Pi session (live, remote workspace, not sandboxed)");
      const target = await ctx.ui.select("Execution target", targets);
      if (!target) return;
      let routingSelection: RoutingLaunchSelection;
      if (target.startsWith("scripted")) {
        routingSelection = { args: [], managedAxes: new Set() };
      } else {
        try {
          const configured = await collectRoutingSelection(ctx, selected.runner, selected.descriptor);
          if (!configured) return;
          routingSelection = configured;
        } catch (error) {
          ctx.ui.notify(error instanceof Error ? error.message : String(error), "error");
          return;
        }
      }
      let targetKind: TargetKind = "scripted";
      let targetSpec: { args: string[]; env: NodeJS.ProcessEnv };
      if (target.startsWith("native ACP")) {
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
        if (!(await ctx.ui.confirm("Create owned Pi child?", "Workflow questions will use the default configured model and may incur provider charges. Tools are disabled."))) return;
        targetSpec = ownedChildTarget();
      } else if (target.startsWith("authenticated remote")) {
        targetKind = "remote";
        if (!remote) throw new Error("remote target disappeared");
        const remoteTarget = await selectRemoteTarget(ctx, remote);
        if (!remoteTarget) return;
        if (!(await ctx.ui.confirm("Use authenticated remote Pi session?", "This acquires an exclusive session lease and workflow questions may incur provider charges."))) return;
        targetSpec = remoteTarget;
      } else {
        targetSpec = { args: ["--scripted"], env: {} };
      }
      if (routingSelection.args.length > 0) targetSpec = { ...targetSpec, args: [...targetSpec.args, ...routingSelection.args] };
      const containment = target.startsWith("owned")
        ? "agent-cat scratch directory; Pi tools disabled"
        : target.startsWith("native ACP")
          ? "agent-cat scratch directory; adapter is not an OS sandbox"
          : target.startsWith("native agent-deck")
            ? "external agent-deck pane/workspace; not a sandbox"
            : target.startsWith("current")
              ? "current Pi project workspace; not a sandbox"
              : target.startsWith("authenticated remote")
                ? "authenticated remote Pi workspace; not a sandbox"
                : "offline scripted table; no command execution";
      if (!(await ctx.ui.confirm("Launch agent-cat workflow?", `runner=${selected.runner.executable}\ncwd=${ctx.cwd}\ntarget=${target}\nrouting=${routingSelection.inspection?.persona.name ?? "runner default"}\ncontainment=${containment}\neffects=${selected.descriptor.capabilities.effects ?? "unknown"}\npersistence=private full prompts/answers plus input hashes`))) return;
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
      });
      Object.assign(prepared.env, targetSpec.env);
      supervise(prepared, ctx, selected.descriptor.name);
    },
  });

  for (const operation of ["restart", "resume", "fork"] as const) {
    pi.registerCommand(`workflow-${operation}`, {
      description: `${operation} an agent-cat workflow as a new immutable child run`,
      handler: async (args, ctx) => {
        const parentRunId = args.trim();
        if (!parentRunId) return ctx.ui.notify(`Usage: /workflow-${operation} PARENT_RUN_ID`, "warning");
        await launchLineage(operation, parentRunId, ctx);
      },
    });
  }

  pi.registerCommand("workflow-diff", {
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

  pi.registerCommand("workflow-status", {
    description: "Show recent agent-cat workflow runs",
    handler: async (_args, ctx) => {
      const rows = supervisor.snapshots().map((snapshot) => `${snapshot.runId}  ${snapshot.status}  ${snapshot.workflow ?? "starting"}`);
      ctx.ui.notify(rows.join("\n") || "No active workflow runs", "info");
    },
  });

  pi.registerCommand("workflow-monitor", {
    description: "Inspect one active or recent agent-cat workflow run",
    handler: async (args, ctx) => {
      let runId = args.trim();
      if (!runId) {
        if (!ctx.hasUI) return ctx.ui.notify("Usage: /workflow-monitor RUN_ID", "warning");
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

  pi.registerCommand("workflow-steer", {
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

  pi.registerCommand("workflow-retry", {
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

  pi.registerCommand("workflow-recover", {
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

  pi.registerCommand("workflow-redirect", {
    description: "Redirect one dispatch-pending occurrence to a reserved target",
    handler: async (args, ctx) => {
      if (!ctx.hasUI) return ctx.ui.notify("workflow redirect requires interactive approval", "error");
      if (!ctx.isProjectTrusted()) return ctx.ui.notify("workflow redirect requires a trusted project", "error");
      const [runId, occurrenceId, target] = args.trim().split(/\s+/, 3);
      if (!runId || !occurrenceId || !target) return ctx.ui.notify("Usage: /workflow-redirect RUN_ID OCCURRENCE_ID RESERVED_TARGET", "warning");
      const run = supervisor.get(runId);
      if (!run) return ctx.ui.notify(`Unknown run ${runId}`, "error");
      try {
        notifyControl(ctx, "redirect", await run.redirect(occurrenceId, target));
      } catch (error) {
        ctx.ui.notify(error instanceof Error ? error.message : String(error), "error");
      }
    },
  });

  pi.registerCommand("workflow-cancel", {
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

function grantError(scope: string) {
  return { content: [{ type: "text" as const, text: `${scope} requires an unused matching grantId from /workflow-grant` }], details: {}, isError: true };
}

  pi.registerCommand("workflow-grant", {
    description: "Issue a one-time scoped grant for model-initiated workflow mutation",
    handler: async (_args, ctx) => {
      if (!ctx.hasUI) return ctx.ui.notify("grant issuance requires interactive UI", "error");
      if (!ctx.isProjectTrusted()) return ctx.ui.notify("grant issuance requires a trusted project", "error");
      const scope = await ctx.ui.select("One-time model grant", ["start", "lineage", "control", "all"] as const);
      if (scope !== "start" && scope !== "lineage" && scope !== "control" && scope !== "all") return;
      if (!(await ctx.ui.confirm("Issue one-time workflow grant?", `scope=${scope}; expires in 10 minutes and is consumed on first use`))) return;
      const grantId = grants.issue(scope as GrantScope);
      ctx.ui.notify(`One-time ${scope} grant: ${grantId}`, "info");
    },
  });

  pi.registerTool({
    name: "agent_cat_workflow",
    label: "agent-cat workflow",
    description: "Discover, launch, inspect, control, restart, resume, or fork agent-cat workflows. Every model-initiated mutation requires a one-time /workflow-grant token.",
    parameters: Type.Object({
      action: Type.Union([
        Type.Literal("list"), Type.Literal("status"), Type.Literal("inspect"), Type.Literal("start"), Type.Literal("restart"), Type.Literal("resume"), Type.Literal("fork"),
        Type.Literal("cancel"), Type.Literal("steer"), Type.Literal("retry"), Type.Literal("recover"), Type.Literal("redirect"),
      ]),
      runId: Type.Optional(Type.String()),
      parentRunId: Type.Optional(Type.String()),
      workflow: Type.Optional(Type.String()),
      inputsJson: Type.Optional(Type.String()),
      launchTarget: Type.Optional(Type.Union([Type.Literal("scripted"), Type.Literal("child"), Type.Literal("remote")])),
      grantId: Type.Optional(Type.String()),
      forkEditsJson: Type.Optional(Type.String()),
      occurrenceId: Type.Optional(Type.String()),
      attemptId: Type.Optional(Type.String()),
      text: Type.Optional(Type.String()),
      timing: Type.Optional(Type.Union([Type.Literal("interrupt-now"), Type.Literal("next-boundary")])),
      recoveryChoice: Type.Optional(Type.Union([Type.Literal("retry"), Type.Literal("failover"), Type.Literal("abandon")])),
      target: Type.Optional(Type.String()),
    }),
    async execute(_toolCallId, params, _signal, _onUpdate, ctx) {
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
        if (!ctx.isProjectTrusted()) return { content: [{ type: "text", text: "start requires a trusted project" }], details: {}, isError: true };
        if (!grants.consume(params.grantId, "start")) return grantError("start");
        if (!params.workflow) return { content: [{ type: "text", text: "start requires workflow" }], details: {}, isError: true };
        try {
          const selected = selectWorkflow(await discover(ctx), params.workflow);
          if (!selected) throw new Error(`Unknown workflow: ${params.workflow}`);
          const inputs = parseInputsJson(params.inputsJson, selected.descriptor);
          const launchTarget = params.launchTarget ?? "scripted";
          const targetKind: TargetKind = launchTarget === "child" ? "child" : launchTarget === "remote" ? "remote" : "scripted";
          let targetSpec: { args: string[]; env: NodeJS.ProcessEnv };
          if (launchTarget === "child") {
            if (selected.descriptor.capabilities.effectful === true) throw new Error("tool-free child target refuses effectful workflow");
            targetSpec = ownedChildTarget();
          } else if (launchTarget === "remote") {
            const remote = configuredRemote();
            if (!remote) throw new Error("remote target is not configured");
            const selectedRemote = await selectRemoteTarget(ctx, remote);
            if (!selectedRemote) throw new Error("no remote session selected");
            targetSpec = selectedRemote;
          } else targetSpec = { args: ["--scripted"], env: {} };
          const prepared = await prepareLaunch({ runner: selected.runner, descriptor: selected.descriptor, cwd: ctx.cwd, stateDir: stateDirectory(), inputs, targetKind, targetArgs: targetSpec.args });
          Object.assign(prepared.env, targetSpec.env);
          const run = supervise(prepared, ctx, selected.descriptor.name);
          return { content: [{ type: "text", text: `Started ${selected.descriptor.name} as ${run.manifest.runId}` }], details: {} };
        } catch (error) {
          return { content: [{ type: "text", text: error instanceof Error ? error.message : String(error) }], details: {}, isError: true };
        }
      }
      if (params.action === "restart" || params.action === "resume" || params.action === "fork") {
        if (!ctx.isProjectTrusted()) return { content: [{ type: "text", text: `${params.action} requires a trusted project` }], details: {}, isError: true };
        if (!grants.consume(params.grantId, "lineage")) return grantError("lineage");
        if (!params.parentRunId) return { content: [{ type: "text", text: `${params.action} requires parentRunId` }], details: {}, isError: true };
        try {
          const edits = params.action === "fork" ? parseLineageEdits(params.forkEditsJson) : [];
          const run = await launchLineage(params.action, params.parentRunId, ctx, parseInputsJson(params.inputsJson), edits);
          if (!run) throw new Error(`${params.action} was not launched`);
          return { content: [{ type: "text", text: `Started ${params.action} child ${run.manifest.runId}` }], details: {} };
        } catch (error) {
          return { content: [{ type: "text", text: error instanceof Error ? error.message : String(error) }], details: {}, isError: true };
        }
      }
      if (!params.runId) return { content: [{ type: "text", text: `${params.action} requires runId` }], details: {}, isError: true };
      if (!ctx.isProjectTrusted()) return { content: [{ type: "text", text: `${params.action} requires a trusted project` }], details: {}, isError: true };
      const run = supervisor.get(params.runId);
      if (!run) return { content: [{ type: "text", text: `Unknown run ${params.runId}` }], details: {}, isError: true };
      if (!grants.consume(params.grantId, "control")) return grantError("control");
      if (params.action === "redirect") {
        if (!params.occurrenceId || !params.target) return { content: [{ type: "text", text: "redirect requires occurrenceId and target" }], details: {}, isError: true };
        try {
          return controlToolResult("redirect", await run.redirect(params.occurrenceId, params.target));
        } catch (error) {
          return { content: [{ type: "text", text: error instanceof Error ? error.message : String(error) }], details: {}, isError: true };
        }
      }
      if (params.action === "recover") {
        if (!params.occurrenceId || !params.recoveryChoice) return { content: [{ type: "text", text: "recover requires occurrenceId and recoveryChoice" }], details: {}, isError: true };
        try {
          return controlToolResult(params.recoveryChoice, await run.recover(params.occurrenceId, params.recoveryChoice));
        } catch (error) {
          return { content: [{ type: "text", text: error instanceof Error ? error.message : String(error) }], details: {}, isError: true };
        }
      }
      if (params.action === "retry") {
        if (!params.occurrenceId) return { content: [{ type: "text", text: "retry requires occurrenceId" }], details: {}, isError: true };
        try {
          return controlToolResult("retry", await run.retry(params.occurrenceId));
        } catch (error) {
          return { content: [{ type: "text", text: error instanceof Error ? error.message : String(error) }], details: {}, isError: true };
        }
      }
      if (params.action === "steer") {
        if (!params.occurrenceId || !params.attemptId || !params.text || !params.timing) {
          return { content: [{ type: "text", text: "steer requires occurrenceId, attemptId, text, and timing" }], details: {}, isError: true };
        }
        try {
          return controlToolResult("steer", await run.steer(params.occurrenceId, params.attemptId, params.text, params.timing));
        } catch (error) {
          return { content: [{ type: "text", text: error instanceof Error ? error.message : String(error) }], details: {}, isError: true };
        }
      }
      await run.cancel("cancelled by model tool");
      return { content: [{ type: "text", text: `Cancellation requested for ${params.runId}` }], details: {} };
    },
  });
}

function notifyControl(ctx: ExtensionContext, action: string, ack: ControlAckSnapshot): void {
  ctx.ui.notify(`${action} ${ack.state} (${ack.controlId}): ${ack.message}`, ack.state === "delivered" ? "info" : "error");
}

function controlToolResult(action: string, ack: ControlAckSnapshot) {
  return {
    content: [{ type: "text" as const, text: `${action} ${ack.state} (${ack.controlId}): ${ack.message}` }],
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
  const args: string[] = [];
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

export function routingLineageArgs(args: string[]): string[] {
  // collectRoutingSelection appends these pairs after all target-specific arguments.
  const inherited: string[] = [];
  for (let end = args.length; end >= 2; end -= 2) {
    const flag = args[end - 2];
    if (flag !== "--persona" && flag !== "--realize") break;
    inherited.unshift(flag, args[end - 1]);
  }
  return inherited;
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


function updateWidget(ctx: ExtensionContext, supervisor: RunSupervisor): void {
  const snapshots = supervisor.activeSnapshots();
  ctx.ui.setStatus("agent-cat", snapshots.length ? `${snapshots.length} active workflow${snapshots.length === 1 ? "" : "s"}` : undefined);
  if (snapshots.length === 0) return ctx.ui.setWidget("agent-cat-runs", undefined);
  ctx.ui.setWidget("agent-cat-runs", (_tui, theme) => new Text(snapshots.map((run) => `${theme.fg(run.status === "failed" ? "error" : "accent", run.status)} ${run.runId} ${run.workflow ?? "starting"}`).join("\n"), 0, 0));
}
