# Lean-native execution experiments

These files are research instruments, not production architecture. They run with the target project's own
`lake env lean`, so the target chooses the Lean executable, ABI, and search path.

`ImportProbe.lean` processes a sequence of source headers in one Lean process and reports resident memory before and
after each exact import environment. `run-import-probe.sh` adds an external hard RSS stop because Lean's allocator
ceiling does not include every memory mapping.

Every retained experiment must record the target revision, Lean version, input list, command, wall-clock time, RSS,
memory pressure, and swap delta under `results/`.
