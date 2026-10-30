module ImageProviderBoundaryTests

using Test, JuliaForever, JSON3

call(id, path) = Dict("id" => id, "type" => "function", "function" => Dict("name" => "read", "arguments" => JSON3.write(Dict("path" => path))))
image(mime, data) = Dict("mime" => mime, "data" => data)
user = Dict("role" => "user", "content" => "hello")
assistant(calls...) = Dict("role" => "assistant", "content" => nothing, "tool_calls" => [calls...])
tool(id, text; image=nothing, error=false) = merge(Dict{String, Any}("role" => "tool", "tool_call_id" => id, "content" => text, "is_error" => error), isnothing(image) ? Dict() : Dict("image" => image))
png = image("image/png", "cG5n")
jpeg = image("image/jpeg", "anBn")
scenarios = [
    [user, assistant(call("call-1", "picture.png"), call("call-2", "photo.jpg"), call("call-3", "notes.txt")), tool("call-1", "read image"; image=png), tool("call-2", "error text"; image=jpeg, error=true), tool("call-3", "notes")],
    [user, assistant(call("call-1", "picture.png")), tool("call-1", ""; image=png)],
    [user, assistant(call("call-1", "picture.png")), tool("call-1", ""; image=png, error=true)]
]

@testset "Anthropic and Google retain tool images" begin
    providers = [("anthropic", Anthropic("http://fixture.invalid", "claude-fixture", "synthetic")), [(id, Google("http://fixture.invalid", id, "synthetic")) for id in ("gemini-2-fixture", "gemini-3-fixture", "custom-model")]...]
    outputs = Dict()
    for (index, messages) in enumerate(scenarios), (name, provider) in providers
        body = JuliaForever.payload(provider, messages, Dict(), Dict())
        @test body isa AbstractString
        if body isa AbstractString
            outputs[(index, name)] = JSON3.read(body, Dict{String, Any})
        end
    end
    if length(outputs) == length(scenarios) * length(providers)
        anthropic = outputs[(1, "anthropic")]["messages"][3]["content"]
        @test [block["type"] for block in anthropic] == ["tool_result", "tool_result", "tool_result", "text", "image"]
        @test anthropic[1]["content"][2]["source"]["data"] == png["data"]
        @test anthropic[2]["content"] == "error text\n(image attached after the tool results)"
        @test anthropic[4]["text"] == "Images from the error result of tool call call-2 (read):"
        @test anthropic[5]["source"]["data"] == jpeg["data"]
        old = outputs[(1, "gemini-2-fixture")]["contents"]
        @test old[4]["parts"][2]["inlineData"]["data"] == png["data"]
        @test old[6]["parts"][2]["inlineData"]["data"] == jpeg["data"]
        @test old[7]["parts"][1]["functionResponse"]["response"]["output"] == "notes"
        for id in ("gemini-3-fixture", "custom-model")
            parts = outputs[(1, id)]["contents"][3]["parts"]
            @test parts[1]["functionResponse"]["parts"][1]["inlineData"]["data"] == png["data"]
            @test parts[2]["functionResponse"]["parts"][1]["inlineData"]["data"] == jpeg["data"]
            @test parts[2]["functionResponse"]["response"]["error"] == "error text"
            @test outputs[(2, id)]["contents"][3]["parts"][1]["functionResponse"]["response"]["output"] == "(see attached image)"
        end
    end
    if haskey(ENV, "PI_SOURCE") && length(outputs) == length(scenarios) * length(providers)
        source = ENV["PI_SOURCE"]
        @test strip(read(`git -C $source rev-parse HEAD`, String)) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
        mktemp() do path, io
            write(io, JSON3.write(scenarios))
            flush(io)
            reference = JSON3.read(read(`node $(joinpath(@__DIR__, "provider_image_reference.mjs")) $source $path`, String), Vector{Dict{String, Any}})
            for index in eachindex(scenarios)
                @test outputs[(index, "anthropic")]["messages"] == reference[index]["anthropic"]
                for id in ("gemini-2-fixture", "gemini-3-fixture", "custom-model")
                    @test outputs[(index, id)]["contents"] == reference[index]["google"][id]
                end
            end
        end
    end
end

end
