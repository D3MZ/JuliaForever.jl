using Test, JuliaForever, HTTP, JSON3
isdefined(Main, :models_process) || include_string(Main, first(split(read(joinpath(@__DIR__, "terminal_models.jl"), String), "@testset")), joinpath(@__DIR__, "terminal_models.jl"))

@testset "model thinking suffix" begin
    requests = Channel{Any}(10)
    destinations = []
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        push!(destinations, (; target=request.target, authorization=HTTP.header(request, "Authorization", "")))
        put!(requests, JSON3.read(String(request.body), Dict{String, Any}))
        delta = JSON3.write((; type="response.output_text.delta", delta="fixture"))
        done = JSON3.write((; type="response.completed", response=(; status="completed", output=[(; type="message", content=[(; type="output_text", text="fixture")])])))
        HTTP.Response(200, ["Content-Type" => "text/event-stream"], "data: $delta\n\ndata: $done\n\n")
    end
    try
        mktempdir() do workspace
            base = "http://$(HTTP.server_addr(server))"
            result = models_process(base, workspace, ["--model", "openai/gpt-5.2:high", "hello"])
            @test result.status == 0
            @test isready(requests)
            if isready(requests)
                body = take!(requests)
                if haskey(ENV, "PI_SOURCE")
                    source = ENV["PI_SOURCE"]
                    @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
                    reference = JSON3.read(read(`node $(joinpath(@__DIR__, "thinking_pi.mjs")) $source`, String), Dict{String, Any})
                    @test body["reasoning"] == reference["reasoning"]
                    @test body["model"] == reference["exact"]
                    project = dirname(@__DIR__)
                    input = joinpath(source, "node_modules", "@earendil-works", "pi-ai", "dist", "providers", "data", "openai.json")
                    generated = joinpath(workspace, "thinking.json")
                    run(`$(Base.julia_cmd()) --startup-file=no --project=$project $(joinpath(project, "scripts", "openai_thinking.jl")) $input $generated`)
                    @test JSON3.read(read(generated), Dict{String, Any}) == JSON3.read(read(joinpath(project, "data", "openai-thinking.json")), Dict{String, Any})
                end
            end
            update = models_process(base, workspace, ["--model", "openai/gpt-6-luna:high", "hello"])
            @test update.status == 0 && isready(requests)
            body = isready(requests) ? take!(requests) : Dict{String, Any}()
            if haskey(ENV, "PI_SOURCE")
                source = ENV["PI_SOURCE"]
                pi = JSON3.read(read(`node $(joinpath(@__DIR__, "thinking_pi.mjs")) $source gpt-6-luna high`, String), Dict{String, Any})
                @test get(body, "reasoning", nothing) == pi["reasoning"]
                @test filter(item -> get(item, "type", nothing) == "configuration_update", get(body, "input", [])) == pi["updates"]
            end
            updateoff = models_process(base, workspace, ["--model", "openai/gpt-6-luna:off", "hello"])
            @test updateoff.status == 0 && isready(requests)
            if isready(requests)
                body = take!(requests)
                if haskey(ENV, "PI_SOURCE")
                    source = ENV["PI_SOURCE"]
                    pi = JSON3.read(read(`node $(joinpath(@__DIR__, "thinking_pi.mjs")) $source gpt-6-luna off`, String), Dict{String, Any})
                    @test body["reasoning"] == pi["reasoning"] && isempty(pi["updates"])
                    @test !any(item -> get(item, "type", nothing) == "configuration_update", body["input"])
                end
            end

        end
    finally
        close(server)
        wait(server)
    end
end
