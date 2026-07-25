# Frontend-native formatter contract

`run.sh` checks a candidate before the replacement renderer exists. A candidate reads normalized Lean source from stdin
and emits one JSON response with canonical text, a complete non-overlapping source map, exact source/setup identities,
cancellation state, and unsupported syntax ranges. Run the built-in identity and injected-negative suite with:

```sh
tests/formatter/run.sh
```

To admit a prototype through the same gates, append its command and arguments:

```sh
tests/formatter/run.sh path/to/candidate --its-options
```

The oracle reparses original and candidate bytes through `__analyze-exact`, compares parsed ordered imports, exact
terminal/tail bytes, token spelling/order, comment kind/payload/owner, and normalized node kind/parent/child order, then
runs a second formatter pass. It deliberately erases byte positions, source-info tags, and whitespace trivia only. It
does not erase syntax kinds, parents, child order, the selected first `choice` branch represented by the projection,
token-to-node ownership, command order, or terminal boundaries.
