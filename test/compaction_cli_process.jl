using JuliaForever, JSON3

function record(operation, messages)
    open(ENV["JF_COMPACTION_REQUESTS"], "a") do io
        println(io, JSON3.write((; operation, messages)))
    end
end

function JuliaForever.complete(provider::OpenAI, messages, tools; parameters=Dict())
    record("summarize", messages)
    mode = get(ENV, "JF_COMPACTION_USAGE", "")
    usage = mode in ("success", "failure") ? Usage(40, 8, 5, 0, 0, 53, 0.002) : nothing
    Completion(Dict{String, Any}("role" => "assistant", "content" => "checkpoint"), usage, mode == "failure" ? "length" : "stop", true, nothing)
end

function JuliaForever.stream(provider::OpenAI, messages, tools; parameters=Dict(), on_event=identity)
    record("respond", messages)
    text = "reply:" * messages[end]["content"]
    on_event((; type=:text, text))
    usage = isempty(get(ENV, "JF_COMPACTION_USAGE", "")) ? nothing : Usage(100, 10, 20, 0, 0, 130, 0.01)
    Completion(Dict{String, Any}("role" => "assistant", "content" => text), usage, "stop", true, nothing)
end

exit(JuliaForever.main(ARGS))
