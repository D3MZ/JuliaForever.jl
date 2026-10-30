module DurableDispatchTests

using Test, JuliaForever
import JuliaForever.Durable as D

if Sys.isunix()
@testset "durable record variants preserve validation" begin
    mktempdir() do dir
        path = joinpath(dir, "records.jsonl")
        store = open(D.Store, path)
        conversation, entry, task, document, submission = D.commit!(store) do tx
            ids = [D.mint!(tx) for _ in 1:5]
            D.put!(tx, D.Conversation(ids[1], nothing))
            D.put!(tx, D.Entry(ids[2], ids[1], "input", "a"))
            D.put!(tx, D.Task(ids[3], ids[1], "running"))
            D.put!(tx, D.Document(ids[4], ids[1], "old"))
            D.put!(tx, D.Submission(ids[5], ids[1], "request", "input", "queued", nothing))
            ids
        end
        @test D.commit!(tx -> D.put!(tx, D.Conversation(0, nothing)), store) == D.Rejected(:unminted_id)
        attempts = [
            (tx -> D.put!(tx, D.Conversation(conversation, "changed")), :immutable),
            (tx -> D.put!(tx, D.Entry(entry, conversation, "input", "changed")), :immutable),
            (tx -> D.put!(tx, D.Task(entry, conversation, "bad type")), :id_in_use),
            (tx -> D.put!(tx, D.Task(task, 999, "wrong owner")), :immutable),
            (tx -> D.put!(tx, D.Document(document, 999, "wrong owner")), :immutable),
            (tx -> D.put!(tx, D.Submission(submission, conversation, "different", "input", "queued", nothing)), :immutable),
            (tx -> D.put!(tx, D.Submission(submission, conversation, "request", "write", "queued", nothing)), :immutable),
            (tx -> D.put!(tx, D.Submission(D.mint!(tx), conversation, "request", "input", "queued", nothing)), :request_in_use),
            (tx -> D.put!(tx, D.Document(D.mint!(tx), 999, nothing)), :conversation_missing),
        ]
        for (attempt, reason) in attempts
            result = D.commit!(store) do tx
                D.put!(tx, D.Task(task, conversation, "must roll back"))
                attempt(tx)
            end
            @test result == D.Rejected(reason)
            @test D.revision(store) == 1
            @test get(store, D.Task, task).state == "running"
            @test get(store, D.Submission, conversation, "request").id == submission
        end
        D.commit!(store) do tx
            D.put!(tx, D.Task(task, conversation, "done"))
            D.put!(tx, D.Document(document, conversation, "new"))
            D.put!(tx, D.Submission(submission, conversation, "request", "input", "done", nothing))
            D.put!(tx, D.Submission(D.mint!(tx), conversation, nothing, "input", "queued", nothing))
        end
        close(store)
        store = open(D.Store, path)
        @test get(store, D.Conversation, conversation).value === nothing
        @test get(store, D.Entry, entry).value == "a"
        @test get(store, D.Task, task).state == "done"
        @test get(store, D.Document, document).value == "new"
        @test get(store, D.Submission, submission).status == "done"
        @test get(store, D.Submission, conversation, "request").id == submission
        @test [(row.request, row.status) for row in D.scan(store, D.Submission)] == [("request", "done"), (nothing, "queued")]
        close(store)

        corrupt = joinpath(dir, "invalid-id.jsonl")
        bytes = "{\"seq\":1,\"nextid\":1,\"writes\":[{\"type\":\"conversation\",\"id\":0,\"value\":null,\"parent\":null}]}\n"
        write(corrupt, bytes)
        @test open(D.Store, corrupt) == D.Rejected(:corrupt_log)
        @test read(corrupt, String) == bytes
    end
end
end

end
