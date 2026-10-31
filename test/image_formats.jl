module ImageFormatTests

using Test, JuliaForever, JSON3, Base64, HTTP

const MCP = JuliaForever.MCP
const C = JuliaForever.Conversation
const H = JuliaForever.History
const fixtures = joinpath(@__DIR__, "fixtures")
const static = ("static.gif", "interlaced.gif", "static.webp", "lossy.webp", "alpha.webp", "edge.gif", "edge.webp", "maxpixels.gif", "maxpixels.webp")
const animated = ("animated.gif", "animated.webp")
const wide = ("wide.gif", "wide.webp")

function result(file, bytes)
    mime = endswith(file, ".gif") ? "image/gif" : "image/webp"
    MCP.toolresult(Dict("content" => [Dict("type" => "image", "mimeType" => mime, "data" => base64encode(bytes))]))
end

@testset "MCP image media types normalize against pinned Pi" begin
    cases = (("animated.gif", "IMAGE/GIF", "image/gif"), ("animated.webp", "IMAGE/WEBP; name=inline.webp", "image/webp"), ("static.gif", "IMAGE/GIF", "image/gif"), ("static.gif", " image/gif; name=static.gif ", "image/gif"), ("static.webp", "IMAGE/WEBP; name=inline.webp", "image/webp"), ("pixel.png", "IMAGE/PNG; name=pixel.png", "image/png"), ("pixel.jpg", "image/JPG", "image/jpeg"), ("pixel.jpg", "image/JPEG; name=pixel.jpg", "image/jpeg"))
    reference = if haskey(ENV, "PI_SOURCE")
        source = ENV["PI_SOURCE"]
        @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
        JSON3.read(read(`node --conditions=source --experimental-strip-types $(joinpath(@__DIR__, "image_mime_pi.mjs")) $source $fixtures`, String))
    else
        nothing
    end
    for (index, (file, mime, canonical)) in enumerate(cases)
        data = base64encode(read(joinpath(fixtures, file)))
        value = MCP.toolresult(Dict("content" => [Dict("type" => "image", "mimeType" => mime, "data" => data)]))
        @test !value.iserror && isequal(value.image, Image(canonical, data))
        embedded = MCP.toolresult(Dict("content" => [Dict("type" => "resource", "resource" => Dict("uri" => "file:///image", "mimeType" => mime, "blob" => data))]))
        @test !embedded.iserror && isequal(embedded.image, Image(canonical, data))
        isnothing(reference) || @test reference[index].mime == canonical && reference[index].unchanged
    end
    for (file, mime) in (("static.gif", "IMAGE/WEBP; name=static.gif"), ("pixel.jpg", "IMAGE/PNG; name=pixel.jpg"))
        data = base64encode(read(joinpath(fixtures, file)))
        value = MCP.toolresult(Dict("content" => [Dict("type" => "image", "mimeType" => mime, "data" => data)]))
        @test value.iserror && isnothing(value.image) && occursin("Mismatched image data", value.text)
    end
end

@testset "GIF reads require a color table" begin
    original = read(joinpath(fixtures, "static.gif"))
    palette = original[14:19]
    without = [original[1:13]; original[20:end]]
    without[11] &= 0x7f
    image = findfirst(==(0x2c), without)
    flags = image + 9
    localonly = [without[1:flags]; palette; without[flags+1:end]]
    localonly[flags] |= 0x80
    mktempdir() do root
        for (file, bytes) in (("missing.gif", without), ("local.gif", localonly))
            write(joinpath(root, file), bytes)
        end
        missing = execute(Read(root), (; path="missing.gif"))
        @test missing.iserror && isnothing(missing.image)
        @test isequal(result("missing.gif", without).image, Image("image/gif", base64encode(without)))
        @test isequal(execute(Read(root), (; path="local.gif")).image, Image("image/gif", base64encode(localonly)))
        if haskey(ENV, "PI_SOURCE")
            source = ENV["PI_SOURCE"]
            reference = JSON3.read(read(`node --conditions=source --experimental-strip-types $(joinpath(@__DIR__, "image_formats_pi.mjs")) $source $root missing.gif local.gif`, String))
            @test length(reference[1].read) == 1 && occursin("omitted", reference[1].read[1].text)
            @test reference[1].content[1].data == base64encode(without)
            @test reference[2].read[2].data == base64encode(localonly)
        end
    end
end

@testset "bounded GIF and WebP tool results" begin
    files = (static..., animated..., wide...)
    reference = if haskey(ENV, "PI_SOURCE")
        source = ENV["PI_SOURCE"]
        @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
        JSON3.read(read(`node $(joinpath(@__DIR__, "image_formats_pi.mjs")) $source $fixtures $files`, String))
    else
        nothing
    end
    for (index, file) in enumerate(files)
        bytes = read(joinpath(fixtures, file))
        actual = execute(Read(fixtures), (; path=file, offset=9, limit=1))
        remote = result(file, bytes)
        if file in (static..., animated...)
            mime = endswith(file, ".gif") ? "image/gif" : "image/webp"
            @test !actual.iserror && actual.text == "Read image file [$mime]"
            @test isequal(actual.image, Image(mime, base64encode(bytes)))
            @test !remote.iserror && isequal(remote.image, actual.image)
            if !isnothing(reference) && !isnothing(actual.image) && !isnothing(remote.image)
                @test reference[index].read[1].text == actual.text
                @test reference[index].read[2].mimeType == actual.image.mime && reference[index].read[2].data == actual.image.data
                @test reference[index].content[1].mimeType == remote.image.mime && reference[index].content[1].data == remote.image.data
            end
        else
            @test actual.iserror && isnothing(actual.image)
            @test remote.iserror && isnothing(remote.image)
            if !isnothing(reference)
                @test length(reference[index].read) == 2
                @test file in animated ? reference[index].read[2].data == base64encode(bytes) : reference[index].read[2].mimeType in ("image/png", "image/jpeg")
            end
        end
    end
    for file in (static..., animated...)
        bytes = read(joinpath(fixtures, file))
        @test result(file, bytes[1:end-5]).iserror
        other = endswith(file, ".gif") ? "image/webp" : "image/gif"
        @test MCP.toolresult(Dict("content" => [Dict("type" => "image", "mimeType" => other, "data" => base64encode(bytes))])).iserror
    end
end

@testset "corrupt and concurrent image decoding" begin
    mktempdir() do root
        files = ("corrupt.gif", "corrupt.webp")
        gif = read(joinpath(fixtures, "static.gif"))
        gif[40:42] .= 0xff
        webp = read(joinpath(fixtures, "static.webp"))
        webp[26:35] .= 0xff
        for (file, bytes) in zip(files, (gif, webp))
            write(joinpath(root, file), bytes)
            @test execute(Read(root), (; path=file)).iserror
            @test result(file, bytes).iserror
        end
        for (file, range) in (("animated.gif", 89:91), ("animated.webp", 158:165))
            bytes = read(joinpath(fixtures, file))
            bytes[range] .= 0xff
            write(joinpath(root, file), bytes)
            @test execute(Read(root), (; path=file)).iserror
            @test result(file, bytes).iserror
        end
        largeframe = read(joinpath(fixtures, "static.gif"))
        largeframe[33:34] .= 0xff
        @test result("corrupt.gif", largeframe).iserror
        largeframe = read(joinpath(fixtures, "alpha.webp"))
        largeframe[65:66] = [0xff, 0x3f]
        @test result("corrupt.webp", largeframe).iserror
        if haskey(ENV, "PI_SOURCE")
            source = ENV["PI_SOURCE"]
            reference = JSON3.read(read(`node $(joinpath(@__DIR__, "image_formats_pi.mjs")) $source $root $files`, String))
            @test all(item -> length(item.read) == 1 && occursin("omitted", item.read[1].text), reference)
            @test all(item -> length(item.content) == 1 && item.content[1].type == "image", reference)
        end
    end
    images = [read(joinpath(fixtures, file)) for file in ("static.gif", "static.webp", animated...)]
    tasks = [Threads.@spawn all(!result(file, images[index]).iserror for _ in 1:50) for (index, file) in enumerate(("static.gif", "static.webp", animated...)) for _ in 1:4]
    @test all(fetch, tasks)
end

@testset "GIF and WebP encoded-size boundary" begin
    files = ("static.gif", "static.webp", animated...)
    reference = if haskey(ENV, "PI_SOURCE")
        source = ENV["PI_SOURCE"]
        JSON3.read(read(`node $(joinpath(@__DIR__, "image_limits_pi.mjs")) $source $fixtures $files`, String))
    else
        nothing
    end
    mktempdir() do root
        for (index, file) in enumerate(files)
            original = read(joinpath(fixtures, file))
            bytes = [original; zeros(UInt8, 3_538_941 - length(original))]
            path = joinpath(root, file)
            write(path, bytes)
            @test !execute(Read(root), (; path=file)).iserror
            @test !result(file, bytes).iserror
            push!(bytes, 0x00)
            write(path, bytes)
            @test execute(Read(root), (; path=file)).iserror
            @test result(file, bytes).iserror
            if !isnothing(reference)
                if file == "animated.webp"
                    @test !reference[2index - 1].ok && !reference[2index].ok
                else
                    @test reference[2index - 1].ok && reference[2index - 1].unchanged
                    @test reference[2index].ok && !reference[2index].unchanged && reference[2index].mime in ("image/png", "image/jpeg")
                end
            end
        end
    end
end

@testset "GIF extension blocks" begin
    original = read(joinpath(fixtures, "static.gif"))
    make(blocks) = [original[1:19]; UInt8[0x21, 0xfe]; repeat(UInt8[0x01, 0x41], blocks); UInt8[0x00]; original[20:end]]
    within, many = make(16_383), make(100_000)
    @test isequal(result("static.gif", within).image, Image("image/gif", base64encode(within)))
    @test isequal(result("static.gif", many).image, Image("image/gif", base64encode(many)))
    if haskey(ENV, "PI_SOURCE")
        mktempdir() do root
            write(joinpath(root, "within.gif"), within)
            write(joinpath(root, "many.gif"), many)
            source = ENV["PI_SOURCE"]
            reference = JSON3.read(read(`node $(joinpath(@__DIR__, "image_formats_pi.mjs")) $source $root within.gif many.gif`, String))
            @test all(length(item.read) == 2 && item.read[2].data == base64encode(bytes) for (item, bytes) in zip(reference, (within, many)))
        end
    end
end

@testset "GIF frames outside the canvas" begin
    original = read(joinpath(fixtures, "static.gif"))
    offset, small = copy(original), copy(original)
    offset[29] = 0x01
    small[7] = 0x02
    files = ("offset.gif", "small.gif")
    mktempdir() do root
        for (file, bytes) in zip(files, (offset, small))
            write(joinpath(root, file), bytes)
            @test isequal(execute(Read(root), (; path=file)).image, Image("image/gif", base64encode(bytes)))
            @test isequal(result(file, bytes).image, Image("image/gif", base64encode(bytes)))
        end
        if haskey(ENV, "PI_SOURCE")
            source = ENV["PI_SOURCE"]
            reference = JSON3.read(read(`node $(joinpath(@__DIR__, "image_formats_pi.mjs")) $source $root $files`, String))
            @test all(length(item.read) == 2 && item.read[2].data == base64encode(bytes) for (item, bytes) in zip(reference, (offset, small)))
        end
    end
end

function providerreply(api, first, name, arguments)
    if api == :chat
        call = Dict("id" => "image-call", "type" => "function", "function" => Dict("name" => name, "arguments" => arguments))
        message = first ? Dict("role" => "assistant", "content" => nothing, "tool_calls" => [call]) : Dict("role" => "assistant", "content" => "done")
        return Dict("choices" => [Dict("message" => message, "finish_reason" => first ? "tool_calls" : "stop")])
    elseif api == :responses
        output = first ? [Dict("type" => "function_call", "id" => "fc", "call_id" => "image-call", "name" => name, "arguments" => arguments, "status" => "completed")] : [Dict("type" => "message", "role" => "assistant", "content" => [Dict("type" => "output_text", "text" => "done")])]
        return Dict("status" => "completed", "output" => output)
    elseif api == :anthropic
        block = first ? Dict("type" => "tool_use", "id" => "image-call", "name" => name, "input" => JSON3.read(arguments, Dict{String, Any})) : Dict("type" => "text", "text" => "done")
        return Dict("content" => [block], "stop_reason" => first ? "tool_use" : "end_turn", "usage" => Dict("input_tokens" => 1, "output_tokens" => 1))
    end
    part = first ? Dict("functionCall" => Dict("id" => "image-call", "name" => name, "args" => JSON3.read(arguments, Dict{String, Any}))) : Dict("text" => "done")
    Dict("candidates" => [Dict("content" => Dict("role" => "model", "parts" => [part]), "finishReason" => "STOP")])
end

mutable struct ImageCompactionProvider
    file::String
    requests::Vector{Any}
end
function JuliaForever.complete(provider::ImageCompactionProvider, messages, tools)
    push!(provider.requests, deepcopy(messages))
    if length(provider.requests) == 2
        call = Dict("id" => "image", "type" => "function", "function" => Dict("name" => "read", "arguments" => JSON3.write(Dict("path" => provider.file))))
        return Dict{String, Any}("role" => "assistant", "content" => nothing, "tool_calls" => [call])
    end
    Dict{String, Any}("role" => "assistant", "content" => "done")
end

end
