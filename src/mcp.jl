module MCP

using JSON3
import HTTP
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

mutable struct HttpTransport
    url::String
    headers::Vector{Pair{String, String}}
    session::String
    version::String
end

mutable struct Client
    process::Union{Base.Process, HttpTransport}
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

send(client::Client, message, connection::Connection) = send(client, message, client.process)

function send(client::Client, message, process::Base.Process)
    try
        println(process, JSON3.write(message))
        flush(process)
        true
    catch
        false
    end
end

function httpheaders(transport::HttpTransport)
    headers = copy(transport.headers)
    push!(headers, "Accept" => "application/json, text/event-stream", "Content-Type" => "application/json")
    isempty(transport.session) || push!(headers, "Mcp-Session-Id" => transport.session)
    isempty(transport.version) || push!(headers, "MCP-Protocol-Version" => transport.version)
    headers
end

function httprequest(client::Client, transport::HttpTransport, message)
    try
        response = HTTP.request("POST", transport.url, httpheaders(transport), JSON3.write(message); status_exception=false, request_timeout=client.timeout, retry=false)
        200 <= response.status < 300 || return httpfailure!(client, message, Failure(:http, "MCP HTTP status $(response.status)", response.status))
        session = HTTP.header(response, "Mcp-Session-Id", "")
        isempty(session) || (transport.session = session)
        haskey(message, "id") || return true
        type = lowercase(strip(first(split(HTTP.header(response, "Content-Type", ""), ';'))))
        type == "application/json" || return httpfailure!(client, message, Failure(:protocol, "Unsupported MCP HTTP response content type: $type"))
        value = JSON3.read(String(response.body), Dict{String, Any})
        received(client, value) || return httpfailure!(client, message, Failure(:protocol, "Invalid JSON-RPC message"))
        true
    catch exception
        httpfailure!(client, message, Failure(:transport, sprint(showerror, exception)))
    end
end

function httpfailure!(client::Client, message, failure::Failure)
    haskey(message, "id") || return false
    channel = lock(() -> pop!(client.pending, message["id"], nothing), client.lock)
    isnothing(channel) || put!(channel, failure)
    true
end

function send(client::Client, message, transport::HttpTransport)
    haskey(message, "id") && haskey(message, "method") && (@async httprequest(client, transport, message); return true)
    httprequest(client, transport, message)
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

shutdown(client::Client) = shutdown(client, client.process)

function shutdown(client::Client, transport::HttpTransport)
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
        isempty(transport.session) || HTTP.request("DELETE", transport.url, httpheaders(transport); status_exception=false, request_timeout=1, retry=false)
    catch
    finally
        notify(client.done)
    end
    nothing
end

function shutdown(client::Client, process::Base.Process)
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

function connect(url::AbstractString; timeout=30.0, headers=Pair{String, String}[])
    transport = HttpTransport(String(url), Pair{String, String}[String(k) => String(v) for (k, v) in headers], "", "")
    client = Client(transport, ReentrantLock(), ReentrantLock(), Dict{Int, Channel{Any}}(), 0, Connecting(), nothing, Float64(timeout), 0.0, false, Base.Event(), nothing)
    params = Dict("protocolVersion" => first(versions), "capabilities" => Dict(), "clientInfo" => Dict("name" => "JuliaForever", "version" => "0.1.0"))
    initialize!(client, request(client, "initialize", params, Connecting()))
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

protocol!(::Base.Process, version) = nothing
protocol!(transport::HttpTransport, version) = (transport.version = version)

function invalid!(client::Client)
    close(client)
    Failure(:protocol, "Invalid or unsupported MCP initialization result")
end

initialize!(client::Client, result) = invalid!(client)

function initialize!(client::Client, result::AbstractDict)
    get(result, "protocolVersion", nothing) in versions && get(result, "capabilities", nothing) isa AbstractDict && get(result["capabilities"], "tools", Dict()) isa AbstractDict && get(result, "serverInfo", nothing) isa AbstractDict && get(result["serverInfo"], "name", nothing) isa AbstractString && get(result["serverInfo"], "version", nothing) isa AbstractString || return invalid!(client)
    client.server = result
    protocol!(client.process, result["protocolVersion"])
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

abstract type Listing end
struct Resources <: Listing end
struct Templates <: Listing end

method(::Resources) = "resources/list"
method(::Templates) = "resources/templates/list"
key(::Resources) = "resources"
key(::Templates) = "resourceTemplates"
identifier(::Resources) = "uri"
identifier(::Templates) = "uriTemplate"

struct Page
    items::Vector{Dict{String, Any}}
    cursor::Union{Nothing, String}
end

available(value) = false
available(::AbstractDict) = true
capability(client::Client) = get(client.server["capabilities"], "resources", nothing)
resourcecapability(client::Client) = resourcecapability(capability(client))
resourcecapability(value) = Failure(:capability, "MCP server did not advertise resources")
resourcecapability(::AbstractDict) = nothing

invalidpage(list::Listing) = Failure(:protocol, "Invalid MCP $(method(list)) result")
invalidentry(list::Listing) = Failure(:protocol, "Invalid entry in MCP $(method(list)) result")
invalidcursor(list::Listing) = Failure(:protocol, "Invalid MCP $(method(list)) cursor")

entry(list::Listing, item) = invalidentry(list)
entry(list::Listing, item::AbstractDict) = entry(list, item, get(item, identifier(list), nothing))
entry(list::Listing, item, uri) = invalidentry(list)
entry(list::Listing, item, uri::AbstractString) = entry(list, item, uri, get(item, "name", uri))
entry(list::Listing, item, uri, name) = invalidentry(list)
entry(list::Listing, item, uri::AbstractString, name::AbstractString) = merge(Dict{String, Any}(item), Dict("name" => String(name)))

addentry!(items::Vector{Dict{String, Any}}, item::Dict{String, Any}) = (push!(items, item); items)
addentry!(items::Vector{Dict{String, Any}}, failure::Failure) = failure
addentry!(failure::Failure, item) = failure
entries(list::Listing, items) = invalidpage(list)
entries(list::Listing, items::AbstractVector) = foldl((found, item) -> addentry!(found, entry(list, item)), items; init=Dict{String, Any}[])

pagecursor(list::Listing, value) = invalidcursor(list)
pagecursor(list::Listing, ::Nothing) = nothing
pagecursor(list::Listing, value::AbstractString) = isempty(value) ? nothing : String(value)

parsepage(list::Listing, failure::Failure) = failure
parsepage(list::Listing, value) = invalidpage(list)
parsepage(list::Listing, value::AbstractDict) = pageitems(list, entries(list, get(value, key(list), nothing)), get(value, "nextCursor", nothing))
pageitems(list::Listing, failure::Failure, cursor) = failure
pageitems(list::Listing, items::Vector{Dict{String, Any}}, cursor) = pagevalue(list, items, pagecursor(list, cursor))
pagevalue(list::Listing, items, failure::Failure) = failure
pagevalue(list::Listing, items, cursor::Union{Nothing, String}) = Page(items, cursor)

fetchpage(client::Client, list::Listing, cursor; timeout=client.timeout) = fetchpage(client, list, cursor, resourcecapability(client); timeout)
fetchpage(client::Client, list::Listing, cursor, failure::Failure; timeout) = failure
fetchpage(client::Client, list::Listing, cursor, ::Nothing; timeout) = parsepage(list, request(client, method(list), cursorparams(cursor); timeout))

pageobject(list::Listing, failure::Failure) = failure
pageobject(list::Listing, page::Page) = pageobject!(Dict{String, Any}(key(list) => page.items), page.cursor)
pageobject!(result, ::Nothing) = result
pageobject!(result, cursor::String) = (result["nextCursor"] = cursor; result)

resourcepage(client::Client, cursor::Union{Nothing, AbstractString}=nothing; timeout=client.timeout) = pageobject(Resources(), fetchpage(client, Resources(), cursor; timeout))
templatepage(client::Client, cursor::Union{Nothing, AbstractString}=nothing; timeout=client.timeout) = pageobject(Templates(), fetchpage(client, Templates(), cursor; timeout))

function listall(client::Client, list::Listing; timeout=client.timeout)
    listall(client, list, Dict{String, Any}[], Set{String}(), nothing, 1; timeout)
end

function listall(client::Client, list::Listing, items, cursors, cursor, count; timeout)
    count > 1000 && return Failure(:protocol, "MCP $(method(list)) exceeded 1000 pages")
    collectpage(client, list, items, cursors, count, fetchpage(client, list, cursor; timeout); timeout)
end

collectpage(client::Client, list::Listing, items, cursors, count, failure::Failure; timeout) = failure
function collectpage(client::Client, list::Listing, items, cursors, count, page::Page; timeout)
    append!(items, page.items)
    nextpage(client, list, items, cursors, count, page.cursor; timeout)
end
nextpage(client::Client, list::Listing, items, cursors, count, ::Nothing; timeout) = items
function nextpage(client::Client, list::Listing, items, cursors, count, cursor::String; timeout)
    cursor in cursors && return Failure(:protocol, "MCP $(method(list)) returned duplicate cursor: $cursor")
    push!(cursors, cursor)
    listall(client, list, items, cursors, cursor, count + 1; timeout)
end

resources(client::Client; timeout=client.timeout) = listall(client, Resources(); timeout)
templates(client::Client; timeout=client.timeout) = listall(client, Templates(); timeout)

stringvalue(value) = false
stringvalue(::AbstractString) = true
validcontent(value) = false
validcontent(value::AbstractDict) = stringvalue(get(value, "uri", nothing)) && (stringvalue(get(value, "text", nothing)) || stringvalue(get(value, "blob", nothing)))
readresponse(failure::Failure) = failure
readresponse(value) = Failure(:protocol, "Invalid MCP resources/read result")
readresponse(value::AbstractDict) = readcontents(value, get(value, "contents", nothing))
readcontents(value, contents) = Failure(:protocol, "Invalid MCP resources/read result")
readcontents(value, contents::AbstractVector) = all(validcontent, contents) ? value : Failure(:protocol, "Invalid contents in MCP resources/read result")

Base.read(client::Client, uri::AbstractString; timeout=client.timeout) = readresource(client, uri, resourcecapability(client); timeout)
readresource(client::Client, uri, failure::Failure; timeout) = failure
readresource(client::Client, uri, ::Nothing; timeout) = readresponse(request(client, "resources/read", Dict("uri" => uri); timeout))

struct ListResources{L<:Listing} <: Tool
    servers::Dict{String, Client}
end
struct ReadResource <: Tool
    servers::Dict{String, Client}
end

listing(::ListResources{L}) where L = L()
name(::ListResources{Resources}) = "list_mcp_resources"
name(::ListResources{Templates}) = "list_mcp_resource_templates"
name(::ReadResource) = "read_mcp_resource"
description(::ListResources{Resources}) = "List resources provided by MCP servers."
description(::ListResources{Templates}) = "List parameterized resource templates provided by MCP servers."
description(::ReadResource) = "Read a resource from an MCP server by server name and URI."
schema(::ListResources) = Dict("type" => "object", "properties" => Dict("server" => Dict("type" => "string"), "cursor" => Dict("type" => "string")), "additionalProperties" => false)
schema(::ReadResource) = Dict("type" => "object", "properties" => Dict("server" => Dict("type" => "string"), "uri" => Dict("type" => "string")), "required" => ["server", "uri"], "additionalProperties" => false)

function resourcetools(servers::AbstractDict{<:AbstractString, <:Client})
    selected = Dict{String, Client}(String(name) => client for (name, client) in servers if available(capability(client)))
    isempty(selected) && return Tool[]
    Tool[ListResources{Resources}(selected), ListResources{Templates}(selected), ReadResource(selected)]
end

argument(value) = value
argument(::Nothing) = nothing
function argument(value::AbstractString)
    cleaned = strip(value)
    isempty(cleaned) ? nothing : String(cleaned)
end

execute(tool::ListResources, args) = listtool(tool, argument(get(args, :server, nothing)), argument(get(args, :cursor, nothing)))
listtool(tool::ListResources, server, cursor) = ToolFailure("server and cursor must be strings")
listtool(tool::ListResources, ::Nothing, cursor::AbstractString) = ToolFailure("cursor can only be used when a server is specified")
listtool(tool::ListResources, ::Nothing, ::Nothing) = listservers(tool)
listtool(tool::ListResources, server::AbstractString, cursor::Union{Nothing, AbstractString}) = listserver(tool, server, cursor, get(tool.servers, server, nothing))

missingserver(tool, server) = ToolFailure("MCP server \"$server\" has no resources" * (isempty(tool.servers) ? "" : ". Servers with resources: " * join(sort!(collect(keys(tool.servers))), ", ")))
listserver(tool::ListResources, server, cursor, ::Nothing) = missingserver(tool, server)
function listserver(tool::ListResources, server, cursor, client::Client)
    list = listing(tool)
    page = fallback(list, fetchpage(client, list, cursor), Page(Dict{String, Any}[], nothing))
    listresult(list, server, page)
end
listresult(list::Listing, server, failure::Failure) = toolresult(failure)
function listresult(list::Listing, server, page::Page)
    result = Dict{String, Any}("server" => server, key(list) => listed(server, page.items))
    ToolResult(JSON3.write(pageobject!(result, page.cursor)))
end

function listservers(tool::ListResources)
    list = listing(tool)
    servers = sort!(collect(keys(tool.servers)))
    jobs = [@async listall(tool.servers[server], list) for server in servers]
    items = Dict{String, Any}[]
    failures = Dict{String, String}[]
    for (server, job) in zip(servers, jobs)
        result = fallback(list, fetch(job), Dict{String, Any}[])
        collectlisting!(items, failures, server, result)
    end
    result = Dict{String, Any}(key(list) => items)
    isempty(failures) || (result["errors"] = failures)
    ToolResult(JSON3.write(result))
end
collectlisting!(items, failures, server, result::Vector{Dict{String, Any}}) = append!(items, listed(server, result))
collectlisting!(items, failures, server, failure::Failure) = push!(failures, Dict("server" => server, "error" => failure.message))

fallback(list::Listing, result, empty) = result
fallback(::Templates, failure::Failure, empty) = fallback(failure, failure.data, empty)
fallback(failure::Failure, data, empty) = failure
fallback(failure::Failure, data::AbstractDict, empty) = get(data, "code", nothing) == -32601 ? empty : failure

apptype(value) = false
apptype(value::AbstractString) = occursin(r";\s*profile\s*=\s*\"?mcp-app\"?"i, value)
function visible(item)
    uri = get(item, "uri", get(item, "uriTemplate", ""))
    !startswith(uri, "ui://") && !apptype(get(item, "mimeType", ""))
end
function listed(server, items)
    [merge(filter(pair -> first(pair) ∉ ("_meta", "icons"), item), Dict{String, Any}("server" => server)) for item in items if visible(item)]
end

execute(tool::ReadResource, args) = readtool(tool, argument(get(args, :server, nothing)), argument(get(args, :uri, nothing)))
readtool(tool::ReadResource, server, uri) = ToolFailure("server and uri must be provided as strings")
readtool(tool::ReadResource, server::AbstractString, uri::AbstractString) = readserver(tool, server, uri, get(tool.servers, server, nothing))
readserver(tool::ReadResource, server, uri, ::Nothing) = missingserver(tool, server)
readserver(tool::ReadResource, server, uri, client::Client) = readresult(uri, read(client, uri))
readresult(uri, failure::Failure) = toolresult(failure)
readresult(uri, result::AbstractDict) = typedcontents(uri, result["contents"])
typedcontents(uri, contents::AbstractVector) = readcontent(uri, Dict{String, Any}[item for item in contents])
function readcontent(uri::AbstractString, contents::Vector{Dict{String, Any}})
    isempty(contents) && return ToolResult("Resource $uri is empty.")
    length(contents) == 1 && return ToolResult(resourcetext(only(contents)))
    ToolResult(join([string(item["uri"], ":\n", resourcetext(item)) for item in contents], "\n"))
end
resourcetext(item)::String = resourcetext(item, get(item, "text", nothing))
resourcetext(item, text::AbstractString) = String(text)
resourcetext(item, value) = JSON3.write(filter(pair -> first(pair) != "_meta", item))

end
