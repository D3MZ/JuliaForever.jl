using Test, JuliaForever

include("quality.jl")

@testset "file tools" begin
    mktempdir() do dir
        writer = Write(dir)
        reader = Read(dir)
        editor = Edit(dir)
        @test execute(writer, (; path="nested/a.txt", content="one\ntwo\nthree\n")).text == "Successfully wrote to nested/a.txt"
        @test execute(reader, (; path="nested/a.txt")).text == "one\ntwo\nthree\n"
        @test execute(reader, (; path="nested/a.txt", offset=2, limit=1)).text == "two\n\n[2 more lines in file. Use offset=3 to continue.]"
        @test execute(editor, (; path="nested/a.txt", edits=[(; oldText="two", newText="TWO")])).text == "Successfully replaced 1 block(s) in nested/a.txt."
        @test read(joinpath(dir, "nested/a.txt"), String) == "one\nTWO\nthree\n"
        @test execute(writer, (; path="duplicate.txt", content="x x")).iserror == false
        @test execute(editor, (; path="duplicate.txt", edits=[(; oldText="x", newText="y")])).iserror
        @test read(joinpath(dir, "duplicate.txt"), String) == "x x"
        @test execute(editor, (; path="duplicate.txt", edits=[(; oldText="missing", newText="y")])).iserror
        @test read(joinpath(dir, "duplicate.txt"), String) == "x x"
        @test execute(writer, (; path="overlap.txt", content="abcdef")).iserror == false
        @test execute(editor, (; path="overlap.txt", edits=[(; oldText="abc", newText="x"), (; oldText="cde", newText="y")])).iserror
        @test read(joinpath(dir, "overlap.txt"), String) == "abcdef"
    end
end

mutable struct Scripted
    responses::Vector{Any}
    requests::Vector{Any}
end

function JuliaForever.complete(provider::Scripted, messages, tools)
    push!(provider.requests, deepcopy(messages))
    popfirst!(provider.responses)
end

@testset "agent loop" begin
    mktempdir() do dir
        toolcall = Dict("id" => "call-1", "type" => "function", "function" => Dict("name" => "write", "arguments" => "{\"path\":\"a.txt\",\"content\":\"hello\"}"))
        provider = Scripted([Dict("role" => "assistant", "content" => nothing, "tool_calls" => [toolcall]), Dict("role" => "assistant", "content" => "done")], [])
        agent = Agent(provider, [Write(dir), Read(dir), Edit(dir)])
        @test respond!(agent, "create a file") == "done"
        @test read(joinpath(dir, "a.txt"), String) == "hello"
        @test length(provider.requests) == 2
        @test provider.requests[2][end]["role"] == "tool"
        @test provider.requests[2][end]["tool_call_id"] == "call-1"
        @test provider.requests[2][end]["content"] == "Successfully wrote to a.txt"
        @test [message["role"] for message in agent.messages] == ["user", "assistant", "tool", "assistant"]
    end
end

include("agent_core.jl")

include("provider.jl")
include("provider_stream.jl")
include("provider_responses.jl")

if haskey(ENV, "PI_SOURCE")
    include("agent_core_differential.jl")
    include("differential.jl")
end

include("system.jl")
include("durable.jl")
include("session.jl")
include("kernel.jl")
include("execution.jl")
include("kernel_execution.jl")
include("logs.jl")
include("search.jl")
include("codemode.jl")
include("scheduler.jl")
if haskey(ENV, "PI_SOURCE")
    include("session_differential.jl")
    include("system_differential.jl")
    mktempdir() do oracle
        withenv("PI_CODING_AGENT_DIR" => oracle) do
            include("search_differential.jl")
        end
    end
end
