module ModelCompletionTests

using Test, JuliaForever, JSON3

@testset "model argument suggestions match Pi" begin
    C = JuliaForever.LiveTerminal.Completion
    M = JuliaForever.Models
    models = [M.Model("openai", "gpt-4o-mini", "GPT-4o Mini"), M.Model("openai", "gpt-5", "GPT Five"), M.Model("openrouter", "openai/gpt-5", "OpenAI GPT Five"), M.Model("fixture", "α-model", "Special Alpha"), M.Model("fixture", "model-2", "Model Two")]
    queries = ["", "gpt", "gpt 5", "openai/gpt-5", "router gpt", "special", "2model", "α", "no matches"]
    actual = [[model.provider * "/" * model.id for model in C.suggestmodels(models, query)] for query in queries]
    if haskey(ENV, "PI_SOURCE")
        source = ENV["PI_SOURCE"]
        @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
        mktemp() do path, io
            JSON3.write(io, (; models, queries))
            flush(io)
            oracle = JSON3.read(read(`node $(joinpath(@__DIR__, "model_completion_pi.mjs")) $source $path`, String), Vector{Vector{String}})
            @test actual == oracle
        end
    end
    @test "openai/gpt-5" in actual[4]
    @test isempty(actual[end])
    @test JuliaForever.LiveTerminal.modelargument("openrouter/openai/gpt-5", models) == "openai/gpt-5"
    @test JuliaForever.LiveTerminal.modelargument("custom/unknown", models) == "custom/unknown"
end

end
