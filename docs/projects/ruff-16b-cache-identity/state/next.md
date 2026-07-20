# Next Proof Packet

- Stack: ruff-16b-cache-identity
- First unresolved: 02-model
- Claim ID: RCI-MODEL
- Prompt: 02-model
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **RCI-MODEL**: Express the currency decision frozen by `RCI-SPEC` as a pure function over an explicit observation, specify what a correct answer is independently of that function, and prove soundness **and** completeness under hypotheses that name every unprovable step.
- Read `roadmap.md`, `notes/01-what-is-provable.md`, its prerequisite stack results, `AGENTS.md`, the current implementation and tests, and the relevant Lean compiler/Lake sources before changing an interface. Write interface comments and characterization tests before implementation where the behavior is not already frozen.

## Reuse

- see the target prompt's Read section

## Documentation Work

Edit only the records named by the prompt. Do not execute planned mathematical or Lean prompts.

## Stop Rules

- **No `axiom` declarations, no `sorry`, no `native_decide`.** Unprovable steps are theorem hypotheses, so they appear in the type of everything downstream. An assumption that disappears from use sites has defeated the purpose of stating it.
- **Do not weaken the specification to close a goal.** If `grammar_current` will not go through, the candidate decision is wrong and `RCI-SPEC` reopens — that is the mechanism working, not an obstacle. §6 of the note records this already happening once.
- Do not let the proof drive the shipped decision toward something easier to verify but weaker in practice; the acceptance measurements in `RCI-FINAL` still bind.
- Do not introduce proof dependencies into the plugin or the binary's link closure.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.
