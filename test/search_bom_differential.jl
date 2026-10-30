@testset "Pi grep byte-order marks" begin
    mktempdir() do dir
        text = "first\nneedle 🌱\nlast\nneedle\n"
        utf16 = transcode(UInt16, text)
        write(joinpath(dir, "utf8"), [0xef, 0xbb, 0xbf, codeunits(text)...])
        for (file, bom, little) in (("le", UInt8[0xff, 0xfe], true), ("be", UInt8[0xfe, 0xff], false))
            bytes = copy(bom)
            for unit in utf16
                append!(bytes, little ? UInt8[unit & 0xff, unit >> 8] : UInt8[unit >> 8, unit & 0xff])
            end
            write(joinpath(dir, file), bytes)
        end
        write(joinpath(dir, "invalid-le"), UInt8[0xff, 0xfe, 0x6e, 0x00, 0x65, 0x00, 0x65, 0x00, 0x64, 0x00, 0x6c, 0x00, 0x65, 0x00, 0x00, 0xd8, 0x0a, 0x00, 0x6e, 0x00, 0x65, 0x00, 0x65, 0x00, 0x64, 0x00, 0x6c, 0x00, 0x65, 0x00, 0x61])
        bad = read(joinpath(dir, "invalid-le"))
        write(joinpath(dir, "invalid-be"), [0xfe, 0xff, reduce(vcat, (reverse(bad[i:i+1]) for i in 3:2:length(bad)-1))..., 0x61])
        write(joinpath(dir, "large"), [0xef, 0xbb, 0xbf, codeunits(repeat(repeat("x", 500) * "needle\n", 110))...])
        cases = [(; tool="grep", args=(; pattern="needle", path=file, options...)) for file in ("utf8", "le", "be", "invalid-le", "invalid-be") for options in ((;), (; context=1), (; limit=1))]
        append!(cases, [(; tool="grep", args=(; pattern="^first", path="utf8")), (; tool="grep", args=(; pattern="needle", path="utf8", context=1, limit=1))])
        push!(cases, (; tool="grep", args=(; pattern="needle", path="large", limit=200)))

        fixtures = Dict{String, Vector{UInt8}}(
            "utf8-bad" => [UInt8[0xef, 0xbb, 0xbf, 0xff]; collect(codeunits("NEEDLE Σ K\nnext needle\n"))],
            "utf8-crlf" => [UInt8[0xef, 0xbb, 0xbf]; collect(codeunits("needle\r\nnext needle\r\n"))],
            "utf8-crlf-bad" => [UInt8[0xef, 0xbb, 0xbf, 0xff]; collect(codeunits("needle\r\nneedle\n"))],
            "utf8-crlf-nul" => [UInt8[0xef, 0xbb, 0xbf]; collect(codeunits("needle\r\nzero\0needle\r\nneedle\n"))],
            "utf8-nul" => [UInt8[0xef, 0xbb, 0xbf]; collect(codeunits("needle\nzero\0NEEDLE Σ\nneedle\n"))],
            "utf8-late-nul" => [UInt8[0xef, 0xbb, 0xbf]; collect(codeunits("needle\n")); fill(UInt8('x'), 65536); UInt8[0x00, 0x0a]; collect(codeunits("needle after\n"))],
        )
        for (name, bom, little) in (("le", UInt8[0xff, 0xfe], true), ("be", UInt8[0xfe, 0xff], false))
            last = little ? UInt8[0x61, 0x00] : UInt8[0x00, 0x61]
            fixtures["$name-empty-context"] = [bom; zeros(UInt8, 6); last]
            for (suffix, value) in (("nul", "NEEDLE Σ K\nzero\0needle\nnext needle\n"), ("late-nul", "needle\n" * repeat("x", 65536) * "\0\nneedle after\n"), ("long", repeat("x", 501) * "needle 🌱\n"), ("crlf", "needle\r\nneedle\nNEEDLE\r\nlast needle"), ("crlf-nul", "needle\r\nzero\0needle\r\nneedle\n"))
                encoded = copy(bom)
                for unit in transcode(UInt16, value)
                    append!(encoded, little ? UInt8[unit & 0xff, unit >> 8] : UInt8[unit >> 8, unit & 0xff])
                end
                fixtures["$name-$suffix"] = encoded
            end
            malformed = copy(bom)
            for unit in UInt16[0x004e, 0x0045, 0x0045, 0x0044, 0x004c, 0x0045, 0xd800, 0x0020, 0xdc00, 0x000a, 0xd83c, 0xdf31, 0x000a]
                append!(malformed, little ? UInt8[unit & 0xff, unit >> 8] : UInt8[unit >> 8, unit & 0xff])
            end
            push!(malformed, 0x61)
            fixtures["$name-malformed"] = malformed
            for (suffix, unit) in (("high-odd", UInt16(0xd800)), ("low-odd", UInt16(0xdc00)))
                encoded = copy(bom)
                for value in UInt16[0x004e, 0x0045, 0x0045, 0x0044, 0x004c, 0x0045, unit]
                    append!(encoded, little ? UInt8[value & 0xff, value >> 8] : UInt8[value >> 8, value & 0xff])
                end
                push!(encoded, 0x61)
                fixtures["$name-$suffix"] = encoded
            end
        end
        for (name, bytes) in fixtures
            mkpath(joinpath(dir, name))
            write(joinpath(dir, name, "data"), bytes)
            patterns = endswith(name, "late-nul") ? ("needle",) : ("needle", "σ", "k", "�")
            for path in (name, "$name/data"), pattern in patterns, context in (0, 1)
                push!(cases, (; tool="grep", args=(; pattern, path, context, literal=true, ignoreCase=true)))
            end
            for path in (name, "$name/data"), context in (0, 1)
                push!(cases, (; tool="grep", args=(; pattern="needle", path, context, limit=1)))
            end
        end
        for name in ("utf8-crlf", "utf8-crlf-bad", "utf8-crlf-nul", "le-crlf", "le-crlf-nul", "be-crlf", "be-crlf-nul"), path in (name, "$name/data"), (pattern, literal) in (("needle\$", false), ("needle\\r\$", false), ("needle\r", true)), context in (0, 1)
            push!(cases, (; tool="grep", args=(; pattern, path, context, literal)))
        end
        for name in ("le-empty-context", "be-empty-context"), context in (0, 1), limit in (1, 100)
            push!(cases, (; tool="grep", args=(; pattern="a", path="$name/data", context, limit, literal=true)))
        end
        input = tempname()
        write(input, JSON3.write(cases))
        try
            reference = JSON3.read(read(`node $(joinpath(@__DIR__, "search_reference.mjs")) $(ENV["PI_SOURCE"]) $dir $input`, String))
            for (index, case) in enumerate(cases)
                result = execute(Grep(dir), case.args)
                @test (result.iserror, result.text) == (reference[index].iserror, reference[index].text)
            end
        finally
            rm(input; force=true)
        end
    end
end
