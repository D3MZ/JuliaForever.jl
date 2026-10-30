module SkillResumeUserTests

using Test, JuliaForever
const H = JuliaForever.History

struct Provider end
JuliaForever.complete(::Provider, messages, tools; kwargs...) = Dict{String, Any}("role" => "assistant", "content" => "answer")

@testset "user-authored system sections survive reload and resume" begin
    mktempdir() do root
        cd(root) do
            withenv("HOME" => root, "PI_CODING_AGENT_DIR" => joinpath(root, "agent"), "JF_INSTRUCTIONS_DIR" => nothing) do
                path = joinpath(root, ".pi", "skills", "example", "SKILL.md")
                mkpath(dirname(path))
                write(path, "---\nname: example\ndescription: test\n---\nbody\n")
                content = JuliaForever.Skills.render(JuliaForever.Skills.load(pwd()), JuliaForever.Skills.reader([Read(root)]))
                user = Dict{String, Any}("role" => "system", "content" => content)
                initial = JuliaForever.Conversation.Message[JuliaForever.Conversation.RawMessage(Dict("role" => "system", "content" => "project")), JuliaForever.Conversation.RawMessage(user)]
                history = H.Tree(H.Memory())
                agent = Agent(Provider(), [Read(root)], initial; history)
                @test user in agent.messages
                terminal = JuliaForever.Terminal(IOBuffer(), IOBuffer(), String[])
                _, _, status = JuliaForever.command!(JuliaForever.terminalcommand("/reload"), terminal, agent, history, IOBuffer(), "", nothing)
                @test status == 0 && count(==(user), agent.messages) == 2
                write(path, "---\nname: example\ndescription: changed\n---\nbody\n")
                _, _, status = JuliaForever.command!(JuliaForever.terminalcommand("/reload"), terminal, agent, history, IOBuffer(), "", nothing)
                @test status == 0 && count(==(user), agent.messages) == 1
                @test any(m -> occursin("<description>changed</description>", get(m, "content", "")), agent.messages)
                before = deepcopy(H.snapshot(history).batches)
                _, _, status = JuliaForever.command!(JuliaForever.terminalcommand("/reload"), terminal, agent, history, IOBuffer(), "", nothing)
                @test status == 0 && H.snapshot(history).batches == before
                @test user in Agent(Provider(), [Read(root)]; history).messages
                close(history)

                target = H.Tree(H.Memory())
                Agent(Provider(), [], initial; history=target)
                active = Agent(Provider(), [Read(root)])
                resumed, selected, status = JuliaForever.resume!(terminal, active, nothing, target)
                @test status == 0 && user in resumed.messages
                @test user in Agent(Provider(), [Read(root)]; history=selected).messages
                close(selected)
            end
        end
    end
end

end
