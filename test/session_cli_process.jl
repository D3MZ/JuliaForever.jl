using JuliaForever, JSON3

function JuliaForever.stream(provider::OpenAI, messages, tools; parameters=Dict(), on_event=identity)
    open(ENV["JF_SESSION_REQUESTS"], "a") do file
        println(file, JSON3.write(messages))
    end
    get(ENV, "JF_SESSION_FAIL", "") == "1" && exit(17)
    text = "reply:" * messages[end]["content"]
    on_event((; type=:text, text))
    Completion(Dict{String, Any}("role" => "assistant", "content" => text), nothing, "stop", true, nothing)
end

exit(JuliaForever.main(ARGS))
