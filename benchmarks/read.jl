using JuliaForever, JSON3

function readmany(tool, args, iterations)
    for _ in 1:iterations
        execute(tool, args)
    end
end

source = ARGS[1]
iterations = parse(Int, ARGS[2])
revision = readchomp(`git -C $source rev-parse HEAD`)
project = dirname(dirname(pathof(JuliaForever)))
target_revision = readchomp(`git -C $project rev-parse HEAD`)
target_dirty = !isempty(read(`git -C $project status --porcelain`, String))
source_dirty = !isempty(read(`git -C $source status --porcelain`, String))
mktempdir() do dir
    write(joinpath(dir, "sample.txt"), repeat("Julia Forever reference data\n", 128))
    tool = Read(dir)
    args = (; path="sample.txt")
    expected = execute(tool, args).text
    readmany(tool, args, 20)
    GC.gc()
    measurement = @timed readmany(tool, args, iterations)
    reference = JSON3.read(read(`node $(joinpath(@__DIR__, "read.mjs")) $source $dir $iterations`, String))
    matched = expected == reference.text && revision == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
    println(JSON3.write((; matched, iterations, revision, target_revision, target_dirty, source_dirty, machine=Sys.MACHINE, cpu=Sys.CPU_NAME, julia_version=string(VERSION), julia_seconds=measurement.time, julia_bytes=measurement.bytes, pi_seconds=reference.seconds, node_version=reference.node)))
    matched || exit(1)
end
