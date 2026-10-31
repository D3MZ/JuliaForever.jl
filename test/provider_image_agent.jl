module ImageAgentBoundaryTests

using Test, JuliaForever, HTTP, JSON3, Distributed, Base64
const E = JuliaForever.Execution
const H = JuliaForever.History

function response(anthropic, first, streaming)
    block = first ? Dict("type" => "tool_use", "id" => "call-1", "name" => "read", "input" => Dict("path" => "pixel.png")) : Dict("type" => "text", "text" => "done")
    reason = first ? "tool_use" : "end_turn"
    if anthropic
        if streaming
            events = [Dict("type" => "message_start", "message" => Dict("usage" => Dict("input_tokens" => 1, "output_tokens" => 0))), Dict("type" => "content_block_start", "index" => 0, "content_block" => block), Dict("type" => "content_block_stop", "index" => 0), Dict("type" => "message_delta", "delta" => Dict("stop_reason" => reason), "usage" => Dict("output_tokens" => 1)), Dict("type" => "message_stop")]
            body = join("event: $(event["type"])\ndata: $(JSON3.write(event))\n\n" for event in events)
            return HTTP.Response(200, ["Content-Type" => "text/event-stream"], body)
        end
        data = Dict("content" => [block], "stop_reason" => reason, "usage" => Dict("input_tokens" => 1, "output_tokens" => 1))
    else
        part = first ? Dict("functionCall" => Dict("id" => "call-1", "name" => "read", "args" => Dict("path" => "pixel.png"))) : Dict("text" => "done")
        data = Dict("candidates" => [Dict("content" => Dict("role" => "model", "parts" => [part]), "finishReason" => "STOP")])
        streaming && return HTTP.Response(200, ["Content-Type" => "text/event-stream"], "data: $(JSON3.write(data))\n\n")
    end
    HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write(data))
end

imagebytes(body, ::Anthropic) = body.messages[3].content[1].content[2].source.data
imagebytes(body, ::Google) = body.contents[3].parts[1].functionResponse.parts[1].inlineData.data

end
