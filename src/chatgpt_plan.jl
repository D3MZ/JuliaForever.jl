endpoint(::ChatGPT.Plan) = "https://api.openai.com/v1/responses"
headers(provider::ChatGPT.Plan) = ["Authorization" => "Bearer $(provider.session.access)", "Content-Type" => "application/json"]
requeststream(provider::ChatGPT.Plan, body, callback) = provider.post(endpoint(provider), headers(provider), body; redirect=false, retry=false, cookies=false, status_exception=false, context=requestcontext(), sse_callback=callback)

struct ChatGPTSystem end
planitem(item) = planitem(item, get(Dict("system" => ChatGPTSystem()), get(item, "role", nothing), nothing))
planitem(item, ::Nothing) = item
planitem(item, ::ChatGPTSystem) = merge(item, Dict("role" => "developer"))

function payload(provider::ChatGPT.Plan, messages, tools, parameters; streaming=true)
    data = Dict{String, Any}(string(key) => value for (key, value) in pairs(parameters))
    items = Any[planitem(item) for item in input(messages)]
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
    result = Completion(Dict{String, Any}("role" => "assistant", "content" => nothing), nothing, nothing, Unfinished(), reason)
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

struct ManagedChatGPT{P, R, N}
    store::ChatGPT.Store
    client::String
    subject::String
    model::String
    secrets::Vector{String}
    post::P
    refresh::R
    now::N
end
ManagedChatGPT(store, client, subject, model, secrets; post=HTTP.post, refresh=ChatGPT.posttoken, now=time) = ManagedChatGPT(store, client, subject, model, secrets, post, refresh, now)

Base.show(io::IO, ::ManagedChatGPT) = print(io, "ManagedChatGPT([redacted])")
StructTypes.StructType(::Type{ManagedChatGPT}) = StructTypes.CustomStruct()
StructTypes.lower(::ManagedChatGPT) = "[redacted]"
requestcontext(::ManagedChatGPT) = HTTP.RequestContext()
requestcontext(::ChatGPT.Plan) = HTTP.RequestContext()

function stream(provider::ManagedChatGPT, messages, tools; parameters=Dict(), on_event=identity)
    session = try
        ChatGPT.refresh(provider.store, provider.client, provider.subject; post=provider.refresh, now=provider.now)
    catch
        ChatGPT.Rejected(:transport)
    end
    streamsession(provider, session, messages, tools; parameters, on_event)
end

chatgptsecrets(session::ChatGPT.Grant) = [session.access, session.id_token]
chatgptsecrets(session::ChatGPT.Session) = [session.access, session.id_token, session.refresh]

function streamsession(provider::ManagedChatGPT, session::ChatGPT.Credential, messages, tools; parameters, on_event)
    append!(provider.secrets, filter(secret -> !isempty(secret) && !(secret in provider.secrets), chatgptsecrets(session)))
    stream(ChatGPT.Plan(provider.model, session; post=provider.post, now=provider.now), messages, tools; parameters, on_event)
end
streamsession(provider::ManagedChatGPT, failure, messages, tools; parameters, on_event) = planfailure(on_event, "ChatGPT session could not be refreshed; run jf --login-chatgpt to sign in again.")
complete(provider::ManagedChatGPT, messages, tools; parameters=Dict()) = stream(provider, messages, tools; parameters)
