# Native Julia extensions

`JuliaForever.Extensions` collects tools and synchronous lifecycle observers from Julia values or packages. The host chooses and loads trusted Julia code with the usual Julia package mechanisms; it runs with the host's permissions.

```julia
using JuliaForever
const E = JuliaForever.Extensions

struct Greet <: JuliaForever.Tool end
JuliaForever.name(::Greet) = "greet"
JuliaForever.description(::Greet) = "Greet a person"
JuliaForever.schema(::Greet) = Dict("type" => "object", "properties" => Dict("name" => Dict("type" => "string")), "required" => ["name"])
JuliaForever.execute(::Greet, args) = ToolResult("Hello, $(args.name)!")

events = Symbol[]
registry = E.Registry()
E.register!(registry, :files, E.Plugin(; tools=(Read(pwd()),)))
E.register!(registry, :greeting, E.Plugin(; tools=(Greet(),), hooks=(:agent_start => (event -> push!(events, event.type)),)))

snapshot = E.snapshot(registry)
agent = Agent(my_provider, snapshot)
listener = E.listen(snapshot)
answer = respond!(agent, "Greet Ada"; on_agent_event=listener)
failures = E.failures(listener)
```

A package can instead define `E.tools(plugin)` and `E.hooks(plugin)` for its own plugin type; either defaults to an empty tuple. Tools are existing `JuliaForever.Tool` values and must have stable, unique `name` values, `description`, `schema`, and `execute` methods. Hooks are ordered `event => callable` pairs. [GreetingPlugin](../test/fixtures/GreetingPlugin) is a small independently loadable package fixture. Package authors may hold resources in the plugin and are responsible for their lifetimes.

## Terminal activation

An explicitly selected native Julia package supplies a zero-argument `plugin()` function returning any value accepted by `Extensions.register!`. For example, a package with the tool above can define `plugin() = E.Plugin(; tools=(Greet(),))`. Install or develop the package and its dependencies in a Julia environment beforehand, then run:

```sh
jf --plugin-env /path/to/environment --plugin MyPlugin 'Greet Ada'
```

`--plugin` and `--plugin-env` may be repeated. The first existing load-path entry stays first; the supplied Julia project or package-directory environments follow in the order given, then the remaining existing entries. A package in the first entry takes precedence over one with the same name in a supplied environment. If the package is already on Julia's load path, omit `--plugin-env`. Julia resolves the selected package and its dependencies normally; the CLI does not install packages or search for plugins automatically. The installed `jf` shim pins its own load path, so `--plugin-env` supplies an explicit additional environment there. Relative paths resolve from the working directory and `~` is expanded. The resolved load path is also passed to child Julia processes for package precompilation.

Packages load and register in flag order with their package names as plugin IDs. Tool names must also be distinct from the built-in tools and, when enabled, `codemode`. Code mode can call the selected plugin tools. A loading, factory, contribution, or collision failure is reported on stderr and exits with status 2 before a provider request. Plugin code executes with the user's permissions, including at load and initialization; do not select untrusted code. Earlier plugins may already have performed side effects if a later plugin fails. Inspection and abandonment commands do not load plugins.

The CLI takes one registry snapshot for the process and creates a fresh listener for each turn. Hook failures are reported on stderr after the turn with the plugin name, event, and exception; remaining hooks run and a completed response still succeeds. The configured provider key is redacted from these diagnostics, but other secrets may appear; plugin code and Julia's package loader can also write output independently. A resumed history uses the plugins selected for that invocation; plugin configuration and state are not recorded. Resources are not automatically closed or reloaded.

`register!` evaluates the plugin's tool and hook iterables, then atomically checks and adds them. It returns `true`, `Rejected(:duplicate_plugin, name)` for an existing ID, or `Rejected(:duplicate_tool, name)` for a repeated name within the candidate or an existing plugin. A failed registration adds nothing. An exception while obtaining contributions propagates; any side effects of that plugin code are its responsibility. `remove!(registry, id)` returns whether the ID existed and removes all its contributions from future snapshots. Registering it again appends it after the remaining plugins. Concurrent operations are serialized; their order is lock-acquisition order. Tool order in `E.tools(snapshot)` follows registration and contribution order; `Agent` stores tools in its existing `Dict`, so model declaration order is not promised.

`snapshot` fixes the registry membership and ordering for a new `Agent` and listener. `Agent(provider, snapshot, messages; history=...)` also accepts an existing initial transcript. Later registration or removal does not change existing snapshots, agents, or listeners. The tool and hook values themselves are shared, not cloned; removal does not close resources or invalidate those values. Rebuild both the agent and listener from a new snapshot to adopt changes. Directly mutating `agent.tools` is outside the registry contract.

Pass `E.listen(snapshot)` as `on_agent_event` to receive the agent's existing notifications, including `agent_start`, `turn_start`, `message_start`, `message_update`, `message_end`, `tool_execution_start`, `tool_execution_end`, `turn_end`, and `agent_end` when the selected driver emits them. A listener runs handlers in plugin registration order, then hook order, synchronously and serially. Each handler receives a separate deep copy of the event; return values are ignored. Thrown exceptions, including `InterruptException`, are captured in `E.failures(listener)` with plugin ID, event and exception, and later hooks run. Failures accumulate for that listener; create another listener for a fresh list. Hooks can still perform arbitrary side effects through their own captured state and can delay the agent.

For parallel local tool batches, before-tool hooks run in call order during preflight, before executable calls start. Result hooks and completion notifications follow completion order; tool messages remain in call order.

`E.listen(snapshot; on_event=callback)` invokes the existing host callback after the hooks, with the original event. Callback exceptions propagate according to `Agent`'s existing behavior; they are not hook failures. Recorded agents emit notifications during live execution, not when opening an existing history. The executor-backed path installs its own tools on its worker; creating an agent from a snapshot alone does not install plugin code or resources there.

## Reference and limits

The selected reference is Pi revision `e7a0df27c09d11bf4161d3605246cbf57a129cb2`, `packages/coding-agent/docs/extensions.md`. Pi also orders notifications by extension and handler registration, reports a failed handler and continues, and exposes custom tool metadata and results. `test/extensions_differential.jl` compares these selected outcomes against Pi when `PI_SOURCE` is set. Pi silently permits built-in tool overrides; this registry deliberately rejects all name collisions. Pi's event payloads and lifecycle boundaries differ.

There is no automatic CLI discovery, package installation, reload command, automatic cleanup, session lifecycle, plugin-defined commands or flags, renderers, provider registration, or model/input/context hooks. The observer hooks cannot block or transform inputs, tools, or results, request continuation, or persist extension state. There is no sandbox, durable replay of plugin side effects, or automatic distribution to executor workers. The comparison covers selected notification and custom-tool behavior, not full Pi parity.
