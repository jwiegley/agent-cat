import { dirname } from "node:path";
import { fileURLToPath } from "node:url";

export const piPackageRoot = dirname(dirname(fileURLToPath(import.meta.resolve("@earendil-works/pi-coding-agent"))));
