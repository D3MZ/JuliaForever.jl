without_last(s::String) = isempty(s) ? s : chop(s; tail=1)

function update!(m::MockState, e::KeyEvent)
    # Page navigation stays available while simulated builds are running.
    if e.key == :tab
        change_page!(m, m.page + 1)
        return
    elseif e.key == :backtab
        change_page!(m, m.page - 1)
        return
    elseif e.key == :ctrl_c || (e.key == :ctrl && e.char == 'c')
        m.quit = true
        return
    end

    if m.page == 1
        auth_key!(m, e)
    elseif m.page == 2
        recipe_key!(m, e)
    elseif m.page == 3
        profile_key!(m, e)
    else
        prompt_key!(m, e)
    end
end

function auth_key!(m::MockState, e::KeyEvent)
    if m.auth_mode == :api || m.auth_mode == :endpoint
        if e.key == :enter
            submit_auth!(m)
        elseif e.key == :escape
            m.auth_draft = ""
            m.auth_mode = :choose
        elseif e.key == :backspace
            m.auth_draft = without_last(m.auth_draft)
        elseif e.key == :ctrl && e.char == 'u'
            m.auth_draft = ""
        elseif e.key == :char && length(m.auth_draft) < 160 && !iscntrl(e.char)
            m.auth_draft *= e.char
        end
        return
    elseif m.auth_mode == :subscriptions || m.auth_mode == :protocol
        choices = m.auth_mode == :subscriptions ? SUBSCRIPTIONS : PROTOCOLS
        if e.key == :up
            m.choice_cursor = mod1(m.choice_cursor - 1, length(choices))
        elseif e.key == :down
            m.choice_cursor = mod1(m.choice_cursor + 1, length(choices))
        elseif e.key == :enter
            submit_auth!(m)
        elseif e.key == :escape
            m.auth_mode = :choose
        end
        return
    end

    if e.key == :up
        m.auth_cursor = mod1(m.auth_cursor - 1, length(AUTH_METHODS))
    elseif e.key == :down
        m.auth_cursor = mod1(m.auth_cursor + 1, length(AUTH_METHODS))
    elseif e.key == :enter
        select_auth!(m, m.auth_cursor)
    elseif e.key == :char && e.char in '1':'4'
        select_auth!(m, Int(e.char - '0'))
    elseif e.key == :char && e.char == 'q'
        m.quit = true
    end
end

function recipe_key!(m::MockState, e::KeyEvent)
    if m.searching
        if e.key == :enter || e.key == :escape
            m.searching = false
        elseif e.key == :backspace
            m.search = without_last(m.search)
            m.recipe_cursor = 1
            m.recipe_scroll = 0
        elseif e.key == :ctrl && e.char == 'u'
            m.search = ""
            m.recipe_cursor = 1
            m.recipe_scroll = 0
        elseif e.key == :char && length(m.search) < 80 && !iscntrl(e.char)
            m.search *= e.char
            m.recipe_cursor = 1
            m.recipe_scroll = 0
        end
        return
    end

    matches = matching_recipes(m)
    if e.key == :up && !isempty(matches)
        m.recipe_cursor = mod1(m.recipe_cursor - 1, length(matches))
    elseif e.key == :down && !isempty(matches)
        m.recipe_cursor = mod1(m.recipe_cursor + 1, length(matches))
    elseif (e.key == :enter || (e.key == :char && e.char == ' ')) && !isempty(matches)
        toggle_recipe!(m, matches[clamp(m.recipe_cursor, 1, length(matches))])
    elseif e.key == :char && e.char == '/'
        m.searching = true
    elseif e.key == :char && e.char == 'c' && !isempty(matches) && matches[m.recipe_cursor] == 6
        cycle_compaction!(m)
    elseif e.key == :char && e.char == 'q'
        m.quit = true
    end
end

function profile_key!(m::MockState, e::KeyEvent)
    if m.editing_name
        if e.key == :enter || e.key == :escape
            m.editing_name = false
        elseif e.key == :backspace
            if m.profile_selected == 2
                m.agent_name = without_last(m.agent_name)
            else
                m.custom_name = without_last(m.custom_name)
            end
            m.saved = false
        elseif e.key == :ctrl && e.char == 'u'
            if m.profile_selected == 2
                m.agent_name = ""
            else
                m.custom_name = ""
            end
            m.saved = false
        elseif e.key == :char && !iscntrl(e.char)
            if m.profile_selected == 2 && length(m.agent_name) < 40
                m.agent_name *= e.char
            elseif m.profile_selected == 3 && length(m.custom_name) < 40
                m.custom_name *= e.char
            end
            m.saved = false
        end
        return
    end

    if e.key == :up
        m.profile_cursor = mod1(m.profile_cursor - 1, length(PROFILES))
    elseif e.key == :down
        m.profile_cursor = mod1(m.profile_cursor + 1, length(PROFILES))
    elseif e.key == :enter || (e.key == :char && e.char == ' ')
        select_profile!(m, m.profile_cursor)
    elseif e.key == :char && e.char == 'e' && m.profile_selected != 1
        m.editing_name = true
    elseif e.key == :char && e.char == 's'
        save_profile!(m)
    elseif e.key == :char && e.char == 'q'
        m.quit = true
    end
end

function prompt_key!(m::MockState, e::KeyEvent)
    if e.key == :enter
        send_prompt!(m)
    elseif e.key == :backspace
        m.prompt_draft = without_last(m.prompt_draft)
    elseif e.key == :ctrl && e.char == 'u'
        m.prompt_draft = ""
    elseif e.key == :char && !iscntrl(e.char) && length(m.prompt_draft) < 240
        m.prompt_draft *= e.char
    end
end

function update!(m::MockState, e::MouseEvent)
    e.action == mouse_press && e.button == mouse_left || return
    for hit in Iterators.reverse(m.hits)
        a = hit.area
        if a.x <= e.x <= right(a) && a.y <= e.y <= bottom(a)
            click!(m, hit.action, hit.index)
            return
        end
    end
end

function click!(m::MockState, action::Symbol, index::Int)
    if action == :page
        change_page!(m, index)
    elseif action == :auth_method
        select_auth!(m, index)
    elseif action == :auth_submit
        submit_auth!(m)
    elseif action == :auth_choice
        m.choice_cursor = index
        submit_auth!(m)
    elseif action == :search
        m.searching = true
    elseif action == :recipe
        matches = matching_recipes(m)
        pos = findfirst(==(index), matches)
        if pos !== nothing
            m.recipe_cursor = pos
            toggle_recipe!(m, index)
        end
    elseif action == :compaction
        cycle_compaction!(m)
    elseif action == :profile
        select_profile!(m, index)
    elseif action == :profile_name
        m.profile_selected != 1 && (m.editing_name = true)
    elseif action == :save
        save_profile!(m)
    elseif action == :send_prompt
        send_prompt!(m)
    end
end
