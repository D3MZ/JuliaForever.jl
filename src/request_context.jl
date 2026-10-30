const contextmodels = Base.OncePerProcess{Dict{Tuple{String, String, String}, Dict{String, Any}}}() do
    Dict((model["provider"], model["id"], model["api"]) => model for model in Models.metadata())
end

contextprovider(::DirectRoute, fallback) = fallback
contextprovider(route::CatalogRoute, fallback) = route.name
contextidentity(provider::OpenAI) = (contextprovider(provider.route, "openai"), provider.model, "openai-completions")
contextidentity(provider::OpenAIResponses) = (contextprovider(provider.route, "openai"), provider.model, "openai-responses")
contextidentity(provider::Anthropic) = (contextprovider(provider.route, "anthropic"), provider.model, "anthropic-messages")
contextmetadata(provider) = get(contextmodels(), contextidentity(provider), Dict{String, Any}())
contextcompat(provider) = get(contextmetadata(provider), "compat", Dict{String, Any}())
const contextstrictmodes = Dict(true => ContextStrictSupported(), false => ContextStrictUnsupported())
contextstrict(provider) = contextstrictmodes[get(contextcompat(provider), "supportsStrictMode", false)]

abstract type ContextPolicy end
struct CollapsedContext <: ContextPolicy end
struct InlineContext <: ContextPolicy end
const contextpolicies = Dict(false => CollapsedContext(), true => InlineContext())
contextpolicy(provider) = contextpolicies[get(contextcompat(provider), "supportsMidConvoSystemMessages", false)]
const instructionroles = Dict((true, true) => "developer", (true, false) => "system", (false, true) => "system", (false, false) => "system")
contextinstruction(provider) = instructionroles[(get(contextmetadata(provider), "reasoning", false), get(contextcompat(provider), "supportsDeveloperRole", true))]

providercontext(::Union{OpenAI, OpenAIResponses, Anthropic, Google, ChatGPT.Plan, ManagedChatGPT}, messages, system) = collapsedcontext(messages, system)
contextdeclarations(tools) = OrderedDict{String, Tool}(String(key) => declaration(tool) for (key, tool) in pairs(tools))
providerprepared(provider::Union{OpenAI, OpenAIResponses, Anthropic}, messages, system, tools) = providerprepared(contextpolicy(provider), provider, messages, system, contextdeclarations(tools))
providerprepared(provider::Google, messages, system, tools) = RequestView(collapsedcontext(messages, system), contextdeclarations(tools))
providerprepared(::CollapsedContext, provider, messages, system, tools) = RequestView(collapsedcontext(messages, system), tools)
chatdefinition(provider::OpenAI, tool::ToolDeclaration) = chatdefinition(tool, contextstrict(provider))
chatdefinition(tool::ToolDeclaration, ::ContextStrictUnsupported) = definition(tool)
function chatdefinition(tool::ToolDeclaration, ::ContextStrictSupported)
    data = definition(tool)
    data["function"]["strict"] = false
    data
end

function rendercontext(message)
    parts = [systemtext(get(message, "content", "")); collect(Iterators.flatten(sectiontext(value) for value in values(get(message, "sections", Dict()))))]
    join(filter(!isempty, parts), "\n\n")
end
sectionupdate(key, ::Nothing) = "Removed system prompt section \"$key\"."
sectionupdate(key, value) = "Updated system prompt section \"$key\":\n\n$value"
function contextupdate(message)
    parts = String[systemtext(get(message, "content", ""))]
    append!(parts, [sectionupdate(key, value) for (key, value) in pairs(get(message, "sections", Dict()))])
    join(filter(!isempty, parts), "\n\n")
end
abstract type ContextPosition end
struct LeadingContext <: ContextPosition end
struct LaterContext <: ContextPosition end
const contextpositions = Dict(true => LeadingContext(), false => LaterContext())
rendercontext(message, ::LeadingContext) = rendercontext(message)
rendercontext(message, ::LaterContext) = contextupdate(message)

function inlinecontext(provider, messages)
    result = Dict{String, Any}[]
    for (index, message) in enumerate(messages)
        inlinecontext!(result, message, contextrole(message), contextpositions[index == 1], contextinstruction(provider))
    end
    result
end
inlinecontext!(result, message, role, first, instruction) = push!(result, message)
function inlinecontext!(result, message, ::ContextSystem, first, instruction)
    text = rendercontext(message, first)
    isempty(text) || push!(result, Dict{String, Any}("role" => instruction, "content" => text))
end
providerprepared(::InlineContext, provider::OpenAI, messages, system, tools) = RequestView(inlinecontext(provider, messages), tools)

const incrementaltext = "This is an incremental tools update. Previously declared tools remain available unless explicitly marked unavailable. A tool declared again here is available again, and its latest definition replaces the earlier one."
abstract type AdditionalState end
struct InitialAdditional <: AdditionalState end
struct LaterAdditional <: AdditionalState end
function incrementalnotice(unavailable)
    isempty(unavailable) ? incrementaltext : incrementaltext * "\nStill unavailable: " * join(keys(unavailable), ", ") * "."
end
additionalnotice!(items, ::InitialAdditional, instruction, unavailable) = nothing
additionalnotice!(items, ::LaterAdditional, instruction, unavailable) = push!(items, Dict("role" => instruction, "content" => incrementalnotice(unavailable)))
function responseupdate(provider, message, first, instruction, declared, unavailable)
    items = Any[]
    additions = get(message, "toolsAdded", [])
    for declaration in additions
        pop!(unavailable, declaration["name"], nothing)
    end
    if !isempty(additions)
        additionalnotice!(items, declared[], instruction, unavailable)
        declared[] = LaterAdditional()
        push!(items, Dict("type" => "additional_tools", "role" => "developer", "tools" => [responsestool(provider, requesttool(nothing, declaration)) for declaration in additions]))
    end
    added = Set(declaration["name"] for declaration in additions)
    removed = [declaration["name"] for declaration in get(message, "toolsRemoved", []) if declaration["name"] ∉ added]
    parts = String[rendercontext(message, first)]
    isempty(removed) || push!(parts, "The following tools are no longer available. Do not call them:\n" * join(("- " * name for name in removed), "\n"))
    foreach(name -> (unavailable[name] = nothing), removed)
    text = join(filter(!isempty, parts), "\n\n")
    isempty(text) || push!(items, Dict("role" => instruction, "content" => text))
    ResponseContextUpdate(items)
end
function responserequest(provider, messages, tools)
    result = Any[]
    declared = Ref{AdditionalState}(InitialAdditional())
    unavailable = OrderedDict{String, Nothing}()
    for (index, message) in enumerate(messages)
        responsecontext!(result, provider, message, contextrole(message), contextpositions[index == 1], declared, unavailable)
    end
    RequestView(result, OrderedDict{String, Tool}())
end
responsecontext!(result, provider, message, role, first, declared, unavailable) = push!(result, message)
function responsecontext!(result, provider, message, ::ContextSystem, first, declared, unavailable)
    push!(result, responseupdate(provider, message, first, contextinstruction(provider), declared, unavailable))
end
providerprepared(::InlineContext, provider::OpenAIResponses, messages, system, tools) = responserequest(provider, messages, tools)

abstract type AnthropicChanges end
struct NoAnthropicChanges <: AnthropicChanges end
struct NativeAnthropicChanges <: AnthropicChanges end
const anthropicchanges = Dict(true => NoAnthropicChanges(), false => NativeAnthropicChanges())

function anthropicinitial(messages, tools)
    isempty(messages) && return OrderedDict{String, Tool}()
    anthropicinitial(first(messages), contextrole(first(messages)), tools)
end
anthropicinitial(message, role, tools) = OrderedDict{String, Tool}()
anthropicinitial(message, ::ContextSystem, tools) = requesttools(message, tools)

function anthropicupdate(message, changes, provider)
    text = contextupdate(message)
    blocks = Any[]
    isempty(text) || push!(blocks, Dict("type" => "text", "text" => text))
    anthropictoolupdates!(blocks, message, changes, provider)
    AnthropicContextUpdate(merge(message, Dict{String, Any}("content" => text)), blocks)
end
anthropictoolupdates!(blocks, message, ::NoAnthropicChanges, provider) = nothing
function anthropictoolupdates!(blocks, message, ::NativeAnthropicChanges, provider)
    additions = get(message, "toolsAdded", [])
    added = Set(tool["name"] for tool in additions)
    for tool in get(message, "toolsRemoved", [])
        tool["name"] ∉ added && push!(blocks, Dict("type" => "tool_removal", "tool" => Dict("type" => "tool_reference", "name" => tool["name"])))
    end
    fields = AnthropicAPI.inlinefields(provider)
    for tool in additions
        declaration = AnthropicAPI.tooldata(requesttool(nothing, tool), fields)
        push!(blocks, Dict("type" => "tool_addition", "tool" => Dict("type" => "tool_definition", "definition" => declaration)))
    end
end

anthropicrequesttools(tools, initial, ::NoAnthropicChanges) = tools
anthropicrequesttools(tools, initial, ::NativeAnthropicChanges) = NativeAnthropicTools(initial)
function anthropiccontext!(result, message, role, first, changes, provider)
    push!(result, message)
end
function anthropiccontext!(result, message, ::ContextSystem, first, changes, provider)
    anthropicsystem!(result, message, first, changes, provider)
end
function anthropicsystem!(result, message, ::LeadingContext, changes, provider)
    text = rendercontext(message)
    isempty(text) || push!(result, Dict{String, Any}("role" => "system", "content" => text))
end
anthropicsystem!(result, message, ::LaterContext, changes, provider) = push!(result, anthropicupdate(message, changes, provider))
function providerprepared(::InlineContext, provider::Anthropic, messages, system, tools)
    initial = anthropicinitial(messages, tools)
    changes = anthropicchanges[isempty(initial)]
    result = Any[]
    for (index, message) in enumerate(messages)
        anthropiccontext!(result, message, contextrole(message), contextpositions[index == 1], changes, provider)
    end
    RequestView(result, anthropicrequesttools(tools, initial, changes))
end
