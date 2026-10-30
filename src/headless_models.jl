const NativeModelProvider = Union{J.OpenAI, J.OpenAIResponses, J.Anthropic, J.Google}
const ModelWire = @NamedTuple{id::String, name::String, api::String, provider::String, baseUrl::String, reasoning::Bool, input::Vector{String}, cost::Dict{String, Any}, contextWindow::Int, maxTokens::Int}
const modelinputs = Dict(false => ["text"], true => ["text", "image"])
struct BuiltinModel
    provider::String
    id::String
    api::String
    data::Dict{String, Any}
end
BuiltinModel(data::Dict{String, Any}) = BuiltinModel(String(data["provider"]), String(data["id"]), String(data["api"]), data)
JSON3.StructTypes.StructType(::Type{BuiltinModel}) = JSON3.StructTypes.CustomStruct()
JSON3.StructTypes.lower(model::BuiltinModel) = model.data
const RPCModel = Union{ModelWire, BuiltinModel}
const RecordedModel = Union{Nothing, J.Conversation.ModelEntry}
struct ModelCatalog
    models::Vector{BuiltinModel}
    index::Dict{Tuple{String, String}, BuiltinModel}
    groups::Dict{String, Vector{BuiltinModel}}
    providers::Vector{String}
end
Base.show(io::IO, value::ModelCatalog) = print(io, "ModelCatalog(", length(value.models), " models)")
const catalog = Base.OncePerProcess{ModelCatalog}() do
    models = BuiltinModel.(J.Models.metadata())
    groups = Dict{String, Vector{BuiltinModel}}()
    for model in models
        push!(get!(groups, model.provider, BuiltinModel[]), model)
    end
    ModelCatalog(models, Dict((model.provider, model.id) => model for model in models), groups, unique([model.provider for model in models]))
end
const modeloverrides = ("name", "baseUrl", "reasoning", "input", "cost", "contextWindow", "maxTokens")

modelregistry(provider) = J.modelconfig(ENV)
modelregistry(provider::NativeModelProvider) = modelregistry(provider.route)
modelregistry(::J.DirectRoute) = J.modelconfig(ENV)
modelregistry(route::J.CatalogRoute) = route.registry

lookupmodelwire(registry::J.Models.Registry, provider, id) = lookupmodelwire(registry, provider, id, modelwire(registry, J.Models.findmodel(model -> model.provider == provider && model.id == id, registry.models)))
lookupmodelwire(::J.Models.InvalidConfig, provider, id) = nothing
lookupmodelwire(registry, provider, id, model::ModelWire) = model
lookupmodelwire(registry, provider, id, ::Nothing) = builtinwire(registry, get(catalog().index, (provider, id), nothing))
builtinwire(registry, ::Nothing) = nothing
builtinwire(registry, model::BuiltinModel) = builtinwire(model, get(registry.providers, model.provider, nothing))
builtinwire(model::BuiltinModel, ::Nothing) = builtinbase(model, J.providerinfo(model.provider))
builtinbase(model, ::Nothing) = model
builtinbase(model, info::NamedTuple) = builtinbase(model, get(ENV, info.base, nothing))
builtinbase(model, base::AbstractString) = withbase(model, String(base))
function withbase(model::BuiltinModel, base::String)
    data = copy(model.data)
    data["baseUrl"] = base
    BuiltinModel(model.provider, model.id, model.api, data)
end
function builtinwire(model::BuiltinModel, settings::AbstractDict)
    data = copy(builtinbase(model, J.providerinfo(model.provider)).data)
    data["baseUrl"] = get(settings, "baseUrl", data["baseUrl"])
    fields = J.modeloverride(settings, model.id)
    for name in modeloverrides
        copyoverride!(data, name, get(fields, name, nothing))
    end
    data["cost"] = J.mergeprice(model.data["cost"], get(fields, "cost", nothing))
    BuiltinModel(model.provider, model.id, model.api, data)
end
copyoverride!(data, name, ::Nothing) = nothing
copyoverride!(data, name, value) = (data[name] = value; nothing)
modelwire(registry, ::Nothing) = nothing
modelwire(registry, model::J.Models.Model) = configuredwire(registry, model, get(registry.providers, model.provider, nothing))
configuredwire(registry, model, ::Nothing) = nothing
configuredwire(registry, model, settings::AbstractDict) = configuredwire(registry, model, settings, J.definition(settings, model.id))
configuredwire(registry, model, settings, ::Nothing) = nothing
function configuredwire(registry, model, settings, definition::AbstractDict)
    fields = merge(definition, J.modeloverride(settings, model.id))
    info = J.configuredinfo(registry, model.provider, model.id, ENV, model.provider)
    input = String.(get(fields, "input", modelinputs[model.images]))
    cost = Dict{String, Any}(String(key) => value for (key, value) in pairs(J.pricebook(model.provider, model.id, settings)))
    ModelWire((model.id, model.name, model.api, model.provider, String(J.modelbase(info, ENV)), model.reasoning, input, cost, model.context, model.maxoutput))
end

modelinfo(provider::NativeModelProvider, mode) = modelinfo(provider, mode, provider.route)
modelinfo(provider, mode, ::J.DirectRoute) = wireinfo(get(catalog().index, (LiveJSON.providername(mode, provider), provider.model), nothing), provider, mode)
modelinfo(provider, mode, route::J.CatalogRoute) = wireinfo(lookupmodelwire(route.registry, route.name, provider.model), provider, mode)
wireinfo(::Nothing, provider, mode) = basicmodel(provider, mode)
wireinfo(model::ModelWire, provider, mode) = model
wireinfo(model::BuiltinModel, provider, mode) = withbase(model, provider.base)

modelwires(::J.Models.InvalidConfig) = Failure("Model configuration is invalid")
modelwires(registry::J.Models.Registry) = modelwires(registry, J.usableproviders(ENV, registry))
function modelwires(registry, usable)
    result = RPCModel[]
    index = Dict((model.provider, model.id) => model for model in registry.models if haskey(registry.providers, model.provider))
    available = catalog()
    for provider in available.providers
        provider in usable || continue
        for model in available.groups[provider]
            native = get(index, (model.provider, model.id), nothing)
            push!(result, builtinselection(registry, model, modelwire(registry, native)))
        end
        custommodels!(result, registry, available, provider, get(registry.providers, provider, nothing))
    end
    for model in registry.models
        model.provider in usable || continue
        haskey(available.groups, model.provider) && continue
        collectwire!(result, modelwire(registry, model))
    end
    result
end
custommodels!(result, registry, available, provider, ::Nothing) = nothing
function custommodels!(result, registry, available, provider, settings::AbstractDict)
    for model in registry.models
        model.provider == provider || continue
        haskey(available.index, (model.provider, model.id)) && continue
        collectwire!(result, modelwire(registry, model))
    end
    nothing
end
builtinselection(registry, model, ::Nothing) = builtinwire(registry, model)
builtinselection(registry, model, custom::ModelWire) = custom
collectwire!(models::Vector{RPCModel}, ::Nothing) = nothing
collectwire!(models::Vector{RPCModel}, model::ModelWire) = (push!(models, model); nothing)

availablewires(session) = availablewires(session.agent.provider, session.registry)
availablewires(provider, registry) = modelwires(registry)
availablewires(::Union{J.ManagedChatGPT, J.ChatGPT.Plan}, registry) = Failure("Model listing is not available for the ChatGPT provider")
handle!(session, ::GetAvailableModels) = listedmodels(availablewires(session))
listedmodels(failure::Failure) = failure
listedmodels(models::Vector) = Success((; data=(; models)))

function handle!(session, command::SetModel)
    lock(session.lock) do
        setrequest!(session, command, session.task)
    end
end
setrequest!(session, command, task::Task) = Failure("Model switching while streaming is not supported")
function setrequest!(session, command, ::Nothing)
    lock(session.agent.lock) do
        setrequest!(session, command, session.agent.turn)
    end
end
setrequest!(session, command, ::Union{J.Running, J.Cancelled}) = Failure("Model switching while streaming is not supported")
setrequest!(session, command, ::J.Idle) = setrequest!(session, command, availablewires(session))
setrequest!(session, command, failure::Failure) = failure
function setrequest!(session, command, models::Vector)
    index = findfirst(model -> model.provider == command.provider && model.id == command.model, models)
    foundmodel!(session, command, models, index)
end
foundmodel!(session, command, models, ::Nothing) = Failure("Model not found: $(command.provider)/$(command.model)")
foundmodel!(session, command, models, index::Int) = setmodel!(session, models[index])

function setmodel!(session, model::RPCModel)
    selectapi!(session, model, get(J.modelapis, model.api, nothing))
end
selectapi!(session, model, api) = Failure("Model switching across APIs is not supported")
function selectapi!(session, model, ::Type{P}) where {P<:NativeModelProvider}
    selected = selectprovider(session, model, session.agent.provider, P)
    selectedprovider!(session, model, P, selected)
end
function selectprovider(session, model, provider::P, ::Type{P}) where {P<:NativeModelProvider}
    current = LiveJSON.providername(session.terminal.mode, provider)
    model.provider == current && return selectedmodel(provider, model)
    targetprovider(session, model, P)
end
selectprovider(session, model, provider, ::Type{P}) where {P<:NativeModelProvider} = targetprovider(session, model, P)
targetprovider(session, model, ::Type{P}) where {P<:NativeModelProvider} = providerfrom(model, J.configuredinfo(session.registry, model.provider, model.id, ENV, model.provider), P)
providerfrom(model, info::J.ConfiguredProvider, ::Type{P}) where {P<:NativeModelProvider} = J.acquire(J.APIKeyAuth(), info, model.id)
providerfrom(model, info::NamedTuple, ::Type{P}) where {P<:NativeModelProvider} = providerfrom(model, info, P, J.keyvalue(ENV, info))
providerfrom(model, info, type) = nothing
providerfrom(model, info, type, key) = nothing
providerfrom(model, info, ::Type{P}, key::AbstractString) where {P<:NativeModelProvider} = builtinkey(model, P, J.envvalue(key))
builtinkey(model, type, ::Nothing) = nothing
builtinkey(model, ::Type{P}, key::String) where {P<:NativeModelProvider} = P(modelbase(model), model.id, key)
modelbase(model::ModelWire) = model.baseUrl
modelbase(model::BuiltinModel) = String(model.data["baseUrl"])
selectedprovider!(session, model, type, selected) = Failure("Model switching is not available for this provider")
selectedprovider!(session, model, ::Type{P}, selected::P) where {P<:NativeModelProvider} = setmodel!(session, model, selected)
selectedmodel(provider, model) = nothing
selectedmodel(provider::NativeModelProvider, model) = selectedmodel(provider, model, provider.route)
selectedmodel(provider, model, route) = J.modelchange(provider, model.id, route)
selectedmodel(provider::J.OpenAIResponses, model, ::J.DirectRoute) = J.responselevel(provider, model.id, nothing)

restoremodel!(session, agent) = nothing
function restoremodel!(session, agent::J.Agent{P}) where {P<:Union{NativeModelProvider, J.UnconfiguredProvider}}
    entry = foldl(recordedmodel, getfield(agent, :events); init=nothing)::RecordedModel
    restoremodel!(session, agent, entry)
end
recordedmodel(current, event) = current
recordedmodel(current, event::J.Conversation.SessionRecord{J.Conversation.ModelEntry}) = event.entry
recordedmodel(current, event::J.Conversation.ModelSelection) = event.model.entry
recordedmodel(current, event::J.Conversation.SessionRecord{J.Conversation.MessageEntry})::RecordedModel = recordedmodel(current, event.entry.message, LiveJSON.role(event.entry.message))
recordedmodel(current, message, role::LiveJSON.Role) = current
recordedmodel(current, message, ::LiveJSON.AssistantRole) = recordedmodel(current, get(message, "provider", nothing), get(message, "model", nothing))
recordedmodel(current, provider::String, model::String) = J.Conversation.ModelEntry(provider, model)
recordedmodel(current, provider, model) = current

targetmodel(session, selected, requested::String) = nothing
targetmodel(session, selected, ::Nothing) = targetmodelsnapshot(session, J.History.snapshot(selected))
targetmodelsnapshot(session, rejected::J.History.Rejected) = Failure(string(rejected.reason))
targetmodelsnapshot(session, snapshot::J.History.Snapshot) = targetselection(session, foldl(targetentry, Iterators.drop(snapshot.batches, 1); init=nothing))
targetentry(rejected::J.History.Rejected, batch::Vector) = rejected
targetentry(current, batch::Vector) = targetentry(current, J.History.treeevent(batch))
targetentry(current, rejected::J.History.Rejected) = rejected
targetentry(current, event::J.Kernel.Event) = recordedmodel(current, event)
targetselection(session, ::Nothing) = nothing
targetselection(session, rejected::J.History.Rejected) = Failure(string(rejected.reason))
function targetselection(session, entry::J.Conversation.ModelEntry)
    provider = session.agent.provider
    current = LiveJSON.providername(session.terminal.mode, provider)
    (entry.provider, entry.model) == (current, provider.model) && return nothing
    targetwire(session, lookupmodelwire(session.registry, entry.provider, entry.model))
end
targetwire(session, ::Nothing) = Failure("Saved model is unavailable")
targetwire(session, model::RPCModel) = targetapi(session, model, get(J.modelapis, model.api, nothing))
targetapi(session, model, api) = Failure("Saved model is unavailable")
function targetapi(session, model, ::Type{P}) where {P<:NativeModelProvider}
    targetselected(session, P, selectprovider(session, model, session.agent.provider, P))
end
targetselected(session, type, selected) = Failure("Saved model is unavailable")
function targetselected(session, ::Type{P}, selected::P) where {P<:NativeModelProvider}
    append!(session.terminal.secrets, [selected.key; last.(selected.extra)])
    nothing
end

restoremodel!(session, agent, ::Nothing) = nothing
function restoremodel!(session, agent, entry::J.Conversation.ModelEntry)
    current = LiveJSON.providername(session.terminal.mode, agent.provider)
    (entry.provider, entry.model) == (current, agent.provider.model) && return nothing
    model = lookupmodelwire(session.registry, entry.provider, entry.model)
    restoremodel!(session, agent, entry, model)
end
restoremodel!(session, agent, entry, ::Nothing) = restoremissing!(session, agent, entry.provider)
restoremodel!(session, agent, entry, model::RPCModel) = restoreapi!(session, agent, entry, model, get(J.modelapis, model.api, nothing))
restoreapi!(session, agent, entry, model, api) = restoremissing!(session, agent, entry.provider)
function restoreapi!(session, agent, entry, model, ::Type{P}) where {P<:NativeModelProvider}
    selected = selectprovider(session, model, agent.provider, P)
    restoreselected!(session, agent, entry, P, selected)
end
restoreselected!(session, agent, entry, type, selected) = restoremissing!(session, agent, entry.provider)
function restoreselected!(session, agent, entry, ::Type{P}, selected::P) where {P<:NativeModelProvider}
    append!(session.terminal.secrets, [selected.key; last.(selected.extra)])
    session.agent = J.withprovider(agent, selected)
    providername!(session, entry.provider)
    nothing
end
function restoremissing!(session, agent, name)
    session.agent = J.withprovider(agent, J.UnconfiguredProvider())
    providername!(session, name)
    nothing
end

setmodel!(session, model, ::Nothing) = Failure("Model switching is not available for this provider")
setmodel!(session, model, status::Integer) = Failure("Model selection failed")
setmodel!(session, model, selected) = Failure("Model switching across APIs is not supported")
function setmodel!(session, model, selected::NativeModelProvider)
    append!(session.terminal.secrets, [selected.key; last.(selected.extra)])
    choices = thinkingchoices(selected)
    level = clampthinking(modelthinking(session.settings, model.provider, model.id, session.thinking), levels(choices))
    adjusted = selectionthinking(selected, choices, level)
    saveselection!(session, model, adjusted, level)
end
selectionthinking(selected, ::FixedThinking, level) = selected
selectionthinking(selected, choices::ReasoningChoices, level) = J.applythinking(selected, choices.efforts[level])
saveselection!(session, model, selected, level) = Failure("Model selection failed")
function saveselection!(session, model, selected::NativeModelProvider, level)
    entry = J.Conversation.ModelEntry(model.provider, model.id)
    saved = level == session.thinking ? recordentry!(session, entry) : recordselection!(session, entry, J.Conversation.ThinkingEntry(level))
    modelrecorded!(session, model, selected, level, saved)
end
modelrecorded!(session, model, selected, level, rejected::J.History.Rejected) = Failure(string(rejected.reason))
function modelrecorded!(session, model, selected, level, ::Nothing)
    session.agent = J.withprovider(session.agent, selected)
    providername!(session, model.provider)
    session.stream.api = LiveJSON.api(selected)
    session.stream.provider = LiveJSON.providername(session.terminal.mode, selected)
    session.stream.model = selected.model
    session.thinking = level
    selectionevent!(session, last(getfield(session.agent, :events)))
    Success((; data=model))
end
selectionevent!(session, ::J.Conversation.SessionRecord) = nothing
function selectionevent!(session, event::J.Conversation.ModelSelection)
    write!(session, (; type="thinking_level_changed", level=event.thinking.entry.level))
    nothing
end

function handle!(session, ::CycleModel)
    lock(session.lock) do
        cyclemodel!(session, session.task)
    end
end
cyclemodel!(session, task::Task) = Failure("Model switching while streaming is not supported")
function cyclemodel!(session, ::Nothing)
    lock(session.agent.lock) do
        cyclemodel!(session, session.agent.turn)
    end
end
cyclemodel!(session, ::Union{J.Running, J.Cancelled}) = Failure("Model switching while streaming is not supported")
cyclemodel!(session, ::J.Idle) = cyclemodels!(session, availablewires(session))
cyclemodels!(session, failure::Failure) = failure
function cyclemodels!(session, models::Vector)
    length(models) <= 1 && return Success((; data=nothing))
    provider = LiveJSON.providername(session.terminal.mode, session.agent.provider)
    current = findfirst(model -> model.provider == provider && model.id == session.agent.provider.model, models)
    index = something(current, 1)
    model = models[mod1(index + 1, length(models))]
    cyclemodelresult(setmodel!(session, model), session, model)
end
cyclemodelresult(failure::Failure, session, model) = failure
cyclemodelresult(::Success, session, model) = Success((; data=(; model, thinkingLevel=session.thinking, isScoped=false)))
