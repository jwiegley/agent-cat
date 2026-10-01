import { constants as fsConstants } from "node:fs";
import { lstat, open, realpath } from "node:fs/promises";
import { basename, dirname, join, resolve } from "node:path";

/** The role marker file of a state root, as `runtime/README.md` "State-root roles" defines it. */
export const ROOT_ROLE_FILE = ".agentic-root-role.json";

/** The exact version-1 bytes of a manager marker: the canonical JSON object followed by one LF. */
export const MANAGER_ROLE_MARKER = '{"version":1,"role":"manager"}\n';

/** The bound of the ancestry walk, in directories, matching the runtime local-use check. */
export const ROOT_ROLE_WALK_LIMIT = 256;

const MARKER_READ_LIMIT = 256;

/** The storage role of one directory. An absent marker is `unmarked`. */
export type StateRootRole = "unmarked" | "manager";

/**
 * Reads the role marker of one directory. Absence is `unmarked`, the exact manager bytes are
 * `manager`, and any other content, a non-regular file, a symbolic link, or a read error refuses.
 */
export async function readStateRootRole(directory: string): Promise<StateRootRole> {
  const marker = join(directory, ROOT_ROLE_FILE);
  let status;
  try {
    status = await lstat(marker);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return "unmarked";
    throw new Error(`state-root role marker ${marker} cannot be inspected: ${(error as Error).message}`);
  }
  if (status.isSymbolicLink()) throw new Error(`state-root role marker ${marker} is a symbolic link`);
  if (!status.isFile()) throw new Error(`state-root role marker ${marker} is not a regular file`);
  const handle = await open(marker, fsConstants.O_RDONLY | fsConstants.O_NOFOLLOW);
  try {
    if (!(await handle.stat()).isFile()) throw new Error(`state-root role marker ${marker} is not a regular file`);
    const buffer = Buffer.alloc(MARKER_READ_LIMIT + 1);
    let length = 0;
    while (length < buffer.length) {
      const { bytesRead } = await handle.read(buffer, length, buffer.length - length, length);
      if (bytesRead === 0) break;
      length += bytesRead;
    }
    if (length > MARKER_READ_LIMIT) throw new Error(`state-root role marker ${marker} is oversized`);
    if (!buffer.subarray(0, length).equals(Buffer.from(MANAGER_ROLE_MARKER, "utf8"))) {
      throw new Error(`state-root role marker ${marker} is not the version-1 manager marker`);
    }
    return "manager";
  } finally {
    await handle.close();
  }
}

/**
 * Refuses local use of a state directory that is a manager root or lies beneath one. The check
 * canonicalizes the configured path, then reads the marker of the directory and of each ancestor,
 * bounded at {@link ROOT_ROLE_WALK_LIMIT} directories. Components that do not exist yet are
 * unmarked.
 */
export async function assertLocalStateRoot(stateDir: string): Promise<void> {
  const root = await canonicalPath(resolve(stateDir));
  let directory = root;
  for (let walked = 1; ; walked += 1) {
    if (walked > ROOT_ROLE_WALK_LIMIT) throw new Error(`state directory ${stateDir} has more than ${ROOT_ROLE_WALK_LIMIT} ancestors`);
    if ((await readStateRootRole(directory)) === "manager") {
      throw new Error(directory === root
        ? `state directory ${stateDir} is a manager state root; local restore and retention refuse`
        : `state directory ${stateDir} lies beneath the manager state root ${directory}; local restore and retention refuse`);
    }
    const parent = dirname(directory);
    if (parent === directory) return;
    directory = parent;
  }
}

async function canonicalPath(path: string): Promise<string> {
  try {
    return await realpath(path);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    const parent = dirname(path);
    if (parent === path) throw error;
    return join(await canonicalPath(parent), basename(path));
  }
}
