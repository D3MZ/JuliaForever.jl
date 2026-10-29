# The codec is deliberately restricted to data, not arbitrary Julia objects.
typecode(::Type) = Rejected(:unsupported_value)
typecode(::Type{Any}) = "any"
typecode(::Type{Nothing}) = "nothing"
typecode(::Type{Bool}) = "bool"
typecode(::Type{Int}) = "int"
typecode(::Type{Float64}) = "float"
typecode(::Type{String}) = "string"

function typecode(::Type{Vector{T}}) where T
    code = typecode(T)
    code isa Rejected ? code : Any["vector", code]
end

function typecode(::Type{Dict{String, T}}) where T
    code = typecode(T)
    code isa Rejected ? code : Any["dict", code]
end

function valuetype(code)
    code == "any" && return Any
    code == "nothing" && return Nothing
    code == "bool" && return Bool
    code == "int" && return Int
    code == "float" && return Float64
    code == "string" && return String
    code isa Vector && length(code) == 2 || return Rejected(:invalid_record)
    type = valuetype(code[2])
    type isa Rejected && return type
    code[1] == "vector" && return Vector{type}
    code[1] == "dict" && return Dict{String, type}
    Rejected(:invalid_record)
end

packvalue(x, seen=IdDict()) = Rejected(:unsupported_value)
packvalue(x::Union{Nothing, Bool, Int, Float64, String}, seen=IdDict()) = value(x, seen)

function packvalue(xs::Vector{T}, seen=IdDict()) where T
    code = typecode(T)
    code isa Rejected && return code
    haskey(seen, xs) && return Rejected(:unsupported_value)
    seen[xs] = nothing
    try
        items = Any[]
        for x in xs
            item = packvalue(x, seen)
            item isa Rejected && return item
            push!(items, item)
        end
        Dict("kind" => "vector", "type" => code, "items" => items)
    finally
        delete!(seen, xs)
    end
end

function packvalue(xs::Dict{String, T}, seen=IdDict()) where T
    code = typecode(T)
    code isa Rejected && return code
    haskey(seen, xs) && return Rejected(:unsupported_value)
    seen[xs] = nothing
    try
        items = Dict{String, Any}()
        for (key, x) in xs
            isvalid(key) || return Rejected(:unsupported_value)
            item = packvalue(x, seen)
            item isa Rejected && return item
            items[key] = item
        end
        Dict("kind" => "dict", "type" => code, "items" => items)
    finally
        delete!(seen, xs)
    end
end

unvalue(x::Union{Nothing, Bool, Int, Float64, String}) = value(x, IdDict())
unvalue(x) = Rejected(:invalid_record)

function unvalue(x::Dict)
    type = valuetype(x["type"])
    type isa Rejected && return type
    if x["kind"] == "vector" && x["items"] isa Vector
        result = type[]
        for item in x["items"]
            item = unvalue(item)
            item isa Rejected && return item
            item isa type || return Rejected(:invalid_record)
            push!(result, item)
        end
        return result
    elseif x["kind"] == "dict" && x["items"] isa Dict
        result = Dict{String, type}()
        for (key, item) in x["items"]
            key isa String && isvalid(key) || return Rejected(:invalid_record)
            item = unvalue(item)
            item isa Rejected && return item
            item isa type || return Rejected(:invalid_record)
            result[key] = item
        end
        return result
    end
    Rejected(:invalid_record)
end

function node(kind, fields...)
    for field in fields
        field isa Rejected && return field
    end
    data = Dict("kind" => kind, "fields" => Any[fields...])
    checked = value(data, IdDict())
    checked isa Rejected ? checked : data
end

function packall(xs)
    items = Any[]
    for x in xs
        item = pack(x)
        item isa Rejected && return item
        push!(items, item)
    end
    items
end

pack(x) = Rejected(:unsupported_value)
pack(x::C.User) = node("user", x.content)
pack(x::C.RawMessage) = node("raw", packvalue(x.value))
pack(x::C.ToolCall) = node("tool_call", x.id, x.name, x.arguments, packvalue(x.metadata))
pack(x::C.Assistant) = node("assistant", x.content, packall(x.calls), x.finish, x.done, packvalue(x.metadata))
pack(x::C.ToolMessage) = pack(x, x.image)
pack(x::C.ToolMessage, ::Nothing) = node("tool_message", x.id, x.content, x.iserror)
pack(x::C.ToolMessage, image::C.Image) = node("tool_message", x.id, x.content, x.iserror, pack(image))
pack(x::C.ModelRequest) = node("model_request", packall(x.messages))
pack(x::C.ToolRequest) = node("tool_request", pack(x.call))
pack(x::C.SkipRequest) = node("skip_request", pack(x.call))
pack(x::C.ModelReply) = node("model_reply", pack(x.message))
pack(x::C.ToolReply) = pack(x, x.image)
pack(x::C.ToolReply, ::Nothing) = node("tool_reply", x.text, x.iserror)
pack(x::C.ToolReply, image::C.Image) = node("tool_reply", x.text, x.iserror, pack(image))
pack(x::C.Image) = node("image", x.mime, x.data)
pack(x::C.ModelFailure) = node("model_failure", x.reason)
pack(x::C.Abandoned) = node("abandoned", x.reason)
pack(x::C.Input) = node("input", x.revision, x.text)
pack(x::C.Steer) = node("steer", x.revision, x.text)
pack(x::C.Followup) = node("followup", x.revision, x.text)
pack(x::C.Advance) = node("advance", x.revision)
pack(x::C.Cancel) = node("cancel", x.revision)
pack(x::C.History) = node("history", x.revision, packall(x.messages))
pack(x::C.Interrupt) = node("interrupt", x.revision, x.reason)
pack(x::C.Abandon) = node("abandon", x.revision, x.reason)
pack(x::K.Call) = node("call", x.name, packvalue(x.input))
pack(x::K.Return) = node("return", packvalue(x.value))
pack(x::K.Fail) = node("fail", packvalue(x.value))
pack(x::K.Plan) = node("plan", x.revision, x.id, pack(x.effect))
pack(x::K.Observe) = node("observe", x.revision, x.id, pack(x.observation))
pack(x::K.Finish) = node("finish", x.revision)

function unpackall(xs, type)
    xs isa Vector || return Rejected(:invalid_record)
    items = type[]
    for x in xs
        item = unpack(x)
        item isa type || return Rejected(:invalid_record)
        push!(items, item)
    end
    items
end

function unpack(x)
    x isa Dict || return Rejected(:invalid_record)
    kind, f = x["kind"], x["fields"]
    f isa Vector || return Rejected(:invalid_record)
    kind == "user" && return C.User(f[1])
    kind == "raw" && return C.RawMessage(unvalue(f[1]))
    kind == "tool_call" && return C.ToolCall(f[1], f[2], f[3], unvalue(f[4]))
    kind == "assistant" && return C.Assistant(f[1], unpackall(f[2], C.ToolCall), f[3], f[4], unvalue(f[5]))
    kind == "tool_message" && return C.ToolMessage(f[1], f[2], f[3], length(f) == 3 ? nothing : unpack(f[4]))
    kind == "model_request" && return C.ModelRequest(unpackall(f[1], C.Message))
    kind == "tool_request" && return C.ToolRequest(unpack(f[1]))
    kind == "skip_request" && return C.SkipRequest(unpack(f[1]))
    kind == "model_reply" && return C.ModelReply(unpack(f[1]))
    kind == "tool_reply" && return C.ToolReply(f[1], f[2], length(f) == 2 ? nothing : unpack(f[3]))
    kind == "image" && return C.Image(f[1], f[2])
    kind == "model_failure" && return C.ModelFailure(f[1])
    kind == "abandoned" && return C.Abandoned(f[1])
    kind == "input" && return C.Input(f[1], f[2])
    kind == "steer" && return C.Steer(f[1], f[2])
    kind == "followup" && return C.Followup(f[1], f[2])
    kind == "advance" && return C.Advance(f[1])
    kind == "cancel" && return C.Cancel(f[1])
    kind == "history" && return C.History(f[1], unpackall(f[2], C.Message))
    kind == "interrupt" && return C.Interrupt(f[1], f[2])
    kind == "abandon" && return C.Abandon(f[1], f[2])
    kind == "call" && return K.Call(f[1], unvalue(f[2]))
    kind == "return" && return K.Return(unvalue(f[1]))
    kind == "fail" && return K.Fail(unvalue(f[1]))
    kind == "plan" && return K.Plan(f[1], f[2], unpack(f[3]))
    kind == "observe" && return K.Observe(f[1], f[2], unpack(f[3]))
    kind == "finish" && return K.Finish(f[1])
    Rejected(:invalid_record)
end

function encode(event::K.Event)
    data = pack(event)
    data isa Rejected ? data : Dict("format" => "JuliaForever.AgentEvent/1", "event" => data)
end

function decode_event(record)
    try
        record isa Dict && get(record, "format", nothing) == "JuliaForever.AgentEvent/1" || return Rejected(:invalid_record)
        event = unpack(record["event"])
        event isa K.Event && isequal(pack(event), record["event"]) ? event : Rejected(:invalid_record)
    catch
        Rejected(:invalid_record)
    end
end

function encode_initial(state::C.State)
    state.revision == 0 && state.kernel.revision == 0 && state.phase == C.Ready || return Rejected(:unsupported_value)
    messages = packall(state.messages)
    messages isa Rejected ? messages : Dict("format" => "JuliaForever.Agent/1", "id" => state.kernel.id, "automatic" => state.automatic, "messages" => messages)
end

function decode_initial(record)
    try
        record isa Dict && get(record, "format", nothing) == "JuliaForever.Agent/1" || return Rejected(:invalid_record)
        messages = unpackall(record["messages"], C.Message)
        messages isa Rejected && return messages
        record["automatic"] isa Bool || return Rejected(:invalid_record)
        state = C.State(record["id"]; automatic=record["automatic"], messages)
        isequal(encode_initial(state), record) ? state : Rejected(:invalid_record)
    catch
        Rejected(:invalid_record)
    end
end
