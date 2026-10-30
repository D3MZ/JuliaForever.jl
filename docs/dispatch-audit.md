# Branch and dispatch audit

The audit covers Julia source in `src/`. `test/branch_scan.jl` uses JuliaSyntax to list source locations for conditionals, short-circuit expressions, loops, exception handlers, comprehension filters, `ifelse`, and calls that may take predicates. The predicate list can include calls whose first argument is a search value rather than a function. The inventory is a static review aid; it cannot see branches produced by arbitrary macro expansion or dynamic code.

At revision `b1a598e`, the inventory contained 1,270 points, including 73 `for` loops, 36 exception handlers, and 31 possible predicate calls. The current tree has 985 points and also contains provider adapters and history-tree code added since that revision. Counts include nested expressions, so they are not counts of independent decisions. `test/branch-baseline.txt` ratchets the normalized inventory, so added, removed, or changed entries require review and an explicit baseline update. It does not detect changes confined to branch bodies or moves of identical entries.

The dispatch check is a separate heuristic. Applied to both versions with the expanded rules, it reports 707 candidates at `b1a598e` and 324 now: 396 previous occurrences were removed and 13 appeared under new expressions. The current tree includes the added modules noted above. The previous, narrower check had recorded 542 candidates. The exact multiset is in `test/dispatch-baseline.txt`; tests fail if it grows or changes without updating the baseline.

The string-status rule found 12 previously unrecognized checks in the provider-merge checkout. Eleven were removed through typed decoding; the remaining OAuth query-key comparison is not a behavioral status. The check also finds status-field and selection comparisons when they return or assign a Boolean instead of controlling a branch directly.

The remaining candidates are not all equivalent. Input validation, file-edit safety, numerical and collection checks, and compatibility accessors still require decisions at their boundaries. The agent loops still check cancellation, completion, and configuration status at a few points. Some provider and worker protocol decoders still branch on tags; these can be refactored further. The baseline records these candidates; it is not an assertion that every one is an acceptable exception.

The review retained the edit checks for missing, ambiguous, and overlapping targets. Exception handlers were reviewed as protocol or operating-system failure boundaries, cleanup, and recovery paths. JuliaSyntax supplies source-aware inventory; JET and Aqua complement it with inference and package-quality tests, but they do not determine whether a branch should use dispatch.

Run the inventory in an environment containing JuliaSyntax with `julia test/branch_scan.jl`. The package test target installs JuliaSyntax and runs the branch and dispatch tests with `julia --project -e 'using Pkg; Pkg.test()'`.
