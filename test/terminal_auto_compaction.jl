module TerminalAutoCompactionTests

using Test, JuliaForever, JSON3

const project = dirname(@__DIR__)
const process = joinpath(@__DIR__, "terminal_auto_compaction_process.jl")

function setup(root)
    agentdir = joinpath(root, "agent")
    mkpath(agentdir)
    model = (; id="small", name="Small", contextWindow=16514, maxTokens=64)
    config = (; providers=(; fixture=(; api="openai-completions", apiKey="fixture", baseUrl="http://localhost", models=[model])))
    write(joinpath(agentdir, "models.json"), JSON3.write(config))
    write(joinpath(agentdir, "settings.json"), JSON3.write((; compaction=(; keepRecentTokens=0))))
    agentdir
end

function terminal(root, name, input; summary="")
    history = joinpath(root, name * ".sqlite")
    requests = joinpath(root, name * ".jsonl")
    command = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --project=$project $process --history $history --provider fixture --model small`; dir=root)
    command = addenv(command, "HOME" => root, "PI_CODING_AGENT_DIR" => joinpath(root, "agent"), "JF_AUTO_REQUESTS" => requests, "JF_AUTO_SUMMARY" => summary, "JF_AUTO_GATE" => nothing, "JF_INSTRUCTIONS_DIR" => root, "JF_SESSION_DIR" => joinpath(root, "sessions"))
    out, diagnostics = IOBuffer(), IOBuffer()
    result = run(pipeline(ignorestatus(command); stdin=IOBuffer(input), stdout=out, stderr=diagnostics))
    calls = isfile(requests) ? JSON3.read.(readlines(requests)) : []
    (; status=result.exitcode, output=String(take!(out)), diagnostics=String(take!(diagnostics)), calls)
end

@testset "terminal compacts at the configured threshold and resumes" begin
    mktempdir() do root
        agentdir = setup(root)
        first = terminal(root, "normal", "first\nsecond\nthird\n/exit\n")
        @test first.status == 0 && first.output == "reply:first\nreply:second\nreply:third\n"
        @test [call.operation for call in first.calls] == ["respond", "respond", "summarize", "respond"]
        @test occursin("Auto-compaction", first.diagnostics)
        @test occursin("reply:first", JSON3.write(first.calls[3].messages))
        @test occursin("checkpoint", JSON3.write(first.calls[4].messages))
        resumed = terminal(root, "normal", "fourth\n/exit\n")
        @test resumed.status == 0 && occursin("checkpoint", JSON3.write(resumed.calls[end].messages))

        if haskey(ENV, "PI_SOURCE")
            source = ENV["PI_SOURCE"]
            @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
            oracle = JSON3.read(read(`node $(joinpath(@__DIR__, "terminal_auto_compaction_pi.mjs")) $source $root $agentdir`, String))
            @test oracle.settings.enabled && oracle.settings.reserveTokens == 16384 && oracle.settings.keepRecentTokens == 0
            @test oracle.decisions == [false, true]
        end
    end
end

@testset "automatic compaction retains the configured recent context" begin
    mktempdir() do root
        agentdir = setup(root)
        write(joinpath(agentdir, "settings.json"), JSON3.write((; compaction=(;))))
        retained = terminal(root, "retained", "first\nsecond\nthird\n/exit\n")
        @test retained.status == 0
        @test [call.operation for call in retained.calls] == ["respond", "respond", "respond"]
        @test occursin("reply:first", JSON3.write(retained.calls[end].messages))
        overflow = terminal(root, "kept-overflow", "first\noverflow\n/exit\n")
        @test overflow.status == 1 && [call.operation for call in overflow.calls] == ["respond", "respond"]
        if haskey(ENV, "PI_SOURCE")
            oracle = JSON3.read(read(`node $(joinpath(@__DIR__, "terminal_auto_compaction_pi.mjs")) $(ENV["PI_SOURCE"]) $root $agentdir`, String))
            @test oracle.preparations == [true, false]
            messages = JuliaForever.Conversation.Message[
                JuliaForever.Conversation.User("first"), JuliaForever.Conversation.Assistant("reply:first", JuliaForever.Conversation.ToolCall[], "stop", true),
                JuliaForever.Conversation.User("second"), JuliaForever.Conversation.Assistant("reply:second", JuliaForever.Conversation.ToolCall[], "stop", true),
            ]
            @test [JuliaForever.recentcut(messages, keep) - 1 for keep in (0, 1, 3, 4, 5, 7, 20000)] == oracle.cuts
            toolmessages = JuliaForever.Conversation.Message[
                JuliaForever.Conversation.User("read file"), JuliaForever.Conversation.Assistant(nothing, [JuliaForever.Conversation.ToolCall("call", "read", "{}")], "tool_calls", true),
                JuliaForever.Conversation.ToolMessage("call", "file contents", false), JuliaForever.Conversation.Assistant("done", JuliaForever.Conversation.ToolCall[], "stop", true),
            ]
            @test [JuliaForever.recentcut(toolmessages, keep) - 1 for keep in (0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 20000)] == oracle.toolCuts
        end
        call = Dict("id" => "call", "type" => "function", "function" => Dict("name" => "read", "arguments" => "{}"))
        initial = Dict{String, Any}[
            Dict("role" => "user", "content" => "read file"),
            Dict("role" => "assistant", "content" => nothing, "tool_calls" => [call]),
            Dict("role" => "tool", "tool_call_id" => "call", "content" => "file contents"),
            Dict("role" => "assistant", "content" => "done"),
        ]
        history = JuliaForever.History.Memory()
        agent = Agent(nothing, []; history)
        append!(agent.messages, initial)
        policy = JuliaForever.UsageCompaction(100, 20, JuliaForever.RecentTokens(6))
        usage = Usage(81, 0, 0, 0, 0, 81, nothing)
        @test JuliaForever.autocompact!(agent, usage, policy, _ -> "checkpoint") == "checkpoint"
        @test [message["role"] for message in agent.messages] == ["user", "assistant", "tool", "assistant"]
        @test agent.messages[2]["tool_calls"][1]["id"] == "call" && agent.messages[3]["tool_call_id"] == "call"
        @test Agent(nothing, []; history).messages == agent.messages
    end
end

@testset "terminal honors Pi settings and recovers an overflow" begin
    mktempdir() do root
        agentdir = setup(root)
        write(joinpath(agentdir, "settings.json"), JSON3.write((; compaction=(; enabled=false, reserveTokens=16384, keepRecentTokens=0))))
        disabled = terminal(root, "disabled", "first\nsecond\nthird\n/exit\n")
        @test disabled.status == 0 && [call.operation for call in disabled.calls] == ["respond", "respond", "respond"]
        @test !occursin("checkpoint", JSON3.write(disabled.calls[end].messages))

        mkpath(joinpath(root, ".pi"))
        settings = (; compaction=(; enabled=true, modelOverrides=(; var"fixture/small"=(; reserveTokens=16384))))
        write(joinpath(root, ".pi", "settings.json"), JSON3.write(settings))
        overflow = terminal(root, "overflow", "first\noverflow\n/exit\n")
        @test overflow.status == 0 && occursin("reply:overflow", overflow.output)
        @test [call.operation for call in overflow.calls] == ["respond", "respond", "summarize", "respond"]
        @test occursin("checkpoint", JSON3.write(overflow.calls[end].messages))
        if haskey(ENV, "PI_SOURCE")
            oracle = JSON3.read(read(`node $(joinpath(@__DIR__, "terminal_auto_compaction_pi.mjs")) $(ENV["PI_SOURCE"]) $root $agentdir`, String))
            @test oracle.settings.enabled && oracle.settings.reserveTokens == 16384 && oracle.decisions == [false, true]
        end

        failed = terminal(root, "failed", "first\nsecond\nthird\n/exit\n"; summary="fail")
        @test failed.status == 0 && occursin("Auto-compaction failed", failed.diagnostics)
        @test !occursin("checkpoint", JSON3.write(failed.calls[end].messages))
        @test occursin("reply:first", JSON3.write(failed.calls[end].messages))
    end
end

@testset "compaction settings follow Pi project and model precedence" begin
    mktempdir() do root
        agentdir = setup(root)
        globalsettings = (; compaction=(; enabled=false, reserveTokens=16380, modelOverrides=(; var"fixture/small"=(; reserveTokens=16383))))
        localsettings = (; compaction=(; enabled=true, reserveTokens=16384))
        write(joinpath(agentdir, "settings.json"), JSON3.write(globalsettings))
        mkpath(joinpath(root, ".pi"))
        localpath = joinpath(root, ".pi", "settings.json")
        write(localpath, JSON3.write(localsettings))
        registry = JuliaForever.Models.load(joinpath(agentdir, "models.json"))
        provider = OpenAI("http://localhost", "small", "fixture", Pair{String, String}[], JuliaForever.CatalogRoute("fixture", registry))
        policy() = JuliaForever.terminalcompaction(provider, "fixture", Dict("PI_CODING_AGENT_DIR" => agentdir), root)
        selected = policy()
        @test selected isa JuliaForever.UsageCompaction && selected.context_window == 16514 && selected.reserve_tokens == 16383
        if haskey(ENV, "PI_SOURCE")
            oracle = JSON3.read(read(`node $(joinpath(@__DIR__, "terminal_auto_compaction_pi.mjs")) $(ENV["PI_SOURCE"]) $root $agentdir`, String))
            @test oracle.settings.enabled && oracle.settings.reserveTokens == selected.reserve_tokens && oracle.decisions == [false, false]
        end
        write(localpath, JSON3.write((; compaction=(; enabled=true, modelOverrides=(; var"fixture/small"=(; reserveTokens=16384))))))
        @test policy().reserve_tokens == 16384
        write(localpath, JSON3.write((; compaction=(; enabled=true, reserveTokens=-1))))
        @test policy() isa JuliaForever.Models.InvalidConfig
        invalid = terminal(root, "invalid", "first\n/exit\n")
        @test invalid.status == 2 && isempty(invalid.calls) && occursin("compaction settings", invalid.diagnostics)
    end
end

end
