module HeadlessDifferentialTests

using Test, JSON3, HTTP, Base64

function runprocess(cmd, input, env)
    mktempdir() do dir
        infile, outfile, errfile = joinpath.((dir,), ("input", "output", "error"))
        write(infile, input)
        process = run(pipeline(ignorestatus(addenv(cmd, env...)); stdin=infile, stdout=outfile, stderr=errfile))
        (; status=process.exitcode, output=read(outfile, String), diagnostics=read(errfile, String))
    end
end

function records(output)
    try
        [JSON3.read(line, Dict{String, Any}) for line in split(chomp(output), '\n') if !isempty(line)]
    catch
        Dict{String, Any}[]
    end
end

function responses(output)
    Dict(record["id"] => record for record in records(output) if get(record, "type", "") == "response" && haskey(record, "id"))
end

function receive!(channel, observed, predicate)
    while true
        timedwait(() -> isready(channel), 45) == :ok || error("Timed out waiting for RPC output")
        value = take!(channel)
        push!(observed, value)
        predicate(value) && return value
    end
end

function exchange(cmd, env; switching=false, protect=false)
    mktempdir() do dir
        diagnostics = joinpath(dir, "error")
        process = open(pipeline(addenv(cmd, env...); stderr=diagnostics), "r+")
        channel = Channel{Any}(Inf)
        reader = @async for line in eachline(process)
            put!(channel, JSON3.read(line, Dict{String, Any}))
        end
        observed = Any[]
        try
            println(process, JSON3.write((; id="prompt", type="prompt", message="hello")))
            flush(process)
            receive!(channel, observed, value -> value["type"] == "agent_settled")
            println(process, JSON3.write((; id="messages", type="get_messages")))
            flush(process)
            messages = receive!(channel, observed, value -> get(value, "id", "") == "messages")
            println(process, JSON3.write((; id="name", type="set_session_name", name=" Example ")))
            flush(process)
            name = receive!(channel, observed, value -> get(value, "id", "") == "name")
            println(process, JSON3.write((; id="state", type="get_state")))
            flush(process)
            state = receive!(channel, observed, value -> get(value, "id", "") == "state")
            println(process, JSON3.write((; id="stats", type="get_session_stats")))
            flush(process)
            stats = receive!(channel, observed, value -> get(value, "id", "") == "stats")
            exported = switching ? exportsession(process, channel, observed, state; protect) : nothing
            println(process, JSON3.write((; id="clone", type="clone")))
            flush(process)
            clone = receive!(channel, observed, value -> get(value, "id", "") == "clone")
            println(process, JSON3.write((; id="clone-state", type="get_state")))
            flush(process)
            clonestate = receive!(channel, observed, value -> get(value, "id", "") == "clone-state")
            fork = forksession(process, channel, observed)
            println(process, JSON3.write((; id="new", type="new_session")))
            flush(process)
            new = receive!(channel, observed, value -> get(value, "id", "") == "new")
            println(process, JSON3.write((; id="new-state", type="get_state")))
            flush(process)
            newstate = receive!(channel, observed, value -> get(value, "id", "") == "new-state")
            switched = switching ? switchback(process, channel, observed, state) : nothing
            (; observed, messages, name, state, stats, exported, clone, clonestate, fork, new, newstate, switched)
        finally
            close(process.in)
            timedwait(() -> process_exited(process), 5) == :ok || kill(process)
            wait(process)
            wait(reader)
        end
    end
end

function forksession(process, channel, observed)
    send(value) = (println(process, JSON3.write(value)); flush(process))
    send((; id="fork-messages", type="get_fork_messages"))
    messages = receive!(channel, observed, value -> get(value, "id", "") == "fork-messages")
    entries = get(get(messages, "data", Dict()), "messages", [])
    entry = isempty(entries) ? "missing" : first(entries)["entryId"]
    send((; id="fork", type="fork", entryId=entry))
    reply = receive!(channel, observed, value -> get(value, "id", "") == "fork")
    send((; id="fork-state", type="get_state"))
    state = receive!(channel, observed, value -> get(value, "id", "") == "fork-state")
    send((; id="fork-invalid", type="fork", entryId="missing-entry"))
    invalid = receive!(channel, observed, value -> get(value, "id", "") == "fork-invalid")
    send((; id="fork-after-invalid", type="get_state"))
    after = receive!(channel, observed, value -> get(value, "id", "") == "fork-after-invalid")
    (; messages, reply, state, invalid, after)
end

function exportsession(process, channel, observed, state; protect=false)
    path = joinpath(dirname(state["data"]["sessionFile"]), "report.html")
    send(value) = (println(process, JSON3.write(value)); flush(process))
    send((; id="export", type="export_html", outputPath=path))
    reply = receive!(channel, observed, value -> get(value, "id", "") == "export")
    html = isfile(path) ? read(path, String) : ""
    send((; id="export-invalid", type="export_html", outputPath=joinpath(dirname(path), "missing", "report.html")))
    invalid = receive!(channel, observed, value -> get(value, "id", "") == "export-invalid")
    source = state["data"]["sessionFile"]
    before = protect ? read(source) : UInt8[]
    overwrite = if protect
        send((; id="export-source", type="export_html", outputPath=source))
        receive!(channel, observed, value -> get(value, "id", "") == "export-source")
    else
        nothing
    end
    unchanged = protect ? read(source) == before : true
    (; path, reply, html, invalid, overwrite, unchanged)
end
function pihtml(html)
    data = match(r"<script id=\"session-data\" type=\"application/json\">([^<]+)</script>", html)
    isnothing(data) ? "" : String(base64decode(data[1]))
end

function switchback(process, channel, observed, state)
    path = state["data"]["sessionFile"]
    send(value) = (println(process, JSON3.write(value)); flush(process))
    send((; id="switch", type="switch_session", sessionPath=path))
    reply = receive!(channel, observed, value -> get(value, "id", "") == "switch")
    send((; id="switched-state", type="get_state"))
    restored = receive!(channel, observed, value -> get(value, "id", "") == "switched-state")
    send((; id="switch-invalid", type="switch_session", sessionPath=dirname(path)))
    invalid = receive!(channel, observed, value -> get(value, "id", "") == "switch-invalid")
    send((; id="switch-after-invalid", type="get_state"))
    after = receive!(channel, observed, value -> get(value, "id", "") == "switch-after-invalid")
    (; reply, restored, invalid, after)
end

function exchangequeued(cmd, env, arrivals)
    mktempdir() do dir
        process = open(pipeline(addenv(cmd, env...); stderr=joinpath(dir, "error")), "r+")
        channel = Channel{Any}(Inf)
        reader = @async for line in eachline(process)
            put!(channel, JSON3.read(line, Dict{String, Any}))
        end
        observed = Any[]
        held = Channel{Nothing}[]
        try
            send(value) = (println(process, JSON3.write(value)); flush(process))
            send((; id="prompt", type="prompt", message="hello"))
            first = receive!(channel, observed, value -> get(value, "id", "") == "prompt")
            timedwait(() -> isready(arrivals), 45) == :ok || error("Provider request did not start")
            firstgate = take!(arrivals)
            push!(held, firstgate)
            send((; id="steer", type="steer", message="change"))
            steer = receive!(channel, observed, value -> get(value, "id", "") == "steer")
            send((; id="follow", type="follow_up", message="after"))
            follow = receive!(channel, observed, value -> get(value, "id", "") == "follow")
            send((; id="busy", type="prompt", message="overlap"))
            busy = receive!(channel, observed, value -> get(value, "id", "") == "busy")
            put!(firstgate, nothing)
            while true
                timedwait(() -> isready(arrivals) || isready(channel), 45) == :ok || error("RPC run did not settle")
                isready(arrivals) && put!(take!(arrivals), nothing)
                isready(channel) || continue
                event = take!(channel)
                push!(observed, event)
                event["type"] == "agent_settled" && break
            end
            send((; id="messages", type="get_messages"))
            messages = receive!(channel, observed, value -> get(value, "id", "") == "messages")
            (; first, steer, follow, busy, messages, observed)
        finally
            for gate in held
                isready(gate) || put!(gate, nothing)
            end
            while isready(arrivals)
                put!(take!(arrivals), nothing)
            end
            close(process.in)
            timedwait(() -> process_exited(process), 5) == :ok || kill(process)
            wait(process)
            wait(reader)
        end
    end
end

function exchangeaborted(cmd, env, arrivals)
    mktempdir() do dir
        process = open(pipeline(addenv(cmd, env...); stderr=joinpath(dir, "error")), "r+")
        channel = Channel{Any}(Inf)
        reader = @async for line in eachline(process)
            put!(channel, JSON3.read(line, Dict{String, Any}))
        end
        observed = Any[]
        gate = nothing
        try
            println(process, JSON3.write((; id="prompt", type="prompt", message="hello")))
            flush(process)
            receive!(channel, observed, value -> get(value, "id", "") == "prompt")
            timedwait(() -> isready(arrivals), 45) == :ok || error("Provider request did not start")
            gate = take!(arrivals)
            println(process, JSON3.write((; id="abort", type="abort")))
            flush(process)
            reply = receive!(channel, observed, value -> get(value, "id", "") == "abort")
            settled = filter(value -> value["type"] == "agent_settled", observed)
            isempty(settled) && push!(settled, receive!(channel, observed, value -> value["type"] == "agent_settled"))
            (; reply, settled=only(settled), observed)
        finally
            isnothing(gate) || put!(gate, nothing)
            while isready(arrivals)
                put!(take!(arrivals), nothing)
            end
            close(process.in)
            timedwait(() -> process_exited(process), 5) == :ok || kill(process)
            wait(process)
            wait(reader)
        end
    end
end

@testset "Pi RPC subprocess protocol" begin
    source = ENV["PI_SOURCE"]
    @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
    mktempdir() do workspace
        skill = joinpath(workspace, ".pi", "skills", "demo", "SKILL.md")
        template = joinpath(workspace, ".pi", "prompts", "fix.md")
        mkpath(dirname(skill))
        mkpath(dirname(template))
        write(skill, "---\nname: demo\ndescription: Demo skill\n---\n\nUse the demo.\n")
        write(template, "---\ndescription: Fix it\n---\n\nFix \$1.\n")
        project = dirname(@__DIR__)
        oracle = joinpath(@__DIR__, "headless_reference.mjs")
        pi = Cmd(`node $oracle $source --mode rpc --no-session --provider openai --model gpt-4.1-mini --approve`; dir=workspace)
        jf = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --project=$project $(joinpath(@__DIR__, "terminal_process.jl")) --mode rpc --no-session`; dir=workspace)
        env = ["PI_SOURCE" => source, "HOME" => workspace, "PI_CODING_AGENT_DIR" => joinpath(workspace, "agent"), "PI_OFFLINE" => "1", "JF_PROVIDER" => "openai", "OPENAI_MODEL" => "gpt-4.1-mini", "OPENAI_API_KEY" => "fixture", "JF_FIXTURE" => "text", "JF_INSTRUCTIONS_DIR" => workspace]
        commands = [(; id="state", type="get_state"), (; id="messages", type="get_messages"), (; id="commands", type="get_commands"), (; id="clear", type="clear_queue"), (; id="bad", type="no_such_command"), (; id="export-empty", type="export_html", outputPath=joinpath(workspace, "report.html")), (; id="levels", type="get_available_thinking_levels"), (; id="cycle", type="cycle_thinking_level"), (; id="thinking", type="set_thinking_level", level="off"), (; id="steering-mode", type="set_steering_mode", mode="one-at-a-time"), (; id="follow-mode", type="set_follow_up_mode", mode="one-at-a-time"), (; id="compaction", type="set_auto_compaction", enabled=false), (; id="retry", type="set_auto_retry", enabled=false), (; id="abort-retry", type="abort_retry"), (; id="abort-bash", type="abort_bash")]
        input = join(JSON3.write.(commands), "\n") * "\n{\n"
        expected = runprocess(pi, input, env)
        actual = runprocess(jf, input, env)
        @test expected.status == actual.status == 0
        reference = responses(expected.output)
        result = responses(actual.output)
        @test Set(keys(result)) == Set(keys(reference))
        for id in ("messages", "clear", "bad", "export-empty", "levels", "cycle", "thinking", "steering-mode", "follow-mode", "compaction", "retry", "abort-retry", "abort-bash")
            @test get(result, id, nothing) == reference[id]
        end
        expected_state = reference["state"]["data"]
        actual_state = get(get(result, "state", Dict()), "data", Dict())
        for key in ("thinkingLevel", "isStreaming", "isCompacting", "steeringMode", "followUpMode", "messageCount", "pendingMessageCount")
            @test get(actual_state, key, nothing) == expected_state[key]
        end
        @test actual_state["model"]["id"] == expected_state["model"]["id"]
        @test actual_state["model"]["provider"] == expected_state["model"]["provider"]
        projectcommands(response) = Dict(item["name"] => item for item in get(get(response, "data", Dict()), "commands", []) if item["name"] in ("fix", "skill:demo"))
        @test projectcommands(get(result, "commands", Dict())) == projectcommands(reference["commands"])
        parseerror(output) = only(record for record in records(output) if get(record, "command", "") == "parse")
        @test parseerror(actual.output)["success"] == parseerror(expected.output)["success"] == false
        @test startswith(parseerror(actual.output)["error"], "Failed to parse command")
        pi_help = Cmd(`node $oracle $source --mode json --help`; dir=workspace)
        jf_help = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project -m JuliaForever --mode json --help`; dir=workspace)
        pi_metadata = runprocess(pi_help, "", env)
        jf_metadata = runprocess(jf_help, "", env)
        @test pi_metadata.status == jf_metadata.status == 0
        @test isempty(pi_metadata.output) && isempty(jf_metadata.output)
        @test !isempty(pi_metadata.diagnostics) && !isempty(jf_metadata.diagnostics)

        cleanenv = Dict("PATH" => ENV["PATH"], "HOME" => workspace, "PI_SOURCE" => source, "PI_CODING_AGENT_DIR" => joinpath(workspace, "empty-agent"), "PI_OFFLINE" => "1", "JF_FIXTURE" => "text", "JF_INSTRUCTIONS_DIR" => workspace, "JULIA_DEPOT_PATH" => get(ENV, "JULIA_DEPOT_PATH", ""))
        empty_pi = setenv(Cmd(`node $oracle $source --mode rpc --no-session`; dir=workspace), cleanenv)
        empty_jf = setenv(Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --project=$project $(joinpath(@__DIR__, "terminal_process.jl")) --mode rpc --no-session`; dir=workspace), cleanenv)
        empty_input = join(JSON3.write.([(; id="state", type="get_state"), (; id="models", type="get_available_models"), (; id="prompt", type="prompt", message="hello")]), "\n") * "\n"
        pi_unconfigured = runprocess(empty_pi, empty_input, [])
        jf_unconfigured = runprocess(empty_jf, empty_input, [])
        @test jf_unconfigured.status == pi_unconfigured.status == 0
        expected_empty, actual_empty = responses(pi_unconfigured.output), responses(jf_unconfigured.output)
        @test get(get(get(actual_empty, "state", Dict()), "data", Dict()), "model", nothing) == expected_empty["state"]["data"]["model"]
        @test get(actual_empty, "models", nothing) == expected_empty["models"]
        @test get(get(actual_empty, "prompt", Dict()), "success", nothing) == expected_empty["prompt"]["success"] == false
    end
end

function eventview(record)
    type = record["type"]
    if type in ("message_start", "message_end")
        value = record["message"]
        role = value["role"]
        type == "message_start" && role == "assistant" && return (; type, role)
        return role == "system" ? (; type, role) : (; type, role, content=value["content"], stopReason=get(value, "stopReason", nothing))
    elseif type == "message_update"
        return (; type, event=record["assistantMessageEvent"], usage=record["usage"])
    elseif type == "turn_end"
        return (; type, content=record["message"]["content"], stopReason=record["message"]["stopReason"], toolResults=toolview.(record["toolResults"]))
    elseif type == "tool_execution_start"
        return (; type, id=record["toolCallId"], name=record["toolName"], args=record["args"])
    elseif type == "tool_execution_end"
        return (; type, id=record["toolCallId"], name=record["toolName"], content=record["result"]["content"], isError=record["isError"])
    elseif type == "agent_end"
        return (; type, roles=[value["role"] for value in record["messages"]], willRetry=record["willRetry"])
    elseif type == "agent_settled"
        return (; type, aborted=record["aborted"])
    end
    (; type)
end
toolview(value) = (; role=value["role"], id=value["toolCallId"], name=value["toolName"], content=value["content"], isError=value["isError"])

@testset "Pi JSON stream with a local provider" begin
    source = ENV["PI_SOURCE"]
    chunks = [Dict("id" => "fixture", "object" => "chat.completion.chunk", "created" => 1, "model" => "fixture", "choices" => [Dict("index" => 0, "delta" => delta, "finish_reason" => finish)]) for (delta, finish) in [(Dict("role" => "assistant", "content" => "Hello"), nothing), (Dict("content" => " world"), nothing), (Dict(), "stop")]]
    body = join(("data: " * JSON3.write(chunk) * "\n\n" for chunk in chunks)) * "data: [DONE]\n\n"
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        HTTP.Response(200, ["Content-Type" => "text/event-stream"], body)
    end
    try
        mktempdir() do workspace
            base = "http://$(HTTP.server_addr(server))/v1"
            agentdir = joinpath(workspace, "agent")
            mkpath(agentdir)
            write(joinpath(agentdir, "settings.json"), JSON3.write((; retry=(; enabled=false))))
            write(joinpath(agentdir, "models.json"), JSON3.write(Dict("providers" => Dict("openai" => Dict("baseUrl" => base, "api" => "openai-completions", "apiKey" => "fixture", "models" => [Dict("id" => "fixture")])))))
            project = dirname(@__DIR__)
            oracle = joinpath(@__DIR__, "headless_reference.mjs")
            pi = Cmd(`node $oracle $source --mode json --no-session --provider openai --model fixture hello`; dir=workspace)
            jf = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project -m JuliaForever --mode json --no-session hello`; dir=workspace)
            env = ["PI_SOURCE" => source, "HOME" => workspace, "PI_CODING_AGENT_DIR" => agentdir, "PI_OFFLINE" => "1", "JF_PROVIDER" => "openai", "OPENAI_MODEL" => "fixture", "OPENAI_API_KEY" => "fixture", "OPENAI_BASE_URL" => base, "JF_INSTRUCTIONS_DIR" => workspace]
            reference = runprocess(pi, "", env)
            actual = runprocess(jf, "", env)
            @test reference.status == actual.status == 0
            @test eventview.(records(actual.output)) == eventview.(records(reference.output))

            packages = joinpath(workspace, "packages")
            plugin = joinpath(packages, "NoisyPlugin")
            mkpath(joinpath(plugin, "src"))
            write(joinpath(plugin, "Project.toml"), "name = \"NoisyPlugin\"\nuuid = \"c5f8f239-ffb0-4ec5-ab9d-3fe12300424f\"\nversion = \"0.1.0\"\n\n[deps]\nJuliaForever = \"2b71f2a2-b786-4fd0-b9cc-80b6322c5084\"\n")
            write(joinpath(plugin, "src", "NoisyPlugin.jl"), "module NoisyPlugin\nusing JuliaForever\nfunction __init__(); println(\"init-noise\"); end\nfunction plugin(); println(\"factory-noise\"); JuliaForever.Extensions.Plugin(; hooks=(:agent_start => (event -> println(\"hook-noise\")),)); end\nend\n")
            extension = joinpath(workspace, "noisy.mjs")
            write(extension, "console.log('init-noise'); export default function(pi) { console.log('factory-noise'); pi.on('agent_start', async () => console.log('hook-noise')); }\n")
            pi_noisy = Cmd(`node $oracle $source --mode json --no-session --provider openai --model fixture --extension $extension --approve hello`; dir=workspace)
            jf_noisy = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project -m JuliaForever --mode json --no-session --plugin-env $packages --plugin NoisyPlugin hello`; dir=workspace)
            pi_logs = runprocess(pi_noisy, "", env)
            jf_logs = runprocess(jf_noisy, "", env)
            @test pi_logs.status == jf_logs.status == 0
            @test eventview.(records(jf_logs.output)) == eventview.(records(pi_logs.output))
            @test all(occursin(noise, pi_logs.diagnostics) && occursin(noise, jf_logs.diagnostics) for noise in ("init-noise", "factory-noise", "hook-noise"))

            rejected = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
                HTTP.Response(401, ["Content-Type" => "application/json"], JSON3.write((; error=(; message="fixture denied", type="authentication_error"))))
            end
            try
                rejectedbase = "http://$(HTTP.server_addr(rejected))/v1"
                write(joinpath(agentdir, "models.json"), JSON3.write(Dict("providers" => Dict("openai" => Dict("baseUrl" => rejectedbase, "api" => "openai-completions", "apiKey" => "fixture", "models" => [Dict("id" => "fixture")])))))
                rejectedenv = [pair for pair in env if first(pair) != "OPENAI_BASE_URL"]
                push!(rejectedenv, "OPENAI_BASE_URL" => rejectedbase)
                pi_failure = runprocess(pi, "", rejectedenv)
                jf_failure = runprocess(jf, "", rejectedenv)
                @test pi_failure.status == jf_failure.status == 0
                @test eventview.(records(jf_failure.output)) == eventview.(records(pi_failure.output))
            finally
                close(rejected)
                wait(rejected)
            end
            disconnected = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
                HTTP.Response(200)
            end
            disconnectedbase = "http://$(HTTP.server_addr(disconnected))/v1"
            close(disconnected)
            wait(disconnected)
            write(joinpath(agentdir, "models.json"), JSON3.write(Dict("providers" => Dict("openai" => Dict("baseUrl" => disconnectedbase, "api" => "openai-completions", "apiKey" => "fixture", "models" => [Dict("id" => "fixture")])))))
            disconnectedenv = [pair for pair in env if first(pair) != "OPENAI_BASE_URL"]
            push!(disconnectedenv, "OPENAI_BASE_URL" => disconnectedbase)
            pi_disconnect = runprocess(pi, "", disconnectedenv)
            jf_disconnect = runprocess(jf, "", disconnectedenv)
            @test pi_disconnect.status == jf_disconnect.status == 0
            @test eventview.(records(jf_disconnect.output)) == eventview.(records(pi_disconnect.output))
            write(joinpath(agentdir, "models.json"), JSON3.write(Dict("providers" => Dict("openai" => Dict("baseUrl" => base, "api" => "openai-completions", "apiKey" => "fixture", "models" => [Dict("id" => "fixture")])))))

            pi_rpc = Cmd(`node $oracle $source --mode rpc --no-session --provider openai --model fixture`; dir=workspace)
            jf_rpc = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project -m JuliaForever --mode rpc --no-session`; dir=workspace)
            pi_run = exchange(pi_rpc, env)
            jf_run = exchange(jf_rpc, env)
            events(run) = [eventview(event) for event in run.observed if !(event["type"] in ("response", "queue_update", "session_info_changed"))]
            @test events(jf_run) == events(pi_run)
            @test jf_run.name == pi_run.name
            @test [value["role"] for value in jf_run.messages["data"]["messages"]] == [value["role"] for value in pi_run.messages["data"]["messages"]]
            @test jf_run.state["data"]["messageCount"] == pi_run.state["data"]["messageCount"]
            @test jf_run.state["data"]["sessionName"] == pi_run.state["data"]["sessionName"]
            @test jf_run.clone == pi_run.clone
            @test jf_run.clonestate["data"]["messageCount"] == pi_run.clonestate["data"]["messageCount"]
            @test jf_run.clonestate["data"]["sessionId"] != jf_run.state["data"]["sessionId"]
            forktexts(result) = [item["text"] for item in get(get(result.fork.messages, "data", Dict()), "messages", [])]
            @test forktexts(jf_run) == forktexts(pi_run) == ["hello"]
            @test jf_run.fork.reply == pi_run.fork.reply
            @test jf_run.fork.state["data"]["messageCount"] == pi_run.fork.state["data"]["messageCount"]
            @test jf_run.fork.state["data"]["sessionId"] != jf_run.clonestate["data"]["sessionId"]
            @test !jf_run.fork.invalid["success"] && !pi_run.fork.invalid["success"]
            @test jf_run.fork.after["data"]["sessionId"] == jf_run.fork.state["data"]["sessionId"]
            @test get(jf_run.stats, "data", nothing) !== nothing
            for key in ("userMessages", "assistantMessages", "toolCalls", "toolResults", "totalMessages", "tokens", "cost")
                @test get(get(jf_run.stats, "data", Dict()), key, nothing) == pi_run.stats["data"][key]
            end
            @test jf_run.new == pi_run.new
            @test jf_run.newstate["data"]["messageCount"] == pi_run.newstate["data"]["messageCount"] == 0
            @test jf_run.newstate["data"]["sessionId"] != jf_run.state["data"]["sessionId"]
            @test !haskey(jf_run.newstate["data"], "sessionName")

            pi_switch_rpc = Cmd(`node $oracle $source --mode rpc --session-dir $(joinpath(workspace, "switch-pi")) --provider openai --model fixture`; dir=workspace)
            jf_switch_rpc = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project -m JuliaForever --mode rpc --session-dir $(joinpath(workspace, "switch-jf"))`; dir=workspace)
            pi_switch = exchange(pi_switch_rpc, env; switching=true)
            jf_switch = exchange(jf_switch_rpc, env; switching=true, protect=true)
            @test pi_switch.exported.reply["success"] && jf_switch.exported.reply["success"]
            @test pi_switch.exported.reply["data"]["path"] == pi_switch.exported.path
            @test get(get(jf_switch.exported.reply, "data", Dict()), "path", nothing) == jf_switch.exported.path
            @test occursin("Hello world", pihtml(pi_switch.exported.html)) && occursin("Hello world", jf_switch.exported.html)
            @test !pi_switch.exported.invalid["success"] && !jf_switch.exported.invalid["success"]
            @test !jf_switch.exported.overwrite["success"] && jf_switch.exported.unchanged
            @test jf_switch.clone == pi_switch.clone
            @test jf_switch.clonestate["data"]["messageCount"] == pi_switch.clonestate["data"]["messageCount"]
            @test forktexts(jf_switch) == forktexts(pi_switch) == ["hello"]
            @test jf_switch.fork.reply == pi_switch.fork.reply
            @test jf_switch.switched.reply == pi_switch.switched.reply
            @test jf_switch.switched.restored["data"]["sessionId"] == jf_switch.state["data"]["sessionId"]
            @test jf_switch.switched.restored["data"]["messageCount"] == pi_switch.switched.restored["data"]["messageCount"]
            @test !jf_switch.switched.invalid["success"] && !pi_switch.switched.invalid["success"]
            @test jf_switch.switched.after["data"]["sessionId"] == jf_switch.state["data"]["sessionId"]

            pidir, jfdir = joinpath(workspace, "pi-sessions"), joinpath(workspace, "jf-sessions")
            pi_saved = Cmd(`node $oracle $source --mode json --session-dir $pidir --provider openai --model fixture hello`; dir=workspace)
            jf_saved = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project -m JuliaForever --mode json --session-dir $jfdir hello`; dir=workspace)
            pi_first = runprocess(pi_saved, "", env)
            jf_first = runprocess(jf_saved, "", env)
            pi_resume = Cmd(`node $oracle $source --mode rpc --continue --session-dir $pidir --provider openai --model fixture`; dir=workspace)
            jf_resume = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project -m JuliaForever --mode rpc --continue --session-dir $jfdir`; dir=workspace)
            inspection = join(JSON3.write.([(; id="messages", type="get_messages"), (; id="state", type="get_state"), (; id="last", type="get_last_assistant_text")]), "\n") * "\n"
            pi_again = runprocess(pi_resume, inspection, env)
            jf_again = runprocess(jf_resume, inspection, env)
            @test pi_first.status == jf_first.status == pi_again.status == jf_again.status == 0
            pi_restored, jf_restored = responses(pi_again.output), responses(jf_again.output)
            @test jf_restored["last"] == pi_restored["last"]
            @test jf_restored["state"]["data"]["messageCount"] == pi_restored["state"]["data"]["messageCount"]
            @test [m["role"] for m in jf_restored["messages"]["data"]["messages"]] == [m["role"] for m in pi_restored["messages"]["data"]["messages"]]
            @test jf_restored["state"]["data"]["sessionId"] == first(records(jf_first.output))["id"]
            @test isfile(jf_restored["state"]["data"]["sessionFile"])

            arrivals = Channel{Channel{Nothing}}(Inf)
            gated = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
                gate = Channel{Nothing}(1)
                put!(arrivals, gate)
                take!(gate)
                HTTP.Response(200, ["Content-Type" => "text/event-stream"], body)
            end
            try
                gatedbase = "http://$(HTTP.server_addr(gated))/v1"
                write(joinpath(agentdir, "models.json"), JSON3.write(Dict("providers" => Dict("openai" => Dict("baseUrl" => gatedbase, "api" => "openai-completions", "apiKey" => "fixture", "models" => [Dict("id" => "fixture")])))))
                gatedenv = [pair for pair in env if first(pair) != "OPENAI_BASE_URL"]
                push!(gatedenv, "OPENAI_BASE_URL" => gatedbase)
                pi_queue = exchangequeued(pi_rpc, gatedenv, arrivals)
                jf_queue = exchangequeued(jf_rpc, gatedenv, arrivals)
                @test jf_queue.first == pi_queue.first
                @test jf_queue.steer == pi_queue.steer
                @test jf_queue.follow == pi_queue.follow
                @test jf_queue.busy == pi_queue.busy
                usertexts(run) = [join(block["text"] for block in message["content"] if block["type"] == "text") for message in run.messages["data"]["messages"] if message["role"] == "user"]
                @test usertexts(jf_queue) == usertexts(pi_queue)
                pi_abort = exchangeaborted(pi_rpc, gatedenv, arrivals)
                jf_abort = exchangeaborted(jf_rpc, gatedenv, arrivals)
                @test jf_abort.reply == pi_abort.reply
                @test jf_abort.settled == pi_abort.settled == Dict("type" => "agent_settled", "aborted" => true)
                reasons(run) = [event["message"]["stopReason"] for event in run.observed if event["type"] == "message_end" && get(event["message"], "role", "") == "assistant"]
                @test reasons(jf_abort) == reasons(pi_abort) == ["aborted"]
            finally
                close(gated)
                wait(gated)
            end

            call = Dict("index" => 0, "id" => "call-1", "type" => "function", "function" => Dict("name" => "read", "arguments" => ""))
            fragments = [Dict("role" => "assistant", "tool_calls" => [call]), Dict("tool_calls" => [Dict("index" => 0, "function" => Dict("arguments" => "{\"path\":\"target.txt\"}"))]), Dict()]
            toolchunks = [Dict("id" => "fixture", "object" => "chat.completion.chunk", "created" => 1, "model" => "fixture", "choices" => [Dict("index" => 0, "delta" => delta, "finish_reason" => finish)]) for (delta, finish) in zip(fragments, (nothing, nothing, "tool_calls"))]
            toolbody = join(("data: " * JSON3.write(chunk) * "\n\n" for chunk in toolchunks)) * "data: [DONE]\n\n"
            write(joinpath(workspace, "target.txt"), "alpha\n")
            toolserver = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
                try
                    data = JSON3.read(codeunits(String(request.body)))
                    aftertool = any(message -> message.role == "tool", data.messages)
                    HTTP.Response(200, ["Content-Type" => "text/event-stream"], aftertool ? body : toolbody)
                catch exception
                    println(stderr, "Tool fixture failed: ", sprint(showerror, exception))
                    HTTP.Response(500)
                end
            end
            try
                toolbase = "http://$(HTTP.server_addr(toolserver))/v1"
                write(joinpath(agentdir, "models.json"), JSON3.write(Dict("providers" => Dict("openai" => Dict("baseUrl" => toolbase, "api" => "openai-completions", "apiKey" => "fixture", "models" => [Dict("id" => "fixture")])))))
                toolenv = [pair for pair in env if first(pair) != "OPENAI_BASE_URL"]
                push!(toolenv, "OPENAI_BASE_URL" => toolbase)
                pi_tools = runprocess(pi, "", toolenv)
                jf_tools = runprocess(jf, "", toolenv)
                @test pi_tools.status == jf_tools.status == 0
                @test count(event -> event["type"] == "tool_execution_end", records(pi_tools.output)) == 1
                @test eventview.(records(jf_tools.output)) == eventview.(records(pi_tools.output))
            finally
                close(toolserver)
                wait(toolserver)
            end
        end
    finally
        close(server)
        wait(server)
    end
end

end
