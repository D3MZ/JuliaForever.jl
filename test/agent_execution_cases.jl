module AgentExecutionCases

using Distributed, JuliaForever
import JuliaForever.Execution as E

struct Synthetic
    requests::RemoteChannel
    started::RemoteChannel
    release::RemoteChannel
    secret::String
end

struct DelayedWrite <: JuliaForever.Tool
    directory::String
    started::RemoteChannel
    release::RemoteChannel
end

JuliaForever.name(::DelayedWrite) = "write"
function JuliaForever.execute(tool::DelayedWrite, args)
    write(joinpath(tool.directory, String(args.path)), String(args.content))
    put!(tool.started, myid())
    take!(tool.release)
    ToolResult("written")
end

struct GateWrite <: JuliaForever.Tool
    directory::String
    started::RemoteChannel
    release::RemoteChannel
    before::Bool
end

JuliaForever.name(::GateWrite) = "write"
function JuliaForever.execute(tool::GateWrite, args)
    if tool.before
        put!(tool.started, myid())
        take!(tool.release)
    end
    open(joinpath(tool.directory, String(args.path)), "a") do io
        write(io, String(args.content))
    end
    if !tool.before
        put!(tool.started, myid())
        take!(tool.release)
    end
    ToolResult("written")
end

function install_gate(id, directory, requests, started, release, before)
    E.install!(id, Synthetic(requests, started, release, "fixture-secret"), [GateWrite(directory, started, release, before)])
end

function JuliaForever.complete(provider::Synthetic, messages, tools; parameters=Dict())
    put!(provider.requests, (; worker=myid(), messages=deepcopy(messages), parameters=deepcopy(parameters)))
    prompt = only(message["content"] for message in messages if message["role"] == "user" && message["content"] != "steer")
    if prompt == "block" || prompt == "block-once" && !any(message -> message["role"] == "tool", messages)
        put!(provider.started, myid())
        take!(provider.release)
    elseif prompt == "fail"
        error("synthetic provider $(provider.secret)")
    end
    message = Dict{String, Any}("role" => "assistant", "content" => "done")
    finish = "stop"
    done = true
    usage = nothing
    failure = nothing
    if prompt == "usage"
        usage = Usage(1, 1, 0, 0, 0, 2, nothing)
    elseif prompt == "error-metadata"
        done = false
        failure = "private error detail"
    elseif prompt == "error-done"
        failure = "private error detail"
    elseif prompt == "incomplete"
        done = false
    elseif !any(message -> message["role"] == "tool", messages)
        message["content"] = nothing
        message["response_output"] = Any[Dict("type" => "reasoning", "encrypted_content" => "synthetic-encrypted")]
        calls = [Dict("id" => "one", "type" => "function", "function" => Dict("name" => "write", "arguments" => "{\"path\":\"a.txt\",\"content\":\"hello\"}"))]
        if prompt == "two"
            push!(calls, Dict("id" => "two", "type" => "function", "function" => Dict("name" => "read", "arguments" => "{\"path\":\"missing.txt\"}")))
        end
        message["tool_calls"] = calls
        finish = prompt == "length" ? "length" : "tool_calls"
    end
    Completion(message, usage, finish, done, failure)
end

function install(id, directory, requests, started, release)
    E.install!(id, Synthetic(requests, started, release, "fixture-secret"), [Write(directory), Read(directory)]; parameters=Dict("temperature" => 0.2))
end

function install_responses(id, directory, base)
    E.install!(id, OpenAIResponses(base, "synthetic-model", "synthetic-key"), [Write(directory)])
end

function install_chat(id, base)
    E.install!(id, OpenAI(base, "synthetic-model", "synthetic-key"), [])
end

function install_delayed(id, directory, requests, started, release)
    E.install!(id, Synthetic(requests, started, release, "fixture-secret"), [DelayedWrite(directory, started, release)])
end

end
