# Frontend-native route audit

This isolated executable exercises the Lean 4 APIs selected by prompt `LFF-API-AUDIT`. `AuditSyntax.lean` is a compiled
project extension module with custom command, term, tactic, notation, and explicit formatter registrations. The probe
processes an in-memory consumer module, keeps its actual `Syntax` and final `Environment`, formats core and imported
project syntax at three widths, observes comment behavior and the `#exit` boundary, and passes an `InitialSnapshot`
through six edit classes while comparing command-result task identity.

Run it with the pinned toolchain:

```sh
lake update
lake build
lake exe frontendNativeAudit
```

The probe is evidence only. It is not imported by any production target.
