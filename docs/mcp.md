# MCP stdio tools

`JuliaForever.MCP` is an optional, native Julia stdio client and adapter for the existing in-process `Tool` API. No server is started by the CLI and no MCP tool is exposed automatically. Choose a trusted executable and its environment explicitly:

```julia
using JuliaForever
const MCP = JuliaForever.MCP

client = MCP.connect(`my-mcp-server`; timeout=30, grace=0.5)
if client isa MCP.Client
    try
        remote = MCP.tools(client; prefix="mcp_")
        if remote isa Vector{MCP.RemoteTool}
            # Check names against every other tool before assembling the agent.
            agent = Agent(my_provider, remote)
            respond!(agent, "Use the available tools")
        end
    finally
        close(client)
    end
end
```

`connect` starts the command with the supplied `Cmd` environment, forwards the child's stderr, requests protocol `2025-11-25` with no optional client capabilities, accepts `2025-06-18`, `2025-03-26` and `2024-11-05`, and sends `notifications/initialized`. The server's initialization result, including its capabilities and instructions, is available as `client.server`. An unsupported version or failed handshake closes the process and returns `MCP.Failure`. Server `ping` requests receive an empty result; unsupported server requests receive JSON-RPC method-not-found. Other notifications, including tool-list changes and progress, are ignored. Call `tools` again to refresh a list.

`MCP.tools` requires the server's tools capability, follows opaque pagination cursors (at most 1000 pages), and returns `RemoteTool` values or `MCP.Failure`. Discovery fails if any tool requires task-augmented execution, which this client cannot perform. It adapts each server name to the provider-friendly prefix plus ASCII letters, digits, `_` or `-`, capped at 64 characters; collisions within the discovered list fail. A caller must also check for collisions with tools from other servers and local tools before creating an `Agent`. Input schemas pass through unchanged. The client does not validate JSON Schema dialects or tool arguments and relies on the server to validate calls.

`MCP.call(client, name, arguments; timeout=...)` returns the raw result dictionary or an `MCP.Failure` containing a `kind`, `message` and optional `data` (including the JSON-RPC error code). Direct callers must check that the tool does not require task execution. Calls may overlap and responses are correlated by ID. Timeouts send `notifications/cancelled` after a request is written; this is a request to the server, not a guarantee that its operation stopped. EOF, malformed or incomplete newline-delimited messages, explicit close and write failures unblock pending requests. A blocked pipe write itself has no timeout. Server output is not size-limited.

`RemoteTool` maps text content into `ToolResult.text`, serializes non-text content blocks and structured content as JSON text, and propagates `isError`. It does not deliver images as native model image blocks or validate output schemas. This differs from Pi's `toLlmContent`, which passes images through, renders resource links as placeholders, and uses structured content only when content is empty. The raw `MCP.call` result retains the original blocks. Tool execution may have side effects and the caller controls which tools to expose.

`close(client)` closes child stdin, waits `grace` seconds, sends SIGTERM and then SIGKILL to the direct child if needed, and reaps it. This client does not supervise child process groups or descendants; commands that launch wrappers must arrange their own descendant cleanup. It does not yet implement Windows process-tree shutdown, HTTP, OAuth, resource or prompt APIs, roots, sampling, elicitation, task APIs, reconnect, progress callbacks, external cancellation, dynamic tool registration, or CLI configuration. It is not full MCP conformance or Pi MCP parity.

Protocol reference: [lifecycle](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle), [stdio transport](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports), [tools](https://modelcontextprotocol.io/specification/2025-11-25/server/tools), and [pagination](https://modelcontextprotocol.io/specification/2025-11-25/server/utilities/pagination). The B1 reference inspected is pinned Pi revision `e7a0df27c09d11bf4161d3605246cbf57a129cb2`, especially `packages/mcp/README.md`, `src/client.ts` and `src/transports/stdio.ts`; this implementation supports a narrower surface.
