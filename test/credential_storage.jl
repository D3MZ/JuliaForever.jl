using Test, JuliaForever, JSON3

if haskey(ENV, "PI_SOURCE")
    @testset "persisted API keys against Pi" begin
        mktempdir() do dir
            env = Dict("PI_CODING_AGENT_DIR" => dir, "JF_PROVIDER" => "openai", "OPENAI_MODEL" => "fixture", "OPENAI_API_KEY" => "fixture-env")
            path = joinpath(dir, "auth.json")
            oracle = joinpath(@__DIR__, "credential_reference.mjs")
            reference() = JSON3.read(read(`node $oracle $(ENV["PI_SOURCE"]) $path`, String))
            for key in ("fixture-stored", "")
                write(path, JSON3.write(Dict("openai" => Dict("type" => "api_key", "key" => key))))
                @test JuliaForever.provider(env).key == reference()
            end
        end
    end
end
