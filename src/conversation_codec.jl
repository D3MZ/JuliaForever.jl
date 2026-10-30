# The codec is deliberately restricted to data, not arbitrary Julia objects.
typecode(::Type) = Rejected(:unsupported_value)
typecode(::Type{Any}) = "any"
typecode(::Type{Nothing}) = "nothing"
typecode(::Type{Bool}) = "bool"
typecode(::Type{Int}) = "int"
typecode(::Type{Float64}) = "float"
typecode(::Type{String}) = "string"

typecode(::Type{Vector{T}}) where T = typecode("vector", typecode(T))
typecode(::Type{Dict{String, T}}) where T = typecode("dict", typecode(T))
typecode(kind, code::Rejected) = code
typecode(kind, code) = Any[kind, code]

valuetype(code) = Rejected(:invalid_record)
const valuetypes = Dict("any" => Any, "nothing" => Nothing, "bool" => Bool, "int" => Int, "float" => Float64, "string" => String)
const containertypes = Dict("vector" => Vector, "dict" => Dict)
valuetype(code::AbstractString) = get(valuetypes, code, Rejected(:invalid_record))

function valuetype(code::Vector)
    length(code) == 2 || return Rejected(:invalid_record)
    valuetype(get(containertypes, code[1], nothing), valuetype(code[2]))
end

valuetype(kind, rejected::Rejected) = rejected
valuetype(::Nothing, type::Type) = Rejected(:invalid_record)
valuetype(::Type{Vector}, type::Type) = Vector{type}
valuetype(::Type{Dict}, type::Type) = Dict{String, type}

packvalue(x, seen=IdDict()) = Rejected(:unsupported_value)
packvalue(x::Union{Nothing, Bool, Int, Float64, String}, seen=IdDict()) = value(x, seen)

packvalue(xs::Vector{T}, seen=IdDict()) where T = packvalue("vector", xs, seen, typecode(T))
packvalue(xs::Dict{String, T}, seen=IdDict()) where T = packvalue("dict", xs, seen, typecode(T))
packvalue(kind, xs, seen, rejected::Rejected) = rejected

function packvalue(kind, xs, seen, code)
    haskey(seen, xs) && return Rejected(:unsupported_value)
    seen[xs] = nothing
    try
        items = foldl((result, item) -> packvalueitem(result, item, seen), xs; init=packitems(xs))
        packedvalues(kind, code, items)
    finally
        delete!(seen, xs)
    end
end

packitems(::Vector) = Any[]
packitems(::Dict) = Dict{String, Any}()
packvalueitem(rejected::Rejected, item, seen) = rejected
packvalueitem(items::Vector, item, seen) = packed(items, packvalue(item, seen))
function packvalueitem(items::Dict, pair::Pair, seen)
    key, item = pair
    isvalid(key) || return Rejected(:unsupported_value)
    packed(items, key, packvalue(item, seen))
end
packed(items::Dict, key, rejected::Rejected) = rejected
packed(items::Dict, key, item) = (items[key] = item; items)
packedvalues(kind, code, rejected::Rejected) = rejected
packedvalues(kind, code, items) = Dict("kind" => kind, "type" => code, "items" => items)

unvalue(x::Union{Nothing, Bool, Int, Float64, String}) = value(x, IdDict())
unvalue(x) = Rejected(:invalid_record)

unvalue(x::Dict) = unvalue(x, valuetype(x["type"]))
unvalue(x::Dict, rejected::Rejected) = rejected
unvalue(x::Dict, type::Type) = unvalue(get(containertypes, x["kind"], nothing), get(x, "items", nothing), type)
unvalue(kind, items, type) = Rejected(:invalid_record)

unvalue(::Type{Vector}, items::Vector, type::Type) = foldl(unvalueitem, items; init=type[])
unvalue(::Type{Dict}, items::Dict, type::Type) = foldl(unvalueitem, items; init=Dict{String, type}())

unvalueitem(rejected::Rejected, item) = rejected
unvalueitem(items::Vector, item) = unvalued(items, unvalue(item))
unvalueitem(items::Dict, pair::Pair) = unvaluekey(items, first(pair), last(pair))
unvaluekey(items, key, item) = Rejected(:invalid_record)
function unvaluekey(items, key::String, item)
    isvalid(key) || return Rejected(:invalid_record)
    unvalued(items, key, unvalue(item))
end
unvalued(items::Vector, rejected::Rejected) = rejected
unvalued(items::Dict, key, rejected::Rejected) = rejected
unvalued(items::Vector, item) = unvaluedtype(items, item)
unvalued(items::Dict, key, item) = unvaluedtype(items, key, item)
unvaluedtype(items::Vector, item) = Rejected(:invalid_record)
unvaluedtype(items::Vector{T}, item::T) where T = push!(items, item)
unvaluedtype(items::Dict, key, item) = Rejected(:invalid_record)
unvaluedtype(items::Dict{String, T}, key, item::T) where T = (items[key] = item; items)

rejection(result, field) = result
rejection(::Nothing, field::Rejected) = field

node(kind, fields...) = node(kind, fields, foldl(rejection, fields; init=nothing))
node(kind, fields::Tuple, rejected::Rejected) = rejected

function node(kind, fields::Tuple, ::Nothing)
    data = Dict("kind" => kind, "fields" => Any[fields...])
    validated(data, value(data, IdDict()))
end

validated(data, checked::Rejected) = checked
validated(data, checked) = data

packall(xs) = foldl(packitem, xs; init=Any[])
packitem(rejected::Rejected, item) = rejected
packitem(items::Vector, item) = packed(items, pack(item))
packed(items::Vector, rejected::Rejected) = rejected
packed(items::Vector, item) = push!(items, item)

pack(x) = Rejected(:unsupported_value)
pack(x::C.User) = node("user", x.content)
pack(x::C.Summary) = node("summary", x.content)
pack(x::C.SkillContext) = node("skill_context", x.content)
pack(x::C.ImageUser) = node("user_images", x.content, packall(x.images))
pack(x::C.RawMessage) = node("raw", packvalue(x.value))
pack(x::C.BashMessage) = node("bash_message", x.command, x.output, x.exitcode, C.bashcancelled(x.status), C.bashtruncated(x.extent), x.file, x.timestamp, C.bashexcluded(x.context))
pack(x::C.ToolCall) = node("tool_call", x.id, x.name, x.arguments, packvalue(x.metadata))
pack(x::C.Assistant) = node("assistant", x.content, packall(x.calls), x.finish, x.done, packvalue(x.metadata))
pack(x::C.ToolMessage) = pack(x, x.image)
pack(x::C.ToolMessage, ::Nothing) = node("tool_message", x.id, x.content, x.iserror)
pack(x::C.ToolMessage, image::C.Image) = node("tool_message", x.id, x.content, x.iserror, pack(image))
pack(x::C.ModelRequest) = node("model_request", packall(x.messages))
pack(x::C.ToolRequest) = node("tool_request", pack(x.call))
pack(x::C.SkipRequest) = node("skip_request", pack(x.call))
pack(x::C.ModelReply) = node("model_reply", pack(x.message))
pack(x::C.ToolReply) = packreply(x.result)
packreply(result::ToolResult) = pack(result, result.image)
pack(result::ToolResult, ::Nothing) = node("tool_reply", result.text, result.iserror)
pack(result::ToolResult, image::C.Image) = node("tool_reply", result.text, result.iserror, pack(image))
packreply(result::ToolDiscovery) = node("tool_discovery_reply", packreply(result.result), loaded(result))
packreply(result::ToolLoaded) = node("tool_search_reply", result.text, loaded(result))
pack(x::C.Image) = node("image", x.mime, x.data)
pack(x::C.ModelFailure) = node("model_failure", x.reason)
pack(x::C.Abandoned) = node("abandoned", x.reason)
pack(x::C.Input) = node("input", x.revision, x.text)
pack(x::C.ImageInput) = node("input_images", x.revision, x.text, packall(x.images))
pack(x::C.Steer) = node("steer", x.revision, x.text)
pack(x::C.Followup) = node("followup", x.revision, x.text)
pack(x::C.Dequeue) = node("dequeue", x.revision)
pack(x::C.SessionName) = node("session_name", x.revision, x.name)
pack(x::C.BashOutput) = node("bash_output", x.revision, pack(x.message))
pack(x::C.ContinueQueued) = node("continue_queued", x.revision)
pack(x::C.Continue) = node("continue", x.revision)
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

unpackall(xs, type) = Rejected(:invalid_record)
unpackall(xs::Vector, type) = foldl(unpackitem, xs; init=type[])
unpackitem(rejected::Rejected, item) = rejected
unpackitem(items::Vector, item) = unpacked(items, unpack(item))
unpacked(items::Vector, item) = Rejected(:invalid_record)
unpacked(items::Vector{T}, item::T) where T = push!(items, item)

const nodetypes = Dict(
    "user" => C.User, "user_images" => C.ImageUser, "summary" => C.Summary, "skill_context" => C.SkillContext, "raw" => C.RawMessage, "bash_message" => C.BashMessage, "tool_call" => C.ToolCall, "assistant" => C.Assistant,
    "tool_message" => C.ToolMessage, "model_request" => C.ModelRequest, "tool_request" => C.ToolRequest,
    "skip_request" => C.SkipRequest, "model_reply" => C.ModelReply, "tool_reply" => C.ToolReply,
    "tool_search_reply" => ToolLoaded, "tool_discovery_reply" => ToolDiscovery,
    "model_failure" => C.ModelFailure, "abandoned" => C.Abandoned, "input" => C.Input, "input_images" => C.ImageInput, "steer" => C.Steer,
    "followup" => C.Followup, "dequeue" => C.Dequeue, "session_name" => C.SessionName, "bash_output" => C.BashOutput, "continue_queued" => C.ContinueQueued, "continue" => C.Continue, "advance" => C.Advance, "cancel" => C.Cancel, "history" => C.History,
    "interrupt" => C.Interrupt, "abandon" => C.Abandon, "call" => K.Call, "return" => K.Return,
    "fail" => K.Fail, "plan" => K.Plan, "observe" => K.Observe, "finish" => K.Finish, "image" => C.Image,
)

unpack(x) = Rejected(:invalid_record)
unpack(x::Dict) = unpack(get(nodetypes, x["kind"], nothing), x["fields"])
unpack(type, fields) = Rejected(:invalid_record)
unpack(::Type{C.User}, f::Vector) = C.User(f[1])
unpack(::Type{C.Summary}, f::Vector) = C.Summary(f[1])
unpack(::Type{C.SkillContext}, f::Vector) = C.SkillContext(f[1])
unpack(::Type{C.ImageUser}, f::Vector) = C.ImageUser(f[1], unpackall(f[2], C.Image))
unpack(::Type{C.RawMessage}, f::Vector) = C.RawMessage(unvalue(f[1]))
unpack(::Type{C.BashMessage}, f::Vector) = C.BashMessage(f[1], f[2], f[3], f[4], f[5], f[6], f[7], C.bashcontext(f[8]))
unpack(::Type{C.ToolCall}, f::Vector) = C.ToolCall(f[1], f[2], f[3], unvalue(f[4]))
unpack(::Type{C.Assistant}, f::Vector) = C.Assistant(f[1], unpackall(f[2], C.ToolCall), f[3], f[4], unvalue(f[5]))
unpackimage(::Nothing) = nothing
unpackimage(value) = unpack(value)
unpack(::Type{C.ToolMessage}, f::Vector) = C.ToolMessage(f[1], f[2], f[3], unpackimage(get(f, 4, nothing)))
unpack(::Type{C.ModelRequest}, f::Vector) = C.ModelRequest(unpackall(f[1], C.Message))
unpack(::Type{C.ToolRequest}, f::Vector) = C.ToolRequest(unpack(f[1]))
unpack(::Type{C.SkipRequest}, f::Vector) = C.SkipRequest(unpack(f[1]))
unpack(::Type{C.ModelReply}, f::Vector) = C.ModelReply(unpack(f[1]))
unpack(::Type{C.ToolReply}, f::Vector) = C.ToolReply(f[1], f[2], unpackimage(get(f, 3, nothing)))
unpack(::Type{C.Image}, f::Vector) = C.Image(f[1], f[2])
unpack(::Type{ToolDiscovery}, f::Vector) = C.ToolReply(ToolDiscovery(unpack(f[1]).result, String[f[2]...]))
unpack(::Type{ToolLoaded}, f::Vector) = C.ToolReply(ToolLoaded(f[1], String[f[2]...]))
unpack(::Type{C.ModelFailure}, f::Vector) = C.ModelFailure(f[1])
unpack(::Type{C.Abandoned}, f::Vector) = C.Abandoned(f[1])
unpack(::Type{C.Input}, f::Vector) = C.Input(f[1], f[2])
unpack(::Type{C.ImageInput}, f::Vector) = C.ImageInput(f[1], f[2], unpackall(f[3], C.Image))
unpack(::Type{C.Steer}, f::Vector) = C.Steer(f[1], f[2])
unpack(::Type{C.Followup}, f::Vector) = C.Followup(f[1], f[2])
unpack(::Type{C.Dequeue}, f::Vector) = C.Dequeue(f[1])
unpack(::Type{C.SessionName}, f::Vector) = C.SessionName(f[1], f[2])
unpack(::Type{C.BashOutput}, f::Vector) = C.BashOutput(f[1], unpack(f[2]))
unpack(::Type{C.ContinueQueued}, f::Vector) = C.ContinueQueued(f[1])
unpack(::Type{C.Continue}, f::Vector) = C.Continue(f[1])
unpack(::Type{C.Advance}, f::Vector) = C.Advance(f[1])
unpack(::Type{C.Cancel}, f::Vector) = C.Cancel(f[1])
unpack(::Type{C.History}, f::Vector) = C.History(f[1], unpackall(f[2], C.Message))
unpack(::Type{C.Interrupt}, f::Vector) = C.Interrupt(f[1], f[2])
unpack(::Type{C.Abandon}, f::Vector) = C.Abandon(f[1], f[2])
unpack(::Type{K.Call}, f::Vector) = K.Call(f[1], unvalue(f[2]))
unpack(::Type{K.Return}, f::Vector) = K.Return(unvalue(f[1]))
unpack(::Type{K.Fail}, f::Vector) = K.Fail(unvalue(f[1]))
unpack(::Type{K.Plan}, f::Vector) = K.Plan(f[1], f[2], unpack(f[3]))
unpack(::Type{K.Observe}, f::Vector) = K.Observe(f[1], f[2], unpack(f[3]))
unpack(::Type{K.Finish}, f::Vector) = K.Finish(f[1])

encode(event::K.Event) = encoded(pack(event))
encoded(rejected::Rejected) = rejected
encoded(data) = Dict("format" => "JuliaForever.AgentEvent/1", "event" => data)

decode_event(record) = Rejected(:invalid_record)
function decode_event(record::Dict)
    try
        get(record, "format", nothing) == "JuliaForever.AgentEvent/1" || return Rejected(:invalid_record)
        decoded_event(record, unpack(record["event"]))
    catch
        Rejected(:invalid_record)
    end
end

decoded_event(record, event) = Rejected(:invalid_record)
decoded_event(record, event::K.Event) = isequal(pack(event), record["event"]) ? event : Rejected(:invalid_record)

function encode_initial(state::C.State)
    state.revision == 0 && state.kernel.revision == 0 || return Rejected(:unsupported_value)
    encode_initial(state, state.phase)
end

encode_initial(state::C.State, phase::C.Phase) = Rejected(:unsupported_value)
encode_initial(state::C.State, ::C.ReadyPhase) = encode_initial(state, packall(state.messages))
encode_initial(state::C.State, rejected::Rejected) = rejected
encode_initial(state::C.State, messages::Vector) = Dict("format" => "JuliaForever.Agent/1", "id" => state.kernel.id, "automatic" => state.automatic, "messages" => messages)

decode_initial(record) = Rejected(:invalid_record)
function decode_initial(record::Dict)
    try
        get(record, "format", nothing) == "JuliaForever.Agent/1" || return Rejected(:invalid_record)
        decode_initial(record, unpackall(record["messages"], C.Message))
    catch
        Rejected(:invalid_record)
    end
end

decode_initial(record, rejected::Rejected) = rejected
decode_initial(record, messages::Vector) = decode_initial(record, messages, record["automatic"])
decode_initial(record, messages::Vector, automatic) = Rejected(:invalid_record)
function decode_initial(record, messages::Vector, automatic::Bool)
    state = C.State(record["id"]; automatic, messages)
    isequal(encode_initial(state), record) ? state : Rejected(:invalid_record)
end
