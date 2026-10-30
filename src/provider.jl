struct OpenAI
    base::String
    model::String
    key::String
end

# Keep request cancellation scoped to the calling task without changing provider APIs.
const requestkey = gensym(:request_context)
requestcontext() = get(task_local_storage(), requestkey, nothing)
requestcontext(provider) = nothing
requestcontext(::OpenAI) = HTTP.RequestContext()

struct InvalidResponse end

function decode(text)
    bytes = codeunits(text)
    complete = false
    try
        data = JSON3.read(bytes, Dict{String, Any})
        complete = true
        return data
    finally
        if !complete && last(current_exceptions()).exception isa ArgumentError
            return InvalidResponse()
        end
    end
end

Base.show(io::IO, provider::OpenAI) = print(io, "OpenAI(", repr(provider.base), ", ", repr(provider.model), ", [redacted])")

openai(env) = OpenAI(get(env, "OPENAI_BASE_URL", "https://api.openai.com/v1"), env["OPENAI_MODEL"], env["OPENAI_API_KEY"])
responses(env) = OpenAIResponses(get(env, "OPENAI_BASE_URL", "https://api.openai.com/v1"), env["OPENAI_MODEL"], env["OPENAI_API_KEY"])
openrouter(env) = OpenAI(get(env, "OPENROUTER_BASE_URL", "https://openrouter.ai/api/v1"), env["OPENROUTER_MODEL"], env["OPENROUTER_API_KEY"])
anthropic(env) = Anthropic(get(env, "ANTHROPIC_BASE_URL", "https://api.anthropic.com"), env["ANTHROPIC_MODEL"], env["ANTHROPIC_API_KEY"])
google(env) = Google(get(env, "GEMINI_BASE_URL", "https://generativelanguage.googleapis.com/v1beta"), env["GEMINI_MODEL"], env["GEMINI_API_KEY"])
unknownprovider(env) = nothing
const providers = Dict("openai" => openai, "openai-responses" => responses, "openrouter" => openrouter, "anthropic" => anthropic, "google" => google)
provider(env=ENV) = get(providers, get(env, "JF_PROVIDER", "openai"), unknownprovider)(env)

struct OpenRouterLogin
    url::String
    verifier::String
end

Base.show(io::IO, login::OpenRouterLogin) = print(io, "OpenRouterLogin(", repr(login.url), ", [redacted])")

base64url(bytes) = rstrip(replace(base64encode(bytes), "+" => "-", "/" => "_"), '=')

function authorize()
    verifier = base64url(rand(RandomDevice(), UInt8, 32))
    challenge = base64url(sha256(verifier))
    OpenRouterLogin("https://openrouter.ai/auth?code_challenge=$challenge&code_challenge_method=S256&key_label=Julia%20Forever", verifier)
end

struct OpenRouterCallback{S}
    server::S
    url::String
    state::String
    result::Channel{Union{Nothing, String}}
end

Base.show(io::IO, ::OpenRouterCallback) = print(io, "OpenRouterCallback([redacted])")

function OpenRouterCallback()
    path = "/oauth/callback/" * base64url(rand(RandomDevice(), UInt8, 24))
    state = String(base64url(rand(RandomDevice(), UInt8, 32)))
    result = Channel{Union{Nothing, String}}(1)
    pending = Ref(true)
    gate = ReentrantLock()
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        request.method == "GET" || return HTTP.Response(405)
        uri = HTTP.URI(request.target)
        uri.path == path || return HTTP.Response(404)
        params = HTTP.queryparampairs(uri)
        codes = [value for (key, value) in params if key == "code"]
        states = [value for (key, value) in params if key == "state"]
        failures = [value for (key, value) in params if key == "error"]
        success = length(codes) == 1 && !isempty(only(codes)) && isempty(failures) && states == [state]
        denied = isempty(codes) && failures == ["access_denied"] && (isempty(states) || states == [state])
        (success || denied) || return HTTP.Response(400)
        lock(gate) do
            pending[] || return HTTP.Response(409)
            pending[] = false
            put!(result, success ? only(codes) : nothing)
            HTTP.Response(200, ["Content-Type" => "text/plain; charset=utf-8", "Cache-Control" => "no-store", "Referrer-Policy" => "no-referrer"], "You may close this window.")
        end
    end
    OpenRouterCallback(server, "http://127.0.0.1:$(HTTP.port(server))$path", state, result)
end

function authorize(callback::OpenRouterCallback)
    login = authorize()
    OpenRouterLogin("$(login.url)&callback_url=$(HTTP.escapeuri(callback.url))&state=$(HTTP.escapeuri(callback.state))", login.verifier)
end

Base.wait(callback::OpenRouterCallback; timeout=300) = timedwait(() -> isready(callback.result), timeout; pollint=0.01) == :ok ? take!(callback.result) : nothing
Base.close(callback::OpenRouterCallback) = (close(callback.server); wait(callback.server); nothing)

function exchange(login::OpenRouterLogin, code; base="https://openrouter.ai/api/v1")
    body = JSON3.write((; code, code_verifier=login.verifier, code_challenge_method="S256"))
    response = HTTP.post("$(rstrip(base, '/'))/auth/keys", ["Content-Type" => "application/json"], body; redirect=false, retry=false, cookies=false)
    apikey(decode(String(response.body)))
end

apikey(failure::InvalidResponse) = failure

function apikey(data::AbstractDict)
    key = get(data, "key", nothing)
    key isa AbstractString && !isempty(key) ? key : nothing
end

struct Usage
    input::Int
    output::Int
    cache_read::Int
    cache_write::Int
    reasoning::Int
    total::Int
    cost::Union{Nothing, Float64}
end

abstract type CompletionStatus end
struct Finished <: CompletionStatus end
struct Unfinished <: CompletionStatus end
const completionstatuses = Dict(true => Finished(), false => Unfinished())
completionstatus(done::Bool) = completionstatuses[done]
finished(::Finished) = true
finished(::Unfinished) = false
completionevent(::Finished) = :done
completionevent(::Unfinished) = :incomplete
JSON3.StructTypes.StructType(::Type{<:CompletionStatus}) = JSON3.StructTypes.CustomStruct()
JSON3.StructTypes.lowertype(::Type{<:CompletionStatus}) = Bool
JSON3.StructTypes.lower(status::CompletionStatus) = finished(status)
JSON3.StructTypes.construct(::Type{CompletionStatus}, done::Bool) = completionstatus(done)

struct Completion
    message::Dict{String, Any}
    usage::Union{Nothing, Usage}
    finish::Union{Nothing, String}
    status::CompletionStatus
    error::Union{Nothing, String, InvalidResponse}

    function Completion(message, usage, finish, status::CompletionStatus, error)
        new(message, usage, finish, status, error)
    end
end
Completion(message, usage, finish, done, error) = Completion(message, usage, finish, completionstatus(convert(Bool, done)), error)
Base.getproperty(result::Completion, name::Symbol) = name === :done ? finished(getfield(result, :status)) : getfield(result, name)
Base.propertynames(::Completion, private::Bool=false) = (:message, :usage, :finish, :done, :error, :status)
completionevent(result::Completion) = completionevent(getfield(result, :status))
JSON3.StructTypes.names(::Type{Completion}) = ((:status, :done),)

incomplete(failure::InvalidResponse) = Completion(Dict{String, Any}("role" => "assistant", "content" => nothing), nothing, nothing, false, failure)

abstract type ChatFinish end
struct ChatAccepted <: ChatFinish
    reason::String
end
struct ChatRejected <: ChatFinish
    reason::String
end
struct ChatMissing <: ChatFinish end
const chatfinishes = Dict("stop" => ChatAccepted, "end" => ChatAccepted, "length" => ChatAccepted, "tool_calls" => ChatAccepted, "function_call" => ChatAccepted)
chatfinish(::Nothing) = ChatMissing()
chatfinish(reason) = get(chatfinishes, reason, ChatRejected)(reason)

chatcompletion(message, used, ::ChatMissing) = Completion(message, used, nothing, false, "Provider finish_reason: missing")
chatcompletion(message, used, status::ChatAccepted) = Completion(message, used, status.reason, true, nothing)
chatcompletion(message, used, status::ChatRejected) = Completion(message, used, status.reason, false, "Provider finish_reason: $(status.reason)")

finishfailure!(failure, ::Union{ChatMissing, ChatAccepted}, previous) = nothing
finishfailure!(failure, ::ChatRejected, ::InvalidResponse) = nothing
finishfailure!(failure, status::ChatRejected, previous) = (failure[] = "Provider finish_reason: $(status.reason)")
finishdone(::ChatMissing, marker, failure) = false
finishdone(::Union{ChatAccepted, ChatRejected}, marker, ::Nothing) = marker
finishdone(::Union{ChatAccepted, ChatRejected}, marker, failure) = false

usage(::Nothing) = nothing
details(::Nothing) = Dict()
details(data) = data
upstream(::Nothing) = 0
upstream(data) = get(data, "upstream_inference_cost", 0)
usagecost(::Nothing, data) = nothing
usagecost(cost, data) = Float64(get(data, "is_byok", false) ? cost + upstream(get(data, "cost_details", nothing)) : cost)

function usage(data)
    prompt = get(data, "prompt_tokens", 0)
    output = get(data, "completion_tokens", 0)
    prompt_details = details(get(data, "prompt_tokens_details", nothing))
    output_details = details(get(data, "completion_tokens_details", nothing))
    cache_read = get(prompt_details, "cached_tokens", get(data, "prompt_cache_hit_tokens", get(data, "cached_tokens", 0)))
    cache_write = get(prompt_details, "cache_write_tokens", 0)
    reasoning = get(output_details, "reasoning_tokens", 0)
    input = max(0, prompt - cache_read - cache_write)
    cost = usagecost(get(data, "cost", nothing), data)
    Usage(input, output, cache_read, cache_write, reasoning, input + output + cache_read + cache_write, cost)
end

recordusage!(reported, callback, ::Nothing) = nothing
function recordusage!(reported, callback, raw)
    reported[] = usage(raw)
    callback((; type=:usage, usage=reported[]))
end

recordfinish!(finish, callback, ::Nothing) = nothing
function recordfinish!(finish, callback, reason)
    finish[] = reason
    callback((; type=:finish, reason))
end

appendtext(::Nothing, text) = text
appendtext(current, text) = current * text
writeonce!(output, key, ::Nothing) = nothing
writeonce!(output, key, value) = isempty(output[key]) && (output[key] = value)

function chatmessage(message)
    data = Dict{String, Any}(string(key) => value for (key, value) in pairs(message))
    delete!(data, "is_error")
    delete!(data, "anthropic_content")
    delete!(data, "anthropic_origin")
    delete!(data, "google_parts")
    delete!(data, "google_origin")
    delete!(data, "response_output")
    data
end

function payload(provider::OpenAI, messages, tools, parameters; streaming=false)
    data = Dict{String, Any}(string(key) => value for (key, value) in pairs(parameters))
    data["model"] = provider.model
    data["messages"] = chatmessage.(messages)
    data["stream"] = streaming
    delete!(data, "tools")
    delete!(data, "stream_options")
    isempty(tools) || (data["tools"] = definition.(collect(values(tools))))
    if streaming
        data["stream_options"] = Dict("include_usage" => true)
    end
    JSON3.write(data)
end

headers(provider::OpenAI) = ["Authorization" => "Bearer $(provider.key)", "Content-Type" => "application/json"]
endpoint(provider::OpenAI) = "$(rstrip(provider.base, '/'))/chat/completions"

function complete(provider::OpenAI, messages, tools; parameters=Dict())
    response = HTTP.post(endpoint(provider), headers(provider), payload(provider, messages, tools, parameters); redirect=false, retry=false, cookies=false, context=requestcontext())
    complete(provider, decode(String(response.body)))
end

complete(provider::OpenAI, failure::InvalidResponse) = incomplete(failure)

function complete(provider::OpenAI, data::AbstractDict)
    choice = first(data["choices"])
    finish = get(choice, "finish_reason", nothing)
    raw_usage = get(data, "usage", nothing)
    used = usage(raw_usage)
    chatcompletion(choice["message"], used, chatfinish(finish))
end

function stream(provider::OpenAI, messages, tools; parameters=Dict(), on_event=identity)
    message = Dict{String, Any}("role" => "assistant", "content" => nothing)
    calls = Dict{Any, Dict{String, Any}}()
    order = Any[]
    reported_usage = Ref{Union{Nothing, Usage}}(nothing)
    finish = Ref{Union{Nothing, String}}(nothing)
    failure = Ref{Union{Nothing, String, InvalidResponse}}(nothing)
    marker = Ref(false)
    HTTP.post(endpoint(provider), headers(provider), payload(provider, messages, tools, parameters; streaming=true); redirect=false, retry=false, cookies=false, context=requestcontext(), sse_callback=event -> begin
        failure[] isa InvalidResponse && return
        if event.data == "[DONE]"
            marker[] = true
            return
        end
        data = decode(event.data)
        if data isa InvalidResponse
            failure[] = data
            return
        end
        on_event((; type=:provider, data))
        if haskey(data, "error")
            failure[] = JSON3.write(data["error"])
            return
        end
        recordusage!(reported_usage, on_event, get(data, "usage", nothing))
        choices = get(data, "choices", [])
        isempty(choices) && return
        choice = first(choices)
        recordfinish!(finish, on_event, get(choice, "finish_reason", nothing))
        delta = get(choice, "delta", nothing)
        isnothing(delta) && return
        for field in ("reasoning_content", "reasoning", "reasoning_text")
            text = get(delta, field, nothing)
            if text isa AbstractString && !isempty(text)
                on_event((; type=:thinking, text, field))
                break
            end
        end
        text = get(delta, "content", nothing)
        if text isa AbstractString && !isempty(text)
            message["content"] = appendtext(message["content"], text)
            on_event((; type=:text, text))
        end
        for call in get(delta, "tool_calls", [])
            index = get(call, "index", get(call, "id", 0))
            if !haskey(calls, index)
                calls[index] = Dict("id" => "", "type" => "function", "function" => Dict("name" => "", "arguments" => ""))
                push!(order, index)
            end
            output = calls[index]
            id = get(call, "id", nothing)
            writeonce!(output, "id", id)
            fn = get(call, "function", Dict())
            name = get(fn, "name", nothing)
            writeonce!(output["function"], "name", name)
            arguments = get(fn, "arguments", "")
            output["function"]["arguments"] *= arguments
            on_event((; type=:tool_call, index, id, name, arguments))
        end
    end)
    isempty(order) || (message["tool_calls"] = [calls[index] for index in order])
    status = chatfinish(finish[])
    finishfailure!(failure, status, failure[])
    result = Completion(message, reported_usage[], finish[], finishdone(status, marker[], failure[]), failure[])
    on_event((; type=completionevent(result), result))
    result
end
