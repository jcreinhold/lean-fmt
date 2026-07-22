# Rule catalog

Generated from the rule registry (`LeanFmt/Rules.lean`); do not edit by hand.

## debug

| Code | Lifecycle | Default | Fix | Summary |
| --- | --- | --- | --- | --- |
| [FMT010](FMT010.md) | preview | off | report-only | report a development-only set_option left in source |

## deprecation

| Code | Lifecycle | Default | Fix | Summary |
| --- | --- | --- | --- | --- |
| [FMT012](FMT012.md) | preview | off | fixable | report use of a deprecated declaration |

## docs

| Code | Lifecycle | Default | Fix | Summary |
| --- | --- | --- | --- | --- |
| [FMT006](FMT006.md) | preview | off | report-only | require a module docstring when a module declares anything |

## imports

| Code | Lifecycle | Default | Fix | Summary |
| --- | --- | --- | --- | --- |
| [FMT003](FMT003.md) | stable | on | fixable | remove a duplicate import |
| [FMT004](FMT004.md) | stable | on | report-only | report an import made redundant by another import's transitive closure |
| [FMT005](FMT005.md) | stable | on | report-only | report imports out of canonical order within a group |

## naming

| Code | Lifecycle | Default | Fix | Summary |
| --- | --- | --- | --- | --- |
| [FMT015](FMT015.md) | preview | off | report-only | report a bound variable that resembles a nullary constructor |

## redundancy

| Code | Lifecycle | Default | Fix | Summary |
| --- | --- | --- | --- | --- |
| [FMT008](FMT008.md) | preview | off | fixable | remove a duplicate attribute in an attribute list |
| [FMT009](FMT009.md) | preview | off | fixable | remove a duplicate deriving class |
| [FMT011](FMT011.md) | stable | off | fixable | remove redundant nested parentheses |

## security

| Code | Lifecycle | Default | Fix | Summary |
| --- | --- | --- | --- | --- |
| [FMT001](FMT001.md) | stable | on | report-only | reject forbidden control bytes in source |
| [FMT002](FMT002.md) | stable | on | report-only | flag suspicious bidirectional controls in source |

## structure

| Code | Lifecycle | Default | Fix | Summary |
| --- | --- | --- | --- | --- |
| [FMT007](FMT007.md) | preview | off | report-only | report an unclosed section or namespace |

## unused

| Code | Lifecycle | Default | Fix | Summary |
| --- | --- | --- | --- | --- |
| [FMT013](FMT013.md) | preview | off | report-only | report an unused variable or binder |
| [FMT014](FMT014.md) | preview | off | report-only | report a section variable unused in a theorem |

## Retired codes

These codes name no live rule; they are reserved so a selector or suppression that still references one keeps working.

| Code | Disposition |
| --- | --- |

The machine-readable configuration schema is `schema.json`, generated from the same registry.
