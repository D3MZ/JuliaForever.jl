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

@testset "image prompts survive history and branches" begin
    mktempdir() do root
        image = Image("image/png", base64encode(read(joinpath(@__DIR__, "fixtures", "pixel.png"))))
        other = Image("image/gif", base64encode("GIF89a"))
        images = [image, other]
        prompt = FileConversation.ImagePrompt("look", images)
        empty!(images)
        @test length(prompt.images) == 2
        path = joinpath(root, "history.sqlite")
        history = FileHistory.Tree(open(FileHistory.SQLite, path))
        provider = FileProvider([])
        agent = Agent(provider, []; history)
        @test respond!(agent, prompt) == "done"
        original = only(message for message in agent.state.messages if message isa FileConversation.ImageUser)
        @test original.content == "look" && original.images == [image, other]
        @test last(provider.requests)[end]["images"][1]["data"] == image.data
        @test FileEstimates.tokens(original) == FileEstimates.tokens(FileConversation.RawMessage(convert(Dict{String, Any}, original)))
        events = FileHistory.entries(history)
        entry = only(item for item in events if FileHistory.decode_event(only(item.batch)) isa FileConversation.ImageInput)
        record = only(entry.batch)
        @test FileHistory.encode(FileHistory.decode_event(record)) == record
        @test any(choice -> choice.text == "look", JuliaForever.TreeTerminal.choices(FileHistory.branches(history)))
        @test JuliaForever.SessionCatalog.firstprompt(FileHistory.entries(history)) == "look"
        close(history)
        reopened = FileHistory.Tree(open(FileHistory.SQLite, path; create=false))
        restored = Agent(provider, []; history=reopened)
        @test restored.fault === nothing
        @test respond!(restored, "next") == "done"
        @test last(provider.requests)[1]["images"] == [Dict("mime" => image.mime, "data" => image.data), Dict("mime" => other.mime, "data" => other.data)]
        close(reopened)
    end
end

@testset "image prompt provider encodings" begin
    image = Image("image/png", base64encode(read(joinpath(@__DIR__, "fixtures", "pixel.png"))))
    message = convert(Dict{String, Any}, FileConversation.ImageUser("what?", [image]))
    tools = Dict{String, JuliaForever.Tool}()
    for (name, provider) in ((:openai, OpenAI("http://localhost", "fixture", "key")), (:responses, OpenAIResponses("http://localhost", "fixture", "key")), (:anthropic, Anthropic("http://localhost", "fixture", "key")), (:google, Google("http://localhost", "gemini-3-fixture", "key")))
        request = JSON3.read(JuliaForever.payload(provider, [message], tools, Dict()))
        if name == :openai
            parts = request.messages[1].content
            @test parts[1].text == "what?"
            @test parts[2].image_url.url == "data:image/png;base64," * image.data
        elseif name == :responses
            parts = request.input[1].content
            @test parts[1].text == "what?"
            @test parts[2].image_url == "data:image/png;base64," * image.data
        elseif name == :anthropic
            parts = request.messages[1].content
            @test parts[1].text == "what?"
            @test parts[2].source.media_type == "image/png" && parts[2].source.data == image.data
        else
            parts = request.contents[1].parts
            @test parts[1].text == "what?"
            @test parts[2].inlineData.mimeType == "image/png" && parts[2].inlineData.data == image.data
        end
    end
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
        path = replace(joinpath(root, "photo 4\u202fPM.png"), '\\' => '/', " " => "%20", "\u202f" => "%E2%80%AF")
        url = (Sys.iswindows() ? "file:///" : "file://") * path
        @test JuliaForever.FileArguments.resolve(url, root) == joinpath(root, "photo 4\u202fPM.png")
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

@testset "image prompts reach provider loopback endpoints" begin
    requests = Any[]
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        push!(requests, JSON3.read(String(request.body)))
        if occursin("chat/completions", request.target)
            data = Dict("choices" => [Dict("message" => Dict("role" => "assistant", "content" => "done"), "finish_reason" => "stop")])
        elseif endswith(request.target, "/responses")
            data = Dict("status" => "completed", "output" => [Dict("type" => "message", "role" => "assistant", "content" => [Dict("type" => "output_text", "text" => "done")])])
        elseif endswith(request.target, "/messages")
            data = Dict("id" => "msg-1", "type" => "message", "role" => "assistant", "content" => [Dict("type" => "text", "text" => "done")], "stop_reason" => "end_turn", "usage" => Dict("input_tokens" => 1, "output_tokens" => 1))
        else
            data = Dict("candidates" => [Dict("content" => Dict("role" => "model", "parts" => [Dict("text" => "done")]), "finishReason" => "STOP")])
        end
        HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write(data))
    end
    try
        base = "http://$(HTTP.server_addr(server))"
        image = Image("image/png", base64encode(read(joinpath(@__DIR__, "fixtures", "pixel.png"))))
        prompt = FileConversation.ImagePrompt("look", [image])
        providers = (OpenAI(base, "fixture", "key"), OpenAIResponses(base, "fixture", "key"), Anthropic(base, "fixture", "key"), Google(base, "gemini-3-fixture", "key"))
        for provider in providers
            @test respond!(Agent(provider, []), prompt) == "done"
        end
        @test length(requests) == 4
        @test requests[1].messages[1].content[2].image_url.url == "data:image/png;base64," * image.data
        @test requests[2].input[1].content[2].image_url == "data:image/png;base64," * image.data
        @test requests[3].messages[1].content[2].source.data == image.data
        @test requests[4].contents[1].parts[2].inlineData.data == image.data
    finally
        close(server)
        wait(server)
    end
end
