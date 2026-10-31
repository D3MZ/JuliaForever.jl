module ModelCostTests

using Test, JuliaForever, JSON3, HTTP

const project = dirname(@__DIR__)
const process = joinpath(@__DIR__, "terminal_process.jl")

function terminal(root, args, input; fixture="usage_uncosted", model="fixture")
    command = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --project=$project $process $args`; dir=root)
    command = addenv(command, "JF_INSTRUCTIONS_DIR" => root, "JF_SESSION_DIR" => joinpath(root, "sessions"), "PI_CODING_AGENT_DIR" => joinpath(root, "agent"), "JF_FIXTURE" => fixture, "JF_PROVIDER" => "openai", "OPENAI_MODEL" => model, "OPENAI_API_KEY" => "synthetic", "OPENAI_BASE_URL" => nothing)
    output, diagnostics = IOBuffer(), IOBuffer()
    result = run(pipeline(ignorestatus(command); stdin=IOBuffer(input), stdout=output, stderr=diagnostics))
    (; status=result.exitcode, output=String(take!(output)), diagnostics=String(take!(diagnostics)))
end

@testset "estimated model pricing through a saved session" begin
    mktempdir() do root
        mkpath(joinpath(root, "agent"))
        rates = (; input=2, output=4, cacheRead=0.5, cacheWrite=1, tiers=[(; inputTokensAbove=130, input=4, output=8, cacheRead=1, cacheWrite=2)])
        config = (; providers=(; openai=(; models=[(; id="fixture", api="openai-completions", cost=rates), (; id="fixturezero", api="openai-completions")]), anthropic=(; models=[(; id="fixture", cost=rates)])))
        configpath = joinpath(root, "agent", "models.json")
        write(configpath, JSON3.write(config))
        history, exported = joinpath(root, "session.sqlite"), joinpath(root, "session.jsonl")
        run = terminal(root, ["--history", history], "first\nsecond\n/session\n/export $exported\n/exit\n")
        @test run.status == 0
        @test occursin("Cost\nTotal: \$0.001", run.diagnostics)
        rows = JSON3.read.(readlines(exported))
        assistants = [row.message for row in rows if row.type == "message" && row.message.role == "assistant"]
        @test length(assistants) == 2
        if length(assistants) == 2
            @test assistants[1].usage.cost.total ≈ 0.00061
            @test assistants[2].usage.cost.total ≈ 0.0001425
            @test assistants[1].usage.cost.input ≈ 0.0004 && assistants[1].usage.cost.output ≈ 0.00016
            @test assistants[1].usage.cost.cacheRead ≈ 0.00003 && assistants[1].usage.cost.cacheWrite ≈ 0.00002
        end
        rpc = terminal(root, ["--history", history, "--mode", "rpc"], JSON3.write((; id="stats", type="get_session_stats")) * "\n")
        records = JSON3.read.(split(chomp(rpc.output), '\n'))
        stats = only(filter(row -> get(row, :id, "") == "stats", records))
        @test stats.success && stats.data.cost ≈ 0.0007525
        live = terminal(root, ["--no-session", "--mode", "json", "first"], "")
        events = JSON3.read.(split(chomp(live.output), '\n'))
        replies = [event.message for event in events if get(event, :type, "") == "message_end" && get(event.message, :role, "") == "assistant"]
        @test length(replies) == 1 && only(replies).usage.cost.total ≈ 0.00061 && !only(replies).usage.cost.totalFromProvider
        reported = terminal(root, ["--no-session", "--mode", "json", "first"], ""; fixture="usage")
        events = JSON3.read.(split(chomp(reported.output), '\n'))
        replies = [event.message for event in events if get(event, :type, "") == "message_end" && get(event.message, :role, "") == "assistant"]
        @test length(replies) == 1 && only(replies).usage.cost.total ≈ 0.012 && only(replies).usage.cost.totalFromProvider
        zero = terminal(root, ["--model", "fixturezero", "--no-session", "--mode", "json", "first"], "")
        events = JSON3.read.(split(chomp(zero.output), '\n'))
        replies = [event.message for event in events if get(event, :type, "") == "message_end" && get(event.message, :role, "") == "assistant"]
        @test length(replies) == 1 && iszero(only(replies).usage.cost.total)
        direct = joinpath(root, "direct")
        mkpath(direct)
        builtin = terminal(direct, ["--no-session", "--mode", "json", "first"], ""; model="gpt-5.4")
        events = JSON3.read.(split(chomp(builtin.output), '\n'))
        builtinreplies = [event.message for event in events if get(event, :type, "") == "message_end" && get(event.message, :role, "") == "assistant"]
        @test length(builtinreplies) == 1 && only(builtinreplies).usage.cost.total ≈ 0.0005575
        registry = JuliaForever.Models.load(configpath)
        model = JuliaForever.Headless.catalog().index[("openai", "gpt-5.4")]
        builtinsettings = Dict("modelOverrides" => Dict("gpt-5.4" => Dict("cost" => Dict("output" => 6))))
        wire = JuliaForever.Headless.builtinwire(model, builtinsettings)
        @test wire.data["cost"]["input"] == 2.5 && wire.data["cost"]["output"] == 6 && length(wire.data["cost"]["tiers"]) == 1
        provider = Anthropic("https://api.anthropic.com", "fixture", "synthetic", Pair{String, String}[], JuliaForever.CatalogRoute("anthropic", registry))
        usage = JuliaForever.AnthropicAPI.usage(Dict("input_tokens" => 100, "output_tokens" => 20, "cache_read_input_tokens" => 30, "cache_creation_input_tokens" => 10, "cache_creation" => Dict("ephemeral_1h_input_tokens" => 4)))
        priced = JuliaForever.price(provider, usage)
        @test priced.cache_write_1h == 4 && priced.cost ≈ 0.000634
        @test isequal(JSON3.read(JSON3.write(priced), Usage), priced)
        if haskey(ENV, "PI_SOURCE")
            source = ENV["PI_SOURCE"]
            @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
            oracle = JSON3.read(read(`node $(joinpath(@__DIR__, "model_cost_pi.mjs")) $source`, String))
            @test assistants[1].usage.cost.total ≈ oracle[1].total && assistants[2].usage.cost.total ≈ oracle[2].total
            @test assistants[1].usage.cost.input ≈ oracle[1].input && assistants[1].usage.cost.cacheWrite ≈ oracle[1].cacheWrite
            @test priced.cost ≈ oracle[3].total && priced.breakdown.cache_write ≈ oracle[3].cacheWrite
            @test only(builtinreplies).usage.cost.total ≈ oracle[4].total
        end
        settings = (; models=[(; id="fixture", api="openai-completions", cost=rates)], modelOverrides=Dict("fixture" => (; cost=(; output=6,))))
        config = (; providers=Dict("openai" => settings))
        write(configpath, JSON3.write(config))
        override = terminal(root, ["--no-session", "--mode", "json", "second"], "")
        events = JSON3.read.(split(chomp(override.output), '\n'))
        replies = [event.message for event in events if get(event, :type, "") == "message_end" && get(event.message, :role, "") == "assistant"]
        @test length(replies) == 1 && only(replies).usage.cost.total ≈ 0.0001625
        rpc = terminal(root, ["--no-session", "--mode", "rpc"], JSON3.write((; id="state", type="get_state")) * "\n")
        state = only(filter(row -> get(row, :id, "") == "state", JSON3.read.(split(chomp(rpc.output), '\n'))))
        @test state.success && state.data.model.cost.input == 2 && state.data.model.cost.output == 6
        @test state.data.model.cost.cacheRead == 0.5 && length(state.data.model.cost.tiers) == 1
        badmodel = (; id="fixture", api="openai-completions", cost=(; input="bad", output=1, cacheRead=0, cacheWrite=0))
        invalid = (; providers=Dict("openai" => (; models=[badmodel])))
        write(configpath, JSON3.write(invalid))
        @test terminal(root, ["--no-session", "first"], "").status == 2
    end
end

@testset "OpenRouter billing attribution" begin
    rates = Dict("input" => 4, "output" => 8, "cacheRead" => 1, "cacheWrite" => 2)
    model = Dict("id" => "fixture", "cost" => rates)
    registry = JuliaForever.Models.Registry(JuliaForever.Models.Model[], Dict{String, Any}("fixture" => Dict("models" => [model])))
    provider = OpenAI("https://openrouter.ai/api/v1", "fixture", "synthetic", Pair{String, String}[], JuliaForever.CatalogRoute("fixture", registry))
    tokens = Dict("prompt_tokens" => 140, "completion_tokens" => 20, "prompt_tokens_details" => Dict("cached_tokens" => 30, "cache_write_tokens" => 10))
    cases = [Dict("cost" => 0.012, "is_byok" => false), Dict("cost" => 0.012, "is_byok" => true, "cost_details" => nothing), Dict("cost" => 0.012, "is_byok" => true, "cost_details" => Dict("upstream_inference_cost" => nothing, "upstream_inference_prompt_cost" => 0.001, "upstream_inference_completions_cost" => 0.002)), Dict("cost" => -1, "is_byok" => false), Dict("cost" => 0.012)]
    actual = [JuliaForever.LiveJSON.usage(JuliaForever.price(provider, JuliaForever.usage(merge(tokens, raw)))).cost for raw in cases]
    @test [value.total for value in actual] ≈ [0.012, 0.00061, 0.015, 0.00061, 0.00061]
    @test [value.totalFromProvider for value in actual] == [true, false, true, false, false]
    if haskey(ENV, "PI_SOURCE")
        oracle = JSON3.read(read(`node $(joinpath(@__DIR__, "openrouter_cost_pi.mjs")) $(ENV["PI_SOURCE"])`, String))
        @test all(actual[index].total ≈ oracle[index].total && actual[index].totalFromProvider == oracle[index].totalFromProvider for index in eachindex(actual))
    end
end

end
