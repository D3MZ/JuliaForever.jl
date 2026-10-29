using Pkg

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
Pkg.test(; julia_args=`--startup-file=no`)
