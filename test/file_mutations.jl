struct GatedEdits{T} <: AbstractVector{T}
    edits::Vector{T}
    started::Channel{Nothing}
    release::Channel{Nothing}
end

Base.size(edits::GatedEdits) = size(edits.edits)
Base.getindex(edits::GatedEdits, index::Int) = edits.edits[index]

function Base.iterate(edits::GatedEdits, state=1)
    if state == 1
        put!(edits.started, nothing)
        take!(edits.release)
    end
    iterate(edits.edits, state)
end

struct GatedContent
    content::String
    started::Channel{Nothing}
    release::Channel{Nothing}
end

function Base.write(io::IO, content::GatedContent)
    put!(content.started, nothing)
    take!(content.release)
    write(io, content.content)
end

struct FailingContent
    path::String
    started::Channel{Nothing}
    release::Channel{Nothing}
end

function Base.write(io::IO, content::FailingContent)
    put!(content.started, nothing)
    take!(content.release)
    read(content.path)
end

function canlink(dir; directory=false)
    target = directory ? "probe-dir" : "probe-missing"
    directory && mkpath(joinpath(dir, target))
    link = joinpath(dir, "probe-link")
    try
        symlink(target, link; dir_target=directory)
    catch exception
        if Sys.iswindows() && exception isa Base.IOError && exception.code in (Base.UV_EPERM, Base.UV_EACCES, Base.UV_ENOSYS, Base.UV_ENOTSUP)
            return false
        end
        rethrow()
    end
    rm(link)
    true
end

function waitusers(path, count)
    timedwait(10; pollint=0.002) do
        lock(JuliaForever.mutationguard) do
            entry = get(JuliaForever.mutations, JuliaForever.mutationkey(path), nothing)
            !isnothing(entry) && entry.users == count
        end
    end == :ok
end

function waittask(task)
    timedwait(() -> istaskdone(task), 10; pollint=0.002) == :ok || error("timed out waiting for task")
    true
end

function started!(channel, task)
    @test timedwait(() -> isready(channel) || istaskdone(task), 10; pollint=0.002) == :ok
    if !isready(channel) && istaskdone(task)
        fetch(task)
        error("task returned before reaching the gate")
    end
    @test isready(channel)
    isready(channel) || error("task did not reach the gate")
    take!(channel)
end

function filemutationcase(dir, kind)
    path = joinpath(dir, "target.txt")
    write(path, "alpha\nbeta\n")
    started = Channel{Nothing}(1)
    release = Channel{Nothing}(1)
    edits = GatedEdits([(; oldText="alpha", newText="ALPHA")], started, release)
    first = Threads.@spawn execute(Edit(dir), (; path="target.txt", edits))
    second = nothing
    other = nothing
    try
        started!(started, first)
        if kind == :edit
            second = Threads.@spawn execute(Edit(dir), (; path="target.txt", edits=[(; oldText="beta", newText="BETA")]))
        else
            second = Threads.@spawn execute(Write(dir), (; path="target.txt", content="replacement\n"))
        end
        @test waitusers(path, 2)
        @test !istaskdone(second)
        other = Threads.@spawn execute(Write(dir), (; path="other.txt", content="independent\n"))
        @test waittask(other)
        @test !fetch(other).iserror
    finally
        put!(release, nothing)
    end
    @test waittask(first)
    @test waittask(second)
    @test !fetch(first).iserror
    @test !fetch(second).iserror
    (; file=read(path, String), other=read(joinpath(dir, "other.txt"), String))
end
