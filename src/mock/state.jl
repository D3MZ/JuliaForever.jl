# All state in this prototype is ephemeral. No agent, credential, file, or
# profile operations are performed by these simulated transitions.
struct Recipe
    name::String
    category::String
    description::String
end

const RECIPES = [
    Recipe("Microphone", "INPUT", "Capture voice input."),
    Recipe("Model selector", "MODELS", "Switch between models."),
    Recipe("Scheduling", "AUTOMATION", "Schedule tasks or periodic checks."),
    Recipe("Web app", "INTERFACE", "Use the agent through a web interface."),
    Recipe("GitHub", "INTEGRATIONS", "Work with repositories and pull requests."),
    Recipe("Compaction", "MEMORY", "Summarize long conversations."),
    Recipe("Browser", "TOOLS", "Browse the web."),
    Recipe("Caesar cipher", "EXAMPLE", "Encode and decode text."),
    Recipe("Custom feature", "CUSTOM", "Placeholder for a user-defined recipe."),
]

const AUTH_METHODS = ["API key", "Endpoint", "Subscription", "Explore the demo"]
const SUBSCRIPTIONS = ["ChatGPT / OpenAI", "Anthropic / Claude", "Google / Gemini", "Other provider"]
const PROTOCOLS = ["OpenAI Chat Completions", "OpenAI Responses", "Anthropic Messages", "Google Gemini"]
const COMPACTION_STYLES = ["Pi", "DeepSeek", "Minimal"]
const PROFILES = ["Default", "Agent named", "Custom"]
const BUILD_SECONDS = 24.0

struct Hit
    area::Rect
    action::Symbol
    index::Int
end

@kwdef mutable struct MockState <: Model
    quit::Bool = false
    page::Int = 1
    auth_cursor::Int = 1
    auth_mode::Symbol = :choose
    auth_origin::Symbol = :none
    auth_draft::String = ""
    auth_label::String = ""
    connected::Bool = false
    choice_cursor::Int = 1
    search::String = ""
    searching::Bool = false
    recipe_cursor::Int = 1
    recipe_scroll::Int = 0
    started::Vector{Float64} = zeros(length(RECIPES))
    canceled::Vector{Bool} = fill(false, length(RECIPES))
    compaction::Int = 1
    profile_cursor::Int = 1
    profile_selected::Int = 1
    agent_name::String = "researcher"
    custom_name::String = "my-profile"
    editing_name::Bool = false
    saved::Bool = false
    prompt_draft::String = ""
    last_prompt::String = ""
    hits::Vector{Hit} = Hit[]
end

should_quit(m::MockState) = m.quit

function matching_recipes(m::MockState)
    needle = lowercase(strip(m.search))
    [i for (i, r) in enumerate(RECIPES) if isempty(needle) ||
        occursin(needle, lowercase("$(r.name) $(r.category) $(r.description)"))]
end

selected_count(m::MockState) = count(!iszero, m.started)
running_count(m::MockState) = count(t -> t > 0 && time() - t < BUILD_SECONDS, m.started)
recipe_progress(m::MockState, i::Int) = m.started[i] == 0 ? 0.0 : clamp((time() - m.started[i]) / BUILD_SECONDS, 0.0, 1.0)
profile_name(m::MockState) = m.profile_selected == 1 ? "Default" :
    m.profile_selected == 2 ? m.agent_name : m.custom_name

function select_auth!(m::MockState, index::Int)
    m.auth_cursor = index
    m.auth_origin = :none
    m.choice_cursor = 1
    m.auth_draft = ""
    if index == 1
        m.auth_mode = :api
        m.auth_draft = "sk-demo-key"
    elseif index == 2
        m.auth_mode = :endpoint
        m.auth_draft = "https://example.com/v1"
    elseif index == 3
        m.auth_mode = :subscriptions
    else
        finish_auth!(m, "Demo session")
    end
end

function finish_auth!(m::MockState, label::String)
    m.auth_draft = ""  # Never retain the sample key after the transition.
    m.auth_label = label
    m.connected = true
    m.auth_mode = :ready
    m.saved = false
end

function submit_auth!(m::MockState)
    if m.auth_mode == :api
        key = strip(m.auth_draft)
        isempty(key) && return
        # Deliberately illustrative: key prefixes cannot reliably identify a provider.
        label = startswith(key, "sk-ant-") ? "Anthropic-looking key" :
                startswith(key, "sk-proj-") || startswith(key, "sk-demo-") ? "OpenAI-looking key" :
                startswith(key, "AIza") ? "Google-looking key" : ""
        m.auth_draft = ""
        if isempty(label)
            m.auth_origin = :api
            m.auth_mode = :protocol
            m.choice_cursor = 1
        else
            finish_auth!(m, label * " · demo")
        end
    elseif m.auth_mode == :endpoint
        isempty(strip(m.auth_draft)) && return
        m.auth_draft = ""
        m.auth_origin = :endpoint
        m.auth_mode = :protocol
        m.choice_cursor = 1
    elseif m.auth_mode == :subscriptions
        finish_auth!(m, SUBSCRIPTIONS[m.choice_cursor] * " · demo")
    elseif m.auth_mode == :protocol
        source = m.auth_origin == :api ? "Custom key" : "Custom endpoint"
        finish_auth!(m, source * " · " * PROTOCOLS[m.choice_cursor])
    elseif m.auth_mode == :ready
        change_page!(m, 2)
    end
end

function change_page!(m::MockState, page::Int)
    page = clamp(page, 1, 4)
    page > 1 && !m.connected && return
    page == 4 && !m.saved && return
    m.page = page
    m.searching = false
    m.editing_name = false
end

function toggle_recipe!(m::MockState, index::Int)
    if m.started[index] == 0
        m.started[index] = time()
        m.canceled[index] = false
    else
        m.started[index] = 0
        m.canceled[index] = true
    end
    m.saved = false
end

function cycle_compaction!(m::MockState)
    m.compaction = mod1(m.compaction + 1, length(COMPACTION_STYLES))
    m.started[6] > 0 && (m.started[6] = time())
    m.saved = false
end

function select_profile!(m::MockState, index::Int)
    m.profile_cursor = index
    m.profile_selected = index
    m.editing_name = index != 1
    m.saved = false
end

function save_profile!(m::MockState)
    isempty(strip(profile_name(m))) && return
    m.editing_name = false
    m.saved = true
end

function send_prompt!(m::MockState)
    isempty(strip(m.prompt_draft)) && return
    m.last_prompt = m.prompt_draft
    m.prompt_draft = ""
end
