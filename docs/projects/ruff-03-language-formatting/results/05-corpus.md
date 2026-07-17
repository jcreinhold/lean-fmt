# RLF-FINAL — results

## What shipped

Two checks and a table. No layout, no formatting behaviour, and **not one output byte** changed in this
prompt — which is the correct outcome for an audit and is also, for the eighth time in this stack, the
finding rather than a shortfall.

1. **`experiments/kind-inventory.txt`** — every command syntax kind the frozen corpus contains that no
   layout emits, each given one of three dispositions and a citation. `run-printer-sample.sh` now fails
   on a kind that is not in it, **in both directions**.
2. **The malformed case** (`tests/printer/run.sh`, `--- malformed input ---`) — pins that
   `__analyze-exact` withholds `"artifact"` for source with errors, which is the claim every other
   parse check in that suite is worth exactly as much as.

## The headline: the refusals were never unsafe, they were unread

`RLF-FINAL`'s stop rule is *zero silently unowned accepted syntax kinds in the frozen corpus*, and the
word carrying it is **silently**. An unclaimed command already keeps its own bytes — the conservative
path `RLF-COMMANDS` built, `RLF-EXTENSIONS` proved sound as a class, and the round-trip pins on all 62
sample modules. Nothing was ever dropped. What was missing is that `run-printer-sample.sh` counted the
refusals into a report and **nothing compared that count to anything**, so a kind arriving in the corpus
produced one more line in a file no gate required anyone to read.

So the stop rule is not about safety and reading it as such would have produced either a shrug ("they
all round-trip, we are done") or 542 unnecessary layouts. It is about *ownership being written down*.
The 24 refused kinds now carry a disposition each:

| disposition | kinds | commands | what it means |
|---|---|---|---|
| `guard` | 4 | 196 | a layout claims the kind; a runtime guard refused these instances, and the guard is named |
| `core` | 14 | 542 | the pinned compiler declares it, no layout claims it — scope, not soundness |
| `corpus` | 6 | 417 | declared by the code being formatted; unreadable by construction |

The three **partition the sample exactly**, and that is arithmetic rather than assertion:

    guard 196  +  core 542  +  corpus 417  =  1155  =  commands 2734 - canonical 1579

Any future edit that leaves a kind out shows up as a sum that no longer closes.

## Why this is not the table `notes/04-extensions.md` §5 refused

§5 refused a clearance table on three grounds, and the strongest was that **every entry goes stale
silently** — each a claim about `Lean/Parser/Term.lean` that no gate here would notice breaking. That
objection is real and it does not reach this file, because **the direction is opposite**:

|  | §5's clearance table | this inventory |
|---|---|---|
| effect on output | **widens** what gets collapsed | widens nothing — every kind is refused whether listed or not |
| a stale entry emits | Lean that does not parse | a wrong *sentence* |
| caught by | nothing | the gate below, both directions |

A stale entry here cannot break a parse; it can only mis-describe a refusal. That is what earns the file
the right to exist where §5's table did not, and the gate is what makes even the wrong sentence loud.

## The gate, and the proof it can fail

Both directions are fatal. The first is the stop rule directly. **The second is the point**: a kind in
the inventory but *not* in the corpus is a sentence about this sample that is no longer true — the exact
rot §5 named — and catching it is the whole reason a hand-written table is allowed here at all.

Mutation-tested on a two-module sub-sample (`Mathlib/Tactic/Nontriviality.lean`,
`Mathlib/Topology/Algebra/ProperAction/AddTorsor.lean`), since the script takes its corpus as an
argument and a mutation test must not take twenty minutes:

    experiments/run-printer-sample.sh ~/Code/mathlib4 mini.txt mini-out.txt

- **Unowned.** Dropping `core     Lean.Parser.Command.moduleDoc` from the inventory → exit 1,
  `FAIL unowned syntax kind in the frozen corpus (RLF-FINAL stop rule)`, naming `moduleDoc`.
- **Dead.** The unmodified inventory over a corpus holding 2 of its 24 kinds → exit 1,
  `FAIL … claims a kind the frozen corpus does not contain`, naming all 22 absent ones.

Both are checks that a mistake makes fire, not checks that a mistake makes silent.

One portability note is recorded at the gate itself because it is the failure mode that would have
looked like a real defect: the disposition parse is `sed -nE`, because BSD `sed`'s basic regex has no
`\|` alternation, so a BRE there matches **nothing**, reports every kind unowned, and reads exactly like
the stop rule firing.

## The malformed case, and the assertion that the assertions mean something

`results/04-extensions.md` states — in prose, unchecked — that `__analyze-exact` "omits `artifact`
entirely when the module has parse errors. That absence is the assertion". Three checks in
`tests/printer/run.sh` are `grep -qF '"artifact"'` and are worth precisely that sentence's truth. If the
frontend emitted an artifact regardless, all three would pass on every input including the broken Lean
they exist to catch, and nothing would notice. That is a vacuous test: not a check that is wrong, but a
check that cannot fail.

It is now pinned on the real frontend. **The fixture's first draft was `def wrong : Nat := 1`, which is
perfectly good Lean** — and the run said so by failing rather than printing `ok`. That self-guard is
the reason the check is worth having: a fixture that stops being malformed cannot quietly become a
tautology. The shipped fixture is `def wrong : Nat := := 1`:

    a.lean:3:18-3:21: error: unexpected token ':='; expected term

and the envelope comes back `{"diagnostics":[…]}` with no `artifact` key at all.

Two details are recorded because each could have made the check vacuous a second way:

- **The withholding is on any error, not on parse errors.** `analyzeExact` returns `broken` on
  `messages.hasErrors` (`LeanFmt/Analysis.lean:79`). A parse error is chosen because it is the failure
  this suite's `"artifact"` checks exist to catch — the printer's own output failing to re-parse.
- **The envelope's `diagnostics` carries a serialized artifact of its own**, emitted by the compiler
  plugin into the message log. It cannot fool `grep -F '"artifact"'`, because JSON escapes it to
  `\"schema\":\"lean-fmt.module-artifact.v2\"` inside a string — the literal `"artifact"` key never
  appears. Verified rather than assumed: `grep -c '"artifact"'` is 0 on the broken envelope.

## Why the inventory covers commands and not terms

The stop rule says *syntax kinds*, and the sample holds 600 of them over 122,011 nodes
(`evidence/02-term-census.txt`). The inventory lists 24. That is a decision, not an omission, and the
asymmetry is one the verified prompts already forced:

- **A refused command is inert.** No layout claims it, the whole command keeps its bytes, and the
  refusal is visible as a count in a report. The report was the silent thing; a table fixes it.
- **An unread *term* kind is not inert.** The printer descends *into* it and lays out the built-ins
  inside (`--- the extension boundary ---`). So ownership there cannot be a list of kinds — and
  `RLF-EXTENSIONS` proved it cannot be, on evidence: a user's `withPosition(term:max colEq term:max)`
  compiles to **no node at all**, so no census of kinds can see it, and `colGt`/`colGe`/`colEq`/`lineEq`/
  `withPosition` are registered parser aliases, so the corpus can declare a live column check anywhere.
  **A term-kind inventory is not merely expensive, it is unfinishable.** The answer there is
  `Tree.mayCollapse`, which needs no kind knowledge at all.

So terms are owned by a *guard*, commands by a *table*, and the reason is that the command set the
printer dispatches on is closed while the term set is open. That is the same closed-versus-open line
`notes/02-expressions.md` drew for the bracketed binders, arrived at from the opposite end.

## Style policy

The prompt's title is "close whole-language coverage **and style policy**", and the honest statement of
the policy is short, because this formatter decides very little:

1. One space between two tokens of a claimed flat run, where the grammar declares no atom.
2. The declared string, where it declares one (`" : "`, `" := "`, `" => "`, `"| "`).
3. A docstring and an attribute block each end their line, because their grammars say `ppLine`.
4. Header: keep a blank line the author left, collapse runs of them to one, add one only after `module`.

**Mathlib was characterization input and not an authority, and the numbers are what make that claim
checkable rather than a posture.** `app_slack=0`, `binder_slack=0`, `match_slack=0`, `tactic_blank_gaps=0`
across all 62 modules: real Lean already writes `f a`, `(x : Nat)`, `| 0 => 1`, and never blank-lines
between two tactics. So mathlib **did not force a single style decision** — it agrees with all four
rules already, and where it disagreed once (a blank line between `public import`s and plain `import`s)
the resolution was to *keep the author's* line, not to adopt mathlib's taste. The roadmap's worry about
"unstable accidental style" never had a chance to bite, and the reason is measured: there was no
accidental style in the sample to copy.

The corollary is this stack's standing finding, now for the eighth time: **the part of formatting that
is citable today is the part that changes nothing on code people actually wrote.** `reformatted=12` of
62 is entirely the declaration shell's attribute and docstring rules.

## Exact commands

    LEAN_NUM_THREADS=1 lake build lean-fmt lean-fmt-tests
    for s in boundary check compiler layout lossless modes printer scale service; do bash tests/$s/run.sh; done
    bash experiments/run-printer-sample.sh
    git diff --check
    uv run --with pyyaml python3 …/check_stack.py docs/projects/ruff-03-language-formatting
    uv run --with pyyaml python3 …/write_next.py --check docs/projects/ruff-03-language-formatting

All nine suites pass. `tests/check/run.sh` is the **exact fresh-frontend differential** the task line
names: it is where the two mandated producers — the compiler plugin and the fresh `__analyze-exact`
frontend — are proven to emit the same projection, and it is a prerequisite-stack gate this prompt runs
rather than a new one it builds.

## Measurements

Frozen sample, unchanged by this prompt:

    modules_analyzed=62 skipped=0 failures=0 reformatted=12
    commands=2734 canonical=1579 members=13 headers_canonical=62
    app_slack=0 binder_slack=0 match_slack=0
    tactic_blocks=1966 tactic_blank_gaps=0

Repository corpus:

    modules_checked=20 commands=458 canonical=435 headers_canonical=20 members=57 failures=0

The corpus's 95% is 57.8% on real Lean, and both are honest: the two disagree because this
repository's command mix is not Lean's, and `kind-inventory.txt` is now the place that says so kind by
kind rather than leaving a bare percentage to be misread as a defect.

## The task line, item by item

| item | where | verdict |
|---|---|---|
| generated syntax-kind inventory | `evidence/01-printer-sample.txt` (generated) + `experiments/kind-inventory.txt` (dispositions) + the gate | shipped |
| repository corpus | `tests/printer/run.sh` — 20 modules, 458 commands | passes |
| frozen mathlib sample | `experiments/run-printer-sample.sh` — 62 modules | passes |
| malformed cases | `tests/printer/run.sh`, `--- malformed input ---` | shipped |
| idempotence loop | `tests/printer/run.sh`, `--- idempotence ---` | passes |
| exact fresh-frontend differential | `tests/check/run.sh` | passes |
| record unsupported constructs, eliminate or block | `experiments/kind-inventory.txt` | recorded; none unsafe |

On the last one: **"eliminate or block" is answered by "neither", and the completion contract is why.**
It licenses the conservative path outright — "unknown/custom syntax preserves its token subtree and
comments conservatively until a registered structural formatter exists". There is no *unsupported*
construct in the sense of one the formatter mishandles; there are 1,155 commands it declines to
re-space, every one of them soundly, and the inventory is the record the stop rule actually asked for.

## What is left uncertain

- **The inventory's counts are prose and the gate checks only the kind set.** Deliberate — a count moves
  whenever the sample moves and a disposition does not — but it means the `196 + 542 + 417` arithmetic
  above is checked by a reader, not by a script. It is the same silent-drift hazard `state/current.md`
  records for the coverage figures quoted in `Printer.lean`'s docstring, and it is not fixed here.
- **`mayCollapse` is proved against Lean's column checks, not against a parser this stack has not
  read.** `notes/04-extensions.md` §6's residue, unchanged; the `.keep` default is the mitigation.
- **The margin is still unset and `Doc`'s break behaviour is still unexercised by real source.** Every
  layout this stack ships is a flat run or a `hard`, so no `group`/`line`/`nest` reaches the engine from
  a real module. `RLC-FINAL`'s caveat narrows but does not close: nothing yet asks the engine to measure
  a width and choose. That is the whole of the remaining value in this area and it belongs to a stack
  that has picked a margin.
- **`variable` (277) and `in` (108) are the two `core` refusals worth buying**, and both are terms-first:
  `variable` is `many1 bracketedBinder`, which `RLF-EXPRESSIONS` already lays out inside declarations and
  declines to claim inside a command it has not measured.
