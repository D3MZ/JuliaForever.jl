function prompt_view!(m::MockState, buf::Buffer, left::Rect, right_panel::Rect)
    l = panel!(buf, left, "YOUR PROMPT", "DEMO")
    r = panel!(buf, right_panel, "CONVERSATION PREVIEW")
    line!(buf, l, 2, 1, "Enter a request", ink(TEXT, bold=true))
    room = max(1, l.width - 6)
    draft = length(m.prompt_draft) > room ? "…" * last(m.prompt_draft, room - 1) : m.prompt_draft
    line!(buf, l, 2, 5, "› " * draft * "_", ink(CYAN))
    button!(m, buf, l, 2, min(8, l.height - 1), "Preview reply  →", :send_prompt)
    if l.height >= 14
        line!(buf, l, 2, 11, "Profile: " * profile_name(m), ink(MUTED))
        line!(buf, l, 2, 13, "$(running_count(m)) simulated builds still running", ink(DIM))
    end

    if isempty(m.last_prompt)
        line!(buf, r, 2, 1, "No messages", ink(TEXT, bold=true))
        line!(buf, r, 2, 3, "Mock only. No data is sent.", ink(AMBER))
    else
        line!(buf, r, 2, 0, "YOU", ink(PURPLE, bold=true))
        line!(buf, r, 2, 1, m.last_prompt, ink(TEXT))
        line!(buf, r, 2, 3, "JULIA FOREVER  /  PREVIEW", ink(PURPLE, bold=true))
        line!(buf, r, 2, 4, "Simulated reply; no model used.", ink(TEXT))
    end
end
