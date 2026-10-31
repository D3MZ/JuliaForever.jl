using HTTP, JSON3

plansse(value) = "data: $(JSON3.write(value))\n\n"
plantext(value) = Dict("type" => "message", "id" => "msg-1", "status" => "completed", "role" => "assistant", "content" => [Dict("type" => "output_text", "text" => value)])
planresponse(output) = Dict("status" => "completed", "output" => output)
plancall = Dict("type" => "function_call", "id" => "fc-1", "call_id" => "call-1", "name" => "write", "arguments" => "{\"path\":\"plan.txt\",\"content\":\"fixture\"}", "status" => "completed")
