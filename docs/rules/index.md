# Rule catalog

Generated from the rule registry (`LeanFmt/Rules.lean`); do not edit by hand.

## debug

| Code | Lifecycle | Default | Fix | Summary |
| --- | --- | --- | --- | --- |
| [FMT012](FMT012.md) | preview | off | report-only | report a development-only set_option left in source |

## deprecation

| Code | Lifecycle | Default | Fix | Summary |
| --- | --- | --- | --- | --- |
| [FMT014](FMT014.md) | preview | off | fixable | report use of a deprecated declaration |

## docs

| Code | Lifecycle | Default | Fix | Summary |
| --- | --- | --- | --- | --- |
| [FMT008](FMT008.md) | preview | off | report-only | require a module docstring when a module declares anything |

## imports

| Code | Lifecycle | Default | Fix | Summary |
| --- | --- | --- | --- | --- |
| [FMT005](FMT005.md) | stable | on | fixable | remove a duplicate import |
| [FMT006](FMT006.md) | stable | on | report-only | report an import made redundant by another import's transitive closure |
| [FMT007](FMT007.md) | stable | on | report-only | report imports out of canonical order within a group |

## naming

| Code | Lifecycle | Default | Fix | Summary |
| --- | --- | --- | --- | --- |
| [FMT017](FMT017.md) | preview | off | report-only | report a bound variable that resembles a nullary constructor |

## redundancy

| Code | Lifecycle | Default | Fix | Summary |
| --- | --- | --- | --- | --- |
| [FMT010](FMT010.md) | preview | off | fixable | remove a duplicate attribute in an attribute list |
| [FMT011](FMT011.md) | preview | off | fixable | remove a duplicate deriving class |
| [FMT013](FMT013.md) | stable | off | fixable | remove redundant nested parentheses |

## security

| Code | Lifecycle | Default | Fix | Summary |
| --- | --- | --- | --- | --- |
| [FMT003](FMT003.md) | stable | on | report-only | reject forbidden control bytes in source |
| [FMT004](FMT004.md) | stable | on | report-only | flag suspicious bidirectional controls in source |

## structure

| Code | Lifecycle | Default | Fix | Summary |
| --- | --- | --- | --- | --- |
| [FMT009](FMT009.md) | preview | off | report-only | report an unclosed section or namespace |

## unused

| Code | Lifecycle | Default | Fix | Summary |
| --- | --- | --- | --- | --- |
| [FMT015](FMT015.md) | preview | off | report-only | report an unused variable or binder |
| [FMT016](FMT016.md) | preview | off | report-only | report a section variable unused in a theorem |

## Retired codes

These codes name no live rule; they are reserved so a selector or suppression that still references one keeps working.

| Code | Disposition |
| --- | --- |
| FMT001 | retired: line-boundary normalization is now part of canonical formatting; run `format` |
| FMT002 | retired: trailing-newline normalization is now part of canonical formatting; run `format` |

The machine-readable configuration schema is `schema.json`, generated from the same registry.
