# RFX-SPEC — Freeze applicability and conflict semantics

**Verified.** The design is `notes/01-model.md`. This records what was run, what it showed, and what
changed while writing it.

No product behavior changed. One evidence file and the note. `LeanFmt/` is untouched, which is the
correct footprint for a spec prompt and is what `state/next.md` declared this prompt to be
("Module: (docs only)"). The prior spec prompt in this family, `RRE-SPEC`, has the same footprint.

## The headline

**A fix is one boolean today — `fixable` — and every fix that exists is applied unconditionally.**
There is no third value between "has a fix" and "no fix", no way for a rule to say "this fix is a
guess", and no way for a user to withhold a guess or opt into one. `preparePatch` collects every
finding's `fix?` and applies them as a single transaction; the only gates are whole-candidate
validation and the stale-source check, neither of which asks about an individual edit
(`evidence/01-no-applicability.txt` §3).

The model this note freezes is ruff's, because ruff is the product this stack is named after:
`Applicability::{Safe, Unsafe, DisplayOnly}`, default applies safe only, `--unsafe-fixes` opts in,
`extend-safe-fixes`/`extend-unsafe-fixes` reclassify per rule. The note is faithful to that source and
records each place it diverges (no global unsafe config bool; no cross-file two-phase commit).

## Commands run

```sh
LEAN_NUM_THREADS=1 lake build                                  # baseline, exit 0 (36 jobs)
lake -q query lean-fmt --text; "$app" rules --json; "$app" rules   # applicability absent
grep -rin 'applicab|unsafe.fix|displayonly|Applicability' LeanFmt Main.lean \
    LeanFmtTest.lean tests docs/adding-a-rule.md | grep -vi 'unsafe def|unsafe ('   # no output
tests/boundary/run.sh                                          # exit 0
git diff --check                                               # no output
check_stack.py    docs/projects/ruff-06-fix-safety --structural   # OK: 3 prompts, 0 warnings
write_next.py --check docs/projects/ruff-06-fix-safety         # matches first_unresolved
```

Environment: commit `8a984f9`, `leanprover/lean4:v4.32.0`, Darwin 25.5.0 arm64. No performance claim
is made here — the two measurements are a JSON-shape read and a source scan, neither timing-sensitive —
so no RSS/pressure/swap record applies. The prerequisite stacks `ruff-04-formatter-product` and
`ruff-05-rule-engine` are both `verified`; their live code was re-read here (`Edit.lean`,
`Application.lean`, `Rules.lean`, `Config.lean`, `Cli.lean`, `ArtifactModel.lean`) rather than trusted,
and every claim in the note cites a file and line.

## What was measured

**1. Applicability is a boolean (`evidence/01` §1-2).** `RuleInfo.fixable : Bool`
(`LeanFmt/Rules.lean:112`). `lean-fmt rules --json` reports `"fixable":true` and no other axis. A
tree-wide scan for the concept — type, field, config key, CLI flag — returns nothing.

**2. Every fix is applied unconditionally (`evidence/01` §3).** `Finding.fix? : Option Edit`
(`ArtifactModel.lean:27`); `preparePatch`'s `filterMap (·.fix?)` (`Edit.lean:113`) is the only place
fixes are selected, and it has no predicate. Runtime confirmation is the green `tests/modes/run.sh`
(298-315): `fix` applies FMT001 with no opt-in.

**3. Conflicts carry indices, not provenance (`evidence/01` §4).** `PatchError.conflict` reports array
positions (`Edit.lean:12`); `filterMap (·.fix?)` drops the rule code before conflict detection, so the
error cannot name the two rules.

**4. Atomicity is per-file with one scope (`evidence/01` §5).** `fixFile`/`publishAtomic` publish each
snapshot independently (`Application.lean:544,660,780`). A file's patch is already all-or-nothing;
there is no cross-file transaction today.

## Decisions, and what changed while making them

**Applicability lives on a new `Fix` structure, not on `Edit` or `Finding`** (note §1, "designed
twice"). `Edit` is a byte fact and will carry several edits per fix; `Finding.fix?` is optional and a
safety value on `Finding` would be a coupled `Option` with no enforcement. `Fix { applicability, edits
}` (ruff's shape) makes "a fix exists iff there is something to apply, with exactly one applicability"
a matter of type. `fix? : Option Edit` becomes `Option Fix`.

**"Safe" was tied to tier, not to reparsing.** The first framing was "safe = the candidate parses".
That is the exact error the prompt's stop rule forbids ("Do not label a fix safe merely because it
reparses"), and writing §1 replaced it: safe means meaning-preserving *under the rule's stated
evidence*, which a source-tier rule can assert only at the byte level and a semantic claim cannot
assert at all until `ruff-11` gives it a tier. This is the same anti-drift argument that killed
`RuleInfo.input`, applied to a new field before it can rot.

**The deferred formatter-composition decision was closed** (note §3). `RRE-FINAL` left a docstring in
`renderCanonicalText` handing this stack the choice of what `format` does with the first syntax-tier
fix. Frozen: fixes apply to canonical text in canonical coordinates; a syntax-tier fix composes by
**re-projecting the canonical text**, not by translating original-coordinate edits onto moved bytes,
because the latter makes the result depend on pass order and the roadmap demands determinism. No
shipped rule exercises this yet; the path is specified for the engine's rule-array seam.

**No cross-file two-phase commit** (note §5). The roadmap's "reject the atomic file *or* project
transaction" was initially read as a demand for both scopes. It is not: the file is the transaction
unit, the project result is the deterministic aggregate, and a batch rename is not atomic on the target
filesystems anyway — so an all-or-nothing project claim would be one the OS cannot honor. Rejected with
that reasoning recorded so `RFX-IMPL` does not reopen it.

**Conflict provenance is rule-code + finding-range per side** (note §4), which requires threading the
finding link past the point `filterMap` currently discards it. That is `RFX-IMPL` work; the error shape
is frozen here.

## Files changed

```
docs/projects/ruff-06-fix-safety/notes/01-model.md                      (new)
docs/projects/ruff-06-fix-safety/results/01-model.md                    (new)
docs/projects/ruff-06-fix-safety/evidence/01-no-applicability.txt       (new)
docs/projects/ruff-06-fix-safety/state/current.md                       (updated)
docs/projects/ruff-06-fix-safety/state/next.md                          (regenerated)
```

## Checks read

`lake build` (36 jobs, exit 0), `tests/boundary/run.sh` (exit 0), and `git diff --check` (silent) all
pass and are unaffected — nothing in `LeanFmt/` changed, so they establish that the tree is clean, which
is what they are here to establish. The structural checker and `write_next.py --check` both pass for
this stack. `lake exe lean-fmt-tests` and the mode/check suites were **not** run as gates for this
prompt: no module they cover changed, and the runtime facts this note relies on are read from the
already-green suite (`tests/modes/run.sh`) rather than re-measured. `RFX-IMPL` changes those modules
and must run them.

No characterization test was added under this prompt. The current behavior is not a bug to pin — it is
an absence (no applicability), and the interface that will express it (`Fix`, effective-applicability
projection, `--unsafe-fixes`) does not exist yet. Its first tests belong to `RFX-IMPL`, where they can
pass against real code rather than freeze a placeholder.

## Remaining uncertainty

Carried in note §7 in full. The three that could shape `RFX-IMPL`:

- **Exact presentation markers** for applicability in `check`/`rules` text output are left to
  `RFX-IMPL` to choose and pin.
- **`--unsafe-fixes` × `--select`** is provisionally orthogonal (select chooses rules, unsafe-fixes
  chooses which admitted fixes apply); `RFX-IMPL` confirms and tests it.
- **Multi-edit fixes** (`edits : Array Edit`) are specified but have no producer until a rule needs one
  (plausibly `ruff-09`); `RFX-IMPL` reserves the shape without building the producer.
