// Development-only differential oracle against the pinned Pi client.
import { pathToFileURL } from "node:url";
const { McpClient, StdioTransport } = await import(pathToFileURL(`${process.env.PI_SOURCE}/packages/mcp/src/index.ts`).href);
const client = new McpClient({ name: "JuliaForever", version: "0.1.0" });
const transport = new StdioTransport({ command: process.env.JF_JULIA, args: ["--startup-file=no", `--project=${process.env.JF_JULIA_PROJECT}`, `${process.env.JF_PROJECT}/test/mcp_resources_server.jl`, "normal", process.env.JF_MARKER] });
try {
  await client.connect(transport);
  const page = await client.listResourcesPage();
  const second = await client.listResourcesPage(page.nextCursor);
  const resources = await client.listResources();
  const templatePage = await client.listResourceTemplatesPage();
  const templates = await client.listResourceTemplates();
  const text = await client.readResource("docs://intro");
  const blob = await client.readResource("docs://image");
  console.log(JSON.stringify({ page, second, resources, templatePage, templates, text, blob }));
} finally {
  await client.close();
}
