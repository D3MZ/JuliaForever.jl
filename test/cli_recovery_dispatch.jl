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
    end
end
