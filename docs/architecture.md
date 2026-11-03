# JuliaForever: proposed architecture

**Status: proposal for discussion, represented by an interactive mock.** Nothing below describes a built agent, sign-in integration, installer, recipe runner, or persistent profile store. The goal is to agree on the boundaries before implementing them.

## Product shape

JuliaForever is a small Julia-native composition layer, not a catalog of built-in integrations. After installation, the user connects a model, chooses features from searchable recipes, and saves the combination as a profile. Each recipe supplies instructions and a contract for an agent to build a feature for that user's environment. The app can evolve as users choose capabilities; microphone, scheduling, GitHub, browser, compaction, web UI, and even the model selector are **skills/features**, not permanent core modules.

```text
User ↔ Julia TUI ↔ setup state / profiles
                       │
                       ├── model & authentication adapter
                       ├── recipe catalog / skill instructions
                       └── build coordinator ── agent adapter(s)
                                │                     │
                         isolated workspaces     narrowly scoped tools
                                └── review / integrate / ownership ledger
```

The UI observes state and issues commands; it does not own agent processes. Work remains visible across pages and continues independently of the currently displayed page. The mock uses timers and memory instead of these components.

### Interface principles

Keep each screen focused on the task: clear hierarchy, concise labels, standard keyboard and mouse interactions, readable contrast, and immediate feedback. Avoid decorative or repetitive copy. Show operational and safety information when it matters; never imply that a simulated action is real.

## Interface principles

- Keep each screen focused on one task; use concise, concrete labels instead of promotional or filler copy.
- Show the current selection, status, and next action clearly. Reveal details only when useful, and make keyboard and mouse interactions equivalent.
- Keep controls consistent and preserve readable contrast and usable layouts at smaller terminal sizes.
- Distinguish simulated states from real operations; show errors and safety-relevant information where decisions are made.
- After setup, provide a minimal prompt rather than a dashboard. The mock prompt returns a canned preview and never contacts a model.

## The smallest useful core

1. **App shell and state:** TUI, navigation, configuration, and a small event stream that reports build progress and errors.
2. **Model/auth boundary:** connect to one usable model through a provider adapter, supply an endpoint/protocol when needed, and manage credential references. No provider integration should depend on a particular feature recipe.
3. **Agent execution boundary:** start an agent with a goal, selected skill instructions, profile context, tools, workspace, and cancellation handle; stream progress and a result. This can initially wrap an existing harness instead of recreating a model loop.
4. **Recipe discovery/composition:** find recipe metadata and load the selected skill instructions; resolve declared dependencies, options, and conflicts.
5. **Build coordinator:** run independent selections concurrently, isolate changes, collect results, serialize integration, and track cancellation/ownership.
6. **Minimal tools:** scoped file read/write, process execution for building the user's project, and the mechanism to inspect results. Model access and agent spawning belong to the runtime boundary. Anything else—network, browser, microphone, scheduling, GitHub, or a web server—is a selected capability or an explicitly authorized adapter, not assumed core functionality.
7. **Profiles and local state:** remember the chosen connection by reference, recipes/options, and build states, without embedding secrets.

These are logical responsibilities, not a commitment to seven packages. Start as one small Julia project; split modules/packages only when the boundaries earn it. Shell execution and file mutation are powerful even when the API is small: scope them to the chosen workspace and give the user a clear approval policy. A working-directory restriction alone is not a sandbox.

## Setup flow

### 1. Connect

- **API key:** inspect known patterns locally as *hints*, never as proof of identity. Let the user confirm a suggested provider. If unknown or ambiguous, ask for provider, base URL if necessary, and a compatible response/API protocol. Verify only with the user's permission; report real verification errors honestly.
- **Endpoint:** enter a URL, choose its wire protocol and any required credentials, then optionally verify. A custom URL is a different concern from the API protocol it implements.
- **Subscription:** offer ChatGPT, Anthropic, Google, and others only where the chosen adapter has a supported and authorized sign-in path. Account subscriptions, API billing, OAuth access, and use from third-party tools are not interchangeable; availability depends on the provider, actual credentials, terms, and harness support. Do not promise that an existing subscription grants API access.
- Keep raw credentials out of prompts, skill files, profiles, logs, screenshots, and agent-visible tool output. Use an OS credential store where available and keep only references in configuration. Never identify providers by transmitting a key to multiple services.

The mock accepts **fake** values, demonstrates the branch for unknown keys, and never verifies or stores a real connection. The demo-session option is for exploring the prototype, not a production authentication design.

### 2. Build features

- Search filters a local catalog; highlighting a recipe shows its purpose and options. Selecting it starts a build immediately. Independent recipes run concurrently, with a visible queued/running/ready/failed state and actionable details. A recipe may expose sub-options, such as periodic checks for scheduling or Pi/DeepSeek-style compaction.
- Deselecting requests cancellation **immediately**, stops the agent and its child processes, and removes its generated work under the ownership rules below. UI should distinguish canceling, removed, and cleanup-needs-attention rather than imply deletion succeeded before it did.
- Navigation is non-blocking: users can move to profiles and see builds continue. A selected recipe can be reselected after cancellation; a stale result from an older attempt must never be integrated.
- A future custom-recipe flow should collect the user's description and ask for any necessary permissions. The mock lists a custom feature but does not collect or build it.

### 3. Save to profile

- Offer **Default**, **Agent named**, and **Custom**. A named profile can be used to start a sub-agent with a specific configuration.
- Save a versioned snapshot of recipe IDs/options, the connection reference, and the selected profile name. Save does not wait for builds; the profile records pending work and its eventual results. The UI should show errors or unfinished work, not call a pending build ready.
- Resume/reconcile interrupted work on restart or explicitly mark it interrupted; do not silently rerun agents. A profile can be edited later without mutating a running agent's already-resolved configuration.
- The mock's save is session-only, not a persistent write. After saving, a minimal prompt preview demonstrates the intended post-setup surface; it does not run an agent.

## Recipes and skills

A recipe is the selectable contract; a skill is the instructions the agent follows. One recipe may compose several skills, but neither should need a custom core module. A minimal future recipe would declare:

```text
id, version, title, description, searchable tags
options and defaults                  # e.g. compaction style
skill entry points                   # e.g. SKILL.md paths
required capabilities / permissions  # e.g. network, microphone
recipe dependencies and conflicts
expected outputs and completion evidence
cleanup / ownership expectations
```

Keep metadata machine-readable and skills human-readable. Let the agent determine implementation details rather than encoding every feature in the core. Treat skill content and external material as untrusted instructions: they must not silently grant tools, expand filesystem scope, or override the user's policies. Version recipes and record the exact version/options used so a profile can be reconstructed or updated deliberately.

**Discovery and propagation:** discover and index skill metadata at startup, but load detailed instructions only when relevant. A user-selected recipe is an explicit skill binding, not merely a hint that an agent may overlook. When starting a build or sub-agent, resolve and pass the applicable skill versions, project rules, and permissions explicitly; do not assume that a child process or isolated worktree inherits its parent's context. Keep unconditional project rules separate from detailed, task-specific skills. Surface missing or conflicting instructions instead of silently proceeding. This is a proposed JuliaForever contract, not an implemented feature.

## Concurrent builds and safe removal

A proposed lifecycle per selection is `selected → queued → running → integrating → ready`, with `failed`, `canceling`, `canceled`, and `cleanup blocked` as explicit outcomes. Real progress should reflect actual events, not invented percentages. Distinct build attempt IDs prevent an old completion event from reviving a deselected recipe.

1. Snapshot a common base and run each agent in its own staging workspace or worktree, with the recipe's allowed tools and an attempt ID.
2. Agents propose changes and completion evidence; they do not concurrently write the shared project. A coordinator integrates compatible results serially, detects overlapping edits, and surfaces conflicts for resolution.
3. Record an ownership manifest for each integrated result: created paths, exact changes to shared files, version/base identifiers, and any shared dependencies. Generated files can be removed only when unchanged and owned exclusively by that recipe. Shared files/dependencies require a precise reversible patch or reference count.
4. On deselection, immediately mark the attempt canceled, revoke further integration, terminate its processes, discard unintegrated staging, and remove safely owned artifacts. If a user or another recipe changed a file, preserve it and report a cleanup conflict; never blindly delete unrelated or user-modified data.
5. On restart, reconcile the journal, workspace, and ownership manifest before offering to resume or clean up. External effects (accounts, remote repositories, scheduled jobs, deployed services) require an explicit recipe-specific cleanup plan and may require additional consent.

This preserves the intended one-click removal experience without promising that arbitrary modifications, user data, or remote side effects can always be safely erased instantly.

## Future project layout

Illustrative only; don't create empty scaffolding before it is needed.

```text
JuliaForever/
  src/
    app/                  # TUI and setup state
    core/                 # contracts, event/state coordination
    providers/            # model/auth adapters and credential references
    agents/               # harness adapter, process lifecycle, tool permissions
    recipes/              # catalog, dependency/option resolution
    builds/               # workspaces, integration, journal, ownership/cleanup
    profiles/             # profile snapshots and persistence
  skills/
    microphone/SKILL.md
    scheduling/SKILL.md
    compaction/SKILL.md
    ...                    # selected capabilities, not core implementations
  recipes/                 # discoverable recipe metadata and skill composition
  docs/
  Project.toml
```

User-specific profiles, generated projects, build journals, and secrets live outside the installed package. The precise file formats and storage location are implementation decisions, not part of this mock.

## Reuse before rebuilding

Evaluate an actively maintained Julia option first for provider clients and agent execution; candidates worth investigating include [Krill.jl](https://github.com/whanyu1212/Krill.jl) (Julia-native agent runtime, currently advertises limited provider support) and [PromptingTools.jl](https://github.com/svilupp/PromptingTools.jl) (Julia LLM tooling, with experimental agent utilities). Also compare [Pi](https://github.com/badlogic/pi-mono) and [OpenCode](https://github.com/anomalyco/opencode) as possible harness/adaptor or implementation references. These are candidates, **not** endorsements or verified drop-in solutions; Kaimon/Julia REPL tools are complementary tooling rather than necessarily a full harness.

Before copying or integrating anything, inspect recent maintenance, licenses and attribution, auth flows and provider terms, supported models, cancellation, tool permissions, portability, and the cost of embedding it. Prefer a clean adapter or a small compatible library over copying a large harness. No harness code has been copied in this prototype.

## Questions to settle with feedback

1. Should the first real runtime wrap an existing harness as a subprocess, or should Julia own the model/tool loop from day one?
2. What approval and isolation level should apply to shell commands, network access, package installation, and generated code?
3. Should a completed feature be integrated automatically or offered for review first? How should conflicting parallel edits be resolved?
4. Which subscription/provider paths are both technically supported and permitted for this specific app?
5. Where should profiles and generated projects live, and should profiles be shareable without credentials?
6. How should custom feature descriptions and recipe options appear in the selector?
