# History export

`JuliaForever.Logs` exports finite iterables of records as a JSON array or a self-contained HTML page. The order is the iterator order. Each exporter traverses its input once; JSON is written one record at a time, and HTML formats one record at a time.

```julia
using JuliaForever
import JuliaForever.Kernel as K
import JuliaForever.Logs as L

events = K.Event[
    K.Plan(0, "call-1", K.Call("read", (; path="notes.txt"))),
    K.Observe(1, "call-1", K.Return("notes")),
    K.Finish(2),
]

json = L.json(events)
html = L.html(K.Replay(K.State("conversation-1"), events))
open("history.html", "w") do io
    L.html(io, events; title="Conversation")
end
```

The string-returning methods are convenient for small histories; pass an `IO` for larger ones. Records can also come from another iterator or storage backend. The built-in projection covers kernel events, effects, observations, replay results and state, along with the typed conversation's messages, requests, replies, events and state. Custom native types can extend `Logs.record` to return a JSON3-compatible value, or callers can supply `project` to transform every item:

```julia
L.json(records; project = item -> (; revision=item.revision))
```

HTML displays escaped, formatted JSON with no external resources or script. Exporting kernel events or replay results does not run the effects they describe. Exporters do invoke the supplied iterator and projection, so those must be passive if read-only behavior is required. JSON3 must be able to encode the projected data, including nested plugin payloads.

These are views, not a versioned persistence format: there is no decoder, history capture, backend connection, redaction, or durability guarantee. An I/O or encoding failure may leave a partially written stream. The caller owns access control and any sensitive data in the records.

## Export a terminal session

Use `jf --export session.sqlite` to write `session.html`, or `jf --export session.sqlite output.json` for JSON. The command replays the active branch without running tools or requiring a provider. It refuses to overwrite an existing destination, including the source session. The HTML shows the user and assistant messages, tool calls and tool results; its self-contained controls search messages, navigate matches, hide tool results, and expand or collapse tool calls. It renders common Markdown in user and assistant messages, while tool results stay literal. HTTP and HTTPS links are clickable; remote Markdown images are shown as alt text, keeping the export self-contained. The transcript remains readable without JavaScript. The JSON is an array of those messages. System and skill instructions are omitted. PNG and JPEG attachments are retained in JSON and embedded in the HTML. Both files can contain private conversation and tool data.

These exports are Julia Forever views, not Pi's JSONL session format. Pi's HTML includes syntax highlighting, timestamps, and additional display controls. Julia Forever's recorded session history does not contain per-message timestamps.

For the optional browser check, make Playwright available to Node, set `JF_EXPORT_UI_BROWSER` to a Chromium executable, and run `julia --project=. test/session_export.jl`. The check launches an isolated headless profile.
