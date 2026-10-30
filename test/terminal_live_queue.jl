using Test, JuliaForever

@testset "live terminal deferred inputs" begin
    live = JuliaForever.LiveTerminal
    pending = live.DeferredQueue()
    @test pending.steering isa Channel{String}
    @test pending.followups isa Channel{String}
    @test isempty(pending)

    live.defer!(pending, "follow one", live.Follow())
    live.defer!(pending, "steer one", live.Send())
    live.defer!(pending, "follow two", live.Follow())
    live.defer!(pending, "steer two", live.Send())
    @test [item.text for item in pending.display] == ["follow one", "steer one", "follow two", "steer two"]
    @test live.next!(pending) == "steer one"
    @test live.next!(pending) == "steer two"
    @test [item.text for item in pending.display] == ["follow one", "follow two"]
    @test live.next!(pending) == "follow one"
    @test live.next!(pending) == "follow two"
    @test isempty(pending)
    @test isempty(pending.display)

    live.defer!(pending, "follow", live.Follow())
    live.defer!(pending, "steer", live.Send())
    queued = (; steering=["already steering"], followups=["already following"])
    @test live.collect!(pending, queued) == ["already steering", "steer", "already following", "follow"]
    @test isempty(pending)
    @test isempty(pending.display)

    live.defer!(pending, "discard", live.Send())
    empty!(pending)
    @test isempty(pending)
    @test isempty(pending.display)
end
