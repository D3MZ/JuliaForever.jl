using Test, JuliaForever, JSON3

@testset "persisted API keys" begin
    mktempdir() do dir
        env = Dict("PI_CODING_AGENT_DIR" => dir, "JF_PROVIDER" => "openai", "OPENAI_MODEL" => "fixture", "OPENAI_API_KEY" => "fixture-env")
        path = joinpath(dir, "auth.json")
        @test JuliaForever.provider(env).key == "fixture-env"
        write(path, JSON3.write(Dict("openai" => Dict("type" => "api_key", "key" => "fixture-stored"))))
        chmod(path, 0o640)
        @test JuliaForever.provider(env).key == "fixture-stored"
        if haskey(ENV, "PI_SOURCE")
            oracle = joinpath(@__DIR__, "credential_reference.mjs")
            reference() = JSON3.read(read(`node $oracle $(ENV["PI_SOURCE"]) $path`, String))
            @test JuliaForever.provider(env).key == reference()
        end
        @test stat(path).mode & 0o777 == 0o640
        @test JSON3.read(read(path, String)).openai.key == "fixture-stored"
        write(path, "{broken")
        @test JuliaForever.provider(env).key == "fixture-env"
        write(path, JSON3.write(Dict("openai" => Dict("type" => "api_key", "key" => ""))))
        @test JuliaForever.provider(env).key == "fixture-env"
        haskey(ENV, "PI_SOURCE") && @test JuliaForever.provider(env).key == reference()
        write(path, JSON3.write(Dict("openai" => Dict("type" => "oauth", "access" => "fixture-oauth"))))
        @test JuliaForever.provider(env) === nothing
    end
end
