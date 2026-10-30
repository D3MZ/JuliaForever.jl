module ImageAgentBoundaryTests

using Test, JuliaForever, HTTP, JSON3, Distributed
const E = JuliaForever.Execution
@testset "unsupported tool images stop the next provider request" begin
    requests = Threads.Atomic{Int}(0)
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        Threads.atomic_add!(requests, 1)
        if occursin("messages", request.target)
            data = Dict("id" => "msg-fixture", "type" => "message", "role" => "assistant", "content" => [Dict("type" => "tool_use", "id" => "call-1", "name" => "read", "input" => Dict("path" => "pixel.png"))], "stop_reason" => "tool_use", "usage" => Dict("input_tokens" => 1, "output_tokens" => 1))
        else
            data = Dict("candidates" => [Dict("content" => Dict("role" => "model", "parts" => [Dict("functionCall" => Dict("id" => "call-1", "name" => "read", "args" => Dict("path" => "pixel.png")))]), "finishReason" => "STOP")])
        end
        HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write(data))
    end
    try
        base = "http://$(HTTP.server_addr(server))"
        mktempdir() do root
            cp(joinpath(@__DIR__, "fixtures", "pixel.png"), joinpath(root, "pixel.png"))
            for (name, model) in ((:anthropic, Anthropic(base, "fixture", "synthetic")), (:google, Google(base, "gemini-3-fixture", "synthetic")))
                @testset "$name direct" begin
                    requests[] = 0
                    agent = Agent(model, [Read(root)])
                    result = respond!(agent, "read the image")
                    @test result isa Completion && !result.done && result.error isa UnsupportedImage
                    @test requests[] == 1
                end
                @testset "$name executor" begin
                    requests[] = 0
                    context = "image-review-$name"
                    @test E.install!(context, model, [Read(root)])
                    pool = E.Executor(myid())
                    try
                        agent = Agent(nothing, [])
                        result = respond!(agent, "read the image"; executor=pool, context)
                        @test result isa E.Turn
                        @test last(result.models).error isa UnsupportedImage
                        @test requests[] == 1
                    finally
                        close(pool)
                        E.uninstall!(context)
                    end
                end
            end
        end
    finally
        close(server)
        wait(server)
    end
end

end
