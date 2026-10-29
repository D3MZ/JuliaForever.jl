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

@testset "file mutations" begin
    for (kind, expected) in ((:edit, "ALPHA\nBETA\n"), (:write, "replacement\n"))
        mktempdir() do dir
            result = filemutationcase(dir, kind)
            @test result == (; file=expected, other="independent\n")
            @test isempty(JuliaForever.mutations)
        end
    end

    mktempdir() do dir
        if !canlink(dir; directory=true)
            @test_skip false
            return
        end
        mkpath(joinpath(dir, "real"))
        symlink("real", joinpath(dir, "alias"); dir_target=true)
        path = joinpath(dir, "real", "nested", "new.txt")
        started = Channel{Nothing}(1)
        release = Channel{Nothing}(1)
        content = GatedContent("alpha\nbeta\n", started, release)
        first = Threads.@spawn execute(Write(dir), (; path="alias/nested/new.txt", content))
        second = nothing
        try
            started!(started, first)
            second = Threads.@spawn execute(Edit(dir), (; path="real/nested/new.txt", edits=[(; oldText="beta", newText="BETA")]))
            @test waitusers(path, 2)
            @test !istaskdone(second)
        finally
            put!(release, nothing)
        end
        @test waittask(first)
        @test waittask(second)
        @test !fetch(first).iserror
        @test !fetch(second).iserror
        @test read(path, String) == "alpha\nBETA\n"
        @test isempty(JuliaForever.mutations)
    end

    mktempdir() do dir
        if !canlink(dir)
            @test_skip false
            return
        end
        symlink("future.txt", joinpath(dir, "alias.txt"))
        path = joinpath(dir, "future.txt")
        started = Channel{Nothing}(1)
        release = Channel{Nothing}(1)
        content = GatedContent("initial", started, release)
        first = Threads.@spawn execute(Write(dir), (; path="alias.txt", content))
        second = nothing
        try
            started!(started, first)
            second = Threads.@spawn execute(Write(dir), (; path="future.txt", content="last"))
            @test waitusers(path, 2)
            @test !istaskdone(second)
        finally
            put!(release, nothing)
        end
        @test waittask(first)
        @test waittask(second)
        @test !fetch(first).iserror
        @test !fetch(second).iserror
        @test read(path, String) == "last"
        @test isempty(JuliaForever.mutations)
    end

    mktempdir() do dir
        if !canlink(dir; directory=true) || !canlink(dir)
            @test_skip false
            return
        end
        mkpath(joinpath(dir, "logical"))
        mkpath(joinpath(dir, "outside", "child"))
        symlink("../outside/child", joinpath(dir, "logical", "link"); dir_target=true)
        symlink("logical/link/../new.txt", joinpath(dir, "alias.txt"))
        path = joinpath(dir, "outside", "new.txt")
        started = Channel{Nothing}(1)
        release = Channel{Nothing}(1)
        content = GatedContent("first", started, release)
        first = Threads.@spawn execute(Write(dir), (; path="alias.txt", content))
        second = nothing
        try
            started!(started, first)
            second = Threads.@spawn execute(Write(dir), (; path="outside/new.txt", content="second"))
            @test waitusers(path, 2)
            @test !istaskdone(second)
        finally
            put!(release, nothing)
        end
        @test waittask(first)
        @test waittask(second)
        @test !fetch(first).iserror
        @test !fetch(second).iserror
        @test read(path, String) == "second"
        @test isempty(JuliaForever.mutations)
    end

    mktempdir() do dir
        path = joinpath(dir, "ordered.txt")
        firststarted, firstrelease = Channel{Nothing}(1), Channel{Nothing}(1)
        secondstarted, secondrelease = Channel{Nothing}(1), Channel{Nothing}(1)
        first = Threads.@spawn execute(Write(dir), (; path="ordered.txt", content=GatedContent("first", firststarted, firstrelease)))
        second = nothing
        third = nothing
        try
            started!(firststarted, first)
            second = Threads.@spawn execute(Write(dir), (; path="ordered.txt", content=GatedContent("second", secondstarted, secondrelease)))
            @test waitusers(path, 2)
            third = Threads.@spawn execute(Write(dir), (; path="ordered.txt", content="third"))
            @test waitusers(path, 3)
            @test !istaskdone(second)
            @test !istaskdone(third)
            put!(firstrelease, nothing)
            started!(secondstarted, second)
            @test !istaskdone(third)
        finally
            isready(firstrelease) || put!(firstrelease, nothing)
            put!(secondrelease, nothing)
        end
        @test waittask(first)
        @test waittask(second)
        @test waittask(third)
        @test !fetch(first).iserror
        @test !fetch(second).iserror
        @test !fetch(third).iserror
        @test read(path, String) == "third"
        @test isempty(JuliaForever.mutations)
    end

    mktempdir() do dir
        path = joinpath(dir, "recovery.txt")
        started, release = Channel{Nothing}(1), Channel{Nothing}(1)
        content = FailingContent(joinpath(dir, "absent"), started, release)
        first = Threads.@spawn execute(Write(dir), (; path="recovery.txt", content))
        second = nothing
        try
            started!(started, first)
            second = Threads.@spawn execute(Write(dir), (; path="recovery.txt", content="recovered"))
            @test waitusers(path, 2)
            @test !istaskdone(second)
        finally
            put!(release, nothing)
        end
        @test waittask(first)
        @test waittask(second)
        @test_throws TaskFailedException fetch(first)
        @test !fetch(second).iserror
        @test read(path, String) == "recovered"
        @test isempty(JuliaForever.mutations)
    end

    mktempdir() do dir
        if !canlink(dir)
            @test_skip false
            return
        end
        symlink("cycle-b", joinpath(dir, "cycle-a"))
        symlink("cycle-a", joinpath(dir, "cycle-b"))
        @test_throws Base.IOError execute(Write(dir), (; path="cycle-a", content="x"))
        @test isempty(JuliaForever.mutations)
    end

    mktempdir() do dir
        @test_throws SystemError execute(Edit(dir), (; path="missing.txt", edits=[(; oldText="a", newText="b")]))
        @test isempty(JuliaForever.mutations)
        @test !execute(Write(dir), (; path="missing.txt", content="a")).iserror
        @test !execute(Edit(dir), (; path="missing.txt", edits=[(; oldText="a", newText="b")])).iserror
        @test read(joinpath(dir, "missing.txt"), String) == "b"
        @test isempty(JuliaForever.mutations)
    end
end
