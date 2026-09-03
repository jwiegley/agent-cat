#!/usr/bin/env node
import { readFile } from "node:fs/promises";
import net from "node:net";

const socketPath = process.env.AGENT_CAT_PI_BRIDGE_SOCKET;
const tokenFile = process.env.AGENT_CAT_PI_BRIDGE_TOKEN_FILE;
if (!socketPath || !tokenFile) {
  process.stderr.write("agent-cat Pi bridge environment is missing\n");
  process.exit(2);
}
const token = (await readFile(tokenFile, "utf8")).trim();
const socket = net.createConnection(socketPath);
socket.on("connect", () => {
  socket.write(`${JSON.stringify({ token })}\n`);
  process.stdin.pipe(socket);
  socket.pipe(process.stdout);
});
socket.on("error", (error) => {
  process.stderr.write(`agent-cat Pi bridge failed: ${error.message}\n`);
  process.exitCode = 1;
});
socket.on("close", () => process.exit());
process.stdin.on("error", () => socket.destroy());
