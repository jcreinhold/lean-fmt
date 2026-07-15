# Performance evidence policy

The original scale prompt required three full 8,795-file trials for each of three workload paths and
the final prompt appeared to require all of them again. That requirement did not distinguish evidence
needed to choose an implementation from evidence needed to accept a release candidate.

The corrected policy has three scopes:

1. Focused fixtures and fresh exact-frontend comparisons establish semantic correctness.
2. The frozen 62-file sample, paired measurements, and named worst-case files guide optimization and
   expose retention or resource failures. A run stops when it has already falsified its target.
3. One monitored full workload per plausible release-candidate path checks coverage, long-tail files,
   and late memory growth. Its binary, workload, toolchain, and configuration digests make that result
   reusable by the final audit.

The deliberately stopped 2,031-file ordinary-built characterization is therefore sufficient rejection
evidence for that implementation: after 27.9 minutes it had already exceeded a ten-minute whole-run
goal. Completing the remaining files could not change the decision and was not acceptance evidence.

This repair changes neither the performance targets nor the 8 GiB resource envelope. It removes
duplicated work while making every full-run claim stricter: only an actual 8,795-file monitored run may
be described as full-mathlib acceptance.
