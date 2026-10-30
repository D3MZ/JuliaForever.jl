using Test, JuliaForever

function history_validation(args)
    mktemp() do path, io
        status = redirect_stderr(io) do
            JuliaForever.main(args)
        end
        flush(io)
        seekstart(io)
        (; status, diagnostics=read(io, String))
    end
end

@testset "history action validation" begin
    mktempdir() do dir
        path = joinpath(dir, "not-created.sqlite")
        inspect = "--inspect-history requires --history PATH and no prompt or --abandon.\n"
        abandon = "--abandon requires --history PATH and no prompt.\n"
        for args in (["--inspect-history"], ["--history", path, "--inspect-history", "prompt"], ["--history", path, "--inspect-history", "--abandon", "reason"], ["--history", path, "--abandon", "reason", "--inspect-history"], ["--history", path, "--inspect-history", "--name", "name"], ["--history", path, "--continue", "--inspect-history"], ["--history", path, "--login-openrouter", "--inspect-history"])
            @test history_validation(args) == (; status=2, diagnostics=inspect)
        end
        for args in (["--abandon", "reason"], ["--history", path, "--abandon", "reason", "prompt"], ["--history", path, "--abandon", "reason", "--name", "name"], ["--history", path, "--no-session", "--abandon", "reason"], ["--history", path, "--login-openrouter", "--abandon", "reason"])
            @test history_validation(args) == (; status=2, diagnostics=abandon)
        end
        @test !isfile(path)
        badprovider = history_validation(["--provider", "invalid", "--inspect-history"])
        @test badprovider.status == 2 && startswith(badprovider.diagnostics, "Unknown provider;")
        login = history_validation(["--provider", "anthropic", "--login-openrouter"])
        @test login == (; status=2, diagnostics="OpenRouter login requires --provider openrouter.\n")
        duplicate = history_validation(["--login-openrouter", "--login-openrouter-callback"])
        @test duplicate == (; status=2, diagnostics="Select only one OpenRouter login mode.\n")
        withenv("OPENROUTER_MODEL" => nothing) do
            @test history_validation(["--provider", "openrouter", "--login-openrouter"]) == (; status=2, diagnostics="Set OPENROUTER_MODEL.\n")
            @test history_validation(["--login-openrouter"]) == (; status=2, diagnostics="Set OPENROUTER_MODEL.\n")
        end
        withenv("OPENAI_MODEL" => nothing, "OPENAI_API_KEY" => nothing) do
            @test history_validation(["--provider", "openai"]) == (; status=2, diagnostics="Set OPENAI_MODEL and OPENAI_API_KEY.\n")
        end
    end
end
