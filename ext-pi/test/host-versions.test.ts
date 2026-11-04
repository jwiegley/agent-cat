import { lstatSync, readdirSync, readFileSync, realpathSync } from "node:fs";
import { findPackageJSON } from "node:module";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { describe, expect, it } from "vitest";

/**
 * The supported Pi host releases: each plain release `x.y.z` from `from` up to, but not including, `before`.
 * The `package.json` of the linked pi-coding-agent names the host release.
 */
const SUPPORTED_PI_RELEASES = { from: "1.4.0", before: "2.0.0" } as const;

/** The supported range as the section "Supported host" of the README states it. */
const SUPPORTED_PI_RANGE = `>=${SUPPORTED_PI_RELEASES.from} <${SUPPORTED_PI_RELEASES.before}`;

/** The host package whose version is the host release. */
const HOST_RELEASE_PACKAGE = "@earendil-works/pi-coding-agent";

/** The host packages that `node_modules/@earendil-works` links into the built Pi fork, each at the host release. */
const LINKED_HOST_PACKAGES: readonly string[] = [
  "@earendil-works/pi-ai",
  HOST_RELEASE_PACKAGE,
  "@earendil-works/pi-telemetry",
  "@earendil-works/pi-tui",
];

/** The retired remote protocol is an extension-owned published dependency. */
const SUPPORTED_REGISTRY: Readonly<Record<string, string>> = {
  "@earendil-works/chord": "1.1.0",
  "@earendil-works/pi-client": "1.1.0",
  "@earendil-works/pi-protocol": "1.1.0",
  "@earendil-works/pi-server": "1.1.0",
};

/** Host packages that resolve through the fork's own `node_modules` from pi-coding-agent, each at the host release. */
const THROUGH_FORK_PACKAGES: readonly string[] = ["@earendil-works/pi-agent-core"];

/** Node patch releases covered by the real-host test matrix. */
const SUPPORTED_NODE_RELEASES = ["22.23.3", "22.23.4"] as const;

/** Exact compiler and test-runner versions shared by the supported Node releases. */
const SUPPORTED_TOOLCHAIN: Readonly<Record<string, string>> = {
  typescript: "5.9.3",
  vitest: "4.1.9",
};

type ObservedHost = {
  linked: Record<string, string>;
  registry: Record<string, string>;
  throughFork: Record<string, string>;
  toolchain: Record<string, string>;
};

/** The major, minor and patch numbers of a plain release `x.y.z`, or `undefined` for any other version. */
function plainRelease(version: string): readonly [number, number, number] | undefined {
  const match = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/.exec(version);
  return match === null ? undefined : [Number(match[1]), Number(match[2]), Number(match[3])];
}

/** Whether `version` is a plain release in the supported range. */
function supportedPiRelease(version: string): boolean {
  const release = plainRelease(version);
  if (release === undefined) return false;
  const order = (bound: string): number => {
    const [major, minor, patch] = plainRelease(bound)!;
    return release[0] - major || release[1] - minor || release[2] - patch;
  };
  return order(SUPPORTED_PI_RELEASES.from) >= 0 && order(SUPPORTED_PI_RELEASES.before) < 0;
}

/**
 * Returns one finding for a host release outside the supported range, for each host package at another release,
 * for each observed version outside the exact registry and toolchain sets, and for each unlisted or missing package.
 */
function hostFindings(observed: ObservedHost): string[] {
  const compare = (kind: string, supported: Readonly<Record<string, string>>, actual: Record<string, string>) => [
    ...Object.entries(actual).flatMap(([name, version]) =>
      supported[name] === undefined ? [`${kind} ${name} ${version} is not in the supported set`]
        : supported[name] !== version ? [`${kind} ${name} is ${version}, not the supported ${supported[name]}`] : []),
    ...Object.keys(supported).filter((name) => actual[name] === undefined).map((name) => `${kind} ${name} is missing`),
  ];
  // A host without a linked pi-coding-agent has no release, so its only release finding is the missing link.
  const hostRelease = observed.linked[HOST_RELEASE_PACKAGE];
  const atRelease = (kind: string, names: readonly string[], actual: Record<string, string>) => [
    ...Object.entries(actual).flatMap(([name, version]) =>
      !names.includes(name) ? [`${kind} ${name} ${version} is not in the supported set`]
        : hostRelease !== undefined && version !== hostRelease ? [`${kind} ${name} is ${version}, not the host release ${hostRelease}`] : []),
    ...names.filter((name) => actual[name] === undefined).map((name) => `${kind} ${name} is missing`),
  ];
  const releaseFindings = hostRelease === undefined || supportedPiRelease(hostRelease) ? []
    : [`host release ${hostRelease} is not a plain release in the supported range ${SUPPORTED_PI_RANGE}`];
  const { node, ...toolchain } = observed.toolchain;
  const nodeFindings = node === undefined ? ["toolchain node is missing"]
    : SUPPORTED_NODE_RELEASES.some((release) => release === node) ? []
      : [`toolchain node is ${node}, not a supported release (${SUPPORTED_NODE_RELEASES.join(", ")})`];
  return [
    ...releaseFindings,
    ...atRelease("linked package", LINKED_HOST_PACKAGES, observed.linked),
    ...compare("registry package", SUPPORTED_REGISTRY, observed.registry),
    ...atRelease("fork package", THROUGH_FORK_PACKAGES, observed.throughFork),
    ...nodeFindings,
    ...compare("toolchain", SUPPORTED_TOOLCHAIN, toolchain),
  ];
}

const extensionRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const scopeDirectory = join(extensionRoot, "node_modules", "@earendil-works");

function resolvedManifest(specifier: string, base: string): { path: string; name: string; version: string } {
  const found = findPackageJSON(specifier, base);
  if (!found) throw new Error(`${specifier} does not resolve from ${base}`);
  const path = realpathSync(found);
  const { name, version } = JSON.parse(readFileSync(path, "utf8")) as { name: string; version: string };
  return { path, name, version };
}

function observeHost(): ObservedHost & { linkTargets: string[]; forkCore: string } {
  const linked: Record<string, string> = {};
  const registry: Record<string, string> = {};
  const linkTargets: string[] = [];
  for (const entry of readdirSync(scopeDirectory).sort()) {
    const specifier = `@earendil-works/${entry}`;
    const manifest = resolvedManifest(specifier, import.meta.url);
    if (manifest.name !== specifier) throw new Error(`${specifier} resolves to ${manifest.name}`);
    if (lstatSync(join(scopeDirectory, entry)).isSymbolicLink()) {
      linked[specifier] = manifest.version;
      linkTargets.push(dirname(manifest.path));
    } else {
      registry[specifier] = manifest.version;
    }
  }
  const codingAgent = resolvedManifest(HOST_RELEASE_PACKAGE, import.meta.url);
  const throughFork: Record<string, string> = {};
  let forkCore = "";
  for (const specifier of THROUGH_FORK_PACKAGES) {
    const manifest = resolvedManifest(specifier, pathToFileURL(codingAgent.path).href);
    throughFork[specifier] = manifest.version;
    forkCore = dirname(manifest.path);
  }
  const toolchain: Record<string, string> = { node: process.versions.node };
  for (const name of ["typescript", "vitest"]) toolchain[name] = resolvedManifest(name, import.meta.url).version;
  return { linked, registry, throughFork, toolchain, linkTargets, forkCore };
}

/** A host whose linked and fork packages all report `release`, with the exact registry set and toolchain. */
function coherentHost(release: string): ObservedHost {
  return {
    linked: Object.fromEntries(LINKED_HOST_PACKAGES.map((name) => [name, release])),
    registry: { ...SUPPORTED_REGISTRY },
    throughFork: Object.fromEntries(THROUGH_FORK_PACKAGES.map((name) => [name, release])),
    toolchain: { node: SUPPORTED_NODE_RELEASES[0], ...SUPPORTED_TOOLCHAIN },
  };
}

describe("supported Pi host", () => {
  const supported = coherentHost("1.5.0");

  it("links a supported Pi host release and keeps the remote protocol on its own release", () => {
    const observed = observeHost();
    expect(hostFindings(observed)).toEqual([]);
    const packages = new Set([...observed.linkTargets, observed.forkCore].map((target) => dirname(target)));
    expect(packages.size).toBe(1);
    expect([...packages][0]!.endsWith("/packages")).toBe(true);
  });

  it("declares the supported range that the README states", () => {
    expect(SUPPORTED_PI_RANGE).toBe(">=1.4.0 <2.0.0");
    expect(readFileSync(join(extensionRoot, "README.md"), "utf8")).toContain(`\`${SUPPORTED_PI_RANGE}\``);
  });

  it.each(["1.4.0", "1.5.0", "1.99.0"])("accepts a coherent host at Pi %s", (release) => {
    expect(hostFindings(coherentHost(release))).toEqual([]);
  });

  it.each(["1.3.0", "2.0.0", "1.5.0-rc.1"])("rejects a coherent host at Pi %s", (release) => {
    expect(hostFindings(coherentHost(release)))
      .toEqual([`host release ${release} is not a plain release in the supported range >=1.4.0 <2.0.0`]);
  });

  it("requires every host package at the release of pi-coding-agent", () => {
    expect(hostFindings({ ...supported, linked: { ...supported.linked, "@earendil-works/pi-tui": "1.4.0" } }))
      .toEqual(["linked package @earendil-works/pi-tui is 1.4.0, not the host release 1.5.0"]);
    expect(hostFindings({ ...supported, throughFork: { "@earendil-works/pi-agent-core": "1.4.0" } }))
      .toEqual(["fork package @earendil-works/pi-agent-core is 1.4.0, not the host release 1.5.0"]);
    expect(hostFindings({ ...supported, throughFork: {} }))
      .toEqual(["fork package @earendil-works/pi-agent-core is missing"]);
  });

  it("reports an unlisted link and a missing host package", () => {
    expect(hostFindings({ ...supported, linked: { ...supported.linked, "@earendil-works/pi-mcp": "1.5.0" } }))
      .toEqual(["linked package @earendil-works/pi-mcp 1.5.0 is not in the supported set"]);
    const { "@earendil-works/pi-telemetry": _telemetry, ...withoutTelemetry } = supported.linked;
    expect(hostFindings({ ...supported, linked: withoutTelemetry }))
      .toEqual(["linked package @earendil-works/pi-telemetry is missing"]);
    const { "@earendil-works/pi-coding-agent": _codingAgent, ...withoutCodingAgent } = supported.linked;
    expect(hostFindings({ ...supported, linked: withoutCodingAgent }))
      .toEqual(["linked package @earendil-works/pi-coding-agent is missing"]);
  });

  it("keeps the registry set exact at every host release", () => {
    expect(hostFindings({ ...supported, registry: { ...SUPPORTED_REGISTRY, "@earendil-works/chord": "1.5.0" } }))
      .toEqual(["registry package @earendil-works/chord is 1.5.0, not the supported 1.1.0"]);
    const { "@earendil-works/chord": _chord, ...withoutChord } = SUPPORTED_REGISTRY;
    expect(hostFindings({ ...supported, registry: withoutChord })).toEqual(["registry package @earendil-works/chord is missing"]);
  });

  it.each(["22.23.3", "22.23.4"])("accepts tested Node release %s", (node) => {
    expect(hostFindings({ ...supported, toolchain: { ...supported.toolchain, node } })).toEqual([]);
  });

  it.each(["22.23.2", "22.23.5", "23.0.0", "24.0.0"])("rejects untested Node release %s", (node) => {
    expect(hostFindings({ ...supported, toolchain: { ...supported.toolchain, node } }))
      .toEqual([`toolchain node is ${node}, not a supported release (22.23.3, 22.23.4)`]);
  });

  it("reports a missing Node release", () => {
    expect(hostFindings({ ...supported, toolchain: { ...SUPPORTED_TOOLCHAIN } }))
      .toEqual(["toolchain node is missing"]);
  });

  it("keeps compiler and test-runner checks exact", () => {
    expect(hostFindings({ ...supported, toolchain: { ...supported.toolchain, typescript: "5.9.2" } }))
      .toEqual(["toolchain typescript is 5.9.2, not the supported 5.9.3"]);
    expect(hostFindings({ ...supported, toolchain: { node: SUPPORTED_NODE_RELEASES[0], typescript: "5.9.3" } }))
      .toEqual(["toolchain vitest is missing"]);
    expect(hostFindings({ ...supported, toolchain: { ...supported.toolchain, tsx: "4.20.0" } }))
      .toEqual(["toolchain tsx 4.20.0 is not in the supported set"]);
  });
});
