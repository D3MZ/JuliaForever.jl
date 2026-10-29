using Test, JuliaForever, HTTP, JSON3

struct BrokenText <: AbstractString end
Base.codeunits(::BrokenText) = throw(Base.IOError("fixture", -1))
struct BrokenArgumentText <: AbstractString end
Base.codeunits(::BrokenArgumentText) = throw(ArgumentError("unrelated"))

@testset "typed invalid provider JSON" begin
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        body = JSON3.read(String(request.body))
        invalid = "{bad synthetic-secret raw-event}"
        request.target == "/v1/auth/keys" && return HTTP.Response(200, ["Content-Type" => "application/json"], invalid)
        if body.stream
            part = request.target == "/v1/responses" ? (; type="response.output_text.delta", delta="partial") : (; choices=[(; delta=(; content="partial"), finish_reason=nothing)])
            tail = request.target == "/v1/responses" ? (; type="response.output_text.delta", delta="ignored") : (; choices=[(; delta=(; content="ignored"), finish_reason="stop")])
            input = request.target == "/v1/responses" ? body.input : body.messages
            if !isempty(input) && input[end].content == "late"
                if request.target == "/v1/responses"
                    call = (; type="response.output_item.added", output_index=0, item=(; type="function_call", id="id", call_id="call"))
                    done = (; type="response.completed", response=(; status="completed", output=[]))
                    return HTTP.Response(200, ["Content-Type" => "text/event-stream"], "data: $(JSON3.write(part))\n\ndata: $(JSON3.write(call))\n\ndata: $(JSON3.write(done))\n\ndata: $invalid\n\n")
                end
                return HTTP.Response(200, ["Content-Type" => "text/event-stream"], "data: $(JSON3.write(part))\n\ndata: $(JSON3.write(tail))\n\ndata: $invalid\n\ndata: [DONE]\n\n")
            end
            payload = "data: $(JSON3.write(part))\n\ndata: $invalid\n\ndata: $(JSON3.write(tail))\n\ndata: [DONE]\n\n"
            return HTTP.Response(200, ["Content-Type" => "text/event-stream"], payload)
        end
        HTTP.Response(200, ["Content-Type" => "application/json"], invalid)
    end
    try
        base = "http://$(HTTP.server_addr(server))/v1"
        for model in (OpenAI(base, "fixture", "synthetic-secret"), OpenAIResponses(base, "fixture", "synthetic-secret"))
            events = []
            streamed = stream(model, [], Dict(); on_event=event -> push!(events, event))
            @test !streamed.done
            @test streamed.error isa JuliaForever.InvalidResponse
            @test streamed.message["content"] == "partial"
            @test [event.text for event in events if event.type == :text] == ["partial"]
            @test count(event -> event.type == :provider, events) == 1
            @test last(events).type == :incomplete
            late = stream(model, [Dict("role" => "user", "content" => "late")], Dict())
            @test !late.done && late.error isa InvalidResponse

            nonstreamed = JuliaForever.complete(model, [], Dict())
            @test !nonstreamed.done
            @test nonstreamed.error isa JuliaForever.InvalidResponse
            @test !occursin("synthetic-secret", sprint(show, nonstreamed))
            @test !occursin("raw-event", sprint(show, nonstreamed))

            agent = Agent(model, [])
            @test respond!(agent, "start").error isa JuliaForever.InvalidResponse
            @test respond!(Agent(model, []), "start"; on_event=identity).error isa JuliaForever.InvalidResponse
        end
        @test JuliaForever.exchange(JuliaForever.authorize(), "code"; base) isa JuliaForever.InvalidResponse
        @test_throws MethodError JuliaForever.decode(42)
        @test_throws Base.IOError JuliaForever.decode(BrokenText())
        @test_throws ArgumentError JuliaForever.decode(BrokenArgumentText())
        nested = try
            parse(Int, "not an integer")
        catch
            JuliaForever.decode("{\"ok\":1}")
        end
        @test nested["ok"] == 1
        mktemp() do path, io
            write(io, "{\"from_file\":true}")
            flush(io)
            @test JuliaForever.decode(path) isa InvalidResponse
        end
    finally
        close(server)
        wait(server)
    end
end
