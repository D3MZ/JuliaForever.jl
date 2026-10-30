using Test, JSON3, JuliaForever

import JuliaForever.Durable as D

mutable struct BadCopy end
Base.deepcopy_internal(::BadCopy, ::IdDict) = error("cannot detach return value")

if !Sys.isunix()
    @testset "unsupported platform" begin
        mktempdir() do dir
            result = open(D.Store, joinpath(dir, "session.jsonl"))
            @test result isa D.Rejected && result.reason == :unsupported_platform
        end
    end
else

@testset "durable lifecycle properties" begin
    mktempdir() do dir
        store = open(D.Store, joinpath(dir, "state.jsonl"))
        @test !store.failed && !store.closed && !store.busy
        @test setproperty!(store, :failed, 1) === true
        @test D.revision(store) == D.Rejected(:failed)
        @test setproperty!(store, :failed, 0) === false
        @test setproperty!(store, :nextid, 0.0) === 0
        held = Ref{Any}()
        @test D.commit!(store) do tx
            held[] = tx
            @test store.busy && tx.active
            @test setproperty!(tx, :active, 1) === true
            @test close(store) == D.Rejected(:busy)
            nothing
        end === nothing
        @test !store.busy && !held[].active
        close(store)
        @test store.closed && !store.failed
    end
end

@testset "durable store" begin
    mktempdir() do dir
        path = joinpath(dir, "session.jsonl")
        store = open(D.Store, path)
        payload = Dict("text" => "first", "parts" => ["a"])
        conversation, entry, task, document, submission = D.commit!(store) do tx
            conversation = D.mint!(tx)
            D.put!(tx, D.Conversation(conversation, Dict("name" => "root")))
            entry = D.mint!(tx)
            D.put!(tx, D.Entry(entry, conversation, "input", payload))
            task = D.mint!(tx)
            D.put!(tx, D.Task(task, conversation, Dict("status" => "running", "step" => 1)))
            document = D.mint!(tx)
            D.put!(tx, D.Document(document, conversation, Dict("count" => 1)))
            submission = D.submit!(tx, conversation; request="request-1", kind="input", value=payload)
            (conversation, entry, task, document, submission)
        end

        @test D.revision(store) == 1
        @test allunique([conversation, entry, task, document, submission])
        payload["text"] = "changed"
        push!(payload["parts"], "changed")
        saved = get(store, D.Entry, entry)
        @test saved.value == Dict("text" => "first", "parts" => ["a"])
        saved.value["parts"][1] = "changed"
        @test get(store, D.Entry, entry).value["parts"] == ["a"]
        @test get(store, D.Task, entry) === nothing
        @test get(store, D.Record, entry).id == entry
        @test get(store, D.Submission, submission).status == "queued"
        @test get(store, D.Submission, conversation, "request-1").id == submission
        @test get(store, D.Submission, conversation, "missing") === nothing
        @test [record.id for record in D.scan(store, D.Task)] == [task]

        @test_throws ErrorException D.commit!(store) do tx
            D.put!(tx, D.Document(document, conversation, Dict("count" => 999)))
            error("abort before storage")
        end
        @test get(store, D.Document, document).value["count"] == 1
        @test D.revision(store) == 1

        @test_throws ErrorException D.commit!(store) do tx
            D.put!(tx, D.Document(document, conversation, Dict("count" => 999)))
            BadCopy()
        end
        @test get(store, D.Document, document).value["count"] == 1
        @test D.revision(store) == 1

        duplicate = D.commit!(store) do tx
            D.submit!(tx, conversation; request="request-1", kind="input", value=Dict("text" => "different"))
        end
        @test duplicate == submission
        @test D.revision(store) == 1
        conflict = D.commit!(store) do tx
            D.put!(tx, D.Document(document, conversation, Dict("count" => 2)))
            D.submit!(tx, conversation; request="request-1", kind="write", value="note")
        end
        @test conflict isa D.Rejected && conflict.reason == :request_type
        @test get(store, D.Document, document).value["count"] == 1
        @test D.revision(store) == 1

        conflict = D.commit!(store) do tx
            D.put!(tx, D.Task(task, conversation, Dict("status" => "done")))
            D.put!(tx, D.Entry(entry, conversation, "input", "replacement"))
        end
        @test conflict isa D.Rejected && conflict.reason == :immutable
        @test get(store, D.Task, task).state["status"] == "running"
        @test D.revision(store) == 1

        other, other_submission = D.commit!(store) do tx
            other = D.mint!(tx)
            D.put!(tx, D.Conversation(other, Dict("name" => "other")))
            (other, D.submit!(tx, other; request="request-1", kind="write", value="note"))
        end
        @test other_submission != submission
        @test D.revision(store) == 2
        @test [record.id for record in D.scan(store, D.Submission)] == [submission, other_submission]
        @test [record.id for record in D.scan(store, D.Submission; conversation=other)] == [other_submission]
        scanned = D.scan(store, D.Submission; conversation=conversation)
        scanned[1].value["text"] = "mutated"
        @test get(store, D.Submission, submission).value["text"] == "first"
        D.commit!(store) do tx
            D.put!(tx, D.Task(task, conversation, Dict("status" => "pending", "step" => 2)))
            D.put!(tx, D.Document(document, conversation, Dict("count" => 2)))
        end
        @test D.revision(store) == 3
        close(store)
        @test D.revision(store) isa D.Rejected
        @test D.scan(store, D.Task) isa D.Rejected

        store = open(D.Store, path)
        @test D.revision(store) == 3
        @test get(store, D.Entry, entry).value["text"] == "first"
        @test get(store, D.Task, task).state == Dict("status" => "pending", "step" => 2)
        @test get(store, D.Document, document).value == Dict("count" => 2)
        @test [record.id for record in D.scan(store, D.Task; conversation=conversation)] == [task]
        @test get(store, D.Submission, conversation, "request-1").id == submission
        @test D.commit!(store) do tx
            D.submit!(tx, conversation; request="request-1", kind="input", value="retry")
        end == submission
        next = D.commit!(store) do tx
            id = D.mint!(tx)
            D.put!(tx, D.Entry(id, conversation, "answer", "done"))
            id
        end
        @test next > maximum([conversation, entry, task, document, submission, other, other_submission])
        close(store)
    end
end

@testset "recovery and corruption" begin
    mktempdir() do dir
        path = joinpath(dir, "session.jsonl")
        store = open(D.Store, path)
        id = D.commit!(store) do tx
            id = D.mint!(tx)
            D.put!(tx, D.Conversation(id, Dict("value" => 1)))
            id
        end
        close(store)
        good = read(path)
        open(path, "a") do io
            write(io, "{\"seq\":2,\"writes\":")
        end
        store = open(D.Store, path)
        @test D.revision(store) == 1
        @test get(store, D.Conversation, id).value["value"] == 1
        @test read(path) == good
        close(store)

        open(path, "a") do io
            write(io, "{bad json}\n")
        end
        corrupt = read(path)
        result = open(D.Store, path)
        @test result isa D.Rejected && result.reason == :corrupt_log
        @test read(path) == corrupt
        write(path, good)
        restored = open(D.Store, path)
        @test restored isa D.Store
        @test D.revision(restored) == 1
        close(restored)

        for (seq, id) in ((true, 1), (1, true))
            path = joinpath(dir, "invalid-$seq-$id.jsonl")
            line = JSON3.write((; seq, nextid=1, writes=[(; type="conversation", id, value=nothing)])) * "\n"
            write(path, line)
            result = open(D.Store, path)
            @test result isa D.Rejected && result.reason == :corrupt_log
            @test read(path, String) == line
            result isa D.Store && close(result)
        end
    end
end

@testset "atomic validation" begin
    mktempdir() do dir
        store = open(D.Store, joinpath(dir, "session.jsonl"))
        conversation = D.commit!(store) do tx
            id = D.mint!(tx)
            D.put!(tx, D.Conversation(id, nothing))
            id
        end
        rejected = D.commit!(store) do tx
            D.put!(tx, D.Entry(D.mint!(tx), conversation, "input", "never committed"))
            D.put!(tx, D.Document(D.mint!(tx), 999, Dict("value" => 1)))
        end
        @test rejected isa D.Rejected && rejected.reason == :conversation_missing
        @test D.revision(store) == 1
        rejected = D.commit!(store) do tx
            D.put!(tx, D.Task(conversation, conversation, Dict("status" => "pending")))
        end
        @test rejected isa D.Rejected && rejected.reason == :id_in_use
        @test D.revision(store) == 1
        close(store)
    end
end

@testset "failed storage and transaction lifetime" begin
    mktempdir() do dir
        path = joinpath(dir, "session.jsonl")
        store = open(D.Store, path)
        held = Ref{Any}()
        id = D.commit!(store) do tx
            held[] = tx
            id = D.mint!(tx)
            D.put!(tx, D.Conversation(id, Dict("value" => 1)))
            id
        end
        expired = D.mint!(held[])
        @test expired isa D.Rejected && expired.reason == :expired_transaction
        close(store.io)
        @test_throws Exception D.commit!(store) do tx
            D.put!(tx, D.Document(D.mint!(tx), id, Dict("value" => 2)))
        end
        @test D.revision(store) == D.Rejected(:failed)
        @test store.failed && !store.closed && !store.busy
        close(store)
        @test store.failed && store.closed
        reopened = open(D.Store, path)
        @test D.revision(reopened) == 1
        @test get(reopened, D.Conversation, id).value["value"] == 1
        close(reopened)
    end
end

@testset "concurrent admission" begin
    mktempdir() do dir
        store = open(D.Store, joinpath(dir, "session.jsonl"))
        conversation = D.commit!(store) do tx
            id = D.mint!(tx)
            D.put!(tx, D.Conversation(id, nothing))
            id
        end
        results = Vector{Int}(undef, 30)
        @sync for i in eachindex(results)
            Threads.@spawn results[i] = D.commit!(store) do tx
                D.submit!(tx, conversation; request="same", kind="input", value=i)
            end
        end
        @test all(==(first(results)), results)
        @test D.revision(store) == 2
        close(store)
    end
end

@testset "exclusive writer and nested commit" begin
    mktempdir() do dir
        path = joinpath(dir, "session.jsonl")
        store = open(D.Store, path)
        competing = open(D.Store, path)
        @test competing isa D.Rejected && competing.reason == :locked
        source = repr(joinpath(@__DIR__, "..", "src", "durable.jl"))
        code = "include($source); print(open(Durable.Store, ARGS[1]).reason)"
        @test read(`$(Base.julia_cmd()) --startup-file=no --project=$(dirname(@__DIR__)) -e $code $path`, String) == "locked"
        nested = Ref{Any}()
        closing = Ref{Any}()
        foreign = Ref{Any}()
        id = D.commit!(store) do tx
            id = D.mint!(tx)
            D.put!(tx, D.Conversation(id, nothing))
            foreign[] = fetch(Threads.@spawn D.mint!(tx))
            nested[] = D.commit!(store) do inner
                D.put!(inner, D.Conversation(D.mint!(inner), "nested"))
            end
            closing[] = close(store)
            id
        end
        @test nested[] isa D.Rejected && nested[].reason == :busy
        @test closing[] isa D.Rejected && closing[].reason == :busy
        @test foreign[] isa D.Rejected && foreign[].reason == :foreign_task
        @test D.revision(store) == 1
        @test get(store, D.Conversation, id) !== nothing
        close(store)
        reopened = open(D.Store, path)
        @test D.revision(reopened) == 1
        close(reopened)
    end
end

@testset "abrupt process exit" begin
    mktempdir() do dir
        path = joinpath(dir, "session.jsonl")
        source = repr(joinpath(@__DIR__, "..", "src", "durable.jl"))
        code = """
            include($source)
            store = open(Durable.Store, ARGS[1])
            Durable.commit!(store) do tx
                id = Durable.mint!(tx)
                Durable.put!(tx, Durable.Conversation(id, Dict("recovered" => true)))
            end
            batch = (; seq=2, nextid=2, writes=[(; type="document", id=2, conversation=1, value=Dict("recovered" => "before adoption"))])
            write(store.io, Durable.JSON3.write(batch) * "\\n")
            Durable.sync(store.io)
            ccall(:_exit, Cvoid, (Cint,), 0)
        """
        run(`$(Base.julia_cmd()) --startup-file=no --project=$(dirname(@__DIR__)) -e $code $path`)
        store = open(D.Store, path)
        @test D.revision(store) == 2
        @test get(store, D.Conversation, 1).value["recovered"] === true
        @test get(store, D.Document, 2).value["recovered"] == "before adoption"
        close(store)
    end
end

end
