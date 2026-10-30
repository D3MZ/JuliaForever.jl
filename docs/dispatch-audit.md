# Branch and dispatch audit

The audit covers Julia source in `src/`. `test/branch_scan.jl` uses JuliaSyntax to list source locations for conditionals, short-circuit expressions, loops, exception handlers, comprehension filters, `ifelse`, and calls that may take predicates. The predicate list can include calls whose first argument is a search value rather than a function. The inventory is a static review aid; it cannot see branches produced by arbitrary macro expansion or dynamic code.

At revision `b1a598e`, the inventory contained 1,268 points, including 73 `for` loops, 36 exception handlers, and 29 possible predicate calls. The integrated tree has 1,505 points. Counts include nested expressions, so they are not counts of independent decisions. `test/branch-baseline.txt` ratchets the normalized inventory, so added, removed, or changed entries require review and an explicit baseline update. It does not detect changes confined to branch bodies or moves of identical entries.

The dispatch check is a separate heuristic. Applied to both versions with the expanded rules, it reports 750 candidates at `b1a598e` and 126 now: 693 previous occurrences were removed and 69 appeared under new expressions. The integrated tree includes modules and features added since the initial revision. The previous, narrower checks had recorded 542 and 715 candidates at the initial revision. The exact multiset is in `test/dispatch-baseline.txt`; tests fail if it grows or changes without updating the baseline. Compatibility properties for terminal state and MCP shutdown account for some matches.

The string-status rule found 12 previously unrecognized checks in the provider-merge checkout. Eleven were removed through typed decoding; the remaining OAuth query-key comparison is not a behavioral status. The check also finds status-field and selection comparisons when they return or assign a Boolean instead of controlling a branch directly. A later pass extended this to `isa`, `isnothing`, `ismissing`, and Boolean or missing-value comparisons outside branch conditions; it exposed two additional checks, both replaced with dispatch. It also catches comparisons of `typeof(...)` outside branch conditions; this revealed no additional current candidates. The dynamic `Val(...)` and `Val{...}()` rule found four value-based type tags in the terminal editor; those were replaced with domain outcomes or ordinary numeric checks.

Another pass identifies names of typed methods that directly return a Boolean literal and flags conditional calls to those names across source files. This name-based heuristic can report unrelated methods with the same name; inferred Boolean returns and arbitrary macro expansion are not covered.

The same scan now recognizes typed methods returning literal protocol labels and flags comparisons of their results. It identified a Responses route converted to a string and compared; authentication now dispatches on the route. Two remaining matches test membership in user-selected tool names.

The keyword-value pass also checks typed Boolean predicates passed to calls. It found request and execution result types converted to Booleans and then reconstructed; both now pass the types directly. The remaining new matches include protocol serialization and unrelated functions sharing predicate names.

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

Queue modes and model completion add six net branch entries for revision, queue, and menu data checks, with no new dispatch candidates.

Saved-provider startup routing adds no branch or dispatch entries; it selects behavior using the resolved provider and credential values.

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

Skill reload adds nine branch entries and five dispatch candidates relative to its base. The candidates are content and revision consistency checks used to retain managed metadata and reject stale updates; the scanner recognizes `Kernel.same` as a Boolean predicate.

Explicit skill commands add two branch entries for matching a discovered name and omitting empty arguments; they add no dispatch candidates.

Interactive command completion adds 22 branch entries for fuzzy matching, menu selection, and layout, and no dispatch candidates.

Interactive file completion adds 69 branch entries for token parsing, directory walking, ranking, and menu updates, and no dispatch candidates. File kinds, request modes, and cancellation states use typed dispatch.

Model argument completion adds four branch entries for menu state and matching, and no dispatch candidates.

Markdown rendering in conversation exports adds six branch entries and no dispatch candidates.

The ChatGPT adapter and conversation export add 142 branch entries and no dispatch candidates relative to their integrated base.

Chat streaming now dispatches missing deltas, reasoning values, and text values. Empty strings remain ordinary protocol-content checks.

A constructor-literal pass found 19 uses of Boolean status arguments. They now construct typed tool or completion outcomes; compatibility constructors remain available at the boundary.

The constructor check also catches Boolean completion or code-result properties. Execution now carries the typed completion status directly, and CodeMode maps wire-format flags to result types at decoding.

Session file paths and branch selection now dispatch on absent and supplied values.

Session file headers and rows are decoded through typed validation. Duplicate IDs still reject the input, and invalid files remain untouched. Branch traversal ends on missing IDs or cycles.

JSON mode adds 20 branch entries and no dispatch candidates.

A further constructor check recognizes common Boolean flag names and excludes constructor definitions. It found four calls, now replaced by typed tool outcomes or boundary decoding; the name-based rule cannot detect every Boolean variable.

Anthropic and Google tool-image support adds two branch entries: recording tool names and selecting the empty-text fallback. It adds no dispatch candidates.

Parallel local tool execution replaces two batch loops with two completion-processing loops. Deferred-tool replay adds two entries for source-ordered discovery; no dispatch candidates were added.

Overflow recovery adds five branch entries and no dispatch candidates.

Kernel observation handling now dispatches on missing and found records while retaining duplicate and conflict precedence.

CodeMode cleanup now dispatches on absent resources and live tasks or processes.

CLI CodeMode registration now dispatches on the selected tool type.

The CLI-option pass recognizes comparisons against long and short option names, excluding the bare argument delimiter and negative numbers. It found 24 discriminator checks; the parser now maps option strings to handlers and dispatches on parsing state. Value validation remains at the input boundary.

Search pattern construction maps literal and case options to concrete pattern behavior at the input boundary.

Ignore-file parsing produces include, ignore, and directory-only patterns carrying their regular expressions. Matching dispatches on those patterns while preserving rule order and nested repository boundaries.

SQLite history opening now dispatches on initialization outcomes and closes the database unless ownership transfers to an open history.

The full-screen terminal adds 45 branch entries, mostly rendering, viewport, and menu iteration. It adds one dispatch candidate for the optional result of a menu key; role and event handling dispatch on typed values.

Document fork policies add 17 branch entries for selection, validation, and replay, and no dispatch candidates.

The model-catalog integration adds 54 net branch entries before the document-fork merge; the dispatch scanner also recognizes additional result-flag patterns.

Model-listing parsing now handles its optional query as a parsing state and retains case-insensitive provider names.

MCP progress uses channels and typed request lifecycle outcomes. It adds 12 branch entries and no dispatch candidates relative to main. Re-evaluating both parents with the expanded scanners, the merge adds no entries beyond their multiset union and retires two branch entries and 27 dispatch candidates.

The parallel-tool and MCP progress merge adds no branch or dispatch entries beyond the union of its parents and retires two branch entries.

The flag-comparison rule now catches common named behavioral flags in equality comparisons. It found one further check in search; include and exclude glob filters now dispatch on their concrete filter values. The remaining `selectglob` candidate evaluates file matching, not filter type.

Shell cancellation now dispatches on its active-run registry, and shell cleanup dispatches on actual retained output files. Cancellation, process-group cleanup, and streaming still have dedicated race and Pi checks.

Shell output selection returns whole lines, byte-limited lines, or a partial line as distinct results. Notice formatting dispatches on the selected output.

MCP tool discovery decodes pages, definitions, task support, descriptions, and cursors through typed methods. Collision and repeated-cursor checks remain as data validation, and failures keep their protocol precedence.

The discriminator rule now includes labels. It identified an unused result-label alternative in find output; the implementation now formats find results directly. Glob character classes dispatch on the matched closing position.

Model reasoning effort is now included in the discriminator rule. Request writing, authorization, and reasoning updates map protocol values at their boundaries; the remaining check validates membership in a model's supported values.

Agent model-response cleanup dispatches on the received response, recording a failure if the provider or usage handling does not complete.

History initial-state encoding dispatches on conversation phase while preserving revision validation.

The authentication, export, and skill-command integration added 144 branch entries. The review retained credential validation, identity and file safety checks, protocol parsing, and collection decisions. A later error-code rule found five additional matches: OAuth refresh and MCP fallback now map protocol codes at the boundary; three operating-system error and exit-code checks remain.

OpenRouter persistence adds 11 branch entries for credential paths, filesystem safety, and error handling; it adds no dispatch candidates.

The OpenRouter callback validates requests before dispatching success, denial, and invalid responses. Its pending channel is consumed once under the callback lock, so concurrent replays are rejected.

OpenAI request construction selects buffered or streamed configuration at the call site; the Boolean keyword remains a boundary adapter.

CodeMode event processing now dispatches on received outcomes and uses channel closure to end the loop. The channel-open check remains an inventory candidate; it represents the event stream lifecycle.

CodeMode tool calls now retain pending or completed call data in distinct types and render the existing status records at the result boundary.

The CodeMode worker represents its open connection by its pending-call registry. Closing the connection removes the registry and wakes pending callers; result delivery and text formatting dispatch on received values.

Recorded-agent persistence dispatches on the actual append result, preserving the uncertain state if an append exits without returning.

Model configuration adds 25 branch entries for parsing, validation, header merging, and model lookup, with no new dispatch candidates.

The subsequent model-configuration update adds seven branch entries for empty credentials, header validation, and model fields; it adds no dispatch candidates.

Re-evaluating both parents with the expanded scanners, the model-configuration merge adds no entries beyond their multiset union and retires 93 branch entries and 57 dispatch candidates.

The model-configuration, skill-command, and credential-store merge adds no entries beyond the union of its parents.

Re-evaluating both parents with the expanded scanners, this merge adds no entries beyond their union and retires nine branch entries and seven dispatch candidates.

The CodeMode and model-configuration merge adds no entries beyond its parents and retires five branch entries and five dispatch candidates.

Directory and search output limits now return full text or a limited output value; notice rendering dispatches on that result.

Search line shortening now returns a shortened line value, with its notice collected by dispatch.

Directory entry limits now return a limited entry collection when there are further entries; search match limits use the count directly.

MCP call response validation dispatches on field presence and decoded field types, preserving the distinction between absent and invalid values.

MCP initialization maps supported protocol versions once and validates capabilities and server identity through typed methods.

Markdown export adds six branch entries for list numbering and rendering iteration; it adds no dispatch candidates.

Terminal completion adds 22 branch entries for fuzzy scoring, matching, list iteration, and viewport layout; it adds no dispatch candidates.

MCP JSON-RPC routing dispatches on message fields, request IDs, and error values; Boolean IDs and error codes remain invalid.

MCP resource-content validation dispatches on URI, text, and blob values; the remaining predicate checks whether all decoded contents are valid.

The provider-alias routing update adds no branch or dispatch entries.

Scheduler opening now dispatches cleanup on the actual result, closing the store when recovery fails.

SQLite transaction cleanup dispatches on whether a commit or rollback returned, preserving uncertainty after failures.

Durable log opening selects the appropriate sync operation at the filesystem boundary. Commit cleanup dispatches on the actual completed value and marks the store failed when writing or syncing does not complete.

SQLite open mode is selected at the keyword boundary; existing-only and create paths use separate initialization and retain file safety checks.
