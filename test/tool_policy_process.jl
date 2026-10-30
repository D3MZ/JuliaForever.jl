using JuliaForever, JSON3

current = Ref(0)
const testcases = [
    (; args=["--no-tools"], kind="write", target="direct-denied.txt"),
    (; args=["--tools", "write"], kind="write", target="direct-allowed.txt"),
    (; args=["--codemode", "--tools", "codemode,read"], kind="codemode", target="nested-denied.txt"),
    (; args=["--codemode", "--tools", "codemode,write"], kind="codemode", target="nested-allowed.txt"),
    (; args=String[], kind="write", target="saved-allowed.txt"),
    (; args=["--continue", "--tools", "read"], kind="write", target="resumed-denied.txt"),
    (; args=["--codemode", "--no-tools"], kind="codemode", target="mode-denied.txt"),
]

function JuliaForever.stream(provider::OpenAI, messages, tools; parameters=Dict(), on_event=identity)
    scenario = testcases[current[]]
    if messages[end]["role"] == "user"
        arguments = scenario.kind == "write" ? (; path=scenario.target, content="written") : (; code="text(tools.write((; path=$(repr(scenario.target)), content=\"written\")).text)")
        call = Dict("id" => "one", "type" => "function", "function" => Dict("name" => scenario.kind, "arguments" => JSON3.write(arguments)))
        return Completion(Dict{String, Any}("role" => "assistant", "content" => nothing, "tool_calls" => [call]), nothing, "tool_calls", true, nothing)
    end
    open(ENV["JF_POLICY_LOG"], "a") do io
        println(io, JSON3.write((; case=current[], result=last(messages))))
    end
    on_event((; type=:text, text="done"))
    Completion(Dict{String, Any}("role" => "assistant", "content" => "done"), nothing, "stop", true, nothing)
end

for (index, scenario) in enumerate(testcases)
    current[] = index
    session = index in (5, 6) ? ["--session-dir", ENV["JF_POLICY_SESSIONS"]] : ["--no-session"]
    status = JuliaForever.main([session..., scenario.args..., "probe"])
    open(ENV["JF_POLICY_STATUSES"], "a") do io
        println(io, JSON3.write((; case=index, status)))
    end
end
