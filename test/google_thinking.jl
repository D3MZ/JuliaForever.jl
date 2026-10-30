using Test, JuliaForever, HTTP, JSON3
isdefined(Main, :models_process) || include_string(Main, first(split(read(joinpath(@__DIR__, "terminal_models.jl"), String), "@testset")), joinpath(@__DIR__, "terminal_models.jl"))

@testset "Google thinking suffixes" begin
    requests = []
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        push!(requests, (; target=request.target, key=HTTP.header(request, "x-goog-api-key"), body=JSON3.read(String(request.body), Dict{String, Any})))
        event = Dict("candidates" => [Dict("content" => Dict("parts" => [Dict("thought" => true, "text" => "thought", "thoughtSignature" => "c2ln"), Dict("text" => "ok")]), "finishReason" => "STOP")])
        HTTP.Response(200, ["Content-Type" => "text/event-stream"], "data: $(JSON3.write(event))\n\n")
    end
    try
        mktempdir() do workspace
            base = "http://$(HTTP.server_addr(server))"
            for (id, levels) in (("gemini-3-flash-preview", ("off", "minimal", "low", "medium", "high")), ("gemini-3.1-pro-preview", ("off", "low", "medium", "high")))
                for level in levels
                    result = models_process(base, workspace, ["--model", "google/$id:$level", "hello"])
                    @test result.status == 0
                    body = requests[end].body
                    expected = Dict("includeThoughts" => true, "thinkingLevel" => level == "off" ? (id == "gemini-3-flash-preview" ? "MINIMAL" : "LOW") : uppercase(level))
                    @test body["generationConfig"]["thinkingConfig"] == expected
                    @test requests[end].key == "synthetic-google-secret" && occursin("/models/$id:", requests[end].target)
                    if haskey(ENV, "PI_SOURCE")
                        source = ENV["PI_SOURCE"]
                        @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
                        reference = JSON3.read(read(`node $(joinpath(@__DIR__, "google_thinking_pi.mjs")) $source $id $level`, String), Dict{String, Any})
                        @test body["generationConfig"]["thinkingConfig"] == reference["generationConfig"]["thinkingConfig"]
                    end
                end
            end
            for (id, level, expected) in (("gemini-2.5-pro", "high", Dict("includeThoughts" => true, "thinkingBudget" => 32768)), ("gemini-2.5-flash-lite", "off", Dict("thinkingBudget" => 0)))
                selected = models_process(base, workspace, ["--model", "google/$id:$level", "hello"])
                @test selected.status == 0
                @test requests[end].body["generationConfig"]["thinkingConfig"] == expected
            end
            default = models_process(base, workspace, ["--model", "google/gemini-2.5-flash", "hello"])
            @test default.status == 0 && !haskey(get(requests[end].body, "generationConfig", Dict()), "thinkingConfig")
            before = length(requests)
            for id in ("google/gemini-2.5-pro:xhigh", "google/gemini-3.1-pro-preview:minimal", "google/gemini-3-flash-preview:xhigh")
                result = models_process(base, workspace, ["--model", id, "hello"])
                @test result.status == 2 && occursin("Thinking", result.diagnostics)
            end
            @test length(requests) == before
            switched = models_process(base, workspace, ["--model", "google/gemini-3-flash-preview:high", "--no-session"]; input="first\nsecond\n/model gemini-3.1-pro-preview\nthird\n/model gemini-2.5-pro\nfourth\n/exit\n")
            @test switched.status == 0
            @test length(requests) == before + 4
            @test all(r -> r.key == "synthetic-google-secret", requests[end-3:end])
            @test all(r -> r.body["generationConfig"]["thinkingConfig"]["thinkingLevel"] == "HIGH", requests[end-3:end-1])
            @test requests[end].body["generationConfig"]["thinkingConfig"] == Dict("includeThoughts" => true, "thinkingBudget" => 32768)
            @test requests[end-2].body["contents"][2]["parts"][1]["thoughtSignature"] == "c2ln"
            @test !haskey(requests[end-1].body["contents"][2]["parts"][1], "thoughtSignature")
            before = length(requests)
            switchedoff = models_process(base, workspace, ["--model", "google/gemini-3-flash-preview:off", "--no-session"]; input="first\n/model gemini-3.1-pro-preview\nsecond\n/exit\n")
            @test switchedoff.status == 0
            @test length(requests) == before + 2
            @test requests[end].body["generationConfig"]["thinkingConfig"] == Dict("includeThoughts" => true, "thinkingLevel" => "LOW")
            commands = [(; id="state", type="get_state"), (; id="levels", type="get_available_thinking_levels"), (; id="low", type="set_thinking_level", level="low"), (; id="after", type="get_state")]
            rpc = models_process(base, workspace, ["--mode", "rpc", "--no-session", "--model", "google/gemini-3-flash-preview:high"]; input=join(JSON3.write.(commands), "\n") * "\n")
            responses = Dict(item["id"] => item for item in (JSON3.read(line, Dict{String, Any}) for line in split(strip(rpc.output), '\n')) if haskey(item, "id"))
            @test responses["state"]["data"]["thinkingLevel"] == "high"
            @test responses["levels"]["data"]["levels"] == ["minimal", "low", "medium", "high"]
            @test responses["after"]["data"]["thinkingLevel"] == "low"
            off = models_process(base, workspace, ["--mode", "rpc", "--no-session", "--model", "google/gemini-3-flash-preview:off"]; input=JSON3.write((; id="state", type="get_state")) * "\n")
            offstate = only(JSON3.read(line, Dict{String, Any}) for line in split(strip(off.output), '\n') if occursin("\"id\":\"state\"", line))
            @test offstate["data"]["thinkingLevel"] == "minimal"
            mkpath(joinpath(workspace, "pi-agent"))
            write(joinpath(workspace, "pi-agent", "models.json"), JSON3.write(Dict("providers" => Dict("google" => Dict("modelOverrides" => Dict("gemini-3-flash-preview" => Dict("reasoning" => true), "gemini-2.5-pro" => Dict("reasoning" => true)))))))
            before = length(requests)
            @test models_process(base, workspace, ["--model", "google/gemini-3-flash-preview:high", "hello"]).status == 2
            @test models_process(base, workspace, ["--model", "google/gemini-2.5-pro:high", "hello"]).status == 2
            @test length(requests) == before
        end
    finally
        close(server)
        wait(server)
    end
end
