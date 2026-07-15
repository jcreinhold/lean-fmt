//! Single source of truth for lean-fmt's Lean resource caps.
//!
//! One [`LeanResourceBudget`], parsed once from the environment with safe defaults, bounds
//! *both* subprocess surfaces that can otherwise exhaust the machine:
//!
//! - the **capability build** (`lake build` → the `lean` fork-storm), capped by
//!   [`threads`](LeanResourceBudget::threads) via `LEAN_NUM_THREADS`;
//! - the **runtime worker child**, capped by the RSS ceilings, the memory-bounded restart
//!   cadence, the per-child thread count, and the Lean runtime memory guardrail. In pinned
//!   mode it also carries a higher [`pinned_rss_ceiling_kib`](LeanResourceBudget::pinned_rss_ceiling_kib)
//!   so a resident whole-project superset environment is not recycled between files.
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

/// Pinned-mode per-worker/total RSS ceiling (16 GiB, in KiB). In pinned mode the child holds
/// one whole-project superset environment resident for its lifetime, so the ordinary 2 GiB
/// soft ceiling would recycle it between files — discarding the pin and defeating the
/// optimization. This higher ceiling lets a legitimately large resident superset survive
/// while the hard-kill guard still bounds a genuine runaway. Overridable via
/// `LEAN_FMT_PINNED_RSS_KIB`.
const DEFAULT_PINNED_RSS_CEILING_KIB: u64 = 16 * 1024 * 1024;

/// Memory budget fallback (8 GiB, in KiB) used only when *both* available- and total-RAM
/// detection fail and `LEAN_FMT_MEM_BUDGET_KIB` is unset. Paired with the ~5 GiB per-worker
/// estimate this admits one worker — a safe floor on a machine whose RAM we cannot read.
const DEFAULT_MEM_BUDGET_KIB: u64 = 8 * 1024 * 1024;

/// Default per-worker planning estimate (5 GiB, in KiB): the *realistic sustained peak* RSS of one
/// worker, used to derive the auto worker count (`W × est` must fit the budget). This is the
/// post-job restart threshold, **not** the 2 GiB soft ceiling — a worker mid-import routinely
/// exceeds the soft floor and is only retired between jobs at the post-job level, so sizing `W`
/// against the soft floor overcommits memory by 2-3× and OOMs. Overridable via
/// `LEAN_FMT_WORKER_EST_KIB` to match what a given project actually holds.
const DEFAULT_WORKER_EST_KIB: u64 = DEFAULT_RSS_POST_JOB_KIB;

/// Reserve (2 GiB, in KiB) held back from detected *available* memory before the fleet budget
/// claims the rest, leaving headroom for the OS, the parent process, and whatever else is running.
const DEFAULT_MEM_RESERVE_KIB: u64 = 2 * 1024 * 1024;

/// Fraction of detected *total* RAM (in tenths) used only as a fallback when available-memory
/// detection fails. 6/10 is deliberately conservative — it cannot see current load, so it leaves a
/// wide margin rather than risk overcommitting a busy machine.
const MEM_BUDGET_TOTAL_NUMERATOR: u64 = 6;
const MEM_BUDGET_TOTAL_DENOMINATOR: u64 = 10;

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
    /// Pinned-mode per-worker/total RSS ceiling, in KiB. Applied only when a worker holds a
    /// pinned superset environment, where the ordinary soft ceiling would recycle the pin.
    pub pinned_rss_ceiling_kib: u64,
    /// Per-worker planning estimate, in KiB: the realistic sustained peak RSS the auto worker count
    /// divides the budget by (`W = ⌊mem_budget / per_worker_est⌋`). Defaults to the post-job
    /// threshold (~5 GiB), not the soft ceiling; overridable via `LEAN_FMT_WORKER_EST_KIB`.
    pub per_worker_est_kib: u64,
    /// Total memory, in KiB, the fleet may spread parallel worker children across. Bounds the auto
    /// worker count so `W × per_worker_est` stays within it. Defaults to detected *available* RAM
    /// minus a 2 GiB reserve (falling back to 60% of total RAM, then an 8 GiB floor, when detection
    /// fails); overridable via `LEAN_FMT_MEM_BUDGET_KIB`.
    pub mem_budget_kib: u64,
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
            pinned_rss_ceiling_kib: DEFAULT_PINNED_RSS_CEILING_KIB,
            per_worker_est_kib: DEFAULT_WORKER_EST_KIB,
            mem_budget_kib: DEFAULT_MEM_BUDGET_KIB,
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
        Self::resolve_with(
            |key| std::env::var(key).ok(),
            DetectedRam {
                available_kib: detect_available_ram_kib(),
                total_kib: detect_total_ram_kib(),
            },
        )
    }

    /// Env-lookup-injectable core of [`from_env`](Self::from_env), for deterministic tests.
    /// RAM detection is left out (both `None`), so `mem_budget_kib` uses the fixed fallback.
    #[cfg(test)]
    fn resolve(lookup: impl Fn(&str) -> Option<String>) -> Self {
        Self::resolve_with(lookup, DetectedRam::default())
    }

    /// Env- and RAM-injectable core of [`from_env`](Self::from_env). `detected` carries the
    /// machine's *available* RAM (preferred) and *total* RAM (fallback basis); the auto memory
    /// budget is available-minus-reserve, else a conservative fraction of total, else the fixed
    /// floor. An explicit `LEAN_FMT_MEM_BUDGET_KIB` overrides all three.
    fn resolve_with(lookup: impl Fn(&str) -> Option<String>, detected: DetectedRam) -> Self {
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
        let pinned_rss_ceiling_kib =
            parse_positive_u64(lookup("LEAN_FMT_PINNED_RSS_KIB").as_deref()).unwrap_or(defaults.pinned_rss_ceiling_kib);

        // The planning estimate defaults to the (possibly-overridden) post-job threshold — the
        // realistic sustained peak — so `W` is not sized against the too-low soft floor.
        let per_worker_est_kib =
            parse_positive_u64(lookup("LEAN_FMT_WORKER_EST_KIB").as_deref()).unwrap_or(post_job_rss_kib);

        // Budget preference: explicit override → available-minus-reserve → a conservative fraction
        // of total → the fixed floor. Available memory reflects current load, so a busy machine is
        // not handed 80% of *total* RAM it does not actually have free.
        let mem_budget_kib = parse_positive_u64(lookup("LEAN_FMT_MEM_BUDGET_KIB").as_deref())
            .or_else(|| {
                detected
                    .available_kib
                    .map(|available| available.saturating_sub(DEFAULT_MEM_RESERVE_KIB))
                    .filter(|&budget| budget >= 1)
            })
            .or_else(|| {
                detected
                    .total_kib
                    .map(|total| (total / MEM_BUDGET_TOTAL_DENOMINATOR).saturating_mul(MEM_BUDGET_TOTAL_NUMERATOR))
                    .filter(|&budget| budget >= 1)
            })
            .unwrap_or(defaults.mem_budget_kib);

        Self {
            threads,
            per_worker_rss_soft_kib,
            post_job_rss_kib,
            hard_kill_rss_kib,
            rss_sample,
            max_imports,
            lean_max_memory_kib,
            pinned_rss_ceiling_kib,
            per_worker_est_kib,
            mem_budget_kib,
        }
    }

    /// The largest worker count whose combined per-worker estimate stays within [`mem_budget_kib`],
    /// for the given mode. Per-file mode sizes each worker at the ~5 GiB realistic-peak estimate;
    /// pinned mode at the (larger) pinned ceiling, so pinned runs self-limit to very few workers.
    /// Always `>= 1` — one worker runs even if it nominally overcommits the budget.
    #[must_use]
    pub fn max_workers_within_memory(&self, pinned: bool) -> usize {
        let per_worker = self.per_worker_est_for_mode(pinned);
        // `per_worker` is `>= 1`, so the division is always defined; `checked_div` keeps the
        // strict `arithmetic_side_effects` lint satisfied without an unchecked `/`.
        let cap = self.mem_budget_kib.checked_div(per_worker).unwrap_or(0);
        usize::try_from(cap).unwrap_or(usize::MAX).max(1)
    }

    /// Resolve how many parallel worker children to run. Without `requested`, the count is the
    /// number of CPUs clamped down to what memory allows ([`max_workers_within_memory`]). An
    /// explicit `requested` (a `-j`/`--jobs` value) wins and is only floored at 1 — honoring the
    /// user's intent even past the memory cap; the caller is responsible for any overcommit
    /// warning (compare against [`max_workers_within_memory`]).
    ///
    /// [`max_workers_within_memory`]: Self::max_workers_within_memory
    #[must_use]
    pub fn worker_count(&self, pinned: bool, requested: Option<usize>) -> usize {
        resolve_worker_count(available_cpus(), self.max_workers_within_memory(pinned), requested)
    }

    /// The per-worker memory estimate, in KiB, the auto worker count divides the budget by for the
    /// given mode: the ~5 GiB realistic-peak estimate per-file, or the pinned ceiling under
    /// `--pinned` (a worker there holds the whole resident superset). Always `>= 1`. Public so the
    /// CLI can report the plan it derived (`W` workers × this estimate within the budget).
    #[must_use]
    pub fn per_worker_est_for_mode(&self, pinned: bool) -> u64 {
        let per_worker = if pinned {
            self.pinned_rss_ceiling_kib
        } else {
            self.per_worker_est_kib
        };
        per_worker.max(1)
    }
}

/// Detected CPU parallelism, floored at 1 when the platform cannot report it.
fn available_cpus() -> usize {
    std::thread::available_parallelism().map_or(1, std::num::NonZeroUsize::get)
}

/// Pure worker-count policy: an explicit `requested` wins (floored at 1); otherwise take the
/// CPU count clamped down to the memory cap. Split out from environment/CPU probing so the
/// clamp/override matrix is deterministically testable.
fn resolve_worker_count(cpus: usize, mem_cap: usize, requested: Option<usize>) -> usize {
    match requested {
        Some(n) => n.max(1),
        None => cpus.min(mem_cap).max(1),
    }
}

/// Best-effort memory readings that size the auto budget.
#[derive(Clone, Copy, Debug, Default)]
struct DetectedRam {
    /// Kernel estimate of memory allocatable without swapping — the preferred budget basis.
    available_kib: Option<u64>,
    /// Total physical RAM — the fallback basis when `available_kib` cannot be read.
    total_kib: Option<u64>,
}

/// Best-effort *available* RAM in KiB — memory the kernel believes can be allocated without
/// swapping, which (unlike total RAM) reflects current load so a busy machine is not overcommitted.
/// Reads `MemAvailable` from `/proc/meminfo` on Linux and sums the free + inactive page classes
/// from `vm_stat` on macOS. Returns `None` on any other platform or on any read/parse failure, in
/// which case the budget falls back to a fraction of total RAM. Never panics.
fn detect_available_ram_kib() -> Option<u64> {
    #[cfg(target_os = "linux")]
    {
        let meminfo = std::fs::read_to_string("/proc/meminfo").ok()?;
        // A `MemAvailable:   9876543 kB` line — value already in KiB. Absent on ancient kernels,
        // in which case we return `None` and the total-RAM fallback applies.
        for line in meminfo.lines() {
            if let Some(rest) = line.strip_prefix("MemAvailable:") {
                let kib = rest.split_whitespace().next()?.parse::<u64>().ok()?;
                return (kib >= 1).then_some(kib);
            }
        }
        None
    }
    #[cfg(target_os = "macos")]
    {
        // `vm_stat` reports a page size and per-class page counts. "Available" here is the free +
        // inactive classes (inactive pages are reclaimable without swapping); it deliberately omits
        // active/wired/compressed. A conservative estimate — it errs toward fewer workers.
        let output = std::process::Command::new("vm_stat").output().ok()?;
        if !output.status.success() {
            return None;
        }
        let text = std::str::from_utf8(&output.stdout).ok()?;
        let page_size = parse_vm_stat_page_size(text)?;
        let free = parse_vm_stat_pages(text, "Pages free:")?;
        let inactive = parse_vm_stat_pages(text, "Pages inactive:")?;
        let bytes = free.saturating_add(inactive).saturating_mul(page_size);
        (bytes >= 1024).then_some(bytes / 1024)
    }
    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    {
        None
    }
}

/// Parse the page size (in bytes) from a `vm_stat` header line like
/// `Mach Virtual Memory Statistics: (page size of 16384 bytes)`.
#[cfg(target_os = "macos")]
fn parse_vm_stat_page_size(text: &str) -> Option<u64> {
    let marker = "page size of ";
    let start = text.find(marker)?.checked_add(marker.len())?;
    let rest = text.get(start..)?;
    let digits: String = rest.chars().take_while(char::is_ascii_digit).collect();
    digits.parse::<u64>().ok().filter(|&n| n >= 1)
}

/// Parse a `vm_stat` page-count line like `Pages free:   123456.` (trailing period, dot-free
/// integer). Returns the page count for the given `label` prefix.
#[cfg(target_os = "macos")]
fn parse_vm_stat_pages(text: &str, label: &str) -> Option<u64> {
    for line in text.lines() {
        if let Some(rest) = line.trim_start().strip_prefix(label) {
            let digits: String = rest.chars().filter(char::is_ascii_digit).collect();
            return digits.parse::<u64>().ok();
        }
    }
    None
}

/// Best-effort total physical RAM in KiB. Reads `/proc/meminfo` on Linux and `hw.memsize` via
/// a single `sysctl` call on macOS; returns `None` on any other platform or on any read/parse
/// failure, in which case the memory budget falls back to its fixed floor. Never panics.
fn detect_total_ram_kib() -> Option<u64> {
    #[cfg(target_os = "linux")]
    {
        let meminfo = std::fs::read_to_string("/proc/meminfo").ok()?;
        // A `MemTotal:      16384000 kB` line — value already in KiB.
        for line in meminfo.lines() {
            if let Some(rest) = line.strip_prefix("MemTotal:") {
                let kib = rest.split_whitespace().next()?.parse::<u64>().ok()?;
                return (kib >= 1).then_some(kib);
            }
        }
        None
    }
    #[cfg(target_os = "macos")]
    {
        let output = std::process::Command::new("sysctl")
            .args(["-n", "hw.memsize"])
            .output()
            .ok()?;
        if !output.status.success() {
            return None;
        }
        let bytes = std::str::from_utf8(&output.stdout).ok()?.trim().parse::<u64>().ok()?;
        (bytes >= 1024).then_some(bytes / 1024)
    }
    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    {
        None
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

    #[test]
    fn pinned_ceiling_defaults_and_overrides() {
        assert_eq!(budget_from(&[]).pinned_rss_ceiling_kib, 16 * 1024 * 1024);
        assert_eq!(
            budget_from(&[("LEAN_FMT_PINNED_RSS_KIB", "12582912")]).pinned_rss_ceiling_kib,
            12_582_912
        );
        // A malformed value falls back to the default.
        assert_eq!(
            budget_from(&[("LEAN_FMT_PINNED_RSS_KIB", "nope")]).pinned_rss_ceiling_kib,
            16 * 1024 * 1024
        );
    }

    #[test]
    fn mem_budget_defaults_to_fixed_floor_without_detection() {
        // `resolve` injects no detected RAM, so the budget is the fixed 8 GiB floor.
        assert_eq!(budget_from(&[]).mem_budget_kib, 8 * 1024 * 1024);
    }

    #[test]
    fn mem_budget_prefers_available_minus_reserve() {
        // 20 GiB available → budget is available minus the 2 GiB reserve; total is ignored when
        // available is present.
        let budget = LeanResourceBudget::resolve_with(
            |_| None,
            DetectedRam {
                available_kib: Some(20 * 1024 * 1024),
                total_kib: Some(64 * 1024 * 1024),
            },
        );
        assert_eq!(budget.mem_budget_kib, 20 * 1024 * 1024 - 2 * 1024 * 1024);
    }

    #[test]
    fn mem_budget_falls_back_to_fraction_of_total_when_available_unknown() {
        // No available reading → 60% of total.
        let budget = LeanResourceBudget::resolve_with(
            |_| None,
            DetectedRam {
                available_kib: None,
                total_kib: Some(32 * 1024 * 1024),
            },
        );
        assert_eq!(budget.mem_budget_kib, (32 * 1024 * 1024) / 10 * 6);
    }

    #[test]
    fn tiny_available_memory_never_underflows_the_reserve() {
        // Available below the reserve saturates to 0, which the `>= 1` filter rejects, so the
        // total fallback applies rather than a wrapped-around huge budget.
        let budget = LeanResourceBudget::resolve_with(
            |_| None,
            DetectedRam {
                available_kib: Some(1024),
                total_kib: Some(32 * 1024 * 1024),
            },
        );
        assert_eq!(budget.mem_budget_kib, (32 * 1024 * 1024) / 10 * 6);
    }

    #[test]
    fn explicit_mem_budget_overrides_detection() {
        let budget = LeanResourceBudget::resolve_with(
            |key| (key == "LEAN_FMT_MEM_BUDGET_KIB").then(|| "1000000".to_owned()),
            DetectedRam {
                available_kib: Some(64 * 1024 * 1024),
                total_kib: Some(64 * 1024 * 1024),
            },
        );
        assert_eq!(budget.mem_budget_kib, 1_000_000);
    }

    #[test]
    fn per_worker_est_defaults_to_post_job_and_overrides() {
        // Default estimate is the post-job threshold (5 GiB), not the 2 GiB soft ceiling.
        assert_eq!(budget_from(&[]).per_worker_est_kib, 5 * 1024 * 1024);
        // Explicit override wins.
        assert_eq!(
            budget_from(&[("LEAN_FMT_WORKER_EST_KIB", "3145728")]).per_worker_est_kib,
            3_145_728
        );
    }

    #[test]
    fn max_workers_within_memory_divides_budget_by_per_worker_estimate() {
        // 20 GiB budget / 5 GiB per-file estimate = 4 workers; pinned uses the 16 GiB ceiling, so
        // the same budget admits only 1.
        let budget = budget_from(&[("LEAN_FMT_MEM_BUDGET_KIB", "20971520")]);
        assert_eq!(budget.max_workers_within_memory(false), 4);
        assert_eq!(budget.max_workers_within_memory(true), 1);
        // The 8 GiB default floor / 5 GiB estimate = 1 worker (no accidental overcommit).
        assert_eq!(budget_from(&[]).max_workers_within_memory(false), 1);
    }

    #[test]
    fn max_workers_within_memory_is_never_zero() {
        // A tiny budget below one per-worker ceiling still yields one worker.
        let budget = budget_from(&[("LEAN_FMT_MEM_BUDGET_KIB", "1")]);
        assert_eq!(budget.max_workers_within_memory(false), 1);
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn vm_stat_parsers_read_page_size_and_counts() {
        let sample = "Mach Virtual Memory Statistics: (page size of 16384 bytes)\n\
             Pages free:                   123456.\n\
             Pages active:                 999999.\n\
             Pages inactive:               65432.\n\
             Pages wired down:             111111.\n";
        assert_eq!(parse_vm_stat_page_size(sample), Some(16384));
        assert_eq!(parse_vm_stat_pages(sample, "Pages free:"), Some(123_456));
        assert_eq!(parse_vm_stat_pages(sample, "Pages inactive:"), Some(65_432));
        assert_eq!(parse_vm_stat_pages(sample, "Pages missing:"), None);
    }

    #[test]
    fn resolve_worker_count_matrix() {
        // Auto: CPUs clamped down to the memory cap.
        assert_eq!(resolve_worker_count(8, 4, None), 4);
        assert_eq!(resolve_worker_count(2, 4, None), 2);
        assert_eq!(resolve_worker_count(0, 4, None), 1);
        // Explicit request wins, floored at 1, even past the memory cap (overcommit is the
        // caller's to warn about).
        assert_eq!(resolve_worker_count(8, 4, Some(16)), 16);
        assert_eq!(resolve_worker_count(8, 4, Some(0)), 1);
        assert_eq!(resolve_worker_count(8, 4, Some(1)), 1);
    }
}
