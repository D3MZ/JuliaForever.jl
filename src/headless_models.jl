const NativeModelProvider = Union{J.OpenAI, J.OpenAIResponses, J.Anthropic, J.Google}
const defaultcost = (; input=0, output=0, cacheRead=0, cacheWrite=0)
const ModelWire = @NamedTuple{id::String, name::String, api::String, provider::String, baseUrl::String, reasoning::Bool, input::Vector{String}, cost::Dict{String, Any}, contextWindow::Int, maxTokens::Int}
const modelinputs = Dict(false => ["text"], true => ["text", "image"])

modelregistry(provider) = J.modelconfig(ENV)
modelregistry(provider::NativeModelProvider) = modelregistry(provider.route)
modelregistry(::J.DirectRoute) = J.modelconfig(ENV)
modelregistry(route::J.CatalogRoute) = route.registry

lookupmodelwire(registry::J.Models.Registry, provider, id) = modelwire(registry, J.Models.findmodel(model -> model.provider == provider && model.id == id, registry.models))
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
modelinfo(provider, mode, ::J.DirectRoute) = basicmodel(provider, mode)
modelinfo(provider, mode, route::J.CatalogRoute) = wireinfo(lookupmodelwire(route.registry, route.name, provider.model), provider, mode)
wireinfo(::Nothing, provider, mode) = basicmodel(provider, mode)
wireinfo(model::ModelWire, provider, mode) = model

modelwires(provider) = modelwires(modelregistry(provider))
modelwires(::J.Models.InvalidConfig) = Failure("Model configuration is invalid")
modelwires(registry::J.Models.Registry) = modelwires(registry, J.usableproviders(ENV, registry))
function modelwires(registry, usable)
    result = ModelWire[]
    for model in registry.models
        model.provider in usable || continue
        result = collectwire!(result, modelwire(registry, model))
    end
    result
end
collectwire!(failure::Failure, wire) = failure
collectwire!(models::Vector{ModelWire}, ::Nothing) = Failure("Model listing is not yet available for this provider")
collectwire!(models::Vector{ModelWire}, model::ModelWire) = (push!(models, model); models)

handle!(session, ::GetAvailableModels) = listedmodels(modelwires(session.agent.provider))
listedmodels(failure::Failure) = failure
listedmodels(models::Vector) = Success((; data=(; models)))

function handle!(session, command::SetModel)
    lock(session.lock) do
        setmodel!(session, command, session.task, modelwires(session.agent.provider))
    end
end
setmodel!(session, command, task::Task, models) = Failure("Model switching while streaming is not supported")
setmodel!(session, command, ::Nothing, failure::Failure) = failure
function setmodel!(session, command, ::Nothing, models::Vector)
    index = findfirst(model -> model.provider == command.provider && model.id == command.model, models)
    foundmodel!(session, command, models, index)
end
foundmodel!(session, command, models, ::Nothing) = Failure("Model not found: $(command.provider)/$(command.model)")
foundmodel!(session, command, models, index::Int) = setmodel!(session, models[index])

function setmodel!(session, model::ModelWire)
    current = LiveJSON.providername(session.terminal.mode, session.agent.provider)
    model.provider == current || return Failure("Model switching across providers is not supported")
    setmodel!(session, model, selectedmodel(session.agent.provider, model))
end
selectedmodel(provider, model) = nothing
selectedmodel(provider::NativeModelProvider, model) = J.modelchange(provider, model.id, provider.route)
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
        cyclemodel!(session, session.task, modelwires(session.agent.provider))
    end
end
cyclemodel!(session, task::Task, models) = Failure("Model switching while streaming is not supported")
cyclemodel!(session, ::Nothing, failure::Failure) = failure
function cyclemodel!(session, ::Nothing, models::Vector)
    length(models) <= 1 && return Success((; data=nothing))
    provider = LiveJSON.providername(session.terminal.mode, session.agent.provider)
    current = findfirst(model -> model.provider == provider && model.id == session.agent.provider.model, models)
    index = something(current, 1)
    model = models[mod1(index + 1, length(models))]
    cyclemodelresult(setmodel!(session, model), session, model)
end
cyclemodelresult(failure::Failure, session, model) = failure
cyclemodelresult(::Success, session, model) = Success((; data=(; model, thinkingLevel=session.thinking, isScoped=false)))
