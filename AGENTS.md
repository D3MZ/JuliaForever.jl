# Julia conventions

- Use small, clear Julia APIs, generic verbs, typed multiple dispatch, and `!` for mutation. Avoid artificial wrappers and type tags when dispatch expresses the behavior.
- Keep runtime code direct. Do not add speculative input guards or custom exceptions. Do not explicitly call `throw`, `error`, or `rethrow`, or use `@assert` in `src`; the quality tests enforce this. Let ordinary Julia and operating-system errors propagate, and represent expected tool failures as values at the tool boundary.
- Preserve meaningful external safety rules: an edit must not alter a file when its targets are missing, ambiguous, or overlapping.
- Keep identifiers concise, avoid leading underscores, avoid needless type annotations and manual line wrapping, and use function barriers for performance-sensitive work.
- Test behavior against the pinned Pi revision where applicable. Keep compatibility gaps explicit. Measure before making performance claims.
