struct OpenAI
    base::String
    model::String
    key::String
end

mutable struct Agent{P}
    provider::P
    tools::Dict{String, Tool}
    messages::Vector{Dict{String, Any}}
end

Agent(provider, tools) = Agent(provider, Dict{String, Tool}(name(tool) => tool for tool in tools), Dict{String, Any}[])

name(::Read) = "read"
name(::Write) = "write"
name(::Edit) = "edit"

schema(::Read) = Dict("type" => "object", "properties" => Dict("path" => Dict("type" => "string"), "offset" => Dict("type" => "integer"), "limit" => Dict("type" => "integer")), "required" => ["path"])
schema(::Write) = Dict("type" => "object", "properties" => Dict("path" => Dict("type" => "string"), "content" => Dict("type" => "string")), "required" => ["path", "content"])
schema(::Edit) = Dict("type" => "object", "properties" => Dict("path" => Dict("type" => "string"), "edits" => Dict("type" => "array", "items" => Dict("type" => "object", "properties" => Dict("oldText" => Dict("type" => "string"), "newText" => Dict("type" => "string")), "required" => ["oldText", "newText"]))), "required" => ["path", "edits"])

description(::Read) = "Read a text file. Offset and limit are line based."
description(::Write) = "Create or overwrite a text file."
description(::Edit) = "Replace unique, non-overlapping text in a file."

definition(tool) = Dict("type" => "function", "function" => Dict("name" => name(tool), "description" => description(tool), "parameters" => schema(tool)))

function complete(provider::OpenAI, messages, tools)
    body = JSON3.write((; model=provider.model, messages, tools=definition.(collect(values(tools)))))
    headers = ["Authorization" => "Bearer $(provider.key)", "Content-Type" => "application/json"]
    response = HTTP.post("$(rstrip(provider.base, '/'))/chat/completions", headers, body)
    JSON3.read(String(response.body), Dict{String, Any})["choices"][1]["message"]
end

function invoke(agent, call)
    try
        tool = call["function"]
        execute(agent.tools[tool["name"]], JSON3.read(tool["arguments"]))
    catch exception
        ToolResult(sprint(showerror, exception), true)
    end
end

function respond!(agent::Agent, prompt)
    push!(agent.messages, Dict("role" => "user", "content" => prompt))
    while true
        message = complete(agent.provider, agent.messages, agent.tools)
        push!(agent.messages, message)
        calls = get(message, "tool_calls", [])
        isempty(calls) && return message["content"]
        for call in calls
            result = invoke(agent, call)
            content = result.iserror ? "Error: $(result.text)" : result.text
            push!(agent.messages, Dict("role" => "tool", "tool_call_id" => call["id"], "content" => content))
        end
    end
end
