endpoint(::ChatGPT.Plan) = "https://api.openai.com/v1/responses"
headers(provider::ChatGPT.Plan) = ["Authorization" => "Bearer $(provider.session.access)", "Content-Type" => "application/json"]
requeststream(provider::ChatGPT.Plan, body, callback) = provider.post(endpoint(provider), headers(provider), body; redirect=false, retry=false, cookies=false, sse_callback=callback)

function payload(provider::ChatGPT.Plan, messages, tools, parameters; streaming=true)
    data = Dict{String, Any}(string(key) => value for (key, value) in pairs(parameters))
    items = Any[get(item, "role", nothing) == "system" ? merge(item, Dict("role" => "developer")) : item for item in input(messages)]
    if !isempty(tools)
        definitions = [merge(Dict("type" => "function", "strict" => false), definition(tool)["function"]) for tool in values(tools)]
        pushfirst!(items, Dict("type" => "additional_tools", "role" => "developer", "tools" => definitions))
    end
    data["model"] = provider.model
    data["input"] = items
    data["store"] = false
    data["stream"] = true
    data["include"] = ["reasoning.encrypted_content"]
    JSON3.write(data)
end

function planfailure(on_event, reason)
    result = Completion(Dict{String, Any}("role" => "assistant", "content" => nothing), nothing, nothing, false, reason)
    on_event((; type=:incomplete, result))
    result
end

function stream(provider::ChatGPT.Plan, messages, tools; parameters=Dict(), on_event=identity)
    ChatGPT.direct in split(provider.session.scope) || return planfailure(on_event, "ChatGPT plan permission is missing")
    provider.now() < provider.session.expires || return planfailure(on_event, "ChatGPT session has expired")
    all(key -> string(key) in ("reasoning", "text", "parallel_tool_calls"), keys(parameters)) || return planfailure(on_event, "Unsupported ChatGPT plan parameter")
    streamresponse(provider, messages, tools; parameters, on_event)
end

complete(provider::ChatGPT.Plan, messages, tools; parameters=Dict()) = stream(provider, messages, tools; parameters)
