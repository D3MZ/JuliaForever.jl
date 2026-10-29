using Test, JuliaForever, JSON3

@testset "Pi project instructions" begin
    source = ENV["PI_SOURCE"]
    @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
    mktempdir() do path
        dir = realpath(path)
        cases = instructioncases(dir)
        input = joinpath(dir, "cases.json")
        write(input, JSON3.write([(; cwd=case.cwd, agentDir=case.agentdir) for case in cases]))
        reference = JSON3.read(read(`node $(joinpath(@__DIR__, "instructions_reference.mjs")) $source $input`, String))
        for (index, case) in enumerate(cases)
            @testset "$(case.label)" begin
                files = JuliaForever.Instructions.load(case.cwd; agentdir=case.agentdir)
                expected = [(; path=String(file.path), content=String(file.content)) for file in reference[index].files]
                @test files == expected
                @test JuliaForever.Instructions.render(files) == reference[index].context
            end
        end
    end
end
