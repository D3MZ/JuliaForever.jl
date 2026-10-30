using Test, JuliaForever, JSON3

struct ContextProbe <: JuliaForever.Tool end
JuliaForever.name(::ContextProbe) = "greet"
JuliaForever.description(::ContextProbe) = "Greet a person"
JuliaForever.schema(::ContextProbe) = Dict("type" => "object")

@testset "Pi context composition" begin
    source = ENV["PI_SOURCE"]
    @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
    mktempdir() do dir
        cwd = realpath(dir)
        reader = Read(cwd)
        probe = ContextProbe()
        files = [(; path=joinpath(cwd, "AGENTS.md"), content="Project fixture")]
        cases = [(; tools=[reader], files=empty(files)), (; tools=[reader, probe, CodeMode([reader, probe])], files)]
        options = [(; cwd, selectedTools=JuliaForever.name.(case.tools), toolSnippets=Dict(JuliaForever.name(tool) => JuliaForever.guidance(tool) for tool in case.tools), contextFiles=case.files) for case in cases]
        input = joinpath(dir, "context-cases.json")
        write(input, JSON3.write(options))
        reference = JSON3.read(read(`node $(joinpath(@__DIR__, "context_reference.mjs")) $source $input`, String))
        for (case, pi) in zip(cases, reference)
            native = JuliaForever.context(cwd, case.tools, case.files)
            @test occursin("coding assistant", lowercase(native)) && occursin("coding assistant", lowercase(pi.preamble))
            @test occursin(cwd, native) && occursin(cwd, pi.cwd)
            for name in ("read", "greet", "codemode", "bash")
                @test occursin("- $name:", native) == occursin("- $name:", pi.tools)
            end
            @test occursin("<project_context>", native) == haskey(pi, :project_context)
            if !isempty(case.files)
                @test occursin(JuliaForever.Instructions.render(case.files), native)
                @test JuliaForever.Instructions.render(case.files) == pi.project_context
            end
        end
    end
end
