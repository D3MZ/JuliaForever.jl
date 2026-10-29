using Test, JuliaForever, HTTP, JSON3, Base64, Distributed
import JuliaForever.History as ImageHistory
import JuliaForever.Conversation as ImageConversation
import JuliaForever.Kernel as ImageKernel

const imagepng = read(joinpath(@__DIR__, "fixtures", "pixel.png"))
const imagejpeg = read(joinpath(@__DIR__, "fixtures", "pixel.jpg"))

@testset "bounded image reads" begin
    mktempdir() do dir
        write(joinpath(dir, "pixels.txt"), imagepng)
        write(joinpath(dir, "photo.bin"), imagejpeg)
        write(joinpath(dir, "text.png"), "ordinary text\n")
        reader = Read(dir)
        result = execute(reader, (; path="pixels.txt", offset=9, limit=1))
        @test !result.iserror
        @test result.text == "Read image file [image/png]"
        @test result.image.mime == "image/png"
        @test base64decode(result.image.data) == imagepng
        jpeg = execute(reader, (; path="photo.bin"))
        @test jpeg.text == "Read image file [image/jpeg]"
        @test jpeg.image.mime == "image/jpeg"
        @test base64decode(jpeg.image.data) == imagejpeg
        text = execute(reader, (; path="text.png"))
        @test text.text == "ordinary text\n"
        @test text.image === nothing
        write(joinpath(dir, "bm.txt"), "BM")
        @test execute(reader, (; path="bm.txt")).text == "BM"
        write(joinpath(dir, "bm.txt"), "BM" * repeat("a", 30))
        @test execute(reader, (; path="bm.txt")).text == "BM" * repeat("a", 30)
        for (file, bytes) in (("animated.png", [imagepng[1:33]; UInt8[0,0,0,8,0x61,0x63,0x54,0x4c,0,0,0,1,0,0,0,0,0,0,0,0]; imagepng[34:end]]), ("unsupported.gif", collect(codeunits("GIF89a"))), ("unsupported.webp", collect(codeunits("RIFFabcdWEBP"))), ("unsupported.bmp", UInt8[0x42,0x4d,58,0,0,0,0,0,0,0,54,0,0,0,40,0,0,0,1,0,0,0,1,0,0,0,1,0,24,0,0,0]))
            write(joinpath(dir, file), bytes)
            unsupported = execute(reader, (; path=file))
            @test unsupported.iserror
            @test unsupported.image === nothing
            @test occursin("not supported", unsupported.text)
        end
        open(joinpath(dir, "big.png"), "w") do io
            write(io, imagepng)
            write(io, zeros(UInt8, 10 * 1024 * 1024))
        end
        oversized = execute(reader, (; path="big.png"))
        @test oversized.iserror
        @test oversized.image === nothing
        @test occursin("10 MiB", oversized.text)
    end
end

mutable struct ImageProvider
    replies::Vector{Any}
    requests::Vector{Any}
end
function JuliaForever.complete(provider::ImageProvider, messages, tools)
    push!(provider.requests, deepcopy(messages))
    popfirst!(provider.replies)
end

@testset "legacy text history records" begin
    initial = Dict{String, Any}("format" => "JuliaForever.Agent/1", "id" => "legacy", "automatic" => false, "messages" => Any[Dict{String, Any}("kind" => "tool_message", "fields" => Any["old", "text", false])])
    restored = ImageHistory.decode_initial(initial)
    @test restored isa ImageConversation.State
    @test only(restored.messages).image === nothing
    @test ImageHistory.encode_initial(restored) == initial
    record = Dict{String, Any}("format" => "JuliaForever.AgentEvent/1", "event" => Dict{String, Any}("kind" => "observe", "fields" => Any[2, "t", Dict{String, Any}("kind" => "tool_reply", "fields" => Any["read", false])]))
    event = ImageHistory.decode_event(record)
    @test event.observation.image === nothing
    @test ImageHistory.encode(event) == record
end

@testset "image typed history and replay" begin
    mktempdir() do dir
        write(joinpath(dir, "image"), imagepng)
        call = Dict{String, Any}("id" => "image-call", "type" => "function", "function" => Dict("name" => "read", "arguments" => "{\"path\":\"image\"}"))
        provider = ImageProvider(Any[Dict("role" => "assistant", "content" => nothing, "tool_calls" => [call]), Dict("role" => "assistant", "content" => "done"), Dict("role" => "assistant", "content" => "again")], Any[])
        history = ImageHistory.Memory()
        agent = Agent(provider, [Read(dir)]; history)
        @test respond!(agent, "read") == "done"
        tool = only(filter(message -> message isa ImageConversation.ToolMessage, agent.state.messages))
        @test tool.image.mime == "image/png"
        @test base64decode(tool.image.data) == imagepng
        observed = only(event for event in agent.events if event isa ImageKernel.Observe && event.observation isa ImageConversation.ToolReply)
        encoded = ImageHistory.encode(observed)
        @test ImageHistory.encode(ImageHistory.decode_event(encoded)) == encoded
        @test ImageKernel.step(agent.state, ImageHistory.decode_event(encoded)) isa ImageKernel.Duplicate
        changed = ImageKernel.Observe(observed.revision, observed.id, ImageConversation.ToolReply(observed.observation.text, false, Image("image/jpeg", base64encode(imagejpeg))))
        @test ImageKernel.step(agent.state, changed).reason == :observation_conflict
        @test JSON3.read(JuliaForever.Logs.json([observed]))[1].observation.image.data == base64encode(imagepng)
        write(joinpath(dir, "image"), "changed")
        restored = Agent(provider, [Read(dir)]; history)
        @test restored.messages == agent.messages
        @test respond!(restored, "again") == "again"
        message = only(filter(message -> message["role"] == "tool", provider.requests[3]))
        @test message["image"]["mime"] == "image/png"
        @test base64decode(message["image"]["data"]) == imagepng
    end
end

@testset "image provider inputs" begin
    for api in (:chat, :responses)
        mktempdir() do dir
            write(joinpath(dir, "image.png"), imagepng)
            write(joinpath(dir, "text.txt"), "words")
            requests = Any[]
            server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
                body = JSON3.read(String(request.body))
                push!(requests, body)
                if api == :chat
                    calls = [Dict("id" => "image", "type" => "function", "function" => Dict("name" => "read", "arguments" => "{\"path\":\"image.png\"}")), Dict("id" => "text", "type" => "function", "function" => Dict("name" => "read", "arguments" => "{\"path\":\"text.txt\"}"))]
                    message = length(requests) == 1 ? Dict("role" => "assistant", "content" => nothing, "tool_calls" => calls) : Dict("role" => "assistant", "content" => "done")
                    HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write((; choices=[(; message, finish_reason=length(requests) == 1 ? "tool_calls" : "stop")])))
                else
                    output = length(requests) == 1 ? [Dict("type" => "function_call", "id" => "fc1", "call_id" => "image", "name" => "read", "arguments" => "{\"path\":\"image.png\"}", "status" => "completed"), Dict("type" => "function_call", "id" => "fc2", "call_id" => "text", "name" => "read", "arguments" => "{\"path\":\"text.txt\"}", "status" => "completed")] : [Dict("type" => "message", "role" => "assistant", "content" => [Dict("type" => "output_text", "text" => "done")])]
                    HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write(Dict("status" => "completed", "output" => output)))
                end
            end
            try
                base = "http://$(HTTP.server_addr(server))/v1"
                model = api == :chat ? OpenAI(base, "synthetic", "key") : OpenAIResponses(base, "synthetic", "key")
                agent = Agent(model, [Read(dir)])
                @test respond!(agent, "read both"; tool_execution=:parallel) == "done"
                url = "data:image/png;base64," * base64encode(imagepng)
                if api == :chat
                    messages = requests[2].messages
                    @test [item.role for item in messages] == ["user", "assistant", "tool", "tool", "user"]
                    @test messages[3].content == "Read image file [image/png]"
                    @test messages[4].content == "words"
                    @test !haskey(messages[3], :image)
                    @test messages[5].content[1].text == "Attached image(s) from tool result:"
                    @test messages[5].content[2].image_url.url == url
                else
                    outputs = filter(item -> haskey(item, :type) && item.type == "function_call_output", requests[2].input)
                    @test outputs[1].output[1].type == "input_text"
                    @test outputs[1].output[1].text == "Read image file [image/png]"
                    @test outputs[1].output[2].type == "input_image"
                    @test outputs[1].output[2].image_url == url
                    @test outputs[2].output == "words"
                end
            finally
                close(server)
                wait(server)
            end
        end
    end
end

@testset "executor and SQLite image replay" begin
    mktempdir() do dir
        path = joinpath(dir, "image.png")
        write(path, imagepng)
        call = Dict{String, Any}("id" => "image-call", "type" => "function", "function" => Dict("name" => "read", "arguments" => "{\"path\":\"image.png\"}"))
        provider = ImageProvider(Any[Dict("role" => "assistant", "content" => nothing, "tool_calls" => [call]), Dict("role" => "assistant", "content" => "done")], Any[])
        history = open(ImageHistory.SQLite, joinpath(dir, "history.sqlite"))
        context = "image-test"
        @test JuliaForever.Execution.install!(context, provider, [Read(dir)])
        executor = JuliaForever.Execution.Executor(myid(); capacity=1)
        try
            agent = Agent(nothing, []; history)
            result = respond!(agent, "read"; executor, context)
            @test result.value == "done"
            @test base64decode(only(filter(message -> message["role"] == "tool", provider.requests[2]))["image"]["data"]) == imagepng
            close(history)
            rm(path)
            history = open(ImageHistory.SQLite, joinpath(dir, "history.sqlite"))
            restored = Agent(nothing, []; history)
            tool = only(filter(message -> message isa ImageConversation.ToolMessage, restored.state.messages))
            @test base64decode(tool.image.data) == imagepng
            @test length(provider.requests) == 2
            @test !isfile(path)
        finally
            close(history)
            close(executor)
            JuliaForever.Execution.uninstall!(context)
        end
    end
end

@testset "CodeMode rejects image results" begin
    mktempdir() do dir
        write(joinpath(dir, "image.png"), imagepng)
        result = codeexecute(CodeMode([Read(dir)]; timeout=30), "tools.read((; path=\"image.png\"))")
        @test result.ok
        @test result.value.iserror
        @test occursin("Image output is not supported", result.value.text)
    end
end
