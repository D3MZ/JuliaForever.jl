using JSON3, HTTP, FileWatching

@testset "protected ChatGPT storage and refresh" begin
    pending = CG.Pending(CG.Register(), "urn:uuid:fixture")
    try
        session = fixtureexchange(pending, CG.Code("fixture-code", "oaiapp_fixture")).session
        mktempdir() do root
            store = CG.Store(joinpath(root, "auth"))
            host = CG.host(store)
            @test occursin(r"^urn:uuid:[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", host)
            @test CG.host(store) == host
            @test stat(store.root).mode & 0o777 == 0o700
            @test CG.save(store, session) === session
            path = CG.path(store, session.client, session.identity.subject)
            @test stat(path).mode & 0o777 == 0o600
            saved = CG.load(store, session.client, session.identity.subject)
            @test (saved.client, saved.identity.subject, saved.access, saved.refresh, saved.scope, saved.expires) == (session.client, session.identity.subject, session.access, session.refresh, session.scope, session.expires)
            @test !occursin("synthetic-access", sprint(show, saved))
            other = CG.Session("oaiapp_other", CG.Identity("account-fixture", nothing), "other-access", "other-refresh", "other-id", identityscope, identitytime + 1)
            @test CG.save(store, other) === other
            @test CG.path(store, session.client, session.identity.subject) != CG.path(store, other.client, other.identity.subject)
            @test CG.load(store, other.client, other.identity.subject).access == "other-access"
            @test CG.load(store, "missing", "missing") isa CG.Rejected
            locked = FileWatching.trymkpidlock(joinpath(store.root, "lock"); mode=0o600)
            try
                @test CG.refresh(store, session.client, session.identity.subject; now=() -> identitytime) isa CG.Busy
            finally
                close(locked)
            end
            project = dirname(@__DIR__)
            script = "using FileWatching; lock = FileWatching.trymkpidlock(ARGS[1]; mode=0o600); print(lock === false ? \"busy\" : \"acquired\"); lock === false || close(lock)"
            locked = FileWatching.trymkpidlock(joinpath(store.root, "lock"); mode=0o600)
            try
                output = read(`$(Base.julia_cmd()) --startup-file=no --project=$project -e $script $(joinpath(store.root, "lock"))`, String)
                @test output == "busy"
            finally
                close(locked)
            end
            captured = Channel{String}(1)
            started = Channel{Nothing}(1)
            release = Channel{Nothing}(1)
            post = body -> begin
                put!(captured, body)
                put!(started, nothing)
                take!(release)
                JSON3.write(Dict("access_token" => "rotated-access", "refresh_token" => "rotated-refresh", "scope" => identityscope, "token_type" => "Bearer", "expires_in" => 3600))
            end
            job = Threads.@spawn CG.refresh(store, session.client, session.identity.subject; post, now=() -> identitytime + 3590)
            take!(started)
            @test CG.refresh(store, session.client, session.identity.subject; post, now=() -> identitytime + 3590) isa CG.Busy
            put!(release, nothing)
            rotated = fetch(job)
            form = HTTP.queryparams(HTTP.URI("http://127.0.0.1/?" * take!(captured)))
            @test form == Dict("grant_type" => "refresh_token", "client_id" => session.client, "refresh_token" => "synthetic-refresh", "resource" => "https://api.openai.com/v1")
            @test rotated.access == "rotated-access" && rotated.refresh == "rotated-refresh"
            @test rotated.expires == identitytime + 7190
            @test rotated.identity.subject == session.identity.subject && rotated.id_token == session.id_token
            @test CG.load(store, session.client, session.identity.subject).refresh == "rotated-refresh"
            @test CG.refresh(store, session.client, session.identity.subject; post=body -> error("must not refresh"), now=() -> identitytime + 3591).access == "rotated-access"
            invalid = body -> JSON3.write(Dict("access_token" => "bad", "refresh_token" => "", "token_type" => "Bearer", "expires_in" => 3600))
            @test CG.refresh(store, session.client, session.identity.subject; post=invalid, now=() -> identitytime + 7180) isa CG.Rejected
            @test CG.load(store, session.client, session.identity.subject).refresh == "rotated-refresh"
            @test_throws ErrorException CG.refresh(store, session.client, session.identity.subject; post=body -> error("network fixture"), now=() -> identitytime + 7180)
            @test CG.load(store, session.client, session.identity.subject).refresh == "rotated-refresh"
            original = read(path, String)
            changed = JSON3.read(original, Dict{String, Any})
            changed["subject"] = "different"
            write(path, JSON3.write(changed))
            @test CG.load(store, session.client, session.identity.subject) isa CG.Rejected
            write(path, original)
            chmod(path, 0o644)
            @test CG.load(store, session.client, session.identity.subject) isa CG.Rejected
            chmod(path, 0o600)
            otherpath = joinpath(root, "unrelated")
            write(otherpath, "untouched")
            rm(path)
            symlink(otherpath, path)
            @test CG.load(store, session.client, session.identity.subject) isa CG.Rejected
            @test read(otherpath, String) == "untouched"
            symlink(store.root, joinpath(root, "alias"))
            @test CG.Store(joinpath(root, "alias")) isa CG.Rejected
        end
    finally
        close(pending)
    end
end
