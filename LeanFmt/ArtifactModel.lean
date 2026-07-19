module

import all LeanFmt.LosslessSource
import Lean

namespace LeanFmt.Internal

/-- A conservative replacement. Applying edits is deliberately not part of the compiler plugin. -/
structure Edit where
  range : SourceRange
  replacement : String
  deriving Inhabited, BEq, DecidableEq, Repr, Lean.ToJson, Lean.FromJson

/-- How safe it is to apply a fix, following ruff's `Applicability`.

- `safe`: the rule's stated evidence guarantees the intended runtime/proof meaning is preserved.
  Applied by default.
- `unsafe`: the fix is plausibly intended, but the rule cannot prove it preserves behavior, comments,
  or intent. Shown by default; applied only under explicit opt-in (`--unsafe-fixes`, or a per-rule
  `extend-safe-fixes` promotion).
- `displayOnly`: never applied. It illustrates the finding for a reader or an editor; configuration
  cannot promote it, because a rule that declined to make an edit applicable cannot be argued into it.

"Safe" is a claim under the rule's evidence and is tied to the rule's tier — never merely "it
reparses". See `docs/projects/ruff-06-fix-safety/notes/01-model.md` §1. -/
inductive Applicability where
  | safe
  | «unsafe»
  | displayOnly
  deriving Inhabited, BEq, DecidableEq, Repr

/-- The wire spelling. Explicit and kebab-cased to match the product's config vocabulary
(`extend-safe-fixes`, `per-file-ignores`) rather than relying on a derived enum encoding. -/
def Applicability.toWire : Applicability → String
  | .safe => "safe"
  | .unsafe => "unsafe"
  | .displayOnly => "display-only"

instance : ToString Applicability := ⟨Applicability.toWire⟩

/-- Whether a fix of this applicability is applied under the current opt-in. Safe always; unsafe only
with `--unsafe-fixes`; display-only never. This is the one admission rule the whole product uses, so
`format`, `diff`, and `fix` agree on what a run would apply. -/
def Applicability.admitted (unsafeFixes : Bool) : Applicability → Bool
  | .safe => true
  | .unsafe => unsafeFixes
  | .displayOnly => false

instance : Lean.ToJson Applicability := ⟨fun a => .str a.toWire⟩

instance : Lean.FromJson Applicability := ⟨fun json => do
  match ← json.getStr? with
  | "safe" => .ok .safe
  | "unsafe" => .ok .unsafe
  | "display-only" => .ok .displayOnly
  | other => .error s!"unknown applicability: {other}"⟩

/-- A proposed transformation attached to a finding: one applicability governing the whole edit set.

Several edits form one atomic fix — disjoint by construction — so applicability is a property of the
fix and not of any single `Edit`, which is a byte fact carrying no judgment. `notes/01-model.md` §1
records why this is a structure rather than a field on `Edit` or on `Finding`. -/
structure Fix where
  applicability : Applicability
  edits : Array Edit
  deriving Inhabited, BEq, DecidableEq, Repr, Lean.ToJson, Lean.FromJson

inductive Severity where
  | information
  | warning
  | error
  deriving Inhabited, BEq, DecidableEq, Repr, Lean.ToJson, Lean.FromJson

/-- What a rule concluded. Rules run outside the compiler, so this is never produced here; it is the
shape a finding takes in a report and in a fix. -/
structure Finding where
  code : String
  severity : Severity
  message : String
  range : SourceRange
  fix? : Option Fix := none
  deriving Inhabited, BEq, DecidableEq, Repr, Lean.ToJson, Lean.FromJson

/-- One compiler diagnostic the exact frontend emitted, normalized into immutable data a semantic-tier
rule reads. A *fact*, never a *finding*: only the frontend could produce it (it ran the linters and
the elaborator), and a reader cannot recompute it from the bytes it holds; the rule that surfaces it
concludes the lean-fmt code, applicability, and reporting shape. Carried in the artifact only when a
consumer demanded the `.semantic` tier (`ruff-11` RMR-SPEC `notes/01-authority.md` §4).

- `kind` is the message's top-level tag (`Lean.Message.kind`) — the linter's option name
  (`linter.unusedVariables`) or the deprecation attribute (`Lean.Linter.deprecatedAttr`). It is the
  **stable** identity a rule keys on; the message *text* is version-volatile and is preserved as
  `message` detail, never asserted as the rule's own claim.
- `range` is normalized-source byte offsets, recovered from the message's `Position` through the exact
  frontend's `FileMap` (which `mkInputContext` builds on `crlfToLf`-normalized source), so it shares
  the projection's one coordinate system. Clamped to the module's own byte span at capture, so a
  macro-reattributed position never yields a finding off the file. -/
structure Diagnostic where
  kind : String
  range : SourceRange
  severity : Severity
  message : String
  deriving Inhabited, BEq, Repr, Lean.ToJson, Lean.FromJson

/-- The declared inter-atom spacing of one notation/atom syntax kind: the untrimmed declared atom
strings, in source order (`" + "` for infix add, `"-"` for prefix neg). A leading or trailing ASCII
space in a string is the notation's declared breakable gap on that side; its absence is tight. This
is the pretty-printing hint the parser trims away (`Init/Prelude.lean:5389`,
`Lean/Parser/Basic.lean:1114`), recovered as data from the notation's `ParserDescr` where the
`Environment` is live. Keyed by `kind` (the `SyntaxNodeKind` string, matching the projection's node
kinds), never by bare token — one token declares different gaps in different kinds (`ruff-05b`
`notes/01-semantic-facts.md` §2-3). -/
structure NotationSpacing where
  kind : String
  atoms : Array String
  deriving Inhabited, BEq, Repr, Lean.ToJson, Lean.FromJson

/-- The semantic facts for one module, captured from the live exact frontend and carried in the
artifact only when a consumer demanded the `.semantic` tier. Two sub-facts, captured together
(monolithic, `ruff-11` `notes/01-authority.md` §6): a demanded `.semantic` artifact carries both, so
`Tier.satisfies` stays a sound cache gate and a notations-only entry never silently under-serves a
rule.

- `notations` (`ruff-05b`, formatter fact): declared spacing for every notation kind present, one
  entry per distinct kind (Design B).
- `diagnostics` (`ruff-11`, rule fact, new in `v5`): the compiler's own diagnostics with a stable
  `kind` tag and exact range, which the semantic-tier rules FMT014–FMT017 surface. -/
structure SemanticProjection where
  notations : Array NotationSpacing
  diagnostics : Array Diagnostic := #[]
  deriving Inhabited, BEq, Repr, Lean.ToJson, Lean.FromJson

/- The artifact is stored inside the successful module's `.olean`; exact toolchain, options,
plugins, ordered imports, and dependency identity therefore belong to the module artifact itself
rather than to a parallel cache identity.

`source` carries both the projection and the artifact's whole identity. There is no second module
name or source digest beside it: a duplicate identity is one that can disagree with itself.

**Facts, never findings.** This carries what a reader cannot recompute — the exact frontend's
projection — and nothing a reader could derive from bytes it already holds. It held `findings` and a
`trailingWhitespace` flag until `RRE-IMPL`; `notes/01-rule-facts.md` §6 has the argument and §2-3
have the two measured defects that made it. The short version is that a conclusion in here is a
second decider: `check` never reads an artifact, so it decided FMT001 for itself and disagreed. The
long version is that the rules were in the compiler plugin's import closure, which put one lint
rule's message text inside every module's compiled bytes. Both are gone by construction now, because
there is nothing here to disagree with and no reason for the plugin to link a rule.

`ruff-11` adds further semantic facts beside `source`. They are facts too, and the same rule applies:
elaboration evidence belongs here because only the frontend can make it; what a rule concludes from
it does not. -/
structure ModuleArtifact where
  schema : String
  source : LosslessSource
  /-- The semantic projection (`v5`): declared notation spacing and normalized compiler diagnostics,
  `none` unless a consumer demanded it. Optional because the two producers differ — the always-on
  compiler plugin emits `none` (no capture in an integrated build), and the on-demand `analyzeExact`
  emits `some` only when the run's tier reaches `.semantic` (a `format` run, or a run selecting a
  `.semantic` rule). See `ruff-05b` `notes/01-semantic-facts.md` §1, `ruff-11` `notes/01-authority.md`
  §6. -/
  semantic : Option SemanticProjection := none
  deriving BEq, Repr, Lean.ToJson, Lean.FromJson

/-- Bumped from `v1` when the command-kind/range projection became `LosslessSource`, from `v2` when
findings and their rule configuration left the artifact, from `v3` when the optional `semantic`
projection was added (`ruff-05b` `RSF-IMPL`), and from `v4` when that projection gained `diagnostics`
(`ruff-11` `RMR-IMPL`). A stale payload must miss, never read as captured-and-empty: a `v4` full
`semantic` (notations, no `diagnostics` key) does not even decode under `v5` — the derived `FromJson`
does not default an absent array field, it errors (verified, v4.32.0) — and a `v4` payload without the
`semantic` key at all decodes with `semantic := none` and is then rejected by the schema guard. Both
paths are a miss that forces re-analysis; the schema tag is the gate, decode-failure a backstop — the
same discipline that made findings leave the artifact rather than default silently. -/
def artifactSchema : String := "lean-fmt.module-artifact.v5"

/-- Build the artifact for one accepted module.

This is the only artifact producer. Exact analysis and the compiler plugin reach it with the same
arguments, so they cannot drift into emitting different artifacts for the same module — which is
what makes the facet a sound cache of the exact frontend rather than a second opinion.

It takes no rule configuration, and that is the point rather than an omission: an artifact is a
function of the module and its source alone, so turning a rule on cannot rebuild or re-elaborate
anything. The optional `semantic` projection is likewise a function of the module and its environment;
it defaults to `none` so the always-on plugin producer stays on the syntax-only path, and only
`analyzeExact` passes `some` under demand. -/
def ModuleArtifact.ofParsedModule (mainModule normalized : String)
    (commands : Array Lean.Syntax) (terminal? : Option Lean.Syntax)
    (semantic : Option SemanticProjection := none) : ModuleArtifact := {
  schema := artifactSchema
  source := LosslessSource.ofSource mainModule normalized commands terminal?
  semantic
}

def artifactLinter : Lean.Name := `leanFmt.semanticArtifact

end LeanFmt.Internal
