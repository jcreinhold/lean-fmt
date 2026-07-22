# Prompt stacks

> **Rule codes in stack records predate the renumbering.** The live catalog was renumbered to start at
> `FMT001` (`docs/rules/MIGRATION.md`); every code shifted down by two. `results/`, `notes/`, and
> `evidence/` across every stack keep the codes that were current when they were written, because they
> are frozen records of decisions and rewriting them would misreport what was decided. Map through the
> migration table, and treat live `lean-fmt rules` output as the authority on what a code means today.

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
