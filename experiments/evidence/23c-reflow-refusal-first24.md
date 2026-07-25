# Reflow and refusal over the first 24 stratified mathlib paths

Measured 2026-07-24. This is a measurement with a date, not a decision. Regenerate it rather than arguing with it.

|  |  |
| --- | --- |
| workload | formatter-cache-cold, ordinary-project-built |
| command | `format --check --json`, paths passed explicitly via `run-check-workload.sh` |
| lean-fmt | `0b6f1b1` |
| mathlib4 | `3de5ed81cc71b9ea62597b865ba0baaeb5eb0ea9` |
| toolchain | `leanprover/lean4:v4.33.0-rc1` |
| manifest | `experiments/workloads/mathlib-v4.33.0-rc1-stratified-first24.txt`, 24 paths, sha256 `3de69dde…3847aea` |
| guard | `profile-run.sh`, rss 8 GiB / swap 256 MiB / pressure 1 |

Run: `wall_ms=165017`, `peak_rss_kib=4509632` (4.30 GiB), `swap_delta_kib=-8192`, `peak_pressure_level=1`,
`hard_stop=none`, `exit_status=2`. Exit 2 is the documented infrastructure-failure code (`docs/ci.md:62`), not a crash.

One caveat about the meta this run wrote. `profile-run.sh` digests `$1` as the measured binary, and the command is
`bash experiments/run-check-workload.sh …`, so the meta records `binary=bash` and `binary_digest=unavailable`.
Provenance still holds through `lean_fmt_revision`. Set `LEAN_FMT_PROFILE_BINARY` on future runs through that driver.

## Counts

```
files=24  changed=15  infrastructure_failures=9
rejected=0  broken=0  written=0  suppressed=0  withheld_unsafe=0  withheld_redundant=9  findings=4
```

15 + 9 = 24, so every path is accounted for: **15 reflowed, 9 refused, 0 published, 0 silently unchanged.** `--check`
writes nothing by construction; `written=0` is the mode, not a result. `broken=0` says no input was already failing, so
all 9 refusals are the candidate's fault.

## The 9 refusals

Two gates. Neither published anything.

| Gate | Files |
| --- | --- |
| `ValidationGate.comments` | 1 |
| `ValidationGate.diagnostics` | 8 |

### comments (1) — a line comment before a docstring is dropped

`Mathlib/Algebra/Jordan/Basic.lean`: `comment contract count changed: 13 -> 11`.

The construct is a line comment immediately preceding a `/-- … -/` docstring on a declaration. That file has three
`-- see Note [lower instance priority]` comments; the two at lines 93 and 107 are followed by a docstring and are the
two that vanish, and the one at 116 has no docstring and survives. Two lost, three candidates, and the discriminator is
the docstring.

Minimized, with its negative control — the first refuses `2 -> 1`, the second is merely `changed`:

```lean
class HasThing (α : Type) where
  thing : α → α

-- see Note [lower instance priority]
/-- A docstring between the line comment and the declaration. -/
instance (priority := 100) natHasThing : HasThing Nat where
  thing value := value
```

Delete the docstring line and the comment survives.

### diagnostics (8) — a break placed where the parser requires a saved column

All eight are one mechanism on two parser surfaces. It is the mechanism `CLAUDE.md` already names: *a parser-significant
column cannot be expressed even where it is known*. `nest n` is relative to the current indent and `align force` pads to
it, so no `Std.Format` constructor means "indent this subtree's continuations to the column where it starts" — which is
exactly what `many1Indent` saves and `checkColGe` measures against. A break that has to land at such a column cannot be
placed.

**`many1Indent` tactic sequences (7 files).** The formatter joins the first tactic onto the `by` line, then breaks the
remainder to `nest`-derived indentation instead of the column the joined tactic now occupies. The block ends at the
break and the next tactic is read as a command. The signature is an `unsolved goals` whose range covers the joined
prefix, immediately followed by `unexpected <token>; expected command`.

Measured candidate, `Mathlib/Analysis/SpecialFunctions/Exponential.lean` (via the `draft:100` capture mode, which is
unvalidated and so survives refusal):

```
214|theorem Real.exp_eq_exp_ℝ : Real.exp = NormedSpace.exp := by ext x;
215|  exact mod_cast congr_fun Complex.exp_eq_exp_ℂ x
```

`ext` starts at column 60; `many1Indent` saved 60; `exact` lands at column 2.

Minimized to eight lines, reproducing the identical two-error signature:

```lean
theorem joinedBreak (value : Nat) : value + 0 = value ∧ value + 0 = value := by
  constructor; exact Nat.add_zero value; exact Nat.add_zero value
```

The source's own layout is legal; the candidate's is not. Note that the same shape *fits* under 100 columns in a smaller
file and is then correctly joined outright — the defect needs a prefix that fits and a whole that does not, which is why
it shows up on mathlib and not on `LeanFmt/`.

**`sepByIndent` structure-instance fields (1 file).** `Mathlib/CategoryTheory/Groupoid/Subgroupoid.lean` refuses with
`unexpected identifier; expected '}'` as its *first* diagnostic, so it is not cascade. Measured candidate:

```
238|          Tl Ss fT]) with
239|    
240|      bot := ⊥
241|    bot_le := fun _ => empty_subset _
```

A whitespace-only line 239, then the first field at column 6 while every sibling sits at column 4. `sepByIndent` wants
one column for the whole list, so `bot_le` at 4 terminates it and the parser wants the closing brace. The reported range
`240:14-241:10` runs from the end of `⊥` to `bot_le`.

Two minimization attempts did **not** reproduce it and are recorded as negatives: a plain newline-separated field list,
and a `{ … with … }` whose fields are newline-separated, both format correctly. What distinguishes the mathlib case is
that the term before `with` is itself multi-line. The standalone reproduction is not written.

### Cascade, not separate constructs

`Mathlib/Analysis/InnerProductSpace/l2Space.lean` and `Mathlib/Analysis/Normed/Module/Multilinear/Basic.lean` each
report an `expected '}'` *after* a tactic-block break earlier in the file. Once a block is misread as a command the rest
of the parse is unreliable, so those are counted under the tactic mechanism, not as instances of the Subgroupoid one.

## What this does and does not say

It says the gates hold: 9 candidates that would not elaborate were refused, nothing was written, and no file passed
silently unchanged. It does not say the adapter is finished — a 9/24 refusal rate on real mathlib is the measurement,
and driving it down is downstream work, not a property of this run.

It is a count over 24 files chosen for stratification, not a rate over mathlib.
