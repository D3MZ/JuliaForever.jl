using Test, JuliaForever, HTTP, JSON3
import JuliaForever.History as H
import JuliaForever.Conversation as C

cancelchunks(::OpenAI) = [Dict("choices" => [Dict("delta" => Dict("content" => "partial"))])]
cancelchunks(::OpenAIResponses) = [Dict("type" => "response.output_text.delta", "output_index" => 0, "item_id" => "m", "content_index" => 0, "delta" => "partial")]
cancelchunks(::Anthropic) = [
    Dict("type" => "message_start", "message" => Dict("id" => "m", "role" => "assistant", "model" => "fixture", "content" => [], "usage" => Dict("input_tokens" => 1, "output_tokens" => 0))),
    Dict("type" => "content_block_start", "index" => 0, "content_block" => Dict("type" => "text", "text" => "")),
    Dict("type" => "content_block_delta", "index" => 0, "delta" => Dict("type" => "text_delta", "text" => "partial")),
]
cancelchunks(::Google) = [Dict("candidates" => [Dict("content" => Dict("role" => "model", "parts" => [Dict("text" => "partial")]))])]
canceljson(::OpenAI) = Dict("choices" => [Dict("message" => Dict("role" => "assistant", "content" => "done"), "finish_reason" => "stop")])
canceljson(::OpenAIResponses) = Dict("status" => "completed", "output" => [Dict("type" => "message", "role" => "assistant", "content" => [Dict("type" => "output_text", "text" => "done")])])
canceljson(::Anthropic) = Dict("content" => [Dict("type" => "text", "text" => "done")], "stop_reason" => "end_turn")
canceljson(::Google) = Dict("candidates" => [Dict("content" => Dict("role" => "model", "parts" => [Dict("text" => "done")]), "finishReason" => "STOP")])
