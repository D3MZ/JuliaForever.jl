module HeadlessAutoCompactionTests

using Test, JuliaForever, JSON3

@testset "compaction settings preserve project overrides and unrelated fields" begin
    mktempdir() do root
        agent = joinpath(root, "agent")
        project = joinpath(root, "project")
        mkpath(agent)
        mkpath(joinpath(project, ".pi"))
        path = joinpath(agent, "settings.json")
        write(path, JSON3.write((; theme="dark", compaction=(; enabled=true, keepRecentTokens=17))))
        localpath = joinpath(project, ".pi", "settings.json")
        write(localpath, JSON3.write((; compaction=(; enabled=false))))
        env = Dict("PI_CODING_AGENT_DIR" => agent)
        @test JuliaForever.setcompaction!(env, true) === nothing
        settings = JSON3.read(read(path))
        @test settings.theme == "dark" && settings.compaction.keepRecentTokens == 17 && settings.compaction.enabled
        @test JuliaForever.compactionenabled(env, project) === false
        write(localpath, JSON3.write((; compaction=(; enabled=true))))
        @test JuliaForever.setcompaction!(env, false) === nothing
        @test JuliaForever.compactionenabled(env, project) === true
        if Sys.isunix()
            target = joinpath(agent, "shared-settings.json")
            mv(path, target)
            symlink(target, path)
            @test JuliaForever.setcompaction!(env, true) === nothing
            @test islink(path) && JSON3.read(read(target)).compaction.enabled
        end
    end
end

@testset "JSON and RPC automatic compaction" begin
    python = Sys.which("python3")
    if haskey(ENV, "PI_SOURCE") && !isnothing(python)
        project = dirname(@__DIR__)
        cmd = `$python $(joinpath(@__DIR__, "headless_auto_compaction.py")) $project $(first(Base.julia_cmd().exec)) $(ENV["PI_SOURCE"])`
        @test success(run(ignorestatus(cmd)))
    else
        @test_skip false
    end
end

end
