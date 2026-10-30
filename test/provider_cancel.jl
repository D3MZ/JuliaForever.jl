using Test, JuliaForever, HTTP, JSON3
import JuliaForever.History as H
import JuliaForever.Conversation as C

cancelchunks(::OpenAI) = [Dict("choices" => [Dict("delta" => Dict("content" => "partial"))])]
cancelchunks(::OpenAIResponses) = [Dict("type" => "response.output_text.delta", "output_index" => 0, "item_id" => "m", "content_index" => 0, "delta" => "partial")]
cancelchunks(::Anthropic) = [
    Dict("type" => "message_start", "message" => Dict("id" => "m", "role" => "assistant", "model" => "fixture", "content" => [], "usage" => Dict("input_tokens" => 1, "output_tokens" => 0))),
    Dict("type" => "content_block_start", "index" => 0, "content_block" => Dict("type" => "text", "text" => "")),
    Dict("type" => "content_block_delta", "index" => 0, "delta" => Dict("type" => "text_delta", "text" => "partial")),
]
cancelchunks(::Google) = [Dict("candidates" => [Dict("content" => Dict("role" => "model", "parts" => [Dict("text" => "partial")]))])]
canceljson(::OpenAI) = Dict("choices" => [Dict("message" => Dict("role" => "assistant", "content" => "done"), "finish_reason" => "stop")])
canceljson(::OpenAIResponses) = Dict("status" => "completed", "output" => [Dict("type" => "message", "role" => "assistant", "content" => [Dict("type" => "output_text", "text" => "done")])])
canceljson(::Anthropic) = Dict("content" => [Dict("type" => "text", "text" => "done")], "stop_reason" => "end_turn")
canceljson(::Google) = Dict("candidates" => [Dict("content" => Dict("role" => "model", "parts" => [Dict("text" => "done")]), "finishReason" => "STOP")])

@testset "cancel stalled provider requests" begin
    for provider in (OpenAI, OpenAIResponses, Anthropic, Google), streamed in (false, true), partial in (false, true), recorded in (false, true)
        partial && !streamed && continue
        ready, release = Channel{Nothing}(1), Channel{Nothing}(1)
        server = HTTP.listen!("127.0.0.1", 0; listenany=true) do io
            HTTP.startread(io)
            read(io)
            if partial
                HTTP.setheader(io, "Content-Type" => "text/event-stream")
                HTTP.startwrite(io)
                for chunk in cancelchunks(provider("", "fixture", "synthetic"))
                    write(io, "data: ", JSON3.write(chunk), "\n\n")
                end
                flush(io)
            else
                put!(ready, nothing)
            end
            take!(release)
            if !partial
                HTTP.setheader(io, "Content-Type" => streamed ? "text/event-stream" : "application/json")
                HTTP.startwrite(io)
                if streamed
                    for chunk in cancelchunks(provider("", "fixture", "synthetic"))
                        write(io, "data: ", JSON3.write(chunk), "\n\n")
                    end
                else
                    write(io, JSON3.write(canceljson(provider("", "fixture", "synthetic"))))
                end
            end
        end
        task = nothing
        try
            model = provider("http://$(HTTP.server_addr(server))/v1", "fixture", "synthetic")
            history = recorded ? H.Memory() : nothing
            agent = Agent(model, []; history)
            seen = String[]
            callback = event -> begin
                if event.type == :text
                    push!(seen, event.text)
                    put!(ready, nothing)
                end
            end
            task = Threads.@spawn respond!(agent, "start"; on_event=streamed ? callback : nothing)
            @test timedwait(() -> isready(ready) || istaskdone(task), 15; pollint=0.01) == :ok
            @test isready(ready)
            if isready(ready)
                take!(ready)
                @test cancel!(agent) === true
                stopped = timedwait(() -> istaskdone(task), 2; pollint=0.01)
                @test stopped == :ok
                stopped == :ok || put!(release, nothing)
                @test fetch(task) == :cancelled
                @test !agent.running
                @test agent.fault === nothing
                @test isempty(agent.state.kernel.pending)
                @test agent.state.phase in (C.Cancelled, C.Incomplete)
                @test seen == (partial ? ["partial"] : String[])
                if recorded
                    restored = Agent(model, []; history)
                    @test restored.fault === nothing
                    @test isempty(restored.state.kernel.pending)
                end
            end
        finally
            isready(release) || put!(release, nothing)
            close(server)
            wait(server)
            task === nothing || wait(task)
        end
    end
end

@testset "cancel before a request is registered" begin
    agent = Agent(OpenAI("http://127.0.0.1:1/v1", "fixture", "synthetic"), [])
    @test JuliaForever.begin!(agent)
    @test cancel!(agent)
    context = HTTP.RequestContext()
    JuliaForever.register!(agent, context)
    @test HTTP.canceled(context)
    JuliaForever.unregister!(agent, context)
end

@testset "provider HTTP failures remain typed" begin
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        HTTP.Response(401, [], "unauthorized")
    end
    try
        model = OpenAI("http://$(HTTP.server_addr(server))/v1", "fixture", "synthetic")
        for callback in (nothing, identity)
            agent = Agent(model, [])
            result = respond!(agent, "start"; on_event=callback)
            @test result isa Completion && result.error isa ProviderStatus && result.error.status == 401
            @test !occursin("unauthorized", sprint(show, result))
            @test !agent.running
        end
    finally
        close(server)
        wait(server)
    end
end
