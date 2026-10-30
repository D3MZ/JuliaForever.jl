@testset "repository ignore scope dispatch" begin
    mktempdir() do dir
        write(joinpath(dir, ".gitignore"), "ignored.txt\n")
        rules = JuliaForever.IgnoreRule[]
        JuliaForever.gitignore!(rules, dir, Find(dir), nothing)
        @test length(rules) == 1
        empty!(rules)
        JuliaForever.gitignore!(rules, dir, Grep(dir), nothing)
        @test isempty(rules)
        JuliaForever.gitignore!(rules, dir, Grep(dir), dir)
        @test length(rules) == 1
    end
end

function searchfixture(dir)
    mkpath(joinpath(dir, ".git"))
    mkpath(joinpath(dir, "src", "deep"))
    mkpath(joinpath(dir, "other"))
    mkpath(joinpath(dir, "node_modules", "dep"))
    write(joinpath(dir, ".gitignore"), "ignored.txt\nnode_modules/\n*.log\n!keep.log\n")
    write(joinpath(dir, "src", ".gitignore"), "local.txt\n")
    write(joinpath(dir, "root.txt"), "alpha\nBeta needle\nomega\nneedle again\n")
    write(joinpath(dir, ".hidden.txt"), "hidden needle\n")
    write(joinpath(dir, "src", "deep", "sample.spec.ts"), "needle\n")
    write(joinpath(dir, "src", "local.txt"), "needle\n")
    write(joinpath(dir, "other", "local.txt"), "needle\n")
    write(joinpath(dir, "ignored.txt"), "needle\n")
    write(joinpath(dir, "node_modules", "dep", "file.txt"), "needle\n")
    write(joinpath(dir, "keep.log"), "needle\n")
    write(joinpath(dir, "skip.log"), "needle\n")
    write(joinpath(dir, "binary.txt"), UInt8[0x6e, 0x65, 0x65, 0x64, 0x6c, 0x65, 0x00])
end

@testset "file URL paths" begin
    @test JuliaForever.fileurlpath("file:///C:/Users/Example%20User/note.txt", true) == "C:/Users/Example User/note.txt"
    @test JuliaForever.fileurlpath("file://server/share/note%20one.txt", true) == "//server/share/note one.txt"
    @test JuliaForever.fileurlpath("file:///tmp/note%20one.txt", false) == "/tmp/note one.txt"
    mktempdir() do dir
        write(joinpath(dir, "space file.txt"), "needle\n")
        normalized = replace(dir, '\\' => '/', " " => "%20")
        url = (Sys.iswindows() ? "file:///" : "file://") * normalized * "/space%20file.txt"
        @test execute(Grep(dir), (; pattern="needle", path=url)).text == "space file.txt:1: needle"
    end
end

@testset "native find and grep" begin
    mktempdir() do dir
        searchfixture(dir)
        finder = Find(dir)
        grepper = Grep(dir)
        @test Set(split(execute(finder, (; pattern="*.txt")).text, '\n')) == Set([".hidden.txt", "binary.txt", "other/local.txt", "root.txt"])
        @test execute(finder, (; pattern="src/**/*.spec.ts")).text == "src/deep/sample.spec.ts"
        @test execute(finder, (; pattern="*.nope")).text == "No files found matching pattern"
        @test execute(finder, (; pattern="*.txt", path="other")).text == "local.txt"
        @test execute(finder, (; pattern="*.txt", path="missing")).text == "[fd error]: Search path '$(joinpath(dir, "missing"))' is not a directory.\n[fd error]: No valid search paths given."
        @test execute(finder, (; pattern="root.txt", limit=0)).text == "root.txt\n\n[0 results limit reached. Use limit=0 for more, or refine pattern]"
        @test execute(finder, (; pattern="*.txt", limit=1)).text |> t -> occursin("[1 results limit reached. Use limit=2 for more, or refine pattern]", t)
        @test execute(grepper, (; pattern="needle", path="root.txt")).text == "root.txt:2: Beta needle\nroot.txt:4: needle again"
        @test execute(grepper, (; pattern="NEEDLE", path="root.txt", ignoreCase=true, context=1, limit=1)).text == "root.txt-1- alpha\nroot.txt:2: Beta needle\nroot.txt-3- omega\n\n[1 matches limit reached. Use limit=2 for more, or refine pattern]"
        @test execute(grepper, (; pattern="^Beta", path="root.txt")).text == "root.txt:2: Beta needle"
        @test execute(grepper, (; pattern="^Beta", path="root.txt", literal=true)).text == "No matches found"
        write(joinpath(dir, "literal.dat"), "CAFÉ [x]\ncafé [x]\n")
        @test execute(grepper, (; pattern="café [x]", path="literal.dat", literal=true)).text == "literal.dat:2: café [x]"
        @test execute(grepper, (; pattern="café [x]", path="literal.dat", literal=true, ignoreCase=true)).text == "literal.dat:1: CAFÉ [x]\nliteral.dat:2: café [x]"
        @test execute(grepper, (; pattern="needle", glob="*.ts")).text == "src/deep/sample.spec.ts:1: needle"
        @test Set(split(execute(grepper, (; pattern="needle")).text, '\n')) == Set([".hidden.txt:1: hidden needle", "keep.log:1: needle", "other/local.txt:1: needle", "root.txt:2: Beta needle", "root.txt:4: needle again", "src/deep/sample.spec.ts:1: needle"])
        @test Set(split(execute(grepper, (; pattern="needle", glob="*.txt")).text, '\n')) == Set([".hidden.txt:1: hidden needle", "ignored.txt:1: needle", "other/local.txt:1: needle", "root.txt:2: Beta needle", "root.txt:4: needle again", "src/local.txt:1: needle"])
        @test execute(grepper, (; pattern="needle", path="root.txt", context=1)).text == "root.txt-1- alpha\nroot.txt:2: Beta needle\nroot.txt-3- omega\nroot.txt-3- omega\nroot.txt:4: needle again\nroot.txt-5- "
        @test execute(grepper, (; pattern="needle", path="missing")).iserror
        @test execute(grepper, (; pattern="[", path="root.txt")).iserror
        write(joinpath(dir, "empty"), "")
        @test execute(grepper, (; pattern="", path="empty")).text == "No matches found"
        write(joinpath(dir, "long.txt"), repeat("x", 501) * "needle\n")
        long = execute(grepper, (; pattern="needle", path="long.txt"))
        @test long.text == "long.txt:1: " * repeat("x", 500) * "... [truncated]\n\n[Some lines truncated to 500 chars. Use read tool to see full lines]"
        @test JuliaForever.name(finder) == "find"
        @test JuliaForever.name(grepper) == "grep"
        @test JuliaForever.schema(finder)["required"] == ["pattern"]
        @test JuliaForever.schema(grepper)["required"] == ["pattern"]
    end
end

@testset "ignore scope and output limits" begin
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
        @test execute(Find(dir), (; pattern="*.secret")).text == "No files found matching pattern"
        @test execute(Grep(dir), (; pattern="needle", path="top.secret")).text == "top.secret:1: needle"
        @test Set(split(execute(Grep(dir), (; pattern="needle")).text, '\n')) == Set(["one/local.txt:1: needle", "two/local.txt:1: needle", "top.secret:1: needle"])
        @test execute(Find(dir), (; pattern="local.txt")).text == "two/local.txt"
        @test execute(Find(dir), (; pattern="*.ignore")).text == ".ignore"
    end
    mktempdir() do dir
        for i in 1:230
            write(joinpath(dir, "file-" * lpad(i, 3, '0') * "-" * repeat("x", 230)), "")
        end
        result = execute(Find(dir), (; pattern="file-*"))
        @test endswith(result.text, "\n\n[50.0KB limit reached]")
        @test ncodeunits(first(split(result.text, "\n\n"))) <= 51200
        write(joinpath(dir, "matches.txt"), repeat(repeat("x", 500) * "needle\n", 110))
        result = execute(Grep(dir), (; pattern="needle", path="matches.txt", limit=200))
        @test endswith(result.text, "\n\n[50.0KB limit reached. Some lines truncated to 500 chars. Use read tool to see full lines]")
        @test ncodeunits(first(split(result.text, "\n\n"))) <= 51200
    end
end

function nestedfixture(dir)
    mkpath(joinpath(dir, ".git", "info"))
    mkpath(joinpath(dir, "nested", ".git", "info"))
    write(joinpath(dir, ".gitignore"), "blocked.txt\n")
    write(joinpath(dir, ".ignore"), "local-only.txt\n")
    write(joinpath(dir, ".git", "info", "exclude"), "private.txt\n")
    write(joinpath(dir, "blocked.txt"), "needle\n")
    write(joinpath(dir, "private.txt"), "needle\n")
    write(joinpath(dir, "nested", "blocked.txt"), "needle\n")
    write(joinpath(dir, "nested", "private.txt"), "needle\n")
    write(joinpath(dir, "nested", "local-only.txt"), "needle\n")
    write(joinpath(dir, "nested", ".git", "info", "exclude"), "nested-secret.txt\n")
    write(joinpath(dir, "nested", "nested-secret.txt"), "needle\n")
end

@testset "nested repository ignore boundaries" begin
    mktempdir() do dir
        nestedfixture(dir)
        @test length(unique(typeof.(first(JuliaForever.initialrules(joinpath(dir, "nested"), Find(dir)))))) == 2
        @test execute(Find(dir), (; pattern="blocked.txt")).text == "nested/blocked.txt"
        @test execute(Find(dir), (; pattern="private.txt")).text == "nested/private.txt"
        @test execute(Find(dir), (; pattern="local-only.txt")).text == "No files found matching pattern"
        @test execute(Find(dir), (; pattern="nested-secret.txt")).text == "No files found matching pattern"
        @test Set(split(execute(Grep(dir), (; pattern="needle")).text, '\n')) == Set(["nested/blocked.txt:1: needle", "nested/private.txt:1: needle"])
    end
end
