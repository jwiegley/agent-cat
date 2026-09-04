export type RunnerConfig = {
  id: string;
  executable: string;
  prefixArgs?: string[];
  allowedCwds: string[];
};

export type WorkflowInputSource = "prompt" | "command-tail" | "stdin";

export type WorkflowInput = {
  name: string;
  source: WorkflowInputSource;
};

export type WorkflowDescriptor = {
  runnerId: string;
  name: string;
  blurb: string;
  level: string;
  size: number;
  askNodes: number;
  minFold: number | null;
  maxFold: number | null;
  paths: number;
  inputs: WorkflowInput[];
  runFacts: string[];
  pins: string[];
  descriptorVersion: number;
  runnerVersion: string;
  protocolVersions: number[];
  storeVersions: number[];
  capabilities: Record<string, boolean | number>;
};

export type RoutingModelChoice = { alias: string; engine: string };

export type RoutingInspection = {
  version: 2;
  persona: { name: string; source: string };
  availablePersonas: string[];
  availableModels: RoutingModelChoice[];
  profiles: Array<{ name: string; rungs: Array<{ axis: string; modelAlias: string; model: string }> }>;
  warnings: string[];
  raw: Record<string, unknown>;
};

export type RuntimeEvent = {
  protocolVersion: number;
  runId: string;
  sequence: string;
  timestamp: string;
  event: { type: string; [key: string]: unknown };
};

export type AttemptSnapshot = {
  id: string;
  target?: string;
  state: "running" | "completed" | "failed";
  output: string;
  steers: Array<{ controlId: string; timing: string; text: string }>;
  failure?: string;
  failureClass?: string;
};

export type OccurrenceSnapshot = {
  id: string;
  state: "running" | "recovering" | "reused" | "completed" | "failed" | "cancelled";
  code?: string;
  intent?: string;
  addressee?: string;
  prompt?: string;
  answer?: string;
  dispatch?: { targets: string[]; open: boolean; redirect?: { controlId: string; target: string } };
  recovery?: {
    gap: string;
    message: string;
    retries: string[];
    choices: Array<{ choice: "retry" | "failover" | "abandon"; target?: string }>;
    chosen?: { controlId: string; choice: "retry" | "failover" | "abandon"; target?: string };
  };
  reuseKind?: string;
  source?: string;
  failureClass?: string;
  replayable: boolean;
  attempts: Map<string, AttemptSnapshot>;
};

export type RunStatus = "starting" | "running" | "cancelling" | "succeeded" | "failed" | "cancelled" | "orphaned";

export type ControlAckSnapshot = { controlId: string; state: string; message: string };

export type RunSnapshot = {
  runId: string;
  status: RunStatus;
  lastSequence?: bigint;
  sequenceGap?: string;
  workflow?: string;
  target?: string;
  occurrences: Map<string, OccurrenceSnapshot>;
  authoredOrder: string[];
  traceRecorded: boolean;
  eventDigests: Map<string, string>;
  controlAcks: Map<string, ControlAckSnapshot>;
  billFresh?: string;
  billMemo?: string;
  failure?: string;
  failureClass?: string;
};

export type TargetKind = "scripted" | "acp" | "deck" | "current" | "child" | "remote";

export type LaunchManifest = {
  runId: string;
  runnerId: string;
  workflow: string;
  cwd: string;
  targetKind: TargetKind;
  targetArgs: string[];
  inputHashes: Record<string, string>;
  programHash: string;
  createdAt: string;
  parentRunId?: string;
  lineage?: "restart" | "resume" | "fork";
  lineageEdits?: Array<{ type: "drop" | "replace"; occurrenceId: string; replacementHash?: string }>;
};
