using Test, JuliaForever

struct ResumeSkillProvider end
JuliaForever.complete(::ResumeSkillProvider, messages, tools; kwargs...) = Dict{String, Any}("role" => "assistant", "content" => "answer")
struct ResumeSkillCapture
    requests::Vector{Any}
end
function JuliaForever.stream(provider::ResumeSkillCapture, messages, tools; kwargs...)
    push!(provider.requests, deepcopy(messages))
    Completion(Dict{String, Any}("role" => "assistant", "content" => "answer"), nothing, "stop", true, nothing)
end

@testset "resumed skill context follows current readers" begin
    mktempdir() do root
        cd(root) do
            withenv("HOME" => root, "PI_CODING_AGENT_DIR" => joinpath(root, "agent"), "JF_INSTRUCTIONS_DIR" => nothing) do
                path = joinpath(root, ".pi", "skills", "example", "SKILL.md")
                mkpath(dirname(path))
                write(path, "---\nname: example\ndescription: example skill\n---\nprivate instructions\n")
                H = JuliaForever.History
                history = H.Tree(open(H.SQLite, joinpath(root, "history.sqlite")))
                seed = Agent(ResumeSkillProvider(), [Read(root)])
                initial = JuliaForever.initial(seed, nothing)
                user = Dict{String, Any}("role" => "system", "content" => "<skills>\nThe following skills provide specialized instructions for specific tasks.\nuser authored\n</available_skills>\n</skills>")
                push!(initial, JuliaForever.Conversation.RawMessage(user))
                original = Agent(ResumeSkillProvider(), seed.tools, initial; history)
                @test respond!(original, "prior") == "answer"
                skills = JuliaForever.Skills.load(root)
                for tools in (JuliaForever.Tool[], [Bash(root)], [Read(root)], [CodeMode([Read(root)])], [CodeMode([Write(root)])])
                    resumed = Agent(ResumeSkillProvider(), tools; history)
                    @test JuliaForever.refreshskills!(resumed, skills) === nothing
                    expected = JuliaForever.Skills.render(skills, JuliaForever.Skills.reader(values(resumed.tools)))
                    sections = [m["content"] for m in resumed.messages if m["role"] == "system"]
                    @test user["content"] in sections
                    @test count(==(expected), sections) == (isnothing(expected) ? 0 : 1)
                    @test Agent(ResumeSkillProvider(), tools; history).messages == resumed.messages
                    @test JuliaForever.Skills.expand("/skill:example hi", skills) == "<skill name=\"example\" location=\"$path\">\nReferences are relative to $(dirname(path)).\n\nprivate instructions\n</skill>\n\nhi"
                end
                stale = Agent(ResumeSkillProvider(), [Read(root)]; history)
                other = Agent(ResumeSkillProvider(), [Read(root)]; history)
                @test name!(other, "concurrent") === nothing
                before = deepcopy(stale.messages)
                @test JuliaForever.refreshskills!(stale, skills) == H.Rejected(:revision)
                @test stale.messages == before
                close(history)
                current = H.Tree(H.Memory())
                active = Agent(ResumeSkillProvider(), JuliaForever.Tool[]; history=current)
                selected = H.Tree(open(H.SQLite, joinpath(root, "history.sqlite"); create=false))
                terminal = JuliaForever.Terminal(IOBuffer(), IOBuffer(), String[])
                resumed, selected, status = JuliaForever.resume!(terminal, active, current, selected)
                @test status == 0
                @test user in resumed.messages
                @test all(!occursin("<available_skills>", m["content"]) for m in resumed.messages if m["role"] == "system" && m != user)
                @test Agent(ResumeSkillProvider(), []; history=selected).messages == resumed.messages
                @test JuliaForever.refreshskills!(Agent(ResumeSkillProvider(), [Read(root)]; history=selected), skills) === nothing
                close(selected)
                selected = H.Tree(open(H.SQLite, joinpath(root, "history.sqlite"); create=false))
                capture = ResumeSkillCapture(Any[])
                extensions = JuliaForever.Extensions.snapshot(JuliaForever.Extensions.Registry())
                @test JuliaForever.runsession!(selected, terminal, capture, extensions, ["/skill:example hi"], root) == 0
                request = only(capture.requests)
                @test user in request
                @test all(!occursin("<available_skills>", get(m, "content", "")) for m in request if m["role"] == "system" && m != user)
                @test occursin("private instructions", string(request[end]))
            end
        end
    end
end
