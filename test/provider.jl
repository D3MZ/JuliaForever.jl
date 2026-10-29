using HTTP, JSON3

@testset "OpenAI-compatible provider" begin
    mktempdir() do dir
        requests = []
        server = HTTP.serve!("127.0.0.1", 0) do request
            push!(requests, (; target=request.target, authorization=HTTP.header(request, "Authorization"), body=JSON3.read(String(request.body))))
            message = if length(requests) == 1
                Dict("role" => "assistant", "content" => nothing, "tool_calls" => [Dict("id" => "call-1", "type" => "function", "function" => Dict("name" => "write", "arguments" => JSON3.write((; path="a.txt", content="hello"))))])
            else
                Dict("role" => "assistant", "content" => "done")
            end
            HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write((; choices=[(; message)])))
        end
        try
            agent = Agent(OpenAI("http://127.0.0.1:$(HTTP.port(server))/v1", "test-model", "test-key"), [Write(dir), Read(dir), Edit(dir)])
            @test respond!(agent, "create a file") == "done"
            @test length(requests) == 2
            @test requests[1].authorization == "Bearer test-key"
            @test requests[1].target == "/v1/chat/completions"
            @test requests[1].body.model == "test-model"
            @test requests[2].body.messages[end].role == "tool"
            @test requests[2].body.messages[end].tool_call_id == "call-1"
            @test read(joinpath(dir, "a.txt"), String) == "hello"
        finally
            close(server)
        end
    end
end
