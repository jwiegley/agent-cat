import { dirname } from "node:path";
import { fileURLToPath } from "node:url";

export const piPackageRoot = process.env.PI_PACKAGE_DIR
  ?? dirname(dirname(fileURLToPath(import.meta.resolve("@earendil-works/pi-coding-agent"))));
