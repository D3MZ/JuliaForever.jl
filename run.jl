if Threads.nthreads() == 1 && Base.JLOptions().nthreads == 0 && !haskey(ENV, "JULIA_NUM_THREADS")
    project = @__DIR__
    threads = min(4, max(2, Sys.CPU_THREADS))
    run(`$(Base.julia_cmd()) --threads=$threads --project=$project $(@__FILE__)`)
    exit()
end

using JuliaForever
JuliaForever.main()
