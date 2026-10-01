import { lstatSync, readdirSync, readFileSync, realpathSync } from "node:fs";
import { findPackageJSON } from "node:module";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { describe, expect, it } from "vitest";

/** The host packages that `node_modules/@earendil-works` links into the built Pi fork. */
const SUPPORTED_LINKED: Readonly<Record<string, string>> = {
  "@earendil-works/chord": "0.99.1",
  "@earendil-works/pi-ai": "0.99.1",
  "@earendil-works/pi-client": "0.99.1",
  "@earendil-works/pi-coding-agent": "0.99.1",
  "@earendil-works/pi-protocol": "0.99.1",
  "@earendil-works/pi-server": "0.99.1",
  "@earendil-works/pi-telemetry": "0.99.1",
  "@earendil-works/pi-tui": "0.99.1",
};

/** Host packages that resolve through the fork's own `node_modules` from pi-coding-agent. */
const SUPPORTED_THROUGH_FORK: Readonly<Record<string, string>> = {
  "@earendil-works/pi-agent-core": "0.99.1",
};

/** The supported toolchain. */
const SUPPORTED_TOOLCHAIN: Readonly<Record<string, string>> = {
  node: "22.23.3",
  typescript: "5.9.3",
  vitest: "4.1.9",
};

type ObservedHost = {
  linked: Record<string, string>;
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
  return [
    ...compare("linked package", SUPPORTED_LINKED, observed.linked),
    ...compare("fork package", SUPPORTED_THROUGH_FORK, observed.throughFork),
    ...compare("toolchain", SUPPORTED_TOOLCHAIN, observed.toolchain),
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
  const linkTargets: string[] = [];
  for (const entry of readdirSync(scopeDirectory).sort()) {
    const specifier = `@earendil-works/${entry}`;
    if (!lstatSync(join(scopeDirectory, entry)).isSymbolicLink()) throw new Error(`${specifier} is not a link into the Pi fork`);
    const manifest = resolvedManifest(specifier, import.meta.url);
    if (manifest.name !== specifier) throw new Error(`${specifier} resolves to ${manifest.name}`);
    linked[specifier] = manifest.version;
    linkTargets.push(dirname(manifest.path));
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
  return { linked, throughFork, toolchain, linkTargets, forkCore };
}

describe("supported Pi host", () => {
  it("links every supported host package into one built Pi fork at its supported version", () => {
    const observed = observeHost();
    expect(hostFindings(observed)).toEqual([]);
    const packages = new Set([...observed.linkTargets, observed.forkCore].map((target) => dirname(target)));
    expect(packages.size).toBe(1);
    expect([...packages][0]!.endsWith("/packages")).toBe(true);
  });

  it("reports another version, an unlisted package, and a missing package", () => {
    const supported = {
      linked: { ...SUPPORTED_LINKED },
      throughFork: { ...SUPPORTED_THROUGH_FORK },
      toolchain: { ...SUPPORTED_TOOLCHAIN },
    };
    expect(hostFindings(supported)).toEqual([]);
    expect(hostFindings({ ...supported, linked: { ...SUPPORTED_LINKED, "@earendil-works/pi-tui": "0.84.3" } }))
      .toEqual(["linked package @earendil-works/pi-tui is 0.84.3, not the supported 0.99.1"]);
    expect(hostFindings({ ...supported, linked: { ...SUPPORTED_LINKED, "@earendil-works/pi-mcp": "0.99.1" } }))
      .toEqual(["linked package @earendil-works/pi-mcp 0.99.1 is not in the supported set"]);
    const { "@earendil-works/chord": _chord, ...withoutChord } = SUPPORTED_LINKED;
    expect(hostFindings({ ...supported, linked: withoutChord })).toEqual(["linked package @earendil-works/chord is missing"]);
    expect(hostFindings({ ...supported, throughFork: { "@earendil-works/pi-agent-core": "0.98.0" } }))
      .toEqual(["fork package @earendil-works/pi-agent-core is 0.98.0, not the supported 0.99.1"]);
    expect(hostFindings({ ...supported, toolchain: { ...SUPPORTED_TOOLCHAIN, node: "24.0.0" } }))
      .toEqual(["toolchain node is 24.0.0, not the supported 22.23.3"]);
  });
});
