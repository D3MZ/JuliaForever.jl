using Test, JuliaForever, JSON3

include("instructions_cases.jl")

@testset "project instructions" begin
    @test JuliaForever.Instructions.render([]) === nothing
    @test JuliaForever.Instructions.render([(; path="/a/AGENTS.md", content="one"), (; path="/b/CLAUDE.md", content="two\n")]) == "<project_context>\nProject-specific instructions and guidelines:\n\n<project_instructions path=\"/a/AGENTS.md\">\none\n</project_instructions>\n\n<project_instructions path=\"/b/CLAUDE.md\">\ntwo\n\n</project_instructions>\n</project_context>"
    mktempdir() do path
        dir = realpath(path)
        cd(dir) do
            cases = instructioncases(dir)
            reference = if haskey(ENV, "PI_SOURCE")
                source = ENV["PI_SOURCE"]
                @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
                input = joinpath(dir, "cases.json")
                write(input, JSON3.write([(; cwd=case.cwd, agentDir=case.agentdir) for case in cases]))
                JSON3.read(read(`node $(joinpath(@__DIR__, "instructions_reference.mjs")) $source $input`, String))
            end
            for (index, case) in enumerate(cases)
                @testset "$(case.label)" begin
                    files = JuliaForever.Instructions.load(case.cwd; agentdir=case.agentdir)
                    localfiles = filter(file -> startswith(file.path, joinpath(dir, "")), files)
                    @test localfiles == case.expected
                    if haskey(ENV, "PI_SOURCE")
                        expected = [(; path=String(file.path), content=String(file.content)) for file in reference[index].files]
                        @test files == expected
                        @test JuliaForever.Instructions.render(files) == reference[index].context
                    end
                end
            end
            @test isempty(filter(file -> startswith(file.path, joinpath(dir, "")), JuliaForever.Instructions.load(joinpath(dir, "empty"))))
        end
    end
end
