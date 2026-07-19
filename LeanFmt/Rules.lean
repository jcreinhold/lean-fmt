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

/-- What a `semantic`-tier rule may read: the syntax projection plus the exact frontend's normalized
compiler diagnostics. A semantic rule needs the syntax facts too — its range coordinate system and
suppression are the projection's — so this nests `SyntaxFacts` rather than restating it, exactly as
`SyntaxFacts` nests `SourceFacts`. `diagnostics` are the immutable facts (`ArtifactModel.Diagnostic`)
the surfaced rules FMT014–FMT017 key on; a rule never sees an `Environment`, a `Position`, or a
`FileMap`, only this data (`ruff-11` `notes/01-authority.md` §7). -/
structure SemanticFacts where
  private mk ::
  «syntax» : SyntaxFacts
  diagnostics : Array Diagnostic
  /-- The owned deprecation-occurrence facts (`ruff-11b`), empty unless the run demanded the
  `occurrences` capability. A rule reads this as plain data; an empty array is *no fixes to offer*
  (whether because nothing was captured or nothing was found — the two are distinguished at the cache
  layer, not here), so a rule stays report-only on empty and the `check` path never triggers the walk. -/
  occurrences : Array DeprecatedOccurrence

/-- `normalized` must be the string `projection` indexes, the same contract `SyntaxFacts.of` carries.
`diagnostics` are the projection's captured `Diagnostic`s, already in normalized-source coordinates;
`occurrences` are the owned deprecation-occurrence facts (empty when the capability was not demanded). -/
def SemanticFacts.of (normalized : String) (projection : LosslessSource)
    (diagnostics : Array Diagnostic) (occurrences : Array DeprecatedOccurrence := #[]) : SemanticFacts :=
  { «syntax» := SyntaxFacts.of normalized projection, diagnostics, occurrences }

/-- The facts a run actually obtained. `SyntaxFacts` contains `SourceFacts` and `SemanticFacts`
contains `SyntaxFacts`, so richer facts run every cheaper rule too, and one run never needs two fact
objects. -/
inductive Facts where
  | source (facts : SourceFacts)
  | «syntax» (facts : SyntaxFacts)
  | semantic (facts : SemanticFacts)

/-- The source facts every set of facts contains. Named for what it returns rather than as
`Facts.source`, which is the constructor. -/
def Facts.sourceFacts : Facts → SourceFacts
  | .source facts => facts
  | .syntax facts => facts.source
  | .semantic facts => facts.syntax.source

/-- A rule's implementation, indexed by the facts it reads.

The constructor *is* the tier declaration. A rule cannot claim one tier and read another, because
the tier determines the argument type — which is the whole difference between this and the `input`
field it replaces. -/
inductive RuleImpl where
  | source (run : SourceFacts → Array Finding)
  | «syntax» (run : SyntaxFacts → Array Finding)
  | semantic (run : SemanticFacts → Array Finding)

def RuleImpl.tier : RuleImpl → Tier
  | .source _ => .source
  | .syntax _ => .syntax
  | .semantic _ => .semantic

/-- What a rule tells a user about itself. Its tier is not in here: `Rule.tier` derives it from the
implementation, so the two cannot disagree. -/
structure RuleInfo where
  code : String
  category : String
  summary : String
  fixable : Bool
  defaultEnabled : Bool
  /-- Whether this rule's fix reads the owned deprecation-occurrence fact (`ruff-11b`). It governs
  *capture cost only*: `RulePlan.demandedCaps` sets the `occurrences` capability — and pays the
  whole-file info-tree fold — exactly when a selected rule declares this in a rendering mode. A wrong
  value never corrupts a file (the fix rides the output re-elaboration validator); it only over- or
  under-captures. Unlike a tier field, it is not a claim the tier system enforces, so a test pins that
  a `needsOccurrences` rule is `.semantic` and that its fix appears iff occurrences were captured. -/
  needsOccurrences : Bool := false
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

/-! ## Source-security rules

`FMT003` and `FMT004` flag bytes that survive into accepted source only inside a string literal or a
comment: a bare control byte or bidirectional mark in the command stream is a hard parse error, so a
file carrying one in code is not accepted source and no source rule runs on it
(`notes/01-catalog.md` §2). The parser's acceptance is therefore the token context these rules would
otherwise need — they scan bytes, and every byte they can see is already in a string or comment. Both
are **report-only**: the byte is inside string data or a human-read comment, so deleting it is not a
change a byte-level argument can call safe (`notes/01-catalog.md` §3). -/

private def hexDigit (n : Nat) : Char :=
  if n < 10 then Char.ofNat (n + '0'.toNat) else Char.ofNat (n - 10 + 'A'.toNat)

/-- Uppercase four-digit hex, for the `U+XXXX` in a message. Every code these rules name is `≤ 0xFFFF`
(`notes/01-catalog.md` §3), so four digits is exact, not a truncation. -/
private def hex4 (n : Nat) : String :=
  String.ofList [hexDigit (n / 4096 % 16), hexDigit (n / 256 % 16), hexDigit (n / 16 % 16),
    hexDigit (n % 16)]

/-- The `FMT003` set: C0 controls except TAB (`0x09`) and LF (`0x0A`), plus DEL (`0x7F`). CR (`0x0D`)
is unreachable — it cannot survive into accepted normalized source — so its inclusion is moot. TAB is
excluded: it is legitimate string content and its bare form is a read-boundary rejection, never a
lint concern here. -/
private def isForbiddenControl (byte : UInt8) : Bool :=
  (byte < 0x20 && byte != 0x09 && byte != 0x0a) || byte == 0x7f

private def controlFinding (start : Nat) (codepoint : Nat) : Finding :=
  {
    code := "FMT003"
    severity := .warning
    message := s!"forbidden control byte U+{hex4 codepoint}"
    range := { start, stop := start + 1 }
    -- Report-only: the byte is inside a string literal or comment, so removing it changes program
    -- data or comment text — not a safe byte-level edit (`notes/01-catalog.md` §3).
    fix? := none
  }

/-- A single byte scan; no UTF-8 decoding, because every forbidden byte is one ASCII byte and can
never be a continuation byte of a multibyte scalar. -/
private def forbiddenControlByte (facts : SourceFacts) : Array Finding := Id.run do
  let bytes := facts.bytes
  let mut findings := #[]
  for index in [0:bytes.size] do
    let byte := bytes.get! index
    if isForbiddenControl byte then
      findings := findings.push (controlFinding index byte.toNat)
  return findings

/-- The `FMT004` set: the twelve Unicode bidirectional formatting controls of the Trojan-Source
attack (CVE-2021-42574). -/
private def isBidiControl (c : Char) : Bool :=
  let n := c.toNat
  n == 0x061c || (0x200e ≤ n && n ≤ 0x200f) || (0x202a ≤ n && n ≤ 0x202e) ||
    (0x2066 ≤ n && n ≤ 0x2069)

private def bidiFinding (start width codepoint : Nat) : Finding :=
  {
    code := "FMT004"
    severity := .warning
    message := s!"suspicious bidirectional control U+{hex4 codepoint}"
    range := { start, stop := start + width }
    -- Report-only for the same reason as `FMT003`: the mark is string data or comment text.
    fix? := none
  }

/-- One left fold over the normalized string, decoding each scalar once and carrying the running byte
offset in the accumulator, so the range is the mark's exact UTF-8 span without a second pass. -/
private def bidiControl (facts : SourceFacts) : Array Finding :=
  let step := fun (state : Nat × Array Finding) (c : Char) =>
    let (bytePos, findings) := state
    let findings :=
      if isBidiControl c then findings.push (bidiFinding bytePos c.utf8Size c.toNat) else findings
    (bytePos + c.utf8Size, findings)
  (facts.normalized.foldl step (0, #[])).2

/-! ## Syntax-tier rules

`FMT008`–`FMT013` read the exact frontend's projection through `SyntaxFacts`: node **kinds as
strings**, child/token adjacency, and leaf source text. None reads `Lean.Syntax`, precedence (the
projection carries none), or `choice` alternatives (only the first survives). Every kind string is
cited to the pinned v4.32.0 compiler in `docs/projects/ruff-10-syntax-rules/notes/01-catalog.md` §2 and
was read off real projections in that stack's `evidence/01-catalog.md` §1 — a wrong kind string is a
rule that silently never fires, so these are the census's strings, not guesses. -/

private def kModuleDoc := "Lean.Parser.Command.moduleDoc"
private def kDeclaration := "Lean.Parser.Command.declaration"
private def kNamespace := "Lean.Parser.Command.namespace"
private def kSection := "Lean.Parser.Command.section"
private def kEnd := "Lean.Parser.Command.end"
private def kAttributes := "Lean.Parser.Term.attributes"
private def kAttrInstance := "Lean.Parser.Term.attrInstance"
private def kDerivingClass := "Lean.Parser.Command.derivingClass"
private def kSetOption := "Lean.Parser.Command.set_option"
private def kParen := "Lean.Parser.Term.paren"
private def kHygienicLParen := "Lean.Parser.Term.hygienicLParen"

/-- Source text of a normalized byte range, decoded as UTF-8. Ranges index the normalized source, so
this is exact; an invalid slice (never produced by a validated projection) decodes to `""`. -/
private def rangeText (bytes : ByteArray) (start stop : Nat) : String :=
  (String.fromUTF8? (bytes.extract start stop)).getD ""

/-! ### FMT008 — module lacks a module docstring

Fires when the module has at least one `declaration` command but no `moduleDoc` (`/-! … -/`) node. A
declaration-level `/-- … -/` is a `docComment` inside `declModifiers`, a different kind, so it does not
satisfy the rule. Report-only: the missing thing is documentation text, which no formatter can write.
The finding is a caret at `headerStop` — where a module doc belongs, right after the header. -/
private def moduleDocRequired (facts : SyntaxFacts) : Array Finding := Id.run do
  let projection := facts.projection
  let mut firstDecl : Option Nat := none
  let mut hasModuleDoc := false
  for i in [0:projection.nodes.size] do
    -- A `moduleDoc` or `declaration` inside a `` `(…) `` quotation is quoted data, not this module's
    -- own docstring or declaration, so it neither satisfies nor triggers the requirement.
    if projection.inQuotation i then
      continue
    let kind := projection.kindOf i
    if kind == kModuleDoc then
      hasModuleDoc := true
    else if kind == kDeclaration && firstDecl.isNone then
      firstDecl := some i
  if hasModuleDoc || firstDecl.isNone then
    return #[]
  let insertion := projection.headerStop
  return #[{
    code := "FMT008"
    severity := .warning
    message := "module has declarations but no module docstring"
    range := { start := insertion, stop := insertion }
    fix? := none
  }]

/-! ### FMT009 — unclosed `section` or `namespace`

Matching is a name stack over the top-level command stream, as `notes/01-catalog.md` §2 specifies and
`Lean.Elab.Command`'s scope stack does. `namespace Foo` pushes the name `Foo`; `section` pushes an
anonymous scope; `section Bar` pushes `Bar`. A bare `end` pops one scope (the innermost, an anonymous
section in accepted source). An `end Foo` pops the scopes whose names, concatenated outer→inner with
`.`, spell `Foo` — so **one** `end A.B` closes both a single `namespace A.B` (one scope named `A.B`)
**and** a `namespace A` / `namespace B` pair (two scopes). Popping only one per `end` is the false
positive this rule shipped and RYR-FINAL's frozen-sample review caught on
`Mathlib/Probability/Kernel/Deterministic.lean` (`namespace ProbabilityTheory` / `namespace Kernel`
closed by one `end ProbabilityTheory.Kernel`). At the terminal, remaining opens are reported, except an
outermost anonymous `noncomputable`/`public`/`meta` section (the idiomatic whole-file section), dropped
to mirror Mathlib's `linter.style.missingEnd`. Report-only: where a scope *should* have closed is
author judgment. -/
private structure OpenScope where
  opener : Nat
  isSection : Bool
  named : Bool
  name : String
  outerSectionOk : Bool
  deriving Inhabited

/-- The whitespace-delimited words of a top-level scope command's node text. The node range is the leaf
hull (trivia excluded), so this is exactly the keyword, any modifiers, and the scope name — e.g.
`["noncomputable", "section", "Foo"]`, `["namespace", "A.B"]`, or `["end", "A.B"]`. Splitting on
whitespace rather than on the keyword substring avoids mis-parsing a name that contains the keyword
(e.g. a `Legendre` namespace). -/
private def scopeWords (text : String) : List String :=
  (text.splitOn " ").filter (·.length > 0)

private def unclosedScopes (facts : SyntaxFacts) : Array Finding := Id.run do
  let projection := facts.projection
  let bytes := facts.source.bytes
  let mut stack : Array OpenScope := #[]
  -- Only the top-level command stream is walked, and a quotation node always has a parent, so a
  -- `namespace`/`section`/`end` quoted inside `` `(…) `` is never in this loop — no `inQuotation`
  -- guard is needed here, unlike the node-scanning rules below.
  for i in projection.topLevelNodes do
    let kind := projection.kindOf i
    let text := rangeText bytes (projection.nodes[i]!.range.start) (projection.nodes[i]!.range.stop)
    if kind == kNamespace then
      -- `namespace <name>` — the name is the one word after the keyword. Fields, in order:
      -- opener, isSection, named, name, outerSectionOk.
      let scopeName := (scopeWords text).getD 1 ""
      stack := stack.push ⟨i, false, true, scopeName, false⟩
    else if kind == kSection then
      let words := scopeWords text
      let sectionIdx := words.findIdx (· == "section")
      -- The name is the word after `section` (absent for an anonymous section); modifiers precede it.
      let scopeName := words.getD (sectionIdx + 1) ""
      let outerOk := (words.take sectionIdx).any fun word =>
        word == "noncomputable" || word == "public" || word == "meta"
      stack := stack.push ⟨i, true, scopeName.length > 0, scopeName, outerOk⟩
    else if kind == kEnd then
      let endName := (scopeWords text).getD 1 ""
      if endName.isEmpty then
        if !stack.isEmpty then stack := stack.pop
      else
        -- Pop scopes from the top, accumulating names, until the outer→inner join spells `endName`.
        -- Accepted source always matches; on no match (unexpected input) fall back to a single pop.
        let mut popped : Array String := #[]
        let mut remaining := stack
        let mut matched := false
        while !remaining.isEmpty && !matched do
          popped := popped.push remaining.back!.name
          remaining := remaining.pop
          if String.intercalate "." popped.reverse.toList == endName then
            matched := true
        if matched then
          stack := remaining
        else if !stack.isEmpty then
          stack := stack.pop
  if stack.isEmpty then
    return #[]
  -- Drop outermost anonymous sections that carry an outer-section modifier.
  let mut lower := 0
  while lower < stack.size &&
      (stack[lower]!.isSection && !stack[lower]!.named && stack[lower]!.outerSectionOk) do
    lower := lower + 1
  if lower >= stack.size then
    return #[]
  let scope := stack[lower]!
  let range := projection.nodes[scope.opener]!.range
  let what := if scope.isSection then "section" else "namespace"
  return #[{
    code := "FMT009"
    severity := .warning
    message := s!"unclosed {what}"
    range
    fix? := none
  }]

/-- Duplicate detection shared by FMT010/FMT011: among sibling nodes of one `owner` kind, an entry
whose byte-identical text already appeared earlier in the same list is a duplicate. The fix deletes the
duplicate together with its preceding `", "` separator — `[previous sibling stop, duplicate stop)` — so
`@[simp, simp]` becomes `@[simp]` and `deriving Repr, Repr` becomes `deriving Repr`. Safe: an exact
repeat is idempotent, so removing it preserves what the elaborator records. -/
private def duplicateSiblings (bytes : ByteArray) (projection : LosslessSource)
    (childAdjacency : Array (Array Nat)) (memberKind code message : String)
    (nodeIndex : Nat) : Array Finding := Id.run do
  let members := (childAdjacency[nodeIndex]!).filter fun j => projection.kindOf j == memberKind
  let mut texts : Array String := #[]
  let mut findings := #[]
  for idx in [0:members.size] do
    let range := projection.nodes[members[idx]!]!.range
    -- The node range is the leaf hull, so leading/trailing trivia is already excluded; the text is
    -- the instance's own bytes, and two exact duplicates compare equal here.
    let text := rangeText bytes range.start range.stop
    if texts.contains text then
      let prevStop := projection.nodes[members[idx-1]!]!.range.stop
      let editRange : SourceRange := { start := prevStop, stop := range.stop }
      findings := findings.push {
        code
        severity := .warning
        message
        range
        fix? := some { applicability := .safe, edits := #[{ range := editRange, replacement := "" }] }
      }
    texts := texts.push text
  return findings

/-! ### FMT010 — duplicate attribute in one `@[…]` list. ### FMT011 — duplicate `deriving` class.
Both are `duplicateSiblings` over the relevant owner/member kinds. -/
private def duplicateAttribute (facts : SyntaxFacts) : Array Finding := Id.run do
  let projection := facts.projection
  let bytes := facts.source.bytes
  let childAdjacency := projection.childAdjacency
  let mut findings := #[]
  -- `attributes` is `"@[" >> sepBy1 attrInstance ", " >> "]"`, and `sepBy1` inserts a null group node,
  -- so the `attrInstance`s are children of that group, not of `attributes` directly. Grouping by the
  -- actual parent (any node with `attrInstance` children) is robust to that intermediate, exactly as
  -- FMT011 does for `derivingClass`.
  for i in [0:projection.nodes.size] do
    if projection.inQuotation i then
      continue
    if (childAdjacency[i]!).any fun j => projection.kindOf j == kAttrInstance then
      findings := findings ++ duplicateSiblings bytes projection childAdjacency
        kAttrInstance "FMT010" "duplicate attribute in attribute list" i
  return findings

private def duplicateDerivingClass (facts : SyntaxFacts) : Array Finding := Id.run do
  let projection := facts.projection
  let bytes := facts.source.bytes
  let childAdjacency := projection.childAdjacency
  let mut findings := #[]
  -- `derivingClass` nodes sit under the `sepBy1` group node; grouping by that parent makes them
  -- siblings, whichever intermediate the parser inserted. Any node with `derivingClass` children is an
  -- owner, so scan every node once.
  for i in [0:projection.nodes.size] do
    if projection.inQuotation i then
      continue
    if (childAdjacency[i]!).any fun j => projection.kindOf j == kDerivingClass then
      findings := findings ++ duplicateSiblings bytes projection childAdjacency
        kDerivingClass "FMT011" "duplicate deriving class" i
  return findings

/-! ### FMT012 — development-only `set_option`

Fires on a `set_option` command whose option name root is `debug`, `pp`, `profiler`, or `trace` — the
exact set of Mathlib's `linter.style.setOption`. Matching the `set_option` **node** (not the string)
means a `set_option`-looking string literal or comment never fires. Report-only: removing a committed
option is author intent, and for the `… in` forms the scoped boundary is not a byte-safe question. -/
private def isDevelopmentOption (name : String) : Bool :=
  let root := (name.splitOn ".").headD name
  root == "debug" || root == "pp" || root == "profiler" || root == "trace"

private def developmentSetOption (facts : SyntaxFacts) : Array Finding := Id.run do
  let projection := facts.projection
  let bytes := facts.source.bytes
  let tokensByNode := projection.tokensByNode
  let mut findings := #[]
  for i in [0:projection.nodes.size] do
    if projection.inQuotation i then
      continue
    if projection.kindOf i == kSetOption then
      let tokens := tokensByNode[i]!
      -- tokens[0] is the `set_option` keyword atom; tokens[1] is the option-name identifier.
      if tokens.size ≥ 2 then
        let nameToken := tokens[1]!
        let name := rangeText bytes nameToken.start nameToken.stop
        if isDevelopmentOption name then
          findings := findings.push {
            code := "FMT012"
            severity := .warning
            message := s!"development-only option '{name}' set in committed source"
            range := { start := projection.nodes[i]!.range.start, stop := nameToken.stop }
            fix? := none
          }
  return findings

/-! ### FMT013 — redundant nested parentheses

Fires on a `paren` node whose only child **node** is itself a `paren` — `((e))`. The inner `(e)` is a
complete atomic term, so dropping the outer pair cannot regroup anything; no precedence is consulted
(the projection has none), which is why only the nested case is answerable here. The fix deletes the
outer `(` and `)` as two edits. Preview default until RYR-FINAL measures its tree-shape rate. -/
private def redundantNestedParen (facts : SyntaxFacts) : Array Finding := Id.run do
  let projection := facts.projection
  let childAdjacency := projection.childAdjacency
  let mut findings := #[]
  for i in [0:projection.nodes.size] do
    if projection.inQuotation i then
      continue
    if projection.kindOf i == kParen then
      -- A `paren` node is `hygienicLParen >> term >> ")"`; the `(` is itself a `hygienicLParen` node,
      -- so a paren has two child nodes and the *term* is the one that is not the opener. The rule
      -- fires when that term is itself a `paren` — `((e))`.
      let inner := (childAdjacency[i]!).filter fun j => projection.kindOf j != kHygienicLParen
      if inner.size == 1 && projection.kindOf inner[0]! == kParen then
        let outer := projection.nodes[i]!.range
        let inner := projection.nodes[inner[0]!]!.range
        findings := findings.push {
          code := "FMT013"
          severity := .warning
          message := "redundant nested parentheses"
          range := outer
          fix? := some { applicability := .safe, edits := #[
            { range := { start := outer.start, stop := inner.start }, replacement := "" },
            { range := { start := inner.stop, stop := outer.stop }, replacement := "" }] }
        }
  return findings

/-! ## Semantic-tier rules

`FMT014`–`FMT017` **surface** compiler diagnostics the exact frontend already emitted, keyed on each
message's stable top-level `kind` tag (a linter option name, or the deprecation attribute). They read
`SemanticFacts.diagnostics` — normalized `Diagnostic`s already in the projection's coordinate system,
captured from the `MessageLog` in `Analysis.lean` — and conclude a report-only `Finding` that preserves
the compiler's own message as detail. They re-derive nothing: reconstructing an unused-variable
diagnostic would mean reimplementing a linter from info trees and the metavariable context, the brittle
invention the roadmap stop-rule forbids (`ruff-11` `notes/01-authority.md` §§1,3-4).

Every rule is **report-only**: removing a binder or a section variable, or renaming a deprecated
reference, is not an edit any byte-level or projection fact here can prove safe. The four `kind` strings
are pinned first-hand to the v4.32.0 compiler in `evidence/01-semantic-diagnostics.txt`; a wrong string
is a rule that silently never fires, so these are the observed tags, not guesses. A toolchain that stops
emitting one of these kinds simply yields no findings — the surfaced mechanism only ever reads a tag the
running compiler actually produced (`notes/01-authority.md` §10). -/

private def kDeprecatedAttr := "Lean.Linter.deprecatedAttr"
private def kUnusedVariables := "linter.unusedVariables"
private def kUnusedSectionVars := "linter.unusedSectionVars"
private def kConstructorNameAsVariable := "linter.constructorNameAsVariable"

/-- The compiler-message `kind` tags the semantic rules surface, the single source of truth the capture
(`Analysis.lean`) filters by. Capture and rules read one array, so a captured diagnostic always has a
rule and a rule never keys on a tag the capture drops — the same discipline `runRulesOf` and
`requiredTierOf` share one registry for. -/
def surfacedDiagnosticKinds : Array String :=
  #[kDeprecatedAttr, kUnusedVariables, kUnusedSectionVars, kConstructorNameAsVariable]

/-- Surface every captured diagnostic of one `kind` as a report-only finding under `code`, preserving
the compiler's original `message`, `severity`, and `range`. No fix: see the section note. -/
private def surfaceDiagnostics (kind code : String) (facts : SemanticFacts) : Array Finding :=
  facts.diagnostics.filterMap fun d =>
    if d.kind == kind then
      some { code, severity := d.severity, message := d.message, range := d.range, fix? := none }
    else none

/-- FMT014 — use of a deprecated declaration (`@[deprecated]`), tag `Lean.Linter.deprecatedAttr`.

The **report** is surfaced from the compiler diagnostic — unchanged, always available, cheap. The
**unsafe rename fix** is attached from the owned occurrence fact only when it was captured (`ruff-11b`):
for each surfaced finding, a *fixable* occurrence at the same range contributes a `Fix` that replaces
the identifier with the deprecation's `newName?`. When occurrences were not captured — `check`, or any
run that did not demand the `occurrences` capability — `facts.occurrences` is empty and every finding
is report-only, byte-identical to the surfaced-only behavior. The fix is `unsafe`: a textual name swap
is plausibly intended but unproven, applied only under `--unsafe-fixes` and backstopped by the output
re-elaboration validator (`ruff-06` `notes/01-model.md` §1, `ruff-11b` `notes/01-model.md` §6). -/
private def deprecatedUse (facts : SemanticFacts) : Array Finding :=
  (surfaceDiagnostics kDeprecatedAttr "FMT014" facts).map fun finding =>
    match facts.occurrences.find? (fun o => o.fixable && o.range == finding.range) with
    | some occ =>
      match occ.newName? with
      | some replacement =>
        { finding with fix? := some {
            applicability := .unsafe, edits := #[{ range := occ.range, replacement }] } }
      | none => finding
    | none => finding

/-- FMT015 — unused variable / binder, tag `linter.unusedVariables`. -/
private def unusedVariable (facts : SemanticFacts) : Array Finding :=
  surfaceDiagnostics kUnusedVariables "FMT015" facts

/-- FMT016 — automatically-included section variable unused in a theorem, tag
`linter.unusedSectionVars`. -/
private def unusedSectionVariable (facts : SemanticFacts) : Array Finding :=
  surfaceDiagnostics kUnusedSectionVars "FMT016" facts

/-- FMT017 — bound variable resembles a nullary constructor, tag `linter.constructorNameAsVariable`. -/
private def constructorNameVariable (facts : SemanticFacts) : Array Finding :=
  surfaceDiagnostics kConstructorNameAsVariable "FMT017" facts

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
  },
  {
    info := {
      code := "FMT003"
      category := "security"
      summary := "reject forbidden control bytes in source"
      fixable := false
      defaultEnabled := true
    }
    impl := .source forbiddenControlByte
  },
  {
    info := {
      code := "FMT004"
      category := "security"
      summary := "flag suspicious bidirectional controls in source"
      fixable := false
      defaultEnabled := true
    }
    impl := .source bidiControl
  },
  {
    info := {
      code := "FMT008"
      category := "docs"
      summary := "require a module docstring when a module declares anything"
      fixable := false
      defaultEnabled := false
    }
    impl := .syntax moduleDocRequired
  },
  {
    info := {
      code := "FMT009"
      category := "structure"
      summary := "report an unclosed section or namespace"
      fixable := false
      defaultEnabled := false
    }
    impl := .syntax unclosedScopes
  },
  {
    info := {
      code := "FMT010"
      category := "redundancy"
      summary := "remove a duplicate attribute in an attribute list"
      fixable := true
      defaultEnabled := false
    }
    impl := .syntax duplicateAttribute
  },
  {
    info := {
      code := "FMT011"
      category := "redundancy"
      summary := "remove a duplicate deriving class"
      fixable := true
      defaultEnabled := false
    }
    impl := .syntax duplicateDerivingClass
  },
  {
    info := {
      code := "FMT012"
      category := "debug"
      summary := "report a development-only set_option left in source"
      fixable := false
      defaultEnabled := false
    }
    impl := .syntax developmentSetOption
  },
  {
    info := {
      code := "FMT013"
      category := "redundancy"
      summary := "remove redundant nested parentheses"
      fixable := true
      defaultEnabled := false
    }
    impl := .syntax redundantNestedParen
  },
  {
    info := {
      code := "FMT014"
      category := "deprecation"
      summary := "report use of a deprecated declaration"
      fixable := true
      defaultEnabled := false
      needsOccurrences := true
    }
    impl := .semantic deprecatedUse
  },
  {
    info := {
      code := "FMT015"
      category := "unused"
      summary := "report an unused variable or binder"
      fixable := false
      defaultEnabled := false
    }
    impl := .semantic unusedVariable
  },
  {
    info := {
      code := "FMT016"
      category := "unused"
      summary := "report a section variable unused in a theorem"
      fixable := false
      defaultEnabled := false
    }
    impl := .semantic unusedSectionVariable
  },
  {
    info := {
      code := "FMT017"
      category := "naming"
      summary := "report a bound variable that resembles a nullary constructor"
      fixable := false
      defaultEnabled := false
    }
    impl := .semantic constructorNameVariable
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
    | .syntax run, .semantic semanticFacts => findings ++ run semanticFacts.syntax
    | .syntax _, .source _ => findings
    | .semantic run, .semantic semanticFacts => findings ++ run semanticFacts
    | .semantic _, .source _ => findings
    | .semantic _, .syntax _ => findings
  findings.qsort findingOrder

/-- Every finding the available facts can produce, from every rule the product ships. -/
def runRules (facts : Facts) : Array Finding := runRulesOf ruleRegistry facts

/-- Run every rule the module's own source can answer. -/
def runSourceRules (normalized : String) : Array Finding :=
  runRules (.source (SourceFacts.of normalized))

/-! ## Import rules — declared here, produced elsewhere

The import family (`FMT005` duplicate, `FMT006` redundant, `FMT007` order/grouping) is **not** in
`ruleRegistry`, because it is not part of the linear-tier `RuleImpl` engine. Header facts are orthogonal
to the `source ≤ syntax ≤ semantic` chain — the syntax projection drops the header
(`LosslessSource.lean:185-187`) — and redundancy needs the Lake graph, which a pure `RuleImpl` cannot
fetch (`Rules.lean:17-19`). Their findings are produced by `LeanFmt.Internal.Imports` and the
`Project` graph operation and merged into the report stream (`RIR-IMPL`).

But their *identities* — code, category, summary, fixability, default — belong with every other rule's,
so selection, `--select imports`, suppression, and `lean-fmt rules` all treat them uniformly and cannot
drift. They are declared here as `RuleInfo`s and unioned into `allRuleInfos`, which is what
`Config`'s selectors and the `rules` command read, rather than `ruleRegistry` alone. -/
def importRuleInfos : Array RuleInfo := #[
  {
    code := "FMT005"
    category := "imports"
    summary := "remove a duplicate import"
    fixable := true
    defaultEnabled := true
  },
  {
    code := "FMT006"
    category := "imports"
    summary := "report an import made redundant by another import's transitive closure"
    fixable := false
    defaultEnabled := true
  },
  {
    code := "FMT007"
    category := "imports"
    summary := "report imports out of canonical order within a group"
    fixable := false
    defaultEnabled := true
  }
]

/-- Every rule identity the product ships: the linear-tier engine's rules plus the import rules. This is
the single source `Config` selection and the `rules` command read, so a rule cannot be selectable in one
place and invisible in another. -/
def allRuleInfos : Array RuleInfo := ruleRegistry.map (·.info) ++ importRuleInfos

/-- Whether `code` names an import rule (produced by `Imports`/`Project`, not the `RuleImpl` engine). -/
def isImportCode (code : String) : Bool := importRuleInfos.any (·.code == code)

/-- The `lean-fmt rules` wire shape for the whole catalog: every engine rule with its derived `input`
tier, then every import rule. An import rule's per-file read is the surface header — a **source**-level
fact — so it projects onto `source`, the cheapest tier; the module graph FMT006 also consults is
orthogonal to the `source ≤ syntax ≤ semantic` chain (`Imports`), a run-level input, not a deeper
frontend tier, so it is not a higher `input`. This is the single array `rules --json` prints, so an
import rule is as visible and selectable as any other. -/
def allRulesJson : Array Lean.Json :=
  ruleRegistry.map Lean.toJson ++ importRuleInfos.map fun info =>
    Lean.Json.mkObj [
      ("code", .str info.code),
      ("category", .str info.category),
      ("summary", .str info.summary),
      ("fixable", .bool info.fixable),
      ("defaultEnabled", .bool info.defaultEnabled),
      ("input", .str "source")
    ]

end LeanFmt.Internal
