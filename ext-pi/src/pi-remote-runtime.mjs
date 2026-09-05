import { existsSync } from "node:fs";
import { basename, dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const packageRoot = process.env.PI_PACKAGE_DIR
  ?? dirname(dirname(fileURLToPath(import.meta.resolve("@earendil-works/pi-coding-agent"))));
const packageParent = dirname(packageRoot);

function findPackage(name) {
  const root = [
    join(packageParent, name),
    join(packageRoot, "node_modules/@earendil-works", name),
  ].find(existsSync);
  if (!root) throw new Error(`Pi runtime package ${name} is unavailable`);
  return root;
}

function moduleUrl(root, path) {
  return pathToFileURL(join(root, path)).href;
}

const clientRoot = findPackage("pi-client");
const chordRoot = findPackage("chord");
const [clientApi, unixApi, chordApi, contextApi] = await Promise.all([
  import(moduleUrl(clientRoot, "dist/index.js")),
  import(moduleUrl(clientRoot, "dist/unix.js")),
  import(moduleUrl(chordRoot, "dist/index.js")),
  import(moduleUrl(chordRoot, "dist/context/index.js")),
]);
const { Client, createClientServiceTransport } = clientApi;
const { createUnixTransportFactory } = unixApi;
const { createRemoteServiceBinding, defineService } = chordApi;
const { BACKGROUND_CONTEXT } = contextApi;

const SessionDirectory = defineService("pi.session-directory");
const SessionManagement = defineService("pi.session-management");
const AgentController = defineService("pi.agent-controller");
const Transcript = defineService("pi.transcript");

function serverIdFromSocket(socketPath) {
  const name = basename(socketPath);
  if (!name.endsWith(".sock")) throw new Error("remote Pi socket must end with <server-id>.sock");
  return name.slice(0, -".sock".length);
}

export async function openRemotePi(socketPath) {
  const serverId = serverIdFromSocket(socketPath);
  const client = await Client.connect({
    serverId,
    transportFactory: createUnixTransportFactory({ path: socketPath }),
  });
  const serverBinding = createRemoteServiceBinding({
    services: [SessionDirectory, SessionManagement],
    transport: createClientServiceTransport(client, () => ({ serverId })),
    bound: true,
  });
  const sessionBinding = createRemoteServiceBinding({
    services: [AgentController, Transcript],
    transport: createClientServiceTransport(client, () => client.attachment),
    bound: false,
  });
  const directory = serverBinding.use(SessionDirectory);
  const management = serverBinding.use(SessionManagement);
  const agent = sessionBinding.use(AgentController);
  const transcript = sessionBinding.use(Transcript);
  try {
    await serverBinding.ready(BACKGROUND_CONTEXT);
  } catch (error) {
    await disposeRemote(sessionBinding, serverBinding, client).catch(() => {});
    throw error;
  }

  return {
    listSessions() {
      return directory.state.value?.sessions ?? [];
    },
    async attach(sessionId) {
      await management.attach(sessionId, BACKGROUND_CONTEXT);
      await sessionBinding.rebind(true, BACKGROUND_CONTEXT);
      await sessionBinding.ready(BACKGROUND_CONTEXT);
    },
    prompt(message) {
      return agent.prompt({ message, images: null }, BACKGROUND_CONTEXT);
    },
    steer(message) {
      return agent.steer({ message, images: null }, BACKGROUND_CONTEXT);
    },
    followUp(message) {
      return agent.followUp({ message, images: null }, BACKGROUND_CONTEXT);
    },
    requestAbort(operationId) {
      return agent.requestAbort(operationId, BACKGROUND_CONTEXT);
    },
    subscribe(listener) {
      return transcript.state.subscribe(listener);
    },
    snapshot() {
      return transcript.state.value?.snapshot ?? null;
    },
    activeOperationId() {
      return transcript.state.value?.snapshot?.operation?.id;
    },
    dispose() {
      return disposeRemote(sessionBinding, serverBinding, client);
    },
  };
}

async function disposeRemote(sessionBinding, serverBinding, client) {
  const errors = [];
  for (const dispose of [
    () => sessionBinding.dispose(BACKGROUND_CONTEXT),
    () => serverBinding.dispose(BACKGROUND_CONTEXT),
    () => client.dispose(),
  ]) {
    try {
      await dispose();
    } catch (error) {
      errors.push(error);
    }
  }
  if (errors.length === 1) throw errors[0];
  if (errors.length > 1) throw new AggregateError(errors, "Failed to close remote Pi connection");
}
