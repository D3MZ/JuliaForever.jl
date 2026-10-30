# MCP tools and resources

`JuliaForever.MCP` is an optional, native Julia stdio and HTTP client and adapter for the existing in-process `Tool` API. No server is started by the CLI and no MCP tool is exposed automatically. Choose a trusted executable and its environment explicitly:

`Client.shutting` remains a Boolean property; its internal shutdown field now uses typed states, so direct field access and old Julia `Serialization` layouts are not compatible.
The internal `activate!` helper now returns a client or `Failure`, and `send` returns `nothing` or `Failure`, instead of Booleans.

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

`connect` starts the command with the supplied `Cmd` environment, forwards the child's stderr, requests protocol `2025-11-25`, accepts `2025-06-18`, `2025-03-26` and `2024-11-05`, and sends `notifications/initialized`. It advertises no optional client capabilities by default. The server's initialization result, including its capabilities and instructions, is available as `client.server`. An unsupported version or failed handshake closes the process and returns `MCP.Failure`. Server `ping` requests receive an empty result; unsupported server requests receive JSON-RPC method-not-found. Other notifications, including tool-list changes, are ignored. Call `tools` again to refresh a list.

Pass `roots=[(; uri="file:///workspace", name="workspace")]` to either `connect` method to advertise roots and answer server `roots/list` requests. A zero-argument callable may supply the list on each request; it runs in a separate task and can make MCP requests itself. An empty list advertises the capability and returns no roots. Without the option, roots are not advertised or disclosed. Callback failures return a JSON-RPC internal error. Changes are visible on the next request, but this client does not advertise or send root-list change notifications. The caller chooses appropriate `file://` URIs and synchronizes changes to a shared list; roots communicate intent to a server and do not enforce filesystem access. HTTP server requests are handled in POST response streams; server-initiated GET streams remain unsupported.

The connection lifecycle uses `MCP.Connecting`, `MCP.Open`, and `MCP.Closed`. Reading `client.state` still returns the corresponding symbol; direct assignment to that property is no longer supported.

`MCP.tools` requires the server's tools capability, follows opaque pagination cursors (at most 1000 pages), and returns `RemoteTool` values or `MCP.Failure`. Discovery fails if any tool requires task-augmented execution, which this client cannot perform. It adapts each server name to the provider-friendly prefix plus ASCII letters, digits, `_` or `-`, capped at 64 characters; collisions within the discovered list fail. A caller must also check for collisions with tools from other servers and local tools before creating an `Agent`. Input schemas pass through unchanged. The client does not validate JSON Schema dialects or tool arguments and relies on the server to validate calls.

`MCP.resourcepage`, `MCP.templatepage`, `MCP.resources`, `MCP.templates`, and `read(client, uri)` list and read server resources. `MCP.resourcetools(Dict("server" => client))` exposes resource listing and reading as agent tools. Binary resource output is currently JSON/base64; resource changes and subscriptions are not supported.

`MCP.call(client, name, arguments; timeout=..., on_progress=...)` returns the raw result dictionary or an `MCP.Failure` containing a `kind`, `message` and optional `data` (including the JSON-RPC error code). Direct callers must check that the tool does not require task execution. Calls may overlap and responses are correlated by ID. The low-level `MCP.request` accepts the same options. A positive finite timeout is in seconds; zero, negative and non-finite values disable the request timer, as in the pinned Pi client.

An `on_progress` callable opts that request into progress notifications. The client puts the request's numeric ID in `params._meta.progressToken`, retaining other object-valued `_meta` fields, and adds no token without a callback; caller-supplied parameters are otherwise unchanged. It accepts a matching numeric token and a numeric `progress`, excluding booleans, then rearms the request timeout before queuing the full parameters dictionary. Like Pi, it does not validate `total`, `message`, monotonicity or the progress range. Unknown, malformed, unmatched and post-completion notifications are ignored. Each request's callback runs serially in a separate Julia task, can make nested MCP requests, and has exceptions logged as warnings without failing the request. Pi instead calls handlers synchronously and exposes errors to its error listeners.

Callbacks run serially per request in a separate task, so transport reading and nested requests can continue. A successful response or JSON-RPC error is delivered after previously accepted callbacks finish; a subsequent server disconnect does not replace that response. A timeout, transport failure before the response, interruption, or explicit close discards callbacks still queued. A callback already running cannot be forcibly stopped and may finish later. A callback that never returns delays a successful response, but closing the client or interrupting the caller still releases the request. Unlike Pi's synchronous callbacks, callbacks for different requests may overlap. This slice applies to stdio and notifications in HTTP POST SSE responses, not server-initiated GET streams; JSON POST responses only carry the final result. Resource convenience methods and `RemoteTool` do not expose progress callbacks.

Timeouts and caller-task interruption request `notifications/cancelled`; this is best effort and does not guarantee that the server operation stopped. Interrupting a caller while it waits for a response cleans up the pending request and propagates the interruption. The public API does not yet provide Pi's external abort signal. EOF, malformed or incomplete newline-delimited messages, and explicit close fail unresolved requests. A failed stdio request write fails that request while earlier requests continue reading their responses. If stdout remains open, requests with disabled timers may wait until a response or explicit close. A blocked pipe write itself has no timeout. Server output is not size-limited.

`RemoteTool` maps text content into `ToolResult.text`, serializes other non-image blocks and structured content as JSON text, and propagates `isError`. One direct image block or embedded image resource can also become a native `Image` attachment. Static PNG and JPEG up to 10 MiB are supported, with canonical padded base64, a matching file signature and the same basic PNG structure checks as `Read`. This is not full image decoding or resizing. Multiple images, unsupported MIME types, malformed or invalid base64, mismatched data, animated or structurally unsupported PNG, and oversized images produce an explicit error with no image attachment. Text and other blocks remain in the result; image data remains available in the raw `MCP.call` result. Image annotations and metadata, including an embedded resource's URI, are available only in that raw result. A `[MCP image attached]` or omission marker appears at the image's original position in the joined text. Native history carries the single image separately, so the provider sends it after the joined text rather than preserving interleaving. Providers must support image input; CodeMode still rejects image results.

This is narrower than Pi's `toLlmContent`, which can pass multiple images and unwrap other embedded resources, renders resource links as placeholders, and uses structured content only when content is empty. `RemoteTool` does not validate output schemas. Tool execution may have side effects and the caller controls which tools to expose.

`close(client)` closes child stdin, waits `grace` seconds, sends SIGTERM and then SIGKILL to the direct child if needed, and reaps it. This client does not supervise child process groups or descendants; commands that launch wrappers must arrange their own descendant cleanup. HTTP sessions can be opened with `MCP.connect("http://localhost:3000/mcp"; headers=["Authorization" => "Bearer token"])`. JSON and SSE POST responses are supported; timeouts and close cancel active HTTP operations. Session ID and negotiated protocol version are forwarded, and DELETE is best effort. OAuth, server-initiated GET streams, reconnect and resumption are unsupported; supplied headers are static.

It does not yet implement Windows process-tree shutdown, OAuth, prompt APIs, root-list change notifications, sampling, elicitation, task APIs, reconnect, external cancellation handles, dynamic tool registration, or CLI configuration. It is not full MCP conformance or Pi MCP parity.

Protocol reference: [lifecycle](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle), [stdio transport](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports), [roots](https://modelcontextprotocol.io/specification/2025-11-25/client/roots), [tools](https://modelcontextprotocol.io/specification/2025-11-25/server/tools), and [pagination](https://modelcontextprotocol.io/specification/2025-11-25/server/utilities/pagination). The B1 reference inspected is pinned Pi revision `e7a0df27c09d11bf4161d3605246cbf57a129cb2`, especially `packages/mcp/README.md`, `src/client.ts` and `src/transports/stdio.ts`, `src/transports/streamable-http.ts`, `src/transports/in-memory.ts`, and `src/transports/transport.ts`; this implementation supports a narrower surface.

The internal HTTP request helper now returns `nothing` or `MCP.Failure` rather than a Boolean; the public client API is unchanged.
