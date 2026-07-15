# ECV2-WORKLOADS gates

Run on 2026-07-15 from `/Users/jcreinhold/Code/lean-fmt` unless noted.

| Gate | Result |
| --- | --- |
| `LEAN_NUM_THREADS=1 lake build` | pass; `Build completed successfully (8 jobs)` |
| `(cd experiments/pure-lean-core && LEAN_NUM_THREADS=1 lake build)` | pass; four jobs |
| `bash -n` on the three experiment scripts | pass |
| Regenerate and compare the 62-file manifest | pass; byte-identical |
| Generate the full manifest | pass; 8,795 paths |
| Profiler with `LEAN_FMT_PROFILE_RSS_LIMIT_KIB=1` | exit 137; `hard_stop=rss` |
| `check_stack.py --structural` | pass; 12 prompts, 0 warnings |
| `write_next.py --check` | pass; `04-built-cold` selected |
| `check_stack.py --verify` | pass; no verified proof prompts |
| `git diff --check` | pass |

The profiler's live swap comparison is exercised in both successful retained runs (zero delta). The
256 MiB termination branch is inspected in the same loop as the exercised RSS branch; deliberately
forcing host swap growth merely to test that branch would violate the experiment's resource policy.
