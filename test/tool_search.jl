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

struct RejectSearchHistory <: SearchHistory.Store
    store::SearchHistory.Memory
end
SearchHistory.snapshot(history::RejectSearchHistory) = SearchHistory.snapshot(history.store)
function SearchHistory.append!(history::RejectSearchHistory, revision::Integer, batch::Vector)
    occursin("tool_search_reply", repr(batch)) && return SearchHistory.Rejected(:search_rejected)
    SearchHistory.append!(history.store, revision, batch)
end
