# RCD-SPEC — hierarchical discovery, explicit inheritance, ignore sources, and sectioned schema

This note **freezes the interface** ruff-13 implements. It is the design; `RCD-IMPL`
(`02-implementation`) wires it and `RCD-FINAL` (`03-acceptance`) audits it. Where a decision changes
today's observable behavior, that is called out explicitly and the owning characterization test named,
so `RCD-IMPL` changes exactly what the freeze says and nothing else.

Everything here is read off live code at commit `62e23fa`, cited by `file:line`. The measured baseline
transcript is `evidence/01-discovery-baseline.md`.

Following the `*-SPEC` convention (`ruff-11` RMR-SPEC, `ruff-12` RRL-SPEC), **no production Lean
interface, config key, or CLI surface ships in this prompt.** The freeze is this note plus the recorded
baseline.

---

## 1. Scope, and what this stack does **not** own

ruff-13 owns: **which files are recognized as configuration**, the **discovery walk** and its root
boundary, **closest-config selection** per file, **explicit inheritance** (`extend`) with cycle
detection and path resolution, the **`[format]`/`[lint]` section split** and its migration from
today's flat schema, **ignore sources** (`.gitignore`, `.ignore`, repository excludes, global
ignores) and their precedence, **explicit-path behavior** and `force-exclude`, **provenance
introspection** (`config show`), and the **cache-identity consequence** of promoting the render margin
to a runtime key.

It does **not** own, and this note must not design:

- Rule lifecycle, the selector algebra, the preview gate, or fixability configuration — those are
  `ruff-12` (verified; `ruff-12-rule-lifecycle/notes/01-schema.md`). ruff-13 **relocates** those keys
  into `[lint]` and changes nothing about how they resolve.
- Output/report formats — `ruff-15-reporting`.
- stdin/stdout and `--range` — `ruff-14-stream-range`. `config show` takes a real path only.
- Watch/incremental rediscovery of configuration — `ruff-16-watch-incremental`. This stack resolves
  configuration once per run; a long-lived `serve` session's re-read policy is ruff-16's.
- Any execution-strategy, worker, or superset-parsing change (roadmap stop rules).

Two load-bearing invariants this stack must not break:

- **Rule selection is a projection over canonical results; it must not enter execution strategy or
  result-cache identity** (`CLAUDE.md`). §9 makes this sharper rather than weaker: `[format]` settings
  are identity-bearing because they change canonical bytes; `[lint]` settings remain a pure projection.
- **Executable Lake configuration remains separately evaluated** (roadmap stop rule). Discovery reads
  `lean-fmt.toml`; it never infers package structure, search paths, or module setup from TOML.
  `Project.loadWorkspace` (`Project.lean:57-80`) stays the sole authority on project semantics.

---

## 2. Baseline, read off live code

| Fact | Live location |
| --- | --- |
| One config file, at the project root only: `root / "lean-fmt.toml"` | `Config.lean:298` |
| An explicit `--config PATH` must exist; an absent conventional file is the default policy, not an error | `Config.lean:296-306` |
| Schema is **flat** — 12 top-level keys, no sections | `Config.lean:182-217` |
| Unknown key is a hard error (`unknown configuration key: …`) | `Config.lean:216` |
| `include`/`exclude` use segment-wise `PathPattern`, not git semantics: no anchoring, no `!` negation, `**` must be a whole component | `Config.lean:73-108` |
| Selection filter, root-relative, excludes win, empty `include` means everything | `Config.lean:311-314` |
| `.lake` is skipped **during discovery only** | `Project.lean:113-116` |
| Explicit requested paths are checked for existence, root containment, and `.lean` extension — **and nothing else** | `Project.lean:122-160`, `Project.lean:94-106` |
| `format` **writes** the selected set in place by default | `ruff-11d` FIP-FINAL |
| Per-target cache identity, the seam a runtime margin must enter | `Project.configurationIdentity`, `Project.lean:296-307`; consumed at `Cache.lean:200-210` |
| Render margin is the compile-time constant `canonicalWidth := 100` | `Application.lean:382` |
| Config load sites: batch run, organize, service | `Application.lean:1036`, `Application.lean:1184`, `Service.lean:174` |
| Generated JSON schema enumerating every accepted key | `Rules.lean:1193-1231` (`catalogSchemaJson`) |
| Characterization test for the flat schema | `LeanFmtTest.lean:415-470` (`testConfig`) |

### 2.1 Two baseline defects this stack inherits

**(a) An explicit path into `.lake` is accepted, and `format` writes it.** Discovery filters `.lake`
(`Project.lean:114`) but the requested-path branch does not. Measured
(`evidence/01-discovery-baseline.md` §3): `lean-fmt format --root P .lake/packages/dep/Dep.lean`
reported `written=1` and modified a vendored dependency's source on disk. Since `ruff-11d` made
`format` a writer by default, this is a **write-safety defect**, not merely a reporting quirk. §11
makes `.lake` an absolute floor that no path form and no configuration can lift.

**(b) A stale docstring at `Application.lean:365-382`.** It justifies keeping the margin a constant by
citing `formatter := Digest.ofBytes (← IO.FS.readBinFile application)` at `Cache.lean:258`. Commit
`62e23fa` replaced that with binary *metadata* — `s!"{application} {byteSize} {modified.sec}
{modified.nsec}"` (`Cache.lean:262-264`). The docstring's *conclusion* survives (a rebuild rewrites the
file, so size/mtime still change whenever the constant could), but its cited mechanism no longer
exists. `RCD-IMPL` rewrites that docstring in the same commit that promotes `line-width` (§9).

---

## 3. Recognized configuration files

In one directory, in **descending** priority:

1. `.lean-fmt.toml`
2. `lean-fmt.toml`

Exactly one is used. If both exist in the same directory, that is a **hard error** naming both paths —
not a silent priority win. (Ruff warns and picks; a hard error is chosen here for the same reason
`extend-safe-fixes` ∩ `extend-unsafe-fixes` is an error rather than last-writer-wins,
`Config.lean:434-436`: a contradiction the user can trivially resolve should not resolve itself.)

`--config PATH` names a file directly and may have any name (unchanged from `Config.lean:296-306`).
§5.1 gives its effect on discovery.

### 3.1 Rejected: `lakefile.toml [tool.lean-fmt]`

The pyproject.toml analogue is available. **Measured** (`evidence/01-discovery-baseline.md` §2): Lake's
`lakefile.toml` decoder ignores unknown keys entirely — both an unknown `[tool.lean-fmt]` table and an
unknown top-level scalar loaded and built with exit 0 on v4.33.0-rc1. The decoders read known keys via
`t.decode`/`t.find?` (`Lake/Load/Toml.lean:405-421`, `gen_toml_decoders%`) with no reject-unknown pass.

Rejected anyway. That tolerance is **incidental and undocumented**: nothing in Lake promises it, and a
future Lake that validates its own schema would break every project that put lean-fmt settings there —
a failure in Lake's loader, reported against Lake, with no migration path we control. Config that lives
in a file another tool owns is only as durable as that tool's indifference. `lean-fmt.toml` costs one
file and owns its own validity.

This is a compatibility judgment, not a capability limit; §15 keeps it open for revisit if Lake ever
documents the `[tool.*]` namespace.

---

## 4. The discovery walk and its root boundary

### 4.1 Boundary

Configuration discovery **never ascends above the project root** (`--root`, realpath'd,
`Project.lean:135`). The root is the boundary because it is already the containment boundary for every
source (`insideRoot`, `Project.lean:90-92`) and the authority boundary for project semantics
(`loadWorkspace`). A run's behavior therefore depends only on the tree it was pointed at.

Two deliberate exceptions, both explicit:

- `extend` may name a path outside the root (§6). The user wrote that path; it is not discovery.
- **Repository** root detection for git ignore sources may ascend above the project root (§10), because
  a Lean project is commonly a subdirectory of a larger repository. It stops at the filesystem root.

### 4.2 One walk, not one walk per file

`RCD-IMPL`'s stop rule forbids repeated filesystem walks per file. The capability is therefore shaped
around the walk `Project.discoverPaths` (`Project.lean:113-116`) already performs:

- **A single `root.walkDir`** collects, in one pass: candidate `.lean` sources, recognized config files,
  and `.gitignore`/`.ignore` files, keyed by directory.
- That pass builds an in-memory **directory → (config?, ignoreFiles)** map.
- Resolving one file's effective configuration is then an **in-memory** ascent through that map from
  the file's directory to the root. No syscall per file.
- Each distinct config file is **parsed once** and memoized by realpath; N files sharing a config
  resolve to the same parsed value. Composition results (§6) are memoized by the same key.

Directories pruned during the walk (`.lake`, and any directory ignored by §10 when
`respect-gitignore` is on) are not descended into, so an ignored subtree costs nothing.

---

## 5. Closest-config selection

For a file `F`, the **owning config** is the recognized config file (§3) in the nearest ancestor
directory of `F`, searching from `F`'s own directory upward, stopping at and including the project
root. If no ancestor has one, the effective configuration is the built-in default
(`Config.lean:167-181`) — an absent config remains "default policy", never an error
(`Config.lean:300-302`).

**Hierarchy does not merge.** The closest config applies *whole*; it does not inherit from configs
above it. Inheritance is explicit and only through `extend` (§6). This is the roadmap's "explicit
inheritance" and matches ruff. It is stated as a rule because the opposite (implicit ancestor merging)
is the intuitive guess and is what a reader will otherwise assume:

> A nested `lean-fmt.toml` **replaces** its ancestors for the subtree it governs. To build on the
> parent instead of replacing it, write `extend = "../lean-fmt.toml"`.

### 5.1 `--config` overrides discovery entirely

An explicit `--config PATH` makes that file the effective configuration for **every** file in the run.
No directory is searched, no nested config is consulted, and a nested config that exists is silently
inert (it is not an error to have one). This preserves today's meaning (`Config.lean:296`) and gives a
CI job one auditable input. `extend` inside an explicit config is still followed (§6).

### 5.2 Determinism

Effective configuration is a function of (project root, file path, `--config`, and the bytes of the
config files reachable from them). It never depends on the working directory, on argument order, or on
which other files are in the run.

---

## 6. `extend` — explicit inheritance

```toml
extend = "../shared/lean-fmt.toml"
```

- `extend` is a **single string**, top-level only. An array is a hard error. (One parent keeps the
  composition order total and the provenance answer unique; a diamond has no principled key-wise
  winner. §15 keeps multiple parents open.)
- The path is resolved **relative to the directory of the file that declares it** — never the project
  root, never the working directory, never the file being formatted. An absolute path is used as-is.
- The target must exist and parse. A missing `extend` target is a hard error naming the *declaring*
  file and the *unresolved* path as written, per the `CLAUDE.md` path-error rule.
- The target may be outside the project root (§4.1).
- The chain is resolved parent-first, then the child applied over it.

### 6.1 Cycle detection and depth

Each file in a chain is identified by **realpath**, so a symlinked alias of an ancestor is caught. A
repeat is a hard error printing the cycle in encounter order:

```
configuration extend cycle: a/lean-fmt.toml -> b/lean-fmt.toml -> a/lean-fmt.toml
```

Independently, a chain longer than **32** files is a hard error. Cycle detection alone terminates, so
this is a resource bound, not a correctness one.

### 6.2 Merge semantics

Applied per key, child over parent:

| Key shape | Composition | Keys |
| --- | --- | --- |
| Scalar | child **replaces** parent | `line-width`, `preview`, `force-exclude`, `respect-gitignore` |
| Base array | child **replaces** parent wholesale | `include`, `exclude`, `select`, `ignore`, `fixable`, `unfixable` |
| `extend-*` array | parent's, then child's, **concatenated** | `extend-select`, `extend-fixable`, `extend-safe-fixes`, `extend-unsafe-fixes` |
| Table | merged **key-wise**; child wins on an identical pattern string | `per-file-ignores` |
| `extend` | not inherited — each file's own `extend` names only its own parent | — |

Rationale: the `extend-*` family is *already* defined as additive within one file
(`Config.lean:427-428`, `Config.lean:446-447`), so concatenating across the chain is the same rule
applied to the same keys, not a new one. Base arrays replacing is what makes a child able to *narrow*
a parent at all.

Concatenation order is parent-then-child, and duplicates are **not** removed: `resolveAxis`
(`Config.lean:400-408`) folds with `Nat.max` over specificity, so a repeated token is idempotent. Order
and duplication are therefore unobservable in the resolved plan, and preserving them keeps provenance
(§12) able to name every file that contributed a token.

---

## 7. Path resolution for patterns

**Every path pattern is anchored at the directory of the config file that declares it.**

This is the rule the roadmap names ("paths resolved relative to their owning file") and it is the one
place a careless implementation silently does the wrong thing, because today's single root config makes
"relative to the declaring file" and "relative to the root" coincide (`Config.lean:311`,
`Project.lean:139`).

Concretely, for `include`, `exclude`, and `per-file-ignores` keys:

- The pattern matches against the candidate file's path **relative to the declaring config's
  directory**.
- A file that is not under the declaring config's directory **never matches** that config's patterns.
  This is reachable only via `--config` (§5.1) or `extend` (§6) pointing at a file elsewhere; in both
  cases the anchor stays the declaring file's directory, so an inherited `exclude = ["Generated/**"]`
  means "`Generated/**` under the *parent's* directory", not under the child's.

The last point is the one genuinely surprising consequence, and it is chosen deliberately: a pattern's
meaning must not change based on who inherited it, or a shared config becomes unreadable. §15 records
the alternative (re-anchor inherited patterns at the inheriting file) as rejected.

Pattern **syntax** for `include`/`exclude`/`per-file-ignores` is unchanged — today's `PathPattern`
(`Config.lean:73-108`). It is deliberately *not* upgraded to git semantics here: existing configs would
silently change meaning, and `PathPattern` is already validated, tested, and shared with
`per-file-ignores`. Git semantics apply only to git ignore *sources* (§10), which is where users
already expect them. The divergence is documented in the generated schema and in §15.

---

## 8. Sections, and migration from the flat schema

### 8.1 The sectioned schema

**Top level — discovery and cross-cutting policy:**

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `extend` | string | — | explicit parent config (§6) |
| `include` | string[] | `[]` (everything) | discovery whitelist (§11) |
| `exclude` | string[] | `[]` | discovery blacklist; beats `include` |
| `force-exclude` | bool | `false` | apply exclusions to explicitly named paths too (§11) |
| `respect-gitignore` | bool | `true` | honor the git ignore sources (§10) |
| `preview` | bool | `false` | unlock preview rules and preview formatter behavior |

`preview` stays **top-level**, where it already is (`Config.lean:207-210`), because it gates both rule
selection and future formatter behavior. It is not duplicated into a section.

**`[format]` — settings that change canonical bytes:**

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `line-width` | integer | `100` | the render margin (§9) |

**`[lint]` — settings that project over results:**

`select`, `extend-select`, `ignore`, `fixable`, `unfixable`, `extend-fixable`, `extend-safe-fixes`,
`extend-unsafe-fixes`, `per-file-ignores`. All types, validation, and resolution are exactly today's
(`Config.lean:182-217`, `Config.lean:412-470`); only their location changes.

The split is not cosmetic — it is the identity boundary of §9. A key's section answers "does this
change bytes or only which findings are shown", which is the question `Project.configurationIdentity`
must be able to ask.

### 8.2 Migration truth table

Every `[lint]` key remains accepted at the top level, so **every config valid today stays valid**. Let
`K` be a linter key (`select`, `ignore`, …).

| Top level | `[lint]` | Result | Diagnostic |
| --- | --- | --- | --- |
| absent | absent | default for `K` | — |
| absent | present | `[lint]` value | — |
| present | absent | top-level value | **deprecation notice** (non-fatal, stderr) |
| present | present | **hard error** | `configuration key 'K' is set both at the top level and in [lint]` |
| — | unknown key | **hard error** | `unknown configuration key: …` (unchanged, `Config.lean:216`) |
| unknown key | — | **hard error** | as above |
| `line-width` at top level | — | **hard error** | `configuration key 'line-width' belongs in the [format] section` |
| `[format]`/`[lint]` not a table | — | **hard error** | `configuration section '[format]' expects a table` |

Three rules govern that table:

1. **Both-set is a contradiction, not a precedence puzzle.** Same reasoning as §3 and as the existing
   `extend-safe`/`extend-unsafe` conflict (`Config.lean:434-436`).
2. **The deprecation notice rides the existing non-fatal channel.** `RulePlan.notices`
   (`Config.lean:66-70`) is already an array of strings the IO caller prints to stderr and which
   "never change exit status or which rules run" — migration notices join it and inherit that
   contract. `RCD-IMPL` must widen the channel to reach `[format]`/discovery notices too, which today's
   plan-shaped field cannot carry; that is an interface change, called out here so it is not invented
   mid-implementation.
3. **`line-width` is new, so it gets no flat spelling.** Accepting it at top level would create a key
   whose section is ambiguous from birth. This row is a hard error rather than a notice precisely
   because there is no legacy config to protect.

Migration is per-file: a flat parent and a sectioned child compose normally (§6.2), key by key, after
each file is independently normalized into the sectioned shape.

### 8.3 Generated schema and docs follow

`catalogSchemaJson` (`Rules.lean:1193-1231`) currently enumerates the flat key set with
`additionalProperties: false`. `RCD-IMPL` restructures it to the sectioned shape with the flat keys
retained and marked `deprecated: true`, and the drift check (`docs --check`,
`LeanFmtTest.lean:584`) keeps it honest. The schema stays generated from one source; no hand-written
key list appears anywhere.

---

## 9. `[format] line-width` and cache identity

### 9.1 The contract

`canonicalWidth := 100` (`Application.lean:382`) becomes the default of a runtime key. Since
`RLF-REFLOW`, the margin **does** change bytes — `Doc.go`'s `.group` fit test (`Doc.lean:219-229`)
breaks an over-margin application onto continuation lines — so this is an output-affecting runtime
input, the first one the product has.

**In the same commit that admits `[format] line-width`, the resolved margin is folded into
`Project.configurationIdentity`** (`Project.lean:296-307`), the per-target `configuration` component of
`CacheIdentity` (`Cache.lean:200-210`).

The argument the old docstring made — the binary hash covers the constant — does not survive
promotion, and it is worth being precise about why, because commit `62e23fa` already changed that
mechanism once (§2.1b). Formatter identity is now `(path, byteSize, mtime)` of the executable
(`Cache.lean:262-264`). A rebuild rewrites the file, so editing a *constant* still invalidates. A
*runtime* override changes output **without touching the binary at all**, so neither the old content
hash nor the new metadata digest can see it. Without a new identity input, two projects on one machine
at different widths would serve each other's cached `CanonicalText`.

### 9.2 The sharp rule

> A `[format]` key enters `configurationIdentity`. A `[lint]` key never does.

`[format]` settings change the canonical bytes a cache entry stores. `[lint]` settings change which
findings are shown from an unchanged canonical result — the projection discipline `CLAUDE.md` requires
and `ruff-12` preserved through the preview gate. The section split is what makes this rule checkable
by inspection instead of by argument, and `RCD-FINAL` tests both halves: a width change must miss the
cache, and a selection change must hit it.

### 9.3 Validation

`line-width` must be an integer with `1 ≤ n ≤ 1000`. Outside that range is a hard error naming the
bound. A non-integer (float, string, boolean) is a hard error naming the expected type. The upper bound
is a resource bound; the lower bound is where `Doc`'s fit test still has meaning.

### 9.4 Threading

`canonicalWidth` stops being a top-level constant and becomes the default of the resolved `[format]`
settings. `renderCanonicalText` (`Application.lean:392-396`) — today's sole production caller — takes
the resolved width from the effective configuration of the file being rendered. Tests that drive width
through `Printer.format`'s required parameter are unaffected.

---

## 10. Ignore sources and precedence

Active when `respect-gitignore = true` (default).

### 10.1 Sources, lowest to highest precedence

1. **Built-in floor**: `.lake` (§11). Not a git source; listed to fix its rank — nothing below can
   re-include it and nothing above can either.
2. **Global git ignore**: `core.excludesFile` from git configuration, else
   `${XDG_CONFIG_HOME:-~/.config}/git/ignore`.
3. **Repository excludes**: `<repo>/.git/info/exclude`.
4. **`.gitignore` files**, outermost directory first.
5. **`.ignore` files**, outermost first; at the *same* directory, `.ignore` outranks `.gitignore`
   (ripgrep's convention, which is what users of `.ignore` expect).
6. **Config `exclude`** (§11), which outranks every ignore source.

Within one file, the **last matching line wins** (git's rule), so a later `!` negation re-includes.
Between files, the **nearer** file wins.

**Git's directory-exclusion rule is preserved**: if a directory is excluded, a pattern cannot re-include
a file beneath it. This is not an optimization detail — it is observable behavior, and it is also what
makes pruning during the walk (§4.2) sound: a pruned directory can never contain a re-included file.

### 10.2 Reading git configuration without the `git` binary

`core.excludesFile` is read by parsing git's configuration files directly — `$GIT_CONFIG_GLOBAL`, else
`${XDG_CONFIG_HOME:-~/.config}/git/config`, else `~/.gitconfig` — for the single key `core.excludesfile`
(git config keys are case-insensitive in section/name). No subprocess is spawned.

Chosen so that lean-fmt does not require `git` on `PATH` to format a repository, and so that
discovery has no process-spawn cost per run. This is a deliberately **partial** git-config
implementation: `include`/`includeIf` directives and conditional includes are **not** followed. That
is a real limitation, stated rather than hidden — §15 tracks it, and a user whose `excludesFile` is
reachable only through an `includeIf` sees their global ignores not applied. Repository-local
`.git/info/exclude` needs no config parsing and is always found.

### 10.3 Repository root

The nearest ancestor of the project root containing `.git`, ascending to the filesystem root. `.git`
may be a **directory** or a **file** (a worktree or submodule gitlink, `gitdir: <path>`); the file form
is followed to locate `info/exclude`. Absent `.git`, sources 3–4 contribute nothing and source 2 still
applies.

---

## 11. Selection, explicit paths, and `force-exclude`

Since `ruff-11d`, this decides which files are **published**, not merely reported. The table below is
therefore a write-safety specification.

For a candidate path `F`, in order:

| # | Gate | Discovered `F` | Explicitly named `F` |
| --- | --- | --- | --- |
| 1 | under project root; extension `.lean`; **not under `.lake`** | applies | **applies** |
| 2 | git ignore sources (§10) | applies | skipped unless `force-exclude` |
| 3 | config `exclude` | applies | skipped unless `force-exclude` |
| 4 | config `include` (if non-empty, must match) | applies | **skipped always** |

**Gate 1 is absolute.** No configuration key, no `--config`, no explicit path, and no `force-exclude
= false` can lift it. `.lake` is Lake's build directory and vendored dependency tree; writing there
corrupts a build the user did not ask us to touch. This closes baseline defect (a) (§2.1): today an
explicit `.lake` path is accepted and `format` writes it (measured, `written=1`). `RCD-IMPL` moves the
`.lake` test out of `discoverPaths` (`Project.lean:114`) and into the shared containment check beside
`insideRoot`/extension (`Project.lean:94-106`), so both path forms pass through it. The error names the
caller's own argument, per `CLAUDE.md`:

```
selected file is inside the Lake build directory: .lake/packages/dep/Dep.lean
```

**Gate 4 is asymmetric on purpose.** `force-exclude` re-enables the *exclusions* (gates 2–3) for
explicit paths but never the `include` whitelist. `include` is a discovery whitelist — "when I say
nothing, format these" — whereas naming a path is saying something. A user who wants an explicitly
named file refused should `exclude` it. This asymmetry is the one judgment call in the table and is
flagged for `RCD-FINAL` to test in both directions.

`force-exclude` exists because `format` writes: a pre-commit hook that passes staged paths explicitly
must be able to say "still never write these", and today it cannot.

---

## 12. `config show PATH [--json]`

```
lean-fmt config show PATH [--root PATH] [--config PATH] [--json]
```

Resolves `PATH` exactly as a run would and prints the effective configuration **with provenance**.

- `PATH` is pre-checked and errors name the caller's own argument, exactly as `selected file does not
  exist: <arg>` does (`Project.lean:146-149`, `CLAUDE.md`).
- Every setting reports its **value**, the **file** it came from, and the **line** in that file.
  Provenance to `file:line` is available: `Lake.Toml.Value` carries a `ref : Syntax` on every
  constructor (`Lake/Toml/Data/Value.lean:27-49`) and `Value.ref` exposes it, so the position of the
  value that won is recoverable without a second parse. A defaulted setting reports origin
  `default` and no location.
- For a setting composed across an `extend` chain, provenance names **every** contributing file in
  composition order — which is why §6.2 preserves duplicates and order.
- Output also reports: the owning config file (or `--config`, or "none — defaults"), the full `extend`
  chain, the discovered ignore sources in precedence order, and whether `PATH` would be **selected**,
  with the gate number (§11) that decided it. "Would this file be formatted, and why not" is the
  question the command exists to answer.
- Output is **deterministic**: settings in schema order, paths relative to the project root where
  inside it, absolute where outside, `\n` line endings.
- `config show` is **read-only** and never writes source or cache.

`config` is a new command group in `Cli.lean` alongside `rules`/`explain`/`docs`, with `show` its only
subcommand. Presentation lives in `Cli.lean`; resolution and provenance are produced by the discovery
capability, per `CLAUDE.md`.

---

## 13. Error surface

Hard errors (non-zero exit, no silent fallback — `03-acceptance`'s stop rule):

- unknown configuration key (unchanged, `Config.lean:216`)
- both `.lean-fmt.toml` and `lean-fmt.toml` in one directory (§3)
- a key set both at the top level and in `[lint]` (§8.2)
- `line-width` at the top level (§8.2); `line-width` out of range or wrong type (§9.3)
- `[format]`/`[lint]` present but not a table (§8.2)
- `extend` not a string; `extend` target missing or unparseable; `extend` cycle; chain depth > 32 (§6)
- an explicit `--config` path that does not exist (unchanged, `Config.lean:301-302`)
- a selected file under `.lake` (§11)
- malformed TOML (unchanged, `Config.lean:284-293`)

Non-fatal notices on stderr, never affecting exit status or which rules run (§8.2 rule 2):

- a linter key at the top level (migration)
- today's `RulePlan.notices` — retired/reserved selector, deprecated rule (`Config.lean:66-70`)

**A recognized-but-invalid config never falls back to defaults.** An absent config is the default
policy (`Config.lean:300-302`); a present broken one is a hard error.

---

## 14. What `RCD-IMPL` builds

1. **One private discovery capability** owning the single walk, the directory map, per-realpath parse
   memoization, closest-config ascent, `extend` composition with cycle detection, and provenance.
   `Project.load` consumes it; `FormatterConfig.load` (`Config.lean:296`) is subsumed by it and the
   root-only path is **removed**, not kept in parallel.
2. **A git ignore matcher** with git pattern semantics (anchoring, trailing-slash, `!`, `*` vs `**`,
   last-match-wins, nearer-file-wins, directory-exclusion), separate from `PathPattern` (§7), plus the
   partial git-config reader (§10.2).
3. **The sectioned schema** with flat-key migration and notices (§8), including widening the notice
   channel beyond `RulePlan` (§8.2 rule 2).
4. **`[format] line-width`** threaded to `renderCanonicalText`, folded into `configurationIdentity`,
   with the `Application.lean:365-382` docstring rewritten (§9, §2.1b).
5. **`.lake` as an absolute floor** on both path forms, and `force-exclude` (§11).
6. **`config show`** (§12).
7. **Generated schema/docs** restructured, drift-checked (§8.3).

### 14.1 Test obligations

At the owning layer, persistent:

- `testConfig` (`LeanFmtTest.lean:415`) extended: sectioned schema, flat migration, both-set error,
  `extend` composition per §6.2, cycle error, depth error, dual-filename error, `line-width`
  validation.
- Discovery unit tests: nested configs, closest-config-replaces-not-merges, pattern anchoring at the
  declaring directory (§7), `--config` overriding discovery, symlinked config and symlinked source.
- Ignore-matcher unit tests: each git pattern form, precedence between sources, negation,
  directory-exclusion, `.ignore` over `.gitignore`.
- **Write-path tests** (`tests/modes/run.sh`, per the roadmap: verified against a `format` **write**,
  not `check`): an excluded file is never written; an explicit excluded path *is* written by default
  and is *not* under `force-exclude`; an explicit `.lake` path is refused under every setting; the
  no-arg write is exactly the `include`-filtered set.
- Cache tests: a `line-width` change misses; a `[lint]` change hits (§9.2).
- `config show` determinism and provenance across an `extend` chain.
- `tests/boundary/run.sh` unchanged and passing — nothing here enters the compiler plugin's link
  closure.

Scale evidence for `RCD-FINAL`: discovery timing on a large tree from the frozen sample, reported per
the roadmap's performance schema. No full mathlib run.

---

## 15. Open questions, left to `RCD-IMPL`/`RCD-FINAL`

1. **`lakefile.toml [tool.lean-fmt]`** (§3.1) — rejected on durability, not capability. Revisit only if
   Lake documents a `[tool.*]` namespace.
2. **Multiple `extend` parents** (§6) — deferred; needs a principled diamond rule before it is worth
   the provenance complexity.
3. **Re-anchoring inherited patterns** (§7) — rejected: a pattern's meaning must not depend on who
   inherited it. Recorded because it is the plausible alternative and someone will propose it.
4. **`include`/`exclude` git semantics** (§7) — today's `PathPattern` is kept for compatibility. If they
   are ever unified onto the git matcher, it is a breaking change owned by its own prompt, with a
   migration.
5. **Git config `include`/`includeIf`** (§10.2) — not followed. Known limitation with a named user-
   visible consequence.
6. **`serve` re-reading configuration** — `ruff-16-watch-incremental`. This stack resolves once per run;
   a session that outlives a config edit is out of scope here.
7. **`line-width` bounds** (§9.3) — `1 ≤ n ≤ 1000` is asserted, not measured. `RCD-FINAL` should
   confirm the printer terminates and produces valid output at both extremes on a real file.
