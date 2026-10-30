# Test coverage

Run from the repository root with `PI_SOURCE` pointing to the pinned Pi checkout and its Node dependencies:

```sh
PI_SOURCE=/path/to/pi JULIA_NUM_THREADS=4 julia --startup-file=no --project=. scripts/ci.jl --coverage
python3 scripts/coverage.py --output /tmp/julia-coverage-baseline.json
```

After a test-only change, run the same Julia command again and compare:

```sh
python3 scripts/coverage.py --baseline /tmp/julia-coverage-baseline.json --output /tmp/julia-coverage-current.json
```

The comparison fails if any previously covered line loses coverage, or a previously reported source file changes or is missing. It is intended for comparisons with unchanged production source and the same operating system, Julia version, dependencies, environment, and test configuration. Use `--native-only --coverage` to measure without Pi; do not compare that run against a full differential run. The command removes existing `src/*.jl.<pid>.cov` reports before collecting fresh results. Do not run coverage jobs in the same checkout concurrently.

The report merges Julia process `.cov` files found under `src/` and calls out source files with no report. Only instrumented processes contribute; subprocesses that do not inherit coverage settings and the separately invoked terminal-plugin installation test may be absent. Coverage tracks executed lines, not branches, assertions, observable behavior, or feature parity. A passing comparison alone does not establish that removing a test is safe.

On Linux, GitHub Actions runs the full suite with coverage and publishes the summary and raw reports as an Actions artifact. No third-party token is needed. Verify the reporter itself with `python3 -B -m unittest discover -s scripts/tests -v`.

On Linux, GitHub Actions compares coverage with the first parent when `src/`, `Project.toml`, and `Manifest.toml` match that parent. It runs the parent test suite against the same pinned Pi and fails if a previously covered source line is lost. A change to source or dependencies explicitly skips this comparison. For a one-off comparison against an earlier revision, run the workflow manually and set `coverage_baseline` to that commit; for this integration use `0e821a5d22a5203913552ddaefd7390261513ea9`. Baseline and current reports are included in the Actions artifact. This comparison only covers instrumented lines and does not prove that retained assertions detect the same faults.
