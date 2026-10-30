module ContextImageCases

using Test, JuliaForever, HTTP, JSON3, Base64, Distributed
const J = JuliaForever
const C = J.Conversation
const E = J.Extensions
const X = J.Execution
const M = J.MCP

function response(index)
    calls = [Dict("id" => id, "type" => "function", "function" => Dict("name" => name, "arguments" => "{}")) for (id, name) in (("gif-call", "mcp_gif"), ("webp-call", "mcp_webp"), ("ghost-call", "ghost"))]
    message = index == 1 ? Dict("role" => "assistant", "content" => nothing, "tool_calls" => calls) : Dict("role" => "assistant", "content" => index == 2 ? "first" : index == 3 ? "followed-once" : index == 4 ? "followed" : "replayed")
    Dict("choices" => [Dict("message" => message, "finish_reason" => index == 1 ? "tool_calls" : "stop")])
end

@testset "context hooks preserve image history and tool permissions" begin
    fixtures = joinpath(@__DIR__, "fixtures")
    data = Dict(name => base64encode(read(joinpath(fixtures, name))) for name in ("pixel.png", "pixel.jpg", "interlaced.gif", "alpha.webp", "static.gif", "static.webp"))
    requests = Any[]
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        push!(requests, JSON3.read(String(request.body)))
        HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write(response(length(requests))))
    end
    try
        mktempdir() do root
            project = dirname(@__DIR__)
            command = `$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --project=$project $(joinpath(@__DIR__, "mcp_server.jl")) normal $(joinpath(root, "marker"))`
            client = M.connect(command; timeout=30, grace=0.2)
            @test client isa M.Client
            try
                schema = Dict("type" => "object", "properties" => Dict())
                tools = [M.RemoteTool(client, "image_gif", "mcp_gif", "GIF", schema), M.RemoteTool(client, "image_webp", "mcp_webp", "WebP", schema)]
                model = OpenAI("http://$(HTTP.server_addr(server))/v1", "fixture", "synthetic")
                for remote in (false, true), filtered in (false, true)
                    empty!(requests)
                    id = "context-images-$(remote)-$(filtered)"
                    pool = remote ? X.Executor(myid()) : nothing
                    remote && @test X.install!(id, model, tools)
                    historypath = joinpath(root, "$id.sqlite")
                    history = open(J.History.SQLite, historypath)
                    try
                        agent = remote ? Agent(nothing, []; history) : Agent(model, tools; history)
                        followup!(agent, C.ImagePrompt("queued", [Image("image/jpeg", data["pixel.jpg"]), Image("image/webp", data["alpha.webp"])]))
                        close(history)
                        history = open(J.History.SQLite, historypath)
                        agent = remote ? Agent(nothing, []; history) : Agent(model, tools; history)
                        pending = only(agent.state.followups)
                        @test pending.content == "queued" && [image.data for image in pending.images] == [data["pixel.jpg"], data["alpha.webp"]]
                        registry = E.Registry()
                        function filterimages(event)
                            filtered || return nothing
                            for message in event.messages
                                get(message, "content", nothing) in ("queued", "during") && delete!(message, "images")
                                get(message, "tool_call_id", nothing) == "gif-call" && delete!(message, "image")
                            end
                            nothing
                        end
                        function filtertools(event)
                            filtered || return nothing
                            event.messages[1]["toolsAdded"] = [Dict("name" => "ghost", "description" => "Ghost", "parameters" => schema)]
                            nothing
                        end
                        E.register!(registry, :fixture, E.Plugin(; hooks=(:context => filterimages, :context_with_system => filtertools)))
                        queued = Ref(false)
                        listener = E.listen(E.snapshot(registry); on_event=event -> begin
                            if event.type == :tool_execution_start && event.tool_call_id == "gif-call" && !queued[]
                                queued[] = true
                                followup!(agent, C.ImagePrompt("during", [Image("image/jpeg", data["pixel.jpg"]), Image("image/webp", data["alpha.webp"])]))
                            end
                        end)
                        prompt = C.ImagePrompt("initial", [Image("image/png", data["pixel.png"]), Image("image/gif", data["interlaced.gif"])])
                        result = remote ? respond!(agent, prompt; executor=pool, context=id, on_agent_event=listener) : respond!(agent, prompt; on_agent_event=listener)
                        @test (remote ? result.value : result) == "followed"
                        @test length(requests) == 4
                        @test Set(String(tool.function.name) for tool in requests[1].tools) == (filtered ? Set(["ghost"]) : Set(["mcp_gif", "mcp_webp"]))
                        firstwire, toolwire, queuewire, laterwire = JSON3.write.(requests)
                        @test all(name -> occursin(data[name], firstwire) && occursin(data[name], queuewire), ("pixel.png", "interlaced.gif"))
                        @test occursin(data["static.webp"], toolwire) && occursin(data["static.gif"], toolwire) == !filtered
                        @test all(name -> occursin(data[name], queuewire) == !filtered, ("pixel.jpg", "alpha.webp"))
                        @test all(name -> occursin(data[name], laterwire) == !filtered, ("pixel.jpg", "alpha.webp"))
                        saved = deepcopy(agent.messages)
                        gif = only(message for message in saved if get(message, "tool_call_id", "") == "gif-call")
                        webp = only(message for message in saved if get(message, "tool_call_id", "") == "webp-call")
                        ghost = only(message for message in saved if get(message, "tool_call_id", "") == "ghost-call")
                        @test base64decode(gif["image"]["data"]) == base64decode(data["static.gif"])
                        @test base64decode(webp["image"]["data"]) == base64decode(data["static.webp"])
                        @test ghost["is_error"] && !haskey(ghost, "image")
                        @test all(name -> occursin(data[name], JSON3.write(saved)), ("pixel.png", "interlaced.gif", "pixel.jpg", "alpha.webp"))
                        close(history)
                        history = open(J.History.SQLite, historypath)
                        restored = remote ? Agent(nothing, []; history) : Agent(model, tools; history)
                        @test restored.messages == saved
                        result = remote ? respond!(restored, "resume"; executor=pool, context=id, on_agent_event=listener) : respond!(restored, "resume"; on_agent_event=listener)
                        @test (remote ? result.value : result) == "replayed"
                        replaywire = JSON3.write(last(requests))
                        @test occursin(data["static.webp"], replaywire) && occursin(data["static.gif"], replaywire) == !filtered
                        @test all(name -> occursin(data[name], replaywire) == !filtered, ("pixel.jpg", "alpha.webp"))
                        @test all(name -> occursin(data[name], replaywire), ("pixel.png", "interlaced.gif"))
                        @test restored.messages[1:end-2] == saved
                    finally
                        close(history)
                        if remote
                            close(pool)
                            X.uninstall!(id)
                        end
                    end
                end
            finally
                close(client)
            end
        end
    finally
        close(server)
        wait(server)
    end
end

end
