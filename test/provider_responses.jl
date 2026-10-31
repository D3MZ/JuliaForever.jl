using HTTP, JSON3

response_sse(data) = "data: $(JSON3.write(data))\n\n"
response_call(id, call, path, content) = Dict("type" => "function_call", "id" => id, "call_id" => call, "name" => "write", "arguments" => JSON3.write((; path, content)), "status" => "completed")
response_text(text) = Dict("type" => "message", "id" => "msg_1", "status" => "completed", "role" => "assistant", "content" => [Dict("type" => "output_text", "text" => text, "annotations" => [])])

response_reasoning() = Dict("type" => "reasoning", "id" => "rs_1", "summary" => [], "encrypted_content" => "synthetic-encrypted")
response_done(output; status="completed", usage=nothing) = Dict("id" => "resp_1", "status" => status, "output" => output, "usage" => usage)
