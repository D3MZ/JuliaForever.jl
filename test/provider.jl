using JSON3

@testset "OpenAI-compatible provider" begin
    mktempdir() do dir
        log = joinpath(dir, "requests.json")
        server = open(`node $(joinpath(@__DIR__, "provider.mjs")) $log`, "r")
        port = parse(Int, readline(server))
        agent = Agent(OpenAI("http://127.0.0.1:$port/v1", "test-model", "test-key"), [Write(dir), Read(dir), Edit(dir)])
        @test respond!(agent, "create a file") == "done"
        close(server)
        requests = JSON3.read(read(log, String))
        @test length(requests) == 2
        @test requests[1].authorization == "Bearer test-key"
        @test requests[1].target == "/v1/chat/completions"
        @test requests[1].body.model == "test-model"
        @test requests[2].body.messages[end].role == "tool"
        @test requests[2].body.messages[end].tool_call_id == "call-1"
        @test read(joinpath(dir, "a.txt"), String) == "hello"
    end
end
