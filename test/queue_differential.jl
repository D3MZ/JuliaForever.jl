using Test, JSON3, JuliaForever

@testset "Pi queued-message recovery" begin
    source = ENV["PI_SOURCE"]
    @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
    reference = JSON3.read(read(`node $(joinpath(@__DIR__, "queue_reference.mjs")) $source`, String))
    agent = Agent(nothing, [])
    steer!(agent, "steer one")
    followup!(agent, "follow one")
    steer!(agent, "steer two")
    followup!(agent, "follow two")
    queued = dequeue!(agent)
    @test queued.steering == reference.steering
    @test queued.followups == reference.followups
    @test (isempty(agent.state.steering) && isempty(agent.state.followups)) == reference.empty
end

@testset "Pi image queue recovery discards attachments" begin
    source = ENV["PI_SOURCE"]
    @test readchomp(`git -C $source rev-parse HEAD`) == "e7a0df27c09d11bf4161d3605246cbf57a129cb2"
    reference = JSON3.read(read(`node $(joinpath(@__DIR__, "image_queue_recovery_pi.mjs")) $source`, String))
    @test [message[2].data for message in reference.before] == ["c3ludGhldGljLWltYWdl", "c3ludGhldGljLWltYWdl"]
    @test reference.restored.steering == ["image steering"]
    @test reference.restored.followUp == ["image followup"]
    @test isempty(reference.remaining)
end
