const NativeModelProvider = Union{J.OpenAI, J.OpenAIResponses, J.Anthropic, J.Google}
const defaultcost = (; input=0, output=0, cacheRead=0, cacheWrite=0)
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
const modelpath = joinpath(@__DIR__, "..", "data", "pi-rpc-models.json")
Base.include_dependency(modelpath)
const catalog = Base.OncePerProcess{ModelCatalog}() do
    models = BuiltinModel.(JSON3.read(read(modelpath), Vector{Dict{String, Any}}))
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
    cost = Dict{String, Any}(String(key) => value for (key, value) in pairs(get(fields, "cost", defaultcost)))
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
setrequest!(session, command, ::Nothing) = setrequest!(session, command, availablewires(session))
setrequest!(session, command, failure::Failure) = failure
function setrequest!(session, command, models::Vector)
    index = findfirst(model -> model.provider == command.provider && model.id == command.model, models)
    foundmodel!(session, command, models, index)
end
foundmodel!(session, command, models, ::Nothing) = Failure("Model not found: $(command.provider)/$(command.model)")
foundmodel!(session, command, models, index::Int) = setmodel!(session, models[index])

function setmodel!(session, model::RPCModel)
    current = LiveJSON.providername(session.terminal.mode, session.agent.provider)
    model.provider == current || return Failure("Model switching across providers is not supported")
    selectapi!(session, model, get(J.modelapis, model.api, nothing))
end
selectapi!(session, model, api) = Failure("Model switching across APIs is not supported")
selectapi!(session::Session{<:J.Agent{P}}, model, ::Type{P}) where {P<:NativeModelProvider} = setmodel!(session, model, selectedmodel(session.agent.provider, model))
selectedmodel(provider, model) = nothing
selectedmodel(provider::NativeModelProvider, model) = selectedmodel(provider, model, provider.route)
selectedmodel(provider, model, route) = J.modelchange(provider, model.id, route)
selectedmodel(provider::J.OpenAIResponses, model, ::J.DirectRoute) = J.responselevel(provider, model.id, nothing)

restoremodel!(session, agent) = nothing
function restoremodel!(session, agent::J.Agent{P}) where {P<:NativeModelProvider}
    entry = foldl(recordedmodel, getfield(agent, :events); init=nothing)::RecordedModel
    restoremodel!(session, agent, entry)
end
recordedmodel(current, event) = current
recordedmodel(current, event::J.Conversation.SessionRecord{J.Conversation.ModelEntry}) = event.entry
recordedmodel(current, event::J.Conversation.SessionRecord{J.Conversation.MessageEntry})::RecordedModel = recordedmodel(current, event.entry.message, LiveJSON.role(event.entry.message))
recordedmodel(current, message, role::LiveJSON.Role) = current
recordedmodel(current, message, ::LiveJSON.AssistantRole) = recordedmodel(current, get(message, "provider", nothing), get(message, "model", nothing))
recordedmodel(current, provider::String, model::String) = J.Conversation.ModelEntry(provider, model)
recordedmodel(current, provider, model) = current
restoremodel!(session, agent, ::Nothing) = nothing
function restoremodel!(session, agent, entry::J.Conversation.ModelEntry)
    current = LiveJSON.providername(session.terminal.mode, agent.provider)
    valid = J.Models.combine(J.Models.check(entry.provider == current), J.Models.check(entry.model != agent.provider.model))
    restoremodel!(session, agent, entry, valid)
end
restoremodel!(session, agent, entry, ::J.Models.InvalidConfig) = nothing
function restoremodel!(session, agent, entry, ::J.Models.ValidConfig)
    model = lookupmodelwire(session.registry, entry.provider, entry.model)
    restoremodel!(agent, model)
end
restoremodel!(agent, ::Nothing) = nothing
restoremodel!(agent, model::RPCModel) = restoreapi!(agent, model, get(J.modelapis, model.api, nothing))
restoreapi!(agent, model, api) = nothing
restoreapi!(agent::J.Agent{P}, model, ::Type{P}) where {P<:NativeModelProvider} = restoreselected!(agent, selectedmodel(agent.provider, model))
restoreselected!(agent, selected) = nothing
function restoreselected!(agent::J.Agent{P}, selected::P) where {P<:NativeModelProvider}
    lock(agent.lock) do
        agent.provider = selected
    end
    nothing
end

setmodel!(session, model, ::Nothing) = Failure("Model switching is not available for this provider")
setmodel!(session, model, status::Integer) = Failure("Model selection failed")
setmodel!(session, model, selected) = Failure("Model switching across APIs is not supported")
function setmodel!(session::Session{<:J.Agent{P}}, model, selected::P) where {P<:NativeModelProvider}
    saved = recordentry!(session, J.Conversation.ModelEntry(model.provider, model.id))
    modelrecorded!(session, model, selected, saved)
end
modelrecorded!(session, model, selected, rejected::J.History.Rejected) = Failure(string(rejected.reason))
function modelrecorded!(session, model, selected, ::Nothing)
    lock(session.agent.lock) do
        session.agent.provider = selected
    end
    append!(session.terminal.secrets, [selected.key; last.(selected.extra)])
    session.stream.api = LiveJSON.api(selected)
    session.stream.provider = LiveJSON.providername(session.terminal.mode, selected)
    session.stream.model = selected.model
    choices = thinkingchoices(selected)
    level = clampthinking(session.thinking, levels(choices))
    applylevel!(session.agent, choices, level)
    modelresult(setthinking!(session, session.thinking), model)
end
modelresult(failure::Failure, model) = failure
modelresult(::Success, model) = Success((; data=model))

function handle!(session, ::CycleModel)
    lock(session.lock) do
        cyclemodel!(session, session.task)
    end
end
cyclemodel!(session, task::Task) = Failure("Model switching while streaming is not supported")
cyclemodel!(session, ::Nothing) = cyclemodels!(session, availablewires(session))
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
