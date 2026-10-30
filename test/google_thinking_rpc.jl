module GoogleThinkingRPC

using Test, JuliaForever, HTTP, JSON3

function receive!(channel, predicate)
    while true
        timedwait(() -> isready(channel), 45) == :ok || error("Timed out waiting for Gemini RPC output")
        record = take!(channel)
        predicate(record) && return record
    end
end

function exchange(cmd, env; modelchange=false, initialonly=false)
    mktempdir() do dir
        diagnostics = joinpath(dir, "error")
        process = open(pipeline(addenv(cmd, env...); stderr=diagnostics), "r+")
        output = Channel{Any}(Inf)
        observed = Any[]
        reader = @async for line in eachline(process)
            push!(observed, line)
            put!(output, JSON3.read(line, Dict{String, Any}))
        end
        try
            send(value) = (println(process, JSON3.write(value)); flush(process))
            response(id) = receive!(output, value -> get(value, "id", "") == id)
            prompt(id, message) = (send((; id, type="prompt", message)); receive!(output, value -> get(value, "type", "") == "agent_settled"))
            send((; id="state", type="get_state"))
            state = response("state")
            send((; id="levels", type="get_available_thinking_levels"))
            levels = response("levels")
            prompt("first", "first")
            initialonly && return (; state, levels, observed, diagnostics=read(diagnostics, String))
            send((; id="low", type="set_thinking_level", level="low"))
            low = response("low")
            prompt("second", "second")
            send((; id="recorded", type="get_state"))
            recorded = response("recorded")
            rejected = if modelchange
                send((; id="model", type="set_model", provider="google", modelId="gemini-3.1-pro-preview"))
                response("model")
            else
                nothing
            end
            send((; id="new", type="new_session"))
            new = response("new")
            send((; id="newstate", type="get_state"))
            newstate = response("newstate")
            send((; id="switch", type="switch_session", sessionPath=recorded["data"]["sessionFile"]))
            switched = response("switch")
            send((; id="restored", type="get_state"))
            restored = response("restored")
            prompt("third", "third")
            (; state, levels, low, recorded, rejected, new, newstate, switched, restored, observed, diagnostics=read(diagnostics, String))
        finally
            close(process.in)
            timedwait(() -> process_exited(process), 5) == :ok || kill(process)
            wait(process)
            wait(reader)
            success(process) || error("RPC subprocess failed: $(read(diagnostics, String))")
        end
    end
end

function environment(workspace, agentdir, base)
    ["HOME" => workspace, "USERPROFILE" => workspace, "PI_CODING_AGENT_DIR" => agentdir, "PI_OFFLINE" => "1", "JF_CHATGPT_DIR" => joinpath(workspace, "chatgpt"), "JF_OPENROUTER_DIR" => joinpath(workspace, "router"), "JF_INSTRUCTIONS_DIR" => workspace, "JF_PROVIDER" => "google", "GEMINI_API_KEY" => "synthetic-google-rpc-key", "GEMINI_BASE_URL" => base, "OPENAI_API_KEY" => "synthetic-unrelated-openai", "OPENROUTER_API_KEY" => nothing, "ANTHROPIC_API_KEY" => nothing, "TERM" => "dumb"]
end

@testset "Gemini RPC selection, thinking and session replay" begin
    requests = Any[]
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        push!(requests, (; target=request.target, key=HTTP.header(request, "x-goog-api-key", ""), authorization=HTTP.header(request, "authorization", ""), body=JSON3.read(String(request.body), Dict{String, Any})))
        event = Dict("candidates" => [Dict("content" => Dict("parts" => [Dict("thought" => true, "text" => "thought", "thoughtSignature" => "c2ln"), Dict("text" => "answer")]), "finishReason" => "STOP")])
        HTTP.Response(200, ["Content-Type" => "text/event-stream"], "data: $(JSON3.write(event))\n\n")
    end
    try
        mktempdir() do workspace
            base = "http://$(HTTP.server_addr(server))/google"
            project = dirname(@__DIR__)
            id = "gemini-3-flash-preview"
            jfagent = joinpath(workspace, "jf-agent")
            jf = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project -m JuliaForever --mode rpc --session-dir $(joinpath(workspace, "jf-sessions")) --model google/$id`; dir=workspace)
            actual = exchange(jf, environment(workspace, jfagent, base); modelchange=true)
            captured = copy(requests)
            @test length(captured) == 3
            @test actual.state["data"]["model"]["id"] == id
            @test actual.state["data"]["thinkingLevel"] == "medium"
            @test actual.levels["data"]["levels"] == ["minimal", "low", "medium", "high"]
            @test actual.low["success"] && actual.new["success"] && actual.switched["success"]
            @test !actual.rejected["success"]
            @test actual.restored["data"]["thinkingLevel"] == "low"
            @test all(r -> r.target == "/google/models/$id:streamGenerateContent?alt=sse" && r.key == "synthetic-google-rpc-key" && isempty(r.authorization), captured)
            @test [r.body["generationConfig"]["thinkingConfig"] for r in captured] == [Dict("includeThoughts" => true, "thinkingLevel" => level) for level in ("MEDIUM", "LOW", "LOW")]
            @test captured[2].body["contents"][2]["parts"][1]["thoughtSignature"] == "c2ln"
            @test captured[3].body["contents"][2]["parts"][1]["thoughtSignature"] == "c2ln"
            @test all(secret -> all(line -> !occursin(secret, line), actual.observed), ("synthetic-google-rpc-key", "synthetic-unrelated-openai"))
            @test all(secret -> !occursin(secret, actual.diagnostics), ("synthetic-google-rpc-key", "synthetic-unrelated-openai"))
            @test all(secret -> !occursin(secret, String(read(actual.recorded["data"]["sessionFile"]))), ("synthetic-google-rpc-key", "synthetic-unrelated-openai"))

            if haskey(ENV, "PI_SOURCE")
                source = ENV["PI_SOURCE"]
                @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
                piagent = joinpath(workspace, "pi-agent")
                mkpath(piagent)
                write(joinpath(piagent, "models.json"), JSON3.write((; providers=(; google=(; baseUrl=base)))))
                pi = Cmd(`node $(joinpath(@__DIR__, "headless_reference.mjs")) $source --mode rpc --session-dir $(joinpath(workspace, "pi-sessions")) --model google/$id --approve`; dir=workspace)
                reference = exchange(pi, environment(workspace, piagent, base))
                picaptured = requests[length(captured)+1:end]
                @test length(picaptured) == 3
                @test [r.body["generationConfig"]["thinkingConfig"] for r in captured] == [r.body["generationConfig"]["thinkingConfig"] for r in picaptured]
                @test [r.body["contents"] for r in captured] == [r.body["contents"] for r in picaptured]
                @test [result["data"]["thinkingLevel"] for result in (actual.state, actual.newstate, actual.restored)] == [result["data"]["thinkingLevel"] for result in (reference.state, reference.newstate, reference.restored)]
                @test actual.levels["data"]["levels"] == reference.levels["data"]["levels"]
                @test all(r -> r.key == "synthetic-google-rpc-key" && isempty(r.authorization), picaptured)
            end

            for (suffix, level, wire) in (("high", "high", "HIGH"), ("off", "minimal", "MINIMAL"))
                selected = "google/$id:$suffix"
                startup = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project -m JuliaForever --mode rpc --no-session --model $selected`; dir=workspace)
                before = length(requests)
                state = exchange(startup, environment(workspace, jfagent, base); initialonly=true)
                @test length(requests) == before + 1
                @test state.state["data"]["thinkingLevel"] == level
                @test requests[end].body["generationConfig"]["thinkingConfig"] == Dict("includeThoughts" => true, "thinkingLevel" => wire)
                @test requests[end].target == "/google/models/$id:streamGenerateContent?alt=sse" && requests[end].key == "synthetic-google-rpc-key"
                if haskey(ENV, "PI_SOURCE")
                    source = ENV["PI_SOURCE"]
                    pi = Cmd(`node $(joinpath(@__DIR__, "headless_reference.mjs")) $source --mode rpc --no-session --model $selected --approve`; dir=workspace)
                    reference = exchange(pi, environment(workspace, joinpath(workspace, "pi-agent"), base); initialonly=true)
                    @test reference.state["data"]["thinkingLevel"] == level
                    @test requests[end-1].body["generationConfig"]["thinkingConfig"] == requests[end].body["generationConfig"]["thinkingConfig"]
                end
            end
        end
    finally
        close(server)
        wait(server)
    end
end

function runcli(cmd, env, input)
    mktempdir() do dir
        stdin, stdout, stderr = joinpath.((dir,), ("stdin", "stdout", "stderr"))
        write(stdin, input)
        process = run(pipeline(ignorestatus(addenv(cmd, env...)); stdin, stdout, stderr))
        (; status=process.exitcode, output=read(stdout, String), diagnostics=read(stderr, String))
    end
end

@testset "configured Gemini routes and unsupported thinking" begin
    requests = Any[]
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        push!(requests, (; target=request.target, key=HTTP.header(request, "x-goog-api-key", ""), route=HTTP.header(request, "x-model-route", ""), authorization=HTTP.header(request, "authorization", ""), body=JSON3.read(String(request.body), Dict{String, Any})))
        event = Dict("candidates" => [Dict("content" => Dict("parts" => [Dict("thought" => true, "text" => "thought", "thoughtSignature" => "c2ln"), Dict("text" => "answer")]), "finishReason" => "STOP")])
        HTTP.Response(200, ["Content-Type" => "text/event-stream"], "data: $(JSON3.write(event))\n\n")
    end
    try
        mktempdir() do workspace
            base = "http://$(HTTP.server_addr(server))"
            agentdir = joinpath(workspace, "agent")
            mkpath(agentdir)
            models = [(; id="gemini-3-flash-preview", reasoning=true, baseUrl=base * "/a", headers=Dict("x-model-route" => "route-a")), (; id="gemini-3.1-pro-preview", reasoning=true, baseUrl=base * "/b", headers=Dict("x-model-route" => "route-b"))]
            config = JSON3.write((; providers=(; fixture=(; api="google-generative-ai", baseUrl=base * "/unused", apiKey="synthetic-config-key", models))))
            write(joinpath(agentdir, "models.json"), config)
            project = dirname(@__DIR__)
            env = environment(workspace, agentdir, base * "/unrelated")
            model = "fixture/gemini-3-flash-preview"
            jf = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project -m JuliaForever --mode rpc --session-dir $(joinpath(workspace, "sessions")) --model $model`; dir=workspace)
            actual = exchange(jf, env; modelchange=true)
            captured = copy(requests)
            @test length(captured) == 3
            @test actual.state["data"]["model"]["id"] == "gemini-3-flash-preview"
            @test actual.levels["data"]["levels"] == ["off"]
            @test actual.low["success"] && actual.restored["data"]["thinkingLevel"] == "off"
            @test !actual.rejected["success"]
            @test all(r -> r.target == "/a/models/gemini-3-flash-preview:streamGenerateContent?alt=sse" && r.key == "synthetic-config-key" && r.route == "route-a" && isempty(r.authorization), captured)
            @test all(r -> !haskey(get(r.body, "generationConfig", Dict()), "thinkingConfig"), captured)
            @test all(secret -> all(line -> !occursin(secret, line), actual.observed), ("synthetic-config-key", "synthetic-google-rpc-key", "synthetic-unrelated-openai"))
            @test all(secret -> !occursin(secret, actual.diagnostics), ("synthetic-config-key", "synthetic-google-rpc-key", "synthetic-unrelated-openai"))

            if haskey(ENV, "PI_SOURCE")
                source = ENV["PI_SOURCE"]
                piagent = joinpath(workspace, "pi-agent")
                mkpath(piagent)
                write(joinpath(piagent, "models.json"), config)
                pi = Cmd(`node $(joinpath(@__DIR__, "headless_reference.mjs")) $source --mode rpc --session-dir $(joinpath(workspace, "pi-sessions")) --model $model --approve`; dir=workspace)
                reference = exchange(pi, environment(workspace, piagent, base * "/unrelated"))
                picaptured = requests[length(captured)+1:end]
                @test length(picaptured) == 3
                @test all(r -> r.target == "/a/models/gemini-3-flash-preview:streamGenerateContent?alt=sse" && r.key == "synthetic-config-key" && r.route == "route-a" && isempty(r.authorization), picaptured)
                @test [r.body["generationConfig"]["thinkingConfig"]["thinkingLevel"] for r in picaptured] == ["MEDIUM", "LOW", "LOW"]
                @test "low" in reference.levels["data"]["levels"]
            end

            before = length(requests)
            cli = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project -m JuliaForever --model $model --no-session`; dir=workspace)
            switched = runcli(cli, env, "first\n/model gemini-3.1-pro-preview\nsecond\n/exit\n")
            @test switched.status == 0 && length(requests) == before + 2
            if length(requests) == before + 2
                @test [(r.target, r.key, r.route, r.authorization) for r in requests[before+1:end]] == [("/a/models/gemini-3-flash-preview:streamGenerateContent?alt=sse", "synthetic-config-key", "route-a", ""), ("/b/models/gemini-3.1-pro-preview:streamGenerateContent?alt=sse", "synthetic-config-key", "route-b", "")]
                @test !haskey(requests[end].body["contents"][2]["parts"][1], "thoughtSignature")
            end
            rejected = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project -m JuliaForever --model $(model * ":high") --no-session hello`; dir=workspace)
            count = length(requests)
            result = runcli(rejected, env, "")
            @test result.status == 2 && occursin("Thinking", result.diagnostics) && length(requests) == count
            @test all(secret -> !occursin(secret, switched.output * switched.diagnostics * result.output * result.diagnostics), ("synthetic-config-key", "synthetic-google-rpc-key", "synthetic-unrelated-openai"))

            provider = JuliaForever.applythinking(Google(base * "/direct", "gemini-3-flash-preview", "synthetic-direct-key"), "high")
            config = Dict{String, Any}("temperature" => 0.25, "thinkingConfig" => Dict("thinkingBudget" => 9))
            parameters = Dict("generationConfig" => deepcopy(config))
            message = [Dict("role" => "user", "content" => "hello")]
            @test JuliaForever.stream(provider, message, Dict(); parameters).done
            @test parameters["generationConfig"] == config
            @test requests[end].body["generationConfig"] == Dict("temperature" => 0.25, "thinkingConfig" => Dict("includeThoughts" => true, "thinkingLevel" => "HIGH"))
            named = (generationConfig=(temperature=0.5,),)
            @test JuliaForever.stream(provider, message, Dict(); parameters=named).done
            @test requests[end].body["generationConfig"] == Dict("temperature" => 0.5, "thinkingConfig" => Dict("includeThoughts" => true, "thinkingLevel" => "HIGH"))
            homogeneous = Dict("generationConfig" => Dict("temperature" => 0.75))
            @test JuliaForever.stream(provider, message, Dict(); parameters=homogeneous).done
            @test homogeneous == Dict("generationConfig" => Dict("temperature" => 0.75))
            @test requests[end].body["generationConfig"] == Dict("temperature" => 0.75, "thinkingConfig" => Dict("includeThoughts" => true, "thinkingLevel" => "HIGH"))
        end
    finally
        close(server)
        wait(server)
    end
end

end
