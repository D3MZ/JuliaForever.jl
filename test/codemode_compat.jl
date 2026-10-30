using Test, JuliaForever, JSON3

struct CodeResultEnvelope
    result::CodeResult
end

@testset "code result compatibility" begin
    output = ["synthetic output"]
    calls = NamedTuple[(; name="read", status=:ok, duration=0.25)]
    writes = Dict{String, Any}("count" => 3, "nested" => Dict("values" => [1, 2]))
    deletes = ["old", "π😀"]
    for (flag, expected) in ((true, CodeSuccess), (false, CodeFailure))
        kind = flag ? nothing : :script
        message = flag ? "" : "synthetic failure"
        fields = ("value", output, calls, writes, deletes, kind, message, "out", "err", 12)
        result = CodeResult(flag, fields...)
        @test result isa expected
        @test CodeResult(Int(flag), fields...) isa expected
        legacyfields = ("value", output, calls, writes, kind, message, "out", "err", 12)
        converted = CodeResult(flag, legacyfields...)
        @test converted isa expected && isempty(converted.deletes)
        @test isempty(CodeResult(Int(flag), legacyfields...).deletes)
        @test expected(legacyfields...) isa expected && isempty(expected(legacyfields...).deletes)
        @test_throws InexactError CodeResult(2, legacyfields...)

        json = JSON3.write(result)
        wire = JSON3.read(json)
        @test wire.ok === flag
        @test wire.calls[1].name == "read" && wire.writes.count == 3
        @test JSON3.read(JSON3.write((; result))).result.ok === flag

        for source in (json, JSON3.write((; ok=flag, value="value", output, calls, writes, kind, message, stdout="out", stderr="err", pid=12)))
            decoded = JSON3.read(source, CodeResult)
            @test decoded isa expected && decoded.ok === flag
            @test decoded.value == "value" && decoded.output == output
            @test only(decoded.calls).name == "read" && only(decoded.calls).status == "ok" && only(decoded.calls).duration == 0.25
            @test decoded.calls == JSON3.read(JSON3.write(calls), Vector{NamedTuple})
            @test JSON3.read(JSON3.write(decoded.writes)) == JSON3.read(JSON3.write(writes))
            @test decoded.deletes == (haskey(JSON3.read(source), :deletes) ? deletes : String[])
            @test (decoded.kind, decoded.message, decoded.stdout, decoded.stderr, decoded.pid) == (kind, message, "out", "err", 12)
            wrapped = JSON3.read("{\"result\":" * source * "}", CodeResultEnvelope)
            @test wrapped.result isa expected && wrapped.result.ok === flag
        end
        @test JSON3.read(json, expected) isa expected
        subtypejson = JSON3.write((; value="value", output, calls, writes, deletes, kind, message, stdout="out", stderr="err", pid=12))
        @test JSON3.read(subtypejson, expected) isa expected
    end
end
