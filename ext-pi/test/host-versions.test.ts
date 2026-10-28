import { lstatSync, readdirSync, readFileSync, realpathSync } from "node:fs";
import { findPackageJSON } from "node:module";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { describe, expect, it } from "vitest";

/** The host packages that `node_modules/@earendil-works` links into the built Pi fork. */
const SUPPORTED_LINKED: Readonly<Record<string, string>> = {
  "@earendil-works/pi-ai": "1.3.0",
  "@earendil-works/pi-coding-agent": "1.3.0",
  "@earendil-works/pi-telemetry": "1.3.0",
  "@earendil-works/pi-tui": "1.3.0",
};

/** The retired remote protocol is an extension-owned published dependency. */
const SUPPORTED_REGISTRY: Readonly<Record<string, string>> = {
  "@earendil-works/chord": "1.1.0",
  "@earendil-works/pi-client": "1.1.0",
  "@earendil-works/pi-protocol": "1.1.0",
  "@earendil-works/pi-server": "1.1.0",
};

/** Host packages that resolve through the fork's own `node_modules` from pi-coding-agent. */
const SUPPORTED_THROUGH_FORK: Readonly<Record<string, string>> = {
  "@earendil-works/pi-agent-core": "1.3.0",
};

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

/** Returns one finding for each observed version outside the supported set and each unlisted or missing package. */
function hostFindings(observed: ObservedHost): string[] {
  const compare = (kind: string, supported: Readonly<Record<string, string>>, actual: Record<string, string>) => [
    ...Object.entries(actual).flatMap(([name, version]) =>
      supported[name] === undefined ? [`${kind} ${name} ${version} is not in the supported set`]
        : supported[name] !== version ? [`${kind} ${name} is ${version}, not the supported ${supported[name]}`] : []),
    ...Object.keys(supported).filter((name) => actual[name] === undefined).map((name) => `${kind} ${name} is missing`),
  ];
  const { node, ...toolchain } = observed.toolchain;
  const nodeFindings = node === undefined ? ["toolchain node is missing"]
    : SUPPORTED_NODE_RELEASES.some((release) => release === node) ? []
      : [`toolchain node is ${node}, not a supported release (${SUPPORTED_NODE_RELEASES.join(", ")})`];
  return [
    ...compare("linked package", SUPPORTED_LINKED, observed.linked),
    ...compare("registry package", SUPPORTED_REGISTRY, observed.registry),
    ...compare("fork package", SUPPORTED_THROUGH_FORK, observed.throughFork),
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
  const codingAgent = resolvedManifest("@earendil-works/pi-coding-agent", import.meta.url);
  const throughFork: Record<string, string> = {};
  let forkCore = "";
  for (const specifier of Object.keys(SUPPORTED_THROUGH_FORK)) {
    const manifest = resolvedManifest(specifier, pathToFileURL(codingAgent.path).href);
    throughFork[specifier] = manifest.version;
    forkCore = dirname(manifest.path);
  }
  const toolchain: Record<string, string> = { node: process.versions.node };
  for (const name of ["typescript", "vitest"]) toolchain[name] = resolvedManifest(name, import.meta.url).version;
  return { linked, registry, throughFork, toolchain, linkTargets, forkCore };
}

describe("supported Pi host", () => {
  const supported: ObservedHost = {
    linked: { ...SUPPORTED_LINKED },
    registry: { ...SUPPORTED_REGISTRY },
    throughFork: { ...SUPPORTED_THROUGH_FORK },
    toolchain: { node: SUPPORTED_NODE_RELEASES[0], ...SUPPORTED_TOOLCHAIN },
  };

  it("links Pi 1.3 host packages and keeps the remote protocol on its own release", () => {
    const observed = observeHost();
    expect(hostFindings(observed)).toEqual([]);
    const packages = new Set([...observed.linkTargets, observed.forkCore].map((target) => dirname(target)));
    expect(packages.size).toBe(1);
    expect([...packages][0]!.endsWith("/packages")).toBe(true);
  });

  it("reports another version, an unlisted package, and a missing package", () => {
    expect(hostFindings(supported)).toEqual([]);
    expect(hostFindings({ ...supported, linked: { ...SUPPORTED_LINKED, "@earendil-works/pi-tui": "0.84.3" } }))
      .toEqual(["linked package @earendil-works/pi-tui is 0.84.3, not the supported 1.3.0"]);
    expect(hostFindings({ ...supported, linked: { ...SUPPORTED_LINKED, "@earendil-works/pi-mcp": "1.3.0" } }))
      .toEqual(["linked package @earendil-works/pi-mcp 1.3.0 is not in the supported set"]);
    const { "@earendil-works/chord": _chord, ...withoutChord } = SUPPORTED_REGISTRY;
    expect(hostFindings({ ...supported, registry: withoutChord })).toEqual(["registry package @earendil-works/chord is missing"]);
    expect(hostFindings({ ...supported, throughFork: { "@earendil-works/pi-agent-core": "0.98.0" } }))
      .toEqual(["fork package @earendil-works/pi-agent-core is 0.98.0, not the supported 1.3.0"]);
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
