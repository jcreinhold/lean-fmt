# Getting Lean code into a document

Verso offers three ways to show Lean code. They differ in what they cost this repository, and the
upstream templates lead with the most expensive one, so the order here is deliberately reversed.

Pick the cheapest option that answers the question the example is being asked to answer.

## Contents

- [Tier 1 — inline examples (default)](#tier-1)
- [Tier 2 — requiring lean-fmt from the docs package](#tier-2)
- [Tier 3 — anchors into LeanFmt sources (needs a decision)](#tier-3)
- [Choosing](#choosing)

<a id="tier-1"></a>
## Tier 1 — inline examples (default)

The code lives in the document, and the docs package elaborates it. Nothing outside `docs/` is
touched. This covers most of what lean-fmt's documentation needs, because most of it is about
*Lean source* — what canonical style looks like, what a rule reports — not about lean-fmt's own API.

Requires `open Verso.Genre.Manual.InlineLean` in the module.

````lean
```lean
def twice (n : Nat) : Nat := n + n
```
````

The block elaborates in the document's environment. A snippet that does not compile fails the build.

To show what a snippet evaluates to, or what error it produces, name the block with `(name := ...)`
and quote the message in a `leanOutput` block carrying that same name:

````lean
```lean (name := twiceEval)
def twice (n : Nat) : Nat := n + n

#eval twice 21
```
```leanOutput twiceEval
42
```
````

The name is not optional — a bare ` ```leanOutput ` fails the build with
`Positional argument 'name' (output name) not found`.

The output must match what Lean actually produced. That is the point — a transcribed output drifts,
a checked one cannot.

Other useful blocks in this tier:

| Block | Shows |
| --- | --- |
| `lean` | A command or declaration, elaborated |
| `leanTerm` | A term rather than a command |
| `leanOutput NAME` | The message the block named `NAME` produced |
| `signature` | A declaration's signature, pulled from the environment |
| `syntaxError` | Source that is *supposed* to fail to parse, with the error |
| `exampleFile`, `stdin`, `stdout`, `stderr`, `ioLean` | A file's contents and a program's I/O — useful for documenting CLI behaviour |

Inline roles for referring to code in prose: `` {lean}`expr` `` elaborates and highlights an
expression, `` {name}`Foo.bar` `` links a name to its definition, and `` {lit}`text` `` is literal
text that should not be elaborated.

**Scope for lean-fmt:** everything about canonical style, every before-and-after layout example,
every configuration snippet, every illustration of what a rule flags. If the example is Lean that a
*user* would write, it belongs here.

<a id="tier-2"></a>
## Tier 2 — requiring lean-fmt from the docs package

When a document needs to name lean-fmt's own API — `RuleInfo`, `Tier`, `SourceFacts` — the docs
package can require the `lean-fmt` package by path:

```toml
[[require]]
name = "lean-fmt"
path = "../.."
```

Then `import LeanFmt.Rules` in the document module and use `{name}` and `signature` against real
declarations.

The direction matters and is the whole reason this is affordable: **lean-fmt is the dependency, not
the dependent.** The root `lakefile.lean` and `lake-manifest.json` are untouched, so `lake build`,
`lake test`, and `lake lint` inside `lean-fmt/` see exactly what they saw before, and no cache entry
is affected.

Two things to verify the first time you do this, because they are cheap to check and expensive to
discover later:

1. `lake build` at the repository root still succeeds and `git status` shows no change to
   `lake-manifest.json`.
2. A warm `lean-fmt check` at the root still hits its cache — run it twice and compare the
   `--statistics` output. Building the docs package builds lean-fmt's modules into the same
   `.lake/build`, and if the docs workspace passes different Lean options, those artifacts differ
   from the ones a plain `lake build` produces.

If either check fails, fall back to tier 1 and describe the API in prose rather than importing it.

**Scope for lean-fmt:** `docs/adding-a-rule.md`'s material is the natural candidate — it is full of
references to `RuleImpl`, `ruleRegistry`, and `Tier` that are currently plain backticks and would
become checked links.

<a id="tier-3"></a>
## Tier 3 — anchors into LeanFmt sources (needs a decision)

Verso can pull a named region straight out of a source file, keeping the documentation and the code
literally the same bytes. You mark the region in the source:

```lean
-- ANCHOR: ruleShape
structure RuleInfo where
  code : String
-- ANCHOR_END: ruleShape
```

and include it in the document:

````lean
```anchor ruleShape
structure RuleInfo where
  code : String
```
````

The block's contents must match the anchored region, so the build fails when the source moves on.
That is genuinely the best guarantee Verso offers.

**It requires adding `subverso` to the root `lakefile.lean`.** Verso's own documentation states the
constraint directly: "The example project must depend on the same version of `subverso` that the
document's Verso version uses." Building the document runs, inside the example project's directory:

```
elan run --install <toolchain> lake build subverso-extract-mod
elan run --install <toolchain> lake build +<Module>:highlighted
```

Neither target exists without the dependency.

So tier 3 costs:

- a dependency in a package that has had none, which every consuming project inherits
- every `.lean-fmt-cache` entry invalidated whenever the `subverso` pin moves, because cache
  identity folds the ordered Lake environment
- `ANCHOR` comments in production sources, which the formatter must then leave alone

**Do not do this on your own judgment.** Present the tradeoff and let the user decide. If they say
yes, pin `subverso` to the revision Verso itself pins (read `lakefile.lean` in the Verso repository
at the matching tag) — a mismatch fails with a deserialization error that does not name the cause.

<a id="choosing"></a>
## Choosing

Ask what the example is for.

*Showing a reader what Lean looks like under this style* → tier 1. The code is illustrative; it does
not need to be lean-fmt's code.

*Naming a type or function in lean-fmt's API so the reader can find it* → tier 2. A `{name}` link to
a real signature beats a backticked string that rots silently.

*Guaranteeing a documented internal stays identical to the shipped source* → tier 3, and only with
the user's agreement.

When in doubt, tier 1. An example that is checked but slightly idealized serves a reader better than
a build that nobody can run.
