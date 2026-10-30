module SkillResumeTerminalTests

using Test, JuliaForever

struct Provider
    requests::Vector{Any}
end
JuliaForever.complete(::Provider, messages, tools; kwargs...) = Dict{String, Any}("role" => "assistant", "content" => "answer")
function JuliaForever.stream(provider::Provider, messages, tools; kwargs...)
    push!(provider.requests, deepcopy(messages))
    Completion(Dict{String, Any}("role" => "assistant", "content" => "answer"), nothing, "stop", true, nothing)
end

function skill(root, name)
    path = joinpath(root, ".pi", "skills", name, "SKILL.md")
    mkpath(dirname(path))
    write(path, "---\nname: $name\ndescription: $name metadata\n---\nprivate $name instructions\n")
    path
end

@testset "terminal resume refreshes skill commands" begin
    mktempdir() do root
        cd(root) do
            withenv("HOME" => root, "PI_CODING_AGENT_DIR" => joinpath(root, "agent"), "JF_INSTRUCTIONS_DIR" => nothing) do
                old = skill(root, "old")
                resources = JuliaForever.Skills.Resources(Dict{String, String}(), JuliaForever.Skills.load(root))
                sessions = joinpath(root, "sessions")
                target = JuliaForever.SessionCatalog.new(sessions, pwd())
                @test respond!(Agent(Provider(Any[]), []; history=target), "saved") == "answer"
                close(target)
                provider = Provider(Any[])
                active = Agent(provider, [Read(root)])
                terminal = JuliaForever.Terminal(IOBuffer(), IOBuffer(), String[])
                extensions = JuliaForever.Extensions.snapshot(JuliaForever.Extensions.Registry())
                rm(dirname(old); recursive=true)
                skill(root, "new")
                resumed, history, status = JuliaForever.readcommand!(terminal, active, extensions, nothing, "/resume", IOBuffer("1\n"), sessions, resources, JuliaForever.terminalcommand("/resume"))
                @test status == 0 && [item.name for item in resources.skills] == ["new"]
                @test any(m -> occursin("new metadata", get(m, "content", "")), resumed.messages)
                _, _, status = JuliaForever.readcommand!(terminal, resumed, extensions, history, "/skill:new hello", IOBuffer(), sessions, resources, nothing)
                @test status == 0 && length(provider.requests) == 1
                @test occursin("private new instructions", string(provider.requests[1][end]))
                close(history)
            end
        end
    end
end

end
