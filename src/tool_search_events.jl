applied!(tools, event) = nothing
applied!(tools::ToolSet, event::Kernel.Observe{Conversation.ToolReply}) = applied!(tools, event.observation.result)
applied!(tools, previous, event, current) = applied!(tools, event)
applied!(tools::ToolSet, previous, event::Union{Kernel.Observe{Conversation.ToolReply}, Conversation.Abandon}, current) = appliedflushed!(tools, previous, current)

function appliedflushed!(tools, previous, current)
    order = getfield(previous, :order)
    first = previous.flushed + 1
    count = length(getfield(current, :messages)) - length(getfield(previous, :messages))
    observations = getfield(current.kernel, :observations)
    for id in order[first:first+count-1]
        observation = only(item.observation for item in observations if item.id == id)
        applied!(tools, observation)
    end
    nothing
end

applied!(tools::ToolSet, observation::Conversation.ToolReply) = applied!(tools, observation.result)
applied!(tools::ToolSet, result::ToolResult) = nothing
applied!(tools::ToolSet, result::ToolLoaded) = expose!(tools, result.loaded)
applied!(tools::ToolSet, result::ToolDiscovery) = expose!(tools, result.loaded)
