using JuliaForever, JSON3

function JuliaForever.stream(provider::OpenAI, messages, tools; parameters=Dict(), on_event=identity)
    open(ENV["JF_RELOAD_REQUESTS"], "a") do io
        println(io, JSON3.write(messages))
    end
    text = "reply:" * messages[end]["content"]
    on_event((; type=:text, text))
    if messages[end]["content"] == "first"
        while !isfile(ENV["JF_RELOAD_GATE"])
            sleep(0.02)
        end
    end
    Completion(Dict{String, Any}("role" => "assistant", "content" => text), nothing, "stop", true, nothing)
end

exit(JuliaForever.main(ARGS))
