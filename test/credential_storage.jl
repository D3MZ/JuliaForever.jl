using Test, JuliaForever, JSON3

@testset "persisted API keys" begin
    mktempdir() do dir
        env = Dict("PI_CODING_AGENT_DIR" => dir, "JF_PROVIDER" => "openai", "OPENAI_MODEL" => "fixture", "OPENAI_API_KEY" => "fixture-env")
        path = joinpath(dir, "auth.json")
        @test JuliaForever.provider(env).key == "fixture-env"
        emptyenv = merge(env, Dict("OPENAI_API_KEY" => ""))
        @test JuliaForever.provider(emptyenv) === nothing
        @test !JuliaForever.configured(emptyenv, JuliaForever.providerinfo("openai"), nothing)
        write(path, JSON3.write(Dict("openai" => Dict("type" => "api_key", "key" => "fixture-stored"))))
        Sys.iswindows() || chmod(path, 0o640)
        @test JuliaForever.provider(env).key == "fixture-stored"
        if haskey(ENV, "PI_SOURCE")
            oracle = joinpath(@__DIR__, "credential_reference.mjs")
            reference() = JSON3.read(read(`node $oracle $(ENV["PI_SOURCE"]) $path`, String))
            @test JuliaForever.provider(env).key == reference()
        end
        Sys.iswindows() || @test stat(path).mode & 0o777 == 0o640
        @test JSON3.read(read(path, String)).openai.key == "fixture-stored"
        @test !occursin("fixture-stored", repr(JuliaForever.provider(env)))
        for (selected, variable, stored) in (("openrouter", "OPENROUTER_API_KEY", "openrouter"), ("anthropic", "ANTHROPIC_API_KEY", "anthropic"), ("google", "GEMINI_API_KEY", "google"))
            info = JuliaForever.providerinfo(selected)
            isnothing(info) && continue
            write(path, JSON3.write(Dict(stored => Dict("type" => "api_key", "key" => "fixture-stored"))))
            other = Dict("PI_CODING_AGENT_DIR" => dir, "JF_PROVIDER" => selected, info.model => "fixture", variable => "fixture-env")
            @test JuliaForever.configured(other, info, nothing)
            @test JuliaForever.provider(other).key == "fixture-stored"
        end
        write(path, "{broken")
        @test JuliaForever.provider(env).key == "fixture-env"
        write(path, JSON3.write(Dict("openai" => Dict("type" => "api_key", "key" => ""))))
        @test JuliaForever.provider(env).key == "fixture-env"
        haskey(ENV, "PI_SOURCE") && @test JuliaForever.provider(env).key == reference()
        for key in ("!fixture-command", "\$FIXTURE_SECRET")
            write(path, JSON3.write(Dict("openai" => Dict("type" => "api_key", "key" => key))))
            @test JuliaForever.provider(env) === nothing
            @test !JuliaForever.configured(env, JuliaForever.providerinfo("openai"), nothing)
        end
        write(path, JSON3.write(Dict("openai" => Dict("type" => "oauth", "access" => "fixture-oauth"))))
        @test JuliaForever.provider(env) === nothing
    end
end
