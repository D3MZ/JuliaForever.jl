using Test, JuliaForever, JSON3

struct ReloadProvider end
JuliaForever.complete(::ReloadProvider, messages, tools; kwargs...) = Dict{String, Any}("role" => "assistant", "content" => "prior answer")
JuliaForever.stream(::ReloadProvider, messages, tools; kwargs...) = Completion(Dict{String, Any}("role" => "assistant", "content" => "prior answer"), nothing, "stop", true, nothing)

function reloadfixture(cwd)
    skills = joinpath(cwd, ".pi", "skills")
    for (name, description) in (("changed", "original metadata"), ("removed", "removed metadata"))
        mkpath(joinpath(skills, name))
        write(joinpath(skills, name, "SKILL.md"), "---\nname: $name\ndescription: $description\n---\nprivate body\n")
    end
end

function reloadchange(cwd)
    skills = joinpath(cwd, ".pi", "skills")
    write(joinpath(skills, "changed", "SKILL.md"), "---\nname: changed\ndescription: updated metadata\n---\nnew private body\n")
    rm(joinpath(skills, "removed"); recursive=true)
    mkpath(joinpath(skills, "added"))
    write(joinpath(skills, "added", "SKILL.md"), "---\nname: added\ndescription: added metadata\n---\nprivate body\n")
end

function skillsection(agent)
    sections = [message["content"] for message in agent.messages if message["role"] == "system" && startswith(message["content"], "<skills>\n")]
    isempty(sections) ? nothing : only(sections)
end

function reloadcommand(terminal, agent, history)
    command = JuliaForever.terminalcommand("/reload")
    JuliaForever.readcommand!(terminal, agent, nothing, history, "/reload", IOBuffer(), "", Dict{String, String}(), command)
end

@testset "Pi in-session skill reload" begin
    source = ENV["PI_SOURCE"]
    @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
    mktempdir() do root
        cwd, home, agentdir = joinpath.((root,), ("project", "home", "agent"))
        mkpath.((cwd, home, agentdir))
        cwd = realpath(cwd)
        reloadfixture(cwd)
        input = joinpath(root, "input.json")
        write(input, JSON3.write((; cwd, agentDir=agentdir)))
        cmd = addenv(`node $(joinpath(@__DIR__, "skill_reload_pi.mjs")) $source $input`, "HOME" => home, "PI_CODING_AGENT_DIR" => agentdir)
        pi = JSON3.read(read(cmd, String))
        @test all(view.inPrompt for view in pi)
        @test [collect(view.conversation) for view in pi] == fill(["prior request", "prior answer"], 3)
        @test [collect(view.history) for view in pi] == fill(["user", "assistant"], 3)
        @test pi[1].section !== nothing && pi[2].section !== nothing && pi[3].section === nothing
        @test occursin("updated metadata", pi[2].section) && !occursin("removed metadata", pi[2].section)
        reloadfixture(cwd)
        cd(cwd) do
            withenv("HOME" => home, "PI_CODING_AGENT_DIR" => agentdir, "JF_INSTRUCTIONS_DIR" => nothing) do
                history = JuliaForever.History.Tree(JuliaForever.History.Memory())
                terminal = JuliaForever.Terminal(IOBuffer(), IOBuffer(), String[])
                seed = Agent(ReloadProvider(), [Read(cwd)])
                agent = Agent(ReloadProvider(), seed.tools, JuliaForever.initial(seed, nothing); history)
                @test respond!(agent, "prior request") == "prior answer"
                prior = deepcopy(agent.messages)
                oldleaf = history.leaf
                oldbatches = JuliaForever.History.snapshot(history).batches
                @test skillsection(agent) == pi[1].section
                reloadchange(cwd)
                same, selected, status = reloadcommand(terminal, agent, history)
                @test status == 0 && same === agent && selected === history
                @test skillsection(agent) == pi[2].section
                @test filter(m -> m["role"] != "system", agent.messages) == filter(m -> m["role"] != "system", prior)
                @test first(agent.messages) == first(prior)
                @test JuliaForever.History.snapshot(history).batches[1:length(oldbatches)] == oldbatches
                @test Agent(ReloadProvider(), []; history).messages == agent.messages
                newleaf = history.leaf
                @test JuliaForever.History.branch!(history, oldleaf) == oldleaf
                @test skillsection(Agent(ReloadProvider(), []; history)) == pi[1].section
                @test JuliaForever.History.branch!(history, newleaf) == newleaf
                rm(joinpath(cwd, ".pi", "skills"); recursive=true)
                same, selected, status = reloadcommand(terminal, agent, history)
                @test status == 0 && same === agent && selected === history
                @test skillsection(agent) === pi[3].section
                @test Agent(ReloadProvider(), []; history).messages == agent.messages
                @test filter(m -> m["role"] != "system", agent.messages) == filter(m -> m["role"] != "system", prior)
                close(history)
            end
        end
    end
end
