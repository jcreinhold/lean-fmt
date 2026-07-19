# Evidence 01-schema — the current rule catalog (baseline to map)

Captured 2026-07-19T15:29:27Z from a clean `lake build` on:

```
leanprover/lean4:v4.32.0
bef35fe442af571b746dc6abe35037cd56da06ed
```

## `lean-fmt rules` (text)

```
FMT003	security	report-only	default	reject forbidden control bytes in source
FMT004	security	report-only	default	flag suspicious bidirectional controls in source
FMT008	docs	report-only	optional	require a module docstring when a module declares anything
FMT009	structure	report-only	optional	report an unclosed section or namespace
FMT010	redundancy	fixable	optional	remove a duplicate attribute in an attribute list
FMT011	redundancy	fixable	optional	remove a duplicate deriving class
FMT012	debug	report-only	optional	report a development-only set_option left in source
FMT013	redundancy	fixable	optional	remove redundant nested parentheses
FMT014	deprecation	fixable	optional	report use of a deprecated declaration
FMT015	unused	report-only	optional	report an unused variable or binder
FMT016	unused	report-only	optional	report a section variable unused in a theorem
FMT017	naming	report-only	optional	report a bound variable that resembles a nullary constructor
FMT005	imports	fixable	default	remove a duplicate import
FMT006	imports	report-only	default	report an import made redundant by another import's transitive closure
FMT007	imports	report-only	default	report imports out of canonical order within a group
```

## `lean-fmt rules --json` (compact)

```json
[{"category":"security","code":"FMT003","defaultEnabled":true,"fixable":false,"input":"source","summary":"reject forbidden control bytes in source"},{"category":"security","code":"FMT004","defaultEnabled":true,"fixable":false,"input":"source","summary":"flag suspicious bidirectional controls in source"},{"category":"docs","code":"FMT008","defaultEnabled":false,"fixable":false,"input":"syntax","summary":"require a module docstring when a module declares anything"},{"category":"structure","code":"FMT009","defaultEnabled":false,"fixable":false,"input":"syntax","summary":"report an unclosed section or namespace"},{"category":"redundancy","code":"FMT010","defaultEnabled":false,"fixable":true,"input":"syntax","summary":"remove a duplicate attribute in an attribute list"},{"category":"redundancy","code":"FMT011","defaultEnabled":false,"fixable":true,"input":"syntax","summary":"remove a duplicate deriving class"},{"category":"debug","code":"FMT012","defaultEnabled":false,"fixable":false,"input":"syntax","summary":"report a development-only set_option left in source"},{"category":"redundancy","code":"FMT013","defaultEnabled":false,"fixable":true,"input":"syntax","summary":"remove redundant nested parentheses"},{"category":"deprecation","code":"FMT014","defaultEnabled":false,"fixable":true,"input":"semantic","summary":"report use of a deprecated declaration"},{"category":"unused","code":"FMT015","defaultEnabled":false,"fixable":false,"input":"semantic","summary":"report an unused variable or binder"},{"category":"unused","code":"FMT016","defaultEnabled":false,"fixable":false,"input":"semantic","summary":"report a section variable unused in a theorem"},{"category":"naming","code":"FMT017","defaultEnabled":false,"fixable":false,"input":"semantic","summary":"report a bound variable that resembles a nullary constructor"},{"category":"imports","code":"FMT005","defaultEnabled":true,"fixable":true,"input":"source","summary":"remove a duplicate import"},{"category":"imports","code":"FMT006","defaultEnabled":true,"fixable":false,"input":"source","summary":"report an import made redundant by another import's transitive closure"},{"category":"imports","code":"FMT007","defaultEnabled":true,"fixable":false,"input":"source","summary":"report imports out of canonical order within a group"}]
```

## Reserved codes not printed by `rules` (grepped from source)

```
FMT001, FMT002  retired (line-boundary / eof) — Suppression.lean:192, Printer.lean:220,253,1903, ArtifactModel.lean:212, Application.lean:520,541
FMT900          suppression self-diagnostic: unused directive  — Suppression.lean:327,335
FMT901          suppression self-diagnostic: malformed directive — Suppression.lean:199,263
```
