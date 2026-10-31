module CompactionUsageTests

using Test, JuliaForever, JSON3

const project = dirname(@__DIR__)
const process = joinpath(@__DIR__, "compaction_cli_process.jl")

function terminal(root, history, mode, args, input)
    command = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --project=$project $process --history $history $args`; dir=root)
    command = addenv(command, "HOME" => root, "JF_COMPACTION_USAGE" => mode, "JF_COMPACTION_REQUESTS" => joinpath(root, "requests"), "JF_SESSION_DIR" => joinpath(root, "sessions"), "PI_CODING_AGENT_DIR" => joinpath(root, "agent"), "JF_PROVIDER" => "openai", "OPENAI_MODEL" => "fixture", "OPENAI_API_KEY" => "synthetic", "OPENAI_BASE_URL" => nothing, "JF_INSTRUCTIONS_DIR" => root)
    output, diagnostics = IOBuffer(), IOBuffer()
    result = run(pipeline(ignorestatus(command); stdin=IOBuffer(input), stdout=output, stderr=diagnostics))
    (; status=result.exitcode, output=String(take!(output)), diagnostics=String(take!(diagnostics)))
end

@testset "compaction usage survives reopening" begin
    mktempdir() do root
        history = joinpath(root, "session.sqlite")
        initial = terminal(root, history, "success", String[], "first\nsecond\n/compact\n/session\n/exit\n")
        @test initial.status == 0 && occursin("Context compacted.", initial.diagnostics)
        @test occursin("User: 2", initial.diagnostics) && occursin("Assistant: 2", initial.diagnostics)
        @test occursin("Input: 285", initial.diagnostics) && occursin("Output: 28", initial.diagnostics) && occursin("Total: 313", initial.diagnostics)
        @test occursin("Total: \$0.022", initial.diagnostics)
        reopened = terminal(root, history, "success", String[], "/session\n/exit\n")
        @test reopened.status == 0 && occursin("Total: 313", reopened.diagnostics) && occursin("Total: \$0.022", reopened.diagnostics)
        rpc = terminal(root, history, "success", ["--mode", "rpc"], JSON3.write((; id="stats", type="get_session_stats")) * "\n")
        records = JSON3.read.(split(chomp(rpc.output), '\n'))
        stats = only(filter(row -> get(row, :id, "") == "stats", records))
        @test stats.success && stats.data.tokens.total == 313 && stats.data.cost ≈ 0.022
        if haskey(ENV, "PI_SOURCE")
            source = ENV["PI_SOURCE"]
            @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
            oracle = JSON3.read(read(`node $(joinpath(@__DIR__, "compaction_usage_pi.mjs")) $source`, String))
            @test stats.data.tokens.total == oracle.tokens.total && stats.data.cost ≈ oracle.cost
            @test stats.data.userMessages == oracle.userMessages && stats.data.assistantMessages == oracle.assistantMessages && stats.data.totalMessages == oracle.totalMessages
        end
    end
    mktempdir() do root
        history = joinpath(root, "session.sqlite")
        failed = terminal(root, history, "failure", String[], "first\nsecond\n/compact\n/session\n/exit\n")
        @test failed.status == 1 && !occursin("Context compacted.", failed.diagnostics)
        @test occursin("Total: 313", failed.diagnostics) && occursin("Total: \$0.022", failed.diagnostics)
        resumed = terminal(root, history, "success", ["third"], "")
        @test resumed.status == 0 && resumed.output == "reply:third\n"
        requests = JSON3.read.(readlines(joinpath(root, "requests")))
        @test [request.operation for request in requests] == ["respond", "respond", "summarize", "respond"]
        @test occursin("reply:first", JSON3.write(requests[end].messages))
        rpc = terminal(root, history, "success", ["--mode", "rpc"], JSON3.write((; id="stats", type="get_session_stats")) * "\n")
        records = JSON3.read.(split(chomp(rpc.output), '\n'))
        stats = only(filter(row -> get(row, :id, "") == "stats", records))
        @test stats.success && stats.data.tokens.total == 443 && stats.data.cost ≈ 0.032
    end
    mktempdir() do root
        history = joinpath(root, "session.sqlite")
        missing = terminal(root, history, "missing", String[], "first\nsecond\n/compact\n/session\n/exit\n")
        @test missing.status == 0 && occursin("Tokens\nInput: Unavailable", missing.diagnostics)
        reopened = terminal(root, history, "missing", String[], "/session\n/exit\n")
        @test occursin("Tokens\nInput: Unavailable", reopened.diagnostics)
    end
end

mutable struct UsageProvider
    replies::Vector{Completion}
    action::Function
end
function JuliaForever.complete(provider::UsageProvider, messages, tools)
    result = popfirst!(provider.replies)
    provider.action()
    result
end
reply(text, usage) = Completion(Dict{String, Any}("role" => "assistant", "content" => text), usage, "stop", true, nothing)

end
