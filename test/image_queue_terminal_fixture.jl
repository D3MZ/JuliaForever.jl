using JuliaForever, JSON3

mutable struct ImageQueueFixture
    directory::String
    mode::String
    agent::Any
    calls::Int
end

function JuliaForever.stream(fixture::ImageQueueFixture, messages, tools; parameters=Dict(), on_event=identity)
    fixture.calls += 1
    image = Image("image/png", "c3ludGhldGljLWltYWdl")
    steer!(fixture.agent, "text steering")
    steer!(fixture.agent, JuliaForever.Conversation.ImagePrompt("image steering", [image]))
    followup!(fixture.agent, JuliaForever.Conversation.ImagePrompt("image followup", [image]))
    followup!(fixture.agent, "text followup")
    on_event((; type=:text, text="waiting"))
    write(joinpath(fixture.directory, "started"), "ready")
    deadline = time() + 180
    while !isfile(joinpath(fixture.directory, "release")) && !JuliaForever.cancelled(fixture.agent) && time() < deadline
        sleep(0.01)
    end
    write(joinpath(fixture.directory, "provider_finished"), "done")
    message = Dict{String, Any}("role" => "assistant", "content" => "waiting")
    fixture.mode == "failure" ? Completion(message, nothing, "content_filter", false, JuliaForever.providererror(:openai_compatible, "content_filter")) : Completion(message, nothing, "stop", true, nothing)
end

wire(value::String) = value
wire(value::JuliaForever.Conversation.ImageUser) = convert(Dict{String, Any}, value)

directory, mode, style_name = ARGS
path = joinpath(directory, "session.sqlite")
history = JuliaForever.History.Tree(open(JuliaForever.History.SQLite, path))
fixture = ImageQueueFixture(directory, mode, nothing, 0)
agent = Agent(fixture, []; history)
fixture.agent = agent
terminal = JuliaForever.Terminal(stdout, stderr, String[])
view_mode = style_name == "fullscreen" ? JuliaForever.LiveTerminal.FullscreenMode() : JuliaForever.LiveTerminal.RegularMode()
status = JuliaForever.LiveTerminal.loop!(terminal, agent, nothing, Ref(history), stdin, directory, Dict{String, String}(), view_mode)
close(history)
history = JuliaForever.History.Tree(open(JuliaForever.History.SQLite, path; create=false))
restored = Agent(nothing, []; history)
report = (; status, calls=fixture.calls, steering=wire.(restored.state.steering), followups=wire.(restored.state.followups), events=string.(nameof.(typeof.(restored.events))))
write(joinpath(directory, "report.json"), JSON3.write(report))
close(history)
