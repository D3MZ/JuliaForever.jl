function commandroots()
    home = homedir()
    agentdir = abspath(expanduser(get(ENV, "PI_CODING_AGENT_DIR", joinpath(home, ".pi", "agent"))))
    project = joinpath(pwd(), ".pi")
    prompts = [(; dir=joinpath(agentdir, "prompts"), base=agentdir, scope="user"), (; dir=joinpath(project, "prompts"), base=project, scope="project")]
    userroots = Dict(joinpath(agentdir, "skills") => "user", joinpath(home, ".agents", "skills") => "user")
    skills = [(; dir, base=dirname(dir), scope=get(userroots, dir, "project")) for (dir, _) in J.Skills.roots(pwd(), home, agentdir)]
    (; prompts, skills)
end

handle!(session, ::GetCommands) = Success((; data=(; commands=discover(session.templates, commandroots()))))
discover(templates::AbstractDict, roots) = [promptinfo(name, body, roots.prompts) for (name, body) in templates]
function discover(resources::J.Skills.Resources, roots)
    [discover(resources.templates, roots); [skillinfo(skill, roots.skills) for skill in resources.skills]]
end

sourceinfo(path, root) = (; path, source="auto", scope=root.scope, origin="top-level", baseDir=root.base)
promptinfo(name, body, roots) = promptinfo(name, body, roots, findfirst(root -> isfile(joinpath(root.dir, name * ".md")), roots))
promptinfo(name, body, roots, ::Nothing) = (; name, description=description(body, nothing), source="prompt")
function promptinfo(name, body, roots, index::Integer)
    root = roots[index]
    path = joinpath(root.dir, name * ".md")
    promptinfo(name, body, path, root, J.attempt(() -> read(path, String)))
end
promptinfo(name, body, path, root, ::J.ToolFailure) = (; name, description=description(body, nothing), source="prompt")
function promptinfo(name, body, path, root, raw::String)
    (; name, description=description(body, J.Skills.header(raw)), source="prompt", sourceInfo=sourceinfo(path, root))
end

description(body, ::Nothing) = fallbackdescription(body)
description(body, header::AbstractDict) = description(body, get(header, "description", nothing))
description(body, text::AbstractString) = isempty(text) ? fallbackdescription(body) : String(text)
description(body, value) = fallbackdescription(body)
fallbackdescription(body) = fallbackdescription(split(body, '\n'))
fallbackdescription(lines::AbstractVector) = fallbackdescription(lines, findfirst(line -> !isempty(strip(line)), lines))
fallbackdescription(lines, ::Nothing) = ""
function fallbackdescription(lines, index::Integer)
    line = lines[index]
    length(line) > 60 ? first(line, 60) * "..." : String(line)
end

skillinfo(skill, roots) = skillinfo(skill, roots, findfirst(root -> startswith(skill.path, joinpath(root.dir, "")), roots))
skillinfo(skill, roots, ::Nothing) = (; name="skill:" * skill.name, description=skill.description, source="skill")
function skillinfo(skill, roots, index::Integer)
    (; name="skill:" * skill.name, description=skill.description, source="skill", sourceInfo=sourceinfo(skill.path, roots[index]))
end
