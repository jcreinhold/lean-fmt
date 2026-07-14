# Performance

Where the formatter spends its time, how to measure it, and the one optimization that is load-bearing. Following the
`lean-rs` performance discipline (`~/Code/lean-rs/docs/performance.md`): **the numbers below are operating checks
captured on one machine, not portable baselines.** Recapture before/after on the same hardware before calling any change
a regression or a win.

## The two measurement surfaces

The formatter splits cleanly into a Lean-free Rust layer and a Lean worker, so it has two benchmark surfaces:

1. **Worker-free hot paths** — `cargo bench -p lean-fmt-project --bench corpus`. A custom harness (no Criterion
   dependency) times the deterministic Rust paths that run on every file: the source digest, the per-file cache key, and
   unified-diff rendering, over the whole [test corpus](../crates/lean-fmt-project/tests/fixtures/corpus). It needs no
   Lean sysroot and asserts no timing numbers, so it runs anywhere.

2. **Worker-driven workloads** — the env-gated probe `crates/lean-fmt-worker-child/tests/perf.rs`. It installs a real
   worker and times the workloads that only exist with Lean in the loop: install cold start, cold vs. warm parse, cache
   miss vs. cache hit, the fix/patch path, and server round-trip latency. It prints one
   `name=<workload> ... elapsed_us=<n>` line per workload. Run it with:

   ```sh
   LEAN_FMT_RUNTIME_SYSROOT="$(cd lean && lake env lean --print-prefix)" \
   LEAN_FMT_RUNTIME_TOOLCHAIN="$(cat lean/lean-toolchain)" \
     cargo test -p lean-fmt-worker-child --test perf -- --ignored --nocapture
   ```

## Where the time goes

Sample capture (macOS, Apple Silicon, Lean `v4.32.0-rc1`, debug build, 7-file clean corpus):

Worker-free hot paths (`--bench corpus`, per file):

| Path | Per file |
| --- | --- |
| `source_digest` | ~0.7 µs |
| `cache_key` | ~1.0 µs |
| `unified_diff` | ~1.6 µs |

Worker-driven workloads (`--test perf`, per file unless noted):

| Workload          | Cost         | Notes                                            |
| ----------------- | ------------ | ------------------------------------------------ |
| `install`         | ~2.9 s (once)| Materialize + smoke-test an installed worker.    |
| `cold_parse`      | ~210 ms/file | First warm-session pass, cache disabled.         |
| `warm_parse`      | ~245 ms/file | Steady-state re-parse through the warm session.  |
| `cache_miss`      | ~245 ms/file | Enabled cache, first pass (parse + store).       |
| `cache_hit`       | **~66 µs/file** | Enabled cache, second pass (no worker touch). |
| `fix`             | ~485 ms/file | Dirty file: parse + rules + format + safe-write. |
| `server_roundtrip`| ~243 ms/file | `FormatService` actor; overhead is negligible.   |

## Bounding Lean resource use (memory & the build fork-storm)

Correctness aside, the load-bearing *stability* control is bounding how much CPU and memory Lean is allowed to consume.
Two surfaces spawn Lean subprocesses, and both are capped from one place — [`LeanResourceBudget`](../crates/lean-fmt-worker/src/budget.rs),
resolved once from the environment with conservative defaults and threaded to each surface as typed knobs (no ambient
`set_var`, no generic child-env passthrough):

1. **The capability build (`install-worker`).** `lake build` derives *both* its build-job parallelism and each spawned
   `lean`'s task-manager thread count from `LEAN_NUM_THREADS` — Lake 5.x exposes **no `-j`/`--jobs` flag**, so this env
   var is the only lever. Unset, Lake fans out to ~`nproc` parallel multi-GB `lean` elaborations (a fork-storm that can
   OOM the machine) while a sibling `cargo build` of the worker-child links `libleanshared` across every core. The budget
   passes `budget.threads` to Lake via [`CargoLeanCapability::lean_num_threads`](../crates/lean-fmt-runtime/src/lib.rs)
   and to the sibling `cargo build` via an explicit `--jobs` on the spawned command. **Default: `1`** (the `LeanFmt`
   package is tiny, so a serial build is safe and fast); set `LEAN_NUM_THREADS` to raise it.

2. **The runtime worker child (`check`/`fix`/`diff`/`serve`).** The one-worker pool already serializes files, but a
   single heavy file can still OOM. [`FormatterWorker`](../crates/lean-fmt-worker/src/lib.rs) applies the budget's RSS
   ceilings and restart cadence uniformly (every construction routes through `FormatterWorker::new`): a soft per-worker
   ceiling and total-child ceiling on the pool, a hard-kill ceiling sampled on an interval (a clean
   `RssHardLimitExceeded` instead of an OS OOM), a memory-bounded recycle after N imports, a per-child thread cap
   (`LEAN_RS_NUM_THREADS`), and an in-runtime Lean allocator guardrail (`LEAN_RS_LEAN_MAX_MEMORY_KIB`) below the OS OOM.
   In `--pinned` mode (see [Pinning one superset environment](#pinning-one-superset-environment)) the import-count
   recycle is disabled — it would throw away the resident superset — and the per-worker ceiling rises to
   `LEAN_FMT_PINNED_RSS_KIB`, so a legitimately large pinned environment survives between files while the hard-kill
   guard still bounds a runaway.

Defaults mirror the `lean-host-mcp` reference (soft **2 GiB** / post-job **5 GiB** / hard-kill **16 GiB**, **250 ms**
sampling, recycle after **~64** imports). Every knob is overridable:

| Env var | Controls | Default |
| --- | --- | --- |
| `LEAN_NUM_THREADS` | build + runtime-child threads | `1` |
| `LEAN_FMT_RSS_SOFT_KIB` | per-worker + total soft RSS ceiling | 2 GiB |
| `LEAN_FMT_RSS_POST_JOB_KIB` | post-job restart threshold | 5 GiB |
| `LEAN_FMT_RSS_HARD_KIB` | hard-kill RSS ceiling | 16 GiB |
| `LEAN_FMT_RSS_SAMPLE_MILLIS` | RSS sampling interval | 250 |
| `LEAN_FMT_MAX_IMPORTS` | imports before a memory-bounded recycle | 64 |
| `LEAN_FMT_LEAN_MAX_MEMORY_KIB` | Lean allocator guardrail | 16 GiB |
| `LEAN_FMT_PINNED_RSS_KIB` | per-worker/total RSS ceiling in `--pinned` mode | 16 GiB |

Parsing is total: a missing or malformed value falls back to the default, and an RSS triple that violates
`soft <= post_job <= hard_kill` reverts to the default triple rather than feed the pool an inverted ceiling.

## The one load-bearing optimization: the cache

The measured before/after is unambiguous. A cold parse costs **~245 ms/file** — dominated by the Lean worker parsing and
validating the source. A warm cache hit costs **~66 µs/file**, roughly **3,700× cheaper**, because `analyze_file`
reconstructs the analysis from the stored result without touching the worker at all. The incremental cache
([`cache.rs`](../crates/lean-fmt-project/src/cache.rs)) is therefore the optimization that matters; everything else is
noise beside it.

The perf probe encodes this as a **relative, machine-independent budget**: a warm cache hit must be at least 2× cheaper
than the cache miss it replaces (in practice it is thousands of times cheaper). The assertion guards against a cache
that silently stopped paying off, without pinning a fragile absolute time.

## Why there is no Rust-side optimization to chase

Profiling says the dominant cost — ~200–250 ms/file — is Lean worker parse/elaboration, which the formatter does not own
and cannot speed up without weakening the validation it exists to provide. The Rust-side hot paths are already
sub-microsecond (table above), three-to-four orders of magnitude below the worker cost, so shaving them would not move
end-to-end time.

Per the `lean-rs` discipline, we do **not** optimize from a microbenchmark without a measured end-to-end win, and we do
**not** trade away a safety check for speed. The `fix` workload (~485 ms/file) is roughly two worker round-trips — one
to parse, one for the safe-write re-validation of the edited output — and that second round-trip is the
comment-preservation and re-parse guarantee, not overhead to remove. The conclusion of this profiling pass is that the
cache is the win, it is measured, and no further Rust optimization is warranted.

## The cost of a cold scan

Formatting a file means parsing it, and parsing Lean means knowing its grammar. That grammar is not
fixed: `notation`, `syntax`, and macros in a file's imports change what the parser accepts. So to
parse a file, lean-fmt rebuilds the parser as that file's imports define it.
[`Frontend.lean`](../lean/LeanFmt/Frontend.lean) does this by calling `Elab.processHeader`, which
calls `importModules` on the header's imports and loads their whole `.olean` closure.

This is a load, not a recompile: the oleans already hold the notation, so lean-fmt reads it rather
than deriving it from source. The cost is turning that stored state into a live `Environment`.
`importModules` deserializes every module in the closure, builds a constant map sized to the whole
closure, and replays every module's extension entries. A file deep in a large library pulls in
hundreds or thousands of modules, so this step costs on the order of a second per file.

By default lean-fmt pays it once per file, because it does not keep the `Environment` between files.
Keeping the *previous* file's environment would help only when consecutive files share imports, and
files in a large library rarely do. But there is one environment every file can reuse: the
whole-project **superset**, the union of every file's imports, loaded once. Holding it turns a cold
pass from N imports into one import plus N cheap parses. That is the `--pinned` optimization below.

A first pass over a whole large library, every file cold *and unpinned*, is a long batch — plausibly
hours, single-threaded. We have not measured it end to end, and it is not the everyday workload:
lean-fmt formats the files you change, and the cache then serves every unchanged file in
microseconds. But a cold pass over an entire ecosystem is a real one-time cost, and `--pinned` is
what collapses it.

## Pinning one superset environment

`lean-fmt check --pinned` (also `fix`/`diff`) imports the project's whole-project superset once, pins
that `Environment` in the warm worker child, and parses every file against it. The per-file import —
the second-per-file cost above — is paid a single time for the run instead of once per file, so a
cold pass over a large project drops from hours toward minutes. This is the ecosystem's established
pattern: the worker child already holds one pinned `Environment` for its process lifetime, and
`lean-host-mcp` relies on it. What `lean-rs` refuses — recycling an in-process environment, or
importing many *different* import sets in one child — is not what this does: it pins exactly one.

The mechanism is deliberately hidden (`Design B`). Each parse request optionally carries the superset
import list plus a stable id (a hash of the sorted union); the worker child
([`Frontend.lean`](../lean/LeanFmt/Frontend.lean)) builds the environment once, keyed by that id, and
reuses it. A child recycled by an RSS guard rebuilds the environment from the next request's carried
list — an automatic self-heal that needs no new export, no protocol change, and no `unsafe` Rust.

Two properties keep it honest:

- **It never trades correctness for speed.** The superset grammar can differ from a file's own-imports
  grammar (a new token shifts a maximal-munch boundary; an added notation makes a parse ambiguous). So
  after parsing a file against the pinned environment, the child checks for parse errors and, on any,
  silently re-parses that one file against its *own* header imports and returns that result, flagged
  `fell_back`. A file that parses fine on its own is never reported broken because the superset
  perturbed it. A `fell_back` result that is *byte-identical* in the projection the rules consume is
  the residual case the offline differential test characterizes.
- **Pinned and per-file results never mix in the cache.** The superset id is part of the
  [`CacheKey`](../crates/lean-fmt-project/src/cache.rs), so a result parsed under one project
  import-union never satisfies a request under a different union, and a pinned result never satisfies a
  per-file one until it has been validated.

`--pinned` is **off by default** and requires the project's oleans to be built (`.lake/build/lib`), so
the superset's imports resolve. If the union does not resolve, or it exceeds `LEAN_FMT_PINNED_RSS_KIB`,
the run degrades cleanly to per-file for the whole pass — a graceful fall-back, never an error. The
memory cost is a resident superset held *once* (bounded by the pinned ceiling) in place of a bounded
environment rebuilt N times; it is a time win, roughly memory-neutral against importing the same set.

## Why there is no parser-only shortcut

This is about a *different* saving than `--pinned` above. Pinning still does the full
`importModules` build; it just does it once and reuses the result. The shortcut asked about here is
building *less* than `importModules` does — loading only the parser slice of each olean. That is the
one that cannot be done without changing Lean.

A parser needs far less than `importModules` builds. Of Lean's environment extensions the parser
reads one, `parserExtension`, whose state holds the token table and the syntax categories; for
ordinary notation it never reads the constant map, since it lexes identifiers as plain tokens. So in
principle lean-fmt could load only the parser slice of each olean and skip the rest, cutting both
time and memory.

It cannot, without a change to Lean itself. Loading the parser slice means replaying the stored
`parserExtension` entries, and that replay turns each stored parser descriptor into a live parser by
looking its constant up in the constant map and running it through the interpreter. The replay needs
the constant map, so the step that costs the most cannot be skipped. A clean version would need a new
Lean core entry point that replays one named extension against a small, caller-supplied set of
constants. Without it, the only route is to re-implement Lean's private, unsafe import internals by
hand and track them across Lean versions.

Two limits hold whatever the loading strategy:

- A parse-only pass sees only the notation a file's *imports* define, never notation the file itself
  introduces, because a `notation` command takes effect only when the frontend elaborates it. lean-fmt
  closes this gap with a **selective-elaboration fallback**: when a parse-only body degrades, it
  re-parses the file, elaborating every command except the heavy declarations and the effectful ones,
  so file-local notation registers into the parser — including notation defined through downstream
  commands like mathlib's `notation3`, which a fixed allowlist could not name. Declaration bodies stay
  unelaborated, so the expensive proof elaboration is still skipped; the cost lands only on files that
  degrade — roughly a second parse plus a handful of cheap notation/scope elaborations (commands that
  depend on the skipped declarations fail fast). A clean file never triggers it. A parser-only import
  would not change any of this.
- `open Foo in ...`, quotations, and a few other constructs read the constant map while parsing. A
  parser-only environment carrying only a partial constant map would fail on them — trading
  correctness for speed on the files a large library is full of.

If this is ever worth doing, the place to do it is upstream: a Lean core `importModulesForParsing`
that builds `parserExtension` plus only the constants its parsers need. That is a change to Lean, not
to lean-fmt.

## Detecting a regression

Capture the worker-driven probe before and after any change you suspect of moving parse, cache, fix, or server latency,
on the same machine:

```sh
# before your change
LEAN_FMT_RUNTIME_SYSROOT="$(cd lean && lake env lean --print-prefix)" \
  cargo test -p lean-fmt-worker-child --test perf -- --ignored --nocapture | tee /tmp/perf-before.txt
# ... make changes ...
# after
LEAN_FMT_RUNTIME_SYSROOT="$(cd lean && lake env lean --print-prefix)" \
  cargo test -p lean-fmt-worker-child --test perf -- --ignored --nocapture | tee /tmp/perf-after.txt
diff /tmp/perf-before.txt /tmp/perf-after.txt
```

Treat a change to `cache_hit` (the fast path) or a `cache_hit`/`cache_miss` ratio drop as load-bearing; treat a uniform
shift across all worker workloads as machine noise between captures. For the Rust hot paths,
`cargo bench -p lean-fmt-project --bench corpus` prints the same per-workload throughput before and after.
