module ThinkingUpdate

using Test, JuliaForever, HTTP, JSON3
isdefined(Main, :models_process) || include_string(Main, first(split(read(joinpath(@__DIR__, "terminal_models.jl"), String), "@testset")), joinpath(@__DIR__, "terminal_models.jl"))

update(effort) = Dict("type" => "configuration_update", "reasoning" => Dict("effort" => effort))
updates(body) = filter(item -> get(item, "type", nothing) == "configuration_update", body["input"])

function reference(steps)
    source = ENV["PI_SOURCE"]
    @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
    script = joinpath(@__DIR__, "thinking_update_pi.mjs")
    JSON3.read(read(`node $script $source $(JSON3.write(steps))`), Vector{Dict{String, Any}})
end

@testset "GPT-6 Responses thinking across requests and replay" begin
    requests = []
    toolrequests = Ref(0)
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        body = JSON3.read(String(request.body), Dict{String, Any})
        push!(requests, (; target=request.target, authorization=HTTP.header(request, "Authorization", ""), body))
        if !get(body, "stream", false)
            toolrequests[] += 1
            item = toolrequests[] == 1 ? Dict("type" => "function_call", "id" => "fc_1", "call_id" => "call_1", "name" => "write", "arguments" => JSON3.write(Dict("path" => "made.txt", "content" => "created")), "status" => "completed") : Dict("type" => "message", "content" => [Dict("type" => "output_text", "text" => "fixture")])
            return HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write(Dict("status" => "completed", "output" => [item])))
        end
        output = [Dict("type" => "message", "id" => "msg_$(length(requests))", "role" => "assistant", "status" => "completed", "content" => [Dict("type" => "output_text", "text" => "fixture", "annotations" => [])])]
        delta = JSON3.write((; type="response.output_text.delta", delta="fixture"))
        done = JSON3.write((; type="response.completed", response=(; status="completed", output)))
        HTTP.Response(200, ["Content-Type" => "text/event-stream"], "data: $delta\n\ndata: $done\n\n")
    end
    try
        mktempdir() do workspace
            base = "http://$(HTTP.server_addr(server))"
            steps = [(; model="gpt-6-luna", level="high"), (; model="gpt-6-luna", level="low"), (; model="gpt-6-sol", level="high"), (; model="gpt-6-luna", level="xhigh")]
            pi = haskey(ENV, "PI_SOURCE") ? reference(steps) : nothing
            if !isnothing(pi)
                @test [item["updates"] for item in pi] == [[update("high")], [update("high"), update("low")], [update("high")], [update("high"), update("low"), update("xhigh")]]
                @test all(item -> item["reasoning"] == Dict("effort" => "medium", "summary" => "auto"), pi)
            end
            input = "first\n/model gpt-6-luna:low\nsecond\n/model gpt-6-sol:high\nthird\n/model gpt-6-luna:xhigh\nfourth\n/exit\n"
            run = Main.models_process(base, workspace, ["--model", "openai/gpt-6-luna:high", "--no-session"]; input)
            @test run.status == 0 && length(requests) == 4
            @test !occursin("synthetic-openai-secret", run.output * run.diagnostics)
            if length(requests) == 4
                bodies = [request.body for request in requests]
                @test [body["model"] for body in bodies] == [step.model for step in steps]
                @test [updates(body) for body in bodies] == [[update("high")], [update("high"), update("low")], [update("high")], [update("high"), update("low"), update("xhigh")]]
                @test all(body -> body["reasoning"] == Dict("effort" => "medium", "summary" => "auto"), bodies)
                @test bodies[2]["input"][1:length(bodies[1]["input"])] == bodies[1]["input"]
                @test all(request -> request.target == "/openai/responses" && request.authorization == "Bearer synthetic-openai-secret", requests)
                if !isnothing(pi)
                    @test [updates(body) for body in bodies] == [item["updates"] for item in pi]
                    @test [body["reasoning"] for body in bodies] == [item["reasoning"] for item in pi]
                end
            end

            before = length(requests)
            history = joinpath(workspace, "thinking.sqlite")
            first = Main.models_process(base, workspace, ["--history", history, "--model", "openai/gpt-6-luna:high", "recorded"]; openai_key="synthetic-old-key")
            second = Main.models_process(base, workspace, ["--history", history, "--model", "openai/gpt-6-luna:low", "resumed"]; openai_key="synthetic-new-key")
            @test first.status == 0 && second.status == 0 && length(requests) == before + 2
            @test all(key -> !occursin(key, first.output * first.diagnostics * second.output * second.diagnostics), ("synthetic-old-key", "synthetic-new-key"))
            if length(requests) == before + 2
                recorded, resumed = requests[end-1].body, requests[end].body
                @test updates(recorded) == [update("high")]
                @test updates(resumed) == [update("high"), update("low")]
                @test resumed["input"][1:length(recorded["input"])] == recorded["input"]
                @test recorded["reasoning"] == resumed["reasoning"] == Dict("effort" => "medium", "summary" => "auto")
                @test (requests[end-1].authorization, requests[end].authorization) == ("Bearer synthetic-old-key", "Bearer synthetic-new-key")
                @test all(key -> !occursin(key, String(read(history))), ("synthetic-old-key", "synthetic-new-key"))
                if !isnothing(pi)
                    @test [updates(recorded), updates(resumed)] == [pi[1]["updates"], pi[2]["updates"]]
                end
            end

            before = length(requests)
            offsteps = [(; model="gpt-6-luna", level="off"), (; model="gpt-6-luna", level="low"), (; model="gpt-6-luna", level="off"), (; model="gpt-6-luna", level="high")]
            offinput = "one\n/model gpt-6-luna:low\ntwo\n/model gpt-6-luna:off\nthree\n/model gpt-6-luna:high\nfour\n/exit\n"
            offrun = Main.models_process(base, workspace, ["--model", "openai/gpt-6-luna:off", "--no-session"]; input=offinput)
            @test offrun.status == 0 && length(requests) == before + 4
            if length(requests) == before + 4
                bodies = [request.body for request in requests[before+1:end]]
                @test [updates(body) for body in bodies] == [[], [update("low")], [], [update("low"), update("high")]]
                @test [body["reasoning"]["effort"] for body in bodies] == ["none", "medium", "none", "medium"]
                if haskey(ENV, "PI_SOURCE")
                    offpi = reference(offsteps)
                    @test [updates(body) for body in bodies] == [item["updates"] for item in offpi]
                    @test [body["reasoning"] for body in bodies] == [item["reasoning"] for item in offpi]
                end
            end

            before = length(requests)
            provider = JuliaForever.applythinking(OpenAIResponses(base * "/openai", "gpt-6-luna", "synthetic-openai-secret"), "high")
            @test provider isa OpenAIResponses
            if provider isa OpenAIResponses
                agent = Agent(provider, [Write(workspace)])
                switch = event -> begin
                    event.type == :tool_execution_end || return nothing
                    lock(agent.lock) do
                        agent.provider = JuliaForever.applythinking(agent.provider, "low")
                    end
                    nothing
                end
                @test respond!(agent, "write"; on_agent_event=switch) == "fixture"
                @test read(joinpath(workspace, "made.txt"), String) == "created"
                @test length(requests) == before + 2
                if length(requests) == before + 2
                    firsttool, aftertool = requests[end-1].body, requests[end].body
                    @test updates(firsttool) == [update("high")]
                    @test updates(aftertool) == [update("high"), update("low")]
                    @test aftertool["input"][1:length(firsttool["input"])] == firsttool["input"]
                    @test aftertool["input"][end-1]["type"] == "function_call_output"
                    if haskey(ENV, "PI_SOURCE")
                        toolpi = reference([(model="gpt-6-luna", level="high", tool=true), (model="gpt-6-luna", level="low", toolResult=true)])
                        @test updates(aftertool) == toolpi[2]["updates"]
                    end
                end
            end

            signin = OpenAIResponses("https://api.openai.com/v1", "gpt-6-luna", "synthetic-access-token")
            @test JuliaForever.applythinking(signin, "high") == 2
            @test JuliaForever.applythinking(signin, "none") isa OpenAIResponses
            for url in ("https://api.openai.com/v1/", "https://API.OPENAI.COM:443/v1")
                alternate = OpenAIResponses(url, "gpt-6-luna", "synthetic-access-token")
                @test JuliaForever.applythinking(alternate, "high") == 2
            end
            earlier = JuliaForever.applythinking(OpenAIResponses("https://api.openai.com/v1", "gpt-5.2", "synthetic-access-token"), "high")
            @test JuliaForever.modelchange(earlier, "gpt-6-luna", earlier.route) == 2
            @test !occursin("synthetic-access-token", repr(signin))
            overridden = OpenAIResponses("https://api.openai.com/v1", "gpt-6-luna", "sk-synthetic", ["Authorization" => "Bearer synthetic-access-token"])
            @test JuliaForever.applythinking(overridden, "high") == 2
            registry = JuliaForever.Models.Registry(JuliaForever.Models.catalog(), Dict{String, Any}())
            routed = OpenAIResponses(base * "/openai", "gpt-6-luna", "synthetic-openai-secret", Pair{String, String}[], JuliaForever.CatalogRoute("openai", registry), nothing)
            @test JuliaForever.applythinking(routed, "high") == 2

            before = length(requests)
            for model in ("openai/gpt-6-luna:minimal", "openai/gpt-6-astra:off")
                invalid = Main.models_process(base, workspace, ["--model", model, "hello"])
                @test invalid.status == 2 && length(requests) == before
            end
            agentdir = joinpath(workspace, "pi-agent")
            mkpath(agentdir)
            write(joinpath(agentdir, "models.json"), JSON3.write(Dict("providers" => Dict("openai" => Dict("baseUrl" => base * "/openai", "apiKey" => "configured-secret")))))
            configured = Main.models_process(base, workspace, ["--model", "openai/gpt-6-luna:high", "hello"])
            @test configured.status == 2 && length(requests) == before
            @test !occursin("configured-secret", configured.output * configured.diagnostics)
        end
    finally
        close(server)
        wait(server)
    end
end

end
