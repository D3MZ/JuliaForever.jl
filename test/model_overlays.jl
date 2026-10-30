using Test, JuliaForever, JSON3

@testset "Pi custom model catalog" begin
    M = JuliaForever.Models
    mktempdir() do dir
        path = joinpath(dir, "models.json")
        write(path, JSON3.write((; providers=(; fixture=(; baseUrl="http://127.0.0.1:1", api="openai-completions", apiKey="fixture-key", models=[(; id="alpha"), (; id="beta", name="Beta", reasoning=true, input=["text", "image"], contextWindow=64000, maxTokens=4000)], modelOverrides=(; alpha=(; name="Overridden", maxTokens=1234))), anthropic=(; models=[(; id="claude-sonnet-4-20250514", name="Replacement")], modelOverrides=Dict("claude-sonnet-4-20250514" => (; reasoning=true, contextWindow=32000)))))))
        source = ENV["PI_SOURCE"]
        @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
        expected = JSON3.read(read(`node --conditions=source --experimental-strip-types $(joinpath(@__DIR__, "model_overlays_pi.mjs")) $source $path`), Vector{M.Model})
        actual = filter(m -> (m.provider == "fixture" || (m.provider == "anthropic" && m.id == "claude-sonnet-4-20250514")), M.catalog(path))
        @test sort(actual; by=m -> (m.provider, m.id)) == sort(expected; by=m -> (m.provider, m.id))
        @test any(m -> m.provider == "anthropic" && m.id != "claude-sonnet-4-20250514", M.catalog(path))
        result = M.resolve("fixture/Overridden", actual, Set(["fixture"]))
        @test result isa M.Resolved && result.model.id == "alpha"
    end
    mktempdir() do dir
        path = joinpath(dir, "models.json")
        write(path, "\ufeff{\n// fixture comment\n\"providers\": {\"fixture\": {\"baseUrl\": \"http://127.0.0.1:1/v1\", \"api\": \"openai-completions\", \"apiKey\": \"//literal,}\", \"models\": [{\"id\": \"alpha\", \"name\": \"quote \\\" // literal\",},],},},}\n")
        source = ENV["PI_SOURCE"]
        expected = JSON3.read(read(`node --conditions=source --experimental-strip-types $(joinpath(@__DIR__, "model_overlays_pi.mjs")) $source $path`), Vector{M.Model})
        actual = filter(m -> m.provider == "fixture", M.catalog(path))
        @test actual == filter(m -> m.provider == "fixture", expected)
        write(path, "{ /* unsupported */ \"providers\": {} }")
        @test M.load(path) isa M.InvalidConfig
    end

end
