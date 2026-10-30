using Test, JSON3, JuliaForever
const ResourceMCP = JuliaForever.MCP

mutable struct ResourceProvider
    requests::Vector{Any}
end

function JuliaForever.complete(provider::ResourceProvider, messages, tools)
    push!(provider.requests, deepcopy(messages))
    calls = (("list_mcp_resources", "{}"), ("read_mcp_resource", "{\"server\":\"docs\",\"uri\":\"docs://intro\"}"))
    length(provider.requests) > length(calls) && return Dict("role" => "assistant", "content" => "done")
    name, args = calls[length(provider.requests)]
    call = Dict("id" => name, "type" => "function", "function" => Dict("name" => name, "arguments" => args))
    Dict("role" => "assistant", "content" => nothing, "tool_calls" => [call])
end

resource_server(mode, marker) = `$(Base.julia_cmd()) --startup-file=no --project=$(dirname(Base.active_project())) $(joinpath(@__DIR__, "mcp_resources_server.jl")) $mode $marker`

@testset "MCP resources over stdio" begin
    mktempdir() do dir
        marker = joinpath(dir, "started")
        client = ResourceMCP.connect(resource_server("normal", marker); timeout=10, grace=0.2)
        @test client isa ResourceMCP.Client
        if client isa ResourceMCP.Client
            try
                selected = Dict{String, ResourceMCP.Client}()
                ResourceMCP.selectresource!(selected, "docs", client, nothing)
                @test isempty(selected)
                ResourceMCP.selectresource!(selected, "docs", client, Dict())
                @test selected["docs"] === client
                page = ResourceMCP.resourcepage(client)
                @test page["nextCursor"] == "opaque/+="
                @test ResourceMCP.resources(client)[end]["name"] == "docs://image"
                @test ResourceMCP.templates(client)[1]["name"] == "docs://{id}"
                @test ResourceMCP.read(client, "docs://intro")["contents"][1]["text"] == "hello: docs://intro"
                @test ResourceMCP.read(client, "docs://image")["contents"][1]["blob"] == "aGVsbG8="
                failure = ResourceMCP.read(client, "docs://missing")
                @test failure isa ResourceMCP.Failure && failure.kind == :rpc && failure.data["code"] == -32002
                failure = ResourceMCP.read(client, "docs://invalid")
                @test failure isa ResourceMCP.Failure && failure.kind == :protocol
                resource_tools = ResourceMCP.resourcetools(Dict("docs" => client))
                @test JuliaForever.name.(resource_tools) == ["list_mcp_resources", "list_mcp_resource_templates", "read_mcp_resource"]
                listed = JSON3.read(execute(resource_tools[1], (;)).text)
                @test [r.uri for r in listed.resources] == ["docs://intro", "docs://image"]
                @test listed.resources[1].server == "docs"
                @test !haskey(listed.resources[1], :_meta) && !haskey(listed.resources[1], :icons)
                paged = JSON3.read(execute(resource_tools[1], (; server="docs")).text)
                @test paged.nextCursor == "opaque/+="
                @test execute(resource_tools[3], (; server="docs", uri="docs://intro")).text == "hello: docs://intro"
                @test execute(resource_tools[3], (; server="docs", uri="docs://empty")).text == "Resource docs://empty is empty."
                @test execute(resource_tools[3], (; server="docs", uri="docs://multi")).text == "docs://a:\none\ndocs://b:\ntwo"
                @test JSON3.read(execute(resource_tools[3], (; server="docs", uri="docs://image")).text).blob == "aGVsbG8="
                provider = ResourceProvider([])
                @test respond!(Agent(provider, resource_tools), "read the guide") == "done"
                @test occursin("docs://intro", provider.requests[2][end]["content"])
                @test provider.requests[3][end]["content"] == "hello: docs://intro"
                @test execute(resource_tools[3], (; server="unknown", uri="docs://intro")) isa ToolFailure
                @test execute(resource_tools[1], (; cursor="opaque/+=")) isa ToolFailure
            finally
                close(client)
            end
            @test ResourceMCP.read(client, "docs://intro").kind == :closed
            @test ResourceMCP.resources(client).kind == :closed
        end
        for mode in ("loop", "badcursor", "badentry", "limit")
            invalid = ResourceMCP.connect(resource_server(mode, marker); timeout=10, grace=0.2)
            @test invalid isa ResourceMCP.Client
            if invalid isa ResourceMCP.Client
                @test ResourceMCP.resources(invalid).kind == :protocol
                close(invalid)
            end
        end
        unavailable = ResourceMCP.connect(resource_server("no_resources", marker); timeout=10, grace=0.2)
        @test unavailable isa ResourceMCP.Client
        if unavailable isa ResourceMCP.Client
            @test isempty(ResourceMCP.resourcetools(Dict("none" => unavailable)))
            @test ResourceMCP.resources(unavailable).kind == :capability
            @test ResourceMCP.read(unavailable, "docs://intro").kind == :capability
            close(unavailable)
        end
        badcap = ResourceMCP.connect(resource_server("badcap", marker); timeout=10, grace=0.2)
        @test badcap isa ResourceMCP.Client
        if badcap isa ResourceMCP.Client
            @test ResourceMCP.resources(badcap).kind == :capability
            close(badcap)
        end
        missing = ResourceMCP.connect(resource_server("no_templates", marker); timeout=10, grace=0.2)
        @test missing isa ResourceMCP.Client
        if missing isa ResourceMCP.Client
            @test ResourceMCP.templates(missing).kind == :rpc
            resource_tools = ResourceMCP.resourcetools(Dict("docs" => missing))
            @test isempty(JSON3.read(execute(resource_tools[2], (; server="docs")).text).resourceTemplates)
            @test isempty(JSON3.read(execute(resource_tools[2], (;)).text).resourceTemplates)
            dead = ResourceMCP.connect(resource_server("normal", marker); timeout=10, grace=0.2)
            @test dead isa ResourceMCP.Client
            if dead isa ResourceMCP.Client
                close(dead)
                multi = ResourceMCP.resourcetools(Dict("docs" => missing, "dead" => dead))
                listed = JSON3.read(execute(multi[1], (;)).text)
                @test [item.uri for item in listed.resources] == ["docs://intro", "docs://image"]
                @test only(listed.errors).server == "dead"
                @test execute(multi[3], (; server="dead", uri="docs://intro")) isa ToolFailure
            end
            close(missing)
        end
        waiting = ResourceMCP.connect(resource_server("normal", marker); timeout=10, grace=0.2)
        @test waiting isa ResourceMCP.Client
        if waiting isa ResourceMCP.Client
            timeout = ResourceMCP.read(waiting, "docs://wait"; timeout=0.2)
            @test timeout isa ResourceMCP.Failure && timeout.kind == :timeout
            @test timedwait(() -> isfile(marker * ".cancelled"), 5) == :ok
            rm(marker; force=true)
            pending = Threads.@spawn ResourceMCP.read(waiting, "docs://wait")
            @test timedwait(() -> isfile(marker), 5) == :ok
            close(waiting)
            @test timedwait(() -> istaskdone(pending), 5) == :ok
            @test fetch(pending).kind == :closed
            @test process_exited(waiting.process)
        end
    end
end
