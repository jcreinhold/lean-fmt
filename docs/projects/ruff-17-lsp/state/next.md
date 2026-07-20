# Next Proof Packet

- Stack: ruff-17-lsp
- First unresolved: 02-documents
- Claim ID: RLP-DOCUMENTS
- Prompt: 02-documents
- Module: (docs only)
- Target file: (docs only)

## Target Declarations

- (docs-only prompt; no decls)

## Read Before Editing

Read this file, the target prompt, target files, listed source/template line ranges, and named APIs only.

## Proof Task

- Deliver **RLP-DOCUMENTS**: Add Content-Length framing, initialize/shutdown, bounded document store, didOpen/didChange/didClose, versions, cancellation tokens, configuration reload, health/logging, and malformed-message recovery.
- Read `roadmap.md`, its prerequisite stack results, `AGENTS.md`, the current implementation and tests, and the relevant Lean compiler/Lake sources before changing an interface. Write interface comments and characterization tests before implementation where the behavior is not already frozen.

## Reuse

- see the target prompt's Read section

## Documentation Work

Edit only the records named by the prompt. Do not execute planned mathematical or Lean prompts.

## Stop Rules

- No unbounded request queue or buffer history.
- A closed/stale document cannot publish diagnostics.
- Stop rather than weakening exact semantics, write safety, or the resource envelope.
