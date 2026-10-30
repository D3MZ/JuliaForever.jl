module MCP

using JSON3
import ..JuliaForever: Tool, ToolResult, ToolFailure, name, description, schema, execute

struct Failure
    kind::Symbol
    message::String
    data::Any
end

Failure(kind, message) = Failure(kind, message, nothing)

abstract type Connection end
struct Connecting <: Connection end
struct Open <: Connection end
struct Closed <: Connection end

state(::Connecting) = :connecting
state(::Open) = :open
state(::Closed) = :closed

mutable struct Client
    process::Base.Process
    lock::ReentrantLock
    writer::ReentrantLock
    pending::Dict{Int, Channel{Any}}
    nextid::Int
    connection::Connection
    server::Any
    timeout::Float64
    grace::Float64
    shutting::Bool
    done::Base.Event
    reader::Union{Nothing, Task}
end

function Base.getproperty(client::Client, name::Symbol)
    name === :state && return state(getfield(client, :connection))
    getfield(client, name)
end

Base.propertynames(client::Client, private::Bool=false) = (fieldnames(typeof(client))..., :state)

const versions = ("2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05")

function send(client::Client, message)
    lock(client.writer) do
        connection = lock(() -> client.connection, client.lock)
        send(client, message, connection)
    end
end

send(client::Client, message, ::Closed) = false

function send(client::Client, message, ::Connection)
    try
        println(client.process, JSON3.write(message))
        flush(client.process)
        true
    catch
        false
    end
end

function fail!(client::Client, failure::Failure)
    channels = lock(client.lock) do
        takepending!(client, client.connection)
    end
    foreach(channel -> put!(channel, failure), channels)
    @async shutdown(client)
    nothing
end

takepending!(client::Client, ::Closed) = Channel{Any}[]

function takepending!(client::Client, ::Connection)
    client.connection = Closed()
    channels = collect(values(client.pending))
    empty!(client.pending)
    channels
end

function shutdown(client::Client)
    owner = lock(client.lock) do
        client.shutting && return false
        client.shutting = true
        true
    end
    if !owner
        wait(client.done)
        return nothing
    end
    try
        try
            close(client.process.in)
        catch
        end
        if timedwait(() -> process_exited(client.process), client.grace; pollint=0.01) != :ok
            try
                kill(client.process, Base.SIGTERM)
            catch
            end
            if timedwait(() -> process_exited(client.process), client.grace; pollint=0.01) != :ok
                try
                    kill(client.process, Base.SIGKILL)
                catch
                end
            end
        end
        wait(client.process)
        try
            close(client.process.out)
        catch
        end
        isnothing(client.reader) || wait(client.reader)
    finally
        notify(client.done)
    end
    nothing
end

function Base.close(client::Client)
    fail!(client, Failure(:closed, "MCP connection closed"))
    shutdown(client)
end

function received(client::Client, message)
    message isa AbstractDict && get(message, "jsonrpc", nothing) == "2.0" || return false
    if haskey(message, "method")
        method = message["method"]
        method isa AbstractString || return false
        if haskey(message, "id")
            id = message["id"]
            (id isa AbstractString || (id isa Integer && !(id isa Bool))) || return false
            response = method == "ping" ? Dict("jsonrpc" => "2.0", "id" => id, "result" => Dict()) : Dict("jsonrpc" => "2.0", "id" => id, "error" => Dict("code" => -32601, "message" => "Method not found"))
            send(client, response) || return false
        end
        return true
    end
    haskey(message, "id") || return false
    id = message["id"]
    (id isa AbstractString || (id isa Integer && !(id isa Bool))) || return false
    (haskey(message, "result") != haskey(message, "error")) || return false
    channel = lock(() -> pop!(client.pending, id, nothing), client.lock)
    isnothing(channel) && return true
    if haskey(message, "error")
        detail = message["error"]
        if detail isa AbstractDict && get(detail, "code", nothing) isa Integer && !(detail["code"] isa Bool) && get(detail, "message", nothing) isa AbstractString
            put!(channel, Failure(:rpc, detail["message"], detail))
        else
            put!(channel, Failure(:protocol, "Invalid JSON-RPC error"))
        end
    else
        put!(channel, message["result"])
    end
    true
end

function readmessages(client::Client)
    try
        for line in eachline(client.process.out; keep=true)
            if !endswith(line, '\n')
                fail!(client, Failure(:protocol, "Incomplete JSON-RPC message"))
                return
            end
            message = try
                JSON3.read(line, Dict{String, Any})
            catch
                fail!(client, Failure(:protocol, "Invalid JSON-RPC message"))
                return
            end
            if !received(client, message)
                fail!(client, Failure(:protocol, "Invalid JSON-RPC message"))
                return
            end
        end
        fail!(client, Failure(:closed, "MCP server closed its output"))
    catch exception
        fail!(client, Failure(:transport, sprint(showerror, exception)))
    end
end

admit(::Connection, ::Connection) = false
admit(::Connecting, ::Connecting) = true
admit(::Open, ::Connection) = true

request(client::Client, method, params; timeout=client.timeout) = request(client, method, params, Open(); timeout)

function request(client::Client, method, params, required::Connection; timeout=client.timeout)
    id, channel = lock(client.lock) do
        admit(client.connection, required) || return nothing, nothing
        client.nextid += 1
        channel = Channel{Any}(1)
        client.pending[client.nextid] = channel
        client.nextid, channel
    end
    isnothing(id) && return Failure(:closed, "MCP connection is not open")
    message = Dict("jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params)
    send(client, message) || fail!(client, Failure(:transport, "Could not write to MCP server"))
    timer = Timer(timeout) do _
        pending, connection = lock(client.lock) do
            pop!(client.pending, id, nothing), client.connection
        end
        expire!(client, id, pending, connection)
    end
    result = take!(channel)
    close(timer)
    result
end

expire!(client::Client, id, ::Nothing, connection::Connection) = nothing

function expire!(client::Client, id, pending::Channel, connection::Connection)
    cancelrequest!(client, id, connection)
    put!(pending, Failure(:timeout, "MCP request timed out"))
end

cancelrequest!(client::Client, id, ::Connection) = nothing
cancelrequest!(client::Client, id, ::Open) = send(client, Dict("jsonrpc" => "2.0", "method" => "notifications/cancelled", "params" => Dict("requestId" => id, "reason" => "Request timed out"))) || fail!(client, Failure(:transport, "Could not write to MCP server"))

activate!(client::Client, ::Connection) = false

function activate!(client::Client, ::Connecting)
    client.connection = Open()
    true
end

function connect(command::Cmd; timeout=30.0, grace=0.5)
    process = try
        open(pipeline(command; stderr=stderr), "r+")
    catch exception
        return Failure(:start, sprint(showerror, exception))
    end
    client = Client(process, ReentrantLock(), ReentrantLock(), Dict{Int, Channel{Any}}(), 0, Connecting(), nothing, Float64(timeout), Float64(grace), false, Base.Event(), nothing)
    client.reader = @async readmessages(client)
    params = Dict("protocolVersion" => first(versions), "capabilities" => Dict(), "clientInfo" => Dict("name" => "JuliaForever", "version" => "0.1.0"))
    initialize!(client, request(client, "initialize", params, Connecting()))
end

function initialize!(client::Client, failure::Failure)
    close(client)
    failure
end

function invalid!(client::Client)
    close(client)
    Failure(:protocol, "Invalid or unsupported MCP initialization result")
end

initialize!(client::Client, result) = invalid!(client)

function initialize!(client::Client, result::AbstractDict)
    get(result, "protocolVersion", nothing) in versions && get(result, "capabilities", nothing) isa AbstractDict && get(result["capabilities"], "tools", Dict()) isa AbstractDict && get(result, "serverInfo", nothing) isa AbstractDict && get(result["serverInfo"], "name", nothing) isa AbstractString && get(result["serverInfo"], "version", nothing) isa AbstractString || return invalid!(client)
    client.server = result
    if !send(client, Dict("jsonrpc" => "2.0", "method" => "notifications/initialized"))
        close(client)
        return Failure(:transport, "Could not finish MCP initialization")
    end
    opened = lock(client.lock) do
        activate!(client, client.connection)
    end
    opened || return Failure(:closed, "MCP connection closed during initialization")
    client
end

function call(client::Client, tool::AbstractString, args; timeout=client.timeout)
    haskey(client.server["capabilities"], "tools") || return Failure(:capability, "MCP server did not advertise tools")
    toolresponse(request(client, "tools/call", Dict("name" => tool, "arguments" => args); timeout))
end

toolresponse(failure::Failure) = failure
toolresponse(result) = Failure(:protocol, "Invalid MCP tools/call result")

function toolresponse(result::AbstractDict)
    (!haskey(result, "content") || result["content"] isa AbstractVector) && (!haskey(result, "isError") || result["isError"] isa Bool) && (haskey(result, "content") || haskey(result, "structuredContent")) || return Failure(:protocol, "Invalid MCP tools/call result")
    result
end

struct RemoteTool <: Tool
    client::Client
    remote::String
    alias::String
    doc::String
    parameters::AbstractDict
end

name(tool::RemoteTool) = tool.alias
description(tool::RemoteTool) = tool.doc
schema(tool::RemoteTool) = tool.parameters

execute(tool::RemoteTool, args) = toolresult(call(tool.client, tool.remote, args))
toolresult(result::Failure) = ToolFailure("MCP $(result.kind): $(result.message)")

const contenttypes = Dict("text" => String)
content!(content, block) = push!(content, JSON3.write(block))
content!(content, block::AbstractDict) = content!(content, block, get(contenttypes, get(block, "type", nothing), nothing))
content!(content, block, ::Nothing) = push!(content, JSON3.write(block))
content!(content, block, ::Type{String}) = text!(content, block, get(block, "text", nothing))
text!(content, block, text::AbstractString) = push!(content, text)
text!(content, block, value) = push!(content, JSON3.write(block))

function toolresult(result::AbstractDict)
    content = String[]
    for block in get(result, "content", [])
        content!(content, block)
    end
    haskey(result, "structuredContent") && push!(content, JSON3.write(result["structuredContent"]))
    ToolResult(join(content, "\n"), get(result, "isError", false))
end

cursorparams(::Nothing) = Dict()
cursorparams(cursor::AbstractString) = Dict("cursor" => cursor)

function tools(client::Client; prefix="mcp_")
    haskey(client.server["capabilities"], "tools") || return Failure(:capability, "MCP server did not advertise tools")
    found = RemoteTool[]
    aliases = Set{String}()
    cursors = Set{String}()
    cursor = nothing
    for _ in 1:1000
        params = cursorparams(cursor)
        page = request(client, "tools/list", params)
        page isa Failure && return page
        page isa AbstractDict && get(page, "tools", nothing) isa AbstractVector || return Failure(:protocol, "Invalid MCP tools/list result")
        for item in page["tools"]
            item isa AbstractDict && get(item, "name", nothing) isa AbstractString && get(item, "inputSchema", nothing) isa AbstractDict || return Failure(:protocol, "Invalid MCP tool definition")
            remote = String(item["name"])
            execution = get(item, "execution", Dict())
            execution isa AbstractDict || return Failure(:protocol, "Invalid MCP tool execution metadata")
            support = get(execution, "taskSupport", "forbidden")
            support in ("forbidden", "optional", "required") || return Failure(:protocol, "Invalid MCP task support")
            support == "required" && return Failure(:capability, "MCP tool $remote requires unsupported task execution")
            alias = first(replace(prefix * remote, r"[^A-Za-z0-9_-]" => "_"), 64)
            alias in aliases && return Failure(:protocol, "MCP tool names collide after adaptation")
            doc = get(item, "description", remote)
            doc isa AbstractString || return Failure(:protocol, "Invalid MCP tool description")
            push!(aliases, alias)
            push!(found, RemoteTool(client, remote, alias, String(doc), item["inputSchema"]))
        end
        haskey(page, "nextCursor") || return found
        cursor = page["nextCursor"]
        cursor isa AbstractString || return Failure(:protocol, "Invalid MCP tools/list cursor")
        cursor in cursors && return Failure(:protocol, "Repeated MCP tools/list cursor")
        push!(cursors, cursor)
    end
    Failure(:protocol, "MCP tools/list exceeded 1000 pages")
end

end
