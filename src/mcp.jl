module MCP

using JSON3, Base64
import HTTP, JSON
import ..JuliaForever: Tool, ToolResult, ToolFailure, tooltype, Image, imagelimit, imageformat, imageproblem, name, description, schema, execute

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

abstract type Shutdown end
struct ShutdownReady <: Shutdown end
struct ShuttingDown <: Shutdown end
shutdownstate(value::Bool) = (ShutdownReady(), ShuttingDown())[Int(value) + 1]
shutting(::ShutdownReady) = false
shutting(::ShuttingDown) = true

mutable struct HttpTransport
    url::String
    headers::Vector{Pair{String, String}}
    session::String
    version::String
    requests::Dict{Int, HTTP.RequestContext}
    getcontext::HTTP.RequestContext
    replies::Dict{HTTP.RequestContext, Task}
    roots::Set{Task}
end

struct NoRoots end
struct Roots{T}
    value::T
end

rootsource(::Nothing) = NoRoots()
rootsource(value) = Roots(value)
rootvalues(values::AbstractVector) = values
rootvalues(callback) = callback()
rootcapabilities(::NoRoots) = Dict{String, Any}()
rootcapabilities(::Roots) = Dict("roots" => Dict{String, Any}())

struct NoProgress end
mutable struct Progress{F}
    callback::F
    queue::Channel{Any}
    task::Union{Nothing, Task}
end
struct Finishing{P<:Progress}
    progress::P
end

progress(::Nothing) = NoProgress()
progress(callback) = Progress(callback, Channel{Any}(Inf), nothing)

mutable struct Pending
    result::Channel{Any}
    progress::Union{NoProgress, Progress, Finishing}
    timeout::Float64
    timer::Union{Nothing, Timer}
    generation::Int
end

mutable struct Client{R}
    process::Union{Base.Process, HttpTransport}
    lock::ReentrantLock
    writer::ReentrantLock
    pending::Dict{Int, Pending}
    nextid::Int
    connection::Connection
    server::Any
    timeout::Float64
    grace::Float64
    shutdown::Shutdown
    done::Base.Event
    reader::Union{Nothing, Task}
    roots::R
end

Client(process, lock, writer, pending, nextid, connection, server, timeout, grace, shutting::Bool, done, reader, roots) = Client(process, lock, writer, pending, nextid, connection, server, timeout, grace, shutdownstate(shutting), done, reader, roots)

function Base.getproperty(client::Client, name::Symbol)
    name === :state && return state(getfield(client, :connection))
    name === :shutting && return shutting(getfield(client, :shutdown))
    getfield(client, name)
end

function Base.setproperty!(client::Client, name::Symbol, value)
    name === :shutting && return (setfield!(client, :shutdown, shutdownstate(convert(Bool, value))); value)
    setfield!(client, name, convert(fieldtype(typeof(client), name), value))
end

Base.propertynames(client::Client, private::Bool=false) = (fieldnames(typeof(client))..., :state, :shutting)

const versions = ("2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05")

function send(client::Client, message)
    lock(client.writer) do
        connection = lock(() -> client.connection, client.lock)
        send(client, message, connection)
    end
end

function sendrequest(client::Client, message, id)
    lock(client.writer) do
        pending, connection = lock(client.lock) do
            get(client.pending, id, nothing), client.connection
        end
        sendrequest(client, message, pending, connection)
    end
end
sendrequest(client::Client, message, ::Nothing, connection) = nothing
sendrequest(client::Client, message, ::Pending, connection) = send(client, message, connection)

send(client::Client, message, ::Closed) = Failure(:closed, "MCP connection is not open")

send(client::Client, message, connection::Connection) = send(client, message, client.process)

function send(client::Client, message, process::Base.Process)
    try
        println(process, JSON3.write(message))
        flush(process)
        nothing
    catch
        Failure(:transport, "Could not write to MCP server")
    end
end

transmitted!(client::Client, ::Nothing) = nothing
transmitted!(client::Client, failure::Failure) = transmitted!(client, failure, client.process)
# A failed stdin write does not imply stdout is drained. The reader owns EOF.
transmitted!(client::Client, ::Failure, ::Base.Process) = nothing
transmitted!(client::Client, ::Failure, ::HttpTransport) = fail!(client, Failure(:transport, "Could not write to MCP server"))
transmitted!(client::Client, ::Nothing, id::Int) = nothing
function transmitted!(client::Client, failure::Failure, id::Int)
    pending = lock(() -> writefailed!(client, id, get(client.pending, id, nothing)), client.lock)
    deliver!(pending, failure)
    nothing
end
writefailed!(client, id, ::Nothing) = nothing
writefailed!(client, id, pending::Pending) = writefailed!(client, id, pending.progress)
writefailed!(client, id, ::Finishing) = nothing
writefailed!(client, id, progress::Union{NoProgress, Progress}) = retire!(client, id)

function httpheaders(transport::HttpTransport)
    headers = copy(transport.headers)
    push!(headers, "Accept" => "application/json, text/event-stream", "Content-Type" => "application/json")
    isempty(transport.session) || push!(headers, "Mcp-Session-Id" => transport.session)
    isempty(transport.version) || push!(headers, "MCP-Protocol-Version" => transport.version)
    headers
end

include("mcp_json.jl")

function ssemessage!(client::Client, data, event, id)
    (isempty(data) || !(event in ("", "message"))) && return false
    ssereply(client, jsonmessage(join(data, "\n")), id)
end
ssereply(client, invalid::InvalidMessage, id) = false
function ssereply(client, value::AbstractDict, id)
    value = validmessage(value)
    received(client, value) || return false
    get(value, "id", nothing) == id && !haskey(value, "method")
end

struct ServerStream end
function servermessage!(client::Client, data, event)
    (isempty(data) || !(event in ("", "message"))) && return nothing
    try
        received(client, validmessage(jsonmessage(join(data, "\n"))))
    catch
    end
    nothing
end

const sselimit = 16 * 1024 * 1024

sseevent!(client, data, event, id) = ssemessage!(client, data, event, id) ? id : nothing
sseevent!(client, data, event, ::ServerStream) = servermessage!(client, data, event)

sseend(::Nothing, chunk) = length(chunk) + 1
sseend(index::Int, chunk) = index

abstract type StreamReceipt end
struct NoEvents <: StreamReceipt end
struct EventsReceived <: StreamReceipt end
abstract type StreamValidity end
struct ValidStream <: StreamValidity end
struct InvalidStream <: StreamValidity end

mutable struct StreamCursor
    id::Union{Nothing, String}
    retry::Union{Nothing, Float64}
    received::StreamReceipt
    validity::StreamValidity
end
StreamCursor() = StreamCursor(nothing, nothing, NoEvents(), ValidStream())

retrydelay!(cursor, ::Nothing) = nothing
retrydelay!(cursor, delay::Float64) = (cursor.retry = delay / 1000; nothing)

function sseread!(client, stream, id, cursor=StreamCursor())
    data = String[]
    bytes = UInt8[]
    size = 0
    event = ""
    function line!()
        line = String(copy(bytes))
        empty!(bytes)
        endswith(line, '\r') && (line = chop(line; tail=1))
        if isempty(line)
            isempty(data) || (cursor.received = EventsReceived())
            sseevent!(client, data, event, id) == id && return 1
            empty!(data)
            size = 0
            event = ""
        elseif !startswith(line, ':')
            parts = split(line, ':'; limit=2)
            field = parts[1]
            value = length(parts) == 2 ? parts[2] : ""
            startswith(value, ' ') && (value = value[2:end])
            if field == "data"
                size += ncodeunits(value) + !isempty(data)
                size > sselimit && (cursor.validity = InvalidStream(); return -1)
                push!(data, value)
            elseif field == "event"
                event = value
            elseif field == "id" && !occursin('\0', value)
                cursor.id = String(value)
            elseif field == "retry" && occursin(r"^[0-9]+$", value)
                delay = tryparse(Float64, value)
                retrydelay!(cursor, delay)
            end
        end
        0
    end
    while !eof(stream)
        chunk = readavailable(stream)
        start = 1
        while start <= length(chunk)
            newline = sseend(findnext(==(0x0a), chunk, start), chunk)
            stop = newline - 1
            length(bytes) + stop - start + 1 > sselimit && (cursor.validity = InvalidStream(); return false)
            append!(bytes, @view chunk[start:stop])
            newline > length(chunk) && break
            result = line!()
            result != 0 && return result > 0
            start = newline + 1
        end
    end
    if !isempty(bytes)
        result = line!()
        result != 0 && return result > 0
    end
    sseevent!(client, data, event, id) == id
end

httptimeout(::Nothing, client::Client) = isfinite(client.timeout) && client.timeout > 0 ? client.timeout : 0
httptimeout(id, client::Client) = 0

function httprequest(client::Client, transport::HttpTransport, message)
    id = haskey(message, "method") ? get(message, "id", nothing) : nothing
    context = HTTP.RequestContext()
    httprequest(client, transport, message, id, admit!(client, transport, id, context))
end

abstract type StreamResult end
struct StreamStopped <: StreamResult end
struct StreamRunning <: StreamResult end
struct StreamRetry <: StreamResult end
struct StreamEnded <: StreamResult end
struct StreamAnswered <: StreamResult end

streamstate(client, id) = lock(() -> streamstate(client, id, client.connection), client.lock)
streamstate(client, id, ::Closed) = StreamStopped()
streamstate(client, ::ServerStream, ::Closed) = StreamStopped()
streamstate(client, ::ServerStream, ::Connection) = StreamRunning()
streamstate(client, id, ::Connection) = streamstate(get(client.pending, id, nothing))
streamstate(::Nothing) = StreamStopped()
streamstate(pending::Pending) = streamstate(pending.progress)
streamstate(::Finishing) = StreamStopped()
streamstate(::Union{NoProgress, Progress}) = StreamRunning()

streamcontext!(client, transport, id, context, ::Closed) = StreamStopped()
streamcontext!(client, transport, ::ServerStream, context, ::Closed) = StreamStopped()
streamcontext!(client, transport, ::ServerStream, context, ::Connection) = (transport.getcontext = context; StreamRunning())
streamcontext!(client, transport, id, context, ::Connection) = streamcontext!(transport, id, context, get(client.pending, id, nothing))
streamcontext!(transport, id, context, ::Nothing) = StreamStopped()
streamcontext!(transport, id, context, pending::Pending) = streamcontext!(transport, id, context, pending.progress)
streamcontext!(transport, id, context, ::Finishing) = StreamStopped()
streamcontext!(transport, id, context, ::Union{NoProgress, Progress}) = (transport.requests[id] = context; StreamRunning())

retryfailure(::Exception) = StreamStopped()
retryfailure(::Union{HTTP.HTTPError, EOFError, Base.IOError, SystemError}) = StreamRetry()
reconnectdelay(::Nothing, attempt) = min(2.0^attempt, 30.0)
reconnectdelay(delay::Float64, attempt) = delay
cursorheader!(headers, ::Nothing) = headers
cursorheader!(headers, id::String) = (push!(headers, "Last-Event-ID" => id); headers)
streamresult(answered::Bool) = (StreamEnded(), StreamAnswered())[Int(answered) + 1]
streamresult(result, ::InvalidStream) = StreamStopped()
streamresult(result, ::ValidStream) = result

function openstream!(client, transport, id, cursor)
    context = HTTP.RequestContext()
    state = lock(() -> streamcontext!(client, transport, id, context, client.connection), client.lock)
    openstream!(client, transport, id, cursor, context, state)
end
openstream!(client, transport, id, cursor, context, ::StreamStopped) = StreamStopped()
function openstream!(client, transport, id, cursor, context, ::StreamRunning)
    headers = filter(pair -> lowercase(first(pair)) ∉ ("accept", "content-type", "last-event-id"), httpheaders(transport))
    push!(headers, "Accept" => "text/event-stream")
    cursorheader!(headers, cursor.id)
    result = Ref{StreamResult}(StreamStopped())
    try
        HTTP.open("GET", transport.url, headers; status_exception=false, request_timeout=0, retry=false, redirect=false, cookies=false, context) do stream
            response = HTTP.startread(stream)
            result[] = streamresponse!(client, transport, id, cursor, stream, response, streamstatus(response.status))
        end
        result[]
    catch exception
        retryfailure(exception)
    end
end
streamstatus(code) = get(Dict(200 => StreamRunning(), 408 => StreamRetry(), 429 => StreamRetry()), code, code >= 500 ? StreamRetry() : StreamStopped())
streamresponse!(client, transport, id, cursor, stream, response, result::StreamResult) = result
function streamresponse!(client, transport, id, cursor, stream, response, ::StreamRunning)
    type = lowercase(strip(first(split(HTTP.header(response, "Content-Type", ""), ';'))))
    streamcontent!(client, transport, id, cursor, stream, response, get(Dict("text/event-stream" => StreamRunning()), type, StreamStopped()))
end
streamcontent!(client, transport, id, cursor, stream, response, ::StreamStopped) = StreamStopped()
function streamcontent!(client, transport, id, cursor, stream, response, ::StreamRunning)
    session = HTTP.header(response, "Mcp-Session-Id", "")
    isempty(session) || (transport.session = session)
    result = streamresult(sseread!(client, stream, id, cursor))
    streamresult(result, cursor.validity)
end

reconnect!(client, transport, id, cursor, start::StreamResult) = reconnect!(client, transport, id, cursor, 0, start)
reconnect!(client, transport, id, cursor, attempt, ::StreamStopped) = false
reconnect!(client, transport, id, cursor, attempt, ::StreamAnswered) = true
function reconnect!(client, transport, id, cursor, attempt, ::StreamRunning)
    reconnectopen!(client, transport, id, cursor, attempt, streamstate(client, id))
end
reconnectopen!(client, transport, id, cursor, attempt, ::StreamStopped) = false
function reconnectopen!(client, transport, id, cursor, attempt, ::StreamRunning)
    cursor.received = NoEvents()
    opened = time()
    result = openstream!(client, transport, id, cursor)
    reconnectnext!(client, transport, id, cursor, attempt, opened, result)
end
reconnectnext!(client, transport, id, cursor, attempt, opened, result::Union{StreamStopped, StreamAnswered}) = reconnect!(client, transport, id, cursor, attempt, result)
reconnectnext!(client, transport, id, cursor, attempt, opened, result::Union{StreamEnded, StreamRetry}) = reconnectafter!(client, transport, id, cursor, nextattempt(id, cursor, attempt, opened), result)
reconnectafter!(client, transport, id, cursor, ::Nothing, result) = false
reconnectafter!(client, transport, id, cursor, attempt::Int, result) = reconnect!(client, transport, id, cursor, attempt, StreamRetry())
function reconnect!(client, transport, id, cursor, attempt, ::StreamRetry)
    attempt >= 5 && return false
    delay = reconnectdelay(cursor.retry, attempt)
    timedwait(() -> streamstate(client, id) == StreamStopped(), max(delay, 0.001); pollint=0.01)
    reconnectopen!(client, transport, id, cursor, attempt + 1, streamstate(client, id))
end
nextattempt(::ServerStream, cursor, attempt, opened) = nextattempt(cursor.received, attempt, opened)
nextattempt(::EventsReceived, attempt, opened) = 0
nextattempt(::NoEvents, attempt, opened) = time() - opened > 30 ? 0 : attempt
nextattempt(id, cursor, attempt, opened) = nextattempt(cursor.id, cursor.received, attempt)
nextattempt(::Nothing, receipt, attempt) = nothing
nextattempt(id::String, ::EventsReceived, attempt) = 0
nextattempt(id::String, ::NoEvents, attempt) = attempt

function getstream!(client::Client, transport::HttpTransport)
    reconnect!(client, transport, ServerStream(), StreamCursor(), StreamRunning())
    nothing
end

admit!(client, transport, ::Nothing, context) = context
function admit!(client, transport, id, context)
    lock(client.lock) do
        haskey(client.pending, id) || return nothing
        transport.requests[id] = context
        context
    end
end

httprequest(client, transport, message, id, ::Nothing) = Failure(:transport, "Could not write to MCP server")
function httprequest(client, transport, message, id, context::HTTP.RequestContext)
    try
        HTTP.open("POST", transport.url, httpheaders(transport); status_exception=false, request_timeout=httptimeout(id, client), retry=false, redirect=false, cookies=false, context) do stream
            write(stream, JSON3.write(message))
            response = HTTP.startread(stream)
            200 <= response.status < 300 || return requestfailure!(client, message, id, Failure(:http, "MCP HTTP status $(response.status)", response.status))
            session = HTTP.header(response, "Mcp-Session-Id", "")
            isempty(session) || (transport.session = session)
            httpresponse!(client, stream, message, id, response)
        end
        nothing
    catch exception
        requestfailure!(client, message, id, Failure(:transport, sprint(showerror, exception)))
        haskey(message, "id") ? nothing : Failure(:transport, "Could not write to MCP server")
    finally
        forgethttp!(transport, client, id)
    end
end

httpresponse!(client, stream, message, ::Nothing, response) = true
function httpresponse!(client, stream, message, id, response)
    type = lowercase(strip(first(split(HTTP.header(response, "Content-Type", ""), ';'))))
    get(httpreaders, type, unsupportedhttp!)(client, stream, message, id, type)
end
function ssehttp!(client, stream, message, id, type)
    cursor = StreamCursor()
    result = try
        streamresult(streamresult(sseread!(client, stream, id, cursor)), cursor.validity)
    catch exception
        retryfailure(exception)
    end
    ssefinish!(client, message, id, cursor, result)
end
ssefinish!(client, message, id, cursor, ::StreamAnswered) = nothing
ssefinish!(client, message, id, cursor, ::StreamStopped) = httpfailure!(client, message, Failure(:protocol, "MCP response stream ended without a response"))
ssefinish!(client, message, id, cursor, ::Union{StreamEnded, StreamRetry}) = sseresume!(client, message, id, cursor, cursor.validity, cursor.id)
sseresume!(client, message, id, cursor, ::InvalidStream, eventid) = ssefinish!(client, message, id, cursor, StreamStopped())
sseresume!(client, message, id, cursor, ::ValidStream, ::Nothing) = ssefinish!(client, message, id, cursor, StreamStopped())
function sseresume!(client, message, id, cursor, ::ValidStream, eventid::String)
    result = streamresult(reconnect!(client, client.process, id, cursor, StreamRetry()))
    ssefinish!(client, message, id, cursor, resumed(result))
end

resumed(::StreamEnded) = StreamStopped()
resumed(::StreamAnswered) = StreamAnswered()

function jsonhttp!(client, stream, message, id, type)
    value = validmessage(jsonmessage(String(read(stream))))
    received(client, value) || httpfailure!(client, message, Failure(:protocol, "Invalid JSON-RPC message"))
end
unsupportedhttp!(client, stream, message, id, type) = httpfailure!(client, message, Failure(:protocol, "Unsupported MCP HTTP response content type: $type"))
const httpreaders = Dict("text/event-stream" => ssehttp!, "application/json" => jsonhttp!)
forgethttp!(transport, client, ::Nothing) = nothing
forgethttp!(transport, client, id) = lock(() -> pop!(transport.requests, id, nothing), client.lock)

function httpfailure!(client::Client, message, failure::Failure)
    haskey(message, "id") || return false
    pending = lock(() -> writefailed!(client, message["id"], get(client.pending, message["id"], nothing)), client.lock)
    deliver!(pending, failure)
    true
end
requestfailure!(client, message, ::Nothing, failure) = false
requestfailure!(client, message, id::Int, failure) = httpfailure!(client, message, failure)

function send(client::Client, message, transport::HttpTransport)
    haskey(message, "id") && haskey(message, "method") && (@async httprequest(client, transport, message); return nothing)
    httprequest(client, transport, message)
end

struct ServerLost end
struct ClientClosing end

fail!(client::Client, failure::Failure) = fail!(client, failure, ServerLost())
function fail!(client::Client, failure::Failure, cause)
    pending = lock(client.lock) do
        takepending!(client, client.connection, cause)
    end
    foreach(entry -> deliver!(entry, failure), pending)
    @async shutdown(client)
    nothing
end

takepending!(client::Client, ::Closed, ::ServerLost) = Pending[]

function takepending!(client::Client, ::Connection, ::ServerLost)
    client.connection = Closed()
    pending = Pending[]
    for (id, request) in collect(client.pending)
        takefailed!(pending, client, id, request.progress)
    end
    pending
end
takefailed!(pending, client, id, ::Finishing) = nothing
takefailed!(pending, client, id, progress) = push!(pending, retire!(client, id))

takepending!(client::Client, connection::Connection, cause::ClientClosing) = takepending!(client, connection, cause, client.process)
function takepending!(client::Client, ::Connection, ::ClientClosing, ::Base.Process)
    client.connection = Closed()
    pending = collect(values(client.pending))
    empty!(client.pending)
    foreach(retire!, pending)
    pending
end
function takepending!(client::Client, ::Connection, ::ClientClosing, ::HttpTransport)
    client.connection = Closed()
    pending = Pending[]
    for (id, request) in collect(client.pending)
        takefailed!(pending, client, id, request.progress)
    end
    pending
end

retire!(::Nothing) = nothing
function retire!(pending::Pending)
    closetimer!(pending.timer)
    clear!(pending.progress)
    pending
end
retire!(client::Client, id) = retire!(pop!(client.pending, id, nothing))
closetimer!(::Nothing) = nothing
closetimer!(timer::Timer) = close(timer)
clear!(::NoProgress) = nothing
function clear!(progress::Progress)
    close(progress.queue)
    while isready(progress.queue)
        take!(progress.queue)
    end
    nothing
end
clear!(progress::Finishing) = clear!(progress.progress)
deliver!(::Nothing, result) = nothing
deliver!(pending::Pending, result) = put!(pending.result, result)

function shutdown(client::Client)
    pending = lock(() -> claim!(client, client.shutdown), client.lock)
    finishshutdown!(client, pending)
end

claim!(client::Client, ::ShutdownReady) = (client.shutdown = ShuttingDown(); nothing)
claim!(client::Client, ::ShuttingDown) = client.done
finishshutdown!(client::Client, done::Base.Event) = (wait(done); nothing)

finishshutdown!(client::Client, ::Nothing) = finishshutdown!(client, client.process)

function finishshutdown!(client::Client, transport::HttpTransport)
    try
        contexts, replies = lock(client.lock) do
            collect(values(transport.requests)), collect(transport.replies)
        end
        foreach(HTTP.cancel!, contexts)
        foreach(pair -> HTTP.cancel!(first(pair)), replies)
        HTTP.cancel!(transport.getcontext)
        timedwait(() -> all(pair -> istaskdone(last(pair)), replies) && readerdone(client.reader), 1; pollint=0.01)
        isempty(transport.session) || HTTP.request("DELETE", transport.url, httpheaders(transport); status_exception=false, request_timeout=1, retry=false, redirect=false, cookies=false)
    catch
    finally
        notify(client.done)
    end
    nothing
end

function finishshutdown!(client::Client, process::Base.Process)
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
        joinreader(client.reader)
    finally
        notify(client.done)
    end
    nothing
end

readerdone(::Nothing) = true
readerdone(reader::Task) = istaskdone(reader)
joinreader(::Nothing) = nothing
joinreader(reader::Task) = wait(reader)

function Base.close(client::Client)
    fail!(client, Failure(:closed, "MCP connection closed"), ClientClosing())
    shutdown(client)
end

serverresponse(client, message) = serverresponse(client, message, client.process)
serverresponse(client, message, ::Base.Process) = (send(client, message); true)
function serverresponse(client, message, transport::HttpTransport)
    admitted = lock(client.lock) do
        serverresponse!(client, message, transport, client.connection)
    end
    overloaded!(client, admitted)
    true
end
overloaded!(client, ::Nothing) = nothing
function overloaded!(client, failure::Failure)
    @warn failure.message
    fail!(client, failure)
end
serverresponse!(client, message, transport, ::Closed) = nothing
function serverresponse!(client, message, transport, ::Connection)
    length(transport.replies) >= 256 && return Failure(:overload, "MCP server response backlog exceeded 256")
    context = HTTP.RequestContext()
    task = @async begin
        try
            httprequest(client, transport, message, nothing, context)
        finally
            lock(() -> pop!(transport.replies, context, nothing), client.lock)
        end
    end
    transport.replies[context] = task
    nothing
end

pingrequest(client, id) = serverresponse(client, Dict("jsonrpc" => "2.0", "id" => id, "result" => Dict()))
missingrequest(client, id) = serverresponse(client, Dict("jsonrpc" => "2.0", "id" => id, "error" => Dict("code" => -32601, "message" => "Method not found")))
rootrequest(client, id) = rootrequest(client, id, client.roots)
rootrequest(client, id, ::NoRoots) = missingrequest(client, id)

rootrequest(client, id, roots::Roots) = rootrequest(client, id, roots, client.process)
function rootrequest(client, id, roots::Roots, ::Base.Process)
    @async rootresponse!(client, id, roots)
    true
end
function rootrequest(client, id, roots::Roots, transport::HttpTransport)
    admitted = lock(() -> startroots!(client, id, roots, transport, client.connection), client.lock)
    overloaded!(client, admitted)
    true
end
startroots!(client, id, roots, transport, ::Closed) = nothing
function startroots!(client, id, roots, transport, ::Connection)
    length(transport.roots) >= 256 && return Failure(:overload, "MCP roots callback backlog exceeded 256")
    task = @async try
        rootresponse!(client, id, roots)
    finally
        lock(() -> delete!(transport.roots, current_task()), client.lock)
    end
    push!(transport.roots, task)
    nothing
end

function rootresponse!(client, id, roots::Roots)
    response = try
        Dict("result" => Dict("roots" => rootvalues(roots.value)))
    catch exception
        Dict("error" => Dict("code" => -32603, "message" => sprint(showerror, exception)))
    end
    message = Dict{String, Any}("jsonrpc" => "2.0", "id" => id)
    merge!(message, response)
    serverresponse(client, message)
end

const serverrequests = Dict{String, Function}("ping" => pingrequest, "roots/list" => rootrequest)

received(client::Client, message) = false
received(client::Client, message::AbstractDict) = get(message, "jsonrpc", nothing) == "2.0" && receivemethod(client, message, toolfield(message, "method"))
receivemethod(client, message, ::Nothing) = receivereply(client, message, toolfield(message, "id"))
receivemethod(client, message, ::Some) = false
receivemethod(client, message, method::Some{<:AbstractString}) = receiverequest(client, message, something(method), toolfield(message, "id"))

function receiverequest(client, message, method, ::Nothing)
    get(notificationhandlers, method, ignorenotification!)(client, get(message, "params", nothing))
    true
end
receiverequest(client, message, method, ::Some) = false
receiverequest(client, message, method, ::Some{Bool}) = false
receiverequest(client, message, method, id::Some{<:Union{AbstractString, Integer}}) = get(serverrequests, method, missingrequest)(client, something(id))

receivereply(client, message, id) = false
receivereply(client, message, ::Some{Bool}) = false
receivereply(client, message, id::Some{<:Union{AbstractString, Integer}}) = receivefields(client, message, something(id), toolfield(message, "result"), toolfield(message, "error"))
receivefields(client, message, id, result, failure) = false
receivefields(client, message, id, ::Some, ::Nothing) = receivereply!(client, message, id)
receivefields(client, message, id, ::Nothing, ::Some) = receivereply!(client, message, id)
function receivereply!(client, message, id)
    action = lock(() -> prepare!(client, id, get(client.pending, id, nothing), message), client.lock)
    response!(client, id, action)
    true
end

responsevalue(message) = responsevalue(message, toolfield(message, "error"))
responsevalue(message, ::Nothing) = message["result"]
responsevalue(message, detail::Some) = rpcerror(something(detail))
rpcerror(detail) = Failure(:protocol, "Invalid JSON-RPC error")
rpcerror(detail::AbstractDict) = rpcerror(detail, get(detail, "code", nothing), get(detail, "message", nothing))
rpcerror(detail, code, message) = Failure(:protocol, "Invalid JSON-RPC error")
rpcerror(detail, code::Bool, message::AbstractString) = Failure(:protocol, "Invalid JSON-RPC error")
rpcerror(detail, code::Real, message::AbstractString) = Failure(:rpc, message, detail)

prepare!(client, id, ::Nothing, message) = nothing
prepare!(client, id, pending::Pending, message) = prepare!(client, id, pending, message, pending.progress)
prepare!(client, id, pending, message, ::Finishing) = nothing
prepare!(client, id, pending, message, ::NoProgress) = (retire!(client, id), responsevalue(message), nothing)
prepare!(client, id, pending, message, progress::Progress) = prepare!(client, id, pending, message, progress, progress.task)
prepare!(client, id, pending, message, progress, ::Nothing) = (retire!(client, id), responsevalue(message), nothing)
function prepare!(client, id, pending, message, progress, task::Task)
    closetimer!(pending.timer)
    pending.timer = nothing
    pending.generation += 1
    pending.progress = Finishing(progress)
    close(progress.queue)
    pending, responsevalue(message), task
end

response!(client, id, ::Nothing) = nothing
response!(client, id, action::Tuple) = response!(client, id, action...)
response!(client, id, pending, result, ::Nothing) = deliver!(pending, result)
function response!(client, id, pending, result, task::Task)
    @async begin
        try
            wait(task)
        catch exception
            @warn "MCP progress task failed" exception
        end
        finished = lock(() -> retirematching!(client, id, pending, get(client.pending, id, nothing)), client.lock)
        deliver!(finished, result)
    end
    nothing
end
retirematching!(client, id, pending, ::Nothing) = nothing
retirematching!(client, id, pending, current::Pending) = current === pending ? retire!(client, id) : nothing

function readmessages(client::Client)
    try
        for line in eachline(client.process.out; keep=true)
            if !endswith(line, '\n')
                fail!(client, Failure(:protocol, "Incomplete JSON-RPC message"))
                return
            end
            received(client, validmessage(jsonmessage(line)))
        end
        fail!(client, Failure(:closed, "MCP server closed its output"))
    catch exception
        fail!(client, Failure(:transport, sprint(showerror, exception)))
    end
end

admit(::Connection, ::Connection) = false
admit(::Connecting, ::Connecting) = true
admit(::Open, ::Connection) = true

request(client::Client, method, params; timeout=client.timeout, on_progress=nothing) = request(client, method, params, Open(); timeout, on_progress)

function request(client::Client, method, params, required::Connection; timeout=client.timeout, on_progress=nothing)
    reservation = lock(() -> admission!(client, client.connection, required, timeout, progress(on_progress)), client.lock)
    request(client, method, params, reservation)
end

admission!(client::Client, current::Connection, required::Connection) = admission!(client, current, required, client.timeout, NoProgress())
admission!(client::Client, ::Connection, ::Connection, timeout, progress) = Failure(:closed, "MCP connection is not open")
admission!(client::Client, ::Connecting, ::Connecting, timeout, progress) = reserve!(client, timeout, progress)
admission!(client::Client, ::Open, ::Connection, timeout, progress) = reserve!(client, timeout, progress)
function reserve!(client::Client, timeout, progress)
    client.nextid += 1
    id = client.nextid
    pending = Pending(Channel{Any}(1), progress, Float64(timeout), nothing, 0)
    client.pending[id] = pending
    arm!(client, id, pending)
    id, pending
end

function arm!(client::Client, id, pending::Pending)
    closetimer!(pending.timer)
    pending.timer = nothing
    pending.generation += 1
    isfinite(pending.timeout) && pending.timeout > 0 || return nothing
    generation = pending.generation
    pending.timer = Timer(pending.timeout) do _
        expired, connection = lock(client.lock) do
            current = get(client.pending, id, nothing)
            current === pending && pending.generation == generation || return (nothing, client.connection)
            retire!(client, id), client.connection
        end
        expire!(client, id, expired, connection)
    end
end

request(client::Client, method, params, failure::Failure) = failure
function request(client::Client, method, params, reservation::Tuple{Int, Pending})
    id, pending = reservation
    try
        message = Dict("jsonrpc" => "2.0", "id" => id, "method" => method, "params" => progressparams(params, id, pending.progress))
        transmitted!(client, sendrequest(client, message, id), id)
        take!(pending.result)
    finally
        abandoned, connection = lock(client.lock) do
            retire!(client, id), client.connection
        end
        cancelhttp!(client.process, client, id)
        abandon!(client, id, abandoned, connection)
    end
end

progressparams(params, id, ::NoProgress) = params
progressparams(::Nothing, id, ::Progress) = Dict("_meta" => progressmeta(nothing, id))
function progressparams(params, id, ::Progress)
    result = Dict{String, Any}(string(key) => value for (key, value) in pairs(params))
    result["_meta"] = progressmeta(get(result, "_meta", nothing), id)
    result
end
progressmeta(meta, id) = Dict{String, Any}("progressToken" => id)
progressmeta(meta::NamedTuple, id) = progressmeta(Dict(string(key) => value for (key, value) in pairs(meta)), id)
function progressmeta(meta::AbstractDict, id)
    result = Dict{String, Any}(string(key) => value for (key, value) in meta)
    result["progressToken"] = id
    result
end

expire!(client::Client, id, ::Nothing, connection::Connection) = nothing
function expire!(client::Client, id, pending::Pending, connection::Connection)
    cancelhttp!(client.process, client, id)
    queuecancel!(client, id, connection, "Request timed out")
    deliver!(pending, Failure(:timeout, "MCP request timed out"))
    nothing
end

abandon!(client::Client, id, ::Nothing, connection::Connection) = nothing
abandon!(client::Client, id, pending::Pending, connection::Connection) = abandon!(client, id, pending.progress, connection)
abandon!(client, id, ::Finishing, connection) = nothing
function abandon!(client, id, progress, connection)
    cancelhttp!(client.process, client, id)
    queuecancel!(client, id, connection, "Request cancelled")
    nothing
end

function queuecancel!(client, id, connection, reason)
    ready = Channel{Nothing}(1)
    @async begin
        result = trylock(client.writer) do
            put!(ready, nothing)
            cancelrequest!(client, id, connection, reason)
            nothing
        end
        cancelwaiting!(result, client, id, connection, reason, ready)
    end
    take!(ready)
    nothing
end
cancelwaiting!(::Nothing, client, id, connection, reason, ready) = nothing
function cancelwaiting!(::Bool, client, id, connection, reason, ready)
    put!(ready, nothing)
    cancelrequest!(client, id, connection, reason)
    nothing
end

struct ProgressStarted end
struct ProgressQueued end

progress!(client::Client, params) = nothing
progress!(client::Client, params::AbstractDict) = progress!(client, get(params, "progressToken", nothing), get(params, "progress", nothing), params)
progress!(client::Client, token, value, params) = nothing
progress!(client::Client, token::Bool, value::Real, params) = nothing
progress!(client::Client, token::Real, value::Bool, params) = nothing
progress!(client::Client, token::Bool, value::Bool, params) = nothing
function progress!(client::Client, token::Real, value::Real, params)
    isfinite(token) || return nothing
    action = lock(client.lock) do
        enqueue!(client, token, get(client.pending, token, nothing), params)
    end
    progressed!(client, action)
end
ignorenotification!(client, params) = nothing
const notificationhandlers = Dict{String, Function}("notifications/progress" => progress!)

enqueue!(client, token, ::Nothing, params) = nothing
enqueue!(client, token, pending::Pending, params) = enqueue!(client, Int(token), pending, pending.progress, params)
enqueue!(client, id, pending, ::NoProgress, params) = nothing
enqueue!(client, id, pending, ::Finishing, params) = nothing
function enqueue!(client, id, pending, progress::Progress, params)
    arm!(client, id, pending)
    put!(progress.queue, params)
    startprogress!(client, id, pending, progress, progress.task)
end

function startprogress!(client, id, pending, progress, ::Nothing)
    progress.task = @async progressloop!(client, id, pending, progress)
    ProgressStarted()
end
startprogress!(client, id, pending, progress, ::Task) = ProgressQueued()
progressed!(client, ::Nothing) = nothing
progressed!(client, ::ProgressQueued) = nothing
progressed!(client, ::ProgressStarted) = yield()

function progressloop!(client, id, pending, progress::Progress)
    for params in progress.queue
        current = lock(() -> get(client.pending, id, nothing), client.lock)
        current === pending || return nothing
        try
            Base.invokelatest(progress.callback, params)
        catch exception
            @warn "MCP progress callback failed" exception
        end
    end
    nothing
end

cancelhttp!(::Base.Process, client, id) = nothing
function cancelhttp!(transport::HttpTransport, client, id)
    context = lock(() -> get(transport.requests, id, nothing), client.lock)
    cancelhttp!(context)
end
cancelhttp!(::Nothing) = true
cancelhttp!(context::HTTP.RequestContext) = HTTP.cancel!(context)

cancelrequest!(client::Client, id, ::Connection, reason) = nothing
cancelrequest!(client::Client, id, ::Open, reason) = transmitted!(client, send(client, Dict("jsonrpc" => "2.0", "method" => "notifications/cancelled", "params" => Dict("requestId" => id, "reason" => reason))))

activate!(client::Client, ::Connection) = Failure(:closed, "MCP connection closed during initialization")

function activate!(client::Client, ::Connecting)
    client.connection = Open()
    startstream!(client, client.process)
    client
end

startstream!(client, ::Base.Process) = nothing
startstream!(client, transport::HttpTransport) = (client.reader = @async getstream!(client, transport); nothing)

initparams(client::Client) = Dict("protocolVersion" => first(versions), "capabilities" => rootcapabilities(client.roots), "clientInfo" => Dict("name" => "JuliaForever", "version" => "0.1.0"))

function connect(url::AbstractString; timeout=30.0, headers=Pair{String, String}[], roots=nothing)
    transport = HttpTransport(String(url), Pair{String, String}[String(k) => String(v) for (k, v) in headers], "", "", Dict{Int, HTTP.RequestContext}(), HTTP.RequestContext(), Dict{HTTP.RequestContext, Task}(), Set{Task}())
    client = Client(transport, ReentrantLock(), ReentrantLock(), Dict{Int, Pending}(), 0, Connecting(), nothing, Float64(timeout), 0.0, false, Base.Event(), nothing, rootsource(roots))
    initialize!(client, request(client, "initialize", initparams(client), Connecting()))
end

function connect(command::Cmd; timeout=30.0, grace=0.5, roots=nothing)
    process = try
        open(pipeline(command; stderr=stderr), "r+")
    catch exception
        return Failure(:start, sprint(showerror, exception))
    end
    client = Client(process, ReentrantLock(), ReentrantLock(), Dict{Int, Pending}(), 0, Connecting(), nothing, Float64(timeout), Float64(grace), ShutdownReady(), Base.Event(), nothing, rootsource(roots))
    client.reader = @async readmessages(client)
    initialize!(client, request(client, "initialize", initparams(client), Connecting()))
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

const supportedversions = Dict(version => version for version in versions)
initialize!(client::Client, result::AbstractDict) = initversion!(client, result, get(supportedversions, get(result, "protocolVersion", nothing), nothing))
initversion!(client, result, ::Nothing) = invalid!(client)
initversion!(client, result, version::String) = initcapabilities!(client, result, version, get(result, "capabilities", nothing))
initcapabilities!(client, result, version, capabilities) = invalid!(client)
initcapabilities!(client, result, version, capabilities::AbstractDict) = inittools!(client, result, version, get(capabilities, "tools", Dict()))
inittools!(client, result, version, tools) = invalid!(client)
inittools!(client, result, version, ::AbstractDict) = initserver!(client, result, version, get(result, "serverInfo", nothing))
initserver!(client, result, version, server) = invalid!(client)
initserver!(client, result, version, server::AbstractDict) = initidentity!(client, result, version, get(server, "name", nothing), get(server, "version", nothing))
initidentity!(client, result, version, name, serverversion) = invalid!(client)
function initidentity!(client, result, version, name::AbstractString, serverversion::AbstractString)
    client.server = result
    protocol!(client.process, version)
    initialized!(client, send(client, Dict("jsonrpc" => "2.0", "method" => "notifications/initialized")))
end

function initialized!(client::Client, ::Failure)
    close(client)
    Failure(:transport, "Could not finish MCP initialization")
end

function initialized!(client::Client, ::Nothing)
    lock(client.lock) do
        activate!(client, client.connection)
    end
end

function call(client::Client, tool::AbstractString, args; timeout=client.timeout, on_progress=nothing)
    haskey(client.server["capabilities"], "tools") || return Failure(:capability, "MCP server did not advertise tools")
    toolresponse(request(client, "tools/call", Dict("name" => tool, "arguments" => args); timeout, on_progress))
end

toolresponse(failure::Failure) = failure
toolresponse(result) = Failure(:protocol, "Invalid MCP tools/call result")

toolfield(result, key) = haskey(result, key) ? Some(result[key]) : nothing
toolresponse(result::AbstractDict) = toolcontent(result, toolfield(result, "content"))
toolcontent(result, ::Nothing) = toolstructured(result, toolfield(result, "structuredContent"))
toolcontent(result, ::Some) = Failure(:protocol, "Invalid MCP tools/call result")
toolcontent(result, ::Some{<:AbstractVector}) = toolerror(result, toolfield(result, "isError"))
toolstructured(result, ::Nothing) = Failure(:protocol, "Invalid MCP tools/call result")
toolstructured(result, ::Some) = toolerror(result, toolfield(result, "isError"))
toolerror(result, ::Nothing) = result
toolerror(result, ::Some) = Failure(:protocol, "Invalid MCP tools/call result")
toolerror(result, ::Some{Bool}) = result

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

imagecontent(block) = nothing
imageblock(block) = (; mime=get(block, "mimeType", nothing), data=get(block, "data", nothing))
resourceblock(block) = resourceimage(get(block, "resource", nothing))
otherblock(block) = nothing
const imageblocks = Dict("image" => imageblock, "resource" => resourceblock)
imagecontent(block::AbstractDict) = get(imageblocks, get(block, "type", nothing), otherblock)(block)

resourceimage(resource) = nothing

function resourceimage(resource::AbstractDict)
    haskey(resource, "text") && return nothing
    resourceimage(get(resource, "mimeType", nothing), resource)
end

resourceimage(mime, resource::AbstractDict) = nothing

function resourceimage(mime::AbstractString, resource::AbstractDict)
    startswith(mime, "image/") || return nothing
    (; mime, data=get(resource, "blob", nothing))
end

image(content) = image(content.mime, content.data)
image(mime, data) = Failure(:protocol, "Malformed image content")

function image(mime::AbstractString, data::AbstractString)
    mime in ("image/png", "image/jpeg") || return Failure(:capability, "Image MIME type $mime is not supported")
    ncodeunits(data) <= 4 * cld(imagelimit, 3) || return Failure(:capability, "Image exceeds the 10 MiB limit")
    bytes = try
        base64decode(data)
    catch
        return Failure(:protocol, "Invalid image base64")
    end
    base64encode(bytes) == data || return Failure(:protocol, "Invalid image base64")
    length(bytes) <= imagelimit || return Failure(:capability, "Image exceeds the 10 MiB limit")
    image(mime, data, bytes, imageformat(bytes))
end

image(mime, data, bytes, ::MIME) = Failure(:protocol, "Mismatched image data for $mime")

function image(mime, data, bytes, format::Union{MIME"image/png", MIME"image/jpeg"})
    mime == string(format) || return Failure(:protocol, "Mismatched image data for $mime")
    image(mime, data, imageproblem(format, bytes))
end

image(mime, data, ::Nothing) = Image(mime, data)
image(mime, data, problem::String) = Failure(:capability, problem)

imagecount(::Nothing) = 0
imagecount(::NamedTuple) = 1
imageoutcome(outcome, ::Union{Nothing, Image}) = outcome
imageoutcome(outcome, ::Failure) = ToolFailure
imageattachment(previous, ::Union{Nothing, Failure}) = previous
imageattachment(previous, value::Image) = value
imagemarker(::Image) = "[MCP image attached]"
imagemarker(value::Failure) = "[MCP image omitted: $(value.message)]"

function contentblock!(content, block::AbstractDict, ::Nothing, count)
    content!(content, block)
    nothing
end

function contentblock!(content, block, ::Nothing, count)
    push!(content, JSON3.write(block))
    nothing
end

function contentblock!(content, block, candidate::NamedTuple, count)
    value = count > 1 ? Failure(:capability, "Multiple images are not supported") : image(candidate)
    push!(content, imagemarker(value))
    value
end

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
    blocks = get(result, "content", [])
    countimages = sum(block -> imagecount(imagecontent(block)), blocks; init=0)
    attachment = nothing
    outcome = tooltype(get(result, "isError", false))
    for block in blocks
        value = contentblock!(content, block, imagecontent(block), countimages)
        outcome = imageoutcome(outcome, value)
        attachment = imageattachment(attachment, value)
    end
    haskey(result, "structuredContent") && push!(content, JSON3.write(result["structuredContent"]))
    outcome(join(content, "\n"), attachment)
end

cursorparams(::Nothing) = Dict()
cursorparams(cursor::AbstractString) = Dict("cursor" => cursor)

mutable struct ToolListing{P}
    client::Client
    prefix::P
    found::Vector{RemoteTool}
    aliases::Set{String}
    cursors::Set{String}
    cursor::Union{Nothing, String}
end

function tools(client::Client; prefix="mcp_")
    haskey(client.server["capabilities"], "tools") || return Failure(:capability, "MCP server did not advertise tools")
    listing = ToolListing(client, prefix, RemoteTool[], Set{String}(), Set{String}(), nothing)
    finishtools(foldl(toolstep!, 1:1000; init=listing))
end

finishtools(listing::ToolListing) = Failure(:protocol, "MCP tools/list exceeded 1000 pages")
finishtools(result::Union{Failure, Vector{RemoteTool}}) = result
toolstep!(result::Union{Failure, Vector{RemoteTool}}, page) = result
function toolstep!(listing::ToolListing, page)
    response = request(listing.client, "tools/list", cursorparams(listing.cursor))
    toolpage!(listing, response)
end

toolpage!(listing, failure::Failure) = failure
toolpage!(listing, page) = Failure(:protocol, "Invalid MCP tools/list result")
toolpage!(listing, page::AbstractDict) = toolitems!(listing, get(page, "tools", nothing), get(page, "nextCursor", missing))
toolitems!(listing, items, cursor) = Failure(:protocol, "Invalid MCP tools/list result")
toolitems!(listing, items::AbstractVector, cursor) = toolnext!(foldl(toolentry!, items; init=listing), cursor)

toolentry!(failure::Failure, item) = failure
toolentry!(listing::ToolListing, item) = Failure(:protocol, "Invalid MCP tool definition")
toolentry!(listing::ToolListing, item::AbstractDict) = tooldefinition!(listing, item, get(item, "name", nothing), get(item, "inputSchema", nothing))
tooldefinition!(listing, item, remote, parameters) = Failure(:protocol, "Invalid MCP tool definition")
tooldefinition!(listing, item, remote::AbstractString, parameters::AbstractDict) = toolexecution!(listing, item, String(remote), parameters, get(item, "execution", Dict()))
toolexecution!(listing, item, remote, parameters, execution) = Failure(:protocol, "Invalid MCP tool execution metadata")
toolexecution!(listing, item, remote, parameters, execution::AbstractDict) = get(tasksupport, get(execution, "taskSupport", "forbidden"), invalidtasksupport)(listing, item, remote, parameters)
invalidtasksupport(listing, item, remote, parameters) = Failure(:protocol, "Invalid MCP task support")
requiredtool(listing, item, remote, parameters) = Failure(:capability, "MCP tool $remote requires unsupported task execution")

function supportedtool!(listing, item, remote, parameters)
    alias = first(replace(listing.prefix * remote, r"[^A-Za-z0-9_-]" => "_"), 64)
    alias in listing.aliases && return Failure(:protocol, "MCP tool names collide after adaptation")
    toolbuild!(listing, remote, alias, parameters, get(item, "description", remote))
end
const tasksupport = Dict("forbidden" => supportedtool!, "optional" => supportedtool!, "required" => requiredtool)
toolbuild!(listing, remote, alias, parameters, doc) = Failure(:protocol, "Invalid MCP tool description")
function toolbuild!(listing, remote, alias, parameters, doc::AbstractString)
    push!(listing.aliases, alias)
    push!(listing.found, RemoteTool(listing.client, remote, alias, String(doc), parameters))
    listing
end

toolnext!(failure::Failure, cursor) = failure
toolnext!(listing::ToolListing, ::Missing) = listing.found
toolnext!(listing::ToolListing, cursor) = Failure(:protocol, "Invalid MCP tools/list cursor")
function toolnext!(listing::ToolListing, cursor::AbstractString)
    cursor in listing.cursors && return Failure(:protocol, "Repeated MCP tools/list cursor")
    push!(listing.cursors, cursor)
    listing.cursor = cursor
    listing
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

validcontent(value) = false
validcontent(value::AbstractDict) = validcontent(get(value, "uri", nothing), get(value, "text", nothing), get(value, "blob", nothing))
validcontent(uri, text, blob) = false
validcontent(uri::AbstractString, text::AbstractString, blob) = true
validcontent(uri::AbstractString, text, blob::AbstractString) = true
validcontent(uri::AbstractString, text::AbstractString, blob::AbstractString) = true
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
    selected = Dict{String, Client}()
    for (name, client) in servers
        selectresource!(selected, name, client, capability(client))
    end
    isempty(selected) && return Tool[]
    Tool[ListResources{Resources}(selected), ListResources{Templates}(selected), ReadResource(selected)]
end

selectresource!(selected, name, client, capability) = nothing
selectresource!(selected, name, client, capability::AbstractDict) = (selected[String(name)] = client; nothing)

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
fallback(failure::Failure, data::AbstractDict, empty) = get(Dict(-32601 => empty), get(data, "code", nothing), failure)

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
