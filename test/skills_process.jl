using JuliaForever, JSON3

function JuliaForever.stream(provider::OpenAI, messages, tools; parameters=Dict(), on_event=identity)
    open(ENV["JF_CAPTURE"], "a") do io
        println(io, JSON3.write(messages))
    end
    if messages[end]["role"] == "user"
        call = Dict("id" => "read-skill", "type" => "function", "function" => Dict("name" => "read", "arguments" => JSON3.write((; path=ENV["JF_SKILL"]))))
        message = Dict{String, Any}("role" => "assistant", "content" => nothing, "tool_calls" => [call])
        return Completion(message, nothing, "tool_calls", true, nothing)
    end
    Completion(Dict{String, Any}("role" => "assistant", "content" => "loaded"), nothing, "stop", true, nothing)
end

exit(JuliaForever.main(ARGS))
