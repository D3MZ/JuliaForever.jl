# Read benchmark

Run a warmed, sequential text-file read against Julia Forever and the pinned Pi reference:

```sh
julia --startup-file=no --project=. benchmarks/read.jl /path/to/pi 1000
```

The Pi checkout needs its Node dependencies. Both tools read the same file, and their text is compared before success is reported. JSON output records both revisions and dirty states, machine, CPU, runtime versions, elapsed time, and Julia allocations for the measured loop. Process startup, compilation, other tools, concurrent throughput, and Node allocations are not measured. This is a narrow microbenchmark, not a claim of overall speed or parity. Repeat trials on the same machine and compare the same workload and revisions.
