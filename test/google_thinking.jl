using Test, JuliaForever, HTTP, JSON3
isdefined(Main, :models_process) || include_string(Main, first(split(read(joinpath(@__DIR__, "terminal_models.jl"), String), "@testset")), joinpath(@__DIR__, "terminal_models.jl"))

@testset "Google thinking suffixes" begin
    requests = []
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        push!(requests, (; target=request.target, key=HTTP.header(request, "x-goog-api-key"), body=JSON3.read(String(request.body), Dict{String, Any})))
        event = Dict("candidates" => [Dict("content" => Dict("parts" => [Dict("thought" => true, "text" => "thought", "thoughtSignature" => "c2ln"), Dict("text" => "ok")]), "finishReason" => "STOP")])
        HTTP.Response(200, ["Content-Type" => "text/event-stream"], "data: $(JSON3.write(event))\n\n")
    end
    try
        mktempdir() do workspace
            base = "http://$(HTTP.server_addr(server))"
            for (id, levels) in (("gemini-3-flash-preview", ("off", "minimal", "low", "medium", "high")), ("gemini-3.1-pro-preview", ("off", "low", "medium", "high")))
                for level in levels
                    result = models_process(base, workspace, ["--model", "google/$id:$level", "hello"])
                    @test result.status == 0
                    body = requests[end].body
                    if haskey(ENV, "PI_SOURCE")
                        source = ENV["PI_SOURCE"]
                        @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
                        reference = JSON3.read(read(`node $(joinpath(@__DIR__, "google_thinking_pi.mjs")) $source $id $level`, String), Dict{String, Any})
                        @test body["generationConfig"]["thinkingConfig"] == reference["generationConfig"]["thinkingConfig"]
                    end
                end
            end

        end
    finally
        close(server)
        wait(server)
    end
end
