using Test, JuliaForever

@testset "grep byte-order marks" begin
    mktempdir() do dir
        write(joinpath(dir, "utf8"), [UInt8[0xef, 0xbb, 0xbf]; collect(codeunits("needle\nnext\n"))])
        tool = Grep(dir)
        @test execute(tool, (; pattern="^needle", path="utf8")).text == "utf8:1: needle"
        @test execute(tool, (; pattern="^needle", path="utf8", context=1)).text == "utf8:1: \ufeffneedle\nutf8-2- next"
        write(joinpath(dir, "utf8-crlf"), [UInt8[0xef, 0xbb, 0xbf]; collect(codeunits("needle\r\nnext\r\n"))])
        @test execute(tool, (; pattern="needle", path="utf8-crlf")).text == "utf8-crlf:1: needle"
        @test execute(tool, (; pattern="needle", path="utf8-crlf", context=1)).text == "utf8-crlf:1: \ufeffneedle\nutf8-crlf-2- next"
        for (name, bom, little) in (("le", UInt8[0xff, 0xfe], true), ("be", UInt8[0xfe, 0xff], false))
            mkpath(joinpath(dir, name))
            bytes = copy(bom)
            for unit in transcode(UInt16, "NEEDLE Σ\0next\n")
                append!(bytes, little ? UInt8[unit & 0xff, unit >> 8] : UInt8[unit >> 8, unit & 0xff])
            end
            write(joinpath(dir, name, "data"), bytes)
            @test execute(tool, (; pattern="needle", path="$name/data", literal=true, ignoreCase=true)).text == "data:1: NEEDLE Σ"
            @test execute(tool, (; pattern="next", path="$name/data")).text == "data:2: next"
            @test execute(tool, (; pattern="needle", path=name, literal=true, ignoreCase=true)).text == "No matches found"
            high = little ? UInt8[0x00, 0xd8] : UInt8[0xd8, 0x00]
            write(joinpath(dir, "$name-high-odd"), [bom; high; UInt8[0x61]])
            @test execute(tool, (; pattern="�", path="$name-high-odd", literal=true)).text == "$name-high-odd:1: �"
            last = little ? UInt8[0x61, 0x00] : UInt8[0x00, 0x61]
            write(joinpath(dir, "$name-empty-context"), [bom; zeros(UInt8, 6); last])
            @test execute(tool, (; pattern="a", path="$name-empty-context", context=1, literal=true)).text == ""
        end
    end
end
