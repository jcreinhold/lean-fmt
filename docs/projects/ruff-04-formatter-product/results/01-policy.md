# RFP-SPEC — Freeze formatting policy and CLI semantics

**Verified.** The policy is `notes/01-policy.md`. This records what was run, what it showed, and what
changed while running it.

No product behavior changed. One fixture, one characterization test, one lakefile root, two evidence
files, and the note. `LeanFmt/` is untouched, which is the correct footprint for a spec prompt.

## The headline

**The command named `format` does not format.** It previews the fixes of selected lint rules and
never consults layout. This was not known when the stack was written; the roadmap's completion
contract ("formatting is a canonical transformation distinct from selectable lint rules") reads as a
constraint to preserve, and is in fact a description of work not yet done.

```
$ lean-fmt format --root . --json --no-cache tests/check/Layout.lean
{"broken":0,"changed":0,"files":[{"diagnostics":[],"diff":null,"findings":[],"formatted":null,
"path":"tests/check/Layout.lean","status":"clean","written":false}],"findings":0,
"infrastructureFailures":[],"mode":"format","rejected":0,"written":0}
exit=0
```

`tests/check/Layout.lean` contains `namespace     Alpha` — five spaces where the printer renders one.
`format` calls it clean. Full transcript: `evidence/01-format-does-not-format.txt`.

Three facts compound to make this structural rather than an oversight (`notes/01-policy.md` §1):
nothing imports `LeanFmt.Printer` but the test binary; both registry rules are `input := .source`, so
`RulePlan.requiresSyntax` is `false` and `officialArtifacts` is never called — **no syntax tree is
built at all**; and `PreparedFile` has no field to hold one. The printer is compiled, reachable, and
starved.

## Decisions changed during execution

**1. I claimed canonical text satisfies FMT001/FMT002. It does not.** This is the one thing I got
wrong and had to reverse. I wrote in §6 that the printer emits no trailing whitespace and terminates
the file, so both fixes would be no-ops on canonical text — subsumed, not raced. Then I ran it:

```
$ lean-fmt-tests printer-format probe.json probe.lean 100
module / (blank) / namespace Alpha / (blank) / def v : Nat := 1··   <- whitespace kept
(blank) / end Alpha                                                  <- no final newline
```

The printer canonicalized the namespace and **left both violations in place**
(`evidence/02-canonical-text-still-lints.txt`). It is right to: `··` is the trailing trivia run of
that command's last token, and a command extent keeps its own trailing run verbatim
(`Printer.lean:208-222`). End-of-line whitespace is not a layout decision.

This inverted the section. The hazard is not duplicate edits — it is **stale offsets**.
Canonicalizing `namespace     Alpha` deletes four bytes, and findings index the normalized source
(`Application.lean:420-422`), so every finding past that point is now four bytes off. A cached
FMT001 fix applied to canonical text corrupts the file. The composition is therefore forced: format
first, then **re-derive** findings against the canonical text — never reuse. That is a real
constraint on `RFP-IMPL` that I would have shipped wrong had I only reasoned about it.

**2. The style surface is empty, and `line-width` is refused on proof rather than deferral.** I
expected to ship the roadmap's four knobs. Three of them cannot change a byte:

- `Doc.go` threads the margin `w` through every constructor and **reads it at exactly one place** —
  the `.group`/`.brk` case, `if fits (w - col) ...` (`Doc.lean:219-229`).
- `LeanFmt/Printer.lean` emits exactly three constructors — `Doc.text` ×3, `Doc.hard` ×2,
  `Doc.verbatim` ×1. No `group`, no `line`, no `nest`.

No group means `fits` is never called means the margin is never read. **Every margin produces
identical bytes**, for foreign input as much as canonical. `LeanFmtTest.lean:831-836` corroborates on
this repository's corpus at margins 0, 1, 40, 80, 120, 1000; the structural argument is what proves
it in general. `indent-*` is the same story against `nest`, which the printer also never emits.

A knob that provably changes no byte is a fake shim, and this loop stops for those. So the refusal
*is* the deliverable, with the exact trigger that reverses it: the first `group` in `Printer.lean`
brings `line-width` **and** its cache-identity component in the same commit. `RFP-IMPL` passes 100
internally as a constant.

I read "expose only line width, indentation style/width, line ending policy" as a cap on the maximum
surface rather than a list to ship, given the contract's own "avoid a knob for every layout decision"
and the prompt's stop rule against exposing layout-engine mechanisms. `line-width` *is* the engine's
mechanism.

**3. Cache identity needed no change, and that is load-bearing rather than lucky.** The stop rule is
"do not let formatter policy enter semantic cache identity unless it changes output". `CacheIdentity`
(`Cache.lean:29-37`) keys `SemanticResult` = `{schema, source, sourceBytes, findings}`
(`Semantic.lean:7-12`) — findings only. Style policy cannot change a finding, and §3 keeping the
surface empty is what keeps `configuration` free of style. Compliant by construction.

The trap worth naming: today's identity is *accidentally* correct. The moment a `group` appears,
`line-width` becomes observable and existing entries go stale under an identity that never mentioned
it — consistent and wrong, which no test catches.

## No migration alias

`format` gains behavior; a lint-clean but non-canonical file goes from exit 0 to exit 1. That breaks
CI gates on unchanged code. But it is a widening, not a rename, so there is no old name to alias —
and `format-legacy` would preserve semantics nobody chose, since today's behavior is an accident of
the printer never being wired in.

The migration is a command that already exists: **`check`**, which reports selected rules and does
not move (formatting is not a rule, so it cannot enter rule selection). Anyone whose `format` gate
meant "does anything need fixing" wants `check`, which is also stricter — it exits 1 on findings with
no fix, where `format` exits 1 only on `changed > 0`.

## Commands run

```
$ LEAN_NUM_THREADS=1 lake build                # Build completed successfully (32 jobs)
$ bash tests/modes/run.sh                      # lean-fmt product mode integration tests passed
$ bash tests/check/run.sh                      # lean-fmt check integration tests passed
$ bash tests/boundary/run.sh                   # native module and dependency boundary passed
$ python3 experiments/check-quoted-figures.py  # quoted figures agree with evidence (33 checked)
$ git diff --check                             # (silent)
```

The stack gates need `pyyaml`, which neither system interpreter has:

```
$ uv run --with pyyaml python3 .../check_stack.py docs/projects/ruff-04-formatter-product
OK: 3 prompt(s), 0 warning(s), no errors.
$ uv run --with pyyaml python3 .../write_next.py --check docs/projects/ruff-04-formatter-product
OK: state/next.md matches first_unresolved='02-integration'
```

`check-quoted-figures.py` is run because the lakefile changed: `tests/check/Layout.lean` is
deliberately non-canonical, and had it landed in the printer's corpus it would have broken the
identity check and moved the gated figures. It does not — the corpus is `find LeanFmt` plus
`Main.lean` (`tests/printer/run.sh:59`) and `git ls-files 'LeanFmt/*.lean' 'LeanFmt.lean' 'Main.lean'`
(`experiments/run-projection-shape.sh:42`). `tests/check/` is in neither. Checked rather than assumed.

Fixture and test added:

- `tests/check/Layout.lean` — lint-clean, layout non-canonical. The one fixture separating "has no
  findings" from "needs no formatting". Added as a `CheckFixtures` root so it builds under the
  plugin and produces an artifact.
- `tests/modes/run.sh` — pins `format` reporting `Layout.lean` clean at exit 0, with the citation
  chain for why. **`RFP-IMPL` must flip this to exit 1**; a green run there means the printer is
  still not reached.

## The characterization test is non-vacuous

Asserted by mutation, per the house standard:

| mutation | result |
| --- | --- |
| canonicalize the fixture's spacing (`namespace Alpha`) | **caught** — `fixture lost its non-canonical spacing; the check above proves nothing` |
| add trailing whitespace to the fixture | **caught** — `expected exit 0, got 1` |

The first is the guard that matters. Without it the test passes for the wrong reason the moment
someone tidies the fixture, and would then certify the printer as unreached forever.

## Remaining uncertainty

- **Whether `RFP-IMPL` can keep the cache on the `fix` path.** A full cache hit returns from
  `previewFile` at `Application.lean:557-563`, *before* `officialArtifacts` at `:569` — so a hit
  carries no tree, and one cannot be built without discarding the hit. Compounding it, decision 1
  means cached findings are unusable against canonical text anyway. It may be that `fix` simply
  cannot take a cache hit. That would be sound, and slow. Unmeasured.
- **Whether the non-overlap of FMT rules and layout survives a third rule.** Both current rules are
  `category := "text"`, about bytes `Doc` cannot represent. Nothing enforces that a future rule stays
  out of the printer's way, and an overlapping one produces exactly the duplicate edit the contract
  forbids.
- **How noisy `format` becomes on partly-claimable files.** A `declaration` shell is canonical while
  its value is `verbatim`, so files whose bytes are mostly untouched will still report
  `would-format`. Correct, possibly irritating. `RFP-FINAL` sees it on the frozen sample first.
