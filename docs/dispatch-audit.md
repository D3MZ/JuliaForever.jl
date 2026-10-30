# Branch and dispatch audit

The audit covers Julia source in `src/`. `test/branch_scan.jl` uses JuliaSyntax to list source locations for conditionals, short-circuit expressions, loops, exception handlers, comprehension filters, `ifelse`, and calls that may take predicates. The predicate list can include calls whose first argument is a search value rather than a function. The inventory is a static review aid; it cannot see branches produced by arbitrary macro expansion or dynamic code.

At revision `b1a598e`, the inventory contained 1,268 points, including 73 `for` loops, 36 exception handlers, and 29 possible predicate calls. The integrated tree has 1,223 points. Counts include nested expressions, so they are not counts of independent decisions. `test/branch-baseline.txt` ratchets the normalized inventory, so added, removed, or changed entries require review and an explicit baseline update. It does not detect changes confined to branch bodies or moves of identical entries.

The dispatch check is a separate heuristic. Applied to both versions with the expanded rules, it reports 724 candidates at `b1a598e` and 210 now: 571 previous occurrences were removed and 57 appeared under new expressions. The integrated tree includes modules and features added since the initial revision. The previous, narrower checks had recorded 542 and 715 candidates at the initial revision. The exact multiset is in `test/dispatch-baseline.txt`; tests fail if it grows or changes without updating the baseline. Compatibility properties for terminal state and MCP shutdown account for some matches.

The string-status rule found 12 previously unrecognized checks in the provider-merge checkout. Eleven were removed through typed decoding; the remaining OAuth query-key comparison is not a behavioral status. The check also finds status-field and selection comparisons when they return or assign a Boolean instead of controlling a branch directly. A later pass extended this to `isa`, `isnothing`, `ismissing`, and Boolean or missing-value comparisons outside branch conditions; it exposed two additional checks, both replaced with dispatch. It also catches comparisons of `typeof(...)` outside branch conditions; this revealed no additional current candidates. The dynamic `Val(...)` and `Val{...}()` rule found four value-based type tags in the terminal editor; those were replaced with domain outcomes or ordinary numeric checks.

Another pass identifies names of typed methods that directly return a Boolean literal and flags conditional calls to those names across source files. This name-based heuristic can report unrelated methods with the same name; inferred Boolean returns and arbitrary macro expansion are not covered.

The remaining candidates are not all equivalent. Input validation, file-edit safety, numerical and collection checks, and compatibility accessors still require decisions at their boundaries. The agent loops still check cancellation, completion, and configuration status at a few points. Some provider and worker protocol decoders still branch on tags; these can be refactored further. The baseline records these candidates; it is not an assertion that every one is an acceptable exception.

The review retained the edit checks for missing, ambiguous, and overlapping targets. Exception handlers were reviewed as protocol or operating-system failure boundaries, cleanup, and recovery paths. JuliaSyntax supplies source-aware inventory; JET and Aqua complement it with inference and package-quality tests, but they do not determine whether a branch should use dispatch.

Run the inventory in an environment containing JuliaSyntax with `julia test/branch_scan.jl`. The package test target installs JuliaSyntax and runs the branch and dispatch tests with `julia --project -e 'using Pkg; Pkg.test()'`.

The session integration added three branch entries and retired 53 against the multiset union of its two parents; it added no dispatch candidates and retired 21. Two added branch entries combine existing login and session-name restrictions for history recovery commands; the third is the argument-count check for the name option. The subsequent shell-streaming merge increased the branch inventory from 1,087 to 1,104 under the previous scanner. The MCP resources merge increased it to 1,126. Later merges incorporated the expanded dispatch scanner and newer shutdown, scheduler, turn-acquisition, search, and MCP changes. Document snapshots added three branch entries and no dispatch candidates relative to their first parent. MCP HTTP and SSE add 35 branch entries and ten dispatch candidates relative to that tree. Neither merge adds entries beyond the union of its parents under the current scanners.

The fork and clone workflows added 24 branch entries and replaced one existing option check. The merge of those workflows with document snapshots, HTTP transport, search, compaction, and skills adds no entries beyond the multiset union of its parents; 18 branch entries and 11 dispatch candidates from that union were retired.

The history codec now dispatches typed collection and record outcomes while retaining cycle detection and invalid-record checks. Named predicates in search and Anthropic handling also dispatch on domain types; the branch scanner excludes infix operators that previously appeared to be predicate calls. Responses function-call validation dispatches on completion status and field types.

Re-evaluating both parents under the current scanners, the merge adds no entries beyond their multiset union and retires 38 branch entries and 21 dispatch candidates.

The credential lookup adds five net branch entries and no dispatch candidates relative to that integrated tree. It adds no checks beyond the multiset union of its parents.

File argument and user-image support initially added 25 branch entries and removed four. Merging that work adds no entries beyond its parents' multiset union and retires six branch entries; dispatch candidates are unchanged. Windows file URL handling added two further branch entries.

CLI history actions and provider selection now dispatch on typed outcomes. Durable store opening also dispatches on lock and recovery outcomes, while releasing locks on failure.

Continuation adds four branch entries for queue availability and revision checks, with no new dispatch candidates; role decoding dispatches on the resulting domain types.

Before-tool hooks add two branch entries for the hook error boundary and an empty block reason, with no new dispatch candidates; hook selection uses a registration lookup.

Durable replay dispatches on decoded records and rejection outcomes. The `Val` check also recognizes Boolean constants and annotations; compaction uses enabled and disabled policy types. Tool selection added 19 branch entries and removed one. Skill prompt visibility dispatches on invocation type.

The subsequent merge with tool selection, MCP roots, and the dispatch changes adds no entries beyond its parents' multiset union; 18 branch entries and 13 dispatch candidates were retired.

Compaction planning now partitions messages and finds the last user turn through dispatch. Constructor arguments for completion and tool results are checked for typed Boolean predicates and status-field reads; provider completion helpers now return typed outcomes. This merge adds no entries beyond its parents' multiset union and retires six branch entries and seven dispatch candidates.

MCP response delivery and HTTP cancellation now dispatch on whether a pending channel or request context exists.

MCP HTTP admission now dispatches on the registered request context, and response content types select protocol handlers at the boundary.

File reads and exact or fuzzy edits now dispatch on truncation and match outcomes; missing, ambiguous, and overlapping edits remain no-write failures.

Duplicate and missing edit validation now propagates typed failures before any file write.

History value copying now dispatches on collections, keys, and rejection outcomes while retaining cycle detection.

Scheduler request deduplication now dispatches on absent requests and decoded task views.

Chat streaming now dispatches missing deltas, reasoning values, and text values. Empty strings remain ordinary protocol-content checks.

Session file paths and branch selection now dispatch on absent and supplied values.

JSON mode adds 20 branch entries and no dispatch candidates.

Anthropic and Google tool-image support adds two branch entries: recording tool names and selecting the empty-text fallback. It adds no dispatch candidates.
