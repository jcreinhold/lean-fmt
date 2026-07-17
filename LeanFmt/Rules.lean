module

import all LeanFmt.ArtifactModel
import Lean

namespace LeanFmt.Internal

/-! # The rule engine

A rule declares what it needs to decide, and gets exactly that and nothing else. The declaration is
`RuleImpl`'s constructor rather than a field, because a field is what drifted: `RuleInfo.input` used
to be a claim no code had to honor, and `RulePlan.requiresSyntax` answered `false` for the product's
whole life as a result. `notes/01-rule-facts.md` §1 and §7 are the argument; the shape is Lean's own
`Linter` (`Lean/Elab/Command.lean:64-70`) minus the mutable ref it needs for plugin loading and this
does not.

Rules run **outside** the compiler, against immutable facts. A rule cannot reach a workspace, a
cache, an `Environment`, or `IO` — not by convention but because `run`'s argument type is a fact view
and its result is an `Array Finding`. -/

/-- What a rule needs in order to decide, ordered by what it costs to obtain.

`source` facts are free: the file was read. `syntax` facts need the exact frontend, so a run that
selects any `syntax` rule needs a current `.olean` and its facet, or a frontend invocation. `semantic`
facts also need the exact frontend, but additionally read the module's `Environment` — the parser and
notation declarations — which the projection does not otherwise carry.

The `semantic` case is added by `ruff-05b` (`RSF-IMPL`), which supplies all three things `ruff-05`
required before a tier may exist — a producer, a consumer, and a test — so this is not the empty tier
`RuleInfo.input` rotted into. Its producer is `analyzeExact`, which captures the declared notation
spacing from the live `Environment` (`Analysis.lean`); its consumer is the **formatter** (not a rule
yet — `ruff-11` adds semantic rules later, and only then do `Facts`/`RuleImpl` gain a `semantic`
case); and it is exercised through the demand-gating seam (`RulePlan.demandedTier`) and the artifact
round-trip tests. A `format` run demands this tier; a source/syntax-only run never does. -/
inductive Tier where
  | source
  | «syntax»
  | semantic
  deriving Inhabited, BEq, DecidableEq, Repr, Lean.ToJson, Lean.FromJson

/-- Whether facts of tier `available` can run a rule of tier `required`. The tiers form a chain
`source ≤ syntax ≤ semantic`: richer facts serve any cheaper requirement. -/
def Tier.satisfies (available required : Tier) : Bool :=
  match required, available with
  | .source, _ => true
  | .syntax, .source => false
  | .syntax, .syntax => true
  | .syntax, .semantic => true
  | .semantic, .semantic => true
  | .semantic, .source => false
  | .semantic, .syntax => false

/-- The cheaper of two tiers cannot serve the dearer, so a run needs the maximum of what it selects. -/
def Tier.max (left right : Tier) : Tier :=
  if left.satisfies right then left else right

/-- What a `source`-tier rule may read: the module's normalized source, and nothing else.

Normalized, never raw. `Parser.mkInputContext` normalizes before assigning any position, so every
compiler-produced offset indexes `raw.crlfToLf`; a finding measured against the file's own bytes and
a projection measured against the normalized string are two coordinate systems in one artifact. Only
reading a file and publishing one may touch raw bytes.

`bytes` is derived, and derived once. Every source rule wants UTF-8 — they are byte-level by nature —
and computing `normalized.toUTF8` inside each rule would walk the source once per rule. Sharing the
derivation is why this is a structure rather than a bare `String`. -/
structure SourceFacts where
  private mk ::
  normalized : String
  bytes : ByteArray

/-- `normalized` must be `(LosslessSource.normalize raw).1`. -/
def SourceFacts.of (normalized : String) : SourceFacts :=
  { normalized, bytes := normalized.toUTF8 }

/-- What a `syntax`-tier rule may read: the exact frontend's lossless projection, and the source it
indexes. A syntax rule needs both — `LosslessSource` is offsets into the normalized string — so this
nests `SourceFacts` rather than restating it. -/
structure SyntaxFacts where
  private mk ::
  source : SourceFacts
  projection : LosslessSource

/-- `normalized` must be the string `projection` indexes, which `LosslessSource.validFor` is what
proves. This does not re-check that: every caller reaches here past a `validFor`, and re-deriving the
projection's own validity from inside the fact view would make the check circular rather than
independent. -/
def SyntaxFacts.of (normalized : String) (projection : LosslessSource) : SyntaxFacts :=
  { source := SourceFacts.of normalized, projection }

/-- The facts a run actually obtained. `SyntaxFacts` contains `SourceFacts`, so richer facts run
every cheaper rule too, and one run never needs two fact objects. -/
inductive Facts where
  | source (facts : SourceFacts)
  | «syntax» (facts : SyntaxFacts)

/-- The source facts every set of facts contains. Named for what it returns rather than as
`Facts.source`, which is the constructor. -/
def Facts.sourceFacts : Facts → SourceFacts
  | .source facts => facts
  | .syntax facts => facts.source

/-- A rule's implementation, indexed by the facts it reads.

The constructor *is* the tier declaration. A rule cannot claim one tier and read another, because
the tier determines the argument type — which is the whole difference between this and the `input`
field it replaces. -/
inductive RuleImpl where
  | source (run : SourceFacts → Array Finding)
  | «syntax» (run : SyntaxFacts → Array Finding)

def RuleImpl.tier : RuleImpl → Tier
  | .source _ => .source
  | .syntax _ => .syntax

/-- What a rule tells a user about itself. Its tier is not in here: `Rule.tier` derives it from the
implementation, so the two cannot disagree. -/
structure RuleInfo where
  code : String
  category : String
  summary : String
  fixable : Bool
  defaultEnabled : Bool
  deriving BEq

structure Rule where
  info : RuleInfo
  impl : RuleImpl

def Rule.code (rule : Rule) : String := rule.info.code

def Rule.tier (rule : Rule) : Tier := rule.impl.tier

/-- The `lean-fmt rules` wire shape. `input` is derived from the implementation rather than read from
a field, so it cannot describe a rule that does something else. -/
instance : Lean.ToJson Rule where
  toJson rule := Lean.Json.mkObj [
    ("code", .str rule.info.code),
    ("category", .str rule.info.category),
    ("summary", .str rule.info.summary),
    ("fixable", .bool rule.info.fixable),
    ("defaultEnabled", .bool rule.info.defaultEnabled),
    ("input", Lean.toJson rule.tier)
  ]

private def isHorizontalWhitespace (byte : UInt8) : Bool :=
  byte == 0x20 || byte == 0x09

private def trailingWhitespaceFinding (start stop : Nat) : Finding :=
  let range := { start, stop }
  {
    code := "FMT001"
    severity := .warning
    message := "trailing whitespace"
    range
    -- Safe: deleting horizontal whitespace before a newline cannot change how any Lean text
    -- elaborates, because the lexer cannot observe it. This is a byte-level argument, which is the
    -- only kind a `source`-tier rule may use to claim safety (`notes/01-model.md` §1).
    fix? := some { applicability := .safe, edits := #[{ range, replacement := "" }] }
  }

private def trailingWhitespace (facts : SourceFacts) : Array Finding := Id.run do
  let source := facts.bytes
  let mut findings := #[]
  let mut lineStart := 0
  for index in [0:source.size] do
    if source.get! index == 0x0a then
      let lineStop := index
      let mut contentStop := lineStop
      while contentStop > lineStart && isHorizontalWhitespace (source.get! (contentStop - 1)) do
        contentStop := contentStop - 1
      if contentStop < lineStop then
        findings := findings.push (trailingWhitespaceFinding contentStop lineStop)
      lineStart := index + 1
  let mut contentStop := source.size
  while contentStop > lineStart && isHorizontalWhitespace (source.get! (contentStop - 1)) do
    contentStop := contentStop - 1
  if contentStop < source.size then
    findings := findings.push (trailingWhitespaceFinding contentStop source.size)
  return findings

private def finalNewline (facts : SourceFacts) : Array Finding :=
  let source := facts.bytes
  if source.isEmpty || source.get! (source.size - 1) == 0x0a then
    #[]
  else
    let range := { start := source.size, stop := source.size }
    #[{
      code := "FMT002"
      severity := .warning
      message := "file must end with a newline"
      range
      -- Safe for the same reason as FMT001: a terminating newline is trivia the lexer cannot see.
      fix? := some { applicability := .safe, edits := #[{ range, replacement := "\n" }] }
    }]

/-- Every rule the product ships, in one static array.

Static, not an attribute or an environment extension. The rule set is compiled and first-party, so
dynamism would buy nothing and cost determinism: `lean-fmt rules` output and pre-sort finding order
would depend on import order. Lean stores its own linters in a mutable ref for one stated reason —
"Linters should be loadable as plugins" (`Lean/Elab/Command.lean:108-109`) — and a public runtime
plugin ABI is exactly what this product does not have. `notes/01-rule-facts.md` §7 compares the four
designs.

Accepted source cannot contain an isolated `\r`, so after normalization no carriage return survives
for a line-oriented rule to consider. -/
def ruleRegistry : Array Rule := #[
  {
    info := {
      code := "FMT001"
      category := "text"
      summary := "remove trailing horizontal whitespace"
      fixable := true
      defaultEnabled := true
    }
    impl := .source trailingWhitespace
  },
  {
    info := {
      code := "FMT002"
      category := "text"
      summary := "require a final newline"
      fixable := true
      defaultEnabled := true
    }
    impl := .source finalNewline
  }
]

/-- Findings sort by position, then by code.

Concatenating each rule's output in registry order used to be enough, because both rules were
`source`-tier and FMT001's findings happened to precede FMT002's. That was an accident of two rules
and does not survive a fold over mixed tiers: a `syntax` rule's findings would otherwise land after
every `source` rule's regardless of where in the file they are. Sorting on the code breaks ties
inside one position so that registry order — which is not meaningful — cannot decide output. -/
private def findingOrder (left right : Finding) : Bool :=
  if left.range.start != right.range.start then left.range.start < right.range.start
  else if left.range.stop != right.range.stop then left.range.stop < right.range.stop
  else left.code < right.code

/-- Every finding the available facts can produce, from `rules`, deterministically ordered.

**Selection is not applied here**, and must not be. `RulePlan.findings` projects afterwards, which is
what lets one cache entry serve any `--select` and what keeps a rule's enablement out of every
identity in the product. A rule whose tier the facts cannot serve is skipped: that is not a silent
omission, because `RulePlan.requiredTierOf` is what decided which facts to obtain, and it derives the
answer from the same array.

The registry is a parameter here and fixed in `runRules`. That is the whole substitution seam, and it
exists for one reason: the engine's tier behavior — skipping, mixed-tier ordering, tie-breaking —
cannot be tested through `ruleRegistry`, because every rule the product ships is `source`-tier and
the roadmap forbids shipping a fake one for coverage. Tests pass their own array. No production
caller does, and none should: a rule set chosen per call site is a rule set that can differ per call
site, which is the class of defect this whole stack exists to close. -/
def runRulesOf (rules : Array Rule) (facts : Facts) : Array Finding :=
  let findings := rules.foldl (init := #[]) fun findings rule =>
    -- The skip is the third case, not a guard. A `facts.tier.satisfies rule.tier` test here would
    -- be exactly redundant with this match and could drift from it; the match cannot drift, because
    -- the constructor pair is what decides, and it is total.
    match rule.impl, facts with
    | .source run, _ => findings ++ run facts.sourceFacts
    | .syntax run, .syntax syntaxFacts => findings ++ run syntaxFacts
    | .syntax _, .source _ => findings
  findings.qsort findingOrder

/-- Every finding the available facts can produce, from every rule the product ships. -/
def runRules (facts : Facts) : Array Finding := runRulesOf ruleRegistry facts

/-- Run every rule the module's own source can answer. -/
def runSourceRules (normalized : String) : Array Finding :=
  runRules (.source (SourceFacts.of normalized))

end LeanFmt.Internal
