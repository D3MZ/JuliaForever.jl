using Test, JuliaForever, JSON3

struct NamedReader <: JuliaForever.Tool
    label::String
end
JuliaForever.name(tool::NamedReader) = tool.label

struct VisibilityProvider end
JuliaForever.complete(::VisibilityProvider, messages, tools; kwargs...) = Dict{String, Any}("role" => "assistant", "content" => "answer")

@testset "Pi skill visibility by selected readers" begin
    source = ENV["PI_SOURCE"]
    @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
    mktempdir() do root
        cwd, home, agentdir = joinpath.((root,), ("project", "home", "agent"))
        mkpath.((cwd, home, agentdir))
        cwd = realpath(cwd)
        path = joinpath(cwd, ".pi", "skills", "example", "SKILL.md")
        mkpath(dirname(path))
        write(path, "---\nname: example\ndescription: useful skill\n---\nprivate instructions\n")
        input = joinpath(root, "input.json")
        write(input, JSON3.write((; cwd, agentDir=agentdir)))
        cmd = addenv(`node $(joinpath(@__DIR__, "skill_visibility_reference.mjs")) $source $input`, "HOME" => home, "PI_CODING_AGENT_DIR" => agentdir)
        pi = JSON3.read(read(cmd, String))
        @test !pi[7].resumedWithoutReader
        cd(cwd) do
            withenv("HOME" => home, "PI_CODING_AGENT_DIR" => agentdir, "JF_INSTRUCTIONS_DIR" => nothing) do
                skills = JuliaForever.Skills.load(cwd)
                choices = [[Read(cwd), Bash(cwd), Edit(cwd), Write(cwd)], JuliaForever.Tool[], [Write(cwd)], [Bash(cwd)], [Read(cwd)], [Read(cwd), Bash(cwd)]]
                @test JuliaForever.Skills.render(skills, JuliaForever.Skills.reader([NamedReader("read")])) == pi[5].initial.section
                @test JuliaForever.Skills.render(skills, JuliaForever.Skills.reader([NamedReader("bash")])) == pi[4].initial.section
                indirect = JuliaForever.Skills.render(skills, JuliaForever.Skills.reader([CodeMode([Read(cwd)])]))
                @test indirect == pi[8].hidden
                @test JuliaForever.Skills.reader([CodeMode([Write(cwd)])]) isa JuliaForever.Skills.NoReader
                @test JuliaForever.Skills.render(skills, JuliaForever.Skills.reader([Bash(cwd), CodeMode([Read(cwd)])])) == pi[4].initial.section
                @test JuliaForever.Skills.render(skills, JuliaForever.Skills.reader([CodeMode([Bash(cwd)]), Read(cwd)])) == pi[5].initial.section
                history = JuliaForever.History.Tree(JuliaForever.History.Memory())
                original = Agent(VisibilityProvider(), [Read(cwd)], JuliaForever.initial(Agent(VisibilityProvider(), [Read(cwd)]), nothing); history)
                @test respond!(original, "prior") == "answer"
                resumed = Agent(VisibilityProvider(), JuliaForever.Tool[]; history)
                terminal = JuliaForever.Terminal(IOBuffer(), IOBuffer(), String[])
                JuliaForever.command!(JuliaForever.terminalcommand("/reload"), terminal, resumed, history, IOBuffer(), "", nothing)
                @test all(!occursin("<available_skills>", get(message, "content", "")) for message in resumed.messages if message["role"] == "system")
                @test JuliaForever.Skills.expand("/skill:example hello", skills) == pi[2].initial.expanded
                for (tools, reference) in zip((JuliaForever.Tool[], [Bash(cwd)], [Read(cwd)], [Read(cwd), Bash(cwd)]), pi[9].changes)
                    resumed = Agent(VisibilityProvider(), tools; history)
                    @test JuliaForever.refreshskills!(resumed, skills) === nothing
                    sections = [m["content"] for m in resumed.messages if m["role"] == "system" && startswith(m["content"], "<skills>\n")]
                    @test sections == (isnothing(reference.section) ? [] : [reference.section])
                    @test JuliaForever.Skills.expand("/skill:example hello", skills) == reference.expanded
                end
                resumed = Agent(VisibilityProvider(), [CodeMode([Read(cwd)])]; history)
                @test JuliaForever.refreshskills!(resumed, skills) === nothing
                @test any(m -> m["role"] == "system" && m["content"] == pi[8].hidden, resumed.messages)
                @test JuliaForever.Skills.expand("/skill:example hello", skills) == pi[9].changes[1].expanded
                close(history)
                for (tools, reference) in zip(choices, pi)
                    seed = Agent(VisibilityProvider(), tools)
                    agent = Agent(VisibilityProvider(), tools, JuliaForever.initial(seed, nothing))
                    section() = something(findfirst(m -> m["role"] == "system" && startswith(m["content"], "<skills>\n"), agent.messages), 0) |> i -> iszero(i) ? nothing : agent.messages[i]["content"]
                    @test section() == reference.initial.section
                    @test JuliaForever.Skills.expand("/skill:example hello", skills) == reference.initial.expanded
                    terminal = JuliaForever.Terminal(IOBuffer(), IOBuffer(), String[])
                    JuliaForever.command!(JuliaForever.terminalcommand("/reload"), terminal, agent, nothing, IOBuffer(), "", nothing)
                    @test section() == reference.reloaded.section == reference.resumed.section
                end
            end
        end
    end
end
