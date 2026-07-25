# Frontend-native formatter prototype

This isolated experiment compares the two adapter/document shapes required by `LFF-PROTOTYPE`. Neither module is
reachable from a production Lake target.

- `converted` calls the live registered formatter on each actual command, eagerly converts the complete `Std.Format`
  tree into a richer tagged document, then lowers that document for rendering. It therefore pays two full document
  traversals and allocates one rich node per native node.
- `opaque` retains a registered extension format as one opaque command document. Its explicit rule for the closed core
  form `def ident := term` composes the registered `ppTerm` document for the actual nested term node. The rule keeps the
  declaration separator flat, intentionally differing from `ppCommand`'s unconditional body break without reconstructing
  syntax or parsing rendered text.

Both shapes render through `Std.Format.prettyM` with an instrumented output monad. The candidate JSON reports document
nodes, converted nodes, output callbacks, tag/source boundaries, core overrides, comment-owned identity regions, changed
commands, and formatter failures. Runtime allocation counts are explicitly reported unavailable; `convertedNodes` is the
deterministic allocation-pressure proxy. Commands whose original trivia contains comments remain byte-identical in this
prototype so the adapter comparison cannot silently inherit `ppCommand`'s known comment-loss gaps. Production comment
attachment is a later prompt, not a regex repair here.

Run:

```sh
./run.sh
```

The script admits both candidates through `tests/formatter/oracle.py`, checks width sensitivity and the intentional core
override, and covers the synthetic extension fixture, two lean-fmt modules, and three modules from the current
`/Users/jcreinhold/Code/mathlib4` checkout. It uses each target project's `lake setup-file` result and `LEAN_PATH`; no
grammar table, synthetic syntax node, rendered text parser, or regular-expression recovery is involved.
