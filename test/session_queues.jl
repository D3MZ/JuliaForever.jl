using Test, JuliaForever
import JuliaForever.History as QueueHistory
import JuliaForever.Conversation as QueueConversation

struct QueueResumeProvider
    calls::Base.RefValue{Int}
end
struct QueueResumeTool <: JuliaForever.Tool
    calls::Base.RefValue{Int}
end
JuliaForever.name(::QueueResumeTool) = "queue_probe"
JuliaForever.description(::QueueResumeTool) = "Track synthetic tool dispatch."
JuliaForever.schema(::QueueResumeTool) = Dict("type" => "object", "properties" => Dict())
JuliaForever.execute(tool::QueueResumeTool, args) = (tool.calls[] += 1; ToolResult("ok"))
function JuliaForever.complete(provider::QueueResumeProvider, messages, tools; kwargs...)
    provider.calls[] += 1
    Dict{String, Any}("role" => "assistant", "content" => "ok")
end
function JuliaForever.stream(provider::QueueResumeProvider, messages, tools; kwargs...)
    provider.calls[] += 1
    Completion(Dict{String, Any}("role" => "assistant", "content" => "ok"), nothing, "stop", true, nothing)
end

function queuedagent(history, provider)
    agent = Agent(provider, []; history)
    steer!(agent, "steer synthetic-key")
    followup!(agent, "follow synthetic-key")
    JuliaForever.transition!(revision -> QueueConversation.Input(revision, "prior"), agent)
    JuliaForever.transition!(revision -> QueueConversation.Interrupt(revision, "incomplete"), agent)
    agent
end
