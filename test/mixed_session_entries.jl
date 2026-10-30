module MixedSessionEntriesTests

using Test, JuliaForever, JSON3, Base64
import JuliaForever as J

struct Provider
    model::String
end
function J.complete(::Provider, messages, tools; parameters=Dict())
    text = get(last(messages), "content", "")
    if get(last(messages), "role", "") == "user" && text in ("tool", "tool-image")
        path = text == "tool" ? "target.txt" : "target.png"
        id = text == "tool" ? "read-1" : "read-image"
        call = Dict("id" => id, "type" => "function", "function" => Dict("name" => "read", "arguments" => JSON3.write((; path))))
        return Completion(Dict{String, Any}("role" => "assistant", "content" => nothing, "tool_calls" => [call]), nothing, "tool_calls", true, nothing)
    end
    Completion(Dict{String, Any}("role" => "assistant", "content" => "answer"), nothing, "stop", true, nothing)
end
function J.stream(provider::Provider, messages, tools; parameters=Dict(), on_event=identity)
    result = J.complete(provider, messages, tools; parameters)
    on_event((; type=:text, text="answer"))
    on_event((; type=:done, result))
    result
end

@testset "record messages produced by native sessions before switching modes" begin
    for mode in (:json, :rpc, :text)
        mktempdir() do root
            write(joinpath(root, "target.txt"), "saved tool output")
            bytes = read(joinpath(@__DIR__, "fixtures", "pixel.png"))
            write(joinpath(root, "target.png"), bytes)
            history = J.History.Memory()
            agent = Agent(Provider("fixture"), [Read(root)]; history)
            json = J.Terminal(IOBuffer(), IOBuffer(), String[], J.JSONMode("fixture"))
            @test J.run!(json, agent, "first") == 0
            @test respond!(agent, "repeat") == "answer"
            @test respond!(agent, "repeat") == "answer"
            @test respond!(agent, "tool") == "answer"
            @test respond!(agent, "tool-image") == "answer"
            image = J.Image("image/png", "aW1hZ2U=")
            @test respond!(agent, J.Conversation.ImagePrompt("image", [image])) == "answer"
            if mode == :json
                @test J.run!(json, agent, "after") == 0
            elseif mode == :text
                text = J.Terminal(IOBuffer(), IOBuffer(), String[], J.TextMode("fixture"))
                @test J.run!(text, agent, "after") == 0
            end
            terminal = J.Terminal(IOBuffer(), IOBuffer(), String[], J.RPCMode("fixture", "off"))
            session = J.Headless.Session(terminal, agent, nothing, Ref(history), nothing, root)
            response = J.Headless.handle!(session, J.Headless.GetEntries(nothing))
            entries = response.fields.data.entries
            users = [entry for entry in entries if entry["type"] == "message" && get(entry["message"], "role", "") == "user"]
            texts = [join(get(block, "text", "") for block in entry["message"]["content"]) for entry in users]
            @test texts == (mode == :rpc ? ["first", "repeat", "repeat", "tool", "tool-image", "image"] : ["first", "repeat", "repeat", "tool", "tool-image", "image", "after"])
            @test length(unique(entry["id"] for entry in users)) == length(users)
            @test any(block -> get(block, "type", "") == "image" && get(block, "data", "") == "aW1hZ2U=", only(entry for entry in users if any(block -> get(block, "text", "") == "image", entry["message"]["content"]))["message"]["content"])
            @test any(entry -> entry["type"] == "message" && get(entry["message"], "role", "") == "toolResult" && get(entry["message"], "toolName", "") == "read" && occursin("saved tool output", JSON3.write(entry["message"])), entries)
            @test any(entry -> entry["type"] == "message" && get(entry["message"], "toolCallId", "") == "read-image" && occursin(base64encode(bytes), JSON3.write(entry["message"])), entries)
            again = J.Headless.Session(terminal, agent, nothing, Ref(history), nothing, root)
            @test length(J.Headless.handle!(again, J.Headless.GetEntries(nothing)).fields.data.entries) == length(entries)
        end
    end
end

@testset "recover tool results after a recorded tool call" begin
    for mode in (:json, :rpc, :text)
        mktempdir() do root
            write(joinpath(root, "target.txt"), "saved tool output")
            history = J.History.Memory()
            agent = Agent(Provider("fixture"), [Read(root)]; history)
            json = J.Terminal(IOBuffer(), IOBuffer(), String[], J.JSONMode("fixture"))
            @test J.run!(json, agent, "first") == 0
            recorder = J.LiveJSON.Recorder(agent)
            stream = J.LiveJSON.Stream(json, agent, json.mode, devnull)
            callback = event -> begin
                if event.type == :message_end && (get(event.message, "role", "") == "user" || haskey(event.message, "tool_calls"))
                    J.LiveJSON.observejson!(stream, recorder, event)
                end
            end
            @test respond!(agent, "tool"; on_agent_event=callback) == "answer"
            if mode == :json
                @test J.run!(json, agent, "after") == 0
            elseif mode == :text
                text = J.Terminal(IOBuffer(), IOBuffer(), String[], J.TextMode("fixture"))
                @test J.run!(text, agent, "after") == 0
            end
            terminal = J.Terminal(IOBuffer(), IOBuffer(), String[], J.RPCMode("fixture", "off"))
            session = J.Headless.Session(terminal, agent, nothing, Ref(history), nothing, root)
            entries = J.Headless.handle!(session, J.Headless.GetEntries(nothing)).fields.data.entries
            tools = [entry["message"] for entry in entries if entry["type"] == "message" && get(entry["message"], "role", "") == "toolResult"]
            @test length(tools) == 1 && only(tools)["toolCallId"] == "read-1" && only(tools)["toolName"] == "read"
        end
    end
end

end
