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
