import { join } from "node:path";
import { pathToFileURL } from "node:url";

const { Agent } = await import(pathToFileURL(join(process.argv[2], "packages/agent/src/agent.ts")));
const agent = new Agent({ streamFn() {}, steeringMode: "all", followUpMode: "all" });
const user = content => ({ role: "user", content, timestamp: 0 });
agent.steer(user("steer one"));
agent.followUp(user("follow one"));
agent.steer(user("steer two"));
agent.followUp(user("follow two"));
const steering = agent.peekQueuedMessages().map(message => message.content);
agent.clearSteeringQueue();
const followups = agent.peekQueuedMessages().map(message => message.content);
agent.clearAllQueues();
process.stdout.write(JSON.stringify({ steering, followups, empty: !agent.hasQueuedMessages() }));
