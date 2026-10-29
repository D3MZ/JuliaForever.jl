@testset "Pi find and grep" begin
    @test readchomp(`git -C $(ENV["PI_SOURCE"]) rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
    cases = [
        (; tool="find", args=(; pattern="*.txt"), unordered=true),
        (; tool="find", args=(; pattern="src/**/*.spec.ts")),
        (; tool="find", args=(; pattern="*.nope")),
        (; tool="find", args=(; pattern="*.txt", path="missing")),
        (; tool="find", args=(; pattern="*.txt", path="root.txt")),
        (; tool="find", args=(; pattern="root.txt", limit=0)),
        (; tool="find", args=(; pattern="*.txt", path="other")),
        (; tool="find", args=(; pattern="*.ts", limit=1)),
        (; tool="find", args=(; pattern="*.TXT")),
        (; tool="find", args=(; pattern="*.txt"), unordered=true),
        (; tool="find", args=(; pattern="{root,keep}.*"), unordered=true),
        (; tool="find", args=(; pattern="src/**"), unordered=true),
        (; tool="find", args=(; pattern="other/*"), unordered=true),
        (; tool="find", args=(; pattern="upper.*")),
        (; tool="find", args=(; pattern="*space*")),
        (; tool="grep", args=(; pattern="needle", path="root.txt")),
        (; tool="grep", args=(; pattern="NEEDLE", path="root.txt", ignoreCase=true, context=1, limit=1)),
        (; tool="grep", args=(; pattern="^Beta", path="root.txt")),
        (; tool="grep", args=(; pattern="^Beta", path="root.txt", literal=true)),
        (; tool="grep", args=(; pattern="needle", glob="*.ts")),
        (; tool="grep", args=(; pattern="needle", path="missing")),
        (; tool="grep", args=(; pattern="needle", glob="*.txt"), unordered=true),
        (; tool="grep", args=(; pattern="needle", path="long.txt")),
        (; tool="grep", args=(; pattern="", path="empty")),
        (; tool="grep", args=(; pattern="needle", path="unicode.txt")),
        (; tool="grep", args=(; pattern="needle", path="root.txt", context=1)),
        (; tool="grep", args=(; pattern="needle"), unordered=true),
        (; tool="grep", args=(; pattern="needle", glob="!*.txt"), unordered=true),
        (; tool="grep", args=(; pattern="needle", glob="src/**/*.ts")),
        (; tool="grep", args=(; pattern="NEEDLE", path="UPPER.TXT", ignoreCase=true)),
        (; tool="grep", args=(; pattern="needle", path="@root.txt")),
        (; tool="grep", args=(; pattern="needle", path="root.txt", limit=0)),
    ]
    mktempdir() do dir
        searchfixture(dir)
        write(joinpath(dir, "empty"), "")
        write(joinpath(dir, "UPPER.TXT"), "needle\n")
        write(joinpath(dir, "space file.txt"), "needle\n")
        normalized = replace(dir, '\\' => '/', " " => "%20")
        url = (Sys.iswindows() ? "file:///" : "file://") * normalized * "/space%20file.txt"
        push!(cases, (; tool="grep", args=(; pattern="needle", path=url)))
        write(joinpath(dir, "trailing space "), "needle\n")
        write(joinpath(dir, "long.txt"), repeat("x", 501) * "needle\n")
        write(joinpath(dir, "unicode.txt"), repeat("🌱", 250) * "needle\n")
        input = tempname()
        write(input, JSON3.write(cases))
        try
            reference = JSON3.read(read(`node $(joinpath(@__DIR__, "search_reference.mjs")) $(ENV["PI_SOURCE"]) $dir $input`, String))
            for (index, case) in enumerate(cases)
                tool = case.tool == "find" ? Find(dir) : Grep(dir)
                result = execute(tool, case.args)
                @test result.iserror == reference[index].iserror
                actual = replace(result.text, dir => "<cwd>")
                expected = reference[index].text
                if get(case, :unordered, false)
                    @test sort(split(actual, '\n')) == sort(split(expected, '\n'))
                else
                    @test actual == expected
                end
            end
        finally
            rm(input; force=true)
        end
    end
end

@testset "Pi ignore scope and byte truncation" begin
    cases = [
        (; tool="find", args=(; pattern="*.secret")),
        (; tool="find", args=(; pattern="local.txt")),
        (; tool="find", args=(; pattern="*.ignore")),
        (; tool="grep", args=(; pattern="needle", glob="!matches.txt"), unordered=true),
        (; tool="grep", args=(; pattern="needle", path="matches.txt", limit=200)),
    ]
    mktempdir() do dir
        mkpath(joinpath(dir, "one"))
        mkpath(joinpath(dir, "two"))
        write(joinpath(dir, ".gitignore"), "*.secret\n")
        write(joinpath(dir, ".ignore"), "hidden.ignore\n")
        write(joinpath(dir, "one", ".gitignore"), "local.txt\n")
        write(joinpath(dir, "one", "local.txt"), "needle\n")
        write(joinpath(dir, "two", "local.txt"), "needle\n")
        write(joinpath(dir, "top.secret"), "needle\n")
        write(joinpath(dir, "hidden.ignore"), "needle\n")
        write(joinpath(dir, "matches.txt"), repeat(repeat("x", 500) * "needle\n", 110))
        input = tempname()
        write(input, JSON3.write(cases))
        try
            reference = JSON3.read(read(`node $(joinpath(@__DIR__, "search_reference.mjs")) $(ENV["PI_SOURCE"]) $dir $input`, String))
            for (index, case) in enumerate(cases)
                tool = case.tool == "find" ? Find(dir) : Grep(dir)
                result = execute(tool, case.args)
                @test result.iserror == reference[index].iserror
                if get(case, :unordered, false)
                    @test sort(split(result.text, '\n')) == sort(split(reference[index].text, '\n'))
                else
                    @test result.text == reference[index].text
                end
            end
        finally
            rm(input; force=true)
        end
    end
end

@testset "Pi nested repository ignore boundaries" begin
    cases = [
        (; tool="find", args=(; pattern="blocked.txt")),
        (; tool="find", args=(; pattern="private.txt")),
        (; tool="find", args=(; pattern="nested-secret.txt")),
        (; tool="grep", args=(; pattern="needle"), unordered=true),
    ]
    mktempdir() do dir
        nestedfixture(dir)
        input = tempname()
        write(input, JSON3.write(cases))
        try
            reference = JSON3.read(read(`node $(joinpath(@__DIR__, "search_reference.mjs")) $(ENV["PI_SOURCE"]) $dir $input`, String))
            for (index, case) in enumerate(cases)
                tool = case.tool == "find" ? Find(dir) : Grep(dir)
                result = execute(tool, case.args)
                @test result.iserror == reference[index].iserror
                if get(case, :unordered, false)
                    @test sort(split(result.text, '\n')) == sort(split(reference[index].text, '\n'))
                else
                    @test result.text == reference[index].text
                end
            end
        finally
            rm(input; force=true)
        end
    end
end
