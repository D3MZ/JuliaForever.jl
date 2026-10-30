@testset "Windows grep path parity" begin
    @test readchomp(`git -C $(ENV["PI_SOURCE"]) rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
    mktempdir() do dir
        mkpath(joinpath(dir, "nested"))
        write(joinpath(dir, "normal.txt"), "needle\n")
        write(joinpath(dir, "nested", "normal.txt"), "needle\n")
        write(joinpath(dir, "nullable.txt"), "needle\n")
        urlpath = replace(dir, '\\' => '/', " " => "%20")
        paths = ["nul", "NUL", "NuL.txt", "nested/nul", "nested\\NUL.txt", "./nul", "@nul", joinpath(dir, "nul"), "file:///" * urlpath * "/nul", "con", "prn.txt", "aux", "com1", "lpt1.txt", "nul ", "nul.", "nested/missing", "normal.txt", "nested/normal.txt", "nested\\normal.txt", "./normal.txt", "@normal.txt", "file:///" * urlpath * "/normal.txt", "nullable.txt"]
        cases = [(; tool="grep", args=(; pattern="needle", path)) for path in paths]
        input = tempname()
        try
            write(input, JSON3.write(cases))
            reference = JSON3.read(read(`node $(joinpath(@__DIR__, "search_reference.mjs")) $(ENV["PI_SOURCE"]) $dir $input`, String))
            for (index, case) in enumerate(cases)
                expected = reference[index]
                root = JuliaForever.searchpath(Grep(dir), case.args.path)
                println("WINDOWS_CASE ", JSON3.write((; path=case.args.path, pi=expected, julia_ispath=ispath(root), julia_ispath_stat=ispath(stat(root)), julia_isfile=isfile(root))))
                # The initial diagnostic avoids potentially blocking reads of console devices.
                if get(ENV, "JF_RED_DIAGNOSTIC", "") == "1" && !(case.args.path in ("nul", "normal.txt"))
                    continue
                end
                result = execute(Grep(dir), case.args)
                @test (result.iserror, replace(result.text, dir => "<cwd>")) == (expected.iserror, expected.text)
            end
        finally
            rm(input; force=true)
        end
    end
end
