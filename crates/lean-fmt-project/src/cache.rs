//! The incremental result cache: reuse a file's analysis/formatting result only when
//! every semantic input that could change that result is unchanged.
//!
//! Freshness is decided by a [`CacheKey`] built from exactly the inputs that can change a
//! file's formatted output — formatter version, the rule-affecting config, the Lean
//! toolchain, the source text, its imports, the runtime source digest, and the requested
//! validation mode — and nothing else. An unrelated file, a README, or workspace git
//! dirtiness never invalidates an entry (the lean-dup cache-lifecycle contract: track only
//! the inputs that can change semantic rows, not broad repository dirtiness).
//!
//! The load-bearing guarantee for [`safe_apply`](crate::safe_apply): the **validation mode
//! and the rule config are both part of the key**, so a cache hit can never let a stale
//! result skip validation after the rules (or the requested check strength) changed — the
//! key differs, the lookup is [`CacheMiss::Stale`], and the pipeline must recompute.
//!
//! The store itself is a content-addressed directory: one JSON entry per cached *identity*
//! (a stable name for "what we cached" — normally a file's root-relative path), holding the
//! [`CacheKey`] alongside the serialized value. A lookup that finds a mismatching key
//! reports *which* inputs changed ([`InvalidationReason`]) rather than a bare miss, so the
//! `--no-cache`/telemetry surface can explain why work was redone.

use std::path::PathBuf;

use serde::Serialize;
use serde::de::DeserializeOwned;
use sha2::{Digest, Sha256};

use crate::config::FormatterConfig;
use crate::error::{Error, Result};

/// The semantic inputs that decide whether a cached per-file result is still valid.
///
/// Two keys are equal iff **every** field matches; any difference is a real invalidation
/// (see [`CacheKey::differences`]). The field set is deliberately closed: only inputs that
/// can change a single file's formatted output participate, so unrelated repository churn
/// does not force a rebuild.
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct CacheKey {
    /// The formatter (CLI/crate) version — a new formatter may format differently.
    pub formatter_version: String,
    /// Digest of the rule-affecting config (see [`config_fingerprint`]).
    pub config_fingerprint: String,
    /// The requested Lean toolchain label — elaboration may differ across toolchains.
    pub toolchain_label: String,
    /// Digest of the source text itself.
    pub source_digest: String,
    /// The file's deduplicated, sorted imports — a changed import set can change layout.
    pub imports: Vec<String>,
    /// The in-repo Lean runtime source digest — the extractor/validator code that produced
    /// the result may have changed.
    pub runtime_source_digest: String,
    /// The validation mode the result was produced under. Part of the key so a weaker
    /// cached result never satisfies a stronger requested check.
    pub validation_mode: String,
}

impl CacheKey {
    /// Build a key from its parts, normalizing `imports` (sorted + deduplicated) so that a
    /// reordered or repeated import list produces the same key.
    #[must_use]
    pub fn new(
        formatter_version: impl Into<String>,
        config_fingerprint: impl Into<String>,
        toolchain_label: impl Into<String>,
        source_digest: impl Into<String>,
        imports: Vec<String>,
        runtime_source_digest: impl Into<String>,
        validation_mode: impl Into<String>,
    ) -> Self {
        let mut imports = imports;
        imports.sort();
        imports.dedup();
        Self {
            formatter_version: formatter_version.into(),
            config_fingerprint: config_fingerprint.into(),
            toolchain_label: toolchain_label.into(),
            source_digest: source_digest.into(),
            imports,
            runtime_source_digest: runtime_source_digest.into(),
            validation_mode: validation_mode.into(),
        }
    }

    /// The inputs by which `self` differs from `other`, in field order. Empty iff the keys
    /// are equal. Used to explain a [`CacheMiss::Stale`] — "the config changed", not just
    /// "miss".
    #[must_use]
    pub fn differences(&self, other: &Self) -> Vec<InvalidationReason> {
        let mut reasons = Vec::new();
        if self.formatter_version != other.formatter_version {
            reasons.push(InvalidationReason::FormatterVersion);
        }
        if self.config_fingerprint != other.config_fingerprint {
            reasons.push(InvalidationReason::Config);
        }
        if self.toolchain_label != other.toolchain_label {
            reasons.push(InvalidationReason::Toolchain);
        }
        if self.source_digest != other.source_digest {
            reasons.push(InvalidationReason::Source);
        }
        if self.imports != other.imports {
            reasons.push(InvalidationReason::Imports);
        }
        if self.runtime_source_digest != other.runtime_source_digest {
            reasons.push(InvalidationReason::RuntimeDigest);
        }
        if self.validation_mode != other.validation_mode {
            reasons.push(InvalidationReason::ValidationMode);
        }
        reasons
    }
}

/// Which semantic input changed, making a cached entry stale.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum InvalidationReason {
    /// The formatter version changed.
    FormatterVersion,
    /// The rule-affecting configuration changed.
    Config,
    /// The Lean toolchain changed.
    Toolchain,
    /// The source text changed.
    Source,
    /// The file's import set changed.
    Imports,
    /// The in-repo Lean runtime source digest changed.
    RuntimeDigest,
    /// The requested validation mode changed.
    ValidationMode,
}

/// Fingerprint the rule-affecting fields of a [`FormatterConfig`].
///
/// Only fields that change a *single file's formatted output* are hashed: `line_width` and
/// the rule selection (`select`/`ignore`/`per_file_ignores`). `include`/`exclude` are
/// discovery filters — they decide *which* files are processed, not how a given file is
/// formatted — so they are intentionally excluded, matching the lean-dup rule that only
/// inputs which can change semantic rows belong in the key.
#[must_use]
pub fn config_fingerprint(config: &FormatterConfig) -> String {
    // A deterministic, canonical description of just the output-affecting fields.
    // `per_file_ignores` is a `BTreeMap`, so its serialization is already key-ordered.
    let material = serde_json::json!({
        "line_width": config.line_width,
        "select": config.select,
        "ignore": config.ignore,
        "per_file_ignores": config.per_file_ignores,
    });
    // `to_string` on a `serde_json::Value` object emits keys in sorted order, so this is
    // stable across runs regardless of insertion order.
    hex_sha256(material.to_string().as_bytes())
}

/// Digest arbitrary source text for use as [`CacheKey::source_digest`].
#[must_use]
pub fn source_digest(source: &str) -> String {
    hex_sha256(source.as_bytes())
}

/// The outcome of a cache lookup: a hit carrying the reused value, or a typed miss.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CacheLookup<T> {
    /// The stored entry's key matches: the value may be reused.
    Hit(T),
    /// No reusable value; the variant explains why the result must be recomputed.
    Miss(CacheMiss),
}

/// Why a cache lookup did not yield a reusable value.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CacheMiss {
    /// The cache is disabled (`--no-cache`): never read, never written.
    Disabled,
    /// No entry exists for this identity yet.
    Absent,
    /// An entry exists but could not be read or decoded — treated as a miss, not an error.
    Corrupt,
    /// An entry exists but its key differs; the listed inputs changed.
    Stale(Vec<InvalidationReason>),
}

/// A content-addressed on-disk store of per-identity results guarded by a [`CacheKey`].
///
/// Enabled by default; [`FormatCache::disabled`] (wired to `--no-cache`) turns every lookup
/// into [`CacheMiss::Disabled`] and every store into a no-op, so the pipeline runs exactly
/// as if no cache existed. The store performs no cleanup and holds no in-memory index — it
/// is a thin, deterministic mapping from identity to a single JSON entry.
#[derive(Clone, Debug)]
pub struct FormatCache {
    root: PathBuf,
    enabled: bool,
}

/// The on-disk shape of one cache entry: the guarding key plus the cached value.
#[derive(serde::Serialize, serde::Deserialize)]
struct CacheEntry<T> {
    key: CacheKey,
    value: T,
}

impl FormatCache {
    /// An enabled cache rooted at `root`. Entry files live directly under it; the directory
    /// is created lazily on the first successful [`store`](Self::store).
    #[must_use]
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self {
            root: root.into(),
            enabled: true,
        }
    }

    /// A disabled cache: every lookup misses with [`CacheMiss::Disabled`] and every store is
    /// a no-op. This is the `--no-cache` behavior.
    #[must_use]
    pub fn disabled(root: impl Into<PathBuf>) -> Self {
        Self {
            root: root.into(),
            enabled: false,
        }
    }

    /// Whether this cache reads and writes (`false` under `--no-cache`).
    #[must_use]
    pub fn is_enabled(&self) -> bool {
        self.enabled
    }

    /// The entry file path for `identity` — content-addressed so identities never collide
    /// on the filesystem and no path detail of the identity leaks into the directory layout.
    fn entry_path(&self, identity: &str) -> PathBuf {
        self.root.join(format!("{}.json", hex_sha256(identity.as_bytes())))
    }

    /// Look up the cached value for `identity`, valid only under `key`.
    ///
    /// Returns [`CacheLookup::Hit`] when a stored entry's key matches `key`, and otherwise a
    /// [`CacheLookup::Miss`] whose [`CacheMiss`] says why: disabled, absent, unreadable
    /// (corrupt), or stale with the exact inputs that changed. A corrupt or unreadable entry
    /// is a miss, never an error — the pipeline just recomputes.
    #[must_use]
    pub fn lookup<T: DeserializeOwned>(&self, identity: &str, key: &CacheKey) -> CacheLookup<T> {
        if !self.enabled {
            return CacheLookup::Miss(CacheMiss::Disabled);
        }
        let path = self.entry_path(identity);
        let bytes = match std::fs::read(&path) {
            Ok(bytes) => bytes,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                return CacheLookup::Miss(CacheMiss::Absent);
            }
            Err(_) => return CacheLookup::Miss(CacheMiss::Corrupt),
        };
        let entry: CacheEntry<T> = match serde_json::from_slice(&bytes) {
            Ok(entry) => entry,
            Err(_) => return CacheLookup::Miss(CacheMiss::Corrupt),
        };
        let differences = key.differences(&entry.key);
        if differences.is_empty() {
            CacheLookup::Hit(entry.value)
        } else {
            CacheLookup::Miss(CacheMiss::Stale(differences))
        }
    }

    /// Store `value` for `identity`, guarded by `key`. A no-op on a disabled cache.
    ///
    /// # Errors
    /// Returns [`Error::Io`] if the cache directory cannot be created or the entry cannot be
    /// written.
    pub fn store<T: Serialize>(&self, identity: &str, key: &CacheKey, value: T) -> Result<()> {
        if !self.enabled {
            return Ok(());
        }
        std::fs::create_dir_all(&self.root).map_err(|source| Error::Io {
            message: "could not create cache directory",
            path: self.root.clone(),
            source,
        })?;
        let entry = CacheEntry {
            key: key.clone(),
            value,
        };
        let path = self.entry_path(identity);
        let bytes = serde_json::to_vec(&entry).map_err(|source| Error::Cache {
            message: "could not serialize cache entry",
            source: Box::new(source),
        })?;
        std::fs::write(&path, bytes).map_err(|source| Error::Io {
            message: "could not write cache entry",
            path,
            source,
        })
    }
}

/// Lowercase hex SHA-256 of `bytes`.
fn hex_sha256(bytes: &[u8]) -> String {
    use std::fmt::Write as _;
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    let mut out = String::new();
    for byte in hasher.finalize() {
        let _ = write!(out, "{byte:02x}");
    }
    out
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::indexing_slicing, clippy::panic)]

    use super::{CacheKey, CacheLookup, CacheMiss, FormatCache, InvalidationReason, config_fingerprint, source_digest};
    use crate::config::FormatterConfig;

    /// A baseline key; helpers below vary exactly one field to prove that input is tracked.
    fn base_key() -> CacheKey {
        CacheKey::new(
            "0.1.0",
            config_fingerprint(&FormatterConfig::default()),
            "leanprover/lean4:v4.32.0-rc1",
            source_digest("import Init\ndef a := 1\n"),
            vec!["Init".to_owned()],
            "runtime-digest-abc",
            "Syntax",
        )
    }

    #[test]
    fn stored_value_is_reused_on_an_identical_key() {
        let dir = tempfile::tempdir().unwrap();
        let cache = FormatCache::new(dir.path());
        let key = base_key();
        cache.store("Foo.lean", &key, "formatted output".to_owned()).unwrap();
        match cache.lookup::<String>("Foo.lean", &key) {
            CacheLookup::Hit(value) => assert_eq!(value, "formatted output"),
            CacheLookup::Miss(miss) => panic!("expected a hit, got {miss:?}"),
        }
    }

    #[test]
    fn a_config_change_invalidates_and_never_hits() {
        // The load-bearing case: after the rule config changes, a stored result must NOT be
        // reused — otherwise a cache hit could skip re-validation of a differently-formatted
        // file. The lookup is Stale(Config), not a Hit.
        let dir = tempfile::tempdir().unwrap();
        let cache = FormatCache::new(dir.path());
        cache.store("Foo.lean", &base_key(), "old".to_owned()).unwrap();

        let changed_config = FormatterConfig {
            select: vec!["imports".to_owned()],
            ..FormatterConfig::default()
        };
        let key = CacheKey::new(
            "0.1.0",
            config_fingerprint(&changed_config),
            "leanprover/lean4:v4.32.0-rc1",
            source_digest("import Init\ndef a := 1\n"),
            vec!["Init".to_owned()],
            "runtime-digest-abc",
            "Syntax",
        );
        match cache.lookup::<String>("Foo.lean", &key) {
            CacheLookup::Miss(CacheMiss::Stale(reasons)) => {
                assert_eq!(reasons, vec![InvalidationReason::Config]);
            }
            CacheLookup::Hit(value) => panic!("config change must invalidate, got Hit({value:?})"),
            CacheLookup::Miss(miss) => panic!("config change must be Stale, got {miss:?}"),
        }
    }

    #[test]
    fn a_validation_mode_change_invalidates_so_validation_is_not_skipped() {
        // The stop-rule guard: a result cached under Syntax must not satisfy an Elab request.
        let dir = tempfile::tempdir().unwrap();
        let cache = FormatCache::new(dir.path());
        cache.store("Foo.lean", &base_key(), "cached".to_owned()).unwrap();

        let mut elab_key = base_key();
        elab_key.validation_mode = "Elab".to_owned();
        match cache.lookup::<String>("Foo.lean", &elab_key) {
            CacheLookup::Miss(CacheMiss::Stale(reasons)) => {
                assert_eq!(reasons, vec![InvalidationReason::ValidationMode]);
            }
            CacheLookup::Hit(value) => panic!("a stronger validation mode must miss, got Hit({value:?})"),
            CacheLookup::Miss(miss) => panic!("validation-mode change must be Stale, got {miss:?}"),
        }
    }

    #[test]
    fn source_toolchain_and_runtime_digest_changes_each_invalidate() {
        let dir = tempfile::tempdir().unwrap();
        let cache = FormatCache::new(dir.path());
        cache.store("Foo.lean", &base_key(), "v".to_owned()).unwrap();

        let mut source_changed = base_key();
        source_changed.source_digest = source_digest("import Init\ndef a := 2\n");
        assert!(matches!(
            cache.lookup::<String>("Foo.lean", &source_changed),
            CacheLookup::Miss(CacheMiss::Stale(ref r)) if r == &[InvalidationReason::Source]
        ));

        let mut toolchain_changed = base_key();
        toolchain_changed.toolchain_label = "leanprover/lean4:v4.33.0".to_owned();
        assert!(matches!(
            cache.lookup::<String>("Foo.lean", &toolchain_changed),
            CacheLookup::Miss(CacheMiss::Stale(ref r)) if r == &[InvalidationReason::Toolchain]
        ));

        let mut runtime_changed = base_key();
        runtime_changed.runtime_source_digest = "runtime-digest-xyz".to_owned();
        assert!(matches!(
            cache.lookup::<String>("Foo.lean", &runtime_changed),
            CacheLookup::Miss(CacheMiss::Stale(ref r)) if r == &[InvalidationReason::RuntimeDigest]
        ));
    }

    #[test]
    fn an_unrelated_file_does_not_invalidate_this_files_entry() {
        // Storing a second, different file leaves the first file's entry a clean hit —
        // freshness is per-identity, never workspace-wide dirtiness.
        let dir = tempfile::tempdir().unwrap();
        let cache = FormatCache::new(dir.path());
        let key = base_key();
        cache.store("Foo.lean", &key, "foo".to_owned()).unwrap();

        let mut other = base_key();
        other.source_digest = source_digest("entirely different\n");
        cache.store("Bar.lean", &other, "bar".to_owned()).unwrap();

        match cache.lookup::<String>("Foo.lean", &key) {
            CacheLookup::Hit(value) => assert_eq!(value, "foo"),
            CacheLookup::Miss(miss) => panic!("an unrelated file must not invalidate, got {miss:?}"),
        }
    }

    #[test]
    fn multiple_changed_inputs_report_all_reasons_in_order() {
        let key = base_key();
        let mut changed = base_key();
        changed.source_digest = source_digest("different\n");
        changed.validation_mode = "Elab".to_owned();
        assert_eq!(
            key.differences(&changed),
            vec![InvalidationReason::Source, InvalidationReason::ValidationMode],
        );
    }

    #[test]
    fn imports_are_order_insensitive() {
        // A reordered/duplicated import list is the same semantic input, so the same key.
        let a = CacheKey::new(
            "0.1.0",
            "cfg",
            "tc",
            "src",
            vec!["B".to_owned(), "A".to_owned(), "A".to_owned()],
            "rt",
            "Syntax",
        );
        let b = CacheKey::new(
            "0.1.0",
            "cfg",
            "tc",
            "src",
            vec!["A".to_owned(), "B".to_owned()],
            "rt",
            "Syntax",
        );
        assert_eq!(a, b);
        assert!(a.differences(&b).is_empty());
    }

    #[test]
    fn a_disabled_cache_never_reads_or_writes() {
        let dir = tempfile::tempdir().unwrap();
        let key = base_key();
        // A no-cache store is a silent no-op...
        let cache = FormatCache::disabled(dir.path());
        cache.store("Foo.lean", &key, "value".to_owned()).unwrap();
        assert!(matches!(
            cache.lookup::<String>("Foo.lean", &key),
            CacheLookup::Miss(CacheMiss::Disabled)
        ));
        // ...and it wrote nothing to disk that an enabled cache could later find.
        let enabled = FormatCache::new(dir.path());
        assert!(matches!(
            enabled.lookup::<String>("Foo.lean", &key),
            CacheLookup::Miss(CacheMiss::Absent)
        ));
    }

    #[test]
    fn an_absent_entry_misses_cleanly() {
        let dir = tempfile::tempdir().unwrap();
        let cache = FormatCache::new(dir.path());
        assert!(matches!(
            cache.lookup::<String>("Never.lean", &base_key()),
            CacheLookup::Miss(CacheMiss::Absent)
        ));
    }

    #[test]
    fn a_corrupt_entry_misses_rather_than_erroring() {
        let dir = tempfile::tempdir().unwrap();
        let cache = FormatCache::new(dir.path());
        let key = base_key();
        cache.store("Foo.lean", &key, "value".to_owned()).unwrap();
        // Corrupt the on-disk entry.
        let path = dir.path().join(format!("{}.json", super::hex_sha256(b"Foo.lean")));
        std::fs::write(&path, b"{ not valid json").unwrap();
        assert!(matches!(
            cache.lookup::<String>("Foo.lean", &key),
            CacheLookup::Miss(CacheMiss::Corrupt)
        ));
    }

    #[test]
    fn config_fingerprint_ignores_discovery_filters_but_tracks_rules() {
        let base = FormatterConfig::default();
        // include/exclude are discovery filters — they don't change a file's output.
        let discovery_only = FormatterConfig {
            include: vec!["Src".to_owned()],
            exclude: vec!["Vendor".to_owned()],
            ..FormatterConfig::default()
        };
        assert_eq!(config_fingerprint(&base), config_fingerprint(&discovery_only));
        // A rule selection change does change the fingerprint.
        let rules_changed = FormatterConfig {
            select: vec!["imports".to_owned()],
            ..FormatterConfig::default()
        };
        assert_ne!(config_fingerprint(&base), config_fingerprint(&rules_changed));
    }
}
