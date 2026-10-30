using Test, JuliaForever, JSON3

struct SearchFixture <: JuliaForever.Tool
    id::String
    doc::String
    parameters::Dict{String, Any}
end
JuliaForever.name(tool::SearchFixture) = tool.id
JuliaForever.description(tool::SearchFixture) = tool.doc
JuliaForever.schema(tool::SearchFixture) = tool.parameters
JuliaForever.execute(tool::SearchFixture, args) = ToolSuccess(tool.id * " ran")

mutable struct SearchProvider
    queries::Vector{NamedTuple}
    offered::Vector{Vector{String}}
end
function JuliaForever.complete(provider::SearchProvider, messages, tools)
    push!(provider.offered, [JuliaForever.name(tool) for tool in values(tools)])
    isempty(provider.queries) && return Dict{String, Any}("role" => "assistant", "content" => "done")
    query = popfirst!(provider.queries)
    call = Dict("id" => string(length(provider.offered)), "type" => "function", "function" => Dict("name" => "tool_search", "arguments" => JSON3.write(query)))
    Dict{String, Any}("role" => "assistant", "content" => nothing, "tool_calls" => [call])
end

@testset "Pi deferred tool discovery" begin
    source = ENV["PI_SOURCE"]
    @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
    reference = JSON3.read(read(`node $(joinpath(@__DIR__, "tool_search_reference.mjs")) $source`, String))
    emptyparams = Dict{String, Any}("type" => "object")
    issueparams = Dict{String, Any}("type" => "object", "properties" => Dict("number" => Dict("type" => "number", "description" => "Issue number")))
    eager = [SearchFixture("alpha", "Alpha tool", emptyparams), SearchFixture("omega", "Omega tool", emptyparams)]
    deferred = [SearchFixture("github_get_issue", "Get a GitHub issue by number", issueparams), SearchFixture("github_list_repos", "List the repositories of a user", emptyparams)]
    provider = SearchProvider(NamedTuple[(; query="github issue", limit=1), (; query="repositories", limit=1), (; query="weather forecast"), (; query="  "), (; query="issue", limit=0)], Vector{String}[])
    agent = Agent(provider, ToolSet(eager, deferred))
    @test respond!(agent, "discover") == "done"
    @test provider.offered == reference.offered
    @test [message["content"] for message in agent.messages if message["role"] == "tool"] == reference.results

    docs = [
        SearchFixture("mcp__github__list_issues", "List issues in a repository.", Dict{String, Any}("type" => "object", "properties" => Dict("state" => Dict("type" => "string", "description" => "open or closed")))),
        SearchFixture("mcp__github__create_pull_request", "Open a pull request.", emptyparams),
        SearchFixture("mcp__linear__search_issues", "Search Linear issues by text.", emptyparams),
        SearchFixture("mcp__app__queue_read", "Read a queued message of this thread.", emptyparams),
        SearchFixture("mcp__dev-app__thread_read", "Read durable state and a paginated timeline from any thread.", Dict{String, Any}("type" => "object", "properties" => Dict("filters" => Dict("items" => Dict("anyOf" => [Dict("description" => "Archived milestone")]))))),
        SearchFixture("first_tie", "matching tokens", emptyparams),
        SearchFixture("other_tie", "matching tokens", emptyparams),
    ]
    namespace = ToolNamespace("mcp__dev-app"; description="Kubernetes cluster", instructions="Discover team schedules")
    documents = [JuliaForever.document(tool, index == 5 ? namespace : ToolNamespace("")) for (index, tool) in enumerate(docs)]
    for (index, query) in enumerate(reference.queries)
        actual = JuliaForever.ranktools(query, documents, 8)
        @test actual == reference.rankings[index]
        if index ∉ 4:7
            @test actual == reference.durable[index]
        end
    end
    for (index, text) in enumerate(["listIssues for the GitHub_repo", "searches queries HTTPServer", "aHTTPServer", "foxes boxes classes"])
        @test JuliaForever.toolterms(text) == reference.tokens[index]
    end
end
