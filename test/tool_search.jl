using Test, JuliaForever, JSON3
import JuliaForever.History as SearchHistory
import JuliaForever.Conversation as SearchConversation
import JuliaForever.Kernel as SearchKernel

struct CatalogTool <: JuliaForever.Tool
    id::String
    doc::String
    parameters::Dict{String, Any}
end
JuliaForever.name(tool::CatalogTool) = tool.id
JuliaForever.description(tool::CatalogTool) = tool.doc
JuliaForever.schema(tool::CatalogTool) = tool.parameters
JuliaForever.execute(tool::CatalogTool, args) = ToolSuccess("$(tool.id) ran")

struct NamedSchemaTool <: JuliaForever.Tool end
JuliaForever.name(::NamedSchemaTool) = "named_schema"
JuliaForever.description(::NamedSchemaTool) = "Native Julia schema"
JuliaForever.schema(::NamedSchemaTool) = (; type="object", properties=(; query=(; anyOf=((; description="Quasar observation"),))))

catalogtool(id, doc) = CatalogTool(id, doc, Dict{String, Any}("type" => "object"))
function catalog()
    ToolSet([catalogtool("alpha", "Alpha"), catalogtool("omega", "Omega")], [catalogtool("github_get_issue", "Get a GitHub issue"), catalogtool("github_list_repos", "List repositories")])
end

mutable struct CatalogProvider
    responses::Vector{Dict{String, Any}}
    offered::Vector{Vector{String}}
end
function JuliaForever.complete(provider::CatalogProvider, messages, tools)
    push!(provider.offered, [JuliaForever.name(tool) for tool in values(tools)])
    popfirst!(provider.responses)
end
function JuliaForever.stream(provider::CatalogProvider, messages, tools; parameters=Dict(), on_event=identity)
    message = JuliaForever.complete(provider, messages, tools)
    Completion(message, nothing, "stop", true, nothing)
end
searchcall(id, tool, args) = Dict("id" => id, "type" => "function", "function" => Dict("name" => tool, "arguments" => JSON3.write(args)))
searchreply(calls...) = Dict{String, Any}("role" => "assistant", "content" => nothing, "tool_calls" => collect(calls))
searchdone() = Dict{String, Any}("role" => "assistant", "content" => "done")
searchprovider(responses...) = CatalogProvider(Dict{String, Any}[responses...], Vector{String}[])
toolnames(tools) = [JuliaForever.name(tool) for tool in values(tools)]

@testset "deferred tool exposure" begin
    standalone = catalog()
    @test haskey(standalone, "alpha")
    @test !haskey(standalone, "github_get_issue")
    @test JuliaForever.name(get(standalone, "alpha", nothing)) == "alpha"
    @test get(standalone, "missing", nothing) === nothing
    @test get(standalone, :alpha, :fallback) === :fallback
    fallbackcalls = Ref(0)
    fallback() = (fallbackcalls[] += 1; :fallback)
    @test JuliaForever.name(get(fallback, standalone, "alpha")) == "alpha"
    @test get(fallback, standalone, "missing") === :fallback
    @test fallbackcalls[] == 1
    @test "alpha" in keys(standalone)
    @test execute(standalone["tool_search"], (; query="issue")).text == "Loaded 1 tool. They are available from your next call:\n- github_get_issue: Get a GitHub issue"
    @test toolnames(standalone) == ["alpha", "omega", "tool_search", "github_get_issue"]
    @test execute(standalone["tool_search"], (; query="issue")).text == "No matching tools found."

    provider = searchprovider(searchreply(searchcall("1", "tool_search", (; query="issue", limit=1))), searchreply(searchcall("2", "github_get_issue", (;))), searchdone())
    agent = Agent(provider, catalog())
    @test respond!(agent, "find and run") == "done"
    @test provider.offered == [["alpha", "omega", "tool_search"], ["alpha", "omega", "tool_search", "github_get_issue"], ["alpha", "omega", "tool_search", "github_get_issue"]]
    @test [message["content"] for message in agent.messages if message["role"] == "tool"] == ["Loaded 1 tool. They are available from your next call:\n- github_get_issue: Get a GitHub issue", "github_get_issue ran"]
    @test_throws KeyError agent.tools["github_list_repos"]

    streamed = searchprovider(searchreply(searchcall("1", "tool_search", (; query="repositories"))), searchdone())
    @test respond!(Agent(streamed, catalog()), "find"; on_event=identity) == "done"
    @test last(streamed.offered) == ["alpha", "omega", "tool_search", "github_list_repos"]

    parallel = searchprovider(searchreply(searchcall("1", "tool_search", (; query="repositories")), searchcall("2", "tool_search", (; query="issue"))), searchdone())
    @test respond!(Agent(parallel, catalog()), "find"; tool_execution=:parallel) == "done"
    @test last(parallel.offered) == ["alpha", "omega", "tool_search", "github_list_repos", "github_get_issue"]
end

@testset "unknown, duplicate, and late tools" begin
    @test toolnames(ToolSet([], [])) == ["tool_search"]
    set = catalog()
    @test Base.IteratorSize(typeof(values(set))) == Base.SizeUnknown()
    @test expose!(set, ["later", "alpha", "later", "github_get_issue", "github_get_issue"]) == (; loaded=["github_get_issue"], unknown=["later"], duplicates=["alpha", "later", "github_get_issue"])
    @test toolnames(set) == ["alpha", "omega", "tool_search", "github_get_issue"]
    @test register!(set, catalogtool("later", "Late tool")) == ToolSuccess("Registered later")
    @test toolnames(set) == ["alpha", "omega", "tool_search", "later", "github_get_issue"]
    @test register!(set, catalogtool("later", "Duplicate")) == ToolFailure("Duplicate tool name: later")
    @test unregister!(set, "alpha") == ToolFailure("Unknown deferred tool: alpha")
    @test unregister!(set, "later") == ToolSuccess("Unregistered later")
    @test toolnames(set) == ["alpha", "omega", "tool_search", "github_get_issue"]
    @test register!(set, catalogtool("later", "Reconnected")) == ToolSuccess("Registered later")
    @test toolnames(set) == ["alpha", "omega", "tool_search", "later", "github_get_issue"]
    @test ToolSet([catalogtool("alpha", "One")], [catalogtool("alpha", "Two")]) == ToolFailure("Duplicate tool names: alpha")
    @test ToolSet([catalogtool("tool_search", "Reserved")], CatalogTool[]) == ToolFailure("Duplicate tool names: tool_search")

    changing = ToolSet([], [])
    expose!(changing, ["late"])
    writer = Threads.@spawn for _ in 1:500
        register!(changing, catalogtool("late", "Late"))
        unregister!(changing, "late")
    end
    snapshots = [toolnames(changing) for _ in 1:500]
    fetch(writer)
    @test all(names -> names == ["tool_search"] || names == ["tool_search", "late"], snapshots)
end

@testset "search arguments and metadata" begin
    set = catalog()
    search = set["tool_search"]
    @test execute(search, (; query="  ")) == ToolFailure("query must not be empty")
    @test execute(search, (; query="issue", limit=0)) == ToolFailure("limit must be a positive integer")
    @test execute(search, (; query="issue", limit=true)) == ToolFailure("limit must be a positive integer")
    @test execute(search, (; query="issue", limit=1.2)) == ToolFailure("limit must be a positive integer")
    @test execute(search, (; limit=1)) == ToolFailure("query must be a string")
    @test execute(search, (; query="nothing like these")).text == "No matching tools found."
    blank = ToolSet(CatalogTool[], [catalogtool("empty_description", "")])
    @test execute(blank["tool_search"], (; query="empty_description")).text == "Loaded 1 tool. They are available from your next call:\n- empty_description: "
    native = ToolSet([], [NamedSchemaTool()])
    @test execute(native["tool_search"], (; query="quasar")).text == "Loaded 1 tool. They are available from your next call:\n- named_schema: Native Julia schema"

    nested = Dict{String, Any}("type" => "object", "properties" => Dict("filter" => Dict("items" => Dict("oneOf" => [Dict("description" => "Archived milestone")]))))
    tool = CatalogTool("mcp__dev-app__thread_read", "Read a durable thread.\nLong description.", nested)
    namespace = ToolNamespace("mcp__dev-app"; description="Kubernetes cluster", instructions="Discover team schedules")
    for query in ("milestones", "kubernetes", "schedules", "dev_app__thread_read")
        set = ToolSet(CatalogTool[], [tool]; namespaces=Dict(tool.id => namespace))
        search = set["tool_search"]
        result = execute(search, (; query))
        @test result.text == "Loaded 1 tool. They are available from your next call:\n- mcp__dev-app__thread_read: Read a durable thread."
    end
end

@testset "provider tool declarations" begin
    set = catalog()
    input = [Dict{String, Any}("role" => "user", "content" => "hello")]
    providers = [OpenAI("https://example.invalid", "test", "key"), OpenAIResponses("https://example.invalid", "test", "key"), Anthropic("https://example.invalid", "test", "key"), Google("https://example.invalid", "test", "key")]
    for expected in (["alpha", "omega", "tool_search"], ["alpha", "omega", "tool_search", "github_get_issue"])
        for (index, provider) in enumerate(providers)
            data = JSON3.read(JuliaForever.payload(provider, input, set, Dict()))
            names = index == 1 ? [tool.function.name for tool in data.tools] : index == 4 ? [tool.name for tool in only(data.tools).functionDeclarations] : [tool.name for tool in data.tools]
            @test names == expected
        end
        expose!(set, ["github_get_issue"])
    end
end

@testset "deferred MCP tools" begin
    mktempdir() do dir
        script = joinpath(@__DIR__, "mcp_server.jl")
        marker = joinpath(dir, "marker")
        command = `$(Base.julia_cmd()) --startup-file=no --project=$(dirname(Base.active_project())) $script normal $marker`
        client = JuliaForever.MCP.connect(command; timeout=10, grace=0.2)
        @test client isa JuliaForever.MCP.Client
        try
            tools = JuliaForever.MCP.tools(client)
            provider = searchprovider(searchreply(searchcall("1", "tool_search", (; query="value", limit=1))), searchreply(searchcall("2", "mcp_alpha", (; value=42))), searchdone())
            agent = Agent(provider, ToolSet(CatalogTool[], tools))
            @test respond!(agent, "find and call") == "done"
            @test provider.offered == [["tool_search"], ["tool_search", "mcp_alpha"], ["tool_search", "mcp_alpha"]]
            @test [message["content"] for message in agent.messages if message["role"] == "tool"] == ["Loaded 1 tool. They are available from your next call:\n- mcp_alpha: First", "alpha:42"]
        finally
            close(client)
        end
    end
end

struct RejectSearchHistory <: SearchHistory.Store
    store::SearchHistory.Memory
end
SearchHistory.snapshot(history::RejectSearchHistory) = SearchHistory.snapshot(history.store)
function SearchHistory.append!(history::RejectSearchHistory, revision::Integer, batch::Vector)
    occursin("tool_search_reply", repr(batch)) && return SearchHistory.Rejected(:search_rejected)
    SearchHistory.append!(history.store, revision, batch)
end

@testset "recorded and branched exposure" begin
    provider = searchprovider(searchdone(), searchreply(searchcall("1", "tool_search", (; query="issue"))), searchdone())
    tree = SearchHistory.Tree(SearchHistory.Memory())
    agent = Agent(provider, catalog(); history=tree)
    @test respond!(agent, "before") == "done"
    before = last(SearchHistory.entries(tree)).id
    @test respond!(agent, "find") == "done"
    after = last(SearchHistory.entries(tree)).id
    @test last(provider.offered) == ["alpha", "omega", "tool_search", "github_get_issue"]
    @test SearchHistory.branch!(tree, before) == before
    @test toolnames(Agent(provider, agent.tools; history=tree).tools) == ["alpha", "omega", "tool_search"]
    @test SearchHistory.branch!(tree, after) == after
    restored = Agent(provider, agent.tools; history=tree)
    @test toolnames(restored.tools) == ["alpha", "omega", "tool_search", "github_get_issue"]
    @test SearchHistory.decode_event(SearchHistory.encode(last(filter(event -> event isa SearchKernel.Observe{SearchConversation.ToolReply}, restored.events)))) isa SearchKernel.Observe{SearchConversation.ToolReply}
    missing = ToolSet([catalogtool("alpha", "Alpha"), catalogtool("omega", "Omega")], CatalogTool[])
    restored = Agent(provider, missing; history=tree)
    @test toolnames(restored.tools) == ["alpha", "omega", "tool_search"]
    @test register!(restored.tools, catalogtool("github_get_issue", "Get a GitHub issue")) == ToolSuccess("Registered github_get_issue")
    @test toolnames(restored.tools) == ["alpha", "omega", "tool_search", "github_get_issue"]

    store = SearchHistory.Memory()
    rejected = Agent(searchprovider(searchreply(searchcall("1", "tool_search", (; query="issue")))), catalog(); history=RejectSearchHistory(store))
    @test respond!(rejected, "find") == SearchHistory.Rejected(:search_rejected)
    @test toolnames(rejected.tools) == ["alpha", "omega", "tool_search"]
    @test toolnames(Agent(provider, catalog(); history=store).tools) == ["alpha", "omega", "tool_search"]

    mktempdir() do dir
        path = joinpath(dir, "history.sqlite")
        history = open(SearchHistory.SQLite, path)
        agent = Agent(searchprovider(searchreply(searchcall("1", "tool_search", (; query="issue"))), searchdone()), catalog(); history)
        @test respond!(agent, "find") == "done"
        close(history)
        history = open(SearchHistory.SQLite, path; create=false)
        try
            @test toolnames(Agent(provider, catalog(); history).tools) == ["alpha", "omega", "tool_search", "github_get_issue"]
        finally
            close(history)
        end
    end
end

@testset "executor boundary" begin
    executor = JuliaForever.Execution.Executor(1)
    provider = searchprovider(searchreply(searchcall("1", "tool_search", (; query="issue"))), searchreply(searchcall("2", "github_get_issue", (;))), searchdone(), searchdone())
    history = SearchHistory.Memory()
    E = JuliaForever.Execution
    @test E.install!("search-test", provider, catalog())
    try
        agent = Agent(nothing, catalog(); history)
        @test respond!(agent, "find"; executor, context="search-test").value == "done"
        @test provider.offered == [["alpha", "omega", "tool_search"], ["alpha", "omega", "tool_search", "github_get_issue"], ["alpha", "omega", "tool_search", "github_get_issue"]]
        @test [m["content"] for m in agent.messages if m["role"] == "tool"][end] == "github_get_issue ran"
        restored = Agent(nothing, catalog(); history)
        @test toolnames(restored.tools) == ["alpha", "omega", "tool_search", "github_get_issue"]
        @test respond!(restored, "again"; executor, context="search-test").value == "done"
        @test last(provider.offered) == ["alpha", "omega", "tool_search", "github_get_issue"]
        rejected_provider = searchprovider(searchreply(searchcall("3", "tool_search", (; query="issue"))))
        @test E.install!("search-rejected", rejected_provider, catalog())
        try
            store = SearchHistory.Memory()
            rejected = Agent(nothing, catalog(); history=RejectSearchHistory(store))
            @test respond!(rejected, "find"; executor, context="search-rejected").value == SearchHistory.Rejected(:search_rejected)
            @test toolnames(rejected.tools) == ["alpha", "omega", "tool_search"]
            @test toolnames(Agent(nothing, catalog(); history=store).tools) == ["alpha", "omega", "tool_search"]
        finally
            E.uninstall!("search-rejected")
        end
    finally
        E.uninstall!("search-test")
        close(executor)
    end
end

@testset "search and image reply identity" begin
    image = Image("image/png", "data")
    plain = SearchConversation.ToolReply(ToolSuccess("ok", image))
    loaded = SearchConversation.ToolReply(JuliaForever.ToolLoaded("ok", ["github_get_issue"]))
    @test plain.image == image
    @test loaded.image === nothing
    @test !isequal(loaded, SearchConversation.ToolReply(JuliaForever.ToolLoaded("ok", ["github_list_repos"])))
    @test isequal(loaded, SearchConversation.ToolReply(JuliaForever.ToolLoaded("ok", ["github_get_issue"])))
    @test hash(loaded) == hash(SearchConversation.ToolReply(JuliaForever.ToolLoaded("ok", ["github_get_issue"])))
end
