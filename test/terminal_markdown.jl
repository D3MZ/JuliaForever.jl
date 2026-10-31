module TerminalMarkdownTests

using Test, JuliaForever, JSON3
const M = JuliaForever.LiveTerminal.MarkdownScreen

@testset "terminal Markdown matches Pi" begin
    cases = JSON3.read(read(joinpath(@__DIR__, "terminal_markdown_cases.json"), String))
    plain(line) = replace(line, r"\e\[[0-9;]*m" => "")
    actual = [[rstrip(plain(line)) for line in M.render(case.text, case.width)] for case in cases]
    if haskey(ENV, "PI_SOURCE")
        source = ENV["PI_SOURCE"]
        @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
        oracle = JSON3.read(read(`node $(joinpath(@__DIR__, "terminal_markdown_pi.mjs")) $source $(joinpath(@__DIR__, "terminal_markdown_cases.json"))`, String), Vector{Vector{String}})
        @test actual == [[rstrip(plain(line)) for line in lines] for lines in oracle]
    end
    @test actual[1] == ["Hello bold, italic, code, and link (https://example.com)."]
    @test actual[5] == ["```julia", "  x = 1", "  println(x)", "```"]
    @test all(M.cellwidth(plain(line)) <= case.width for (case, lines) in zip(cases, M.render.(getproperty.(cases, :text), getproperty.(cases, :width))) for line in lines)
    @test !occursin("\e]", join(M.render("plain \e]2;spoof\a **safe**", 30)))
    @test !occursin("\e[2J", join(M.render("plain \e[2J safe", 30)))
    @test M.render("````julia\nunfinished", 30, M.Plain()) == ["```julia", "  unfinished", "```"]
    @test occursin("\e[1m", join(M.render("**bold**", 30)))
    @test occursin("\e[9m", join(M.render("~~gone~~", 30)))
    narrow = M.render("- one\n    - two\n        - three", 4, M.Plain())
    @test all(M.cellwidth(line) <= 4 for line in narrow)
    @test all(word -> occursin(word, join(strip.(narrow))), ("one", "two", "three"))
end

end
