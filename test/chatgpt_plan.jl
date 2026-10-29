using HTTP, JSON3

plansse(value) = "data: $(JSON3.write(value))\n\n"
plantext(value) = Dict("type" => "message", "id" => "msg-1", "status" => "completed", "role" => "assistant", "content" => [Dict("type" => "output_text", "text" => value)])
planresponse(output) = Dict("status" => "completed", "output" => output)
plancall = Dict("type" => "function_call", "id" => "fc-1", "call_id" => "call-1", "name" => "write", "arguments" => "{\"path\":\"plan.txt\",\"content\":\"fixture\"}", "status" => "completed")

@testset "ChatGPT plan streaming" begin
    pending = CG.Pending(CG.Register(), "urn:uuid:fixture")
    try
        session = fixtureexchange(pending, CG.Code("fixture-code", "oaiapp_fixture")).session
        received = Channel{Any}(4)
        replies = [plansse((; type="response.output_item.done", output_index=0, item=plancall)) * plansse((; type="response.completed", response=planresponse([plancall]))), plansse((; type="response.output_item.done", output_index=0, item=plantext("done"))) * plansse((; type="response.completed", response=planresponse([plantext("done")])))]
        server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
            put!(received, (; target=request.target, authorization=HTTP.header(request, "Authorization"), body=JSON3.read(String(request.body))))
            HTTP.Response(200, ["Content-Type" => "text/event-stream"], popfirst!(replies))
        end
        try
            calls = String[]
            post = (url, headers, body; kwargs...) -> begin
                push!(calls, url)
                HTTP.post("http://$(HTTP.server_addr(server))/v1/responses", headers, body; kwargs...)
            end
            model = CG.Plan("fixture-model", session; post, now=() -> identitytime)
            @test !occursin("synthetic-access", sprint(show, model))
            mktempdir() do dir
                agent = Agent(model, Dict{String, JuliaForever.Tool}("write" => Write(dir)), Dict{String, Any}[Dict("role" => "system", "content" => "fixture instructions")])
                answer = respond!(agent, "create file")
                @test answer == "done"
                answer == "done" || return
                @test read(joinpath(dir, "plan.txt"), String) == "fixture"
                first = take!(received)
                second = take!(received)
                @test calls == ["https://api.openai.com/v1/responses", "https://api.openai.com/v1/responses"]
                @test first.authorization == "Bearer synthetic-access"
                @test first.body.model == "fixture-model"
                @test first.body.stream === true && first.body.store === false
                @test !haskey(first.body, :tools)
                @test first.body.input[1].type == "additional_tools" && first.body.input[1].role == "developer"
                @test first.body.input[1].tools[1].type == "function" && first.body.input[1].tools[1].name == "write"
                @test first.body.input[2].role == "developer" && first.body.input[2].content == "fixture instructions"
                @test "reasoning.encrypted_content" in first.body.include
                @test second.body.input[end].type == "function_call_output"
                @test second.body.input[end].call_id == "call-1"
                for parameters in (Dict("store" => true), Dict("stream" => false), Dict("temperature" => 1), Dict("previous_response_id" => "unsafe"), Dict("tools" => []))
                    @test !JuliaForever.stream(model, [], Dict(); parameters).done
                end
                @test length(calls) == 2
            end
            expired = CG.Plan("fixture-model", session; post, now=() -> identitytime + 3600)
            @test !JuliaForever.stream(expired, [], Dict()).done
            missing = CG.Session(session.client, session.identity, session.access, session.refresh, session.id_token, "openid", session.expires)
            @test !JuliaForever.stream(CG.Plan("fixture-model", missing; post, now=() -> identitytime), [], Dict()).done
            @test length(calls) == 2
        finally
            close(server)
            wait(server)
        end
    finally
        close(pending)
    end
end

@testset "ChatGPT plan rejects foreign tool namespaces" begin
    pending = CG.Pending(CG.Register(), "urn:uuid:fixture")
    try
        session = fixtureexchange(pending, CG.Code("fixture-code", "oaiapp_fixture")).session
        foreign = merge(plancall, Dict("namespace" => "foreign"))
        replies = [plansse((; type="response.output_item.done", output_index=0, item=foreign)) * plansse((; type="response.completed", response=planresponse([foreign]))), plansse((; type="response.output_item.done", output_index=0, item=plancall)) * plansse((; type="response.completed", response=planresponse([foreign]))), plansse((; type="response.failed", response=Dict("status" => "failed", "output" => [], "error" => Dict("message" => "fixture failure")))), plansse((; type="response.failed", response=planresponse([]))), plansse((; type="response.failed", response=Dict("status" => "failed", "output" => []))) * plansse((; type="response.completed", response=planresponse([])))]
        server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
            HTTP.Response(200, ["Content-Type" => "text/event-stream"], popfirst!(replies))
        end
        try
            post = (url, headers, body; kwargs...) -> HTTP.post("http://$(HTTP.server_addr(server))/v1/responses", headers, body; kwargs...)
            model = CG.Plan("fixture-model", session; post, now=() -> identitytime)
            @test !JuliaForever.stream(model, [], Dict()).done
            @test !JuliaForever.stream(model, [], Dict()).done
            @test !JuliaForever.stream(model, [], Dict()).done
            @test !JuliaForever.stream(model, [], Dict()).done
            @test !JuliaForever.stream(model, [], Dict()).done
        finally
            close(server)
            wait(server)
        end
    finally
        close(pending)
    end
end

@testset "ChatGPT nonrenewable direct grant" begin
    grant = CG.Grant("oaiapp_fixture", CG.Identity("account-fixture", nothing), "synthetic-access", "synthetic-id-token", identityscope, identitytime + 3600)
    output = plantext("ok")
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        HTTP.Response(200, ["Content-Type" => "text/event-stream"], plansse((; type="response.output_item.done", output_index=0, item=output)) * plansse((; type="response.completed", response=planresponse([output]))))
    end
    try
        post = (url, headers, body; kwargs...) -> HTTP.post("http://$(HTTP.server_addr(server))/v1/responses", headers, body; kwargs...)
        result = JuliaForever.stream(CG.Plan("fixture-model", grant; post, now=() -> identitytime), [], Dict())
        @test result.done && result.message["content"] == "ok"
    finally
        close(server)
        wait(server)
    end
end
