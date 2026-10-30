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

function terminal_completion(text; calls=[], finish="stop", done=true, failure=nothing)
    message = Dict{String, Any}("role" => "assistant", "content" => text)
    isempty(calls) || (message["tool_calls"] = calls)
    Completion(message, nothing, done ? finish : nothing, done, failure)
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

@testset "terminal truncated final text" begin
    for history in (nothing, JuliaForever.History.Memory())
        output, diagnostics = TerminalOutput(IOBuffer(), String[]), IOBuffer()
        seen = String[]
        provider = TerminalFixture([(terminal_completion("partial content"; finish="length"), ["partial", " content"])], () -> push!(seen, contents(output.buffer)))
        terminal = JuliaForever.Terminal(output, diagnostics, String[])
        @test JuliaForever.run!(terminal, Agent(provider, []; history), "start") == 1
        @test seen == ["partial", "partial content"]
        @test contents(output.buffer) == "partial content\n"
        @test "partial content" in output.flushed
        @test String(take!(diagnostics)) == "Response was truncated: the model reached its output token limit.\n"
    end
end

@testset "terminal incomplete stream after length reason" begin
    output, diagnostics = IOBuffer(), IOBuffer()
    message = Dict{String, Any}("role" => "assistant", "content" => "partial")
    response = Completion(message, nothing, "length", false, "stream interrupted")
    provider = TerminalFixture([(response, ["partial"])], () -> nothing)
    terminal = JuliaForever.Terminal(output, diagnostics, String[])
    @test JuliaForever.run!(terminal, Agent(provider, []), "start") == 1
    @test String(take!(output)) == "partial\n"
    @test String(take!(diagnostics)) == "Response incomplete: the provider stream did not finish\n"
end

@testset "terminal recovers from truncated tool calls" begin
    mktempdir() do dir
        call = Dict("id" => "one", "type" => "function", "function" => Dict("name" => "write", "arguments" => JSON3.write((; path="unsafe.txt", content="partial"))))
        for history in (nothing, JuliaForever.History.Memory())
            replies = [(terminal_completion("partial"; calls=[call], finish="length"), ["partial"]), (terminal_completion("recovered"), ["recovered"])]
            provider = TerminalFixture(replies, () -> nothing)
            output, diagnostics = IOBuffer(), IOBuffer()
            terminal = JuliaForever.Terminal(output, diagnostics, String[])
            @test JuliaForever.run!(terminal, Agent(provider, [Write(dir)]; history), "start") == 0
            @test String(take!(output)) == "partial\nrecovered\n"
            @test occursin("output token limit", String(take!(diagnostics)))
            @test !isfile(joinpath(dir, "unsafe.txt"))
        end
    end
end

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

@testset "terminal redacts formatted tool errors" begin
    cases = [("synthetic" * Char(0x80), "a"), ("synthetic" * Char(0x10ffff), "f"), ("synthetic" * Char(0x7f), "0")]
    Sys.iswindows() || append!(cases, [("synthetic\\", "a"), ("synthetic" * repeat("\\", 20), "a")])
    for (key, suffix) in cases
        mktempdir() do dir
            path = "missing-" * key * suffix
            call = Dict("id" => "one", "type" => "function", "function" => Dict("name" => "read", "arguments" => JSON3.write((; path))))
            replies = [(terminal_completion(nothing; calls=[call], finish="tool_calls"), String[]), (terminal_completion("done"), ["done"])]
            provider = TerminalFixture(replies, () -> nothing)
            output, diagnostics = IOBuffer(), IOBuffer()
            terminal = JuliaForever.Terminal(output, diagnostics, [key])
            @test JuliaForever.run!(terminal, Agent(provider, [Read(dir)]), "start") == 0
            text = String(take!(diagnostics))
            @test occursin("missing-[redacted]" * suffix, text)
            @test !occursin(chop(repr(key * suffix); head=1, tail=2), text)
        end
    end
    key = "synthetic" * '\0'
    terminal = JuliaForever.Terminal(IOBuffer(), IOBuffer(), [key])
    @test JuliaForever.redact(terminal, repr("before " * key * "0 after")) == repr("before [redacted]0 after")
    for key in ("synthetic\\", "synthetic" * repeat("\\", 20))
        terminal = JuliaForever.Terminal(IOBuffer(), IOBuffer(), [key])
        @test JuliaForever.redact(terminal, repr("before " * key * "a after")) == repr("before [redacted]a after")
    end
end

@testset "terminal redacts quoted forms in context" begin
    for char in (Char(0), Char(0x7f), Char(0x80), Char(0x9f), Char(0x10ffff)), suffix in ("", "0", "7", "8", "a", "f", "A", "F", "g")
        key = "synthetic" * char
        terminal = JuliaForever.Terminal(IOBuffer(), IOBuffer(), [key])
        @test JuliaForever.redact(terminal, repr("before " * key * suffix * " after")) == repr("before [redacted]" * suffix * " after")
    end
end

@testset "terminal request preserves unexpected exceptions" begin
    terminal = JuliaForever.Terminal(IOBuffer(), IOBuffer(), String[])
    @test_throws TaskFailedException JuliaForever.request!(() -> 1 + "synthetic", terminal)
end

function terminal_process(mode, args; input="", key="synthetic-secret")
    project = dirname(@__DIR__)
    script = joinpath(@__DIR__, "terminal_process.jl")
    session = "--history" in args ? String[] : ["--no-session"]
    cmd = addenv(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --project=$project $script $session $args`, "JF_FIXTURE" => mode, "JF_PROVIDER" => "openai", "OPENAI_MODEL" => "fixture", "OPENAI_API_KEY" => key)
    mktempdir() do dir
        stdinpath, stdoutpath, stderrpath = joinpath.((dir,), ("stdin", "stdout", "stderr"))
        write(stdinpath, input)
        process = run(pipeline(ignorestatus(cmd); stdin=stdinpath, stdout=stdoutpath, stderr=stderrpath))
        (; status=process.exitcode, output=read(stdoutpath, String), diagnostics=read(stderrpath, String))
    end
end

function pi_terminal_truncation(source)
    script = joinpath(@__DIR__, "terminal_truncation_pi.mjs")
    mktempdir() do dir
        output, diagnostics = joinpath.((dir,), ("output", "diagnostics"))
        cmd = `node --conditions=source --experimental-strip-types $script $source`
        process = run(pipeline(ignorestatus(cmd); stdout=output, stderr=diagnostics))
        (; status=process.exitcode, output=read(output, String), diagnostics=read(diagnostics, String))
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

    truncated = terminal_process("length", ["start"])
    @test truncated == (; status=1, output="partial content\n", diagnostics="Response was truncated: the model reached its output token limit.\n")
    mktempdir() do dir
        @test terminal_process("length", ["--history", joinpath(dir, "history.sqlite"), "start"]) == truncated
    end
    if haskey(ENV, "PI_SOURCE")
        source = ENV["PI_SOURCE"]
        @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
        @test pi_terminal_truncation(source) == truncated
    end

    failure = terminal_process("http", ["start"])
    @test failure == (; status=1, output="", diagnostics="Request failed (HTTP 401).\n")

    invalid = terminal_process("json", ["start"])
    @test invalid.status != 0
    @test occursin("invalid JSON", invalid.diagnostics)

    bug = terminal_process("bug", ["start"])
    @test bug.status != 0
    @test occursin("ordinary failure", bug.diagnostics)

    piped = terminal_process("echo", String[]; input="one\ntwo\n/exit\nignored\n")
    @test piped == (; status=0, output="reply:one\nreply:two\n", diagnostics="")

    missing = terminal_process("echo", ["start"]; key=nothing)
    @test missing == (; status=2, output="", diagnostics="Set OPENAI_API_KEY.\n")

    help = terminal_process("echo", ["--help"]; key=nothing)
    @test help.status == 0
    @test startswith(help.output, "jf [--provider NAME] [--model ID] [--codemode] [--history PATH] [prompt]")
    @test isempty(help.diagnostics)
end

@testset "non-sticky terminal request" begin
    terminal = JuliaForever.Terminal(IOBuffer(), IOBuffer(), String[])
    @test JuliaForever.request!(() -> current_task().sticky, terminal).value === false
end

@testset "terminal pseudo-terminal input" begin
    python = Sys.which("python3")
    if Sys.isunix() && !isnothing(python)
        script = joinpath(@__DIR__, "terminal_pty.py")
        julia = joinpath(Sys.BINDIR, Base.julia_exename())
        @test success(`$python $script $julia $(dirname(@__DIR__))`)
    else
        @test_skip "PTY test requires Unix and python3"
    end
end
