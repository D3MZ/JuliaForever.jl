applied!(tools, event) = nothing
applied!(tools::ToolSet, event::Kernel.Observe{Conversation.ToolReply}) = applied!(tools, event.observation.result)
applied!(tools::ToolSet, result::ToolResult) = nothing
applied!(tools::ToolSet, result::ToolLoaded) = expose!(tools, result.loaded)
