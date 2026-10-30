@testset "grep matches CRLF without normalizing" begin
    mktempdir() do dir
        write(joinpath(dir, "mixed.txt"), "before\r\nneedle\r\nneedle\nafter\r\n")
        grepper = Grep(dir)
        @test execute(grepper, (; pattern="needle\$", path="mixed.txt", context=1)).text == "mixed.txt-2- needle\nmixed.txt:3: needle\nmixed.txt-4- after"
        @test execute(grepper, (; pattern="needle\r", path="mixed.txt", literal=true)).text == "mixed.txt:2: needle"
    end
end

@testset "repository boundary retains file ignores" begin
    mktempdir() do dir
        path = joinpath(dir, "ignore")
        write(path, "first\n!second/\n")
        file1, file2 = JuliaForever.rules(path, JuliaForever.FileRule)
        git1 = first(JuliaForever.rules(path, JuliaForever.GitRule))
        rules = JuliaForever.IgnoreRule[git1, file1, git1, file2, git1]
        @test JuliaForever.cleargit!(rules) === rules
        @test rules == JuliaForever.IgnoreRule[file1, file2]
        @test JuliaForever.cleargit!(rules) === rules
        @test rules == JuliaForever.IgnoreRule[file1, file2]
        onlygit = JuliaForever.IgnoreRule[git1, git1]
        @test isempty(JuliaForever.cleargit!(onlygit))
    end
end

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
    write(joinpath(dir, "other", "node_modules"), "")
    write(joinpath(dir, "ignored.txt"), "needle\n")
    write(joinpath(dir, "node_modules", "dep", "file.txt"), "needle\n")
    write(joinpath(dir, "keep.log"), "needle\n")
    write(joinpath(dir, "skip.log"), "needle\n")
    write(joinpath(dir, "binary.txt"), UInt8[0x6e, 0x65, 0x65, 0x64, 0x6c, 0x65, 0x00])
end

function ignorepriorityfixture(dir)
    mkpath(joinpath(dir, ".git"))
    mkpath(joinpath(dir, "sub"))
    mkpath(joinpath(dir, "deep"))
    write(joinpath(dir, ".gitignore"), "secret.txt\n")
    write(joinpath(dir, ".ignore"), "!visible.txt\nblocked.txt\n*.masked\n!keep.masked\nnested.txt\n")
    write(joinpath(dir, "sub", ".gitignore"), "visible.txt\n!blocked.txt\nkeep.masked\n!secret.txt\n")
    write(joinpath(dir, "sub", ".ignore"), "!nested.txt\nno.txt\n")
    for file in ("sub/visible.txt", "sub/blocked.txt", "sub/keep.masked", "sub/nested.txt", "sub/no.txt", "sub/secret.txt", "sub/open.txt", "deep/keep.masked", "deep/blocked.masked", "deep/secret.txt")
        write(joinpath(dir, split(file, '/')...), "needle\n")
    end
end

@testset "ignore file precedence" begin
    mktempdir() do dir
        ignorepriorityfixture(dir)
        grep = execute(Grep(dir), (; pattern="needle"))
        @test !grep.iserror
        @test Set(split(grep.text, '\n')) == Set(["sub/visible.txt:1: needle", "sub/keep.masked:1: needle", "sub/nested.txt:1: needle", "sub/secret.txt:1: needle", "sub/open.txt:1: needle", "deep/keep.masked:1: needle"])
        find = execute(Find(dir), (; pattern="*.txt"))
        @test !find.iserror
        @test Set(split(find.text, '\n')) == Set(["sub/visible.txt", "sub/nested.txt", "sub/secret.txt", "sub/open.txt"])
    end
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
        @test execute(finder, (; pattern="node_modules")).text == "other/node_modules"
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
        @test Set(split(execute(grepper, (; pattern="needle", glob="!*.txt")).text, '\n')) == Set(["keep.log:1: needle", "src/deep/sample.spec.ts:1: needle"])
        @test execute(grepper, (; pattern="needle", glob="!")).text == execute(grepper, (; pattern="needle")).text
        @test execute(grepper, (; pattern="needle", path="root.txt", context=1)).text == "root.txt-1- alpha\nroot.txt:2: Beta needle\nroot.txt-3- omega\nroot.txt-3- omega\nroot.txt:4: needle again\nroot.txt-5- "
        @test execute(grepper, (; pattern="needle", path="missing")).iserror
        @test execute(grepper, (; pattern="[", path="root.txt")).iserror
        write(joinpath(dir, "empty"), "")
        @test execute(grepper, (; pattern="", path="empty")).text == "No matches found"
        write(joinpath(dir, "long.txt"), repeat("x", 501) * "needle\n")
        long = execute(grepper, (; pattern="needle", path="long.txt"))
        @test long.text == "long.txt:1: " * repeat("x", 500) * "... [truncated]\n\n[Some lines truncated to 500 chars. Use read tool to see full lines]"
        write(joinpath(dir, "bracket[.txt"), "text")
        write(joinpath(dir, "bracketa.txt"), "text")
        @test execute(finder, (; pattern="bracket[.txt")).text == "bracket[.txt"
        @test execute(finder, (; pattern="bracket[a].txt")).text == "bracketa.txt"
        @test JuliaForever.name(finder) == "find"
        @test JuliaForever.name(grepper) == "grep"
        @test JuliaForever.schema(finder)["required"] == ["pattern"]
        @test JuliaForever.schema(grepper)["required"] == ["pattern"]
    end
end

@testset "Unicode case-insensitive literal grep" begin
    mktempdir() do dir
        prefix = repeat("中", 50)
        files = Dict(
            "titlecase.dat" => join((prefix * c for c in ("Ǆ", "ǅ", "ǆ")), "\n") * "\n",
            "greek.dat" => "σ\nς\nΣ\n",
            "kelvin.dat" => "k\nK\nK\n",
            "long-s.dat" => "s\nS\nſ\n",
            "turkic.dat" => "i\nI\nİ\nı\n",
            "sharp-s.dat" => "ß\nẞ\nss\nSS\n",
            "ligature.dat" => "ﬀ\nff\nﬅ\nﬆ\nst\n",
            "greek-accent.dat" => "ΐ\nΐ\nΐ\n",
            "cyrillic.dat" => "Ᲊ\nᲊ\n",
            "controls.dat" => "Σ\x01s\nσ\x02s\n",
            "empty-lines.dat" => "abc\n\nσ\n",
            "deseret.dat" => "𐐀\n𐐨\n",
            "quoted.dat" => "[A]\\e(B)\n[a]\\E(b)\nA\\eB\n",
            "canonical.dat" => "é\né\n",
        )
        foreach(pair -> write(joinpath(dir, first(pair)), last(pair)), pairs(files))
        cases = [
            ((; pattern="ǅ", path="titlecase.dat", literal=true, ignoreCase=true), join(("titlecase.dat:$i: " * prefix * c for (i, c) in enumerate(("Ǆ", "ǅ", "ǆ"))), "\n")),
            ((; pattern="σ", path="greek.dat", literal=true, ignoreCase=true), "greek.dat:1: σ\ngreek.dat:2: ς\ngreek.dat:3: Σ"),
            ((; pattern="σ", path="greek.dat", literal=true), "greek.dat:1: σ"),
            ((; pattern="^Σ\$", path="greek.dat", ignoreCase=true), "greek.dat:1: σ\ngreek.dat:2: ς\ngreek.dat:3: Σ"),
            ((; pattern="k", path="kelvin.dat", literal=true, ignoreCase=true), "kelvin.dat:1: k\nkelvin.dat:2: K\nkelvin.dat:3: K"),
            ((; pattern="s", path="long-s.dat", literal=true, ignoreCase=true), "long-s.dat:1: s\nlong-s.dat:2: S\nlong-s.dat:3: ſ"),
            ((; pattern="i", path="turkic.dat", literal=true, ignoreCase=true), "turkic.dat:1: i\nturkic.dat:2: I"),
            ((; pattern="ß", path="sharp-s.dat", literal=true, ignoreCase=true), "sharp-s.dat:1: ß\nsharp-s.dat:2: ẞ"),
            ((; pattern="ss", path="sharp-s.dat", literal=true, ignoreCase=true), "sharp-s.dat:3: ss\nsharp-s.dat:4: SS"),
            ((; pattern="s", path="sharp-s.dat", literal=true, ignoreCase=true), "sharp-s.dat:3: ss\nsharp-s.dat:4: SS"),
            ((; pattern="ﬀ", path="ligature.dat", literal=true, ignoreCase=true), "ligature.dat:1: ﬀ"),
            ((; pattern="ﬅ", path="ligature.dat", literal=true, ignoreCase=true), "ligature.dat:3: ﬅ\nligature.dat:4: ﬆ"),
            ((; pattern="st", path="ligature.dat", literal=true, ignoreCase=true), "ligature.dat:5: st"),
            ((; pattern="ΐ", path="greek-accent.dat", literal=true, ignoreCase=true), "greek-accent.dat:1: ΐ\ngreek-accent.dat:2: ΐ"),
            ((; pattern="Ᲊ", path="cyrillic.dat", literal=true, ignoreCase=true), "cyrillic.dat:1: Ᲊ\ncyrillic.dat:2: ᲊ"),
            ((; pattern="ς\x01S", path="controls.dat", literal=true, ignoreCase=true), "controls.dat:1: Σ\x01s"),
            ((; pattern="", path="empty-lines.dat", literal=true, ignoreCase=true), "empty-lines.dat:1: abc\nempty-lines.dat:2: \nempty-lines.dat:3: σ"),
            ((; pattern="𐐀", path="deseret.dat", literal=true, ignoreCase=true), "deseret.dat:1: 𐐀\ndeseret.dat:2: 𐐨"),
            ((; pattern="[a]\\E(b)", path="quoted.dat", literal=true, ignoreCase=true), "quoted.dat:1: [A]\\e(B)\nquoted.dat:2: [a]\\E(b)"),
            ((; pattern="é", path="canonical.dat", literal=true, ignoreCase=true), "canonical.dat:1: é"),
        ]
        for (args, expected) in cases
            result = execute(Grep(dir), args)
            @test !result.iserror && result.text == expected
        end
        @test occursin(JuliaForever.foldedpattern("σ\0x"), "ς\0X")
        @test !occursin(JuliaForever.foldedpattern("σ\0x"), "ς\x01X")
        @test !occursin(JuliaForever.foldedpattern("σ\x01x"), "ς\0X")
        @test !occursin(JuliaForever.foldedpattern("σ\x01x"), "ς\x02X")
        @test occursin(JuliaForever.foldedpattern("σ\0x"), prefix * "ς\0X")
        @test !occursin(JuliaForever.foldedpattern("σ\0x"), prefix * "ς\x01X")
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
