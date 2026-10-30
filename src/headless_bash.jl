function respond!(session, request::Request{<:BashCommand})
    lock(session.lock) do
        token = session.bashcancel
        task = Threads.@spawn begin
            try
                chunks = J.ShellChunks(delta -> bashupdate!(session, request.id, delta))
                try
                    result = J.attempt(() -> J.execute(J.Bash(pwd()), (; command=request.command.command); cancel=token, on_update=chunks))
                    respond!(session, request, bashresult!(session, request.command, chunks.report, result, token))
                finally
                    J.closechunks!(chunks)
                end
            finally
                lock(() -> delete!(session.bashtasks, current_task()), session.lock)
            end
        end
        push!(session.bashtasks, task)
    end
    nothing
end

function bashupdate!(session, id, delta)
    event = Dict{String, Any}("type" => "bash_execution_update", "delta" => delta)
    write!(session, withid!(event, id))
end

bashresult!(session, command, ::Nothing, failure::J.ToolFailure, token) = lock(() -> bashnotstarted!(session, command, failure, token.runs), token.lock)
bashnotstarted!(session, command, failure, ::Set{J.ShellRun}) = Failure(J.redact(session.terminal, failure.text))
bashnotstarted!(session, command, failure, ::Nothing) = bashresult!(session, command, J.ShellReport("", nothing, false, J.ShellCancelled(), nothing), failure, nothing)
function bashresult!(session, command, report::J.ShellReport, result, token)
    bashresult!(session, command, report, report.outcome)
end
bashresult!(session, command, report, ::J.ShellStopFailed) = Failure("Could not stop shell process group")
function bashresult!(session, command, report, outcome::J.ShellOutcome)
    message = J.Conversation.BashMessage(command.command, report.output, report.exitcode, bashcancelled(report.outcome), report.truncated, report.file, round(Int, 1000 * time()), command.context)
    saved = lock(() -> queuebash!(session, message, session.task), session.lock)
    bashreply(saved, message)
end

bashcancelled(::J.ShellOutcome) = false
bashcancelled(::J.ShellCancelled) = true
queuebash!(session, message, ::Task) = (push!(session.pendingbash, message); nothing)
queuebash!(session, message, ::Nothing) = savebash!(session, message)
function savebash!(session, message)
    saved = J.recordbash!(session.agent, message)
    savebash!(session, message, saved)
end
savebash!(session, message, rejected::J.History.Rejected) = rejected
function savebash!(session, message, ::Nothing)
    value = convert(Dict{String, Any}, message)
    push!(session.messages, value)
    entrysaved!(session, recordentry!(session, J.Conversation.MessageEntry(value)))
    nothing
end

bashreply(rejected::J.History.Rejected, message) = Failure(string(rejected.reason))
function bashreply(::Nothing, message)
    data = convert(Dict{String, Any}, message)
    for key in ("role", "command", "timestamp", "excludeFromContext")
        delete!(data, key)
    end
    Success((; data))
end

function flushbash!(session)
    for message in session.pendingbash
        saved = savebash!(session, message)
        bashsaved!(session, saved)
    end
    empty!(session.pendingbash)
    nothing
end
bashsaved!(session, ::Nothing) = nothing
bashsaved!(session, failure::J.History.Rejected) = println(session.terminal.diagnostics, "Could not save bash result: ", failure.reason)

function handle!(session, ::AbortBash)
    token = lock(session.lock) do
        current = session.bashcancel
        session.bashcancel = J.ShellCancellation()
        current
    end
    J.cancel!(token)
    Success()
end

function finishbash!(session)
    handle!(session, AbortBash())
    tasks = lock(() -> collect(session.bashtasks), session.lock)
    foreach(wait, tasks)
    nothing
end
