import VersoManual

open Verso.Genre Manual
open Verso.Genre.Manual.InlineLean

#doc (Manual) "Rules and findings" =>
%%%
tag := "rules"
%%%

A rule reports one specific problem in one place. `lean-fmt check` runs the active rules and prints
a finding per line:

```
LeanFmt/Scratch.lean:4:1: FMT003 duplicate import of Lean
```

The shape is the usual one — file, line, column, identifier, message — so an editor or a CI
annotation parses it without help.

# Asking what a rule is

`lean-fmt explain` describes any rule, including a worked example of what it flags:

```
FMT003  remove a duplicate import  [stable]
  category: imports   tier: source   fix: fixable   default: on

  The same module is imported twice in a header. The safe fix removes the later
  duplicate line. An exact repeat imports nothing new, so removing it preserves
  the module's environment and import order.

  Example
    - bad -
    import Lean
    import Lean
    - good -
    import Lean

  Select:    --select FMT003   |   --select imports
  Suppress:  -- lean-fmt: ignore[FMT003]
  Docs:      docs/rules/FMT003.md
```

`lean-fmt rules` lists the whole registry. Each rule carries four facts that decide when it runs
and what it can do:

- *Category* — `imports`, `security`, `redundancy`, `unused`, `layout`, and so on. A category is
  selectable as a unit, so `--select imports` turns on every import rule.
- *Stability* — `stable` or `preview`. A preview rule is still being tried out and stays off until
  you pass `--preview`.
- *Fix* — `fixable` or `report-only`. Only a fixable rule can be applied by `check --fix`.
- *Default* — whether it runs when you have not selected anything.

# Fixing

`lean-fmt check --fix` applies the fixable findings. It publishes at the original coordinates and
changes nothing else about the file — it is not a formatting pass, and running it does not reformat
the source around what it fixed.

Only fixes that are safe to apply are applied. A rule that can spot a problem but cannot repair it
without guessing stays `report-only` by design, because a fix that is right most of the time is
worse than no fix: it moves the work from writing the change to auditing it.

# Selecting rules

Selection is a filter over the findings, and it is the same on every command:

- `--select SELECTOR` sets the active rules. A selector is a rule identifier, a category, or `all`.
  Repeat the flag to name several.
- `--extend-select SELECTOR` adds to the active set instead of replacing it.
- `--ignore SELECTOR` switches rules off.
- `--preview` unlocks the preview rules.

The same choices live in configuration under `[lint]`, which is the better home for anything a
whole project should agree on. {ref "configuration"}[The configuration chapter] has the keys.

# Suppressing one finding

When a rule is right in general and wrong in one place, suppress it there rather than switching it
off everywhere:

```
-- lean-fmt: ignore[FMT003]
```

Naming the rule in the comment is what makes this readable later. A bare suppression tells the next
reader that something was silenced but not what, and it keeps silencing the rule after the reason
has gone away.

For a whole file or a directory, `per-file-ignores` in configuration says the same thing in one
place instead of once per occurrence.

# The catalog

Every rule has a generated reference page under
[`docs/rules/`](https://github.com/jcreinhold/lean-fmt/tree/main/docs/rules), one file per
identifier, with the rule's rationale and its examples. Those pages are generated from the registry
itself, so they cannot drift from the rules that actually run.
