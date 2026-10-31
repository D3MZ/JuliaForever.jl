using Pkg

Pkg.instantiate()
Pkg.test(; julia_args=`--startup-file=no --threads=$(Threads.nthreads())`)
