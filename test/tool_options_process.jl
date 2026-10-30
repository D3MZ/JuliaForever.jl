using JuliaForever, JSON3

caseid = Ref(0)
function JuliaForever.stream(provider::OpenAI, messages, tools; parameters=Dict(), on_event=identity)
    open(ENV["JF_TOOL_OBSERVATIONS"], "a") do io
        println(io, JSON3.write((; case=caseid[], tools=sort!(collect(keys(tools))), system=first(messages)["content"])))
    end
    on_event((; type=:text, text="ok"))
    Completion(Dict{String, Any}("role" => "assistant", "content" => "ok"), nothing, "stop", true, nothing)
end

fixture = joinpath(@__DIR__, "fixtures")
cases = JSON3.read(read(ARGS[1], String), Vector{Vector{String}})
for (index, args) in enumerate(cases)
    caseid[] = index
    ENV["JF_TEST_EVENTS"] = ENV["JF_TOOL_EVENTS"] * string(index)
    status = JuliaForever.main(["--no-session", "--plugin-env", fixture, "--plugin", "GreetingPlugin", args..., "probe"])
    open(ENV["JF_TOOL_STATUSES"], "a") do io
        println(io, JSON3.write((; case=index, status)))
    end
end
