# Shorter cards keep the same interactions visible in a small terminal.
function auth_compact_view!(m::MockState, buf::Buffer, r::Rect)
    if m.auth_mode == :choose
        line!(buf, r, 2, 0, "Select a sign-in method", ink(TEXT, bold=true))
        line!(buf, r, 2, 2, "Demo only. No network calls.", ink(AMBER))
    elseif m.auth_mode == :api || m.auth_mode == :endpoint
        api = m.auth_mode == :api
        line!(buf, r, 2, 0, api ? "Try a sample API key" : "Try a custom endpoint", ink(TEXT, bold=true))
        line!(buf, r, 2, 2, api ? "Fake key only. No real secrets." : "Sample URL. No requests sent.", ink(AMBER))
        line!(buf, r, 2, 3, api ? "SAMPLE KEY" : "ENDPOINT URL", ink(DIM, bold=true))
        shown = api ? repeat("•", min(length(m.auth_draft), 30)) : m.auth_draft
        line!(buf, r, 2, 4, "› " * shown * "_", ink(CYAN))
        button!(m, buf, r, 2, 6, api ? "Simulate connection  →" : "Choose format  →", :auth_submit)
    elseif m.auth_mode == :subscriptions || m.auth_mode == :protocol
        subs = m.auth_mode == :subscriptions
        choices = subs ? SUBSCRIPTIONS : PROTOCOLS
        line!(buf, r, 2, 0, subs ? "Choose a subscription" : "Choose a compatible format", ink(TEXT, bold=true))
        line!(buf, r, 2, 1, "No provider is contacted.", ink(MUTED))
        for i in eachindex(choices)
            y = 2 + i
            line!(buf, r, 2, y, (i == m.choice_cursor ? "›  " : "   ") * choices[i], ink(i == m.choice_cursor ? PURPLE : TEXT))
            clickable!(m, r, 2, y, r.width - 4, :auth_choice, i)
        end
    else
        line!(buf, r, 2, 0, "✓  Connection simulated", ink(GREEN, bold=true))
        line!(buf, r, 2, 2, m.auth_label, ink(TEXT))
        line!(buf, r, 2, 4, "No provider was contacted.", ink(MUTED))
        button!(m, buf, r, 2, 6, "Continue  →", :page, 2)
    end
end

function recipe_compact_view!(m::MockState, buf::Buffer, r::Rect, i::Int)
    recipe = RECIPES[i]
    line!(buf, r, 2, 0, "$(recipe.category)  /  $(recipe.name)", ink(PURPLE, bold=true))
    line!(buf, r, 2, 2, recipe.description, ink(MUTED))
    if i == 6
        line!(buf, r, 2, 3, "Style: $(COMPACTION_STYLES[m.compaction])   [c / click]", ink(CYAN))
        clickable!(m, r, 2, 3, r.width - 4, :compaction)
    elseif i == 3
        line!(buf, r, 2, 3, "Includes: periodic checks", ink(CYAN))
    end
    p = recipe_progress(m, i)
    if m.started[i] == 0
        line!(buf, r, 2, 5, m.canceled[i] ? "◌  Canceled · nothing deleted" : "○  Not selected yet", ink(m.canceled[i] ? AMBER : MUTED))
    elseif p < 1
        phase = p < 1 / 3 ? "Planning" : p < 2 / 3 ? "Assembling" : "Finishing"
        line!(buf, r, 2, 5, "◌  $phase · simulated · $(round(Int, p * 100))%", ink(CYAN))
    else
        line!(buf, r, 2, 5, "✓  Ready · simulated", ink(GREEN))
    end
end

function profile_compact_view!(m::MockState, buf::Buffer, r::Rect)
    label = isempty(strip(profile_name(m))) ? "Name required" : profile_name(m)
    line!(buf, r, 2, 0, "Configuration", ink(TEXT, bold=true))
    line!(buf, r, 2, 2, "Profile: " * label, ink(CYAN))
    line!(buf, r, 2, 3, "Connection: " * m.auth_label, ink(MUTED))
    line!(buf, r, 2, 5, "$(selected_count(m)) selected · $(running_count(m)) building", ink(TEXT))
    line!(buf, r, 2, 6, m.saved ? "✓ Saved for this session only." : "Save while builds continue.", ink(m.saved ? GREEN : MUTED))
    if m.saved
        button!(m, buf, r, 2, 8, "Open prompt  →", :page, 4)
    else
        button!(m, buf, r, 2, 8, "Save profile  →", :save)
    end
end
