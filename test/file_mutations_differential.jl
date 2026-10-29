@testset "Pi file mutations" begin
    source = ENV["PI_SOURCE"]
    @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
    reference = JSON3.read(read(`node $(joinpath(@__DIR__, "file_mutations_reference.mjs")) $source`, String))
    for (index, kind) in enumerate((:edit, :write))
        mktempdir() do dir
            result = filemutationcase(dir, kind)
            @test result.file == reference[index].file
            @test result.other == reference[index].other
            @test isempty(JuliaForever.mutations)
        end
    end
end
