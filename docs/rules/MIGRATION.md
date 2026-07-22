# Rule code renumbering (pre-release)

The live catalog was renumbered to start at `FMT001`. Every code shifted down by two.

This is a **breaking change to the public code namespace** and it was made exactly once, before the
package had users. It is recorded here rather than in a changelog line because it reuses two retired
codes, which the catalog's own rules forbid.

## The mapping

| Was | Is | Rule |
| --- | --- | --- |
| FMT003 | **FMT001** | reject forbidden control bytes in source |
| FMT004 | **FMT002** | flag suspicious bidirectional controls in source |
| FMT005 | **FMT003** | remove a duplicate import |
| FMT006 | **FMT004** | report an import made redundant by another import's transitive closure |
| FMT007 | **FMT005** | report imports out of canonical order within a group |
| FMT008 | **FMT006** | require a module docstring when a module declares anything |
| FMT009 | **FMT007** | report an unclosed section or namespace |
| FMT010 | **FMT008** | remove a duplicate attribute in an attribute list |
| FMT011 | **FMT009** | remove a duplicate deriving class |
| FMT012 | **FMT010** | report a development-only `set_option` left in source |
| FMT013 | **FMT011** | remove redundant nested parentheses |
| FMT014 | **FMT012** | report use of a deprecated declaration |
| FMT015 | **FMT013** | report an unused variable or binder |
| FMT016 | **FMT014** | report a section variable unused in a theorem |
| FMT017 | **FMT015** | report a bound variable that resembles a nullary constructor |

`FMT900` and `FMT901`, the suppression engine's meta self-diagnostics, are **unchanged**.

## What this reused, and why that is not a precedent

`FMT001` and `FMT002` were not free. They were *retired* codes: the line-boundary and trailing-newline
rules, which `ruff-11c` folded into canonical formatting. They sat in `reservedCodes`, and the catalog
holds retired codes forever on purpose — so that a stale `lean-fmt.toml` or a
`-- lean-fmt: ignore[FMT001]` comment written against an old version stays *inert* rather than
silently binding to a different rule.

Reusing them is precisely the hazard that machinery prevents. It was allowed here because the package
is pre-release with no users, so no config file and no suppression comment anywhere could be pointing
at the old meanings. **That argument expires the moment someone depends on this package.** After that,
a retired code is permanent and the next renumbering is not available.

Had there been users, the failure mode would have been silent and bad: an old
`-- lean-fmt: ignore[FMT001]` written to silence trailing-whitespace warnings would now suppress
**FMT001, the forbidden-control-byte security rule**, in whatever file carried it.

## What this cost

`reservedCodes` is now empty. The retirement machinery — `isReservedCode`, `reservedDisposition?`,
`explain`'s `[retired]` branch, the reserved-selector branch in `Config.selectorsValid`, and the
inert-directive branch in `Suppression.apply` — is all still present and still correct, but it has no
live instance, so **it is untested**.

Three unit cases and one shell case that covered it were **deleted rather than repointed**, along with
the `tests/suppression/RetiredInert.lean` fixture. Repointing them at `FMT001` would have left tests
that still passed while testing a live security rule instead of a retired code — a test that survives
the redefinition of its own subject is worse than no test, because it reads as coverage.

A placeholder retired code, invented to give those tests something to assert against, was considered
and rejected: it would prove the placeholder exists, not that the machinery works. Coverage returns
when a rule genuinely retires.

## Historical records

The prompt stacks under `docs/projects/` used the old codes throughout and were deleted wholesale
after this renumbering, so no record outside this file still refers to them. Anything predating this
table — an old branch, a saved report, a downstream `ignore[…]` written before release — must be read
against it.
