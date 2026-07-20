# Prompt stacks

One directory per stack, named `ruff-NN-topic`. Each holds:

- `roadmap.md` — goal, defect, and plan. Frontmatter names the stack's `main_results` and
  `prereq_stacks`.
- `prompts/NN-name.md` — the work, one prompt per file. Frontmatter carries the `claim_id`, its
  `status`, and what it `depends_on`.
- `results/`, `notes/`, `evidence/` — each has a `README.md` stating what belongs in it. Read that
  README before writing there.
- `state/current.md` — where the stack stopped. `first_unresolved` names the prompt still to run.
- `state/next.md` — the packet for that prompt: claim, target files, what to read, stop rules.

## Running a prompt

Start at `state/next.md`. Read the prompt it names, then `roadmap.md`, then the results of the
prerequisite stacks. Obey the packet's stop rules; a stop is a stop, not a finding to file.

Write the result note under `results/`, named after the prompt stem. Then update `state/current.md`
and `state/next.md` to the next unresolved prompt.

The root `CLAUDE.md` sets which record wins when two disagree, and the order stacks run in.
