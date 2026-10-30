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

manualretention(provider, name) = isempty(name) ? LastTurn() : manualretention(provider, name, attempt(() -> terminalsettings(ENV, pwd())))
manualretention(provider, name, settings) = History.Rejected(:invalid_compaction_settings)
manualretention(provider, name, settings::AbstractDict) = manualconfig(provider, name, get(settings, "compaction", Dict{String, Any}()))
manualconfig(provider, name, config) = History.Rejected(:invalid_compaction_settings)
manualconfig(provider, name, config::AbstractDict) = manualenabled(provider, name, config, validcompactionbool(get(config, "enabled", true)))
manualenabled(provider, name, config, ::Models.InvalidConfig) = History.Rejected(:invalid_compaction_settings)
manualenabled(provider, name, config, ::Models.ValidConfig) = manualretention(compactionconfig(provider, name, merge(Dict{String, Any}(config), Dict("enabled" => true))))
manualretention(policy) = History.Rejected(:invalid_compaction_settings)
manualretention(policy::UsageCompaction) = policy.retention

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

settingspath(env) = joinpath(get(env, "PI_CODING_AGENT_DIR", joinpath(homedir(), ".pi", "agent")), "settings.json")
compactionenabled(env, cwd) = compactionenabled(terminalsettings(env, cwd))
compactionenabled(settings::Models.InvalidConfig) = settings
compactionenabled(settings::AbstractDict) = compactionconfigenabled(get(settings, "compaction", Dict{String, Any}()))
compactionconfigenabled(config) = Models.InvalidConfig()
compactionconfigenabled(config::AbstractDict) = compactionenabledvalue(get(config, "enabled", true))
compactionenabledvalue(value) = Models.InvalidConfig()
compactionenabledvalue(value::Bool) = value

function setcompaction!(env, enabled::Bool)
    path = settingspath(env)
    mkpath(dirname(path))
    lockpath = path * ".lock"
    setcompaction!(path, lockpath, enabled, attempt(() -> mkdir(lockpath)))
end
setcompaction!(path, lockpath, enabled, failure::ToolFailure) = failure
function setcompaction!(path, lockpath, enabled, acquired::String)
    try
        target = islink(path) ? realpath(path) : path
        setcompaction!(target, enabled, readsettings(path))
    finally
        rm(lockpath)
    end
end
setcompaction!(path, enabled, settings::InvalidResponse) = Models.InvalidConfig()
setcompaction!(path, enabled, settings) = Models.InvalidConfig()
function setcompaction!(path, enabled, settings::AbstractDict)
    setcompaction!(path, enabled, settings, get(settings, "compaction", Dict{String, Any}()))
end
setcompaction!(path, enabled, settings, config) = Models.InvalidConfig()
function setcompaction!(path, enabled, settings, config::AbstractDict)
    updated = Dict{String, Any}(settings)
    updated["compaction"] = merge(Dict{String, Any}(config), Dict("enabled" => enabled))
    mktemp(dirname(path)) do temporary, io
        JSON3.pretty(io, updated)
        write(io, '\n')
        flush(io)
        close(io)
        preservepermissions!(temporary, path)
        Base.Filesystem.rename(temporary, path)
    end
    nothing
end
preservepermissions!(temporary, path) = isfile(path) && chmod(temporary, stat(path).mode & 0o777)

usablecompaction(settings::Union{Nothing, AutoCompaction}) = settings
usablecompaction(settings) = nothing
