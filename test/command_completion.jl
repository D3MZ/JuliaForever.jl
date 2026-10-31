module CommandCompletionTests

using Test, JuliaForever, JSON3

@testset "command suggestions match Pi" begin
    C = JuliaForever.LiveTerminal.Completion
    S = JuliaForever.Skills
    skills = [S.Skill("example", "Example skill", "/example/SKILL.md", "/example", S.Automatic()), S.Skill("reviewer", "Explicit skill", "/reviewer/SKILL.md", "/reviewer", S.Explicit()), S.Skill("2model", "Numeric skill", "/numeric/SKILL.md", "/numeric", S.Automatic()), S.Skill("🚀plan", "Unicode skill", "/unicode/SKILL.md", "/unicode", S.Automatic())]
    resources = S.Resources(Dict("review" => "Review \$1", "revise" => "Revise \$1", "model2" => "Model", "café" => "Coffee"), skills)
    commands = C.commands(resources)
    queries = ["", "r", "re", "rev", "rsm", "example", "skill:exa", "skill", "REVIEW", "model2", "2model", "CAFÉ", "cfé", "🚀p", "no-such-command"]
    actual = [[item.name for item in C.suggest(commands, query)] for query in queries]
    if haskey(ENV, "PI_SOURCE")
        source = ENV["PI_SOURCE"]
        @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
        mktemp() do path, io
            JSON3.write(io, (; commands=[(; name=item.name, description=item.description) for item in commands], queries))
            flush(io)
            oracle = JSON3.read(read(`node $(joinpath(@__DIR__, "command_completion_pi.mjs")) $source $path`, String), Vector{Vector{String}})
            @test actual == oracle
        end
    end
    @test "skill:example" in actual[6]
    @test "skill:reviewer" in actual[8]
    @test isempty(actual[end])
    @test Set(chopprefix(name, "/") for name in keys(JuliaForever.terminalcommands)) ⊆ Set(item.name for item in commands)
end

end
