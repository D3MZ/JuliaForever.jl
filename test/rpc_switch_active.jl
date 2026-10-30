module RPCSwitchActiveTests

using Test, JuliaForever, JSON3, HTTP

function receive!(channel, observed, predicate)
    while true
        timedwait(() -> isready(channel), 45) == :ok || error("Timed out waiting for RPC output")
        value = take!(channel)
        push!(observed, value)
        predicate(value) && return value
    end
end

function responsebody(deltas, finishes)
    chunks = [Dict("id" => "fixture", "object" => "chat.completion.chunk", "created" => 1, "model" => "fixture", "choices" => [Dict("index" => 0, "delta" => delta, "finish_reason" => finish)]) for (delta, finish) in zip(deltas, finishes)]
    join(("data: " * JSON3.write(chunk) * "\n\n" for chunk in chunks)) * "data: [DONE]\n\n"
end

textbody() = responsebody([Dict("role" => "assistant", "content" => "ready"), Dict()], [nothing, "stop"])
function toolbody()
    call = Dict("index" => 0, "id" => "call-1", "type" => "function", "function" => Dict("name" => "bash", "arguments" => ""))
    args = JSON3.write(Dict("command" => raw"echo $$ > started; sleep 30; echo late > late"))
    responsebody([Dict("role" => "assistant", "tool_calls" => [call]), Dict("tool_calls" => [Dict("index" => 0, "function" => Dict("arguments" => args))]), Dict()], [nothing, nothing, "tool_calls"])
end

function contents(message)
    content = get(message, "content", "")
    content isa AbstractString && return content
    content isa AbstractVector || return ""
    join(get(part, "text", "") for part in content)
end

usermessages(response) = [contents(message) for message in response["data"]["messages"] if message["role"] == "user"]
files(path) = [isfile(path * suffix) ? read(path * suffix) : nothing for suffix in ("", "-wal")]
alive(pid) = ccall(:kill, Cint, (Cint, Cint), pid, 0) == 0

function exchange(cmd, env, workspace, gate, arrivals, mode)
    mktempdir() do dir
        diagnostics = joinpath(dir, "diagnostics")
        process = open(pipeline(addenv(cmd, env...); stderr=diagnostics), "r+")
        channel = Channel{Any}(Inf)
        observed = Any[]
        reader = @async for line in eachline(process)
            put!(channel, JSON3.read(line, Dict{String, Any}))
        end
        try
            send(value) = (println(process, JSON3.write(value)); flush(process))
            reply(id) = receive!(channel, observed, value -> get(value, "id", "") == id)
            send((; id="seed", type="prompt", message="seed"))
            receive!(channel, observed, value -> get(value, "type", "") == "agent_settled")
            send((; id="target", type="get_state"))
            target = reply("target")["data"]
            send((; id="new", type="new_session"))
            @test reply("new")["success"]
            if mode in (:blocked_target, :fault_target, :missing_model)
                history = JuliaForever.History.Tree(open(JuliaForever.History.SQLite, target["sessionFile"]; create=false))
                targetagent = Agent(nothing, []; history)
                if mode == :blocked_target
                    @test steer!(targetagent, "target queued") === nothing
                elseif mode == :missing_model
                    JuliaForever.transition!(revision -> JuliaForever.Conversation.SessionRecord(revision, "missing-model", nothing, "2026-01-01T00:00:00Z", JuliaForever.Conversation.ModelEntry("missing", "missing")), targetagent)
                else
                    JuliaForever.transition!(revision -> JuliaForever.Conversation.Input(revision, "target pending"), targetagent)
                    JuliaForever.transition!(revision -> JuliaForever.Conversation.Advance(revision), targetagent)
                end
                close(history)
            end
            message = mode == :tool ? "waiting-tool" : "waiting-provider"
            send((; id="active", type="prompt", message))
            @test reply("active")["success"]
            if mode == :tool
                receive!(channel, observed, value -> get(value, "type", "") == "tool_execution_start")
                @test timedwait(() -> isfile(joinpath(workspace, "started")) && !isempty(read(joinpath(workspace, "started"), String)), 45) == :ok
            else
                @test timedwait(() -> isready(arrivals), 45) == :ok
                take!(arrivals)
            end
            if mode == :queued
                send((; id="queued", type="steer", message="queued input"))
                @test reply("queued")["success"]
            end
            send((; id="source", type="get_state"))
            source = reply("source")["data"]
            before = (files(source["sessionFile"]), files(target["sessionFile"]))
            send((; id="invalid", type="switch_session", sessionPath=workspace))
            invalid = reply("invalid")
            send((; id="after-invalid", type="get_state"))
            afterinvalid = reply("after-invalid")["data"]
            unchanged = before == (files(source["sessionFile"]), files(target["sessionFile"]))
            chosen = mode == :same ? source : target
            before = (files(source["sessionFile"]), files(target["sessionFile"]))
            firstswitch = length(observed)
            send((; id="switch", type="switch_session", sessionPath=chosen["sessionFile"]))
            switched = reply("switch")
            during = observed[firstswitch+1:end]
            settled = findfirst(value -> get(value, "type", "") == "agent_settled", during)
            unchanged_switch = before == (files(source["sessionFile"]), files(target["sessionFile"]))
            send((; id="selected", type="get_state"))
            selected = reply("selected")["data"]
            send((; id="messages", type="get_messages"))
            messages = reply("messages")
            replay = nothing
            replaystate = nothing
            if switched["success"] && !isnothing(settled)
                send((; id="replay", type="switch_session", sessionPath=source["sessionFile"]))
                replayed = reply("replay")
                if replayed["success"]
                    send((; id="source-messages", type="get_messages"))
                    replay = reply("source-messages")
                    send((; id="source-state", type="get_state"))
                    replaystate = reply("source-state")["data"]
                end
            end
            exited = mode != :tool || !alive(parse(Int, strip(read(joinpath(workspace, "started"), String))))
            (; invalid, afterinvalid, source, target, chosen, switched, during, settled, selected, messages, replay, replaystate, unchanged, unchanged_switch, exited, late=isfile(joinpath(workspace, "late")), diagnostics=read(diagnostics, String))
        finally
            isready(gate) || put!(gate, nothing)
            close(process.in)
            timedwait(() -> process_exited(process), 5) == :ok || kill(process)
            wait(process)
            wait(reader)
        end
    end
end

function exercise(kind, mode)
    mktempdir() do root
        workspace = realpath(root)
        gate, arrivals = Channel{Nothing}(1), Channel{Nothing}(1)
        server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
            data = String(request.body)
            body = if occursin("waiting-provider", data)
                put!(arrivals, nothing)
                take!(gate)
                textbody()
            elseif occursin("waiting-tool", data)
                toolbody()
            else
                textbody()
            end
            HTTP.Response(200, ["Content-Type" => "text/event-stream"], body)
        end
        try
            base = "http://$(HTTP.server_addr(server))/v1"
            agentdir = joinpath(workspace, "agent")
            mkpath(agentdir)
            config = Dict("providers" => Dict("openai" => Dict("baseUrl" => base, "api" => "openai-completions", "apiKey" => "synthetic-switch-key", "models" => [Dict("id" => "fixture")])))
            write(joinpath(agentdir, "models.json"), JSON3.write(config))
            env = ["HOME" => workspace, "USERPROFILE" => workspace, "PI_CODING_AGENT_DIR" => agentdir, "PI_OFFLINE" => "1", "JF_INSTRUCTIONS_DIR" => workspace, "JF_CHATGPT_DIR" => joinpath(workspace, "chatgpt"), "JF_OPENROUTER_DIR" => joinpath(workspace, "router"), "JF_PROVIDER" => "openai", "OPENAI_MODEL" => "fixture", "OPENAI_API_KEY" => "synthetic-switch-key", "OPENAI_BASE_URL" => base, "OPENROUTER_API_KEY" => nothing, "ANTHROPIC_API_KEY" => nothing, "GEMINI_API_KEY" => nothing, "TERM" => "dumb"]
            project = dirname(@__DIR__)
            sessions = joinpath(workspace, "sessions")
            cmd = if kind == :pi
                source = ENV["PI_SOURCE"]
                @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
                Cmd(`node $(joinpath(@__DIR__, "headless_reference.mjs")) $source --mode rpc --session-dir $sessions --provider openai --model fixture --approve`; dir=workspace)
            else
                mode == :missing_model ? Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project -m JuliaForever --mode rpc --session-dir $sessions --provider openai`; dir=workspace) : Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project -m JuliaForever --mode rpc --session-dir $sessions --provider openai --model fixture`; dir=workspace)
            end
            exchange(cmd, env, workspace, gate, arrivals, mode)
        finally
            isready(gate) || put!(gate, nothing)
            close(server)
            wait(server)
        end
    end
end

@testset "switching an active RPC session settles its outgoing turn" begin
    for mode in (Sys.isunix() ? (:provider, :same, :tool, :queued, :blocked_target, :fault_target, :missing_model) : (:provider, :same, :queued, :blocked_target, :fault_target, :missing_model))
        kinds = mode in (:blocked_target, :fault_target, :missing_model) || !haskey(ENV, "PI_SOURCE") ? (:julia,) : (:pi, :julia)
        results = Dict(kind => exercise(kind, mode) for kind in kinds)
        for (kind, result) in results
            @test !result.invalid["success"] && result.unchanged
            @test result.afterinvalid["sessionId"] == result.source["sessionId"] && result.afterinvalid["isStreaming"]
            if mode in (:blocked_target, :fault_target, :missing_model) || (mode == :queued && kind == :julia)
                @test !result.switched["success"] && result.unchanged_switch
                @test result.selected["sessionId"] == result.source["sessionId"] && result.selected["isStreaming"]
                @test result.selected["pendingMessageCount"] == (mode == :queued ? 1 : 0)
                @test usermessages(result.messages) == ["waiting-provider"]
                @test !occursin("synthetic-switch-key", result.diagnostics)
                continue
            end
            @test result.switched["success"] && result.selected["sessionId"] == result.chosen["sessionId"]
            @test !isnothing(result.settled) && result.during[result.settled]["aborted"]
            @test !result.selected["isStreaming"]
            expected = mode == :same ? ["waiting-provider"] : ["seed"]
            @test usermessages(result.messages) == expected
            @test !isnothing(result.replay) && usermessages(result.replay) == [mode == :tool ? "waiting-tool" : "waiting-provider"]
            if mode == :queued
                @test !isnothing(result.replaystate) && result.replaystate["pendingMessageCount"] == 0
            end
            @test result.exited && !result.late && !occursin("synthetic-switch-key", result.diagnostics)
            if mode == :tool
                ended = findfirst(value -> get(value, "type", "") == "tool_execution_end", result.during)
                @test !isnothing(ended) && !isnothing(result.settled) && ended < result.settled
            end
        end
    end
end

end
