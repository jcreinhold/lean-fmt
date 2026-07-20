# RCD-SPEC — measured baseline

Raw transcripts backing `notes/01-discovery.md`. Machine: Darwin 25.5.0 (arm64). Toolchain
`leanprover/lean4:v4.33.0-rc1`. Repository commit `62e23fa` (`main`, clean). Binary
`.lake/build/bin/lean-fmt`, built by `LEAN_NUM_THREADS=1 lake build` (exit 0).

Probe project `P` = a scratch two-file Lake project on the same toolchain, outside the repository.

---

## 1. Baseline build

```
$ cd /Users/jcreinhold/Code/lean-fmt && LEAN_NUM_THREADS=1 lake build
(exit 0)
```

---

## 2. Lake's `lakefile.toml` tolerates unknown keys (§3.1)

Backs the rejected `[tool.lean-fmt]` alternative: the capability exists, and is declined on durability
grounds, not because it fails.

`P/lakefile.toml`:

```toml
name = "probe"
defaultTargets = ["Probe"]

[[lean_lib]]
name = "Probe"

[tool.lean-fmt]
line-width = 88
```

```
$ lake resolve-deps
(no output; exit 0)
$ lake build
✔ [2/3] Built Probe (171ms)
Build completed successfully (3 jobs).
(exit 0)
```

With an unknown **top-level scalar** added (`bogusKey = 1` after `name`):

```
$ lake resolve-deps
(no output; exit 0)
```

So Lake accepts both an unknown table and an unknown scalar key. Consistent with the decoders, which
read known keys via `t.decode`/`t.find?` under `gen_toml_decoders%`
(`$(lean --print-prefix)/src/lean/lake/Lake/Load/Toml.lean:405-421`) with no reject-unknown pass.
Nothing in Lake documents this tolerance.

---

## 3. Explicit `.lake` paths are accepted, and `format` writes them (§2.1a, §11)

Baseline defect (a). `P/.lake/packages/dep/Dep.lean` created with a duplicate import:

```
module

import Probe
import Probe
```

Discovery correctly skips `.lake` — the no-arg run sees only `Probe.lean`:

```
$ lean-fmt check --root P
mode=check files=1 findings=0 changed=0 written=0 broken=0 rejected=0 withheld_unsafe=0 \
  suppressed=0 infrastructure_failures=0
```

An explicit path into `.lake` is accepted and analyzed:

```
$ lean-fmt check --root P .lake/packages/dep/Dep.lean
.lake/packages/dep/Dep.lean:21-33: FMT005 duplicate import of Probe [safe]
mode=check files=1 findings=1 changed=1 written=0 broken=0 rejected=0 withheld_unsafe=0 \
  suppressed=0 infrastructure_failures=0
(exit 0)
```

And `format` — a writer by default since `ruff-11d` — **modifies the file on disk**. Content reset to
`module\n\ndef    dep   :=    1\n` first:

```
$ lean-fmt format --root P .lake/packages/dep/Dep.lean
.lake/packages/dep/Dep.lean: formatted
mode=format files=1 findings=0 changed=1 written=1 broken=0 rejected=0 withheld_unsafe=0 \
  suppressed=0 infrastructure_failures=0
```

```
$ od -c P/.lake/packages/dep/Dep.lean
0000000    m   o   d   u   l   e  \n  \n   d   e   f       d   e   p
0000020            :   =                   1  \n
0000032
```

`written=1`, and the bytes on disk changed — lean-fmt rewrote a vendored dependency's source. This is
the write-safety defect §11 gate 1 closes.

---

## 4. Live-code locators cited by the freeze

Verified by reading at commit `62e23fa`:

| Claim | Location | Confirmed |
| --- | --- | --- |
| root-only config path | `Config.lean:298` | `let path := explicit?.getD (root / "lean-fmt.toml")` |
| absent config = defaults | `Config.lean:300-302` | returns `defaultConfig` unless `explicit?` |
| unknown key hard error | `Config.lean:216` | `throw s!"unknown configuration key: {unknown}"` |
| flat 12-key schema | `Config.lean:182-217` | no section handling present |
| `PathPattern` is not git semantics | `Config.lean:73-108` | no anchor, no `!`; `**` whole-component only |
| `.lake` skipped in discovery only | `Project.lean:113-116` | `walkDir` predicate |
| requested paths unchecked for `.lake` | `Project.lean:139-160`, `94-106` | existence, `insideRoot`, `.lean` only |
| cache identity seam | `Project.lean:296-307`, `Cache.lean:200-210` | `configuration := ← Project.configurationIdentity` |
| margin is a constant | `Application.lean:382` | `def canonicalWidth : Nat := 100` |
| **stale docstring** | `Application.lean:365-382` | cites `Digest.ofBytes (← IO.FS.readBinFile application)` at `Cache.lean:258` |
| actual formatter identity | `Cache.lean:262-264` | `s!"{application} {stat.byteSize} {stat.modified.sec} {stat.modified.nsec}"` |
| TOML provenance available | `Lake/Toml/Data/Value.lean:27-49` | every constructor carries `ref : Syntax`; `Value.ref` exposes it |
| generated schema key list | `Rules.lean:1193-1231` | `catalogSchemaJson`, `additionalProperties: false` |
| schema drift check | `LeanFmtTest.lean:584` | `"the generated config schema is missing"` |
| flat-schema characterization test | `LeanFmtTest.lean:415-470` | `testConfig` |

The stale-docstring row is baseline defect (b): commit `62e23fa` ("cache: derive formatter identity
from binary metadata, not a content hash") replaced the mechanism the docstring cites. Its conclusion
still holds — a rebuild changes size/mtime — but `RCD-IMPL` rewrites it when it promotes the margin.
