function readsettings(path)
    isfile(path) || return Dict{String, Any}()
    decode(replace(read(path, String), r"^\ufeff" => ""))
end

mergesettings(base, override) = override
mergesettings(base::AbstractDict, override::AbstractDict) = mergewith(mergesettings, base, override)
mergesettings(base::InvalidResponse, override) = Models.InvalidConfig()
mergesettings(base, override::InvalidResponse) = Models.InvalidConfig()
mergesettings(base::InvalidResponse, override::InvalidResponse) = Models.InvalidConfig()

function terminalsettings(env, cwd)
    agentdir = get(env, "PI_CODING_AGENT_DIR", joinpath(homedir(), ".pi", "agent"))
    globalsettings = readsettings(joinpath(agentdir, "settings.json"))
    projectsettings = readsettings(joinpath(cwd, ".pi", "settings.json"))
    mergesettings(globalsettings, projectsettings)
end

terminalcompaction(provider, name, env, cwd) = isempty(name) ? nothing : terminalcompaction(provider, name, terminalsettings(env, cwd))
terminalcompaction(provider, name, ::Models.InvalidConfig) = Models.InvalidConfig()
terminalcompaction(provider, name, settings::AbstractDict) = compactionconfig(provider, name, get(settings, "compaction", Dict{String, Any}()))

function compactionconfig(provider, name, config::AbstractDict)
    ordinary = get(config, "reserveTokens", 16384)
    recent = get(config, "keepRecentTokens", 20000)
    overrides = get(config, "modelOverrides", Dict{String, Any}())
    compactionconfig(provider, name, config, ordinary, recent, overrides)
end
compactionconfig(provider, name, config) = Models.InvalidConfig()
compactionconfig(provider, name, config, ordinary, recent, overrides) = Models.InvalidConfig()
function compactionconfig(provider, name, config, ordinary, recent, overrides::AbstractDict)
    modelname = compactionmodelname(provider, name)
    override = get(overrides, modelname, Dict{String, Any}())
    compactionoverride(provider, name, config, ordinary, recent, override)
end
compactionoverride(provider, name, config, ordinary, recent, override) = Models.InvalidConfig()
function compactionoverride(provider, name, config, ordinary, recent, override::AbstractDict)
    enabled = get(config, "enabled", true)
    reserved = get(override, "reserveTokens", ordinary)
    kept = get(override, "keepRecentTokens", recent)
    valid = Models.combine(validcompactionbool(enabled), validcompactiontokens(ordinary), validcompactiontokens(recent), validcompactiontokens(reserved), validcompactiontokens(kept))
    terminalcompaction(provider, name, enabled, reserved, kept, valid)
end
terminalcompaction(provider, name, enabled, reserve, keep, ::Models.InvalidConfig) = Models.InvalidConfig()
function terminalcompaction(provider, name, enabled::Bool, reserve, keep, ::Models.ValidConfig)
    model = compactionmodel(provider, name)
    retention(AutoCompaction(compactionwindow(model), Int(reserve); enabled), Int(keep))
end
retention(policy::DisabledCompaction, keep) = policy
retention(policy::UsageCompaction, keep) = UsageCompaction(policy.context_window, policy.reserve_tokens, RecentTokens(keep))

validcompactionbool(::Bool) = Models.ValidConfig()
validcompactionbool(value) = Models.InvalidConfig()
validcompactiontokens(value) = Models.InvalidConfig()
validcompactiontokens(::Bool) = Models.InvalidConfig()
validcompactiontokens(value::Real) = Models.check(isfinite(value) && isinteger(value) && 0 <= value <= 9007199254740991)
compactionwindow(::Nothing) = 0
compactionwindow(model::Models.Model) = model.context
compactionmodelname(provider, name) = name * "/" * provider.model
compactionmodelname(provider::Union{OpenAI, OpenAIResponses, Anthropic, Google}, name) = modelcatalogname(provider, name) * "/" * provider.model
compactionmodel(provider, name) = nothing
function compactionmodel(provider::Union{OpenAI, OpenAIResponses, Anthropic, Google}, name)
    catalogname = modelcatalogname(provider, name)
    Models.findmodel(model -> model.provider == catalogname && model.id == provider.model, modelcatalog(provider))
end
compactionmodel(provider::ManagedChatGPT, name) = Models.findmodel(model -> model.provider == "openai" && model.id == provider.model, Models.catalog())
