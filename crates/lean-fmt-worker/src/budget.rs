//! Single source of truth for lean-fmt's Lean resource caps.
//!
//! One [`LeanResourceBudget`], parsed once from the environment with safe defaults, bounds
//! *both* subprocess surfaces that can otherwise exhaust the machine:
//!
//! - the **capability build** (`lake build` → the `lean` fork-storm), capped by
//!   [`threads`](LeanResourceBudget::threads) via `LEAN_NUM_THREADS`;
//! - the **runtime worker child**, capped by the RSS ceilings, the memory-bounded restart
//!   cadence, the per-child thread count, and the Lean runtime memory guardrail.
//!
//! Defaults mirror the `lean-host-mcp` reference (soft 2 / post-job 5 / hard-kill 16 GiB,
//! 250 ms RSS sampling, recycle after ~64 imports). Every knob is overridable via a
//! `LEAN_FMT_*` env var; the thread count follows Lake's own `LEAN_NUM_THREADS`. Parsing is
//! total — a missing or malformed value silently falls back to the default, and an RSS
//! triple that violates `soft <= post_job <= hard_kill` reverts to the default triple rather
//! than feeding an inverted ceiling to the pool.

use std::time::Duration;

/// Conservative build/runtime thread fallback. The `LeanFmt` capability is tiny, so a serial
/// `lake build` is safe and fast; one runtime child at one task-manager thread cannot fork a
/// storm. Used whenever `LEAN_NUM_THREADS` is unset or not a positive integer.
const DEFAULT_THREADS: u32 = 1;

/// Per-worker soft RSS ceiling (2 GiB, in KiB): the pool prefers to recycle a child that
/// crosses this between jobs. Matches `lean-host-mcp`'s import-switch soft guard.
const DEFAULT_RSS_SOFT_KIB: u64 = 2 * 1024 * 1024;

/// Post-job restart RSS threshold (5 GiB, in KiB): a child above this after finishing a job
/// is retired even if still under the hard kill. Matches `lean-host-mcp`.
const DEFAULT_RSS_POST_JOB_KIB: u64 = 5 * 1024 * 1024;

/// Hard-kill RSS ceiling (16 GiB, in KiB): the supervisor kills a child that crosses this
/// mid-job, surfacing `RssHardLimitExceeded` instead of letting the OS OOM-kill. Matches
/// `lean-host-mcp`.
const DEFAULT_RSS_HARD_KILL_KIB: u64 = 16 * 1024 * 1024;

/// RSS sampling cadence (250 ms). Tight enough to catch a fast blow-up before it OOMs, loose
/// enough to stay off the hot path. Matches `lean-host-mcp`.
const DEFAULT_RSS_SAMPLE_MILLIS: u64 = 250;

/// Recycle the runtime child after this many imported files, bounding module-cache growth
/// across a long `check`/`fix` run. Matches `lean-host-mcp`'s per-worker request-restart count.
const DEFAULT_MAX_IMPORTS: u64 = 64;

/// Lean-runtime memory guardrail (16 GiB, in KiB), passed to the child as
/// `LEAN_RS_LEAN_MAX_MEMORY_KIB`. The Lean allocator aborts the elaboration cleanly at this
/// bound; pairing it with the RSS hard kill gives an in-runtime backstop below the OS OOM.
const DEFAULT_LEAN_MAX_MEMORY_KIB: u64 = 16 * 1024 * 1024;

/// Resolved Lean resource caps, threaded to both the capability build and the runtime worker.
///
/// Construct with [`LeanResourceBudget::from_env`]; the fields are the single source of truth
/// consumed at each subprocess surface.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct LeanResourceBudget {
    /// Build/runtime thread cap (`LEAN_NUM_THREADS`), always `>= 1`.
    pub threads: u32,
    /// Per-worker soft RSS ceiling, in KiB.
    pub per_worker_rss_soft_kib: u64,
    /// Post-job restart RSS threshold, in KiB.
    pub post_job_rss_kib: u64,
    /// Hard-kill RSS ceiling, in KiB.
    pub hard_kill_rss_kib: u64,
    /// RSS sampling interval.
    pub rss_sample: Duration,
    /// Import count that triggers a memory-bounded child recycle.
    pub max_imports: u64,
    /// Lean-runtime memory guardrail, in KiB (`LEAN_RS_LEAN_MAX_MEMORY_KIB`).
    pub lean_max_memory_kib: u64,
}

impl Default for LeanResourceBudget {
    fn default() -> Self {
        Self {
            threads: DEFAULT_THREADS,
            per_worker_rss_soft_kib: DEFAULT_RSS_SOFT_KIB,
            post_job_rss_kib: DEFAULT_RSS_POST_JOB_KIB,
            hard_kill_rss_kib: DEFAULT_RSS_HARD_KILL_KIB,
            rss_sample: Duration::from_millis(DEFAULT_RSS_SAMPLE_MILLIS),
            max_imports: DEFAULT_MAX_IMPORTS,
            lean_max_memory_kib: DEFAULT_LEAN_MAX_MEMORY_KIB,
        }
    }
}

impl LeanResourceBudget {
    /// Resolve the budget from the process environment, falling back to safe defaults.
    ///
    /// Parsing never fails: `LEAN_NUM_THREADS` and each `LEAN_FMT_*` override is applied only
    /// when it parses to a positive value, and an RSS triple that violates
    /// `soft <= post_job <= hard_kill` reverts to the default triple.
    #[must_use]
    pub fn from_env() -> Self {
        Self::resolve(|key| std::env::var(key).ok())
    }

    /// Env-lookup-injectable core of [`from_env`](Self::from_env), for deterministic tests.
    fn resolve(lookup: impl Fn(&str) -> Option<String>) -> Self {
        let defaults = Self::default();

        let threads = parse_positive_u32(lookup("LEAN_NUM_THREADS").as_deref()).unwrap_or(defaults.threads);

        let per_worker_rss_soft_kib =
            parse_positive_u64(lookup("LEAN_FMT_RSS_SOFT_KIB").as_deref()).unwrap_or(defaults.per_worker_rss_soft_kib);
        let post_job_rss_kib =
            parse_positive_u64(lookup("LEAN_FMT_RSS_POST_JOB_KIB").as_deref()).unwrap_or(defaults.post_job_rss_kib);
        let hard_kill_rss_kib =
            parse_positive_u64(lookup("LEAN_FMT_RSS_HARD_KIB").as_deref()).unwrap_or(defaults.hard_kill_rss_kib);

        // Reject an inverted ceiling wholesale: a mixed user/default triple could still invert,
        // so revert all three together to the known-good defaults rather than clamp piecewise.
        let (per_worker_rss_soft_kib, post_job_rss_kib, hard_kill_rss_kib) =
            if per_worker_rss_soft_kib <= post_job_rss_kib && post_job_rss_kib <= hard_kill_rss_kib {
                (per_worker_rss_soft_kib, post_job_rss_kib, hard_kill_rss_kib)
            } else {
                (
                    defaults.per_worker_rss_soft_kib,
                    defaults.post_job_rss_kib,
                    defaults.hard_kill_rss_kib,
                )
            };

        let rss_sample = parse_positive_u64(lookup("LEAN_FMT_RSS_SAMPLE_MILLIS").as_deref())
            .map_or(defaults.rss_sample, Duration::from_millis);
        let max_imports = parse_positive_u64(lookup("LEAN_FMT_MAX_IMPORTS").as_deref()).unwrap_or(defaults.max_imports);
        let lean_max_memory_kib = parse_positive_u64(lookup("LEAN_FMT_LEAN_MAX_MEMORY_KIB").as_deref())
            .unwrap_or(defaults.lean_max_memory_kib);

        Self {
            threads,
            per_worker_rss_soft_kib,
            post_job_rss_kib,
            hard_kill_rss_kib,
            rss_sample,
            max_imports,
            lean_max_memory_kib,
        }
    }
}

/// Parse a strictly-positive `u32`, rejecting missing, malformed, and zero values.
fn parse_positive_u32(raw: Option<&str>) -> Option<u32> {
    raw.and_then(|value| value.trim().parse::<u32>().ok())
        .filter(|&n| n >= 1)
}

/// Parse a strictly-positive `u64`, rejecting missing, malformed, and zero values.
fn parse_positive_u64(raw: Option<&str>) -> Option<u64> {
    raw.and_then(|value| value.trim().parse::<u64>().ok())
        .filter(|&n| n >= 1)
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::indexing_slicing, clippy::panic)]

    use std::collections::HashMap;

    use super::*;

    fn budget_from(pairs: &[(&str, &str)]) -> LeanResourceBudget {
        let map: HashMap<String, String> = pairs.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())).collect();
        LeanResourceBudget::resolve(|key| map.get(key).cloned())
    }

    #[test]
    fn unset_environment_yields_defaults() {
        let budget = budget_from(&[]);
        assert_eq!(budget, LeanResourceBudget::default());
        assert_eq!(budget.threads, 1);
        assert_eq!(budget.per_worker_rss_soft_kib, 2 * 1024 * 1024);
        assert_eq!(budget.hard_kill_rss_kib, 16 * 1024 * 1024);
        assert_eq!(budget.rss_sample, Duration::from_millis(250));
        assert_eq!(budget.max_imports, 64);
    }

    #[test]
    fn valid_lean_num_threads_is_honored() {
        assert_eq!(budget_from(&[("LEAN_NUM_THREADS", "8")]).threads, 8);
    }

    #[test]
    fn invalid_or_zero_lean_num_threads_falls_back() {
        assert_eq!(budget_from(&[("LEAN_NUM_THREADS", "0")]).threads, 1);
        assert_eq!(budget_from(&[("LEAN_NUM_THREADS", "not-a-number")]).threads, 1);
        assert_eq!(budget_from(&[("LEAN_NUM_THREADS", "")]).threads, 1);
        assert_eq!(budget_from(&[("LEAN_NUM_THREADS", "-4")]).threads, 1);
    }

    #[test]
    fn rss_overrides_are_applied_when_ordered() {
        let budget = budget_from(&[
            ("LEAN_FMT_RSS_SOFT_KIB", "1000"),
            ("LEAN_FMT_RSS_POST_JOB_KIB", "2000"),
            ("LEAN_FMT_RSS_HARD_KIB", "3000"),
        ]);
        assert_eq!(budget.per_worker_rss_soft_kib, 1000);
        assert_eq!(budget.post_job_rss_kib, 2000);
        assert_eq!(budget.hard_kill_rss_kib, 3000);
    }

    #[test]
    fn inverted_rss_triple_reverts_to_defaults() {
        // hard-kill below soft — an inverted ceiling that would misconfigure the pool.
        let budget = budget_from(&[
            ("LEAN_FMT_RSS_SOFT_KIB", "9000"),
            ("LEAN_FMT_RSS_POST_JOB_KIB", "5000"),
            ("LEAN_FMT_RSS_HARD_KIB", "1000"),
        ]);
        let defaults = LeanResourceBudget::default();
        assert_eq!(budget.per_worker_rss_soft_kib, defaults.per_worker_rss_soft_kib);
        assert_eq!(budget.post_job_rss_kib, defaults.post_job_rss_kib);
        assert_eq!(budget.hard_kill_rss_kib, defaults.hard_kill_rss_kib);
    }

    #[test]
    fn ordering_invariant_holds_for_defaults() {
        let b = LeanResourceBudget::default();
        assert!(b.per_worker_rss_soft_kib <= b.post_job_rss_kib);
        assert!(b.post_job_rss_kib <= b.hard_kill_rss_kib);
    }

    #[test]
    fn sample_and_memory_overrides_apply() {
        let budget = budget_from(&[
            ("LEAN_FMT_RSS_SAMPLE_MILLIS", "500"),
            ("LEAN_FMT_MAX_IMPORTS", "16"),
            ("LEAN_FMT_LEAN_MAX_MEMORY_KIB", "8388608"),
        ]);
        assert_eq!(budget.rss_sample, Duration::from_millis(500));
        assert_eq!(budget.max_imports, 16);
        assert_eq!(budget.lean_max_memory_kib, 8_388_608);
    }
}
