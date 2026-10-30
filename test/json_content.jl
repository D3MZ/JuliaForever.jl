module JSONContentTests

using Test, JuliaForever, JSON3, HTTP, SQLite
import JuliaForever.Durable as D
import JuliaForever.History as H

const MCP = JuliaForever.MCP
const S = JuliaForever.Sessions
const value = "\U00010000\U0010fffd"

struct Echo <: JuliaForever.Tool end
JuliaForever.name(::Echo) = "echo"
JuliaForever.description(::Echo) = "Echo Unicode."
JuliaForever.schema(::Echo) = Dict("type" => "object")
JuliaForever.execute(::Echo, args) = ToolSuccess(value)

struct Phase <: D.Phase
    value::String
end
D.encode(phase::Phase) = D.Checkpoint("fixture", phase.value)
struct Handler <: D.Handler end
D.name(::Handler) = "fixture"

# A valid JSON document can also be an existing filename on Unix. It exposes
# accidental path interpretation locally while the Unicode cases run on Windows.
function spoof(json, replacement)
    if Sys.isunix()
        @test sizeof(json) < 255
        write(json, replacement)
    end
end

@testset "JSON content and Unicode" begin
    @testset "provider tool history" begin
        mktempdir() do dir
            cd(dir) do
                arguments = JSON3.write((; value))
                spoof(arguments, JSON3.write((; value="spoof")))
                call = Dict("id" => "one", "type" => "function", "function" => Dict("name" => "example", "arguments" => arguments))
                history = [Dict("role" => "assistant", "content" => nothing, "tool_calls" => [call])]
                anthropic = JSON3.read(codeunits(JuliaForever.payload(Anthropic("http://fixture", "model", "key"), history, Dict(), Dict())))
                google = JSON3.read(codeunits(JuliaForever.payload(Google("http://fixture", "gemini-3-fixture", "key"), history, Dict(), Dict())))
                @test anthropic.messages[1].content[1].input.value == value
                @test google.contents[1].parts[1].functionCall.args.value == value
                call["function"]["arguments"] = "{\"value\":"
                @test_throws ArgumentError JuliaForever.payload(Anthropic("http://fixture", "model", "key"), history, Dict(), Dict())
                @test_throws ArgumentError JuliaForever.payload(Google("http://fixture", "gemini-3-fixture", "key"), history, Dict(), Dict())
            end
        end
    end

    @testset "credential contents" begin
        mktempdir() do dir
            cd(dir) do
                env = Dict("PI_CODING_AGENT_DIR" => dir, "JF_PROVIDER" => "openai", "OPENAI_MODEL" => "model", "OPENAI_API_KEY" => "fallback")
                json = JSON3.write(Dict("openai" => Dict("type" => "api_key", "key" => value)))
                spoof(json, JSON3.write(Dict("openai" => Dict("type" => "api_key", "key" => "spoof"))))
                write("auth.json", "\ufeff" * json)
                @test JuliaForever.provider(env).key == value
                write("auth.json", "{broken")
                @test JuliaForever.provider(env).key == "fallback"
            end
        end
    end

    @testset "session record" begin
        mktempdir() do dir
            cd(dir) do
                fields = Dict("message" => Dict("role" => "user", "content" => value))
                spoof(JSON3.write(fields), JSON3.write(Dict("message" => Dict("role" => "user", "content" => "spoof"))))
                session = S.Session("session.jsonl"; cwd=dir)
                S.record!(session, "message", fields)
                @test only(S.messages(session))["content"] == value
            end
        end
    end

    @testset "session reopen" begin
        mktempdir() do dir
            cd(dir) do
                header = (; type="session", version=3, id="one", timestamp="2020", cwd=dir)
                row = (; type="message", id="two", parentId=nothing, timestamp="2020", message=(; role="user", content=value))
                json = JSON3.write(row)
                write("session.jsonl", JSON3.write(header) * "\n" * json * "\n")
                spoof(json, "{broken")
                session = open(S.Session, "session.jsonl")
                @test session isa S.Session
                session isa S.Session && @test only(S.messages(session))["content"] == value
                write("invalid.jsonl", JSON3.write(header) * "\n{broken\n")
                @test open(S.Session, "invalid.jsonl") == S.Rejected(:invalid_session)
            end
        end
    end

    @testset "SQLite history" begin
        mktempdir() do dir
            cd(dir) do
                history = open(H.SQLite, "history.sqlite")
                try
                    @test H.append!(history, 0, Any[value]) == 1
                    spoof(JSON3.write([value]), JSON3.write(["spoof"]))
                    @test collect(H.snapshot(history)) == [value]
                    SQLite.execute(history.db, "UPDATE jf_history SET data = ?", ("[broken",))
                    @test H.snapshot(history) == H.Rejected(:history_format)
                finally
                    close(history)
                end
            end
        end
    end

    @testset "durable copy" begin
        mktempdir() do dir
            cd(dir) do
                record = D.Conversation(1, value)
                spoof(JSON3.write(D.encode(record)), JSON3.write(D.encode(D.Conversation(1, "spoof"))))
                @test D.detach(record).value == value
            end
        end
    end

    @testset "scheduler checkpoints" begin
        mktempdir() do dir
            cd(dir) do
                phase = Phase(value)
                checkpoint = D.checkpoint(D.encode(phase))
                spoof(JSON3.write(checkpoint), JSON3.write(D.checkpoint(D.encode(Phase("spoof")))))
                for (result, status) in ((D.Next(phase), "pending"), (D.Sleep(phase, 10), "sleeping"), (D.Join(phase, [1]), "waiting"))
                    state = Dict{String, Any}("checkpoint" => Dict("name" => "fixture", "value" => "old"), "phase" => 1, "attempts" => 1, "message" => "old")
                    D.advance!(state, result)
                    @test state["checkpoint"] == checkpoint && state["status"] == status
                end
            end
        end
    end

    if Sys.isunix()
        @testset "scheduler admission" begin
            mktempdir() do dir
                cd(dir) do
                    scheduler = open(D.Scheduler, "scheduler.jsonl")
                    try
                        conversation = D.commit!(scheduler.store) do tx
                            id = D.mint!(tx)
                            D.put!(tx, D.Conversation(id, nothing))
                            id
                        end
                        handler, phase = Handler(), Phase("start")
                        initial = D.checkpoint(D.encode(phase))
                        spec = Dict("kind" => D.name(handler), "input" => value, "initial" => initial, "maxattempts" => 3)
                        replacement = merge(spec, Dict("input" => "spoof"))
                        spoof(JSON3.write(spec), JSON3.write(replacement))
                        id = D.enqueue!(scheduler, conversation, handler, phase, value)
                        @test get(scheduler, id).input == value
                    finally
                        close(scheduler)
                    end
                end
            end
        end

        @testset "durable recovery" begin
            mktempdir() do dir
                cd(dir) do
                    store = open(D.Store, "durable.jsonl")
                    id = D.commit!(store) do tx
                        id = D.mint!(tx)
                        D.put!(tx, D.Conversation(id, value))
                        id
                    end
                    close(store)
                    spoof(chomp(read("durable.jsonl", String)), "{broken")
                    reopened = open(D.Store, "durable.jsonl")
                    @test reopened isa D.Store
                    if reopened isa D.Store
                        @test get(reopened, D.Conversation, id).value == value
                        close(reopened)
                    end
                    write("corrupt.jsonl", "{broken\n")
                    @test open(D.Store, "corrupt.jsonl") == D.Rejected(:corrupt_log)
                end
            end
        end
    end

    @testset "MCP stdio" begin
        mktempdir() do dir
            cd(dir) do
                script = joinpath(@__DIR__, "json_content_mcp_server.jl")
                cmd = `$(Base.julia_cmd()) --startup-file=no --project=$(dirname(Base.active_project())) $script`
                client = MCP.connect(cmd; timeout=15)
                @test client isa MCP.Client
                if client isa MCP.Client
                    try
                        result = MCP.call(client, "echo", Dict())
                        @test result isa AbstractDict && result["content"][1]["text"] == value
                    finally
                        close(client)
                    end
                end
            end
        end
    end

    @testset "MCP HTTP and SSE" begin
        mktempdir() do dir
            cd(dir) do
                server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
                    request.method == "DELETE" && return HTTP.Response(204)
                    message = JSON3.read(codeunits(String(request.body)), Dict{String, Any})
                    haskey(message, "id") || return HTTP.Response(202)
                    result = if message["method"] == "initialize"
                        Dict("protocolVersion" => "2025-06-18", "capabilities" => Dict("tools" => Dict()), "serverInfo" => Dict("name" => "fixture", "version" => "1"))
                    else
                        Dict("content" => [Dict("type" => "text", "text" => value)])
                    end
                    response = JSON3.write(Dict("jsonrpc" => "2.0", "id" => message["id"], "result" => result))
                    occursin(value, response) && spoof(response, "{}")
                    endswith(request.target, "/sse") ? HTTP.Response(200, ["Content-Type" => "text/event-stream"], "data: " * response * "\n\n") : HTTP.Response(200, ["Content-Type" => "application/json"], response)
                end
                try
                    for transport in ("json", "sse")
                        client = MCP.connect("http://127.0.0.1:$(HTTP.port(server))/$transport"; timeout=10)
                        @test client isa MCP.Client
                        if client isa MCP.Client
                            try
                                result = MCP.call(client, "echo", Dict())
                                @test result isa AbstractDict && result["content"][1]["text"] == value
                            finally
                                close(client)
                            end
                        end
                    end
                finally
                    close(server)
                    wait(server)
                end
            end
        end
    end

    @testset "CodeMode request" begin
        mktempdir() do dir
            cd(dir) do
                code = repr(value)
                request = JSON3.write((; code, store=Dict{String, Any}(), tools=[]))
                spoof(request, JSON3.write((; code="nothing", store=Dict(), tools=[])))
                result = JuliaForever.codeexecute(CodeMode(JuliaForever.Tool[]; timeout=30), code)
                @test result.ok && result.value == value
            end
        end
    end

    @testset "CodeMode text and store" begin
        mktempdir() do dir
            cd(dir) do
                spoof(JSON3.write((; type="text", text=value)), JSON3.write((; type="text", text="spoof")))
                spoof(JSON3.write(value), JSON3.write("spoof"))
                code = "text($(repr(value))); store(\"v\", $(repr(value))); load(\"v\")"
                result = JuliaForever.codeexecute(CodeMode(JuliaForever.Tool[]; timeout=30), code)
                @test result.ok && result.output == [value] && result.value == value && result.writes["v"] == value
            end
        end
    end

    @testset "CodeMode tool reply" begin
        mktempdir() do dir
            cd(dir) do
                reply = (; id=1, result=(; text=value, iserror=false))
                spoof(JSON3.write(reply), JSON3.write((; id=1, result=(; text="spoof", iserror=false))))
                result = JuliaForever.codeexecute(CodeMode([Echo()]; timeout=30), "tools.echo((;)).text")
                @test result.ok && result.value == value
            end
        end
    end
end

end
