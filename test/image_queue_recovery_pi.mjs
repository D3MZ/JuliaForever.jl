import { join } from "node:path";
import { pathToFileURL } from "node:url";

const source = process.argv[2];
const { Agent } = await import(pathToFileURL(join(source, "packages/agent/src/agent.ts")));
const { AgentSession } = await import(pathToFileURL(join(source, "packages/coding-agent/src/core/agent-session.ts")));
const agent = new Agent({ streamFn() {}, steeringMode: "all", followUpMode: "all" });
const session = { agent, _steeringMessages: [], _followUpMessages: [], _emitQueueUpdate() {} };
const image = { type: "image", mimeType: "image/png", data: "c3ludGhldGljLWltYWdl" };
await AgentSession.prototype._queueSteer.call(session, "image steering", [image]);
await AgentSession.prototype._queueFollowUp.call(session, "image followup", [image]);
const before = [...agent.steeringQueue.peek(), ...agent.followUpQueue.peek()].map(message => message.content);
const restored = AgentSession.prototype.clearQueue.call(session);
process.stdout.write(JSON.stringify({ before, restored, remaining: agent.peekQueuedMessages() }));
