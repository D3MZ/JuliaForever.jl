using Pkg

# Tests that isolate the user directory must still see the installed packages.
ENV["JULIA_DEPOT_PATH"] = join(DEPOT_PATH, Sys.iswindows() ? ';' : ':')

if ARGS == ["--native-only"]
    pop!(ENV, "PI_SOURCE", nothing)
    println("Running native tests; Pi differential tests are skipped.")
elseif !isempty(ARGS) || !haskey(ENV, "PI_SOURCE")
    println(stderr, "Set PI_SOURCE to the pinned Pi checkout, or pass --native-only.")
    exit(2)
else
    get!(ENV, "PI_OFFLINE", "1")
    println("Running native tests and Pi differential tests.")
end

flush(stdout)
Pkg.instantiate()
Pkg.test(; julia_args=`--startup-file=no --threads=$(Threads.nthreads())`)
include(joinpath(@__DIR__, "..", "test", "terminal_plugin_install.jl"))
