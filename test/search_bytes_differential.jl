@testset "Pi grep binary and malformed UTF-8" begin
    @test readchomp(`git -C $(ENV["PI_SOURCE"]) rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
    mktempdir() do dir
        write(joinpath(dir, "has-nul"), b"needle\n\0\nneedle\n")
        write(joinpath(dir, "same"), b"needle\0tail\n")
        write(joinpath(dir, "invalid"), UInt8[0xff, codeunits("needle")..., 0xe0, 0x80, 0x80, 0x0a])
        write(joinpath(dir, "long"), [fill(0xff, 501); collect(codeunits("needle\n"))])
        write(joinpath(dir, "many"), repeat([UInt8[0xff]; collect(codeunits(repeat("x", 490) * "needle\n"))], 110))
        write(joinpath(dir, "late"), [collect(codeunits("needle\n")); fill(UInt8('x'), 65536); UInt8[0x00, 0x0a]; collect(codeunits("needle\n"))])
        cases = Any[(; tool="grep", args=(; pattern="needle", path, context)) for path in ("has-nul", "same", "invalid", "long", "many", "late") for context in (0, 1)]
        push!(cases, (; tool="grep", args=(; pattern="needle", path="many", limit=200)))
        push!(cases, (; tool="grep", args=(; pattern="�", path="invalid")))
        mkpath(joinpath(dir, "tree"))
        cp(joinpath(dir, "has-nul"), joinpath(dir, "tree", "early"))
        cp(joinpath(dir, "late"), joinpath(dir, "tree", "late"))
        push!(cases, (; tool="grep", args=(; pattern="needle", path="tree"), unordered=true))
        for offset in (65535, 65536, 65537, 131071, 131072, 131073, 196608)
            name = "boundary-$(offset)"
            mkpath(joinpath(dir, name))
            prefix = [collect(codeunits("needle first\n")); fill(UInt8('x'), offset - 21); collect(codeunits("\nneedle\n"))]
            @test length(prefix) == offset
            write(joinpath(dir, name, "data"), [prefix; UInt8[0x00]; collect(codeunits("needle after\n"))])
            for path in (name, "$name/data"), context in (0, 1, 2)
                push!(cases, (; tool="grep", args=(; pattern="needle", path, context)))
            end
        end
        for offset in (65535, 65536, 65537, 131072), width in (32, 8190)
            name = "layout-$(offset)-$(width)"
            mkpath(joinpath(dir, name))
            block = [fill(UInt8('x'), width); UInt8('\n')]
            prefix = repeat(block, cld(offset, length(block)))[1:offset]
            prefix[1:7] = codeunits("needle\n")
            prefix[end-7:end] = codeunits("\nneedle\n")
            write(joinpath(dir, name, "data"), [prefix; UInt8[0x00]; collect(codeunits("needle after\n"))])
            for path in (name, "$name/data"), context in (0, 1)
                push!(cases, (; tool="grep", args=(; pattern="needle", path, context)))
            end
        end
        for (name, bytes) in (
            ("invalid-before", UInt8[0xff; collect(codeunits("NEEDLE Σ K\n"))]),
            ("invalid-between", UInt8[codeunits("NE")...; 0xff; codeunits("EDLE\n")...]),
            ("invalid-after", UInt8[codeunits("Σ K NEEDLE")...; 0xff; 0x0a]),
            ("invalid-replacement", UInt8[0xff; codeunits("Σ � needle\n")...]),
        )
            mkpath(joinpath(dir, name))
            write(joinpath(dir, name, "data"), bytes)
            for path in (name, "$name/data"), pattern in ("needle", "σ", "k", "�"), literal in (false, true)
                push!(cases, (; tool="grep", args=(; pattern, path, ignoreCase=true, literal)))
            end
        end
        prefix = repeat("ΣςK中", 20)
        for (name, bytes) in (
            ("cached-before", UInt8[0xff; codeunits(prefix * " NEEDLE Ǆ\n")...]),
            ("cached-between", UInt8[codeunits(prefix * " NE")...; 0xff; codeunits("EDLE ǅ\n")...]),
            ("cached-after", UInt8[codeunits(prefix * " NEEDLE ǆ")...; 0xff; 0x0a]),
            ("cached-replacement", UInt8[codeunits(prefix * " � NEEDLE")...; 0xff; 0x0a]),
            ("cached-invalid-only", UInt8[codeunits(prefix * " tail")...; 0xff; 0x0a]),
            ("cached-controls", UInt8[codeunits(prefix * " \x01\x03 NEEDLE")...; 0xff; 0x0a]),
        )
            mkpath(joinpath(dir, name))
            write(joinpath(dir, name, "data"), bytes)
            for path in (name, "$name/data"), pattern in ("needle", "σ", "k", "�", "ǅ", "\x01\x03")
                push!(cases, (; tool="grep", args=(; pattern, path, ignoreCase=true, literal=true)))
            end
        end
        @test execute(Grep(dir), (; pattern="needle", path="cached-between/data", ignoreCase=true, literal=true)).text == "No matches found"
        @test execute(Grep(dir), (; pattern="�", path="cached-invalid-only/data", ignoreCase=true, literal=true)).text == "No matches found"
        @test execute(Grep(dir), (; pattern="\x01\x03", path="cached-invalid-only/data", ignoreCase=true, literal=true)).text == "No matches found"
        @test occursin("ǆ�", execute(Grep(dir), (; pattern="ǅ", path="cached-after/data", ignoreCase=true, literal=true)).text)
        input = tempname()
        write(input, JSON3.write(cases))
        try
            reference = JSON3.read(read(`node $(joinpath(@__DIR__, "search_reference.mjs")) $(ENV["PI_SOURCE"]) $dir $input`, String))
            for (i, case) in enumerate(cases)
                result = try
                    execute(Grep(dir), case.args)
                catch exception
                    exception
                end
                @test result isa ToolResult
                result isa ToolResult || continue
                @test result.iserror == reference[i].iserror
                actual, expected = result.text, reference[i].text
                @test get(case, :unordered, false) ? sort(split(actual, '\n')) == sort(split(expected, '\n')) : actual == expected
            end
        finally
            rm(input; force=true)
        end
    end
end
