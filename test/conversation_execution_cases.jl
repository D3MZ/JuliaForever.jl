module ConversationExecutionCases

using Distributed, JuliaForever
import JuliaForever.Execution as E

struct Synthetic
    requests::RemoteChannel
    started::RemoteChannel
    release::RemoteChannel
    secret::String
end

function JuliaForever.complete(provider::Synthetic, messages, tools; parameters=Dict())
    put!(provider.requests, (; worker=myid(), messages=deepcopy(messages), tools=sort!(collect(keys(tools))), parameters=deepcopy(parameters)))
    prompt = get(last(messages), "content", nothing)
    if prompt == "block"
        put!(provider.started, myid())
        take!(provider.release)
    elseif prompt == "fail"
        error("provider exposed $(provider.secret)")
    end
    output = if last(messages)["role"] == "tool"
        Any[Dict("id" => "msg-1", "type" => "message", "content" => [Dict("type" => "output_text", "text" => "done")])]
    else
        Any[Dict("id" => "reason-1", "type" => "reasoning", "encrypted_content" => "encrypted-reasoning"), Dict("id" => "item-1", "type" => "function_call", "call_id" => "call-1", "name" => "write", "arguments" => "{\"path\":\"output.txt\",\"content\":\"hello\"}", "status" => "completed")]
    end
    status = prompt == "incomplete" ? "incomplete" : "completed"
    JuliaForever.completion(JuliaForever.OpenAIResponses("synthetic", "synthetic", provider.secret), Dict("status" => status, "output" => output))
end

function install(id, directory, requests, started, release)
    E.install!(id, Synthetic(requests, started, release, "private-fixture-marker"), [Write(directory), Read(directory)]; parameters=Dict("temperature" => 0.2))
end

function install_responses(id, directory, base)
    E.install!(id, OpenAIResponses(base, "synthetic-model", "synthetic-key"), [Write(directory)]; parameters=Dict("reasoning" => Dict("effort" => "low")))
end

end
