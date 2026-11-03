# JuliaForever

A **Julia-native, interactive setup mock** for a small agent core extended by skills. It is a design prototype for feedback, not an agent harness or installer.

## Try the mock

Requirements: Julia and a Unicode-capable terminal such as Ghostty. The checked-in environment was created with Julia 1.13; Tachikoma itself supports Julia 1.10 and later.

```sh
cd /Users/z/Coding/JuliaForever  # or your checkout
julia --project=. -e 'using Pkg; Pkg.instantiate()'
julia --project=. run.jl
```

The first launch may take a little while to compile. The mock requires at least 76 columns × 25 rows.

### Controls

- Use **↑/↓** and **Enter** to choose an option; clickable rows and buttons work with the mouse too.
- Use **Tab** for the next page and **Shift+Tab** for the previous page. Select a mock sign-in method first; **Explore the demo** skips straight through.
- On **Features**, Enter/Space toggles a recipe; `/` edits the search; Enter finishes searching. Highlight Compaction and press `c` to cycle its style. Builds progress independently while you navigate, and toggling one off simulates cancellation/removal.
- On **Profile**, Enter selects an option, `e` edits a named profile, and `s` simulates saving. Named/custom profile selection starts in edit mode; Enter finishes editing. After saving, use Tab or **Open prompt** to preview the minimal prompt.
- The prompt accepts text and displays a canned reply without contacting a model. On text fields, **Ctrl+U** clears the current text. **q** quits outside a text field; **Ctrl+C** quits anywhere.

## What is and is not real

Only the interface and its in-memory state are real. Do **not** enter real API keys: sample keys are masked, never sent, and cleared from the mock state after submission. No sign-in, API calls, OAuth, agents, parallel work, generated code, filesystem deletion, or persistent profile save is implemented. Timed indicators only simulate builds; the prompt response is canned; quitting resets the demo.

The proposed product architecture, future project layout, security boundaries, lifecycle, and decisions to settle together are in [docs/architecture.md](docs/architecture.md). No external harness code has been copied.

The TUI is built with [Tachikoma.jl](https://github.com/kahliburke/Tachikoma.jl), a Julia-native terminal UI framework.
