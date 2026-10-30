using Test, JuliaForever, JSON3, Base64

@testset "image reads against pinned Pi" begin
    source = ENV["PI_SOURCE"]
    @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
    mktempdir() do dir
        png = read(joinpath(@__DIR__, "fixtures", "pixel.png"))
        jpeg = read(joinpath(@__DIR__, "fixtures", "pixel.jpg"))
        write(joinpath(dir, "pixels.txt"), png)
        write(joinpath(dir, "photo.bin"), jpeg)
        reference = JSON3.read(read(`node $(joinpath(@__DIR__, "image_reference.mjs")) $source $dir`, String))
        for (index, args) in enumerate(((; path="pixels.txt", offset=9, limit=1), (; path="photo.bin")))
            actual = execute(Read(dir), args)
            text = only(filter(block -> block.type == "text", reference[index]))
            image = only(filter(block -> block.type == "image", reference[index]))
            @test !actual.iserror
            @test actual.text == text.text
            @test actual.image.mime == image.mimeType
            @test actual.image.data == image.data
        end
    end
end
