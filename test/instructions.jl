using Test, JuliaForever

include("instructions_cases.jl")

@testset "project instructions" begin
    @test JuliaForever.Instructions.render([]) === nothing
    @test JuliaForever.Instructions.render([(; path="/a/AGENTS.md", content="one"), (; path="/b/CLAUDE.md", content="two\n")]) == "<project_context>\nProject-specific instructions and guidelines:\n\n<project_instructions path=\"/a/AGENTS.md\">\none\n</project_instructions>\n\n<project_instructions path=\"/b/CLAUDE.md\">\ntwo\n\n</project_instructions>\n</project_context>"
    mktempdir() do path
        dir = realpath(path)
        cd(dir) do
            for case in instructioncases(dir)
                @testset "$(case.label)" begin
                    files = JuliaForever.Instructions.load(case.cwd; agentdir=case.agentdir)
                    localfiles = filter(file -> startswith(file.path, joinpath(dir, "")), files)
                    @test localfiles == case.expected
                end
            end
            @test isempty(filter(file -> startswith(file.path, joinpath(dir, "")), JuliaForever.Instructions.load(joinpath(dir, "empty"))))
        end
    end
end
