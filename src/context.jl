guidance(tool::Tool) = description(tool)

function context(cwd, tools, files)
    available = ["- $(name(tool)): $(guidance(tool))" for tool in tools]
    isempty(available) && push!(available, "(none)")
    sections = [
        "You are a coding assistant in Julia Forever. Help the user work in the current project using the available tools. Inspect relevant files, make requested changes, and report the outcome.",
        "Working directory: $(abspath(cwd))",
        "Available tools:\n$(join(available, "\n"))",
    ]
    isempty(files) || push!(sections, Instructions.render(files))
    join(sections, "\n\n")
end
