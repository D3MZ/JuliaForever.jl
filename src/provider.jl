struct OpenAI
    base::String
    model::String
    key::String
end

struct InvalidResponse end
struct ProviderStatus
    status::Int
end

StructTypes.StructType(::Type{OpenAI}) = StructTypes.CustomStruct()
StructTypes.lower(provider::OpenAI) = (; model=provider.model, credentials="[redacted]")

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

Base.show(io::IO, provider::OpenAI) = print(io, "OpenAI(", repr(provider.model), ", [redacted])")

function providerinfo(selected)
    selected == "openai" && return (; factory=OpenAI, base="OPENAI_BASE_URL", url="https://api.openai.com/v1", model="OPENAI_MODEL", key="OPENAI_API_KEY")
    selected == "openai-responses" && return (; factory=OpenAIResponses, base="OPENAI_BASE_URL", url="https://api.openai.com/v1", model="OPENAI_MODEL", key="OPENAI_API_KEY")
    selected == "openrouter" && return (; factory=OpenAI, base="OPENROUTER_BASE_URL", url="https://openrouter.ai/api/v1", model="OPENROUTER_MODEL", key="OPENROUTER_API_KEY")
    nothing
end

modelvalue(env, name, ::Nothing) = env[name]
modelvalue(env, name, model::AbstractString) = model

provider(::Nothing, env, model) = nothing
provider(info::NamedTuple, env, model) = info.factory(get(env, info.base, info.url), modelvalue(env, info.model, model), env[info.key])
provider(env=ENV) = provider(providerinfo(get(env, "JF_PROVIDER", "openai")), env, nothing)

struct OpenRouterLogin
    url::String
    verifier::String
end

Base.show(io::IO, ::OpenRouterLogin) = print(io, "OpenRouterLogin([redacted])")
StructTypes.StructType(::Type{OpenRouterLogin}) = StructTypes.CustomStruct()
StructTypes.lower(::OpenRouterLogin) = "[redacted]"

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
StructTypes.StructType(::Type{<:OpenRouterCallback}) = StructTypes.CustomStruct()
StructTypes.lower(::OpenRouterCallback) = "[redacted]"

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
    response = HTTP.post("$(rstrip(base, '/'))/auth/keys", ["Content-Type" => "application/json"], body; redirect=false, retry=false, cookies=false, status_exception=false)
    200 <= response.status < 300 || return ProviderStatus(response.status)
    data = decode(String(response.body))
    data isa InvalidResponse && return data
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

struct Completion
    message::Dict{String, Any}
    usage::Union{Nothing, Usage}
    finish::Union{Nothing, String}
    done::Bool
    error::Union{Nothing, String, InvalidResponse, ProviderStatus}
end

incomplete(failure::Union{InvalidResponse, ProviderStatus}) = Completion(Dict{String, Any}("role" => "assistant", "content" => nothing), nothing, nothing, false, failure)

function usage(data)
    prompt = get(data, "prompt_tokens", 0)
    output = get(data, "completion_tokens", 0)
    prompt_details = get(data, "prompt_tokens_details", nothing)
    prompt_details = isnothing(prompt_details) ? Dict() : prompt_details
    output_details = get(data, "completion_tokens_details", nothing)
    output_details = isnothing(output_details) ? Dict() : output_details
    cache_read = get(prompt_details, "cached_tokens", get(data, "prompt_cache_hit_tokens", get(data, "cached_tokens", 0)))
    cache_write = get(prompt_details, "cache_write_tokens", 0)
    reasoning = get(output_details, "reasoning_tokens", 0)
    input = max(0, prompt - cache_read - cache_write)
    cost = get(data, "cost", nothing)
    if !isnothing(cost) && get(data, "is_byok", false)
        details = get(data, "cost_details", nothing)
        cost += isnothing(details) ? 0 : get(details, "upstream_inference_cost", 0)
    end
    Usage(input, output, cache_read, cache_write, reasoning, input + output + cache_read + cache_write, isnothing(cost) ? nothing : Float64(cost))
end

chatmessage!(result, images, message, ::Nothing) = push!(result, message)

function chatmessage!(result, images, message, image)
    if message["role"] == "tool"
        value = copy(message)
        delete!(value, "image")
        push!(result, value)
        push!(images, Dict("type" => "image_url", "image_url" => Dict("url" => "data:$(image["mime"]);base64,$(image["data"])")))
    else
        push!(result, message)
    end
end

function chat(messages)
    result = Any[]
    images = Any[]
    for message in messages
        if message["role"] != "tool" && !isempty(images)
            push!(result, Dict("role" => "user", "content" => [Dict("type" => "text", "text" => "Attached image(s) from tool result:"), images...]))
            empty!(images)
        end
        chatmessage!(result, images, message, get(message, "image", nothing))
    end
    isempty(images) || push!(result, Dict("role" => "user", "content" => [Dict("type" => "text", "text" => "Attached image(s) from tool result:"), images...]))
    result
end

function payload(provider::OpenAI, messages, tools, parameters; streaming=false)
    data = Dict{String, Any}(string(key) => value for (key, value) in pairs(parameters))
    data["model"] = provider.model
    data["messages"] = chat(messages)
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
    response = HTTP.post(endpoint(provider), headers(provider), payload(provider, messages, tools, parameters); redirect=false, retry=false, cookies=false, status_exception=false)
    200 <= response.status < 300 || return incomplete(ProviderStatus(response.status))
    data = decode(String(response.body))
    data isa InvalidResponse && return incomplete(data)
    choice = first(data["choices"])
    finish = get(choice, "finish_reason", nothing)
    raw_usage = get(data, "usage", nothing)
    used = isnothing(raw_usage) ? nothing : usage(raw_usage)
    done = finish in ("stop", "end", "length", "tool_calls", "function_call")
    failure = done ? nothing : "Provider finish_reason: $(isnothing(finish) ? "missing" : finish)"
    Completion(choice["message"], used, finish, done, failure)
end

function stream(provider::OpenAI, messages, tools; parameters=Dict(), on_event=identity)
    message = Dict{String, Any}("role" => "assistant", "content" => nothing)
    calls = Dict{Any, Dict{String, Any}}()
    order = Any[]
    reported_usage = Ref{Union{Nothing, Usage}}(nothing)
    finish = Ref{Union{Nothing, String}}(nothing)
    failure = Ref{Union{Nothing, String, InvalidResponse}}(nothing)
    marker = Ref(false)
    reasoningfield = Ref{Union{Nothing, String}}(nothing)
    response = HTTP.post(endpoint(provider), headers(provider), payload(provider, messages, tools, parameters; streaming=true); redirect=false, retry=false, cookies=false, status_exception=false, sse_callback=event -> begin
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
        raw_usage = get(data, "usage", nothing)
        if !isnothing(raw_usage)
            reported_usage[] = usage(raw_usage)
            on_event((; type=:usage, usage=reported_usage[]))
        end
        choices = get(data, "choices", [])
        isempty(choices) && return
        choice = first(choices)
        reason = get(choice, "finish_reason", nothing)
        if !isnothing(reason)
            finish[] = reason
            on_event((; type=:finish, reason))
        end
        delta = get(choice, "delta", nothing)
        isnothing(delta) && return
        for field in ("reasoning_content", "reasoning", "reasoning_text")
            text = get(delta, field, nothing)
            if text isa AbstractString && !isempty(text)
                reasoningfield[] = something(reasoningfield[], field)
                key = reasoningfield[]
                message[key] = get(message, key, "") * text
                on_event((; type=:thinking, text, field))
                break
            end
        end
        text = get(delta, "content", nothing)
        if text isa AbstractString && !isempty(text)
            current = message["content"]
            message["content"] = isnothing(current) ? text : current * text
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
            !isnothing(id) && isempty(output["id"]) && (output["id"] = id)
            fn = get(call, "function", Dict())
            name = get(fn, "name", nothing)
            !isnothing(name) && isempty(output["function"]["name"]) && (output["function"]["name"] = name)
            arguments = get(fn, "arguments", "")
            output["function"]["arguments"] *= arguments
            on_event((; type=:tool_call, index, id, name, arguments))
        end
    end)
    if !(200 <= response.status < 300)
        result = incomplete(ProviderStatus(response.status))
        on_event((; type=:incomplete, result))
        return result
    end
    isempty(order) || (message["tool_calls"] = [calls[index] for index in order])
    if !(failure[] isa InvalidResponse) && !isnothing(finish[]) && !(finish[] in ("stop", "end", "length", "tool_calls", "function_call"))
        failure[] = "Provider finish_reason: $(finish[])"
    end
    result = Completion(message, reported_usage[], finish[], marker[] && !isnothing(finish[]) && isnothing(failure[]), failure[])
    on_event((; type=result.done ? :done : :incomplete, result))
    result
end
