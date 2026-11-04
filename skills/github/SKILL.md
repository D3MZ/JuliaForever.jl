---
name: github
description: Build a read-only GitHub helper CLI using the existing gh executable.
---

Produce one complete Julia source file as plain text, with no Markdown fences or commentary. Use only Julia standard libraries.

Implement `julia main.jl repo [OWNER/REPO]` and `julia main.jl issues [OWNER/REPO]`. `--help`, alone or after a subcommand, prints useful usage and exits 0 before checking gh, authentication, or network. Reject unknown commands/options, wrong argument counts, and malformed repositories on stderr with a nonzero exit. Validate `OWNER/REPO` against the whole-string pattern `[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+`. Without a repository, let gh infer it from the current directory.

Find gh on PATH; report its absence on stderr and exit nonzero. Run only `gh repo view [OWNER/REPO]` or `gh issue list [--repo OWNER/REPO]` (open issues), using process argument vectors (`Cmd`), never a shell. Set `GH_PROMPT_DISABLED=1`. Show gh stdout and stderr; catch launch failures and report unsuccessful exits, including authentication and network errors, on stderr with nonzero status. Never mutate data or execute user-supplied commands.
