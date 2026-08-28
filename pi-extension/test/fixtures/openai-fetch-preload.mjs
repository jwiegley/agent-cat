import { appendFileSync } from "node:fs";

const counter = process.env.AGENT_CAT_FIXTURE_COUNTER;
if (!counter) throw new Error("AGENT_CAT_FIXTURE_COUNTER is required");

globalThis.fetch = async () => {
  appendFileSync(counter, "request\n");
  const content = '{"title":"Child result","priority":1,"steps":["decode"]}';
  const chunks = [
    { id: "fixture", object: "chat.completion.chunk", choices: [{ index: 0, delta: { role: "assistant", content }, finish_reason: null }] },
    { id: "fixture", object: "chat.completion.chunk", choices: [{ index: 0, delta: {}, finish_reason: "stop" }] },
  ];
  const body = chunks.map((chunk) => `data: ${JSON.stringify(chunk)}\n\n`).join("") + "data: [DONE]\n\n";
  return new Response(body, { status: 200, headers: { "content-type": "text/event-stream" } });
};
