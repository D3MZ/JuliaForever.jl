using JuliaForever, JSON3

const calls = Ref(0)
function JuliaForever.stream(provider::OpenAI, messages, tools; parameters=Dict(), on_event=identity)
    calls[] += 1
    open(ENV["JF_SESSION_REQUESTS"], "a") do file
        println(file, JSON3.write(messages))
    end
    root = ENV["JF_SKILL_WORKSPACE"]
    if calls[] == 1
        normal = joinpath(root, ".pi", "skills", "normal", "SKILL.md")
        write(normal, "---\nname: normal\ndescription: changed normal\n---\nUpdated body.\n")
        rm(joinpath(root, ".pi", "skills", "hidden"); recursive=true)
        write(joinpath(root, ".pi", "skills", "broken", "SKILL.md"), "---\nname: [unterminated\n---\nBroken body.\n")
        added = joinpath(root, ".pi", "skills", "added", "SKILL.md")
        mkpath(dirname(added))
        write(added, "---\nname: added\ndescription: added skill\n---\nAdded body.\n")
    elseif calls[] == 6
        later = joinpath(root, ".pi", "skills", "later", "SKILL.md")
        mkpath(dirname(later))
        write(later, "---\nname: later\ndescription: explicit only\ndisable-model-invocation: true\n---\nLater body.\n")
    end
    text = "reply:" * messages[end]["content"]
    on_event((; type=:text, text))
    Completion(Dict{String, Any}("role" => "assistant", "content" => text), nothing, "stop", true, nothing)
end

exit(JuliaForever.main(ARGS))
