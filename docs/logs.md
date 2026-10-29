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
