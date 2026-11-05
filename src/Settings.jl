module Settings

using TOML

config_path() = abspath(expanduser(get(ENV, "JULIAFOREVER_CONFIG",
    joinpath(@__DIR__, "..", "config.toml"))))

function table(name::AbstractString)
    path = config_path()
    isfile(path) || error("Missing configuration file: $path")
    data = TOML.parsefile(path)
    value = get(data, name, nothing)
    value isa AbstractDict || error("Configuration file $path has no [$name] table.")
    value
end

function text(data, key::AbstractString)
    value = get(data, key, nothing)
    value isa AbstractString && !isempty(value) || error("Configuration value $key must be a non-empty string.")
    String(value)
end

function count(data, key::AbstractString)
    value = get(data, key, nothing)
    value isa Integer && value > 0 || error("Configuration value $key must be a positive integer.")
    Int(value)
end

end
