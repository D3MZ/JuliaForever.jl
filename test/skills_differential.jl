using Test, JuliaForever, JSON3

function skillfile(dir, header; body="secret instructions")
    mkpath(dir)
    path = joinpath(dir, "SKILL.md")
    write(path, "---\n" * header * "\n---\n" * body)
    path
end

@testset "Pi skill discovery and model-facing metadata" begin
    source = ENV["PI_SOURCE"]
    @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
    mktempdir() do temp
        root = realpath(temp)
        home, agent, project = joinpath.((root,), ("home", "agent", "project"))
        cwd = joinpath(project, "service")
        mkpath.((home, agent, cwd, joinpath(project, ".git")))
        chosen = skillfile(joinpath(cwd, ".pi", "skills", "chosen"), "name: shared\ndescription: 'project & <chosen>'")
        skillfile(joinpath(agent, "skills", "duplicate"), "name: shared\ndescription: global duplicate")
        skillfile(joinpath(agent, "skills", "global"), "description: global skill")
        skillfile(joinpath(home, ".agents", "skills", "duplicate-global"), "name: global\ndescription: agents duplicate")
        skillfile(joinpath(home, ".agents", "skills", "user"), "name: user-agents\ndescription: user agents skill")
        skillfile(joinpath(project, ".agents", "skills", "ancestor"), "name: ancestor\ndescription: ancestor skill")
        skillfile(joinpath(root, ".agents", "skills", "outside"), "name: outside\ndescription: outside repository")
        skillfile(joinpath(cwd, ".agents", "skills", "local"), "name: ancestor\ndescription: nearer ancestor skill")
        skillfile(joinpath(cwd, ".agents", "skills", "disabled"), "name: disabled\ndescription: explicit only\ndisable-model-invocation: true")
        skillfile(joinpath(cwd, ".pi", "skills", "group"), "name: group\ndescription: 'outer skill'")
        skillfile(joinpath(cwd, ".pi", "skills", "group", "inner"), "name: inner\ndescription: should not be discovered")
        skillfile(joinpath(cwd, ".pi", "skills", "invalid"), "name: invalid")
        skillfile(joinpath(cwd, ".pi", "skills", "bad-yaml"), "name: [unterminated")
        skillfile(joinpath(cwd, ".pi", "skills", ".hidden"), "name: hidden\ndescription: hidden directory")
        skillfile(joinpath(cwd, ".pi", "skills", "ignored"), "name: ignored\ndescription: ignored directory")
        skillfile(joinpath(cwd, ".pi", "skills", "git-ignored"), "name: git-ignored\ndescription: ignored directory")
        skillfile(joinpath(cwd, ".pi", "skills", "fd-ignored"), "name: fd-ignored\ndescription: ignored directory")
        skillfile(joinpath(cwd, ".pi", "skills", "ignore-keep"), "name: keep\ndescription: explicitly kept")
        skillfile(joinpath(cwd, ".pi", "skills", "ignore-root"), "name: ignored-root\ndescription: ignored root file")
        skillfile(joinpath(cwd, ".pi", "skills", "ignore-root", "child"), "name: retained-child\ndescription: retained child")
        write(joinpath(cwd, ".pi", "skills", ".ignore"), "ignored/\nignore-keep/\n!ignore-keep/\nignore-root/SKILL.md\n")
        write(joinpath(cwd, ".pi", "skills", ".gitignore"), "git-ignored/\n")
        write(joinpath(cwd, ".pi", "skills", ".fdignore"), "fd-ignored/\n")
        mkpath(joinpath(cwd, ".agents", "skills"))
        write(joinpath(cwd, ".agents", "skills", "loose.md"), "---\nname: loose\ndescription: ignored root markdown\n---\n")
        standalone = joinpath(cwd, ".pi", "skills", "standalone.md")
        write(standalone, "---\nname: standalone\ndescription: 'a standalone skill'\n---\n")
        subdir = joinpath(cwd, ".agents", "skills", "extra")
        mkpath(subdir)
        write(joinpath(subdir, "extra.md"), "---\nname: extra\ndescription: >-\n  a folded\n  description\n---\n")
        symlink(dirname(chosen), joinpath(cwd, ".agents", "skills", "same-file"))
        input = joinpath(root, "input.json")
        write(input, JSON3.write((; cwd, agentDir=agent)))
        cmd = addenv(`node $(joinpath(@__DIR__, "skills_reference.mjs")) $source $input`, "HOME" => home, "PI_CODING_AGENT_DIR" => agent)
        reference = JSON3.read(read(cmd, String))
        @test Set(item.name for item in reference.metadata) == Set(["shared", "group", "standalone", "keep", "retained-child", "ancestor", "disabled", "extra", "global", "user-agents"])
        @test only(item for item in reference.metadata if item.name == "shared").description == "project & <chosen>"
        @test only(item for item in reference.metadata if item.name == "ancestor").description == "nearer ancestor skill"
        @test only(item for item in reference.metadata if item.name == "global").description == "global skill"
        skills = JuliaForever.Skills.load(cwd; agentdir=agent, home)
        metadata = [(; name=skill.name, description=skill.description, filePath=skill.path, baseDir=skill.dir, disableModelInvocation=JuliaForever.Skills.disabled(skill.invocation)) for skill in skills]
        @test JSON3.write(metadata) == JSON3.write(reference.metadata)
        @test JuliaForever.Skills.render(skills) == reference.section
        @test JuliaForever.Skills.render(JuliaForever.Skills.Skill[]) === nothing

        output, diagnostics, capture = joinpath.((root,), ("output", "diagnostics", "capture"))
        package = dirname(@__DIR__)
        cmd = Cmd(`$(Base.julia_cmd()) --startup-file=no --compiled-modules=existing --project=$package $(joinpath(@__DIR__, "skills_process.jl")) --no-session inspect`; dir=cwd)
        cmd = addenv(cmd, "HOME" => home, "JULIA_DEPOT_PATH" => join(DEPOT_PATH, Sys.iswindows() ? ';' : ':'), "PI_CODING_AGENT_DIR" => agent, "JF_SESSION_DIR" => joinpath(root, "sessions"), "JF_INSTRUCTIONS_DIR" => nothing, "JF_PROVIDER" => "openai", "OPENAI_MODEL" => "fixture", "OPENAI_API_KEY" => "synthetic-secret", "JF_CAPTURE" => capture, "JF_SKILL" => chosen)
        process = run(pipeline(ignorestatus(cmd); stdout=output, stderr=diagnostics))
        @test process.exitcode == 0
        requests = JSON3.read.(readlines(capture))
        @test length(requests) == 2
        sections = [message["content"] for message in requests[1] if message["role"] == "system"]
        @test reference.section in sections
        @test all(!occursin("secret instructions", section) for section in sections)
        @test any(message["role"] == "tool" && occursin("secret instructions", message["content"]) for message in requests[2])
        @test occursin("loaded", read(output, String))
    end
end
