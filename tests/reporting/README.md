# Reporting format tests

`run.sh` exercises the machine-readable report formats added by `ruff-15` RRF-IMPL. The frozen
contract is the format section of `docs/ci.md`.

## Vendored schema

`sarif-schema-2.1.0.json` is the SARIF 2.1.0 JSON schema, fetched from
`https://json.schemastore.org/sarif-2.1.0.json`. It is vendored so the suite validates offline and so
a schema revision upstream cannot silently change what this repository claims to have verified.

The OASIS specification (§3.13.3, NOTE 2) names
`https://raw.githubusercontent.com/oasis-tcs/sarif-spec/master/Schemata/sarif-schema-2.1.0.json` as the
canonical location; that URL now 404s, which is why the SchemaStore copy is the one used. The `$schema`
property our renderer emits still points at the specification's own URI, because that is the identifier
the format defines, not a promise that the URL resolves.

## Independent parsers

Structured output is checked by real consumers, not by our own string matching — a renderer and a
bespoke checker can agree on the same mistake:

- SARIF: `check-jsonschema` against the vendored schema, plus assertions for the conformance rules the
  schema does not encode (`columnKind`, `executionSuccessful`, descriptor coverage).
- JUnit: `xmllint --noout` for well-formedness, plus `junitparser` reading every suite, case, result
  type, and aggregate count back.

Both arrive through `uv run --with`, so the suite needs no system package.

## Fixtures

`Unicode.lean` puts multi-byte characters before a finding, so a byte column and a codepoint column
disagree (byte 31 versus codepoint 27 on line 8). Cases needing a hostile path or CRLF bytes go through
`--stdin-filename`, which `ruff-14` froze as an identity that need not exist — a repository cannot
track a file named `dir,with:punct/Buffer.lean`, and git will not preserve a CRLF fixture on disk.
