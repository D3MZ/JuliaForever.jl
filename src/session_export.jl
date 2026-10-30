struct ExportJSONL <: ExportFormat end
struct MemoryExport end
struct UnsavedExport end

struct ExportSnapshot{S}
    source::S
    id::String
    timestamp::String
    stamp::Int
    cwd::String
    parent::Union{Nothing, String}
    messages::Vector{Conversation.Message}
end

exportsource(::Nothing) = MemoryExport()
exportsource(::History.Memory) = MemoryExport()
exportsource(history::History.Tree) = exportsource(history.store)
exportsource(history::History.SQLite) = SessionCatalog.path(history)
function exportsource(history::SessionCatalog.Deferred)
    lock(history.lock) do
        exportsource(history, history.store)
    end
end
exportsource(history::SessionCatalog.Deferred, ::History.Memory) = UnsavedExport()
exportsource(history::SessionCatalog.Deferred, store::History.SQLite) = SessionCatalog.path(store)
exportsource(::History.Store) = MemoryExport()
exportid(history, agent) = LiveJSON.id(history)
exportid(::Union{Nothing, History.Memory}, agent) = bytes2hex(sha256(agent.initial.kernel.id))[1:32]
exportid(history::History.Tree, agent) = exportid(history.store, agent)

exportparent(history::History.Tree) = SessionCatalog.parent(history)
exportparent(history) = nothing

exportargument(::Nothing) = nothing
exportargument(path::String) = isempty(path) ? nothing : path
exportformat(::Nothing) = ExportHTML()
exportformat(path::String) = endswith(path, ".jsonl") ? ExportJSONL() : ExportHTML()

function exportsnapshot(agent, history)
    lock(agent.lock) do
        ExportSnapshot(exportsource(history), exportid(history, agent), LiveJSON.isotime(), LiveJSON.nowms(), pwd(), exportparent(history), deepcopy(getfield(agent.state, :messages)))
    end
end

function command!(command::ExportCommand, terminal, agent, history, input, directory, snapshot)
    path = exportargument(command.path)
    data = exportsnapshot(agent, history)
    exportcommand!(terminal, agent, history, path, exportformat(path), data)
end

exportcommand!(terminal, agent, history, path, ::ExportHTML, data::ExportSnapshot{MemoryExport}) = exportmessage!(terminal, agent, history, "Cannot export in-memory session to HTML.")
exportcommand!(terminal, agent, history, path, ::ExportHTML, data::ExportSnapshot{UnsavedExport}) = exportmessage!(terminal, agent, history, "Nothing to export yet - start a conversation first.")
function exportcommand!(terminal, agent, history, path, format::ExportFormat, data::ExportSnapshot)
    target = exporttarget(path, format, data)
    result = attempt(() -> exportwrite(target, format, data))
    exportresult!(terminal, agent, history, target, result)
end

exporttarget(path::String, format, data) = abspath(expanduser(path))
exporttarget(::Nothing, ::ExportHTML, data) = abspath("pi-session-" * splitext(basename(data.source))[1] * ".html")

function exportwrite(target, format::ExportFormat, data)
    exportdirectory(target, format)
    writeexport(target, format, data)
end
exportdirectory(target, ::ExportHTML) = nothing
exportdirectory(target, ::ExportJSONL) = mkpath(dirname(target))

function exportresult!(terminal, agent, history, target, ::Nothing)
    println(terminal.diagnostics, "Session exported to: ", redact(terminal, target))
    flush(terminal.diagnostics)
    agent, history, 0
end
exportresult!(terminal, agent, history, target, failure::ToolFailure) = exportmessage!(terminal, agent, history, "Failed to export session: " * redact(terminal, failure.text))
function exportmessage!(terminal, agent, history, message::String)
    println(terminal.diagnostics, message)
    flush(terminal.diagnostics)
    agent, history, 1
end

function writeexport(io::IO, ::ExportHTML, data::ExportSnapshot)
    messages = Dict{String, Any}[]
    foreach(message -> exporthtml!(messages, message), data.messages)
    Logs.conversationhtml(io, messages)
end
exporthtml!(messages, message::Conversation.Message) = nothing
exporthtml!(messages, message::Union{Conversation.User, Conversation.ImageUser, Conversation.Summary, Conversation.Assistant, Conversation.ToolMessage}) = push!(messages, convert(Dict{String, Any}, message))
function exporthtml!(messages, message::Conversation.RawMessage)
    exporthtml!(messages, LiveJSON.role(message.value), message.value)
end
exporthtml!(messages, role::LiveJSON.Role, value) = nothing
exporthtml!(messages, role::Union{LiveJSON.UserRole, LiveJSON.AssistantRole, LiveJSON.ToolRole}, value) = push!(messages, deepcopy(value))
function exporthtml!(messages, value::Conversation.BashMessage)
    push!(messages, Dict{String, Any}("role" => "tool", "content" => "\$ " * value.command * "\n" * value.output))
end

function writeexport(io::IO, ::ExportJSONL, data::ExportSnapshot)
    header = Dict{String, Any}("type" => "session", "version" => 3, "id" => data.id, "timestamp" => data.timestamp, "cwd" => data.cwd, "juliaForever" => (; usage="unavailable values are zero", messageTimestamps="recorded when available; otherwise export time"))
    exportparent!(header, data.parent)
    JSON3.write(io, header)
    write(io, '\n')
    entries = Dict{String, Any}[]
    names = Dict{String, String}()
    for message in data.messages
        exportentry!(entries, names, data, message)
    end
    for entry in entries
        JSON3.write(io, entry)
        write(io, '\n')
    end
    nothing
end

exportparent!(header, ::Nothing) = header
exportparent!(header, parent::String) = (header["parentSession"] = parent; header)

function exportentry!(entries, value, timestamp)
    index = length(entries) + 1
    id = lpad(string(index; base=16), 8, '0')
    parent = isempty(entries) ? nothing : last(entries)["id"]
    push!(entries, Dict{String, Any}("type" => "message", "id" => id, "parentId" => parent, "timestamp" => timestamp, "message" => value))
    nothing
end

exportentry!(entries, names, data, message::Conversation.Message) = nothing
function exportentry!(entries, names, data, message::Union{Conversation.User, Conversation.ImageUser, Conversation.Summary})
    raw = convert(Dict{String, Any}, message)
    value = Dict{String, Any}("role" => "user", "content" => exportcontent(raw["content"], get(raw, "images", nothing)), "timestamp" => data.stamp)
    exportentry!(entries, value, data.timestamp)
end
function exportentry!(entries, names, data, message::Conversation.Assistant)
    raw = convert(Dict{String, Any}, message)
    for call in message.calls
        names[call.id] = something(call.name, "")
    end
    reason = exportreason(message, raw, getfield(message, :status), message.finish)
    fields = exportfields(message.info, data.stamp)
    value = Dict{String, Any}("role" => "assistant", "content" => LiveJSON.fallbackcontent(raw), "api" => fields.api, "provider" => fields.provider, "model" => fields.model, "usage" => LiveJSON.usage(fields.usage), "stopReason" => reason, "timestamp" => fields.timestamp)
    exportentry!(entries, value, data.timestamp)
end
exportfields(::Nothing, stamp) = (; api="unknown", provider="unknown", model="unknown", usage=nothing, timestamp=stamp)
exportfields(info::Conversation.ResponseInfo, stamp) = (; api=something(info.api, "unknown"), provider=something(info.provider, "unknown"), model=something(info.model, "unknown"), usage=info.usage, timestamp=something(info.timestamp, stamp))
exportreason(message, raw, ::Finished, ::Nothing) = isempty(message.calls) ? "stop" : "toolUse"
function exportreason(message, raw, status, finish)
    completion = Completion(raw, nothing, finish, status, nothing)
    LiveJSON.reason(completion, raw)
end
function exportentry!(entries, names, data, message::Conversation.ToolMessage)
    exporttool!(entries, names, data, convert(Dict{String, Any}, message))
end
function exporttool!(entries, names, data, raw)
    id = get(raw, "tool_call_id", "")
    content = exportcontent(get(raw, "content", ""), nothing)
    LiveJSON.image!(content, get(raw, "image", nothing))
    value = Dict{String, Any}("role" => "toolResult", "toolCallId" => id, "toolName" => get(names, id, ""), "content" => content, "isError" => get(raw, "is_error", false), "timestamp" => data.stamp)
    exportentry!(entries, value, data.timestamp)
end
exportentry!(entries, names, data, message::Conversation.BashMessage) = exportentry!(entries, convert(Dict{String, Any}, message), data.timestamp)
function exportentry!(entries, names, data, message::Conversation.RawMessage)
    raw = message.value
    exportentry!(entries, names, data, raw, LiveJSON.role(raw))
end
exportentry!(entries, names, data, raw, role::LiveJSON.Role) = nothing
function exportentry!(entries, names, data, raw, ::LiveJSON.UserRole)
    value = Dict{String, Any}("role" => "user", "content" => exportcontent(get(raw, "content", ""), get(raw, "images", nothing)), "timestamp" => data.stamp)
    exportentry!(entries, value, data.timestamp)
end
function exportentry!(entries, names, data, raw, ::LiveJSON.AssistantRole)
    exportassistant!(entries, names, data, raw, get(raw, "content", nothing))
end
function exportassistant!(entries, names, data, raw, content::Union{Nothing, AbstractString})
    value = conversation_reply((; message=raw, result=nothing)).message
    exportentry!(entries, names, data, value)
end
function exportassistant!(entries, names, data, raw, content::AbstractVector)
    blocks = Dict{String, Any}[]
    calls = Dict{String, String}()
    foreach(block -> exportassistantblock!(blocks, calls, block), content)
    foreach(call -> exportassistantcall!(blocks, calls, LiveJSON.toolcall(call)), get(raw, "tool_calls", []))
    merge!(names, calls)
    reason = get(raw, "stopReason", isempty(calls) ? "stop" : "toolUse")
    value = Dict{String, Any}("role" => "assistant", "content" => blocks, "api" => "unknown", "provider" => "unknown", "model" => "unknown", "usage" => LiveJSON.usage(nothing), "stopReason" => reason, "timestamp" => data.stamp)
    exportentry!(entries, value, data.timestamp)
end
exportassistantblock!(blocks, calls, value) = exportblock!(blocks, value)
exportassistantblock!(blocks, calls, value::AbstractDict) = get(assistantblocks, get(value, "type", ""), exportassistantother!)(blocks, calls, value)
exportassistantother!(blocks, calls, value) = exportblock!(blocks, value)
exportthinking!(blocks, calls, value) = push!(blocks, Dict{String, Any}("type" => "thinking", "thinking" => get(value, "thinking", "")))
function exportassistantcall!(blocks, calls, value)
    id, name = get(value, "id", ""), get(value, "name", "")
    calls[id] = name
    push!(blocks, Dict{String, Any}(value))
end
const assistantblocks = Dict("thinking" => exportthinking!, "toolCall" => exportassistantcall!)
function exportentry!(entries, names, data, raw, ::LiveJSON.ToolRole)
    exporttool!(entries, names, data, raw)
end

exportcontent(text::AbstractString, images) = LiveJSON.content(text, images)
exportcontent(::Nothing, images) = LiveJSON.content("", images)
exportcontent(value, images) = LiveJSON.content(JSON3.write(value), images)
function exportcontent(values::AbstractVector, images)
    blocks = Dict{String, Any}[]
    foreach(value -> exportblock!(blocks, value), values)
    exportimages!(blocks, images)
end
exportimages!(blocks, ::Nothing) = blocks
function exportimages!(blocks, images::AbstractVector)
    append!(blocks, LiveJSON.image.(images))
end
exportblock!(blocks, value::AbstractString) = push!(blocks, LiveJSON.textblock(value))
exportblock!(blocks, value) = push!(blocks, LiveJSON.textblock(JSON3.write(value)))
exportblock!(blocks, value::AbstractDict) = get(exportblocks, get(value, "type", ""), exportother!)(blocks, value)
exportother!(blocks, value) = push!(blocks, LiveJSON.textblock(JSON3.write(value)))
exporttext!(blocks, value) = push!(blocks, LiveJSON.textblock(get(value, "text", "")))
function exportimage!(blocks, value)
    mime = get(value, "mimeType", get(value, "mime", "application/octet-stream"))
    push!(blocks, Dict{String, Any}("type" => "image", "mimeType" => mime, "data" => get(value, "data", "")))
end
exportimageurl!(blocks, value) = exporturl!(blocks, get(value, "image_url", ""))
exporturl!(blocks, value::AbstractDict) = exporturl!(blocks, get(value, "url", ""))
exporturl!(blocks, value::AbstractString) = exporturl!(blocks, value, match(r"\Adata:([^;,]+);base64,(.*)\z"s, value))
exporturl!(blocks, value, ::Nothing) = push!(blocks, LiveJSON.textblock(value))
function exporturl!(blocks, value, match::RegexMatch)
    push!(blocks, Dict{String, Any}("type" => "image", "mimeType" => String(match[1]), "data" => String(match[2])))
end
const exportblocks = Dict("text" => exporttext!, "image" => exportimage!, "image_url" => exportimageurl!)
