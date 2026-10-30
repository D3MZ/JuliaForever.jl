module ContextDistributedCases
using Test, JuliaForever, HTTP, JSON3, Distributed
const J = JuliaForever
const E = J.Extensions
const X = J.Execution

@testset "request context crosses a distributed executor boundary" begin
    requests = Any[]
    server = HTTP.serve!("127.0.0.1", 0; listenany=true) do request
        push!(requests, JSON3.read(String(request.body)))
        body = Dict("id" => "r", "status" => "completed", "output" => [Dict("type" => "message", "id" => "m", "role" => "assistant", "status" => "completed", "content" => [Dict("type" => "output_text", "text" => "done", "annotations" => [])])])
        HTTP.Response(200, ["Content-Type" => "application/json"], JSON3.write(body))
    end
    try
        project = dirname(@__DIR__)
        pid = only(addprocs(1; exeflags=`--startup-file=no --compiled-modules=existing --compile=min -O0 --project=$project`))
        try
            remotecall_wait(Core.eval, pid, Main, :(using JuliaForever))
            mktempdir() do dir
                provider = OpenAIResponses("http://$(HTTP.server_addr(server))/v1", "gpt-5.4", "synthetic-key")
                @test remotecall_fetch(X.install!, pid, "context-remote", provider, [Write(dir)])
                pool = X.Executor(pid)
                try
                    registry = E.Registry()
                    E.register!(registry, :fixture, E.Plugin(; hooks=(:context_with_system => event -> (push!(event.messages, Dict("role" => "system", "content" => "extra")); nothing),)))
                    agent = Agent(nothing, Dict{String, J.Tool}(), Dict{String, Any}[Dict("role" => "system", "content" => "base")]; history=J.History.Memory())
                    @test respond!(agent, "hello"; executor=pool, context="context-remote", on_agent_event=E.listen(E.snapshot(registry))).value == "done"
                    additions = filter(item -> get(item, :type, "") == "additional_tools", only(requests).input)
                    @test [tool.name for tool in only(additions).tools] == ["write"]

                    seen = Any[]
                    filtered = E.Registry()
                    E.register!(filtered, :fixture, E.Plugin(; hooks=(:context_with_system => event -> begin
                        push!(seen, [tool["name"] for tool in get(event.messages[1], "toolsAdded", [])])
                        event.messages[1]["toolsAdded"] = []
                        nothing
                    end,)))
                    agent = Agent(nothing, Dict{String, J.Tool}(), Dict{String, Any}[Dict("role" => "system", "content" => "base")]; history=J.History.Memory())
                    @test respond!(agent, "hello"; executor=pool, context="context-remote", on_agent_event=E.listen(E.snapshot(filtered))).value == "done"
                    @test only(seen) == ["write"]
                    @test !any(item -> get(item, :type, "") == "additional_tools", requests[2].input)
                    @test !haskey(requests[2], :tools)

                    changed = E.Registry()
                    E.register!(changed, :fixture, E.Plugin(; hooks=(:context_with_system => event -> begin
                        remotecall_wait(X.uninstall!, pid, "context-remote")
                        @test remotecall_fetch(X.install!, pid, "context-remote", provider, [])
                        nothing
                    end,)))
                    agent = Agent(nothing, Dict{String, J.Tool}(), Dict{String, Any}[Dict("role" => "system", "content" => "base")]; history=J.History.Memory())
                    @test respond!(agent, "hello"; executor=pool, context="context-remote", on_agent_event=E.listen(E.snapshot(changed))).value == X.Rejected(:provider_failure)
                    @test length(requests) == 2
                finally
                    close(pool)
                    remotecall_wait(X.uninstall!, pid, "context-remote")
                end
            end
        finally
            rmprocs(pid)
        end
    finally
        close(server)
        wait(server)
    end
end

end
