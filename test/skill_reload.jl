using Test, JuliaForever

struct SkillReloadProvider end
JuliaForever.complete(::SkillReloadProvider, messages, tools; kwargs...) = Dict{String, Any}("role" => "assistant", "content" => "answer")

function reloadskill(path, description)
    mkpath(dirname(path))
    write(path, "---\nname: example\ndescription: $description\n---\nprivate content\n")
end

@testset "skill reload safety and recorded context" begin
    mktempdir() do root
        cwd = joinpath(root, "project")
        mkpath(cwd)
        path = joinpath(cwd, ".pi", "skills", "example", "SKILL.md")
        reloadskill(path, "old metadata")
        cd(cwd) do
            withenv("HOME" => root, "PI_CODING_AGENT_DIR" => joinpath(root, "agent"), "JF_INSTRUCTIONS_DIR" => nothing) do
                history = JuliaForever.History.Tree(JuliaForever.History.Memory())
                terminal = JuliaForever.Terminal(IOBuffer(), IOBuffer(), ["synthetic-secret"])
                seed = Agent(SkillReloadProvider(), [Read(cwd)])
                messages = JuliaForever.initial(seed, nothing)
                unrelated = Dict{String, Any}("role" => "system", "content" => "unrelated system instruction")
                push!(messages, JuliaForever.Conversation.RawMessage(unrelated))
                agent = Agent(SkillReloadProvider(), seed.tools, messages; history)
                @test respond!(agent, "prior") == "answer"
                before = deepcopy(agent.messages)
                batches = JuliaForever.History.snapshot(history).batches
                revision = agent.state.revision
                same, selected, status = JuliaForever.reload!(terminal, agent, history, () -> read(joinpath(root, "synthetic-secret", "missing"), String))
                @test status == 1 && same === agent && selected === history
                @test agent.messages == before && agent.state.revision == revision
                @test JuliaForever.History.snapshot(history).batches == batches
                diagnostic = String(take!(terminal.diagnostics))
                @test occursin("Skill reload failed", diagnostic) && occursin("[redacted]", diagnostic) && !occursin("synthetic-secret", diagnostic)
                @test !agent.running

                JuliaForever.startturn!(agent)
                loaded = Ref(false)
                same, selected, status = JuliaForever.reload!(terminal, agent, history, () -> (loaded[] = true; nothing))
                @test status == 0 && same === agent && selected === history && !loaded[]
                @test agent.running && !agent.cancelled && agent.messages == before
                @test occursin("Wait for the current response", String(take!(terminal.diagnostics)))
                JuliaForever.finish!(agent)

                same, selected, status = JuliaForever.reload!(terminal, agent, history, () -> (steer!(agent, "queued during reload"); "replacement"))
                @test status == 1 && same === agent && selected === history
                @test agent.messages == before && agent.state.steering == ["queued during reload"]
                @test !agent.running
                @test dequeue!(agent).steering == ["queued during reload"]
                take!(terminal.diagnostics)

                push!(agent.messages, Dict("role" => "system", "content" => "additional system instruction"))
                insert!(agent.messages, 1, Dict("role" => "system", "content" => "inserted system instruction"))
                @test JuliaForever.sync!(agent) === nothing
                reloadskill(path, "new metadata")
                _, _, status = JuliaForever.command!(JuliaForever.terminalcommand("/reload"), terminal, agent, history, IOBuffer(), "", nothing)
                @test status == 0
                system = [message["content"] for message in agent.messages if message["role"] == "system"]
                @test count(text -> occursin("new metadata", text), system) == 1
                @test all(!occursin("old metadata", text) for text in system)
                @test "unrelated system instruction" in system && "additional system instruction" in system && "inserted system instruction" in system
                @test JuliaForever.ContextEstimates.estimate(agent.state.messages).total > 0
                @test respond!(agent, "next") == "answer"
                @test compact!(agent, _ -> "checkpoint") == "checkpoint"
                @test any(message -> message["role"] == "system" && occursin("new metadata", message["content"]), agent.messages)
                @test Agent(SkillReloadProvider(), []; history).messages == agent.messages
                close(history)
            end
        end
    end
end

@testset "stale history rejects skill reload" begin
    history = JuliaForever.History.Memory()
    terminal = JuliaForever.Terminal(IOBuffer(), IOBuffer(), String[])
    agent = Agent(SkillReloadProvider(), []; history)
    other = Agent(SkillReloadProvider(), []; history)
    before = deepcopy(agent.messages)
    @test name!(other, "other writer") === nothing
    _, _, status = JuliaForever.reload!(terminal, agent, history, () -> "new skills")
    @test status == 1 && agent.messages == before
    @test agent.fault == JuliaForever.History.Rejected(:revision)
    @test Agent(SkillReloadProvider(), []; history).messages == before

    history = JuliaForever.History.Memory()
    agent = Agent(SkillReloadProvider(), []; history)
    other = Agent(SkillReloadProvider(), []; history)
    _, _, status = JuliaForever.reload!(terminal, agent, history, () -> (name!(other, "racing writer"); name!(agent, "conflict"); nothing))
    @test status == 1 && agent.fault == JuliaForever.History.Rejected(:revision)
    @test isempty(agent.messages) && !agent.running
end

mutable struct FailingReloadHistory <: JuliaForever.History.Store
    memory::JuliaForever.History.Memory
    fail::Bool
end
JuliaForever.History.snapshot(store::FailingReloadHistory) = JuliaForever.History.snapshot(store.memory)
function JuliaForever.History.append!(store::FailingReloadHistory, revision::Integer, batch::Vector)
    store.fail && throw(SystemError("synthetic-secret", Int32(5)))
    JuliaForever.History.append!(store.memory, revision, batch)
end

@testset "reload reports history I/O failure without replacing context" begin
    history = FailingReloadHistory(JuliaForever.History.Memory(), false)
    agent = Agent(SkillReloadProvider(), []; history)
    terminal = JuliaForever.Terminal(IOBuffer(), IOBuffer(), ["synthetic-secret"])
    before = deepcopy(agent.messages)
    history.fail = true
    _, _, status = JuliaForever.reload!(terminal, agent, history, () -> "new skills")
    @test status == 1 && agent.messages == before && !agent.running
    @test agent.fault == JuliaForever.History.Rejected(:uncertain)
    diagnostic = String(take!(terminal.diagnostics))
    @test occursin("Skill reload failed", diagnostic) && occursin("[redacted]", diagnostic) && !occursin("synthetic-secret", diagnostic)
end

@testset "reload replaces recorded CLI skill context" begin
    mktempdir() do root
        path = joinpath(root, ".pi", "skills", "example", "SKILL.md")
        reloadskill(path, "original metadata")
        cd(root) do
            withenv("HOME" => root, "PI_CODING_AGENT_DIR" => joinpath(root, "agent"), "JF_INSTRUCTIONS_DIR" => nothing) do
                history = JuliaForever.History.Memory()
                terminal = JuliaForever.Terminal(IOBuffer(), IOBuffer(), String[])
                seed = Agent(SkillReloadProvider(), [Read(root)])
                initial = JuliaForever.initial(seed, nothing)
                raw = Dict{String, Any}[convert(Dict{String, Any}, item) for item in initial]
                agent = Agent(SkillReloadProvider(), seed.tools, raw; history)
                @test respond!(agent, "prior") == "answer"
                original = deepcopy(agent.messages)
                reloadskill(path, "replacement metadata")
                _, _, status = JuliaForever.command!(JuliaForever.terminalcommand("/reload"), terminal, agent, history, IOBuffer(), "", nothing)
                @test status == 0
                system = [item["content"] for item in agent.messages if item["role"] == "system"]
                @test count(text -> occursin("replacement metadata", text), system) == 1
                @test all(!occursin("original metadata", text) for text in system)
                @test agent.messages[3:end] == original[3:end]
                @test Agent(SkillReloadProvider(), []; history).messages == agent.messages
            end
        end
    end
end

@testset "reload adds the first skill and removes the last" begin
    mktempdir() do root
        cd(root) do
            withenv("HOME" => root, "PI_CODING_AGENT_DIR" => joinpath(root, "agent"), "JF_INSTRUCTIONS_DIR" => nothing) do
                history = JuliaForever.SessionCatalog.new(joinpath(root, "sessions"), root)
                terminal = JuliaForever.Terminal(IOBuffer(), IOBuffer(), String[])
                seed = Agent(SkillReloadProvider(), [Read(root)])
                agent = Agent(SkillReloadProvider(), seed.tools, JuliaForever.initial(seed, nothing); history)
                file = JuliaForever.SessionCatalog.path(history)
                initial = deepcopy(agent.messages)
                initialrevision = history.leaf
                _, _, status = JuliaForever.command!(JuliaForever.terminalcommand("/reload"), terminal, agent, history, IOBuffer(), "", nothing)
                @test status == 0 && history.leaf == initialrevision && !isfile(file)
                path = joinpath(root, ".pi", "skills", "example", "SKILL.md")
                reloadskill(path, "newly available")
                _, _, status = JuliaForever.command!(JuliaForever.terminalcommand("/reload"), terminal, agent, history, IOBuffer(), "", nothing)
                @test status == 0 && isfile(file)
                @test any(message -> occursin("newly available", message["content"]), agent.messages)
                rm(dirname(path); recursive=true)
                _, _, status = JuliaForever.command!(JuliaForever.terminalcommand("/reload"), terminal, agent, history, IOBuffer(), "", nothing)
                @test status == 0 && agent.messages == initial
                @test Agent(SkillReloadProvider(), []; history).messages == initial
                close(history)
            end
        end
    end
end
