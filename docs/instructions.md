# Project instructions

`JuliaForever.Instructions.load(cwd=pwd(); agentdir=nothing)` reads project instructions without Pi or Node. It returns a vector of named tuples with `path` and `content`. The optional `agentdir` specifies a global instructions directory; it defaults to `nothing`, so callers choose their own configuration location. `cwd` and `agentdir` are resolved to absolute paths, with `~` expanded. To disable discovery when using the API, omit the call. `JuliaForever.Instructions.render(files)` formats them as a project-context section, or returns `nothing` for an empty vector.

```julia
using JuliaForever

files = JuliaForever.Instructions.load(pwd(); agentdir=joinpath(homedir(), ".julia", "my-agent"))
for file in files
    println(file.path, ":\n", file.content)
end
```

One regular file is selected per directory, in this order: `AGENTS.override.md`, `AGENTS.md`, `AGENTS.MD`, `CLAUDE.md`, `CLAUDE.MD`. Directories and dangling links at candidate paths are skipped; symlinks to regular files are read. The selected global file comes first, followed by files from the filesystem root down to `cwd`, including directories above a Git repository. If the same lexical path was already loaded as the global file, it appears only once. Each selected file has a leading UTF-8 BOM removed; all other content, including an empty file, is preserved. Paths identify the selected lexical location, even when the file is a symlink.

The `jf` command reads working-directory instructions once at startup and places the rendered section in a system message sent to the provider. Set `JF_INSTRUCTIONS_DIR` to a directory to load a global file first; the command does not read Pi configuration by default. The CLI has no disable flag, and changes during a running session are not reloaded. File contents and paths are included as written, so use the command in a workspace whose instructions you intend to send to your provider.

For a linked worktree nested inside its main checkout, a context file at the worktree root shadows the main checkout's selected context file only when their selected filenames match. The main checkout's other ancestors still apply. A bare repository's containing directory and an unrelated worktree do not receive this shadowing. This check reads Git metadata directly and does not invoke Git.

The optional differential tests compare these selected behaviors with Pi revision `e7a0df27c09d11bf4161d3605246cbf57a129cb2`. They compare discovery and project-context formatting across global/ancestor order and deduplication, candidate precedence, uppercase variants, directories as candidates, BOM and empty content, relative paths, symlinks, and nested and bare worktree layouts. A synthetic local HTTP test exercises the `jf` subprocess with chat completions and Responses. On the tested case-insensitive filesystem, uppercase suffixes resolve through the earlier lowercase candidate. This is a subset, not complete Pi compatibility. Julia errors from reading selected files or Git metadata propagate, while Pi reports some read failures and continues. Invalid UTF-8, file URLs, Windows path conversions, and full Pi resource-loader settings and overrides are outside this API. Tests for this change have run on macOS only; Linux and Windows remain unverified. Direct `Agent` constructors do not discover instructions automatically.
