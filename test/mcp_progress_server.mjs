import readline from "node:readline";

const send = (message) => process.stdout.write(`${JSON.stringify(message)}\n`);
const reply = (id, result) => send({ jsonrpc: "2.0", id, result });
const progress = (token, value, more = {}) => send({ jsonrpc: "2.0", method: "notifications/progress", params: { progressToken: token, progress: value, ...more } });
const later = (ms, action) => setTimeout(action, ms);
const pair = [];
const pending = new Map();

readline.createInterface({ input: process.stdin }).on("line", (line) => {
  const message = JSON.parse(line);
  const { id, method, params = {} } = message;
  if (method === "initialize") {
    reply(id, { protocolVersion: "2025-11-25", capabilities: { tools: {} }, serverInfo: { name: "progress", version: "1" } });
  } else if (method === "notifications/cancelled") {
    const item = pending.get(params.requestId);
    if (item) {
      progress(item.id, 99, { message: "late cancellation" });
      pending.delete(item.id);
    }
  } else if (method === "probe") {
    later(20, () => {
      send({ jsonrpc: "2.0", method: "notifications/progress", params: null });
      progress(true, 1);
      progress(String(id), 2);
      progress(id + 1000, 3);
      progress(id, "invalid");
      progress(id, true);
      progress(id, null);
      progress(id, -1, { total: "unchecked", message: 7, extra: "retained" });
      progress(id, 2.5, { total: 4, message: "second" });
    });
    later(100, () => { reply(id, { params }); progress(id, 100); });
  } else if (method === "plain") {
    progress(id, 1);
    reply(id, { params });
  } else if (method === "pair") {
    pair.push({ id, params });
    if (pair.length === 2) later(30, () => {
      for (const item of pair.reverse()) progress(item.id, item.params.label, { message: item.params.label });
      later(70, () => { for (const item of pair) reply(item.id, { label: item.params.label }); });
    });
  } else if (method === "slow") {
    for (let index = 1; index <= 3; index++) later(index * 450, () => progress(id, index));
    later(1800, () => reply(id, { done: true }));
  } else if (method === "throw") {
    later(20, () => progress(id, 1));
    later(60, () => progress(id, 2));
    later(120, () => reply(id, { done: true }));
  } else if (method === "rpc") {
    later(20, () => progress(id, 1));
    later(80, () => {
      send({ jsonrpc: "2.0", id, error: { code: -32602, message: "failed" } });
      progress(id, 2);
    });
  } else if (method === "timeout") {
    pending.set(id, { id });
    later(20, () => progress(id, 1));
  } else if (method === "metadata") {
    reply(id, { params });
  } else if (method === "no-timeout") {
    later(150, () => reply(id, { done: true }));
  } else if (method === "barrier") {
    later(100, () => reply(id, { done: true }));
  }
});
