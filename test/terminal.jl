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

if haskey(ENV, "PI_SOURCE")
    @testset "terminal truncation against Pi" begin
        truncated = terminal_process("length", ["start"])
        source = ENV["PI_SOURCE"]
        @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
        @test pi_terminal_truncation(source) == truncated
    end
end
