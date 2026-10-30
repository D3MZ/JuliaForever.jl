module RPCParentSessionTests
using Test, JuliaForever, JSON3, HTTP

@testset "RPC new session lineage persists on reopen" begin
    if haskey(ENV, "PI_SOURCE")
        source = ENV["PI_SOURCE"]
        @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
        reference = JSON3.read(read(`node $(joinpath(@__DIR__, "rpc_parent_reference.mjs")) $source`, String))
        @test !reference.before && reference.parent == "../missing parent.jsonl" && reference.reopened == reference.parent
    end
    mktempdir() do root
        gate, arrivals = Channel{Nothing}(1), Channel{Nothing}(1)
        server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
            if occursin("waiting-parent", String(request.body))
                put!(arrivals, nothing)
                take!(gate)
            end
            chunks = [Dict("id" => "fixture", "object" => "chat.completion.chunk", "created" => 1, "model" => "fixture", "choices" => [Dict("index" => 0, "delta" => delta, "finish_reason" => finish)]) for (delta, finish) in [(Dict("role" => "assistant", "content" => "ok"), nothing), (Dict(), "stop")]]
            body = join("data: " * JSON3.write(chunk) * "\n\n" for chunk in chunks) * "data: [DONE]\n\n"
            HTTP.Response(200, ["Content-Type" => "text/event-stream"], body)
        end
        try
            project = dirname(@__DIR__)
            cmd = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project -m JuliaForever --mode rpc --session-dir $(joinpath(root, "sessions"))`; dir=root)
            env = ["HOME" => root, "JF_INSTRUCTIONS_DIR" => root, "JF_PROVIDER" => "openai", "OPENAI_MODEL" => "fixture", "OPENAI_API_KEY" => "fixture", "OPENAI_BASE_URL" => "http://$(HTTP.server_addr(server))/v1"]
            process = open(pipeline(addenv(cmd, env...); stderr=devnull), "r+")
            channel = Channel{Any}(Inf)
            reader = @async for line in eachline(process)
                put!(channel, JSON3.read(line, Dict{String, Any}))
            end
            send(value) = (println(process, JSON3.write(value)); flush(process))
            function receive(predicate)
                while true
                    timedwait(() -> isready(channel), 45) == :ok || error("RPC timeout")
                    value = take!(channel)
                    predicate(value) && return value
                end
            end
            reply(id) = receive(value -> get(value, "id", "") == id)
            try
                parent = "../missing parent.jsonl"
                send((; id="new", type="new_session", parentSession=parent))
                new = reply("new")
                @test new["success"]
                new["success"] || return
                send((; id="state", type="get_state"))
                state = reply("state")["data"]
                @test !isdir(joinpath(root, "sessions")) || isempty(readdir(joinpath(root, "sessions")))
                send((; id="prompt", type="prompt", message="hello"))
                receive(value -> get(value, "type", "") == "agent_settled")
                send((; id="saved", type="get_state"))
                path = reply("saved")["data"]["sessionFile"]
                send((; id="other", type="new_session"))
                @test reply("other")["success"]
                send((; id="reopen", type="switch_session", sessionPath=path))
                @test reply("reopen")["success"]
                history = JuliaForever.SessionCatalog.wrap(open(JuliaForever.History.SQLite, path; create=false))
                @test JuliaForever.SessionCatalog.parent(history) == parent
                agent = JuliaForever.Agent(nothing, []; history)
                data = JuliaForever.exportsnapshot(agent, history)
                output = IOBuffer()
                JuliaForever.writeexport(output, JuliaForever.ExportJSONL(), data)
                header = JSON3.read(first(split(String(take!(output)), "\n")))
                @test header.parentSession == parent
                close(history)
                @test !isempty(state["sessionId"])
                send((; id="active", type="prompt", message="waiting-parent"))
                @test reply("active")["success"]
                @test timedwait(() -> isready(arrivals), 45) == :ok
                take!(arrivals)
                send((; id="active-new", type="new_session", parentSession="active parent"))
                @test reply("active-new")["success"]
                send((; id="active-state", type="get_state"))
                active = reply("active-state")["data"]
                @test !active["isStreaming"] && active["sessionId"] != state["sessionId"]
                put!(gate, nothing)
                @test timedwait(() -> !isready(gate), 45) == :ok
                send((; id="blocked-active", type="prompt", message="waiting-parent"))
                @test reply("blocked-active")["success"]
                @test timedwait(() -> isready(arrivals), 45) == :ok
                take!(arrivals)
                images = [(; type="image", mimeType="image/png", data="iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/aX0AAAAASUVORK5CYII=")]
                send((; id="queued-image", type="steer", message="keep", images))
                @test reply("queued-image")["success"]
                send((; id="blocked-new", type="new_session", parentSession="must not replace"))
                @test !reply("blocked-new")["success"]
                send((; id="blocked-state", type="get_state"))
                blocked = reply("blocked-state")["data"]
                @test blocked["sessionId"] == active["sessionId"] && blocked["isStreaming"] && blocked["pendingMessageCount"] == 1
                current = JuliaForever.SessionCatalog.wrap(open(JuliaForever.History.SQLite, blocked["sessionFile"]; create=false))
                @test JuliaForever.SessionCatalog.parent(current) == "active parent"
                close(current)
            finally
                isready(gate) || put!(gate, nothing)
                close(process.in)
                timedwait(() -> process_exited(process), 5) == :ok || kill(process)
                wait(process); wait(reader)
            end
        finally
            isready(gate) || put!(gate, nothing)
            close(server); wait(server)
        end
    end
end
end
