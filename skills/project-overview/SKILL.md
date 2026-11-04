---
name: project-overview
description: Build a read-only Julia CLI for local project overviews and extension counts. Use when creating such a tool.
---

# Build the CLI

Return one complete Julia source file as plain text, with no fences or commentary. Use only Julia standard libraries.

Implement `julia project_overview.jl [DIRECTORY]`; default to the current directory. `--help` must print usage and exit 0 without scanning. Reject unknown options, extra arguments, nonexistent or non-directory paths, excluded roots, and symlink roots: print a clear error to stderr and exit nonzero.

Walk recursively with `walkdir(...; follow_symlinks=false)`; prune symlinks and directories named `.git`, `.pi`, `node_modules`, `build`, `dist`, `target`, `vendor`, `deps`, `.venv`, `venv`, `.cache`, `.next`, or `__pycache__`. Count regular files only. On traversal errors, identify the path and fail rather than report incomplete totals.

Print the root, present top-level project markers (`Project.toml`, `README.md`, `package.json`, `Cargo.toml`, `pyproject.toml`), visited directory count excluding the root, file count, and every extension count. Use lowercase `splitext` extensions, grouping extensionless files as `(none)`; sort output deterministically. Never modify files, run commands, or access the network.
