# ECV2-BUILT-COLD gates

Run on 2026-07-15 from `/Users/jcreinhold/Code/lean-fmt` unless noted.

| Gate | Result |
| --- | --- |
| Exact `Lake.setupServerModule`, all selected files, `noBuild := true` | pass; 8,795/8,795 |
| Ordered-header census | pass; 8,357 contexts, 8,090 singleton contexts |
| Fixed 62-file setup-free import lower bound | pass; 43,229 ms, 2,842,992 KiB sampled peak; endpoint free-memory 83%, no live pressure sampling |
| Sorted-prefix setup-free lower bound | completed rejection characterization after 2,031 successes; zero file failures, 6,797,232 KiB sampled peak, sampled normal pressure, negative swap delta |
| Fresh isolation control | pass; `B_Observe.lean` exit 0 |
| Same-runtime adversarial isolation | pass; `A_Poison` succeeds, `B_Observe` rejects leaked state, process exit 1 |
| Incremental snapshot custom-syntax differential | pass for the tested setup-free top-level command-kind/range projection only; candidate rejected and not retained |
| Post-design deep-module audit | pass after corrections: sampled/setup-free claims, grouping scope, file identity, and projection scope narrowed |
| `LEAN_NUM_THREADS=1 lake build` | pass; 8 jobs |
| Experiment `LEAN_NUM_THREADS=1 lake build` | pass; 4 jobs |
| `bash -n` on experiment scripts | pass |
| `check_stack.py --structural` | pass; 12 prompts, 0 warnings |
| `write_next.py --check` | pass; `05-compiler-artifacts` selected |
| `check_stack.py --verify --claim ECV2-BUILT-COLD` | pass; docs/API-audit claim, no proof targets |
| `git diff --check` | pass |

The terminated characterization completed its rejection gate: the experiment's purpose was to
decide whether the fallback could be competitive under the sampled policy, not to spend two hours
reproducing an already decisive linear extrapolation. No optimized path was retained, so there is no
production optimization requiring an exact differential or end-to-end improvement claim. Full-corpus
acceptance remains required for a production path that claims to meet a performance target.
