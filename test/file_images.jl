using Test, JuliaForever, JSON3, Base64, HTTP
import JuliaForever.Conversation as FileConversation
import JuliaForever.History as FileHistory
import JuliaForever.ContextEstimates as FileEstimates

mutable struct FileProvider
    requests::Vector{Any}
end
function JuliaForever.complete(provider::FileProvider, messages, tools; parameters=Dict())
    push!(provider.requests, deepcopy(messages))
    Dict{String, Any}("role" => "assistant", "content" => "done")
end

@testset "Pi text and image file preprocessing" begin
    mktempdir() do root
        root = realpath(root)
        files = ("pixel.png", "pixel.jpg")
        for file in files
            cp(joinpath(@__DIR__, "fixtures", file), joinpath(root, file))
        end
        write(joinpath(root, "tiny.gif"), base64decode("R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw=="))
        write(joinpath(root, "tiny.webp"), UInt8[codeunits("RIFF")...; 16; 0; 0; 0; codeunits("WEBP")...; codeunits("VP8 ")...])
        write(joinpath(root, "bad.txt"), UInt8[0xff, 0x61, 0xc3, 0xa9, 0xe2, 0x82])
        paths = [files..., "tiny.gif", "tiny.webp", "bad.txt"]
        result = JuliaForever.FileArguments.load(paths, root)
        @test [image.mime for image in result.images] == ["image/png", "image/jpeg", "image/gif", "image/webp"]
        @test [base64decode(image.data) for image in result.images] == [read(joinpath(root, file)) for file in paths[1:4]]
        if haskey(ENV, "PI_SOURCE")
            pi = ENV["PI_SOURCE"]
            args = ["@" * file for file in paths]
            cmd = Cmd(`node $(joinpath(@__DIR__, "file_arguments_pi.mjs")) $pi $(JSON3.write(args))`; dir=root)
            reference = JSON3.read(read(cmd, String))
            @test result.text == reference.initial.initialMessage
            @test [image.data for image in result.images] == [image.data for image in reference.initial.initialImages]
        end
    end
end

@testset "file path normalization and PNG detection" begin
    mktempdir() do root
        root = realpath(root)
        write(joinpath(root, "photo 4\u202fPM.png"), "screenshot")
        write(joinpath(root, "d’écran.txt"), "curly")
        write(joinpath(root, "@literal.txt"), "literal")
        png = read(joinpath(@__DIR__, "fixtures", "pixel.png"))
        write(joinpath(root, "animated.png"), [png[1:33]; UInt8[0,0,0,8,0x61,0x63,0x54,0x4c,0,0,0,1,0,0,0,0,0,0,0,0]; png[34:end]])
        names = ["photo 4 PM.png", "d'écran.txt", "animated.png"]
        result = JuliaForever.FileArguments.load(names, root)
        @test isempty(result.images)
        @test occursin("screenshot", result.text) && occursin("curly", result.text)
        filepath = joinpath(root, "photo 4\u202fPM.png")
        urlpath = replace(filepath, '\\' => '/')
        urlpath = startswith(urlpath, "/") ? urlpath : "/" * urlpath
        url = "file://" * replace(urlpath, " " => "%20", "\u202f" => "%E2%80%AF")
        @test JuliaForever.FileArguments.resolve(url, root) == filepath
        @test JuliaForever.FileArguments.resolve("@@literal.txt", root) == joinpath(root, "@literal.txt")
        if haskey(ENV, "PI_SOURCE")
            pi = ENV["PI_SOURCE"]
            args = ["@" * file for file in names]
            cmd = Cmd(`node $(joinpath(@__DIR__, "file_arguments_pi.mjs")) $pi $(JSON3.write(args))`; dir=root)
            reference = JSON3.read(read(cmd, String))
            @test result.text == reference.initial.initialMessage
        end
    end
end
