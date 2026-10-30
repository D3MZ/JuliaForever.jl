struct HistoryExport
    source::String
end
exportaction(::Nothing, path) = HistoryExport(path)
exportaction(action, path) = HistoryConflict()
historyinspect(::HistoryExport) = HistoryConflict()
historyabandon(::HistoryExport, reason) = HistoryConflict()

historyaction(action::HistoryExport, options) = exportrequest(options.auth, action, options)
exportrequest(auth, action, options) = invalidexport()
function exportrequest(::APIKeyAuth, action, options)
    length(options.args) <= 1 || return invalidexport()
    destination = isempty(options.args) ? splitext(action.source)[1] * ".html" : only(options.args)
    exporthistory(action.source, destination)
end
function invalidexport()
    println(stderr, "--export requires a session path and optional .html or .json destination.")
    2
end

abstract type ExportFormat end
struct ExportHTML <: ExportFormat end
struct ExportJSON <: ExportFormat end
const exportformats = Dict(".html" => ExportHTML(), ".json" => ExportJSON())
function exporthistory(source, destination)
    format = get(exportformats, lowercase(splitext(destination)[2]), nothing)
    exporthistory(source, destination, format)
end
exporthistory(source, destination, ::Nothing) = invalidexport()
function exporthistory(source, destination, format::ExportFormat)
    (ispath(destination) || islink(destination)) && return exportfailure("Destination already exists.")
    result = attempt(() -> open(History.SQLite, source; create=false))
    exportopened(result, destination, format)
end
exportopened(failure::ToolFailure, destination, format) = exportfailure("Could not open session.")
exportopened(rejected::History.Rejected, destination, format) = exportfailure("Could not open session: $(rejected.reason).")
function exportopened(store::History.SQLite, destination, format)
    try
        exported(destination, format, History.Tree(store))
    finally
        close(store)
    end
end
exported(destination, format, rejected::History.Rejected) = exportfailure("Invalid session: $(rejected.reason).")
exported(destination, format, tree::History.Tree) = exported(destination, format, History.snapshot(tree))
function exported(destination, format, snapshot::History.Snapshot)
    batches = snapshot.batches
    isempty(batches) && return exportfailure("Session is empty.")
    all(batch -> length(batch) == 1, batches) || return exportfailure("Invalid session.")
    initial = History.decode_initial(only(first(batches)))
    exported(destination, format, replay(initial, batches[2:end], Dict{String, Tool}()))
end
function exported(destination, format, replayed::Tuple)
    state = first(replayed)
    messages = Dict{String, Any}[]
    foreach(message -> exportmessage!(messages, message), state.messages)
    result = attempt(() -> writeexport(destination, format, messages))
    exported(destination, result)
end
exportmessage!(messages, message::Conversation.Message) = nothing
exportmessage!(messages, message::Union{Conversation.User, Conversation.ImageUser, Conversation.Assistant, Conversation.ToolMessage}) = push!(messages, convert(Dict{String, Any}, message))
function writeexport(destination::AbstractString, format::ExportFormat, messages)
    io = Base.Filesystem.open(destination, Base.JL_O_WRONLY | Base.JL_O_CREAT | Base.JL_O_EXCL, 0o600)
    try
        writeexport(io, format, messages)
    finally
        close(io)
    end
    nothing
end
writeexport(io::IO, ::ExportHTML, messages) = Logs.conversationhtml(io, messages)
writeexport(io::IO, ::ExportJSON, messages) = Logs.json(io, messages; project=identity)
exported(destination, ::Nothing) = (println("Exported to: ", destination); 0)
exported(destination, failure::ToolFailure) = exportfailure("Could not write export.")
function exportfailure(message)
    println(stderr, message)
    2
end
