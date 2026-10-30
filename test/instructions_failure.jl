using Test, JuliaForever, JSON3

mutable struct StartupHistory <: JuliaForever.History.Store
    closed::Bool
end
JuliaForever.History.snapshot(::StartupHistory) = JuliaForever.History.Snapshot(0, Vector{Any}[])
Base.close(history::StartupHistory) = (history.closed = true)

struct StartupTool <: JuliaForever.Tool
    calls::Base.RefValue{Int}
end
JuliaForever.name(::StartupTool) = "startup_probe"
JuliaForever.description(::StartupTool) = "Record unexpected calls."
JuliaForever.schema(::StartupTool) = Dict("type" => "object")
function JuliaForever.execute(tool::StartupTool, args)
    tool.calls[] += 1
    ToolResult("unexpected")
end

struct BrokenStartupTool <: JuliaForever.Tool end
JuliaForever.name(::BrokenStartupTool) = "broken_startup"
JuliaForever.description(::BrokenStartupTool) = 1 + "unexpected"

struct IOStartupTool <: JuliaForever.Tool
    path::String
end
JuliaForever.name(::IOStartupTool) = "io_startup"
JuliaForever.description(tool::IOStartupTool) = join(readdir(tool.path), " ")

struct StartupProvider
    calls::Base.RefValue{Int}
end
function JuliaForever.stream(provider::StartupProvider, messages, tools; parameters=Dict(), on_event=identity)
    provider.calls[] += 1
    Completion(Dict{String, Any}("role" => "assistant", "content" => "unexpected"), nothing, "stop", true, nothing)
end

function startup_snapshot(tool)
    registry = JuliaForever.Extensions.Registry()
    JuliaForever.Extensions.register!(registry, :probe, JuliaForever.Extensions.Plugin(; tools=(tool,)))
    JuliaForever.Extensions.snapshot(registry)
end

function instruction_failure_process(workspace, sessions, requests, key, args)
    project = dirname(@__DIR__)
    script = joinpath(@__DIR__, "session_cli_process.jl")
    cmd = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --project=$project $script $args`; dir=workspace)
    cmd = addenv(cmd, "JF_SESSION_REQUESTS" => requests, "JF_SESSION_FAIL" => nothing, "JF_SESSION_DIR" => sessions, "JF_PROVIDER" => "openai", "OPENAI_BASE_URL" => "http://127.0.0.1:1/v1", "OPENAI_MODEL" => "fixture", "OPENAI_API_KEY" => key, "JF_INSTRUCTIONS_DIR" => nothing)
    mktempdir() do dir
        output, diagnostics = joinpath.((dir,), ("stdout", "stderr"))
        process = run(pipeline(ignorestatus(cmd); stdin=devnull, stdout=output, stderr=diagnostics))
        (; status=process.exitcode, output=read(output, String), diagnostics=read(diagnostics, String))
    end
end

@testset "instruction failure redacts before dispatch" begin
    Sys.isunix() && mktempdir() do root
        key = "synthetic" * Char(0x80)
        workspace = joinpath(root, "project-" * key * "a")
        sessions = joinpath(root, "sessions")
        requests = joinpath(root, "requests")
        mkpath(workspace)
        instruction = joinpath(workspace, "AGENTS.md")
        write(instruction, "unreadable fixture")
        chmod(instruction, 0)
        try
            tool = StartupTool(Ref(0))
            provider = StartupProvider(Ref(0))
            history = StartupHistory(false)
            output, diagnostics = IOBuffer(), IOBuffer()
            terminal = JuliaForever.Terminal(output, diagnostics, [key])
            result = try
                cd(workspace) do
                    withenv("JF_INSTRUCTIONS_DIR" => nothing) do
                        JuliaForever.runsession!(history, terminal, provider, startup_snapshot(tool), ["start"])
                    end
                end
            catch exception
                exception
            end
            message = String(take!(diagnostics))
            @test result == 1
            @test history.closed
            @test provider.calls[] == 0 && tool.calls[] == 0
            @test isempty(String(take!(output)))
            @test occursin("project-[redacted]a", message)
            @test !occursin(key, message) && !occursin(chop(repr(key * "a"); head=1, tail=1), message)

            explicit = joinpath(root, "explicit.sqlite")
            for args in (["--no-session", "start"], ["start"], ["--history", explicit, "start"])
                process = instruction_failure_process(workspace, sessions, requests, key, args)
                @test process.status == 1 && isempty(process.output)
                @test occursin("project-[redacted]a", process.diagnostics)
                @test occursin("permission denied", lowercase(process.diagnostics))
                @test !occursin(key, process.diagnostics) && !occursin(chop(repr(key * "a"); head=1, tail=1), process.diagnostics)
                @test !isfile(requests)
            end
            @test !isdir(sessions) || isempty(readdir(sessions))
            history = open(JuliaForever.History.SQLite, explicit; create=false)
            @test history isa JuliaForever.History.SQLite
            @test JuliaForever.History.snapshot(history).revision == 0
            close(history)
        finally
            chmod(instruction, 0o600)
        end
    end
end

@testset "unexpected startup exceptions propagate and close history" begin
    mktempdir() do workspace
        history = StartupHistory(false)
        terminal = JuliaForever.Terminal(IOBuffer(), IOBuffer(), String[])
        @test_throws MethodError cd(workspace) do
            withenv("JF_INSTRUCTIONS_DIR" => nothing) do
                JuliaForever.runsession!(history, terminal, StartupProvider(Ref(0)), startup_snapshot(BrokenStartupTool()), ["start"])
            end
        end
        @test history.closed
    end
end

@testset "startup IO errors use the same boundary" begin
    mktempdir() do workspace
        key = "synthetic-io-key"
        missing = joinpath(workspace, "missing-" * key)
        exception = try
            readdir(missing)
        catch exception
            exception
        end
        @test exception isa Base.IOError
        provider = StartupProvider(Ref(0))
        history = StartupHistory(false)
        output, diagnostics = IOBuffer(), IOBuffer()
        terminal = JuliaForever.Terminal(output, diagnostics, [key])
        result = cd(workspace) do
            withenv("JF_INSTRUCTIONS_DIR" => nothing) do
                JuliaForever.runsession!(history, terminal, provider, startup_snapshot(IOStartupTool(missing)), ["start"])
            end
        end
        message = String(take!(diagnostics))
        @test result == 1 && history.closed && provider.calls[] == 0
        @test occursin("missing-[redacted]", message) && !occursin(key, message)
        @test isempty(String(take!(output)))
    end
end

@testset "resumed sessions retain their captured instructions" begin
    Sys.isunix() && mktempdir() do root
        workspace = joinpath(root, "project")
        sessions = joinpath(root, "sessions")
        requests = joinpath(root, "requests")
        mkpath(workspace)
        instruction = joinpath(workspace, "AGENTS.md")
        write(instruction, "original fixture")
        first = instruction_failure_process(workspace, sessions, requests, "synthetic-secret", ["start"])
        @test first.status == 0 && first.output == "reply:start\n"
        chmod(instruction, 0)
        try
            resumed = instruction_failure_process(workspace, sessions, requests, "synthetic-secret", ["--continue", "next"])
            @test resumed.status == 0 && resumed.output == "reply:next\n"
            messages = JSON3.read(last(readlines(requests)))
            @test occursin("original fixture", messages[1].content)
            @test [message.content for message in messages if message.role in ("user", "assistant")] == ["start", "reply:start", "next"]
        finally
            chmod(instruction, 0o600)
        end
    end
end
