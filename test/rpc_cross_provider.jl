module RPCCrossProviderTests

using Test, JuliaForever, JSON3, HTTP

function fixtureenv(pairs)
    env = Dict("PATH" => ENV["PATH"], "JULIA_DEPOT_PATH" => join(DEPOT_PATH, Sys.iswindows() ? ';' : ':'), "JULIA_NUM_THREADS" => "4")
    for key in ("SystemRoot", "WINDIR", "COMSPEC", "PATHEXT", "TMP", "TEMP", "TMPDIR", "PI_SOURCE")
        haskey(ENV, key) && (env[key] = ENV[key])
    end
    for (key, value) in pairs
        isnothing(value) || (env[key] = value)
    end
    env
end

function receive!(output, observed, predicate)
    while true
        timedwait(() -> isready(output), 60) == :ok || error("Timed out waiting for RPC")
        record = take!(output)
        push!(observed, record)
        predicate(record) && return record
    end
end

function exchange(cmd, env; checkbad=false)
    mktempdir() do dir
        diagnostics = joinpath(dir, "diagnostics")
        process = open(pipeline(setenv(cmd, fixtureenv(env)); stderr=diagnostics), "r+")
        output = Channel{Any}(Inf)
        observed = Any[]
        reader = @async for line in eachline(process)
            put!(output, JSON3.read(line, Dict{String, Any}))
        end
        try
            send(value) = (println(process, JSON3.write(value)); flush(process))
            reply(id) = receive!(output, observed, value -> get(value, "id", "") == id)
            command(value) = (send(value); reply(value.id))
            prompt(id, message) = (send((; id, type="prompt", message)); receive!(output, observed, value -> get(value, "type", "") == "agent_settled"))
            prompt("start", "first message")
            start = command((; id="start-state", type="get_state"))
            queued = command((; id="queue", type="steer", message="queued message"))
            switched = command((; id="responses", type="set_model", provider="fixture", modelId="responses"))
            response_state = command((; id="responses-state", type="get_state"))
            cleared = command((; id="clear", type="clear_queue"))
            prompt("responses-prompt", "second message")
            anthropic = command((; id="anthropic", type="set_model", provider="other", modelId="anthropic-model"))
            anthropic_state = command((; id="anthropic-state", type="get_state"))
            prompt("anthropic-prompt", "third message")
            google = command((; id="google", type="set_model", provider="third", modelId="google-model"))
            google_state = command((; id="google-state", type="get_state"))
            before = command((; id="before-failure", type="get_entries"))
            failed = command((; id="failed", type="set_model", provider="missing", modelId="missing"))
            bad = checkbad ? command((; id="bad", type="set_model", provider="bad", modelId="bad-model")) : nothing
            after = command((; id="after-failure", type="get_entries"))
            final_state = command((; id="final-state", type="get_state"))
            prompt("google-prompt", "fourth message")
            saved = command((; id="saved", type="get_state"))
            (; start, queued, switched, response_state, cleared, anthropic, anthropic_state, google, google_state, before, failed, bad, after, final_state, saved, observed, diagnostics=read(diagnostics, String))
        finally
            close(process.in)
            timedwait(() -> process_exited(process), 10) == :ok || kill(process)
            wait(process)
            wait(reader)
            success(process) || error("RPC subprocess failed: $(read(diagnostics, String))")
        end
    end
end

function fixture(base)
    definition(id; api=nothing, path=nothing, headers=nothing) = merge((; id, name=id, input=["text"], reasoning=false, contextWindow=10000, maxTokens=1000), isnothing(api) ? NamedTuple() : (; api), isnothing(path) ? NamedTuple() : (; baseUrl=base * path), isnothing(headers) ? NamedTuple() : (; headers))
    first = (; baseUrl=base * "/chat", api="openai-completions", apiKey="synthetic-fixture-key", headers=Dict("x-route" => "fixture-header"), models=[definition("chat"), definition("responses"; api="openai-responses", path="/responses", headers=Dict("x-model" => "responses-header"))])
    (; providers=(;
        fixture=first, openai=first,
        other=(; baseUrl=base * "/anthropic", api="anthropic-messages", apiKey="synthetic-other-key", headers=Dict("x-route" => "other-header"), models=[definition("anthropic-model")]),
        third=(; baseUrl=base * "/google", api="google-generative-ai", apiKey="synthetic-third-key", headers=Dict("x-route" => "third-header"), models=[definition("google-model")]),
        bad=(; baseUrl=base * "/bad", api="openai-completions", apiKey="synthetic-bad-key", headers=Dict("x-bad" => "\$JF_MISSING_HEADER"), models=[definition("bad-model")]),
    ))
end

function reopen(cmd, env; expectprompt=true)
    mktempdir() do dir
        diagnostics = joinpath(dir, "diagnostics")
        process = open(pipeline(setenv(cmd, fixtureenv(env)); stderr=diagnostics), "r+")
        output = Channel{Any}(Inf)
        observed = Any[]
        reader = @async for line in eachline(process)
            put!(output, JSON3.read(line, Dict{String, Any}))
        end
        try
            send(value) = (println(process, JSON3.write(value)); flush(process))
            send((; id="state", type="get_state"))
            state = receive!(output, observed, item -> get(item, "id", "") == "state")
            send((; id="prompt", type="prompt", message="after reopen"))
            prompt = expectprompt ? receive!(output, observed, item -> get(item, "type", "") == "agent_settled") : receive!(output, observed, item -> get(item, "id", "") == "prompt")
            (; state, prompt, observed, diagnostics=read(diagnostics, String))
        finally
            close(process.in)
            timedwait(() -> process_exited(process), 10) == :ok || kill(process)
            wait(process)
            wait(reader)
            success(process) || error("RPC reopen failed: $(read(diagnostics, String))")
        end
    end
end

function failedswitch(cmd, env, target)
    mktempdir() do dir
        diagnostics = joinpath(dir, "diagnostics")
        process = open(pipeline(setenv(cmd, fixtureenv(env)); stderr=diagnostics), "r+")
        output = Channel{Any}(Inf)
        observed = Any[]
        reader = @async for line in eachline(process)
            put!(output, JSON3.read(line, Dict{String, Any}))
        end
        try
            send(value) = (println(process, JSON3.write(value)); flush(process))
            command(value) = (send(value); receive!(output, observed, item -> get(item, "id", "") == value.id))
            send((; id="prompt", type="prompt", message="source remains"))
            receive!(output, observed, item -> get(item, "type", "") == "agent_settled")
            before = command((; id="before", type="get_state"))
            entries = command((; id="entries", type="get_entries"))
            saved = read(target)
            switched = command((; id="switch", type="switch_session", sessionPath=target))
            after = command((; id="after", type="get_state"))
            following = command((; id="following", type="get_entries"))
            (; before, entries, switched, after, following, unchanged=read(target) == saved, observed, diagnostics=read(diagnostics, String))
        finally
            close(process.in)
            timedwait(() -> process_exited(process), 10) == :ok || kill(process)
            wait(process)
            wait(reader)
            success(process) || error("Failed-switch fixture failed: $(read(diagnostics, String))")
        end
    end
end

function thinkingexchange(cmd, env)
    mktempdir() do dir
        diagnostics = joinpath(dir, "diagnostics")
        process = open(pipeline(setenv(cmd, fixtureenv(env)); stderr=diagnostics), "r+")
        output = Channel{Any}(Inf)
        observed = Any[]
        reader = @async for line in eachline(process)
            put!(output, JSON3.read(line, Dict{String, Any}))
        end
        try
            send(value) = (println(process, JSON3.write(value)); flush(process))
            command(value) = (send(value); receive!(output, observed, item -> get(item, "id", "") == value.id))
            prompt(id) = (send((; id, type="prompt", message="thinking fixture")); receive!(output, observed, item -> get(item, "type", "") == "agent_settled"))
            prompt("initial")
            states = [command((; id="initial-state", type="get_state"))]
            replies = Any[]
            for (id, provider, model) in (("google", "google", "gemini-2.5-flash"), ("anthropic", "anthropic", "claude-sonnet-4-5"), ("fixed", "openai", "gpt-4.1"), ("back", "google", "gemini-2.5-flash"))
                push!(replies, command((; id, type="set_model", provider, modelId=model)))
                push!(states, command((; id=id * "-state", type="get_state")))
                prompt(id * "-prompt")
            end
            entries = command((; id="entries", type="get_entries"))
            (; states, replies, entries, observed, diagnostics=read(diagnostics, String))
        finally
            close(process.in)
            timedwait(() -> process_exited(process), 10) == :ok || kill(process)
            wait(process)
            wait(reader)
            success(process) || error("Thinking RPC failed: $(read(diagnostics, String))")
        end
    end
end

function response(request)
    if endswith(request.target, "/responses")
        delta = JSON3.write((; type="response.output_text.delta", delta="answer"))
        done = JSON3.write((; type="response.completed", response=(; status="completed", output=[(; type="message", content=[(; type="output_text", text="answer")])])))
        return "data: $delta\n\ndata: $done\n\n"
    end
    if occursin("/v1/messages", request.target)
        events = [(; type="message_start", message=(; usage=(; input_tokens=10, output_tokens=1))), (; type="content_block_start", index=0, content_block=(; type="text", text="answer")), (; type="content_block_stop", index=0), (; type="message_delta", delta=(; stop_reason="end_turn")), (; type="message_stop")]
        return join("event: $(event.type)\ndata: $(JSON3.write(event))\n\n" for event in events)
    end
    if occursin(":streamGenerateContent", request.target)
        event = (; candidates=[(; content=(; parts=[(; text="answer")]), finishReason="STOP")])
        return "data: $(JSON3.write(event))\n\n"
    end
    chunk = JSON3.write((; choices=[(; delta=(; content="answer"), finish_reason="stop")]))
    "data: $chunk\n\ndata: [DONE]\n\n"
end

@testset "RPC switches between configured provider APIs" begin
    requests = Any[]
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        push!(requests, (; target=request.target, authorization=HTTP.header(request, "authorization", ""), anthropic=HTTP.header(request, "x-api-key", ""), google=HTTP.header(request, "x-goog-api-key", ""), route=HTTP.header(request, "x-route", ""), modelheader=HTTP.header(request, "x-model", ""), body=JSON3.read(String(request.body), Dict{String, Any})))
        HTTP.Response(200, ["Content-Type" => "text/event-stream"], response(request))
    end
    try
        mktempdir() do root
            base = "http://$(HTTP.server_addr(server))"
            project = dirname(@__DIR__)
            for kind in (haskey(ENV, "PI_SOURCE") ? (:pi, :julia) : (:julia,))
                workspace = joinpath(root, String(kind))
                mkpath(workspace)
                agentdir = joinpath(workspace, "agent")
                mkpath(agentdir)
                write(joinpath(agentdir, "models.json"), JSON3.write(fixture(base)))
                write(joinpath(agentdir, "settings.json"), JSON3.write((; defaultProvider="openai", defaultModel="chat", retry=(; enabled=false))))
                hookpath = joinpath(workspace, "hooks")
                extension = joinpath(workspace, "hook.mjs")
                write(extension, "import { appendFileSync } from 'node:fs'; export default function(pi) { pi.on('agent_start', async () => appendFileSync(process.env.JF_HOOK_PATH, 'x')); }\n")
                packages = joinpath(workspace, "packages")
                plugin = joinpath(packages, "ProviderHook")
                mkpath(joinpath(plugin, "src"))
                write(joinpath(plugin, "Project.toml"), "name = \"ProviderHook\"\nuuid = \"63132595-25fd-4693-a178-f8d812047b94\"\nversion = \"0.1.0\"\n\n[deps]\nJuliaForever = \"2b71f2a2-b786-4fd0-b9cc-80b6322c5084\"\n")
                write(joinpath(plugin, "src", "ProviderHook.jl"), "module ProviderHook\nusing JuliaForever\nfunction plugin(); JuliaForever.Extensions.Plugin(; hooks=(:agent_start => (event -> open(io -> write(io, \"x\"), ENV[\"JF_HOOK_PATH\"], \"a\")),)); end\nend\n")
                env = ["HOME" => workspace, "USERPROFILE" => workspace, "PI_CODING_AGENT_DIR" => agentdir, "PI_OFFLINE" => "1", "JF_INSTRUCTIONS_DIR" => workspace, "JF_CHATGPT_DIR" => joinpath(workspace, "chatgpt"), "JF_OPENROUTER_DIR" => joinpath(workspace, "router"), "JF_HOOK_PATH" => hookpath, "JF_PROVIDER" => "openai", "JF_MISSING_HEADER" => nothing, "OPENAI_MODEL" => "chat", "OPENAI_API_KEY" => nothing, "OPENROUTER_API_KEY" => nothing, "ANTHROPIC_API_KEY" => nothing, "GEMINI_API_KEY" => nothing, "TERM" => "dumb"]
                sessions = joinpath(workspace, "sessions")
                cmd = if kind == :pi
                    source = ENV["PI_SOURCE"]
                    @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
                    Cmd(`node $(joinpath(@__DIR__, "headless_reference.mjs")) $source --mode rpc --session-dir $sessions --provider fixture --model chat --extension $extension --approve`; dir=workspace)
                else
                    Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project -m JuliaForever --mode rpc --session-dir $sessions --provider fixture --model chat --plugin-env $packages --plugin ProviderHook`; dir=workspace)
                end
                first = length(requests)
                result = exchange(cmd, env; checkbad=kind == :julia)
                wire = requests[first+1:end]
                @test result.queued["success"] && result.switched["success"] && result.cleared["success"]
                @test result.response_state["data"]["model"]["api"] == "openai-responses"
                @test result.response_state["data"]["pendingMessageCount"] == 1
                @test result.anthropic["success"] && result.anthropic_state["data"]["model"]["provider"] == "other"
                @test result.google["success"] && result.google_state["data"]["model"]["provider"] == "third"
                @test !result.failed["success"] && result.before["data"] == result.after["data"]
                if kind == :julia
                    @test !result.bad["success"]
                end
                @test result.final_state["data"]["model"] == result.google_state["data"]["model"]
                @test read(hookpath, String) == "xxxx"
                @test length(wire) == 4
                if length(wire) == 4
                    @test [request.route for request in wire] == ["fixture-header", "fixture-header", "other-header", "third-header"]
                    @test wire[1].authorization == wire[2].authorization == "Bearer synthetic-fixture-key"
                    @test isempty(wire[1].modelheader) && wire[2].modelheader == "responses-header"
                    @test wire[3].anthropic == "synthetic-other-key" && wire[4].google == "synthetic-third-key"
                    @test all(request -> !occursin("synthetic-fixture-key", JSON3.write(request)), wire[3:4])
                    @test isempty(wire[3].modelheader) && isempty(wire[4].modelheader)
                    @test all(request -> occursin("first message", JSON3.write(request.body)), wire)
                    @test all(request -> !isempty(get(request.body, "tools", [])), wire)
                end
                @test all(secret -> !occursin(secret, JSON3.write(result.observed) * result.diagnostics), ("synthetic-fixture-key", "synthetic-other-key", "synthetic-third-key", "synthetic-bad-key"))
                @test all(secret -> !occursin(secret, String(read(result.saved["data"]["sessionFile"]))), ("synthetic-fixture-key", "synthetic-other-key", "synthetic-third-key"))
                history = result.saved["data"]["sessionFile"]
                restart = if kind == :pi
                    Cmd(`node $(joinpath(@__DIR__, "headless_reference.mjs")) $(ENV["PI_SOURCE"]) --mode rpc --session $history --extension $extension --approve`; dir=workspace)
                else
                    Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project -m JuliaForever --mode rpc --session $history --plugin-env $packages --plugin ProviderHook`; dir=workspace)
                end
                before_restart = length(requests)
                restored = reopen(restart, env)
                @test restored.state["data"]["model"]["provider"] == "third"
                replay = requests[before_restart+1:end]
                @test length(replay) == 1 && replay[1].google == "synthetic-third-key" && replay[1].route == "third-header"
                @test read(hookpath, String) == "xxxxx"
                @test all(secret -> !occursin(secret, JSON3.write(restored.observed) * restored.diagnostics), ("synthetic-fixture-key", "synthetic-other-key", "synthetic-third-key"))
                if kind == :julia
                    config = JSON3.read(JSON3.write(fixture(base)), Dict{String, Any})
                    config["providers"]["third"]["apiKey"] = "\$JF_MISSING_KEY"
                    write(joinpath(agentdir, "models.json"), JSON3.write(config))
                    before_missing = length(requests)
                    missing = reopen(restart, [env; "JF_MISSING_KEY" => nothing]; expectprompt=false)
                    @test missing.state["data"]["model"]["provider"] == "unknown" && !missing.prompt["success"]
                    @test length(requests) == before_missing
                    @test all(secret -> !occursin(secret, JSON3.write(missing.observed) * missing.diagnostics), ("synthetic-fixture-key", "synthetic-other-key", "synthetic-third-key"))
                    source = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project -m JuliaForever --mode rpc --session-dir $(joinpath(workspace, "new-sessions"))`; dir=workspace)
                    blocked = failedswitch(source, [env; "JF_MISSING_KEY" => nothing], history)
                    @test !blocked.switched["success"] && blocked.unchanged
                    @test blocked.before["data"]["sessionId"] == blocked.after["data"]["sessionId"] && blocked.after["data"]["model"]["provider"] == "openai"
                    @test blocked.entries["data"] == blocked.following["data"]
                    @test all(secret -> !occursin(secret, JSON3.write(blocked.observed) * blocked.diagnostics), ("synthetic-fixture-key", "synthetic-other-key", "synthetic-third-key"))
                end
            end
        end
    finally
        close(server)
        wait(server)
    end
end

@testset "provider switches respect model thinking settings" begin
    requests = Any[]
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        push!(requests, (; target=request.target, authorization=HTTP.header(request, "authorization", ""), anthropic=HTTP.header(request, "x-api-key", ""), google=HTTP.header(request, "x-goog-api-key", ""), body=JSON3.read(String(request.body), Dict{String, Any})))
        HTTP.Response(200, ["Content-Type" => "text/event-stream"], response(request))
    end
    try
        mktempdir() do root
            base = "http://$(HTTP.server_addr(server))"
            project = dirname(@__DIR__)
            results = []
            for kind in (haskey(ENV, "PI_SOURCE") ? (:pi, :julia) : (:julia,))
                workspace = joinpath(root, String(kind))
                mkpath(workspace)
                agentdir = joinpath(workspace, "agent")
                mkpath(agentdir)
                settings = (; defaultProvider="openai", defaultModel="gpt-5.2", defaultThinkingLevel="high", modelThinkingLevels=Dict("google/gemini-2.5-flash" => "low", "anthropic/claude-sonnet-4-5" => "high"), retry=(; enabled=false))
                write(joinpath(agentdir, "settings.json"), JSON3.write(settings))
                if kind == :pi
                    routes = (; providers=(; openai=(; baseUrl=base * "/responses"), anthropic=(; baseUrl=base * "/anthropic"), google=(; baseUrl=base * "/google")))
                    write(joinpath(agentdir, "models.json"), JSON3.write(routes))
                end
                env = ["HOME" => workspace, "USERPROFILE" => workspace, "PI_CODING_AGENT_DIR" => agentdir, "PI_OFFLINE" => "1", "JF_INSTRUCTIONS_DIR" => workspace, "JF_CHATGPT_DIR" => joinpath(workspace, "chatgpt"), "JF_OPENROUTER_DIR" => joinpath(workspace, "router"), "JF_PROVIDER" => "openai-responses", "OPENAI_MODEL" => "gpt-5.2", "OPENAI_BASE_URL" => base * "/responses", "OPENAI_API_KEY" => "sk-synthetic-openai", "ANTHROPIC_BASE_URL" => base * "/anthropic", "ANTHROPIC_API_KEY" => "synthetic-anthropic", "GEMINI_BASE_URL" => base * "/google", "GEMINI_API_KEY" => "synthetic-google", "OPENROUTER_API_KEY" => nothing, "TERM" => "dumb"]
                sessions = joinpath(workspace, "sessions")
                cmd = if kind == :pi
                    Cmd(`node $(joinpath(@__DIR__, "headless_reference.mjs")) $(ENV["PI_SOURCE"]) --mode rpc --session-dir $sessions --approve`; dir=workspace)
                else
                    Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project -m JuliaForever --mode rpc --session-dir $sessions`; dir=workspace)
                end
                before = length(requests)
                result = thinkingexchange(cmd, env)
                wire = requests[before+1:end]
                @test all(reply -> reply["success"], result.replies)
                @test length(wire) == 5
                if length(wire) == 5
                    @test wire[1].authorization == "Bearer sk-synthetic-openai" && wire[2].google == "synthetic-google" && wire[3].anthropic == "synthetic-anthropic"
                    @test !occursin("sk-synthetic-openai", JSON3.write(wire[2:3])) && !occursin("synthetic-google", JSON3.write(wire[1:1]))
                end
                @test all(secret -> !occursin(secret, JSON3.write(result.observed) * result.diagnostics), ("sk-synthetic-openai", "synthetic-anthropic", "synthetic-google"))
                history = last(result.states)["data"]["sessionFile"]
                restart = if kind == :pi
                    Cmd(`node $(joinpath(@__DIR__, "headless_reference.mjs")) $(ENV["PI_SOURCE"]) --mode rpc --session $history --approve`; dir=workspace)
                else
                    Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project -m JuliaForever --mode rpc --session $history`; dir=workspace)
                end
                before_restart = length(requests)
                restored = reopen(restart, env)
                replay = requests[before_restart+1:end]
                @test restored.state["data"]["model"]["provider"] == "google" && restored.state["data"]["thinkingLevel"] == "low"
                @test length(replay) == 1 && replay[1].google == "synthetic-google"
                if length(replay) == 1 && length(wire) == 5
                    @test replay[1].body["generationConfig"]["thinkingConfig"] == wire[5].body["generationConfig"]["thinkingConfig"]
                end
                push!(results, (; levels=[state["data"]["thinkingLevel"] for state in result.states], wire))
            end
            if length(results) == 2
                @test results[1].levels == results[2].levels == ["high", "low", "high", "off", "low"]
                if length(results[1].wire) == length(results[2].wire) == 5
                    pi, jf = results
                    @test jf.wire[2].body["generationConfig"]["thinkingConfig"] == pi.wire[2].body["generationConfig"]["thinkingConfig"]
                    @test jf.wire[3].body["thinking"] == pi.wire[3].body["thinking"]
                    @test jf.wire[5].body["generationConfig"]["thinkingConfig"] == pi.wire[5].body["generationConfig"]["thinkingConfig"]
                end
            end
        end
    finally
        close(server)
        wait(server)
    end
end

mutable struct FailingStore <: JuliaForever.History.Store
    memory::JuliaForever.History.Memory
    fail::Bool
end
JuliaForever.History.snapshot(store::FailingStore) = JuliaForever.History.snapshot(store.memory)
Base.append!(store::FailingStore, revision::Integer, batch::Vector) = store.fail ? JuliaForever.History.Rejected(:revision) : append!(store.memory, revision, batch)
Base.close(::FailingStore) = nothing

end
