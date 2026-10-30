using Test, JuliaForever, HTTP, JSON3
isdefined(Main, :models_process) || include_string(Main, first(split(read(joinpath(@__DIR__, "terminal_models.jl"), String), "@testset")), joinpath(@__DIR__, "terminal_models.jl"))

@testset "Anthropic budget thinking" begin
    requests = Channel{Any}(30)
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        put!(requests, (; body=JSON3.read(String(request.body), Dict{String, Any}), key=HTTP.header(request, "x-api-key", ""), beta=HTTP.header(request, "anthropic-beta", "")))
        events = [Dict("type" => "message_start", "message" => Dict("usage" => Dict())), Dict("type" => "content_block_start", "index" => 0, "content_block" => Dict("type" => "thinking", "thinking" => "thought", "signature" => "signed")), Dict("type" => "content_block_stop", "index" => 0), Dict("type" => "content_block_start", "index" => 1, "content_block" => Dict("type" => "text", "text" => "answer")), Dict("type" => "content_block_stop", "index" => 1), Dict("type" => "message_delta", "delta" => Dict("stop_reason" => "end_turn")), Dict("type" => "message_stop")]
        HTTP.Response(200, ["Content-Type" => "text/event-stream"], join("data: $(JSON3.write(event))\n\n" for event in events))
    end
    try
        mktempdir() do workspace
            base = "http://$(HTTP.server_addr(server))"
            id = "claude-sonnet-4-5"
            if haskey(ENV, "PI_SOURCE")
                @test readchomp(`git -C $(ENV["PI_SOURCE"]) rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
            end
            for (level, budget) in (("off", 0), ("minimal", 1024), ("low", 2048), ("medium", 8192), ("high", 16384), ("xhigh", 16384), ("max", 16384))
                provider = JuliaForever.applythinking(Anthropic(base * "/anthropic", id, "synthetic-anthropic-secret"), level)
                result = JuliaForever.stream(provider, [Dict{String, Any}("role" => "user", "content" => "hello")], Dict())
                @test result.done && isready(requests)
                if isready(requests)
                    request = take!(requests)
                    @test request.key == "synthetic-anthropic-secret"
                    @test request.body["max_tokens"] == 64000
                    @test get(request.body, "thinking", nothing) == (budget == 0 ? Dict("type" => "disabled") : Dict("type" => "enabled", "budget_tokens" => budget, "display" => "summarized"))
                    @test request.beta == (budget == 0 ? "" : "interleaved-thinking-2025-05-14")
                    if haskey(ENV, "PI_SOURCE")
                        pi = JSON3.read(read(`node $(joinpath(@__DIR__, "anthropic_thinking_pi.mjs")) $(ENV["PI_SOURCE"]) $id $level`, String), Dict{String, Any})
                        @test get(request.body, "thinking", nothing) == get(pi["body"], "thinking", nothing)
                        @test request.body["max_tokens"] == pi["body"]["max_tokens"]
                        @test request.beta == get(pi["headers"], "anthropic-beta", "")
                    end
                end
            end
            direct = JuliaForever.applythinking(Anthropic(base, id, "synthetic"), "high")
            switched = JuliaForever.modelchange(direct, "claude-haiku-4-5", direct.route)
            @test switched.model == "claude-haiku-4-5" && switched.key == direct.key
            @test JSON3.read(JuliaForever.payload(switched, [Dict{String, Any}("role" => "user", "content" => "hello")], Dict(), Dict()), Dict{String, Any})["thinking"]["budget_tokens"] == 16384
            @test JuliaForever.modelchange(direct, "claude-opus-4-6", direct.route) == 2
            @test JuliaForever.applythinking(Anthropic(base, id, "sk-ant-oat-synthetic"), "high") == 2
            capped = JSON3.read(JuliaForever.payload(direct, [Dict{String, Any}("role" => "user", "content" => "hello")], Dict(), Dict("max_tokens" => 4096, "temperature" => 0.5); streaming=true), Dict{String, Any})
            @test capped["max_tokens"] == 20480 && !haskey(capped, "temperature")
            if haskey(ENV, "PI_SOURCE")
                pi = JSON3.read(read(`node $(joinpath(@__DIR__, "anthropic_thinking_pi.mjs")) $(ENV["PI_SOURCE"]) $id high 4096`, String), Dict{String, Any})
                @test capped["max_tokens"] == pi["body"]["max_tokens"] && capped["thinking"] == pi["body"]["thinking"]
            end
            for model in ("anthropic/claude-opus-4-6:high", "anthropic/unknown:high")
                result = models_process(base, workspace, ["--model", model, "hello"])
                @test result.status == 2 && !isready(requests)
            end
            result = models_process(base, workspace, ["--model", "anthropic/$id:high", "--no-session"]; input="first\n/model claude-opus-4-6\nsecond\n/exit\n")
            @test result.status == 2
            @test isready(requests)
            first = isready(requests) ? take!(requests) : nothing
            @test isready(requests)
            second = isready(requests) ? take!(requests) : nothing
            if first !== nothing && second !== nothing
                @test first.body["model"] == second.body["model"] == id
                @test second.body["messages"][2]["content"][1] == Dict("type" => "thinking", "thinking" => "thought", "signature" => "signed")
                if haskey(ENV, "PI_SOURCE")
                    pi = JSON3.read(read(`node $(joinpath(@__DIR__, "anthropic_thinking_pi.mjs")) $(ENV["PI_SOURCE"]) $id high 64000 replay`, String), Dict{String, Any})
                    @test second.body["messages"][2]["content"] == pi["body"]["messages"][2]["content"]
                end
            end
            @test !occursin("synthetic-anthropic-secret", result.output * result.diagnostics)
            mkpath(joinpath(workspace, "pi-agent"))
            write(joinpath(workspace, "pi-agent", "models.json"), JSON3.write(Dict("providers" => Dict("anthropic" => Dict("modelOverrides" => Dict(id => Dict("maxTokens" => 1000)))))))
            configured = models_process(base, workspace, ["--model", "anthropic/$id:high", "hello"])
            @test configured.status == 2 && !isready(requests)
        end
    finally
        close(server); wait(server)
    end
end
