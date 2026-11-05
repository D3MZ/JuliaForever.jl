using PrecompileTools: @setup_workload, @compile_workload

@setup_workload begin
    menu = Menu()
    output = IOBuffer()
    terminal = Tachikoma.Terminal(; io=output, size=(rows=40, cols=142), external_size=true)
    overlay = Tachikoma.AppOverlay()
    frame = Frame(Buffer(Rect(1, 1, 142, 40)), Rect(1, 1, 142, 40),
                  Tachikoma.GraphicsRegion[], Tachikoma.PixelSnapshot[])

    @compile_workload begin
        view(menu, frame)
        Tachikoma.dispatch_event!(terminal, overlay, menu, KeyEvent(:down), false)
        Tachikoma.dispatch_event!(terminal, overlay, menu, KeyEvent(:enter), false)
        Tachikoma.dispatch_event!(terminal, overlay, menu, KeyEvent(:tab), false)
        view(menu, frame)

        show_page!(menu, :accounts, ["ChatGPT", "Other provider"])
        view(menu, frame)
        Tachikoma.dispatch_event!(terminal, overlay, menu, KeyEvent(:down), false)

        menu.catalog = [(id="profile-model", name="Profile model", window=272_000),
                        (id="other-model", name="Other model", window=272_000)]
        menu.filtered = [1, 2]
        show_page!(menu, :models, [model.name for model in menu.catalog])
        view(menu, frame)
        Tachikoma.dispatch_event!(terminal, overlay, menu, KeyEvent('p'), false)
        view(menu, frame)
        Tachikoma.dispatch_event!(terminal, overlay, menu, KeyEvent(:ctrl, 'a'), false)
        Tachikoma.dispatch_event!(terminal, overlay, menu, KeyEvent(:ctrl, 'e'), false)
        Tachikoma.dispatch_event!(terminal, overlay, menu, KeyEvent(:ctrl, 'w'), false)
        Tachikoma.dispatch_event!(terminal, overlay, menu, KeyEvent(:ctrl, 'y'), false)
        Tachikoma.dispatch_event!(terminal, overlay, menu, KeyEvent(:ctrl, 'u'), false)
        Tachikoma.dispatch_event!(terminal, overlay, menu, KeyEvent('é'), false)
        Tachikoma.dispatch_event!(terminal, overlay, menu, KeyEvent('_'), false)
        Tachikoma.dispatch_event!(terminal, overlay, menu, KeyEvent(:ctrl, 'w'), false)
        Tachikoma.dispatch_event!(terminal, overlay, menu, KeyEvent(:backspace), false)
        raw_editor_command(Vector{UInt8}(codeunits("\e[1;3D")))
        raw_editor_command(Vector{UInt8}(codeunits("\e[127;9u")))
        Tachikoma.dispatch_event!(terminal, overlay, menu, KeyEvent(:down), false)
        Tachikoma.dispatch_event!(terminal, overlay, menu, KeyEvent(:enter), false)
        view(menu, frame)
        area = menu.choices.last_area
        Tachikoma.dispatch_event!(terminal, overlay, menu,
            MouseEvent(area.x + 2, area.y, mouse_left, mouse_press, false, false, false), false)
        menu.selected_model = 0
        area = menu.button.last_area
        Tachikoma.dispatch_event!(terminal, overlay, menu,
            MouseEvent(area.x, area.y, mouse_left, mouse_press, false, false, false), false)

        session = NativeAgent.Session(model="profile-model", cwd="/tmp",
            input=Any[Dict("role" => "user", "content" => "A short prompt"),
                      Dict("role" => "assistant", "content" => [Dict("type" => "output_text",
                          "text" => "A short response with café and wide text 漢字.")])])
        show_chat!(menu, session)
        view(menu, frame)
        Tachikoma.dispatch_event!(terminal, overlay, menu, Tachikoma._track_key_state!(KeyEvent('p')), false)
        Tachikoma.dispatch_event!(terminal, overlay, menu, KeyEvent(:ctrl, 'a'), false)
        Tachikoma.dispatch_event!(terminal, overlay, menu, KeyEvent(:ctrl, 'e'), false)
        Tachikoma.dispatch_event!(terminal, overlay, menu, KeyEvent(:ctrl, 'u'), false)
        Tachikoma.dispatch_event!(terminal, overlay, menu, KeyEvent(:ctrl, 'y'), false)
        Tachikoma.dispatch_event!(terminal, overlay, menu, KeyEvent(:ctrl, '_'), false)
        Tachikoma.dispatch_event!(terminal, overlay, menu, KeyEvent(:backspace), false)
        Tachikoma.dispatch_event!(terminal, overlay, menu, KeyEvent(:up), false)
        Tachikoma.dispatch_event!(terminal, overlay, menu, KeyEvent(:down), false)
        Tachikoma.dispatch_event!(terminal, overlay, menu, KeyEvent(:enter), false)
        Base.put!(menu.pending, (:delta, " streaming"))
        view(menu, frame)
        Base.put!(menu.pending, (:done, ""))
        view(menu, frame)
        menu.streaming = repeat("responsive text ", 4_000)
        view(menu, frame)
        if menu.layout.stream_task !== nothing
            wait(menu.layout.stream_task)
            view(menu, frame)
        end
        menu.streaming = ""
        view(menu, frame)
        Tachikoma.draw!(terminal) do rendered
            view(menu, rendered)
        end
        Tachikoma.reset_key_state!()
        menu.quit = false
        show_page!(menu, :auth, auth_options())
        Tachikoma.enable_raw_capture!()
        try
            Tachikoma.app(menu; fps=120, default_bindings=false, io=IOBuffer(),
                          input=IOBuffer("\x03"), tty_size=(rows=20, cols=80))
        finally
            Tachikoma.disable_raw_capture!()
        end
    end
end
