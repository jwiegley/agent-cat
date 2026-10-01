import { mkdir, mkdtemp, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { assertLocalStateRoot, MANAGER_ROLE_MARKER, readStateRootRole, ROOT_ROLE_FILE, ROOT_ROLE_WALK_LIMIT } from "../src/root-role.ts";

const created: string[] = [];
afterEach(async () => Promise.all(created.splice(0).map((path) => rm(path, { recursive: true, force: true }))));

async function scratch(): Promise<string> {
  const directory = await mkdtemp(join(tmpdir(), "agent-cat-root-role-"));
  created.push(directory);
  return directory;
}

async function managerRoot(parent: string): Promise<string> {
  const root = join(parent, "manager");
  await mkdir(root, { mode: 0o700 });
  await writeFile(join(root, ROOT_ROLE_FILE), MANAGER_ROLE_MARKER, { mode: 0o600 });
  return root;
}

describe("state-root roles", () => {
  it("reads absence as unmarked and the exact version-1 bytes as a manager root", async () => {
    const directory = await scratch();
    expect(await readStateRootRole(directory)).toBe("unmarked");
    const root = await managerRoot(directory);
    expect(await readStateRootRole(root)).toBe("manager");
  });

  it.each([
    ["no trailing LF", '{"version":1,"role":"manager"}'],
    ["noncanonical whitespace", '{"version": 1,"role":"manager"}\n'],
    ["an unknown version", '{"version":2,"role":"manager"}\n'],
    ["an extra field", '{"version":1,"role":"manager","x":1}\n'],
    ["another role", '{"version":1,"role":"local"}\n'],
    ["an empty file", ""],
    ["an oversized file", `${" ".repeat(300)}\n`],
  ])("refuses a marker with %s", async (_label, bytes) => {
    const directory = await scratch();
    await writeFile(join(directory, ROOT_ROLE_FILE), bytes, { mode: 0o600 });
    await expect(readStateRootRole(directory)).rejects.toThrow(ROOT_ROLE_FILE);
    await expect(assertLocalStateRoot(join(directory, "state"))).rejects.toThrow(ROOT_ROLE_FILE);
  });

  it("refuses a marker that is a directory or a symbolic link", async () => {
    const directory = await scratch();
    const folder = join(directory, "folder");
    await mkdir(join(folder, ROOT_ROLE_FILE), { recursive: true });
    await expect(readStateRootRole(folder)).rejects.toThrow("not a regular file");
    const linked = join(directory, "linked");
    await mkdir(linked);
    const target = join(directory, "marker-target");
    await writeFile(target, MANAGER_ROLE_MARKER, { mode: 0o600 });
    await symlink(target, join(linked, ROOT_ROLE_FILE));
    await expect(readStateRootRole(linked)).rejects.toThrow("symbolic link");
  });

  it("permits an unmarked local root, existing or not", async () => {
    const directory = await scratch();
    await mkdir(join(directory, "local"));
    await expect(assertLocalStateRoot(join(directory, "local"))).resolves.toBeUndefined();
    await expect(assertLocalStateRoot(join(directory, "missing", "state"))).resolves.toBeUndefined();
  });

  it("refuses a manager root, a directory beneath one, and an alias that resolves beneath one", async () => {
    const directory = await scratch();
    const root = await managerRoot(directory);
    await expect(assertLocalStateRoot(root)).rejects.toThrow("is a manager state root");
    await mkdir(join(root, "nested"));
    await expect(assertLocalStateRoot(join(root, "nested"))).rejects.toThrow("lies beneath the manager state root");
    await expect(assertLocalStateRoot(join(root, "nested", "missing", "state"))).rejects.toThrow("lies beneath the manager state root");
    await symlink(join(root, "nested"), join(directory, "alias"));
    await expect(assertLocalStateRoot(join(directory, "alias"))).rejects.toThrow("lies beneath the manager state root");
  });

  it("bounds the ancestry walk", async () => {
    const directory = await scratch();
    const deep = join(directory, ...Array.from({ length: ROOT_ROLE_WALK_LIMIT }, () => "d"));
    await mkdir(deep, { recursive: true });
    await expect(assertLocalStateRoot(deep)).rejects.toThrow(`more than ${ROOT_ROLE_WALK_LIMIT} ancestors`);
  });
});
