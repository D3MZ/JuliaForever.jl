using Test, JuliaForever, JSON3

mutable struct TerminalFixture
    replies::Vector{Tuple{Completion, Vector{String}}}
    observe::Function
end

function JuliaForever.stream(provider::TerminalFixture, messages, tools; parameters=Dict(), on_event=identity)
    result, chunks = popfirst!(provider.replies)
    for chunk in chunks
        on_event((; type=:text, text=chunk))
        provider.observe()
    end
    on_event((; type=result.done ? :done : :incomplete, result))
    result
end

struct TerminalFailure <: JuliaForever.Tool end
JuliaForever.name(::TerminalFailure) = "failure"
JuliaForever.execute(::TerminalFailure, args) = ToolResult("missing synthetic-secret", true)

function terminal_completion(text; calls=[], done=true, failure=nothing)
    message = Dict{String, Any}("role" => "assistant", "content" => text)
    isempty(calls) || (message["tool_calls"] = calls)
    Completion(message, nothing, done ? "stop" : nothing, done, failure)
end

function contents(io::IOBuffer)
    position = Base.position(io)
    seekstart(io)
    text = read(io, String)
    seek(io, position)
    text
end

mutable struct TerminalOutput <: IO
    buffer::IOBuffer
    flushed::Vector{String}
end

Base.unsafe_write(io::TerminalOutput, data::Ptr{UInt8}, count::UInt) = Base.unsafe_write(io.buffer, data, count)
Base.flush(io::TerminalOutput) = push!(io.flushed, contents(io.buffer))

@testset "terminal streaming and tools" begin
    output, diagnostics = TerminalOutput(IOBuffer(), String[]), IOBuffer()
    seen = String[]
    call = Dict("id" => "one", "type" => "function", "function" => Dict("name" => "failure", "arguments" => JSON3.write((; value="synthetic-secret"))))
    replies = [(terminal_completion("Working"; calls=[call]), ["Work", "ing"]), (terminal_completion("done\n"), ["do", "ne\n"])]
    provider = TerminalFixture(replies, () -> push!(seen, contents(output.buffer)))
    terminal = JuliaForever.Terminal(output, diagnostics, ["synthetic-secret"])
    @test JuliaForever.run!(terminal, Agent(provider, [TerminalFailure()]), "start") == 0
    @test seen == ["Work", "Working", "Working\ndo", "Working\ndone\n"]
    @test output.flushed == ["Work", "Working", "Working\n", "Working\ndo", "Working\ndone\n", "Working\ndone\n"]
    @test String(take!(output.buffer)) == "Working\ndone\n"
    @test String(take!(diagnostics)) == "[tool] failure: started\n[tool] failure: error: missing [redacted]\n"
end

@testset "terminal completion and failure" begin
    output, diagnostics = IOBuffer(), IOBuffer()
    provider = TerminalFixture([(terminal_completion("fallback"), String[])], () -> nothing)
    terminal = JuliaForever.Terminal(output, diagnostics, ["synthetic-secret"])
    @test JuliaForever.run!(terminal, Agent(provider, []), "start") == 0
    @test String(take!(output)) == "fallback\n"
    @test isempty(String(take!(diagnostics)))

    provider = TerminalFixture([(terminal_completion("partial"; done=false, failure="stream failed: synthetic-secret"), ["partial"])], () -> nothing)
    @test JuliaForever.run!(terminal, Agent(provider, []), "start") == 1
    @test String(take!(output)) == "partial\n"
    @test String(take!(diagnostics)) == "Response incomplete: the provider stream did not finish\n"
end

function terminal_process(mode, args; input="", key="synthetic-secret")
    project = dirname(@__DIR__)
    script = joinpath(@__DIR__, "terminal_process.jl")
    cmd = addenv(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --project=$project $script $args`, "JF_FIXTURE" => mode, "JF_PROVIDER" => "openai", "OPENAI_MODEL" => "fixture", "OPENAI_API_KEY" => key)
    mktempdir() do dir
        stdinpath, stdoutpath, stderrpath = joinpath.((dir,), ("stdin", "stdout", "stderr"))
        write(stdinpath, input)
        process = run(pipeline(ignorestatus(cmd); stdin=stdinpath, stdout=stdoutpath, stderr=stderrpath))
        (; status=process.exitcode, output=read(stdoutpath, String), diagnostics=read(stderrpath, String))
    end
end

@testset "terminal process streams and status" begin
    success = terminal_process("tool", ["start"])
    @test success.status == 0
    @test success.output == "Before\nafter\n"
    @test occursin("[tool] read: started\n", success.diagnostics)
    @test occursin("[tool] read: error:", success.diagnostics)
    @test occursin("[redacted]", success.diagnostics)
    @test !occursin("synthetic-secret", success.diagnostics)

    incomplete = terminal_process("incomplete", ["start"])
    @test incomplete == (; status=1, output="partial\n", diagnostics="Response incomplete: the provider stream did not finish\n")

    failure = terminal_process("http", ["start"])
    @test failure == (; status=1, output="", diagnostics="Request failed (HTTP 401).\n")

    invalid = terminal_process("json", ["start"])
    @test invalid == (; status=1, output="", diagnostics="Request failed (invalid provider response).\n")

    bug = terminal_process("bug", ["start"])
    @test bug.status != 0
    @test occursin("ordinary failure", bug.diagnostics)

    piped = terminal_process("echo", String[]; input="one\ntwo\n/exit\nignored\n")
    @test piped == (; status=0, output="reply:one\nreply:two\n", diagnostics="")

    missing = terminal_process("echo", ["start"]; key=nothing)
    @test missing == (; status=2, output="", diagnostics="Set OPENAI_API_KEY.\n")

    help = terminal_process("echo", ["--help"]; key=nothing)
    @test help.status == 0
    @test startswith(help.output, "jf [--codemode] [prompt]")
    @test isempty(help.diagnostics)
end
