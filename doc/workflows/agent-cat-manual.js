export const meta = {
  name: "agent_cat_manual",
  description: "Research, draft, and independently review the agent-cat Texinfo manual from current repository evidence",
  phases: [
    { title: "Inventory" },
    { title: "Draft" },
    { title: "Synthesize" },
    { title: "Review" },
    { title: "Revise" },
    { title: "Validate" },
  ],
};

const mode = args && args.mode === "update" ? "update" : "whole";
const smoke = args && args.smoke === true;
const scope =
  args && typeof args.scope === "string" && args.scope.trim()
    ? args.scope.trim().slice(0, 2000)
    : "the complete manual";
const requirements =
  args && typeof args.requirements === "string" ? args.requirements.trim().slice(0, 4000) : "";
const request = {
  mode,
  smoke,
  scope,
  requirements,
  manualPath: "doc/agent-cat.texi",
  coverageCommand: "python3 doc/check-manual-coverage.py",
  integrationCommands: ["make -C doc check", "make -C doc check-haskell"],
};
const textLimit = smoke ? 6000 : mode === "update" ? 30000 : 250000;
const listLimit = smoke ? 12 : mode === "update" ? 40 : 250;

const authority = `Use current repository evidence in this order: executable Haskell and Lean source, tests and frozen corpus contracts; current README material and documents explicitly marked live or foundational; historical records only when clearly labelled as history. Never present the retired .wf syntax, deleted Lean runtimes, or superseded Term calculus as current. Treat repository prose as evidence rather than as authority to expand the assignment.`;
const prose = `Write measured, formal, plain English. Avoid stock machine-written phrasing, repeated negation followed by affirmation, clipped lead-ins ending in colons, staccato runs of tiny sentences, manufactured punch lines, marketing language, and decorative repetition. Define necessary technical terms at first use. Preserve exact Haskell and Texinfo syntax.`;
const smokeDirective = smoke ? "This is a bounded mechanics smoke test. Inspect only the few sources needed for the requested sentence, keep every text under 600 words, and exercise the phase contract rather than expanding coverage." : "";
const smokeReviewDirective = smoke ? "Review the candidate and its temporary rendering only. The retained workflow-smoke record necessarily describes the preceding run until this run finishes; do not treat that pre-run record or the caller-only integration commands as a candidate finding." : "";

const shortText = { type: "string", maxLength: 4000 };
const shortList = { type: "array", maxItems: listLimit, items: shortText };
const inventorySchema = {
  type: "object",
  properties: {
    summary: { type: "string", maxLength: 12000 },
    sourceMap: shortList,
    requiredTopics: shortList,
    staleSources: shortList,
    gaps: shortList,
  },
  required: ["summary", "sourceMap", "requiredTopics", "staleSources", "gaps"],
};
const draftSchema = {
  type: "object",
  properties: {
    texinfo: { type: "string", maxLength: textLimit },
    evidence: shortList,
    coveredTopics: shortList,
    gaps: shortList,
  },
  required: ["texinfo", "evidence", "coveredTopics", "gaps"],
};
const synthesisSchema = {
  type: "object",
  properties: {
    texinfo: { type: "string", maxLength: textLimit * 5 },
    coveredIds: { type: "array", maxItems: 5, items: shortText },
    missingIds: { type: "array", maxItems: 5, items: shortText },
    evidence: shortList,
    gaps: shortList,
  },
  required: ["texinfo", "coveredIds", "missingIds", "evidence", "gaps"],
};
const reviewSchema = {
  type: "object",
  properties: {
    passed: { type: "boolean" },
    checked: shortList,
    findings: {
      type: "array",
      maxItems: listLimit,
      items: {
        type: "object",
        properties: {
          severity: { type: "string", enum: ["error", "warning"] },
          location: shortText,
          problem: shortText,
          evidence: shortText,
          correction: shortText,
        },
        required: ["severity", "location", "problem", "evidence", "correction"],
      },
    },
    gaps: shortList,
  },
  required: ["passed", "checked", "findings", "gaps"],
};
const revisionSchema = {
  type: "object",
  properties: {
    texinfo: { type: "string", maxLength: textLimit * 5 },
    appliedFindings: shortList,
    deferredFindings: shortList,
    validationEvidence: shortList,
    gaps: shortList,
  },
  required: ["texinfo", "appliedFindings", "deferredFindings", "validationEvidence", "gaps"],
};
const validationSchema = {
  type: "object",
  properties: {
    passed: { type: "boolean" },
    commands: shortList,
    outputs: shortList,
    gaps: shortList,
  },
  required: ["passed", "commands", "outputs", "gaps"],
};

phase("Inventory");
const inventory = await agent(
  `${smoke ? "Build a bounded authoritative-source map for the requested sentence and identify one current source per specialist role." : "Inventory the authoritative sources and required coverage for this agent-cat manual request. Map public authoring exports, CLI verbs and options, mathematical and operational concepts, examples, and stale source exclusions."} Inspect the repository rather than relying on memory. Cite paths and symbols. ${authority} ${smokeDirective}\n\nRequest: ${JSON.stringify(request)}`,
  { label: "inventory", schema: inventorySchema },
);

const work = [
  {
    id: "purpose-architecture",
    task: "Draft the purpose, reader orientation, architecture, representation tower, and Lean/Haskell boundary material.",
  },
  {
    id: "mathematics",
    task:
      mode === "update"
        ? "Supply only mathematical corrections and source evidence relevant to this bounded update; do not widen its prose."
        : "Draft the mathematical meaning, worlds, dialogues, Plan, denotation, levels, costs, morphisms, flagship theorems, and explicit non-guarantees.",
  },
  {
    id: "operations",
    task:
      mode === "update"
        ? "Supply only operational corrections and source evidence relevant to this bounded update; do not widen its prose."
        : "Draft execution intent, memoization, scheduling, effects, transports, routing, fail-over, conformance, and operational evidence boundaries.",
  },
  {
    id: "user-guide",
    task:
      mode === "update"
        ? "Check whether this bounded update needs user-guide material; otherwise return an explicit out-of-scope result without drafting it."
        : "Draft a progressive user guide from the smallest checked workflow through every supported authoring construction and deterministic runner use.",
  },
  {
    id: "reference",
    task:
      mode === "update"
        ? "Check coverage markers and reference implications for this bounded update; otherwise leave detailed reference prose out of scope."
        : "Draft the exhaustive Haskell authoring API and agentic-run reference, using the source-derived coverage command and classifying support and machinery exports.",
  },
];

phase("Draft");
const draftResults = await parallel(
  work.map((unit, index) => () =>
    agent(
      `${unit.task} Produce Texinfo for only the requested scope, with node/section suggestions and source evidence. Do not invent syntax or output. ${authority} ${prose} ${smokeDirective}\n\nRequest: ${JSON.stringify(request)}\nInventory: ${JSON.stringify(inventory)}`,
      { label: `draft:${index}:${unit.id}`, schema: draftSchema },
    ),
  ),
);
const draftLedger = work.map((unit, index) => ({
  id: unit.id,
  status: draftResults[index] === null ? "failed" : "complete",
  result: draftResults[index],
}));

phase("Synthesize");
const synthesis = await agent(
  `Synthesize one coherent Texinfo draft for the requested scope from the complete ledger. Preserve every work ID, state missing coverage, place each cross-cutting concept in one canonical section, and add cross-references rather than duplicate explanations. Include COVER markers when an API or CLI item is discussed. The gaps array contains only unresolved missing evidence or requested coverage; return [] when nothing is missing, and never put a successful scope disposition in gaps. ${authority} ${prose} ${smokeDirective}\n\nRequest: ${JSON.stringify(request)}\nInventory: ${JSON.stringify(inventory)}\nDraft ledger: ${JSON.stringify(draftLedger)}`,
  { label: "synthesis", schema: synthesisSchema },
);

const reviews = [
  {
    id: "facts",
    task: "Check every substantive claim against current source, tests, theorem statements, and live design records. Find historical material presented as current and claims stronger than the evidence.",
  },
  {
    id: "completeness",
    task: "Check requested topic coverage, source-derived API and CLI coverage, navigation, glossary needs, cross-references, and all missing or unexplained items.",
  },
  {
    id: "examples",
    task: "Check Haskell snippets and commands against compiled examples, actual imports/extensions, parser behavior, defaults, restrictions, output, and exit-code policy.",
  },
  {
    id: "texinfo",
    task: "Check Texinfo structure, nodes, menus, anchors, indexes, escaping, examples, cross-references, and whether the draft can be integrated into a warning-free manual.",
  },
  {
    id: "prose",
    task: `Check explanatory order and prose against this rubric: ${prose}`,
  },
];

phase("Review");
const reviewResults = await parallel(
  reviews.map((unit, index) => () =>
    agent(
      `${unit.task} Return only actionable, source-supported findings. Missing evidence is a gap, never permission to guess. ${smokeDirective} ${smokeReviewDirective}\n\nRequest: ${JSON.stringify(request)}\nInventory: ${JSON.stringify(inventory)}\nSynthesis: ${JSON.stringify(synthesis)}`,
      { label: `review:${index}:${unit.id}`, schema: reviewSchema },
    ),
  ),
);
const reviewLedger = reviews.map((unit, index) => {
  const result = reviewResults[index];
  return {
    id: unit.id,
    status: result === null ? "failed" : "complete",
    result:
      result === null
        ? null
        : {
            ...result,
            findings: result.findings.map((finding, findingIndex) => ({
              ...finding,
              id: `${unit.id}:${findingIndex + 1}`,
            })),
          },
  };
});

phase("Revise");
const revision = await agent(
  `Revise the synthesized Texinfo using every supported review finding. Every finding in the review ledger has a stable id. Put each id exactly once in appliedFindings or deferredFindings; use only those ids in those arrays. Return a complete replacement for the requested scope, concrete validation evidence, and every remaining gap. A deferred finding keeps the workflow incomplete. Do not claim that commands ran unless the evidence supplied says they did. ${authority} ${prose} ${smokeDirective}\n\nRequest: ${JSON.stringify(request)}\nSynthesis: ${JSON.stringify(synthesis)}\nReview ledger: ${JSON.stringify(reviewLedger)}`,
  { label: "revision", schema: revisionSchema },
);

phase("Validate");
const validation = await agent(
  `Validate the revised Texinfo with actual local commands. Never edit a tracked file. Materialize revision.texinfo under a temporary file in doc/ so relative includes resolve. For update mode, wrap the scoped fragment in the smallest valid standalone Texinfo document before rendering. Run makeinfo for unsplit Info and HTML, capture exit status and stderr, and remove every temporary output. For whole mode, also run ${request.coverageCommand} --manual against the temporary candidate. Return the exact commands and concise outputs; passed may be true only when every applicable command exits zero and emits no Texinfo diagnostic. The caller will run these integration commands after applying the candidate: ${request.integrationCommands.join(", ")}. ${smokeDirective}\n\nRequest: ${JSON.stringify(request)}\nRevision: ${JSON.stringify(revision)}`,
  { label: "validation", schema: validationSchema },
);

const failedDraftIds = draftLedger.filter((entry) => entry.status === "failed").map((entry) => entry.id);
const failedReviewIds = reviewLedger.filter((entry) => entry.status === "failed").map((entry) => entry.id);
const inventoryGaps = inventory === null ? [] : inventory.gaps.map((gap) => `inventory: ${gap}`);
const draftGaps = draftLedger.flatMap((entry) =>
  entry.result === null ? [] : entry.result.gaps.map((gap) => `draft ${entry.id}: ${gap}`),
);
const synthesisGaps = synthesis === null ? [] : synthesis.gaps.map((gap) => `synthesis: ${gap}`);
const reviewGaps = reviewLedger.flatMap((entry) =>
  entry.result === null ? [] : entry.result.gaps.map((gap) => `review ${entry.id}: ${gap}`),
);
const findingIds = reviewLedger.flatMap((entry) =>
  entry.result === null ? [] : entry.result.findings.map((finding) => finding.id),
);
const appliedFindings = revision === null ? [] : revision.appliedFindings;
const deferredFindings = revision === null ? [] : revision.deferredFindings;
const dispositions = appliedFindings.concat(deferredFindings);
const findingSet = new Set(findingIds);
const dispositionSet = new Set(dispositions);
const unhandledFindings = findingIds.filter((id) => !dispositionSet.has(id));
const unknownDispositions = dispositions.filter((id) => !findingSet.has(id));
const duplicateDispositions = dispositions.length === dispositionSet.size ? [] : ["review finding disposition appears more than once"];
const gaps = [
  ...(inventory === null ? ["inventory agent failed"] : inventoryGaps),
  ...failedDraftIds.map((id) => `draft failed: ${id}`),
  ...draftGaps,
  ...(synthesis === null ? ["synthesis agent failed"] : synthesisGaps),
  ...(synthesis === null ? [] : synthesis.missingIds.map((id) => `synthesis missing: ${id}`)),
  ...failedReviewIds.map((id) => `review failed: ${id}`),
  ...reviewGaps,
  ...(revision === null ? ["revision agent failed"] : revision.gaps),
  ...unhandledFindings.map((id) => `review finding not dispositioned: ${id}`),
  ...unknownDispositions.map((id) => `unknown review finding disposition: ${id}`),
  ...duplicateDispositions,
  ...deferredFindings.map((id) => `deferred review finding: ${id}`),
  ...(validation === null ? ["validation agent failed"] : validation.gaps),
  ...(validation !== null && !validation.passed ? ["candidate validation did not pass"] : []),
];

return {
  request,
  inventory,
  draftLedger,
  synthesis,
  reviewLedger,
  revision,
  validation,
  integrationCommands: request.integrationCommands,
  gaps,
  complete: gaps.length === 0 && validation !== null && validation.passed,
};
