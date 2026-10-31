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
