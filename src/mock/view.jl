# A small visual system for the prototype. Tachikoma owns terminal input,
# rendering, borders and the event loop; these helpers compose its primitives.
const BG       = ColorRGB(15, 18, 30)
const SURFACE  = ColorRGB(21, 25, 40)
const SELECTED = ColorRGB(41, 38, 67)
const BORDER   = ColorRGB(72, 80, 100)
const MUTED    = ColorRGB(165, 173, 192)
const TEXT     = ColorRGB(225, 229, 239)
const DIM      = ColorRGB(140, 149, 170)
const PURPLE   = ColorRGB(185, 158, 255)
const CYAN     = ColorRGB(113, 210, 210)
const GREEN    = ColorRGB(132, 218, 180)
const AMBER    = ColorRGB(237, 192, 121)

ink(c; bold=false) = Style(fg=c, bold=bold)
const BODY_STYLE = Style(fg=TEXT, bg=BG)
const CARD_STYLE = Style(fg=TEXT, bg=SURFACE)

function fill_rect!(buf::Buffer, r::Rect, style::Style)
    for y in r.y:bottom(r), x in r.x:right(r)
        set_char!(buf, x, y, ' ', style)
    end
end

function line!(buf::Buffer, r::Rect, x::Int, y::Int, s::AbstractString, style::Style=ink(TEXT))
    xx, yy = r.x + x, r.y + y
    if r.x <= xx <= right(r) && r.y <= yy <= bottom(r)
        visible = Tachikoma.truncate_to_width(s, right(r) - xx + 1)
        set_string!(buf, xx, yy, visible, style; max_x=right(r))
    end
end

function clickable!(m::MockState, r::Rect, x::Int, y::Int, width::Int, action::Symbol, index::Int=0)
    yy = r.y + y
    xx = r.x + x
    if yy <= bottom(r) && xx <= right(r) && yy >= r.y
        push!(m.hits, Hit(Rect(xx, yy, max(0, min(width, right(r) - xx + 1)), 1), action, index))
    end
end

function panel!(buf::Buffer, r::Rect, title::String, right_title::String="")
    fill_rect!(buf, r, CARD_STYLE)
    render(Block(title=title, title_right=right_title, border_style=ink(BORDER),
                 title_style=ink(MUTED, bold=true), title_right_style=ink(DIM)), r, buf)
end

function button!(m::MockState, buf::Buffer, r::Rect, x::Int, y::Int, text::String, action::Symbol, index::Int=0; primary=true)
    label = "  " * text * "  "
    style = Style(fg=primary ? BG : TEXT, bg=primary ? PURPLE : SELECTED, bold=true)
    line!(buf, r, x, y, label, style)
    clickable!(m, r, x, y, textwidth(label), action, index)
end

function view(m::MockState, f::Frame)
    buf, area = f.buffer, f.area
    empty!(m.hits)
    fill_rect!(buf, area, BODY_STYLE)
    if area.width < 76 || area.height < 25
        line!(buf, area, 2, 2, "JULIA FOREVER  /  SETUP PREVIEW", ink(PURPLE, bold=true))
        line!(buf, area, 2, 4, "Please resize your terminal to at least 76 × 25.", ink(TEXT))
        line!(buf, area, 2, 6, "Ctrl+C quits.", ink(MUTED))
        return
    end

    w = min(area.width - 4, 116)
    root = Rect(area.x + (area.width - w) ÷ 2, area.y, w, area.height)
    line!(buf, root, 0, 1, "JULIA FOREVER", ink(PURPLE, bold=true))
    line!(buf, root, max(0, w - 20), 1, "MOCK · NO CHANGES", ink(AMBER, bold=true))

    steps = [("01", "Sign in"), ("02", "Features"), ("03", "Profile")]
    for (i, (number, title)) in enumerate(steps)
        x = (i - 1) * 23
        color = i == min(m.page, 3) ? PURPLE : i < m.page ? GREEN : DIM
        line!(buf, root, x, 3, "$number  $title", ink(color, bold=i == min(m.page, 3)))
        i < 3 && line!(buf, root, x + 15, 3, "────", ink(BORDER))
        clickable!(m, root, x, 3, 13, :page, i)
    end

    headings = [("Sign in", "Choose a connection method."),
                ("Build features", "Select recipes to simulate parallel builds."),
                ("Save profile", "Builds continue while you choose a profile."),
                ("Prompt", "Preview only. No model is connected.")]
    line!(buf, root, 0, 5, headings[m.page][1], ink(TEXT, bold=true))
    line!(buf, root, 0, 6, headings[m.page][2], ink(MUTED))

    body = Rect(root.x, root.y + 8, root.width, root.height - 12)
    left_width = max(34, body.width * 47 ÷ 100)
    left = Rect(body.x, body.y, left_width, body.height)
    right_panel = Rect(body.x + left_width + 2, body.y, body.width - left_width - 2, body.height)
    if m.page == 1
        auth_view!(m, buf, left, right_panel)
    elseif m.page == 2
        recipes_view!(m, buf, left, right_panel)
    elseif m.page == 3
        profile_view!(m, buf, left, right_panel)
    else
        prompt_view!(m, buf, left, right_panel)
    end

    footer = Rect(root.x, bottom(root) - 1, root.width, 1)
    if m.page == 1
        help = m.auth_mode in (:api, :endpoint) ? "Enter simulate  ·  Ctrl+U clear  ·  Esc back" :
               m.auth_mode in (:subscriptions, :protocol) ? "↑↓ choose  ·  Enter simulate  ·  Esc back" :
               "↑↓ choose  ·  Enter open  ·  1–4 select  ·  q quit"
    elseif m.page == 2
        help = m.searching ? "Type to filter  ·  Enter finish  ·  Ctrl+U clear" :
               "↑↓ move  ·  Enter / Space toggle  ·  / search  ·  q quit"
    elseif m.page == 3
        help = m.editing_name ? "Edit name  ·  Enter finish  ·  Ctrl+U clear" :
               "↑↓ move  ·  Enter select  ·  e edit name  ·  s save  ·  q quit"
    else
        help = "Enter preview reply  ·  Ctrl+U clear  ·  Ctrl+C quit"
    end
    nav = m.page == 1 && !m.connected ? "connect to continue" :
          m.page == 1 ? "Tab  next →" : m.page == 2 ? "Shift+Tab  back     Tab  next →" :
          m.page == 3 && m.saved ? "Shift+Tab  back     Tab  prompt →" : "Shift+Tab  back"
    if footer.width < textwidth(help) + textwidth(nav) + 3
        help = m.page == 1 ? (m.auth_mode in (:api, :endpoint) ? "Enter simulate  ·  Ctrl+U clear  ·  Esc back" : "↑↓ choose  ·  Enter select  ·  Esc back") :
               m.page == 2 ? (m.searching ? "Type to filter  ·  Enter finish" : "↑↓ move  ·  Enter toggle  ·  / search") :
               m.page == 3 ? (m.editing_name ? "Edit name  ·  Enter finish" : "↑↓ move  ·  Enter select  ·  s save") :
               "Enter preview  ·  Ctrl+C quit"
    end
    line!(buf, footer, 0, 0, help, ink(MUTED))
    nx = max(0, footer.width - textwidth(nav))
    if nx > textwidth(help) + 2
        line!(buf, footer, nx, 0, nav, ink(PURPLE, bold=true))
    end
end

function auth_view!(m::MockState, buf::Buffer, left::Rect, right_panel::Rect)
    l = panel!(buf, left, "SIGN-IN METHOD", "01 / 03")
    r = panel!(buf, right_panel, "CONNECTION PREVIEW")
    descriptions = ["Detect a provider from a sample key", "Use a compatible service URL", "Choose a provider account", "Continue without signing in"]
    gap = l.height >= 12 ? 2 : 1
    for i in eachindex(AUTH_METHODS)
        y = 1 + (i - 1) * gap
        chosen = m.auth_cursor == i
        chosen && fill_rect!(buf, Rect(l.x + 1, l.y + y, max(0, l.width - 2), 1), Style(bg=SELECTED))
        line!(buf, l, 2, y, chosen ? "›" : " ", ink(PURPLE, bold=true))
        line!(buf, l, 4, y, "$(i)  $(AUTH_METHODS[i])", ink(chosen ? TEXT : MUTED, bold=chosen))
        clickable!(m, l, 1, y, l.width - 2, :auth_method, i)
    end
    if r.height < 17
        auth_compact_view!(m, buf, r)
        return
    end

    if m.auth_mode == :choose
        line!(buf, r, 2, 1, "Select a sign-in method", ink(TEXT, bold=true))
        line!(buf, r, 2, 3, descriptions[m.auth_cursor] * ".", ink(MUTED))
        line!(buf, r, 2, 5, "Demo only. No sign-in or network calls.", ink(AMBER))
    elseif m.auth_mode == :api || m.auth_mode == :endpoint
        api = m.auth_mode == :api
        line!(buf, r, 2, 1, api ? "Try a sample API key" : "Try a custom endpoint", ink(TEXT, bold=true))
        line!(buf, r, 2, 3, api ? "Use a fake key only — never enter a real secret." : "Example URL only. No requests will be sent.", ink(AMBER))
        line!(buf, r, 2, 5, api ? "SAMPLE KEY" : "ENDPOINT URL", ink(DIM, bold=true))
        shown = api ? repeat("•", min(length(m.auth_draft), 45)) : m.auth_draft
        line!(buf, r, 2, 6, "› " * shown * "_", ink(CYAN))
        line!(buf, r, 2, 8, api ? "Known-looking prefixes are a guess, not proof." : "Next, choose a compatible API format.", ink(MUTED))
        button!(m, buf, r, 2, min(11, r.height - 2), api ? "Simulate connection  →" : "Choose format  →", :auth_submit)
    elseif m.auth_mode == :subscriptions || m.auth_mode == :protocol
        subs = m.auth_mode == :subscriptions
        line!(buf, r, 2, 1, subs ? "Choose a subscription" : "Choose a compatible format", ink(TEXT, bold=true))
        line!(buf, r, 2, 3, subs ? "A preview only; no OAuth or account is opened." : "The choice is simulated and can be changed later.", ink(MUTED))
        choices = subs ? SUBSCRIPTIONS : PROTOCOLS
        for i in eachindex(choices)
            y = 5 + i
            line!(buf, r, 3, y, (i == m.choice_cursor ? "›  " : "   ") * choices[i], ink(i == m.choice_cursor ? PURPLE : TEXT, bold=i == m.choice_cursor))
            clickable!(m, r, 2, y, r.width - 4, :auth_choice, i)
        end
    else
        line!(buf, r, 2, 1, "✓  Connection simulated", ink(GREEN, bold=true))
        line!(buf, r, 2, 3, m.auth_label, ink(TEXT))
        line!(buf, r, 2, 5, "No provider was contacted and nothing was saved.", ink(MUTED))
        button!(m, buf, r, 2, min(8, r.height - 2), "Continue  →", :page, 2)
    end
end

function recipes_view!(m::MockState, buf::Buffer, left::Rect, right_panel::Rect)
    matches = matching_recipes(m)
    l = panel!(buf, left, "RECIPE LIBRARY", "$(length(matches)) shown")
    r = panel!(buf, right_panel, "FEATURE DETAILS")
    search_text = isempty(m.search) ? (m.searching ? "" : "Search recipes...") : m.search
    line!(buf, l, 2, 1, "/  " * search_text * (m.searching ? "_" : ""), ink(m.searching ? CYAN : MUTED))
    clickable!(m, l, 1, 1, l.width - 2, :search)

    available = max(1, l.height - 5)
    gap = available >= 2 * length(matches) ? 2 : 1
    capacity = max(1, (available + gap - 1) ÷ gap)
    if !isempty(matches)
        m.recipe_cursor = clamp(m.recipe_cursor, 1, length(matches))
        m.recipe_scroll = clamp(m.recipe_scroll, 0, max(0, length(matches) - capacity))
        m.recipe_cursor <= m.recipe_scroll && (m.recipe_scroll = m.recipe_cursor - 1)
        m.recipe_cursor > m.recipe_scroll + capacity && (m.recipe_scroll = m.recipe_cursor - capacity)
        for pos in (m.recipe_scroll + 1):min(length(matches), m.recipe_scroll + capacity)
            i = matches[pos]
            y = 3 + (pos - m.recipe_scroll - 1) * gap
            chosen = m.recipe_cursor == pos
            chosen && fill_rect!(buf, Rect(l.x + 1, l.y + y, max(0, l.width - 2), 1), Style(bg=SELECTED))
            p = recipe_progress(m, i)
            mark = m.started[i] == 0 ? "○" : p < 1 ? "◌" : "✓"
            status = m.started[i] == 0 ? (m.canceled[i] ? "CANCELED" : "ADD") : p < 1 ? "BUILDING" : "READY"
            color = m.started[i] == 0 ? (m.canceled[i] ? AMBER : DIM) : p < 1 ? CYAN : GREEN
            line!(buf, l, 2, y, chosen ? "›" : " ", ink(PURPLE, bold=true))
            line!(buf, l, 4, y, mark, ink(color, bold=true))
            line!(buf, l, 7, y, RECIPES[i].name, ink(chosen ? TEXT : MUTED, bold=chosen))
            sx = l.width - textwidth(status) - 2
            sx > 7 + textwidth(RECIPES[i].name) && line!(buf, l, sx, y, status, ink(color))
            clickable!(m, l, 1, y, l.width - 2, :recipe, i)
        end
    else
        line!(buf, l, 2, 4, "No recipes match. Edit the search to try again.", ink(MUTED))
    end
    line!(buf, l, 2, l.height - 1, "$(selected_count(m)) selected  ·  $(running_count(m)) building", ink(DIM))

    if isempty(matches)
        line!(buf, r, 2, 1, "No matching recipes", ink(TEXT, bold=true))
        line!(buf, r, 2, 3, "Search by name, category, or description.", ink(MUTED))
        return
    end
    i = matches[m.recipe_cursor]
    recipe = RECIPES[i]
    if r.height < 17
        recipe_compact_view!(m, buf, r, i)
        return
    end
    line!(buf, r, 2, 1, recipe.category, ink(PURPLE, bold=true))
    line!(buf, r, 2, 3, recipe.name, ink(TEXT, bold=true))
    line!(buf, r, 2, 5, recipe.description, ink(MUTED))
    if i == 6
        line!(buf, r, 2, 7, "Style:  $(COMPACTION_STYLES[m.compaction])   [c / click to change]", ink(CYAN))
        clickable!(m, r, 2, 7, r.width - 4, :compaction)
    elseif i == 3
        line!(buf, r, 2, 7, "Includes: periodic checks", ink(CYAN))
    elseif i == 9
        line!(buf, r, 2, 7, "Description input is not implemented.", ink(CYAN))
    end

    p = recipe_progress(m, i)
    if m.started[i] == 0
        line!(buf, r, 2, 10, m.canceled[i] ? "◌  Canceled · nothing deleted" : "○  Not selected", ink(m.canceled[i] ? AMBER : MUTED))
    elseif p < 1
        phase = p < 1 / 3 ? "Planning" : p < 2 / 3 ? "Assembling" : "Finishing"
        n = clamp(floor(Int, p * 18), 0, 18)
        line!(buf, r, 2, 10, "◌  $phase · simulated", ink(CYAN, bold=true))
        line!(buf, r, 2, 12, repeat("━", n) * repeat("─", 18 - n) * "  $(round(Int, p * 100))%", ink(CYAN))
    else
        line!(buf, r, 2, 10, "✓  Ready · simulated", ink(GREEN, bold=true))
    end
end

function profile_view!(m::MockState, buf::Buffer, left::Rect, right_panel::Rect)
    l = panel!(buf, left, "CHOOSE A PROFILE", "03 / 03")
    r = panel!(buf, right_panel, "PROFILE PREVIEW")
    descriptions = ["", "For a named sub-agent", ""]
    gap = l.height >= 15 ? 3 : l.height <= 10 ? 1 : 2
    for i in eachindex(PROFILES)
        y = 1 + (i - 1) * gap
        cursor = m.profile_cursor == i
        cursor && fill_rect!(buf, Rect(l.x + 1, l.y + y, max(0, l.width - 2), 1), Style(bg=SELECTED))
        line!(buf, l, 2, y, cursor ? "›" : " ", ink(PURPLE, bold=true))
        line!(buf, l, 4, y, m.profile_selected == i ? "●" : "○", ink(m.profile_selected == i ? PURPLE : DIM))
        line!(buf, l, 7, y, PROFILES[i], ink(cursor ? TEXT : MUTED, bold=cursor))
        gap == 3 && !isempty(descriptions[i]) && line!(buf, l, 7, y + 1, descriptions[i], ink(DIM))
        clickable!(m, l, 1, y, l.width - 2, :profile, i)
    end
    if m.profile_selected != 1
        name_y = min(11, l.height - 4)
        line!(buf, l, 2, name_y, "PROFILE NAME", ink(DIM, bold=true))
        line!(buf, l, 2, name_y + 1, "› " * profile_name(m) * (m.editing_name ? "_" : "   [e to edit]"), ink(CYAN))
        clickable!(m, l, 1, name_y + 1, l.width - 2, :profile_name)
    end
    if r.height < 17
        profile_compact_view!(m, buf, r)
        return
    end

    line!(buf, r, 2, 1, "Configuration", ink(TEXT, bold=true))
    line!(buf, r, 2, 3, "PROFILE", ink(DIM, bold=true))
    line!(buf, r, 2, 4, isempty(strip(profile_name(m))) ? "Name required" : profile_name(m), ink(isempty(strip(profile_name(m))) ? AMBER : CYAN))
    line!(buf, r, 2, 6, "CONNECTION", ink(DIM, bold=true))
    line!(buf, r, 2, 7, m.auth_label, ink(TEXT))
    line!(buf, r, 2, 9, "FEATURES  ·  $(selected_count(m)) selected / $(running_count(m)) building", ink(DIM, bold=true))
    selected = findall(!iszero, m.started)
    summary = isempty(selected) ? "No features selected yet." : join((RECIPES[i].name for i in selected), ", ")
    line!(buf, r, 2, 10, summary, ink(TEXT))
    if m.saved
        line!(buf, r, 2, 13, "✓  Saved for this session only", ink(GREEN, bold=true))
    else
        line!(buf, r, 2, 13, "Save without waiting for builds.", ink(MUTED))
    end
    if m.saved
        button!(m, buf, r, 2, min(16, r.height - 2), "Open prompt  →", :page, 4)
    else
        button!(m, buf, r, 2, min(16, r.height - 2), "Save profile  →", :save)
    end
end
