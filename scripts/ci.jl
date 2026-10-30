using Pkg

args = Set(ARGS)
coverage = "--coverage" in args
if !issubset(args, Set(["--coverage", "--native-only"])) || length(args) != length(ARGS)
    println(stderr, "Usage: scripts/ci.jl [--native-only] [--coverage]")
    exit(2)
elseif "--native-only" in args
    pop!(ENV, "PI_SOURCE", nothing)
    println("Running native tests; Pi differential tests are skipped.")
elseif !haskey(ENV, "PI_SOURCE")
    println(stderr, "Set PI_SOURCE to the pinned Pi checkout, or pass --native-only.")
    exit(2)
else
    get!(ENV, "PI_OFFLINE", "1")
    println("Running native tests and Pi differential tests.")
end

flush(stdout)
if coverage
    for (dir, _, files) in walkdir(joinpath(@__DIR__, "..", "src")), file in files
        occursin(r"\.jl\.\d+\.cov$", file) && rm(joinpath(dir, file))
    end
end
Pkg.instantiate()
Pkg.test(; coverage, julia_args=`--startup-file=no --threads=$(Threads.nthreads())`)
include(joinpath(@__DIR__, "..", "test", "terminal_plugin_install.jl"))
