module ContextImageCases

using Test, JuliaForever, HTTP, JSON3, Base64, Distributed
const J = JuliaForever
const C = J.Conversation
const E = J.Extensions
const X = J.Execution
const M = J.MCP

function response(index)
    calls = [Dict("id" => id, "type" => "function", "function" => Dict("name" => name, "arguments" => "{}")) for (id, name) in (("gif-call", "mcp_gif"), ("webp-call", "mcp_webp"), ("ghost-call", "ghost"))]
    message = index == 1 ? Dict("role" => "assistant", "content" => nothing, "tool_calls" => calls) : Dict("role" => "assistant", "content" => index == 2 ? "first" : index == 3 ? "followed-once" : index == 4 ? "followed" : "replayed")
    Dict("choices" => [Dict("message" => message, "finish_reason" => index == 1 ? "tool_calls" : "stop")])
end

end
