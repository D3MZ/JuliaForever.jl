using Test, JuliaForever, HTTP

@testset "provider image attachments are not dropped" begin
    requests = Threads.Atomic{Int}(0)
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        Threads.atomic_add!(requests, 1)
        HTTP.Response(200, ["Content-Type" => "application/json"], "{}")
    end
    try
        url = "http://$(HTTP.server_addr(server))"
        messages = [Dict{String, Any}("role" => "tool", "tool_call_id" => "image-1", "content" => "read image", "image" => Dict("mime" => "image/png", "data" => "cG5n"))]
        for model in (Anthropic(url, "fixture", "synthetic"), Google(url, "fixture", "synthetic"))
            @test JuliaForever.payload(model, messages, Dict(), Dict()) isa UnsupportedImage
            seen = []
            completed = JuliaForever.complete(model, messages, Dict())
            streamed = JuliaForever.stream(model, messages, Dict(); on_event=event -> push!(seen, event))
            @test !completed.done && completed.error isa UnsupportedImage
            @test !streamed.done && streamed.error isa UnsupportedImage
            @test length(seen) == 1 && seen[1].type == :incomplete
            output = IOBuffer()
            terminal = JuliaForever.Terminal(IOBuffer(), output, ["synthetic"])
            @test JuliaForever.result!(terminal, completed) == 1
            @test occursin("image", lowercase(String(take!(output))))
        end
        @test requests[] == 0
    finally
        close(server)
        wait(server)
    end
end
