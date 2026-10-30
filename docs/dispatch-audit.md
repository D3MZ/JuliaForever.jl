# Branch and dispatch audit

The audit covers Julia source in `src/`. `test/branch_scan.jl` uses JuliaSyntax to list source locations for conditionals, short-circuit expressions, loops, exception handlers, comprehension filters, `ifelse`, and calls that may take predicates. The predicate list can include calls whose first argument is a search value rather than a function. The inventory is a static review aid; it cannot see branches produced by arbitrary macro expansion or dynamic code.

At revision `b1a598e`, the inventory contained 1,270 points, including 73 `for` loops, 36 exception handlers, and 31 possible predicate calls. The isolated refactor contained 968 points. Counts include nested expressions, so they are not counts of independent decisions. `test/branch-baseline.txt` ratchets the normalized inventory, so added, removed, or changed entries require review and an explicit baseline update. It does not detect changes confined to branch bodies or moves of identical entries.

The dispatch check is a separate heuristic. Applied to both versions with the expanded rules, it reports 691 candidates before and 395 in the isolated refactor: 306 previous occurrences were removed and ten appeared under new expressions. Those ten comprise compatibility accessors and constructors, moved history-rejection and wire-schema checks, and a moved worker-completion check. The previous, narrower check had recorded 542 candidates. The exact multiset is in `test/dispatch-baseline.txt`; tests fail if it grows or changes without updating the baseline.

The remaining candidates are not all equivalent. Input validation, file-edit safety, numerical and collection checks, and compatibility accessors still require decisions at their boundaries. Executor-backed agent loops retain type, fault, and cancellation checks; the recorded loop still checks completion status. Some provider and worker protocol decoders still branch on tags; these can be refactored further. The baseline records these candidates; it is not an assertion that every one is an acceptable exception.

The review retained the edit checks for missing, ambiguous, and overlapping targets. Exception handlers were reviewed as protocol or operating-system failure boundaries, cleanup, and recovery paths. JuliaSyntax supplies source-aware inventory; JET and Aqua complement it with inference and package-quality tests, but they do not determine whether a branch should use dispatch.

Run the inventory in an environment containing JuliaSyntax with `julia test/branch_scan.jl`. The package test target installs JuliaSyntax and runs the branch and dispatch tests with `julia --project -e 'using Pkg; Pkg.test()'`.

The merge with the session, image, provider, extension, and context work changes the incoming refactor's inventories: 140 branch entries are added and 38 removed (net 102), while seven dispatch candidates are added and 21 removed (net 14 fewer). The added branch entries cover CLI provider/model and plugin selection, terminal input and history selection, session-tree ancestry and durable validation, image format and size checks, MCP image handling, provider HTTP statuses, extension hooks, and context estimates. They are retained to preserve those features; the branch inventory is not a claim that every branch is irreducible. The seven additions to the dispatch inventory, separate from the pre-existing candidates, are:

- `agent.jl: result.finish == "length"`: the model provider's finish reason.
- `conversation.jl: name in (:text, :iserror, :image)`: compatibility properties of `ToolReply`.
- `extensions.jl: hook.event == event.type`: plugin subscription names.
- `terminal.jl: ok`: the Julia REPL prompt's success result.
- `terminal.jl: suspend`: the Julia REPL prompt's suspension result.
- `tools.jl: kind == codeunits("IDAT")`: a PNG image data chunk identifier.
- `tools.jl: kind == codeunits("acTL")`: a PNG animation chunk identifier.

MCP content and chat message roles use handlers instead of added tag checks. The separate terminal Channel queue is not included in this merge.

The code-mode store deletion merge changes one existing loop inventory entry: the worker now exposes the `forget!` helper alongside `store` and `load`. It adds no new branch point.

The provider-error integration removes the `isnothing(finish)` dispatch candidate; no new dispatch candidate is added. Its branch inventory replaces that finish-reason check with a numeric 400–599 range check at the provider error boundary. Unrecognized provider details are mapped to a fixed error category, and raw provider callback events remain unfiltered.

The session safety work adds nine branch inventory entries and removes five, taking the inventory from 1,178 to 1,182. The added decisions validate stored batch shape, finite numeric values, nonempty batches, and revision consistency; preserve ownership when the selected history is already active; and recognize JSON parsing failures at the SQLite boundary. Typed decoding replaces three tag comparisons, a typed revision check replaces the previous comparison, and a fold replaces the SQLite row loop. There are no new dispatch candidates; the provider integrations reduce the dispatch inventory from 379 to 378.
