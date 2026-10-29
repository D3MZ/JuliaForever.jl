struct OpenAI
    base::String
    model::String
    key::String
end

Base.show(io::IO, provider::OpenAI) = print(io, "OpenAI(", repr(provider.base), ", ", repr(provider.model), ", [redacted])")

function provider(env=ENV)
    selected = get(env, "JF_PROVIDER", "openai")
    selected == "openai" && return OpenAI(get(env, "OPENAI_BASE_URL", "https://api.openai.com/v1"), env["OPENAI_MODEL"], env["OPENAI_API_KEY"])
    selected == "openai-responses" && return OpenAIResponses(get(env, "OPENAI_BASE_URL", "https://api.openai.com/v1"), env["OPENAI_MODEL"], env["OPENAI_API_KEY"])
    selected == "openrouter" && return OpenAI(get(env, "OPENROUTER_BASE_URL", "https://openrouter.ai/api/v1"), env["OPENROUTER_MODEL"], env["OPENROUTER_API_KEY"])
    nothing
end

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

function exchange(login::OpenRouterLogin, code; base="https://openrouter.ai/api/v1")
    body = JSON3.write((; code, code_verifier=login.verifier, code_challenge_method="S256"))
    response = HTTP.post("$(rstrip(base, '/'))/auth/keys", ["Content-Type" => "application/json"], body; redirect=false, retry=false, cookies=false)
    data = JSON3.read(String(response.body), Dict{String, Any})
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
    error::Union{Nothing, String}
end

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

function payload(provider::OpenAI, messages, tools, parameters; streaming=false)
    data = Dict{String, Any}(string(key) => value for (key, value) in pairs(parameters))
    data["model"] = provider.model
    data["messages"] = messages
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
    response = HTTP.post(endpoint(provider), headers(provider), payload(provider, messages, tools, parameters); redirect=false, retry=false, cookies=false)
    JSON3.read(String(response.body), Dict{String, Any})["choices"][1]["message"]
end

function stream(provider::OpenAI, messages, tools; parameters=Dict(), on_event=identity)
    message = Dict{String, Any}("role" => "assistant", "content" => nothing)
    calls = Dict{Any, Dict{String, Any}}()
    order = Any[]
    reported_usage = Ref{Union{Nothing, Usage}}(nothing)
    finish = Ref{Union{Nothing, String}}(nothing)
    failure = Ref{Union{Nothing, String}}(nothing)
    marker = Ref(false)
    HTTP.post(endpoint(provider), headers(provider), payload(provider, messages, tools, parameters; streaming=true); redirect=false, retry=false, cookies=false, sse_callback=event -> begin
        if event.data == "[DONE]"
            marker[] = true
            return
        end
        data = JSON3.read(event.data, Dict{String, Any})
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
    isempty(order) || (message["tool_calls"] = [calls[index] for index in order])
    if !isnothing(finish[]) && !(finish[] in ("stop", "end", "length", "tool_calls", "function_call"))
        failure[] = "Provider finish_reason: $(finish[])"
    end
    result = Completion(message, reported_usage[], finish[], marker[] && !isnothing(finish[]) && isnothing(failure[]), failure[])
    on_event((; type=result.done ? :done : :incomplete, result))
    result
end
