using Test

@testset "installed native CLI plugin" begin
    python = Sys.which("python3")
    git = Sys.which("git")
    supported = Sys.isunix() && !isnothing(python) && !isnothing(git)
    supported && (supported = success(pipeline(`$python -c "import tomllib"`; stdout=devnull, stderr=devnull)))
    if supported
        root = dirname(@__DIR__)
        mktempdir() do dir
            snapshot = joinpath(dir, "package")
            mkpath(joinpath(snapshot, "test"))
            cp(joinpath(root, "Project.toml"), joinpath(snapshot, "Project.toml"))
            cp(joinpath(root, "src"), joinpath(snapshot, "src"))
            cp(joinpath(root, "test", "fixtures"), joinpath(snapshot, "test", "fixtures"))
            for file in ("terminal_provider.jl", "terminal_plugin_app.py")
                cp(joinpath(root, "test", file), joinpath(snapshot, "test", file))
            end
            template = joinpath(dir, "template")
            mkpath(template)
            depot = joinpath(dir, "depot")
            env = ["HOME" => dir, "GIT_CONFIG_NOSYSTEM" => "1", "GIT_CONFIG_GLOBAL" => joinpath(dir, "gitconfig"), "GIT_TEMPLATE_DIR" => template, "JULIA_PKG_OFFLINE" => "true", "JULIA_DEPOT_PATH" => join([depot; DEPOT_PATH], ':'), "JF_TEST_MANIFEST" => joinpath(dirname(Base.active_project()), "Manifest.toml")]
            run(addenv(`$git init -q $snapshot`, env...))
            run(addenv(`$git -C $snapshot add --all`, env...))
            run(addenv(`$git -C $snapshot -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm fixture`, env...))
            log = joinpath(dir, "install.log")
            install = addenv(`$(Base.julia_cmd()) --startup-file=no -e 'using Pkg; Pkg.Apps.add(path=ARGS[1])' $snapshot`, env...)
            process = run(pipeline(ignorestatus(install); stdout=log, stderr=log))
            success(process) || print(stderr, read(log, String))
            @test success(process)
            if success(process)
                app = joinpath(depot, "bin", "jf")
                smoke = addenv(`$python $(joinpath(snapshot, "test", "terminal_plugin_app.py")) $app`, env...)
                @test success(smoke)
            end
        end
    else
        @test_skip "Installed app check requires Unix, Git, and Python 3.11 or newer"
    end
end
