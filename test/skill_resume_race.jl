module SkillResumeRaceTests

using Test, JuliaForever
const H = JuliaForever.History

struct Provider end
JuliaForever.complete(::Provider, messages, tools; kwargs...) = Dict{String, Any}("role" => "assistant", "content" => "ok")

mutable struct Store <: H.Store
    memory::H.Memory
    hook::Function
    closes::Int
end
H.snapshot(store::Store) = (store.hook(); H.snapshot(store.memory))
Base.append!(store::Store, revision::Integer, batch::Vector) = append!(store.memory, revision, batch)
Base.close(store::Store) = (store.closes += 1; nothing)

@testset "resume leaves target unchanged when source becomes unavailable" begin
    mktempdir() do root
        cd(root) do
            withenv("HOME" => root, "PI_CODING_AGENT_DIR" => joinpath(root, "agent"), "JF_INSTRUCTIONS_DIR" => nothing) do
                path = joinpath(root, ".pi", "skills", "example", "SKILL.md")
                mkpath(dirname(path))
                write(path, "---\nname: example\ndescription: test skill\n---\nprivate instructions\n")
                for kind in (:queue, :fault)
                    store = Store(H.Memory(), () -> nothing, 0)
                    target = H.Tree(store)
                    seed = Agent(Provider(), []; history=target)
                    @test respond!(seed, "saved") == "ok"
                    before = deepcopy(H.snapshot(store.memory).batches)
                    active = Agent(Provider(), [Read(root)])
                    resources = JuliaForever.Skills.Resources(Dict("saved" => "template"), JuliaForever.Skills.Skill[])
                    signalled = Ref(false)
                    store.hook = () -> begin
                        signalled[] && return nothing
                        signalled[] = true
                        if kind == :queue
                            steer!(active, "queued")
                        else
                            lock(active.lock) do
                                active.fault = H.Rejected(:incomplete_turn)
                            end
                        end
                        nothing
                    end
                    terminal = JuliaForever.Terminal(IOBuffer(), IOBuffer(), String[])
                    same, history, status = JuliaForever.resume!(terminal, active, nothing, target, resources)
                    @test status == 1 && same === active && isnothing(history)
                    @test signalled[] && store.closes == 1
                    @test H.snapshot(store.memory).batches == before
                    @test resources.templates == Dict("saved" => "template") && isempty(resources.skills)
                end
            end
        end
    end
end

@testset "same session and concurrent opposite switches" begin
    history = H.Tree(H.Memory())
    active = Agent(Provider(), []; history)
    before = deepcopy(H.snapshot(history).batches)
    terminal = JuliaForever.Terminal(IOBuffer(), IOBuffer(), String[])
    same, selected, status = JuliaForever.resume!(terminal, active, history, history)
    @test status == 0 && same === active && selected === history
    @test H.snapshot(history).batches == before
    mktempdir() do root
        cd(root) do
            withenv("HOME" => root, "PI_CODING_AGENT_DIR" => joinpath(root, "agent"), "JF_INSTRUCTIONS_DIR" => nothing) do
                path = joinpath(root, "same.sqlite")
                source = H.Tree(open(H.SQLite, path))
                agent = Agent(Provider(), []; history=source)
                saved = deepcopy(H.snapshot(source).batches)
                target = H.Tree(open(H.SQLite, path; create=false))
                restored, selected, status = JuliaForever.resume!(terminal, agent, source, target)
                @test status == 0 && restored !== agent && selected === target
                @test H.snapshot(target).batches == saved
                close(target)
            end
        end
    end
    mktemp() do path, io
        cmd = `$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --threads=2 --project=$(dirname(Base.active_project())) $(joinpath(@__DIR__, "skill_resume_parallel.jl"))`
        process = run(pipeline(ignorestatus(cmd); stdout=io, stderr=io); wait=false)
        finished = timedwait(() -> process_exited(process), 90)
        @test finished == :ok
        finished == :ok || kill(process)
        wait(process)
        flush(io)
        seekstart(io)
        output = read(io, String)
        @test success(process) || (println(output); false)
    end
    close(history)
end

end
