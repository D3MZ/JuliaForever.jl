struct ChatGPTAuth <: Authentication end
abstract type ChatGPTSelection end
struct ResumeChatGPT <: ChatGPTSelection end
struct ChooseChatGPT <: ChatGPTSelection end

chatgptdirectory(env) = abspath(expanduser(get(env, "JF_CHATGPT_DIR", joinpath(homedir(), ".config", "juliaforever", "chatgpt"))))

function browseropen(url)
    command = Sys.isapple() ? `open $url` : `xdg-open $url`
    success(pipeline(command; stdout=devnull, stderr=devnull))
end

function connectchatgpt(store, chosen; output=stderr, opener=browseropen, post=ChatGPT.posttoken, fetcher=ChatGPT.fetch, now=time, waitfor=wait)
    connectchatgpt(store, chosen, ChatGPT.host(store); output, opener, post, fetcher, now, waitfor)
end
connectchatgpt(store, chosen, failure; kwargs...) = failure
function connectchatgpt(store, chosen, host::AbstractString; output, opener, post, fetcher, now, waitfor)
    registered = loginregistration(chosen)
    pending = ChatGPT.Pending(registered, host)
    try
        authorization = ChatGPT.authorize(pending)
        println(output, "Continue with ChatGPT to allow Julia Forever to use your ChatGPT plan.")
        announcechatgpt(output, registered, authorization)
        flush(output)
        launched = ChatGPT.launch(opener, authorization)
        waitchatgpt(store, chosen, registered, pending, launched; post, fetcher, now, waitfor)
    catch
        ChatGPT.Rejected(:authorization)
    finally
        close(pending)
    end
end
announcechatgpt(output, registered, authorization) = nothing
announcechatgpt(output, ::ChatGPT.Register, authorization) = println(output, "Open this URL if your browser does not open: ", authorization.uri)
waitchatgpt(store, chosen, registered, pending, failure::ChatGPT.Rejected; post, fetcher, now, waitfor) = failure
waitchatgpt(store, chosen, ::ChatGPT.Register, pending, failure::ChatGPT.Rejected; post, fetcher, now, waitfor) = waitchatgpt(store, chosen, pending, waitfor(pending); post, fetcher, now)
waitchatgpt(store, chosen, registered, pending, ::Nothing; post, fetcher, now, waitfor) = waitchatgpt(store, chosen, pending, waitfor(pending); post, fetcher, now)
waitchatgpt(store, chosen, pending, result; post, fetcher, now) = ChatGPT.Rejected(:cancelled)
function waitchatgpt(store, chosen, pending, result::ChatGPT.Code; post, fetcher, now)
    credential = ChatGPT.exchange(pending, result; post, fetcher, now)
    savechatgpt(store, chosen, credential)
end

loginregistration(::ChatGPT.Register) = ChatGPT.Register()
function loginregistration(account::ChatGPT.Credential)
    returning = ChatGPT.Returning(account.client, account.identity.subject; id_token=account.id_token, email=account.identity.email)
    ChatGPT.direct in split(account.scope) ? returning : ChatGPT.Reconsent(returning)
end
loginregistration(account::ChatGPT.Account) = ChatGPT.Returning(account.client, account.identity.subject; email=account.identity.email)
savechatgpt(store, chosen, failure::Union{ChatGPT.Rejected, ChatGPT.OAuthError, Nothing}) = failure
savechatgpt(store, ::ChatGPT.Register, credential::ChatGPT.Credential) = ChatGPT.save(store, credential)
savechatgpt(store, chosen::Union{ChatGPT.Account, ChatGPT.Credential}, credential::ChatGPT.Credential) = replace(store, chosen, credential)

function choosechatgpt(accounts, input, output, ::ResumeChatGPT)
    isempty(accounts) && return ChatGPT.Register()
    length(accounts) == 1 && return only(accounts)
    choosechatgpt(accounts, input, output, ChooseChatGPT())
end
function choosechatgpt(accounts, input, output, ::ChooseChatGPT)
    isempty(accounts) && return ChatGPT.Register()
    println(output, "Choose a ChatGPT account:")
    for (index, account) in enumerate(accounts)
        label = something(account.identity.email, "ChatGPT account")
        println(output, "  ", index, ") ", label, " (", account.client, ")")
    end
    println(output, "  ", length(accounts) + 1, ") Add another account")
    print(output, "> ")
    flush(output)
    eof(input) && return nothing
    accountchoice(accounts, tryparse(Int, strip(readline(input))))
end
accountchoice(accounts, ::Nothing) = nothing
function accountchoice(accounts, choice::Int)
    choice == length(accounts) + 1 && return ChatGPT.Register()
    1 <= choice <= length(accounts) ? accounts[choice] : nothing
end

chatgptsession(store, chosen::ChatGPT.Register, mode) = connectchatgpt(store, chosen)
chatgptsession(store, chosen::Union{ChatGPT.Account, ChatGPT.Credential}, ::ChooseChatGPT) = connectchatgpt(store, chosen)
function chatgptsession(store, chosen::Union{ChatGPT.Account, ChatGPT.Credential}, ::ResumeChatGPT)
    try
        resumechatgpt(store, chosen, ChatGPT.refresh(store, chosen.client, chosen.identity.subject))
    catch
        ChatGPT.Rejected(:transport)
    end
end
resumechatgpt(store, chosen, result) = result
struct ReauthorizeChatGPT end
resumechatgpt(store, chosen, result::ChatGPT.Rejected) = resumerejected(store, chosen, result, get(Dict(:reauthorize => ReauthorizeChatGPT()), result.reason, nothing))
resumerejected(store, chosen, result, reason) = result
resumerejected(store, chosen, result, ::ReauthorizeChatGPT) = connectchatgpt(store, chosen)

function chatgptmodels(session; request=HTTP.get)
    response = request("https://api.openai.com/v1/models", ["Authorization" => "Bearer $(session.access)"]; redirect=false, retry=false, cookies=false, status_exception=false, request_timeout=10, read_idle_timeout=5, max_decompressed_size=1_048_576)
    200 <= response.status < 300 || return ProviderStatus(response.status)
    modeldata(decode(String(response.body)))
end
modeldata(::InvalidResponse) = String[]
function modeldata(data::AbstractDict)
    models = String[]
    foreach(model -> addchatgptmodel!(models, model), get(data, "models", []))
    models
end
addchatgptmodel!(models, model) = nothing
struct ListedChatGPTModel end
addchatgptmodel!(models, model::AbstractDict) = addchatgptmodel!(models, get(Dict("list" => ListedChatGPTModel()), get(model, "visibility", nothing), nothing), get(model, "slug", nothing))
addchatgptmodel!(models, state, slug) = nothing
addchatgptmodel!(models, ::ListedChatGPTModel, slug::AbstractString) = isempty(slug) || push!(models, String(slug))

chatgptmodel(session, requested::AbstractString) = requested
function chatgptmodel(session, ::Nothing)
    try
        choosechatgptmodel(chatgptmodels(session))
    catch
        println(stderr, "Could not discover a ChatGPT model; check your connection or pass --model MODEL_ID.")
        nothing
    end
end
function choosechatgptmodel(models)
    println(stderr, "Could not discover a ChatGPT model; pass --model MODEL_ID.")
    nothing
end
function choosechatgptmodel(models::AbstractVector)
    isempty(models) && return choosechatgptmodel(nothing)
    first(models)
end

acquirechatgpt(requested, mode) = acquirechatgpt(ChatGPT.Store(chatgptdirectory(ENV)), requested, mode)
acquirechatgpt(store, requested, mode) = chatgptfailure()
acquirechatgpt(store::ChatGPT.Store, requested, mode) = acquirechatgpt(store, ChatGPT.accounts(store), requested, mode)
acquirechatgpt(store, accounts, requested, mode) = chatgptfailure()
function acquirechatgpt(store, accounts::AbstractVector, requested, mode)
    confirmchatgpt(store, accounts, requested, mode)
end
function confirmchatgpt(store, accounts, requested, mode::ResumeChatGPT)
    if isempty(accounts)
        print(stderr, "Continue with ChatGPT? [Y/n] ")
        flush(stderr)
        eof(stdin) && return chatgptfailure()
        lowercase(strip(readline(stdin))) in ("", "y", "yes") || return 0
    end
    selectedchatgpt(store, choosechatgpt(accounts, stdin, stderr, mode), requested, mode)
end
confirmchatgpt(store, accounts, requested, mode::ChooseChatGPT) = selectedchatgpt(store, choosechatgpt(accounts, stdin, stderr, mode), requested, mode)
selectedchatgpt(store, ::Nothing, requested, mode) = chatgptfailure()
selectedchatgpt(store, chosen, requested, mode) = acquiredchatgpt(store, chatgptsession(store, chosen, mode), requested)
acquiredchatgpt(store, session, requested) = chatgptfailure()
function acquiredchatgpt(store, session::ChatGPT.Credential, requested)
    ChatGPT.direct in split(session.scope) || return chatgptfailure("ChatGPT plan usage was not authorized. Run jf --login-chatgpt to try again.")
    acquiredchatgpt(store, session, chatgptmodel(session, requested), requested)
end
acquiredchatgpt(store, session, ::Nothing, requested) = 2
function acquiredchatgpt(store, session, model::AbstractString, requested)
    println(stderr, "ChatGPT plan: ", something(session.identity.email, "connected account"), " · model ", model, ". Manage usage at https://chatgpt.com/settings/usage")
    ManagedChatGPT(store, session.client, session.identity.subject, model, chatgptsecrets(session))
end

function chatgptfailure(message="ChatGPT sign-in failed or was cancelled. Run jf --login-chatgpt to try again.")
    println(stderr, message)
    2
end

function launchchatgpt(options, mode::ChatGPTSelection)
    model = acquirechatgpt(options.requested_model, mode)
    Base.ScopedValues.with(tuimode => LiveTerminal.withprovider(options.tui, "chatgpt")) do
        launch(options.output, model, options.packages, options.environments, options.codemode, options.session, options.sessiondir, options.args, options.sessionname, options.baseline, options.rules, options.excluded, provider(options.outputmode, "chatgpt"))
    end
end

function launch(output, model::ManagedChatGPT, packages, environments, codemode, session, sessiondir, args, sessionname, baseline, rules, excluded, mode)
    tools = Tool[Read(pwd()), Write(pwd()), Edit(pwd()), Bash(pwd()), PowerShell(pwd()), Ls(pwd()), Find(pwd()), Grep(pwd())]
    terminal = Terminal(output, stderr, model.secrets, mode)
    registry = plugins(terminal, tools, packages, environments)
    Base.invokelatest(terminal!, terminal, model, registry, codemode, session, sessiondir, args, sessionname, baseline, rules, excluded)
end

struct ChatGPTLogout end
logoutaction(::Nothing) = ChatGPTLogout()
logoutaction(action) = HistoryConflict()
historyinspect(::ChatGPTLogout) = HistoryConflict()
historyabandon(::ChatGPTLogout, reason) = HistoryConflict()

historyaction(::ChatGPTLogout, options) = logoutrequest(options.auth, options)
logoutrequest(auth, options) = invalidlogout()
function logoutrequest(::APIKeyAuth, options)
    isempty(options.args) || return invalidlogout()
    logoutchatgpt(ChatGPT.Store(chatgptdirectory(ENV)))
end
invalidlogout() = chatgptfailure("--logout-chatgpt takes no prompt or login option.")
logoutchatgpt(store) = chatgptfailure()
logoutchatgpt(store::ChatGPT.Store) = logoutchatgpt(store, ChatGPT.accounts(store))
logoutchatgpt(store, accounts) = chatgptfailure()
function logoutchatgpt(store, accounts::AbstractVector)
    isempty(accounts) && return chatgptfailure("No ChatGPT account is connected.")
    logoutchatgpt(store, choosechatgpt(accounts, stdin, stderr, ResumeChatGPT()))
end
logoutchatgpt(store, account::ChatGPT.Account) = chatgptfailure("That ChatGPT account is already signed out.")
logoutchatgpt(store, account::ChatGPT.Credential) = logoutresult(ChatGPT.signout(store, account))
logoutresult(::ChatGPT.Revoked) = (println(stderr, "Signed out of ChatGPT."); 0)
function logoutresult(::ChatGPT.RevocationUnconfirmed)
    println(stderr, "Signed out locally; remote revocation was not confirmed. You can disconnect Julia Forever in ChatGPT settings.")
    0
end
logoutresult(result) = chatgptfailure("ChatGPT sign-out failed; the stored account may have changed.")

LiveTerminal.modelname(provider::ManagedChatGPT) = provider.model

function setmodel!(terminal, agent::Agent{P}, history, model::AbstractString) where {P<:ManagedChatGPT}
    isempty(model) && return agent, history, 0
    lock(agent.lock) do
        previous = agent.provider
        agent.provider = ManagedChatGPT(previous.store, previous.client, previous.subject, String(model), previous.secrets, previous.post, previous.refresh, previous.now, previous.catalog)
    end
    println(terminal.diagnostics, "Model set: ", redact(terminal, model))
    flush(terminal.diagnostics)
    agent, history, 0
end

function LiveTerminal.modeloptions(session, provider::ManagedChatGPT)
    choices = try
        credential = ChatGPT.refresh(provider.store, provider.client, provider.subject; post=provider.refresh, now=provider.now)
        chatgptchoices(provider, credential)
    catch
        String[]
    end
    [(; id=model, name=model) for model in choices]
end
chatgptchoices(provider, failure) = String[]
function chatgptchoices(provider, session::ChatGPT.Credential)
    ChatGPT.direct in split(session.scope) || return String[]
    append!(provider.secrets, filter(secret -> !isempty(secret) && !(secret in provider.secrets), chatgptsecrets(session)))
    chatgptchoices(provider.catalog(session))
end
chatgptchoices(models) = String[]
chatgptchoices(models::AbstractVector) = models
