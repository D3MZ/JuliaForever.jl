@testset "Pi grep line endings" begin
    mktempdir() do dir
        write(joinpath(dir, "lf.txt"), "before\nneedle\nafter\n")
        write(joinpath(dir, "crlf.txt"), "before\r\nneedle\r\nafter\r\n")
        write(joinpath(dir, "mixed.txt"), "needle\r\nneedle\nNEEDLE\r\ntail needle")
        write(joinpath(dir, "long.txt"), repeat("x", 501) * "needle\r\nneedle\n")
        write(joinpath(dir, "invalid.txt"), UInt8[0xff, 0x0d, 0x0a, codeunits("needle\r\nneedle\n")...])
        write(joinpath(dir, "binary.txt"), UInt8[codeunits("needle\r\n")..., 0x00, codeunits("needle\n")...])
        write(joinpath(dir, ".ignore"), "ignored.txt\n")
        write(joinpath(dir, "ignored.txt"), "needle\n")
        cases = [
            (; pattern="needle\$", path="lf.txt"),
            (; pattern="needle\$", path="crlf.txt", context=1),
            (; pattern="needle\\r\$", path="crlf.txt", context=1),
            (; pattern="needle", path="crlf.txt", literal=true, context=1),
            (; pattern="needle\r", path="crlf.txt", literal=true),
            (; pattern="needle\$", path="mixed.txt", context=1),
            (; pattern="^needle", path="mixed.txt", ignoreCase=true, context=1, limit=2),
            (; pattern="needle", path="mixed.txt", literal=true, ignoreCase=true),
            (; pattern="needle\$", path="long.txt", context=1),
            (; pattern="needle", path="long.txt", literal=true, limit=1),
            (; pattern="needle\$", path="invalid.txt", context=1),
            (; pattern="needle", path="invalid.txt", literal=true, context=1),
            (; pattern="needle\$", path="binary.txt", context=1),
            (; pattern="needle", path="binary.txt", literal=true, context=1),
            (; pattern="needle\$", glob="*.txt"),
            (; pattern="needle", literal=true, glob="*.txt"),
            (; pattern="needle\$", path="."),
            (; pattern="needle", path=".", literal=true),
            (; pattern="needle\$", path="ignored.txt"),
        ]
        input = tempname()
        write(input, JSON3.write([(; tool="grep", args) for args in cases]))
        try
            reference = JSON3.read(read(`node $(joinpath(@__DIR__, "search_reference.mjs")) $(ENV["PI_SOURCE"]) $dir $input`, String))
            for (index, args) in enumerate(cases)
                result = execute(Grep(dir), args)
                @test result.iserror == reference[index].iserror
                actual, expected = result.text, reference[index].text
                if haskey(args, :glob) || get(args, :path, "") == "."
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
