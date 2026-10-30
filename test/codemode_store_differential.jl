@testset "Pi code mode store deletion" begin
    source = ENV["PI_SOURCE"]
    @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
    reference = JSON3.read(read(`node --conditions=source --experimental-strip-types $(joinpath(@__DIR__, "codemode_store_reference.mjs")) $source`, String))
    cases = [
        (Dict("old" => 5, "keep" => true, "π😀" => 9), "forget!(\"old\"); forget!(\"π😀\"); store(\"null\", nothing); forget!(\"absent\"); [load(\"old\"), load(\"null\"), load(\"keep\") ]"),
        (Dict("replaced" => 1), "store(\"discarded\", 9); forget!(\"discarded\"); forget!(\"replaced\"); store(\"replaced\", 2); [load(\"discarded\"), load(\"replaced\") ]"),
        (Dict("old" => 5), "forget!(\"old\"); store(\"new\", 1); 1 + \"bad\""),
    ]
    mode = CodeMode(JuliaForever.Tool[]; timeout=60)
    for ((snapshot, code), pi) in zip(cases, reference)
        result = codeexecute(mode, code; store=snapshot)
        @test result.ok == pi.ok
        @test !result.ok || result.value == pi.value
        @test JSON3.read(JSON3.write(result.writes)) == pi.writes
        @test hasproperty(result, :deletes) && Set(result.deletes) == Set(String.(pi.deletes))
    end
end
