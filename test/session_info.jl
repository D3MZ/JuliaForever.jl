module SessionInfoTests

using Test, JuliaForever, JSON3

const project = dirname(@__DIR__)
const process = joinpath(@__DIR__, "terminal_process.jl")

function runterminal(root, args, input; fixture="usage")
    capture = joinpath(root, "requests.jsonl")
    command = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --project=$project $process $args`; dir=root)
    command = addenv(command, "JF_INSTRUCTIONS_DIR" => root, "JF_SESSION_DIR" => joinpath(root, "sessions"), "JF_FIXTURE" => fixture, "JF_CAPTURE" => capture, "JF_CAPTURE_MESSAGES" => joinpath(root, "messages.jsonl"), "JF_PROVIDER" => "openai", "OPENAI_MODEL" => "fixture", "OPENAI_API_KEY" => "synthetic-secret")
    output, diagnostics = IOBuffer(), IOBuffer()
    result = run(pipeline(ignorestatus(command); stdin=IOBuffer(input), stdout=output, stderr=diagnostics))
    (; status=result.exitcode, output=String(take!(output)), diagnostics=String(take!(diagnostics)), capture)
end

@testset "session information and durable usage" begin
    info = JuliaForever.Conversation.ResponseInfo(JuliaForever.Usage(1, 2, 3, 4, 0, 10, 0.2), "api", nothing, "model", 123)
    message = JuliaForever.Conversation.Assistant("ok", JuliaForever.Conversation.ToolCall[], "stop", true; info)
    @test isequal(JSON3.read(JSON3.write(message), JuliaForever.Conversation.Assistant), message)
    mktempdir() do root
        history = joinpath(root, "session.sqlite")
        exported = joinpath(root, "session.jsonl")
        first = runterminal(root, ["--history", history], "first\nsecond\n/name Example\n/session\n/export $exported\n/exit\n")
        @test first.status == 0
        @test length(readlines(first.capture)) == 2
        requests = JSON3.read.(readlines(joinpath(root, "messages.jsonl")))
        @test all(!haskey(message, :usage) && !haskey(message, :responseInfo) for message in requests[2])
        @test occursin("Session Info", first.diagnostics)
        @test occursin("Name: Example", first.diagnostics)
        @test occursin("User: 2", first.diagnostics) && occursin("Assistant: 2", first.diagnostics)
        @test occursin("Input: 195", first.diagnostics) && occursin("Output: 30", first.diagnostics)
        @test occursin("Cached: 35 (17.9%)", first.diagnostics) && occursin("Uncached: 160 (10 written to cache)", first.diagnostics)
        @test occursin("Total: 225", first.diagnostics) && occursin("\$0.015", first.diagnostics)
        @test occursin("Response usage excludes compaction requests.", first.diagnostics)
        if isfile(exported)
            rows = JSON3.read.(readlines(exported))
            assistants = [row.message for row in rows if row.type == "message" && row.message.role == "assistant"]
            @test [a.usage.totalTokens for a in assistants] == [160, 65]
            @test [a.usage.cost.total for a in assistants] == [0.012, 0.003]
            @test all(a.model == "fixture" && a.api == "openai-completions" && a.timestamp > 0 for a in assistants)
        else
            @test false
        end
        reopened = runterminal(root, ["--history", history], "/session\n/exit\n")
        @test reopened.status == 0 && length(readlines(reopened.capture)) == 2
        @test occursin("User: 2", reopened.diagnostics) && occursin("Assistant: 2", reopened.diagnostics)
        @test occursin("Input: 195", reopened.diagnostics) && occursin("Total: 225", reopened.diagnostics)
        @test occursin("\$0.015", reopened.diagnostics)
        rpc = runterminal(root, ["--history", history, "--mode", "rpc"], JSON3.write((; id="stats", type="get_session_stats")) * "\n")
        records = JSON3.read.(split(chomp(rpc.output), '\n'))
        stats = only(filter(row -> get(row, :id, "") == "stats", records))
        @test stats.success
        if stats.success
            @test stats.data.tokens.total == 225 && stats.data.cost ≈ 0.015
        end
        if haskey(ENV, "PI_SOURCE")
            @test readchomp(`git -C $(ENV["PI_SOURCE"]) rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
            oracle = JSON3.read(read(`node $(joinpath(@__DIR__, "session_info_pi.mjs")) $(ENV["PI_SOURCE"])`, String))
            @test oracle.userMessages == 2 && oracle.assistantMessages == 2 && oracle.totalMessages == 4
            @test oracle.tokens.input + oracle.tokens.cacheRead + oracle.tokens.cacheWrite == 195
            @test oracle.tokens.output == 30 && oracle.tokens.total == 225
            @test oracle.cost ≈ 0.015
        end
    end
    mktempdir() do root
        result = runterminal(root, ["--no-session"], "unknown\n/name Safe\e[2JName\n/session\n/exit\n"; fixture="echo")
        @test occursin("In-memory", result.diagnostics)
        @test occursin("Unavailable", result.diagnostics)
        @test !occursin('\e', last(split(result.diagnostics, "Session Info")))
    end
    mktempdir() do root
        missing = runterminal(root, ["--no-session"], "first\n/session\n/exit\n"; fixture="usage_uncosted")
        @test occursin("Input: 140", missing.diagnostics) && occursin("Total: 160", missing.diagnostics)
        @test occursin("Cost\nTotal: Unavailable", missing.diagnostics)
    end
    mktempdir() do root
        incomplete = runterminal(root, ["--no-session"], "first\n/session\n/exit\n"; fixture="usage_incomplete")
        @test occursin("Assistant: 1", incomplete.diagnostics) && occursin("Total: 160", incomplete.diagnostics)
        @test occursin("\$0.012", incomplete.diagnostics)
    end
end

@testset "live session information" begin
    python = Sys.which("python3")
    if Sys.isunix() && !isnothing(python) && !isnothing(Sys.which("tmux"))
        julia = first(Base.julia_cmd().exec)
        @test success(`$python $(joinpath(@__DIR__, "session_info_live.py")) $project $julia`)
    else
        @test_skip false
    end
end

end
