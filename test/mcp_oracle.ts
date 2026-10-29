// B1 oracle only: execute the pinned Pi client against the same deterministic server.
import { pathToFileURL } from "node:url";

const source = `${process.env.PI_SOURCE}/packages/mcp/src/index.ts`;
const { McpClient, StdioTransport } = await import(pathToFileURL(source).href);
const transport = new StdioTransport({ command: process.env.JF_JULIA, args: ["--startup-file=no", `--project=${process.env.JF_JULIA_PROJECT}`, `${process.env.JF_PROJECT}/test/mcp_server.jl`, "normal", process.env.JF_MARKER] });
const client = new McpClient({ name: "JuliaForever", version: "0.1.0" });
try {
  const server = await client.connect(transport);
  const tools = await client.listTools();
  const echo = await client.callTool("alpha", { value: 7 });
  const toolError = await client.callTool("tool_error", {});
  const mixed = await client.callTool("mixed", {});
  let code;
  try {
    await client.callTool("protocol_error", {});
  } catch (error) {
    code = error.code;
  }
  console.log(JSON.stringify({ version: server.protocolVersion, tools, echo, toolError, mixed, code }));
} finally {
  await client.close();
}
