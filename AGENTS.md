# Julia conventions

- Use small, clear Julia APIs, generic verbs, typed multiple dispatch, and `!` for mutation. Avoid artificial wrappers and type tags when dispatch expresses the behavior.
- Model behavioral alternatives as distinct types and dispatch on them instead of branching on status flags, `isa`, or `nothing`; keep unavoidable protocol conversions at the boundary. The dispatch quality test ratchets the recognized checks while existing cases are retired.
- At external boundaries, map protocol discriminators to concrete domain types once and dispatch on those types. Name values for the domain concepts they represent.
- Keep runtime code direct. Do not add speculative input guards or custom exceptions. Do not explicitly call `throw`, `error`, or `rethrow`, or use `@assert` in `src`; the quality tests enforce this. Let ordinary Julia and operating-system errors propagate, and represent expected tool failures as values at the tool boundary.
- Preserve meaningful external safety rules: an edit must not alter a file when its targets are missing, ambiguous, or overlapping.
- Keep identifiers concise, avoid leading underscores, avoid needless type annotations and manual line wrapping, and use function barriers for performance-sensitive work.
- Test behavior against the pinned Pi revision where applicable. Keep compatibility gaps explicit. Measure before making performance claims.

# Testing

- Prefer end-to-end, observable feature behavior over granular unit tests and assertions about implementation details. Aim for one to three broad tests per feature, covering meaningful success, failure, safety, and compatibility scenarios; use additional focused tests only when necessary to protect a distinct behavior or deterministic race, recovery, or boundary case.
- Preserve source coverage when consolidating tests, but do not treat line coverage as proof of behavioral coverage. Keep independent expected outcomes and differential cases against pinned Pi where applicable.
- Run focused tests for the features changed locally; rely on GitHub Actions for the full suite and coverage run. Report any coverage or behavior that remains unverified.
